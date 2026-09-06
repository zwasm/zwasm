#!/usr/bin/env bash
# check_releasesafe_runners.sh — guard the ADR-0177 ReleaseSafe-runner floor.
#
# A plain `zig build test-all` (Debug default) must run every HEAVY e2e/corpus
# runner ReleaseSafe (~100× faster; cf. ClojureWasmFromScratch's campaign +
# lesson `releasesafe-runner-floor-audit`). The floor is the `core_rs` /
# `zwasm_lib_mod` (= core_rs) / `core_releasesafe` modules + any module on
# `.optimize = runner_optimize`. This check fails when:
#   (a) a NEW module imports the Debug `core` module as "zwasm" outside the
#       justified allowlist (a new runner that forgot the floor), OR
#   (a2) a runner is handed the Debug `exe` as a SPAWNED BINARY — the channel
#       (a) cannot see, because the runner imports no zwasm module at all.
#   (b) `core_comp` (the Component Model spec runner's module; the
#       `test-component-spec` summary prints its corpus size as
#       `(over N manifests)`) regresses from `runner_optimize` back to raw
#       `optimize` (= Debug) — the 2026-06-14 gap.
#
# Honours-`-Doptimize` allowlist (verified intentional): `core` itself
# (self-import), `core_tests` (leak-detecting DebugAllocator by default; CI's
# Linux leg also runs it ReleaseSafe, #347), `exe` AS THE INSTALLED ARTIFACT
# (the shipped CLI honours -Doptimize) — but NOT as a runner's engine, which is
# what (a2) checks — the light unit-test mods, the trivial single-wasm examples.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD=build.zig
fail=0

# (a) Modules importing the Debug `core` module (exact `core`, not core_rs /
#     core_comp / core_releasesafe). Allowlist = Debug-by-design consumers.
# `zig_host_jit_mod` (ADR-0200): trivial 2-func JIT mini-consumer — JIT-emitted
# code runs at native speed regardless of core's build mode, so the Debug-core
# penalty is only the negligible compile of 2 tiny funcs (NOT a corpus runner).
allow='^(core|exe_mod|spec_assert_base_test_mod|wasm_3_0_assert_unit_mod|wasm_3_0_manifest_unit_mod|zig_host_mod|zig_host_jit_mod)$'
while IFS= read -r mod; do
  if ! [[ "$mod" =~ $allow ]]; then
    echo "[check_releasesafe_runners] BLOCK — '$mod' imports the Debug \`core\` module as zwasm."
    echo "  A runner on Debug core runs its corpus ~100× slower in test-all (ADR-0177)."
    echo "  Fix: import \`zwasm_lib_mod\` (= core_rs) instead, OR — if genuinely Debug-by-design"
    echo "  (unit test / production exe / trivial example) — add it to the allowlist here with a reason."
    fail=1
  fi
done < <(grep -oE '[a-z_0-9]+\.addImport\("zwasm", core\)' "$BUILD" | sed -E 's/\.addImport.*//')

# (a2) The SPAWN channel. (a) sees a runner only if it imports a zwasm module.
#      `test-aot-diff` consumes the engine as a spawned BINARY — the CLI is
#      handed to the runner via `addArtifactArg` — so it was invisible to (a)
#      and to the lesson's grep recipe, and ran its 64-fixture corpus on the
#      Debug `exe` for two months (531 s vs 19 s ReleaseSafe, same verdict).
#      `exe` is correctly on (a)'s allowlist: the SHIPPED binary must honour
#      -Doptimize. What is not correct is feeding that binary to a corpus
#      runner. Pass `exe_rs` (the ReleaseSafe twin) instead.
#      Not flagged: `addRunArtifact(exe)` — running the Debug CLI directly is
#      `zig build run` and the single-shot fault/oob-trap lanes, not a corpus.
# Matches the whole `add*Arg` family and `getEmittedBin`, not just
# `addArtifactArg(exe)`: build.zig already uses the prefixed-arg spelling
# elsewhere, so a narrower pattern would report OK on the same regression
# written a different way. `\bexe\b` so `exe_rs` does not match.
while IFS= read -r site; do
  echo "[check_releasesafe_runners] BLOCK — a runner is handed the Debug \`exe\`:"
  echo "    $site"
  echo "  A runner spawning the Debug CLI compiles its whole corpus far slower (ADR-0177)."
  echo "  Fix: pass \`exe_rs\` (the ReleaseSafe CLI twin) instead."
  fail=1
done < <(grep -nE 'add[A-Za-z]*Arg\([^)]*\bexe\b[^)]*\)|\bexe\.getEmittedBin\(' "$BUILD" \
         | grep -vE 'addRunArtifact')

# (b) core_comp must stay floored at runner_optimize (the 2026-06-14 fix).
#     Inspect the `const core_comp = b.createModule({...})` block.
core_comp_block=$(awk '/const core_comp = b\.createModule/{f=1} f{print} /\}\);/{if(f) exit}' "$BUILD")
if ! grep -qE '\.optimize = runner_optimize' <<<"$core_comp_block"; then
  echo "[check_releasesafe_runners] BLOCK — core_comp is not on \`.optimize = runner_optimize\`."
  echo "  The Component Model spec runner (the \`test-component-spec\` lane; its summary"
  echo "  prints the corpus size as \`(over N manifests)\`) would run Debug."
  echo "  Fix: \`.optimize = runner_optimize\` (ADR-0177 Revision 2026-06-14)."
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "[check_releasesafe_runners] OK — all e2e runners ReleaseSafe-floored (imports + spawns); core_comp floored."
fi
exit "$fail"
