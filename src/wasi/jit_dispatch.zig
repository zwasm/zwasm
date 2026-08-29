// FILE-SIZE-EXEMPT: uniform 48-trampoline C-ABI catalog for JIT host dispatch; a split yields N3-shallow siblings (investigated 2026-08-12, per ADR-0099)
//! WASI snapshot-preview1 dispatch trampolines for the JIT path
//! (chunk 7.9-d-2). C-ABI function pointers planted into
//! `JitRuntime.host_dispatch_base[idx]` by `runner.zig` when an
//! import's `(module, name)` matches a known WASI handler.
//!
//! Calling convention (load-bearing per chunk d-1 design):
//! every handler takes `rt: *JitRuntime` as its first arg
//! followed by the Wasm-declared params per the platform C ABI.
//! The JIT-side reserves arg0 for `runtime_ptr`, so the handler
//! sees the JitRuntime ptr in X0 / RDI / RCX without any
//! trampoline reshuffling. Handlers translate Wasm linear-memory
//! offsets (i32 args) into Zig pointers via `rt.vm_base + off`.
//!
//! Scope (d-2 MVP — the minimum to lift any realworld fixture
//! from COMPILE-PASS to RUN-PASS):
//! - `fd_write` — write iovec slice to stdout / stderr.
//! - `clock_time_get` — POSIX CLOCK_REALTIME / CLOCK_MONOTONIC.
//! - `random_get` — POSIX getrandom.
//! - `args_sizes_get` / `args_get` — return 0/empty (no argv).
//! - `environ_sizes_get` / `environ_get` — return 0/empty.
//!
//! Out of d-2 scope (deferred to d-3):
//! - `proc_exit` — semantics require non-returning + exit-code
//!   plumbing through JitRuntime. Default trap trampoline
//!   continues to handle it (sets trap_flag = 1). Wasm programs
//!   that call proc_exit will surface as Error.Trap to the host
//!   after the host stub returns.
//! - File-descriptor open / read / seek / close — needs a
//!   capability layer (preopens) which is itself post-d-2.
//!
//! Zone 2 (`src/wasi/`).

const std = @import("std");
const builtin = @import("builtin");
const jit_abi = @import("../engine/codegen/shared/jit_abi.zig");
const sections = @import("../parse/sections.zig");
// D-244 (JIT-WASI): when `rt.wasi_host` is set, the thin JIT thunks delegate
// to the SAME ABI-agnostic handlers the interp uses (`(host, mem, ...args)`),
// avoiding a second 46-syscall implementation.
const wasi_host_mod = @import("host.zig");
const wasi_clocks = @import("clocks.zig");
const wasi_fd = @import("fd.zig");
const wasi_proc = @import("proc.zig");
const wasi_path = @import("path.zig");
const dbg = @import("../support/dbg.zig");

const JitRuntime = jit_abi.JitRuntime;
const Errno = enum(i32) {
    success = 0,
    badf = 8,
    fault = 21,
    inval = 28,
    io = 29,
    nosys = 52,
};

/// `wasi_snapshot_preview1.fd_write(fd, iovs_ptr, iovs_len,
/// nwritten_ptr) -> errno` — write iovec array to a file
/// descriptor. The Wasm caller hands us four i32 values plus the
/// hidden runtime_ptr. iovs is an array of `(buf_off: u32,
/// buf_len: u32)` pairs at `vm_base + iovs_ptr`.
///
/// d-2 MVP supports fd 1 (stdout) + fd 2 (stderr) only; other
/// fds return EBADF. Bounds checks reject iov entries that
/// extend past `mem_limit`.
pub fn fd_write(
    rt: *JitRuntime,
    fd: i32,
    iovs_ptr: i32,
    iovs_len: i32,
    nwritten_ptr: i32,
) callconv(.c) i32 {
    // D-331A: fingerprint linear memory at the host-call boundary (interp-vs-jit diff).
    dbg.print("mem.cksum", "jit fd_write {x}", .{dbg.fnv1a(memOf(rt))});
    // D-489 fmtwatch: track the tinygo_json fmt string ("name=%s age=%d city=%s") in
    // guest rodata at each fd_write — the transition intact→corrupted localizes the
    // guest-mem corruption to a specific host-call boundary (rodata = random_get-free).
    if (dbg.on("fmtwatch")) {
        const gm = memOf(rt);
        if (std.mem.find(u8, gm, "name=%s age=%d")) |off| {
            std.debug.print("[fmtwatch] fd={d} fmt@{d} INTACT\n", .{ fd, off });
        } else {
            std.debug.print("[fmtwatch] fd={d} fmt CORRUPTED (name=%s gone)\n", .{fd});
        }
    }
    // D-244: with a host, delegate to the shared interp handler — it gathers
    // the ciovecs, routes to the host's real stdout/stderr (or capture buffer),
    // and supports file fds, none of which the compute-only stub does.
    if (rt.wasi_host) |hp| {
        const host: *wasi_host_mod.Host = @ptrCast(@alignCast(hp));
        const mem = rt.vm_base[0..@intCast(rt.mem_limit)];
        return @intCast(@intFromEnum(wasi_fd.fdWrite(host, mem, @bitCast(fd), @bitCast(iovs_ptr), @bitCast(iovs_len), @bitCast(nwritten_ptr))));
    }
    const writer_kind: enum { stdout, stderr, bad } = switch (fd) {
        1 => .stdout,
        2 => .stderr,
        else => .bad,
    };
    if (writer_kind == .bad) return @intFromEnum(Errno.badf);

    if (iovs_ptr < 0 or iovs_len < 0 or nwritten_ptr < 0) {
        return @intFromEnum(Errno.inval);
    }
    const iovs_off: u64 = @intCast(iovs_ptr);
    const iovs_n: u64 = @intCast(iovs_len);
    const iovs_total_bytes: u64 = iovs_n * 8;
    if (iovs_off + iovs_total_bytes > rt.mem_limit) {
        return @intFromEnum(Errno.fault);
    }
    const nwritten_off: u64 = @intCast(nwritten_ptr);
    if (nwritten_off + 4 > rt.mem_limit) return @intFromEnum(Errno.fault);

    var total_written: u32 = 0;
    var i: u64 = 0;
    while (i < iovs_n) : (i += 1) {
        const iov_at: usize = @intCast(iovs_off + i * 8);
        const buf_off = std.mem.readInt(u32, rt.vm_base[iov_at..][0..4], .little);
        const buf_len = std.mem.readInt(u32, rt.vm_base[iov_at + 4 ..][0..4], .little);
        const buf_off_u: u64 = buf_off;
        const buf_len_u: u64 = buf_len;
        if (buf_off_u + buf_len_u > rt.mem_limit) return @intFromEnum(Errno.fault);
        // d-2 MVP: count bytes only — actual stdout / stderr
        // routing needs `std.Io` plumbing through JitRuntime,
        // which lands alongside the run_runner_jit harness in
        // chunk d-3. Bounds-check the slice (the harness will
        // observe bytes from `vm_base[buf_off..buf_off+buf_len]`
        // post-call when output capture is wired).
        _ = rt.vm_base[@intCast(buf_off_u)..][0..@intCast(buf_len_u)];
        total_written +%= @intCast(buf_len);
    }
    const nw_at: usize = @intCast(nwritten_off);
    std.mem.writeInt(u32, rt.vm_base[nw_at..][0..4], total_written, .little);
    return @intFromEnum(Errno.success);
}

