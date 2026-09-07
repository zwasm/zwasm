#!/usr/bin/env bash
# check_ci_changes_detect.sh — the `changes` job's doc-only decision, exercised.
#
# `ci.yml`'s `changes` step decides whether a run pays the 3-OS gate. Its
# failure mode is a silent pass: `ci-required` treats a FAILED `changes` as
# fatal (D-520), but a `changes` that succeeds while answering `code=false`
# wrongly is green with nothing behind it. That has happened — #297, where
# `^docs/` swallowed `docs/examples/` and a build input skipped the whole gate.
# The guard against a repeat is a sentence in the step's own comment, which is
# the prose-only invariant `.claude/rules/comment_as_invariant.md` forbids.
#
# The `merge_group` arm (ADR-0227 D3) needs this more than the others: it does
# not run until a merge queue exists, so CI never exercises it, and under a
# queue the answer is acted on without anyone looking.
#
# The step's script is read out of `ci.yml` rather than copied, so the two
# cannot drift, and runs against a throwaway repository built here.
#
#   bash scripts/check_ci_changes_detect.sh          # informational, exit 0
#   bash scripts/check_ci_changes_detect.sh --gate   # exit 1 on any mismatch
set -euo pipefail

# yq (mikefarah v4) is not part of the base toolchain (Zig-only clones lack
# it). Absent -> SKIP with a pointer, never a bash stack trace (ADR-0206).
# git exports GIT_DIR and GIT_INDEX_FILE to its hooks, and GIT_DIR outranks
# `-C`: run from the pre-commit hook without clearing them, every git command
# below addresses the repository being committed to instead of the throwaway
# one. Measured — it re-inits that repository and lands this file's fixture
# commits in it, while still reporting OK. Nothing here needs the caller's git
# context, so the whole redirecting set goes.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_CEILING_DIRECTORIES GIT_PREFIX GIT_QUARANTINE_PATH

if ! command -v yq >/dev/null 2>&1; then
  echo "[check_ci_changes_detect] SKIP — yq (mikefarah v4) not found; install it (https://github.com/mikefarah/yq) or use 'nix develop'" >&2
  exit 0
fi
cd "$(dirname "$0")/.."

MODE="${1:-info}"
WF=.github/workflows/ci.yml

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

yq -r '.jobs.changes.steps[] | select(.id == "detect") | .run' "$WF" > "$TMP/detect.sh"
if [ ! -s "$TMP/detect.sh" ]; then
  echo "[check_ci_changes_detect] FAIL — no step with id 'detect' in the changes job of $WF" >&2
  exit 1
fi

# A repository whose history holds one commit per path class the step sorts on.
#
# Every git call names its repository with `-C "$REPO"`, and nothing here runs
# in a subshell or changes directory. Both matter: bash fires an inherited EXIT
# trap when a subshell exits, so a `( cd "$REPO"; ... )` block would run this
# script's own `rm -rf` cleanup and leave the git commands below executing in
# the checkout that invoked it.
REPO="$TMP/repo"
mkdir -p "$REPO/docs/examples" "$REPO/.dev" "$REPO/src"
git -C "$REPO" init -q -b work .
git -C "$REPO" config user.email check@example.invalid
git -C "$REPO" config user.name check
echo base > "$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD)

echo doc >> "$REPO/README.md"
echo note > "$REPO/.dev/note.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm doc
DOC=$(git -C "$REPO" rev-parse HEAD)

git -C "$REPO" reset -q --hard "$BASE"
echo code > "$REPO/src/thing.zig"
git -C "$REPO" add -A
git -C "$REPO" commit -qm code
CODE=$(git -C "$REPO" rev-parse HEAD)

git -C "$REPO" reset -q --hard "$BASE"
echo host > "$REPO/docs/examples/host.zig"
git -C "$REPO" add -A
git -C "$REPO" commit -qm example
EXAMPLE=$(git -C "$REPO" rev-parse HEAD)

fails=0
cases=0

check() { # name event base head want
  cases=$((cases + 1))
  local out
  : > "$TMP/gh_output"
  # `-C` is not available for the step's own `git diff`, so the working
  # directory has to be the throwaway repo. A subshell and not `env -C` — that
  # option is GNU coreutils only and macOS's BSD `env` rejects it. `$TMP` and
  # `$REPO` are absolute, so the paths below survive the `cd`.
  (
    cd "$REPO"
    EVENT="$2" \
    PR_BASE="$3" PR_HEAD="$4" \
    PUSH_BEFORE="$3" PUSH_HEAD="$4" \
    MG_BASE="$3" MG_HEAD="$4" \
    GITHUB_OUTPUT="$TMP/gh_output" \
    bash "$TMP/detect.sh" >/dev/null 2>&1
  ) || true
  out=$(grep -o 'code=[a-z]*' "$TMP/gh_output" | tail -1 || true)
  if [ "$out" != "code=$5" ]; then
    # No output means the step itself died on this input — a case that cannot
    # answer is as much a finding as one that answers wrongly.
    echo "[check_ci_changes_detect] FAIL $1 -> ${out:-(step produced no code=; it exited non-zero)} (want code=$5)" >&2
    fails=$((fails + 1))
  fi
}

# The arm this repository has no CI coverage for until a queue exists.
check "merge_group doc-only"        merge_group "$BASE" "$DOC"     false
check "merge_group code"            merge_group "$BASE" "$CODE"    true
check "merge_group docs/examples"   merge_group "$BASE" "$EXAMPLE" true
check "merge_group base unreachable" merge_group 0000000000000000000000000000000000000000 "$CODE" true
check "merge_group base empty"      merge_group ""      "$CODE"    true
# The arms that do run, so a change to the shared filter cannot pass by
# fixing one event and breaking another.
check "pull_request doc-only"       pull_request "$BASE" "$DOC"     false
check "pull_request code"           pull_request "$BASE" "$CODE"    true
check "pull_request docs/examples"  pull_request "$BASE" "$EXAMPLE" true
check "push doc-only"               push         "$BASE" "$DOC"     false
check "push code"                   push         "$BASE" "$CODE"    true
check "workflow_dispatch"           workflow_dispatch "" ""         true

if [ "$fails" -gt 0 ]; then
  echo "[check_ci_changes_detect] $fails of $cases case(s) disagree with the step in $WF" >&2
  [ "$MODE" = "--gate" ] && exit 1
  exit 0
fi
echo "[check_ci_changes_detect] OK ($cases cases)" >&2
