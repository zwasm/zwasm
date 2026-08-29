const std = @import("std");
// Single source of truth for the version string: read it from build.zig.zon
// and thread it through `build_options` so `zwasm.version` / `--version`
// can never drift from the published package version (and the tag).
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ROADMAP §4.6 — coarse, orthogonal feature flags.
    //   -Dwasm     : Wasm spec level (3.0 default)
    //   -Dwasi     : WASI version inclusion
    //   -Dengine   : engine selection (interp / jit / both)
    //   -Dstrip    : strip debug info from the CLI binary
    //
    // Per-proposal feature gating happens via dispatch-table
    // registration (ROADMAP §4.5 / A12), not pervasive build-time
    // `if` branches.
    const wasm_level = b.option(WasmLevel, "wasm", "Wasm spec level (default 3.0)") orelse .v3_0;
    const wasi_level = b.option(WasiLevel, "wasi", "WASI version inclusion: none/p1/p2/p3 ordered tier (default p2; p3=Preview-3 async, ADR-0193)") orelse .p2;
    const engine_mode = b.option(EngineMode, "engine", "Engine selection (default both)") orelse .both;
    const enable_strip = b.option(bool, "strip", "Strip debug info from the CLI binary") orelse false;
    const strip_opt: ?bool = if (enable_strip) true else null;

    // ADR-0015 §Decision Part 2 (§9.6 / 6.K.7): -Dsanitize=address
    // wires LLVM AddressSanitizer + UBSan via Zig 0.16's
    // `module.sanitize_c = .full`. -Dsanitize=thread enables
    // ThreadSanitizer. Both Mac aarch64 + Linux x86_64 only —
    // Windows ucrt skipped because clang ASan/Win32 needs an MSVC
    // redist that doesn't ship through the Nix dev shell.
    // Adopted as a weekly Linux x86_64 lane, not per-commit (~2× slower).
    const sanitize = b.option(SanitizeMode, "sanitize", "Sanitizer (off / address / thread). Mac+Linux only.") orelse .off;
    const is_windows = target.result.os.tag == .windows;
    if (is_windows and sanitize != .off) {
        // A requested sanitizer must never silently vanish: Windows ucrt has
        // no ASan/TSan runtime in this toolchain, so reject instead of
        // building an unsanitized binary the caller believes is sanitized.
        std.debug.panic("-Dsanitize={s} is not available on Windows targets (Mac+Linux only)", .{@tagName(sanitize)});
    }
    const sanitize_c: ?std.zig.SanitizeC = if (is_windows) null else switch (sanitize) {
        .off => null,
        .address => .full,
        .thread => null,
    };
    const sanitize_thread: ?bool = if (is_windows) null else switch (sanitize) {
        .off, .address => null,
        .thread => true,
    };
    // Bundled into a single value so call sites use one short
    // `createSanitizedModule(b, sanitize_opts, .{...})` per module
    // instead of `createModule + applySanitize` boilerplate (D-016
    // discharge).
    const sanitize_opts: SanitizeOpts = .{ .c = sanitize_c, .thread = sanitize_thread };

    // ADR-0028 / D-022: Diagnostic M3-a trace ringbuffer compile-time
    // gate. Default false so release builds emit zero trace code in
    // hot paths (per ROADMAP §A12). Enable on debug / audit runs via
    // `-Dtrace-ringbuffer=true`.
    const trace_ringbuffer = b.option(bool, "trace-ringbuffer", "Compile in Diagnostic M3-a trace ringbuffer (default: false)") orelse false;

    // ADR-0164 B / D-292: stack-probe + trap-stub diagnostic prints
    // (`[stack_probe] …` setup probe + `[d-165] kind=4 …` trap-stub entry count).
    // These are D-245/D-165/D-279 Win64 investigation primitives; default false
    // so even Debug `zig build test` stderr is clean (the prints fired once per
    // process on the first JIT call). Win64 heisenbug (D-279) work re-enables via
    // `-Dtrace-stackprobe=true`.
    const trace_stackprobe = b.option(bool, "trace-stackprobe", "Compile in the [stack_probe]/[d-165] JIT diagnostic prints (default: false)") orelse false;

    // Zig does NOT bundle compiler-rt into a static library by default (the
    // implicit default only covers exe + dynamic lib), so a NON-zig linker
    // consuming libzwasm.a is left with undefined `__zig_probe_stack`
    // (x86_64-macos) and the `__divti3`-class builtins. The latter are usually
    // covered by the consumer's own runtime (clang_rt / libgcc / Rust's
    // compiler_builtins); `__zig_probe_stack` has no non-Zig provider, so it
    // is a hard link failure (#153). Opt-in, same spelling as v1.
    const bundle_compiler_rt = b.option(bool, "compiler-rt", "Bundle Zig compiler-rt into libzwasm.a (default: false; set true for external non-zig linkers)") orelse false;

    // ADR-0193 — the Component Model + WASI-P2 host is gated by the WASI
    // tier, NOT a separate `-Dcomponent` flag (removed — it duplicated the
    // gate and admitted contradictory combos like `-Dwasi=p1 -Dcomponent=true`).
    // `wasi_level >= .p2` IS the component substrate (ADR-0181 §1.2 floor;
    // wasmtime-standard default). The lean opt-out is now `-Dwasi=p1`, which
    // strips the whole `src/feature/component/` + P2-host subsystem (~156 KB
    // of a 1.9 MB ReleaseFast binary, measured at ADR-0182) via the same
    // comptime fences that read `enable_component`.
    const enable_component = @intFromEnum(wasi_level) >= @intFromEnum(WasiLevel.p2);
    // ADR-0193 P3 — the P3/async host (component_wasi_p3.zig + component/async.zig)
    // compiles only at `wasi_level >= .p3`. At the default `.p2` async is opt-in
    // (`-Dwasi=p3`) — a p2 build emits zero p3-async symbols (DCE-assertable).
    const enable_wasi_p3 = @intFromEnum(wasi_level) >= @intFromEnum(WasiLevel.p3);

    const options = b.addOptions();
    options.addOption(WasmLevel, "wasm_level", wasm_level);
    options.addOption(WasiLevel, "wasi_level", wasi_level);
    const runner_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseSafe else optimize;
    options.addOption(EngineMode, "engine_mode", engine_mode);
    // ADR-0209 — the mode `core_rs` is built with, which is not the mode the
    // caller asked for: `runner_optimize` floors Debug at ReleaseSafe for
    // iteration speed. `bench/latency` imports the engine through `core_rs`, so
    // reporting its own `builtin.mode` would label ReleaseSafe numbers `Debug`.
    // Named for the twin it describes, not "engine_optimize": this same
    // `build_options` module is shared by `core` and `exe_mod`, which are built
    // with the raw `-Doptimize`, and a bare name would be wrong for them.
    options.addOption(std.builtin.OptimizeMode, "runner_engine_optimize", runner_optimize);
    options.addOption(bool, "trace_ringbuffer", trace_ringbuffer);
    options.addOption(bool, "trace_stackprobe", trace_stackprobe);
    options.addOption(bool, "enable_component", enable_component);
    options.addOption(bool, "enable_wasi_p3", enable_wasi_p3);
    options.addOption([]const u8, "version", zon.version);

    // Build_options as a single shared module so both `core` and
    // `exe_mod` (and any other consumer) reference the same Module.
    // ADR-0028 requires `src/diagnostic/trace.zig` to import
    // `build_options`; the previous double-`addOptions` shape made
    // the auto-generated file the root of two modules ("build_options"
    // and "build_options0") and broke compilation when both root
    // modules (core + exe_mod) appeared in the same `zig build test`
    // run. Sharing a single Module via `b.addModule` deduplicates.
    const build_options_mod = options.createModule();

    // ============================================================
    // `core` module — the shared library Module per ADR-0024 D-1.
    // Rooted at `src/zwasm.zig` so transitive `@import("../X")`
    // chains stay inside `src/` (the subtree restriction Zig 0.16
    // enforces). Used as `.root_module` by:
    //   - libzwasm.a (static lib)
    //   - test runners (spec / wast / realworld / wasi / etc.)
    //   - the CLI exe's root_module imports it by name (Bun-style
    //     self-import + Ghostty-style multi-artifact reuse)
    // ADR-0024 D-2 carves out `src/zwasm.zig` as the single
    // re-export hub and test loader.
    // ============================================================
    // Public, named module so external `build.zig.zon` path-dep
    // consumers can pull the Zig facade via
    // `b.dependency("zwasm", .{}).module("zwasm")` (ADR-0109 / §16.5
    // dogfooding). Internal artifacts (CLI exe, examples, test
    // runners) reuse this same `*Module` directly. `b.addModule`
    // (not `createModule`) is what registers it under the "zwasm"
    // name for dependents.
    const core = b.addModule("zwasm", .{
        .root_source_file = b.path("src/zwasm.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_opt,
        // §9.3 / 3.3: the C API binding's Engine carries
        // `std.heap.c_allocator`, which requires libc linkage.
        // Linking unconditionally is fine — zwasm v2 is a libc-
        // adjacent runtime (wasm-c-api consumers are C hosts).
        .link_libc = true,
    });
    applySanitize(core, sanitize_opts);
    core.addImport("build_options", build_options_mod);
    // §9.3 / 3.1: `include/` carries the vendored C API headers
    // (wasm.h pinned via ADR-0004). Adding the path here lets
    // src/api/* modules `@cImport(@cInclude("wasm.h"))` resolve.
    core.addIncludePath(b.path("include"));
    // ADR-0024 D-3: self-import. Every leaf in `src/` can write
    // `@import("zwasm").<zone>.<symbol>` to reach the central
    // re-export hub regardless of nesting depth.
    core.addImport("zwasm", core);

    // ADR-0177 (D-311) — a ReleaseSafe twin of `core` for the integration
    // TEST RUNNERS only. Debug host execution is ~5-10x slower; the runners
    // (spec / realworld / wast / edge corpus) are run-time-dominated, so they
    // build ReleaseSafe for iteration speed (still full safety checks). The
    // `core_tests` UNIT suite stays on Debug `core` (it calls raw `module.entry`
    // fn-ptrs that violate the JIT host-boundary callee-saved contract under an
    // optimized host — a test-harness pattern, not a production path; production
    // routes through the cohort trampoline). Production (`exe`/lib) keeps `core`
    // honouring `-Doptimize`. Floor at ReleaseSafe so a plain Debug build still
    // runs runners fast; a higher `-Doptimize` (ReleaseFast) wins.
    const core_rs = b.createModule(.{
        .root_source_file = b.path("src/zwasm.zig"),
        .target = target,
        .optimize = runner_optimize,
        .strip = strip_opt,
        .link_libc = true,
    });
    applySanitize(core_rs, sanitize_opts);
    core_rs.addImport("build_options", build_options_mod);
    core_rs.addIncludePath(b.path("include"));
    core_rs.addImport("zwasm", core_rs);

    // CLI exe — separate thin module rooted at `src/cli/main.zig`
    // (per ADR-0024 D-4) so `pub fn main` lives in the CLI zone
    // and doesn't collide with C hosts' `int main` when they link
    // against libzwasm.a.
    const exe_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_opt,
        .link_libc = true,
    });
    exe_mod.addImport("build_options", build_options_mod);
    exe_mod.addIncludePath(b.path("include"));
    exe_mod.addImport("zwasm", core);

    const exe = b.addExecutable(.{
        .name = "zwasm",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // The ReleaseSafe floor of ADR-0177 (D-311), reaching the one channel a
    // module swap cannot: `test-aot-diff` consumes the engine as a SPAWNED
    // BINARY, so `core_rs` never reaches it and it would otherwise run the
    // whole corpus on a Debug engine — three compiles and five CLI spawns per
    // fixture, so the Debug tax lands once per compile rather than once per
    // run. ReleaseSafe keeps every safety check. Deliberately not installed:
    // the shipped `zwasm` is `exe`, which honours `-Doptimize`.
    const exe_rs_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = runner_optimize,
        .strip = strip_opt,
        .link_libc = true,
    });
    exe_rs_mod.addImport("build_options", build_options_mod);
    exe_rs_mod.addIncludePath(b.path("include"));
    exe_rs_mod.addImport("zwasm", core_rs);
    const exe_rs = b.addExecutable(.{
        .name = "zwasm-releasesafe",
        .root_module = exe_rs_mod,
    });

    // `zig build run -- <args>` runs the CLI.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the zwasm executable");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — unit tests inline in src/.
    //
    // Zig's `b.addTest` injects `std.testing.allocator` (a
    // leak-detecting `std.heap.DebugAllocator`-backed
    // allocator) into every test. Any allocation that escapes a
    // test without a matching free prints `error(gpa): memory
    // address ... leaked` and fails the run. So `zig build test`
    // IS the leak-check gate per §9.2 / 2.5 — no separate
    // `--leak-check` step is needed.
    // Unit tests run against the `core` module directly — that's
    // where the test loader lives (per ADR-0024 D-2). The CLI
    // exe's tests come along too via the inline `test "..."`
    // blocks in `src/cli/main.zig`.
    const core_tests = b.addTest(.{ .root_module = core });
    const run_core_tests = b.addRunArtifact(core_tests);
    const cli_tests = b.addTest(.{ .root_module = exe_mod });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    // Close-plan §6 (j) D-153 / direct-implementation route
    // (2026-05-21). spectest is the standard Wasm host module
    // (canonical: `WebAssembly/spec/interpreter/host/spectest.ml`,
    // 56 OCaml lines). Both v1 zwasm and wazero ship it as a
    // regular `.wat` that the spec runner auto-registers; we
    // adopt the same model.
    //
    // Pipeline:
    //   test/spec/spectest.wat (committed source)
    //     → `wasm-tools parse` (Nix-managed; flake.nix lists wasm-tools)
    //     → spectest.wasm (in build cache; never committed)
    //     → WriteFiles bundles {spectest.wasm, spectest_module.zig}
    //     → createModule wraps it; `@embedFile("spectest.wasm")`
    //       resolves at compile time of the runner exe
    //
    // Differential rebuild: Zig tracks the .wat input file's
    // hash; unchanged .wat → cached .wasm reused. CI-grade
    // reproducibility per user request 2026-05-21.
    // D-290: wabt → wasm-tools migration. `wasm-tools parse <wat> -o <wasm>` is
    // the wat→wasm equivalent of `wat2wasm` (byte-identical for basic modules;
    // spectest.wat is a plain support module). Drops one wabt site from the build.
    const spectest_wat2wasm = b.addSystemCommand(&.{ "wasm-tools", "parse" });
    spectest_wat2wasm.addFileArg(b.path("test/spec/spectest.wat"));
    spectest_wat2wasm.addArg("-o");
    const spectest_wasm_path = spectest_wat2wasm.addOutputFileArg("spectest.wasm");
    const spectest_wf = b.addWriteFiles();
    _ = spectest_wf.addCopyFile(spectest_wasm_path, "spectest.wasm");
    const spectest_embed_src = spectest_wf.add("spectest_module.zig",
        \\//! Auto-generated by build.zig: wraps the compiled
        \\//! spectest.wasm (from test/spec/spectest.wat) as a
        \\//! byte slice importable via @import("spectest_module").
        \\pub const bytes: []const u8 = @embedFile("spectest.wasm");
        \\
    );
    const spectest_wasm_mod = b.createModule(.{
        .root_source_file = spectest_embed_src,
    });

    // §9.9-III (c)-2.3 D-142 fix (B) attendant: the
    // `RegisteredExporter` unit tests in
    // `test/spec/spec_assert_runner_base.zig` were authored
    // alongside the γ-1/γ-2/γ-3/γ-3.b chunks but never wired
    // into `zig build test` (they exist inside a
    // `pub fn`-providing module consumed by the three runner
    // exes; exe wiring doesn't run `test "..."` blocks). Wire
    // them now so the D-142 absent-backing assertion + the
    // γ-tests guard the exporter shape going forward.
    const spec_assert_base_test_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/spec_assert_runner_base.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_assert_base_test_mod.addImport("zwasm", core);
    spec_assert_base_test_mod.addImport("spectest_module", spectest_wasm_mod);
    const spec_assert_base_tests = b.addTest(.{ .root_module = spec_assert_base_test_mod });
    const run_spec_assert_base_tests = b.addRunArtifact(spec_assert_base_tests);
    const test_step = b.step("test", "Run unit tests");

    // §10 / 10.T-4: emit_test golden bless workflow entry point.
    // Skeleton — auto-bless impl is deferred per design plan §4.7
    // until first cluster hits ≥ 10 pending mismatches. Today
    // routes through `scripts/bless_emit_tests.sh` which reports
    // sidecar status.
    const bless_step = b.step("bless", "Apply pending emit_test golden mismatches (10.T-4 skeleton; impl deferred per design plan §4.7)");
    const bless_cmd = b.addSystemCommand(&.{ "bash", "scripts/bless_emit_tests.sh" });
    bless_step.dependOn(&bless_cmd.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_spec_assert_base_tests.step);

    // `zig build test-spec` — drive the frontend over the vendored
    // Wasm spec corpus (Phase 1 / §9.1 / 1.8: parser smoke; 1.9
    // upgrades to full decode + validate + lower).
    //
    // Per ADR-0024 D-1, every test runner reuses one shared zwasm module via
    // `addImport("zwasm", zwasm_lib_mod)`. ADR-0177 (D-311): that alias now
    // points at the ReleaseSafe twin `core_rs` so every integration runner
    // builds ReleaseSafe (iteration speed) in one place. `core_tests`/`exe`
    // still use Debug `core`.
    const zwasm_lib_mod = core_rs;
    const spec_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const spec_runner_exe = b.addExecutable(.{
        .name = "zwasm-spec-runner",
        .root_module = spec_runner_mod,
    });
    const run_spec_smoke = b.addRunArtifact(spec_runner_exe);
    run_spec_smoke.addArg(b.pathFromRoot("test/spec/smoke"));
    const run_spec_mvp = b.addRunArtifact(spec_runner_exe);
    run_spec_mvp.addArg(b.pathFromRoot("test/spec/wasm-1.0"));
    // ADR-0210 — `zig build test-spec` did not print what it ran: three
    // consecutive runs each showed 8 `PASS` lines while the two summaries
    // claimed 3 + 9 = 12, one line spliced mid-token. The cause was NOT
    // this build wiring — it was `std.Io.File.stdout().writer()`, whose
    // default `.positional` mode restarts at offset 0 in every process, so
    // the second runner overwrote the first's output whenever stdout was a
    // regular file. Every runner under `test/` now uses `writerStreaming`
    // (as all of `src/` already did). Ordering the two runs is the residual
    // half: with both appending, concurrent runs could still interleave
    // mid-line, and a denominator is worthless if the lines backing it can
    // be shredded between the runner and the log a reviewer reads.
    run_spec_mvp.step.dependOn(&run_spec_smoke.step);
    const test_spec_step = b.step("test-spec", "Run the Wasm spec test runner");
    test_spec_step.dependOn(&run_spec_smoke.step);
    test_spec_step.dependOn(&run_spec_mvp.step);

    // `zig build test-edge-cases` — sub-7.5b-iii fixture runner.
    // Iterates `test/edge_cases/p7/` and runs each .wasm through
    // the ARM64 JIT, comparing against the sibling .expect.
    const edge_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/edge_cases/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    edge_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const edge_runner_exe = b.addExecutable(.{
        .name = "zwasm-edge-runner",
        .root_module = edge_runner_mod,
    });
    // `has_side_effects = true` on these fixture-runners is REDUNDANT, kept
    // only as an explicit statement of intent (tests must always execute).
    // The corpus dir does reach the runner as an untracked `addArg` string,
    // but that alone never made them cacheable: `Run.hasSideEffects()` is
    // already true for the default `stdio = .infer_from_args` unless the step
    // has an output arg, and these have none. Caching needs a SECOND
    // condition — an output arg, or an `addCheck` caller (`expectExitCode`,
    // `expectStdOutEqual`) flipping stdio to `.check`. See D-592: the cyc216
    // diagnosis that put these lines here was wrong, and `run_oob_trap` is
    // the one step in this file where both conditions actually hold.
    const run_edge_p7 = b.addRunArtifact(edge_runner_exe);
    run_edge_p7.addArg(b.pathFromRoot("test/edge_cases/p7"));
    run_edge_p7.has_side_effects = true;
    const run_edge_p9 = b.addRunArtifact(edge_runner_exe);
    run_edge_p9.addArg(b.pathFromRoot("test/edge_cases/p9"));
    run_edge_p9.has_side_effects = true;
    const run_edge_p10 = b.addRunArtifact(edge_runner_exe);
    run_edge_p10.addArg(b.pathFromRoot("test/edge_cases/p10"));
    run_edge_p10.has_side_effects = true;
    const run_edge_p17 = b.addRunArtifact(edge_runner_exe);
    run_edge_p17.addArg(b.pathFromRoot("test/edge_cases/p17"));
    run_edge_p17.has_side_effects = true;
    // Realworld p10 result-check (10.TC-JIT IT-5): the same JIT
    // edge-runner walks `test/realworld/p10/**`, result-checking any
    // toolchain-compiled `.wasm` with a sibling `.expect`
    // (clang_musttail → return_call D-205; clang_wasm64 → memory64 D-209).
    const run_edge_realworld_p10 = b.addRunArtifact(edge_runner_exe);
    run_edge_realworld_p10.addArg(b.pathFromRoot("test/realworld/p10"));
    run_edge_realworld_p10.has_side_effects = true;
    const test_edge_step = b.step("test-edge-cases", "Run edge-case fixture runner (all hosts post §9.9 / 9.9-j-2b)");
    test_edge_step.dependOn(&run_edge_p7.step);
    test_edge_step.dependOn(&run_edge_p9.step);
    test_edge_step.dependOn(&run_edge_p10.step);
    test_edge_step.dependOn(&run_edge_p17.step);
    test_edge_step.dependOn(&run_edge_realworld_p10.step);

    // `zig build test-spec-jit-compile` — §9.7 / 7.5 first
    // sub-chunk. Walks spec corpora and reports whether each
    // fixture compiles end-to-end through the JIT pipeline
    // (parse + validate + lower + regalloc + ARM64 emit). Mac
    // aarch64 only (linker tied to host arch).
    const jit_compile_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/jit_compile_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    jit_compile_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const jit_compile_runner_exe = b.addExecutable(.{
        .name = "zwasm-spec-jit-compile",
        .root_module = jit_compile_runner_mod,
    });
    const run_jit_compile = b.addRunArtifact(jit_compile_runner_exe);
    run_jit_compile.addArg(b.pathFromRoot("test/spec/smoke"));
    run_jit_compile.addArg(b.pathFromRoot("test/spec/wasm-1.0"));
    const test_jit_compile_step = b.step("test-spec-jit-compile", "JIT-compile spec corpus (Mac aarch64 only; §9.7 / 7.5)");
    test_jit_compile_step.dependOn(&run_jit_compile.step);

    // `zig build test-spec-assert` — §9.7 / 7.5-spec-assertion-driver-a.
    // Walks corpus produced by `scripts/regen_spec_1_0_assert.sh`,
    // JIT-compiles each `module` and runs each `assert_return`
    // through the typed entry helpers (callI32NoArgs / callI32_i32),
    // reporting pass / fail / skipped counts. Wired into test-all
    // on all hosts at §9.7 / 7.8 close (D-045 chunks 1-14
    // discharged; gate green Mac + Linux + Windows).
    const spec_assert_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/spec_assert_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_assert_runner_mod.addImport("zwasm", zwasm_lib_mod);
    spec_assert_runner_mod.addImport("spectest_module", spectest_wasm_mod);
    const spec_assert_runner_exe = b.addExecutable(.{
        .name = "zwasm-spec-assert",
        .root_module = spec_assert_runner_mod,
    });
    const run_spec_assert = b.addRunArtifact(spec_assert_runner_exe);
    run_spec_assert.addArg(b.pathFromRoot("test/spec/wasm-1.0-assert"));
    const test_spec_assert_step = b.step("test-spec-assert", "Run JIT spec assertion runner (all hosts; gate-green at §9.7 / 7.8 close)");
    test_spec_assert_step.dependOn(&run_spec_assert.step);

    // E1 (ADR-0170): Component Model spec corpus runner. Unlike the
    // core-wasm runners it needs the component host API, so it is built
    // against a dedicated `zwasm` module forced to a `.p2` WASI floor
    // (ADR-0193: component == `wasi_level >= .p2`) regardless of the
    // top-level `-Dwasi` (which may be `none`/`p1`). `core_comp` is a
    // separate root of `src/zwasm.zig` rooting its own executable — never
    // co-compiled with `core` in one exe, so the ADR-0028 dual-
    // `build_options`-root hazard does not apply.
    const comp_wasi_level: WasiLevel = if (@intFromEnum(wasi_level) >= @intFromEnum(WasiLevel.p2)) wasi_level else .p2;
    const comp_options = b.addOptions();
    comp_options.addOption(WasmLevel, "wasm_level", wasm_level);
    comp_options.addOption(WasiLevel, "wasi_level", comp_wasi_level);
    comp_options.addOption(EngineMode, "engine_mode", engine_mode);
    comp_options.addOption(bool, "trace_ringbuffer", trace_ringbuffer);
    comp_options.addOption(bool, "trace_stackprobe", trace_stackprobe);
    comp_options.addOption(bool, "enable_component", true);
    comp_options.addOption(bool, "enable_wasi_p3", @intFromEnum(comp_wasi_level) >= @intFromEnum(WasiLevel.p3));
    comp_options.addOption([]const u8, "version", zon.version);
    const comp_options_mod = comp_options.createModule();
    const core_comp = b.createModule(.{
        .root_source_file = b.path("src/zwasm.zig"),
        .target = target,
        // ADR-0177 (Revision 2026-06-14): the Component Model spec runner
        // (`comp_spec_runner`, 158-manifest corpus in `test-all`) is an
        // integration runner — floor it at ReleaseSafe like `core_rs`, else a
        // plain Debug `zig build test-all` runs the whole CM corpus ~100× slower.
        // `core_comp` is consumed ONLY by that runner (no production component
        // exe), so the floor never costs a real Debug build.
        .optimize = runner_optimize,
        .strip = strip_opt,
        .link_libc = true,
    });
    applySanitize(core_comp, sanitize_opts);
    core_comp.addImport("build_options", comp_options_mod);
    core_comp.addIncludePath(b.path("include"));
    core_comp.addImport("zwasm", core_comp);

    const comp_spec_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/component_model_assert_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    comp_spec_runner_mod.addImport("zwasm", core_comp);
    const comp_spec_runner_exe = b.addExecutable(.{
        .name = "zwasm-component-spec-assert",
        .root_module = comp_spec_runner_mod,
    });
    const run_comp_spec_assert = b.addRunArtifact(comp_spec_runner_exe);
    run_comp_spec_assert.addArg(b.pathFromRoot("test/spec/component-model-assert"));
    const test_comp_spec_step = b.step("test-component-spec", "Run the Component Model spec corpus runner (E1; ADR-0170)");
    test_comp_spec_step.dependOn(&run_comp_spec_assert.step);

    // ADR-0193 P3 — the 28 WASI Preview-3 (async) unit tests live in
    // `api/component_wasi_p3.zig`, which compiles only at `wasi_level >= .p3`.
    // The default `.p2` `zig build test` skips them (the file is unimported),
    // so a dedicated module forced to `.p3` runs them regardless of the
    // top-level `-Dwasi`. Mirrors `core_comp`'s forced-`.p2` floor above; uses
    // the Debug `optimize` (like `core_tests`, not `runner_optimize`) since the
    // async tests are unit-suite shape, not run-time-dominated corpus runners.
    const p3_options = b.addOptions();
    p3_options.addOption(WasmLevel, "wasm_level", wasm_level);
    p3_options.addOption(WasiLevel, "wasi_level", .p3);
    p3_options.addOption(EngineMode, "engine_mode", engine_mode);
    p3_options.addOption(bool, "trace_ringbuffer", trace_ringbuffer);
    p3_options.addOption(bool, "trace_stackprobe", trace_stackprobe);
    p3_options.addOption(bool, "enable_component", true);
    p3_options.addOption(bool, "enable_wasi_p3", true);
    p3_options.addOption([]const u8, "version", zon.version);
    const p3_options_mod = p3_options.createModule();
    const core_p3 = b.createModule(.{
        .root_source_file = b.path("src/zwasm.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_opt,
        .link_libc = true,
    });
    applySanitize(core_p3, sanitize_opts);
    core_p3.addImport("build_options", p3_options_mod);
    core_p3.addIncludePath(b.path("include"));
    core_p3.addImport("zwasm", core_p3);
    // `zig build test-list` — print every DISCOVERED test name (custom list
    // runner; sweep S5(c)). Runs on the p3-forced module (the maximal file
    // set); `scripts/check_test_discovery.sh` diffs this against the named
    // `test "…"` blocks present in source to catch dead test blocks.
    const list_tests = b.addTest(.{
        .root_module = core_p3,
        .test_runner = .{ .path = b.path("src/test_support/list_tests_runner.zig"), .mode = .simple },
    });
    const run_list_tests = b.addRunArtifact(list_tests);
    const test_list_step = b.step("test-list", "List every discovered test name (S5 test-discovery guard input)");
    test_list_step.dependOn(&run_list_tests.step);

    const p3_tests = b.addTest(.{
        .root_module = core_p3,
        .filters = if (b.option([]const u8, "test-filter", "run only tests whose name contains this string (test-wasi-p3)")) |f| b.dupeStrings(&.{f}) else &.{},
    });
    const run_p3_tests = b.addRunArtifact(p3_tests);
    const test_wasi_p3_step = b.step("test-wasi-p3", "Run the WASI Preview-3 (async) unit tests under a forced -Dwasi=p3 module (ADR-0193 P3)");
    test_wasi_p3_step.dependOn(&run_p3_tests.step);

    // `zig build test-spec-simd` — §9.9 per ADR-0045. SIMD spec
    // assertion runner (parallel to spec_assert_runner). §9.9-a
    // foundation: runner skeleton + build.zig wiring + manifest
    // format spec. NOT YET aggregated into test-all (deferred to
    // §9.9-e per ADR-0045 Consequences §). Manifest population
    // begins at §9.9-b.
    const simd_assert_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/simd_assert_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    simd_assert_runner_mod.addImport("zwasm", zwasm_lib_mod);
    simd_assert_runner_mod.addImport("spectest_module", spectest_wasm_mod);
    const simd_assert_runner_exe = b.addExecutable(.{
        .name = "zwasm-spec-simd",
        .root_module = simd_assert_runner_mod,
    });
    const run_simd_assert = b.addRunArtifact(simd_assert_runner_exe);
    run_simd_assert.addArg(b.pathFromRoot("test/spec/wasm-2.0-simd-assert"));
    const test_spec_simd_step = b.step("test-spec-simd", "Run SIMD spec assertion runner (§9.9 per ADR-0045; foundation: 0 manifests until §9.9-b)");
    test_spec_simd_step.dependOn(&run_simd_assert.step);

    // `zig build test-spec-wasm-2.0-assert` — §9.9 / 9.9-l-1b per
    // ADR-0057. Wasm 2.0 non-SIMD scalar spec assertion runner;
    // parallel to spec_assert_runner (wasm-1.0) and simd_assert_runner
    // (SIMD). All three runners consume `spec_assert_runner_base`
    // and differ only in their RunnerCallbacks literal. Corpus
    // (`test/spec/wasm-2.0-assert/`) lands in a follow-up chunk
    // (k-1 — curated sign-ext / sat-trunc / multi-value /
    // call_indirect wast vendor); until then the runner reports
    // "corpus not found; 0 manifests" and exits clean so test-all
    // stays green.
    // §9.9 / 9.9-l-1b-d093-d67 (D-134 probe): force the spec_assert
    // non-simd runner to compile single-threaded. The d-65
    // investigation surfaced a cross-thread `siglongjmp` hypothesis
    // (our `sigsegvHandler` installs OK + fires on intentional null
    // deref, but does NOT fire on the real Rosetta-translated x86_64 Linux
    // SEGV — strong
    // evidence the SEGV is delivered to a worker thread context our
    // handler cannot service). Building with `-fsingle-threaded`
    // makes `std.Io.Threaded.init` return `.init_single_threaded`
    // (per Zig std's `Io/Threaded.zig`), so no
    // `Io.Threaded` worker threads can spawn at all. The spec_assert
    // runner walks corpora + invokes JIT bodies purely sequentially
    // — no `async` / `concurrent` use — so single-threaded is the
    // correct execution shape regardless. If the Rosetta-translated x86_64 Linux SEGV
    // persists post-d-67, cross-thread is ruled out and the
    // hypothesis space narrows to (i) libc-context SEGV (RIP
    // captured in libc.so.6 region per d-65 valgrind) or (ii) Zig's
    // own `handleSegfaultPosix` chain still firing despite our own
    // sigaction (D-134 candidate path (d) — toolchain PR #25227).
    const non_simd_assert_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/spec_assert_runner_non_simd.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    non_simd_assert_runner_mod.addImport("zwasm", zwasm_lib_mod);
    non_simd_assert_runner_mod.addImport("spectest_module", spectest_wasm_mod);
    // D-148 workaround: force LLVM backend for this binary. The
    // self-hosted x86_64 backend miscompiles `callconv(.c)` calls
    // with 9 FP scalar args + MEMORY-class return (`callLargesig`
    // in entry.zig hits it; large-sig spec fixture is the only
    // affected test). See Codeberg ziglang/zig#35343 (also #35329
    // for the related aggregate-arg miscompile). Mac aarch64
    // already defaults to LLVM, so the override only changes
    // x86_64 hosts in Debug. Revert once upstream lands the fix.
    const non_simd_assert_runner_exe = b.addExecutable(.{
        .name = "zwasm-spec-wasm-2-0-assert",
        .root_module = non_simd_assert_runner_mod,
        .use_llvm = true,
    });
    // D-165 cycle 9 diag: install to zig-out/bin/ so D165_DUMP_JIT
    // dumps + ad-hoc isolated runs against custom manifest dirs can
    // use a stable path (`zig-out/bin/zwasm-spec-wasm-2-0-assert(.exe)`)
    // instead of hunting for the latest .zig-cache/o/*/*.exe hash.
    b.installArtifact(non_simd_assert_runner_exe);
    const run_non_simd_assert = b.addRunArtifact(non_simd_assert_runner_exe);
    run_non_simd_assert.addArg(b.pathFromRoot("test/spec/wasm-2.0-assert"));
    const test_spec_wasm_2_0_assert_step = b.step("test-spec-wasm-2.0-assert", "Run Wasm 2.0 non-SIMD scalar spec assertion runner (§9.9 / 9.9-l-1b per ADR-0057; corpus lands at k-1)");
    test_spec_wasm_2_0_assert_step.dependOn(&run_non_simd_assert.step);

    // §17.4 D-301 — official atomics (threads proposal) conformance corpus,
    // run by the same non_simd scalar runner (atomics are pure-int scalar).
    const run_threads_assert = b.addRunArtifact(non_simd_assert_runner_exe);
    run_threads_assert.addArg(b.pathFromRoot("test/spec/threads-assert"));
    const test_spec_threads_assert_step = b.step("test-spec-threads-assert", "Run atomics (threads) official spec assertion corpus via the non-SIMD scalar runner (§17.4 / D-301)");
    test_spec_threads_assert_step.dependOn(&run_threads_assert.step);

    // `zig build test-spec-wasm-3.0-assert` — §10 / 10.T-2b. Wasm 3.0
    // assertion runner skeleton; enumerates the baked manifests under
    // `test/spec/wasm-3.0-assert/<proposal>/<name>/manifest.txt` and
    // reports per-proposal directive counts. JIT-execute + assertion
    // matching lands cycle-by-cycle as impl rows 10.M / 10.R / 10.TC /
    // 10.E / 10.G adopt the spec_assert_runner_base callbacks pattern.
    const wasm_3_0_assert_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/spec_assert_runner_wasm_3_0.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_3_0_assert_runner_mod.addImport("zwasm", core_rs); // ADR-0177: integration runner → ReleaseSafe
    const wasm_3_0_assert_runner_exe = b.addExecutable(.{
        .name = "zwasm-spec-wasm-3-0-assert",
        .root_module = wasm_3_0_assert_runner_mod,
    });
    // Installed so the wasmtime-misc native differential sweep (ADR-0192)
    // can run gc/memory64/tail-call/function-references/multi-memory
    // buckets through the GC/typed-ref-capable native engine runner.
    b.installArtifact(wasm_3_0_assert_runner_exe);
    const run_wasm_3_0_assert = b.addRunArtifact(wasm_3_0_assert_runner_exe);
    run_wasm_3_0_assert.addArg(b.pathFromRoot("test/spec/wasm-3.0-assert"));
    const test_spec_wasm_3_0_assert_step = b.step("test-spec-wasm-3.0-assert", "Run Wasm 3.0 spec assertion runner skeleton (§10 / 10.T-2b; 5 sub-corpora enumerated)");
    test_spec_wasm_3_0_assert_step.dependOn(&run_wasm_3_0_assert.step);

    // In-source test of the runner skeleton (covers PROPOSALS list).
    const wasm_3_0_assert_unit_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/spec_assert_runner_wasm_3_0.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_3_0_assert_unit_mod.addImport("zwasm", core);
    const wasm_3_0_assert_unit_tests = b.addTest(.{ .root_module = wasm_3_0_assert_unit_mod });
    const run_wasm_3_0_assert_unit = b.addRunArtifact(wasm_3_0_assert_unit_tests);
    test_step.dependOn(&run_wasm_3_0_assert_unit.step);

    // Corpus-presence guard (ADR-0174 win-harden-I). All five spec-assert
    // corpora are COMMITTED (not host-regenerated), so a corpus root that
    // fails to open is a REAL error — not a fresh-checkout / pre-regen
    // state. The simd / non-simd / wasm-3.0 runners historically printed
    // "0 manifests" and exited 0 on a missing root: a silent skip that can
    // mask a host-specific path-resolution failure behind a green
    // `test-all` (the Windows host OK-verdict-hides-pass=0 anomaly this
    // campaign hunts). Each now `exit(1)`s on a missing root, matching the
    // wasm-1.0 `spec_assert_runner`. These negative runs pin that on EVERY
    // host (incl. the Windows host) — a runner that silently skips its corpus
    // turns this build RED.
    const absent_corpus = b.pathFromRoot("test/spec/__absent_corpus_negative_test__");
    const run_simd_absent = b.addRunArtifact(simd_assert_runner_exe);
    run_simd_absent.addArg(absent_corpus);
    run_simd_absent.expectExitCode(1);
    const run_non_simd_absent = b.addRunArtifact(non_simd_assert_runner_exe);
    run_non_simd_absent.addArg(absent_corpus);
    run_non_simd_absent.expectExitCode(1);
    const run_wasm_3_0_absent = b.addRunArtifact(wasm_3_0_assert_runner_exe);
    run_wasm_3_0_absent.addArg(absent_corpus);
    run_wasm_3_0_absent.expectExitCode(1);
    const test_corpus_presence_step = b.step("test-corpus-presence", "Assert spec-assert runners FAIL (exit 1) on a missing corpus root — no silent skip (ADR-0174)");
    test_corpus_presence_step.dependOn(&run_simd_absent.step);
    test_corpus_presence_step.dependOn(&run_non_simd_absent.step);
    test_corpus_presence_step.dependOn(&run_wasm_3_0_absent.step);

    // §10 / 10.E spec corpus runner foundation — manifest parser
    // tests. Lands ahead of the dispatcher integration so future
    // cycles can wire parsed Directives through cli_run.runWasmCaptured
    // against a structured input shape.
    const wasm_3_0_manifest_unit_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/wasm_3_0_manifest.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_3_0_manifest_unit_mod.addImport("zwasm", core);
    const wasm_3_0_manifest_unit_tests = b.addTest(.{ .root_module = wasm_3_0_manifest_unit_mod });
    const run_wasm_3_0_manifest_unit = b.addRunArtifact(wasm_3_0_manifest_unit_tests);
    test_step.dependOn(&run_wasm_3_0_manifest_unit.step);

    // §10 / 10.T-3: gc_stress + eh_frequency runner skeletons.
    // Impl-body lands when 10.G / 10.E activate (collector vtable +
    // FP-walk unwind in place). Until then the runners report
    // SKIP-P10-{GC,EH}-GAP and exit 0; their in-source unit tests
    // verify the matrix shapes per ADR-0115/0116 + ADR-0114.
    const gc_stress_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/runners/gc_stress_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gc_stress_runner_tests = b.addTest(.{ .root_module = gc_stress_runner_mod });
    const run_gc_stress_runner_tests = b.addRunArtifact(gc_stress_runner_tests);
    test_step.dependOn(&run_gc_stress_runner_tests.step);

    const eh_frequency_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/runners/eh_frequency_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const eh_frequency_runner_tests = b.addTest(.{ .root_module = eh_frequency_runner_mod });
    const run_eh_frequency_runner_tests = b.addRunArtifact(eh_frequency_runner_tests);
    test_step.dependOn(&run_eh_frequency_runner_tests.step);

    // `zig build test-spec-wasm-2.0` — wast-directive runner
    // (Phase 2 / §9.2 / 2.7). Reads each subdir's manifest.txt
    // and processes module / assert_invalid / assert_malformed
    // (binary) commands.
    const wast_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/wast_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    wast_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const wast_runner_exe = b.addExecutable(.{
        .name = "zwasm-wast-runner",
        .root_module = wast_runner_mod,
    });
    const run_wast_2_0 = b.addRunArtifact(wast_runner_exe);
    run_wast_2_0.addArg(b.pathFromRoot("test/spec/wasm-2.0"));
    const test_spec_2_0_step = b.step("test-spec-wasm-2.0", "Run the Wasm 2.0 wast-directive runner");
    test_spec_2_0_step.dependOn(&run_wast_2_0.step);

    // `zig build test-wasmtime-misc-basic` — Phase 6 / §9.6 / 6.B
    // (per ADR-0012). Drives the wast_runner against the
    // wasmtime misc_testsuite BATCH1 fixtures vendored under
    // `test/wasmtime_misc/wast/basic/` (migrated in 6.B from the
    // now-dissolved `test/v1_carry_over/`). Initial set is
    // parse + validate only; runtime-asserting coverage lands
    // when 6.D re-drives the same corpus through the
    // wast_runtime_runner.
    const run_wasmtime_misc_basic = b.addRunArtifact(wast_runner_exe);
    run_wasmtime_misc_basic.addArg(b.pathFromRoot("test/wasmtime_misc/wast"));
    const test_wasmtime_misc_basic_step = b.step("test-wasmtime-misc-basic", "Run the wasmtime misc_testsuite BATCH1 corpus (parse + validate)");
    test_wasmtime_misc_basic_step.dependOn(&run_wasmtime_misc_basic.step);

    // `zig build test-runtime-runner-smoke` — Phase 6 / §9.6 / 6.A
    // (per ADR-0013). Drives the runtime-asserting WAST runner
    // against the in-tree smoke fixture (`test/runners/fixtures/`).
    // Smoke gate exercises module + assert_return + assert_trap +
    // valid; the full wasmtime_misc corpus wires in 6.D.
    const wast_runtime_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/runners/wast_runtime_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wast_runtime_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const wast_runtime_runner_exe = b.addExecutable(.{
        .name = "zwasm-wast-runtime-runner",
        .root_module = wast_runtime_runner_mod,
    });
    // Installed so the wasmtime-misc differential sweep (ADR-0192)
    // can invoke it on an arbitrary generated corpus dir.
    b.installArtifact(wast_runtime_runner_exe);
    const run_wast_runtime_smoke = b.addRunArtifact(wast_runtime_runner_exe);
    run_wast_runtime_smoke.addArg(b.pathFromRoot("test/runners/fixtures"));
    const test_runtime_runner_smoke_step = b.step("test-runtime-runner-smoke", "Run the runtime-asserting WAST runner against the smoke fixture");
    test_runtime_runner_smoke_step.dependOn(&run_wast_runtime_smoke.step);

    // `zig build test-wasmtime-misc-runtime` — Phase 6 / §9.6 / 6.D
    // (per ADR-0012). Drives the runtime-asserting runner against
    // the same wasmtime_misc corpus as test-wasmtime-misc-basic, but
    // consuming `manifest_runtime.txt` (assert_return / assert_trap /
    // module / register / invoke) instead of the parse-only
    // `manifest.txt`. Surfaces v2 interp behaviour gaps that the
    // parse runner cannot see.
    //
    // **Not wired into `test-all` aggregate**. The current corpus
    // panics inside `interp.popOperand`'s assert when a fixture
    // exercises an operand-stack discipline bug (one of the 39
    // trap-mid-execution patterns ADR-0011 surfaced). 6.E (interp
    // behaviour bug investigation) addresses these; once the
    // underlying gaps close, this step joins `test-all`.
    // Until then, run standalone for triage:
    //   zig build test-wasmtime-misc-runtime
    const run_wasmtime_misc_runtime = b.addRunArtifact(wast_runtime_runner_exe);
    run_wasmtime_misc_runtime.addArg(b.pathFromRoot("test/wasmtime_misc/wast"));
    const test_wasmtime_misc_runtime_step = b.step("test-wasmtime-misc-runtime", "Run the runtime-asserting WAST runner against the wasmtime_misc corpus (NOT in test-all; surfaces 6.E targets)");
    test_wasmtime_misc_runtime_step.dependOn(&run_wasmtime_misc_runtime.step);

    // `zig build test-realworld` — parse-smoke a vendored set of
    // toolchain-produced .wasm fixtures (Phase 2 / §9.2 / 2.6).
    const realworld_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/realworld/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    realworld_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const realworld_runner_exe = b.addExecutable(.{
        .name = "zwasm-realworld-runner",
        .root_module = realworld_runner_mod,
    });
    const run_realworld = b.addRunArtifact(realworld_runner_exe);
    run_realworld.addArg(b.pathFromRoot("test/realworld/wasm"));
    // has_side_effects: redundant here, same as the run_edge_* steps above —
    // an untracked `addArg` corpus dir alone does not make a step cacheable.
    // Kept as a statement of intent. See D-592.
    run_realworld.has_side_effects = true;
    const test_realworld_step = b.step("test-realworld", "Run the realworld parse smoke");
    test_realworld_step.dependOn(&run_realworld.step);

    // `zig build bench-latency` — ADR-0209. Steady-state per-call latency on an
    // already-instantiated module. Every other bench goes through `hyperfine`
    // on a whole process, which is one guest call per process, so a per-call
    // cost is paid once there and vanishes into process startup. D-584 / D-585
    // were both invisible to that harness by construction. NOT in `test-all`:
    // it is a measurement, not an assertion, and its numbers move with machine
    // state (7% between rounds on one host).
    const latency_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("bench/latency/percall_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    latency_runner_mod.addImport("zwasm", zwasm_lib_mod);
    latency_runner_mod.addImport("build_options", build_options_mod);
    const latency_runner_exe = b.addExecutable(.{
        .name = "zwasm-latency-runner",
        .root_module = latency_runner_mod,
    });
    const run_latency = b.addRunArtifact(latency_runner_exe);
    // has_side_effects: redundant (see the run_edge_* comment and D-592 —
    // a step with no output arg is already side-effecting). Kept because the
    // intent is load-bearing here: a benchmark must re-measure, and if this
    // step ever gains an output arg, caching it would silently report the
    // previous machine state's numbers.
    run_latency.has_side_effects = true;
    const bench_latency_step = b.step("bench-latency", "Measure steady-state per-call latency (ADR-0209; not an assertion, not in test-all)");
    bench_latency_step.dependOn(&run_latency.step);

    // ADR-0209 — compile-only, so the gate catches public-API drift
    // (`Instance.typedFunc`, `Module.InstantiateOpts.engine`, `std.Io.Clock`)
    // without spending gate wall-clock on a measurement. Running it in CI would
    // record a shared runner's numbers as if they meant something; not
    // compiling it at all lets it bit-rot silently, which is the failure this
    // whole PR is about.
    const bench_latency_build_step = b.step("bench-latency-build", "Compile the per-call latency runner without running it (ADR-0209)");
    bench_latency_build_step.dependOn(&latency_runner_exe.step);

    // `zig build test-fuzz` — §14.3 / D-256 fuzz smoke. Feeds each
    // committed seed-corpus file's raw bytes through `parser.parse` +
    // the public `Engine.compile` (parse + validate). A decode-error
    // return is an EXPECTED reject; a CRASH (panic / SEGV / OOM-loop)
    // is a finding — it kills the loader process → red gate. Full
    // campaigns run on demand over a larger gitignored `wasm-tools smith`
    // corpus (`gen_fuzz_corpus.sh campaign`; automation retired with
    // nightly.yml — ADR-0211 D1, revival hints in D-593).
    const fuzz_loader_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/fuzz/fuzz_loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_loader_mod.addImport("zwasm", zwasm_lib_mod);
    const fuzz_loader_exe = b.addExecutable(.{
        .name = "zwasm-fuzz-loader",
        .root_module = fuzz_loader_mod,
    });
    const run_fuzz = b.addRunArtifact(fuzz_loader_exe);
    run_fuzz.addArg(b.pathFromRoot("test/fuzz/corpus/seed"));
    // has_side_effects: redundant, same as run_realworld above (see that
    // comment and D-592). Kept as a statement of intent.
    run_fuzz.has_side_effects = true;
    const test_fuzz_step = b.step("test-fuzz", "Run the fuzz smoke over the committed seed corpus (§14.3 / D-256)");
    test_fuzz_step.dependOn(&run_fuzz.step);

    // `zig build fuzz-campaign` — on-demand campaign (ADR-0211 D1 / D-593).
    // Runs the loader over the larger gitignored campaign corpus
    // (`gen_fuzz_corpus.sh campaign`, generated on a host with
    // `wasm-tools`). NOT in test-all (the campaign dir is absent on a
    // normal checkout).
    const run_fuzz_campaign = b.addRunArtifact(fuzz_loader_exe);
    run_fuzz_campaign.addArg(b.pathFromRoot("test/fuzz/corpus/campaign"));
    run_fuzz_campaign.has_side_effects = true;
    const fuzz_campaign_step = b.step("fuzz-campaign", "Run the fuzz loader over the gitignored campaign corpus (on-demand, D-593)");
    fuzz_campaign_step.dependOn(&run_fuzz_campaign.step);

    // `zig build test-fuzz-exec` (alias `fuzz-diff`) — D-469/D-510 interp-vs-JIT
    // EXECUTION differential. Invokes each module's 0-param/single-scalar-result
    // exports under the interp AND two JIT lanes (`.auto` guard-page elision +
    // `.explicit` inline check, ADR-0202) and gates on value/trap/memory-snapshot
    // divergences (a JIT-execute miscompile = a finding). GATING. The campaign
    // corpus rides `zwasm-fuzz-exec <dir>` directly (gitignored, like the loader).
    const fuzz_exec_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/fuzz/fuzz_exec.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_exec_mod.addImport("zwasm", zwasm_lib_mod);
    const fuzz_exec_exe = b.addExecutable(.{
        .name = "zwasm-fuzz-exec",
        .root_module = fuzz_exec_mod,
    });
    const run_fuzz_exec = b.addRunArtifact(fuzz_exec_exe);
    // Curated, hand-written 0-param/scalar modules (value/trap/loop/call cases) —
    // the smith seed exports nothing comparable, so this dedicated corpus is what
    // makes the committed gate actually compare functions. The wide campaign run
    // (122 funcs) rides `zwasm-fuzz-exec test/fuzz/corpus/campaign` directly.
    run_fuzz_exec.addArg(b.pathFromRoot("test/fuzz/corpus/exec_seed"));
    // D-510 — committed regression corpus (wazero-fuzzcases-style): minimised
    // past differential findings + hand-written memory-state / guard-boundary
    // exercisers, replayed on every run.
    run_fuzz_exec.addArg(b.pathFromRoot("test/fuzz/corpus/regression"));
    run_fuzz_exec.has_side_effects = true;
    const test_fuzz_exec_step = b.step("test-fuzz-exec", "Interp-vs-JIT execution differential fuzz (D-469)");
    test_fuzz_exec_step.dependOn(&run_fuzz_exec.step);
    // D-510 — first-class name matching the debt-row/peer vocabulary; same gate.
    const fuzz_diff_step = b.step("fuzz-diff", "Interp-vs-JIT differential over the committed corpora (= test-fuzz-exec; D-510)");
    fuzz_diff_step.dependOn(&run_fuzz_exec.step);

    // `zig build test-aot-diff` — AOT-full-fidelity campaign Phase II: the
    // CROSS-PROCESS `.wasm`-vs-`.cwasm` differential. Spawns the real zwasm
    // CLI (run / compile / run-artifact) per fixture, so ASLR-staleness bugs
    // (D-516 baked helper addresses) that in-process harnesses can't see are
    // exercised the way a real deployment would. Known gaps are pinned in the
    // runner's expectation table (D-516/D-517/D-518) — the gate trips on any
    // UNEXPECTED divergence and on RATCHET-FLIPs (a pinned gap now matching,
    // forcing the table update in the fixing PR).
    const aot_diff_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/aot/aot_process_diff.zig"),
        .target = target,
        .optimize = optimize,
    });
    const aot_diff_exe = b.addExecutable(.{
        .name = "zwasm-aot-process-diff",
        .root_module = aot_diff_mod,
    });
    const run_aot_diff = b.addRunArtifact(aot_diff_exe);
    run_aot_diff.addArtifactArg(exe_rs); // the CLI under test (ADR-0177 floor)
    run_aot_diff.addArg(b.pathFromRoot("test/realworld/wasm"));
    run_aot_diff.addArg(b.pathFromRoot("test/aot/corpus"));
    run_aot_diff.has_side_effects = true;
    const test_aot_diff_step = b.step("test-aot-diff", "Cross-process .wasm-vs-.cwasm differential (AOT campaign Phase II)");
    test_aot_diff_step.dependOn(&run_aot_diff.step);

    // `zig build test-realworld-run` — Phase 6 / §9.6 / 6.1
    // chunk b. Drives each fixture through `cli_run.runWasm`
    // end-to-end (engine → store → WASI → instantiate → entry
    // → wasm_func_call). Outcome categories: PASS / SKIP-WASI /
    // SKIP-NOENTRY / FAIL. The gate trips only on FAIL —
    // SKIP-WASI counts but is orthogonal to interp-op coverage.
    const realworld_run_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/realworld/run_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    realworld_run_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const realworld_run_runner_exe = b.addExecutable(.{
        .name = "zwasm-realworld-run-runner",
        .root_module = realworld_run_runner_mod,
    });
    const run_realworld_run = b.addRunArtifact(realworld_run_runner_exe);
    run_realworld_run.addArg(b.pathFromRoot("test/realworld/wasm"));
    run_realworld_run.has_side_effects = true; // fixture-only changes must re-run (cyc216 gap)
    const test_realworld_run_step = b.step("test-realworld-run", "Run each realworld fixture end-to-end via cli_run.runWasm");
    test_realworld_run_step.dependOn(&run_realworld_run.step);

    // `zig build test-realworld-run-jit` — §9.7 / 7.9 chunk a
    // baseline. Walks the same corpus and drives each fixture
    // through `engine.runner.compileWasm` (the JIT pipeline).
    // Reports compile-side coverage: COMPILE-PASS / COMPILE-IMPORTS
    // / COMPILE-OP / COMPILE-VAL / FAIL-OTHER. Compilation ONLY —
    // whether the emitted code computes the right answer is
    // `test-realworld-diff-jit`'s question, not this step's.
    const realworld_run_jit_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/realworld/run_runner_jit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    realworld_run_jit_mod.addImport("zwasm", zwasm_lib_mod);
    const realworld_run_jit_exe = b.addExecutable(.{
        .name = "zwasm-realworld-run-jit-runner",
        .root_module = realworld_run_jit_mod,
    });
    const run_realworld_run_jit = b.addRunArtifact(realworld_run_jit_exe);
    run_realworld_run_jit.addArg(b.pathFromRoot("test/realworld/wasm"));
    run_realworld_run_jit.has_side_effects = true; // fixture-only changes must re-run (cyc216 gap)
    const test_realworld_run_jit_step = b.step("test-realworld-run-jit", "JIT-compile each realworld fixture (§9.7 / 7.9 baseline)");
    test_realworld_run_jit_step.dependOn(&run_realworld_run_jit.step);

    // `zig build jit-result-probe-releasesafe` — D-245 RESULT-path gate
    // (§15.5 / chunk 1). `check_jit_releasesafe.sh` only exercises the no-arg
    // VOID path; the i32 RESULT path (`runner.runI32Export` →
    // `entry.invokeAndCheck`) has its own host→JIT callee-saved-clobber seam.
    // The bug ONLY manifests in ReleaseSafe, and an exe's optimize does NOT
    // propagate to a pre-built `core` module — so this step compiles a FRESH
    // `core` PINNED to ReleaseSafe (regardless of the ambient `-Doptimize`)
    // plus the probe, then runs it. A non-zero exit = the clobber regressed.
    const core_releasesafe = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("src/zwasm.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    core_releasesafe.addImport("build_options", build_options_mod);
    core_releasesafe.addIncludePath(b.path("include"));
    core_releasesafe.addImport("zwasm", core_releasesafe);
    const jit_result_probe_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/jit/releasesafe_result_probe.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    jit_result_probe_mod.addImport("zwasm", core_releasesafe);
    const jit_result_probe_exe = b.addExecutable(.{
        .name = "zwasm-jit-result-probe",
        .root_module = jit_result_probe_mod,
    });
    const run_jit_result_probe = b.addRunArtifact(jit_result_probe_exe);
    run_jit_result_probe.has_side_effects = true; // must run even when nothing else changed
    const jit_result_probe_step = b.step("jit-result-probe-releasesafe", "D-245 RESULT-path ReleaseSafe regression probe (runI32Export callee-saved preservation)");
    jit_result_probe_step.dependOn(&run_jit_result_probe.step);

    // `zig build test-realworld-diff` — Phase 6 / §9.6 / 6.F.
    // Spawns `wasmtime run <fixture>` per fixture, captures
    // stdout, compares byte-for-byte against
    // `cli_run.runWasmCaptured`. Gate is 30+ matches; runner
    // SKIPs gracefully when wasmtime is not on PATH (so the
    // build remains green on hosts that lack it).
    const realworld_diff_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/realworld/diff_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    realworld_diff_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const realworld_diff_runner_exe = b.addExecutable(.{
        .name = "zwasm-realworld-diff-runner",
        .root_module = realworld_diff_runner_mod,
    });
    const run_realworld_diff = b.addRunArtifact(realworld_diff_runner_exe);
    run_realworld_diff.addArg(b.pathFromRoot("test/realworld/wasm"));
    run_realworld_diff.has_side_effects = true; // fixture-only changes must re-run (cyc216 gap)
    // Nothing in the build graph depends on this step any more — `test-all`
    // takes `test-realworld-diff-jit`, which is the same runner plus `--jit`.
    // It survives as the manual entry point for the shared lane alone (a
    // faster loop when triaging a non-JIT divergence). Being CI-unreached, its
    // wiring can rot silently; the `--jit` step below shares this exe and
    // corpus arg, so a break here shows up there.
    const test_realworld_diff_step = b.step("test-realworld-diff", "Diff realworld fixtures' stdout against wasmtime (shared lane only; not in test-all)");
    test_realworld_diff_step.dependOn(&run_realworld_diff.step);

    // `zig build test-realworld-diff-aot` — D-283 widen / D-251 validate.
    // Same differential PLUS an opt-in AOT lane (compile→`.cwasm`→`runCwasmWasi`
    // per fixture, vs wasmtime). NOT in the default `test-all`: it JIT-compiles
    // every fixture (slow) + runs native AOT code in-process. Report-only for
    // now (triages AOT-WASI corpus coverage); a follow-up gates it once clean.
    const run_realworld_diff_aot = b.addRunArtifact(realworld_diff_runner_exe);
    run_realworld_diff_aot.addArg(b.pathFromRoot("test/realworld/wasm"));
    run_realworld_diff_aot.addArg("--aot");
    run_realworld_diff_aot.has_side_effects = true;
    const test_realworld_diff_aot_step = b.step("test-realworld-diff-aot", "Realworld differential incl. the opt-in AOT lane (D-283)");
    test_realworld_diff_aot_step.dependOn(&run_realworld_diff_aot.step);

    // `zig build d489-repro` — minimal D-489 isolation harness (x86_64-linux only;
    // Rosetta + arm64 mask it). Isolates capture-buffer vs in-process-ripple as the
    // cause of tinygo_json's jit=130/correct=90 divergence under the diff-runner.
    const d489_repro_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/realworld/d489_repro.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    d489_repro_mod.addImport("zwasm", zwasm_lib_mod);
    const d489_repro_exe = b.addExecutable(.{
        .name = "zwasm-d489-repro",
        .root_module = d489_repro_mod,
    });
    const run_d489_repro = b.addRunArtifact(d489_repro_exe);
    run_d489_repro.has_side_effects = true;
    const d489_repro_step = b.step("d489-repro", "Minimal D-489 isolation harness");
    d489_repro_step.dependOn(&run_d489_repro.step);

    // `zig build test-realworld-diff-wasmer` — §9.6 A3 second-oracle lane.
    // Same wasmtime differential PLUS wasmer as a 2nd reference oracle; flags
    // REF-DISAGREE fixtures (the two reference runtimes disagree — the
    // divergence a single-reference gate misses). Report-only; Mac-only
    // (wasmer is not in the x86_64 dev shells), graceful skip off-Mac.
    const run_realworld_diff_wasmer = b.addRunArtifact(realworld_diff_runner_exe);
    run_realworld_diff_wasmer.addArg(b.pathFromRoot("test/realworld/wasm"));
    run_realworld_diff_wasmer.addArg("--wasmer");
    run_realworld_diff_wasmer.has_side_effects = true;
    const test_realworld_diff_wasmer_step = b.step("test-realworld-diff-wasmer", "Realworld differential incl. the opt-in wasmer second-oracle lane (§9.6 A3)");
    test_realworld_diff_wasmer_step.dependOn(&run_realworld_diff_wasmer.step);

    // `zig build test-realworld-diff-jit` — D-283 the real JIT-correctness net,
    // and the lane `test-all` depends on (NOT `test-realworld-diff`, which is the
    // same runner minus the engine lanes; depending on both would run the shared
    // lane twice). Same wasmtime differential PLUS a `--jit` lane that runs each
    // fixture via the WASI-aware `--engine jit` path (runWasmJitCaptured) +
    // byte-diffs stdout vs wasmtime. Superseded the run_runner_jit run-stage,
    // which ran with a null WASI host and so reported false traps.
    // Measured cost over the shared-lane-only step: +29s (19.3 → 48.3) on
    // x86_64-linux — a rounding error against the ~10 min core gate, which is
    // why this sits in the core gate rather than behind ZWASM_CI_EXTENDED.
    // `--interp` (issue #215) adds the forced-interp lane to the same
    // invocation: 52 of 56 fixtures byte-diffed vs wasmtime under
    // `Limits{ .engine = .interp }`, the 4 slowest enumerated as accounted
    // SKIP-INTERP-SLOW (81.7s of the corpus's 116.0s forced-interp total,
    // x86_64-linux Debug 2026-08-21 — the lane's own +34s stays in the JIT
    // lane's cost class). Full-corpus coverage: `test-realworld-diff-interp`.
    const run_realworld_diff_jit = b.addRunArtifact(realworld_diff_runner_exe);
    run_realworld_diff_jit.addArg(b.pathFromRoot("test/realworld/wasm"));
    run_realworld_diff_jit.addArg("--jit");
    run_realworld_diff_jit.addArg("--interp");
    run_realworld_diff_jit.has_side_effects = true;
    const test_realworld_diff_jit_step = b.step("test-realworld-diff-jit", "Realworld differential incl. the gating WASI-aware JIT and forced-interp lanes (D-283, #215)");
    test_realworld_diff_jit_step.dependOn(&run_realworld_diff_jit.step);

    // `zig build test-realworld-diff-interp` — the forced-interp differential
    // over the FULL corpus (`--interp-all`: the enumerated-slow fixtures run
    // too, under a 240s per-fixture deadline). Manual entry point, NOT in
    // `test-all` — the 4 enumerated fixtures alone are ~82s on x86_64-linux
    // Debug. One command re-derives interp-vs-wasmtime for all 56.
    const run_realworld_diff_interp = b.addRunArtifact(realworld_diff_runner_exe);
    run_realworld_diff_interp.addArg(b.pathFromRoot("test/realworld/wasm"));
    run_realworld_diff_interp.addArg("--interp-all");
    run_realworld_diff_interp.has_side_effects = true;
    const test_realworld_diff_interp_step = b.step("test-realworld-diff-interp", "Full-corpus forced-interp differential incl. the enumerated-slow fixtures (manual; not in test-all)");
    test_realworld_diff_interp_step.dependOn(&run_realworld_diff_interp.step);

    // `zig build test-api-zig-facade` — Phase 10 / §10.J / J.6.
    // Walks the realworld corpus driving each fixture through the
    // native Zig facade (`Engine.compile` → `Module.instantiate`).
    // Pairs with `test-realworld-run` (c_api path) so the same
    // fixture set exercises both surfaces. WASI fixtures SKIP per
    // D-176 (defineWasi lands at J.7).
    const zig_facade_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/api/zig_facade_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zig_facade_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const zig_facade_runner_exe = b.addExecutable(.{
        .name = "zwasm-zig-facade-runner",
        .root_module = zig_facade_runner_mod,
    });
    const run_zig_facade = b.addRunArtifact(zig_facade_runner_exe);
    run_zig_facade.addArg(b.pathFromRoot("test/realworld/wasm"));
    const test_api_zig_facade_step = b.step("test-api-zig-facade", "Run each realworld fixture through the native Zig API (Engine/Module/Instance)");
    test_api_zig_facade_step.dependOn(&run_zig_facade.step);

    // `zig build test-wasi-p1` — Phase 4 / §9.4 / 4.9. Walks
    // `test/wasi/` driving each .wasm fixture through
    // `cli_run.runWasm`, comparing the exit code against the
    // matching `<basename>.expected_exit` file.
    const wasi_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/wasi/runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wasi_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const wasi_runner_exe = b.addExecutable(.{
        .name = "zwasm-wasi-runner",
        .root_module = wasi_runner_mod,
    });
    const run_wasi_p1 = b.addRunArtifact(wasi_runner_exe);
    run_wasi_p1.addArg(b.pathFromRoot("test/wasi"));
    const test_wasi_p1_step = b.step("test-wasi-p1", "Run the WASI 0.1 fixture suite");
    test_wasi_p1_step.dependOn(&run_wasi_p1.step);

    // `zig build test-wasi-p1-official` — the OFFICIAL wasi-testsuite
    // wasm32-wasip1 corpus (D-582). Deliberately NOT in `test-all` yet: the
    // corpus reports 14 engine-independent failures (D-583), so folding it
    // into the blocking gate now would red every PR. CI runs it as an ADVISORY
    // step in the `gate` job (step-level `continue-on-error`); this step joins
    // `test-all` when D-583 discharges, which is that row's exit condition.
    //
    // Two lanes, because the engines diverge: `--engine jit` fails 4 tests the
    // interpreter passes, and the default `.auto` prefers the JIT — so a
    // single unpinned lane would silently measure the JIT and label it
    // preview1 coverage.
    const wasi_official_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/wasi/official_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wasi_official_mod.addImport("zwasm", zwasm_lib_mod);
    const wasi_official_exe = b.addExecutable(.{
        .name = "zwasm-wasi-p1-official",
        .root_module = wasi_official_mod,
    });
    const run_wasi_official_interp = b.addRunArtifact(wasi_official_exe);
    run_wasi_official_interp.addArg(b.pathFromRoot("test/wasi/wasip1_official"));
    run_wasi_official_interp.addArg("interp");
    const run_wasi_official_jit = b.addRunArtifact(wasi_official_exe);
    run_wasi_official_jit.addArg(b.pathFromRoot("test/wasi/wasip1_official"));
    run_wasi_official_jit.addArg("jit");
    const test_wasi_p1_official_step = b.step("test-wasi-p1-official", "Run the official wasi-testsuite wasm32-wasip1 corpus on both engines (D-582)");
    test_wasi_p1_official_step.dependOn(&run_wasi_official_interp.step);
    test_wasi_p1_official_step.dependOn(&run_wasi_official_jit.step);

    // `zig build test-c-api` — Phase 3 / §9.3 / 3.9. Builds
    // `libzwasm.a` from the shared `core` module (rooted at
    // `src/zwasm.zig` per ADR-0024 D-1), compiles
    // `docs/examples/c_host/hello.c` against `include/wasm.h`, links
    // the two, and runs the resulting executable. The C host
    // exits 0 on success (printed result == 42).
    const c_api_lib = b.addLibrary(.{
        .name = "zwasm",
        .linkage = .static,
        .root_module = core,
    });
    c_api_lib.bundle_compiler_rt = bundle_compiler_rt;

    const c_host_mod = createSanitizedModule(b, sanitize_opts, .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_host_mod.addCSourceFile(.{
        .file = b.path("docs/examples/c_host/hello.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    c_host_mod.addIncludePath(b.path("include"));
    c_host_mod.linkLibrary(c_api_lib);

    const c_host_exe = b.addExecutable(.{
        .name = "zwasm-c-host-hello",
        .root_module = c_host_mod,
    });

    const run_c_host = b.addRunArtifact(c_host_exe);
    run_c_host.expectExitCode(0);
    const test_c_api_step = b.step("test-c-api", "Build libzwasm.a + the C host example, run the example");
    test_c_api_step.dependOn(&run_c_host.step);

    // `zig build static-lib` — install libzwasm.a + the public C headers into
    // zig-out/ for non-Zig consumers (Rust/C). External (non-zig) linkers must
    // build with `-Dcompiler-rt=true` (see the option above) and add `-lm`
    // (zwasm references libm: trunc/truncf/…; verified on Linux gcc)
    // and, on Linux, `-Wl,-z,noexecstack` (zig-emitted objects currently lack a
    // `.note.GNU-stack` section — Zig upstream limitation, D-312; harmless
    // deprecation warning otherwise). Respects -Dgc / -Dcomponent / -Dtarget.
    const static_lib_step = b.step("static-lib", "Install libzwasm.a + public headers (C/Rust consumers; build with -Dcompiler-rt=true, link with -lm [+ -Wl,-z,noexecstack on Linux])");
    const install_static_lib = b.addInstallArtifact(c_api_lib, .{});
    static_lib_step.dependOn(&install_static_lib.step);
    inline for (.{ "wasm.h", "wasi.h", "zwasm.h" }) |h| {
        static_lib_step.dependOn(&b.addInstallFileWithDir(b.path("include/" ++ h), .header, h).step);
    }

    // `zig build test-c-api-conformance` — §13.4. Compiles each
    // `test/c_api_conformance/*.c` (wasm-c-api example ports +
    // zwasm-specific tests) against `include/wasm.h` + libzwasm.a and
    // runs it (exit 0 = pass). Validates the §13.2 C surface end-to-end
    // through the real C ABI. Add `.c` files here as they land.
    const conformance_step = b.step("test-c-api-conformance", "Build + run the C-API conformance examples");
    const conformance_cases = [_]struct {
        src: []const u8,
        name: []const u8,
        /// Committed guest .wasm passed to the case as argv[1] (absolute path).
        wasm_arg: ?[]const u8 = null,
    }{
        .{ .src = "test/c_api_conformance/callback.c", .name = "callback" },
        .{ .src = "test/c_api_conformance/global_import.c", .name = "global_import" },
        .{ .src = "test/c_api_conformance/memory_import.c", .name = "memory_import" },
        .{ .src = "test/c_api_conformance/table_import.c", .name = "table_import" },
        .{ .src = "test/c_api_conformance/trap.c", .name = "trap" },
        .{ .src = "test/c_api_conformance/funcref_table_call.c", .name = "funcref_table_call" },
        .{ .src = "test/c_api_conformance/funcref_result_call.c", .name = "funcref_result_call" },
        .{ .src = "test/c_api_conformance/data_active_drop.c", .name = "data_active_drop" },
        .{ .src = "test/c_api_conformance/instance_get_func.c", .name = "instance_get_func" },
        .{ .src = "test/c_api_conformance/jit_engine.c", .name = "jit_engine" }, // ADR-0200 JIT mini-consumer
        .{ .src = "test/c_api_conformance/jit_callback.c", .name = "jit_callback" }, // D-478 host-func under JIT
        .{ .src = "test/c_api_conformance/jit_callback_args.c", .name = "jit_callback_args" }, // D-478 N-scalar-arg
        .{ .src = "test/c_api_conformance/jit_callback_fp.c", .name = "jit_callback_fp" }, // D-478 FP host-func args
        .{ .src = "test/c_api_conformance/jit_start.c", .name = "jit_start" }, // D-478 start function under JIT
        .{ .src = "test/c_api_conformance/jit_wasi.c", .name = "jit_wasi" }, // ADR-0200/D-478 WASI host-fn under JIT
        .{ .src = "test/c_api_conformance/wasi_exit_code.c", .name = "wasi_exit_code" }, // a C host reads a WASI exit status
        .{
            .src = "test/c_api_conformance/wasi_preopen.c",
            .name = "wasi_preopen",
            .wasm_arg = "test/c_api_conformance/wasi_preopen_guest.wasm",
        },
    };
    for (conformance_cases) |c| {
        const cmod = createSanitizedModule(b, sanitize_opts, .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        cmod.addCSourceFile(.{
            .file = b.path(c.src),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
        });
        cmod.addIncludePath(b.path("include"));
        cmod.linkLibrary(c_api_lib);
        const cexe = b.addExecutable(.{
            .name = b.fmt("zwasm-conformance-{s}", .{c.name}),
            .root_module = cmod,
        });
        const run_c = b.addRunArtifact(cexe);
        if (c.wasm_arg) |w| run_c.addFileArg(b.path(w));
        run_c.expectExitCode(0);
        conformance_step.dependOn(&run_c.step);
    }

    // `zig build run-zig-host` — §13.5. The Zig-native embedding example
    // (`docs/examples/zig_host/hello.zig`, ADR-0109 API) — counterpart to the
    // C-ABI `c_host`. Imports the `zwasm` core module, runs, exits 0.
    const zig_host_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("docs/examples/zig_host/hello.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_host_mod.addImport("zwasm", core);
    const zig_host_exe = b.addExecutable(.{
        .name = "zwasm-zig-host-hello",
        .root_module = zig_host_mod,
    });
    const run_zig_host = b.addRunArtifact(zig_host_exe);
    run_zig_host.expectExitCode(0);
    const run_zig_host_step = b.step("run-zig-host", "Build + run the native Zig host example");
    run_zig_host_step.dependOn(&run_zig_host.step);

    // `zig build run-zig-host-jit` (ADR-0200) — the JIT-backed mini-consumer:
    // `Module.instantiate(.{ .engine = .jit })` calling a multi-arg + a SIMD-body
    // export. Counterpart to `docs/examples/c_host/jit_engine.c`. Run in test-all.
    const zig_host_jit_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("docs/examples/zig_host/jit_engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_host_jit_mod.addImport("zwasm", core);
    const zig_host_jit_exe = b.addExecutable(.{
        .name = "zwasm-zig-host-jit",
        .root_module = zig_host_jit_mod,
    });
    const run_zig_host_jit = b.addRunArtifact(zig_host_jit_exe);
    run_zig_host_jit.expectExitCode(0);
    const run_zig_host_jit_step = b.step("run-zig-host-jit", "Build + run the JIT-backed Zig host example (ADR-0200)");
    run_zig_host_jit_step.dependOn(&run_zig_host_jit.step);

    // `zig build run-rust-host` — §13.5. A third, independent embedding-
    // ABI consumer: `docs/examples/rust_host/hello.rs` declares the wasm-c-api
    // surface via `extern "C"` and links the same `libzwasm.a` the C host
    // uses. **3-host (ADR-0162)**: native rust now lives on the test hosts
    // (the Linux host's `nix develop .#rust-host`; the Windows host's winget rust). Still
    // NOT in `test-all` (it needs the rust shell / native rust, not the lean
    // `default` shell) — invoked as its own step per host.
    //
    // macOS: rustc links via the xcrun-found SDK; wrap in `/bin/sh` to set
    // `SDKROOT` (xcrun's `--show-sdk-path` is broken on this dev Mac post-
    // Xcode-update — it prints "unable to find sdk" to STDOUT, rc=255). The
    // sh-wrapper probes the two standard SDK dirs when xcrun is unhealthy.
    // Linux/Windows: call rustc directly — no macOS SDK, and `/bin/sh` is
    // not natively spawnable by a Windows `zig build` process.
    const rustc_cmd = if (target.result.os.tag == .macos)
        b.addSystemCommand(&.{
            "/bin/sh", "-c",
            \\SDKROOT="$(xcrun --show-sdk-path 2>/dev/null)"
            \\if [ ! -d "$SDKROOT" ]; then
            \\  dev="$(xcode-select -p 2>/dev/null)"
            \\  for c in "$dev/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" "$dev/SDKs/MacOSX.sdk"; do
            \\    [ -d "$c" ] && SDKROOT="$c" && break
            \\  done
            \\fi
            \\export SDKROOT
            \\exec rustc --edition 2021 "$@"
            ,
            "sh",
        })
    else
        b.addSystemCommand(&.{ "rustc", "--edition", "2021" });
    rustc_cmd.addFileArg(b.path("docs/examples/rust_host/hello.rs"));
    rustc_cmd.addPrefixedDirectoryArg("-Lnative=", c_api_lib.getEmittedBinDirectory());
    rustc_cmd.addArg("-lstatic=zwasm");
    rustc_cmd.addArg("-o");
    // rustc names the bin-crate output `<name>.exe` on Windows; the run-step's
    // expected output path must match or zig's cache check FileNotFounds it
    // (the windows-gnu rust_host link succeeds, only the suffix differed).
    const rust_host_exe = if (target.result.os.tag == .windows)
        "zwasm-rust-host-hello.exe"
    else
        "zwasm-rust-host-hello";
    const rust_host_bin = rustc_cmd.addOutputFileArg(rust_host_exe);

    const run_rust_host = std.Build.Step.Run.create(b, "run zwasm-rust-host-hello");
    run_rust_host.addFileArg(rust_host_bin);
    run_rust_host.expectExitCode(0);
    const run_rust_host_step = b.step("run-rust-host", "Build + run the Rust host example (3-host per ADR-0162; needs native rust)");
    run_rust_host_step.dependOn(&run_rust_host.step);

    // ADR-0166 (D-292 B-core): verify the production internal-fault handler
    // end-to-end on EACH host. `zwasm --__selftest-crash` deliberately faults; the
    // handler must catch it and exit with code 70 (a distinct "internal error"
    // disposition, NOT a silent signal-death). Exercises the POSIX sigaction path
    // (Mac/Linux) + the Windows VEH path — the only behavioural test of the latter.
    const run_internal_fault = b.addRunArtifact(exe);
    run_internal_fault.addArg("--__selftest-crash");
    run_internal_fault.expectExitCode(70);
    const test_internal_fault_step = b.step("test-internal-fault", "Verify the internal-fault handler exits 70 (ADR-0166 / D-292 B-core)");
    test_internal_fault_step.dependOn(&run_internal_fault.step);

    // ADR-0202 D4/D5 (D-507) — verify the guard-page bounds-elision path
    // end-to-end on EACH host: `zwasm run --engine jit` on a boundary oob
    // load (eff_addr 65533 + 4 > 65536) must, with the CMP elided, hardware-
    // fault in the guard region, be redirected by the production handler to
    // the oob stub, and surface as a wasm trap (exit 1). This is the only
    // behavioural test of the FULL production elision path (installInternal-
    // FaultHandler + guarded memory + elided codegen + Win64 VEH redirect);
    // the spec corpus runs `.explicit` (non-guarded harness memory).
    const run_oob_trap = b.addRunArtifact(exe);
    run_oob_trap.addArgs(&.{
        "run",      "--engine",
        "jit",      "test/edge_cases/p7/memory_bounds/past_limit_load_i32.wasm",
        "--invoke", "test",
    });
    run_oob_trap.expectExitCode(1); // a genuine trap → exit 1 (interp-parity)
    // has_side_effects: `expectExitCode` routes through `addCheck`, which flips
    // `stdio` from `.infer_from_args` to `.check` — and `Run.hasSideEffects()`
    // returns FALSE for `.check`. That makes this step cacheable, while the
    // fixture above reaches it as a plain `addArg` STRING (not a tracked input),
    // so a fixture-only change is served from cache and never re-verified.
    // Measured 2026-08-15: swapping the 47-byte trapping module for an 8-byte
    // empty one left the step `cached` and green. Without this line the only
    // behavioural test of the production elision path is false coverage on any
    // warm cache (local `test-all`, gate_commit, gate_merge; CI checks out
    // fresh, so it is cold there). See D-592.
    // Alternative not taken: `addFileArg(b.path(…))` would track the fixture
    // and keep caching correct rather than defeating it, and would make the
    // implicit repo-root cwd explicit. Rejected for now only because the
    // always-run form matches every other runner here and the step costs
    // ~24ms; revisit if unconditional CLI re-runs become noticeable.
    run_oob_trap.has_side_effects = true;
    const test_oob_trap_step = b.step("test-oob-elision", "Verify guard-page bounds elision traps oob (ADR-0202 D4/D5 / D-507)");
    test_oob_trap_step.dependOn(&run_oob_trap.step);

    // Issue #320 — regression-run the fault-handler install/publish
    // protocol (`signal.ensureInstalled` ordering + `markInstalled`
    // stand-down). A standalone exe because the scenarios need a virgin
    // process-global install flag per iteration, which no test inside a
    // shared test binary can guarantee (any earlier in-process JIT
    // invoke arms it); the runner forks one pristine child per
    // scenario. Self-skips on Windows (fork).
    const signal_install_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/runners/signal_install_order_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    signal_install_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const signal_install_runner_exe = b.addExecutable(.{
        .name = "zwasm-signal-install-order",
        .root_module = signal_install_runner_mod,
    });
    const run_signal_install = b.addRunArtifact(signal_install_runner_exe);
    const test_signal_install_step = b.step("test-signal-install-order", "Regression-run the fault-handler install/publish ordering (issue #320; skips on Windows)");
    test_signal_install_step.dependOn(&run_signal_install.step);

    // `zig build test-all` — aggregate all enabled test layers.
    // Phase 0: only `test`. Phase 1+ adds spec / e2e / realworld /
    // c_api / fuzz steps as they land. Each layer registers itself
    // here so the user's invocation surface stays stable.
    const test_all_step = b.step("test-all", "Run all enabled test layers");
    test_all_step.dependOn(&run_internal_fault.step); // ADR-0166 B-core
    test_all_step.dependOn(&run_oob_trap.step); // ADR-0202 D4/D5 (D-507) guard-page elision
    test_all_step.dependOn(&run_signal_install.step); // issue #320 install/publish ordering
    test_all_step.dependOn(&run_core_tests.step);
    test_all_step.dependOn(&run_cli_tests.step);
    test_all_step.dependOn(&run_spec_smoke.step);
    test_all_step.dependOn(&run_spec_mvp.step);
    test_all_step.dependOn(&run_realworld.step);
    test_all_step.dependOn(&run_realworld_run.step);
    // `run_realworld_diff` was wired in at §9.6 / 6.F (39/50
    // matched, 0 mismatched). The remaining 11 SKIP-V2-* are
    // Go fixtures gated on the validator's typing-rule gap
    // (§9.6 outstanding spec gap "10 SKIP-VALIDATOR realworld
    // fixtures") — they are SKIP, not FAIL, so the runner
    // exits zero. Hosts without `wasmtime` on PATH degrade to
    // SKIP-WASMTIME-FAIL gracefully and do not break the gate.
    // The `--jit --interp` variant, NOT `run_realworld_diff`: same runner, same
    // default-engine lane, plus the gating JIT and forced-interp lanes — so one
    // dependency, no double run of the shared lane. The shared lane itself calls
    // `runWasmCaptured` with default `Limits`, i.e. `.auto`, which tries the JIT
    // first and reaches the interp only where the JIT cannot instantiate; the
    // `--interp` lane (issue #215) is what pins the engine and result-checks the
    // corpus on the interpreter (52 of 56 — 4 enumerated accounted skips).
    test_all_step.dependOn(&run_realworld_diff_jit.step);
    test_all_step.dependOn(&run_wast_2_0.step);
    // §10 / 10.T-2b: wasm-3.0 assertion runner skeleton — enumerates
    // baked manifests, exits clean. Adopts JIT-execute as impl rows
    // 10.M / 10.R / 10.TC / 10.E / 10.G land.
    test_all_step.dependOn(&run_wasm_3_0_assert.step);
    // The wasm-3.0 runner's embedded unit tests (§1 JIT-corpus
    // eligibility + manifest parse) were wired only into `test` — so
    // the per-chunk gate (`mac_gate.sh` → test-all) never ran them and
    // a stale `jitReturnEligible` assertion passed unnoticed (D-228).
    // Aggregate them here so test-all covers the §1 corpus logic.
    test_all_step.dependOn(&run_wasm_3_0_assert_unit.step);
    test_all_step.dependOn(&run_wasm_3_0_manifest_unit.step);
    test_all_step.dependOn(&run_wasmtime_misc_basic.step);
    test_all_step.dependOn(&run_wast_runtime_smoke.step);
    test_all_step.dependOn(&run_c_host.step);
    test_all_step.dependOn(conformance_step); // §13.4 C-API conformance
    test_all_step.dependOn(&run_zig_host.step); // §13.5 zig_host example
    test_all_step.dependOn(&run_zig_host_jit.step); // ADR-0200 JIT zig_host mini-consumer
    test_all_step.dependOn(&run_fuzz.step); // §14.3 / D-256 fuzz smoke (seed corpus)
    test_all_step.dependOn(&run_fuzz_exec.step); // D-469 interp-vs-JIT exec differential (exec_seed; toolchain-free, 3-host)
    test_all_step.dependOn(&run_aot_diff.step); // AOT campaign Phase II cross-process .wasm-vs-.cwasm differential (toolchain-free, 3-host)
    test_all_step.dependOn(&run_wasi_p1.step);
    // §9.7 / 7.8 row close (D-045 chunks 1-14 fully discharged):
    // wire test-spec-assert into test-all on ALL hosts. Three-host
    // exit-criterion measurement at row close:
    //   Mac aarch64       : 212 passed, 0 failed, 20 skipped
    //   Linux x86_64      : 212 passed, 0 failed, 20 skipped
    //   Windows x86_64    : 212 passed, 0 failed, 20 skipped
    // skip-adr-text-format = 20, skip-impl = 0 per ADR-0029.
    test_all_step.dependOn(&run_spec_assert.step);
    // §9.9 / 9.9-h-13 (post-D-078 (c) close): wire `test-spec-simd`
    // into `test-all` on ALL hosts. Both Mac aarch64 + the
    // Linux x86_64 lane are now at 0 FAIL on the SIMD spec corpus
    // (11270/0 each post-§9.9-h-12), so this aggregation no
    // longer breaks the gate. Preventive — surfaces silent
    // x86_64 SIMD regressions in the autonomous `/continue` loop
    // (per `LOOP.md` "Parallel test gate" 2-host subset).
    // the Windows reconciliation runs at phase boundary
    // separately per ADR-0049.
    test_all_step.dependOn(&run_simd_assert.step);
    // §9.9 / 9.9-l-1b (per ADR-0057): wire the new
    // non-SIMD wasm-2.0 scalar assertion runner. The curated
    // corpus lands in a follow-up (k-1); the runner gracefully
    // reports "0 manifests" against the missing directory so this
    // dependOn doesn't break test-all on a clean checkout.
    test_all_step.dependOn(&run_non_simd_assert.step);
    test_all_step.dependOn(&run_threads_assert.step); // §17.4 D-301 atomics corpus
    test_all_step.dependOn(&run_comp_spec_assert.step); // E1 Component Model spec corpus (ADR-0170)
    test_all_step.dependOn(&run_p3_tests.step); // ADR-0193 P3 — async unit tests under forced -Dwasi=p3
    // ADR-0174 win-harden-I: assert the resource runners FAIL on a missing
    // corpus root (no silent "0 manifests" skip) on EVERY host incl. the Windows host.
    test_all_step.dependOn(&run_simd_absent.step);
    test_all_step.dependOn(&run_non_simd_absent.step);
    test_all_step.dependOn(&run_wasm_3_0_absent.step);
    // §9.9 / 9.9-j-2 (per ADR-0056 §9.9 scope extension): wire two
    // runners that were "documented exit criterion measurement
    // points" but never CI-gated.
    //
    // test-realworld-run-jit compiles every fixture through the JIT
    // pipeline. Its RUN-PASS stage — and the 40+ RUN-PASS floor that
    // was §9.7 / 7.9-a's exit criterion — is GONE: it invoked `_start`
    // with a null WASI host, so its traps measured the harness, not
    // the JIT. `test-realworld-diff-jit` carries the execution side
    // now (D-283).
    //
    // test-wasmtime-misc-runtime (today 266/0/0 with panics
    // resolved) is the only runtime-asserting runner for non-SIMD
    // wasm-2.0 features — ADR-0056's discovery #1 ("non-SIMD spec
    // coverage is fake green") surfaces it as the bridge until
    // 9.9-l-1 lands the non-SIMD spec_assert_runner. The block at
    // line 333-343 above (NOT in test-all) is now historical; the
    // panic gap referenced there has closed.
    //
    // §9.9 / 9.9-m-5 (per ADR-0056): test-edge-cases wired into
    // test-all on all hosts. D-087 (x86_64 trunc trap), D-088
    // (x86_64 div_s/rem_s overflow trap), and D-089 (Linux
    // ld.so dl-fini assertion) all discharged together by
    // extending the `uses_runtime_ptr` whitelist (emit.zig) to
    // include div / rem / trunc_trap ops — these emit trap-stub
    // fixups that write `[r15 + trap_flag_off]`, which requires
    // R15 to hold the runtime ptr. Without R15 initialised, the
    // trap store hits a garbage address; trap_flag stays 0 (runner
    // sees value-return instead of trap) AND adjacent memory
    // corruption manifests as the dl-fini assertion at process
    // exit. Single-cause cohort: 8 fixtures pass + assertion gone.
    // Mac 35/0 + Linux x86_64 35/0 post-fix.
    test_all_step.dependOn(&run_edge_p7.step);
    test_all_step.dependOn(&run_edge_p9.step);
    test_all_step.dependOn(&run_edge_p10.step);
    test_all_step.dependOn(&run_edge_p17.step);
    test_all_step.dependOn(&run_edge_realworld_p10.step);
    test_all_step.dependOn(&run_realworld_run_jit.step);
    test_all_step.dependOn(&run_wasmtime_misc_runtime.step);
    test_all_step.dependOn(&run_zig_facade.step);

    // `zig build lint` — the zlinter rule chain, which lives in
    // `tools/lint/build.zig` with its own manifest so that this package
    // depends on nothing (ADR-0214). A top-level `@import("zlinter")` here
    // would make the lint tool a hard prerequisite of every step, including
    // `static-lib`, which C and Rust consumers build (#235). Mac-host gate;
    // not part of test-all. Run with `--max-warnings 0` for strict CI
    // semantics — extra args reach the linter through `b.args`.
    //
    // Re-measured on zig 0.16.0 + the pinned zlinter 2026-08-22, reversing
    // D-274: `.lazy = true` alone still cannot fix it (an unfetched lazy dep
    // makes the comptime `@import` fail with "no module named 'zlinter'"),
    // and `builder()` is still unreachable via `b.lazyDependency` —
    // `std.Build.Dependency` exposes only artifact/module/path. What D-274
    // missed is that the import does not have to be in THIS build file.
    const lint_step = b.step("lint", "Lint source code (zlinter).");
    const lint_run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "--build-file",
        b.pathFromRoot("tools/lint/build.zig"),
        "lint",
    });
    // zlinter spawns the linter with the sub-build's root as its cwd but
    // names the binary by a path relative to the invoking cwd, so the two
    // have to agree.
    lint_run.setCwd(b.path("tools/lint"));
    // `--` so the sub-build hands them to zlinter instead of parsing them
    // itself, keeping `zig build lint -- --max-warnings 0` working.
    if (b.args) |args| {
        lint_run.addArg("--");
        lint_run.addArgs(args);
    }
    lint_run.stdio = .inherit;
    lint_step.dependOn(&lint_run.step);
}

pub const WasmLevel = enum { v1_0, v2_0, v3_0 };
pub const WasiLevel = enum { none, p1, p2, p3 };
pub const EngineMode = enum { interp, jit, both };
pub const SanitizeMode = enum { off, address, thread };

/// Bundle of sanitizer settings derived from `-Dsanitize`.
/// Constructed once in `build()` and reused at each
/// `createSanitizedModule` call site (D-016 discharge).
pub const SanitizeOpts = struct {
    c: ?std.zig.SanitizeC,
    thread: ?bool,
};

/// Create a `*std.Build.Module` and apply the active sanitizer
/// settings in one call. Replaces the prior
/// `b.createModule + applySanitize` two-step pattern that
/// appeared at 17 call sites across this file.
///
/// Per ADR-0015 §Decision Part 2 / §9.6 / 6.K.7: `.full` enables
/// LLVM AddressSanitizer + UBSan; `sanitize_thread` enables
/// ThreadSanitizer. Mac aarch64 + Linux x86_64 only — on Windows
/// both fields are null and this is a pure `createModule`
/// passthrough.
fn createSanitizedModule(
    b: *std.Build,
    sopts: SanitizeOpts,
    mod_opts: std.Build.Module.CreateOptions,
) *std.Build.Module {
    const mod = b.createModule(mod_opts);
    applySanitize(mod, sopts);
    return mod;
}

/// Apply the ADR-0015 sanitize flags to an already-created module —
/// shared by `createSanitizedModule` (private modules) and the public
/// `b.addModule("zwasm", …)` consumable module (which must be registered
/// by name, not `createModule`, to be reachable via a path-dep's
/// `dependency("zwasm").module("zwasm")`).
fn applySanitize(mod: *std.Build.Module, sopts: SanitizeOpts) void {
    if (sopts.c) |s| mod.sanitize_c = s;
    if (sopts.thread) |t| mod.sanitize_thread = t;
}
