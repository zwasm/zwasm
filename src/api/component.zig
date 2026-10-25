//! Component Model **host orchestration** (Zone 3; CM campaign chunk B6).
//!
//! Per ADR-0172 the engine-driving orchestration lives here (Zone 3): it
//! decodes a component (Zone-1 `feature/component/decode`), instantiates the
//! embedded core modules via the public `Engine` facade, and invokes exports.
//! The pure canonical-ABI / WIT logic stays in Zone 1; this file is the only
//! place that touches `invoke`.
//!
//! IT-1 (this chunk): a single embedded core module is instantiated behind a
//! heap-stable `ComponentInstance` handle, and a flat-scalar export is
//! invokable directly with facade `Value`s (no canon trampoline yet). Canon
//! lift/lower + the `cabi_realloc` wiring engage at IT-3 (string→string).

const std = @import("std");

const decode = @import("../feature/component/decode.zig");
const canon = @import("../feature/component/canon.zig");
const ctypes = @import("../feature/component/types.zig");
const diagnostic = @import("../diagnostic/diagnostic.zig");
const cvalidate = @import("../feature/component/validate.zig");
const value_conv = @import("../zwasm/value_conv.zig");
const zwasm = @import("../zwasm.zig");
const wasi_host = @import("../wasi/host.zig");

const Allocator = std.mem.Allocator;
const Engine = @import("../zwasm/engine.zig").Engine;
const Module = @import("../zwasm/module.zig").Module;
const Instance = @import("../zwasm/instance.zig").Instance;
const Value = zwasm.Value;
const PrimValType = ctypes.PrimValType;

/// Max flattened core params for the flat (register) call path (`CanonicalABI.md`).
pub const MAX_FLAT_PARAMS = 16;

const typed = @import("component_typed.zig");
const coreToFacade = typed.coreToFacade;

pub const Error = error{
    /// The component embeds no core module to instantiate.
    NoCoreModule,
    OutOfMemory,
} || decode.Error || ctypes.Error || Module.InstantiateError;

/// Per-instance budget (fuel / max-memory) for the component instantiate
/// entry points (REQ-4, cw CM-API). Re-exported from `Module` so consumers
/// have a single name; `.{}` = the default budget.
pub const InstantiateOpts = Module.InstantiateOpts;

