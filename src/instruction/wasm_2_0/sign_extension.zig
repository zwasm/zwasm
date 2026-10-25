//! Wasm 2.0 sign-extension interp handlers (§9.2 / 2.3 chunk 1).
//!
//! Opcodes 0xC0..0xC4. Each pops the source ValType, sign-extends
//! from the low N bits, pushes back the same ValType. No trap, no
//! immediate. Per-feature interp module split (ROADMAP §4.5 /
//! §A12); handlers register into the central
//! `DispatchTable.interp` slot like the MVP module does.
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
    table.interp[op(.@"i32.extend8_s")] = i32Extend8s;
    table.interp[op(.@"i32.extend16_s")] = i32Extend16s;
    table.interp[op(.@"i64.extend8_s")] = i64Extend8s;
    table.interp[op(.@"i64.extend16_s")] = i64Extend16s;
    table.interp[op(.@"i64.extend32_s")] = i64Extend32s;
}

fn i32Extend8s(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().i32;
    const low: i8 = @truncate(x);
    try rt.pushOperand(.{ .i32 = @as(i32, low) });
}

fn i32Extend16s(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().i32;
    const low: i16 = @truncate(x);
    try rt.pushOperand(.{ .i32 = @as(i32, low) });
}

fn i64Extend8s(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().i64;
    const low: i8 = @truncate(x);
    try rt.pushOperand(.{ .i64 = @as(i64, low) });
}

fn i64Extend16s(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().i64;
    const low: i16 = @truncate(x);
    try rt.pushOperand(.{ .i64 = @as(i64, low) });
}

fn i64Extend32s(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().i64;
    const low: i32 = @truncate(x);
    try rt.pushOperand(.{ .i64 = @as(i64, low) });
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("../../interp/dispatch.zig");
const Trap = runtime.Trap;

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "register: all five sign-ext slots populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"i32.extend8_s")] != null);
    try testing.expect(t.interp[op(.@"i32.extend16_s")] != null);
    try testing.expect(t.interp[op(.@"i64.extend8_s")] != null);
    try testing.expect(t.interp[op(.@"i64.extend16_s")] != null);
    try testing.expect(t.interp[op(.@"i64.extend32_s")] != null);
}

test "i32.extend8_s: 0xFF → -1" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 0xFF });
    try driveOne(&rt, &t, .@"i32.extend8_s", 0, 0);
    try testing.expectEqual(@as(i32, -1), rt.popOperand().i32);
}

test "i32.extend8_s: 0x7F → 127 (no extension)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 0x7F });
    try driveOne(&rt, &t, .@"i32.extend8_s", 0, 0);
    try testing.expectEqual(@as(i32, 127), rt.popOperand().i32);
}

test "i32.extend8_s: 0x80 → -128" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 0x80 });
    try driveOne(&rt, &t, .@"i32.extend8_s", 0, 0);
    try testing.expectEqual(@as(i32, -128), rt.popOperand().i32);
}

test "i32.extend8_s: ignores high bits beyond low 8" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = @bitCast(@as(u32, 0xDEADBE_FF)) });
    try driveOne(&rt, &t, .@"i32.extend8_s", 0, 0);
    try testing.expectEqual(@as(i32, -1), rt.popOperand().i32);
}

test "i32.extend16_s: 0xFFFF → -1" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 0xFFFF });
    try driveOne(&rt, &t, .@"i32.extend16_s", 0, 0);
    try testing.expectEqual(@as(i32, -1), rt.popOperand().i32);
}

test "i32.extend16_s: 0x7FFF → 32767" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 0x7FFF });
    try driveOne(&rt, &t, .@"i32.extend16_s", 0, 0);
    try testing.expectEqual(@as(i32, 32767), rt.popOperand().i32);
}

test "i32.extend16_s: ignores high bits beyond low 16" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = @bitCast(@as(u32, 0xDEAD_8000)) });
    try driveOne(&rt, &t, .@"i32.extend16_s", 0, 0);
    try testing.expectEqual(@as(i32, -32768), rt.popOperand().i32);
}

test "i64.extend8_s: 0xFF → -1" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i64 = 0xFF });
    try driveOne(&rt, &t, .@"i64.extend8_s", 0, 0);
    try testing.expectEqual(@as(i64, -1), rt.popOperand().i64);
}

test "i64.extend16_s: 0x8000 → -32768" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i64 = 0x8000 });
    try driveOne(&rt, &t, .@"i64.extend16_s", 0, 0);
    try testing.expectEqual(@as(i64, -32768), rt.popOperand().i64);
}

test "i64.extend32_s: 0xFFFF_FFFF → -1" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i64 = 0xFFFF_FFFF });
    try driveOne(&rt, &t, .@"i64.extend32_s", 0, 0);
    try testing.expectEqual(@as(i64, -1), rt.popOperand().i64);
}

test "i64.extend32_s: 0x8000_0000 → INT32_MIN" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i64 = 0x8000_0000 });
    try driveOne(&rt, &t, .@"i64.extend32_s", 0, 0);
    try testing.expectEqual(@as(i64, -2147483648), rt.popOperand().i64);
}

test "i64.extend32_s: ignores high 32 bits" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i64 = @bitCast(@as(u64, 0xDEAD_BEEF_8000_0000)) });
    try driveOne(&rt, &t, .@"i64.extend32_s", 0, 0);
    try testing.expectEqual(@as(i64, -2147483648), rt.popOperand().i64);
}

test "unbound op slot returns Trap.Unreachable (sign_ext only registers its five)" {
    var t = DispatchTable.init();
    register(&t);
    // i32.add was not registered by sign_ext; should still trap.
    try testing.expect(t.interp[op(.@"i32.add")] == null);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try testing.expectError(Trap.Unreachable, driveOne(&rt, &t, .@"i32.add", 0, 0));
}
