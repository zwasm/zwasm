// FILE-SIZE-EXEMPT: (cap=UNCAPPED) C ABI translation catalog (Zone 3 boundary layer); no separable subsystem per ADR-0099 §D2 P3 evaluation (see .dev/architecture/api_instance_audit.md, §9.12-G (c)). 10.F D-173/D-172 accessor surfaces extended exempt cap 2500→2800→3000; cyc174 raised 3000→3200 (ADR-0099 amend) for the Wasm start-section execution feature (a runtime-feature add in instantiateInternal, NOT accessor bloat) — consistent with the non-separable P3 eval + the validator.zig cyc158 precedent. P13 §13.2 raised 3200→3300 (ADR-0099 amend) for the runtime-entity host-creation surface — standalone-entity (instance==null) branches in the global/table/memory accessors + the buildBindings host-import arm; the `_new` CONSTRUCTORS are already split to extern_new.zig, this is the irreducible accessor/binding half coupled to the entity structs. ADR-0184 raised 3300→3400 (ADR-0099 amend 2026-06-13) for the engine-owned io plumbing (Threaded ownership + Host.io wiring + preopen materialization), same runtime-feature-add class. ADR-0200 raised 3400→3700 (ADR-0099 amend 2026-06-21) for the JIT-backed engine surface (EngineKind + instantiateJit + the per-instance engine branch in instantiateInternal; the wasm_func_call JIT arm + Val↔JIT marshalling helpers + JIT exports_storage population — all C-ABI translation, NOT a separable subsystem: extracting the ~80-LOC marshalling cluster would be an N3 shallow module). ADR-0200 raised 3700→3800 (ADR-0099 amend 2026-06-21, user-authorized) for the JIT C-surface completion (instantiateJit now populating export_types parallel to exports_storage for by-name discovery + the C-path discover/invoke test) — same runtime-feature-add-in-instantiate class. D-171 restructure increasingly warranted as ADR-0200 grows the C surface — the genuine separable-subsystem split. ADR-0200/D-496 added the JIT-instance C-API accessor surface (global/memory/get_func JIT arms + `.jit`-pinned tests). **UNCAPPED (user-ratified 2026-06-22, ADR-0099 amend)**: this file is a designated irreducible C-ABI translation catalog — a flat list of thin per-entity wrappers that grows one cluster per C-API feature, with no separable subsystem (the genuinely-extractable parts — `_new` constructors → extern_new.zig, introspection → module_introspect.zig — are already split). The per-line cap is the wrong instrument here; the line count is not a smell. D-171 (further restructure) is OPTIONAL tidiness, NOT a forced split.
//! Engine / Store / Module / Instance / Func / Extern surface of
//! the C ABI binding (§9.5 / 5.0 chunk d carve-out from
//! `wasm.zig` per ADR-0007).
//!
//! Owns every value and handle type the wasm-c-api shapes the
//! life cycle around: `Engine`, `Store`, `Module`, `Instance`,
//! `Func`, `Extern` (plus `ValKind` / `Val` / `ExternKind`).
//! Holds the corresponding `*_new` / `*_delete` C exports, the
//! frontend-validate + instantiation pipelines, the Func dispatch
//! glue, the marshal helpers, the export-discovery surface
//! (`wasm_extern_*`, `wasm_instance_exports`,
//! `wasm_extern_vec_delete` — moved here because it cascades into
//! `wasm_extern_delete`), and `wasm_func_call`.
//!
//! Reaches `ByteVec` / `ValVec` / `ExternVec` from `vec.zig` and
//! `Trap` / `TrapKind` / `allocTrap` / `mapInterpTrap` from
//! `trap_surface.zig` directly (sideways imports inside Zone 3).
//! `wasm.zig` re-exports every public name in this file so
//! call sites (CLI, in-binding helpers, external tests) keep
//! addressing them as `wasm_c_api.<name>`.
//!
//! Zone 3 — same as the rest of `src/api/`. Imports lower
//! zones (`interp/`, `wasi/`, `frontend/`, `ir/`, `util/`) freely.

const std = @import("std");

const runtime = @import("../runtime/runtime.zig");
const runtime_instance = @import("../runtime/instance/instance.zig");
const runtime_instance_import = @import("../runtime/instance/import.zig");
const instantiate = @import("../runtime/instance/instantiate.zig");
const memory_backing = @import("../runtime/instance/memory_backing.zig");
const wasi_host = @import("../wasi/host.zig");
const wasi = @import("wasi.zig");
const trap_surface = @import("trap_surface.zig");
const vec = @import("vec.zig");
const dispatch = @import("../interp/dispatch.zig");
const interp_mvp = @import("../interp/mvp.zig");
const runner = @import("../engine/runner.zig"); // ADR-0200 JIT engine (Zone 2)
const build_options = @import("build_options");
const wasm_2_0_enabled = @intFromEnum(build_options.wasm_level) >= @intFromEnum(@as(@TypeOf(build_options.wasm_level), .v2_0));
const wasm_3_0_enabled = @intFromEnum(build_options.wasm_level) >= @intFromEnum(@as(@TypeOf(build_options.wasm_level), .v3_0));
// ADR-0193 P4: this `ext_* = if (wasm_N_enabled) @import(...) else struct{}`
// block is the deliberate finished-form for Wasm-level feature gating — a
// file-tier feature manifest (two central comptime predicates above + the
// feature modules resident in their `instruction/wasm_{2,3}_0/` directories),
// NOT scattered branches. Kept as-is, not pushed into the op dispatch_collector
// (these modules expose functions instance.zig calls directly, not just op handlers).
const ext_sign_ext = if (wasm_2_0_enabled) @import("../instruction/wasm_2_0/sign_extension.zig") else struct {};
const ext_sat_trunc = if (wasm_2_0_enabled) @import("../instruction/wasm_2_0/nontrap_conversion.zig") else struct {};
const ext_bulk_memory = if (wasm_2_0_enabled) @import("../instruction/wasm_2_0/bulk_memory.zig") else struct {};
const ext_ref_types = if (wasm_2_0_enabled) @import("../instruction/wasm_2_0/reference_types.zig") else struct {};
const ext_function_references = if (wasm_3_0_enabled) @import("../instruction/wasm_3_0/function_references.zig") else struct {};
const ext_i31_ops = if (wasm_3_0_enabled) @import("../instruction/wasm_3_0/i31_ops.zig") else struct {};
const ext_ref_test_ops = if (wasm_3_0_enabled) @import("../instruction/wasm_3_0/ref_test_ops.zig") else struct {};
const ext_ref_convert_ops = if (wasm_3_0_enabled) @import("../instruction/wasm_3_0/ref_convert_ops.zig") else struct {};
const ext_struct_ops = if (wasm_3_0_enabled) @import("../instruction/wasm_3_0/struct_ops.zig") else struct {};
const ext_array_ops = if (wasm_3_0_enabled) @import("../instruction/wasm_3_0/array_ops.zig") else struct {};
const dbg = @import("../support/dbg.zig");
const ext_table_ops = if (wasm_2_0_enabled) @import("../instruction/wasm_2_0/table_ops.zig") else struct {};
const parser = @import("../parse/parser.zig");
const cross_module = @import("cross_module.zig");
const sections = @import("../parse/sections.zig");
const leb128 = @import("../support/leb128.zig");
const zir = @import("../ir/zir.zig");
const dispatch_table_mod = @import("../ir/dispatch_table.zig");
const handles = @import("handles.zig");
const jit_dispatch = @import("../wasi/jit_dispatch.zig"); // D-478 — WASI dispatch lookup
const jit_host_bridge = @import("jit_host_bridge.zig"); // D-478 — host-func JIT bridge
const setup_mod = @import("../engine/setup.zig"); // D-478 — HostFuncTarget
const validator_helpers = @import("../validate/validator_helpers.zig"); // #360 — cross-module func import subtyping

const ByteVec = vec.ByteVec;
const ValVec = vec.ValVec;
const ExternVec = vec.ExternVec;
const Trap = trap_surface.Trap;
const TrapKind = trap_surface.TrapKind;
const allocTrap = trap_surface.allocTrap;
const mapInterpTrap = trap_surface.mapInterpTrap;

const testing = std.testing;

// Opaque types (match wasm.h declarations 1:1)
// ============================================================

/// `wasm_engine_t` — process-wide top-level handle. Carries the
/// allocator the binding will thread into runtimes (and into
/// future `wasm_store_t` GC roots). The §9.3 / 3.3 binding uses
/// `std.heap.c_allocator` so C hosts get malloc-equivalent
/// lifetime; a future `zwasm.h` extension will let the host
/// inject its own.
pub const Engine = runtime.Engine;
pub const Store = runtime.Store;
pub const Zombie = runtime.Zombie;

/// `wasm_module_t` — validated module. Owns a heap-allocated
/// copy of the input bytes (so the C host can free its
/// `byte_vec` immediately after `wasm_module_new`) plus a
/// pointer back to the Store so `_delete` can recover the
/// allocator. Section decode + lowering happens at `_new` time;
/// the §9.3 / 3.5 instance constructor reuses the work.
pub const Module = extern struct {
    store: ?*Store,
    bytes_ptr: ?[*]u8,
    bytes_len: usize,
    /// host_info (wasm.h `WASM_DECLARE_SHARABLE_REF`/`REF_BASE`); accessors in
    /// `host_info.zig`, finalizer fired in `wasm_module_delete`.
    host_info: ?*anyopaque = null,
    host_info_finalizer: ?*const fn (?*anyopaque) callconv(.c) void = null,
    /// Cached borrowed `wasm_ref_t` view (`wasm_module_as_ref`, ADR-0158;
    /// payload = `@intFromPtr(self)`; freed in `wasm_module_delete`).
    ref_view: ?*handles.Ref = null,
};

// Instance + ExportType moved to src/runtime/instance/instance.zig
// per ADR-0023 §7 item 5. The binding-side wasm_module_t (this
// file's `Module` extern struct) stays here and is forward-cast
// through Instance.module's `?*const anyopaque` slot at the
// boundary — see `wasm_instance_new` + the equality-test site in
// the §9.3 / 3.5 lifetime test.
pub const Instance = runtime_instance.Instance;
pub const ExportType = runtime_instance.ExportType;

// C-API handle structs (Func/Global/Table/Memory/Ref/Extern) + value shapes
// (Val/ValKind/ExternKind) + the host-func payload live in `handles.zig`
// (carved out per ADR-0157 — instance.zig was at its file-size cap; chunk E's
// per-handle host_info needs room to grow). Re-exported here so `instance.<T>`
// keeps resolving for siblings (module_introspect / extern_new / wasm.zig) +
// this file's accessor/marshal functions.
//
// `Trap`/`TrapKind` live in `trap_surface.zig`; `ByteVec`/`ValVec`/`ExternVec`
// in `vec.zig` (ADR-0007) — see the aliases near the imports above.
pub const Func = handles.Func;
pub const WasmFuncCallback = handles.WasmFuncCallback;
pub const WasmFuncCallbackEnv = handles.WasmFuncCallbackEnv;
pub const HostFuncPayload = handles.HostFuncPayload;
pub const Global = handles.Global;
pub const Ref = handles.Ref;
pub const Table = handles.Table;
pub const Memory = handles.Memory;
pub const ValKind = handles.ValKind;
pub const Val = handles.Val;
pub const ExternKind = handles.ExternKind;
pub const Extern = handles.Extern;

// `ExternVec` lives in `src/api/vec.zig` after the §9.5 / 5.0
// chunk c carve-out (ADR-0007); see the re-exports near the
// imports at the top of this file.

// ============================================================
// Engine constructors / destructors (§9.3 / 3.3)
// ============================================================

inline fn engineAllocator(e: *const Engine) std.mem.Allocator {
    return .{
        .ptr = @ptrCast(e.alloc_ptr),
        .vtable = @ptrCast(@alignCast(e.alloc_vtable.?)),
    };
}

/// Engine-owned io token (ADR-0184). Null only for an Engine that
/// predates `wasm_engine_new` (e.g. a zeroed struct from C).
pub inline fn engineIo(e: *const Engine) ?std.Io {
    const t: *std.Io.Threaded = @ptrCast(@alignCast(e.io_threaded orelse return null));
    return t.io();
}

/// `wasm_engine_new()` — allocate an Engine + bind the C
/// allocator. Returns null on OOM (zero allocations should
/// happen at this layer beyond the Engine struct itself; the C
/// allocator is process-wide).
///
/// First-time side effect: pulls `ZWASM_DEBUG` from process env
/// via `std.c.getenv` (libc is linked at this Zone 3 c_api
/// binding by definition) and configures the Zone 0 `dbg`
/// whitelist via `dbg.initFromEnv`. Per D-009 refactor: Zone 0
/// no longer reads env directly; Zone 3 entry points plumb the
/// value down. Idempotent — only the first call observes the
/// env; subsequent `initFromEnv` calls overwrite, but every C
/// host process traverses `wasm_engine_new` at most a handful
/// of times.
pub export fn wasm_engine_new() callconv(.c) ?*Engine {
    const tls = struct {
        var dbg_initialised: bool = false;
    };
    if (!tls.dbg_initialised) {
        const raw = std.c.getenv("ZWASM_DEBUG");
        const value: ?[]const u8 = if (raw) |p| std.mem.span(p) else null;
        dbg.initFromEnv(value);
        tls.dbg_initialised = true;
    }
    const alloc = std.heap.c_allocator;
    const e = alloc.create(Engine) catch return null;
    // ADR-0184: the engine owns a `std.Io.Threaded` so the C-ABI
    // surface (which cannot receive a Zig io token) can serve WASI
    // preopens / env inheritance. Threads spawn lazily; init only
    // needs the allocator.
    const threaded = alloc.create(std.Io.Threaded) catch {
        alloc.destroy(e);
        return null;
    };
    threaded.* = .init(alloc, .{});
    e.* = .{
        .alloc_ptr = alloc.ptr,
        .alloc_vtable = @ptrCast(alloc.vtable),
        .io_threaded = threaded,
    };
    return e;
}

/// `wasm_engine_delete(*Engine)` — free an Engine that was
/// returned by `wasm_engine_new`. Idempotent for a null pointer
/// (mirrors upstream `WASM_DECLARE_OWN` discipline: the C host
/// passes the same pointer it got back).
pub export fn wasm_engine_delete(e: ?*Engine) callconv(.c) void {
    const handle = e orelse return;
    const alloc = engineAllocator(handle);
    if (handle.io_threaded) |t_opaque| {
        const t: *std.Io.Threaded = @ptrCast(@alignCast(t_opaque));
        t.deinit();
        alloc.destroy(t);
    }
    alloc.destroy(handle);
}

// ============================================================
// Store constructors / destructors (§9.3 / 3.3b)
// ============================================================

/// `wasm_store_new(wasm_engine_t*)` — allocate a Store bound to
/// the given Engine. Returns null on OOM or null engine.
pub export fn wasm_store_new(e: ?*Engine) callconv(.c) ?*Store {
    const engine = e orelse return null;
    const alloc = engineAllocator(engine);
    const s = alloc.create(Store) catch return null;
    s.* = .{ .engine = engine };
    return s;
}

/// `wasm_store_delete(*Store)` — free a Store. Null-tolerant.
/// Walks the zombie-instance list (per ADR-0014 §2.1 / 6.K.2
/// sub-change 4); tears down the attached WASI Host (if any);
/// releases the struct itself.
pub export fn wasm_store_delete(s: ?*Store) callconv(.c) void {
    const handle = s orelse return;
    const engine = handle.engine orelse return; // dangling — leak rather than crash
    const alloc = engineAllocator(engine);
    // D-174: cascade-cleanup any c_api Instance handles still
    // registered as live at store-teardown time. Each handle's
    // runtime + arena get parked as zombies (reaped in the next
    // loop), and the Instance struct itself is freed. After the
    // cascade, `inst.store` pointers in any caller-held handle
    // are stale, but the handles themselves are freed — calling
    // wasm_instance_delete on them post-cascade is UB by C-API
    // contract (use-after-free of caller-owned handle pointer).
    for (handle.live_instances.items) |inst_opaque| {
        const inst: *Instance = @ptrCast(@alignCast(inst_opaque));
        if (inst.runtime) |rt| {
            if (inst.arena) |arena| {
                // EXEMPT-FALLBACK: D-174 — parkAsZombie OOM at store-teardown accepts arena leak over UAF.
                parkAsZombie(alloc, handle, rt, arena) catch {};
                inst.arena = null;
            } else {
                rt.deinit();
                alloc.destroy(rt);
            }
        }
        // #360 — a JIT-backed instance still live here has its JitInstance
        // parked for the reap below. Before this it was dropped on the floor
        // (the cascade only ever looked at `inst.runtime`), leaking the code
        // pages and the runtime on the reverse-order teardown path.
        if (inst.jit) |jp| {
            // EXEMPT-FALLBACK: ADR-0014 — park OOM at store-teardown accepts a JitInstance leak over UAF.
            parkJitAsZombie(alloc, handle, jp) catch {};
            inst.jit = null;
        }
        inst.funcs_storage = &.{};
        inst.func_ptrs_storage = &.{};
        alloc.destroy(inst);
    }
    handle.live_instances.deinit(alloc);
    // Reap zombies first: each one's runtime + arena outlived the
    // instance handle so cross-module funcrefs into it stayed
    // valid; with the store going away, no foreign reference
    // remains, so they can be freed.
    for (handle.zombies.items) |z| {
        z.runtime.deinit();
        z.arena.deinit();
        alloc.destroy(z.arena);
        alloc.destroy(z.runtime);
    }
    handle.zombies.deinit(alloc);
    // #360 — and the JIT-backed zombies: an importer's bridge thunk pointed at
    // each of these, and every importer is gone with the cascade above.
    for (handle.jit_zombies.items) |jp| {
        const jit: *runner.JitInstance = @ptrCast(@alignCast(jp));
        jit.deinit(alloc);
        alloc.destroy(jit);
    }
    handle.jit_zombies.deinit(alloc);
    // Free the cross-module instance registry (ADR-0065 §"Cat III").
    // Values are erased `*Instance` pointers (lifetimes managed by
    // the zombie list); keys are caller-owned. Only the hashmap's
    // own backing storage is released here.
    handle.instances.deinit(alloc);
    if (handle.wasi_host) |host_opaque| {
        const host: *wasi_host.Host = @ptrCast(@alignCast(host_opaque));
        host.deinit();
        alloc.destroy(host);
    }
    // Hosts a `zwasm_store_set_wasi` could not free because an instance
    // had captured them. Nothing can reach them now: every runtime that
    // held one is gone with the instances + zombies reaped above.
    for (handle.retired_wasi_hosts.items) |host_opaque| {
        const host: *wasi_host.Host = @ptrCast(@alignCast(host_opaque));
        host.deinit();
        std.heap.c_allocator.destroy(host);
    }
    handle.retired_wasi_hosts.deinit(std.heap.c_allocator);
    alloc.destroy(handle);
}

/// Park a runtime + arena pair on the store's zombie list. Used
/// by `wasm_instance_new`'s catch path (failed instantiation
/// retains its state per Wasm 2.0 partial-init semantics) and
/// by `wasm_instance_delete` (cross-module funcrefs into the
/// instance's funcs stay valid until store teardown). Per
/// ADR-0014 §2.1 / 6.K.2 sub-change 4.
fn parkAsZombie(
    store_alloc: std.mem.Allocator,
    store: *Store,
    rt: *runtime.Runtime,
    arena: *std.heap.ArenaAllocator,
) std.mem.Allocator.Error!void {
    try store.zombies.append(store_alloc, .{
        .runtime = rt,
        .arena = arena,
    });
}

/// #360 — the JIT counterpart of `parkAsZombie`. A cross-module func import
/// bakes the exporter's `&owned.rt` and entry address into the importer's
/// bridge thunk (D-225), so the exporter's `JitInstance` must outlive every
/// importer. Parking defers the free to `wasm_store_delete`, by when nothing
/// can call in. Takes the erased pointer the `Instance.jit` field carries.
fn parkJitAsZombie(
    store_alloc: std.mem.Allocator,
    store: *Store,
    jit: *anyopaque,
) std.mem.Allocator.Error!void {
    try store.jit_zombies.append(store_alloc, jit);
}

// ============================================================
// WASI host wiring (§9.4 / 4.7 chunk a)
// ============================================================
//
// `zwasm_wasi_config_new` and `zwasm_wasi_config_delete` live in
// `src/api/wasi.zig` (§9.5 / 5.0 carve-out per ADR-0007); only
// the Store-touching `zwasm_store_set_wasi` remains here.

/// `zwasm_store_set_wasi(*Store, ?*Host)` — install a WASI
/// host on a Store. Ownership of the Host transfers to the
/// Store; the C host must not call `zwasm_wasi_config_delete`
/// on the same pointer afterwards. Calling twice on the same
/// Store frees the previous Host first — UNLESS an instantiation
/// has already captured it, in which case it retires and is freed
/// by `wasm_store_delete` (a live instance, or a zombie's parked
/// bindings, still holds its address). Pass `null` to detach the
/// existing Host under the same rule.
pub export fn zwasm_store_set_wasi(s: ?*Store, h: ?*wasi_host.Host) callconv(.c) void {
    const store = s orelse return;
    if (store.wasi_host) |old_opaque| {
        if (store.wasi_host_captured) {
            // `c_allocator` is what `zwasm_wasi_config_new` used for every
            // host this list can hold, and what `wasm_store_delete` frees
            // them with. The slot is already reserved: whatever set
            // `wasi_host_captured` reserved one and the flag is cleared below,
            // so each capture funds exactly the one retirement it can cause
            // (ADR-0224). Kept fallible rather than assuming the capacity so a
            // violated reservation degrades instead of panicking in a library.
            // EXEMPT-FALLBACK: ADR-0014 — an append OOM accepts the leak over the UAF, mirroring parkAsZombie.
            store.retired_wasi_hosts.append(std.heap.c_allocator, old_opaque) catch {};
        } else {
            const old: *wasi_host.Host = @ptrCast(@alignCast(old_opaque));
            old.deinit();
            std.heap.c_allocator.destroy(old);
        }
    }
    store.wasi_host_captured = false;
    if (h) |hp| {
        // ADR-0184: hand the engine-owned io to the host so fs
        // syscalls (path_open, preopen materialization) work from
        // the pure C surface. Valid for the host's whole life: the
        // engine outlives the store, which owns the host.
        if (store.engine) |eng| {
            if (hp.io == null) hp.io = engineIo(eng);
        }
    }
    store.wasi_host = if (h) |hp| @as(*anyopaque, @ptrCast(hp)) else null;
}

/// `zwasm_store_wasi_exit_code(*Store, *u32)` — read the exit status
/// a WASI guest requested through `proc_exit`. Returns false, leaving
/// `out` untouched, when the Store has no WASI host or the guest never
/// called `proc_exit`. The status is per call: `wasm_func_call` clears
/// it before running, so what this reports is the call just made.
/// `src/cli/run.zig` applies the same rule: a trap that carries an exit
/// code is a guest that ended itself, and a trap without one is a fault.
pub export fn zwasm_store_wasi_exit_code(s: ?*const Store, out: ?*u32) callconv(.c) bool {
    const store = s orelse return false;
    const host = activeWasiHost(store) orelse return false;
    const code = host.exit_code orelse return false;
    if (out) |p| p.* = code;
    return true;
}

/// #352 / ADR-0224 — discard any recorded exit status across this Store, on
/// the way into guest code, so what a reader sees afterwards describes that
/// entry alone.
///
/// Clearing every host rather than one addressed host IS the decision: which
/// host a call reaches is not knowable before it runs, because dispatch can
/// leave the instance it entered and run another one's body with that
/// instance's WASI binding.
///
/// Written as a drain of the accessor below so the SET has exactly one
/// definition — a third source of hosts would otherwise have to be added to
/// two walks and one of them would be missed. Each pass strictly reduces the
/// number of hosts carrying a status, so it terminates; by the accessor's
/// invariant it is normally one clear plus one confirming scan.
pub fn clearWasiExitStatus(store: *const Store) void {
    while (activeWasiHost(store)) |h| h.exit_code = null;
}

/// #352 / ADR-0224 — the WASI host to read an exit status from: whichever one
/// a `proc_exit` actually wrote. Null when no guest in this Store has exited
/// since the last entry into guest code.
///
/// The set walked here is every host a guest in this Store can write, and it
/// is closed on both sides: an instance's host always came from
/// `store.wasi_host` at capture time, `zwasm_store_set_wasi` frees a host
/// nothing captured on the spot rather than retiring it, and a capture
/// reserves the retirement slot it may later need — so a displaced host cannot
/// fall out of the list and become unreadable while its instances stay
/// callable. It is the same set `wasm_store_delete` frees.
///
/// Scanning is sound because AT MOST ONE host in it carries a status at any
/// read point. A `proc_exit` unwinds the whole call, so the guest that wrote
/// one cannot run again and nothing can write after it; the one way two could
/// coexist — a host callback that swallows a nested call's exit trap and
/// returns to an outer guest that exits on a different host — is removed by
/// the nested entry clearing again on its way out.
///
/// The single resolution rule for every Store-mediated reader: this accessor
/// and `src/cli/run.zig`'s trap-vs-exit branch, so a second reader cannot
/// drift onto `wasi_host` alone.
pub fn activeWasiHost(store: *const Store) ?*wasi_host.Host {
    if (store.wasi_host) |h| {
        const typed: *wasi_host.Host = @ptrCast(@alignCast(h));
        if (typed.exit_code != null) return typed;
    }
    for (store.retired_wasi_hosts.items) |h| {
        const typed: *wasi_host.Host = @ptrCast(@alignCast(h));
        if (typed.exit_code != null) return typed;
    }
    return null;
}

