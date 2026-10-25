// FILE-SIZE-EXEMPT: uniform 48-handler load/store catalog, itself the §A2 extraction; further split yields N3-shallow siblings (investigated 2026-08-12, per ADR-0099)
//! MVP memory ops — loads / stores / memory.size / memory.grow
//! (Phase 2 / §9.2 / 2.2 chunk 5).
//!
//! Extracted from `src/interp/mvp.zig` for the §A2 file-size cap.
//! Effective address = base (popped i32) + memarg.offset (encoded
//! by the lowerer into `ZirInstr.payload`). Width-bounds check
//! against `Runtime.memory.len` traps `OutOfBoundsLoad` /
//! `OutOfBoundsStore`. f32 / f64 transit through `Value.bits64`
//! to preserve IEEE-754 without canonicalisation.
//!
//! Wasm 1.0 page size = 64 KiB, max 2^16 pages. `memory.grow`
//! returns -1 (i32) on OOM or page-cap overflow per spec.
//!
//! Zone 2 (`src/interp/`) — imports Zone 1 (`ir/`) and sibling
//! Zone 2 (`mod.zig`).

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

/// 10.M cycle 64 — return the byte slice of the memory targeted by
/// `instr.extra`'s `MemArgExtra.memidx` field (Wasm 3.0 §5.4.6
/// memarg encoding). For memidx=0 this is `rt.memories[0].bytes`
/// which aliases the legacy `rt.memory` per
/// `setMemory0Bytes` (ADR-0111 D2); for memidx > 0 this routes to
/// the corresponding entry in the `rt.memories` array.
///
/// Returns an empty slice when `rt.memories` is uninitialised (test
/// scaffolds that bypass the full instantiate path leave it empty
/// + rt.memory non-empty); falls back to `rt.memory` in that case
/// so MVP single-memory tests stay green.
inline fn memorySlice(rt: *Runtime, extra: u32) []u8 {
    const memidx: u8 = zir.MemArgExtra.unpack(extra).memidx;
    if (rt.memories.len == 0) return rt.memory;
    if (memidx >= rt.memories.len) return &[_]u8{};
    return rt.memories[memidx].bytes;
}

/// True when the memory at `extra`'s memidx is declared shared (the
/// 0x02 limits flag, threaded onto `MemoryInstance.shared`). Used by
/// `memory.atomic.wait*` to trap on a non-shared memory (ADR-0168).
/// The MVP test-scaffold fallback (memories empty) reports non-shared.
inline fn memShared(rt: *Runtime, extra: u32) bool {
    const memidx: u8 = zir.MemArgExtra.unpack(extra).memidx;
    if (rt.memories.len == 0 or memidx >= rt.memories.len) return false;
    return rt.memories[memidx].shared;
}

