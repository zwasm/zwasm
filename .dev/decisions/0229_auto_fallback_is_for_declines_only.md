# 0229 — `.auto` falls back on a capability decline; a validity verdict is final

- **Status**: Accepted (2026-09-10 — sign-off on PR #429, the maintainer of
  record's own per #407; D1–D4 as written)
- **Date**: 2026-09-08
- **Author**: Junji Takakura
- **Tags**: engine, jit, api, validation

## Context

ADR-0200 D3 fixed the fallback posture: `auto` = "JIT if this arch has a
backend, else interp". D-496 then made the fallback per module: `.auto` tries
the JIT and, on any `null`, instantiates the interpreter (`api/instance.zig`,
`instantiateInternal`). `instantiateJit` produced that `null` from one
`catch` over `initLinked`, so two different things wore the same shape:

- a **capability decline** — an import the JIT cannot satisfy, a body it
  cannot compile, a const expression it cannot evaluate at setup;
- a **validity verdict** — a spec rule `compile.zig` checks that the front-end
  validator does not check yet (#285's remainder: exports, start, imported
  entity types, elem items).

#233 measured the consequence: `(module (func $s (param i32)) (start $s))`
and a module with two exports named `a` are refused by `--engine jit` and
`zwasm compile` and run to exit 0 by the default `zwasm run`, because the
interpreter never re-judges what the JIT judged. #397 was the same seam from
the other side: a JIT-only check rejecting a *valid* module, hidden by the
fallback. Every future JIT-only check re-creates the seam unless the boundary
can tell the two apart.

## Decision

1. **`.auto` retries the interpreter only on a decline.** A validity verdict
   is final on `.auto` and `.jit` alike: `NULL` with a
   `ZWASM_TRAP_INVALID_MODULE` (19) trap whose message names the verdict
   (`invalid module: <error name>`). A decline stays what it was: a bare
   `NULL` on `.jit`, the interpreter on `.auto`. `instantiateJit` says which
   by a tag (`Declined` / `Final`), the second axis a lone `null` could not
   carry (`single_slot_dual_meaning`); the trap names the reason when it can
   be allocated, and a `Final` outcome does not depend on that allocation.
2. **The classification is a table, closed by a test.** `jit_verdict_names`
   and `jit_decline_names` in `api/instance.zig` name every member of
   `runner.Error`, each with the spec section (verdicts) or the capability it
   stands for (declines); a unit test walks `@typeInfo(runner.Error)` and
   fails on any name in neither or both. A new JIT-side check cannot land
   without saying which it is.
3. **The CLI starts every path from the same verdict.** `zwasm compile` and
   `zwasm run --engine=jit` run `frontendValidate` before the JIT, as the
   `.wasm` default already did through `wasm_module_new`; the verdict trap is
   printed by `zwasm run` as the instantiation's reason. `run`, `run
   --engine=jit` and `compile` refuse the same module with the same reason.
4. **The remaining asymmetry is #285's.** The two probe modules are still
   accepted by `wasm_module_new` and `wasm_module_validate`; when #285 moves
   those rules into the validator, the JIT's verdict on them becomes
   unreachable and the tests here pick other modules or retire.

## Alternatives considered

### Alternative A — run every JIT-only check in the validator now

- **Sketch**: port `compile.zig`'s module-level checks to `frontendValidate`
  and delete them from the JIT.
- **Why rejected**: that is #285, and it is the right end state; it does not
  make the boundary honest for the next JIT-only check, which is what recurs.

### Alternative B — validate once in the C API before both engines (only)

- **Sketch**: chaploud's (a). `wasm_module_new` already does this; the CLI's
  `compile` and `--engine=jit` did not.
- **Why rejected as sufficient**: taken for the CLI (Decision 3), but it does
  not reach the checks the validator lacks, so it cannot close #233 alone.

### Alternative C — treat every JIT rejection as final

- **Sketch**: `.auto` never retries.
- **Why rejected**: it turns every capability gap into a refusal of a valid
  module, the opposite of ADR-0200 D3's portability aim.

## Consequences

- **Positive**: the default engine no longer runs a module the JIT judged
  invalid; an embedder gets a reason for `NULL` on this path (Refs #353);
  `compile`, `run` and the C API agree.
- **Negative**: one more C-ABI trap kind (append-only, 19); a module a
  JIT-only check wrongly rejects is now refused on `.auto` rather than hidden
  — #397's shape becomes visible instead of silent, which is the point.
- **Neutral / follow-ups**: #285 closes the asymmetry at its root; the AOT
  producer's own declines (`UnsupportedGlobalInit`) are unaffected.

## References

- Issues: zwasm/zwasm#233, zwasm/zwasm#397, zwasm/zwasm#285, zwasm/zwasm#353
- Related ADRs: ADR-0200 (D3 fallback posture), ADR-0218 (host-originated trap
  kinds)
- Files: `src/api/instance.zig`, `src/api/trap_surface.zig`,
  `include/zwasm.h`, `src/cli/run.zig`, `src/cli/compile.zig`; tests
  `src/api/engine_verdict_test.zig`,
  `test/c_api_conformance/auto_rejects_invalid.c`,
  `test/runners/invalid_module_cli_runner.zig`
