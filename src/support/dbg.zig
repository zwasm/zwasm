//! Env-gated debug logger (ADR-0015 candidate).
//!
//! `dbg.print(comptime mod, fmt, args)` is a no-op unless the
//! whitelist (configured via `initFromEnv`) enables `mod` or one
//! of its prefixes — `interp` enables `interp.alloc`,
//! `interp.dispatch`, …. The value `*` enables every module; an
//! empty / null value disables every module.
//!
//! Compile-stripped in `ReleaseFast` / `ReleaseSmall` via a
//! `builtin.mode` guard — release builds emit zero code for the
//! call site (the comptime branch + `@compileLog`-free body
//! collapses).
//!
//! ## Initialization (D-009 refactor)
//!
//! Zone 0 (`src/support/`) cannot read process env directly:
//! `std.posix.getenv` was removed in Zig 0.16, and
//! `std.process.Environ.getPosix` needs a `std.process.Init`
//! that only a Zig `main` owns. That leaves `std.c.getenv`,
//! which ADR-0070 classifies Necessary for the c_api context
//! only — a new site here needs an ADR-0070 amendment (ROADMAP
//! §14 forbidden list; `.claude/rules/libc_boundary.md`). The
//! env value is plumbed down from Zone 3 entry points:
//!
//! - `cli/main.zig` reads `init.environ.getPosix("ZWASM_DEBUG")`
//!   and calls `dbg.initFromEnv(value)` at startup.
//! - `api/instance.zig:wasm_engine_new` reads `std.c.getenv`
//!   (libc-linked Zone 3 c_api context is OK) and calls
//!   `dbg.initFromEnv(value)` once per process.
//!
//! Until init is called, every `enabled(mod)` returns false (=
//! release-equivalent default).
//!
//! ## Usage
//!
//! ```zig
//! const dbg = @import("support/dbg.zig");
//!
//! dbg.print("interp.alloc", "rt={x} mem.ptr={x} len={d}", .{
//!     @intFromPtr(rt), @intFromPtr(mem.ptr), mem.len,
//! });
//! ```
//!
//! ```sh
//! ZWASM_DEBUG=interp.alloc zig build test 2>&1 | grep dbg
//! ZWASM_DEBUG=interp,c_api zig build test 2>&1
//! ZWASM_DEBUG=* zig build test 2>&1
//! ```
//!
//! Output goes to stderr via `std.debug.print`. Each line is
//! prefixed with `[dbg <mod>] ` so multiple modules' lines stay
//! distinguishable when several are enabled.
//!
//! Zone 0 (`src/support/`).

const std = @import("std");
const builtin = @import("builtin");

/// Whitelist of enabled module prefixes; populated by
/// `initFromEnv`. The whitelist itself is interned in a static
/// buffer to avoid relying on the GPA / arena.
const Whitelist = struct {
    /// `*` enables every module.
    everything: bool = false,
    /// Stable storage for the comma-split env value.
    buf: [4096]u8 = undefined,
    len: usize = 0,
    /// Pointers into `buf`; up to 64 entries.
    entries: [64][]const u8 = undefined,
    entry_count: usize = 0,
};

var whitelist: Whitelist = .{};
var whitelist_initialised: bool = false;

/// Configure the whitelist from a `ZWASM_DEBUG` env var value.
/// Pass `null` (or empty) to disable every module. Idempotent —
/// a second call replaces the prior whitelist.
///
/// Zone 0 (`support/`) declares the data shape; Zone 3 entry
/// points (`cli/main.zig`, `api/instance.zig:wasm_engine_new`)
/// read process env via their zone-appropriate API and pass the
/// value here. This keeps libc and `std.process.Init` out of
/// Zone 0.
pub fn initFromEnv(value: ?[]const u8) void {
    whitelist = .{};
    if (value) |v| {
        if (std.mem.eql(u8, v, "*")) {
            whitelist.everything = true;
            whitelist_initialised = true;
            return;
        }
        if (v.len == 0) {
            whitelist_initialised = true;
            return;
        }
        const copy_len = @min(v.len, whitelist.buf.len);
        @memcpy(whitelist.buf[0..copy_len], v[0..copy_len]);
        whitelist.len = copy_len;
        var it = std.mem.tokenizeScalar(u8, whitelist.buf[0..copy_len], ',');
        while (it.next()) |tok| {
            const trimmed = std.mem.trim(u8, tok, " \t");
            if (trimmed.len == 0) continue;
            if (whitelist.entry_count >= whitelist.entries.len) break;
            whitelist.entries[whitelist.entry_count] = trimmed;
            whitelist.entry_count += 1;
        }
    }
    whitelist_initialised = true;
}

