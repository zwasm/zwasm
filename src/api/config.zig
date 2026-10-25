//! `wasm_config_t` surface of the C ABI binding (wasm.h:127,137).
//!
//! zwasm's engine is single-tier with NO spec-standard tunables: the standard
//! wasm.h declares no config setters; strategy / opt-level / fuel / epoch are
//! runtime-specific extensions we deliberately do not owe (ADR-0156
//! lightweight-yet-fast bar). So `wasm_config_t` is an opaque, currently-empty
//! object that exists only so `wasm_engine_new_with_config` is callable.
//!
//! Lives in its own file (not instance.zig, which owns the Engine) because
//! instance.zig is at its per-file size cap (ADR-0099). Zone 3 (`src/api/`);
//! re-exported via `api/wasm.zig`. One-way dependency on `instance` (Engine +
//! `wasm_engine_new`).

const std = @import("std");

const instance = @import("instance.zig");
const Engine = instance.Engine;

/// `wasm_config_t` — opaque engine config. `reserved` keeps the allocation
/// non-zero-sized + a home for any future option (none today).
pub const Config = struct {
    reserved: u8 = 0,
};

pub export fn wasm_config_new() callconv(.c) ?*Config {
    const c = std.heap.c_allocator.create(Config) catch return null;
    c.* = .{};
    return c;
}

pub export fn wasm_config_delete(c: ?*Config) callconv(.c) void {
    const handle = c orelse return;
    std.heap.c_allocator.destroy(handle);
}

/// `wasm_engine_new_with_config(own wasm_config_t*)` — consumes (takes
/// ownership of, and frees) the config, then returns a new engine. zwasm
/// honours no config knobs, so this is `wasm_engine_new` after adopting the
/// config per the `own` transfer contract. Null config is tolerated.
pub export fn wasm_engine_new_with_config(c: ?*Config) callconv(.c) ?*Engine {
    if (c) |handle| std.heap.c_allocator.destroy(handle);
    return instance.wasm_engine_new();
}

test "wasm_config + engine_new_with_config: config lifecycle + config-consumed engine" {
    // engine_new_with_config consumes (frees) the config and yields a usable engine.
    const cfg = wasm_config_new() orelse return error.ConfigAllocFailed;
    const e = wasm_engine_new_with_config(cfg) orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    instance.wasm_store_delete(s);

    // standalone config new/delete + null discipline.
    const cfg2 = wasm_config_new() orelse return error.ConfigAllocFailed;
    wasm_config_delete(cfg2);
    wasm_config_delete(null);
    const e2 = wasm_engine_new_with_config(null) orelse return error.EngineAllocFailed;
    instance.wasm_engine_delete(e2);
}
