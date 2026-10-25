//! MVP conversion ops carve-out (§9.5 / 5.1 split from `mvp.zig`).
//!
//! Holds wrap / extend / trunc / convert / promote / demote /
//! reinterpret handlers (Wasm 1.0 conversion family, opcodes
//! 0xA7..0xBF). `register()` installs only this module's slots;
//! the residual `mvp.zig` shell calls each split's `register()`.
//!
//! `trunc_*` traps `InvalidConversionToInt` on NaN inputs and
//! `IntOverflow` on out-of-range floats; this is Wasm-spec
//! behaviour. Sat-trunc variants live in
//! `ext_2_0/sat_trunc.zig` (Wasm 2.0 extension).
//!
//! Zone 2 (`src/interp/`).

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
const Trap = runtime.Trap;

inline fn op(t: ZirOp) usize {
    return @backingInt(t);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"i32.wrap_i64")] = i32WrapI64;
    table.interp[op(.@"i32.trunc_f32_s")] = i32TruncF32S;
    table.interp[op(.@"i32.trunc_f32_u")] = i32TruncF32U;
    table.interp[op(.@"i32.trunc_f64_s")] = i32TruncF64S;
    table.interp[op(.@"i32.trunc_f64_u")] = i32TruncF64U;
    table.interp[op(.@"i64.extend_i32_s")] = i64ExtendI32S;
    table.interp[op(.@"i64.extend_i32_u")] = i64ExtendI32U;
    table.interp[op(.@"i64.trunc_f32_s")] = i64TruncF32S;
    table.interp[op(.@"i64.trunc_f32_u")] = i64TruncF32U;
    table.interp[op(.@"i64.trunc_f64_s")] = i64TruncF64S;
    table.interp[op(.@"i64.trunc_f64_u")] = i64TruncF64U;
    table.interp[op(.@"f32.convert_i32_s")] = f32ConvertI32S;
    table.interp[op(.@"f32.convert_i32_u")] = f32ConvertI32U;
    table.interp[op(.@"f32.convert_i64_s")] = f32ConvertI64S;
    table.interp[op(.@"f32.convert_i64_u")] = f32ConvertI64U;
    table.interp[op(.@"f32.demote_f64")] = f32DemoteF64;
    table.interp[op(.@"f64.convert_i32_s")] = f64ConvertI32S;
    table.interp[op(.@"f64.convert_i32_u")] = f64ConvertI32U;
    table.interp[op(.@"f64.convert_i64_s")] = f64ConvertI64S;
    table.interp[op(.@"f64.convert_i64_u")] = f64ConvertI64U;
    table.interp[op(.@"f64.promote_f32")] = f64PromoteF32;
    table.interp[op(.@"i32.reinterpret_f32")] = i32ReinterpretF32;
    table.interp[op(.@"i64.reinterpret_f64")] = i64ReinterpretF64;
    table.interp[op(.@"f32.reinterpret_i32")] = f32ReinterpretI32;
    table.interp[op(.@"f64.reinterpret_i64")] = f64ReinterpretI64;
}

// ============================================================
// Handlers
// ============================================================

// Float → int truncation: trap on NaN / ±inf, trap on out-of-range.
// Spec §3.3.1.6: "trunc_f32_s" et al. produce InvalidConversionToInt
// on NaN, IntOverflow on saturating-out-of-range. Wasm 2.0 adds
// trunc_sat_* variants that don't trap; those land separately.
//
// The upper bound is maxInt + 1, a power of two and so exact in both float
// types. maxInt itself is not exact in f32 (nor in f64 for 64-bit
// destinations): it rounds up to that power, which `>` would let through to
// `@intFromFloat`.

fn truncFloatToInt(comptime DstInt: type, x: anytype) !DstInt {
    if (std.math.isNan(x)) return Trap.InvalidConversionToInt;
    if (std.math.isInf(x)) return Trap.IntOverflow;
    const truncated = @trunc(x);
    const min_f = @as(@TypeOf(x), @floatFromInt(std.math.minInt(DstInt)));
    const limit_f = @as(@TypeOf(x), @floatFromInt(std.math.maxInt(DstInt) + 1));
    if (truncated < min_f or truncated >= limit_f) return Trap.IntOverflow;
    return @intFromFloat(truncated);
}

fn truncFloatToUint(comptime DstUint: type, x: anytype) !DstUint {
    if (std.math.isNan(x)) return Trap.InvalidConversionToInt;
    if (std.math.isInf(x)) return Trap.IntOverflow;
    const truncated = @trunc(x);
    const limit_f = @as(@TypeOf(x), @floatFromInt(std.math.maxInt(DstUint) + 1));
    if (truncated < 0 or truncated >= limit_f) return Trap.IntOverflow;
    return @intFromFloat(truncated);
}

