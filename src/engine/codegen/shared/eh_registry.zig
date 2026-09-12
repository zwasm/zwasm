//! Process-global registry: live JIT instances' code-block address
//! ranges → their EH views, for cross-instance unwinding (ADR-0134 D2).
//!
//! The FP-walk unwinder (`unwind.walk`) resolves each frame's absolute
//! PC to its OWNING instance via this registry, so it consults THAT
//! instance's exception table + tag-identity map (`tag_ids`) — letting
//! a module-1 throw reach a module-2 catch. The owning instance is the
//! one whose per-Instance `CodeMap` (built from `rt.eh_code_map_entries`)
//! contains the PC; the registry just holds the live `*JitRuntime`s and
//! reuses each one's existing CodeMap for the containment test + the
//! abs→module-relative PC normalization.
//!
//! **Every path that heap-pins a `JitInstance` must register it** — the C
//! API's `instantiateJit` and the spec runner. An instance that is not in
//! here cannot be unwound through: a throw inside it resolves to nothing,
//! so no handler is found and the walk runs on into host frames (#426).
//! Reads allocate nothing and take no lock, per ADR-0114 D5 (no allocator
//! calls between teardown and landing); growth happens in `register`, at
//! instantiation, where allocating is allowed.
//!
//! **Capacity is growable, not capped.** Past `initial_slots` a doubled
//! table is published with an atomic store and the superseded one is KEPT,
//! because an in-flight reader may still hold its pointer. Nothing is freed,
//! so the retained total is the sum of the generations: under 2× the FINAL
//! capacity, and since the growth that produced that capacity was triggered
//! by a live count past half of it, under 4× the live high-water mark.
//! "Full → refuse
//! to register" would be a cliff, not a limit: under `.auto` the instance
//! past the cap falls to the interpreter, and then every instance importing
//! it declines too, since an interp-backed source is not a JIT import
//! target (`api/instance.zig:crossModuleJitTarget`). Scan cost is per LIVE
//! instance, not per slot (`slot orelse continue`), so capacity only ever
//! cost memory.
//!
//! **Concurrency: the table only.** `register` / `unregister` serialize under
//! `table_lock`, and readers take no lock, loading each published slot
//! atomically — so a scan cannot see a half-written slot or walk a table
//! being grown. That is the whole of the guarantee, and it is deliberately
//! narrower than "thread-safe".
//!
//! **There is no reclamation, and the read path cannot have one.** A reader
//! loads a `*JitRuntime` and then dereferences it (`cmapFor`), and `resolve` /
//! `codeMapForPc` hand back slices INTO that runtime which the trampoline
//! keeps using after the lookup returns. Storing null in the slot stops the
//! next reader; it does nothing for one that already loaded the pointer, and
//! `wasm_store_delete` frees the runtime immediately after unregistering it.
//! Two threads unwinding and tearing down concurrently would therefore read
//! freed memory. What rules that out is not this file: ROADMAP §7 says
//! "Phases 0–10: single-threaded" — one thread per PROCESS, not per Store,
//! which matters because this table spans stores and is what makes two Stores
//! on two threads reach each other at all. Nothing in the engine spawns a
//! thread that arrives here either (the CLI's timeout raiser only stores an
//! interrupt flag). The public headers state the constraint in those terms,
//! since a per-Store reading of it would permit exactly this race.
//! Phase 11's thread-safe Engine is what needs the missing half — a read
//! guard held from before `dispatchThrow` until every view it returned is
//! done, with `JitInstance.deinit` deferred behind it. Not a per-lookup
//! counter: the views outlive the lookup.
//!
//! Serializing the writers says nothing about the read, which runs on
//! whichever thread threw; `platform/signal.zig` arms its alternate signal
//! stack once per thread (#321) because more than one can be inside JIT code.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

const jit_abi = @import("jit_abi.zig");
const code_map_mod = @import("code_map.zig");
const exception_table = @import("exception_table.zig");
const unwind = @import("unwind.zig");

/// Slots in the statically-allocated first generation. Sized so the
/// common embedding (a handful of linked instances) never allocates;
/// past it `grow` takes over.
const initial_slots = 64;

/// Backing store for the growable tables. `slots` is either the static
/// first generation or a heap block that is never freed; `prev` is the
/// generation this one superseded, kept reachable so `unregister` can
/// clear a slot in EVERY table a reader might still be holding.
fn Table(comptime Slot: type) type {
    return struct {
        slots: []Slot,
        prev: ?*@This(),
    };
}

