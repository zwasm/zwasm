//! Production fault handler (ADR-0166 diagnostic core + ADR-0202 D2
//! guard-fault→trap redirect).
//!
//! Two dispositions, classified in `faultHandler` / the Windows VEH:
//!
//! 1. **Guard-fault → wasm trap (ADR-0202 D2)**: a SIGSEGV/SIGBUS (or
//!    Win64 ACCESS_VIOLATION) whose fault address lies in a registered
//!    guard-page reservation AND whose PC is registered JIT code is a
//!    linear-memory out-of-bounds — the trap registry resolves the
//!    containing function's kind=6 (oob_memory) stub, the handler
//!    rewrites the context PC to it, and execution RESUMES there (the
//!    stub runs the normal ADR-0199 sticky-flag path → `Error.Trap`).
//! 2. **Unclassified → internal-error exit (ADR-0166)**: any other
//!    fatal signal is a zwasm-INTERNAL bug (v2 emits explicit checks
//!    everywhere elision is off). `installInternalFaultHandler` (called
//!    once from `cli/main.zig` + embedding init) writes a fixed
//!    "internal error" line (async-signal-safe) and `_exit`s with a
//!    DISTINCT code — a diagnosable death, clearly NOT a wasm trap.
//!
//! Distinct from the test runner's `spec_assert_runner_base.
//! installSigsegvHandler`, which classifies first (same D2 path) then
//! siglongjmps for miscompile recovery. Windows landed in ADR-0166
//! cycle II; the VEH gained the D2 branch alongside the POSIX handler.
//!
//! Zone 0 (`src/platform/`).

const builtin = @import("builtin");
const std = @import("std");
const skip = @import("../test_support/skip.zig");
const trap_registry = @import("trap_registry.zig");
const sigcontext = @import("sigcontext.zig");

/// EX_SOFTWARE (sysexits.h) — "an internal software error". Distinct from CLI
/// exit 1 (a clean wasm trap) and from a signal-default death (128+signo), so
/// the three outcomes are unambiguous to a caller / CI.
pub const INTERNAL_ERROR_EXIT_CODE: u8 = 70;

const enabled = builtin.os.tag != .windows and builtin.os.tag != .wasi;

/// Async-signal-safe raw write(2) — POSIX signal-safety(7). The `std.posix.write`
/// wrapper returns an error union (forcing a fallback in a signal context); the
/// raw libc primitive is the canonical async-signal-safe write. ADR-0070
/// necessary (production signal-handler site; same rationale as `_exit`).
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

// Alternate signal stack, ONE PER THREAD (issue #321). `sigaction` is
// process-wide but `sigaltstack` is per-thread state, so the `SA.ONSTACK`
// on the dispositions below is a promise every thread has to keep for
// itself: a stack-overflow SIGSEGV (host-side deep native recursion, cf.
// D-288) needs a stack the handler can run on, on a thread that has just
// run out of its own. `armAltStackForThisThread` keeps that promise on a
// thread's first entry into guarded code.
//
// 32 KiB: the handler allocates nothing and formats nothing (disposition 2
// is a fixed write(2) + `_exit`), so the floor is the platform minimum —
// MINSIGSTKSZ is 32 KiB on Darwin and 2–8 KiB on Linux — not the 256 KiB
// wasmtime sizes for a handler that mallocs a backtrace.
//
// Static TLS, no teardown: the array dies with the thread's TLS block. In
// the window between TLS destruction and the thread's exit no zwasm code
// runs on that thread, so a signal there is not ours to diagnose; a
// pthread_key destructor that SS_DISABLEs first (wasmtime's shape) buys
// nothing for its complexity. Cost: this many bytes of static TLS in
// every thread of the process, armed or not.
const ALT_STACK_SIZE = 1 << 15; // 32 KiB
const min_sigstksz = switch (builtin.os.tag) {
    // `std.c.MINSIGSTKSZ` is unset for Linux; the kernel's value lives here.
    .linux => std.os.linux.MINSIGSTKSZ,
    else => std.posix.system.MINSIGSTKSZ,
};
comptime {
    if (enabled) std.debug.assert(ALT_STACK_SIZE >= min_sigstksz);
}
threadlocal var alt_stack: [ALT_STACK_SIZE]u8 align(16) = undefined;
threadlocal var alt_stack_armed: bool = false;
/// The arm-failure warning fires once per process, not once per thread.
var alt_stack_warned = std.atomic.Value(bool).init(false);

