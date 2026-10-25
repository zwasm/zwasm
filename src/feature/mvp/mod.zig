//! MVP feature module — Wasm 1.0 opcode handlers registered into the
//! central `DispatchTable` per ROADMAP §4.5 / §A12.
//!
//! `register(*DispatchTable)` installs per-opcode handlers into the
//! `parsers` slot. Each handler reads its immediate operand(s) (if
//! any) from a `*ParserCtx` (cast back to the concrete `Ctx` from
//! `parse/ctx.zig`) and packs the result into the
//! caller-supplied `*ZirInstr`. The caller pre-fills `instr.op` and
//! positions the `Ctx` cursor immediately after the opcode byte.
//!
//! Phase 1.7 establishes the registration pattern with the MVP
//! opcode subset already lowered by `ir/lower.zig`. The
//! lowerer keeps its inline switch for Phase 1; the production
//! frontend migrates to dispatch-table consumption when Phase 2
//! (interp) wires the table for runtime dispatch.
//!
//! Zone 1 (`src/feature/mvp/`) — imports Zone 1 (`ir/`,
//! `parse/ctx.zig`).

const std = @import("std");

const dispatch = @import("../../ir/dispatch_table.zig");
const zir = @import("../../ir/zir.zig");
const parse_ctx = @import("../../parse/ctx.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const ParserCtx = dispatch.ParserCtx;
const Ctx = parse_ctx.Ctx;

const no_immediate_ops = [_]ZirOp{
    .@"unreachable",
    .nop,
    .@"return",
    .drop,
    .@"i32.eqz",
    .@"i32.add",
    .@"i32.sub",
    .@"i32.mul",
};

const local_indexed_ops = [_]ZirOp{
    .@"local.get",
    .@"local.set",
    .@"local.tee",
};

pub fn register(table: *DispatchTable) void {
    inline for (no_immediate_ops) |op| {
        table.parsers[@backingInt(op)] = parseNoImmediate;
    }
    inline for (local_indexed_ops) |op| {
        table.parsers[@backingInt(op)] = parseLocalIndexed;
    }
    table.parsers[@backingInt(ZirOp.@"i32.const")] = parseI32Const;
    table.parsers[@backingInt(ZirOp.@"i64.const")] = parseI64Const;
    table.parsers[@backingInt(ZirOp.@"f32.const")] = parseF32Const;
    table.parsers[@backingInt(ZirOp.@"f64.const")] = parseF64Const;
    table.parsers[@backingInt(ZirOp.br)] = parseBr;
}

fn parseNoImmediate(_: *ParserCtx, instr: *ZirInstr) anyerror!void {
    instr.payload = 0;
    instr.extra = 0;
}

fn parseLocalIndexed(opaque_ctx: *ParserCtx, instr: *ZirInstr) anyerror!void {
    const ctx = Ctx.fromOpaque(opaque_ctx);
    instr.payload = try ctx.readUleb32();
    instr.extra = 0;
}

fn parseBr(opaque_ctx: *ParserCtx, instr: *ZirInstr) anyerror!void {
    const ctx = Ctx.fromOpaque(opaque_ctx);
    instr.payload = try ctx.readUleb32();
    instr.extra = 0;
}

fn parseI32Const(opaque_ctx: *ParserCtx, instr: *ZirInstr) anyerror!void {
    const ctx = Ctx.fromOpaque(opaque_ctx);
    const v = try ctx.readSleb32();
    instr.payload = @as(u32, @bitCast(v));
    instr.extra = 0;
}

fn parseI64Const(opaque_ctx: *ParserCtx, instr: *ZirInstr) anyerror!void {
    const ctx = Ctx.fromOpaque(opaque_ctx);
    const v = try ctx.readSleb64();
    const u: u64 = @bitCast(v);
    instr.payload = @as(u32, @truncate(u));
    instr.extra = @truncate(u >> 32);
}

fn parseF32Const(opaque_ctx: *ParserCtx, instr: *ZirInstr) anyerror!void {
    const ctx = Ctx.fromOpaque(opaque_ctx);
    instr.payload = try ctx.readF32Bits();
    instr.extra = 0;
}

fn parseF64Const(opaque_ctx: *ParserCtx, instr: *ZirInstr) anyerror!void {
    const ctx = Ctx.fromOpaque(opaque_ctx);
    const bits = try ctx.readF64Bits();
    instr.payload = bits.lo;
    instr.extra = bits.hi;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn dispatchOp(table: *const DispatchTable, op: ZirOp, body: []const u8) !ZirInstr {
    const slot = table.parsers[@backingInt(op)] orelse return error.NoHandler;
    var ctx = Ctx.init(body);
    var instr: ZirInstr = .{ .op = op, .payload = 0, .extra = 0 };
    try slot(ctx.opaqueSelf(), &instr);
    return instr;
}

test "register: no-immediate ops are populated" {
    var table = DispatchTable.init();
    register(&table);
    inline for (no_immediate_ops) |op| {
        try testing.expect(table.parsers[@backingInt(op)] != null);
    }
}

test "register: local-indexed ops are populated" {
    var table = DispatchTable.init();
    register(&table);
    inline for (local_indexed_ops) |op| {
        try testing.expect(table.parsers[@backingInt(op)] != null);
    }
}

test "register: const + br ops are populated" {
    var table = DispatchTable.init();
    register(&table);
    try testing.expect(table.parsers[@backingInt(ZirOp.@"i32.const")] != null);
    try testing.expect(table.parsers[@backingInt(ZirOp.@"i64.const")] != null);
    try testing.expect(table.parsers[@backingInt(ZirOp.@"f32.const")] != null);
    try testing.expect(table.parsers[@backingInt(ZirOp.@"f64.const")] != null);
    try testing.expect(table.parsers[@backingInt(ZirOp.br)] != null);
}

test "register: untouched slots remain null" {
    var table = DispatchTable.init();
    register(&table);
    // call_indirect is not in MVP scope of 1.7
    try testing.expect(table.parsers[@backingInt(ZirOp.call_indirect)] == null);
    try testing.expect(table.interp[@backingInt(ZirOp.@"i32.add")] == null);
    try testing.expect(table.jit_arm64[@backingInt(ZirOp.@"i32.add")] == null);
}

test "dispatch: parseNoImmediate yields zero payload + extra" {
    var table = DispatchTable.init();
    register(&table);
    const inst = try dispatchOp(&table, .@"i32.add", &.{});
    try testing.expectEqual(@as(u32, 0), inst.payload);
    try testing.expectEqual(@as(u32, 0), inst.extra);
}

test "dispatch: parseI32Const reads sleb128 and bitcasts to u32" {
    var table = DispatchTable.init();
    register(&table);
    // sleb128(-1) = 0x7F → bitcast u32 = 0xFFFF_FFFF
    const inst = try dispatchOp(&table, .@"i32.const", &[_]u8{0x7F});
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), inst.payload);
    try testing.expectEqual(@as(u32, 0), inst.extra);
}

