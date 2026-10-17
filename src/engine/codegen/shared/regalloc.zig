//! JIT greedy-local register allocator.
//!
//! Reads `ZirFunc.liveness.?.ranges` (populated upstream by
//! `src/ir/liveness.zig`) and assigns each vreg
//! the smallest physical slot id not held by any earlier vreg
//! whose live range overlaps. Output is a dense
//! `Allocation { slots, n_slots }` consumed by the
//! emit pass (which maps slot id → physical register via the
//! per-arch ABI table).
//!
//! W54-class lesson made structural (per `textbook_survey.md`
//! Guard 4 + ROADMAP §4.2 / P13): liveness drives regalloc, not
//! the other way around. Liveness is a **const input** here;
//! `verify` then asserts the post-condition (no two overlapping
//! live ranges share a slot) before downstream emit ever sees
//! the allocation. v1's W54 root cause was regalloc-stage IR
//! shape implicitly assuming an absent liveness invariant; the
//! split-input + post-condition shape here makes that
//! impossible by construction.
//!
//! Current scope: slot-only assignment + verifier. All vregs
//! treated as a single pool; per-class slot pools land alongside
//! the ABI work (`reg_class.zig`'s `RegClassInfo` table
//! becomes load-bearing then). Spilling is a
//! follow-up — the allocator may grow `n_slots` up to
//! `max_slots`; `SlotOverflow` surfaces when the validator's
//! max_operand_stack would otherwise exceed it.
//!
//! Lifetime: caller-allocated; pair `compute` with `deinit`.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const reg_class = @import("reg_class.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const LiveRange = zir.LiveRange;
const RegClass = zir.RegClass;

pub const Error = error{
    LivenessMissing,
    OutOfMemory,
    SlotOverflow,
};

pub const VerifyError = error{
    SlotsLengthMismatch,
    SlotIndexExceedsCount,
    OverlappingVregsShareSlot,
    /// ADR-0077 — a live vreg's assigned slot id falls inside an
    /// op's `op_scratch_reservation_table` set across the op's
    /// PC range, meaning the op handler's internal scratch
    /// clobber would corrupt the vreg's value mid-emit. Surfaces
    /// only when `verifyWith` is called with a non-null
    /// `scratch_reservations` fence — `verify` (the thin null
    /// wrapper) never returns this variant.
    OpScratchOverlap,
};

/// Per-op scratch reservation lookup (ADR-0077).
///
/// Returns the regalloc slot ids that the op's emit handler
/// will clobber internally as op-internal scratch. Empty slice
/// = no reservation (the common case). The shared regalloc
/// stays arch-agnostic — per-arch tables live in `arm64/abi.zig`
/// / `x86_64/abi.zig` and the emit pipeline supplies the lookup
/// fn at `computeWith` call time. `null` disables the fence
/// (preserves pre-ADR-0077 semantics for callers not wired).
///
/// Returned slot ids MUST be `< force_spill_threshold` (= the
/// per-arch `allocatable_gprs.len`); ids ≥ threshold name spill
/// region, which is unreachable via op-internal clobber. The
/// per-arch comptime `validate_op_scratch_reservation_table`
/// enforces this at build time; runtime
/// `slotForbidden` defensively ignores out-of-range ids.
pub const ScratchReservationFn = *const fn (op: zir.ZirOp) Reservation;

pub const Reservation = struct {
    /// Slots the handler clobbers: no vreg live across the op may hold one.
    scratch: []const u16 = &.{},
    /// Slots the handler writes before it has read every operand: the op's
    /// own operands (last use at its pc) may not hold one either.
    operand: []const u16 = &.{},
};

// forbiddenMaskForVreg + slotForbidden + validateRegallocOpScratchReservation
// + max_slots extracted to `regalloc_compute.zig` per ADR-0098.
// Re-exports below preserve the regalloc.X namespace.

/// Resolved slot — what physical home a vreg lives in.
/// `reg`'s u8 indexes the per-arch `allocatable_gprs` /
/// `allocatable_v_regs` table (interpreted by per-arch
/// `slotToReg` / `fpSlotToReg`). `spill`'s u32 is a byte
/// offset within the function's spill frame (8-aligned).
pub const Slot = union(enum) {
    reg: u8,
    spill: u32,
};

