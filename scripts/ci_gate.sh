#!/usr/bin/env bash
# scripts/ci_gate.sh — single source of truth for the HOST-LOCAL verification
# gate. Both CI (.github/workflows/ci.yml, once per matrix OS) and the local
# maintainer flow (gate_merge.sh mirrors these same steps) run this, so CI can
# never verify LESS than the per-host gate. It checks the CURRENT host only;
# multi-host fan-out is the caller's job (the CI matrix / gate_merge's SSH legs).
#
#   Core (every OS):  zig fmt --check (src/ + bench/latency/) + zig build test-all
#                     + bench-latency-build
#   Extended (ZWASM_CI_EXTENDED=1; Unix legs): lint + build-option DCE +
#     ReleaseSafe JIT smoke (D-245) + AOT cross-compile portability +
#     external system-linker consumer (test_extlink.sh) + zone_check +
#     spill_aware_check (host-independent source checks, promoted to CI
#     2026-07-03 as real merge gates)
#
# Usage:
#   bash scripts/ci_gate.sh                    # core gate on this host
#   ZWASM_CI_EXTENDED=1 bash scripts/ci_gate.sh   # + extended checks
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[ci_gate] host: $(uname -s) — zig $(zig version)"

echo "[ci_gate] (1/3) zig fmt --check src/ bench/latency/ tools/"
zig fmt --check src/
# bench/latency/ is compiled by step 3 but lives outside src/, so without this
# it would be the one Zig file in the tree whose formatting can drift silently.
zig fmt --check bench/latency/
# tools/lint/build.zig is only built by the extended leg's `zig build lint`,
# so without this its formatting would drift unchecked on every PR. The
# exclude is load-bearing: zig unpacks packages into <build root>/zig-pkg,
# and `zig fmt` recurses into it (it skips .zig-cache on its own, not this),
# so without it a zlinter/zls bump could red this gate on a vendored file.
zig fmt --check --exclude tools/lint/zig-pkg tools/

echo "[ci_gate] (2/3) zig build test-all"
# `--summary all` prints each step's own wall time (zig records
# `result_duration_ns` and reports it in the summary tree). Without it a CI log
# gives no step-level timing at all, and `test-all` is ~98% of the macOS leg —
# so every question about where that leg's time goes had to be answered by
# inferring from gaps between log lines, which produced a wrong answer twice.
# Costs no runtime and ~200 lines on a ~58k-line log (measured 0.36%).
zig build test-all --summary all

# ADR-0209 — compile-only. `bench-latency` is a measurement and stays out of
# test-all, but without SOMETHING building it, public-API drift would break the
# bench with no signal until a human ran it by hand.
echo "[ci_gate] (3/3) zig build bench-latency-build (compile-only, ADR-0209)"
zig build bench-latency-build

# rust-host embedding consumer (D-254): the third independent embedding-ABI
# consumer (docs/examples/rust_host/hello.rs links the same libzwasm.a the C
# host uses) — exercise it so it can't rot silently. LINUX-only: the ubuntu
# runner ships a gnu-target rustc that is ABI-compatible with zig's native
# libzwasm.a, so the link is clean (the macOS SDK dance + the Windows rust ABI
# question are out of scope here). Runs on EVERY PR (core), so a break shows on
# the PR's Linux leg before merge, not post-merge. Skips gracefully where rustc
# is absent (e.g. a local gate host without the .#rust-host shell).
if [ "$(uname -s)" = "Linux" ]; then
    if command -v rustc >/dev/null 2>&1; then
        echo "[ci_gate] rust-host embedding consumer (zig build run-rust-host, D-254)"
        zig build run-rust-host
    else
        echo "[ci_gate] (skip run-rust-host — rustc not on PATH; needs the .#rust-host shell)"
    fi
fi

