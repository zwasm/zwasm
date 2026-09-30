//! WASI-side of the C ABI binding (§9.5 / 5.0 carve-out from
//! `wasm.zig` per ADR-0007).
//!
//! Holds the host thunks that bridge guest WASI calls into the
//! `src/wasi/*.zig` handlers, the dispatcher
//! (`lookupWasiThunk`), and the standalone `zwasm_wasi_config_*`
//! C exports. `zwasm_store_set_wasi` stays in `wasm.zig`
//! because it touches the `Store` shape; it moves later with
//! `instance.zig`.
//!
//! Zone 3 — same as the rest of `src/api/`. May import any
//! lower zone (`interp/`, `wasi/`).

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("../runtime/runtime.zig");
const wasi_host = @import("../wasi/host.zig");
const wasi_fd = @import("../wasi/fd.zig");
const wasi_proc = @import("../wasi/proc.zig");
const wasi_clocks = @import("../wasi/clocks.zig");
const wasi_path = @import("../wasi/path.zig");
const Errno = @import("../wasi/preview1.zig").Errno;

const testing = std.testing;

// ============================================================
// WASI host config (§9.4 / 4.7 chunk a)
// ============================================================

/// `zwasm_wasi_config_new()` — allocate a fresh WASI host
/// config (the `zwasm_wasi_config_t` opaque type from
/// `include/wasi.h`). Internally aliases to `wasi_host.Host`.
/// Caller owns until `zwasm_store_set_wasi` transfers
/// ownership to a Store, OR until `zwasm_wasi_config_delete`.
///
/// Allocator: pinned to the engine's allocator path is not
/// possible since this function does not take an Engine. Uses
/// `std.heap.c_allocator` so the resulting Host is freeable
/// either through `_delete` here or through `wasm_store_delete`
/// once installed.
pub export fn zwasm_wasi_config_new() callconv(.c) ?*wasi_host.Host {
    const alloc = std.heap.c_allocator;
    const h = alloc.create(wasi_host.Host) catch return null;
    h.* = wasi_host.Host.init(alloc) catch {
        alloc.destroy(h);
        return null;
    };
    return h;
}

/// `zwasm_wasi_config_delete(*Host)` — free a config that was
/// NOT installed on a Store. Null-tolerant. After
/// `zwasm_store_set_wasi` consumes the config, the C host
/// must NOT call this on the same pointer.
pub export fn zwasm_wasi_config_delete(h: ?*wasi_host.Host) callconv(.c) void {
    const handle = h orelse return;
    handle.deinit();
    std.heap.c_allocator.destroy(handle);
}

/// `zwasm_wasi_config_set_args(cfg, argc, argv)` — explicit argv
/// override (`include/wasi.h`). Each `argv[i]` is a NUL-terminated
/// C string, borrowed for the call only — the config copies them
/// (`Host.setArgs` dupes). Null `cfg`/`argv` is a no-op. The C ABI
/// is void, so OOM leaves the config unchanged (no error channel).
pub export fn zwasm_wasi_config_set_args(
    h: ?*wasi_host.Host,
    argc: usize,
    argv: [*c]const [*c]const u8,
) callconv(.c) void {
    const handle = h orelse return;
    if (argv == null) return;
    const ca = std.heap.c_allocator;
    const tmp = ca.alloc([]const u8, argc) catch return;
    defer ca.free(tmp);
    for (0..argc) |i| tmp[i] = std.mem.span(argv[i]);
    handle.setArgs(tmp) catch return;
}