/// Serializes `register` / `unregister` / `reset` against each other.
/// NOT taken by the read path. A spin lock, not a blocking one: the
/// critical section is a scan of the slot array, the callers are
/// instantiation and teardown, and `std.atomic.Mutex` is the only mutex
/// reachable from Zone 2 without an `Io` handle.
var table_lock: std.atomic.Mutex = .unlocked;

fn lockTables() void {
    while (!table_lock.tryLock()) std.atomic.spinLoopHint();
}

/// The tables are never freed, so they outlive every allocator a Store
/// could offer. `page_allocator` is the one that needs no libc and no
/// caller-supplied handle.
const table_allocator = std.heap.page_allocator;

/// Publish a table twice the size of `live.*`, carrying its slots over.
/// Caller holds `table_lock`.
fn grow(comptime Slot: type, live: **Table(Slot), empty: Slot) error{OutOfMemory}!void {
    const old = live.*;
    const slots = try table_allocator.alloc(Slot, old.slots.len * 2);
    errdefer table_allocator.free(slots);
    @memcpy(slots[0..old.slots.len], old.slots);
    @memset(slots[old.slots.len..], empty);
    const next = try table_allocator.create(Table(Slot));
    next.* = .{ .slots = slots, .prev = old };
    // Release: a reader that acquires this pointer must see the copied
    // slots. The superseded table stays valid for whoever already has it.
    @atomicStore(*Table(Slot), live, next, .release);
}

var rt_gen0_slots: [initial_slots]?*jit_abi.JitRuntime = .{null} ** initial_slots;
var rt_gen0: Table(?*jit_abi.JitRuntime) = .{ .slots = &rt_gen0_slots, .prev = null };
var rts: *Table(?*jit_abi.JitRuntime) = &rt_gen0;

/// Registered bridge-thunk arena address ranges (D-238 / ADR-0185 (b)).
/// A cross-module bridge thunk lives in the IMPORTER instance's
/// `thunk_arena`, outside every instance's per-function CodeMap. The
/// x86_64 frame-chain sniff must still recognize a thunk-return address
/// as valid code to disambiguate the callee's prologue layout, so the
/// arenas are registered globally here (the importer's arena is not the
/// throwing instance's view).
///
/// `start == 0` marks a free slot — a mapped page never has address 0.
///
/// A range is two words, and no portable atomic loads both at once, so `seq`
/// makes the PAIR readable: a writer bumps it to odd, writes the fields, and
/// bumps it to even, and a reader that sees an odd or a changed `seq` skips
/// the slot instead of pairing an old `start` with a new `len`. Ordering
/// alone cannot do this — it rules out a zero `start` beside a live `len`,
/// but not one generation's `start` beside the next generation's `len` after
/// `unregisterThunkArena` frees a slot that a new registration then reuses.
/// Skipping errs toward "not a thunk", which is where an unregistered arena
/// already sat, and it costs one extra load rather than a retry loop on the
/// allocation-free unwind path.
const ThunkRange = struct { seq: usize = 0, start: usize = 0, len: usize = 0 };
var thunk_gen0_slots: [initial_slots]ThunkRange = .{ThunkRange{}} ** initial_slots;
var thunk_gen0: Table(ThunkRange) = .{ .slots = &thunk_gen0_slots, .prev = null };
var thunk_ranges: *Table(ThunkRange) = &thunk_gen0;

/// Open a write to `slot` (caller holds `table_lock`): `seq` goes odd, so a
/// reader mid-flight skips the slot rather than reading a half-written pair.
fn beginThunkWrite(slot: *ThunkRange) void {
    @atomicStore(usize, &slot.seq, slot.seq + 1, .release);
}

/// Close a write opened by `beginThunkWrite`: `seq` goes even again.
fn endThunkWrite(slot: *ThunkRange) void {
    @atomicStore(usize, &slot.seq, slot.seq + 1, .release);
}

