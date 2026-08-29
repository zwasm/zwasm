//! WASM Spec §4.2.x / wasm-c-api `wasm_store_t` — module-
//! instantiation context + zombie-instance container.
//!
//! Per ADR-0023 §3 reference table: extracted from
//! `c_api/instance.zig`. The C ABI binding code stays in
//! `api/wasm.zig` (post-ADR-0023 §7 item 11); this file owns
//! only the data shape and the per-Store zombie list type that
//! Wasm 2.0 partial-init semantics require (ADR-0014 §2.1 /
//! 6.K.2 sub-change 4).
//!
//! WASI host wiring is forward-declared via an opaque pointer so
//! `runtime/` does not need to import `wasi/`. The C ABI binding
//! at `api/wasm.zig` casts back to `*wasi.Host` when handing the
//! pointer to `zwasm_store_set_wasi`.
//!
//! Zone 1 (`src/runtime/`).

const std = @import("std");

const engine_mod = @import("engine.zig");
const runtime_mod = @import("runtime.zig");

const Engine = engine_mod.Engine;
const Runtime = runtime_mod.Runtime;

/// `wasm_store_t` — module-instantiation context. Carries a
/// back-pointer to its owning Engine so subsequent C-API entries
/// can recover the allocator without a global. Hosts the
/// per-Store zombie-instance list (ADR-0014 §2.1 / 6.K.2 sub-
/// change 4) so cross-module funcrefs into a failed-or-
/// destroyed instance still dispatch correctly until store
/// teardown.
///
/// Plain (non-`extern`) struct: C only sees `wasm_store_t` as
/// opaque per upstream wasm.h, so the layout is private.
/// Matches the `Instance` shape choice for the same reason.
pub const Store = struct {
    engine: ?*Engine,
    /// Optional WASI host (`zwasm_wasi_config_t` from C's
    /// perspective). Stored as `?*anyopaque` so this file in
    /// Zone 1 (`runtime/`) does not need to import Zone 2
    /// (`wasi/`). The C ABI binding casts back to `*wasi.Host`.
    /// Set via `zwasm_store_set_wasi`; ownership transfers to
    /// the Store. Freed by `wasm_store_delete`, or by the next
    /// `zwasm_store_set_wasi` while no instantiation has captured
    /// it (see `wasi_host_captured`). Null when the store has no
    /// WASI hosting configured.
    wasi_host: ?*anyopaque = null,
    /// Set once an instantiation baked `wasi_host`'s address into
    /// something that outlives the call: the interpreter's per-import
    /// `host_call.ctx`, or the JIT runtime's own `wasi_host`. A
    /// captured host can no longer be freed by the next
    /// `zwasm_store_set_wasi` — it retires onto `retired_wasi_hosts`
    /// instead. Deliberately NOT cleared when an instance is deleted:
    /// the interp bindings are parked with the instance's arena on
    /// `zombies` and stay callable until store teardown. Cleared only
    /// when a different host is installed.
    wasi_host_captured: bool = false,
    /// The WASI host the most recent call into this Store actually
    /// reached — the one the called instance captured at instantiate
    /// time, NOT whatever `wasi_host` now holds. `zwasm_store_set_wasi`
    /// can move `wasi_host` on while an older instance keeps calling
    /// through the host it was built with; this is the field that
    /// addresses the same host the guest wrote. Only ever set to a host
    /// an instantiation captured, which is exactly the condition under
    /// which `zwasm_store_set_wasi` retires rather than frees it — so
    /// the pointer stays valid until `wasm_store_delete`. Null until
    /// the first such instantiation. Erased to `*anyopaque` for the
    /// same Zone-1 reason as `wasi_host`.
    active_wasi_host: ?*anyopaque = null,
    /// Re-entrancy depth of `wasm_func_call` on this Store. Only the
    /// OUTERMOST call decides which host the exit status is read from and
    /// which one is cleared: a host callback that calls back in — a nested
    /// `wasm_func_call`, or a `wasm_instance_new` — must not retarget the
    /// status away from the guest the embedder actually called. Without it a
    /// nested call to a `wasm_func_new` func drops `active_wasi_host` to null
    /// and the outer guest's `proc_exit` becomes unreadable.
    wasi_call_depth: u32 = 0,
    /// Hosts displaced by `zwasm_store_set_wasi` while captured.
    /// `wasm_store_delete` frees each one exactly like `wasi_host`.
    /// Erased to `*anyopaque` for the same Zone-1 reason.
    retired_wasi_hosts: std.ArrayList(*anyopaque) = .empty,
    /// Per-Store zombie-instance list (ADR-0014 §2.1 / 6.K.2
    /// sub-change 4). When `instantiateRuntime` traps mid-
    /// element-segment processing, prior writes into a foreign
    /// instance's table cells already hold `*FuncEntity`
    /// pointers into the failing instance's arena. Per Wasm 2.0
    /// partial-init semantics those writes must persist; the
    /// failing instance's runtime + arena therefore park here
    /// instead of being destroyed by the catch path.
    /// `wasm_instance_delete` on a successfully-instantiated
    /// handle also parks (so cross-module funcrefs stay valid
    /// through the importer's lifetime). Walked + freed by
    /// `wasm_store_delete`.
    zombies: std.ArrayList(Zombie) = .empty,
    /// Wasm 1.0 §4.5 cross-module instance registry per ADR-0065
    /// (Phase 9 Cat III §9.9-III scope). Spec testsuite uses
    /// `(register "M" $inst)` to bind a previously-instantiated
    /// module under a host-import alias; subsequent modules can
    /// `(import "M" "f" ...)` to call into the registered
    /// instance's exports. Stored as `*anyopaque` (a `*Instance`
    /// erased) to avoid the `store.zig` ↔ `instance/instance.zig`
    /// circular import — callers in Zone 2/3 cast back to
    /// `*Instance`. Key bytes are caller-owned (typically the
    /// runner harness's session arena for spec_assert); Store does
    /// NOT copy them. Walked + freed (the hashmap itself) by
    /// `wasm_store_delete`.
    instances: std.StringHashMapUnmanaged(*anyopaque) = .empty,
    /// Per-Store live c_api Instance back-registry (D-174 defensive
    /// fix). Distinct from `instances` (host-import alias registry)
    /// and `zombies` (already-deinited instances kept for cross-
    /// module funcref survival). Every successful `wasm_instance_new`
    /// appends its handle; `wasm_instance_delete` swap-removes.
    /// `wasm_store_delete` walks this list to cascade-cleanup any
    /// instance still alive at store-teardown time — without this,
    /// reverse-order delete (`wasm_store_delete(s)` before
    /// `wasm_instance_delete(inst)`) UAFs on the freed Store via
    /// `inst.store.engine` deref. Stored as `*anyopaque` to avoid the
    /// `store.zig` ↔ `api/instance.zig` circular import. See
    /// `.dev/c_api_instance_audit_2026-05-24.md` §3 C3.
    live_instances: std.ArrayList(*anyopaque) = .empty,

    /// Register an instance under a host-import alias. The `name`
    /// bytes are caller-owned (NOT copied). Errors only on OOM in
    /// the underlying hashmap. Idempotent: re-registering the same
    /// name overwrites the previous binding (matches the wast
    /// `(register "M" $inst)` re-bind semantics).
    pub fn register(
        store: *Store,
        alloc: std.mem.Allocator,
        name: []const u8,
        instance_opaque: *anyopaque,
    ) std.mem.Allocator.Error!void {
        try store.instances.put(alloc, name, instance_opaque);
    }

    /// Look up a registered instance by alias. Returns null when
    /// the alias is unknown.
    pub fn lookup(store: *const Store, name: []const u8) ?*anyopaque {
        return store.instances.get(name);
    }
};