/// Per-vreg shape tag (SIMD-128 per ADR-0041
/// §"Decision" / 2). The slot id alone cannot encode whether
/// a vreg occupies an 8-byte (scalar) or 16-byte (v128)
/// spill stride — per `single_slot_dual_meaning.md` (§14
/// enforcement), shape lives on a separate axis from the
/// slot id. ARM64 NEON `LDR Q<n>` / x86_64 SSE4.1 `MOVDQA`
/// require 16-byte alignment for fast paths; the spill-frame
/// layout queries this tag to size the per-vreg stride.
///
/// 9.4 MVP: `shapeTag(vreg)` returns `.scalar` by default (no
/// per-vreg shape storage yet). 9.5 ARM64 NEON emit will
/// populate `Allocation.shape_tags` from ZirOp metadata when
/// `compute()` runs over a function containing SIMD ops.
pub const ShapeTag = enum(u2) { scalar, v128, _ };

const result_abi_mod = @import("result_abi.zig");

pub const Allocation = struct {
    /// ADR-0106 path (a) — result-marshal ABI for the
    /// JIT-compiled function. `.register_write` (default) = legacy
    /// per-class RAX/RDX (x86_64) / X0..X7,V0..V7 (arm64) epilogue.
    /// `.buffer_write` = ADR-0106 uniform shape (epilogue writes
    /// `results[i]` via the entry-helper's results-ptr arg).
    /// Threaded via Allocation because compile()'s positional
    /// signature has ~358 callsites; wide refactor deferred to a
    /// dedicated `CompileOpts` struct.
    /// Default preserves all existing callsites' behaviour.
    result_abi: result_abi_mod.ResultAbi = .register_write,
    /// `slots[v]` is the dense physical slot id assigned to
    /// vreg `v`. Length matches `func.liveness.?.ranges.len`.
    /// Slot ids are 0..n_slots-1 (no holes).
    ///
    /// **Class interpretation is up to the caller.** The
    /// allocator is class-blind — a single contiguous slot id
    /// space spans every vreg. Per-class boundaries (this struct's
    /// `max_reg_slots_gpr` / `max_reg_slots_fp`) decide whether a
    /// given id resolves to a register or to a spill slot, and
    /// the per-arch `slotToReg` / `fpSlotToReg` decide which
    /// physical register. A future class-aware allocator (Phase 8
    /// follow-up — D-036 §"option (b)") may reuse slot ids
    /// across disjoint classes; today the worst-case spill frame
    /// covers any slot id ≥ `max_reg_slots_gpr`.
    slots: []const u16,
    /// Distinct slots used. `max(slots) + 1`, or 0 for the
    /// empty-function case. Drives stack-frame sizing in the
    /// per-arch emit pass.
    n_slots: u16,
    /// GPR-class boundary: slot ids `< max_reg_slots_gpr` resolve
    /// to `Slot.reg` for class `.gpr`; ids `>= max_reg_slots_gpr`
    /// resolve to `Slot.spill` (per ADR-0018). Default = 8 (ARM64
    /// `allocatable_gprs.len` post-ADR-0027: caller-scratch
    /// X9..X13 (5) + allocatable callee-saved X20..X22 (3) = 8;
    /// X14/X15 reserved as spill stages, X19 / X23..X28 reserved
    /// as runtime invariants).
    max_reg_slots_gpr: u8 = 8,
    /// FP-class boundary: slot ids `< max_reg_slots_fp` resolve to
    /// `Slot.reg` for class `.fpr`; ids `>= max_reg_slots_fp`
    /// resolve to `Slot.spill`. Default = 13 (ARM64
    /// `allocatable_v_regs.len` post-D-037: V16..V28; V29/V30 are
    /// reserved as FP spill stages, V31 reserved for popcnt's
    /// V-register pipeline). Per ADR-0018 amendment
    /// "class-aware boundaries" (D-036): this field replaces the
    /// chunk-q `resolveFp` shim that read `slots[]` directly to
    /// bypass the GPR threshold. The default tracks the per-arch
    /// `allocatable_v_regs.len` manually — `slotToReg` /
    /// `fpSlotToReg` remain authoritative for null-return spill
    /// detection, so a default-default mismatch surfaces as a test
    /// failure rather than silent miscompile.
    max_reg_slots_fp: u8 = 13,
    /// Per-vreg shape tags (per ADR-0041 §"Decision" / 2).
    /// `null` means all vregs are `.scalar` (no SIMD ops in the
    /// function); a populated slice indexes by vreg id. Length when
    /// non-null equals `slots.len`. The MVP leaves this `null`;
    /// ARM64 NEON emit populates it during `compute()` when
    /// the function's ZirInstr stream contains v128 ops.
    shape_tags: ?[]const ShapeTag = null,
    /// Per-slot byte offset table for spill slots
    /// (per ADR-0053 Part 1). When non-null, indexed by `slot_id -
    /// max_reg_slots_gpr` (so `spill_offsets[0]` is the byte offset
    /// of the first spill slot). Populated post-`compute()` when
    /// `shape_tags` is non-null AND at least one slot is occupied
    /// by a v128 vreg — gives v128 spill slots 16-byte alignment +
    /// 16-byte stride, scalar spill slots stay 8-byte. `null` means
    /// "use the legacy uniform `(id - max_reg_slots_gpr) * 8` formula"
    /// — the all-scalar or no-spill case where v128 alignment is
    /// vacuously satisfied.
    spill_offsets: ?[]const u32 = null,

    /// Resolve a vreg's home for the given register class: physical
    /// register slot or spill offset. The class selects which
    /// boundary applies — a slot id ≥ `max_reg_slots_gpr` is spill
    /// for `.gpr` but may still be a V-register for `.fpr` (id ≤
    /// `max_reg_slots_fp - 1`).
    ///
    /// Spill offsets always use the GPR boundary as origin so the
    /// shared spill frame is class-agnostic; spillBytes() returns
    /// `(n_slots - max_reg_slots_gpr) * 8` (worst case — all slots
    /// past the GPR boundary count, even if some are FP regs that
    /// don't actually spill). Tighter accounting lands when the
    /// allocator becomes class-aware (D-036 §"option (b)").
    ///
    /// Special-cache classes (inst_ptr_special / vm_ptr_special /
    /// simd_base_special) and `simd` are not yet handled by the
    /// regalloc — caller passes `.gpr` or `.fpr`. The non-
    /// exhaustive `_` arm of `RegClass` triggers the spec-citation
    /// rule's `else` ban only when these classes start being
    /// allocated; today asserting the supported set is
    /// sufficient.
    pub fn slot(self: Allocation, vreg: usize, class: RegClass) Slot {
        const id = self.slots[vreg];
        const threshold: u16 = switch (class) {
            .gpr => self.max_reg_slots_gpr,
            .fpr => self.max_reg_slots_fp,
            .simd, .inst_ptr_special, .vm_ptr_special, .simd_base_special => self.max_reg_slots_gpr,
            _ => self.max_reg_slots_gpr,
        };
        // `id < threshold` ⇒ id < pool size (≤ 16 today), so the
        // u8 narrowing is provably safe.
        if (id < threshold) return .{ .reg = @intCast(id) };
        // ADR-0053 Part 1 + ADR-0110: when
        // `spill_offsets` is populated, consult the per-slot byte
        // offset table (v128-aware: pre-widen this carried 8/16
        // stride mix; post-Value=16 widen every slot is uniformly
        // 16-byte). Fallback path also returns 16-byte stride
        // post-widen — `Value` is 16 bytes regardless of variant.
        if (self.spill_offsets) |offsets| {
            const spill_idx = id - self.max_reg_slots_gpr;
            return .{ .spill = offsets[spill_idx] };
        }
        return .{ .spill = (@as(u32, id) - self.max_reg_slots_gpr) * 16 };
    }

    /// Total spill-frame bytes required by this allocation.
    /// Adds to the function's stack frame in the prologue.
    /// Uses the GPR boundary as the conservative origin — see
    /// `slot()`'s doc for the per-class accounting subtlety.
    pub fn spillBytes(self: Allocation) u32 {
        if (self.n_slots <= self.max_reg_slots_gpr) return 0;
        // ADR-0053 Part 1: shape-aware total when `spill_offsets`
        // is populated — the last slot's offset plus its own size.
        // Size is 16 for v128 slots, 8 otherwise; recover from the
        // gap between consecutive offsets (or from spill_total when
        // we add it). Cheaper recovery: the last offset + the
        // tail-slot size as recorded at compute time. Embedded
        // here as `offsets[last] + tail_size`; tail_size derives
        // from offsets[last+1] - offsets[last] for non-last slots,
        // but for the final slot we re-read shape via slot id. The
        // shorter approach: keep an implicit assumption that the
        // total is captured by the prologue as
        // `spillBytesFromOffsets(offsets, n_slots, max_reg_slots_gpr,
        // shape_tags)`. To keep the API surface tight today, the
        // 16-byte-rounded total is `align_up(last_offset + 16, 16)`
        // — slightly conservative when the last slot is scalar, but
        // safe (over-allocates by ≤ 8 bytes once per function).
        if (self.spill_offsets) |offsets| {
            if (offsets.len == 0) return 0;
            const last = offsets[offsets.len - 1];
            return std.mem.alignForward(u32, last + 16, 16);
        }
        return (@as(u32, self.n_slots) - self.max_reg_slots_gpr) * 16;
    }

    /// Per-vreg shape tag query (per ADR-0041
    /// §"Decision" / 2). Returns `.scalar` when `shape_tags`
    /// is `null` (no SIMD vregs in the function) or when the
    /// per-vreg slot is unmarked; `.v128` when the vreg's
    /// ZirOp metadata indicates v128. Used by 9.5+ ARM64 NEON
    /// emit + 9.7+ x86_64 SSE4.1 emit for spill-frame stride
    /// selection (8-byte vs 16-byte) and for `LDR Q` / `MOVDQA`
    /// instruction selection vs scalar `LDR D` / `MOVSD`.
    pub fn shapeTag(self: Allocation, vreg: usize) ShapeTag {
        const tags = self.shape_tags orelse return .scalar;
        if (vreg >= tags.len) return .scalar;
        return tags[vreg];
    }
};

