# 0152 — §15.6 ClojureWasm CI validation deferred (consumer is genuinely-later external work)

- **Status**: Closed 2026-09-08 (the barrier will not dissolve — ClojureWasm wound down, #407; §15.6 closed as won't-happen)
- **Date**: 2026-06-04
- **Author**: claude (autonomous, /continue §15.6 Step 0 survey) — user-confirmed the consumer state
- **Tags**: Phase 15, ClojureWasm, external-dependency, defer, ADR-0132 carve-out
- **Amends**: ROADMAP §15.6 row (deferred + forward-ref) + §15.P (no longer gates on §15.6).

## Context

§15.6 = "ClojureWasm CI green with its `zwasm` dep pointing at a local `build.zig.zon`
`path = …` to `zwasm_from_scratch/` (no ClojureWasm-side commits needed for v2-experimental
validation)." The §15.6 Step 0 survey + user confirmation established that the consumer side
**does not exist yet**:

- `ClojureWasmFromScratch/build.zig.zon` (branch `cw-from-scratch`, version `0.0.0`) declares
  **only `zlinter`** as a dependency — **no `zwasm` dep at all**, by any form (git url / path /
  package).
- No `.github/workflows/` — there is no ClojureWasm CI to make "green".
- `ClojureWasmFromScratch` is itself a **from-scratch v1 redesign in progress** (its own ADR
  sequence, e.g. ADR-0087), analogous to what zwasm v2 is to zwasm v1. The **stable** ClojureWasm
  is v0.5.0 on `main`; the zwasm-v2 consumer is cw's own **future internal phase** (its
  `project_facts.md` "Phase 16" wasm-FFI zone) — not yet built.

So "make ClojureWasm CI green against zwasm v2" references genuinely-later work owned by a
*different project's* in-progress redesign timeline. There is nothing on the consumer side to
validate against today.

## Decision

**Defer §15.6** to when `ClojureWasmFromScratch` v1 lands its zwasm-v2 wasm-FFI consumer (its
internal "Phase 16"). This is the ADR-0132 carve-out (re-scope when a phase references
genuinely-later work) extended to an **external** dependency — even more clearly defer-justified
than an intra-ROADMAP forward-ref, since the timeline is not ours to drive.

- §15.6 ROADMAP row → carries a **deferred** marker + forward-ref to **D-264** (the tracking
  debt row, barrier = cw-v1 zwasm-FFI consumer existing).
- §15.P (Phase 15 close) **no longer gates on §15.6**. Phase 15 closes on the §15.P
  parity-vs-v1 work (D-263) with §15.6 explicitly carried as a deferred external item.
- zwasm v2's embedding API is **already proven consumable** by the in-repo `examples/zig_host/`
  native-embedding example (ADR-0109) + `test/api/zig_facade_runner.zig` — so v2's
  package-consumability is not itself in doubt; only the cw-specific CI integration waits.

## Rejected alternatives

- **Build a throwaway `private/spikes/clojurewasm_v2_consumer/` now** (the survey's first
  recommendation) — rejected as busy-work: it would re-prove what `examples/zig_host/` already
  demonstrates (v2 is consumable as a Zig package via `@import("zwasm")`), without exercising any
  *ClojureWasm-specific* surface (which does not exist yet). If a package-consumability gap is
  ever suspected, `examples/zig_host/` is the existing proof; a spike adds nothing until cw has
  real consumer code.
- **Block Phase 15 close on §15.6** — rejected: ties zwasm's milestone to another project's
  internal redesign schedule. The user explicitly OK'd deferral ("後回しにしてもいい").

## Consequences

- §15.6 row → deferred; D-264 tracks the barrier. §15.P becomes the last active Phase-15 task
  (parity-vs-v1 + W45 loop measurement, D-263). Phase 15 can close with §15.6 forward-ref'd.
- When cw-v1 lands its wasm-FFI consumer, D-264's barrier dissolves → re-open §15.6 (or fold it
  into a post-v0.1.0 integration phase, decided then with the real consumer in hand).

## Revision history

| Date       | SHA          | Note                                                           |
|------------|--------------|----------------------------------------------------------------|
| 2026-06-04 | `<backfill>` | Initial accepted version.                                      |
| 2026-09-08 | `<backfill>` | Closed: barrier void (#407); §15.6 row closed as won't-happen. |
