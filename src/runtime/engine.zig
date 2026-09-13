//! WASM Spec §4.2.x / wasm-c-api `wasm_engine_t` — top-level
//! configuration handle that owns the allocator vtable injected
//! by the C host.
//!
//! Per ADR-0023 §3 reference table: extracted from
//! `c_api/instance.zig`. The C ABI binding code (`wasm_engine_new`
//! / `_delete`) stays in `api/wasm.zig` (post-ADR-0023 §7 item 11);
//! this file owns only the data shape.
//!
//! Zone 1 (`src/runtime/`).

/// `wasm_engine_t` — top-level configuration handle. Carries the
/// allocator that backs every Store / Module / Instance that
/// derive from it (so the C host can recover its allocator from
/// any future `wasm_store_t` GC roots). The §9.3 / 3.3 binding uses
/// `std.heap.c_allocator` so C hosts get malloc-equivalent
/// lifetime; a future `zwasm.h` extension will let the host
/// inject its own.
pub const Engine = extern struct {
    /// Type-erased allocator pointer + vtable. Stored as two
    /// `*anyopaque` so the layout is C-stable — Zig's
    /// `std.mem.Allocator` is `extern struct { ptr: *anyopaque,
    /// vtable: *const VTable }` so a memcpy / pointer cast
    /// round-trips.
    alloc_ptr: ?*anyopaque,
    alloc_vtable: ?*const anyopaque,
    /// Engine-owned `std.Io.Threaded` (ADR-0184). The C-ABI
    /// boundary cannot receive a Zig io token, so the engine
    /// manufactures one; WASI preopens / env inheritance flow
    /// through it. Heap-allocated by `wasm_engine_new`, deinited
    /// at `wasm_engine_delete`. Type-erased for the same
    /// C-stable-layout reason as the allocator pair; the §9.3
    /// binding casts to `*std.Io.Threaded`.
    io_threaded: ?*anyopaque = null,
    /// #216 / ADR-0231 — the embedder's five observability slots, set through
    /// `zwasm_engine_set_*_hook` (C) or `Engine.set*Hook` (Zig). Every raising
    /// site reaches them from here, which is why the counter below lives here
    /// too rather than on the Store.
    hooks: hooks_mod.Hooks = .{},
    /// #216 — source of the `u64` instance ids the hooks report. Monotonic and
    /// never reused, so an id identifies one instantiation for the engine's
    /// whole life, unlike a pointer a later instance can be handed again.
    /// Plain integer: a Store is single-threaded by design, and an Engine is
    /// used from one thread (`include/zwasm.h`, "Threads").
    next_instance_id: u64 = 0,
};

const hooks_mod = @import("hooks.zig");