// compute + computeWith + computeSpillOffsets + forbiddenMaskForVreg +
// slotForbidden + validateRegallocOpScratchReservation + max_slots +
// ActiveEntry extracted to `regalloc_compute.zig` per ADR-0098.
const compute_mod = @import("regalloc_compute.zig");
pub const max_slots = compute_mod.max_slots;
pub const compute = compute_mod.compute;
pub const computeWith = compute_mod.computeWith;
pub const validateRegallocOpScratchReservation = compute_mod.validateRegallocOpScratchReservation;

/// Post-condition predicate: assert no two overlapping live
/// ranges share a slot. (Naive O(n²) walker — the current scope
/// caps max_operand_stack at 1024, so at most ~1024 vregs in
/// straight-line code). Interval-tree refinement is a
/// follow-up if a profile demands it.
pub fn verify(func: *const ZirFunc, alloc: Allocation) VerifyError!void {
    return verifyWith(func, alloc, null);
}

/// `verify` + ADR-0077 op-scratch-overlap post-condition.
///
/// When `scratch_reservations` is non-null, additionally emits
/// `OpScratchOverlap` if a live vreg's assigned slot id falls in
/// a reservation its range meets. The mask is the one
/// `computeWith` builds, so verification fires
/// iff the walker should have skipped the slot id but didn't —
/// the canonical regression check for a buggy fence
/// integration. Spill slots (id ≥ `force_spill_threshold`,
/// derived from `alloc.max_reg_slots_gpr`) are exempt: they
/// never resolve to a clobberable register.
pub fn verifyWith(
    func: *const ZirFunc,
    alloc: Allocation,
    scratch_reservations: ?ScratchReservationFn,
) VerifyError!void {
    const live = func.liveness orelse return;
    if (alloc.slots.len != live.ranges.len) return VerifyError.SlotsLengthMismatch;
    for (alloc.slots) |s| {
        if (s >= alloc.n_slots) return VerifyError.SlotIndexExceedsCount;
    }
    for (live.ranges, 0..) |a, ai| {
        for (live.ranges[ai + 1 ..], ai + 1..) |b, bi| {
            // Strict half-open overlap: [a.def, a.use) ∩ [b.def, b.use).
            const overlaps = (a.def_pc < b.last_use_pc) and (b.def_pc < a.last_use_pc);
            if (overlaps and alloc.slots[ai] == alloc.slots[bi]) {
                return VerifyError.OverlappingVregsShareSlot;
            }
        }
    }
    if (scratch_reservations) |fence| {
        const force_spill_threshold: u16 = alloc.max_reg_slots_gpr;
        for (live.ranges, 0..) |r, vreg| {
            const sid = alloc.slots[vreg];
            if (sid >= force_spill_threshold or sid >= 16) continue;
            const mask = compute_mod.forbiddenMaskForVreg(func.instrs.items, r, fence);
            if (mask & (@as(u16, 1) << @intCast(sid)) != 0) return VerifyError.OpScratchOverlap;
        }
    }
}

