# ADR-0177 — Integration test runners build ReleaseSafe (D-311)

> **Doc-state**: ACTIVE
> Status: Accepted (2026-06-08)

## Context

The per-chunk gates (`mac_gate.sh`, `run_remote_{ubuntu,windows}.sh`) run
`zig build test-all`, which defaulted every artifact to **Debug**
(`standardOptimizeOption`). Debug host execution is ~5–10× slower than
ReleaseSafe; the integration RUNNERS (spec-assert / realworld / wast / edge
corpora) are run-time-dominated, so Debug made the loop's iteration slow —
user-flagged 2026-06-08 ("結合テストはイテレーション速度が大事").

Switching the whole build to ReleaseSafe exposed **D-311**: 8 ReleaseSafe-only
failures (`zig build test-all -Doptimize=ReleaseSafe`). Five were a real
production bug (buffer-write JIT entry bypassed the D-245 callee-saved
trampoline — fixed @a0069ce8). The remaining three are **unit tests** that call
a raw `module.entry(...)` JIT fn-ptr directly (119 such sites in
`src/engine/`), violating the host-boundary contract: the JIT body MOV-installs
the pinned callee-saved cohort from `rt` without stack-saving the caller's
values, so an *optimized* host with live values in those registers corrupts.
Production never calls raw entry — it always routes through
`entry.invokeAndCheck` / `entry_buffer_write.invokeBufferWrite` (cohort
trampoline). So the 3 are a test-harness artifact, harmless under Debug.

## Decision

Per-artifact optimize split in `build.zig`:

- A ReleaseSafe twin module **`core_rs`** (root `src/zwasm.zig`, optimize =
  `if (Debug) ReleaseSafe else -Doptimize`) backs every integration runner —
  the shared `zwasm_lib_mod` alias points at `core_rs`, so all ~16 runners +
  the wasm-3.0 spec runner flip in one place.
- **`core_tests`** (the unit suite, with the raw-entry calls) + `cli_tests` +
  the production `exe`/lib stay on Debug `core` (honouring `-Doptimize`).
- The integration runners invoke wasm ONLY through production trampoline-safe
  paths, so they are correct under ReleaseSafe (verified: spec 212 / realworld
  55 / wast 1158 green).

Result: `zig build test-all` runs unit tests Debug (fast compile, raw-entry
safe) + runner corpora ReleaseSafe (fast run) — **no gate-script change**;
the existing `zig build test-all` invocations get faster automatically. Zig
caches per optimize mode, so Debug `core` + ReleaseSafe `core_rs` coexist
without thrash. `gate_merge.sh` is unchanged (Debug `test-all` at the A13
merge checkpoint preserves Debug-undefined-fill coverage + its ReleaseSafe
JIT smoke).

## Alternatives rejected

- **Whole build `-Doptimize=ReleaseSafe`** — trips the 3 raw-entry unit-test
  failures (and seed-dependent siblings among the 119 sites).
- **Sweep all 119 raw-entry call-sites through a trampoline helper** — large,
  mechanical, error-prone, and unnecessary: the runners (the slow part) don't
  call raw entry, and the unit suite is fine in Debug (the user explicitly
  accepted unit-Debug).
- **Make the JIT body save/restore the callee-saved cohort itself** — reverses
  the D-245 decision (lean body, host-boundary trampoline) and adds hot-path
  prologue/epilogue cost to every JIT call.

## Consequences

- Faster `test-all` on Mac + ubuntu (the user's iteration-speed ask).
- ReleaseSafe runners ALSO add JIT-ABI coverage Debug hides (the D-245 class).
- A plain `zig build` (production CLI/lib) is unaffected (Debug default).
- Debugging a runner in Debug needs a temporary build.zig edit (rare).
- Extra cache: `core` (Debug) + `core_rs` (ReleaseSafe) + `core_comp`
  (component) coexist in `.zig-cache`.

## Revision history

- 2026-06-14 — **Gap closed: `core_comp` was Debug.** A cross-project audit
  (prompted by ClojureWasmFromScratch's own ReleaseSafe campaign — Debug sneaking
  into gate paths is ~100× slower) found the original change floored the *wasm*
  spec/realworld/edge runners at ReleaseSafe (via the `zwasm_lib_mod = core_rs`
  alias) but the **Component Model spec runner** (`comp_spec_runner`, a 158-manifest
  corpus in `test-all`) imports the SEPARATE `core_comp` module, which was still
  `.optimize = optimize` (= Debug on a plain `zig build test-all`). The surface
  looked unified but this one integration runner ran the whole CM corpus in Debug.
  Fix: `core_comp.optimize = runner_optimize` (same ReleaseSafe floor as `core_rs`;
  `core_comp` is consumed only by that runner, no production component exe). Audit
  recipe + the full runner→module map: lesson `releasesafe-runner-floor-audit`.
  Remaining Debug-by-design (verified intentional): `core_tests` (leak-detecting
  DebugAllocator), `exe` (production CLI honours `-Doptimize`), the light unit-test
  mods, and the trivial `zig_host`/`c_host` single-wasm examples.
  **Scope of that enumeration (clarified 2026-08-26):** it was taken over the
  MODULE-IMPORT channel only. `exe` is Debug-by-design as the *installed*
  artifact; it was simultaneously the engine of a spawned-binary corpus lane,
  which this pass never examined. See the 2026-08-26 row.

- 2026-08-26 — **Gap closed: the spawn channel.** The floor is enforced by
  swapping a module import, so it reaches a runner only if the runner imports a
  zwasm module. `test-aot-diff` (`test/aot/aot_process_diff.zig`) takes the
  engine as a **spawned binary** — `build.zig` hands it the CLI artifact — so
  no module swap could reach it and it ran its whole cross-process corpus on
  Debug, at a cost of one Debug compile per lane per fixture. Both the audit
  recipe and `check_releasesafe_runners.sh` were blind to it for the same
  reason: both walk `addImport` sites. Fix: `exe_rs` / `zwasm-releasesafe`, a
  ReleaseSafe twin of the CLI built from `core_rs`, handed to that lane;
  `exe` keeps `-Doptimize` as the shipped binary and still backs `zig build
  run` and the single-shot fault/oob-trap lanes. Guard extended with case (a2)
  (any `add*Arg` handing `exe` to a runner, plus `exe.getEmittedBin()`), and
  moved into `scripts/ci_gate.sh` core — it had run only in `gate_commit.sh`,
  which is optional pre-flight and fires only when `build.zig` is staged, so
  the floor was never checked on the merge path. **Generalised rule: the floor
  is a property of the ENGINE a runner executes, not of the modules it
  imports.** Lesson `releasesafe-runner-floor-audit` updated for both channels.