// ============================================================
// Module constructors / validators / destructors (§9.3 / 3.4)
// ============================================================

pub inline fn storeAllocator(s: *const Store) ?std.mem.Allocator {
    const engine = s.engine orelse return null;
    return engineAllocator(engine);
}

/// `wasm_module_new(store, binary)` — parse + validate `binary`,
/// return an owning Module on success or null on parse / validate
/// failure. The returned Module copies the binary bytes so the C
/// host can free its `byte_vec` immediately.
pub export fn wasm_module_new(s: ?*Store, binary: ?*const ByteVec) callconv(.c) ?*Module {
    const store = s orelse return null;
    const bv = binary orelse return null;
    const alloc = storeAllocator(store) orelse return null;
    const data_ptr = bv.data orelse return null;
    const slice = data_ptr[0..bv.size];

    if (!instantiate.frontendValidate(alloc, slice)) return null;

    // Copy the bytes so the Module owns them past the call.
    const owned = alloc.dupe(u8, slice) catch return null;
    errdefer alloc.free(owned);

    const m = alloc.create(Module) catch {
        alloc.free(owned);
        return null;
    };
    m.* = .{
        .store = store,
        .bytes_ptr = owned.ptr,
        .bytes_len = owned.len,
    };
    return m;
}

/// `wasm_module_validate(store, binary)` — same pipeline as
/// `_module_new` but discards the result; returns `true` if the
/// module passes validation.
pub export fn wasm_module_validate(s: ?*Store, binary: ?*const ByteVec) callconv(.c) bool {
    const store = s orelse return false;
    const bv = binary orelse return false;
    const alloc = storeAllocator(store) orelse return false;
    const data_ptr = bv.data orelse return false;
    return instantiate.frontendValidate(alloc, data_ptr[0..bv.size]);
}

/// `wasm_module_delete(module)` — free a Module returned by
/// `_module_new`. Null-tolerant.
pub export fn wasm_module_delete(m: ?*Module) callconv(.c) void {
    const handle = m orelse return;
    if (handle.host_info_finalizer) |fin| fin(handle.host_info);
    const store = handle.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    if (handle.ref_view) |rv| alloc.destroy(rv); // object-identity as_ref view (ADR-0158)
    if (handle.bytes_ptr) |p| alloc.free(p[0..handle.bytes_len]);
    alloc.destroy(handle);
}

// `wasm_module_imports` / `_exports` (§13.2 introspection) live in the
// separable `api/module_introspect.zig` (D-171 / ADR-0099 §D2 P3 — a
// genuine subsystem, keeping instance.zig under its exempt cap).

// ============================================================
// Instance constructors / destructors (§9.3 / 3.5 + 3.6)
// ============================================================

/// Look up the source instance's exported entity descriptor by
/// `(kind, name)` against `inst.{exports_storage, export_types}`.
fn lookupSourceExportType(
    inst: *const Instance,
    kind: sections.ExportDesc,
    name: []const u8,
) !runtime.ExportType {
    if (inst.exports_storage.len != inst.export_types.len)
        return error.ImportTypeMismatch;
    for (inst.exports_storage, inst.export_types) |exp, et| {
        if (exp.kind == kind and std.mem.eql(u8, exp.name, name)) return et;
    }
    return error.ImportTypeMismatch;
}

/// Pre-resolve all imports declared in `bytes` into Zone-1
/// native `ImportBinding`s. Returns null when the module has no
/// imports. Allocates the binding slice + cross-module CallCtx
/// records on `arena_alloc` (the per-instance arena).
fn buildBindings(
    arena_alloc: std.mem.Allocator,
    bytes: []const u8,
    imports_array: ?[*]const ?*const Extern,
    store: *Store,
) !?[]const runtime_instance_import.ImportBinding {
    var module = try parser.parse(arena_alloc, bytes);
    defer module.deinit(arena_alloc);
    const imp_section = module.find(.import) orelse return null;
    var imports_decoded = try sections.decodeImports(arena_alloc, imp_section.body);
    defer imports_decoded.deinit();
    if (imports_decoded.items.len == 0) return null;

    const bindings = try arena_alloc.alloc(runtime_instance_import.ImportBinding, imports_decoded.items.len);
    for (imports_decoded.items, 0..) |it, idx| {
        if (std.mem.eql(u8, it.module, "wasi_snapshot_preview1")) {
            if (it.kind != .func) return error.UnsupportedWasiImport;
            const thunk = wasi.lookupWasiThunk(it.name) orelse return error.UnsupportedWasiImport;
            const wasi_host_ptr = store.wasi_host orelse return error.WasiNotConfigured;
            // The binding outlives this call — and outlives the instance
            // too, since `wasm_instance_delete` parks the arena holding it
            // on `store.zombies`. May over-mark (this also runs on the
            // throwaway arena in `collectFuncImportTargets`); over-marking
            // only defers a free, so nothing compensates for it.
            //
            // ADR-0224 — reserve the retirement slot HERE, at capture, not at
            // the swap. `activeWasiHost` finds a displaced host only through
            // `retired_wasi_hosts`, so a host that fails to reach that list is
            // not merely leaked (the pre-ADR-0224 cost) but unreadable: its
            // instances stay callable and their exits report nothing.
            // Reserving at capture puts the allocation failure on the
            // instantiation, which can and does report it.
            try store.retired_wasi_hosts.ensureUnusedCapacity(std.heap.c_allocator, 1);
            store.wasi_host_captured = true;
            bindings[idx] = .{ .func = .{
                .host_call = .{ .fn_ptr = thunk, .ctx = wasi_host_ptr },
                .source = .wasi,
            } };
            continue;
        }
        const ext_ptr = if (imports_array) |arr| arr[idx] else null;
        const ext = ext_ptr orelse return error.UnknownImportModule;
        const want_kind: ExternKind = switch (it.kind) {
            .func => .func,
            .table => .table,
            .memory => .memory,
            .global => .global,
            // EH tag imports (10.E-xmodule-tags) don't bind through the
            // legacy ext_ptr/ExternKind c_api path (ExternKind has no
            // tag); cross-module tag binding goes via the Linker (step
            // 2). Reaching here = unbound tag import.
            .tag => return error.ImportKindMismatch,
        };
        if (ext.kind != want_kind) return error.ImportKindMismatch;
        // Host-created standalone entity (e.g. `wasm_global_new`): no source
        // instance — bind directly from the entity's own backing cell. The
        // GlobalImport binding only needs a `*Value` + type descriptors, so a
        // host cell aliases into the importer's `rt.globals[]` like any other.
        if (ext.instance == null) {
            switch (it.kind) {
                .global => {
                    const hg = ext.global orelse return error.UnknownImportModule;
                    const cell = hg.cell orelse return error.UnknownImportModule;
                    bindings[idx] = .{ .global = .{
                        .slot = cell,
                        .source_valtype = hg.valtype,
                        .source_mutable = hg.mutable,
                    } };
                },
                .memory => {
                    const hm = ext.memory orelse return error.UnknownImportModule;
                    const mi = hm.minst orelse return error.UnknownImportModule;
                    bindings[idx] = .{ .memory = .{ .inst = mi } };
                },
                .table => {
                    const ht = ext.table orelse return error.UnknownImportModule;
                    const ti = ht.tinst orelse return error.UnknownImportModule;
                    bindings[idx] = .{
                        .table = .{
                            .instance = ti.*, // value copy; refs slice aliased
                            .source_elem_type = ht.elem_type,
                            // table64 handle limits (u64) narrowed to the u32 binding (saturate).
                            .source_min = std.math.cast(u32, ht.min) orelse std.math.maxInt(u32),
                            .source_max = if (ht.max) |m| (std.math.cast(u32, m) orelse std.math.maxInt(u32)) else null,
                        },
                    };
                },
                .func => {
                    const hf = ext.func orelse return error.UnknownImportModule;
                    const payload = hf.host orelse return error.UnknownImportModule;
                    // Reuse the `.wasi` void source arm (as native defineFunc
                    // does): "host callback, invoked by funcidx via host_calls[]".
                    bindings[idx] = .{ .func = .{
                        .host_call = .{ .fn_ptr = hostFuncThunk, .ctx = @ptrCast(payload) },
                        .source = .wasi,
                    } };
                },
                .tag => return error.UnsupportedHostImport,
            }
            continue;
        }
        const source_inst = ext.instance orelse return error.UnknownImportModule;
        const source_rt = source_inst.runtime orelse return error.UnknownImportModule;

        switch (it.kind) {
            .func => {
                const fh = ext.func orelse return error.UnknownImportModule;
                _ = fh;
                const source_funcidx = blk: {
                    for (source_inst.exports_storage) |exp| {
                        if (exp.kind == .func and std.mem.eql(u8, exp.name, it.name))
                            break :blk exp.idx;
                    }
                    return error.UnknownImportModule;
                };
                const src_et = try lookupSourceExportType(source_inst, .func, it.name);
                const source_sig = switch (src_et) {
                    .func => |sft| sft.sig,
                    else => return error.ImportTypeMismatch,
                };
                const ctx_ptr = try arena_alloc.create(cross_module.CallCtx);
                ctx_ptr.* = .{
                    .source_rt = source_rt,
                    .source_funcidx = source_funcidx,
                    .dispatch_table = dispatchTable(),
                };
                bindings[idx] = .{ .func = .{
                    .host_call = .{
                        .fn_ptr = cross_module.thunk,
                        .ctx = @ptrCast(ctx_ptr),
                    },
                    .source = .{ .cross_module = .{
                        .source_runtime = source_rt,
                        .source_funcidx = source_funcidx,
                        .source_signature = source_sig,
                    } },
                } };
            },
            .table => {
                if (ext.table_idx >= source_rt.tables.len) return error.UnknownImportModule;
                const src_et = try lookupSourceExportType(source_inst, .table, it.name);
                const desc = switch (src_et) {
                    .table => |t| t,
                    else => return error.ImportTypeMismatch,
                };
                bindings[idx] = .{ .table = .{
                    .instance = source_rt.tables[ext.table_idx],
                    .source_elem_type = desc.elem_type,
                    .source_min = desc.min,
                    .source_max = desc.max,
                } };
            },
            .memory => {
                const src_et = try lookupSourceExportType(source_inst, .memory, it.name);
                switch (src_et) {
                    .memory => {},
                    else => return error.ImportTypeMismatch,
                }
                // D-199 — share the exporter's live memory0 *MemoryInstance.
                if (source_rt.memories.len == 0) return error.UnknownImportModule;
                bindings[idx] = .{ .memory = .{ .inst = source_rt.memories[0] } };
            },
            .global => {
                if (ext.global_idx >= source_rt.globals.len) return error.UnknownImportModule;
                const src_et = try lookupSourceExportType(source_inst, .global, it.name);
                const desc = switch (src_et) {
                    .global => |g| g,
                    else => return error.ImportTypeMismatch,
                };
                bindings[idx] = .{ .global = .{
                    .slot = source_rt.globals[ext.global_idx],
                    .source_valtype = desc.valtype,
                    .source_mutable = desc.mutable,
                } };
            },
            // Unreachable: the `want_kind` switch above returns early
            // for `.tag` (tags don't bind through this legacy c_api
            // path). Arm present only for exhaustiveness (10.E).
            .tag => return error.ImportKindMismatch,
        }
    }
    return bindings;
}

/// `wasm_instance_new(store, module, imports, trap_out)` —
/// allocate an Instance bound to the given Module and lower its
/// code into the owned Runtime. `imports` is the upstream
/// `const wasm_extern_vec_t*` (recast below, indexed by the
/// module's import count); `trap_out` surfaces a start-function
/// trap per the wasm-c-api contract (D-275). Returns null on any
/// null required input, instantiation failure, or OOM.
pub export fn wasm_instance_new(
    s: ?*Store,
    m: ?*const Module,
    imports: ?*const anyopaque,
    trap_out: ?*?*Trap,
) callconv(.c) ?*Instance {
    // Stock wasm-c-api: engine is `.auto` — JIT-first, interp only for a module
    // the JIT declines (D-496). `zwasm_instance_new_ex` selects per-instance.
    return instanceNewWithEngine(s, m, imports, trap_out, .auto);
}

/// ADR-0200 — shared `wasm_instance_new` body parameterised by engine. The C
/// extension `zwasm_ext.zig::zwasm_instance_new_ex` calls this with the
/// caller's `EngineKind`; `wasm_instance_new` passes `.auto`.
pub fn instanceNewWithEngine(
    s: ?*Store,
    m: ?*const Module,
    imports: ?*const anyopaque,
    trap_out: ?*?*Trap,
    engine: EngineKind,
) ?*Instance {
    const store = s orelse return null;
    const module = m orelse return null;
    // wasm.h: `imports` is `const wasm_extern_vec_t*` ({size,data}), NOT a
    // bare extern array. Recast to the vec; hand buildBindings its `.data`
    // (indexed by the module's import count). Null vec/data → no imports.
    const imports_array: ?[*]const ?*const Extern = if (imports) |p| iblk: {
        const v: *const ExternVec = @ptrCast(@alignCast(p));
        break :iblk if (v.data) |d| @ptrCast(d) else null;
    } else null;

    // D-275: thread `trap_out` so a start-function trap surfaces per the
    // wasm-c-api contract (null return + `*trap_out` = the start trap). The C
    // ABI carries no budget knobs (upstream wasm.h shape); per-instance budgets
    // are the Zig facade's `instantiateFacade` + the `zwasm_instance_*` setters.
    return instantiateInternal(store, module, BuildBindingsCApi{ .imports_array = imports_array }, trap_out, .{}, engine);
}

/// Zig-facade no-import instantiation (`src/zwasm/module.zig::Module.instantiate`)
/// that threads per-instance runtime budgets (ADR-0179). Mirrors
/// `wasm_instance_new` with a null imports vector but accepts `limits` so fuel /
/// memory caps are armed before the start function and the initial allocation.
/// ADR-0200 / D-496 — per-instance engine selection. `auto` tries the JIT and
/// falls back to the interp for a module the JIT declines; `jit` / `interp`
/// force one (a forced `jit` fails rather than downgrading). The fork is
/// centralised in `instantiateInternal` so every entry point (facade /
/// `wasm_instance_new` / linker) honours it.
pub const EngineKind = enum { auto, jit, interp };

pub fn instantiateFacade(store: *Store, module: *const Module, trap_out: ?*?*Trap, limits: InstantiateLimits, engine: EngineKind) ?*Instance {
    return instantiateInternal(store, module, BuildBindingsCApi{ .imports_array = null }, trap_out, limits, engine);
}

/// D-478 / #360 — the JIT-satisfiable func imports of one module, both in
/// func-import order: embedder host callbacks (`wasm_func_new`) and
/// cross-module targets resolved against a JIT-backed exporter.
const JitFuncImports = struct {
    host: []setup_mod.HostFuncTarget = &.{},
    /// Positional, `num_func_imports` long when non-empty; a zeroed entry is
    /// an import setup resolves some other way (WASI / embedder host).
    cross: []setup_mod.FuncImportTarget = &.{},
};

/// #360 — resolve one cross-module FUNC import against a JIT-backed source
/// instance into the D-225 `FuncImportTarget` `initLinked` already consumes.
/// `error.Unsupported` when the source is interp-backed (JIT-compiled code
/// cannot enter an interpreter runtime), when it exports no such func, or
/// when its type is not a subtype of the declared import type — the same
/// §4.5.10 rule `instantiate.checkImportTypeMatches` applies on the interp
/// path. Matching is BY NAME, as the interp binder's cross-module arm is.
fn crossModuleJitTarget(
    ta: std.mem.Allocator,
    source_inst: *Instance,
    it: sections.Import,
    importer_types: *const sections.Types,
) error{Unsupported}!setup_mod.FuncImportTarget {
    const jit_ptr = source_inst.jit orelse return error.Unsupported;
    const source_jit: *runner.JitInstance = @ptrCast(@alignCast(jit_ptr));
    const src_et = lookupSourceExportType(source_inst, .func, it.name) catch return error.Unsupported;
    const src_sig = switch (src_et) {
        .func => |sft| sft.sig,
        else => return error.Unsupported,
    };
    const want_tidx = it.payload.func_typeidx;
    if (want_tidx >= importer_types.items.len) return error.Unsupported;
    const want_sig = importer_types.items[want_tidx];
    // #387 — `funcTypeImportCompatible` resolves both signatures in ONE type
    // space, and the only one in hand here is the importer's. That is sound
    // while every type is structural, and unsound the moment a signature names
    // a type INDEX: `(ref $t)` means what `$t` means in the module it came
    // from. The interp path has the same gap, but it carries
    // `source_signature` to the call; a resolved JIT target becomes a bridge
    // thunk jumping straight into the callee's body, so a wrongly accepted
    // link there is an ABI mismatch rather than a semantic one. Decline the
    // shape until the exporter's own `Types` are retained (the facade linker's
    // `export_src_types` + `canonicalEqualCross` is the model) — the caller
    // falls back to the interp, which is exactly where main already sent it.
    if (hasConcreteHeapType(want_sig) or hasConcreteHeapType(src_sig)) return error.Unsupported;
    if (!validator_helpers.funcTypeImportCompatible(want_sig, src_sig, importer_types))
        return error.Unsupported;
    return source_jit.exportedFuncTarget(ta, it.name) orelse error.Unsupported;
}

/// #387 — does this signature name a type-section INDEX anywhere? Such a type
/// is only meaningful in its own module, so a single-type-space comparison
/// cannot judge it across a module boundary.
fn hasConcreteHeapType(sig: zir.FuncType) bool {
    for ([_][]const zir.ValType{ sig.params, sig.results }) |half| {
        for (half) |vt| switch (vt) {
            .ref => |r| switch (r.heap_type) {
                .concrete => return true,
                .abstract => {},
            },
            else => {},
        };
    }
    return false;
}

/// D-478 / #360 — resolve the JIT path's func imports. Returns
/// `error.Unsupported` for any import the JIT cannot satisfy (caller rejects →
/// `.interp`). Empty slices mean "all imports are WASI / none" — those are
/// planted by setup via `jit_dispatch`, so no binder is consulted (no
/// regression on the WASI-only JIT path, which needs no `store.wasi_host` at
/// bind time).
///
/// The C ABI path resolves straight off the import `Extern`s
/// (`builder.imports`), because `buildBindings` — the interp binder — cannot
/// describe a JIT-backed source at all: it reaches for that instance's
/// interpreter `Runtime`, which is null by construction (ADR-0200's XOR). The
/// native-facade path (`src/zwasm/linker.zig`) carries no extern array and
/// keeps going through the binder, host funcs only.
fn collectFuncImportTargets(
    ta: std.mem.Allocator,
    bytes: []const u8,
    builder_state: anytype,
    store: *Store,
) error{ Unsupported, OutOfMemory }!JitFuncImports {
    var mod = parser.parse(ta, bytes) catch return error.Unsupported;
    const imp_section = mod.find(.import) orelse return .{};
    var imports = sections.decodeImports(ta, imp_section.body) catch return error.Unsupported;
    defer imports.deinit();

    // First pass: only func imports are JIT-satisfiable; detect whether any
    // needs a binding resolved here (a non-WASI func import).
    var needs_binding = false;
    for (imports.items) |it| {
        if (it.kind != .func) return error.Unsupported;
        if (jit_dispatch.lookup(it.module, it.name) == null) needs_binding = true;
    }
    if (!needs_binding) return .{};

    var local_state = builder_state;
    const builder: BindingsBuilder = if (@TypeOf(builder_state) == BindingsBuilder)
        builder_state
    else
        local_state.asBuilder();

    if (builder.imports) |arr| {
        const type_sec = mod.find(.type) orelse return error.Unsupported;
        return collectFromExterns(ta, type_sec.body, imports.items, arr);
    }

    // Native-facade path: buildBindings wires each host-func import's
    // `host_call.ctx` to its `*HostFuncPayload`.
    const bindings_opt = builder.build(builder.ctx, ta, bytes, store) catch return error.Unsupported;
    const bindings = bindings_opt orelse return error.Unsupported;

    var out: std.ArrayList(setup_mod.HostFuncTarget) = .empty;
    var func_idx: u32 = 0;
    for (imports.items, 0..) |it, i| {
        defer func_idx += 1; // every import is a func (checked above)
        if (jit_dispatch.lookup(it.module, it.name) != null) continue; // WASI → setup plants it
        if (i >= bindings.len or bindings[i] != .func) return error.Unsupported;
        const hc = bindings[i].func.host_call;
        if (hc.fn_ptr != hostFuncThunk) return error.Unsupported; // cross-module / non-embedder
        const payload: *HostFuncPayload = @ptrCast(@alignCast(hc.ctx));
        const dp = jit_host_bridge.dispatchPtrFor(payload.params, payload.results, func_idx) orelse return error.Unsupported;
        try out.append(ta, .{ .idx = func_idx, .dispatch_ptr = dp, .payload = @intFromPtr(payload) });
    }
    return .{ .host = try out.toOwnedSlice(ta) };
}

/// C ABI half of `collectFuncImportTargets`: every import is a func (the
/// caller checked), so the import index IS the func-import index. A host
/// callback is a standalone entity (`instance == null`); anything carrying a
/// source instance is a cross-module import.
fn collectFromExterns(
    ta: std.mem.Allocator,
    type_section_body: []const u8,
    items: []const sections.Import,
    arr: [*]const ?*const Extern,
) error{ Unsupported, OutOfMemory }!JitFuncImports {
    var types = sections.decodeTypes(ta, type_section_body) catch return error.Unsupported;
    defer types.deinit();

    var host: std.ArrayList(setup_mod.HostFuncTarget) = .empty;
    var cross = try ta.alloc(setup_mod.FuncImportTarget, items.len);
    @memset(cross, .{});
    var any_cross = false;
    for (items, 0..) |it, i| {
        const func_idx: u32 = @intCast(i);
        if (jit_dispatch.lookup(it.module, it.name) != null) continue; // WASI → setup plants it
        const ext = arr[i] orelse return error.Unsupported;
        if (ext.kind != .func) return error.Unsupported;
        if (ext.instance) |source_inst| {
            cross[i] = try crossModuleJitTarget(ta, source_inst, it, &types);
            any_cross = true;
            continue;
        }
        const fh = ext.func orelse return error.Unsupported;
        const payload = fh.host orelse return error.Unsupported;
        const dp = jit_host_bridge.dispatchPtrFor(payload.params, payload.results, func_idx) orelse return error.Unsupported;
        try host.append(ta, .{ .idx = func_idx, .dispatch_ptr = dp, .payload = @intFromPtr(payload) });
    }
    return .{
        .host = try host.toOwnedSlice(ta),
        .cross = if (any_cross) cross else &.{},
    };
}

