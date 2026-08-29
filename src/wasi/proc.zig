//! WASI 0.1 proc + args + environ handlers (Phase 4 / §9.4 / 4.3).
//!
//! The first batch of `wasi_snapshot_preview1` host functions —
//! all share a "no fd table touch beyond `proc_exit`" property,
//! so they can land before the §9.4 / 4.4 fd_* handlers wire
//! their IO surface.
//!
//! Each handler takes the host state (`*Host`), a slice into
//! the guest's linear memory (`[]u8`), plus the guest-supplied
//! argument values. Memory writes go through bounds-checked
//! `writeU32` / `writeBytes` helpers — out-of-bounds returns
//! `Errno.fault`, matching wasmtime's behaviour for guest-
//! supplied bad pointers.
//!
//! `proc_exit` is the odd one out: it has no return value
//! (witx `noreturn`). We model it by recording `host.exit_code`
//! and unwinding through a channel of the engine's own — the
//! interp thunk returns `error.WasiExit` (`src/api/wasi.zig`),
//! the JIT stub raises the trap flag (`jit_dispatch.zig`).
//! Neither reads `host.exit_code` back: it is the recorded
//! status, not the unwind signal. Both surface as a trap at the
//! C-API binding.
//!
//! Zone 2 (`src/wasi/`) — same zone as `host.zig` and `p1.zig`.

const std = @import("std");

const p1 = @import("preview1.zig");
const host_mod = @import("host.zig");

const Host = host_mod.Host;

// ============================================================
// Memory access helpers (bounds-checked)
// ============================================================

fn writeU32LE(mem: []u8, offset: u32, value: u32) p1.Errno {
    if (@as(usize, offset) + 4 > mem.len) return .fault;
    std.mem.writeInt(u32, mem[offset..][0..4], value, .little);
    return .success;
}

fn writeBytes(mem: []u8, offset: u32, src: []const u8) p1.Errno {
    if (@as(usize, offset) + src.len > mem.len) return .fault;
    @memcpy(mem[offset .. offset + src.len], src);
    return .success;
}

// ============================================================
// proc_exit
// ============================================================

/// `proc_exit(rval) -> noreturn` — request termination of the
/// instance with exit code `rval`. The handler only records
/// `host.exit_code` and returns `Errno.success`; unwinding is the
/// caller's, per engine (`error.WasiExit` from the interp thunk,
/// the trap flag from the JIT stub). The recorded status is what
/// `zwasm_store_wasi_exit_code` and `src/cli/run.zig` read, and
/// `wasm_func_call` clears it before each call so it describes
/// that call alone (#341).
pub fn procExit(host: *Host, rval: u32) p1.Errno {
    host.exit_code = rval;
    return .success;
}

/// Wasm WASI snapshot-1 `sched_yield` — cooperative scheduler yield.
/// zwasm runs the guest synchronously on the host thread with no
/// scheduler, so there is nothing to yield to: a no-op `success`,
/// matching wasmtime/wasmer single-threaded behaviour.
pub fn schedYield() p1.Errno {
    return .success;
}

/// `proc_raise(sig) → errno` — request delivery of signal `sig` to the guest.
/// zwasm sandboxes the guest with NO POSIX signal-delivery path: a wasm guest
/// has no signal handlers in this model, and raising a real host signal would
/// hit the runtime process, not the guest — actively wrong. So this reports
/// `notsup` (a deliberate design boundary, not an unimplemented stub): wasi-
/// libc's `abort()` then falls through to its trap/exit path instead of
/// silently continuing. `proc_raise` is deprecated in WASI for this reason.
pub fn procRaise(sig: u32) p1.Errno {
    _ = sig;
    return .notsup;
}

// ============================================================
// args_*
// ============================================================

/// Total bytes the guest needs to allocate to hold the arg
/// strings (each null-terminated). Public for callers that
/// want to size their own buffer; otherwise `args_sizes_get`
/// is the only consumer.
pub fn argsBufSize(host: *const Host) u32 {
    var total: u32 = 0;
    for (host.args) |a| total += @intCast(a.len + 1);
    return total;
}

/// `args_sizes_get(*argc_out, *buf_size_out) -> errno` —
/// write the count + total-byte-length to guest memory.
pub fn argsSizesGet(
    host: *const Host,
    mem: []u8,
    argc_ptr: u32,
    buf_size_ptr: u32,
) p1.Errno {
    const e1 = writeU32LE(mem, argc_ptr, @intCast(host.args.len));
    if (e1 != .success) return e1;
    return writeU32LE(mem, buf_size_ptr, argsBufSize(host));
}

/// `args_get(*argv_out, *argv_buf_out) -> errno` — write the
/// per-arg pointer table (one u32 per arg, pointing into the
/// string buffer) and the null-terminated strings themselves.
/// Caller computes the buffer size via `args_sizes_get`.
pub fn argsGet(
    host: *const Host,
    mem: []u8,
    argv_ptr: u32,
    argv_buf_ptr: u32,
) p1.Errno {
    var cursor: u32 = argv_buf_ptr;
    for (host.args, 0..) |arg, i| {
        const ptr_off: u32 = @intCast(argv_ptr + i * 4);
        const e1 = writeU32LE(mem, ptr_off, cursor);
        if (e1 != .success) return e1;
        const e2 = writeBytes(mem, cursor, arg);
        if (e2 != .success) return e2;
        cursor += @intCast(arg.len);
        const e3 = writeBytes(mem, cursor, &[_]u8{0});
        if (e3 != .success) return e3;
        cursor += 1;
    }
    return .success;
}

