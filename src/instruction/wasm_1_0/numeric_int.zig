//! MVP integer ops carve-out (§9.5 / 5.1 split from `mvp.zig`).
//!
//! Holds i32 / i64 constants + numeric ops (unary, binary,
//! relational). The `register()` here installs only this module's
//! slots; the residual `mvp.zig` shell calls each split's
//! `register()` so a single `mvp.register(table)` still wires the
//! full ZirOp surface into the dispatch table.
//!
//! Wraparound semantics for integer arithmetic: Wasm `add` /
//! `sub` / `mul` are mod 2^N (`+%` / `-%` / `*%` in Zig). `div_s`
//! / `div_u` / `rem_s` / `rem_u` trap on divisor=0 and (signed
//! div only) on INT_MIN/-1 (`Trap.IntOverflow`). Shifts use the
//! lower-N-bits-of-shift-amount rule (`& (N-1)`).
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
const Trap = runtime.Trap;

inline fn op(t: ZirOp) usize {
    return @backingInt(t);
}

pub fn register(table: *DispatchTable) void {
    // Constants
    table.interp[op(.@"i32.const")] = i32Const;
    table.interp[op(.@"i64.const")] = i64Const;

    // i32 testop / unops
    table.interp[op(.@"i32.eqz")] = i32Eqz;
    table.interp[op(.@"i32.clz")] = i32Clz;
    table.interp[op(.@"i32.ctz")] = i32Ctz;
    table.interp[op(.@"i32.popcnt")] = i32Popcnt;

    // i32 binops
    table.interp[op(.@"i32.add")] = i32Add;
    table.interp[op(.@"i32.sub")] = i32Sub;
    table.interp[op(.@"i32.mul")] = i32Mul;
    table.interp[op(.@"i32.div_s")] = i32DivS;
    table.interp[op(.@"i32.div_u")] = i32DivU;
    table.interp[op(.@"i32.rem_s")] = i32RemS;
    table.interp[op(.@"i32.rem_u")] = i32RemU;
    table.interp[op(.@"i32.and")] = i32And;
    table.interp[op(.@"i32.or")] = i32Or;
    table.interp[op(.@"i32.xor")] = i32Xor;
    table.interp[op(.@"i32.shl")] = i32Shl;
    table.interp[op(.@"i32.shr_s")] = i32ShrS;
    table.interp[op(.@"i32.shr_u")] = i32ShrU;
    table.interp[op(.@"i32.rotl")] = i32Rotl;
    table.interp[op(.@"i32.rotr")] = i32Rotr;

    // i32 relops
    table.interp[op(.@"i32.eq")] = i32Eq;
    table.interp[op(.@"i32.ne")] = i32Ne;
    table.interp[op(.@"i32.lt_s")] = i32LtS;
    table.interp[op(.@"i32.lt_u")] = i32LtU;
    table.interp[op(.@"i32.gt_s")] = i32GtS;
    table.interp[op(.@"i32.gt_u")] = i32GtU;
    table.interp[op(.@"i32.le_s")] = i32LeS;
    table.interp[op(.@"i32.le_u")] = i32LeU;
    table.interp[op(.@"i32.ge_s")] = i32GeS;
    table.interp[op(.@"i32.ge_u")] = i32GeU;

    // i64 testop / unops
    table.interp[op(.@"i64.eqz")] = i64Eqz;
    table.interp[op(.@"i64.clz")] = i64Clz;
    table.interp[op(.@"i64.ctz")] = i64Ctz;
    table.interp[op(.@"i64.popcnt")] = i64Popcnt;

    // i64 binops
    table.interp[op(.@"i64.add")] = i64Add;
    table.interp[op(.@"i64.sub")] = i64Sub;
    table.interp[op(.@"i64.mul")] = i64Mul;
    // wide arithmetic (ADR-0168 v0.2) — 128-bit multi-result.
    table.interp[op(.@"i64.add128")] = i64Add128;
    table.interp[op(.@"i64.sub128")] = i64Sub128;
    table.interp[op(.@"i64.mul_wide_s")] = i64MulWideS;
    table.interp[op(.@"i64.mul_wide_u")] = i64MulWideU;
    table.interp[op(.@"i64.div_s")] = i64DivS;
    table.interp[op(.@"i64.div_u")] = i64DivU;
    table.interp[op(.@"i64.rem_s")] = i64RemS;
    table.interp[op(.@"i64.rem_u")] = i64RemU;
    table.interp[op(.@"i64.and")] = i64And;
    table.interp[op(.@"i64.or")] = i64Or;
    table.interp[op(.@"i64.xor")] = i64Xor;
    table.interp[op(.@"i64.shl")] = i64Shl;
    table.interp[op(.@"i64.shr_s")] = i64ShrS;
    table.interp[op(.@"i64.shr_u")] = i64ShrU;
    table.interp[op(.@"i64.rotl")] = i64Rotl;
    table.interp[op(.@"i64.rotr")] = i64Rotr;

    // i64 relops
    table.interp[op(.@"i64.eq")] = i64Eq;
    table.interp[op(.@"i64.ne")] = i64Ne;
    table.interp[op(.@"i64.lt_s")] = i64LtS;
    table.interp[op(.@"i64.lt_u")] = i64LtU;
    table.interp[op(.@"i64.gt_s")] = i64GtS;
    table.interp[op(.@"i64.gt_u")] = i64GtU;
    table.interp[op(.@"i64.le_s")] = i64LeS;
    table.interp[op(.@"i64.le_u")] = i64LeU;
    table.interp[op(.@"i64.ge_s")] = i64GeS;
    table.interp[op(.@"i64.ge_u")] = i64GeU;
}