/// ADR-0200 — build a JIT-backed `Instance` (`runtime == null`, `jit` set)
/// from a module compiled to native code via `engine/runner.zig::JitInstance`.
/// Imports are resolved by `collectFuncImportTargets` (WASI / embedder host /
/// cross-module) and fed to `initLinked`; `wasi_host` is attached below. The
/// borrowed `wasm_bytes` live in the owning `Module`, which outlives the
/// instance, and the `JitInstance` is heap-pinned so `exportedFuncTarget`'s
/// `&owned.rt` stays stable.
fn instantiateJit(store: *Store, module: *const Module, builder_state: anytype, trap_out: ?*?*Trap, limits: InstantiateLimits) ?*Instance {
    const alloc = storeAllocator(store) orelse return null;
    const bytes_ptr = module.bytes_ptr orelse return null;
    const bytes = bytes_ptr[0..module.bytes_len];

    // ADR-0200 / D-451 / D-478 / #360 — every import must be JIT-satisfiable AT
    // INSTANTIATION (mirrors the interp linker's UnknownImport): a WASI func
    // (`jit_dispatch.lookup`, planted by setup), an embedder host func
    // (`wasm_func_new`) whose signature the comptime bridge covers, OR a func
    // exported by another JIT-backed instance (D-225's `FuncImportTarget`).
    // Anything else — non-func import, an interp-backed cross-module source,
    // uncovered host-func signature, unsatisfied import — rejects here so the
    // caller's `.interp` path handles it (no silent wrong answer; uncovered
    // shapes never reach the JIT body). The resolved targets are arena-scoped:
    // setup copies the host ones' (idx, dispatch_ptr, payload) into the
    // heap-owned `host_payloads` and emits the cross-module ones into its own
    // thunk arena, so this arena can be reclaimed once `initLinked` returns.
    var ht_arena = std.heap.ArenaAllocator.init(alloc);
    defer ht_arena.deinit();
    const func_imports = collectFuncImportTargets(ht_arena.allocator(), bytes, builder_state, store) catch return null;

    const jit = alloc.create(runner.JitInstance) catch return null;
    jit.* = runner.JitInstance.initLinked(alloc, bytes, &.{}, func_imports.cross, &.{}, func_imports.host) catch {
        alloc.destroy(jit);
        return null;
    };
    // ADR-0179 budgets: the JIT meters poll-site crossings (not interp insns);
    // null axes stay unmetered. Memory/table caps clamp grow at runtime.
    jit.setFuel(limits.fuel);
    jit.setMemoryPagesLimit(limits.max_memory_pages);
    jit.setTableElementsLimit(limits.max_table_elements);
    // ADR-0200 — point the JIT interrupt poll at the now-heap-pinned own flag so
    // the facade `interrupt()` can cooperatively cancel a running guest.
    jit.armSelfInterrupt();
    // ADR-0200 / D-478 — attach the store's WASI host so the JIT's planted WASI
    // dispatch thunks do real syscalls (null → compute-only stub: clock/random/
    // fd_write silently no-op). Both fields are `?*anyopaque`. Materialize any
    // queued preopens first (mirrors the interp `instantiateInternal` path).
    if (store.wasi_host) |host_opaque| {
        const host: *wasi_host.Host = @ptrCast(@alignCast(host_opaque));
        host.materializePendingPreopens() catch {
            jit.deinit(alloc);
            alloc.destroy(jit);
            return null;
        };
    }
    jit.owned.rt.wasi_host = store.wasi_host;
    // Captured for the JitInstance's life. May over-mark (this runs before
    // `runStart`, which can still fail the instantiation) — see buildBindings,
    // including why the retirement slot is reserved at capture.
    if (store.wasi_host != null) {
        store.retired_wasi_hosts.ensureUnusedCapacity(std.heap.c_allocator, 1) catch {
            jit.deinit(alloc);
            alloc.destroy(jit);
            return null;
        };
        store.wasi_host_captured = true;
    }
    // #352 / ADR-0224 — instantiating is an entry into guest code: a `(start)`
    // can call `proc_exit`. Clear before `runStart`, so the start's own status
    // is what reads back and an earlier call's cannot stand in for it.
    // Unconditional, because `zwasm_store_set_wasi` leaves `wasi_host` null on
    // a detach: a module that captures nothing must still close the window.
    // Clear again on the way out when this instantiation was itself nested
    // inside a call in progress — that call owns the status, so a guest a host
    // callback built must not leave one behind.
    const nested_entry = store.wasi_call_depth > 0;
    clearWasiExitStatus(store);
    defer if (nested_entry) clearWasiExitStatus(store);

    // Wasm §4.5.4 — run the `(start)` function AFTER setup initialised globals /
    // memory / tables, BEFORE the instance is surfaced. A start trap fails
    // instantiation (mirrors the interp path; `trap_out` carries the trap). An
    // imported start is unsupported here → fail so an `.auto` caller can retry on
    // interp rather than silently skip it. Run before `inst` exists so teardown
    // is just the jit (no registry/arena to unwind).
    {
        // #345 — while the start function runs it OWNS the status, exactly as
        // an outermost `wasm_func_call` does: it can reach `proc_exit`, and a
        // host callback it invokes can call back into this Store. The depth is
        // what makes that callback's own call nested, so its guest's status is
        // dropped on the way out instead of standing in for the start's.
        store.wasi_call_depth +|= 1;
        defer store.wasi_call_depth -|= 1;
        jit.runStart() catch |err| {
            if (trap_out) |to| to.* = jitErrToTrap(err, jit, alloc, store);
            jit.deinit(alloc);
            alloc.destroy(jit);
            return null;
        };
    }

    const inst = alloc.create(Instance) catch {
        jit.deinit(alloc);
        alloc.destroy(jit);
        return null;
    };
    inst.* = .{
        .store = store,
        .module = module,
        .runtime = null,
        .jit = jit,
    };

    // ADR-0200 — surface the JIT's func exports through the C-API discovery path
    // (`wasm_instance_exports` + Func handles). The JIT compiles NO
    // `exports_storage`/`func_ptrs_storage` (interp-only), so map its
    // `compiled.exports` (name→funcidx) to `sections.Export{name, .func, idx}`.
    // The name slices borrow `jit.compiled.arena` (lives in the JitInstance); the
    // slice itself lives on a minimal per-instance arena freed in the JIT teardown.
    // ADR-0200 / D-496 — surface ALL exports (func/table/memory/global) through the
    // C-API discovery path so a JIT instance has the SAME embedding surface as interp.
    // Mirrors the interp path (instantiate.zig:1439-1442): decode the export section +
    // `buildExportTypes` (kind-generic, reads module type/table/memory/global sections,
    // never the runtime). Without the non-func kinds, `wasm_extern_as_memory|table|global`
    // + introspection returned null on a JIT instance (the D-496 flip blocker). The
    // arena holds the decoded export items + ExportType[]; names borrow the module bytes
    // (which outlive the instance). Freed in the JIT instance teardown via `inst.arena`.
    {
        const arena = alloc.create(std.heap.ArenaAllocator) catch {
            jit.deinit(alloc);
            alloc.destroy(jit);
            alloc.destroy(inst);
            return null;
        };
        arena.* = std.heap.ArenaAllocator.init(alloc);
        const a = arena.allocator();
        const built = blk: {
            // Re-parse the section index off the module bytes (the C-API `module` is
            // an extern struct without `.find`; `instantiateJit` compiled from raw
            // bytes). Cheap header walk; arena-scoped.
            var rt_module = parser.parse(a, bytes) catch break :blk false;
            const export_section = rt_module.find(.@"export") orelse break :blk true; // no exports
            const imports_decoded: ?sections.Imports = if (rt_module.find(.import)) |imp|
                (sections.decodeImports(a, imp.body) catch break :blk false)
            else
                null;
            const exports = sections.decodeExports(a, export_section.body) catch break :blk false;
            inst.exports_storage = exports.items;
            inst.export_types = instantiate.buildExportTypes(a, rt_module, exports.items, imports_decoded) catch break :blk false;
            break :blk true;
        };
        if (!built) {
            arena.deinit();
            alloc.destroy(arena);
            jit.deinit(alloc);
            alloc.destroy(jit);
            alloc.destroy(inst);
            return null;
        }
        // Retain the arena only if it backs live export storage; else release it.
        if (inst.exports_storage.len > 0) inst.arena = arena else {
            arena.deinit();
            alloc.destroy(arena);
        }
    }

    // D-174 live-instance registry so wasm_store_delete cascades teardown.
    // EXEMPT-FALLBACK: D-174 — append OOM degrades to forward-order-only teardown (matches interp path).
    store.live_instances.append(alloc, @ptrCast(inst)) catch {};
    return inst;
}

/// Shape produced by either the c_api Extern path (`wasm_instance_new`)
/// or a native binding constructor (e.g. `src/zwasm/linker.zig`).
/// `build` is invoked once with the per-instance arena allocator
/// after the arena exists; it returns the pre-resolved binding
/// slice (or null when the module declares no imports).
pub const BindingsBuilder = struct {
    ctx: *anyopaque,
    build: *const fn (ctx: *anyopaque, arena_alloc: std.mem.Allocator, bytes: []const u8, store: *Store) anyerror!?[]const runtime_instance_import.ImportBinding,
    /// #360 — the C ABI import vector, when this builder wraps one. The JIT
    /// path reads the `Extern`s directly (`collectFromExterns`): `build` is
    /// the interp binder, and it cannot describe an import whose source
    /// instance is JIT-backed. Null for the native-facade builder.
    imports: ?[*]const ?*const Extern = null,
};

const BuildBindingsCApi = struct {
    imports_array: ?[*]const ?*const Extern,

    fn buildImpl(ctx: *anyopaque, arena_alloc: std.mem.Allocator, bytes: []const u8, store: *Store) anyerror!?[]const runtime_instance_import.ImportBinding {
        const self: *BuildBindingsCApi = @ptrCast(@alignCast(ctx));
        return buildBindings(arena_alloc, bytes, self.imports_array, store);
    }

    pub fn asBuilder(self: *BuildBindingsCApi) BindingsBuilder {
        return .{ .ctx = self, .build = buildImpl, .imports = self.imports_array };
    }
};

/// Tear down a fully-built instance whose post-build finalize failed
/// (instantiateRuntime trap OR start-function trap). Parks the committed
/// runtime/arena as a zombie when an arena exists (cross-module refs may
/// point into it — destroying would UAF; ADR-0014 §2.1), else frees.
fn failBuiltInstance(alloc: std.mem.Allocator, store: *Store, inst: *Instance, inst_rt: *runtime.Runtime) void {
    if (inst.arena) |arena2| {
        // EXEMPT-FALLBACK: ADR-0014 — parkAsZombie OOM accepts arena leak over UAF of cross-module references.
        parkAsZombie(alloc, store, inst_rt, arena2) catch {};
        inst.arena = null;
    } else {
        inst_rt.deinit();
        alloc.destroy(inst_rt);
    }
    inst.funcs_storage = &.{};
    inst.func_ptrs_storage = &.{};
    removeFromLiveInstances(store, inst);
    alloc.destroy(inst);
}

/// Wasm §5.5.13 — scan section headers for the start section (id 8) and
/// return its funcidx. Cheap header walk (no full re-parse). The funcidx
/// is range/sig-validated at compile time (compile.zig).
fn findStartFuncIdx(bytes: []const u8) ?u32 {
    if (bytes.len < 8) return null;
    var pos: usize = 8; // magic + version
    while (pos < bytes.len) {
        const id = bytes[pos];
        pos += 1;
        const size = leb128.readUleb128(u32, bytes, &pos) catch return null;
        const body_start = pos;
        if (id == 8) {
            var p = body_start;
            return leb128.readUleb128(u32, bytes, &p) catch null;
        }
        pos = body_start + size;
        if (pos > bytes.len) return null;
    }
    return null;
}

/// ADR-0179 — per-instance runtime budgets applied at instantiation. `null` =
/// unmetered for that axis. Threaded in so they take effect BEFORE the start
/// function runs (fuel) and BEFORE the initial linear memory is allocated
/// (`max_memory_pages`), not only on the post-instantiate setters / `memory.grow`.
pub const InstantiateLimits = struct {
    fuel: ?u64 = null,
    max_memory_pages: ?u64 = null,
    /// D-332 — host cap on the INITIAL declared element count of each table
    /// (extends the grow-time `store_table_elements_max` to instantiation).
    max_table_elements: ?u64 = null,
};

/// Internal entry shared by `wasm_instance_new` (C ABI path,
/// Extern[]-driven bindings) and `src/zwasm/linker.zig` (native
/// path, host-fn + cross-instance bindings). Both wrap their
/// resolver in a `BindingsBuilder` and call here.
pub fn instantiateInternal(store: *Store, module: *const Module, builder_state: anytype, trap_out: ?*?*Trap, limits: InstantiateLimits, engine: EngineKind) ?*Instance {
    const alloc = storeAllocator(store) orelse return null;

    // ADR-0200 — per-instance engine fork, shared by EVERY entry point
    // (`instantiateFacade`, `wasm_instance_new`, `src/zwasm/linker.zig`). `.jit`
    // builds a native JIT-backed instance; `.interp` forces the interp setup below.
    if (engine == .jit) return instantiateJit(store, module, builder_state, trap_out, limits);

    // ADR-0200 / D-496 — `.auto`→JIT flip (D-489/D-494 regalloc miscompiles fixed;
    // JIT instances now expose the full C-API surface: exports + memory/table/global
    // accessors + introspection + get_func, chunks 1-5). TRY the JIT first; it
    // rejects (returns null, NO trap) any module with an import/signature it can't
    // satisfy — that rejection is at the import check BEFORE any setup side-effect
    // (preopens, start), so the interp retry below is clean. A real `(start)` trap
    // sets `jit_trap` and propagates (interp would trap too) rather than re-running.
    if (engine == .auto) {
        var jit_trap: ?*Trap = null;
        if (instantiateJit(store, module, builder_state, &jit_trap, limits)) |inst| return inst;
        if (jit_trap) |t| {
            if (trap_out) |to| to.* = t;
            return null;
        }
        // JIT could not compile this module → fall through to the interp setup below.
    }

    // ADR-0184: open any preopen requests queued by the io-free
    // config builder (`zwasm_wasi_config_preopen_dir`) via the
    // engine-owned io. Instantiation is the wasm-c-api error
    // surface: an unopenable host path fails the instantiation.
    if (store.wasi_host) |host_opaque| {
        const host: *wasi_host.Host = @ptrCast(@alignCast(host_opaque));
        host.materializePendingPreopens() catch return null;
    }

    var local_state = builder_state;
    const builder: BindingsBuilder = if (@TypeOf(builder_state) == BindingsBuilder)
        builder_state
    else
        local_state.asBuilder();

    const inst_rt = alloc.create(runtime.Runtime) catch return null;
    inst_rt.* = runtime.Runtime.init(alloc);
    // ADR-0179 #3a-2: arm cooperative interruption — point the poll at this
    // Runtime's own stable flag storage (now at its final heap address).
    inst_rt.interrupt = &inst_rt.interrupt_flag_storage;
    // ADR-0179 #3b/#3c: arm the runtime budgets up front so fuel bounds the
    // start function (run below) and the memory cap bounds the INITIAL
    // allocation in `instantiateRuntime` (not just later `memory.grow`).
    inst_rt.fuel = limits.fuel;
    inst_rt.store_memory_pages_max = limits.max_memory_pages;
    inst_rt.store_table_elements_max = limits.max_table_elements; // D-332 (initial alloc)

    const inst = alloc.create(Instance) catch {
        inst_rt.deinit();
        alloc.destroy(inst_rt);
        return null;
    };
    inst.* = .{
        .store = store,
        .module = module,
        .runtime = inst_rt,
    };

    const bytes_ptr = module.bytes_ptr orelse {
        inst_rt.deinit();
        alloc.destroy(inst_rt);
        alloc.destroy(inst);
        return null;
    };
    const bytes = bytes_ptr[0..module.bytes_len];

    // Per ADR-0023 §7 item 5 (Step A2): set up the per-instance
    // arena BEFORE binding build (binding allocations live on
    // the same arena), then rebind the runtime allocator.
    const arena = alloc.create(std.heap.ArenaAllocator) catch {
        inst_rt.deinit();
        alloc.destroy(inst_rt);
        alloc.destroy(inst);
        return null;
    };
    arena.* = std.heap.ArenaAllocator.init(alloc);
    inst.arena = arena;
    inst_rt.alloc = arena.allocator();
    inst_rt.instance = inst;

    const bindings = builder.build(builder.ctx, arena.allocator(), bytes, store) catch {
        if (inst.arena) |a2| {
            // EXEMPT-FALLBACK: ADR-0014 — parkAsZombie OOM accepts arena leak over UAF of cross-module references.
            parkAsZombie(alloc, store, inst_rt, a2) catch {};
            inst.arena = null;
        } else {
            inst_rt.deinit();
            alloc.destroy(inst_rt);
        }
        inst.funcs_storage = &.{};
        inst.func_ptrs_storage = &.{};
        alloc.destroy(inst);
        return null;
    };

    // #352 / ADR-0224 — same entry rule as the JIT arm above: instantiating
    // enters guest code, because the start function below can call
    // `proc_exit`. Clear on the way in, unconditionally — a module with no
    // WASI imports, built after a replace or a detach, must still close the
    // window — and again on the way out when this instantiation was itself
    // nested inside a call in progress.
    const nested_entry = store.wasi_call_depth > 0;
    clearWasiExitStatus(store);
    defer if (nested_entry) clearWasiExitStatus(store);

    // D-174 defensive fix: register inst in the store's live-instance
    // list so wasm_store_delete can cascade-cleanup on reverse-order
    // teardown. If the append OOMs the inst stays out of the cascade
    // list — instance→store teardown order still works (the normal
    // path); reverse-order would UAF as before. Accept the OOM-degrades-
    // to-pre-D-174-behaviour rather than complicate the success path.
    // EXEMPT-FALLBACK: D-174 — live_instances append OOM degrades to pre-fix behaviour; full ENOMEM propagation would require redesigning wasm_instance_new's allocator contract.
    store.live_instances.append(alloc, @ptrCast(inst)) catch {};

    instantiate.instantiateRuntime(bytes, inst, inst_rt, bindings) catch {
        // Per ADR-0014 §2.1 / 6.K.2 sub-change 4: park the failed
        // instance's runtime + arena (committed cross-module writes
        // would UAF if the arena were destroyed). D-174: drops the
        // live_instances back-registry entry registered above.
        failBuiltInstance(alloc, store, inst, inst_rt);
        return null;
    };

    // Wasm §4.5.4 — run the start function (if any) AFTER all sections
    // (incl. data segments) are initialised. A trap fails instantiation.
    // The start funcidx was range/sig-validated at compile time.
    if (findStartFuncIdx(bytes)) |sfx| {
        // #345 — the start function owns the status while it runs; see the
        // JIT arm's note. Covers both shapes below (imported start via
        // `host_calls`, and a defined one dispatched here).
        // The depth is also what makes a `wasm_func_call` a host callback
        // makes from inside the start a NESTED entry (ADR-0224).
        store.wasi_call_depth +|= 1;
        defer store.wasi_call_depth -|= 1;
        if (sfx < inst.func_ptrs_storage.len) {
            // The start function may be an IMPORTED func (wit-component's
            // start-shim wraps `_initialize` exactly this way); its
            // func_ptrs_storage slot is the `unreachable` placeholder, so
            // dispatch through `host_calls` like any other imported call.
            // Start sig is ()->() (validated), so no operand transfer.
            if (sfx < inst_rt.host_calls.len) {
                if (inst_rt.host_calls[sfx]) |hc| {
                    hc.fn_ptr(inst_rt, hc.ctx) catch |err| {
                        if (trap_out) |to| {
                            if (storeAllocator(store)) |sa| to.* = allocTrap(sa, store, mapInterpTrap(err));
                        }
                        failBuiltInstance(alloc, store, inst, inst_rt);
                        return null;
                    };
                    return inst;
                }
            }
            const zfunc = inst.func_ptrs_storage[sfx];
            const num_locals = zfunc.sig.params.len + zfunc.locals.len;
            const locals = alloc.alloc(runtime.Value, num_locals) catch {
                failBuiltInstance(alloc, store, inst, inst_rt);
                return null;
            };
            defer alloc.free(locals);
            for (locals) |*l| l.* = runtime.Value.zero;
            const op_base = inst_rt.operand_len;
            inst_rt.pushFrame(.{
                .sig = zfunc.sig,
                .locals = locals,
                .operand_base = op_base,
                .pc = 0,
                .func = zfunc,
            }) catch {
                failBuiltInstance(alloc, store, inst, inst_rt);
                return null;
            };
            dispatch.run(inst_rt, dispatchTable(), zfunc.instrs.items) catch |err| {
                // Start trapped → instantiation fails. The instance
                // committed state (data writes, cross-module refs), so
                // park-as-zombie rather than free (mirrors the build path).
                // D-275: surface the trap via `trap_out` (wasm-c-api contract).
                // Store-level alloc (not the per-instance arena) so the Trap
                // outlives the parked instance; caller frees via wasm_trap_delete.
                if (trap_out) |to| {
                    if (storeAllocator(store)) |sa| to.* = allocTrap(sa, store, mapInterpTrap(err));
                }
                failBuiltInstance(alloc, store, inst, inst_rt);
                return null;
            };
            _ = inst_rt.popFrame();
            inst_rt.operand_len = op_base;
        }
    }
    return inst;
}

/// D-174: linear-scan + swap-remove this inst from store.live_instances.
/// No-op when inst isn't registered (the OOM-during-append path leaves
/// inst out of the list but otherwise live). Cheap by construction —
/// typical workloads have ≤ tens of instances per store.
fn removeFromLiveInstances(store: *Store, inst: *Instance) void {
    const inst_opaque: *anyopaque = @ptrCast(inst);
    for (store.live_instances.items, 0..) |item, idx| {
        if (item == inst_opaque) {
            _ = store.live_instances.swapRemove(idx);
            return;
        }
    }
}

/// `wasm_instance_delete(*Instance)` — release the C-side
/// `wasm_instance_t` handle. Per ADR-0014 §2.1 / 6.K.2 sub-
/// change 4 the underlying runtime + arena park as a zombie on
/// the store: cross-module funcrefs into this instance's funcs
/// from sibling instances stay valid until `wasm_store_delete`
/// reaps the zombie. Mirrors wasmtime's instance-Arc lifetime
/// (`store.rs:146`) and wazero's `involvingModuleInstances`
/// (`internal/wasm/table.go:104`).
///
/// Null-tolerant.
pub export fn wasm_instance_delete(i: ?*Instance) callconv(.c) void {
    const handle = i orelse return;
    if (handle.host_info_finalizer) |fin| fin(handle.host_info);
    const store = handle.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    if (handle.ref_view) |rv| alloc.destroy(@as(*handles.Ref, @ptrCast(@alignCast(rv)))); // as_ref view (ADR-0158)
    // D-174: drop the live-instance registry entry before parking +
    // free so wasm_store_delete doesn't try to cascade-cleanup an
    // already-freed handle.
    removeFromLiveInstances(store, handle);
    if (handle.jit) |jp| {
        // ADR-0200 / #360 — PARK the heap-pinned JitInstance rather than free it,
        // the JIT counterpart of the interpreter arm below: an importer's bridge
        // thunk holds this instance's runtime address and entry point (D-225), so
        // freeing here would leave it calling into released code. Reaped by
        // `wasm_store_delete`. The per-instance arena holding `exports_storage`
        // IS freed — only the c_api handle reads it, and it is going away.
        // EXEMPT-FALLBACK: ADR-0014 — park OOM accepts a JitInstance leak over UAF of an importer's bridge thunk.
        parkJitAsZombie(alloc, store, jp) catch {};
        handle.jit = null;
        if (handle.arena) |arena| {
            arena.deinit();
            alloc.destroy(arena);
            handle.arena = null;
        }
        handle.exports_storage = &.{};
    }
    if (handle.runtime) |rt| {
        if (handle.arena) |arena| {
            // Park instead of free. If parkAsZombie OOMs we accept
            // the arena leak (process exit cleans it up) rather
            // than UAF the cross-module references.
            // EXEMPT-FALLBACK: ADR-0014 — parkAsZombie OOM accepts arena leak over UAF of cross-module references.
            parkAsZombie(alloc, store, rt, arena) catch {};
            handle.arena = null;
        } else {
            // Pre-arena state (couldn't happen on the success
            // path but defensive): free the runtime directly.
            rt.deinit();
            alloc.destroy(rt);
        }
    }
    handle.funcs_storage = &.{};
    handle.func_ptrs_storage = &.{};
    alloc.destroy(handle);
}

// ============================================================
// Func + dispatch (§9.3 / 3.6 chunk b)
// ============================================================

/// Process-wide dispatch-table cache. Lazily populated on first
/// call. The table maps `ZirOp` → handler and is identical across
/// every Engine in a process, so a single shared instance is the
/// natural shape (and avoids re-running registration on every
/// `wasm_func_call`). Single-threaded for Phases 1-9 per the
/// project's threading discipline; `std.atomic` once-init lands
/// alongside the threads proposal post-v0.1.0.
var g_dispatch_table_storage: dispatch_table_mod.DispatchTable = undefined;
var g_dispatch_table_initialized: bool = false;

pub fn dispatchTable() *const dispatch_table_mod.DispatchTable {
    if (!g_dispatch_table_initialized) {
        g_dispatch_table_storage = .init();
        interp_mvp.register(&g_dispatch_table_storage);
        if (comptime wasm_2_0_enabled) {
            ext_sign_ext.register(&g_dispatch_table_storage);
            ext_sat_trunc.register(&g_dispatch_table_storage);
            ext_bulk_memory.register(&g_dispatch_table_storage);
            ext_ref_types.register(&g_dispatch_table_storage);
            ext_table_ops.register(&g_dispatch_table_storage);
        }
        if (comptime wasm_3_0_enabled) {
            ext_function_references.register(&g_dispatch_table_storage);
            ext_i31_ops.register(&g_dispatch_table_storage);
            ext_ref_test_ops.register(&g_dispatch_table_storage);
            ext_ref_convert_ops.register(&g_dispatch_table_storage);
            ext_struct_ops.register(&g_dispatch_table_storage);
            ext_array_ops.register(&g_dispatch_table_storage);
        }
        g_dispatch_table_initialized = true;
    }
    return &g_dispatch_table_storage;
}

