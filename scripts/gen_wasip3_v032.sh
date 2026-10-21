#!/usr/bin/env bash
# Derive test/component/wasip3/cli-env-v032.wasm from the official cli-env
# (see test/component/wasip3/README_cli_env_v032.md). Needs perl and a
# wasm-tools that reads CM-async func types (1.262 does, 1.237 does not).
set -euo pipefail

cd "$(dirname "$0")/../test/component"
src=wasip3_official/cli-env.wasm
dst=wasip3/cli-env-v032.wasm

perl -0777 -pe 's/\@0\.3\.0/\@0.3.2/g' "$src" > "$dst"
# cmp -l prints octal bytes: every differing byte must be '0' (060) -> '2' (062).
diffs=$(cmp -l "$src" "$dst" || true)
[ -n "$diffs" ] && ! awk '$2 != 60 || $3 != 62' <<<"$diffs" | grep -q .
wasm-tools validate "$dst"
echo "generated $dst ($(wc -l <<<"$diffs") version digits rewritten)"