// ============================================================
// Handlers — i32 / i64 constants
// ============================================================

fn i32Const(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .i32 = @bitCast(@as(u32, @truncate(instr.payload))) });
}
fn i64Const(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const lo: u64 = instr.payload;
    const hi: u64 = instr.extra;
    try rt.pushOperand(.{ .u64 = lo | (hi << 32) });
}

// ============================================================
// Handlers — i32 unops / binops / relops
// ============================================================

fn i32Eqz(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().i32;
    try rt.pushOperand(.{ .i32 = if (x == 0) 1 else 0 });
}

fn i32Clz(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u32;
    const r: i32 = @intCast(@clz(x));
    try rt.pushOperand(.{ .i32 = r });
}

fn i32Ctz(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u32;
    const r: i32 = @intCast(@ctz(x));
    try rt.pushOperand(.{ .i32 = r });
}

fn i32Popcnt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u32;
    const r: i32 = @intCast(@popCount(x));
    try rt.pushOperand(.{ .i32 = r });
}

// --- i32 binops ---

fn popI32Pair(rt: *Runtime) Trap!struct { a: i32, b: i32 } {
    if (rt.operand_len < 2) return Trap.Unreachable;
    const b = rt.popOperand().i32;
    const a = rt.popOperand().i32;
    return .{ .a = a, .b = b };
}

fn popU32Pair(rt: *Runtime) Trap!struct { a: u32, b: u32 } {
    if (rt.operand_len < 2) return Trap.Unreachable;
    const b = rt.popOperand().u32;
    const a = rt.popOperand().u32;
    return .{ .a = a, .b = b };
}

fn i32Add(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popI32Pair(rt);
    try rt.pushOperand(.{ .i32 = p.a +% p.b });
}

fn i32Sub(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popI32Pair(rt);
    try rt.pushOperand(.{ .i32 = p.a -% p.b });
}

fn i32Mul(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popI32Pair(rt);
    try rt.pushOperand(.{ .i32 = p.a *% p.b });
}

fn i32DivS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popI32Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    if (p.a == std.math.minInt(i32) and p.b == -1) return Trap.IntOverflow;
    try rt.pushOperand(.{ .i32 = @divTrunc(p.a, p.b) });
}

fn i32DivU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    try rt.pushOperand(.{ .u32 = p.a / p.b });
}

fn i32RemS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popI32Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    // INT_MIN % -1 = 0 in Wasm; @rem would overflow.
    if (p.a == std.math.minInt(i32) and p.b == -1) {
        try rt.pushOperand(.{ .i32 = 0 });
        return;
    }
    try rt.pushOperand(.{ .i32 = @rem(p.a, p.b) });
}

fn i32RemU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    try rt.pushOperand(.{ .u32 = p.a % p.b });
}

fn i32And(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    try rt.pushOperand(.{ .u32 = p.a & p.b });
}

fn i32Or(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    try rt.pushOperand(.{ .u32 = p.a | p.b });
}

