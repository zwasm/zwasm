# Org transfer plan — `clojurewasm/zwasm` → a dedicated `zwasm` org

> **Doc-state**: ARCHIVED-IN-PLACE 2026-09-08. Phases 1-4 and step 11 are done — the repo
> lives at `zwasm/zwasm`, `zwasm/homebrew-tap` serves the formula (v2.6.0 today),
> `clojurewasm/homebrew-tap` carries `tap_migrations.json`, and cljw's `build.zig.zon` pins
> v2.5.0. Step 12 (cljw's own announcement) will not happen as planned; #407 is the notice
> zwasm has. Do not edit.

## Context

zwasm moves to its own GitHub organization and gains a co-maintainer. In the
same period ClojureWasm (cljw) stops being maintained: it pins zwasm v2.5.0,
announces end-of-maintenance, and is left in place. The Homebrew tap
(`clojurewasm/homebrew-tap`) currently serves BOTH `cljw` and `zwasm`, so the
two projects have to be separated there as well.

## Verified facts (checked 2026-08-12, not assumed)

- **The `zwasm` GitHub login is free** — `GET /users/zwasm` → 404. It is
  first-come; claim it before announcing anything.
- **Repo transfer keeps** issues, PRs, stars (159), watchers, forks (11),
  releases + their assets, webhooks, **repository** secrets, and deploy keys.
  Only the org-owned things do not travel.
- **Redirects**: GitHub redirects both web URLs and `git clone/fetch/push`
  after a transfer — *"All links to the previous repository location are
  automatically redirected to the new location"*. **They are destroyed
  permanently if a repo or fork is ever created at the old path.**
- **The branch ruleset is repository-scoped** (`main branch protection`,
  `source_type: Repository`) so it travels with the repo. Re-verify anyway —
  the required check is `ci-required`.
- **CI has no org-level dependency**: no workflow references `secrets.*` or
  `vars.*` beyond `GITHUB_TOKEN`, and no workflow hardcodes the org name.
- **Homebrew's tap-migration mechanism is real and installed-version-verified**
  (`Homebrew/tap.rb`, `cmd/update_report/reporter.rb`, `missing_formula.rb`):
  a `tap_migrations.json` at the tap root maps `{"<formula>": "<new/tap>"}`;
  `brew update` acts on it when it sees the formula file **deleted** from the
  old tap, and `brew install <old/tap/formula>` afterwards prints where the
  formula moved.
- **The migration is guided, not silent, for a third-party tap.** Homebrew 6.x
  only auto-migrates *trusted* taps (`implicitly_trusted?` = Homebrew-official;
  confirmed `trusted=false` for `clojurewasm/tap`). For an untrusted tap it
  prints the exact commands instead:
  `brew tap zwasm/tap` / `brew trust zwasm/tap/zwasm` / `brew reinstall zwasm`.
  **If the user has already tapped the new tap, the migration IS automatic**
  (`ensure_trusted_tap_installed!` returns early when `new_tap.installed?` —
  it just rewrites the installed keg's tap attribution).

## Tap: recommended shape

**New `zwasm/homebrew-tap` holding only the zwasm formula; the old tap keeps
`cljw` and gains a `tap_migrations.json` pointing zwasm at the new tap.**

Rejected alternatives, and why:

- *Transfer the whole tap repo to the new org*: it would drag `cljw` into an
  org that has nothing to do with it, and `brew install clojurewasm/tap/cljw`
  would then work only through a redirect that a single future repo creation
  can destroy.
- *Leave the zwasm formula in `clojurewasm/tap` forever*: the install command
  for a maintained project would permanently name an abandoned org, and the
  tap's availability would depend on that org.

Note for later (not part of this transfer): at 159 stars zwasm is past
homebrew-core's usual notability bar, so `brew install zwasm` with no tap at
all is a future option — it would mean a build-from-source formula against
whatever Zig version core ships, which is a separate piece of work.

## Ordered procedure

Sequencing matters in one place: **cljw's final zwasm pin should be written
after the transfer**, so its last commit names the new canonical URL rather
than relying on a redirect it will never be able to fix.

### Phase 1 — new org ✅

1. Create the `zwasm` GitHub organization; add the co-maintainer as an owner.
2. Enable Actions for the org and allow the workflow permissions the release
   job needs (`contents: write`).

### Phase 2 — transfer the repo ✅ (2026-08-12)

3. `Settings → General → Transfer ownership` on `clojurewasm/zwasm` → `zwasm`.
4. Immediately re-point local clones: `git remote set-url origin
   git@github.com:zwasm/zwasm.git` (this working copy included).
5. Verify in the new repo: ruleset active with `ci-required` required;
   Discussions on; private vulnerability reporting on; Actions enabled;
   releases + assets intact.
6. Smoke-test a redirect and an asset:
   `git ls-remote https://github.com/clojurewasm/zwasm.git | head -1` and
   `curl -sIL -o /dev/null -w '%{http_code}\n' https://github.com/clojurewasm/zwasm/releases/download/v2.5.0/SHA256SUMS`.

Post-transfer state: `zwasm/zwasm`, 159 stars, Discussions on, ruleset
`main branch protection` present.

### Phase 3 — in-repo references ✅ (2026-08-12)

7. Sweep the live (non-historical) references — inventory taken 2026-08-12:
   `README.md` (CI badge, Releases links, brew command, v1 link),
   `.github/CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/config.yml`,
   `.github/SECURITY.md`, `docs/development.md` (clone URL),
   `scripts/run_remote_ubuntu.sh` (comment).
   `.dev/decisions/**` and `.dev/lessons/**` are dated records — leave them.

   Swept, plus two the inventory missed: `.dev/ubuntunote_setup.md` and
   `.dev/windows_ssh_setup.md` (both ACTIVE, both carry a `git clone` URL).
   The **brew command is deliberately still `clojurewasm/tap/zwasm`** — it
   must not name a tap before phase 4 creates it. Also left alone: the
   `CHANGELOG.md` 2.3.0 entry naming the old tap (dated record of what that
   release shipped) and `.dev/archive/**`.

### Phase 4 — the tap split

8. Create `zwasm/homebrew-tap` containing `Formula/zwasm.rb` (the v2.5.0
   formula, with `homepage` and the three `url`s repointed at
   `github.com/zwasm/zwasm`) and a README.
9. In `clojurewasm/homebrew-tap`: delete `Formula/zwasm.rb`, add

   ```json
   { "zwasm": "zwasm/tap" }
   ```

   as `tap_migrations.json` at the repo root, and trim the README to cljw.
   One commit, e.g. `zwasm: migrate to zwasm/tap`.

   Then flip README.md's install command to `brew install zwasm/tap/zwasm`
   — it is the one in-repo reference phase 3 could not sweep, because a
   command naming a tap that does not exist is worse than one naming the
   old one.
10. Verify from a clean state: `brew update` on a machine with the old tap
    prints the migration guidance, and `brew install zwasm/tap/zwasm` installs
    2.5.0 (`brew audit --formula --online` clean, version infers from the tag).

### Phase 5 — ClojureWasm wind-down

11. Update cljw's `build.zig.zon` `.zwasm.url` to
    `git+https://github.com/zwasm/zwasm.git?ref=v2.5.0#<same sha>`. The
    `.hash` is content-derived and does not change — URL-only edit.
12. Then announce cljw's end of maintenance.

## Permanent rules after the transfer

- **Never create a repo or fork named `zwasm` under `clojurewasm` again** —
  that permanently deletes every redirect, including the one cljw's pinned
  dependency and every old release-asset link ride on.
- Keep `clojurewasm/homebrew-tap` alive (archived is fine — archived repos
  still fetch) so `tap_migrations.json` keeps steering old users.
- Releases stay user-only (ADR-0156); the transfer does not change that.

## Open items for the user

- Org name: `zwasm` is free today; anything else changes every URL below.
- Whether cljw's formula stays in `clojurewasm/tap` (assumed yes here).
