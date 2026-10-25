//! Diagnostic M3-a trace ringbuffer (per ADR-0028).
//!
//! Per-thread fixed-size ring buffer of structured `TraceEntry`
//! records. Used to capture compile-time and (eventually) trap-
//! time events for post-mortem diagnosis without per-event
//! syscall overhead.
//!
//! M3-a-1 scope (this commit): ringbuffer infrastructure +
//! `bounds` category (compile-time write at memory-op emit
//! sites). Trap-time write from JIT stub is M3-a-2 (separate
//! chunk; requires trap stub → drain helper call calling-
//! convention coordination).
//!
//! Compile-time gate: `build_options.trace_ringbuffer` controls
//! whether write functions execute meaningfully or fold to
//! no-ops. Per ROADMAP §A12 the gate is **not** a runtime `if`
//! in hot dispatch paths; it's a `comptime` branch consumed by
//! every write site, so release builds with `-Dtrace-ringbuffer=
//! false` (default) emit zero trace code.
//!
//! Storage is `threadlocal` per ADR-0028 D-021 cross-reference.
//! Phase 14 multi-thread re-architecture happens alongside
//! Diagnostic's threadlocal slot (same reasoning, same migration).
//!
//! Zone 1 (`src/diagnostic/`).

const std = @import("std");
const build_options = @import("build_options");

/// Whether the trace ringbuffer is compiled in. Off by default
/// (see `build.zig` `-Dtrace-ringbuffer` flag). When false, all
/// write functions fold to no-ops via `comptime` branches and
/// the threadlocal storage slot drops out as dead state.
pub const enabled: bool = build_options.trace_ringbuffer;

/// Trace event category. 4-bit encoding (16 slots reserved;
/// 7 used today, 9 spare).
pub const Category = enum(u4) {
    /// Per-memory-op emit (M3-a-1: bounds-check site offset).
    bounds = 0,
    /// Per-trap entry (M3-a-2: trap stub records kind + pc).
    trap = 1,
    /// Per-allocation-decision (M3-b).
    regalloc = 2,
    /// Per-function compile boundary (M3-b).
    jit = 3,
    /// Per-call boundary interp ↔ JIT (M3-c).
    exec = 4,
    /// Per-ZIR-instr (M3-c; high overhead).
    regir = 5,
    /// Per-pass enter / exit (§9.8a / 8a.1; ADR-0033).
    pass = 6,
    _,
};

/// Per-category event tag. 4-bit; layout depends on Category.
/// `bounds` events use only `.emit_check`; future categories
/// add their own variants. Numeric values may collide across
/// categories (e.g. `bounds.emit_check = 0` and
/// `pass.pass_enter = 0`); the reader disambiguates via the
/// `category` field.
pub const Event = enum(u4) {
    emit_check = 0,
    _,
};

/// Per-pass event tag (Category.pass). Numeric values overlap
/// with `Event` by design — callers convert via
/// `@enumFromInt(@intFromEnum(pe))` when writing the entry's
/// 4-bit `event` slot. Per ADR-0033.
pub const PassEvent = enum(u4) {
    pass_enter = 0,
    pass_exit = 1,
    _,
};

/// Pipeline pass identity (Category.pass). 8-bit catalogue;
/// 6 known + 250 spare slots for §9.8b coalescer / regalloc-
/// upgrade / aot follow-ups. Per ADR-0033.
pub const PassId = enum(u8) {
    lower = 0,
    loop_info = 1,
    hoist = 2,
    liveness = 3,
    regalloc = 4,
    emit = 5,
    _,
};

