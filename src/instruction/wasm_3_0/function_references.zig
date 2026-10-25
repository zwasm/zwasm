//! Wasm 3.0 function-references proposal interp handlers
//! (`phase10_design_plan_ja.md` §3.2). Mirror of
//! `src/instruction/wasm_2_0/reference_types.zig` shape — the
//! 5 typed-function-references ops (ref.as_non_null / br_on_null
//! / br_on_non_null / call_ref / return_call_ref) register their
//! interp handlers via the same DispatchTable.interp slot pattern
//! as the Wasm 2.0 reftype family.
//!
//! 10.R-1 landed ref.as_non_null; 10.R-2 added br_on_null; 10.R-3
//! adds br_on_non_null. call_ref / return_call_ref register at
//! 10.R-4..10.R-5 (sub-chunks per the design plan).
//!
//! Wasm spec 3.0 §3.3.8.5 (`ref.as_non_null`): pop reftype; if
//! null, trap (.NullReference per ADR-0111 / runtime/trap.zig);
//! else push the same reftype value back. Statically the type
//! narrows `(ref null T)` → `(ref T)` (nullability axis); v2.0
//! reftype catalogue doesn't model this yet, so the runtime
//! handler is a simple null-check (per `phase10_design_plan_ja.md`
//! §3.2 (1)). Per-op file placeholder
//! `src/instruction/wasm_3_0/ref_as_non_null.zig` returns
//! NotMigrated → legacy dispatch table (this file) handles it.
//!
//! Zone 1 (`src/instruction/`).

const std = @import("std");

const dispatch = @import("../../ir/dispatch_table.zig");
const zir = @import("../../ir/zir.zig");
const runtime = @import("../../runtime/runtime.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const InterpCtx = dispatch.InterpCtx;
const Runtime = runtime.Runtime;
const Value = runtime.Value;

inline fn op(o: ZirOp) usize {
    return @backingInt(o);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"ref.as_non_null")] = refAsNonNull;
    table.interp[op(.br_on_null)] = brOnNull;
    table.interp[op(.br_on_non_null)] = brOnNonNull;
}

fn refAsNonNull(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const r = rt.popOperand().ref;
    if (r == Value.null_ref) return runtime.Trap.NullReference;
    try rt.pushOperand(.{ .ref = r });
}

/// Maximum branch-arity supported by `br_on_null` (= maximum
/// label result count from the Wasm 1.0/2.0 control-flow
/// catalogue). Mirrors `src/interp/mvp.zig::max_block_arity`.
/// Re-derived rather than imported because instruction/ is
/// Zone 1 and mvp.zig is Zone 2 (zone_deps.md forbids upward).
const max_branch_arity: u32 = 16;

/// Re-derived branch mechanic mirroring `mvp.zig::doBranch` +
/// `restoreToLabel`. Lives here rather than imported because
/// instruction/ is Zone 1 and mvp.zig is Zone 2 (zone_deps.md
/// forbids upward). A future refactor could promote this to
/// `runtime/frame.zig` (Zone 1) and dedupe with mvp.zig.
fn branchTo(rt: *Runtime, depth: u32) anyerror!void {
    const frame = rt.currentFrame();
    if (depth >= frame.label_len) return runtime.Trap.Unreachable;
    const target = frame.labelAt(depth);
    // Pop (depth + 1) labels; loop opcode re-pushes its label
    // when target_pc lands on it (mirror of mvp.zig logic).
    var i: u32 = 0;
    while (i <= depth) : (i += 1) _ = frame.popLabel();
    // Restore stack to label using branch_arity (results for
    // block/if; 0 for loops in Wasm 1.0 / single-result blocktype
    // in 2.0). Save → reset → push back pattern.
    const arity = target.branch_arity;
    if (arity > max_branch_arity) return runtime.Trap.Unreachable;
    var saved: [max_branch_arity]Value = undefined;
    var j: u32 = arity;
    while (j > 0) {
        j -= 1;
        saved[j] = rt.popOperand();
    }
    rt.operand_len = target.height;
    j = 0;
    while (j < arity) : (j += 1) {
        try rt.pushOperand(saved[j]);
    }
    frame.pc = target.target_pc;
}

/// Wasm spec 3.0 §3.3.8.6 — `br_on_null l`: pop reftype; if
/// null, branch to label l (consume l.branch_arity values from
/// stack as branch values); else push the non-null reftype back
/// and fall through.
fn brOnNull(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const r = rt.popOperand().ref;
    if (r != Value.null_ref) {
        try rt.pushOperand(.{ .ref = r });
        return;
    }
    try branchTo(rt, @intCast(instr.payload));
}

