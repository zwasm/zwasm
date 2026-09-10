// FILE-SIZE-EXEMPT: ADR-0079 Step-1 carve-out (RuntimeOwned + setupRuntime, one deep op); further split forces N2 (investigated 2026-08-12, per ADR-0099)
// AUTO-EXTRACTED from src/engine/runner.zig at ADR-0079 Step 1 (close-plan §6 (g)).
// Carve-out: `RuntimeOwned` + `setupRuntime` + `hostDispatchTrap`. Re-export
// from runner.zig keeps the public surface stable.
//
// Zone 2 (`src/engine/`); same import boundaries as runner.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

const parser = @import("../parse/parser.zig");
const sections = @import("../parse/sections.zig");
const jit_dispatch = @import("../wasi/jit_dispatch.zig");
const entry = @import("codegen/shared/entry.zig");
const linker = @import("codegen/shared/linker.zig");
const canonical_type = @import("codegen/shared/canonical_type.zig");
const rv = @import("runner_validate.zig");
const zir = @import("../ir/zir.zig");

const runner_mod = @import("runner.zig");
const instantiate = @import("../runtime/instance/instantiate.zig");
const memory_backing = @import("../runtime/instance/memory_backing.zig");
const guarded_mem = @import("../platform/guarded_mem.zig");
const heap_mod = @import("../feature/gc/heap.zig");
const gc_type_info = @import("../feature/gc/type_info.zig");
const needs_heap_detector = @import("../feature/gc/needs_heap_detector.zig");
const shared_thunk = @import("codegen/shared/thunk.zig");
const jit_mem = @import("../platform/jit_mem.zig");
const dbg = @import("../support/dbg.zig");
const Error = runner_mod.Error;
const CompiledWasm = runner_mod.CompiledWasm;

/// D-225 — resolved target for a cross-module FUNC import, in func-import
/// order. `callee_entry`/`callee_rt` come from the EXPORTER `JitInstance`
/// (its `module.entryAddr(funcidx)` + `&owned.rt`); the importer setup
/// emits a cohort-safe bridge thunk (ADR-0066 `emitThunk`) into its own
/// thunk arena and plants the slot in `dispatch[func_import_idx]`. A
/// zero `callee_entry` = unresolved (slot stays `hostDispatchTrap`).
///
/// ADR-0228 — `sig` is the CALLEE's signature, filled by the exporter from
/// its own `func_sigs` (the module that defines the function, whichever
/// module re-exported it on the way). The bridge thunk needs it to lay out
/// what the ABI does not pass in registers (#390); it borrows the exporter's
/// compile arena, which lives as long as the exporter (see
/// `JitInstance.exportedFuncTarget`). Empty when unresolved.
pub const FuncImportTarget = struct {
    callee_rt: usize = 0,
    callee_entry: usize = 0,
    sig: zir.FuncType = .{ .params = &.{}, .results = &.{} },
};

/// D-478 — a resolved EMBEDDER host-func import (`wasm_func_new`), in
/// func-import order. `dispatch_ptr` is the comptime host-bridge thunk
/// (`api/jit_host_bridge.zig`) for this slot+signature; `payload` is
/// `@intFromPtr(*api.HostFuncPayload)` planted into `host_payloads[idx]` for the
/// thunk to read. Both are opaque `usize` to setup (Zone 2) — the Zone-3 caller
/// resolves coverage. A zero `dispatch_ptr` = uncovered (handled by the caller
/// rejecting the JIT instantiate, so it never reaches here).
pub const HostFuncTarget = struct {
    idx: u32,
    dispatch_ptr: usize,
    payload: usize,
};

/// ADR-0134 D3 — resolved identity for a cross-module TAG import, in
/// tag-import order. `source_id` is the EXPORTER instance's
/// globally-comparable tag identity for the imported tag (its
/// `tag_ids[exported_tag_idx]`, an address-derived token per ADR-0114
/// D7 pointer-identity). The importer's setup writes this id into its
/// own `tag_ids[import_idx]` so a cross-module throw and catch compare
/// equal. A zero `source_id` = unresolved → the importer falls back to
/// a local within-module identity (preserves Cause A aliasing).
pub const TagImportTarget = struct {
    source_id: u64 = 0,
};

pub const RuntimeOwned = struct {
    rt: entry.JitRuntime,
    // Linear memory is owned by a pinned heap `MemGrowCtx` (reached via
    // `rt.host_state`) so `memory.grow` can realloc-move the backing
    // buffer and have BOTH the JIT (`rt.vm_base` reload) and `deinit` see
    // the current pointer (RuntimeOwned itself moves by value into
    // JitInstance, so a field pointer here would dangle). D-215.
    mem_ctx: ?*MemGrowCtx = null,
    dispatch: []usize,
    globals: []@import("../runtime/value.zig").Value,
    funcptrs: []u64,
    typeidxs: []u32,
    // §9.9 / 9.9-m-1b: per-module FuncEntity array backing JIT
    // `ref.func`. JIT computes `&func_entities[idx]` for each
    // ref.func op; only the address matters for ref.is_null /
    // ref.eq / select_typed [funcref] semantics. Struct contents
    // (FuncEntity.runtime, .func_idx) are not exercised on this
    // code path (no full Runtime; interp uses its own allocation).
    func_entities: []@import("../runtime/instance/func.zig").FuncEntity,
    // §9.9 / 9.9-m-3a: parallel data/elem segment "dropped"
    // flag arrays. bool stored as u8 (matches extern struct
    // layout the JIT expects).
    data_dropped: []u8,
    elem_dropped: []u8,
    // §9.9 / 9.9-m-3b: per-data-segment SegmentSlice descriptors
    // backing JIT `memory.init`. Each entry's `ptr` aliases the
    // module's parsed `.data` section bytes (held by the caller
    // via `wasm_bytes`); the lifetime contract is that
    // `wasm_bytes` outlives `RuntimeOwned` (callers pass module
    // bytes that persist across the call).
    data_segments: []entry.SegmentSlice,
    // §9.9 / 9.9-m-2a: per-table descriptors + contiguous refs
    // arena backing JIT `table.get` / `table.set` / `table.size`.
    // `tables_descriptors[k].refs` points into `table_refs`; the
    // two slices have matching lifetimes (both freed at deinit).
    tables_descriptors: []entry.TableSlice,
    table_refs: []u64,
    // §9.9 / 9.9-m-2c-init: per-element-segment ElemSlice descriptors
    // + contiguous u64 arena holding the pre-computed funcref values.
    elem_segments: []entry.ElemSlice,
    elem_refs: []u64,
    // §9.9 / 9.9-l-1b-d093-d42 (D-112): per-table call_indirect
    // dispatch descriptors + extra (non-table-0) funcptr/typeidx
    // arena. Table 0's TableJitCallInfo entry reuses `funcptrs` /
    // `typeidxs` above; tables 1..N point into the contiguous
    // `extra_funcptrs` / `extra_typeidxs` arenas via per-table
    // offsets computed at setup time.
    tables_jit_ci: []entry.TableJitCallInfo,
    extra_funcptrs: []u64,
    extra_typeidxs: []u32,
    // 10.G GC-on-JIT: dedicated arena holding the per-run GC Heap +
    // GcTypeInfos (rt.gc_heap / gc_type_infos_ptr alias into it).
    // Null for non-GC modules. One arena.deinit frees the slab + the
    // materialised type table.
    gc_arena: ?*std.heap.ArenaAllocator = null,
    // D-225 — per-instance JIT-capable arena holding the cross-module
    // bridge thunks (one slot per resolved func import); `dispatch[N]`
    // points into it. Null when the module has no resolved func imports.
    thunk_arena: ?jit_mem.JitBlock = null,
    // ADR-0134 D3 — per-instance tag-identity map (`tag_ids`) + its
    // address-token backing (`tag_tokens`, one cell per tag whose address
    // is a defined tag's unique identity). Empty when the module imports
    // no tags. Both freed here; the heap backing is stable across the
    // by-value RuntimeOwned move so the token addresses in `tag_ids` hold.
    tag_ids: []u64 = &.{},
    tag_tokens: []u8 = &.{},
    // D-327 (ADR-0120 D6) — exnref reify context (allocator + Exception
    // tracker). Heap-allocated so the by-value RuntimeOwned move (D-215)
    // doesn't dangle the self-referential pointer in `rt.eh_reify_ctx`.
    eh_reify_ctx: ?*entry.EhReifyCtx = null,
    // D-478 — per-func-import `*HostFuncPayload` backing array (each entry an
    // `@intFromPtr`), aliased by `rt.host_payloads_base`. Heap-owned so the ptr
    // stays valid across the by-value RuntimeOwned move (like `dispatch`). Empty
    // when the module has no embedder host-func imports.
    host_payloads: []usize = &.{},

    pub fn deinit(self: *RuntimeOwned, allocator: Allocator) void {
        if (self.eh_reify_ctx) |c| {
            c.deinit();
            allocator.destroy(c);
        }
        if (self.thunk_arena) |arena| shared_thunk.freeArena(arena);
        if (self.gc_arena) |a| {
            a.deinit();
            allocator.destroy(a);
        }
        if (self.mem_ctx) |c| {
            // The ctx OWNS the (possibly grown) linear-memory buffer —
            // free the CURRENT pointer (memory.grow realloc-moves it).
            // Guarded backing (ADR-0202 D1): release the reservation
            // instead — the allocator never saw those bytes.
            if (c.reservation) |res|
                guarded_mem.release(res)
            else if (c.memory.len > 0) allocator.free(c.memory);
            allocator.destroy(c);
        }
        allocator.free(self.dispatch);
        allocator.free(self.globals);
        allocator.free(self.funcptrs);
        allocator.free(self.typeidxs);
        if (self.func_entities.len > 0) allocator.free(self.func_entities);
        if (self.data_dropped.len > 0) allocator.free(self.data_dropped);
        if (self.elem_dropped.len > 0) allocator.free(self.elem_dropped);
        if (self.data_segments.len > 0) allocator.free(self.data_segments);
        allocator.free(self.tables_descriptors);
        allocator.free(self.table_refs);
        if (self.elem_segments.len > 0) allocator.free(self.elem_segments);
        if (self.elem_refs.len > 0) allocator.free(self.elem_refs);
        allocator.free(self.tables_jit_ci);
        if (self.extra_funcptrs.len > 0) allocator.free(self.extra_funcptrs);
        if (self.extra_typeidxs.len > 0) allocator.free(self.extra_typeidxs);
        if (self.tag_ids.len > 0) allocator.free(self.tag_ids);
        if (self.tag_tokens.len > 0) allocator.free(self.tag_tokens);
        if (self.host_payloads.len > 0) allocator.free(self.host_payloads);
    }
};

