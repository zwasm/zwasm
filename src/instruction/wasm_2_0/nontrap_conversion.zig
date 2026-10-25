//! Wasm 2.0 saturating-truncation interp handlers (§9.2 / 2.3 chunk 2).
//!
//! Prefix opcode 0xFC + sub-opcode 0..7. Unlike `iN.trunc_*` these
//! never trap: NaN saturates to 0, +∞ / out-of-range-high saturates
//! to MAX, -∞ / out-of-range-low saturates to MIN. Otherwise truncate
//! toward zero. Spec §6.2.5 (wasm-2.0).
//!
//! Sub-opcode → ZirOp:
//!   0 → i32.trunc_sat_f32_s    1 → i32.trunc_sat_f32_u
//!   2 → i32.trunc_sat_f64_s    3 → i32.trunc_sat_f64_u
//!   4 → i64.trunc_sat_f32_s    5 → i64.trunc_sat_f32_u
//!   6 → i64.trunc_sat_f64_s    7 → i64.trunc_sat_f64_u
//!
//! Zone 2 (`src/interp/ext_2_0/`) — imports Zone 0 (`util/`) +
//! Zone 1 (`ir/`) + sibling Zone 2 (`../mod.zig`,
//! `../dispatch.zig`).

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
    table.interp[op(.@"i32.trunc_sat_f32_s")] = i32TruncSatF32S;
    table.interp[op(.@"i32.trunc_sat_f32_u")] = i32TruncSatF32U;
    table.interp[op(.@"i32.trunc_sat_f64_s")] = i32TruncSatF64S;
    table.interp[op(.@"i32.trunc_sat_f64_u")] = i32TruncSatF64U;
    table.interp[op(.@"i64.trunc_sat_f32_s")] = i64TruncSatF32S;
    table.interp[op(.@"i64.trunc_sat_f32_u")] = i64TruncSatF32U;
    table.interp[op(.@"i64.trunc_sat_f64_s")] = i64TruncSatF64S;
    table.interp[op(.@"i64.trunc_sat_f64_u")] = i64TruncSatF64U;
}

fn satTruncSigned(comptime DstInt: type, x: anytype) DstInt {
    if (std.math.isNan(x)) return 0;
    const max_i: DstInt = std.math.maxInt(DstInt);
    const min_i: DstInt = std.math.minInt(DstInt);
    const max_f = @as(@TypeOf(x), @floatFromInt(max_i));
    const min_f = @as(@TypeOf(x), @floatFromInt(min_i));
    if (x >= max_f) return max_i;
    if (x <= min_f) return min_i;
    return @intFromFloat(@trunc(x));
}

fn satTruncUnsigned(comptime DstUint: type, x: anytype) DstUint {
    if (std.math.isNan(x)) return 0;
    const max_i: DstUint = std.math.maxInt(DstUint);
    const max_f = @as(@TypeOf(x), @floatFromInt(max_i));
    if (x <= 0) return 0;
    if (x >= max_f) return max_i;
    return @intFromFloat(@trunc(x));
}

fn i32TruncSatF32S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f32;
    try rt.pushOperand(.{ .i32 = satTruncSigned(i32, x) });
}

fn i32TruncSatF32U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f32;
    try rt.pushOperand(.{ .u32 = satTruncUnsigned(u32, x) });
}

fn i32TruncSatF64S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f64;
    try rt.pushOperand(.{ .i32 = satTruncSigned(i32, x) });
}

fn i32TruncSatF64U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f64;
    try rt.pushOperand(.{ .u32 = satTruncUnsigned(u32, x) });
}

fn i64TruncSatF32S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f32;
    try rt.pushOperand(.{ .i64 = satTruncSigned(i64, x) });
}

fn i64TruncSatF32U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f32;
    try rt.pushOperand(.{ .u64 = satTruncUnsigned(u64, x) });
}

fn i64TruncSatF64S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f64;
    try rt.pushOperand(.{ .i64 = satTruncSigned(i64, x) });
}

fn i64TruncSatF64U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f64;
    try rt.pushOperand(.{ .u64 = satTruncUnsigned(u64, x) });
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

fn pushF32(rt: *Runtime, x: f32) !void {
    try rt.pushOperand(.{ .f32 = x });
}

fn pushF64(rt: *Runtime, x: f64) !void {
    try rt.pushOperand(.{ .f64 = x });
}

test "register: all eight sat-trunc slots populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"i32.trunc_sat_f32_s")] != null);
    try testing.expect(t.interp[op(.@"i32.trunc_sat_f32_u")] != null);
    try testing.expect(t.interp[op(.@"i32.trunc_sat_f64_s")] != null);
    try testing.expect(t.interp[op(.@"i32.trunc_sat_f64_u")] != null);
    try testing.expect(t.interp[op(.@"i64.trunc_sat_f32_s")] != null);
    try testing.expect(t.interp[op(.@"i64.trunc_sat_f32_u")] != null);
    try testing.expect(t.interp[op(.@"i64.trunc_sat_f64_s")] != null);
    try testing.expect(t.interp[op(.@"i64.trunc_sat_f64_u")] != null);
}