/// `zwasm_wasi_config_set_envs(cfg, count, keys, vals)` — explicit
/// environment override. `keys[i]`/`vals[i]` are NUL-terminated C
/// strings, borrowed for the call only (the config copies them).
/// Null `cfg`/`keys`/`vals` is a no-op; same void-ABI OOM contract
/// as `set_args`.
pub export fn zwasm_wasi_config_set_envs(
    h: ?*wasi_host.Host,
    count: usize,
    keys: [*c]const [*c]const u8,
    vals: [*c]const [*c]const u8,
) callconv(.c) void {
    const handle = h orelse return;
    if (keys == null or vals == null) return;
    const ca = std.heap.c_allocator;
    const k = ca.alloc([]const u8, count) catch return;
    defer ca.free(k);
    const v = ca.alloc([]const u8, count) catch return;
    defer ca.free(v);
    for (0..count) |i| {
        k[i] = std.mem.span(keys[i]);
        v[i] = std.mem.span(vals[i]);
    }
    handle.setEnvs(k, v) catch return;
}

/// `zwasm_wasi_config_preopen_dir(cfg, host_path, guest_path)` —
/// queue a host directory for preopening (`include/wasi.h`,
/// ADR-0184). Config time is io-free: the request is QUEUED here
/// and opened via the engine-owned io at `wasm_instance_new`,
/// where an unopenable path fails instantiation (the wasm-c-api
/// error-reporting point). Both paths are NUL-terminated C
/// strings, borrowed for the call only (copied). Returns true
/// when queued; false on null args or OOM.
pub export fn zwasm_wasi_config_preopen_dir(
    h: ?*wasi_host.Host,
    host_path: [*c]const u8,
    guest_path: [*c]const u8,
) callconv(.c) bool {
    const handle = h orelse return false;
    if (host_path == null or guest_path == null) return false;
    handle.addPendingPreopen(std.mem.span(host_path), std.mem.span(guest_path)) catch return false;
    return true;
}

/// `zwasm_wasi_config_inherit_env(cfg)` — snapshot the host
/// process's environment into the config (`include/wasi.h`,
/// ADR-0184), replacing any previously set envs (same replace
/// semantics as `set_envs`). Snapshot-at-call: later host-process
/// env mutations are not reflected. Returns true on success;
/// false on null cfg or snapshot/copy failure.
///
/// Env access at the C boundary: Windows reads the PEB via
/// `std.process.Environ` (`.global` block); POSIX reads the libc
/// `environ` block (`std.c.environ`, ADR-0070 Necessary — a C-ABI
/// export has no `std.process.Init` token, same constraint as
/// `std.c.getenv` in `wasm_engine_new`).
pub export fn zwasm_wasi_config_inherit_env(h: ?*wasi_host.Host) callconv(.c) bool {
    const handle = h orelse return false;
    const ca = std.heap.c_allocator;
    const env: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else posix_blk: {
        const raw = std.c.environ;
        var n: usize = 0;
        while (raw[n] != null) : (n += 1) {}
        break :posix_blk .{ .block = .{ .slice = raw[0..n :null] } };
    };
    var map = std.process.Environ.createMap(env, ca) catch return false;
    defer map.deinit();
    handle.setEnvs(map.keys(), map.values()) catch return false;
    return true;
}

/// `zwasm_wasi_config_inherit_stdio(cfg)` — route the guest's
/// stdin/stdout/stderr (fd 0/1/2) to the host process's stdio.
/// This is the default: `Host.init` already installs the three
/// stdio fds, so this is a documented no-op kept for wasm-c-api
/// API parity. Null `cfg` is a no-op.
pub export fn zwasm_wasi_config_inherit_stdio(h: ?*wasi_host.Host) callconv(.c) void {
    _ = h orelse return;
}

// ============================================================
// WASI host thunks (§9.4 / 4.7 chunk c)
// ============================================================
//
// Each thunk pops the guest-call args off the operand stack
// (right-to-left, since Wasm pushes left-to-right), invokes the
// corresponding `src/wasi/*.zig` handler with `host` + `mem` +
// the args, and pushes the resulting Errno back as an i32.
// `proc_exit` is the odd one out: it unwinds (see `src/wasi/proc.zig`).

/// Type-erased thunk pointer surface. The `*anyopaque` ctx is
/// the `*wasi_host.Host` installed on the Store at
/// instantiation time.
pub const HostThunkFn = *const fn (*runtime.Runtime, *anyopaque) anyerror!void;