/// An instantiated component. IT-1 holds a single embedded core module's
/// instance; multi-module graphs land in C2. The `Module`/`Instance` are
/// heap-allocated for stable addresses (the facade structs hold c-api handles;
/// heap storage keeps the handle owners pinned across the struct's lifetime).
pub const ComponentInstance = struct {
    alloc: Allocator,
    /// Owned copy of the component bytes. `decoded` (and the `info` names +
    /// core `module` that slice it) borrow from THIS, so the instance is
    /// self-contained — a host can free its load buffer and keep the opened
    /// component cached (REQ-7 / D-326).
    owned_bytes: []const u8,
    decoded: decode.Component,
    /// Decoded type/canon/alias index spaces — used to resolve a component
    /// export to the core funcs the host invokes (C2-2).
    info: ctypes.TypeInfo,
    /// Borrowed — the caller owns the `Engine` and must outlive this.
    engine: *Engine,
    module: *Module,
    core: *Instance,
    /// The core export name `reallocViaGuest` invokes — set per resolved call
    /// (defaults to the conventional `cabi_realloc`).
    realloc_name: []const u8 = "cabi_realloc",

    /// ADR-0183 F1 — introspect the typed func exports from the
    /// SELF-DESCRIBING binary (no `.wit` sidecar; CWFS ADR-0135),
    /// including interface-nested funcs path-qualified `<iface>#<func>`.
    /// Free via `TypeInfo.freeExportedFuncs` (names alloc-owned; types
    /// borrow from the instance's `TypeInfo`).
    pub fn exportedFuncs(self: *const ComponentInstance, alloc: Allocator) Allocator.Error![]ctypes.TypeInfo.ExportedFunc {
        return self.info.exportedFuncs(alloc);
    }

    /// REQ-3 (cw CM-API) — resolve a func export's full typed signature to
    /// the specialization-preserving, label-carrying `WitType` tree. `arena`
    /// owns the returned tree (free it all at once); label/field names borrow
    /// from this instance's `TypeInfo`. Returns `null` when `name` does not
    /// resolve to a concrete func. Accepts top-level + `<iface>#<func>` paths.
    pub fn resolveFuncSig(self: *const ComponentInstance, arena: Allocator, name: []const u8) wit_type.Error!?FuncSig {
        return wit_type.resolveFuncSig(arena, &self.info, name);
    }

    /// ADR-0183 F2b/F3 — TYPED invoke through the canonical ABI: validates
    /// `args` against the export's WIT signature (from the self-describing
    /// binary), lowers them flat (compound payloads via the guest's
    /// `cabi_realloc`; >MAX_FLAT_PARAMS spills to a memory tuple), invokes
    /// the lifted core func, and lifts the result into a caller-owned
    /// `ComponentValue` (free with `.deinit(out_alloc)`).
    pub fn invokeTyped(
        self: *ComponentInstance,
        export_name: []const u8,
        args: []const ComponentValue,
        out_alloc: std.mem.Allocator,
    ) InvokeTypedError!?ComponentValue {
        const ft = self.info.resolveFuncType(export_name) orelse return diagUnresolved(export_name);
        const r = self.info.resolveLiftedFunc(export_name) orelse return diagUnresolved(export_name);
        if (r.string_encoding != .utf8) {
            diagnostic.setDiag(.execute, .other, .unknown, "typed invoke '{s}': unsupported string encoding (only utf8)", .{export_name});
            return InvokeTypedError.UnsupportedEncoding;
        }
        if (r.realloc) |rr| self.realloc_name = rr.name;
        const cx = try self.canonContext();
        // Single-module component: the lifted func AND post_return both
        // live on the one embedded core instance.
        return typed.invokeTypedCore(self.alloc, &self.info, cx, self.core, self.core, ft, r, args, out_alloc);
    }

    pub fn deinit(self: *ComponentInstance) void {
        self.core.deinit();
        self.alloc.destroy(self.core);
        self.module.deinit();
        self.alloc.destroy(self.module);
        self.info.deinit();
        self.decoded.deinit(self.alloc);
        self.alloc.free(self.owned_bytes);
    }

    /// Invoke a core export by name with raw facade `Value`s (flat-scalar
    /// path; canon-typed component invoke arrives at IT-3).
    pub fn invokeCore(self: *ComponentInstance, name: []const u8, args: []const Value, results: []Value) Instance.InvokeError!void {
        return self.core.invoke(name, args, results);
    }

    /// Invoke a component export through the canonical-ABI **flat trampoline**:
    /// lower each component-level `canon.Value` arg to its single core value,
    /// invoke the core export, and lift the (optional) single result back. B6
    /// IT-2 — flat scalars only (no memory / cabi_realloc; that is IT-3). The
    /// param/result types are supplied by the caller (later derived from the
    /// component's own type section).
    pub fn invokeFlat(
        self: *ComponentInstance,
        name: []const u8,
        args: []const canon.Value,
        arg_types: []const PrimValType,
        result_type: ?PrimValType,
        out: *canon.Value,
    ) InvokeFlatError!void {
        std.debug.assert(args.len == arg_types.len);
        if (args.len > MAX_FLAT_PARAMS) return InvokeFlatError.TooManyParams;

        var argbuf: [MAX_FLAT_PARAMS]Value = undefined;
        for (args, arg_types, 0..) |a, ty, i| {
            const ct = canon.flatCoreType(ty) orelse return InvokeFlatError.NotFlatScalar;
            argbuf[i] = coreToFacade(try canon.lower(a), ct);
        }

        var resbuf: [1]Value = .{.{ .i32 = 0 }};
        const results: []Value = if (result_type != null) resbuf[0..1] else resbuf[0..0];
        try self.core.invoke(name, argbuf[0..args.len], results);

        if (result_type) |rt| {
            out.* = try canon.lift(value_conv.zwasmToRuntime(resbuf[0]), rt);
        }
    }

    /// Build a `canon.CanonContext` over the instance's linear memory + the
    /// guest's `cabi_realloc`. NOTE: the captured `memory` slice is valid only
    /// while the guest does not GROW memory mid-lift/lower; a growing
    /// `cabi_realloc` would dangle it (addressed for the real fixture at IT-3b).
    pub fn canonContext(self: *ComponentInstance) CanonContextError!canon.CanonContext {
        if (self.core.memory() == null) return CanonContextError.NoMemory;
        return .{
            .memory_ctx = @ptrCast(self),
            .memory_fn = fetchCoreMemory,
            .realloc_ctx = @ptrCast(self),
            .realloc_fn = reallocViaGuest,
        };
    }

    /// `CanonContext.memory_fn` — RE-FETCH the core instance's linear memory
    /// on every canon access (a guest `cabi_realloc` may grow/move it
    /// mid-store; a cached slice would dangle).
    fn fetchCoreMemory(ctx: *anyopaque) []u8 {
        const self: *ComponentInstance = @ptrCast(@alignCast(ctx));
        const mem = self.core.memory() orelse return &.{};
        return mem.slice();
    }

    /// Invoke a `func(string) -> string` component export end-to-end through the
    /// canonical ABI (B6 IT-3b-3). `core_func` is the lowered core export; the
    /// string result is too wide to flatten, so the core returns a RETURN-AREA
    /// POINTER to `[out_ptr:i32, out_len:i32]` in guest memory (the canon-lift
    /// convention). `post_return` (if the canon-lift had one) is called for
    /// cleanup. Returns a host-owned copy (allocated from `out_alloc`).
    ///
    /// NOTE (IT-3b shortcut): exports are addressed by their core name; the
    /// general canon-lift→core-func resolution (alias / core-instance decode)
    /// is the follow-up. utf8 string-encoding only.
    pub fn invokeString(
        self: *ComponentInstance,
        core_func: []const u8,
        post_return: ?[]const u8,
        arg: []const u8,
        out_alloc: std.mem.Allocator,
    ) InvokeStringError![]u8 {
        const cx = try self.canonContext();
        const lowered = try canon.lowerString(cx, arg);

        var args = [_]Value{ .{ .i32 = @bitCast(lowered.ptr) }, .{ .i32 = @bitCast(lowered.packed_length) } };
        var results = [_]Value{.{ .i32 = 0 }};
        try self.core.invoke(core_func, &args, &results);
        const ret_ptr: u32 = @bitCast(results[0].i32);

        // Re-fetch memory: a growing cabi_realloc could have moved the backing.
        const cx2 = try self.canonContext();
        const out_ptr = try readU32LE(cx2.mem(), ret_ptr);
        const out_len = try readU32LE(cx2.mem(), ret_ptr + 4);
        // liftString allocates the (possibly transcoded) result directly into
        // out_alloc — an owned host copy, independent of guest memory.
        const owned = try canon.liftString(cx2, out_alloc, out_ptr, out_len);
        errdefer out_alloc.free(owned);

        if (post_return) |pr| {
            var pr_args = [_]Value{.{ .i32 = @bitCast(ret_ptr) }};
            try self.core.invoke(pr, &pr_args, &.{});
        }
        return owned;
    }

    /// Invoke a `func(string) -> string` component export BY ITS COMPONENT NAME
    /// (C2-2, discharges D-304). Resolves the export → its `canon lift` → the
    /// real core funcs (lowered func / realloc / post-return) via the decoded
    /// alias + canon index spaces, then runs `invokeString` — no hard-coded core
    /// names. utf8 string-encoding only.
    pub fn invokeStringExport(self: *ComponentInstance, export_name: []const u8, arg: []const u8, out_alloc: std.mem.Allocator) InvokeStringError![]u8 {
        const r = self.info.resolveLiftedFunc(export_name) orelse return InvokeStringError.ExportNotResolved;
        if (r.string_encoding != .utf8) return InvokeStringError.UnsupportedEncoding;
        if (r.realloc) |rr| self.realloc_name = rr.name;
        const post: ?[]const u8 = if (r.post_return) |p| p.name else null;
        return self.invokeString(r.core_func.name, post, arg, out_alloc);
    }
};

