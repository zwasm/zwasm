// FILE-SIZE-EXEMPT: single instantiateGraph recursion; 62 private helpers share graph state — N2 on any cut (investigated 2026-08-12, per ADR-0099; re-triage on growth)
//! Multi-component **graph** orchestration (Zone 3; D-305).
//!
//! `instantiateGraph` evaluates a composed component's outer `instance`
//! section in definition order. Each child component is itself a full
//! component (its own `core_instances` index space — a `$libc` core module
//! plus a main module, exactly the shape an aggregate-passing component
//! needs), so the build is TWO-LEVEL: the OUTER loop walks the
//! `component_instances`, and per child an INNER loop walks that child's
//! `core_instances` (mirroring `component_wasi_p2.buildWasiP2Component`'s
//! core-instance loop, but with WASI imports replaced by cross-component
//! ones).
//!
//! A child's component-level imports are satisfied from the outer `with`
//! args, which point at an earlier child's LIFTED export. The child's
//! `canon lower` of such an import becomes a host trampoline that marshals
//! the arguments A-memory → B-memory at the boundary (canon lower → core →
//! lift) and invokes the provider's core func — so a `string` argument is
//! copied into the callee's own linear memory via its `cabi_realloc`, not
//! passed through as a raw (ptr,len) into foreign memory.

const std = @import("std");

const decode = @import("../feature/component/decode.zig");
const canon = @import("../feature/component/canon.zig");
const ctypes = @import("../feature/component/types.zig");
const cvalidate = @import("../feature/component/validate.zig");
const async_mod = @import("../feature/component/async.zig");
const zir = @import("../ir/zir.zig");
const marshal = @import("../zwasm/host_func_marshal.zig");
/// The operand-stack `Value` (extern union) the generic `rawThunk` pops and the
/// boundary trampoline receives — distinct from the public tagged `zwasm.Value`
/// (`Value` below) that `Instance.invoke` takes. The boundary is all-i32, so the
/// bridge between them is a single `.i32` field copy.
const RtValue = @import("../runtime/value.zig").Value;
const zwasm = @import("../zwasm.zig");

const Allocator = std.mem.Allocator;
const Engine = @import("../zwasm/engine.zig").Engine;
const Module = @import("../zwasm/module.zig").Module;
const Instance = @import("../zwasm/instance.zig").Instance;
const linker_mod = @import("../zwasm/linker.zig");
const Linker = linker_mod.Linker;
const Caller = @import("../zwasm/caller.zig").Caller;
const Memory = @import("../zwasm/memory.zig").Memory;
const Value = zwasm.Value;
const InstantiateOpts = Module.InstantiateOpts;

pub const GraphError = error{
    /// A child component embeds no core module to instantiate.
    NoCoreModule,
    /// An outer `with` arg / core import did not resolve to a built export.
    ImportUnsatisfied,
    /// The exported entry point did not resolve to a child's lifted func.
    ExportNotResolved,
    /// A cross-component boundary uses an arg/result shape the marshaller
    /// does not implement yet (typed deferral, not a silent mis-marshal).
    UnsupportedBoundaryType,
    OutOfMemory,
} || decode.Error || ctypes.Error || Module.InstantiateError || Engine.CompileError || linker_mod.LinkError || async_mod.Error;

/// One instantiated child component: its built core instances plus the
/// memory/realloc instances the canon boundary marshals through, and a
/// resolver from a component-export NAME to the lifted core func.
const GraphChild = struct {
    alloc: Allocator,
    /// Position in `graph.children` — the owner id the async handle-isolation
    /// ledger (`GraphAsync.owners`, ADR-0197 / D-463) tags this child's minted
    /// stream/future ends with, so a peer child cannot reach them by index.
    idx: u32 = 0,
    decoded: decode.Component,
    info: ctypes.TypeInfo,
    /// Built core instances in definition order (index = core-instance idx).
    core_instances: std.ArrayList(?*Instance),
    /// The core instance exporting `cabi_realloc` (return-area / string
    /// allocator) and the one exporting linear memory — the canon boundary
    /// the lowers bind to.
    realloc_instance: ?*Instance = null,
    realloc_name: []const u8 = "cabi_realloc",
    mem_instance: ?*Instance = null,

    fn deinit(self: *GraphChild) void {
        self.core_instances.deinit(self.alloc);
        self.info.deinit();
        self.decoded.deinit(self.alloc);
    }

    /// `CanonContext.memory_fn` — re-fetch this child's bound linear memory.
    fn memFetch(p: *anyopaque) []u8 {
        const self: *GraphChild = @ptrCast(@alignCast(p));
        const inst = self.mem_instance orelse return &.{};
        const mem = inst.memory() orelse return &.{};
        return mem.slice();
    }

    /// `CanonContext.realloc_fn` — nested-invoke this child's `cabi_realloc`.
    fn reallocFetch(p: *anyopaque, old_ptr: u32, old_size: u32, alignment: u32, new_size: u32) canon.ReallocError!u32 {
        const self: *GraphChild = @ptrCast(@alignCast(p));
        const inst = self.realloc_instance orelse return canon.ReallocError.AllocFailed;
        var args = [_]Value{
            .{ .i32 = @bitCast(old_ptr) },
            .{ .i32 = @bitCast(old_size) },
            .{ .i32 = @bitCast(alignment) },
            .{ .i32 = @bitCast(new_size) },
        };
        var res = [_]Value{.{ .i32 = 0 }};
        inst.invoke(self.realloc_name, &args, &res) catch return canon.ReallocError.AllocFailed;
        const ptr: u32 = @bitCast(res[0].i32);
        if (ptr == 0 and new_size != 0) return canon.ReallocError.AllocFailed;
        return ptr;
    }

    fn canonContext(self: *GraphChild) canon.CanonContext {
        return .{
            .memory_ctx = @ptrCast(self),
            .memory_fn = memFetch,
            .realloc_ctx = @ptrCast(self),
            .realloc_fn = reallocFetch,
        };
    }
};

/// Heap-stable context for one cross-component host trampoline: the callee
/// child it marshals into + the callee's lifted core func to invoke, and the
/// imported func's WIT signature driving the per-arg marshalling.
const BoundaryCtx = struct {
    /// The callee child (owns the target memory + realloc the args land in).
    callee: *GraphChild,
    /// The callee's core func the lowered import dispatches to (the lifted
    /// export's underlying core export).
    core_func_name: []const u8,
    /// The callee instance the core func lives on.
    core_inst: *Instance,
    /// Imported func type (drives the per-arg lower: string vs flat scalar).
    func_type: ctypes.FuncType,
    /// For a single `list<primitive>` param: the element byte size (1/2/4/8),
    /// so the boundary copies `count * elem_size` bytes. 0 = not a list param.
    list_elem_size: u32 = 0,
    /// The IMPORTER child (owns the memory + realloc a `string` RESULT is
    /// lowered INTO). Only set for the retptr-result trampoline (`tag() ->
    /// string`); null for the flat-result trampoline.
    importer: ?*GraphChild = null,
    /// D-305(b2): for a flat-record RESULT (`() -> record`) crossing via retptr,
    /// the record's in-memory byte size. The trampoline raw-copies
    /// `result_blob_size` bytes from B's storage pointer to the importer's retptr
    /// (a flat record has no internal pointer → no lift/lower). 0 = not a
    /// record-result boundary.
    result_blob_size: u32 = 0,
    /// D-305(b3): the single param is a record CONTAINING a string/list — it
    /// crosses via a canon liftFlat (from the importer's memory) → lowerFlat (into
    /// the callee's memory) round-trip instead of by-words pass-through. Requires
    /// `importer` set (the lift reads A's memory). false = no pointer-bearing param.
    param_record_marshal: bool = false,
    /// D-305(b4): the RESULT is a record CONTAINING a string/list (internal
    /// pointer), returned via retptr. B's producer returns a pointer to the record
    /// in B's memory; the trampoline `canon.load`s it from B then `canon.store`s it
    /// into A's retptr (lowering the string into A's memory). Requires `importer`.
    result_record_marshal: bool = false,
    /// Set when the imported func is async-lifted (ADR-0195 c-2b): the shared
    /// graph scheduler state the async trampoline enqueues the callee subtask
    /// into. null for a synchronous boundary.
    async_state: ?*GraphAsync = null,
    /// The callee subtask's registry funcidx in `GraphAsync.callbacks` — the id
    /// the async trampoline tags the enqueued `TaskDescriptor` with so the
    /// scheduler re-enters the right callee callback. Only set for an async
    /// boundary.
    async_cb_funcidx: u32 = 0,
};

/// ADR-0195 c-2b — the shared cross-component async scheduler state. Owns the
/// graph's single `TaskTable` and a registry mapping a synthetic task funcidx
/// to the (instance, callback name) the scheduler re-enters. A funcidx here is
/// NOT a core-module funcidx; it is the dense registry index the graph mints so
/// `driveScheduler`'s `invokeTaskCallback(funcidx, …)` dispatches across
/// instances (the single-component runner ignores funcidx — there it is one
/// callback; the graph needs the per-task instance routing).
const GraphAsync = struct {
    alloc: Allocator,
    tasks: async_mod.TaskTable,
    /// funcidx (registry index) → the callback to re-enter for that task.
    callbacks: std.ArrayList(CallbackTarget),
    /// ADR-0195 step (d-a): the task currently executing a guest entry/callback.
    /// Set IMMEDIATELY before each callee invoke so the graph-level `task.return`
    /// host func knows which task's `TaskDescriptor.result` to store into. 0 = no
    /// task executing (the reserved table id is never a live task).
    current_task_id: u32 = 0,
    /// ADR-0195 step (d-b-2): the GRAPH-shared future/stream rendezvous arena +
    /// its handle table. A `future.new` in ANY child mints both ends into THIS
    /// one table over THIS one `shared`, so a future handle passed from child A
    /// to child B (a bare i32) is valid in B's lookup and resolves to the SAME
    /// rendezvous slot A reads — the cross-component handle crossing. (Mirrors
    /// `WasiP2Ctx.{streams,shared}`, but graph-level rather than per-component.)
    shared: async_mod.SharedTable,
    streams: async_mod.StreamFutureTable,
    /// ADR-0195 step (d-c-2): the GRAPH-shared waitable-set table. A child's
    /// `canon waitable-set.new`/`join` mint/extend sets HERE, so a blocked guest
    /// callee (B) joins its parked read-end into a set the graph scheduler polls
    /// via `GraphAsyncCtx.pollSet` (mirrors `WasiP2Ctx.sets`, but graph-level).
    sets: async_mod.WaitableSetTable,
    /// ADR-0195 step (d-c-2): a guest `stream.read` that PARKS (the peer has not
    /// yet written) records its reader-side destination here, keyed by the readable
    /// end handle. When the peer's later `stream.write` resolves the rendezvous, the
    /// deposited bytes are copied into THIS reader's memory at `ptr` (the guest↔guest
    /// analogue of the host-source `deliverParkedReads`). Cleared on delivery.
    pending_graph_reads: std.AutoHashMapUnmanaged(u32, PendingGraphRead) = .empty,
    /// ADR-0197 (D-463): stream/future end handle → owning child idx. The graph keeps
    /// ONE shared `streams`/`shared`/`sets` (the scheduler stays component-agnostic),
    /// and this ledger gives the guest-facing builtins per-component handle isolation:
    /// a child may only access an end it owns; the boundary trampoline retags ownership
    /// on transfer. Handle values are guest-opaque, so this is spec-conformant without
    /// per-child tables (would force child-identity threading through the scheduler).
    owners: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    const CallbackTarget = struct { inst: *Instance, name: []const u8 };
    /// A parked cross-component read: where (which guest memory + offset) the
    /// resolving write must deposit the bytes. `elem_size` is the lowered element
    /// width; `cap` the requested element count (the read's buffer capacity).
    const PendingGraphRead = struct { mem: Memory, ptr: u32, cap: u32, elem_size: u8 };

    fn init(alloc: Allocator) async_mod.Error!GraphAsync {
        return .{
            .alloc = alloc,
            .tasks = try async_mod.TaskTable.init(alloc),
            .callbacks = .empty,
            .shared = async_mod.SharedTable.init(alloc),
            .streams = try async_mod.StreamFutureTable.init(alloc),
            .sets = try async_mod.WaitableSetTable.init(alloc),
        };
    }

    fn deinit(self: *GraphAsync) void {
        self.tasks.deinit();
        self.callbacks.deinit(self.alloc);
        self.shared.deinit();
        self.streams.deinit();
        self.sets.deinit();
        self.pending_graph_reads.deinit(self.alloc);
        self.owners.deinit(self.alloc);
    }

    /// Register a callback target and return its funcidx (the dense registry
    /// index the scheduler dispatches on). Index 0 is a valid registry slot
    /// here (unlike the table's reserved-0 handle): the funcidx is a plain
    /// array index, never a task id.
    fn registerCallback(self: *GraphAsync, inst: *Instance, name: []const u8) async_mod.Error!u32 {
        const idx: u32 = @intCast(self.callbacks.items.len);
        try self.callbacks.append(self.alloc, .{ .inst = inst, .name = name });
        return idx;
    }

    /// The live task id whose callback is registry `funcidx` (ADR-0195 d-a),
    /// or 0 if none — drives `current_task_id` so a callback's `task.return`
    /// stores into the right per-task slot. Each task registers a distinct
    /// callback funcidx, so the match is unique.
    fn taskOfCallback(self: *GraphAsync, funcidx: u32) u32 {
        for (self.tasks.slots.items, 0..) |slot, i| {
            const t = slot orelse continue;
            if (t.callback_funcidx == funcidx) return @intCast(i);
        }
        return 0;
    }
};