/// One parked instance. Keeps the runtime + arena alive until
/// `wasm_store_delete` walks the list. Per ADR-0014 §2.1 /
/// 6.K.2 sub-change 4.
pub const Zombie = struct {
    runtime: *Runtime,
    arena: *std.heap.ArenaAllocator,
};

const testing = std.testing;

test "Store.register / lookup round-trip" {
    var store: Store = .{ .engine = null };
    defer store.instances.deinit(testing.allocator);

    var dummy_a: u8 = 0;
    var dummy_b: u8 = 0;
    try store.register(testing.allocator, "M1", &dummy_a);
    try store.register(testing.allocator, "M2", &dummy_b);

    try testing.expectEqual(@as(?*anyopaque, &dummy_a), store.lookup("M1"));
    try testing.expectEqual(@as(?*anyopaque, &dummy_b), store.lookup("M2"));
    try testing.expectEqual(@as(?*anyopaque, null), store.lookup("M3"));
}

test "Store.register rebind overwrites" {
    var store: Store = .{ .engine = null };
    defer store.instances.deinit(testing.allocator);

    var v1: u8 = 0;
    var v2: u8 = 0;
    try store.register(testing.allocator, "alias", &v1);
    try store.register(testing.allocator, "alias", &v2);
    try testing.expectEqual(@as(?*anyopaque, &v2), store.lookup("alias"));
}