fn i32Xor(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    try rt.pushOperand(.{ .u32 = p.a ^ p.b });
}

fn i32Shl(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    const sh: u5 = @intCast(p.b & 31);
    try rt.pushOperand(.{ .u32 = p.a << sh });
}

fn i32ShrS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popI32Pair(rt);
    const sh: u5 = @intCast(@as(u32, @bitCast(p.b)) & 31);
    try rt.pushOperand(.{ .i32 = p.a >> sh });
}

fn i32ShrU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    const sh: u5 = @intCast(p.b & 31);
    try rt.pushOperand(.{ .u32 = p.a >> sh });
}

fn i32Rotl(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    const sh: u5 = @intCast(p.b & 31);
    try rt.pushOperand(.{ .u32 = std.math.rotl(u32, p.a, sh) });
}

fn i32Rotr(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    const sh: u5 = @intCast(p.b & 31);
    try rt.pushOperand(.{ .u32 = std.math.rotr(u32, p.a, sh) });
}

// --- i32 relops ---

inline fn pushBool(rt: *Runtime, b: bool) anyerror!void {
    try rt.pushOperand(.{ .i32 = if (b) 1 else 0 });
}

fn i32Eq(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popI32Pair(rt);
    try pushBool(rt, p.a == p.b);
}
fn i32Ne(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popI32Pair(rt);
    try pushBool(rt, p.a != p.b);
}
fn i32LtS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popI32Pair(rt);
    try pushBool(rt, p.a < p.b);
}
fn i32LtU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    try pushBool(rt, p.a < p.b);
}
fn i32GtS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popI32Pair(rt);
    try pushBool(rt, p.a > p.b);
}
fn i32GtU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    try pushBool(rt, p.a > p.b);
}
fn i32LeS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popI32Pair(rt);
    try pushBool(rt, p.a <= p.b);
}
fn i32LeU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    try pushBool(rt, p.a <= p.b);
}
fn i32GeS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popI32Pair(rt);
    try pushBool(rt, p.a >= p.b);
}
fn i32GeU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = try popU32Pair(rt);
    try pushBool(rt, p.a >= p.b);
}

// --- i64 unops / testop ---

fn i64Eqz(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().i64;
    try rt.pushOperand(.{ .i32 = if (x == 0) 1 else 0 });
}

fn i64Clz(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u64;
    const r: i64 = @intCast(@clz(x));
    try rt.pushOperand(.{ .i64 = r });
}

fn i64Ctz(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u64;
    const r: i64 = @intCast(@ctz(x));
    try rt.pushOperand(.{ .i64 = r });
}

fn i64Popcnt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u64;
    const r: i64 = @intCast(@popCount(x));
    try rt.pushOperand(.{ .i64 = r });
}

// --- i64 binops ---

fn popI64Pair(rt: *Runtime) struct { a: i64, b: i64 } {
    const b = rt.popOperand().i64;
    const a = rt.popOperand().i64;
    return .{ .a = a, .b = b };
}

fn popU64Pair(rt: *Runtime) struct { a: u64, b: u64 } {
    const b = rt.popOperand().u64;
    const a = rt.popOperand().u64;
    return .{ .a = a, .b = b };
}

fn i64Add(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try rt.pushOperand(.{ .i64 = p.a +% p.b });
}

fn i64Sub(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try rt.pushOperand(.{ .i64 = p.a -% p.b });
}

fn i64Mul(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try rt.pushOperand(.{ .i64 = p.a *% p.b });
}

// --- wide arithmetic (ADR-0168 v0.2) — 128-bit math, multi-result ---
// Operand order per spec: a 128-bit value is (lo, hi) with lo pushed
// first (deeper). add128/sub128 take two such pairs; mul_wide takes two
// scalars. All push (lo, hi) — lo first, hi on top. Zig native u128/i128
// does the assembly/split.

/// `i64.add128` — pop [a_lo, a_hi, b_lo, b_hi], push [r_lo, r_hi] (wrapping).
fn i64Add128(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const b_hi = rt.popOperand().u64;
    const b_lo = rt.popOperand().u64;
    const a_hi = rt.popOperand().u64;
    const a_lo = rt.popOperand().u64;
    const a: u128 = (@as(u128, a_hi) << 64) | a_lo;
    const b: u128 = (@as(u128, b_hi) << 64) | b_lo;
    const r = a +% b;
    try rt.pushOperand(.{ .u64 = @truncate(r) });
    try rt.pushOperand(.{ .u64 = @truncate(r >> 64) });
}

