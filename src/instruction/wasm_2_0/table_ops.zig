//! Wasm 2.0 table interp handlers (§9.2 / 2.3 chunks 5c / 5c-2).
//!
//! Five table ops:
//!   0x25     table.get x  — pop i32 idx, push tables[x][idx].
//!   0x26     table.set x  — pop reftype, pop i32 idx, write.
//!   0xFC 15  table.grow x — pop n:i32, init:reftype; realloc
//!                           refs[..len+n], fill new slots with
//!                           init; push prev_size or -1.
//!   0xFC 16  table.size x — push i32 (current length).
//!   0xFC 17  table.fill x — pop n:i32, val:reftype, dst:i32;
//!                           write n cells; trap on OOB.
//!
//! table.copy / table.init / elem.drop defer to chunk 5d (need
//! the element section decoder).
//!
//! Zone 2.

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
    return @intFromEnum(o);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"table.get")] = tableGet;
    table.interp[op(.@"table.set")] = tableSet;
    table.interp[op(.@"table.size")] = tableSize;
    table.interp[op(.@"table.grow")] = tableGrow;
    table.interp[op(.@"table.fill")] = tableFill;
    table.interp[op(.@"table.copy")] = tableCopy;
    table.interp[op(.@"table.init")] = tableInit;
    table.interp[op(.@"elem.drop")] = elemDrop;
}

fn tableGet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.payload;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = rt.tables[tableidx];
    const idx = popTableIndex(rt, tbl.idx_type);
    if (idx >= tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    try rt.pushOperand(tbl.refs[@intCast(idx)]);
}

/// Pop a table index/count operand at the table's address width. For a
/// table64 the producer pushed an i64 (validator-enforced) — read the full
/// 64 bits so an out-of-range index still trips the bounds check (reading
/// `.i32` would truncate a >2^32 index and wrongly pass). i32 tables read
/// the low word and zero-extend.
inline fn popTableIndex(rt: *Runtime, idx_type: zir.IdxType) u64 {
    return switch (idx_type) {
        .i64 => @bitCast(rt.popOperand().i64),
        .i32 => @as(u32, @bitCast(rt.popOperand().i32)),
    };
}

fn tableSet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.payload;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = rt.tables[tableidx];
    const v = rt.popOperand();
    const idx = popTableIndex(rt, tbl.idx_type);
    if (idx >= tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    tbl.refs[@intCast(idx)] = v;
}

fn tableSize(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.payload;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = rt.tables[tableidx];
    try pushTableIndex(rt, tbl.idx_type, tbl.refs.len);
}

/// Push a table size/result at the table's address width: i64 for a
/// table64 (table.size / table.grow result), i32 otherwise.
inline fn pushTableIndex(rt: *Runtime, idx_type: zir.IdxType, val: u64) anyerror!void {
    switch (idx_type) {
        .i64 => try rt.pushOperand(.{ .i64 = @bitCast(val) }),
        .i32 => try rt.pushOperand(.{ .i32 = @bitCast(@as(u32, @intCast(val))) }),
    }
}