/// A linked multi-component graph (D-305). Heap-allocated children +
/// instances keep addresses stable (instances and trampoline contexts
/// reference each other for the lifetime of the graph).
pub const ComponentGraph = struct {
    alloc: Allocator,
    owned_bytes: []const u8,
    outer: decode.Component,
    info: ctypes.TypeInfo,
    children: std.ArrayList(*GraphChild),
    modules: std.ArrayList(*Module),
    linkers: std.ArrayList(*Linker),
    instances: std.ArrayList(*Instance),
    boundaries: std.ArrayList(*BoundaryCtx),
    /// Heap-allocated `canon future.*` host contexts (ADR-0195 d-b-2), one per
    /// wired future builtin; freed at graph deinit (addresses stay stable while
    /// bound to the linker).
    future_ctxs: std.ArrayList(*GraphFutureCtx) = .empty,
    /// Map a child's definition ordinal (in `component_instances`) to the
    /// built `GraphChild` slot — outer `with` args reference children by
    /// instance index.
    child_of_instance: std.ArrayList(?*GraphChild),
    /// The shared cross-component async scheduler state (ADR-0195 c-2b), created
    /// lazily the first time an async boundary is installed; null for a graph
    /// with no async imports.
    async_state: ?*GraphAsync = null,

    pub fn deinit(self: *ComponentGraph) void {
        for (self.instances.items) |inst| {
            inst.deinit();
            self.alloc.destroy(inst);
        }
        for (self.linkers.items) |lk| {
            lk.deinit();
            self.alloc.destroy(lk);
        }
        for (self.modules.items) |m| {
            m.deinit();
            self.alloc.destroy(m);
        }
        for (self.boundaries.items) |b| self.alloc.destroy(b);
        for (self.future_ctxs.items) |f| self.alloc.destroy(f);
        for (self.children.items) |c| {
            c.deinit();
            self.alloc.destroy(c);
        }
        self.instances.deinit(self.alloc);
        self.linkers.deinit(self.alloc);
        self.modules.deinit(self.alloc);
        self.boundaries.deinit(self.alloc);
        self.future_ctxs.deinit(self.alloc);
        self.children.deinit(self.alloc);
        self.child_of_instance.deinit(self.alloc);
        if (self.async_state) |as| {
            as.deinit();
            self.alloc.destroy(as);
        }
        self.info.deinit();
        self.outer.deinit(self.alloc);
        self.alloc.free(self.owned_bytes);
    }

    /// Lazily create + return the shared async scheduler state (ADR-0195 c-2b).
    fn asyncState(self: *ComponentGraph) async_mod.Error!*GraphAsync {
        if (self.async_state) |as| return as;
        const as = try self.alloc.create(GraphAsync);
        errdefer self.alloc.destroy(as);
        as.* = try GraphAsync.init(self.alloc);
        self.async_state = as;
        return as;
    }

    /// Invoke a graph export by name with flat-scalar args/result through the
    /// canonical ABI. Resolves the outer export → the child + that child's
    /// lifted export, then invokes the child's lifted core func directly
    /// (flat-scalar boundary; the string-passing happens internally between
    /// children via the boundary trampolines).
    pub fn invokeFlat(self: *ComponentGraph, name: []const u8, args: []const Value, results: []Value) !void {
        const res = self.resolveExport(name) orelse return GraphError.ExportNotResolved;
        const r = res.child.info.resolveLiftedFunc(res.export_name) orelse return GraphError.ExportNotResolved;
        const inst = res.child.core_instances.items[r.core_func.instance] orelse return GraphError.ExportNotResolved;
        return inst.invoke(r.core_func.name, args, results);
    }

    /// The ctx `driveScheduler` is generic over for the cross-component graph
    /// (ADR-0195 c-2b): dispatch a task's callback by its registry funcidx across
    /// the graph's instances. `pollSet` (ADR-0195 d-c-2) delivers a cross-component
    /// stream/future event that a peer's write already deposited into a joined end's
    /// `pending_event`; a `.waiting` task with no such event returns null, so the
    /// scheduler deadlocks loudly via `AsyncDeadlock` (never a silent NONE).
    const GraphAsyncCtx = struct {
        state: *GraphAsync,

        pub fn invokeTaskCallback(self: *GraphAsyncCtx, funcidx: u32, event_code: u32, p1: u32, p2: u32) !u32 {
            if (funcidx >= self.state.callbacks.items.len) return GraphError.ExportNotResolved;
            const target = self.state.callbacks.items[funcidx];
            var args = [_]Value{
                .{ .i32 = @bitCast(event_code) },
                .{ .i32 = @bitCast(p1) },
                .{ .i32 = @bitCast(p2) },
            };
            var res = [_]Value{.{ .i32 = 0 }};
            // ADR-0195 d-a: mark the task whose callback this is as current so a
            // task.return from inside the callback lands in its own result slot.
            const prev = self.state.current_task_id;
            self.state.current_task_id = self.state.taskOfCallback(funcidx);
            defer self.state.current_task_id = prev;
            try target.inst.invoke(target.name, &args, &res);
            return @bitCast(res[0].i32);
        }

        /// ADR-0195 step (d-c-2): deliver a pending cross-component event for a
        /// `.waiting` task's waitable set. The peer's `stream.write` already
        /// resolved the parked read (copying bytes into the reader's memory + setting
        /// its read-end `pending_event` via `end.copy`'s notify), so this just polls
        /// the set's members. No host-source `deliverParkedReads` step is needed —
        /// the producer is the peer guest, not a host fd. Returns null when nothing
        /// is pending, letting `driveScheduler` trap `AsyncDeadlock` for an
        /// unresolvable WAIT (the adversarial no-peer-write case).
        pub fn pollSet(self: *GraphAsyncCtx, set_index: u32) !?async_mod.EventTuple {
            const set = try self.state.sets.get(set_index);
            return try set.poll(&self.state.streams);
        }

        /// No-progress seam (ADR-0205 D2): the graph boundary wires no host
        /// timers today (guest↔guest only), so a stalled pass is a genuine
        /// deadlock — nothing to sleep for.
        pub fn waitForTimer(self: *GraphAsyncCtx) !bool {
            _ = self;
            return false;
        }
    };

    /// Drive the graph's main async export (`name`) to completion through the
    /// stackless callback scheduler (ADR-0195 c-2b). Seeds task 0 = the named
    /// async export, then runs `driveScheduler` over the graph's shared
    /// `TaskTable`: a cross-component async import (component A's `canon lower …
    /// async` of B's async `tick`) enqueues B's subtask into the SAME table at
    /// boundary-call time, so the scheduler drives BOTH guests to completion.
    /// Traps `AsyncDeadlock` (not a silent NONE) if a task blocks with no
    /// deliverable event.
    pub fn driveAsyncMain(self: *ComponentGraph, name: []const u8) !void {
        const res = self.resolveExport(name) orelse return GraphError.ExportNotResolved;
        const r = res.child.info.resolveLiftedFunc(res.export_name) orelse return GraphError.ExportNotResolved;
        if (!r.is_async) return GraphError.UnsupportedBoundaryType; // not an async export
        const cb = r.callback orelse return GraphError.UnsupportedBoundaryType; // async lift implies a callback
        const inst = res.child.core_instances.items[r.core_func.instance] orelse return GraphError.ExportNotResolved;
        const cb_inst = res.child.core_instances.items[cb.instance] orelse return GraphError.ExportNotResolved;

        const as = try self.asyncState();

        // Reserve task 0's id BEFORE invoking the main entry, so a `task.return`
        // from inside it (a result-bearing async export) lands in this task's slot
        // (ADR-0195 d-a). The placeholder is folded to its real state afterward.
        const main_funcidx = try as.registerCallback(cb_inst, cb.name);
        const main_id = try as.tasks.add(.{ .callback_funcidx = main_funcidx });
        as.current_task_id = main_id;

        // Invoke the async task entry once; its packed i32 return seeds the task.
        var results = [_]Value{.{ .i32 = 0 }};
        try inst.invoke(r.core_func.name, &.{}, &results);
        const initial: u32 = @bitCast(results[0].i32);
        as.current_task_id = 0;

        const seed = try async_mod.seedTask(initial);
        const main_task = try as.tasks.get(main_id);
        main_task.state = seed.state;
        main_task.set_index = seed.set_index;

        var ctx = GraphAsyncCtx{ .state = as };
        try async_mod.driveScheduler(&ctx, &as.tasks);
    }

    /// Count the (live, non-tombstone) tasks the async scheduler has driven and
    /// how many reached `.done` — the test seam proving BOTH the caller (A's
    /// `run`) and the enqueued callee (B's `tick`) completed (ADR-0195 c-2b).
    pub fn asyncTaskCounts(self: *ComponentGraph) struct { total: usize, done: usize } {
        const as = self.async_state orelse return .{ .total = 0, .done = 0 };
        var total: usize = 0;
        var done: usize = 0;
        for (as.tasks.slots.items) |slot| {
            const t = slot orelse continue;
            total += 1;
            if (t.state == .done) done += 1;
        }
        return .{ .total = total, .done = done };
    }

    /// ADR-0195 step (d-a) — the value task `id` delivered via `canon task.return`
    /// (the cross-component async DATA channel), or null if the task never returned
    /// a value (or `id` is not a live task). The test seam proving a callee's
    /// `task.return(value)` was captured graph-side into its per-task slot.
    pub fn taskResult(self: *ComponentGraph, id: u32) ?u32 {
        const as = self.async_state orelse return null;
        const task = as.tasks.get(id) catch return null;
        return task.result;
    }

    const ExportResolution = struct { child: *GraphChild, export_name: []const u8 };

    /// Resolve an outer export NAME to (child, child-export-name): the outer
    /// `export` aliases a component func that aliases a local child instance's
    /// export.
    fn resolveExport(self: *ComponentGraph, name: []const u8) ?ExportResolution {
        for (self.info.exports.items) |e| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            if (std.meta.activeTag(e.sort) != .func) return null;
            // e.index is a component-func index; chase its alias to a local
            // component-instance export.
            const cf = if (e.index < self.info.component_funcs.items.len)
                self.info.component_funcs.items[e.index]
            else
                return null;
            const ce = switch (cf) {
                .alias => |t| switch (t) {
                    .component_export => |c| c,
                    else => return null,
                },
                else => return null,
            };
            const child = self.childOfInstanceIndex(ce.instance) orelse return null;
            return .{ .child = child, .export_name = ce.name };
        }
        return null;
    }

    /// The `GraphChild` an outer component-instance index resolves to (a
    /// LOCAL `.instantiate`); null for imports / synthetics / out of range.
    fn childOfInstanceIndex(self: *ComponentGraph, instance_index: u32) ?*GraphChild {
        const d = self.info.localInstanceOrdinal(instance_index) orelse return null;
        if (d >= self.child_of_instance.items.len) return null;
        return self.child_of_instance.items[d];
    }
};

/// Instantiate + link a multi-component graph (see `ComponentGraph`).
pub fn instantiateGraph(engine: *Engine, alloc: Allocator, bytes: []const u8, opts: InstantiateOpts) GraphError!ComponentGraph {
    const owned_bytes = try alloc.dupe(u8, bytes);
    var graph = ComponentGraph{
        .alloc = alloc,
        .owned_bytes = owned_bytes,
        .outer = decode.decode(alloc, owned_bytes) catch |e| {
            alloc.free(owned_bytes);
            return e;
        },
        .info = undefined,
        .children = .empty,
        .modules = .empty,
        .linkers = .empty,
        .instances = .empty,
        .boundaries = .empty,
        .child_of_instance = .empty,
    };
    errdefer graph.deinit();
    graph.info = try ctypes.decodeTypeInfo(alloc, &graph.outer);
    try cvalidate.validate(&graph.info); // ADR-0176

    for (graph.info.component_instances.items) |ci| {
        const it = switch (ci) {
            .instantiate => |it| it,
            // A synthetic re-export instance instantiates nothing; record an
            // empty slot so child ordinals stay aligned with definition order.
            .inline_exports => {
                try graph.child_of_instance.append(alloc, null);
                continue;
            },
        };
        const child = try buildChild(engine, &graph, it, opts);
        try graph.children.append(alloc, child);
        try graph.child_of_instance.append(alloc, child);
    }
    return graph;
}