/// `i64.sub128` — pop [a_lo, a_hi, b_lo, b_hi], push [r_lo, r_hi] (wrapping).
fn i64Sub128(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const b_hi = rt.popOperand().u64;
    const b_lo = rt.popOperand().u64;
    const a_hi = rt.popOperand().u64;
    const a_lo = rt.popOperand().u64;
    const a: u128 = (@as(u128, a_hi) << 64) | a_lo;
    const b: u128 = (@as(u128, b_hi) << 64) | b_lo;
    const r = a -% b;
    try rt.pushOperand(.{ .u64 = @truncate(r) });
    try rt.pushOperand(.{ .u64 = @truncate(r >> 64) });
}

/// `i64.mul_wide_u` — pop a, b, push the full 128-bit unsigned product [lo, hi].
fn i64MulWideU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const b = rt.popOperand().u64;
    const a = rt.popOperand().u64;
    const r: u128 = @as(u128, a) * @as(u128, b);
    try rt.pushOperand(.{ .u64 = @truncate(r) });
    try rt.pushOperand(.{ .u64 = @truncate(r >> 64) });
}

/// `i64.mul_wide_s` — pop a, b, push the full 128-bit signed product [lo, hi].
fn i64MulWideS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const b = rt.popOperand().u64;
    const a = rt.popOperand().u64;
    const sa: i128 = @as(i64, @bitCast(a));
    const sb: i128 = @as(i64, @bitCast(b));
    const r: u128 = @bitCast(sa * sb);
    try rt.pushOperand(.{ .u64 = @truncate(r) });
    try rt.pushOperand(.{ .u64 = @truncate(r >> 64) });
}

fn i64DivS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    if (p.a == std.math.minInt(i64) and p.b == -1) return Trap.IntOverflow;
    try rt.pushOperand(.{ .i64 = @divTrunc(p.a, p.b) });
}

fn i64DivU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    try rt.pushOperand(.{ .u64 = p.a / p.b });
}

fn i64RemS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    if (p.a == std.math.minInt(i64) and p.b == -1) {
        try rt.pushOperand(.{ .i64 = 0 });
        return;
    }
    try rt.pushOperand(.{ .i64 = @rem(p.a, p.b) });
}

fn i64RemU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    try rt.pushOperand(.{ .u64 = p.a % p.b });
}

fn i64And(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try rt.pushOperand(.{ .u64 = p.a & p.b });
}

fn i64Or(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try rt.pushOperand(.{ .u64 = p.a | p.b });
}

fn i64Xor(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try rt.pushOperand(.{ .u64 = p.a ^ p.b });
}

fn i64Shl(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    const sh: u6 = @intCast(p.b & 63);
    try rt.pushOperand(.{ .u64 = p.a << sh });
}

fn i64ShrS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    const sh: u6 = @intCast(@as(u64, @bitCast(p.b)) & 63);
    try rt.pushOperand(.{ .i64 = p.a >> sh });
}

fn i64ShrU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    const sh: u6 = @intCast(p.b & 63);
    try rt.pushOperand(.{ .u64 = p.a >> sh });
}

fn i64Rotl(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    const sh: u6 = @intCast(p.b & 63);
    try rt.pushOperand(.{ .u64 = std.math.rotl(u64, p.a, sh) });
}

fn i64Rotr(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    const sh: u6 = @intCast(p.b & 63);
    try rt.pushOperand(.{ .u64 = std.math.rotr(u64, p.a, sh) });
}

// --- i64 relops ---

fn i64Eq(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try pushBool(rt, p.a == p.b);
}
fn i64Ne(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try pushBool(rt, p.a != p.b);
}
fn i64LtS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try pushBool(rt, p.a < p.b);
}
fn i64LtU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try pushBool(rt, p.a < p.b);
}
fn i64GtS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try pushBool(rt, p.a > p.b);
}
fn i64GtU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try pushBool(rt, p.a > p.b);
}
fn i64LeS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try pushBool(rt, p.a <= p.b);
}
fn i64LeU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try pushBool(rt, p.a <= p.b);
}
fn i64GeS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try pushBool(rt, p.a >= p.b);
}
fn i64GeU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try pushBool(rt, p.a >= p.b);
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

