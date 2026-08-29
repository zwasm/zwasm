//! WASM Spec §4.2 "Runtime Structure" — Runtime central handle.
//!
//! Per ADR-0023 §3 P-A (single source of truth) and §3 P-D (vertical
//! slicing within `runtime/`): this file owns the `Runtime` struct
//! itself plus the small support types (`TableInstance`, `HostCall`)
//! that don't yet justify their own files. Spec §4.2 concepts that
//! do justify their own files are extracted to siblings:
//!
//! - `value.zig` — `Value`, `FuncEntity`
//! - `trap.zig`  — `Trap`, `TraceEvent`, `TraceCallback`
//! - `frame.zig` — `Frame`, `Label`, `max_*` stack-bound constants
//!
//! Module / Engine / Store / per-instance types follow in
//! ADR-0023 §7 items 4–6. Until they land, `instance` is an opaque
//! back-pointer (the `?*anyopaque` field below).
//!
//! Memory discipline: bounded inline buffers for both operand
//! stack (4096 slots) and frame stack (256 frames) per ROADMAP
//! §P3 — no allocation per call. Linear memory and global slots
//! are heap-allocated once at instance construction.
//!
//! Zone 1 (`src/runtime/`) — may import Zone 0 (`support/leb128.zig`)
//! and Zone 1 (`ir/`). MUST NOT import Zone 2+ (`interp/`, `jit*/`,
//! `wasi/`, `c_api/`, `cli/`).

const std = @import("std");

pub const zir = @import("../ir/zir.zig");
pub const dispatch_table = @import("../ir/dispatch_table.zig");

const value_mod = @import("value.zig");
const trap_mod = @import("trap.zig");
const frame_mod = @import("frame.zig");
const memory_instance_mod = @import("instance/memory_instance.zig");
const memory_backing = @import("instance/memory_backing.zig");
const guarded_mem = @import("../platform/guarded_mem.zig");
const heap_mod = @import("../feature/gc/heap.zig");
const stack_limit_mod = @import("../platform/stack_limit.zig");
pub const MemoryInstance = memory_instance_mod.MemoryInstance;

const Allocator = std.mem.Allocator;
const ValType = zir.ValType;
const FuncType = zir.FuncType;
const InterpCtx = dispatch_table.InterpCtx;

// ============================================================
// Re-exports — keep `runtime.X` callsites stable across the
// sub-file split. Each sibling file is the source of truth; this
// file presents the unified `Runtime`-package surface.
// ============================================================

pub const Value = value_mod.Value;
pub const FuncEntity = @import("instance/func.zig").FuncEntity;

pub const Trap = trap_mod.Trap;
pub const TraceEvent = trap_mod.TraceEvent;
pub const TraceCallback = trap_mod.TraceCallback;

pub const Frame = frame_mod.Frame;
pub const Label = frame_mod.Label;
pub const max_operand_stack = frame_mod.max_operand_stack;
pub const max_frame_stack = frame_mod.max_frame_stack;
pub const max_label_stack = frame_mod.max_label_stack;

pub const Module = @import("module.zig").Module;
pub const Engine = @import("engine.zig").Engine;
pub const Store = @import("store.zig").Store;
pub const Zombie = @import("store.zig").Zombie;
pub const Instance = @import("instance/instance.zig").Instance;
pub const ExportType = @import("instance/instance.zig").ExportType;
pub const TableInstance = @import("instance/table.zig").TableInstance;

/// Free a typed slice via `Allocator.rawFree`, skipping the
/// `@memset(slice, undefined)` poisoning that `Allocator.free`
/// performs. Required by `Runtime.deinit` per ADR-0014 §2.2 /
/// 6.K.2 to keep cross-module-imported slices intact when an
/// importer tears down.
inline fn rawFreeOwned(alloc: Allocator, comptime T: type, slice: []T) void {
    if (slice.len == 0) return;
    const bytes = std.mem.sliceAsBytes(slice);
    const non_const = @constCast(bytes);
    alloc.rawFree(
        non_const,
        std.mem.Alignment.fromByteUnits(@alignOf(T)),
        @returnAddress(),
    );
}

/// One host-call binding — stored at `Runtime.host_calls[i]`
/// for each `i` that corresponds to an imported function. The
/// `call <i>` instruction short-circuits to `fn_ptr(rt, ctx)`
/// when this slot is non-null. The C-API binding (Phase 4)
/// builds these for `(import "wasi_snapshot_preview1" ...)`
/// entries; ctx is typically a `*wasi.Host`.
pub const HostCall = struct {
    fn_ptr: *const fn (*Runtime, *anyopaque) anyerror!void,
    ctx: *anyopaque,
};

/// Wasm 3.0 EH Exception heap object — re-exported from
/// `feature/exception_handling/exception.zig` (Zone 1). Carried
/// by `Runtime.pending_exception` as `*Exception` during in-flight
/// throw / catch dispatch; tracked in `Runtime.live_exceptions`
/// for `Runtime.deinit` cleanup.
pub const Exception = @import("../feature/exception_handling/exception.zig").Exception;

/// Wasm 3.0 EH tag identity object (ADR-0114 D1) — re-exported from
/// `feature/exception_handling/tag.zig`. `Runtime.tags` holds one
/// `*TagInstance` per tag in the instance's tag index space; identity
/// is the pointer (cross-module imports share the source's pointer).
pub const TagInstance = @import("../feature/exception_handling/tag.zig").TagInstance;

