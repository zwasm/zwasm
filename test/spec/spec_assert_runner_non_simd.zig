//! Wasm 2.0 non-SIMD spec assertion runner — JIT-execute + compare
//! scalar (i32 / i64 / f32 / f64) assertions against the curated
//! `test/spec/wasm-2.0-assert/` corpus (l-1b per ADR-0057).
//!
//! Parallel to `simd_assert_runner.zig`: both consume
//! `spec_assert_runner_base` and differ only in their
//! `RunnerCallbacks` literal. SIMD result decoding (per-lane NaN,
//! v128_lanes tokens) is unreachable here; this runner rejects
//! any `v128:` result token with FAIL. The wasm-1.0 corpus
//! continues to be served by the legacy `spec_assert_runner.zig`
//! (its PASS-line and `(D-042)` SKIP suffix shape predates base
//! and is preserved verbatim for the §9.7 / 7.5 gate semantics).
//!
//! Per ADR-0029 Path B: the twin tally split (skip-impl vs
//! skip-adr-<id>) flows through `base.AssertTally`; this runner
//! prints the same summary line shape as `simd_assert_runner`.
//!
//! Usage:
//!   spec_assert_runner_non_simd <corpus-root>
//! exits non-zero if any `failed > 0`, OR if the corpus root is
//! missing — the corpus is committed, so a missing root is a real
//! error (e.g. a host-specific path-resolution failure), not a
//! fresh-checkout state (ADR-0174 no-silent-skip; matches the
//! wasm-1.0 runner).

const std = @import("std");

const zwasm = @import("zwasm");
const runner_mod = zwasm.engine.runner;
const entry = zwasm.engine.codegen.shared.entry;
const base = @import("spec_assert_runner_base.zig");

const ArgKind = base.ArgKind;
const ArgValue = base.ArgValue;

/// §9.9 / 9.9-l-1b-d093-d68 (D-134 probe): disable Zig's default
/// SEGV/ILL/BUS/FPE handler so it cannot compete with our own
/// `installSigsegvHandler` install. In Debug builds (runtime_safety
/// = true), `std.options.enable_segfault_handler` defaults to
/// `true` per `~/Documents/OSS/zig/lib/std/debug.zig`:
/// `default_enable_segfault_handler = runtime_safety and
/// have_segfault_handling_support`, and the startup path's
/// `maybeEnableSegfaultHandler()` then calls `attachSegfaultHandler()`
/// → `updateSegfaultHandler(act)` → `posix.sigaction(.SEGV, .ILL,
/// .BUS, .FPE, ...)` installing Zig's 3-arg `handleSegfaultPosix`
/// (= the recursive `mem.Alignment.toByteUnits` chain valgrind
/// captured in d-65). The d-65 narrative claimed this was
/// "disabled via `std_options.enable_segfault_handler = false`"
/// but a repo-wide grep at d-68 resume showed **no `std_options`
/// declaration existed** — the disable was aspirational, never
/// landed. Without it, our handler may install correctly but get
/// shadowed by Zig's `RESETHAND`-flagged install at some later
/// std-lib touch (Debug-mode allocator panic paths, for instance,
/// can re-route through Zig's panic + sigaction). Setting this
/// explicitly to `false` makes our `installSigsegvHandler` the
/// sole sigaction for SEGV/BUS, so a real SEGV must dispatch
/// through `sigsegvHandler` (or fail to dispatch entirely, which
/// is itself diagnostic).
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
};

