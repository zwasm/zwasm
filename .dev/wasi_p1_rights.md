# WASI preview1 rights — the gate table

> **Doc-state**: ACTIVE — normative for `src/wasi/`. Conflicts with the code
> are bugs in the code.

Which `rights` bit gates which preview1 call, what a preopen advertises, and
which decisions here are ours rather than the spec's. The decisions and the
alternatives they beat are recorded in
[ADR-0215](decisions/0215_wasi_p1_rights_model.md); this file is the table
they operate on.

> **Implementation status.** The model lands in three changes and this file
> describes all of it, so parts of it lead the code. Advertising the table and
> deriving rights onto opened fds, reading a right at each call, and folding
> `..` (`path.normalize`): all **landed**.

## Sources

| What | Where | Pin |
|---|---|---|
| The 30 `rights` bits + their gate wording | `WebAssembly/WASI` `preview1/witx/typenames.witx` | branch `wasi-0.1`, `fae981bae14809d91f9bc2d63852d461f331d161` |
| Rendered bit numbers (`Bit: N`) | same tree, `preview1/docs.md` | same |
| `path_open` rights parameters | same tree, `preview1/witx/wasi_snapshot_preview1.witx` | same |
| The rights a guest is entitled to see on a preopen | `WebAssembly/wasi-testsuite` `tests/rust/wasm32-wasip1/src/bin/path_open_preopen.rs`, `directory_base_rights()` / `directory_inheriting_rights()` | `52aa5d73cb06eab3461d0939eae43423fe49c0b5` (the corpus pin in `scripts/vendor_wasip1_official.sh`) |
| Reference host behaviour | wasmtime 47.0.3, measured — see "Measured, not assumed" below | — |

witx has no per-function rights annotation: the gate wording lives in each
flag's doc comment ("The right to invoke `X`"). The table below is that
wording, transposed.

## The table

Bit N = `1 << N`, in witx declaration order.

| Bit | Right | Gates | zwasm entry point |
|---:|---|---|---|
| 0 | `fd_datasync` | `fd_datasync`; `path_open` with `fdflags::dsync` | `fd.fdDatasync` |
| 1 | `fd_read` | `fd_read`, `sock_recv`; `fd_pread` when `fd_seek` is also held | `fd.fdRead`, `fd.fdPread` |
| 2 | `fd_seek` | `fd_seek`; witx says it "implies `rights::fd_tell`", so it also answers for `fd_tell` and for `fd_seek(cur, 0)` | `fd.fdSeek`, `fd.fdTell`, `fd.fdPread`, `fd.fdPwrite` |
| 3 | `fd_fdstat_set_flags` | `fd_fdstat_set_flags` | `fd.fdFdstatSetFlags` |
| 4 | `fd_sync` | `fd_sync`; `path_open` with `fdflags::rsync`/`dsync` | `fd.fdSync` |
| 5 | `fd_tell` | `fd_tell`, and `fd_seek(cur, 0)` | `fd.fdTell`, `fd.fdSeek` |
| 6 | `fd_write` | `fd_write`, `sock_send`; `fd_pwrite` when `fd_seek` is also held | `fd.writeSlice`, `fd.fdPwrite` |
| 7 | `fd_advise` | `fd_advise` | `fd.fdAdvise` |
| 8 | `fd_allocate` | `fd_allocate` | `fd.fdAllocate` |
| 9 | `path_create_directory` | `path_create_directory` | `path.pathCreateDirectory` |
| 10 | `path_create_file` | `path_open` with `oflags::creat` | `fd.pathOpen` |
| 11 | `path_link_source` | `path_link`, source dirfd | `path.pathLink` |
| 12 | `path_link_target` | `path_link`, target dirfd | `path.pathLink` |
| 13 | `path_open` | `path_open` | `fd.pathOpen` |
| 14 | `fd_readdir` | `fd_readdir` | `fd.fdReaddir` |
| 15 | `path_readlink` | `path_readlink` | `path.pathReadlink` |
| 16 | `path_rename_source` | `path_rename`, source dirfd | `path.pathRename` |
| 17 | `path_rename_target` | `path_rename`, target dirfd | `path.pathRename` |
| 18 | `path_filestat_get` | `path_filestat_get` | `path.pathFilestatGet` |
| 19 | `path_filestat_set_size` | `path_open` with `oflags::trunc` (witx: "the right to change a file's size"; there is no `path_filestat_set_size` call) | `fd.pathOpen` |
| 20 | `path_filestat_set_times` | `path_filestat_set_times` | `path.pathFilestatSetTimes` |
| 21 | `fd_filestat_get` | `fd_filestat_get` | `fd.fdFilestatGet` |
| 22 | `fd_filestat_set_size` | `fd_filestat_set_size` | `fd.fdFilestatSetSize` |
| 23 | `fd_filestat_set_times` | `fd_filestat_set_times` | `fd.fdFilestatSetTimes` |
| 24 | `path_symlink` | `path_symlink` | `path.pathSymlink` |
| 25 | `path_remove_directory` | `path_remove_directory` | `path.pathRemoveDirectory` |
| 26 | `path_unlink_file` | `path_unlink_file` | `fd.pathUnlinkFile` |
| 27 | `poll_fd_readwrite` | `poll_oneoff` subscriptions to `fd_read`/`fd_write` | — (not modelled; see below) |
| 28 | `sock_shutdown` | `sock_shutdown` | — (not gated; see below) |
| 29 | `sock_accept` | `sock_accept` | — (not gated; see below) |

