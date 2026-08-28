//! Fuzz loader (§14.3 / D-256 MVP).
//!
//! Walks a corpus directory and feeds each file's raw bytes through
//! the two host-reachable decode paths:
//!   1. `parser.parse` — structural decode (section list).
//!   2. `Engine.compile` — parse + frontend validation (the public
//!      native compile path).
//!
//! The contract: arbitrary bytes are EXPECTED to be rejected — a
//! parse/validate error return is a legitimate outcome, NOT a finding.
//! A real bug is a process-level CRASH (panic / `unreachable` / SEGV /
//! OOM-loop / hang) on malformed input. A single-process loader cannot
//! `catch` a panic, so detection is external: if any corpus file
//! crashes a decode path, this process dies and `zig build test-fuzz`
//! sees the non-zero/signal exit. Completing the whole corpus without
//! crashing => exit 0.
//!
//! Usage:
//!   zig build test-fuzz                 # walks test/fuzz/corpus/seed/
//!   zwasm-fuzz-loader <corpus-dir>
//!
//! Full campaigns (a larger, gitignored `wasm-tools smith` corpus)
//! run on demand via `zig build fuzz-campaign` (automation retired
//! with nightly.yml — ADR-0211 D1, revival hints in D-593); this
//! smoke gate runs the committed seed corpus so the toolchain-free
//! test hosts can execute it (no `wasm-tools` at run time).

const std = @import("std");

const zwasm = @import("zwasm");
const parser = zwasm.parse.parser;
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
        try stdout.print("usage: zwasm-fuzz-loader <corpus-dir>\n", .{});
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

    var processed: u32 = 0;
    var compiled: u32 = 0;
    var rejected: u32 = 0;
    var instantiated: u32 = 0;
    var jit_compiled: u32 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;

        // Fuzz inputs are small modules; cap at 1 MiB. A truncated read
        // is a host I/O issue, not a fuzz finding — skip it.
        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20)) catch |err| {
            try stdout.print("SKIP  {s}: read error {s}\n", .{ entry.name, @errorName(err) });
            continue;
        };
        defer gpa.free(bytes);
        processed += 1;

        // Path 1: structural parse in isolation. An error return is an
        // expected reject; on success free the section list.
        if (parser.parse(gpa, bytes)) |m| {
            var parsed = m;
            parsed.deinit(gpa);
        } else |_| {
            // Expected: malformed bytes rejected with a parse error.
        }

        // Path 2: parse + frontend validation via the public compile.
        // Fresh Engine per input keeps store state from cross-contaminating.
        var eng = zwasm.Engine.init(gpa, .{}) catch {
            try stdout.print("SKIP  {s}: engine init OOM\n", .{entry.name});
            continue;
        };
        if (eng.compile(bytes)) |mod| {
            var compiled_mod = mod;
            compiled += 1;
            // Path 3: instantiation (interp) — memory/table/global init +
            // the start function (the native Instance dispatches through
            // `interp/`, so no host->JIT / D-245 exposure). Missing imports
            // or a start-trap are expected rejects; a crash is a finding.
            if (compiled_mod.instantiate(.{})) |inst| {
                var instance = inst;
                instance.deinit();
                instantiated += 1;
            } else |_| {
                // Expected: unsatisfied imports / start trap / resource limit.
            }
            // Path 4: JIT codegen. The smith corpus exercises unusual-but-valid
            // module shapes the spec / realworld corpora don't (deep nesting,
            // dense locals, odd control flow); a CRASH in the JIT pipeline
            // (parse → IR → regalloc → emit → link) is a finding. `UnsupportedOp`
            // (unimplemented op) + other compile errors are graceful — only a
            // panic / unreachable / SEGV is caught (externally, by this process
            // dying). Compile-only: imports get trap trampolines, no host needed.
            // Name the module on stderr before the JIT pipeline so a codegen
            // PANIC/SEGV (no Zig-catchable handler) is attributable to a specific
            // corpus file, not anonymous.
            std.debug.print("JIT-COMPILE {s}\n", .{entry.name});
            if (engine_runner.compileWasm(gpa, bytes)) |jit_mod| {
                var jc = jit_mod;
                jc.deinit(gpa);
                jit_compiled += 1;
            } else |_| {
                // Expected: UnsupportedOp / unsatisfiable import / resource limit.
            }
            compiled_mod.deinit();
        } else |_| {
            rejected += 1;
        }
        eng.deinit();
    }

    // Reaching here means no input crashed a decode path.
    try stdout.print(
        "\nfuzz_loader: {d} processed, {d} compiled ({d} interp-instantiated, {d} JIT-compiled), {d} rejected, 0 crashes\n",
        .{ processed, compiled, instantiated, jit_compiled, rejected },
    );
    try stdout.flush();

    if (processed == 0) {
        try stdout.print("error: empty corpus '{s}'\n", .{corpus_dir});
        try stdout.flush();
        std.process.exit(1);
    }
}
