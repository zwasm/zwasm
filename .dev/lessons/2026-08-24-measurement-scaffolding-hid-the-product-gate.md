# Splitting the measurement scaffolding out of a patch exposed a measurement gap

**Date**: 2026-08-24
**Keywords**: D-596, liveverify, ZWASM_DEBUG dark under runners, dbg.anyActive too broad, measurement patch as a separate file, pristine-tree control

**Citing**: `#269` (the parity check that carried the scaffolding)

## What happened

The D-596 parity check was prototyped with two gates in one patch: the product
one (`dbg.on("liveverify")`) and a direct env read added because `dbg` is never
initialised under the test runners. Review asked for the env read to move to a
separate file. Splitting it meant running `test-all` through the *product* gate
for the first time — `ZWASM_DEBUG=liveverify zig build test-all` — and 16 tests
failed. A control on **pristine** `5058d517f` with no patch produced the same 16
failures, so the patch was not the cause.

## Root cause

Not one. Two facts had been true the whole time and were never in the same run:
`dbg.on` is dark under every runner (`dbg.initFromEnv` has two call sites,
neither reachable from `test/`), and setting `ZWASM_DEBUG` at all makes
`dbg.anyActive()` true (`src/support/dbg.zig:162-168` tests only
`entry_count > 0`), which makes `zwasm compile` refuse
(`aot/produce.zig:106`) and fails the eight AOT `.cwasm` tests in
`src/cli/run.zig`. While the combined patch existed, every corpus run went
through the second env var, so neither fact was ever exercised.

## Fix (or path forward)

No fix — an observation. A patch carrying its own measurement scaffolding is
never run the way it will ship; separating the two forces a run of the product
configuration, which is where the gap was.

## Why this didn't surface earlier

The combined gate short-circuited: `dbg.on(…) or getenv(…) != null`. Every
sweep set the second variable, so the first was never the deciding term and
`anyActive()` was never true during a corpus run.

## Re-derivability

Re-derivable only by someone who runs a lane with `ZWASM_DEBUG` set — which
nothing in the repo does, since no lane reaches `initFromEnv`.

## Related

- D-596 — the parity check; its `Reach` paragraph records the same gap.
- The split also showed both libc gates passing that patch: `zone_check.sh`
  reads imports only, `check_libc_boundary.sh` classifies by symbol.