/// Max number of operand values a tag's param-list can stash in
/// `Exception.payload`. Mirrors the `Exception` struct's inline
/// cap; matches `max_block_arity` in `src/interp/mvp.zig` (the
/// cap on Wasm 2.0 multivalue block arity, reused here so the
/// same fixed-size buffer can carry tag payload marshalling).
pub const max_exception_payload: u32 = 16;

/// ADR-0120 D5 — slot-count encoding of a Wasm value type in the
/// EH payload buffer. v128 spans 2 u64 slots (low 8 bytes, high
/// 8 bytes); all other v0.1 types fit in 1 slot. `exnref` is
/// rejected as a tag param at module-load (v0.1 scope; tags do
/// not carry exnref payloads — the unwinder handles exnref
/// reification separately per ADR-0120 D6).
///
/// Used both by `Runtime.init` to pre-size `eh_payload` and by
/// the per-arch throw/catch emit paths to compute the slot
/// offset for the i-th param.
pub fn slotCountForValType(v: zir.ValType) u32 {
    return switch (v) {
        .v128 => 2,
        .i32, .i64, .f32, .f64, .ref => 1,
    };
}

/// Per-instance interpreter state. Owns linear memory + globals
/// (heap-backed); operand and frame stacks are inline.
pub const Runtime = struct {
    /// Allocator that backs every runtime-owned slice (memory,
    /// globals, tables.refs, elems, func_entities, dropped flags).
    /// In the c_api path this is the per-instance arena allocator
    /// (per ADR-0014 §2.2 / 6.K.2) — `Runtime.deinit`'s `free` calls
    /// then degrade to no-ops and the arena reclaims everything
    /// uniformly when `Instance.arena.deinit()` runs at instance
    /// teardown. Tests may pass `testing.allocator` directly when
    /// they manage their own slices; `deinit` then performs real
    /// frees.
    alloc: Allocator,
    /// Optional back-pointer to the owning `c_api/instance.Instance`,
    /// stored as `?*anyopaque` to keep Zone 1 (`src/runtime/`) free
    /// of any Zone 3 import. Used by §9.6 / 6.K.3 cross-module
    /// dispatch to recover the source instance from a FuncEntity's
    /// runtime back-ref. Not consulted on the hot path.
    instance: ?*anyopaque = null,
    /// Linear-memory bytes for memory 0 (legacy single-memory
    /// shortcut). Pointer-alias of `memories[0].bytes` once
    /// `memories.len > 0`; the invariant is enforced by
    /// `setMemory0Bytes` (always go through it when mutating).
    /// Multi-memory (`memories.len > 1`) is still rejected at
    /// instantiate per ADR-0111 D2 until 10.M-3 wires MemArg
    /// memidx through codegen.
    memory: []u8 = &.{},
    /// Per-memory runtime descriptors (Wasm 3.0 §5.4.6
    /// multi-memory data shape, ADR-0111 D2). **Pointer-per-entry**
    /// (D-199) so a cross-module imported memory ALIASES the
    /// exporter's live `*MemoryInstance`: `memory.grow` reallocs the
    /// shared instance's `bytes` and every importer sees it (a copied
    /// slice would go stale after the exporter grows). `memories[0]`
    /// mirrors `memory` (the legacy memory0 byte alias).
    memories: []*MemoryInstance = &.{},
    /// Backing storage for this instance's OWN (defined) memory
    /// instances (D-199). `memories[i]` points here for defined
    /// memories; imported entries point at the exporter's
    /// `memory_storage` instead (shared). deinit frees this (the owned
    /// values) + the `memories` pointer array — mirrors
    /// `globals_storage` / `globals`.
    memory_storage: []MemoryInstance = &.{},
    /// Module global slots. **Pointer-per-entry** so cross-module
    /// global imports alias the source instance's storage (per
    /// ADR-0014 §2.1 / 6.K.3). Defined globals point at slots in
    /// `globals_storage`; imported globals point at the source
    /// instance's slot. global.get / global.set dereference.
    globals: []*Value = &.{},
    /// Owning storage for **defined** globals. Imported globals
    /// alias source storage and don't touch this slice. Arena-
    /// owned in the c_api path; tests construct in-place.
    globals_storage: []Value = &.{},
    /// Module function table — `funcs[i]` is the ZirFunc for the
    /// i-th function in the module's index space (imports first,
    /// then defined). The `call` handler indexes into this; the
    /// runner sets it before invoking the entry function.
    funcs: []const *const zir.ZirFunc = &.{},
    /// Parallel-to-`funcs` FuncEntity array (Wasm 2.0 funcref
    /// encoding per ADR-0014 §2.1 / 6.K.1). `ref.func i` /
    /// element-segment init resolve to `&func_entities[i]` and
    /// store its address in `Value.ref`. `call_indirect` reverses
    /// the cast to recover the source runtime + func_idx.
    /// Allocated in `instantiateRuntime` on the per-instance
    /// arena; tests construct stub slices directly.
    func_entities: []FuncEntity = &.{},
    /// Parallel-to-`funcs` host-call table. When the dispatch
    /// loop's `call` op routes to index `i` and `host_calls[i]`
    /// is non-null, the host thunk runs instead of dispatching
    /// the ZirFunc body. Length 0 (empty) when no imports
    /// resolved through the binding.
    host_calls: []const ?HostCall = &.{},
    /// Module data segments. Borrowed; the runner keeps the
    /// decoded data alive for as long as `Runtime` references it.
    /// Used by `memory.init` (Wasm 2.0 §9.2 / 2.3 chunk 4b).
    datas: []const []const u8 = &.{},
    /// Per-segment dropped flag. `data.drop` flips entries here so
    /// later `memory.init` calls trap. Owned (heap-allocated when
    /// `datas.len > 0`); freed in deinit.
    data_dropped: []bool = &.{},
    /// Module tables (Wasm 2.0 §9.2 / 2.3 chunks 5c / 5c-2).
    /// Mutable so `table.grow` can swap a TableInstance's `refs`
    /// slice header for a longer one. The owner of each refs
    /// slice (typically the runner / test setup) is responsible
    /// for using the same allocator that grow ends up reallocating
    /// against (`rt.alloc`) and for freeing the final slice after
    /// runtime tear-down.
    tables: []TableInstance = &.{},
    /// Module element segments resolved to runtime ref values
    /// (Wasm 2.0 §9.2 / 2.3 chunk 5d-2). Borrowed; the runner
    /// translates funcidxs from the decoded ElementSegment into
    /// these slices at instantiation time.
    elems: []const []const Value = &.{},
    /// Per-segment dropped flag for `elem.drop`. Owned (heap-
    /// allocated when `elems.len > 0`); freed in deinit.
    elem_dropped: []bool = &.{},
    /// Module type section. `call_indirect` reads expected
    /// signatures here at runtime to raise
    /// IndirectCallTypeMismatch when the table cell's resolved
    /// callee disagrees. Borrowed by the runner.
    module_types: []const zir.FuncType = &.{},
    /// Wasm 3.0 EH (10.E-N-2): per-tag param count, pre-resolved
    /// from `module.tags[i].typeidx → module_types[typeidx].params.len`
    /// at module setup time. Indexed by `tag_idx`. `throwOp` reads
    /// `tag_param_counts[tag_idx]` to pop that many operand values
    /// into the exception payload stash before walking the catch
    /// vec. Default `&.{}`: existing tests / runners that don't
    /// thread tags through see length-0 → throwOp pops 0 (safe
    /// fallback). Validator's `Error.InvalidTagIndex` rejects
    /// out-of-range `throw` at compile time, so the runtime side
    /// never sees a tag_idx past the populated length when the
    /// production pipeline has populated this field.
    tag_param_counts: []const u32 = &.{},

    /// Wasm 3.0 EH tag identity table (ADR-0114 D1; 10.E-eh-tail).
    /// Parallel to `tag_param_counts`: one `*TagInstance` per tag in
    /// the instance's tag index space (imported tags first, then
    /// defined). Imported slots alias the source instance's
    /// `*TagInstance` (cross-module pointer identity); defined slots
    /// are freshly allocated. throw stamps `exc.tag = tags[tag_idx]`;
    /// catch matches `tags[catch_tag_idx] == exc.tag`. Default `&.{}`
    /// (non-EH modules); throw only occurs in EH modules where this
    /// is populated.
    tags: []const *TagInstance = &.{},

    /// Wasm 3.0 EH (10.E-payload-prop Cycle 1; ADR-0120 D1+D5+D6)
    /// — JIT payload staging region. Written by JIT throw sites
    /// (each pops N slots and stores them via
    /// `[runtime_ptr + eh_payload_ptr_off + i*8]`), read by JIT
    /// catch landing pads (each loads back N slots, pushes as
    /// fresh vregs onto the catch block's operand stack).
    ///
    /// Slot encoding (ADR-0120 D5):
    ///   - i32 / i64 / f32 / f64 / funcref / externref → 1 slot
    ///   - v128 → 2 slots (low 8 bytes at `i`, high at `i+1`)
    ///   - exnref → rejected at module-load as tag param (v0.1 scope)
    ///
    /// Slice is pre-sized at `Runtime.init` to
    /// `sum(slot_count(tag.params))` over the module's tag
    /// section, so:
    ///   - No magic cap (the original ADR-0120 draft had `[16]u64`).
    ///   - Throw-site bounds are validated at module-load, not
    ///     runtime.
    ///   - The slice pointer is stable for Runtime lifetime;
    ///     JIT can literal-pool it once per compile.
    ///
    /// Cycle 1 (this commit): field shape + module-load slot
    /// count sum. Currently unread by emit code — Cycle 2 wires
    /// throw.emit writes; Cycle 3 wires try_table.emit
    /// landing-pad reads.
    eh_payload: []u64 = &.{},
    /// EH payload length (slot count from
    /// `tag_param_slot_counts[tag_idx]` at the most recent
    /// throw site). See `eh_payload`.
    eh_payload_len: u32 = 0,
    /// Slot-count-per-tag table (ADR-0120 D5). Same shape as
    /// `tag_param_counts` but counts SLOTS not PARAMS — v128
    /// contributes 2 slots, all other v0.1 types contribute 1.
    /// Indexed by `tag_idx`. Read by JIT throw / catch emit;
    /// runtime size sum lives in `eh_payload.len`.
    tag_param_slot_counts: []const u32 = &.{},

    /// Wasm 3.0 EH (10.E-5d / 10.E-exnref-a) — in-flight exception
    /// slot for cross-frame unwind. `throwOp` allocates an
    /// `Exception` heap object (tracked in `live_exceptions` for
    /// `deinit` cleanup), writes the pointer here, then walks the
    /// local frame's catch vec; on a local-frame match the slot is
    /// cleared and dispatch proceeds. On no local match the slot
    /// stays set and `Trap.UncaughtException` propagates; the
    /// `invoke()` helper catches the trap post-popFrame and retries
    /// `findAndDispatchCatch` against the caller's frame, repeating
    /// up the frame stack until either a catch fires or the trap
    /// escapes the top-level invocation. Treated as a thread-local-
    /// equivalent slot per ADR-0114 D6's "zwasm_throw trampoline"
    /// design (interp variant: in-process slot vs codegen's
    /// per-thread storage). `catch_all_ref` / `catch_ref` dispatch
    /// reads the slot's pointer to push the exnref value on the
    /// catch target's stack.
    pending_exception: ?*Exception = null,

    /// Wasm 3.0 EH (10.E-exnref-a) — Exception heap objects
    /// allocated by `throwOp` for the lifetime of this Runtime.
    /// Freed at `deinit`. The naive "leak until Runtime end"
    /// strategy is sufficient for the pre-GC milestones; the
    /// final GC-managed exnref reachability lands at 10.G when
    /// `Collector` walks `exnref`-typed roots per ADR-0117 I1.
    live_exceptions: std.ArrayList(*Exception) = .empty,
    /// Dispatch table used by the active interp run. Set by
    /// `src/interp/dispatch.zig`'s `run`; the `call` handler
    /// needs it to recursively dispatch the callee body.
    table: ?*const dispatch_table.DispatchTable = null,

    /// Wasm 3.0 tail-call signal (D-187 discharge per ROADMAP §10
    /// row 10.TC "interp trampoline" scope). `return_call` /
    /// `return_call_indirect` / `return_call_ref` handlers set
    /// this to the resolved callee + mark the current frame
    /// `done`; `src/interp/dispatch.zig::run`'s trampoline loop
    /// reads the signal after the inner instr loop exits, pops
    /// the caller frame, pops args off the operand stack into
    /// freshly-alloc'd callee locals, pushes the callee frame,
    /// and continues iterating WITHOUT recursing into Zig. The
    /// previous shape (returnCallOp → mvp.invoke → dispatch.run
    /// recursion) mirrored Wasm tail-call depth onto the host
    /// call stack and tripped `Trap.CallStackExhausted` at
    /// `max_frame_stack = 256` for self-recursive count(N≥256).
    pending_tail_call: ?*const zir.ZirFunc = null,

    /// 10.G-foundation cycle 5 (ADR-0115 §1 zero-overhead gate).
    /// Per-Store GC heap slab — non-null iff
    /// `Module.needs_gc_heap` was true at parse-time. When null,
    /// GC heap allocation + collector vtable + root walk all
    /// skip; when non-null, instantiate materialised a `*Heap`
    /// via `setupGcHeap` and `Runtime.deinit` releases it back
    /// to the parent allocator. Future cycles add
    /// `gc_collector: ?Collector` alongside (cycle 6) and the
    /// op_gc.zig dispatch consumers (post-foundation).
    gc_heap: ?*heap_mod.Heap = null,

    operand_buf: [max_operand_stack]Value = undefined,
    operand_len: u32 = 0,

    frame_buf: [max_frame_stack]Frame = undefined,
    frame_len: u32 = 0,

    /// D-288 / ADR-0167: cached native-stack low limit for the interp's
    /// deep-recursion guard. `null` until lazily computed on the first
    /// `checkNativeStackLimit` (captures the RUNNING thread's stack);
    /// `0` once computed means the platform query is unsupported →
    /// the check is skipped and `frame_buf[256]` is the only guard.
    native_stack_limit: ?usize = null,

    /// ADR-0179 #3a: cooperative interruption flag, host-owned (lives on the
    /// Engine/Instance; set from any thread for timeout/cancellation). `null`
    /// = no interruption configured → zero hot-path cost (the optional unwrap
    /// is one predictable branch). Polled unconditionally at function entry
    /// (`checkInterrupt`) and throttled on the interp loop back-edge
    /// (`dispatch.run`, every `INTERRUPT_CHECK_MASK + 1` steps) so a tight
    /// `(loop (br 0))` with no calls is still interruptible.
    interrupt: ?*std.atomic.Value(u32) = null,
    /// Owned, stable storage for the interruption flag (ADR-0179 #3a-2). The
    /// per-instance Runtime is heap-allocated (`Instance.runtime: ?*Runtime`),
    /// so `&rt.interrupt_flag_storage` is a stable address the host can set
    /// from any thread (`Instance.interrupt()`) and the JIT can hold a pointer
    /// to (JitRuntime, #3a-3). Wired by pointing `interrupt` at it once the
    /// Runtime is at its final heap address (`api/instance.zig`). Default 0.
    interrupt_flag_storage: std.atomic.Value(u32) = .{ .raw = 0 },
    /// Free-running step counter for the throttled loop-back-edge poll above.
    interrupt_tick: u64 = 0,

    /// ADR-0179 #3c: host-imposed max linear-memory size in PAGES (of memory 0's
    /// page size), an extra cap BELOW the module's declared max — `null` = no
    /// host limit. Folded into `growMemory`'s page-cap min, so `memory.grow`
    /// past it returns the spec grow-failure (`-1` / previous size unchanged),
    /// NOT a trap. (JIT path = `MemGrowCtx.max_pages`, clamped at setup — #3c-2.)
    store_memory_pages_max: ?u64 = null,

    /// ADR-0179 / D-316: host-imposed max table size in ELEMENTS, an extra cap
    /// below the module's declared table max — `null` = no host limit. Folded
    /// into `table.grow`'s cap check, so a grow past it returns the spec
    /// grow-failure (`-1` / previous size unchanged), NOT a trap. Applies to
    /// every table in the instance. (Interp/facade path; the JIT table-grow cap
    /// is a documented post-v0.1 enhancement, like fuel.)
    store_table_elements_max: ?u64 = null,

    /// ADR-0179 #3b: host-imposed deterministic instruction budget — remaining
    /// fuel, decremented once per executed interp instruction; trap `OutOfFuel`
    /// at 0. `null` = unmetered (zero hot-path cost: one predictable optional
    /// unwrap per instruction). Set/read via the facade `Instance.setFuel`/
    /// `fuelRemaining`. This field is the INTERP engine's cell; the JIT keeps
    /// its own (`JitRuntime.fuel_cell`, armed via `JitInstance.setFuel`, units =
    /// poll-site crossings). The facade and `zwasm_instance_set_fuel` route to
    /// whichever engine backs the instance, so both are reachable from a host.
    fuel: ?u64 = null,

    /// Optional per-instruction trace hook (Phase 6 / §9.6 / 6.A
    /// per ADR-0013). When non-null, `dispatch.step` invokes
    /// `trace_cb(trace_ctx, event)` after each handler call.
    /// Zero-cost when null.
    trace_cb: ?TraceCallback = null,
    trace_ctx: ?*anyopaque = null,

    pub fn init(alloc: Allocator) Runtime {
        return .{ .alloc = alloc };
    }

    /// Update memory 0's backing bytes while keeping the
    /// `memory` ↔ `memories[0].bytes` pointer-alias invariant
    /// (ADR-0111 D2). Use at every `rt.memory = X` mutation
    /// site; when `memories.len == 0` (test setups that don't
    /// drive the full instantiate path) only `memory` is
    /// updated — the invariant `memories[0].bytes == memory`
    /// holds vacuously.
    pub fn setMemory0Bytes(self: *Runtime, bytes: []u8) void {
        self.memory = bytes;
        if (self.memories.len >= 1) {
            self.memories[0].bytes = bytes;
        }
    }

    /// Wasm spec §4.4.7 (memory.grow) — grow the memory at `memidx` by
    /// `delta` pages (64 KiB each), zero-filling the new region and
    /// preserving the `memory ↔ memories[0].bytes` alias (D-199).
    /// Returns the previous page count on success, or `null` when the
    /// growth is refused: the declared/spec page cap is exceeded, an
    /// arithmetic overflow occurs, or the host allocator fails. The
    /// interp `memory.grow` handler and the Zig facade `Memory.grow`
    /// both route here so the cap + realloc + alias logic has a single
    /// home (mirrors the introspection-reuses-decoder pattern).
    pub fn growMemory(self: *Runtime, memidx: usize, delta: u64) ?u64 {
        // Custom-page-sizes (ADR-0168 v0.2): page size = 1 << page_size_log2
        // (default 64 KiB). memory.size/grow + the page cap are in units of
        // this. The scaffold fallback (memidx 0 via `self.memory`, no
        // `memories` entry) keeps the 64 KiB default.
        const page_size: u64 = if (memidx < self.memories.len)
            @as(u64, 1) << @intCast(self.memories[memidx].page_size_log2)
        else
            65536;
        const target_bytes: []u8 = if (memidx < self.memories.len)
            self.memories[memidx].bytes
        else if (memidx == 0)
            self.memory
        else
            return null;
        const is_i64 = memidx < self.memories.len and self.memories[memidx].idx_type == .i64;
        const declared_pages_max: ?u64 = if (memidx < self.memories.len)
            self.memories[memidx].pages_max
        else
            null;
        const old_pages: u64 = target_bytes.len / page_size;
        // Spec page cap = byte_cap / page_size (i32 byte_cap = 2^32; i64 =
        // 2^64). With the 64 KiB default this is 2^16 // 2^48 pages; a 1-byte
        // page scales it up. u128 byte_cap avoids the i64 2^64 overflow.
        const byte_cap: u128 = if (is_i64) (@as(u128, 1) << 64) else (@as(u128, 1) << 32);
        const spec_cap: u64 = @intCast(@min(byte_cap / page_size, @as(u128, std.math.maxInt(u64))));
        const page_cap: u64 = @min(
            spec_cap,
            declared_pages_max orelse spec_cap,
            self.store_memory_pages_max orelse spec_cap, // ADR-0179 #3c host cap
        );
        const new_pages_ov = @addWithOverflow(old_pages, delta);
        if (new_pages_ov[1] != 0 or new_pages_ov[0] > page_cap) return null;
        const new_pages = new_pages_ov[0];
        const new_bytes_ov = @mulWithOverflow(new_pages, page_size);
        if (new_bytes_ov[1] != 0 or new_bytes_ov[0] > std.math.maxInt(usize)) return null;
        const new_mem: []u8 = blk: {
            // ADR-0202 D1 — guarded backing grows by committing more of the
            // reservation IN PLACE (base never moves; fresh pages OS-zeroed).
            if (memidx < self.memories.len) {
                if (self.memories[memidx].reservation) |*res| {
                    break :blk memory_backing.growGuarded(res, @intCast(new_bytes_ov[0])) orelse return null;
                }
            }
            const grown = self.alloc.realloc(target_bytes, @intCast(new_bytes_ov[0])) catch return null;
            @memset(grown[target_bytes.len..], 0);
            break :blk grown;
        };
        if (memidx == 0) {
            self.setMemory0Bytes(new_mem);
        } else {
            self.memories[memidx].bytes = new_mem;
        }
        return old_pages;
    }

    pub fn deinit(self: *Runtime) void {
        // Per ADR-0014 §2.2 / 6.K.2: all resources are arena-owned
        // in the c_api path; tests pass `testing.allocator` directly.
        //
        // Critically, this routes through `rawFree` rather than
        // `Allocator.free`. The wrapper at `Allocator.free`
        // `@memset(slice, undefined)`s the bytes (= 0xAA) BEFORE
        // delegating to the underlying allocator's `rawFree` — and
        // that poisoning lands on the *bytes themselves*. For arena
        // allocators whose `rawFree` is the no-op trailing-shrink
        // check, that means a cross-module import that aliased the
        // source instance's memory slice would see its bytes
        // overwritten with 0xAA whenever any importer's runtime
        // tears down. `rawFree` skips the wrapper's poisoning, so
        // arena-owned slices stay intact while testing.allocator-
        // owned slices still release without leaking.
        // ADR-0202 D1 — guarded backings are reservation-owned: release
        // the OWN storage's reservations (imported entries are released
        // by their exporter) and skip the allocator free for a guarded
        // memory0 alias (the allocator never saw those bytes).
        //
        // INVARIANT: NEVER dereference `self.memories[i]` here — the
        // pointer array may hold cross-module ZOMBIE pointers into an
        // already-deinited exporter's storage at teardown (ADR-0014
        // §6.K.2; Windows CI SEGV in the component-model corpus).
        // Guardedness of the memory0 alias is decided by pointer
        // identity against OWN storage (alive until the rawFree below);
        // an imported memory0 alias keeps the legacy rawFree (arena
        // no-op — identical to the pre-guarded semantics).
        var memory0_guarded = false;
        for (self.memory_storage) |*m| {
            if (m.reservation) |res| {
                if (m.bytes.ptr == self.memory.ptr) memory0_guarded = true;
                guarded_mem.release(res);
            }
        }
        if (!memory0_guarded) rawFreeOwned(self.alloc, u8, self.memory);
        // D-199 — free the pointer array + the OWNED instance storage.
        // Imported entries point into the exporter's `memory_storage`
        // (freed by the exporter), so freeing our own storage is correct.
        rawFreeOwned(self.alloc, *MemoryInstance, self.memories);
        rawFreeOwned(self.alloc, MemoryInstance, self.memory_storage);
        rawFreeOwned(self.alloc, *Value, self.globals);
        rawFreeOwned(self.alloc, Value, self.globals_storage);
        rawFreeOwned(self.alloc, bool, self.data_dropped);
        rawFreeOwned(self.alloc, bool, self.elem_dropped);
        // Wasm 3.0 EH (10.E-exnref-a): free per-throw Exception heap
        // objects. Arena allocators no-op the destroy; testing /
        // standalone allocators release them here.
        for (self.live_exceptions.items) |exc| self.alloc.destroy(exc);
        self.live_exceptions.deinit(self.alloc);
        // 10.G-foundation cycle 5: release the GC heap if
        // instantiate materialised one. Arena-owned in the c_api
        // path so `Heap.deinit` is the no-op slice-release; the
        // `destroy(*Heap)` releases the struct itself. testing.
        // allocator path frees the bytes too.
        if (self.gc_heap) |h| {
            h.deinit();
            self.alloc.destroy(h);
            self.gc_heap = null;
        }
    }

    pub fn pushOperand(self: *Runtime, v: Value) Trap!void {
        if (self.operand_len == max_operand_stack) return Trap.StackOverflow;
        self.operand_buf[self.operand_len] = v;
        self.operand_len += 1;
    }

    pub fn popOperand(self: *Runtime) Value {
        std.debug.assert(self.operand_len > 0);
        self.operand_len -= 1;
        return self.operand_buf[self.operand_len];
    }

    pub fn topOperand(self: *const Runtime) Value {
        std.debug.assert(self.operand_len > 0);
        return self.operand_buf[self.operand_len - 1];
    }

    pub fn pushFrame(self: *Runtime, frame: Frame) Trap!void {
        if (self.frame_len == max_frame_stack) return Trap.CallStackExhausted;
        self.frame_buf[self.frame_len] = frame;
        self.frame_len += 1;
    }

    /// D-288 / ADR-0167: trap `CallStackExhausted` at the real per-OS
    /// native stack limit BEFORE the host stack SEGVs. The interp
    /// recurses natively per wasm call; on the small (~1 MiB) Windows
    /// stack the real ceiling sits BELOW the `frame_buf[256]` guard, so
    /// without this 128–256-deep recursion crashes instead of trapping.
    /// `sp` is the caller's `@frameAddress()`. The limit is computed
    /// lazily once on the running thread; a `0` (unsupported-platform)
    /// limit disables the check, leaving `frame_buf[256]` as the guard.
    pub fn checkNativeStackLimit(self: *Runtime, sp: usize) Trap!void {
        const limit = self.native_stack_limit orelse blk: {
            const l = stack_limit_mod.computeStackLimit(stack_limit_mod.INTERP_STACK_HEADROOM);
            self.native_stack_limit = l;
            break :blk l;
        };
        if (limit != 0 and sp <= limit) return Trap.CallStackExhausted;
    }

    /// Throttle mask for the interp loop-back-edge interruption poll
    /// (ADR-0179 #3a): check the flag once per 1024 steps. Bounds the
    /// per-instruction cost while keeping cancellation latency sub-µs.
    pub const INTERRUPT_CHECK_MASK: u64 = 1023;

    /// Trap `Interrupted` if the host has raised the cooperative interruption
    /// flag (ADR-0179 #3a). No-op when no flag is configured. Called at
    /// function entry; the interp loop back-edge calls it throttled.
    pub inline fn checkInterrupt(self: *Runtime) Trap!void {
        if (self.interrupt) |flag| {
            if (flag.load(.monotonic) != 0) return Trap.Interrupted;
        }
    }

    pub fn popFrame(self: *Runtime) Frame {
        std.debug.assert(self.frame_len > 0);
        self.frame_len -= 1;
        const f = self.frame_buf[self.frame_len];
        // D-242 — free the frame's lazy label overflow (if any) and clear
        // the slot's pointer so a re-push can't double-free. The returned
        // copy's `label_overflow` is then dangling, but callers never read
        // it post-pop (they consume sig/locals/results only).
        if (f.label_overflow.len > 0) {
            self.alloc.free(f.label_overflow);
            self.frame_buf[self.frame_len].label_overflow = &.{};
        }
        return f;
    }

    pub fn currentFrame(self: *Runtime) *Frame {
        std.debug.assert(self.frame_len > 0);
        return &self.frame_buf[self.frame_len - 1];
    }

    pub fn toOpaque(self: *Runtime) *InterpCtx {
        return @ptrCast(self);
    }

    pub fn fromOpaque(p: *InterpCtx) *Runtime {
        return @ptrCast(@alignCast(p));
    }
};

