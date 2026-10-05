// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig); std.process.spawn with no environ_map hands the child this process's environment, so a channel set on this lane reaches it.
//! CLI stdin regression (issues #257, #494, #508): `zwasm run` must hand a
//! core module AND a component the process stdin, and must not call it a tty.
//! Spawns the REAL CLI with bytes piped into fd 0 and checks that the
//! `stdin_echo.wasm` guest echoes them back (stdout = the bytes, exit code =
//! the byte count), that the `stdin_echo_p2.wasm` component echoes them too
//! (stdout = the bytes, exit 0), and that the `fdstat_stdio.wasm` guest sees
//! neither fd 0 nor fd 1 as a character device (stdout "00"), on
//! `--engine interp`, `--engine jit` and the default. A null-device stdin must
//! read as EOF (exit 0, empty stdout) and is not a tty either. Three more rows
//! on the default engine keep the component path honest about the pipe: the
//! echo answers while the writer still holds stdin open (no read-to-EOF), a
//! 65 MiB payload goes through whole (no size cap), and `stdin_read_p2.wasm`'s
//! first non-blocking `read` on an empty open pipe is ok(empty), not a wait.
//!
//! Why a subprocess: the in-process runners build the WASI host themselves;
//! only the CLI's own `main.zig` decides what the guest's fd 0 is.
//!
//! Usage: `zig build test-cli-stdin` /
//!        `zwasm-cli-stdin <zwasm-cli> <stdin_echo.wasm> <fdstat_stdio.wasm> <stdin_echo_p2.wasm> <stdin_read_p2.wasm>`

const std = @import("std");
const spawned_cli = @import("spawned_cli");

const payload = "hello\n";

const Observed = struct { stdout: []u8, exit: u8 };

fn runCli(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, stdin: ?[]const u8) !Observed {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);
    if (stdin) |bytes| {
        // Written and closed before the guest can read: the bytes already sit
        // in the pipe, the same shape as the issue's reproduction. A guest
        // that never reads fd 0 (`fdstat_stdio`) may have exited already, and
        // the write then fails with EPIPE; the exit code and stdout decide.
        child.stdin.?.writeStreamingAll(io, bytes) catch |err| switch (err) {
            error.BrokenPipe => {},
            else => return err,
        };
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var rd_buf: [4096]u8 = undefined;
    var rd = child.stdout.?.reader(io, &rd_buf);
    const out = try rd.interface.allocRemaining(gpa, .limited(64 * 1024));
    const term = try child.wait(io);
    return .{ .stdout = out, .exit = switch (term) {
        .exited => |c| c,
        else => 255,
    } };
}

/// Writer side of a live pipe, on its own thread so the parent can drain the
/// child's stdout meanwhile: both pipes are 64 KiB deep, so one thread doing
/// both deadlocks on any payload past that.
fn feedStdin(io: std.Io, file: std.Io.File, bytes: []const u8) void {
    file.writeStreamingAll(io, bytes) catch {};
}

/// Terminates the child if the row has not finished in time, so a host that
/// waits where it must not fails the row instead of hanging the lane. It holds
/// a copy of the id and signals it raw: `Child.kill` also reaps, and the main
/// thread's own `wait` / `kill` must stay the only caller of those.
const Watchdog = struct {
    io: std.Io,
    id: std.process.Child.Id,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *Watchdog) void {
        self.io.sleep(.{ .nanoseconds = 30 * std.time.ns_per_s }, .awake) catch {};
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
};

