//! WASM Spec §4.2.5 "Module Instance" — runtime-side instantiated
//! module data shape.
//!
//! Per ADR-0023 §3 reference table + §7 item 5: extracted from
//! `c_api/instance.zig`. The wasm-c-api binding handle for
//! `wasm_module_t` is forward-declared here as `?*const anyopaque`
//! because the binding-side struct is owned by `api/wasm.zig`
//! (post-ADR-0023 §7 item 11) and including its concrete type
//! would require this Zone 1 file to import Zone 3 — a P-A
//! violation. The C-API binding casts back to its concrete shape
//! at the boundary.
//!
//! Per-instance type granularity (memory / table / global / func /
//! element / data) lands in §7 item 6's sibling files; for now
//! those concepts live as inline slices on Instance.
//!
//! Zone 1 (`src/runtime/`).

const std = @import("std");

const runtime_mod = @import("../runtime.zig");
const store_mod = @import("../store.zig");
const sections = @import("../../parse/sections.zig");
const zir = @import("../../ir/zir.zig");

const Store = store_mod.Store;
const Runtime = runtime_mod.Runtime;

/// `wasm_instance_t` — instantiated module. Owns one
/// `runtime.Runtime` plus a per-instance arena that backs every
/// derived state slice (types, lowered `ZirFunc`s, the func-
/// pointer table seen by `Runtime.funcs`). C only ever sees a
/// pointer to this struct (the upstream wasm.h declares
/// `wasm_instance_t` as opaque), so it does not need an extern
/// layout — using a regular Zig `struct` lets us hold proper
/// slices without packing them as `[*]T + len` pairs.
///
/// §9.3 / 3.5 wired the lifetime; §9.3 / 3.6 (chunk a) wires
/// instantiation — at `wasm_instance_new` time the Module bytes
/// are decoded + lowered into `Runtime.funcs` /
/// `Runtime.module_types`. `Runtime.memory` / `.tables` /
/// `.datas` / `.elems` follow when 3.6's call surface needs them.
pub const Instance = struct {
    store: ?*Store,
    /// Back-pointer to the binding-side wasm_module_t handle
    /// (`c_api/instance.zig:Module`, post-§7 item 11
    /// `api/wasm.zig`). Held as `?*const anyopaque` so this
    /// Zone 1 file does not import the Zone 3 binding layer; the
    /// C-API binding casts at the boundary.
    module: ?*const anyopaque,
    runtime: ?*Runtime,
    /// ADR-0200 — JIT-backed engine handle (`engine/runner.zig::JitInstance`),
    /// the per-instance alternative to the interp `runtime`. Exactly one of
    /// `runtime` / `jit` is non-null (the engine fork chosen at instantiate).
    /// Held as `?*anyopaque` because this Zone-1 file MUST NOT import Zone-2
    /// `engine/`; the Zone-3 api / native facade casts at the boundary
    /// (mirrors `module: ?*const anyopaque`). NOT a reuse of `runtime`
    /// (single_slot_dual_meaning): each carries distinct engine state.
    jit: ?*anyopaque = null,
    /// Per-instance arena holding every derived-state slice. A
    /// single `arena.deinit()` releases types, lowered ZirFunc
    /// state, the func-pointer table — uniformly. Owned (heap-
    /// allocated) so its identity survives moves of the Instance
    /// struct itself.
    arena: ?*std.heap.ArenaAllocator = null,
    funcs_storage: []zir.ZirFunc = &.{},
    func_ptrs_storage: []*const zir.ZirFunc = &.{},
    /// Decoded export-section entries (arena-backed). Used by
    /// `wasm_instance_exports` to surface the upstream-standard
    /// discovery path.
    exports_storage: []sections.Export = &.{},
    /// Parallel to `exports_storage` — `export_types[i]` is the
    /// structural type of `exports_storage[i]`. Populated during
    /// `instantiateRuntime` so cross-module imports can validate
    /// import-vs-export type matching at the c_api boundary
    /// (Wasm 2.0 §3.4.10). See `ExportType` below + the
    /// validation site at the import-resolution loop. Discharges
    /// debt D-006 (the "linking-errors-pass-for-the-wrong-reason"
    /// gap exposed by the auto-register spike).
    export_types: []ExportType = &.{},
    /// EH cross-module tag exports (10.E-xmodule-tags, ADR-0114).
    /// Tag exports (export-kind 0x04) are filtered out of
    /// `exports_storage` because the c_api `ExternKind` has no tag
    /// variant (`sections.zig` decodeExports). This parallel side-
    /// table records them (name → tag index) so a cross-module tag
    /// import can resolve via `Linker.defineCrossModuleTag` without
    /// polluting the c_api export-discovery path. Arena-backed.
    tag_exports: []TagExport = &.{},
    /// 10.G op_gc cycle 21 (ADR-0116 §3a impl) — per-Instance
    /// GC type metadata materialised from `Module.types`
    /// (parser side-tables per ADR-0121 D2). Populated iff
    /// `Module.needs_gc_heap` was true at parse-time. The
    /// underlying `entries / struct_infos / array_infos` slices
    /// live in the Instance `arena` so single `arena.deinit()`
    /// releases them. Resolver for runtime struct.new / array.new
    /// reads `struct_infos[typeidx].?` / `array_infos[typeidx].?`.
    gc_type_infos: ?@import("../../feature/gc/type_info.zig").GcTypeInfos = null,
    /// ADR-0127 PHASE C — the exporter module's full decoded type section,
    /// retained (arena-backed) so a cross-module func import can compare
    /// type-DEFINITIONS canonically across the two modules' `Types`
    /// (`sections.canonicalEqualCross` / `superReachesCross`). `ExportFuncType`
    /// only flattens the sig + finality; the supertype chain + nested concrete
    /// refs need the whole `Types`. Null when the module has no type section.
    export_src_types: ?sections.Types = null,
    /// C-API host_info slot (wasm.h `WASM_DECLARE_REF_BASE`): an opaque pointer
    /// + finalizer the Zone-3 binding attaches via `wasm_instance_set_host_info`;
    /// the runtime never reads it (fired in `wasm_instance_delete`, Zone 3).
    /// Lives on this runtime struct because the C-API uses it directly (no
    /// Zone-3 Instance wrapper); both field types are builtin pointers, so this
    /// stays import-free — no Zone-1→Zone-3 dependency.
    host_info: ?*anyopaque = null,
    host_info_finalizer: ?*const fn (?*anyopaque) callconv(.c) void = null,
    /// C-API `wasm_instance_as_ref` cached view (ADR-0158). Typed `?*anyopaque`
    /// (not `?*Ref`) because `Ref` is a Zone-3 type — a `?*Ref` field here would
    /// be a Zone-1→Zone-3 upward import. The Zone-3 binding casts it; freed
    /// (cast to `*Ref`) in `wasm_instance_delete`.
    ref_view: ?*anyopaque = null,
};

