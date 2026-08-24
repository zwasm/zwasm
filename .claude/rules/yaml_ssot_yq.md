---
description: "debt.yaml (+ any .dev YAML SSOT) query/edit discipline — mikefarah Go yq v4 idioms: single-quote the expression, pass shell vars via env(), `yq -i` preserves block scalars + comments. Migrated from debt.md per D-227 / ADR-0129."
paths:
  - ".dev/debt.yaml"
---

# YAML SSOT + `yq` cookbook

## Invariant

`.dev/debt.yaml` is the technical-debt SSOT (was `debt.md`; D-227 / ADR-0129).
Query + edit it with **mikefarah Go `yq` v4** (NOT python-yq / jq). Schema:

```yaml
entries:
  - id: "D-NNN"
    layer: "code"            # or "" for compact historical notes
    status: "now"            # now | blocked-by | resolved | partial | note
    description: |-          # full body (block scalar; the blocked-by barrier lives here)
      ...
    first_raised: "YYYY-MM-DD"
    last_reviewed: "YYYY-MM-DD"   # "" if never reviewed
    refs: |-                 # file:line / ADR § / skill path  ("" if none)
      ...
conventions: |-              # the ledger's own discipline + how-to-read + promotion-to-ADR
  ...
```

`status` is a **derived classifier** (the original Status prose, incl. the
`blocked-by:` barrier predicate, is preserved verbatim at the head of
`description`). Discipline (delete-on-discharge, blocked-by predicate
mandatory, staleness sweep) is unchanged — it lives in `.conventions`.

## Shell-quoting rule (the whole trick)

1. **Single-quote the entire `yq` expression** — neutralises `| [] * ? . " ==`.
2. **Pass shell variables via `env(VAR)`, never string interpolation.**
3. `yq -i` (in-place) **preserves `|-` block scalars + comments** (v4.53.2 verified).

## Canonical queries

```sh
yq -r '.entries | length' .dev/debt.yaml                          # count
yq -r '.entries[].id' .dev/debt.yaml                              # all IDs
yq -r '.entries[] | select(.status == "now") | .id' .dev/debt.yaml          # discharge candidates
yq -r '.entries[] | select(.status == "blocked-by") | .id + "  " + .last_reviewed' .dev/debt.yaml  # staleness sweep
DROW="D-201" yq -r '.entries[] | select(.id == env(DROW)) | .description' .dev/debt.yaml   # one body
yq -r '.entries[] | select(.status == "resolved" or .status == "note") | .id' .dev/debt.yaml  # deletable (git retains)
# NEXT ID — grep the WHOLE repo, NOT just debt.yaml. Resolved rows are DELETED
# from debt.yaml but their src/.dev citations remain; reusing a deleted number
# collides with those dangling citations (2026-06-15: D-324/325/326 reused →
# clashed with validator / cross-instance-call_indirect / REQ-7; renumbered to
# D-329/330/331). The true max = max CITED anywhere, not max in debt.yaml.
grep -rhoE 'D-[0-9]+' src/ .dev/ include/ test/ scripts/ | sort -t- -k2 -n -u | tail -1  # true max → next is +1
```

## Edit workflow (AI agent)

- **Add**: dedup first (`rg -n '<keyword>' .dev/debt.yaml`); update the existing
  entry if the class overlaps, else append a new `- id:` block under `entries:`
  with the next ID. Use the **Edit/Write tool** for new multi-line `description`
  prose (NOT `yq -i` — block-scalar indent is exactly 4 spaces for the key,
  6 for the content).
- **Scalar flip** (status / last_reviewed): `yq -i` is safe —
  `DROW="D-NNN" yq -i '(.entries[] | select(.id == env(DROW)) | .last_reviewed) = "2026-06-02"' .dev/debt.yaml`
- **Discharge**: delete the entry (git log retains it via the discharge commit
  `chore(debt): close D-NNN <line>`) — `DROW="D-NNN" yq -i 'del(.entries[] | select(.id == env(DROW)))' .dev/debt.yaml`.

## Enforcement

`bash scripts/check_debt_yaml.sh [--gate]` (wired into `gate_commit.sh` when
debt.yaml is staged) — validates the ledger's own integrity: parse, required
fields, `status` enum, `blocked-by` ⇒ `last_reviewed`, unique IDs, and flags
phantom `D-NEW*` placeholders. It does NOT resolve every cited `D-NNN` (resolved
debts are deleted here by design — git is the archive). Block scalars +
indentation are validated by `yq` parsing (a malformed entry makes every query
error).

## Top traps

- **yq flavor**: must be mikefarah Go v4 (`yq --version` → `v4.x`). jq/python-yq
  syntax differs.
- **Empty cell**: never emit a bare `key: |-` with no content (parses as null) —
  use `key: ""`.
- **Block-scalar indent**: content is exactly 2 spaces deeper than its key; drift
  = parse failure. Use the Edit tool, mirror an existing entry's indent.

## Rotting values

**A measured value does not go in a row.** The row carries the claim; a
re-derivation command carries the evidence — `zig build test-wasi-p1-official`,
not `58/72`. A value that must be written carries its measurement date and SHA
(`measured 2026-08-24 on 5058d517f`).

Measured 2026-08-24: 28 of 89 rows held a rotting number, and most of the 11
corrections in the never-reviewed sweep (#273) were replacing one.