fn thunkFdWrite(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const nwritten_ptr = rt.popOperand().u32;
    const ciovec_count = rt.popOperand().u32;
    const ciovec_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    const errno = wasi_fd.fdWrite(host, rt.memory, fd, ciovec_ptr, ciovec_count, nwritten_ptr);
    try rt.pushOperand(.{ .i32 = @intCast(@intFromEnum(errno)) });
}

fn thunkProcExit(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const rval = rt.popOperand().u32;
    _ = wasi_proc.procExit(host, rval);
    return error.ProcExit;
}

fn pushErrno(rt: *runtime.Runtime, errno: Errno) !void {
    try rt.pushOperand(.{ .i32 = @intCast(@intFromEnum(errno)) });
}

// args / environ thunks
fn thunkArgsSizesGet(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const buf_size_ptr = rt.popOperand().u32;
    const argc_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_proc.argsSizesGet(host, rt.memory, argc_ptr, buf_size_ptr));
}
fn thunkArgsGet(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const argv_buf_ptr = rt.popOperand().u32;
    const argv_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_proc.argsGet(host, rt.memory, argv_ptr, argv_buf_ptr));
}
fn thunkEnvironSizesGet(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const buf_size_ptr = rt.popOperand().u32;
    const count_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_proc.environSizesGet(host, rt.memory, count_ptr, buf_size_ptr));
}
fn thunkEnvironGet(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const environ_buf_ptr = rt.popOperand().u32;
    const environ_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_proc.environGet(host, rt.memory, environ_ptr, environ_buf_ptr));
}

// clock / random / poll thunks
fn thunkProcRaise(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    _ = ctx;
    const sig = rt.popOperand().u32;
    return pushErrno(rt, wasi_proc.procRaise(sig));
}
fn thunkClockTimeGet(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const time_ptr = rt.popOperand().u32;
    const precision = rt.popOperand().u64;
    const clock_id = rt.popOperand().u32;
    return pushErrno(rt, wasi_clocks.clockTimeGet(host, rt.memory, clock_id, precision, time_ptr));
}
fn thunkClockResGet(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const resolution_ptr = rt.popOperand().u32;
    const clock_id = rt.popOperand().u32;
    return pushErrno(rt, wasi_clocks.clockResGet(host, rt.memory, clock_id, resolution_ptr));
}
fn thunkRandomGet(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const buf_len = rt.popOperand().u32;
    const buf_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_clocks.randomGet(host, rt.memory, buf_ptr, buf_len));
}
fn thunkPollOneoff(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const nevents_ptr = rt.popOperand().u32;
    const nsubscriptions = rt.popOperand().u32;
    const out_ptr = rt.popOperand().u32;
    const in_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_clocks.pollOneoff(host, rt.memory, in_ptr, out_ptr, nsubscriptions, nevents_ptr));
}

