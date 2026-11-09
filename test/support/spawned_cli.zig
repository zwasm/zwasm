//! What a runner that reaches the engine as a SPAWNED BINARY can settle about
//! it by asking (D-598).
//!
//! `scripts/check_releasesafe_runners.sh` holds the ADR-0177 ReleaseSafe floor
//! by grepping `build.zig` for the two channels its author had in mind — the
//! module import and the `addArtifactArg` spawn. A third spelling (an
//! installed `zig-out` path, `addSystemCommand`, a shell wrapper around the
//! CLI) is invisible to it again, and it would report OK while a corpus runner
//! drove the Debug binary for months, which is what happened once already
//! (issue #284). The grep stays — it names the fix at the line that needs
//! changing, before anything is built. This says what actually ran.

const std = @import("std");
const build_options = @import("build_options");

/// The mode the runners' CLI (`exe_rs`) is actually built at — NOT a fixed
/// `ReleaseSafe`. `runner_optimize` floors Debug at ReleaseSafe and passes any
/// other `-Doptimize` through (build.zig `runner_engine_optimize`, ADR-0209),
/// so `zig build test-all -Doptimize=ReleaseFast` hands these lanes a
/// ReleaseFast CLI and that IS the artifact the build selected. Reading the
/// floor as the literal string would red every optimized invocation.
const want_mode = @tagName(build_options.runner_engine_optimize);

/// Refuse to measure anything if the CLI about to be driven is not the build
/// the wiring was supposed to hand over. Called ONCE, before the corpus loop:
/// one binary answers for every fixture.
pub fn assertRunnerBuildMode(gpa: std.mem.Allocator, io: std.Io, exe_path: []const u8) !void {
    const result = try std.process.run(gpa, io, .{ .argv = &.{ exe_path, "--version" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (saysMode(result.stdout, want_mode)) return;
    std.debug.print("WRONG-BUILD-MODE  {s}: --version says \"{f}\", which is not `mode: {s}` (ADR-0177 floor, D-598)\n", .{
        exe_path, std.zig.fmtString(std.mem.trimEnd(u8, result.stdout, "\r\n")), want_mode,
    });
    return error.WrongBuildMode;
}

/// Ends a spawned child still running after `seconds`, so a lane fails instead
/// of hanging. It signals the id raw: `Child.kill` also reaps, and stays the
/// spawning thread's. The watcher thread is detached and may outlive the
/// caller's frame, so the state is heap-held and freed by whichever of
/// `disarm` and the watcher lets go last.
pub const Watchdog = struct {
    io: std.Io,
    id: std.process.Child.Id,
    seconds: u64,
    done: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u8) = .init(2),

    pub fn start(io: std.Io, id: std.process.Child.Id, seconds: u64) !*Watchdog {
        const self = try std.heap.page_allocator.create(Watchdog);
        self.* = .{ .io = io, .id = id, .seconds = seconds };
        const thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            std.heap.page_allocator.destroy(self);
            return err;
        };
        thread.detach();
        return self;
    }

    /// Call before the child is reaped; the watchdog is gone afterwards.
    pub fn disarm(self: *Watchdog) void {
        self.done.store(true, .release);
        self.release();
    }

    fn run(self: *Watchdog) void {
        defer self.release();
        self.io.sleep(.{ .nanoseconds = @as(i96, self.seconds) * std.time.ns_per_s }, .awake) catch return;
        if (self.done.load(.acquire)) return;
        switch (@import("builtin").os.tag) {
            .windows => {
                const k32 = struct {
                    extern "kernel32" fn TerminateProcess(h: std.os.windows.HANDLE, code: std.os.windows.UINT) callconv(.winapi) c_int;
                };
                _ = k32.TerminateProcess(self.id, 1);
            },
            else => std.posix.kill(self.id, .KILL) catch {},
        }
    }

    fn release(self: *Watchdog) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.page_allocator.destroy(self);
    }
};

/// The needle carries the line's closing paren, so a mode never matches a
/// longer one it is a prefix of.
fn saysMode(version_output: []const u8, want: []const u8) bool {
    var buf: [64]u8 = undefined;
    const needle = std.mem.print(&buf, "mode: {s})", .{want}) catch return false;
    return std.mem.find(u8, version_output, needle) != null;
}

test "saysMode: reads the mode field, and a prefix of a longer mode is not it" {
    const t = std.testing;
    try t.expect(saysMode("zwasm v2.7.0 (wasm: v3_0, wasi: p2, engine: both, mode: safe)\n", "safe"));
    try t.expect(!saysMode("zwasm v2.7.0 (wasm: v3_0, wasi: p2, engine: both, mode: debug)\n", "safe"));
    try t.expect(!saysMode("zwasm v2.7.0 (wasm: v3_0, wasi: p2, engine: both, mode: safe)\n", "saf"));
    // A CLI from before the field existed answers the question with a no.
    try t.expect(!saysMode("zwasm v2.7.0 (wasm: v3_0, wasi: p2, engine: both)\n", "safe"));
}