/// Build one child component: decode it, then walk its `core_instances`
/// index space in definition order. The child's component-level imports are
/// resolved from the outer `with` args (`it.args`).
fn buildChild(
    engine: *Engine,
    graph: *ComponentGraph,
    it: anytype, // .instantiate payload: { component, args }
    opts: InstantiateOpts,
) GraphError!*GraphChild {
    const alloc = graph.alloc;
    const child_bytes = nthChildComponent(&graph.outer, it.component) orelse return GraphError.NoCoreModule;

    const child = try alloc.create(GraphChild);
    errdefer alloc.destroy(child);
    child.* = .{
        .alloc = alloc,
        // The eventual index in `graph.children` (appended right after buildChild
        // returns, in definition order). Set HERE — not at the append site — because
        // this child's synthetic builtins are installed DURING buildChild and capture
        // `idx` into their `GraphFutureCtx` (ADR-0197 ownership ledger).
        .idx = @intCast(graph.children.items.len),
        .decoded = try decode.decode(alloc, child_bytes),
        .info = undefined,
        .core_instances = .empty,
    };
    errdefer child.deinit();
    child.info = try ctypes.decodeTypeInfo(alloc, &child.decoded);
    try cvalidate.validate(&child.info);

    for (child.info.core_instances.items) |cinst| {
        const built = try buildCoreInstance(engine, graph, child, it, cinst, opts);
        try child.core_instances.append(alloc, built);
        if (built) |gi| {
            if (child.realloc_instance == null and instanceExportsFunc(gi, child.realloc_name))
                child.realloc_instance = gi;
            if (child.mem_instance == null and gi.memory() != null)
                child.mem_instance = gi;
        }
    }
    return child;
}

/// Build one of a child's core instances. A `.instantiate` compiles + links
/// its module (imports satisfied from earlier core instances, synthetic
/// `with` instances, or — via a boundary trampoline — a cross-component
/// lowered import). An `.inline_exports` instance is synthetic: it has no
/// `*Instance`, so it returns null and is bound lazily when an importer names
/// it (handled in `pourCoreInstanceArg`).
fn buildCoreInstance(
    engine: *Engine,
    graph: *ComponentGraph,
    child: *GraphChild,
    outer_it: anytype,
    cinst: ctypes.CoreInstance,
    opts: InstantiateOpts,
) GraphError!?*Instance {
    const alloc = graph.alloc;
    switch (cinst) {
        .inline_exports => return null,
        .instantiate => |inst_def| {
            const core_bytes = nthCoreModule(&child.decoded, inst_def.module) orelse return GraphError.NoCoreModule;
            // D-466: NO function-scope `errdefer destroy(module)` — once appended
            // to graph.modules, graph.deinit (the instantiateGraph errdefer) owns
            // module's deinit+destroy; a surviving errdefer double-frees when a
            // LATER step in this fn (linker / pour / instance build) fails, e.g. an
            // unsupported boundary downstream. Clean up explicitly for the only
            // pre-append fallible step (compile); an OOM-append leak is tolerated.
            const module = try alloc.create(Module);
            module.* = engine.compile(core_bytes) catch |e| {
                alloc.destroy(module);
                return e;
            };
            try graph.modules.append(alloc, module);

            const lk = try alloc.create(Linker);
            lk.* = engine.linker();
            try graph.linkers.append(alloc, lk);

            // Pour each `with` arg's prior core instance into the linker under
            // its namespace, satisfying this module's imports.
            for (inst_def.args) |arg| {
                try pourCoreInstanceArg(graph, child, outer_it, lk, arg);
            }

            const gi = try alloc.create(Instance);
            errdefer alloc.destroy(gi);
            gi.* = try lk.instantiate(module, opts);
            try graph.instances.append(alloc, gi);
            return gi;
        },
    }
}

/// Pour one core-instance `with` arg (`name` ← core instance `arg.instance`)
/// into the linker. The referenced instance is either a real guest instance
/// (alias all its exports) OR a synthetic `.inline_exports` instance, whose
/// func exports may be lowered cross-component imports — those bind to a
/// boundary trampoline.
fn pourCoreInstanceArg(
    graph: *ComponentGraph,
    child: *GraphChild,
    outer_it: anytype,
    lk: *Linker,
    arg: ctypes.CoreInstantiateArg,
) GraphError!void {
    const cinsts = child.info.core_instances.items;
    if (arg.instance >= cinsts.len) return GraphError.ImportUnsatisfied;
    switch (cinsts[arg.instance]) {
        .instantiate => {
            const provider = child.core_instances.items[arg.instance] orelse return GraphError.ImportUnsatisfied;
            try lk.defineInstance(arg.name, provider);
        },
        .inline_exports => |exps| {
            for (exps) |ex| try pourSyntheticExport(graph, child, outer_it, lk, arg.name, ex);
        },
    }
}

/// Bind one synthetic inline-export into the linker under `ns`. A `.func`
/// export that is a `canon lower` of a component import resolves (via the
/// outer `with` args) to a provider child's lifted func; we install a host
/// trampoline that marshals across the boundary.
fn pourSyntheticExport(
    graph: *ComponentGraph,
    child: *GraphChild,
    outer_it: anytype,
    lk: *Linker,
    ns: []const u8,
    ex: ctypes.CoreInlineExport,
) GraphError!void {
    if (ex.sort != .func) return GraphError.UnsupportedBoundaryType;
    const cf = child.info.coreFunc(ex.index) orelse return GraphError.ImportUnsatisfied;
    const import_name = switch (cf) {
        .lower => |l| importNameOfLoweredFunc(&child.info, l.func) orelse return GraphError.ImportUnsatisfied,
        // A child's own `canon task.return` (ADR-0195 d-a): wire the graph-level
        // host func that captures the value into the currently-executing task.
        // Only the minimal single-`u32` result is implemented; a multi-value /
        // typed task.return is a typed deferral (UnsupportedBoundaryType), never
        // a silent partial capture.
        .task_return => |tr| {
            if (tr.result == null or !isFlat4Scalar(tr.result.?)) return GraphError.UnsupportedBoundaryType;
            const as = try graph.asyncState();
            try lk.defineFuncCtx(ns, ex.name, @ptrCast(as), TaskReturnSig, graphTaskReturn);
            return;
        },
        // A child's own `canon {future,stream}.*` builtin (ADR-0195 d-b-2 /
        // d-c-1): wire the graph-level host func backed by the GRAPH-shared
        // rendezvous, so an end minted in one child is resolvable by the peer
        // child. Future (single-shot value) + synchronous multi-element stream
        // ops are wired; cancel ops are a typed deferral (d-c-2) — fail loudly.
        .stream_future => |sf| {
            try installGraphFutureBuiltin(graph, child, lk, ns, ex.name, sf.op, sf.type_index);
            return;
        },
        // A child's own `canon waitable-set.new` / `waitable.join` (ADR-0195 d-c-2):
        // wire the graph-level host func backed by the GRAPH-shared `sets` table, so a
        // blocked guest callee can build a set + join its parked read-end and the graph
        // scheduler's `pollSet` finds it. `wait`/`poll`/`drop` are typed deferrals
        // (the scheduler delivers WAIT via the callback ABI, not a guest `wait` call).
        .waitable_set => |ws| {
            const as = try graph.asyncState();
            // Per-child ctx so `waitable.join` can owner-check the joined end (ADR-0197).
            // `elem_size` is unused here. Ownership → future_ctxs (freed at graph deinit).
            const wctx = try graph.alloc.create(GraphFutureCtx);
            wctx.* = .{ .as = as, .elem_size = 0, .child_idx = child.idx };
            try graph.future_ctxs.append(graph.alloc, wctx);
            switch (ws.op) {
                .new => try lk.defineFuncCtx(ns, ex.name, @ptrCast(wctx), fn (*Caller) BoundaryError!u32, graphWaitableSetNew),
                .join => try lk.defineFuncCtx(ns, ex.name, @ptrCast(wctx), fn (*Caller, u32, u32) BoundaryError!void, graphWaitableJoin),
                .wait, .poll, .drop => return GraphError.UnsupportedBoundaryType,
            }
            return;
        },
        else => return GraphError.UnsupportedBoundaryType,
    };
    // The outer `with` arg whose name matches this import names the provider
    // child + that child's exported func.
    const provider = resolveProvider(graph, outer_it, import_name) orelse return GraphError.ImportUnsatisfied;
    try installBoundaryTrampoline(graph, lk, ns, ex.name, import_name, child, provider);
}

const Provider = struct { child: *GraphChild, export_name: []const u8 };

/// Resolve a child's component-import NAME to the provider (child + exported
/// func) via the outer `with` args: each arg satisfies an import name with a
/// `func` from a local child instance's exports.
fn resolveProvider(graph: *ComponentGraph, outer_it: anytype, import_name: []const u8) ?Provider {
    for (outer_it.args) |a| {
        if (!std.mem.eql(u8, a.name, import_name)) continue;
        if (std.meta.activeTag(a.sort) != .func) return null;
        // a.index is a component-func index in the OUTER component: a func
        // alias of a child instance export.
        const cf = if (a.index < graph.info.component_funcs.items.len)
            graph.info.component_funcs.items[a.index]
        else
            return null;
        const ce = switch (cf) {
            .alias => |t| switch (t) {
                .component_export => |c| c,
                else => return null,
            },
            else => return null,
        };
        const pc = graph.childOfInstanceIndex(ce.instance) orelse return null;
        return .{ .child = pc, .export_name = ce.name };
    }
    return null;
}

