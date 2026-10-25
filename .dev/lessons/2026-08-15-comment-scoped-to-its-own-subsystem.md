# A source comment is authoritative about its own subsystem, not about the system

**Date**: 2026-08-15
**Keywords**: D-586, comment true locally false globally, grep for the MECHANISM
not for the absence, patchTableImportFuncptrs existed unfound, one-line fix

**Citing**: `e1e6925ab` (D-586 fix — the one-line funcptr mirror assignment)

## What happened

D-586's investigation read `setup.zig`'s comment — "the JIT call_indirect path
doesn't emit that trampoline" — and built the fix around it: trap on the null
funcptr, and record the real fix as separate codegen work. The comment was true;
the conclusion drawn from it was not. A bridge thunk was already in scope at
that line (`func_entities[fidx].funcptr` = the `dispatch[fidx]` that
`jitTableGrowCore` copies on `table.set`), plus a `patchTableImportFuncptrs`
helper written to discharge this SEGV. One line took the 3.0 lane 277 → 1.

## Root cause

The comment scoped a claim to the JIT's emit path; the question being asked was
whether a trampoline was reachable *anywhere* — these differ whenever the
capability lives in a sibling subsystem. Nothing searched for the mechanism by
name; the search was for the absence the comment described, which the code
confirmed. The comment was then rewritten twice, premise untested.

## Fix (or path forward)

No fix — a search habit: when a comment states an absence that bounds the work,
grep `src/` for the *mechanism*, not for the absence the comment names. The
tell is a comment whose subject is one subsystem and whose consequence spans
several.

## Why this didn't surface earlier

Both suites agreed with the wrong model — the tests pinned "traps instead of
dying", which the interim fix satisfied. An adversarial self-review missed it
too: it verified the fix against the stated problem, not the re-derived one.

## Re-derivability

Not re-derivable — the code reads as consistent and the comment as
authoritative; only the outcome (277 → 1) shows a cheaper fix was in scope.

## Related

- D-586 — its earlier revision asserted the trampoline was separate codegen work.
- Same session, same root: the `return_call_indirect` sites were missed by
  trusting a self-authored enumeration instead of re-deriving it.
- `.claude/rules/extended_challenge.md` Step 1 — confirming the absence a comment
  names is not confirming the absence that matters.
