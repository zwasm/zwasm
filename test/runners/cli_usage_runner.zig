// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig).
//! `zwasm run`'s option parsing, observed from outside (#236, #232). Options
//! precede the module path, so an unknown one is a usage error (exit 2) — not
//! a module path that cannot be read (exit 1) — and `--` ends them. Anything
//! after the path is the guest's argv, even when it spells a known option.
//!
//! Usage: `zig build test-cli-usage` /
//!        `zwasm-cli-usage <zwasm-cli> <module.wasm> <argv_echo.wasm>`

const std = @import("std");
const spawned_cli = @import("spawned_cli");

const Match = union(enum) {
    any,
    has: []const u8,
    is: []const u8,

    fn ok(m: Match, s: []const u8) bool {
        return switch (m) {
            .any => true,
            .has => |n| std.mem.find(u8, s, n) != null,
            .is => |e| std.mem.eql(u8, s, e),
        };
    }
};

const Row = struct {
    args: []const []const u8,
    exit: u8,
    stdout: Match = .any,
    stderr: Match = .any,
};

/// Stand-ins for the two module paths: a `_start` that does nothing, and one
/// that echoes argv[1..] a line each.
const M = "<module>";
const E = "<argv_echo>";

const rows = [_]Row{
    .{ .args = &.{ "run", "--bogus", M }, .exit = 2, .stderr = .{ .has = "unknown option '--bogus'" } },
    .{ .args = &.{ "run", "-bogus", M }, .exit = 2, .stderr = .{ .has = "unknown option '-bogus'" } },
    .{ .args = &.{ "run", "--invok", "add", M }, .exit = 2, .stderr = .{ .has = "unknown option '--invok'" } },
    .{ .args = &.{ "run", "--invoke", "--bogus", M }, .exit = 2, .stderr = .{ .has = "usage: zwasm run --invoke" } },
    .{ .args = &.{ "run", "--dir", "--bogus", M }, .exit = 2, .stderr = .{ .has = "usage: zwasm run --dir" } },
    .{ .args = &.{ "run", "--", M }, .exit = 0 },
    .{ .args = &.{ "run", E, "--engine", "jit" }, .exit = 0, .stdout = .{ .is = "--engine\njit\n" }, .stderr = .{ .is = "" } },
    .{ .args = &.{"--help"}, .exit = 0, .stdout = .{ .has = "run [options]" } },
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const cli = arg_it.next() orelse return error.MissingCliPath;
    const module = arg_it.next() orelse return error.MissingModulePath;
    const argv_echo = arg_it.next() orelse return error.MissingArgvEchoPath;
    try spawned_cli.assertRunnerBuildMode(gpa, io, cli);

    var failed: u32 = 0;
    for (rows) |row| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, cli);
        for (row.args) |a| try argv.append(gpa, if (std.mem.eql(u8, a, M)) module else if (std.mem.eql(u8, a, E)) argv_echo else a);

        const result = try std.process.run(gpa, io, .{ .argv = argv.items });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        const exit: u8 = switch (result.term) {
            .exited => |c| c,
            else => 255,
        };
        const ok = exit == row.exit and row.stdout.ok(result.stdout) and row.stderr.ok(result.stderr);
        if (!ok) failed += 1;
        const shown = try std.mem.join(gpa, " ", row.args);
        defer gpa.free(shown);
        std.debug.print("cli-usage {s:<4} {s:<40} exit {d} (want {d}) stdout \"{f}\" stderr \"{f}\"\n", .{
            if (ok) "ok" else "FAIL",
            shown,
            exit,
            row.exit,
            std.zig.fmtString(result.stdout[0..@min(result.stdout.len, 40)]),
            std.zig.fmtString(std.mem.trimEnd(u8, result.stderr, "\n")),
        });
    }
    std.debug.print("cli-usage: {d} rows, {d} failed\n", .{ rows.len, failed });
    return if (failed != 0) 1 else 0;
}