/// Per-pass summary (`Category.pass`, `pass_exit` event).
/// `applied` / `skipped` carry the cross-pass-shared counters;
/// `extra` is interpreted per-pass at the call site (documented
/// per `ADR-0033` table). The full struct is stored in
/// `ZirFunc.pass_diagnostics` (8a.1-c slot); the ringbuffer
/// only carries `digest()` packed into `payload_b`.
pub const PassSummary = struct {
    applied: u32 = 0,
    skipped: u32 = 0,
    extra: u32 = 0,

    /// Pack `applied` (low 16 bits, saturating) +
    /// `skipped` (high 16 bits, saturating) into the
    /// ringbuffer's `payload_b: u32` slot. Lossy by design;
    /// callers wanting exact counts read
    /// `ZirFunc.pass_diagnostics`. Per ADR-0033.
    pub fn digest(self: PassSummary) u32 {
        const lo: u32 = @min(self.applied, std.math.maxInt(u16));
        const hi: u32 = @min(self.skipped, std.math.maxInt(u16));
        return (hi << 16) | lo;
    }
};

/// 8-byte packed entry (one cache line per 8 entries).
///
/// `payload_a` / `payload_b` semantics are category-specific;
/// the trace dump consumer interprets them via Category +
/// Event. For Category=.bounds Event=.emit_check:
///   payload_a = func_idx (u24; truncated if Wasm module has
///               > 16M funcs — far beyond any realistic Wasm
///               module size)
///   payload_b = byte_offset_within_func (u32; full 4 GiB
///               function body addressable, no truncation)
///
/// Layout (64 bits total): cat(4) + event(4) + payload_a(24) +
/// payload_b(32) = 64. Timestamp / cycle counter is dropped at
/// M3-a-1 in favour of `head` ordering (see `writeEntry` /
/// `drain` for chronological reconstruction).
pub const TraceEntry = packed struct(u64) {
    category: Category,
    event: Event,
    payload_a: u24,
    payload_b: u32,
};

/// Ring buffer capacity in entries. 32 = 256 bytes, fits 4
/// cache lines on 64-byte-line machines. Sized to capture
/// the typical "last 8 events before trap" window 4× over.
pub const capacity: usize = 32;

/// Per-thread ring buffer state. Lives only when `enabled`
/// (otherwise dead state, optimised out by LLVM).
const Ring = struct {
    entries: [capacity]TraceEntry,
    /// Total writes since last `clear` — the consumer mod-`capacity`
    /// to find the slot. Wraps on u64 overflow (≈ 5 × 10^11
    /// years at 1 GHz; not a concern).
    head: u64,
};

threadlocal var ring: Ring = .{
    .entries = @splat(.{
        .category = .bounds,
        .event = .emit_check,
        .payload_a = 0,
        .payload_b = 0,
    }),
    .head = 0,
};

/// Write a single entry into the per-thread ring. Compile-time
/// no-op when `enabled == false`. Cold-path: trace writes happen
/// at compile sites (M3-a-1) or trap sites (M3-a-2) — never on
/// the JIT-execution hot path.
inline fn writeEntry(entry: TraceEntry) void {
    if (comptime !enabled) return;
    const slot = ring.head % capacity;
    ring.entries[slot] = entry;
    ring.head += 1;
}

/// M3-a-1: record a memory-op bounds-check emit site. Called
/// from ARM64 `op_memory.emitMemOp` and x86_64 `emit.emitMemOp`
/// after the JAE/B.HI fixup is appended.
///
/// `func_idx` is truncated to u24 (16 M funcs); `byte_offset_in
/// _func` keeps full u32 (4 GiB).
pub inline fn writeBounds(func_idx: u32, byte_offset_in_func: u32) void {
    if (comptime !enabled) return;
    writeEntry(.{
        .category = .bounds,
        .event = .emit_check,
        .payload_a = @truncate(func_idx),
        .payload_b = byte_offset_in_func,
    });
}

/// Pack `func_idx` (20 bits, saturating) + low nibble of
/// `pass` into a `u24` `payload_a` slot. The remaining 4 high
/// `PassId` bits live only in `ZirFunc.pass_diagnostics`; the
/// ringbuffer's payload_a is approximate by design (16 PassIds
/// covers the visible Phase 8 surface; §9.8b extensions encode
/// in the per-function slot only). Per ADR-0033.
inline fn packPass(func_idx: u32, pass: PassId) u24 {
    const fi: u24 = @truncate(@min(func_idx, std.math.maxInt(u20)));
    const pid_lo4: u24 = @backingInt(pass) & 0xF;
    return (fi << 4) | pid_lo4;
}

