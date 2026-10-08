//! Regalloc linear-scan allocator (LSRA) with LIFO free-pool reuse.
//! Extracted from `regalloc.zig` per ADR-0098 (D-141 sweep, Step 2
//! of compute/verify axis split; ADR-0097 was Step 1 = verify).
//!
//! Implements:
//!   - ADR-0037 LIFO free-pool LSRA
//!   - ADR-0060 force-spill of call-crossing vregs
//!   - ADR-0077 op_scratch_reservation_table fence (forbidden mask)
//!   - ADR-0053 v128 spill-frame alignment (computeSpillOffsets)

const std = @import("std");
const dbg = @import("../../../support/dbg.zig");
const zir = @import("../../../ir/zir.zig");
const regalloc = @import("regalloc.zig");
const shape_tags_mod = @import("regalloc_shape_tags.zig");
const local_homing = @import("../../../ir/analysis/local_homing.zig");
const jit_abi = @import("jit_abi.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const LiveRange = zir.LiveRange;
const Error = regalloc.Error;
const ScratchReservationFn = regalloc.ScratchReservationFn;
const Allocation = regalloc.Allocation;
const ShapeTag = regalloc.ShapeTag;

/// Cap on distinct slots before `compute` returns `SlotOverflow`.
/// D-289/D-331(B): raised 4095 → u16-max so fat funcs (go_regex) with
/// >4095 SIMULTANEOUSLY-LIVE values compile. The prior `4095` was the
/// arm64 `SUB SP, #imm12` budget — STALE: the prologue now two-steps
/// (arm64 emit.zig) / uses disp32 (x86_64 rbp_disp) past it, and spill
/// addressing escalates via `frameAddrLarge` (gpr.zig). The remaining
/// hard limit is the u16 slot id itself. `active_buf`/`free_buf` are
/// allocator-backed (sized to the live-range count, capped here), so a
/// large cap costs nothing for small functions (the dynamic-vs-fixed
/// pattern — 4th instance after [256]Frame block_stack + table_size 4096).
pub const max_slots: u16 = 65535;

const max_reg_slots_gpr_default: u16 = 8;

/// Build a u16 bitmask of forbidden slot ids for a vreg by
/// union-ing the reservation tables of every op strictly inside
/// the vreg's live range (`def_pc < pc < last_use_pc`).
fn forbiddenMaskForVreg(
    instrs: []const zir.ZirInstr,
    r: LiveRange,
    fence: ScratchReservationFn,
) u16 {
    var mask: u16 = 0;
    var pc: u32 = r.def_pc + 1;
    while (pc < r.last_use_pc) : (pc += 1) {
        if (pc >= instrs.len) break;
        for (fence(instrs[pc].op)) |sid| {
            if (sid < 16) mask |= @as(u16, 1) << @intCast(sid);
        }
    }
    return mask;
}

inline fn slotForbidden(mask: u16, slot_id: u16, force_spill_threshold: u16) bool {
    if (slot_id >= force_spill_threshold) return false;
    if (slot_id >= 16) return false;
    return (mask & (@as(u16, 1) << @intCast(slot_id))) != 0;
}

/// Comptime validator for a per-arch op_scratch_reservation_table
/// (ADR-0077). Per-arch tables call this from a `comptime` block
/// right after the table literal. The function emits
/// `@compileError` on any violation; the call is a no-op at
/// runtime.
pub fn validateRegallocOpScratchReservation(
    comptime table: anytype,
    comptime force_spill_threshold: u16,
) void {
    comptime {
        for (table, 0..) |reservation, op_idx| {
            for (reservation, 0..) |sid, sid_idx| {
                if (sid >= force_spill_threshold) {
                    @compileError(std.fmt.comptimePrint(
                        "ADR-0077: op_scratch_reservation_table[{d}][{d}] = slot {d} >= force_spill_threshold {d} (no-op declaration)",
                        .{ op_idx, sid_idx, sid, force_spill_threshold },
                    ));
                }
                var earlier_idx: usize = 0;
                while (earlier_idx < sid_idx) : (earlier_idx += 1) {
                    if (reservation[earlier_idx] == sid) {
                        @compileError(std.fmt.comptimePrint(
                            "ADR-0077: op_scratch_reservation_table[{d}] contains duplicate slot id {d}",
                            .{ op_idx, sid },
                        ));
                    }
                }
            }
        }
    }
}

const ActiveEntry = struct { slot: u16, last_use_pc: u32 };

/// A callout PC for the ADR-0060 force-spill pre-scan. `inclusive`
/// (ADR-0060 2026-05-31 amendment) widens the crossing test to
/// `cp <= last_use_pc` for alloc ops (struct.new) whose operands are
/// read AFTER the internal alloc CALL; regular calls keep `cp <
/// last_use_pc`.
const CallSite = struct { pc: u32, inclusive: bool };

/// Thin wrapper passing the arm64-default force_spill_threshold +
/// no fence. Callers needing the ADR-0077 fence call
/// `computeWith` directly.
pub fn compute(allocator: Allocator, func: *const ZirFunc) Error!Allocation {
    return computeWith(allocator, func, max_reg_slots_gpr_default, null, max_reg_slots_gpr_default);
}

/// Linear-scan allocation with LIFO free-pool reuse on dead
/// vregs (per ADR-0037), force-spill call-crossing vregs (per
/// ADR-0060), and ADR-0077 op-scratch fence.
pub fn computeWith(
    allocator: Allocator,
    func: *const ZirFunc,
    force_spill_threshold: u16,
    scratch_reservations: ?ScratchReservationFn,
    // ADR-0194 — the spill-frame origin (= per-arch GPR pool size =
    // `min(gpr_pool, fp_pool)`, the lowest id any class can spill at). The
    // `spill_offsets` array is SIZED and INDEXED from this so it agrees with
    // `Allocation.slot()`'s resolve origin; the value is recorded on the
    // returned Allocation (no post-compute patch). arm64 passes 8 (= the
    // historical `max_reg_slots_gpr_default`), so its layout is byte-identical.
    max_reg_slots_gpr: u16,
) Error!Allocation {
    const live = func.liveness orelse return Error.LivenessMissing;
    // ADR-0194: thread the spill-frame origin even on the empty path so the
    // Allocation's `max_reg_slots_gpr` is always the caller-supplied value
    // (consistency; harmless here since an empty alloc never spills).
    if (live.ranges.len == 0) return .{ .slots = &.{}, .n_slots = 0, .max_reg_slots_gpr = @intCast(max_reg_slots_gpr) };

    // ADR-0060 (+ 2026-05-31 amendment): collect callout PCs once.
    // `inclusive` marks alloc ops (struct.new) whose field operands are
    // read AFTER the internal alloc CALL — a vreg whose last_use IS the
    // op PC must spill across it (`cp <= last_use_pc`). Regular calls
    // and struct.new_default (zero field operands) keep the strict
    // bound (`cp < last_use_pc`).
    var call_pc_buf: [256]CallSite = undefined;
    var call_pc_len: u32 = 0;
    var call_pc_overflow = false;
    for (func.instrs.items, 0..) |ins, pc| {
        // Atomic rmw / cmpxchg (ADR-0168): callout through atomic_*_fn(s);
        // operands consumed into arg regs BEFORE the CALL (strict
        // crossing, like array.fill), but vregs spanning it must
        // force-spill (BLR/CALL clobbers caller-saved). Mirror memory.grow.
        if (jit_abi.isAtomicRmw(ins.op) or jit_abi.isAtomicCmpxchg(ins.op) or
            jit_abi.isAtomicNotify(ins.op) or jit_abi.isAtomicWait(ins.op))
        {
            if (call_pc_len < call_pc_buf.len) {
                call_pc_buf[call_pc_len] = .{ .pc = @intCast(pc), .inclusive = false };
                call_pc_len += 1;
            } else call_pc_overflow = true;
            continue;
        }
        const inclusive: ?bool = switch (ins.op) {
            .call, .@"memory.grow" => false,
            // #505: call_ref's callee and table.grow's callout clobber the pool
            // like `call`; a try_table's landing pad is reached through the
            // throw dispatcher and the exnref reify, so a vreg that outlives
            // the block spills at the block's pc.
            .call_ref, .@"table.grow", .try_table => false,
            // D-235: a subtyping module's call_indirect inserts a
            // `jitCallIndirectResolve` trampoline CALL before marshalling, so
            // its operands (idx + args, last_use AT the op PC) must force-spill
            // to survive the caller-saved clobber — inclusive crossing, like
            // struct.new. Non-subtyping call_indirect consumes operands before
            // its only (BLR) call → strict crossing (byte-identical).
            .call_indirect => func.uses_type_subtyping,
            // GC-on-JIT: struct.new_default emits a BLR/CALL into
            // the jitGcAlloc trampoline (clobbers caller-saved like
            // memory.grow), so vregs live across it must force-spill.
            .@"struct.new_default" => false,
            // struct.new (variadic): field operands stored AFTER the
            // alloc CALL → inclusive upper bound (ADR-0060 amendment).
            .@"struct.new" => true,
            // array.new_default: BLR/CALL into jitGcAllocArray; its length
            // operand is consumed into the arg BEFORE the CALL (strict),
            // but vregs spanning it must still force-spill.
            .@"array.new_default" => false,
            // array.new: BLR/CALL into jitGcAllocArrayFill; init + length
            // both consumed into args before the CALL (strict).
            .@"array.new" => false,
            // array.new_fixed (variadic): element operands stored AFTER the
            // alloc CALL → inclusive upper bound (mirror struct.new).
            .@"array.new_fixed" => true,
            // array.fill: CALL into jitGcArrayFill; all 4 operands consumed
            // into arg regs BEFORE the CALL (strict), but vregs spanning it
            // must force-spill (clobbered caller-saved).
            .@"array.fill" => false,
            // array.copy: CALL into jitGcArrayCopy; all 5 operands consumed
            // into arg regs BEFORE the CALL (strict).
            .@"array.copy" => false,
            // array.new_data: CALL into jitGcArrayNewData; both operands
            // (offset, size) consumed into args before the CALL (strict);
            // the result ref is captured from W0 after.
            .@"array.new_data" => false,
            // array.new_elem: CALL into jitGcArrayNewElem; same strict
            // shape as array.new_data (offset + size consumed pre-CALL).
            .@"array.new_elem" => false,
            // ref.test / ref.test_null: CALL into jitGcRefTest; the ref
            // operand is consumed into an arg reg before the CALL (strict).
            .@"ref.test", .@"ref.test_null" => false,
            // ref.cast: CALL into jitGcRefCast; ref consumed pre-CALL (strict).
            .@"ref.cast" => false,
            // ref.cast_null: CALL into jitGcRefTest; ref consumed pre-CALL (strict).
            .@"ref.cast_null" => false,
            // br_on_cast / br_on_cast_fail CALL jitGcRefTest. The ref is
            // PEEKed (not popped): read into the arg reg BEFORE the CALL and
            // RELOADED AFTER it by branchOnReg's merge. So a vreg whose last_use
            // IS this op pc (the ref, if not consumed further) must still spill
            // across the internal CALL → inclusive bound (mirror struct.new).
            .br_on_cast, .br_on_cast_fail => true,
            else => null,
        };
        const inc = inclusive orelse continue;
        if (call_pc_len < call_pc_buf.len) {
            call_pc_buf[call_pc_len] = .{ .pc = @intCast(pc), .inclusive = inc };
            call_pc_len += 1;
        } else {
            call_pc_overflow = true;
        }
    }
    const call_pcs = call_pc_buf[0..call_pc_len];

    var slots = try allocator.alloc(u16, live.ranges.len);
    errdefer allocator.free(slots);
    const shape_tags = try shape_tags_mod.populateShapeTags(allocator, func, live.ranges.len);
    errdefer if (shape_tags) |t| allocator.free(t);

    var n_slots: u16 = 0;
    var n_spill_minted: u16 = 0;

    // D-289: allocator-backed (was `[max_slots+1]` stack arrays — 65536 entries
    // would blow the stack). active_len/free_len never exceed n_slots ≤
    // min(ranges.len, max_slots), so size to that tight bound.
    // `@min` narrows to the comptime bound's type (u16): widen BEFORE the + 1 (#487).
    const buf_cap: usize = @as(usize, @min(live.ranges.len, max_slots)) + 1;
    const active_buf = try allocator.alloc(ActiveEntry, buf_cap);
    defer allocator.free(active_buf);
    var active_len: u16 = 0;
    const free_buf = try allocator.alloc(u16, buf_cap);
    defer allocator.free(free_buf);
    var free_len: u16 = 0;

    // ADR-0155 stage 1 — register-homed locals. liveness APPENDED K
    // function-spanning pseudo-vregs (the last K vregs). PRIORITISE them onto
    // the low register slots 0..K-1 BEFORE the greedy temporary scan so they
    // stay register-resident despite their high vreg ids. Pre-seed the active
    // list with their spanning ranges (last_use_pc = function end) so the
    // reclaim test never frees those slots for any temporary; the greedy scan
    // then mints temporaries starting at slot K. The pseudo-vreg's own
    // iteration step (vreg id >= homed_base) assigns its reserved slot.
    const homing = local_homing.plan(func);
    const homed_count: u16 = @intCast(homing.count);
    const homed_base: usize = live.ranges.len - @as(usize, homed_count); // first pseudo-vreg id
    if (homed_count > 0) {
        const last_pc: u32 = if (func.instrs.items.len > 0) @intCast(func.instrs.items.len - 1) else 0;
        var s: u16 = 0;
        while (s < homed_count) : (s += 1) {
            active_buf[active_len] = .{ .slot = s, .last_use_pc = last_pc };
            active_len += 1;
        }
        n_slots = homed_count;
    }

    for (live.ranges, 0..) |r, vreg| {
        // Homed pseudo-vreg: take its pre-reserved low slot (rank = id offset
        // from homed_base). Already in the active list from the pre-seed.
        if (homed_count > 0 and vreg >= homed_base) {
            slots[vreg] = @intCast(vreg - homed_base);
            continue;
        }
        var i: u16 = 0;
        while (i < active_len) {
            // D-330 / ADR-0037 amendment: STRICT expiry (`<`, not `<=`). A vreg
            // last-used at pc P and a vreg defined at pc P OVERLAP at P — the op
            // at P reads the former while writing the latter. Coalescing their
            // slot (the old `<=`) is only safe if EVERY op emit reads all
            // operands before writing its result; that invariant is unenforced
            // and was violated (a strnlen byte-loop op in emscripten vfprintf →
            // empty `%s` + dropped `\n`, c_sha256_hash/emcc_fasta miscompiled).
            // Strict expiry guarantees a result slot never aliases an operand the
            // defining op reads, making per-op read-before-write discipline
            // unnecessary (misuse-resistant). Cost: ~+1 slot on the worst
            // realworld function (vfprintf 12→13); negligible.
            if (active_buf[i].last_use_pc < r.def_pc) {
                // D-489 experiment (ZWASM_DEBUG=regalloc.noreuse): drop the freed slot
                // instead of recycling it → every vreg mints a fresh slot. If the bug
                // vanishes, slot REUSE is the cause.
                free_buf[free_len] = active_buf[i].slot;
                free_len += 1;
                active_len -= 1;
                if (i < active_len) active_buf[i] = active_buf[active_len];
            } else {
                i += 1;
            }
        }

        const spans_call = blk: {
            if (call_pc_overflow) break :blk true;
            for (call_pcs) |c| {
                const crosses = if (c.inclusive)
                    (r.def_pc < c.pc and c.pc <= r.last_use_pc)
                else
                    (r.def_pc < c.pc and c.pc < r.last_use_pc);
                if (crosses) break :blk true;
            }
            break :blk false;
        };

        const forbidden: u16 = if (scratch_reservations) |fence|
            forbiddenMaskForVreg(func.instrs.items, r, fence)
        else
            0;

        const assigned: u16 = blk: {
            if (spans_call) {
                var fi: u16 = 0;
                while (fi < free_len) : (fi += 1) {
                    if (free_buf[fi] >= force_spill_threshold) {
                        const s = free_buf[fi];
                        free_buf[fi] = free_buf[free_len - 1];
                        free_len -= 1;
                        break :blk s;
                    }
                }
                const s_u32: u32 = @as(u32, force_spill_threshold) + n_spill_minted;
                if (s_u32 >= max_slots) {
                    dbg.print("codegen", "regalloc: SlotOverflow (spill mint) at func[{d}] vreg={d} ranges.len={d}\n", .{ func.func_idx, vreg, live.ranges.len });
                    return Error.SlotOverflow;
                }
                n_spill_minted += 1;
                break :blk @as(u16, @intCast(s_u32));
            }
            if (free_len > 0) {
                var fi: i32 = @as(i32, free_len) - 1;
                while (fi >= 0) : (fi -= 1) {
                    const idx: u16 = @intCast(fi);
                    if (!slotForbidden(forbidden, free_buf[idx], force_spill_threshold)) {
                        const s = free_buf[idx];
                        free_buf[idx] = free_buf[free_len - 1];
                        free_len -= 1;
                        break :blk s;
                    }
                }
            }
            // Register region: skip forbidden register slots (slotForbidden is
            // false for ids >= force_spill_threshold, so this only advances through
            // register ids).
            while (n_slots < force_spill_threshold and slotForbidden(forbidden, n_slots, force_spill_threshold)) {
                n_slots += 1;
            }
            if (n_slots < force_spill_threshold) {
                const new = n_slots;
                n_slots += 1;
                break :blk new;
            }
            // D-489 fix: registers exhausted → mint the spill slot from the UNIFIED
            // `n_spill_minted` counter (shared with the spans_call path above). The
            // previous code minted `n_slots` here, whose values reach the same
            // `force_spill_threshold + k` ids the spans_call path mints — double-booking
            // a spill slot between a call-spanning vreg and a normal spilled vreg. The
            // collision only bites when normal-path spilling actually occurs (n_slots
            // passes the threshold), which is routine on x86_64's 4-GPR pool but rare on
            // arm64's 8 → the x86_64-only D-489 tinygo_json miscompile.
            const s_u32: u32 = @as(u32, force_spill_threshold) + n_spill_minted;
            if (s_u32 >= max_slots) {
                dbg.print("codegen", "regalloc: SlotOverflow (spill mint) at func[{d}] vreg={d} ranges.len={d} (>{d} simultaneously live)\n", .{ func.func_idx, vreg, live.ranges.len, max_slots });
                return Error.SlotOverflow;
            }
            n_spill_minted += 1;
            break :blk @as(u16, @intCast(s_u32));
        };
        slots[vreg] = assigned;
        // Track the register high-water only; spill slots are accounted by
        // `n_spill_minted` (D-489 — keeps `n_slots` as the register counter so a
        // spill assignment can't push register minting into the spill region).
        if (assigned < force_spill_threshold and assigned + 1 > n_slots) n_slots = assigned + 1;
        active_buf[active_len] = .{ .slot = assigned, .last_use_pc = r.last_use_pc };
        active_len += 1;
    }

    // Total slot count = register high-water, or the top of the spill region when
    // any spill was minted (spill ids are force_spill_threshold .. +n_spill_minted-1).
    const total_slots: u16 = if (n_spill_minted > 0)
        @intCast(@as(u32, force_spill_threshold) + n_spill_minted)
    else
        n_slots;

    const spill_offsets = if (shape_tags) |tags|
        try computeSpillOffsets(allocator, slots, total_slots, max_reg_slots_gpr, tags)
    else
        null;
    errdefer if (spill_offsets) |so| allocator.free(so);

    return .{
        .slots = slots,
        .n_slots = total_slots,
        .shape_tags = shape_tags,
        .spill_offsets = spill_offsets,
        .max_reg_slots_gpr = @intCast(max_reg_slots_gpr),
    };
}

/// ADR-0053 Part 1 — compute per-slot spill byte offsets.
fn computeSpillOffsets(
    allocator: Allocator,
    slots: []const u16,
    n_slots: u16,
    max_reg_slots_gpr: u16,
    shape_tags: []const ShapeTag,
) Error!?[]u32 {
    if (n_slots <= max_reg_slots_gpr) return null;
    const n_spill: usize = @intCast(n_slots - max_reg_slots_gpr);

    var any_v128: bool = false;
    const shapes = try allocator.alloc(u2, n_spill);
    defer allocator.free(shapes);
    @memset(shapes, 0);
    for (slots, 0..) |s, vreg| {
        if (s < max_reg_slots_gpr) continue;
        const idx: usize = @intCast(s - max_reg_slots_gpr);
        const t = if (vreg < shape_tags.len) shape_tags[vreg] else .scalar;
        const this_shape: u2 = switch (t) {
            .v128 => 2,
            .scalar, _ => 1,
        };
        if (this_shape > shapes[idx]) shapes[idx] = this_shape;
        if (this_shape == 2) any_v128 = true;
    }
    if (!any_v128) return null;

    const offsets = try allocator.alloc(u32, n_spill);
    errdefer allocator.free(offsets);
    var byte_off: u32 = 0;
    var i: usize = 0;
    while (i < n_spill) : (i += 1) {
        if (shapes[i] == 2) {
            byte_off = std.mem.alignForward(u32, byte_off, 16);
            offsets[i] = byte_off;
            byte_off += 16;
        } else {
            offsets[i] = byte_off;
            byte_off += 8;
        }
    }
    return offsets;
}

const testing = std.testing;

fn freshFunc() ZirFunc {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    return ZirFunc.init(0, sig, &.{});
}

/// Local stub fence-table fn for tests. Reserves slots {0..4} for
/// `.@"table.fill"`. Mirrors the production reservation set per
/// the live-scratch census.
fn testFenceTableFill(op: zir.ZirOp) []const u16 {
    const reservation = [_]u16{ 0, 1, 2, 3, 4 };
    return if (op == .@"table.fill") &reservation else &.{};
}

test "compute: empty liveness yields empty allocation" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(usize, 0), alloc.slots.len);
    try testing.expectEqual(@as(u16, 0), alloc.n_slots);
}