/// `wasi_snapshot_preview1.fd_read(fd, iovs_ptr, iovs_len,
/// nread_ptr) -> errno` — scatter-read into an iovec array.
/// MVP supports fd 0 (stdin) only; other fds return EBADF.
/// Stdin is not yet plumbed through `JitRuntime`, so the MVP
/// reports EOF: writes 0 into `*nread` and returns success.
/// This lets fixtures that probe stdin (e.g. `read 0 bytes`)
/// reach `proc_exit` cleanly rather than trapping at the WASI
/// boundary. Real stdin sourcing lands once a `WasiContext`
/// tail-extension to `JitRuntime` is justified by a fixture
/// that genuinely needs input bytes.
pub fn fd_read(
    rt: *JitRuntime,
    fd: i32,
    iovs_ptr: i32,
    iovs_len: i32,
    nread_ptr: i32,
) callconv(.c) i32 {
    // D-244: with a host, delegate to the shared interp handler (reads from the
    // host's real stdin / file fds; the stub only EOF-stubbed fd 0).
    if (rt.wasi_host) |hp| {
        const host: *wasi_host_mod.Host = @ptrCast(@alignCast(hp));
        const mem = rt.vm_base[0..@intCast(rt.mem_limit)];
        return @intCast(@intFromEnum(wasi_fd.fdRead(host, mem, @bitCast(fd), @bitCast(iovs_ptr), @bitCast(iovs_len), @bitCast(nread_ptr))));
    }
    if (fd != 0) return @intFromEnum(Errno.badf);
    if (iovs_ptr < 0 or iovs_len < 0 or nread_ptr < 0) {
        return @intFromEnum(Errno.inval);
    }
    const iovs_off: u64 = @intCast(iovs_ptr);
    const iovs_n: u64 = @intCast(iovs_len);
    if (iovs_off + iovs_n * 8 > rt.mem_limit) {
        return @intFromEnum(Errno.fault);
    }
    const nread_off: u64 = @intCast(nread_ptr);
    if (nread_off + 4 > rt.mem_limit) return @intFromEnum(Errno.fault);

    // Walk every iovec to validate buffer bounds even though we
    // write nothing — guests that hand us a malformed iovec must
    // see EFAULT, not a quiet 0-bytes-read success.
    var i: u64 = 0;
    while (i < iovs_n) : (i += 1) {
        const iov_at: usize = @intCast(iovs_off + i * 8);
        const buf_off = std.mem.readInt(u32, rt.vm_base[iov_at..][0..4], .little);
        const buf_len = std.mem.readInt(u32, rt.vm_base[iov_at + 4 ..][0..4], .little);
        const buf_off_u: u64 = buf_off;
        const buf_len_u: u64 = buf_len;
        if (buf_off_u + buf_len_u > rt.mem_limit) return @intFromEnum(Errno.fault);
    }

    const nw_at: usize = @intCast(nread_off);
    std.mem.writeInt(u32, rt.vm_base[nw_at..][0..4], 0, .little);
    return @intFromEnum(Errno.success);
}

/// `wasi_snapshot_preview1.clock_time_get(clock_id, precision,
/// time_ptr) -> errno` — write current nanos into `vm_base +
/// time_ptr`. Supports CLOCK_REALTIME (0) and CLOCK_MONOTONIC
/// (1); other clock_ids return EINVAL.
pub fn clock_time_get(
    rt: *JitRuntime,
    clock_id: i32,
    precision: i64,
    time_ptr: i32,
) callconv(.c) i32 {
    dbg.print("mem.cksum", "jit clock_time_get {x}", .{dbg.fnv1a(memOf(rt))});
    // D-244: with a host attached (`--engine jit` + WASI), delegate to the
    // shared interp handler for a REAL clock read; the handler bounds-checks
    // and writes the nanoseconds itself.
    if (rt.wasi_host) |hp| {
        const host: *wasi_host_mod.Host = @ptrCast(@alignCast(hp));
        const mem = rt.vm_base[0..@intCast(rt.mem_limit)];
        const e = wasi_clocks.clockTimeGet(host, mem, @bitCast(clock_id), @bitCast(precision), @bitCast(time_ptr));
        return @intCast(@intFromEnum(e));
    }
    // precision is ignored on the fallback path (OS clocks are single-resolution).
    if (time_ptr < 0) return @intFromEnum(Errno.inval);
    const off: u64 = @intCast(time_ptr);
    if (off + 8 > rt.mem_limit) return @intFromEnum(Errno.fault);
    if (clock_id < 0 or clock_id > 3) return @intFromEnum(Errno.inval);
    // Compute-only fallback (no host): write 0 nanos (deterministic + safe
    // against missing stdlib clock symbols on locked-down hosts).
    const at: usize = @intCast(off);
    std.mem.writeInt(u64, rt.vm_base[at..][0..8], 0, .little);
    return @intFromEnum(Errno.success);
}