/// Install a host trampoline that, when the importer core module calls the
/// lowered import with flat args, marshals them into the provider child and
/// invokes the provider's lifted core func — copying `string` args into the
/// callee's own memory via its realloc (canon lower → core → lift).
fn installBoundaryTrampoline(
    graph: *ComponentGraph,
    lk: *Linker,
    ns: []const u8,
    core_export_name: []const u8,
    import_name: []const u8,
    importer: *GraphChild,
    provider: Provider,
) GraphError!void {
    const r = provider.child.info.resolveLiftedFunc(provider.export_name) orelse return GraphError.ImportUnsatisfied;
    const ft = provider.child.info.resolveFuncType(provider.export_name) orelse return GraphError.ImportUnsatisfied;
    const core_inst = provider.child.core_instances.items[r.core_func.instance] orelse return GraphError.ImportUnsatisfied;
    if (r.string_encoding != .utf8) return GraphError.UnsupportedBoundaryType;
    if (r.realloc) |rr| provider.child.realloc_name = rr.name;
    _ = import_name;

    // ADR-0195 c-2b — the imported func is async-lifted: route through the
    // async boundary trampoline (mint a subtask for the callee + enqueue it into
    // the shared scheduler `TaskTable`), not the synchronous marshal-and-call.
    if (r.is_async) {
        return installAsyncBoundary(graph, lk, ns, core_export_name, ft, r, core_inst, importer, provider);
    }

    // A `string` RESULT flattens to >1 core value, so per the Canonical ABI it
    // returns via a RETPTR: the lowered import's core signature is `(retptr) ->
    // ()`, NOT the fixed `(i32,i32) -> i32`. Detect it and install the dedicated
    // retptr-result trampoline (no value params; the result string is lifted
    // from B and lowered into A's memory).
    if (resultIsString(graph.alloc, &provider.child.info, ft)) {
        // Two retptr-result shapes are implemented:
        //   `() -> string`         → core `(retptr) -> ()`
        //   `(string) -> string`   → core `(param_ptr, param_len, retptr) -> ()`
        // Any other param list alongside a string result is a broader shape
        // (typed deferral — no silent mis-marshal).
        const param_is_string = ft.params.len == 1 and isString(ft.params[0].ty);
        if (ft.params.len != 0 and !param_is_string) return GraphError.UnsupportedBoundaryType;
        const bctx = try graph.alloc.create(BoundaryCtx);
        // D-466: no local errdefer — graph.deinit (the instantiateGraph errdefer) owns
        // bctx once appended below; a surviving errdefer double-frees on a later
        // defineFuncCtx failure (an OOM-append leak of one struct is tolerated, as elsewhere).
        bctx.* = .{
            .callee = provider.child,
            .core_func_name = r.core_func.name,
            .core_inst = core_inst,
            .func_type = ft,
            .importer = importer,
        };
        try graph.boundaries.append(graph.alloc, bctx);
        if (param_is_string) {
            try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), StrRetStrSig, strRetStrTrampoline);
        } else {
            try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), RetPtrSig, retPtrTrampoline);
        }
        return;
    }

    // D-305(b2): a flat-record RESULT (`() -> record`, e.g. `point{x,y:u32}`)
    // flattens to >1 core value, so per the Canonical ABI it returns via a RETPTR:
    // A allocates the return area in its own memory and passes the pointer; B's
    // core func writes the record blob into B's memory; the trampoline raw-copies
    // the fixed-size bytes B→A (a flat record has no internal pointer, so no
    // lift/lower relocation — unlike the string-result path above). Only the
    // no-value-param shape is implemented; flat params alongside a record result
    // are a broader shape (typed deferral).
    if (resultFlatRecordBlob(graph.alloc, &provider.child.info, ft)) |blob| {
        if (ft.params.len != 0) return GraphError.UnsupportedBoundaryType;
        const bctx = try graph.alloc.create(BoundaryCtx);
        bctx.* = .{
            .callee = provider.child,
            .core_func_name = r.core_func.name,
            .core_inst = core_inst,
            .func_type = ft,
            .importer = importer,
            .result_blob_size = blob.size,
        };
        try graph.boundaries.append(graph.alloc, bctx);
        try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), RetPtrSig, recordRetTrampoline);
        return;
    }

    // D-305(b4): a record RESULT CONTAINING a string/list (internal pointer) also
    // returns via retptr, but the raw byte-copy (b2) would carry B-relative
    // pointers into A — wrong. Instead `canon.load` the record from B's memory
    // into a canon Value, then `canon.store` it into A's retptr (lowering the
    // string into A's OWN memory via A's realloc, writing A-relative pointers).
    // Only the no-value-param `() -> record` shape; mixed params deferred.
    if (resultRecordWithPointer(graph.alloc, &provider.child.info, ft)) {
        if (ft.params.len != 0) return GraphError.UnsupportedBoundaryType;
        const bctx = try graph.alloc.create(BoundaryCtx);
        bctx.* = .{
            .callee = provider.child,
            .core_func_name = r.core_func.name,
            .core_inst = core_inst,
            .func_type = ft,
            .importer = importer,
            .result_record_marshal = true,
        };
        try graph.boundaries.append(graph.alloc, bctx);
        try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), RetPtrSig, recordPtrRetTrampoline);
        return;
    }

    // For a single `list<primitive>` param, resolve the element byte size now so
    // the call-time copy moves `count * elem_size` bytes. A `list<u32>` param is a
    // `type_index` into the provider's type space, so resolve via `canon`.
    var list_elem_size: u32 = 0;
    if (ft.params.len == 1) {
        var tmp = std.heap.ArenaAllocator.init(graph.alloc);
        defer tmp.deinit();
        if (canon.canonTypeFromDecoded(tmp.allocator(), &provider.child.info, ft.params[0].ty)) |ct| {
            if (ct == .list and ct.list.* == .prim and isFlatPrim(ct.list.*.prim))
                list_elem_size = @intCast(canon.sizeOf(ct.list.*));
        } else |_| {
            // Type resolution failed → not a flat-primitive list; the shape
            // check below rejects it (string/flat path or typed deferral).
        }
    }

    // D-305(a)+(b): resolve the flattened all-i32 core shape — any flat-scalar
    // arity, a flat record/tuple param (fields flatten to i32 → pass-through), or
    // a single string/list param (2-word memory-marshalled). A wide scalar
    // (i64/f32/f64), a string/list INSIDE a record, or an aggregate RESULT (the
    // retptr path is handled earlier) is a typed deferral (no silent mis-marshal).
    const shape = boundaryFlatShape(graph.alloc, &provider.child.info, ft, list_elem_size > 0);
    if (!shape.ok) return GraphError.UnsupportedBoundaryType;

    const bctx = try graph.alloc.create(BoundaryCtx);
    // D-466: no local errdefer — graph.deinit owns bctx once appended below; a
    // surviving errdefer double-frees on a later defineFuncCtx failure.
    bctx.* = .{
        .callee = provider.child,
        .core_func_name = r.core_func.name,
        .core_inst = core_inst,
        .func_type = ft,
        .list_elem_size = list_elem_size,
        // D-305(b3): a record-with-pointer param round-trips via liftFlat/lowerFlat,
        // which lifts from the IMPORTER's (A's) memory — so it needs `importer`.
        .importer = if (shape.record_marshal) importer else null,
        .param_record_marshal = shape.record_marshal,
    };
    try graph.boundaries.append(graph.alloc, bctx);

    // D-305: ONE Value-slice trampoline marshals the flattened all-i32 core words
    // (any flat-scalar arity / flat record pass-through, plus the 2-word
    // string/list path); the result is a single flat-4 word. `boundaryFlatShape`
    // bounded the word count to `marshal.raw_max_words`.
    const n_words = shape.words;
    try lk.defineFuncRaw(
        ns,
        core_export_name,
        @ptrCast(bctx),
        boundary_core_i32[0..n_words],
        boundary_core_i32[0..1],
        boundaryTrampolineRaw,
    );
}

/// `Subtask.State` codes the async-LOWERED import returns to the caller per the
/// Canonical ABI (`CanonicalABI.md` `Subtask.State`). RETURNED=2 means the
/// callee resolved within the call (a synchronous completion); the minimal c-2b
/// fixture's callee EXITs immediately, so the lowered call returns RETURNED.
const SUBTASK_RETURNED: u32 = @intFromEnum(async_mod.SubtaskState.returned);

/// The async boundary trampoline's flattened core signature for a NO-RESULT
/// async import (`canon lower … async` of `func()`): `() -> i32`, returning the
/// async-call status code. `BoundaryError!u32` so a callee trap propagates.
const AsyncBoundarySig = fn (*Caller) BoundaryError!u32;

/// The async boundary trampoline's core signature for a SINGLE-FLAT-PARAM async
/// import (`canon lower … async` of `func(handle)`): `(handle:i32) -> i32`
/// (ADR-0195 d-b-2). The handle crosses verbatim to the callee entry.
const AsyncBoundaryParamSig = fn (*Caller, u32) BoundaryError!u32;

/// The async boundary trampoline's core signature for a RESULT-BEARING async
/// import (`canon lower … async` of `func() -> u32`): the lowered core func gains
/// a leading `retptr` param naming where the importer would receive the result,
/// `(retptr:i32) -> i32`. The result itself travels via the callee's
/// `task.return` (captured graph-side into the subtask's per-task slot, ADR-0195
/// d-a), so the retptr is currently unused by the boundary (the minimal d-a step
/// captures graph-side; lowering the result back into the importer's retptr is a
/// later slice).
const AsyncBoundaryRetSig = fn (*Caller, u32) BoundaryError!u32;

/// Install the async cross-component boundary (ADR-0195 c-2b / d-a). When the
/// importer calls the async-lowered import, the trampoline invokes the callee's
/// async task entry once, mints a `Subtask` for it, and enqueues a
/// `TaskDescriptor` (callback = the callee's async `callback`) into the shared
/// scheduler table so the graph runner drives the callee to completion alongside
/// the caller.
///
/// Two shapes are implemented: the no-result `func()` (c-2b) and a single
/// flat-4-scalar result `func() -> u32` (d-a — the result is delivered via the
/// callee's `task.return`, captured graph-side). Any param list, or a wider /
/// aggregate result that needs cross-boundary marshalling, is a typed deferral:
/// `UnsupportedBoundaryType`, never a silent wrong value.
fn installAsyncBoundary(
    graph: *ComponentGraph,
    lk: *Linker,
    ns: []const u8,
    core_export_name: []const u8,
    ft: ctypes.FuncType,
    r: ctypes.TypeInfo.ResolvedLift,
    core_inst: *Instance,
    importer: *GraphChild,
    provider: Provider,
) GraphError!void {
    // A single FLAT param (a `future`/`stream`/scalar handle that flattens to one
    // i32) crosses verbatim to the callee entry (ADR-0195 d-b-2). A future/stream
    // handle resolves to the same GRAPH-shared rendezvous slot in the callee, so
    // no rebind is needed — only the i32 crosses. A wider/aggregate param list
    // needs cross-memory marshalling (a later slice) → typed deferral.
    if (ft.params.len > 1) return GraphError.UnsupportedBoundaryType;
    const has_param = ft.params.len == 1;
    if (has_param and !isFlatI32Handle(graph.alloc, &provider.child.info, ft.params[0].ty)) return GraphError.UnsupportedBoundaryType;
    const has_result = if (ft.result) |rt| blk: {
        if (!isFlat4Scalar(rt)) return GraphError.UnsupportedBoundaryType;
        break :blk true;
    } else false;
    // A param + a retptr-result at once is a broader 2-word lowered shape not yet
    // wired (no fixture exercises it) — defer loudly rather than mis-marshal.
    if (has_param and has_result) return GraphError.UnsupportedBoundaryType;
    const cb = r.callback orelse return GraphError.UnsupportedBoundaryType; // async lift implies a callback
    const cb_inst = provider.child.core_instances.items[cb.instance] orelse return GraphError.ImportUnsatisfied;

    const as = try graph.asyncState();
    const cb_funcidx = try as.registerCallback(cb_inst, cb.name);

    const bctx = try graph.alloc.create(BoundaryCtx);
    // D-466: no local errdefer — graph.deinit owns bctx once appended below; a
    // surviving errdefer double-frees on a later defineFuncCtx failure.
    bctx.* = .{
        .callee = provider.child,
        .core_func_name = r.core_func.name,
        .core_inst = core_inst,
        .func_type = ft,
        .async_state = as,
        .async_cb_funcidx = cb_funcidx,
        .importer = importer, // d-b: the result-bearing trampoline lowers B's result into A's retptr
    };
    try graph.boundaries.append(graph.alloc, bctx);

    if (has_result) {
        try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), AsyncBoundaryRetSig, asyncBoundaryRetTrampoline);
    } else if (has_param) {
        try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), AsyncBoundaryParamSig, asyncBoundaryParamTrampoline);
    } else {
        try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), AsyncBoundarySig, asyncBoundaryTrampoline);
    }
}

/// A valtype that flattens to a single i32 core word AND can cross the async
/// boundary as a bare handle: a `future`/`stream` handle (its i32 indexes the
/// GRAPH-shared table, valid in the callee) or a 4-byte scalar. A `string` /
/// aggregate flattens to >1 word → not a single-word handle. The param is a
/// `type_index` into the provider's type space, so resolve via `canon`.
fn isFlatI32Handle(alloc: Allocator, info: *const ctypes.TypeInfo, vt: ctypes.ValType) bool {
    if (isFlat4Scalar(vt)) return true;
    var tmp = std.heap.ArenaAllocator.init(alloc);
    defer tmp.deinit();
    const ct = canon.canonTypeFromDecoded(tmp.allocator(), info, vt) catch return false;
    return switch (ct) {
        .future, .stream, .own, .borrow => true,
        .prim => |p| isFlat4ScalarPrim(p),
        else => false,
    };
}

/// A 4-byte (i32-flat) scalar primitive — the prim-level form of `isFlat4Scalar`.
fn isFlat4ScalarPrim(p: ctypes.PrimValType) bool {
    return switch (p) {
        .bool, .s8, .u8, .s16, .u16, .s32, .u32, .char => true,
        .s64, .u64, .f32, .f64, .string, .error_context => false,
    };
}

/// Host trampoline for an async cross-component import (ADR-0195 c-2b): invoke
/// the callee's async task entry, seed a `TaskDescriptor` from its packed result
/// (EXIT → done, YIELD → ready, WAIT → waiting), enqueue it into the shared
/// scheduler table, and return the async-call status (RETURNED, since the
/// minimal callee resolves synchronously). A callee trap propagates as a trap.
fn asyncBoundaryTrampoline(caller: *Caller) BoundaryError!u32 {
    _ = try enqueueCalleeSubtask(caller.data(BoundaryCtx), null);
    return SUBTASK_RETURNED;
}

/// Single-flat-param async import (`canon lower … async` of `func(handle)`,
/// ADR-0195 d-b-2): the lowered core func is `(handle:i32) -> i32`. The handle
/// (a `future`/`stream` end into the GRAPH-shared table) crosses verbatim to the
/// callee's entry — its i32 resolves to the same rendezvous slot in the callee,
/// so no rebind is needed. The callee runs synchronously here (writing into / the
/// future the importer later reads), and the call returns the async status.
fn asyncBoundaryParamTrampoline(caller: *Caller, handle: u32) BoundaryError!u32 {
    const bctx = caller.data(BoundaryCtx);
    // ADR-0197 (D-463): lowering a stream/future end across the boundary TRANSFERS
    // ownership to the callee (Component-Model lower-of-an-owned-handle moves it).
    // Retag the ledger so the callee may access it and the caller can no longer reach
    // it. A scalar / resource handle is untracked (absent from the ledger) → untouched.
    if (bctx.async_state) |as| {
        if (as.owners.getPtr(handle)) |o| o.* = bctx.callee.idx;
    }
    _ = try enqueueCalleeSubtask(bctx, handle);
    return SUBTASK_RETURNED;
}