/// table.grow x: pop n:idx_type, init:reftype. Realloc refs to
/// len+n and fill new slots with init. Push prev_size (at the table's
/// address width) on success, or -1 on max-cap violation / alloc failure.
fn tableGrow(c: *@import("../../ir/dispatch_table.zig").InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.payload;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = &rt.tables[tableidx];

    const n = popTableIndex(rt, tbl.idx_type);
    const init_v = rt.popOperand();
    const prev: u64 = tbl.refs.len;
    // The grow-failure result is -1 represented at the table's address width.
    const fail_val: Value = switch (tbl.idx_type) {
        .i64 => .{ .i64 = -1 },
        .i32 => .{ .i32 = -1 },
    };
    const add = @addWithOverflow(prev, n);
    const new_len = add[0];

    // Overflow, u32-range (i32 table can't exceed u32), max-cap, or host
    // element-cap violation → push -1, no mutation. (A >2^32-cell table is
    // unallocatable regardless of idx_type, so the realloc below also fails.)
    if (add[1] != 0 or (tbl.idx_type == .i32 and new_len > std.math.maxInt(u32))) {
        try rt.pushOperand(fail_val);
        return;
    }
    if (tbl.max) |m| if (new_len > m) {
        try rt.pushOperand(fail_val);
        return;
    };
    // D-316: a host element cap refuses the grow (spec grow-failure, not a trap),
    // the same way `store_memory_pages_max` bounds `memory.grow`.
    if (rt.store_table_elements_max) |cap| if (new_len > cap) {
        try rt.pushOperand(fail_val);
        return;
    };

    // #449 — the realloc below would move a buffer the `wasm_table_t` handle
    // still points at; the spec lets `table.grow` answer -1. See `TableInstance`.
    if (tbl.host_imported) {
        try rt.pushOperand(fail_val);
        return;
    }
    const new_refs = rt.alloc.realloc(tbl.refs, std.math.cast(usize, new_len) orelse {
        try rt.pushOperand(fail_val);
        return;
    }) catch {
        try rt.pushOperand(fail_val);
        return;
    };
    var i: usize = @intCast(prev);
    while (i < new_refs.len) : (i += 1) new_refs[i] = init_v;
    tbl.refs = new_refs;

    try pushTableIndex(rt, tbl.idx_type, prev);
}