/// §9.8a / 8a.1-b — record a pipeline-pass enter event into
/// the ringbuffer (Category.pass). Per ADR-0033. Compile-time
/// no-op when `enabled == false`. Cold-path: pass boundaries
/// fire at most once per pass per func.
pub inline fn passEnter(func_idx: u32, pass: PassId) void {
    if (comptime !enabled) return;
    writeEntry(.{
        .category = .pass,
        .event = @fromBackingInt(@intCast(@backingInt(PassEvent.pass_enter))),
        .payload_a = packPass(func_idx, pass),
        .payload_b = 0,
    });
}

/// §9.8a / 8a.1-b — record a pipeline-pass exit event into
/// the ringbuffer with the (lossy) per-pass summary digest.
/// Per ADR-0033. Compile-time no-op when `enabled == false`.
pub inline fn passExit(func_idx: u32, pass: PassId, summary: PassSummary) void {
    if (comptime !enabled) return;
    writeEntry(.{
        .category = .pass,
        .event = @fromBackingInt(@intCast(@backingInt(PassEvent.pass_exit))),
        .payload_a = packPass(func_idx, pass),
        .payload_b = summary.digest(),
    });
}

/// Reset the per-thread ring. Called by tests + by future
/// host entry points before each guest-call boundary.
pub fn clear() void {
    if (comptime !enabled) return;
    ring.head = 0;
}

/// Snapshot the most recent `min(max, dst.len, head, capacity)`
/// entries in chronological order (oldest of the snapshot first,
/// newest last — i.e. the LAST events before drain). Returned
/// slice is a copy into `dst` to avoid threadlocal-pointer
/// leakage; caller owns `dst`.
///
/// **Trap diagnosis pattern**: when `dst` is smaller than the
/// total writes, the OLDEST entries are dropped and the NEWEST
/// fill `dst`. This matches the typical "show me the last N
/// events before the trap" use case.
///
/// Returns the count actually filled; 0 when disabled or empty.
pub fn drain(dst: []TraceEntry, max: usize) usize {
    if (comptime !enabled) return 0;
    const written = ring.head;
    const want = @min(@min(max, dst.len), @min(written, capacity));
    if (want == 0) return 0;
    // Oldest-first: the slot N entries before head is at
    // (head - N) mod capacity. We walk forward from there.
    const start_offset = written - want;
    var i: usize = 0;
    while (i < want) : (i += 1) {
        const slot = (start_offset + i) % capacity;
        dst[i] = ring.entries[slot];
    }
    return want;
}

/// Total entries written since last `clear` (saturates at u64
/// max). Useful for tests asserting "exactly N writes happened".
pub fn writeCount() u64 {
    if (comptime !enabled) return 0;
    return ring.head;
}

// ============================================================
// §9.8a / 8a.4 — `ZWASM_DIAG` runtime opt-in surface.
//
// Build-time gate `-Dtrace-ringbuffer` controls whether the
// ringbuffer itself is compiled in (per ADR-0028). The runtime
// `ZWASM_DIAG` env var controls whether built-in surfaces drain
// the data on demand — orthogonal to recording.
//
// Tokens (comma-separated, e.g. `ZWASM_DIAG=passes,jit_exec`):
//   * `passes`    — drain `Category.pass` events to stderr at
//                    process exit. Per ADR-0033.
//   * `jit_exec`  — surface JIT-execution sentinel results.
//                    Per ADR-0034 (currently realworld_run_jit
//                    runner reads this directly; this token
//                    reserves the surface for future
//                    interp-vs-JIT differential tools).
//   * `bench`     — bench-script verbose output. Per ADR-0032.
//                    Currently host-side bash; this token
//                    reserves the name.
//   * `*`         — enable every channel.
//
// Zone 1 declares the data shape; Zone 3 entry points (cli/
// main.zig + api/instance.zig) read process env via their zone-
// appropriate API and pass the value to `initFromEnv`. Mirrors
// the `support/dbg.zig:ZWASM_DEBUG` pattern (D-009).
// ============================================================

