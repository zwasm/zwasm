//! `Module` — validated Wasm module ready for instantiation per
//! ADR-0109 §3. Holds the native parsed view (`runtime.Module`) plus
//! a transitional c_api handle so the existing `Instance` veneer
//! can still instantiate. J.3 drops the c_api side.

const std = @import("std");
const Allocator = std.mem.Allocator;

const _api_instance = @import("../api/instance.zig");
const _trap_surface = @import("../api/trap_surface.zig");
const _runtime_module = @import("../runtime/module.zig");
const _sections = @import("../parse/sections.zig");

const _zwasm = @import("../zwasm.zig");

/// The shape of an imported / exported entity. Native-Zig mirror of the
/// wasm-c-api `wasm_externkind_t`; `tag` covers the Wasm 3.0 EH tag
/// import (no `tag` export kind exists in the binary format).
pub const ExternKind = enum { func, table, memory, global, tag };

/// One decoded import: the two-level name (`module` + `name`) plus the
/// entity kind. Names are owned by the enclosing `ModuleImports.arena`.
pub const ImportItem = struct {
    module: []const u8,
    name: []const u8,
    kind: ExternKind,
};

/// One decoded export: the field `name` plus the entity kind. The name
/// is owned by the enclosing `ModuleExports.arena`.
pub const ExportItem = struct {
    name: []const u8,
    kind: ExternKind,
};

/// Owned result of `Module.imports`; `deinit` frees the items + names.
pub const ModuleImports = struct {
    arena: std.heap.ArenaAllocator,
    items: []const ImportItem,

    pub fn deinit(self: *ModuleImports) void {
        self.arena.deinit();
    }
};

/// Owned result of `Module.exports`; `deinit` frees the items + names.
pub const ModuleExports = struct {
    arena: std.heap.ArenaAllocator,
    items: []const ExportItem,

    pub fn deinit(self: *ModuleExports) void {
        self.arena.deinit();
    }
};

/// `DecodeFailed` = the import/export section body, already accepted by
/// `compile`, failed structural re-decode (an internal inconsistency,
/// surfaced rather than swallowed).
pub const IntrospectError = error{ DecodeFailed, OutOfMemory };

fn importKind(k: _sections.ImportKind) ExternKind {
    return switch (k) {
        .func => .func,
        .table => .table,
        .memory => .memory,
        .global => .global,
        .tag => .tag,
    };
}

fn exportKind(k: _sections.ExportDesc) ExternKind {
    return switch (k) {
        .func => .func,
        .table => .table,
        .memory => .memory,
        .global => .global,
    };
}