test "i32.const: pushes the bitcast u32 value" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, -7)), 0);
    try testing.expectEqual(@as(i32, -7), rt.popOperand().i32);
}

test "i64.const: low/high split round-trip" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const v: i64 = -1;
    const u: u64 = @bitCast(v);
    try driveOne(&rt, &t, .@"i64.const", @truncate(u), @truncate(u >> 32));
    try testing.expectEqual(@as(i64, -1), rt.popOperand().i64);
}
test "i32.add wraps modulo 2^32" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, std.math.maxInt(i32))), 0);
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 1)), 0);
    try driveOne(&rt, &t, .@"i32.add", 0, 0);
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), rt.popOperand().i32);
}

test "i32.div_s: 0 divisor traps DivByZero" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 7)), 0);
    try driveOne(&rt, &t, .@"i32.const", 0, 0);
    try testing.expectError(Trap.DivByZero, driveOne(&rt, &t, .@"i32.div_s", 0, 0));
}

test "i32.div_s: INT_MIN/-1 traps IntOverflow" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, std.math.minInt(i32))), 0);
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, -1)), 0);
    try testing.expectError(Trap.IntOverflow, driveOne(&rt, &t, .@"i32.div_s", 0, 0));
}

test "i32.rem_s: INT_MIN % -1 = 0 (no trap, spec rule)" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, std.math.minInt(i32))), 0);
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, -1)), 0);
    try driveOne(&rt, &t, .@"i32.rem_s", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "i32.shl: shift amount is masked to 5 bits" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", 1, 0);
    try driveOne(&rt, &t, .@"i32.const", 33, 0); // 33 mod 32 = 1
    try driveOne(&rt, &t, .@"i32.shl", 0, 0);
    try testing.expectEqual(@as(u32, 2), rt.popOperand().u32);
}

test "i32 relops: lt_s/lt_u differ for sign" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    // -1 vs 1 — signed: -1 < 1 = true; unsigned: 0xFFFFFFFF > 1 = false.
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, -1)), 0);
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 1)), 0);
    try driveOne(&rt, &t, .@"i32.lt_s", 0, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, -1)), 0);
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 1)), 0);
    try driveOne(&rt, &t, .@"i32.lt_u", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "i32.eqz: 0 → 1, nonzero → 0" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", 0, 0);
    try driveOne(&rt, &t, .@"i32.eqz", 0, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);

    try driveOne(&rt, &t, .@"i32.const", 7, 0);
    try driveOne(&rt, &t, .@"i32.eqz", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "i32.clz / ctz / popcnt round-trip" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", 1, 0);
    try driveOne(&rt, &t, .@"i32.clz", 0, 0);
    try testing.expectEqual(@as(i32, 31), rt.popOperand().i32);

    try driveOne(&rt, &t, .@"i32.const", 8, 0);
    try driveOne(&rt, &t, .@"i32.ctz", 0, 0);
    try testing.expectEqual(@as(i32, 3), rt.popOperand().i32);

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, -1)), 0);
    try driveOne(&rt, &t, .@"i32.popcnt", 0, 0);
    try testing.expectEqual(@as(i32, 32), rt.popOperand().i32);
}
test "i64.add wraps modulo 2^64" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const lo_max: u64 = @bitCast(@as(i64, std.math.maxInt(i64)));
    try driveOne(&rt, &t, .@"i64.const", @truncate(lo_max), @truncate(lo_max >> 32));
    try driveOne(&rt, &t, .@"i64.const", 1, 0);
    try driveOne(&rt, &t, .@"i64.add", 0, 0);
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), rt.popOperand().i64);
}

test "i64.div_s: INT_MIN/-1 traps IntOverflow" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const min_lo: u64 = @bitCast(@as(i64, std.math.minInt(i64)));
    try driveOne(&rt, &t, .@"i64.const", @truncate(min_lo), @truncate(min_lo >> 32));
    const minus_one: u64 = @bitCast(@as(i64, -1));
    try driveOne(&rt, &t, .@"i64.const", @truncate(minus_one), @truncate(minus_one >> 32));
    try testing.expectError(Trap.IntOverflow, driveOne(&rt, &t, .@"i64.div_s", 0, 0));
}