const INTERNAL_ERROR_MSG =
    "zwasm: internal error — caught a fatal signal. This is a bug in zwasm " ++
    "(not a wasm trap); please report it.\n";

fn faultHandler(sig: std.posix.SIG, info: *const std.posix.siginfo_t, uctx: ?*anyopaque) callconv(.c) void {
    // ADR-0202 D2 disposition 1 — classified guard fault: the fault address
    // lies in a registered guarded reservation AND the PC is inside
    // registered JIT code → rewrite the context PC to the containing
    // function's kind=6 (oob_memory) trap stub and RESUME (sigreturn
    // restores the modified context; the stub then runs the normal
    // ADR-0199 sticky-flag path). Async-signal-safe: pure registry reads +
    // one context write. macOS reports guard hits as SIGBUS, Linux as
    // SIGSEGV — classify both; ILL/FPE have no meaningful fault address.
    if (sig == .SEGV or sig == .BUS) {
        if (sigcontext.pcPtr(uctx)) |pc_slot| {
            if (trap_registry.classify(sigcontext.faultAddr(info), pc_slot.*)) |stub| {
                pc_slot.* = stub;
                return;
            }
        }
    }
    // Disposition 2 (unclassified = a zwasm-internal bug, ADR-0166):
    // async-signal-safe only: raw write(2) + `_exit` (skips atexit/stdio). No
    // allocation, no formatting, no recovery — always exits.
    // The fork-recovery test below installs this handler in a child that
    // deliberately faults; under `zig build test` the message would pollute the
    // shared harness stderr (the test asserts the exit code, never the text), so
    // it is comptime-elided in test builds. Production always prints.
    if (!builtin.is_test) _ = write(2, INTERNAL_ERROR_MSG, INTERNAL_ERROR_MSG.len);
    std.c._exit(INTERNAL_ERROR_EXIT_CODE);
}

// Windows (ADR-0166 cycle II): a production diagnostic-only vectored-exception
// handler. Mirrors `windows_traphandler`'s API surface (ntdll VEH, no fresh
// @extern), but — unlike that JIT-trap-RECOVERY VEH — this one is the last-resort
// disposition: on a genuine fault it writes the "internal error" line and
// `ExitProcess(70)` (never returns), instead of resuming. Production-only (NOT
// the test harness), so it never shadows the recovery VEH (which production
// never arms anyway).
const win_impl = if (builtin.os.tag == .windows) struct {
    const win = std.os.windows;
    var veh_handle: ?win.PVOID = null;

    // Zig 0.16's std.os.windows does not expose these kernel32 entry points;
    // declare them per MSDN (mirrors windows_traphandler's MSDN constant decls).
    // kernel32 is the Windows system library, not libc (ADR-0070 does not fire).
    extern "kernel32" fn GetStdHandle(nStdHandle: win.DWORD) callconv(.winapi) win.HANDLE;
    extern "kernel32" fn WriteFile(hFile: win.HANDLE, lpBuffer: [*]const u8, nBytes: win.DWORD, lpWritten: ?*win.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) win.BOOL;
    extern "kernel32" fn ExitProcess(uExitCode: win.UINT) callconv(.winapi) noreturn;
    const STD_ERROR_HANDLE: win.DWORD = @bitCast(@as(i32, -12)); // MSDN

    // MSDN: continue execution at the (possibly modified) context.
    const EXCEPTION_CONTINUE_EXECUTION: c_long = -1;

    fn handler(exception_info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
        const code = exception_info.ExceptionRecord.ExceptionCode;
        // ADR-0202 D2 disposition 1 — classified guard fault → redirect Rip
        // to the containing function's kind=6 trap stub and resume (mirrors
        // the POSIX branch; Rip-rewrite precedent = windows_traphandler.zig
        // ADR-0103). For ACCESS_VIOLATION, ExceptionInformation[1] is the
        // faulting data address (MSDN EXCEPTION_RECORD; [0] = read/write).
        if (code == win.EXCEPTION_ACCESS_VIOLATION and
            exception_info.ExceptionRecord.NumberParameters >= 2)
        {
            const fault_addr: usize = exception_info.ExceptionRecord.ExceptionInformation[1];
            const rip: usize = @intCast(exception_info.ContextRecord.Rip);
            if (trap_registry.classify(fault_addr, rip)) |stub| {
                exception_info.ContextRecord.Rip = stub;
                return EXCEPTION_CONTINUE_EXECUTION;
            }
        }
        switch (code) {
            win.EXCEPTION_ACCESS_VIOLATION,
            win.EXCEPTION_ILLEGAL_INSTRUCTION,
            win.EXCEPTION_DATATYPE_MISALIGNMENT,
            => {
                const h = GetStdHandle(STD_ERROR_HANDLE);
                var written: win.DWORD = 0;
                _ = WriteFile(h, INTERNAL_ERROR_MSG.ptr, @intCast(INTERNAL_ERROR_MSG.len), &written, null);
                ExitProcess(INTERNAL_ERROR_EXIT_CODE);
            },
            // Faults v2 doesn't own (e.g. a host-installed handler's) pass through.
            else => return win.EXCEPTION_CONTINUE_SEARCH,
        }
    }

    fn install() void {
        if (veh_handle != null) return;
        // First = 1 → FRONT of the VEH chain. Registered in main() AFTER Zig's
        // runtime attaches its own (Debug-mode) segfault VEH, so the most-recently-
        // registered First=1 handler — ours — is called first. Without this, Zig's
        // default handler intercepts the fault (prints a trace + exits 3) and ours
        // never runs (it caught exit 3, not our 70, on the test-internal-fault gate).
        // Production-only install → never shadows the (never-armed) JIT-recovery VEH.
        veh_handle = win.ntdll.RtlAddVectoredExceptionHandler(1, &handler);
    }
} else struct {};