test "compute: missing liveness returns LivenessMissing" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try testing.expectError(Error.LivenessMissing, compute(testing.allocator, &f));
}

test "computeWith: records the caller's max_reg_slots_gpr on the Allocation (ADR-0194)" {
    // The spill-frame origin is set at BUILD time (was: patched after compute in
    // compile.zig, leaving spill_offsets sized from a different origin → D-461 OOB).
    // A non-default origin (4 = x86_64 GPR pool) must round-trip onto the result.
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const alloc = try computeWith(testing.allocator, &f, 6, null, 4);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u8, 4), alloc.max_reg_slots_gpr);
}

test "compute: two non-overlapping ranges share slot 0" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 1), alloc.n_slots);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u16, 0), alloc.slots[1]);
    try regalloc.verify(&f, alloc);
}

test "compute: two overlapping ranges get distinct slots" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 5 },
        .{ .def_pc = 1, .last_use_pc = 4 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 2), alloc.n_slots);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u16, 1), alloc.slots[1]);
    try regalloc.verify(&f, alloc);
}

test "compute: shared-edge (use=def at same pc) IS an overlap → distinct slots (D-330)" {
    // D-330 / ADR-0037 amendment: a vreg last-used at pc P and a vreg defined at
    // pc P overlap AT P (the op at P reads the first while writing the second), so
    // they must NOT share a slot. The prior `<=` expiry coalesced them (1 slot),
    // which is only safe if every op emit reads operands before writing its
    // result — an unenforced invariant violated by a strnlen byte-loop op in
    // emscripten vfprintf (empty `%s` + dropped `\n`). Strict `<` expiry → 2 slots.
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 5 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 2), alloc.n_slots);
    try testing.expect(alloc.slots[0] != alloc.slots[1]);
    try regalloc.verify(&f, alloc);
}

