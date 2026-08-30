// FILE-SIZE-EXEMPT: 50% in-file CLI e2e tests (P4-alone insufficient); the impl half is one cohesive run driver (investigated 2026-08-12, per ADR-0099)
//! `zwasm run` CLI helper (Phase 4 / §9.4 / 4.8 chunk a).
//!
//! Houses `runWasm` — the Zig-callable entry that drives a
//! WASI-importing module from in-memory bytes through to a
//! u8 exit code. The CLI argv-parsing wrapper lives in
//! `src/main.zig` and lands alongside §9.4 / 4.8 chunk b.
//!
//! Zone 3 — may import `c_api/`. CLI is conventionally where
//! the binding's exported surface gets driven from Zig
//! (functions are declared `export fn` for C linkage but
//! remain ordinary Zig functions, callable here).
//!
//! Exit-code mapping:
//!   - guest returns normally     → 0
//!   - guest calls `proc_exit(N)` → N
//!   - guest traps (other)        → 1

const std = @import("std");

const wasm_c_api = @import("../api/wasm.zig");
const trap_surface = @import("../api/trap_surface.zig");
const diagnostic = @import("../diagnostic/diagnostic.zig");
const wasi_host = @import("../wasi/host.zig");
const invoke_args_mod = @import("invoke_args.zig");
const export_lookup = @import("../engine/export_lookup.zig");
const dbg = @import("../support/dbg.zig");
const call_profile = @import("../support/call_profile.zig");

/// ADR-0179 #3a-4 / D-314 / D-332 — `zwasm run` sandboxing flags (`--fuel` /
/// `--timeout` / `--max-memory` / `--max-table-elements`). All optional;
/// `.{}` = unlimited. Fuel
/// UNITS are engine-specific by design (interp = instructions, JIT =
/// poll-site crossings — ADR-0179 rev 2026-06-12); --help says so.
pub const Limits = struct {
    fuel: ?u64 = null,
    max_memory_bytes: ?u64 = null,
    /// D-332 — host cap on a module's declared initial table elements
    /// (`--max-table-elements`); completes the JIT sandbox triad.
    max_table_elements: ?u64 = null,
    timeout_ms: ?u64 = null,
    /// D-349 (found from cljw) — cap on each capture buffer. `null` = unbounded.
    /// The other axes bound the guest's COMPUTE; this one bounds the host memory
    /// the guest can make the runner hold, which nothing else does: fuel bounds
    /// instructions and bytes-per-instruction is the guest's choice. Only
    /// meaningful on a captured run; ignored when output goes to real stdio.
    max_output_bytes: ?u64 = null,
    /// D-496 — engine for the C-API captured-run path. `.auto` (default) =
    /// JIT-preferring with interp fallback (the `.auto`→JIT flip); `.interp`
    /// forces interp (CLI `--engine interp`). `--engine jit` uses the dedicated
    /// `runWasmJitCaptured` path, not this field.
    engine: @import("../api/instance.zig").EngineKind = .auto,

    pub fn any(self: Limits) bool {
        return self.fuel != null or self.max_memory_bytes != null or self.max_table_elements != null or self.timeout_ms != null or self.max_output_bytes != null;
    }
};

/// `--timeout` timer body: sleeps on the io event loop (`.awake` = the
/// monotonic clock WASI also uses), then raises the cooperative-interruption
/// flag both engines poll. Canceled (guest finished first) → returns without
/// raising.
fn timeoutRaiser(io: std.Io, ms: u64, flag: *std.atomic.Value(u32)) void {
    io.sleep(.{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms }, .awake) catch return;
    flag.store(1, .monotonic);
}

/// Interp default page size; the interp's `store_memory_pages_max` is in
/// pages. (The JIT path converts with the module's actual page size —
/// `RunLimits.max_memory_bytes` stays in bytes for that reason.)
const wasm_page_bytes: u64 = 64 * 1024;

pub fn runWasm(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    argv: []const []const u8,
) !u8 {
    return runWasmCaptured(alloc, io, bytes, argv, null, null);
}

/// `zwasm run --engine=jit` (ADR-0136): JIT-compile `bytes` and run the
/// entry export (`invoke_name`, else `_start`) to completion. **D-244**: now
/// attaches a WASI host (`io` + `argv`) so the JIT does REAL WASI — clock /
/// random / fd_write→stdout / fd_read→stdin (the `stdin_bytes` handed to
/// `runWasmJitCaptured`; this wrapper hands none, so fd 0 reads EOF) / args /
/// environ route through the shared interp handlers (`jit_dispatch.zig`), and `proc_exit(N)` surfaces as
/// the exit code, `argv` + `--dir` preopens are threaded in, and the full 46
/// preview1 syscalls resolve (`jit_dispatch.zig`). A compute-only module simply
/// ignores the host. Returns 0 on a clean exit; a genuine trap propagates (the
/// caller maps it to exit 1).
pub fn runWasmJit(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    invoke_name: ?[]const u8,
    argv: []const []const u8,
    preopens: []const PreopenDir,
    env_keys: []const []const u8,
    env_vals: []const []const u8,
    limits: Limits,
) !u8 {
    return runWasmJitCaptured(alloc, io, bytes, invoke_name, argv, preopens, env_keys, env_vals, limits, null, null, .none);
}

/// Like `runWasmJit` but routes guest stdout (`fd_write` on fd 1) into
/// `stdout_capture` when non-null. `null` → real process stdout (the CLI
/// path). The realworld `--jit` differential lane (D-283) passes a buffer to
/// byte-diff `--engine jit` output vs wasmtime — the realworld JIT-correctness
/// net. What distinguishes it from the other two realworld result-checks in
/// `test-all` is its oracle, an independent runtime: `run_edge_realworld_p10`
/// checks 8 fixtures against static `.expect` values, and `run_aot_diff`
/// compares zwasm against itself across the `.cwasm` boundary.
pub fn runWasmJitCaptured(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    invoke_name: ?[]const u8,
    argv: []const []const u8,
    preopens: []const PreopenDir,
    env_keys: []const []const u8,
    env_vals: []const []const u8,
    limits: Limits,
    stdout_capture: ?*std.ArrayList(u8),
    invoke_args: ?[]const u8,
    stdin: StdinSource,
) !u8 {
    const runner = @import("../engine/runner.zig");
    // ADR-0203 stage 3 — a `.cwasm` artifact runs through the SAME flow as a
    // `.wasm` (runWasiLenientArgs branches to the full-fidelity deserializer
    // on the CWAS magic). Export-TYPE lookups (arg packing / multi-result
    // sizing) read module metadata through the artifact's embedded original
    // bytes so `--invoke` behaves byte-identically to the source `.wasm`.
    const wasm_view: []const u8 = if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "CWAS"))
        try @import("../engine/codegen/aot/load_compiled.zig").embeddedWasmBytes(bytes)
    else
        bytes;
    if (dbg.on("jit.callcount")) call_profile.reset();
    defer if (dbg.on("jit.callcount")) call_profile.dump();
    if (dbg.on("global.trace")) call_profile.greset();
    defer if (dbg.on("global.trace")) call_profile.gdump();
    var host = try wasi_host.Host.init(alloc);
    defer host.deinit();
    host.io = io;
    if (stdout_capture) |b| host.stdout_buffer = b;
    stdin.applyTo(&host); // the guest's fd 0 source
    host.max_capture_bytes = limits.max_output_bytes;
    // ADR-0179 #3a-4 — `--timeout` arms a timer on the io event loop that
    // raises the interrupt flag the JIT polls (prologue + back-edges).
    // ConcurrencyUnavailable surfaces loudly (a silent no-timeout run would
    // be a sandbox hole, no_workaround).
    var timeout_flag = std.atomic.Value(u32).init(0);
    var timeout_fut: ?std.Io.Future(void) = null;
    if (limits.timeout_ms) |ms| {
        timeout_fut = try io.concurrent(timeoutRaiser, .{ io, ms, &timeout_flag });
    }
    defer if (timeout_fut) |*f| f.cancel(io);
    if (argv.len > 0) try host.setArgs(argv);
    if (env_keys.len > 0) try host.setEnvs(env_keys, env_vals); // D-295 P0: --env KEY=VAL
    // D-244: map `--dir` host directories into the guest's preopen table so the
    // JIT's path_open / fd_readdir / fd_filestat_get resolve against them (the
    // fds live for the process lifetime, CLI-scoped, like the interp path).
    for (preopens) |pd| {
        const dir = try std.Io.Dir.cwd().openDir(io, pd.host_path, .{ .iterate = true });
        _ = try host.addPreopen(dir.handle, pd.guest_path);
    }
    // D-244 chunk 2d: `proc_exit(N)` records `host.exit_code` then unwinds via
    // the JIT trap mechanism (returns Error.Trap). Surface the guest's exit
    // code; a trap with NO exit_code is a genuine fault → propagate (exit 1).
    var trap_code: u32 = 0;
    var scalar_result: ?runner.ScalarResult = null;
    // D-477: typed `--invoke NAME=ARGS` on the JIT engine — parse the args by
    // the export's param sig and thread them through the buffer-write entry.
    // `null` invoke_args (or a bare `--invoke NAME`) → empty slice = zero-arg.
    const packed_args: []const u64 = if (invoke_args) |astr| blk: {
        break :blk try packJitInvokeArgs(alloc, wasm_view, invoke_name.?, astr);
    } else &.{};
    defer if (packed_args.len > 0) alloc.free(@constCast(packed_args));
    // D-477 multi-result: a `--invoke` of an export with ≥2 results fills
    // `multi_out` (TypedResult[]); each value is printed on its own line, like
    // the interp path (`invoke_args.invokeFormatted`) + wasmtime.
    var multi_buf: [16]runner.TypedResult = undefined;
    var multi_out: ?[]runner.TypedResult = null;
    if (invoke_name) |name| {
        if (export_lookup.getExportFuncType(alloc, wasm_view, name)) |ft| {
            defer {
                alloc.free(ft.params);
                alloc.free(ft.results);
            }
            if (ft.results.len >= 2 and ft.results.len <= multi_buf.len) multi_out = multi_buf[0..ft.results.len];
        } else |_| {
            // Bad/missing export → leave multi_out null; runWasiLenientArgs
            // surfaces the proper ExportNotFound/UnsupportedEntrySignature.
        }
    }
    _ = runner.runWasiLenientArgs(alloc, bytes, invoke_name, &host, &trap_code, .{
        .fuel = limits.fuel,
        .max_memory_bytes = limits.max_memory_bytes,
        .max_table_elements = limits.max_table_elements,
        .interrupt_flag = if (limits.timeout_ms != null) &timeout_flag else null,
    }, &scalar_result, packed_args, multi_out) catch |err| {
        if (host.exit_code) |code| return @intCast(@min(code, std.math.maxInt(u8)));
        // A genuine trap (no recorded exit_code) surfaces its kind on stderr
        // then maps to exit 1 — interp-parity per ADR-0164 workstream A. A
        // trap is exit≠0, NOT a Zig error: returning the code (not re-raising
        // error.Trap) keeps the single-message parity with the interp path;
        // main.zig's renderFallback is reserved for non-trap errors (compile/
        // validate/load).
        if (err == error.Trap) {
            // JIT traps unwind via siglongjmp, which skips the top-of-fn
            // `defer call_profile.dump()` — dump explicitly here so the
            // profiler works for trapping/crashing programs (D-494).
            if (dbg.on("jit.callcount")) call_profile.dump();
            if (dbg.on("global.trace")) call_profile.gdump();
            surfaceJitTrap(io, trap_code);
            return 1;
        }
        return err;
    };
    // A value-returning `--invoke <name>` surfaces its typed result on the
    // guest-stdout channel like the interp path + wasmtime (gated on an explicit
    // invoke — a `_start`/default entry stays exit-code-only). `void` exports
    // leave `scalar_result` null → nothing extra printed.
    if (invoke_name != null) {
        if (multi_out) |results| {
            // Multi-value result: one bare value per line, in order (interp parity).
            for (results) |tr| {
                var b: [80]u8 = undefined;
                const bare = try invoke_args_mod.formatScalar(b[0 .. b.len - 1], typedResultToVal(tr));
                b[bare.len] = '\n';
                try writeResultText(io, stdout_capture, alloc, b[0 .. bare.len + 1]);
            }
        } else if (scalar_result) |sr| {
            var b: [80]u8 = undefined;
            // v128 is outside the C-ABI `Val` set — render the 16 bytes as a
            // little-endian u128 decimal (matches wasmtime's `--invoke` output).
            const bare = if (sr == .v128)
                try std.fmt.bufPrint(b[0 .. b.len - 1], "{d}", .{@as(u128, @bitCast(sr.v128))})
            else
                try invoke_args_mod.formatScalar(b[0 .. b.len - 1], scalarToVal(sr));
            b[bare.len] = '\n';
            try writeResultText(io, stdout_capture, alloc, b[0 .. bare.len + 1]);
        }
    }
    if (host.exit_code) |code| return @intCast(@min(code, std.math.maxInt(u8)));
    return 0;
}

