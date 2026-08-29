#!/usr/bin/env bash
# check_engine_default_claims.sh — keep prose in sync with the CLI's real
# default engine.
#
# The default has been `auto` (prefers the JIT, interpreter fallback) since the
# D-496 ch6 flip (ADR-0200). "interp is the default" nevertheless survived in
# `--help` until v2.4.1 and in four more places until #163 — an ungated claim
# rots, and this one rotted twice. Same class as the D-312 compiler-rt lie
# (lesson 2026-08-03-ungated-negative-doc-claim-rotted-into-a-lie.md).
#
# Three assertions:
#   1. ANCHOR — the CLI usage text still says the default is `auto`. If the
#      default legitimately changes, this fires first and forces the sweep
#      below to be redone rather than silently inverted.
#   2. SWEEP — no live tracked file claims the interpreter is the default, on
#      any single line.
#   3. SPAN SWEEP — the same claim spread across two comment lines. #309 was
#      missed because `include/zwasm.h` wrapped "interpreter-backed instances"
#      and "(the hardened default engine)" onto separate lines, and a
#      line-oriented grep cannot see a claim that straddles the wrap.
#
# Modes:
#   bash scripts/check_engine_default_claims.sh          # informational, exit 0
#   bash scripts/check_engine_default_claims.sh --gate   # exit 1 on any hit
#
# Historical records are exempt: they were true when written and are not
# instructions to a reader. Prose that a user could act on is not.

set -u

mode="${1:-info}"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root" || exit 2

ANCHOR_FILE="src/cli/dispatch.zig"

# Paths whose interp-is-default text is a dated record, not a live claim.
EXEMPT_RE='^(bench/|CHANGELOG\.md$|\.dev/archive/|\.dev/lessons/|\.dev/decisions/|\.dev/phase_log/|\.dev/meta_audits/|\.dev/debt\.yaml$|\.devils-advocate/|scripts/check_engine_default_claims\.sh$)'

# Phrasings that assert the interpreter is zwasm's default. Matched
# case-insensitively; `[`*]*` absorbs the markdown emphasis these names almost
# always carry. Kept literal and narrow — a loose pattern here produces false
# positives on true statements about comparator runtimes, which is how a gate
# gets disabled.
#
# The `currently|for now` and `auto (= interp` / `auto resolves to interp` arms
# were added for #309: both phrasings assert the interpreter is what you get
# today without ever writing "interpreter is the default".
CLAIM_RE='interp(reter)?[`*]*[[:space:]]*\((the )?default[,)]|interpreter by default|default[[:space:]]+engine[[:space:]]+is[[:space:]]+(the[[:space:]]+)?[`*]*interp|interp(reter)?/default engine|(currently|for now)[[:space:]]+(the[[:space:]]+)?[`*]*interp(reter)?\b|auto[`*.]*[[:space:]]*(\(=[[:space:]]*|resolves to[[:space:]]+)[`*]*(the[[:space:]]+)?interp(reter)?\b'

# Pass 3 operates on the file with comment leaders and newlines flattened to
# spaces, so a claim that wraps is one string. Necessarily broader than
# CLAIM_RE, so each match is re-tested against TRUE_MARKER_RE: a window that
# also names `auto` / the JIT / a fallback is describing the real default
# ("auto — prefers the JIT, interpreter fallback — is the default engine") and
# is not a claim that the interpreter is it. A match that the file wraps in
# quotation marks is likewise skipped: a quoted claim is being cited (as
# ci.yml cites the #163 one), not made.
SPAN_CLAIM_RE='interp(reter)?[a-z-]*[^.]{0,60}default engine'
TRUE_MARKER_RE='auto|jit|fallback|not the default|no longer the default'

fail=0

# --- 1. anchor -------------------------------------------------------------
if [[ ! -f "$ANCHOR_FILE" ]]; then
  echo "[check_engine_default] FAIL — anchor file $ANCHOR_FILE not found"
  fail=1
elif ! grep -q 'default auto' "$ANCHOR_FILE"; then
  echo "[check_engine_default] FAIL — $ANCHOR_FILE no longer documents 'default auto'."
  echo "  If the default engine changed on purpose, update this script AND re-sweep"
  echo "  every doc listed by it (README, docs/reference/cli.md, docs/benchmarks.md,"
  echo "  docs/zig_api_design.md, docs/reference/zig_api.md, docs/migration_v1_to_v2.md,"
  echo "  .dev/ROADMAP.md §10.2, .github/ISSUE_TEMPLATE/bug_report.yml)."
  fail=1
fi

# --- 2. sweep --------------------------------------------------------------
hits=()
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  [[ "$f" =~ $EXEMPT_RE ]] && continue
  while IFS= read -r line; do
    # A comparator's own default is a true statement about that comparator.
    printf '%s' "$line" | grep -qiE 'wasmedge|wasmer|wazero|wasmtime|zwasm v1|\bv1\b' && continue
    hits+=("$f: $line")
  done < <(grep -niE "$CLAIM_RE" "$f" 2>/dev/null || true)
done < <(git ls-files -- '*.md' '*.yml' '*.yaml' '*.zig' '*.sh' '*.h' '*.c' '*.rs' 2>/dev/null)

# --- 3. span sweep (claims that wrap across comment lines) -----------------
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  [[ "$f" =~ $EXEMPT_RE ]] && continue
  # Cheap pre-filter: the span pattern always ends in "default engine".
  grep -qiF 'default engine' "$f" || continue
  joined="$(sed -E 's#^[[:space:]]*(///|//|\*/|/\*|\*|\#)[[:space:]]*##' "$f" | tr '\n' ' ')"
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    printf '%s' "$m" | grep -qiE "$TRUE_MARKER_RE" && continue
    printf '%s' "$m" | grep -qiE 'wasmedge|wasmer|wazero|wasmtime|zwasm v1|\bv1\b' && continue
    printf '%s' "$joined" | grep -qF "\"$m\"" && continue
    hits+=("$f: (spans lines) $m")
  done < <(printf '%s' "$joined" | grep -oiE "$SPAN_CLAIM_RE" 2>/dev/null || true)
done < <(git ls-files -- '*.md' '*.yml' '*.yaml' '*.zig' '*.sh' '*.h' '*.c' '*.rs' 2>/dev/null)

if [[ ${#hits[@]} -gt 0 ]]; then
  echo "[check_engine_default] FAIL — ${#hits[@]} live claim(s) that the interpreter is the default:"
  for h in "${hits[@]}"; do echo "  - $h"; done
  echo ""
  echo "The default is 'auto' (prefers the JIT, interpreter fallback) — see"
  echo "$ANCHOR_FILE and .dev/ROADMAP.md §10.2. Say 'auto' explicitly, or name"
  echo "the forced engine (--engine interp / --engine jit)."
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "[check_engine_default] OK — anchor intact, no live interp-is-default claims"
  exit 0
fi

if [[ "$mode" == "--gate" ]]; then exit 1; fi
exit 0