/// Result-bearing async import (`func() -> u32`, ADR-0195 d-b): the lowered core
/// func carries a leading `retptr` where the importer (A) receives the result. The
/// callee's result is delivered via its `task.return` (captured graph-side into the
/// subtask's per-task slot); on SYNCHRONOUS resolution (the callee ran to `.done`
/// in its entry invoke) this trampoline lowers that flat-4 result into A's memory
/// at `retptr`, so A reads B's value in-guest.
fn asyncBoundaryRetTrampoline(caller: *Caller, retptr: u32) BoundaryError!u32 {
    const bctx = caller.data(BoundaryCtx);
    const task_id = try enqueueCalleeSubtask(bctx, null);

    // Lower B's task.return result into A's retptr IF the subtask resolved
    // synchronously (it task.returned during its entry invoke). A callee that
    // blocked (no result yet) is the async-completion path — the result arrives
    // via a later subtask event (a further d-slice); the retptr stays unwritten and
    // A must not read it until the SUBTASK event fires.
    const as = bctx.async_state orelse return error.OutOfBoundsStore;
    const task = as.tasks.get(task_id) catch return error.OutOfBoundsLoad;
    if (task.result) |v| {
        const importer = bctx.importer orelse return error.OutOfBoundsStore;
        const cx = importer.canonContext();
        if (@as(usize, retptr) + 4 > cx.mem().len) return error.OutOfBoundsStore;
        std.mem.writeInt(u32, cx.mem()[retptr..][0..4], v, .little);
    }
    return SUBTASK_RETURNED;
}

/// Shared enqueue body: invoke the callee's async entry once, mint its subtask,
/// fold the packed result into the subtask state, and return the new task's id
/// (so the caller can read its `.result` for the d-b retptr lowering).
fn enqueueCalleeSubtask(bctx: *BoundaryCtx, arg: ?u32) BoundaryError!u32 {
    const as = bctx.async_state orelse return error.OutOfBoundsLoad; // wired only for async boundaries

    // Reserve the callee subtask's id BEFORE invoking its entry, so the
    // graph-level task.return host func (ADR-0195 d-a) routes the callee's
    // `task.return(value)` into THIS task's `result` slot. A placeholder
    // descriptor is folded to its real state from the entry's packed return.
    const task_id = as.tasks.add(.{ .callback_funcidx = bctx.async_cb_funcidx }) catch return error.OutOfMemory;
    const prev = as.current_task_id;
    as.current_task_id = task_id;
    defer as.current_task_id = prev;

    // The single flat-i32 handle (d-b-2) crosses verbatim as the callee entry's
    // sole arg; a no-param callee gets an empty arg list.
    var arg_buf = [_]Value{.{ .i32 = @bitCast(arg orelse 0) }};
    const args: []const Value = if (arg != null) arg_buf[0..1] else &.{};
    var res = [_]Value{.{ .i32 = 0 }};
    try bctx.core_inst.invoke(bctx.core_func_name, args, &res);
    const initial: u32 = @bitCast(res[0].i32);

    const seed = async_mod.seedTask(initial) catch return error.OutOfBoundsLoad; // bad callback code = guest fault
    const task = as.tasks.get(task_id) catch return error.OutOfBoundsLoad;
    task.state = seed.state;
    task.set_index = seed.set_index;
    return task_id;
}

/// The graph-level `canon task.return` host func's flattened core signature:
/// `(value:i32) -> ()` (the minimal single-`u32`-lowered-result form). Returns
/// `BoundaryError!void` so a wiring fault propagates as a trap, never silently.
const TaskReturnSig = fn (*Caller, i32) BoundaryError!void;

/// Host trampoline for a graph child's `canon task.return(value)` (ADR-0195 d-a):
/// store the delivered value into the CURRENTLY-EXECUTING task's per-task `result`
/// slot. The graph runner sets `current_task_id` immediately before each guest
/// entry/callback invoke, so the value lands in the right subtask even with many
/// concurrent graph tasks (the per-task slot avoids the single-ctx-slot collision
/// the P3 runner's `WasiP2Ctx.task_return` would have across tasks). A
/// task.return with no executing task, or a stale task id, is a wiring fault →
/// trap (never a silent drop).
fn graphTaskReturn(caller: *Caller, value: i32) BoundaryError!void {
    const as = caller.data(GraphAsync);
    const task = as.tasks.get(as.current_task_id) catch return error.OutOfBoundsStore;
    task.result = @bitCast(value);
}

/// `canon waitable-set.new` at the graph boundary (ADR-0195 d-c-2): mint an empty
/// waitable set into the GRAPH-shared `sets` table (mirror of `p2WaitableSetNew`).
/// A blocked guest callee builds a set, joins its parked end, and returns WAIT(set);
/// the graph scheduler's `pollSet` then resolves it across the boundary.
fn graphWaitableSetNew(caller: *Caller) BoundaryError!u32 {
    const as = caller.data(GraphFutureCtx).as;
    return as.sets.add(async_mod.WaitableSet.init(as.alloc)) catch |e| return mapGraphAsyncFault(e);
}

/// `canon waitable.join` at the graph boundary (ADR-0195 d-c-2): add a waitable
/// (a stream/future end handle in `GraphAsync.streams`) to a graph-shared set. A
/// bad set handle is a guest fault → trap (mirror of `p2WaitableJoin`).
fn graphWaitableJoin(caller: *Caller, waitable: u32, set_handle: u32) BoundaryError!void {
    const ctx = caller.data(GraphFutureCtx);
    try checkOwner(ctx, waitable); // a child may only join an end it owns (ADR-0197)
    const set = ctx.as.sets.get(set_handle) catch |e| return mapGraphAsyncFault(e);
    set.join(waitable) catch |e| return mapGraphAsyncFault(e);
}

/// The host context a graph `canon future.*` builtin binds to (ADR-0195 d-b-2):
/// the GRAPH-shared rendezvous arena + its handle table (so a future minted in
/// child A is readable by child B), plus the resolved payload byte size for the
/// `future<T>` this op operates on.
const GraphFutureCtx = struct { as: *GraphAsync, elem_size: u8, child_idx: u32 = 0 };

/// ADR-0197 (D-463): a child may only operate on a stream/future end it OWNS. A
/// handle with no ledger entry, or one owned by a different child, is a guest fault
/// → the canonical guest trap (the pre-fix shared-table runner silently allowed a
/// peer child to reach an un-granted end). Mirrors `Table.get`'s trap-on-stale.
fn checkOwner(ctx: *GraphFutureCtx, handle: u32) BoundaryError!void {
    const owner = ctx.as.owners.get(handle) orelse return error.Unreachable;
    if (owner != ctx.child_idx) return error.Unreachable;
}

/// Record both freshly-minted ends as owned by the minting child (ADR-0197).
fn recordOwnerPair(ctx: *GraphFutureCtx, pair: async_mod.EndPair) BoundaryError!void {
    ctx.as.owners.put(ctx.as.alloc, pair.readable, ctx.child_idx) catch return error.OutOfMemory;
    ctx.as.owners.put(ctx.as.alloc, pair.writable, ctx.child_idx) catch return error.OutOfMemory;
}

/// Map a graph async-builtin fault to the host-fn surface: a guest supplies the
/// handle/ptr, so a bad handle / illegal sequencing / exhausted table is a GUEST
/// fault → the canonical guest trap (`error.Unreachable`), which `mapDispatchErr`
/// narrows cleanly. Genuine host OOM propagates. (Mirrors `component_wasi_p2.mapAsyncFault`.)
fn mapGraphAsyncFault(e: async_mod.Error) BoundaryError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreachable,
    };
}

/// `canon future.new` at the graph boundary: mint a readable+writable end pair
/// into the GRAPH-shared table over the GRAPH-shared rendezvous; return the
/// spec's packed `ri | (wi << 32)`. Both ends (hence the handle that later
/// crosses to the peer child) live in the one shared table.
fn graphFutureNew(caller: *Caller) BoundaryError!u64 {
    const ctx = caller.data(GraphFutureCtx);
    const pair = async_mod.newFuturePair(&ctx.as.streams, &ctx.as.shared, null) catch |e| return mapGraphAsyncFault(e);
    try recordOwnerPair(ctx, pair);
    return @as(u64, pair.readable) | (@as(u64, pair.writable) << 32);
}

/// `canon future.write(handle, ptr)` at the graph boundary: deposit the single
/// value's lowered bytes (read from the writer child's memory at `ptr`) into the
/// shared future, then drive the rendezvous. Single-shot → the bytes outlive the
/// (possibly blocked) write until the reader drains them.
fn graphFutureWrite(caller: *Caller, handle: u32, ptr: u32) BoundaryError!u32 {
    const ctx = caller.data(GraphFutureCtx);
    try checkOwner(ctx, handle);
    const end = ctx.as.streams.get(handle) catch |e| return mapGraphAsyncFault(e);
    const sh = ctx.as.shared.get(end.shared) catch |e| return mapGraphAsyncFault(e);
    const fut = switch (sh.*) {
        .future => |*f| f,
        // future.* on a non-future handle = guest fault (subtask never linked).
        .stream, .subtask => return error.Unreachable,
    };
    // Stash the writer's bytes BEFORE the rendezvous step (so a parked writer's
    // value is available when the reader later completes the rendezvous).
    const mem = caller.memory() orelse return error.OutOfBoundsLoad;
    const src = mem.sliceAt(ptr, ctx.elem_size) catch return error.OutOfBoundsLoad;
    @memcpy(fut.value[0..ctx.elem_size], src);
    fut.value_len = ctx.elem_size;
    const step = end.copy(fut, &ctx.as.streams, handle, 1) catch |e| return mapGraphAsyncFault(e);
    return step.code().encode();
}

/// `canon future.read(handle, ptr)` at the graph boundary: drive the rendezvous,
/// then — on a COMPLETED read — copy the writer's stashed value out of the shared
/// future into the reader child's memory at `ptr`. The DATA half of the transfer.
fn graphFutureRead(caller: *Caller, handle: u32, ptr: u32) BoundaryError!u32 {
    const ctx = caller.data(GraphFutureCtx);
    try checkOwner(ctx, handle);
    const end = ctx.as.streams.get(handle) catch |e| return mapGraphAsyncFault(e);
    const sh = ctx.as.shared.get(end.shared) catch |e| return mapGraphAsyncFault(e);
    const fut = switch (sh.*) {
        .future => |*f| f,
        .stream, .subtask => return error.Unreachable,
    };
    const step = end.copy(fut, &ctx.as.streams, handle, 1) catch |e| return mapGraphAsyncFault(e);
    if (step.caller == .completed) {
        if (fut.value_len < ctx.elem_size) return error.Unreachable; // reader before any writer = guest fault
        const mem = caller.memory() orelse return error.OutOfBoundsStore;
        const dst = mem.sliceAt(ptr, ctx.elem_size) catch return error.OutOfBoundsStore;
        @memcpy(dst, fut.value[0..ctx.elem_size]);
    }
    return step.code().encode();
}

/// `canon {future,stream}.drop-{readable,writable}(handle)` at the graph boundary:
/// drop one end (release its share of the rendezvous). Kind-agnostic — `dropEnd`
/// resolves the end's shared slot regardless of stream/future, so both families
/// share this fn (ADR-0195 d-b-2 / d-c-1).
fn graphFutureDrop(caller: *Caller, handle: u32) BoundaryError!void {
    const ctx = caller.data(GraphFutureCtx);
    try checkOwner(ctx, handle);
    // dropEndGuarded enforces the future-writable-before-write trap + marks the
    // rendezvous DROPPED for the surviving peer (shared with the WASI-P2 path).
    async_mod.dropEndGuarded(&ctx.as.streams, &ctx.as.shared, handle) catch |e| return mapGraphAsyncFault(e);
    _ = ctx.as.owners.remove(handle); // the end no longer exists; free its ledger entry
}

/// `canon stream.new` at the graph boundary (ADR-0195 d-c-1): mint a readable +
/// writable end pair into the GRAPH-shared table over the GRAPH-shared rendezvous;
/// return the spec's packed `ri | (wi << 32)`. Symmetric to `graphFutureNew`.
fn graphStreamNew(caller: *Caller) BoundaryError!u64 {
    const ctx = caller.data(GraphFutureCtx);
    const pair = async_mod.newStreamPair(&ctx.as.streams, &ctx.as.shared, null) catch |e| return mapGraphAsyncFault(e);
    try recordOwnerPair(ctx, pair);
    return @as(u64, pair.readable) | (@as(u64, pair.writable) << 32);
}