/// Host-side context for `memory.grow` (D-215). Pinned on the heap; a
/// pointer lives in `JitRuntime.host_state` so the C-ABI `jitMemoryGrow`
/// trampoline can realloc the buffer. Owns the linear-memory slice (freed
/// by `RuntimeOwned.deinit`).
pub const MemGrowCtx = struct {
    allocator: Allocator,
    memory: []u8,
    /// ADR-0202 D1 — non-null when `memory` is guard-page
    /// reservation-backed: grow commits in place (base never moves)
    /// and deinit releases the reservation instead of freeing.
    reservation: ?guarded_mem.Reservation = null,
    max_pages: u64,
    /// ADR-0179 #3c-2 / D-314 — host-imposed page cap BELOW the declared/spec
    /// `max_pages` (JIT mirror of the facade `setMemoryPagesLimit`). null =
    /// no host cap. Grow past it returns the spec failure (-1), not a trap.
    host_max_pages: ?u64 = null,
};

/// Real `memory_grow_fn` (replaces `defaultMemoryGrowReject`). Grows the
/// linear memory by `delta_pages`, returning the OLD page count or -1 on
/// failure (max exceeded / OOM) — Wasm `memory.grow` semantics. Reallocs
/// the backing buffer (may move it) and updates `rt.vm_base` + `rt.mem_limit`
/// so the JIT body's post-call base reload sees the new buffer (arm64
/// reloads X28/X27; x86_64 reloads per-access). D-215.
///
/// Note: the trampoline ABI returns i32. memory64 `memory.grow` yields i64;
/// the -1 failure sentinel needs the result sign-extended to i64 at the call
/// site (D-215 Part B) — success values (old page count) fit i32 here.
pub fn jitMemoryGrow(rt: *entry.JitRuntime, delta_pages: u32) callconv(.c) i32 {
    const ctx: *MemGrowCtx = @ptrCast(@alignCast(rt.host_state orelse return -1));
    // Custom-page-sizes (ADR-0168 v0.2): page = 1 << memory0's page_size_log2
    // (default 64 KiB). ctx.max_pages is in these same page units.
    const page: u64 = @as(u64, 1) << @intCast(rt.mem0_page_size_log2);
    const old_len = ctx.memory.len;
    const old_pages = old_len / page;
    const new_pages = old_pages + @as(u64, delta_pages);
    if (new_pages > ctx.max_pages) return -1;
    // ADR-0179 #3c-2 / D-314 — host cap below the declared/spec max.
    if (ctx.host_max_pages) |cap| if (new_pages > cap) return -1;
    const new_bytes: usize = std.math.cast(usize, new_pages * page) orelse return -1;
    const grown: []u8 = if (ctx.reservation) |*res|
        // ADR-0202 D1 — commit-in-place: base never moves, fresh pages
        // OS-zeroed (the post-grow vm_base reload is now a no-op reload).
        memory_backing.growGuarded(res, new_bytes) orelse return -1
    else blk: {
        const g = ctx.allocator.realloc(ctx.memory, new_bytes) catch return -1;
        @memset(g[old_len..new_bytes], 0);
        break :blk g;
    };
    ctx.memory = grown;
    rt.vm_base = grown.ptr;
    rt.mem_limit = new_bytes;
    return @bitCast(@as(u32, @truncate(old_pages)));
}

/// D-497 (ADR-0201) — shared `table.grow` core. Grows table `tableidx` by `delta`,
/// filling new slots with `init` (Value.ref-encoded u64) and returning the OLD size
/// (or -1 on failure). No realloc: setup pre-allocates each table's `refs` arena (and,
/// for funcref tables, the funcptr/typeidx mirrors) up to its capacity (`.max`), so
/// growth fills pre-allocated slots + bumps `.len` in place (table.get reads it fresh,
/// so no JIT base reload, unlike memory.grow). For a funcref table the parallel
/// funcptr/typeidx views are filled: null init → funcptr 0 + sentinel typeidx (a later
/// `call_indirect` traps cleanly); non-null init → if `resolve` (GUEST path: `init` is
/// a real `*FuncEntity`) read `fe.funcptr`/`fe.typeidx` (matching `emitTableSet`'s LDR
/// mirror), else (HOST path: `init` may be a forged ref) clear to the sentinel
/// (fail-safe, mirrors `tableSetRef`; a callable grown slot then needs `wasm_table_set`).
fn jitTableGrowCore(rt: *entry.JitRuntime, tableidx: u32, init: u64, delta: u64, resolve: bool) i64 {
    const FuncEntity = @import("../runtime/instance/func.zig").FuncEntity;
    const Value = @import("../runtime/value.zig").Value;
    if (tableidx >= rt.tables_count) return -1;
    const descs: [*]entry.TableSlice = @constCast(rt.tables_ptr);
    const d = &descs[tableidx];
    const old_len = d.len;
    // Overflow-safe (D-475): a table64 delta is a raw u64 from the
    // wasm stack, so `old_len + delta` can wrap.
    const new_len: u64 = std.math.add(u64, old_len, delta) catch return -1;
    if (new_len > d.max) return -1; // exceeds pre-allocated capacity (= .max)
    // D-314(b): host sandbox cap on total table elements — a guest cannot
    // grow past `store_table_elements_max` even within the static descriptor
    // max. Mirrors the interp table.grow handler (instantiate.zig) so the
    // sandbox triad's table leg is cross-engine. maxInt sentinel = unlimited.
    if (new_len > rt.store_table_elements_max) return -1;
    const is_funcref = @intFromPtr(d.funcptrs) != 0;
    // typeidx mirror reached via tables_jit_ci_ptr (NO TableSlice layout change).
    const typeidx_base: ?[*]u32 = if (is_funcref and tableidx < rt.tables_jit_ci_count)
        @constCast(rt.tables_jit_ci_ptr[tableidx].typeidx_base)
    else
        null;
    var i: u64 = old_len;
    while (i < new_len) : (i += 1) {
        d.refs[i] = init;
        if (!is_funcref) continue;
        var fp: u64 = 0;
        var ti: u32 = std.math.maxInt(u32);
        if (init != Value.null_ref and resolve) {
            const fe: *const FuncEntity = @ptrFromInt(@as(usize, @intCast(init)));
            fp = fe.funcptr;
            ti = fe.typeidx;
        }
        d.funcptrs[i] = fp;
        if (typeidx_base) |tb| tb[i] = ti;
    }
    d.len = new_len;
    // D-497: table 0's `call_indirect` fast path bounds-checks against the scalar
    // `rt.table_size` snapshot (not `d.len`); bump it so a grown table-0 slot is
    // reachable. Tables k>0 read `tables_ptr[k].len` directly (jit_abi helper).
    if (tableidx == 0) rt.table_size = new_len;
    return @bitCast(old_len);
}

