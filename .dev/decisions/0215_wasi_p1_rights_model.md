# 0215 — Enforce preview1 rights, and advertise the corpus minimum plus one bit

- **Status**: Accepted (2026-08-23 — maintainer sign-off on PR #251; product
  semantics per ADR-0212 D1)
- **Date**: 2026-08-23
- **Author**: jtakakura
- **Tags**: wasi, product-semantics, conformance

## Context

`src/wasi/` carried WASI preview1 `rights` without implementing them. Three
measurements at `9d74fba80`:

- `preview1.zig` defined **5** of the witx `$rights` record's **30** flags.
- `Host.addPreopen` advertised `PATH_OPEN | FD_READ` as `fs_rights_base`.
- Of the 31 `pub fn` in `fd.zig`, **none** read `rights_base`. The only
  enforcement anywhere was the narrowing check inside
  `fd_fdstat_set_rights` — i.e. rights could be dropped, and dropping them
  changed nothing.

Six of the fourteen official-corpus failures (#204, D-583) are that gap.

The reference host does not settle the question. wasmtime 47.0.3, measured
with hand-written WAT probes rather than read from its source:

| Probe | wasmtime 47.0.3 |
|---|---|
| preopen `fs_rights_base` / `_inheriting` | `0x07B7FE00` / `0x0FF7FFFF` |
| `fd_fdstat_set_rights(fd, current, current)` | `notsup` |
| `fd_filestat_get(stdout)` — rights are `FD_WRITE` alone | `success` |
| the 12 gated calls against stdio | type errors (`spipe` / `badf`), never `notcapable` |

So wasmtime advertises a canned per-filetype set and enforces nothing;
`fd_fdstat_set_rights` answering `notsup` is what makes the corpus's
`supports_rights()` probe return false and its rights test skip its own body.

Rights defaults and enforcement are product semantics, so per
[ADR-0212](0212_maintenance_mode_authority.md) D1 they need maintainer
sign-off. This ADR is that record. It is a new design decision, not a
correction of a ROADMAP inconsistency, so §18.1 puts it here rather than in
an in-place amendment.

## Decision

**D1 — Rights are enforced, not merely advertised.** Every preview1 entry
point checks the right its flag's witx doc comment names. zwasm's accepted
set is therefore *narrower* than wasmtime's, deliberately. Rights that are
carried, reported through `fd_fdstat_get`, and narrowable through
`fd_fdstat_set_rights`, but never read, are not a compatibility choice — they
are an unimplemented feature that reports itself as implemented.

**D2 — A preopen advertises the corpus minimum plus `PATH_FILESTAT_SET_SIZE`.**

```
RIGHTS_DIRECTORY_BASE        = 0x07BFFE00   17 bits
RIGHTS_DIRECTORY_INHERITING  = 0x0FFFFFFF   28 bits (all but the two sock_* bits)
```

Base is wasmtime's measured `0x07B7FE00` — itself exactly the set
`path_open_preopen.rs` hardcodes — plus bit 19. Inheriting is wasmtime's
`0x0FF7FFFF` plus the same bit, which rounds it to "every bit except the
socket ones"; a filesystem preopen has no socket capability to hand down.

The extra bit is what makes `truncation_rights` execute. Without it the test
takes its `implementation doesn't support setting file sizes, skipping`
branch — which is how wasmtime passes it. A test that skips its own body and
reports green is a hollow gate, and the project already has enough of those
to be wary of adding one.

**D3 — Rights are checked AFTER the fd-type dispatch.** The fd's type decides
whether the operation exists at all (`spipe` for a stream, `isdir` for a
directory, `notdir` for a file); only then does the capability decide whether
this fd may perform it. Chosen from the fourth measurement above: every gated
call against stdio answers with a type error under wasmtime, and putting the
capability check first would replace all of them with `notcapable`.

**D4 — The errno is `notcapable`.** witx added it for exactly this
("Extension: Capabilities insufficient"). The corpus accepts a *set* at each
site rather than one value, and `notcapable` is the only member common to all
five: `{badf, notcapable}`, `{badf, notcapable, acces}`, `{isdir, notcapable,
badf}`, `{perm, notcapable}`, `{perm, notcapable}`. One value everywhere is
the property worth having.

**D5 — Three rows stay ungated, with reasons recorded.**
`poll_fd_readwrite` (fd-readiness polling is `notsup` in `clocks.zig`, so
there is nothing to gate); `sock_shutdown` / `sock_accept` (the preview1
socket entry points are stubs answering `notsock` for every fd, and the
corpus asserts that); and the `fdflags` clauses witx attaches to
`fd_datasync` / `fd_sync` (zwasm's `fdflags` handling is itself incomplete —
`fd_flags_set` is still a corpus failure — so gating on a half-modelled flag
narrows acceptance without a test that asks for it).

**D6 — A caller with no rights model asks through one helper.** WASI 0.2/0.3
`open-at` has no rights concept: the preopen IS its sandbox. Both trampolines
route through `p1.rightsForRightlessOpen(oflags)`, which returns a `base`
masked by filetype for a directory target and an `inheriting` that is
**never** masked. The two-call-site duplication that preceded the helper
produced exactly one defect (external review, 2026-08-23): masking
`inheriting` too recorded a ceiling without `FD_WRITE`, so every file opened
under a component-opened subdirectory was clamped to unwritable and answered
`notcapable`.

The normative table — which right gates which call, with its witx citation —
lives in [`.dev/wasi_p1_rights.md`](../wasi_p1_rights.md).

## Alternatives considered

### Alternative A — wasmtime parity: advertise, do not enforce

- **Sketch**: implement the constant table and the canned per-filetype
  advertised sets; make `fd_fdstat_set_rights` return `notsup`; check nothing.
  All five rights tests go green, `fd_fdstat_set_rights` by skipping.
- **Why rejected**: it deletes a capability zwasm already has (real narrowing)
  to match a host that never implemented one, and it buys two of the five
  greens by having the test decline to run. ROADMAP §1.2's bar is 100% spec,
  and the spec states the gate table normatively.

### Alternative B — wasmtime's preopen set exactly

- **Sketch**: `0x07B7FE00` / `0x0FF7FFFF`, no extra bit.
- **Why rejected**: `truncation_rights` then skips its body. Bit-identical
  agreement with the reference host is worth less than a test that asserts
  something. Recorded rather than dropped, because it is the option to revert
  to if a real guest is ever found that depends on the narrower set.

### Alternative C — check rights before the fd-type dispatch

- **Sketch**: capability first, uniformly: `if (!slot.has(r)) return .notcapable`
  immediately after `translateFd`.
- **Why rejected**: measured to change eleven existing expectations at once —
  `fd_pread(stdin)` `spipe` → `notcapable`, `fd_advise(stdout)` `spipe` →
  `notcapable`, `fd_filestat_get(stdout)` `success` → `notcapable`, and so on.
  wasmtime reports the type error for every one. The alternative repair —
  widening the stdio rights until the type arms become reachable again — makes
  a character device advertise `FD_ADVISE` and `FD_FILESTAT_SET_TIMES` to keep
  a code path alive, which is a worse lie than the ordering fixes.

### Alternative D — `notcapable` when a request exceeds the parent's inheriting set

- **Sketch**: `path_open` errors instead of silently clamping, as the historic
  `wasi-common` did.
- **Why rejected**: the corpus's own `create_tmp_dir` helper requests
  `PATH_FILESTAT_SET_SIZE` in `base` and `.expect()`s success, so erroring
  fails four tests outright. witx also sanctions the clamp: the host "is
  allowed to return a file descriptor with fewer rights than specified".

## Consequences

- **Positive**: `test-wasi-p1-official` interp 58 → 64, jit 54 → 60. The
  rights bits a guest reads back through `fd_fdstat_get` now describe what it
  can actually do, which is what `fd_fdstat_set_rights` was always promising.
- **Negative**: zwasm accepts strictly less than wasmtime does. A guest that
  opens a file with `fs_rights_base = 0` and then reads it works there and
  gets `notcapable` here. No such guest exists in `test/realworld/` (57
  fixtures), `test/wasi/`, or the spec suites — measured, `test-all` green —
  but the exposure is real and this is the row to revisit if one appears.
- **Negative**: the WASI 0.2/0.3 `open-at` trampolines now depend on a
  preview1 concept they do not model. D6's helper keeps that dependency in one
  place; a P2-native descriptor table would remove it entirely, and is not
  scheduled. The nearest consequence is tracked as #254: both trampolines ask
  for `FD_WRITE` unconditionally, so a read-only host file cannot be opened
  through `open-at`. That predates this ADR — `9d74fba80` passed
  `RIGHTS_FD_READ | RIGHTS_FD_WRITE` and discarded `descriptor-flags` — and
  the helper neither causes nor fixes it.
- **Neutral / follow-ups**:
  - ROADMAP §9 row 11.1 quotes "58/72 on the interpreter". Refresh it to 64/72
    when the last of the three PRs lands, not before — the number must be true
    on `main`. Routine per §18.3a (it does not change what closes the row).
  - D-583 keeps the remaining 8: symlink 2, readdir 1, fdflags 2, fd
    management 2, poll 1. None are rights.
  - `path.normalize` (the `..` fold) ships alongside but is path resolution,
    not rights, and carries no decision this ADR needs to hold.

## References

- ROADMAP §1.2 (correctness floors), §9 row 11.1, §18.1 (ADR vs amendment)
- Related ADRs: [0212](0212_maintenance_mode_authority.md) D1 (sign-off scope
  for product semantics), [0208](0208_wasip1_official_corpus.md) (the corpus
  and its runner), [0156](0156_endgame_no_autonomous_release_completion_gated.md) (release + surface authority)
- Table + citations: [`.dev/wasi_p1_rights.md`](../wasi_p1_rights.md)
- witx: `WebAssembly/WASI`, branch `wasi-0.1`,
  `fae981bae14809d91f9bc2d63852d461f331d161`,
  `preview1/witx/typenames.witx` + `preview1/docs.md`
- Corpus sources read at `52aa5d73cb06eab3461d0939eae43423fe49c0b5` (the pin
  in `scripts/vendor_wasip1_official.sh`)
- Debt: D-583 (the 14 official-corpus failures), D-315 (follow-time symlink
  confinement, untouched)

## Revision history

| Date       | SHA          | Note                                                              |
|------------|--------------|-------------------------------------------------------------------|
| 2026-08-24 | `5058d517f`  | Initial version, maintainer sign-off and the #254 reference — the branch was squashed, so all three reached `main` in one commit. |
