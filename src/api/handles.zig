//! C-API handle struct catalog — the opaque-from-C entity handles
//! (`wasm_func_t` / `wasm_global_t` / `wasm_table_t` / `wasm_memory_t` /
//! `wasm_ref_t` / `wasm_extern_t`) + the value shapes (`wasm_val_t` /
//! `wasm_valkind_t` / `wasm_externkind_t`) + the host-func callback payload.
//!
//! Carved out of `instance.zig` (ADR-0157): instance.zig was at its per-file
//! size cap (3300, ADR-0099) and §16.2 chunk E needs to grow these structs
//! (per-handle `host_info` slot). Pure type definitions — no logic; the
//! accessor / marshal functions stay in instance.zig and reference these via
//! the re-export aliases there (so `instance.Func` etc. keep working for
//! module_introspect / extern_new / wasm.zig).
//!
//! Cycle-safe: every handle→Instance/Store/Func/… reference is a POINTER (no
//! by-value nesting → no struct-layout cycle). `Instance`/`Store` are
//! `runtime.*` aliases, so this file depends one-way on `runtime`; the
//! ValVec/Trap refs (in the host-callback typedef) ride the existing
//! pointer-only `vec`↔`wasm`↔`instance` import cycle Zig 0.16 already resolves.
//!
//! Zone 3 (`src/api/`).

const runtime = @import("../runtime/runtime.zig");
const runtime_instance = @import("../runtime/instance/instance.zig");
const zir = @import("../ir/zir.zig");
const vec = @import("vec.zig");
const trap_surface = @import("trap_surface.zig");

const Instance = runtime_instance.Instance;
const Store = runtime.Store;
const ValVec = vec.ValVec;
const Trap = trap_surface.Trap;

/// `wasm_func_t` — exported / imported function handle. Carries a
/// back-pointer to its owning Instance plus the function's index
/// in `Instance.funcs_storage`. C only ever sees the opaque
/// pointer (per upstream wasm.h), so the struct does not need
/// extern layout.
pub const Func = struct {
    /// host_info (wasm.h `WASM_DECLARE_REF_BASE`): host-attached opaque +
    /// its finalizer, fired in `wasm_func_delete`. Mirrors `Foreign`
    /// (`extern_new.zig`). Accessors are generic in `host_info.zig`.
    host_info: ?*anyopaque = null,
    host_info_finalizer: ?*const fn (?*anyopaque) callconv(.c) void = null,
    instance: ?*Instance,
    func_idx: u32,
    /// Cached borrowed `wasm_extern_t` view (lazily built by
    /// `wasm_func_as_extern`; owned by this Func, freed in
    /// `wasm_func_delete`). The view's `Extern.borrowed` flag makes
    /// `wasm_extern_delete` a no-op so a C host can't double-free —
    /// mirrors the borrow discipline of the reverse `wasm_extern_as_func`.
    extern_view: ?*Extern = null,
    /// Host-created standalone func only (`wasm_func_new[_with_env]`,
    /// `instance == null`): the C callback + arity; the buildBindings
    /// host-func arm wires `hostFuncThunk` so the guest `call` invokes it.
    host: ?*HostFuncPayload = null,
    /// Store handle for the standalone alloc/free path (no instance).
    store: ?*Store = null,
    /// Cached borrowed funcref `wasm_ref_t` view (`wasm_func_as_ref`;
    /// owned by this Func, freed in `wasm_func_delete`). Borrowed-view
    /// discipline like `extern_view`.
    ref_view: ?*Ref = null,
};

/// C callback ABI for `wasm_func_new` / `wasm_func_new_with_env`
/// (`include/wasm.h`): returns null on success or an owned
/// `wasm_trap_t*` on trap (ownership transfers to the runtime).
pub const WasmFuncCallback = *const fn (args: ?*const ValVec, results: ?*ValVec) callconv(.c) ?*Trap;
pub const WasmFuncCallbackEnv = *const fn (env: ?*anyopaque, args: ?*const ValVec, results: ?*ValVec) callconv(.c) ?*Trap;