/// `wasi_snapshot_preview1.random_get(buf_ptr, buf_len) -> errno`
/// — fill `vm_base + buf_ptr` with `buf_len` random bytes via
/// std.posix.getrandom (unix) / std.crypto.random (fallback).
pub fn random_get(rt: *JitRuntime, buf_ptr: i32, buf_len: i32) callconv(.c) i32 {
    dbg.print("mem.cksum", "jit random_get {x}", .{dbg.fnv1a(memOf(rt))});
    // D-244: with a host, delegate to the shared interp handler for REAL
    // cryptographic entropy (it bounds-checks + fills from host.io).
    if (rt.wasi_host) |hp| {
        const host: *wasi_host_mod.Host = @ptrCast(@alignCast(hp));
        const mem = rt.vm_base[0..@intCast(rt.mem_limit)];
        return @intCast(@intFromEnum(wasi_clocks.randomGet(host, mem, @bitCast(buf_ptr), @bitCast(buf_len))));
    }
    if (buf_ptr < 0 or buf_len < 0) return @intFromEnum(Errno.inval);
    const off: u64 = @intCast(buf_ptr);
    const len: u64 = @intCast(buf_len);
    if (off + len > rt.mem_limit) return @intFromEnum(Errno.fault);
    if (len == 0) return @intFromEnum(Errno.success);
    const at: usize = @intCast(off);
    const slice = rt.vm_base[at..][0..@intCast(len)];
    // Compute-only fallback (no host): zero-fill — deterministic + safe,
    // and preferable for the realworld JIT differential corpus (interp ==
    // arm64 == x86_64 §9.7 / 7.11 gate).
    @memset(slice, 0);
    return @intFromEnum(Errno.success);
}

/// `args_sizes_get(argc_ptr, argv_buf_size_ptr) -> errno` —
/// d-2 stub returns 0/0 (no args). Real argv plumbing lands in
/// d-3 alongside a `WasiContext` JitRuntime tail-extension.
pub fn args_sizes_get(rt: *JitRuntime, argc_ptr: i32, argv_buf_size_ptr: i32) callconv(.c) i32 {
    dbg.print("mem.cksum", "jit args_sizes_get {x}", .{dbg.fnv1a(memOf(rt))});
    if (rt.wasi_host) |hp| {
        const host: *wasi_host_mod.Host = @ptrCast(@alignCast(hp));
        const mem = rt.vm_base[0..@intCast(rt.mem_limit)];
        return @intCast(@intFromEnum(wasi_proc.argsSizesGet(host, mem, @bitCast(argc_ptr), @bitCast(argv_buf_size_ptr))));
    }
    if (argc_ptr < 0 or argv_buf_size_ptr < 0) return @intFromEnum(Errno.inval);
    const argc_off: u64 = @intCast(argc_ptr);
    const argv_off: u64 = @intCast(argv_buf_size_ptr);
    if (argc_off + 4 > rt.mem_limit or argv_off + 4 > rt.mem_limit) {
        return @intFromEnum(Errno.fault);
    }
    std.mem.writeInt(u32, rt.vm_base[@intCast(argc_off)..][0..4], 0, .little);
    std.mem.writeInt(u32, rt.vm_base[@intCast(argv_off)..][0..4], 0, .little);
    return @intFromEnum(Errno.success);
}

/// `args_get(argv_ptrs, argv_buf) -> errno` — d-2 stub no-op
/// (paired with args_sizes_get returning 0).
pub fn args_get(rt: *JitRuntime, argv_ptrs: i32, argv_buf: i32) callconv(.c) i32 {
    if (rt.wasi_host) |hp| {
        const host: *wasi_host_mod.Host = @ptrCast(@alignCast(hp));
        const mem = rt.vm_base[0..@intCast(rt.mem_limit)];
        return @intCast(@intFromEnum(wasi_proc.argsGet(host, mem, @bitCast(argv_ptrs), @bitCast(argv_buf))));
    }
    // Compute-only fallback: no argv → success no-op.
    return @intFromEnum(Errno.success);
}

/// `environ_sizes_get(envc_ptr, envv_buf_size_ptr) -> errno` —
/// d-2 stub returns 0/0 (no environ).
pub fn environ_sizes_get(rt: *JitRuntime, envc_ptr: i32, envv_buf_size_ptr: i32) callconv(.c) i32 {
    if (rt.wasi_host) |hp| {
        const host: *wasi_host_mod.Host = @ptrCast(@alignCast(hp));
        const mem = rt.vm_base[0..@intCast(rt.mem_limit)];
        return @intCast(@intFromEnum(wasi_proc.environSizesGet(host, mem, @bitCast(envc_ptr), @bitCast(envv_buf_size_ptr))));
    }
    if (envc_ptr < 0 or envv_buf_size_ptr < 0) return @intFromEnum(Errno.inval);
    const c_off: u64 = @intCast(envc_ptr);
    const v_off: u64 = @intCast(envv_buf_size_ptr);
    if (c_off + 4 > rt.mem_limit or v_off + 4 > rt.mem_limit) {
        return @intFromEnum(Errno.fault);
    }
    std.mem.writeInt(u32, rt.vm_base[@intCast(c_off)..][0..4], 0, .little);
    std.mem.writeInt(u32, rt.vm_base[@intCast(v_off)..][0..4], 0, .little);
    return @intFromEnum(Errno.success);
}

