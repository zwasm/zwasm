#!/usr/bin/env bash
# D-245 regression gate — host→JIT calls must preserve the host's callee-saved
# registers. The bug ONLY manifests in ReleaseSafe (the optimized host keeps
# live values in the callee-saved regs the JIT clobbers); the Debug-only
# `runWasmJit` unit test missed it, so it shipped. A build.zig run-artifact
# can't catch it because an exe's optimize mode does NOT propagate to imported
# modules (the `core` lib keeps its own -Doptimize), so the only faithful check
# is a full `-Doptimize=ReleaseSafe` build + run.
#
# Build ReleaseSafe + run a SIMD `_start` via `--engine=jit` (the interp has no
# SIMD, so this forces the JIT execute path). A non-zero exit = the
# callee-saved-clobber SEGV regressed. Cheap to read, ~minutes to build.
#
# Where this runs: `ci_gate.sh` invokes it inside the ZWASM_CI_EXTENDED leg,
# which fires on the push to `main` and NOT on a pull request. A regression in
# this class therefore reaches `main` before any lane reports it — the same
# shape of gap that let the original defect ship. The cost is the reason: this
# is a full cold ReleaseSafe build, and the PR gate is already the slowest
# thing in the loop. Promoting it to the core leg is the fix if that cost ever
# becomes affordable.
set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURE=bench/runners/wasm/simd/i32x4_add.wasm
echo "[check_jit_releasesafe] zig build -Doptimize=ReleaseSafe ..."
zig build -Doptimize=ReleaseSafe >/dev/null
echo "[check_jit_releasesafe] zwasm run --engine=jit $FIXTURE ..."
if zig-out/bin/zwasm run --engine=jit "$FIXTURE" >/dev/null 2>&1; then
    echo "[check_jit_releasesafe] OK — --engine=jit runs in ReleaseSafe (D-245 void path fixed)."
else
    rc=$?
    echo "[check_jit_releasesafe] FAIL (exit $rc) — --engine=jit crashed in ReleaseSafe; D-245 callee-saved-preservation regressed (see src/engine/codegen/shared/entry.zig invokeAndCheckVoid)." >&2
    exit 1
fi

# §15.5 chunk 1: the no-arg VOID path above does NOT cover the i32 RESULT path
# (`runner.runI32Export` → `entry.invokeAndCheck` → `jitTrampoline`). The probe
# step compiles a fresh `core` PINNED to ReleaseSafe + a host that holds live
# callee-saved values across the JIT call, asserting the result (==42) and that
# no live host slice was corrupted by the cohort clobber. Non-zero exit = the
# RESULT-path trampoline regressed.
echo "[check_jit_releasesafe] zig build jit-result-probe-releasesafe (RESULT path) ..."
if zig build jit-result-probe-releasesafe >/dev/null 2>&1; then
    echo "[check_jit_releasesafe] OK — runI32Export preserves the host cohort in ReleaseSafe (D-245 result path fixed)."
else
    rc=$?
    echo "[check_jit_releasesafe] FAIL (exit $rc) — runI32Export crashed/mismatched in ReleaseSafe; D-245 RESULT-path preservation regressed (see src/engine/codegen/shared/entry.zig jitTrampoline / invokeAndCheck)." >&2
    exit 1
fi

# 2026-08-25 — the two legs above cover the VOID path and the i32 RESULT path.
# They do not reach the MIXED multi-result thunks (`(i32, f64)`, `(f64, i32)`,
# `(f64, f32)`), which have their own hand-written asm and had the same defect
# this gate exists for: they never bracketed the JIT call with a save of
# X19-X28, so an optimised host lost live values there. They also named x0 as
# both an untied input and an output of the same asm, which lets the allocator
# place the output's def ahead of the input's use.
#
# The corpus that reaches them is `call_indirect`, whose `type-all-i32-f64` and
# siblings return mixed pairs. Debug passes it either way — the whole point is
# that only an optimised build shows the fault — so this runs the real runner
# against the real corpus at ReleaseSafe. Every optimisation mode failed
# identically when the defect was live, so ReleaseSafe alone is a faithful
# probe.
echo "[check_jit_releasesafe] mixed multi-result thunks at ReleaseSafe ..."
MIXED_DIR=$(mktemp -d)
trap 'rm -rf "$MIXED_DIR"' EXIT
cp -r test/spec/wasm-2.0-assert/call_indirect "$MIXED_DIR/"
if zig-out/bin/zwasm-spec-wasm-2-0-assert "$MIXED_DIR" >/dev/null 2>&1; then
    echo "[check_jit_releasesafe] OK — mixed int/float multi-result returns survive optimisation."
else
    rc=$?
    echo "[check_jit_releasesafe] FAIL (exit $rc) — the mixed-result thunks regressed in ReleaseSafe (this leg runs on whichever host builds it — aarch64 and x86_64 alike); see src/engine/codegen/shared/entry.zig callI32f64NoArgs / callF64i32NoArgs / callF64f32NoArgs (x0 must not be both an input and an output of the asm; X19-X28 must be saved around the BLR)." >&2
    exit 1
fi