/// D-477 — parse `--invoke NAME=ARGS` into u64 carriers for the JIT buffer-write
/// entry, typed by the export's declared params (zir sig). i32/f32 occupy the
/// low 32 bits, i64/f64 the full 64 (the buffer-write ABI convention). Caller
/// frees the returned slice. ArgCountMismatch / InvalidArgValue / UnsupportedArgType
/// surface like the interp `--invoke` path.
fn packJitInvokeArgs(alloc: std.mem.Allocator, bytes: []const u8, name: []const u8, args_str: []const u8) ![]u64 {
    const ft = try export_lookup.getExportFuncType(alloc, bytes, name);
    defer {
        alloc.free(ft.params);
        alloc.free(ft.results);
    }
    const ntok: usize = if (args_str.len == 0) 0 else blk: {
        var c: usize = 1;
        for (args_str) |ch| {
            if (ch == ',') c += 1;
        }
        break :blk c;
    };
    if (ntok != ft.params.len) return invoke_args_mod.ArgError.ArgCountMismatch;
    const out = try alloc.alloc(u64, ft.params.len);
    errdefer alloc.free(out);
    if (ft.params.len == 0) return out;
    var it = std.mem.splitScalar(u8, args_str, ',');
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        const kind: wasm_c_api.ValKind = switch (ft.params[i]) {
            .i32 => .i32,
            .i64 => .i64,
            .f32 => .f32,
            .f64 => .f64,
            .v128, .ref => return invoke_args_mod.ArgError.UnsupportedArgType,
        };
        const v = try invoke_args_mod.parseArg(kind, std.mem.trim(u8, tok, " "));
        out[i] = switch (v.kind) {
            .i32 => @as(u64, @as(u32, @bitCast(v.of.i32))),
            .i64 => @bitCast(v.of.i64),
            .f32 => @as(u64, @as(u32, @bitCast(v.of.f32))),
            .f64 => @bitCast(v.of.f64),
            .anyref, .funcref => return invoke_args_mod.ArgError.UnsupportedArgType,
        };
    }
    return out;
}

/// Map a D-477 multi-result `TypedResult` slot to the C-API boundary `Val` so
/// `invoke_args.formatScalar` renders it identically to the interp multi-value
/// path. i32/i64/f32/f64 are bit-casts of the slot; refs render null/ref.
fn typedResultToVal(r: @import("../engine/runner.zig").TypedResult) wasm_c_api.Val {
    return switch (r) {
        .i32 => |x| .{ .kind = .i32, .of = .{ .i32 = @bitCast(x) } },
        .i64 => |x| .{ .kind = .i64, .of = .{ .i64 = @bitCast(x) } },
        .f32 => |x| .{ .kind = .f32, .of = .{ .f32 = @bitCast(x) } },
        .f64 => |x| .{ .kind = .f64, .of = .{ .f64 = @bitCast(x) } },
        .funcref => |x| .{ .kind = .funcref, .of = .{ .ref = if (x == 0) null else @ptrFromInt(x) } },
        .externref => |x| .{ .kind = .anyref, .of = .{ .ref = if (x == 0) null else @ptrFromInt(x) } },
    };
}

/// Map the engine's Zone-2 `ScalarResult` to the C-API boundary `Val` so the
/// shared `invoke_args.formatScalar` renders it identically to the interp path.
fn scalarToVal(r: @import("../engine/runner.zig").ScalarResult) wasm_c_api.Val {
    return switch (r) {
        .i32 => |x| .{ .kind = .i32, .of = .{ .i32 = x } },
        .i64 => |x| .{ .kind = .i64, .of = .{ .i64 = x } },
        .f32 => |x| .{ .kind = .f32, .of = .{ .f32 = x } },
        .f64 => |x| .{ .kind = .f64, .of = .{ .f64 = x } },
        // v128 is rendered directly (caller branches before this); it has no
        // C-ABI `Val` representation.
        .v128 => unreachable,
    };
}

/// `zwasm run <component.wasm>` (CM campaign D1-2 / D-306): run a WASI Preview 2
/// **component** from the CLI. Routes a component-layer module (preamble version
/// `0x0d`, layer 1) to the component host (`api/component.zig runWasiP2Main`),
/// wiring real stdout via the WASI host (`io` set, no capture buffer → the
/// trampolines' `fd.writeSlice` routes fd 1 to the process stdout). Returns the
/// guest exit code (0 on clean run). SCOPE: the `wasi:cli/run` stdio subset (the
/// general P2 host is D-306).
pub fn runComponentWasi(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    argv: []const []const u8,
    preopens: []const PreopenDir,
    env_keys: []const []const u8,
    env_vals: []const []const u8,
    stdin: StdinSource,
) !u8 {
    return runComponentCaptured(alloc, io, bytes, argv, preopens, env_keys, env_vals, stdin, null);
}

/// `runComponentWasi` with an optional stdout capture buffer (tests assert on
/// guest output; `null` → real process stdout).
pub fn runComponentCaptured(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    argv: []const []const u8,
    preopens: []const PreopenDir,
    env_keys: []const []const u8,
    env_vals: []const []const u8,
    stdin: StdinSource,
    stdout_capture: ?*std.ArrayList(u8),
) !u8 {
    const component = @import("../api/component.zig");
    const Engine = @import("../zwasm/engine.zig").Engine;
    var eng = try Engine.init(alloc, .{});
    defer eng.deinit();

    var host = try wasi_host.Host.init(alloc);
    defer host.deinit();
    host.io = io;
    if (stdout_capture) |b| host.stdout_buffer = b;
    if (argv.len > 0) try host.setArgs(argv);
    if (env_keys.len > 0) try host.setEnvs(env_keys, env_vals); // D-295 P0: --env KEY=VAL
    stdin.applyTo(&host); // components serve fd 0 from a byte slice only
    // `--dir` preopens feed the P2 host: `get-directories` enumerates them and
    // the descriptor `*-at` methods resolve against their fds (CLI-scoped fd
    // lifetime, like the core-module paths).
    for (preopens) |pd| {
        const dir = try std.Io.Dir.cwd().openDir(io, pd.host_path, .{ .iterate = true });
        _ = try host.addPreopen(dir.handle, pd.guest_path);
    }

    // REQ-4 — the component CLI path uses the default budget for now; wiring
    // the `--fuel`/`--max-memory` flags into `runComponentCaptured` is a
    // separate CLI enhancement (the API-level budget is the cw requirement).
    // Unified runner (D-335 Unit F): async-lifted components run through the P3
    // callback loop, sync ones through `wasi:cli/run` — auto-dispatched.
    component.runWasiMain(&eng, alloc, bytes, &host, .{}) catch |err| {
        if (host.exit_code) |code| return @intCast(@min(code, std.math.maxInt(u8)));
        return err;
    };
    if (host.exit_code) |code| return @intCast(@min(code, std.math.maxInt(u8)));
    return 0;
}

/// `zwasm run <file.cwasm>` (ADR-0203 stage 3): a `.cwasm` runs through the
/// SAME full-runtime flow as its source `.wasm` — `runWasmJitCaptured`
/// detects the CWAS magic, the engine deserializes the artifact into a real
/// `CompiledWasm`, and the identical setup/WASI/entry path executes it
/// (cache-hit == cache-miss). The pre-stage-3 compute-only mini-runtime
/// (`aot/run.zig`) is retired: memory.grow / GC / EH / start functions /
/// sandbox limits behave exactly like the `.wasm` path (discharges D-517 +
/// D-518). Kept as a named wrapper for the AOT-lane callers.
pub fn runCwasmWasi(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwasm_bytes: []const u8,
    invoke_name: ?[]const u8,
    argv: []const []const u8,
    preopens: []const PreopenDir,
    env_keys: []const []const u8,
    env_vals: []const []const u8,
    stdout_capture: ?*std.ArrayList(u8),
) !u8 {
    diagnostic.clearDiag();
    return runWasmJitCaptured(alloc, io, cwasm_bytes, invoke_name, argv, preopens, env_keys, env_vals, .{}, stdout_capture, null, .none);
}

