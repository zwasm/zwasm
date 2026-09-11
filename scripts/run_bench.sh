#!/usr/bin/env bash
# scripts/run_bench.sh — interactive bench runner via hyperfine.
#
# Builds zwasm in ReleaseFast (fair vs the release-optimized comparators;
# --safe / BENCH_SAFE=1 forces ReleaseSafe) and runs each fixture in
# bench/runners/wasm/{shootout,tinygo,handwritten}/*.wasm + the
# 5 cljw_*.wasm guests from test/realworld/wasm/ (per §9.6 / 6.G).
# Writes results to bench/results/recent.yaml (records the build mode).
#
# Usage:
#   bash scripts/run_bench.sh                     # full (5 runs + 3 warmup)
#   bash scripts/run_bench.sh --quick             # quick (3 runs + 1 warmup)
#   bash scripts/run_bench.sh --bench=<name>      # single bench by name
#   bash scripts/run_bench.sh --windows-subset    # 5-fixture fast subset
#                                                 # (§9.8 / 8.3) — for use on
#                                                 # the Windows SSH host where
#                                                 # the full inventory takes
#                                                 # 5+ hours; ~250-400ms/fixture
#                                                 # × 5 × 3-runs ≈ 6s total.
#                                                 # Subset: shootout/nestedloop
#                                                 # + tinygo/{arith,fib,sieve,tak}
#                                                 # (all <30ms on Linux baseline;
#                                                 # ~12x slower on Win = under 1s).
#   bash scripts/run_bench.sh --phase-record \
#        --reason='<phase-tag>: <gist>'           # ALSO append to history.yaml
#   bash scripts/run_bench.sh --compare=wasmtime  # Run each fixture against
#                                                 # BOTH zwasm and wasmtime;
#                                                 # YAML entries gain a
#                                                 # `runtime:` field. Phase 11
#                                                 # bench prerequisite per
#                                                 # §9.12-H. Wazero/wasmer/bun
#                                                 # /node deferred to Phase 11.
#   bash scripts/run_bench.sh --capture-rss       # Capture max RSS via
#                                                 # /usr/bin/time -l (macOS) /
#                                                 # /usr/bin/time -v (Linux);
#                                                 # adds `max_rss_kb` to each
#                                                 # YAML entry. Requires
#                                                 # /usr/bin/time on PATH.
#   bash scripts/run_bench.sh --engines=interp,jit,aot
#                                                 # (ADR-0163 A) bench zwasm
#                                                 # across its engines — one
#                                                 # runtime row each (zwasm-interp
#                                                 # /zwasm-jit/zwasm-aot). aot
#                                                 # precompiles a temp .cwasm.
#                                                 # Combine with --compare=all for
#                                                 # the full all-engine + multi-
#                                                 # runtime matrix.
#
# Per ADR-0012 §7: recent.yaml gitignored, history.yaml committed
# at phase boundaries only.
#
# `--phase-record` writes one history.yaml entry tagged with the
# current commit + arch + the supplied --reason. Without
# --phase-record, recent.yaml is overwritten in place.
#
# CI (.github/workflows/bench.yml) invokes this script with
# `--quick --phase-record --reason="CI: ..."` on each push to
# main; the per-arch entry is then extracted via
# scripts/append_bench_to_history.sh and aggregated into one bot
# commit. Local users do not call append_bench_to_history.sh.

set -euo pipefail
cd "$(dirname "$0")/.."

QUICK=0
PHASE_RECORD=0
WINDOWS_SUBSET=0
BENCH=""
REASON=""
DIFF_REF=""
COMPARE=""
CAPTURE_RSS=0
SIMD=0
ENGINES_CSV=""
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
        --phase-record) PHASE_RECORD=1 ;;
        --windows-subset) WINDOWS_SUBSET=1; QUICK=1 ;;
        --simd) SIMD=1 ;;
        --bench=*) BENCH="${arg#--bench=}" ;;
        --reason=*) REASON="${arg#--reason=}" ;;
        --diff=*) DIFF_REF="${arg#--diff=}" ;;
        --diff)  ;;  # next iteration provides ref via positional pickup; see below
        --compare=*) COMPARE="${arg#--compare=}" ;;
        --capture-rss) CAPTURE_RSS=1 ;;
        --engines=*) ENGINES_CSV="${arg#--engines=}" ;;
        --safe) BENCH_SAFE=1 ;;
    esac
done

