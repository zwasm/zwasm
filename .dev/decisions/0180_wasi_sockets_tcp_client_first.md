# ADR-0180 — wasi:sockets: TCP-client subset first, with real readiness

> **Doc-state**: ACTIVE
> Status: Accepted (2026-06-12)

## Context

The CM campaign (ADR-0170) targets wasmtime-equivalent WASI Preview 2.
`wasi:sockets@0.2.x` is the last unimplemented interface family: today an
import of `wasi:sockets/*` errors cleanly (`wasi_p2_unknown_import` fixture,
D-308). Survey (`private/notes/p17-d3-8-sockets-survey.md`, 2026-06-12):

- The spec family is 7 interfaces; a typical Rust/Go TCP **client** guest
  needs only `tcp-create-socket.create-tcp-socket`, `tcp` `start-bind`/
  `finish-bind`/`start-connect`/`finish-connect` (+ the minted
  input/output-streams), `instance-network`, and drops.
- wasmtime models a tcp-socket as a state machine
  (unbound → bound → connecting → connected | listening) over tokio
  (`crates/wasi/src/sockets/tcp.rs`); streams are minted on connect.
- zwasm's P1 layer has NO socket facility (`sock*` = `.notsock` stubs) and
  Zig 0.16 `std.Io` ships only an abstract Poller vtable — the concrete
  path is `std.posix.socket/bind/connect/recv/send` (+ `poll(2)`).
- **The fork**: zwasm's `wasi:io/poll` host is synchronous ALWAYS-READY.
  Sockets wired without real readiness lie to guests: `subscribe`+`poll`
  loops spin or hang, `finish-connect` cannot observe in-progress, and
  `accept` is unimplementable.

## Decision

**Phased, honest-first.**

1. **Phase 1 (this bundle): TCP-client subset with REAL readiness.**
   - New `TCP_SOCKET_RT` resource; state machine per the spec's documented
     transitions (unbound → bind-in-progress → bound → connect-in-progress
     → connected), re-derived from spec prose + wasmtime shape (textbook,
     no copy).
   - Host syscalls via `std.posix` with `O_NONBLOCK`; `start-connect`
     issues the non-blocking connect, `finish-connect` checks completion
     (`getsockopt(SO_ERROR)` / writability), minting the stream pair on
     success. Socket-backed input/output-streams route `read`/`write` to
     `recv`/`send` on the socket fd.
   - **Pollable honesty**: a pollable minted from a socket (`subscribe`,
     stream subscribe on a socket-backed stream) carries the fd +
     interest; `pollable.ready`/`block`/`poll` consult `poll(2)` for
     socket-backed entries. Non-socket pollables keep the existing
     always-ready behaviour (correct for the synchronous host's other
     resources). This removes the lie WITHOUT building an async runtime.
   - `instance-network`/`network` = a trivial singleton resource (the
     host's ambient network; no capability refinement yet).
2. **Phase 2 (follow-up chunks, demand-driven within E3)**: `listen`/
   `accept` (needs readiness on listeners — same poll(2) machinery),
   socket options beyond defaults, `shutdown`.
3. **Phase 3 (deferred until a consumer demands)**: UDP datagram streams +
   `ip-name-lookup` (resolver policy: blocking `getaddrinfo` vs caching —
   decide when reached). Unknown imports keep erroring cleanly until then.

Errors map through a `wasi:sockets/network` `error-code` table (19
ordinals) — a sibling of the D-307 filesystem errno map.

## Alternatives rejected

- **Blocking-posix subset without readiness (survey option a)** — makes
  `subscribe`/`poll` lie (spin/hang); violates `no_workaround` (silent
  semantic demotion) for a core interface family.
- **Stay deferred (option c)** — was the pre-campaign posture; rejected as
  the steady state because ADR-0170's bar is wasmtime-equivalence and the
  truthful-error fixture only covers the *absence*, not the feature.
- **Full async runtime (tokio-equivalent)** — disproportionate; `poll(2)`
  at the poll trampolines gives honest readiness for the synchronous host
  without an executor.

## Consequences

- A real Rust/Go TCP-client guest (connect + echo) becomes the proof
  fixture (gen-shell built, committed; loopback server provided by the
  e2e test harness on the host side).

## Revisions

- **2026-06-12 (impl-1)**: the PINNED Zig 0.16.0 stdlib has no raw
  `std.posix` socket surface (the survey read a newer master clone) —
  networking is `std.Io.net` (io-based, blocking under `Threaded`). The
  Decision's "O_NONBLOCK + finish polls completion" mechanism is adjusted:
  the synchronous connect executes inside `start-connect` with the result
  cached for `finish-connect` (guest-observable two-phase contract
  preserved); readiness stays poll(2)-honest via `posix.poll` on the
  socket handle. Bound-socket connect = truthful `not-supported` until
  Phase 2 (`std.Io.net` has no bound-connect).
- `p2Poll`/`pollable.ready` gain a socket-aware branch — the always-ready
  fast path is unchanged for non-socket pollables.
- Win64: `poll(2)` → `WSAPoll` divergence; gate via the existing platform
  layer, cross-compile before push (platform_panic_vs_error discipline).
- Bundle `d3-8-sockets-tcp` tracks the multi-cycle rollout.
- **2026-06-13 (Phase 2 LANDED)**: listener subset shipped — `TcpState`
  gains `listen_started`/`listening`; `start-listen` runs the OS
  socket+bind+listen atomically (`netListenIp`; the pinned stdlib has no
  separate stream-socket bind, so `start-bind` validates+stores and bind
  failures surface at `finish-listen` — the Phase-2 defer-bind
  DIVERGENCE); non-blocking `accept` gates on poll(2) readiness and
  mints the accepted connection + stream pair; REAL
  `local-address`/`remote-address` (canonical in-memory encode; peer
  addr from netAccept); `set-listen-backlog-size` stored pre-listen.
  Proof: `wasi_p2_listen_rust.wasm` (rustc wasip2 std::net::TcpListener)
  accepts a host client and echoes e2e. **WSAPoll landed** (D-319): the
  pinned stdlib has no WSAPoll binding, so `pollOnce` declares
  `extern "ws2_32" WSAPoll` per the platform-layer `extern "kernel32"`
  precedent (POLLRDNORM/POLLWRNORM interest bits); all windows skips
  removed — windowsmini verifies at its next batch. Phase-3
  (UDP/name-lookup) remains deferred.
- **2026-06-13 (D-319 DISCHARGED)**: windows readiness verified full-green
  on windowsmini (probe #6: unit + both rust e2e). The WSAPoll plan was
  unimplementable on the pinned stdlib (raw NT/AFD handles, winsock
  never initialized/registered — probes #3/#4: WSA 10093 → 10038);
  shipped IOCTL_AFD_POLL via `ntdll.NtDeviceIoControlFile` instead
  (wepoll approach). The earlier windowsmini "hang" was the guest poll
  loop spinning on never-ready readiness. All windows test gates and the
  probe flag are removed; residual: the stdlib's unmapped
  connection-refused NTSTATUS (D-323). Lesson:
  `2026-06-13-winsock-vs-nt-afd-handles`.
- **2026-10-24 (network grant)**: Phase 1's ambient network is replaced by a
  grant, `Host.allow_network` (CLI `--allow-network`), off by default. Every op
  that creates a socket or reaches the host's network checks it when called
  (the callers of `ctxRequireNetwork`) and answers `access-denied` without it,
  in every `-Dwasi` build: a sync export reaches the 0.3 host in the default
  build. `instance-network` stays ungated, since its WIT result has no error
  arm. The grant is one bool; per-address policy is not decided.
