//! WASI 0.1 clock / random / poll handlers (§9.4 / 4.6).
//!
//! All three are low-IO syscalls that map onto Zig stdlib
//! primitives:
//!
//! - `clock_time_get(clock_id, precision, *time_out) → errno`
//!   reads the host's monotonic / realtime clock and writes
//!   nanoseconds-since-epoch into the guest pointer.
//! - `random_get(buf_ptr, buf_len) → errno` fills guest memory
//!   with cryptographic random bytes.
//! - `poll_oneoff(in_ptr, out_ptr, nsubscriptions, *nevents_out)
//!   → errno` — clock subscriptions park until the earliest
//!   deadline; fd_read / fd_write subscriptions report readiness
//!   over the Host's fd table. See `pollOneoff` for why every
//!   valid fd is ready immediately.
//!
//! Zone 2 (`src/wasi/`) — siblings: p1.zig / host.zig /
//! proc.zig / fd.zig.

const std = @import("std");

const p1 = @import("preview1.zig");
const host_mod = @import("host.zig");

const Host = host_mod.Host;

// ============================================================
// Memory helpers
// ============================================================

fn writeU32LE(mem: []u8, offset: u32, value: u32) p1.Errno {
    if (@as(usize, offset) + 4 > mem.len) return .fault;
    std.mem.writeInt(u32, mem[offset..][0..4], value, .little);
    return .success;
}

fn writeU64LE(mem: []u8, offset: u32, value: u64) p1.Errno {
    if (@as(usize, offset) + 8 > mem.len) return .fault;
    std.mem.writeInt(u64, mem[offset..][0..8], value, .little);
    return .success;
}

// ============================================================
// clock_time_get
// ============================================================

/// `clock_time_get(clock_id, precision, *time_out) → errno`.
/// Spec-conformant clock IDs (see witx `clockid`):
///   - 0 realtime          → `std.Io.Clock.real`
///   - 1 monotonic         → `std.Io.Clock.awake`
///   - 2 process_cputime   → `std.Io.Clock.cpu_process`
///   - 3 thread_cputime    → `std.Io.Clock.cpu_thread`
///
/// `precision` is advisory (witx: "max permissible allowable
/// error in nanoseconds"). Ignored; we return the host's
/// native resolution.
///
/// Requires `host.io` to be set; without it returns `nosys`
/// (Zig 0.16 routes all clock reads through `std.Io`).
pub fn clockTimeGet(
    host: *Host,
    mem: []u8,
    clock_id: u32,
    precision: u64,
    time_ptr: u32,
) p1.Errno {
    _ = precision;
    const ns_u = clockTimeNs(host, clock_id) catch |err| return switch (err) {
        error.NoSys => .nosys,
        error.Inval => .inval,
    };
    return writeU64LE(mem, time_ptr, ns_u);
}

/// Read a clock as a raw nanosecond `u64` — the value `clock_time_get` writes to
/// guest memory. Factored out so the WASI-P2 `monotonic-clock.now()` trampoline
/// can return the value directly (its lowered `()->i64`) instead of through
/// guest memory. Same clock-id mapping as `clock_time_get`; requires `host.io`.
pub fn clockTimeNs(host: *Host, clock_id: u32) error{ NoSys, Inval }!u64 {
    const ns_i = try clockTimeNsSigned(host, clock_id);
    if (ns_i < 0) return error.Inval;
    return @intCast(@min(ns_i, std.math.maxInt(u64)));
}

/// Read a clock as SIGNED nanoseconds since its epoch. The official WASI
/// 0.3.0 `system-clock` `instant` carries signed seconds (pre-1970 instants
/// are representable), so its trampoline needs the un-clamped value; the
/// P1/0.2 paths keep the unsigned `clockTimeNs` view.
pub fn clockTimeNsSigned(host: *Host, clock_id: u32) error{ NoSys, Inval }!i96 {
    const io = host.io orelse return error.NoSys;
    const clock: std.Io.Clock = switch (clock_id) {
        0 => .real,
        1 => .awake,
        2 => .cpu_process,
        3 => .cpu_thread,
        else => return error.Inval,
    };
    return std.Io.Timestamp.now(io, clock).toNanoseconds();
}