/// Custom-page-sizes (ADR-0168 v0.2) — the memory's page size in bytes
/// (`1 << page_size_log2`; default 64 KiB). `memory.size`/`grow` report/
/// operate in these units. Fallback (no `memories` entry) = 64 KiB.
inline fn memPageSizeAt(rt: *Runtime, memidx: usize) u64 {
    if (memidx < rt.memories.len) return @as(u64, 1) << @intCast(rt.memories[memidx].page_size_log2);
    return wasm_page_size;
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"i32.load")] = i32Load;
    table.interp[op(.@"i32.atomic.load")] = i32AtomicLoad;
    table.interp[op(.@"i64.atomic.load")] = i64AtomicLoad;
    table.interp[op(.@"i32.atomic.load8_u")] = i32AtomicLoad8U;
    table.interp[op(.@"i32.atomic.load16_u")] = i32AtomicLoad16U;
    table.interp[op(.@"i64.atomic.load8_u")] = i64AtomicLoad8U;
    table.interp[op(.@"i64.atomic.load16_u")] = i64AtomicLoad16U;
    table.interp[op(.@"i64.atomic.load32_u")] = i64AtomicLoad32U;
    table.interp[op(.@"i32.atomic.store")] = i32AtomicStore;
    table.interp[op(.@"i64.atomic.store")] = i64AtomicStore;
    table.interp[op(.@"i32.atomic.store8")] = i32AtomicStore8;
    table.interp[op(.@"i32.atomic.store16")] = i32AtomicStore16;
    table.interp[op(.@"i64.atomic.store8")] = i64AtomicStore8;
    table.interp[op(.@"i64.atomic.store16")] = i64AtomicStore16;
    table.interp[op(.@"i64.atomic.store32")] = i64AtomicStore32;
    // atomic rmw binops (threads, ADR-0168) — generic rmwHandler factory.
    table.interp[op(.@"i32.atomic.rmw.add")] = rmwHandler(u32, false, .add);
    table.interp[op(.@"i64.atomic.rmw.add")] = rmwHandler(u64, true, .add);
    table.interp[op(.@"i32.atomic.rmw8.add_u")] = rmwHandler(u8, false, .add);
    table.interp[op(.@"i32.atomic.rmw16.add_u")] = rmwHandler(u16, false, .add);
    table.interp[op(.@"i64.atomic.rmw8.add_u")] = rmwHandler(u8, true, .add);
    table.interp[op(.@"i64.atomic.rmw16.add_u")] = rmwHandler(u16, true, .add);
    table.interp[op(.@"i64.atomic.rmw32.add_u")] = rmwHandler(u32, true, .add);
    table.interp[op(.@"i32.atomic.rmw.sub")] = rmwHandler(u32, false, .sub);
    table.interp[op(.@"i64.atomic.rmw.sub")] = rmwHandler(u64, true, .sub);
    table.interp[op(.@"i32.atomic.rmw8.sub_u")] = rmwHandler(u8, false, .sub);
    table.interp[op(.@"i32.atomic.rmw16.sub_u")] = rmwHandler(u16, false, .sub);
    table.interp[op(.@"i64.atomic.rmw8.sub_u")] = rmwHandler(u8, true, .sub);
    table.interp[op(.@"i64.atomic.rmw16.sub_u")] = rmwHandler(u16, true, .sub);
    table.interp[op(.@"i64.atomic.rmw32.sub_u")] = rmwHandler(u32, true, .sub);
    table.interp[op(.@"i32.atomic.rmw.and")] = rmwHandler(u32, false, .@"and");
    table.interp[op(.@"i64.atomic.rmw.and")] = rmwHandler(u64, true, .@"and");
    table.interp[op(.@"i32.atomic.rmw8.and_u")] = rmwHandler(u8, false, .@"and");
    table.interp[op(.@"i32.atomic.rmw16.and_u")] = rmwHandler(u16, false, .@"and");
    table.interp[op(.@"i64.atomic.rmw8.and_u")] = rmwHandler(u8, true, .@"and");
    table.interp[op(.@"i64.atomic.rmw16.and_u")] = rmwHandler(u16, true, .@"and");
    table.interp[op(.@"i64.atomic.rmw32.and_u")] = rmwHandler(u32, true, .@"and");
    table.interp[op(.@"i32.atomic.rmw.or")] = rmwHandler(u32, false, .@"or");
    table.interp[op(.@"i64.atomic.rmw.or")] = rmwHandler(u64, true, .@"or");
    table.interp[op(.@"i32.atomic.rmw8.or_u")] = rmwHandler(u8, false, .@"or");
    table.interp[op(.@"i32.atomic.rmw16.or_u")] = rmwHandler(u16, false, .@"or");
    table.interp[op(.@"i64.atomic.rmw8.or_u")] = rmwHandler(u8, true, .@"or");
    table.interp[op(.@"i64.atomic.rmw16.or_u")] = rmwHandler(u16, true, .@"or");
    table.interp[op(.@"i64.atomic.rmw32.or_u")] = rmwHandler(u32, true, .@"or");
    table.interp[op(.@"i32.atomic.rmw.xor")] = rmwHandler(u32, false, .xor);
    table.interp[op(.@"i64.atomic.rmw.xor")] = rmwHandler(u64, true, .xor);
    table.interp[op(.@"i32.atomic.rmw8.xor_u")] = rmwHandler(u8, false, .xor);
    table.interp[op(.@"i32.atomic.rmw16.xor_u")] = rmwHandler(u16, false, .xor);
    table.interp[op(.@"i64.atomic.rmw8.xor_u")] = rmwHandler(u8, true, .xor);
    table.interp[op(.@"i64.atomic.rmw16.xor_u")] = rmwHandler(u16, true, .xor);
    table.interp[op(.@"i64.atomic.rmw32.xor_u")] = rmwHandler(u32, true, .xor);
    table.interp[op(.@"i32.atomic.rmw.xchg")] = rmwHandler(u32, false, .xchg);
    table.interp[op(.@"i64.atomic.rmw.xchg")] = rmwHandler(u64, true, .xchg);
    table.interp[op(.@"i32.atomic.rmw8.xchg_u")] = rmwHandler(u8, false, .xchg);
    table.interp[op(.@"i32.atomic.rmw16.xchg_u")] = rmwHandler(u16, false, .xchg);
    table.interp[op(.@"i64.atomic.rmw8.xchg_u")] = rmwHandler(u8, true, .xchg);
    table.interp[op(.@"i64.atomic.rmw16.xchg_u")] = rmwHandler(u16, true, .xchg);
    table.interp[op(.@"i64.atomic.rmw32.xchg_u")] = rmwHandler(u32, true, .xchg);
    // atomic cmpxchg (threads, ADR-0168) — compare-exchange.
    table.interp[op(.@"i32.atomic.rmw.cmpxchg")] = cmpxchgHandler(u32, false);
    table.interp[op(.@"i64.atomic.rmw.cmpxchg")] = cmpxchgHandler(u64, true);
    table.interp[op(.@"i32.atomic.rmw8.cmpxchg_u")] = cmpxchgHandler(u8, false);
    table.interp[op(.@"i32.atomic.rmw16.cmpxchg_u")] = cmpxchgHandler(u16, false);
    table.interp[op(.@"i64.atomic.rmw8.cmpxchg_u")] = cmpxchgHandler(u8, true);
    table.interp[op(.@"i64.atomic.rmw16.cmpxchg_u")] = cmpxchgHandler(u16, true);
    table.interp[op(.@"i64.atomic.rmw32.cmpxchg_u")] = cmpxchgHandler(u32, true);
    // atomic notify/wait (threads, ADR-0168) — single-thread substrate.
    table.interp[op(.@"memory.atomic.notify")] = atomicNotify;
    table.interp[op(.@"memory.atomic.wait32")] = waitHandler(u32);
    table.interp[op(.@"memory.atomic.wait64")] = waitHandler(u64);
    table.interp[op(.@"i64.load")] = i64Load;
    table.interp[op(.@"f32.load")] = f32Load;
    table.interp[op(.@"f64.load")] = f64Load;
    table.interp[op(.@"i32.load8_s")] = i32Load8S;
    table.interp[op(.@"i32.load8_u")] = i32Load8U;
    table.interp[op(.@"i32.load16_s")] = i32Load16S;
    table.interp[op(.@"i32.load16_u")] = i32Load16U;
    table.interp[op(.@"i64.load8_s")] = i64Load8S;
    table.interp[op(.@"i64.load8_u")] = i64Load8U;
    table.interp[op(.@"i64.load16_s")] = i64Load16S;
    table.interp[op(.@"i64.load16_u")] = i64Load16U;
    table.interp[op(.@"i64.load32_s")] = i64Load32S;
    table.interp[op(.@"i64.load32_u")] = i64Load32U;

    table.interp[op(.@"i32.store")] = i32Store;
    table.interp[op(.@"i64.store")] = i64Store;
    table.interp[op(.@"f32.store")] = f32Store;
    table.interp[op(.@"f64.store")] = f64Store;
    table.interp[op(.@"i32.store8")] = i32Store8;
    table.interp[op(.@"i32.store16")] = i32Store16;
    table.interp[op(.@"i64.store8")] = i64Store8;
    table.interp[op(.@"i64.store16")] = i64Store16;
    table.interp[op(.@"i64.store32")] = i64Store32;

    table.interp[op(.@"memory.size")] = memorySize;
    table.interp[op(.@"memory.grow")] = memoryGrow;
}

