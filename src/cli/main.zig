// TEST-DISCOVERY-EXEMPT: tested as its own root module by build.zig's cli_tests (exe_mod addTest) — outside the core_p3 listing that check_test_discovery.sh compares against.
//! `zwasm` CLI exe entry.
//!
//! Per ADR-0024 D-4: lives at `src/cli/main.zig` (not at the
//! top-level `src/main.zig`) so that the static-library root
//! `src/zwasm.zig` does not pull in `pub fn main` — that would
//! duplicate-define `_main` against C-host examples linking
//! against `libzwasm.a`.
//!
//! The `core` module (rooted at `src/zwasm.zig`) is injected via
//! build.zig as a named import (`addImport("zwasm", core)`); the
//! library symbols are reached as `zwasm.<zone>.<symbol>`.
//!
//! Subcommands:
//!   (none)                    Print version + build options.
//!   run <path.wasm>           Drive a WASI module's `_start` / `main`
//!                             export; exit with the guest's
//!                             `proc_exit` code.
//!   run --invoke <name>       Invoke the named func export (zero-args)
//!   run --engine <auto|interp|jit> Engine: default auto, prefers JIT
//!                             with interp fallback; interp|jit force one — BOTH do full
//!                             WASI (D-244); jit additionally executes SIMD
//!                             (the interp does not). `--engine=jit` accepted.
//!     <path.wasm>             instead of the default `_start` / `main`
//!                             selection. Typed `--invoke NAME=a,b,...`
//!                             arg marshalling + result printing are
//!                             handled in `cli/invoke_args.zig` (D-273).
//!   compile <path.wasm>       Produce a `.cwasm` v0.5 full-fidelity artifact
//!     -o <out.cwasm>          (per ADR-0203). Generator side; `run
//!                             <file.cwasm>` loads + executes it.
//!
//! The surface is `run` + `compile` only (ADR-0159, §16.4): the
//! wasmtime/wazero-aligned first-principles shape for a runtime. Validation
//! is programmatic (C-API `wasm_module_validate` / Zig `Engine.compile`);
//! introspection + wat↔wasm conversion are `wasm-tools` / `wabt`'s job —
//! zwasm deliberately does NOT ship `validate`/`inspect`/`features`/
//! `wat`/`wasm` subcommands.

const std = @import("std");
const build_options = @import("build_options");
const zwasm = @import("zwasm");

const cli_run = zwasm.cli.run;
const cli_cache = zwasm.cli.cache;
const cli_compile = zwasm.cli.compile;
const cli_dispatch = zwasm.cli.dispatch;
const diag_print = zwasm.cli.diag_print;
const diagnostic = zwasm.diagnostic;
const dbg = zwasm.support.dbg;