test "compute: >4095 simultaneously-live ranges no longer SlotOverflow (D-289/D-331(B))" {
    // D-289: fat funcs (go_regex) need >4095 simultaneously-live values. The old
    // fixed `[max_slots+1]` stack buffers + `max_slots=4095` cap returned
    // SlotOverflow; allocator-backed buffers + a raised cap (the 4th dynamic-vs-
    // fixed instance) mint one slot per live value. 5000 fully-overlapping ranges.
    const n: u16 = 5000;
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = try testing.allocator.alloc(LiveRange, n);
    defer testing.allocator.free(ranges);
    for (ranges) |*r| r.* = .{ .def_pc = 0, .last_use_pc = 10000 };
    f.liveness = .{ .ranges = ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(n, alloc.n_slots); // fully overlapping → no reuse
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u16, n - 1), alloc.slots[n - 1]);
    try regalloc.verify(&f, alloc);
}

test "compute: 65535 simultaneously-live ranges fill the cap exactly, no panic (#487)" {
    // Pins: the buffer-size arithmetic runs in usize, not the cap's u16.
    const n: usize = max_slots;
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = try testing.allocator.alloc(LiveRange, n);
    defer testing.allocator.free(ranges);
    for (ranges) |*r| r.* = .{ .def_pc = 0, .last_use_pc = 100_000 };
    f.liveness = .{ .ranges = ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(max_slots, alloc.n_slots);
    // `verify` is quadratic; fully overlapping ranges mint slot ids in vreg
    // order, so the linear check is exact.
    for (alloc.slots, 0..) |s, v| try testing.expectEqual(@as(u16, @intCast(v)), s);
}

test "compute: 65535 sequential ranges share slot 0 (the ffmpeg shape, #487)" {
    // Pins: many vregs with few live at once compile, rather than decline.
    const n: usize = max_slots;
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = try testing.allocator.alloc(LiveRange, n);
    defer testing.allocator.free(ranges);
    for (ranges, 0..) |*r, i| r.* = .{ .def_pc = @intCast(i), .last_use_pc = @intCast(i) };
    f.liveness = .{ .ranges = ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 1), alloc.n_slots);
    for (alloc.slots) |s| try testing.expectEqual(@as(u16, 0), s);
}

