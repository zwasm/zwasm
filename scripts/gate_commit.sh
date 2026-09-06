#!/usr/bin/env bash
# Pre-commit gate. Runs (in order):
#   1. Diff classification (docs-only / src-touching / ADR-touching) — drives short-circuits.
#   2. zig fmt --check src/ docs/examples/ bench/latency/ tools/   — always.
#   3. scripts/zone_check.sh --gate                          — skipped on docs-only.
#   4. scripts/file_size_check.sh --gate                    — skipped on docs-only.
#   5. scripts/check_skip_adrs.sh --gate                     — skipped on docs-only.
#   6. scripts/check_adr_history.sh --gate                   — only when an ADR changed.
#   7. scripts/check_lesson_citing.sh                        — info only (warn count).
#   8. scripts/check_libc_boundary.sh (report)              — info; skipped on docs-only.
#   9. scripts/check_fallback_patterns.sh (report)          — info; skipped on docs-only.
#  10. scripts/check_invariant_comments.sh --strict         — gate (ADR-0077, B128); skipped on docs-only.
#  11. scripts/check_engine_default_claims.sh --gate        — gate; ALWAYS (docs are the thing it guards).
#  12. scripts/check_wasi03_coverage_claims.sh --gate       — gate; ALWAYS (same reason).
#  13. scripts/check_doc_fossils.sh --gate                  — gate; ALWAYS (same reason).
#  14. zig build test (Mac native)                          — skipped on docs-only.
#
# Per the A6 gate consolidation study (§9.12-A / A6), docs/config-only
# diffs cannot move src/-related gate outcomes, so they short-circuit.
# Target: ~29 s docs-only pre-commit → ~3 s.
#
# Conservative case (ANY_STAGED=0, i.e. `git commit -a` / amend with
# empty --cached): treated as src-touching to be safe.
#
# Exits non-zero on any gate failure.

set -euo pipefail
cd "$(dirname "$0")/.."

# --- arg parsing ---------------------------------------------------------
#
# --fast: skip `zig build test` and `zig build lint`. Used by the
# pre-commit / pre-push hooks (ADR-0076 D4): the /continue loop is
# already responsible for running test (Step 5) + lint (Step 4) before
# commit, and re-running them inside the git hook is pure duplication.
# Manual commits OR explicit `bash scripts/gate_commit.sh` (no flag)
# still run the full gate as a safety net.

FAST_MODE=0
for arg in "$@"; do
    case "$arg" in
        --fast) FAST_MODE=1 ;;
    esac
done

# --- bounded execution ----------------------------------------------------
#
# 2026-06-12 host-memory-exhaustion audit: an unbounded `zig build test`
# that hangs (e.g. a JIT-miscompiled infinite loop before D-314 interrupt
# polls existed) becomes an hours-long orphan when the invoking session
# dies — an 8.5 h zig process was observed overnight (21:27→05:54).
# Every zig build here is bounded; a hang dies by itself even orphaned.
bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 30 "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout -k 30 "$secs" "$@"
    else
        "$@"
    fi
}

# --- diff classification -------------------------------------------------

STAGED="$(git diff --cached --name-only)"
SRC_TOUCHED=0
ADR_TOUCHED=0
RULES_TOUCHED=0
SKILLS_TOUCHED=0
DEV_MD_TOUCHED=0
DEBT_YAML_TOUCHED=0
ANY_STAGED=0
if [ -n "$STAGED" ]; then
    ANY_STAGED=1
    while IFS= read -r f; do
        case "$f" in
            src/*|test/*|include/*|bench/latency/*|build.zig|build.zig.zon|flake.nix|flake.lock)
                SRC_TOUCHED=1
                ;;
            .dev/decisions/*.md|.dev/decisions/*/*.md)
                ADR_TOUCHED=1
                ;;
        esac
        case "$f" in
            .claude/rules/*.md)
                RULES_TOUCHED=1
                ;;
            .claude/skills/*/SKILL.md)
                SKILLS_TOUCHED=1
                ;;
        esac
        # .dev/*.md but not .dev/decisions/*.md (covered by ADR_TOUCHED)
        # nor lessons (Citing field has its own check). Doc-state marker
        # check applies to phase_log / archive / architecture / meta_audits /
        # phase10_prep / and the loose top-level .dev/*.md files.
        case "$f" in
            .dev/decisions/*|.dev/lessons/*)
                # Skip — handled by check_adr_history / check_lesson_citing.
                ;;
            .dev/*.md|.dev/*/*.md|.dev/*/*/*.md)
                DEV_MD_TOUCHED=1
                ;;
        esac
        case "$f" in
            .dev/debt.yaml)
                DEBT_YAML_TOUCHED=1
                ;;
        esac
    done <<< "$STAGED"