pub fn deinit(allocator: Allocator, alloc: Allocation) void {
    if (alloc.slots.len != 0) allocator.free(alloc.slots);
    if (alloc.shape_tags) |tags| if (tags.len != 0) allocator.free(tags);
    if (alloc.spill_offsets) |so| if (so.len != 0) allocator.free(so);
}

// populateShapeTags extracted to `regalloc_shape_tags.zig` per
// ADR-0090. Re-exported so callers reach
// `regalloc.populateShapeTags` unchanged.
const shape_tags_mod = @import("regalloc_shape_tags.zig");
pub const populateShapeTags = shape_tags_mod.populateShapeTags;

// reg_class is the upstream-class-aware refinement hook used by
// the per-arch wiring; reference it so `no_unused`
// linting is happy until the wiring lands.
comptime {
    _ = reg_class;
}

// VregClass + vregClassByDef + vregClassOfOp extracted to
// `regalloc_vreg_class.zig` per ADR-0092. Re-exported here so
// callers reach `regalloc.VregClass` / `regalloc.vregClassByDef`
// unchanged.
const vreg_class_mod = @import("regalloc_vreg_class.zig");
pub const VregClass = vreg_class_mod.VregClass;
pub const vregClassByDef = vreg_class_mod.vregClassByDef;

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn freshFunc() ZirFunc {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    return ZirFunc.init(0, sig, &.{});
}