/// GUEST `table_grow_fn` (replaces `defaultTableGrowReject`) — `init` from the wasm
/// stack is a real funcref/externref, so funcref native-entry resolution is safe.
pub fn jitTableGrow(rt: *entry.JitRuntime, tableidx: u32, init: u64, delta: u64) callconv(.c) i64 {
    return jitTableGrowCore(rt, tableidx, init, delta, true);
}

/// HOST C-API `table.grow` (`growTable` facade) — `init` is a host `*Ref` whose
/// payload may be forged, so never dereference it as a `*FuncEntity` (fail-safe).
pub fn jitTableGrowHost(rt: *entry.JitRuntime, tableidx: u32, init: u64, delta: u64) i64 {
    return jitTableGrowCore(rt, tableidx, init, delta, false);
}

/// Build a JitRuntime + populate its host_dispatch table + init
/// linear memory from data segments. Shared between `runI32Export`
/// and `runVoidExport`. The caller owns the returned `memory` and
/// `dispatch` slices via `RuntimeOwned.deinit`.
pub fn setupRuntime(
    allocator: Allocator,
    compiled: *const CompiledWasm,
    wasm_bytes: []const u8,
) Error!RuntimeOwned {
    return setupRuntimeLinked(allocator, compiled, wasm_bytes, &.{}, &.{}, &.{}, &.{});
}