fi

DOCS_ONLY=0
if [ "$ANY_STAGED" -eq 1 ] && [ "$SRC_TOUCHED" -eq 0 ] && [ "$ADR_TOUCHED" -eq 0 ]; then
    DOCS_ONLY=1
fi

# --- gate: zig fmt (always) ---------------------------------------------

echo "[gate_commit] zig fmt --check src/ docs/examples/ bench/latency/ tools/ ..."
if [ -d src ] && [ -n "$(find src -name '*.zig' 2>/dev/null | head -1)" ]; then
    zig fmt --check src/
    # docs/examples/ carries committable .zig consumers (zig_dep / zig_host); keep
    # them fmt-clean too (they slipped pre-2026-06-05 because only src/ was checked).
    # Guarded on docs/examples/, not `examples/`: the directory moved under
    # docs/ and the stale guard meant this check never actually ran.
    if [ -d docs/examples ] && [ -n "$(find docs/examples -name '*.zig' 2>/dev/null | head -1)" ]; then
        zig fmt --check docs/examples/
    fi
    # bench/latency/ carries the per-call latency runner (ADR-0209); it is
    # compiled by the core gate but sits outside src/, so it needs naming here
    # for the same reason docs/examples/ did.
    if [ -d bench/latency ] && [ -n "$(find bench/latency -name '*.zig' 2>/dev/null | head -1)" ]; then
        zig fmt --check bench/latency/
    fi
    # tools/ carries the lint sub-build (ADR-0214), which only `zig build lint`
    # compiles — same reason again. --exclude because zig unpacks packages
    # into tools/lint/zig-pkg and `zig fmt` recurses into it.
    if [ -d tools ] && [ -n "$(find tools -name '*.zig' 2>/dev/null | head -1)" ]; then
        zig fmt --check --exclude tools/lint/zig-pkg tools/
    fi
else
    echo "(no src/*.zig yet — skipping fmt)"
fi

# --- gates: prose-truth checks (always — docs are exactly what rots) ----
#
# The three checks CI's `doc-truth` job runs on every PR, doc-only included.
# They sit ABOVE the docs-only short-circuit for the reason that job exists:
# their subject is the prose the short-circuit would otherwise skip. Each
# writes its findings to stderr, so `> /dev/null` hides only the OK chatter.

echo "[gate_commit] check_engine_default_claims --gate ..."
bash scripts/check_engine_default_claims.sh --gate > /dev/null
echo "[gate_commit] check_wasi03_coverage_claims --gate ..."
bash scripts/check_wasi03_coverage_claims.sh --gate > /dev/null
echo "[gate_commit] check_doc_fossils --gate ..."
bash scripts/check_doc_fossils.sh --gate > /dev/null

# --- gates: zone + file_size + skip_adrs (skipped on docs-only) ---------

if [ "$DOCS_ONLY" -eq 1 ]; then
    echo "[gate_commit] (docs-only diff — skipping zone_check + file_size_check + check_skip_adrs)"