fn i32WrapI64(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u64;
    try rt.pushOperand(.{ .u32 = @truncate(x) });
}

fn i32TruncF32S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f32;
    const r = try truncFloatToInt(i32, x);
    try rt.pushOperand(.{ .i32 = r });
}
fn i32TruncF32U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f32;
    const r = try truncFloatToUint(u32, x);
    try rt.pushOperand(.{ .u32 = r });
}
fn i32TruncF64S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f64;
    const r = try truncFloatToInt(i32, x);
    try rt.pushOperand(.{ .i32 = r });
}
fn i32TruncF64U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f64;
    const r = try truncFloatToUint(u32, x);
    try rt.pushOperand(.{ .u32 = r });
}

fn i64ExtendI32S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().i32;
    try rt.pushOperand(.{ .i64 = @as(i64, x) });
}
fn i64ExtendI32U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u32;
    try rt.pushOperand(.{ .u64 = @as(u64, x) });
}

fn i64TruncF32S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f32;
    const r = try truncFloatToInt(i64, x);
    try rt.pushOperand(.{ .i64 = r });
}
fn i64TruncF32U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f32;
    const r = try truncFloatToUint(u64, x);
    try rt.pushOperand(.{ .u64 = r });
}
fn i64TruncF64S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f64;
    const r = try truncFloatToInt(i64, x);
    try rt.pushOperand(.{ .i64 = r });
}
fn i64TruncF64U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f64;
    const r = try truncFloatToUint(u64, x);
    try rt.pushOperand(.{ .u64 = r });
}

fn f32ConvertI32S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @floatFromInt(rt.popOperand().i32) });
}
fn f32ConvertI32U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @floatFromInt(rt.popOperand().u32) });
}
fn f32ConvertI64S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @floatFromInt(rt.popOperand().i64) });
}
fn f32ConvertI64U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @floatFromInt(rt.popOperand().u64) });
}
fn f32DemoteF64(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @floatCast(rt.popOperand().f64) });
}

fn f64ConvertI32S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @floatFromInt(rt.popOperand().i32) });
}
fn f64ConvertI32U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @floatFromInt(rt.popOperand().u32) });
}
fn f64ConvertI64S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @floatFromInt(rt.popOperand().i64) });
}
fn f64ConvertI64U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @floatFromInt(rt.popOperand().u64) });
}
fn f64PromoteF32(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @floatCast(rt.popOperand().f32) });
}

// Reinterpret: copy bits, no value conversion. The Value union is
// extern, so f32 and u32 share storage; popping as `.bits64` and
// pushing back is the canonical bit-preserving move.
fn i32ReinterpretF32(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    try rt.pushOperand(.{ .u32 = @truncate(v.bits64) });
}
fn i64ReinterpretF64(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    try rt.pushOperand(.{ .u64 = v.bits64 });
}
fn f32ReinterpretI32(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    try rt.pushOperand(.{ .bits64 = @as(u64, v.u32) });
}
fn f64ReinterpretI64(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    try rt.pushOperand(.{ .bits64 = v.u64 });
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("../../interp/dispatch.zig");
const mvp = @import("../../interp/mvp.zig");

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "i32.wrap_i64 takes the low 32 bits" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .u64 = 0xDEAD_BEEF_CAFE_BABE });
    try driveOne(&rt, &t, .@"i32.wrap_i64", 0, 0);
    try testing.expectEqual(@as(u32, 0xCAFE_BABE), rt.popOperand().u32);
}

test "i64.extend_i32_s sign-extends" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = -1 });
    try driveOne(&rt, &t, .@"i64.extend_i32_s", 0, 0);
    try testing.expectEqual(@as(i64, -1), rt.popOperand().i64);
}

test "i64.extend_i32_u zero-extends" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = -1 });
    try driveOne(&rt, &t, .@"i64.extend_i32_u", 0, 0);
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF), rt.popOperand().u64);
}

test "i32.trunc_f32_s: NaN traps InvalidConversionToInt" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f32 = std.math.nan(f32) });
    try testing.expectError(Trap.InvalidConversionToInt, driveOne(&rt, &t, .@"i32.trunc_f32_s", 0, 0));
}

test "i32.trunc_f64_s: out of range traps IntOverflow" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f64 = 1e30 });
    try testing.expectError(Trap.IntOverflow, driveOne(&rt, &t, .@"i32.trunc_f64_s", 0, 0));
}

test "i32.trunc_f64_u: 2^31 must not trap (issue4840)" {
    // The wasmtime issue4840 fixture exercises this exact value.
    // It is in-range for u32 (well below 2^32) and used to trip
    // a too-strict bound check.
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f64 = 2147483648.0 });
    try driveOne(&rt, &t, .@"i32.trunc_f64_u", 0, 0);
    try testing.expectEqual(@as(u32, 2147483648), rt.popOperand().u32);
}

