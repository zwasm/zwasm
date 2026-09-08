# 0228 — The cross-module bridge knows the callee's signature and enters the defining module

- **Status**: Proposed
- **Date**: 2026-09-08
- **Author**: Junji Takakura
- **Tags**: jit, cross-module, abi

## Context

A JIT-backed importer reaches a func exported by another JIT-backed instance
through a bridge thunk (ADR-0066, D-225): setup emits one per resolved func
import into a per-instance arena and plants it in `dispatch[N]`. The thunk
swaps the runtime pointer for the callee's and CALLs the callee's entry. It
was built from `FuncImportTarget = { callee_rt, callee_entry }` and nothing
else.

Three defects share that contract:

- **#388** — `exportedFuncTarget` answered null for any export whose func
  index was an import, so a chain A→B→C (B re-exports A's func) could not
  link. `initLinked` was handed the resolved targets and threw them away.
- **#390** — the thunk is signature-agnostic and the ABI is not. An argument
  that overflows the register set is written by the importer relative to its
  own stack and read by the callee relative to its own frame, with the thunk's
  frame between them; a MEMORY-class result (`results.len > 2`) loses its
  hidden buffer pointer because the caller's `emitImportDispatch` puts the
  runtime where the pointer belongs. #391 fenced both shapes off in
  `bridgeCanCarry` by copying the call site's marshalling budget — a second
  copy of a rule that already had one.
- **#413** — the arm64 thunk saves six of the seven registers
  `abi.reserved_invariant_gprs` names, hand-written; X23 (`globals_base`) is
  the one it skips.

An alternative surfaced in review (2026-09-07): drop the thunk and emit a
direct CALL to the callee's entry at every import call site. It fails on
funcref identity. An import's `funcptr` — what `ref.func`, table elements and
`call_ref` see — is `dispatch[fidx]` (`setup.zig`, `compile_init.zig`), i.e.
the thunk's address. `call_indirect` and `call_ref` do not hold an import
index statically and cannot be inlined, so whatever sits at that address must
carry every signature. A direct CALL for the static `call` route would be an
optimisation layered on a correct thunk, not a replacement for one.

## Decision

1. **`FuncImportTarget` carries the callee's signature.** The exporter fills
   `sig` from its own `func_sigs`. The thunk is emitted for that signature:
   it copies the importer's overflow arguments into its own outgoing area
   and, for a MEMORY-class result, keeps the hidden pointer in entry-arg0 and
   moves the runtime to arg1 (arm64: X0 stays, X8 is untouched). Overflow
   sizes come from the call site's own rule (`computeCallOverflowBytesCc` on
   x86_64, `computeCallOverflowBytes` on arm64), not from a copy. Static
   `call` and the table / funcref routes go through the same thunk. The
   thunk stays **fixed-size**: the copy is a pointer-walk loop and every
   per-signature difference is an immediate or a same-length register
   number, so the arena stays slot-indexed (`thunkSlot`) and no offset table
   is needed. Measured: 126 bytes on x86_64 (was 79) and 168 on arm64 (was
   120); an unrolled copy at the 128-argument cap would be ~15× that.
2. **Resolution folds at link time.** `JitInstance` keeps the targets it was
   linked with (`import_targets`). `exportedFuncTarget` on an import index
   returns that entry, so C's thunk names A directly; nothing is walked at
   call time. Unresolved imports (WASI, embedder host funcs) stay null.
3. **Retention is stated, not counted.** The target names the defining
   instance's runtime, arena and module bytes, and nothing counts the takers.
   The defining instance must outlive every importer that took a target from
   it, transitively. The C API keeps this today by parking every JIT instance
   until `wasm_store_delete` (`parkJitAsZombie`) and deferring a borrowed
   module's bytes (`Module.jit_borrowers`); other callers keep it by hand.
   `cross_module_reexport.c` deletes A and B before calling C.
4. **The arm64 save block is derived from `abi.reserved_invariant_gprs`**, so
   #413 cannot recur by omission.
5. **Land in two PRs.** The first carries (2) and (3) and does not touch
   codegen. The second carries (1) and (4), retires or narrows the #391 fence
   to whatever the new thunk still cannot carry, and moves this ADR to
   Accepted.

## Alternatives considered

### Alternative A — direct CALL at the import call site, no thunk

- **Sketch**: `emitImportDispatch` emits `CALL callee_entry` with the runtime
  swap inline; no arena.
- **Why rejected**: funcref identity (Context). The thunk address is what a
  funcref to an import IS; the indirect routes cannot be inlined.

### Alternative B — walk the chain at call time

- **Sketch**: B's thunk forwards to A's thunk.
- **Why rejected**: one extra frame per hop for nothing; the callee-side
  overflow read assumes the caller that wrote the arguments is the frame
  directly above, so each hop would need its own copy step.

### Alternative C — refcount the defining instance

- **Sketch**: each taken target increments a count on the exporter; free at
  zero.
- **Why rejected**: the C API already never frees a JIT instance before its
  store, so a count would guard nothing today; it would be a second retention
  mechanism to keep consistent with the first.

## Consequences

- **Positive**: three-module chains link; overflow arguments and MEMORY-class
  results cross the bridge; the #391 budget copy goes away with the fence.
- **Negative**: the thunk grows (x86_64 79 → 126, arm64 120 → 168 bytes) and
  spends a short loop per call on the copy; `FuncImportTarget.sig` borrows
  the exporter's compile arena, which the retention statement already
  requires to be alive.
- **Neutral / follow-ups**: the interpreter's binder has the same missing fold
  for a re-exported import (its thunk runs the re-exporter's `unreachable`
  placeholder) — tracked separately. A cross-module throw through the bridge
  faults unless the caller registered its instances with `eh_registry`, which
  `initLinked` never does — tracked separately. `fromCompiled` (`.cwasm`)
  still links no cross-module imports. A v128 parameter is still declined
  (SysV's overflow rule excludes it).

## References

- Issues: zwasm/zwasm#388, zwasm/zwasm#390, zwasm/zwasm#413; fence
  zwasm/zwasm#391; runtime swap zwasm/zwasm#385
- Related ADRs: ADR-0066 (bridge thunk), ADR-0185 / D-238 (frame link kept
  in the thunk), ADR-0200 (JIT-backed C API instances)
- Files: `src/engine/setup.zig`, `src/engine/runner.zig`,
  `src/engine/codegen/shared/thunk.zig`, `src/engine/codegen/{x86_64,arm64}/thunk.zig`,
  `src/api/instance.zig`; tests `src/engine/runner_test.zig`,
  `test/c_api_conformance/cross_module_reexport.c`
