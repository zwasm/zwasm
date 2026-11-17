// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig).
//! `zwasm run`'s option parsing, observed from outside (#236, #232). Options
//! precede the module path, so an unknown one is a usage error (exit 2) — not
//! a module path that cannot be read (exit 1) — and `--` ends them. Anything
//! after the path is the guest's argv, even when it spells a known option.
//! And which engine runs a SIMD module, said where the run fails (#597).
//! `--timeout` fires while the guest sleeps in `poll_oneoff` (#598).
//! An f32 param with three results is refused by the JIT, not misread (#618).
//! A component reaches the host's network only with `--allow-network`.
//! A catch clause whose label is a loop branches to the loop's header (#369).
//! An `if` whose then-arm ends in `unreachable` returns the else arm's value
//! on every engine (#739). A block that closes short of its f64 result
//! before any vreg exists traps on every engine (#399).
//!
//! Usage: `zig build test-cli-usage` /
//!        `zwasm-cli-usage <zwasm-cli> <module.wasm> <argv_echo.wasm>
//!         <simd_op.wasm> <simd_jit_decline.wasm> <select_v128_spilled_val2.wasm>
//!         <poll_sleep.wasm> <f32_param_three_results.wasm>
//!         <wasi_p2_tcp_rust.wasm> <catch_to_loop.wasm>
//!         <catch_to_loop_ref_result.wasm> <catch_to_loop_params.wasm>
//!         <catch_to_loop_unset_params.wasm> <if_dead_then_arm.wasm>
//!         <short_frame_f64.wasm>`

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
/// `(f32) -> (i32 i32 i32)`, a Rust wasip2 TCP client, #369's catch clauses
/// that target a loop (without params, with a result, with params, and with a
/// param the stack never held a value for), #739's two `if`s, and #399's block.
const M = "<module>";
const E = "<argv_echo>";
const S = "<simd_op>";
const D = "<simd_jit_decline>";
const V = "<select_spill>";
const P = "<poll_sleep>";
const F = "<f32_three>";
const T = "<tcp_client>";
const L = "<catch_to_loop>";
const R = "<catch_to_loop_ref_result>";
const Q = "<catch_to_loop_params>";
const U = "<catch_to_loop_unset_params>";
const I = "<if_dead_then>";
const B = "<short_frame>";
const placeholders = [_][]const u8{ M, E, S, D, V, P, F, T, L, R, Q, U, I, B };

const all_engines = [_][]const []const u8{ &.{ "--engine", "interp" }, &.{ "--engine", "jit" }, &.{} };
/// The interpreter traps on some loops with params (#244).
const jit_engines = all_engines[1..];

/// `run --invoke <name> <module>` on each engine, each printing `out`.
fn onEngines(comptime engines: []const []const []const u8, comptime module: []const u8, comptime name: []const u8, comptime out: []const u8) [engines.len]Row {
    var r: [engines.len]Row = undefined;
    for (engines, &r) |e, *row| row.* = .{ .args = &(.{"run"} ++ e[0..e.len].* ++ .{ "--invoke", name, module }), .exit = 0, .stdout = .{ .is = out } };
    return r;
}

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
    // A catch whose loop param the stack never held a value for: the JIT once
    // declined it (the param was the placeholder vreg), but since #399 the
    // frame mints a real vreg for it, so the JIT runs the shape and traps on
    // the `unreachable` it reaches, as the interpreter does.
    .{ .args = &.{ "run", "--engine", "interp", U }, .exit = 1, .stderr = .{ .has = "trap kind=unreachable_" } },
    .{ .args = &.{ "run", "--engine", "jit", U }, .exit = 1, .stderr = .{ .has = "trap kind=unreachable_" } },
    .{ .args = &.{ "run", U }, .exit = 1, .stderr = .{ .has = "trap kind=unreachable_" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "else_arm=0", I }, .exit = 0, .stdout = .{ .is = "-2\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "else_arm=0", I }, .exit = 0, .stdout = .{ .is = "-2\n" } },
    .{ .args = &.{ "run", "--invoke", "else_arm=0", I }, .exit = 0, .stdout = .{ .is = "-2\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "ref_result=0", I }, .exit = 0, .stdout = .{ .is = "47\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "ref_result=0", I }, .exit = 0, .stdout = .{ .is = "47\n" } },
    .{ .args = &.{ "run", "--invoke", "ref_result=0", I }, .exit = 0, .stdout = .{ .is = "47\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "param_else=0", I }, .exit = 0, .stdout = .{ .is = "45\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "param_else=0", I }, .exit = 0, .stdout = .{ .is = "45\n" } },
    .{ .args = &.{ "run", "--invoke", "param_else=0", I }, .exit = 0, .stdout = .{ .is = "45\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "param_else_only=0", I }, .exit = 0, .stdout = .{ .is = "15\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "param_else_only=0", I }, .exit = 0, .stdout = .{ .is = "15\n" } },
    .{ .args = &.{ "run", "--invoke", "param_else_only=0", I }, .exit = 0, .stdout = .{ .is = "15\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "implicit_else=0", I }, .exit = 0, .stdout = .{ .is = "-2\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "implicit_else=0", I }, .exit = 0, .stdout = .{ .is = "-2\n" } },
    .{ .args = &.{ "run", "--invoke", "implicit_else=0", I }, .exit = 0, .stdout = .{ .is = "-2\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "f", B }, .exit = 1, .stderr = .{ .has = "kind=unreachable" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "f", B }, .exit = 1, .stderr = .{ .has = "kind=unreachable" } },
    .{ .args = &.{ "run", "--invoke", "f", B }, .exit = 1, .stderr = .{ .has = "kind=unreachable" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "else_short=1", B }, .exit = 0, .stdout = .{ .is = "17\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "else_short=1", B }, .exit = 0, .stdout = .{ .is = "17\n" } },
    .{ .args = &.{ "run", "--invoke", "else_short=1", B }, .exit = 0, .stdout = .{ .is = "17\n" } },
    .{ .args = &.{ "run", "--engine", "interp", "--invoke", "else_unreachable=1", B }, .exit = 0, .stdout = .{ .is = "115\n" } },
    .{ .args = &.{ "run", "--engine", "jit", "--invoke", "else_unreachable=1", B }, .exit = 0, .stdout = .{ .is = "115\n" } },
    .{ .args = &.{ "run", "--invoke", "else_unreachable=1", B }, .exit = 0, .stdout = .{ .is = "115\n" } },
} ++ onEngines(&all_engines, L, "catch_to_loop", "3\n") ++
    onEngines(&all_engines, L, "catch_to_block", "1\n") ++
    onEngines(&all_engines, L, "catch_all_to_loop", "3\n") ++
    onEngines(&all_engines, L, "catch_to_outer_loop", "3\n") ++
    onEngines(&all_engines, R, "test", "42\n") ++
    onEngines(jit_engines, Q, "payload_to_loop", "3\n") ++
    onEngines(jit_engines, Q, "f64_payload_to_loop", "4.5\n") ++
    onEngines(&all_engines, Q, "catch_ref_to_loop", "10\n") ++ [_]Row{
    // The pad's back-edge poll stops a loop re-entered only through its catch;
    // without it the run ends after 10^8 iterations and prints the count.
    .{ .args = &.{ "run", "--timeout", "500", "--engine", "jit", "--invoke", "catch_all_spin=100000000", L }, .exit = 1, .stderr = .{ .has = "interrupted" } },
    .{ .args = &.{ "run", "--fuel", "100000", "--engine", "jit", "--invoke", "catch_all_spin=100000000", L }, .exit = 1, .stderr = .{ .has = "all fuel consumed" } },
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