// ============================================================
// clock_res_get
// ============================================================

/// `clock_res_get(clock_id, *resolution_out) → errno`. Writes the
/// host clock's granularity in nanoseconds. Same clock-id mapping as
/// `clock_time_get`. `Clock.resolution` (Zig 0.16) surfaces
/// `ClockUnavailable` for a clock the host lacks → `notsup`; an
/// unexpected OS failure → `io`. Requires `host.io` (else `nosys`).
pub fn clockResGet(
    host: *Host,
    mem: []u8,
    clock_id: u32,
    resolution_ptr: u32,
) p1.Errno {
    const ns_u = clockResNs(host, clock_id) catch |err| return switch (err) {
        error.NoSys => .nosys,
        error.Inval => .inval,
        error.NotSup => .notsup,
        error.Io => .io,
    };
    return writeU64LE(mem, resolution_ptr, ns_u);
}

/// Read a clock's resolution as a raw nanosecond `u64` — the value
/// `clock_res_get` writes to guest memory. Factored out so the WASI-P2/P3
/// `get-resolution` trampolines (`wasi:clocks@0.3.0`) can return it directly
/// (their lowered `()->i64`) instead of through guest memory. Same clock-id
/// mapping as `clock_time_get`; requires `host.io`.
pub fn clockResNs(host: *Host, clock_id: u32) error{ NoSys, Inval, NotSup, Io }!u64 {
    const io = host.io orelse return error.NoSys;
    const clock: std.Io.Clock = switch (clock_id) {
        0 => .real,
        1 => .awake,
        2 => .cpu_process,
        3 => .cpu_thread,
        else => return error.Inval,
    };
    const dur = clock.resolution(io) catch |err| switch (err) {
        error.ClockUnavailable => return error.NotSup,
        error.Unexpected => return error.Io,
    };
    const ns_i = dur.toNanoseconds();
    if (ns_i < 0) return error.Inval;
    return @intCast(@min(ns_i, std.math.maxInt(u64)));
}

// ============================================================
// random_get
// ============================================================

/// `random_get(buf_ptr, buf_len) → errno` — fill guest memory
/// with cryptographic random bytes. Uses `std.Io.randomSecure`
/// (Zig 0.16 routes randomness through `std.Io`). Out-of-bounds
/// buf returns `fault`; allocator failures inside the io vtable
/// surface as `nosys`.
pub fn randomGet(
    host: *Host,
    mem: []u8,
    buf_ptr: u32,
    buf_len: u32,
) p1.Errno {
    const end = @as(usize, buf_ptr) + @as(usize, buf_len);
    if (end > mem.len) return .fault;
    return randomFill(host, mem[buf_ptr..end]);
}

/// Fill `dest` with cryptographically-secure random bytes. Factored from
/// `random_get` so the WASI-P2 `get-random-bytes` trampoline — which allocates
/// its own destination via the guest `cabi_realloc` — reuses the same io path.
pub fn randomFill(host: *Host, dest: []u8) p1.Errno {
    if (dest.len == 0) return .success;
    const io = host.io orelse return .nosys;
    io.randomSecure(dest) catch return .nosys;
    return .success;
}

// ============================================================
// poll_oneoff
// ============================================================

/// How ready an fd subscription is: the byte count the event reports and its
/// `eventrwflags`. Every fd this table can hold is ready the moment it is
/// valid — see `pollOneoff`'s note on why that is the truth here and not a
/// placeholder.
const FdReadiness = struct { nbytes: u64, flags: u16 };

