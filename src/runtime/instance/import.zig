//! Zone-1 native import binding — runtime-side view of a single
//! `(import "module" "name" <kind>)` resolution at instantiation
//! time.
//!
//! Per ADR-0023 §7 item 5 (Step A2): replaces the previous
//! `?[*]const ?*const api.Extern` instantiation argument so
//! `runtime/instance/instantiate.zig` is free of Zone-3
//! binding-handle dependencies. The C-API binding pre-resolves
//! every import (cross-module Extern lookup, WASI thunk lookup,
//! CallCtx allocation, source-signature retrieval) and hands a
//! `[]const ImportBinding` to `instantiate.instantiateRuntime`.
//!
//! Each variant carries:
//!   - the **wiring data** the runtime needs (HostCall slot value,
//!     source TableInstance value, source memory slice, source
//!     global slot pointer),
//!   - both the **source's actual descriptor** AND the
//!     **importer's expected descriptor** so the runtime-side
//!     `checkImportTypeMatches` is a pure data compare with no
//!     re-decoding of the source binary.
//!
//! Zone 1 (`src/runtime/`).

const runtime_mod = @import("../runtime.zig");
const zir = @import("../../ir/zir.zig");
const sections = @import("../../parse/sections.zig");

const Runtime = runtime_mod.Runtime;
const Value = runtime_mod.Value;
const HostCall = runtime_mod.HostCall;
const TableInstance = runtime_mod.TableInstance;

/// One pre-resolved import. Order in the slice matches the
/// `(import ...)` declaration order in the importer's binary.
pub const ImportBinding = union(enum) {
    func: FuncImport,
    table: TableImport,
    memory: MemoryImport,
    global: GlobalImport,
    tag: TagImport,
};

/// Function import. The `host_call` slot is pre-built by the
/// binding (cross-module thunk + CallCtx for non-WASI; WASI
/// thunk + `*wasi.Host` ctx for WASI). `source` describes how
/// the FuncEntity slot should be populated:
///
/// - `cross_module`: the FuncEntity slot points at the source
///   runtime's func_idx, so funcref dispatch through this cell
///   reaches the source body via FuncEntity.runtime. The
///   `source_signature` is compared against the importer's
///   declared typeidx during the runtime-side type-match check.
/// - `wasi`: WASI is called by funcidx, never by ref; the
///   FuncEntity slot stays with the importer's local placeholder.
///   No signature compare (the binding-side guarantees the
///   thunk lookup matched the import name).
pub const FuncImport = struct {
    host_call: HostCall,
    source: union(enum) {
        cross_module: struct {
            source_runtime: *Runtime,
            source_funcidx: u32,
            source_signature: zir.FuncType,
            /// #387 — the exporter's own decoded type section and the func's
            /// index into it, so `checkImportTypeMatches` compares the two
            /// type DEFINITIONS across both type spaces
            /// (`sections.canonicalEqualCross` / `superReachesCross`) instead
            /// of reading `source_signature`'s concrete indices in the
            /// importer's space. Null when the exporter retained none; the
            /// check then falls back to the same-space structural compare
            /// plus the finality rule. Read at instantiation only, while the
            /// exporter's handle is alive (the binder took it from the extern
            /// the embedder passed); nothing dereferences it afterwards.
            source_types: ?*const sections.Types = null,
            source_typeidx: u32 = 0,
            /// The exporter type-def's finality, for the fallback arm.
            source_final: bool = true,
        },
        wasi: void,
    },
};

/// Table import. The `instance` field is a value-copy of the
/// source `TableInstance` (refs slice is aliased — both modules
/// see/mutate the same cells per ADR-0014 §6.K.3). The trailing
/// fields carry the source's descriptor for the runtime-side
/// type-match check; the importer's expected descriptor comes
/// from its own `(import ... (table ...))` decoding.
pub const TableImport = struct {
    instance: TableInstance,
    source_elem_type: zir.ValType,
    source_min: u32,
    source_max: ?u32,
    /// #449 — the `wasm_table_new` instance `instance` was copied from, null
    /// for a cross-module import. Carried so the commit point in
    /// `instantiateInternal` can mark the source once, and only if, the
    /// instantiation gets that far.
    host_source: ?*TableInstance = null,
};

/// Memory import. `inst` POINTS AT the source instance's live
/// `*MemoryInstance` (D-199) — the importer adopts the same pointer
/// into `rt.memories`, so `memory.grow` (which reallocs the shared
/// instance's `bytes`) is visible to every importer. The source's
/// arena keeps the instance alive across importer teardown (ADR-0014
/// §2.2 / §6.K.2 zombie-park). `idx_type`/page bounds come WITH the
/// shared instance (no copy needed).
pub const MemoryImport = struct {
    inst: *runtime_mod.MemoryInstance,
};

/// Global import. The `slot` points at the source runtime's
/// `globals[idx]` cell (per ADR-0014 §6.K.3 the importer's
/// `Runtime.globals: []*Value` aliases the source slot).
pub const GlobalImport = struct {
    slot: *Value,
    source_valtype: zir.ValType,
    source_mutable: bool,
};

/// EH tag import (10.E-xmodule-tags). Cross-module tag binding per
/// ADR-0114. v0.1 instantiate-resolution carries the source runtime
/// + the source tag index so the import RESOLVES (no UnknownImport);
/// the import-vs-export type match compares param COUNT
/// (`source_runtime.tag_param_counts[source_tag_index]`). Full
/// `*TagInstance` pointer-identity (throw/catch matching) is the
/// execution-stage step — not wired here.
pub const TagImport = struct {
    source_runtime: *Runtime,
    source_tag_index: u32,
};