/// `canon stream.write(handle, ptr, count)` at the graph boundary (ADR-0195
/// d-c-1): deposit `count` lowered elements (read from the writer child's memory
/// at `ptr`) into the shared stream, then drive the rendezvous. The synchronous
/// case (the reader has not yet read) stashes the bytes so the later reader drains
/// them. A `count * elem_size` exceeding the inline buffer is a typed deferral.
fn graphStreamWrite(caller: *Caller, handle: u32, ptr: u32, count: u32) BoundaryError!u32 {
    const ctx = caller.data(GraphFutureCtx);
    try checkOwner(ctx, handle);
    const end = ctx.as.streams.get(handle) catch |e| return mapGraphAsyncFault(e);
    const sh = ctx.as.shared.get(end.shared) catch |e| return mapGraphAsyncFault(e);
    const st = switch (sh.*) {
        .stream => |*s| s,
        // stream.* on a non-stream handle = guest fault (subtask never linked).
        .future, .subtask => return error.Unreachable,
    };
    const nbytes = @as(u64, count) * @as(u64, ctx.elem_size);
    if (nbytes > async_mod.SharedStream.BUF_CAP) return error.Unreachable; // > inline buf: d-c later slice
    // Stash the writer's bytes BEFORE the rendezvous step (so a parked reader, or
    // a not-yet-arrived reader, drains them on completion).
    const mem = caller.memory() orelse return error.OutOfBoundsLoad;
    const src = mem.sliceAt(ptr, @intCast(nbytes)) catch return error.OutOfBoundsLoad;
    @memcpy(st.buf[0..@intCast(nbytes)], src);
    st.buf_len = @intCast(nbytes);
    const step = end.copy(st, &ctx.as.streams, handle, count) catch |e| return mapGraphAsyncFault(e);
    // ADR-0195 d-c-2 (the BLOCKING path): if this write resolved a PARKED reader
    // (the reader blocked before any writer arrived), deliver the deposited bytes
    // into that reader's recorded memory now — its `pending_event` is already set
    // by `end.copy`'s notify, so `pollSet` re-enters its task to find the bytes
    // in place. The guest↔guest analogue of the host-source `deliverParkedReads`.
    if (step.notify) |nt| {
        if (ctx.as.pending_graph_reads.fetchRemove(nt.waitable)) |kv| {
            const pr = kv.value;
            // Deliver min(reader capacity, deposited) bytes — the rendezvous count
            // model resolves to `min(write_count, read_cap)`, so cap the copy by
            // both the reader's requested span and what the writer actually stashed.
            const rbytes = @min(@as(u64, pr.cap) * @as(u64, pr.elem_size), @as(u64, st.buf_len));
            if (rbytes > 0) {
                const dst = pr.mem.sliceAt(pr.ptr, @intCast(rbytes)) catch return error.OutOfBoundsStore;
                @memcpy(dst, st.buf[0..@intCast(rbytes)]);
            }
        }
    }
    return step.code().encode();
}

/// `canon stream.read(handle, ptr, count)` at the graph boundary (ADR-0195
/// d-c-1): drive the rendezvous, then — on a COMPLETED(n) read — copy the first
/// `n` elements the writer stashed out of the shared stream into the reader
/// child's memory at `ptr`. A would-block read (writer not yet written) returns
/// BLOCKED loudly (the pollSet path is d-c-2), never a silent 0.
fn graphStreamRead(caller: *Caller, handle: u32, ptr: u32, count: u32) BoundaryError!u32 {
    const ctx = caller.data(GraphFutureCtx);
    try checkOwner(ctx, handle);
    const end = ctx.as.streams.get(handle) catch |e| return mapGraphAsyncFault(e);
    const sh = ctx.as.shared.get(end.shared) catch |e| return mapGraphAsyncFault(e);
    const st = switch (sh.*) {
        .stream => |*s| s,
        .future, .subtask => return error.Unreachable,
    };
    const step = end.copy(st, &ctx.as.streams, handle, count) catch |e| return mapGraphAsyncFault(e);
    if (step.caller == .completed) {
        const n = step.caller.completed;
        const nbytes = @as(u64, n) * @as(u64, ctx.elem_size);
        if (nbytes > 0) {
            if (st.buf_len < nbytes) return error.Unreachable; // reader before any writer deposit = guest fault
            const mem = caller.memory() orelse return error.OutOfBoundsStore;
            const dst = mem.sliceAt(ptr, @intCast(nbytes)) catch return error.OutOfBoundsStore;
            @memcpy(dst, st.buf[0..@intCast(nbytes)]);
        }
    } else if (step.caller == .blocked) {
        // ADR-0195 d-c-2: the read parked (no writer yet). Record where the resolving
        // peer-write must deposit the bytes (this reader's memory + ptr), keyed by the
        // readable end handle the guest then joins to its waitable set. Validate the
        // destination span up front so a bad (ptr,cap) traps at park time, not later.
        const mem = caller.memory() orelse return error.OutOfBoundsStore;
        const span = @as(u64, count) * @as(u64, ctx.elem_size);
        _ = mem.sliceAt(ptr, @intCast(span)) catch return error.OutOfBoundsStore;
        ctx.as.pending_graph_reads.put(ctx.as.alloc, handle, .{ .mem = mem, .ptr = ptr, .cap = count, .elem_size = ctx.elem_size }) catch return error.OutOfMemory;
    }
    return step.code().encode();
}

/// The lowered byte size of a `future<T>`'s value `T` / `stream<T>`'s element `T`
/// (1 for payload-less / unresolvable). Mirrors `component_wasi_p2.streamElemByteSize`
/// but graph-side; caps to the relevant inline-buffer width (a wider payload is a
/// typed deferral, see the per-op `> CAP` guards).
fn graphStreamFutureElemSize(alloc: Allocator, info: *const ctypes.TypeInfo, type_index: u32) u8 {
    var tmp = std.heap.ArenaAllocator.init(alloc);
    defer tmp.deinit();
    const resolved = canon.resolveTypeIndex(tmp.allocator(), info, type_index) catch return 1;
    // A future stashes ONE value (cap VALUE_CAP=8); a stream stashes its synchronous
    // element bytes (cap BUF_CAP). The per-op `> CAP` guards re-check at write time.
    const payload: ?ctypes.ValType, const cap: u16 = switch (resolved.dt) {
        .future => |f| .{ f.payload, async_mod.SharedFuture.VALUE_CAP },
        .stream => |s| .{ s.payload, async_mod.SharedStream.BUF_CAP },
        else => return 1,
    };
    const p = payload orelse return 1;
    const ct = canon.canonTypeFromDecoded(tmp.allocator(), info, p) catch return 1;
    const sz = canon.sizeOf(ct);
    return if (sz == 0 or sz > cap) 1 else @intCast(sz);
}

/// Wire a child's `canon {future,stream}.*` core import to the matching graph-level
/// host func (ADR-0195 d-b-2 / d-c-1). The host context is heap-allocated + tracked
/// for free at graph deinit; `elem_size` resolves the `future<T>`/`stream<T>`
/// payload byte width. Cancel ops land in a later slice (d-c-2) → typed deferral.
fn installGraphFutureBuiltin(
    graph: *ComponentGraph,
    child: *GraphChild,
    lk: *Linker,
    ns: []const u8,
    core_export_name: []const u8,
    op: ctypes.StreamFutureOp,
    type_index: u32,
) GraphError!void {
    const as = try graph.asyncState();
    const elem_size = graphStreamFutureElemSize(graph.alloc, &child.info, type_index);
    const fctx = try graph.alloc.create(GraphFutureCtx);
    // D-466: no local errdefer — graph.deinit owns fctx once appended below.
    fctx.* = .{ .as = as, .elem_size = elem_size, .child_idx = child.idx };
    try graph.future_ctxs.append(graph.alloc, fctx);
    switch (op) {
        .future_new => try lk.defineFuncCtx(ns, core_export_name, @ptrCast(fctx), fn (*Caller) BoundaryError!u64, graphFutureNew),
        .future_write => try lk.defineFuncCtx(ns, core_export_name, @ptrCast(fctx), fn (*Caller, u32, u32) BoundaryError!u32, graphFutureWrite),
        .future_read => try lk.defineFuncCtx(ns, core_export_name, @ptrCast(fctx), fn (*Caller, u32, u32) BoundaryError!u32, graphFutureRead),
        .future_drop_readable, .future_drop_writable => try lk.defineFuncCtx(ns, core_export_name, @ptrCast(fctx), fn (*Caller, u32) BoundaryError!void, graphFutureDrop),
        // stream.{new,read,write,drop-*} (ADR-0195 d-c-1, synchronous multi-element
        // rendezvous). `dropEnd` is kind-agnostic so the future drop fn is reused.
        .stream_new => try lk.defineFuncCtx(ns, core_export_name, @ptrCast(fctx), fn (*Caller) BoundaryError!u64, graphStreamNew),
        .stream_write => try lk.defineFuncCtx(ns, core_export_name, @ptrCast(fctx), fn (*Caller, u32, u32, u32) BoundaryError!u32, graphStreamWrite),
        .stream_read => try lk.defineFuncCtx(ns, core_export_name, @ptrCast(fctx), fn (*Caller, u32, u32, u32) BoundaryError!u32, graphStreamRead),
        .stream_drop_readable, .stream_drop_writable => try lk.defineFuncCtx(ns, core_export_name, @ptrCast(fctx), fn (*Caller, u32) BoundaryError!void, graphFutureDrop),
        // stream/future cancel-{read,write}: the blocking-copy cancellation path
        // (d-c-2). Typed deferral — fail loudly.
        .stream_cancel_read,
        .stream_cancel_write,
        .future_cancel_read,
        .future_cancel_write,
        => return GraphError.UnsupportedBoundaryType,
    }
}

/// Does this WIT func return a `string`? A string result flattens to >1 core
/// value so it returns via a retptr — the dedicated `(retptr) -> ()` trampoline.
fn resultIsString(alloc: Allocator, info: *const ctypes.TypeInfo, ft: ctypes.FuncType) bool {
    const rt = ft.result orelse return false;
    if (isString(rt)) return true;
    // A `type_index` result may alias `string` (the provider type space).
    var tmp = std.heap.ArenaAllocator.init(alloc);
    defer tmp.deinit();
    if (canon.canonTypeFromDecoded(tmp.allocator(), info, rt)) |ct| {
        return ct == .prim and ct.prim == .string;
    } else |_| {
        return false;
    }
}

/// D-305(b2): the in-memory size+alignment of a flat-record RESULT that crosses
/// via retptr, or null if the result is not a by-value record blob. A record
/// flattening to >1 core value returns via a return area; a flat record (no
/// internal string/list/handle pointer) is raw-copyable byte-for-byte, so the
/// retptr marshal needs only its size+alignment. A single-field record (flattens
/// to 1 core value, no retptr) and aggregates with internal pointers are excluded.
fn resultFlatRecordBlob(alloc: Allocator, info: *const ctypes.TypeInfo, ft: ctypes.FuncType) ?struct { size: u32 } {
    const rt = ft.result orelse return null;
    var tmp = std.heap.ArenaAllocator.init(alloc);
    defer tmp.deinit();
    const ct = canon.canonTypeFromDecoded(tmp.allocator(), info, rt) catch return null;
    if (ct != .record) return null;
    if (!canonIsByValueBlob(ct)) return null;
    if (canonFlatWidth(ct) <= canon.MAX_FLAT_RESULTS) return null; // fits a flat result → no retptr
    return .{ .size = @intCast(canon.sizeOf(ct)) };
}

/// D-305(b4): is the result a record CONTAINING an internal pointer (string/list)?
/// Such a record can't cross by raw byte copy (its pointers are B-relative); it
/// needs the `canon.load`(B)→`canon.store`(A) memory→memory marshal that relocates
/// the pointed-to bytes into A's memory. A flat record (no pointer) takes the
/// cheaper `resultFlatRecordBlob` raw-copy path above instead.
fn resultRecordWithPointer(alloc: Allocator, info: *const ctypes.TypeInfo, ft: ctypes.FuncType) bool {
    const rt = ft.result orelse return false;
    var tmp = std.heap.ArenaAllocator.init(alloc);
    defer tmp.deinit();
    const ct = canon.canonTypeFromDecoded(tmp.allocator(), info, rt) catch return false;
    return ct == .record and canonHasPointer(ct);
}