// ============================================================
// Loads / stores / memory
// ============================================================

const wasm_page_size: usize = 65536;

fn effectiveAddrStore(mem: []u8, popped_addr: u32, offset: u64, width: usize) Trap!usize {
    const ea: u64 = @as(u64, popped_addr) + offset;
    if (ea + width > mem.len) return Trap.OutOfBoundsStore;
    return @intCast(ea);
}

// --- Loads ---

fn i32Load(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea + 4 > mem.len) return Trap.OutOfBoundsLoad;
    const v = std.mem.readInt(u32, mem[@intCast(ea)..][0..4], .little);
    try rt.pushOperand(.{ .u32 = v });
}

/// Wasm threads §exec — `i32.atomic.load` (ADR-0168): naturally
/// aligned 4-byte load. On the single-threaded substrate every atomic
/// access is trivially seq-cst, so this is a plain little-endian load.
/// Per spec step 8 the alignment trap (`ea mod 4 ≠ 0`) is checked
/// BEFORE the bounds test (step 14a). Validation already pinned the
/// static memarg align to exactly 2 (natural).
fn i32AtomicLoad(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea & 3 != 0) return Trap.UnalignedAtomic;
    if (ea + 4 > mem.len) return Trap.OutOfBoundsLoad;
    const v = std.mem.readInt(u32, mem[@intCast(ea)..][0..4], .little);
    try rt.pushOperand(.{ .u32 = v });
}

/// Wasm threads §exec — `i64.atomic.load` (ADR-0168): naturally
/// aligned 8-byte seq-cst load. Mirrors `i32AtomicLoad` (alignment
/// trap `ea mod 8 ≠ 0` BEFORE bounds, spec step 8 < 14a); natural
/// align pinned to 3 by validation.
fn i64AtomicLoad(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea & 7 != 0) return Trap.UnalignedAtomic;
    if (ea + 8 > mem.len) return Trap.OutOfBoundsLoad;
    const v = std.mem.readInt(u64, mem[@intCast(ea)..][0..8], .little);
    try rt.pushOperand(.{ .u64 = v });
}

/// Wasm threads §exec — narrow atomic loads (`*.atomic.load{8,16,32}_u`,
/// ADR-0168): naturally aligned zero-extending load. Alignment trap
/// (`ea mod width ≠ 0`) BEFORE bounds (spec step 8 < 14a); 1-byte loads
/// are always aligned. All atomic narrow loads are UNSIGNED (no _s).
fn atomicLoadU(mem: []const u8, popped_addr: u32, comptime W: type, offset: u64) Trap!u64 {
    const width = @sizeOf(W);
    const ea: u64 = @as(u64, popped_addr) + offset;
    if (ea & (width - 1) != 0) return Trap.UnalignedAtomic;
    if (ea + width > mem.len) return Trap.OutOfBoundsLoad;
    return @as(u64, std.mem.readInt(W, mem[@intCast(ea)..][0..width], .little));
}
fn i32AtomicLoad8U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try atomicLoadU(memorySlice(rt, instr.extra), rt.popOperand().u32, u8, instr.payload);
    try rt.pushOperand(.{ .u32 = @intCast(v) });
}
fn i32AtomicLoad16U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try atomicLoadU(memorySlice(rt, instr.extra), rt.popOperand().u32, u16, instr.payload);
    try rt.pushOperand(.{ .u32 = @intCast(v) });
}
fn i64AtomicLoad8U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try atomicLoadU(memorySlice(rt, instr.extra), rt.popOperand().u32, u8, instr.payload);
    try rt.pushOperand(.{ .u64 = v });
}
fn i64AtomicLoad16U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try atomicLoadU(memorySlice(rt, instr.extra), rt.popOperand().u32, u16, instr.payload);
    try rt.pushOperand(.{ .u64 = v });
}
fn i64AtomicLoad32U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try atomicLoadU(memorySlice(rt, instr.extra), rt.popOperand().u32, u32, instr.payload);
    try rt.pushOperand(.{ .u64 = v });
}

fn i64Load(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea + 8 > mem.len) return Trap.OutOfBoundsLoad;
    const v = std.mem.readInt(u64, mem[@intCast(ea)..][0..8], .little);
    try rt.pushOperand(.{ .u64 = v });
}

fn f32Load(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea + 4 > mem.len) return Trap.OutOfBoundsLoad;
    const bits = std.mem.readInt(u32, mem[@intCast(ea)..][0..4], .little);
    try rt.pushOperand(.{ .bits64 = bits });
}

fn f64Load(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea + 8 > mem.len) return Trap.OutOfBoundsLoad;
    const bits = std.mem.readInt(u64, mem[@intCast(ea)..][0..8], .little);
    try rt.pushOperand(.{ .bits64 = bits });
}

fn loadInt(mem: []const u8, popped_addr: u32, comptime W: type, comptime sign_extend: bool, offset: u64) Trap!i64 {
    const width = @sizeOf(W);
    const ea: u64 = @as(u64, popped_addr) + offset;
    if (ea + width > mem.len) return Trap.OutOfBoundsLoad;
    const raw = std.mem.readInt(W, mem[@intCast(ea)..][0..width], .little);
    if (sign_extend) {
        const SignedW = @Int(.signed, @bitSizeOf(W));
        const sw: SignedW = @bitCast(raw);
        return @as(i64, sw);
    }
    return @as(i64, @as(i64, @bitCast(@as(u64, raw))));
}

