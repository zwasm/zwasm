//! Mode A host GC root scope — `withRootScope(rt, ctx, cb)`
//! per ADR-0115 §4 (10.G op_gc cycle 29).
//!
//! Mode A is the default: zwasm owns the GC. The host opens a
//! scope, executes Wasm + any host-side work, and gets a controlled
//! point to trigger collection. During the scope, the collector
//! never runs concurrently with the callback (our `collect()` is
//! explicit, single-threaded, called from within `RootScope.collect`),
//! so the no-race invariant is structurally satisfied.
//!
//! The scope also lets the host register "extra roots" — GcRefs
//! it's currently holding outside the Runtime's operand stack,
//! locals, and globals (e.g., refs returned from a previous
//! invocation and stashed in host memory). These extra roots are
//! marked alongside the Runtime-walked roots when `collect()` fires.
//!
//! ## Usage
//!
//! ```zig
//! const scope = try gc.RootScope.init(allocator, rt, collector);
//! defer scope.deinit();
//! try scope.pushRoot(some_extern_held_ref);
//! // ... run Wasm, allocate, etc. ...
//! scope.collect();  // marks Runtime + extra_roots, then sweeps
//! ```
//!
//! Mode B (host-provided RootProvider vtable) is opt-in and
//! defers to a separate ~50-LOC follow-up per ADR-0115 §4.
//!
//! Zone 1 (`src/feature/gc/`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const heap_mod = @import("heap.zig");
const iface = @import("collector_iface.zig");
const runtime_mod = @import("../../runtime/runtime.zig");

const GcRef = heap_mod.GcRef;
const Collector = iface.Collector;

pub const RootScope = struct {
    allocator: Allocator,
    rt: *runtime_mod.Runtime,
    collector: Collector,
    extra_roots: std.ArrayList(GcRef) = .empty,

    pub fn init(allocator: Allocator, rt: *runtime_mod.Runtime, collector: Collector) RootScope {
        return .{
            .allocator = allocator,
            .rt = rt,
            .collector = collector,
        };
    }

    pub fn deinit(self: *RootScope) void {
        self.extra_roots.deinit(self.allocator);
    }

    /// Register a host-held GcRef as a root for the next
    /// `collect()` call. Caller MUST own the ref's lifetime
    /// beyond the scope; otherwise the object will be marked
    /// live but the ref may be a use-after-free at runtime.
    pub fn pushRoot(self: *RootScope, ref: GcRef) !void {
        try self.extra_roots.append(self.allocator, ref);
    }

    /// Trigger a full mark + sweep cycle. Walks Runtime roots
    /// (operand stack + frame locals + globals via the collector's
    /// vtable), marks each extra root, then runs sweep.
    pub fn collect(self: *RootScope) void {
        // Phase 1: walk Runtime roots through the vtable's walker.
        self.collector.walkRoots(markCallback, @ptrCast(self));
        // Phase 2: mark host-registered extra roots.
        for (self.extra_roots.items) |ref| {
            markCallback(@ptrCast(self), ref);
        }
        // Phase 3: sweep.
        self.collector.collect();
    }
};

/// Drive a GC collection iff the heap has crossed its pressure
/// watermark (§15.1 chunk 1c / ADR-0146). `MarkSweepCollector` keeps
/// no state across collections, so it is built here for one collection
/// and `deinit`ed after it rather than stored on the Runtime — no
/// persistent collector field, no import cycle. The conservative
/// native-stack scan is
/// ENABLED (`scan_native_stack`): a JIT frame may hold the only
/// reference to an object the interp is mid-constructing, invisible
/// to the operand-stack walk. No reclamation yet (ADR-0135 interim),
/// so a mis-fire here cannot UAF — the only effect is `gc_cycles` +
/// sweep stats advancing. The transient scope's extra-roots list
/// stays empty on this path (interp roots only), so a zero-size
/// `FixedBufferAllocator` backs it — it is never actually allocated
/// from, which keeps the alloc handlers from needing an allocator.
pub fn maybeCollect(
    heap: *heap_mod.Heap,
    gti: *const type_info_mod.GcTypeInfos,
    rt: *runtime_mod.Runtime,
) void {
    if (!heap.shouldCollect()) return;
    var coll = ms_mod.MarkSweepCollector.init(heap, gti);
    defer coll.deinit();
    coll.bindRuntime(rt);
    coll.scan_native_stack = true;
    var empty_buf: [0]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&empty_buf);
    var scope = RootScope.init(fba.allocator(), rt, coll.collector());
    defer scope.deinit();
    scope.collect();
    heap.noteCollected();
}