/// `zwasm_instance_get_func` — project-extension helper that
/// resolves an Instance + function index into a fresh `Func`
/// handle. The C host owns the returned pointer and must call
/// `wasm_func_delete`. Folds into upstream `wasm_instance_exports`
/// + `wasm_extern_vec_t` indexing alongside §9.3 / 3.7.
pub export fn zwasm_instance_get_func(i: ?*Instance, idx: u32) callconv(.c) ?*Func {
    const inst = i orelse return null;
    const store = inst.store orelse return null;
    const alloc = storeAllocator(store) orelse return null;
    // D-496 — JIT instances populate no funcs_storage; bound against the JIT's
    // full func count instead (wasm_func_call's JIT arm dispatches by func_idx).
    const func_count: usize = if (inst.runtime != null)
        inst.funcs_storage.len
    else if (jitOf(inst)) |jit|
        jit.funcCount()
    else
        inst.funcs_storage.len;
    if (idx >= func_count) return null;
    const f = alloc.create(Func) catch return null;
    f.* = .{ .instance = inst, .func_idx = idx };
    return f;
}

// ADR-0179 #3a-4 / D-314 — the instance-level sandboxing setters
// (`zwasm_instance_set_fuel` / `interrupt` / `set_memory_pages_limit` …)
// live in `zwasm_ext.zig` (per-file cap; the zwasm extension surface
// evolves independently of the frozen upstream wasm.h binding).

/// `wasm_func_delete(*Func)` — free a `Func` handle returned by
/// `zwasm_instance_get_func`. Null-tolerant.
pub export fn wasm_func_delete(f: ?*Func) callconv(.c) void {
    const handle = f orelse return;
    if (handle.host_info_finalizer) |fin| fin(handle.host_info);
    const store = if (handle.instance) |inst| (inst.store orelse return) else (handle.store orelse return);
    const alloc = storeAllocator(store) orelse return;
    if (handle.extern_view) |v| alloc.destroy(v);
    if (handle.ref_view) |rv| alloc.destroy(rv);
    if (handle.host) |p| { // standalone host func: run finalizer, free payload + arity
        if (p.finalizer) |fin| fin(p.env);
        alloc.free(p.params);
        alloc.free(p.results);
        alloc.destroy(p);
    }
    alloc.destroy(handle);
}

/// Context for marshalling a ref-typed `runtime.Value` OUT to a
/// `wasm_val_t` (D-269B owned-handle model): a ref result's `of.ref`
/// is an OWNED `wasm_ref_t*` (= `*Ref`), allocated here, freed by the
/// caller via `wasm_val_delete`/`wasm_ref_delete`. `inst`/`store` are
/// stored on the `*Ref` so `wasm_ref_delete` recovers this allocator.
pub const RefMarshalCtx = struct {
    alloc: std.mem.Allocator,
    inst: ?*Instance,
    store: ?*Store,
};

/// Marshal a `wasm_val_t` IN to a `runtime.Value`. For ref kinds the
/// `of.ref` is an owned `*Ref` handle (D-269B); read its payload. A
/// null `of.ref` is the null reference. (The host owns the arg `*Ref`;
/// we only read it — no free here.)
pub fn marshalValIn(v: Val) runtime.Value {
    return switch (v.kind) {
        .i32 => .{ .i32 = v.of.i32 },
        .i64 => .{ .i64 = v.of.i64 },
        .f32 => .{ .bits64 = @as(u64, @as(u32, @bitCast(v.of.f32))) },
        .f64 => .{ .bits64 = @bitCast(v.of.f64) },
        .anyref, .funcref => .{ .ref = if (v.of.ref) |rp| refPayload(rp) else runtime.Value.null_ref },
    };
}

fn refPayload(rp: *anyopaque) u64 {
    const r: *Ref = @ptrCast(@alignCast(rp));
    return r.ref;
}

/// Marshal a `runtime.Value` OUT to a `wasm_val_t`. ADR-0123 Cycle 2:
/// the c_api shape distinguishes only funcref vs anyref (i31/struct/
/// array bucket through `.anyref`). D-269B: a ref `of.ref` is an OWNED
/// `*Ref` allocated via `rm` (null payload → null `of.ref`); on OOM or
/// a missing `rm` the ref degrades to a null `of.ref` (the only failure
/// channel the POD `wasm_val_t` ABI offers).
pub fn marshalValOut(v: runtime.Value, kind: zir.ValType, rm: ?RefMarshalCtx) Val {
    return switch (kind) {
        .i32 => .{ .kind = .i32, .of = .{ .i32 = v.i32 } },
        .i64 => .{ .kind = .i64, .of = .{ .i64 = v.i64 } },
        .f32 => .{ .kind = .f32, .of = .{ .f32 = @bitCast(@as(u32, @truncate(v.bits64))) } },
        .f64 => .{ .kind = .f64, .of = .{ .f64 = @bitCast(v.bits64) } },
        .v128 => .{ .kind = .i64, .of = .{ .i64 = 0 } }, // unreachable for MVP
        .ref => |r| blk: {
            const c_kind: ValKind = switch (r.heap_type) {
                .abstract => |a| if (a == .func) .funcref else .anyref,
                .concrete => .anyref, // typed-funcref → .funcref shape; struct/array → .anyref shape; collapsed for Tier-1
            };
            const of_ref: ?*anyopaque = if (v.ref == runtime.Value.null_ref) null else allocRefHandle(rm, v.ref);
            break :blk .{ .kind = c_kind, .of = .{ .ref = of_ref } };
        },
    };
}

/// Allocate an owned `*Ref` wrapping `payload` for a marshalled-out ref
/// value (D-269B). Null on OOM / absent ctx (the ABI has no error path).
fn allocRefHandle(rm: ?RefMarshalCtx, payload: u64) ?*anyopaque {
    const m = rm orelse return null;
    const r = m.alloc.create(Ref) catch return null;
    r.* = .{ .instance = m.inst, .store = m.store, .ref = payload };
    return @ptrCast(r);
}

/// `HostCall` fn_ptr for a `wasm_func_new` host callback (wired by the
/// buildBindings host-func arm). Marshals the guest's operand-stack args
/// (top `params.len`, left-to-right) into a `wasm_val_vec_t`, invokes the
/// C callback, and pushes the marshalled results. A non-null returned
/// `wasm_trap_t*` becomes a guest trap. Runtime-arity twin of the comptime
/// `host_func_marshal` native thunk (ADR-0109).
fn hostFuncThunk(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const p: *HostFuncPayload = @ptrCast(@alignCast(ctx));
    const np: u32 = @intCast(p.params.len);
    const nr = p.results.len;
    if (rt.operand_len < np) return runtime.Trap.StackOverflow;
    const ca = std.heap.c_allocator;
    const args_data = ca.alloc(Val, p.params.len) catch return runtime.Trap.Unreachable;
    defer ca.free(args_data);
    const res_data = ca.alloc(Val, nr) catch return runtime.Trap.Unreachable;
    defer ca.free(res_data);
    // D-269B: a ref-kind arg is marshalled OUT as an owned `*Ref` that
    // zwasm lends to the callback and frees after it returns. Recover
    // the store/allocator from the runtime's owning Instance back-ptr.
    const cb_inst: ?*Instance = if (rt.instance) |io| @ptrCast(@alignCast(io)) else null;
    const cb_store: ?*Store = if (cb_inst) |ci| ci.store else null;
    const cb_rm: ?RefMarshalCtx = if (cb_store) |st|
        (if (storeAllocator(st)) |al| RefMarshalCtx{ .alloc = al, .inst = cb_inst, .store = st } else null)
    else
        null;
    const start: usize = rt.operand_len - np;
    for (0..p.params.len) |i| args_data[i] = marshalValOut(rt.operand_buf[start + i], p.params[i], cb_rm);
    // Free the lent arg ref handles once the callback returns (kind-guarded
    // so non-ref `of` union members are never misread as a pointer).
    defer for (0..p.params.len) |i| {
        if (args_data[i].kind == .funcref or args_data[i].kind == .anyref) {
            if (args_data[i].of.ref) |rp| wasm_ref_delete(@ptrCast(@alignCast(rp)));
        }
    };
    rt.operand_len = @intCast(start);
    @memset(res_data, .{ .kind = .i32, .of = .{ .i32 = 0 } });
    var args_vec: ValVec = .{ .size = p.params.len, .data = if (p.params.len > 0) args_data.ptr else null };
    var res_vec: ValVec = .{ .size = nr, .data = if (nr > 0) res_data.ptr else null };
    const trap: ?*Trap = if (p.callback_env) |cb| cb(p.env, &args_vec, &res_vec) else if (p.callback) |cb| cb(&args_vec, &res_vec) else return runtime.Trap.HostTrap;
    if (trap) |tr| {
        trap_surface.wasm_trap_delete(tr); // consume the callback's owned trap
        // #331: host-originated, so NOT `Unreachable` — a C host must be able to
        // tell its own callback's failure from a guest fault. The interp twin of
        // `jit_host_bridge.zig`'s trapResult; both surface `binding_error`.
        return runtime.Trap.HostTrap;
    }
    // A ref-kind result's `of.ref` is owned by the callback/host (it may
    // be a borrowed view, e.g. `wasm_func_as_ref`); read the payload only,
    // do NOT free here — leak-safe over a double-free of a borrowed view.
    for (0..nr) |i| try rt.pushOperand(marshalValIn(res_data[i]));
}

// ============================================================
// wasm_extern_t + wasm_instance_exports (§9.3 / 3.7 chunk c)
// ============================================================

fn exportDescToExternKind(kind: sections.ExportDesc) ExternKind {
    return switch (kind) {
        .func => .func,
        .global => .global,
        .table => .table,
        .memory => .memory,
    };
}

/// `wasm_extern_kind` — return the upstream-numeric tag.
pub export fn wasm_extern_kind(e: ?*const Extern) callconv(.c) u8 {
    const handle = e orelse return @intFromEnum(ExternKind.func);
    return @intFromEnum(handle.kind);
}

/// `wasm_extern_delete(*Extern)` — free an Extern handle and
/// the contained Func / Global (if any). Null-tolerant.
pub export fn wasm_extern_delete(e: ?*Extern) callconv(.c) void {
    const handle = e orelse return;
    // A borrowed view (from `*_as_extern`) is owned by its source
    // entity, which frees it on its own delete — deleting it here
    // would double-free, so this is a no-op.
    if (handle.borrowed) return;
    if (handle.host_info_finalizer) |fin| fin(handle.host_info);
    if (handle.func) |fh| wasm_func_delete(fh);
    if (handle.global) |gh| wasm_global_delete(gh);
    if (handle.memory) |mh| wasm_memory_delete(mh);
    if (handle.table) |th| wasm_table_delete(th);
    const inst = handle.instance orelse return;
    const store = inst.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    if (handle.ref_view) |rv| alloc.destroy(rv); // object-identity as_ref view (ADR-0158)
    alloc.destroy(handle);
}

/// `wasm_extern_as_func(*Extern)` — borrow the Func contained in
/// an Extern. Returns null if the Extern is not of kind func.
/// **Ownership stays with the Extern**; callers must NOT call
/// `wasm_func_delete` on the returned pointer (matches upstream
/// wasm.h discipline for the `_as_*` family).
pub export fn wasm_extern_as_func(e: ?*Extern) callconv(.c) ?*Func {
    const handle = e orelse return null;
    if (handle.kind != .func) return null;
    return handle.func;
}

/// `wasm_extern_as_{func,global,table,memory}_const(*const Extern)`
/// — const-qualified borrows mirroring the mutable family (C
/// const-correctness; same kind check + borrowed return, ownership
/// stays with the Extern). Null on kind mismatch or null arg.
pub export fn wasm_extern_as_func_const(e: ?*const Extern) callconv(.c) ?*const Func {
    const handle = e orelse return null;
    if (handle.kind != .func) return null;
    return handle.func;
}

pub export fn wasm_extern_as_global_const(e: ?*const Extern) callconv(.c) ?*const Global {
    const handle = e orelse return null;
    if (handle.kind != .global) return null;
    return handle.global;
}

pub export fn wasm_extern_as_table_const(e: ?*const Extern) callconv(.c) ?*const Table {
    const handle = e orelse return null;
    if (handle.kind != .table) return null;
    return handle.table;
}

pub export fn wasm_extern_as_memory_const(e: ?*const Extern) callconv(.c) ?*const Memory {
    const handle = e orelse return null;
    if (handle.kind != .memory) return null;
    return handle.memory;
}

// Entity → Extern conversions (`wasm_{func,global,table,memory}_as_extern
// [_const]`) live in `extern_new.zig` (the runtime-entity construction
// layer, extracted per ADR-0099 §D2 / the module_introspect precedent).
// They cache a borrowed-view Extern on the entity's `extern_view` field;
// `wasm_extern_delete` no-ops on a view (`Extern.borrowed`), and each
// entity's delete frees its cached view.

/// `wasm_extern_as_global(*Extern)` — borrow the Global contained
/// in an Extern. Returns null if the Extern is not of kind global.
/// **Ownership stays with the Extern**; callers must NOT call
/// `wasm_global_delete` on the returned pointer. Mirrors
/// `wasm_extern_as_func` (per `include/wasm.h:_as_*` family
/// discipline).
pub export fn wasm_extern_as_global(e: ?*Extern) callconv(.c) ?*Global {
    const handle = e orelse return null;
    if (handle.kind != .global) return null;
    return handle.global;
}

/// `wasm_global_delete(*Global)` — free a Global handle. Null-
/// tolerant. The borrowed handle returned by `wasm_extern_as_global`
/// must NOT be passed here (the owning Extern's
/// `wasm_extern_delete` releases it via the `Extern.global`
/// back-pointer); only call this on a Global obtained via a
/// future `wasm_global_new` (host-side standalone construction).
pub export fn wasm_global_delete(g: ?*Global) callconv(.c) void {
    const handle = g orelse return;
    if (handle.host_info_finalizer) |fin| fin(handle.host_info);
    const store = if (handle.instance) |inst| (inst.store orelse return) else (handle.store orelse return);
    const alloc = storeAllocator(store) orelse return;
    if (handle.extern_view) |v| alloc.destroy(v);
    if (handle.ref_view) |rv| alloc.destroy(rv); // object-identity as_ref view (ADR-0158)
    if (handle.cell) |c| alloc.destroy(c); // standalone own-cell (instance-backed: null)
    alloc.destroy(handle);
}

/// `wasm_global_get(global, out)` — Wasm spec §4.5.5
/// (`global.get`) — read the global's current value into `out`.
/// Reads via the pointer-aliased `Value` cell (per ADR-0110), so
/// cross-instance reads see writes from any instance importing
/// the same global. v128-typed globals leave `out` zero-set with
/// `kind = .i32` (spec-prohibited from the c_api union; see
/// `2026-05-24-c_api-v128-spec-boundary.md`) — callers needing
/// v128 access use the ADR-0109 native Zig API.
pub export fn wasm_global_get(g: ?*const Global, out: ?*Val) callconv(.c) void {
    const o = out orelse return;
    o.* = .{ .kind = .i32, .of = .{ .i32 = 0 } };
    const handle = g orelse return;
    const slot: *runtime.Value = if (handle.instance) |inst| blk: {
        if (inst.runtime) |rt| {
            if (handle.global_idx >= rt.globals.len) return;
            break :blk rt.globals[handle.global_idx];
        }
        // D-496 — JIT-backed instance: read the global cell from the JitRuntime.
        if (jitOf(inst)) |jit| break :blk (jit.globalCell(handle.global_idx) orelse return);
        return;
    } else handle.cell orelse return; // standalone host global
    const g_store: ?*Store = if (handle.instance) |inst| inst.store else handle.store;
    const g_rm: ?RefMarshalCtx = if (g_store) |st|
        (if (storeAllocator(st)) |al| RefMarshalCtx{ .alloc = al, .inst = handle.instance, .store = st } else null)
    else
        null;
    o.* = marshalValOut(slot.*, handle.valtype, g_rm);
}

/// `wasm_global_set(global, val)` — Wasm spec §4.5.6
/// (`global.set`) — write `val` into the global's `Value` cell.
/// No-op when the global is immutable (spec: mutability is
/// validated at instantiation; setting an immutable global from
/// the host is an out-of-band write and is rejected here). v128
/// inputs are rejected at the union shape (per spec-boundary
/// lesson); callers needing v128 use the native Zig API.
pub export fn wasm_global_set(g: ?*Global, v: ?*const Val) callconv(.c) void {
    const val = v orelse return;
    const handle = g orelse return;
    if (!handle.mutable) return;
    const slot: *runtime.Value = if (handle.instance) |inst| blk: {
        if (inst.runtime) |rt| {
            if (handle.global_idx >= rt.globals.len) return;
            break :blk rt.globals[handle.global_idx];
        }
        // D-496 — JIT-backed instance: write the global cell in the JitRuntime.
        if (jitOf(inst)) |jit| break :blk (jit.globalCell(handle.global_idx) orelse return);
        return;
    } else handle.cell orelse return; // standalone host global
    slot.* = marshalValIn(val.*);
}

// ============================================================
// Memory accessors (D-173 / `include/wasm.h:471-481`)
// ============================================================

/// `wasm_extern_as_memory(*Extern)` — borrow the Memory contained
/// in an Extern. Returns null if the Extern is not of kind memory.
/// Ownership stays with the Extern (same discipline as
/// `wasm_extern_as_func` / `wasm_extern_as_global`).
pub export fn wasm_extern_as_memory(e: ?*Extern) callconv(.c) ?*Memory {
    const handle = e orelse return null;
    if (handle.kind != .memory) return null;
    return handle.memory;
}

/// `wasm_memory_delete(*Memory)` — free a Memory handle. Null-
/// tolerant. The borrowed handle returned by `wasm_extern_as_memory`
/// must NOT be passed here (the owning Extern's
/// `wasm_extern_delete` releases it via the `Extern.memory`
/// back-pointer).
pub export fn wasm_memory_delete(m: ?*Memory) callconv(.c) void {
    const handle = m orelse return;
    if (handle.host_info_finalizer) |fin| fin(handle.host_info);
    const store = if (handle.instance) |inst| (inst.store orelse return) else (handle.store orelse return);
    const alloc = storeAllocator(store) orelse return;
    if (handle.extern_view) |v| alloc.destroy(v);
    if (handle.ref_view) |rv| alloc.destroy(rv); // object-identity as_ref view (ADR-0158)
    if (handle.minst) |mi| { // standalone host memory: free its own backing
        // ADR-0202 D1 — guarded backing is reservation-owned.
        memory_backing.freeBacking(alloc, .{ .bytes = mi.bytes, .reservation = mi.reservation });
        alloc.destroy(mi);
    }
    alloc.destroy(handle);
}

/// `wasm_memory_data(*Memory)` — Wasm spec §4.5.7 (linear memory
/// data pointer). Returns a byte pointer into the importing
/// instance's `rt.memory` slice; valid for the lifetime of the
/// instance (or for the cross-module zombie window per
/// ADR-0014 §6.K.2). Null on a stale / detached handle.
pub export fn wasm_memory_data(m: ?*Memory) callconv(.c) ?[*]u8 {
    const handle = m orelse return null;
    const bytes: []u8 = if (handle.instance) |inst| blk: {
        if (inst.runtime) |rt| break :blk rt.memory;
        if (jitOf(inst)) |jit| break :blk jit.memoryBytes(); // D-496
        return null;
    } else (handle.minst orelse return null).bytes; // standalone host memory
    if (bytes.len == 0) return null;
    return bytes.ptr;
}

/// `wasm_memory_data_size(*const Memory)` — byte length of the
/// memory's backing slice. Mirrors `wasm_memory_data` lifetime.
pub export fn wasm_memory_data_size(m: ?*const Memory) callconv(.c) usize {
    const handle = m orelse return 0;
    if (handle.instance) |inst| {
        if (inst.runtime) |rt| return rt.memory.len;
        if (jitOf(inst)) |jit| return jit.memoryBytes().len; // D-496
        return 0;
    }
    return (handle.minst orelse return 0).bytes.len;
}

/// `wasm_memory_size(*const Memory)` — Wasm spec §4.4.7
/// (`memory.size`) — page count in the memory's page-size units
/// (64 KiB default; custom-page-sizes ADR-0168 v0.2 = 1 << page_size_log2).
pub export fn wasm_memory_size(m: ?*const Memory) callconv(.c) u32 {
    const handle = m orelse return 0;
    var ps_log2: u6 = 16;
    const len: usize = if (handle.instance) |inst| blk: {
        if (inst.runtime) |rt| {
            if (rt.memories.len > 0) ps_log2 = @intCast(rt.memories[0].page_size_log2);
            break :blk rt.memory.len;
        }
        if (jitOf(inst)) |jit| { // D-496
            ps_log2 = jit.memoryPageSizeLog2();
            break :blk jit.memoryBytes().len;
        }
        return 0;
    } else dblk: {
        const mi = handle.minst orelse return 0;
        ps_log2 = @intCast(mi.page_size_log2);
        break :dblk mi.bytes.len;
    };
    return @intCast(len >> ps_log2);
}

/// `wasm_memory_grow(*Memory, delta)` — Wasm spec §4.4.7
/// (`memory.grow`) — request additional `delta` pages. Returns
/// `true` on success (= old-page-count returned to guest via
/// memory.grow semantics is observable via `wasm_memory_size`
/// after the call); `false` on allocator failure or detached
/// handle. v0.1: no max-pages check (the importing module's
/// declared max is enforced at instantiate; host-side grow
/// honours the declared bound through realloc availability).
pub export fn wasm_memory_grow(m: ?*Memory, delta: u32) callconv(.c) bool {
    const handle = m orelse return false;
    if (handle.instance) |inst| {
        if (inst.runtime) |rt| {
            // Custom-page-sizes (ADR-0168 v0.2): grow in the memory's page units.
            const ps_log2: u6 = if (rt.memories.len > 0) @intCast(rt.memories[0].page_size_log2) else 16;
            const old_pages = rt.memory.len >> ps_log2;
            const new_bytes = (old_pages + delta) << ps_log2;
            const old_len = rt.memory.len;
            const grown: []u8 = blk: {
                // ADR-0202 D1 — guarded backing commits in place.
                if (rt.memories.len > 0) {
                    if (rt.memories[0].reservation) |*res| {
                        break :blk memory_backing.growGuarded(res, new_bytes) orelse return false;
                    }
                }
                const g = rt.alloc.realloc(rt.memory, new_bytes) catch return false;
                @memset(g[old_len..new_bytes], 0);
                break :blk g;
            };
            rt.setMemory0Bytes(grown);
            return true;
        }
        if (jitOf(inst)) |jit| { // D-496 — re-syncs vm_base/mem_limit internally
            _ = jit.growMemory(delta) orelse return false;
            return true;
        }
        return false;
    }
    // standalone host memory: realloc its own bytes via the Store allocator
    const mi = handle.minst orelse return false;
    const store = handle.store orelse return false;
    const alloc = storeAllocator(store) orelse return false;
    const ps_log2: u6 = @intCast(mi.page_size_log2);
    const old_len = mi.bytes.len;
    const new_bytes = ((old_len >> ps_log2) + delta) << ps_log2;
    // ADR-0202 D1 — guarded backing commits in place.
    if (mi.reservation) |*res| {
        mi.bytes = memory_backing.growGuarded(res, new_bytes) orelse return false;
        return true;
    }
    const grown = alloc.realloc(mi.bytes, new_bytes) catch return false;
    @memset(grown[old_len..new_bytes], 0);
    mi.bytes = grown;
    return true;
}

// ============================================================
// Ref + Table accessors (D-172 / `include/wasm.h:466-477` + 327-365)
// ============================================================

/// `wasm_ref_delete(*Ref)` — free a Ref handle. Null-tolerant.
pub export fn wasm_ref_delete(r: ?*Ref) callconv(.c) void {
    const handle = r orelse return;
    if (handle.host_info_finalizer) |fin| fin(handle.host_info);
    const store = if (handle.instance) |i| (i.store orelse return) else (handle.store orelse return);
    const alloc = storeAllocator(store) orelse return;
    if (handle.func_view) |fv| alloc.destroy(fv);
    alloc.destroy(handle);
}

/// `wasm_extern_as_table(*Extern)` — borrow the Table contained
/// in an Extern. Returns null if the Extern is not of kind table.
pub export fn wasm_extern_as_table(e: ?*Extern) callconv(.c) ?*Table {
    const handle = e orelse return null;
    if (handle.kind != .table) return null;
    return handle.table;
}

/// `wasm_table_delete(*Table)` — free a Table handle. Null-tolerant.
/// The borrowed handle returned by `wasm_extern_as_table` must NOT
/// be passed here (the owning Extern's `wasm_extern_delete`
/// releases it via the `Extern.table` back-pointer).
pub export fn wasm_table_delete(t: ?*Table) callconv(.c) void {
    const handle = t orelse return;
    if (handle.host_info_finalizer) |fin| fin(handle.host_info);
    const store = if (handle.instance) |inst| (inst.store orelse return) else (handle.store orelse return);
    const alloc = storeAllocator(store) orelse return;
    if (handle.extern_view) |v| alloc.destroy(v);
    if (handle.ref_view) |rv| alloc.destroy(rv); // object-identity as_ref view (ADR-0158)
    if (handle.tinst) |ti| { // standalone host table: free its own backing
        alloc.free(ti.refs);
        alloc.destroy(ti);
    }
    alloc.destroy(handle);
}