fn i32Load8S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u8, true, instr.payload);
    try rt.pushOperand(.{ .i32 = @intCast(@as(i32, @truncate(v))) });
}
fn i32Load8U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u8, false, instr.payload);
    try rt.pushOperand(.{ .u32 = @intCast(v) });
}
fn i32Load16S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u16, true, instr.payload);
    try rt.pushOperand(.{ .i32 = @intCast(@as(i32, @truncate(v))) });
}
fn i32Load16U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u16, false, instr.payload);
    try rt.pushOperand(.{ .u32 = @intCast(v) });
}
fn i64Load8S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u8, true, instr.payload);
    try rt.pushOperand(.{ .i64 = v });
}
fn i64Load8U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u8, false, instr.payload);
    try rt.pushOperand(.{ .u64 = @intCast(v) });
}
fn i64Load16S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u16, true, instr.payload);
    try rt.pushOperand(.{ .i64 = v });
}
fn i64Load16U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u16, false, instr.payload);
    try rt.pushOperand(.{ .u64 = @intCast(v) });
}
fn i64Load32S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u32, true, instr.payload);
    try rt.pushOperand(.{ .i64 = v });
}
fn i64Load32U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u32, false, instr.payload);
    try rt.pushOperand(.{ .u64 = @intCast(v) });
}

// --- Stores ---

fn i32Store(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand().u32;
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 4);
    std.mem.writeInt(u32, mem[ea..][0..4], v, .little);
}
fn i64Store(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand().u64;
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 8);
    std.mem.writeInt(u64, mem[ea..][0..8], v, .little);
}
fn f32Store(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const bits: u32 = @truncate(v.bits64);
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 4);
    std.mem.writeInt(u32, mem[ea..][0..4], bits, .little);
}
fn f64Store(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 8);
    std.mem.writeInt(u64, mem[ea..][0..8], v.bits64, .little);
}
fn i32Store8(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u8 = @truncate(rt.popOperand().u32);
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 1);
    mem[ea] = v;
}
fn i32Store16(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u16 = @truncate(rt.popOperand().u32);
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 2);
    std.mem.writeInt(u16, mem[ea..][0..2], v, .little);
}
fn i64Store8(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u8 = @truncate(rt.popOperand().u64);
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 1);
    mem[ea] = v;
}
fn i64Store16(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u16 = @truncate(rt.popOperand().u64);
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 2);
    std.mem.writeInt(u16, mem[ea..][0..2], v, .little);
}
fn i64Store32(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u32 = @truncate(rt.popOperand().u64);
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 4);
    std.mem.writeInt(u32, mem[ea..][0..4], v, .little);
}

/// Wasm threads §exec — atomic store effective-address + traps (ADR-0168):
/// alignment trap (`ea mod width ≠ 0`) BEFORE the bounds test (spec step
/// 8 < 14a). 1-byte stores are always aligned. Single-threaded substrate
/// → a plain little-endian store after the checks.
fn atomicStoreEa(mem: []u8, popped_addr: u32, offset: u64, width: usize) Trap!usize {
    const ea: u64 = @as(u64, popped_addr) + offset;
    if (ea & (width - 1) != 0) return Trap.UnalignedAtomic;
    if (ea + width > mem.len) return Trap.OutOfBoundsStore;
    return @intCast(ea);
}
fn i32AtomicStore(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand().u32;
    const ea = try atomicStoreEa(memorySlice(rt, instr.extra), rt.popOperand().u32, instr.payload, 4);
    std.mem.writeInt(u32, memorySlice(rt, instr.extra)[ea..][0..4], v, .little);
}
fn i64AtomicStore(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand().u64;
    const ea = try atomicStoreEa(memorySlice(rt, instr.extra), rt.popOperand().u32, instr.payload, 8);
    std.mem.writeInt(u64, memorySlice(rt, instr.extra)[ea..][0..8], v, .little);
}
fn i32AtomicStore8(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u8 = @truncate(rt.popOperand().u32);
    const ea = try atomicStoreEa(memorySlice(rt, instr.extra), rt.popOperand().u32, instr.payload, 1);
    memorySlice(rt, instr.extra)[ea] = v;
}
fn i32AtomicStore16(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u16 = @truncate(rt.popOperand().u32);
    const ea = try atomicStoreEa(memorySlice(rt, instr.extra), rt.popOperand().u32, instr.payload, 2);
    std.mem.writeInt(u16, memorySlice(rt, instr.extra)[ea..][0..2], v, .little);
}
fn i64AtomicStore8(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u8 = @truncate(rt.popOperand().u64);
    const ea = try atomicStoreEa(memorySlice(rt, instr.extra), rt.popOperand().u32, instr.payload, 1);
    memorySlice(rt, instr.extra)[ea] = v;
}
fn i64AtomicStore16(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u16 = @truncate(rt.popOperand().u64);
    const ea = try atomicStoreEa(memorySlice(rt, instr.extra), rt.popOperand().u32, instr.payload, 2);
    std.mem.writeInt(u16, memorySlice(rt, instr.extra)[ea..][0..2], v, .little);
}
fn i64AtomicStore32(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u32 = @truncate(rt.popOperand().u64);
    const ea = try atomicStoreEa(memorySlice(rt, instr.extra), rt.popOperand().u32, instr.payload, 4);
    std.mem.writeInt(u32, memorySlice(rt, instr.extra)[ea..][0..4], v, .little);
}

// --- Atomic read-modify-write (threads, ADR-0168) ---
//
// rmw pops [addr, value], loads `old` (width W) with the alignment
// trap (ea mod W) BEFORE bounds (spec exec), computes `op(old, val)`,
// stores it back, and pushes `old` zero-extended to the result type.
// Single-threaded substrate → a plain non-atomic load-modify-store.

const RmwKind = enum { add, sub, @"and", @"or", xor, xchg };