/// `environ_get(envv_ptrs, envv_buf) -> errno` — d-2 no-op.
pub fn environ_get(rt: *JitRuntime, envv_ptrs: i32, envv_buf: i32) callconv(.c) i32 {
    if (rt.wasi_host) |hp| {
        const host: *wasi_host_mod.Host = @ptrCast(@alignCast(hp));
        const mem = rt.vm_base[0..@intCast(rt.mem_limit)];
        return @intCast(@intFromEnum(wasi_proc.environGet(host, mem, @bitCast(envv_ptrs), @bitCast(envv_buf))));
    }
    // Compute-only fallback: no environ → success no-op.
    return @intFromEnum(Errno.success);
}

/// `wasi_snapshot_preview1.proc_exit(rval) -> noreturn` — Wasm
/// program-termination request. The spec semantics are
/// "noreturn from the program" but a direct `std.process.exit`
/// in a JIT-host context would terminate the test runner too,
/// so we surface it as a trap instead. Sets `trap_flag = 1` and
/// returns; the JIT body's subsequent ops execute (control did
/// not actually exit), but the entry shim's post-return check
/// (`if (rt.trap_flag != 0) return Error.Trap`) routes the
/// caller to the Trap path. Wasm programs typically call
/// proc_exit as the last op, so post-trap-flag work is
/// unreachable in practice.
///
/// d-3 MVP: discards the exit code (no JitRuntime tail-extension
/// for `proc_exit_code` yet — that lands when run_runner_jit
/// needs to surface program exit codes for differential
/// comparison with wasmtime).
pub fn proc_exit(rt: *JitRuntime, rval: i32) callconv(.c) void {
    dbg.print("wasi.jit", "proc_exit rval={d}", .{rval});
    // D-244: record the requested exit code on the host (mirroring the interp
    // `procExit`) so `runWasmJit` can surface it; then raise trap_flag to
    // unwind the JIT body to its epilogue (the JIT's proc_exit mechanism).
    if (rt.wasi_host) |hp| {
        const host: *wasi_host_mod.Host = @ptrCast(@alignCast(hp));
        _ = wasi_proc.procExit(host, @bitCast(rval));
    }
    // #331: mark the unwind host-originated so the C surface does not report a
    // clean exit as a guest `unreachable`. 18 is the JIT stub-code space, which
    // is NOT the public `ZWASM_TRAP_*` space — `trap_surface.jitTrapCode` is the
    // only place the two are related.
    rt.trap_kind = 18;
    rt.trap_flag = 1;
}

// ============================================================
// D-244: host-only thunks for the remaining preview1 surface.
//
// Unlike the d-2/d-3 thunks above (fd_write / clock_time_get /
// random_get / args_* / environ_*), these syscalls have NO
// meaningful compute-only fallback — they inherently consult the
// host fd-table, filesystem, or io context. With no `wasi_host`
// attached they return `nosys`. Each delegates to the SAME
// ABI-agnostic handler the interp uses; the callconv(.c) params
// mirror the Wasm declaration order of the corresponding
// `thunk*` in `src/api/wasi.zig` (the interp pops args in the
// reverse order it declares them).
// ============================================================

/// Resolve `rt.wasi_host` to the typed Host pointer; `null` if no host.
inline fn hostOf(rt: *JitRuntime) ?*wasi_host_mod.Host {
    const hp = rt.wasi_host orelse return null;
    return @ptrCast(@alignCast(hp));
}

inline fn memOf(rt: *JitRuntime) []u8 {
    return rt.vm_base[0..@intCast(rt.mem_limit)];
}

// --- clock / poll ---

pub fn clock_res_get(rt: *JitRuntime, clock_id: i32, resolution_ptr: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_clocks.clockResGet(host, memOf(rt), @bitCast(clock_id), @bitCast(resolution_ptr))));
}

pub fn poll_oneoff(rt: *JitRuntime, in_ptr: i32, out_ptr: i32, nsubscriptions: i32, nevents_ptr: i32) callconv(.c) i32 {
    dbg.print("mem.cksum", "jit poll_oneoff {x}", .{dbg.fnv1a(memOf(rt))});
    dbg.print("wasi.jit", "poll_oneoff nsubs={d}", .{nsubscriptions});
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_clocks.pollOneoff(host, memOf(rt), @bitCast(in_ptr), @bitCast(out_ptr), @bitCast(nsubscriptions), @bitCast(nevents_ptr))));
}

// --- proc ---

/// `sched_yield()` — no host / mem / args; always success.
pub fn sched_yield(rt: *JitRuntime) callconv(.c) i32 {
    _ = rt;
    dbg.print("wasi.jit", "sched_yield", .{});
    return @intCast(@intFromEnum(wasi_proc.schedYield()));
}

/// `proc_raise(sig)` — takes only `sig` (no host deref); reports notsup.
pub fn proc_raise(rt: *JitRuntime, sig: i32) callconv(.c) i32 {
    _ = rt;
    return @intCast(@intFromEnum(wasi_proc.procRaise(@bitCast(sig))));
}

// --- fd ---

pub fn fd_close(rt: *JitRuntime, fd: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdClose(host, @bitCast(fd))));
}

pub fn fd_seek(rt: *JitRuntime, fd: i32, offset: i64, whence: i32, new_pos_ptr: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdSeek(host, memOf(rt), @bitCast(fd), offset, @intCast(@as(u32, @bitCast(whence)) & 0xFF), @bitCast(new_pos_ptr))));
}

pub fn fd_tell(rt: *JitRuntime, fd: i32, pos_ptr: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdTell(host, memOf(rt), @bitCast(fd), @bitCast(pos_ptr))));
}

pub fn fd_fdstat_get(rt: *JitRuntime, fd: i32, fdstat_ptr: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdFdstatGet(host, memOf(rt), @bitCast(fd), @bitCast(fdstat_ptr))));
}

pub fn fd_fdstat_set_flags(rt: *JitRuntime, fd: i32, flags: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdFdstatSetFlags(host, @bitCast(fd), @intCast(@as(u32, @bitCast(flags)) & 0xFFFF))));
}

