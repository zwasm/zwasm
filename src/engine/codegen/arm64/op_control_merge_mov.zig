//! Merge-move helpers for ARM64 control-flow emit handlers —
//! extracted from `op_control.zig` per ADR-0093.
//!
//! Private helper cluster: the parallel assignment an edge makes into
//! a merge (`emitMergeMoves`) + per-move emitter + branch-merge
//! capturer + arity unpacker. Used only by `op_control.zig`'s emit
//! handlers (block / loop / br / br_if / br_table / if / else / end)
//! and the `br_on_*` ops. Pub-ified for cross-file access.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const ctx_mod = @import("ctx.zig");
const abi = @import("abi.zig");
const inst = @import("inst.zig");
const inst_fp = @import("inst_fp.zig");
const gpr = @import("gpr.zig");
const inst_neon = @import("inst_neon.zig");
const regalloc = @import("../shared/regalloc.zig");
const parallel_move = @import("../shared/parallel_move.zig");
const dbg = @import("../../../support/dbg.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

/// The park registers a set of merge moves breaks a cycle through. Neither
/// is in the regalloc pool or a spill stage (`emitMergeMov` stages through
/// those), and a set runs between ops on the path that leaves for the merge,
/// so nothing else holds them.
const park_gpr: inst.Xn = 16;
const park_v: inst.Vn = 31;

comptime {
    for (abi.allocatable_gprs ++ abi.spill_stage_gprs) |r| {
        if (r == park_gpr) @compileError("park_gpr is a pool or spill-stage register");
    }
    for (abi.allocatable_v_regs ++ abi.fp_spill_stage_vregs) |r| {
        if (r == park_v) @compileError("park_v is a pool or spill-stage register");
    }
}

/// The spill stages one merge move goes through: source, destination.
const stage_src: u8 = 1;
const stage_dst: u8 = 0;

/// `emitMergeMov` picks the register class from the merge vreg, for both
/// operands.
fn mergeInV(alloc: regalloc.Allocation, func: *const ZirFunc, merge_vreg: u32) bool {
    return alloc.shapeTag(merge_vreg) == .v128 or regalloc.vregClass(func, merge_vreg) == .fpr;
}

/// The place `vreg` lives in, as a `parallel_move` key: equal for one
/// register or one spill cell, unequal otherwise.
fn placeKey(alloc: regalloc.Allocation, vreg: u32, v: bool) Error!u64 {
    return switch (alloc.slot(vreg, if (v) .fpr else .gpr)) {
        .spill => |off| (2 << 32) | @as(u64, off),
        .reg => |id| if (v)
            (1 << 32) | @as(u64, abi.fpSlotToReg(id) orelse return Error.SlotOverflow)
        else
            abi.slotToReg(id) orelse return Error.SlotOverflow,
    };
}

/// Move `srcs[i]` into `dsts[i]` for every i as one parallel assignment: no
/// move reads a place an earlier one wrote. Every edge that delivers values
/// to a merge (a frame's merge vregs, or the params of a loop or of an `if`
/// with no else) moves them through here. Mirror of x86_64's
/// `emitMergeMoves`.
///
/// Besides its destinations a set writes the park registers and the spill
/// stages. `read_after` names a register the caller reads after the set, on
/// the path that runs it (a branch condition it has not tested yet); a set
/// that would write it is refused. A caller that has consumed its condition
/// passes null: `br_on_null` hands `branchOnReg` its condition in X16, the
/// GPR park, and `branchOnReg` tests it before any move.
// SIBLING-PUB: op_control.zig (per ADR-0093 extraction)
pub fn emitMergeMoves(ctx: *EmitCtx, srcs: []const u32, dsts: []const u32, read_after: ?inst.Xn) Error!void {
    return moveSet(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, ctx.func, srcs, dsts, read_after);
}

fn moveSet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    func: *const ZirFunc,
    srcs: []const u32,
    dsts: []const u32,
    read_after: ?inst.Xn,
) Error!void {
    var from: [parallel_move.cap]u32 = undefined;
    var to: [parallel_move.cap]u32 = undefined;
    var src_keys: [parallel_move.cap]u64 = undefined;
    var dst_keys: [parallel_move.cap]u64 = undefined;
    var n: usize = 0;
    for (srcs, dsts) |src, dst| {
        if (src == dst) continue;
        const v = mergeInV(alloc, func, dst);
        const src_key = try placeKey(alloc, src, v);
        const dst_key = try placeKey(alloc, dst, v);
        if (src_key == dst_key) continue;
        if (n == parallel_move.cap) {
            dbg.print("codegen", "arm64/op_control_merge_mov: more than {d} merge moves in one set\n", .{parallel_move.cap});
            return Error.UnsupportedOp;
        }
        from[n] = src;
        to[n] = dst;
        src_keys[n] = src_key;
        dst_keys[n] = dst_key;
        n += 1;
    }
    if (n == 0) return;
    if (read_after) |r| {
        if (r == park_gpr or std.mem.findScalar(inst.Xn, &abi.spill_stage_gprs, r) != null or
            std.mem.findScalar(u64, dst_keys[0..n], r) != null)
        {
            dbg.print("codegen", "arm64/op_control_merge_mov: merge moves would write X{d}, read after them\n", .{r});
            return Error.UnsupportedOp;
        }
    }
    var steps_buf: [2 * parallel_move.cap]parallel_move.Step = undefined;
    const steps = parallel_move.schedule(src_keys[0..n], dst_keys[0..n], &steps_buf) catch |err| switch (err) {
        error.RepeatedDestination, error.ParkHeld => {
            dbg.print("codegen", "arm64/op_control_merge_mov: merge moves are not a parallel assignment ({s})\n", .{@errorName(err)});
            return Error.UnsupportedOp;
        },
    };
    var parked: [parallel_move.cap]bool = @splat(false);
    for (steps) |step| switch (step) {
        .park => |i| {
            if (alloc.shapeTag(to[i]) == .v128) {
                const src_v = try gpr.qLoadSpilled(allocator, buf, alloc, spill_base_off, from[i], stage_src);
                try gpr.writeU32(allocator, buf, inst_neon.encMovV16B(park_v, src_v));
            } else if (mergeInV(alloc, func, to[i])) {
                const src_v = try gpr.fpLoadSpilled(allocator, buf, alloc, spill_base_off, from[i], stage_src);
                try gpr.writeU32(allocator, buf, inst_fp.encFmovDReg(park_v, src_v));
            } else {
                const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, from[i], stage_src);
                try gpr.writeU32(allocator, buf, inst.encOrrReg(park_gpr, 31, src_r));
            }
            parked[i] = true;
        },
        .move => |i| try emitMergeMov(allocator, buf, alloc, spill_base_off, func, if (parked[i]) null else from[i], to[i]),
    };
}