test "dispatch: parseI64Const splits low32 / high32" {
    var table = DispatchTable.init();
    register(&table);
    // sleb128(-1) for i64 = 0x7F → bitcast u64 = 0xFFFF...FFFF
    const inst = try dispatchOp(&table, .@"i64.const", &[_]u8{0x7F});
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), inst.payload);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), inst.extra);
}

test "dispatch: parseF32Const reads raw 4 bytes" {
    var table = DispatchTable.init();
    register(&table);
    const inst = try dispatchOp(&table, .@"f32.const", &[_]u8{ 0x00, 0x00, 0x80, 0x3F });
    try testing.expectEqual(@as(u32, 0x3F800000), inst.payload);
    try testing.expectEqual(@as(u32, 0), inst.extra);
}

test "dispatch: parseF64Const splits raw 8 bytes" {
    var table = DispatchTable.init();
    register(&table);
    const inst = try dispatchOp(&table, .@"f64.const", &[_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F,
    });
    try testing.expectEqual(@as(u32, 0x0000_0000), inst.payload);
    try testing.expectEqual(@as(u32, 0x3FF0_0000), inst.extra);
}

test "dispatch: parseLocalIndexed reads uleb32" {
    var table = DispatchTable.init();
    register(&table);
    const inst = try dispatchOp(&table, .@"local.get", &[_]u8{0x05});
    try testing.expectEqual(@as(u32, 5), inst.payload);
    try testing.expectEqual(@as(u32, 0), inst.extra);
}

test "dispatch: parseBr reads uleb32 depth" {
    var table = DispatchTable.init();
    register(&table);
    const inst = try dispatchOp(&table, .br, &[_]u8{0x03});
    try testing.expectEqual(@as(u32, 3), inst.payload);
}