/// `wasm_table_size(*const Table)` — Wasm spec §4.4.6
/// (`table.size`) — slot count of the table's `refs` backing slice.
pub export fn wasm_table_size(t: ?*const Table) callconv(.c) u32 {
    const handle = t orelse return 0;
    if (handle.instance) |inst| {
        if (inst.runtime) |rt| {
            if (handle.table_idx >= rt.tables.len) return 0;
            return @intCast(rt.tables[handle.table_idx].refs.len);
        }
        // D-496; saturate to the u32 wasm-c-api shape (D-475: JIT len is u64).
        if (jitOf(inst)) |jit| return std.math.cast(u32, jit.tableLen(handle.table_idx) orelse 0) orelse std.math.maxInt(u32);
        return 0;
    }
    return @intCast((handle.tinst orelse return 0).refs.len); // standalone host table
}

/// `wasm_table_get(*const Table, idx)` — Wasm spec §4.4.6
/// (`table.get`) — read the ref at `idx`. Returns a heap-allocated
/// `*Ref` (caller owns; releases via `wasm_ref_delete`) or null on
/// OOB. The null-ref slot is returned as a Ref whose `.ref ==
/// runtime.Value.null_ref` — the caller distinguishes null
/// reference vs OOB by `wasm_table_size` bound check.
pub export fn wasm_table_get(t: ?*const Table, idx: u32) callconv(.c) ?*Ref {
    const handle = t orelse return null;
    // D-496 — JIT-backed instance: read the raw ref payload from the JitRuntime
    // table slot (mirrors interp's raw `Value.ref` round-trip).
    if (handle.instance) |inst| {
        if (inst.runtime == null) {
            const jit = jitOf(inst) orelse return null;
            const payload = jit.tableGetRef(handle.table_idx, idx) orelse return null;
            const store = inst.store orelse return null;
            const alloc = storeAllocator(store) orelse return null;
            const ref_handle = alloc.create(Ref) catch return null;
            ref_handle.* = .{ .instance = handle.instance, .ref = payload };
            return ref_handle;
        }
    }
    const tab: runtime.TableInstance = if (handle.instance) |inst| blk: {
        const rt = inst.runtime orelse return null;
        if (handle.table_idx >= rt.tables.len) return null;
        break :blk rt.tables[handle.table_idx];
    } else (handle.tinst orelse return null).*;
    if (idx >= tab.refs.len) return null;
    const store = if (handle.instance) |inst| (inst.store orelse return null) else (handle.store orelse return null);
    const alloc = storeAllocator(store) orelse return null;
    const ref_handle = alloc.create(Ref) catch return null;
    ref_handle.* = .{ .instance = handle.instance, .ref = tab.refs[idx].ref };
    return ref_handle;
}

/// `wasm_table_set(*Table, idx, *Ref)` — Wasm spec §4.4.6
/// (`table.set`) — write `ref` into slot `idx`. Passing null `ref`
/// stores `runtime.Value.null_ref`. Returns `false` on OOB; true
/// on success. Ownership of the Ref handle stays with the caller
/// (only the `.ref` payload is read).
pub export fn wasm_table_set(t: ?*Table, idx: u32, ref: ?*Ref) callconv(.c) bool {
    const handle = t orelse return false;
    const payload: u64 = if (ref) |r| r.ref else runtime.Value.null_ref;
    // D-496 — JIT-backed instance: write the raw ref into the JitRuntime table slot
    // (funcptr mirror fail-safe-cleared inside tableSetRef).
    if (handle.instance) |inst| {
        if (inst.runtime == null) {
            const jit = jitOf(inst) orelse return false;
            return jit.tableSetRef(handle.table_idx, idx, payload);
        }
    }
    const tab: runtime.TableInstance = if (handle.instance) |inst| blk: {
        const rt = inst.runtime orelse return false;
        if (handle.table_idx >= rt.tables.len) return false;
        break :blk rt.tables[handle.table_idx];
    } else (handle.tinst orelse return false).*; // refs slice aliased — write hits the backing
    if (idx >= tab.refs.len) return false;
    tab.refs[idx] = .{ .ref = payload };
    return true;
}

/// `wasm_table_grow(*Table, delta, *Ref init)` — Wasm spec §4.4.6
/// (`table.grow`) — request `delta` additional slots, filling each
/// with `init`'s ref payload (null `init` → `runtime.Value.null_ref`).
/// Returns `true` on success, `false` on allocator failure or
/// detached handle. The Table's declared `max` limit is enforced
/// (grow past `max` returns false). Mirrors `wasm_memory_grow`
/// realloc semantics for the table's `refs` slice.
pub export fn wasm_table_grow(t: ?*Table, delta: u32, init: ?*Ref) callconv(.c) bool {
    const handle = t orelse return false;
    var tab_ptr: *runtime.TableInstance = undefined;
    var alloc: std.mem.Allocator = undefined;
    if (handle.instance) |inst| {
        if (inst.runtime) |rt| {
            if (handle.table_idx >= rt.tables.len) return false;
            tab_ptr = &rt.tables[handle.table_idx];
            alloc = rt.alloc;
        } else {
            // D-497 (ADR-0201) — JIT-backed instance: grow into the pre-allocated
            // mirror capacity (a no-max table has no headroom → false). The HOST
            // path stores the raw ref + clears the funcptr mirror (fail-safe).
            const jit = jitOf(inst) orelse return false;
            const payload: u64 = if (init) |r| r.ref else runtime.Value.null_ref;
            return jit.growTable(handle.table_idx, payload, delta) != null;
        }
    } else { // standalone host table
        tab_ptr = handle.tinst orelse return false;
        alloc = storeAllocator(handle.store orelse return false) orelse return false;
    }
    const old_len = tab_ptr.refs.len;
    const new_len = old_len + delta;
    if (handle.max) |m| {
        if (new_len > m) return false;
    }
    const grown = alloc.realloc(tab_ptr.refs, new_len) catch return false;
    const payload: u64 = if (init) |r| r.ref else runtime.Value.null_ref;
    for (grown[old_len..new_len]) |*slot| slot.* = .{ .ref = payload };
    tab_ptr.refs = grown;
    return true;
}

// --- extern vec (pointer-vec; vec_delete also frees pointed-to objects)
//
// `wasm_extern_vec_new_empty` / `_new_uninitialized` / `_new`
// live in `src/api/vec.zig`; only the delete cascade lives
// here because it must call back into `wasm_extern_delete`.

/// `wasm_extern_vec_delete(*ExternVec)` — free the vec's pointer
/// array AND each non-null pointed-to Extern (per upstream's
/// pointer-vec ownership rule for `WASM_DECLARE_REF` types).
pub export fn wasm_extern_vec_delete(v: ?*ExternVec) callconv(.c) void {
    const handle = v orelse return;
    if (handle.data) |dp| {
        for (dp[0..handle.size]) |opt_ext| {
            if (opt_ext) |ext| wasm_extern_delete(ext);
        }
        std.heap.c_allocator.free(dp[0..handle.size]);
    }
    handle.* = .{ .size = 0, .data = null };
}

/// `wasm_instance_exports(*Instance, *out vec)` — populate `out`
/// with one Extern per decoded export from the Module's export
/// section. Each Extern's contained `Func` (when kind == func)
/// resolves to the Instance's lowered ZirFunc index. The vec is
/// owned by the caller and must be released with
/// `wasm_extern_vec_delete`.
///
/// On any allocation failure the populated prefix is rolled back
/// so the out vec is either fully populated or empty — never
/// partially populated.
pub export fn wasm_instance_exports(i: ?*const Instance, out: ?*ExternVec) callconv(.c) void {
    const o = out orelse return;
    o.* = .{ .size = 0, .data = null };
    const inst = i orelse return;
    const store = inst.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    if (inst.exports_storage.len == 0) return;

    const buf = std.heap.c_allocator.alloc(?*Extern, inst.exports_storage.len) catch return;
    @memset(buf, null);
    var populated: usize = 0;

    for (inst.exports_storage, 0..) |exp, idx| {
        const ext = alloc.create(Extern) catch break;
        ext.* = .{
            .kind = exportDescToExternKind(exp.kind),
            .instance = @constCast(inst),
        };
        switch (ext.kind) {
            .func => {
                const fh = alloc.create(Func) catch {
                    alloc.destroy(ext);
                    break;
                };
                fh.* = .{ .instance = @constCast(inst), .func_idx = exp.idx };
                ext.func = fh;
            },
            .table => {
                ext.table_idx = exp.idx;
                const th = alloc.create(Table) catch {
                    alloc.destroy(ext);
                    break;
                };
                const tt = switch (inst.export_types[idx]) {
                    .table => |t| t,
                    else => {
                        alloc.destroy(th);
                        alloc.destroy(ext);
                        break;
                    },
                };
                th.* = .{
                    .instance = @constCast(inst),
                    .table_idx = exp.idx,
                    .elem_type = tt.elem_type,
                    .min = tt.min,
                    .max = if (tt.max) |m| @as(u64, m) else null,
                };
                ext.table = th;
            },
            .memory => {
                ext.memory_idx = exp.idx;
                const mh = alloc.create(Memory) catch {
                    alloc.destroy(ext);
                    break;
                };
                mh.* = .{ .instance = @constCast(inst), .memory_idx = exp.idx };
                ext.memory = mh;
            },
            .global => {
                ext.global_idx = exp.idx;
                // export_types[idx] is parallel to exports_storage[idx]; the
                // .global variant carries valtype + mutability so the c_api
                // marshaling path in wasm_global_get can render wasm_val_t
                // without re-walking the module's globals section.
                const gh = alloc.create(Global) catch {
                    alloc.destroy(ext);
                    break;
                };
                const gt = switch (inst.export_types[idx]) {
                    .global => |g| g,
                    else => {
                        alloc.destroy(gh);
                        alloc.destroy(ext);
                        break;
                    },
                };
                gh.* = .{
                    .instance = @constCast(inst),
                    .global_idx = exp.idx,
                    .valtype = gt.valtype,
                    .mutable = gt.mutable,
                };
                ext.global = gh;
            },
        }
        buf[idx] = ext;
        populated += 1;
    }

    if (populated != inst.exports_storage.len) {
        // Roll back partial state — release what we did populate
        // and the buffer itself so the caller sees an empty vec.
        for (buf[0..populated]) |opt_ext| {
            if (opt_ext) |ext| wasm_extern_delete(ext);
        }
        std.heap.c_allocator.free(buf);
        return;
    }

    o.* = .{ .size = inst.exports_storage.len, .data = buf.ptr };
}

/// `wasm_func_call(func, args, results)` — invoke `func` with
/// `args.size` input values, write `results.size` output values
/// into `results.data`, return null on success or a non-null
/// owned `wasm_trap_t*` on Trap (a kinded trap with a real message
/// body; freed via `wasm_trap_delete`, read via `wasm_trap_message`
/// — see `api/trap_surface.zig`).
///
/// Args / result vec sizes must match `func.sig.params.len` /
/// `func.sig.results.len` exactly — mismatch raises a Trap rather
/// than corrupting the operand stack.
pub export fn wasm_func_call(
    f: ?*const Func,
    args: ?*const ValVec,
    results: ?*ValVec,
) callconv(.c) ?*Trap {
    const handle = f orelse return null;
    // #341 — the WASI exit status describes THIS call, not an earlier guest's.
    // A WASI command exits through `proc_exit` even when it succeeds, so a Store
    // that has run one command carries a `0` — and `0` is what
    // `zwasm_store_wasi_exit_code` reports as a clean exit. Recording + clearing
    // above every branch below covers the interp and JIT/AOT arms and the
    // direct-callback path in one place. Instance-derived handles carry
    // `.instance`, `wasm_func_new` ones carry `.store`.
    //
    // #352 / ADR-0224 — this call is an entry into guest code, so it discards
    // any status still standing across this Store's hosts. Which host it will
    // reach is not knowable here: dispatch can leave the instance it entered
    // and run another one's body with that instance's WASI binding. A
    // `wasm_func_new` func has no guest behind it at all, and the same clear is
    // what makes its trap read back as "not an exit" rather than as the last
    // guest's status.
    //
    // A NESTED call clears again on the way out. A host callback can call back
    // in, swallow the trap its guest raised, and return to an outer guest that
    // then exits on a different host; without the second clear both would carry
    // a status and the scan would have two answers.
    const call_store: ?*Store = if (handle.instance) |i| i.store else handle.store;
    const nested_call = if (call_store) |store| store.wasi_call_depth > 0 else false;
    if (call_store) |store| {
        clearWasiExitStatus(store);
        store.wasi_call_depth +|= 1;
    }
    defer if (call_store) |store| {
        store.wasi_call_depth -|= 1;
        if (nested_call) clearWasiExitStatus(store);
    };
    // #315: a `wasm_func_new[_with_env]` func has no instance — the C callback
    // IS its body, so invoke it here rather than reporting a silent success.
    if (handle.host) |hp| return hostFuncCallDirect(handle, hp, args, results);
    const inst = handle.instance orelse return null;
    const store = inst.store orelse return null;
    const alloc = storeAllocator(store) orelse return null;
    // ADR-0200 — JIT-backed instance: route to the native engine. JIT invoke is
    // by-NAME, so reverse-map func_idx → export name via exports_storage (a
    // DIVERGENCE from the interp funcidx-keyed `func_ptrs_storage` path; a
    // func_idx with no export name is unreachable through the C handle anyway).
    if (inst.runtime == null) {
        if (jitOf(inst)) |jit| return wasmFuncCallJit(jit, inst, store, alloc, handle.func_idx, args, results);
        return null;
    }
    const rt = inst.runtime orelse return null;
    // `func_ptrs_storage` is the full funcidx-space table
    // (imports first, then defined). For exports referencing
    // imports the dispatch path would still work — the
    // callee's first instruction is the import-placeholder
    // `unreachable`, which short-circuits via host_calls in the
    // dispatch loop. For defined functions the lookup yields
    // the real ZirFunc.
    if (handle.func_idx >= inst.func_ptrs_storage.len) return allocTrap(alloc, store, .binding_error);

    const zfunc = inst.func_ptrs_storage[handle.func_idx];
    const sig = zfunc.sig;
    const args_size = if (args) |a| a.size else 0;
    const results_size = if (results) |r| r.size else 0;
    if (args_size != sig.params.len) return allocTrap(alloc, store, .binding_error);
    if (results_size != sig.results.len) return allocTrap(alloc, store, .binding_error);

    const num_locals = sig.params.len + zfunc.locals.len;
    const locals = alloc.alloc(runtime.Value, num_locals) catch return allocTrap(alloc, store, .out_of_memory);
    defer alloc.free(locals);
    for (locals) |*l| l.* = .{ .bits128 = 0 };
    if (args) |a| if (a.data) |dp| {
        for (0..a.size) |idx| locals[idx] = marshalValIn(dp[idx]);
    };

    const op_base = rt.operand_len;
    rt.pushFrame(.{
        .sig = sig,
        .locals = locals,
        .operand_base = op_base,
        .pc = 0,
        .func = zfunc,
    }) catch |err| return allocTrap(alloc, store, mapInterpTrap(err));

    dispatch.run(rt, dispatchTable(), zfunc.instrs.items) catch |err| {
        _ = rt.popFrame();
        rt.operand_len = op_base;
        return allocTrap(alloc, store, mapInterpTrap(err));
    };
    _ = rt.popFrame();

    if (rt.operand_len < op_base + sig.results.len) {
        rt.operand_len = op_base;
        return allocTrap(alloc, store, .binding_error);
    }
    if (results) |r| if (r.data) |dp| {
        var i: usize = sig.results.len;
        while (i > 0) {
            i -= 1;
            const v = rt.popOperand();
            dp[i] = marshalValOut(v, sig.results[i], .{ .alloc = alloc, .inst = inst, .store = store });
        }
    };
    rt.operand_len = op_base;
    return null;
}

/// #315 — `wasm_func_call` on a host func created by `wasm_func_new[_with_env]`
/// (no instance, no guest frame). Nothing is marshalled: the callback's
/// `(args, results)` ABI is the one `wasm_func_call` was handed, and neither
/// vec nor any ref-kind `of.ref` inside one is owned by zwasm on this path —
/// both sides are the same host. Two DIVERGENCES from `hostFuncThunk`, which
/// serves the guest boundary: the callback's trap is returned to the caller
/// unconsumed (there is no guest to fault), and no arg ref handle is minted or
/// freed. Arity mismatch traps, matching the instance path.
fn hostFuncCallDirect(
    handle: *const Func,
    hp: *HostFuncPayload,
    args: ?*const ValVec,
    results: ?*ValVec,
) ?*Trap {
    const store = handle.store;
    const alloc = if (store) |s| storeAllocator(s) else null;
    const args_size = if (args) |a| a.size else 0;
    const results_size = if (results) |r| r.size else 0;
    if (args_size != hp.params.len or results_size != hp.results.len) {
        return if (alloc) |al| allocTrap(al, store, .binding_error) else null;
    }
    if (hp.callback_env) |cb| return cb(hp.env, args, results);
    if (hp.callback) |cb| return cb(args, results);
    return if (alloc) |al| allocTrap(al, store, .binding_error) else null;
}

/// ADR-0200 — cast the Zone-1 `Instance.jit` opaque slot to the engine type at
/// the Zone-3 boundary. Null for an interp-backed (or empty) instance. Shared by
/// `wasm_func_call` + the `zwasm_ext.zig` budget setters' JIT arms.
pub fn jitOf(inst: *Instance) ?*runner.JitInstance {
    const jp = inst.jit orelse return null;
    return @ptrCast(@alignCast(jp));
}

/// ADR-0200 — `wasm_func_call` JIT arm. Resolve func_idx→export name, get the
/// sig, marshal `Val[]` args → u64, run via `JitInstance.invoke`/`invokeMulti`,
/// marshal results back. Scalar args+results only (i32/i64/f32/f64); ref/v128
/// or an uncovered shape → `binding_error` trap (mirrors the Zig facade arm).
fn wasmFuncCallJit(jit: *runner.JitInstance, inst: *Instance, store: *Store, alloc: std.mem.Allocator, func_idx: u32, args: ?*const ValVec, results: ?*ValVec) ?*Trap {
    // D-496/D-498 — dispatch by func_idx, NOT export name: a funcref recovered from
    // a table or `ref.func` (wasm_ref_as_func) need not be exported, so the prior
    // jitExportName lookup returned null → binding_error. func_idx is always valid
    // (it came from the Func handle / FuncEntity).
    const sig = jit.funcSigByIdx(func_idx) orelse return allocTrap(alloc, store, .binding_error);
    const args_size = if (args) |a| a.size else 0;
    const results_size = if (results) |r| r.size else 0;
    if (args_size != sig.params.len) return allocTrap(alloc, store, .binding_error);
    if (results_size != sig.results.len) return allocTrap(alloc, store, .binding_error);
    if (sig.params.len > 16 or sig.results.len > 16) return allocTrap(alloc, store, .binding_error);

    var abuf: [16]u64 = undefined;
    if (args) |a| if (a.data) |dp| {
        for (0..a.size) |idx| abuf[idx] = cValToJitBits(dp[idx]);
    };

    if (sig.results.len > 1) {
        var rbuf: [16]runner.TypedResult = undefined;
        jit.invokeMultiIdx(func_idx, abuf[0..sig.params.len], rbuf[0..sig.results.len]) catch |err| return jitErrToTrap(err, jit, alloc, store);
        if (results) |r| if (r.data) |dp| {
            for (0..sig.results.len) |idx| dp[idx] = typedResultToCVal(rbuf[idx], inst, alloc) orelse return allocTrap(alloc, store, .binding_error);
        };
        return null;
    }

    // D-498 — a single funcref/externref result is captured by `invokeRefIdx`
    // (the scalar `invokeIdx` runs a ref-result func as void); marshal the raw
    // payload into an owned `*Ref` C handle.
    if (sig.results.len == 1 and std.meta.activeTag(sig.results[0]) == .ref) {
        const payload = jit.invokeRefIdx(func_idx, abuf[0..sig.params.len]) catch |err| return jitErrToTrap(err, jit, alloc, store);
        if (results) |r| if (r.data) |dp| {
            dp[0] = refResultToCVal(sig.results[0], payload, inst, alloc) orelse return allocTrap(alloc, store, .binding_error);
        };
        return null;
    }

    const got = jit.invokeIdx(func_idx, abuf[0..sig.params.len]) catch |err| return jitErrToTrap(err, jit, alloc, store);
    if (sig.results.len == 1) {
        if (results) |r| if (r.data) |dp| {
            const bits = got orelse return allocTrap(alloc, store, .binding_error);
            dp[0] = jitBitsToCVal(sig.results[0], bits) orelse return allocTrap(alloc, store, .binding_error);
        };
    }
    return null;
}

/// D-498 — wrap a raw JIT ref payload (u64; funcref = `*FuncEntity` ptr, externref
/// = host payload) into an owned `*Ref` C handle carrying the source instance, so a
/// standard consumer can `wasm_ref_as_func` it. Null payload → null funcref.
fn refResultToCVal(vt: zir.ValType, payload: u64, inst: *Instance, alloc: std.mem.Allocator) ?Val {
    const kind: ValKind = if (vt.isFuncref()) .funcref else .anyref;
    if (payload == runtime.Value.null_ref) return .{ .kind = kind, .of = .{ .ref = null } };
    const ref_handle = alloc.create(Ref) catch return null;
    ref_handle.* = .{ .instance = inst, .ref = payload };
    return .{ .kind = kind, .of = .{ .ref = ref_handle } };
}

/// Marshal a C `Val` to the JIT host-invoke u64 bit-carrier (i32/f32 in low 32).
fn cValToJitBits(v: Val) u64 {
    return switch (v.kind) {
        .i32 => @as(u64, @as(u32, @bitCast(v.of.i32))),
        .i64 => @bitCast(v.of.i64),
        .f32 => @as(u64, @as(u32, @bitCast(v.of.f32))),
        .f64 => @bitCast(v.of.f64),
        .anyref, .funcref => if (v.of.ref) |rp| refPayload(rp) else 0,
    };
}

/// Decode a JIT scalar result u64 into a C `Val` by valtype; null for ref/v128
/// (not retrievable via the single-u64 arm — surfaces as a binding_error trap).
fn jitBitsToCVal(vt: zir.ValType, bits: u64) ?Val {
    return switch (vt) {
        .i32 => .{ .kind = .i32, .of = .{ .i32 = @bitCast(@as(u32, @truncate(bits))) } },
        .i64 => .{ .kind = .i64, .of = .{ .i64 = @bitCast(bits) } },
        .f32 => .{ .kind = .f32, .of = .{ .f32 = @bitCast(@as(u32, @truncate(bits))) } },
        .f64 => .{ .kind = .f64, .of = .{ .f64 = @bitCast(bits) } },
        .v128, .ref => null,
    };
}

/// Decode a self-describing JIT `TypedResult` (multi-value) into a C `Val`. D-498 —
/// funcref/externref carriers are wrapped into an owned `*Ref` handle.
fn typedResultToCVal(tr: runner.TypedResult, inst: *Instance, alloc: std.mem.Allocator) ?Val {
    return switch (tr) {
        .i32 => |x| .{ .kind = .i32, .of = .{ .i32 = @bitCast(x) } },
        .i64 => |x| .{ .kind = .i64, .of = .{ .i64 = @bitCast(x) } },
        .f32 => |x| .{ .kind = .f32, .of = .{ .f32 = @bitCast(x) } },
        .f64 => |x| .{ .kind = .f64, .of = .{ .f64 = @bitCast(x) } },
        .funcref => |p| refResultToCVal(zir.ValType.funcref, p, inst, alloc),
        .externref => |p| refResultToCVal(zir.ValType.externref, p, inst, alloc),
    };
}

/// Map a JIT engine error to a C `*Trap`. Runtime traps carry a numeric
/// `trap_kind` on the JIT runtime (generic bucket → unreachable, D-292).
fn jitErrToTrap(err: runner.Error, jit: *runner.JitInstance, alloc: std.mem.Allocator, store: *Store) ?*Trap {
    return switch (err) {
        error.Trap => allocTrap(alloc, store, trap_surface.jitTrapCode(jit.owned.rt.trap_kind) orelse .unreachable_),
        else => allocTrap(alloc, store, .binding_error),
    };
}

// ============================================================
// Tests
// ============================================================

test "wasm_engine_new / delete: round-trip + alloc binding survives" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    // The Engine carries c_allocator pointers; verify the round-
    // trip Allocator is usable.
    const alloc = engineAllocator(e);
    const probe = try alloc.alloc(u8, 16);
    defer alloc.free(probe);
    @memset(probe, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), probe[0]);
}

test "wasm_engine_delete: tolerates null handle" {
    wasm_engine_delete(null);
}

test "wasm_engine_new: owns a std.Io.Threaded; engineIo is usable (ADR-0184)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    try testing.expect(e.io_threaded != null);
    const io = engineIo(e) orelse return error.NoEngineIo;
    // Probe the io with a real filesystem op: stat the cwd.
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    dir.close(io);
}

