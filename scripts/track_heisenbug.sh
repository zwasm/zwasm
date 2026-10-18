#!/usr/bin/env bash
# Track per-run outcomes for a named heisenbug, accumulate streak
# state, and surface discharge candidacy when the threshold is met.
#
# Originally designed for D-134 (OrbStack `zwasm-spec-wasm-2-0-assert`
# layout-sensitive SEGV — closed 2026-05-17 by ADR-0067 ubuntunote
# pivot, root cause Rosetta 2). Retained for any future flake that
# requires "did the bug stop reproducing?" empirical evidence
# rather than narrative claim (cf.
# `.dev/lessons/2026-05-16-narrative-claim-vs-landed-state.md`).
#
# Storage: `private/heisenbug-<name>.log` — gitignored. Each run
# appends one line:
#   <ISO-timestamp> <outcome> <commit-sha> <streak>
# Outcomes are caller-defined; common: silent, fail, segv.
#
# Usage:
#   bash scripts/track_heisenbug.sh <name> <outcome> [--threshold N]
#     - record one outcome (default threshold = 5)
#   bash scripts/track_heisenbug.sh <name> --status
#     - print current streak / last 10 entries without recording
#   bash scripts/track_heisenbug.sh <name> --reset
#     - clear history (rare; usually only when discharging)
#
# Discharge rule (project-wide): documented in
# `.claude/references/investigation_discipline.md` §2. Default: N consecutive
# `silent` outcomes since the last `fail`/`segv` → discharge
# candidate. The autonomous /continue loop checks this each resume
# for active heisenbug debt rows. (D-134 — the original
# canonical case — was closed without using this script's streak
# threshold; root-cause investigation outpaced empirical
# discharge.)

set -uo pipefail

cd "$(dirname "$0")/.."

if [ $# -lt 2 ]; then
  echo "usage: $0 <name> <outcome|--status|--reset> [--threshold N]" >&2
  exit 2
fi

name="$1"
shift
mode_or_outcome="$1"
shift

# Sanitise name (no slashes, only alnum + hyphen + underscore).
case "$name" in
  *[!a-zA-Z0-9_-]*) echo "ERROR: name must be [a-zA-Z0-9_-]+; got: $name" >&2; exit 2 ;;
esac

log="private/heisenbug-$name.log"
mkdir -p private

threshold=5
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold) threshold="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

case "$mode_or_outcome" in
  --status)
    if [ ! -f "$log" ]; then
      echo "no history for $name"
      exit 0
    fi
    echo "=== $name (last 10) ==="
    tail -10 "$log"
    last_streak=$(tail -1 "$log" | awk '{print $4}')
    last_outcome=$(tail -1 "$log" | awk '{print $2}')
    echo ""
    echo "current streak: $last_streak (last outcome: $last_outcome)"
    if [ "$last_outcome" = "silent" ] && [ "$last_streak" -ge "$threshold" ]; then
      echo ""
      echo "*** DISCHARGE CANDIDATE: $last_streak consecutive silent runs ≥ threshold $threshold ***"
      echo "    See .claude/references/investigation_discipline.md §2 for the close procedure."
    fi
    exit 0
    ;;
  --reset)
    if [ -f "$log" ]; then
      mv "$log" "$log.archived-$(date -u +%Y%m%dT%H%M%SZ)"
      echo "archived $log"
    fi
    exit 0
    ;;
esac

# Record-mode: $mode_or_outcome is the outcome string.
outcome="$mode_or_outcome"
case "$outcome" in
  *[!a-zA-Z0-9_-]*) echo "ERROR: outcome must be [a-zA-Z0-9_-]+; got: $outcome" >&2; exit 2 ;;
esac

# Streak is consecutive `silent` outcomes from the most-recent end.
# Any non-silent outcome resets to 0; a silent outcome increments
# the prior streak by 1.
prev_streak=0
prev_outcome=""
if [ -f "$log" ]; then
  # Defensive: malformed last line (e.g. truncated) yields empty
  # $4; default to 0 so arithmetic doesn't fail under `set -u`.
  prev_streak=$(tail -1 "$log" | awk '{print $4}')
  prev_streak=${prev_streak:-0}
  prev_outcome=$(tail -1 "$log" | awk '{print $2}')
fi

if [ "$outcome" = "silent" ]; then
  streak=$((prev_streak + 1))
else
  streak=0
fi

sha=$(git rev-parse --short HEAD 2>/dev/null || echo "no-git")
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

printf '%s %s %s %d\n' "$ts" "$outcome" "$sha" "$streak" >> "$log"

echo "$name: $outcome @ $sha (streak: $streak)"
if [ "$outcome" = "silent" ] && [ "$streak" -ge "$threshold" ]; then
  echo ""
  echo "*** DISCHARGE CANDIDATE: $streak consecutive silent runs ≥ threshold $threshold ***"
  echo "    Per .claude/references/investigation_discipline.md §2, the autonomous"
  echo "    loop may now propose closing the corresponding debt row."
fi