pub fn fd_fdstat_set_rights(rt: *JitRuntime, fd: i32, rights_base: i64, rights_inheriting: i64) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdFdstatSetRights(host, @bitCast(fd), @bitCast(rights_base), @bitCast(rights_inheriting))));
}

pub fn fd_sync(rt: *JitRuntime, fd: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdSync(host, @bitCast(fd))));
}

pub fn fd_datasync(rt: *JitRuntime, fd: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdDatasync(host, @bitCast(fd))));
}

pub fn fd_advise(rt: *JitRuntime, fd: i32, offset: i64, len: i64, advice: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdAdvise(host, @bitCast(fd), @bitCast(offset), @bitCast(len), @intCast(@as(u32, @bitCast(advice)) & 0xFF))));
}

pub fn fd_allocate(rt: *JitRuntime, fd: i32, offset: i64, len: i64) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdAllocate(host, @bitCast(fd), @bitCast(offset), @bitCast(len))));
}

pub fn fd_pread(rt: *JitRuntime, fd: i32, iovec_ptr: i32, iovec_count: i32, offset: i64, nread_ptr: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdPread(host, memOf(rt), @bitCast(fd), @bitCast(iovec_ptr), @bitCast(iovec_count), @bitCast(offset), @bitCast(nread_ptr))));
}

pub fn fd_pwrite(rt: *JitRuntime, fd: i32, ciovec_ptr: i32, ciovec_count: i32, offset: i64, nwritten_ptr: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdPwrite(host, memOf(rt), @bitCast(fd), @bitCast(ciovec_ptr), @bitCast(ciovec_count), @bitCast(offset), @bitCast(nwritten_ptr))));
}

pub fn fd_renumber(rt: *JitRuntime, from: i32, to: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdRenumber(host, @bitCast(from), @bitCast(to))));
}

pub fn fd_readdir(rt: *JitRuntime, fd: i32, buf_ptr: i32, buf_len: i32, cookie: i64, bufused_ptr: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdReaddir(host, memOf(rt), @bitCast(fd), @bitCast(buf_ptr), @bitCast(buf_len), @bitCast(cookie), @bitCast(bufused_ptr))));
}

pub fn fd_filestat_get(rt: *JitRuntime, fd: i32, filestat_ptr: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdFilestatGet(host, memOf(rt), @bitCast(fd), @bitCast(filestat_ptr))));
}

pub fn fd_filestat_set_size(rt: *JitRuntime, fd: i32, size: i64) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdFilestatSetSize(host, @bitCast(fd), @bitCast(size))));
}

pub fn fd_filestat_set_times(rt: *JitRuntime, fd: i32, atim: i64, mtim: i64, fst_flags: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdFilestatSetTimes(host, @bitCast(fd), @bitCast(atim), @bitCast(mtim), @intCast(@as(u32, @bitCast(fst_flags)) & 0xFFFF))));
}

pub fn fd_prestat_get(rt: *JitRuntime, fd: i32, prestat_ptr: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdPrestatGet(host, memOf(rt), @bitCast(fd), @bitCast(prestat_ptr))));
}

pub fn fd_prestat_dir_name(rt: *JitRuntime, fd: i32, path_ptr: i32, path_len: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.fdPrestatDirName(host, memOf(rt), @bitCast(fd), @bitCast(path_ptr), @bitCast(path_len))));
}

// --- path ---

pub fn path_open(rt: *JitRuntime, dirfd: i32, dirflags: i32, path_ptr: i32, path_len: i32, oflags: i32, fs_rights_base: i64, fs_rights_inheriting: i64, fdflags: i32, opened_fd_ptr: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.pathOpen(host, memOf(rt), @bitCast(dirfd), @bitCast(dirflags), @bitCast(path_ptr), @bitCast(path_len), @intCast(@as(u32, @bitCast(oflags)) & 0xFFFF), @bitCast(fs_rights_base), @bitCast(fs_rights_inheriting), @intCast(@as(u32, @bitCast(fdflags)) & 0xFFFF), @bitCast(opened_fd_ptr))));
}

pub fn path_unlink_file(rt: *JitRuntime, dirfd: i32, path_ptr: i32, path_len: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.pathUnlinkFile(host, memOf(rt), @bitCast(dirfd), @bitCast(path_ptr), @bitCast(path_len))));
}

pub fn path_create_directory(rt: *JitRuntime, dirfd: i32, path_ptr: i32, path_len: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_path.pathCreateDirectory(host, memOf(rt), @bitCast(dirfd), @bitCast(path_ptr), @bitCast(path_len))));
}

pub fn path_remove_directory(rt: *JitRuntime, dirfd: i32, path_ptr: i32, path_len: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_path.pathRemoveDirectory(host, memOf(rt), @bitCast(dirfd), @bitCast(path_ptr), @bitCast(path_len))));
}

pub fn path_filestat_get(rt: *JitRuntime, dirfd: i32, lookupflags: i32, path_ptr: i32, path_len: i32, filestat_ptr: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_path.pathFilestatGet(host, memOf(rt), @bitCast(dirfd), @bitCast(lookupflags), @bitCast(path_ptr), @bitCast(path_len), @bitCast(filestat_ptr))));
}

pub fn path_filestat_set_times(rt: *JitRuntime, dirfd: i32, lookupflags: i32, path_ptr: i32, path_len: i32, atim: i64, mtim: i64, fst_flags: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_path.pathFilestatSetTimes(host, memOf(rt), @bitCast(dirfd), @bitCast(lookupflags), @bitCast(path_ptr), @bitCast(path_len), @bitCast(atim), @bitCast(mtim), @intCast(@as(u32, @bitCast(fst_flags)) & 0xFFFF))));
}

