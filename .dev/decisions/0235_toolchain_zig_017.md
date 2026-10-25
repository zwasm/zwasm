# 0235 — zwasm pins one Zig minor exactly, and moves the pin only in a zwasm minor release

- **Status**: Accepted (2026-10-31, on PR #648)
- **Date**: 2026-10-24
- **Author**: Junji Takakura
- **Tags**: build, toolchain, release

## Context

zwasm has pinned Zig 0.16.0 since the v2 campaign began. Zig 0.17.0 was
released on 2026-10-01 (#624). Zig changes the language and `std` in every
minor, so a pin that floats or spans two minors either breaks a build without
a zwasm change or needs version-conditional code. The pin also reaches
embedders: the Zig API is consumed as a package dependency, so the pin is the
Zig an embedder must build with.

## Decision

1. **zwasm pins the latest Zig minor that it has been ported to, exactly**
   (`X.Y.Z`): `build.zig.zon` `minimum_zig_version`, `flake.nix`,
   `.github/versions.lock` and every workflow that installs Zig name the same
   version.
2. **The pin moves to a new Zig minor only in a zwasm minor release.** The
   release's CHANGELOG `### Changed` states that this version and later need
   Zig X.Y. 2.8.x stays on 0.16.0; 2.9.0 is the first release on 0.17.0.
3. **A Zig patch release is followed in its own PR**, not alongside other
   work.
4. **A port changes no behaviour.** New lints, new `std` APIs and other
   improvements the new Zig makes possible land in later PRs.

## Consequences

- An embedder can read the Zig it needs from the zwasm version alone.
- Dependents that repeat the pin (`zwasm-rust-sdk`, `containerd-shim-zwasm`,
  `wasmi-benchmarks`) move after the zwasm release that moves it.

## Revision history

| Date       | SHA          | Note |
|------------|--------------|------|
| 2026-10-31 | `<backfill>` | Initial, Accepted on PR #648; landed with the 0.17.0 pin it defines. |
