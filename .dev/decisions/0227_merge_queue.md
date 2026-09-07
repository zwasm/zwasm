# 0227 — `main` merges through a queue; `strict` comes off and the workflow gains `merge_group`

- **Status**: Proposed (gate definition per ADR-0212 D1 — D1 and D2 flip to
  Accepted on the maintainer's word on the PR that carries them, the way
  ADR-0225 did on #380. D3 is apparatus-internal and needs no sign-off; it
  lands either way, inert until a queue exists.)
- **Date**: 2026-09-07
- **Author**: chaploud
- **Tags**: ci, gate, merge-queue, process

## Context

`main`'s ruleset carries `strict_required_status_checks_policy: true`, so a
branch must be up to date with `main` to merge. With several PRs open, each
merge invalidates the others: they need a manual update and a full 3-OS
re-run, whose macOS leg is the long pole.

#299 measured what that costs. Over the last 100 PR runs (29 branches):
**3.4 runs per branch** (median 3, max 10), **36 % ending `cancelled`**. Its
follow-up comment measured the parameters a queue would need against this
repository: core-gate leg durations over n=41 — macOS **median 33.5 min, max
39.7 min**, windows median 14.8, linux median 8.0 — and merges to `main`
arriving a **median 50 min apart**, with only 5 of 29 gaps at 30 min or less.
Everything below rests on those numbers; this ADR adds the mechanism they did
not cover.

GitHub's documentation states the mechanism plainly: a merge queue "provides
the same benefits as the **Require branches to be up to date before merging**
branch protection, but does not require a pull request author to update their
pull request branch." The guarantee moves rather than weakens — the queue
tests the *result* of merging each entry.

Three facts about this repository decide the rest.

**The workflow does not run on `merge_group`.** `ci.yml`'s triggers are
`pull_request`, `push` to `main` and `workflow_dispatch`. GitHub's
documentation: "You **must** use the `merge_group` event to trigger your
GitHub Actions workflow when a pull request is added to a merge queue", and
"the `merge_group` event is separate from the `pull_request` and `push`
events". A required check that never reports is not a pending check — the
ruleset's `check_response_timeout_minutes` elapses and the check "will be
assumed to have failed", so **every entry would be ejected**. This is the one
change without which enabling a queue makes the repository unmergeable.

**The doc-only skip does not survive the queue on its own.** The `changes`
job branches on `pull_request` and `push`, and its `else` arm sets
`code=true`. A `merge_group` run would take that arm, so a doc-only PR would
pay a full 3-OS gate in the queue that it is excused from on its own PR. Four
of the last six merges were docs or scripts.

**The concurrency group already handles it.** The key is
`ci-<workflow>-<ref>`, and a merge-group run's ref is the queue's own
`refs/heads/gh-readonly-queue/...`, distinct per entry — entries cannot
cancel each other, including the speculative ones. No change needed, recorded
here so the next reader does not re-derive it.

## Decision

### D1 — `main` gains a `merge_queue` rule and loses `strict`

The ruleset keeps `deletion`, `non_fast_forward`, `pull_request` and
`required_status_checks` with `ci-required` as the required check.
`strict_required_status_checks_policy` comes off in the same change: left on,
the forced update this ADR is about survives the queue.

Settings, each with the measurement or the documented meaning behind it:

| parameter | value | why |
|---|---|---|
| `check_response_timeout_minutes` | 60 | Checks that have not reported by then are assumed failed. The macOS leg's measured max is 39.7 min, and an entry also waits for a runner; 60 leaves headroom without letting a genuinely stuck entry sit. |
| `grouping_strategy` | `ALLGREEN` | Each PR's own merge commit must pass. `HEADGREEN` checks only the group head, which is a weaker guarantee than `ci-required` gives today. |
| `max_entries_to_build` | 1 | No speculation to begin with. Speculative builds multiply concurrent macOS jobs at ~33 min each; whether that trades queue latency for runner starvation is a measurement, and it should be taken after the queue is real. |
| `min_entries_to_merge` | 1 | Merges arrive a median 50 min apart and an entry costs ~32 min, so waiting to group costs more than it saves. |
| `min_entries_to_merge_wait_minutes` | 0 | Same reason. |
| `max_entries_to_merge` | 1 | Nothing to batch at this arrival rate; raise it with `max_entries_to_build` if the rate changes. |
| `merge_method` | see D2 | |

### D2 — `merge_method` is `REBASE`

This is the parameter #299's follow-up listed and did not price, and it
decides a question that reads as separate. `squash_merge_commit_message` is
`COMMIT_MESSAGES`, and the last fifteen commits on `main` carry curated
6–23 line bodies that are neither concatenated branch commits nor PR bodies:
they are written at merge time through `gh pr merge --body-file`. A queue
merges automatically, so that override is gone — but only under `SQUASH`.

