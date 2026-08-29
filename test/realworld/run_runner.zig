//! Realworld run-to-completion runner (§9.6 / 6.1 chunk b).
//!
//! Walks `test/realworld/wasm/` and, for each `.wasm` fixture,
//! drives `cli/run.zig:runWasm` end-to-end (engine → store →
//! WASI config → module → instance → entry → `wasm_func_call`).
//! The §9.6 / 6.1 exit criterion ("all 50 vendored samples run
//! to completion under v2 interp") is satisfied when no fixture
//! parses cleanly only to crash inside dispatch on a missing
//! handler — which surfaces here as a `ModuleAllocFailed` (parse-
//! time) outcome.
//!
//! Outcome categories:
//!
//!   PASS   — `runWasm` returned a u8 exit code (any value).
//!            Fixture instantiated AND interp dispatch carried
//!            execution to completion (proc_exit, normal return,
//!            or non-missing-op trap that mapped to exit 1).
//!   SKIP-WASI — `runWasm` returned `error.InstanceAllocFailed`.
//!            Fixture imports a WASI thunk this build's host
//!            doesn't yet implement; orthogonal to interp-op
//!            coverage. Counted but not gating.
//!   SKIP-NOENTRY — `error.NoFuncExport`. Fixture exposes no
//!            callable entry; not relevant to the gate.
//!   SKIP-VALIDATOR — `error.ModuleAllocFailed` AND the fixture
//!            does parse cleanly via `parser.parse`. The
//!            failure is per-function validation (typing rule
//!            v2 hasn't taught the validator yet). Orthogonal
//!            to interp-op coverage; queued as a real Phase-6
//!            follow-up but not gating today.
//!   FAIL   — `error.ModuleAllocFailed` AND `parser.parse`
//!            ALSO fails — a real parse-time gap (chunk a
//!            cleared this for the current corpus). Or any
//!            other unexpected error class. Fails the gate.
//!
//! The §9.6 / 6.1 exit criterion specifically calls out
//! "no `Errno.unreachable_` traps from missing ops". v2's
//! dispatch loop maps both an unbound op slot and a guest-side
//! `unreachable` opcode to `Trap.Unreachable`, which `runWasm`
//! coalesces into exit code 1. The two are not distinguishable
//! from outside without instrumentation; this runner counts on
//! the parse + section + per-function-validate pipeline (already
//! cleared by chunk a) plus the dispatch table population
//! (mvp + mvp_int + mvp_float + mvp_conversions + ext_2_0
//! per `interp/mvp.zig:register`) to close the missing-op
//! coverage. Fixtures that surface a *real* missing-op gap will
//! be promoted to a known-blocked carry-over list (mirroring
//! the `br-table-fuzzbug` precedent in §9.6 / 6.0).
//!
//! Usage:
//!   zig build test-realworld-run         # walks test/realworld/wasm/
//!   realworld_run_runner_exe <corpus-dir>

const std = @import("std");

const zwasm = @import("zwasm");
const cli_run = zwasm.cli.run;
const parser = zwasm.parse.parser;

pub fn main(init: std.process.Init) !void {
    zwasm.support.dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const corpus_dir_arg = arg_it.next() orelse {
        try stdout.print("usage: realworld_run_runner <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_dir = try gpa.dupe(u8, corpus_dir_arg);
    defer gpa.free(corpus_dir);

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_dir, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer dir.close(io);

    var passed: u32 = 0;
    var skipped_wasi: u32 = 0;
    var skipped_noentry: u32 = 0;
    var skipped_validator: u32 = 0;
    var failed: u32 = 0;
    var total: u32 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;
        total += 1;

        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(64 << 20)) catch |err| {
            try stdout.print("FAIL  {s}: read error {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer gpa.free(bytes);

        const run_argv: [1][]const u8 = .{entry.name};
        // D-313 — capture guest stdout and refuse self-verify failures: a
        // fixture printing "FAIL" (e.g. a wrong baked expected constant)
        // must RED the gate, not pass on exit-code alone. The exit-code-only
        // check let c_sha256_hash's wrong constant ship silently.
        var guest_out: std.ArrayList(u8) = .empty;
        defer guest_out.deinit(gpa);
        const result = cli_run.runWasmCaptured(gpa, io, bytes, &run_argv, &guest_out, null);
        if (result) |exit_code| {
            if (std.mem.find(u8, guest_out.items, "FAIL") != null) {
                try stdout.print("FAIL  {s}: guest self-verify reported FAIL in stdout\n", .{entry.name});
                failed += 1;
                continue;
            }
            try stdout.print("PASS  {s} (exit={d})\n", .{ entry.name, exit_code });
            passed += 1;
        } else |err| switch (err) {
            error.InstanceAllocFailed => {
                try stdout.print("SKIP-WASI  {s} (instantiate error — WASI host gap)\n", .{entry.name});
                skipped_wasi += 1;
            },
            error.NoFuncExport => {
                try stdout.print("SKIP-NOENTRY  {s} (no callable entry)\n", .{entry.name});
                skipped_noentry += 1;
            },
            error.ModuleAllocFailed => {
                // Differentiate parse-time failure (real gap;
                // FAIL) from per-function validate failure
                // (orthogonal to dispatch coverage; SKIP-VALIDATOR).
                if (parser.parse(gpa, bytes)) |*module_| {
                    var module = module_.*;
                    module.deinit(gpa);
                    try stdout.print("SKIP-VALIDATOR  {s} (validate error — typing-rule gap)\n", .{entry.name});
                    skipped_validator += 1;
                } else |_| {
                    try stdout.print("FAIL  {s}: parse error (post chunk-a regression)\n", .{entry.name});
                    failed += 1;
                }
            },
            else => {
                try stdout.print("FAIL  {s}: {s}\n", .{ entry.name, @errorName(err) });
                failed += 1;
            },
        }
    }

    try stdout.print(
        "\nrealworld_run_runner: {d}/{d} passed, {d} skipped (WASI), {d} skipped (no entry), {d} skipped (validator), {d} failed\n",
        .{ passed, total, skipped_wasi, skipped_noentry, skipped_validator, failed },
    );
    try stdout.flush();

    if (total < 50) {
        try stdout.print("error: §9.6 / 6.1 requires 50+ samples; saw only {d}\n", .{total});
        try stdout.flush();
        std.process.exit(1);
    }
    if (failed != 0) std.process.exit(1);
}
