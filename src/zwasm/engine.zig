//! `Engine` — native Zig facade entry point per ADR-0109 §3.
//!
//! Owns the user-supplied allocator and threads it through every
//! internal allocation (allocator strict-pass invariant per
//! `docs/zig_api_design.md` §4.1). `compile(bytes)` invokes the
//! native parser at `src/parse/parser.zig` directly, bypassing the
//! `wasm-c-api` surface.
//!
//! Transitional shape (J.2 → J.3):
//!   The c_api Engine + Store are still held internally because the
//!   existing `Instance` veneer in `src/zwasm.zig` consumes a c_api
//!   `*Module`; J.3 lifts `Instance` onto the native surface and
//!   removes the c_api fields here.

const std = @import("std");
const Allocator = std.mem.Allocator;

const _api_instance = @import("../api/instance.zig");
const _vec = @import("../api/vec.zig");
const _parser = @import("../parse/parser.zig");
const _hooks = @import("../runtime/hooks.zig");

pub const Module = @import("module.zig").Module;

pub const Engine = struct {
    alloc: Allocator,
    // J.2 transition fields — removed when J.3 replaces Instance.
    c_engine: *_api_instance.Engine,
    c_store: *_api_instance.Store,
    // Tracer slice that satisfies the allocator strict-pass invariant
    // even before `compile` is called. Recording-allocator tests rely
    // on `Engine.init` itself touching `alloc.alloc`.
    _alloc_witness: []u8,

    pub const InitOpts = struct {};

    pub const InitError = error{OutOfMemory};

    pub fn init(alloc: Allocator, _: InitOpts) InitError!Engine {
        const witness = try alloc.alloc(u8, 1);
        errdefer alloc.free(witness);
        witness[0] = 0;

        const e = _api_instance.wasm_engine_new() orelse return error.OutOfMemory;
        errdefer _api_instance.wasm_engine_delete(e);
        const s = _api_instance.wasm_store_new(e) orelse return error.OutOfMemory;

        return .{
            .alloc = alloc,
            .c_engine = e,
            .c_store = s,
            ._alloc_witness = witness,
        };
    }

    /// Release the engine, its backing store, and internal allocations.
    /// Modules + instances derived from it must be deinit'd first (reverse
    /// construction order; the `defer` idiom in the examples does this).
    pub fn deinit(self: *Engine) void {
        _api_instance.wasm_store_delete(self.c_store);
        _api_instance.wasm_engine_delete(self.c_engine);
        self.alloc.free(self._alloc_witness);
    }

    /// `ParseFailed` = structural parse rejected the bytes (bad magic /
    /// section frame / malformed body). `ValidateFailed` = the bytes
    /// parsed but the validation pass (`frontendValidate`) rejected them
    /// (type-stack / subtype / index-bounds). The split discharges D-197
    /// — the previous single `ParseFailed` collapsed both, hiding whether
    /// a spec-corpus `compile FAIL` was a parse gap or a validate gap.
    pub const CompileError = error{ ParseFailed, ValidateFailed } || Allocator.Error;

    /// Wasm spec §5.5 — parse magic / version / section sequence.
    /// Body decoding (types, code, imports) happens lazily; only the
    /// header + section frame is validated here.
    pub fn compile(self: *Engine, bytes: []const u8) CompileError!Module {
        // #216 — this surface parses before handing the bytes to
        // `wasm_module_new`, so a PARSE failure returns before reaching the
        // compile funnel there. Raise the same event here rather than dropping
        // the pre-parse: the alternative, deleting it, would collapse
        // `ParseFailed` and `ValidateFailed` back into one error (D-197). The
        // other two outcomes still come from `wasm_module_new`, so each input
        // produces exactly one event on this surface as on the C one.
        var native = _parser.parse(self.alloc, bytes) catch {
            _hooks.emitCompile(self.c_engine, bytes.len, false);
            return error.ParseFailed;
        };
        errdefer native.deinit(self.alloc);

        // J.2 transition: parallel c_api Module so the existing
        // `Instance` veneer continues to operate. J.3 deletes this
        // pair and routes `instantiate` through native pipeline.
        // The outer parse (above) already succeeded, so a null here is a
        // VALIDATION failure (frontendValidate false), not a parse error.
        var bv: _vec.ByteVec = .{ .size = bytes.len, .data = @constCast(bytes.ptr) };
        const c_mod = _api_instance.wasm_module_new(self.c_store, &bv) orelse return error.ValidateFailed;

        return Module{
            .alloc = self.alloc,
            .c_store = self.c_store,
            .c_handle = c_mod,
            .native = native,
        };
    }

    /// #216 / ADR-0231 — the five observability slots. Thin writers onto the
    /// same `runtime.Engine` fields the C registrations set, so the two
    /// surfaces observe one engine and cannot drift. Types, contract and the
    /// event semantics are in `runtime/hooks.zig` and `include/zwasm.h`:
    /// no re-entry, set before first use, borrowed strings.
    pub fn setCompileHook(self: *Engine, f: ?_hooks.CompileFn, user_data: ?*anyopaque) void {
        self.c_engine.hooks.compile = f;
        self.c_engine.hooks.compile_user_data = user_data;
    }

    pub fn setInstantiateHook(self: *Engine, f: ?_hooks.InstantiateFn, user_data: ?*anyopaque) void {
        self.c_engine.hooks.instantiate = f;
        self.c_engine.hooks.instantiate_user_data = user_data;
    }

    pub fn setTrapHook(self: *Engine, f: ?_hooks.TrapFn, user_data: ?*anyopaque) void {
        self.c_engine.hooks.trap = f;
        self.c_engine.hooks.trap_user_data = user_data;
    }

    pub fn setFuelExhaustedHook(self: *Engine, f: ?_hooks.FuelExhaustedFn, user_data: ?*anyopaque) void {
        self.c_engine.hooks.fuel_exhausted = f;
        self.c_engine.hooks.fuel_exhausted_user_data = user_data;
    }

    pub fn setMemoryGrowthHook(self: *Engine, f: ?_hooks.MemoryGrowthFn, user_data: ?*anyopaque) void {
        self.c_engine.hooks.memory_growth = f;
        self.c_engine.hooks.memory_growth_user_data = user_data;
    }

    /// Convenience factory for a `Linker` bound to this engine —
    /// `eng.linker()` reads cleaner than `Linker.init(&eng)` and matches
    /// the embedding examples in `docs/zig_api_design.md`. The caller owns
    /// the returned `Linker` (call `.deinit()`).
    pub fn linker(self: *Engine) @import("linker.zig").Linker {
        return @import("linker.zig").Linker.init(self);
    }
};

const testing = std.testing;

test "Engine.linker(): factory binds a Linker to this engine" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var lk = eng.linker();
    defer lk.deinit();
    try testing.expectEqual(&eng, lk.engine);
}
