# 0234 — CHANGELOG entries live in `changelog.d/` until a dispatched workflow assembles the release section

- **Status**: Accepted
- **Date**: 2026-10-24
- **Author**: Junji Takakura
- **Tags**: process, release, changelog, merge-queue

## Context

`main` merges through a REBASE queue (ADR-0227). Every PR adds its entry at
the same place, `CHANGELOG.md`'s `[Unreleased]`, so each one the queue lands
leaves the rest unable to rebase and drops them from the queue. On 2026-10-21
three PRs fell out in one day (#616, #571, #620), and three more the next day
(#628, #629, #630); each was rebased by hand.

`merge=union` in `.gitattributes` does not help: the queue rebases on GitHub's
side, which does not run custom merge drivers.

towncrier (pytest, pip, Twisted, attrs), changesets (pnpm, Turborepo) and
scriv share one shape: a PR adds a fragment file, and the release folds the
fragments into one section and deletes them.

## Decision

**D1 — Fragments.** A PR adds one file per entry under `changelog.d/`, named
`<section>-<slug>.md`, `<section>` one of `added`, `changed`, `deprecated`,
`removed`, `fixed`, `security`, `documentation` (Keep a Changelog's order).
The file holds the entry in the form `CHANGELOG.md` uses today. No PR edits
`CHANGELOG.md` during development; the entries already under `[Unreleased]`
stay and are released with 2.8.0. `changelog.d/README.md` says how to write one.

**D2 — `scripts/changelog_assemble.sh <version> <date>`** (bash + coreutils)
inserts `## [<version>] - <date>` under `## [Unreleased]`, one heading per
section that has fragments, fragments in file-name order within it, and
`git rm`s them. It exits 1 with nothing changed when there is no fragment.
`--dry-run` prints the section and changes nothing;
`scripts/check_changelog_assemble.sh` checks it on fixtures.

**D3 — `.github/workflows/release_prep.yml`**, `workflow_dispatch` with input
`version`: checkout `main` → D2 → rewrite `.version` in `build.zig.zon` → one
commit `release: prepare vX.Y.Z` → push `release/vX.Y.Z` → print the
`gh pr create … --draft` line in the job summary. It opens no PR: CI's
`pull_request` run does not start for a PR `GITHUB_TOKEN` opened, and opening
it is the maintainer's step. Permissions: `contents: write` only. The tag
stays manual (ADR-0156).

## Consequences

- 2.8.0 is cut by hand, as before: `workflow_dispatch` can only be run once
  the workflow is on the default branch, and this merges after the 2.8.0 tag.
  From 2.8.1 on, the release starts with a dispatch.
- PRs no longer conflict on `CHANGELOG.md`.
- Nothing checks that a PR added a fragment. Whether CI should is left open;
  a new gate needs sign-off (ADR-0212 D1), and none is added here.
- The push from `actions/checkout`'s token is first exercised on the first
  dispatch after merge — a dispatch-only workflow is not registered until it
  has run once.

## References

- Related ADRs: ADR-0156 (release is user-only), ADR-0212 D1 (gates need
  sign-off), ADR-0227 (merge queue)
- Files: `changelog.d/README.md`, `scripts/changelog_assemble.sh`,
  `scripts/check_changelog_assemble.sh`, `.github/workflows/release_prep.yml`,
  `docs/development.md` ("Cutting a release")