/// Like `runWasm` but routes guest stdout writes (`fd_write`
/// to fd 1) into the caller-supplied `stdout_capture`. When
/// non-null, the runner wires `host.stdout_buffer` to it; the
/// caller owns the buffer and must release it. The realworld-
/// diff runner (§9.6 / 6.F) uses this to byte-compare against
/// wasmtime's stdout for the same fixture.
///
/// `argv` is forwarded to the WASI host via `setArgs`; conventional
/// WASI guests expect `argv[0]` to be the program name (matching
/// wasmtime's default of using the wasm filename). Pass `&.{}` for
/// "no args" — empty argv yields argc=0.
///
/// `invoke_name` overrides the entry-point selection (default
/// `_start` → `main` → first func export). When non-null, the
/// runner locates the func export with that exact name and calls
/// it with **zero args** — this is the zero-arg wrapper; typed
/// `--invoke NAME=a,b,...` arg marshalling + result printing live
/// in `cli/invoke_args.zig` (D-273).
pub fn runWasmCaptured(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    argv: []const []const u8,
    stdout_capture: ?*std.ArrayList(u8),
    invoke_name: ?[]const u8,
) !u8 {
    return runWasmCapturedOpts(alloc, io, bytes, argv, stdout_capture, invoke_name, &.{}, &.{}, &.{}, null, .{});
}

/// One host→guest directory mapping for a WASI preopen (`--dir`, D-243).
pub const PreopenDir = struct { host_path: []const u8, guest_path: []const u8 };

/// What the guest's fd 0 reads (#257). `.inherit` serves the host process's
/// stdin on demand — no size cap, no read-ahead, a terminal works — and is
/// what `zwasm run` passes for a core module. Components read from a byte
/// slice only, so their CLI path reads a piped stdin up front into `.bytes`.
pub const StdinSource = union(enum) {
    none,
    bytes: []const u8,
    inherit,

    fn applyTo(self: StdinSource, host: *wasi_host.Host) void {
        switch (self) {
            .none => {},
            .bytes => |b| host.stdin_bytes = b,
            .inherit => host.stdin_inherit = true,
        }
    }
};

/// Like `runWasmCaptured` but maps `preopens` host directories into the
/// guest's WASI preopen table (the `--dir <host>[:<guest>]` flag). The
/// opened host dir fds live for the process lifetime (CLI-scoped); the
/// realworld runners pass `&.{}` (no preopens) per D-243.
pub fn runWasmCapturedFull(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    argv: []const []const u8,
    stdout_capture: ?*std.ArrayList(u8),
    stderr_capture: ?*std.ArrayList(u8),
    stdin: StdinSource,
    invoke_name: ?[]const u8,
    preopens: []const PreopenDir,
    env_keys: []const []const u8,
    env_vals: []const []const u8,
    invoke_args: ?[]const u8,
    limits: Limits,
) !u8 {
    if (dbg.on("jit.callcount")) call_profile.reset();
    defer if (dbg.on("jit.callcount")) call_profile.dump();

    // Per ADR-0016 phase 1: clear any stale diagnostic from a
    // previous call before populating a fresh one on failure.
    diagnostic.clearDiag();

    const engine = wasm_c_api.wasm_engine_new() orelse {
        diagnostic.setDiag(.instantiate, .engine_alloc_failed, .unknown, "engine allocation failed", .{});
        return error.EngineAllocFailed;
    };
    defer wasm_c_api.wasm_engine_delete(engine);
    const store = wasm_c_api.wasm_store_new(engine) orelse {
        diagnostic.setDiag(.instantiate, .store_alloc_failed, .unknown, "store allocation failed", .{});
        return error.StoreAllocFailed;
    };
    defer wasm_c_api.wasm_store_delete(store);

    // Configure the WASI host. The CLI threading of args /
    // environ / preopens lands in chunk b; for chunk a the host
    // is the bare default + an io context for path_open / clock /
    // random.
    const cfg = wasm_c_api.zwasm_wasi_config_new() orelse {
        diagnostic.setDiag(.instantiate, .config_alloc_failed, .unknown, "wasi config allocation failed", .{});
        return error.ConfigAllocFailed;
    };
    cfg.io = io;
    // D-243 — map host directories into the guest's preopen table. Open
    // each host dir and register its fd via addPreopen; path_open then
    // resolves guest paths relative to it. The fd stays open for the
    // process lifetime (host.deinit frees the preopen names, not the fds).
    for (preopens) |pd| {
        const host_dir = std.Io.Dir.cwd().openDir(io, pd.host_path, .{ .iterate = true }) catch |err| {
            diagnostic.setDiag(.instantiate, .config_alloc_failed, .unknown, "wasi preopen dir open failed", .{});
            wasm_c_api.zwasm_wasi_config_delete(cfg);
            return err;
        };
        _ = cfg.addPreopen(host_dir.handle, pd.guest_path) catch {
            diagnostic.setDiag(.instantiate, .config_alloc_failed, .unknown, "wasi preopen registration failed", .{});
            wasm_c_api.zwasm_wasi_config_delete(cfg);
            return error.ConfigAllocFailed;
        };
    }
    if (stdout_capture) |buf| cfg.stdout_buffer = buf;
    if (stderr_capture) |buf| cfg.stderr_buffer = buf;
    stdin.applyTo(cfg);
    // Grow the caller-owned capture buffers with the caller's allocator so the
    // grow-allocator and the caller's free/toOwnedSlice allocator agree.
    cfg.capture_alloc = alloc;
    // The C-API path builds its own Host through `zwasm_wasi_config_new`, so it
    // does NOT inherit the cap `runWasmJitCaptured` sets on its host — a second
    // capture surface beside a hardened one does not inherit the hardening
    // unless it is wired too. Measured: cljw's `wasm/run` passes through here,
    // and the first version of the cap left it uncapped at exactly the 64 MB
    // per 1e6 fuel the axis exists to bound.
    cfg.max_capture_bytes = limits.max_output_bytes;
    if (argv.len > 0) cfg.setArgs(argv) catch {
        diagnostic.setDiag(.instantiate, .config_alloc_failed, .unknown, "wasi argv allocation failed", .{});
        wasm_c_api.zwasm_wasi_config_delete(cfg);
        return error.ConfigAllocFailed;
    };
    if (env_keys.len > 0) cfg.setEnvs(env_keys, env_vals) catch { // D-295 P0: --env KEY=VAL
        diagnostic.setDiag(.instantiate, .config_alloc_failed, .unknown, "wasi environ allocation failed", .{});
        wasm_c_api.zwasm_wasi_config_delete(cfg);
        return error.ConfigAllocFailed;
    };
    wasm_c_api.zwasm_store_set_wasi(store, cfg);

    var bv: wasm_c_api.ByteVec = .{
        .size = bytes.len,
        .data = @constCast(bytes.ptr),
    };
    const module = wasm_c_api.wasm_module_new(store, &bv) orelse {
        // ADR-0016 M3 — `frontendValidate` sets an attributed validate
        // diagnostic (phase=.validate, op/offset) on the cold path; keep
        // it. Only fall back to the generic message if no detail was set
        // (e.g. an allocation failure rather than a validate rejection).
        if (diagnostic.lastDiagnostic() == null) {
            diagnostic.setDiag(.instantiate, .module_alloc_failed, .unknown, "module decode/validate failed", .{});
        }
        return error.ModuleAllocFailed;
    };
    defer wasm_c_api.wasm_module_delete(module);

    // D-496 — honour the caller's engine selection (default `.auto` = JIT-preferring
    // with interp fallback per the flip; `.interp` forces interp for `--engine interp`).
    const instance = @import("../api/instance.zig").instanceNewWithEngine(store, module, null, null, limits.engine) orelse {
        diagnostic.setDiag(.instantiate, .instance_alloc_failed, .unknown, "instantiation failed (no further detail in phase 1)", .{});
        return error.InstanceAllocFailed;
    };
    defer wasm_c_api.wasm_instance_delete(instance);

    // ADR-0179 #3a-4 / D-314 — arm the sandboxing limits on the interp
    // Runtime (post-instantiate, mirroring the facade setters). The
    // `--timeout` timer raises the interrupt flag the dispatch loop polls;
    // ConcurrencyUnavailable surfaces loudly (a silent no-timeout run would
    // be a sandbox hole, no_workaround).
    var timeout_flag = std.atomic.Value(u32).init(0);
    var timeout_fut: ?std.Io.Future(void) = null;
    defer if (timeout_fut) |*f| f.cancel(io);
    if (limits.any()) {
        if (instance.runtime) |rt| {
            if (limits.fuel) |n| rt.fuel = n;
            if (limits.max_memory_bytes) |b| rt.store_memory_pages_max = b / wasm_page_bytes;
            if (limits.timeout_ms) |ms| {
                timeout_fut = try io.concurrent(timeoutRaiser, .{ io, ms, &timeout_flag });
                rt.interrupt = &timeout_flag;
            }
        } else if (@import("../api/instance.zig").jitOf(instance)) |jit| {
            // ADR-0200/D-496 `.auto`→JIT flip: this captured-run path now defaults to
            // the JIT, so the sandbox limits must arm the JIT instance too (else
            // `--fuel`/`--timeout` are silently dropped and an infinite-loop guest
            // hangs — the regression the flip exposes). The JIT meters poll-site
            // crossings (prologue + back-edges) for both fuel and interrupt.
            if (limits.fuel) |n| jit.setFuel(n);
            if (limits.max_memory_bytes) |b| jit.setMemoryPagesLimit(b / wasm_page_bytes);
            if (limits.timeout_ms) |ms| {
                timeout_fut = try io.concurrent(timeoutRaiser, .{ io, ms, &timeout_flag });
                jit.setInterruptFlag(&timeout_flag);
            }
        }
    }

    // Locate the entry export. When `invoke_name` is non-null the
    // caller has picked a specific export by name (Phase 11 bench
    // prerequisite per §9.12-G); otherwise WASI guests
    // conventionally export `_start` and our fixtures + hand-rolled
    // hello-worlds also use `main`.
    const entry_idx = blk: {
        if (invoke_name) |name| {
            for (instance.exports_storage, 0..) |exp, i| {
                if (exp.kind == .func and std.mem.eql(u8, exp.name, name)) break :blk i;
            }
            diagnostic.setDiag(.instantiate, .no_func_export, .unknown, "--invoke: named func export not found", .{});
            return error.NoFuncExport;
        }
        for (instance.exports_storage, 0..) |exp, i| {
            if (exp.kind == .func and std.mem.eql(u8, exp.name, "_start")) break :blk i;
        }
        for (instance.exports_storage, 0..) |exp, i| {
            if (exp.kind == .func and std.mem.eql(u8, exp.name, "main")) break :blk i;
        }
        for (instance.exports_storage, 0..) |exp, i| {
            if (exp.kind == .func) break :blk i;
        }
        diagnostic.setDiag(.instantiate, .no_func_export, .unknown, "no exported function found (looked for _start, main, then any export)", .{});
        return error.NoFuncExport;
    };

    var exports: wasm_c_api.ExternVec = .{ .size = 0, .data = null };
    wasm_c_api.wasm_instance_exports(instance, &exports);
    defer wasm_c_api.wasm_extern_vec_delete(&exports);
    if (entry_idx >= exports.size) {
        diagnostic.setDiag(.instantiate, .no_func_export, .unknown, "exported function vector size mismatch", .{});
        return error.NoFuncExport;
    }
    const ext = exports.data.?[entry_idx] orelse {
        diagnostic.setDiag(.instantiate, .no_func_export, .unknown, "exported function entry is null", .{});
        return error.NoFuncExport;
    };
    const entry_fn = wasm_c_api.wasm_extern_as_func(ext) orelse {
        diagnostic.setDiag(.instantiate, .no_func_export, .unknown, "exported entry is not a function", .{});
        return error.NoFuncExport;
    };

    // Marshal `--invoke NAME=ARGS` arguments against the entry's signature
    // and collect its typed results (D-273(1)). A value-returning export now
    // runs (the results vec is sized to the result arity); the formatted
    // results print on the same channel as guest stdout — wasmtime semantics.
    var result_text: std.ArrayList(u8) = .empty;
    defer result_text.deinit(alloc);
    const trap = invoke_args_mod.invokeFormatted(alloc, entry_fn, invoke_args, &result_text) catch |err| {
        const msg = switch (err) {
            error.ArgCountMismatch => "--invoke: argument count does not match the export's parameters",
            error.UnsupportedArgType => "--invoke: unsupported argument type (CLI args are i32/i64/f32/f64 only)",
            error.InvalidArgValue => "--invoke: could not parse an argument for the export's parameter type",
            else => "--invoke: argument marshalling failed",
        };
        diagnostic.setDiag(.execute, .binding_error, .unknown, "{s}", .{msg});
        return err;
    };
    if (trap == null) {
        try writeResultText(io, stdout_capture, alloc, result_text.items);
        return 0;
    }
    defer wasm_c_api.wasm_trap_delete(trap);

    // Trap path. If `proc_exit` was the cause, the host carries
    // the requested exit code. Other traps map to 1.
    // For non-exit traps, print the kind + message on stderr so
    // the CLI / `runWasm` callers can see what hit.
    // #345 — resolve the host through the same rule as
    // `zwasm_store_wasi_exit_code`: the one the called instance captured, not
    // whichever is installed now. Unreachable divergence here today (the CLI
    // installs one config and never swaps), but a second reader keyed on
    // `store.wasi_host` is how the two halves drifted apart in the first place.
    if (@import("../api/instance.zig").activeWasiHost(store)) |host| {
        if (host.exit_code) |_| {
            // exit_code already carries the status; nothing else to surface.
        } else {
            surfaceTrap(io, trap.?);
        }
        if (host.exit_code) |code| {
            return @intCast(@min(code, std.math.maxInt(u8)));
        }
    } else {
        surfaceTrap(io, trap.?);
    }
    return 1;
}