/// table.fill x: pop n:i32, val:reftype, dst:i32. Set n cells
/// at dst to val. Trap OutOfBoundsTableAccess if dst+n > len.
fn tableFill(c: *@import("../../ir/dispatch_table.zig").InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.payload;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = rt.tables[tableidx];

    const n = popTableIndex(rt, tbl.idx_type);
    const v = rt.popOperand();
    const dst = popTableIndex(rt, tbl.idx_type);
    const end_ov = @addWithOverflow(dst, n);
    if (end_ov[1] != 0 or end_ov[0] > tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    if (n == 0) return;
    var i: usize = @intCast(dst);
    const end: usize = @intCast(end_ov[0]);
    while (i < end) : (i += 1) tbl.refs[i] = v;
}

/// table.copy x y: pop n:i32, src:i32, dst:i32. Copy n refs from
/// tables[y] to tables[x]. memmove semantics on overlap when
/// tables[x] == tables[y]. Encoding: payload = dst-tableidx,
/// extra = src-tableidx.
fn tableCopy(c: *@import("../../ir/dispatch_table.zig").InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const dst_tbl_idx = instr.payload;
    const src_tbl_idx = instr.extra;
    if (dst_tbl_idx >= rt.tables.len or src_tbl_idx >= rt.tables.len) return Trap.Unreachable;
    const dst_tbl = rt.tables[dst_tbl_idx];
    const src_tbl = rt.tables[src_tbl_idx];

    // table64: dst/src indices use their own table's width; n uses the
    // narrower (mirrors the validator's memory.copy-style n typing).
    const n_idx_type: zir.IdxType = if (dst_tbl.idx_type == .i32 or src_tbl.idx_type == .i32) .i32 else .i64;
    const n = popTableIndex(rt, n_idx_type);
    const src = popTableIndex(rt, src_tbl.idx_type);
    const dst = popTableIndex(rt, dst_tbl.idx_type);
    const src_end = @addWithOverflow(src, n);
    const dst_end = @addWithOverflow(dst, n);
    if (src_end[1] != 0 or dst_end[1] != 0 or src_end[0] > src_tbl.refs.len or dst_end[0] > dst_tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    if (n == 0) return;
    const src_lo: usize = @intCast(src);
    const dst_lo: usize = @intCast(dst);
    const n_lo: usize = @intCast(n);

    const same = dst_tbl_idx == src_tbl_idx;
    if (same and dst_lo > src_lo and dst_lo < src_lo + n_lo) {
        // Self-overlap with dst > src — copy backwards.
        var i: usize = n_lo;
        while (i > 0) {
            i -= 1;
            dst_tbl.refs[dst_lo + i] = src_tbl.refs[src_lo + i];
        }
    } else {
        var i: usize = 0;
        while (i < n_lo) : (i += 1) {
            dst_tbl.refs[dst_lo + i] = src_tbl.refs[src_lo + i];
        }
    }
}

/// table.init x y: payload = elemidx, extra = tableidx. Pop n,
/// src, dst. Copy n refs from elems[x] to tables[y]. Trap if
/// src+n > elem.len OR dst+n > table.len. Treat dropped segments
/// as zero-length.
fn tableInit(c: *@import("../../ir/dispatch_table.zig").InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const elemidx = instr.payload;
    const tableidx = instr.extra;
    if (elemidx >= rt.elems.len or tableidx >= rt.tables.len) return Trap.Unreachable;
    const dropped = if (elemidx < rt.elem_dropped.len) rt.elem_dropped[elemidx] else false;
    const seg = rt.elems[elemidx];
    const seg_len: u64 = if (dropped) 0 else seg.len;
    const tbl = rt.tables[tableidx];

    // table64: the elem segment is i32-indexed (src + n stay i32); only the
    // destination table address uses the table's width.
    const n: u64 = @as(u32, @bitCast(rt.popOperand().i32));
    const src: u64 = @as(u32, @bitCast(rt.popOperand().i32));
    const dst = popTableIndex(rt, tbl.idx_type);
    const dst_end = @addWithOverflow(dst, n);
    if (src + n > seg_len or dst_end[1] != 0 or dst_end[0] > tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    if (n == 0) return;
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        tbl.refs[@as(usize, @intCast(dst)) + i] = seg[@as(usize, @intCast(src)) + i];
    }
}

/// elem.drop x: mark element segment x as dropped. Subsequent
/// table.init x calls treat its length as 0.
fn elemDrop(c: *@import("../../ir/dispatch_table.zig").InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const elemidx = instr.payload;
    if (elemidx >= rt.elem_dropped.len) return Trap.Unreachable;
    rt.elem_dropped[elemidx] = true;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("../../interp/dispatch.zig");
const Value = runtime.Value;
const TableInstance = runtime.TableInstance;

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "register: all eight table ops populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"table.get")] != null);
    try testing.expect(t.interp[op(.@"table.set")] != null);
    try testing.expect(t.interp[op(.@"table.size")] != null);
    try testing.expect(t.interp[op(.@"table.grow")] != null);
    try testing.expect(t.interp[op(.@"table.fill")] != null);
    try testing.expect(t.interp[op(.@"table.copy")] != null);
    try testing.expect(t.interp[op(.@"table.init")] != null);
    try testing.expect(t.interp[op(.@"elem.drop")] != null);
}

test "table.size: returns refs.len" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs = [_]Value{ .{ .ref = Value.null_ref }, .{ .ref = 7 }, .{ .ref = 9 } };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    try driveOne(&rt, &t, .@"table.size", 0, 0);
    try testing.expectEqual(@as(i32, 3), rt.popOperand().i32);
}

test "table.get / set round-trip" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs = [_]Value{
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
    };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    // table.set: idx=1, val=ref(42)
    try rt.pushOperand(.{ .i32 = 1 });
    try rt.pushOperand(.{ .ref = 42 });
    try driveOne(&rt, &t, .@"table.set", 0, 0);

    // table.get: idx=1
    try rt.pushOperand(.{ .i32 = 1 });
    try driveOne(&rt, &t, .@"table.get", 0, 0);
    try testing.expectEqual(@as(u64, 42), rt.popOperand().ref);

    // Other slots untouched.
    try testing.expectEqual(Value.null_ref, refs[0].ref);
    try testing.expectEqual(Value.null_ref, refs[2].ref);
}

test "table.get: idx out of range traps OutOfBoundsTableAccess" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs = [_]Value{.{ .ref = Value.null_ref }};
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    try rt.pushOperand(.{ .i32 = 5 });
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.get", 0, 0));
}