pub fn main(init: std.process.Init) !void {
    // ADR-0166 (D-292 B-core): install the diagnostic-only internal-fault
    // handler FIRST, so any later internal SIGSEGV/crash surfaces a distinct
    // "internal error" + exit 70 instead of a silent signal-death. v2 has no
    // signal-based wasm traps, so any fatal signal here is a zwasm bug.
    zwasm.platform.signal.installInternalFaultHandler();

    const io = init.io;
    const gpa = init.gpa;

    // D-009 refactor: Zone 0 dbg.zig has no env-read capability;
    // plumb `ZWASM_DEBUG` down from Zone 3 here. `Map.get`
    // returns null when the var is unset → dbg becomes a no-op.
    dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));

    // §9.8a / 8a.4 — `ZWASM_DIAG` runtime opt-in for the trace
    // ringbuffer drain + future bench/jit_exec channels. Pre-init
    // and `-Dtrace-ringbuffer=false` builds make this a no-op.
    diagnostic.trace.initFromEnv(init.environ_map.get("ZWASM_DIAG"));
    defer diagnostic.trace.drainPassesToStderr();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?; // executable name
    const subcmd_opt = arg_it.next();

    // ADR-0166 hidden test affordance (D-292 B-core): deliberately trigger an
    // internal fault so the handler installed above is exercised end-to-end (→
    // "internal error" line + exit 70). Used by the `test-internal-fault` build
    // step to verify the handler on each host. Not advertised in `--help`.
    if (subcmd_opt) |sc| {
        if (std.mem.eql(u8, sc, "--__selftest-crash")) {
            const p: *allowzero volatile u8 = @ptrFromInt(0);
            p.* = 0;
            unreachable; // the fault handler exits(70) before control returns here
        }
    }

    // Top-level verb routing (ADR-0159). help/version/unknown resolve
    // here; run/compile/banner fall through to the logic below (each
    // keeps its own arg parsing). An unrecognised first token is a
    // typo, not an implicit file-run — the surface is explicit.
    switch (cli_dispatch.classify(subcmd_opt)) {
        .help => {
            try printOut(io, cli_dispatch.usage);
            std.process.exit(0);
        },
        .version => {
            var buf: [192]u8 = undefined;
            const line = cli_dispatch.versionLine(&buf, zwasm.version, @tagName(build_options.wasm_level), @tagName(build_options.wasi_level), @tagName(build_options.engine_mode));
            try printOut(io, line);
            std.process.exit(0);
        },
        .unknown => {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zwasm: unknown subcommand '{s}' — run 'zwasm --help' for usage", .{subcmd_opt.?}) catch "zwasm: unknown subcommand";
            try printlnErr(io, msg);
            std.process.exit(2);
        },
        .banner, .run, .compile => {},
    }

    if (subcmd_opt) |subcmd| {
        if (std.mem.eql(u8, subcmd, "run")) {
            // Parse `--invoke <name>` ahead of the positional path. The
            // flag must precede the path so the trailing argv (= WASI
            // guest argv) is unambiguous.
            var invoke_name: ?[]const u8 = null;
            // D-273(1) — `--invoke NAME=ARGS`: the `=ARGS` tail (comma-
            // separated, parsed by the export's param types) is split off the
            // single token so the trailing WASI argv stays unambiguous. Null =
            // the zero-arg entry form (`--invoke NAME`).
            var invoke_args: ?[]const u8 = null;
            // ADR-0136 — `--engine=jit` routes the run through the JIT executor
            // (full WASI via D-244 + SIMD). Default = interp (the C-API path).
            var engine_jit = false;
            var preopen_list: std.ArrayList(cli_run.PreopenDir) = .empty;
            defer preopen_list.deinit(gpa);
            // D-295 P0 — `--env KEY=VAL`: WASI environ injected into the guest
            // via the host's setEnvs (parallel keys/vals slices).
            var env_keys: std.ArrayList([]const u8) = .empty;
            defer env_keys.deinit(gpa);
            var env_vals: std.ArrayList([]const u8) = .empty;
            defer env_vals.deinit(gpa);
            // ADR-0179 #3a-4 / D-314 — `--fuel` / `--timeout` / `--max-memory`.
            var limits: cli_run.Limits = .{};
            var cache_enabled = false;
            var cache_clear = false;
            var cache_dir_arg: ?[]const u8 = null;
            var next_arg = arg_it.next();
            while (next_arg) |a| {
                if (std.mem.eql(u8, a, "--invoke")) {
                    const spec = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --invoke <name>[=arg1,arg2,...] <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    if (std.mem.findScalar(u8, spec, '=')) |eq| {
                        invoke_name = spec[0..eq];
                        invoke_args = spec[eq + 1 ..];
                    } else {
                        invoke_name = spec;
                    }
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--engine") or std.mem.startsWith(u8, a, "--engine=")) {
                    // Accept both `--engine jit` and `--engine=jit`.
                    const eq = "--engine=";
                    const mode = if (std.mem.startsWith(u8, a, eq))
                        a[eq.len..]
                    else
                        arg_it.next() orelse {
                            try printlnErr(io, "usage: zwasm run --engine <auto|interp|jit> <path.wasm> [args...]");
                            std.process.exit(2);
                        };
                    if (std.mem.eql(u8, mode, "auto")) {
                        // Explicit spelling of the default: JIT-preferring
                        // with interp fallback (last flag wins).
                        engine_jit = false;
                        limits.engine = .auto;
                    } else if (std.mem.eql(u8, mode, "jit")) {
                        engine_jit = true;
                        // Last flag wins: undo a preceding `--engine interp`'s
                        // sticky force (read by the cache + .cwasm gates).
                        limits.engine = .auto;
                    } else if (std.mem.eql(u8, mode, "interp")) {
                        engine_jit = false;
                        // D-496 `.auto`→JIT flip: the default captured path now prefers
                        // JIT, so an EXPLICIT `--engine interp` must force interp.
                        limits.engine = .interp;
                    } else {
                        try printlnErr(io, "zwasm run: --engine must be 'auto', 'interp' or 'jit'");
                        std.process.exit(2);
                    }
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--dir")) {
                    // `--dir <host>[:<guest>]` — preopen a host dir for the
                    // guest. Without a colon the guest path mirrors the host.
                    const spec = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --dir <host>[:<guest>] <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    const colon = std.mem.findScalar(u8, spec, ':');
                    const host_path = if (colon) |c| spec[0..c] else spec;
                    const guest_path = if (colon) |c| spec[c + 1 ..] else spec;
                    try preopen_list.append(gpa, .{ .host_path = host_path, .guest_path = guest_path });
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--env")) {
                    // `--env KEY=VAL` — inject a WASI environment variable. A
                    // bare `--env KEY` (no '=') sets an empty value, matching
                    // wasmtime's permissive parse.
                    const spec = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --env KEY=VAL <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    if (std.mem.findScalar(u8, spec, '=')) |eq| {
                        try env_keys.append(gpa, spec[0..eq]);
                        try env_vals.append(gpa, spec[eq + 1 ..]);
                    } else {
                        try env_keys.append(gpa, spec);
                        try env_vals.append(gpa, spec[spec.len..]);
                    }
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--fuel")) {
                    const v = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --fuel <N> <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    limits.fuel = std.fmt.parseInt(u64, v, 10) catch {
                        try printlnErr(io, "zwasm run: --fuel expects a non-negative integer");
                        std.process.exit(2);
                    };
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--timeout")) {
                    const v = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --timeout <ms> <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    limits.timeout_ms = std.fmt.parseInt(u64, v, 10) catch {
                        try printlnErr(io, "zwasm run: --timeout expects milliseconds as a non-negative integer");
                        std.process.exit(2);
                    };
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--max-memory")) {
                    const v = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --max-memory <bytes> <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    limits.max_memory_bytes = std.fmt.parseInt(u64, v, 10) catch {
                        try printlnErr(io, "zwasm run: --max-memory expects bytes as a non-negative integer");
                        std.process.exit(2);
                    };
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--max-table-elements")) {
                    const v = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --max-table-elements <N> <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    limits.max_table_elements = std.fmt.parseInt(u64, v, 10) catch {
                        try printlnErr(io, "zwasm run: --max-table-elements expects a non-negative integer");
                        std.process.exit(2);
                    };
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--cache") or std.mem.startsWith(u8, a, "--cache=")) {
                    // ADR-0203 D5 / D-508 — transparent compilation cache.
                    // `--cache` uses the platform default root; `--cache=DIR`
                    // overrides it.
                    cache_enabled = true;
                    if (std.mem.startsWith(u8, a, "--cache=")) cache_dir_arg = a["--cache=".len..];
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--cache-clear")) {
                    // Clear-only: caching this run still requires `--cache`
                    // (least surprise — "clear" must not imply "populate").
                    cache_clear = true;
                    next_arg = arg_it.next();
                } else break;
            }
            const path_arg = next_arg orelse {
                try printlnErr(io, "usage: zwasm run [--invoke <name>] [--engine <auto|interp|jit>] [--dir <host>[:<guest>]] [--env KEY=VAL] [--fuel <N>] [--timeout <ms>] [--max-memory <bytes>] [--max-table-elements <N>] [--cache[=DIR]] [--cache-clear] <path.wasm> [args...]");
                std.process.exit(2);
            };
            const path = try gpa.dupe(u8, path_arg);
            defer gpa.free(path);

            const cwd = std.Io.Dir.cwd();
            const bytes = cwd.readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "zwasm run: cannot read '{s}': {s}", .{ path, @errorName(err) }) catch "zwasm run: read failed";
                try printlnErr(io, msg);
                std.process.exit(1);
            };
            defer gpa.free(bytes);

            // ADR-0203 D5 / D-508 — transparent compilation cache. Only a
            // plain core module routes through the cache (an explicit
            // `.cwasm` input IS the artifact; components have no artifact
            // format), and an explicit `--engine interp` bypasses it (the
            // artifact is JIT code — the flag must keep forcing interp,
            // D-496). On a hit the cached artifact replaces `bytes` and the
            // CWAS branch below runs it through the full-fidelity load path
            // — the same flow a miss's freshly-produced artifact takes.
            var cache_bytes: ?[]u8 = null;
            defer if (cache_bytes) |cb| gpa.free(cb);
            if (cache_enabled or cache_clear) {
                const root = cache_dir_arg orelse defaultCacheRoot(gpa, init) orelse {
                    try printlnErr(io, "zwasm run: --cache/--cache-clear could not resolve a cache directory (set HOME/XDG_CACHE_HOME/LOCALAPPDATA or pass --cache=DIR)");
                    std.process.exit(2);
                };
                defer if (cache_dir_arg == null) gpa.free(@constCast(root));
                if (cache_clear) try cli_cache.clear(gpa, io, root);
                const is_core_module = bytes.len >= 8 and
                    std.mem.eql(u8, bytes[0..4], "\x00asm") and bytes[6] != 0x01;
                if (cache_enabled and is_core_module and limits.engine != .interp) {
                    // A compile/produce refusal (module the AOT producer
                    // can't serialize, ZWASM_DEBUG instrumentation, genuine
                    // module error) falls through to the normal dispatch —
                    // keeping `.auto`'s interp fallback and its diagnostics.
                    // EXEMPT-FALLBACK: cache-path failure = BYPASS, never a failed run (ADR-0203 D5).
                    cache_bytes = cli_cache.lookupOrProduce(gpa, io, root, bytes) catch null;
                }
            }
            const run_bytes: []const u8 = cache_bytes orelse bytes;

            // Build argv for the WASI guest. Wasmtime's default is
            // argv[0] = wasm filename + any trailing args; mirror
            // that here so guests that print argv produce parity
            // bytes. Both the `.cwasm` and `.wasm` paths consume it.
            var argv_list: std.ArrayList([]const u8) = .empty;
            defer argv_list.deinit(gpa);
            try argv_list.append(gpa, path);
            while (arg_it.next()) |a| try argv_list.append(gpa, a);

            // The guest's fd 0, decided ONCE for every run path below (.cwasm /
            // component / core interp / core JIT, #257): a piped or redirected
            // stdin is read up front into the host's stdin source; a TTY stays
            // EOF because the host serves reads from a byte slice and has no
            // interactive streaming stdin.
            var stdin_pipe: ?[]u8 = null;
            defer if (stdin_pipe) |s| gpa.free(s);
            const stdin_file = std.Io.File.stdin();
            const stdin_is_tty = stdin_file.isTty(io) catch true;
            if (!stdin_is_tty) {
                var rd_buf: [4096]u8 = undefined;
                var rd = stdin_file.reader(io, &rd_buf);
                stdin_pipe = rd.interface.allocRemaining(gpa, .limited(64 * 1024 * 1024)) catch null;
            }

            // ADR-0203 stage 3 — a pre-compiled AOT artefact (CWAS magic)
            // runs through the SAME full-runtime JIT path as a `.wasm`:
            // the engine deserializes the artifact and executes it with
            // identical WASI / sandbox-limit / `--invoke NAME=ARGS` /
            // start-function behaviour (cache-hit == cache-miss). The
            // pre-stage-3 refusals (limits, typed invoke args) are gone —
            // both are wired through the shared path now.
            if (run_bytes.len >= 4 and std.mem.eql(u8, run_bytes[0..4], "CWAS")) {
                // D-496 spirit: an explicit `--engine interp` cannot be
                // honoured for a precompiled JIT artifact — refuse loudly
                // rather than silently running the JIT. (The cache path
                // never reaches here under interp; it bypasses above.)
                if (limits.engine == .interp) {
                    try printlnErr(io, "zwasm run: --engine interp cannot run a .cwasm artifact (precompiled JIT code); run the original .wasm instead");
                    std.process.exit(2);
                }
                const code = cli_run.runWasmJitCaptured(gpa, io, run_bytes, invoke_name, argv_list.items, preopen_list.items, env_keys.items, env_vals.items, limits, null, invoke_args, stdin_pipe) catch |err| {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "zwasm run: cannot run '{s}': {s}", .{ path, @errorName(err) }) catch "zwasm run: .cwasm run failed";
                    try printlnErr(io, msg);
                    std.process.exit(1);
                };
                std.process.exit(code);
            }

            // CM campaign D1-2 / D-306 — a component-layer module (preamble
            // version 0x0d, layer byte = 0x01) routes to the component host
            // (`runWasiP2Main`), not the core-module runner. stdio subset.
            if (run_bytes.len >= 8 and std.mem.eql(u8, run_bytes[0..4], "\x00asm") and run_bytes[6] == 0x01) {
                if (comptime !@import("build_options").enable_component) {
                    try printlnErr(io, "zwasm run: component support not compiled in (rebuild with -Dwasi=p2 or higher)");
                    std.process.exit(2);
                }
                // ADR-0179 #3a-4 — same loud refusal for the component host.
                if (limits.any()) {
                    try printlnErr(io, "zwasm run: --fuel/--timeout/--max-memory are not wired for components yet (core modules only)");
                    std.process.exit(2);
                }
                const code = cli_run.runComponentWasi(gpa, io, run_bytes, argv_list.items, preopen_list.items, env_keys.items, env_vals.items, stdin_pipe) catch |err| {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "zwasm run: cannot run component '{s}': {s}", .{ path, @errorName(err) }) catch "zwasm run: component run failed";
                    try printlnErr(io, msg);
                    std.process.exit(1);
                };
                std.process.exit(code);
            }

            // D-244 — `--engine=jit` now does real WASI (incl. `--dir` preopens).
            // D-477 — typed `--invoke NAME=ARGS` now also runs on the JIT engine
            // (marshalled through the generalized buffer-write thunk).
            const code = (if (engine_jit)
                cli_run.runWasmJitCaptured(gpa, io, run_bytes, invoke_name, argv_list.items, preopen_list.items, env_keys.items, env_vals.items, limits, null, invoke_args, stdin_pipe)
            else
                cli_run.runWasmCapturedFull(gpa, io, run_bytes, argv_list.items, null, null, stdin_pipe, invoke_name, preopen_list.items, env_keys.items, env_vals.items, invoke_args, limits)) catch |err| {
                // Per ADR-0016 phase 1: prefer the structured
                // diagnostic when one was set; fall back to the
                // legacy `@errorName` form for unwired sites.
                var stderr_buf: [1024]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
                const stderr = &stderr_writer.interface;
                const source: diag_print.Source = .{ .filename = path, .bytes = bytes };
                if (diagnostic.lastDiagnostic()) |diag| {
                    // EXEMPT-FALLBACK: ADR-0016 phase 1 — diagnostic render is last-resort stderr; re-entry on failure is meaningless.
                    diag_print.formatDiagnostic(diag, source, stderr) catch {};
                } else {
                    // EXEMPT-FALLBACK: ADR-0016 phase 1 — fallback render is last-resort stderr; re-entry on failure is meaningless.
                    diag_print.renderFallback(err, source, stderr) catch {};
                }
                // EXEMPT-FALLBACK: ADR-0016 phase 1 — flushing the same stderr that just rendered the diagnostic; failure here is unrecoverable.
                stderr.flush() catch {};
                std.process.exit(1);
            };
            std.process.exit(code);
        }
        if (std.mem.eql(u8, subcmd, "compile")) {
            const code = cli_compile.run(gpa, io, &arg_it) catch |err| {
                if (err == error.UsageError) {
                    // Usage errors exit 2 uniformly across subcommands.
                    // EXEMPT-FALLBACK: ADR-0016 phase 1 — usage-line stderr report is last-resort; the process exits 2 regardless.
                    printlnErr(io, "usage: zwasm compile <file.wasm> -o <out.cwasm>") catch {};
                    std.process.exit(2);
                }
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "zwasm compile: {s}", .{@errorName(err)}) catch "zwasm compile: failed";
                // EXEMPT-FALLBACK: ADR-0016 phase 1 — compile-error stderr report is last-resort; the process exits 1 regardless.
                printlnErr(io, msg) catch {};
                std.process.exit(1);
            };
            std.process.exit(code);
        }
    }

    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("zwasm v{s}\n", .{zwasm.version});
    try stdout.print(
        "  wasm-level: {s}, wasi-level: {s}, engine: {s}\n",
        .{
            @tagName(build_options.wasm_level),
            @tagName(build_options.wasi_level),
            @tagName(build_options.engine_mode),
        },
    );
    try stdout.flush();
}

