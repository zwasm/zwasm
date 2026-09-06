// DBG-INIT-EXEMPT: manual D-489 isolation harness (zig build d489-repro), in no test lane — the guard exists for lanes whose channels went dark unnoticed, and this one is run by hand for a single investigation.
//! Minimal D-489 repro — isolates WHY tinygo_json's JIT output is correct (90B)
//! via the direct CLI but wrong (130B) via the diff-runner. Both use the SAME
//! `runWasmJitCaptured`; argv/limits/preopen/env are all ruled out. Remaining
//! suspects: (a) the stdout-capture BUFFER path, (b) in-process RIPPLE from a
//! prior interp run in the same Zig process. This exe runs each scenario in a
//! fresh process so the divergence point is pinned. x86_64-LINUX only (Rosetta
//! + arm64 mask it). Run: `nix develop --command zig build d489-repro`.
const std = @import("std");
const zwasm = @import("zwasm");
const cli_run = zwasm.cli.run;

const PATH = "test/realworld/wasm/tinygo_json.wasm";
const ARGV = [_][]const u8{"tinygo_json.wasm"};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var ob: [512]u8 = undefined;
    var ow = std.Io.File.stdout().writerStreaming(io, &ob);
    const out = &ow.interface;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, PATH, gpa, .limited(64 << 20));
    defer gpa.free(bytes);

    // (1) JIT-captured ALONE — nothing ran before it in this process.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const exit = cli_run.runWasmJitCaptured(gpa, io, bytes, null, &ARGV, &.{}, &.{}, &.{}, .{}, &buf, null, .none) catch |e| {
            try out.print("(1) jit-alone ERR {s}\n", .{@errorName(e)});
            try out.flush();
            return;
        };
        try out.print("(1) jit-alone:        exit={d} len={d} {s}\n", .{ exit, buf.items.len, if (buf.items.len == 90) "OK" else "DIVERGED" });
    }

    // (2) interp-captured FIRST, then JIT-captured — mimics the diff-runner's
    // in-process order (interp/wasmtime run precede the jit run per fixture).
    {
        var ibuf: std.ArrayList(u8) = .empty;
        defer ibuf.deinit(gpa);
        _ = cli_run.runWasmCaptured(gpa, io, bytes, &ARGV, &ibuf, null) catch {};
        var jbuf: std.ArrayList(u8) = .empty;
        defer jbuf.deinit(gpa);
        const exit = cli_run.runWasmJitCaptured(gpa, io, bytes, null, &ARGV, &.{}, &.{}, &.{}, .{}, &jbuf, null, .none) catch |e| {
            try out.print("(2) interp-then-jit ERR {s}\n", .{@errorName(e)});
            try out.flush();
            return;
        };
        try out.print("(2) interp-then-jit:  interp_len={d} jit_exit={d} jit_len={d} {s}\n", .{ ibuf.items.len, exit, jbuf.items.len, if (jbuf.items.len == 90) "OK" else "DIVERGED" });
        if (jbuf.items.len != 90) try out.print("    [jit output]\n{s}\n", .{jbuf.items});
    }

    // (3) JIT-captured with a PRE-SIZED buffer — if no in-run realloc fixes it,
    // the bug is a cached pointer invalidated when the capture ArrayList grows.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try buf.ensureTotalCapacity(gpa, 1 << 16);
        const exit = cli_run.runWasmJitCaptured(gpa, io, bytes, null, &ARGV, &.{}, &.{}, &.{}, .{}, &buf, null, .none) catch |e| {
            try out.print("(3) jit pre-sized ERR {s}\n", .{@errorName(e)});
            try out.flush();
            return;
        };
        try out.print("(3) jit pre-sized buf: exit={d} len={d} {s}\n", .{ exit, buf.items.len, if (buf.items.len == 90) "OK" else "DIVERGED" });
    }

    // (4) heap-layout probe: pre-allocate dummy heap to shift allocation layout,
    // then JIT-captured. If the result changes vs (1), the bad write targets a
    // HOST address that depends on heap layout (not a fixed guest offset) — which
    // also explains why arm64/Rosetta (different layout) don't corrupt.
    {
        const dummy = try gpa.alloc(u8, 8 << 20);
        defer gpa.free(dummy);
        @memset(dummy, 0xAA);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const exit = cli_run.runWasmJitCaptured(gpa, io, bytes, null, &ARGV, &.{}, &.{}, &.{}, .{}, &buf, null, .none) catch |e| {
            try out.print("(4) heap-shifted ERR {s}\n", .{@errorName(e)});
            try out.flush();
            return;
        };
        try out.print("(4) heap-shifted:     exit={d} len={d} {s}\n", .{ exit, buf.items.len, if (buf.items.len == 90) "OK" else "DIVERGED" });
    }

    try out.flush();
}
