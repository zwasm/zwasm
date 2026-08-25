# 0105 — Adopt JIT-prologue stack-probe for stack-overflow trap recovery

- **Status**: Closed (implemented) 2026-05-24
- **Date**: 2026-05-22
- **Author**: Shota Kudo + 2026-05-22 Agent 4 (v1/wasmtime comparative survey)
- **Tags**: phase-9, codegen, jit, win64, posix, stack-overflow, abi
- **Companion**: ADR-0104 (Phase 9 honest-accounting reframe) — META decision; this ADR is the technical design for D-162.
- **Supersedes**: ADR-0103 §"Consequences" path-(a) `_resetstkoflw` MSVCRT linkage quick fix (DEMOTED to Rejected via this ADR).

## Context

D-162 (`SKIP-WIN64-EXHAUSTION`) was filed when the W4 retry chain
discovered that `assert_exhaustion runaway ()` fixtures crash
windowsmini even after VEH-based recovery (`windows_traphandler.zig::
vehHandler`) catches `EXCEPTION_STACK_OVERFLOW`. Root cause: Windows
does not auto-restore the guard page consumed by the original
stack-overflow; subsequent stack growth re-faults outside the VEH
filter window.

ADR-0103 (Win64 SEH bridge) §"Consequences" enumerated 2 fix paths:

- **(a)** Link `_resetstkoflw()` from MSVCRT via `@extern "msvcrt"` —
  re-arms the guard page. Requires ADR-0070 libc_boundary 3rd-category
  amendment (Win64-only MSVCRT linkage). Quick (~1 day), Win64-specific.
- **(b)** JIT-prologue stack-probe — emit explicit stack-limit check
  at function entry in JIT codegen; the probe traps with `Error.Trap`
  cleanly via existing trap-stub path BEFORE the hardware fault.
  Cross-platform (POSIX + Win64), matches v1 + wasmtime.

Path (a) was tentatively chosen at W4 retry sequence as the
"first-cycle quick fix" but never landed (D-162 SKIP remained
active).

The 2026-05-22 Agent 4 comparative survey (v1 + wasmtime + spec
testsuite) established:

1. **v1 uses path (b)**:
   - `~/Documents/MyProducts/zwasm/src/x86.zig:2708-2722` — JIT
     prologue emits `cmp [vmctx + stack_limit_off], rsp` + `jbe
     stack_overflow_trap_stub`.
   - `~/Documents/MyProducts/zwasm/src/jit.zig:6464` — stack-limit
     wiring.
   - `~/Documents/MyProducts/zwasm/src/cli.zig:2157` — converts
     `error.StackOverflow` (from the trap stub) to clean spec-
     compliant `Trap`.
   - v1's `guard.zig` Windows handler only filters
     `EXCEPTION_ACCESS_VIOLATION` (`src/guard.zig:289-309` at tag
     `v1.11.1`); hardware
     EXCEPTION_STACK_OVERFLOW path is **bypassed by design**.

2. **wasmtime uses path (b)**:
   - `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/sys/
     windows/vectored_exceptions.rs:181-187` — VEH filter explicitly
     excludes `EXCEPTION_STACK_OVERFLOW`.
   - `~/Documents/OSS/wasmtime/crates/cranelift/src/func_environ.rs:
     204-211, 3664-3672` — Cranelift emits `stack_limit_check` at
     function entry; reads SP, compares against
     `vmctx.stack_limit`, traps with `TrapCode::STACK_OVERFLOW`.
   - `~/Documents/OSS/wasmtime/crates/cranelift/src/isa_builder.rs:
     26-29` — `enable_probestack=false` explicit (the per-function
     entry probe IS the stack-guard mechanism).
   - `~/Documents/OSS/wasmtime/tests/all/traps.rs:266-291` — unit
     test asserts `Trap::StackOverflow` cross-platform (no
     `#[cfg(unix)]`).