/// Factory: returns the interp handler for a given narrow width `W`,
/// result width (`res64` → i64 result else i32), and rmw `kind`.
fn rmwHandler(comptime W: type, comptime res64: bool, comptime kind: RmwKind) dispatch.InterpFn {
    const width = @sizeOf(W);
    return struct {
        fn h(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
            const rt = Runtime.fromOpaque(c);
            const raw_val = if (res64) rt.popOperand().u64 else @as(u64, rt.popOperand().u32);
            const addr = rt.popOperand().u32;
            const mem = memorySlice(rt, instr.extra);
            const ea: u64 = @as(u64, addr) + @as(u64, instr.payload);
            if (ea & (width - 1) != 0) return Trap.UnalignedAtomic;
            if (ea + width > mem.len) return Trap.OutOfBoundsLoad;
            const slot = mem[@intCast(ea)..][0..width];
            const old = std.mem.readInt(W, slot, .little);
            const val: W = @truncate(raw_val);
            const new: W = switch (kind) {
                .add => old +% val,
                .sub => old -% val,
                .@"and" => old & val,
                .@"or" => old | val,
                .xor => old ^ val,
                .xchg => val,
            };
            std.mem.writeInt(W, slot, new, .little);
            if (res64) try rt.pushOperand(.{ .u64 = @as(u64, old) }) else try rt.pushOperand(.{ .u32 = @as(u32, old) });
        }
    }.h;
}

/// Factory for `tNN.atomic.rmw*.cmpxchg_u` (threads, ADR-0168). Pops
/// [addr, expected, replacement], loads `old` (width W), and per spec
/// exec compares `old == wrap_N(expected)`; on match stores
/// `wrap_N(replacement)`. Always pushes `old` zero-extended to the
/// result type (regardless of match). Alignment trap BEFORE bounds.
fn cmpxchgHandler(comptime W: type, comptime res64: bool) dispatch.InterpFn {
    const width = @sizeOf(W);
    return struct {
        fn h(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
            const rt = Runtime.fromOpaque(c);
            const rep_raw = if (res64) rt.popOperand().u64 else @as(u64, rt.popOperand().u32);
            const exp_raw = if (res64) rt.popOperand().u64 else @as(u64, rt.popOperand().u32);
            const addr = rt.popOperand().u32;
            const mem = memorySlice(rt, instr.extra);
            const ea: u64 = @as(u64, addr) + @as(u64, instr.payload);
            if (ea & (width - 1) != 0) return Trap.UnalignedAtomic;
            if (ea + width > mem.len) return Trap.OutOfBoundsLoad;
            const slot = mem[@intCast(ea)..][0..width];
            const old = std.mem.readInt(W, slot, .little);
            if (old == @as(W, @truncate(exp_raw))) {
                std.mem.writeInt(W, slot, @as(W, @truncate(rep_raw)), .little);
            }
            if (res64) try rt.pushOperand(.{ .u64 = @as(u64, old) }) else try rt.pushOperand(.{ .u32 = @as(u32, old) });
        }
    }.h;
}

/// `memory.atomic.notify` (threads, ADR-0168) — pop count + addr,
/// align(4)+bounds trap, push the number of waiters woken. Single-
/// threaded substrate: no waiters ever exist → always 0 (valid on a
/// non-shared memory too). Alignment trap BEFORE bounds.
fn atomicNotify(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    _ = rt.popOperand().u32; // count (no waiters single-thread)
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, addr) + @as(u64, instr.payload);
    if (ea & 3 != 0) return Trap.UnalignedAtomic;
    if (ea + 4 > mem.len) return Trap.OutOfBoundsLoad;
    try rt.pushOperand(.{ .u32 = 0 });
}

/// Factory for `memory.atomic.wait{32,64}` (threads, ADR-0168). Pops
/// [addr, expected, timeout], align(W)+bounds trap, then traps if the
/// memory is non-shared (spec precondition). On a shared memory the
/// single-threaded substrate cannot block, so: value ≠ expected → 1
/// ("not equal"); value == expected → 2 ("timed out" — no notifier can
/// ever arrive, the timeout elapses immediately regardless of its
/// value). `W` = u32 (wait32) / u64 (wait64).
fn waitHandler(comptime W: type) dispatch.InterpFn {
    const width = @sizeOf(W);
    return struct {
        fn h(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
            const rt = Runtime.fromOpaque(c);
            _ = rt.popOperand().u64; // timeout (instant-timeout single-thread)
            const expected = if (W == u64) rt.popOperand().u64 else @as(u64, rt.popOperand().u32);
            const addr = rt.popOperand().u32;
            const mem = memorySlice(rt, instr.extra);
            const ea: u64 = @as(u64, addr) + @as(u64, instr.payload);
            if (ea & (width - 1) != 0) return Trap.UnalignedAtomic;
            if (ea + width > mem.len) return Trap.OutOfBoundsLoad;
            if (!memShared(rt, instr.extra)) return Trap.ExpectedSharedMemory;
            const cur = std.mem.readInt(W, mem[@intCast(ea)..][0..width], .little);
            const status: u32 = if (cur != @as(W, @truncate(expected))) 1 else 2;
            try rt.pushOperand(.{ .u32 = status });
        }
    }.h;
}

// --- memory.size / memory.grow ---

/// True when the memory at `memidx` is declared with `(memory i64 …)`
/// (Wasm 3.0 memory64). Falls back to i32 when `rt.memories[memidx]`
/// is not present (test scaffolds that bypass instantiate leave
/// memories empty + rt.memory non-empty for memidx=0).
inline fn memoryIsI64(rt: *const Runtime, memidx: usize) bool {
    return memidx < rt.memories.len and rt.memories[memidx].idx_type == .i64;
}

