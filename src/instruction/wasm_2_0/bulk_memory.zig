//! Wasm 2.0 bulk-memory interp handlers (§9.2 / 2.3 chunk 4).
//!
//! Prefix opcode 0xFC + sub-opcode 10 / 11. Both pop three i32
//! operands (n, src/val, dst) and trap OutOfBoundsStore on
//! overflow. memory.init / data.drop / table.* land in later
//! sub-chunks (data + element section decoders required first).
//!
//! Sub-opcode → ZirOp:
//!   10 → memory.copy: pop n, src, dst; copy n bytes (memmove
//!        semantics for overlap); trap if (dst+n > len) or
//!        (src+n > len).
//!   11 → memory.fill: pop n, val, dst; fill n bytes at dst with
//!        val&0xFF; trap if (dst+n > len).
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
const Trap = runtime.Trap;

inline fn op(o: ZirOp) usize {
    return @backingInt(o);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"memory.copy")] = memoryCopy;
    table.interp[op(.@"memory.fill")] = memoryFill;
    table.interp[op(.@"memory.init")] = memoryInit;
    table.interp[op(.@"data.drop")] = dataDrop;
}

/// 10.M cycle 67 — resolve the target memory slice by memidx,
/// falling back to `rt.memory` when `rt.memories` is empty
/// (test scaffolds that bypass instantiate). Mirrors the
/// `memorySlice` helper in `wasm_1_0/memory.zig`.
inline fn memSliceByIdx(rt: *Runtime, memidx: u64) []u8 {
    if (rt.memories.len == 0 and memidx == 0) return rt.memory;
    const i: usize = @intCast(memidx);
    if (i >= rt.memories.len) return &[_]u8{};
    return rt.memories[i].bytes;
}

/// D-324 — is the memory at `memidx` i64-indexed? Scaffold fallback
/// (no `memories` entries) = legacy i32, mirroring `memSliceByIdx`.
inline fn memIs64(rt: *Runtime, memidx: u64) bool {
    const i: usize = @intCast(memidx);
    return i < rt.memories.len and rt.memories[i].idx_type == .i64;
}

/// D-324 — pop one address/count operand at the width the validator
/// typed it (i64-indexed memory → full u64; else u32). Popping `.i32`
/// unconditionally silently truncated i64 addresses ≥ 2^32 (wrong
/// region touched instead of a trap).
inline fn popAddr(rt: *Runtime, is64: bool) u64 {
    if (is64) return rt.popOperand().u64;
    return @as(u32, @bitCast(rt.popOperand().i32));
}

/// D-324 — overflow-safe `base + n > len` (u64 base/n wrap at 2^64
/// would bypass the bounds check for huge memory64 operands).
inline fn outOfRange(base: u64, n: u64, len: usize) bool {
    const end = @addWithOverflow(base, n);
    return end[1] != 0 or end[0] > len;
}

fn memoryCopy(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    // 10.M cycle 67 — payload = dst_memidx, extra = src_memidx.
    const dst_mem = memSliceByIdx(rt, instr.payload);
    const src_mem = memSliceByIdx(rt, instr.extra);
    // Wasm 3.0 §3.4.7 (D-324): operands are [it_dst it_src it_min]
    // (it_min = i32 if either memory is i32-indexed); pop in reverse.
    const dst64 = memIs64(rt, instr.payload);
    const src64 = memIs64(rt, instr.extra);
    const n = popAddr(rt, dst64 and src64);
    const src = popAddr(rt, src64);
    const dst = popAddr(rt, dst64);
    if (outOfRange(src, n, src_mem.len) or outOfRange(dst, n, dst_mem.len)) return Trap.OutOfBoundsStore;
    if (n == 0) return;
    const src_lo: usize = @intCast(src);
    const dst_lo: usize = @intCast(dst);
    const n_lo: usize = @intCast(n);
    // memmove semantics: if regions overlap with dst > src, copy
    // backwards; otherwise forwards. The src vs dst overlap test
    // is only valid when both refer to the SAME memory; cross-
    // memidx copies never alias, so forward copy is always safe.
    if (instr.payload == instr.extra and dst_lo > src_lo and dst_lo < src_lo + n_lo) {
        std.mem.copyBackwards(u8, dst_mem[dst_lo .. dst_lo + n_lo], src_mem[src_lo .. src_lo + n_lo]);
    } else {
        std.mem.copyForwards(u8, dst_mem[dst_lo .. dst_lo + n_lo], src_mem[src_lo .. src_lo + n_lo]);
    }
}