// fd thunks
fn thunkFdRead(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const nread_ptr = rt.popOperand().u32;
    const iovec_count = rt.popOperand().u32;
    const iovec_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdRead(host, rt.memory, fd, iovec_ptr, iovec_count, nread_ptr));
}
fn thunkFdClose(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdClose(host, fd));
}
fn thunkFdSync(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdSync(host, fd));
}
fn thunkFdDatasync(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdDatasync(host, fd));
}
fn thunkFdAdvise(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const advice: u8 = @intCast(rt.popOperand().u32 & 0xFF);
    const len = rt.popOperand().u64;
    const offset = rt.popOperand().u64;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdAdvise(host, fd, offset, len, advice));
}
fn thunkFdFdstatSetRights(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const rights_inheriting = rt.popOperand().u64;
    const rights_base = rt.popOperand().u64;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdFdstatSetRights(host, fd, rights_base, rights_inheriting));
}
fn thunkFdReaddir(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const bufused_ptr = rt.popOperand().u32;
    const cookie = rt.popOperand().u64;
    const buf_len = rt.popOperand().u32;
    const buf_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdReaddir(host, rt.memory, fd, buf_ptr, buf_len, cookie, bufused_ptr));
}
fn thunkFdFilestatSetSize(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const size = rt.popOperand().u64;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdFilestatSetSize(host, fd, size));
}
fn thunkFdAllocate(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const len = rt.popOperand().u64;
    const offset = rt.popOperand().u64;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdAllocate(host, fd, offset, len));
}
fn thunkFdFilestatSetTimes(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const fst_flags: u16 = @intCast(rt.popOperand().u32 & 0xFFFF);
    const mtim = rt.popOperand().u64;
    const atim = rt.popOperand().u64;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdFilestatSetTimes(host, fd, atim, mtim, fst_flags));
}
fn thunkFdPread(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const nread_ptr = rt.popOperand().u32;
    const offset = rt.popOperand().u64;
    const iovec_count = rt.popOperand().u32;
    const iovec_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdPread(host, rt.memory, fd, iovec_ptr, iovec_count, offset, nread_ptr));
}
fn thunkFdPwrite(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const nwritten_ptr = rt.popOperand().u32;
    const offset = rt.popOperand().u64;
    const ciovec_count = rt.popOperand().u32;
    const ciovec_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdPwrite(host, rt.memory, fd, ciovec_ptr, ciovec_count, offset, nwritten_ptr));
}
fn thunkSockAccept(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    _ = rt.popOperand().u32; // new_fd_ptr
    _ = rt.popOperand().u32; // fdflags
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.sockAccept(host, fd));
}
fn thunkSockRecv(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    _ = rt.popOperand().u32; // ro_flags_ptr
    _ = rt.popOperand().u32; // ro_datalen_ptr
    _ = rt.popOperand().u32; // ri_flags
    _ = rt.popOperand().u32; // ri_data_len
    _ = rt.popOperand().u32; // ri_data_ptr
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.sockRecv(host, fd));
}
fn thunkSockSend(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    _ = rt.popOperand().u32; // so_datalen_ptr
    _ = rt.popOperand().u32; // si_flags
    _ = rt.popOperand().u32; // si_data_len
    _ = rt.popOperand().u32; // si_data_ptr
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.sockSend(host, fd));
}
fn thunkSockShutdown(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    _ = rt.popOperand().u32; // how
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.sockShutdown(host, fd));
}
fn thunkFdRenumber(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const to = rt.popOperand().u32;
    const from = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdRenumber(host, from, to));
}
fn thunkFdSeek(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const new_pos_ptr = rt.popOperand().u32;
    const whence: u8 = @intCast(rt.popOperand().u32 & 0xFF);
    const offset = rt.popOperand().i64;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdSeek(host, rt.memory, fd, offset, whence, new_pos_ptr));
}
fn thunkFdTell(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const pos_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdTell(host, rt.memory, fd, pos_ptr));
}
fn thunkFdFdstatGet(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const fdstat_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdFdstatGet(host, rt.memory, fd, fdstat_ptr));
}
fn thunkFdFdstatSetFlags(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const flags: u16 = @intCast(rt.popOperand().u32 & 0xFFFF);
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdFdstatSetFlags(host, fd, flags));
}
fn thunkPathOpen(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const opened_fd_ptr = rt.popOperand().u32;
    const fdflags: u16 = @intCast(rt.popOperand().u32 & 0xFFFF);
    const fs_rights_inheriting = rt.popOperand().u64;
    const fs_rights_base = rt.popOperand().u64;
    const oflags: u16 = @intCast(rt.popOperand().u32 & 0xFFFF);
    const path_len = rt.popOperand().u32;
    const path_ptr = rt.popOperand().u32;
    const dirflags = rt.popOperand().u32;
    const dirfd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.pathOpen(host, rt.memory, dirfd, dirflags, path_ptr, path_len, oflags, fs_rights_base, fs_rights_inheriting, fdflags, opened_fd_ptr));
}