fn memorySize(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    // 10.M cycle 66 — memidx in instr.payload (was reserved 0x00
    // pre-multi-memory). Route through rt.memories[memidx]; fall
    // back to rt.memory for the legacy memidx=0 / pre-instantiate
    // case so the existing in-source unit tests stay green.
    const memidx: usize = @intCast(instr.payload);
    const mem: []const u8 = if (memidx < rt.memories.len)
        rt.memories[memidx].bytes
    else if (memidx == 0)
        rt.memory
    else
        return Trap.OutOfBoundsLoad;
    const pages: u64 = mem.len / memPageSizeAt(rt, memidx);
    // Wasm spec §4.4.7 — result type matches the memory's idx_type.
    if (memoryIsI64(rt, memidx)) {
        try rt.pushOperand(.{ .i64 = @bitCast(pages) });
    } else {
        try rt.pushOperand(.{ .u32 = @intCast(pages) });
    }
}

fn memoryGrow(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const memidx: usize = @intCast(instr.payload);
    const is_i64 = memoryIsI64(rt, memidx);
    // Pop delta in the memory's idx-type-width: writer pushed i64
    // for memory64 modules; reading .u32 there would mask off the
    // high half and silently miscompute.
    const delta: u64 = if (is_i64) @bitCast(rt.popOperand().i64) else rt.popOperand().u32;
    // Core grow (cap + realloc + zero-fill + memory0 alias) lives on
    // `Runtime.growMemory` so the interp handler + the Zig facade
    // `Memory.grow` share one implementation. `null` = grow refused
    // (cap exceeded / overflow / OOM) → push the -1 sentinel; the
    // result width follows the memory's idx-type.
    const old_pages = rt.growMemory(memidx, delta) orelse {
        if (is_i64) try rt.pushOperand(.{ .i64 = -1 }) else try rt.pushOperand(.{ .i32 = -1 });
        return;
    };
    if (is_i64) {
        try rt.pushOperand(.{ .i64 = @bitCast(old_pages) });
    } else {
        try rt.pushOperand(.{ .u32 = @intCast(old_pages) });
    }
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

test "i32.load / i32.store round-trip with offset" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0);

    // Store 0xCAFEBABE at addr=4 + offset=4 = 8.
    try rt.pushOperand(.{ .u32 = 4 }); // base address
    try rt.pushOperand(.{ .u32 = 0xCAFEBABE }); // value
    try driveOne(&rt, &t, .@"i32.store", 4, 0); // payload=offset=4

    // Load it back.
    try rt.pushOperand(.{ .u32 = 4 });
    try driveOne(&rt, &t, .@"i32.load", 4, 0);
    try testing.expectEqual(@as(u32, 0xCAFEBABE), rt.popOperand().u32);
}

test "i32.load OOB traps" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 8);

    try rt.pushOperand(.{ .u32 = 5 }); // 5+4 > 8
    try testing.expectError(Trap.OutOfBoundsLoad, driveOne(&rt, &t, .@"i32.load", 0, 0));
}

test "i32.atomic.load reads an aligned word" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0);

    // Plain store 0xCAFEBABE at aligned addr=8, then atomic-load it.
    try rt.pushOperand(.{ .u32 = 8 });
    try rt.pushOperand(.{ .u32 = 0xCAFEBABE });
    try driveOne(&rt, &t, .@"i32.store", 0, 0);

    try rt.pushOperand(.{ .u32 = 8 });
    try driveOne(&rt, &t, .@"i32.atomic.load", 0, 0);
    try testing.expectEqual(@as(u32, 0xCAFEBABE), rt.popOperand().u32);
}

test "i32.atomic.load unaligned address traps UnalignedAtomic (before bounds)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);

    // addr=2 is in-bounds but not 4-aligned → alignment trap, not OOB.
    try rt.pushOperand(.{ .u32 = 2 });
    try testing.expectError(Trap.UnalignedAtomic, driveOne(&rt, &t, .@"i32.atomic.load", 0, 0));
}

test "i64.atomic.load reads an aligned doubleword + traps unaligned (4 not 8-aligned)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0);

    try rt.pushOperand(.{ .u32 = 8 });
    try rt.pushOperand(.{ .u64 = 0x0123456789ABCDEF });
    try driveOne(&rt, &t, .@"i64.store", 0, 0);
    try rt.pushOperand(.{ .u32 = 8 });
    try driveOne(&rt, &t, .@"i64.atomic.load", 0, 0);
    try testing.expectEqual(@as(u64, 0x0123456789ABCDEF), rt.popOperand().u64);

    // addr=4 is 4-aligned but NOT 8-aligned → UnalignedAtomic.
    try rt.pushOperand(.{ .u32 = 4 });
    try testing.expectError(Trap.UnalignedAtomic, driveOne(&rt, &t, .@"i64.atomic.load", 0, 0));
}

test "narrow atomic loads zero-extend + trap unaligned" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0);
    rt.memory[5] = 0xAB; // byte at 5
    std.mem.writeInt(u32, rt.memory[8..][0..4], 0xDEADBEEF, .little); // word at 8

    // i32.atomic.load8_u @5 → 0xAB (byte access always aligned).
    try rt.pushOperand(.{ .u32 = 5 });
    try driveOne(&rt, &t, .@"i32.atomic.load8_u", 0, 0);
    try testing.expectEqual(@as(u32, 0xAB), rt.popOperand().u32);
    // i64.atomic.load32_u @8 → 0xDEADBEEF zero-extended to u64.
    try rt.pushOperand(.{ .u32 = 8 });
    try driveOne(&rt, &t, .@"i64.atomic.load32_u", 0, 0);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), rt.popOperand().u64);
    // i32.atomic.load16_u @1 (odd) → UnalignedAtomic.
    try rt.pushOperand(.{ .u32 = 1 });
    try testing.expectError(Trap.UnalignedAtomic, driveOne(&rt, &t, .@"i32.atomic.load16_u", 0, 0));
}

