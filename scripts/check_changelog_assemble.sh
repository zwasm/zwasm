#!/usr/bin/env bash
# check_changelog_assemble.sh — changelog_assemble.sh's section, exercised on fixtures.
#
# The section is assembled by a workflow at release time and first read in the
# release PR, so a fragment dropped or filed under the wrong heading would ship
# unless someone spots it there. This builds a throwaway tree and compares
# `--dry-run`'s output with the section it must print.
#
#   bash scripts/check_changelog_assemble.sh          # informational, exit 0
#   bash scripts/check_changelog_assemble.sh --gate   # exit 1 on any mismatch
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-info}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fails=0
cases=0
fail() { echo "[check_changelog_assemble] FAIL $*" >&2; fails=$((fails + 1)); }

# The script resolves changelog.d/ and CHANGELOG.md from its own location, so a
# copy under $TMP/t never reads the real ones.
T="$TMP/t"
fresh_tree() {
  rm -rf "$T"
  mkdir -p "$T/scripts" "$T/changelog.d"
  cp scripts/changelog_assemble.sh "$T/scripts/"
  printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- old\n' > "$T/CHANGELOG.md"
  printf '# changelog.d\n' > "$T/changelog.d/README.md"
  : > "$T/changelog.d/.gitkeep"
}

# Three sections, the last one last, two fragments in one of them, and blank
# lines a fragment's author left at either end.
cases=$((cases + 1))
fresh_tree
printf -- '- **Thing** (#3).\n' > "$T/changelog.d/added-thing.md"
printf -- '\n- **Zeta** (#2).\n\n\n' > "$T/changelog.d/fixed-zeta.md"
printf -- '- **Alpha** (#1). Body\n  line two.\n' > "$T/changelog.d/fixed-alpha.md"
printf -- '- **Limit** (#4).\n' > "$T/changelog.d/known-limitations-limit.md"
cat > "$TMP/want" <<'EOF'
## [9.9.9] - 2026-02-03

### Added

- **Thing** (#3).

### Fixed

- **Alpha** (#1). Body
  line two.

- **Zeta** (#2).

### Known limitations

- **Limit** (#4).
EOF
before=$(cd "$T" && find . -type f | sort | xargs cksum)
if ! bash "$T/scripts/changelog_assemble.sh" --dry-run 9.9.9 2026-02-03 > "$TMP/got" 2> "$TMP/err"; then
  fail "dry-run exited non-zero: $(cat "$TMP/err")"
elif ! diff -u "$TMP/want" "$TMP/got" > "$TMP/diff"; then
  fail "dry-run section differs from the expected one:"
  cat "$TMP/diff" >&2
fi
[ "$before" = "$(cd "$T" && find . -type f | sort | xargs cksum)" ] || fail "dry-run changed the tree"

# No fragment: an empty release is refused.
cases=$((cases + 1))
fresh_tree
if bash "$T/scripts/changelog_assemble.sh" --dry-run 9.9.9 2026-02-03 > /dev/null 2>&1; then
  fail "no fragment, yet the script exited 0"
fi

if [ "$fails" -gt 0 ]; then
  echo "[check_changelog_assemble] $fails of $cases case(s) failed" >&2
  [ "$MODE" = "--gate" ] && exit 1
  exit 0
fi
echo "[check_changelog_assemble] OK ($cases cases)" >&2