test "table.set: idx out of range traps OutOfBoundsTableAccess" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs = [_]Value{.{ .ref = Value.null_ref }};
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    try rt.pushOperand(.{ .i32 = 1 });
    try rt.pushOperand(.{ .ref = 7 });
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.set", 0, 0));
}

test "table.get: tableidx out of range traps Unreachable" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // No tables wired.
    try rt.pushOperand(.{ .i32 = 0 });
    try testing.expectError(Trap.Unreachable, driveOne(&rt, &t, .@"table.get", 0, 0));
}

test "table.fill: writes n cells with val; trap on dst+n > len" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]Value{
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
    };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    // table.fill 0: dst=1, val=ref(7), n=2 → cells 1..3 = 7
    try rt.pushOperand(.{ .i32 = 1 });
    try rt.pushOperand(.{ .ref = 7 });
    try rt.pushOperand(.{ .i32 = 2 });
    try driveOne(&rt, &t, .@"table.fill", 0, 0);
    try testing.expectEqual(Value.null_ref, refs[0].ref);
    try testing.expectEqual(@as(u64, 7), refs[1].ref);
    try testing.expectEqual(@as(u64, 7), refs[2].ref);
    try testing.expectEqual(Value.null_ref, refs[3].ref);

    // OOB: dst=3, n=2 (3+2=5 > 4) → trap.
    try rt.pushOperand(.{ .i32 = 3 });
    try rt.pushOperand(.{ .ref = 9 });
    try rt.pushOperand(.{ .i32 = 2 });
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.fill", 0, 0));
}

test "table.grow: extends refs and pushes prev_size" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    // Initial table of length 2; allocate via testing.allocator so realloc works.
    const initial = try testing.allocator.alloc(Value, 2);
    initial[0] = .{ .ref = 1 };
    initial[1] = .{ .ref = 2 };
    var tbls = [_]TableInstance{.{ .refs = initial, .elem_type = .funcref }};
    rt.tables = &tbls;
    defer testing.allocator.free(rt.tables[0].refs);

    // table.grow 0: init=ref(99), n=3 → prev_size=2; new len=5 with cells 2..5 = 99
    try rt.pushOperand(.{ .ref = 99 });
    try rt.pushOperand(.{ .i32 = 3 });
    try driveOne(&rt, &t, .@"table.grow", 0, 0);
    try testing.expectEqual(@as(i32, 2), rt.popOperand().i32);
    try testing.expectEqual(@as(usize, 5), rt.tables[0].refs.len);
    try testing.expectEqual(@as(u64, 1), rt.tables[0].refs[0].ref);
    try testing.expectEqual(@as(u64, 99), rt.tables[0].refs[2].ref);
    try testing.expectEqual(@as(u64, 99), rt.tables[0].refs[4].ref);
}

test "6.K.2: table.grow against per-instance arena reallocs through rt.alloc" {
    // Per ADR-0014 §2.2 / 6.K.2 acceptance: a freshly-instantiated
    // module's `rt.alloc` is the per-instance arena, and `table.grow`
    // realloc lands on that arena. The grown slice must hold the
    // previous values plus the init-value at the appended slots.
    var t = DispatchTable.init();
    register(&t);

    // Stand in for what `instantiateRuntime` does: a Runtime whose
    // alloc is the per-instance arena's allocator. The arena's
    // backing allocator (page_allocator here) reclaims everything
    // at `arena.deinit()` regardless of which slices grew.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var rt = Runtime.init(a);
    defer rt.deinit();

    // Defined-table refs come from the same arena per 6.K.2's
    // single-allocator policy.
    const initial = try a.alloc(Value, 2);
    initial[0] = .{ .ref = 11 };
    initial[1] = .{ .ref = 22 };
    var tbls = [_]TableInstance{.{ .refs = initial, .elem_type = .funcref }};
    rt.tables = &tbls;

    // Grow by 3 with init = 99.
    try rt.pushOperand(.{ .ref = 99 });
    try rt.pushOperand(.{ .i32 = 3 });
    try driveOne(&rt, &t, .@"table.grow", 0, 0);
    try testing.expectEqual(@as(i32, 2), rt.popOperand().i32);
    try testing.expectEqual(@as(usize, 5), rt.tables[0].refs.len);
    try testing.expectEqual(@as(u64, 11), rt.tables[0].refs[0].ref);
    try testing.expectEqual(@as(u64, 22), rt.tables[0].refs[1].ref);
    try testing.expectEqual(@as(u64, 99), rt.tables[0].refs[2].ref);
    try testing.expectEqual(@as(u64, 99), rt.tables[0].refs[3].ref);
    try testing.expectEqual(@as(u64, 99), rt.tables[0].refs[4].ref);
}

