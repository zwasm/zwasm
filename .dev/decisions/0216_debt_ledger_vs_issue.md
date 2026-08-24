# 0216 — The debt ledger records conditions, GitHub issues record defects, and neither restates the other

- **Status**: Proposed (2026-08-24)
- **Date**: 2026-08-24
- **Author**: jtakakura
- **Tags**: process, debt, issues, documentation

## Context

`.dev/debt.yaml` has been the debt ledger since D-227 / ADR-0129. GitHub
issues began carrying work on **2026-08-20**, four days before this ADR. The
ledger predates that channel entirely, so nothing has ever decided which of
the two a given statement belongs in.

Both grew in those four days: 89 ledger rows, and more than twenty issues.
The boundary has been drawn ad hoc each time.

Measured 2026-08-24 at `17f4399af`:

- **8 of 89** ledger rows cite a `#NNN` issue or PR.
- **1 of 7** recently filed issues cites a `D-NNN`, and that one carries
  history the reader needs.
- Every one of the 21 files in `.claude/rules/` cites an ADR in its body.
  There is no rule for this boundary, because there is no ADR to anchor one.

The concrete risk is not hypothetical for this project. `.dev/handover.md`
was FROZEN on 2026-08-20 (ADR-0212 D1) for exactly this shape: a second
document describing state that live state had moved away from. Two records
of one fact drift, and the drift is silent.

## Decision

**A ledger row states a CONDITION of the codebase. An issue states an
observable DEFECT. The same statement goes in one of them, never both.**

- A **condition** is a property that *produces* defects: an absent check,
  one rule copied into N places, a guard that is too weak. It has no single
  reproducer, needs internal knowledge to state, and outlives any one PR.
- A **defect** is reproducible: "run this, got X, expected Y". Someone
  outside the project could have filed it, and one merged PR closes it.

Worked example from the week this ADR was written: **D-596** — liveness and
emit are two hand-maintained models of one fact — is the condition.
**#245 / #253 / #259** are defects it produced. The row does not restate the
reproducers; the issues do not restate the row.

**Reference direction**: a ledger row may cite `#NNN`. An issue cites
`D-NNN` only when the reader gains something from it — `D-NNN` does not
resolve for anyone outside this repository, and issue bodies are public. No
internal identifier goes into an upstream PR or any artifact published
outside this repository.

**When both are defensible** — a weak guard that one fix closes, say — the
statement goes to whichever destination is already decided, and only there.
Ambiguity resolved by writing it twice is the failure this ADR forbids.

## Alternatives rejected

**Retire the ledger; make everything an issue.** Rejected on three
properties issues do not have: `status: blocked-by` (12 rows today) is a
dependency ledger; `last_reviewed` is a review cadence, not a work queue;
and rows travel with the code in git, so a branch carries the debt state
that matches it. Migrating 89 rows of history would also discard the
`first_raised` timeline.

**Allow the same statement in both and keep them in sync.** Rejected on the
`handover.md` precedent above: this project has already paid for a second
copy of one fact, and the cost arrived as silence rather than as a conflict.

**Decide per item, write no rule.** Rejected because the two failure
directions are asymmetric. A condition parked in an issue loses its review
cadence quietly; a defect parked in a ledger row is invisible to everyone
outside the repository, which is most of the people who would hit it.
Leaving that to per-item judgement optimises the visible direction only.

## Consequences

- `.claude/rules/debt_vs_issue.md` is the lean stub of this ADR, loaded on a
  `.dev/debt.yaml` edit.
- **Enforcement is judgement, not machinery.** `scripts/check_debt_yaml.sh`
  validates row shape, not destination. The `audit_scaffolding` skill's
  debt+lessons coherence pass is where a misplaced or duplicated statement
  surfaces.
- The rule's trigger is one-directional by construction: editing
  `.dev/debt.yaml` is the moment to ask "should this be an issue instead?",
  while filing an issue that should have been a row triggers nothing.
  `audit_scaffolding` is the backstop for that direction.
- This ADR decides a boundary that was previously undecided. It does not
  ratify existing practice — only the reference direction above was measured
  as already-followed.

## References

- ADR-0129 / D-227 — the ledger as YAML SSOT.
- ADR-0212 D1 — maintenance-mode authority; the `handover.md` freeze.
- ADR-0118 D2 — the rule / reference split that `.claude/rules/` follows.
- `.claude/rules/lessons_vs_adr.md` — the sibling boundary (lesson vs ADR),
  whose decision table this one mirrors in shape.
