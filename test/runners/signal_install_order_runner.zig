//! Regression runner for the fault-handler install/publish protocol of
//! `src/platform/signal.zig` (issue #320).
//!
//! Contract under test: when `ensureInstalled` (or the force-install
//! entry `installInternalFaultHandler`) returns, a complete handler
//! install is observable — the SEGV/BUS dispositions are no longer the
//! process-start baseline. A caller that returns while the baseline is
//! still active has observed the publish-before-install window; that is
//! the ordering defect behind the intermittent SIGBUS deaths under
//! concurrent instantiation (guard-page elision REQUIRES an armed
//! handler before any JIT execution, ADR-0202 D4).
//!
//! Why a standalone exe: the install flag is process-global and sticky,
//! and any earlier in-process JIT invoke arms it via `ensureInstalled`
//! — no test inside a shared test binary can rely on a virgin flag.
//! Here the parent process never touches signal state and forks one
//! child per scenario iteration, so every child inherits a pristine
//! flag. Zig's own segfault handler is disabled below so the fork-time
//! baseline disposition is SIG_DFL, not the std.debug handler.
//!
//! The race itself is intermittent, so scenario failures are amplified
//! (N racer threads released by a spin barrier × ITERATIONS forks) and
//! detection is by sigaction READBACK after each racer returns — any
//! return-before-install is caught, fault or no fault. The stand-down
//! and force-install scenarios are single-threaded and deterministic.
//!
//! Deliberately NOT asserted here: sigaltstack arming, which is
//! per-thread and tracked separately (issue #321).
//!
//! Windows: fork is unavailable; the runner self-skips (exit 0). The
//! publish-after-install path is shared with the win_impl branch but is
//! not exercised here. fork/waitpid/_exit = ADR-0070 necessary
//! (test-only), mirroring `signal.zig`'s fork test.

const std = @import("std");
const builtin = @import("builtin");
const signal = @import("zwasm").platform.signal;

pub const std_options: std.Options = .{ .enable_segfault_handler = false };

const RACERS = 4;
const ITERATIONS = 40;

const EXIT_OK = 0;
const EXIT_VIOLATION = 9;
const EXIT_INFRA = 12;

const Scenario = enum { ensure_race, mixed_race, stand_down, force_install };
const Outcome = enum { ok, violation, infra };

/// Current disposition of `sig` as a comparable integer. The
/// `.handler`/`.sigaction` union members alias the same storage in the
/// C sigaction layout, so one read covers both forms.
fn disposition(sig: std.posix.SIG) usize {
    var old: std.posix.Sigaction = undefined;
    std.posix.sigaction(sig, null, &old);
    return @intFromPtr(old.handler.handler);
}

const RaceCtx = struct {
    go: std.atomic.Value(bool),
    violations: std.atomic.Value(u32),
    base_segv: usize,
    base_bus: usize,
    mixed: bool,
};

fn racer(ctx: *RaceCtx, idx: usize) void {
    while (!ctx.go.load(.acquire)) std.atomic.spinLoopHint();
    if (ctx.mixed and idx == 0)
        signal.installInternalFaultHandler()
    else
        signal.ensureInstalled();
    // Readback AFTER return: the contract is "a handler is armed once
    // this returns". Observing the fork-time baseline here means the
    // call returned inside the publish-before-install window.
    if (disposition(.SEGV) == ctx.base_segv or disposition(.BUS) == ctx.base_bus)
        _ = ctx.violations.fetchAdd(1, .monotonic);
}

fn raceChild(mixed: bool) noreturn {
    var ctx: RaceCtx = .{
        .go = std.atomic.Value(bool).init(false),
        .violations = std.atomic.Value(u32).init(0),
        .base_segv = disposition(.SEGV),
        .base_bus = disposition(.BUS),
        .mixed = mixed,
    };
    var threads: [RACERS]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < RACERS) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, racer, .{ &ctx, spawned }) catch break;
    }
    // Release even on partial spawn so no racer spins forever; the
    // partial run is discarded as an infra failure either way.
    ctx.go.store(true, .release);
    for (threads[0..spawned]) |t| t.join();
    if (spawned != RACERS) std.c._exit(EXIT_INFRA);
    std.c._exit(if (ctx.violations.load(.acquire) != 0) EXIT_VIOLATION else EXIT_OK);
}

fn standDownChild() noreturn {
    const base = disposition(.SEGV);
    signal.markInstalled();
    signal.ensureInstalled();
    // External ownership: ensureInstalled must NOT touch the disposition.
    std.c._exit(if (disposition(.SEGV) != base) EXIT_VIOLATION else EXIT_OK);
}

fn forceChild() noreturn {
    const base = disposition(.SEGV);
    signal.markInstalled();
    signal.installInternalFaultHandler();
    // The direct entry stays a FORCE install (CLI startup semantics),
    // even after an external owner was marked.
    std.c._exit(if (disposition(.SEGV) == base) EXIT_VIOLATION else EXIT_OK);
}

fn runOne(scenario: Scenario) Outcome {
    const pid = std.c.fork();
    if (pid == -1) return .infra;
    if (pid == 0) {
        switch (scenario) {
            .ensure_race => raceChild(false),
            .mixed_race => raceChild(true),
            .stand_down => standDownChild(),
            .force_install => forceChild(),
        }
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    if (!std.posix.W.IFEXITED(ustatus)) return .infra;
    return switch (std.posix.W.EXITSTATUS(ustatus)) {
        EXIT_OK => .ok,
        EXIT_VIOLATION => .violation,
        else => .infra,
    };
}

pub fn main() u8 {
    if (comptime builtin.os.tag == .windows) {
        std.debug.print("signal-install-order: SKIP (fork unavailable on Windows; shared publish path unexercised here)\n", .{});
        return 0;
    }
    var ensure_v: u32 = 0;
    var mixed_v: u32 = 0;
    var infra: u32 = 0;
    for (0..ITERATIONS) |_| switch (runOne(.ensure_race)) {
        .violation => ensure_v += 1,
        .infra => infra += 1,
        .ok => {},
    };
    for (0..ITERATIONS) |_| switch (runOne(.mixed_race)) {
        .violation => mixed_v += 1,
        .infra => infra += 1,
        .ok => {},
    };
    const stand_down = runOne(.stand_down);
    const force_install = runOne(.force_install);
    if (stand_down == .infra or force_install == .infra) infra += 1;

    std.debug.print(
        "signal-install-order: ensure-race {d}/{d} mixed-race {d}/{d} stand-down {s} force-install {s} infra {d}\n",
        .{
            ensure_v,             ITERATIONS,
            mixed_v,              ITERATIONS,
            @tagName(stand_down), @tagName(force_install),
            infra,
        },
    );
    const failed = ensure_v != 0 or mixed_v != 0 or
        stand_down != .ok or force_install != .ok or infra != 0;
    return if (failed) 1 else 0;
}
