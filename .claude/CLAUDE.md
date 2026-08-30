# zwasm v2

A from-scratch WebAssembly runtime in Zig 0.16.0.

> Pointers only — detailed plans live in [`.dev/ROADMAP.md`](../.dev/ROADMAP.md),
> runnable procedures in [`.claude/skills/`](skills/). (The autonomous
> `/continue` build-campaign loop is RETIRED post-merge — maintenance mode.)

## Identity

**Project name (in all docs and the published artifact): `zwasm`.**
Binary / package: `zwasm`.

zwasm v2 is a ground-up redesign of zwasm (v1 git history at commit 517cc5a).
**As of 2026-07-01 the from-scratch campaign is COMPLETE**: v2 shipped to
`main` (replace-merge `dbd43f89e`); v1 is frozen at tag `v1.11.1`.

- Working dir: `~/Documents/MyProducts/zwasm/` (unified — the separate
  `zwasm_from_scratch/` working dir is retired).
- **`main` is the trunk.** Dev model: cut a `develop/<slug>` branch from
  `main`, PR to `main`. `main` is **server-side ruleset-protected**: no direct
  push, PR required, and the `ci-required` status check (CI's 3-OS gate) must be
  green to merge; only the repo admin can bypass. Doc-only PRs auto-skip the
  heavy gate (still green via `ci-required`). The local `scripts/gate_merge.sh`
  (3-host SSH fan-out) is an **optional** pre-PR pre-flight mirroring CI
  (ADR-0076 D9) — CI's `ci-required` is authoritative. `--force`
  always forbidden. Root is kept lean (ADR-mirroring the CW layout): this file
  is `.claude/CLAUDE.md`; community-health files (CONTRIBUTING / CODE_OF_CONDUCT /
  SECURITY) are in `.github/`; `THIRD_PARTY.md` is in `legal/`; `examples/` is
  under `docs/examples/`. Only README / LICENSE / CHANGELOG / build+flake files
  remain at root.
- **Release stays user-only (ADR-0156)**: tag / publish / cutover are
  manual. The release line is the latest `v2.x` tag (see CHANGELOG /
  GitHub Releases — do NOT hardcode it here, it rots). Cut = bump
  `build.zig.zon` + CHANGELOG section + push the `vX.Y.Z` tag →
  `release.yml` auto-builds + publishes. See
  [`.dev/archive/migration_v1_to_v2.md`](../.dev/archive/migration_v1_to_v2.md).
- v1 ABI compatibility is out of scope; the C/Zig/CLI surfaces broke v1 on
  purpose (ADR-0156).

Read-only reference clones: `~/Documents/OSS/` (upstream runtimes + specs) and
`~/Documents/MyProducts/ClojureWasm/` (cljw, the downstream consumer). Full
list at [`.dev/reference_clones.md`](../.dev/reference_clones.md); mirrored in
the `additionalDirectories` setting. Never edit or commit from these paths.
v1 is not a separate clone — it is tag `v1.11.1` in this repository.

## Language policy

Public project. **English by default** for code, comments, identifiers,
commit messages, README, ROADMAP, ADRs, `.dev/`, `.claude/`, all config.
**Japanese** for chat replies only — set by the `Japanese` output style
([`.claude/output_styles/japanese.md`](output_styles/japanese.md), via
`outputStyle` in `settings.json`). That single setting is sufficient; the
SessionStart hook injects no language directive. To work in another
language, override `outputStyle` per-machine in `settings.local.json`.

**Bilingual exception**: meta-prose pointers ("詳細は <ref> を参照。")
and culturally-loaded one-word labels (例: 気付いたら即追加, 裏取り)
where they anchor a concept more cleanly. Never in normative rule
text or code identifiers.

## Frozen invariants (read once per session)

- **Release is user-only (ADR-0156)**: never autonomously tag, publish, or
  cut over to a release. Tag / publish / version come only from an explicit
  user message. (The v2 build campaign — Phase 16 完成形 — is complete; the
  project is in maintenance. v2 is on `main`; v1 frozen at v1.11.1.)
- **ROADMAP §18 amendment**: routine `[x]` flips + SHA backfills + next
  phase table expansion = no ADR. Deviation in §1 / §2 (P/A) / §4
  (architecture / Zone / ZirOp) / §5 (layout) / §9 phase scope/exit /
  §11 / §14 forbidden list = file `.dev/decisions/NNNN_<slug>.md` per
  §18.2 FIRST. **Carve-out (ADR-0132)**: re-sequencing/re-scoping the
  ROADMAP because a phase's exit/scope references genuinely-later-phase
  work (§18.1 first bullet) is **AUTONOMOUS** — file the ADR + §18.2
  four-step + forward-ref each deferred item to its true phase, and
  proceed without stopping (no user-flip). Default posture =
  autonomous-with-ADR; surface only for bucket-2/3 genuine blocks.
- **CI gate is authoritative (post-v2.0.0 maintenance; ADR-0076 D9)**: `main`
  is PR-only, and CI's `ci-required` runs `scripts/ci_gate.sh` on **all 3 OSes**
  (aarch64-macos + x86_64-linux + x86_64-windows) for **every** PR. That IS the
  merge gate. A PR run gets the **core** gate — zig fmt + `test-all` +
  `bench-latency-build` (compile-only, ADR-0209) + the test-discovery guard,
  plus on the Linux leg only `run-rust-host` and the unit tests built
  ReleaseSafe (#347). The **extended** checks (lint /
  build-option DCE / ReleaseSafe JIT smoke / AOT cross-compile / `zone_check` /
  `spill_aware`) are gated on `ZWASM_CI_EXTENDED`, which `ci.yml` sets only on
  the **push to `main`** — they are up to ~20 cold-cache ReleaseSafe builds and
  would dominate every PR's wall-clock (rationale in `ci.yml`).
  Doc-only PRs auto-skip the heavy legs (still green via `ci-required`). The
  local `scripts/gate_merge.sh` (3-host SSH fan-out) + `scripts/gate_commit.sh`
  (pre-commit) are now **optional pre-PR pre-flight** mirroring CI — no longer
  load-bearing for merge safety. The campaign-era Windows-BATCHED / `--suspend`
  cadence is RETIRED (its scripts are deleted; ADR-0174 superseded-in-part).
  Per-machine host aliases for the optional fan-out live in
  `scripts/dev_hosts.env` (gitignored; template `dev_hosts.env.example` —
  ADR-0206).
  `file_size_check` is **advisory** (ADR-0099 2026-07-03, not a commit block);
  `spill_aware_check` is wired into `gate_commit.sh` + CI `ci_gate.sh` extended
  (D-505 triage done; BASELINE=0). OrbStack retired per ADR-0067 (D-134); scratch only.
- **Context budget**: the **1M** window is in effect (the prior 200K pin
  `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` was removed 2026-05-31 — it made the
  window hit 100% fast and the squeeze, not the working set, was the felt
  pain). The real levers are **structural, not a window cap**: (1) lean
  auto-loaded rules — `.claude/rules/*.md` are injected IN FULL by their
  `paths:` frontmatter glob, so each carries only the load-bearing
  invariant + enforcement pointer; verbose rationale lives in
  `.claude/references/*.md` (no frontmatter → on-demand read only); (2)
  fork big reads/surveys to subagents AND have them return ≤30-line
  summaries (the report returns into main context too); (3) the
  SessionStart + `PostCompact` brief (`scripts/print_handover_brief.sh`)
  re-anchors on live state — open PRs/issues + last commits
  (`.dev/handover.md` is frozen; discussion #207 plank 4). Full rationale:
  `.claude/references/context_budget.md`.

## Working agreement (short list)

- TDD: red → green → refactor.
- **Design priority (ADR-0153)**: the bar is clean final design +
  full-featured + 100% spec + **lightweight-yet-fast**. A *measured*
  structural deficiency in one of those — esp. a v1-parity miss (§1.2)
  rooted in a deliberate v2 simplification — **schedules a rework, not a
  defer-past-v0.1.0** (v0.1.0 is not urgent; correctness + design
  quality gate, not the date). Run it as a correctness-first
  **rework campaign** per
  [`continue/REWORK.md`](skills/continue/REWORK.md) (I+II hard
  gates before redesign code), WITHIN single-pass P3/P6 (no optimising
  tier). Never over correctness.
- Step 0 Survey before each task per
  [`textbook_survey.md`](rules/textbook_survey.md). No copy-paste
  from v1 per [`no_copy_from_v1.md`](rules/no_copy_from_v1.md).
- Commit at natural granularity. `private/` is gitignored agent scratch
  (not authoritative; promote to ROADMAP/ADR/lesson/debt if it
  matters).
- Subagent fork for: Step 0 surveys, large test logs (>200 lines),
  cross-codebase searches (>5 files), audit/simplify/security-review
  fan-out.
- Debt + lessons live in git: [`.dev/debt.yaml`](../.dev/debt.yaml) (ledger),
  [`.dev/lessons/`](../.dev/lessons/) (re-derivable observations, INDEX.md is
  the keyword index).
- Don't paper over absences. Walk the 3-step procedure in
  [`extended_challenge.md`](rules/extended_challenge.md) before
  declaring something missing or shipping a SKIP-X workaround.
- Bound every backgrounded long-runner with `timeout` per
  [`orphan_prevention.md`](rules/orphan_prevention.md). The
  remote gates self-guard via `scripts/orphan_guard.sh` (reap + bound);
  compounds with Microsoft Defender's `.zig-cache`/`zig-out` scan
  (cf. D-028) so orphans hurt double here.

## Skills

- [`continue`](skills/continue/SKILL.md) — resume context + the
  per-task TDD loop (red→green→refactor). Triggers on "続けて" / "/continue"
  / "resume". **Maintenance mode** (post-campaign): no auto-loop, no
  self-re-arm, no direct-to-`main` push — work on a `develop/<slug>` branch
  → PR. The `LOOP/GATE/RESUME/REWORK/STOP_BUCKETS` sub-docs are the retired
  campaign machinery, kept as historical reference.
- [`audit_scaffolding`](skills/audit_scaffolding/SKILL.md) —
  adaptive audit (staleness / bloat / lies / debt+lessons coherence /
  extended-challenge consistency) across CLAUDE.md, `.dev/`, `.claude/`,
  `scripts/`.
- [`meta_audit`](skills/meta_audit/SKILL.md) — deliberate-skepticism audit
  against ROADMAP §1/§2/§9/§14/§15 and recent ADRs. User-requested.
- [`dispatch_consistency_audit`](skills/dispatch_consistency_audit/SKILL.md) —
  three-way consistency of the ZirOp dispatch substrate. On request.
- [`debug_jit_auto`](skills/debug_jit_auto/SKILL.md) — SEGV /
  miscompile / runtime-crash investigation toolkit.

## Layout (pointer)

`src/` Zig source (parse / validate / ir / runtime / instruction /
feature / engine / interp / wasi / api / cli / diagnostic / support /
platform — shape per ADR-0023 + ADR-0024).
`include/` public C headers. `build.zig` build script. `flake.nix` Nix
dev shell pinned to Zig 0.16.0.
`.dev/` ROADMAP + debt + lessons + decisions + phase_log + setup
docs (+ the frozen handover.md).
`.claude/` settings, skills, rules, output styles.
`scripts/` gate, zone_check, file_size_check, bench, run_remote_*, ...
`test/` unified `zig build test-all` aggregator + per-layer suites.
`bench/` append-only benchmark history. `private/` gitignored scratch.
`tools/lint/` the `zig build lint` sub-build — the only package here with
a dependency (ADR-0214); the root `build.zig.zon` has none.

## Build & test (pointer)

```sh
zig build               # compile
zig build test          # unit tests
zig build test-spec     # spec testsuite
zig build test-all      # all enabled layers
zig fmt src/            # format
```

Host/CI invocation discipline:
[`docs/development.md`](../docs/development.md) (ADR-0206 SSOT; the loop-era
[`GATE.md`](skills/continue/GATE.md) is historical reference).

Realworld `.wasm` fixtures are generated on the **Mac host only** via
`nix develop .#gen` (emcc / tinygo / rustc-wasm / go / clang+lld, pinned
in `flake.nix`); the committed `.wasm` runs on the test hosts through the
Zig-built edge-runner (no toolchain there). See
[`.dev/toolchain_provisioning.md`](../.dev/toolchain_provisioning.md).

## Pre-commit gate

[`scripts/gate_commit.sh`](../scripts/gate_commit.sh) — local **pre-commit**
gate (zig fmt + `file_size_check` (advisory, ADR-0099) + `spill_aware_check
--gate` (D-505) + the `check_*` integrity scripts; docs-only short-circuit;
`--fast` defers `zig build test`/`lint`/`zone_check` to CI). Manual commits
call it before `git commit`.

The **authoritative** merge gate is CI's `ci-required` 3-OS `scripts/ci_gate.sh`
run on every PR. [`scripts/gate_merge.sh`](../scripts/gate_merge.sh) (local
3-host SSH fan-out) is now an **optional** pre-PR pre-flight that mirrors CI
(ADR-0076 D9) — not required for merge safety.

## References

- [`.dev/ROADMAP.md`](../.dev/ROADMAP.md) — single source of truth (mission,
  principles, phase plan). Conflicts → ROADMAP wins.
- [`.dev/handover.md`](../.dev/handover.md) — **FROZEN 2026-08-20**
  (discussion #207 plank 4; ADR-0212 D1): campaign-era state snapshot,
  kept as-is. Current state = open PRs + issues (the SessionStart brief
  prints them).
- [`.dev/debt.yaml`](../.dev/debt.yaml) — debt ledger.
- [`.dev/lessons/`](../.dev/lessons/) — observational notes (see INDEX.md).
- [`.dev/decisions/`](../.dev/decisions/) — ADRs (load-bearing deviations
  only).
- [`.dev/phase_log/`](../.dev/phase_log/) — sub-chunk records (§18.3).
- [`.dev/proposal_watch.md`](../.dev/proposal_watch.md) — Wasm proposal
  tracking (quarterly).
- [`ADR-0118`](../.dev/decisions/0118_meta_loop_consolidation.md) — meta-
  ADR for the rule/skill consolidation + bundle-mode that shaped the
  current loop scaffolding.