/// D-225 — `setupRuntime` + cross-module imported-global resolution. The
/// importing module's setup-time const-expr evals (defined-global init +
/// table explicit-init-expr) can `global.get N` an IMPORTED global; the
/// caller (spec runner / linker) passes the resolved import values in
/// import order via `imported_global_vals` so e.g. `(ref.i31 (global.get
/// $env.g))` reads 42 instead of nothing. Plain `setupRuntime` passes `&.{}`
/// (no imports). Emitted-code `global.get` of an import is a SEPARATE gap
/// (the JIT global model excludes import slots — see D-225 survey).
pub fn setupRuntimeLinked(
    allocator: Allocator,
    compiled: *const CompiledWasm,
    wasm_bytes: []const u8,
    imported_global_vals: []const u64,
    func_import_targets: []const FuncImportTarget,
    tag_import_targets: []const TagImportTarget,
    host_func_targets: []const HostFuncTarget,
) Error!RuntimeOwned {
    const dispatch = try allocator.alloc(usize, compiled.num_imports);
    errdefer allocator.free(dispatch);
    for (dispatch) |*slot| slot.* = @intFromPtr(&hostDispatchTrap);
    // D-225 — cross-module FUNC import bridge thunks land here (set below).
    var thunk_arena: ?jit_mem.JitBlock = null;
    errdefer if (thunk_arena) |a| shared_thunk.freeArena(a);

    var memory: []u8 = &.{};
    // ADR-0202 D1 — non-null when `memory` is guard-page reservation-backed
    // (qualifying i32/64KiB memory0): grow commits in place, free = release.
    var mem_reservation: ?guarded_mem.Reservation = null;
    errdefer if (mem_reservation) |res|
        guarded_mem.release(res)
    else if (memory.len > 0) allocator.free(memory);
    // D-215 — memory.grow upper bound (pages). Declared max if present,
    // else the spec address-space limit per idx_type. 0 = no memory section.
    var mem_max_pages: u64 = 0;
    // ADR-0168 — memory0 shared flag, surfaced to the JIT rt so the
    // `memory.atomic.wait*` callout can trap on a non-shared memory.
    var mem_shared: bool = false;
    // ADR-0168 v0.2 — memory0 page_size_log2 (custom-page-sizes), surfaced
    // to the JIT rt for memory.size's variable shift + jitMemoryGrow.
    var mem_page_size_log2: u32 = 16;

    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try parser.parse(ta, wasm_bytes);

    const Value = @import("../runtime/value.zig").Value;

    var num_func_imports: u32 = 0;
    // ADR-0134 D3 — imported-tag count + a within-module aliasing map
    // (representative tag-import index per imported tag, ta-owned). Two
    // tag imports with the same (module,name) bind one source tag, so the
    // later collapses onto the earlier (Cause A). Consumed below to seed
    // local identity tokens for any import the caller did not resolve.
    var imp_tag_count: u32 = 0;
    var imp_local_canon: []u32 = &.{};
    // Decode the import section whenever it exists — tag imports must be
    // counted even when `num_imports` (the dispatch-table = func-import
    // count) is 0, e.g. a module that imports only tags.
    if (module.find(.import)) |s| {
        var imports_buf = try sections.decodeImports(ta, s.body);
        defer imports_buf.deinit();
        if (compiled.num_imports > 0) jit_dispatch.populateDispatch(dispatch, imports_buf.items);
        for (imports_buf.items) |it| {
            switch (it.kind) {
                .func => num_func_imports += 1,
                .tag => imp_tag_count += 1,
                .table, .memory, .global => {},
            }
        }
        if (imp_tag_count > 0) {
            const canon = try ta.alloc(u32, imp_tag_count);
            var ti: u32 = 0;
            for (imports_buf.items, 0..) |it, i| {
                if (it.kind != .tag) continue;
                canon[ti] = ti;
                var tj: u32 = 0;
                for (imports_buf.items[0..i]) |prev| {
                    if (prev.kind != .tag) continue;
                    if (std.mem.eql(u8, prev.module, it.module) and
                        std.mem.eql(u8, prev.name, it.name))
                    {
                        canon[ti] = tj;
                        break;
                    }
                    tj += 1;
                }
                ti += 1;
            }
            imp_local_canon = canon;
        }
    }

    // ADR-0134 D3 — full-space tag-identity map (imported ++ defined),
    // built whenever the module has ≥1 tag (imported OR defined). A
    // defined tag's identity is the address of its own `tag_tokens` cell
    // (unique per instance — the JIT analog of ADR-0114 D7's
    // `*TagInstance` pointer); an exporter exposes this via
    // `exportedTagTarget` so an importer can inherit it. An IMPORTED tag
    // takes the EXPORTER's id when the caller resolved it
    // (`tag_import_targets`), else the local token of its (module,name)
    // representative (Cause A aliasing within the module). Defined-only
    // modules still get a map (token-equality == index-equality, so EH
    // behaviour is unchanged) so their exported tags have a stable
    // identity to hand out. `null` only when the module has no tags at
    // all → raw-index comparison. Both arrays are allocator-owned (freed
    // via RuntimeOwned); token addresses stay valid across the by-value
    // RuntimeOwned move (the backing heap does not move).
    var tag_ids: []u64 = &.{};
    errdefer if (tag_ids.len > 0) allocator.free(tag_ids);
    var tag_tokens: []u8 = &.{};
    errdefer if (tag_tokens.len > 0) allocator.free(tag_tokens);
    {
        const defined_tags: []const sections.TagEntry = if (module.find(.tag)) |ts|
            try sections.decodeTags(ta, ts.body)
        else
            &.{};
        const total_tags: usize = @as(usize, imp_tag_count) + defined_tags.len;
        if (total_tags > 0) {
            const tokens = try allocator.alloc(u8, total_tags);
            errdefer allocator.free(tokens);
            const ids = try allocator.alloc(u64, total_tags);
            errdefer allocator.free(ids);
            for (0..imp_tag_count) |k| {
                const src: u64 = if (k < tag_import_targets.len) tag_import_targets[k].source_id else 0;
                if (src != 0) {
                    ids[k] = src;
                } else {
                    const rep = if (k < imp_local_canon.len) imp_local_canon[k] else @as(u32, @intCast(k));
                    ids[k] = @intFromPtr(&tokens[rep]);
                }
            }
            for (imp_tag_count..total_tags) |k| ids[k] = @intFromPtr(&tokens[k]);
            tag_tokens = tokens;
            tag_ids = ids;
        }
    }
    // D-225 — cross-module FUNC dispatch: for each func import the caller
    // resolved to an exporter JitInstance, emit a cohort-safe bridge thunk
    // (ADR-0066 `emitThunk`: swap runtime_ptr→callee_rt, BLR/CALL callee_entry,
    // RET) into a per-instance arena and plant the slot in `dispatch[N]`
    // (func-import-indexed). Without this an imported-func call hits
    // `hostDispatchTrap`. allocArena flips this thread writable (Mac per-thread
    // W^X) → finalizeArena flips back; nothing executes in between.
    if (func_import_targets.len > 0 and num_func_imports > 0) {
        var any_resolved = false;
        for (func_import_targets) |t| {
            if (t.callee_entry != 0) any_resolved = true;
        }
        if (any_resolved) {
            const arena = try shared_thunk.allocArena(num_func_imports);
            thunk_arena = arena;
            for (func_import_targets, 0..) |t, j| {
                if (j >= num_func_imports or t.callee_entry == 0) continue;
                const slot = shared_thunk.thunkSlot(arena, j);
                shared_thunk.emitThunk(slot, t.callee_rt, t.callee_entry);
                dispatch[j] = @intFromPtr(slot.ptr);
            }
            try shared_thunk.finalizeArena(arena);
        }
    }

    // D-478 — plant embedder host-func dispatch. Each target's `dispatch_ptr`
    // is the comptime host-bridge thunk (resolved + coverage-checked by the
    // Zone-3 caller); `host_payloads[idx]` carries the `*HostFuncPayload` the
    // thunk reads via `rt.host_payloads_base`. Heap-owned (freed at deinit) so
    // the base ptr survives the by-value RuntimeOwned move (D-215).
    var host_payloads: []usize = &.{};
    errdefer if (host_payloads.len > 0) allocator.free(host_payloads);
    if (host_func_targets.len > 0 and compiled.num_imports > 0) {
        const payloads = try allocator.alloc(usize, compiled.num_imports);
        @memset(payloads, 0);
        for (host_func_targets) |t| {
            if (t.idx >= compiled.num_imports or t.dispatch_ptr == 0) continue;
            dispatch[t.idx] = t.dispatch_ptr;
            payloads[t.idx] = t.payload;
        }
        host_payloads = payloads;
    }

    if (module.find(.memory)) |s| {
        var memories = try sections.decodeMemory(ta, s.body);
        defer memories.deinit();
        if (memories.items.len > 0) {
            const mem0 = memories.items[0];
            // Custom-page-sizes (ADR-0168 v0.2): initial bytes = min ×
            // (1 << page_size_log2). Default 64 KiB; a 1-byte page makes
            // min a byte count. The 256 MiB cap stays in BYTES (host guard).
            const page_size: u64 = @as(u64, 1) << @intCast(mem0.page_size_log2);
            const min_pages: u64 = mem0.min;
            const total_bytes: u64 = min_pages * page_size;
            if (total_bytes > 256 * 1024 * 1024) {
                return Error.UnsupportedEntrySignature;
            }
            const backing = try memory_backing.allocBacking(
                allocator,
                @intCast(total_bytes),
                mem0.idx_type,
                mem0.page_size_log2,
            );
            memory = backing.bytes;
            mem_reservation = backing.reservation;
            // D-215 — grow ceiling: declared max, else the spec page limit.
            // Custom-page-sizes (ADR-0168 v0.2): the page cap = byte_cap /
            // page_size (i32 byte_cap 2^32 → 2^16 pages at 64 KiB, 2^32 at
            // 1 byte; i64 byte_cap 2^64). u128 avoids the i64 overflow.
            mem_max_pages = mem0.max orelse blk: {
                const byte_cap: u128 = if (mem0.idx_type == .i64) (@as(u128, 1) << 64) else (@as(u128, 1) << 32);
                break :blk @intCast(@min(byte_cap / page_size, @as(u128, std.math.maxInt(u64))));
            };
            mem_shared = mem0.shared;
            mem_page_size_log2 = mem0.page_size_log2;
        }
    }

    if (module.find(.data)) |s| {
        var datas = try sections.decodeData(ta, s.body);
        defer datas.deinit();
        for (datas.items) |seg| {
            if (seg.kind != .active) continue;
            // D-219 — accepts i64.const offsets for memory64. `off_u >
            // memory.len` first so `off_u + len` can't overflow u64.
            const off_u = rv.evalConstOffsetU64(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
            if (off_u > memory.len or off_u + seg.bytes.len > memory.len) {
                return Error.UnsupportedEntrySignature;
            }
            @memcpy(memory[@intCast(off_u)..][0..seg.bytes.len], seg.bytes);
        }
    }

    // Decode globals + tables for placeholder arrays. Realistic
    // values are needed because fixtures' JIT bodies reach for
    // global.get / call_indirect bodies that reference these
    // offsets even when the bounds check would short-circuit
    // — `globals_base = undefined` previously caused 0xaaaa...
    // segfaults in the realworld corpus invocation path.
    var globals_count: u32 = 0;
    var decoded_globals: ?sections.Globals = null;
    defer if (decoded_globals) |*g| g.deinit();
    if (module.find(.global)) |s| {
        decoded_globals = try sections.decodeGlobals(ta, s.body);
        globals_count = @intCast(decoded_globals.?.items.len);
    }
    // D-225 — the emitted-code global layout (`computeGlobalsLayout`) is
    // import-inclusive: global index space = imports first, then defined.
    // So `globals_buf` must reserve the import slots; otherwise an emitted
    // `global.get $defined` (index ≥ num_global_imports) reads OOB past the
    // defined-only buffer (gc/i31.4: i31ref defined global → null → trap).
    var num_global_imports: u32 = 0;
    if (module.find(.import)) |s| {
        var imps = try sections.decodeImports(ta, s.body);
        defer imps.deinit();
        for (imps.items) |it| {
            if (it.kind == .global) num_global_imports += 1;
        }
    }
    const globals_total: u32 = num_global_imports + globals_count;
    // §9.9 / 9.9-m-2a: parse the table section into per-table
    // descriptors. `table_size` is retained as the table-0 entry
    // count (call_indirect's `funcptrs_buf` + `typeidxs_buf` are
    // table-0-only specialisations); the new `tables_descs` array
    // generalises this to all declared tables for `table.get` /
    // `table.set` / `table.size` (m-2a) and later m-2b/c ops.
    var table_size: u64 = 0;
    // `init_expr` (D-225): Wasm 3.0 table-with-explicit-init-expr
    // (`0x40 0x00 reftype limits constexpr`) — raw const-expr bytes for the
    // initial element value (empty = default null fill). Slices into the
    // table section body (ta-owned, outlives `tables_buf.deinit`).
    // min/max are u64 per D-475: a table64 declares u64 limits (spec §5.3.5).
    const TableMeta = struct { min: u64, max: ?u64, is_funcref: bool, init_expr: []const u8 };
    var table_metas: []TableMeta = &.{};
    if (module.find(.table)) |s| {
        var tables_buf = try sections.decodeTables(ta, s.body);
        defer tables_buf.deinit();
        if (tables_buf.items.len > 0) {
            table_size = tables_buf.items[0].min;
            table_metas = try ta.alloc(TableMeta, tables_buf.items.len);
            for (tables_buf.items, 0..) |t, i| {
                table_metas[i] = .{ .min = t.min, .max = t.max, .is_funcref = (t.elem_type.isFuncref()), .init_expr = t.init_expr };
            }
        }
    }
    // D-331(A): no arbitrary globals/table-size cap here. `globals_buf`,
    // `funcptrs_buf` and `typeidxs_buf` are all allocator-backed (sized to
    // the declared counts below), so the old 4096 ceiling was a pure early-
    // dev guard, NOT a fixed-array dependency — and it diverged from the
    // interp, which allocates `min` table cells uncapped (instantiate.zig).
    // Real toolchains exceed it (Go/wasip1 declares a ~5790-entry funcref
    // table), so the cap rejected them as UnsupportedEntrySignature on the
    // JIT path only. The cross-engine DoS bound on eager table allocation is
    // the sandbox knob `RunLimits.max_table_elements` (D-332), enforced as an
    // early-reject in `runner.runWasiLenient` BEFORE this eager alloc (mirrors
    // the interp eager-alloc cap) — not an asymmetric hard reject here.

    const globals_buf = try allocator.alloc(Value, if (globals_total == 0) 1 else globals_total);
    errdefer allocator.free(globals_buf);
    @memset(globals_buf, .{ .bits128 = 0 });
    // Fill the imported-global slots [0..num_global_imports) with the
    // resolved values (D-225); the defined globals land at the offset below.
    for (0..num_global_imports) |i| {
        globals_buf[i] = .{ .bits64 = if (i < imported_global_vals.len) imported_global_vals[i] else 0 };
    }
    // D-225 / #397 — `[]*Value` view of every global slot, in index order,
    // for the setup-time const-expr evals' `global.get N`: a prefix of it is
    // the window §3.3.13.1 gives each expression. ta-allocated: read only
    // during setup.
    const global_ptrs: []const *Value = blk: {
        const ptrs = try ta.alloc(*Value, globals_total);
        for (ptrs, 0..) |*p, i| p.* = &globals_buf[i];
        break :blk ptrs;
    };

    // 10.G GC-on-JIT (ADR-0128 §2): materialise the GC heap + type table
    // for modules with a GC type section BEFORE the global-init loop, so
    // gc const-expr globals (struct.new / array.new) can allocate into it
    // (D-223). The JIT struct.new* / jitGcAlloc trampoline shares this
    // slab. All GC allocations live in a dedicated arena (freed at deinit).
    var gc_arena: ?*std.heap.ArenaAllocator = null;
    var gc_heap_typed: ?*heap_mod.Heap = null;
    var gc_type_infos_typed: ?*gc_type_info.GcTypeInfos = null;
    errdefer if (gc_arena) |a| {
        a.deinit();
        allocator.destroy(a);
    };
    // gti is materialised for GC-heap modules AND func-only-subtyping modules
    // (`sub` / `sub final` func types with no heap objects) — the latter still
    // need the supertype-chain / canonical-id / finality table for a correct
    // JIT `call_indirect` subtype check (D-235; mirrors the interp D-232 fix in
    // instantiate.zig). ADR-0115 zero-overhead preserved via the cheap
    // `mayUseTypeSubtyping` byte pre-filter.
    if (module.needs_gc_heap or needs_heap_detector.mayUseTypeSubtyping(&module)) {
        if (module.find(.type)) |ts| {
            const ga = try allocator.create(std.heap.ArenaAllocator);
            ga.* = std.heap.ArenaAllocator.init(allocator);
            const gaa = ga.allocator();
            var gc_types = try sections.decodeTypes(ta, ts.body);
            defer gc_types.deinit();
            if (module.needs_gc_heap or needs_heap_detector.usesTypeSubtyping(gc_types)) {
                gc_arena = ga; // claim for errdefer cleanup; freed at deinit
                const gti = try gaa.create(gc_type_info.GcTypeInfos);
                // v128 struct/array fields are deferred (ADR-0116 §3a) — map to
                // the runI32Export "unsupported shape" error rather than widen
                // the runner Error set with a GC-internal variant.
                gti.* = gc_type_info.materialiseGcTypes(gaa, gc_types) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.UnsupportedFieldSize => return error.UnsupportedEntrySignature,
                };
                const heap = try gaa.create(heap_mod.Heap);
                heap.* = heap_mod.Heap.init(gaa);
                gc_heap_typed = heap;
                gc_type_infos_typed = gti;
            } else {
                // Byte pre-filter false-positive (a coincidental 0x50/0x4F byte):
                // no real subtyping + no heap → free the arena so non-subtyping
                // modules keep zero GC overhead (ADR-0115).
                ga.deinit();
                allocator.destroy(ga);
            }
        }
    }
    const gc_heap_ptr: ?*anyopaque = gc_heap_typed;
    const gc_type_infos_ptr: ?*anyopaque = gc_type_infos_typed;

    // Build `func_entities` BEFORE the global-init loop so `ref.func N`
    // const-expr globals resolve to a non-null funcref (`&func_entities[N]`)
    // rather than the D-223 placeholder null (D-225 sub-fix: ref_func
    // `is_null-v` etc.). Only depends on `dispatch` + `compiled` + `module`
    // (all built above); the element-section loop below also consumes it.
    const FuncEntity = @import("../runtime/instance/func.zig").FuncEntity;
    const total_funcs = compiled.func_sigs.len;
    const func_entities = try allocator.alloc(FuncEntity, total_funcs);
    errdefer allocator.free(func_entities);
    var fe_canon_types: ?sections.Types = null;
    defer if (fe_canon_types) |*t| t.deinit();
    if (module.find(.type)) |ts| fe_canon_types = try sections.decodeTypes(ta, ts.body);
    for (func_entities, 0..) |*fe, i| {
        const f_off = compiled.module.func_offsets[i];
        const funcptr: usize = if (f_off == linker.IMPORT_SENTINEL_OFFSET)
            (if (i < dispatch.len) dispatch[i] else 0)
        else
            @intFromPtr(compiled.module.block.bytes.ptr + f_off);
        const raw_ti = compiled.func_typeidxs[i];
        const canon_ti: u32 = if (fe_canon_types) |t| canonical_type.canonicalTypeidx(t.items, raw_ti) else raw_ti;
        fe.* = .{ .runtime = undefined, .func_idx = @intCast(i), .typeidx = canon_ti, .funcptr = funcptr, .raw_typeidx = raw_ti };
        // Runtime entry address for `ZWASM_DEBUG=jit.dump` — pairs the
        // body-relative bytes (compile.zig) with the absolute address so an
        // lldb breakpoint at `addr + (asm_line-1)*4` (arm64) can value-trace a
        // miscompile. Skipped for import sentinels (no JIT body).
        if (f_off != linker.IMPORT_SENTINEL_OFFSET and dbg.on("jit.dump")) {
            std.debug.print("[jit.dump] func={d} runtime_addr=0x{x}\n", .{ i, funcptr });
        }
    }

    // Evaluate each defined global's init-expr so e.g. `__stack_pointer`
    // holds its real value. This simplified setup previously left globals
    // at 0, which made shadow-stack modules' `SP - n` wrap to a huge OOB
    // address → trap (surfaced by the rust_data realworld fixture: real
    // rustc/clang -O code spills to the shadow stack). Non-const inits
    // (rare in these fixtures) fall back to 0. GC const-exprs (struct.new /
    // array.new) reach `evalGlobalInitGc` via the UnsupportedConstExpr
    // fallback and allocate on the heap materialised above (D-223). D-225:
    // `func_entities` (built above) now resolves `ref.func` globals to a
    // non-null funcref.
    if (decoded_globals) |g| {
        const gti_val: ?gc_type_info.GcTypeInfos = if (gc_type_infos_typed) |t| t.* else null;
        for (g.items, 0..) |gd, i| {
            // Defined globals follow the import slots (D-225) to match the
            // import-inclusive emitted-code layout.
            // §3.3.13.1 — the init may read the imports and the globals
            // defined before it, all evaluated by now.
            const readable = global_ptrs[0 .. num_global_imports + i];
            globals_buf[num_global_imports + i] = instantiate.evalConstExprValue(gd.init_expr) catch |e| blk: {
                if (e == error.UnsupportedConstExpr) {
                    break :blk instantiate.evalGlobalInitGc(gd.init_expr, gc_heap_typed, gti_val, func_entities, readable) catch |e2| {
                        // A real GC-heap resource trap (the 4 GiB cap — e.g. a
                        // too-large `array.new` const-expr, D-472) must FAIL
                        // instantiation, matching the interp path
                        // (instantiateRuntime propagates OutOfHeap). Only a
                        // genuinely-unsupported const-expr SHAPE falls back to a
                        // 0 global (D-473). Mapped to OutOfMemory (OutOfHeap is
                        // not in the engine Error set; both = resource failure).
                        if (e2 == error.OutOfHeap) return error.OutOfMemory;
                        break :blk .{ .bits128 = 0 };
                    };
                }
                break :blk .{ .bits128 = 0 };
            };
        }
    }

    // D-497 / ADR-0201 — grow-headroom pre-allocation. Per-table capacity =
    // declared max capped at `grow_cap`, never below min. The baked-base JIT
    // can't realloc a slice, so growable tables are pre-allocated to this
    // capacity. Funcref tables follow the SAME rule, so their funcptr/typeidx
    // mirrors get headroom for grown slots' native-entry resolution.
    //
    // D-501 — a table declared WITHOUT a max used to get min-only headroom (=
    // never grows under the JIT), stricter than every senior runtime surveyed
    // (wasmtime/wasmer/wazero realloc + reload base per access; WAMR bakes the
    // base like us but still SYNTHESIZES a default cap). So a no-max table now
    // gets a synthesized cap `max(min*2, 1024)` (1024 mirrors WAMR's
    // WASM_TABLE_MAX_SIZE), bounded by `grow_cap`. Unbounded no-max grow would
    // need per-access base reload (D-501 tier 2, build-on-demand).
    const grow_cap: u64 = 65536;
    const growCapacity = struct {
        fn f(tm: anytype, cap: u64) u64 {
            const eff_max = tm.max orelse @max(tm.min *| 2, @as(u64, 1024));
            return @max(tm.min, @min(eff_max, cap));
        }
    }.f;
    const table0_cap: u64 = if (table_metas.len > 0) growCapacity(table_metas[0], grow_cap) else table_size;

    const funcptrs_buf = try allocator.alloc(u64, if (table0_cap == 0) 1 else table0_cap);
    errdefer allocator.free(funcptrs_buf);
    @memset(funcptrs_buf, 0);
    const typeidxs_buf = try allocator.alloc(u32, if (table0_cap == 0) 1 else table0_cap);
    errdefer allocator.free(typeidxs_buf);
    // Sentinel `maxInt(u32)` for "no function in this slot" — the
    // JIT-emitted call_indirect type-check `cmp w16, #expected`
    // never matches this, so an unset slot traps cleanly via the
    // bounds_fixups path instead of through a NULL `blr`.
    @memset(typeidxs_buf, std.math.maxInt(u32));

    // §9.9 / 9.9-m-2a (per ADR-0058): generalised per-table storage.
    // Each declared table gets a `TableSlice` descriptor with `refs`
    // pointing into a single contiguous `table_refs` arena. Each
    // entry is `Value.ref`-encoded u64 (FuncEntity pointer for
    // funcref, host handle for externref, or `null_ref` sentinel).
    // Initialised to `null_ref`; the element-section loop below
    // mirrors writes from `funcptrs_buf` into the corresponding
    // `table_refs` slot (using the FuncEntity-ptr encoding, NOT
    // the native-code-ptr encoding used by `funcptrs_buf`).
    // D-224 / D-497 (ADR-0201) — table.grow capacity: pre-allocate tables up to
    // their declared `max` (capped) so `jitTableGrow` bumps `.len` into pre-
    // allocated slots without realloc (the shared arena can't realloc one slice).
    // `growCapacity` (defined above) now covers funcref tables too — their
    // funcptr/typeidx mirrors are sized to the same capacity, so a grown funcref
    // slot has room for its resolved native entry. `.max` = this capacity so the
    // grow fn's cap-check == the actual pre-allocated size.
    var total_table_refs: usize = 0;
    for (table_metas) |tm| total_table_refs += growCapacity(tm, grow_cap);
    const tables_descs = try allocator.alloc(entry.TableSlice, if (table_metas.len == 0) 1 else table_metas.len);
    errdefer allocator.free(tables_descs);
    const table_refs = try allocator.alloc(u64, if (total_table_refs == 0) 1 else total_table_refs);
    errdefer allocator.free(table_refs);
    @memset(table_refs, Value.null_ref);
    // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    {
        var ref_offset: usize = 0;
        for (table_metas, 0..) |tm, i| {
            const fp_init: [*]allowzero u64 = if (tm.is_funcref) funcptrs_buf.ptr else @ptrFromInt(0);
            const cap = growCapacity(tm, grow_cap);
            tables_descs[i] = .{
                .refs = table_refs.ptr + ref_offset,
                .len = tm.min,
                // D-224 / D-497: `.max` = pre-allocated capacity (funcref included
                // now). A no-max table has cap == min → grow rejected (no headroom).
                .max = cap,
                .funcptrs = fp_init,
            };
            ref_offset += cap;
        }
        if (table_metas.len == 0) {
            tables_descs[0] = .{
                .refs = table_refs.ptr,
                .len = 0,
                .max = entry.table_no_max,
                .funcptrs = funcptrs_buf.ptr,
            };
        }
    }

    // D-225 — Wasm 3.0 table-with-explicit-init-expr
    // (`(table N M reftype constexpr)`): the const-expr value initialises
    // ALL `min` slots (setup previously left them null → `table.get` of an
    // i31ref/ref table trapped on i31.get/use). evalConstExprValue handles
    // ref.null/numeric; evalGlobalInitGc handles ref.i31 / ref.func /
    // struct.new / array.new (with the heap + func_entities built above).
    // `global.get` in the init-expr reads an imported global only — the
    // scope §3.3.13.1 gives a table init, and the one `compileWasm` judged
    // it against; evaluation gets the same prefix (PR #428 review).
    {
        const gti_val: ?gc_type_info.GcTypeInfos = if (gc_type_infos_typed) |t| t.* else null;
        for (table_metas, 0..) |tm, i| {
            if (tm.init_expr.len == 0) continue;
            const v = instantiate.evalConstExprValue(tm.init_expr) catch
                instantiate.evalGlobalInitGc(tm.init_expr, gc_heap_typed, gti_val, func_entities, global_ptrs[0..num_global_imports]) catch continue;
            // A table init-expr always yields a reftype; `.ref` (== `.bits64`
            // offset in the extern union) holds the ref-encoded u64.
            const raw: u64 = v.ref;
            const d = tables_descs[i];
            var k: u64 = 0;
            while (k < tm.min) : (k += 1) d.refs[k] = raw;
        }
    }

    // §9.9 / 9.9-l-1b-d093-d42 (D-112): per-table call_indirect
    // dispatch (table 0 reuses funcptrs/typeidxs; k>0 → extras).
    var extra_total_slots: usize = 0;
    if (table_metas.len > 1) {
        for (table_metas[1..]) |tm| extra_total_slots += growCapacity(tm, grow_cap); // D-497: grow headroom
    }
    const tables_jit_ci_buf = try allocator.alloc(entry.TableJitCallInfo, if (table_metas.len == 0) 1 else table_metas.len);
    errdefer allocator.free(tables_jit_ci_buf);
    const extra_funcptrs_buf = try allocator.alloc(u64, if (extra_total_slots == 0) 1 else extra_total_slots);
    errdefer allocator.free(extra_funcptrs_buf);
    @memset(extra_funcptrs_buf, 0);
    const extra_typeidxs_buf = try allocator.alloc(u32, if (extra_total_slots == 0) 1 else extra_total_slots);
    errdefer allocator.free(extra_typeidxs_buf);
    @memset(extra_typeidxs_buf, std.math.maxInt(u32));
    {
        tables_jit_ci_buf[0] = .{ .funcptr_base = funcptrs_buf.ptr, .typeidx_base = typeidxs_buf.ptr };
        if (table_metas.len > 1) {
            var off: usize = 0;
            for (table_metas[1..], 1..) |tm, k| {
                tables_jit_ci_buf[k] = .{
                    .funcptr_base = extra_funcptrs_buf.ptr + off,
                    .typeidx_base = extra_typeidxs_buf.ptr + off,
                };
                // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
                if (tm.is_funcref) tables_descs[k].funcptrs = extra_funcptrs_buf.ptr + off;
                off += growCapacity(tm, grow_cap); // D-497: stride by grow capacity
            }
        }
    }
    // Per-table starting offsets into extra_funcptrs/typeidxs.
    // 16-table cap → fixed stack array; over-cap modules trap.
    if (table_metas.len > 16) return Error.UnsupportedEntrySignature;
    var extra_offs: [16]usize = [_]usize{0} ** 16;
    if (table_metas.len > 1) {
        var off: usize = 0;
        for (table_metas[1..], 1..) |tm, k| {
            extra_offs[k] = off;
            off += growCapacity(tm, grow_cap); // D-497: stride by grow capacity (matches the jit_ci loop)
        }
    }

    // §9.9 / 9.9-m-1b: per-module FuncEntity array, allocated
    // above the element-section loop so the loop populates refs
    // (FuncEntity-ptr) in the same pass as funcptrs_buf.
    // Wasm spec §4.5.7 (table.init / element-segment instantiation)
    // — populate the table with funcref entries from the element
    // section. Without this, `call_indirect` loads a NULL funcptr
    // and SEGVs at PC=0 (D-049 root cause). Active segments only;
    // passive / declarative segments live in the runtime element
    // index space, not the table itself, and reach the runtime via
    // `table.init` ops which v0.1.0's JIT path doesn't emit yet.
    //
    // §9.9 / 9.9-m-2a: the same loop populates `tables_descs[k].refs`
    // (`table_refs` arena slice) with `Value.fromFuncRef` encoding
    // (`@intFromPtr(&func_entities[fidx])`) for JIT `table.get`.
    // `funcptrs_buf` keeps the native-code-ptr encoding for
    // `call_indirect`'s fast path; the two views are coherent at
    // setup time but diverge if `table.set` runs post-instantiation
    // (a known follow-up tracked as part of the m-2 cluster).
    if (module.find(.element)) |s| {
        var elems = try sections.decodeElement(ta, s.body);
        defer elems.deinit();
        // D-111: canonicalize typeidx so call_indirect's structural
        // FuncType match (Wasm spec §3.4.6 + §4.4.10.1) works on
        // the bytewise typeidx compare. Decode the type section
        // once for the loop.
        const canon_types_section = module.find(.type);
        var canon_types: ?sections.Types = null;
        defer if (canon_types) |*t| t.deinit();
        if (canon_types_section) |ts| {
            canon_types = try sections.decodeTypes(ta, ts.body);
        }
        // D-235: subtyping modules store the RAW typeidx (not the D-111
        // canonical) so the JIT `jitCallIndirectSubtypeOk` trampoline sees the
        // true declared identity (finality + declared super). The canonical
        // collapse is correct ONLY for non-subtyping modules, where the inline
        // structural compare stays. Must match `EmitCtx.uses_type_subtyping`
        // (both derive from the same `usesTypeSubtyping` predicate).
        const store_raw_typeidx: bool = if (canon_types) |t| needs_heap_detector.usesTypeSubtyping(t) else false;
        for (elems.items) |seg| {
            if (seg.kind != .active) continue;
            if (seg.tableidx >= tables_descs.len) continue;
            // D-475: a table64 active elem offset is an `i64.const` expr —
            // evaluate at u64 width (mirrors the interp fix @a7609a65b; the
            // i32-only eval rejected it → the .auto path silently fell back
            // to the interp). i32 offsets arrive zero-extended.
            const off = rv.evalConstOffsetU64(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
            const base: usize = std.math.cast(usize, off) orelse return Error.UnsupportedEntrySignature;
            const tbl = tables_descs[seg.tableidx];
            // Overflow-safe (D-475): `base` is a guest-chosen u64 —
            // check it against len FIRST so `base + funcidxs.len`
            // cannot wrap (mirrors the D-219 data-segment check above).
            if (base > tbl.len or base + seg.funcidxs.len > tbl.len) return Error.UnsupportedEntrySignature;
            // Wasm 3.0 GC (D-221 + D-218): an i31ref/eqref/anyref active elem
            // segment carries i31-ENCODED values in `funcidxs` (decoder:
            // i32ToI31Truncate == runtime Value.fromI31Truncate), NOT funcidxs.
            // Write them straight into `tbl.refs` (table.get returns them;
            // i31.get_{s,u} decode them) and SKIP the funcref funcptr/typeidx
            // wiring below — whose `tbl_funcptrs.len` guard wrongly rejects an
            // i31-only table (its `funcptrs_buf` isn't sized for it). The
            // discriminator mirrors the decoder's `head_ok` (abstract i31/eq/any
            // only; concrete `(ref $func)` tables still carry funcidxs).
            // (global.get-marker items [bit31] → later chunk; left null.)
            const seg_is_i31 = seg.elem_type == .ref and switch (seg.elem_type.ref.heap_type) {
                .abstract => |a| a == .i31 or a == .eq or a == .any,
                .concrete => false,
            };
            if (seg_is_i31) {
                for (seg.funcidxs, 0..) |fidx, i| {
                    if (fidx == std.math.maxInt(u32)) {
                        tbl.refs[base + i] = Value.null_ref;
                    } else if ((fidx & 0x80000000) == 0) {
                        tbl.refs[base + i] = fidx;
                    }
                }
                continue;
            }
            // §9.9 / 9.9-l-1b-d093-d42: per-table funcptr/typeidx
            // slice. Table 0 writes into the legacy flat
            // `funcptrs_buf` / `typeidxs_buf` (which back the
            // JitRuntime scalar `funcptr_base` / `typeidx_base`
            // fields); tables 1+ write into their slice within the
            // `extra_funcptrs` / `extra_typeidxs` arenas. The JIT
            // emit (arm64/x86_64 op_call.emitCallIndirect) selects
            // the right slice via `tables_jit_ci_ptr[table_idx]`.
            const is_table0 = (seg.tableidx == 0);
            const tbl_funcptrs: []u64 = if (is_table0)
                funcptrs_buf
            else
                extra_funcptrs_buf[extra_offs[seg.tableidx] .. extra_offs[seg.tableidx] + table_metas[seg.tableidx].min];
            const tbl_typeidxs: []u32 = if (is_table0)
                typeidxs_buf
            else
                extra_typeidxs_buf[extra_offs[seg.tableidx] .. extra_offs[seg.tableidx] + table_metas[seg.tableidx].min];
            if (base + seg.funcidxs.len > tbl_funcptrs.len) return Error.UnsupportedEntrySignature;
            for (seg.funcidxs, 0..) |fidx, i| {
                if (fidx == std.math.maxInt(u32)) {
                    // ref.null — leave the slot null + sentinel typeidx.
                    tbl.refs[base + i] = Value.null_ref;
                    continue;
                }
                if (fidx >= compiled.func_sigs.len) return Error.UnsupportedEntrySignature;
                tbl.refs[base + i] = @intFromPtr(&func_entities[fidx]);
                const raw_typeidx = compiled.func_typeidxs[fidx];
                tbl_typeidxs[base + i] = if (store_raw_typeidx)
                    raw_typeidx
                else if (canon_types) |t|
                    canonical_type.canonicalTypeidx(t.items, raw_typeidx)
                else
                    raw_typeidx;
                // D-586 — `func_entities` resolved this above: a body address
                // for a local function, `dispatch[fidx]` for an import, so one
                // assignment serves both and an imported table element is
                // callable. This is the same value `jitTableGrowCore` already
                // copied on the `table.set` path, so reachability stops
                // depending on how the element got here; this branch used to
                // leave the mirror null and the emit sites executed it
                // (SIGSEGV). One signature the bridge thunk cannot carry — a
                // MEMORY-class return — is still mis-called on every route,
                // including the three that already reached the thunk before
                // this line changed. D-586 (g) owns that; it is not guarded
                // here, because a guard on this write alone would leave those
                // three open.
                tbl_funcptrs[base + i] = func_entities[fidx].funcptr;
            }
        }
    }

    // §9.9 / 9.9-m-3a: data / elem segment dropped-flag arrays.
    // Each is a bool[] sized to the module's segment count;
    // initialised to false (segment not yet dropped). JIT data.drop
    // / elem.drop write byte stores; JIT memory.init (m-3b) reads
    // before computing seg_len. For modules without segments, the
    // arrays are zero-length (no allocation, ptr = undefined).
    // §9.9 / 9.9-m-3b: parallel data_segments descriptor array.
    // Each entry's `ptr` aliases the parsed module's `.data`
    // section bytes via the resident `wasm_bytes` slice — the
    // segment's `bytes` field already points into that buffer
    // (no copy). `len` is the segment's byte count; the JIT
    // overrides to 0 via the `data_dropped_ptr` flag.
    var data_dropped_count: u32 = 0;
    var data_segments_buf: []entry.SegmentSlice = &.{};
    errdefer if (data_segments_buf.len > 0) allocator.free(data_segments_buf);
    if (module.find(.data)) |s| {
        var datas_buf = try sections.decodeData(ta, s.body);
        defer datas_buf.deinit();
        data_dropped_count = @intCast(datas_buf.items.len);
        if (data_dropped_count > 0) {
            data_segments_buf = try allocator.alloc(entry.SegmentSlice, data_dropped_count);
            for (datas_buf.items, 0..) |seg, i| {
                data_segments_buf[i] = .{
                    .ptr = if (seg.bytes.len == 0) @as([*]const u8, undefined) else seg.bytes.ptr,
                    .len = seg.bytes.len,
                };
            }
        }
    }
    const data_dropped = try allocator.alloc(u8, data_dropped_count);
    errdefer allocator.free(data_dropped);
    @memset(data_dropped, 0);
    // Wasm 2.0 §4.5.5: active data segments are consumed at
    // instantiation — applyActiveDataSegments has already copied
    // their bytes into linear memory; subsequent `memory.init`
    // against them must trap on n>0 because the segment's
    // effective size is 0. Mirror of d-49's elem-segment fix.
    if (module.find(.data)) |s_drop| {
        var datas_drop = try sections.decodeData(ta, s_drop.body);
        defer datas_drop.deinit();
        for (datas_drop.items, 0..) |seg, i| {
            if (seg.kind == .active) data_dropped[i] = 1;
        }
    }

    // §9.9 / 9.9-m-2c-init: per-element-segment ElemSlice arena.
    // Each segment gets its own pre-computed `[]u64` of Value.ref
    // values (FuncEntity ptr encoding for funcref; Value.null_ref
    // for null entries). The ElemSlice descriptors point into a
    // single contiguous arena sized to the sum of all
    // seg.funcidxs.len. JIT `table.init` indexes the descriptors
    // with stride 16, reads `refs[src..src+n]`, and writes into
    // the target table's u64[] storage.
    var elem_dropped_count: u32 = 0;
    var elem_segments_buf: []entry.ElemSlice = &.{};
    errdefer if (elem_segments_buf.len > 0) allocator.free(elem_segments_buf);
    var elem_refs_arena: []u64 = &.{};
    errdefer if (elem_refs_arena.len > 0) allocator.free(elem_refs_arena);
    if (module.find(.element)) |s| {
        var elems_buf = try sections.decodeElement(ta, s.body);
        defer elems_buf.deinit();
        elem_dropped_count = @intCast(elems_buf.items.len);
        if (elem_dropped_count > 0) {
            var total_refs: usize = 0;
            // A segment carries EITHER funcidxs (funcref/i31-encoded) OR
            // item_exprs (GC general const-exprs); count whichever is present.
            for (elems_buf.items) |seg| total_refs += if (seg.item_exprs.len > 0) seg.item_exprs.len else seg.funcidxs.len;
            elem_segments_buf = try allocator.alloc(entry.ElemSlice, elem_dropped_count);
            elem_refs_arena = try allocator.alloc(u64, if (total_refs == 0) 1 else total_refs);
            const elem_gti_val: ?gc_type_info.GcTypeInfos = if (gc_type_infos_typed) |t| t.* else null;
            var off: usize = 0;
            for (elems_buf.items, 0..) |seg, i| {
                const use_items = seg.item_exprs.len > 0;
                const seg_len: u32 = @intCast(if (use_items) seg.item_exprs.len else seg.funcidxs.len);
                elem_segments_buf[i] = .{
                    .refs = elem_refs_arena.ptr + off,
                    .len = seg_len,
                };
                if (use_items) {
                    // D-225 — Wasm 3.0 GC general const-expr element items
                    // (`array.new` / `array.new_fixed` / `struct.new` / `ref.func` …).
                    // Eval each to a `Value.ref` so `array.new_elem` reads real refs
                    // (else seg_len stayed 0 → OOB trap). Mirrors the global/table
                    // init-expr eval. gc/array.8 array.new_elem depends on this.
                    for (seg.item_exprs, 0..) |ie, k| {
                        const v = instantiate.evalConstExprValue(ie) catch |e| blk: {
                            if (e == error.UnsupportedConstExpr) {
                                break :blk instantiate.evalGlobalInitGc(ie, gc_heap_typed, elem_gti_val, func_entities, global_ptrs) catch Value{ .ref = Value.null_ref };
                            }
                            break :blk Value{ .ref = Value.null_ref };
                        };
                        elem_refs_arena[off + k] = v.ref;
                    }
                    off += seg_len;
                    continue;
                }
                // D-218: i31ref/eqref/anyref elem segments carry i31-ENCODED
                // values, NOT funcidxs — store them directly (table.init reads
                // them; i31.get decodes), mirroring the active elem-init +
                // compile-time guards. Else the encoded value (e.g. (999<<1)|1)
                // trips `>= func_sigs.len` → UnsupportedEntrySignature.
                const seg_is_i31 = seg.elem_type == .ref and switch (seg.elem_type.ref.heap_type) {
                    .abstract => |a| a == .i31 or a == .eq or a == .any,
                    .concrete => false,
                };
                for (seg.funcidxs, 0..) |fidx, k| {
                    if (fidx == std.math.maxInt(u32)) {
                        elem_refs_arena[off + k] = Value.null_ref;
                    } else if (seg_is_i31) {
                        elem_refs_arena[off + k] = if ((fidx & 0x80000000) == 0) fidx else Value.null_ref;
                    } else if (fidx >= compiled.func_sigs.len) {
                        return Error.UnsupportedEntrySignature;
                    } else {
                        elem_refs_arena[off + k] = @intFromPtr(&func_entities[fidx]);
                    }
                }
                off += seg_len;
            }
        }
    }
    const elem_dropped = try allocator.alloc(u8, elem_dropped_count);
    errdefer allocator.free(elem_dropped);
    @memset(elem_dropped, 0);
    // Wasm 2.0 §4.5.4: active + declarative elem segments are
    // consumed at instantiation — their effective size becomes 0
    // for any subsequent `table.init`. Re-walk the section to
    // mark them dropped. Passive segments stay live until an
    // explicit `elem.drop`.
    if (module.find(.element)) |s_drop| {
        var elems_drop = try sections.decodeElement(ta, s_drop.body);
        defer elems_drop.deinit();
        for (elems_drop.items, 0..) |seg, i| {
            if (seg.kind != .passive) elem_dropped[i] = 1;
        }
    }

    // D-215 — pin the linear-memory buffer in a heap ctx so memory.grow
    // can realloc-move it. Owns `memory` from here on (freed via deinit).
    const mem_ctx = try allocator.create(MemGrowCtx);
    errdefer allocator.destroy(mem_ctx);
    mem_ctx.* = .{ .allocator = allocator, .memory = memory, .reservation = mem_reservation, .max_pages = mem_max_pages };

    // D-327 (ADR-0120 D6) — install the exnref reify callout unconditionally
    // (cheap; the ctx only allocates when an `_ref` catch clause actually
    // fires). Heap-allocated so the by-value RuntimeOwned move keeps the
    // `rt.eh_reify_ctx` pointer valid.
    const reify_ctx = try allocator.create(entry.EhReifyCtx);
    errdefer allocator.destroy(reify_ctx);
    reify_ctx.* = .{ .allocator = allocator };

    return .{
        .rt = .{
            .vm_base = if (memory.len > 0) memory.ptr else @ptrFromInt(@as(usize, 0x1000)),
            .mem_limit = memory.len,
            .mem0_shared = if (mem_shared) 1 else 0,
            .mem0_page_size_log2 = mem_page_size_log2,
            .host_state = mem_ctx,
            .memory_grow_fn = jitMemoryGrow,
            .reify_exnref_fn = entry.reifyExnref,
            .eh_reify_ctx = reify_ctx,
            .funcptr_base = funcptrs_buf.ptr,
            .table_size = table_size,
            .typeidx_base = typeidxs_buf.ptr,
            .trap_flag = 0,
            .globals_base = globals_buf.ptr,
            .globals_count = globals_total,
            .host_dispatch_base = dispatch.ptr,
            .host_dispatch_count = compiled.num_imports,
            // D-478 — host-func payload array base (null when no embedder
            // host-func imports); read only by the planted Zig bridge thunks.
            .host_payloads_base = if (host_payloads.len > 0) host_payloads.ptr else null,
            .func_entities_ptr = @ptrCast(func_entities.ptr),
            .func_entities_count = @intCast(total_funcs),
            .data_dropped_ptr = data_dropped.ptr,
            .data_dropped_count = data_dropped_count,
            .elem_dropped_ptr = elem_dropped.ptr,
            .elem_dropped_count = elem_dropped_count,
            .data_segments_ptr = if (data_segments_buf.len == 0) @as([*]const entry.SegmentSlice, undefined) else data_segments_buf.ptr,
            .data_segments_count = @intCast(data_segments_buf.len),
            .tables_ptr = tables_descs.ptr,
            .tables_count = @intCast(table_metas.len),
            .table_grow_fn = jitTableGrow, // D-224 (non-funcref tables)
            .elem_segments_ptr = if (elem_segments_buf.len == 0) @as([*]const entry.ElemSlice, undefined) else elem_segments_buf.ptr,
            .elem_segments_count = @intCast(elem_segments_buf.len),
            .tables_jit_ci_ptr = tables_jit_ci_buf.ptr,
            .tables_jit_ci_count = @intCast(tables_jit_ci_buf.len),
            // Phase 10.E IT-6 cycle 3c — EH dispatcher fields. The
            // trampoline reads ptr+count via `[X19/R15 + off]` to
            // materialize `ExceptionTable` + `CodeMap` slices for
            // `dispatchThrow`. Modules without try_table get an
            // empty table (ptr null, count 0); the .uncaught path
            // fires immediately.
            .eh_table_entries = if (compiled.exception_table.entries.len > 0)
                compiled.exception_table.entries.ptr
            else
                null,
            .eh_table_count = @intCast(compiled.exception_table.entries.len),
            .eh_code_map_entries = if (compiled.module.code_map_entries.len > 0)
                compiled.module.code_map_entries.ptr
            else
                null,
            .eh_code_map_count = @intCast(compiled.module.code_map_entries.len),
            // 10.G GC-on-JIT: the jitGcAlloc trampoline reads these to
            // allocate; null for non-GC modules.
            .gc_heap = gc_heap_ptr,
            .gc_type_infos_ptr = gc_type_infos_ptr,
            .tag_ids_ptr = if (tag_ids.len > 0) tag_ids.ptr else null,
            .tag_ids_count = @intCast(tag_ids.len),
        },
        .mem_ctx = mem_ctx,
        .eh_reify_ctx = reify_ctx,
        .dispatch = dispatch,
        .globals = globals_buf,
        .funcptrs = funcptrs_buf,
        .typeidxs = typeidxs_buf,
        .func_entities = func_entities,
        .data_dropped = data_dropped,
        .elem_dropped = elem_dropped,
        .data_segments = data_segments_buf,
        .tables_descriptors = tables_descs,
        .table_refs = table_refs,
        .elem_segments = elem_segments_buf,
        .elem_refs = elem_refs_arena,
        .tables_jit_ci = tables_jit_ci_buf,
        .extra_funcptrs = extra_funcptrs_buf,
        .extra_typeidxs = extra_typeidxs_buf,
        .gc_arena = gc_arena,
        .thunk_arena = thunk_arena,
        .tag_ids = tag_ids,
        .tag_tokens = tag_tokens,
        .host_payloads = host_payloads,
    };
}

/// Default host-import trap trampoline (chunk 7.9-d). C-ABI
/// function pointer planted into every `host_dispatch_base[i]`
/// slot when no real WASI handler has been installed. Sets
/// `rt.trap_flag = 1` and returns 0 (sentinel). The entry shim's
/// post-return inspection of `rt.trap_flag` distinguishes this
/// trap from a real i32 return value of 0.
///
/// The trampoline takes the JitRuntime ptr as its first arg
/// (matching the JIT-side calling convention's
/// `entry_arg0 = runtime_ptr` reservation). Subsequent Wasm args
/// are passed in arg-regs 1..N but are ignored — the trampoline
/// has no per-import signature, only a fail-safe sink. This
/// works because the C ABI on both AAPCS64 and SysV / Win64
/// permits a callee to read fewer args than the caller passed
/// without faulting.
pub fn hostDispatchTrap(rt: *entry.JitRuntime) callconv(.c) u64 {
    rt.trap_flag = 1;
    return 0;
}

// ============================================================
// Tests
// ============================================================