# Test-discovery guard (sweep S5): a named test block that no test step
# discovers never runs. Discovery is HOST-DEPENDENT for the arch-specific
# codegen files (an arm64-only file is analysed natively on an arm64 host but
# needs an explicit import to be reached on x86_64), so this has to run per-OS
# — and on every PR, not just the merge to main, or the first signal is a red
# `main` instead of a red PR (which is exactly how it first fired).
echo "[ci_gate] test-discovery guard (check_test_discovery --gate)"
bash scripts/check_test_discovery.sh --gate

# Spec-manifest shape guard (ADR-0210). The spec runners print an
# enumeration denominator whose whole value is that a third party can
# re-derive it with `wc -l`. That only holds while the corpora stay one
# directive per line — a regen introducing blank or comment lines would
# break the re-derivation while both the runner and the corpus stayed
# green. Cheap (a read of 86 manifests), so it runs on every PR.
echo "[ci_gate] spec-manifest shape guard (check_spec_manifest_shape --gate)"
# Output kept (not `> /dev/null`, unlike the gate_commit invocations): the
# whole value of this guard is naming WHICH manifest broke the
# re-derivation, and a red CI leg showing only a bare non-zero exit would
# make the next person reproduce it by hand. Matches check_test_discovery
# above.
bash scripts/check_spec_manifest_shape.sh --gate

# ReleaseSafe-runner floor (ADR-0177). `gate_commit.sh` also runs this, but it
# is optional pre-flight and fires only when build.zig is staged; the merge
# path needs it unconditionally, because a runner dropped to Debug costs the
# leg minutes while every gate stays green. A grep over one file, so it sits in
# the core gate rather than behind ZWASM_CI_EXTENDED.
echo "[ci_gate] ReleaseSafe-runner floor (check_releasesafe_runners)"
bash scripts/check_releasesafe_runners.sh

if [ "${ZWASM_CI_EXTENDED:-0}" = "1" ]; then
    echo "[ci_gate] extended: zig build lint"
    zig build lint

    echo "[ci_gate] extended: build-option DCE / level-separation (9 combos)"
    bash scripts/check_build_dce.sh --gate

    echo "[ci_gate] extended: --engine=jit ReleaseSafe smoke (D-245)"
    bash scripts/check_jit_releasesafe.sh

    echo "[ci_gate] extended: AOT cross-compile portability (§12.3)"
    bash scripts/check_aot_cross_compile.sh

    # Wired 2026-08-03 (issue #153): the external non-zig link line was
    # documented but never gated, so a false "zig bundles compiler-rt into the
    # .a" claim reached a downstream consumer as a link failure. Unix legs only
    # (the script assumes a POSIX `cc` + `ar`).
    echo "[ci_gate] extended: external system-linker consumer (test_extlink.sh, D-312)"
    bash scripts/test_extlink.sh

    # Host-independent source checks (promoted to CI 2026-07-03 per the
    # scaffolding-decisions batch). They walk src/ only, so the Unix extended
    # leg is a fine home; zone_check is now a real merge gate via ci-required.
    echo "[ci_gate] extended: zone dependency check (zone_check --gate)"
    bash scripts/zone_check.sh --gate

    # Promoted 2026-07-03 (D-505): the 7 pre-existing arm64-SIMD violations were
    # triaged — the 3 emitI*Bitmask GPR-result sites made spill-aware, the
    # bitselect/fma resolveFp 3rd/4th-V-operand sites marked SPILL-EXEMPT (need
    # FP spill stage-2, D-506). Baseline is 0; --gate rejects any regression.
    echo "[ci_gate] extended: spill-aware op-handler check (spill_aware_check --gate)"
    bash scripts/spill_aware_check.sh --gate

    # Sweep S5 (2026-08-12): the growth ratchet gates DELTA on already-over-cap
    # files (the absolute caps stay advisory per ADR-0099); the discovery guard
    # compares source test blocks against the compiler's own test listing
    # (the ADR-0207 II-2a dead-test incident class).
    echo "[ci_gate] extended: file growth ratchet (file_growth_ratchet --gate)"
    RATCHET_BASE="${RATCHET_BASE:-origin/main}" bash scripts/file_growth_ratchet.sh --gate
fi

echo "[ci_gate] OK ($(uname -s))"