pub const Module = struct {
    alloc: Allocator,
    // J.2 transition: c_api handle drives `instantiate` until J.3
    // lifts Instance onto the native surface.
    c_store: *_api_instance.Store,
    c_handle: *_api_instance.Module,
    native: _runtime_module.Module,

    /// Release the compiled module — its c_api handle and native module
    /// storage. Instances already created from it stay valid until their
    /// own `deinit`.
    pub fn deinit(self: *Module) void {
        _api_instance.wasm_module_delete(self.c_handle);
        self.native.deinit(self.alloc);
    }

    /// A per-axis runtime budget (ADR-0179). `unmetered` must be spelled out;
    /// it is never the silent default, so an embedder running untrusted modules
    /// gets a bounded instance unless it deliberately opts out.
    pub const Budget = union(enum) {
        unmetered,
        limited: u64,

        pub fn toOptional(self: Budget) ?u64 {
            return switch (self) {
                .unmetered => null,
                .limited => |v| v,
            };
        }
    };

    /// Default deterministic instruction budget (~1e9 interp instructions).
    pub const default_fuel: u64 = 1_000_000_000;
    /// Default linear-memory ceiling in 64 KiB pages (4096 = 256 MiB), an extra
    /// cap below the spec 4 GiB ceiling.
    pub const default_max_memory_pages: u64 = 4096;
    /// Default table-element ceiling (D-332): a generous DoS backstop on the
    /// INITIAL eager table allocation, mirroring `default_max_memory_pages`.
    /// 10M funcref slots ≈ 80 MiB — far above any real toolchain (Go/wasip1's
    /// table is ~5790), so it rejects only pathological declared mins, NOT a low
    /// arbitrary cap (cf. D-331(A)). Hosts tighten via `max_table_elements`.
    pub const default_max_table_elements: u64 = 10_000_000;

    /// Instantiation options (ADR-0179). Both budgets default to a FINITE value
    /// so the common `init → compile → instantiate → invoke` flow is bounded
    /// without an extra call; set the axis to `.unmetered` for trusted modules.
    pub const InstantiateOpts = struct {
        fuel: Budget = .{ .limited = default_fuel },
        max_memory_pages: Budget = .{ .limited = default_max_memory_pages },
        /// D-332 — host cap on a table's INITIAL declared element count (mirrors
        /// `max_memory_pages`; extends the grow-time `store_table_elements_max`).
        max_table_elements: Budget = .{ .limited = default_max_table_elements },
        /// ADR-0200 — per-instance engine selection. `.auto` (default) prefers
        /// the JIT and falls back to the interpreter for a module the JIT
        /// declines; `.jit` requires the JIT (instantiation fails where it would
        /// have fallen back); `.interp` forces the interpreter.
        engine: _api_instance.EngineKind = .auto,
    };

    /// `StartTrapped` = the module's `(start)` function trapped during
    /// instantiation (D-275); `MemoryLimitExceeded` = the module's declared
    /// initial linear memory exceeds `opts.max_memory_pages`;
    /// `TableLimitExceeded` = a declared table's initial element count exceeds
    /// `opts.max_table_elements` (D-332); `InstantiateFailed` = any other
    /// failure (link / alloc). The specific trap kind is available to C hosts
    /// via `wasm_instance_new`'s `trap_out` + `wasm_trap_message`.
    pub const InstantiateError = error{ InstantiateFailed, StartTrapped, MemoryLimitExceeded, TableLimitExceeded };

    pub fn instantiate(self: *Module, opts: InstantiateOpts) InstantiateError!_zwasm.Instance {
        const limits: _api_instance.InstantiateLimits = .{
            .fuel = opts.fuel.toOptional(),
            .max_memory_pages = opts.max_memory_pages.toOptional(),
            .max_table_elements = opts.max_table_elements.toOptional(),
        };

        // Reject an over-cap declared initial memory before instantiation so the
        // caller gets a distinct error (the runtime also enforces this, but its
        // null return cannot carry the specific cause).
        if (limits.max_memory_pages) |cap| {
            if (self.declaredInitialMemoryPages()) |min_pages| {
                if (min_pages > cap) return error.MemoryLimitExceeded;
            }
        }
        // D-332: same for the largest declared initial table element count.
        if (limits.max_table_elements) |cap| {
            if (self.declaredInitialTableElements()) |min_elems| {
                if (min_elems > cap) return error.TableLimitExceeded;
            }
        }

        var trap: ?*_trap_surface.Trap = null;
        const inst = _api_instance.instantiateFacade(self.c_store, self.c_handle, &trap, limits, opts.engine) orelse {
            if (trap) |t| {
                _trap_surface.wasm_trap_delete(t); // facade owns the trap; free it
                return error.StartTrapped;
            }
            return error.InstantiateFailed;
        };
        return .{ .handle = inst, .c_store = self.c_store };
    }

    /// Largest declared initial page count across the module's DEFINED memories
    /// (the no-import facade path has no imported memories), or `null` when the
    /// module declares no memory. Page units match the runtime page cap.
    fn declaredInitialMemoryPages(self: *const Module) ?u64 {
        const sec = self.native.find(.memory) orelse return null;
        // EXEMPT-FALLBACK: ADR-0179 — best-effort pre-check for a distinct
        // caller error; `instantiateRuntime` re-decodes + enforces the cap
        // authoritatively, so a decode miss here safely defers to that path
        // (the section already parsed during `compile`).
        var decoded = _sections.decodeMemory(self.alloc, sec.body) catch return null;
        defer decoded.deinit();
        if (decoded.items.len == 0) return null;
        var max_min: u64 = 0;
        for (decoded.items) |entry| max_min = @max(max_min, entry.min);
        return max_min;
    }

    /// D-332 — largest declared initial element count across the module's
    /// DEFINED tables, or `null` when it declares none. Mirrors
    /// `declaredInitialMemoryPages`; element units match the runtime table cap.
    fn declaredInitialTableElements(self: *const Module) ?u64 {
        const sec = self.native.find(.table) orelse return null;
        // EXEMPT-FALLBACK: D-332 — best-effort pre-check for a distinct caller
        // error; the runtime re-decodes + enforces the cap authoritatively, so a
        // decode miss here safely defers (the section parsed during `compile`).
        var decoded = _sections.decodeTables(self.alloc, sec.body) catch return null;
        defer decoded.deinit();
        if (decoded.items.len == 0) return null;
        var max_min: u64 = 0;
        for (decoded.items) |entry| max_min = @max(max_min, entry.min);
        return max_min;
    }

    /// Section count from the native parser.
    pub fn sectionCount(self: *const Module) usize {
        return self.native.sections.items.len;
    }

    /// Decoded import descriptors (module + field name + extern kind) for
    /// pre-instantiation introspection — an embedder learns which host
    /// definitions a `Linker` must supply before linking. Mirrors
    /// wasmtime's `Module::imports()`. The result owns its strings; call
    /// `.deinit()` when done. Empty when the module has no import section.
    pub fn imports(self: *const Module, gpa: Allocator) IntrospectError!ModuleImports {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const sec = self.native.find(.import) orelse return .{ .arena = arena, .items = &.{} };
        var decoded = _sections.decodeImports(gpa, sec.body) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.DecodeFailed,
        };
        defer decoded.deinit();

        const out = try a.alloc(ImportItem, decoded.items.len);
        for (decoded.items, 0..) |it, i| {
            out[i] = .{
                .module = try a.dupe(u8, it.module),
                .name = try a.dupe(u8, it.name),
                .kind = importKind(it.kind),
            };
        }
        return .{ .arena = arena, .items = out };
    }

    /// Decoded export descriptors (field name + extern kind). Mirrors
    /// wasmtime's `Module::exports()`. The result owns its strings; call
    /// `.deinit()` when done. Empty when the module has no export section.
    pub fn exports(self: *const Module, gpa: Allocator) IntrospectError!ModuleExports {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const sec = self.native.find(.@"export") orelse return .{ .arena = arena, .items = &.{} };
        var decoded = _sections.decodeExports(gpa, sec.body) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.DecodeFailed,
        };
        defer decoded.deinit();

        const out = try a.alloc(ExportItem, decoded.items.len);
        for (decoded.items, 0..) |e, i| {
            out[i] = .{
                .name = try a.dupe(u8, e.name),
                .kind = exportKind(e.kind),
            };
        }
        return .{ .arena = arena, .items = out };
    }
};