/// D-097 (ADR-0060 follow-up): unified merge-MOV dispatcher.
///
/// Copies `src_vreg`'s value into `merge_vreg`'s storage. Picks the
/// right register-class path:
///   - `.v128` (per `alloc.shapeTag`)  → q-form (16-byte) MOV
///   - `.fpr`  (per `regalloc.vregClass`) → FMOV D (8-byte)
///   - `.gpr`  (default)                → 32-bit ORR (legacy)
///
/// Earlier code only dispatched on `.v128` — FP scalar fell through
/// to GPR MOV which silently corrupted f32/f64 if-frame merges
/// because the GPR view of an FP slot is a different physical
/// register on both arm64 (X_n vs V_n) and x86_64 (RBX vs XMM8
/// etc.). compose_no_call.wat on x86_64 + the 8 x86_64-specific
/// `if.wast` residuals all traced back to this single gap.
///
/// `stage_src` / `stage_dst` index the per-class spill stage
/// register pool so concurrent loads + defs of the same class
/// never alias (R10/R11 on x86_64, X14/X15 on arm64; V29/V30
/// for FP / v128 stage on arm64; XMM14/XMM15 on x86_64).
///
/// One move of an `emitMergeMoves` set; a null `src_vreg` reads the park
/// register.
fn emitMergeMov(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    func: *const ZirFunc,
    src_vreg: ?u32,
    merge_vreg: u32,
) Error!void {
    if (alloc.shapeTag(merge_vreg) == .v128) {
        const src_v = if (src_vreg) |v| try gpr.qLoadSpilled(allocator, buf, alloc, spill_base_off, v, stage_src) else park_v;
        const merge_v = try gpr.qDefSpilled(alloc, merge_vreg, stage_dst);
        if (merge_v != src_v) {
            try gpr.writeU32(allocator, buf, inst_neon.encMovV16B(merge_v, src_v));
        }
        try gpr.qStoreSpilled(allocator, buf, alloc, spill_base_off, merge_vreg, stage_dst);
        return;
    }
    if (regalloc.vregClass(func, merge_vreg) == .fpr) {
        const src_v = if (src_vreg) |v| try gpr.fpLoadSpilled(allocator, buf, alloc, spill_base_off, v, stage_src) else park_v;
        const merge_v = try gpr.fpDefSpilled(alloc, merge_vreg, stage_dst);
        if (merge_v != src_v) {
            try gpr.writeU32(allocator, buf, inst_fp.encFmovDReg(merge_v, src_v));
        }
        try gpr.fpStoreSpilled(allocator, buf, alloc, spill_base_off, merge_vreg, stage_dst);
        return;
    }
    const src_r = if (src_vreg) |v| try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, v, stage_src) else park_gpr;
    const merge_r = try gpr.gprDefSpilled(alloc, merge_vreg, stage_dst);
    if (merge_r != src_r) {
        // X-form (64-bit) ORR — preserves all 64 bits. W-form would
        // truncate upper 32 bits on i64 vregs; for i32 the upper
        // bits are don't-care per AAPCS64, so X-form is safe for
        // both. (Earlier the else_open merge path used W-form
        // throughout — load-bearing for i32 corpus but quietly
        // wrong for i64. The implicit-else path had to
        // re-derive the same fix locally; the unified merge
        // helper now applies it everywhere.)
        try gpr.writeU32(allocator, buf, inst.encOrrReg(merge_r, 31, src_r));
    }
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, merge_vreg, stage_dst);
}