pub const InvokeTypedError = typed.InvokeTypedError;

/// `CanonContext.memory_fn` over a BUILT component: re-fetch the
/// memory-exporting instance's linear memory on every access.
fn builtMemoryFetch(p: *anyopaque) []u8 {
    const ctx: *cwasi.WasiP2Ctx = @ptrCast(@alignCast(p));
    const inst = ctx.mem_instance orelse return &.{};
    const mem = inst.memory() orelse return &.{};
    return mem.slice();
}

/// `CanonContext.realloc_fn` over a BUILT component: nested-invoke the
/// realloc-exporting instance's `cabi_realloc`.
fn builtRealloc(p: *anyopaque, old_ptr: u32, old_size: u32, alignment: u32, new_size: u32) canon.ReallocError!u32 {
    const ctx: *cwasi.WasiP2Ctx = @ptrCast(@alignCast(p));
    const inst = ctx.realloc_instance orelse return canon.ReallocError.AllocFailed;
    var args = [_]Value{
        .{ .i32 = @bitCast(old_ptr) },
        .{ .i32 = @bitCast(old_size) },
        .{ .i32 = @bitCast(alignment) },
        .{ .i32 = @bitCast(new_size) },
    };
    var res = [_]Value{.{ .i32 = 0 }};
    inst.invoke(ctx.realloc_name, &args, &res) catch return canon.ReallocError.AllocFailed;
    const ptr: u32 = @bitCast(res[0].i32);
    if (ptr == 0 and new_size != 0) return canon.ReallocError.AllocFailed;
    return ptr;
}