3. **No production Wasm runtime relies on hardware
   EXCEPTION_STACK_OVERFLOW + VEH recovery + `_resetstkoflw`**.
   The path (a) approach is a Win64-specific workaround that
   sidesteps the real issue (no per-function stack-budget probe).

## Decision

Adopt path (b) — JIT-prologue stack-probe — as the cross-platform
stack-overflow trap mechanism for zwasm v2. Implementation:

### D1 — `JitRuntime.stack_limit` field

Add an instance-scoped `stack_limit: usize` field to `JitRuntime`
(stored at a fixed offset, accessed via the existing R15/X19 vmctx
pointer). Set at instance instantiation to:

```
stack_limit = pthread_get_stackaddr_np(thread) - pthread_get_stacksize_np(thread) + STACK_GUARD_HEADROOM
```

where `STACK_GUARD_HEADROOM` = the maximum Wasm frame size we
guarantee to handle after a `stack_limit` violation (likely ~16 KiB
to safely run the trap-stub epilogue + recovery).

Cross-platform mapping:
- POSIX: `pthread_get_stackaddr_np` + `pthread_get_stacksize_np`
  (macOS) or `pthread_attr_getstack` (Linux).
- Win64: `GetCurrentThreadStackLimits` (Win 8+) returns
  `[low, high]`; use `low + STACK_GUARD_HEADROOM`.

### D2 — JIT prologue stack-probe

Emit at the start of every JIT-compiled Wasm function (BEFORE any
`SUB rsp, frame_size` allocation):

**x86_64**:
```text
cmp [r15 + stack_limit_off], rsp
jbe stack_overflow_trap_stub      ; rsp <= stack_limit → trap
```

**arm64**:
```text
ldr x16, [x19, #stack_limit_off]
mov x17, sp
cmp x17, x16
b.ls stack_overflow_trap_stub     ; sp <= x16 → trap
```

### D3 — Stack-overflow trap stub

Reuses the existing per-arch trap-stub infrastructure (`emit.zig::
emitTrapStub`). Sets `error.Trap` in the runtime + jumps to
`siglongjmp` recovery target (POSIX) or VEH `Rip/Rsp/Rax` redirect
(Win64). The same `error.Trap` path that bounds-check / OOB-table /
divide-by-zero traps use.

### D4 — Remove EXCEPTION_STACK_OVERFLOW from VEH filter

`src/platform/windows_traphandler.zig::vehHandler` currently
filters EXCEPTION_STACK_OVERFLOW (added at W4 retry 2 = `09ee5bb9`).
After D2 lands, the probe traps BEFORE the hardware fault — VEH
never sees a stack-overflow exception.

### D5 — Remove SKIP-WIN64-EXHAUSTION from runner

`test/spec/spec_assert_runner_base.zig::.assert_exhaustion` arm
emits `SKIP-WIN64-EXHAUSTION` on Windows. After D2-D4 land, remove
the SKIP arm. Verify `assert_exhaustion runaway` PASSes on all 3
hosts.

### D6 — STACK_GUARD_HEADROOM sizing

The headroom must accommodate:
- Trap-stub epilogue (~256 bytes worst case).
- `siglongjmp` recovery state (~128 bytes).
- Recursion-depth-1 of the trap handler itself (signal frame on
  POSIX, VEH frame on Win64).
- A safety margin for the Wasm function's local-stack-frame at
  the SP-probe site (the frame hasn't been allocated yet at probe
  time, so this is just the "next call" headroom).

Conservative initial value: **16 KiB** (`0x4000`). Tunable per ADR
amendment if D-162 fixtures stress-test reveals lower bound. v1
uses 64 KiB historically (`v1/src/cli.zig`); wasmtime's
`STACK_LIMIT_FROM_RED_ZONE_SIZE` is configurable per `Config`
(default 32 KiB).

## Alternatives considered

### Alternative A — ADR-0103 path (a): `_resetstkoflw()` MSVCRT linkage

- **Sketch**: `@extern "msvcrt" fn _resetstkoflw() c_int` called
  from `vehHandler` after EXCEPTION_STACK_OVERFLOW. Re-arms the
  guard page in-place. ADR-0070 amended to add Win64-only MSVCRT
  3rd-category exception.
