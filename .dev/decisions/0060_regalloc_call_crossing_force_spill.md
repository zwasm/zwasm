# 0060 — Force-spill call-crossing vregs in the regalloc

- **Status**: Closed (implemented)
- **Date**: 2026-05-14
- **Author**: zwasm-from-scratch /continue autonomous loop (D-093 d-16)
- **Tags**: regalloc, call-abi, mvp

## Context

`src/engine/codegen/shared/regalloc.zig:compute` is a linear-scan,
first-fit allocator. Slot ids are minted sequentially (0, 1, 2, …);
the per-arch `slotToReg` / `fpSlotToReg` maps `slot < max_reg_slots_*`
to a physical register and higher ids to a stack spill slot. The
arch-blind id space lets the same allocator drive both backends.

The JIT prologue (arm64: `src/engine/codegen/arm64/emit.zig:325`+;
x86_64: analogous) loads runtime invariants into the AAPCS64
callee-saved bank (X19..X28) but does **not** save them; it relies on
the entry stub having already followed AAPCS64 across the C-host
boundary. The body then uses `allocatable_gprs = caller-saved scratch
∪ callee-saved` as the regalloc's slot pool:

- arm64: `allocatable_gprs = X9..X13 ∪ X20..X22` (8 slots).
- x86_64: `allocatable_gprs = ∅ ∪ {RBX, R12, R13, R14}` (4 slots).

At a JIT-to-JIT `call` / `call_indirect`, or at the `memory.grow`
runtime callout (ADR-0059), the called function's prologue overwrites
the callee-saved bank without saving the caller's prior contents. The
caller's vregs whose live range strictly contains the call PC therefore
read garbage after the call. D-093 (d-15) repro: `if.wast :
as-compare-operand` exercises a compose-of-two `if (result f32)`
expressions whose first `if`'s merge vreg is live across a `call $dummy`;
the regalloc places it in X9 (caller-saved on arm64) and the call
clobbers X9 → consumer reads garbage. `compose_no_call.wat` (no
intervening calls) passes; the symptom is call-induced. D-095 captures
the design gap.

The same shape exists on x86_64: even though every `allocatable_gpr`
is SysV-callee-saved, the JIT callee does not save them either, so
RBX / R12 / R13 / R14 are clobbered by an inner JIT call when its
own body reuses the slot.

## Decision

Treat any vreg whose live range strictly contains a call PC as **force-
spilled**: assign it a slot id ≥ the per-arch `force_spill_threshold`
(= `allocatable_gprs.len`), so the per-arch `slotToReg` resolves it to a
`.spill` stack slot. The vreg's value lives only in memory across the
call. STR-before-call and LDR-after-call already exist as the standard
spill-class emit path; no per-arch code changes needed.

Implementation: extend `regalloc.compute` to (a) pre-scan
`func.instrs.items` collecting PCs of `.call`, `.call_indirect`,
`.@"memory.grow"`; (b) for each vreg compute
`spans_call := ∃ call_pc with r.def_pc < call_pc < r.last_use_pc`; (c)
when allocating, partition the slot id space into "register slots"
(`< threshold`) and "spill slots" (`≥ threshold`) with independent
mint counters and free-pool scans. spans_call vregs mint and reuse
spill slots only; non-spans_call vregs prefer register slots, fall
back to spill slots if the register pool is exhausted. The caller
(`compile.zig`) passes the per-arch threshold (arm64 = 8, x86_64 = 4).

Strict inequality on both sides of `def_pc < call_pc < last_use_pc` is
deliberate. When the call IS the vreg's last_use, the value is read
into the arg register before the BLR/CALL clobbers anything (so the
vreg is safe). When the call IS the vreg's def_pc (= call result), the
value is materialised post-call from X0/X1 or RAX/RDX (= no pre-call
register state to preserve).

## Alternatives considered

### Alternative A — Prologue-side callee-saved save/restore

- **Sketch**: Each JIT function's prologue pushes the callee-saved
  registers it actually uses (`STP X20, X21, [SP, #-16]!`, …; `push rbx`,
  …); epilogue reverses. Then regalloc can place call-crossing vregs in
  callee-saved slots safely.
- **Why rejected (for d-16)**: invasive — touches prologue + epilogue
  on both archs, needs per-function save-mask tracking, needs frame-
  size adjustment, needs interaction with the existing `frame_bytes`
  SUB SP path (arm64) and the AAPCS64 16-byte SP-alignment invariant.
  ~500 LOC across two backends. Phase 8b bench-driven optimisation work
  is the right home — this MVP (Option C) buys correctness now and lets
  Phase 8 evaluate whether the save/restore cost actually wins back the
  spill-slot cost on real workloads.

### Alternative B — Caller-side save/restore around each call (v1)

- **Sketch**: At each call site, emit explicit STR for every caller-
  saved live vreg before the call, LDR after. v1's `spillCallerSaved`
  (`~/Documents/MyProducts/zwasm/src/jit.zig`) takes this approach.
- **Why rejected**: O(live_vregs × call_sites) emit cost; duplicates
  spill machinery in the per-arch emit. The regalloc-side force-spill
  is one pre-pass and one allocation tweak, with zero per-call emit
  cost — and the existing spill emit path already handles
  STR-before-use / LDR-before-use for spill-class slots naturally.

### Alternative C (= chosen) — Force-spill call-crossing vregs

- **Sketch**: above.
- **Why chosen**: smallest correct fix; arch-agnostic; reuses existing
  spill emit; leaves room for Phase 8 to evaluate save/restore variants
  empirically.

## Consequences