test "i32.trunc_f32_u: -0.5 truncates to 0" {
    // Wasm spec: trunc_*_u accepts inputs in (-1, max+1) range.
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f32 = -0.5 });
    try driveOne(&rt, &t, .@"i32.trunc_f32_u", 0, 0);
    try testing.expectEqual(@as(u32, 0), rt.popOperand().u32);
}

// Where maxInt of the destination is not representable in the source type,
// the first out-of-range input is the power of two just past it. These pin the
// interpreter's bounds; test/edge_cases runs the JIT only.
test "trunc: the power of two just past the destination range traps IntOverflow" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const cases = [_]struct { op: ZirOp, src: Value }{
        .{ .op = .@"i32.trunc_f32_s", .src = .{ .u32 = 0x4F00_0000 } }, // 2^31
        .{ .op = .@"i32.trunc_f32_u", .src = .{ .u32 = 0x4F80_0000 } }, // 2^32
        .{ .op = .@"i64.trunc_f32_s", .src = .{ .u32 = 0x5F00_0000 } }, // 2^63
        .{ .op = .@"i64.trunc_f32_u", .src = .{ .u32 = 0x5F80_0000 } }, // 2^64
        .{ .op = .@"i64.trunc_f64_s", .src = .{ .u64 = 0x43E0_0000_0000_0000 } }, // 2^63
        .{ .op = .@"i64.trunc_f64_u", .src = .{ .u64 = 0x43F0_0000_0000_0000 } }, // 2^64
        .{ .op = .@"i32.trunc_f64_s", .src = .{ .f64 = 2147483648.0 } },
        .{ .op = .@"i32.trunc_f64_u", .src = .{ .f64 = 4294967296.0 } },
    };
    for (cases) |case| {
        try rt.pushOperand(case.src);
        try testing.expectError(Trap.IntOverflow, driveOne(&rt, &t, case.op, 0, 0));
    }
}

test "trunc: the largest in-range input converts" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const cases = [_]struct { op: ZirOp, src: Value, want: u64 }{
        .{ .op = .@"i32.trunc_f32_s", .src = .{ .u32 = 0x4EFF_FFFF }, .want = 0x7FFF_FF80 },
        .{ .op = .@"i32.trunc_f32_u", .src = .{ .u32 = 0x4F7F_FFFF }, .want = 0xFFFF_FF00 },
        .{ .op = .@"i64.trunc_f32_s", .src = .{ .u32 = 0x5EFF_FFFF }, .want = 0x7FFF_FF80_0000_0000 },
        .{ .op = .@"i64.trunc_f32_u", .src = .{ .u32 = 0x5F7F_FFFF }, .want = 0xFFFF_FF00_0000_0000 },
        .{ .op = .@"i64.trunc_f64_s", .src = .{ .u64 = 0x43DF_FFFF_FFFF_FFFF }, .want = 0x7FFF_FFFF_FFFF_FC00 },
        .{ .op = .@"i64.trunc_f64_u", .src = .{ .u64 = 0x43EF_FFFF_FFFF_FFFF }, .want = 0xFFFF_FFFF_FFFF_F800 },
        // maxInt itself is representable here, so it must not trap.
        .{ .op = .@"i32.trunc_f64_s", .src = .{ .f64 = 2147483647.9 }, .want = 0x7FFF_FFFF },
        .{ .op = .@"i32.trunc_f64_u", .src = .{ .f64 = 4294967295.9 }, .want = 0xFFFF_FFFF },
    };
    for (cases) |case| {
        try rt.pushOperand(case.src);
        try driveOne(&rt, &t, case.op, 0, 0);
        const got = rt.popOperand();
        const is_i32 = std.mem.startsWith(u8, @tagName(case.op), "i32");
        try testing.expectEqual(case.want, if (is_i32) got.u32 else got.u64);
    }
}

test "f32.demote_f64 + f64.promote_f32 round-trip" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f64 = 3.5 });
    try driveOne(&rt, &t, .@"f32.demote_f64", 0, 0);
    try driveOne(&rt, &t, .@"f64.promote_f32", 0, 0);
    try testing.expectEqual(@as(f64, 3.5), rt.popOperand().f64);
}

test "i32.reinterpret_f32 + f32.reinterpret_i32: bit-preserving" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f32 = 1.0 });
    try driveOne(&rt, &t, .@"i32.reinterpret_f32", 0, 0);
    try testing.expectEqual(@as(u32, 0x3F800000), rt.popOperand().u32);

    try rt.pushOperand(.{ .u32 = 0x3F800000 });
    try driveOne(&rt, &t, .@"f32.reinterpret_i32", 0, 0);
    try testing.expectEqual(@as(f32, 1.0), rt.popOperand().f32);
}