/// Read `slot`'s range as one consistent pair, or null when the slot is free
/// or being written. Both payload loads are atomic (a concurrent write is a
/// data race otherwise); `seq` is what makes them a snapshot.
fn readThunkRange(slot: *const ThunkRange) ?struct { start: usize, len: usize } {
    const before = @atomicLoad(usize, &slot.seq, .acquire);
    if (before & 1 != 0) return null; // a write is open
    const start = @atomicLoad(usize, &slot.start, .acquire);
    const len = @atomicLoad(usize, &slot.len, .acquire);
    if (@atomicLoad(usize, &slot.seq, .acquire) != before) return null; // it changed
    if (start == 0) return null;
    return .{ .start = start, .len = len };
}

/// Register a live instance (idempotent). Address must be stable for
/// the registered lifetime (heap-pinned per D-225's exporter contract).
/// `OutOfMemory` only when the table must grow and cannot — the caller
/// declines the JIT instantiation rather than run an instance that
/// cannot be unwound through (#426).
pub fn register(rt: *jit_abi.JitRuntime) error{OutOfMemory}!void {
    lockTables();
    defer table_lock.unlock();
    for (rts.slots) |slot| if (slot == rt) return;
    while (true) {
        for (rts.slots) |*slot| if (slot.* == null) {
            @atomicStore(?*jit_abi.JitRuntime, slot, rt, .release);
            return;
        };
        try grow(?*jit_abi.JitRuntime, &rts, null);
    }
}

/// Remove an instance at teardown (no-op if absent). Clears the slot in
/// every generation, so a reader holding a superseded table cannot
/// resolve a PC to an instance that is going away.
pub fn unregister(rt: *jit_abi.JitRuntime) void {
    lockTables();
    defer table_lock.unlock();
    var t: ?*Table(?*jit_abi.JitRuntime) = rts;
    while (t) |tbl| : (t = tbl.prev) {
        for (tbl.slots) |*slot| if (slot.* == rt) {
            @atomicStore(?*jit_abi.JitRuntime, slot, null, .release);
        };
    }
}

/// Register a bridge-thunk arena's address range (idempotent on `start`).
/// Called at JIT finalize once the arena page is mapped (`setup.zig`).
pub fn registerThunkArena(start: usize, len: usize) error{OutOfMemory}!void {
    lockTables();
    defer table_lock.unlock();
    for (thunk_ranges.slots) |slot| if (slot.start == start) return;
    while (true) {
        for (thunk_ranges.slots) |*slot| if (slot.start == 0) {
            beginThunkWrite(slot);
            @atomicStore(usize, &slot.start, start, .monotonic);
            @atomicStore(usize, &slot.len, len, .monotonic);
            endThunkWrite(slot);
            return;
        };
        try grow(ThunkRange, &thunk_ranges, .{});
    }
}

/// Remove a thunk arena at teardown (no-op if absent). Clears every
/// generation, for the reason `unregister` does.
pub fn unregisterThunkArena(start: usize) void {
    lockTables();
    defer table_lock.unlock();
    var t: ?*Table(ThunkRange) = thunk_ranges;
    while (t) |tbl| : (t = tbl.prev) {
        for (tbl.slots) |*slot| if (slot.start == start) {
            beginThunkWrite(slot);
            @atomicStore(usize, &slot.start, 0, .monotonic);
            @atomicStore(usize, &slot.len, 0, .monotonic);
            endThunkWrite(slot);
        };
    }
}

/// True if `addr` falls inside any registered bridge-thunk arena.
pub fn isThunkAddr(addr: usize) bool {
    const tbl = @atomicLoad(*Table(ThunkRange), &thunk_ranges, .acquire);
    for (tbl.slots) |*slot| {
        const r = readThunkRange(slot) orelse continue;
        if (addr >= r.start and addr < r.start + r.len) return true;
    }
    return false;
}

/// True if `abs_pc` is a valid JIT code address ANYWHERE in the live EH
/// world — any registered instance's CodeMap OR any registered bridge-thunk
/// arena (ADR-0185 (c)). The x86_64 frame-chain sniff uses this (not a
/// single instance's CodeMap) to disambiguate a frame's prologue layout,
/// because a cross-instance unwind walks frames belonging to other
/// instances + the importer's bridge thunk.
pub fn isCodeAddr(abs_pc: usize) bool {
    if (isThunkAddr(abs_pc)) return true;
    const tbl = @atomicLoad(*Table(?*jit_abi.JitRuntime), &rts, .acquire);
    for (tbl.slots) |*slot| {
        const rt = @atomicLoad(?*jit_abi.JitRuntime, slot, .acquire) orelse continue;
        const cmap = cmapFor(rt);
        if (cmap.entries.len == 0) continue;
        switch (cmap.lookup(abs_pc)) {
            .inside => return true,
            .outside => {},
        }
    }
    return false;
}