test "table.grow: max-cap violation pushes -1" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    const initial = try testing.allocator.alloc(Value, 2);
    initial[0] = .{ .ref = 0 };
    initial[1] = .{ .ref = 0 };
    var tbls = [_]TableInstance{.{ .refs = initial, .elem_type = .funcref, .max = 3 }};
    rt.tables = &tbls;
    defer testing.allocator.free(rt.tables[0].refs);

    // n=5 → would overflow max=3 → push -1, no mutation.
    try rt.pushOperand(.{ .ref = 0 });
    try rt.pushOperand(.{ .i32 = 5 });
    try driveOne(&rt, &t, .@"table.grow", 0, 0);
    try testing.expectEqual(@as(i32, -1), rt.popOperand().i32);
    try testing.expectEqual(@as(usize, 2), rt.tables[0].refs.len);
}

test "table.copy: cross-table copy moves refs" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs0 = [_]Value{
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
    };
    var refs1 = [_]Value{ .{ .ref = 7 }, .{ .ref = 8 }, .{ .ref = 9 } };
    var tbls = [_]TableInstance{
        .{ .refs = &refs0, .elem_type = .funcref },
        .{ .refs = &refs1, .elem_type = .funcref },
    };
    rt.tables = &tbls;

    // table.copy 0 1: dst=0, src=1, n=2 → tables[0][0..2] = tables[1][0..2]
    // payload=0 (dst), extra=1 (src)
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 2 }); // n
    try driveOne(&rt, &t, .@"table.copy", 0, 1);
    try testing.expectEqual(@as(u64, 7), refs0[0].ref);
    try testing.expectEqual(@as(u64, 8), refs0[1].ref);
    try testing.expectEqual(Value.null_ref, refs0[2].ref);
}

test "table.copy: same-table overlap with dst > src copies backwards" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs = [_]Value{
        .{ .ref = 1 }, .{ .ref = 2 }, .{ .ref = 3 }, .{ .ref = 4 }, .{ .ref = 5 },
    };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    // table.copy 0 0: dst=2, src=0, n=3 → backwards copy.
    // After: refs = [1, 2, 1, 2, 3]
    try rt.pushOperand(.{ .i32 = 2 });
    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 3 });
    try driveOne(&rt, &t, .@"table.copy", 0, 0);
    try testing.expectEqual(@as(u64, 1), refs[0].ref);
    try testing.expectEqual(@as(u64, 2), refs[1].ref);
    try testing.expectEqual(@as(u64, 1), refs[2].ref);
    try testing.expectEqual(@as(u64, 2), refs[3].ref);
    try testing.expectEqual(@as(u64, 3), refs[4].ref);
}

test "table.copy: src+n > src_len traps" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs0 = [_]Value{ .{ .ref = 0 }, .{ .ref = 0 }, .{ .ref = 0 } };
    var refs1 = [_]Value{ .{ .ref = 0 }, .{ .ref = 0 } };
    var tbls = [_]TableInstance{
        .{ .refs = &refs0, .elem_type = .funcref },
        .{ .refs = &refs1, .elem_type = .funcref },
    };
    rt.tables = &tbls;
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 1 }); // src
    try rt.pushOperand(.{ .i32 = 3 }); // n (1+3=4 > src_len=2)
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.copy", 0, 1));
}