pub fn path_symlink(rt: *JitRuntime, target_ptr: i32, target_len: i32, dirfd: i32, path_ptr: i32, path_len: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_path.pathSymlink(host, memOf(rt), @bitCast(target_ptr), @bitCast(target_len), @bitCast(dirfd), @bitCast(path_ptr), @bitCast(path_len))));
}

pub fn path_readlink(rt: *JitRuntime, dirfd: i32, path_ptr: i32, path_len: i32, buf_ptr: i32, buf_len: i32, bufused_ptr: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_path.pathReadlink(host, memOf(rt), @bitCast(dirfd), @bitCast(path_ptr), @bitCast(path_len), @bitCast(buf_ptr), @bitCast(buf_len), @bitCast(bufused_ptr))));
}

pub fn path_rename(rt: *JitRuntime, old_dirfd: i32, old_ptr: i32, old_len: i32, new_dirfd: i32, new_ptr: i32, new_len: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_path.pathRename(host, memOf(rt), @bitCast(old_dirfd), @bitCast(old_ptr), @bitCast(old_len), @bitCast(new_dirfd), @bitCast(new_ptr), @bitCast(new_len))));
}

pub fn path_link(rt: *JitRuntime, old_dirfd: i32, old_flags: i32, old_ptr: i32, old_len: i32, new_dirfd: i32, new_ptr: i32, new_len: i32) callconv(.c) i32 {
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_path.pathLink(host, memOf(rt), @bitCast(old_dirfd), @bitCast(old_flags), @bitCast(old_ptr), @bitCast(old_len), @bitCast(new_dirfd), @bitCast(new_ptr), @bitCast(new_len))));
}

// --- sock (each handler takes only fd; the other ABI args are unused) ---

pub fn sock_accept(rt: *JitRuntime, fd: i32, fdflags: i32, new_fd_ptr: i32) callconv(.c) i32 {
    _ = fdflags;
    _ = new_fd_ptr;
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.sockAccept(host, @bitCast(fd))));
}

pub fn sock_recv(rt: *JitRuntime, fd: i32, ri_data_ptr: i32, ri_data_len: i32, ri_flags: i32, ro_datalen_ptr: i32, ro_flags_ptr: i32) callconv(.c) i32 {
    _ = ri_data_ptr;
    _ = ri_data_len;
    _ = ri_flags;
    _ = ro_datalen_ptr;
    _ = ro_flags_ptr;
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.sockRecv(host, @bitCast(fd))));
}

pub fn sock_send(rt: *JitRuntime, fd: i32, si_data_ptr: i32, si_data_len: i32, si_flags: i32, so_datalen_ptr: i32) callconv(.c) i32 {
    _ = si_data_ptr;
    _ = si_data_len;
    _ = si_flags;
    _ = so_datalen_ptr;
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.sockSend(host, @bitCast(fd))));
}

pub fn sock_shutdown(rt: *JitRuntime, fd: i32, how: i32) callconv(.c) i32 {
    _ = how;
    const host = hostOf(rt) orelse return @intFromEnum(Errno.nosys);
    return @intCast(@intFromEnum(wasi_fd.sockShutdown(host, @bitCast(fd))));
}

/// Match an import (`module`, `name`) tuple against the known
/// WASI snapshot-preview1 manifest and return a function pointer
/// suitable for planting into `JitRuntime.host_dispatch_base[i]`.
/// Returns `null` for non-WASI imports — the caller leaves the
/// slot pointing at the default trap trampoline.
pub fn lookup(module_name: []const u8, field_name: []const u8) ?usize {
    if (!std.mem.eql(u8, module_name, "wasi_snapshot_preview1") and
        !std.mem.eql(u8, module_name, "wasi_unstable"))
    {
        return null;
    }
    const Pair = struct { name: []const u8, ptr: usize };
    const table = [_]Pair{
        .{ .name = "fd_write", .ptr = @intFromPtr(&fd_write) },
        .{ .name = "fd_read", .ptr = @intFromPtr(&fd_read) },
        .{ .name = "clock_time_get", .ptr = @intFromPtr(&clock_time_get) },
        .{ .name = "random_get", .ptr = @intFromPtr(&random_get) },
        .{ .name = "args_sizes_get", .ptr = @intFromPtr(&args_sizes_get) },
        .{ .name = "args_get", .ptr = @intFromPtr(&args_get) },
        .{ .name = "environ_sizes_get", .ptr = @intFromPtr(&environ_sizes_get) },
        .{ .name = "environ_get", .ptr = @intFromPtr(&environ_get) },
        .{ .name = "proc_exit", .ptr = @intFromPtr(&proc_exit) },
        // D-244: remaining preview1 surface (host-only thunks).
        .{ .name = "clock_res_get", .ptr = @intFromPtr(&clock_res_get) },
        .{ .name = "poll_oneoff", .ptr = @intFromPtr(&poll_oneoff) },
        .{ .name = "sched_yield", .ptr = @intFromPtr(&sched_yield) },
        .{ .name = "proc_raise", .ptr = @intFromPtr(&proc_raise) },
        .{ .name = "fd_close", .ptr = @intFromPtr(&fd_close) },
        .{ .name = "fd_seek", .ptr = @intFromPtr(&fd_seek) },
        .{ .name = "fd_tell", .ptr = @intFromPtr(&fd_tell) },
        .{ .name = "fd_fdstat_get", .ptr = @intFromPtr(&fd_fdstat_get) },
        .{ .name = "fd_fdstat_set_flags", .ptr = @intFromPtr(&fd_fdstat_set_flags) },
        .{ .name = "fd_fdstat_set_rights", .ptr = @intFromPtr(&fd_fdstat_set_rights) },
        .{ .name = "fd_sync", .ptr = @intFromPtr(&fd_sync) },
        .{ .name = "fd_datasync", .ptr = @intFromPtr(&fd_datasync) },
        .{ .name = "fd_advise", .ptr = @intFromPtr(&fd_advise) },
        .{ .name = "fd_allocate", .ptr = @intFromPtr(&fd_allocate) },
        .{ .name = "fd_pread", .ptr = @intFromPtr(&fd_pread) },
        .{ .name = "fd_pwrite", .ptr = @intFromPtr(&fd_pwrite) },
        .{ .name = "fd_renumber", .ptr = @intFromPtr(&fd_renumber) },
        .{ .name = "fd_readdir", .ptr = @intFromPtr(&fd_readdir) },
        .{ .name = "fd_filestat_get", .ptr = @intFromPtr(&fd_filestat_get) },
        .{ .name = "fd_filestat_set_size", .ptr = @intFromPtr(&fd_filestat_set_size) },
        .{ .name = "fd_filestat_set_times", .ptr = @intFromPtr(&fd_filestat_set_times) },
        .{ .name = "fd_prestat_get", .ptr = @intFromPtr(&fd_prestat_get) },
        .{ .name = "fd_prestat_dir_name", .ptr = @intFromPtr(&fd_prestat_dir_name) },
        .{ .name = "path_open", .ptr = @intFromPtr(&path_open) },
        .{ .name = "path_unlink_file", .ptr = @intFromPtr(&path_unlink_file) },
        .{ .name = "path_create_directory", .ptr = @intFromPtr(&path_create_directory) },
        .{ .name = "path_remove_directory", .ptr = @intFromPtr(&path_remove_directory) },
        .{ .name = "path_filestat_get", .ptr = @intFromPtr(&path_filestat_get) },
        .{ .name = "path_filestat_set_times", .ptr = @intFromPtr(&path_filestat_set_times) },
        .{ .name = "path_symlink", .ptr = @intFromPtr(&path_symlink) },
        .{ .name = "path_readlink", .ptr = @intFromPtr(&path_readlink) },
        .{ .name = "path_rename", .ptr = @intFromPtr(&path_rename) },
        .{ .name = "path_link", .ptr = @intFromPtr(&path_link) },
        .{ .name = "sock_accept", .ptr = @intFromPtr(&sock_accept) },
        .{ .name = "sock_recv", .ptr = @intFromPtr(&sock_recv) },
        .{ .name = "sock_send", .ptr = @intFromPtr(&sock_send) },
        .{ .name = "sock_shutdown", .ptr = @intFromPtr(&sock_shutdown) },
    };
    for (table) |p| {
        if (std.mem.eql(u8, p.name, field_name)) return p.ptr;
    }
    return null;
}

