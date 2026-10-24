# 0150 — §15.3 class-aware allocator: FP-spill measured at 0% → ≥3% bar unreachable, folded

- **Status**: Accepted (2026-06-04; autonomous-with-ADR per default posture + deviation-watch §18.2)
- **Date**: 2026-06-04
- **Author**: claude (autonomous, /continue Phase-15 perf assessment)
- **Tags**: Phase 15, perf, regalloc, class-aware, dual-pool, FP, spillBytes, ADR-0038, ADR-0040, ADR-0149
- **Amends**: ROADMAP §15.3 row (target) + §15.P aggregate framing; ADR-0038/0040
  (the deferred class-aware-allocation premise). Sibling to ADR-0149 (§15.2 fold).

## Context

§15.3 was scoped (ADR-0038/0040) as a **dual-pool GPR/FP allocator** + liveness
type-tagging + tighter `spillBytes()`, exit ≥3% on FP-heavy fixtures, contributing
to a combined ≥10% with the (now-folded, ADR-0149) §15.2 coalescer. ADR-0038 §AltA
itself estimated the win at "~3–5% on FP-heavy fixtures only."

A measurement this turn (throwaway FP/GPR spill counters in `arm64/gpr.zig` via
`zwasm run --engine jit`, reverted) shows the premise is empirically void:

| fixture | total instrs | fp_spill_loads | fp_spill_stores | gpr_spill_loads | gpr_spill_stores |
|---|---|---|---|---|---|
| handwritten/nbody (FP-dense) | 665 | **0** | **0** | 0 | 0 |
| shootout/matrix (FP present) | 21288 | **0** | **0** | 258 | 233 |

**FP-spill traffic = 0.0% of emitted instructions on both.** With 13 allocatable
V-registers (V16–V28, `max_reg_slots_fp=13`), FP register pressure never overflows on
these FP-heavy fixtures, so `fpLoadSpilled`/`fpStoreSpilled` are never reached. The
allocator's *resolution* is already class-aware (D-036, shipped: `Allocation.slot(vreg,
class)` dispatches GPR/FP); only the *allocator pool* is class-blind.

## Decision

**§15.3's ≥3% FP-perf target is empirically unreachable → §15.3 folds (like §15.2).**

A dual-pool allocator + liveness type-tagging would eliminate FP spills — but there
are NO FP spills to eliminate (0%). Tighter `spillBytes()` only shrinks the spill
stack frame (footprint), saving **zero runtime instructions** when FP doesn't spill.
So the ≥3% perf bar cannot be met by the §15.3 mechanism on the current fixtures.

- §15.3 row → `[x]` folded; the dual-pool refactor (ADR-0038/0040, ~150–300 LOC) is
  NOT built (no FP-perf to gain).
- The one genuinely-useful sliver — `spillBytes()` over-allocates the spill frame by
  counting FP regs past the GPR boundary (a footprint/correctness cleanup, NOT perf,
  ABI-offset-adjacent so W54-careful) — is filed as **D-259**, an opportunistic §15.P
  cleanup, not a perf chunk.

## The regalloc-axis pattern (§15.2 + §15.3)

Both regalloc-axis perf tasks now measure ~0 headroom: §15.2 GPR-spill traffic
2.7–5.6% (ADR-0149), §15.3 FP-spill 0%. **v2's deterministic-slot emit is already
tight on memory traffic** — the inefficiencies these tasks targeted do not exist at
the assumed scale. This is a *positive* signal (v2 is likely near v1 parity), not a
failure. The remaining perf lever is the **compute/SIMD axis (§15.4)**, which is a
different mechanism (instruction throughput + the D-246 arm64 `dot`/`extmul` emit
HOLE = missing ops, a correctness gap independent of perf).

## §15.P aggregate reframing

The §15.3 row's "combined ≥10% on 3 v1-class fixtures" rested on §15.2 + §15.3, both
now ~0. The ≥10% fixed-combined target is no longer supportable from the regalloc
axis. **§15.P is reframed**: validate **no unexplained regression vs v1 main** +
§15.4 SIMD deltas where applicable (SIMD-heavy fixtures) + the empirical regalloc-axis
finding (already-efficient). A fixed aggregate % is replaced by parity-vs-v1.

## Rejected alternatives

- **Build the dual-pool allocator anyway** — 0% FP-spill ⇒ it provably yields no
  FP-perf; building 150–300 LOC of regalloc refactor (W54-risky) for a vacuous bar is
  dishonest, mirroring the §15.2 no-op-coalescer rejection.
- **Implement tighter `spillBytes()` now as the §15.3 deliverable** — it is footprint
  not perf (0 runtime instrs), and frame-size changes are ABI-offset-adjacent (W54
  class). Defer as D-259 cleanup, not a forced §15.3 chunk.

## Consequences

- §15.3 `[x]` folded; §15.4 (SIMD + D-246 emit hole) is the next + real perf/correctness
  lever. D-259 filed (spillBytes footprint cleanup). Phase 15 stays IN-PROGRESS.
- If a future FP-register-pressure-heavy workload (more live FP temps than 13) appears
  — e.g. via ClojureWasm (§15.6) — re-open: dual-pool would then have real headroom.
  Discharge predicate for re-opening = a fixture showing non-zero `fpLoadSpilled`.

## Revision (2026-06-04, D-265 rework campaign — ADR-0153 close)

The "regalloc-axis ~0 headroom" framing (§"The regalloc-axis pattern" above) is
REVISED to scope: it holds for *FP spill* (genuinely 0%) and for *average* program
spill traffic, but NOT for the GPR **loop-carried-local** hot path. The §15.P bench
measured a real 2.30× vs-v1 regression on loops reading a loop local; the D-265
campaign (ADR-0153) closed it via register-homing of hot locals (single-pass intact),
recovering arm64 2.30×→0.97× and collapsing the x86_64 reads-`i`/control differential
2.4×→1.0×. This ADR's own FP conclusion is unaffected (0% FP spill is real); only the
sibling-ADR-0149 GPR "~0 headroom" generalisation was the over-reach — see ADR-0149
Revision + lesson [[2026-06-04-regalloc-headroom-hotloop-not-total-instrs]].

## Revision 2026-10-23 — FP spill on x86_64 with register homes (#600)

The 0% was measured on arm64 before register homing. With four homes holding
ids 0–3, x86_64 FP values had two of six XMMs, and llama2.c spent 21.6% of its
hot function's instructions moving XMM values through frame slots. #600 gives
FP the ids past the homes; the dual pool stays unbuilt.