test "compute: 65536 simultaneously-live ranges decline with SlotOverflow, not a panic (#487)" {
    const n: usize = @as(usize, max_slots) + 1;
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = try testing.allocator.alloc(LiveRange, n);
    defer testing.allocator.free(ranges);
    for (ranges) |*r| r.* = .{ .def_pc = 0, .last_use_pc = 100_000 };
    f.liveness = .{ .ranges = ranges };
    try testing.expectError(error.SlotOverflow, compute(testing.allocator, &f));
}

test "compute: three sequential non-overlapping ranges all share slot 0 (n_slots = 1)" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 3, .last_use_pc = 5 },
        .{ .def_pc = 6, .last_use_pc = 8 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 1), alloc.n_slots);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u16, 0), alloc.slots[1]);
    try testing.expectEqual(@as(u16, 0), alloc.slots[2]);
    try regalloc.verify(&f, alloc);
}

test "compute: three overlapping ranges fan out to distinct slots" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 9 },
        .{ .def_pc = 1, .last_use_pc = 9 },
        .{ .def_pc = 2, .last_use_pc = 9 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 3), alloc.n_slots);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u16, 1), alloc.slots[1]);
    try testing.expectEqual(@as(u16, 2), alloc.slots[2]);
    try regalloc.verify(&f, alloc);
}