/// `CanonContext.borrow_rep_fn` over a BUILT component: a borrow handle of
/// a guest-defined resource resolves to its rep in the component's table.
fn builtBorrowRep(p: *anyopaque, ti: u32, handle: u32) canon.BorrowRepError!u32 {
    const ctx: *cwasi.WasiP2Ctx = @ptrCast(@alignCast(p));
    return ctx.guest_resources.rep(ti, handle) catch canon.BorrowRepError.InvalidHandle;
}

/// ADR-0183 F3 — TYPED invoke against a BUILT component (the general
/// ADR-0175 graph incl. WASI wiring): real-toolchain components import
/// wasi, so the single-module `ComponentInstance` path cannot run them.
/// REQ-6 (cw CM-API) — set a diagnostic naming the unresolved export before
/// returning `ExportNotResolved` (shared by both invoke entry points).
fn diagUnresolved(export_name: []const u8) InvokeTypedError {
    diagnostic.setDiag(.execute, .other, .unknown, "typed invoke: export '{s}' does not resolve to a concrete lifted func", .{export_name});
    return InvokeTypedError.ExportNotResolved;
}

/// Same contract as `ComponentInstance.invokeTyped`.
pub fn invokeTypedBuilt(
    built: *cwasi.BuiltComponent,
    export_name: []const u8,
    args: []const ComponentValue,
    out_alloc: std.mem.Allocator,
) InvokeTypedError!?ComponentValue {
    const info = &built.info;
    const ft = info.resolveFuncType(export_name) orelse return diagUnresolved(export_name);
    const r = info.resolveLiftedFunc(export_name) orelse return diagUnresolved(export_name);
    if (r.string_encoding != .utf8) {
        diagnostic.setDiag(.execute, .other, .unknown, "typed invoke '{s}': unsupported string encoding (only utf8)", .{export_name});
        return InvokeTypedError.UnsupportedEncoding;
    }
    if (r.realloc) |rr| built.ctx.realloc_name = rr.name;
    const core_inst = built.guestInstance(r.core_func.instance) orelse return diagUnresolved(export_name);
    // post_return may live on a different guest instance than the lifted
    // func; absent instances skip cleanup (matching the pre-split behavior).
    const pr_inst: ?*Instance = if (r.post_return) |pr| built.guestInstance(pr.instance) else null;
    const cx = canon.CanonContext{
        .memory_ctx = @ptrCast(built.ctx),
        .memory_fn = builtMemoryFetch,
        .realloc_ctx = @ptrCast(built.ctx),
        .realloc_fn = builtRealloc,
        // D-322: borrow params of guest-defined resources lower to the rep.
        .resource_ctx = @ptrCast(built.ctx),
        .borrow_rep_fn = builtBorrowRep,
    };
    return typed.invokeTypedCore(built.alloc, info, cx, core_inst, pr_inst, ft, r, args, out_alloc);
}

