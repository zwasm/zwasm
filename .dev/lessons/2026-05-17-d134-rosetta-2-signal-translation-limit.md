---
slug: d134-rosetta-2-signal-translation-limit
date: 2026-05-17
keywords: D-134, Rosetta 2, OrbStack, SIGSEGV, sigaction, signal handling, JIT, x86_64-on-aarch64, dmesg
citing:
  - 58e69207 — D-134 closure + ubuntunote pivot commit
---

# D-134 OrbStack heisenbug — root cause is Rosetta 2 signal translation, not zwasm

## Outcome (2026-05-17, post-investigation)

**D-134 closed structurally** by **ADR-0067**: per-chunk Linux
x86_64 gate host pivoted from OrbStack `my-ubuntu-amd64`
(Rosetta-translated) to **native** `ubuntunote.local` (Ubuntu
24.04 LTS, 8 cores / 31 GB, NOPASSWD sudo, Determinate Nix,
direnv + nix-direnv pinned via `flake.nix`). Validation:
5/5 consecutive `test-spec-wasm-2.0-assert` green with
identical 1268-line stderr output (deterministic — no Rosetta
flakiness possible on native silicon), full `test-all` green
bit-identical with Mac aarch64 (24034 / 0 / 2015 spec_assert
non-simd + 13301 / 0 / 440 simd).

The retry wrapper (`scripts/orb_test_all_with_d134_retry.sh`)
that was prepared as a short-term mitigation **never reached
production** — the host pivot landed first. The wrapper is
retained in-tree as a Rosetta-class fingerprint classifier for
any future flake of the same shape (if a Rosetta-translated
host re-enters the gate path, the wrapper's
`process terminated with signal SEGV` + `[rosetta]` dmesg
fingerprint logic still applies).

OrbStack is retained as a Mac-local interactive scratch host
(`.dev/orbstack_setup.md`); it is not in any gate path.

## TL;DR

The "OrbStack Linux x86_64 `zwasm-spec-wasm-2-0-assert`
non-deterministic SEGV" tracked under D-134 since d-64 is
**not** caused by zwasm code, Zig stdlib startup, or signal-
handler install races. **OrbStack `my-ubuntu-amd64`'s
"x86_64" userland runs x86_64 binaries through Apple's
Rosetta 2 dynamic translation on an ARM64 kernel** (confirmed
via `/proc/sys/kernel/arch = aarch64` + `binfmt_misc [mac]`
interpreter + kernel `dmesg` line `[rosetta]:
zwasm-spec-wasm: potentially unexpected fatal signal 11`).
Long-running, high-fixture-count JIT workloads expose a
Rosetta 2 limitation where SIGSEGV delivery occasionally
fails to reach the guest-installed sigaction handler
(deterministic crash location but non-deterministic
recovery — handler fires on 3/10 runs at exactly the same
binary, same input, same SHA). zwasm code is correct; the
3-host gate's OrbStack path needs a Rosetta-aware retry
wrapper.

## What was already in the D-134 plan

Pre-investigation hypothesis tree (from `.dev/debt.md` D-134
"Strict discharge plan" + sibling lesson
[`2026-05-16-zig-sigsegv-recovery-flake.md`](2026-05-16-zig-sigsegv-recovery-flake.md)):

- (i) Some path calls `posix.sigaction(.SEGV, ...)` after our
  `installSigsegvHandler` overwriting our handler.
- (ii) `std.heap.DebugAllocator` diagnostic path installs its
  own handler.
- (iii) async-signal-safety violation inside our handler.
- (iv) `signal_stack_size` ↔ d-62 SA.ONSTACK 256 KB altstack
  interaction.

The pre-investigation lesson narrative (2026-05-16 entry)
ranked **cross-thread siglongjmp** (POSIX UB when sigsetjmp's
thread ≠ SEGV thread) as primary candidate after a web survey
of ziglang/zig#14658 + #25025.

## What 2026-05-17 investigation actually found

### Step 1 — Sigaction audit via LD_PRELOAD shim

Compiled `private/spikes/d134_sigaction_shim/shim.c` to log
every `sigaction(SIGSEGV, ...)` call (with `backtrace(3)` +
`dladdr` for caller resolution). Confirmed:

- Three sigaction calls per run: 2 installs (SEGV + BUS by
  `spec_assert_runner_base.installSigsegvHandler`) + 1
  readback (act=NULL). **No third party rewrites the SEGV
  disposition.** Hypothesis (i) rejected.
- Subagent audit of `~/Documents/OSS/zig/lib/std/`: only
  `attachSegfaultHandler` calls `sigaction(.SEGV, ...)` and
  it's gated by `std_options.enable_segfault_handler` which
  zwasm's runner sets to `false` at line 58 of
  `spec_assert_runner_non_simd.zig`. Hypotheses (i)/(ii)
  rejected at the Zig stdlib level too.