/// Runtime channel bits. Comptime-elided when `enabled == false`
/// (the build flag controls whether the field even exists in any
/// meaningful sense; release builds compile out).
pub const Channels = packed struct(u8) {
    passes: bool = false,
    jit_exec: bool = false,
    bench: bool = false,
    _pad: u5 = 0,
};

var channels: Channels = .{};
var channels_initialised: bool = false;

/// Configure runtime channels from a `ZWASM_DIAG` env var
/// value. Pass `null` (or empty) to disable every channel;
/// `*` to enable all.
pub fn initFromEnv(value: ?[]const u8) void {
    if (comptime !enabled) return;
    channels = .{};
    channels_initialised = true;
    const v = value orelse return;
    if (v.len == 0) return;
    if (std.mem.eql(u8, v, "*")) {
        channels = .{ .passes = true, .jit_exec = true, .bench = true };
        return;
    }
    var it = std.mem.tokenizeScalar(u8, v, ',');
    while (it.next()) |raw_tok| {
        const tok = std.mem.trim(u8, raw_tok, " \t");
        if (std.mem.eql(u8, tok, "passes")) channels.passes = true else if (std.mem.eql(u8, tok, "jit_exec")) channels.jit_exec = true else if (std.mem.eql(u8, tok, "bench")) channels.bench = true;
        // Unknown tokens silently ignored — keeps forward-compat
        // with future channel additions.
    }
}

/// Query whether a named channel is enabled. Returns false in
/// release / pre-init / unknown-name cases.
pub fn channelEnabled(name: []const u8) bool {
    if (comptime !enabled) return false;
    if (!channels_initialised) return false;
    if (std.mem.eql(u8, name, "passes")) return channels.passes;
    if (std.mem.eql(u8, name, "jit_exec")) return channels.jit_exec;
    if (std.mem.eql(u8, name, "bench")) return channels.bench;
    return false;
}

/// §9.8a / 8a.4 — drain `Category.pass` ringbuffer entries to
/// stderr in chronological order. No-op when `enabled == false`,
/// when `ZWASM_DIAG=passes` is unset, or when the ring is empty.
/// Intended for `defer trace.drainPassesToStderr()` at process
/// entry-point scope (cli/main.zig).
pub fn drainPassesToStderr() void {
    if (comptime !enabled) return;
    if (!channelEnabled("passes")) return;
    var buf: [capacity]TraceEntry = undefined;
    const n = drain(&buf, capacity);
    if (n == 0) return;
    std.debug.print("[zwasm-diag passes] drained {d} pass-event entries:\n", .{n});
    for (buf[0..n]) |entry| {
        if (entry.category != .pass) continue;
        const fi: u32 = @as(u32, entry.payload_a) >> 4;
        const pid_lo4: u4 = @intCast(entry.payload_a & 0xF);
        const ev_tag: u4 = @backingInt(entry.event);
        const ev_str = if (ev_tag == @backingInt(PassEvent.pass_enter)) "enter" else "exit";
        std.debug.print(
            "  func={d} pass_id_lo4={d} {s} payload_b=0x{x}\n",
            .{ fi, pid_lo4, ev_str, entry.payload_b },
        );
    }
}

/// Test-only: reset channel state.
pub fn resetChannelsForTest() void {
    if (comptime !enabled) return;
    channels = .{};
    channels_initialised = false;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "trace: enabled flag matches build_options" {
    try testing.expectEqual(build_options.trace_ringbuffer, enabled);
}

test "trace: writeBounds + drain captures the event" {
    if (!enabled) return error.SkipZigTest;
    clear();
    writeBounds(7, 0x100);
    writeBounds(7, 0x150);
    var buf: [4]TraceEntry = undefined;
    const n = drain(&buf, 4);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u24, 7), buf[0].payload_a);
    try testing.expectEqual(@as(u32, 0x100), buf[0].payload_b);
    try testing.expectEqual(Category.bounds, buf[0].category);
    try testing.expectEqual(@as(u32, 0x150), buf[1].payload_b);
}