/// Walk imports in wasm-space order; for each function import,
/// fill `dispatch[i]` with the corresponding WASI handler ptr or
/// leave it untouched (the caller pre-fills with the default trap
/// trampoline). i increments only on `kind == .func` per the
/// wasm function-index space's semantics.
pub fn populateDispatch(dispatch: []usize, imports: []const sections.Import) void {
    var i: u32 = 0;
    for (imports) |imp| {
        if (imp.kind != .func) continue;
        if (i >= dispatch.len) return;
        if (lookup(imp.module, imp.name)) |ptr| dispatch[i] = ptr;
        i += 1;
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "lookup: fd_write resolves" {
    try testing.expect(lookup("wasi_snapshot_preview1", "fd_write") != null);
    try testing.expect(lookup("wasi_unstable", "fd_write") != null);
}

test "lookup: proc_exit resolves" {
    try testing.expect(lookup("wasi_snapshot_preview1", "proc_exit") != null);
}

test "lookup: unknown module returns null" {
    try testing.expectEqual(@as(?usize, null), lookup("env", "fd_write"));
}

test "lookup: unknown field returns null" {
    try testing.expectEqual(@as(?usize, null), lookup("wasi_snapshot_preview1", "fd_write_v2"));
}

test "fd_write: bad fd returns EBADF" {
    var memory: [16]u8 = undefined;
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const errno = fd_write(&rt, 99, 0, 0, 0);
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.badf)), errno);
    _ = builtin.os.tag; // touch builtin to silence unused-import warning
}

test "clock_time_get: host-attached → REAL nonzero time; no host → 0 stub (D-244)" {
    var memory: [16]u8 = @splat(0);
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
        .wasi_host = &h,
    };
    // realtime clock → the shared interp handler writes real nanoseconds.
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), clock_time_get(&rt, 0, 0, 0));
    try testing.expect(std.mem.readInt(u64, memory[0..8], .little) > 0);

    // Compute-only fallback (no host): deterministic 0.
    rt.wasi_host = null;
    @memset(&memory, 0xFF);
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), clock_time_get(&rt, 0, 0, 0));
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, memory[0..8], .little));
}

test "random_get: host-attached → real entropy; no host → zero-fill (D-244)" {
    var memory: [32]u8 = @splat(0);
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
        .wasi_host = &h,
    };
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), random_get(&rt, 0, 32));
    var any_nonzero = false;
    for (memory) |b| {
        if (b != 0) any_nonzero = true;
    }
    try testing.expect(any_nonzero);

    // No host → deterministic zero-fill.
    rt.wasi_host = null;
    @memset(&memory, 0xAB);
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), random_get(&rt, 0, 32));
    for (memory) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "fd_write: host-attached routes to the shared handler (real stdout capture) (D-244)" {
    var memory: [64]u8 = @splat(0);
    // ciovec at mem[16] = {buf=24, len=5}; payload "HELLO" at mem[24].
    std.mem.writeInt(u32, memory[16..20], 24, .little);
    std.mem.writeInt(u32, memory[20..24], 5, .little);
    @memcpy(memory[24..29], "HELLO");
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    h.stdout_buffer = &capture;
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
        .wasi_host = &h,
    };
    // fd=1 stdout, 1 ciovec at 16, nwritten at 40.
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), fd_write(&rt, 1, 16, 1, 40));
    try testing.expectEqualStrings("HELLO", capture.items);
    try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, memory[40..44], .little));
}