/// Back-compat shim: stdout-only capture (no stderr/stdin). Existing callers
/// (the `run` CLI command, realworld runners) keep their signature; embedders
/// that need stderr/stdin capture (cljw `wasm/run`) call `runWasmCapturedFull`.
pub fn runWasmCapturedOpts(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    argv: []const []const u8,
    stdout_capture: ?*std.ArrayList(u8),
    invoke_name: ?[]const u8,
    preopens: []const PreopenDir,
    env_keys: []const []const u8,
    env_vals: []const []const u8,
    invoke_args: ?[]const u8,
    limits: Limits,
) !u8 {
    return runWasmCapturedFull(alloc, io, bytes, argv, stdout_capture, null, .none, invoke_name, preopens, env_keys, env_vals, invoke_args, limits);
}

/// Emit the formatted `--invoke` result text on the guest-stdout channel:
/// the capture buffer when one is wired (tests / realworld differ), else the
/// process stdout. Empty text (void / zero-result export) is a no-op, so the
/// existing `_start`/`main` exit-code paths print nothing extra.
fn writeResultText(io: std.Io, capture: ?*std.ArrayList(u8), alloc: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;
    if (capture) |buf| {
        try buf.appendSlice(alloc, text);
        return;
    }
    var ob: [256]u8 = undefined;
    var sw = std.Io.File.stdout().writerStreaming(io, &ob);
    const w = &sw.interface;
    try w.writeAll(text);
    try w.flush();
}

/// Best-effort stderr surface of a non-exit trap. If the underlying
/// writer fails (closed pipe, OOM during print), there is nothing
/// meaningful to do beyond the caller's exit-code path — the print
/// errors are intentionally swallowed.
fn surfaceTrap(io: std.Io, trap: anytype) void {
    // Production CLI diagnostic. Under `zig build test` this writes to the shared
    // harness stderr (no test asserts the text; they check exit codes / trap
    // kinds), so it is comptime-elided in test builds to keep output clean.
    if (@import("builtin").is_test) return;
    var stderr_buf: [256]u8 = undefined;
    var sw = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const w = &sw.interface;
    if (trap.message_ptr) |p| {
        w.print("zwasm: trap kind={s} msg={s}\n", .{
            @tagName(trap.kind),
            p[0..trap.message_len],
            // EXEMPT-FALLBACK: ADR-0016 phase 1 — surfaceTrap is best-effort trap stderr; closed-pipe failure has no recovery path.
        }) catch {};
    } else {
        // EXEMPT-FALLBACK: ADR-0016 phase 1 — surfaceTrap is best-effort trap stderr; closed-pipe failure has no recovery path.
        w.print("zwasm: trap kind={s}\n", .{@tagName(trap.kind)}) catch {};
    }
    // EXEMPT-FALLBACK: ADR-0016 phase 1 — final stderr flush on trap surfacing; failure here is unrecoverable.
    w.flush() catch {};
}

/// Surface a JIT/AOT trap on stderr from the numeric trap-kind code the shared
/// trap stub recorded (ADR-0164 workstream A). The interp path uses
/// `surfaceTrap` over a `wasm_trap_t`; the JIT/AOT run paths bypass the C API,
/// so they map `JitRuntime.trap_kind` here. A precise code prints the same
/// interp-parity kind + message; the generic bucket (codes 0/1) honestly says
/// the kind is not yet distinguished (D-292 codegen widening).
fn surfaceJitTrap(io: std.Io, code: u32) void {
    // See surfaceTrap: comptime-elided under test to keep harness stderr clean.
    if (@import("builtin").is_test) return;
    var stderr_buf: [256]u8 = undefined;
    var sw = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const w = &sw.interface;
    if (trap_surface.jitTrapCode(code)) |kind| {
        // EXEMPT-FALLBACK: ADR-0016 phase 1 — best-effort trap stderr; closed-pipe failure has no recovery path.
        w.print("zwasm: trap kind={s} msg={s}\n", .{ @tagName(kind), trap_surface.trapMessageFor(kind) }) catch {};
    } else {
        // EXEMPT-FALLBACK: ADR-0016 phase 1 — best-effort trap stderr; closed-pipe failure has no recovery path.
        w.print("zwasm: wasm trap (kind not yet distinguished under jit/aot — D-292)\n", .{}) catch {};
    }
    // EXEMPT-FALLBACK: ADR-0016 phase 1 — final stderr flush on trap surfacing; failure here is unrecoverable.
    w.flush() catch {};
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test {
    // The diagnostic + diag_print modules ship their own unit
    // tests; reference them from this file's test block so
    // `zig build test` discovers them via the `cli/run.zig`
    // ladder regardless of whether `main.zig` is compiled.
    _ = diagnostic;
}

// Same fixture shape as the §9.4 / 4.7d end-to-end test in
// wasm_c_api.zig:
//   (module (import "wasi_snapshot_preview1" "proc_exit"
//             (func (param i32)))
//          (func (export "main") i32.const 42 call 0))
const proc_exit_42_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x01, 0x7F, 0x00, 0x60,
    0x00, 0x00, 0x02, 0x24, 0x01, 0x16, 0x77, 0x61,
    0x73, 0x69, 0x5F, 0x73, 0x6E, 0x61, 0x70, 0x73,
    0x68, 0x6F, 0x74, 0x5F, 0x70, 0x72, 0x65, 0x76,
    0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6F,
    0x63, 0x5F, 0x65, 0x78, 0x69, 0x74, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x01, 0x07, 0x08, 0x01, 0x04,
    0x6D, 0x61, 0x69, 0x6E, 0x00, 0x01, 0x0A, 0x08,
    0x01, 0x06, 0x00, 0x41, 0x2A, 0x10, 0x00, 0x0B,
};

test "runWasm: proc_exit_42 fixture returns exit code 42" {
    const code = try runWasm(testing.allocator, testing.io, &proc_exit_42_wasm, &.{});
    try testing.expectEqual(@as(u8, 42), code);
}

// ADR-0016 phase 1 golden test: a malformed-magic wasm makes
// `wasm_module_new` fail; runWasm returns ModuleAllocFailed; the
// threadlocal diagnostic is set to the boundary classification
// the CLI render pipeline expects. Locks v1 → v2 parity recovery.
const malformed_magic_wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0xff, 0xff, 0xff, 0xff };

test "runComponentWasi: a real WASI-P2 component runs from the CLI path + prints" {
    // The CLI routes a component-layer module to the component host; the
    // wasi:cli/run hello-world prints "hello\n" through the P2 trampolines.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "test/component/wasi_p2_hello.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    const code = try runComponentCaptured(testing.allocator, testing.io, bytes, &.{}, &.{}, &.{}, &.{}, .none, &capture);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("hello\n", capture.items);
}