// compute tests moved to `regalloc_compute.zig` per ADR-0098.

/// Local copy of the regalloc-side fence-table stub used by the
/// compute-side fence tests. Reserves slots {0..4} for
/// `.@"table.fill"` (mirrors the production reservation set per
/// the live-scratch census). Kept duplicated rather than
/// pub-ifying the regalloc.zig test helper.
fn testFenceTableFill(op: zir.ZirOp) Reservation {
    const reservation = [_]u16{ 0, 1, 2, 3, 4 };
    return if (op == .@"table.fill") .{ .scratch = &reservation } else .{};
}

test "verify: rejects allocation with slot index >= n_slots" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }};
    f.liveness = .{ .ranges = &ranges };
    const bad_slots = [_]u16{5};
    const bad: Allocation = .{ .slots = &bad_slots, .n_slots = 1 };
    try testing.expectError(VerifyError.SlotIndexExceedsCount, verify(&f, bad));
}

test "verify: rejects mismatched slot/range lengths" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }};
    f.liveness = .{ .ranges = &ranges };
    const bad_slots = [_]u16{ 0, 1 };
    const bad: Allocation = .{ .slots = &bad_slots, .n_slots = 2 };
    try testing.expectError(VerifyError.SlotsLengthMismatch, verify(&f, bad));
}

test "verify: rejects overlapping ranges sharing a slot" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 5 },
        .{ .def_pc = 1, .last_use_pc = 4 },
    };
    f.liveness = .{ .ranges = &ranges };
    const bad_slots = [_]u16{ 0, 0 };
    const bad: Allocation = .{ .slots = &bad_slots, .n_slots = 1 };
    try testing.expectError(VerifyError.OverlappingVregsShareSlot, verify(&f, bad));
}

test "verifyWith: detects op-scratch overlap on hand-broken allocation" {
    // Same shape as the fence test, but inject an allocation that
    // bypasses the fence (slot 0 for a vreg crossing table.fill).
    // verifyWith with the fence active must catch it; verify
    // without the fence accepts it (back-compat).
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

    const broken_slots = [_]u16{0};
    const broken: Allocation = .{ .slots = &broken_slots, .n_slots = 1 };
    try testing.expectError(VerifyError.OpScratchOverlap, verifyWith(&f, broken, testFenceTableFill));
    // Back-compat: verify (null fence) accepts the same allocation.
    try verify(&f, broken);
}

test "verifyWith: spill-region slot ids are exempt from the post-condition" {
    // A vreg parked in the spill region (slot >= max_reg_slots_gpr)
    // cannot collide with op-internal scratch — the spill stage
    // regs are X14/X15, outside `allocatable_gprs`. Verifier
    // must not flag this.
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .@"table.fill" });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
    };
    f.liveness = .{ .ranges = &ranges };

    // Slot 9 is spill territory under the default max_reg_slots_gpr=8.
    const spilled_slots = [_]u16{9};
    const spilled: Allocation = .{ .slots = &spilled_slots, .n_slots = 10 };
    try verifyWith(&f, spilled, testFenceTableFill);
}

// ========================================================
// ADR-0018: Slot resolution + spill-frame sizing
// ========================================================

test "Allocation.slot: id < max_reg_slots_gpr resolves to .reg for class .gpr" {
    const slots = [_]u16{ 0, 5, 9 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 10, .max_reg_slots_gpr = 10 };
    try testing.expectEqual(Slot{ .reg = 0 }, alloc.slot(0, .gpr));
    try testing.expectEqual(Slot{ .reg = 5 }, alloc.slot(1, .gpr));
    try testing.expectEqual(Slot{ .reg = 9 }, alloc.slot(2, .gpr));
}

test "Allocation.slot: id >= max_reg_slots_gpr resolves to .spill at 16-aligned offset" {
    const slots = [_]u16{ 9, 10, 11, 12 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 13, .max_reg_slots_gpr = 10 };
    try testing.expectEqual(Slot{ .reg = 9 }, alloc.slot(0, .gpr));
    try testing.expectEqual(Slot{ .spill = 0 }, alloc.slot(1, .gpr));
    // Post-ADR-0110 widen: stride is 16-byte (matches @sizeOf(Value) == 16).
    try testing.expectEqual(Slot{ .spill = 16 }, alloc.slot(2, .gpr));
    try testing.expectEqual(Slot{ .spill = 32 }, alloc.slot(3, .gpr));
}