test "trace: ring wraps after capacity entries" {
    if (!enabled) return error.SkipZigTest;
    clear();
    var i: u32 = 0;
    while (i < capacity + 5) : (i += 1) {
        writeBounds(0, i);
    }
    try testing.expectEqual(@as(u64, capacity + 5), writeCount());
    var buf: [capacity]TraceEntry = undefined;
    const n = drain(&buf, capacity);
    try testing.expectEqual(capacity, n);
    // Oldest captured entry has byte_offset = 5 (slots 0..4 were overwritten).
    try testing.expectEqual(@as(u32, 5), buf[0].payload_b);
    // Newest captured entry has byte_offset = capacity + 4.
    try testing.expectEqual(@as(u32, capacity + 4), buf[capacity - 1].payload_b);
}

test "trace: drain into smaller dst returns newest N (last events before trap)" {
    if (!enabled) return error.SkipZigTest;
    clear();
    writeBounds(0, 1);
    writeBounds(0, 2);
    writeBounds(0, 3);
    var buf: [2]TraceEntry = undefined;
    const n = drain(&buf, 2);
    try testing.expectEqual(@as(usize, 2), n);
    // Newest 2 of 3 (trap diagnosis preference): byte_offsets 2 and 3.
    try testing.expectEqual(@as(u32, 2), buf[0].payload_b);
    try testing.expectEqual(@as(u32, 3), buf[1].payload_b);
}

test "trace: clear resets writeCount + drain" {
    if (!enabled) return error.SkipZigTest;
    clear();
    writeBounds(0, 100);
    writeBounds(0, 200);
    try testing.expectEqual(@as(u64, 2), writeCount());
    clear();
    try testing.expectEqual(@as(u64, 0), writeCount());
    var buf: [4]TraceEntry = undefined;
    try testing.expectEqual(@as(usize, 0), drain(&buf, 4));
}

test "trace: TraceEntry is exactly 8 bytes (packed struct contract)" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(TraceEntry));
}

test "trace: passEnter + passExit captures pair in pipeline order" {
    if (!enabled) return error.SkipZigTest;
    clear();
    passEnter(7, .hoist);
    passExit(7, .hoist, .{ .applied = 4, .skipped = 12, .extra = 2 });
    var buf: [4]TraceEntry = undefined;
    const n = drain(&buf, 4);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(Category.pass, buf[0].category);
    try testing.expectEqual(@as(u4, @backingInt(PassEvent.pass_enter)), @backingInt(buf[0].event));
    try testing.expectEqual(@as(u32, 0), buf[0].payload_b);
    try testing.expectEqual(Category.pass, buf[1].category);
    try testing.expectEqual(@as(u4, @backingInt(PassEvent.pass_exit)), @backingInt(buf[1].event));
    // payload_a packing: (func_idx << 4) | (pass_id & 0xF). For
    // func_idx=7, pass=.hoist (=2): (7 << 4) | 2 = 0x72.
    try testing.expectEqual(@as(u24, 0x72), buf[0].payload_a);
    try testing.expectEqual(@as(u24, 0x72), buf[1].payload_a);
    // exit payload_b = digest(applied=4, skipped=12) = (12 << 16) | 4
    try testing.expectEqual(@as(u32, (12 << 16) | 4), buf[1].payload_b);
}

test "trace: PassSummary.digest saturates applied + skipped at u16 max" {
    const big: PassSummary = .{ .applied = 70_000, .skipped = 100_000, .extra = 0 };
    const max16: u32 = std.math.maxInt(u16);
    try testing.expectEqual((max16 << 16) | max16, big.digest());

    const small: PassSummary = .{ .applied = 3, .skipped = 5, .extra = 99 };
    try testing.expectEqual(@as(u32, (5 << 16) | 3), small.digest());
}