// ============================================================
// Tests — Runtime / sub-file integration.
// Per-type tests live in the owning sub-files (value.zig /
// trap.zig / frame.zig).
// ============================================================

const testing = std.testing;

test "Runtime.init / deinit clean (no allocations)" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.memory.len);
    try testing.expectEqual(@as(usize, 0), r.memories.len);
    try testing.expectEqual(@as(usize, 0), r.globals.len);
    try testing.expectEqual(@as(u32, 0), r.operand_len);
    try testing.expectEqual(@as(u32, 0), r.frame_len);
}

test "Runtime.init: EH payload staging defaults (ADR-0120 10.E-payload-prop Cycle 1 revised)" {
    // ADR-0120 D1 revised (2026-05-28 cycle 90): eh_payload is a slice
    // pre-sized at instantiate; default-init Runtime has zero-length
    // slice + empty slot-count table. Module-load populates both per
    // tag section content.
    var r = Runtime.init(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(u32, 0), r.eh_payload_len);
    try testing.expectEqual(@as(usize, 0), r.eh_payload.len);
    try testing.expectEqual(@as(usize, 0), r.tag_param_slot_counts.len);
}

test "slotCountForValType: ADR-0120 D5 slot encoding" {
    // v128 spans 2 u64 slots; all other v0.1 types fit in 1.
    try testing.expectEqual(@as(u32, 1), slotCountForValType(.i32));
    try testing.expectEqual(@as(u32, 1), slotCountForValType(.i64));
    try testing.expectEqual(@as(u32, 1), slotCountForValType(.f32));
    try testing.expectEqual(@as(u32, 1), slotCountForValType(.f64));
    try testing.expectEqual(@as(u32, 1), slotCountForValType(.funcref));
    try testing.expectEqual(@as(u32, 1), slotCountForValType(.externref));
    try testing.expectEqual(@as(u32, 2), slotCountForValType(.v128));
}

