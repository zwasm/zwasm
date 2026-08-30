# 0077 — Make regalloc aware of op-internal scratch reservations

- **Status**: Closed (implemented)
- **Date**: 2026-05-20
- **Author**: autonomous-loop (Claude) + chaploud (review)
- **Tags**: regalloc, ABI, scratch, D-132, D-133, §9.12-C, substrate

## Context

D-132 (2026-05-16) and its surviving cohort D-133 surfaced a load-bearing
abstraction gap: **regalloc treats X10/X11/X12 as freely allocatable
caller-saved scratch slots, but several arm64 op emit handlers use the
same registers as op-internal scratch with hardcoded `encLdrImm(10, ...)`
/ `encLdrImm(11, ...)` / `encLdrImm(12, ...)` patterns**. When regalloc
assigns a live vreg to one of these slots and an op handler clobbers it
mid-emit, the value silently corrupts.

B113-B118 attempted a substrate fix:

- B113 added named pools `abi.table_emit_scratch_gprs = [_]Xn{14, 15}` +
  `memory_emit_scratch_gprs = [_]Xn{14, 15}` carved out of
  `spill_stage_gprs`, with a comptime disjointness check against
  `allocatable_gprs`.
- B118 documented that the pools intentionally overlap with
  `spill_stage_gprs` because table/memory emit handlers do not spill
  mid-op (so X14/X15 are guaranteed free at op entry).

B119's sweep attempt then exposed a deeper structural insufficiency:

- The "≤ 2 simultaneous scratch" contract held only for trivial ops
  (`emitTableGet` / `emitTableSet` / `emitTableSize`, already discharged
  at d-64 / d-66).
- The 5 bulk handlers (`emitTableFill`, `emitTableCopy`, `emitTableInit`,
  `emitMemoryInit`, plus `emitElemDrop` subsumed by `emitTableInit`'s
  step B3) hold **≥ 4 simultaneously-live scratches** across bounds
  checks, dual-table copies, and dropped-flag overrides.
- See `.dev/lessons/2026-05-20-d133-sweep-pool-size-insufficient.md`
  for the detailed live-scratch census per handler.

The B118 comment-as-invariant prose ("d-64 load-then-overwrite pattern
keeps simultaneous use ≤ 2 per op") did not survive contact with the
bulk handlers. Per `.claude/rules/comment_as_invariant.md`: an invariant
in prose without code-level enforcement is a known-failure-mode latent
bug.

### The three resolution paths surveyed in B119

1. **(a) Per-handler stack save/restore.** Add ~40 bytes of
   STP/LDP scaffolding to each affected handler's prologue/epilogue.
   Runtime cost: per-handler-call. JIT bloat: ~200 bytes total (5
   handlers × ~40 bytes).
2. **(b) Extend `allocatable_caller_saved_scratch_gprs` to {9..15}.**
   Kills regalloc: the pool size determines the slot threshold above
   which spills happen; over-extending raises spill frequency on
   every function.
3. **(c) Make regalloc aware of op-internal scratch reservations.**
   Add a per-op-tag declaration "this op reserves X10/X11/X12 at its
   PC range" + a regalloc walker fence that excludes those slot ids
   from vregs whose live range crosses the op's PC. Runtime cost:
   zero. JIT bloat: zero. Up-front cost: regalloc plumbing + per-op
   declarations + spike validation.

### Why (a) is rejected

Path (a) is a **workaround** in the `.claude/rules/no_workaround.md`
sense — it pays runtime cost to paper over a missing abstraction
rather than fixing the abstraction itself. The runtime cost is paid
on every call to the affected handler (even when regalloc *would not*
have placed a live vreg in X10-X12 — the save/restore happens
unconditionally). Future ops needing ≥ 3 simultaneous scratch would
require manual prologue extension per-op, recreating the same class
of latent gap.

ROADMAP P1 (spec fidelity over expedience) + P3 (defer rather than
work around) + `no_workaround.md` collectively point at (c) as the
structurally correct fix. The deferred runtime cost of (c)'s up-front
plumbing investment is paid back across every future op that needs
op-internal scratch — and there will be more such ops in Phase 10+
GC / threads / EH work.

## Decision

Adopt path **(c)**: extend `src/engine/codegen/shared/regalloc.zig`
with an **op-internal scratch reservation API** that:

1. Per-arch ABI declares a `op_scratch_reservation_table` (`ZirOp →
   slice of slot ids`) listing which slot ids each op's emit handler
   will clobber internally.
2. Regalloc's slot assignment walker (in `compute` /  `computeWith`)
   consults this table when assigning a slot id to a vreg whose
   live range crosses the op's PC. If a candidate slot id is in the
   op's reservation set, regalloc skips it (forces spill or picks
   a higher slot id).
3. The verifier (`verify`) checks the post-condition that no live
   vreg is assigned a slot id in a clobbering op's reservation set
   across that op's PC range. Failure is a `VerifyError.OpScratchOverlap`.
4. A comptime `validate_op_scratch_reservation_table` walks every
   declared op-tag's reserved slot ids against `abi.allocatable_gprs`
   and rejects entries that reference non-allocatable slots (would
   be a no-op declaration) — pairing this rule with
   `.claude/rules/comment_as_invariant.md`.

The actual reservation slots for the 5 D-133 bulk handlers stay
{X10, X11, X12, X13} (= the existing `allocatable_caller_saved_scratch_gprs`
members already used by the legacy hardcoded handlers); regalloc just
becomes aware of the use and accommodates it.

`abi.table_emit_scratch_gprs` + `abi.memory_emit_scratch_gprs` (B113)
remain useful as **the named source-of-truth** for the per-op
reservation table entries — the handlers reference them, the table
references them, and the comptime check verifies consistency.