else
    # zone_check.sh walks every `src/**/*.zig` file with a per-file
    # awk + grep + cd subshell, costing ~100 s in current shape.
    # In --fast mode it is delegated to `audit_scaffolding` (periodic)
    # — the rule itself is load-bearing, but per-commit enforcement
    # at this cost is not. Full-gate mode (no --fast) still runs it
    # as a manual-commit safety net (per ADR-0076 D4 amend).
    if [ "$FAST_MODE" -eq 1 ]; then
        echo "[gate_commit] (--fast — skipping zone_check; audit_scaffolding owns it per ADR-0076 D4)"
    else
        echo "[gate_commit] zone_check --gate ..."
        bash scripts/zone_check.sh --gate
    fi

    echo "[gate_commit] file_size_check --gate ..."
    bash scripts/file_size_check.sh --gate
    echo "[gate_commit] file_growth_ratchet --gate ..."
    bash scripts/file_growth_ratchet.sh --gate

    # D-505: spill-aware op-handler convention (bare resolveGpr/Fp on a spilled
    # vreg → UnsupportedOp JIT-reject). Cheap pure-awk walk of the codegen
    # op-handler files; BASELINE=0. Previously listed as wired but was not —
    # this closes that gap. Also runs in CI's extended leg (ci_gate.sh).
    echo "[gate_commit] spill_aware_check --gate ..."
    bash scripts/spill_aware_check.sh --gate

    # Per ADR-0099 §D4: informational split-smell checker. Surfaces
    # N1 (helper-circular import) / N3 (shallow module) / N4 (test
    # dup) / hub-emptiness findings to stderr but never gates the
    # commit. Reviewers triage findings against §D2 4+4 conditions.
    if [ -x scripts/check_split_smell.sh ]; then
        echo "[gate_commit] check_split_smell (info; per ADR-0099) ..."
        bash scripts/check_split_smell.sh || true
    fi

    # Per ADR-0029 Path B (chunk 9.9-h-24): verify prefix-vocab
    # coherence — every `skip-adr-<id>` manifest line resolves to an
    # existing `.dev/decisions/skip_<id>.md` ADR, and every skip-ADR
    # has ≥ 1 manifest consumer (no orphans). Plus the original
    # fixture-path existence checks for cited `.wasm` files.
    # Issue #161: an src/api file with `pub export fn` absent from the
    # zwasm.zig comptime force-analyse block ships a libzwasm.a missing
    # every symbol the file exports (and never compiles or runs its tests).
    # Pure grep — cross-platform, no build. The built-archive side of the
    # invariant lives in test_extlink.sh (CI extended).
    echo "[gate_commit] check_api_export_analysis --gate ..."
    bash scripts/check_api_export_analysis.sh --gate > /dev/null

    echo "[gate_commit] check_skip_adrs --gate ..."
    bash scripts/check_skip_adrs.sh --gate > /dev/null
    # ADR-0122 (2026-05-27) — test-time SkipZigTest categorization:
    # all skips must route via src/test_support/skip.zig helpers
    # (phaseEnd / blocker categories) or be comptime arch-pinned
    # with paired SIBLING-AT comment. Orthogonal to check_skip_adrs
    # (which covers runtime SKIP-* token taxonomy from spec runners).
    echo "[gate_commit] check_skip_helpers --gate ..."
    bash scripts/check_skip_helpers.sh --gate > /dev/null

    # ADR-0210 — the spec runners' enumeration denominator is only
    # re-derivable while the corpora stay one directive per line.
    echo "[gate_commit] check_spec_manifest_shape --gate ..."
    bash scripts/check_spec_manifest_shape.sh --gate > /dev/null
fi

# --- gate: check_adr_history (only when an ADR changed or empty diff) ---

if [ "$ADR_TOUCHED" -eq 1 ] || [ "$ANY_STAGED" -eq 0 ]; then
    if [ -x scripts/check_adr_history.sh ]; then
        echo "[gate_commit] check_adr_history --gate ..."
        bash scripts/check_adr_history.sh --gate > /dev/null
    fi
elif [ "$DOCS_ONLY" -eq 0 ]; then
    echo "[gate_commit] (no ADR changed — skipping check_adr_history)"
fi

# --- gate: ReleaseSafe runner floor (when build.zig staged; ADR-0177) ---

if grep -qE '(^|/)build\.zig$' <<<"$STAGED"; then
    if [ -x scripts/check_releasesafe_runners.sh ]; then
        echo "[gate_commit] check_releasesafe_runners ..."
        bash scripts/check_releasesafe_runners.sh
    fi
fi

# --- gate: lesson citing (info only) ------------------------------------

if [ -x scripts/check_lesson_citing.sh ]; then
    n=$(bash scripts/check_lesson_citing.sh 2>&1 | grep -c '^WARN ') || true
    if [ "$n" -gt 0 ]; then
        echo "[gate_commit] (info) $n lesson(s) with unfilled Citing — backfill at phase boundary"
    fi
