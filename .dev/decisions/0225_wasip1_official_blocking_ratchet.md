# 0225 — The official preview1 corpus blocks, with a ratchet; ADR-0208 D3's advisory placement is superseded

- **Status**: Accepted (2026-09-02 — maintainer sign-off on PR #380, taken on
  the measurements in Context before any of it was written; D1–D3 as written)
- **Date**: 2026-09-02
- **Author**: Junji Takakura
- **Tags**: ci, wasi, gate, ratchet

## Context

ADR-0208 D3 placed `zig build test-wasi-p1-official` in the `gate` job with
step-level `continue-on-error: true`, and its `Alternatives rejected` section
turned down a failure ratchet in favour of that. Both parts have since been
overtaken, and one of them was already inaccurate when written.

**The premise moved.** D3's reason was "the corpus is 14 red today", so
blocking would red every PR. Measured on `0a90547e2` (run 33612652144, all
three legs, both engines): x86_64-linux and aarch64-macos are at the vendored
total on both lanes, and x86_64-windows fails the #290 family — the same names
on both engines, already enumerated by name in D-583. Two of the three hosts
need no tolerance at all, and the third needs a list, not a flag.

**The rejection's factual ground was wrong.** D3 rejected a ratchet partly on
"Nothing in the repo ratchets failures today". `test/aot/aot_process_diff.zig`
has carried exactly that mechanism since `4ac56549a` (2026-07-09), five weeks
before ADR-0208: a `known_table` whose `.wrong_result` rows name a debt row,
are tolerated, and trip `RATCHET-FLIP` when the fixture starts matching. The
table was empty, so the *mechanism* was invisible to a survey of active
ratchets — but the shape was house-shaped and precedented, not new. #375
re-affirmed and extended that lane.

**`continue-on-error` did more than annotate.** GitHub keeps `outcome:
failure` on such a step but rewrites `conclusion` to `success`, and
`conclusion` is what `needs.gate.result` and therefore `ci-required` read.
That is what hid #310: the runner stopped producing a summary line at all —
it died mid-corpus — and the leg reported green. The failure mode was not a
worse number, it was no number.

**Push-only compounds it.** ADR-0208 predates the 2026-08-24 move to
`if: github.event_name == 'push'`, whose stated reason is that a step which
cannot block a PR buys no gate signal for the 182 s it costs. Once the step
blocks, that reason inverts: a blocking check that runs only after the merge
turns a preview1 regression into a red `main`, which is the situation #312 is
open about.

## Decision

### D1 — The step blocks, and the tolerance is a named table, not a flag

`continue-on-error` is deleted. `test/wasi/official_runner.zig` grows a
`known_table` in the shape of the AOT differential's: entries carry a test
stem and a debt-row id, a listed test that fails is counted apart and
tolerated, and a listed test that PASSES exits non-zero so its row is removed
by the PR that fixed it. `builtin.os.tag` selects the table; linux and macOS
get an empty one, so every test there is `.match` and any failure reds the PR.

The table records **names**, never a count — the count stays derivable from
the run. That is the same reason the CI comment block carries no number: this
project has already had a copied count go stale against the debt row it was
copied from.

No separate presence check is added. The runner's exit code is the presence
check: a corpus that stops producing a summary line does so by dying, and a
dead process exits non-zero. What hid #310 was not a missing check, it was
`continue-on-error` overwriting the one that existed.

The table is held to the corpus in both directions. RATCHET-FLIP covers a row
whose test starts passing. A row whose test is no longer THERE is the other
direction, and it is silent: an upstream bump that removes a listed test and
adds another keeps the vendored total intact, so nothing else in the runner
notices, and the row sits tolerating nothing. Each row therefore carries an
hit COUNT, and any row the walk did not reach exactly once exits non-zero:
`STALE-ROW` at zero, `DUP-STEM` above one. Duplicate keys within the table are
a `@compileError`, since the second copy would be unreachable and never
counted. Both directions came from Devin's review on PR #380 and were
reproduced before fixing — a bogus row passed at exit 0, and stem uniqueness
across the three suites was asserted only by a comment:
`scripts/vendor_wasip1_official.sh` pins per-language COUNTS, not names, so a
rename that collides two suites' stems keeps the vendored total intact.

### D2 — The table describes CI's windows-2022 runner and no other host

D-583 records `path_symlink_trailing_slashes` failing on a Windows 11 host,
where the family is eight rather than seven. An exact-match table cannot hold
both: listing eight reds windows-2022 with a ratchet flip, listing seven reds
Windows 11 with an unexpected failure. The gate exists to hold CI, so it is
written for CI's host. An extra failure on a local Windows 11 box is that box
disagreeing with the runner; it is recorded in D-583 and not enforced.

### D3 — The step runs on pull requests as well as the merge

Reverses the 2026-08-24 push-only placement, on that placement's own
reasoning. Cost is the measured 182 s (`286a91f89`, 2026-08-25) — 138 s on the
macOS leg, 44 s across linux and windows — against a macOS gate leg that ran
23 m 25 s on PR #376.

## Alternatives rejected

- **Keep the advisory placement and add a notifier for a red `main`.** The
  premise does not hold up. Over the last 100 push runs of `ci.yml` on `main`
  (2026-08-04 .. 2026-09-02) there were two failures, both in extended-only
  checks, and both were fixed within hours by the person who merged —
  `8ea1f797a` about an hour after run 33056826468, with a body that cites the
  failure ("the merge red main"), and `a27504789` about 2.5 h after run
  31552046553, whose own title is "run the test-discovery guard on PRs". In
  both cases the remedy taken was to move the check to where it blocks. This
  ADR does that for a third one. Whether a notification channel is also worth
  having is #312's question and is not settled here.

- **Ratchet on a failure COUNT rather than a name set.** A count cannot tell
  "one fixed, one regressed" from "no change", which is the state the #290
  cluster will actually pass through. It also reintroduces the copied number
  D-583 already lost once.

- **Move the step into `test-all` now.** That is D-583's discharge and it is
  not reached: the Windows names are still red. Folding it in early would put
  the tolerance table inside the blocking unit test gate, where it is harder
  to see.

## Consequences

- ADR-0208 **D3 is superseded**; D1 and D2 stand. Its `Alternatives rejected`
  entry "Ratchet the 14 failures instead of running advisory" no longer
  describes current practice, and its factual claim about the repo having no
  failure ratchet was already false at the time.
- `ci-required` now genuinely covers the preview1 corpus on all three OSes —
  before, a Windows leg exiting 1 was indistinguishable through the API from a
  pass.
- D-583's DISCHARGE clause gains an edit (emptying the table) and loses its
  "stays non-blocking" sentence.
- The #290 cluster is now load-bearing: fixing any of those names requires
  removing its table row in the same PR, which the ratchet enforces.
- `test/aot/aot_process_diff.zig`'s `known_table`, which this one is modelled
  on, has the STALE-ROW hole too — its `expectationFor` is consulted only for
  fixtures the corpus yields. Not fixed here: that lane's table is empty today,
  so the hole is latent, and closing it belongs with that lane rather than in a
  preview1 gate change.
