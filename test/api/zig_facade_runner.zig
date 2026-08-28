//! Tier-2 fixture-enumeration runner for the native Zig API per
//! ADR-0109 §J.6 + `phase10_zig_api_plan.md` §3 J.6.
//!
//! Walks a corpus directory, drives each `.wasm` fixture through
//! the zwasm v2 native facade (`Engine.compile` → `Module.instantiate`),
//! and reports an outcome category. Pairs with the existing
//! `realworld/run_runner.zig` (c_api path) so the same fixture set
//! exercises both surfaces; divergences surface as count drift.
//!
//! Outcome categories:
//!   PASS         — `Engine.compile` + `Module.instantiate` succeed.
//!                  No host imports needed, or all imports satisfied
//!                  by the no-op Linker.
//!   SKIP-WASI    — fixture imports from `wasi_snapshot_preview1`;
//!                  `Linker.defineWasi` lands at J.7 (D-176).
//!   SKIP-IMPORTS — fixture imports from a non-WASI module the
//!                  runner has no recipe for (out of v0.1 scope).
//!   FAIL-PARSE   — `Engine.compile` returned `error.ParseFailed`.
//!   FAIL-INST    — `Module.instantiate` returned a binding /
//!                  validator error after parse succeeded.
//!
//! Exit codes:
//!   0 — no FAIL-* outcomes (PASS + SKIP-* combinations are OK).
//!   1 — at least one FAIL-* outcome.
//!   2 — corpus directory unreachable or argv error.
//!
//! Usage:
//!   zig build test-api-zig-facade        # walks test/realworld/wasm/
//!   zwasm-zig-facade-runner <corpus-dir>

const std = @import("std");

const zwasm = @import("zwasm");

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
        try stdout.print("usage: zwasm-zig-facade-runner <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_dir = try gpa.dupe(u8, corpus_dir_arg);
    defer gpa.free(corpus_dir);

    var passed: u32 = 0;
    var skip_wasi: u32 = 0;
    var skip_imports: u32 = 0;
    var failed: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_dir, @errorName(err) });
        try stdout.flush();
        std.process.exit(2);
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;

        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(4 << 20)) catch |err| {
            try stdout.print("FAIL-PARSE  {s}: read error {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer gpa.free(bytes);

        const outcome = runFixture(gpa, bytes);
        switch (outcome) {
            .pass => {
                passed += 1;
                try stdout.print("PASS         {s}\n", .{entry.name});
            },
            .skip_wasi => {
                skip_wasi += 1;
                try stdout.print("SKIP-WASI    {s}: WASI import name not in lookupWasiThunk (Phase 11 / D-177)\n", .{entry.name});
            },
            .skip_imports => {
                skip_imports += 1;
                try stdout.print("SKIP-IMPORTS {s}: non-WASI host imports out of v0.1 facade scope\n", .{entry.name});
            },
            .fail_parse => |err_name| {
                failed += 1;
                try stdout.print("FAIL-PARSE   {s}: {s}\n", .{ entry.name, err_name });
            },
            .fail_inst => |err_name| {
                failed += 1;
                try stdout.print("FAIL-INST    {s}: {s}\n", .{ entry.name, err_name });
            },
        }
    }

    try stdout.print(
        "\n[zig_facade_runner] {} PASS, {} SKIP-WASI, {} SKIP-IMPORTS, {} FAIL\n",
        .{ passed, skip_wasi, skip_imports, failed },
    );
    try stdout.flush();
    if (failed > 0) std.process.exit(1);
}

const Outcome = union(enum) {
    pass,
    /// Reserved for fixtures whose WASI requirements remain
    /// outside v0.1 facade scope after J.7 (e.g. preopens land
    /// at Phase 11). No fixture currently routes here, but the
    /// runner keeps the variant so re-classification can happen
    /// without an Outcome-shape change.
    skip_wasi,
    skip_imports,
    fail_parse: []const u8,
    fail_inst: []const u8,
};

fn runFixture(alloc: std.mem.Allocator, bytes: []const u8) Outcome {
    // Pre-scan import section to classify the fixture. WASI imports
    // route through `Linker.defineWasi` (J.7); non-WASI host imports
    // are out of v0.1 facade scope.
    var needs_wasi = false;
    if (preScanImports(alloc, bytes)) |class| switch (class) {
        .none => {},
        .wasi => needs_wasi = true,
        .non_wasi => return .skip_imports,
    } else |_| {
        // Pre-scan parser failure surfaces as FAIL-PARSE in the
        // subsequent compile call.
    }

    var eng = zwasm.Engine.init(alloc, .{}) catch return .{ .fail_inst = "Engine.init OOM" };
    defer eng.deinit();

    var mod = eng.compile(bytes) catch |err| return .{ .fail_parse = @errorName(err) };
    defer mod.deinit();

    if (needs_wasi) {
        var lk = zwasm.Linker.init(&eng);
        defer lk.deinit();
        lk.defineWasi(.{}) catch return .{ .fail_inst = "defineWasi OOM" };
        var inst = lk.instantiate(&mod, .{}) catch |err| switch (err) {
            error.UnsupportedWasiImport => return .skip_wasi,
            else => return .{ .fail_inst = @errorName(err) },
        };
        defer inst.deinit();
        return .pass;
    }

    var inst = mod.instantiate(.{}) catch |err| return .{ .fail_inst = @errorName(err) };
    defer inst.deinit();
    return .pass;
}

const ImportClass = enum { none, wasi, non_wasi };

fn preScanImports(alloc: std.mem.Allocator, bytes: []const u8) !ImportClass {
    var native = try zwasm.parse.parser.parse(alloc, bytes);
    defer native.deinit(alloc);

    const imp_sec = native.find(.import) orelse return .none;
    var decoded = try zwasm.parse.sections.decodeImports(alloc, imp_sec.body);
    defer decoded.deinit();
    if (decoded.items.len == 0) return .none;

    var saw_non_wasi = false;
    for (decoded.items) |it| {
        if (std.mem.eql(u8, it.module, "wasi_snapshot_preview1")) return .wasi;
        saw_non_wasi = true;
    }
    return if (saw_non_wasi) .non_wasi else .none;
}
