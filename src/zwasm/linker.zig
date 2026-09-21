//! `Linker` — host-import builder per ADR-0109 §3.2.
//!
//! Maintains a `(module, name) → host-fn / memory` registry that
//! is consulted at `instantiate(module)` time. Each `defineFunc`
//! comptime-derives the Wasm signature from the user's Zig fn,
//! type-checks it against the importing module's declared
//! signature at instantiate time (per Wasm spec §3.4.10), and
//! installs a `runtime.HostCall` slot.
//!
//! LIFETIME CONTRACT (Zig has no borrow checker — enforced by
//! convention, like wasmtime's `Store` ownership): a `Linker` MUST
//! outlive every `Instance` it instantiates that imports a host or
//! cross-module function. The importer's runtime holds a raw pointer
//! into the Linker-owned `CallCtx` (`ctx_storage`); calling such an
//! import after `Linker.deinit` is use-after-free. Likewise, a
//! cross-module `source_inst` MUST outlive every importer (its live
//! runtime / memory / global / table storage is aliased, not copied).
//! Both are caller obligations with no runtime guard.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dbg = @import("../support/dbg.zig");

const _api_instance = @import("../api/instance.zig");
const _api_wasi = @import("../api/wasi.zig");
const _cross_module = @import("../api/cross_module.zig");
const _sections = @import("../parse/sections.zig");
const _runtime = @import("../runtime/runtime.zig");
const _runtime_import = @import("../runtime/instance/import.zig");
const _wasi_host = @import("../wasi/host.zig");
const _zir = @import("../ir/zir.zig");
const _validate = @import("../validate/validator.zig");

const _zwasm = @import("../zwasm.zig");
const _engine = @import("engine.zig");
const _module = @import("module.zig");
const _memory_mod = @import("memory.zig");
const _caller = @import("caller.zig");
const _marshal = @import("host_func_marshal.zig");

pub const Caller = _caller.Caller;

pub const LinkError = error{
    UnknownImport,
    /// A `wasi_snapshot_preview1` import whose name has no thunk
    /// registered in `src/api/wasi.zig::lookupWasiThunk`. Distinct
    /// from `UnknownImport` so callers can route these as
    /// "phase-11 deferred" rather than treating them as fatal.
    UnsupportedWasiImport,
    ImportKindMismatch,
    SignatureMismatch,
    InstantiateFailed,
    WasiAlreadyDefined,
    OutOfMemory,
};

/// Bulk WASI configuration per ADR-0109 §3.8 +
/// `docs/zig_api_design.md` §3.8. Carries `args` / `envs` / `preopens`.
pub const WasiConfig = struct {
    args: []const []const u8 = &.{},
    /// Environment variables exposed to the guest via `environ_get` /
    /// `environ_sizes_get`. Each entry is a (name, value) pair; copied
    /// into the host on `defineWasi` (the slices need not outlive it).
    envs: []const Env = &.{},
    /// Filesystem preopens (D-177). Each opens `host_path` and exposes it
    /// to the guest as `guest_path` (the WASI fd-3+ preopen table). REQUIRES
    /// `io` — the dirs are opened at `instantiate` time via `io`, and the
    /// Host closes the fds on deinit. Empty = no preopens (back-compat).
    preopens: []const Preopen = &.{},
    /// The `std.Io` the WASI host uses for filesystem syscalls (`path_open`,
    /// preopen materialisation). The embedder brings its own io / event loop
    /// (no engine-owned thread). `null` → fs syscalls degrade; preopens then
    /// fail with `error.NoHostIo`.
    io: ?std.Io = null,
    // stdin / stdout / stderr capture: still facade-unwired (CLI / C-API meanwhile).

    pub const Env = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Preopen = struct {
        host_path: []const u8,
        guest_path: []const u8,
    };
};