/// Classify one `fd_read` / `fd_write` subscription. Errors are the WHOLE
/// call's answer, not a per-event `error` field: preview1 has an error slot on
/// each event, but wasmtime 47 fails the call for a descriptor that cannot
/// carry the subscription, and a guest that gets a half-filled event array has
/// no way to tell which subscription was rejected.
fn fdReadiness(
    host: *Host,
    fd: p1.Fd,
    want_read: bool,
) error{ BadF, NotCapable, NoSys, Io }!FdReadiness {
    const slot = host.translateFd(fd) orelse return error.BadF;
    // The fd's TYPE decides whether the subscription exists at all; only then
    // does the capability decide whether THIS fd may carry it — the same order
    // `fd.writeSlice` keeps, and what makes `notcapable` mean what it says.
    switch (slot.kind) {
        .closed, .dir => return error.BadF,
        // There is no readable stdout and no writable stdin.
        .stdin => {
            if (!want_read) return error.BadF;
        },
        .stdout, .stderr => {
            if (want_read) return error.BadF;
        },
        .file => {},
    }
    if (!slot.has(p1.RIGHTS_POLL_FD_READWRITE)) return error.NotCapable;

    if (!want_read) {
        // A write sink with no bound to report. Both destinations a preview1
        // write can reach — a capture buffer and the process stream — accept
        // whatever they are handed, so the only honest count is the smallest
        // one that still means "writable". wasmtime 47 reports 1 here too.
        return .{ .nbytes = 1, .flags = 0 };
    }

    const remaining: u64 = switch (slot.kind) {
        .stdin => blk: {
            // An inherited stdin cannot be counted without blocking on it;
            // report it readable with the same constant 1 wasmtime uses, so a
            // guest that polls before reading does not see a hang-up.
            const src = host.stdin_bytes orelse break :blk @as(u64, if (host.stdin_inherit) 1 else 0);
            break :blk if (src.len > host.stdin_pos) @intCast(src.len - host.stdin_pos) else 0;
        },
        .file => blk: {
            const io = host.io orelse return error.NoSys;
            const f: std.Io.File = .{
                .handle = slot.host_handle orelse return error.BadF,
                .flags = .{ .nonblocking = false },
            };
            const size = (f.stat(io) catch return error.Io).size;
            break :blk if (size > slot.pos) size - slot.pos else 0;
        },
        // Unreachable by the kind switch above: it fails the call for a
        // closed slot, a directory and a read of stdout/stderr, so the only
        // kinds that reach a read here are stdin and file.
        .stdout, .stderr, .dir, .closed => unreachable,
    };
    // witx: nbytes is "the number of bytes available for reading". We know it
    // exactly for both readable kinds, so we report it. (wasmtime 47 computes
    // the same number, uses it only to decide HANGUP, and writes a constant 1;
    // reporting the real count is the stricter reading of the same field and
    // no guest can be worse off for it.)
    return .{
        .nbytes = remaining,
        .flags = if (remaining == 0) p1.EVENTRWFLAGS_FD_READWRITE_HANGUP else 0,
    };
}

/// Write one 32-byte `event` at `off`. `error` stays success — a subscription
/// that could not produce an event failed the whole call instead.
fn writeEvent(mem: []u8, off: usize, userdata: u64, ty: p1.EventType, nbytes: u64, flags: u16) void {
    @memset(mem[off..][0..32], 0);
    std.mem.writeInt(u64, mem[off..][0..8], userdata, .little);
    mem[off + 10] = @intFromEnum(ty);
    std.mem.writeInt(u64, mem[off + 16 ..][0..8], nbytes, .little);
    std.mem.writeInt(u16, mem[off + 24 ..][0..2], flags, .little);
}