fi

# --- gate: spec-distill library self-tests (when staged) ----------------
#
# The shared distiller value-dialect lib (`scripts/spec_distill/`) absorbs
# wasm-tools `json-from-wast` JSON-shape evolution in ONE place; its self-tests
# pin the encoding so a future tool/spec bump can't silently mis-bake the
# conformance corpus. Each module is self-testing via `__main__`.

if echo "$STAGED" | grep -q '^scripts/spec_distill/.*\.py$'; then
    if command -v python3 >/dev/null 2>&1; then
        echo "[gate_commit] spec_distill self-tests ..."
        for t in scripts/spec_distill/*.py; do
            python3 "$t" > /dev/null || { echo "[gate_commit] spec_distill self-test FAILED: $t" >&2; exit 1; }
        done
    fi
fi

# --- gates: A1 checks (informational; skipped on docs-only) -------------
#
# Per §9.12-A / A7: wire as informational, not --gate, until the
# Both check_libc_boundary and check_fallback_patterns now run in
# strict `--gate` mode — preconditions cleared:
#   - check_libc_boundary: 9 replaceable sites migrated in §9.12-D
#     (current site count = 0).
#   - check_fallback_patterns: 10 existing `catch {}` sites marked
#     EXEMPT-FALLBACK with ADR-0014 / ADR-0016 citations at 0d524134.

if [ "$DOCS_ONLY" -eq 0 ]; then
    if [ -x scripts/check_libc_boundary.sh ]; then
        echo "[gate_commit] check_libc_boundary --gate ..."
        bash scripts/check_libc_boundary.sh --gate > /dev/null
    fi
    if [ -x scripts/check_fallback_patterns.sh ]; then
        echo "[gate_commit] check_fallback_patterns --gate ..."
        bash scripts/check_fallback_patterns.sh --gate > /dev/null
    fi
    # ADR-0077 strict gate (§9.12-C / B128). The B126 sweep
    # discharged all 55 latent overlap sites; --strict now fails
    # on any new digit-literal in the arm64 op_*.zig pool range,
    # forbidding re-introduction of the D-132/D-133 failure mode.
    if [ -x scripts/check_invariant_comments.sh ]; then
        echo "[gate_commit] check_invariant_comments --strict ..."
        bash scripts/check_invariant_comments.sh --strict > /dev/null
    fi
    # ADR-0094 (D-158): SIBLING-PUB marker audit. Walks
    # `// SIBLING-PUB:` markers + verifies no unauthorized
    # importer calls the pub decl. @import-filter eliminates
    # false positives on common names (e.g. `emit`).
    if [ -x scripts/check_sibling_pub.sh ]; then
        echo "[gate_commit] check_sibling_pub --gate ..."
        bash scripts/check_sibling_pub.sh --gate > /dev/null
    fi
    # C-ABI drift guard: include/zwasm.h ZWASM_TRAP_* constants MUST match the
    # TrapKind enum values (zwasm_trap_kind's return). Cross-artifact (C header ↔
    # Zig enum), so it can't be a @embedFile unit test — runs here.
    if [ -x scripts/check_trap_abi_sync.sh ]; then
        echo "[gate_commit] check_trap_abi_sync --gate ..."
        bash scripts/check_trap_abi_sync.sh --gate > /dev/null
    fi
    # D-180 (lesson 2026-05-28-x86_64-uses-runtime-ptr-eh-gap):
    # x86_64 `usesRuntimePtr` whitelist drift detector. Any op
    # whose emit produces R15-dependent bytes MUST be listed; drift
    # = silent miscompile on Linux x86_64 (Mac aarch64 immune).
    # Informational; reviewer responds to WARN.
    if [ -x scripts/check_uses_runtime_ptr.sh ]; then
        echo "[gate_commit] check_uses_runtime_ptr (info) ..."
        bash scripts/check_uses_runtime_ptr.sh
    fi
fi

# --- gate: zig build test (skipped on docs-only OR --fast) ---------------

if [ "$FAST_MODE" -eq 1 ]; then
    echo "[gate_commit] (--fast — skipping zig build test; /continue Step 5 owns it per ADR-0076 D4)"
elif [ ! -f build.zig ]; then
    echo "[gate_commit] (no build.zig — skipping zig build test)"
elif [ "$DOCS_ONLY" -eq 1 ]; then
    echo "[gate_commit] (docs/config-only diff — skipping zig build test)"
else
    echo "[gate_commit] zig build test ..."
    bounded 1800 zig build test
fi

# --- gate: edge-case fixture runner (corpus-touching commits only) -------
#
# Closes the "a fixture misplaced under test/edge_cases/ breaks the edge-runner,
# invisible to `zig build test`, caught only one cycle later on the remote
# test-all" gap (lesson 2026-06-07-fixtures-under-edge-cases-run-by-edge-runner).
# `zig build test` runs only in-source unit tests; the edge-runner walks the
# corpus and is normally test-all-only. Run it HERE, in BOTH fast and full modes
# (the corpus is ~seconds, host-arch JIT, and this is the only LOCAL place it
# runs — Step 5's `zig build test` excludes it), whenever a commit touches the
# runner's corpus roots. A misplaced/broken fixture (missing .expect /
# unsatisfiable host import) fails the commit here, not on x86_64 next cycle.
# This is enforcement, NOT swallow/skip: the runner still fails loudly.
if [ -f build.zig ] && echo "$STAGED" | grep -qE '^test/(edge_cases|realworld)/'; then
    echo "[gate_commit] zig build test-edge-cases (corpus fixtures staged) ..."
    bounded 900 zig build test-edge-cases
fi

# --- gate: zig build lint (skipped on docs-only OR --fast) ---------------
#
# Lint findings are platform-independent and architecturally orthogonal
# to test failures, so they get their own gate. In --fast mode the
# /continue Step 4 owns it (per ADR-0076 D4).

if [ "$FAST_MODE" -eq 1 ]; then
    echo "[gate_commit] (--fast — skipping zig build lint; /continue Step 4 owns it per ADR-0076 D4)"
elif [ ! -f build.zig ]; then
    echo "[gate_commit] (no build.zig — skipping zig build lint)"
elif [ "$DOCS_ONLY" -eq 1 ]; then
    echo "[gate_commit] (docs/config-only diff — skipping zig build lint)"
else
    echo "[gate_commit] zig build lint ..."
    bounded 900 zig build lint -- --max-warnings 0
fi

# --- scope-gated lints: rules / skills / .dev/*.md markers --------------
#
# Per D-058 / D-059 (discharged at cycle 85) + cycle-82 audit's §H
# block finding (Doc-state markers missing on 12 .dev/*.md files;
# fixed in cycle 82 but check wasn't gate-wired). Each lint runs only
# when its scope is touched, so docs-only commits don't pay the
# full-tree walk cost.

if [ "$RULES_TOUCHED" -eq 1 ] && [ -x scripts/check_rule_paths.sh ]; then
    echo "[gate_commit] check_rule_paths --gate ..."
    bash scripts/check_rule_paths.sh --gate > /dev/null
fi

if [ "$SKILLS_TOUCHED" -eq 1 ] && [ -x scripts/check_skill_descriptions.sh ]; then
    echo "[gate_commit] check_skill_descriptions --gate ..."
    bash scripts/check_skill_descriptions.sh --gate > /dev/null
fi

if [ "$DEV_MD_TOUCHED" -eq 1 ] && [ -x scripts/check_doc_state.sh ]; then
    echo "[gate_commit] check_doc_state --gate ..."
    bash scripts/check_doc_state.sh --gate > /dev/null
fi

# debt.yaml schema gate (D-227 / ADR-0129): when the ledger is touched,
# validate parse + required fields + status enum + blocked-by review-dates
# + unique IDs + no phantom D-NEW* (a malformed block scalar would silently
# break every yq query the loop's Step 0.5 sweep depends on).
if [ "$DEBT_YAML_TOUCHED" -eq 1 ] && [ -x scripts/check_debt_yaml.sh ]; then
    echo "[gate_commit] check_debt_yaml --gate ..."
    bash scripts/check_debt_yaml.sh --gate > /dev/null
fi

echo "[gate_commit] All gates passed."