### Step 2 — Handler-entry probe

Added `_ = std.c.write(2, "H", 1)` at handler entry +
"A" / "U" markers on the armed / unarmed paths. Result:

- Green runs (EXIT=0): H≈15, A+U accounting matches —
  handler fires on every SEGV in the corpus.
- Crashing runs (EXIT=139): **H=0** — handler never runs at
  all. The kernel terminates the process with the default
  SIGSEGV action despite our handler being the registered
  disposition (verified by readback at install time).

### Step 3 — Build vs direct, strace, setsid, ulimit

The crash reproduces under different launch contexts at
inconsistent rates:

- Inside `zig build test-all`: SEGV in `zwasm-spec-wasm-2-0-assert`
  step.
- Direct `./zwasm-spec-wasm-2-0-assert <corpus>`: ~7/10 crash,
  3/10 green.
- Under `strace -e trace=...`: **always green** (ptrace's
  serialization changes the timing window).
- Under `setsid`: green most runs.
- With `ulimit -c unlimited` + core dump: crash; `gdb` itself
  segfaults trying to read the 785 MB core file (file-backed
  mapping notes are malformed; suspected JIT-page artefacts).

### Step 4 — Kernel-side `dmesg` capture (the smoking gun)

After `echo 1 > /proc/sys/kernel/print-fatal-signals`, `dmesg`
produced:

```text
[122222.032003] [rosetta]: zwasm-spec-wasm: potentially unexpected fatal signal 11.
[122222.032016] CPU: 4 UID: 501 PID: 57305 Comm: zwasm-spec-wasm ... PREEMPTLAZY
[122222.032018] pstate: 80000000 (Nzcv daif -PAN -UAO -TCO -DIT -SSBS BTYPE=--)
[122222.032019] pc : 0000effff83018f8
[122222.032019] lr : 000080000004e074
[122222.032020] sp : 0000effff7df3750
[122222.032020] x29: 0000effff7df37a0 x28: 0000000000000004 x27: 0000000000000001
[...]
```

Key observations:

- `[rosetta]:` prefix — the kernel labels this process as
  Rosetta-translated (host ARM64, guest x86_64).
- `pstate` / `x0..x29` register dump — these are **ARM64
  registers**, not x86_64. The crash is in the
  Rosetta-translated host code, not the guest x86_64
  instruction stream.
- `pc : 0000effff83018f8` — address range
  `0000effff...` is characteristic of Rosetta translation
  cache mappings (host-managed RX pages distinct from the
  guest's mmap'd RWX JIT pages).

`uname -m` reports `x86_64` (guest userspace),
`cat /proc/sys/kernel/arch` reports `aarch64` (host kernel),
and `binfmt_misc` shows a `[mac]` interpreter for
Mach-O-magic + x86_64 ELFs — OrbStack routes both Mac- and
Linux-x86_64 binaries through Apple's Rosetta 2 (rather than
qemu-user).

### Step 5 — Vanilla SIGSEGV-handler reproducer

Minimal C reproducer
`private/spikes/d134_sigaction_shim/repro.c` (sigaltstack +
SA_ONSTACK + sigsetjmp + handler with raw write(2)) plus the
JIT variant `repro_jit.c` (NULL deref from a freshly-mmap'd
RWX page) **both pass 1,000,000 iterations × 3 runs at every
scale tested** (100 / 1k / 10k / 100k / 1M). 15/15 green.

So vanilla "sigaction → SEGV → siglongjmp" + "JIT page →
NULL deref → siglongjmp" works on Rosetta. The bug requires
the *combination* of long-running execution, many JIT page
allocations / mprotect cycles, and Zig runtime state.

### Step 6 — Crash determinism

10 direct runs: 3 green, 6 crash at exactly 5 stderr lines
(same 5 `compileWasm: ... → validate ...` lines), 1 crashes
mid-run at 322 stderr lines. The crash location is fixed in
the corpus; what varies is whether Rosetta's signal-delivery
race delivers the signal to our handler or terminates the
process.

## Root cause (named)

**Apple Rosetta 2's SIGSEGV delivery to a guest-installed
`sigaction(.SEGV, ..., SA_ONSTACK)` handler is unreliable for
long-running JIT workloads** on (at least) macOS 15 / Apple
Silicon + OrbStack's `my-ubuntu-amd64` machine
(rosetta-translated kernel `6.17.8-orbstack-00308`).

This is **not** a zwasm code bug. It is **not** a Zig stdlib
bug. It is an environmental limitation of Rosetta 2's
signal-translation pipeline when interacting with a
high-iteration JIT-allocating x86_64 process.