pub const Linker = struct {
    engine: *_engine.Engine,
    entries: std.ArrayList(Entry) = .empty,
    ctx_storage: std.ArrayList(CtxEntry) = .empty,
    /// WASI host registered by `defineWasi`. Linker owns the
    /// allocation; thunks receive the pointer via their `ctx`
    /// argument (not via `store.wasi_host`, whose owning allocator
    /// is `wasm_store_delete`'s c_allocator).
    wasi_host: ?*_wasi_host.Host = null,

    pub const CtxEntry = struct {
        ptr: *anyopaque,
        destroy_fn: *const fn (Allocator, *anyopaque) void,
    };

    pub const Entry = struct {
        module: []const u8,
        name: []const u8,
        payload: Payload,
    };

    pub const Payload = union(enum) {
        host_func: HostFuncEntry,
        memory_alias: MemoryAlias,
        /// 10.M-D195b extension cycle 74 — cross-instance func
        /// binding. Resolves `(import "<as>" "<name>" (func …))`
        /// to a function in another already-instantiated module's
        /// runtime. The Linker holds the `CallCtx` arena slot via
        /// `ctx_storage` so it stays alive for the importing
        /// instance's lifetime (cross-module thunk dereferences
        /// `ctx` at every call).
        cross_module_func: CrossModuleFuncEntry,
        /// 10.M-D195b extension cycle 77 — cross-instance global
        /// alias. The slot pointer aliases the source instance's
        /// `Runtime.globals[idx]` cell so importer reads/writes
        /// see the same Value. Caller (the Linker user) must keep
        /// the source instance alive for the importing instance's
        /// lifetime. D-178 partial discharge (host-side global
        /// construction via standalone Store-anchored Global is
        /// still v0.2; this only wires the import-aliasing path).
        global_alias: GlobalAliasEntry,
        /// 10.E-xmodule-tags — cross-instance EH tag binding (ADR-0114).
        /// Resolves `(import "<as>" "<name>" (tag …))` to a tag in
        /// another already-instantiated module. v0.1 holds the source
        /// runtime + tag index (param-count type-match); `*TagInstance`
        /// pointer-identity is the execution-stage step.
        cross_module_tag: CrossModuleTagEntry,
        /// D-201b — cross-instance table alias. Holds the exporter's
        /// `TableInstance` (value; its `refs` slice header aliases the
        /// shared backing, so `elem`/`table.set` writes are visible to
        /// both modules). Caller keeps the source instance alive. NOTE:
        /// a cross-module `table.grow` (refs realloc) would stale this
        /// snapshot — *TableInstance sharing (cf. D-199 memory) is the
        /// follow-up if a grow-across-modules fixture needs it.
        table_alias: TableAlias,
    };

    pub const HostFuncEntry = struct {
        thunk_fn: *const fn (*_runtime.Runtime, *anyopaque) anyerror!void,
        ctx: *anyopaque,
        params: []const _zir.ValType,
        results: []const _zir.ValType,
    };

    pub const MemoryAlias = struct {
        /// D-199 — the exporter's live `*MemoryInstance` (shared, so
        /// `memory.grow` is visible to importers), not a stale slice.
        inst: *_runtime.MemoryInstance,
    };

    pub const TableAlias = struct {
        /// D-201b — the exporter's `TableInstance` (refs slice aliased).
        inst: _runtime.TableInstance,
    };

    pub const CrossModuleFuncEntry = struct {
        source_rt: *_runtime.Runtime,
        source_funcidx: u32,
        source_signature: _zir.FuncType,
        /// Whether the exporter's func type-definition is FINAL
        /// (`sub final` / bare comptype). D-202 PHASE B: a FINAL import
        /// may only resolve against an exporter type that is itself the
        /// same final type-definition; an open `(sub …)` exporter type
        /// is rejected even when structurally identical.
        source_final: bool,
        /// ADR-0127 PHASE C — the exporter func's type index into
        /// `source_types`, + the exporter module's retained `Types`. Lets the
        /// resolve check compare type-DEFINITIONS canonically across the two
        /// modules (`canonicalEqualCross` / `superReachesCross`), not just the
        /// flattened sig. `source_types` is null when the exporter has no type
        /// section (then PHASE C degenerates to PHASE A/B).
        source_typeidx: u32,
        source_types: ?*const _sections.Types,
        ctx_ptr: *_cross_module.CallCtx,
    };

    pub const GlobalAliasEntry = struct {
        slot: *_runtime.Value,
        source_valtype: _zir.ValType,
        source_mutable: bool,
    };

    pub const CrossModuleTagEntry = struct {
        source_rt: *_runtime.Runtime,
        source_tag_index: u32,
    };

    pub fn init(engine: *_engine.Engine) Linker {
        return .{ .engine = engine };
    }

    /// Frees the Linker's import registry + the cross-module/host
    /// `CallCtx` allocations. INVARIANT: every `Instance` instantiated
    /// through this Linker that imports a host or cross-module function
    /// MUST already be deinit'd — their runtimes hold raw pointers into
    /// the `ctx_storage` freed here (see the file-header lifetime
    /// contract). Deinit the Linker LAST.
    pub fn deinit(self: *Linker) void {
        for (self.ctx_storage.items) |e| e.destroy_fn(self.engine.alloc, e.ptr);
        self.ctx_storage.deinit(self.engine.alloc);
        self.entries.deinit(self.engine.alloc);
        if (self.wasi_host) |h| {
            h.deinit();
            self.engine.alloc.destroy(h);
            self.wasi_host = null;
        }
    }

    /// ADR-0109 §3.8 — bulk WASI bindings. After `defineWasi`,
    /// any `(import "wasi_snapshot_preview1" "<name>" ...)` in
    /// the module is satisfied by the registered host (all 46 WASI
    /// 0.1 thunks; Phase 11). Installs `cfg.args` + `cfg.envs`;
    /// `cfg.preopens` are queued here and OPENED at `instantiate`
    /// (they need `cfg.io`). At-most-once per Linker.
    pub fn defineWasi(self: *Linker, cfg: WasiConfig) !void {
        if (self.wasi_host != null) return error.WasiAlreadyDefined;
        const h = try self.engine.alloc.create(_wasi_host.Host);
        errdefer self.engine.alloc.destroy(h);
        h.* = try _wasi_host.Host.init(self.engine.alloc);
        errdefer h.deinit();

        h.io = cfg.io;

        if (cfg.args.len > 0) try h.setArgs(cfg.args);

        // Queue preopens; `instantiate` materialises them (opens via `io`).
        for (cfg.preopens) |p| try h.addPendingPreopen(p.host_path, p.guest_path);

        if (cfg.envs.len > 0) {
            // setEnvs takes parallel key/value slices; split the pair list
            // into two temporaries (setEnvs dupes, so they need not persist).
            const keys = try self.engine.alloc.alloc([]const u8, cfg.envs.len);
            defer self.engine.alloc.free(keys);
            const vals = try self.engine.alloc.alloc([]const u8, cfg.envs.len);
            defer self.engine.alloc.free(vals);
            for (cfg.envs, 0..) |e, i| {
                keys[i] = e.name;
                vals[i] = e.value;
            }
            try h.setEnvs(keys, vals);
        }

        self.wasi_host = h;
    }

    fn destroyForCtx(comptime Ctx: type) *const fn (Allocator, *anyopaque) void {
        return struct {
            fn d(a: Allocator, p: *anyopaque) void {
                const cp: *Ctx = @ptrCast(@alignCast(p));
                a.destroy(cp);
            }
        }.d;
    }

    /// Register a host function whose first parameter must be
    /// `*Caller`. The Wasm signature is comptime-derived from the
    /// remaining parameters and the return type per ADR-0109 §3.2.
    pub fn defineFunc(
        self: *Linker,
        module: []const u8,
        name: []const u8,
        comptime Sig: type,
        user_fn: *const Sig,
    ) !void {
        return self.defineFuncImpl(module, name, null, Sig, user_fn);
    }

    /// Like `defineFunc`, but threads an opaque host context that the host
    /// fn recovers via `Caller.data(T)` (wasmtime's `Caller::data`). Used
    /// when a trampoline needs host-side state beyond the guest runtime —
    /// e.g. the WASI-P2 output-stream trampolines need the `wasi.Host` +
    /// resource table. `host_data` must outlive every Instance instantiated
    /// through this Linker (same contract as the file-header lifetime note).
    pub fn defineFuncCtx(
        self: *Linker,
        module: []const u8,
        name: []const u8,
        host_data: *anyopaque,
        comptime Sig: type,
        user_fn: *const Sig,
    ) !void {
        return self.defineFuncImpl(module, name, host_data, Sig, user_fn);
    }

    fn defineFuncImpl(
        self: *Linker,
        module: []const u8,
        name: []const u8,
        host_data: ?*anyopaque,
        comptime Sig: type,
        user_fn: *const Sig,
    ) !void {
        const fn_info = @typeInfo(Sig).@"fn";
        if (fn_info.params.len == 0 or (fn_info.params[0].type orelse return error.SignatureMismatch) != *Caller) {
            @compileError("Linker.defineFunc: host fn must take *Caller as first param");
        }
        const Ctx = _marshal.HostFnCtx(Sig);
        const ctx_ptr = try self.engine.alloc.create(Ctx);
        errdefer self.engine.alloc.destroy(ctx_ptr);
        ctx_ptr.* = .{ .user_fn = user_fn, .host_data = host_data };
        try self.ctx_storage.append(self.engine.alloc, .{
            .ptr = ctx_ptr,
            .destroy_fn = destroyForCtx(Ctx),
        });

        const sig = comptime _marshal.signatureOf(Sig);
        try self.entries.append(self.engine.alloc, .{
            .module = module,
            .name = name,
            .payload = .{ .host_func = .{
                .thunk_fn = _marshal.thunkFor(Sig),
                .ctx = ctx_ptr,
                .params = sig.params,
                .results = sig.results,
            } },
        });
    }

    /// Register a host function with a RUNTIME-arity signature: `params` /
    /// `results` are explicit core ValType slices (must outlive every Instance
    /// instantiated through this Linker, same contract as `host_data`), and the
    /// host fn receives the popped operands as a `[]const Value`. Unlike
    /// `defineFuncCtx`, no per-arity Zig fn type is reflected — ONE `rawThunk`
    /// serves every arity. Used by the cross-component boundary to collapse the
    /// per-arity trampolines (D-305): a single Value-slice trampoline marshals
    /// any flat-scalar arity instead of a `BoundarySigN` per N.
    pub fn defineFuncRaw(
        self: *Linker,
        module: []const u8,
        name: []const u8,
        host_data: ?*anyopaque,
        params: []const _zir.ValType,
        results: []const _zir.ValType,
        user_fn: _marshal.RawHostFn,
    ) !void {
        const ctx_ptr = try self.engine.alloc.create(_marshal.RawHostFnCtx);
        errdefer self.engine.alloc.destroy(ctx_ptr);
        ctx_ptr.* = .{
            .user_fn = user_fn,
            .host_data = host_data,
            .n_params = params.len,
            .n_results = results.len,
        };
        try self.ctx_storage.append(self.engine.alloc, .{
            .ptr = ctx_ptr,
            .destroy_fn = destroyForCtx(_marshal.RawHostFnCtx),
        });
        try self.entries.append(self.engine.alloc, .{
            .module = module,
            .name = name,
            .payload = .{ .host_func = .{
                .thunk_fn = _marshal.rawThunk,
                .ctx = ctx_ptr,
                .params = params,
                .results = results,
            } },
        });
    }

    pub fn defineMemory(self: *Linker, module: []const u8, name: []const u8, mem: _memory_mod.Memory) !void {
        // D-199 — share the exporter's memory0 `*MemoryInstance` so
        // importers see growth. Requires the source to have a
        // materialised `rt.memories[0]` (every memory-bearing module
        // does post-instantiate).
        try self.entries.append(self.engine.alloc, .{
            .module = module,
            .name = name,
            .payload = .{ .memory_alias = .{ .inst = mem.backing.interp.memories[0] } },
        });
    }

    /// 10.M-D195b cycle 75 — `*MemoryInstance` overload of
    /// `defineMemory` for multi-memory exports (memidx > 0). Pass
    /// `source_inst.handle.runtime.?.memories[memidx]` (D-199: the
    /// shared instance pointer, not a copied slice). Caller keeps the
    /// source instance alive.
    pub fn defineMemoryInstance(self: *Linker, module: []const u8, name: []const u8, inst: *_runtime.MemoryInstance) !void {
        try self.entries.append(self.engine.alloc, .{
            .module = module,
            .name = name,
            .payload = .{ .memory_alias = .{ .inst = inst } },
        });
    }

    /// D-201b — export a table for cross-module import. Pass the source
    /// instance's `rt.tables[idx]` (value; its `refs` slice aliases the
    /// shared backing, so `elem`/`table.set` writes are mutually
    /// visible). Caller keeps the source instance alive.
    pub fn defineTable(self: *Linker, module: []const u8, name: []const u8, inst: _runtime.TableInstance) !void {
        try self.entries.append(self.engine.alloc, .{
            .module = module,
            .name = name,
            .payload = .{ .table_alias = .{ .inst = inst } },
        });
    }

    /// 10.M-D195b cycle 77 — alias a global export from another
    /// already-instantiated module. The importing module's `(import
    /// <module> <name> (global …))` resolves to the source's
    /// `globals[idx]` cell via a shared `*Value` pointer.
    /// `source_inst` must outlive every Instance instantiated
    /// through this Linker.
    pub fn defineGlobal(
        self: *Linker,
        module: []const u8,
        name: []const u8,
        source_inst: *_zwasm.Instance,
        source_name: []const u8,
    ) !void {
        const source_rt = source_inst.handle.runtime orelse return error.SignatureMismatch;
        var glob_idx: u32 = std.math.maxInt(u32);
        var glob_valtype: _zir.ValType = .i32;
        var glob_mutable: bool = false;
        for (source_inst.handle.exports_storage, source_inst.handle.export_types) |exp, et| {
            if (!std.mem.eql(u8, exp.name, source_name)) continue;
            if (exp.kind != .global) return error.ImportKindMismatch;
            glob_idx = exp.idx;
            glob_valtype = et.global.valtype;
            glob_mutable = et.global.mutable;
            break;
        }
        if (glob_idx == std.math.maxInt(u32)) return error.UnknownImport;
        if (glob_idx >= source_rt.globals.len) return error.UnknownImport;

        try self.entries.append(self.engine.alloc, .{
            .module = module,
            .name = name,
            .payload = .{ .global_alias = .{
                .slot = source_rt.globals[glob_idx],
                .source_valtype = glob_valtype,
                .source_mutable = glob_mutable,
            } },
        });
    }

    /// 10.M-D195b cycle 74 — bind a cross-instance function. The
    /// `source_inst` is a previously-instantiated module that
    /// exports `<source_name>` as a function; the importing
    /// module's `(import <module> <name> (func …))` resolves to
    /// the source's funcidx via the cross-module dispatch thunk
    /// (`src/api/cross_module.zig`). `source_inst` must outlive
    /// every Instance instantiated through this Linker (the
    /// CallCtx aliases its runtime).
    pub fn defineCrossModuleFunc(
        self: *Linker,
        module: []const u8,
        name: []const u8,
        source_inst: *_zwasm.Instance,
        source_name: []const u8,
    ) !void {
        const source_rt = source_inst.handle.runtime orelse return error.SignatureMismatch;
        // Find the export by name + ensure it's a func. Capture the
        // exporter func type's FINALITY from `export_types` (parallel to
        // `exports_storage`) for the D-202 PHASE B import-finality check.
        var src_funcidx: u32 = std.math.maxInt(u32);
        var source_final = false;
        var source_typeidx: u32 = 0;
        for (source_inst.handle.exports_storage, 0..) |exp, ei| {
            if (!std.mem.eql(u8, exp.name, source_name)) continue;
            if (exp.kind != .func) return error.ImportKindMismatch;
            src_funcidx = exp.idx;
            if (ei < source_inst.handle.export_types.len) {
                switch (source_inst.handle.export_types[ei]) {
                    .func => |fe| {
                        source_final = fe.final;
                        source_typeidx = fe.typeidx;
                    },
                    else => {},
                }
            }
            break;
        }
        const source_types: ?*const _sections.Types = if (source_inst.handle.export_src_types) |*t| t else null;
        if (src_funcidx == std.math.maxInt(u32)) return error.UnknownImport;
        const src_sig = source_inst.exportFuncSig(source_name) orelse return error.SignatureMismatch;

        const ctx_ptr = try self.engine.alloc.create(_cross_module.CallCtx);
        errdefer self.engine.alloc.destroy(ctx_ptr);
        ctx_ptr.* = .{
            .source_rt = source_rt,
            .source_funcidx = src_funcidx,
            .dispatch_table = _api_instance.dispatchTable(),
        };
        try self.ctx_storage.append(self.engine.alloc, .{
            .ptr = @ptrCast(ctx_ptr),
            .destroy_fn = struct {
                fn d(a: Allocator, p: *anyopaque) void {
                    const cp: *_cross_module.CallCtx = @ptrCast(@alignCast(p));
                    a.destroy(cp);
                }
            }.d,
        });

        try self.entries.append(self.engine.alloc, .{
            .module = module,
            .name = name,
            .payload = .{ .cross_module_func = .{
                .source_rt = source_rt,
                .source_funcidx = src_funcidx,
                .source_signature = src_sig,
                .source_final = source_final,
                .source_typeidx = source_typeidx,
                .source_types = source_types,
                .ctx_ptr = ctx_ptr,
            } },
        });
    }

    /// 10.E-xmodule-tags — register a cross-module EH tag (ADR-0114).
    /// `source_tag_index` is the tag's index in `source_inst`'s tag
    /// space; the importer resolves `(import module name (tag …))`
    /// against this entry. No per-tag ctx (unlike funcs) — v0.1 only
    /// records identity for the import-binding step.
    pub fn defineCrossModuleTag(
        self: *Linker,
        module: []const u8,
        name: []const u8,
        source_inst: *_zwasm.Instance,
        source_tag_index: u32,
    ) !void {
        const source_rt = source_inst.handle.runtime orelse return error.SignatureMismatch;
        try self.entries.append(self.engine.alloc, .{
            .module = module,
            .name = name,
            .payload = .{ .cross_module_tag = .{
                .source_rt = source_rt,
                .source_tag_index = source_tag_index,
            } },
        });
    }

    /// Register EVERY export of an already-instantiated `source_inst`
    /// under the namespace `module`, in one call (wasmtime's
    /// `Linker::define_instance`). Each export is aliased — funcs via
    /// the cross-module dispatch thunk, globals/memories/tables via the
    /// shared `*Value` / `*MemoryInstance` / `TableInstance` (D-199 /
    /// D-201b) — so the importer sees the source's live state, including
    /// later mutation/growth. A sugar wrapper over the point-wise
    /// `defineCrossModuleFunc` / `defineGlobal` / `defineMemoryInstance`
    /// / `defineTable`; `source_inst` must outlive every Instance
    /// instantiated through this Linker.
    pub fn defineInstance(self: *Linker, module: []const u8, source_inst: *_zwasm.Instance) !void {
        const source_rt = source_inst.handle.runtime orelse return error.SignatureMismatch;
        for (source_inst.handle.exports_storage) |exp| {
            switch (exp.kind) {
                .func => try self.defineCrossModuleFunc(module, exp.name, source_inst, exp.name),
                .global => try self.defineGlobal(module, exp.name, source_inst, exp.name),
                .memory => {
                    if (exp.idx >= source_rt.memories.len) return error.UnknownImport;
                    try self.defineMemoryInstance(module, exp.name, source_rt.memories[exp.idx]);
                },
                .table => {
                    if (exp.idx >= source_rt.tables.len) return error.UnknownImport;
                    try self.defineTable(module, exp.name, source_rt.tables[exp.idx]);
                },
                .tag => try self.defineCrossModuleTag(module, exp.name, source_inst, exp.idx),
            }
        }
    }

    /// Instantiate `mod` against the registered imports, returning
    /// a native `Instance`. Per ADR-0109 §3.2 the signature
    /// type-check happens here against each `(import ...)`
    /// declaration; unknown imports + signature mismatches surface
    /// as named errors before any runtime state is allocated.
    pub fn instantiate(self: *Linker, mod: *_module.Module, opts: _module.Module.InstantiateOpts) LinkError!_zwasm.Instance {
        const arena = std.heap.ArenaAllocator;
        var scratch_arena = arena.init(self.engine.alloc);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        const imp_section = mod.native.find(.import);
        var bindings_list: std.ArrayList(_runtime_import.ImportBinding) = .empty;
        defer bindings_list.deinit(scratch);

        if (imp_section) |sec| {
            var decoded = _sections.decodeImports(scratch, sec.body) catch return error.InstantiateFailed;
            defer decoded.deinit();

            const types_section = mod.native.find(.type);
            var module_types: ?_sections.Types = null;
            defer if (module_types) |*t| t.deinit();
            if (types_section) |ts| {
                module_types = _sections.decodeTypes(scratch, ts.body) catch return error.InstantiateFailed;
            }

            // Each WASI thunk receives the host via its `ctx`
            // argument (`host_call.ctx = host`), so we deliberately
            // do NOT write `store.wasi_host` here — that field's
            // owning allocator is `wasm_store_delete`'s c_allocator,
            // while ours is the Engine's user-supplied allocator.
            // The Linker keeps ownership of the host across all
            // instances created from it.

            for (decoded.items) |it| {
                // ADR-0109 §3.8 — WASI shortcut: any
                // `wasi_snapshot_preview1` import resolves through
                // the registered host even if no entry was added
                // via defineFunc.
                if (std.mem.eql(u8, it.module, "wasi_snapshot_preview1")) {
                    if (it.kind != .func) return error.ImportKindMismatch;
                    const host = self.wasi_host orelse return error.UnknownImport;
                    const thunk = _api_wasi.lookupWasiThunk(it.name) orelse return error.UnsupportedWasiImport;
                    bindings_list.append(scratch, .{ .func = .{
                        .host_call = .{ .fn_ptr = thunk, .ctx = @ptrCast(host) },
                        .source = .wasi,
                    } }) catch return error.OutOfMemory;
                    continue;
                }

                const entry = self.findEntry(it.module, it.name) orelse return error.UnknownImport;
                switch (it.kind) {
                    .func => {
                        const typeidx = switch (it.payload) {
                            .func_typeidx => |t| t,
                            else => return error.SignatureMismatch,
                        };
                        const types = (module_types orelse return error.SignatureMismatch).items;
                        if (typeidx >= types.len) return error.SignatureMismatch;
                        const declared = types[typeidx];
                        switch (entry.payload) {
                            .host_func => |host| {
                                if (!sigEqual(declared.params, host.params) or !sigEqual(declared.results, host.results)) {
                                    // `ZWASM_DEBUG=link.trace` names the offending
                                    // import (the bare error code cost a real
                                    // debugging session on the official wasip3
                                    // corpus — keep the diagnostic).
                                    if (dbg.on("link.trace")) std.debug.print("[link] SignatureMismatch: {s}::{s}\n", .{ it.module, it.name });
                                    return error.SignatureMismatch;
                                }
                                bindings_list.append(scratch, .{
                                    .func = .{
                                        .host_call = .{ .fn_ptr = host.thunk_fn, .ctx = host.ctx },
                                        .source = .wasi,
                                    },
                                }) catch return error.OutOfMemory;
                            },
                            .cross_module_func => |cmf| {
                                // 10.M-D195b cycle 74 — cross-instance func
                                // binding via the cross_module.thunk dispatcher.
                                // Import-time check uses func SUBTYPING
                                // (contravariant params / covariant results;
                                // Wasm 3.0 §3.3.5.3), NOT exact equality — a
                                // cross-module import may resolve against a
                                // subtype-compatible exported func (D-202 PHASE A,
                                // gc/type-subtyping.30/.48/.50). Mirrors the
                                // instantiate.zig::checkImportTypeMatches path
                                // (cyc192). Same-typespace simplification: the
                                // importer's `module_types` interprets both sides
                                // (valid while corpus type defs are duplicated;
                                // distinct-layout + finality = D-202 PHASE B).
                                if (!_validate.funcTypeImportCompatible(declared, cmf.source_signature, &module_types.?)) {
                                    return error.SignatureMismatch;
                                }
                                // ADR-0127 PHASE C: type-DEFINITION compatibility
                                // (subsumes the PHASE B finality check). The
                                // exporter type-def must BE the importer's declared
                                // type (canonicalEqualCross) OR declare it as a
                                // supertype (superReachesCross), compared canonically
                                // across the two modules' Types — structural sig
                                // equality is not enough (assert_unlinkable
                                // gc/type-subtyping.35/.36/.42/.52/.54: open `(sub
                                // (func))` ↔ distinct `(sub final (func))`). Falls
                                // back to the finality check when the exporter has no
                                // retained type section.
                                if (cmf.source_types) |src_types| {
                                    const def_ok = _sections.canonicalEqualCross(&module_types.?, typeidx, src_types, cmf.source_typeidx) or
                                        _sections.superReachesCross(src_types, cmf.source_typeidx, &module_types.?, typeidx);
                                    if (!def_ok) return error.SignatureMismatch;
                                } else if (module_types.?.finals[typeidx] and !cmf.source_final) {
                                    return error.SignatureMismatch;
                                }
                                bindings_list.append(scratch, .{
                                    .func = .{
                                        .host_call = .{ .fn_ptr = _cross_module.thunk, .ctx = @ptrCast(cmf.ctx_ptr) },
                                        .source = .{ .cross_module = .{
                                            .source_runtime = cmf.source_rt,
                                            .source_funcidx = cmf.source_funcidx,
                                            .source_signature = cmf.source_signature,
                                        } },
                                    },
                                }) catch return error.OutOfMemory;
                            },
                            else => return error.ImportKindMismatch,
                        }
                    },
                    .memory => {
                        // D-199 — importer adopts the exporter's shared
                        // `*MemoryInstance` (idx_type/page-bounds come with
                        // it; the importer's declared limits in `it.payload`
                        // are the compat constraint, checked elsewhere).
                        _ = switch (it.payload) {
                            .memory => |m| m,
                            else => return error.ImportKindMismatch,
                        };
                        const alias = switch (entry.payload) {
                            .memory_alias => |m| m,
                            else => return error.ImportKindMismatch,
                        };
                        bindings_list.append(scratch, .{ .memory = .{
                            .inst = alias.inst,
                        } }) catch return error.OutOfMemory;
                    },
                    .global => {
                        // 10.M-D195b cycle 77 — cross-instance global
                        // alias binding. Importer declares valtype +
                        // mutable; runtime-side type check at call
                        // boundary compares against source.
                        const decl = switch (it.payload) {
                            .global => |g| g,
                            else => return error.ImportKindMismatch,
                        };
                        const ga = switch (entry.payload) {
                            .global_alias => |g| g,
                            else => return error.ImportKindMismatch,
                        };
                        if (!decl.valtype.eql(ga.source_valtype)) return error.SignatureMismatch;
                        if (decl.mutable != ga.source_mutable) return error.SignatureMismatch;
                        bindings_list.append(scratch, .{ .global = .{
                            .slot = ga.slot,
                            .source_valtype = ga.source_valtype,
                            .source_mutable = ga.source_mutable,
                        } }) catch return error.OutOfMemory;
                    },
                    .table => {
                        // D-201b — cross-module table import: adopt the
                        // exporter's `TableInstance` (refs aliased) so
                        // elem / table.set writes are mutually visible.
                        const alias = switch (entry.payload) {
                            .table_alias => |t| t,
                            else => return error.ImportKindMismatch,
                        };
                        bindings_list.append(scratch, .{
                            .table = .{
                                .instance = alias.inst,
                                .source_elem_type = alias.inst.elem_type,
                                .source_min = @intCast(alias.inst.refs.len),
                                // table64 source max (u64) narrowed to the u32 binding field
                                // (saturate — cross-module i64-table import limit).
                                .source_max = if (alias.inst.max) |m| (std.math.cast(u32, m) orelse std.math.maxInt(u32)) else null,
                            },
                        }) catch return error.OutOfMemory;
                    },
                    // EH tag import (10.E-xmodule-tags) — resolve against
                    // a `defineCrossModuleTag` entry. Param-count type
                    // match happens runtime-side (checkImportTypeMatches);
                    // here we just thread the source identity through.
                    .tag => {
                        const ct = switch (entry.payload) {
                            .cross_module_tag => |c| c,
                            else => return error.ImportKindMismatch,
                        };
                        bindings_list.append(scratch, .{ .tag = .{
                            .source_runtime = ct.source_rt,
                            .source_tag_index = ct.source_tag_index,
                        } }) catch return error.OutOfMemory;
                    },
                }
            }
        }

        // D-177 — open queued WASI preopens (via cfg.io) before the instance
        // runs. No-op when none were queued; NoHostIo / fs errors surface as
        // InstantiateFailed (preopens set without an io are a caller error).
        if (self.wasi_host) |h| h.materializePendingPreopens() catch return error.InstantiateFailed;

        const prebuilt = bindings_list.items;
        const Pre = struct {
            slice: ?[]const _runtime_import.ImportBinding,
            fn b(ctx: *anyopaque, arena_alloc: Allocator, bytes: []const u8, store: *_api_instance.Store) anyerror!?[]const _runtime_import.ImportBinding {
                _ = arena_alloc;
                _ = bytes;
                _ = store;
                const s: *@This() = @ptrCast(@alignCast(ctx));
                return s.slice;
            }
            fn asBuilder(s: *@This()) _api_instance.BindingsBuilder {
                return .{ .ctx = s, .build = b };
            }
        };
        var pre: Pre = .{ .slice = if (prebuilt.len == 0) null else prebuilt };
        // REQ-4 (cw CM-API) — per-instance budget (fuel / max-memory) applied at
        // instantiation, mirroring Module.instantiate: cap takes effect before the
        // start fn runs + before the initial memory alloc.
        const limits: _api_instance.InstantiateLimits = .{
            .fuel = opts.fuel.toOptional(),
            .max_memory_pages = opts.max_memory_pages.toOptional(),
            .max_table_elements = opts.max_table_elements.toOptional(), // D-332
        };
        // trap_out=null: the Linker path keeps the coarse InstantiateFailed for
        // a start trap (its rich LinkError covers the import-resolution failures);
        // surfacing a start trap here is a follow-up if a consumer needs it (D-275).
        // ADR-0200 / D-496 — the Linker path stays INTERP-pinned even after the
        // `.auto`→JIT flip: cross-module func/global/table/memory aliasing +
        // component graph wiring are interp-runtime invariants (the JIT instance
        // exposes accessors but not the cross-instance aliasing the Linker builds).
        // Engine selection on the Linker is a separate follow-up slice.
        const inst_ptr = _api_instance.instantiateInternal(mod.c_store, mod.c_handle, pre.asBuilder(), null, limits, .interp) orelse return error.InstantiateFailed;
        return .{ .handle = inst_ptr, .c_store = mod.c_store };
    }

    fn findEntry(self: *Linker, module: []const u8, name: []const u8) ?*const Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.module, module) and std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

