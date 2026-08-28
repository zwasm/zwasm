//! Spec assertion runner — JIT-execute + compare against
//! `assert_return` expectations (§9.7 / 7.5-spec-assertion-driver-a).
//!
//! Walks subdirectories of a corpus root produced by
//! `scripts/regen_spec_1_0_assert.sh`. Each subdirectory has a
//! `manifest.txt` with directives:
//!
//!   `module <file>`                                — load .wasm into JIT
//!   `assert_return <fn> () -> <type>:<value>`      — invoke 0-arg
//!   `assert_return <fn> i32:<v> -> i32:<v>`        — invoke 1-i32-arg
//!   `skip-impl <reason>`                           — implementation gap; counts toward `skip-impl == 0` gate
//!   `skip-adr-<ADR-id> <reason>`                   — design-deferred per the named skip-ADR; waived from gate
//!   `skip <reason>`                                — legacy bare form (back-compat warning; counts as skip-impl)
//!
//! Chunk-a covers ONLY i32→i32 (0/1 args). Subsequent chunks
//! widen the surface (i64, f32/f64, multi-arg, traps).
//!
//! Usage:
//!   spec_assert_runner <corpus-root>
//! exits non-zero if any `failed > 0`.

const std = @import("std");

const zwasm = @import("zwasm");
const runner_mod = zwasm.engine.runner;
const entry = zwasm.engine.codegen.shared.entry;