- **Positive**:
  - Closes D-095 with a ~120 LOC change in `shared/regalloc.zig` + a
    one-line `compile.zig` change. No per-arch emit churn.
  - Fixes the 5 residual `if.wast` failures on arm64
    (`as-compare-operand{s}`, `param-break`, `params-break`, plus the
    last `as-compare-operand` not yet in the regression set).
  - x86_64 picks up the same correctness fix for compose-of-2 with
    intervening calls (currently latent — the surfaced spec corpus
    doesn't exercise it on x86_64, but the same vreg-clobber shape
    exists when an inner call reuses RBX as its own slot 0).
- **Negative**:
  - Spans-call vregs always go through memory: +1 STR (post-def) + 1
    LDR (pre-last-use) per vreg. For compose-of-2 patterns this is one
    extra pair per inner-result. Negligible vs the call overhead.
  - n_slots can grow slightly faster (the register / spill id ranges no
    longer share; if a function has k spans-call vregs in a tight loop,
    spill region grows by k × 8 bytes). The verifier's existing
    `slot_id < n_slots` invariant still holds; no max_slots overflow at
    Phase 9 sizes (validator caps operand stack at 1024).
- **Neutral / follow-ups**:
  - Phase 8b bench-driven follow-up: ADR for prologue-side callee-saved
    save/restore (Alternative A). Trigger: when bench shows force-spill
    cost is material on real workloads.
  - The call-PC pre-scan currently considers only `.call`,
    `.call_indirect`, `.@"memory.grow"`. Future runtime callouts (e.g.
    `.table.grow` if it ever becomes a callout rather than inline)
    extend the list.
  - The per-arch `force_spill_threshold` is the same constant as the
    existing `Allocation.max_reg_slots_gpr`. A future refactor can
    collapse them; today they stay separate so the compute-pass
    parameter remains independent of the post-compute override path.

## Amendment (2026-05-31): alloc-op operand force-spill (10.G GC-on-JIT)

The original Decision force-spills a vreg whose live range **strictly**
contains a call PC: `r.def_pc < cp and cp < r.last_use_pc`. The strict
upper bound is justified (§Decision ¶4) because when the call IS the
vreg's `last_use`, the value is read into its arg register *before* the
BLR/CALL clobbers anything.

The 10.G GC-on-JIT `struct.new` emit breaks that justification for its
own **field operands**. Unlike a `call`, `struct.new` does not consume
its operands into arg registers before the clobbering CALL. Its emit
sequence is: marshal `rt`+`typeidx` → CALL `jitGcAlloc` (clobbers
caller-saved) → **then** store each popped field into the freshly
allocated object. The field operands are therefore read *after* the
internal alloc CALL, so a field vreg whose `last_use` IS the
`struct.new` PC must survive the CALL in memory — exactly the case the
strict `<` excludes.

**Decision extension**: classify the alloc CALL ops (`struct.new`, and
future `array.new` / `array.new_fixed` with post-CALL operand reads) as
a distinct **inclusive-alloc-op** category in the `spans_call` pre-scan.
For PCs in that category the crossing test is `r.def_pc < cp and cp <=
r.last_use_pc` (inclusive upper bound). The inclusive predicate is a
strict superset of the original: it additionally catches vregs whose
`last_use == cp` (the field operands), while still catching every
strictly-spanning unrelated vreg (since `cp < last_use ⟹ cp <=
last_use`). A vreg with `last_use == cp` can only be an operand the op
pops (two instructions never share a PC), so the inclusive rule spills
precisely the field operands plus the genuine spanners — no
over-spill of unrelated values.

`struct.new_default` (added to the `is_call` set at A-2, cyc248) stays
in the **strict** category: it has zero field operands, so no vreg has
`last_use` at its PC, and strict-vs-inclusive is a no-op for it. Keeping
it strict documents that the inclusive widening is load-bearing only for
ops with post-CALL operand reads.

Implementation: `regalloc_compute.zig` `computeWith` — the callout
pre-scan now records each call site's category (strict vs inclusive) and
`spans_call` branches on it. No per-arch emit change; the existing
spill-class STR-before / LDR-after path carries the spilled field vregs
across the alloc CALL exactly as it carries any other force-spilled
value. Design grounded in `.dev/phase10_g_op_bundle_plan.md` §"Cycle
A-3".

## References

- ROADMAP §9.9 / 9.9-l-1b-d093-d16
- D-095 (`.dev/debt.md`) — discharge plan referenced in this ADR.
- D-094 (related) — x86_64 multi-result MEMORY-class (different gap;
  same area).
- ADR-0017 (X19 = runtime_ptr_save_gpr, the one register the prologue
  *does* preserve via re-load from JitRuntime).
- ADR-0027 (allocatable_caller_saved_scratch_gprs / allocatable_callee_
  saved_gprs split).
- ADR-0059 (memory.grow callout — defines the third call site this
  pre-scan covers).
- `src/engine/codegen/shared/regalloc.zig:compute`,
  `src/engine/codegen/shared/compile.zig:177`.
- v1 reference: `~/Documents/MyProducts/zwasm/src/jit.zig` `spillCallerSaved`
  (Alternative B, rejected).

## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-14 | `5ccae2cd` | Initial accepted version (d-16).        |
| 2026-05-31 | `fb73a87b` | Amendment — alloc-op operand force-spill (10.G GC-on-JIT). Inclusive upper-bound `cp <= last_use_pc` for `struct.new` (post-CALL operand reads); `struct.new_default` stays strict. |

## Revision 2026-10-17 — x86_64 threshold

The threshold is `max(gpr pool, fp pool)` (`compile.zig`): 8 on both arches
since #503 (x86_64: eight GPRs, six XMMs). The pool lists under Context are
as of the decision. A last use at the call stays safe on x86_64 because the
marshal is a parallel move: the pool now holds argument registers.
