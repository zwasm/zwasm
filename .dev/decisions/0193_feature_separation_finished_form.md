# ADR-0193 — Feature-separation finished-form: unify the WASI version axis + reify component-P2/P3 as registration

- Status: **Accepted** (USER-steered design + decisions, 2026-06-16). User resolved both open questions and
  granted full autonomy to plan + execute the migration: **(a) hard-remove `-Dcomponent`** (no alias);
  **(b) single-axis Option A** (no component-without-WASI target). **Default = `p2` interim**, NOT `p3` yet:
  p3 (WASI Preview-3 async) is core-green but not settled (Unit E/F host breadth — sockets/http async —
  incomplete, D-335). The p2 stage measures the blast-radius + de-risks the eventual `p2 → p3` default flip
  (one-line + the old-default-assuming sites rewritten in one go, per user). This is a §4
  architecture change the user explicitly asked to *design before coding*.
- Date: 2026-06-16
- Deciders: user-flagged (debt D-462); investigation loop-executed
- Relates: ADR-0181/0182 (build flags), ADR-0023 §3 (feature `register()` pattern), ADR-0129 (binary-size
  dispatch gating), ADR-0187-0191 (CM-async / P3). ROADMAP §4.6 (feature flags) — this is a §4.6 deviation, so
  the ADR precedes any code per §18.

## Context

The maintainer once carefully separated runtime features at build time + runtime. As WASI Preview-2 (Component
Model) then Preview-3 (async, D-335) landed, the separation eroded. The **finished-form preference** (lesson
`feature-separation-finished-form-preference`, user-stated) ranks the *mechanism* of separation, LEFT = more
finished:

> **directory > file (declared metadata + central comptime collector) > function-cluster (one boundary) >
> comptime/runtime `if`-branch (`分岐散り`, least finished).**

Not every branch is a defect — some are genuinely unavoidable. The task is to tell the true finished form from the
unavoidable, and migrate realistically.

### Current state (investigation 2026-06-16, debt D-462)

Per-axis finished-form grade + biggest erosion:

| Axis | Grade | Mechanism today | Biggest erosion |
|---|---|---|---|
| Wasm spec level | B (good) | dir `src/instruction/wasm_{1,2,3}_0/` + per-file `wasm_level` metadata + central `dispatch_collector` | 9 conditional feature-module imports in `api/instance.zig:39-52` |
| Engine | B+ (clean) | dir `src/interp/` + `src/engine/codegen/{arm64,x86_64}/`; selected at instantiation | none |
| GC | B (placeholder) | `src/feature/gc/register.zig` (`enable_gc` + `register()`) | none yet (flag not scattered) |
| **WASI version** | **D+ (eroded)** | P1 in `src/wasi/`; **P2/P3 host in Zone-3 `src/api/component_wasi_p{2,3}.zig`, NOT in the metadata/registration scheme**; `WasiLevel={none,p1,p2,both}` has **no p3** | P2/P3 unselectable as versions; gated by a *separate* `-Dcomponent` bool |
| **Component** | **D (eroded)** | Zone-1 decoder walled in `src/feature/component/`, but Zone-3 orchestration sprawls (`api/component*.zig`); `-Dcomponent` bool gates it via a CLI runtime check (`cli/main.zig:296`) | two flags (`-Dwasi=p2` AND `-Dcomponent`) gate P2; contradictory combos unvalidated |

**Scattered `build_options.*` branch sites (≈11)** — classification:
- **Genuinely UNAVOIDABLE (~6)**: parser byte-level version gates (`parse/sections.zig` memory64 idx-type, EH tag
  section); CLI `--version` display (`cli/main.zig`); JIT-trace diagnostics (`entry.zig`, `platform/stack_limit.zig`);
  the interp subtype-accept arm (`interp/mvp.zig`, already size-gated per ADR-0129). These read a flag at a point
  where no structural boundary can exist (wire-level / display / diagnostic). **Accept as-is.**
