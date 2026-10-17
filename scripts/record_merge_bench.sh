#!/usr/bin/env bash
# Manual bench recorder — the §12.4 deliberate-recording entry point. Thin
# wrapper over scripts/run_bench.sh, which is the real hyperfine engine
# (builds zwasm ReleaseFast + runs its bench/runners/ inventory,
# writing bench/results/recent.yaml).
#
# Without --phase-record: overwrites recent.yaml (gitignored, per-commit).
# With --phase-record: ALSO appends ONE entry to bench/results/history.yaml
# (committed, append-only) tagged with commit + arch + reason. Arch is
# auto-detected from `uname` ({aarch64-darwin, x86_64-linux, x86_64-windows}).
#
# Cadence (ROADMAP §12.4, ADR-0211 D2): history.yaml rows come from
# DELIBERATE recordings only — run this at phase boundaries or when a change
# is performance-relevant, with the intent in `--reason`. The retired
# per-merge convention lives in git history; the automated gross-regression
# watch is bench_watch.yml (commit-free, see scripts/bench_watch.sh).
#
# Usage:
#   bash scripts/record_merge_bench.sh                  # recent.yaml only
#   bash scripts/record_merge_bench.sh --quick          # quick (3 runs + 1 warmup)
#   bash scripts/record_merge_bench.sh --phase-record \
#        --reason='p11: <gist>'                         # append to history.yaml
#
# All flags forward verbatim to run_bench.sh (--quick / --phase-record /
# --reason= / --bench= / --compare= / --capture-rss / --windows-subset).
set -euo pipefail
cd "$(dirname "$0")/.."

exec bash scripts/run_bench.sh "$@"