/// `poll_oneoff(in_ptr, out_ptr, nsubscriptions, *nevents_out) → errno`.
/// Reports every fd subscription that is ready now; if none is, blocks until
/// the earliest clock deadline and reports that one clock event (poll_oneoff is
/// satisfied once ≥1 subscription fires; a guest re-polls for the rest). The
/// clock path covers the scheduler-park case (Go/wasi-libc sleep).
/// `nsubscriptions == 0` → nevents=0.
///
/// **Every valid fd subscription is ready immediately** (ADR-0217). No kind
/// `FdKind` holds has a blocking point — a stdin read copies out of
/// `host.stdin_bytes` or reports EOF, a write reaches a capture buffer or the
/// process stream, a `.file` read or write is positional — so "the matching
/// call will not block" is true by construction, not approximated for want of
/// an `epoll` / `kqueue` / AFD source. The WASI-P2 pollable in
/// `api/component_wasi_p2.zig` says ready for sources that genuinely can
/// block; that one is a placeholder and this one is not.
///
/// **The premise is the Host's, so it breaks when the Host changes**: give
/// stdin a real process handle and it needs a readiness source this file does
/// not have. Nothing else in the table can acquire one. Until then, EOF is
/// reported rather than hidden — a read ready with nothing left answers
/// `nbytes = 0` plus FD_READWRITE_HANGUP, so a guest looping "poll until
/// readable, then read" terminates instead of spinning.
///
/// Subscription (48 B): userdata u64 @0; tag eventtype @8; clock body —
/// id u32 @16, timeout u64 @24, precision u64 @32, flags u16 @40
/// (bit 0 = ABSTIME); fd body — fd u32 @16. Event (32 B): userdata @0,
/// error u16 @8, type @10, fd_readwrite @16 (nbytes u64 @16, flags u16 @24).
pub fn pollOneoff(
    host: *Host,
    mem: []u8,
    in_ptr: u32,
    out_ptr: u32,
    nsubscriptions: u32,
    nevents_ptr: u32,
) p1.Errno {
    if (nsubscriptions == 0) return writeU32LE(mem, nevents_ptr, 0);
    const io = host.io orelse return .nosys;

    const SUB_SIZE: u32 = 48;
    const EVT_SIZE: usize = 32;
    const ABSTIME: u16 = 0x1;

    if (@as(u64, in_ptr) + @as(u64, nsubscriptions) * SUB_SIZE > mem.len) return .fault;
    // The out array is sized for the whole subscription set: a poll where every
    // fd is ready writes one event per subscription.
    if (@as(u64, out_ptr) + @as(u64, nsubscriptions) * EVT_SIZE > mem.len) return .fault;

    // Earliest-deadline clock subscription (relative ns from now) + its userdata.
    var best_rel_ns: ?u64 = null;
    var best_userdata: u64 = 0;
    var nevents: u32 = 0;
    var i: u32 = 0;
    while (i < nsubscriptions) : (i += 1) {
        const base = in_ptr + i * SUB_SIZE;
        const userdata = std.mem.readInt(u64, mem[base..][0..8], .little);
        const tag = mem[base + 8];
        switch (tag) {
            @intFromEnum(p1.EventType.clock) => {
                const clock_id = std.mem.readInt(u32, mem[base + 16 ..][0..4], .little);
                const timeout_ns = std.mem.readInt(u64, mem[base + 24 ..][0..8], .little);
                const flags = std.mem.readInt(u16, mem[base + 40 ..][0..2], .little);
                const rel: u64 = if (flags & ABSTIME != 0) blk: {
                    const now_ns = clockTimeNs(host, clock_id) catch |err| return switch (err) {
                        error.NoSys => .nosys,
                        error.Inval => .inval,
                    };
                    break :blk if (timeout_ns > now_ns) timeout_ns - now_ns else 0;
                } else timeout_ns;
                if (best_rel_ns == null or rel < best_rel_ns.?) {
                    best_rel_ns = rel;
                    best_userdata = userdata;
                }
            },
            @intFromEnum(p1.EventType.fd_read), @intFromEnum(p1.EventType.fd_write) => {
                const want_read = tag == @intFromEnum(p1.EventType.fd_read);
                const fd = std.mem.readInt(u32, mem[base + 16 ..][0..4], .little);
                const r = fdReadiness(host, fd, want_read) catch |err| return switch (err) {
                    error.BadF => .badf,
                    error.NotCapable => .notcapable,
                    error.NoSys => .nosys,
                    error.Io => .io,
                };
                const off = @as(usize, out_ptr) + @as(usize, nevents) * EVT_SIZE;
                writeEvent(mem, off, userdata, if (want_read) .fd_read else .fd_write, r.nbytes, r.flags);
                nevents += 1;
            },
            else => return .inval,
        }
    }

    // An fd fired, so the poll is already satisfied: return without sleeping,
    // and WITHOUT a clock event. A guest that pairs fd subscriptions with a
    // timeout reads a returned clock event as "the timeout won".
    if (nevents > 0) return writeU32LE(mem, nevents_ptr, nevents);

    // Pure-clock poll: block until the earliest subscription fires (monotonic;
    // a duration is a duration regardless of the named clock). Cancellation
    // just proceeds.
    if (best_rel_ns) |ns| {
        if (ns > 0) std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@intCast(ns)), .awake) catch |err| switch (err) {
            // A cancelled sleep just wakes early; poll_oneoff still reports the
            // clock event and the guest re-polls if its real deadline has not
            // elapsed. There is no other Cancelable error to handle.
            error.Canceled => {},
        };
    }

    // One clock event: userdata echoed, error=success(0), type=clock, rest zero.
    writeEvent(mem, out_ptr, best_userdata, .clock, 0, 0);
    return writeU32LE(mem, nevents_ptr, 1);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "clockTimeGet: realtime writes non-zero u64" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [16]u8 = @splat(0);
    const e = clockTimeGet(&h, &mem, 0, 0, 0);
    try testing.expectEqual(p1.Errno.success, e);
    const ns = std.mem.readInt(u64, mem[0..8], .little);
    try testing.expect(ns > 0);
}