fn thunkFdPrestatGet(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const prestat_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdPrestatGet(host, rt.memory, fd, prestat_ptr));
}
fn thunkFdPrestatDirName(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const path_len = rt.popOperand().u32;
    const path_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdPrestatDirName(host, rt.memory, fd, path_ptr, path_len));
}
fn thunkSchedYield(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    _ = ctx;
    return pushErrno(rt, wasi_proc.schedYield());
}
fn thunkFdFilestatGet(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const filestat_ptr = rt.popOperand().u32;
    const fd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.fdFilestatGet(host, rt.memory, fd, filestat_ptr));
}
fn thunkPathUnlinkFile(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const path_len = rt.popOperand().u32;
    const path_ptr = rt.popOperand().u32;
    const dirfd = rt.popOperand().u32;
    return pushErrno(rt, wasi_fd.pathUnlinkFile(host, rt.memory, dirfd, path_ptr, path_len));
}
fn thunkPathCreateDirectory(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const path_len = rt.popOperand().u32;
    const path_ptr = rt.popOperand().u32;
    const dirfd = rt.popOperand().u32;
    return pushErrno(rt, wasi_path.pathCreateDirectory(host, rt.memory, dirfd, path_ptr, path_len));
}
fn thunkPathRemoveDirectory(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const path_len = rt.popOperand().u32;
    const path_ptr = rt.popOperand().u32;
    const dirfd = rt.popOperand().u32;
    return pushErrno(rt, wasi_path.pathRemoveDirectory(host, rt.memory, dirfd, path_ptr, path_len));
}
fn thunkPathRename(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const new_len = rt.popOperand().u32;
    const new_ptr = rt.popOperand().u32;
    const new_dirfd = rt.popOperand().u32;
    const old_len = rt.popOperand().u32;
    const old_ptr = rt.popOperand().u32;
    const old_dirfd = rt.popOperand().u32;
    return pushErrno(rt, wasi_path.pathRename(host, rt.memory, old_dirfd, old_ptr, old_len, new_dirfd, new_ptr, new_len));
}
fn thunkPathLink(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const new_len = rt.popOperand().u32;
    const new_ptr = rt.popOperand().u32;
    const new_dirfd = rt.popOperand().u32;
    const old_len = rt.popOperand().u32;
    const old_ptr = rt.popOperand().u32;
    const old_flags = rt.popOperand().u32;
    const old_dirfd = rt.popOperand().u32;
    return pushErrno(rt, wasi_path.pathLink(host, rt.memory, old_dirfd, old_flags, old_ptr, old_len, new_dirfd, new_ptr, new_len));
}
fn thunkPathSymlink(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const path_len = rt.popOperand().u32;
    const path_ptr = rt.popOperand().u32;
    const dirfd = rt.popOperand().u32;
    const target_len = rt.popOperand().u32;
    const target_ptr = rt.popOperand().u32;
    return pushErrno(rt, wasi_path.pathSymlink(host, rt.memory, target_ptr, target_len, dirfd, path_ptr, path_len));
}
fn thunkPathReadlink(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const bufused_ptr = rt.popOperand().u32;
    const buf_len = rt.popOperand().u32;
    const buf_ptr = rt.popOperand().u32;
    const path_len = rt.popOperand().u32;
    const path_ptr = rt.popOperand().u32;
    const dirfd = rt.popOperand().u32;
    return pushErrno(rt, wasi_path.pathReadlink(host, rt.memory, dirfd, path_ptr, path_len, buf_ptr, buf_len, bufused_ptr));
}
fn thunkPathFilestatGet(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const filestat_ptr = rt.popOperand().u32;
    const path_len = rt.popOperand().u32;
    const path_ptr = rt.popOperand().u32;
    const lookupflags = rt.popOperand().u32;
    const dirfd = rt.popOperand().u32;
    return pushErrno(rt, wasi_path.pathFilestatGet(host, rt.memory, dirfd, lookupflags, path_ptr, path_len, filestat_ptr));
}
fn thunkPathFilestatSetTimes(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const host: *wasi_host.Host = @ptrCast(@alignCast(ctx));
    const fst_flags: u16 = @intCast(rt.popOperand().u32 & 0xFFFF);
    const mtim = rt.popOperand().u64;
    const atim = rt.popOperand().u64;
    const path_len = rt.popOperand().u32;
    const path_ptr = rt.popOperand().u32;
    const lookupflags = rt.popOperand().u32;
    const dirfd = rt.popOperand().u32;
    return pushErrno(rt, wasi_path.pathFilestatSetTimes(host, rt.memory, dirfd, lookupflags, path_ptr, path_len, atim, mtim, fst_flags));
}