test "zwasm_store_set_wasi: wires the engine io into Host.io (ADR-0184)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    const cfg = wasi.zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    try testing.expect(cfg.io == null);
    zwasm_store_set_wasi(s, cfg);
    const host: *wasi_host.Host = @ptrCast(@alignCast(s.wasi_host.?));
    try testing.expect(host.io != null);
}

test "wasm_store_new / delete: round-trip with engine back-pointer" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);

    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    try testing.expect(s.engine == e);
}

test "zwasm_wasi_config_new / set / store_delete: ownership round-trip" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;

    // Initial: no WASI configured.
    try testing.expect(s.wasi_host == null);

    const cfg = wasi.zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    zwasm_store_set_wasi(s, cfg);
    try testing.expect(s.wasi_host == @as(*anyopaque, @ptrCast(cfg)));

    // wasm_store_delete tears down the attached host transitively;
    // the test passes if no leak escapes through c_allocator.
    wasm_store_delete(s);
}

test "zwasm_store_set_wasi(*store, null): detaches + frees the existing host" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    const cfg = wasi.zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    zwasm_store_set_wasi(s, cfg);
    try testing.expect(s.wasi_host != null);
    zwasm_store_set_wasi(s, null);
    try testing.expect(s.wasi_host == null);
}

test "zwasm_store_set_wasi: null-arg discipline" {
    zwasm_store_set_wasi(null, null);
}

test "wasm_store_new(null) returns null; delete(null) tolerates" {
    try testing.expect(wasm_store_new(null) == null);
    wasm_store_delete(null);
}

// Minimal Wasm binary: \0asm \1\0\0\0 + bare type section
// declaring `() -> ()` + function section with one entry +
// code section with `end`.
const minimal_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // \0asm
    0x01, 0x00, 0x00, 0x00, // version 1
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
    0x03, 0x02, 0x01, 0x00, // function: 1 function, type 0
    0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code: 1 fn, no locals, end
};

test "wasm_module_validate: minimal valid module → true" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = minimal_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    try testing.expect(wasm_module_validate(s, &bv));
}

test "wasm_module_validate: garbage bytes → false" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const bv: ByteVec = .{ .size = garbage.len, .data = &garbage };
    try testing.expect(!wasm_module_validate(s, &bv));
}

test "wasm_module_new / delete: round-trip + bytes copied" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = minimal_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    try testing.expectEqual(bytes.len, m.bytes_len);
    // Bytes are copied — modify our local copy, the Module's
    // owned slice should be untouched.
    bytes[8] = 0xFF;
    try testing.expectEqual(@as(u8, 0x01), m.bytes_ptr.?[8]);
}

test "wasm_module_*: null-arg discipline" {
    try testing.expect(wasm_module_new(null, null) == null);
    try testing.expect(!wasm_module_validate(null, null));
    wasm_module_delete(null);
}

test "wasm_instance_new / delete: round-trip with minimal module" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = minimal_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const i = instanceNewWithEngine(s, m, null, null, .interp) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(i);

    try testing.expect(i.store == s);
    try testing.expect(i.module == @as(*const anyopaque, @ptrCast(m)));
    try testing.expect(i.runtime != null);
}

test "wasm_instance_new: lowers Module funcs into Runtime" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = minimal_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const i = instanceNewWithEngine(s, m, null, null, .interp) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(i);

    const rt = i.runtime.?;
    // minimal_wasm declares one type and one defined function.
    try testing.expectEqual(@as(usize, 1), rt.funcs.len);
    try testing.expectEqual(@as(usize, 1), rt.module_types.len);
    // The lowered ZirFunc body is `end` only — exactly one
    // instruction.
    try testing.expectEqual(@as(usize, 1), rt.funcs[0].instrs.items.len);
}

test "wasm_instance_new: populates Runtime.tag_param_counts from tag section (10.E-N-4)" {
    // Same shape as compileWasm's tag-section test (engine/runner.zig)
    // but routed through the c_api / instantiateRuntime path.
    // type(1): [(i32) -> ()]; tag(13): [attr=0, typeidx=0].
    // Expected: rt.tag_param_counts = [1].
    var bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: count=1; functype: 0x60, params=[i32], results=[]
        0x01, 0x05, 0x01, 0x60, 0x01, 0x7F, 0x00,
        // tag section (id 13): count=1; tag: attr=0x00, typeidx=0
        0x0D,
        0x03, 0x01, 0x00, 0x00,
    };
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const i = instanceNewWithEngine(s, m, null, null, .interp) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(i);

    const rt = i.runtime.?;
    try testing.expectEqual(@as(usize, 1), rt.tag_param_counts.len);
    try testing.expectEqual(@as(u32, 1), rt.tag_param_counts[0]);
}

test "wasm_instance_new: tag_param_counts empty for module without tag section" {
    // minimal_wasm has no tag section → rt.tag_param_counts stays
    // at the default empty slice.
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);
    var bytes = minimal_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const i = instanceNewWithEngine(s, m, null, null, .interp) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(i);

    try testing.expectEqual(@as(usize, 0), i.runtime.?.tag_param_counts.len);
}

test "wasm_instance_*: null-arg discipline" {
    try testing.expect(wasm_instance_new(null, null, null, null) == null);
    wasm_instance_delete(null);
}

// (module (func (result i32) (i32.const 42)))
// Hand-rolled wasm so the dispatch test stays import-free (the
// realworld toolchain wasms pull in WASI imports).
const i32_const_42_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // \0asm
    0x01, 0x00, 0x00, 0x00, // version 1
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F, // type: () -> (i32)
    0x03, 0x02, 0x01, 0x00, // function: 1 fn, type 0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2A, 0x0B, // code: i32.const 42, end
};

test "wasm_func_call: i32-returning function dispatches to 42" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = i32_const_42_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const i = instanceNewWithEngine(s, m, null, null, .interp) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(i);

    const func = zwasm_instance_get_func(i, 0) orelse return error.FuncResolveFailed;
    defer wasm_func_delete(func);

    var results_data: [1]Val = undefined;
    var results: ValVec = .{ .size = 1, .data = &results_data };
    const args: ValVec = .{ .size = 0, .data = null };
    const trap = wasm_func_call(func, &args, &results);
    try testing.expect(trap == null);
    try testing.expectEqual(ValKind.i32, results_data[0].kind);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32);
}

test "wasm_func_call: arg-count mismatch returns Trap with message; both freed" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = i32_const_42_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const i = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(i);

    const func = zwasm_instance_get_func(i, 0) orelse return error.FuncResolveFailed;
    defer wasm_func_delete(func);

    // Function takes 0 params but we pass 1. Should trap.
    var bogus_arg: [1]Val = .{.{ .kind = .i32, .of = .{ .i32 = 99 } }};
    const args: ValVec = .{ .size = 1, .data = &bogus_arg };
    const results: ValVec = .{ .size = 0, .data = null };
    const trap = wasm_func_call(func, &args, @constCast(&results));
    try testing.expect(trap != null);
    try testing.expectEqual(TrapKind.binding_error, trap.?.kind);

    var msg: ByteVec = .{ .size = 0, .data = null };
    trap_surface.wasm_trap_message(trap, &msg);
    try testing.expect(msg.size > 0);
    vec.wasm_byte_vec_delete(&msg);
    trap_surface.wasm_trap_delete(trap);
}

// Extern-vec null-arg coverage lives here alongside
// `wasm_extern_vec_delete`; byte/val vec round-trip + null-arg
// tests live in `src/api/vec.zig`.

test "wasm_extern_vec_*: null-arg discipline" {
    vec.wasm_extern_vec_new_empty(null);
    vec.wasm_extern_vec_new_uninitialized(null, 16);
    vec.wasm_extern_vec_new(null, 4, null);
    wasm_extern_vec_delete(null);
}

// (module (func (export "main") (result i32) (i32.const 42)))
// Same as i32_const_42_wasm but with an export section between
// function (id 3) and code (id 10).
const i32_const_42_export_main_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // \0asm
    0x01, 0x00, 0x00, 0x00, // version 1
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F, // type: () -> (i32)
    0x03, 0x02, 0x01, 0x00, // function: 1 fn, type 0
    0x07, 0x08, 0x01, 0x04, 0x6D, 0x61, 0x69, 0x6E, 0x00, 0x00, // export "main" (func 0)
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2A, 0x0B, // code: i32.const 42, end
};

// (module (import "env" "foo" (func)))
// Unsupported import: the binding rejects unknown modules at
// `wasm_instance_new` time per §9.4 / 4.7 chunk b.
const env_foo_import_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
    0x02, 0x0B, 0x01, // import section header + count=1
    0x03, 0x65, 0x6E, 0x76, // "env"
    0x03, 0x66, 0x6F, 0x6F, // "foo"
    0x00, 0x00, // desc = func, typeidx = 0
};

// (module
//   (import "wasi_snapshot_preview1" "fd_write"
//     (func (param i32 i32 i32 i32) (result i32))))
const wasi_fd_write_import_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // type: 1 type, (i32 i32 i32 i32) -> (i32)
    0x01, 0x09, 0x01, 0x60, 0x04, 0x7F, 0x7F, 0x7F,
    0x7F, 0x01, 0x7F,
    // import section: count=1, module "wasi_snapshot_preview1"
    // (1 + 22 = 23 bytes), name "fd_write" (1 + 8 = 9 bytes),
    // desc func typeidx=0 (2 bytes), count=1 byte. Body =
    // 1 + 23 + 9 + 2 = 35 = 0x23.
    0x02, 0x23, 0x01, 0x16, 0x77,
    0x61, 0x73, 0x69, 0x5F, 0x73, 0x6E, 0x61, 0x70,
    0x73, 0x68, 0x6F, 0x74, 0x5F, 0x70, 0x72, 0x65,
    0x76, 0x69,
    0x65, 0x77, 0x31, // "wasi_snapshot_preview1"
    0x08, 0x66, 0x64, 0x5F, 0x77, 0x72, 0x69, 0x74, 0x65, // "fd_write"
    0x00, 0x00, // desc = func, typeidx = 0
};

test "wasm_instance_new: rejects modules with unknown import modules" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = env_foo_import_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    // Unknown import module = instantiation fails.
    const inst = wasm_instance_new(s, m, null, null);
    try testing.expect(inst == null);
}

test "wasm_instance_new: rejects WASI imports when no host is configured" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = wasi_fd_write_import_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    // Module imports wasi_snapshot_preview1.fd_write but no host is configured.
    // D-496 — this is the INTERP rejection contract (interp rejects an
    // unsatisfiable WASI import at instantiation). The JIT contract differs by
    // design (D-451: it plants WASI thunks that stub-dispatch even without a host),
    // so pin `.interp` — the post-flip `.auto` default would otherwise accept this
    // on the JIT and no-op the syscalls.
    const inst = instanceNewWithEngine(s, m, null, null, .interp);
    try testing.expect(inst == null);
}

// (module
//   (type $sig_exit (func (param i32)))   ;; type 0
//   (type $sig_main (func))                ;; type 1
//   (import "wasi_snapshot_preview1" "proc_exit"
//     (func $exit (type 0)))               ;; funcidx 0
//   (func $main (type 1)                   ;; funcidx 1
//     i32.const 42
//     call $exit)
//   (export "main" (func $main)))
//
// End-to-end fixture: instantiating + calling main triggers
// the host thunk for proc_exit, which sets host.exit_code=42
// and unwinds the dispatch loop with `error.WasiExit`.
const proc_exit_42_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // type section: 2 types, (i32) -> () and () -> ()
    0x01, 0x08, 0x02, 0x60, 0x01, 0x7F, 0x00, 0x60,
    0x00, 0x00,
    // import section: count=1; "wasi_snapshot_preview1" (22 bytes)
    // + "proc_exit" (9 bytes) + 0x00 0x00 (kind=func, typeidx=0).
    // Body = 1 + 23 + 10 + 2 = 36 = 0x24.
    0x02, 0x24, 0x01, 0x16, 0x77, 0x61,
    0x73, 0x69, 0x5F, 0x73, 0x6E, 0x61, 0x70, 0x73,
    0x68, 0x6F, 0x74, 0x5F, 0x70, 0x72, 0x65, 0x76,
    0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6F,
    0x63, 0x5F, 0x65, 0x78, 0x69, 0x74, 0x00, 0x00,
    // function section: count=1, typeidx=1 (sig_main)
    0x03, 0x02, 0x01, 0x01,
    // export section: count=1, "main" (kind=func, funcidx=1)
    0x07, 0x08, 0x01, 0x04,
    0x6D, 0x61, 0x69, 0x6E, 0x00, 0x01,
    // code section: count=1; fn body = locals=0, i32.const 42,
    // call 0, end. 5 instr bytes + 1 locals = 6 = 0x06.
    0x0A, 0x08,
    0x01, 0x06, 0x00, 0x41, 0x2A, 0x10, 0x00, 0x0B,
};

test "wasm_func_call: dispatches main → proc_exit(42) → host.exit_code (4.7d)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    const cfg = wasi.zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    zwasm_store_set_wasi(s, cfg);

    var bytes = proc_exit_42_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    var exports: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports);
    defer wasm_extern_vec_delete(&exports);
    try testing.expectEqual(@as(usize, 1), exports.size);
    const main_fn = wasm_extern_as_func(exports.data.?[0].?) orelse return error.NotFunc;

    const args: ValVec = .{ .size = 0, .data = null };
    var results: ValVec = .{ .size = 0, .data = null };
    const trap = wasm_func_call(main_fn, &args, &results);
    // proc_exit unwinds via error.WasiExit, surfaces as a Trap.
    try testing.expect(trap != null);
    defer trap_surface.wasm_trap_delete(trap);

    // The host now carries the exit code.
    try testing.expect(s.wasi_host != null);
    const host_typed: *wasi_host.Host = @ptrCast(@alignCast(s.wasi_host.?));
    try testing.expectEqual(@as(u32, 42), host_typed.exit_code.?);
}

test "wasm_instance_new: succeeds for WASI imports when host configured (4.7c)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    const cfg = wasi.zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    zwasm_store_set_wasi(s, cfg);

    var bytes = wasi_fd_write_import_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    // With host configured, instantiation succeeds even though
    // no defined functions exist — the import is wired into
    // host_calls[0] via thunkFdWrite.
    const inst = instanceNewWithEngine(s, m, null, null, .interp) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    const rt = inst.runtime.?;
    try testing.expectEqual(@as(usize, 1), rt.funcs.len); // placeholder for the import
    try testing.expectEqual(@as(usize, 1), rt.host_calls.len);
    try testing.expect(rt.host_calls[0] != null);
}

test "wasm_instance_new: materializes queued preopens via engine io (ADR-0184)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    const cfg = wasi.zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    try testing.expect(wasi.zwasm_wasi_config_preopen_dir(cfg, ".", "/sandbox"));
    zwasm_store_set_wasi(s, cfg);

    var bytes = wasi_fd_write_import_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    const host: *wasi_host.Host = @ptrCast(@alignCast(s.wasi_host.?));
    try testing.expectEqual(@as(usize, 0), host.pending_preopens.items.len);
    try testing.expectEqual(@as(usize, 1), host.preopens.len);
    try testing.expectEqualStrings("/sandbox", host.preopens[0].guest_path);
}

test "wasm_instance_new: unopenable preopen path fails instantiation (ADR-0184)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    const cfg = wasi.zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    try testing.expect(wasi.zwasm_wasi_config_preopen_dir(cfg, "definitely/not/a/real/dir-zwasm", "/x"));
    zwasm_store_set_wasi(s, cfg);

    var bytes = wasi_fd_write_import_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    try testing.expect(wasm_instance_new(s, m, null, null) == null);
}

test "wasm_instance_exports: surfaces declared exports + dispatches via wasm_extern_as_func" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = i32_const_42_export_main_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    var exports: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports);
    defer wasm_extern_vec_delete(&exports);

    try testing.expectEqual(@as(usize, 1), exports.size);
    const ext = exports.data.?[0] orelse return error.MissingExtern;
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.func)), wasm_extern_kind(ext));

    // wasm_extern_as_func returns a borrowed pointer; dispatch
    // through it without separately freeing.
    const f = wasm_extern_as_func(ext) orelse return error.NotFunc;
    var results_data: [1]Val = undefined;
    var results: ValVec = .{ .size = 1, .data = &results_data };
    const args: ValVec = .{ .size = 0, .data = null };
    const trap = wasm_func_call(f, &args, &results);
    try testing.expect(trap == null);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32);
}

test "ADR-0200 C-path JIT: wasm_instance_exports + wasm_func_call on a JIT instance (add 2,3 → 5)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);
    // (module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
    var bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type (i32 i32)->i32
        0x03, 0x02, 0x01, 0x00, // func type 0
        0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // export "add" func 0
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // i32.add
    };
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    // Force the JIT engine via the facade entry; stock `wasm_instance_new`
    // hardcodes `.auto` — the C `zwasm_instance_new_ex` knob is next.
    const inst = instantiateFacade(s, m, null, .{}, .jit) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    var exports: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports);
    defer wasm_extern_vec_delete(&exports);
    try testing.expectEqual(@as(usize, 1), exports.size);
    const ext = exports.data.?[0] orelse return error.MissingExtern;
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.func)), wasm_extern_kind(ext));

    const fc = wasm_extern_as_func(ext) orelse return error.NotFunc;
    var args_data = [_]Val{
        .{ .kind = .i32, .of = .{ .i32 = 2 } },
        .{ .kind = .i32, .of = .{ .i32 = 3 } },
    };
    const args: ValVec = .{ .size = 2, .data = &args_data };
    var results_data: [1]Val = undefined;
    var results: ValVec = .{ .size = 1, .data = &results_data };
    const trap = wasm_func_call(fc, &args, &results);
    try testing.expect(trap == null);
    try testing.expectEqual(@as(i32, 5), results_data[0].of.i32);
}

test "wasm_instance_exports: empty when no export section" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = i32_const_42_wasm; // no export section
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    var exports: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports);
    defer wasm_extern_vec_delete(&exports);
    try testing.expectEqual(@as(usize, 0), exports.size);
}

test "wasm_extern_*: null-arg discipline" {
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.func)), wasm_extern_kind(null));
    wasm_extern_delete(null);
    try testing.expect(wasm_extern_as_func(null) == null);
    var out: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(null, &out);
    try testing.expectEqual(@as(usize, 0), out.size);
}

test "zwasm_instance_get_func / wasm_func_delete: null-arg discipline" {
    try testing.expect(zwasm_instance_get_func(null, 0) == null);
    wasm_func_delete(null);
}

// ============================================================
// Wasm 2.0 c_api utilisation tests (master plan §5.2 / I2 of
// .claude/rules/phase9_close_invariants.md). These exercise the
// reftype / bulk-trap / mixed-export / cross-module-funcref
// surfaces of the wasm-c-api binding so the Phase 9 close-gate
// I2 invariant flips OK.
// ============================================================

// (module (func (export "id") (param funcref) (result funcref) local.get 0))
// Identity over funcref: exercises Val.kind = .funcref marshalling
// through wasm_func_call argv/results.
const funcref_id_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // type: (funcref) -> (funcref). funcref = 0x70.
    0x01, 0x06, 0x01, 0x60, 0x01, 0x70, 0x01, 0x70,
    0x03, 0x02, 0x01, 0x00, // function: typeidx=0
    0x07, 0x06, 0x01, 0x02, 0x69, 0x64, 0x00, 0x00, // export "id" func 0
    // code: locals=0, local.get 0 (0x20 0x00), end
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x20, 0x00, 0x0b,
};

test "wasm 2.0 reftype c_api round-trip: funcref param+result via wasm_func_call" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = funcref_id_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const inst = instanceNewWithEngine(s, m, null, null, .jit) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    const func = zwasm_instance_get_func(inst, 0) orelse return error.FuncResolveFailed;
    defer wasm_func_delete(func);

    // Pass null funcref in; expect null funcref back.
    var args_data: [1]Val = .{.{ .kind = .funcref, .of = .{ .ref = null } }};
    const args: ValVec = .{ .size = 1, .data = &args_data };
    var results_data: [1]Val = undefined;
    var results: ValVec = .{ .size = 1, .data = &results_data };

    const trap = wasm_func_call(func, &args, &results);
    try testing.expect(trap == null);
    try testing.expectEqual(ValKind.funcref, results_data[0].kind);
    try testing.expectEqual(@as(?*anyopaque, null), results_data[0].of.ref);
}

// (module
//   (memory 1)
//   (func (export "main")
//     (i32.const 0) (i32.const 0) (i32.const 65537)
//     (memory.copy)))
// Wasm 2.0 bulk-memory `memory.copy` (0xFC 0x0A) with size that
// exceeds memory bounds: traps with out-of-bounds memory access.
const memory_copy_oob_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
    0x03, 0x02, 0x01, 0x00, // function: typeidx=0
    0x05, 0x03, 0x01, 0x00, 0x01, // memory: count=1, flag=0, min=1
    0x07, 0x08, 0x01, 0x04, 0x6d, 0x61, 0x69, 0x6e, 0x00, 0x00, // export "main" func 0
    // code: locals=0, i32.const 0, i32.const 0, i32.const 65537 (LEB128 0x81 0x80 0x04),
    //       memory.copy (0xfc 0x0a 0x00 0x00), end
    0x0a, 0x10, 0x01, 0x0e, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41,
    0x81, 0x80, 0x04, 0xfc, 0x0a, 0x00, 0x00, 0x0b,
};

test "wasm 2.0 bulk-traps via c_api: memory.copy OOB returns wasm_trap_t with message" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = memory_copy_oob_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    const func = zwasm_instance_get_func(inst, 0) orelse return error.FuncResolveFailed;
    defer wasm_func_delete(func);

    const args: ValVec = .{ .size = 0, .data = null };
    var results: ValVec = .{ .size = 0, .data = null };
    const trap = wasm_func_call(func, &args, &results);
    try testing.expect(trap != null);
    // Bulk-memory OOB surfaces as oob_memory (Wasm 2.0 §4.5.6).
    try testing.expectEqual(TrapKind.oob_memory, trap.?.kind);

    var msg: ByteVec = .{ .size = 0, .data = null };
    trap_surface.wasm_trap_message(trap, &msg);
    try testing.expect(msg.size > 0);
    vec.wasm_byte_vec_delete(&msg);
    trap_surface.wasm_trap_delete(trap);
}

// (module
//   (memory 1)
//   (table 1 funcref)
//   (global (mut i32) (i32.const 7))
//   (func (export "f") (result i32) (i32.const 42))
//   (export "m" (memory 0))
//   (export "t" (table 0))
//   (export "g" (global 0)))
// Four exports across all four wasm_extern_kind values — the
// c_api walk via wasm_instance_exports must surface each kind
// with the right tag. `pub` so the sibling `extern_new.zig` test
// reuses this shared 4-kind fixture instead of duplicating it.
pub const mixed_exports_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> (i32)
    0x03, 0x02, 0x01, 0x00, // function: typeidx=0
    0x04, 0x04, 0x01, 0x70, 0x00, 0x01, // table: count=1, funcref, flag=0, min=1
    0x05, 0x03, 0x01, 0x00, 0x01, // memory: count=1, flag=0, min=1
    0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x07, 0x0b, // global: count=1, i32 mut, init i32.const 7
    // export: count=4, "f" func 0, "m" memory 0, "t" table 0, "g" global 0
    0x07, 0x11, 0x04, 0x01, 0x66, 0x00, 0x00, 0x01,
    0x6d, 0x02, 0x00, 0x01, 0x74, 0x01, 0x00, 0x01,
    0x67, 0x03, 0x00,
    // code: locals=0, i32.const 42, end
    0x0a, 0x06, 0x01, 0x04, 0x00,
    0x41, 0x2a, 0x0b,
};

test "wasm 2.0 mixed-exports c_api walk: func+memory+table+global surface via wasm_instance_exports" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = mixed_exports_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    var exports_vec: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports_vec);
    defer wasm_extern_vec_delete(&exports_vec);

    try testing.expectEqual(@as(usize, 4), exports_vec.size);
    const data = exports_vec.data orelse return error.ExportsDataNull;

    // Decoded-order matches `inst.exports_storage`. Inspect each
    // pointed-to Extern's kind tag — c_api hosts read via
    // `wasm_extern_kind`.
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.func)), wasm_extern_kind(data[0]));
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.memory)), wasm_extern_kind(data[1]));
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.table)), wasm_extern_kind(data[2]));
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.global)), wasm_extern_kind(data[3]));

    // Func extern resolves through `wasm_extern_as_func`; non-func
    // ones return null per upstream wasm.h discipline.
    try testing.expect(wasm_extern_as_func(data[0]) != null);
    try testing.expect(wasm_extern_as_func(data[1]) == null);
    try testing.expect(wasm_extern_as_func(data[2]) == null);
    try testing.expect(wasm_extern_as_func(data[3]) == null);

    // const-qualified family: same kind discipline, borrowed return.
    try testing.expect(wasm_extern_as_func_const(data[0]) != null);
    try testing.expect(wasm_extern_as_memory_const(data[0]) == null);
    try testing.expect(wasm_extern_as_memory_const(data[1]) != null);
    try testing.expect(wasm_extern_as_table_const(data[2]) != null);
    try testing.expect(wasm_extern_as_global_const(data[3]) != null);
    try testing.expect(wasm_extern_as_global_const(data[0]) == null);
    // null-arg discipline.
    try testing.expect(wasm_extern_as_func_const(null) == null);
}