test "alloc-op force-spill: struct.new field operand (last_use AT op PC) spills" {
    // ADR-0060 amendment — struct.new reads its field operands AFTER the
    // internal jitGcAlloc CALL, so a vreg whose last_use IS the struct.new
    // PC must force-spill (inclusive upper bound `cp <= last_use_pc`).
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"struct.new", .payload = 0 });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expect(alloc.slots[0] >= max_reg_slots_gpr_default);
    try regalloc.verify(&f, alloc);
}

test "alloc-op force-spill: vreg strictly spanning struct.new also spills (superset)" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"struct.new", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .drop });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expect(alloc.slots[0] >= max_reg_slots_gpr_default);
    try regalloc.verify(&f, alloc);
}

test "#505: a vreg spanning call_ref / table.grow / try_table force-spills (strict crossing)" {
    const ops = [_]zir.ZirOp{ .call_ref, .@"table.grow", .try_table };
    for (ops) |op| {
        var f = freshFunc();
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
        try f.instrs.append(testing.allocator, .{ .op = op, .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .drop });
        const ranges = [_]LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
        };
        f.liveness = .{ .ranges = &ranges };
        const alloc = try compute(testing.allocator, &f);
        defer regalloc.deinit(testing.allocator, alloc);
        try testing.expect(alloc.slots[0] >= max_reg_slots_gpr_default);
        try regalloc.verify(&f, alloc);
    }
}