test "Runtime.init: gc_heap defaults to null (10.G-foundation cycle 5; ADR-0115 §1 zero-overhead gate)" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(?*heap_mod.Heap, null), r.gc_heap);
}

test "Runtime.deinit: releases gc_heap when set (10.G-foundation cycle 5)" {
    var r = Runtime.init(testing.allocator);
    // Simulate the instantiate-side gate: create + assign a heap.
    const h = try testing.allocator.create(heap_mod.Heap);
    h.* = heap_mod.Heap.init(testing.allocator);
    _ = try h.allocate(16); // bump cursor; ensure bytes allocated
    r.gc_heap = h;
    // Round-trip: deinit should free the slab bytes (heap.deinit)
    // + the *Heap struct itself (alloc.destroy). The testing
    // allocator catches leaks on either side.
    r.deinit();
    try testing.expectEqual(@as(?*heap_mod.Heap, null), r.gc_heap);
}

test "Runtime.setMemory0Bytes: preserves memory ↔ memories[0].bytes alias (ADR-0111 D2)" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();

    // Empty memories: setMemory0Bytes updates memory only (alias
    // vacuously holds — no memories[0] to mirror).
    const stub: []u8 = &.{};
    r.setMemory0Bytes(stub);
    try testing.expectEqual(@as(usize, 0), r.memory.len);
    try testing.expectEqual(@as(usize, 0), r.memories.len);

    // Populated memories: setMemory0Bytes mirrors into memories[0].
    var inst: MemoryInstance = .{};
    const mi = try testing.allocator.alloc(*MemoryInstance, 1);
    defer testing.allocator.free(mi);
    mi[0] = &inst;
    r.memories = mi;
    const bytes = try testing.allocator.alloc(u8, 128);
    defer testing.allocator.free(bytes);
    r.setMemory0Bytes(bytes);
    try testing.expectEqual(bytes.ptr, r.memory.ptr);
    try testing.expectEqual(bytes.ptr, r.memories[0].bytes.ptr);
    try testing.expectEqual(@as(usize, 128), r.memory.len);
    try testing.expectEqual(@as(usize, 128), r.memories[0].bytes.len);
    // Re-set with a different slice: alias re-syncs.
    const bytes2 = try testing.allocator.alloc(u8, 64);
    defer testing.allocator.free(bytes2);
    r.setMemory0Bytes(bytes2);
    try testing.expectEqual(bytes2.ptr, r.memory.ptr);
    try testing.expectEqual(bytes2.ptr, r.memories[0].bytes.ptr);
    // Avoid Runtime.deinit's rawFreeOwned re-touching the stub slice.
    r.memory = &.{};
    r.memories = &.{};
}