/// Wasm spec §4.5 (GC reclamation) — JIT-path heap-pressure collect
/// (ADR-0160 / D-258). Unlike `maybeCollect`, NO `*Runtime` is bound:
/// GC-on-JIT runs pure-JIT (no interp↔JIT bridging; ADR-0128 §22), so a
/// precise Runtime-buffer root walk would be empty. Every live GcRef is
/// instead on the native stack at the trampoline CALL (caller-saved
/// spilled pre-call; callee-saved saved in the `callconv(.c)` trampoline
/// frame), so the conservative scan finds them all. Drives the collector
/// directly (RootScope's value-add — rt + extra-roots — is absent here).
/// Correctness of the conservative-only model is pinned by D-261.
pub fn maybeCollectJit(
    heap: *heap_mod.Heap,
    gti: *const type_info_mod.GcTypeInfos,
) void {
    if (!heap.shouldCollect()) return;
    var coll = ms_mod.MarkSweepCollector.init(heap, gti);
    defer coll.deinit();
    coll.scan_native_stack = true; // conservative-only; no bindRuntime (ADR-0160)
    const c = coll.collector();
    c.walkRoots(markCallbackJit, @ptrCast(&coll));
    c.collect();
    heap.noteCollected();
}

/// Mark callback for the JIT collect path: the ctx IS the
/// `*MarkSweepCollector` (no RootScope indirection).
fn markCallbackJit(ctx: *anyopaque, ref: GcRef) void {
    const ms: *ms_for_callback.MarkSweepCollector = @ptrCast(@alignCast(ctx));
    ms.markFromRoot(ref);
}

/// Mark callback used by walkRoots + extra-root iteration.
/// The ctx is a *RootScope; we forward to the collector's
/// markFromRoot via a downcast to MarkSweepCollector (the
/// only Collector impl that exposes markFromRoot publicly).
const ms_for_callback = @import("collector_mark_sweep.zig");

fn markCallback(ctx: *anyopaque, ref: GcRef) void {
    const scope: *RootScope = @ptrCast(@alignCast(ctx));
    // The Collector vtable's `ctx` is the impl's struct ptr.
    // For MarkSweepCollector this is *MarkSweepCollector.
    const ms: *ms_for_callback.MarkSweepCollector = @ptrCast(@alignCast(scope.collector.ctx));
    ms.markFromRoot(ref);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const sections = @import("../../parse/sections.zig");
const type_info_mod = @import("type_info.zig");
const ms_mod = @import("collector_mark_sweep.zig");

fn buildEnv(arena: *std.heap.ArenaAllocator, body: []const u8) !struct {
    rt: *runtime_mod.Runtime,
    heap: *heap_mod.Heap,
    gti: type_info_mod.GcTypeInfos,
} {
    const a = arena.allocator();
    var types = try sections.decodeTypes(testing.allocator, body);
    defer types.deinit();
    const gti = try type_info_mod.materialiseGcTypes(a, types);
    const heap = try a.create(heap_mod.Heap);
    heap.* = heap_mod.Heap.init(a, testing.allocator);
    const rt = try a.create(runtime_mod.Runtime);
    rt.* = runtime_mod.Runtime.init(a);
    return .{ .rt = rt, .heap = heap, .gti = gti };
}

test "RootScope.collect: Runtime operand-stack root keeps object alive (10.G op_gc cycle 29)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildEnv(&arena, &body);

    // Allocate an object; push its ref on operand stack.
    const header_size: u32 = @sizeOf(type_info_mod.ObjectHeader);
    const ref = try env.heap.allocate(header_size + 8);
    const hdr: type_info_mod.ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[ref .. ref + header_size], std.mem.asBytes(&hdr)[0..header_size]);
    try env.rt.pushOperand(.{ .ref = @as(u64, ref) });

    var ms = ms_mod.MarkSweepCollector.init(env.heap, &env.gti);
    ms.bindRuntime(@ptrCast(env.rt));
    var scope = RootScope.init(testing.allocator, env.rt, ms.collector());
    defer scope.deinit();

    scope.collect();
    try testing.expectEqual(@as(u32, 1), ms.last_stats.survivors);
    try testing.expectEqual(@as(u32, 0), ms.last_stats.dead_bytes);
}

