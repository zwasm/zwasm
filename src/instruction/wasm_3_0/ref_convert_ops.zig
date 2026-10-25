//! Wasm 3.0 GC `any.convert_extern` / `extern.convert_any` interp
//! handlers (10.G op_gc cycle 10 per `.dev/phase10_g_op_bundle_plan.md`).
//!
//! Encoding (Wasm 3.0 GC §3.3.5.7):
//!   - `any.convert_extern` (0xFB 0x1A): pop externref, push anyref.
//!   - `extern.convert_any` (0xFB 0x1B): pop anyref, push externref.
//!
//! Runtime semantics: identity at the Value level. Reftypes share
//! the `.ref: u64` slot in Value; the spec's any↔extern hierarchy
//! distinction is purely static (validator-tracked). At runtime the
//! conversion is observable only through the validator-narrowed
//! type the downstream consumer expects.
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

inline fn op(o: ZirOp) usize {
    return @backingInt(o);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"any.convert_extern")] = convertIdentity;
    table.interp[op(.@"extern.convert_any")] = convertIdentity;
    table.interp[op(.@"ref.eq")] = refEq;
    table.interp[op(.@"array.len")] = arrayLen;
}

fn convertIdentity(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    // Reftypes share the same Value runtime representation; the
    // any↔extern distinction is validator-only. Leave the operand
    // on the stack unchanged.
    _ = c;
}

/// Wasm 3.0 GC §3.3.5.2 — `ref.eq`: pop two reftypes, push i32
/// (1 iff same reference identity, else 0). Two nulls compare
/// equal per spec (null_ref == null_ref).
fn refEq(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const b = rt.popOperand();
    const a = rt.popOperand();
    const eq: i32 = if (a.ref == b.ref) 1 else 0;
    try rt.pushOperand(.{ .i32 = eq });
}

/// Wasm 3.0 GC §3.3.5.6.13 — `array.len`: pop arrayref, push i32
/// length. Cycle-12 stub: array creation ops (array.new family)
/// haven't landed, so every reftype operand is structurally null →
/// trap NullReference. Real length-decode lands with ArrayInfo
/// RTT when sub-chunk 6 of the bundle plan ships.
fn arrayLen(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    _ = rt.popOperand();
    return runtime.Trap.NullReference;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("../../interp/dispatch.zig");
const Value = runtime.Value;

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp) !void {
    const instr: ZirInstr = .{ .op = t, .payload = 0, .extra = 0 };
    try dispatch_loop.step(rt, table, &instr);
}

test "any.convert_extern: ref slot round-trips unchanged (10.G op_gc cycle 10)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0xCAFE_1234 });
    try driveOne(&rt, &t, .@"any.convert_extern");
    try testing.expectEqual(@as(u64, 0xCAFE_1234), rt.popOperand().ref);
}

test "any.convert_extern: null ref round-trips (10.G op_gc cycle 10)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try driveOne(&rt, &t, .@"any.convert_extern");
    try testing.expectEqual(Value.null_ref, rt.popOperand().ref);
}

test "extern.convert_any: ref slot round-trips unchanged (10.G op_gc cycle 10)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0xDEAD_BEEF });
    try driveOne(&rt, &t, .@"extern.convert_any");
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), rt.popOperand().ref);
}

test "extern.convert_any: null ref round-trips (10.G op_gc cycle 10)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try driveOne(&rt, &t, .@"extern.convert_any");
    try testing.expectEqual(Value.null_ref, rt.popOperand().ref);
}

test "ref.eq: same non-null ref returns 1 (10.G op_gc cycle 11)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0x1234_5678 });
    try rt.pushOperand(.{ .ref = 0x1234_5678 });
    try driveOne(&rt, &t, .@"ref.eq");
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}

test "ref.eq: distinct refs return 0 (10.G op_gc cycle 11)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0x1111 });
    try rt.pushOperand(.{ .ref = 0x2222 });
    try driveOne(&rt, &t, .@"ref.eq");
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "ref.eq: null == null returns 1 (10.G op_gc cycle 11)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try driveOne(&rt, &t, .@"ref.eq");
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}

test "ref.eq: null vs non-null returns 0 (10.G op_gc cycle 11)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try rt.pushOperand(.{ .ref = 0xCAFE });
    try driveOne(&rt, &t, .@"ref.eq");
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "array.len: traps NullReference pre-array-creation (10.G op_gc cycle 12)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try testing.expectError(runtime.Trap.NullReference, driveOne(&rt, &t, .@"array.len"));
}

test "array.len: also traps on non-null operand pre-ArrayInfo (10.G op_gc cycle 12)" {
    // Cycle-12 stub always traps — ArrayInfo lookup lands later.
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0xDEAD });
    try testing.expectError(runtime.Trap.NullReference, driveOne(&rt, &t, .@"array.len"));
}