test "i64.shl masks shift count to 6 bits" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i64.const", 1, 0);
    try driveOne(&rt, &t, .@"i64.const", 65, 0); // 65 mod 64 = 1
    try driveOne(&rt, &t, .@"i64.shl", 0, 0);
    try testing.expectEqual(@as(u64, 2), rt.popOperand().u64);
}

test "i64.eqz: 0 → 1, nonzero → 0" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i64.const", 0, 0);
    try driveOne(&rt, &t, .@"i64.eqz", 0, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}

test "i64.lt_u: high bits respected" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // 0x1_0000_0000 vs 0x2 — unsigned: a > b
    try driveOne(&rt, &t, .@"i64.const", 0, 1);
    try driveOne(&rt, &t, .@"i64.const", 2, 0);
    try driveOne(&rt, &t, .@"i64.lt_u", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "i64.add128: carry propagates lo→hi" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // a = (lo=max, hi=0) = 2^64-1 ; b = (lo=1, hi=0) = 1 → r = 2^64 = (lo=0, hi=1).
    try rt.pushOperand(.{ .u64 = 0xFFFFFFFFFFFFFFFF }); // a_lo
    try rt.pushOperand(.{ .u64 = 0 }); // a_hi
    try rt.pushOperand(.{ .u64 = 1 }); // b_lo
    try rt.pushOperand(.{ .u64 = 0 }); // b_hi
    try driveOne(&rt, &t, .@"i64.add128", 0, 0);
    try testing.expectEqual(@as(u64, 1), rt.popOperand().u64); // r_hi (top)
    try testing.expectEqual(@as(u64, 0), rt.popOperand().u64); // r_lo
}

test "i64.sub128: borrow propagates lo→hi" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // a = (lo=0, hi=1) = 2^64 ; b = (lo=1, hi=0) = 1 → r = 2^64-1 = (lo=max, hi=0).
    try rt.pushOperand(.{ .u64 = 0 }); // a_lo
    try rt.pushOperand(.{ .u64 = 1 }); // a_hi
    try rt.pushOperand(.{ .u64 = 1 }); // b_lo
    try rt.pushOperand(.{ .u64 = 0 }); // b_hi
    try driveOne(&rt, &t, .@"i64.sub128", 0, 0);
    try testing.expectEqual(@as(u64, 0), rt.popOperand().u64); // r_hi
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), rt.popOperand().u64); // r_lo
}

test "i64.mul_wide_u: full unsigned 128-bit product" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // 0xFFFFFFFFFFFFFFFF * 2 = 0x1_FFFFFFFFFFFFFFFE → lo=0xFFFFFFFFFFFFFFFE, hi=1.
    try rt.pushOperand(.{ .u64 = 0xFFFFFFFFFFFFFFFF }); // a
    try rt.pushOperand(.{ .u64 = 2 }); // b
    try driveOne(&rt, &t, .@"i64.mul_wide_u", 0, 0);
    try testing.expectEqual(@as(u64, 1), rt.popOperand().u64); // hi
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFE), rt.popOperand().u64); // lo
}

test "i64.mul_wide_s: signed product sign-extends the high word" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // (-1) * (-1) = 1 → lo=1, hi=0.
    try rt.pushOperand(.{ .u64 = 0xFFFFFFFFFFFFFFFF }); // a = -1
    try rt.pushOperand(.{ .u64 = 0xFFFFFFFFFFFFFFFF }); // b = -1
    try driveOne(&rt, &t, .@"i64.mul_wide_s", 0, 0);
    try testing.expectEqual(@as(u64, 0), rt.popOperand().u64); // hi
    try testing.expectEqual(@as(u64, 1), rt.popOperand().u64); // lo
    // (-1) * 2 = -2 → lo=0xFFFFFFFFFFFFFFFE, hi=0xFFFFFFFFFFFFFFFF (sign-extended).
    try rt.pushOperand(.{ .u64 = 0xFFFFFFFFFFFFFFFF }); // a = -1
    try rt.pushOperand(.{ .u64 = 2 }); // b = 2
    try driveOne(&rt, &t, .@"i64.mul_wide_s", 0, 0);
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), rt.popOperand().u64); // hi
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFE), rt.popOperand().u64); // lo
}
