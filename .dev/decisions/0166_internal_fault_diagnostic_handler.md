# 0166 — Production internal-fault handler: SIGSEGV/crash → graceful "internal error"

- **Status**: Accepted (2026-06-06; autonomous-with-ADR per ADR-0153 — a silent
  signal-death with no diagnostic is a robustness/UX completeness miss; the
  あるべき論 is to surface "this is a zwasm bug" distinctly).
- **Date**: 2026-06-06
- **Author**: claude (D-292 B-core; ADR-0164 workstream B; Phase-16 完成形).
- **Tags**: signals, diagnostics, robustness, crash-vs-trap, §16, D-292, ADR-0164
- **Amends**: ADR-0070 (adds a production `std.c._exit` site; see §libc). Builds on
  ADR-0103 (Windows VEH) + the test-runner `installSigsegvHandler` pattern.

## Context

D-292 (ADR-0164) demands that a zwasm-INTERNAL fault (a v2 codegen bug, host-side
memory corruption — a real SIGSEGV) be **distinguishable** from a clean wasm
`Trap`. v2 uses NO signal-based wasm trap semantics: every wasm trap is an
explicit check (the D-293 CMP+branch → trap-stub mechanism) surfacing as
`Error.Trap` → CLI exit 1 + a `zwasm: trap kind=… msg=…` line. Therefore ANY
fatal signal that reaches the OS = a zwasm-internal bug, never normal operation.

**Current state (investigation 2026-06-06, correcting a stale "no signal handling
anywhere" premise):**
- `src/platform/signal.zig` — a 15-line PLACEHOLDER (reserved for guard-page
  SIGSEGV→trap; never implemented, since v2 chose explicit bounds checks).
- `src/platform/windows_traphandler.zig` (ADR-0103) — a real Win64 VEH, but for
  JIT trap **recovery**, armed per-call; faults OUTSIDE the jit code region return
  `EXCEPTION_CONTINUE_SEARCH` → default OS disposition. Never armed in production.
- `test/spec/spec_assert_runner_base.zig::installSigsegvHandler` — a working POSIX
  `sigaction` SEGV/BUS handler (sigaltstack + SA.SIGINFO + siglongjmp recovery),
  but TEST-ONLY.
- **Production `zwasm run`** installs ZERO fault handlers (grep of `src/cli/` +
  `src/engine/` = empty). So an internal fault → silent signal-11 death: exit 139
  (POSIX) / unhandled ACCESS_VIOLATION (Windows), NO diagnostic.

## Decision

Install a **production, diagnostic-only, last-resort fault handler** at CLI
startup (`src/cli/main.zig`, production entry only — NOT the test runners, which
own their recovery handlers). On an unintended fatal fault it writes a distinct
"internal error" line and exits with a distinct code, instead of dying silently.

- **POSIX** — mirror the test runner's proven setup but diagnostic-only (NO
  siglongjmp recovery): a **per-thread** `sigaltstack` (32 KiB of static TLS,
  armed on each thread's first entry into JIT code or the force-install; #321)
  + `std.posix.sigaction` (sa_sigaction form, `SA.SIGINFO | SA.ONSTACK`) for
  `SEGV` + `BUS` (+ `ILL`, `FPE`). `sigaction` is process-wide, `sigaltstack`
  is not — `SA.ONSTACK` is a promise every thread keeps for itself. The handler is
  **async-signal-safe**: it only `std.posix.write`s a FIXED message + the
  `siginfo.addr` fault address (rendered with a stack buffer, no allocator/stdio),
  then `std.c._exit(70)`. `std.posix.sigaction`/`write` are pure-Zig syscalls (no
  libc-boundary trigger); `std.c._exit` is already ADR-0070-necessary.
- **Windows** — `SetUnhandledExceptionFilter` (or a diagnostic arm of the existing
  `windows_traphandler`) as the last-resort filter: same fixed message +
  `ExceptionRecord.ExceptionAddress`, then `ExitProcess(70)`. Uses ntdll/kernel32
  (no libc). It runs only after any armed JIT-recovery VEH declines (continue-search).
- **Exit code 70** (`EX_SOFTWARE`, "internal software error") — unambiguously NOT
  exit 1 (clean wasm trap) nor 139 (uncaught signal). The message names it a zwasm
  bug + asks to report.
- **Message** (fixed, async-signal-safe): `zwasm: internal error — fatal signal <N>
  at <addr>. This is a bug in zwasm (not a wasm trap); please report it.`

## Consequences

- An internal fault becomes diagnosable: a clear "internal error … this is a bug"
  line + exit 70, vs a silent exit-139 crash. A clean wasm trap is unchanged
  (explicit `Error.Trap` → exit 1 + `trap kind=…`); the two are now three-way
  distinct (trap=1 / internal=70 / truly-unhandled=signal-default).
- **Not a correctness change** — internal faults are bugs to fix at the source;
  this makes them visible, it does not mask them (the handler always EXITS, never
  resumes; no recovery, no retry).
- **libc (ADR-0070 amendment)**: no NEW symbol. `std.c._exit` gains a PRODUCTION
  site (`src/platform/signal.zig`, the implemented handler) alongside its existing
  test-runner site; update the ADR-0070 inventory's `_exit` row. `std.posix.sigaction`
  + `std.posix.write` are pure-Zig (check_libc_boundary does not fire).
- **Testing** — a hidden `--__selftest-crash` flag (production-gated) deliberately
  raises the fault; a subprocess test asserts the diagnostic line + exit 70.
  Signal behaviour differs per-OS → 3-host verification is mandatory before close.
- **Interaction**: guarded production-only so it never shadows the test runner's
  recovery handler or an armed JIT-recovery VEH (those run first; this is the
  fallthrough). Stack-overflow SIGSEGV (host-side deep native recursion, cf. D-288)
  also surfaces as "internal error" — correct (it IS an internal limit hit).

## Implementation plan (bundle)

I `signal.zig` POSIX handler + main.zig install + `--__selftest-crash` + subprocess
test → II Windows filter → III 3-host verify (signal behaviour per-OS) → close.

## Revision history

| Date       | SHA          | Note |
|------------|--------------|------|
| 2026-06-06 | `e7eacf37d` | Initial accepted version. |
| 2026-09-08 | `<backfill>` | The alternate stack is per thread (32 KiB, armed on a thread's first JIT entry), not one 64 KiB stack for the process (#321). |
