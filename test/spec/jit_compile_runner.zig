//! JIT-compile spec corpus runner (§9.7 / 7.5 first sub-chunk).
//!
//! Walks one or more corpus directories; for each `.wasm` file
//! runs it through `engine.runner.compileWasm` (the full
//! parse → validate → ZIR lower → regalloc → ARM64 emit
//! pipeline) and reports whether each fixture compiles.
//!
//! Compile success proves the byte-level emit pass landed in
//! 7.7 actually handles every op the fixture contains. It does
//! NOT yet prove execution correctness — that is the next
//! 7.5 sub-chunk (assertion driver).
//!
//! Mac aarch64 only (the linker assumes the host arch matches
//! the emit backend). Other hosts skip with a banner; the
//! `test-spec-jit-compile` build step gates accordingly.
//!
//! Usage:
//!   zwasm-spec-jit-compile <corpus-dir> [<more-dirs>...]

const std = @import("std");
const builtin = @import("builtin");

const zwasm = @import("zwasm");
const run_wasm = zwasm.engine.runner;

pub fn main(init: std.process.Init) !void {
    zwasm.support.dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        try stdout.print("spec-jit-compile runner: skipped (Mac aarch64 only)\n", .{});
        try stdout.flush();
        return;
    }

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?; // executable name

    var passed: u32 = 0;
    var failed: u32 = 0;

    while (arg_it.next()) |corpus_dir| {
        try walkAndCompile(io, gpa, stdout, corpus_dir, &passed, &failed);
    }

    try stdout.print("\nspec-jit-compile runner: {d} passed, {d} failed\n", .{ passed, failed });
    try stdout.flush();
    if (failed != 0) std.process.exit(1);
}

fn walkAndCompile(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    root_path: []const u8,
    passed: *u32,
    failed: *u32,
) !void {
    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, root_path, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ root_path, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry_| {
        if (entry_.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry_.path, ".wasm")) continue;

        const wasm_bytes = root.readFileAlloc(io, entry_.path, gpa, .limited(1 << 20)) catch |err| {
            try stdout.print("FAIL  {s}: read .wasm: {s}\n", .{ entry_.path, @errorName(err) });
            failed.* += 1;
            continue;
        };
        defer gpa.free(wasm_bytes);

        if (run_wasm.compileWasm(gpa, wasm_bytes)) |compiled_const| {
            var compiled = compiled_const;
            compiled.deinit(gpa);
            try stdout.print("PASS  {s}\n", .{entry_.path});
            passed.* += 1;
        } else |err| {
            try stdout.print("FAIL  {s}: {s}\n", .{ entry_.path, @errorName(err) });
            failed.* += 1;
        }
    }
}