test "clockTimeGet: monotonic also writes a u64" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [16]u8 = @splat(0);
    const e = clockTimeGet(&h, &mem, 1, 0, 0);
    try testing.expectEqual(p1.Errno.success, e);
    try testing.expect(std.mem.readInt(u64, mem[0..8], .little) > 0);
}

test "clockTimeGet: unknown clock_id returns inval" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [16]u8 = @splat(0);
    const e = clockTimeGet(&h, &mem, 99, 0, 0);
    try testing.expectEqual(p1.Errno.inval, e);
}

test "clockTimeGet: out-of-bounds time_ptr returns fault" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [4]u8 = @splat(0);
    const e = clockTimeGet(&h, &mem, 0, 0, 0);
    try testing.expectEqual(p1.Errno.fault, e);
}

test "clockTimeGet: missing host.io returns nosys" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [16]u8 = @splat(0);
    const e = clockTimeGet(&h, &mem, 0, 0, 0);
    try testing.expectEqual(p1.Errno.nosys, e);
}

test "clockResGet: realtime writes a positive resolution u64" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [16]u8 = @splat(0);
    const e = clockResGet(&h, &mem, 0, 0);
    try testing.expectEqual(p1.Errno.success, e);
    const ns = std.mem.readInt(u64, mem[0..8], .little);
    try testing.expect(ns > 0 and ns <= std.time.ns_per_s);
}

test "clockResGet: unknown clock_id returns inval" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [16]u8 = @splat(0);
    try testing.expectEqual(p1.Errno.inval, clockResGet(&h, &mem, 99, 0));
}

test "clockResGet: out-of-bounds ptr returns fault" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [4]u8 = @splat(0);
    try testing.expectEqual(p1.Errno.fault, clockResGet(&h, &mem, 0, 0));
}

test "clockResGet: missing host.io returns nosys" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [16]u8 = @splat(0);
    try testing.expectEqual(p1.Errno.nosys, clockResGet(&h, &mem, 0, 0));
}

test "randomGet: fills 32 bytes with at least one non-zero byte" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [32]u8 = @splat(0);
    const e = randomGet(&h, &mem, 0, 32);
    try testing.expectEqual(p1.Errno.success, e);
    var any_nonzero = false;
    for (mem) |b| {
        if (b != 0) {
            any_nonzero = true;
            break;
        }
    }
    try testing.expect(any_nonzero);
}

test "randomGet: zero-length buf is success-noop" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [4]u8 = @splat(0xAB);
    const e = randomGet(&h, &mem, 0, 0);
    try testing.expectEqual(p1.Errno.success, e);
    // Memory untouched.
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xAB, 0xAB, 0xAB }, &mem);
}