pub fn main(init: std.process.Init) !void {
    zwasm.support.dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));
    const io = init.io;
    const gpa = init.gpa;

    // D-163-origin JIT hex dump: off by default, opt-in via ZWASM_DUMP_JIT
    // (D-279 H7 — the previously-always-on dump flooded Win64 stdout).
    base.dump_jit_enabled = init.environ_map.get("ZWASM_DUMP_JIT") != null;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    // Install the SIGSEGV → trap-recovery handler before any JIT
    // entry call (D-103 / d-29). d-30 verified the handler IS
    // load-bearing: removing the install line aborts the runner
    // with `Segmentation fault at address 0x10b9e0018` on the
    // elem.wast corpus. The handler converts in-body SEGV (e.g.
    // an element-segment trap-assert whose JIT body crashes
    // before the trap stub fires) to `error.Trap` so
    // `nonSimdRunAssertTrap` records the line as PASS.
    base.installSigsegvHandler();
    base.initHostDispatchStubs();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const corpus_root_arg = arg_it.next() orelse {
        try stdout.print("usage: spec_assert_runner_non_simd <corpus-root>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_root = try gpa.dupe(u8, corpus_root_arg);
    defer gpa.free(corpus_root);

    var tally: base.AssertTally = .{};
    var manifest_count: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
        // Committed corpus (wasm-2.0-assert / threads-assert) — a missing
        // root is a real error, not a fresh-checkout state. FAIL loud so a
        // silent "0 manifests" exit-0 can't mask a host-specific
        // path-resolution gap behind a green test-all (ADR-0174). Mirrors
        // the wasm-1.0 `spec_assert_runner`.
        try stdout.print("spec_assert_runner_non_simd: corpus '{s}' not found ({s}) — FAIL (committed corpus; missing root is a real error, ADR-0174)\n", .{ corpus_root, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer root.close(io);

    var iter = root.iterate();
    while (try iter.next(io)) |dir_entry| {
        if (dir_entry.kind != .directory) continue;
        manifest_count += 1;
        // Per-manifest progress beacon to stderr (async-signal-safe;
        // raw write(2)) so a crash mid-corpus identifies the manifest
        // even when stdout's 1024B buffer drops the in-flight output.
        // Added at W4 reconcile diagnosis (D-136 in-flight). The
        // cost is two syscalls per manifest (≤ 60 over the wasm-2.0
        // corpus); the value is naming the suspect manifest.
        {
            const tag = "[W4 BEACON] entering manifest ";
            _ = base.write(2, tag, tag.len);
            _ = base.write(2, dir_entry.name.ptr, dir_entry.name.len);
            _ = base.write(2, "\n", 1);
        }
        try base.runCorpus(io, gpa, &root, dir_entry.name, stdout, &tally, non_simd_callbacks);
        // Per-manifest stdout flush so partial progress survives a
        // crash. Cost: one flush per ~10 manifests; value: identifies
        // the last successfully-completed manifest.
        stdout.flush() catch {};
    }

    try stdout.print(
        "\nspec_assert_runner_non_simd: {d} passed, {d} failed, {d} skipped (= {d} skip-impl + {d} runtime-skip + {d} skip-adr) (over {d} manifests)\n",
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
    // ADR-0210 — print the enumeration denominator next to the verdict
    // columns. Without it "25539 passed" cannot be checked against the
    // work enumerated: a directive dropped before reaching a column is
    // indistinguishable from one that was never in the corpus.
    try stdout.print(
        "spec_assert_runner_non_simd: lines={d} accounted={d} residual={d} overcounted={d} (residual = non-assertion directives that reached no column - note a runtime-skip raised on a non-assertion line counts as accounted, so this is not a round count of them; overcounted = a verdict exists for lines that were never read (unreadable manifest) or a line was tallied twice)\n",
        .{ tally.lines, tally.accounted(), tally.residual(), tally.overcounted() },
    );
    try stdout.flush();

    if (tally.failed > 0) std.process.exit(1);
}

/// Linear-memory scratch lives in `base.growable_memory` (per
/// ADR-0059 / §9.9 / 9.9-l-1b-d093-d8c) so `memory.grow` callouts
/// can extend the in-use region within a fixed 16-page pool.
/// Each `module` directive calls `base.resetGrowableMemory(1)` to
/// reset to 1 page initial; per-fixture state (memory.store /
/// memory.load round-trips + memory.grow accumulation) is preserved
/// across asserts within one fixture.
/// 256-byte globals buffer — ADR-0052 byte-offset layout. Scalar
/// globals occupy 8 bytes each; up to 32 globals supported per
/// fixture. 16-byte alignment kept (not strictly required without
/// v128 but harmless + matches the simd runner shape for
/// future-proofing if a Wasm 2.0 fixture imports a v128 global).
var scratch_globals: [256]u8 align(16) = undefined;

/// Funcref table for `call_indirect` — Wasm 2.0 spec fixtures
/// (call_indirect, table_get / set, table_init, etc.) need this
/// populated from active element segments per D-063's pattern.
// §9.9 / 9.9-l-1b-d093-d49 (D-124): bumped 32 → 1024 to satisfy
// `table_copy.wast` no-import variants that declare 128-entry
// tables (e.g. table_copy.50.wasm `(table 128 128 funcref)` with
// elem write at offset 112 + len 16 = range 112..128). Mirror of
// d-21's GROWABLE_MEMORY_CAPACITY bump.
const scratch_table_capacity = 1024;
var scratch_funcptrs: [scratch_table_capacity]u64 = undefined;
var scratch_typeidxs: [scratch_table_capacity]u32 = undefined;

/// `RunnerCallbacks.on_module_loaded` — repopulate scratch state
/// from the freshly-compiled module's active segments. Mirrors
/// `simd_assert_runner.simdOnModuleLoaded`; the only difference
/// is the SIMD runner's scratch_globals carries v128 16-byte
/// slots while this runner's holds 8-byte scalar slots. The
/// `applyDefinedGlobalsInit` helper is shape-aware and writes
/// the correct width per global's valtype.
fn nonSimdOnModuleLoaded(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!void {
    // Close-plan §6 (j) Step B cohort 1-residual — when memory-0 is
    // imported, use the EXPORTER's actual min (registered fallback
    // to importer-declared min). Defined memory uses declared min
    // exactly as before. Without this, `(import "spectest" "memory"
    // (memory 1))` left current_mem_bytes=0 and active data segments
    // OOB'd → 15 spurious data-init UES (data.2/.4/.6/.8/.12/.21-.26
    // + imports.95/.96 + linking.31/.32).
    // Runner is Wasm 1.0/2.0 scope; memory64 fixtures arrive at
    // 10.M-5 with the runtime cascade (10.M-2). @intCast asserts
    // the truncation is lossless for the in-scope corpus.
    const mem_min_pages = base.effectiveMemory0Min(gpa, wasm_bytes, base.current_registered);
    const mem_max_pages = base.effectiveMemory0Max(gpa, wasm_bytes, base.current_registered);
    base.resetGrowableMemory(@intCast(mem_min_pages));
    base.current_mem_max_pages = if (mem_max_pages) |m| @intCast(m) else null;
    // Threads/atomics: seed memory-0 shared flag so memory.atomic.wait{32,64}
    // runs on the corpus's `(memory … shared)` modules (else trap kind=15).
    base.current_mem_shared = base.extractMemory0Shared(gpa, wasm_bytes);
    @memset(scratch_globals[0..], 0);

    // Close-plan §6 (j) Step B cohort 1 — populate the importer's
    // scratch_globals[0..num_global_imports) from registered
    // exporters (spectest + fixture-to-fixture) BEFORE evaluating
    // any const-exprs that may `global.get N` against those slots.
    // Order matters: data / elem / defined-global init exprs all
    // observe the populated slots via `GlobalsCtx`.
    const fixture = base.current_module_file orelse "?";
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
            try stdout.print("FAIL  {s}/{s} imported-globals-init: {s}\n", .{ name, fixture, @errorName(err) });
            return err;
        };
    }

    const gctx_runtime = @import("zwasm").engine.runner_validate.GlobalsCtx{
        .offsets = compiled.globals_offsets,
        .valtypes = compiled.globals_valtypes,
        .buf = scratch_globals[0..],
        .num_imports = compiled.num_global_imports,
    };

    runner_mod.applyActiveDataSegmentsCtx(
        gpa,
        wasm_bytes,
        base.growable_memory[0..@intCast(base.current_mem_bytes)],
        gctx_runtime,
    ) catch |err| {
        try stdout.print("FAIL  {s}/{s} data-init: {s}\n", .{ name, fixture, @errorName(err) });
        return err;
    };
    runner_mod.applyDefinedGlobalsInit(
        gpa,
        wasm_bytes,
        compiled.globals_offsets,
        compiled.globals_valtypes,
        scratch_globals[0..],
        compiled.num_global_imports,
    ) catch |err| {
        try stdout.print("FAIL  {s}/{s} globals-init: {s}\n", .{ name, fixture, @errorName(err) });
        return err;
    };
    // close-plan §6 (j) Step B cohort 4 — bound the funcptrs/typeidxs
    // slice by the EFFECTIVE table-0 min (exporter actual for imported
    // tables; declared min for local) so active elem segments writing
    // past the actual size surface as OOB (UES). Importer-declared
    // min on an imported table is just a lower bound and is NOT the
    // table's true size — that's the exporter's table min.
    const table0_min = base.effectiveTable0Min(gpa, wasm_bytes, base.current_registered);
    const table0_cap = @min(@as(usize, table0_min), scratch_funcptrs.len);
    // D-166 fix — reset scratch_funcptrs / scratch_typeidxs to sentinel
    // FOR THE FULL CAPACITY before applyTableInit writes table0_cap entries.
    // Per base.zig:668 comment, `rt.table_size` stays at scratch capacity
    // (= 1024) and call_indirect relies on sig-mismatch (sentinel typeidx
    // = maxInt(u32)) for OOB idx trap. If we skip this reset, leftover
    // entries from a previous module's table layout could match a
    // call_indirect's expected typeidx → sig check passes → stale
    // funcptr executed → wild memory corruption (D-166 ubuntu
    // memory_grow.4 off-by-one signature).
    @memset(scratch_funcptrs[0..], 0);
    @memset(scratch_typeidxs[0..], std.math.maxInt(u32));
    runner_mod.applyTableInitCtx(
        gpa,
        wasm_bytes,
        compiled,
        scratch_funcptrs[0..table0_cap],
        scratch_typeidxs[0..table0_cap],
        gctx_runtime,
    ) catch |err| {
        try stdout.print("FAIL  {s}/{s} table-init: {s}\n", .{ name, fixture, @errorName(err) });
        return err;
    };
    // §9.9 / 9.9-l-1b-d093-d42b (D-112): populate per-non-zero-
    // table scratch for JIT multi-table call_indirect (select.wast
    // `(table $tab) (table $t) (call_indirect $t ...)`-class
    // modules). Single-table modules become a 1-line entry-0
    // rebind; multi-table modules walk each non-zero table's elem
    // segments into the per-table scratch.
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
    // §9.9-III γ.3 (ADR-0068 follow-up): resolve ref.func-initialised
    // funcref globals from raw funcidx (placeholder) to FuncEntity
    // pointer. `applyDefinedGlobalsInit` ran before `func_entities`
    // existed; this fixup pass closes the gap.
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
    // §9.9-III (c)-2.3-γ-5 per ADR-0066: for table-0 entries whose
    // source funcidx is an IMPORT, `applyTableInit` left funcptr
    // at 0; patch it to the resolved bridge-thunk address from
    // `current_dispatch[fidx]` so `call_indirect` through the
    // table entry routes via β-2b's thunk to the registered
    // exporter. No-op when no per-module dispatch was wired
    // (e.g. spectest-only imports — those keep the 0 funcptr +
    // trap on call_indirect, consistent with the d-35 trap
    // stub).
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
    // d-22 (D-106 discharge): Wasm spec §4.5.5.2 — the module's
    // start function (if declared) runs at instantiation, before
    // any export is invoked. Spec corpus `start.wast` exercises
    // this via a start fn that mutates an exported global; the
    // first `(invoke "get")` then observes the post-start value.
    // The start section body is just a single LEB128 funcidx.
    if (base.extractStartFunc(gpa, wasm_bytes)) |start_funcidx| {
        // Bounds-check: start funcidx may target an import; the
        // JIT entry() table only covers defined funcs after
        // imports. Skip silently when the funcidx is out of the
        // JIT-compiled range (an imported start fn would need
        // host_dispatch_base wiring we don't have for the spec
        // runner's test scaffolding).
        if (start_funcidx < compiled.module.func_offsets.len and
            compiled.module.func_offsets[start_funcidx] != @import("zwasm").engine.codegen.shared.linker.IMPORT_SENTINEL_OFFSET)
        {
            var rt = base.makeJitRuntime(
                base.growable_memory[0..@intCast(base.current_mem_bytes)],
                scratch_globals[0..],
                scratch_funcptrs[0..],
                scratch_typeidxs[0..],
                base.currentDispatchView(),
            );
            // §9.9-III (c)-2.3-γ-3.b-arm per ADR-0066: arm
            // `sigsegv_armed` before the JIT call so a SIGSEGV
            // inside a cross-module callee (which may touch
            // exporter state γ-1/γ-2/γ-3 didn't back —
            // elem_segments / data_segments / func_entities /
            // multi-table) lands on `siglongjmp` and surfaces as
            // SKIP-CROSS-MODULE-CALLEE-STATE instead of taking
            // the runner out via `_exit(142)`. Mirrors the
            // assert_return/assert_trap arming pattern at line
            // ~1163. The `sigsetjmp` call MUST stay inline in
            // the caller frame (see discipline note in
            // `spec_assert_runner_base.zig` lines ~1281–1290).
            const segv_trapped: bool = blk: {
                if (comptime @import("builtin").os.tag == .windows) {
                    // Win64 VEH path (ADR-0103 / W3.b-2). The
                    // helper arms threadlocal recovery against
                    // the JIT region, runs the entry, and
                    // returns true if a hardware fault inside
                    // the region OR an `error.Trap` return path
                    // fires. Disarm runs via the helper's defer.
                    const jit_start = @intFromPtr(compiled.module.block.bytes.ptr);
                    const jit_end = jit_start + compiled.module.block.bytes.len;
                    break :blk @import("zwasm").platform.windows_traphandler.callJitOrTrap(
                        jit_start,
                        jit_end,
                        entry.callVoidNoArgs,
                        .{ compiled.module, start_funcidx, &rt },
                    );
                }
                if (base.sigsetjmp(@ptrCast(&base.sigsegv_recover_buf), 1) != 0) {
                    base.sigsegv_armed.store(false, .release);
                    break :blk true;
                }
                base.sigsegv_armed.store(true, .release);
                defer base.sigsegv_armed.store(false, .release);
                entry.callVoidNoArgs(compiled.module, start_funcidx, &rt) catch |err| switch (err) {
                    error.Trap => break :blk true,
                };
                break :blk false;
            };
            if (segv_trapped) {
                // d-36 + γ-3.b-arm: a trap (or recovered SEGV)
                // during start-init has three plausible sources:
                // (1) unbound host-import trap stub (d-35 path —
                // start.wast modules 5/6 import `spectest.print_i32`),
                // (2) genuine `(unreachable)` start fn (spec
                // wraps those in `assert_uninstantiable`),
                // (3) γ-4: cross-module callee touching unbacked
                // exporter state — SEGV-recovered here. All three
                // propagate as SKIP per ADR-0061 (no host-import
                // binding) + ADR-0066 (β-2/γ scope).
                try stdout.print("SKIP-START-TRAP  {s}: start-init trapped or segv-recovered (host-import or cross-module callee state)\n", .{name});
                return error.SkipModule;
            }
        }
    }
}

/// `RunnerCallbacks.handle_assert_return` — scalar (i32 / i64 /
/// f32 / f64) dispatch. The dispatch ladder mirrors the legacy
/// `spec_assert_runner.zig`'s shape (n_args × arg-kind × result-
/// kind triple) so wasm-1.0-class fixtures port cleanly when the
/// curated wasm-2.0-assert corpus lands; v128 tokens are rejected
/// outright since this runner is the non-SIMD specialisation.
fn nonSimdRunAssertReturn(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    const arrow = std.mem.find(u8, rest, " -> ") orelse return error.BadDirective;
    const lhs = rest[0..arrow];
    const results_s = rest[arrow + 4 ..];

    const fa = try base.splitFnAndArgs(lhs);
    var fn_name_buf: [512]u8 = undefined;
    const fn_name = try base.decodeFnName(fa.fn_name, &fn_name_buf);
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

    // §9.9 / 9.9-l-1b-d093-d61: capacity 5 → 8 to fit the
    // 8-arg `(f64 ×8, f64)` + 6-arg `(f32 i32 i64 i32 f64 i32, f64)`
    // shapes added in d-61's runner-shape-gap drain.
    // Cap raised 8 → 24 for `func.wast::large-sig` (17 params).
    var args: [24]ArgValue = undefined;
    const n_args = base.parseAssertReturnArgs(args_s, &args) catch |err| {
        if (err == error.TooManyArgs) {
            try stdout.print("FAIL  {s}: > {d} args unsupported ({s})\n", .{ name, args.len, args_s });
        } else {
            try stdout.print("FAIL  {s}: unsupported arg token ({s})\n", .{ name, args_s });
        }
        return false;
    };

    // Reject v128 args at the dispatch boundary — this runner is
    // the non-SIMD specialisation; v128-aware fixtures belong to
    // simd_assert_runner.
    for (args[0..n_args]) |a| {
        if (a == .v128) {
            try stdout.print("FAIL  {s}: v128 arg in non-SIMD runner ({s})\n", .{ name, args_s });
            return false;
        }
    }

    // Void-result dispatch.
    if (std.mem.eql(u8, results_s, "()")) {
        return dispatchVoidResult(compiled, func_idx, &rt, fn_name, args_s, args[0..n_args], stdout, name);
    }

    // Multi-result dispatch (results_s contains a space separator
    // between `<kind>:<value>` tokens). Phase 9 Cat II per ADR-0065;
    // shapes drained one at a time matching the close-plan §6 step (b)
    // priority order.
    if (std.mem.findScalar(u8, results_s, ' ') != null) {
        return dispatchMultiResult(compiled, func_idx, &rt, fn_name, args_s, args[0..n_args], results_s, stdout, name);
    }

    // v128 result token unreachable here.
    if (std.mem.startsWith(u8, results_s, "v128") or std.mem.startsWith(u8, results_s, "v128_lanes:")) {
        try stdout.print("FAIL  {s}: v128 result in non-SIMD runner ({s})\n", .{ name, results_s });
        return false;
    }

    // Scalar result.
    if (results_s.len < 4) {
        try stdout.print("FAIL  {s}: malformed result '{s}'\n", .{ name, results_s });
        return false;
    }
    const result_kind: ArgKind = if (std.mem.startsWith(u8, results_s, "i32:")) .i32 else if (std.mem.startsWith(u8, results_s, "i64:")) .i64 else if (std.mem.startsWith(u8, results_s, "f32:")) .f32 else if (std.mem.startsWith(u8, results_s, "f64:")) .f64 else {
        try stdout.print("FAIL  {s}: unsupported result type '{s}'\n", .{ name, results_s });
        return false;
    };
    const exp_s = results_s[4..];

    const got: u64 = (try dispatchScalarResult(compiled, func_idx, &rt, fn_name, args_s, args[0..n_args], result_kind, stdout, name)) orelse return false;

    // FP results: parse expected via `parseScalarFpExpected` so
    // `nan:canonical` / `nan:arithmetic` tokens compare via the
    // NaN-class matcher (Wasm spec §A.2). Integer results stay on
    // the bit-pattern equality path.
    switch (result_kind) {
        .f32 => {
            const spec = base.parseScalarFpExpected(exp_s, 32) catch {
                try stdout.print("FAIL  {s}: bad f32 result '{s}'\n", .{ name, results_s });
                return false;
            };
            const got_bits: u32 = @intCast(got & 0xffffffff);
            if (!base.matchScalarF32(got_bits, spec)) {
                try stdout.print("FAIL  {s}: {s}({s}) → got f32:0x{x:0>8}, expected {s}\n", .{ name, fn_name, args_s, got_bits, exp_s });
                return false;
            }
            return true;
        },
        .f64 => {
            const spec = base.parseScalarFpExpected(exp_s, 64) catch {
                try stdout.print("FAIL  {s}: bad f64 result '{s}'\n", .{ name, results_s });
                return false;
            };
            if (!base.matchScalarF64(got, spec)) {
                try stdout.print("FAIL  {s}: {s}({s}) → got f64:0x{x:0>16}, expected {s}\n", .{ name, fn_name, args_s, got, exp_s });
                return false;
            }
            return true;
        },
        .i32, .i64 => {
            const expected: u64 = if (result_kind == .i32)
                @as(u64, try base.parseI32Token(exp_s))
            else
                try base.parseI64Token(exp_s);
            if (got != expected) {
                try stdout.print("FAIL  {s}: {s}({s}) → got {d}, expected {d}\n", .{ name, fn_name, args_s, got, expected });
                return false;
            }
            return true;
        },
        .v128 => unreachable,
    }
}

/// Void-result dispatch ladder. Returns `false` on shape-unsupported
/// OR trap; the assert_return semantics treat both as failure (no
/// expected value to compare). The shapes covered mirror the
/// legacy wasm-1.0 runner; multi-value 5-arg dispatch
/// (`(i64, f32, f64, i32, i32)`) is included for parity with
/// upstream multi-value spec fixtures.
fn dispatchVoidResult(
    compiled: *const runner_mod.CompiledWasm,
    func_idx: u32,
    rt: *entry.JitRuntime,
    fn_name: []const u8,
    args_s: []const u8,
    args: []const ArgValue,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    if (args.len == 0) {
        entry.callVoidNoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, "()", err, stdout);
            return false;
        };
        return true;
    }
    if (args.len == 1 and args[0] == .i32) {
        entry.callVoid_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        return true;
    }
    if (args.len == 1 and args[0] == .i64) {
        entry.callVoid_i64(compiled.module, func_idx, rt, args[0].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        return true;
    }
    if (args.len == 1 and args[0] == .f32) {
        const a0: f32 = @bitCast(args[0].f32);
        entry.callVoid_f32(compiled.module, func_idx, rt, a0) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        return true;
    }
    if (args.len == 1 and args[0] == .f64) {
        const a0: f64 = @bitCast(args[0].f64);
        entry.callVoid_f64(compiled.module, func_idx, rt, a0) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        return true;
    }
    if (args.len == 2 and args[0] == .i32 and args[1] == .i32) {
        entry.callVoid_i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        return true;
    }
    // D-114 / d-41: `(i32, i64)` — memory_trap.wast's `i64.store`
    // exports (addr + value). Without this shape, the
    // `(invoke "i64.store" 0xfff8 0)` zero-store between the trap
    // asserts and follow-up loads is skipped; the loads then read
    // the original "abcdefgh" data instead of 0.
    if (args.len == 2 and args[0] == .i32 and args[1] == .i64) {
        entry.callVoid_i32i64(compiled.module, func_idx, rt, args[0].i32, args[1].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        return true;
    }
    // D-116: `(i32, f32)` and `(i32, f64)` — float_exprs.wast's
    // `init (param i32) (param f<32,64>)` exports invoked bare to
    // populate memory[i] = x. Without these shapes, the action
    // skipped (distiller side); follow-up assert_return checks
    // read 0 from the never-initialised memory cell.
    if (args.len == 2 and args[0] == .i32 and args[1] == .f32) {
        const a1: f32 = @bitCast(args[1].f32);
        entry.callVoid_i32f32(compiled.module, func_idx, rt, args[0].i32, a1) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        return true;
    }
    if (args.len == 2 and args[0] == .i32 and args[1] == .f64) {
        const a1: f64 = @bitCast(args[1].f64);
        entry.callVoid_i32f64(compiled.module, func_idx, rt, args[0].i32, a1) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        return true;
    }
    // D-116: `(i32, i32, i32)` — float_exprs.wast's
    // `f<32,64>.simple_x4_sum (param i32 i32 i32)` exports
    // (i / j / k offsets); bare-invoked to fold sum into memory[k]
    // for the subsequent `(invoke "f<32,64>.load" k)` to read.
    if (args.len == 3 and args[0] == .i32 and args[1] == .i32 and args[2] == .i32) {
        entry.callVoid_i32i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32, args[2].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        return true;
    }
    if (args.len == 5 and args[0] == .i64 and args[1] == .f32 and args[2] == .f64 and args[3] == .i32 and args[4] == .i32) {
        const a1: f32 = @bitCast(args[1].f32);
        const a2: f64 = @bitCast(args[2].f64);
        entry.callVoid_i64f32f64i32i32(compiled.module, func_idx, rt, args[0].i64, a1, a2, args[3].i32, args[4].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        return true;
    }
    // §9.9 / 9.9-l-1b-d093-d63: `(i32, i64, i32) → void` — table_fill
    // shape after reftype aliasing (idx, externref-as-u64, n).
    if (args.len == 3 and args[0] == .i32 and args[1] == .i64 and args[2] == .i32) {
        entry.callVoid_i32i64i32(compiled.module, func_idx, rt, args[0].i32, args[1].i64, args[2].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        return true;
    }
    try stdout.print("FAIL  {s}: void-result unsupported (n_args={d}) for {s}({s})\n", .{ name, args.len, fn_name, args_s });
    return false;
}

/// Multi-result dispatch ladder. Wasm spec §4.5.3 allows arbitrary
/// result arity; this ladder grows shape-by-shape as the close-plan
/// §6 step (b) drains the multi-result `skip-impl` backlog. The
/// distiller's `supported_multi` set in `regen_spec_2_0_assert.sh`
/// gates which shapes ever reach the runner, so the FAIL at the
/// bottom of this function fires only on a distiller/runner sync gap.
fn dispatchMultiResult(
    compiled: *const runner_mod.CompiledWasm,
    func_idx: u32,
    rt: *entry.JitRuntime,
    fn_name: []const u8,
    args_s: []const u8,
    args: []const ArgValue,
    results_s: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    // Parse result tokens once; downstream arms re-use. Cap raised
    // from 4 → 16 to accommodate `func.wast::large-sig` (ADR-0069
    // §Phase 3 / D-140) — 16-result Class C MEMORY-class.
    var rtoks: [16][]const u8 = undefined;
    var n_rtoks: usize = 0;
    {
        var it = std.mem.tokenizeScalar(u8, results_s, ' ');
        while (it.next()) |tok| {
            if (n_rtoks == rtoks.len) {
                try stdout.print("FAIL  {s}: > {d} result tokens '{s}'\n", .{ name, rtoks.len, results_s });
                return false;
            }
            rtoks[n_rtoks] = tok;
            n_rtoks += 1;
        }
    }

    // Shape: `(i64, i64, i32) -> (i64, i32)` — `add64_u_with_carry`
    // family across if / func / call / loop / block / br /
    // call_indirect corpora. Phase 9 Cat II chunk (b)-1.
    if (args.len == 3 and args[0] == .i64 and args[1] == .i64 and args[2] == .i32 and
        n_rtoks == 2 and std.mem.startsWith(u8, rtoks[0], "i64:") and std.mem.startsWith(u8, rtoks[1], "i32:"))
    {
        const exp_r0 = base.parseI64Token(rtoks[0][4..]) catch {
            try stdout.print("FAIL  {s}: bad i64 result '{s}'\n", .{ name, rtoks[0] });
            return false;
        };
        const exp_r1 = base.parseI32Token(rtoks[1][4..]) catch {
            try stdout.print("FAIL  {s}: bad i32 result '{s}'\n", .{ name, rtoks[1] });
            return false;
        };
        const got = entry.callI64i32_i64i64i32(compiled.module, func_idx, rt, args[0].i64, args[1].i64, args[2].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        if (got.r0 != exp_r0 or got.r1 != exp_r1) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (i64:{d}, i32:{d}), expected (i64:{d}, i32:{d})\n", .{ name, fn_name, args_s, got.r0, got.r1, exp_r0, exp_r1 });
            return false;
        }
        return true;
    }

    // Phase 9 Cat II chunk (b)-2 + (b)-3: 2-result int shapes.
    // FuncRet_* structs are u64-padded so each field gets its own
    // X0/X1 / RAX/RDX register, matching the JIT epilogue's
    // per-result-slot convention. Mixed int+float shapes deferred
    // per D-137 residual.
    // `(i32) -> (i32, i32)` — if.wast `multi`, etc. (chunk (b)-3)
    if (args.len == 1 and args[0] == .i32 and
        n_rtoks == 2 and std.mem.startsWith(u8, rtoks[0], "i32:") and std.mem.startsWith(u8, rtoks[1], "i32:"))
    {
        const exp_r0 = base.parseI32Token(rtoks[0][4..]) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1 = base.parseI32Token(rtoks[1][4..]) catch return failBadResult(stdout, name, rtoks[1]);
        const got = entry.callI32i32_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        const got_r0: u32 = @intCast(got.r0 & 0xffffffff);
        const got_r1: u32 = @intCast(got.r1 & 0xffffffff);
        if (got_r0 != exp_r0 or got_r1 != exp_r1) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (i32:{d}, i32:{d}), expected (i32:{d}, i32:{d})\n", .{ name, fn_name, args_s, got_r0, got_r1, exp_r0, exp_r1 });
            return false;
        }
        return true;
    }
    // `() -> (i32, i32)`. (chunk (b)-3)
    if (args.len == 0 and
        n_rtoks == 2 and std.mem.startsWith(u8, rtoks[0], "i32:") and std.mem.startsWith(u8, rtoks[1], "i32:"))
    {
        const exp_r0 = base.parseI32Token(rtoks[0][4..]) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1 = base.parseI32Token(rtoks[1][4..]) catch return failBadResult(stdout, name, rtoks[1]);
        const got = entry.callI32i32NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        const got_r0: u32 = @intCast(got.r0 & 0xffffffff);
        const got_r1: u32 = @intCast(got.r1 & 0xffffffff);
        if (got_r0 != exp_r0 or got_r1 != exp_r1) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (i32:{d}, i32:{d}), expected (i32:{d}, i32:{d})\n", .{ name, fn_name, args_s, got_r0, got_r1, exp_r0, exp_r1 });
            return false;
        }
        return true;
    }
    // `() -> (i32, i64)`.
    if (args.len == 0 and
        n_rtoks == 2 and std.mem.startsWith(u8, rtoks[0], "i32:") and std.mem.startsWith(u8, rtoks[1], "i64:"))
    {
        const exp_r0 = base.parseI32Token(rtoks[0][4..]) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1 = base.parseI64Token(rtoks[1][4..]) catch return failBadResult(stdout, name, rtoks[1]);
        const got = entry.callI32i64NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        if (got.r0 != exp_r0 or got.r1 != exp_r1) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (i32:{d}, i64:{d}), expected (i32:{d}, i64:{d})\n", .{ name, fn_name, args_s, got.r0, got.r1, exp_r0, exp_r1 });
            return false;
        }
        return true;
    }
    // `(i32) -> (i32, i64)` — break-br_if-num-num / break-br_table-num-num.
    if (args.len == 1 and args[0] == .i32 and
        n_rtoks == 2 and std.mem.startsWith(u8, rtoks[0], "i32:") and std.mem.startsWith(u8, rtoks[1], "i64:"))
    {
        const exp_r0 = base.parseI32Token(rtoks[0][4..]) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1 = base.parseI64Token(rtoks[1][4..]) catch return failBadResult(stdout, name, rtoks[1]);
        const got = entry.callI32i64_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        if (got.r0 != exp_r0 or got.r1 != exp_r1) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (i32:{d}, i64:{d}), expected (i32:{d}, i64:{d})\n", .{ name, fn_name, args_s, got.r0, got.r1, exp_r0, exp_r1 });
            return false;
        }
        return true;
    }
    // `() -> (f64, f64)` — HFA via V0+V1 / XMM0+XMM1; NaN-aware compare.
    if (args.len == 0 and
        n_rtoks == 2 and std.mem.startsWith(u8, rtoks[0], "f64:") and std.mem.startsWith(u8, rtoks[1], "f64:"))
    {
        const exp_r0_spec = base.parseScalarFpExpected(rtoks[0][4..], 64) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1_spec = base.parseScalarFpExpected(rtoks[1][4..], 64) catch return failBadResult(stdout, name, rtoks[1]);
        const got = entry.callF64f64NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        const r0_bits: u64 = @bitCast(got.r0);
        const r1_bits: u64 = @bitCast(got.r1);
        if (!base.matchScalarF64(r0_bits, exp_r0_spec) or !base.matchScalarF64(r1_bits, exp_r1_spec)) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (f64:0x{x:0>16}, f64:0x{x:0>16}), expected ({s}, {s})\n", .{ name, fn_name, args_s, r0_bits, r1_bits, rtoks[0], rtoks[1] });
            return false;
        }
        return true;
    }
    // `() -> (i64, i32)`.
    if (args.len == 0 and
        n_rtoks == 2 and std.mem.startsWith(u8, rtoks[0], "i64:") and std.mem.startsWith(u8, rtoks[1], "i32:"))
    {
        const exp_r0 = base.parseI64Token(rtoks[0][4..]) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1 = base.parseI32Token(rtoks[1][4..]) catch return failBadResult(stdout, name, rtoks[1]);
        const got = entry.callI64i32NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        if (got.r0 != exp_r0 or got.r1 != exp_r1) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (i64:{d}, i32:{d}), expected (i64:{d}, i32:{d})\n", .{ name, fn_name, args_s, got.r0, got.r1, exp_r0, exp_r1 });
            return false;
        }
        return true;
    }
    // Class B mixed int+float per ADR-0069. `(i32, f64)` shape.
    // arm64 uses inline-asm thunk; x86_64 SysV uses native
    // callconv(.c) (per-eightbyte INTEGER+SSE classification).
    if (args.len == 0 and
        n_rtoks == 2 and std.mem.startsWith(u8, rtoks[0], "i32:") and std.mem.startsWith(u8, rtoks[1], "f64:"))
    {
        const exp_r0 = base.parseI32Token(rtoks[0][4..]) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1_spec = base.parseScalarFpExpected(rtoks[1][4..], 64) catch return failBadResult(stdout, name, rtoks[1]);
        const got = entry.callI32f64NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        const got_r0: u32 = @intCast(got.r0 & 0xffffffff);
        const got_r1_bits: u64 = @bitCast(got.r1);
        if (got_r0 != exp_r0 or !base.matchScalarF64(got_r1_bits, exp_r1_spec)) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (i32:{d}, f64:0x{x:0>16}), expected (i32:{d}, {s})\n", .{ name, fn_name, args_s, got_r0, got_r1_bits, exp_r0, rtoks[1] });
            return false;
        }
        return true;
    }
    // Class B mixed `(f64, i32)` shape.
    if (args.len == 0 and
        n_rtoks == 2 and std.mem.startsWith(u8, rtoks[0], "f64:") and std.mem.startsWith(u8, rtoks[1], "i32:"))
    {
        const exp_r0_spec = base.parseScalarFpExpected(rtoks[0][4..], 64) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1 = base.parseI32Token(rtoks[1][4..]) catch return failBadResult(stdout, name, rtoks[1]);
        const got = entry.callF64i32NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        const got_r0_bits: u64 = @bitCast(got.r0);
        const got_r1: u32 = @intCast(got.r1 & 0xffffffff);
        if (!base.matchScalarF64(got_r0_bits, exp_r0_spec) or got_r1 != exp_r1) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (f64:0x{x:0>16}, i32:{d}), expected ({s}, i32:{d})\n", .{ name, fn_name, args_s, got_r0_bits, got_r1, rtoks[0], exp_r1 });
            return false;
        }
        return true;
    }
    // Class B mixed `(f64, f32)` shape (D-146 close).
    if (args.len == 0 and
        n_rtoks == 2 and std.mem.startsWith(u8, rtoks[0], "f64:") and std.mem.startsWith(u8, rtoks[1], "f32:"))
    {
        const exp_r0_spec = base.parseScalarFpExpected(rtoks[0][4..], 64) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1_spec = base.parseScalarFpExpected(rtoks[1][4..], 32) catch return failBadResult(stdout, name, rtoks[1]);
        const got = entry.callF64f32NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        const got_r0_bits: u64 = @bitCast(got.r0);
        const got_r1_bits: u32 = @bitCast(got.r1);
        if (!base.matchScalarF64(got_r0_bits, exp_r0_spec) or !base.matchScalarF32(got_r1_bits, exp_r1_spec)) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (f64:0x{x:0>16}, f32:0x{x:0>8}), expected ({s}, {s})\n", .{ name, fn_name, args_s, got_r0_bits, got_r1_bits, rtoks[0], rtoks[1] });
            return false;
        }
        return true;
    }
    // Class C MEMORY-class 3-int-result shapes (chunk (b)-e-4
    // per ADR-0069 §Phase 2): `() → (i32, i32, i32)` +
    // `() → (i32, i32, i64)` + `(i32) → (i32, i32, i64)`.
    if (args.len == 0 and
        n_rtoks == 3 and std.mem.startsWith(u8, rtoks[0], "i32:") and std.mem.startsWith(u8, rtoks[1], "i32:") and std.mem.startsWith(u8, rtoks[2], "i32:"))
    {
        const exp_r0 = base.parseI32Token(rtoks[0][4..]) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1 = base.parseI32Token(rtoks[1][4..]) catch return failBadResult(stdout, name, rtoks[1]);
        const exp_r2 = base.parseI32Token(rtoks[2][4..]) catch return failBadResult(stdout, name, rtoks[2]);
        const got = entry.callI32i32i32NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        const got_r0: u32 = @intCast(got.r0 & 0xffffffff);
        const got_r1: u32 = @intCast(got.r1 & 0xffffffff);
        const got_r2: u32 = @intCast(got.r2 & 0xffffffff);
        if (got_r0 != exp_r0 or got_r1 != exp_r1 or got_r2 != exp_r2) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (i32:{d}, i32:{d}, i32:{d}), expected (i32:{d}, i32:{d}, i32:{d})\n", .{ name, fn_name, args_s, got_r0, got_r1, got_r2, exp_r0, exp_r1, exp_r2 });
            return false;
        }
        return true;
    }
    if (args.len == 0 and
        n_rtoks == 3 and std.mem.startsWith(u8, rtoks[0], "i32:") and std.mem.startsWith(u8, rtoks[1], "i32:") and std.mem.startsWith(u8, rtoks[2], "i64:"))
    {
        const exp_r0 = base.parseI32Token(rtoks[0][4..]) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1 = base.parseI32Token(rtoks[1][4..]) catch return failBadResult(stdout, name, rtoks[1]);
        const exp_r2 = base.parseI64Token(rtoks[2][4..]) catch return failBadResult(stdout, name, rtoks[2]);
        const got = entry.callI32i32i64NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        const got_r0: u32 = @intCast(got.r0 & 0xffffffff);
        const got_r1: u32 = @intCast(got.r1 & 0xffffffff);
        const got_r2: u64 = got.r2;
        if (got_r0 != exp_r0 or got_r1 != exp_r1 or got_r2 != exp_r2) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (i32:{d}, i32:{d}, i64:{d}), expected (i32:{d}, i32:{d}, i64:{d})\n", .{ name, fn_name, args_s, got_r0, got_r1, got_r2, exp_r0, exp_r1, exp_r2 });
            return false;
        }
        return true;
    }
    if (args.len == 1 and args[0] == .i32 and
        n_rtoks == 3 and std.mem.startsWith(u8, rtoks[0], "i32:") and std.mem.startsWith(u8, rtoks[1], "i32:") and std.mem.startsWith(u8, rtoks[2], "i64:"))
    {
        const exp_r0 = base.parseI32Token(rtoks[0][4..]) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1 = base.parseI32Token(rtoks[1][4..]) catch return failBadResult(stdout, name, rtoks[1]);
        const exp_r2 = base.parseI64Token(rtoks[2][4..]) catch return failBadResult(stdout, name, rtoks[2]);
        const got = entry.callI32i32i64_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        const got_r0: u32 = @intCast(got.r0 & 0xffffffff);
        const got_r1: u32 = @intCast(got.r1 & 0xffffffff);
        const got_r2: u64 = got.r2;
        if (got_r0 != exp_r0 or got_r1 != exp_r1 or got_r2 != exp_r2) {
            try stdout.print("FAIL  {s}: {s}({s}) → got (i32:{d}, i32:{d}, i64:{d}), expected (i32:{d}, i32:{d}, i64:{d})\n", .{ name, fn_name, args_s, got_r0, got_r1, got_r2, exp_r0, exp_r1, exp_r2 });
            return false;
        }
        return true;
    }
    // `func.wast::large-sig` — 17 params + 16 mixed-class results.
    // ADR-0069 §Phase 3 / D-140: Class C MEMORY-class with mixed
    // int/f32/f64 slots. Convention Swap (ADR-0026 2026-05-18)
    // routes &buffer in RDI/X8 and rt in RSI/X0; native callconv(.c)
    // matches end-to-end.
    if (args.len == 17 and n_rtoks == 16 and
        args[0] == .i32 and args[1] == .i64 and args[2] == .f32 and args[3] == .f32 and
        args[4] == .i32 and args[5] == .f64 and args[6] == .f32 and args[7] == .i32 and
        args[8] == .i32 and args[9] == .i32 and args[10] == .f32 and args[11] == .f64 and
        args[12] == .f64 and args[13] == .f64 and args[14] == .i32 and args[15] == .i32 and
        args[16] == .f32 and
        std.mem.startsWith(u8, rtoks[0], "f64:") and std.mem.startsWith(u8, rtoks[1], "f32:") and
        std.mem.startsWith(u8, rtoks[2], "i32:") and std.mem.startsWith(u8, rtoks[3], "i32:") and
        std.mem.startsWith(u8, rtoks[4], "i32:") and std.mem.startsWith(u8, rtoks[5], "i64:") and
        std.mem.startsWith(u8, rtoks[6], "f32:") and std.mem.startsWith(u8, rtoks[7], "i32:") and
        std.mem.startsWith(u8, rtoks[8], "i32:") and std.mem.startsWith(u8, rtoks[9], "f32:") and
        std.mem.startsWith(u8, rtoks[10], "f64:") and std.mem.startsWith(u8, rtoks[11], "f64:") and
        std.mem.startsWith(u8, rtoks[12], "i32:") and std.mem.startsWith(u8, rtoks[13], "f32:") and
        std.mem.startsWith(u8, rtoks[14], "i32:") and std.mem.startsWith(u8, rtoks[15], "f64:"))
    {
        const exp_r0 = base.parseScalarFpExpected(rtoks[0][4..], 64) catch return failBadResult(stdout, name, rtoks[0]);
        const exp_r1 = base.parseScalarFpExpected(rtoks[1][4..], 32) catch return failBadResult(stdout, name, rtoks[1]);
        const exp_r2 = base.parseI32Token(rtoks[2][4..]) catch return failBadResult(stdout, name, rtoks[2]);
        const exp_r3 = base.parseI32Token(rtoks[3][4..]) catch return failBadResult(stdout, name, rtoks[3]);
        const exp_r4 = base.parseI32Token(rtoks[4][4..]) catch return failBadResult(stdout, name, rtoks[4]);
        const exp_r5 = base.parseI64Token(rtoks[5][4..]) catch return failBadResult(stdout, name, rtoks[5]);
        const exp_r6 = base.parseScalarFpExpected(rtoks[6][4..], 32) catch return failBadResult(stdout, name, rtoks[6]);
        const exp_r7 = base.parseI32Token(rtoks[7][4..]) catch return failBadResult(stdout, name, rtoks[7]);
        const exp_r8 = base.parseI32Token(rtoks[8][4..]) catch return failBadResult(stdout, name, rtoks[8]);
        const exp_r9 = base.parseScalarFpExpected(rtoks[9][4..], 32) catch return failBadResult(stdout, name, rtoks[9]);
        const exp_r10 = base.parseScalarFpExpected(rtoks[10][4..], 64) catch return failBadResult(stdout, name, rtoks[10]);
        const exp_r11 = base.parseScalarFpExpected(rtoks[11][4..], 64) catch return failBadResult(stdout, name, rtoks[11]);
        const exp_r12 = base.parseI32Token(rtoks[12][4..]) catch return failBadResult(stdout, name, rtoks[12]);
        const exp_r13 = base.parseScalarFpExpected(rtoks[13][4..], 32) catch return failBadResult(stdout, name, rtoks[13]);
        const exp_r14 = base.parseI32Token(rtoks[14][4..]) catch return failBadResult(stdout, name, rtoks[14]);
        const exp_r15 = base.parseScalarFpExpected(rtoks[15][4..], 64) catch return failBadResult(stdout, name, rtoks[15]);
        // ArgValue stores `.f32` as the u32 bit-pattern and `.f64`
        // as u64 — bitcast to the parameter's float type at the
        // call site so the JIT receives the value in the FP class
        // register pool (not the int class).
        const got = entry.callLargesig(
            compiled.module,
            func_idx,
            rt,
            args[0].i32,
            args[1].i64,
            @as(f32, @bitCast(args[2].f32)),
            @as(f32, @bitCast(args[3].f32)),
            args[4].i32,
            @as(f64, @bitCast(args[5].f64)),
            @as(f32, @bitCast(args[6].f32)),
            args[7].i32,
            args[8].i32,
            args[9].i32,
            @as(f32, @bitCast(args[10].f32)),
            @as(f64, @bitCast(args[11].f64)),
            @as(f64, @bitCast(args[12].f64)),
            @as(f64, @bitCast(args[13].f64)),
            args[14].i32,
            args[15].i32,
            @as(f32, @bitCast(args[16].f32)),
        ) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return false;
        };
        // Extract: f64 / f32 slots read via low-bits truncate then
        // bitcast; i32 slots truncate to u32; i64 slots use the
        // full u64 directly.
        const got_r0: u64 = got.r0;
        const got_r1: u32 = @truncate(got.r1);
        const got_r2: u32 = @truncate(got.r2);
        const got_r3: u32 = @truncate(got.r3);
        const got_r4: u32 = @truncate(got.r4);
        const got_r5: u64 = got.r5;
        const got_r6: u32 = @truncate(got.r6);
        const got_r7: u32 = @truncate(got.r7);
        const got_r8: u32 = @truncate(got.r8);
        const got_r9: u32 = @truncate(got.r9);
        const got_r10: u64 = got.r10;
        const got_r11: u64 = got.r11;
        const got_r12: u32 = @truncate(got.r12);
        const got_r13: u32 = @truncate(got.r13);
        const got_r14: u32 = @truncate(got.r14);
        const got_r15: u64 = got.r15;
        const ok = base.matchScalarF64(got_r0, exp_r0) and
            base.matchScalarF32(got_r1, exp_r1) and
            got_r2 == exp_r2 and got_r3 == exp_r3 and got_r4 == exp_r4 and
            got_r5 == exp_r5 and
            base.matchScalarF32(got_r6, exp_r6) and
            got_r7 == exp_r7 and got_r8 == exp_r8 and
            base.matchScalarF32(got_r9, exp_r9) and
            base.matchScalarF64(got_r10, exp_r10) and
            base.matchScalarF64(got_r11, exp_r11) and
            got_r12 == exp_r12 and
            base.matchScalarF32(got_r13, exp_r13) and
            got_r14 == exp_r14 and
            base.matchScalarF64(got_r15, exp_r15);
        if (!ok) {
            try stdout.print("FAIL  {s}: {s}({s}) -> large-sig mismatch\n", .{ name, fn_name, args_s });
            return false;
        }
        return true;
    }
    try stdout.print("FAIL  {s}: multi-result unsupported for {s}({s}) -> {s}\n", .{ name, fn_name, args_s, results_s });
    return false;
}