fn sigEqual(a: []const _zir.ValType, b: []const _zir.ValType) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

const testing = std.testing;

test "Linker.defineInstance: registers every export (func/table/memory/global) under one namespace" {
    // Module A exports a func, a table, a memory, and a global.
    const a_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: ()->(i32)
        0x03, 0x02, 0x01, 0x00, // func: 1× type 0
        0x04, 0x04, 0x01, 0x70, 0x00, 0x01, // table: funcref, min 1
        0x05, 0x03, 0x01, 0x00, 0x01, // memory: min 1
        0x06, 0x06, 0x01, 0x7f, 0x00, 0x41, 0x00, 0x0b, // global: i32, init i32.const 0
        // export: "f"=func0, "mem"=memory0, "g"=global0, "t"=table0
        0x07, 0x13, 0x04, 0x01, 'f',  0x00, 0x00, 0x03,
        'm',  'e',  'm',  0x02, 0x00, 0x01, 'g',  0x03,
        0x00, 0x01, 't',  0x01, 0x00,
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b, // code: func returns i32.const 42
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod_a = try eng.compile(&a_bytes);
    defer mod_a.deinit();
    var inst_a = try mod_a.instantiate(.{ .engine = .interp });
    defer inst_a.deinit();

    var lk = eng.linker();
    defer lk.deinit();
    try lk.defineInstance("a", &inst_a);

    // One linker entry per export, all under module "a".
    try testing.expectEqual(@as(usize, 4), lk.entries.items.len);
    try testing.expect(lk.findEntry("a", "f") != null);
    try testing.expect(lk.findEntry("a", "mem") != null);
    try testing.expect(lk.findEntry("a", "g") != null);
    try testing.expect(lk.findEntry("a", "t") != null);
}