fn memoryFill(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memSliceByIdx(rt, instr.payload);
    // D-324: dst + n carry the TARGET memory's idx_type width.
    const is64 = memIs64(rt, instr.payload);
    const n = popAddr(rt, is64);
    const val_i = rt.popOperand().i32;
    const dst = popAddr(rt, is64);
    if (outOfRange(dst, n, mem.len)) return Trap.OutOfBoundsStore;
    if (n == 0) return;
    const dst_lo: usize = @intCast(dst);
    const n_lo: usize = @intCast(n);
    const byte: u8 = @truncate(@as(u32, @bitCast(val_i)));
    @memset(mem[dst_lo .. dst_lo + n_lo], byte);
}

/// memory.init x: pop n, src, dst. Copy n bytes from data segment
/// rt.datas[x] starting at offset src into rt.memory at offset
/// dst. Trap OutOfBoundsStore if src+n > data.len OR dst+n >
/// mem.len. If the segment was previously dropped, treat its data
/// length as 0 (any n>0 → trap).
fn memoryInit(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    // 10.M cycle 67 — payload = dataidx, extra = dst_memidx.
    const dataidx = instr.payload;
    if (dataidx >= rt.datas.len) return Trap.Unreachable;
    const dropped = if (dataidx < rt.data_dropped.len) rt.data_dropped[dataidx] else false;
    const seg_len: u64 = if (dropped) 0 else rt.datas[@intCast(dataidx)].len;
    const dst_mem = memSliceByIdx(rt, instr.extra);

    // D-324: dst carries the TARGET memory's idx_type width; src + n
    // are data-segment offsets (always i32 per Wasm 3.0 §3.4.7).
    const n: u64 = @as(u32, @bitCast(rt.popOperand().i32));
    const src: u64 = @as(u32, @bitCast(rt.popOperand().i32));
    const dst = popAddr(rt, memIs64(rt, instr.extra));
    if (src + n > seg_len or outOfRange(dst, n, dst_mem.len)) return Trap.OutOfBoundsStore;
    if (n == 0) return;
    const src_lo: usize = @intCast(src);
    const dst_lo: usize = @intCast(dst);
    const n_lo: usize = @intCast(n);
    @memcpy(dst_mem[dst_lo .. dst_lo + n_lo], rt.datas[@intCast(dataidx)][src_lo .. src_lo + n_lo]);
}

/// data.drop x: mark data segment x as dropped. Subsequent
/// memory.init x calls treat its length as 0.
fn dataDrop(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const dataidx = instr.payload;
    if (dataidx >= rt.data_dropped.len) return Trap.Unreachable;
    rt.data_dropped[dataidx] = true;
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

fn allocMem(rt: *Runtime, len: usize) !void {
    const bytes = try rt.alloc.alloc(u8, len);
    @memset(bytes, 0);
    const storage = try rt.alloc.alloc(runtime.MemoryInstance, 1);
    storage[0] = .{ .bytes = bytes, .pages_min = @intCast(len / 65536) };
    const mi = try rt.alloc.alloc(*runtime.MemoryInstance, 1);
    mi[0] = &storage[0];
    rt.memories = mi;
    rt.memory_storage = storage;
    rt.memory = bytes;
}

/// D-324 — same scaffold but the memory is i64-indexed, so the
/// handlers must pop full-width u64 address/count operands.
fn allocMem64(rt: *Runtime, len: usize) !void {
    try allocMem(rt, len);
    rt.memory_storage[0].idx_type = .i64;
}

test "memory.copy on i64 memory: dst ≥ 2^32 traps (D-324 — was silently truncated to 0)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem64(&rt, 16);
    try rt.pushOperand(.{ .u64 = 1 << 32 }); // dst (low 32 bits = 0)
    try rt.pushOperand(.{ .u64 = 0 }); // src
    try rt.pushOperand(.{ .u64 = 1 }); // n
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.copy", 0, 0));
}