/// Backing for a host-created func (`wasm_func_new[_with_env]`).
/// `callback` XOR `callback_env` is set. `params`/`results` are owned
/// `zir.ValType` slices (the marshalled arity). #439 — the STORE owns this,
/// not the `Func` handle: see `Store.host_func_payloads`.
pub const HostFuncPayload = struct {
    callback: ?WasmFuncCallback = null,
    callback_env: ?WasmFuncCallbackEnv = null,
    env: ?*anyopaque = null,
    finalizer: ?*const fn (?*anyopaque) callconv(.c) void = null,
    params: []zir.ValType,
    results: []zir.ValType,
};

/// `wasm_global_t` — opaque-from-C handle for a global instance.
/// Carries an instance back-pointer + the global's index in
/// `Runtime.globals[]`. The valtype + mutability are cached at
/// handle-creation time so `wasm_global_get` can marshal the
/// internal `Value` cell into a `wasm_val_t` (tagged C union)
/// without re-walking the module's globals section.
///
/// **Storage lifetime** (per ADR-0110 Phase A.4g): the underlying
/// `*Value` cell lives in the owning Store's arena. A Global
/// handle synthesised against an Instance's export can outlive
/// that Instance as long as another live instance (zombie list)
/// keeps the Store anchored — the c_api cross-instance global
/// mutation surface relies on this pointer-aliased storage shape.
///
/// v128 globals are deliberately NOT exposed through this API
/// per `wasm-c-api include/wasm.h:329-338` (`wasm_val_t` lacks a
/// 128-bit slot) — see `.dev/lessons/2026-05-24-c_api-v128-spec-boundary.md`.
/// Zig-side v128 access goes through the ADR-0109 native API only.
pub const Global = struct {
    /// host_info (see `Func`); fired in `wasm_global_delete`.
    host_info: ?*anyopaque = null,
    host_info_finalizer: ?*const fn (?*anyopaque) callconv(.c) void = null,
    instance: ?*Instance,
    global_idx: u32,
    valtype: zir.ValType,
    mutable: bool,
    /// Cached borrowed extern view (see `Func.extern_view`).
    extern_view: ?*Extern = null,
    /// Cached borrowed `wasm_ref_t` view (`wasm_global_as_ref`, ADR-0158;
    /// payload = `@intFromPtr(self)`; freed in `wasm_global_delete`).
    ref_view: ?*Ref = null,
    /// Host-created standalone global only (`wasm_global_new`,
    /// `instance == null`): the owned `*Value` backing cell. The
    /// get/set accessors read/write this when there is no instance;
    /// it is aliased into an importing instance's `rt.globals[]` (a
    /// `[]*Value`) so guest + host see one cell. Null for an
    /// instance-backed global (its cell lives in `rt.globals_storage`).
    cell: ?*runtime.Value = null,
    /// Store handle for the standalone alloc/free path (no instance to
    /// recover the allocator from). Null for an instance-backed global.
    store: ?*Store = null,
};

/// `wasm_ref_t` — opaque reference handle per `include/wasm.h:327-365`.
/// Carries a single `u64` ref payload (funcref / externref encoding
/// per `runtime.Value.ref` semantics). Allocated by
/// `wasm_table_get` / `wasm_ref_copy`; freed by `wasm_ref_delete`.
/// v0.1 surface: payload only; ref-type kind (funcref vs externref)
/// is implicit from the source Table's `elem_type`.
pub const Ref = struct {
    /// host_info (see `Func`); fired in `wasm_ref_delete`.
    host_info: ?*anyopaque = null,
    host_info_finalizer: ?*const fn (?*anyopaque) callconv(.c) void = null,
    instance: ?*Instance,
    ref: u64,
    /// Cached borrowed `wasm_func_t` view (`wasm_ref_as_func`; owned by
    /// this Ref, freed in `wasm_ref_delete`) — the Func a funcref ref
    /// denotes. Borrowed-view discipline like `Func.ref_view` (reverse).
    func_view: ?*Func = null,
    /// Allocator recovery for an instance-less ref (foreign externref).
    store: ?*Store = null,
};