test "Linker.defineInstance: a tag export is registered, and a tag import links through it (#478)" {
    // A: (type (func (param i32))) (tag (type 0)) (export "t" (tag 0))
    const a_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00, // type: (i32)->()
        0x0d, 0x03, 0x01, 0x00, 0x00, // tag: 1× type 0
        0x07, 0x05, 0x01, 0x01, 't', 0x04, 0x00, // export "t"=tag0
    };
    // B: (type (func (param i32))) (import "a" "t" (tag (type 0)))
    const b_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00,
        0x02, 0x08, 0x01, 0x01, 'a', 0x01, 't', 0x04, 0x00, 0x00, // import a.t (tag type 0)
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod_a = try eng.compile(&a_bytes);
    defer mod_a.deinit();
    var inst_a = try mod_a.instantiate(.{ .engine = .interp });
    defer inst_a.deinit();

    var lk = eng.linker();
    defer lk.deinit();
    try lk.defineInstance("a", &inst_a);
    try testing.expectEqual(@as(usize, 1), lk.entries.items.len);
    try testing.expect(lk.findEntry("a", "t") != null);

    var mod_b = try eng.compile(&b_bytes);
    defer mod_b.deinit();
    var inst_b = try lk.instantiate(&mod_b, .{ .engine = .interp });
    defer inst_b.deinit();
}