# §11.3 — `--simd` benches the SIMD per-op micro-bench corpus
# (bench/runners/wasm/simd/). zwasm must run these via the JIT
# (`--engine=jit`): the interpreter has no SIMD execution (ADR-0136 / D-244).
ZWASM_RUN_FLAGS=""
if [ "$SIMD" -eq 1 ]; then
    ZWASM_RUN_FLAGS=" --engine=jit"
fi

# ADR-0163 A — engine matrix. `--engines=interp,jit,aot` benches zwasm across
# its engines, emitting one runtime row each (zwasm-interp / zwasm-jit /
# zwasm-aot). aot precompiles a temp .cwasm per fixture (the timed command runs
# the artifact — cold-start compile is a separate metric, see aot_coldstart.md).
# Flag absent → a single `zwasm` row using ZWASM_RUN_FLAGS: no `--engine`, i.e.
# the CLI default `auto` (JIT-preferring, interp fallback) — or forced jit under
# --simd. Published tables always pass `--engines=`, so no row is ever labelled
# by an engine the default picked.
ZW_RUNTIMES=()
if [ -n "$ENGINES_CSV" ]; then
    IFS=',' read -ra _engs <<< "$ENGINES_CSV"
    for e in "${_engs[@]}"; do
        case "$e" in
            interp|jit|aot) ZW_RUNTIMES+=("zwasm-$e") ;;
            *) echo "[run_bench] --engines: '$e' not supported (interp|jit|aot)" >&2; exit 1 ;;
        esac
    done
else
    ZW_RUNTIMES=("zwasm")
fi
# §9.8a / 8a.3 — `--diff <ref>` (space-separated form). The
# `case` loop above only handles `--diff=<ref>`; pick up the
# space-separated form by walking $@ pairwise.
prev=""
for arg in "$@"; do
    if [ "$prev" = "--diff" ] && [ -z "$DIFF_REF" ]; then
        DIFF_REF="$arg"
    fi
    prev="$arg"
done

# §9.8 / 8.3 — Windows subset: 5 fast fixtures (all <30ms on Linux
# baseline). At Mac:Win ~12x ratio observed in Phase 7 close, this
# is ~250-400ms/fixture × 3 quick-runs ≈ 6s total. Use on the
# Windows SSH host where the full 26-fixture inventory takes
# 5+ hours and is incompatible with inline gate cadence.
WINDOWS_SUBSET_NAMES=(
    "shootout/nestedloop"
    "tinygo/arith"
    "tinygo/fib"
    "tinygo/sieve"
    "tinygo/tak"
)

if ! command -v hyperfine >/dev/null 2>&1; then
    echo "[run_bench] hyperfine not on PATH; aborting (the dev shell pins it via flake.nix)." >&2
    exit 1
fi

# §11.3 / ADR-0163-B — comparator runtime presence check. --compare accepts a
# single name, a comma-separated list, or `all` (= every comparator on PATH).
# The SIMD per-op gap analysis (§11.3) takes the median of wasmtime/wazero/
# wasmer; wasmedge (LLVM AOT) joined for the WASI-realworld matrix (ADR-0163).
# bun / node stay deferred (need a JS WASI wrapper). The `.#bench` dev shell
# pins the full set; `default` pins only the SIMD trio.
COMPARATORS=()
if [ -n "$COMPARE" ]; then
    case "$COMPARE" in
        all)
            # Only the comparators actually on PATH (wasmer is Mac-only — see
            # flake.nix; the bench host is Mac so all resolve via `.#bench`).
            COMPARATORS=()
            for c in wasmtime wazero wasmer wasmedge; do
                command -v "$c" >/dev/null 2>&1 && COMPARATORS+=("$c")
            done
            ;;
        *)   IFS=',' read -ra COMPARATORS <<< "$COMPARE" ;;
    esac
    for c in "${COMPARATORS[@]}"; do
        case "$c" in
            wasmtime|wazero|wasmer|wasmedge)
                command -v "$c" >/dev/null 2>&1 || {
                    echo "[run_bench] --compare=$c: $c not on PATH (the .#bench dev shell pins it via flake.nix)" >&2
                    exit 1
                }
                ;;
            *)
                echo "[run_bench] --compare: '$c' not supported (wasmtime|wazero|wasmer|wasmedge|all; bun/node deferred)" >&2
                exit 1
                ;;
        esac
    done
fi