/// A canonical type whose in-memory representation is a self-contained byte blob
/// — fixed-size scalars (incl. wide f32/f64/i64) and records built from them,
/// with NO internal pointer (string/list/handle). Such a value crosses a retptr
/// boundary by a raw byte copy (no lift/lower relocation). Broader than
/// `canonIsFlatI32` (which the register pass-through path needs) since a memory
/// blob doesn't care about the i32 vs f64 core-word distinction. D-305(b2).
fn canonIsByValueBlob(t: canon.CanonType) bool {
    return switch (t) {
        .prim => |p| p != .string and p != .error_context,
        .record => |fields| {
            for (fields) |f| {
                if (!canonIsByValueBlob(f.ty)) return false;
            }
            return true;
        },
        else => false,
    };
}

/// Backing storage for every boundary's core param/result ValType slices passed
/// to `defineFuncRaw`. Every flat-scalar/string/list boundary flattens to all-i32
/// core words, so one static all-i32 array serves them all — no per-boundary
/// allocation (D-305). Sized to the linker's raw-arity cap.
const boundary_core_i32: [marshal.raw_max_words]zir.ValType = .{.i32} ** marshal.raw_max_words;

/// The resolved boundary shape: whether the func flattens to the all-i32 core
/// signature the generic trampoline marshals, and its flattened param word count.
const BoundaryShape = struct { ok: bool, words: usize, record_marshal: bool = false };

/// Resolve the boundary's flattened all-i32 core shape + param word count.
/// Accepts: a single `(string)` / `(list<primitive>)` param (2 ptr,len words,
/// memory-marshalled at call time); OR params that flatten to all-i32 with no
/// internal pointer — flat-4 scalars and flat records/tuples thereof (D-305(b)),
/// each passing straight through. The result must be a single flat-4 scalar (an
/// aggregate RESULT uses the retptr path, handled earlier). D-305: flat-scalar
/// arity is no longer per-trampoline capped — only `marshal.raw_max_words` (the
/// generic thunk buffer) bounds the flattened word count. Wide scalars
/// (s64/u64/f32/f64), strings/lists INSIDE a record, and variant/enum/flags stay
/// a typed deferral (no silent mis-marshal).
fn boundaryFlatShape(alloc: Allocator, info: *const ctypes.TypeInfo, ft: ctypes.FuncType, param0_is_list: bool) BoundaryShape {
    const no = BoundaryShape{ .ok = false, .words = 0 };
    const result_ok = if (ft.result) |rt| isFlat4Scalar(rt) else false;
    if (!result_ok) return no;
    if (ft.params.len == 1 and (isString(ft.params[0].ty) or param0_is_list)) return .{ .ok = true, .words = 2 };
    // D-305(b3): a single record param CONTAINING an internal pointer (string/list)
    // can't pass through by-words — it crosses via a canon liftFlat/lowerFlat
    // round-trip (the pointed-to bytes are copied A→B). Accept it with the canon-
    // flattened word count; a FLAT record (no pointer) falls through to the cheap
    // pass-through path below.
    if (ft.params.len == 1) {
        var tmp = std.heap.ArenaAllocator.init(alloc);
        defer tmp.deinit();
        if (canon.canonTypeFromDecoded(tmp.allocator(), info, ft.params[0].ty)) |ct| {
            if (ct == .record and canonHasPointer(ct)) {
                var words: std.ArrayList(canon.CoreType) = .empty;
                canon.flattenType(tmp.allocator(), ct, &words) catch return no;
                if (words.items.len == 0 or words.items.len > marshal.raw_max_words) return no;
                return .{ .ok = true, .words = words.items.len, .record_marshal = true };
            }
        } else |_| {
            // Type resolution failed → not a record; fall through to the flat path.
        }
    }
    if (ft.params.len == 0 or ft.params.len > marshal.raw_max_words) return no;
    var total: usize = 0;
    for (ft.params) |p| {
        var tmp = std.heap.ArenaAllocator.init(alloc);
        defer tmp.deinit();
        const ct = canon.canonTypeFromDecoded(tmp.allocator(), info, p.ty) catch return no;
        if (!canonIsFlatI32(ct)) return no;
        total += canonFlatWidth(ct);
    }
    if (total == 0 or total > marshal.raw_max_words) return no;
    return .{ .ok = true, .words = total };
}

/// D-305(b): does a canonical type flatten to all-i32 core words with NO internal
/// pointer (string/list)? True for the flat-4 scalars (`flatCoreType == .i32`)
/// and records recursively built from them — these pass straight through the
/// boundary like flat scalars. Wide (i64/f32/f64) prims, string/list, and
/// variant/enum/flags are NOT (a different core word or a typed deferral).
fn canonIsFlatI32(t: canon.CanonType) bool {
    return switch (t) {
        .prim => |p| (canon.flatCoreType(p) orelse return false) == .i32,
        .record => |fields| {
            for (fields) |f| {
                if (!canonIsFlatI32(f.ty)) return false;
            }
            return true;
        },
        else => false,
    };
}

/// Flattened i32-word count of a `canonIsFlatI32` type: a flat scalar is 1 word,
/// a record is the sum of its fields.
fn canonFlatWidth(t: canon.CanonType) usize {
    return switch (t) {
        .prim => 1,
        .record => |fields| blk: {
            var n: usize = 0;
            for (fields) |f| n += canonFlatWidth(f.ty);
            break :blk n;
        },
        else => 0,
    };
}

/// D-305(b3): does a canonical type contain an internal pointer (string / list /
/// resource handle) anywhere — directly or nested in a record? Such a value can
/// NOT pass through by-words (the pointer is into the SOURCE memory); it must
/// cross via a `liftFlat`/`lowerFlat` round-trip that copies the pointed-to bytes
/// into the target memory. A flat record (`canonHasPointer == false`) keeps the
/// cheap pass-through path. Variant pointer-payloads are not yet handled (defer).
fn canonHasPointer(t: canon.CanonType) bool {
    return switch (t) {
        .prim => |p| p == .string,
        .list, .own, .borrow, .stream, .future => true,
        .record => |fields| {
            for (fields) |f| {
                if (canonHasPointer(f.ty)) return true;
            }
            return false;
        },
        else => false,
    };
}

fn isString(vt: ctypes.ValType) bool {
    return switch (vt) {
        .primitive => |p| p == .string,
        else => false,
    };
}

/// A fixed-size scalar primitive (numeric/bool/char) — a `list<this>` is a flat
/// `count * size`-byte run with no internal pointers, so the boundary can copy
/// it by bytes. `string` / `error_context` need their own marshalling.
fn isFlatPrim(p: ctypes.PrimValType) bool {
    return switch (p) {
        .bool, .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64, .char => true,
        .string, .error_context => false,
    };
}

/// A 4-byte (i32-flat) scalar valtype — flattens to a single i32 core word.
fn isFlat4Scalar(vt: ctypes.ValType) bool {
    return switch (vt) {
        .primitive => |p| switch (p) {
            .bool, .s8, .u8, .s16, .u16, .s32, .u32, .char => true,
            .s64, .u64, .f32, .f64, .string, .error_context => false,
        },
        else => false,
    };
}

/// The error set a boundary trampoline returns: the callee-invoke's full
/// `InvokeError` (every guest `Trap` + `ProcExit`) plus the host-side
/// out-of-memory of the snapshot copy. Every variant is one `mapDispatchErr`
/// already narrows back to a `Trap` (or `ProcExit`), so a returned error becomes
/// a guest trap — NOT a silent fallback. The marshalling-failure cases map onto
/// the memory trap they are (`OutOfBoundsLoad`/`Store`), per the Canonical ABI +
/// untrusted-component sandboxing: a bad `(ptr,len)` must trap.
const BoundaryError = Instance.InvokeError || error{OutOfMemory};

/// D-305: ONE Value-slice host fn replaces the per-arity `boundaryTrampoline{,3,4}`.
/// `defineFuncRaw` pops the flattened core words into `args` (all-i32) and hands
/// them here; `boundaryMarshal` marshals a `string`/`list<primitive>` param into
/// the callee's memory, passes flat scalars straight through, invokes the callee
/// core func, and writes the single flat result. Serves ANY flat-scalar arity —
/// no per-arity Zig fn. A marshalling failure propagates as a guest trap (never a
/// silent fallback), exactly as the prior fixed-arity trampolines.
fn boundaryTrampolineRaw(caller: *Caller, args: []const RtValue, results: []RtValue) anyerror!void {
    const bctx = caller.data(BoundaryCtx);
    results[0] = .{ .i32 = @bitCast(try boundaryMarshal(caller, bctx, args)) };
}

/// Marshal the flattened core words across the boundary per the importer's WIT
/// signature, invoke the callee's core func, return its flat result. A `string` /
/// `list<primitive>` param (args[0]=ptr, args[1]=len/count in the IMPORTER's
/// memory) is copied into the CALLEE's memory via its realloc (the callee reads
/// its OWN memory); flat scalars pass through. A marshalling failure (OOB
/// (ptr,len), invalid UTF-8, realloc overflow) propagates as a trap — never a
/// silent fallback. The args are mutated in a local buffer before the invoke, so
/// the popped operands are not aliased.
fn boundaryMarshal(caller: *Caller, bctx: *BoundaryCtx, args: []const RtValue) BoundaryError!u32 {
    const params = bctx.func_type.params;

    // D-305(b3): a record-with-pointer param crosses via a canon round-trip — lift
    // the value from A's flattened words (`liftFlat` reads A's memory for the
    // string/list bytes), then lower it into B's memory (`lowerFlat` copies the
    // bytes via B's realloc + emits B's pointers). The lowered words invoke B.
    // `CoreValue` == the operand `RtValue`, so `args` is the flat input verbatim.
    if (bctx.param_record_marshal) {
        var rec_arena = std.heap.ArenaAllocator.init(caller.allocator());
        defer rec_arena.deinit();
        const ra = rec_arena.allocator();
        const ct = canon.canonTypeFromDecoded(ra, &bctx.callee.info, params[0].ty) catch return error.OutOfBoundsLoad;
        const importer = bctx.importer orelse return error.OutOfBoundsStore;
        var idx: usize = 0;
        const value = canon.liftFlat(importer.canonContext(), ra, ct, args, &idx) catch return error.OutOfBoundsLoad;
        var out: std.ArrayList(canon.CoreValue) = .empty;
        canon.lowerFlat(bctx.callee.canonContext(), ra, value, ct, &out) catch return error.OutOfBoundsStore;
        const bargs = ra.alloc(Value, out.items.len) catch return error.OutOfMemory;
        for (out.items, 0..) |cv, i| bargs[i] = .{ .i32 = cv.i32 };
        var res = [_]Value{.{ .i32 = 0 }};
        try bctx.core_inst.invoke(bctx.core_func_name, bargs, &res);
        return @bitCast(res[0].i32);
    }

    var arg_buf: [marshal.raw_max_words]Value = undefined;
    // Bridge the operand-stack words (RtValue) to the public `Value` invoke takes.
    // Every boundary word is a flat i32 (flat scalar or string/list ptr/len).
    for (args, 0..) |a, i| arg_buf[i] = .{ .i32 = a.i32 };
    const marshalled = arg_buf[0..args.len];

    if (bctx.list_elem_size > 0) {
        // list<primitive>: w0=ptr, w1=COUNT in the IMPORTER's memory. Copy
        // count*elem_size bytes into the CALLEE's memory via its realloc
        // (aligned to the element size), since the callee reads its OWN memory.
        const w0: u32 = @bitCast(marshalled[0].i32);
        const w1: u32 = @bitCast(marshalled[1].i32);
        const caller_mem: Memory = caller.memory() orelse return error.OutOfBoundsLoad;
        const byte_count: u32 = w1 * bctx.list_elem_size;
        const src = try caller_mem.sliceAt(w0, byte_count); // OOB read → OutOfBoundsLoad trap
        const tmp = try caller.allocator().dupe(u8, src);
        defer caller.allocator().free(tmp);
        const cx = bctx.callee.canonContext();
        const ptr = cx.realloc(0, 0, bctx.list_elem_size, byte_count) catch return error.OutOfBoundsStore;
        if (@as(usize, ptr) + byte_count > cx.mem().len) return error.OutOfBoundsStore;
        @memcpy(cx.mem()[ptr..][0..byte_count], tmp);
        marshalled[0] = .{ .i32 = @bitCast(ptr) };
        // count (marshalled[1]) unchanged.
    } else if (params.len == 1 and isString(params[0].ty)) {
        // Single string: w0=ptr, w1=len in the IMPORTER's memory. Snapshot the
        // bytes, then lower them into the CALLEE's memory via its realloc — the
        // callee reads its OWN memory, so the string must physically move.
        const w0: u32 = @bitCast(marshalled[0].i32);
        const w1: u32 = @bitCast(marshalled[1].i32);
        const caller_mem: Memory = caller.memory() orelse return error.OutOfBoundsLoad;
        const src = try caller_mem.sliceAt(w0, w1); // OOB read → OutOfBoundsLoad trap
        const tmp = try caller.allocator().dupe(u8, src);
        defer caller.allocator().free(tmp);
        const cx = bctx.callee.canonContext();
        const lowered = canon.lowerString(cx, tmp) catch |e| return stringErrToTrap(e);
        marshalled[0] = .{ .i32 = @bitCast(lowered.ptr) };
        marshalled[1] = .{ .i32 = @bitCast(lowered.packed_length) };
    }
    // else: flat scalars pass straight through (no memory marshalling).

    var res = [_]Value{.{ .i32 = 0 }};
    try bctx.core_inst.invoke(bctx.core_func_name, marshalled, &res);
    return @bitCast(res[0].i32);
}