test "runComponentWasi: an ASYNC (WASI-0.3 P3) component runs from the CLI path (Unit F dispatch)" {
    // D-335 Unit F: the unified runner auto-detects the async lift and drives
    // the P3 callback loop — the guest writes "hi" to stdout via write-via-stream.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "test/component/async_stdout_write_via_stream.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    const code = try runComponentCaptured(testing.allocator, testing.io, bytes, &.{}, &.{}, &.{}, &.{}, .none, &capture);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("hi\n", capture.items);
}

test "runWasm: malformed wasm produces a parse-phase diagnostic with byte offset (F6)" {
    // D-334 F6: the parser now sets a specific .parse diagnostic, so the coarse
    // `.instantiate` "module decode/validate failed" fallback (run.zig ~423, set
    // only when lastDiagnostic()==null) steps aside. malformed_magic_wasm = good
    // magic + bad version 0xffffffff → UnsupportedVersion @ offset 0x4.
    const result = runWasm(testing.allocator, testing.io, &malformed_magic_wasm, &.{});
    try testing.expectError(error.ModuleAllocFailed, result);

    const diag = diagnostic.lastDiagnostic().?;
    try testing.expectEqual(diagnostic.Phase.parse, diag.phase);
    try testing.expect(std.mem.find(u8, diag.message(), "unsupported binary version") != null);
    try testing.expect(std.mem.find(u8, diag.message(), "0x4") != null);
}

test "runWasmCaptured: --invoke 'main' on proc_exit_42 fixture returns exit code 42" {
    // Phase 11 bench prerequisite (§9.12-G): named-export entry-point
    // selection. The proc_exit_42 fixture exports `main`; invoking it
    // by name returns the same exit code as the default `main` fallback.
    const code = try runWasmCaptured(testing.allocator, testing.io, &proc_exit_42_wasm, &.{}, null, "main");
    try testing.expectEqual(@as(u8, 42), code);
}

// `(func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)`
const add_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60,
    0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20,
    0x00, 0x20, 0x01, 0x6a, 0x0b,
};

test "runWasmCapturedOpts: --invoke add=2,3 marshals args and prints the typed result (D-273(1))" {
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    const code = try runWasmCapturedOpts(testing.allocator, testing.io, &add_wasm, &.{}, &capture, "add", &.{}, &.{}, &.{}, "2,3", .{});
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("5\n", capture.items);
}

test "runWasmCapturedOpts: --invoke add with a bad arg count is a loud binding_error" {
    const result = runWasmCapturedOpts(testing.allocator, testing.io, &add_wasm, &.{}, null, "add", &.{}, &.{}, &.{}, "2", .{});
    try testing.expectError(error.ArgCountMismatch, result);
    const diag = diagnostic.lastDiagnostic().?;
    try testing.expectEqual(diagnostic.Kind.binding_error, diag.kind);
}

// (module (func (export "a") (result i32) i32.const 42)) — zero params,
// value-returning. The JIT `--invoke` path must surface the typed result on the
// guest-stdout channel like the interp path + wasmtime (it was silently dropped
// for i32 and a hard `UnsupportedEntrySignature` for i64/f32/f64 before).
const answer_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
    0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x61,
    0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41,
    0x2a, 0x0b,
};

test "runWasmJitCaptured: --invoke a zero-arg i32 export prints the typed result (wasmtime/interp parity)" {
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    const code = try runWasmJitCaptured(testing.allocator, testing.io, &answer_wasm, "a", &.{}, &.{}, &.{}, &.{}, .{}, &capture, null, .none);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("42\n", capture.items);
}

// (module (func (export "a") (result f64) f64.const 3.5)) — locks the 64-bit
// float carrier decode arm (was a hard `UnsupportedEntrySignature` on the JIT
// path before the typed-result wiring; i64/f32 ride the same machinery).
const answer_f64_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00, 0x01,
    0x7c, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x61, 0x00, 0x00, 0x0a, 0x0d,
    0x01, 0x0b, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x40, 0x0b,
};

test "runWasmJitCaptured: --invoke a zero-arg f64 export prints the typed result (64-bit carrier)" {
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    const code = try runWasmJitCaptured(testing.allocator, testing.io, &answer_f64_wasm, "a", &.{}, &.{}, &.{}, &.{}, .{}, &capture, null, .none);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("3.5\n", capture.items);
}

// (module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
// D-477 exit-condition: `zwasm run --engine jit --invoke add=2,3` prints "5".
const add2_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
    0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0a, 0x09,
    0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a,
    0x0b,
};

test "runWasmJitCaptured: D-477 --invoke add=2,3 on the JIT engine prints 5 (arm64 + x86_64 SysV + Win64)" {
    // The end-to-end bundle exit-condition: typed multi-arg `--invoke` on the JIT
    // engine. 2-param GPR is emitted on all three arches (arm64 ≤7, x86_64 SysV
    // ≤5, Win64 ≤3), so add=2,3 works everywhere. (sum4's 4 params stay
    // Win64-deferred — see runner_multiarg_invoke_test.zig.)
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    const code = try runWasmJitCaptured(testing.allocator, testing.io, &add2_wasm, "add", &.{}, &.{}, &.{}, &.{}, .{}, &capture, "2,3", .none);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("5\n", capture.items);
}

// (module (func (export "swap2") (param i32 i32) (result i32 i32) local.get 1 local.get 0))
// D-477 multi-result CLI: `--invoke swap2=7,9` prints "9\n7\n" (each value a line).
const swap2_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x02,
    0x7f, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x09,
    0x01, 0x05, 0x73, 0x77, 0x61, 0x70, 0x32, 0x00,
    0x00, 0x0a, 0x08, 0x01, 0x06, 0x00, 0x20, 0x01,
    0x20, 0x00, 0x0b,
};

test "runWasmJitCaptured: D-477 --invoke swap2=7,9 multi-result prints each value on its own line (arm64 + x86_64 SysV)" {
    // CLI multi-RESULT sliver: a 2-result export prints both values, in order,
    // one per line — interp parity. arm64 + x86_64 SysV emit the 2-param 2-GPR-
    // result thunk; Win64 RUN stays phase-end-gated (verified on Mac arm64 +
    // ubuntu SysV here).
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return;
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    const code = try runWasmJitCaptured(testing.allocator, testing.io, &swap2_wasm, "swap2", &.{}, &.{}, &.{}, &.{}, .{}, &capture, "7,9", .none);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("9\n7\n", capture.items);
}

// (module (func (export "_start") (loop (br 0)))) — infinite; only a
// sandboxing limit can end it (hang-as-failure, bounded by gate timeouts).
const infinite_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60,
    0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x03,
    0x40, 0x0c, 0x00, 0x0b, 0x0b,
};

test "run --fuel: interp path traps an infinite loop and exits 1 (ADR-0179 #3a-4)" {
    const code = try runWasmCapturedOpts(testing.allocator, testing.io, &infinite_start_wasm, &.{}, null, null, &.{}, &.{}, &.{}, null, .{ .fuel = 1000 });
    try testing.expectEqual(@as(u8, 1), code);
}

test "run --timeout: interp path interrupts an infinite loop and exits 1 (ADR-0179 #3a-4)" {
    const code = try runWasmCapturedOpts(testing.allocator, testing.io, &infinite_start_wasm, &.{}, null, null, &.{}, &.{}, &.{}, null, .{ .timeout_ms = 50 });
    try testing.expectEqual(@as(u8, 1), code);
}

test "run --fuel: JIT path traps an infinite loop and exits 1 (ADR-0179 #3a-4)" {
    const code = try runWasmJit(testing.allocator, testing.io, &infinite_start_wasm, null, &.{}, &.{}, &.{}, &.{}, .{ .fuel = 1000 });
    try testing.expectEqual(@as(u8, 1), code);
}

test "run --timeout: JIT path interrupts an infinite loop and exits 1 (ADR-0179 #3a-4)" {
    const code = try runWasmJit(testing.allocator, testing.io, &infinite_start_wasm, null, &.{}, &.{}, &.{}, &.{}, .{ .timeout_ms = 50 });
    try testing.expectEqual(@as(u8, 1), code);
}

// (module (memory 1) (func (export "_start")
//   (drop (memory.grow (i32.const 1)))                       ;; 1→2
//   (if (i32.ne (memory.grow (i32.const 1)) (i32.const -1))  ;; 2→3
//     (then unreachable))))
// With --max-memory 131072 (= 2 pages) the SECOND grow is refused (-1) →
// clean exit 0; without the cap it succeeds → unreachable → exit 1. Pins
// the bytes→pages conversion on both engine paths.
const grow_probe_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60,
    0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07,
    0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a,
    0x14, 0x01, 0x12, 0x00, 0x41, 0x01, 0x40, 0x00, 0x1a, 0x41, 0x01, 0x40,
    0x00, 0x41, 0x7f, 0x47, 0x04, 0x40, 0x00, 0x0b, 0x0b,
};

test "run --max-memory: caps memory.grow on both engine paths (ADR-0179 #3a-4)" {
    // Capped at 2 pages → second grow refused → guest exits clean (0).
    try testing.expectEqual(@as(u8, 0), try runWasmCapturedOpts(testing.allocator, testing.io, &grow_probe_wasm, &.{}, null, null, &.{}, &.{}, &.{}, null, .{ .max_memory_bytes = 2 * 64 * 1024 }));
    try testing.expectEqual(@as(u8, 0), try runWasmJit(testing.allocator, testing.io, &grow_probe_wasm, null, &.{}, &.{}, &.{}, &.{}, .{ .max_memory_bytes = 2 * 64 * 1024 }));
    // Uncapped → second grow succeeds → guest hits unreachable (exit 1).
    try testing.expectEqual(@as(u8, 1), try runWasmCapturedOpts(testing.allocator, testing.io, &grow_probe_wasm, &.{}, null, null, &.{}, &.{}, &.{}, null, .{}));
    try testing.expectEqual(@as(u8, 1), try runWasmJit(testing.allocator, testing.io, &grow_probe_wasm, null, &.{}, &.{}, &.{}, &.{}, .{}));
}

test "runWasmCaptured: --invoke <bogus> on proc_exit_42 fixture returns NoFuncExport" {
    const result = runWasmCaptured(testing.allocator, testing.io, &proc_exit_42_wasm, &.{}, null, "bogus_export_name");
    try testing.expectError(error.NoFuncExport, result);

    const diag = diagnostic.lastDiagnostic().?;
    try testing.expectEqual(diagnostic.Phase.instantiate, diag.phase);
    try testing.expectEqual(diagnostic.Kind.no_func_export, diag.kind);
    try testing.expect(std.mem.startsWith(u8, diag.message(), "--invoke:"));
}