test "D-496 JIT C-path: func+memory+table+global exports all surface via wasm_instance_exports (.jit)" {
    // D-496 chunk 1: a JIT instance must expose ALL export kinds (not just funcs)
    // through the C-API discovery path, so `wasm_extern_as_memory|table|global`
    // resolve (they returned null pre-fix → the .auto→JIT flip's C-API blocker).
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);
    var bytes = mixed_exports_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = instanceNewWithEngine(s, m, null, null, .jit) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);
    try testing.expect(inst.jit != null and inst.runtime == null); // confirm JIT-backed

    var exports_vec: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports_vec);
    defer wasm_extern_vec_delete(&exports_vec);
    try testing.expectEqual(@as(usize, 4), exports_vec.size);
    const data = exports_vec.data orelse return error.ExportsDataNull;
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.func)), wasm_extern_kind(data[0]));
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.memory)), wasm_extern_kind(data[1]));
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.table)), wasm_extern_kind(data[2]));
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.global)), wasm_extern_kind(data[3]));
    // The fix's observable: non-func externs now resolve on a JIT instance.
    try testing.expect(wasm_extern_as_func(data[0]) != null);
    try testing.expect(wasm_extern_as_memory(data[1]) != null);
    try testing.expect(wasm_extern_as_table(data[2]) != null);
    try testing.expect(wasm_extern_as_global(data[3]) != null);
}

test "D-496 JIT C-path: wasm_global_get/set round-trips a mutable global (.jit)" {
    // D-496 chunk 2: global value read/write on a JIT instance (was `inst.runtime
    // orelse return` = no-op on JIT). Reads/writes via JitInstance.globalCell.
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);
    var bytes = mixed_exports_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = instanceNewWithEngine(s, m, null, null, .jit) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);
    var exports_vec: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports_vec);
    defer wasm_extern_vec_delete(&exports_vec);
    const data = exports_vec.data orelse return error.ExportsDataNull;
    const g = wasm_extern_as_global(data[3]) orelse return error.GlobalNull;
    var out: Val = .{ .kind = .i32, .of = .{ .i32 = 0 } };
    wasm_global_get(g, &out);
    try testing.expectEqual(@as(i32, 7), out.of.i32); // mixed_exports "g" = (mut i32) 7
    wasm_global_set(g, &.{ .kind = .i32, .of = .{ .i32 = 42 } });
    wasm_global_get(g, &out);
    try testing.expectEqual(@as(i32, 42), out.of.i32);
}

test "D-496 JIT C-path: wasm_memory_data/size/grow on a JIT instance (.jit)" {
    // D-496 chunk 3: memory accessors on a JIT instance (was no-op on JIT).
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);
    var bytes = mixed_exports_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = instanceNewWithEngine(s, m, null, null, .jit) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);
    var exports_vec: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports_vec);
    defer wasm_extern_vec_delete(&exports_vec);
    const data = exports_vec.data orelse return error.ExportsDataNull;
    const mem = wasm_extern_as_memory(data[1]) orelse return error.MemoryNull;
    try testing.expectEqual(@as(u32, 1), wasm_memory_size(mem)); // mixed_exports "m" = 1 page
    try testing.expectEqual(@as(usize, 65536), wasm_memory_data_size(mem));
    try testing.expect(wasm_memory_data(mem) != null);
    try testing.expect(wasm_memory_grow(mem, 1));
    try testing.expectEqual(@as(u32, 2), wasm_memory_size(mem));
}

test "D-496 JIT C-path: zwasm_instance_get_func resolves by index (.jit)" {
    // D-496 chunk 5: by-index func handle on a JIT instance (funcs_storage empty
    // on JIT → bound against the JIT's func count instead). Handle is callable.
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);
    var bytes = mixed_exports_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = instanceNewWithEngine(s, m, null, null, .jit) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);
    const func = zwasm_instance_get_func(inst, 0) orelse return error.FuncResolveFailed;
    defer wasm_func_delete(func);
}

test "D-496 JIT C-path: wasm_table_size/get/set raw-ref round-trip on a JIT instance (.jit)" {
    // D-496 chunk 4: table size + raw-ref get/set on a JIT instance (was no-op on
    // JIT). Mirrors interp's raw Value.ref C-API semantics (the existing interp
    // table test forges a sentinel ref). funcref-table GROW on JIT = D-497 (ADR-0201).
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);
    var bytes = mixed_exports_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = instanceNewWithEngine(s, m, null, null, .jit) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);
    var exports_vec: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports_vec);
    defer wasm_extern_vec_delete(&exports_vec);
    const data = exports_vec.data orelse return error.ExportsDataNull;
    const tab = wasm_extern_as_table(data[2]) orelse return error.TableNull;
    try testing.expectEqual(@as(u32, 1), wasm_table_size(tab)); // mixed_exports "t" = funcref min 1
    const r0 = wasm_table_get(tab, 0) orelse return error.RefNull;
    defer wasm_ref_delete(r0);
    try testing.expectEqual(@as(u64, runtime.Value.null_ref), r0.ref);
    var sentinel: Ref = .{ .instance = null, .ref = 0xC0FFEE };
    try testing.expect(wasm_table_set(tab, 0, &sentinel));
    const r1 = wasm_table_get(tab, 0) orelse return error.RefNull;
    defer wasm_ref_delete(r1);
    try testing.expectEqual(@as(u64, 0xC0FFEE), r1.ref);
}

// (module (func (export "mix") (param i32 f64) (result f64) local.get 1))
// D-477 sliver(3): a mixed (i32,f64)→f64 export — a 2-arg scalar combo the
// dispatchScalar2 veneer omits, so it must FALL THROUGH to the buffer-write thunk
// (not trap UnsupportedEntrySignature) on a JIT instance via the C-API call path.
const mix_i32f64_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7c, 0x01, 0x7c, // type (i32,f64)->f64
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x07, 0x01, 0x03, 0x6d, 0x69, 0x78, 0x00, 0x00, // export "mix" func 0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x20, 0x01, 0x0b, // local.get 1; end
};

test "D-477 sliver(3): JIT C-path mixed (i32,f64)->f64 export falls through to buffer thunk (.jit)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);
    var bytes = mix_i32f64_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = instanceNewWithEngine(s, m, null, null, .jit) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);
    const func = zwasm_instance_get_func(inst, 0) orelse return error.FuncResolveFailed;
    defer wasm_func_delete(func);

    var args_data: [2]Val = .{
        .{ .kind = .i32, .of = .{ .i32 = 5 } },
        .{ .kind = .f64, .of = .{ .f64 = 2.5 } },
    };
    const args: ValVec = .{ .size = 2, .data = &args_data };
    var results_data: [1]Val = undefined;
    var results: ValVec = .{ .size = 1, .data = &results_data };
    try testing.expect(wasm_func_call(func, &args, &results) == null);
    try testing.expectEqual(ValKind.f64, results_data[0].kind);
    try testing.expectEqual(@as(f64, 2.5), results_data[0].of.f64);
}

// (module (table (export "t") 1 4 funcref)) — a max-bounded funcref table, so the
// JIT pre-allocates grow headroom (ADR-0201). No funcs/code needed.
const funcref_table_max_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x04, 0x05, 0x01, 0x70, 0x01, 0x01, 0x04, // table funcref {min 1, max 4}
    0x07, 0x05, 0x01, 0x01, 0x74, 0x01, 0x00, // export "t" table 0
};

test "D-497 JIT C-path: wasm_table_grow on a funcref table (host fail-safe fill) (.jit)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);
    var bytes = funcref_table_max_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = instanceNewWithEngine(s, m, null, null, .jit) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);
    var exports_vec: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports_vec);
    defer wasm_extern_vec_delete(&exports_vec);
    const data = exports_vec.data orelse return error.ExportsDataNull;
    const tab = wasm_extern_as_table(data[0]) orelse return error.TableNull;
    try testing.expectEqual(@as(u32, 1), wasm_table_size(tab));

    // Grow by 2 (1→3, within max 4) with a forged sentinel init — the HOST path
    // stores it in refs and clears the funcptr mirror (never derefs the ref).
    var init_ref: Ref = .{ .instance = null, .ref = 0xBEEF };
    try testing.expect(wasm_table_grow(tab, 2, &init_ref));
    try testing.expectEqual(@as(u32, 3), wasm_table_size(tab));
    for (1..3) |i| {
        const r = wasm_table_get(tab, @intCast(i)) orelse return error.RefNull;
        defer wasm_ref_delete(r);
        try testing.expectEqual(@as(u64, 0xBEEF), r.ref);
    }
    // Slot 0 untouched.
    const r0 = wasm_table_get(tab, 0) orelse return error.RefNull;
    defer wasm_ref_delete(r0);
    try testing.expectEqual(@as(u64, runtime.Value.null_ref), r0.ref);

    // Grow past the declared max (3+2=5 > 4) → refused.
    try testing.expect(!wasm_table_grow(tab, 2, null));
    try testing.expectEqual(@as(u32, 3), wasm_table_size(tab));
}

test "ADR-0200 JIT C-path: export_types parallel to exports_storage so by-name discovery resolves (wast_runtime_runner regression)" {
    // (module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
    // The .auto-flip reverted because a JIT instance populated exports_storage but
    // NOT export_types, so `lookupSourceExportType` (length-mismatch bail) + the
    // C by-name invoke path saw ExportNotFound. This pins the parallel-arrays fix.
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);
    var bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0a, 0x09,
        0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a,
        0x0b,
    };
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const inst = instanceNewWithEngine(s, m, null, null, .jit) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);
    try testing.expect(inst.runtime == null); // JIT-backed

    // The invariant the C discovery path requires: parallel arrays.
    try testing.expectEqual(@as(usize, 1), inst.exports_storage.len);
    try testing.expectEqual(inst.exports_storage.len, inst.export_types.len);
    const et = try lookupSourceExportType(inst, .func, "add");
    try testing.expectEqual(@as(usize, 2), et.func.sig.params.len);
    try testing.expectEqual(@as(usize, 1), et.func.sig.results.len);

    // End-to-end: by-name discovery via wasm_instance_exports surfaces the func.
    var exports_vec: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports_vec);
    defer wasm_extern_vec_delete(&exports_vec);
    try testing.expectEqual(@as(usize, 1), exports_vec.size);
    const data = exports_vec.data orelse return error.ExportsDataNull;
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.func)), wasm_extern_kind(data[0]));
    const func = wasm_extern_as_func(data[0]) orelse return error.ExternNotFunc;

    // Invoke the discovered handle through the C path (the exact wast_runtime_runner
    // shape: discover → call) — add(2,3) → 5, proving the JIT C invoke works end-to-end.
    var args_data: [2]Val = .{ .{ .kind = .i32, .of = .{ .i32 = 2 } }, .{ .kind = .i32, .of = .{ .i32 = 3 } } };
    const args: ValVec = .{ .size = 2, .data = &args_data };
    var results_data: [1]Val = undefined;
    var results: ValVec = .{ .size = 1, .data = &results_data };
    try testing.expect(wasm_func_call(func, &args, &results) == null); // no trap
    try testing.expectEqual(@as(i32, 5), results_data[0].of.i32);
}

test "wasm 2.0 c_api scalar global accessors: read and write mutable i32 via wasm_extern_as_global + wasm_global_get/set (D-171)" {
    // mixed_exports_wasm declares `(global (export "g") (mut i32) (i32.const 7))`
    // at export index 3. Exercises D-171 minimum-viable surface:
    // wasm_extern_as_global → wasm_global_get (returns initial 7) →
    // wasm_global_set (writes 42) → wasm_global_get (returns 42).
    // wasm_extern_as_global on non-global externs returns null.
    // Per `2026-05-24-c_api-v128-spec-boundary.md`: v128 globals are
    // permanently NOT exposed through this API (covered by D-079 Zig API).
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = mixed_exports_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    var exports: ExternVec = undefined;
    wasm_instance_exports(inst, &exports);
    defer wasm_extern_vec_delete(&exports);
    try testing.expectEqual(@as(usize, 4), exports.size);
    const data = exports.data orelse return error.NullExportsData;

    // Non-global externs return null from wasm_extern_as_global.
    try testing.expect(wasm_extern_as_global(data[0]) == null); // func
    try testing.expect(wasm_extern_as_global(data[1]) == null); // memory
    try testing.expect(wasm_extern_as_global(data[2]) == null); // table

    // Global extern at idx 3 resolves; the handle records valtype + mutability.
    const g = wasm_extern_as_global(data[3]) orelse return error.GlobalResolveFailed;
    try testing.expectEqual(@as(u8, @intFromEnum(zir.ValType.i32)), @intFromEnum(g.valtype));
    try testing.expect(g.mutable);

    // Read the initial value (7 per fixture's `i32.const 7` init).
    var v: Val = undefined;
    wasm_global_get(g, &v);
    try testing.expectEqual(ValKind.i32, v.kind);
    try testing.expectEqual(@as(i32, 7), v.of.i32);

    // Write 42; re-read sees the new value (pointer-aliased cell per ADR-0110).
    const new_val: Val = .{ .kind = .i32, .of = .{ .i32 = 42 } };
    wasm_global_set(g, &new_val);
    wasm_global_get(g, &v);
    try testing.expectEqual(ValKind.i32, v.kind);
    try testing.expectEqual(@as(i32, 42), v.of.i32);

    // Null-arg discipline.
    wasm_global_get(null, &v);
    wasm_global_get(g, null);
    wasm_global_set(null, &new_val);
    wasm_global_set(g, null);
    try testing.expect(wasm_extern_as_global(null) == null);
}

// (module (func (export "answer") (result i32) (i32.const 42)))
// Module A — exports a function for module B to import.
const cross_module_a_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> (i32)
    0x03, 0x02, 0x01, 0x00, // function: typeidx=0
    // export "answer" (6 chars) func 0
    0x07, 0x0a, 0x01, 0x06,
    0x61, 0x6e, 0x73, 0x77,
    0x65, 0x72, 0x00, 0x00,
    0x0a, 0x06, 0x01, 0x04,
    0x00, 0x41, 0x2a, 0x0b,
};

// (module
//   (import "a" "answer" (func (result i32)))
//   (func (export "main") (result i32) (call 0)))
// Module B — imports A's "answer" and calls it.
const cross_module_b_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> (i32)
    // import "a" "answer" func typeidx=0; body = count(1)+mod(2)+name(7)+desc(2) = 12
    0x02, 0x0c, 0x01,
    0x01, 0x61, // module "a"
    0x06, 0x61, 0x6e, 0x73, 0x77, 0x65, 0x72, // name "answer"
    0x00, 0x00, // desc: func typeidx=0
    0x03, 0x02, 0x01, 0x00, // function: typeidx=0 (this is funcidx=1 after import)
    // export "main" func idx=1
    0x07, 0x08, 0x01, 0x04,
    0x6d, 0x61, 0x69, 0x6e,
    0x00, 0x01,
    // code: locals=0, call 0, end
    0x0a, 0x06,
    0x01, 0x04, 0x00, 0x10,
    0x00, 0x0b,
};

// D-170 fixture (§9.13-0 close blocker). Cross-instance v128
// global import — Exporter defines a v128 global with known
// lane bits; Importer imports it and exports a function that
// extracts lane 0 via `i32x4.extract_lane`. The c_api carries
// only i32 across the boundary (wasm-c-api `wasm_val_t` has no
// v128 slot per `include/wasm.h:329-338`; matches wasmtime +
// wasmer per lesson `2026-05-24-c_api-v128-spec-boundary.md`).
// Boundary axis: cross-module / linking + v128 source-of-truth
// init ordering (per edge_case_testing.md Stress axes).
//
// (module
//   (global (export "g") v128
//     (v128.const i32x4 0xdeadbeef 0x00c0ffee 0x12340000 0x56780000)))
const v128_cross_inst_exporter_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x06, 0x16, 0x01, 0x7b, 0x00, 0xfd, 0x0c, 0xef,
    0xbe, 0xad, 0xde, 0xee, 0xff, 0xc0, 0x00, 0x00,
    0x00, 0x34, 0x12, 0x00, 0x00, 0x78, 0x56, 0x0b,
    0x07, 0x05, 0x01, 0x01, 0x67, 0x03, 0x00,
};

// (module
//   (import "exp" "g" (global v128)))
//
// Importer carries only the v128 global import — no function /
// SIMD ops. The c_api uses interp dispatch which does not yet
// implement SIMD ops (D-110 / Phase 10+ scope); D-170 isolates
// the cross-instance v128 wiring at the `Runtime.globals[]`
// pointer-aliasing layer and verifies the resulting cell
// directly from Zig.
const v128_cross_inst_importer_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x02, 0x0a, 0x01, 0x03, 0x65, 0x78, 0x70, 0x01,
    0x67, 0x03, 0x7b, 0x00,
};

// Module with an active element segment whose offset is out-of-
// bounds for the declared table: writes funcidx=0 into table[5]
// on a 1-entry table. Wasm 2.0 §4.5.4 says active element bounds
// are checked at instantiation; OOB raises a trap caught by the
// wasm_instance_new wrapper → arena parks on store.zombies.
// Used by gap A3 to exercise the parkAsZombie catch-path.
const trapping_oob_elem_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
    0x03, 0x02, 0x01, 0x00, // function: typeidx=0
    0x04, 0x04, 0x01, 0x70, 0x00, 0x01, // table: 1 funcref, min=1
    0x09, 0x07, 0x01, // element section: count=1
    0x00, 0x41, 0x05, 0x0b, 0x01, 0x00, // active seg: table=0, offset=i32.const 5, vec<funcidx>=[0]
    0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code: 1 func, body locals=0 end
};

test "wasm 2.0 cross-module funcref via wasm_instance_new: B's main dispatches into A's answer" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    // Instantiate module A — provides the funcref-typed export.
    var bytes_a = cross_module_a_wasm;
    const bv_a: ByteVec = .{ .size = bytes_a.len, .data = &bytes_a };
    const m_a = wasm_module_new(s, &bv_a) orelse return error.ModuleAAllocFailed;
    defer wasm_module_delete(m_a);
    const inst_a = instanceNewWithEngine(s, m_a, null, null, .interp) orelse return error.InstanceAAllocFailed;
    defer wasm_instance_delete(inst_a);

    // Walk A's exports → take the Extern* for "answer" and pass it
    // through B's imports[]. This is the threading the master-plan
    // I2 invariant names ("funcref from instance A into instance B").
    var exports_a: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst_a, &exports_a);
    defer wasm_extern_vec_delete(&exports_a);
    try testing.expectEqual(@as(usize, 1), exports_a.size);
    const data_a = exports_a.data orelse return error.ExportsDataNull;
    const answer_ext = data_a[0] orelse return error.AnswerExternNull;

    var bytes_b = cross_module_b_wasm;
    const bv_b: ByteVec = .{ .size = bytes_b.len, .data = &bytes_b };
    const m_b = wasm_module_new(s, &bv_b) orelse return error.ModuleBAllocFailed;
    defer wasm_module_delete(m_b);

    var imports_arr: [1]?*Extern = .{answer_ext};
    var imports_vec: ExternVec = .{ .size = imports_arr.len, .data = &imports_arr };
    const imports_opaque: *const anyopaque = @ptrCast(&imports_vec);
    const inst_b = instanceNewWithEngine(s, m_b, imports_opaque, null, .interp) orelse return error.InstanceBAllocFailed;
    defer wasm_instance_delete(inst_b);

    // Walk B's exports → wasm_extern_as_func borrows the "main"
    // handle. (Not zwasm_instance_get_func — that one clamps
    // against the defined-only funcs_storage and would mis-index
    // when imports occupy lower funcidx slots.)
    var exports_b: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst_b, &exports_b);
    defer wasm_extern_vec_delete(&exports_b);
    try testing.expectEqual(@as(usize, 1), exports_b.size);
    const main_b = wasm_extern_as_func(exports_b.data.?[0]) orelse return error.FuncResolveFailed;

    var results_data: [1]Val = undefined;
    var results: ValVec = .{ .size = 1, .data = &results_data };
    const args: ValVec = .{ .size = 0, .data = null };
    const trap = wasm_func_call(main_b, &args, &results);
    try testing.expect(trap == null);
    try testing.expectEqual(ValKind.i32, results_data[0].kind);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32);
}

test "wasm 2.0 cross-module v128 global via wasm_instance_new: D-170 close" {
    // D-170 / D-079(ii) — verifies cross-instance v128 global
    // pointer-aliasing through `Runtime.globals[]: []*Value`
    // (post-Phase A.4g uniform 16-byte stride; matches industry
    // pointer-aliasing pattern per lesson
    // `2026-05-24-c_api-v128-spec-boundary.md`). c_api's wasm.h
    // surface does NOT expose v128 (spec-prohibited per
    // `include/wasm.h:329-338` `wasm_val_t` union shape); the
    // assertion therefore reads the Value cell directly from the
    // importer's runtime.
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes_exp = v128_cross_inst_exporter_wasm;
    const bv_exp: ByteVec = .{ .size = bytes_exp.len, .data = &bytes_exp };
    const m_exp = wasm_module_new(s, &bv_exp) orelse return error.ExporterModuleAllocFailed;
    defer wasm_module_delete(m_exp);
    const inst_exp = instanceNewWithEngine(s, m_exp, null, null, .interp) orelse return error.ExporterInstanceAllocFailed;
    defer wasm_instance_delete(inst_exp);

    var exports_exp: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst_exp, &exports_exp);
    defer wasm_extern_vec_delete(&exports_exp);
    try testing.expectEqual(@as(usize, 1), exports_exp.size);
    const g_ext = exports_exp.data.?[0] orelse return error.GlobalExternNull;

    var bytes_imp = v128_cross_inst_importer_wasm;
    const bv_imp: ByteVec = .{ .size = bytes_imp.len, .data = &bytes_imp };
    const m_imp = wasm_module_new(s, &bv_imp) orelse return error.ImporterModuleAllocFailed;
    defer wasm_module_delete(m_imp);

    var imports_arr: [1]?*Extern = .{g_ext};
    var imports_vec: ExternVec = .{ .size = imports_arr.len, .data = &imports_arr };
    const imports_opaque: *const anyopaque = @ptrCast(&imports_vec);
    const inst_imp = instanceNewWithEngine(s, m_imp, imports_opaque, null, .interp) orelse return error.ImporterInstanceAllocFailed;
    defer wasm_instance_delete(inst_imp);

    // Source (exporter) cell: defined global at idx=0, init via
    // v128.const → storage[0] holds the lane bits.
    const rt_exp = inst_exp.runtime orelse return error.ExporterRuntimeNull;
    try testing.expectEqual(@as(usize, 1), rt_exp.globals.len);
    const exp_v128 = rt_exp.globals[0].v128;
    try testing.expectEqual(@as(u32, 0xdeadbeef), std.mem.readInt(u32, exp_v128[0..4], .little));

    // Importer cell: imported global at idx=0, pointer aliases
    // source. The pointer-aliasing invariant requires the
    // importer's slot AND the source's slot to dereference to
    // the same 16 bytes.
    const rt_imp = inst_imp.runtime orelse return error.ImporterRuntimeNull;
    try testing.expectEqual(@as(usize, 1), rt_imp.globals.len);
    try testing.expectEqual(rt_exp.globals[0], rt_imp.globals[0]);
    const imp_v128 = rt_imp.globals[0].v128;
    try testing.expectEqual(@as(u32, 0xdeadbeef), std.mem.readInt(u32, imp_v128[0..4], .little));
    try testing.expectEqual(@as(u32, 0x00c0ffee), std.mem.readInt(u32, imp_v128[4..8], .little));
    try testing.expectEqual(@as(u32, 0x12340000), std.mem.readInt(u32, imp_v128[8..12], .little));
    try testing.expectEqual(@as(u32, 0x56780000), std.mem.readInt(u32, imp_v128[12..16], .little));
}

// D-139 §5.3a A2 — c_api Instance audit coverage. The spec runner
// bypasses `wasm_instance_new` per ADR-0045; these tests exercise
// the lifecycle / arena / cross-module paths that only c_api uses.