test "call (non-alloc): operand consumed AT call PC stays in register (strict bound preserved)" {
    // Contrast guard: a normal call reads its operand into the arg register
    // BEFORE the clobber, so last_use == call PC is safe (strict `<`).
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expect(alloc.slots[0] < max_reg_slots_gpr_default);
    try regalloc.verify(&f, alloc);
}

test "compute: empty liveness returns null shape_tags" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expect(alloc.shape_tags == null);
}

test "compute: scalar-only function has null shape_tags" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expect(alloc.shape_tags == null);
}

test "spill_offsets: scalar-only allocation uses 16-byte stride (post-ADR-0110 widen)" {
    const slots = [_]u16{ 0, 1, 8, 9 };
    const tags = [_]ShapeTag{ .scalar, .scalar, .scalar, .scalar };
    const alloc: Allocation = .{
        .slots = &slots,
        .n_slots = 10,
        .max_reg_slots_gpr = 8,
        .shape_tags = &tags,
        .spill_offsets = null,
    };
    try testing.expectEqual(@as(u32, 0), alloc.slot(0, .gpr).reg);
    try testing.expectEqual(@as(u32, 1), alloc.slot(1, .gpr).reg);
    // Post-widen: every slot is 16-byte regardless of scalar/v128.
    try testing.expectEqual(@as(u32, 0), alloc.slot(2, .gpr).spill);
    try testing.expectEqual(@as(u32, 16), alloc.slot(3, .gpr).spill);
}

