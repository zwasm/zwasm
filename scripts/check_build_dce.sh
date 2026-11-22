#!/usr/bin/env bash
# scripts/check_build_dce.sh — Build-option DCE enforcement gate.
#
# Builds zwasm across the 9 build-option combinations
# (`-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2,p3}`) and verifies via
# `nm` symbol grep that:
#
#   1. Each build succeeds and yields a binary `nm` can list.
#   2. No build lists a symbol matching a pattern forbidden at its level
#      (the FORBIDDEN_* lists below): the Wasm 2.0 and 3.0 op modules in a
#      `-Dwasm=v1_0` build, the 3.0 ones in `v2_0`; the Preview 2 HTTP host
#      at `-Dwasi=p1`; the async driver and `zwasm serve` below `p3`.
#   3. Every pattern names a symbol in the `v3_0:p3` build, where nothing is
#      forbidden. One that does not could never fail (#672).
#
# Binary `.text` size is printed per build, not asserted.
#
# Phase 9 completion master plan §7.1 / ADR-0073.
#
# Modes:
#   --gate            : exit non-zero on any FAIL (pre-push hook; expensive)
#   --sample <N>      : build N random combinations (cheaper smoke)
#   --target <combo>  : build a single combination, e.g. "v1_0:p1"
#   --report          : exit 0; emit the matrix table

set -uo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,24p' "$0"
  exit 0
fi

MODE="${1:-report}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WASM_LEVELS=(v1_0 v2_0 v3_0)
WASI_LEVELS=(p1 p2 p3)

# Forbidden-symbol patterns per build axis. Each is a fixed string
# (`grep -F`) looked up in the build's `nm` listing; if found the build is in
# violation.
FORBIDDEN_V1_0=("wasm_2_0" "wasm_3_0")
FORBIDDEN_V2_0=("wasm_3_0")
FORBIDDEN_P1=("wasi_p2_")
# ADR-0193 P3: any build below `.p3` must NOT contain the async driver
# (`api/component_wasi_p3.zig`) or `zwasm serve`, both comptime-fenced on
# enable_wasi_p3. The trailing `.` keeps `component_wasi_p3_host` and `_http`
# out of the first pattern: a p2 build carries those today.
FORBIDDEN_BELOW_P3=("component_wasi_p3." "cli.serve.")

# The one build that forbids nothing and compiles every level in: the
# positive control for the patterns above.
LIVE_BUILD="v3_0:p3"

OUT_BASE="/tmp/zwasm-dce-check"
mkdir -p "$OUT_BASE"

build_one() {
  local wasm="$1" wasi="$2"
  local prefix="$OUT_BASE/${wasm}_${wasi}"
  rm -rf "$prefix"
  mkdir -p "$prefix"
  zig build \
    "-Dwasm=$wasm" "-Dwasi=$wasi" \
    "-Doptimize=ReleaseSafe" \
    "-p" "$prefix" \
    > "$prefix/build.log" 2>&1
}

# D-231: the host-native build on an arm64 Mac exercises only the arm64
# codegen's DCE; x86_64 codegen DCE drift (e.g. a legacy-switch arm calling
# `wasm_3_0` op.emit() without a `comptime wasm_v3_plus` guard, the live leak
# fixed @96fcdf9f) is INVISIBLE to it. Cross-compile to x86_64-linux so the
# x86 codegen is compiled + its dead symbols are observable to nm. nix `nm`
# (llvm-nm via the clang wrapper) reads cross ELF fine.
#
# On an x86_64 host the native build already compiles the x86_64 codegen, so
# the same-triple cross build adds zero coverage — skip it (halves the matrix
# wall-clock on the x86_64-linux CI leg; each ReleaseSafe build is minutes).
XBUILD_TARGET="x86_64-linux-gnu"
HOST_ARCH="$(uname -m)"
build_one_x86() {
  local wasm="$1" wasi="$2"
  local prefix="$OUT_BASE/x86_${wasm}_${wasi}"
  rm -rf "$prefix"
  mkdir -p "$prefix"
  zig build \
    "-Dtarget=$XBUILD_TARGET" \
    "-Dwasm=$wasm" "-Dwasi=$wasi" \
    "-Doptimize=ReleaseSafe" \
    "-p" "$prefix" \
    > "$prefix/build.log" 2>&1
}

forbidden_set_for() {
  local wasm="$1" wasi="$2"
  local out=""
  case "$wasm" in
    v1_0) out="${FORBIDDEN_V1_0[*]}" ;;
    v2_0) out="${FORBIDDEN_V2_0[*]}" ;;
  esac
  if [ "$wasi" = "p1" ]; then
    out="$out ${FORBIDDEN_P1[*]}"
  fi
  if [ "$wasi" != "p3" ]; then
    out="$out ${FORBIDDEN_BELOW_P3[*]}"
  fi
  echo "$out"
}

# Writes `nm`'s listing of $1 to $1.syms; non-zero when `nm` fails or the
# listing is empty. A listing `nm` did not finish may lack the very symbol
# the check forbids. The patterns are matched against the file, never
# against a pipe from `nm`: `grep -q` exits at its first match, `nm` then
# dies of SIGPIPE, and under `pipefail` the pipeline's 141 reads as "no
# match" — a present symbol reported as absent.
list_symbols() {
  nm "$1" > "$1.syms" 2>/dev/null && [ -s "$1.syms" ]
}