test "memory.copy on i64 memory: u64 wrap in bounds math still traps (D-324)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem64(&rt, 16);
    try rt.pushOperand(.{ .u64 = std.math.maxInt(u64) }); // dst
    try rt.pushOperand(.{ .u64 = 0 }); // src
    try rt.pushOperand(.{ .u64 = std.math.maxInt(u64) }); // n (dst+n wraps)
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.copy", 0, 0));
}

test "memory.fill on i64 memory: dst ≥ 2^32 traps (D-324)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem64(&rt, 16);
    try rt.pushOperand(.{ .u64 = 1 << 32 }); // dst
    try rt.pushOperand(.{ .i32 = 0xAB }); // val
    try rt.pushOperand(.{ .u64 = 1 }); // n
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.fill", 0, 0));
}

test "register: bulk-memory slots populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"memory.copy")] != null);
    try testing.expect(t.interp[op(.@"memory.fill")] != null);
    try testing.expect(t.interp[op(.@"memory.init")] != null);
    try testing.expect(t.interp[op(.@"data.drop")] != null);
}

fn setupDatas(rt: *Runtime, segs: []const []const u8) !void {
    rt.datas = segs;
    rt.data_dropped = try rt.alloc.alloc(bool, segs.len);
    @memset(rt.data_dropped, false);
}

test "memory.init: copy bytes from data segment to memory" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    const seg0 = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE };
    const segs = [_][]const u8{&seg0};
    try setupDatas(&rt, &segs);
    try rt.pushOperand(.{ .i32 = 4 }); // dst
    try rt.pushOperand(.{ .i32 = 1 }); // src (offset within seg)
    try rt.pushOperand(.{ .i32 = 3 }); // n
    try driveOne(&rt, &t, .@"memory.init", 0, 0);
    try testing.expectEqual(@as(u8, 0xBB), rt.memory[4]);
    try testing.expectEqual(@as(u8, 0xCC), rt.memory[5]);
    try testing.expectEqual(@as(u8, 0xDD), rt.memory[6]);
}

test "memory.init: src+n > seg_len → OutOfBoundsStore" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    const seg0 = [_]u8{ 0xAA, 0xBB, 0xCC };
    const segs = [_][]const u8{&seg0};
    try setupDatas(&rt, &segs);
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 1 }); // src
    try rt.pushOperand(.{ .i32 = 5 }); // n (1+5=6 > 3)
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.init", 0, 0));
}

test "memory.init: dst+n > mem_len → OutOfBoundsStore" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 4);
    const seg0 = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const segs = [_][]const u8{&seg0};
    try setupDatas(&rt, &segs);
    try rt.pushOperand(.{ .i32 = 2 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 3 }); // n (2+3=5 > 4)
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.init", 0, 0));
}

test "memory.init after data.drop: any n>0 traps; n=0 succeeds" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    const seg0 = [_]u8{ 0x11, 0x22, 0x33 };
    const segs = [_][]const u8{&seg0};
    try setupDatas(&rt, &segs);

    // data.drop 0
    try driveOne(&rt, &t, .@"data.drop", 0, 0);
    try testing.expectEqual(true, rt.data_dropped[0]);

    // memory.init 0 with n=1 → trap (segment effectively empty).
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 1 }); // n
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.init", 0, 0));

    // memory.init 0 with n=0 succeeds (no-op).
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 0 }); // n
    try driveOne(&rt, &t, .@"memory.init", 0, 0);
}

test "data.drop: dataidx out of range traps Unreachable" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // No datas set up.
    try testing.expectError(Trap.Unreachable, driveOne(&rt, &t, .@"data.drop", 0, 0));
}

test "memory.copy: non-overlapping forward copy" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    rt.memory[0] = 0xAA;
    rt.memory[1] = 0xBB;
    rt.memory[2] = 0xCC;
    // memory.copy: pop n, src, dst. Push order: dst, src, n.
    try rt.pushOperand(.{ .i32 = 8 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 3 }); // n
    try driveOne(&rt, &t, .@"memory.copy", 0, 0);
    try testing.expectEqual(@as(u8, 0xAA), rt.memory[8]);
    try testing.expectEqual(@as(u8, 0xBB), rt.memory[9]);
    try testing.expectEqual(@as(u8, 0xCC), rt.memory[10]);
}

