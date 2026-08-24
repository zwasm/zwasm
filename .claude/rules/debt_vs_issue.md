---
description: "Debt ledger vs GitHub issue — a debt row states a CONDITION of the codebase (no repro, needs internal knowledge, outlives one PR); an issue states an observable DEFECT (repro, an outsider could file it, one PR closes it). Never both; debt may cite an issue, an issue cites D-NNN only when the reader gains something."
paths:
  - ".dev/debt.yaml"
---

# Debt row vs GitHub issue

> Lean stub of **ADR-0216**. Full context, rejected alternatives, and the
> measurements: [`../../.dev/decisions/0216_debt_ledger_vs_issue.md`](../../.dev/decisions/0216_debt_ledger_vs_issue.md).

## Invariant

**Condition → `.dev/debt.yaml`. Defect → GitHub issue. Never the same
statement in both.** A condition is a property of the codebase that
*produces* defects; a defect is a thing you can reproduce.

Decision table (YES → issue / NO → debt row):

| Question | YES→issue | NO→debt |
|---|:-:|:-:|
| Can you write "run this → got X, expected Y"? | ✓ | |
| Could someone outside the project have filed it? | ✓ | |
| Does one merged PR close it? | ✓ | |
| Is the best you can say "nothing prevents X" / "N copies of one rule"? | | ✓ |
| Does it survive several PRs and want `last_reviewed` re-checked? | | ✓ |

Worked example — the same investigation split correctly: **D-596** (liveness
and emit are two hand-maintained models of one fact) is the condition;
**#245 / #253 / #259** are defects it produced. The row does not restate the
repros; the issues do not restate the row.

## Reference direction

**Debt may cite `#NNN`; an issue cites `D-NNN` only when the reader gains
something from it.** `D-NNN` does not resolve for anyone outside this repo,
and issue bodies are public. Measured 2026-08-24: 8 of 89 rows cite an
issue or PR; 1 of 7 recent issues cites a `D-NNN`, and that one carries
history the reader needs.

**Never put an internal identifier in an upstream PR or a public artifact
outside this repo.** Use a resolvable URL or a self-contained explanation.
(ADR-0216; the reference direction is the one part of this rule that was
measured as already-followed — the rest is decided there, not ratified.)

## Boundary cases

- **Both are defensible** (e.g. "a guard is too weak" — a condition, but one
  fix closes it): pick the destination that is already decided and write it
  there ONLY. Ambiguity resolved by duplication is the failure mode.
- **"TODO later"** → debt (`lessons_vs_adr.md` already says so).
- **"We tried X and learned Y"** → lesson, not either.
- A condition whose instances are still arriving keeps its row after each
  instance is fixed; the row discharges when the condition is gone.

## Enforcement

None mechanical — this is a judgment rule. `scripts/check_debt_yaml.sh`
validates row shape, not destination. The `audit_scaffolding` skill's
debt+lessons coherence pass is where a row that should have been an issue
(or a duplicated statement) surfaces.

**Trigger asymmetry, deliberate**: this loads on a `.dev/debt.yaml` edit —
the moment a row is about to be added. Filing an issue that should have been
a row does not trigger it; `audit_scaffolding` is the backstop that way.