test "ZWASM_DIAG: initFromEnv null/empty disables every channel" {
    if (!enabled) return error.SkipZigTest;
    resetChannelsForTest();
    initFromEnv(null);
    try testing.expect(!channelEnabled("passes"));
    try testing.expect(!channelEnabled("jit_exec"));
    try testing.expect(!channelEnabled("bench"));

    initFromEnv("");
    try testing.expect(!channelEnabled("passes"));
    try testing.expect(!channelEnabled("jit_exec"));
}

test "ZWASM_DIAG: comma-separated tokens parse + tolerate whitespace + unknown tokens" {
    if (!enabled) return error.SkipZigTest;
    resetChannelsForTest();
    initFromEnv(" passes , jit_exec , unknown_future ");
    try testing.expect(channelEnabled("passes"));
    try testing.expect(channelEnabled("jit_exec"));
    try testing.expect(!channelEnabled("bench"));
    try testing.expect(!channelEnabled("unknown_future"));
}

test "ZWASM_DIAG: `*` enables every channel" {
    if (!enabled) return error.SkipZigTest;
    resetChannelsForTest();
    initFromEnv("*");
    try testing.expect(channelEnabled("passes"));
    try testing.expect(channelEnabled("jit_exec"));
    try testing.expect(channelEnabled("bench"));
}

test "ZWASM_DIAG: pre-init returns false (matches ZWASM_DEBUG idiom)" {
    if (!enabled) return error.SkipZigTest;
    resetChannelsForTest();
    try testing.expect(!channelEnabled("passes"));
}

test "trace: packPass saturates func_idx at 20 bits" {
    if (!enabled) return error.SkipZigTest;
    clear();
    // 0x10_0001 (= 1 << 20 + 1) saturates to 0xF_FFFF (20-bit max).
    passEnter(0x10_0001, .emit);
    var buf: [1]TraceEntry = undefined;
    _ = drain(&buf, 1);
    // expected = (0xF_FFFF << 4) | (5 & 0xF) = 0xFFFFF5
    try testing.expectEqual(@as(u24, 0xFF_FFF5), buf[0].payload_a);
}

// Integration test: verifies the JIT emit paths (both backends)
// actually invoke trace.writeBounds when a memory op is compiled.
// Skipped under default build (`-Dtrace-ringbuffer=false`); the
// disabled state is independently covered by the call-site
// `comptime` branches.
test "trace: JIT emit invokes writeBounds for i32.load (integration, both backends)" {
    if (!enabled) return error.SkipZigTest;
    const builtin = @import("builtin");
    const zir = @import("../ir/zir.zig");
    const ZirFunc = zir.ZirFunc;
    const regalloc = @import("../engine/codegen/shared/regalloc.zig");

    // Pick the active backend's compile() based on host arch. The
    // Wasm fixture is the same for both; the bytes differ but the
    // `trace.writeBounds` call should fire identically.
    const compile = switch (builtin.cpu.arch) {
        .aarch64 => @import("../engine/codegen/arm64/emit.zig").compile,
        .x86_64 => @import("../engine/codegen/x86_64/emit.zig").compile,
        else => unreachable,
    };
    const deinit = switch (builtin.cpu.arch) {
        .aarch64 => @import("../engine/codegen/arm64/emit.zig").deinit,
        .x86_64 => @import("../engine/codegen/x86_64/emit.zig").deinit,
        else => unreachable,
    };

    clear();

    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(42, sig, &.{}); // func_idx = 42
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0);
    defer deinit(testing.allocator, out);

    try testing.expectEqual(@as(u64, 1), writeCount());
    var buf: [4]TraceEntry = undefined;
    const n = drain(&buf, 4);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(Category.bounds, buf[0].category);
    try testing.expectEqual(Event.emit_check, buf[0].event);
    try testing.expectEqual(@as(u24, 42), buf[0].payload_a);
    try testing.expect(buf[0].payload_b > 0); // some non-trivial fixup byte offset
}