- **STRUCTURALISABLE (~4-5)**: the `api/instance.zig` conditional feature imports → directory/registration
  discovery; the memory64 i64 emit path (`codegen/{arm64,x86_64}/op_memory.zig`) is already a full sub-emitter
  (`emitMemOpI64`) → move to a function-cluster `op_memory_i64.zig` registered by build predicate.

## Decision (target finished form)

**Single ordered WASI version axis, with the component runtime as its P2+ substrate, gated by a comptime
`wasi_level` predicate at the feature boundary** (NOT a dispatch-table `register()` — see §3 revision).

1. `WasiLevel = enum { none, p1, p2, p3 }` — an **ordered tier** (drop the `both` wildcard; `p3 ⊇ p2 ⊇ p1`).
   Dispatch filter becomes `need > build_level → drop` (remove the `!= .both` special case at
   `dispatch_collector.zig:120`). **Default = `p2`** (preserves today's "component default-ON" capability,
   `p2 ⊇ p1`); the `p2 → p3` default flip is deferred until p3 host-breadth (Unit E/F) settles.
2. **The component runtime is gated by `wasi_level >= p2`, not a separate `-Dcomponent` bool.** P2 *is* the
   component substrate here; P3 = P2 + async. `-Dcomponent` is **hard-removed** (user decision (a): no
   deprecated alias — an alias would preserve exactly the two-flag `分岐散り` this ADR exists to kill). This
   eliminates the two-flag overlap + the contradictory-combo class.
3. **Gate the P2/P3 host by a comptime `wasi_level` predicate at the feature boundary** — NOT a dispatch-table
   `register()`. **REVISED 2026-06-16 after the P2 survey**: the `src/feature/gc/register.zig` model does NOT
   fit WASI. GC `register()` installs static IR-op handlers into the Zone-1 `DispatchTable` singleton; WASI host
   imports resolve **by-name at instantiation** (`buildWasiP2Component`, Zone-3, per-run resource-handle tables),
   so there is no global-registration analog — a `wasi_p2/register.zig` would be an empty mirror, and Zone 1
   (`src/feature/`) cannot reference the Zone-3 `Linker`/`Instance` the host wiring needs. The real reification:
   (i) a single comptime predicate `build_options.wasi_level >= .p2` replaces the separate `enable_component`
   bool everywhere (so build-time gate == runtime reachability — kills the two-flag erosion); (ii) the async/P3
   host (`api/component_wasi_p3.zig` + `feature/component/async.zig`) compiles **only** under
   `wasi_level >= .p3`, the component/P2 host only under `>= .p2` — replacing today's runtime export-shape
   P2-vs-P3 dispatch's *always-compiled* state, so a p2 build emits zero p3-async symbols (DCE-assertable). The
   Zone-1 `feature/component/` decoder is unchanged; only the gate axis + comptime fences move.