Ungated by design, because witx assigns them no bit: `fd_close`,
`fd_renumber`, `fd_fdstat_get`, `fd_fdstat_set_rights`, `fd_prestat_get`,
`fd_prestat_dir_name`, `args_*`, `environ_*`, `clock_*`, `random_get`,
`proc_*`, `sched_yield`.

### Where the check sits

The rights check runs **after** the fd-type dispatch, never before. The fd's
type decides whether the operation exists at all — `spipe` for a stream,
`isdir` for a directory, `notdir` for a file — and only then does the
capability decide whether this fd may perform it.

This is measured, not stylistic. Under wasmtime 47.0.3 every one of the twelve
gated calls against stdio answers with a type error and none with a capability
error: `fd_pread(stdin)` → `spipe`, `fd_advise(stdout)` → `badf`,
`fd_filestat_get(stdout)` → `success`, `fd_seek(stdin, cur, 0)` → `spipe`.
Checking rights first turns all of those into `notcapable`, which no guest and
no test expects.

Two consequences worth naming:

- `fd_filestat_get` and `fd_fdstat_set_flags` on a stdio fd answer from the
  type arm without a rights check. A stdio stream's filestat is synthetic, not
  a capability held over a filesystem object.
- `fd_seek` on a directory is `isdir`, not `notcapable` — the type arm reaches
  it first. Both are answers `directory_seek` accepts; `notsup`, which this
  used to give, is not.

Three rows stay ungated even once the checks land:

- **`poll_fd_readwrite`** — `poll_oneoff` fd-readiness is `notsup` in zwasm
  (`clocks.zig`), so there is nothing to gate. It becomes live with that work.
- **`sock_shutdown` / `sock_accept`** — preview1 sockets are stubs that return
  `notsock` for every fd, and the official corpus asserts exactly that
  (`sock_shutdown-not_sock`). A rights check would answer `notcapable` to a
  question that is not about capability.
- **`fd_datasync` / `fd_sync` on `path_open`'s `fdflags`** — the witx wording
  ties these to `fdflags::dsync`/`rsync`, but zwasm's `fdflags` handling is
  itself incomplete (`fd_flags_set` is a known corpus failure). Gating on a
  half-modelled flag narrows acceptance without a test that asks for it.

## What a preopen advertises

```
RIGHTS_DIRECTORY_BASE        = 0x07BFFE00   17 bits
RIGHTS_DIRECTORY_INHERITING  = 0x0FFFFFFF   28 bits (everything but the two sock_* bits)
```

`RIGHTS_DIRECTORY_BASE` is what a guest may do *through the directory fd
itself*: the `path_*` operations plus `fd_readdir`, `fd_filestat_get` and
`fd_filestat_set_times`. No `fd_read`/`fd_write`/`fd_seek` — those name file
content, and a directory has none.

`RIGHTS_DIRECTORY_INHERITING` is the ceiling on every fd derived from it. A
filesystem preopen never hands out socket capabilities, so it is every bit
except `sock_shutdown` and `sock_accept`.

### Measured, not assumed

wasmtime 47.0.3, `--dir=root::/`, read back by the guest through
`fd_fdstat_get(3)`:

```
base 129498624 = 0x07B7FE00      inheriting 267911167 = 0x0FF7FFFF
```