/// Install protocol for the process-wide fault handler, folded into ONE
/// atomic so the transient `installing` value doubles as the mutual-
/// exclusion token (Zone 0: `std.atomic` only, no mutex dependency).
///
/// Ordering invariant (issue #320; enforced by the signal-install-order
/// runner): a terminal value (`installed` / `external`) is published
/// with a `.release` store only AFTER the install it describes is
/// complete, and every reader loads with `.acquire` — so a caller that
/// observes a terminal state and returns is guaranteed a complete
/// install happened-before. A caller that observes `installing` waits
/// it out (bounded by the installer's few syscalls) instead of
/// returning handler-less into JIT code.
const InstallState = enum(u8) {
    /// No owner yet; the next `ensureInstalled` elects an installer.
    uninstalled,
    /// An install is in flight; other callers spin until terminal.
    installing,
    /// Our production handler is armed.
    installed,
    /// SOME external handler owns SIGSEGV/SIGBUS — the spec runner's
    /// recovery handler (classifies guard faults first, then
    /// siglongjmp-recovers) — so the engine's auto-install (needed for
    /// elided JIT execution under plain `zig build test`) stands down
    /// and never clobbers it.
    external,
};
var install_state = std.atomic.Value(InstallState).init(.uninstalled);

/// Idempotent auto-install for the JIT invoke path (ADR-0202 D4):
/// guard-page elision REQUIRES a fault handler, so any JIT execution
/// must have one armed. No-op if a handler is already installed
/// (production CLI init, embedding init, or the spec runner); briefly
/// spin-waits while another thread's install is in flight, so a
/// handler is ALWAYS armed by the time this returns.
///
/// Two axes, one call: the process-wide dispositions (the state machine
/// below, once per process) and THIS thread's alternate stack (once per
/// thread, before the state machine — a terminal state says nothing
/// about the calling thread, issue #321).
pub fn ensureInstalled() void {
    armAltStackForThisThread();
    switch (install_state.load(.acquire)) {
        .installed, .external => return,
        .uninstalled => {
            if (install_state.cmpxchgStrong(.uninstalled, .installing, .acquire, .monotonic) == null) {
                installNow();
                install_state.store(.installed, .release);
                return;
            }
            // Lost the election — fall through and wait out the winner.
        },
        .installing => {},
    }
    while (install_state.load(.acquire) == .installing) std.atomic.spinLoopHint();
}

/// Mark SIGSEGV/SIGBUS as owned by an externally-installed handler
/// (the spec runner's recovery handler) so `ensureInstalled` stands
/// down. Call AFTER that handler is in place and before concurrent
/// `ensureInstalled` traffic starts. Called from
/// `spec_assert_runner_base.installSigsegvHandler`.
pub fn markInstalled() void {
    install_state.store(.external, .release);
}