/// Drop all registrations (test isolation). Keeps the tables themselves —
/// a later `register` reuses the slots rather than growing again.
pub fn reset() void {
    lockTables();
    defer table_lock.unlock();
    var r: ?*Table(?*jit_abi.JitRuntime) = rts;
    while (r) |tbl| : (r = tbl.prev) @memset(tbl.slots, null);
    var t: ?*Table(ThunkRange) = thunk_ranges;
    while (t) |tbl| : (t = tbl.prev) for (tbl.slots) |*slot| {
        beginThunkWrite(slot);
        slot.start = 0;
        slot.len = 0;
        endThunkWrite(slot);
    };
}

fn cmapFor(rt: *const jit_abi.JitRuntime) code_map_mod.CodeMap {
    return .{ .entries = if (rt.eh_code_map_entries) |p| p[0..rt.eh_code_map_count] else &.{} };
}

fn tableFor(rt: *const jit_abi.JitRuntime) exception_table.ExceptionTable {
    return .{
        .entries = if (rt.eh_table_entries) |p| p[0..rt.eh_table_count] else &.{},
        .tag_ids = if (rt.tag_ids_ptr) |p| p[0..rt.tag_ids_count] else null,
    };
}

/// `unwind.InstanceResolver.resolve` impl: find the registered instance
/// whose CodeMap contains `abs_pc` and return its table + the PC
/// normalized to that instance's module space. `null` when no instance
/// owns the PC (e.g. a cross-module bridge-thunk frame → pass-through).
pub fn resolve(abs_pc: usize, ctx: ?*anyopaque) ?unwind.ResolvedFrame {
    _ = ctx;
    const tbl = @atomicLoad(*Table(?*jit_abi.JitRuntime), &rts, .acquire);
    for (tbl.slots) |*slot| {
        const rt = @atomicLoad(?*jit_abi.JitRuntime, slot, .acquire) orelse continue;
        const cmap = cmapFor(rt);
        if (cmap.entries.len == 0) continue;
        switch (cmap.lookup(abs_pc)) {
            .inside => return .{
                .table = tableFor(rt),
                .module_pc = code_map_mod.toModuleRelativePc(&cmap, abs_pc),
            },
            .outside => {},
        }
    }
    return null;
}

/// Build the `InstanceResolver` the trampoline passes to `unwind.walk`.
pub fn resolver() unwind.InstanceResolver {
    return .{ .resolve = resolve, .ctx = null };
}

/// Return the CodeMap of the registered instance that owns `abs_pc`, or
/// null if none. The trampoline uses this for the `.handler` SP-restore
/// + landing-pad computation when the catching frame is in a DIFFERENT
/// instance than the throwing one (cross-instance catch): the handler's
/// `start_addr` + `frame_bytes` must come from the CATCHING instance's
/// CodeMap, not the throwing one's (ADR-0134 D2).
/// The registered runtime that owns `abs_pc`, or null if none. Companion to
/// `codeMapForPc`: the trampoline needs the CATCHING instance's runtime, not
/// only its CodeMap, to put the pinned invariant registers back before it
/// jumps to a landing pad in another instance (#426 review).
pub fn runtimeForPc(abs_pc: usize) ?*jit_abi.JitRuntime {
    const tbl = @atomicLoad(*Table(?*jit_abi.JitRuntime), &rts, .acquire);
    for (tbl.slots) |*slot| {
        const rt = @atomicLoad(?*jit_abi.JitRuntime, slot, .acquire) orelse continue;
        const cmap = cmapFor(rt);
        if (cmap.entries.len == 0) continue;
        switch (cmap.lookup(abs_pc)) {
            .inside => return rt,
            .outside => {},
        }
    }
    return null;
}