fn setupElems(rt: *Runtime, segs: []const []const Value) !void {
    rt.elems = segs;
    rt.elem_dropped = try rt.alloc.alloc(bool, segs.len);
    @memset(rt.elem_dropped, false);
}

test "table.init: copies refs from element segment to table" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs = [_]Value{
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
    };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    const seg0 = [_]Value{ .{ .ref = 11 }, .{ .ref = 22 }, .{ .ref = 33 } };
    const segs = [_][]const Value{&seg0};
    try setupElems(&rt, &segs);

    // table.init 0 0: dst=1, src=0, n=2. Encoding: payload=0 (elemidx), extra=0 (tableidx)
    try rt.pushOperand(.{ .i32 = 1 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 2 }); // n
    try driveOne(&rt, &t, .@"table.init", 0, 0);
    try testing.expectEqual(Value.null_ref, refs[0].ref);
    try testing.expectEqual(@as(u64, 11), refs[1].ref);
    try testing.expectEqual(@as(u64, 22), refs[2].ref);
    try testing.expectEqual(Value.null_ref, refs[3].ref);
}

test "table.init: src+n > seg_len traps" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]Value{ .{ .ref = Value.null_ref }, .{ .ref = Value.null_ref } };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const seg0 = [_]Value{.{ .ref = 0 }};
    const segs = [_][]const Value{&seg0};
    try setupElems(&rt, &segs);

    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 5 }); // n=5 > seg_len=1
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.init", 0, 0));
}

test "table.init after elem.drop: any n>0 traps; n=0 succeeds" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]Value{.{ .ref = Value.null_ref }};
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const seg0 = [_]Value{ .{ .ref = 1 }, .{ .ref = 2 } };
    const segs = [_][]const Value{&seg0};
    try setupElems(&rt, &segs);

    // elem.drop 0
    try driveOne(&rt, &t, .@"elem.drop", 0, 0);
    try testing.expectEqual(true, rt.elem_dropped[0]);

    // n=1 → trap.
    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 1 });
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.init", 0, 0));

    // n=0 → no-op.
    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 0 });
    try driveOne(&rt, &t, .@"table.init", 0, 0);
}

test "elem.drop: elemidx out of range traps Unreachable" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try testing.expectError(Trap.Unreachable, driveOne(&rt, &t, .@"elem.drop", 0, 0));
}

// table64 (D-475): an i64-indexed table pops its index/n + pushes
// size/grow results at i64 width.
test "table64: get/set round-trip with i64 index" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]Value{ .{ .ref = Value.null_ref }, .{ .ref = Value.null_ref }, .{ .ref = Value.null_ref } };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref, .idx_type = .i64 }};
    rt.tables = &tbls;

    try rt.pushOperand(.{ .i64 = 2 });
    try rt.pushOperand(.{ .ref = 99 });
    try driveOne(&rt, &t, .@"table.set", 0, 0);

    try rt.pushOperand(.{ .i64 = 2 });
    try driveOne(&rt, &t, .@"table.get", 0, 0);
    try testing.expectEqual(@as(u64, 99), rt.popOperand().ref);
}

test "table64: size pushes i64" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]Value{ .{ .ref = Value.null_ref }, .{ .ref = Value.null_ref }, .{ .ref = Value.null_ref } };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref, .idx_type = .i64 }};
    rt.tables = &tbls;
    try driveOne(&rt, &t, .@"table.size", 0, 0);
    try testing.expectEqual(@as(i64, 3), rt.popOperand().i64);
}

test "table64: index > 2^32 traps OOB (full-width read, not i32-truncated)" {
    // refs.len = 2; index = 2^32 (low 32 bits = 0). An i32-truncating read
    // would see 0 (in-bounds → wrong); the full i64 read sees 2^32 → OOB.
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]Value{ .{ .ref = Value.null_ref }, .{ .ref = Value.null_ref } };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref, .idx_type = .i64 }};
    rt.tables = &tbls;
    try rt.pushOperand(.{ .i64 = 0x1_0000_0000 });
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.get", 0, 0));
}