test "atomic stores write + trap unaligned" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0);

    // i32.atomic.store @8 = 0xCAFEBABE, read back via i32.atomic.load.
    try rt.pushOperand(.{ .u32 = 8 });
    try rt.pushOperand(.{ .u32 = 0xCAFEBABE });
    try driveOne(&rt, &t, .@"i32.atomic.store", 0, 0);
    try rt.pushOperand(.{ .u32 = 8 });
    try driveOne(&rt, &t, .@"i32.atomic.load", 0, 0);
    try testing.expectEqual(@as(u32, 0xCAFEBABE), rt.popOperand().u32);

    // i64.atomic.store8 @3 = 0xFF (byte, always aligned).
    try rt.pushOperand(.{ .u32 = 3 });
    try rt.pushOperand(.{ .u64 = 0x1FF });
    try driveOne(&rt, &t, .@"i64.atomic.store8", 0, 0);
    try testing.expectEqual(@as(u8, 0xFF), rt.memory[3]);

    // i32.atomic.store16 @1 (odd) → UnalignedAtomic (operands popped first).
    try rt.pushOperand(.{ .u32 = 1 });
    try rt.pushOperand(.{ .u32 = 0 });
    try testing.expectError(Trap.UnalignedAtomic, driveOne(&rt, &t, .@"i32.atomic.store16", 0, 0));
}

test "atomic rmw binops: add/xchg/and + narrow + unaligned trap" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0);
    std.mem.writeInt(u32, rt.memory[8..][0..4], 100, .little);

    // i32.atomic.rmw.add @8 += 23 → pushes OLD (100); mem becomes 123.
    try rt.pushOperand(.{ .u32 = 8 });
    try rt.pushOperand(.{ .u32 = 23 });
    try driveOne(&rt, &t, .@"i32.atomic.rmw.add", 0, 0);
    try testing.expectEqual(@as(u32, 100), rt.popOperand().u32);
    try testing.expectEqual(@as(u32, 123), std.mem.readInt(u32, rt.memory[8..][0..4], .little));

    // i32.atomic.rmw.xchg @8 = 7 → pushes OLD (123); mem becomes 7.
    try rt.pushOperand(.{ .u32 = 8 });
    try rt.pushOperand(.{ .u32 = 7 });
    try driveOne(&rt, &t, .@"i32.atomic.rmw.xchg", 0, 0);
    try testing.expectEqual(@as(u32, 123), rt.popOperand().u32);
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, rt.memory[8..][0..4], .little));

    // i64.atomic.rmw8.and_u @3: mem[3]=0xF0, &= 0x3C → old 0xF0, mem 0x30.
    rt.memory[3] = 0xF0;
    try rt.pushOperand(.{ .u32 = 3 });
    try rt.pushOperand(.{ .u64 = 0x3C });
    try driveOne(&rt, &t, .@"i64.atomic.rmw8.and_u", 0, 0);
    try testing.expectEqual(@as(u64, 0xF0), rt.popOperand().u64);
    try testing.expectEqual(@as(u8, 0x30), rt.memory[3]);

    // unaligned: i32.atomic.rmw.add @2 → UnalignedAtomic.
    try rt.pushOperand(.{ .u32 = 2 });
    try rt.pushOperand(.{ .u32 = 1 });
    try testing.expectError(Trap.UnalignedAtomic, driveOne(&rt, &t, .@"i32.atomic.rmw.add", 0, 0));
}

test "atomic cmpxchg: match stores, mismatch leaves; pushes old" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0);
    std.mem.writeInt(u32, rt.memory[8..][0..4], 100, .little);

    // MATCH: cmpxchg @8 expected=100 replacement=999 → old 100, mem becomes 999.
    try rt.pushOperand(.{ .u32 = 8 }); // addr
    try rt.pushOperand(.{ .u32 = 100 }); // expected
    try rt.pushOperand(.{ .u32 = 999 }); // replacement
    try driveOne(&rt, &t, .@"i32.atomic.rmw.cmpxchg", 0, 0);
    try testing.expectEqual(@as(u32, 100), rt.popOperand().u32);
    try testing.expectEqual(@as(u32, 999), std.mem.readInt(u32, rt.memory[8..][0..4], .little));

    // MISMATCH: expected=5 (≠999) → old 999, mem UNCHANGED (999).
    try rt.pushOperand(.{ .u32 = 8 });
    try rt.pushOperand(.{ .u32 = 5 });
    try rt.pushOperand(.{ .u32 = 7 });
    try driveOne(&rt, &t, .@"i32.atomic.rmw.cmpxchg", 0, 0);
    try testing.expectEqual(@as(u32, 999), rt.popOperand().u32);
    try testing.expectEqual(@as(u32, 999), std.mem.readInt(u32, rt.memory[8..][0..4], .little));

    // narrow i64.cmpxchg8_u @3: mem[3]=0xAB, expected wraps to 0xAB → match, store 0xCD.
    rt.memory[3] = 0xAB;
    try rt.pushOperand(.{ .u32 = 3 });
    try rt.pushOperand(.{ .u64 = 0xFFAB }); // wrap_8 = 0xAB → match
    try rt.pushOperand(.{ .u64 = 0xCD });
    try driveOne(&rt, &t, .@"i64.atomic.rmw8.cmpxchg_u", 0, 0);
    try testing.expectEqual(@as(u64, 0xAB), rt.popOperand().u64);
    try testing.expectEqual(@as(u8, 0xCD), rt.memory[3]);
}

test "memory.atomic.notify returns 0 (no waiters) + traps unaligned" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);

    // notify @8 count=3 → 0 (single-thread, no waiters). Stack [addr, count].
    try rt.pushOperand(.{ .u32 = 8 });
    try rt.pushOperand(.{ .u32 = 3 });
    try driveOne(&rt, &t, .@"memory.atomic.notify", 0, 0);
    try testing.expectEqual(@as(u32, 0), rt.popOperand().u32);

    // notify @2 unaligned → trap (before bounds).
    try rt.pushOperand(.{ .u32 = 2 });
    try rt.pushOperand(.{ .u32 = 1 });
    try testing.expectError(Trap.UnalignedAtomic, driveOne(&rt, &t, .@"memory.atomic.notify", 0, 0));
}

