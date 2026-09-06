// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig); std.process.spawn with no environ_map hands the child this process's environment, so a channel set on this lane reaches it.
//! CLI stdin regression (issue #257): `zwasm run` must hand a core module
//! the process stdin. Spawns the REAL CLI with bytes piped into fd 0 and
//! checks the `stdin_echo.wasm` guest echoes them back (stdout = the bytes,
//! exit code = the byte count), on `--engine interp`, `--engine jit` and the
//! default. A null-device stdin must read as EOF (exit 0, empty stdout).
//!
//! Why a subprocess: the in-process runners build the WASI host themselves;
//! only the CLI's own `main.zig` decides what the guest's fd 0 is.
//!
//! Usage: `zig build test-cli-stdin` /
//!        `zwasm-cli-stdin <zwasm-cli> <stdin_echo.wasm>`

const std = @import("std");

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
        // in the pipe, the same shape as the issue's reproduction.
        try child.stdin.?.writeStreamingAll(io, bytes);
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

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const cli = arg_it.next() orelse return error.MissingCliPath;
    const fixture = arg_it.next() orelse return error.MissingFixturePath;

    const engine_flags: []const []const []const u8 = &.{ &.{}, &.{"--engine=interp"}, &.{"--engine=jit"} };
    var failed: u32 = 0;
    for (engine_flags) |flags| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ cli, "run" });
        try argv.appendSlice(gpa, flags);
        try argv.append(gpa, fixture);
        const label: []const u8 = if (flags.len == 0) "default" else flags[0];

        const piped = try runCli(gpa, io, argv.items, payload);
        defer gpa.free(piped.stdout);
        const piped_ok = piped.exit == payload.len and std.mem.eql(u8, piped.stdout, payload);
        std.debug.print("cli-stdin {s:<15} piped:    exit {d} stdout \"{f}\" {s}\n", .{ label, piped.exit, std.zig.fmtString(piped.stdout), if (piped_ok) "ok" else "FAIL" });

        const eof = try runCli(gpa, io, argv.items, null);
        defer gpa.free(eof.stdout);
        const eof_ok = eof.exit == 0 and eof.stdout.len == 0;
        std.debug.print("cli-stdin {s:<15} no-stdin: exit {d} stdout \"{f}\" {s}\n", .{ label, eof.exit, std.zig.fmtString(eof.stdout), if (eof_ok) "ok" else "FAIL" });

        if (!piped_ok or !eof_ok) failed += 1;
    }
    return if (failed != 0) 1 else 0;
}