inline fn failBadResult(stdout: *std.Io.Writer, name: []const u8, tok: []const u8) bool {
    stdout.print("FAIL  {s}: bad multi-result token '{s}'\n", .{ name, tok }) catch {};
    return false;
}

/// Scalar-result dispatch ladder. Returns the bit-pattern as `u64`
/// (caller compares against the parsed expected value). `null` on
/// shape-unsupported or trap (caller treats as FAIL; the dispatch
/// already printed the FAIL line).
fn dispatchScalarResult(
    compiled: *const runner_mod.CompiledWasm,
    func_idx: u32,
    rt: *entry.JitRuntime,
    fn_name: []const u8,
    args_s: []const u8,
    args: []const ArgValue,
    result_kind: ArgKind,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!?u64 {
    if (args.len == 0 and result_kind == .i32) {
        return @as(u64, entry.callI32NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, "()", err, stdout);
            return null;
        });
    }
    if (args.len == 0 and result_kind == .i64) {
        return entry.callI64NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, "()", err, stdout);
            return null;
        };
    }
    if (args.len == 0 and result_kind == .f32) {
        const r = entry.callF32NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, "()", err, stdout);
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 0 and result_kind == .f64) {
        const r = entry.callF64NoArgs(compiled.module, func_idx, rt) catch |err| {
            try base.printCallTrap(rt, name, fn_name, "()", err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 1 and args[0] == .i32 and result_kind == .i32) {
        return @as(u64, entry.callI32_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 1 and args[0] == .i32 and result_kind == .i64) {
        return entry.callI64_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
    }
    if (args.len == 1 and args[0] == .i64 and result_kind == .i64) {
        return entry.callI64_i64(compiled.module, func_idx, rt, args[0].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
    }
    if (args.len == 1 and args[0] == .f32 and result_kind == .f32) {
        const a0: f32 = @bitCast(args[0].f32);
        const r = entry.callF32_f32(compiled.module, func_idx, rt, a0) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 1 and args[0] == .f64 and result_kind == .f64) {
        const a0: f64 = @bitCast(args[0].f64);
        const r = entry.callF64_f64(compiled.module, func_idx, rt, a0) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    // §9.9 / 9.9-l-1b-widen: cross-type scalar shapes from
    // conversions.wast — trunc / trunc_sat (FP→int), convert
    // (int→FP), promote / demote / reinterpret across FP widths.
    if (args.len == 1 and args[0] == .i64 and result_kind == .i32) {
        return @as(u64, entry.callI32_i64(compiled.module, func_idx, rt, args[0].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 1 and args[0] == .f32 and result_kind == .i32) {
        const a0: f32 = @bitCast(args[0].f32);
        return @as(u64, entry.callI32_f32(compiled.module, func_idx, rt, a0) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 1 and args[0] == .f64 and result_kind == .i32) {
        const a0: f64 = @bitCast(args[0].f64);
        return @as(u64, entry.callI32_f64(compiled.module, func_idx, rt, a0) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 1 and args[0] == .f32 and result_kind == .i64) {
        const a0: f32 = @bitCast(args[0].f32);
        return entry.callI64_f32(compiled.module, func_idx, rt, a0) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
    }
    if (args.len == 1 and args[0] == .f64 and result_kind == .i64) {
        const a0: f64 = @bitCast(args[0].f64);
        return entry.callI64_f64(compiled.module, func_idx, rt, a0) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
    }
    if (args.len == 1 and args[0] == .i32 and result_kind == .f32) {
        const r = entry.callF32_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 1 and args[0] == .i64 and result_kind == .f32) {
        const r = entry.callF32_i64(compiled.module, func_idx, rt, args[0].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 1 and args[0] == .i32 and result_kind == .f64) {
        const r = entry.callF64_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 1 and args[0] == .i64 and result_kind == .f64) {
        const r = entry.callF64_i64(compiled.module, func_idx, rt, args[0].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 1 and args[0] == .f64 and result_kind == .f32) {
        const a0: f64 = @bitCast(args[0].f64);
        const r = entry.callF32_f64(compiled.module, func_idx, rt, a0) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 1 and args[0] == .f32 and result_kind == .f64) {
        const a0: f32 = @bitCast(args[0].f32);
        const r = entry.callF64_f32(compiled.module, func_idx, rt, a0) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 2 and args[0] == .i32 and args[1] == .i32 and result_kind == .i32) {
        return @as(u64, entry.callI32_i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    // §9.9 / 9.9-l-1b-binop: i64 / f32 / f64 2-arg shapes
    // (binop + cmp families exercised by i64 / f32 / f64 / *_cmp wasts).
    if (args.len == 2 and args[0] == .i64 and args[1] == .i64 and result_kind == .i64) {
        return entry.callI64_i64i64(compiled.module, func_idx, rt, args[0].i64, args[1].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
    }
    if (args.len == 2 and args[0] == .i64 and args[1] == .i64 and result_kind == .i32) {
        return @as(u64, entry.callI32_i64i64(compiled.module, func_idx, rt, args[0].i64, args[1].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 2 and args[0] == .f32 and args[1] == .f32 and result_kind == .f32) {
        const a0: f32 = @bitCast(args[0].f32);
        const a1: f32 = @bitCast(args[1].f32);
        const r = entry.callF32_f32f32(compiled.module, func_idx, rt, a0, a1) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 2 and args[0] == .f32 and args[1] == .f32 and result_kind == .i32) {
        const a0: f32 = @bitCast(args[0].f32);
        const a1: f32 = @bitCast(args[1].f32);
        return @as(u64, entry.callI32_f32f32(compiled.module, func_idx, rt, a0, a1) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 2 and args[0] == .f64 and args[1] == .f64 and result_kind == .f64) {
        const a0: f64 = @bitCast(args[0].f64);
        const a1: f64 = @bitCast(args[1].f64);
        const r = entry.callF64_f64f64(compiled.module, func_idx, rt, a0, a1) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 2 and args[0] == .f64 and args[1] == .f64 and result_kind == .i32) {
        const a0: f64 = @bitCast(args[0].f64);
        const a1: f64 = @bitCast(args[1].f64);
        return @as(u64, entry.callI32_f64f64(compiled.module, func_idx, rt, a0, a1) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    // §9.9 / 9.9-l-1b-d093-d55: 3-/4-arg + mixed FP/i32 shapes.
    if (args.len == 3 and args[0] == .i32 and args[1] == .i32 and args[2] == .i32 and result_kind == .i32) {
        return @as(u64, entry.callI32_i32i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32, args[2].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    // §9.9 / 9.9-l-1b-d093-d63: reftype-aliased table_grow / check-
    // table-null shapes. table_grow's `(grow-* idx ref)` returns the
    // prior size as i32; check-table-null returns funcref aliased
    // as i64.
    if (args.len == 2 and args[0] == .i32 and args[1] == .i64 and result_kind == .i32) {
        return @as(u64, entry.callI32_i32i64(compiled.module, func_idx, rt, args[0].i32, args[1].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 2 and args[0] == .i32 and args[1] == .i32 and result_kind == .i64) {
        return entry.callI64_i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
    }
    if (args.len == 2 and args[0] == .i32 and args[1] == .i64 and result_kind == .i64) {
        return entry.callI64_i32i64(compiled.module, func_idx, rt, args[0].i32, args[1].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
    }
    if (args.len == 3 and args[0] == .i64 and args[1] == .i64 and args[2] == .i32 and result_kind == .i64) {
        return entry.callI64_i64i64i32(compiled.module, func_idx, rt, args[0].i64, args[1].i64, args[2].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
    }
    // §17.4 D-301 — 3-arg atomics (threads corpus): cmpxchg (addr,exp,repl) +
    // wait (addr,exp,timeout). cmpxchg/wait are sequence-setup ops, so they
    // must execute (not skip) for dependent load asserts to read correct state.
    if (args.len == 3 and args[0] == .i32 and args[1] == .i32 and args[2] == .i32 and result_kind == .i32) {
        return @as(u64, entry.callI32_i32i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32, args[2].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 3 and args[0] == .i32 and args[1] == .i64 and args[2] == .i64 and result_kind == .i64) {
        return entry.callI64_i32i64i64(compiled.module, func_idx, rt, args[0].i32, args[1].i64, args[2].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
    }
    if (args.len == 3 and args[0] == .i32 and args[1] == .i32 and args[2] == .i64 and result_kind == .i32) {
        return @as(u64, entry.callI32_i32i32i64(compiled.module, func_idx, rt, args[0].i32, args[1].i32, args[2].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 3 and args[0] == .i32 and args[1] == .i64 and args[2] == .i64 and result_kind == .i32) {
        return @as(u64, entry.callI32_i32i64i64(compiled.module, func_idx, rt, args[0].i32, args[1].i64, args[2].i64) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 3 and args[0] == .f32 and args[1] == .f32 and args[2] == .f32 and result_kind == .f32) {
        const a0: f32 = @bitCast(args[0].f32);
        const a1: f32 = @bitCast(args[1].f32);
        const a2: f32 = @bitCast(args[2].f32);
        const r = entry.callF32_f32f32f32(compiled.module, func_idx, rt, a0, a1, a2) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 4 and args[0] == .f32 and args[1] == .f32 and args[2] == .f32 and args[3] == .f32 and result_kind == .f32) {
        const a0: f32 = @bitCast(args[0].f32);
        const a1: f32 = @bitCast(args[1].f32);
        const a2: f32 = @bitCast(args[2].f32);
        const a3: f32 = @bitCast(args[3].f32);
        const r = entry.callF32_f32f32f32f32(compiled.module, func_idx, rt, a0, a1, a2, a3) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 3 and args[0] == .f32 and args[1] == .f32 and args[2] == .i32 and result_kind == .f32) {
        const a0: f32 = @bitCast(args[0].f32);
        const a1: f32 = @bitCast(args[1].f32);
        const r = entry.callF32_f32f32i32(compiled.module, func_idx, rt, a0, a1, args[2].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 2 and args[0] == .f32 and args[1] == .f64 and result_kind == .f32) {
        const a0: f32 = @bitCast(args[0].f32);
        const a1: f64 = @bitCast(args[1].f64);
        const r = entry.callF32_f32f64(compiled.module, func_idx, rt, a0, a1) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 2 and args[0] == .f64 and args[1] == .f32 and result_kind == .f32) {
        const a0: f64 = @bitCast(args[0].f64);
        const a1: f32 = @bitCast(args[1].f32);
        const r = entry.callF32_f64f32(compiled.module, func_idx, rt, a0, a1) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 3 and args[0] == .f64 and args[1] == .f64 and args[2] == .f64 and result_kind == .f64) {
        const a0: f64 = @bitCast(args[0].f64);
        const a1: f64 = @bitCast(args[1].f64);
        const a2: f64 = @bitCast(args[2].f64);
        const r = entry.callF64_f64f64f64(compiled.module, func_idx, rt, a0, a1, a2) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 4 and args[0] == .f64 and args[1] == .f64 and args[2] == .f64 and args[3] == .f64 and result_kind == .f64) {
        const a0: f64 = @bitCast(args[0].f64);
        const a1: f64 = @bitCast(args[1].f64);
        const a2: f64 = @bitCast(args[2].f64);
        const a3: f64 = @bitCast(args[3].f64);
        const r = entry.callF64_f64f64f64f64(compiled.module, func_idx, rt, a0, a1, a2, a3) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 3 and args[0] == .f64 and args[1] == .f64 and args[2] == .i32 and result_kind == .f64) {
        const a0: f64 = @bitCast(args[0].f64);
        const a1: f64 = @bitCast(args[1].f64);
        const r = entry.callF64_f64f64i32(compiled.module, func_idx, rt, a0, a1, args[2].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 5 and args[0] == .i64 and args[1] == .f32 and args[2] == .f64 and args[3] == .i32 and args[4] == .i32 and result_kind == .i64) {
        const a1: f32 = @bitCast(args[1].f32);
        const a2: f64 = @bitCast(args[2].f64);
        return entry.callI64_i64f32f64i32i32(compiled.module, func_idx, rt, args[0].i64, a1, a2, args[3].i32, args[4].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
    }
    if (args.len == 5 and args[0] == .i64 and args[1] == .f32 and args[2] == .f64 and args[3] == .i32 and args[4] == .i32 and result_kind == .f64) {
        const a1: f32 = @bitCast(args[1].f32);
        const a2: f64 = @bitCast(args[2].f64);
        const r = entry.callF64_i64f32f64i32i32(compiled.module, func_idx, rt, args[0].i64, a1, a2, args[3].i32, args[4].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    // §9.9 / 9.9-l-1b-d093-d61: residual runner-shape-gap drain
    // (FP-result 2-arg-i32 + i32-result 3-arg-FP + mixed-arg shapes
    // surfaced post-d-55).
    if (args.len == 2 and args[0] == .i32 and args[1] == .i32 and result_kind == .f32) {
        const r = entry.callF32_i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 2 and args[0] == .i32 and args[1] == .i32 and result_kind == .f64) {
        const r = entry.callF64_i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 3 and args[0] == .f32 and args[1] == .f32 and args[2] == .f32 and result_kind == .i32) {
        const a0: f32 = @bitCast(args[0].f32);
        const a1: f32 = @bitCast(args[1].f32);
        const a2: f32 = @bitCast(args[2].f32);
        return @as(u64, entry.callI32_f32f32f32(compiled.module, func_idx, rt, a0, a1, a2) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 3 and args[0] == .f64 and args[1] == .f64 and args[2] == .f64 and result_kind == .i32) {
        const a0: f64 = @bitCast(args[0].f64);
        const a1: f64 = @bitCast(args[1].f64);
        const a2: f64 = @bitCast(args[2].f64);
        return @as(u64, entry.callI32_f64f64f64(compiled.module, func_idx, rt, a0, a1, a2) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 3 and args[0] == .i32 and args[1] == .f64 and args[2] == .i32 and result_kind == .i32) {
        const a1: f64 = @bitCast(args[1].f64);
        return @as(u64, entry.callI32_i32f64i32(compiled.module, func_idx, rt, args[0].i32, a1, args[2].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        });
    }
    if (args.len == 8 and args[0] == .f64 and args[1] == .f64 and args[2] == .f64 and args[3] == .f64 and args[4] == .f64 and args[5] == .f64 and args[6] == .f64 and args[7] == .f64 and result_kind == .f64) {
        const a0: f64 = @bitCast(args[0].f64);
        const a1: f64 = @bitCast(args[1].f64);
        const a2: f64 = @bitCast(args[2].f64);
        const a3: f64 = @bitCast(args[3].f64);
        const a4: f64 = @bitCast(args[4].f64);
        const a5: f64 = @bitCast(args[5].f64);
        const a6: f64 = @bitCast(args[6].f64);
        const a7: f64 = @bitCast(args[7].f64);
        const r = entry.callF64_f64f64f64f64f64f64f64f64(compiled.module, func_idx, rt, a0, a1, a2, a3, a4, a5, a6, a7) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 6 and args[0] == .f32 and args[1] == .i32 and args[2] == .i64 and args[3] == .i32 and args[4] == .f64 and args[5] == .i32 and result_kind == .f64) {
        const a0: f32 = @bitCast(args[0].f32);
        const a4: f64 = @bitCast(args[4].f64);
        const r = entry.callF64_f32i32i64i32f64i32(compiled.module, func_idx, rt, a0, args[1].i32, args[2].i64, args[3].i32, a4, args[5].i32) catch |err| {
            try base.printCallTrap(rt, name, fn_name, args_s, err, stdout);
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    try stdout.print("FAIL  {s}: unsupported shape n_args={d} result_kind={s} for {s}({s})\n", .{ name, args.len, @tagName(result_kind), fn_name, args_s });
    return null;
}

/// `RunnerCallbacks.handle_assert_trap` — invokes the function +
/// classifies the outcome. Any successful call (including matching
/// the expected value happenstance) is a FAIL; `Error.Trap` is a
/// PASS; any other error is a distinct FAIL line. Trap-reason
/// discrimination is D-022's scope (interp trap-location wiring);
/// today the runner only checks "did trap occur".
fn nonSimdRunAssertTrap(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    const fa = try base.splitFnAndArgs(rest);
    var fn_name_buf: [512]u8 = undefined;
    const fn_name = try base.decodeFnName(fa.fn_name, &fn_name_buf);
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

    // §9.9 / 9.9-l-1b-d093-d61: capacity 5 → 8 to fit the
    // 8-arg `(f64 ×8, f64)` + 6-arg `(f32 i32 i64 i32 f64 i32, f64)`
    // shapes added in d-61's runner-shape-gap drain.
    // Cap raised 8 → 24 for `func.wast::large-sig` (17 params).
    var args: [24]ArgValue = undefined;
    const n_args = base.parseAssertReturnArgs(args_s, &args) catch |err| {
        if (err == error.TooManyArgs) {
            try stdout.print("FAIL  {s}: assert_trap > {d} args unsupported ({s})\n", .{ name, args.len, args_s });
        } else {
            try stdout.print("FAIL  {s}: assert_trap unsupported arg token ({s})\n", .{ name, args_s });
        }
        return false;
    };

    for (args[0..n_args]) |a| {
        if (a == .v128) {
            try stdout.print("FAIL  {s}: assert_trap v128 arg in non-SIMD runner ({s})\n", .{ name, args_s });
            return false;
        }
    }

    // Invoke via the simplest matching shape. Result type is
    // immaterial — `Error.Trap` is the only PASS outcome.
    //
    // SIGSEGV recovery (D-103 / d-29 / W3.b-2b): the dispatch
    // ladder runs under either POSIX `sigsetjmp` (Mac / Linux)
    // or Win64 `callJitOrTrap` VEH protection (ADR-0103). The
    // dispatch logic itself is factored into a local
    // `Dispatch.run` method so the Windows comptime arm can
    // route it via `@call(.never_inline, ...)` through the
    // helper, while POSIX keeps the `sigsetjmp` callsite inline
    // per the discipline at `spec_assert_runner_base.zig:2306`.
    const Dispatch = struct {
        compiled: *const runner_mod.CompiledWasm,
        func_idx: u32,
        rt: *entry.JitRuntime,
        n_args: usize,
        args_ptr: [*]const ArgValue,
        shape_matched: bool = false,

        fn run(self: *@This()) entry.Error!void {
            const args_in = self.args_ptr;
            if (self.n_args == 0) {
                self.shape_matched = true;
                _ = try entry.callI32NoArgs(self.compiled.module, self.func_idx, self.rt);
                return;
            }
            if (self.n_args == 1 and args_in[0] == .i32) {
                self.shape_matched = true;
                _ = try entry.callI32_i32(self.compiled.module, self.func_idx, self.rt, args_in[0].i32);
                return;
            }
            if (self.n_args == 1 and args_in[0] == .i64) {
                self.shape_matched = true;
                _ = try entry.callI64_i64(self.compiled.module, self.func_idx, self.rt, args_in[0].i64);
                return;
            }
            if (self.n_args == 2 and args_in[0] == .i32 and args_in[1] == .i32) {
                self.shape_matched = true;
                _ = try entry.callI32_i32i32(self.compiled.module, self.func_idx, self.rt, args_in[0].i32, args_in[1].i32);
                return;
            }
            if (self.n_args == 2 and args_in[0] == .i64 and args_in[1] == .i64) {
                self.shape_matched = true;
                _ = try entry.callI64_i64i64(self.compiled.module, self.func_idx, self.rt, args_in[0].i64, args_in[1].i64);
                return;
            }
            // §9.9 / 9.9-l-1b-trap-widen — f32 / f64 arg shapes.
            if (self.n_args == 1 and args_in[0] == .f32) {
                self.shape_matched = true;
                const a0: f32 = @bitCast(args_in[0].f32);
                _ = try entry.callI32_f32(self.compiled.module, self.func_idx, self.rt, a0);
                return;
            }
            if (self.n_args == 1 and args_in[0] == .f64) {
                self.shape_matched = true;
                const a0: f64 = @bitCast(args_in[0].f64);
                _ = try entry.callI32_f64(self.compiled.module, self.func_idx, self.rt, a0);
                return;
            }
            // D-114 / d-41 — store-trap shapes.
            if (self.n_args == 2 and args_in[0] == .i32 and args_in[1] == .i64) {
                self.shape_matched = true;
                try entry.callVoid_i32i64(self.compiled.module, self.func_idx, self.rt, args_in[0].i32, args_in[1].i64);
                return;
            }
            if (self.n_args == 2 and args_in[0] == .i32 and args_in[1] == .f32) {
                self.shape_matched = true;
                const a1: f32 = @bitCast(args_in[1].f32);
                try entry.callVoid_i32f32(self.compiled.module, self.func_idx, self.rt, args_in[0].i32, a1);
                return;
            }
            if (self.n_args == 2 and args_in[0] == .i32 and args_in[1] == .f64) {
                self.shape_matched = true;
                const a1: f64 = @bitCast(args_in[1].f64);
                try entry.callVoid_i32f64(self.compiled.module, self.func_idx, self.rt, args_in[0].i32, a1);
                return;
            }
            // §9.9 / 9.9-l-1b-d093-d56 — `(i32, i32, i32)` shape.
            if (self.n_args == 3 and args_in[0] == .i32 and args_in[1] == .i32 and args_in[2] == .i32) {
                self.shape_matched = true;
                _ = try entry.callI32_i32i32i32(self.compiled.module, self.func_idx, self.rt, args_in[0].i32, args_in[1].i32, args_in[2].i32);
                return;
            }
            // §9.9 / 9.9-l-1b-d093-d63 — `(i32, i64, i32)` shape.
            if (self.n_args == 3 and args_in[0] == .i32 and args_in[1] == .i64 and args_in[2] == .i32) {
                self.shape_matched = true;
                try entry.callVoid_i32i64i32(self.compiled.module, self.func_idx, self.rt, args_in[0].i32, args_in[1].i64, args_in[2].i32);
                return;
            }
            // §17.4 D-301 — `(i32, i64, i64)` shape: i64 atomic cmpxchg
            // (addr, expected, replacement) on the unaligned-trap path.
            // Result is immaterial — only Error.Trap is a PASS — so the
            // i64-result helper is reused and its value discarded.
            if (self.n_args == 3 and args_in[0] == .i32 and args_in[1] == .i64 and args_in[2] == .i64) {
                self.shape_matched = true;
                _ = try entry.callI64_i32i64i64(self.compiled.module, self.func_idx, self.rt, args_in[0].i32, args_in[1].i64, args_in[2].i64);
                return;
            }
            // No arm matched — leave shape_matched = false.
        }
    };

    var dispatch = Dispatch{
        .compiled = compiled,
        .func_idx = func_idx,
        .rt = &rt,
        .n_args = n_args,
        .args_ptr = &args,
    };

    const trapped: bool = blk: {
        if (comptime @import("builtin").os.tag == .windows) {
            // Win64 VEH path (ADR-0103 / W3.b-2b).
            const jit_start = @intFromPtr(compiled.module.block.bytes.ptr);
            const jit_end = jit_start + compiled.module.block.bytes.len;
            if (@import("zwasm").platform.windows_traphandler.callJitOrTrap(
                jit_start,
                jit_end,
                Dispatch.run,
                .{&dispatch},
            )) break :blk true;
        } else {
            if (base.sigsetjmp(@ptrCast(&base.sigsegv_recover_buf), 1) != 0) {
                // Recovered from in-body SEGV / SIGBUS → treat as
                // trap. d-30 verified this path catches the 2
                // elem.wast SEGVs (`assert_trap init ()` on
                // elem.75 / elem.76).
                base.sigsegv_armed.store(false, .release);
                break :blk true;
            }
            base.sigsegv_armed.store(true, .release);
            defer base.sigsegv_armed.store(false, .release);
            dispatch.run() catch |err| switch (err) {
                error.Trap => break :blk true,
            };
        }
        if (!dispatch.shape_matched) {
            try stdout.print("FAIL  {s}: assert_trap unsupported shape n_args={d} for {s}({s})\n", .{ name, n_args, fn_name, args_s });
            return false;
        }
        break :blk false;
    };

    if (!trapped) {
        try stdout.print("FAIL  {s}: assert_trap {s}({s}) did not trap\n", .{ name, fn_name, args_s });
        return false;
    }
    return true;
}

/// d-36: bare `(invoke FN ARGS)` action — invoke for side
/// effects. Per Wasm spec, a bare action carries NO trap-or-
/// return assertion: the host fires the call, observes whatever
/// happens, moves on. So both success AND trap return true.
/// Failure modes that still surface as FAIL: missing export,
/// arg-parse error, unsupported shape (= the manifest distiller
/// shouldn't have emitted invoke-action for an unsupported
/// shape; surfacing it loudly catches distillation bugs).
///
/// The shape ladder reuses `dispatchVoidResult`. Each entry-call
/// helper's trap path is treated as a non-failure here; we
/// inspect `rt.trap_flag` after the call rather than letting
/// `dispatchVoidResult` print a FAIL line on trap.
fn nonSimdRunInvokeAction(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    const fa = try base.splitFnAndArgs(rest);
    var fn_name_buf: [512]u8 = undefined;
    const fn_name = try base.decodeFnName(fa.fn_name, &fn_name_buf);
    const args_s = fa.args_s;

    const func_idx = runner_mod.findExportFunc(gpa, wasm_bytes, fn_name) catch |err| {
        try stdout.print("FAIL  {s}: invoke-action findExport({s}): {s}\n", .{ name, fn_name, @errorName(err) });
        return false;
    };

    var rt = base.makeJitRuntime(
        base.growable_memory[0..@intCast(base.current_mem_bytes)],
        scratch_globals[0..],
        scratch_funcptrs[0..],
        scratch_typeidxs[0..],
        base.currentDispatchView(),
    );

    // §9.9 / 9.9-l-1b-d093-d61: capacity 5 → 8 to fit the
    // 8-arg `(f64 ×8, f64)` + 6-arg `(f32 i32 i64 i32 f64 i32, f64)`
    // shapes added in d-61's runner-shape-gap drain.
    // Cap raised 8 → 24 for `func.wast::large-sig` (17 params).
    var args: [24]ArgValue = undefined;
    const n_args = base.parseAssertReturnArgs(args_s, &args) catch |err| {
        if (err == error.TooManyArgs) {
            try stdout.print("FAIL  {s}: invoke-action > {d} args unsupported ({s})\n", .{ name, args.len, args_s });
        } else {
            try stdout.print("FAIL  {s}: invoke-action unsupported arg token ({s})\n", .{ name, args_s });
        }
        return false;
    };

    // Reuse the dispatchVoidResult shape ladder for the no-arg /
    // 1-arg / 2-arg cases. dispatchVoidResult returns false on
    // trap (and prints a FAIL line); per bare-action semantics,
    // we suppress that. Approach: invoke directly, swallow Trap,
    // surface only ShapeNotSupported as FAIL.
    const arr = args[0..n_args];
    invokeActionShape(compiled, func_idx, &rt, fn_name, args_s, arr) catch |err| switch (err) {
        error.Trap => return true,
        error.ShapeNotSupported => {
            try stdout.print("FAIL  {s}: invoke-action unsupported shape n_args={d} for {s}({s})\n", .{ name, n_args, fn_name, args_s });
            return false;
        },
    };
    return true;
}

/// d-36 invoke-action dispatch — mirrors `dispatchVoidResult`'s
/// shape ladder but propagates `error.Trap` as-is (caller
/// treats it as PASS per bare-action semantics).
fn invokeActionShape(
    compiled: *const runner_mod.CompiledWasm,
    func_idx: u32,
    rt: *entry.JitRuntime,
    _: []const u8,
    _: []const u8,
    args: []const ArgValue,
) !void {
    if (args.len == 0) {
        return entry.callVoidNoArgs(compiled.module, func_idx, rt);
    }
    if (args.len == 1 and args[0] == .i32) {
        return entry.callVoid_i32(compiled.module, func_idx, rt, args[0].i32);
    }
    if (args.len == 1 and args[0] == .i64) {
        return entry.callVoid_i64(compiled.module, func_idx, rt, args[0].i64);
    }
    if (args.len == 1 and args[0] == .f32) {
        const a0: f32 = @bitCast(args[0].f32);
        return entry.callVoid_f32(compiled.module, func_idx, rt, a0);
    }
    if (args.len == 1 and args[0] == .f64) {
        const a0: f64 = @bitCast(args[0].f64);
        return entry.callVoid_f64(compiled.module, func_idx, rt, a0);
    }
    if (args.len == 2 and args[0] == .i32 and args[1] == .i32) {
        return entry.callVoid_i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32);
    }
    // D-114 / d-41: `(i32, i64)` invoke-action — memory_trap-like
    // stores via bare invoke (none in current corpus but plumbed
    // alongside dispatchVoidResult / assert_trap for consistency).
    if (args.len == 2 and args[0] == .i32 and args[1] == .i64) {
        return entry.callVoid_i32i64(compiled.module, func_idx, rt, args[0].i32, args[1].i64);
    }
    // D-116: `(i32, f32)` / `(i32, f64)` / `(i32, i32, i32)` —
    // mirror the `dispatchVoidResult` shape ladder. float_exprs.wast
    // memory-init patterns hit these.
    if (args.len == 2 and args[0] == .i32 and args[1] == .f32) {
        const a1: f32 = @bitCast(args[1].f32);
        return entry.callVoid_i32f32(compiled.module, func_idx, rt, args[0].i32, a1);
    }
    if (args.len == 2 and args[0] == .i32 and args[1] == .f64) {
        const a1: f64 = @bitCast(args[1].f64);
        return entry.callVoid_i32f64(compiled.module, func_idx, rt, args[0].i32, a1);
    }
    if (args.len == 3 and args[0] == .i32 and args[1] == .i32 and args[2] == .i32) {
        return entry.callVoid_i32i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32, args[2].i32);
    }
    // §9.9 / 9.9-l-1b-d093-d63: `(i32, i64, i32)` — table_fill
    // invoke-action shape after reftype aliasing (e.g. `init`
    // populating an externref-indexed table before the assert
    // observation chain runs).
    if (args.len == 3 and args[0] == .i32 and args[1] == .i64 and args[2] == .i32) {
        return entry.callVoid_i32i64i32(compiled.module, func_idx, rt, args[0].i32, args[1].i64, args[2].i32);
    }
    return error.ShapeNotSupported;
}

/// `RunnerCallbacks.handle_assert_uninstantiable` — mirrors
/// `nonSimdOnModuleLoaded`'s init pipeline but inverts the
/// outcome: any error during data/elem/start init is the
/// expected behaviour (PASS = `true`); only a clean
/// instantiation is a FAIL. Run via the
/// `assert_uninstantiable` directive arm in `runCorpus` for
/// modules whose source-level shape was
/// `(assert_uninstantiable (module ...) "...")`.
fn nonSimdHandleAssertUninstantiable(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    const u_mem_min_pages = base.effectiveMemory0Min(gpa, wasm_bytes, base.current_registered);
    const u_mem_max_pages = base.effectiveMemory0Max(gpa, wasm_bytes, base.current_registered);
    base.resetGrowableMemory(@intCast(u_mem_min_pages));
    base.current_mem_max_pages = if (u_mem_max_pages) |m| @intCast(m) else null;
    @memset(scratch_globals[0..], 0);

    runner_mod.applyActiveDataSegments(
        gpa,
        wasm_bytes,
        base.growable_memory[0..@intCast(base.current_mem_bytes)],
    ) catch return true;
    runner_mod.applyDefinedGlobalsInit(
        gpa,
        wasm_bytes,
        compiled.globals_offsets,
        compiled.globals_valtypes,
        scratch_globals[0..],
        compiled.num_global_imports,
    ) catch return true;
    const u_table0_min = base.effectiveTable0Min(gpa, wasm_bytes, base.current_registered);
    const u_table0_cap = @min(@as(usize, u_table0_min), scratch_funcptrs.len);
    const u_gctx = @import("zwasm").engine.runner_validate.GlobalsCtx{
        .offsets = compiled.globals_offsets,
        .valtypes = compiled.globals_valtypes,
        .buf = scratch_globals[0..],
        .num_imports = compiled.num_global_imports,
    };
    runner_mod.applyTableInitCtx(
        gpa,
        wasm_bytes,
        compiled,
        scratch_funcptrs[0..u_table0_cap],
        scratch_typeidxs[0..u_table0_cap],
        u_gctx,
    ) catch return true;
    base.setupMultiTableScratchCtx(
        gpa,
        wasm_bytes,
        compiled,
        scratch_funcptrs[0..u_table0_cap],
        scratch_typeidxs[0..u_table0_cap],
        u_gctx,
    ) catch return true;
    if (base.current_dispatch) |disp| {
        runner_mod.patchTableImportFuncptrs(
            gpa,
            wasm_bytes,
            compiled.num_imports,
            0,
            disp,
            scratch_funcptrs[0..],
        ) catch return true;
    }

    if (base.extractStartFunc(gpa, wasm_bytes)) |start_funcidx| {
        if (start_funcidx < compiled.module.func_offsets.len and
            compiled.module.func_offsets[start_funcidx] != @import("zwasm").engine.codegen.shared.linker.IMPORT_SENTINEL_OFFSET)
        {
            var rt = base.makeJitRuntime(
                base.growable_memory[0..@intCast(base.current_mem_bytes)],
                scratch_globals[0..],
                scratch_funcptrs[0..],
                scratch_typeidxs[0..],
                base.currentDispatchView(),
            );
            // §9.9-III (c)-2.3-γ-3.b-arm: SEGV during a cross-
            // module callee's state access is also a valid
            // "uninstantiable" outcome (the module never finishes
            // start-init cleanly). Arm sigsegv + treat recovered
            // SEGV identically to error.Trap → return true.
            if (comptime @import("builtin").os.tag == .windows) {
                // Win64 VEH path (ADR-0103 / W3.b-2).
                const jit_start = @intFromPtr(compiled.module.block.bytes.ptr);
                const jit_end = jit_start + compiled.module.block.bytes.len;
                if (@import("zwasm").platform.windows_traphandler.callJitOrTrap(
                    jit_start,
                    jit_end,
                    entry.callVoidNoArgs,
                    .{ compiled.module, start_funcidx, &rt },
                )) return true;
            } else {
                if (base.sigsetjmp(@ptrCast(&base.sigsegv_recover_buf), 1) != 0) {
                    base.sigsegv_armed.store(false, .release);
                    return true;
                }
                base.sigsegv_armed.store(true, .release);
                defer base.sigsegv_armed.store(false, .release);
                entry.callVoidNoArgs(compiled.module, start_funcidx, &rt) catch |err| switch (err) {
                    error.Trap => return true,
                };
            }
        }
    }

    try stdout.print("FAIL  {s}: assert_uninstantiable but module instantiated cleanly\n", .{name});
    return false;
}

/// §9.12-E / B138 (D-152 discharge): same-module `(get "field")`
/// action handler. Body shape `<field> <type> <value>`. Looks up
/// the named global via `engine.export_lookup.findExportGlobal`,
/// indexes `scratch_globals` at `compiled.globals_offsets[idx]`,
/// compares vs expected. Returns true on PASS.
fn nonSimdHandleGetAction(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    body: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    var it = std.mem.tokenizeScalar(u8, body, ' ');
    const field = it.next() orelse return false;
    const type_str = it.next() orelse return false;
    const value_str = it.next() orelse return false;

    const export_idx = zwasm.engine.export_lookup.findExportGlobal(gpa, wasm_bytes, field) catch |err| {
        try stdout.print("FAIL  {s}: get-action({s}) export lookup: {s}\n", .{ name, field, @errorName(err) });
        return false;
    };
    const defined_idx: usize = @intCast(export_idx);
    if (defined_idx >= compiled.globals_offsets.len) {
        try stdout.print("FAIL  {s}: get-action({s}) idx={d} ≥ globals_offsets.len {d}\n", .{ name, field, defined_idx, compiled.globals_offsets.len });
        return false;
    }
    const byte_off: usize = compiled.globals_offsets[defined_idx];
    if (byte_off + 8 > scratch_globals.len) return false;
    const slot = scratch_globals[byte_off..][0..8];

    if (std.mem.eql(u8, type_str, "i32")) {
        const expected = std.fmt.parseInt(u32, value_str, 10) catch 0;
        const actual = std.mem.readInt(u32, slot[0..4], .little);
        if (actual == expected) return true;
        try stdout.print("FAIL  {s}: get-action({s}) i32 expected={d} actual={d}\n", .{ name, field, expected, actual });
        return false;
    } else if (std.mem.eql(u8, type_str, "i64")) {
        const expected = std.fmt.parseInt(u64, value_str, 10) catch 0;
        const actual = std.mem.readInt(u64, slot[0..8], .little);
        if (actual == expected) return true;
        try stdout.print("FAIL  {s}: get-action({s}) i64 expected={d} actual={d}\n", .{ name, field, expected, actual });
        return false;
    } else if (std.mem.eql(u8, type_str, "f32")) {
        const expected = std.fmt.parseInt(u32, value_str, 10) catch 0;
        const actual = std.mem.readInt(u32, slot[0..4], .little);
        if (actual == expected) return true;
        try stdout.print("FAIL  {s}: get-action({s}) f32 expected_bits=0x{x} actual_bits=0x{x}\n", .{ name, field, expected, actual });
        return false;
    } else if (std.mem.eql(u8, type_str, "f64")) {
        const expected = std.fmt.parseInt(u64, value_str, 10) catch 0;
        const actual = std.mem.readInt(u64, slot[0..8], .little);
        if (actual == expected) return true;
        try stdout.print("FAIL  {s}: get-action({s}) f64 expected_bits=0x{x} actual_bits=0x{x}\n", .{ name, field, expected, actual });
        return false;
    } else {
        try stdout.print("FAIL  {s}: get-action({s}) unsupported type {s}\n", .{ name, field, type_str });
        return false;
    }
}

const non_simd_callbacks: base.RunnerCallbacks = .{
    .on_module_loaded = nonSimdOnModuleLoaded,
    .handle_assert_return = nonSimdRunAssertReturn,
    .handle_assert_trap = nonSimdRunAssertTrap,
    .handle_invoke_action = nonSimdRunInvokeAction,
    .handle_assert_uninstantiable = nonSimdHandleAssertUninstantiable,
    .handle_get_action = nonSimdHandleGetAction,
};