- `SQUASH` + `PR_BODY` puts the PR body in `main`. PR bodies here are decision
  documents, with tables and options; that is not what the history should
  carry.
- `SQUASH` + `BLANK` keeps `main` clean and drops the 6–23 lines of recorded
  reasoning, which is the more useful half.
- `MERGE` brings each branch's `Merge branch 'main' into …` commits with it —
  exactly what the `--body-file` override has been keeping out.
- `REBASE` replays the branch's own commits, drops the merge commits, and
  each keeps its own message.

`REBASE` preserves what `main` reads like today; the cost is that the writing
moves from merge time to the branch, so a branch's final commit messages have
to stand as the record. That is a real change in habit and it is the part of
this ADR most worth disagreeing with.

### D3 — The workflow changes (apparatus-internal)

Two, both inert until a queue exists:

- `ci.yml` gains an unfiltered `merge_group:` trigger, the shape wasmtime's
  `main.yml` uses.
- The `changes` job gains a `merge_group` arm reading
  `github.event.merge_group.base_sha` / `head_sha`, so the doc-only skip
  applies to a queue entry as it does to a PR. Fail-closed like the push arm:
  an absent or unreachable base runs the gate rather than reading as
  doc-only.

`ZWASM_CI_EXTENDED` is untouched. It keys on `github.event_name == 'push'`,
and a queue still produces a push to `main` on merge, so the extended checks
keep running exactly where they run now.

## Applying D1

Not a script: it runs once and would then be a caller-less file (ADR-0212 D3).
The transform reads the live ruleset and edits two things, so nothing else in
it is retyped or disturbed:

```sh
gh api repos/zwasm/zwasm/rulesets/13308987 > /tmp/ruleset.json

jq '(.rules[] | select(.type=="required_status_checks")
       | .parameters.strict_required_status_checks_policy) = false
    | .rules += [{ type: "merge_queue", parameters: {
        check_response_timeout_minutes: 60,
        grouping_strategy: "ALLGREEN",
        max_entries_to_build: 1,
        max_entries_to_merge: 1,
        merge_method: "REBASE",
        min_entries_to_merge: 1,
        min_entries_to_merge_wait_minutes: 0 }}]
    | {name, target, enforcement, conditions, bypass_actors, rules}' \
  /tmp/ruleset.json > /tmp/ruleset-queued.json

# read it, then:
gh api --method PUT repos/zwasm/zwasm/rulesets/13308987 --input /tmp/ruleset-queued.json
```

Run against the live ruleset on 2026-09-07, the transform produced the five
rules with `strict=false`, and `deletion` / `non_fast_forward` /
`pull_request` / `name` / `target` / `enforcement` / `conditions` /
`bypass_actors` diffed clean against the original. The `PUT` was not run.

To undo, `PUT` the saved `/tmp/ruleset.json` back.

## Alternatives rejected

- **Do nothing.** The measured loop is 3.4 runs per branch at 36 % cancelled,
  and it grows with the number of open PRs rather than staying flat.
- **#298's content-keyed skip instead.** Complementary, not a substitute: it
  removes the CI cost of updating a branch, where a queue removes the update.
  Neither subsumes the other.
- **`merge_group` without the `changes` arm** (wasmtime's shape). Simpler, and
  correct — it just pays a 3-OS gate for every doc-only entry. The arm is
  eight lines and the skip is already built.

## Consequences

- **Positive**: a branch stops being invalidated by someone else's merge. The
  gate does not weaken — `ci-required` runs on the merge result rather than on
  a branch that was up to date an hour ago.
- **Negative**: a merged PR pays two gate runs, its own and the queue's, where
  today it pays one plus however many re-runs the invalidation forces. At the
  measured 3.4 that is a reduction, but it is not free per PR.
- **Negative**: under `REBASE`, commit messages have to be right on the branch.
  There is no merge-time edit.
- **Neutral**: the ruleset change is a settings action, not a repository one.
  This ADR and D3 make the repository ready; nothing here enables a queue.
- **Follow-up**: `max_entries_to_build` above 1 is a measurement to take once
  the queue has run for a week, against runner concurrency rather than in the
  abstract.

## References

- #299 (the row, and the parameter measurements this ADR rests on), #298
  (the content-keyed skip), #312 (cancelled `main` runs — why the concurrency
  key is shaped as it is)
- ADR-0212 D1 (gate definitions need sign-off; apparatus does not),
  ADR-0076 D9 (CI is authoritative)
- GitHub docs: "Managing a merge queue"; the `merge_queue` rule parameters in
  the repository-rules REST reference