test "Allocation.spillBytes: 0 when n_slots fits in pool" {
    const slots = [_]u16{ 0, 1 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 2, .max_reg_slots_gpr = 10 };
    try testing.expectEqual(@as(u32, 0), alloc.spillBytes());
}

test "Allocation.spillBytes: 16-byte stride past pool size (post-ADR-0110)" {
    const slots = [_]u16{ 9, 10, 11, 12 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 13, .max_reg_slots_gpr = 10 };
    try testing.expectEqual(@as(u32, 48), alloc.spillBytes()); // (13-10)*16
}

// ========================================================
// D-036: Class-aware slot resolution (chunk-d036)
// ========================================================

test "Allocation.slot: same id resolves to .reg for .fpr but .spill for .gpr (class-aware boundaries)" {
    const slots = [_]u16{ 0, 7, 8, 12 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 13 };
    // class .gpr — boundary at 8 (default max_reg_slots_gpr)
    try testing.expectEqual(Slot{ .reg = 0 }, alloc.slot(0, .gpr));
    try testing.expectEqual(Slot{ .reg = 7 }, alloc.slot(1, .gpr));
    try testing.expectEqual(Slot{ .spill = 0 }, alloc.slot(2, .gpr));
    try testing.expectEqual(Slot{ .spill = 64 }, alloc.slot(3, .gpr)); // (12 - 8) * 16
    // class .fpr — boundary at 13 (default max_reg_slots_fp); same ids stay in regs
    try testing.expectEqual(Slot{ .reg = 0 }, alloc.slot(0, .fpr));
    try testing.expectEqual(Slot{ .reg = 7 }, alloc.slot(1, .fpr));
    try testing.expectEqual(Slot{ .reg = 8 }, alloc.slot(2, .fpr));
    try testing.expectEqual(Slot{ .reg = 12 }, alloc.slot(3, .fpr));
}

test "Allocation.slot: id >= max_reg_slots_fp resolves to .spill for .fpr" {
    const slots = [_]u16{ 12, 13, 14 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 15 };
    try testing.expectEqual(Slot{ .reg = 12 }, alloc.slot(0, .fpr));
    // FP spill: id >= 13 → .spill, offset uses GPR boundary as origin
    // so the shared spill frame is class-agnostic. Stride is 16-byte
    // post-ADR-0110 widen.
    try testing.expectEqual(Slot{ .spill = (13 - 8) * 16 }, alloc.slot(1, .fpr));
    try testing.expectEqual(Slot{ .spill = (14 - 8) * 16 }, alloc.slot(2, .fpr));
}

test "Allocation.slot: spill offset is class-agnostic (shared frame origin = max_reg_slots_gpr)" {
    // A function with mixed GPR/FP vregs sharing a spill frame:
    // GPR vreg at slot 8 → spill 0; FP vreg at slot 14 → spill 96.
    // Even though FP doesn't *actually* spill at slot 8..12
    // (those are V-regs), the offset formula stays consistent so
    // the prologue can size the frame from spillBytes() alone.
    // Stride is 16-byte post-ADR-0110 widen.
    const slots = [_]u16{ 8, 14 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 15 };
    try testing.expectEqual(Slot{ .spill = 0 }, alloc.slot(0, .gpr));
    try testing.expectEqual(Slot{ .spill = (14 - 8) * 16 }, alloc.slot(1, .fpr));
}

// ============================================================
// D-461 rework Phase II (ADR-0153) — characterization of the
// `slot()`-THROUGH-`spill_offsets` resolve path. Before this, every
// slot()/spillBytes test used the NULL-spill_offsets fallback formula;
// the populated-array branch (regalloc.zig:221 `offsets[id - gpr]`, the
// exact site of the x86_64 FP-spill OOB) had ZERO direct unit coverage.
// These pin the WORKING contract (sizing origin == resolve field) so the
// arch-parameterization rework cannot silently regress it. The DIVERGENT
// origin case (x86_64 field=4 vs sized origin=8) is the bug — its red→green
// lands in Phase IV once the design fixes the origin accounting.
// ============================================================

test "D-461 char: slot() through populated spill_offsets returns the array entry (GPR, consistent origin)" {
    // spill_offsets covers spill ids [8..13] (origin = max_reg_slots_gpr = 8);
    // a v128-aware compute would emit these 16-byte-strided byte offsets.
    const offsets = [_]u32{ 0, 16, 32, 48, 64, 80 };
    const slots = [_]u16{ 8, 10, 13 };
    const alloc: Allocation = .{
        .slots = &slots,
        .n_slots = 14,
        .spill_offsets = &offsets,
    };
    // id 8 → offsets[8-8]=offsets[0]; id 10 → offsets[2]; id 13 → offsets[5].
    try testing.expectEqual(Slot{ .spill = 0 }, alloc.slot(0, .gpr));
    try testing.expectEqual(Slot{ .spill = 32 }, alloc.slot(1, .gpr));
    try testing.expectEqual(Slot{ .spill = 80 }, alloc.slot(2, .gpr));
}