4. **Structuralise the ~4 cheap branch sites** (instance.zig imports → registration; memory64 emit →
   `op_memory_i64.zig`); **explicitly accept the ~6 unavoidable** ones (document each with a one-line "why
   unavoidable" so future audits don't re-flag them).

## Consequences

- One coherent axis: build-time `-Dwasi` and runtime reachability agree; no `-Dwasi=p1 -Dcomponent=true`
  contradiction; P3 finally selectable. Component-import version checks become a single predicate.
- **Breaking build-flag change** (`-Dcomponent` removed/aliased; `WasiLevel` values change) — acceptable on this
  pre-release v2 branch (ADR-0156 surfaces are breakable), but it touches `build.zig`, `dispatch_collector`, CLI,
  and the component runner wiring (~5-8 files).
- Moves WASI/component from grade D → B (file-tier registration), matching the Wasm-level axis.

## Realistic phased migration (cheap + de-risking first; each phase independently green)

1. **P1 — `WasiLevel = {none,p1,p2,p3}` ordered tier + default `p2`** (no `both` alias — drop it outright since
   every `.both` site is in-tree and migrated same-commit): collector filter becomes `need > cur` (drop the
   `!= .both` special case). Default flips `p1 → p2`. Lowest-risk structural step; unblocks p3 selectability.
   The build-combo scripts (`gate_merge.sh`, `check_build_dce.sh`) keep working unchanged (they enumerate
   `p1`/`p2`, both still valid). NOTE (discovered during P1): the p3 host (`component_wasi_p3.zig`/`async.zig`)
   is **currently NOT `wasi_level`-gated** — it rides on `enable_component` (`component.zig:556`), so p3 symbols
   ship in any `-Dcomponent=true` build regardless of `-Dwasi`. That ungated state IS the WASI-D+ erosion; the
   `wasi_level >= p3` gate + the matching `check_build_dce` p3-forbidden assertion (a p2 build has no p3-async
   symbols) land in **P2/P3** once the gate exists, NOT in P1.
2. **P2 — fold `enable_component` into `wasi_level >= .p2`** (REVISED per survey — NOT a `register()` reify).
   Derive the gate from the tier: in `build.zig`, `enable_component = @intFromEnum(wasi_level) >= @intFromEnum(.p2)`,
   and **hard-remove the `-Dcomponent` b.option**. `enable_component` survives only as the internal derived
   `build_options` bool the existing `comptime` fences already read (`src/zwasm.zig:170`, `cli/main.zig:296`) —
   so those sites are untouched; only their *source of truth* changes from a flag to the tier. Rewrite the
   old-default-assuming consumers in one go: `record_binary_size.sh` (lean = `-Dwasi=p1`, was `-Dcomponent=false`),
   `build.zig` comp_options (`core_comp` forces `enable_component=true` → forces `wasi_level=.p2` floor instead).
   Behaviour-preserving at default (p2 ⇒ component on, == today). Characterization: WASI/component corpus 158/0/0
   pinned every commit.
3. **P3 — comptime-fence the p3/async host on `wasi_level >= .p3`**: add the derived `enable_wasi_p3`
   `build_options` bool; `comptime`-gate `api/component_wasi_p3.zig` + `feature/component/async.zig` imports
   (`component.zig:556`, `zwasm.zig:413`) on it so a p2 build emits **zero** p3 symbols. Then add the
   `check_build_dce` p3-forbidden assertion (a `-Dwasi=p2` build has no `wasi_p3_`/async symbols) + extend its
   matrix to p3. **STRUCTURAL WRINKLE (found 2026-06-16)**: the unified entry `runWasiMain` (the P2+P3 surface the
   CLI/embedders call) currently LIVES IN `component_wasi_p3.zig:70` — fencing that whole file out under p2 would
   also remove the P2 *sync* entry. So P3 first RELOCATES `runWasiMain` + the sync dispatch to a P2 home
   (`component_wasi_p2.zig` / `component.zig`), leaving ONLY genuinely-async code (`driveAsyncMain`,
   `P3CallbackCtx`, `runWasiP3Main`, `waitOn`) in the p3 file; the relocated `runWasiMain`'s async branch is
   `comptime enable_wasi_p3`-gated so the p3 file is referenced only when enabled. This is the erosion's true
   close: build-time `-Dwasi` finally agrees with runtime reachability.
4. **P4 — structuralise judgment + doc sync** (bundle close): **(b) doc sync DONE** — every user-facing /
   CWFS-handoff `-Dcomponent` reference rewritten to the `-Dwasi` axis (`README`, `docs/zig_api_design.md`
   §3.8/§3.9, `migration_v1_to_v2`, `handoff_cw_v{1,2}`, `ROADMAP`, `record_binary_size`/`size_history`); also
   fixed pre-existing post-0182 "opt-in/default off" staleness. **(c) CWFS handover DONE** — the handoff_cw docs
   carry the new default; CWFS passes neither flag (defaults only) so the `p1 → p2` change flows in on its next
   SHA-pin bump (no CWFS edit needed; lean = `-Dwasi=p1`). **(a) structuralise — RECONSIDERED & SCOPED DOWN**: the
   original "extract `op_memory_i64.zig`, discover instance.zig imports" was over-reach. Per the `file_size_smell`
   discipline, `emitMemOpI64` (~130 LOC, shares arm64/x86_64 emit helpers, host file 1219/2000 LOC) extraction
   would force an **N2 helper pub-leak** with no P1 (sub-300-LOC) and no file-size pressure → **kept inline**. The
   `instance.zig` `ext_* = if (wasm_N_enabled) @import(...)` block is **already a clean file-tier feature manifest**
   (one central comptime predicate + directory-resident modules), NOT `分岐散り` → annotated, not refactored. The
   ~6 genuinely-unavoidable sites (parser byte-level version gates, CLI `--version` display, JIT-trace diagnostics,
   interp subtype-arm) are accepted as-is with a one-line "why" so future audits don't re-flag them. **Finished-form
   verdict**: the WASI/component axis (the eroded D+/D) is the substantive fix (P1-P3); the Wasm-level sites were
   already B/B+ and forcing extractions on them fails the project's own smell test.

Correctness-first (ADR-0153): each phase keeps the full WASI/component/spec corpora green; P2's behaviour-
preservation is pinned by characterization before the move.

## Open questions — RESOLVED (user, 2026-06-16)

- **(a) Keep `-Dcomponent` as a deprecated alias, or hard-remove?** → **HARD-REMOVE.** An alias retains the
  two-flag branch this ADR exists to eliminate; pre-release v2 surfaces are breakable (ADR-0156).
- **(b) Is a pure component-model-without-WASI build a real target?** → **NO.** Single-axis Option A. zwasm has
  no such consumer; `-Dwasi` is the sole axis with the component runtime as its P2+ substrate.
- **Default p2 vs p3?** → **p2 interim.** p3 async core is green but Unit E/F host breadth is incomplete; flip to
  p3 default once it settles. The p2 stage's measured blast-radius is the de-risking input for that flip.

## Retrospective (V) — all four phases landed 2026-06-16

- **Hit the 完成形 bar?** Yes for the substantive axis. WASI went **D+ → B** and component **D → B**: one ordered
  `-Dwasi` axis now gates everything (build-time == runtime reachability), the two-flag contradiction class is
  gone, and a p2 build emits **zero** p3-async symbols (DCE-gated). Wasm-level sites (already B/B+) were left as
  clean file-tier manifests after a smell-test check (P4a).
- **Verified deltas**: P1 `eb43d8af` (tier+default p2), P2 `3a2c2c36` (gate fold, `-Dcomponent` removed),
  P3 `888585e2` (async comptime-fence + `test-wasi-p3`) + DCE `888585e2`-area, P4 doc-sync + judgment. Throughout:
  component corpus **158/0/0**, default unit suite green (2917/2929; 28 async tests moved to `test-wasi-p3`),
  `check_build_dce` v3_0:p2 clean / p3 +2232 B. ubuntu green each cycle.
- **New debt / residual**: ONE — flip the default `p2 → p3` once WASI-0.3 Unit E/F host breadth settles (tracked
  under **D-335**, gated, not urgent). The p2-interim blast-radius measured here (the consumer-rewrite set:
  `record_binary_size`, comp_options floor, docs) is the de-risking input for that one-line flip.
- **Superseded**: ADR-0182's `-Dcomponent` flag is removed; ADR-0181/0182 wording about the separate component
  axis is superseded on this branch (the flag no longer exists; component == `-Dwasi>=p2`).

## Revision history

| Date       | SHA          | Note |
|------------|--------------|------|
| 2026-10-31 | —            | The default flips `p2 → p3` for 2.10.0 (PR #673), discharging D-335 (ADR-0205 settled the host breadth); `test-wasi-p3` becomes `test-wasi-p2`, the unit suite of the `-Dwasi=p2` opt-out build. |