# Verdict column for one built binary; non-zero when it fails.
check_binary() {
  local bin="$1" wasm="$2" wasi="$3"
  local fail=0 pat
  if ! list_symbols "$bin"; then
    echo "    FAIL  $bin → nm failed or listed no symbols"
    return 1
  fi
  for pat in $(forbidden_set_for "$wasm" "$wasi"); do
    if grep -qF "$pat" "$bin.syms"; then
      echo "    FAIL  $bin → $pat present"
      fail=1
    fi
  done
  if [ "$wasm:$wasi" = "$LIVE_BUILD" ]; then
    for pat in "${FORBIDDEN_V1_0[@]}" "${FORBIDDEN_V2_0[@]}" "${FORBIDDEN_P1[@]}" "${FORBIDDEN_BELOW_P3[@]}"; do
      if ! grep -qF "$pat" "$bin.syms"; then
        echo "    FAIL  $bin → $pat names no symbol here, so it cannot fail a lower build"
        fail=1
      fi
    done
  fi
  return $fail
}

# --- assemble matrix ----------------------------------------------------

MATRIX=()
case "$MODE" in
  --sample)
    n="${2:-2}"
    for i in $(seq 1 "$n"); do
      MATRIX+=("${WASM_LEVELS[$((RANDOM % 3))]}:${WASI_LEVELS[$((RANDOM % 3))]}")
    done
    ;;
  --target)
    MATRIX+=("${2:-v1_0:p1}")
    ;;
  *)
    for w in "${WASM_LEVELS[@]}"; do
      for wi in "${WASI_LEVELS[@]}"; do
        MATRIX+=("$w:$wi")
      done
    done
    ;;
esac

fail=0
echo "=== build-option DCE check (per ADR-0073) ==="
echo "matrix size: ${#MATRIX[@]}"
echo ""
printf '%-6s %-4s %-10s %-12s %-12s\n' wasm wasi build text_bytes forbidden
echo "----------------------------------------------------"

for entry in "${MATRIX[@]}"; do
  wasm="${entry%%:*}"; wasi="${entry##*:}"
  if ! build_one "$wasm" "$wasi"; then
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "FAIL" "-" "-"
    tail -10 "$OUT_BASE/${wasm}_${wasi}/build.log" 2>/dev/null | sed 's/^/    /'
    fail=1
    continue
  fi
  # Prefer the `zwasm` CLI binary (the WASI-component path lives there);
  # `head -1` could grab an unrelated test-runner exe and false-pass the
  # P3-symbol DCE assertion (ADR-0193 P3).
  bin="$OUT_BASE/${wasm}_${wasi}/bin/zwasm"
  [ -f "$bin" ] || bin=$(find "$OUT_BASE/${wasm}_${wasi}/bin" -type f 2>/dev/null | head -1)
  if [ -z "$bin" ]; then
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "OK" "no-bin" "FAIL"
    fail=1
    continue
  fi
  text=$(size "$bin" 2>/dev/null | awk 'NR==2 {print $1}')
  if check_binary "$bin" "$wasm" "$wasi"; then
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "OK" "$text" "clean"
  else
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "OK" "$text" "FAIL"
    fail=1
  fi

  # D-231: cross-x86 DCE check (forbidden-symbol nm-grep only; no size —
  # host `size` may not read cross ELF, but nm does). Skipped on x86_64 hosts
  # where it would duplicate the native build above.
  if [ "$HOST_ARCH" = "x86_64" ]; then
    continue
  fi
  if ! build_one_x86 "$wasm" "$wasi"; then
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "x86:FAIL" "build" "-"
    tail -10 "$OUT_BASE/x86_${wasm}_${wasi}/build.log" 2>/dev/null | sed 's/^/    /'
    fail=1
    continue
  fi
  xbin="$OUT_BASE/x86_${wasm}_${wasi}/bin/zwasm"
  [ -f "$xbin" ] || xbin=$(find "$OUT_BASE/x86_${wasm}_${wasi}/bin" -type f 2>/dev/null | head -1)
  if [ -z "$xbin" ]; then
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "x86:OK" "no-bin" "FAIL"
    fail=1
  elif check_binary "$xbin" "$wasm" "$wasi"; then
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "x86:OK" "-" "clean"
  else
    printf '%-6s %-4s %-10s %-12s %-12s\n' "$wasm" "$wasi" "x86:OK" "-" "FAIL"
    fail=1
  fi
done

echo ""
case " ${MATRIX[*]} " in
  *" $LIVE_BUILD "*) ;;
  *) echo "note: $LIVE_BUILD is not in this matrix, so no pattern was shown able to match" ;;
esac
if [ "$MODE" = "--gate" ] && [ "$fail" -ne 0 ]; then
  echo "[check_build_dce] FAIL — DCE violations present (see above)"
  exit 1
fi

echo "[check_build_dce] OK"
exit 0