pub const InvokeStringError = error{
    OutOfBounds,
    OutOfMemory,
    /// The component export name didn't resolve to a `canon lift` over a core
    /// export (unknown export, or an unresolvable alias form).
    ExportNotResolved,
} || canon.StringError || Instance.InvokeError || CanonContextError;

/// Read a little-endian u32 from a guest-memory slice (bounds-checked).
fn readU32LE(mem: []const u8, off: u32) error{OutOfBounds}!u32 {
    if (@as(usize, off) + 4 > mem.len) return error.OutOfBounds;
    return std.mem.readInt(u32, mem[off..][0..4], .little);
}

pub const InvokeFlatError = error{
    TooManyParams,
    NotFlatScalar,
} || canon.LowerError || canon.LiftError || Instance.InvokeError;

/// The `cabi_realloc` callback (ADR-0171) that runs the guest's own
/// `cabi_realloc` export — so canon lift/lower allocate in the guest's
/// allocator (spec-conformant). `ctx` is the `*ComponentInstance`.
fn reallocViaGuest(ctx: *anyopaque, old_ptr: u32, old_size: u32, alignment: u32, new_size: u32) canon.ReallocError!u32 {
    const self: *ComponentInstance = @ptrCast(@alignCast(ctx));
    var args = [_]Value{
        .{ .i32 = @bitCast(old_ptr) },
        .{ .i32 = @bitCast(old_size) },
        .{ .i32 = @bitCast(alignment) },
        .{ .i32 = @bitCast(new_size) },
    };
    var results = [_]Value{.{ .i32 = 0 }};
    self.core.invoke(self.realloc_name, &args, &results) catch return canon.ReallocError.AllocFailed;
    const ptr: u32 = @bitCast(results[0].i32);
    if (ptr == 0 and new_size != 0) return canon.ReallocError.AllocFailed; // null = OOM
    return ptr;
}

pub const CanonContextError = typed.CanonContextError;

fn firstCoreModule(decoded: *const decode.Component) ?[]const u8 {
    for (decoded.sections.items) |sec| {
        if (sec.id == .core_module) return sec.body;
    }
    return null;
}

// Multi-component graph orchestration (D-305) lives in a sibling module — it
// is a distinct two-level concern (outer component-instance loop × per-child
// core-instance loop + cross-component canon marshalling). Re-exported here so
// the public host surface (`host.instantiateGraph` / `host.ComponentGraph`)
// stays stable.
const component_graph = @import("component_graph.zig");
pub const ComponentGraph = component_graph.ComponentGraph;
pub const instantiateGraph = component_graph.instantiateGraph;

