//! Per-runtime function handle — instance-bearing funcref
//! representation per ADR-0014 §6.K.1.
//!
//! Per ADR-0023 §3 reference table + §7 item 6: extracted from
//! `runtime/value.zig`'s prior `FuncEntity` location. The funcref
//! Value still encodes `@intFromPtr(*const FuncEntity)`; this
//! file just gives the type its canonical home alongside the
//! other instance-side runtime types.
//!
//! Zone 1 (`src/runtime/`).

const runtime_mod = @import("../runtime.zig");

/// Per-runtime function handle. One entry per index in
/// `Runtime.funcs`; allocated in `instantiateRuntime`. A funcref
/// `Value` stores `@intFromPtr(*const FuncEntity)` so dereference
/// reveals which Runtime owns the callee body — the encoding
/// 6.K.3 needs to drop the cross-module-import error returns.
///
/// Per ADR-0014 §6.K.1 the funcref carries its own identity, and per
/// ADR-0233 that identity is `{owner, func_idx}` on both engines: the
/// function a funcref denotes is found from the entity alone, never
/// from whichever instance handed the value over.
pub const FuncEntity = struct {
    /// Interpreter only: the Runtime whose `funcs[func_idx]` (and
    /// `host_calls[func_idx]` when imported) describes the callee
    /// body. `undefined` on the JIT, which has no interpreter Runtime.
    runtime: *runtime_mod.Runtime,
    /// The defining function's index in `owner`'s function space (in
    /// `runtime.funcs` on the interpreter).
    func_idx: u32,
    /// The C-API `Instance` (`instance.zig`) that defines this
    /// function, held untyped as `Runtime.instance` is (ADR-0233 D1).
    /// For an import it is the definer's, except a host function's
    /// import, which keeps the importer and its import index. Null
    /// only in a unit test that builds a Runtime without going
    /// through `api/`.
    owner: ?*anyopaque = null,
    /// TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    /// Canonical typeidx of this function's signature. JIT
    /// `emitTableSet` / `emitTableFill` / `emitTableInit` mirror
    /// this into the parallel `typeidx_base` view so post-mutation
    /// `call_indirect` sig-check sees the correct type. Equals
    /// `canonical_type.canonicalTypeidx(types, func_typeidxs[i])`.
    typeidx: u32,
    /// TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    /// Native code entry point for this function. JIT
    /// `emitTableSet` reads this via
    /// `LDR Xfp, [Xref, #funcentity_funcptr_offset]` to mirror the
    /// funcref input into the dual-view funcptr storage (per
    /// ADR-0068 §A1). Locals:
    /// `@intFromPtr(compiled.module.block.bytes.ptr + func_offsets[i])`;
    /// imports: `dispatch[i]`; `0` for interp-only / unresolved.
    funcptr: usize,
    /// RAW declared typeidx of this function's signature (the type-section
    /// index, NOT canonicalized like `typeidx`). Needed by
    /// `ref.test`/`ref.cast` on a funcref (ADR-0126): the RTT match walks
    /// this index's supertype chain + canonical id, which the
    /// `funcTypeEql`-canonicalized `typeidx` would have collapsed (bare
    /// funcs all map to the first bare func, losing the subtype identity).
    /// 0 when unknown (e.g. cross-module funcref — source-space index not
    /// resolved into the importer's type space; that RTT case is rarer).
    raw_typeidx: u32 = 0,
};

/// TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
/// Byte offsets for the JIT mirror code's `LDR` from FuncEntity.
/// Comptime-derived so layout changes propagate without re-coding.
pub const funcentity_typeidx_offset: u32 = @offsetOf(FuncEntity, "typeidx");
pub const funcentity_funcptr_offset: u32 = @offsetOf(FuncEntity, "funcptr");