test "D-461 char: slot() through spill_offsets for FPR spill past the FP boundary (consistent origin)" {
    // Default fp boundary = 13; ids < 13 are FP registers, id >= 13 spills.
    // The spill_offsets index is still GPR-origin (id - 8), so the FP spill
    // at id 13 lands at offsets[5]. This is the class-agnostic shared frame.
    const offsets = [_]u32{ 0, 16, 32, 48, 64, 80 };
    const slots = [_]u16{ 12, 13 };
    const alloc: Allocation = .{
        .slots = &slots,
        .n_slots = 14,
        .spill_offsets = &offsets,
    };
    try testing.expectEqual(Slot{ .reg = 12 }, alloc.slot(0, .fpr)); // 12 < 13 → register
    try testing.expectEqual(Slot{ .spill = 80 }, alloc.slot(1, .fpr)); // 13 → offsets[13-8]=offsets[5]
}

test "D-461 char: spillBytes through spill_offsets = align_up(last + 16, 16)" {
    const offsets = [_]u32{ 0, 16, 32 };
    const slots = [_]u16{ 8, 9, 10 };
    const alloc: Allocation = .{
        .slots = &slots,
        .n_slots = 11,
        .spill_offsets = &offsets,
    };
    // last offset 32 + 16 = 48, already 16-aligned.
    try testing.expectEqual(@as(u32, 48), alloc.spillBytes());
}

test "D-461/ADR-0194: x86_64-origin (max_reg_slots_gpr=4) consistent allocation resolves FP spill in-bounds" {
    // Post-ADR-0194, `computeWith` sizes `spill_offsets` from the per-arch
    // `max_reg_slots_gpr` (4 on x86_64), so the array covers ids [4, n_slots)
    // and `slot()` indexes `id - 4` consistently — the divergent-origin OOB
    // (was: sized origin-8 vs resolve origin-4) is gone. Pins that resolve is
    // correct for a non-8 origin (the other characterization tests cover only
    // the arm64 origin-8 case). End-to-end OOB fix verified by the
    // `runner_gc_test` 12-live-v128 fixture under x86_64.
    const offsets = [_]u32{ 0, 16, 32, 48, 64, 80, 96, 112, 128 }; // sized n_slots(13) - origin(4) = 9
    const slots = [_]u16{9};
    const alloc: Allocation = .{
        .slots = &slots,
        .n_slots = 13,
        .max_reg_slots_gpr = 4, // x86_64 GPR pool (= the spill-frame origin)
        .max_reg_slots_fp = 6, // x86_64 XMM pool
        .spill_offsets = &offsets,
    };
    // FP vreg id 9 → 9 >= 6 (fp boundary) → spill → offsets[9 - 4] = offsets[5] = 80, in-bounds.
    try testing.expectEqual(Slot{ .spill = 80 }, alloc.slot(0, .fpr));
}

// ============================================================
// ShapeTag API tests (per ADR-0041 §"Decision" / 2)
// ============================================================

test "Allocation.shapeTag: returns .scalar when shape_tags is null" {
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 3 };
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(0));
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(1));
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(2));
}

test "Allocation.shapeTag: returns per-vreg tag from populated slice" {
    const slots = [_]u16{ 0, 1, 2 };
    const tags = [_]ShapeTag{ .scalar, .v128, .scalar };
    const alloc: Allocation = .{
        .slots = &slots,
        .n_slots = 3,
        .shape_tags = &tags,
    };
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(0));
    try testing.expectEqual(ShapeTag.v128, alloc.shapeTag(1));
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(2));
}

test "Allocation.shapeTag: out-of-range vreg returns .scalar" {
    const slots = [_]u16{0};
    const tags = [_]ShapeTag{.v128};
    const alloc: Allocation = .{
        .slots = &slots,
        .n_slots = 1,
        .shape_tags = &tags,
    };
    try testing.expectEqual(ShapeTag.v128, alloc.shapeTag(0));
    // Out-of-range — defensive default, not a hard error.
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(99));
}

// ============================================================
// populateShapeTags tests (per ADR-0041
// §"Decision" / 2)
// ============================================================

test "populateShapeTags: no SIMD ops returns null" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 1);
    try testing.expect(tags == null);
}