// ============================================================
// environ_*
// ============================================================

/// Total bytes the guest needs to allocate to hold the env
/// strings. Each entry is `KEY=VAL\0`.
pub fn environBufSize(host: *const Host) u32 {
    var total: u32 = 0;
    for (host.envs) |e| total += @intCast(e.key.len + 1 + e.value.len + 1);
    return total;
}

pub fn environSizesGet(
    host: *const Host,
    mem: []u8,
    count_ptr: u32,
    buf_size_ptr: u32,
) p1.Errno {
    const e1 = writeU32LE(mem, count_ptr, @intCast(host.envs.len));
    if (e1 != .success) return e1;
    return writeU32LE(mem, buf_size_ptr, environBufSize(host));
}

pub fn environGet(
    host: *const Host,
    mem: []u8,
    environ_ptr: u32,
    environ_buf_ptr: u32,
) p1.Errno {
    var cursor: u32 = environ_buf_ptr;
    for (host.envs, 0..) |e, i| {
        const ptr_off: u32 = @intCast(environ_ptr + i * 4);
        const e1 = writeU32LE(mem, ptr_off, cursor);
        if (e1 != .success) return e1;
        const e2 = writeBytes(mem, cursor, e.key);
        if (e2 != .success) return e2;
        cursor += @intCast(e.key.len);
        const e3 = writeBytes(mem, cursor, "=");
        if (e3 != .success) return e3;
        cursor += 1;
        const e4 = writeBytes(mem, cursor, e.value);
        if (e4 != .success) return e4;
        cursor += @intCast(e.value.len);
        const e5 = writeBytes(mem, cursor, &[_]u8{0});
        if (e5 != .success) return e5;
        cursor += 1;
    }
    return .success;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "procExit: sets host.exit_code" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    try testing.expect(h.exit_code == null);
    const e = procExit(&h, 42);
    try testing.expectEqual(p1.Errno.success, e);
    try testing.expectEqual(@as(u32, 42), h.exit_code.?);
}

test "args_sizes_get: writes argc + total-byte-length" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var src: [2][]const u8 = .{ "zwasm", "hello" };
    try h.setArgs(&src);

    var mem: [16]u8 = @splat(0);
    const e = argsSizesGet(&h, &mem, 0, 4);
    try testing.expectEqual(p1.Errno.success, e);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, mem[0..4], .little));
    // "zwasm\0" = 6 bytes, "hello\0" = 6 bytes, total 12.
    try testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, mem[4..8], .little));
}

test "args_sizes_get: out-of-bounds argc_ptr returns fault" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [4]u8 = @splat(0);
    // argc_ptr = 100 is past the 4-byte buffer.
    const e = argsSizesGet(&h, &mem, 100, 0);
    try testing.expectEqual(p1.Errno.fault, e);
}

test "args_get: writes pointer table + null-terminated strings" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var src: [2][]const u8 = .{ "zwasm", "hello" };
    try h.setArgs(&src);

    var mem: [32]u8 = @splat(0);
    // argv_ptr at 0 (8 bytes for 2 u32 entries), strings at 8.
    const e = argsGet(&h, &mem, 0, 8);
    try testing.expectEqual(p1.Errno.success, e);

    // Pointer table.
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, mem[0..4], .little));
    try testing.expectEqual(@as(u32, 14), std.mem.readInt(u32, mem[4..8], .little));
    // Strings.
    try testing.expectEqualStrings("zwasm\x00", mem[8..14]);
    try testing.expectEqualStrings("hello\x00", mem[14..20]);
}

test "environ_sizes_get / environ_get: KEY=VALUE\\0 format" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    const keys: [2][]const u8 = .{ "PATH", "USER" };
    const vals: [2][]const u8 = .{ "/usr/bin", "root" };
    try h.setEnvs(&keys, &vals);

    var mem: [64]u8 = @splat(0);

    // sizes: count=2, buf_size = 4+1+8+1 + 4+1+4+1 = 14 + 10 = 24
    const se = environSizesGet(&h, &mem, 0, 4);
    try testing.expectEqual(p1.Errno.success, se);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, mem[0..4], .little));
    try testing.expectEqual(@as(u32, 24), std.mem.readInt(u32, mem[4..8], .little));

    // strings: ptr table at 0 (8 bytes), buf at 8.
    @memset(&mem, 0);
    const ge = environGet(&h, &mem, 0, 8);
    try testing.expectEqual(p1.Errno.success, ge);
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, mem[0..4], .little));
    try testing.expectEqual(@as(u32, 22), std.mem.readInt(u32, mem[4..8], .little));
    try testing.expectEqualStrings("PATH=/usr/bin\x00", mem[8..22]);
    try testing.expectEqualStrings("USER=root\x00", mem[22..32]);
}

test "args_get: empty args writes nothing" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [4]u8 = @splat(0xFF);
    const e = argsGet(&h, &mem, 0, 0);
    try testing.expectEqual(p1.Errno.success, e);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF }, &mem);
}

test "schedYield: no-op success (single-threaded host)" {
    try testing.expectEqual(p1.Errno.success, schedYield());
}

test "procRaise: notsup (no guest signal delivery in the sandbox)" {
    try testing.expectEqual(p1.Errno.notsup, procRaise(6)); // SIGABRT
    try testing.expectEqual(p1.Errno.notsup, procRaise(0));
}