/// FORCE-install the diagnostic-only internal-fault handler NOW — the
/// production last-resort disposition (ADR-0166). Called once at CLI
/// startup (`cli/main.zig`) + embedding init + the fork-recovery
/// tests; installs regardless of prior state, including a marked
/// external owner. No-op install body on wasi. Serializes with any
/// in-flight install and publishes `installed` only after its OWN
/// complete install.
pub fn installInternalFaultHandler() void {
    armAltStackForThisThread();
    while (true) {
        const s = install_state.load(.acquire);
        if (s == .installing) {
            std.atomic.spinLoopHint();
            continue;
        }
        if (install_state.cmpxchgWeak(s, .installing, .acquire, .monotonic) == null) break;
    }
    installNow();
    install_state.store(.installed, .release);
}

/// Arm THIS thread's alternate stack, once per thread. Independent of the
/// process-wide install state, and armed under `external` too: the spec
/// runner's handler carries `SA.ONSTACK` as well, and nothing but an
/// `SA.ONSTACK` handler ever uses an alternate stack, so arming one is
/// never a clobber.
///
/// A thread that already has an alternate stack at least this large keeps
/// it: Zig's start code and `std.Thread.spawn` arm std's 256 KiB one on
/// every thread they start, and the spec runner arms its own. Replacing a
/// larger stack with a smaller one is a downgrade — the process-wide
/// install used to do exactly that to the main thread.
///
/// Failure is not fatal (warned once per process) and not remembered:
/// the guard-fault → trap disposition never touches the alternate stack,
/// so JIT execution on the thread stays sound, and what is lost is the
/// exit-70 diagnosis of a host stack overflow on that one thread until
/// the next entry. The one reachable failure is EPERM — this thread is
/// executing ON an alternate stack right now (the size is checked at
/// comptime, the pointer is ours) — and the next entry from ordinary
/// context succeeds.
fn armAltStackForThisThread() void {
    if (comptime !enabled) return;
    if (alt_stack_armed) return;
    var old: std.posix.stack_t = undefined;
    const has_one = if (std.posix.sigaltstack(null, &old))
        old.flags & std.posix.system.SS.DISABLE == 0 and old.size >= ALT_STACK_SIZE
    else |_|
        false; // the query failed; arm our own below and let that call report
    if (!has_one) {
        std.posix.sigaltstack(&.{
            .sp = &alt_stack,
            .flags = 0,
            .size = ALT_STACK_SIZE,
        }, null) catch |err| {
            if (!alt_stack_warned.swap(true, .monotonic))
                std.debug.print("zwasm: warning: sigaltstack failed ({s}); a host stack overflow on this thread will not be diagnosed\n", .{@errorName(err)});
            return;
        };
    }
    alt_stack_armed = true;
}

/// The platform install body — sigaction (POSIX) or the VEH registration
/// (Windows); the per-thread alternate stack is `armAltStackForThisThread`'s.
/// Writes NO install state: the two pub installers above own the state
/// machine and publish only after this returns.
fn installNow() void {
    if (comptime builtin.os.tag == .windows) {
        win_impl.install();
        return;
    }
    if (comptime !enabled) return;
    var act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = faultHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.ONSTACK | std.posix.SA.SIGINFO,
    };
    std.posix.sigaction(.SEGV, &act, null);
    std.posix.sigaction(.BUS, &act, null);
    std.posix.sigaction(.ILL, &act, null);
    std.posix.sigaction(.FPE, &act, null);
}