/// Map a WASI snapshot-1 import name to its host thunk, or
/// null if the name is outside the supported set.
pub fn lookupWasiThunk(name: []const u8) ?HostThunkFn {
    if (std.mem.eql(u8, name, "fd_write")) return thunkFdWrite;
    if (std.mem.eql(u8, name, "proc_exit")) return thunkProcExit;
    if (std.mem.eql(u8, name, "args_get")) return thunkArgsGet;
    if (std.mem.eql(u8, name, "args_sizes_get")) return thunkArgsSizesGet;
    if (std.mem.eql(u8, name, "environ_get")) return thunkEnvironGet;
    if (std.mem.eql(u8, name, "environ_sizes_get")) return thunkEnvironSizesGet;
    if (std.mem.eql(u8, name, "clock_time_get")) return thunkClockTimeGet;
    if (std.mem.eql(u8, name, "clock_res_get")) return thunkClockResGet;
    if (std.mem.eql(u8, name, "random_get")) return thunkRandomGet;
    if (std.mem.eql(u8, name, "poll_oneoff")) return thunkPollOneoff;
    if (std.mem.eql(u8, name, "fd_read")) return thunkFdRead;
    if (std.mem.eql(u8, name, "fd_close")) return thunkFdClose;
    if (std.mem.eql(u8, name, "fd_sync")) return thunkFdSync;
    if (std.mem.eql(u8, name, "fd_datasync")) return thunkFdDatasync;
    if (std.mem.eql(u8, name, "fd_advise")) return thunkFdAdvise;
    if (std.mem.eql(u8, name, "fd_pread")) return thunkFdPread;
    if (std.mem.eql(u8, name, "fd_pwrite")) return thunkFdPwrite;
    if (std.mem.eql(u8, name, "fd_renumber")) return thunkFdRenumber;
    if (std.mem.eql(u8, name, "fd_seek")) return thunkFdSeek;
    if (std.mem.eql(u8, name, "fd_tell")) return thunkFdTell;
    if (std.mem.eql(u8, name, "fd_fdstat_get")) return thunkFdFdstatGet;
    if (std.mem.eql(u8, name, "fd_fdstat_set_flags")) return thunkFdFdstatSetFlags;
    if (std.mem.eql(u8, name, "fd_fdstat_set_rights")) return thunkFdFdstatSetRights;
    if (std.mem.eql(u8, name, "fd_readdir")) return thunkFdReaddir;
    if (std.mem.eql(u8, name, "path_open")) return thunkPathOpen;
    if (std.mem.eql(u8, name, "fd_prestat_get")) return thunkFdPrestatGet;
    if (std.mem.eql(u8, name, "fd_prestat_dir_name")) return thunkFdPrestatDirName;
    if (std.mem.eql(u8, name, "sched_yield")) return thunkSchedYield;
    if (std.mem.eql(u8, name, "proc_raise")) return thunkProcRaise;
    if (std.mem.eql(u8, name, "sock_accept")) return thunkSockAccept;
    if (std.mem.eql(u8, name, "sock_recv")) return thunkSockRecv;
    if (std.mem.eql(u8, name, "sock_send")) return thunkSockSend;
    if (std.mem.eql(u8, name, "sock_shutdown")) return thunkSockShutdown;
    if (std.mem.eql(u8, name, "fd_filestat_get")) return thunkFdFilestatGet;
    if (std.mem.eql(u8, name, "fd_filestat_set_size")) return thunkFdFilestatSetSize;
    if (std.mem.eql(u8, name, "fd_filestat_set_times")) return thunkFdFilestatSetTimes;
    if (std.mem.eql(u8, name, "fd_allocate")) return thunkFdAllocate;
    if (std.mem.eql(u8, name, "path_unlink_file")) return thunkPathUnlinkFile;
    if (std.mem.eql(u8, name, "path_create_directory")) return thunkPathCreateDirectory;
    if (std.mem.eql(u8, name, "path_remove_directory")) return thunkPathRemoveDirectory;
    if (std.mem.eql(u8, name, "path_filestat_get")) return thunkPathFilestatGet;
    if (std.mem.eql(u8, name, "path_filestat_set_times")) return thunkPathFilestatSetTimes;
    if (std.mem.eql(u8, name, "path_symlink")) return thunkPathSymlink;
    if (std.mem.eql(u8, name, "path_readlink")) return thunkPathReadlink;
    if (std.mem.eql(u8, name, "path_rename")) return thunkPathRename;
    if (std.mem.eql(u8, name, "path_link")) return thunkPathLink;
    return null;
}

