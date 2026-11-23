//! Null collector — bump-pointer allocator over `Heap`, no GC.
//!
//! Implements the `Collector` vtable from `collector_iface.zig`
//! per ADR-0115 §3 / §10. `allocObjectFn` delegates to
//! `Heap.allocate`; `collectFn` / `walkRootsFn` are no-ops.
//!
//! Purpose: exercise the alloc + ref-touch paths without the
//! collect complexity. `collector_mark_sweep.zig` (β must-ship
//! per ADR-0115 §10) reuses the same vtable shape in subsequent
//! bundle cycles.
//!
//! Selection is programmatic (construct the impl directly);
//! the once-planned `-Dgc-collector` build option was never
//! introduced (cf. ADR-0115 revision note).
//!
//! Zone 1 (`src/feature/gc/`).

const heap_mod = @import("heap.zig");
const iface = @import("collector_iface.zig");

const Heap = heap_mod.Heap;
const GcRef = heap_mod.GcRef;
const Collector = iface.Collector;
const RootCallback = iface.RootCallback;

/// `NullCollector` carries only the backing `*Heap`. The struct
/// itself is the vtable's `ctx`; vtable methods downcast and
/// delegate.
pub const NullCollector = struct {
    heap: *Heap,

    pub fn init(heap: *Heap) NullCollector {
        return .{ .heap = heap };
    }

    /// Return a Collector vtable bound to this instance. Caller
    /// holds `*NullCollector` past the vtable's lifetime — the
    /// vtable carries `*anyopaque` back to this struct.
    pub fn collector(self: *NullCollector) Collector {
        return .{
            .allocObjectFn = allocObject,
            .collectFn = collect,
            .walkRootsFn = walkRoots,
            .ctx = @ptrCast(self),
        };
    }

    fn allocObject(ctx: *anyopaque, size: u32) ?GcRef {
        const self: *NullCollector = @ptrCast(@alignCast(ctx));
        return self.heap.allocate(size) catch null;
    }

    fn collect(_: *anyopaque) void {
        // No-op per ADR-0115 §10. NullCollector relies on the
        // backing Heap's bump-pointer alloc; collection is
        // mark_sweep's responsibility.
    }

    fn walkRoots(_: *anyopaque, _: RootCallback, _: *anyopaque) void {
        // No-op per ADR-0115 §10. Production collectors walk per
        // ADR-0116 (operand stack / frame locals / globals).
    }
};

// ============================================================
// Tests
// ============================================================

const std = @import("std");
const testing = std.testing;

test "NullCollector.allocObject: delegates to Heap.allocate (10.G-foundation cycle 4)" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    var nc = NullCollector.init(&h);
    const c = nc.collector();
    const ref = c.allocObject(16).?;
    try testing.expect(ref != 0); // non-null per heap.null_ref
    try testing.expect(ref >= 2); // post-sentinel offset
}

test "NullCollector.allocObject: cursor advances across calls" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    var nc = NullCollector.init(&h);
    const c = nc.collector();
    const r0 = c.allocObject(8).?;
    const r1 = c.allocObject(8).?;
    try testing.expect(r1 > r0);
}

test "NullCollector.allocObject: returns null on OutOfHeap (4 GiB cap)" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    var nc = NullCollector.init(&h);
    const c = nc.collector();
    const r = c.allocObject(Heap.max_size);
    try testing.expectEqual(@as(?GcRef, null), r);
}

test "NullCollector.collect: no-op (safe to call against fresh heap)" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    var nc = NullCollector.init(&h);
    const c = nc.collector();
    // Repeated calls are harmless.
    c.collect();
    c.collect();
    // Heap state unchanged by collect.
    try testing.expectEqual(@as(u32, 2), h.cursor);
}

test "NullCollector.walkRoots: no-op (callback never invoked)" {
    var h = Heap.init(testing.allocator, testing.allocator);
    defer h.deinit();
    var nc = NullCollector.init(&h);
    const c = nc.collector();

    var call_count: u32 = 0;
    const cb = struct {
        fn cb(ctx: *anyopaque, _: GcRef) void {
            const counter: *u32 = @ptrCast(@alignCast(ctx));
            counter.* += 1;
        }
    }.cb;
    c.walkRoots(cb, @ptrCast(&call_count));
    try testing.expectEqual(@as(u32, 0), call_count);
}

test "NullCollector: vtable shape carries ctx back to impl" {
    // Round-trip check: two collectors backed by different heaps
    // produce different alloc offsets in their own backing.
    var h1 = Heap.init(testing.allocator, testing.allocator);
    defer h1.deinit();
    var h2 = Heap.init(testing.allocator, testing.allocator);
    defer h2.deinit();

    var nc1 = NullCollector.init(&h1);
    var nc2 = NullCollector.init(&h2);
    const c1 = nc1.collector();
    const c2 = nc2.collector();

    _ = c1.allocObject(16);
    _ = c1.allocObject(16);
    _ = c2.allocObject(16);

    // h1 has two allocs (cursor past 2+16+16); h2 has one.
    try testing.expect(h1.cursor > h2.cursor);
}