test "runWasm: clearDiag is invoked on entry — fresh call clears prior state" {
    diagnostic.setDiag(.execute, .oob_memory, .unknown, "stale", .{});
    try testing.expect(diagnostic.lastDiagnostic() != null);

    // Successful run path — should clear the stale diag at entry.
    _ = try runWasm(testing.allocator, testing.io, &proc_exit_42_wasm, &.{});
    // After a successful run, no diagnostic should be set.
    try testing.expect(diagnostic.lastDiagnostic() == null);
}

// `(module (memory (export "memory") 1) (func (export "_start")
//   (local $i i32) (local $acc v128) ... loop { acc = i32x4.add acc k; i-- }
//   (v128.store 0 acc)))` — a compute-only SIMD `_start`. The interpreter
// has NO SIMD execution (SIMD is JIT-only by design, D-244), so the default
// path traps `Unreachable`; `--engine=jit` (ADR-0136) JIT-compiles + runs it.
const simd_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60,
    0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07,
    0x13, 0x02, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x06,
    0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x55, 0x01, 0x53,
    0x02, 0x01, 0x7f, 0x01, 0x7b, 0x41, 0x80, 0xda, 0xc4, 0x09, 0x21, 0x00,
    0xfd, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x01, 0x02, 0x40, 0x03, 0x40,
    0x20, 0x01, 0xfd, 0x0c, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0xfd, 0xae, 0x01, 0x21,
    0x01, 0x20, 0x00, 0x41, 0x01, 0x6b, 0x21, 0x00, 0x20, 0x00, 0x0d, 0x00,
    0x0b, 0x0b, 0x41, 0x00, 0x20, 0x01, 0xfd, 0x0b, 0x04, 0x00, 0x0b,
};

test "cwasm --invoke behaves byte-identically to its source .wasm (ADR-0203 stage 3)" {
    // Executes native AOT machine code → Win64 deferred, mirroring the
    // pre-stage-3 aot exec tests (skip.phaseEnd).
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);

    const runner = @import("../engine/runner.zig");
    const aot_produce = @import("../engine/codegen/aot/produce.zig");

    // `() -> i32` returning 42, exported "f". (type/func/export/code)
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41,
        0x2a, 0x0b,
    };

    var compiled = try runner.compileWasmForAot(testing.allocator, &wasm);
    const cwasm = blk: {
        defer compiled.deinit(testing.allocator);
        break :blk try aot_produce.produceFromCompiledWasm(testing.allocator, &compiled, &wasm);
    };
    defer testing.allocator.free(cwasm);

    // `--invoke f` prints the typed result — the SAME bytes as the .wasm path.
    var cap_cwasm: std.ArrayList(u8) = .empty;
    defer cap_cwasm.deinit(testing.allocator);
    var cap_wasm: std.ArrayList(u8) = .empty;
    defer cap_wasm.deinit(testing.allocator);
    const code_c = try runWasmJitCaptured(testing.allocator, testing.io, cwasm, "f", &.{}, &.{}, &.{}, &.{}, .{}, &cap_cwasm, null, .none);
    const code_w = try runWasmJitCaptured(testing.allocator, testing.io, &wasm, "f", &.{}, &.{}, &.{}, &.{}, .{}, &cap_wasm, null, .none);
    try testing.expectEqual(code_w, code_c);
    try testing.expectEqual(@as(u8, 0), code_c);
    try testing.expectEqualStrings("42\n", cap_cwasm.items);
    try testing.expectEqualStrings(cap_wasm.items, cap_cwasm.items);
    // A missing name is a loud ExportNotFound — same error as the .wasm path.
    try testing.expectError(error.ExportNotFound, runWasmJitCaptured(testing.allocator, testing.io, cwasm, "nope", &.{}, &.{}, &.{}, &.{}, .{}, null, null, .none));
}

test "cwasm honors --fuel: a long loop traps out-of-fuel like the .wasm path (ADR-0203 stage 3)" {
    // DA-critique check #7 coverage: the ADR-0179 limits refusal for .cwasm
    // was removed on the claim that the shared core wires limits — pin it.
    // The loop is FINITE (1M iterations): without fuel wiring it would
    // COMPLETE (exit 0), with wiring it traps → exit 1. No hang either way.
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);

    const runner = @import("../engine/runner.zig");
    const aot_produce = @import("../engine/codegen/aot/produce.zig");

    // (module (func (export "_start") (local i32)
    //   (loop (br_if 0 (i32.lt_u (local.tee 0 (i32.add (local.get 0) (i32.const 1))) (i32.const 1000000))))))
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
        0x74, 0x61, 0x72, 0x74, 0x00, 0x00,
        // code: locals 1×i32; loop; local.get 0; i32.const 1; i32.add;
        // local.tee 0; i32.const 1000000; i32.lt_u; br_if 0; end; end
        0x0a, 0x17,
        0x01, 0x15, 0x01, 0x01, 0x7f, 0x03, 0x40, 0x20,
        0x00, 0x41, 0x01, 0x6a, 0x22, 0x00, 0x41, 0xc0,
        0x84, 0x3d, 0x49, 0x0d, 0x00, 0x0b, 0x0b,
    };

    var compiled = try runner.compileWasmForAot(testing.allocator, &wasm);
    const cwasm = blk: {
        defer compiled.deinit(testing.allocator);
        break :blk try aot_produce.produceFromCompiledWasm(testing.allocator, &compiled, &wasm);
    };
    defer testing.allocator.free(cwasm);

    // No fuel: the loop completes → exit 0.
    try testing.expectEqual(@as(u8, 0), try runWasmJitCaptured(testing.allocator, testing.io, cwasm, null, &.{}, &.{}, &.{}, &.{}, .{}, null, null, .none));
    // Tiny fuel: the SAME artifact traps out-of-fuel → exit 1 (parity with
    // the .wasm lane below) — the limit provably reaches the artifact code.
    const limited: Limits = .{ .fuel = 100 };
    try testing.expectEqual(@as(u8, 1), try runWasmJitCaptured(testing.allocator, testing.io, cwasm, null, &.{}, &.{}, &.{}, &.{}, limited, null, null, .none));
    try testing.expectEqual(@as(u8, 1), try runWasmJitCaptured(testing.allocator, testing.io, &wasm, null, &.{}, &.{}, &.{}, &.{}, limited, null, null, .none));
}

test "cwasm honors --invoke NAME=ARGS: typed args route through the embedded bytes (ADR-0203 stage 3)" {
    // DA-critique check #7 coverage: packJitInvokeArgs-over-wasm_view never
    // executed against an artifact in any suite — pin the parity.
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);

    const runner = @import("../engine/runner.zig");
    const aot_produce = @import("../engine/codegen/aot/produce.zig");

    // (module (func (export "add") (param i32 i32) (result i32)
    //   local.get 0  local.get 1  i32.add))
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0a, 0x09,
        0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a,
        0x0b,
    };

    var compiled = try runner.compileWasmForAot(testing.allocator, &wasm);
    const cwasm = blk: {
        defer compiled.deinit(testing.allocator);
        break :blk try aot_produce.produceFromCompiledWasm(testing.allocator, &compiled, &wasm);
    };
    defer testing.allocator.free(cwasm);

    var cap_cwasm: std.ArrayList(u8) = .empty;
    defer cap_cwasm.deinit(testing.allocator);
    var cap_wasm: std.ArrayList(u8) = .empty;
    defer cap_wasm.deinit(testing.allocator);
    const code_c = try runWasmJitCaptured(testing.allocator, testing.io, cwasm, "add", &.{}, &.{}, &.{}, &.{}, .{}, &cap_cwasm, "2,3", .none);
    const code_w = try runWasmJitCaptured(testing.allocator, testing.io, &wasm, "add", &.{}, &.{}, &.{}, &.{}, .{}, &cap_wasm, "2,3", .none);
    try testing.expectEqual(code_w, code_c);
    try testing.expectEqualStrings("5\n", cap_cwasm.items);
    try testing.expectEqualStrings(cap_wasm.items, cap_cwasm.items);
}

test "runCwasmWasi: a WASI proc_exit(42) .cwasm surfaces exit code 42 end-to-end (D-251)" {
    // The exit-condition observable for the D-251-aot-wasi bundle: a
    // WASI-importing `.cwasm` does REAL WASI under standalone AOT run. Executes
    // native AOT machine code → Win64-deferred (mirrors the jit_mem exec tests).
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);

    const runner = @import("../engine/runner.zig");
    const aot_produce = @import("../engine/codegen/aot/produce.zig");

    var compiled = try runner.compileWasmForAot(testing.allocator, &proc_exit_42_wasm);
    defer compiled.deinit(testing.allocator);
    const cwasm = try aot_produce.produceFromCompiledWasm(testing.allocator, &compiled, &proc_exit_42_wasm);
    defer testing.allocator.free(cwasm);

    // main calls proc_exit(42) → host records exit_code → JIT trap → 42 surfaces.
    const code = try runCwasmWasi(testing.allocator, testing.io, cwasm, null, &.{}, &.{}, &.{}, &.{}, null);
    try testing.expectEqual(@as(u8, 42), code);
}

// `_start` builds an iovec {buf=8,len=3} for the active-data string "hi\n" and
// calls fd_write(fd=1, ...). Exercises the fd_write WASI handler (a returning
// syscall that writes guest memory + routes to the host stdout buffer) under
// standalone AOT — a different handler path than the trapping proc_exit test,
// and the only `zig build test` (host-portable) caller of runCwasmWasi's
// stdout_capture param (the realworld --aot lane is Mac+wasmtime-gated). D-251.
const fd_write_hi_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0c, 0x02, 0x60, 0x04, 0x7f, 0x7f, 0x7f,
    0x7f, 0x01, 0x7f, 0x60, 0x00, 0x00, 0x02, 0x23, 0x01, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73,
    0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31,
    0x08, 0x66, 0x64, 0x5f, 0x77, 0x72, 0x69, 0x74, 0x65, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01, 0x05,
    0x03, 0x01, 0x00, 0x01, 0x07, 0x13, 0x02, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,
    0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x01, 0x0a, 0x1d, 0x01, 0x1b, 0x00, 0x41, 0x00,
    0x41, 0x08, 0x36, 0x02, 0x00, 0x41, 0x04, 0x41, 0x03, 0x36, 0x02, 0x00, 0x41, 0x01, 0x41, 0x00,
    0x41, 0x01, 0x41, 0x14, 0x10, 0x00, 0x1a, 0x0b, 0x0b, 0x09, 0x01, 0x00, 0x41, 0x08, 0x0b, 0x03,
    0x68, 0x69, 0x0a,
};