// ============================================================
// Tests
// ============================================================

test "zwasm_wasi_config_delete: standalone (not installed on Store) is leak-free" {
    const cfg = zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    zwasm_wasi_config_delete(cfg);
}

test "zwasm_wasi_config_delete: null-arg discipline" {
    zwasm_wasi_config_delete(null);
}

test "zwasm_wasi_config_set_args: copies C argv into host.args" {
    const cfg = zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    defer zwasm_wasi_config_delete(cfg);
    const argv = [_][*c]const u8{ "prog", "--flag", "x" };
    zwasm_wasi_config_set_args(cfg, argv.len, &argv);
    try testing.expectEqual(@as(usize, 3), cfg.args.len);
    try testing.expectEqualStrings("prog", cfg.args[0]);
    try testing.expectEqualStrings("--flag", cfg.args[1]);
    try testing.expectEqualStrings("x", cfg.args[2]);
}

test "zwasm_wasi_config_set_args: null cfg / null argv are no-ops" {
    zwasm_wasi_config_set_args(null, 0, null);
    const cfg = zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    defer zwasm_wasi_config_delete(cfg);
    zwasm_wasi_config_set_args(cfg, 5, null);
    try testing.expectEqual(@as(usize, 0), cfg.args.len);
}

test "zwasm_wasi_config_inherit_stdio: no-op leaves the 3 default stdio fds intact" {
    const cfg = zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    defer zwasm_wasi_config_delete(cfg);
    zwasm_wasi_config_inherit_stdio(cfg);
    zwasm_wasi_config_inherit_stdio(null);
    try testing.expectEqual(@as(usize, 3), cfg.fd_table.items.len);
}

test "zwasm_wasi_config_set_envs: copies key/val pairs into host.envs" {
    const cfg = zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    defer zwasm_wasi_config_delete(cfg);
    const keys = [_][*c]const u8{ "HOME", "PATH" };
    const vals = [_][*c]const u8{ "/root", "/bin" };
    zwasm_wasi_config_set_envs(cfg, keys.len, &keys, &vals);
    try testing.expectEqual(@as(usize, 2), cfg.envs.len);
    try testing.expectEqualStrings("HOME", cfg.envs[0].key);
    try testing.expectEqualStrings("/root", cfg.envs[0].value);
    try testing.expectEqualStrings("PATH", cfg.envs[1].key);
    try testing.expectEqualStrings("/bin", cfg.envs[1].value);
}