test "Runtime: push/pop operand stack round-trip" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();

    try r.pushOperand(Value.fromI32(1));
    try r.pushOperand(Value.fromI32(2));
    try r.pushOperand(Value.fromI64(0x123456789));

    try testing.expectEqual(@as(u32, 3), r.operand_len);
    try testing.expectEqual(@as(i64, 0x123456789), r.popOperand().i64);
    try testing.expectEqual(@as(i32, 2), r.popOperand().i32);
    try testing.expectEqual(@as(i32, 1), r.popOperand().i32);
    try testing.expectEqual(@as(u32, 0), r.operand_len);
}

test "Runtime: push/pop frame stack round-trip" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();

    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    try r.pushFrame(.{
        .sig = sig,
        .locals = &.{},
        .operand_base = 0,
        .pc = 0,
    });
    try r.pushFrame(.{
        .sig = sig,
        .locals = &.{},
        .operand_base = 7,
        .pc = 42,
    });
    try testing.expectEqual(@as(u32, 2), r.frame_len);

    const f1 = r.popFrame();
    try testing.expectEqual(@as(u32, 7), f1.operand_base);
    try testing.expectEqual(@as(u32, 42), f1.pc);

    const f0 = r.popFrame();
    try testing.expectEqual(@as(u32, 0), f0.pc);
}

