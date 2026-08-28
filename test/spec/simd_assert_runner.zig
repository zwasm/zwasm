//! SIMD spec assertion runner — JIT-execute + compare against
//! `assert_return` expectations on the WebAssembly testsuite SIMD
//! bundle (§9.9 per ADR-0045).
//!
//! Parallel runner to `spec_assert_runner.zig`; consumes a v128-
//! aware text manifest format that extends the scalar shape with
//! `v128:<32 hex digits>` tokens for 128-bit bit-pattern args /
//! results (see ADR-0045 §"Decision" / 2). Hex digits are
//! lower-byte-first to match the in-memory little-endian Wasm
//! v128 layout (lane-0-byte-0 first), produced by
//! `scripts/regen_spec_simd_assert.sh`'s Python distillation.
//!
//! Per-lane NaN-pattern result tokens (chunk 9.9-h-25) extend the
//! v128 form with `v128_lanes:<shape>:<l0>,<l1>,...,<lN>` where
//! `<shape>` ∈ {`f32x4`, `f64x2`} and each lane is one of:
//!   `c`       — canonical NaN (±canonical accepted)
//!   `a`       — arithmetic NaN (any quiet NaN per Wasm spec)
//!   `V<hex>`  — exact bit pattern (8 hex / lane for f32x4,
//!               16 hex / lane for f64x2; upper-byte-first
//!               natural-width hex — distinct from the
//!               lane-0-byte-0 packing of `v128:`).
//! Per Wasm spec testsuite semantics, each lane is checked
//! independently; the assertion passes iff every lane matches its
//! pattern. Only emitted for FP shapes that actually contain a
//! `nan:*` token; otherwise the legacy `v128:` form is preserved.
//!
//! §9.9-c (this commit) — populates manifest + JIT execution.
//! Walks each subdirectory's `manifest.txt`, dispatches `module` /
//! `assert_return` / `assert_invalid` / `assert_malformed` / `skip`
//! directives. Supported shapes: `() → {i32,i64,f32,f64,v128,()}`
//! and `(i32) → {i32,v128}`. v128 PARAM marshal + multi-arg shapes
//! land in §9.9-e+.
//!
//! Usage:
//!   simd_assert_runner <corpus-root>
//! exits non-zero if any `failed > 0`.

const std = @import("std");

const zwasm = @import("zwasm");
const runner_mod = zwasm.engine.runner;
const entry = zwasm.engine.codegen.shared.entry;
// §9.9 / 9.9-l-1a (per ADR-0057): shared token parsers + helpers
// extracted from this file. l-1a stage 1 covers scalar tokens +
// splitFnAndArgs; later sub-chunks move the full manifest loop
// + module-init + RunnerCallbacks trait.
const base = @import("spec_assert_runner_base.zig");