# §9.12-H — RSS capture relies on /usr/bin/time -l (macOS BSD) /
# /usr/bin/time -v (Linux GNU). Probe both forms; record the
# canonical command in TIME_CMD or disable on missing tool.
TIME_CMD=""
if [ "$CAPTURE_RSS" -eq 1 ]; then
    if [ -x /usr/bin/time ]; then
        case "$(uname -s)" in
            Darwin) TIME_CMD="/usr/bin/time -l" ;;
            Linux)  TIME_CMD="/usr/bin/time -v" ;;
            *)
                echo "[run_bench] --capture-rss: no /usr/bin/time variant for $(uname -s); RSS will be null" >&2
                CAPTURE_RSS=0
                ;;
        esac
    else
        echo "[run_bench] --capture-rss: /usr/bin/time not present; RSS will be null" >&2
        CAPTURE_RSS=0
    fi
fi

# Build ReleaseFast by default: the comparator runtimes (wasmtime/wazero/wasmer/
# wasmedge) are all release-optimized, so ReleaseSafe here would be an unfair
# handicap (safety checks slow zwasm's interp loop + JIT-compile/startup). This
# matches the s15p_parity_vs_v1 basis. `--safe` opts back into ReleaseSafe for a
# safety-on measurement (records build: ReleaseSafe in the YAML).
ZWASM_BUILD_MODE="${BENCH_SAFE:+ReleaseSafe}"
ZWASM_BUILD_MODE="${ZWASM_BUILD_MODE:-ReleaseFast}"
echo "[run_bench] building $ZWASM_BUILD_MODE..."
zig build -Doptimize="$ZWASM_BUILD_MODE" >&2

ZWASM=./zig-out/bin/zwasm
if [ ! -x "$ZWASM" ]; then
    echo "[run_bench] $ZWASM not present after build" >&2
    exit 1
fi

# Bench inventory: layer/name → wasm path. Layer is the
# directory hierarchy (per ADR-0012 §4 file-naming-by-hierarchy).
BENCHES=(
    # Sightglass shootout (pre-built without bench::start/end harness)
    "shootout/fib2:bench/runners/wasm/shootout/fib2.wasm"
    "shootout/sieve:bench/runners/wasm/shootout/sieve.wasm"
    "shootout/nestedloop:bench/runners/wasm/shootout/nestedloop.wasm"
    "shootout/matrix:bench/runners/wasm/shootout/matrix.wasm"
    "shootout/heapsort:bench/runners/wasm/shootout/heapsort.wasm"
    "shootout/base64:bench/runners/wasm/shootout/base64.wasm"
    "shootout/gimli:bench/runners/wasm/shootout/gimli.wasm"
    "shootout/memmove:bench/runners/wasm/shootout/memmove.wasm"
    "shootout/keccak:bench/runners/wasm/shootout/keccak.wasm"
    # ADR-0163 A breadth (vendored bench/shootout-src/, built by its build.sh):
    # crypto / parsing / PRNG / dispatch categories absent in the original 9.
    "shootout/ctype:bench/runners/wasm/shootout/ctype.wasm"
    "shootout/random:bench/runners/wasm/shootout/random.wasm"
    "shootout/ratelimit:bench/runners/wasm/shootout/ratelimit.wasm"
    "shootout/minicsv:bench/runners/wasm/shootout/minicsv.wasm"
    "shootout/xblabla20:bench/runners/wasm/shootout/xblabla20.wasm"
    "shootout/xchacha20:bench/runners/wasm/shootout/xchacha20.wasm"
    # NOT in the matrix — each surfaced a real zwasm limit (sources + .wasm still
    # vendored as repro fixtures): switch → D-287 (control-stack cap 1024),
    # ackermann → D-288 (call-stack too small for 1021-deep recursion),
    # ed25519 → D-289 (JIT local.set emit fails in large func), seqhash → too
    # slow under interp for the all-engine matrix (works under jit).
    # TinyGo WASI guests
    "tinygo/arith:bench/runners/wasm/tinygo/arith.wasm"
    "tinygo/fib:bench/runners/wasm/tinygo/fib.wasm"
    "tinygo/fib_loop:bench/runners/wasm/tinygo/fib_loop.wasm"
    "tinygo/gcd:bench/runners/wasm/tinygo/gcd.wasm"
    "tinygo/list_build:bench/runners/wasm/tinygo/list_build.wasm"
    "tinygo/mfr:bench/runners/wasm/tinygo/mfr.wasm"
    "tinygo/nqueens:bench/runners/wasm/tinygo/nqueens.wasm"
    "tinygo/real_work:bench/runners/wasm/tinygo/real_work.wasm"
    "tinygo/sieve:bench/runners/wasm/tinygo/sieve.wasm"
    "tinygo/string_ops:bench/runners/wasm/tinygo/string_ops.wasm"
    "tinygo/tak:bench/runners/wasm/tinygo/tak.wasm"
    # Hand-written: none. `handwritten/nbody` exports `init` / `run` /
    # `advance` and no `_start` / `main`; the row that ran it without
    # `--invoke` measured `init` (setup) through the first-func-export
    # fallback #220 removed. It needs `--invoke run=N` on every runtime
    # (bench/runners/wasm/PROVENANCE.txt).
    # ClojureWasm v1 (vendored at §9.6 / 6.G into test/realworld/wasm/)
    "cljw/fib:test/realworld/wasm/cljw_fib.wasm"
    "cljw/gcd:test/realworld/wasm/cljw_gcd.wasm"
    "cljw/arith:test/realworld/wasm/cljw_arith.wasm"
    "cljw/sieve:test/realworld/wasm/cljw_sieve.wasm"
    "cljw/tak:test/realworld/wasm/cljw_tak.wasm"
)