test "runCwasmWasi: a WASI fd_write .cwasm writes 'hi\\n' to the captured stdout (D-251)" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);

    const runner = @import("../engine/runner.zig");
    const aot_produce = @import("../engine/codegen/aot/produce.zig");

    var compiled = try runner.compileWasmForAot(testing.allocator, &fd_write_hi_wasm);
    defer compiled.deinit(testing.allocator);
    const cwasm = try aot_produce.produceFromCompiledWasm(testing.allocator, &compiled, &fd_write_hi_wasm);
    defer testing.allocator.free(cwasm);

    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    const code = try runCwasmWasi(testing.allocator, testing.io, cwasm, null, &.{}, &.{}, &.{}, &.{}, &capture);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("hi\n", capture.items);
}

test "runWasmJit: SIMD _start runs via the JIT where the interp traps (ADR-0136 / D-244)" {
    // Interpreter path: no SIMD execution → the `i32x4.add` dispatch slot is
    // null → Trap.Unreachable, which the run path maps to a non-zero exit
    // code (a trap is exit≠0, not a Zig error). D-496: force `.interp` — the
    // post-flip default `.auto` would run SIMD on the JIT (this leg is the foil).
    const interp_code = try runWasmCapturedOpts(testing.allocator, testing.io, &simd_start_wasm, &.{}, null, null, &.{}, &.{}, &.{}, null, .{ .engine = .interp });
    try testing.expect(interp_code != 0);

    // JIT path: compiles + runs the SIMD `_start` to completion → 0.
    const jit_code = try runWasmJit(testing.allocator, testing.io, &simd_start_wasm, null, &.{}, &.{}, &.{}, &.{}, .{});
    try testing.expectEqual(@as(u8, 0), jit_code);
}

// D-244 chunk 2c: a `_start` that calls clock_time_get and traps (unreachable)
// when the loaded time is 0. `runWasmJit` now attaches a WASI host, so the JIT
// clock is REAL (nonzero) → no trap → exit 0. Without the host attachment this
// would trap. Proves `--engine jit` does real WASI end-to-end.
const clock_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0b, 0x02, 0x60, 0x03, 0x7f, 0x7e, 0x7f,
    0x01, 0x7f, 0x60, 0x00, 0x00, 0x02, 0x29, 0x01, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e,
    0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x0e,
    0x63, 0x6c, 0x6f, 0x63, 0x6b, 0x5f, 0x74, 0x69, 0x6d, 0x65, 0x5f, 0x67, 0x65, 0x74, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x01, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74,
    0x61, 0x72, 0x74, 0x00, 0x01, 0x0a, 0x17, 0x01, 0x15, 0x00, 0x41, 0x00, 0x42, 0x00, 0x41, 0x00,
    0x10, 0x00, 0x1a, 0x41, 0x00, 0x29, 0x03, 0x00, 0x50, 0x04, 0x40, 0x00, 0x0b, 0x0b,
};

test "runWasmJit: --engine jit attaches a WASI host → real clock, no trap (D-244 2c)" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);
    // Host attached → real (nonzero) clock → the trap-if-zero guard passes → 0.
    const code = try runWasmJit(testing.allocator, testing.io, &clock_start_wasm, null, &.{}, &.{}, &.{}, &.{}, .{});
    try testing.expectEqual(@as(u8, 0), code);
}

test "runCwasmWasi: AOT clock_time_get reads a real (nonzero) host clock (D-251)" {
    // Completes the AOT-WASI syscall test matrix (proc_exit / fd_write / args /
    // preopen / clock — the distinct handler shapes). clock_start_wasm's _start
    // traps if the loaded time is 0; an attached host → real nonzero clock →
    // no trap → exit 0. Native AOT exec → Win64-deferred.
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);

    const runner = @import("../engine/runner.zig");
    const aot_produce = @import("../engine/codegen/aot/produce.zig");

    var compiled = try runner.compileWasmForAot(testing.allocator, &clock_start_wasm);
    defer compiled.deinit(testing.allocator);
    const cwasm = try aot_produce.produceFromCompiledWasm(testing.allocator, &compiled, &clock_start_wasm);
    defer testing.allocator.free(cwasm);

    const code = try runCwasmWasi(testing.allocator, testing.io, cwasm, null, &.{}, &.{}, &.{}, &.{}, null);
    try testing.expectEqual(@as(u8, 0), code);
}

// D-244 chunk 2d: `_start` calls proc_exit(42).
const proc_exit_42_jit = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60,
    0x00, 0x00, 0x02, 0x24, 0x01, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73,
    0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6f,
    0x63, 0x5f, 0x65, 0x78, 0x69, 0x74, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01, 0x07, 0x0a, 0x01, 0x06,
    0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x01, 0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x2a, 0x10,
    0x00, 0x0b,
};

test "runWasmJit: --engine jit surfaces the guest proc_exit code (D-244 2d)" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);
    const code = try runWasmJit(testing.allocator, testing.io, &proc_exit_42_jit, null, &.{}, &.{}, &.{}, &.{}, .{});
    try testing.expectEqual(@as(u8, 42), code);
}

// `test/wasi/stdin_echo.wat` (issue #257): fd_read ≤32 bytes from fd 0,
// fd_write them to fd 1, proc_exit(nread).
const stdin_echo_wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03, 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00, 0x02, 0x67, 0x03, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x07, 0x66, 0x64, 0x5f, 0x72, 0x65, 0x61, 0x64, 0x00, 0x00, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x08, 0x66, 0x64, 0x5f, 0x77, 0x72, 0x69, 0x74, 0x65, 0x00, 0x00, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6f, 0x63, 0x5f, 0x65, 0x78, 0x69, 0x74, 0x00, 0x01, 0x03, 0x02, 0x01, 0x02, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x13, 0x02, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x03, 0x0a, 0x5e, 0x01, 0x5c, 0x01, 0x02, 0x7f, 0x03, 0x40, 0x41, 0x00, 0x41, 0xc0, 0x00, 0x36, 0x02, 0x00, 0x41, 0x04, 0x41, 0x20, 0x36, 0x02, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x01, 0x41, 0x10, 0x10, 0x00, 0x21, 0x01, 0x20, 0x01, 0x04, 0x40, 0x41, 0xe4, 0x00, 0x20, 0x01, 0x6a, 0x10, 0x02, 0x0b, 0x41, 0x10, 0x28, 0x02, 0x00, 0x04, 0x40, 0x41, 0x04, 0x41, 0x10, 0x28, 0x02, 0x00, 0x36, 0x02, 0x00, 0x41, 0x01, 0x41, 0x00, 0x41, 0x01, 0x41, 0x14, 0x10, 0x01, 0x1a, 0x20, 0x00, 0x41, 0x10, 0x28, 0x02, 0x00, 0x6a, 0x21, 0x00, 0x0c, 0x01, 0x0b, 0x0b, 0x20, 0x00, 0x10, 0x02, 0x0b, 0x00, 0x43, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01, 0x1f, 0x03, 0x00, 0x07, 0x66, 0x64, 0x5f, 0x72, 0x65, 0x61, 0x64, 0x01, 0x08, 0x66, 0x64, 0x5f, 0x77, 0x72, 0x69, 0x74, 0x65, 0x02, 0x09, 0x70, 0x72, 0x6f, 0x63, 0x5f, 0x65, 0x78, 0x69, 0x74, 0x02, 0x0f, 0x01, 0x03, 0x02, 0x00, 0x05, 0x74, 0x6f, 0x74, 0x61, 0x6c, 0x01, 0x03, 0x65, 0x72, 0x72, 0x03, 0x0a, 0x01, 0x03, 0x01, 0x00, 0x05, 0x61, 0x67, 0x61, 0x69, 0x6e };

test "a stdin byte slice reaches the guest's fd 0 on both engines; none = EOF (#257)" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);
    var cap_jit: std.ArrayList(u8) = .empty;
    defer cap_jit.deinit(testing.allocator);
    const jit = try runWasmJitCaptured(testing.allocator, testing.io, &stdin_echo_wasm, null, &.{}, &.{}, &.{}, &.{}, .{}, &cap_jit, null, .{ .bytes = "hello\n" });
    try testing.expectEqual(@as(u8, 6), jit);
    try testing.expectEqualStrings("hello\n", cap_jit.items);

    var cap_interp: std.ArrayList(u8) = .empty;
    defer cap_interp.deinit(testing.allocator);
    const interp = try runWasmCapturedFull(testing.allocator, testing.io, &stdin_echo_wasm, &.{}, &cap_interp, null, .{ .bytes = "hello\n" }, null, &.{}, &.{}, &.{}, null, .{ .engine = .interp });
    try testing.expectEqual(@as(u8, 6), interp);
    try testing.expectEqualStrings("hello\n", cap_interp.items);

    var cap_eof: std.ArrayList(u8) = .empty;
    defer cap_eof.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), try runWasmJitCaptured(testing.allocator, testing.io, &stdin_echo_wasm, null, &.{}, &.{}, &.{}, &.{}, .{}, &cap_eof, null, .none));
    try testing.expectEqual(@as(usize, 0), cap_eof.items.len);
}

// `(module (func (export "_start") unreachable))` — a genuine trap with NO
// recorded exit_code. The interp path treats a trap as exit≠0 (a code, NOT a
// Zig error; see the SIMD test). The JIT path must match: surface the kind on
// stderr then RETURN exit 1, NOT re-raise error.Trap (which would make
// main.zig's renderFallback print a SECOND `Trap` line). Interp-parity per
// ADR-0164 workstream A.
const unreachable_start_jit = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x05,
    0x01, 0x03, 0x00, 0x00, 0x0b,
};

test "runWasmJit: a genuine trap maps to exit 1, not a propagated error (ADR-0164 A parity)" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);
    const code = try runWasmJit(testing.allocator, testing.io, &unreachable_start_jit, null, &.{}, &.{}, &.{}, &.{}, .{});
    try testing.expectEqual(@as(u8, 1), code);
}