test "memory.copy: zero-length is a no-op even at boundary" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    try rt.pushOperand(.{ .i32 = 16 }); // dst (one past end)
    try rt.pushOperand(.{ .i32 = 16 }); // src
    try rt.pushOperand(.{ .i32 = 0 }); // n
    try driveOne(&rt, &t, .@"memory.copy", 0, 0);
}

test "memory.copy: overlap dst > src → backward copy preserves data" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 8);
    // 0x01 0x02 0x03 0x04 0x05 ...
    var i: u8 = 0;
    while (i < 8) : (i += 1) rt.memory[i] = i + 1;
    // Copy [0..4] to [2..6] — overlap, dst > src.
    try rt.pushOperand(.{ .i32 = 2 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 4 }); // n
    try driveOne(&rt, &t, .@"memory.copy", 0, 0);
    // After: memory[0..6] = 1 2 1 2 3 4
    try testing.expectEqual(@as(u8, 1), rt.memory[0]);
    try testing.expectEqual(@as(u8, 2), rt.memory[1]);
    try testing.expectEqual(@as(u8, 1), rt.memory[2]);
    try testing.expectEqual(@as(u8, 2), rt.memory[3]);
    try testing.expectEqual(@as(u8, 3), rt.memory[4]);
    try testing.expectEqual(@as(u8, 4), rt.memory[5]);
}

test "memory.copy: overlap src > dst → forward copy preserves data" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 8);
    var i: u8 = 0;
    while (i < 8) : (i += 1) rt.memory[i] = i + 1;
    // Copy [2..6] to [0..4] — overlap, src > dst.
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 2 }); // src
    try rt.pushOperand(.{ .i32 = 4 }); // n
    try driveOne(&rt, &t, .@"memory.copy", 0, 0);
    // After: memory[0..6] = 3 4 5 6 5 6
    try testing.expectEqual(@as(u8, 3), rt.memory[0]);
    try testing.expectEqual(@as(u8, 4), rt.memory[1]);
    try testing.expectEqual(@as(u8, 5), rt.memory[2]);
    try testing.expectEqual(@as(u8, 6), rt.memory[3]);
    try testing.expectEqual(@as(u8, 5), rt.memory[4]);
    try testing.expectEqual(@as(u8, 6), rt.memory[5]);
}

test "memory.copy: src+n > len → OutOfBoundsStore" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 8);
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 5 }); // src
    try rt.pushOperand(.{ .i32 = 4 }); // n (5+4 = 9 > 8)
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.copy", 0, 0));
}

test "memory.copy: dst+n > len → OutOfBoundsStore" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 8);
    try rt.pushOperand(.{ .i32 = 5 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 4 }); // n (5+4 = 9 > 8)
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.copy", 0, 0));
}

test "memory.fill: writes byte-low-8 of value" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    try rt.pushOperand(.{ .i32 = 4 }); // dst
    try rt.pushOperand(.{ .i32 = @bitCast(@as(u32, 0xAABBCCEE)) }); // val (low 8 → 0xEE)
    try rt.pushOperand(.{ .i32 = 6 }); // n
    try driveOne(&rt, &t, .@"memory.fill", 0, 0);
    var i: usize = 4;
    while (i < 10) : (i += 1) {
        try testing.expectEqual(@as(u8, 0xEE), rt.memory[i]);
    }
    // Untouched bytes still zero.
    try testing.expectEqual(@as(u8, 0), rt.memory[3]);
    try testing.expectEqual(@as(u8, 0), rt.memory[10]);
}

test "memory.fill: zero-length is a no-op even at boundary" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    try rt.pushOperand(.{ .i32 = 16 }); // dst at boundary
    try rt.pushOperand(.{ .i32 = 0xAA }); // val
    try rt.pushOperand(.{ .i32 = 0 }); // n
    try driveOne(&rt, &t, .@"memory.fill", 0, 0);
}

test "memory.fill: dst+n > len → OutOfBoundsStore" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 8);
    try rt.pushOperand(.{ .i32 = 5 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // val
    try rt.pushOperand(.{ .i32 = 4 }); // n (5+4 = 9 > 8)
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.fill", 0, 0));
}