test "fd_read: host-attached reads from real stdin; no host → EOF stub (D-244)" {
    var memory: [64]u8 = @splat(0);
    // iovec at mem[16] = {buf=24, len=8}.
    std.mem.writeInt(u32, memory[16..20], 24, .little);
    std.mem.writeInt(u32, memory[20..24], 8, .little);
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    h.stdin_bytes = "ab";
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
        .wasi_host = &h,
    };
    // fd=0 stdin, 1 iovec at 16, nread at 40.
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), fd_read(&rt, 0, 16, 1, 40));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, memory[40..44], .little));
    try testing.expectEqualStrings("ab", memory[24..26]);
}

test "lookup: fd_read resolves" {
    try testing.expect(lookup("wasi_snapshot_preview1", "fd_read") != null);
    try testing.expect(lookup("wasi_unstable", "fd_read") != null);
}

test "fd_read: bad fd returns EBADF" {
    var memory: [16]u8 = undefined;
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const errno = fd_read(&rt, 99, 0, 0, 0);
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.badf)), errno);
}

test "fd_read: fd 0 stdin EOF writes 0 to nread and returns success" {
    var memory: [32]u8 = .{0xAA} ** 32;
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    // iovec at offset 0: { buf=16, buf_len=8 }; nread at offset 24.
    std.mem.writeInt(u32, memory[0..4], 16, .little);
    std.mem.writeInt(u32, memory[4..8], 8, .little);
    const errno = fd_read(&rt, 0, 0, 1, 24);
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), errno);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, memory[24..28], .little));
}

test "fd_read: out-of-bounds iovs_ptr returns EFAULT" {
    var memory: [16]u8 = undefined;
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    // iovs_ptr=12 + 1 iovec (8 bytes) overflows 16-byte memory.
    const errno = fd_read(&rt, 0, 12, 1, 0);
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.fault)), errno);
}

test "args_sizes_get: writes 0 + 0 to memory" {
    var memory: [16]u8 = .{ 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA };
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const errno = args_sizes_get(&rt, 0, 4);
    try testing.expectEqual(@as(i32, 0), errno);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, memory[0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, memory[4..8], .little));
}

// ============================================================
// D-244: tests for the extended preview1 surface.
//
// Each calls the thunk DIRECTLY with a constructed JitRuntime
// (no JIT exec) so they run on every platform. Errno integers
// are the preview1 values: notsup=58, notsock=57, spipe=70,
// badf=8, success=0.
// ============================================================

/// Build a host-attached JitRuntime over `memory` for the D-244 thunk tests.
fn jitRtWithHost(memory: []u8, host: *wasi_host_mod.Host) JitRuntime {
    return .{
        .vm_base = memory.ptr,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
        .wasi_host = host,
    };
}

test "D-244 clock_res_get: host → success, resolution > 0" {
    var memory: [16]u8 = @splat(0);
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var rt = jitRtWithHost(&memory, &h);
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), clock_res_get(&rt, 0, 0));
    try testing.expect(std.mem.readInt(u64, memory[0..8], .little) > 0);
}

test "D-244 clock_res_get: no host → nosys" {
    var memory: [16]u8 = @splat(0);
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.nosys)), clock_res_get(&rt, 0, 0));
}

test "D-244 sched_yield: success (no host needed)" {
    var memory: [4]u8 = @splat(0);
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), sched_yield(&rt));
}

test "D-244 proc_raise: notsup (deliberate design boundary)" {
    var memory: [4]u8 = @splat(0);
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    try testing.expectEqual(@as(i32, 58), proc_raise(&rt, 6));
}

test "D-244 fd_close: stdio fd → success" {
    var memory: [16]u8 = @splat(0);
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var rt = jitRtWithHost(&memory, &h);
    // fd 1 (stdout) is a stdio slot → close is a success no-op.
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.success)), fd_close(&rt, 1));
}

test "D-244 fd_seek: stdio → spipe" {
    var memory: [16]u8 = @splat(0);
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var rt = jitRtWithHost(&memory, &h);
    // fd 0 (stdin) is not seekable → spipe (70).
    try testing.expectEqual(@as(i32, 70), fd_seek(&rt, 0, 0, 0, 0));
}

test "D-244 fd_prestat_get: bad fd → badf" {
    var memory: [32]u8 = @splat(0);
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var rt = jitRtWithHost(&memory, &h);
    // fd 1 (stdout, not a preopen dir) → badf (8).
    try testing.expectEqual(@as(i32, @intFromEnum(Errno.badf)), fd_prestat_get(&rt, 1, 0));
}

test "D-244 sock_recv: stdio fd → notsock" {
    var memory: [16]u8 = @splat(0);
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    var rt = jitRtWithHost(&memory, &h);
    // fd 0 is a valid (non-socket) slot → notsock (57).
    try testing.expectEqual(@as(i32, 57), sock_recv(&rt, 0, 0, 0, 0, 0, 0));
}

test "D-244 lookup: extended preview1 surface resolves (46 entries total)" {
    const names = [_][]const u8{
        "clock_res_get",        "poll_oneoff",             "sched_yield",
        "proc_raise",           "fd_close",                "fd_seek",
        "fd_tell",              "fd_fdstat_get",           "fd_fdstat_set_flags",
        "fd_fdstat_set_rights", "fd_sync",                 "fd_datasync",
        "fd_advise",            "fd_allocate",             "fd_pread",
        "fd_pwrite",            "fd_renumber",             "fd_readdir",
        "fd_filestat_get",      "fd_filestat_set_size",    "fd_filestat_set_times",
        "fd_prestat_get",       "fd_prestat_dir_name",     "path_open",
        "path_unlink_file",     "path_create_directory",   "path_remove_directory",
        "path_filestat_get",    "path_filestat_set_times", "path_symlink",
        "path_readlink",        "path_rename",             "path_link",
        "sock_accept",          "sock_recv",               "sock_send",
        "sock_shutdown",
    };
    for (names) |n| {
        try testing.expect(lookup("wasi_snapshot_preview1", n) != null);
        try testing.expect(lookup("wasi_unstable", n) != null);
    }
}
