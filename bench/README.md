# bench/

Benchmark history (append-only) and runner data.

## Layout

```
bench/
├── README.md          # this file
├── latency/           # steady-state per-call latency runner (ADR-0209)
├── results/
│   ├── history.yaml           # committed, append-only, phase-boundary entries only
│   ├── latency_history.yaml   # committed, append-only, per-call latency (ADR-0209)
│   └── recent.yaml            # gitignored, rolling per-commit
├── runners/           # bench wasm samples (Phase 10+)
│   └── src/           # source for runners (committed)
└── fixtures/          # bench-specific data files (Phase 10+)
```

## Two measurement kinds

Everything driven by `scripts/run_bench.sh` times a **whole process** through
`hyperfine`: spawn, plus instantiate, plus execute. That is one guest
invocation per process, so a cost paid on *every* call is paid once and
disappears into process startup.

`bench/latency/` measures the other shape: instantiate once, call many times,
time only the calls. It exists to make D-584 and D-585 checkable, not to add a
performance goal — §2 P3 keeps cold-start as the primary metric. It needs no
`hyperfine` and no dev shell (plain Zig), so it also covers `windowsmini`,
which `run_bench.sh` cannot reach (D-249).

```sh
zig build bench-latency                                   # measure, print YAML
bash scripts/record_latency_bench.sh --reason "<tag>: <gist>"   # + append
```

Rationale and what each harness can and cannot see:
[`ADR-0209`](../.dev/decisions/0209_percall_latency_bench.md).

To compare two builds, copy their runners into one directory and start both
from there: on x86_64 Linux the same runner started from a path 21 characters
longer measured the JIT rows and `stack_limit_query_ns` 2% slower.

The `results/` split (committed `history.yaml` vs gitignored
`recent.yaml`) was introduced 2026-05-04 per §9.6 / 6.H +
ADR-0012 §7. The two-file approach prevents per-commit bench
runs from inflating git history; only phase-boundary results are
preserved long-term.

## Cadence (ROADMAP §12.4)

- **Local manual**: `bash scripts/run_bench.sh [--quick]` writes
  `bench/results/recent.yaml`. Adding `--phase-record
  --reason="<tag>: <gist>"` also appends one row to
  `bench/results/history.yaml`. `scripts/record_merge_bench.sh`
  is the wrapper.
- **Per-merge recording is retired (ADR-0211 D2, 2026-08-19)**: the
  convention assumed merges were local events and went unused once
  the merge gate moved to CI. `history.yaml` rows now come from
  deliberate recordings only — a local `--phase-record` run or a
  `bench.yml` dispatch.
- **Nightly gross-regression watch**:
  [`.github/workflows/bench_watch.yml`](../.github/workflows/bench_watch.yml)
  runs [`scripts/bench_watch.sh`](../scripts/bench_watch.sh) daily on
  macos-15 + ubuntu-22.04: same-run A/B of HEAD vs the latest `v*`
  release tag over a 5-fixture canary set, alerting (via the
  scheduled run failing, which emails the cron author) when HEAD is
  ≥2x slower on ≥2 fixtures. It commits nothing and gates nothing —
  `history.yaml` stays curated, and a breach is an investigation
  trigger per ROADMAP §12.1, not a block.
- **On-demand CI**: [`.github/workflows/bench.yml`](../.github/workflows/bench.yml)
  runs `--quick --phase-record` across `macos-latest`
  (aarch64-darwin) + `ubuntu-latest` (x86_64-linux). **Trigger is
  `workflow_dispatch` only** — the push trigger was disabled
  2026-05-25 because local development is the primary path and the
  auto-runs produced noise. It watched `zwasm-from-scratch`, the
  then-current dev branch, not `main`. Start a run with
  `gh workflow run bench.yml --ref main`. Each arch uploads a YAML
  fragment as an artifact; an `aggregate` job merges them in
  arch-name-sorted order into `history.yaml` and pushes one bot
  commit tagged `[skip ci]`. windowsmini stays a local-only path
  (no GitHub-hosted Windows bench runner).

## Schema (ROADMAP §12.3)

```yaml
- date: 2026-XX-XXTHH:MM:SSZ
  commit: <full SHA>
  arch: aarch64-darwin | x86_64-linux | x86_64-windows
  reason: "<phase-tag>: <one-line>"
  runs: 5
  warmup: 3
  benches:
    - name: <bench-name>
      mean_ms: 12.34
      stddev_ms: 0.45
      min_ms: 11.80
      max_ms: 13.10
```

The recorded values are `mean / stddev / min / max` as produced
by hyperfine's `--export-json`. Earlier drafts of this README
documented a `median_ms` field; the script never wrote one. Use
`mean_ms` as the primary central-tendency field (rationale:
hyperfine reports mean, and we keep tool fidelity rather than
compute a derivative). For sub-millisecond fixtures, treat
`mean_ms` as ordinal — `min_ms / max_ms` give the dispersion
shape. (Schema clarification 2026-05-12 / §9.9-j-2 per
ADR-0056.)

`bench/results/history.yaml` is append-only (ROADMAP §A9). Rows
are added by `scripts/run_bench.sh --phase-record` (manual /
phase boundary) and the CI bench-aggregate job
([`.github/workflows/bench.yml`](../.github/workflows/bench.yml),
`workflow_dispatch` only).
Never edit historical rows.

`bench/results/recent.yaml` is gitignored and overwritten on
every local run.

## No fixed numeric targets (ROADMAP §12.1)

Per-phase numeric ratios (e.g. "within 1.5× of wasmtime") are
deliberately not set. Goodhart's law: a numeric target distorts
behaviour toward the number, not the underlying goal. Comparison
against reference runtimes (wasm3, wasmtime baseline, wasmtime
cranelift, wasmer singlepass) is recorded but not gated.

## Current status (post-Phase-7, Phase-8 onward)

`scripts/run_bench.sh` is hyperfine-driven; the `bench.yml` CI job
records two arch rows when it is dispatched (per the cadence above) —
nothing appends to `history.yaml` automatically (the scheduled
`bench_watch.yml` measures but never records). Local phase-boundary rows continue to
land via `--phase-record`, and are the path that actually gets
used. The pre-Phase-6
trap-time baseline rows are preserved per ADR-0011 §3.
