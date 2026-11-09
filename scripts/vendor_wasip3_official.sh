#!/usr/bin/env bash
# Vendor the official wasi-testsuite wasm32-wasip3 conformance binaries
# (ADR-0205 D3) into test/component/wasip3_official/.
#
# Source of truth: the `prod/testsuite-base` branch of
# https://github.com/WebAssembly/wasi-testsuite — the upstream-built binaries
# for the tests under tests/rust/wasm32-wasip3/ (Apache-2.0; see
# legal/THIRD_PARTY.md). Binaries are `wasm-tools strip`ped (drops the ~2.5 MB
# of debug custom sections per binary; behavior-identical) before committing.
# Manifests (.json) come from the same pinned commit's `main`-side sources.
#
# Deliberate-bump-only (ADR-0205 D6): edit PIN_SHA + re-run + commit.
set -euo pipefail

PIN_SHA="9d84631e427729802085c3d172d0a63cd360a1fa" # prod/testsuite-base 2026-10-30
CLONE="${WASI_TESTSUITE_CLONE:-$HOME/Documents/OSS/wasi-testsuite}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/test/component/wasip3_official"

# Staged enablement (ADR-0205 D4): extend per phase as host surfaces land.
TESTS=(
  # phase A — cli / clocks / random / run
  cli-env cli-exit cli-stdio cli-stdio-roundtrip cli-stdout-flush cli-terminal
  monotonic-clock multi-clock-wait random wall-clock run-with-err
  # phase B — filesystem (root preopen tree = fs-tests.dir below)
  filesystem-advise filesystem-dotdot filesystem-flags-and-type
  filesystem-hard-links filesystem-io filesystem-is-same-object
  filesystem-metadata-hash filesystem-mkdir-rmdir filesystem-open-errors
  filesystem-read-directory filesystem-rename filesystem-set-size
  filesystem-stat filesystem-unlink-errors
  # phase C — sockets (control plane + connected data plane; D-568)
  sockets-tcp-properties sockets-udp-properties sockets-udp-bind
  sockets-tcp-bind sockets-tcp-connect sockets-tcp-listen
  sockets-tcp-receive sockets-tcp-send sockets-echo
  sockets-udp-connect sockets-udp-receive sockets-udp-send
  # phase D — http (types resources first; service/client legs follow)
  http-fields http-request-options http-request http-response
  http-service http-service-echo http-service-uri http-client
)

command -v wasm-tools >/dev/null || { echo "wasm-tools required" >&2; exit 1; }
git -C "$CLONE" rev-parse --quiet --verify "$PIN_SHA^{commit}" >/dev/null || {
  echo "pin $PIN_SHA not present in $CLONE — fetch prod/testsuite-base first:" >&2
  echo "  git -C $CLONE fetch origin prod/testsuite-base" >&2
  exit 1
}

mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for t in "${TESTS[@]}"; do
  git -C "$CLONE" show "$PIN_SHA:tests/rust/testsuite/wasm32-wasip3/$t.wasm" > "$tmp/$t.wasm"
  wasm-tools strip "$tmp/$t.wasm" -o "$DEST/$t.wasm"
  # Manifest is optional upstream (absent = run + expect exit 0).
  if git -C "$CLONE" cat-file -e "$PIN_SHA:tests/rust/wasm32-wasip3/src/bin/$t.json" 2>/dev/null; then
    git -C "$CLONE" show "$PIN_SHA:tests/rust/wasm32-wasip3/src/bin/$t.json" > "$DEST/$t.json"
  fi
done

# The filesystem tests' preopen tree (manifest "root": "fs-tests.dir"); the
# harness copies it to a temp dir per run (tests mutate the tree).
mkdir -p "$DEST/fs-tests.dir"
for f in $(git -C "$CLONE" ls-tree -r --name-only "$PIN_SHA" tests/rust/wasm32-wasip3/src/bin/fs-tests.dir/); do
  git -C "$CLONE" show "$PIN_SHA:$f" > "$DEST/fs-tests.dir/$(basename "$f")"
done

echo "vendored ${#TESTS[@]} tests at pin $PIN_SHA into $DEST"