/// `wasm_table_t` — opaque-from-C handle for a table export.
/// Mirrors `Global`'s shape per `include/wasm.h:466-477`. Wasm 1.0
/// / 2.0 modules carry at most one table per index; multi-table is
/// post-v0.2. Backing storage is the importing instance's
/// `rt.tables[table_idx].refs` — get / set / size accessors read /
/// mutate that slice directly so cross-module imports
/// see writes uniformly per ADR-0014 §6.K.3 arena-aliased semantics.
pub const Table = struct {
    /// host_info (see `Func`); fired in `wasm_table_delete`.
    host_info: ?*anyopaque = null,
    host_info_finalizer: ?*const fn (?*anyopaque) callconv(.c) void = null,
    instance: ?*Instance,
    table_idx: u32 = 0,
    elem_type: zir.ValType,
    // u64 to carry a table64 (i64-indexed) table's limits; the C-API
    // getters (wasm_table_type / wasm_tabletype_limits) saturate to u32.
    min: u64,
    max: ?u64,
    /// Cached borrowed extern view (see `Func.extern_view`).
    extern_view: ?*Extern = null,
    /// Cached borrowed `wasm_ref_t` view (`wasm_table_as_ref`, ADR-0158;
    /// payload = `@intFromPtr(self)`; freed in `wasm_table_delete`).
    ref_view: ?*Ref = null,
    /// Host-created standalone table only (`wasm_table_new`,
    /// `instance == null`): the owned `*TableInstance` backing
    /// (`refs` slice). Accessors use this when there is no instance;
    /// it is value-copied (refs aliased) into an importing instance's
    /// `rt.tables[]` (a `[]TableInstance`) so set/get share the refs
    /// slice. Null for an instance-backed table.
    tinst: ?*runtime.TableInstance = null,
    /// Store handle for the standalone alloc/free path (no instance).
    store: ?*Store = null,
};

/// `wasm_memory_t` — opaque-from-C handle for a memory export.
/// Mirrors `Global`'s shape per `include/wasm.h:471-481`. Wasm 1.0
/// / 2.0 modules carry at most one memory; `memory_idx` is always
/// 0 in v0.1 (multi-memory is post-v0.2 per Phase 14+ scope). The
/// backing storage is the importing instance's `rt.memory` slice —
/// the c_api accessors `wasm_memory_data` / `..._size` / `..._grow`
/// read / mutate that slice directly so cross-module imports
/// (instance B importing instance A's memory) see writes
/// uniformly per ADR-0014 §6.K.3 arena-aliased semantics.
pub const Memory = struct {
    /// host_info (see `Func`); fired in `wasm_memory_delete`.
    host_info: ?*anyopaque = null,
    host_info_finalizer: ?*const fn (?*anyopaque) callconv(.c) void = null,
    instance: ?*Instance,
    memory_idx: u32 = 0,
    /// Cached borrowed extern view (see `Func.extern_view`).
    extern_view: ?*Extern = null,
    /// Cached borrowed `wasm_ref_t` view (`wasm_memory_as_ref`, ADR-0158;
    /// payload = `@intFromPtr(self)`; freed in `wasm_memory_delete`).
    ref_view: ?*Ref = null,
    /// Host-created standalone memory only (`wasm_memory_new`,
    /// `instance == null`): the owned `*MemoryInstance` backing. The
    /// accessors read/grow this when there is no instance; it is shared
    /// (pointer) into an importing instance as `memories[0]` so
    /// `rt.memory` aliases its bytes (D-199). Null for an
    /// instance-backed memory.
    minst: ?*runtime.MemoryInstance = null,
    /// Store handle for the standalone alloc/free path (no instance).
    store: ?*Store = null,
};