`scripts/check_invariant_comments.sh` strict mode flips to gate-failing
once the D-133 sweep lands (sites go from 55 → 0).

## Alternatives considered

### Alternative A — Per-handler stack save/restore

- **Sketch**: Add `STP X10, X11, [SP, #-16]!` + `LDP X10, X11, [SP], #16`
  to each affected handler's prologue/epilogue. ~40 bytes per handler.
- **Why rejected**: workaround (papers over the regalloc abstraction
  gap with runtime cost), unconditional save even when regalloc had
  not placed a live vreg in X10-X12, recreates the same class of
  latent gap for any future op needing op-internal scratch. ROADMAP
  P1 / P3 + `.claude/rules/no_workaround.md` collectively reject this
  shape.

### Alternative B — Extend `allocatable_caller_saved_scratch_gprs` to {9..15}

- **Sketch**: Make X14/X15 allocatable. Kill the carve-out.
- **Why rejected**: (1) X14/X15 are needed for spill staging per
  ADR-0018; (2) the pool size determines the slot threshold for
  forced spill — over-extending raises spill frequency on every
  function. Catastrophic perf regression possible.

### Alternative C — Keep current `{14, 15}` pool, restructure handlers to fit

- **Sketch**: Per-handler reorder loads so simultaneous use ≤ 2.
  Bulk handlers need 4+ live scratches, so this requires manual
  reload-after-clobber patterns (re-load tables_ptr from X19 each
  time it's needed).
- **Why rejected**: Adds runtime cost (extra LDR per re-derive),
  the d-64 pattern doesn't trivially extend to 4-scratch cases,
  comment-as-invariant prose is brittle. Same workaround shape as (a).

## Consequences

- **Positive**:
  - Structural fix to the regalloc abstraction gap that surfaced as
    D-132 / D-133. Future ops needing op-internal scratch just append
    to the reservation table — no per-op runtime cost, no future
    latent gaps.
  - Zero runtime cost in the emitted JIT code.
  - `check_invariant_comments.sh --strict` can become a pre-commit
    gate, catching new prose-only invariants at write-time.
  - Provides a substrate for Phase 10+ GC / threads / EH ops that
    will need similar op-internal scratch patterns.
- **Negative**:
  - Up-front cost: ~200-500 LOC of regalloc plumbing + per-op
    reservation declarations + verifier extension.
  - Requires a spike (`private/spikes/regalloc-live-fence/`) to
    validate the API shape against bulk handlers before committing
    to the design.
  - The regalloc walker becomes slightly more complex (one
    additional comptime-known data lookup per slot assignment).
- **Neutral / follow-ups**:
  - Spike outcome → this ADR flips to Accepted (or this ADR gets
    amended with a corrected design if the spike surfaces issues).
  - Once Accepted, B113's `table_emit_scratch_gprs` /
    `memory_emit_scratch_gprs` constants are re-purposed as the
    named-source for the reservation table entries (kept, not
    deleted).
  - D-133 row in `.dev/debt.md` flips to `blocked-by: ADR-0077
    Accepted + implementation` (currently `now`).
  - `.claude/rules/comment_as_invariant.md` Related § appends
    "ADR-0077 (regalloc op scratch reservation)" once Accepted.
  - x86_64 mirror: x86_64 emit handlers currently don't show the
    same hardcoded scratch pattern (per `check_invariant_comments.sh`
    scope note), but the reservation API is per-arch and extensible.
    Phase 10+ x86_64 SIMD work that introduces op-internal scratch
    re-uses the same mechanism without ADR amendment.

## References

- ROADMAP §9.12-C (Q5 hygiene landings — D-133 sweep)
- ROADMAP §2 P1 (spec fidelity), P3 (defer rather than work around),
  P14 (substrate fixes preferred over runtime workarounds)
- ROADMAP §14 (forbidden list — "Single field serving two distinct
  semantic axes" anchors the abstraction-gap class)
- Related ADRs:
  - ADR-0018 (regalloc reserved set; precedent for the comptime
    disjointness check)
  - ADR-0060 (D-095 call-crossing force-spill — extends regalloc's
    PC-aware shaping; this ADR extends it further with op-tag
    awareness)
  - ADR-0071 §Q5 (Phase 9 substrate audit Q5 resolution; D-132/D-133
    are anchored here)
  - ADR-0072 (comment_as_invariant rule — this ADR makes the
    invariant code-level enforceable)
- Lessons:
  - `.dev/lessons/2026-05-16-regalloc-pool-scratch-overlap.md`
    (D-132 failure mode)
  - `.dev/lessons/2026-05-20-d133-sweep-pool-size-insufficient.md`
    (B119 outcome; live-scratch census + 3 paths)
- Code:
  - `src/engine/codegen/shared/regalloc.zig::compute` /
    `computeWith` (the slot assignment walker that gains the new
    fence check)
  - `src/engine/codegen/arm64/abi.zig` (host of the per-arch
    reservation table)
  - `src/engine/codegen/arm64/op_table.zig` +
    `src/engine/codegen/arm64/op_memory.zig` (the 5 bulk handler
    consumers)
- Scripts:
  - `scripts/check_invariant_comments.sh` (gate flip target post-impl)

## Revision history

| Date       | SHA          | Note                                                                                                                                                                          |
|------------|--------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-05-20 | `342554b2` | Initial Proposed version (B119 outcome).                                                                                                                                      |
| 2026-05-20 | `1bc9c09b` | User review → Status: Accepted. Implementation deferred to fresh session; spike-first per `.claude/rules/spike_lifecycle.md`; D-133 row updated to point at ADR-0077 impl. |
