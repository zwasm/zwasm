//! IR verifier (§9.5 / 5.5).
//!
//! Sanity checker that runs after each Phase-5 analysis pass.
//! Validates the invariants `loop_info` and `liveness` are
//! supposed to maintain so a regression in either pass surfaces
//! immediately rather than as a downstream JIT bug (the W54-class
//! lesson made concrete: layered optimisations on a fragile IR
//! shape are how implicit-contract sprawl creeps in).
//!
//! Invariants checked when each slot is populated:
//!
//! `loop_info`:
//!   - `loop_headers.len == loop_end.len`.
//!   - Every `header[i]` < `instrs.len` AND instr at `header[i]`
//!     has op `.@"loop"`.
//!   - Every `loop_end[i]` < `instrs.len` AND instr at
//!     `loop_end[i]` has op `.@"end"`.
//!   - `header[i] < loop_end[i]` (start before end).
//!
//! `liveness`:
//!   - Every `range.def_pc` < `instrs.len`.
//!   - Every `range.last_use_pc` < `instrs.len`.
//!   - `def_pc <= last_use_pc`.
//!
//! `branch_targets` (always populated by the lowerer for
//! `br_table` rows):
//!   - Every entry < the maximum branch depth implied by the
//!     enclosing block nesting at its referencing instr — too
//!     expensive to recompute here without a second pass; for
//!     §9.5 / 5.5 we settle for the cheap range check that the
//!     entry is < a generous ceiling (`max_block_depth`). The
//!     stricter check belongs in the validator and already runs
//!     during the validate pass per `validator.zig`.
//!
//! `verify` returns at the first failed invariant. Each error
//! variant names what failed; the structured error catalogue is
//! the surface §9.5 / 5.6 const-prop and the Phase-7 regalloc
//! consumers will pattern-match on.
//!
//! Zone 1 (`src/ir/`).

const std = @import("std");

const zir = @import("zir.zig");

const ZirFunc = zir.ZirFunc;

pub const Error = error{
    LoopInfoLengthMismatch,
    LoopHeaderOutOfRange,
    LoopHeaderNotLoopOp,
    LoopEndOutOfRange,
    LoopEndNotEndOp,
    LoopHeaderAfterEnd,
    LivenessDefPcOutOfRange,
    LivenessLastUsePcOutOfRange,
    LivenessDefAfterLastUse,
    BranchTargetOutOfRange,
};

/// Conservative ceiling on branch depths = the validator's
/// `max_control_stack` (the shared `zir.max_control_stack`, the
/// single source of truth). Anything that survives the validator
/// passes this check too; sourcing the same constant prevents the
/// D-241 drift (was a stale literal 256 vs the validator's 1024 →
/// validator-accepted standard-Go funcs wrongly rejected here). Real
/// per-instr depth would require re-walking the control stack — out
/// of scope for the "cheap structural check" Phase-5 wants here.
const max_block_depth: usize = zir.max_control_stack;

/// Verify all populated analysis slots on `func`. Returns at the
/// first failed invariant.
pub fn verify(func: *const ZirFunc) Error!void {
    if (func.loop_info) |li| try verifyLoopInfo(func, li);
    if (func.liveness) |lv| try verifyLiveness(func, lv);
    try verifyBranchTargets(func);
}

fn verifyLoopInfo(func: *const ZirFunc, li: zir.LoopInfo) Error!void {
    if (li.loop_headers.len != li.loop_end.len) {
        return Error.LoopInfoLengthMismatch;
    }
    const n_instrs: u32 = @intCast(func.instrs.items.len);
    for (li.loop_headers, li.loop_end) |h, e| {
        if (h >= n_instrs) return Error.LoopHeaderOutOfRange;
        if (func.instrs.items[h].op != .loop) return Error.LoopHeaderNotLoopOp;
        if (e >= n_instrs) return Error.LoopEndOutOfRange;
        if (func.instrs.items[e].op != .end) return Error.LoopEndNotEndOp;
        if (h >= e) return Error.LoopHeaderAfterEnd;
    }
}

fn verifyLiveness(func: *const ZirFunc, lv: zir.Liveness) Error!void {
    const n_instrs: u32 = @intCast(func.instrs.items.len);
    for (lv.ranges) |r| {
        if (r.def_pc >= n_instrs) return Error.LivenessDefPcOutOfRange;
        if (r.last_use_pc >= n_instrs) return Error.LivenessLastUsePcOutOfRange;
        if (r.def_pc > r.last_use_pc) return Error.LivenessDefAfterLastUse;
    }
}