That is *exactly* `directory_base_rights()` / `directory_inheriting_rights()`
from `path_open_preopen.rs` — the reference host advertises the corpus
minimum and nothing more.

zwasm differs from it in **one bit, deliberately**: `path_filestat_set_size`
(bit 19) is present in both our sets. Consequence: `truncation_rights` runs
its real branch instead of the `implementation doesn't support setting file
sizes, skipping` branch that wasmtime takes. A green test that skipped its own
body would be a hollow gate.

Also measured, and deliberately *not* copied:

- wasmtime answers `fd_fdstat_set_rights` with `notsup`, which makes the
  corpus's `supports_rights()` probe return false and `fd_fdstat_set_rights`
  skip entirely. zwasm implements the narrowing for real.
- wasmtime enforces no rights at all at call time — `fd_filestat_get(stdout)`
  succeeds on an fd whose advertised rights are `fd_write` alone. zwasm
  enforces, so its accepted set is *narrower* than wasmtime's.

## Rights on a `path_open`ed fd

Two clamps, both from the witx `path_open` prose:

1. `base &= parent.fs_rights_inheriting`, `inheriting &= parent.fs_rights_inheriting`
   — "the *inheriting* rights are rights that apply to file descriptors
   derived from it". Silent, not an error: witx also says the host "is allowed
   to return a file descriptor with fewer rights than specified".
2. For a directory target, `base &= RIGHTS_DIRECTORY_APPLICABLE`
   (`= ~(fd_seek | fd_write | fd_filestat_set_size)`) — "if and only if those
   rights do not apply to the type of file being opened". This is what makes
   `directory_seek` see `fs_rights_base & RIGHTS_FD_SEEK == 0` after asking
   for `RIGHTS_FD_SEEK`.

`oflags::trunc` forces a writable host handle regardless of the requested
rights, because the open must resize the file. A truncate-open of a file the
process cannot write is therefore `acces`, from the open itself. It used to be
`inval`, raised by `ftruncate` on a read-only handle one step later — an
artifact of doing the truncate in two parts, and the reason `truncation_rights`
was red. wasmtime 47.0.3 answers `acces` too (measured).

Asking for `fd_write` on a directory is not a clamp but an error: `isdir`.
`path_open_preopen` requires it, and wasmtime agrees.

The rule is scoped to `OFLAGS_DIRECTORY`. A write-rights open of a directory
*without* that flag keeps zwasm's existing fallback to a directory open —
wasmtime answers `isdir` there too, but no test pins it, and the fallback is
load-bearing for POSIX-style guests (Go's `os.Open` before `ReadDir`, and the
WASI 0.2 `open-at` trampoline).

### Callers with no rights model

WASI 0.2/0.3 `open-at` has no rights concept — the preopen IS its sandbox — so
both trampolines ask through `p1.rightsForRightlessOpen(oflags)`. It returns a
`base` masked by filetype for a directory target and an `inheriting` that is
**never** masked. Masking the ceiling as well records a directory that cannot
hand `FD_WRITE` down, and every file opened under it is then clamped to
unwritable (ADR-0215 D6).

## Which errno

`notcapable` (76) — "Extension: Capabilities insufficient", the errno witx
added for exactly this. The corpus accepts a set at each site rather than one
value, and `notcapable` is in every one of them:

| Test | Accepts |
|---|---|
| `fd_fdstat_set_rights` | `badf`, `notcapable` |
| `path_open_read_write` | `badf`, `notcapable`, `acces` |
| `directory_seek` | `isdir`, `notcapable`, `badf` |
| `truncation_rights` | `perm`, `notcapable` |
| `interesting_paths` (escape) | `perm`, `notcapable` |

One value everywhere is the property worth having; `notcapable` is the only
candidate that satisfies all five.

## `..` is path resolution, not rights

`interesting_paths` clusters with the rights failures only because the old
code answered `notcapable` for it. It is a separate rule: a preview1 path is
confined to its preopen, but `..` is not itself the violation — a path that
dips through `..` and comes back stays inside and must resolve. Only an
absolute path, or one whose `..` ascends past the root, escapes.

One `path.normalize` folds the path lexically and
answers `notcapable` only when the fold would leave the root. A trailing
separator is preserved, because POSIX reads `x/` as "x, which must be a
directory" and the host syscalls already enforce that. The fold is lexical, so
`a/b/..` does not verify that `a/b` exists — the trade-off `path.Clean` makes,
and the reason follow-time symlink confinement (D-315) remains a separate,
still-open problem.