- **Why rejected**:
  1. Win64-specific — POSIX still needs a different mechanism
     (signal-handler-altstack + sigaction SIGSEGV with stack-fault
     detection), creating per-platform divergence in the trap
     path. Path (b) is uniform across hosts.
  2. Relies on undocumented MSVCRT internals (`_resetstkoflw`
     behaviour changes across MSVC versions); link surface
     introduces stability risk per ADR-0070 §"Convenience-bucket
     evaluation".
  3. Neither v1 nor wasmtime adopts this path — production-runtime
     consensus rejects it.
  4. Does not fix the underlying design issue (relying on
     hardware EXCEPTION_STACK_OVERFLOW). Path (b) eliminates the
     reliance.

### Alternative C — Per-function stack-frame static analysis + tail-call elimination

- **Sketch**: At JIT compile time, compute each Wasm function's
  worst-case stack usage (incl. transitive calls). If the worst
  case exceeds a budget, refuse to compile (`Error.StackUnbounded`).
  Tail-call elimination opportunistic.
- **Why rejected**:
  1. Wasm allows recursion of arbitrary depth — static analysis
     can't bound it.
  2. Tail-call elimination is a Wasm 3.0 proposal (`return_call`)
     — Phase 10+ scope.
  3. Per-function probe is cheaper than full call-graph analysis
     at compile time.

### Alternative D — Increase OS thread stack size to "enough"

- **Sketch**: At instance instantiation, request a 64 MiB thread
  stack via `pthread_attr_setstacksize` / `CreateThread(stacksize)`.
- **Why rejected**:
  1. Doesn't solve the problem — recursion still consumes the
     stack; eventually overflows.
  2. Wastes memory (each instance commits MB-scale stacks).
  3. Doesn't match production-runtime practice (wasmtime uses
     ~512 KiB default stack + per-function probe; v1 ~2 MiB).

## Consequences

### Positive

- **Cross-platform uniformity**: same probe + trap-stub path on
  Mac aarch64 + ubuntunote x86_64 + windowsmini Win64. Easier to
  test, easier to teach (P10).
- **Eliminates D-162 SKIP-WIN64-EXHAUSTION**: `assert_exhaustion
  runaway` PASSes on Windows post-implementation. Phase 9 honest
  exit predicate (per ADR-0104 D1.2) satisfied for D-162.
- **Eliminates VEH EXCEPTION_STACK_OVERFLOW filter complexity**:
  `windows_traphandler.zig::vehHandler` simplifies; one fewer
  exception code to handle.
- **Industry-standard convergence** with v1 + wasmtime.
- **Performance neutral**: per-function probe is 2 instructions
  (cmp + jbe / cmp + b.ls), well below 1% function-entry
  overhead. wasmtime measurements (their `enable_probestack=false`
  rationale) confirm this.

### Negative

- **Implementation cost**: per-arch emit + per-arch trap-stub
  wiring + cross-platform stack-limit field. Estimated 2 cycles
  of `/continue` autonomous loop.
- **Stack-limit-field overhead**: `JitRuntime.head_size` grows by
  8 bytes for the `stack_limit` field. (Per-instance, not per-call.)
- **STACK_GUARD_HEADROOM tuning**: initial 16 KiB might be wrong;
  tune by running `assert_exhaustion` fixtures + Phase 11 embenchen
  on all 3 hosts. Per-amendment.

### Neutral

- **ADR-0103 stays Accepted** as the SEH-bridge-design ADR. Its
  Consequences §"Two fix paths" gets a Revision history row noting
  path (a) is REJECTED by this ADR; path (b) is the chosen design.
  ADR-0103's other content (VEH handler shape, threadlocal
  RecoveryInfo, `callJitOrTrap` helper) remains load-bearing.

## Implementation plan

(Tracked by D-162 row in `.dev/debt.md`; rough cycle count.)