/// Platform default cache root for `--cache` (ADR-0203 D5): the user
/// cache directory + "/zwasm". Resolved from the environment the same way
/// wasmtime/wazero do; null when no suitable variable is set (the caller
/// surfaces a usage error suggesting `--cache=DIR`). Caller frees.
fn defaultCacheRoot(gpa: std.mem.Allocator, init: std.process.Init) ?[]const u8 {
    const builtin = @import("builtin");
    switch (builtin.target.os.tag) {
        .windows => {
            const base = init.environ_map.get("LOCALAPPDATA") orelse return null;
            return std.fmt.allocPrint(gpa, "{s}\\zwasm", .{base}) catch null;
        },
        .macos => {
            const home = init.environ_map.get("HOME") orelse return null;
            return std.fmt.allocPrint(gpa, "{s}/Library/Caches/zwasm", .{home}) catch null;
        },
        else => {
            if (init.environ_map.get("XDG_CACHE_HOME")) |x| {
                return std.fmt.allocPrint(gpa, "{s}/zwasm", .{x}) catch null;
            }
            const home = init.environ_map.get("HOME") orelse return null;
            return std.fmt.allocPrint(gpa, "{s}/.cache/zwasm", .{home}) catch null;
        },
    }
}

fn printlnErr(io: std.Io, msg: []const u8) !void {
    var stderr_buf: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.print("{s}\n", .{msg});
    try stderr.flush();
}

/// Write `msg` to stdout verbatim (no trailing newline added — callers
/// pass text that already terminates). Used by --help / --version.
fn printOut(io: std.Io, msg: []const u8) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}", .{msg});
    try stdout.flush();
}

test "version is non-empty" {
    try std.testing.expect(zwasm.version.len > 0);
}

test "build options are wired" {
    _ = build_options.wasm_level;
    _ = build_options.wasi_level;
    _ = build_options.engine_mode;
}