test "RootScope.pushRoot: host-held ref kept alive even when no Runtime slot holds it (10.G op_gc cycle 29)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildEnv(&arena, &body);

    const header_size: u32 = @sizeOf(type_info_mod.ObjectHeader);
    const ref = try env.heap.allocate(header_size + 8);
    const hdr: type_info_mod.ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[ref .. ref + header_size], std.mem.asBytes(&hdr)[0..header_size]);
    // Note: NOT pushed onto operand stack — Runtime has no reference.

    var ms = ms_mod.MarkSweepCollector.init(env.heap, &env.gti);
    ms.bindRuntime(@ptrCast(env.rt));
    var scope = RootScope.init(testing.allocator, env.rt, ms.collector());
    defer scope.deinit();

    // First collect without registering → object is dead.
    scope.collect();
    try testing.expectEqual(@as(u32, 0), ms.last_stats.survivors);

    // Register as extra root, collect again → object survives.
    try scope.pushRoot(ref);
    scope.collect();
    try testing.expectEqual(@as(u32, 1), ms.last_stats.survivors);
}

test "RootScope.collect: no roots → all objects dead (10.G op_gc cycle 29)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildEnv(&arena, &body);

    const header_size: u32 = @sizeOf(type_info_mod.ObjectHeader);
    const ref = try env.heap.allocate(header_size + 8);
    const hdr: type_info_mod.ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[ref .. ref + header_size], std.mem.asBytes(&hdr)[0..header_size]);

    var ms = ms_mod.MarkSweepCollector.init(env.heap, &env.gti);
    ms.bindRuntime(@ptrCast(env.rt));
    var scope = RootScope.init(testing.allocator, env.rt, ms.collector());
    defer scope.deinit();

    scope.collect();
    try testing.expectEqual(@as(u32, 1), ms.last_stats.objects_seen);
    try testing.expectEqual(@as(u32, 0), ms.last_stats.survivors);
    try testing.expectEqual(header_size + 8, ms.last_stats.dead_bytes);
}

test "maybeCollect: fires a collection only under heap pressure; counts the cycle (§15.1 chunk 1c)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildEnv(&arena, &body);
    env.heap.pressure_bytes = 64; // shrink so a few allocs cross it
    env.heap.next_gc_at = 64;

    const header_size: u32 = @sizeOf(type_info_mod.ObjectHeader);
    const ref = try env.heap.allocate(header_size + 8);
    const hdr: type_info_mod.ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[ref .. ref + header_size], std.mem.asBytes(&hdr)[0..header_size]);
    try env.rt.pushOperand(.{ .ref = @as(u64, ref) });

    // Below the watermark → no collection driven.
    maybeCollect(env.heap, &env.gti, env.rt);
    try testing.expectEqual(@as(u32, 0), env.heap.gc_cycles);

    // Cross the watermark → maybeCollect fires exactly once + re-arms
    // the watermark above the current cursor.
    while (env.heap.cursor < 64) _ = try env.heap.allocate(8);
    maybeCollect(env.heap, &env.gti, env.rt);
    try testing.expectEqual(@as(u32, 1), env.heap.gc_cycles);
    try testing.expect(!env.heap.shouldCollect());
}