test "randomGet: out-of-bounds buf returns fault" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [16]u8 = @splat(0);
    const e = randomGet(&h, &mem, 10, 20);
    try testing.expectEqual(p1.Errno.fault, e);
}

test "pollOneoff: zero subscriptions writes nevents=0" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [8]u8 = @splat(0xFF);
    const e = pollOneoff(&h, &mem, 0, 0, 0, 0);
    try testing.expectEqual(p1.Errno.success, e);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, mem[0..4], .little));
}

test "pollOneoff: a clock subscription fires + writes one event" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    // 48-byte subscription @0; 32-byte event out @48; nevents @80.
    var mem: [128]u8 = @splat(0);
    std.mem.writeInt(u64, mem[0..8], 0xCAFE, .little); // userdata @0
    mem[8] = @intFromEnum(p1.EventType.clock); // tag @8 = clock
    std.mem.writeInt(u32, mem[16..20], 1, .little); // clock_id @16 = monotonic
    std.mem.writeInt(u64, mem[24..32], 0, .little); // timeout @24 = 0 (relative → immediate)
    // flags @40 = 0 (relative)
    const e = pollOneoff(&h, &mem, 0, 48, 1, 80);
    try testing.expectEqual(p1.Errno.success, e);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, mem[80..84], .little)); // nevents
    try testing.expectEqual(@as(u64, 0xCAFE), std.mem.readInt(u64, mem[48..56], .little)); // event.userdata
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, mem[56..58], .little)); // event.error = success
    try testing.expectEqual(@as(u8, @intFromEnum(p1.EventType.clock)), mem[58]); // event.type @ 48+10
}

// ---- poll_oneoff: fd-readiness ----
//
// Layout used by the fd tests below: subscriptions at 0, events at
// `sub_count * 48`, nevents at 512. `sub` fills one 48-byte subscription;
// `evt` reads one 32-byte event back.

/// Write subscription `idx`: userdata, tag, and the fd (clock bodies set their
/// own fields on top).
fn sub(mem: []u8, idx: u32, userdata: u64, ty: p1.EventType, fd: u32) void {
    const base = idx * 48;
    std.mem.writeInt(u64, mem[base..][0..8], userdata, .little);
    mem[base + 8] = @intFromEnum(ty);
    std.mem.writeInt(u32, mem[base + 16 ..][0..4], fd, .little);
}

const Evt = struct { userdata: u64, err: u16, ty: u8, nbytes: u64, flags: u16 };

fn evt(mem: []const u8, out_ptr: u32, idx: u32) Evt {
    const off = out_ptr + idx * 32;
    return .{
        .userdata = std.mem.readInt(u64, mem[off..][0..8], .little),
        .err = std.mem.readInt(u16, mem[off + 8 ..][0..2], .little),
        .ty = mem[off + 10],
        .nbytes = std.mem.readInt(u64, mem[off + 16 ..][0..8], .little),
        .flags = std.mem.readInt(u16, mem[off + 24 ..][0..2], .little),
    };
}

test "pollOneoff: fd_read on stdin with bytes left reports the remaining count" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    h.stdin_bytes = "abcde";
    h.stdin_pos = 2; // 3 left

    var mem: [640]u8 = @splat(0);
    sub(&mem, 0, 0xB0B, .fd_read, 0);
    try testing.expectEqual(p1.Errno.success, pollOneoff(&h, &mem, 0, 48, 1, 512));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, mem[512..516], .little));
    const e = evt(&mem, 48, 0);
    try testing.expectEqual(@as(u64, 0xB0B), e.userdata);
    try testing.expectEqual(@as(u16, 0), e.err);
    try testing.expectEqual(@as(u8, @intFromEnum(p1.EventType.fd_read)), e.ty);
    try testing.expectEqual(@as(u64, 3), e.nbytes);
    try testing.expectEqual(@as(u16, 0), e.flags);
}

