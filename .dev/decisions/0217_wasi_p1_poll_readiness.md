# 0217 — preview1 fd-readiness is answered from the Host's own IO model, not an OS event source

- **Status**: Proposed (2026-08-25)
- **Date**: 2026-08-25
- **Author**: jtakakura
- **Tags**: wasi, preview1, poll, platform

## Context

`poll_oneoff` answered `notsup` to every `fd_read` / `fd_write` subscription,
which held the official wasi-testsuite corpus at 71/72 (#263). The file said
so itself: "fd-readiness polling are not yet modelled".

The premise carried by #263 was that closing it needs a per-OS readiness
source — `epoll` on Linux, `kqueue` on macOS, and on Windows the undocumented
`AFD` / `NtDeviceIoControlFile` surface, because `WaitForMultipleObjects` does
not cover a pipe the way `poll(2)` does. zwasm gates on all three OSes
(ADR-0076 D9), so that framing makes the work a platform project whose CI risk
is concentrated where nothing else in `src/wasi/` reaches.

Two things measured on 2026-08-25 at `286a91f89` say the premise does not
hold here.

**Nothing in this Host blocks.** Every preview1 IO path is synchronous:
`fd_read` over stdin copies out of `host.stdin_bytes` or reports EOF,
`fd_write` appends to a capture buffer or hands bytes to the process stream,
and a `.file` read or write is a positional syscall. `FdKind` holds exactly
`stdin` / `stdout` / `stderr` / `file` / `dir` / `closed` — no socket, no
pipe, nothing with a kernel-side wait queue.

**The reference implementation does not use one either.** Read at wasmtime
`main` (`5f229d9f5cb`): nothing reachable from its preview1 `poll_oneoff`
registers an fd with epoll/kqueue/IOCP. `stdout` / `stderr` are unconditionally
ready (`async fn ready(&mut self) {}`), files resolve through a blocking pool,
stdin is a worker thread gated on a condvar, and socket subscriptions are
rejected outright. Its mio-backed readiness machinery only serves sockets,
which preview1 never reaches.

There is also a readiness layer already in this repository —
`p2_sockets.zig`'s `pollOnce` / `afdPollOnce`, from the ADR-0180 sockets work.
It is not a candidate: `afdPollOnce` issues its ioctl against the polled
handle itself, which only reaches `\Device\Afd` endpoints, and the preview1 fd
table holds no sockets to point it at.

## Decision

**A valid fd subscription is ready immediately, because "ready" means "the
matching call will not block" and in this Host that is true by construction.**
`poll_oneoff` reports readiness from the fd table directly. No OS event source
is introduced, and the implementation is identical on all three OSes.

Three consequences are part of the decision, not incidental:

- **EOF is reported, not hidden.** A read that is ready with nothing left
  answers `nbytes = 0` plus `FD_READWRITE_HANGUP`. Without that bit a guest
  looping "poll until readable, then read" spins forever — and zwasm's stdin
  is permanently at EOF today, so the spin is the default case rather than an
  edge one.
- **A ready fd suppresses the clock event.** A guest that pairs fd
  subscriptions with a timeout reads a returned clock event as "the timeout
  won".
- **`RIGHTS_POLL_FD_READWRITE` becomes live**, and stdio carries it. It was
  the last row `.dev/wasi_p1_rights.md` listed as ungated for want of an
  implementation.

**This decision is scoped to the Host as it stands.** It is a claim about
zwasm's IO model, not about fd-readiness in general, and it expires the moment
that model gains a blocking point.

## Alternatives rejected

**A per-OS readiness source (`epoll` / `kqueue` / AFD), as #263 framed it.**
Rejected because there is nothing for it to watch. Every descriptor the
preview1 table can hold is already non-blocking, so the syscall would be asked
which of two always-true conditions is true, and the answer could not differ
from the one computed directly. It would buy no behaviour and spend the
project's only concentrated Windows-NT risk surface outside the one place
(ADR-0180 sockets) that genuinely needs it.

**Reusing `p2_sockets.zig`'s poll layer.** Rejected on mechanism: the Windows
half only addresses `\Device\Afd` handles, and neither half has a subject —
preview1 has no socket `FdKind`. Reaching for it would mean inventing one.

**A wasmtime-style stdin worker thread.** Rejected as premature rather than
wrong. It is the right shape *once* stdin is a real process handle (#257), and
notably it is per-OS only in its inner read call — so adopting it later still
does not bring epoll/kqueue/AFD with it. Building it now would model a
blocking point that does not exist and would have to be justified by a
readiness question nothing can currently ask.

**Reporting a constant `nbytes: 1`, as wasmtime does.** Rejected as a
divergence worth taking. wasmtime computes the real byte count and uses it
only to decide `HANGUP`, writing `1` into the field regardless. witx defines
that field as "the number of bytes available for reading", we know it exactly
for both readable kinds, and reporting it costs nothing over computing it.

## Consequences

- The official preview1 corpus reaches 72/72 on both engines **on
  x86_64-linux**. It does **not** discharge D-583, whose condition is green on
  all three OSes: x86_64-windows carries the symlink / hardlink / readdir
  cluster tracked as #290, so the corpus stays advisory and out of `test-all`.
- `pollOneoff`'s doc comment states the invariant and points here. The comment
  is load-bearing: a reader who takes always-ready for a placeholder will
  either "fix" it toward an event loop or copy it somewhere it is false.
- **The premise is stated so it can be seen to break.** Giving stdin a real
  process handle (#257) creates the first blocking point in the table; at that
  point stdin — and only stdin — needs an actual readiness source, and this
  ADR is superseded in part. No other `FdKind` can acquire one.
- This does not touch WASI 0.2 / 0.3. `api/component_wasi_p2.zig`'s pollable
  is always-ready for a different and weaker reason — its sources genuinely
  can block — and remains a placeholder.

## References

- #263 — the issue, including the per-OS framing this ADR rejects.
- #204 — the corpus campaign this closes out.
- #290 — the Windows cluster that keeps the corpus advisory regardless.
- #257 — the change that would break the premise above.
- ADR-0180 — the sockets campaign that produced `p2_sockets.zig`'s poll layer.
- ADR-0215 / `.dev/wasi_p1_rights.md` — the rights model bit 27 now joins.
- ADR-0076 D9 — the 3-OS CI gate that made the platform framing load-bearing.
- wasmtime `main` `5f229d9f5cb`, `crates/wasi/src/p1.rs` +
  `crates/wasi/src/cli/{stdout.rs,worker_thread_stdin.rs}` — the reference
  behaviour measured above.
