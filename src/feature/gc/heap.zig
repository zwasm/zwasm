//! Per-Store GC heap slab (ADR-0115 §1 + §5; ROADMAP §10 row 10.G).
//!
//! Cycle 3 of the 10.G-foundation bundle. Lands the minimal
//! bump-pointer allocator over an arena-backed slab. The slab is
//! a Runtime arena sub-region per ADR-0014 §6.K.2 single-allocator
//! policy (no separate libc path); `deinit` returns memory to the
//! parent arena.
//!
//! Key invariants (ADR-0115 §5):
//!   - 32-bit indexed `GcRef` (offset into slab). 4 GiB cap.
//!   - Object alignment ≥ 2 bytes (preserves low bit for i31
//!     discriminant per ADR-0116 §135-149).
//!   - `0` = null sentinel (offset 0 reserved; never allocated).
//!   - 4 KB page granularity for grow.
//!
//! Scope (deliberate; collector lives separately):
//!   - No mark/sweep / no compaction yet. The Collector vtable
//!     lands at cycle 4 (`collector_null.zig` + `collector_
//!     mark_sweep.zig`).
//!   - No write barriers — barrier-zero per ADR-0115 §3.
//!   - No root walker — Mode A default (host marks via
//!     `zwasm_runtime_with_root_scope` per §4) lands later.
//!
//! Zone 1 (`src/feature/gc/`).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// 32-bit offset into a `Heap.bytes` slab; `0` = null sentinel.
/// Matches `Value.anyref` arm (added cycle 1) — both encode the
/// same GcRef view per ADR-0115 §6.
pub const GcRef = u32;

/// Null reference (offset 0). Per ADR-0115 §5 the slab reserves
/// offset 0 so this sentinel cannot collide with a real object.
pub const null_ref: GcRef = 0;

/// Per-Store contiguous slab. 32-bit cursor (offset 1..maxU32);
/// allocations bump-advance the cursor + 2-byte align. Grow
/// reallocs the backing slice via the parent arena allocator in
/// 4 KB page chunks. ADR-0115 §5.
/// A reclaimed slab region available for reuse (§15.1 chunk 2 /
/// ADR-0147). `size` is the exact byte size the dead object occupied,
/// so `allocate` can exact-fit a same-size request into `offset`.
pub const FreeSlot = struct {
    offset: GcRef,
    size: u32,
};