/// Map a Canonical-ABI string marshalling failure onto the memory trap it is:
/// an out-of-bounds (ptr,len) or invalid/over-long string crossing the boundary
/// is a guest fault → a memory trap (Canonical ABI traps, never silently coerces).
fn stringErrToTrap(e: canon.StringError) BoundaryError {
    return switch (e) {
        error.OutOfBounds, error.AllocFailed => error.OutOfBoundsStore,
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUtf8, error.InvalidUtf16, error.StringTooLong, error.UnsupportedEncoding => error.OutOfBoundsLoad,
    };
}

/// The retptr-result trampoline's flattened core signature: `(retptr:i32) ->
/// ()`, returning `BoundaryError!void` so a marshalling failure PROPAGATES as a
/// guest trap (NOT a silent untouched-return-area fallback). A `string` RESULT
/// can't be a flat return word, so the importer passes a return-area pointer
/// (into its OWN memory) where the boundary writes the A-side `(ptr, len)` pair.
const RetPtrSig = fn (*Caller, u32) BoundaryError!void;

/// Host trampoline for `() -> string`: invoke the callee's core func (writing
/// the result string into the CALLEE's memory via a callee-side return area),
/// lift that string, then lower it into the IMPORTER's memory and write the
/// A-side `(ptr, len)` at the importer's retptr. A marshalling failure (out-of-
/// bounds return area, invalid UTF-8) propagates as a trap.
fn retPtrTrampoline(caller: *Caller, retptr: u32) BoundaryError!void {
    const bctx = caller.data(BoundaryCtx);
    return retPtrMarshal(caller, bctx, retptr);
}

fn retPtrMarshal(caller: *Caller, bctx: *BoundaryCtx, retptr: u32) BoundaryError!void {
    // 1. Allocate a return area in the CALLEE's memory and invoke its core func,
    //    which writes the result string (ptr,len) there (B writes B's memory).
    const callee_cx = bctx.callee.canonContext();
    const callee_ret = callee_cx.realloc(0, 0, 4, 8) catch return error.OutOfBoundsStore;
    var args = [_]Value{.{ .i32 = @bitCast(callee_ret) }};
    var res = [_]Value{};
    try bctx.core_inst.invoke(bctx.core_func_name, &args, &res);

    // 2. Lift the result string from the CALLEE's memory at its return area.
    if (@as(usize, callee_ret) + 8 > callee_cx.mem().len) return error.OutOfBoundsLoad;
    const b_ptr = std.mem.readInt(u32, callee_cx.mem()[callee_ret..][0..4], .little);
    const b_len = std.mem.readInt(u32, callee_cx.mem()[callee_ret + 4 ..][0..4], .little);
    const lifted = canon.liftString(callee_cx, caller.allocator(), b_ptr, b_len) catch |e| return stringErrToTrap(e);
    defer caller.allocator().free(lifted);

    // 3. Lower the string into the IMPORTER's memory. `lifted` is an OWNED host
    //    copy (independent of callee memory), so the importer's realloc moving
    //    its own memory can't disturb it. Write the A-side (ptr,len) at retptr.
    const importer = bctx.importer orelse return error.OutOfBoundsStore;
    const importer_cx = importer.canonContext();
    const lowered = canon.lowerString(importer_cx, lifted) catch |e| return stringErrToTrap(e);
    if (@as(usize, retptr) + 8 > importer_cx.mem().len) return error.OutOfBoundsStore;
    std.mem.writeInt(u32, importer_cx.mem()[retptr..][0..4], lowered.ptr, .little);
    std.mem.writeInt(u32, importer_cx.mem()[retptr + 4 ..][0..4], lowered.packed_length, .little);
}

/// D-305(b2) host trampoline for `() -> flat_record` (e.g. `() -> point`): A
/// passes a retptr into its OWN memory; allocate a return area in the CALLEE's
/// memory, invoke B's core func (which writes the record blob there), then
/// raw-copy the fixed-size bytes from the callee's area to A's retptr. A flat
/// record has no internal pointer, so the byte copy IS the lower (no relocation).
/// Out-of-bounds at either end propagates as a guest trap — never a silent fallback.
fn recordRetTrampoline(caller: *Caller, retptr: u32) BoundaryError!void {
    const bctx = caller.data(BoundaryCtx);
    const size: u32 = bctx.result_blob_size;

    // The canon-LIFT producer (B's core func) RETURNS a pointer into B's memory
    // where it stored the record — it takes no value param (unlike the string
    // retptr path, whose producer is authored to take a return area). Invoke with
    // no args; the i32 result is B's storage pointer.
    var args = [_]Value{};
    var res = [_]Value{.{ .i32 = 0 }};
    try bctx.core_inst.invoke(bctx.core_func_name, &args, &res);
    const b_ptr: u32 = @bitCast(res[0].i32);

    // Raw-copy the record blob from B's memory to A's retptr (a flat record has no
    // internal pointer → the byte copy IS the lower). Distinct component instances
    // → distinct memories (no aliasing).
    const callee_cx = bctx.callee.canonContext();
    if (@as(usize, b_ptr) + size > callee_cx.mem().len) return error.OutOfBoundsLoad;
    const importer = bctx.importer orelse return error.OutOfBoundsStore;
    const importer_cx = importer.canonContext();
    if (@as(usize, retptr) + size > importer_cx.mem().len) return error.OutOfBoundsStore;
    @memcpy(importer_cx.mem()[retptr..][0..size], callee_cx.mem()[b_ptr..][0..size]);
}

/// D-305(b4) host trampoline for `() -> record-with-string` (a record result with
/// an internal pointer): A passes a retptr into its OWN memory. Invoke B's producer
/// (returns a pointer to the record in B's memory), `canon.load` the record from
/// B's memory into a canon Value (lifting the string), then `canon.store` it into
/// A's retptr — which lowers the string into A's OWN memory via A's realloc and
/// writes A-relative pointers. canon.load/store recurse over record fields. A
/// marshalling failure propagates as a guest trap — never a silent fallback.
fn recordPtrRetTrampoline(caller: *Caller, retptr: u32) BoundaryError!void {
    const bctx = caller.data(BoundaryCtx);
    var arena = std.heap.ArenaAllocator.init(caller.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const ct = canon.canonTypeFromDecoded(a, &bctx.callee.info, bctx.func_type.result.?) catch return error.OutOfBoundsLoad;

    var args = [_]Value{};
    var res = [_]Value{.{ .i32 = 0 }};
    try bctx.core_inst.invoke(bctx.core_func_name, &args, &res);
    const b_ptr: u32 = @bitCast(res[0].i32);

    const value = canon.load(bctx.callee.canonContext(), a, ct, b_ptr) catch return error.OutOfBoundsLoad;
    const importer = bctx.importer orelse return error.OutOfBoundsStore;
    canon.store(importer.canonContext(), value, ct, retptr) catch return error.OutOfBoundsStore;
}

/// The `(string) -> string` boundary's flattened core signature:
/// `(param_ptr:i32, param_len:i32, retptr:i32) -> ()`, returning
/// `BoundaryError!void` so a marshalling failure PROPAGATES as a guest trap. It
/// composes the string PARAM lower (importer-memory → callee-memory) with the
/// string RESULT lift+lower (callee-memory → importer-memory, written at retptr).
const StrRetStrSig = fn (*Caller, u32, u32, u32) BoundaryError!void;

/// Host trampoline for `(string) -> string`: lower the caller's string param
/// into the CALLEE's memory (via the callee's realloc), invoke the callee core
/// func with `(callee_ptr, callee_len, callee_retptr)`, then lift the callee's
/// returned string and lower it into the IMPORTER's memory, writing the A-side
/// `(ptr,len)` at the importer's retptr. A marshalling failure (out-of-bounds
/// (ptr,len), invalid UTF-8, realloc overflow) propagates as a trap — never a
/// silent fallback.
fn strRetStrTrampoline(caller: *Caller, param_ptr: u32, param_len: u32, retptr: u32) BoundaryError!void {
    const bctx = caller.data(BoundaryCtx);
    const callee_cx = bctx.callee.canonContext();

    // 1. Lower the caller's string param into the CALLEE's memory (snapshot the
    //    caller bytes first: the callee realloc may grow/move its own memory).
    const caller_mem: Memory = caller.memory() orelse return error.OutOfBoundsLoad;
    const src = try caller_mem.sliceAt(param_ptr, param_len); // OOB read → trap
    const param_tmp = try caller.allocator().dupe(u8, src);
    defer caller.allocator().free(param_tmp);
    const lowered_param = canon.lowerString(callee_cx, param_tmp) catch |e| return stringErrToTrap(e);

    // 2. Allocate the callee's return area and invoke its core func, which writes
    //    the result string (ptr,len) there (B writes B's memory).
    const callee_ret = callee_cx.realloc(0, 0, 4, 8) catch return error.OutOfBoundsStore;
    var args = [_]Value{
        .{ .i32 = @bitCast(lowered_param.ptr) },
        .{ .i32 = @bitCast(lowered_param.packed_length) },
        .{ .i32 = @bitCast(callee_ret) },
    };
    var res = [_]Value{};
    try bctx.core_inst.invoke(bctx.core_func_name, &args, &res);

    // 3. Lift the result string from the CALLEE's memory at its return area.
    if (@as(usize, callee_ret) + 8 > callee_cx.mem().len) return error.OutOfBoundsLoad;
    const b_ptr = std.mem.readInt(u32, callee_cx.mem()[callee_ret..][0..4], .little);
    const b_len = std.mem.readInt(u32, callee_cx.mem()[callee_ret + 4 ..][0..4], .little);
    const lifted = canon.liftString(callee_cx, caller.allocator(), b_ptr, b_len) catch |e| return stringErrToTrap(e);
    defer caller.allocator().free(lifted);

    // 4. Lower the string into the IMPORTER's memory. `lifted` is an OWNED host
    //    copy (independent of callee memory), so the importer's realloc moving
    //    its own memory can't disturb it. Write the A-side (ptr,len) at retptr.
    const importer = bctx.importer orelse return error.OutOfBoundsStore;
    const importer_cx = importer.canonContext();
    const lowered = canon.lowerString(importer_cx, lifted) catch |e| return stringErrToTrap(e);
    if (@as(usize, retptr) + 8 > importer_cx.mem().len) return error.OutOfBoundsStore;
    std.mem.writeInt(u32, importer_cx.mem()[retptr..][0..4], lowered.ptr, .little);
    std.mem.writeInt(u32, importer_cx.mem()[retptr + 4 ..][0..4], lowered.packed_length, .little);
}

/// The component-import NAME a `canon lower`'s func operand aliases — for a
/// DIRECT func import (`(import "firstbyte" (func ...))`), the lowered
/// component-func index is a `ComponentFuncDef.import` into `imports`.
fn importNameOfLoweredFunc(info: *const ctypes.TypeInfo, component_func_idx: u32) ?[]const u8 {
    if (component_func_idx >= info.component_funcs.items.len) return null;
    return switch (info.component_funcs.items[component_func_idx]) {
        .import => |import_idx| if (import_idx < info.imports.items.len) info.imports.items[import_idx].name else null,
        else => null,
    };
}

fn instanceExportsFunc(inst: *Instance, name: []const u8) bool {
    return inst.exportFuncSig(name) != null;
}

fn nthChildComponent(decoded: *const decode.Component, n: u32) ?[]const u8 {
    var i: u32 = 0;
    for (decoded.sections.items) |sec| {
        if (sec.id != .component) continue;
        if (i == n) return sec.body;
        i += 1;
    }
    return null;
}

fn nthCoreModule(decoded: *const decode.Component, n: u32) ?[]const u8 {
    var i: u32 = 0;
    for (decoded.sections.items) |sec| {
        if (sec.id != .core_module) continue;
        if (i == n) return sec.body;
        i += 1;
    }
    return null;
}