// D-244 chunk 2d-rest: `_start` calls args_sizes_get then proc_exit(argc).
const argc_exit_jit = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0e, 0x03, 0x60, 0x02, 0x7f, 0x7f, 0x01,
    0x7f, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00, 0x02, 0x4c, 0x02, 0x16, 0x77, 0x61, 0x73, 0x69,
    0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65,
    0x77, 0x31, 0x0e, 0x61, 0x72, 0x67, 0x73, 0x5f, 0x73, 0x69, 0x7a, 0x65, 0x73, 0x5f, 0x67, 0x65,
    0x74, 0x00, 0x00, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f,
    0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6f, 0x63, 0x5f,
    0x65, 0x78, 0x69, 0x74, 0x00, 0x01, 0x03, 0x02, 0x01, 0x02, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07,
    0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x02, 0x0a, 0x12, 0x01, 0x10, 0x00,
    0x41, 0x00, 0x41, 0x04, 0x10, 0x00, 0x1a, 0x41, 0x00, 0x28, 0x02, 0x00, 0x10, 0x01, 0x0b,
};

test "runCwasmWasi: threads argv → AOT guest args_sizes_get sees argc (D-251)" {
    // Mirror the JIT argv test on standalone AOT: argc_exit_jit's _start calls
    // args_sizes_get then proc_exit(argc). Verifies runCwasmWasi's argv →
    // host.setArgs threading reaches the AOT args_sizes_get syscall. Completes
    // the args/stdout/exit AOT-WASI trio. Native AOT exec → Win64-deferred.
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);

    const runner = @import("../engine/runner.zig");
    const aot_produce = @import("../engine/codegen/aot/produce.zig");

    var compiled = try runner.compileWasmForAot(testing.allocator, &argc_exit_jit);
    defer compiled.deinit(testing.allocator);
    const cwasm = try aot_produce.produceFromCompiledWasm(testing.allocator, &compiled, &argc_exit_jit);
    defer testing.allocator.free(cwasm);

    // argv = {prog, a, b} → argc 3 → the guest proc_exits with it.
    const code = try runCwasmWasi(testing.allocator, testing.io, cwasm, null, &.{ "prog", "a", "b" }, &.{}, &.{}, &.{}, null);
    try testing.expectEqual(@as(u8, 3), code);
}

test "runWasmJit: --engine jit threads argv → guest args_sizes_get sees argc (D-244 2d)" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);
    // argv = {prog, a, b} → argc 3 → the guest proc_exits with it.
    const code = try runWasmJit(testing.allocator, testing.io, &argc_exit_jit, null, &.{ "prog", "a", "b" }, &.{}, &.{}, &.{}, .{});
    try testing.expectEqual(@as(u8, 3), code);
}

// D-244: `_start` proc_exits with `fd_prestat_get(3, &prestat)`'s errno —
// success(0) when fd 3 is a preopen dir, badf(8) when there is none.
const prestat_jit = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0e, 0x03, 0x60, 0x02, 0x7f, 0x7f, 0x01,
    0x7f, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00, 0x02, 0x4c, 0x02, 0x16, 0x77, 0x61, 0x73, 0x69,
    0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65,
    0x77, 0x31, 0x0e, 0x66, 0x64, 0x5f, 0x70, 0x72, 0x65, 0x73, 0x74, 0x61, 0x74, 0x5f, 0x67, 0x65,
    0x74, 0x00, 0x00, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f,
    0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6f, 0x63, 0x5f,
    0x65, 0x78, 0x69, 0x74, 0x00, 0x01, 0x03, 0x02, 0x01, 0x02, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07,
    0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x02, 0x0a, 0x0c, 0x01, 0x0a, 0x00,
    0x41, 0x03, 0x41, 0x00, 0x10, 0x00, 0x10, 0x01, 0x0b,
};

test "runCwasmWasi: --dir preopen makes the AOT fd_prestat_get(3) succeed (D-251)" {
    // Mirror the JIT prestat test on the standalone AOT path: the same
    // `prestat_jit` _start proc_exits with fd_prestat_get(3)'s errno — 0 when
    // fd 3 is a preopen dir, 8 (badf) without. Exercises runCwasmWasi's
    // preopens param + the AOT fd_prestat_get syscall. Native AOT exec → Win64-deferred.
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);

    const runner = @import("../engine/runner.zig");
    const aot_produce = @import("../engine/codegen/aot/produce.zig");

    var compiled = try runner.compileWasmForAot(testing.allocator, &prestat_jit);
    defer compiled.deinit(testing.allocator);
    const cwasm = try aot_produce.produceFromCompiledWasm(testing.allocator, &compiled, &prestat_jit);
    defer testing.allocator.free(cwasm);

    // Preopen cwd (".") → guest fd 3 is a valid preopen → prestat_get success (0).
    const code = try runCwasmWasi(testing.allocator, testing.io, cwasm, null, &.{}, &.{.{ .host_path = ".", .guest_path = "/sandbox" }}, &.{}, &.{}, null);
    try testing.expectEqual(@as(u8, 0), code);
    // No preopen → fd 3 is badf (8).
    const code2 = try runCwasmWasi(testing.allocator, testing.io, cwasm, null, &.{}, &.{}, &.{}, &.{}, null);
    try testing.expectEqual(@as(u8, 8), code2);
}

test "runWasmJit: --dir preopen makes the JIT's fd_prestat_get(3) succeed (D-244)" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);
    // Preopen the cwd (".") → guest fd 3 is a valid preopen dir → prestat_get
    // returns success (0).
    const code = try runWasmJit(testing.allocator, testing.io, &prestat_jit, null, &.{}, &.{.{ .host_path = ".", .guest_path = "/sandbox" }}, &.{}, &.{}, .{});
    try testing.expectEqual(@as(u8, 0), code);
    // No preopen → fd 3 is badf (8).
    const code2 = try runWasmJit(testing.allocator, testing.io, &prestat_jit, null, &.{}, &.{}, &.{}, &.{}, .{});
    try testing.expectEqual(@as(u8, 8), code2);
}

// D-284: `(module (func (export "init")))` — a void export, NO `_start` (the
// nbody shape). Pre-fix the JIT resolved `_start` ONLY → ExportNotFound (exit 1),
// while interp ran the first func export → exit 0. `runWasmJit` now uses the
// lenient `_start → main → first-func-export → instantiate-only` chain, matching
// `runWasm`(interp)/the CWAS lane (AOT) → SAME exit code (the D-284 discharge).
const no_start_init_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type ()->()
    0x03, 0x02, 0x01, 0x00, // func: 1 func, type 0
    0x07, 0x08, 0x01, 0x04, 0x69, 0x6e, 0x69, 0x74, 0x00, 0x00, // export "init" func 0
    0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code: 1 func, empty body
};

test "runWasmJit: no-_start module runs the first func export, jit==interp (D-284)" {
    const jit_code = try runWasmJit(testing.allocator, testing.io, &no_start_init_wasm, null, &.{}, &.{}, &.{}, &.{}, .{});
    const interp_code = try runWasm(testing.allocator, testing.io, &no_start_init_wasm, &.{});
    try testing.expectEqual(@as(u8, 0), jit_code); // was Error.ExportNotFound (exit 1) pre-fix
    try testing.expectEqual(interp_code, jit_code); // intra-zwasm agreement
}

// A WASI command that writes a 64-byte line to stdout forever, IGNORING the
// errno. Source + rebuild recipe: `test/wasi/spam_stdout.wat`
// (`wasm-tools parse test/wasi/spam_stdout.wat -o -`). Inline as bytes to match
// `prestat_jit` above — a run.zig test embeds its guest rather than reading a
// file, so the test needs no fixture path.
const spam_stdout = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0c, 0x02, 0x60, 0x04, 0x7f, 0x7f, 0x7f,
    0x7f, 0x01, 0x7f, 0x60, 0x00, 0x00, 0x02, 0x23, 0x01, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73,
    0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31,
    0x08, 0x66, 0x64, 0x5f, 0x77, 0x72, 0x69, 0x74, 0x65, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01, 0x05,
    0x03, 0x01, 0x00, 0x01, 0x07, 0x13, 0x02, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,
    0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x01, 0x0a, 0x24, 0x01, 0x22, 0x00, 0x41, 0x00,
    0x41, 0x08, 0x36, 0x02, 0x00, 0x41, 0x04, 0x41, 0xc0, 0x00, 0x36, 0x02, 0x00, 0x03, 0x40, 0x41,
    0x01, 0x41, 0x00, 0x41, 0x01, 0x41, 0xc8, 0x01, 0x10, 0x00, 0x1a, 0x0c, 0x00, 0x0b, 0x0b, 0x0b,
    0x46, 0x01, 0x00, 0x41, 0x08, 0x0b, 0x40, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
    0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
    0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
    0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
    0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x00, 0x1e, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01, 0x0b,
    0x01, 0x00, 0x08, 0x66, 0x64, 0x5f, 0x77, 0x72, 0x69, 0x74, 0x65, 0x03, 0x0a, 0x01, 0x01, 0x01,
    0x00, 0x05, 0x61, 0x67, 0x61, 0x69, 0x6e,
};

test "runWasmCapturedFull: max_output_bytes caps the C-API capture path too" {
    // The cap was first wired only onto `runWasmJitCaptured`'s host. The C-API
    // path builds its OWN host through `zwasm_wasi_config_new`, so it did not
    // inherit it, and ClojureWasm's `wasm/run` — which goes through here —
    // stayed uncapped at exactly the volume the axis exists to bound. A second
    // capture surface beside a hardened one does not inherit the hardening.
    //
    // The guest writes 64 bytes per iteration forever and IGNORES the errno, so
    // this holds against a guest that does not cooperate. Fuel is what ends the
    // run; the cap is what bounds the memory while it lasts.
    const spam = &spam_stdout;
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    var errbuf: std.ArrayList(u8) = .empty;
    defer errbuf.deinit(testing.allocator);

    _ = try runWasmCapturedFull(
        testing.allocator,
        testing.io,
        spam,
        &.{},
        &capture,
        &errbuf,
        .none,
        null,
        &.{},
        &.{},
        &.{},
        null,
        .{ .fuel = 200_000, .max_output_bytes = 4096 },
    );
    try testing.expectEqual(@as(usize, 4096), capture.items.len);

    // Uncapped, the same fuel buffers orders of magnitude more — the assertion
    // that makes the capped number mean something.
    var uncapped: std.ArrayList(u8) = .empty;
    defer uncapped.deinit(testing.allocator);
    var errbuf2: std.ArrayList(u8) = .empty;
    defer errbuf2.deinit(testing.allocator);
    _ = try runWasmCapturedFull(
        testing.allocator,
        testing.io,
        spam,
        &.{},
        &uncapped,
        &errbuf2,
        .none,
        null,
        &.{},
        &.{},
        &.{},
        null,
        .{ .fuel = 200_000 },
    );
    try testing.expect(uncapped.items.len > 100_000);
}
