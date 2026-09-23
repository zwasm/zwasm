//! Top-level CLI verb classification — pure + testable. `main.zig`
//! routes on the returned `Action`; `run` / `compile` keep their own
//! per-subcommand arg parsing. Splitting the top-level routing out
//! here is what makes the CLI surface (ADR-0159: run + compile +
//! --version/--help) unit-testable without spawning the exe.
//!
//! Zone 3 (`src/cli/`).

const std = @import("std");

pub const Action = enum { banner, help, version, run, compile, unknown };

/// Classify the first CLI token. `null` (no subcommand) = the
/// version + build-options banner. An unrecognised token is
/// `.unknown` (a typo) rather than an implicit file-run — the
/// surface is explicit (`zwasm run <file>`), no bare-file shortcut.
pub fn classify(subcmd: ?[]const u8) Action {
    const s = subcmd orelse return .banner;
    if (eq(s, "--help") or eq(s, "-h") or eq(s, "help")) return .help;
    if (eq(s, "--version") or eq(s, "-V")) return .version;
    if (eq(s, "run")) return .run;
    if (eq(s, "compile")) return .compile;
    return .unknown;
}

inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Format the canonical `--version` line: version + build identity, so a
/// distributed binary's `zwasm --version` reveals which wasm/wasi/engine
/// build it is (previously only the no-arg banner showed this; the version
/// flag is the authoritative build identity, wasmtime-aligned). `mode` is the
/// optimize mode it was built at: a harness that drives this binary can then
/// check what it is about to measure instead of trusting the wiring that
/// produced it (D-598). All of them are passed in as `@tagName` strings to
/// keep this pure (no build_options coupling) and unit-testable.
pub fn versionLine(buf: []u8, version: []const u8, wasm_level: []const u8, wasi_level: []const u8, engine: []const u8, mode: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "zwasm v{s} (wasm: {s}, wasi: {s}, engine: {s}, mode: {s})\n",
        .{ version, wasm_level, wasi_level, engine, mode },
    ) catch "zwasm\n";
}

pub const usage =
    \\zwasm — a WebAssembly runtime
    \\
    \\Usage:
    \\  zwasm run <file.wasm|file.cwasm> [args...]   Run a module (WASI _start / main)
    \\    [--invoke <name>[=a,b,...]]                Invoke a named export (optional call args)
    \\    [--engine <auto|interp|jit>]                    Engine: default auto (prefers JIT, interp fallback); interp|jit force one (both full WASI; jit adds SIMD)
    \\    [--dir <host>[:<guest>]]                   Preopen a host directory for WASI
    \\    [--env <KEY=VAL>]                          Set an environment variable for the guest
    \\    [--fuel <N>]                               Trap after a fuel budget (units are engine-specific:
    \\                                               interp = instructions, jit = function entries + loop iterations)
    \\    [--timeout <ms>]                           Interrupt the guest after a wall-clock deadline
    \\    [--max-memory <bytes>]                     Refuse memory.grow past this many bytes (64 KiB page granularity)
    \\    [--max-table-elements <N>]                 Refuse table growth/alloc past this many elements
    \\    [--cache[=DIR]]                            Transparent compilation cache (content-keyed .cwasm reuse)
    \\    [--cache-clear]                            Delete this build's cache subdirectory (combine with --cache to repopulate)
    \\  zwasm compile <file.wasm> -o <out.cwasm>     Compile to a .cwasm AOT artifact
    \\  zwasm --version | -V                         Print the version + build identity
    \\  zwasm --help | -h | help                     Print this help
    \\  zwasm                                        Print version + build options
    \\
;

test "classify: known verbs" {
    try std.testing.expectEqual(Action.run, classify("run"));
    try std.testing.expectEqual(Action.compile, classify("compile"));
}

test "classify: help + version flags and aliases" {
    try std.testing.expectEqual(Action.help, classify("--help"));
    try std.testing.expectEqual(Action.help, classify("-h"));
    try std.testing.expectEqual(Action.help, classify("help"));
    try std.testing.expectEqual(Action.version, classify("--version"));
    try std.testing.expectEqual(Action.version, classify("-V"));
}

test "classify: null is banner, unknown token is unknown" {
    try std.testing.expectEqual(Action.banner, classify(null));
    try std.testing.expectEqual(Action.unknown, classify("bogus"));
    try std.testing.expectEqual(Action.unknown, classify("foo.wasm"));
}

test "versionLine: carries version + wasm/wasi/engine/mode build identity" {
    var buf: [192]u8 = undefined;
    const line = versionLine(&buf, "9.9.9", "wasm_3_0", "wasi_0_2", "interp_only", "ReleaseSafe");
    try std.testing.expect(std.mem.find(u8, line, "zwasm v9.9.9") != null);
    try std.testing.expect(std.mem.find(u8, line, "wasm: wasm_3_0") != null);
    try std.testing.expect(std.mem.find(u8, line, "wasi: wasi_0_2") != null);
    try std.testing.expect(std.mem.find(u8, line, "engine: interp_only") != null);
    try std.testing.expect(std.mem.find(u8, line, "mode: ReleaseSafe") != null);
}

test "usage text names both shipped subcommands + every run flag main.zig parses" {
    try std.testing.expect(std.mem.find(u8, usage, "zwasm run ") != null);
    try std.testing.expect(std.mem.find(u8, usage, "zwasm compile ") != null);
    // Lock doc/code coherence: every flag `run` actually accepts (main.zig)
    // must be documented, so help can't silently drop one again (--env did).
    try std.testing.expect(std.mem.find(u8, usage, "--invoke") != null);
    try std.testing.expect(std.mem.find(u8, usage, "--engine") != null);
    try std.testing.expect(std.mem.find(u8, usage, "--dir") != null);
    try std.testing.expect(std.mem.find(u8, usage, "--env") != null);
    // ADR-0179 #3a-4 / D-314 — the sandboxing triad flags.
    try std.testing.expect(std.mem.find(u8, usage, "--fuel") != null);
    try std.testing.expect(std.mem.find(u8, usage, "--timeout") != null);
    try std.testing.expect(std.mem.find(u8, usage, "--max-memory") != null);
    try std.testing.expect(std.mem.find(u8, usage, "--max-table-elements") != null);
}