test "pollOneoff: fd_read on a drained stdin is ready with nbytes=0 and HANGUP" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    // Both flavours of "nothing to read": drained, and never supplied. Without
    // HANGUP a guest that polls-then-reads spins on either.
    h.stdin_bytes = "ab";
    h.stdin_pos = 2;

    var mem: [640]u8 = @splat(0);
    sub(&mem, 0, 0x1, .fd_read, 0);
    try testing.expectEqual(p1.Errno.success, pollOneoff(&h, &mem, 0, 48, 1, 512));
    var e = evt(&mem, 48, 0);
    try testing.expectEqual(@as(u64, 0), e.nbytes);
    try testing.expectEqual(p1.EVENTRWFLAGS_FD_READWRITE_HANGUP, e.flags);

    h.stdin_bytes = null;
    try testing.expectEqual(p1.Errno.success, pollOneoff(&h, &mem, 0, 48, 1, 512));
    e = evt(&mem, 48, 0);
    try testing.expectEqual(@as(u64, 0), e.nbytes);
    try testing.expectEqual(p1.EVENTRWFLAGS_FD_READWRITE_HANGUP, e.flags);
}

test "pollOneoff: fd_write on stdout and stderr both fire, in subscription order" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;

    var mem: [640]u8 = @splat(0);
    sub(&mem, 0, 0xA, .fd_write, 1);
    sub(&mem, 1, 0xB, .fd_write, 2);
    try testing.expectEqual(p1.Errno.success, pollOneoff(&h, &mem, 0, 96, 2, 512));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, mem[512..516], .little));

    const e0 = evt(&mem, 96, 0);
    try testing.expectEqual(@as(u64, 0xA), e0.userdata);
    try testing.expectEqual(@as(u8, @intFromEnum(p1.EventType.fd_write)), e0.ty);
    try testing.expectEqual(@as(u16, 0), e0.flags);
    const e1 = evt(&mem, 96, 1);
    try testing.expectEqual(@as(u64, 0xB), e1.userdata);
    try testing.expectEqual(@as(u8, @intFromEnum(p1.EventType.fd_write)), e1.ty);
}

test "pollOneoff: a ready fd wins over a pending clock — no clock event, no sleep" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;

    var mem: [640]u8 = @splat(0);
    // A clock the guest would have to wait a full hour for, plus a writable fd.
    sub(&mem, 0, 0xC10C, .clock, 0);
    std.mem.writeInt(u32, mem[16..20], 1, .little); // monotonic
    std.mem.writeInt(u64, mem[24..32], 3600 * std.time.ns_per_s, .little);
    sub(&mem, 1, 0xFD, .fd_write, 1);

    try testing.expectEqual(p1.Errno.success, pollOneoff(&h, &mem, 0, 96, 2, 512));
    // Exactly one event, and it is the fd: a returned clock event would tell
    // the guest its timeout won.
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, mem[512..516], .little));
    const e = evt(&mem, 96, 0);
    try testing.expectEqual(@as(u64, 0xFD), e.userdata);
    try testing.expectEqual(@as(u8, @intFromEnum(p1.EventType.fd_write)), e.ty);
}

