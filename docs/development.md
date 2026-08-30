# Developing zwasm

This is the single entry point for building, testing, and contributing to
zwasm on a fresh machine. If any other document disagrees with this one about
the development environment, this one wins (design/architecture questions are
owned by [`.dev/ROADMAP.md`](../.dev/ROADMAP.md)).

**The short version: you need Zig 0.16.0 and `wasm-tools`.** The authoritative
test gate is GitHub CI, which runs the 3-OS matrix on every pull request
(all three legs blocking) — you do not need multiple machines, SSH hosts,
Nix, or any maintainer-specific setup to contribute.

## Quick start

```sh
git clone https://github.com/zwasm/zwasm
cd zwasm
zig build                # compile the CLI + library
zig build test           # unit tests
zig build test-all       # every enabled test layer (what CI runs)
zig fmt src/             # format before committing
```

`zig version` must print `0.16.0` — the project pins it exactly
(`.github/versions.lock`, `flake.nix`). Get it from
[ziglang.org/download](https://ziglang.org/download/) or via the Nix shell
below.

## Build options

The complete `-D` surface (`zig build --help` is always authoritative):

| Option | Values (default first) | Effect |
|---|---|---|
| `-Dwasm` | `v3_0` / `v2_0` / `v1_0` | Wasm spec level; lower levels strip later proposals (incl. GC/EH at `v1_0`/`v2_0`) via compile-time DCE |
| `-Dwasi` | `p2` / `p3` / `p1` / `none` | Ordered WASI tier. `p2` = Component Model + WASI-P2 host; `p3` adds Preview-3 native async; `p1` is the lean opt-out (strips the whole component subsystem) |
| `-Dengine` | `both` / `jit` / `interp` | Engine selection compiled in |
| `-Dstrip` | `false` / `true` | Strip debug info from the CLI binary |
| `-Dsanitize` | `off` / `address` / `thread` | ASan+UBSan / TSan (Mac + Linux only — a Windows target rejects a non-`off` value at configure time rather than silently building unsanitized) |
| `-Dcompiler-rt` | `false` / `true` | Bundle Zig compiler-rt into `libzwasm.a` for non-Zig linkers (`__zig_probe_stack` etc.) |
| `-Dtrace-ringbuffer` | `false` / `true` | Compile in the diagnostic trace ringbuffer |
| `-Dtrace-stackprobe` | `false` / `true` | Compile in the JIT stack-probe diagnostic prints |
| `-Dtest-filter` | (string) | Run only matching tests in `zig build test-wasi-p3` |

There is no separate GC flag: WasmGC ships with `-Dwasm=v3_0` (the default),
and the wasm level is the strip lever.

## Tools: required vs optional

| Tool | Status | Used for |
|---|---|---|
| Zig 0.16.0 (exact) | **required** | everything |
| git | **required** | everything |
| [wasmtime](https://wasmtime.dev/) | optional | differential oracle in some suites — absent = those comparisons **skip**, never fail |
| Nix (flakes) | optional | reproducible dev shell (`nix develop`), fixture regeneration shells |
| `yq` (mikefarah v4) | optional | `.dev/debt.yaml` ledger checks in the pre-commit hook — guarded, prints an install pointer if missing |
| [wasm-tools](https://github.com/bytecodealliance/wasm-tools) | **required** | the default `zig build` installs `zwasm-spec-wasm-2-0-assert`, which embeds `spectest.wasm` generated from `test/spec/spectest.wat`; absent = the build **fails**, it is not guarded |
| hyperfine / wabt | optional | benchmarks, fixture tooling — all guarded |

The committed test corpus (spec suite, WASI conformance, real-world `.wasm`
fixtures) runs with **no toolchain beyond Zig and `wasm-tools`**. Regenerating
fixtures from source (emcc / TinyGo / Rust) is a maintainer task using the Nix
`gen` shells — contributors never need it; the `.wasm` files are committed.

## Test layers

| Command | What it runs |
|---|---|
| `zig build test` | unit tests (all zones) |
| `zig build test-spec` | Wasm spec testsuite (1.0/2.0/3.0) |
| `zig build test-wasi-p1` | WASI 0.1 fixture suite |
| `zig build test-wasi-p1-official` | official wasi-testsuite `wasm32-wasip1` corpus, `interp` + `jit` lanes. **Not in `test-all`** — see below |
| `zig build test-wasi-p3` | WASI 0.3 (Component-Model async) incl. the official conformance corpus |
| `zig build test-realworld` / `test-realworld-run` | real-world `.wasm` fixtures (parse / run) |
| `zig build test-all` | all of the above except `test-wasi-p1-official` (the CI core gate) |
| `zig build lint -- --max-warnings 0` | project linter |

`test-wasi-p1-official` is the one layer `test-all` does not carry. The corpus
is not green (D-583 carries the live count — no copy of it here, that is what
went stale last time), so CI runs it as an **advisory step** in the `gate`
job: the red shows in the run without blocking the merge. Because it cannot
block either way, it runs **only on the merge to `main`**, like the extended
checks below — your PR will not show it. It is not part of the local
`gate_commit.sh` / `gate_merge.sh` flow either, so run it directly when
touching WASI preview1. When D-583 discharges, the step joins `test-all` and
the advisory goes away (ADR-0208 D2/D3).

## The merge gate — CI is authoritative

`main` is protected: every change lands via a branch → pull request → the
required **`ci-required`** status check. CI runs
[`scripts/ci_gate.sh`](../scripts/ci_gate.sh) on **all three supported OSes** —
macOS aarch64, Linux x86_64, Windows x86_64. Your PR gets the *core* gate: fmt
+ `test-all` + the rust-host consumer + the test-discovery guard + the
ReleaseSafe-runner floor guard (ADR-0177) + the unit tests built
ReleaseSafe (Linux leg only; the mode every release binary is built in). The extended
static/build checks (lint, the build-option DCE matrix, AOT cross-compile,
`zone_check`) run on the merge to `main`, not per PR — they are up to ~20
cold-cache builds and would dominate every PR's wall-clock. All three legs are
blocking (ADR-0211 D3). There is no additional hidden gate beyond CI.

A green `zig build test` / `test-all` on a single OS is **not** sufficient
evidence for changes that touch platform branches, ABI boundaries, or feature
flips — each OS masks the other two's failures (a POSIX run says nothing about
Windows; aarch64 nothing about x86_64). Let the 3-OS PR gate judge those.

Doc-only PRs (Markdown, `docs/`, `.dev/`, `.claude/`, `LICENSE`) skip the
heavy 3-OS legs automatically and are gated by the fast `doc-truth` job
instead.

To run exactly what CI runs, locally, on your own machine:

```sh
bash scripts/ci_gate.sh                    # core (fmt + test-all)
ZWASM_CI_EXTENDED=1 bash scripts/ci_gate.sh  # + lint/DCE/AOT/zone checks (Unix)
```

## Cutting a release

Releases are cut by hand, by a maintainer, and never by automation acting on
its own (ADR-0156). Three manual steps; the rest is the `release` workflow.

1. **Bump `.version` in `build.zig.zon`.** SemVer against the previous tag —
   `git log v<previous>..main --no-merges` is the input to that call.
2. **Add the CHANGELOG section** for the new version, dated.
3. **Push the tag.** `git tag vX.Y.Z && git push origin vX.Y.Z`.

Pushing a `v*` tag triggers `.github/workflows/release.yml`, which builds
and packages all four targets in ReleaseSafe (macOS aarch64, Linux
x86_64/aarch64, Windows x86_64), then creates the GitHub Release with the
archives and `SHA256SUMS`. Nothing else in this repository needs touching.

**One step is outside this repository and is not automated: the Homebrew
formula.** `zwasm/homebrew-tap`'s `Formula/zwasm.rb` pins the release URL
and its sha256, so until it is updated `brew install zwasm/tap/zwasm` still
installs the previous version — while the README points readers at exactly
that command. Update the formula as part of the release, not after someone
reports it.

## Git hooks (recommended)

The repo ships its hooks in `.githooks/` (fast static checks at commit,
cheap ratchet audits at push). Activate them once per clone:

```sh
git config core.hooksPath .githooks
```

The Nix dev shell does this automatically; on a plain checkout it is this
one command. The hooks are advisory helpers — CI re-checks everything.

## Nix (optional)

```sh
nix develop            # pinned Zig + wabt + wasmtime + wasm-tools + lldb
nix develop .#bench    # + hyperfine, for benchmarks
```

Maintainer-only shells: `.#gen` / `.#gen-wasip3` (fixture regeneration
toolchains — see [`.dev/toolchain_provisioning.md`](../.dev/toolchain_provisioning.md)),
`.#rust-host` (the Rust embedding-consumer test).

## Things you may see referenced but do NOT need

- **Remote pre-flight scripts** (`scripts/gate_merge.sh`,
  `scripts/run_remote_*.sh`): an *optional* local mirror of the CI matrix for
  anyone with spare x86_64 Linux / Windows machines. CI is the authoritative
  gate — you never need these. To use them, copy
  [`scripts/dev_hosts.env.example`](../scripts/dev_hosts.env.example) to
  `scripts/dev_hosts.env` (gitignored) and point the three values at your own
  hosts; every remote-gate script sources it. No host name is baked into the
  repo, so until you write that file `gate_merge.sh` simply skips the remote
  legs.
- **Gitignored local scratch**: a few scripts probe gitignored local paths and
  skip cleanly when they are absent. No build, test, or review path requires
  any file outside the committed tree.
- **Reference clones** (`~/Documents/OSS/...` paths in `.dev/` docs): a local
  layout for reading other runtimes' source
  ([`.dev/reference_clones.md`](../.dev/reference_clones.md)) — not required
  to build, test, or review.
- **`.claude/`**: AI-agent workflow scaffolding (skills, session rules).
  Interesting as documentation of how the project is developed, but nothing
  in it is needed to contribute by hand.

## Project conventions (pointers)

- **Where decisions live**: [`.dev/ROADMAP.md`](../.dev/ROADMAP.md) (mission /
  architecture / phase plan — the design SSOT),
  [`.dev/decisions/`](../.dev/decisions/) (ADRs),
  [`.dev/debt.yaml`](../.dev/debt.yaml) (tech-debt ledger),
  [`.dev/lessons/`](../.dev/lessons/) (observational notes).
- **Language policy**: code, comments, commits, docs — English.
- **Layering**: `src/` is organized in import-ordered zones (support/platform
  → ir/runtime/parse/validate → interp/engine/wasi → cli/api); enforced by
  `scripts/zone_check.sh`. See [`.claude/rules/zone_deps.md`](../.claude/rules/zone_deps.md).
- **Contribution flow, license, review expectations**:
  [`.github/CONTRIBUTING.md`](../.github/CONTRIBUTING.md).
- **Using zwasm (not developing it)**: [`docs/tutorial.md`](tutorial.md).
