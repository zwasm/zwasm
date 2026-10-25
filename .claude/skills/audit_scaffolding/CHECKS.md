# audit_scaffolding — checks

> Run the checks in order. Classify each finding as `block` / `soon`
> / `watch` (see SKILL.md). Output `private/audit-YYYY-MM-DD.md`.

## A. Staleness checks

### A.1 Dead file references

For each markdown file under `.dev/`, `.claude/` (incl. `.claude/CLAUDE.md`),
`README.md`:

- Extract every `(./path)` and `path/to/file` reference.
- For each, check `test -e <path>`.
- Flag missing as `block` (CLAUDE.md / ROADMAP.md) or `soon` (others).
  The frozen `.dev/handover.md` (#207 plank 4) is exempt: its
  campaign-era references may rot in place — no findings against it.

### A.2 Dead SHA references

In `.dev/decisions/*.md` (the frozen handover.md is exempt — its SHAs
are historical):

- Extract `[a-f0-9]{7,40}` patterns that look like SHAs.
- For each, run `git cat-file -t <sha>` and flag if not present.

### A.3 Phase tracker drift — RETIRED

`.dev/handover.md` froze 2026-08-20 (#207 plank 4); it no longer claims
a current phase / task, so there is nothing to cross-check. Current
state = open PRs and issues.

### A.4 ROADMAP-amendment ↔ ADR coverage

For each ROADMAP edit landing in the last 10 commits:

- Per ROADMAP §18, an ADR is required for amendments to §1, §2, §4,
  §5, §9 phase rows, §11 layers, §14 forbidden list.
- Check the commit message references an ADR.
- Flag commits that touch those sections without an ADR reference
  (`block`).

### A.5 Proposal-watch freshness

`.dev/proposal_watch.md` has a "Last reviewed" date. If it's more
than 90 days old, flag `soon`.

## B. Bloat checks

### B.1 File-size hard cap

`bash scripts/file_size_check.sh`. Hard cap (>2000 lines) is `block`.
Soft cap (>1000 lines, no ADR for split plan) is `soon`.

### B.2 Markdown bloat

For `.dev/*.md`, `.claude/**/*.md`:

- Files > 800 lines: `soon` (consider splitting into multiple files
  or moving content to ADRs).
- Files > 1500 lines: `block` (must split). ROADMAP.md is the
  intentional exception — it is large by design.

### B.3 Duplicated facts

Pairwise diff of "principles" / "rules" / "phase plan" between:

- `CLAUDE.md` vs `.dev/ROADMAP.md`
- `.claude/rules/zone_deps.md` vs `.dev/ROADMAP.md` §A1

Drifted duplication → `soon`.

### B.4 Skill instruction bloat

`.claude/skills/*/SKILL.md` > 500 lines: `soon`. Skills should be
short procedures, not narratives.

## C. Lies / absolute claims

### C.1 "Always X" / "Never Y" statements

```
grep -E '^\s*(- \*\*)?(Always|Never|All)' \
    .dev/ROADMAP.md .claude/rules/*.md .claude/CLAUDE.md
```

For each absolute claim, verify it holds:

- "Tests must pass on three hosts" — does the pre-push hook
  enforce it?
- "All public functions have `///`" — sample check.
- "ZirOp is u16" — does `src/ir/zir.zig` confirm?

Failed claim → `block`.

### C.2 "Phase N delivers X"

For each "Phase N delivers ..." in ROADMAP §9, check:

- Does the §9.<N> task list still produce that?
- Has the ADR table for that phase changed?

Drift → `soon`.

## D. False positives

### D.1 Rule path matchers

`.claude/rules/*.md` front-matter has `paths:`. For each rule:

- Run `find <pattern>` to confirm matched files exist.
- Flag rules whose patterns match no files (`watch`).

### D.2 Pre-commit / pre-push hooks

`.githooks/pre_commit` / `pre_push` should fail only on real issues.
If a developer reports a false positive, capture in `private/audit-*`
as `block` until fixed.

### D.3 zone_check.sh — periodic enforcement (per ADR-0076 D4)

Per ADR-0076 D4, `zone_check.sh --gate` is **no longer in
pre-commit** (cost ~100 s per invocation). audit_scaffolding now
owns periodic enforcement:

```sh
bash scripts/zone_check.sh --gate
```

Any non-zero exit is a `block` finding. For info-mode false
positives (e.g. test code crossing zones legitimately), still
flag as `block` if the rule itself is wrong. The full-gate
mode (manual `bash scripts/gate_commit.sh` without `--fast`)
also re-runs zone_check as the manual-commit safety net.

Cadence: every audit_scaffolding invocation (phase boundary
+ opportunistic). Future follow-up: zone_check.sh itself
should be rewritten to drop the per-file awk+grep+cd
subshell fork (currently the cost driver); once it lands
< 5 s, it can return to pre-commit.

## E. Cross-section consistency

### E.1 ROADMAP self-consistency

- §3.1 "in scope" ↔ §9 Phase outputs: every in-scope item should
  trace to a phase exit criterion.
- §6 tier system ↔ §4.2 ZirOp catalogue ↔ §9 phase plan: the three
  views of "what we implement when" should agree.

### E.2 Forbidden actions ↔ permission allowlist

ROADMAP §14 lists forbidden actions. `.claude/settings.json`
`permissions.deny` should mirror them. Mismatch → `block`.

### E.3 Test-strategy ↔ build steps

ROADMAP §11.1 lists `zig build test-*` steps. `build.zig` should
declare each one when its phase opens. Missing step at a phase
where it's promised → `block`.

## F. Debt + lessons coherence (added 2026-05-04)

First run `bash scripts/check_debt_yaml.sh` (schema lint: parse,
required fields, status enum, blocked-by⇒last_reviewed, unique IDs,
phantom `D-NEW*`). Then the semantic checks below. `.dev/debt.yaml` is
the YAML SSOT (D-227 / ADR-0129); query with `yq` per
[`yaml_ssot_yq.md`](../../rules/yaml_ssot_yq.md).

### F.1 Debt-ledger Refs validity

For every entry's `refs` field
(`yq -r '.entries[] | .id + "  " + .refs' .dev/debt.yaml`), check it
points to something that still exists:

- File path → `test -e <path>`. Missing file → `block`.
- ADR § anchor → grep the ADR for the section. Missing → `soon`.
- Lesson slug → grep `.dev/lessons/INDEX.md` for the row. Missing
  → `block`.
- Skill / rule path → `test -e <path>`. Missing → `block`.

An entry whose `refs` are invalid is itself debt; either the
debt has been discharged (delete the entry) or the reference is
stale (fix it).

### F.2 Debt-entry status integrity

Every entry's `status` ∈ `{now, blocked-by, resolved, partial, note}`
(enforced by `check_debt_yaml.sh`). The barrier for a `blocked-by`
entry is the predicate at the head of `description` and MUST be a
**specific structural barrier**. Vague "later" / "low priority" /
"small effort" / "TODO" framing is forbidden by `.conventions`.

```sh
yq -r '.entries[] | select(.status == "blocked-by") | .id + ": " + .description' .dev/debt.yaml
```

- `blocked-by` whose barrier is empty / vague ("later", "someone") →
  `block`.
- `blocked-by` whose barrier has demonstrably been removed (cited
  Phase closed; cited ADR landed) → `soon` (flip `status` to `now`
  and discharge).
- `resolved` / `note` entries lingering many cycles → `soon` (delete;
  git retains via the close commit).

### F.2a Blocked-by escalation by age (added 2026-05-21)

Close-plan §6 (h) (resolving close-plan B2 — 30+ `blocked-by`
rows accumulating without re-evaluation). A barrier nobody has
re-walked is being trusted silently, which is how a dissolved
barrier (a closed campaign removing the blocker) goes unnoticed.

Threshold ladder, evaluated against each row's `last_reviewed`
date — calendar days, matching what the script implements:

| Age (today − last_reviewed) | Finding        | Action                                                                              |
|------------------------------|----------------|-------------------------------------------------------------------------------------|
| ≤ 14 days                    | `none` (clean) | No action. Routine.                                                                 |
| > 14 days                    | `soon` (WARN)  | Re-walk the barrier; update `last_reviewed` if still blocked.                        |
| > 30 days                    | `block` (STALE)| Barrier likely fossilised. File an ADR or lesson capturing the structural cause, OR promote the row to `now` (the barrier is no longer real). |

A missing `last_reviewed` on a `blocked-by` row is STALE by
definition — there is no date to trust.

Three or more rows hitting `soon` / `block` at once is the
structural failure this rule exists for (several barriers
evaporating together as a closed campaign or landed ADR renders
them moot) — it promotes to `suggest meta_audit` (`watch`
severity), which is also what §J.4 records.

The runnable form of this check lives at:

```sh
bash scripts/audit_blocked_by_age.sh   # informational; --gate exits 1 on STALE
```

The script is the reference implementation of the ladder above;
there is no inline fallback to keep in sync with it.

### F.3 Lessons INDEX coverage

Every file in `.dev/lessons/` (excluding INDEX.md, `_TEMPLATE.md`,
and the `archive/` subtree) MUST have a corresponding row in
`.dev/lessons/INDEX.md`:

- Lesson file without an INDEX row → `block`.
- INDEX row pointing at a missing file → `block`.
- INDEX row's keyword column empty → `soon` (keyword is the
  search anchor; without it, lesson is undiscoverable).

### F.3a Lesson Citing backfill (added 2026-05-16)

```sh
bash scripts/check_lesson_citing.sh
```

Flags lessons with unfilled `<backfill>` / TBD / pending markers
in the `**Citing**:` header.

- WARN at phase boundary → `soon` (backfill in the per-phase
  SHA-pointer backfill commit).
- WARN persisting > 2 phase boundaries → `block` (lesson is
  losing its commit-lineage value).

### F.4 Lessons promotion candidates

For each lesson, count citations across the codebase + commit
log:

- 3+ citations (in commit messages, code comments, ADR
  Alternatives sections) → `soon` ("promote to ADR per
  `lessons_vs_adr.md`").
- Same lesson title appearing in multiple lesson files →
  `block` (de-dup).

### F.5 Skip-ADR Removal-condition currency

Run `bash scripts/check_skip_adrs.sh` and parse output:

- Any "MISSING ON DISK" → `block`.
- Skip-ADR Removal condition obviously satisfied (e.g. cited
  follow-up ADR has been Accepted, cited Phase has closed) →
  `soon` ("remove skip-ADR; restore fixtures to runner").

### F.6 ADR Revision-history SHA validity

Run `bash scripts/check_adr_history.sh` and parse output:

- Any "UNKNOWN" SHA → `block`.
- `<backfill>` placeholder older than the current phase →
  `soon` ("backfill SHA at phase boundary").

### F.7 Phase-boundary cohort backfill (added 2026-05-11)

At every Phase-close boundary (the same audit invocation that
flips `Phase Status` widget for `<N> → DONE`), run
`scripts/check_adr_history.sh --gate` and **batch-backfill all
`<backfill>` placeholders** for ADRs whose Revision history rows
fall within the closing Phase's commit window.

Procedure:

1. `git log --oneline --since=<phase-open-SHA> --until=HEAD --
   .dev/decisions/` → enumerate the ADR-touching commits in the
   closing phase.
2. For each ADR with `<backfill>` rows whose dates intersect
   that window, replace the placeholder with the corresponding
   commit SHA (use `git log --diff-filter=A --follow` for
   creation; `git log` over the file for amendments).
3. Recheck `check_adr_history.sh --gate` exits 0 after the
   cohort edit; commit as
   `chore(adr): SHA backfill — <Phase N close cohort>`.

The 2026-05-11 audit (SUMMARY §4.1 / batch_C) flagged 10/13
ADRs in the 0028..0040 range with un-backfilled rows;
phase-boundary cohort runs are the structural fix. Per-amend
"backfill in the same commit" remains optional — the
phase-boundary cohort is the safety net, not a replacement.

### F.8 ADR Status lifecycle terminals (added 2026-05-11)

For each ADR, verify Status line matches one of the canonical
forms enumerated in `decisions/README.md` §"Required structure
/ Status" (per ADR-0050 D-1):

- `Proposed` / `Accepted` /
  `Accepted (partial — see D-NNN)` /
  `Accepted (scope downgraded by NNNN)` /
  `Superseded by NNNN` /
  `Closed (Phase X DONE)` /
  `Demoted to .dev/lessons/<file>` /
  `Rejected` / `Deprecated`

Findings:

- ADR's referenced Phase is `DONE` per ROADMAP `Phase Status`
  widget AND ADR Status is plain `Accepted` AND no recent
  commit (last ~3 phases) touches the ADR file → `soon`
  ("candidate for `Closed (Phase X DONE)` flip per ADR-0050").
- Status references a debt ID (D-NNN partial) but the debt row
  is missing or `Discharged` → `block` (Status drift).
- Status references a successor ADR (`scope downgraded by`,
  `Superseded by`) but the named successor ADR's References
  back-link is missing → `soon`.

### F.9 Skip-ADR effectiveness gate (added 2026-05-11)

Per ADR-0050 D-2 + D-3, every `skip_*.md` ADR must be effective
via one of: (1) runner-side `skip-adr-<slug>` classification,
(2) DEFER-mark + runner-side skip-token, (3) manifest exclusion.

Run `bash scripts/check_skip_adrs.sh --gate` (when the D-3
extension lands) and parse output. Until then, manual audit:

- For each `skip_*.md`, locate the manifest(s) that reference
  the listed fixtures.
- Verify: fixture appears with `# DEFER:` / `skip-adr-` prefix
  OR the runner has hardcoded skip-token recognition for the
  fixture's reason (per ADR-0029 implementation reality, see
  D-073) OR the fixture is removed from the active manifest.
- If none holds, the skip-ADR is **not effective** → `block`
  (skip-ADR drift) AND the audit must verify a debt row
  exists naming the structural barrier (typically D-072 for
  the wast_runtime_runner.zig case; create a fresh debt row
  if a new skip-ADR surfaces this gap).

### F.10 Dual-view table storage sync (ADR-0068 §A1; added 2026-05-25)

```sh
bash scripts/audit_table_sync.sh
```

Replaces the deleted `.claude/rules/dual_view_table_sync.md`
(retired 2026-05-25; never had an actual enforcement mechanism
— the rule's promised `audit §F grep` was aspirational).
Verifies every writing handler in `src/engine/codegen/{arm64,
x86_64}/op_table.zig` (Set/Copy/Init/Grow/Fill) is in one of
three compliant shapes: (a) inline mirror — references both
`tables_ptr_off` AND `tables_jit_ci_ptr_off`; (b) runtime
delegation — calls via `table_<op>_fn_off`; or (c) thin
wrapper — body is `return emitXxx(...);` only.

Findings:

- PARTIAL (references refs base but not mirror base) →
  `block` — re-introduces D-126 (post-mutation
  `call_indirect` reads stale funcptr_base; cross-instance
  dispatch fails silently).
- UNKNOWN (no base reference + not a wrapper + no runtime
  helper) → `block` — handler shape doesn't fit any of the
  three expected compliance patterns; likely added without
  considering the dual-view invariant.

Promotion to `gate_commit.sh` hard gate is queued after 2+
clean audit cycles per ADR-0068 Revision 2026-05-25.

## G. Extended-challenge consistency

### G.1 Workaround pairings

For each "SKIP-X-MISSING" / "SKIP-X-UNUSABLE" / similar fallback
in source / test runners, verify it's paired with **either** an
ADR documenting the choice **or** a debt row naming the
structural barrier:

- Workaround without paired investigation → `block`
  (violates `.claude/rules/extended_challenge.md`).
- Workaround whose paired debt row was discharged but the
  workaround code still exists → `soon`.

#### G.1.1 SKIP-* taxonomy currency (added 2026-05-21; ADR-0078 / D-155)

```sh
bash scripts/check_skip_taxonomy.sh --gate
```

Validates that every `SKIP-<TOKEN>` emission in `test/spec/`
source has a row in ADR-0078's canonical token-class table. The
script exits non-zero (`block` finding) if any emitted token
lacks a classification entry. Catches the close-plan C3 anti-
pattern: a new SKIP-* token landing in the runner without a
paired ADR/debt artifact.

- Script exit 1 (emitted token missing from table) → `block`.
- Inventory-only tokens (in ADR-0078 but not emitted) → info,
  no finding (the table is forward-looking; specialisation
  overrides may emit them).

#### G.1.2 ADR-0078 paired-artifact resolution (added 2026-05-21; ADR-0078 follow-up)

```sh
bash scripts/check_skip_taxonomy_pairing.sh --gate
```

For each row in ADR-0078's canonical table, resolves the Paired
artifact column against current ground truth:

- `debt-trackable` row citing `D-NNN` (concrete) → grep
  `.dev/debt.yaml` for an active row; if absent, grep `git log`
  for a discharge SHA. `soon` finding when the debt is
  discharged but the row still references it (the ADR table
  needs updating — either cite the discharge SHA or retire the
  SKIP-* emission if the underlying gap dissolved).
- `debt-trackable` row with `D-NNN` placeholder ("D-NNN
  follow-up") → `soon` (unfiled debt; the row promises tracking
  but no concrete D-NNN exists).
- `debt-trackable` row with per-instance phrasing ("per-fixture
  D-NNN as discovered" / "per-corpus D-NNN" / "per-call D-NNN")
  → info, no finding (these are deferred-as-instances markers,
  not concrete pairings).
- `ADR-required` row citing `.dev/decisions/<file>.md` → check
  file exists. Missing file → `block` (the row's claim is
  load-bearing for the audit; the file MUST resolve).
- `runner-internal` row → no external artifact required (the
  ADR row itself is the artifact).

Script exit 1 only on `block` (missing ADR file). `soon` and
info findings are reported but never block — they prompt the
next ADR amendment cycle.

### G.2 Anchor-command currency

Re-run the diagnostic anchor commands the loop has been silently
trusting; flag drift between "what we assume" and "what is".
The audit fires these inline (one Bash call per command, parallel-
batched), captures the output verbatim into the day's audit
report, and grades:

- `ssh windowsmini 'bash -c "command -v zig"'` — Windows host
  reachable + zig present (note: must wrap in `bash -c` because
  the default SSH shell on windowsmini is PowerShell, where
  `command -v` resolves through different rules and zig isn't
  visible by default; the project's bash-side install IS visible).
- `ssh windowsmini 'bash -c "command -v wasmtime"'` —
  windowsmini wasmtime resolution. Expected (post-D-008
  discharge): resolves to `/c/Users/.../wasmtime`.
- `ssh windowsmini "wasmtime --version"` — does the binary run
  via the SSH default shell? Expected (post-D-008 discharge):
  yes (`wasmtime 42.0.1 (...)`). **If this starts failing**, a
  windowsmini-side regression occurred — flag `block`.
- `ssh ubuntunote 'command -v nix && bash -lc "nix develop --command zig version"'`
  — Linux x86_64 host reachable + Nix dev shell + zig 0.17.0
  present. Per ADR-0067, this replaces the prior OrbStack
  invocation (D-134 retired the Rosetta path).
- `ssh ubuntunote 'whoami; sudo -n true && echo sudo-ok'` —
  NOPASSWD sudo working (autonomous setup invariant).

Each command's outcome:

- Expected (per current debt rows) → record verbatim, no
  finding.
- Different from expected → `soon` finding ("D-NNN's barrier
  may have changed; flip Status to `now` and re-evaluate").
- Command itself fails to even run (host unreachable) → `block`
  finding ("the audit's anchor is broken; fix host setup
  per `.dev/{ubuntunote,windows_ssh}_setup.md`").

This is the "mandatory walking" of `extended_challenge.md`
Step 1 that was missing in Phase 6 — the audit now fires it
on every audit run rather than waiting for the human to
notice.

### G.3 Comment-as-invariant drift (added 2026-05-16)

```sh
bash scripts/check_invariant_comments.sh
```

Detects per-arch op_*.zig source files that hardcode register
numerals belonging to `abi.allocatable_caller_saved_scratch_gprs`
— the D-132 / D-133 failure mode where comments asserted "X10/X11
/X12 are private scratch" while regalloc was simultaneously
allocating vregs into the same slots. Substrate audit Q5 anchor.

- Surfaced sites: `soon` (each is a latent regalloc-clobber
  risk; D-133 enumerates the current backlog).
- Surfaced sites + the file's narrative comments claim
  "private scratch" without code-level enforcement → `block`
  (re-derives the D-132 failure mode).

### G.4 Spike lifecycle (added 2026-05-16)

```sh
bash scripts/audit_spikes.sh
```

Flags `private/spikes/<slug>/` directories with stale lifecycle
state per `.claude/rules/extended_challenge.md` Step 4 + the
`scripts/new_spike.sh` skeleton's Status/Outcome contract:

- Status=running > 14d, or Outcome=<TBD> > 30d → `soon`
  (spike has likely been abandoned; promote-to-ADR / promote-
  to-lesson or delete).
- Status ∈ {merged-into-prod, rejected} with directory still
  present → `soon` (delete; the production commit OR ADR is
  the authoritative record).
- Spike directory without README.md → `block` (pre-skeleton
  spike; scaffold via `scripts/new_spike.sh` or document
  the lifecycle inline).

### G.5 On-branch architectural spike pattern (added 2026-05-21)

```sh
bash scripts/audit_arch_spike_pattern.sh
```

Greps the last 14 days of `main` commits for the
forbidden phrases enumerated in
[`.claude/rules/spike_discipline.md`](../../rules/spike_discipline.md)
("preparatory infra", "wire-up next cycle", "lay the groundwork",
etc.). Each hit is graded by whether the commit body pairs the
phrase with a `private/spikes/<slug>/` or
`.dev/decisions/NNNN_` reference:

- Paired with spike/ADR → `soon` (discipline held; the
  multi-cycle work is acknowledged, but flag to keep the cycle
  count visible against the `architectural` 3-cycle cap in
  LOOP.md §"Chunk types").
- No pairing → `block` (re-derives the D-153 / B146–B158
  failure mode: helper-first land + wire-up next cycle = an
  unobservable on-branch spike).

This audit runs forward-only — D-153's existing B146–B158
commits are not retroactively flagged (close-plan §6 (j)
handles their resolution).

## I. Edge-case fixture coverage (added 2026-05-04 per ADR-0020)

Verifies the `test/edge_cases/p<N>/` fixture corpus stays in
sync with semantic-boundary code touched in recent commits.
The discipline lives in
[`.claude/rules/test_discipline.md`](../../rules/test_discipline.md):
boundary-touching commits land their fixture in the same diff.

### I.1 Fixture triple integrity

For each `test/edge_cases/**/<case>.wat`:

```bash
test -f "${case%.wat}.wasm"   || warn "missing .wasm artifact"
test -f "${case%.wat}.expect" || warn "missing .expect file"
```

Findings:

- Missing `.wasm` for an existing `.wat` → `warn` ("re-compile
  via `wat2wasm`; check fixture-build target wires it").
- Missing `.expect` → `warn` ("each fixture's expected output
  must be declared; trap-only fixtures still need `trap:
  <reason>`").

### I.2 Fixture artifact freshness

For each `<case>.wasm` paired with `<case>.wat`, verify the
artifact's mtime ≥ the source's mtime. Stale artifact → `warn`
finding ("re-compile + commit the updated `.wasm`").

### I.3 Boundary-touch / fixture-add correspondence

Walks recent commits (last 20 by default, or since last phase
boundary) and cross-references "boundary-touching" file
changes with fixture additions:

- **Boundary-touching** = commits that modify Zig source under
  `src/jit_arm64/emit.zig`, `src/interp/`, `src/feature/` (op
  handler surfaces) OR `.dev/decisions/` (ADRs that change
  semantics).
- **Fixture additions** = new files under `test/edge_cases/**`.

For each boundary-touching commit lacking a paired fixture
addition: `soon` finding ("touches semantic boundary without
fixture addition; verify rationale per
`.claude/rules/test_discipline.md`'s 'When NOT to add a
fixture' section").

Intentionally noisy at first; calibration happens via the
rule's exclusion list and per-commit rationale.

### I.4 Convention checks

All fixture paths must match
`test/edge_cases/p<N>/<concept>/<case>.{wat,wasm,expect}`.
Any deviation → `warn` finding.

### I.5 Stale-ness

If the rule file (`.claude/rules/test_discipline.md`) is
missing or its `paths:` frontmatter no longer covers `src/**`
+ `test/**`, §I's premise is broken — `block` finding ("rule
file missing; restore from ADR-0020 or supersede").

## J. Meta-audit triggers (added 2026-05-04)

Detect drift signals that suggest the user should fire the
`meta_audit` skill. These checks **do not** fail the audit; they
emit `suggest meta_audit` findings. The `meta_audit` skill is
user-gated (per its SKILL.md "User-gated, not autonomous" §); this
section's job is to surface the candidates for that decision.

### J.1 §A2 soft-cap approach

Any `src/**/*.zig` whose line count is ≥ 800 (= 80% of the
ROADMAP §A2 soft cap of 1000). Surface as `suggest meta_audit`
finding listing each match (`watch` severity). The 2026-05-04
retrospective worked example: emit.zig at 3989 LOC was a §A2
hard-cap violation that should have triggered meta_audit at
the 800-LOC mark (sub-7.3), not be discovered at the
retrospective.

**Per ADR-0099**: the soft cap is a **smell detector, not a
metric**. WARN findings should trigger investigation against
the §D2 4+4 conditions, with `FILE-SIZE-EXEMPT` as the default
outcome when no valid extraction exists. Mechanical extraction
to "make the WARN disappear" is the failure mode this
discipline rejects.

### J.2 §A2 hard-cap violation

Any `src/**/*.zig` whose line count is ≥ 2000 (the §A2 hard cap).
This is a **§14 forbidden-list cross**, not a near-miss; emit
`block` severity finding with explicit
`fire meta_audit BEFORE next /continue resume`. Existing
violations (e.g. emit.zig pre-discharge of ADR-0021 row 7.5d-b)
are tracked but not re-fired each cycle while their discharging
ADR is active.

### J.3 Debt accumulation

`.dev/debt.yaml` Active rows count > 15. The threshold is
intentionally low — debt rows are supposed to discharge or
escalate, not accumulate. Emit `suggest meta_audit` listing the
oldest 5 rows by First-raised date (`soon` severity).

### J.4 Stale debt review

Any debt row that `scripts/audit_blocked_by_age.sh` reports STALE
(`last_reviewed` older than 30 days, or missing) — the same ladder
§F.2a states. Promotes to `suggest meta_audit` (`watch` severity)
when ≥ 3 rows are stale; §F.2a alone surfaces the single-row case.

### J.5 §14 forbidden-list near-miss

**"New" definition**: appears in a commit later than the
previous `audit_scaffolding` invocation's `private/audit-*.md`
report — or, on first run, any current occurrence. Snapshot the
match list per run so a delta is computable next time.

Detection patterns (heuristic; false-positives acceptable):

- Any new `pub var` in `src/` (§14: "pub var as a vtable").
- Any new `if (build_options\.` (or compile-time equivalent)
  outside the **build-options registration sites** — exclude
  `src/main.zig`, `src/c_api/*.zig`, `src/cli/*.zig`, and any
  module wired into `addOptions` per `build.zig`. The §14 ban is
  on **pervasive** build-time flags in main code paths; entry
  modules legitimately read `build_options.wasm_level` etc.
  False-positive on entry modules is what motivated this
  exception.
- Any new `std.Thread.Mutex` / `std.io.AnyWriter` /
  `std.io.fixedBufferStream` (§14 + §P4 + zig_tips.md
  removed-API list).
- Any new file path containing `-` (§14: hyphens in file names).

Emit `suggest meta_audit` finding per match (`watch` severity).

### J.6 ADR cross-reference integrity

ADR count grew by ≥ 5 since the last `meta_audit` retrospective
report under `.dev/meta_audits/`. Without periodic cross-reference
verification (Revision history SHAs, Dependencies sections — see
the 2026-05-04 batch-dependency-order lesson), a 5-ADR batch
risks the implicit-DAG anti-pattern. Emit `suggest meta_audit`
when threshold reached (`watch` severity).

### J.7 Phase boundary

When the Phase Status widget flips to `DONE` (§A.3 watches this).
Emit `suggest meta_audit` as a routine cadence finding (`watch`
severity — lightest of the three CHECKS categories). The user
usually accepts this trigger; it is the default cadence for
`meta_audit` per its SKILL.md.

### J.8 Split-quality smell (added 2026-05-21; ADR-0099 §D4)

Fire `bash scripts/check_split_smell.sh` and surface every
finding as a `watch` severity entry (informational; not
blocking). Categories:

- `N1-helper-circular` — child sibling imports parent and
  calls parent helper functions (per ADR-0099 §D2 N1).
- `N3-shallow` — naming-pattern sibling with substantive
  code < 100 LOC (§D2 N3).
- `N4-test-dup` — test helper duplicated across siblings
  (§D2 N4).
- `hub-emptiness` — parent file is mostly re-exports
  (possible over-split signal).

Each finding triages against §D2:
- If a tie-breaker (P1+N2 managed, P3+N1-type-only) explains
  it — accept; no action.
- If a `FILE-SIZE-EXEMPT` marker explains it — accept.
- Otherwise — file a rollback / redesign ADR per §D2.

The script is gate-wired (gate_commit.sh between
`file_size_check` and `check_skip_adrs`) as informational; the
audit re-runs it for periodic cross-check and surfaces deltas
since the last audit run.

Write to `private/audit-YYYY-MM-DD.md`:

```
# Scaffolding audit — YYYY-MM-DD

## block (N)
- <file:line> — <one-line description>
  fix: <suggestion>

## soon (N)
- ...

## watch (N)
- ...

## summary
<2-3 sentences>
```

Then summarise to the user with severity counts and top-3 findings.
Do not modify any tracked files; the user decides the fix timing.