test "Runtime: operand-stack overflow trips StackOverflow" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();

    var i: u32 = 0;
    while (i < max_operand_stack) : (i += 1) {
        try r.pushOperand(Value.zero);
    }
    try testing.expectError(Trap.StackOverflow, r.pushOperand(Value.zero));
}

test "Runtime: frame-stack overflow trips CallStackExhausted" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();

    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    var i: u32 = 0;
    while (i < max_frame_stack) : (i += 1) {
        try r.pushFrame(.{ .sig = sig, .locals = &.{}, .operand_base = 0, .pc = 0 });
    }
    try testing.expectError(
        Trap.CallStackExhausted,
        r.pushFrame(.{ .sig = sig, .locals = &.{}, .operand_base = 0, .pc = 0 }),
    );
}

test "Runtime: native stack-limit check traps CallStackExhausted below the limit (D-288)" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();

    // Force a known limit (bypass the lazy per-thread computation).
    r.native_stack_limit = 0x4000;
    // SP at/below the limit → trap (deep recursion would SEGV here).
    try testing.expectError(Trap.CallStackExhausted, r.checkNativeStackLimit(0x100));
    try testing.expectError(Trap.CallStackExhausted, r.checkNativeStackLimit(0x4000));
    // SP comfortably above the limit → pass.
    try r.checkNativeStackLimit(0x8000);

    // A `0` (unsupported-platform) limit disables the check entirely —
    // even sp==0 passes, leaving frame_buf[256] as the sole guard.
    r.native_stack_limit = 0;
    try r.checkNativeStackLimit(0);
}