test "memory.atomic.wait32 on a non-shared memory traps ExpectedSharedMemory" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64); // fallback = non-shared

    // wait32 @8 expected=0 timeout=-1. Stack [addr, expected, timeout].
    try rt.pushOperand(.{ .u32 = 8 });
    try rt.pushOperand(.{ .u32 = 0 });
    try rt.pushOperand(.{ .i64 = -1 });
    try testing.expectError(Trap.ExpectedSharedMemory, driveOne(&rt, &t, .@"memory.atomic.wait32", 0, 0));
}

test "memory.atomic.wait on shared memory: not-equal→1, equal→2 (single-thread instant timeout)" {
    const memory_instance = @import("../../runtime/instance/memory_instance.zig");
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const buf = try testing.allocator.alloc(u8, 64);
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[8..][0..4], 42, .little);
    var mi_val: memory_instance.MemoryInstance = .{ .bytes = buf, .shared = true };
    var mi = [_]*memory_instance.MemoryInstance{&mi_val};
    rt.memories = mi[0..];
    defer rt.memories = &.{};

    // wait32 @8 expected=99 (≠ 42) → 1 (not-equal).
    try rt.pushOperand(.{ .u32 = 8 });
    try rt.pushOperand(.{ .u32 = 99 });
    try rt.pushOperand(.{ .i64 = 0 });
    try driveOne(&rt, &t, .@"memory.atomic.wait32", 0, 0);
    try testing.expectEqual(@as(u32, 1), rt.popOperand().u32);

    // wait32 @8 expected=42 (== 42) → 2 (timed-out; no notifier single-thread).
    try rt.pushOperand(.{ .u32 = 8 });
    try rt.pushOperand(.{ .u32 = 42 });
    try rt.pushOperand(.{ .i64 = -1 });
    try driveOne(&rt, &t, .@"memory.atomic.wait32", 0, 0);
    try testing.expectEqual(@as(u32, 2), rt.popOperand().u32);

    testing.allocator.free(buf);
}

test "i32.load8_s sign-extends" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 4);
    rt.memory[0] = 0xFF;

    try rt.pushOperand(.{ .u32 = 0 });
    try driveOne(&rt, &t, .@"i32.load8_s", 0, 0);
    try testing.expectEqual(@as(i32, -1), rt.popOperand().i32);
}

test "memory.size: zero-page memory" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"memory.size", 0, 0);
    try testing.expectEqual(@as(u32, 0), rt.popOperand().u32);
}

test "memory.grow grows by 1 page; size reflects update" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .u32 = 1 });
    try driveOne(&rt, &t, .@"memory.grow", 0, 0);
    try testing.expectEqual(@as(u32, 0), rt.popOperand().u32); // old size
    try testing.expectEqual(@as(usize, 65536), rt.memory.len);

    try driveOne(&rt, &t, .@"memory.size", 0, 0);
    try testing.expectEqual(@as(u32, 1), rt.popOperand().u32);
}

test "memory.size on memory64 returns i64 result (ADR-0111 D2 runtime)" {
    // Wasm spec §4.4.7 — memory.size returns i32 for i32-indexed
    // memory and i64 for i64-indexed (memory64). The interp's
    // current i32-only path returned the low 32 bits with the
    // high bits undefined; the wasm-3.0-assert memory64 corpus
    // surfaced this as ~22 size/grow mismatches.
    const sections_mod = @import("../../parse/sections.zig");
    const memory_instance = @import("../../runtime/instance/memory_instance.zig");

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 2 * 65536); // 2 pages
    var mi_val: memory_instance.MemoryInstance = .{
        .bytes = rt.memory,
        .idx_type = sections_mod.MemoryEntry.IdxType.i64,
        .pages_min = 2,
        .pages_max = null,
    };
    var mi = [_]*memory_instance.MemoryInstance{&mi_val};
    rt.memories = mi[0..];
    defer rt.memories = &.{};

    try driveOne(&rt, &t, .@"memory.size", 0, 0);
    try testing.expectEqual(@as(i64, 2), rt.popOperand().i64);
}

test "memory.grow on memory64 pops i64 delta, pushes i64 old_size (ADR-0111 D2 runtime)" {
    const sections_mod = @import("../../parse/sections.zig");
    const memory_instance = @import("../../runtime/instance/memory_instance.zig");

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var mi_val: memory_instance.MemoryInstance = .{
        .bytes = &.{},
        .idx_type = sections_mod.MemoryEntry.IdxType.i64,
        .pages_min = 0,
        .pages_max = null,
    };
    var mi = [_]*memory_instance.MemoryInstance{&mi_val};
    rt.memories = mi[0..];
    defer rt.memories = &.{};

    try rt.pushOperand(.{ .i64 = 1 });
    try driveOne(&rt, &t, .@"memory.grow", 0, 0);
    try testing.expectEqual(@as(i64, 0), rt.popOperand().i64); // old size = 0
    try testing.expectEqual(@as(usize, 65536), rt.memory.len);
}

test "memory.size/grow on a 1-byte-page memory operate in byte units (custom-page-sizes, ADR-0168 v0.2)" {
    const memory_instance = @import("../../runtime/instance/memory_instance.zig");
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var mi_val: memory_instance.MemoryInstance = .{
        .bytes = &.{},
        .pages_min = 0,
        .page_size_log2 = 0, // 1-byte page
    };
    var mi = [_]*memory_instance.MemoryInstance{&mi_val};
    rt.memories = mi[0..];
    defer rt.memories = &.{};

    // grow by 5 (1-byte) pages → old size 0; mem becomes 5 bytes.
    try rt.pushOperand(.{ .u32 = 5 });
    try driveOne(&rt, &t, .@"memory.grow", 0, 0);
    try testing.expectEqual(@as(u32, 0), rt.popOperand().u32);
    try testing.expectEqual(@as(usize, 5), rt.memory.len);

    // memory.size = 5 (byte count), NOT 5/65536 = 0.
    try driveOne(&rt, &t, .@"memory.size", 0, 0);
    try testing.expectEqual(@as(u32, 5), rt.popOperand().u32);
}
