#!/usr/bin/env bash
# check_wasi03_coverage_claims.sh — keep prose in sync with the real WASI 0.3
# coverage.
#
# As of ADR-0205 (the wasi03-full campaign) zwasm serves ALL SIX WASI 0.3.0
# proposals — cli / clocks / random / filesystem / sockets / http — with the
# official `wasm32-wasip3` corpus 45/45 green. "http / sockets data-plane is
# pending" prose survived the campaign in README + migration doc; an ungated
# coverage claim rots exactly like the D-312 compiler-rt lie and the #163
# default-engine lie (lesson 2026-08-03-ungated-negative-doc-claim-…).
#
# Two assertions:
#   1. ANCHOR — the conformance harness still enables the http-client test
#      (the last-landed 0.3 leg; its presence proves http is served). If the
#      corpus is ever pared back, this fires first and forces the sweep to be
#      redone rather than silently inverted.
#   2. SWEEP — no live tracked file claims a 0.3 proposal is unimplemented /
#      pending / not-yet-complete.
#
# Modes:
#   bash scripts/check_wasi03_coverage_claims.sh          # informational, exit 0
#   bash scripts/check_wasi03_coverage_claims.sh --gate   # exit 1 on any hit
#
# Historical records are exempt: they were true when written and are not
# instructions to a reader.

set -u

mode="${1:-info}"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root" || exit 2

ANCHOR_FILE="src/api/component_wasi_p3.zig"

# Dated records, not live claims.
EXEMPT_RE='^(bench/|CHANGELOG\.md$|\.dev/archive/|\.dev/lessons/|\.dev/decisions/|\.dev/phase_log/|\.dev/meta_audits/|\.dev/debt\.yaml$|\.dev/handover\.md$|\.dev/proposal_watch\.md$|\.devils-advocate/|scripts/check_wasi03_coverage_claims\.sh$)'

# Phrasings that assert a WASI 0.3 proposal is NOT served. Matched
# case-insensitively; the proposal name must co-occur with a not-done word on
# the same line. Narrow by design — a loose pattern false-positives on true
# statements (e.g. "@unstable interfaces are excluded").
CLAIM_RE='(wasi:(http|sockets|filesystem)|wasi 0\.3|preview3|wasip3)[^.]*(pending|not[[:space:]]+(yet[[:space:]]+)?(complete|implemented|supported)|unimplemented|is[[:space:]]+missing|are[[:space:]]+pending|data-plane[^.]*pending)'

fail=0

# --- 1. anchor -------------------------------------------------------------
if [[ ! -f "$ANCHOR_FILE" ]]; then
  echo "[check_wasi03_coverage] FAIL — anchor file $ANCHOR_FILE not found"
  fail=1
elif ! grep -q 'wasip3-official: http-client' "$ANCHOR_FILE"; then
  echo "[check_wasi03_coverage] FAIL — $ANCHOR_FILE no longer enables the http-client conformance test."
  echo "  If the 0.3 corpus was pared back on purpose, update this script AND re-sweep"
  echo "  every doc that states 0.3 coverage (README §WASI, docs/migration_v1_to_v2.md,"
  echo "  .dev/ROADMAP.md)."
  fail=1
fi

# --- 2. sweep --------------------------------------------------------------
hits=()
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  [[ "$f" =~ $EXEMPT_RE ]] && continue
  while IFS= read -r line; do
    hits+=("$f: $line")
  done < <(grep -niE "$CLAIM_RE" "$f" 2>/dev/null || true)
done < <(git ls-files -- '*.md' '*.yml' '*.yaml' 2>/dev/null)

if [[ ${#hits[@]} -gt 0 ]]; then
  echo "[check_wasi03_coverage] FAIL — ${#hits[@]} live claim(s) that a WASI 0.3 proposal is unimplemented:"
  for h in "${hits[@]}"; do echo "  - $h"; done
  echo ""
  echo "All six 0.3.0 proposals are served on all three supported OSes"
  echo "(the vendored official corpus is green; ADR-0205). State the coverage as complete, or"
  echo "cite a specific tracked debt row."
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "[check_wasi03_coverage] OK — anchor intact, no live 0.3-is-pending claims"
  exit 0
fi

if [[ "$mode" == "--gate" ]]; then exit 1; fi
exit 0