pub fn codeMapForPc(abs_pc: usize) ?code_map_mod.CodeMap {
    const tbl = @atomicLoad(*Table(?*jit_abi.JitRuntime), &rts, .acquire);
    for (tbl.slots) |*slot| {
        const rt = @atomicLoad(?*jit_abi.JitRuntime, slot, .acquire) orelse continue;
        const cmap = cmapFor(rt);
        if (cmap.entries.len == 0) continue;
        switch (cmap.lookup(abs_pc)) {
            .inside => return cmap,
            .outside => {},
        }
    }
    return null;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "eh_registry: resolve picks the instance whose CodeMap contains the PC" {
    reset();
    defer reset();

    // Two synthetic instances. A's code block at 0x10000; B's at 0x20000.
    var a_cm = [_]code_map_mod.Entry{.{ .start_addr = 0x10000, .len = 0x100, .func_idx = 0 }};
    var b_cm = [_]code_map_mod.Entry{.{ .start_addr = 0x20000, .len = 0x100, .func_idx = 0 }};
    const a_ids = [_]u64{0xAA};
    const b_ids = [_]u64{0xAA};

    // Only the EH-view fields `resolve` reads need values; the rest of
    // the extern struct is irrelevant to the registry (left undefined).
    var a_rt: jit_abi.JitRuntime = undefined;
    a_rt.eh_code_map_entries = &a_cm;
    a_rt.eh_code_map_count = 1;
    a_rt.eh_table_entries = null;
    a_rt.eh_table_count = 0;
    a_rt.tag_ids_ptr = &a_ids;
    a_rt.tag_ids_count = 1;
    var b_rt: jit_abi.JitRuntime = undefined;
    b_rt.eh_code_map_entries = &b_cm;
    b_rt.eh_code_map_count = 1;
    b_rt.eh_table_entries = null;
    b_rt.eh_table_count = 0;
    b_rt.tag_ids_ptr = &b_ids;
    b_rt.tag_ids_count = 1;

    try register(&a_rt);
    try register(&b_rt);
    try register(&a_rt); // idempotent

    // PC in A → A's table + module_pc relative to A's block base.
    const ra = resolve(0x10042, null).?;
    try testing.expectEqual(@as(u32, 0x42), ra.module_pc);
    try testing.expectEqual(@as(?[]const u64, &a_ids), ra.table.tag_ids);

    // PC in B → B's instance.
    const rb = resolve(0x20010, null).?;
    try testing.expectEqual(@as(u32, 0x10), rb.module_pc);
    try testing.expectEqual(@as(?[]const u64, &b_ids), rb.table.tag_ids);

    // PC in neither (a thunk-arena address) → pass-through null.
    try testing.expectEqual(@as(?unwind.ResolvedFrame, null), resolve(0x90000, null));

    // After unregister, A's PC no longer resolves.
    unregister(&a_rt);
    try testing.expectEqual(@as(?unwind.ResolvedFrame, null), resolve(0x10042, null));
}

test "eh_registry: thunk-arena range registration + isThunkAddr (ADR-0185 b)" {
    reset();
    defer reset();

    try registerThunkArena(0x50000, 0x80);
    try registerThunkArena(0x50000, 0x80); // idempotent on start
    try registerThunkArena(0x60000, 0x40);

    try testing.expect(isThunkAddr(0x50000)); // first byte
    try testing.expect(isThunkAddr(0x5007F)); // last byte in range
    try testing.expect(!isThunkAddr(0x50080)); // one past end → outside
    try testing.expect(!isThunkAddr(0x4FFFF)); // one before start → outside
    try testing.expect(isThunkAddr(0x60020)); // second arena

    unregisterThunkArena(0x50000);
    try testing.expect(!isThunkAddr(0x50000)); // gone
    try testing.expect(isThunkAddr(0x60020)); // other arena intact
}

test "eh_registry: a slot mid-write is skipped, never read as a torn pair (#424 review)" {
    reset();
    defer reset();

    try registerThunkArena(0x50000, 0x80);
    try testing.expect(isThunkAddr(0x50040));

    // Stand in for a reader that arrives between a writer's two field
    // stores: open the write, then move `start` on to what a REUSING
    // registration would put there while `len` still holds the old value.
    // Without `seq` the reader would pair the addresses it finds and claim
    // `[0x90000, 0x90080)` — or, with the stores in the other order, the old
    // start beside the new length.
    const slot = &thunk_ranges.slots[0];
    beginThunkWrite(slot);
    @atomicStore(usize, &slot.start, 0x90000, .monotonic);
    try testing.expect(!isThunkAddr(0x90040)); // the half-written pair claims nothing
    try testing.expect(!isThunkAddr(0x50040)); // and neither does the old one
    @atomicStore(usize, &slot.len, 0x100, .monotonic);
    endThunkWrite(slot);

    // Closed: the slot reads as exactly what the writer left.
    try testing.expect(isThunkAddr(0x900FF));
    try testing.expect(!isThunkAddr(0x90100));
    try testing.expect(!isThunkAddr(0x50040));
}

test "eh_registry: isCodeAddr spans all instances' CodeMaps + thunk ranges (ADR-0185 c)" {
    reset();
    defer reset();

    var a_cm = [_]code_map_mod.Entry{.{ .start_addr = 0x10000, .len = 0x100, .func_idx = 0 }};
    var b_cm = [_]code_map_mod.Entry{.{ .start_addr = 0x20000, .len = 0x100, .func_idx = 0 }};
    var a_rt: jit_abi.JitRuntime = undefined;
    a_rt.eh_code_map_entries = &a_cm;
    a_rt.eh_code_map_count = 1;
    var b_rt: jit_abi.JitRuntime = undefined;
    b_rt.eh_code_map_entries = &b_cm;
    b_rt.eh_code_map_count = 1;
    try register(&a_rt);
    try register(&b_rt);
    try registerThunkArena(0x50000, 0x80);

    // The load-bearing D-238 property: a PC in ANY instance's CodeMap OR
    // any thunk arena is "code", even though no single instance's CodeMap
    // contains all three — the single-CodeMap sniff could not see this.
    try testing.expect(isCodeAddr(0x10042)); // instance A's body
    try testing.expect(isCodeAddr(0x20010)); // instance B's body
    try testing.expect(isCodeAddr(0x50040)); // a bridge-thunk return addr
    try testing.expect(!isCodeAddr(0x90000)); // host stack / not code → false
}

test "eh_registry: registration past the static generation keeps resolving (#426)" {
    reset();
    defer reset();

    // `initial_slots + 1` instances: the last one forces a grow. Each gets
    // its own one-entry CodeMap at a distinct base so a resolve names it.
    const n = initial_slots + 1;
    var cms: [n][1]code_map_mod.Entry = undefined;
    var rt_storage: [n]jit_abi.JitRuntime = undefined;
    var ids: [n][1]u64 = undefined;
    for (0..n) |i| {
        const base = 0x10000 + i * 0x1000;
        cms[i] = .{.{ .start_addr = base, .len = 0x100, .func_idx = 0 }};
        ids[i] = .{@intCast(0xA000 + i)};
        rt_storage[i].eh_code_map_entries = &cms[i];
        rt_storage[i].eh_code_map_count = 1;
        rt_storage[i].eh_table_entries = null;
        rt_storage[i].eh_table_count = 0;
        rt_storage[i].tag_ids_ptr = &ids[i];
        rt_storage[i].tag_ids_count = 1;
        try register(&rt_storage[i]);
    }

    // Every instance still resolves — the ones copied into the grown table
    // and the one that caused the grow. The pre-growth table dropped the
    // 65th silently, which under `.auto` made it and every importer of it
    // decline to the interpreter.
    for (0..n) |i| {
        const base = 0x10000 + i * 0x1000;
        const r = resolve(base + 0x42, null).?;
        try testing.expectEqual(@as(u32, 0x42), r.module_pc);
        try testing.expectEqual(@as(?[]const u64, &ids[i]), r.table.tag_ids);
    }

    // And unregister reaches the superseded generation: clearing an
    // instance registered BEFORE the grow must stop resolving, not just
    // in the live table (a reader may still hold the old one).
    unregister(&rt_storage[0]);
    try testing.expectEqual(@as(?unwind.ResolvedFrame, null), resolve(0x10042, null));
    try testing.expect(resolve(0x10000 + 0x1000 + 0x42, null) != null);
}

test "eh_registry: thunk arenas past the static generation stay recognized" {
    reset();
    defer reset();

    const n = initial_slots + 1;
    for (0..n) |i| try registerThunkArena(0x50000 + i * 0x1000, 0x80);
    for (0..n) |i| {
        try testing.expect(isThunkAddr(0x50000 + i * 0x1000));
        try testing.expect(!isThunkAddr(0x50000 + i * 0x1000 + 0x80));
    }
    unregisterThunkArena(0x50000);
    try testing.expect(!isThunkAddr(0x50000));
    try testing.expect(isThunkAddr(0x51000));
}