pub fn main(init: std.process.Init) !void {
    zwasm.support.dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));
    base.initHostDispatchStubs();
    // ADR-0202 D5 — JIT-executes against the bespoke non-guarded
    // `base.growable_memory` array → explicit bounds checks mandatory
    // (elision would read past it instead of faulting). D-515.
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
        try stdout.print("usage: simd_assert_runner <corpus-root>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_root = try gpa.dupe(u8, corpus_root_arg);
    defer gpa.free(corpus_root);

    // Per ADR-0029 Path B (chunk 9.9-h-21): the tally carries twin
    // `skip-impl` (counts toward gate) vs `skip-adr-<id>` (waived)
    // counters. Per §9.9 / 9.9-l-1a stage 4 (ADR-0057), the dispatch
    // loop lives in `base.runCorpus`; this runner contributes only the
    // SIMD-specific module-init + assertion handlers via `simd_callbacks`.
    var tally: base.AssertTally = .{};
    var manifest_count: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
        // The wasm-2.0-simd-assert corpus is COMMITTED, so a missing root
        // is a real error (e.g. a host-specific path-resolution failure) —
        // NOT a fresh-checkout / pre-regen state. FAIL loud: a silent
        // "0 manifests" exit-0 would mask the gap behind a green test-all
        // (the ADR-0174 windowsmini OK-hides-pass=0 anomaly). Mirrors the
        // wasm-1.0 `spec_assert_runner`.
        try stdout.print("simd_assert_runner: corpus '{s}' not found ({s}) — FAIL (committed corpus; missing root is a real error, ADR-0174)\n", .{ corpus_root, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer root.close(io);

    var iter = root.iterate();
    while (try iter.next(io)) |dir_entry| {
        if (dir_entry.kind != .directory) continue;
        manifest_count += 1;
        try base.runCorpus(io, gpa, &root, dir_entry.name, stdout, &tally, simd_callbacks);
    }

    try stdout.print(
        "\nsimd_assert_runner: {d} passed, {d} failed, {d} skipped (= {d} skip-impl + {d} runtime-skip + {d} skip-adr) (over {d} manifests)\n",
        .{
            tally.passed,
            tally.failed,
            tally.manifest_skip_impl + tally.runtime_skip + tally.skipped_adr,
            tally.manifest_skip_impl,
            tally.runtime_skip,
            tally.skipped_adr,
            manifest_count,
        },
    );
    // ADR-0210 — enumeration denominator alongside the verdict columns.
    try stdout.print(
        "simd_assert_runner: lines={d} accounted={d} residual={d} overcounted={d} (residual = non-assertion directives that reached no column - note a runtime-skip raised on a non-assertion line counts as accounted, so this is not a round count of them; overcounted = a verdict exists for lines that were never read (unreadable manifest) or a line was tallied twice)\n",
        .{ tally.lines, tally.accounted(), tally.residual(), tally.overcounted() },
    );
    try stdout.flush();

    if (tally.failed > 0) std.process.exit(1);
}

/// `RunnerCallbacks.on_module_loaded` implementation: repopulates
/// the SIMD runner's shared scratch buffers from the just-loaded
/// module so the JIT sees the fixture-declared memory / globals /
/// table state. Resets memory + globals to zero first so a previous
/// module's bytes don't bleed through.
///
/// On error prints the init-specific FAIL line (data-init vs
/// globals-init vs table-init) so the diagnostic is precise; base
/// then marks `module_bad` and suppresses subsequent asserts.
fn simdOnModuleLoaded(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!void {
    base.resetGrowableMemory(1);
    @memset(scratch_globals[0..], 0);

    // Close-plan §6 (j) Step B cohort 1 — see non_simd mirror.
    if (base.current_registered) |reg| {
        base.applyImportedGlobalsFromRegistered(
            gpa,
            wasm_bytes,
            compiled.globals_offsets,
            compiled.globals_valtypes,
            scratch_globals[0..],
            compiled.num_global_imports,
            reg,
        ) catch |err| {
            try stdout.print("FAIL  {s} imported-globals-init: {s}\n", .{ name, @errorName(err) });
            return err;
        };
    }

    const gctx_runtime = @import("zwasm").engine.runner_validate.GlobalsCtx{
        .offsets = compiled.globals_offsets,
        .valtypes = compiled.globals_valtypes,
        .buf = scratch_globals[0..],
        .num_imports = compiled.num_global_imports,
    };

    // §9.9 / 9.9-d-7: write active data-segment bytes so subsequent
    // v128.load fixtures see the fixture-declared bytes instead of
    // the all-zero memset baseline.
    runner_mod.applyActiveDataSegmentsCtx(
        gpa,
        wasm_bytes,
        base.growable_memory[0..@intCast(base.current_mem_bytes)],
        gctx_runtime,
    ) catch |err| {
        try stdout.print("FAIL  {s} data-init: {s}\n", .{ name, @errorName(err) });
        return err;
    };
    // ADR-0052 §9.9 / 9.9-h-2 — write defined-globals init values
    // into the shared scratch buffer at the module-specific
    // per-global byte offsets the JIT emit baked in.
    runner_mod.applyDefinedGlobalsInit(
        gpa,
        wasm_bytes,
        compiled.globals_offsets,
        compiled.globals_valtypes,
        scratch_globals[0..],
        compiled.num_global_imports,
    ) catch |err| {
        try stdout.print("FAIL  {s} globals-init: {s}\n", .{ name, @errorName(err) });
        return err;
    };
    // D-063 discharge (§9.9 / 9.9-h-4) — populate the funcref table
    // from active element segments so `call_indirect` finds entries.
    runner_mod.applyTableInitCtx(
        gpa,
        wasm_bytes,
        compiled,
        scratch_funcptrs[0..],
        scratch_typeidxs[0..],
        gctx_runtime,
    ) catch |err| {
        try stdout.print("FAIL  {s} table-init: {s}\n", .{ name, @errorName(err) });
        return err;
    };
    // §9.9 / 9.9-l-1b-d093-d42b (D-112): mirror of the non-simd
    // runner — wire per-non-zero-table scratch for multi-table
    // JIT call_indirect. SIMD corpora today are single-table, so
    // this collapses to an entry-0 rebind + `active_table_count = 1`.
    base.setupMultiTableScratchCtx(
        gpa,
        wasm_bytes,
        compiled,
        scratch_funcptrs[0..],
        scratch_typeidxs[0..],
        gctx_runtime,
    ) catch |err| {
        try stdout.print("FAIL  {s} multi-table-init: {s}\n", .{ name, @errorName(err) });
        return err;
    };
    // §9.9-III γ.3 (ADR-0068 follow-up): see non_simd runner —
    // resolve ref.func funcref globals after func_entities exists.
    runner_mod.resolveFuncrefGlobals(
        gpa,
        wasm_bytes,
        compiled.globals_offsets,
        compiled.globals_valtypes,
        scratch_globals[0..],
        base.scratch_func_entities[0..base.active_func_count],
        compiled.num_global_imports,
    ) catch |err| {
        try stdout.print("FAIL  {s} resolve-funcref-globals: {s}\n", .{ name, @errorName(err) });
        return err;
    };
    // §9.9-III (c)-2.3-γ-5 per ADR-0066: mirror of the non-SIMD
    // patch — substitute resolved bridge-thunk addrs into
    // table-0 funcptr entries whose source funcidx is an import.
    if (base.current_dispatch) |disp| {
        runner_mod.patchTableImportFuncptrs(
            gpa,
            wasm_bytes,
            compiled.num_imports,
            0,
            disp,
            scratch_funcptrs[0..],
        ) catch |err| {
            try stdout.print("FAIL  {s} patch table import funcptrs: {s}\n", .{ name, @errorName(err) });
            return err;
        };
    }
}

/// SIMD specialisation of `base.RunnerCallbacks` per ADR-0057 §"Decision".
/// `runAssertReturn` / `runAssertTrap` retain their existing signatures
/// (defined further below); they parse SIMD-aware result tokens,
/// dispatch via `invokeV128`, and compare per-lane NaN patterns —
/// none of which the non-SIMD specialisation will need.
const simd_callbacks: base.RunnerCallbacks = .{
    .on_module_loaded = simdOnModuleLoaded,
    .handle_assert_return = runAssertReturn,
    .handle_assert_trap = runAssertTrap,
    // d-36: SIMD corpora don't emit `invoke-action` lines today;
    // surface a FAIL if one ever appears so the gap is discoverable
    // instead of silently swallowed.
    .handle_invoke_action = simdRunInvokeAction,
};

fn simdRunInvokeAction(
    _: std.mem.Allocator,
    _: []const u8,
    _: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    try stdout.print("FAIL  {s}: invoke-action not implemented for SIMD runner ({s})\n", .{ name, rest });
    return false;
}

// Scalar token parsers moved to spec_assert_runner_base.zig per
// ADR-0057. Re-exported here as local aliases so the body of this
// runner doesn't need to know about the base file path. §9.9 /
// 9.9-l-1a stage 5 (ADR-0057): v128 token parser + ArgKind/ArgValue
// hoisted to base since they are token-level (l-1b non-SIMD won't
// see v128 tokens but reuses the same union so the arg-buffer type
// flows through both runners).
const parseI32Token = base.parseI32Token;
const parseI64Token = base.parseI64Token;
const parseV128Token = base.parseV128Token;

// Per-lane NaN-pattern result decoder (chunk 9.9-h-25). The
// canonical / arithmetic checks match Wasm spec §A.2 "Result
// types" + the testsuite's `nan:canonical` / `nan:arithmetic`
// semantics: a canonical NaN has exponent all-1s and mantissa =
// `1 << (mantissa_width - 1)` (sign arbitrary); an arithmetic
// NaN is any quiet NaN (exponent all-1s, mantissa MSB = 1).
const LaneShape = enum { f32x4, f64x2 };
const LaneSpec = union(enum) {
    canonical,
    arithmetic,
    exact: u64,
};

const ParsedV128Lanes = struct {
    shape: LaneShape,
    lanes: [4]LaneSpec,
    n_lanes: u8,
};

fn parseV128LanesToken(s: []const u8) !ParsedV128Lanes {
    // `s` is the suffix after `v128_lanes:`; expects
    // `<shape>:<lane0>,<lane1>,...,<laneN>`.
    const colon = std.mem.findScalar(u8, s, ':') orelse return error.BadValue;
    const shape_s = s[0..colon];
    const rest = s[colon + 1 ..];

    var out: ParsedV128Lanes = undefined;
    var hex_width: usize = undefined;
    if (std.mem.eql(u8, shape_s, "f32x4")) {
        out.shape = .f32x4;
        out.n_lanes = 4;
        hex_width = 8;
    } else if (std.mem.eql(u8, shape_s, "f64x2")) {
        out.shape = .f64x2;
        out.n_lanes = 2;
        hex_width = 16;
    } else return error.BadValue;

    var idx: u8 = 0;
    var it = std.mem.splitScalar(u8, rest, ',');
    while (it.next()) |lane_tok| {
        if (idx >= out.n_lanes) return error.BadValue;
        if (lane_tok.len == 1 and lane_tok[0] == 'c') {
            out.lanes[idx] = .canonical;
        } else if (lane_tok.len == 1 and lane_tok[0] == 'a') {
            out.lanes[idx] = .arithmetic;
        } else if (lane_tok.len == hex_width + 1 and lane_tok[0] == 'V') {
            const bits = try std.fmt.parseInt(u64, lane_tok[1..], 16);
            out.lanes[idx] = .{ .exact = bits };
        } else return error.BadValue;
        idx += 1;
    }
    if (idx != out.n_lanes) return error.BadValue;
    return out;
}

fn matchLaneF32(got_bits: u32, spec: LaneSpec) bool {
    return switch (spec) {
        // Canonical NaN: sign-agnostic ±0x7fc00000.
        .canonical => got_bits == 0x7fc00000 or got_bits == 0xffc00000,
        // Arithmetic NaN: exp all-1s + mantissa MSB = 1
        // (= any quiet NaN, includes canonical).
        .arithmetic => (got_bits & 0x7fc00000) == 0x7fc00000,
        .exact => |bits| got_bits == @as(u32, @intCast(bits & 0xffffffff)),
    };
}

fn matchLaneF64(got_bits: u64, spec: LaneSpec) bool {
    return switch (spec) {
        .canonical => got_bits == 0x7ff8000000000000 or got_bits == 0xfff8000000000000,
        .arithmetic => (got_bits & 0x7ff8000000000000) == 0x7ff8000000000000,
        .exact => |bits| got_bits == bits,
    };
}

/// §17.4 relaxed-SIMD — does `got` match one `(either)` alternative token?
/// `tok` is `v128:<hex>` (bit-exact) or `v128_lanes:<shape>:...` (NaN-aware
/// per-lane). Returns false (not error) on a malformed token so the caller's
/// any-match loop simply skips it.
fn v128MatchesToken(got: [16]u8, tok: []const u8) bool {
    if (std.mem.startsWith(u8, tok, "v128:")) {
        const expected = parseV128Token(tok[5..]) catch return false;
        return std.mem.eql(u8, &got, &expected);
    }
    if (std.mem.startsWith(u8, tok, "v128_lanes:")) {
        const parsed = parseV128LanesToken(tok[11..]) catch return false;
        switch (parsed.shape) {
            .f32x4 => {
                var lane: usize = 0;
                while (lane < 4) : (lane += 1) {
                    const bits = std.mem.readInt(u32, got[lane * 4 ..][0..4], .little);
                    if (!matchLaneF32(bits, parsed.lanes[lane])) return false;
                }
            },
            .f64x2 => {
                var lane: usize = 0;
                while (lane < 2) : (lane += 1) {
                    const bits = std.mem.readInt(u64, got[lane * 8 ..][0..8], .little);
                    if (!matchLaneF64(bits, parsed.lanes[lane])) return false;
                }
            },
        }
        return true;
    }
    return false;
}

// §9.9 / 9.9-l-1a stage 5 — ArgKind/ArgValue moved to base.
// Re-aliased so existing call sites keep their local names.
const ArgKind = base.ArgKind;
const ArgValue = base.ArgValue;

/// 64 KB scratch heap shared by every assertion. Mirrors the
/// `spec_assert_runner` shape exactly so the SIMD runner sees the
/// same `vm_base` / `mem_limit` semantics; data segments still
/// flow through `compileWasm`'s setupRuntime path on each `module`
/// directive. Backing storage moved to `base.growable_memory` per
/// ADR-0059 / §9.9 / 9.9-l-1b-d093-d8c so `memory.grow` callouts
/// can extend the in-use region within a 16-page pool.
/// Globals byte buffer. ADR-0052 — v128 globals live in 16-byte
/// slots (with 16-byte alignment); scalar globals in 8-byte
/// slots. 256 bytes accommodates up to 16 v128 globals or 32
/// scalars. Reset to zero on each `module` directive; init values
/// written via `applyDefinedGlobalsInit`.
var scratch_globals: [256]u8 align(16) = undefined;
/// D-063 discharge (§9.9 / 9.9-h-4) — funcref table for
/// `call_indirect`. Populated via `applyTableInit`. Sized for
/// realistic spec-fixture tables; simd_const.386 uses 2 entries.
// §9.9 / 9.9-l-1b-d093-d49 (D-124): bumped 32 → 1024 to mirror
// the non_simd runner's bump (table_copy.wast no-import 128-entry
// table variants).
const scratch_table_capacity = 1024;
var scratch_funcptrs: [scratch_table_capacity]u64 = undefined;
var scratch_typeidxs: [scratch_table_capacity]u32 = undefined;

// §9.9 / 9.9-l-1a stage 5 — parseArgToken moved to base. Alias
// retained so runAssertReturn / runAssertTrap (and any later
// helpers) read the local name.
const parseArgToken = base.parseArgToken;

/// Split `<fn> <args>` where `<fn>` may be a bare token OR a
// splitFnAndArgs moved to spec_assert_runner_base.zig per ADR-0057.
// Re-exported here as a local alias.
const splitFnAndArgs = base.splitFnAndArgs;

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

    const fa = try splitFnAndArgs(lhs);
    const fn_name = fa.fn_name;
    const args_s = fa.args_s;

    const func_idx = runner_mod.findExportFunc(gpa, wasm_bytes, fn_name) catch |err| {
        try stdout.print("FAIL  {s}: findExport({s}): {s}\n", .{ name, fn_name, @errorName(err) });
        return false;
    };

    var rt = base.makeJitRuntime(
        base.growable_memory[0..@intCast(base.current_mem_bytes)],
        scratch_globals[0..],
        scratch_funcptrs[0..],
        scratch_typeidxs[0..],
        base.currentDispatchView(),
    );

    var args: [4]ArgValue = undefined;
    const n_args = base.parseAssertReturnArgs(args_s, &args) catch |err| {
        if (err == error.TooManyArgs) {
            try stdout.print("FAIL  {s}: > {d} args unsupported ({s})\n", .{ name, args.len, args_s });
        } else {
            try stdout.print("FAIL  {s}: unsupported arg token ({s})\n", .{ name, args_s });
        }
        return false;
    };

    // void result.
    if (std.mem.eql(u8, results_s, "()")) {
        if (n_args == 0) {
            entry.callVoidNoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            };
            return true;
        }
        // §9.9 / 9.9-h-3 (D-079 (i)) — v128 multi-arg setter shapes.
        // Drives simd_const fixtures like `as-global.set_value_$g0`
        // (1 v128 param) and `_$g0_$g1_$g2_$g3` (4 v128 params).
        if (n_args == 1 and args[0] == .v128) {
            entry.callVoid_v128(compiled.module, func_idx, &rt, args[0].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        if (n_args == 2 and args[0] == .v128 and args[1] == .v128) {
            entry.callVoid_v128v128(compiled.module, func_idx, &rt, args[0].v128, args[1].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        if (n_args == 4 and args[0] == .v128 and args[1] == .v128 and args[2] == .v128 and args[3] == .v128) {
            entry.callVoid_v128v128v128v128(
                compiled.module,
                func_idx,
                &rt,
                args[0].v128,
                args[1].v128,
                args[2].v128,
                args[3].v128,
            ) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        // chunk 9.9-h-28 (v128-param-pending residual discharge):
        // (i32, v128) → () — `simd_align` `v128.store align=16`.
        if (n_args == 2 and args[0] == .i32 and args[1] == .v128) {
            entry.callVoid_i32v128(compiled.module, func_idx, &rt, args[0].i32, args[1].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        // chunk 9.9-h-29 Part A (assert_trap discharge): (i32) → () —
        // simd_address `store_data_*` shape. Used by both
        // assert_return (passing-through call) and assert_trap
        // (must raise Error.Trap on OOB).
        if (n_args == 1 and args[0] == .i32) {
            entry.callVoid_i32(compiled.module, func_idx, &rt, args[0].i32) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        try stdout.print("FAIL  {s}: void-result with {d} args unsupported for {s}\n", .{ name, n_args, fn_name });
        return false;
    }

    // Single-result decode.
    if (results_s.len < 4) {
        try stdout.print("FAIL  {s}: malformed result '{s}'\n", .{ name, results_s });
        return false;
    }

    // §17.4 relaxed-SIMD — `(either A B …)` 2+-outcome assertion (ADR-0169
    // per-arch hardware latitude). Invoke once; PASS if `got` matches ANY
    // alternative (each a v128:/v128_lanes: token, `|`-separated).
    if (std.mem.startsWith(u8, results_s, "either:")) {
        const got = (try invokeV128(compiled, func_idx, &rt, fn_name, args_s, args[0..n_args], stdout, name)) orelse return false;
        var it = std.mem.splitScalar(u8, results_s[7..], '|');
        while (it.next()) |alt| {
            if (v128MatchesToken(got, alt)) return true;
        }
        try stdout.print("FAIL  {s}: {s}({s}) → got v128:{x}, no (either) alt matched: {s}\n", .{ name, fn_name, args_s, got, results_s });
        return false;
    }

    if (std.mem.startsWith(u8, results_s, "v128:")) {
        const expected = parseV128Token(results_s[5..]) catch {
            try stdout.print("FAIL  {s}: bad v128 result token '{s}'\n", .{ name, results_s });
            return false;
        };
        const got = (try invokeV128(compiled, func_idx, &rt, fn_name, args_s, args[0..n_args], stdout, name)) orelse return false;
        if (!std.mem.eql(u8, &got, &expected)) {
            try stdout.print("FAIL  {s}: {s}({s}) → got v128:{x}, expected v128:{x}\n", .{ name, fn_name, args_s, got, expected });
            return false;
        }
        return true;
    }

    if (std.mem.startsWith(u8, results_s, "v128_lanes:")) {
        const parsed = parseV128LanesToken(results_s[11..]) catch {
            try stdout.print("FAIL  {s}: bad v128_lanes result token '{s}'\n", .{ name, results_s });
            return false;
        };
        const got = (try invokeV128(compiled, func_idx, &rt, fn_name, args_s, args[0..n_args], stdout, name)) orelse return false;
        switch (parsed.shape) {
            .f32x4 => {
                var lane: usize = 0;
                while (lane < 4) : (lane += 1) {
                    const off = lane * 4;
                    const bits = std.mem.readInt(u32, got[off..][0..4], .little);
                    if (!matchLaneF32(bits, parsed.lanes[lane])) {
                        try stdout.print(
                            "FAIL  {s}: {s}({s}) → f32x4 lane {d}: got 0x{x:0>8} vs {s}\n",
                            .{ name, fn_name, args_s, lane, bits, laneSpecName(parsed.lanes[lane]) },
                        );
                        return false;
                    }
                }
            },
            .f64x2 => {
                var lane: usize = 0;
                while (lane < 2) : (lane += 1) {
                    const off = lane * 8;
                    const bits = std.mem.readInt(u64, got[off..][0..8], .little);
                    if (!matchLaneF64(bits, parsed.lanes[lane])) {
                        try stdout.print(
                            "FAIL  {s}: {s}({s}) → f64x2 lane {d}: got 0x{x:0>16} vs {s}\n",
                            .{ name, fn_name, args_s, lane, bits, laneSpecName(parsed.lanes[lane]) },
                        );
                        return false;
                    }
                }
            },
        }
        return true;
    }

    // Scalar result.
    const result_kind: ArgKind = if (std.mem.startsWith(u8, results_s, "i32:")) .i32 else if (std.mem.startsWith(u8, results_s, "i64:")) .i64 else if (std.mem.startsWith(u8, results_s, "f32:")) .f32 else if (std.mem.startsWith(u8, results_s, "f64:")) .f64 else {
        try stdout.print("FAIL  {s}: unsupported result type '{s}'\n", .{ name, results_s });
        return false;
    };
    const exp_s = results_s[4..];
    const expected: u64 = switch (result_kind) {
        .i32, .f32 => @as(u64, try parseI32Token(exp_s)),
        .i64, .f64 => try parseI64Token(exp_s),
        .v128 => unreachable,
    };

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
        if (n_args == 1 and args[0] == .i32 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_i32(compiled.module, func_idx, &rt, args[0].i32) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        // chunk 9.9-h-26 (v128-param-pending discharge): (v128) → i32
        // for i*x*.all_true / any_true / bitmask / extract_lane.{s,u}.
        if (n_args == 1 and args[0] == .v128 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_v128(compiled.module, func_idx, &rt, args[0].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        // chunk 9.9-h-26: (v128) → f32 for f32x4.extract_lane.
        if (n_args == 1 and args[0] == .v128 and result_kind == .f32) {
            const r = entry.callF32_v128(compiled.module, func_idx, &rt, args[0].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @as(u32, @bitCast(r)));
        }
        // chunk 9.9-h-26: (v128) → f64 for f64x2.extract_lane.
        if (n_args == 1 and args[0] == .v128 and result_kind == .f64) {
            const r = entry.callF64_v128(compiled.module, func_idx, &rt, args[0].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @bitCast(r));
        }
        // chunk 9.9-h-27 (v128-param-pending residual discharge):
        // (v128) → i64 for i64x2.extract_lane.
        if (n_args == 1 and args[0] == .v128 and result_kind == .i64) {
            break :blk entry.callI64_v128(compiled.module, func_idx, &rt, args[0].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
        }
        // chunk 9.9-h-27: (v128, v128) → i32 for composite
        // `*_with_v128.{and,or,xor}` / `*_as_i32.*_operand`.
        if (n_args == 2 and args[0] == .v128 and args[1] == .v128 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_v128v128(compiled.module, func_idx, &rt, args[0].v128, args[1].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        // chunk 9.9-h-28 (v128-param-pending residual discharge):
        // (v128, v128, v128) → i32 — `simd_boolean`
        // `*_with_v128.bitselect` (any_true/all_true of bitselect).
        if (n_args == 3 and args[0] == .v128 and args[1] == .v128 and args[2] == .v128 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_v128v128v128(compiled.module, func_idx, &rt, args[0].v128, args[1].v128, args[2].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        // chunk 9.9-h-28: (v128, i32) → i32 — `simd_lane`
        // `i*x*_replace_lane-{s,u}` / `as-i*x*_any_true-operand`.
        if (n_args == 2 and args[0] == .v128 and args[1] == .i32 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_v128i32(compiled.module, func_idx, &rt, args[0].v128, args[1].i32) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        // chunk 9.9-h-28: (v128, i64) → i32 — `simd_lane`
        // `as-i32x4_any_true-operand2`.
        if (n_args == 2 and args[0] == .v128 and args[1] == .i64 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_v128i64(compiled.module, func_idx, &rt, args[0].v128, args[1].i64) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        // chunk 9.9-h-28: (v128, i64) → i64 — `simd_lane`
        // `i64x2_replace_lane`.
        if (n_args == 2 and args[0] == .v128 and args[1] == .i64 and result_kind == .i64) {
            break :blk entry.callI64_v128i64(compiled.module, func_idx, &rt, args[0].v128, args[1].i64) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
        }
        // chunk 9.9-h-28: (v128, f32) → f32 — `simd_lane`
        // `f32x4_replace_lane`.
        if (n_args == 2 and args[0] == .v128 and args[1] == .f32 and result_kind == .f32) {
            const r = entry.callF32_v128f32(compiled.module, func_idx, &rt, args[0].v128, @as(f32, @bitCast(args[1].f32))) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @as(u32, @bitCast(r)));
        }
        // chunk 9.9-h-28: (v128, f64) → f64 — `simd_lane`
        // `f64x2_replace_lane`.
        if (n_args == 2 and args[0] == .v128 and args[1] == .f64 and result_kind == .f64) {
            const r = entry.callF64_v128f64(compiled.module, func_idx, &rt, args[0].v128, @as(f64, @bitCast(args[1].f64))) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @bitCast(r));
        }
        // D-467 single-scalar → scalar (simd_splat extract_lane
        // operand fixtures: splat the scalar to v128, extract a lane,
        // return scalar). `.i64` Value field is already i64; `.f32`/
        // `.f64` hold RAW BITS → @bitCast to the float before call.
        if (n_args == 1 and args[0] == .i64 and result_kind == .i64) {
            break :blk entry.callI64_i64(compiled.module, func_idx, &rt, @bitCast(args[0].i64)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
        }
        if (n_args == 1 and args[0] == .i64 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_i64(compiled.module, func_idx, &rt, @bitCast(args[0].i64)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        if (n_args == 1 and args[0] == .f32 and result_kind == .f32) {
            const r = entry.callF32_f32(compiled.module, func_idx, &rt, @as(f32, @bitCast(args[0].f32))) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @as(u32, @bitCast(r)));
        }
        if (n_args == 1 and args[0] == .f64 and result_kind == .f64) {
            const r = entry.callF64_f64(compiled.module, func_idx, &rt, @as(f64, @bitCast(args[0].f64))) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @bitCast(r));
        }
        // D-467 `v128.store{8,16,32,64}_lane` test exports —
        // (i32 addr, v128) → i64: store the lane, read back i64.
        if (n_args == 2 and args[0] == .i32 and args[1] == .v128 and result_kind == .i64) {
            break :blk entry.callI64_i32v128(compiled.module, func_idx, &rt, args[0].i32, args[1].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
        }
        try stdout.print("FAIL  {s}: scalar-result unsupported (n_args={d}, shape) for {s}({s}) -> {s}\n", .{ name, n_args, fn_name, args_s, results_s });
        return false;
    };

    if (got != expected) {
        try stdout.print("FAIL  {s}: {s}({s}) → got {d}, expected {d}\n", .{ name, fn_name, args_s, got, expected });
        return false;
    }
    return true;
}

/// Dispatch the JIT-compiled function for a v128-result assertion.
/// Returns `null` on unsupported shape / call error (after the
/// caller-level FAIL line has been printed); the caller maps `null`
/// to `return false` from `runAssertReturn`.
fn invokeV128(
    compiled: *const runner_mod.CompiledWasm,
    func_idx: u32,
    rt: *entry.JitRuntime,
    fn_name: []const u8,
    args_s: []const u8,
    args: []const ArgValue,
    stdout: *std.Io.Writer,
    name: []const u8,
) !?[16]u8 {
    const n_args = args.len;
    if (n_args == 0) {
        return entry.callV128NoArgs(compiled.module, func_idx, rt) catch |err| {
            try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
            return null;
        };
    }
    if (n_args == 1 and args[0] == .i32) {
        return entry.callV128_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 1 and args[0] == .i64) {
        return entry.callV128_i64(compiled.module, func_idx, rt, @bitCast(args[0].i64)) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 1 and args[0] == .f32) {
        return entry.callV128_f32(compiled.module, func_idx, rt, @bitCast(args[0].f32)) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 1 and args[0] == .f64) {
        return entry.callV128_f64(compiled.module, func_idx, rt, @bitCast(args[0].f64)) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 1 and args[0] == .v128) {
        return entry.callV128_v128(compiled.module, func_idx, rt, args[0].v128) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 2 and args[0] == .v128 and args[1] == .v128) {
        return entry.callV128_v128v128(compiled.module, func_idx, rt, args[0].v128, args[1].v128) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 3 and args[0] == .v128 and args[1] == .v128 and args[2] == .v128) {
        return entry.callV128_v128v128v128(compiled.module, func_idx, rt, args[0].v128, args[1].v128, args[2].v128) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-26 (v128-param-pending discharge):
    // (v128, i32) → v128 — i*x*.shl/shr_s/shr_u + i*x*.replace_lane.
    if (n_args == 2 and args[0] == .v128 and args[1] == .i32) {
        return entry.callV128_v128i32(compiled.module, func_idx, rt, args[0].v128, args[1].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-26: (v128, f32) → v128 — f32x4.replace_lane.
    if (n_args == 2 and args[0] == .v128 and args[1] == .f32) {
        const r = entry.callV128_v128f32(compiled.module, func_idx, rt, args[0].v128, @as(f32, @bitCast(args[1].f32))) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return r;
    }
    // chunk 9.9-h-26: (v128, f64) → v128 — f64x2.replace_lane.
    if (n_args == 2 and args[0] == .v128 and args[1] == .f64) {
        const r = entry.callV128_v128f64(compiled.module, func_idx, rt, args[0].v128, @as(f64, @bitCast(args[1].f64))) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return r;
    }
    // chunk 9.9-h-27 (v128-param-pending residual discharge):
    // (v128, i64) → v128 — i64x2.replace_lane.
    if (n_args == 2 and args[0] == .v128 and args[1] == .i64) {
        return entry.callV128_v128i64(compiled.module, func_idx, rt, args[0].v128, args[1].i64) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-27: (v128, v128, i32) → v128 — select_v128_i32.
    if (n_args == 3 and args[0] == .v128 and args[1] == .v128 and args[2] == .i32) {
        return entry.callV128_v128v128i32(compiled.module, func_idx, rt, args[0].v128, args[1].v128, args[2].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-28 (v128-param-pending residual discharge):
    // (v128, v128, v128, v128) → v128 — `simd_lane`
    // `swizzle-as-i8x16_add-operands` / `shuffle-as-i8x16_sub-operands`.
    if (n_args == 4 and args[0] == .v128 and args[1] == .v128 and args[2] == .v128 and args[3] == .v128) {
        return entry.callV128_v128v128v128v128(compiled.module, func_idx, rt, args[0].v128, args[1].v128, args[2].v128, args[3].v128) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-28: (v128, i32, v128) → v128 — `simd_lane`
    // `as-v8x16_swizzle-operand`.
    if (n_args == 3 and args[0] == .v128 and args[1] == .i32 and args[2] == .v128) {
        return entry.callV128_v128i32v128(compiled.module, func_idx, rt, args[0].v128, args[1].i32, args[2].v128) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-28: (v128, i32, v128, i32) → v128 — `simd_lane`
    // `as-v8x16_shuffle-operands` / `as-i*x*_add-operands`.
    if (n_args == 4 and args[0] == .v128 and args[1] == .i32 and args[2] == .v128 and args[3] == .i32) {
        return entry.callV128_v128i32v128i32(compiled.module, func_idx, rt, args[0].v128, args[1].i32, args[2].v128, args[3].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-28: (v128, i64, v128, i64) → v128 — `simd_lane`
    // `as-i64x2_add-operands`.
    if (n_args == 4 and args[0] == .v128 and args[1] == .i64 and args[2] == .v128 and args[3] == .i64) {
        return entry.callV128_v128i64v128i64(compiled.module, func_idx, rt, args[0].v128, args[1].i64, args[2].v128, args[3].i64) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // D-467 multi-scalar → v128 constructor shapes (simd_splat
    // `as-i*x*_*-operands` / `as-f*x*_*-operands`). The `.f32`/`.f64`
    // Value fields hold RAW BITS → @bitCast to the float before call.
    if (n_args == 2 and args[0] == .i32 and args[1] == .i32) {
        return entry.callV128_i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 3 and args[0] == .i32 and args[1] == .i32 and args[2] == .i32) {
        return entry.callV128_i32i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32, args[2].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 4 and args[0] == .i32 and args[1] == .i32 and args[2] == .i32 and args[3] == .i32) {
        return entry.callV128_i32i32i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32, args[2].i32, args[3].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 2 and args[0] == .i64 and args[1] == .i64) {
        return entry.callV128_i64i64(compiled.module, func_idx, rt, @bitCast(args[0].i64), @bitCast(args[1].i64)) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 4 and args[0] == .i64 and args[1] == .i64 and args[2] == .i64 and args[3] == .i64) {
        return entry.callV128_i64i64i64i64(compiled.module, func_idx, rt, @bitCast(args[0].i64), @bitCast(args[1].i64), @bitCast(args[2].i64), @bitCast(args[3].i64)) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 2 and args[0] == .f32 and args[1] == .f32) {
        return entry.callV128_f32f32(compiled.module, func_idx, rt, @as(f32, @bitCast(args[0].f32)), @as(f32, @bitCast(args[1].f32))) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 2 and args[0] == .f64 and args[1] == .f64) {
        return entry.callV128_f64f64(compiled.module, func_idx, rt, @as(f64, @bitCast(args[0].f64)), @as(f64, @bitCast(args[1].f64))) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 4 and args[0] == .f64 and args[1] == .f64 and args[2] == .f64 and args[3] == .f64) {
        return entry.callV128_f64f64f64f64(compiled.module, func_idx, rt, @as(f64, @bitCast(args[0].f64)), @as(f64, @bitCast(args[1].f64)), @as(f64, @bitCast(args[2].f64)), @as(f64, @bitCast(args[3].f64))) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // D-467 `v128.load{8,16,32,64}_lane` — (i32 addr, v128) → v128.
    // Active data segments are pre-materialized into linear memory.
    if (n_args == 2 and args[0] == .i32 and args[1] == .v128) {
        return entry.callV128_i32v128(compiled.module, func_idx, rt, args[0].i32, args[1].v128) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    try stdout.print("FAIL  {s}: v128-result unsupported (n_args={d}, arg shape) for {s}({s})\n", .{ name, n_args, fn_name, args_s });
    return null;
}

/// `assert_trap` directive (chunk 9.9-h-29 Part A). Returns `true`
/// on PASS (the call raised `Error.Trap`) and `false` on FAIL (any
/// other outcome — successful call, different error, parse error).
/// Result-type matching is purely a calling-convention selector
/// (Error.Trap propagates uniformly via the JIT entry helpers); a
/// successful call with any value is a FAIL.
fn runAssertTrap(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) !bool {
    // rest = "<fn> <args> -> <result_types>"
    const arrow = std.mem.find(u8, rest, " -> ") orelse return error.BadDirective;
    const lhs = rest[0..arrow];
    const result_types_s = rest[arrow + 4 ..];

    const fa = try splitFnAndArgs(lhs);
    const fn_name = fa.fn_name;
    const args_s = fa.args_s;

    const func_idx = runner_mod.findExportFunc(gpa, wasm_bytes, fn_name) catch |err| {
        try stdout.print("FAIL  {s}: assert_trap findExport({s}): {s}\n", .{ name, fn_name, @errorName(err) });
        return false;
    };

    var rt = base.makeJitRuntime(
        base.growable_memory[0..@intCast(base.current_mem_bytes)],
        scratch_globals[0..],
        scratch_funcptrs[0..],
        scratch_typeidxs[0..],
        base.currentDispatchView(),
    );

    var args: [4]ArgValue = undefined;
    const n_args = base.parseAssertReturnArgs(args_s, &args) catch |err| {
        if (err == error.TooManyArgs) {
            try stdout.print("FAIL  {s}: assert_trap > {d} args unsupported ({s})\n", .{ name, args.len, args_s });
        } else {
            try stdout.print("FAIL  {s}: assert_trap unsupported arg token ({s})\n", .{ name, args_s });
        }
        return false;
    };

    // The `expect` helper takes a single call expression and
    // converts any successful return into "did NOT trap" FAIL,
    // `error.Trap` into PASS, and any other error into a
    // distinct-error FAIL line.
    const TrapOutcome = enum { trapped, did_not_trap, other_error };
    var outcome: TrapOutcome = .other_error;
    var other_err_name: []const u8 = "?";

    if (std.mem.eql(u8, result_types_s, "()")) {
        // void result.
        if (n_args == 0) {
            if (entry.callVoidNoArgs(compiled.module, func_idx, &rt)) |_| {
                outcome = .did_not_trap;
            } else |err| {
                if (err == error.Trap) outcome = .trapped else {
                    outcome = .other_error;
                    other_err_name = @errorName(err);
                }
            }
        } else if (n_args == 1 and args[0] == .i32) {
            if (entry.callVoid_i32(compiled.module, func_idx, &rt, args[0].i32)) |_| {
                outcome = .did_not_trap;
            } else |err| {
                if (err == error.Trap) outcome = .trapped else {
                    outcome = .other_error;
                    other_err_name = @errorName(err);
                }
            }
        } else {
            try stdout.print("FAIL  {s}: assert_trap void-result with {d} args unsupported for {s}\n", .{ name, n_args, fn_name });
            return false;
        }
    } else if (std.mem.eql(u8, result_types_s, "v128")) {
        // v128 result; dispatch via the same shapes as invokeV128.
        // Only the shapes actually observed in assert_trap fixtures
        // are wired here (() and (i32,) — load/store OOB).
        if (n_args == 0) {
            if (entry.callV128NoArgs(compiled.module, func_idx, &rt)) |_| {
                outcome = .did_not_trap;
            } else |err| {
                if (err == error.Trap) outcome = .trapped else {
                    outcome = .other_error;
                    other_err_name = @errorName(err);
                }
            }
        } else if (n_args == 1 and args[0] == .i32) {
            if (entry.callV128_i32(compiled.module, func_idx, &rt, args[0].i32)) |_| {
                outcome = .did_not_trap;
            } else |err| {
                if (err == error.Trap) outcome = .trapped else {
                    outcome = .other_error;
                    other_err_name = @errorName(err);
                }
            }
        } else {
            try stdout.print("FAIL  {s}: assert_trap v128-result with {d} args unsupported for {s}\n", .{ name, n_args, fn_name });
            return false;
        }
    } else {
        try stdout.print("FAIL  {s}: assert_trap unsupported result type '{s}' for {s}\n", .{ name, result_types_s, fn_name });
        return false;
    }

    switch (outcome) {
        .trapped => return true,
        .did_not_trap => {
            try stdout.print("FAIL  {s}: assert_trap {s}({s}) did NOT trap\n", .{ name, fn_name, args_s });
            return false;
        },
        .other_error => {
            try stdout.print("FAIL  {s}: assert_trap {s}({s}) errored {s} (expected Trap)\n", .{ name, fn_name, args_s, other_err_name });
            return false;
        },
    }
}

fn laneSpecName(spec: LaneSpec) []const u8 {
    return switch (spec) {
        .canonical => "nan:canonical",
        .arithmetic => "nan:arithmetic",
        .exact => "exact",
    };
}
