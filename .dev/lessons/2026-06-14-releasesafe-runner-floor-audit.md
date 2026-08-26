# ReleaseSafe-floor audit: a per-runner check, not a surface claim

**Date**: 2026-06-14 (spawn channel added 2026-08-26) · **Context**: ADR-0177 gap audits.

## Observation

ADR-0177 floored the test runners at ReleaseSafe via a `zwasm_lib_mod = core_rs` alias that
"every integration runner imports." The surface looked unified. Twice it was not: `core_comp`
(the Component Model runner's own module) sat on `.optimize = optimize`, and `test-aot-diff`
imports no zwasm module at all — it spawns the CLI, so the alias could never reach it. Each ran
a whole corpus in Debug, invisibly, past a green guard. (cljw hit the identical class —
ADR-0132/0133 there.)

## Rule

"All runners are ReleaseSafe" is a **per-runner property**, not a surface claim. Audit it by
mapping every runner to **the engine it executes**, not to the modules it imports. Two channels
reach an engine and an audit of one is silent about the other: a runner may IMPORT a zwasm module
(a separate `core_*` twin defaults to Debug the moment it needs different build_options), or it
may SPAWN the CLI, which no module swap can floor.

## Audit recipe (re-runnable)

```sh
# 1a. IMPORT channel — map every runner → its zwasm module:
grep -nE 'addImport\("zwasm",' build.zig
# 1b. SPAWN channel — every runner handed a CLI artifact (this is the channel 1a cannot see):
grep -nE 'add[A-Za-z]*Arg\([^)]*\bexe' build.zig
# 2. ReleaseSafe-floored ⟺ module ∈ {core_rs, core_releasesafe, zwasm_lib_mod(=core_rs)},
#    or artifact ∈ {exe_rs}. Debug ⟺ core, core_comp, exe, …anything on `.optimize = optimize`.
# 3. Each Debug consumer must be Debug-BY-DESIGN — allowlist in ADR-0177's Revision rows and in
#    check_releasesafe_runners.sh. GAP: any HEAVY corpus RUN-ARTIFACT in `test-all` on Debug.
# 4. Fix: `.optimize = runner_optimize` for a module, or `exe_rs` for a spawned CLI.
```

`runner_optimize` floors at ReleaseSafe but honours a higher `-Doptimize`. Gaps found: `core_comp`
(import, 2026-06-14) and `test-aot-diff` (spawn, 2026-08-26 — invisible to step 1a, which is why
it survived a clean re-run of this recipe).

## Tells

- A new `core_*` module created with `.optimize = optimize` (copy-pasted from `core`, not `core_rs`).
- `test-all` wall-clock dominated by one corpus dir that "should be fast."
- A runner whose zwasm import is NOT the `zwasm_lib_mod`/`core_rs` alias.
- A runner that takes the engine as a spawned binary — it has no import to audit.

Anti-regression: `scripts/check_releasesafe_runners.sh` (in `ci_gate.sh` core, not just
pre-commit) asserts no runner reaches a Debug engine by import OR by spawn. Stronger, not done
here: cljw embeds the mode in the binary and asserts it via `--version` (ADR-0132 there), which
guards the artifact rather than build.zig's spelling.
