# ADR-0205: WASI 0.3 full-coverage campaign (wasi03-full)

- **Status**: Accepted — campaign COMPLETE incl. the F windows port (phases
  A–F landed on `develop/wasi-03-full`; official corpus 45/45 green on ALL
  THREE supported OSes; D-568 and D-569 both discharged)
- **Date**: 2026-08-10
- **Front**: D-wasi03 (D-335 / D-523 / D-524; user-directed 2026-08-10)
- **Findings base**: `~/Documents/OSS/WASI` tag `v0.3.0` WIT inventory +
  Step-0 survey of `src/wasi/adapter.zig` / `src/api/component_wasi_p2.zig` /
  `src/feature/component/async.zig` (this session).

## Context

WASI 0.3.0 was released 2026-06-11; `specifications/wasi-0.3.0/` covers six
proposals — **cli, clocks, filesystem, http, random, sockets** — published as
OCI packages and tagged `v0.3.0` in the WASI monorepo. Upstream now runs a
two-monthly **release train** (`docs/Release.md`: 0.3.1 on 2026-08-11, then
every second Tuesday). The WIT delta between `v0.3.0` and today's HEAD
(0.3.1-to-be) is 3 doc-comment lines in `http/types.wit` — implementing 0.3.0
is implementing 0.3.1.

zwasm today (post ADR-0187…0197): the CM-async substrate (streams, futures,
waitable-sets, multi-task `driveScheduler`) is shipped; the P3 host surface is
cli (stdio via-stream, env, exit, terminal) + clocks (`now`/`get-resolution`,
incl. 0.3 `system-clock`) + random — all dispatched through the **P2 adapter
table with version-stripped name matching**. Missing vs official 0.3.0:
`monotonic-clock.wait-until`/`wait-for` (no timer waitable exists),
`cli/exit.exit-with-code`, the whole filesystem-0.3 via-stream data plane,
sockets-0.3 (async TCP / UDP / ip-name-lookup), and all of `wasi:http`
(absent). Version-stripped matching cannot distinguish 0.2/0.3 same-name
functions whose shapes differ (filesystem `stat`, sockets).

The goal (user-directed): zwasm claims **full WASI 0.3 coverage** — every
`@since(version = 0.3.0)` interface/function of the six shipped proposals.
`@unstable` gated features (e.g. `clocks/timezone`) are explicitly out of the
claim, matching upstream's own release gating.

Verification asset: the official `wasi-testsuite` now carries **45
`wasm32-wasip3` rust guest tests** (cli 6, filesystem 16, http 8, sockets 12,
clocks/random/run 8) with `wkg.lock` pinned `=0.3.0`, prebuilt on the
`prod/testsuite-base` branch (Apache-2.0). Measured: those binaries are
dual-world (import both `wasi:*@0.2.x` and `@0.3.0`) — the host must serve
both generations at once, which zwasm's unified adapter already does
structurally.

## Decisions

### D1 — Version-generation-aware import classification (closes D-524(3))

`resolveComponentImport` keeps the interface's semver but classification maps
it to a **generation** `gen ∈ {p2, p3}` from `major.minor` (`0.2 → p2`,
`0.3 → p3`). The adapter table key becomes (iface, func, gen-mask); rows whose
shape is identical across generations carry both bits (environment, random,
exit, `monotonic-clock.now`…), diverging shapes get per-gen rows (filesystem,
sockets). Unknown generations stay `error.UnsupportedWasiImport`.

- Rejected: full-semver dispatch rows — the release train would force a row
  churn every two months for shape-identical bumps; generation is the level
  at which shapes actually diverge (0.2.x is frozen-shape, 0.3.x additive).

### D2 — Timer waitable + scheduler sleep policy (unblocks D-524(1))

Zone-1 `async.zig` gains a **deadline waitable**: `pollSet` compares
`monotonic now` against the deadline; `driveScheduler`'s no-progress policy
changes from unconditional `error.AsyncDeadlock` to: if any timer is pending,
**sleep until the nearest deadline** (host-runner seam), then re-poll.
No-progress with no pending timer stays AsyncDeadlock. This is the foundation
for `wait-until`/`wait-for`, http `request-options` timeouts, and sockets
connect/keep-alive timeouts.

### D3 — Conformance = vendored official wasi-testsuite binaries (reframes D-523)

Vendor the `prod/testsuite-base` prebuilt `wasm32-wasip3` binaries + their
`.json` manifests under `test/component/wasip3_official/` (Apache-2.0 →
`legal/THIRD_PARTY.md` entry), enabled per phase as interfaces land, wired
into `zig build test-wasi-p3`. The 7 local rust fixtures stay as the CM-async
export-ABI corpus. D-523's local-regen half is reframed **external-blocked**:
the borrowed wasip2 wasi-libc keeps emitting 0.2.6 imports until upstream
ships a wasip3 wasi-libc; the official binaries carry the 0.3.0-import
certification meanwhile.

### D4 — Phasing (each phase = one `develop/*` PR, TDD, CI 3-OS gate)

- **A — substrate**: D2 + D3 harness + the missing canon builtins
  (context.get/set, subtask.drop/cancel, task.cancel, waitable-set.poll/drop,
  thread.yield decode) + async-lower binding for the timer waits +
  `wait-until`/`wait-for` + `exit-with-code`. Exit: official cli/clocks/random
  tests green; closes D-524(1). *(Amended during phase A: D1
  generation-aware dispatch moves to the START of phase B — no colliding
  same-name row exists until filesystem-0.3 lands, and the dual-world official
  binaries bind correctly under version-stripped matching, so implementing D1
  in A would have been speculative.)*