/// Block-merge mechanism for forward `br` / `br_if` to a
/// `block (result T..)` target. Mirrors the if/else
/// `merge_top_vregs` mechanism (D-027 + D-035)
/// extended to `.block` per D-093.
///
/// On the FIRST forward branch to a block label with
/// `result_arity > 0`, captures the top `arity` vregs as the
/// canonical merge target. No MOV is emitted: the captured
/// vregs ARE the merge target (the operand stack is already
/// in the right slots).
///
/// On SUBSEQUENT forward branches, emits `arity` MOVs from
/// the current top `arity` vregs into the captured merge
/// target's physical registers, so all paths through the
/// block end on the same regs. Post-block consumers then
/// read from `merge_top_vregs`.
///
/// Returns `true` when MOVs were emitted (caller is a second-
/// or-later br/br_if and must structure its branch
/// accordingly — br_if wraps MOVs+B inside a CBZ skip so
/// the fall-through path doesn't run them).
///
/// No-op when the target is not `.block` or `result_arity ==
/// 0` (legacy single-arm shapes).
// SIBLING-PUB: op_control.zig, br_on_null.zig, br_on_non_null.zig (per ADR-0093 extraction; ops/wasm_3_0/br_on_null.zig sibling — same merge semantics for the null-branch path; br_on_non_null.zig — label expects k+1 values including the ref)
pub fn captureOrEmitBlockMergeMov(ctx: *EmitCtx, tgt_idx: usize, read_after: ?inst.Xn) Error!bool {
    const arity: u32 = ctx.labels.items[tgt_idx].result_arity;
    if (arity == 0) return false;
    // D-096: br inside if-arm targets the if-frame. The br
    // skips past .end so the .end merge MOV never runs; the br
    // must carry the value into the if-frame's result slot itself.
    // Same shape as block-target br: capture top vregs on first br,
    // MOV from current top on subsequent brs (after .else has
    // captured merge_top_vregs).
    const kind = ctx.labels.items[tgt_idx].kind;
    if (kind != .block and kind != .if_then and kind != .else_open) return false;
    if (ctx.pushed_vregs.items.len < arity) return Error.AllocationMissing;

    if (!ctx.labels.items[tgt_idx].merge_captured) {
        const base = ctx.pushed_vregs.items.len - arity;
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            ctx.labels.items[tgt_idx].merge_top_vregs[i] = ctx.pushed_vregs.items[base + i];
        }
        ctx.labels.items[tgt_idx].merge_captured = true;
        return false;
    }

    const base = ctx.pushed_vregs.items.len - arity;
    try emitMergeMoves(ctx, ctx.pushed_vregs.items[base..][0..arity], ctx.labels.items[tgt_idx].merge_top_vregs[0..arity], read_after);
    return true;
}

