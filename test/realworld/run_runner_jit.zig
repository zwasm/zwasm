//! Realworld JIT compile-baseline runner (§9.7 / 7.9 chunk a).
//!
//! Walks `test/realworld/wasm/` and, for each `.wasm` fixture,
//! invokes `engine.runner.compileWasm` (= the JIT pipeline:
//! parse → validate → lower → liveness → regalloc → arm64/x86_64
//! emit → linker.link). Reports per-fixture compile outcome
//! categorised:
//!
//!   COMPILE-PASS    — `compileWasm` returned a `JitModule`.
//!                     Module body fully encoded by the host's
//!                     JIT backend.
//!   COMPILE-IMPORTS — `error.UnsupportedImport`. The wasm
//!                     module imports at least one host
//!                     function (typically WASI).
//!   COMPILE-OP      — `error.UnsupportedOp`. Module compiles
//!                     past parse + validate but the JIT emit
//!                     pass rejects an op.
//!   COMPILE-VAL     — validator rejection — orthogonal to the
//!                     JIT gate; queued as a separate gap.
//!   FAIL-OTHER      — any other error class (real bug).
//!
//! **This runner measures compilation only, by design.** Whether
//! JIT-emitted code computes the right answer is measured by
//! `zig build test-realworld-diff-jit` (`diff_runner.zig --jit`),
//! which runs each fixture through the WASI-aware `--engine jit`
//! path and byte-diffs stdout against wasmtime. Read the two
//! together: this runner says the backend encoded every fixture,
//! the diff lane says the encoding was correct.
//!
//! A run stage used to live here behind `ZWASM_JIT_RUN=1`. It
//! invoked `_start` through `runVoidExport`, which attaches NO
//! WASI host, so every fixture reaching `fd_write` / `proc_exit`
//! "trapped" — a property of the harness, not of the JIT (the
//! same fixtures run correctly under the real `--engine jit`).
//! It was removed once the diff lane landed as its replacement;
//! `.dev/lessons/2026-06-14-jit-realworld-runtraps-are-null-wasi-harness-artifacts.md`
//! records why a JIT run harness measuring correctness must wire
//! a WASI host or diff against a reference.
//!
//! Mirror of `test/realworld/run_runner.zig`'s shape (interp
//! mode); shares the corpus walk + categorisation idiom.
//!
//! Usage:
//!   zig build test-realworld-run-jit       # walks test/realworld/wasm/
//!   realworld_run_jit_runner_exe <corpus-dir>

const std = @import("std");

const zwasm = @import("zwasm");
const engine_runner = zwasm.engine.runner;

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
        try stdout.print("usage: run_runner_jit <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_dir = try gpa.dupe(u8, corpus_dir_arg);
    defer gpa.free(corpus_dir);

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_dir, @errorName(err) });
        try stdout.flush();
        std.process.exit(2);
    };
    defer dir.close(io);

    var total: u32 = 0;
    var compile_pass: u32 = 0;
    var compile_imports: u32 = 0;
    var compile_op: u32 = 0;
    var compile_val: u32 = 0;
    var fail_other: u32 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;
        total += 1;

        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(64 << 20)) catch |err| {
            try stdout.print("FAIL-OTHER  {s}: read error {s}\n", .{ entry.name, @errorName(err) });
            fail_other += 1;
            continue;
        };
        defer gpa.free(bytes);

        const result = engine_runner.compileWasm(gpa, bytes);
        if (result) |compiled_const| {
            var compiled = compiled_const;
            compiled.deinit(gpa);
            compile_pass += 1;
            try stdout.print("COMPILE-PASS  {s}\n", .{entry.name});
        } else |err| switch (err) {
            error.UnsupportedImport => {
                try stdout.print("COMPILE-IMPORTS  {s} (host imports)\n", .{entry.name});
                compile_imports += 1;
            },
            error.UnsupportedOp,
            error.UnsupportedControlFlow,
            // SlotOverflow = regalloc pool exhaustion (post-MVP spill ratchet,
            // ROADMAP §A12), surfaces same shape as UnsupportedOp in the
            // COMPILE classification.
            error.SlotOverflow,
            => {
                try stdout.print("COMPILE-OP  {s}: {s}\n", .{ entry.name, @errorName(err) });
                compile_op += 1;
            },
            error.StackTypeMismatch,
            error.ArityMismatch,
            error.InvalidLocalIndex,
            error.StackUnderflow,
            error.InvalidFuncIndex,
            error.InvalidGlobalIndex,
            error.BadValType,
            error.UnsupportedEntrySignature,
            // Realworld fixtures with malformed (per our validator) func-types.
            // Some go binaries use multi-value sigs that the v2 validator
            // pre-decodes strictly; the spec requires it but our InvalidFunctype
            // shape may be tightening a check beyond strict need.
            error.InvalidFunctype,
            => {
                try stdout.print("COMPILE-VAL  {s}: {s}\n", .{ entry.name, @errorName(err) });
                compile_val += 1;
            },
            else => {
                try stdout.print("FAIL-OTHER  {s}: {s}\n", .{ entry.name, @errorName(err) });
                fail_other += 1;
            },
        }
    }

    try stdout.print(
        "\nrealworld_run_jit_runner: {d}/{d} compile-pass, {d} compile-imports, {d} compile-op, {d} compile-val, {d} fail-other (compile only — execution is gated by test-realworld-diff-jit)\n",
        .{ compile_pass, total, compile_imports, compile_op, compile_val, fail_other },
    );
    try stdout.flush();

    // Compile categorisation is informational: an import / op / validator gap is
    // a known-shape gap tracked elsewhere, not a regression this runner owns.
    // fail-other is a real bug; it does fail the gate.
    if (fail_other != 0) std.process.exit(1);
}
