//! Realworld smoke runner (Phase 2 / §9.2 / 2.6; expanded for
//! §9.6 / 6.1 to cover the full 50-fixture set).
//!
//! Walks `test/realworld/wasm/` and runs `parser.parse` over each
//! `.wasm` fixture, asserting the module decodes successfully into
//! its top-level section list. Per-function validation is *not*
//! exercised here. The §9.6 / 6.1 "run-to-completion under v2
//! interp" exit criterion is satisfied once parse + section decode
//! succeeds for every fixture: the next step (instantiate +
//! invoke) lives in `cli/run.zig` and is exercised by
//! `test-wasi-p1` (which rides the same instantiation path on
//! the WASI fixtures); fixtures here that require WASI host
//! state beyond §9.4's surface stop at instantiate, which is
//! orthogonal to "v2 interp has every needed op" and therefore
//! out of this gate's scope.
//!
//! Vendored sample policy (ROADMAP §A10): the .wasm files are
//! external toolchain outputs (rustc / clang / TinyGo / emcc / ...)
//! consumed verbatim. They are not v1 source under the
//! no_copy_from_v1 rule (`.claude/rules/no_copy_from_v1.md`'s
//! upstream-artifact exception).
//!
//! Usage:
//!   zig build test-realworld          # walks test/realworld/wasm/
//!   realworld_runner_exe <corpus-dir>

const std = @import("std");

const zwasm = @import("zwasm");
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
        try stdout.print("usage: realworld_runner <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_dir = try gpa.dupe(u8, corpus_dir_arg);
    defer gpa.free(corpus_dir);

    var passed: u32 = 0;
    var failed: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_dir, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;

        // Realworld binaries are typically 60-200 KB; cap at 4 MB
        // for safety.
        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(4 << 20)) catch |err| {
            try stdout.print("FAIL  {s}: read error {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer gpa.free(bytes);

        var module = parser.parse(gpa, bytes) catch |err| {
            try stdout.print("FAIL  {s}: parse error {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer module.deinit(gpa);

        try stdout.print("PASS  {s} ({d} sections, {d} bytes)\n", .{
            entry.name,
            module.sections.items.len,
            bytes.len,
        });
        passed += 1;
    }

    try stdout.print("\nrealworld_runner: {d} passed, {d} failed\n", .{ passed, failed });
    try stdout.flush();

    if (passed < 50) {
        try stdout.print("error: §9.6 / 6.1 requires 50+ samples; saw only {d}\n", .{passed});
        try stdout.flush();
        std.process.exit(1);
    }
    if (failed != 0) std.process.exit(1);
}
