#!/usr/bin/env bash
# changelog_assemble.sh — fold changelog.d/ into a dated CHANGELOG section (ADR-0234).
#
# Inserts `## [<version>] - <date>` directly under `## [Unreleased]`, one
# `### <Section>` per section that has fragments (Keep a Changelog's order),
# fragments in file-name order within it, then `git rm`s the fragments used.
# Run by `.github/workflows/release_prep.yml`.
#
#   bash scripts/changelog_assemble.sh X.Y.Z YYYY-MM-DD            # rewrite + git rm
#   bash scripts/changelog_assemble.sh --dry-run X.Y.Z YYYY-MM-DD  # print the section, change nothing
#
# Exits 1, changing nothing, when there is no fragment, a fragment's name
# starts with no known section, the version is already in the CHANGELOG, or
# `[Unreleased]` still holds entries: inserted above them, they would read as
# part of the new section's last heading.
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."

die() { echo "[changelog_assemble] $*" >&2; exit 1; }

DRY=false
if [ "${1:-}" = "--dry-run" ]; then DRY=true; shift; fi
[ $# -eq 2 ] || die "usage: $0 [--dry-run] <X.Y.Z> <YYYY-MM-DD>"
VERSION=$1
DATE=$2
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z, got '$VERSION'"
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "date must be YYYY-MM-DD, got '$DATE'"

# <file-name prefix>:<heading>, in the order the section prints them.
SECTIONS=(added:Added changed:Changed deprecated:Deprecated removed:Removed
          fixed:Fixed security:Security documentation:Documentation
          "known-limitations:Known limitations")

used=()
for f in changelog.d/*.md; do
  [ -e "$f" ] || continue
  name=${f#changelog.d/}
  [ "$name" = README.md ] && continue
  known=false
  for s in "${SECTIONS[@]}"; do
    case $name in "${s%%:*}"-?*.md) known=true ;; esac
  done
  $known || die "$f: the name must be <section>-<slug>.md, <section> one of: ${SECTIONS[*]%%:*}"
  used+=("$f")
done
[ ${#used[@]} -gt 0 ] || die "no fragment in changelog.d/ — nothing to release"

grep -qxF '## [Unreleased]' CHANGELOG.md || die "CHANGELOG.md has no '## [Unreleased]' line"
grep -qF "## [$VERSION]" CHANGELOG.md && die "CHANGELOG.md already has a [$VERSION] section"
pending=$(awk '$0 == "## [Unreleased]" { in_u = 1; next } in_u && /^## / { exit } in_u && NF' CHANGELOG.md)
[ -z "$pending" ] || die "[Unreleased] still holds entries; move them to changelog.d/ first"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A fragment's own leading and trailing blank lines are dropped, so the blank
# line between entries is the only one.
trim() { awk '{ l[NR] = $0 } NF { if (!s) s = NR; e = NR } END { for (i = s; s && i <= e; i++) print l[i] }' "$1"; }

{
  printf '## [%s] - %s\n' "$VERSION" "$DATE"
  for s in "${SECTIONS[@]}"; do
    heading_done=false
    for f in "${used[@]}"; do
      case ${f#changelog.d/} in "${s%%:*}"-*) ;; *) continue ;; esac
      $heading_done || { printf '\n### %s\n' "${s#*:}"; heading_done=true; }
      printf '\n'
      trim "$f"
    done
  done
} > "$TMP/section"

if $DRY; then
  cat "$TMP/section"
  exit 0
fi

# The file, not awk -v, carries the section: -v would expand backslashes in it.
awk -v section="$TMP/section" '
  skip && !NF { next }
  skip { print ""; skip = 0 }
  { print }
  !done && $0 == "## [Unreleased]" {
    print ""
    while ((getline l < section) > 0) print l
    done = 1; skip = 1
  }
' CHANGELOG.md > "$TMP/changelog"
cat "$TMP/changelog" > CHANGELOG.md
git rm -q -- "${used[@]}"