/// Decode a component and instantiate its (first) embedded core module via the
/// `Engine` facade. `engine` must outlive the returned `ComponentInstance`.
/// `opts` carries the per-instance budget (fuel / max-memory); pass `.{}` for
/// the default budget (REQ-4, cw CM-API).
pub fn instantiate(engine: *Engine, alloc: Allocator, bytes: []const u8, opts: InstantiateOpts) Error!ComponentInstance {
    // Own the bytes so the instance is self-contained (REQ-7 / D-326): `decoded`,
    // its `info` names, and the core `module` all borrow from `owned_bytes`.
    const owned_bytes = try alloc.dupe(u8, bytes);
    errdefer alloc.free(owned_bytes);

    var decoded = try decode.decode(alloc, owned_bytes);
    errdefer decoded.deinit(alloc);

    const core_bytes = firstCoreModule(&decoded) orelse return Error.NoCoreModule;

    const module = try alloc.create(Module);
    errdefer alloc.destroy(module);
    module.* = engine.compile(core_bytes) catch return Error.InstantiateFailed;
    errdefer module.deinit();

    const core = try alloc.create(Instance);
    errdefer alloc.destroy(core);
    // Propagate the rich InstantiateError (StartTrapped / MemoryLimitExceeded)
    // so the budget cause reaches the consumer (REQ-4).
    // D-496/D-500 — the component CM-API core runs on INTERP: cross-module/component
    // orchestration is interp's domain (like the Linker, also `.interp`-pinned), and
    // cljw (the consumer) uses interp for components (D-488). The `.auto`→JIT flip
    // would route invokeTyped through the JIT buffer-write thunk, which has a Win64
    // gap for the string-arg shape (`greet(string)` → hasThunk=false → Unsupported;
    // REQ-1/REQ-7 Win64-only). Component-on-JIT is a separate future capability (D-500).
    var core_opts = opts;
    core_opts.engine = .interp;
    core.* = try module.instantiate(core_opts);

    var info = try ctypes.decodeTypeInfo(alloc, &decoded);
    errdefer info.deinit();
    try cvalidate.validate(&info); // ADR-0176: reject invalid components pre-instantiate

    return .{ .alloc = alloc, .owned_bytes = owned_bytes, .decoded = decoded, .info = info, .engine = engine, .module = module, .core = core };
}

// WASI Preview 2 host trampolines + the single-component runner live in a
// sibling module (D-309 extraction — `component.zig` crossed the file-size
// smell cap as the P2 surface grew). Re-exported here so the public `run` path
// (`cli/run.zig` → `component.runWasiP2Main`) and the in-tree e2e/unit tests
// keep the same surface.
/// ADR-0183 — the public component-level value tree (rich typed invoke).
pub const ComponentValue = @import("../feature/component/value.zig").ComponentValue;

/// REQ-3 (cw CM-API) — the public component-level TYPE tree + resolver
/// (specialization-preserving, label-carrying; the type counterpart to
/// `ComponentValue`). `resolveType` / `resolveFuncSig` chase the decoded
/// 2-space rule internally so consumers don't reconstruct a TypeCtx.
pub const wit_type = @import("../feature/component/wit_type.zig");
pub const WitType = wit_type.WitType;
pub const FuncSig = wit_type.FuncSig;

const cwasi = @import("component_wasi_p2.zig");
pub const runWasiP2Main = cwasi.runWasiP2Main;
pub const BuiltComponent = cwasi.BuiltComponent;
pub const buildWasiP2Component = cwasi.buildWasiP2Component;
const WasiP2Ctx = cwasi.WasiP2Ctx;
/// Unified WASI-component runner (D-335 Unit F): builds once, then drives the
/// async (P3 callback-loop) or sync (`wasi:cli/run`) path automatically. Lives
/// in the P2 home (ADR-0193 P3); its async branch is `enable_wasi_p3`-gated.
pub const runWasiMain = cwasi.runWasiMain;

/// WASI Preview 3 / CM-async runner (D-335 unit D-ηB, ADR-0188). ADR-0193 P3:
/// the P3 driver compiles only at `wasi_level >= .p3`; at a p2 build this
/// re-export is absent and `component_wasi_p3.zig` is never imported.
pub const runWasiP3Main = if (@import("build_options").enable_wasi_p3)
    @import("component_wasi_p3.zig").runWasiP3Main
else {
    // absent at wasi_level < .p3 — no external caller reaches it (ADR-0193 P3)
};

// ============================================================
// REQ-1 (cw CM-API) — unified open + handle
// ============================================================

/// REQ-1 — does this component import any `wasi:*` interface? A cheap
/// pre-instantiation predicate (decode + scan the component import names)
/// so a host can inspect a component without attempting instantiation.
pub fn componentNeedsWasi(alloc: Allocator, bytes: []const u8) !bool {
    var decoded = try decode.decode(alloc, bytes);
    defer decoded.deinit(alloc);
    var info = try ctypes.decodeTypeInfo(alloc, &decoded);
    defer info.deinit();
    for (info.imports.items) |imp| {
        if (std.mem.startsWith(u8, imp.name, "wasi:")) return true;
    }
    return false;
}

