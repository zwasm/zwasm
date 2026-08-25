# 2026-05-16 — Zig 0.16 SIGSEGV recovery flake (OrbStack Linux x86_64)

Citing: chunk d-65 of §9.9 / 9.9-l-1b-d093 (D-134 investigation, no fix landed).
Related debt: [D-134], [D-135].

## What surfaced

`zig build test-spec-wasm-2.0-assert` on OrbStack Linux x86_64
SEGVs non-deterministically (~50% rate) at `assert_exhaustion`
and at certain `assert_return` directives. Mac aarch64
unaffected. The d-62 fix (explicit altstack + atomic-flag
armed) reduced but did not eliminate the flake.

## What d-65 confirmed (concrete, no predictions)

1. **The runner code itself is correct** — direct binary
   execution sometimes passes (3-5 out of 10), sometimes
   SEGVs. Identical binary, identical args, identical corpus.
2. **strace / valgrind both perturb timing enough to hide the
   SEGV** — classic heisenbug. Confirms a race-condition class
   of bug, not a deterministic logic bug.
3. **Our installed SIGSEGV handler is registered** — readback
   via `sigaction(SEGV, NULL, &oact)` after install confirms
   our handler pointer is the active disposition (`D134-INSTALL-OK`
   probe marker fires).
4. **The handler DOES fire on intentional null deref**
   immediately after install (probe path with explicit
   `@ptrFromInt(1).* = 42`) — handler dispatch works.
5. **The handler does NOT fire on the actual SEGV**, even
   with `std.Options.enable_segfault_handler = false` so
   Zig's default handler is fully out of the way. The signal
   is delivered but our handler is bypassed → SIG_DFL →
   process killed.
6. **Captured RIP at SEGV is in libc.so.6 (0x7fffff7bd62a)**;
   fault address is either `0x1` (NULL+1 deref) or `0x7fffff7beff8`
   (stack-region adjacent). The latter is consistent with
   stack-guard-page touch.
7. **Two distinct directive sites trigger the SEGV**:
   `assert_return as-binary-right ()` in the `call_indirect`
   corpus AND `assert_exhaustion runaway ()` (the explicit
   stack-overflow fixture).

## Web survey findings (parallel subagent, 2026-05-16)

The most relevant upstream Zig/POSIX evidence:

- **[ziglang/zig#14658](https://github.com/ziglang/zig/issues/14658)**
  — Zig's `handleSegfaultPosix` is not signal-safe: it does
  locked stderr I/O. If the SEGV interrupts a thread holding
  `stderr_mutex` or `DebugAllocator`'s mutex, the nested panic
  deadlocks → external SIGSEGV. **valgrind captured exactly
  this recursive chain** in our case:
  `handleSegfaultPosix → writeCurrentStackTrace →
  printSourceAtAddress → ArrayList alloc → FixedBufferAllocator →
  mem.Alignment.toByteUnits (mem.zig:33: 1 << @intFromEnum(a))`
  raising secondary SIGILL on a garbage `Alignment` value.
- **[ziglang/zig#25025](https://github.com/ziglang/zig/issues/25025)
  + [PR #25227](https://github.com/ziglang/zig/pull/25227)** —
  DebugAllocator + threads + libc stack-trace SEGV. Fixed in
  0.16. Toolchain version confirmed `zig version` = 0.16.0
  so we should have the fix; worth verifying we have the
  post-PR-25227 build (`Zig 0.16.0` tagged release, not a
  pre-release).
- **[ziglang/zig#21810](https://github.com/ziglang/zig/issues/21810)**
  — setjmp/longjmp can optimize-eliminate locals even in
  Debug. We mitigate `sigsegv_armed` via `std.atomic.Value`;
  the lesson is to extend the same mitigation to any other
  locals that span sigsetjmp ↔ siglongjmp boundaries.
- **POSIX requirement**: `siglongjmp` MUST return into the
  thread that called `sigsetjmp`. glibc enforces nothing;
  cross-thread longjmp is undefined corruption. Analogous
  golang issue: [golang/go#44501](https://github.com/golang/go/issues/44501).
  If `std.Io.Threaded` migrates the JIT-body invocation
  across workers (work-stealing per [#25757](https://github.com/ziglang/zig/issues/25757)
  roadmap), our sigsetjmp anchor's thread may not match the
  SEGV thread.

## Hypothesis with strongest signal

**Cross-thread siglongjmp**: the JIT body invocation in
`spec_assert_runner_non_simd.zig:985-1000` is wrapped in
`base.sigsetjmp(&base.sigsegv_recover_buf, 1)`. The JIT body
itself runs on the calling thread, BUT some sub-step inside
(`dir.readFileAlloc`, allocator hot paths via Threaded.io)
may dispatch async work to a worker. If a SIGSEGV fires on
that worker, our handler longjmps using a jmp_buf that was
saved on the main thread → undefined behavior, frequently
manifests as recursive crash on libc-internal frames.

Secondary contributor: **stale jmp_buf reuse**. After a
successful sigsetjmp/JIT-body/return cycle, the saved
`sigjmp_buf` still references the now-popped dispatcher
frame. A subsequent SEGV that hits the armed-true window
(perhaps from `assert_exhaustion`'s preceding cleanup)
longjmps into garbage memory.

## What worked, what didn't, what to try next

- ✓ `std.atomic.Value(bool)` for `sigsegv_armed` (d-62) —
  necessary but insufficient. Defeats BSS-load elision but
  not the cross-thread / stale-jmp_buf class.
- ✓ Explicit 256 KB static altstack (d-62) — covers the
  main thread's altstack at known address.
- ✗ Adding ILL/FPE handlers — did not change behavior;
  the original SEGV is genuinely SIGSEGV, not a downgrade.
- ✗ Dropping `SA.ONSTACK` — increased SEGV rate slightly
  (5/6 vs 3/6); altstack helps but doesn't fix.
- ✗ Disabling Zig's `enable_segfault_handler` — handler
  doesn't fire either way → confirms it's NOT a Zig-default-
  handler interference.

**Next chunk's discharge plan** (handover'd to d-66+):

1. Log `pthread_self()` in `sigsegvHandler` AND at the
   sigsetjmp call site. Confirm whether they match in the
   non-recovering case.
2. Wrap the entire spec_assert runner main in a single-
   threaded Io context (e.g. `Threaded.init_single_threaded`)
   and re-measure SEGV rate. If 0% → cross-thread siglongjmp
   confirmed; the structural fix is per-worker altstacks +
   per-thread sigsetjmp anchors (or pinning JIT-body
   invocations to a single thread).
3. Audit `mem.Alignment.toByteUnits` callers in the panic
   chain — find who passes a garbage `Alignment`.
4. Confirm the installed Zig 0.16 tag has PR #25227.

## Why this lesson, not an ADR

Per [`lessons_vs_adr.md`](../../.claude/rules/lessons_vs_adr.md):
this is observational (a debug-time finding plus a web
survey) that future sessions might re-pay if they re-survey
the same upstream issues. Promotion to an ADR is appropriate
when a load-bearing structural change is adopted (e.g.
single-threaded Io context for spec runners). At d-65 close
no such change has landed.

## Reproduction recipe

```sh
orb run -m my-ubuntu-amd64 bash -c '
  cd ~/Documents/MyProducts/zwasm_from_scratch
  zig build test-spec-wasm-2.0-assert
  BIN=$(find .zig-cache -name "zwasm-spec-wasm-2-0-assert" -type f | head -1)
  for i in 1 2 3 4 5; do "$BIN" ~/Documents/MyProducts/zwasm_from_scratch/test/spec/wasm-2.0-assert > /dev/null; echo "run $i exit=$?"; done
'
```

Expect: 50–80% runs exit 139 (SIGSEGV); the rest exit 0 with
DebugAllocator leak output (= D-135 surface, distinct from
D-134).