1. **Cycle 1** — `JitRuntime.stack_limit` field + cross-platform
   `instantiate.zig` initialisation. Add `head_size` test.
2. **Cycle 2** — x86_64 prologue emit + arm64 prologue emit + the
   3 stack-overflow trap-stub entry points. Mac + ubuntunote
   `assert_exhaustion runaway` PASS verification.
3. **Cycle 3** — Win64 prologue emit + windows_traphandler.zig
   EXCEPTION_STACK_OVERFLOW filter removal + windowsmini W4 retry
   to verify `assert_exhaustion` PASS. Remove SKIP-WIN64-EXHAUSTION
   arm. D-162 close.

## Removal condition

This ADR is permanent (the chosen design is the project's
stack-overflow trap mechanism). Status: `Closed (Phase 9 DONE)`
when D-162 closes + all 3 hosts PASS `assert_exhaustion` fixtures.

## References

- ADR-0104 (Phase 9 honest-accounting reframe — META decision
  this ADR implements one technical leg of).
- ADR-0103 (Win64 SEH bridge — path (a) demoted by this ADR;
  path (b) = this ADR).
- ADR-0070 (libc_boundary — would have needed Win64 MSVCRT 3rd-cat
  amendment under path (a); not needed under (b)).
- v1: `~/Documents/MyProducts/zwasm/src/x86.zig:2708-2722`
  (stack-probe emit), `src/jit.zig:6464` (stack_limit wiring),
  `src/cli.zig:2157` (Trap conversion), `src/guard.zig:289-309`
  (Windows handler EXCEPTION_ACCESS_VIOLATION only).
- wasmtime: `crates/wasmtime/src/runtime/vm/sys/windows/
  vectored_exceptions.rs:181-187` (VEH filter, no
  STACK_OVERFLOW), `crates/cranelift/src/func_environ.rs:
  204-211, 3664-3672` (stack_limit_check), `crates/cranelift/
  src/isa_builder.rs:26-29` (enable_probestack=false),
  `tests/all/traps.rs:266-291` (cross-platform Trap::StackOverflow
  test).
- Spec testsuite: `assert_exhaustion runaway` in
  `~/Documents/OSS/WebAssembly/testsuite/call.wast` + sibling
  fixtures — core Wasm 1.0 MUST-PASS.

## Revision history

| Date       | Commit       | Change                          |
|------------|--------------|---------------------------------|
| 2026-05-22 | `6bfd0c8c` | Initial draft (Proposed status; user flips Accepted at §9.13 hard gate per ADR-0104 D5) |
| 2026-05-23 | `783517cb` | **Status: Proposed → Accepted** per user collab re-audit. Single design path with v1 + wasmtime precedent; ROADMAP §2 P3 (cold-start over peak; 2-instr prologue <1% overhead) + P10 (cross-platform uniformity teaches the same pattern on all 3 hosts) + P14 (`_resetstkoflw` Win64-only workaround explicitly Rejected) all align. No §14 forbidden-list conflict. Implementation per §"Implementation plan" cycles 1-3 now unblocked for the autonomous loop. |
| 2026-05-24 | `b160206b` | **Status: Accepted → Closed (implemented)**. D-162 closed via cycles 1-3 implementation (stack-limit query + JIT-prologue compare-and-trap). SKIP-WIN64-EXHAUSTION arm removed from spec_assert_runner_base.zig; `check_phase9_close_invariants.sh` invariant I1a passes at 18/18. Per Phase C ADR canonical pass (§9.12-I). |
| 2026-06-08 | (pending) | **Linux query made musl-portable** per ADR-0178 (cljw v1 handoff §A1). The glibc `pthread_getattr_np` path is now `comptime`-gated behind `builtin.abi.isGnu()`; musl/other Linux derives the main-thread limit from `/proc/self/maps` top minus `RLIMIT_STACK` (the glibc/sanitizer method) via `std.os.linux.*`. Sentinel-disabled on non-main musl threads / unbounded rlimit. glibc / Mac / Windows paths unchanged. |