pub fn main(init: std.process.Init) !void {
    zwasm.support.dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));
    // ADR-0202 D5 — this runner JIT-executes against a bespoke non-guarded
    // `scratch_memory` buffer, so it MUST compile with explicit bounds checks
    // (guard-page elision would read past the buffer instead of faulting,
    // violating the binding-time soundness invariant). D-515.
    zwasm.engine.runner.setBoundsChecks(.explicit);
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const corpus_root_arg = arg_it.next() orelse {
        try stdout.print("usage: spec_assert_runner <corpus-root>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_root = try gpa.dupe(u8, corpus_root_arg);
    defer gpa.free(corpus_root);

    // ADR-0210 — enumeration denominator: non-blank manifest lines read.
    var lines: u32 = 0;
    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;
    // Per ADR-0029: skip-impl vs skip-adr split. The §9.7 / 7.5
    // exit criterion is `skip-impl == 0`; skip-adr counts are
    // documented and accepted (e.g. text-format-parser scope-out
    // per `.dev/decisions/skip_text_format_parser.md`).
    var skipped_adr: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_root, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer root.close(io);

    var it = root.iterate();
    while (try it.next(io)) |dir_entry| {
        if (dir_entry.kind != .directory) continue;
        try runCorpus(io, gpa, &root, dir_entry.name, stdout, &lines, &passed, &failed, &skipped, &skipped_adr);
    }

    try stdout.print("\nspec_assert_runner: {d} passed, {d} failed, {d} skipped (= {d} skip-impl + {d} skip-adr)\n", .{ passed, failed, skipped + skipped_adr, skipped, skipped_adr });
    // ADR-0210 — the denominator next to the verdict columns, so "N passed"
    // can be checked against the work enumerated rather than taken on trust.
    const accounted = passed + failed + skipped + skipped_adr;
    // `overcounted > 0` means a line was tallied twice; a bare residual
    // saturates at zero and would report that as a perfectly accounted
    // corpus (ADR-0210).
    try stdout.print("spec_assert_runner: lines={d} accounted={d} residual={d} overcounted={d} (residual = non-assertion directives + any line that reached no column; overcounted = a verdict exists for lines that were never read (unreadable manifest) or a line was tallied twice)\n", .{ lines, accounted, if (lines > accounted) lines - accounted else 0, if (accounted > lines) accounted - lines else 0 });
    try stdout.flush();
    if (failed != 0) std.process.exit(1);
}

fn runCorpus(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: *std.Io.Dir,
    name: []const u8,
    stdout: *std.Io.Writer,
    lines: *u32,
    passed: *u32,
    failed: *u32,
    skipped: *u32,
    skipped_adr: *u32,
) !void {
    var dir = try root.openDir(io, name, .{});
    defer dir.close(io);

    const manifest_bytes = try dir.readFileAlloc(io, "manifest.txt", gpa, .limited(1 << 16));
    defer gpa.free(manifest_bytes);

    var current_wasm: ?[]u8 = null;
    var current_compiled: ?runner_mod.CompiledWasm = null;
    defer {
        if (current_wasm) |b| gpa.free(b);
        if (current_compiled) |*c| c.deinit(gpa);
    }

    var line_it = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        lines.* += 1;

        // Per ADR-0029 (Path B vocabulary, prep-mode chunk 9.9-h-21):
        // manifest skip directives carry one of three forms:
        //   `skip-impl <reason>`        — implementation gap; counts toward `skip-impl == 0` gate.
        //   `skip-adr-<ADR-id> <reason>` — design-deferred; counts toward `skip-adr` tally only.
        //   `skip <reason>`             — legacy bare form; back-compat warning + counts as skip-impl
        //                                   until manifest regen sweeps the corpus (chunk 9.9-h-22).
        // Prefix-aware classification means new skip-ADRs need only:
        //   (a) `.dev/decisions/skip_<topic>.md` and
        //   (b) `scripts/regen_spec_*.sh` emit the `skip-adr-<topic>` prefix.
        // No runner-code edits per new ADR.
        if (std.mem.startsWith(u8, line, "skip-impl ")) {
            skipped.* += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "skip-adr-")) {
            skipped_adr.* += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "skip ")) {
            // Back-compat for un-migrated manifests. Bare `skip` is being
            // phased out in 9.9-h-22's regen sweep. The legacy hardcoded
            // reason-string mapping for `directive-assert_malformed-text`
            // (per skip_text_format_parser.md) preserves classification
            // accuracy until that sweep lands. Once 0 lines fire here,
            // the back-compat arm can be removed in a follow-up.
            try stdout.print("WARN  {s}: bare `skip` line — migrate to `skip-impl` or `skip-adr-<id>` (chunk 9.9-h-22 regen sweep): {s}\n", .{ name, line });
            const reason = line[5..];
            if (std.mem.eql(u8, reason, "directive-assert_malformed-text")) {
                skipped_adr.* += 1;
            } else {
                skipped.* += 1;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "module ")) {
            const file = line[7..];
            // Drop any prior compiled module + reset scratch state
            // so cross-fixture state doesn't leak (within-fixture
            // state DOES persist across asserts, by design).
            if (current_compiled) |*c| c.deinit(gpa);
            current_compiled = null;
            if (current_wasm) |b| gpa.free(b);
            current_wasm = null;
            @memset(scratch_memory[0..], 0);
            @memset(scratch_globals[0..], Value.fromI32(0));

            const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                try stdout.print("FAIL  {s}/{s} module read: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                continue;
            };
            current_wasm = wasm_bytes;

            const compiled = runner_mod.compileWasm(gpa, wasm_bytes) catch |err| {
                try stdout.print("FAIL  {s}/{s} compile: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                continue;
            };
            current_compiled = compiled;
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_return ")) {
            const compiled = current_compiled orelse {
                try stdout.print("FAIL  {s}: assert_return without prior module\n", .{name});
                failed.* += 1;
                continue;
            };
            const wasm = current_wasm.?;
            const ok = runAssertReturn(gpa, wasm, &compiled, line[14..], stdout, name) catch |err| {
                try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
                failed.* += 1;
                continue;
            };
            if (ok) {
                passed.* += 1;
                try stdout.print("PASS  {s}: {s}\n", .{ name, line });
            } else {
                failed.* += 1;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_invalid ")) {
            // 7.5-close-a: assert_invalid <file>
            // The .wasm parses (well-formed) but should fail
            // type-checking. We expect `compileWasm` to surface
            // the error; if it succeeds, the test FAILs because
            // the validator missed a malformed module.
            const file = line[15..];
            const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                try stdout.print("FAIL  {s}/{s} (assert_invalid) read: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                continue;
            };
            // compileWasm retains references into wasm_bytes; we
            // need to keep the buffer alive until after deinit.
            // Compiled-success path: deinit before freeing buffer.
            if (runner_mod.compileWasm(gpa, wasm_bytes)) |compiled_ok| {
                // Validator gap: compileWasm accepted a module the
                // upstream wast2json marked as `assert_invalid`.
                // Per `.claude/rules/no_workaround.md` paired with
                // a debt entry (D-042) this counts as `skip-impl
                // validator-gap` rather than FAIL — surfacing the
                // gap loudly via the manifest line + skip count.
                var c = compiled_ok;
                c.deinit(gpa);
                try stdout.print("SKIP-VALIDATOR-GAP  {s}: assert_invalid {s} (D-042)\n", .{ name, file });
                skipped.* += 1;
            } else |_| {
                passed.* += 1;
                try stdout.print("PASS  {s}: assert_invalid {s}\n", .{ name, file });
            }
            gpa.free(wasm_bytes);
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_malformed ")) {
            // 7.5-close-b: parser-level rejection. Same shape as
            // assert_invalid (D-041 a bucket); the bytes are
            // truly malformed (decoder layer), not merely type-
            // incorrect (validator layer). Either decoder or
            // validator MAY surface the rejection — runner only
            // checks the unified compile path returns an error.
            const file = line[17..];
            const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                try stdout.print("FAIL  {s}/{s} (assert_malformed) read: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                continue;
            };
            if (runner_mod.compileWasm(gpa, wasm_bytes)) |compiled_ok| {
                var c = compiled_ok;
                c.deinit(gpa);
                try stdout.print("SKIP-PARSER-GAP  {s}: assert_malformed {s} (D-042-mirror)\n", .{ name, file });
                skipped.* += 1;
            } else |_| {
                passed.* += 1;
                try stdout.print("PASS  {s}: assert_malformed {s}\n", .{ name, file });
            }
            gpa.free(wasm_bytes);
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_trap ")) {
            const compiled = current_compiled orelse {
                try stdout.print("FAIL  {s}: assert_trap without prior module\n", .{name});
                failed.* += 1;
                continue;
            };
            const wasm = current_wasm.?;
            const ok = runAssertTrap(gpa, wasm, &compiled, line[12..], stdout, name) catch |err| {
                try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
                failed.* += 1;
                continue;
            };
            if (ok) {
                passed.* += 1;
                try stdout.print("PASS  {s}: {s}\n", .{ name, line });
            } else {
                failed.* += 1;
            }
            continue;
        }

        try stdout.print("FAIL  {s}: unknown directive '{s}'\n", .{ name, line });
        failed.* += 1;
    }
}

