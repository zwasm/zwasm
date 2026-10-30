# changelog.d

A PR's CHANGELOG entries live here until a release folds them into
`CHANGELOG.md` (`scripts/changelog_assemble.sh`, ADR-0234). A PR does not edit
`CHANGELOG.md` itself.

One file per entry, named `<section>-<slug>.md`. `<section>` is one of
`added`, `changed`, `deprecated`, `removed`, `fixed`, `security`,
`documentation`, `known-limitations`; the slug is free (the branch slug or the issue number reads
well). A PR with two entries adds two files.

The file holds the entry exactly as the CHANGELOG will show it:

```markdown
- **One bold sentence saying what changed for a user** (#N). At most four
  lines of body: what was wrong or missing, and what is true now.
```

The release lists each section's entries in file-name order.
