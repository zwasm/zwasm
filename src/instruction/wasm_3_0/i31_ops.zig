//! Wasm 3.0 GC i31 interp handlers (`phase10_design_plan_ja.md`
//! GC section). Lands the 3 i31 ops — `ref.i31` / `i31.get_s` /
//! `i31.get_u` — registered into `DispatchTable.interp` via the
//! same per-feature register pattern as
//! `wasm_3_0/function_references.zig`.
//!
//! Encoding: i31 ref values use `Value.fromI31Truncate` / the
//! `Value.refAsI31*` accessors, which store the i31-packed
//! payload in the low 32 bits of `Value.ref` per ADR-0116 D4.
//! Phase 10 punts on the dedicated `anyref: u32` Value arm until
//! the GC heap impl needs to disambiguate i31 from heap-pointer
//! encodings.
//!
//! Spec semantics (Wasm 3.0 GC proposal):
//!   - `ref.i31`: pop i32, push (ref i31). Spec defines silent
//!     low-31-bit truncation; `i32ToI31Truncate` mirrors that.
//!   - `i31.get_s`: pop (ref null i31); if null → trap; else
//!     push i32 (sign-extended).
//!   - `i31.get_u`: same as `get_s` but unsigned (high bit zero).
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
    table.interp[op(.@"ref.i31")] = refI31;
    table.interp[op(.@"i31.get_s")] = i31GetS;
    table.interp[op(.@"i31.get_u")] = i31GetU;
}

fn refI31(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().i32;
    try rt.pushOperand(Value.fromI31Truncate(x));
}

fn i31GetS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    // Spec: `i31.get_*` traps if input is null. With the low-bit-1
    // discriminant (ADR-0116 D4), null (ref == 0) reads as
    // !isI31Ref(v); we conflate non-i31 + null under the same
    // NullReference trap because the v2.0 catalogue can't statically
    // narrow the type to (ref i31) without typed-ref precision.
    if (!Value.isI31Ref(v)) return runtime.Trap.NullReference;
    try rt.pushOperand(.{ .i32 = Value.refAsI31Signed(v) });
}

fn i31GetU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    if (!Value.isI31Ref(v)) return runtime.Trap.NullReference;
    try rt.pushOperand(.{ .u32 = Value.refAsI31Unsigned(v) });
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

test "register: ref.i31 + i31.get_s + i31.get_u slots populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"ref.i31")] != null);
    try testing.expect(t.interp[op(.@"i31.get_s")] != null);
    try testing.expect(t.interp[op(.@"i31.get_u")] != null);
}

test "ref.i31 + i31.get_s: positive round-trip" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 1234 });
    try driveOne(&rt, &t, .@"ref.i31", 0, 0);
    try driveOne(&rt, &t, .@"i31.get_s", 0, 0);
    try testing.expectEqual(@as(i32, 1234), rt.popOperand().i32);
}

test "ref.i31 + i31.get_s: negative round-trip (sign-extend)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = -1 });
    try driveOne(&rt, &t, .@"ref.i31", 0, 0);
    try driveOne(&rt, &t, .@"i31.get_s", 0, 0);
    try testing.expectEqual(@as(i32, -1), rt.popOperand().i32);
}

test "ref.i31 + i31.get_u: -1 → 0x7FFFFFFF (high bit zero)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = -1 });
    try driveOne(&rt, &t, .@"ref.i31", 0, 0);
    try driveOne(&rt, &t, .@"i31.get_u", 0, 0);
    try testing.expectEqual(@as(u32, 0x7FFF_FFFF), rt.popOperand().u32);
}

test "i31.get_s: null ref → Trap.NullReference" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try testing.expectError(runtime.Trap.NullReference, driveOne(&rt, &t, .@"i31.get_s", 0, 0));
}

test "i31.get_u: null ref → Trap.NullReference" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try testing.expectError(runtime.Trap.NullReference, driveOne(&rt, &t, .@"i31.get_u", 0, 0));
}

test "ref.i31: silent truncation of wider-than-31-bit input" {
    // i32 max (0x7FFFFFFF) → after low-31-bit truncation + sign-extend
    // recovery, the high bit of the 31-bit payload becomes the sign
    // bit, recovering -1 from i31.get_s (matches the helper's
    // contract — see feature/gc/i31.zig "i32ToI31Truncate" test).
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = std.math.maxInt(i32) });
    try driveOne(&rt, &t, .@"ref.i31", 0, 0);
    try driveOne(&rt, &t, .@"i31.get_s", 0, 0);
    try testing.expectEqual(@as(i32, -1), rt.popOperand().i32);
}