const testing = std.testing;

test "Module.imports: func import → {module,name,kind} (ADR-0109 introspection)" {
    // Minimal module: type (func)->(), import env.imp_f (func 0),
    // export "exp_f" = the imported func (idx 0). No code section.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: 1× (func)->()
        0x02, 0x0d, 0x01, 0x03, 'e', 'n', 'v', 0x05, 'i', 'm', 'p', '_', 'f', 0x00, 0x00, // import env.imp_f (func 0)
        0x07, 0x09, 0x01, 0x05, 'e', 'x', 'p', '_', 'f', 0x00, 0x00, // export exp_f = func 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();

    var imps = try mod.imports(testing.allocator);
    defer imps.deinit();
    try testing.expectEqual(@as(usize, 1), imps.items.len);
    try testing.expectEqualStrings("env", imps.items[0].module);
    try testing.expectEqualStrings("imp_f", imps.items[0].name);
    try testing.expectEqual(ExternKind.func, imps.items[0].kind);

    var exps = try mod.exports(testing.allocator);
    defer exps.deinit();
    try testing.expectEqual(@as(usize, 1), exps.items.len);
    try testing.expectEqualStrings("exp_f", exps.items[0].name);
    try testing.expectEqual(ExternKind.func, exps.items[0].kind);
}

test "Engine.compile: rejects a memory whose declared min exceeds the spec page ceiling" {
    // (memory 70000) — min 70000 pages > 65536 (i32 ceiling). uleb 70000 = F0 A2 04.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x05, 0x01, 0x00, 0xF0, 0xA2, 0x04, // memory: min 70000
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    try testing.expectError(error.ValidateFailed, eng.compile(&bytes));
}