test "pollOneoff: fd_read on a file reports size minus cursor, and HANGUP at EOF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;

    const dir: std.Io.Dir = .{ .handle = tmp.dir.handle };
    const f = try dir.createFile(testing.io, "poll.txt", .{ .read = true });
    defer f.close(testing.io);
    try f.writePositionalAll(testing.io, "abcdef", 0); // 6 bytes
    try h.fd_table.append(testing.allocator, .{
        .kind = .file,
        .rights_base = p1.RIGHTS_FD_READ | p1.RIGHTS_POLL_FD_READWRITE,
        .host_handle = f.handle,
    });
    const fd: u32 = @intCast(h.fd_table.items.len - 1);

    var mem: [640]u8 = @splat(0);
    sub(&mem, 0, 0xF11E, .fd_read, fd);
    try testing.expectEqual(p1.Errno.success, pollOneoff(&h, &mem, 0, 48, 1, 512));
    var e = evt(&mem, 48, 0);
    try testing.expectEqual(@as(u64, 6), e.nbytes);
    try testing.expectEqual(@as(u16, 0), e.flags);

    // Cursor at end: still ready (a read there returns 0, it does not block)
    // but the hangup bit says there is nothing more coming.
    h.translateFd(fd).?.pos = 6;
    try testing.expectEqual(p1.Errno.success, pollOneoff(&h, &mem, 0, 48, 1, 512));
    e = evt(&mem, 48, 0);
    try testing.expectEqual(@as(u64, 0), e.nbytes);
    try testing.expectEqual(p1.EVENTRWFLAGS_FD_READWRITE_HANGUP, e.flags);

    // A file is writable-ready too.
    h.translateFd(fd).?.rights_base |= p1.RIGHTS_FD_WRITE;
    sub(&mem, 0, 0xF11E, .fd_write, fd);
    try testing.expectEqual(p1.Errno.success, pollOneoff(&h, &mem, 0, 48, 1, 512));
    try testing.expectEqual(@as(u8, @intFromEnum(p1.EventType.fd_write)), evt(&mem, 48, 0).ty);

    h.translateFd(fd).?.kind = .closed;
}

test "pollOneoff: an fd that cannot carry the subscription fails the whole call with badf" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const fake: std.posix.fd_t = undefined;
    const dirfd = try h.addPreopen(fake, "/sandbox");

    var mem: [640]u8 = @splat(0);
    // Out of range.
    sub(&mem, 0, 0, .fd_read, 99);
    try testing.expectEqual(p1.Errno.badf, pollOneoff(&h, &mem, 0, 48, 1, 512));
    // A directory has no stream to poll.
    sub(&mem, 0, 0, .fd_read, dirfd);
    try testing.expectEqual(p1.Errno.badf, pollOneoff(&h, &mem, 0, 48, 1, 512));
    // Wrong direction: stdout is not readable, stdin is not writable.
    sub(&mem, 0, 0, .fd_read, 1);
    try testing.expectEqual(p1.Errno.badf, pollOneoff(&h, &mem, 0, 48, 1, 512));
    sub(&mem, 0, 0, .fd_write, 0);
    try testing.expectEqual(p1.Errno.badf, pollOneoff(&h, &mem, 0, 48, 1, 512));
    // A closed slot is in range but is not a descriptor.
    h.fd_table.items[0].kind = .closed;
    sub(&mem, 0, 0, .fd_read, 0);
    try testing.expectEqual(p1.Errno.badf, pollOneoff(&h, &mem, 0, 48, 1, 512));
}

test "pollOneoff: an fd without POLL_FD_READWRITE is notcapable, not badf" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    // The type is right and only the capability is missing — the guest is told
    // which of the two it is.
    h.fd_table.items[0].rights_base = p1.RIGHTS_FD_READ;

    var mem: [640]u8 = @splat(0);
    sub(&mem, 0, 0, .fd_read, 0);
    try testing.expectEqual(p1.Errno.notcapable, pollOneoff(&h, &mem, 0, 48, 1, 512));
}

test "pollOneoff: an unknown subscription tag is inval" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var mem: [640]u8 = @splat(0);
    mem[8] = 7; // not clock / fd_read / fd_write
    try testing.expectEqual(p1.Errno.inval, pollOneoff(&h, &mem, 0, 48, 1, 512));
}

test "pollOneoff: the out array is bounds-checked for every subscription" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    // Room for the 3 subscriptions (144 B) and for ONE event at 144, but a
    // 3-event poll needs 96 B there. Sizing the check to one event would let
    // the second write run off the end of guest memory.
    var mem: [200]u8 = @splat(0);
    sub(&mem, 0, 0xA, .fd_write, 1);
    sub(&mem, 1, 0xB, .fd_write, 2);
    sub(&mem, 2, 0xC, .fd_write, 1);
    try testing.expectEqual(p1.Errno.fault, pollOneoff(&h, &mem, 0, 144, 3, 190));
}