## Discharge strategy considered

Three options were weighed during the investigation. **The
actual closure chose option (3)** — see "Outcome
(2026-05-17, post-investigation)" at the top of this file and
ADR-0067 §Alternatives for the load-bearing decision record.

1. **Rosetta-retry wrapper around the spec-runner step**
   (drafted, NOT adopted): `scripts/orb_test_all_with_d134_retry.sh`
   re-invokes the binary up to N times and accepts the first
   green outcome. Detects D-134 specifically (matches
   `zwasm-spec-wasm-2-0-assert failure` + `process terminated
   with signal SEGV` log fingerprints). The wrapper is retained
   in-tree as a historical Rosetta-class fingerprint classifier
   but is **not invoked from the autonomous loop** post-pivot.

2. **Switch OrbStack to native ARM64** (`my-ubuntu-arm64`):
   rejected — would lose x86_64-codegen coverage on this host
   and demote the per-chunk gate from "Mac aarch64 + Linux
   x86_64" to "Mac aarch64 + Ubuntu aarch64", deferring
   x86_64 regressions to windowsmini's phase-boundary
   reconcile (ADR-0049).

3. **Replace OrbStack with a native x86_64 Linux host**
   (chosen) — ADR-0067 ubuntunote pivot. Eliminates the
   Rosetta translation layer entirely; signal-handling
   semantics revert to upstream kernel + glibc behaviour on
   real silicon. Validation: 5/5 deterministic-green
   `test-spec-wasm-2.0-assert` at the same SHA, bit-identical
   24034/0/2015 + 13301/0/440 with Mac aarch64.

The retry-loop streak discipline in
[`investigation_discipline.md` §2](../../.claude/references/investigation_discipline.md)
remains in force for future heisenbug debt rows; D-134 itself
closed via root-cause identification + environmental host
change rather than empirical streak.

## Why earlier hypotheses (ii)/(iii)/(iv) fell apart in this investigation

- (ii) `std.heap.DebugAllocator` SEGV handler: confirmed
  absent — the only SEGV-installer in Zig 0.16 stdlib is
  `attachSegfaultHandler`, gated by `enable_segfault_handler`.
- (iii) async-signal-safety violation in our handler: the
  handler-entry probe showed H=0 in crash runs (handler
  never enters) — there's no in-handler crash to violate
  safety inside.
- (iv) signal_stack_size interaction: green-run pattern (15
  H markers fire correctly with the same altstack)
  contradicts a fundamental altstack bug.

The 2026-05-16 lesson's "cross-thread siglongjmp" candidate is
also rejected — the runner is compiled `-fsingle-threaded`
per the build.zig step definition, so there is no second
thread that could fire SIGSEGV out of the handler's
sigsetjmp anchor.

## Related artefacts

- Pre-investigation lesson:
  [`2026-05-16-zig-sigsegv-recovery-flake.md`](2026-05-16-zig-sigsegv-recovery-flake.md)
  (now superseded — its hypothesis tree was unable to
  identify the Rosetta-environmental cause; the d-65
  valgrind capture remains valid evidence that Zig's default
  `handleSegfaultPosix` chain CAN recurse, but that path is
  neutered by `std_options.enable_segfault_handler = false`).
- LD_PRELOAD shim: `private/spikes/d134_sigaction_shim/shim.c`.
- Reproducers: `private/spikes/d134_sigaction_shim/repro.c`
  (vanilla) + `repro_jit.c` (JIT page). Both pass 1M
  iterations.
- Retry wrapper (preserved as historical classifier; NOT in
  the autonomous loop hot path post-ADR-0067):
  `scripts/orb_test_all_with_d134_retry.sh`.
- Production gate wrapper (post-ADR-0067 ubuntunote host):
  `scripts/run_remote_ubuntu.sh`.

## Reviewer checklist when re-classifying a future D-134-shaped flake

- [ ] `cat /proc/sys/kernel/arch` on the failing host: does
      it report a different arch than the binary's
      `uname -m`? → Rosetta / emulation candidate.
- [ ] `dmesg` after `echo 1 > /proc/sys/kernel/print-fatal-signals`
      shows `[rosetta]:` prefix? → confirmed Rosetta.
- [ ] Direct binary execution outside `zig build`: same
      reliability profile (~3/10 green / ~7/10 SEGV at
      identical determinism point)? → matches D-134 fingerprint.
- [ ] Vanilla sigaction + siglongjmp C reproducer (1M iters)
      green on the same host? → confirms it's not the
      base sigaction shape.

If all four → close as D-134-mitigated-via-retry. If any
diverges → genuine new bug; do NOT classify as D-134.