test "installInternalFaultHandler: a fault in a forked child exits 70 (handler ran), not a signal-death" {
    // Windows handler = ADR-0166 cycle II; comptime gate also prunes the POSIX
    // fork tail (std.c.fork is not declared on Windows) — mirrors the realworld
    // runner's `if (comptime !use_fork)` pattern.
    if (comptime !enabled) return skip.phaseEnd(.win64);
    // fork the test process: the child installs the handler + deliberately
    // faults; the parent verifies the child EXITED with code 70 (the handler
    // ran + _exit'd cleanly) rather than being killed by the signal (which would
    // be WIFSIGNALED). std.c.fork/waitpid = ADR-0070 necessary (test-only).
    const pid = std.c.fork();
    try std.testing.expect(pid != -1); // fork must succeed on a POSIX test host
    if (pid == 0) {
        installInternalFaultHandler();
        const p: *allowzero volatile u8 = @ptrFromInt(0); // null page → SIGSEGV
        p.* = 0;
        std.c._exit(1); // unreachable if the handler fired
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    try std.testing.expect(std.posix.W.IFEXITED(ustatus));
    try std.testing.expectEqual(@as(u32, INTERNAL_ERROR_EXIT_CODE), std.posix.W.EXITSTATUS(ustatus));
}

// A thread that zwasm did not create (an embedder's pthread, a host thread
// pool) arrives with NO alternate stack. `std.Thread.spawn` arms std's own
// 256 KiB one on every thread it starts, so the two #321 tests below strip it
// first — the kernel state that matters is "SS_DISABLE on this thread", and
// that is what a foreign thread has.
//
// The size and pointer travel with SS_DISABLE even though the kernel ignores
// both: Darwin's libc wrapper (`Libc/compat-43/sigaltstk.c`) returns ENOMEM
// for any new stack smaller than MINSIGSTKSZ before the flag is looked at.
fn disableThisThreadsAltStack() void {
    std.posix.sigaltstack(&.{
        .sp = &alt_stack,
        .flags = std.posix.system.SS.DISABLE,
        .size = ALT_STACK_SIZE,
    }, null) catch unreachable;
}

test "ensureInstalled: a thread that arrives with no alternate stack leaves with one of its own (#321)" {
    if (comptime !enabled) return skip.phaseEnd(.win64);
    // Drive the process-wide state to terminal on THIS thread first, so the
    // probe thread below exercises the per-thread arm alone, not the one-time
    // install (which arms whichever thread happens to win the election).
    ensureInstalled();
    var main_ss: std.posix.stack_t = undefined;
    try std.posix.sigaltstack(null, &main_ss);
    const Probe = struct {
        fn run(out: *std.posix.stack_t) void {
            disableThisThreadsAltStack();
            ensureInstalled();
            std.posix.sigaltstack(null, out) catch unreachable;
        }
    };
    var got: std.posix.stack_t = undefined;
    const t = try std.Thread.spawn(.{}, Probe.run, .{&got});
    t.join();
    try std.testing.expect(got.flags & std.posix.system.SS.DISABLE == 0);
    try std.testing.expect(got.size >= ALT_STACK_SIZE);
    try std.testing.expect(got.sp != main_ss.sp);
}

// Host-side native recursion, never inlined, never tail-called: the volatile
// write keeps the frame, the call keeps the depth. The frame is kept SMALLER
// than a guard page on purpose: a frame that steps over the guard in one go
// lands its first touch in whatever is mapped below, and the kernel can then
// push a signal frame there — the death this test is after never happens.
// A small frame faults with the stack pointer INSIDE the guard page, where
// no signal frame fits without an alternate stack.
fn overflowHostStack(depth: usize) usize {
    var frame: [256]u8 = undefined;
    const slot: *volatile u8 = &frame[depth % frame.len];
    slot.* = @truncate(depth);
    return @call(.never_inline, overflowHostStack, .{depth + 1}) +% slot.*;
}

fn overflowOnBareThread() void {
    disableThisThreadsAltStack();
    ensureInstalled();
    _ = overflowHostStack(0);
}

test "installInternalFaultHandler: a host stack overflow on a second thread exits 70, not a signal death (#321)" {
    if (comptime !enabled) return skip.phaseEnd(.win64);
    // Same fork shape as the test above. The child arms the handler on its
    // main thread the way the CLI does, then a second thread — armed only by
    // the JIT entry path's `ensureInstalled` — overflows its host stack. The
    // handler needs stack on a thread that has just run out of it; without a
    // per-thread alternate stack the kernel cannot deliver and the child dies
    // by the signal (WIFSIGNALED), the exit-70 contract of ADR-0166 lost.
    const pid = std.c.fork();
    try std.testing.expect(pid != -1);
    if (pid == 0) {
        installInternalFaultHandler();
        const t = std.Thread.spawn(.{}, overflowOnBareThread, .{}) catch std.c._exit(2);
        t.join();
        std.c._exit(1); // unreachable if the handler fired
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    try std.testing.expect(std.posix.W.IFEXITED(ustatus));
    try std.testing.expectEqual(@as(u32, INTERNAL_ERROR_EXIT_CODE), std.posix.W.EXITSTATUS(ustatus));
}
