# Optimisation log — Adopted / Rejected / Deferred ledger

> **Doc-state**: ACTIVE — load-bearing reference (Phase 9+ scope).

> **Tracker for optimisation candidates and decisions from Phase 8
> onward**. The Phase 7 baseline (interpreter + naive JIT) is the
> measurement zero; `bench/` hyperfine numbers are the adoption
> evidence.
>
> v1 had multiple "interpreter-was-actually-fast" data points
> (W43/W44/W45 family hoists, coalescer, address-mode folding,
> etc.). v2 captures these as **Adopted / Rejected / Deferred**
> rows so a later session never has to rediscover "we tried this
> and rejected it" — the W54-class regression we are explicitly
> structured to prevent.

## Edit rules

- One candidate = one row. Phase / cost estimate / expected gain
  / status / refs.
- Status is one of `Adopted` / `Rejected` / `Deferred` /
  `Investigating`.
- `Adopted` rows must cite the implementing commit SHA.
  `Rejected` rows must point at an ADR or lesson when the
  reasoning is reusable; lesson is mandatory if the rejection
  surfaces a non-obvious general principle.
- `Deferred` rows **must** include a concrete trigger condition
  (e.g. "when bench shows op X is hot", "after Wasm 3.0 SIMD
  proposal lands", "when FFI overhead exceeds 10%"). Vague
  "later" is not allowed.
- Add candidates **the moment you think of one**. Whether to
  implement is a separate decision; the ledger is also a
  brain-dump.

## Status semantics

`Investigating` is bounded — when it runs out of attention, it
must move to `Rejected` or `Deferred`. Three resume cycles in
`Investigating` and `audit_scaffolding §F` flags the row.

## Day-1 adopted (v2 foundation choices)

Optimisations that are **structurally baked into v2 from the
start**, codified in ROADMAP §2 (P/A principles) and the Phase 0-7
ADRs. These are not Phase 8+ candidates — they are the **baseline
that every candidate is measured against**.

| ID    | Area                | What was adopted                                                                       | v1 contrast                                  | Refs                                                  |
|-------|---------------------|----------------------------------------------------------------------------------------|----------------------------------------------|-------------------------------------------------------|
| F-001 | IR shape            | ZIR + day-1 `?Liveness` slot in `ZirFunc`                                              | v1 was post-hoc (W54 regression bedrock)     | ROADMAP §4.2 / §P13; ADR-0014                         |
| F-002 | JIT pipeline        | Single-pass JIT (parse → ZIR lower → regalloc → emit in one walk)                       | v1 was 4-pass                                 | ROADMAP §P6                                           |
| F-003 | Interp dispatch     | `while`-loop dispatch over ZIR, handlers via `DispatchTable.interp`                    | v1 was switch-based                           | `src/interp/dispatch.zig`; §9.6 close; #680            |
| F-004 | JIT register strat  | Reserved invariant GPRs (ARM64 X19-X28 / x86_64 R15) hold the runtime pointer          | v1 reloaded from `*Runtime` per op            | ADR-0017 (ARM64) / ADR-0026 (x86_64)                  |
| F-005 | Feature gate        | Dispatch table is mandatory — primary parser/validator/interp/emit never `@import` a feature module | v1 had scattered code + `if (feature_x)` branches | A12 forbidden list; `src/ir/dispatch_table.zig`        |
| F-006 | Trap stub strategy  | One trap stub per function + `bounds_fixups` shared by memory / sig / trunc-trap     | v1 had per-op trap stubs                      | `emit.zig:bounds_fixups`; ADR-0028 carries the per-reason split |
| F-007 | Memory model        | Instance arena allocator (bulk-free at instance close)                                 | v1 used per-allocation alloc/free             | ADR-0014 §6.K.3                                        |
| F-008 | ABI invariants      | Comptime ABI layout guards (`jit_abi.zig`'s `@compileError` for offset/alignment)      | v1 caught layout drift only at runtime        | `src/engine/codegen/shared/jit_abi.zig`                |
| F-009 | Encoder design      | Op families consolidated into parameterized helpers (`kind: SseScalarKind` + `opcode`) | n/a (new in v2)                               | `inst.zig:encSseScalarBinary` and friends             |
| F-010 | Value representation | `extern union { i32, i64, f32, f64, v128, funcref, externref }` (no NaN-box)         | Same as v1 (NaN-box rejection is intentional; see R-001) | `src/runtime/value.zig`; ADR-0014                     |
| F-011 | Slot model          | Separate GPR/FP regalloc pools + scratch reservations (ARM64 X16/X17, x86_64 RAX out-of-pool) | n/a (new in v2)                               | `src/engine/codegen/{arm64,x86_64}/abi.zig`            |
| F-012 | Edge-case fixtures  | Boundary cases pinned immediately under `test/edge_cases/p<N>/<concept>/<case>/`       | n/a (new in v2)                               | ADR-0020; `.claude/rules/edge_case_testing.md`         |

## Day-1 rejected (deliberately not adopted)

> **Rejection is conditional, not permanent.** Each row carries
> (a) the load-bearing reason for not adopting today + (b) a
> concrete re-evaluation trigger that, if it fires, forces a
> re-examination. Same discipline as `Deferred`: testable
> conditions only, no vague "later". `audit_scaffolding §F`
> flags rows missing a trigger.

| ID    | Subject                                                | Load-bearing rejection reason                                              | Re-evaluation trigger (re-open the question if this happens)                     | Refs                                                          |
|-------|--------------------------------------------------------|----------------------------------------------------------------------------|----------------------------------------------------------------------------------|---------------------------------------------------------------|
| R-001 | NaN-boxed `Value` (used by ClojureWasm and others)     | Wasm types are statically known after validation → no runtime tag is needed → `extern union` is the simplest correct encoding (NaN-box solves a problem v2 doesn't have). | (1) Wasm 3.0 GC proposal advances to phase 4 with operand-stack values that become runtime-type-erased; OR (2) profiling shows operand-stack bandwidth is hot AND a non-SIMD workload makes `sizeOf(Value)=16` visible as ≥ 5% overhead. Note SIMD-enabled builds gain nothing from NaN-box (v128 cannot fit). | F-010; ADR-0014; spec proposal phase tracking      |
| R-002 | v1's post-hoc address-mode folding (D116)              | v1 abandoned-then-reverted this. Day-1 ON in v2 is rejected.                | Phase 8 bench-driven re-evaluation — registered as O-001. Decide once `bench/results/history.yaml` covers `c_btree` and other mem-heavy fixtures. | v1 D116 post-mortem; O-001                                    |
| R-003 | Pervasive feature `if`-branching (`if cfg.simd_enabled`) | A12 forbidden list — feature dispatch must go through `dispatch_table.zig` to prevent W54-class contract drift. | A12 itself would have to be retracted via a §18.2 deviation ADR. **Effectively permanent**. | ROADMAP §A12; F-005                                           |
| R-004 | `std.Thread.Mutex` / `pub var` vtable / `std.io.AnyWriter` | §14 forbidden list — Zig 0.16 itself removed `std.Thread.Mutex` and friends; the rejection follows the language. | (1) Zig stdlib reverses course and reinstates `std.Thread.Mutex` over `std.atomic`; OR (2) Phase 14 (concurrency) requires a thread API integration where an explicit VTable struct is no longer sufficient. | §14 forbidden list; `.claude/rules/zig_tips.md`               |
| R-005 | Per-trap-reason individual stubs                       | Single shared stub + Diagnostic M3 (ADR-0028) for reason identification — smaller code size. | Bench shows the trap path is hot AND the M3 ringbuffer write overhead is materially heavier than a per-stub fast-path would be. Re-measure once M3-a-2 (D-022) lands. | F-006; ADR-0028; D-022                                        |
| R-006 | v1's D117 dual-entry self-call workaround              | v2 reserves `RegClass.inst_ptr_special` from Phase 7 onward; the structural cause is gone. | A spec change that breaks `inst_ptr_special` (e.g. tail-call proposal landing with a self-recursive ABI that conflicts) would re-open the question. | `src/engine/codegen/shared/reg_class.zig`; v1 D117 post-mortem; spec tail-call proposal |
| R-007 | Implicit error set sprawl (`anyerror!T` everywhere)    | Per-zone explicit `Error` enums prevent W54-class contract drift at the type level. | Zig stdlib pivots toward inferred error sets as the recommendation (currently it recommends explicit), OR a cross-zone API arrives where `anyerror` is unavoidable. | `.claude/rules/zig_tips.md` "inferred error sets"; ADR-0014    |
| R-008 | `usingnamespace` (deleted in Zig 0.16)                 | The Zig language itself removed it — non-adoption is **language-spec compliance**. | Zig reintroduces `usingnamespace` in some new form. **Effectively permanent**. | `.claude/rules/zig_tips.md`                                   |

**Reading guide — R-001 (NaN-box) walk-through:**
- Today's reason: types are statically known after validation. That alone is sufficient. The earlier draft listed three reasons (memory density, static types, debug difficulty) — only the middle one is load-bearing; the other two were padding.
- Trigger (1): Wasm 3.0 GC is currently at spec phase 3, so the trigger stays cold until phase 4. Reaching phase 4 obligates a re-examination.
- Trigger (2): hooks into the bench-driven adoption process (Phase 8+). Without bench data, the trigger cannot fire.
- Both triggers are currently inactive → the row stays `Rejected`. `audit_scaffolding` is responsible for flipping the row to `Investigating` if either trigger fires.

**Discipline for rejection reasons:** when listing the reasoning,
**name the single load-bearing reason explicitly** — don't pad
with weaker arguments. If three reasons are listed in parallel, a
later reader can't tell which one is the actual gate. Move the
weak ones to "Refs". The R-001 first draft made this mistake; the
rule above codifies the correction.

## Naming

- `F-NNN` (Foundation) — adopted on day 1; implementation is
  done, design is locked.
- `R-NNN` (Rejected pre-emptively) — explicitly not adopted on
  day 1. When a re-evaluation trigger fires, the row is mirrored
  into the candidate table as `O-NNN` `Investigating` (e.g.
  R-002 ↔ O-001).
- `O-NNN` — Phase 8+ candidates. See the table below.

## Candidate table

| ID    | Phase  | Candidate                                                                                       | Cost est.           | Expected gain          | Status          | Refs                                          |
|-------|--------|--------------------------------------------------------------------------------------------------|---------------------|------------------------|-----------------|-----------------------------------------------|
| O-001 | 8 / 15 | Address-mode folding (fold immediate disp into store/load LEA; abandoned in v1 D116)             | 2–3 day             | 5–10% on mem-heavy benches | `Investigating` | v1 D116 post-mortem; R-002; bench `c_btree`   |
| O-002 | 8      | x86_64 regalloc port (slot reuse + parallel-move; resolves D-029)                                | 1 week              | 3–5% on hot loops      | `Deferred`      | D-029; `7.7-regalloc` not yet started; F-011 |
| O-004 | 8 / 15 | Inline cache for cross-module `call` (after D-026 resolution)                                    | 3–4 day             | 10–20% if call-heavy    | `Deferred`      | D-026; trigger = cross-module bench landing  |
| O-005 | 11+    | AOT compilation pipeline (cranelift backend or in-house emitter? — ADR required)                 | 2–3 weeks           | 30–50% startup-after-warm | `Deferred`      | ROADMAP §11; trigger = Phase 10 close        |
| O-006 | 15     | Liveness-aware regalloc (W54 mirror; v2's day-1 ZIR substrate is the prerequisite)               | 1 week              | 5–10% (regalloc-dependent) | `Deferred`     | ADR-0014 §6.K.5; trigger = after O-002       |
| O-007 | 8      | `i32.shr_s/u` with constant rhs → fused IMM form (current is MOV+SHR; v1 observed this hot)      | 1 day               | 2–5% on shift-heavy code | `Investigating` | bench: `rust_sha256` (shift dense)            |
| O-008 | 8      | Memory bounds-check coalescing (merge consecutive accesses into one check; v1 D43)               | 3 day               | 10–30% on mem benches  | `Deferred`      | trigger = Phase 8 mem-bench landing          |
| O-009 | 11+    | Multi-value (Wasm 1.1) direct support (currently single-result `UnsupportedOp`) — Wasm 3.0 ride  | varies              | feature completeness   | `Deferred`      | spec proposal phase 4; ROADMAP §11           |
| O-010 | 15     | Loop unrolling for tight numeric kernels (v1 W45)                                                | 1 week              | 5–15% on kernel benches | `Deferred`     | trigger = fixed-size loop pattern detection  |

## Candidate-row template

```
| O-NNN | <Phase> | <one-line description — what is being optimised> | <day/week unit> | <%> | `Investigating`/`Deferred`/`Adopted`/`Rejected` | <links> |
```

## Phase 7 close checklist (before transitioning to Phase 8)

When Phase 7 closes (= every §9.7 row marked [x]), the
`audit_scaffolding` skill inspects this log against:

1. **Debt × optimisation crossover**: every row in `.dev/debt.yaml`
   must either map to a specific `O-NNN` here, or be tagged as
   "structural defect, not an optimisation". Eliminate
   duplicates — make one a pointer to the other.
2. **Phase 7 prerequisites met**: x86_64 baseline + 3-host gate
   + bench infrastructure are now in place, so Phase 8
   candidates must move to `Adopted` only on **bench-numbers-
   driven** evidence (no gut-feel adoption — the load-bearing
   `Investigating` labels on O-001 / O-007 are exactly this
   discipline).
3. **Design clutter check**: with AOT, Wasm 3.0, WASI extensions,
   and SIMD all on the horizon, every adopted optimisation must
   not break the `src/engine/` zone layering (e.g. O-005 AOT
   already has its slot at `engine/codegen/aot/`; O-008
   bounds-check coalescing belongs in `ir/analysis/`; both
   landing zones are pre-reserved).

## ID conventions

- `O-NNN` is monotonically assigned. Rows are not deleted even
  after `Rejected` — keep them so future maintainers can see
  "we tried this before". Same operating model as `D-NNN` in
  `.dev/debt.yaml`.
- `F-NNN` and `R-NNN` follow the same retention rule.

## Related files

- `.dev/debt.yaml` — structural debt (act-now / blocked-by). Not
  optimisation; defect repair.
- `.dev/lessons/INDEX.md` — observational notes. `Rejected`
  rationales that are reusable as principles should land here
  with an `O-NNN` / `R-NNN` cross-pointer.
- `bench/results/history.yaml` — measured data. `Adopted` rows
  must record before/after numbers here.
- `.dev/decisions/` — when an `Adopted` row carries a load-
  bearing design choice (rejected alternatives matter), file an
  ADR.