/// Spawn the CLI with stdin held open, and read exactly `bytes.len` bytes of
/// stdout BEFORE the writer closes: the guest must answer from a live pipe.
/// `handshake` first reads one byte of stdout before writing anything.
fn runCliLive(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, bytes: []const u8, handshake: bool) !Observed {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
    defer child.kill(io);
    var wd: Watchdog = .{ .io = io, .id = child.id.? };
    const wd_thread = try std.Thread.spawn(.{}, Watchdog.run, .{&wd});
    wd_thread.detach();
    defer wd.done.store(true, .release);

    var rd_buf: [64 * 1024]u8 = undefined;
    var rd = child.stdout.?.reader(io, &rd_buf);
    const out = try gpa.alloc(u8, bytes.len + @as(usize, if (handshake) 1 else 0));
    errdefer gpa.free(out);
    if (handshake) try rd.interface.readSliceAll(out[0..1]);
    const writer = try std.Thread.spawn(.{}, feedStdin, .{ io, child.stdin.?, bytes });
    try rd.interface.readSliceAll(out[if (handshake) 1 else 0..]);
    writer.join();
    child.stdin.?.close(io);
    child.stdin = null;
    const rest = try rd.interface.allocRemaining(gpa, .limited(1024));
    defer gpa.free(rest);
    const term = try child.wait(io);
    return .{ .stdout = out, .exit = if (rest.len != 0) 254 else switch (term) {
        .exited => |c| c,
        else => 255,
    } };
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const cli = arg_it.next() orelse return error.MissingCliPath;
    const echo_fixture = arg_it.next() orelse return error.MissingFixturePath;
    const fdstat_fixture = arg_it.next() orelse return error.MissingFixturePath;
    const echo_p2_fixture = arg_it.next() orelse return error.MissingFixturePath;
    const read_p2_fixture = arg_it.next() orelse return error.MissingFixturePath;
    try spawned_cli.assertRunnerBuildMode(gpa, io, cli);

    const engine_flags: []const []const []const u8 = &.{ &.{}, &.{"--engine=interp"}, &.{"--engine=jit"} };
    var failed: u32 = 0;
    for (engine_flags) |flags| {
        const label: []const u8 = if (flags.len == 0) "default" else flags[0];

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ cli, "run" });
        try argv.appendSlice(gpa, flags);
        try argv.append(gpa, echo_fixture);

        const piped = try runCli(gpa, io, argv.items, payload);
        defer gpa.free(piped.stdout);
        const piped_ok = piped.exit == payload.len and std.mem.eql(u8, piped.stdout, payload);
        std.debug.print("cli-stdin {s:<15} piped:    exit {d} stdout \"{f}\" {s}\n", .{ label, piped.exit, std.zig.fmtString(piped.stdout), if (piped_ok) "ok" else "FAIL" });

        const eof = try runCli(gpa, io, argv.items, null);
        defer gpa.free(eof.stdout);
        const eof_ok = eof.exit == 0 and eof.stdout.len == 0;
        std.debug.print("cli-stdin {s:<15} no-stdin: exit {d} stdout \"{f}\" {s}\n", .{ label, eof.exit, std.zig.fmtString(eof.stdout), if (eof_ok) "ok" else "FAIL" });

        // #494: a pipe and the null device are not ttys, and the runner's
        // stdout is a pipe too; the guest must print "00" for fds 0 and 1.
        argv.items[argv.items.len - 1] = fdstat_fixture;

        const piped_fdstat = try runCli(gpa, io, argv.items, payload);
        defer gpa.free(piped_fdstat.stdout);
        const piped_fdstat_ok = piped_fdstat.exit == 0 and std.mem.eql(u8, piped_fdstat.stdout, "00");
        std.debug.print("cli-fdstat {s:<15} piped:    exit {d} stdout \"{f}\" {s}\n", .{ label, piped_fdstat.exit, std.zig.fmtString(piped_fdstat.stdout), if (piped_fdstat_ok) "ok" else "FAIL" });

        const null_fdstat = try runCli(gpa, io, argv.items, null);
        defer gpa.free(null_fdstat.stdout);
        const null_fdstat_ok = null_fdstat.exit == 0 and std.mem.eql(u8, null_fdstat.stdout, "00");
        std.debug.print("cli-fdstat {s:<15} no-stdin: exit {d} stdout \"{f}\" {s}\n", .{ label, null_fdstat.exit, std.zig.fmtString(null_fdstat.stdout), if (null_fdstat_ok) "ok" else "FAIL" });

        // #508: the component host reads the same stdin on demand; the echo
        // twin returns ok, so exit 0 with the bytes on stdout, and EOF on null.
        argv.items[argv.items.len - 1] = echo_p2_fixture;

        const piped_p2 = try runCli(gpa, io, argv.items, payload);
        defer gpa.free(piped_p2.stdout);
        const piped_p2_ok = piped_p2.exit == 0 and std.mem.eql(u8, piped_p2.stdout, payload);
        std.debug.print("cli-stdin-p2 {s:<13} piped:    exit {d} stdout \"{f}\" {s}\n", .{ label, piped_p2.exit, std.zig.fmtString(piped_p2.stdout), if (piped_p2_ok) "ok" else "FAIL" });

        const eof_p2 = try runCli(gpa, io, argv.items, null);
        defer gpa.free(eof_p2.stdout);
        const eof_p2_ok = eof_p2.exit == 0 and eof_p2.stdout.len == 0;
        std.debug.print("cli-stdin-p2 {s:<13} no-stdin: exit {d} stdout \"{f}\" {s}\n", .{ label, eof_p2.exit, std.zig.fmtString(eof_p2.stdout), if (eof_p2_ok) "ok" else "FAIL" });

        if (!piped_ok or !eof_ok or !piped_fdstat_ok or !null_fdstat_ok or !piped_p2_ok or !eof_p2_ok) failed += 1;

        if (flags.len != 0) continue; // the pipe rows below do not depend on the engine

        const live = try runCliLive(gpa, io, argv.items, payload, false);
        defer gpa.free(live.stdout);
        const live_ok = live.exit == 0 and std.mem.eql(u8, live.stdout, payload);
        std.debug.print("cli-stdin-p2 {s:<13} live:     exit {d} stdout \"{f}\" {s}\n", .{ label, live.exit, std.zig.fmtString(live.stdout), if (live_ok) "ok" else "FAIL" });

        const big = try gpa.alloc(u8, 65 * 1024 * 1024);
        defer gpa.free(big);
        for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
        const large = try runCliLive(gpa, io, argv.items, big, false);
        defer gpa.free(large.stdout);
        const large_ok = large.exit == 0 and std.mem.eql(u8, large.stdout, big);
        std.debug.print("cli-stdin-p2 {s:<13} 65 MiB:   exit {d} {d} bytes back {s}\n", .{ label, large.exit, large.stdout.len, if (large_ok) "ok" else "FAIL" });

        argv.items[argv.items.len - 1] = read_p2_fixture;
        const nb = try runCliLive(gpa, io, argv.items, payload, true);
        defer gpa.free(nb.stdout);
        const nb_ok = nb.exit == 0 and nb.stdout.len == payload.len + 1 and nb.stdout[0] == 'E' and std.mem.eql(u8, nb.stdout[1..], payload);
        std.debug.print("cli-stdin-p2 {s:<13} read():   exit {d} stdout \"{f}\" {s}\n", .{ label, nb.exit, std.zig.fmtString(nb.stdout), if (nb_ok) "ok" else "FAIL" });

        if (!live_ok or !large_ok or !nb_ok) failed += 1;
    }
    return if (failed != 0) 1 else 0;
}