test "spill_offsets: v128 spill slot gets 16-byte alignment + stride" {
    const slots = [_]u16{ 8, 9, 10 };
    const tags = [_]ShapeTag{ .scalar, .v128, .scalar };
    const offsets = [_]u32{ 0, 16, 32 };
    const alloc: Allocation = .{
        .slots = &slots,
        .n_slots = 11,
        .max_reg_slots_gpr = 8,
        .shape_tags = &tags,
        .spill_offsets = &offsets,
    };
    try testing.expectEqual(@as(u32, 0), alloc.slot(0, .gpr).spill);
    try testing.expectEqual(@as(u32, 16), alloc.slot(1, .gpr).spill);
    try testing.expectEqual(@as(u32, 32), alloc.slot(2, .gpr).spill);
    try testing.expectEqual(@as(u32, 48), alloc.spillBytes());
}

test "computeSpillOffsets: bumps scalar-then-v128 to 16-byte alignment" {
    const slots_arr = [_]u16{ 8, 9, 10 };
    const tags = [_]ShapeTag{ .scalar, .v128, .scalar };
    const result = (try computeSpillOffsets(testing.allocator, &slots_arr, 11, 8, &tags)).?;
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u32, &.{ 0, 16, 32 }, result);
}

test "computeSpillOffsets: returns null when no v128 vreg spills" {
    const slots_arr = [_]u16{ 8, 9 };
    const tags = [_]ShapeTag{ .scalar, .scalar };
    const result = try computeSpillOffsets(testing.allocator, &slots_arr, 10, 8, &tags);
    try testing.expect(result == null);
}