test "start function may be an IMPORTED host func (wit-component start-shim shape)" {
    // (module (type (func)) (import "env" "tick" (func (type 0))) (start 0))
    // — the start funcidx names the import itself (Wasm §4.5.4 allows it;
    // wit-component's start-shim wraps `_initialize` exactly this way).
    // Before the host_calls dispatch fix the placeholder `unreachable` body
    // ran instead, failing instantiation.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: ()->()
        0x02, 0x0c, 0x01, 0x03, 'e', 'n', 'v', 0x04, 't', 'i', 'c', 'k', 0x00, 0x00, // import env.tick (func type 0)
        0x08, 0x01, 0x00, // start: func 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();

    var lk = eng.linker();
    defer lk.deinit();
    var ticks: u32 = 0;
    const H = struct {
        fn tick(caller: *Caller) anyerror!void {
            caller.data(u32).* += 1;
        }
    };
    try lk.defineFuncCtx("env", "tick", &ticks, fn (*Caller) anyerror!void, H.tick);
    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();
    try testing.expectEqual(@as(u32, 1), ticks);
}

test "Linker.defineWasi: WasiConfig.envs populate the host environ (D-177)" {
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var lk = eng.linker();
    defer lk.deinit();
    try lk.defineWasi(.{
        .args = &.{"prog"},
        .envs = &.{
            .{ .name = "FOO", .value = "bar" },
            .{ .name = "BAZ", .value = "qux" },
        },
    });
    const host = lk.wasi_host.?;
    try testing.expectEqual(@as(usize, 2), host.envs.len);
    try testing.expectEqualStrings("FOO", host.envs[0].key);
    try testing.expectEqualStrings("bar", host.envs[0].value);
    try testing.expectEqualStrings("BAZ", host.envs[1].key);
    try testing.expectEqualStrings("qux", host.envs[1].value);
}

test "Linker.defineWasi: WasiConfig.preopens materialise into the host at instantiate (D-177)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var lk = eng.linker();
    defer lk.deinit();
    // Preopen the cwd as guest "/sandbox"; the dir is opened via `io` at instantiate.
    try lk.defineWasi(.{
        .io = threaded.io(),
        .preopens = &.{.{ .host_path = ".", .guest_path = "/sandbox" }},
    });
    // Minimal `() -> i32` (returns 42, export "f") — no imports.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 'f',
        0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41,
        0x2a, 0x0b,
    };
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();
    // `instantiate` drained the pending preopen + opened it into the fd table.
    const host = lk.wasi_host.?;
    try testing.expectEqual(@as(usize, 1), host.preopens.len);
    try testing.expectEqualStrings("/sandbox", host.preopens[0].guest_path);
    try testing.expectEqual(@as(usize, 0), host.pending_preopens.items.len);
}