fn enabled(comptime mod: []const u8) bool {
    // Release builds skip the env read entirely — call sites
    // collapse to nothing.
    if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
        return false;
    }
    // Pre-init: dbg is a no-op (= release-equivalent default).
    // Zone 0 has no env-read capability; init is the caller's
    // responsibility.
    if (!whitelist_initialised) return false;
    if (whitelist.everything) return true;
    var i: usize = 0;
    while (i < whitelist.entry_count) : (i += 1) {
        const e = whitelist.entries[i];
        // Prefix match: `interp` enables `interp.alloc`, but
        // `interp.alloc` does NOT enable `interp` (the more
        // specific filter wins from the developer's side). Skip
        // when `mod` is shorter than `e` — slice-from-empty is a
        // compile error in Zig 0.16 when both bounds are 0.
        if (mod.len == 0 or mod.len < e.len) continue;
        if (e.len > 0 and std.mem.eql(u8, mod[0..e.len], e)) {
            // Boundary: either exact match, or next char is `.`.
            if (mod.len == e.len) return true;
            if (mod[e.len] == '.') return true;
        }
    }
    return false;
}

/// Print `fmt`-formatted output to stderr if `mod` is enabled by
/// `ZWASM_DEBUG`. Comptime no-op in release builds.
pub fn print(comptime mod: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
        return;
    }
    if (!enabled(mod)) return;
    std.debug.print("[dbg " ++ mod ++ "] " ++ fmt ++ "\n", args);
}

/// Whether `mod` is enabled by `ZWASM_DEBUG` — the gate predicate
/// behind `print`, exposed for call sites that must emit
/// variable-shaped output (e.g. a hex byte dump) that a comptime
/// `fmt` cannot express. Comptime no-op in release builds, same as
/// `print`. Pair with `std.debug.print` inside the guarded block.
pub fn on(comptime mod: []const u8) bool {
    return enabled(mod);
}

/// Whether ANY `ZWASM_DEBUG` channel is active — the AOT-produce refusal
/// predicate (ADR-0203 stage 2 / D-519): dbg-instrumented codegen (e.g.
/// `jit.callcount`, `global.trace`) bakes this process's diagnostic-counter
/// addresses into emitted code, which must never be serialized into a
/// `.cwasm`. Comptime-false in release builds like `on`.
pub fn anyActive() bool {
    if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
        return false;
    }
    if (!whitelist_initialised) return false;
    return whitelist.everything or whitelist.entry_count > 0;
}

/// FNV-1a 64-bit hash — a tiny, dependency-free content checksum used by the
/// `mem.cksum` diagnostic (D-331A) to fingerprint linear memory at host-call
/// boundaries and diff an interp run against a JIT run (first divergent boundary
/// localizes a miscompile). Pure; not gated (the caller gates on `on("mem.cksum")`).
pub fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

/// Force-disable the cached whitelist. Test-only: lets a unit test
/// re-evaluate `ZWASM_DEBUG` after mutating the process env.
pub fn resetForTest() void {
    whitelist = .{};
    whitelist_initialised = false;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "enabled: pre-init returns false (Zone 0 default)" {
    resetForTest();
    try testing.expect(!enabled("any"));
    try testing.expect(!enabled("interp.alloc"));
}

test "enabled: initFromEnv(null) disables every module" {
    resetForTest();
    initFromEnv(null);
    defer resetForTest();
    try testing.expect(!enabled("any"));
    try testing.expect(!enabled("interp.alloc"));
}

test "enabled: initFromEnv(\"\") disables every module" {
    resetForTest();
    initFromEnv("");
    defer resetForTest();
    try testing.expect(!enabled("any"));
}

test "enabled: prefix match — `interp` enables `interp.alloc`" {
    resetForTest();
    initFromEnv("interp");
    defer resetForTest();
    try testing.expect(enabled("interp"));
    try testing.expect(enabled("interp.alloc"));
    try testing.expect(enabled("interp.dispatch"));
    try testing.expect(!enabled("c_api"));
    try testing.expect(!enabled("interpolate")); // boundary check
}

test "enabled: more specific entry doesn't enable the parent" {
    resetForTest();
    initFromEnv("interp.alloc");
    defer resetForTest();
    try testing.expect(enabled("interp.alloc"));
    try testing.expect(!enabled("interp"));
    try testing.expect(!enabled("interp.dispatch"));
}

test "enabled: `*` enables every module" {
    resetForTest();
    initFromEnv("*");
    defer resetForTest();
    try testing.expect(enabled("anything"));
    try testing.expect(enabled("interp.alloc"));
}

test "on: mirrors enabled (gate predicate for variable-shaped output)" {
    resetForTest();
    initFromEnv("jit.dump");
    defer resetForTest();
    try testing.expect(on("jit.dump"));
    try testing.expect(!on("jit"));
    try testing.expect(!on("interp"));
}

test "enabled: comma-separated whitelist" {
    resetForTest();
    initFromEnv("interp,c_api,emit");
    defer resetForTest();
    try testing.expect(enabled("interp"));
    try testing.expect(enabled("interp.alloc"));
    try testing.expect(enabled("c_api"));
    try testing.expect(enabled("emit"));
    try testing.expect(!enabled("validate"));
}
