# ADR-0174 — windowsmini hardening campaign, then gate suspension

> **Doc-state**: ACTIVE
> Status: Accepted (user-directed 2026-06-07). Amends ADR-0076 D8 (windows BATCHED cadence).

## Context

The 3-host gate (Mac aarch64 + ubuntunote x86_64 + windowsmini Win64; ADR-0076)
runs windowsmini as a background BATCHED gate. In practice the windowsmini
verification load (the `<user>@<windows-host>` SSH-driven `test-all`) is
**contending with the user's separate ClojureWasmFromScratch development** on the
same physical windowsmini box. The user wants to stop paying that cost during
routine feature iteration.

There is also a **concrete open Win64 signal**: as of @87635409 the windowsmini
`test-all` reports `[run_remote_windows] OK` (realworld fixtures `MATCH`) **but
the spec-assert phase shows `pass=0` across EVERY category** (assert_return
pass=0 fail=0; assert_invalid pass=0 fail=194; trap/malformed partial fails),
while ubuntunote on the *same commit* passes all with real counts. This strongly
indicates a **windows-side spec-runner execution/reporting failure masked by the
OK verdict** — i.e. windowsmini is NOT actually fully green; the OK verdict is
keying off realworld MATCH only. (Cf. lesson `fixture-self-verify-false-lead`
for how an OK verdict can hide a broken phase.)

## Decision

A **two-phase plan**:

1. **windowsmini-hardening campaign (immediate priority).** A focused,
   intensive campaign: run windowsmini frequently (low/zero batch threshold),
   root-cause the spec-assert `pass=0` anomaly FIRST, then any remaining real
   Win64 divergences, until windowsmini is **fully, verifiably green** (real
   pass counts matching ubuntu, not a MATCH-only OK). Use the
   investigation-discipline hypothesis-list + heisenbug gates. This is normal
   autonomous campaign work (runs under `/continue`).

2. **Gate suspension (after #1 succeeds).** Once windowsmini is fully green,
   **suspend windowsmini gating** so Mac+ubuntu iterate fast:
   `bash scripts/should_gate_windows.sh --suspend` (writes
   `.dev/windows_gate_suspended` = the SHA at suspension). While suspended,
   `should_gate_windows.sh` always returns "gate-deferred" and the loop runs a
   **2-host gate (Mac + ubuntunote)**. Re-enable with `--resume` (a) before any
   `main` merge / A13 strict-3-host gate, or (b) when a diff touches
   Win64-divergence-prone paths (ABI / calling-convention / frame-layout /
   `emit.zig` marshal areas — the existing `ABI_PATHS` set), or (c) on user
   request.

Suspension is a **deliberate, user-sanctioned 2-host mode, NOT a silent skip**
(no_workaround compliance): it is gated behind an explicit sentinel + this ADR,
prints its state every check, and the A13 strict-3-host merge gate
(`gate_merge.sh`) is unchanged — windowsmini is still required for any `main`
push, so suspension only affects the fast inner iteration loop.

## Consequences

- Inner loop on `zwasm-from-scratch` can run Mac+ubuntu-only after the campaign,
  freeing windowsmini for ClojureWasmFromScratch.
- The `main` merge gate (A13) and the campaign itself keep windowsmini honest;
  Win64 drift accumulated while suspended is caught at `--resume` (the next
  windows batch re-verifies the whole span since `.dev/windows_gate_suspended`).
- ADR-0076 D8's cadence still applies whenever gating is NOT suspended.

## Revision / status update

- 2026-07-03 — **SUPERSEDED-IN-PART by ADR-0076 D9** (user-ratified, scaffolding-necessity audit §B.2). The suspend/resume machinery and the "windowsmini as inner-loop gate" framing are obsolete: post-v2.0.0 maintenance retired the local Windows cadence entirely (CI's `ci-required` runs the Windows leg on every PR). `should_gate_windows.sh` is now a deprecation stub and the `.dev/windows_gate_suspended` sentinel is dead. Retained as historical record of the campaign-era gate economics.