/// Unpack `(param_arity, result_arity)` from a block-open
/// ZirInstr's `extra` field. Per lower.zig's `readBlockType`
/// the packing is `(params << 8) | results`, both u8.
// SIBLING-PUB: op_control.zig (per ADR-0093 extraction)
pub fn unpackBlockArity(extra: u32) struct { params: u8, results: u8 } {
    return .{
        .params = @intCast((extra >> 8) & 0xFF),
        .results = @intCast(extra & 0xFF),
    };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn funcWithClasses(classes: []const zir.RegClass) ZirFunc {
    var f = ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    f.liveness = .{ .classes = classes };
    return f;
}

fn expectWords(want: []const u32, got: []const u8) !void {
    try testing.expectEqual(want.len * 4, got.len);
    for (want, 0..) |w, i| try testing.expectEqual(w, std.mem.readInt(u32, got[i * 4 ..][0..4], .little));
}

test "moveSet: two GPRs that trade places go through X16" {
    var f = funcWithClasses(&.{ .gpr, .gpr });
    defer f.deinit(testing.allocator);
    const alloc: regalloc.Allocation = .{ .slots = &.{ 0, 1 }, .n_slots = 2 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try moveSet(testing.allocator, &buf, alloc, 32, &f, &.{ 0, 1 }, &.{ 1, 0 }, null);

    const a = abi.allocatable_gprs[0];
    const b = abi.allocatable_gprs[1];
    try expectWords(&.{
        inst.encOrrReg(16, 31, b),
        inst.encOrrReg(b, 31, a),
        inst.encOrrReg(a, 31, 16),
    }, buf.items);
}

test "moveSet: two spilled f64s that trade places go through V31" {
    var f = funcWithClasses(&.{ .fpr, .fpr });
    defer f.deinit(testing.allocator);
    // Slot ids 13 and 14 are past the thirteen V homes: spill cells at 80 and 96.
    const alloc: regalloc.Allocation = .{ .slots = &.{ 13, 14 }, .n_slots = 15 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try moveSet(testing.allocator, &buf, alloc, 32, &f, &.{ 0, 1 }, &.{ 1, 0 }, null);

    try expectWords(&.{
        inst.encLdrDImm(30, 31, 128),
        inst_fp.encFmovDReg(31, 30),
        inst.encLdrDImm(30, 31, 112),
        inst_fp.encFmovDReg(29, 30),
        inst.encStrDImm(29, 31, 128),
        inst_fp.encFmovDReg(29, 31),
        inst.encStrDImm(29, 31, 112),
    }, buf.items);
}

test "moveSet: two spilled v128s that trade places go through V31" {
    var f = funcWithClasses(&.{ .simd, .simd });
    defer f.deinit(testing.allocator);
    const alloc: regalloc.Allocation = .{ .slots = &.{ 13, 14 }, .n_slots = 15, .shape_tags = &.{ .v128, .v128 } };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try moveSet(testing.allocator, &buf, alloc, 32, &f, &.{ 0, 1 }, &.{ 1, 0 }, null);

    try expectWords(&.{
        inst_neon.encLdrQImm(30, 31, 128),
        inst_neon.encMovV16B(31, 30),
        inst_neon.encLdrQImm(30, 31, 112),
        inst_neon.encMovV16B(29, 30),
        inst_neon.encStrQImm(29, 31, 128),
        inst_neon.encMovV16B(29, 31),
        inst_neon.encStrQImm(29, 31, 112),
    }, buf.items);
}

test "moveSet: a set that would write a register the caller reads after it is refused" {
    var f = funcWithClasses(&.{ .gpr, .gpr });
    defer f.deinit(testing.allocator);
    const alloc: regalloc.Allocation = .{ .slots = &.{ 0, 1 }, .n_slots = 2 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // The park, the spill stages, and the destination's own register.
    for ([_]inst.Xn{ park_gpr, abi.allocatable_gprs[1] } ++ abi.spill_stage_gprs) |written| {
        try testing.expectError(Error.UnsupportedOp, moveSet(testing.allocator, &buf, alloc, 32, &f, &.{0}, &.{1}, written));
    }
    try testing.expectEqual(@as(usize, 0), buf.items.len);
    // A set with nothing to move writes nothing; a register outside the set is not written.
    try moveSet(testing.allocator, &buf, alloc, 32, &f, &.{ 0, 1 }, &.{ 0, 1 }, park_gpr);
    try testing.expectEqual(@as(usize, 0), buf.items.len);
    try moveSet(testing.allocator, &buf, alloc, 32, &f, &.{0}, &.{1}, abi.allocatable_gprs[2]);
    try testing.expect(buf.items.len > 0);
}
