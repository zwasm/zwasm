// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig); std.process.spawn with no environ_map hands the child this process's environment, so a channel set on this lane reaches it.
//! CLI argv[0] regression (issue #256): `zwasm run <path>` must hand the
//! guest the wasm file's BASE NAME as argv[0], matching wasmtime, whatever
//! path the CLI was given. Spawns the REAL CLI on `argv0_echo.wasm` by its
//! absolute path and by a relative path with a directory component (native
//! separator, so Windows exercises `\`), and checks stdout is the base name.
//!
//! Why a subprocess: the in-process runners choose argv[0] themselves; only
//! the CLI's own `main.zig` builds it from the path. Why both shapes: the
//! bug is invisible from the fixture's own directory, where path == base
//! name. One engine suffices — argv is built before the engine is chosen.
//!
//! Usage: `zig build test-cli-argv0` /
//!        `zwasm-cli-argv0 <zwasm-cli> </abs/path/to/argv0_echo.wasm>`

const std = @import("std");

const Observed = struct { stdout: []u8, exit: u8 };

fn runCli(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd) !Observed {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);
    var rd_buf: [4096]u8 = undefined;
    var rd = child.stdout.?.reader(io, &rd_buf);
    const out = try rd.interface.allocRemaining(gpa, .limited(64 * 1024));
    const term = try child.wait(io);
    return .{ .stdout = out, .exit = switch (term) {
        .exited => |c| c,
        else => 255,
    } };
}

fn check(gpa: std.mem.Allocator, io: std.Io, label: []const u8, cli: []const u8, path: []const u8, cwd: std.process.Child.Cwd, want: []const u8) !bool {
    const got = try runCli(gpa, io, &.{ cli, "run", path }, cwd);
    defer gpa.free(got.stdout);
    const ok = got.exit == 0 and std.mem.eql(u8, got.stdout, want);
    std.debug.print("cli-argv0 {s:<9} {s}: exit {d} stdout \"{f}\" {s}\n", .{ label, path, got.exit, std.zig.fmtString(got.stdout), if (ok) "ok" else "FAIL" });
    return ok;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    // The build runner hands the CLI as a cache-relative path; the relative
    // case changes the child's cwd, so resolve it once here.
    const cli = try std.Io.Dir.cwd().realPathFileAlloc(io, arg_it.next() orelse return error.MissingCliPath, gpa);
    defer gpa.free(cli);
    const fixture = arg_it.next() orelse return error.MissingFixturePath;
    if (!std.Io.Dir.path.isAbsolute(fixture)) return error.FixturePathNotAbsolute;

    const want = std.Io.Dir.path.basename(fixture);
    const parent = std.Io.Dir.path.dirname(fixture) orelse return error.FixturePathNotAbsolute;
    const grandparent = std.Io.Dir.path.dirname(parent) orelse return error.FixturePathNotAbsolute;
    // `<parent-dir-name>/<file>`, run from the grandparent: a relative path
    // that still carries a directory component.
    const relative = try std.Io.Dir.path.join(gpa, &.{ std.Io.Dir.path.basename(parent), want });
    defer gpa.free(relative);

    var failed: u32 = 0;
    if (!try check(gpa, io, "absolute", cli, fixture, .inherit, want)) failed += 1;
    if (!try check(gpa, io, "relative", cli, relative, .{ .path = grandparent }, want)) failed += 1;
    return if (failed != 0) 1 else 0;
}