pub const Heap = struct {
    /// Parent allocator backing `bytes`. Runtime arena per
    /// ADR-0014 §6.K.2 (so `deinit` doesn't free — the parent
    /// arena's `deinit` frees in bulk).
    parent: Allocator,
    /// Slab bytes. Grown in `page_size` increments. `bytes.ptr`
    /// is stable across grows because we use `parent.realloc`.
    bytes: []u8 = &.{},
    /// Next-free offset. Starts at 2 (offset 0 = null sentinel;
    /// offset 1 left padding to keep first object 2-byte aligned).
    cursor: u32 = 2,

    /// Heap-pressure collection trigger (§15.1 chunk 1c / ADR-0146).
    /// A collection is driven (by `object_alloc.maybeCollect`) once
    /// `cursor` reaches `next_gc_at`. The Heap owns only the SIGNAL —
    /// it cannot reach the Runtime/roots, so it never drives the
    /// collection itself.
    ///
    /// `pressure_bytes` is the growth budget between collections
    /// (settable; tests shrink it to trigger without huge allocs).
    /// `next_gc_at` is the cursor watermark that arms the next
    /// collection. `gc_cycles` counts collections actually run — the
    /// production-observable proof the trigger fired (sweep does not
    /// reclaim until chunk 2, so this counter is the only signal).
    pressure_bytes: u32 = default_pressure_bytes,
    next_gc_at: u32 = default_pressure_bytes,
    gc_cycles: u32 = 0,

    /// Reclamation free-list (§15.1 chunk 2 / ADR-0147). The sweep
    /// rebuilds this each collection from the dead (unmarked) objects;
    /// `allocate` reuses an exact-size slot before bumping the cursor.
    /// External (not intrusive) so dead slots keep their `ObjectHeader`
    /// and the heap stays walkable for the conservative scan + sweep.
    free_list: std.ArrayList(FreeSlot) = .empty,
    /// Dead slots that could not be enqueued because the `free_list`
    /// append OOM'd mid-sweep (ADR-0147). Best-effort reclaim: those
    /// slots just aren't reused this cycle — never a freed live object.
    reclaim_oom_count: u32 = 0,
    /// Allocator for a collection's transient buffers (the object-start
    /// set, the mark work list). Every buffer allocated from it is freed
    /// before that collection returns, so it must reclaim individual frees
    /// — never the `parent` arena, which would keep each one. The offset of
    /// `bytes`, which compiled code reads, is pinned by a test below.
    scratch: Allocator,

    /// 4 KB grow granularity per ADR-0115 §5. Page is the slab
    /// grow unit, NOT the OS page (the slab is a sub-region of
    /// the Runtime arena which is itself mmap-backed).
    pub const page_size: u32 = 4096;

    /// Object alignment floor per ADR-0115 §5. 2 bytes preserves
    /// the low bit for i31 discriminant per ADR-0116.
    pub const min_align: u32 = 2;

    /// 4 GiB cap (maxInt(u32)) per ADR-0115 §5. Multi-Store
    /// deployment for larger heaps.
    pub const max_size: u32 = std.math.maxInt(u32);

    /// Default growth budget between collections (§15.1 chunk 1c /
    /// ADR-0146). 1 MiB is a first-cut β policy; a build-option /
    /// adaptive sizing is a later optimisation, not load-bearing.
    pub const default_pressure_bytes: u32 = 1 << 20;

    pub const Error = error{
        /// Heap exhausted past 4 GiB cap (or parent arena OOM).
        OutOfHeap,
    };

    pub fn init(parent: Allocator, scratch: Allocator) Heap {
        return .{ .parent = parent, .scratch = scratch };
    }

    /// Returns memory to the parent allocator. Per ADR-0014
    /// §6.K.2 the parent is the Runtime arena, so this is
    /// usually a no-op (arena `deinit` frees in bulk); explicit
    /// free is provided for tests and standalone use.
    pub fn deinit(self: *Heap) void {
        if (self.bytes.len > 0) self.parent.free(self.bytes);
        self.bytes = &.{};
        self.cursor = 2;
        self.free_list.deinit(self.parent);
    }

    /// Total bytes currently held on the reclamation free-list
    /// (§15.1 chunk 2 / ADR-0147) — the reusable dead space the last
    /// sweep recorded. Observable proof reclamation is tracking.
    pub fn reclaimableBytes(self: *const Heap) u64 {
        var sum: u64 = 0;
        for (self.free_list.items) |slot| sum += slot.size;
        return sum;
    }

    /// Pop an exact-size reusable slot from the free-list, or null if
    /// none. Used by `allocate` to reuse a dead slot before bumping
    /// (§15.1 chunk 2 / ADR-0147). Linear scan — exact-size first cut.
    fn popFreeSlot(self: *Heap, size: u32) ?GcRef {
        var i: usize = self.free_list.items.len;
        while (i > 0) {
            i -= 1;
            if (self.free_list.items[i].size == size) {
                const off = self.free_list.items[i].offset;
                _ = self.free_list.swapRemove(i);
                return off;
            }
        }
        return null;
    }

    /// Bump-allocate `size` bytes from the slab, growing in
    /// 4 KB pages as needed. Returns the GcRef offset (≥ 2).
    /// Object alignment is forced to `min_align` (2 bytes) per
    /// the i31 low-bit invariant.
    pub fn allocate(self: *Heap, size: u32) Error!GcRef {
        if (size == 0) return self.cursor; // zero-size object alias
        // Reuse an exact-size dead slot before bumping (§15.1 chunk 2 /
        // ADR-0147). The slot is a former object start (already
        // min_align-aligned) and exact-fits `size`; cursor stays put.
        if (self.popFreeSlot(size)) |off| return off;
        // Align the cursor up to min_align before allocating.
        const aligned = std.mem.alignForward(u32, self.cursor, min_align);
        // Range check against 4 GiB cap with overflow protection.
        const end_widened = @addWithOverflow(aligned, size);
        if (end_widened[1] != 0 or end_widened[0] > max_size) {
            return Error.OutOfHeap;
        }
        const end = end_widened[0];
        if (end > self.bytes.len) try self.growTo(end);
        const ref: GcRef = aligned;
        self.cursor = end;
        return ref;
    }

    fn growTo(self: *Heap, min_bytes: u32) Error!void {
        // Round up to next page_size boundary.
        const new_len_u32 = std.mem.alignForward(u32, min_bytes, page_size);
        const new_len: usize = @intCast(new_len_u32);
        const new_bytes = if (self.bytes.len == 0)
            self.parent.alloc(u8, new_len) catch return Error.OutOfHeap
        else
            self.parent.realloc(self.bytes, new_len) catch return Error.OutOfHeap;
        // Zero the newly-grown tail so freshly-allocated objects
        // see a clean slate (matches Wasm GC spec init-to-default).
        @memset(new_bytes[self.bytes.len..], 0);
        self.bytes = new_bytes;
    }

    /// True once allocation pressure has reached the armed watermark
    /// (§15.1 chunk 1c / ADR-0146). The interp alloc handlers consult
    /// this before allocating and drive a collection via
    /// `object_alloc.maybeCollect` when it fires.
    pub fn shouldCollect(self: *const Heap) bool {
        return self.cursor >= self.next_gc_at;
    }

    /// Record that a collection just ran: re-arm the watermark
    /// `pressure_bytes` above the current cursor and count the cycle.
    /// Saturates the watermark at `max_size` so it can never wrap.
    pub fn noteCollected(self: *Heap) void {
        const armed = @addWithOverflow(self.cursor, self.pressure_bytes);
        self.next_gc_at = if (armed[1] != 0) max_size else armed[0];
        self.gc_cycles +%= 1;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Heap.bytes stays at the offset JIT code reads the slab from" {
    // The JIT emits `@offsetOf(Heap, "bytes")` into GC loads and stores, and a
    // `.cwasm` keeps that code (#665): moving the field breaks an artifact
    // another build produced. 16 = after `parent`, as in v2.12.1.
    try testing.expectEqual(@as(usize, 16), @offsetOf(Heap, "bytes"));
}

test "Heap.init: empty slab, cursor at 2 (offset 0+1 reserved)" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    try testing.expectEqual(@as(usize, 0), h.bytes.len);
    try testing.expectEqual(@as(u32, 2), h.cursor);
}

