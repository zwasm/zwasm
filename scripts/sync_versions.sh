#!/usr/bin/env bash
# Verify versions.lock <-> flake.nix consistency (D136 from v1).
# For Phase 0-13, this only checks that flake.nix pins Zig 0.17.1.
# Phase 14+ extends with versions.lock for SDK / wasm-tools / etc.

set -euo pipefail
cd "$(dirname "$0")/.."

if ! grep -q '"0.17.1"' flake.nix; then
    echo "[sync_versions] flake.nix does not pin Zig 0.17.1." >&2
    exit 1
fi

echo "[sync_versions] flake.nix pins Zig 0.17.1 — OK."
