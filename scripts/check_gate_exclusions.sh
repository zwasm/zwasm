#!/usr/bin/env bash
# check_gate_exclusions.sh — no build input hides behind the doc-only skip.
#
# `ci.yml`'s `changes` job skips the 3-OS gate when every changed path matches
# `scripts/gate_exclusions.regex`. That list names EXCLUSIONS, so a new build
# input is gated unless someone lists its path; the hole is a build input that
# already sits under a listed path — #297, where `build.zig` compiled
# `docs/examples/` and `^docs/` skipped it. This walks what the gate reads
# (`build.zig`, `ci_gate.sh`, the scripts it names) for quoted paths and fails
# on one the skip would swallow. `build.zig.zon` is not walked: its `.paths`
# lists what `zig fetch` packages, not what the gate runs.
#
#   bash scripts/check_gate_exclusions.sh          # informational, exit 0
#   bash scripts/check_gate_exclusions.sh --gate   # exit 1 on findings
set -euo pipefail
MODE="${1:-info}"
cd "$(dirname "$0")/.."

REGEX=scripts/gate_exclusions.regex
[ -s "$REGEX" ] || { echo "[check_gate_exclusions] FAIL — $REGEX missing or empty" >&2; exit 1; }

# The list, the workflow that applies it, and this script are inputs too: a
# change to one of them must never be doc-only.
inputs="$REGEX .github/workflows/ci.yml scripts/check_gate_exclusions.sh build.zig scripts/ci_gate.sh $(grep -oE 'scripts/[A-Za-z0-9_./-]+\.sh' scripts/ci_gate.sh | sort -u | grep -v '^scripts/ci_gate\.sh$' | tr '\n' ' ')"

findings=$(
  for f in $inputs; do
    # Comment lines dropped; then every quoted string without whitespace. The
    # second filter is the step's own `docs/examples/` carve-out (non-`.md`
    # there is code), so a path it rescues is not a finding.
    { printf '%s\n' "$f"; grep -vE '^[[:space:]]*(#|//)' "$f" \
      | grep -oE "\"[^\"[:space:]]+\"|'[^'[:space:]]+'" \
      | sed -E 's/^.//; s/.$//'; } \
      | grep -Ef "$REGEX" \
      | awk '!(/^docs\/examples\// && !/\.md$/)' \
      | sed "s|^|$f: |" || true
  done
)

n=$(printf '%s\n' "$findings" | grep -c . || true)
if [ "$n" -gt 0 ]; then
  printf '%s\n' "$findings" >&2
  echo "[check_gate_exclusions] $n build input(s) match $REGEX — a change to one skips the 3-OS gate; narrow the pattern or move the file" >&2
  [ "$MODE" = "--gate" ] && exit 1
  exit 0
fi
echo "[check_gate_exclusions] OK ($(echo $inputs | wc -w) inputs walked)" >&2
