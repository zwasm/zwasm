# 0230 — The CLI's default entry is `_start`, else `main`; it runs when it takes no parameters; both drivers apply one policy

- **Status**: Proposed
- **Date**: 2026-09-11
- **Author**: Junji Takakura
- **Tags**: cli, engine, jit

## Context

`zwasm run` without `--invoke` has two drivers: the `.wasm` default goes
through `runWasmCapturedFull` (the C API, `.auto` engine), while
`--engine jit` and a `.cwasm` go through `runWasmJitCaptured` (the engine's
`runWasiLenientArgs`). Each decided on its own what a default entry is and
what happens to it, and the answers had drifted (#220):

- the chain was `_start` → `main` → the first function export, a third link
  introduced for a bench convenience (`fbc608157`, D-284 nbody) that no
  other runtime has and that neither README nor `docs/reference/cli.md` ever
  stated — 57/57 realworld fixtures export `_start`;
- the `.wasm` default printed the entry's results; the JIT driver printed
  only for `--invoke`;
- an entry with parameters was refused (exit 1) by the `.wasm` default and
  instantiated-only (exit 0, nothing run) by the JIT driver, as was every
  shape the JIT has no call helper for — a capability gap covered by a
  silent success, the posture ADR-0229 removed from instantiation.

The 2026-09-11 adversarial review re-derived the answer for 20 module
shapes on all four paths (`.wasm`, `--engine interp`, `--engine jit`,
`.cwasm`); the table is what settled the decision.

## Decision

1. **The default entry is `_start`, else `main`, else none.** The third
   link is dropped. A module with neither export is refused with exit 1 and
   `no exported function found (looked for _start, main)`; `--invoke`
   names the export to run instead.
2. **A zero-parameter entry runs, whatever its results, and the results
   print** bare on stdout, one per line, on every path — as the `.wasm`
   default already did. The exit code is the guest's `proc_exit` status,
   never a result (#220 (c)); a trap exits 1 with its kind on stderr.
3. **An entry that takes parameters is refused by name on every path**
   (`the default entry '<name>' takes N parameter(s) and none were
   supplied`, exit 1). wasmtime refuses the same shape with exit 1.
4. **A shape the engine cannot call is refused with the reason**, never run
   as instantiate-only exit 0: the JIT's `runWasiLenientArgs` returns
   `UnsupportedEntrySignature` for any named entry it has no helper for, and
   the CLI prints `the JIT engine cannot call '<name>': unsupported entry
   signature`. The engine keeps one judgment — whether it can call the
   shape — and none about which export is the entry: with no name it
   instantiates and runs `(start)` only.
5. **One policy, called by both drivers, after instantiation.**
   `runner.resolveLenientEntry` (engine, on the module bytes) is the chain;
   `cli/run.zig` `resolveDefaultEntry` applies 1–3 and both drivers report
   its refusal only once the module is instantiated: the validity verdict
   (ADR-0229) and the `(start)` function come with instantiation on the
   `.wasm` default, so they precede the entry on every path — the JIT driver
   defers a refusal across its engine call. The `.wasm`, `--engine jit` and
   `.cwasm` paths refuse the same module with the same line, and `main.zig`
   prints a driver's failure through one report for all three.

## Alternatives considered

### Alternative A — align both drivers on the JIT's bound (no printing, instantiate-only for params)

- **Sketch**: the author's first proposal: default entry stays exit-code
  only; an entry with parameters instantiates and exits 0.
- **Why rejected**: the review sank it. It deletes output the default path
  already produces, and it turns an error into a silent success; wasmtime
  is exit 1 on the same module, and every runtime surveyed is non-zero on a
  trapping `_start`.

### Alternative B — wasmtime's shape: `_start` only, no `main`

- **Sketch**: drop the chain entirely.
- **Why rejected**: `main` is what the project's own fixtures and
  hand-rolled hello-worlds export, and the public prose has said `_start` /
  `main` since it was written; only the undocumented third link had no
  precedent.

## Consequences

- **Positive**: one contract, stated in `docs/reference/cli.md` and
  re-derived by `test-cli-default-entry` as a table of 16 shapes × 4 paths;
  a `--engine jit` / `.cwasm` run no longer reports exit 0 for a module it
  did not run.
- **Negative**: a module whose only entry was reachable through the third
  link now needs `--invoke` (the AOT corpus fixture and two unit tests were
  the only users in-tree).
- **Neutral / follow-ups**: the default engine's JIT-backed instance still
  declines a mixed multi-value result at call time (#431 — a C-API call
  arm, not this policy); `zwasm compile` still accepts a module with no
  function export (#432), though `run` on the artifact now says so.

## References

- Issues: zwasm/zwasm#220, zwasm/zwasm#431, zwasm/zwasm#432
- Related ADRs: ADR-0229 (a capability decline is reported, not covered)
- Files: `src/engine/runner.zig`, `src/cli/run.zig`, `src/cli/main.zig`;
  tests `test/runners/default_entry_runner.zig`,
  `test/runners/fixtures/default_entry/`