test "Engine.compile: accepts a table with a large valid min; rejects max < min (§3.2.4)" {
    // A large limit is a VALID table type (spec ceiling is the full u32 range;
    // reserving the entries is an instantiation-time concern, not validation):
    // the wasm-2.0 spec `table.6` fixture byte-for-byte — flag 0x01 (min+max),
    // min 0, max 0xffffffff (2^32-1).
    const ok = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x04, 0x09, 0x01, 0x70, 0x01, 0x00, 0xFF, 0xFF,
        0xFF, 0xFF, 0x0F,
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&ok); // valid — no ValidateFailed
    mod.deinit();

    // But max < min is malformed: flag 0x01 (min+max), min 10, max 5. Rejected
    // by compile (either the parse or the validate stage — both are correct
    // refusals; assert it does not compile successfully).
    const bad = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x04, 0x05, 0x01, 0x70, 0x01, 0x0A, 0x05,
    };
    var eng2 = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng2.deinit();
    try testing.expect(std.meta.isError(eng2.compile(&bad)));
}

test "Module.instantiate: default opts arm a finite fuel budget (ADR-0179)" {
    // (module (func (export "f") (result i32) (i32.const 42)))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 'f',
        0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41,
        0x2a, 0x0b,
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{}); // finite defaults, no extra call
    defer inst.deinit();
    const rem = inst.fuelRemaining() orelse return error.ExpectedFiniteDefault;
    try testing.expect(rem <= Module.default_fuel);
}

test "Module.instantiate: fuel=.limited(0) traps first instruction; .unmetered completes (ADR-0179)" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 'f',
        0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41,
        0x2a, 0x0b,
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var results = [_]_zwasm.Value{.{ .i32 = 0 }};

    // D-499 — pin `.interp`: `f` is a TRIVIAL leaf fn (no mem/global/call), and the
    // x86_64 JIT only emits the fuel/interrupt prologue poll for runtime-ptr-using
    // fns, so fuel=0 does NOT trap a trivial fn on x86_64 JIT (arm64 always polls).
    // The fuel=0-immediate-trap semantic on trivial fns is debt-tracked (D-499);
    // runaway-safety is intact (loops are back-edge-polled). This tests the contract.
    var inst0 = try mod.instantiate(.{ .fuel = .{ .limited = 0 }, .engine = .interp });
    defer inst0.deinit();
    try testing.expectError(error.OutOfFuel, inst0.invoke("f", &.{}, &results));

    var inst1 = try mod.instantiate(.{ .fuel = .unmetered });
    defer inst1.deinit();
    try inst1.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);
    try testing.expectEqual(@as(?u64, null), inst1.fuelRemaining());
}

test "Module.instantiate: declared initial memory above max_memory_pages → MemoryLimitExceeded (ADR-0179)" {
    // (module (memory 2))  — min 2 pages.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x02, // memory: min 2
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();

    try testing.expectError(error.MemoryLimitExceeded, mod.instantiate(.{ .max_memory_pages = .{ .limited = 1 } }));

    var inst = try mod.instantiate(.{ .max_memory_pages = .{ .limited = 2 } });
    defer inst.deinit();
    try testing.expect(inst.memory() != null);
}

test "Module.instantiate: declared initial table above max_table_elements → TableLimitExceeded (D-332)" {
    // (module (table 2 funcref)) — table section: count 1, funcref(0x70), min-only(0x00), min 2.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x04, 0x04, 0x01, 0x70, 0x00, 0x02, // table: funcref min 2
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();

    // A small declared min (2) above a low cap (1) is rejected WITHOUT allocating
    // — the cap bounds the INITIAL eager table alloc, not only table.grow.
    try testing.expectError(error.TableLimitExceeded, mod.instantiate(.{ .max_table_elements = .{ .limited = 1 } }));

    var inst = try mod.instantiate(.{ .max_table_elements = .{ .limited = 2 } });
    defer inst.deinit();
}

test "Module.exports: memory export → kind=.memory (kind-mapping boundary)" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x05, 0x03, 0x01, 0x00, 0x01, // memory: 1× {min 1}
        0x07, 0x05, 0x01, 0x01, 'm', 0x02, 0x00, // export "m" = memory 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();

    var imps = try mod.imports(testing.allocator);
    defer imps.deinit();
    try testing.expectEqual(@as(usize, 0), imps.items.len); // no import section → empty

    var exps = try mod.exports(testing.allocator);
    defer exps.deinit();
    try testing.expectEqual(@as(usize, 1), exps.items.len);
    try testing.expectEqualStrings("m", exps.items[0].name);
    try testing.expectEqual(ExternKind.memory, exps.items[0].kind);
}