test "i32.trunc_sat_f32_s: NaN saturates to 0" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF32(&rt, std.math.nan(f32));
    try driveOne(&rt, &t, .@"i32.trunc_sat_f32_s", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "i32.trunc_sat_f32_s: +inf saturates to INT32_MAX" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF32(&rt, std.math.inf(f32));
    try driveOne(&rt, &t, .@"i32.trunc_sat_f32_s", 0, 0);
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), rt.popOperand().i32);
}

test "i32.trunc_sat_f32_s: -inf saturates to INT32_MIN" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF32(&rt, -std.math.inf(f32));
    try driveOne(&rt, &t, .@"i32.trunc_sat_f32_s", 0, 0);
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), rt.popOperand().i32);
}

test "i32.trunc_sat_f32_s: in-range value truncates toward zero" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF32(&rt, -3.7);
    try driveOne(&rt, &t, .@"i32.trunc_sat_f32_s", 0, 0);
    try testing.expectEqual(@as(i32, -3), rt.popOperand().i32);
}

test "i32.trunc_sat_f32_s: 1e10 saturates high" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF32(&rt, 1.0e10);
    try driveOne(&rt, &t, .@"i32.trunc_sat_f32_s", 0, 0);
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), rt.popOperand().i32);
}

test "i32.trunc_sat_f32_u: -1.0 saturates to 0" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF32(&rt, -1.0);
    try driveOne(&rt, &t, .@"i32.trunc_sat_f32_u", 0, 0);
    try testing.expectEqual(@as(u32, 0), rt.popOperand().u32);
}

test "i32.trunc_sat_f32_u: NaN saturates to 0" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF32(&rt, std.math.nan(f32));
    try driveOne(&rt, &t, .@"i32.trunc_sat_f32_u", 0, 0);
    try testing.expectEqual(@as(u32, 0), rt.popOperand().u32);
}

test "i32.trunc_sat_f32_u: +inf saturates to UINT32_MAX" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF32(&rt, std.math.inf(f32));
    try driveOne(&rt, &t, .@"i32.trunc_sat_f32_u", 0, 0);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), rt.popOperand().u32);
}

test "i32.trunc_sat_f32_u: 42.9 → 42" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF32(&rt, 42.9);
    try driveOne(&rt, &t, .@"i32.trunc_sat_f32_u", 0, 0);
    try testing.expectEqual(@as(u32, 42), rt.popOperand().u32);
}

test "i32.trunc_sat_f64_s: NaN → 0; +inf → MAX; -inf → MIN" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    try pushF64(&rt, std.math.nan(f64));
    try driveOne(&rt, &t, .@"i32.trunc_sat_f64_s", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);

    try pushF64(&rt, std.math.inf(f64));
    try driveOne(&rt, &t, .@"i32.trunc_sat_f64_s", 0, 0);
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), rt.popOperand().i32);

    try pushF64(&rt, -std.math.inf(f64));
    try driveOne(&rt, &t, .@"i32.trunc_sat_f64_s", 0, 0);
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), rt.popOperand().i32);
}

test "i32.trunc_sat_f64_u: spec corner — -0.5 → 0" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF64(&rt, -0.5);
    try driveOne(&rt, &t, .@"i32.trunc_sat_f64_u", 0, 0);
    try testing.expectEqual(@as(u32, 0), rt.popOperand().u32);
}

test "i64.trunc_sat_f32_s: large positive saturates to INT64_MAX" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF32(&rt, 1.0e30);
    try driveOne(&rt, &t, .@"i64.trunc_sat_f32_s", 0, 0);
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), rt.popOperand().i64);
}

test "i64.trunc_sat_f32_u: NaN → 0" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF32(&rt, std.math.nan(f32));
    try driveOne(&rt, &t, .@"i64.trunc_sat_f32_u", 0, 0);
    try testing.expectEqual(@as(u64, 0), rt.popOperand().u64);
}

test "i64.trunc_sat_f64_s: 12345.7 → 12345" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try pushF64(&rt, 12345.7);
    try driveOne(&rt, &t, .@"i64.trunc_sat_f64_s", 0, 0);
    try testing.expectEqual(@as(i64, 12345), rt.popOperand().i64);
}

test "i64.trunc_sat_f64_u: -inf → 0; +inf → UINT64_MAX" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    try pushF64(&rt, -std.math.inf(f64));
    try driveOne(&rt, &t, .@"i64.trunc_sat_f64_u", 0, 0);
    try testing.expectEqual(@as(u64, 0), rt.popOperand().u64);

    try pushF64(&rt, std.math.inf(f64));
    try driveOne(&rt, &t, .@"i64.trunc_sat_f64_u", 0, 0);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), rt.popOperand().u64);
}