/// Wasm spec 3.0 §3.3.8.7 — `br_on_non_null l`: pop reftype; if
/// non-null, push the ref back and branch to label l (which
/// expects `[t1*, reftype]` — the non-null ref is passed as a
/// branch value at top). Otherwise consume the (null) ref and
/// fall through with the prefix `[t1*]` on stack.
fn brOnNonNull(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const r = rt.popOperand().ref;
    if (r == Value.null_ref) return; // null: fall through, ref consumed
    try rt.pushOperand(.{ .ref = r });
    try branchTo(rt, @intCast(instr.payload));
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("../../interp/dispatch.zig");

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "register: ref.as_non_null + br_on_null + br_on_non_null slots populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"ref.as_non_null")] != null);
    try testing.expect(t.interp[op(.br_on_null)] != null);
    try testing.expect(t.interp[op(.br_on_non_null)] != null);
}

test "ref.as_non_null: non-null funcref → passes through" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // Push a non-null sentinel (any non-zero value).
    try rt.pushOperand(.{ .ref = 0x1000 });
    try driveOne(&rt, &t, .@"ref.as_non_null", 0, 0);
    try testing.expectEqual(@as(u64, 0x1000), rt.popOperand().ref);
}

test "ref.as_non_null: null → Trap.NullReference" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try testing.expectError(runtime.Trap.NullReference, driveOne(&rt, &t, .@"ref.as_non_null", 0, 0));
}

test "br_on_null: non-null → fall through (ref preserved)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // Push a label-stack frame so the branch path *would* work,
    // then verify the non-null case leaves the ref on top and
    // doesn't touch frame.pc.
    const empty_sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var frame: runtime.Frame = .{
        .sig = empty_sig,
        .locals = &.{},
        .operand_base = 0,
        .pc = 100,
    };
    try frame.pushLabel(testing.allocator, .{ .height = 0, .arity = 0, .branch_arity = 0, .target_pc = 999 });
    try rt.pushFrame(frame);
    try rt.pushOperand(.{ .ref = 0x1000 });
    try driveOne(&rt, &t, .br_on_null, 0, 0); // depth=0
    try testing.expectEqual(@as(u64, 0x1000), rt.popOperand().ref);
    // pc unchanged (no branch).
    try testing.expectEqual(@as(u32, 100), rt.currentFrame().pc);
}

test "br_on_null: null → branch (ref consumed; pc jumps to target)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const empty_sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var frame: runtime.Frame = .{
        .sig = empty_sig,
        .locals = &.{},
        .operand_base = 0,
        .pc = 100,
    };
    try frame.pushLabel(testing.allocator, .{ .height = 0, .arity = 0, .branch_arity = 0, .target_pc = 42 });
    try rt.pushFrame(frame);
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try driveOne(&rt, &t, .br_on_null, 0, 0); // depth=0 → target_pc=42
    // ref popped; stack restored to height=0.
    try testing.expectEqual(@as(u32, 0), rt.operand_len);
    // pc jumped to target.
    try testing.expectEqual(@as(u32, 42), rt.currentFrame().pc);
}

test "br_on_non_null: null → fall through (ref consumed; pc unchanged)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const empty_sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var frame: runtime.Frame = .{
        .sig = empty_sig,
        .locals = &.{},
        .operand_base = 0,
        .pc = 100,
    };
    // Label expects [reftype] (branch_arity=1) on branch, but the
    // null path doesn't take it; we just verify the ref is
    // consumed and pc is unchanged.
    try frame.pushLabel(testing.allocator, .{ .height = 0, .arity = 1, .branch_arity = 1, .target_pc = 999 });
    try rt.pushFrame(frame);
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try driveOne(&rt, &t, .br_on_non_null, 0, 0); // depth=0
    // ref consumed (stack empty); pc unchanged (no branch).
    try testing.expectEqual(@as(u32, 0), rt.operand_len);
    try testing.expectEqual(@as(u32, 100), rt.currentFrame().pc);
}

test "br_on_non_null: non-null → branch (ref passed at top; pc jumps)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const empty_sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var frame: runtime.Frame = .{
        .sig = empty_sig,
        .locals = &.{},
        .operand_base = 0,
        .pc = 100,
    };
    // Label expects [reftype]; branch_arity=1 carries the ref to
    // the branch destination.
    try frame.pushLabel(testing.allocator, .{ .height = 0, .arity = 1, .branch_arity = 1, .target_pc = 42 });
    try rt.pushFrame(frame);
    try rt.pushOperand(.{ .ref = 0x2000 });
    try driveOne(&rt, &t, .br_on_non_null, 0, 0); // depth=0 → target_pc=42
    // ref preserved on top of stack (branch_arity=1 carried it).
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u64, 0x2000), rt.popOperand().ref);
    // pc jumped to target.
    try testing.expectEqual(@as(u32, 42), rt.currentFrame().pc);
}