test "computeSpillOffsets: v128 alignment with leading scalar pads correctly" {
    const slots_arr = [_]u16{ 8, 9 };
    const tags = [_]ShapeTag{ .scalar, .v128 };
    const result = (try computeSpillOffsets(testing.allocator, &slots_arr, 10, 8, &tags)).?;
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u32, &.{ 0, 16 }, result);
}

test "compute: SIMD function gets populated shape_tags" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32x4.splat" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expect(alloc.shape_tags != null);
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(0));
    try testing.expectEqual(ShapeTag.v128, alloc.shapeTag(1));
}

test "fence: null reservation is bit-for-bit identical to pre-fence walker" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .@"table.fill" });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try computeWith(testing.allocator, &f, max_reg_slots_gpr_default, null, max_reg_slots_gpr_default);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try regalloc.verify(&f, alloc);
}

test "fence: vreg crossing reserving op is forced past slots 0..4" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .@"table.fill" });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 3 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try computeWith(testing.allocator, &f, max_reg_slots_gpr_default, testFenceTableFill, max_reg_slots_gpr_default);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expect(alloc.slots[0] >= 5);
    try regalloc.verify(&f, alloc);
}

test "fence is PC-local: non-crossing vreg keeps slot 0 even with fence active" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .@"table.fill" });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 3, .last_use_pc = 4 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try computeWith(testing.allocator, &f, max_reg_slots_gpr_default, testFenceTableFill, max_reg_slots_gpr_default);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u16, 0), alloc.slots[1]);
    try regalloc.verify(&f, alloc);
}

test "fence: boundary PC (vreg ending AT reserving op) is safe on slot 0" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .@"table.fill" });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try computeWith(testing.allocator, &f, max_reg_slots_gpr_default, testFenceTableFill, max_reg_slots_gpr_default);
    defer regalloc.deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try regalloc.verify(&f, alloc);
}

test "D-489: call-spanning spill + normal-path spill never share a slot" {
    // Regression for the dual-counter spill-mint collision: a call-spanning vreg
    // (force-spilled via the spans_call path, minting `threshold + n_spill_minted`)
    // and a normal-path spilled vreg (formerly minting `n_slots`, which reaches the
    // SAME `threshold + k` ids once registers are exhausted) double-booked one spill
    // slot. With force_spill_threshold = 2, v0 spans the call@5 and v3 spills via the
    // normal path while v0 is still live → the old code gave both slot 2.
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 11) : (i += 1) {
        try f.instrs.append(testing.allocator, .{ .op = if (i == 5) .call else .nop });
    }
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 10 }, // v0 — spans call@5 → force-spilled
        .{ .def_pc = 6, .last_use_pc = 9 }, // v1 — register
        .{ .def_pc = 6, .last_use_pc = 8 }, // v2 — register (pool of 2 now full)
        .{ .def_pc = 6, .last_use_pc = 7 }, // v3 — normal-path spill, overlaps v0
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try computeWith(testing.allocator, &f, 2, null, 2);
    defer regalloc.deinit(testing.allocator, alloc);
    try regalloc.verify(&f, alloc); // would throw OverlappingVregsShareSlot pre-fix
    try testing.expect(alloc.slots[0] >= 2 and alloc.slots[3] >= 2); // both spilled
    try testing.expect(alloc.slots[0] != alloc.slots[3]); // distinct spill slots
}

test "validateRegallocOpScratchReservation: well-formed table compiles" {
    comptime {
        var t: [16][]const u16 = .{&.{}} ** 16;
        t[3] = &.{ 0, 1, 2, 3, 4 };
        validateRegallocOpScratchReservation(t, 8);
    }
}

test "validateRegallocOpScratchReservation: empty table compiles" {
    comptime {
        const t: [4][]const u16 = .{&.{}} ** 4;
        validateRegallocOpScratchReservation(t, 8);
    }
}

test "validateRegallocOpScratchReservation: edge case — single-slot reservation at threshold-1" {
    comptime {
        var t: [2][]const u16 = .{&.{}} ** 2;
        t[0] = &.{7};
        validateRegallocOpScratchReservation(t, 8);
    }
}