fn verifyBranchTargets(func: *const ZirFunc) Error!void {
    for (func.branch_targets.items) |target| {
        if (target >= max_block_depth) return Error.BranchTargetOutOfRange;
    }
}

const testing = std.testing;

fn buildFunc(allocator: std.mem.Allocator, ops: []const zir.ZirInstr) !ZirFunc {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    errdefer f.deinit(allocator);
    for (ops) |o| try f.instrs.append(allocator, o);
    return f;
}

test "verify: empty function with no analyses passes" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);
    try verify(&f);
}

test "verify: well-formed loop_info passes" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .loop },
        .{ .op = .nop },
        .{ .op = .end },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);
    f.loop_info = .{ .loop_headers = &[_]u32{0}, .loop_end = &[_]u32{2} };
    try verify(&f);
}

test "verify: loop_info length mismatch fails" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .loop },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);
    f.loop_info = .{ .loop_headers = &[_]u32{0}, .loop_end = &[_]u32{} };
    try testing.expectError(Error.LoopInfoLengthMismatch, verify(&f));
}

test "verify: loop_info header out of range fails" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);
    f.loop_info = .{ .loop_headers = &[_]u32{99}, .loop_end = &[_]u32{0} };
    try testing.expectError(Error.LoopHeaderOutOfRange, verify(&f));
}

test "verify: loop_info header pointing at non-loop op fails" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .nop }, // not a loop
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);
    f.loop_info = .{ .loop_headers = &[_]u32{0}, .loop_end = &[_]u32{1} };
    try testing.expectError(Error.LoopHeaderNotLoopOp, verify(&f));
}

test "verify: loop_info end pointing at non-end op fails" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .loop },
        .{ .op = .nop }, // not an end
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);
    f.loop_info = .{ .loop_headers = &[_]u32{0}, .loop_end = &[_]u32{1} };
    try testing.expectError(Error.LoopEndNotEndOp, verify(&f));
}

test "verify: loop_info header after end fails" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .end },
        .{ .op = .loop },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);
    f.loop_info = .{ .loop_headers = &[_]u32{1}, .loop_end = &[_]u32{0} };
    try testing.expectError(Error.LoopHeaderAfterEnd, verify(&f));
}

test "verify: well-formed liveness passes" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .drop },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    try verify(&f);
}

test "verify: liveness def_pc out of range fails" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 99, .last_use_pc = 99 },
    } };
    try testing.expectError(Error.LivenessDefPcOutOfRange, verify(&f));
}

test "verify: liveness def after last_use fails" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .drop },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 1, .last_use_pc = 0 }, // inverted
        },
    };
    try testing.expectError(Error.LivenessDefAfterLastUse, verify(&f));
}

test "verify: branch_targets within ceiling pass (incl. >256, the D-241 regime)" {
    var f = try buildFunc(testing.allocator, &.{.{ .op = .end }});
    defer f.deinit(testing.allocator);
    try f.branch_targets.append(testing.allocator, 0);
    try f.branch_targets.append(testing.allocator, 255);
    // 256..1023 were wrongly rejected pre-D-241 (stale 256 ceiling) though
    // the validator accepts them; standard-Go funcs live here.
    try f.branch_targets.append(testing.allocator, 256);
    try f.branch_targets.append(testing.allocator, @intCast(zir.max_control_stack - 1));
    try verify(&f);
}

test "verify: branch_targets exceeding ceiling fail" {
    var f = try buildFunc(testing.allocator, &.{.{ .op = .end }});
    defer f.deinit(testing.allocator);
    try f.branch_targets.append(testing.allocator, @intCast(zir.max_control_stack));
    try testing.expectError(Error.BranchTargetOutOfRange, verify(&f));
}

test "verify: branch-target ceiling matches the validator's control-stack cap (D-241 drift guard)" {
    // The exact invariant that broke: verifier ceiling == validator cap.
    const validator = @import("../validate/validator.zig");
    try testing.expectEqual(validator.max_control_stack, max_block_depth);
}

test "verify: combined loop_info + liveness + branch_targets pass" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .loop },
        .{ .op = .@"i32.const", .payload = 7 },
        .{ .op = .drop },
        .{ .op = .end },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);
    f.loop_info = .{ .loop_headers = &[_]u32{0}, .loop_end = &[_]u32{3} };
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    try f.branch_targets.append(testing.allocator, 0);
    try verify(&f);
}
