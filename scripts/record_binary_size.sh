#!/usr/bin/env bash
# scripts/record_binary_size.sh — D-320 (ADR-0181): append the release
# binary-size series to bench/results/size_history.yaml so the
# "lightweight" axis of the 完成形 bar is OBSERVED, not assumed.
#
# Records two variants per invocation (append-only, per ROADMAP §A9):
#   base — `zig build -Doptimize=ReleaseFast` (the default -Dwasi=p3, ADR-0193)
#   lean — same + -Dwasi=p1 (CM/WASI-P2 subsystem stripped)
#
# Cadence: manual / phase-boundary (alongside run_bench.sh --phase-record);
# NOT a per-commit gate.
set -euo pipefail
cd "$(dirname "$0")/.."

out="bench/results/size_history.yaml"
sha="$(git rev-parse --short HEAD)"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

fsize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

measure() { # $1 = variant name, $2... = extra zig build args
    local variant="$1"; shift
    zig build -Doptimize=ReleaseFast "$@" >/dev/null
    local bytes
    bytes="$(fsize zig-out/bin/zwasm)"
    {
        echo ""
        echo "- commit: \"$sha\""
        echo "  timestamp: \"$ts\""
        echo "  variant: \"$variant\""
        echo "  optimize: \"ReleaseFast\""
        echo "  zwasm_bytes: $bytes"
    } >> "$out"
    echo "[record_binary_size] $variant: $bytes bytes"
}

if [ ! -f "$out" ]; then
    cat > "$out" <<'HDR'
# Release binary-size history — D-320 (ADR-0181). Append-only (§A9);
# one row per (commit, variant) via scripts/record_binary_size.sh.
# variant: "base" = ReleaseFast default (-Dwasi=p2 until 2.9.0, -Dwasi=p3 from 2.10.0);
# "lean" = -Dwasi=p1 (no Component Model / P2 host; ADR-0193 replaced -Dcomponent=false).
HDR
fi

measure base
measure lean -Dwasi=p1
