# ADR-0194 — Unify the spill-frame origin (fix the x86_64 v128 spill OOB; D-461 rework Phase III)

- Status: **Accepted** (D-461 rework campaign Phase III, ADR-0153; 2026-06-16). Autonomous — fixes a measured
  x86_64 JIT correctness gap within the single-pass P3/P6 invariants (no optimising tier, no new pass).
- Date: 2026-06-16
- Relates: ADR-0053 (v128 spill-frame alignment / `computeSpillOffsets`), ADR-0098 (regalloc_compute extraction),
  ADR-0110 (Value=16 widen), ADR-0018/0036 (class-aware slot boundaries). Supersedes the implicit "origin = 8"
  assumption in `computeSpillOffsets`.

## Context

D-461 Phase I+II established (ground-truth instrumented `slot()` dump + the previously-zero-coverage
characterization tests): x86_64 JIT panics `index out of bounds` at `regalloc.zig:222` under ≥7 live FP/v128
vregs. The deterministic regalloc threads **THREE inconsistent "spill-frame origin" values** for what must be one
quantity — "the lowest slot id that can resolve to a spill":

| Stage | Origin used | x86_64 | arm64 |
|---|---|---|---|
| **Mint** (`computeWith` force_spill_threshold) | `max(gpr_pool, fp_pool)` | 6 | 13 |
| **`spill_offsets` sizing** (`computeSpillOffsets` param) | hardcoded `max_reg_slots_gpr_default` | **8** | 8→OK |
| **`slot()` resolve** (`Allocation.max_reg_slots_gpr`, patched in `compile.zig:274`) | `gpr_pool` | **4** | 8 |

The bounded v128 `spill_offsets` array is **sized** from origin 8 (`n_slots - 8` entries, indexed `s - 8` at
build) but **indexed** `id - 4` at resolve (the patched field). The +4 skew overruns the array, and the
"faked spill" ids in `[gpr_pool, mint_threshold)` (GPR ids 4..5, never minted as spills) have no array entry.
arm64 is unaffected only because all three origins coincidentally collapse to 8 there.

Scalar spills survived because the no-v128 path uses the array-less `(id - max_reg_slots_gpr) * 16` fallback
(`regalloc.zig:224`), which already reads the patched per-call field consistently — only the **bounded array** has
the divergence. Hidden until D-460 high-v128-pressure programs first exercised v128 spills.

## Decision

**The spill-frame origin is a single per-arch value = `max_reg_slots_gpr` (the GPR pool size), which is always
`min(gpr_pool, fp_pool)` — the lowest id any class can spill at. Thread it into `computeWith` →
`computeSpillOffsets` so the array is SIZED and INDEXED from the same origin `slot()` RESOLVES with, and set it on
the `Allocation` at build time (removing the `compile.zig` post-compute GPR patch).**

Concretely:
1. `computeWith(allocator, func, force_spill_threshold, scratch_fn, **max_reg_slots_gpr**)` gains the per-arch GPR
   pool param. `computeSpillOffsets` uses it (not `max_reg_slots_gpr_default`) for `n_spill = n_slots - origin` and
   the `s - origin` build index, so the array covers `[max_reg_slots_gpr, n_slots)` — including the faked-spill ids.
2. `computeWith` sets `Allocation.max_reg_slots_gpr = max_reg_slots_gpr` (build time). `compile.zig` drops its
   `alloc.max_reg_slots_gpr = …` patch (line 274); the `max_reg_slots_fp` patch STAYS (it is the FP register-vs-spill
   threshold, an independent axis from the spill-frame origin).
3. `slot()` is unchanged — it already indexes `id - self.max_reg_slots_gpr`; once sizing matches, it is correct.
4. The **mint** (`force_spill_threshold`) is UNCHANGED. It legitimately differs from the origin: it maximises
   register use at `max(gpr,fp)` while the origin is `min(gpr,fp)`; the `[origin, mint)` band is "minted as a
   register for the larger-pool class, spilled for the smaller-pool class" — the array now covers it.

## Alternatives rejected

- **Class-aware regalloc mint** (separate GPR/FP register pools at mint): needs a per-vreg gpr-vs-fpr class signal
  the allocator does not track today (only v128 `shape_tags`). Far larger blast radius; unnecessary — the bug is an
  ORIGIN bookkeeping inconsistency, not a fundamental mint-model defect. Rejected.
- **Eliminate `spill_offsets`, always use the uniform `(id-origin)*16` fallback**: rejected — `computeSpillOffsets`
  still packs scalar spills at 8-byte stride (regalloc_compute.zig:401), so the array is NOT redundant post-ADR-0110;
  removing it regresses mixed scalar+v128 frame density and shifts offsets.

## Anti-regression invariants

- **arm64 byte-identical**: `max_reg_slots_gpr = 8 = max_reg_slots_gpr_default`, so `computeSpillOffsets` produces
  the identical array; the Phase II characterization tests (`D-461 char: …`) + all existing regalloc/spill tests
  stay green unchanged.
- **The Phase II adversarial fix-verifier** (`D-461 ADVERSARIAL …`, currently `skip.blocker`) is un-gated in Phase
  IV and must pass: the x86_64 divergent-origin FP spill resolves in-bounds.
- **The D-461 integration test** (`runner_gc_test` 12-live-v128, arm64-gated) is un-gated for x86_64 → returns 4095.
- WASI/SIMD/GC corpora green at every commit; `check_build_dce` + 3-host gate unchanged.

## Incremental migration (Phase IV)

1. Add the `max_reg_slots_gpr` param to `computeWith` + `computeSpillOffsets`; default callers pass
   `max_reg_slots_gpr_default` (arm64-identical). Un-gate the adversarial unit test → green.
2. `compile.zig`: pass the per-arch GPR pool; drop the GPR post-patch. Rosetta-verify x86_64 locally.
3. Un-gate the `runner_gc_test` D-461 fixture for x86_64; ubuntu confirms on real x86_64.
4. Then resume the D-460 v128-GC x86_64 mirror (the original blocker) on top of the fixed spill path.

## Consequences

- One coherent spill-frame origin; x86_64 high-FP-pressure JIT no longer panics; D-460 v128-GC x86_64 unblocked.
- `computeWith` signature changes (~3 call sites + tests). Small, mechanical, within single-pass.

## Revision 2026-10-17 — the origin is the smaller of the two thresholds

The Decision read the origin off the GPR pool because that pool was the
smaller one. It was, on both arches, until #503 gave x86_64 eight GPRs
against six XMMs; an FP vreg in slot 6 or 7 would then have resolved to a
negative offset. The origin is now `min(max_reg_slots_gpr, max_reg_slots_fp)`,
derived where it is used rather than stored, and `computeWith` takes both
thresholds so the Allocation carries them from build time (the FP post-patch
in `compile.zig` is gone). arm64 and the four-GPR x86_64 resolve to the
origins they had.

## Revision 2026-10-23 — the mint rises with the homes (#600)

Decision 4's mint is now `max(gpr, fp + K)` in a function with FP values
(ADR-0060 Revision 2026-10-23); the origin stays `min(gpr, fp)`. FP's ids
`fp ..< fp + K` are registers, so their cells in `[origin, mint)` go unused,
as the GPR-held ids there already did.