/// REQ-1 — the unified opened-component handle. `open` auto-selects the
/// single-embedded-module fast path (`ComponentInstance`) or the general
/// WASI-P2 / multi-instance graph (`BuiltComponent`); the consumer drives
/// BOTH through one set of methods (no try-catch fallback, no two-way
/// dispatch). Free with `deinit`.
pub const Opened = union(enum) {
    /// Single embedded core module, no host imports.
    single: ComponentInstance,
    /// General graph (WASI-P2 host wiring and/or multiple core instances).
    wasi: BuiltComponent,

    pub fn deinit(self: *Opened) void {
        switch (self.*) {
            inline else => |*x| x.deinit(),
        }
    }

    /// Borrow this handle's decoded `TypeInfo` (label/name lifetimes).
    pub fn typeInfo(self: *const Opened) *const ctypes.TypeInfo {
        return switch (self.*) {
            inline else => |*x| &x.info,
        };
    }

    /// Introspect the typed func exports (path-qualified interface funcs
    /// included). Free via `ctypes.TypeInfo.freeExportedFuncs`.
    pub fn exportedFuncs(self: *const Opened, alloc: Allocator) Allocator.Error![]ctypes.TypeInfo.ExportedFunc {
        return self.typeInfo().exportedFuncs(alloc);
    }

    /// Resolve a func export's signature to the `WitType` tree (REQ-3).
    pub fn resolveFuncSig(self: *const Opened, arena: Allocator, name: []const u8) wit_type.Error!?FuncSig {
        return wit_type.resolveFuncSig(arena, self.typeInfo(), name);
    }

    /// Typed invoke through the canonical ABI (REQ-2 labels on the result;
    /// REQ-6 diagnostics on failure). Caller frees the result tree.
    pub fn invokeTyped(self: *Opened, name: []const u8, args: []const ComponentValue, out_alloc: Allocator) InvokeTypedError!?ComponentValue {
        return switch (self.*) {
            .single => |*ci| ci.invokeTyped(name, args, out_alloc),
            .wasi => |*bc| invokeTypedBuilt(bc, name, args, out_alloc),
        };
    }

    /// REQ-5 — host-facing drop of a guest-defined resource handle (runs the
    /// declared destructor for an `own` handle). Only the graph path carries
    /// guest resources; a single-module component has none, so a drop on it
    /// is a `NoResourceTable` misuse error.
    pub fn dropResource(self: *Opened, handle: u32) DropResourceError!void {
        return switch (self.*) {
            .single => DropResourceError.NoResourceTable,
            .wasi => |*bc| bc.dropResource(handle),
        };
    }
};

/// REQ-5 — `Opened.dropResource` failure set: the build's drop errors plus
/// the single-module "no resource table" misuse.
pub const DropResourceError = cwasi.DropResourceError || error{NoResourceTable};

/// REQ-1 — open a component into a unified handle, auto-selecting the
/// instantiation path. `host` is wired into the WASI-P2 path and ignored by
/// the single-module path (pass a host regardless — the consumer always has
/// one). `opts` is the per-instance budget (REQ-4). The selection is
/// structural: a component with host imports OR more than one embedded core
/// module needs the general graph builder; otherwise the single-module fast
/// path suffices.
pub fn open(engine: *Engine, alloc: Allocator, bytes: []const u8, host: *wasi_host.Host, opts: InstantiateOpts) anyerror!Opened {
    var decoded = try decode.decode(alloc, bytes);
    var core_count: u32 = 0;
    for (decoded.sections.items) |sec| {
        if (sec.id == .core_module) core_count += 1;
    }
    var info = try ctypes.decodeTypeInfo(alloc, &decoded);
    const needs_general = info.imports.items.len > 0 or core_count != 1;
    info.deinit();
    decoded.deinit(alloc);

    if (needs_general) {
        return .{ .wasi = try buildWasiP2Component(engine, alloc, bytes, host, opts) };
    }
    return .{ .single = try instantiate(engine, alloc, bytes, opts) };
}