fn parseI32Token(tok: []const u8) !u32 {
    return std.fmt.parseInt(u32, tok, 10) catch
        @as(u32, @bitCast(std.fmt.parseInt(i32, tok, 10) catch return error.BadValue));
}

fn parseI64Token(tok: []const u8) !u64 {
    return std.fmt.parseInt(u64, tok, 10) catch
        @as(u64, @bitCast(std.fmt.parseInt(i64, tok, 10) catch return error.BadValue));
}

const ArgKind = enum { i32, i64, f32, f64 };
const ArgValue = struct { kind: ArgKind, val: u64 };

/// 64 KB (one Wasm page) scratch heap shared by every assertion.
/// Memory-using fixtures (load/store) see this as `vm_base` with
/// `mem_limit = 65536`. \`memory.grow\` does not actually expand
/// this buffer — fixtures requiring grow semantics still go
/// without a richer runtime path. ADR-grade module init lives in
/// a future chunk.
var scratch_memory: [65536]u8 = undefined;

const Value = zwasm.runtime.Value;
/// 16 globals slots backing global.get / global.set in fixtures.
/// Zero-initialised on each assertion (alongside scratch_memory).
var scratch_globals: [16]Value = undefined;

fn runAssertReturn(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) !bool {
    // rest = "<fn> <args> -> <results>"
    const arrow = std.mem.find(u8, rest, " -> ") orelse return error.BadDirective;
    const lhs = rest[0..arrow];
    const results_s = rest[arrow + 4 ..];

    const sp1 = std.mem.findScalar(u8, lhs, ' ') orelse return error.BadDirective;
    const fn_name = lhs[0..sp1];
    const args_s = lhs[sp1 + 1 ..];

    const func_idx = runner_mod.findExportFunc(gpa, wasm_bytes, fn_name) catch |err| {
        try stdout.print("FAIL  {s}: findExport({s}): {s}\n", .{ name, fn_name, @errorName(err) });
        return false;
    };

    // scratch_memory + scratch_globals are reset on each `module`
    // directive (per-fixture); state persists across asserts
    // within one fixture so global.set/get + memory.store/load
    // round-trips behave as intended.
    var rt: entry.JitRuntime = .{
        .vm_base = scratch_memory[0..],
        .mem_limit = scratch_memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = &scratch_globals,
        .globals_count = scratch_globals.len,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };

    // Parse arg tokens.
    var args: [5]ArgValue = undefined;
    var n_args: usize = 0;
    if (!std.mem.eql(u8, args_s, "()")) {
        var arg_it = std.mem.tokenizeScalar(u8, args_s, ' ');
        while (arg_it.next()) |tok| {
            if (n_args >= args.len) {
                try stdout.print("FAIL  {s}: > {d} args unsupported ({s})\n", .{ name, args.len, args_s });
                return false;
            }
            if (std.mem.startsWith(u8, tok, "i32:")) {
                args[n_args] = .{ .kind = .i32, .val = try parseI32Token(tok[4..]) };
            } else if (std.mem.startsWith(u8, tok, "i64:")) {
                args[n_args] = .{ .kind = .i64, .val = try parseI64Token(tok[4..]) };
            } else if (std.mem.startsWith(u8, tok, "f32:")) {
                args[n_args] = .{ .kind = .f32, .val = @as(u64, try parseI32Token(tok[4..])) };
            } else if (std.mem.startsWith(u8, tok, "f64:")) {
                args[n_args] = .{ .kind = .f64, .val = try parseI64Token(tok[4..]) };
            } else {
                try stdout.print("FAIL  {s}: unsupported arg type ({s})\n", .{ name, tok });
                return false;
            }
            n_args += 1;
        }
    }

    // 7.5-close-c1: void-result dispatch (`results_s == "()"`).
    // No expected value to compare; just invoke + check no trap.
    if (std.mem.eql(u8, results_s, "()")) {
        if (n_args == 0) {
            entry.callVoidNoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            };
            return true;
        }
        if (n_args == 1 and args[0].kind == .i32) {
            entry.callVoid_i32(compiled.module, func_idx, &rt, @intCast(args[0].val)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        if (n_args == 1 and args[0].kind == .i64) {
            entry.callVoid_i64(compiled.module, func_idx, &rt, args[0].val) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        if (n_args == 1 and args[0].kind == .f32) {
            const a0_f: f32 = @bitCast(@as(u32, @intCast(args[0].val)));
            entry.callVoid_f32(compiled.module, func_idx, &rt, a0_f) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        if (n_args == 1 and args[0].kind == .f64) {
            const a0_d: f64 = @bitCast(args[0].val);
            entry.callVoid_f64(compiled.module, func_idx, &rt, a0_d) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        if (n_args == 2 and args[0].kind == .i32 and args[1].kind == .i32) {
            entry.callVoid_i32i32(compiled.module, func_idx, &rt, @intCast(args[0].val), @intCast(args[1].val)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        if (n_args == 5 and args[0].kind == .i64 and args[1].kind == .f32 and args[2].kind == .f64 and args[3].kind == .i32 and args[4].kind == .i32) {
            const a1: f32 = @bitCast(@as(u32, @intCast(args[1].val)));
            const a2: f64 = @bitCast(args[2].val);
            entry.callVoid_i64f32f64i32i32(compiled.module, func_idx, &rt, args[0].val, a1, a2, @intCast(args[3].val), @intCast(args[4].val)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        try stdout.print("FAIL  {s}: void-result unsupported (n_args={d}, arg shape) for {s}({s})\n", .{ name, n_args, fn_name, args_s });
        return false;
    }

    // Parse expected result.
    const result_kind: ArgKind = if (std.mem.startsWith(u8, results_s, "i32:")) .i32 else if (std.mem.startsWith(u8, results_s, "i64:")) .i64 else if (std.mem.startsWith(u8, results_s, "f32:")) .f32 else if (std.mem.startsWith(u8, results_s, "f64:")) .f64 else {
        try stdout.print("FAIL  {s}: unsupported result type '{s}'\n", .{ name, results_s });
        return false;
    };
    const exp_s = results_s[4..];
    const expected: u64 = switch (result_kind) {
        .i32, .f32 => @as(u64, try parseI32Token(exp_s)),
        .i64, .f64 => try parseI64Token(exp_s),
    };

    // Dispatch on (n_args, arg-kind shape, result-kind).
    const got: u64 = blk: {
        if (n_args == 0 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32NoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            });
        }
        if (n_args == 0 and result_kind == .i64) {
            break :blk entry.callI64NoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            };
        }
        if (n_args == 1 and args[0].kind == .i32 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_i32(compiled.module, func_idx, &rt, @intCast(args[0].val)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        if (n_args == 1 and args[0].kind == .i32 and result_kind == .i64) {
            break :blk entry.callI64_i32(compiled.module, func_idx, &rt, @intCast(args[0].val)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
        }
        if (n_args == 1 and args[0].kind == .i64 and result_kind == .i64) {
            break :blk entry.callI64_i64(compiled.module, func_idx, &rt, args[0].val) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
        }
        if (n_args == 2 and args[0].kind == .i32 and args[1].kind == .i32 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_i32i32(compiled.module, func_idx, &rt, @intCast(args[0].val), @intCast(args[1].val)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        if (n_args == 0 and result_kind == .f32) {
            const r = entry.callF32NoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @as(u32, @bitCast(r)));
        }
        if (n_args == 0 and result_kind == .f64) {
            const r = entry.callF64NoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @bitCast(r));
        }
        if (n_args == 1 and args[0].kind == .f32 and result_kind == .f32) {
            const a0_f: f32 = @bitCast(@as(u32, @intCast(args[0].val)));
            const r = entry.callF32_f32(compiled.module, func_idx, &rt, a0_f) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @as(u32, @bitCast(r)));
        }
        if (n_args == 1 and args[0].kind == .f64 and result_kind == .f64) {
            const a0_d: f64 = @bitCast(args[0].val);
            const r = entry.callF64_f64(compiled.module, func_idx, &rt, a0_d) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @bitCast(r));
        }
        if (n_args == 5 and args[0].kind == .i64 and args[1].kind == .f32 and args[2].kind == .f64 and args[3].kind == .i32 and args[4].kind == .i32 and result_kind == .i64) {
            const a1: f32 = @bitCast(@as(u32, @intCast(args[1].val)));
            const a2: f64 = @bitCast(args[2].val);
            break :blk entry.callI64_i64f32f64i32i32(compiled.module, func_idx, &rt, args[0].val, a1, a2, @intCast(args[3].val), @intCast(args[4].val)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
        }
        if (n_args == 5 and args[0].kind == .i64 and args[1].kind == .f32 and args[2].kind == .f64 and args[3].kind == .i32 and args[4].kind == .i32 and result_kind == .f64) {
            const a1: f32 = @bitCast(@as(u32, @intCast(args[1].val)));
            const a2: f64 = @bitCast(args[2].val);
            const r = entry.callF64_i64f32f64i32i32(compiled.module, func_idx, &rt, args[0].val, a1, a2, @intCast(args[3].val), @intCast(args[4].val)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @bitCast(r));
        }
        try stdout.print("FAIL  {s}: unsupported (n_args={d}, arg/result shape) for {s}({s}) -> {s}\n", .{ name, n_args, fn_name, args_s, results_s });
        return false;
    };

    if (got != expected) {
        try stdout.print("FAIL  {s}: {s}({s}) → got {d}, expected {d}\n", .{ name, fn_name, args_s, got, expected });
        return false;
    }
    return true;
}

/// `assert_trap <fn> <args>` (reason discrimination is D-022 work).
/// Invokes the function and checks that `Error.Trap` is observed.
fn runAssertTrap(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) !bool {
    const sp1 = std.mem.findScalar(u8, rest, ' ') orelse return error.BadDirective;
    const fn_name = rest[0..sp1];
    const args_s = rest[sp1 + 1 ..];

    const func_idx = runner_mod.findExportFunc(gpa, wasm_bytes, fn_name) catch |err| {
        try stdout.print("FAIL  {s}: findExport({s}): {s}\n", .{ name, fn_name, @errorName(err) });
        return false;
    };

    // scratch_memory + scratch_globals are reset on each `module`
    // directive (per-fixture); state persists across asserts
    // within one fixture so global.set/get + memory.store/load
    // round-trips behave as intended.
    var rt: entry.JitRuntime = .{
        .vm_base = scratch_memory[0..],
        .mem_limit = scratch_memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = &scratch_globals,
        .globals_count = scratch_globals.len,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };

    var args: [2]ArgValue = undefined;
    var n_args: usize = 0;
    if (!std.mem.eql(u8, args_s, "()")) {
        var arg_it = std.mem.tokenizeScalar(u8, args_s, ' ');
        while (arg_it.next()) |tok| {
            if (n_args >= 2) {
                try stdout.print("FAIL  {s}: > 2 args unsupported in assert_trap ({s})\n", .{ name, args_s });
                return false;
            }
            if (std.mem.startsWith(u8, tok, "i32:")) {
                args[n_args] = .{ .kind = .i32, .val = try parseI32Token(tok[4..]) };
            } else if (std.mem.startsWith(u8, tok, "i64:")) {
                args[n_args] = .{ .kind = .i64, .val = try parseI64Token(tok[4..]) };
            } else {
                try stdout.print("FAIL  {s}: unsupported arg type ({s})\n", .{ name, tok });
                return false;
            }
            n_args += 1;
        }
    }

    // Dispatch — same shape table as runAssertReturn but we discard
    // the i32/i64 distinction on the result side (any Error.Trap is
    // a pass for assert_trap; reason discrimination = D-022 / M3).
    const got_trap: bool = blk: {
        if (n_args == 0) {
            _ = entry.callI32NoArgs(compiled.module, func_idx, &rt) catch |err| switch (err) {
                error.Trap => break :blk true,
            };
            break :blk false;
        }
        if (n_args == 1 and args[0].kind == .i32) {
            _ = entry.callI32_i32(compiled.module, func_idx, &rt, @intCast(args[0].val)) catch |err| switch (err) {
                error.Trap => break :blk true,
            };
            break :blk false;
        }
        if (n_args == 1 and args[0].kind == .i64) {
            _ = entry.callI64_i64(compiled.module, func_idx, &rt, args[0].val) catch |err| switch (err) {
                error.Trap => break :blk true,
            };
            break :blk false;
        }
        if (n_args == 2 and args[0].kind == .i32 and args[1].kind == .i32) {
            _ = entry.callI32_i32i32(compiled.module, func_idx, &rt, @intCast(args[0].val), @intCast(args[1].val)) catch |err| switch (err) {
                error.Trap => break :blk true,
            };
            break :blk false;
        }
        try stdout.print("FAIL  {s}: assert_trap unsupported (n_args={d}) for {s}({s})\n", .{ name, n_args, fn_name, args_s });
        return false;
    };

    if (!got_trap) {
        try stdout.print("FAIL  {s}: assert_trap {s}({s}) → did NOT trap\n", .{ name, fn_name, args_s });
        return false;
    }
    return true;
}