test "zwasm_wasi_config_preopen_dir: queues a pending preopen (copies both paths)" {
    const cfg = zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    defer zwasm_wasi_config_delete(cfg);
    try testing.expect(zwasm_wasi_config_preopen_dir(cfg, ".", "/sandbox"));
    try testing.expectEqual(@as(usize, 1), cfg.pending_preopens.items.len);
    try testing.expectEqualStrings(".", cfg.pending_preopens.items[0].host_path);
    try testing.expectEqualStrings("/sandbox", cfg.pending_preopens.items[0].guest_path);
    // Not opened yet — config time is io-free (ADR-0184).
    try testing.expectEqual(@as(usize, 0), cfg.preopens.len);
}

test "zwasm_wasi_config_preopen_dir: null-arg discipline" {
    try testing.expect(!zwasm_wasi_config_preopen_dir(null, ".", "/s"));
    const cfg = zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    defer zwasm_wasi_config_delete(cfg);
    try testing.expect(!zwasm_wasi_config_preopen_dir(cfg, null, "/s"));
    try testing.expect(!zwasm_wasi_config_preopen_dir(cfg, ".", null));
    try testing.expectEqual(@as(usize, 0), cfg.pending_preopens.items.len);
}

test "zwasm_wasi_config_inherit_env: snapshots the process environment (ADR-0184)" {
    const cfg = zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    defer zwasm_wasi_config_delete(cfg);
    try testing.expect(zwasm_wasi_config_inherit_env(cfg));
    // The test runner always carries at least one env var
    // (PATH / HOME on POSIX; SystemRoot etc. on Windows).
    try testing.expect(cfg.envs.len > 0);
    for (cfg.envs) |e| try testing.expect(e.key.len > 0);
}

test "zwasm_wasi_config_inherit_env: null-arg discipline; replaces explicit envs" {
    try testing.expect(!zwasm_wasi_config_inherit_env(null));
    const cfg = zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    defer zwasm_wasi_config_delete(cfg);
    const keys = [_][*c]const u8{"ZWASM_TEST_SENTINEL_KEY"};
    const vals = [_][*c]const u8{"1"};
    zwasm_wasi_config_set_envs(cfg, keys.len, &keys, &vals);
    try testing.expectEqual(@as(usize, 1), cfg.envs.len);
    try testing.expect(zwasm_wasi_config_inherit_env(cfg));
    // setEnvs is replace-semantics: the sentinel pair is gone.
    for (cfg.envs) |e| try testing.expect(!std.mem.eql(u8, e.key, "ZWASM_TEST_SENTINEL_KEY"));
}

test "lookupWasiThunk: every supported WASI 0.1 import resolves" {
    const names = [_][]const u8{
        "fd_write",              "proc_exit",
        "args_get",              "args_sizes_get",
        "environ_get",           "environ_sizes_get",
        "clock_time_get",        "clock_res_get",
        "random_get",            "poll_oneoff",
        "fd_read",               "fd_close",
        "fd_sync",               "fd_datasync",
        "fd_advise",             "fd_pread",
        "fd_pwrite",             "fd_renumber",
        "fd_seek",               "fd_tell",
        "fd_fdstat_get",         "fd_fdstat_set_flags",
        "fd_fdstat_set_rights",  "fd_readdir",
        "path_open",             "fd_prestat_get",
        "fd_prestat_dir_name",   "sched_yield",
        "proc_raise",            "sock_accept",
        "sock_recv",             "sock_send",
        "sock_shutdown",         "fd_filestat_get",
        "fd_filestat_set_size",  "fd_filestat_set_times",
        "fd_allocate",           "path_unlink_file",
        "path_create_directory", "path_remove_directory",
        "path_filestat_get",     "path_filestat_set_times",
        "path_symlink",          "path_readlink",
        "path_rename",           "path_link",
    };
    inline for (names) |n| {
        try testing.expect(lookupWasiThunk(n) != null);
    }
    try testing.expect(lookupWasiThunk("does_not_exist") == null);
}