# §11.3 — under `--simd`, replace the inventory with the SIMD per-op
# micro-bench corpus (enumerated from disk, generated by
# bench/runners/wasm/simd/gen_simd_corpus.sh).
if [ "$SIMD" -eq 1 ]; then
    BENCHES=()
    for w in bench/runners/wasm/simd/*.wasm; do
        [ -f "$w" ] || continue
        BENCHES+=("simd/$(basename "$w" .wasm):$w")
    done
    if [ "${#BENCHES[@]}" -eq 0 ]; then
        echo "[run_bench] --simd: no fixtures in bench/runners/wasm/simd/ (run gen_simd_corpus.sh)" >&2
        exit 1
    fi
fi

mkdir -p bench/results
RECENT=bench/results/recent.yaml

if [ $QUICK -eq 1 ]; then
    RUNS=3; WARMUP=1
else
    RUNS=5; WARMUP=3
fi

case "$(uname -s -m)" in
    "Darwin arm64")    arch="aarch64-darwin" ;;
    "Linux x86_64")    arch="x86_64-linux" ;;
    "MINGW"*|"MSYS"*)  arch="x86_64-windows" ;;
    *)                 arch="$(uname -s -m | tr ' ' -)" ;;
esac

commit=$(git rev-parse HEAD)
date=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# header
{
    echo "# bench/results/recent.yaml"
    echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/run_bench.sh"
    echo "# Schema in bench/README.md."
    echo "- date: $date"
    echo "  commit: $commit"
    echo "  arch: $arch"
    echo "  build: $ZWASM_BUILD_MODE"
    echo "  reason: \"local recent run (runs=$RUNS warmup=$WARMUP build=$ZWASM_BUILD_MODE)\""
    echo "  runs: $RUNS"
    echo "  warmup: $WARMUP"
    echo "  benches:"
} > "$RECENT"

# §11.3 / ADR-0163 A — runtime matrix. zwasm engine row(s) first (one per
# --engines entry, else a single `zwasm`); the --compare comparators (wasmtime /
# wazero / wasmer / wasmedge) follow. YAML entries gain a `runtime:` field iff
# the matrix has > 1 entry, so historical single-runtime entries stay shape-compatible.
RUNTIMES=("${ZW_RUNTIMES[@]}")
if [ ${#COMPARATORS[@]} -gt 0 ]; then
    RUNTIMES+=("${COMPARATORS[@]}")
fi

# Capture max RSS (kB) from /usr/bin/time stderr after a single
# invocation. macOS reports bytes; Linux reports kB. Echo "null"
# on parse failure to keep YAML well-formed.
measure_rss_kb() {
    local rt="$1"
    local wasm="$2"
    local rss_out
    rss_out=$(mktemp)
    local aot_cwasm="$3"   # set only for rt=zwasm-aot (precompiled artifact)
    case "$rt" in
        zwasm)        $TIME_CMD "$ZWASM" run $ZWASM_RUN_FLAGS "$wasm" 2>"$rss_out" >/dev/null || true ;;
        zwasm-interp) $TIME_CMD "$ZWASM" run --engine interp "$wasm" 2>"$rss_out" >/dev/null || true ;;
        zwasm-jit)    $TIME_CMD "$ZWASM" run --engine jit "$wasm" 2>"$rss_out" >/dev/null || true ;;
        zwasm-aot)    $TIME_CMD "$ZWASM" run "$aot_cwasm" 2>"$rss_out" >/dev/null || true ;;
        wasmtime) $TIME_CMD wasmtime run "$wasm" 2>"$rss_out" >/dev/null || true ;;
        wazero)   $TIME_CMD wazero run "$wasm" 2>"$rss_out" >/dev/null || true ;;
        wasmer)   $TIME_CMD wasmer run "$wasm" 2>"$rss_out" >/dev/null || true ;;
        wasmedge) $TIME_CMD wasmedge "$wasm" 2>"$rss_out" >/dev/null || true ;;
    esac
    case "$(uname -s)" in
        Darwin)
            # `... maximum resident set size` (bytes on macOS BSD time)
            local bytes
            bytes=$(awk '/maximum resident set size/ {print $1; exit}' "$rss_out" 2>/dev/null)
            rm -f "$rss_out"
            if [ -z "$bytes" ] || ! [ "$bytes" -eq "$bytes" ] 2>/dev/null; then
                echo null
            else
                echo $((bytes / 1024))
            fi
            ;;
        Linux)
            # `Maximum resident set size (kbytes): N` (GNU time -v)
            local kb
            kb=$(awk '/Maximum resident set size/ {print $NF; exit}' "$rss_out" 2>/dev/null)
            rm -f "$rss_out"
            if [ -z "$kb" ] || ! [ "$kb" -eq "$kb" ] 2>/dev/null; then
                echo null
            else
                echo "$kb"
            fi
            ;;
        *)
            rm -f "$rss_out"
            echo null
            ;;
    esac
}

ran_any=0
for entry in "${BENCHES[@]}"; do
    name="${entry%%:*}"
    if [ "$WINDOWS_SUBSET" -eq 1 ]; then
        in_subset=0
        for sub in "${WINDOWS_SUBSET_NAMES[@]}"; do
            if [ "$sub" = "$name" ]; then in_subset=1; break; fi
        done
        if [ "$in_subset" -eq 0 ]; then continue; fi
    fi
    wasm="${entry#*:}"
    if [ -n "$BENCH" ] && [ "$name" != "$BENCH" ]; then
        continue
    fi
    if [ ! -f "$wasm" ]; then
        echo "[run_bench] missing $wasm — skipping $name" >&2
        continue
    fi
    for runtime in "${RUNTIMES[@]}"; do
        # zwasm-aot precompiles the fixture to a temp .cwasm (the timed command
        # runs the artifact; AOT compile latency is a separate cold-start metric).
        cwasm_tmp=""
        if [ "$runtime" = "zwasm-aot" ]; then
            cwasm_tmp="$(mktemp).cwasm"
            if ! "$ZWASM" compile "$wasm" -o "$cwasm_tmp" 2>/dev/null; then
                echo "    (aot compile failed; emitting null row)" >&2
                rm -f "$cwasm_tmp"
                cat <<EOF >> "$RECENT"
    - name: $name
      runtime: $runtime
      mean_ms: null
      stddev_ms: null
      min_ms: null
      max_ms: null
EOF
                continue
            fi
        fi
        case "$runtime" in
            zwasm)        cmd="$ZWASM run$ZWASM_RUN_FLAGS $wasm" ;;
            zwasm-interp) cmd="$ZWASM run --engine interp $wasm" ;;
            zwasm-jit)    cmd="$ZWASM run --engine jit $wasm" ;;
            zwasm-aot)    cmd="$ZWASM run $cwasm_tmp" ;;
            wasmtime) cmd="wasmtime run $wasm" ;;
            wazero)   cmd="wazero run $wasm" ;;
            wasmer)   cmd="wasmer run $wasm" ;;
            wasmedge) cmd="wasmedge $wasm" ;;   # no `run` subcommand; runs WASI _start
        esac
        echo "[run_bench] $name ($wasm) — runtime=$runtime"
        json=$(mktemp)
        err=$(mktemp)
        # §9.9 / 9.9-j-2 (per ADR-0056): capture stderr to $err for
        # diagnostic surfacing on failure — was `>/dev/null 2>&1` which
        # silently swallowed hyperfine + zwasm error messages, making
        # bench-script failures opaque.
        if ! hyperfine --warmup "$WARMUP" --runs "$RUNS" \
                --shell=none \
                --export-json "$json" \
                "$cmd" >/dev/null 2>"$err"; then
            echo "    (failed; first stderr lines:)" >&2
            head -5 "$err" | sed 's/^/      /' >&2
            rm -f "$json" "$err" "$cwasm_tmp"
            cat <<EOF >> "$RECENT"
    - name: $name
      runtime: $runtime
      mean_ms: null
      stddev_ms: null
      min_ms: null
      max_ms: null
EOF
            continue
        fi
        rm -f "$err"
        # §9.9 / 9.9-j-2 (per ADR-0056 + Agent Y finding #1): use python
        # to parse hyperfine's JSON. Prior `grep -oE '[0-9.]+'`
        # regex did not match scientific notation (e.g. `8.31753e-06`),
        # captured `8.31753`, then awk `* 1000 = 8317.53` — mathematically
        # impossible alongside its own `min_ms=2.12 / max_ms=2.13`.
        # Multiple `bench/results/history.yaml` entries were already
        # contaminated (commit c27f74da and prior); see annotation in
        # history.yaml flagging affected rows.
        metrics=$(python3 - "$json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
r = d["results"][0]
print(f"{r['mean']*1000:.2f} {r['stddev']*1000:.2f} {r['min']*1000:.2f} {r['max']*1000:.2f}")
PY
)
        read -r mean stddev min max <<<"$metrics"
        rm -f "$json"
        rss_line=""
        if [ "$CAPTURE_RSS" -eq 1 ]; then
            rss_kb=$(measure_rss_kb "$runtime" "$wasm" "$cwasm_tmp")
            rss_line="
      max_rss_kb: $rss_kb"
        fi
        cat <<EOF >> "$RECENT"
    - name: $name
      runtime: $runtime
      mean_ms: $mean
      stddev_ms: $stddev
      min_ms: $min
      max_ms: $max$rss_line
EOF
        rm -f "$cwasm_tmp"
        ran_any=1
    done
done

if [ $ran_any -eq 0 ]; then
    echo "[run_bench] no benchmarks ran (BENCH=$BENCH not in inventory)" >&2
    exit 2
fi

echo "[run_bench] wrote $RECENT"

if [ $PHASE_RECORD -eq 1 ]; then
    HIST=bench/results/history.yaml
    if [ -z "$REASON" ]; then
        REASON="phase boundary (auto): $(git log -1 --format='%s')"
    fi
    {
        echo ""
        echo "- date: $date"
        echo "  commit: $commit"
        echo "  arch: $arch"
        echo "  build: $ZWASM_BUILD_MODE"
        echo "  reason: \"$REASON\""
        echo "  runs: $RUNS"
        echo "  warmup: $WARMUP"
        echo "  benches:"
        # copy benches from recent.yaml (everything indented 4 spaces)
        awk '/^  benches:/,EOF' "$RECENT" | tail -n +2
    } >> "$HIST"
    echo "[run_bench] appended phase-record entry to $HIST"
fi

# §9.8a / 8a.3 — `--diff <ref>` mode: produce a markdown delta
# table comparing recent.yaml against the history.yaml entry at
# `<ref>`. Output goes to stdout (caller redirects). Per
# ADR-0032 + LOOP.md Step 5b.
if [ -n "$DIFF_REF" ]; then
    HIST=bench/results/history.yaml
    if [ ! -f "$HIST" ]; then
        echo "[run_bench] --diff requires $HIST; absent." >&2
        exit 2
    fi
    target_sha=$(git rev-parse --verify "$DIFF_REF^{commit}" 2>/dev/null || true)
    if [ -z "$target_sha" ]; then
        echo "[run_bench] --diff: cannot resolve ref '$DIFF_REF' to a commit" >&2
        exit 2
    fi
    # Extract the FIRST history.yaml entry whose `commit:` matches
    # the resolved SHA (or its prefix). yq's filter selects all
    # matching entries; we keep position 0.
    baseline_tmp=$(mktemp)
    trap 'rm -f "$baseline_tmp"' EXIT
    yq "[.[] | select(.commit | test(\"^${target_sha:0:12}\"))][0:1]" "$HIST" > "$baseline_tmp"
    if [ ! -s "$baseline_tmp" ] || [ "$(yq '. | length' "$baseline_tmp")" = "0" ]; then
        echo "[run_bench] --diff: no history.yaml entry matches commit prefix ${target_sha:0:12}" >&2
        exit 2
    fi
    bash scripts/record_bench_delta.sh "$baseline_tmp" "$RECENT" "vs $DIFF_REF (${target_sha:0:12})"
fi
