// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig).
//! `zwasm run`'s option parsing, observed from outside (#236, #232). Options
//! precede the module path, so an unknown one is a usage error (exit 2) — not
//! a module path that cannot be read (exit 1) — and `--` ends them. Anything
//! after the path is the guest's argv, even when it spells a known option.
//! And which engine runs a SIMD module, said where the run fails (#597).
//! `--timeout` fires while the guest sleeps in `poll_oneoff` (#598).
//! An f32 param with three results is refused by the JIT, not misread (#618).
//! A component reaches the host's network only with `--allow-network`.
//!
//! Usage: `zig build test-cli-usage` /
//!        `zwasm-cli-usage <zwasm-cli> <module.wasm> <argv_echo.wasm>
//!         <simd_op.wasm> <simd_jit_decline.wasm> <select_v128_spilled_val2.wasm>
//!         <poll_sleep.wasm> <f32_param_three_results.wasm>
//!         <wasi_p2_tcp_rust.wasm>`

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

/// Stand-ins for the module paths, in argument order: a `_start` that does
/// nothing, one that echoes argv[1..] a line each, one SIMD op, a SIMD module
/// the JIT declines, #596's select, a 5 s sleep in `poll_oneoff`, #618's
/// `(f32) -> (i32 i32 i32)`, and a Rust wasip2 TCP client.
const M = "<module>";
const E = "<argv_echo>";
const S = "<simd_op>";
const D = "<simd_jit_decline>";
const V = "<select_spill>";
const P = "<poll_sleep>";
const F = "<f32_three>";
const T = "<tcp_client>";
const placeholders = [_][]const u8{ M, E, S, D, V, P, F, T };

const rows = [_]Row{
    .{ .args = &.{ "run", "--bogus", M }, .exit = 2, .stderr = .{ .has = "unknown option '--bogus'" } },
    .{ .args = &.{ "run", "-bogus", M }, .exit = 2, .stderr = .{ .has = "unknown option '-bogus'" } },
    .{ .args = &.{ "run", "--invok", "add", M }, .exit = 2, .stderr = .{ .has = "unknown option '--invok'" } },
    .{ .args = &.{ "run", "--invoke", "--bogus", M }, .exit = 2, .stderr = .{ .has = "usage: zwasm run --invoke" } },
    .{ .args = &.{ "run", "--dir", "--bogus", M }, .exit = 2, .stderr = .{ .has = "usage: zwasm run --dir" } },
    .{ .args = &.{ "run", "--", M }, .exit = 0 },
    .{ .args = &.{ "run", E, "--engine", "jit" }, .exit = 0, .stdout = .{ .is = "--engine\njit\n" }, .stderr = .{ .is = "" } },
    .{ .args = &.{"--help"}, .exit = 0, .stdout = .{ .has = "run [options]" } },
    .{ .args = &.{ "run", "--engine", "interp", S }, .exit = 1, .stderr = .{ .has = "the interpreter does not execute `v128.const`" } },
    .{ .args = &.{ "run", D }, .exit = 1, .stderr = .{ .has = "`return_call` with a 3-result callee\nthe interpreter does not execute `v128.const`" } },
    .{ .args = &.{ "run", "--invoke", "test", V }, .exit = 0, .stdout = .{ .is = "63\n" } },
    .{ .args = &.{ "run", "--timeout", "500", "--engine", "interp", P }, .exit = 1, .stderr = .{ .has = "interrupted" } },
    .{ .args = &.{ "run", "--timeout", "500", "--engine", "jit", P }, .exit = 1, .stderr = .{ .has = "interrupted" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "f=2.5", F }, .exit = 0, .stdout = .{ .is = "7\n250\n2500\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "f=2.5", F }, .exit = 1, .stderr = .{ .has = "unsupported entry signature" } },
    .{ .args = &.{ "run", "--invoke", "f=2.5", F }, .exit = 1, .stderr = .{ .has = "unsupported" } },
    // Nothing listens on loopback port 1, so a granted connect is refused by
    // the peer; a listener row would hang on accept once the gate broke.
    .{ .args = &.{ "run", T, "1" }, .exit = 1, .stderr = .{ .has = "connect failed: Os { code: 2, kind: PermissionDenied" } },
    .{ .args = &.{ "run", "--allow-network", T, "1" }, .exit = 1, .stderr = .{ .has = "connect failed: Os { code: 14, kind: ConnectionRefused" } },
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const cli = arg_it.next() orelse return error.MissingCliPath;
    var paths: [placeholders.len][]const u8 = undefined;
    for (&paths) |*p| p.* = arg_it.next() orelse return error.MissingModulePath;
    try spawned_cli.assertRunnerBuildMode(gpa, io, cli);

    var failed: u32 = 0;
    for (rows) |row| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, cli);
        for (row.args) |a| {
            const path = for (placeholders, paths) |ph, p| {
                if (std.mem.eql(u8, a, ph)) break p;
            } else a;
            try argv.append(gpa, path);
        }

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