test "populateShapeTags: i32x4.splat produces a v128 vreg" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    // i32.const 7 (vreg 0, scalar) ; i32x4.splat (vreg 1, v128) ; end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32x4.splat" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 2);
    try testing.expect(tags != null);
    defer testing.allocator.free(tags.?);
    try testing.expectEqual(@as(usize, 2), tags.?.len);
    try testing.expectEqual(ShapeTag.scalar, tags.?[0]);
    try testing.expectEqual(ShapeTag.v128, tags.?[1]);
}

test "populateShapeTags: v128.const + i32x4.add produces 2 v128 vregs" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    // v128.const (vreg 0) ; v128.const (vreg 1) ; i32x4.add (vreg 2) ; end
    try f.instrs.append(testing.allocator, .{ .op = .@"v128.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"v128.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32x4.add" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 3);
    try testing.expect(tags != null);
    defer testing.allocator.free(tags.?);
    try testing.expectEqual(@as(usize, 3), tags.?.len);
    try testing.expectEqual(ShapeTag.v128, tags.?[0]);
    try testing.expectEqual(ShapeTag.v128, tags.?[1]);
    try testing.expectEqual(ShapeTag.v128, tags.?[2]);
}

test "populateShapeTags: extract_lane produces scalar from v128" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    // v128.const (vreg 0, v128) ; i32x4.extract_lane (vreg 1, scalar) ; end
    try f.instrs.append(testing.allocator, .{ .op = .@"v128.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32x4.extract_lane" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 2);
    try testing.expect(tags != null);
    defer testing.allocator.free(tags.?);
    try testing.expectEqual(@as(usize, 2), tags.?.len);
    try testing.expectEqual(ShapeTag.v128, tags.?[0]);
    try testing.expectEqual(ShapeTag.scalar, tags.?[1]);
}

test "populateShapeTags: empty func returns null (no SIMD)" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 0);
    try testing.expect(tags == null);
}

test "populateShapeTags: D-061 — v128 params trigger populate via local.get tagging" {
    // simd_select.0 fixture shape: (v128, v128, i32) → v128 with
    // body `local.get 0; local.get 1; local.get 2; select; end`.
    // Without D-061 fix populateShapeTags would return null
    // (no SIMD op in body) and arm64/emit's select handler would
    // dispatch through the .scalar branch — UnsupportedOp.
    const params = [_]zir.ValType{ .v128, .v128, .i32 };
    const results = [_]zir.ValType{.v128};
    const sig: zir.FuncType = .{ .params = &params, .results = &results };
    var f = zir.ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 2 });
    try f.instrs.append(testing.allocator, .{ .op = .select });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 4);
    try testing.expect(tags != null);
    defer testing.allocator.free(tags.?);
    try testing.expectEqual(@as(usize, 4), tags.?.len);
    try testing.expectEqual(ShapeTag.v128, tags.?[0]); // local.get 0 → v128 param
    try testing.expectEqual(ShapeTag.v128, tags.?[1]); // local.get 1 → v128 param
    try testing.expectEqual(ShapeTag.scalar, tags.?[2]); // local.get 2 → i32 param
    // tags[3] is `select`'s result; left .scalar today
    // (per-vreg type-flow tracking via operand-stack simulation
    // is a separate enhancement — see populateShapeTags doc).
}

test "populateShapeTags: scalar binop between SIMD ops keeps vreg numbering aligned" {
    // i32x4.splat (v128 vreg 0)
    // i32.const   (scalar vreg 1)
    // i32.add     (scalar vreg 2 — pre-D-061 walk would NOT
    //              increment, drifting tags[3] for the next push)
    // i32x4.splat (v128 vreg 3)
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32x4.splat" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .drop });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32x4.splat" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 7);
    try testing.expect(tags != null);
    defer testing.allocator.free(tags.?);
    // vreg layout (def-order): 0=i32.const, 1=i32x4.splat,
    // 2=i32.const, 3=i32.const, 4=i32.add, 5=i32.const, 6=i32x4.splat.
    // Seven pushes; tags[1] = v128, tags[6] = v128.
    try testing.expectEqual(ShapeTag.scalar, tags.?[0]);
    try testing.expectEqual(ShapeTag.v128, tags.?[1]);
    try testing.expectEqual(ShapeTag.scalar, tags.?[2]);
    try testing.expectEqual(ShapeTag.scalar, tags.?[3]);
    try testing.expectEqual(ShapeTag.scalar, tags.?[4]);
    try testing.expectEqual(ShapeTag.scalar, tags.?[5]);
    try testing.expectEqual(ShapeTag.v128, tags.?[6]);
}

// compute+shape_tags / spill_offsets / computeSpillOffsets / fence /
// validateRegallocOpScratchReservation tests moved to
// `regalloc_compute.zig` per ADR-0098.
