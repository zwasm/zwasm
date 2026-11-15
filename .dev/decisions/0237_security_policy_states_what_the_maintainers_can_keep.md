# 0237 — The security policy states what a small group of maintainers can keep doing

- **Status**: Accepted (2026-11-21, on PR #757)
- **Date**: 2026-11-15
- **Author**: Junji Takakura
- **Tags**: security, release, process

## Context

`docs/threat_model.md` (2026-10-24) defines a vulnerability, and
`.github/SECURITY.md` has said since 2026-11-14 that a breach of goals 1, 3
or 4, or memory unsafety in the host, is released "as soon as it is merged".
Every vulnerability also got its own advisory.

In the 19 days after the threat model was published the project cut 7
releases and published 13 advisories. 12 of the 13 were found by the
maintainers' own audits, not reported from outside. Each release and each
advisory is done by hand by one of two maintainers, and little other work was
done in that time.

The definitions were not the cost. The obligations attached to them were: a
release per fix, and a full advisory per finding.

## Decision

1. **The definitions stay.** What counts as a vulnerability, the five goals
   and the three questions in `docs/threat_model.md` do not change. Every
   vulnerability is still classified, fixed and named in the CHANGELOG.
2. **Two rows, by what the guest gains.** The first row is goals 1, 3 and 4:
   a guest reads, writes, runs or reaches something it was not given. The
   second row is goals 2 and 5. "Memory unsafety in the host" leaves the
   first row: where a guest can steer it, it is goal 1; where it only stops
   the process, it is goal 2.
3. **Release timing.** A first-row fix is released within 30 days of being
   ready (CI and review passed), or within 14 days if it was reported from
   outside, and is merged on the day of the release. A second-row fix rides
   the next release, at most 30 days after it is ready. Security releases
   are batched, at most one every two weeks. A report from outside with a
   disclosure date, and exploitation seen in use, are released as soon as
   the fix is ready.
4. **Advisories.** An advisory is published for a first-row breach, and for
   anything reported from outside. A second-row breach the maintainers found
   themselves is listed under Security in the CHANGELOG, with no advisory.
5. **A short advisory.** It says what a guest could do, which versions are
   affected and which version fixes it. The tests the fix adds are the
   reproduction.
6. **The policy says why.** `SECURITY.md` states that it describes what a
   small group can keep doing, and that it widens as maintainers join.

## Alternatives considered

### Alternative A — keep a release per fix and an advisory per finding

- **Sketch**: the policy as it stood on 2026-11-14.
- **Why rejected**: 7 releases and 13 advisories in 19 days, for two
  maintainers, left no time for anything else. A promise that cannot be kept
  for long is worse than a smaller one that can.

### Alternative B — lighter handling for some features

- **Sketch**: GC, exception handling, the component model with WASI 0.2 and
  0.3, `zwasm serve` and AOT get the second-row handling whatever goal is
  breached.
- **Why rejected**: on top of decisions 3 and 4 it removes 3 or 4 of the 13
  advisories, and those are the severe ones: 3 of the 5 rated high. It can be
  added later; a narrowed promise is hard to widen back.

### Alternative C — a fixed release day

- **Sketch**: one release on a set weekday.
- **Why rejected**: it forces a release in a week with nothing to ship. A cap
  of one every two weeks gives the same batching without that.

## Consequences

- **Positive**: counted against the same 19 days, 7 releases become 2 and 13
  advisories become 5 or 6. A fix no longer has to be merged the moment it is
  green, so review can finish first.
- **Negative**: a guest-triggered stop of the host process that the
  maintainers found is no longer announced by an advisory; a user learns of
  it from the CHANGELOG. A first-row fix the maintainers found can wait up to 30
  days in a public pull request before it is released.
- **Neutral / follow-ups**: revisit when a maintainer joins, when reports
  from outside arrive regularly, or after a month under this policy.
  Alternative B is the next lever if the load is still too high.

## References

- `docs/threat_model.md`, `.github/SECURITY.md`
- ADR-0156 (release is manual), ADR-0234 (release preparation)