/// Structural type of an exported entity. Mirrors the four
/// `ImportPayload` variants in `parse/sections.zig` but with
/// `func` resolving the typeidx to a concrete `FuncType` so the
/// importer-vs-exporter comparison is direct.
/// Exported func type + its type-definition FINALITY (`sub final` /
/// bare comptype = true; `sub` open = false). Captured at
/// `buildExportTypes` time because the parse-time `Types` (which holds
/// `finals`) is freed after instantiate; cross-module import linking
/// needs it to reject a FINAL import resolving against an open exported
/// type (D-202 PHASE B).
pub const ExportFuncType = struct {
    sig: zir.FuncType,
    final: bool,
    /// The exporter func's type index into `Instance.export_src_types`
    /// (ADR-0127 PHASE C — cross-module type-def identity check).
    typeidx: u32 = 0,
};

pub const ExportType = union(sections.ImportKind) {
    func: ExportFuncType,
    table: struct { elem_type: zir.ValType, min: u32, max: ?u32 },
    memory: struct { idx_type: sections.MemoryEntry.IdxType = .i32, min: u64, max: ?u64 },
    global: struct { valtype: zir.ValType, mutable: bool },
    // EH tag export type (10.E-xmodule-tags): the tag's func-type
    // signature (param types; tags have no results). Used by cross-
    // module tag import-vs-export matching (step 2+).
    tag: zir.FuncType,
};

/// One EH tag export (10.E-xmodule-tags). `tag_index` is the tag's
/// index in the exporting module's tag space (imports ++ defined);
/// for the spec EH source (try_table.0, no tag imports) this equals
/// the defined-tag index, so it indexes `Runtime.tag_param_counts`.
pub const TagExport = struct {
    name: []const u8,
    tag_index: u32,
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const type_info_mod = @import("../../feature/gc/type_info.zig");

test "Instance: gc_type_infos defaults to null (10.G op_gc cycle 21; ADR-0116 §3a)" {
    const inst: Instance = .{
        .store = null,
        .module = null,
        .runtime = null,
    };
    try testing.expectEqual(@as(?type_info_mod.GcTypeInfos, null), inst.gc_type_infos);
}

test "Instance: gc_type_infos round-trips a single-struct module shape (10.G op_gc cycle 21)" {
    // Build the parser-side Types directly (no full instantiate path),
    // materialise, and assert the GcTypeInfos surface is correct.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // struct { i32 var } as a single typedef.
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    var types = try sections.decodeTypes(testing.allocator, &body);
    defer types.deinit();

    const gti = try type_info_mod.materialiseGcTypes(a, types);

    // Mirror the cycle-21 instantiate wire: stash into Instance field.
    var inst: Instance = .{ .store = null, .module = null, .runtime = null };
    inst.gc_type_infos = gti;

    try testing.expect(inst.gc_type_infos != null);
    const stashed = inst.gc_type_infos.?;
    try testing.expectEqual(@as(usize, 1), stashed.entries.len);
    try testing.expectEqual(type_info_mod.TypeKind.struct_, stashed.entries[0].kind);
    try testing.expect(stashed.struct_infos[0] != null);
    try testing.expectEqual(@as(u32, 8), stashed.struct_infos[0].?.payload_size);
}
