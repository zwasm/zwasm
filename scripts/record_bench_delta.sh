#!/usr/bin/env bash
# scripts/record_bench_delta.sh — §9.8a / 8a.3 (per ADR-0032).
#
# Compares two bench-result YAML files (the schema in
# bench/results/history.yaml + recent.yaml) and emits a markdown
# table suitable for commit-message inclusion. Used by
# `run_bench.sh --diff <ref>` and the autonomous `/continue`
# loop's Step 5b bench-discipline trigger (8b tasks).
#
# Usage:
#   bash scripts/record_bench_delta.sh <before.yaml> <after.yaml> [<context-label>]
#
# Args:
#   <before.yaml>   YAML file containing the baseline entry. May
#                   be a multi-entry history.yaml (the FIRST entry
#                   is used) OR a single-entry recent.yaml.
#   <after.yaml>    YAML file containing the post-change entry.
#                   Same conventions as <before.yaml>.
#   <context-label> Optional. One-line label printed in the
#                   markdown header (e.g. "vs HEAD~1" or
#                   "Phase 7 close").
#
# Output (stdout): markdown block with `## Bench delta` heading
# + per-fixture table. Both positive and negative movements
# surface; regressions (>+5% or absolute > +1ms whichever
# higher) get a `⚠` flag.
#
# Schema notes:
#   - `median_ms` preferred (newer entries); falls back to
#     `mean_ms` (legacy entries before §9.6 / 6.E).
#   - Fixtures present only in one side surface with `—` in the
#     missing column + `new`/`removed` flag.
#   - Rows pair by (name, runtime): `--engines=jit,aot` writes two
#     rows per name. An entry without the field ran the default
#     engine and pairs as `zwasm`, which is how run_bench.sh records
#     that engine now. When the two files hold more than one runtime
#     between them, the Fixture cell reads `name (runtime)`.
#   - A `null` time (a failed run) flags `⚠ failed` / `recovered` /
#     `failed` with no delta, also on a row only one side has.
#
# Zone-equivalent: scripts (host-only). yq-go (in flake.nix) is
# the YAML parser; bc is the float arithmetic.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: record_bench_delta.sh <before.yaml> <after.yaml> [<context-label>]" >&2
    exit 2
fi

before_yaml="$1"
after_yaml="$2"
context_label="${3:-}"

if [ ! -f "$before_yaml" ]; then
    echo "error: <before.yaml> not found: $before_yaml" >&2
    exit 2
fi
if [ ! -f "$after_yaml" ]; then
    echo "error: <after.yaml> not found: $after_yaml" >&2
    exit 2
fi

# Pick the median_ms (or mean_ms fallback) for each fixture in
# the FIRST entry of the YAML. Outputs lines `name<TAB>runtime<TAB>ms`.
extract_benches() {
    local f="$1"
    yq -r '
        .[0].benches[] |
        [.name, (.runtime // "zwasm"), (.median_ms // .mean_ms)] | @tsv
    ' "$f"
}

# Pluck the entry's commit + arch for the header.
extract_meta() {
    local f="$1"
    local field="$2"
    yq -r ".[0].${field} // \"<unknown>\"" "$f"
}

before_commit=$(extract_meta "$before_yaml" commit)
after_commit=$(extract_meta "$after_yaml" commit)
before_arch=$(extract_meta "$before_yaml" arch)
after_arch=$(extract_meta "$after_yaml" arch)

# Header.
printf '## Bench delta'
if [ -n "$context_label" ]; then
    printf ' %s' "$context_label"
fi
if [ "$before_arch" = "$after_arch" ]; then
    printf ' (%s)' "$before_arch"
else
    printf ' (before: %s, after: %s — arch mismatch ⚠)' "$before_arch" "$after_arch"
fi
printf '\n\n'

printf -- '- before: `%s`\n' "${before_commit:0:12}"
printf -- '- after:  `%s`\n\n' "${after_commit:0:12}"

printf '| Fixture | Before (ms) | After (ms) | Δ (ms) | Δ%% | Flag |\n'
printf '|---|---:|---:|---:|---:|:---|\n'

# Build assoc-array equivalent via tmpfiles (bash 3 on macOS lacks
# associative arrays in portable form across all flake.nix shell
# variants). Each tmpfile maps (name, runtime) → ms.
tmp_before=$(mktemp)
tmp_after=$(mktemp)
trap 'rm -f "$tmp_before" "$tmp_after"' EXIT

extract_benches "$before_yaml" > "$tmp_before"
extract_benches "$after_yaml" > "$tmp_after"

n_runtimes=$( { cut -f2 "$tmp_after"; cut -f2 "$tmp_before"; } | sort -u | wc -l | tr -d ' ')

# Walk the union of (name, runtime) keys in stable (after-then-before-only) order.
all_keys=$( { cut -f1,2 "$tmp_after"; cut -f1,2 "$tmp_before"; } | awk '!seen[$0]++')

while IFS=$'\t' read -r name rt; do
    [ -z "$name" ] && continue
    before_ms=$(awk -F'\t' -v n="$name" -v r="$rt" '$1 == n && $2 == r { print $3; exit }' "$tmp_before")
    after_ms=$(awk -F'\t' -v n="$name" -v r="$rt" '$1 == n && $2 == r { print $3; exit }' "$tmp_after")
    label="$name"
    if [ "$n_runtimes" -gt 1 ]; then
        label="$name ($rt)"
    fi

    # run_bench.sh writes `null` when hyperfine or `zwasm compile` failed;
    # read as a number, a null after-time is a −100 % "improvement". Checked
    # before new/removed so a failed run on a one-sided row still flags.
    if [ "$before_ms" = null ] || [ "$after_ms" = null ]; then
        flag="failed"
        if [ "$after_ms" = null ] && [ "$before_ms" != null ]; then flag="⚠ failed"; fi
        if [ "$before_ms" = null ] && [ -n "$after_ms" ] && [ "$after_ms" != null ]; then flag="recovered"; fi
        printf '| %s | %s | %s | — | — | %s |\n' "$label" "${before_ms:-—}" "${after_ms:-—}" "$flag"
        continue
    fi

    if [ -z "$before_ms" ] && [ -n "$after_ms" ]; then
        printf '| %s | — | %s | — | — | new |\n' "$label" "$after_ms"
        continue
    fi
    if [ -n "$before_ms" ] && [ -z "$after_ms" ]; then
        printf '| %s | %s | — | — | — | removed |\n' "$label" "$before_ms"
        continue
    fi

    # Both present: compute delta + percentage. bc -l for floats.
    delta=$(printf '%s %s' "$after_ms" "$before_ms" | awk '{printf "%.2f", $1 - $2}')
    pct=$(printf '%s %s' "$after_ms" "$before_ms" | awk '{ if ($2 == 0) printf "—"; else printf "%+.1f", ($1 - $2) / $2 * 100 }')

    # Regression flag: |Δ%| > 5 AND |Δ ms| > 1, with sign honoured (positive Δ = slower).
    flag=""
    flag=$(awk -v d="$delta" -v p="$pct" 'BEGIN {
        if (p == "—") { print "—"; exit }
        d_abs = (d < 0) ? -d : d
        p_num = p + 0
        p_abs = (p_num < 0) ? -p_num : p_num
        if (p_num > 5 && d_abs > 1) print "⚠ regression"
        else if (p_num < -5 && d_abs > 1) print "✓ improved"
        else print ""
    }')

    printf '| %s | %s | %s | %s | %s%% | %s |\n' "$label" "$before_ms" "$after_ms" "$delta" "$pct" "$flag"
done <<< "$all_keys"