test "Runtime: checkInterrupt traps Interrupted only when the host flag is raised (ADR-0179 #3a)" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();

    // No flag configured → no-op (zero hot-path cost path).
    try r.checkInterrupt();

    var flag = std.atomic.Value(u32).init(0);
    r.interrupt = &flag;
    try r.checkInterrupt(); // flag clear → still passes

    flag.store(1, .monotonic); // host requests interruption
    try testing.expectError(Trap.Interrupted, r.checkInterrupt());

    flag.store(0, .monotonic); // cleared → passes again
    try r.checkInterrupt();
}

test "Runtime: per-frame label stack spills past the inline cap and popFrame frees it (D-242)" {
    // The validator accepts control nesting up to `zir.max_control_stack`
    // (1024); the runtime label stack MUST hold all of it. Inline capacity
    // is only `inline_label_stack` (128) — deeper frames lazily spill to a
    // heap overflow that popFrame must free (testing.allocator flags a leak
    // if it doesn't).
    var r = Runtime.init(testing.allocator);
    defer r.deinit();

    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    try r.pushFrame(.{ .sig = sig, .locals = &.{}, .operand_base = 0, .pc = 0 });
    const frame = r.currentFrame();

    const n: u32 = frame_mod.inline_label_stack + 64; // cross the inline→heap boundary
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try frame.pushLabel(r.alloc, .{ .height = i, .arity = 0, .branch_arity = 0, .target_pc = i });
    }
    try testing.expectEqual(n, frame.label_len);
    try testing.expect(frame.label_overflow.len > 0); // overflow was allocated
    try testing.expectEqual(@as(u32, n - 1), frame.labelAt(0).target_pc); // innermost = last pushed
    try testing.expectEqual(@as(u32, 0), frame.labelAt(n - 1).target_pc); // oldest = first pushed
    // a label straddling the boundary (first overflow slot) reads back correctly
    try testing.expectEqual(@as(u32, frame_mod.inline_label_stack), frame.labelAt(n - 1 - frame_mod.inline_label_stack).target_pc);

    _ = r.popFrame(); // frees label_overflow — no leak

}

test "Trap: error set carries the spec-conformant trap conditions" {
    // Compile-time spot-check that the named tags exist on the Trap
    // error set. Returning each value would discard it; storing into
    // an `anyerror` slot keeps the code path live.
    const traps: [9]anyerror = .{
        Trap.Unreachable,              Trap.DivByZero,
        Trap.IntOverflow,              Trap.InvalidConversionToInt,
        Trap.OutOfBoundsLoad,          Trap.OutOfBoundsStore,
        Trap.OutOfBoundsTableAccess,   Trap.UninitializedElement,
        Trap.IndirectCallTypeMismatch,
    };
    try testing.expectEqual(@as(usize, 9), traps.len);
}