- **B — filesystem 0.3**: descriptor `read/write/append-via-stream` via the
  ADR-0190 host-stream-peer pattern on the existing P2 descriptor backend;
  remaining methods as async-eager (D5). Exit: official filesystem tests
  green.
- **C — sockets 0.3**: `tcp-socket.create/bind/connect/listen/send/receive`
  (listen returns `stream<tcp-socket>`), UDP, `ip-name-lookup` — lifts the
  former future-bucket entry (user-directed). Exit: official sockets tests
  green. *(Status 2026-08-11: control plane DONE + green — create / bind with
  ephemeral resolution / all TCP+UDP options / address validation / udp-bind;
  the connected DATA plane + `getsockname`-dependent local-address +
  SO_REUSEADDR are **D-568**, blocked on a libc-boundary getsockname
  amendment + socket-readiness scheduler integration.)*
- **D — http 0.3 — DONE/green**: `types` resources (fields/request/response/
  request-options), `client.send` on `std.http.Client`, `handler` EXPORT
  invocation (the harness plays the HTTP client per manifest `request` op).
  Official http-fields/-request/-response/-request-options/-service/-echo/
  -uri/-client all green. Substrate additions: `task.return` generalized to
  >1-flat results via `defineFuncRaw`; `WaitableSet.resolveDroppedPeers`
  (completes a parked copy whose peer dropped after it parked). A
  `zwasm serve`-style CLI entry for the `service` world is QoI,
  demand-driven (not part of the interface-level coverage claim).
- **E — claims sweep — DONE**: README §WASI / migration doc / ROADMAP widget
  flipped to full-coverage; `scripts/check_wasi03_coverage_claims.sh`
  doc-truth guard (anchored on the http-client conformance test) wired into
  the always-on CI `doc-truth` job; CHANGELOG Added entry.
- **F — cross-OS truth pass — DONE** (2026-08-11, user-directed 全部実装しきる).
  The A–E "45/45 green" was a macOS-arm64-only measurement; running the
  corpus on the other two gate OSes surfaced 3 Linux + 10 windows real
  failures. Linux: TCP listen now composes a raw SO_REUSEADDR-only bind —
  the stdlib couples SO_REUSEPORT into `reuse_address` and clearing it
  post-bind is ineffective (the kernel bind bucket caches `fastreuseport` at
  first bind; spike `private/spikes/linux-reuseport-bind`). Windows: own
  NT/AFD socket control plane (UNIQUE-share bind fixing the address-in-use
  contract the stdlib's REUSE-share bind broke; dgram + bound + stream
  connect ioctls with real status mapping — the stdlib's dgram connect dies
  on SO_REUSE_UNICASTPORT and its stream connect maps no failure statuses;
  AFD getsockname, which returns a plain sockaddr at offset 0) + NT
  hardlinks via FILE_LINK_INFORMATION (stdlib dirHardLink is a blanket
  OperationUnsupported) + pre-OS empty-path→NoEntry (NT resolves "" to the
  dir handle itself). Official corpus green on windowsmini with ZERO skips;
  D-568 (was: sockets data plane) and D-569 (was: explicit-bind connect)
  both discharged.

### D5 — Async-eager host completion (keeps ADR-0187 stackless design)

A WIT `async func` on the host side may **complete eagerly** (canonical ABI
permits sync completion of async calls). Only genuinely-blocking operations
park on waitables: timers (D2), via-stream planes, socket connect/accept/
receive, http send. Everything else (fs metadata ops, `advise`, `sync`…)
returns synchronously inside the async ABI. No fibers, no threads.

### D6 — 0.3.x release-train tracking

The quarterly `proposal_watch.md` review gains a WASI-release-train check:
record the latest `v0.3.x` tag + WIT diff vs the vendored surface; bump the
vendored testsuite binaries deliberately (never auto). Shape-identical bumps
are a doc-line change; shape-changing bumps open a debt row.

## Consequences

- ROADMAP §9.0 Front D re-scoped to cite this ADR + phases A–E;
  `wasi:sockets` listeners/UDP/name-lookup + fs `*-via-stream` **leave the
  genuinely-future bucket** (ADR-0132 autonomous re-scope, user-directed).
- D-524 closes at phase A; D-523 reframed per D3; http/sockets/fs residuals
  get rows only when a phase lands with a known gap.
- The 0.2 surface is untouched: dual-generation dispatch is additive; 0.2
  guests keep the exact rows they had.

## Revision history

| Date       | Note |
|------------|------|
| 2026-11-09 | D4 phase D's `zwasm serve` QoI entry landed for 0.3 (#688): WebAssembly/wasi-testsuite#296's runner skipped zwasm's 14 `wasi:http/service` tests for want of it. One instance, one request at a time; the 0.2 `incoming-handler` half stays open on #688. |
| 2026-11-09 | The vendored corpus moves to the 2026-10-30 `prod/testsuite-base` (`PIN_SHA` in `scripts/vendor_wasip3_official.sh`), the same 45 tests — a shape-identical bump under D6: the binaries now import the `@0.3.2` / `@0.2.9` names, which version-stripped matching already accepted. Not vendored: the ten new `http-client-*` tests (endpoint modes, canned responses, `kind: closed`), the next phase. `sockets-{tcp,udp}-properties` gained manifests that state the no-manifest default (run + wait, exit 0). |