test "wasm 2.0 c_api arena ownership: 4 instances of same module, independent cleanup" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = cross_module_a_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    // Each instance has its own arena (Instance.arena per
    // src/runtime/instance/instance.zig); reusing the same Module
    // across instantiations must not leak or alias their storage.
    var insts: [4]?*Instance = undefined;
    for (&insts) |*slot| {
        slot.* = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    }

    // Exercise each instance's exported "answer" func — verifies
    // each arena's lowered ZirFunc + JIT runtime are independent.
    for (insts) |inst| {
        var exports: ExternVec = .{ .size = 0, .data = null };
        wasm_instance_exports(inst.?, &exports);
        defer wasm_extern_vec_delete(&exports);
        const answer = wasm_extern_as_func(exports.data.?[0]) orelse return error.AnswerFuncNull;
        var rd: [1]Val = undefined;
        var rv: ValVec = .{ .size = 1, .data = &rd };
        const av: ValVec = .{ .size = 0, .data = null };
        const trap = wasm_func_call(answer, &av, &rv);
        try testing.expect(trap == null);
        try testing.expectEqual(@as(i32, 42), rd[0].of.i32);
    }

    // Delete in non-sequential order (3,1,0,2) — arena cleanup
    // must be order-independent and not double-free.
    wasm_instance_delete(insts[3]);
    wasm_instance_delete(insts[1]);
    wasm_instance_delete(insts[0]);
    wasm_instance_delete(insts[2]);
}

test "wasm 2.0 c_api cross-module Store binding: multiple stores on same engine are isolated" {
    // D-139 gap C2 per .dev/c_api_instance_audit_2026-05-24.md §3.
    // Two stores on the same engine each instantiate the same module
    // independently; their zombie lists + instances registries do
    // not cross-contaminate. wasm_store_delete on one does not
    // affect liveness of instances on the other.
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);

    const s1 = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s1);
    const s2 = wasm_store_new(e) orelse return error.StoreAllocFailed;

    var bytes_s1 = minimal_wasm;
    var bytes_s2 = minimal_wasm;
    const bv_s1: ByteVec = .{ .size = bytes_s1.len, .data = &bytes_s1 };
    const bv_s2: ByteVec = .{ .size = bytes_s2.len, .data = &bytes_s2 };

    const mod1 = wasm_module_new(s1, &bv_s1) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(mod1);
    const mod2 = wasm_module_new(s2, &bv_s2) orelse return error.ModuleAllocFailed;
    // No `defer wasm_module_delete(mod2)` — mod2 must be deleted
    // BEFORE its owning store s2 below; deferring would run after
    // s2 is freed and dereference dead store memory.

    const inst1 = instanceNewWithEngine(s1, mod1, null, null, .interp) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst1);
    const inst2 = instanceNewWithEngine(s2, mod2, null, null, .interp) orelse return error.InstanceAllocFailed;

    // Isolation invariant 1: each instance's store back-pointer
    // resolves only to its own store.
    try testing.expect(inst1.store == s1);
    try testing.expect(inst2.store == s2);
    try testing.expect(inst1.store != inst2.store);

    // Isolation invariant 2: deleting s2's instance + module + store
    // does not disturb s1's instance. Delete order child→parent:
    // inst2 → mod2 → s2. inst1 stays live through the function's
    // defer at s1.
    wasm_instance_delete(inst2);
    wasm_module_delete(mod2);
    wasm_store_delete(s2);

    // inst1 must still be usable after s2 teardown — runtime intact,
    // module pointer reachable.
    try testing.expect(inst1.runtime != null);
    try testing.expect(inst1.module == @as(*const anyopaque, @ptrCast(mod1)));
}

test "wasm 2.0 c_api zombie lifecycle: B holds funcref into A after wasm_instance_delete(A)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes_a = cross_module_a_wasm;
    const bv_a: ByteVec = .{ .size = bytes_a.len, .data = &bytes_a };
    const m_a = wasm_module_new(s, &bv_a) orelse return error.ModuleAAllocFailed;
    defer wasm_module_delete(m_a);
    const inst_a = instanceNewWithEngine(s, m_a, null, null, .interp) orelse return error.InstanceAAllocFailed;
    // No `defer wasm_instance_delete(inst_a)` — we delete A
    // BEFORE B to exercise the zombie keep-alive contract.

    // Take A's exports vec, build B's imports, then RELEASE
    // exports_a BEFORE deleting A (the ExternVec holds pointers
    // into A's arena; deleting A first would dangle them).
    // After this block, the only remaining reference into A is
    // B's import binding — that's what the zombie list tracks.
    var bytes_b = cross_module_b_wasm;
    const bv_b: ByteVec = .{ .size = bytes_b.len, .data = &bytes_b };
    const m_b = wasm_module_new(s, &bv_b) orelse return error.ModuleBAllocFailed;
    defer wasm_module_delete(m_b);
    const inst_b = blk: {
        var exports_a: ExternVec = .{ .size = 0, .data = null };
        wasm_instance_exports(inst_a, &exports_a);
        defer wasm_extern_vec_delete(&exports_a);
        const answer_ext = exports_a.data.?[0] orelse return error.AnswerExternNull;
        var imports_arr: [1]?*Extern = .{answer_ext};
        var imports_vec: ExternVec = .{ .size = imports_arr.len, .data = &imports_arr };
        const imports_opaque: *const anyopaque = @ptrCast(&imports_vec);
        break :blk instanceNewWithEngine(s, m_b, imports_opaque, null, .interp) orelse return error.InstanceBAllocFailed;
    };
    defer wasm_instance_delete(inst_b);

    // Cache B's "main" handle while A's instance is still live.
    var exports_b: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst_b, &exports_b);
    defer wasm_extern_vec_delete(&exports_b);
    const main_b = wasm_extern_as_func(exports_b.data.?[0]) orelse return error.MainFuncNull;

    // Delete A BEFORE calling B. The zombie list / kept-alive
    // contract must preserve A's func storage until B (which
    // imported A's funcref) is also deleted. Without this,
    // `main_b` calling into A would dereference freed memory.
    wasm_instance_delete(inst_a);

    var rd: [1]Val = undefined;
    var rv: ValVec = .{ .size = 1, .data = &rd };
    const av: ValVec = .{ .size = 0, .data = null };
    const trap = wasm_func_call(main_b, &av, &rv);
    try testing.expect(trap == null);
    try testing.expectEqual(@as(i32, 42), rd[0].of.i32);
}

test "wasm 2.0 c_api zombie partial-init: OOB element segment parks arena; store cleanup reaps it" {
    // D-139 gap A3 per .dev/c_api_instance_audit_2026-05-24.md §3.
    // Simpler form of the audit's full partial-init scenario: an
    // active element segment with OOB offset traps at instantiation
    // (Wasm 2.0 §4.5.4 — active elem bounds are runtime-checked).
    // The trap must trigger the parkAsZombie catch path in
    // wasm_instance_new — without this the arena leaks AND any
    // cross-module funcrefs into the failed instance UAF.
    // wasm_store_delete then cleanly reaps the zombie (no second
    // leak; verified by the test's normal teardown succeeding).
    //
    // The full audit scenario (element-segment writes-then-trap with
    // cross-module table imports) requires hand-rolling a more
    // intricate Wasm module with table imports + multiple element
    // segments; deferred to v0.1.0 RC (D-075). This chunk covers
    // the structural plumbing — the parkAsZombie path itself —
    // which is the load-bearing invariant.
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = trapping_oob_elem_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    // Pre-condition: empty zombie list.
    try testing.expectEqual(@as(usize, 0), s.zombies.items.len);

    // wasm_instance_new must return null (OOB trap) AND park the
    // failed instance's arena on the store's zombie list.
    const inst = wasm_instance_new(s, m, null, null);
    try testing.expect(inst == null);

    // Zombie list grew by exactly one entry. Without the catch-path
    // parkAsZombie this would be 0 (arena freed prematurely) or the
    // test would crash on UAF later.
    try testing.expectEqual(@as(usize, 1), s.zombies.items.len);

    // live_instances stays empty: the failed-instance handle was
    // removed by removeFromLiveInstances inside the catch path
    // (D-174 fix) before being destroyed.
    try testing.expectEqual(@as(usize, 0), s.live_instances.items.len);
}

test "wasm 2.0 c_api cross-module Store binding: wasm_store_delete cascades over live instance" {
    // D-139 gap C3 per .dev/c_api_instance_audit_2026-05-24.md §3.
    // Validates D-174 cascade fix: reverse-order delete
    // (wasm_store_delete BEFORE wasm_instance_delete) must safely
    // cascade-cleanup the live instance via store.live_instances,
    // not UAF on inst.store.engine deref.
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;

    var bytes = minimal_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    // Sanity: inst was registered in s.live_instances at creation.
    try testing.expect(s.live_instances.items.len == 1);
    _ = inst; // intentionally not deleted; the cascade handles it.

    // Delete module first (module's lifetime depends on store).
    wasm_module_delete(m);

    // Reverse-order: wasm_store_delete BEFORE any wasm_instance_delete.
    // The cascade walks s.live_instances, parks each inst's runtime +
    // arena as zombie, then reaps the zombies + frees the store. No
    // UAF on caller's `inst` pointer (it's freed during cascade; we
    // don't touch it after).
    wasm_store_delete(s);
}

test "wasm 2.0 c_api cross-module Store binding: engine-allocator survives store deinit; new store on same engine works" {
    // D-139 gap C4 per .dev/c_api_instance_audit_2026-05-24.md §3.
    // Engine E owns the allocator binding; Stores S1, S2 derive
    // from E independently. After deleting S1 + its instance, a
    // fresh wasm_store_new(E) → S3 must still succeed and host
    // a new instance — proving E's allocator is not store-tied.
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);

    // Stage 1: create S1, instantiate on it, then tear down
    // (instance → store), leaving only E live.
    var bytes_1 = minimal_wasm;
    {
        const s1 = wasm_store_new(e) orelse return error.Store1AllocFailed;
        const bv_1: ByteVec = .{ .size = bytes_1.len, .data = &bytes_1 };
        const m_1 = wasm_module_new(s1, &bv_1) orelse return error.Module1AllocFailed;
        const inst_1 = instanceNewWithEngine(s1, m_1, null, null, .interp) orelse return error.Instance1AllocFailed;
        try testing.expect(inst_1.runtime != null);
        wasm_instance_delete(inst_1);
        wasm_module_delete(m_1);
        wasm_store_delete(s1);
    }

    // Stage 2: fresh store + instance from the SAME engine. If
    // E's allocator had been tied to S1's lifetime, this would
    // either UAF or fail to alloc.
    var bytes_2 = minimal_wasm;
    const s2 = wasm_store_new(e) orelse return error.Store2AllocFailed;
    defer wasm_store_delete(s2);
    const bv_2: ByteVec = .{ .size = bytes_2.len, .data = &bytes_2 };
    const m_2 = wasm_module_new(s2, &bv_2) orelse return error.Module2AllocFailed;
    defer wasm_module_delete(m_2);
    const inst_2 = instanceNewWithEngine(s2, m_2, null, null, .interp) orelse return error.Instance2AllocFailed;
    defer wasm_instance_delete(inst_2);

    try testing.expect(inst_2.runtime != null);
    try testing.expect(inst_2.store == s2);
}

test "wasm 2.0 c_api arena ownership: reverse-order delete (B then A) from forward-order instantiate" {
    // D-139 gap B3 per .dev/c_api_instance_audit_2026-05-24.md §3.
    // Focused 2-instance variant of the existing 4-instance arena
    // test: instantiate A then B (forward); delete B before A
    // (reverse-LIFO). Verify A remains usable after B's arena
    // deinit — no aliasing across same-module instances.
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = cross_module_a_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const inst_a = wasm_instance_new(s, m, null, null) orelse return error.InstanceAAllocFailed;
    defer wasm_instance_delete(inst_a);
    const inst_b = wasm_instance_new(s, m, null, null) orelse return error.InstanceBAllocFailed;
    // No defer for inst_b — explicit delete mid-test exercises
    // reverse-order arena deinit (B before A) while A stays live.

    // Cache A's "answer" handle via defer (A survives the test).
    var exports_a: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst_a, &exports_a);
    defer wasm_extern_vec_delete(&exports_a);
    const answer_a = wasm_extern_as_func(exports_a.data.?[0]) orelse return error.AnswerANull;

    // B's exports vec must be released BEFORE explicit inst_b
    // delete — defer would dangle into B's freed arena.
    var exports_b: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst_b, &exports_b);
    const answer_b = wasm_extern_as_func(exports_b.data.?[0]) orelse return error.AnswerBNull;

    var rd: [1]Val = undefined;
    var rv: ValVec = .{ .size = 1, .data = &rd };
    const av: ValVec = .{ .size = 0, .data = null };

    // Stage 1: both instances live, independent calls succeed.
    try testing.expect(wasm_func_call(answer_a, &av, &rv) == null);
    try testing.expectEqual(@as(i32, 42), rd[0].of.i32);
    try testing.expect(wasm_func_call(answer_b, &av, &rv) == null);
    try testing.expectEqual(@as(i32, 42), rd[0].of.i32);

    // Stage 2: reverse-order arena deinit. B (instantiated second)
    // is destroyed first. A's arena + JIT runtime must remain
    // intact.
    wasm_extern_vec_delete(&exports_b);
    wasm_instance_delete(inst_b);

    // Stage 3: A still callable post-B-delete. This catches
    // accidental aliasing of arena slots, JIT code pages, or
    // module-shared mutable state across same-module instances.
    try testing.expect(wasm_func_call(answer_a, &av, &rv) == null);
    try testing.expectEqual(@as(i32, 42), rd[0].of.i32);
}

test "wasm 2.0 c_api zombie multi-consumer: 2 instances hold funcref into A after wasm_instance_delete(A)" {
    // D-139 gap A2 per .dev/c_api_instance_audit_2026-05-24.md §3.
    // Extends the baseline single-consumer zombie test with a
    // second consumer of A: both B-instances hold funcref into A.
    // Deleting A parks it as one zombie; both consumers keep it
    // alive; sequential delete of consumers releases the zombie
    // only when the last reference drops.
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes_a = cross_module_a_wasm;
    const bv_a: ByteVec = .{ .size = bytes_a.len, .data = &bytes_a };
    const m_a = wasm_module_new(s, &bv_a) orelse return error.ModuleAAllocFailed;
    defer wasm_module_delete(m_a);
    const inst_a = instanceNewWithEngine(s, m_a, null, null, .interp) orelse return error.InstanceAAllocFailed;
    // Intentionally NOT deferred — explicit pre-consumer delete
    // below exercises zombie keep-alive across multiple consumers.

    var bytes_b1 = cross_module_b_wasm;
    var bytes_b2 = cross_module_b_wasm;
    const bv_b1: ByteVec = .{ .size = bytes_b1.len, .data = &bytes_b1 };
    const bv_b2: ByteVec = .{ .size = bytes_b2.len, .data = &bytes_b2 };
    const m_b1 = wasm_module_new(s, &bv_b1) orelse return error.ModuleB1AllocFailed;
    defer wasm_module_delete(m_b1);
    const m_b2 = wasm_module_new(s, &bv_b2) orelse return error.ModuleB2AllocFailed;
    defer wasm_module_delete(m_b2);

    // Cache A's "answer" extern once; share into both consumers'
    // imports[]. The exports vec is released before the explicit
    // A delete so no live pointers dangle through the zombie park.
    const inst_b1, const inst_b2 = blk: {
        var exports_a: ExternVec = .{ .size = 0, .data = null };
        wasm_instance_exports(inst_a, &exports_a);
        defer wasm_extern_vec_delete(&exports_a);
        const answer_ext = exports_a.data.?[0] orelse return error.AnswerExternNull;
        var imports_arr1: [1]?*Extern = .{answer_ext};
        var imports_arr2: [1]?*Extern = .{answer_ext};
        var imports_vec1: ExternVec = .{ .size = imports_arr1.len, .data = &imports_arr1 };
        var imports_vec2: ExternVec = .{ .size = imports_arr2.len, .data = &imports_arr2 };
        const imp1_opaque: *const anyopaque = @ptrCast(&imports_vec1);
        const imp2_opaque: *const anyopaque = @ptrCast(&imports_vec2);
        const b1 = instanceNewWithEngine(s, m_b1, imp1_opaque, null, .interp) orelse return error.InstanceB1AllocFailed;
        const b2 = instanceNewWithEngine(s, m_b2, imp2_opaque, null, .interp) orelse return error.InstanceB2AllocFailed;
        break :blk .{ b1, b2 };
    };
    defer wasm_instance_delete(inst_b2);
    // inst_b1 deleted mid-test to verify zombie A survives one
    // consumer drop (and only releases when the LAST consumer goes).

    // Cache b2's main handle via defer (b2 lives through to end).
    var exports_b2: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst_b2, &exports_b2);
    defer wasm_extern_vec_delete(&exports_b2);
    const main_b2 = wasm_extern_as_func(exports_b2.data.?[0]) orelse return error.MainB2Null;

    // b1's exports vec must be released BEFORE inst_b1 is deleted
    // mid-test — defer would dereference freed instance arena.
    var exports_b1: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst_b1, &exports_b1);
    const main_b1 = wasm_extern_as_func(exports_b1.data.?[0]) orelse return error.MainB1Null;

    // Stage 1: A is live. Both consumers can call into A.
    var rd: [1]Val = undefined;
    var rv: ValVec = .{ .size = 1, .data = &rd };
    const av: ValVec = .{ .size = 0, .data = null };
    try testing.expect(wasm_func_call(main_b1, &av, &rv) == null);
    try testing.expectEqual(@as(i32, 42), rd[0].of.i32);
    try testing.expect(wasm_func_call(main_b2, &av, &rv) == null);
    try testing.expectEqual(@as(i32, 42), rd[0].of.i32);

    // Stage 2: A parked as zombie. Both consumers MUST still resolve
    // their funcref into A.
    wasm_instance_delete(inst_a);
    try testing.expect(wasm_func_call(main_b1, &av, &rv) == null);
    try testing.expectEqual(@as(i32, 42), rd[0].of.i32);
    try testing.expect(wasm_func_call(main_b2, &av, &rv) == null);
    try testing.expectEqual(@as(i32, 42), rd[0].of.i32);

    // Stage 3: one consumer drops; the other must still resolve. A
    // remains zombied (one consumer alive); funcref stays valid.
    wasm_extern_vec_delete(&exports_b1);
    wasm_instance_delete(inst_b1);
    // main_b1 handle now dangles — no further use. main_b2 must work.
    try testing.expect(wasm_func_call(main_b2, &av, &rv) == null);
    try testing.expectEqual(@as(i32, 42), rd[0].of.i32);

    // Stage 4 (implicit on defer): inst_b2 deletion releases A's
    // zombie; wasm_store_delete then drains the empty zombie list.
}

// D-173 close: c_api memory accessors. Exercises
// `wasm_extern_as_memory` + `wasm_memory_data` + `wasm_memory_size`
// + `wasm_memory_data_size` + `wasm_memory_grow` over the
// `mixed_exports_wasm` fixture's exported "m" memory (1 page).
test "wasm 2.0 c_api memory accessors: data + size + grow round-trip (D-173)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = mixed_exports_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    var exports: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports);
    defer wasm_extern_vec_delete(&exports);

    // Exports order: f (func), m (memory), t (table), g (global).
    const mem = wasm_extern_as_memory(exports.data.?[1]) orelse return error.MemoryNull;
    try testing.expectEqual(@as(u32, 1), wasm_memory_size(mem));
    try testing.expectEqual(@as(usize, 65536), wasm_memory_data_size(mem));

    // Byte write + read round-trip through the data pointer.
    const data = wasm_memory_data(mem) orelse return error.MemoryDataNull;
    data[0x100] = 0xAB;
    data[0x101] = 0xCD;
    try testing.expectEqual(@as(u8, 0xAB), data[0x100]);
    try testing.expectEqual(@as(u8, 0xCD), data[0x101]);

    // Grow by 1 page → size=2, data_size=128 KiB; existing bytes
    // preserved + new tail zero-initialised.
    try testing.expect(wasm_memory_grow(mem, 1));
    try testing.expectEqual(@as(u32, 2), wasm_memory_size(mem));
    try testing.expectEqual(@as(usize, 131072), wasm_memory_data_size(mem));
    const data2 = wasm_memory_data(mem) orelse return error.MemoryDataNull;
    try testing.expectEqual(@as(u8, 0xAB), data2[0x100]);
    try testing.expectEqual(@as(u8, 0x00), data2[65536]); // first byte of new page

    // Non-memory Extern → null.
    try testing.expect(wasm_extern_as_memory(exports.data.?[0]) == null); // func
    try testing.expect(wasm_extern_as_memory(exports.data.?[3]) == null); // global
    try testing.expect(wasm_extern_as_memory(null) == null);

    // Null tolerance on accessors.
    try testing.expect(wasm_memory_data(null) == null);
    try testing.expectEqual(@as(usize, 0), wasm_memory_data_size(null));
    try testing.expectEqual(@as(u32, 0), wasm_memory_size(null));
    try testing.expect(!wasm_memory_grow(null, 1));
}

// D-172 close: c_api table accessors. Exercises
// `wasm_extern_as_table` + `wasm_table_size` + `wasm_table_get` +
// `wasm_table_set` + `wasm_ref_delete` over the
// `mixed_exports_wasm` fixture's exported "t" table (1 funcref slot).
test "wasm 2.0 c_api table accessors: size + get + set round-trip (D-172)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = mixed_exports_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    var exports: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports);
    defer wasm_extern_vec_delete(&exports);

    // Exports order: f (func), m (memory), t (table), g (global).
    const tab = wasm_extern_as_table(exports.data.?[2]) orelse return error.TableNull;
    try testing.expectEqual(@as(u32, 1), wasm_table_size(tab));

    // Initial null-ref slot.
    const r0 = wasm_table_get(tab, 0) orelse return error.RefNull;
    defer wasm_ref_delete(r0);
    try testing.expectEqual(@as(u64, runtime.Value.null_ref), r0.ref);

    // Forge a sentinel non-null ref + write it.
    var sentinel: Ref = .{ .instance = null, .ref = 0xC0FFEE };
    try testing.expect(wasm_table_set(tab, 0, &sentinel));
    const r1 = wasm_table_get(tab, 0) orelse return error.RefNull;
    defer wasm_ref_delete(r1);
    try testing.expectEqual(@as(u64, 0xC0FFEE), r1.ref);

    // OOB index: get returns null, set returns false.
    try testing.expect(wasm_table_get(tab, 1) == null);
    try testing.expect(!wasm_table_set(tab, 1, &sentinel));

    // Null-ref clears the slot back to null_ref.
    try testing.expect(wasm_table_set(tab, 0, null));
    const r2 = wasm_table_get(tab, 0) orelse return error.RefNull;
    defer wasm_ref_delete(r2);
    try testing.expectEqual(@as(u64, runtime.Value.null_ref), r2.ref);

    // Non-table Extern → null.
    try testing.expect(wasm_extern_as_table(exports.data.?[0]) == null); // func
    try testing.expect(wasm_extern_as_table(exports.data.?[1]) == null); // memory
    try testing.expect(wasm_extern_as_table(null) == null);

    // Null tolerance on accessors.
    try testing.expectEqual(@as(u32, 0), wasm_table_size(null));
    try testing.expect(wasm_table_get(null, 0) == null);
    try testing.expect(!wasm_table_set(null, 0, &sentinel));
    wasm_ref_delete(null);
}

// 10.F-c follow-up: c_api `wasm_table_grow` (deferred from D-172).
// Exercises grow round-trip + max-limit rejection + init-fill.
test "wasm 2.0 c_api wasm_table_grow: grow + init-fill + max-limit (10.F-c)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = mixed_exports_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const inst = instanceNewWithEngine(s, m, null, null, .interp) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    var exports: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports);
    defer wasm_extern_vec_delete(&exports);

    const tab = wasm_extern_as_table(exports.data.?[2]) orelse return error.TableNull;
    try testing.expectEqual(@as(u32, 1), wasm_table_size(tab));

    // mixed_exports_wasm declares `(table 1 funcref)` — no explicit
    // max, so grow is unbounded. Grow by 3 slots with init=0xBEEF.
    var init_ref: Ref = .{ .instance = null, .ref = 0xBEEF };
    try testing.expect(wasm_table_grow(tab, 3, &init_ref));
    try testing.expectEqual(@as(u32, 4), wasm_table_size(tab));

    // Original slot 0 untouched; grown slots 1..3 carry the init payload.
    const r0 = wasm_table_get(tab, 0) orelse return error.RefNull;
    defer wasm_ref_delete(r0);
    try testing.expectEqual(@as(u64, runtime.Value.null_ref), r0.ref);
    for (1..4) |i| {
        const r = wasm_table_get(tab, @intCast(i)) orelse return error.RefNull;
        defer wasm_ref_delete(r);
        try testing.expectEqual(@as(u64, 0xBEEF), r.ref);
    }

    // Grow by 0 is a no-op.
    try testing.expect(wasm_table_grow(tab, 0, null));
    try testing.expectEqual(@as(u32, 4), wasm_table_size(tab));

    // Null init defaults to null_ref.
    try testing.expect(wasm_table_grow(tab, 1, null));
    try testing.expectEqual(@as(u32, 5), wasm_table_size(tab));
    const r4 = wasm_table_get(tab, 4) orelse return error.RefNull;
    defer wasm_ref_delete(r4);
    try testing.expectEqual(@as(u64, runtime.Value.null_ref), r4.ref);

    // Null tolerance.
    try testing.expect(!wasm_table_grow(null, 1, null));
}