test "Heap.allocate: first allocation lands at offset 2 (post-sentinel)" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    const ref = try h.allocate(16);
    try testing.expectEqual(@as(GcRef, 2), ref);
    try testing.expect(h.bytes.len >= 2 + 16);
}

test "Heap.allocate: cursor advances; never returns null_ref" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    const r0 = try h.allocate(8);
    const r1 = try h.allocate(8);
    try testing.expect(r0 != null_ref);
    try testing.expect(r1 != null_ref);
    try testing.expect(r1 > r0);
}

test "Heap.allocate: 2-byte alignment preserves i31 low bit (ADR-0116)" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    // Allocate an odd-size object — next ref must be even-aligned.
    _ = try h.allocate(1);
    const r1 = try h.allocate(4);
    try testing.expectEqual(@as(u32, 0), r1 % Heap.min_align);
}

test "Heap pressure: shouldCollect arms at next_gc_at; noteCollected re-arms + counts (§15.1 chunk 1c)" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    h.pressure_bytes = 64; // shrink so a few small allocs cross it
    h.next_gc_at = 64;

    // Below the watermark → no collection armed.
    _ = try h.allocate(16);
    try testing.expect(!h.shouldCollect());
    try testing.expectEqual(@as(u32, 0), h.gc_cycles);

    // Cross the watermark → armed.
    while (h.cursor < 64) _ = try h.allocate(16);
    try testing.expect(h.shouldCollect());

    // noteCollected re-arms pressure_bytes above the current cursor
    // and counts the cycle; shouldCollect clears until the next cross.
    const cursor_at_collect = h.cursor;
    h.noteCollected();
    try testing.expectEqual(@as(u32, 1), h.gc_cycles);
    try testing.expectEqual(cursor_at_collect + 64, h.next_gc_at);
    try testing.expect(!h.shouldCollect());
}

test "Heap free-list: exact-size reuse only; mismatched size bumps (§15.1 chunk 2)" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    const off = try h.allocate(16); // bump
    const cursor1 = h.cursor;

    // Stage a freed 16-byte slot → a same-size request reuses it in place.
    try h.free_list.append(h.parent, .{ .offset = off, .size = 16 });
    try testing.expectEqual(off, try h.allocate(16));
    try testing.expectEqual(cursor1, h.cursor); // no growth

    // Re-stage; a DIFFERENT size must NOT reuse it (would corrupt) — bump.
    try h.free_list.append(h.parent, .{ .offset = off, .size = 16 });
    const other = try h.allocate(8);
    try testing.expect(other != off);
    try testing.expect(h.cursor > cursor1);
    // The size-16 slot is untouched by the size-8 request.
    try testing.expectEqual(@as(u64, 16), h.reclaimableBytes());
}

test "Heap.allocate: grow in 4 KB pages" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    _ = try h.allocate(1);
    // First grow rounds up to one page (4096 B).
    try testing.expectEqual(@as(usize, Heap.page_size), h.bytes.len);
    // Trigger second-page grow.
    _ = try h.allocate(Heap.page_size);
    try testing.expect(h.bytes.len >= 2 * Heap.page_size);
}

test "Heap.allocate: returns OutOfHeap when size > 4 GiB cap" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    // Past the 4 GiB cap.
    try testing.expectError(Heap.Error.OutOfHeap, h.allocate(Heap.max_size));
}

test "Heap.deinit: explicit free returns bytes to parent" {
    var h = Heap.init(testing.allocator, testing.allocator);
    _ = try h.allocate(8);
    try testing.expect(h.bytes.len > 0);
    h.deinit();
    try testing.expectEqual(@as(usize, 0), h.bytes.len);
    try testing.expectEqual(@as(u32, 2), h.cursor);
}
