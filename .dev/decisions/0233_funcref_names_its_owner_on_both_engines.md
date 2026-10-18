# 0233 — A funcref names its own instance on both engines: `FuncEntity` carries the owner

- **Status**: Accepted (2026-10-18 — PR #584)
- **Date**: 2026-10-18
- **Author**: Junji Takakura
- **Tags**: api, c-abi, runtime, jit, interp, funcref, cross-module

## Context

`wasm_ref_as_func` builds its `wasm_func_t` as `{Ref.instance, fe.func_idx}`
and falls back to the entity's own instance (`fe.runtime.instance`) only when
the `Ref` carries none (`src/api/extern_new.zig`, `wasm_ref_as_func`). Every
site that mints a `Ref` from a value — `wasm_table_get` (both arms),
`wasm_global_get`, the result marshalling of `wasm_func_call` (interpreter,
JIT single and multi-value) and a host call's arguments (`hostFuncThunk`) —
puts the instance that *handed the value over* there, not the one the
function belongs to. When the two differ, `func_idx` is looked up in the
wrong function space and a different function runs, with no trap (#566).
`test/c_api_conformance/funcref_owner_instance.c` measures 19 such paths
across the four engine pairings; all 19 fail on `ad0e62937`.

Three facts shape the fix.

- **The minting sites hold only the payload.** Six of the seven hold a table
  cell, a global cell or a result value; only `wasm_func_as_ref` knows the
  owner directly. Putting the right instance in the `Ref` means decoding the
  owner from the `FuncEntity` at each site — the resolution `wasm_ref_as_func`
  needs anyway.
- **A JIT `FuncEntity` cannot name its owner.** ADR-0014 §6.K.1 made a funcref
  `*FuncEntity` so that it "carries its own instance identity", and put that
  identity in `runtime: *Runtime`. The JIT has no interpreter `Runtime`; its
  entities are built with `runtime = undefined` (`src/engine/setup.zig`, the
  `func_entities` loop), and the D-496/D-498 comment in `wasm_ref_as_func` is
  why the `Ref`'s carried instance is consulted first. Nor can the `Ref` tell
  the two kinds apart: with A on the JIT and B on the interpreter, a funcref
  B minted read from A's table has a JIT instance in `Ref.instance` and an
  interpreter entity as its payload.
- **`Ref.instance` serves two readers.** `wasm_ref_copy` / `wasm_ref_delete`
  read it to recover the store's allocator; `wasm_ref_as_func` reads it as
  the callee's instance. Only the second is wrong when a funcref crosses.

wasmtime keeps the identity in the reference itself: `VMFuncRef.vmctx` is the
callee's context, and `Table::get` builds the `Func` from the `VMFuncRef`
pointer alone, the table's owner taking no part. An imported function's slot
holds a copy that carries the *exporter's* `vmctx`.

## Decision

**D1 — `FuncEntity` carries its owner on both engines.** A new field
`owner: ?*anyopaque` holds the C-API `Instance`
(`runtime/instance/instance.zig`) the function belongs to, untyped as
`Runtime.instance` is. The
invariant is: **`{owner, func_idx}` denotes this function**, so a
`wasm_func_t` built from the two calls it. On the interpreter `owner` is the
instance of `fe.runtime` — for an import, the source runtime's, matching the
`{source_runtime, source_funcidx}` the entity already holds. On the JIT the
`api/` layer passes the instance in; an import's entity takes the
`{instance, func_idx}` of the function its extern resolves to — the
**defining** one, through a re-export chain as ADR-0228 resolves it — as the
interpreter's does and as wasmtime's copied `VMFuncRef` does. A JIT
`call_indirect` reads the entity's `funcptr` / `typeidx` mirrors, never its
`func_idx`, so rewriting an import's `func_idx` changes no JIT dispatch.
`owner` is set before any guest code runs, the start function included. `runtime` keeps its meaning and its consumers (`interp/mvp.zig`);
the JIT's `LDR` offsets are comptime-derived (`funcentity_*_offset`) and
follow the layout change.

**D2 — `wasm_ref_as_func` resolves from the entity alone.** It reads
`fe.owner` and `fe.func_idx`; `Ref.instance` is no longer consulted for the
callee. The minting sites stay as they are.

**D3 — a deleted JIT instance's `Instance` is parked** with its `JitInstance`
until `wasm_store_delete`, as the interpreter's already is (#539, #555), so
`owner` never dangles.

## Open questions

1. **A host function's import has no defining instance.** A funcref to an
   import bound to a `wasm_func_new` callback resolves, on both engines, to
   an index `wasm_func_call` does not run (interpreter `UNREACHABLE`, JIT
   `UNSUPPORTED`). wasmtime's host `VMFuncRef` carries the host context
   instead. Proposed: out of this ADR; its own issue decides whether the
   entity names the host `Func`.

## Alternatives considered

### Alternative A — find the owner by scanning the store

- **Sketch**: keep `FuncEntity` as is; `wasm_ref_as_func` walks
  `Store.live_instances` and the two zombie lists for the instance whose
  `func_entities` contains the pointer, then reads `fe.runtime` or the slot
  index by that instance's engine.
- **Why rejected**: O(instances) per resolution, and the walk must know
  every list that holds an instance. A deleted JIT instance's `Instance` is
  freed, so its funcref resolves to null — the opposite of what #555 decided
  for the interpreter.

### Alternative B — mint the right instance at each site

- **Sketch**: each of the six sites above decodes the payload's owner and
  stores it in `Ref.instance`.
- **Why rejected**: the decoding is the same JIT-blind lookup at six sites,
  and a seventh site would have to copy it again. It also keeps
  `Ref.instance` carrying both meanings.

### Alternative C — an engine-tagged context in place of `runtime`

- **Sketch**: replace `runtime` with a tagged pointer — the interpreter's
  `*Runtime` or the JIT's `*JitRuntime` — the closest copy of `vmctx`.
- **Why rejected here**: every `fe.runtime` consumer in `interp/mvp.zig`
  changes, and the C API still needs the `Instance`, which `JitRuntime` has
  no pointer to. Left to #536 (below) if JIT code needs the callee's state.

### Alternative D — a JIT import's owner is the importer

- **Sketch**: keep the JIT import entity as the importer's own slot
  (`func_idx` = the import index) and teach `wasm_func_call` on the JIT to
  call an import index, which `JitInstance.invokeIdx` refuses today.
- **Why rejected**: two meanings of "the function at `func_idx`" — the
  defining one on the interpreter, the importer's slot on the JIT — where
  the interpreter, wasmtime and ADR-0228's bridge all name the definer.

## Consequences

- **Positive**: one resolution site; the 19 paths of
  `funcref_owner_instance.c` resolve to the owner. D3 also removes the read
  of freed memory when a funcref outlives its JIT instance.
- **Negative**: `FuncEntity` grows by a pointer; a deleted JIT instance's
  `Instance` stays allocated until the store goes.
- **Neutral / follow-ups**:
  - #536 (JIT `call_indirect` runs a foreign funcref on the caller's state)
    can find the callee instance through `owner`. JIT machine code cannot
    dereference the C-API `Instance`, so #536 reaches it through a callout
    or adds the context of Alternative C; that is #536's decision.
  - The interpreter's `call_indirect` on a JIT-owned funcref reads
    `fe.runtime` (`undefined`) and dies with a fatal signal. `owner` makes
    the case detectable from `api/`, not from `interp/`; its issue decides
    between a clean trap and a cross-engine call.
  - A host `wasm_table_set` into a JIT table zeroes the funcptr mirror
    (`JitInstance.tableSetRef`), so `call_indirect` on the slot traps even
    for the instance's own funcref. `owner` tells `tableSetRef` when the
    entity's `funcptr` / `typeidx` belong to this instance; the mirror fix is
    separate.
  - `Ref.instance` is left with the allocator-recovery reader only.

## References

- Related ADRs: 0014 §6.K.1 (funcref = `*FuncEntity`), §6.K.2 sub-change 4
  (zombie keep-alive); 0068 (dual-view table, `funcentity_*_offset`); 0200
  (C-API JIT arm); 0228 (a re-exported import resolves to the defining
  module)
- Debt: D-496 (JIT `FuncEntity.runtime = undefined`); D-498 (release notes
  v2.0.0-alpha.3)
- Issues: #566, #555, #539, #536
- Test: `test/c_api_conformance/funcref_owner_instance.c`
- External (wasmtime 48.0.5, crates.io sources):
  `wasmtime-environ/src/vmtypes.rs:105-140` (`VMFuncRef`, `vmctx` at :139);
  `wasmtime/src/runtime/externals/table.rs:202-214` (`Table::get`);
  `wasmtime/src/runtime/func.rs:552-562` (`Func::from_vm_func_ref`);
  `wasmtime/src/runtime/vm/instance.rs:853-869` (`get_func_ref`: an import
  returns its slot's copy) and `:984` (a defined func's `vmctx`);
  `wasmtime/src/runtime/func.rs:1215-1244` (`Func::vmimport` copies the
  exporter's `VMFuncRef`)