/// `wasm_valkind_t` — Wasm valtype tag.
pub const ValKind = enum(u8) {
    i32 = 0,
    i64 = 1,
    f32 = 2,
    f64 = 3,
    anyref = 128,
    funcref = 129,
};

/// `wasm_val_t` — tagged value used at host ↔ Wasm boundary.
/// (`wasm_val_copy` / `wasm_val_delete` live in `vec.zig`.)
pub const Val = extern struct {
    kind: ValKind,
    of: extern union {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
        ref: ?*anyopaque,
    },
};

/// `wasm_externkind_t` — tag identifying which Wasm extern shape
/// an `Extern` carries. Numeric values match upstream wasm.h
/// (`WASM_EXTERN_FUNC` = 0, …) so the binding exports the same
/// integers C hosts read.
pub const ExternKind = enum(u8) {
    func = 0,
    global = 1,
    table = 2,
    memory = 3,
};

/// `wasm_extern_t` — opaque-from-C handle for an exported /
/// imported runtime entity. The func variant carries an owned
/// `Func` handle; table / memory variants carry a pointer back
/// to the source instance plus the export's index in the source
/// module's index space, so the import wiring (§9.6 / 6.E iter
/// 7) can share the underlying TableInstance / memory slice.
/// global is declared but not yet wired through imports.
pub const Extern = struct {
    kind: ExternKind,
    /// host_info (see `Func`); fired in `wasm_extern_delete` for an OWNED
    /// extern (a borrowed `*_as_extern` cache-view never fires it — that
    /// edge folds into the D-269/D-253 ref-model reconcile).
    host_info: ?*anyopaque = null,
    host_info_finalizer: ?*const fn (?*anyopaque) callconv(.c) void = null,
    /// Back-pointer for allocator recovery in `wasm_extern_delete`.
    instance: ?*Instance,
    /// For kind = func: the Func handle owned by this Extern. C
    /// hosts borrow via `wasm_extern_as_func` (no transfer of
    /// ownership) and must NOT call `wasm_func_delete` on the
    /// returned pointer; `wasm_extern_delete` releases it.
    func: ?*Func = null,
    /// For kind = table: index into the source instance's
    /// runtime table list. Only meaningful when `kind == .table`.
    table_idx: u32 = 0,
    /// For kind = memory: index into the source instance's runtime
    /// memory list (the interpreter carries several under multi-memory;
    /// the JIT declines such a module). Only meaningful when
    /// `kind == .memory`.
    memory_idx: u32 = 0,
    /// For kind = global: index into the source instance's
    /// runtime globals list. Only meaningful when `kind == .global`.
    global_idx: u32 = 0,
    /// For kind = global: the Global handle owned by this Extern.
    /// C hosts borrow via `wasm_extern_as_global` (no transfer of
    /// ownership) and must NOT call `wasm_global_delete` on the
    /// returned pointer; `wasm_extern_delete` releases it. Mirrors
    /// `Extern.func` for the func variant.
    global: ?*Global = null,
    /// For kind = memory: the Memory handle owned by this Extern.
    /// Same borrow / ownership discipline as `func` / `global`.
    memory: ?*Memory = null,
    /// For kind = table: the Table handle owned by this Extern.
    /// Same borrow / ownership discipline as `func` / `global` /
    /// `memory`.
    table: ?*Table = null,
    /// True when this Extern is a *borrowed view* produced by
    /// `wasm_{func,global,table,memory}_as_extern` — it is owned by
    /// the source entity (which caches it in `extern_view` and frees
    /// it on the entity's delete), NOT by the C host. `wasm_extern_delete`
    /// is a no-op on a borrowed view so the entity stays the sole owner.
    borrowed: bool = false,
    /// Cached borrowed `wasm_ref_t` view (`wasm_extern_as_ref`, ADR-0158;
    /// payload = `@intFromPtr(self)`; freed in `wasm_extern_delete`).
    ref_view: ?*Ref = null,
};
