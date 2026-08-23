// FILE-SIZE-EXEMPT: the WASI-P2 trampoline surface + classifier + component orchestration (ADR-0207 (b), M4-measured 2026-08-12); the P2 fs/sockets sub-split had no positive ADR-0099 condition (spec-closed clusters but shallow <300-LOC net gains), so honest-exempt over metric-split.
//! WASI **Preview 2** trampolines + classifier + component orchestration —
//! ADR-0207 (b). The substrate (`WasiP2Ctx`, engines, straddle helpers)
//! lives in `component_wasi_ctx.zig`; the 0.3 layer in
//! `component_wasi_p3_host.zig`. This file is also the compat surface:
//! external importers keep resolving every historical pub symbol here.

const std = @import("std");

const decode = @import("../feature/component/decode.zig");
const ctypes = @import("../feature/component/types.zig");
const canon = @import("../feature/component/canon.zig");
const wit_type = @import("../feature/component/wit_type.zig");
const cvalidate = @import("../feature/component/validate.zig");
const wasi_host = @import("../wasi/host.zig");
const wasi_fd = @import("../wasi/fd.zig");
const wasi_path = @import("../wasi/path.zig");
const wasi_proc = @import("../wasi/proc.zig");
const wasi_clocks = @import("../wasi/clocks.zig");
const wasi_p1 = @import("../wasi/preview1.zig");
const p2sock = @import("../wasi/p2_sockets.zig");
const p3http = @import("../wasi/p3_http.zig");
const adapter = @import("../wasi/adapter.zig");
const resource_table = @import("../feature/component/resource_table.zig");
const async_mod = @import("../feature/component/async.zig");
const Caller = @import("../zwasm/caller.zig").Caller;

const Allocator = std.mem.Allocator;
const Engine = @import("../zwasm/engine.zig").Engine;
const Module = @import("../zwasm/module.zig").Module;
const Instance = @import("../zwasm/instance.zig").Instance;
const Linker = @import("../zwasm/linker.zig").Linker;
const Value = @import("../zwasm.zig").Value;
const zir_mod = @import("../ir/zir.zig");
const build_options = @import("build_options");

const ctx_mod = @import("component_wasi_ctx.zig");
const p3h = @import("component_wasi_p3_host.zig");

// Substrate re-exports (compat surface, ADR-0207 I1) + local aliases so the
// moved trampoline bodies read unchanged.
pub const WasiP2Ctx = ctx_mod.WasiP2Ctx;
pub const WasiP2Error = ctx_mod.WasiP2Error;
pub const PendingRead = ctx_mod.PendingRead;
pub const PendingWrite = ctx_mod.PendingWrite;
pub const ParkedSockRead = ctx_mod.ParkedSockRead;
pub const TcpTxRole = ctx_mod.TcpTxRole;
pub const ParkedUdpReceive = ctx_mod.ParkedUdpReceive;
pub const HostBodyBytes = ctx_mod.HostBodyBytes;
pub const PendingClientSend = ctx_mod.PendingClientSend;
pub const AsyncBuiltinCtx = ctx_mod.AsyncBuiltinCtx;
pub const ResourceBuiltinCtx = ctx_mod.ResourceBuiltinCtx;
pub const GuestDtor = ctx_mod.GuestDtor;
pub const ContextBuiltinCtx = ctx_mod.ContextBuiltinCtx;
const Memory = ctx_mod.Memory;
const FilestatResult = ctx_mod.FilestatResult;
const ctxMemory = ctx_mod.ctxMemory;
const ctxIo = ctx_mod.ctxIo;
const ctxTcpSocket = ctx_mod.ctxTcpSocket;
const ctxUdpSocket = ctx_mod.ctxUdpSocket;
const descriptorFilestat = ctx_mod.descriptorFilestat;
const pathFilestat = ctx_mod.pathFilestat;
const decodeIpSocketAddress = ctx_mod.decodeIpSocketAddress;
const writeIpSocketAddressResult = ctx_mod.writeIpSocketAddressResult;
const mapAsyncFault = ctx_mod.mapAsyncFault;
const p2StdoutWriteViaStream = ctx_mod.p2StdoutWriteViaStream;
const p2StderrWriteViaStream = ctx_mod.p2StderrWriteViaStream;
const p2StdinReadViaStream = ctx_mod.p2StdinReadViaStream;
const p2WaitUntilSync = ctx_mod.p2WaitUntilSync;
const p2WaitForSync = ctx_mod.p2WaitForSync;
const p2GuestResourceNew = ctx_mod.p2GuestResourceNew;
const p2GuestResourceRep = ctx_mod.p2GuestResourceRep;
const p2GuestResourceDrop = ctx_mod.p2GuestResourceDrop;
const p2TaskReturn = ctx_mod.p2TaskReturn;
const p2TaskReturnRaw = ctx_mod.p2TaskReturnRaw;
const p2WaitableSetNew = ctx_mod.p2WaitableSetNew;
const p2WaitableJoin = ctx_mod.p2WaitableJoin;
const p2WaitableSetPoll = ctx_mod.p2WaitableSetPoll;
const p2WaitableSetDrop = ctx_mod.p2WaitableSetDrop;
const p2TaskCancel = ctx_mod.p2TaskCancel;
const p2SubtaskCancel = ctx_mod.p2SubtaskCancel;
const p2SubtaskDrop = ctx_mod.p2SubtaskDrop;
const p2ThreadYield = ctx_mod.p2ThreadYield;
const p2ContextGet32 = ctx_mod.p2ContextGet32;
const p2ContextSet32 = ctx_mod.p2ContextSet32;
const p2ContextGet64 = ctx_mod.p2ContextGet64;
const p2ContextSet64 = ctx_mod.p2ContextSet64;
const p2StreamNew = ctx_mod.p2StreamNew;
const p2FutureNew = ctx_mod.p2FutureNew;
const p2FutureCopy = ctx_mod.p2FutureCopy;
const p2StreamFutureCopy = ctx_mod.p2StreamFutureCopy;
const p2StreamFutureCancel = ctx_mod.p2StreamFutureCancel;
const p2StreamFutureDrop = ctx_mod.p2StreamFutureDrop;

// P3-side pubs (consumed by component_wasi_p3.zig; re-export per ADR-0207 I1).
pub const http3DropTransferredEnd = p3h.http3DropTransferredEnd;
pub const pollPendingClientSends = p3h.pollPendingClientSends;
pub const http3RegisterCaptureSink = p3h.http3RegisterCaptureSink;

pub fn p2GetStdout(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.OUTPUT_STREAM_RT, 1);
}

/// `wasi:cli/stderr` `get-stderr` → mint an output-stream handle bound to fd 2.
/// The write/drop trampolines are shared (they resolve the fd from the handle).
fn p2GetStderr(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.OUTPUT_STREAM_RT, 2);
}

/// `wasi:cli/exit` `exit(status: result)` → P1 `proc_exit`. The bare `result`
/// status lowers to a single i32 discriminant (0=ok, 1=err); map it straight to
/// the exit code. `exit` is `noreturn`: after recording the code we return
/// `ProcExit` to unwind the guest invoke, and `runWasiP2Main` treats a set
/// `host.exit_code` as a clean termination (not a failure).
fn p2Exit(caller: *Caller, status: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    _ = wasi_proc.procExit(ctx.host, status);
    return WasiP2Error.ProcExit;
}

/// `wasi:cli/exit@0.3.0` `exit-with-code(status-code: u8)` — the arbitrary-code
/// sibling of `exit` (official 0.3.0 addition). The u8 lowers to an i32; pass
/// it through as the recorded exit code and unwind like `exit`.
fn p2ExitWithCode(caller: *Caller, code: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    _ = wasi_proc.procExit(ctx.host, code & 0xff);
    return WasiP2Error.ProcExit;
}

/// `wasi:clocks/monotonic-clock` `now()` → instant(u64). Returns the host
/// monotonic clock (P1 clock id 1) directly as the lowered `i64` — no guest
/// memory / return area. `now()` is infallible in WIT and the component-run
/// path always has `host.io`, so a clock-read failure is a host-setup bug.
fn p2MonotonicNow(caller: *Caller) WasiP2Error!i64 {
    const ctx = caller.data(WasiP2Ctx);
    const ns = wasi_clocks.clockTimeNs(ctx.host, 1) catch
        return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
    return @bitCast(ns);
}

/// `wasi:clocks/wall-clock` `now()` → datetime{seconds: u64, nanoseconds: u32}.
/// Splits the host realtime clock (P1 clock id 0) into seconds + sub-second ns
/// and writes the 12-byte record to the return area at `retptr` (seconds @ 0,
/// nanoseconds @ 8). Reuses clockTimeNs; no realloc (the guest supplies retptr).
fn p2WallNow(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const ns = wasi_clocks.clockTimeNs(ctx.host, 0) catch
        return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
    try mem.write(retptr, @as(u64, ns / std.time.ns_per_s));
    try mem.write(retptr + 8, @as(u32, @intCast(ns % std.time.ns_per_s)));
}

/// `wasi:clocks/system-clock` `now()` → instant{seconds: s64, nanoseconds: u32}
/// (official WASI 0.3.0 — the renamed 0.2 `wall-clock`, reading the same host
/// realtime clock; the record's seconds field became SIGNED). Writes the
/// 12-byte record to the return area at `retptr` (seconds @ 0, ns @ 8).
fn p2SystemNow(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const ns = wasi_clocks.clockTimeNsSigned(ctx.host, 0) catch
        return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
    const inst = instantFromNs(ns);
    try mem.write(retptr, inst.seconds);
    try mem.write(retptr + 8, inst.nanoseconds);
}

/// Split signed epoch-nanoseconds into the WIT `instant` encoding: FLOORED
/// seconds + a non-negative sub-second remainder (the spec's example — 1 ns
/// before the epoch — is `{-1 seconds, 999_999_999 nanoseconds}`). Seconds
/// beyond the i64 domain clamp (mirrors `clockTimeNs`'s u64 clamp).
fn instantFromNs(ns: i96) struct { seconds: i64, nanoseconds: u32 } {
    const secs = @divFloor(ns, std.time.ns_per_s);
    const min_s: i96 = std.math.minInt(i64);
    const max_s: i96 = std.math.maxInt(i64);
    return .{
        .seconds = @intCast(std.math.clamp(secs, min_s, max_s)),
        .nanoseconds = @intCast(@mod(ns, std.time.ns_per_s)),
    };
}

test "instantFromNs: floored split incl. the WIT pre-epoch example" {
    // The system-clock.wit example: 1 ns before the epoch.
    try std.testing.expectEqual(@as(i64, -1), instantFromNs(-1).seconds);
    try std.testing.expectEqual(@as(u32, 999_999_999), instantFromNs(-1).nanoseconds);
    // Positive path + exact-second boundaries.
    try std.testing.expectEqual(@as(i64, 1), instantFromNs(1_500_000_000).seconds);
    try std.testing.expectEqual(@as(u32, 500_000_000), instantFromNs(1_500_000_000).nanoseconds);
    try std.testing.expectEqual(@as(i64, -2), instantFromNs(-2_000_000_000).seconds);
    try std.testing.expectEqual(@as(u32, 0), instantFromNs(-2_000_000_000).nanoseconds);
}

/// `wasi:clocks/{system,monotonic}-clock` `get-resolution()` → duration(u64)
/// (official WASI 0.3.0): the host clock granularity in ns, returned directly
/// as the lowered `i64`. WIT declares it infallible, so a host that cannot
/// report a resolution surfaces a loud error (never a fabricated value).
fn clockGetResolution(caller: *Caller, clock_id: u32) WasiP2Error!i64 {
    const ctx = caller.data(WasiP2Ctx);
    const ns = wasi_clocks.clockResNs(ctx.host, clock_id) catch |err| switch (err) {
        error.Inval => unreachable, // clock id is hardcoded 0/1 at the call sites
        error.NoSys, error.NotSup, error.Io => return WasiP2Error.NoHostIo,
    };
    return @bitCast(ns);
}

fn p2SystemGetResolution(caller: *Caller) WasiP2Error!i64 {
    return clockGetResolution(caller, 0);
}

fn p2MonotonicGetResolution(caller: *Caller) WasiP2Error!i64 {
    return clockGetResolution(caller, 1);
}

/// `wasi:cli/stdin` `get-stdin` → mint an input-stream handle bound to fd 0.
fn p2GetStdin(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.INPUT_STREAM_RT, 0);
}

/// `wasi:io/streams` `[method]input-stream.read(self, len) -> result<list<u8>,
/// stream-error>` (self, len, retptr): read up to `len` bytes from the fd bound
/// to `self` (stdin) into a cabi_realloc'd buffer. Writes the `result` at
/// `retptr`: disc@0 (0=ok / 1=err), and on ok (data_ptr@4, len@8); on EOF the
/// stream is closed → err(stream-error::closed) (err disc@0=1, variant case@4=1).
fn p2InStreamRead(caller: *Caller, self_handle: u32, len: u64, retptr: u32) WasiP2Error!void {
    return inStreamReadImpl(caller, self_handle, len, retptr, false);
}

fn p2InStreamBlockingRead(caller: *Caller, self_handle: u32, len: u64, retptr: u32) WasiP2Error!void {
    return inStreamReadImpl(caller, self_handle, len, retptr, true);
}

fn inStreamReadImpl(caller: *Caller, self_handle: u32, len: u64, retptr: u32, blocking: bool) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const h = try ctx.resources.peek(self_handle);
    if (h.rt == WasiP2Ctx.SOCK_INPUT_STREAM_RT) return sockStreamRead(ctx, mem, h.rep, len, retptr, blocking);
    if (h.rt != WasiP2Ctx.INPUT_STREAM_RT) return resource_table.Error.TypeMismatch;
    const n: u32 = @intCast(@min(len, std.math.maxInt(u32)));
    const data_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n, 1);
    const got: u32 = if (n == 0) 0 else @intCast(wasi_fd.readStdinSlice(ctx.host, mem.sliceAt(data_ptr, n) catch return WasiP2Error.OutOfBounds));
    if (got == 0 and n != 0) {
        try mem.write(retptr, @as(u8, 1)); // err disc
        try mem.write(retptr + 4, @as(u8, 1)); // stream-error::closed (variant case 1)
    } else {
        try mem.write(retptr, @as(u8, 0)); // ok disc
        try mem.write(retptr + 4, data_ptr); // list data ptr
        try mem.write(retptr + 8, got); // list length
    }
}

/// Socket-backed `input-stream.read` / `blocking-read` (ADR-0180): the
/// non-blocking read returns the EMPTY list when poll(2) reports no data
/// (the spec's would-block signal); the blocking variant waits on readiness
/// first. A 0-byte recv after readiness = peer EOF -> stream-error::closed.
fn sockStreamRead(ctx: *WasiP2Ctx, mem: Memory, rep: u32, len: u64, retptr: u32, blocking: bool) WasiP2Error!void {
    const sock = try ctxTcpSocket(ctx, rep);
    const io = try ctxIo(ctx);
    const n: u32 = @intCast(@min(len, std.math.maxInt(u32)));
    const readable = sock.ready(p2sock.POLL_IN) catch false;
    if (!readable) {
        if (!blocking) { // would-block -> ok(empty list)
            try mem.write(retptr, @as(u8, 0));
            try mem.write(retptr + 4, @as(u32, 0));
            try mem.write(retptr + 8, @as(u32, 0));
            return;
        }
        var waited: u32 = 0;
        while (!(sock.ready(p2sock.POLL_IN) catch true) and waited < 30_000) : (waited += 2) {
            io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake) catch break;
        }
    }
    const data_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n, 1);
    const dest = mem.sliceAt(data_ptr, n) catch return WasiP2Error.OutOfBounds;
    const got = sock.recv(io, dest) catch {
        try mem.write(retptr, @as(u8, 1)); // stream-error::closed (typed arm)
        try mem.write(retptr + 4, @as(u8, 1));
        return;
    };
    if (got == 0 and n != 0) { // EOF
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, @as(u8, 1)); // closed
        return;
    }
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, data_ptr);
    try mem.write(retptr + 8, @as(u32, @intCast(got)));
}

/// `wasi:random/random` `get-random-bytes(len: u64) -> list<u8>`. Allocates
/// `len` bytes via the guest `cabi_realloc` (nested invoke), fills them with
/// secure random, and writes `(data_ptr, len)` to the return area at `retptr`.
/// Mirrors the D2 list-return pattern (p2GetDirectories).
fn p2RandomGetBytes(caller: *Caller, len: u64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const n: u32 = @intCast(@min(len, std.math.maxInt(u32)));
    const data_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n, 1);
    if (n != 0) {
        const dest = mem.sliceAt(data_ptr, n) catch return WasiP2Error.OutOfBounds;
        if (wasi_clocks.randomFill(ctx.host, dest) != .success)
            return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
    }
    try mem.write(retptr, data_ptr); // list data ptr
    try mem.write(retptr + 4, n); // list length
}

/// `wasi:io/streams` `[method]output-stream.blocking-write-and-flush`
/// (self, ptr, len, retptr): write the flat `list<u8>` at `(ptr, len)` to the
/// fd bound to `self`, then store the `result<_, stream-error>` ok-discriminant
/// (0) at `retptr`.
pub fn p2OutStreamWrite(caller: *Caller, self_handle: u32, ptr: u32, len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const bytes = mem.sliceAt(ptr, len) catch return WasiP2Error.OutOfBounds;
    const h = try ctx.resources.peek(self_handle);
    if (h.rt == WasiP2Ctx.SOCK_OUTPUT_STREAM_RT) {
        // Socket-backed stream (ADR-0180): send on the connected socket; any
        // send failure surfaces as stream-error::closed (case 1, payload-free
        // — the lossy-but-typed arm; last-operation-failed needs an error
        // resource, Phase-2 scope).
        const sock = try ctxTcpSocket(ctx, h.rep);
        _ = sock.send(try ctxIo(ctx), bytes) catch {
            try mem.write(retptr, @as(u8, 1));
            try mem.write(retptr + 4, @as(u8, 1)); // stream-error::closed
            return;
        };
        try mem.write(retptr, @as(u8, 0));
        return;
    }
    if (h.rt != WasiP2Ctx.OUTPUT_STREAM_RT) return resource_table.Error.TypeMismatch;
    const fd: wasi_p1.Fd = @intCast(h.rep);
    if (wasi_fd.writeSlice(ctx.host, fd, bytes) != .success) return WasiP2Error.WriteFailed;
    try mem.write(retptr, @as(u8, 0));
}

/// The live `TcpSocket` a SOCK_* handle rep (low 24 bits) points at.
pub fn p2OutStreamDrop(caller: *Caller, self_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    _ = try ctx.resources.drop(WasiP2Ctx.OUTPUT_STREAM_RT, self_handle);
}

/// `wasi:filesystem/types` `[method]descriptor.write` (self, buf_ptr, buf_len,
/// offset, retptr): positionally write the flat `list<u8>` at `(buf_ptr,
/// buf_len)` to the fd bound to the `descriptor` handle, then store the
/// `result<filesize, error-code>` (disc 0 = ok, u64 filesize at +8) at `retptr`.
pub fn p2DescriptorWrite(caller: *Caller, self_handle: u32, buf_ptr: u32, buf_len: u32, offset: u64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    const bytes = mem.sliceAt(buf_ptr, buf_len) catch return WasiP2Error.OutOfBounds;
    const errno = wasi_fd.pwriteSlice(ctx.host, fd, bytes, offset);
    if (errno != .success) {
        try writeP1Err(mem, retptr, 8, errno); // result align 8
        return;
    }
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 8, @as(u64, buf_len)); // filesize written
}

/// `wasi:filesystem/types` `[resource-drop]descriptor` (self): drop the handle
/// (closes the underlying fd via P1 `fd_close`).
pub fn p2DescriptorDrop(caller: *Caller, self_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    _ = wasi_fd.fdClose(ctx.host, fd);
    _ = try ctx.resources.drop(WasiP2Ctx.DESCRIPTOR_RT, self_handle);
}

/// Generic classified `canon resource.drop`: drop a handle of ANY host-modeled
/// P2 resource (output-stream / descriptor — both rep = a P1 fd) and close the
/// underlying fd (a noop for stdio per P1 `fd_close`). The language-level drop
/// already named the type; the table's stored type is authoritative, so the
/// host need not resolve which interface's resource was dropped.
fn p2ResourceDrop(caller: *Caller, self_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    // fd-backed resources (stdio/descriptor streams) close their fd; a pollable
    // carries no host fd and a directory-entry-stream borrows its descriptor's
    // fd (rep = `dir_streams` index), so those only release the handle slot.
    if (try ctx.resources.dropAny(self_handle)) |h| {
        switch (h.rt) {
            // Pollables / dir-entry-streams / networks / socket streams carry
            // no exclusively-owned host fd — only the handle slot is released.
            WasiP2Ctx.POLLABLE_RT, WasiP2Ctx.DIR_STREAM_RT, WasiP2Ctx.NETWORK_RT, WasiP2Ctx.SOCK_POLLABLE_RT, WasiP2Ctx.SOCK_INPUT_STREAM_RT, WasiP2Ctx.SOCK_OUTPUT_STREAM_RT => {},
            // The tcp-socket handle owns the OS socket.
            WasiP2Ctx.TCP_SOCKET_RT => {
                const sock = ctxTcpSocket(ctx, h.rep) catch return; // slot already gone
                if (sock.state != .closed) sock.deinit(try ctxIo(ctx));
            },
            // The udp-socket handle owns the OS socket (rep = udp_sockets
            // index, NOT a P1 fd — the else-branch fdClose would close an
            // unrelated host fd).
            WasiP2Ctx.UDP_SOCKET3_RT => {
                const sock = ctxUdpSocket(ctx, h.rep) catch return;
                if (sock.socket != null) sock.deinit(try ctxIo(ctx));
            },
            // The fields handle owns its (name, value) pair storage.
            WasiP2Ctx.HTTP_FIELDS_RT => {
                if (h.rep < ctx.http_fields.items.len)
                    ctx.http_fields.items[h.rep].deinit(ctx.alloc);
            },
            // Borrowed views / plain-value resources: handle slot only.
            WasiP2Ctx.HTTP_FIELDS_VIEW_RT, WasiP2Ctx.HTTP_REQOPTS_RT, WasiP2Ctx.HTTP_REQOPTS_VIEW_RT => {},
            // The response owns its headers fields storage + transferred
            // body ends (same writer-task unblock as the request).
            WasiP2Ctx.HTTP_RESPONSE_RT => {
                if (h.rep < ctx.http_responses.items.len) {
                    const resp = &ctx.http_responses.items[h.rep];
                    if (resp.headers_rep < ctx.http_fields.items.len)
                        ctx.http_fields.items[resp.headers_rep].deinit(ctx.alloc);
                    ctx.p3().drop_transferred_end(ctx, resp.trailers_future);
                    if (resp.contents_stream) |s| ctx.p3().drop_transferred_end(ctx, s);
                }
            },
            // The request owns its uri strings, its headers fields storage,
            // and the TRANSFERRED body ends — dropping the trailers-future
            // readable unblocks the guest's writer task (else its
            // wit_future closure waits forever → AsyncDeadlock).
            WasiP2Ctx.HTTP_REQUEST_RT => {
                if (h.rep < ctx.http_requests.items.len) {
                    const req = &ctx.http_requests.items[h.rep];
                    if (req.headers_rep < ctx.http_fields.items.len)
                        ctx.http_fields.items[req.headers_rep].deinit(ctx.alloc);
                    ctx.p3().drop_transferred_end(ctx, req.trailers_future);
                    if (req.contents_stream) |s| ctx.p3().drop_transferred_end(ctx, s);
                    req.deinit(ctx.alloc);
                }
            },
            else => _ = wasi_fd.fdClose(ctx.host, @intCast(h.rep)),
        }
    }
}

test "D-444 II: p2ResourceDrop(HTTP_REQUEST_RT) — releases transferred ends + owned storage" {
    const Runtime = @import("../runtime/runtime.zig").Runtime;
    const testing = std.testing;
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    p3h.installP3Hooks(&ctx); // the drop path below reaches P3 via the hooks
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var caller: Caller = .{ .rt = &rt, .host_data = &ctx };

    // A request carrying transferred body ends + owned headers/uri storage,
    // exactly the state a guest hands over before dropping the resource.
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    const strm = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null);
    try ctx.pending_reads.put(ctx.alloc, strm.readable, .{ .ptr = 0, .cap = 0 });
    var flds: p3http.HttpFields = .{};
    try flds.entries.append(ctx.alloc, .{
        .name = try ctx.alloc.dupe(u8, "x"),
        .value = try ctx.alloc.dupe(u8, "y"),
    });
    try ctx.http_fields.append(ctx.alloc, flds);
    try ctx.http_requests.append(ctx.alloc, .{
        .path_with_query = try ctx.alloc.dupe(u8, "/probe?q=1"),
        .headers_rep = 0,
        .contents_stream = strm.readable,
        .trailers_future = fut.readable,
    });
    const h = try ctx.resources.new(WasiP2Ctx.HTTP_REQUEST_RT, 0);

    try p2ResourceDrop(&caller, h);

    // The trailers-future / contents-stream ends are gone from every side
    // table (the writer-task unblock invariant) and the handle slot is freed.
    try testing.expect(ctx.host_result_futures.get(fut.readable) == null);
    try testing.expect(ctx.pending_reads.get(strm.readable) == null);
    try testing.expectError(async_mod.Error.InvalidHandle, ctx.streams.get(fut.readable));
    try testing.expectError(async_mod.Error.InvalidHandle, ctx.streams.get(strm.readable));
    try testing.expectError(resource_table.Error.InvalidHandle, ctx.resources.rep(WasiP2Ctx.HTTP_REQUEST_RT, h));
    // Owned storage (headers pair + uri string) is freed — enforced by the
    // testing allocator's leak check at ctx.deinit.

    // A request with NO transferred ends (trailers_future = 0) drops benignly.
    try ctx.http_requests.append(ctx.alloc, .{ .headers_rep = 99 });
    const h2 = try ctx.resources.new(WasiP2Ctx.HTTP_REQUEST_RT, 1);
    try p2ResourceDrop(&caller, h2);
}

/// True if `inst` exports a function named `name`.
fn instanceExportsFunc(inst: *Instance, name: []const u8) bool {
    for (inst.handle.exports_storage) |e| {
        if (e.kind == .func and std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

/// True if `inst` exports a linear memory (the canon-lower-bound memory the
/// host trampolines read/write — `$main` / `$libc`).
fn instanceExportsMemory(inst: *Instance) bool {
    for (inst.handle.exports_storage) |e| {
        if (e.kind == .memory) return true;
    }
    return false;
}

/// The WASI fd of the preopen rooted at host-OS fd `host_fd` (its `.dir`
/// fd-table slot), or null if not found.
fn preopenWasiFd(host: *wasi_host.Host, host_fd: std.posix.fd_t) ?wasi_p1.Fd {
    for (host.fd_table.items, 0..) |slot, i| {
        if (slot.kind == .dir and slot.host_handle == host_fd) return @intCast(i);
    }
    return null;
}

/// `wasi:filesystem/types` `[method]descriptor.open-at` (self, path_flags,
/// path_ptr, path_len, open_flags, descriptor_flags, retptr): open `path`
/// relative to the directory descriptor `self`, mint a descriptor resource for
/// the opened fd, and store `result<own<descriptor>, error-code>` (disc 0 = ok,
/// handle at +4) at `retptr`. P2 open-flags bits map 1:1 onto P1 oflags
/// (create/directory/exclusive/truncate = 0x1/2/4/8). A P1 error becomes
/// `result.err(error-code)` via the D-307 errno map (no trap).
pub fn p2DescriptorOpenAt(caller: *Caller, self_handle: u32, path_flags: u32, path_ptr: u32, path_len: u32, open_flags: u32, descriptor_flags: u32, retptr: u32) WasiP2Error!void {
    _ = path_flags;
    _ = descriptor_flags;
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    const oflags: wasi_p1.Oflags = @intCast(open_flags & 0x000F);
    // The component model has no rights: the preopen IS the sandbox. Ask for
    // everything the target type can carry and let `path_open` clamp against
    // the parent's inheriting set.
    const rights = wasi_p1.rightsForRightlessOpen(oflags);
    // pathOpen writes the opened fd to retptr+4; reuse that slot for the result payload.
    const errno = wasi_fd.pathOpen(ctx.host, mem.slice(), dirfd, 0, path_ptr, path_len, oflags, rights.base, rights.inheriting, 0, retptr + 4);
    if (errno != .success) {
        try writeP1Err(mem, retptr, 4, errno);
        return;
    }
    const opened_fd = try mem.read(u32, retptr + 4);
    const handle = try ctx.resources.new(WasiP2Ctx.DESCRIPTOR_RT, opened_fd);
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 4, handle); // own<descriptor>
}

/// `wasi:filesystem/preopens` `get-directories` (retptr): build a
/// `list<tuple<own<descriptor>, string>>` of the host's preopened dirs in a
/// freshly `cabi_realloc`'d backing (each entry mints a descriptor resource
/// bound to the preopen's WASI fd), then store `(list_ptr, list_len)` at
/// `retptr`. The list/string allocation is the nested-invoke realloc path.
pub fn p2GetDirectories(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const preopens = ctx.host.preopens;
    const n: u32 = @intCast(preopens.len);
    // Each list element is a tuple (descriptor handle i32, str_ptr i32, str_len i32) = 12 bytes.
    const list_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n * 12, 4);
    for (preopens, 0..) |p, i| {
        const wfd = preopenWasiFd(ctx.host, p.host_fd) orelse return WasiP2Error.WriteFailed;
        const handle = try ctx.resources.new(WasiP2Ctx.DESCRIPTOR_RT, wfd);
        const path_len: u32 = @intCast(p.guest_path.len);
        const str_ptr = try ctx.reallocGuest(path_len, 1);
        @memcpy(mem.sliceAt(str_ptr, path_len) catch return WasiP2Error.OutOfBounds, p.guest_path);
        const tup = list_ptr + @as(u32, @intCast(i)) * 12;
        try mem.write(tup, handle);
        try mem.write(tup + 4, str_ptr);
        try mem.write(tup + 8, path_len);
    }
    try mem.write(retptr, list_ptr);
    try mem.write(retptr + 4, n);
}

/// `wasi:io/streams` `[method]output-stream.blocking-flush` (self, retptr):
/// store `result<_, stream-error>` ok (disc 0) at `retptr`. The host writes
/// directly to the underlying fd (nothing is buffered at this layer), so a
/// flush is always an immediate success once the handle is valid.
fn p2OutStreamFlush(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const h = try ctx.resources.peek(self_handle); // validate handle (fd or socket stream)
    if (h.rt != WasiP2Ctx.OUTPUT_STREAM_RT and h.rt != WasiP2Ctx.SOCK_OUTPUT_STREAM_RT)
        return resource_table.Error.TypeMismatch;
    const mem = try ctxMemory(caller);
    try mem.write(retptr, @as(u8, 0)); // result disc: ok (nothing buffered at this layer)
}

/// `wasi:filesystem/types` `[method]descriptor.sync` (self, retptr): flush the
/// fd to disk via P1 `fd_sync`, then store `result<_, error-code>` at `retptr`
/// (disc 0 = ok; on a P1 error, disc 1 + the D-307 error-code ordinal at +1).
fn p2DescriptorSync(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    const errno = wasi_fd.fdSync(ctx.host, fd);
    if (errno == .success) {
        try mem.write(retptr, @as(u8, 0));
    } else {
        try writeP1Err(mem, retptr, 1, errno);
    }
}

/// Map a P1 `Filetype` onto the P2 `descriptor-type` enum ordinal (the two
/// enums diverge in case order — fifo/socket are P2-only at 4/7).
fn filetypeToDescriptorType(ft: wasi_p1.Filetype) u8 {
    return switch (ft) {
        .unknown => 0,
        .block_device => 1,
        .character_device => 2,
        .directory => 3,
        .regular_file => 6,
        .socket_dgram, .socket_stream => 7,
        .symbolic_link => 5,
        _ => 0,
    };
}

fn p2DescriptorGetType(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    switch (try descriptorFilestat(ctx, mem, fd)) {
        .ok => |fs| {
            try mem.write(retptr, @as(u8, 0)); // result disc: ok
            try mem.write(retptr + 1, filetypeToDescriptorType(fs.filetype));
        },
        .err => |errno| try writeP1Err(mem, retptr, 1, errno),
    }
}

/// `wasi:filesystem/types` `[method]descriptor.stat` (self, retptr): store
/// `result<descriptor-stat, error-code>` at `retptr`. The `descriptor-stat`
/// record (align 8) lands at the result payload offset +8; its canonical layout
/// is `%type@0, link-count@8, size@16` then three `option<datetime>` (24 bytes
/// each: disc@0, datetime{seconds u64@8, nanoseconds u32@16}) at +24/+48/+72.
fn p2DescriptorStat(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeStatResult(mem, retptr, try descriptorFilestat(ctx, mem, fd));
}

/// Store a `result<descriptor-stat, error-code>` at `retptr` (the shared
/// back-half for stat / stat-at; layout per `p2DescriptorStat`'s docstring).
fn writeStatResult(mem: Memory, retptr: u32, r: FilestatResult) WasiP2Error!void {
    switch (r) {
        .ok => |fs| {
            try mem.write(retptr, @as(u8, 0)); // result disc: ok
            const base = retptr + 8; // descriptor-stat align-8 payload
            try mem.write(base, filetypeToDescriptorType(fs.filetype));
            try mem.write(base + 8, @as(u64, fs.nlink));
            try mem.write(base + 16, @as(u64, fs.size));
            // Three Some(datetime) timestamps: access / modification / change.
            inline for (.{ .{ base + 24, fs.atim }, .{ base + 48, fs.mtim }, .{ base + 72, fs.ctim } }) |t| {
                try mem.write(t[0], @as(u8, 1)); // option disc: some
                try mem.write(t[0] + 8, @as(u64, t[1] / std.time.ns_per_s));
                try mem.write(t[0] + 16, @as(u32, @intCast(t[1] % std.time.ns_per_s)));
            }
        },
        .err => |errno| try writeP1Err(mem, retptr, 8, errno),
    }
}

/// `wasi:filesystem/types` `[method]descriptor.stat-at` (self, path_flags,
/// path_ptr, path_len, retptr): stat `path` relative to the directory
/// descriptor `self` via P1 `path_filestat_get`, honouring the P2
/// `path-flags{symlink-follow}` bit (1:1 with P1 lookupflags), then store
/// `result<descriptor-stat, error-code>` at `retptr` (same layout as `stat`).
fn p2DescriptorStatAt(caller: *Caller, self_handle: u32, path_flags: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeStatResult(mem, retptr, try pathFilestat(ctx, mem, dirfd, path_flags, path_ptr, path_len));
}

/// Write the err-arm of a filesystem `result<_, error-code>`: disc 1 at
/// `retptr`, then the D-307 P2 error-code ordinal at `retptr + off` (the
/// payload offset varies with the result's alignment: 1 / 4 / 8 across the
/// descriptor methods).
fn writeP1Err(mem: Memory, retptr: u32, off: u32, errno: wasi_p1.Errno) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 1));
    try mem.write(retptr + off, @intFromEnum(adapter.errnoToP2ErrorCode(errno)));
}

/// Store a `result<_, error-code>` at `retptr` — disc@0, error-code payload@1
/// (both align 1; the unit ok-arm carries no payload). The shared back-half
/// for the path-mutation `*-at` methods + `sync-data`.
fn writeUnitResult(mem: Memory, retptr: u32, errno: wasi_p1.Errno) WasiP2Error!void {
    if (errno == .success) {
        try mem.write(retptr, @as(u8, 0));
        return;
    }
    try writeP1Err(mem, retptr, 1, errno);
}

/// `wasi:filesystem/types` `[method]descriptor.create-directory-at`
/// (self, path_ptr, path_len, retptr) → P1 `path_create_directory`.
fn p2DescriptorCreateDirectoryAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_path.pathCreateDirectory(ctx.host, mem.slice(), dirfd, path_ptr, path_len));
}

/// `wasi:filesystem/types` `[method]descriptor.remove-directory-at`
/// (self, path_ptr, path_len, retptr) → P1 `path_remove_directory`.
fn p2DescriptorRemoveDirectoryAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_path.pathRemoveDirectory(ctx.host, mem.slice(), dirfd, path_ptr, path_len));
}

/// `wasi:filesystem/types` `[method]descriptor.unlink-file-at`
/// (self, path_ptr, path_len, retptr) → P1 `path_unlink_file`.
fn p2DescriptorUnlinkFileAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_fd.pathUnlinkFile(ctx.host, mem.slice(), dirfd, path_ptr, path_len));
}

/// `wasi:filesystem/types` `[method]descriptor.rename-at` (self, old_ptr,
/// old_len, new_desc, new_ptr, new_len, retptr): rename old (relative to
/// `self`) to new (relative to the borrowed `new_desc` directory descriptor)
/// via P1 `path_rename`.
fn p2DescriptorRenameAt(caller: *Caller, self_handle: u32, old_ptr: u32, old_len: u32, new_desc: u32, new_ptr: u32, new_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const old_dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const new_dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, new_desc));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_path.pathRename(ctx.host, mem.slice(), old_dirfd, old_ptr, old_len, new_dirfd, new_ptr, new_len));
}

/// `wasi:filesystem/types` `[method]descriptor.link-at` (self, old_flags,
/// old_ptr, old_len, new_desc, new_ptr, new_len, retptr): hard-link old
/// (relative to `self`, honouring `path-flags{symlink-follow}` = P1
/// lookupflags bit 0) as new (relative to `new_desc`) via P1 `path_link`.
fn p2DescriptorLinkAt(caller: *Caller, self_handle: u32, old_flags: u32, old_ptr: u32, old_len: u32, new_desc: u32, new_ptr: u32, new_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const old_dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const new_dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, new_desc));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_path.pathLink(ctx.host, mem.slice(), old_dirfd, old_flags, old_ptr, old_len, new_dirfd, new_ptr, new_len));
}

/// `wasi:filesystem/types` `[method]descriptor.symlink-at` (self, old_ptr,
/// old_len, new_ptr, new_len, retptr): create a symlink at new (relative to
/// `self`) pointing at the old-path TEXT via P1 `path_symlink`.
fn p2DescriptorSymlinkAt(caller: *Caller, self_handle: u32, old_ptr: u32, old_len: u32, new_ptr: u32, new_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_path.pathSymlink(ctx.host, mem.slice(), old_ptr, old_len, dirfd, new_ptr, new_len));
}

/// `wasi:filesystem/types` `[method]descriptor.sync-data` (self, retptr) →
/// P1 `fd_datasync`.
fn p2DescriptorSyncData(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_fd.fdDatasync(ctx.host, fd));
}

/// `wasi:filesystem/types` `[method]descriptor.readlink-at` (self, path_ptr,
/// path_len, retptr): read the symlink target into a `cabi_realloc`'d buffer
/// via P1 `path_readlink`, then store `result<string, error-code>` at `retptr`
/// (disc@0; ok string ptr@+4 len@+8; err code@+4).
fn p2DescriptorReadlinkAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    const buf_len: u32 = 4096; // symlink-target cap (PATH_MAX class)
    const buf_ptr = try ctx.reallocGuest(buf_len, 1);
    const scratch = try ctx.reallocGuest(4, 4); // P1 bufused out-slot
    const errno = wasi_path.pathReadlink(ctx.host, mem.slice(), dirfd, path_ptr, path_len, buf_ptr, buf_len, scratch);
    if (errno != .success) {
        try writeP1Err(mem, retptr, 4, errno);
        return;
    }
    const used = try mem.read(u32, scratch);
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 4, buf_ptr); // string data ptr
    try mem.write(retptr + 8, used); // string length
}

/// `wasi:filesystem/types` `[method]descriptor.read-directory` (self, retptr):
/// mint a directory-entry-stream over the directory descriptor `self` (state =
/// `{fd, cookie 0}` in `ctx.dir_streams`; the handle rep is the state index)
/// and store `result<own<directory-entry-stream>, error-code>` (ok handle@+4)
/// at `retptr`.
fn p2DescriptorReadDirectory(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    const state_index: u32 = @intCast(ctx.dir_streams.items.len);
    ctx.dir_streams.append(ctx.alloc, .{ .fd = fd, .cookie = 0 }) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.DIR_STREAM_RT, state_index);
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 4, handle); // own<directory-entry-stream>
}

/// `wasi:filesystem/types` `[method]directory-entry-stream.read-directory-entry`
/// (self, retptr): read ONE entry via P1 `fd_readdir` at the stream's cookie,
/// skipping the P1-synthetic `.`/`..` (the P2 stream excludes them), then store
/// `result<option<directory-entry>, error-code>` at `retptr`: disc@0; ok option
/// disc@+4 (0 = stream end); entry record `%type`@+8, name ptr@+12, len@+16
/// (name in a fresh `cabi_realloc` backing); err code@+4.
fn p2DirEntryStreamReadEntry(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const state_index: u32 = @intCast(try ctx.resources.rep(WasiP2Ctx.DIR_STREAM_RT, self_handle));
    if (state_index >= ctx.dir_streams.items.len) return WasiP2Error.InvalidHandle;
    const state = &ctx.dir_streams.items[state_index];
    const mem = try ctxMemory(caller);
    // One dirent header (24 B) + a PATH-class name fits comfortably; P1 packs
    // as many entries as fit, we parse only the first per call.
    const buf_len: u32 = 4096;
    const buf_ptr = try ctx.reallocGuest(buf_len, 8);
    const used_ptr = try ctx.reallocGuest(4, 4);
    while (true) {
        const errno = wasi_fd.fdReaddir(ctx.host, mem.slice(), state.fd, buf_ptr, buf_len, state.cookie, used_ptr);
        if (errno != .success) {
            try writeP1Err(mem, retptr, 4, errno);
            return;
        }
        const used = try mem.read(u32, used_ptr);
        if (used < 24) { // not even one header — stream end
            try mem.write(retptr, @as(u8, 0)); // result disc: ok
            try mem.write(retptr + 4, @as(u8, 0)); // option disc: none
            return;
        }
        const d_next = try mem.read(u64, buf_ptr);
        const d_namlen = try mem.read(u32, buf_ptr + 16);
        const d_type = try mem.read(u8, buf_ptr + 20);
        if (used < 24 + d_namlen) return WasiP2Error.OutOfBounds; // truncated name (> 4 KiB path)
        state.cookie = d_next;
        const name = mem.sliceAt(buf_ptr + 24, d_namlen) catch return WasiP2Error.OutOfBounds;
        // P1 synthesizes "." / ".."; the P2 stream excludes them.
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const name_ptr = if (d_namlen == 0) 0 else try ctx.reallocGuest(d_namlen, 1);
        if (d_namlen != 0) {
            const dest = mem.sliceAt(name_ptr, d_namlen) catch return WasiP2Error.OutOfBounds;
            // Re-slice the source: reallocGuest may have moved/grown memory.
            const src = mem.sliceAt(buf_ptr + 24, d_namlen) catch return WasiP2Error.OutOfBounds;
            @memcpy(dest, src);
        }
        try mem.write(retptr, @as(u8, 0)); // result disc: ok
        try mem.write(retptr + 4, @as(u8, 1)); // option disc: some
        try mem.write(retptr + 8, filetypeToDescriptorType(@enumFromInt(d_type)));
        try mem.write(retptr + 12, name_ptr); // directory-entry.name ptr
        try mem.write(retptr + 16, d_namlen); // directory-entry.name len
        return;
    }
}

/// `wasi:random/random` `get-random-u64` `() -> u64`: 8 secure-random bytes
/// as the lowered `i64` return (no guest allocation).
fn p2RandomGetU64(caller: *Caller) WasiP2Error!i64 {
    const ctx = caller.data(WasiP2Ctx);
    var buf: [8]u8 = undefined;
    if (wasi_clocks.randomFill(ctx.host, &buf) != .success)
        return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
    return @bitCast(std.mem.readInt(u64, &buf, .little));
}

/// `wasi:random/insecure-seed` `insecure-seed` `() -> tuple<u64, u64>`: a
/// 128-bit seed for hashing. The contract permits a non-crypto source, so the
/// host's secure fill over-satisfies it — but the value is morally a VALUE
/// IMPORT ("should return the same values each time it is called"), so the
/// first fill is cached per ctx. The tuple flattens past MAX_FLAT_RESULTS=1 →
/// the two u64 land at `retptr` (+0, +8).
fn p2RandomInsecureSeed(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const seed = ctx.insecure_seed orelse blk: {
        var buf: [16]u8 = undefined;
        if (wasi_clocks.randomFill(ctx.host, &buf) != .success)
            return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
        const s: [2]u64 = .{ std.mem.readInt(u64, buf[0..8], .little), std.mem.readInt(u64, buf[8..16], .little) };
        ctx.insecure_seed = s;
        break :blk s;
    };
    try mem.write(retptr, seed[0]);
    try mem.write(retptr + 8, seed[1]);
}

/// `wasi:filesystem/types` `[method]descriptor.read` (self, length, offset,
/// retptr): positionally read up to `length` bytes at `offset` into a
/// `cabi_realloc`'d buffer via P1 `fd_pread`, then store `result<tuple<list<u8>,
/// bool>, error-code>` at `retptr` (align 4 → payload@+4): on ok, list
/// (data_ptr@+4, len@+8) + EOF bool@+12; on a P1 error, disc 1 + error-code@+4.
fn p2DescriptorRead(caller: *Caller, self_handle: u32, length: u64, offset: u64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    const n: u32 = @intCast(@min(length, std.math.maxInt(u32)));
    const data_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n, 1);
    // A single-entry iovec + nread slot in a fresh scratch area (P1 fd_pread is
    // iovec-based; reuse it wholesale rather than duplicate the read loop).
    const scratch = try ctx.reallocGuest(12, 4);
    try mem.write(scratch, data_ptr); // iovec[0].buf
    try mem.write(scratch + 4, n); // iovec[0].buf_len
    const errno = wasi_fd.fdPread(ctx.host, mem.slice(), fd, scratch, 1, offset, scratch + 8);
    if (errno != .success) {
        try writeP1Err(mem, retptr, 4, errno);
        return;
    }
    const nread = try mem.read(u32, scratch + 8);
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 4, data_ptr); // tuple.0 list data ptr
    try mem.write(retptr + 8, nread); // tuple.0 list length
    try mem.write(retptr + 12, @as(u8, if (nread < n) 1 else 0)); // tuple.1 eof bool
}

// ---- wasi:io/poll (D3-7) ----
//
// A synchronous host has no async readiness: every resource it models is
// always ready (a file read never blocks, stdio is immediate, a clock duration
// is checked at poll time). So every pollable's `ready` is true, `block` is a
// noop, and `poll` reports all input pollables ready. `subscribe`-style methods
// mint a POLLABLE_RT handle; its rep is unused (kept 0). This matches the spec
// contract (poll never fails; readiness errors surface via the source op).

/// `wasi:io/streams`/`wasi:clocks` `subscribe*` → mint a pollable handle. The
/// source handle / clock argument is irrelevant for an always-ready host.
fn p2Subscribe(caller: *Caller, self_handle: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    // A socket-backed stream subscribes a REAL readiness pollable (ADR-0180);
    // every other resource keeps the synchronous host's always-ready handle.
    const h = ctx.resources.peek(self_handle) catch return ctx.resources.new(WasiP2Ctx.POLLABLE_RT, 0);
    if (h.rt == WasiP2Ctx.SOCK_INPUT_STREAM_RT)
        return ctx.resources.new(WasiP2Ctx.SOCK_POLLABLE_RT, (h.rep & 0x00FF_FFFF) | (1 << 24));
    if (h.rt == WasiP2Ctx.SOCK_OUTPUT_STREAM_RT)
        return ctx.resources.new(WasiP2Ctx.SOCK_POLLABLE_RT, (h.rep & 0x00FF_FFFF) | (2 << 24));
    return ctx.resources.new(WasiP2Ctx.POLLABLE_RT, 0);
}

/// True iff the SOCK_POLLABLE_RT rep's socket is ready for its packed
/// interest (1 = read, 2 = write, 3 = either).
fn sockPollableReady(ctx: *WasiP2Ctx, rep: u32) bool {
    const sock = ctxTcpSocket(ctx, rep) catch return true; // dead handle never blocks a waiter
    const tag = rep >> 24;
    const interest: i16 = switch (tag) {
        1 => p2sock.POLL_IN,
        2 => p2sock.POLL_OUT,
        else => p2sock.POLL_IN | p2sock.POLL_OUT,
    };
    return sock.ready(interest) catch true;
}

/// `wasi:clocks/monotonic-clock` `subscribe-instant`/`subscribe-duration`
/// (when: u64) → pollable. Same always-ready handle; the deadline is ignored.
fn p2SubscribeClock(caller: *Caller, _: u64) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.POLLABLE_RT, 0);
}

/// `wasi:io/poll` `[method]pollable.ready` (self) -> bool: always ready (1).
fn p2PollableReady(caller: *Caller, self_handle: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const h = try ctx.resources.peek(self_handle);
    if (h.rt == WasiP2Ctx.SOCK_POLLABLE_RT) return @intFromBool(sockPollableReady(ctx, h.rep));
    if (h.rt != WasiP2Ctx.POLLABLE_RT) return resource_table.Error.TypeMismatch;
    return 1;
}

/// `wasi:io/poll` `[method]pollable.block` (self): a synchronous host never
/// blocks — return immediately once the handle is validated.
fn p2PollableBlock(caller: *Caller, self_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const h = try ctx.resources.peek(self_handle);
    if (h.rt == WasiP2Ctx.SOCK_POLLABLE_RT) {
        const io = try ctxIo(ctx);
        var waited: u32 = 0;
        while (!sockPollableReady(ctx, h.rep) and waited < 30_000) : (waited += 2) {
            io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake) catch break;
        }
        return;
    }
    if (h.rt != WasiP2Ctx.POLLABLE_RT) return resource_table.Error.TypeMismatch;
}

/// `wasi:io/poll` `poll(in: list<borrow<pollable>>) -> list<u32>` (in_ptr,
/// in_len, retptr): every pollable is always ready, so return the full index
/// set `[0, in_len)` as a freshly `cabi_realloc`'d `list<u32>` and write
/// `(data_ptr, in_len)` at `retptr`. Each input handle is validated.
fn p2Poll(caller: *Caller, in_ptr: u32, in_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const data_ptr: u32 = if (in_len == 0) 0 else try ctx.reallocGuest(in_len * 4, 4);
    // Spec: block until >= 1 pollable is ready, then return the ready index
    // set. Non-socket pollables are always ready (synchronous host);
    // socket-backed entries consult poll(2) (ADR-0180) — so the wait loop
    // only ever engages when EVERY entry is socket-backed and idle.
    var waited: u32 = 0;
    while (true) {
        var ready_n: u32 = 0;
        var i: u32 = 0;
        while (i < in_len) : (i += 1) {
            const h = try ctx.resources.peek(try mem.read(u32, in_ptr + i * 4));
            const is_ready = if (h.rt == WasiP2Ctx.SOCK_POLLABLE_RT) sockPollableReady(ctx, h.rep) else true;
            if (is_ready) {
                try mem.write(data_ptr + ready_n * 4, i);
                ready_n += 1;
            }
        }
        if (ready_n > 0 or in_len == 0 or waited >= 30_000) {
            try mem.write(retptr, data_ptr); // list data ptr
            try mem.write(retptr + 4, ready_n); // list length
            return;
        }
        const io = try ctxIo(ctx);
        io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake) catch break;
        waited += 2;
    }
    try mem.write(retptr, data_ptr);
    try mem.write(retptr + 4, @as(u32, 0));
}

// ---- wasi:cli/environment + terminal-* + output-stream.check-write (E2) ----
//
// A sandboxed, non-tty, always-writable host. get-environment / get-arguments
// return the empty list; initial-cwd + get-terminal-* return `none`;
// check-write reports a large byte permit so the guest proceeds to write.

/// Copy `s` into a fresh `cabi_realloc` backing, returning (ptr, len).
fn allocGuestString(ctx: *WasiP2Ctx, mem: Memory, s: []const u8) WasiP2Error!struct { ptr: u32, len: u32 } {
    const n: u32 = @intCast(s.len);
    const ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n, 1);
    if (n != 0) {
        const dest = mem.sliceAt(ptr, n) catch return WasiP2Error.OutOfBounds;
        @memcpy(dest, s);
    }
    return .{ .ptr = ptr, .len = n };
}

/// `wasi:cli/environment` `get-arguments` -> `list<string>` of the host argv
/// (set via `Host.setArgs` / CLI trailing args; empty when unset).
fn p2GetArguments(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const args = ctx.host.args;
    const n: u32 = @intCast(args.len);
    const list_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n * 8, 4);
    for (args, 0..) |arg, i| {
        const str = try allocGuestString(ctx, mem, arg);
        const elem = list_ptr + @as(u32, @intCast(i)) * 8;
        try mem.write(elem, str.ptr);
        try mem.write(elem + 4, str.len);
    }
    try mem.write(retptr, list_ptr);
    try mem.write(retptr + 4, n);
}

/// `wasi:cli/environment` `get-environment` -> `list<tuple<string, string>>`
/// of the host env entries (set via `Host.setEnvs` / `--env`).
fn p2GetEnvironment(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const envs = ctx.host.envs;
    const n: u32 = @intCast(envs.len);
    const list_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n * 16, 4);
    for (envs, 0..) |e, i| {
        const k = try allocGuestString(ctx, mem, e.key);
        const v = try allocGuestString(ctx, mem, e.value);
        const elem = list_ptr + @as(u32, @intCast(i)) * 16;
        try mem.write(elem, k.ptr);
        try mem.write(elem + 4, k.len);
        try mem.write(elem + 8, v.ptr);
        try mem.write(elem + 12, v.len);
    }
    try mem.write(retptr, list_ptr);
    try mem.write(retptr + 4, n);
}

/// An `option<...>` host query with no value (`initial-cwd`, `get-terminal-*`)
/// → `none`: write the option discriminant 0 at `retptr`.
fn p2ReturnNone(caller: *Caller, retptr: u32) WasiP2Error!void {
    const mem = try ctxMemory(caller);
    try mem.write(retptr, @as(u8, 0)); // option disc: none
}

/// `wasi:io/streams` `[method]output-stream.check-write` (self, retptr) ->
/// `result<u64, stream-error>`: an always-writable sync host reports a large
/// permit. Writes disc 0 (ok) + the u64 permit at `retptr+8` (align 8).
fn p2CheckWrite(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const h = try ctx.resources.peek(self_handle);
    const mem = try ctxMemory(caller);
    if (h.rt == WasiP2Ctx.SOCK_OUTPUT_STREAM_RT) {
        // Socket permit is REAL (ADR-0180): writable now -> a page; else 0
        // (the guest subscribes + polls).
        const sock = try ctxTcpSocket(ctx, h.rep);
        const writable = sock.ready(p2sock.POLL_OUT) catch false;
        try mem.write(retptr, @as(u8, 0));
        try mem.write(retptr + 8, @as(u64, if (writable) 4096 else 0));
        return;
    }
    if (h.rt != WasiP2Ctx.OUTPUT_STREAM_RT) return resource_table.Error.TypeMismatch;
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 8, @as(u64, 4096)); // bytes the guest may write now
}

// ---- wasi:sockets (ADR-0180 Phase 1) ----

/// `wasi:sockets/instance-network` `instance-network()` -> the ambient
/// network singleton resource.
fn p2InstanceNetwork(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.NETWORK_RT, 0);
}

/// `wasi:sockets/tcp-create-socket` `create-tcp-socket(address-family)`
/// (family, retptr) -> result<own<tcp-socket>, error-code> (ok handle@+4 /
/// err code@+4).
fn p2CreateTcpSocket(caller: *Caller, family: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fam: p2sock.AddressFamily = if (family == 0) .ipv4 else .ipv6;
    const idx: u32 = @intCast(ctx.tcp_sockets.items.len);
    ctx.tcp_sockets.append(ctx.alloc, p2sock.TcpSocket.create(fam)) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.TCP_SOCKET_RT, idx);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, handle);
}

/// Decode the flattened `ip-socket-address` variant (disc + 11 joined flat
/// params; ipv4 uses p0..p4, ipv6 all 11) into a host `IpAddress`.
fn writeSockErr(mem: Memory, retptr: u32, off: u32, e: anyerror) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 1));
    try mem.write(retptr + off, @intFromEnum(p2sock.errorToCode(e)));
}

/// Store a `result<_, error-code>` for a sockets op at `retptr` (disc@0,
/// `wasi:sockets/network` error-code@+1).
fn writeSockUnitResult(mem: Memory, retptr: u32, err: ?anyerror) WasiP2Error!void {
    if (err) |e| return writeSockErr(mem, retptr, 1, e);
    try mem.write(retptr, @as(u8, 0));
}

/// `tcp.start-bind` (self, network, addr-disc, p0..p10, retptr) ->
/// result<_, error-code> (err@+1).
fn p2TcpStartBind(caller: *Caller, self: u32, network: u32, disc: u32, p0: u32, p1: u32, p2: u32, p3: u32, p4: u32, p5: u32, p6: u32, p7: u32, p8: u32, p9: u32, p10: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    _ = try ctx.resources.rep(WasiP2Ctx.NETWORK_RT, network);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    const addr = decodeIpSocketAddress(disc, .{ p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 }) orelse
        return writeSockUnitResult(mem, retptr, error.InvalidArgument);
    sock.startBind(try ctxIo(ctx), addr) catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.finish-bind` (self, retptr) -> result<_, error-code>.
fn p2TcpFinishBind(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    sock.finishBind() catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.start-connect` (same flat shape as start-bind) -> result<_, error-code>.
fn p2TcpStartConnect(caller: *Caller, self: u32, network: u32, disc: u32, p0: u32, p1: u32, p2: u32, p3: u32, p4: u32, p5: u32, p6: u32, p7: u32, p8: u32, p9: u32, p10: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    _ = try ctx.resources.rep(WasiP2Ctx.NETWORK_RT, network);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    const addr = decodeIpSocketAddress(disc, .{ p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 }) orelse
        return writeSockUnitResult(mem, retptr, error.InvalidArgument);
    sock.startConnect(try ctxIo(ctx), addr) catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.finish-connect` (self, retptr) -> result<(own<input-stream>,
/// own<output-stream>), error-code> (ok in@+4 out@+8; err@+4). Mints the
/// socket-backed stream pair on success.
fn p2TcpFinishConnect(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const rep = try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self);
    const sock = try ctxTcpSocket(ctx, rep);
    sock.finishConnect() catch |e| return writeSockErr(mem, retptr, 4, e);
    const in_h = try ctx.resources.new(WasiP2Ctx.SOCK_INPUT_STREAM_RT, rep);
    const out_h = try ctx.resources.new(WasiP2Ctx.SOCK_OUTPUT_STREAM_RT, rep);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, in_h);
    try mem.write(retptr + 8, out_h);
}

/// `tcp.subscribe` (self) -> pollable watching the socket for any activity.
fn p2TcpSubscribe(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const rep = try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self);
    return ctx.resources.new(WasiP2Ctx.SOCK_POLLABLE_RT, (rep & 0x00FF_FFFF) | (3 << 24));
}

/// `tcp.shutdown` (self, how, retptr) -> result<_, error-code>. `how`:
/// 0 = receive, 1 = send, 2 = both (spec `shutdown-type` ordinals).
fn p2TcpShutdown(caller: *Caller, self: u32, how: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    const dir: std.Io.net.ShutdownHow = switch (how) {
        0 => .recv,
        1 => .send,
        else => .both,
    };
    sock.shutdown(try ctxIo(ctx), dir) catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.is-listening` (self) -> bool.
fn p2TcpIsListening(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    return @intFromBool(sock.state == .listening);
}

/// `tcp.start-listen` (self, retptr) -> result<_, error-code>. The OS
/// socket+bind+listen runs here (ADR-0180 Phase-2 defer-bind divergence).
fn p2TcpStartListen(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    sock.startListen(try ctxIo(ctx)) catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.finish-listen` (self, retptr) -> result<_, error-code>.
fn p2TcpFinishListen(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    sock.finishListen() catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.set-listen-backlog-size` (self, value:u64, retptr) ->
/// result<_, error-code>.
fn p2TcpSetListenBacklog(caller: *Caller, self: u32, value: u64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    sock.setListenBacklog(value) catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.accept` (self, retptr) -> result<tuple<own<tcp-socket>,
/// own<input-stream>, own<output-stream>>, error-code> (ok handles
/// @+4/+8/+12; err@+4). Registers the accepted connection as a fresh
/// connected tcp-socket resource and mints its socket-backed stream pair
/// (the finish-connect shape).
fn p2TcpAccept(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    const accepted = sock.accept(try ctxIo(ctx)) catch |e| return writeSockErr(mem, retptr, 4, e);
    // NOTE: append AFTER the last `sock` deref — it may move the list.
    const idx: u32 = @intCast(ctx.tcp_sockets.items.len);
    ctx.tcp_sockets.append(ctx.alloc, accepted) catch return WasiP2Error.OutOfMemory;
    const sock_h = try ctx.resources.new(WasiP2Ctx.TCP_SOCKET_RT, idx);
    const in_h = try ctx.resources.new(WasiP2Ctx.SOCK_INPUT_STREAM_RT, idx);
    const out_h = try ctx.resources.new(WasiP2Ctx.SOCK_OUTPUT_STREAM_RT, idx);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, sock_h);
    try mem.write(retptr + 8, in_h);
    try mem.write(retptr + 12, out_h);
}

/// Store a `result<ip-socket-address, error-code>` at `retptr` per the
/// canonical ABI in-memory layout: result disc@0, payload@+4; the
/// ip-socket-address variant disc@+4, case record@+8 (ipv4: port:u16@8,
/// addr bytes@10..14; ipv6: port:u16@8, flow:u32@12, segments 8*u16
/// @16..32, scope-id:u32@32).
fn p2TcpLocalAddress(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    const addr = sock.localAddress() catch |e| return writeSockErr(mem, retptr, 4, e);
    try writeIpSocketAddressResult(mem, retptr, addr);
}

/// `tcp.remote-address` (self, retptr) -> result<ip-socket-address, error-code>.
fn p2TcpRemoteAddress(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    const addr = sock.remoteAddress() catch |e| return writeSockErr(mem, retptr, 4, e);
    try writeIpSocketAddressResult(mem, retptr, addr);
}

// -- not-supported stubs (ADR-0180 phased scope): the spec's TYPED signal --
// Each writes result.err(not-supported) at the shape's err-payload offset.

fn sockStubWriteErr(caller: *Caller, retptr: u32, comptime off: u32) WasiP2Error!void {
    const mem = try ctxMemory(caller);
    try mem.write(retptr, @as(u8, 1));
    try mem.write(retptr + off, @intFromEnum(p2sock.ErrorCode.not_supported));
}

fn p2SockStubUnit2(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 1);
}
fn p2SockStubUnit3i(caller: *Caller, _: u32, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 1);
}
fn p2SockStubUnit3l(caller: *Caller, _: u32, _: u64, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 1);
}
fn p2SockStubUnit15(caller: *Caller, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 1);
}
fn p2SockStubVal1(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 1);
}
fn p2SockStubVal4(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 4);
}
fn p2SockStubVal8(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 8);
}
fn p2SockStubVal15_4(caller: *Caller, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 4);
}
fn p2SockStubResolve(caller: *Caller, _: u32, _: u32, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 4);
}
fn p2SockStubRecv(caller: *Caller, _: u32, _: u64, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 4);
}
fn p2SockStubSend(caller: *Caller, _: u32, _: u32, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 8);
}
/// wasi:filesystem not-supported stubs (rust-std links the *-via-stream /
/// metadata methods; a CLI/TCP guest never calls them) — err(unsupported),
/// the FILESYSTEM error-code ordinal, at the shape's payload offset.
fn fsStubWriteUnsupported(caller: *Caller, retptr: u32, comptime off: u32) WasiP2Error!void {
    const mem = try ctxMemory(caller);
    try mem.write(retptr, @as(u8, 1));
    try mem.write(retptr + off, @intFromEnum(adapter.P2ErrorCode.unsupported));
}

fn p2FsStubViaStreamOffset(caller: *Caller, _: u32, _: u64, retptr: u32) WasiP2Error!void {
    return fsStubWriteUnsupported(caller, retptr, 4);
}
fn p2FsStubViaStream(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return fsStubWriteUnsupported(caller, retptr, 4);
}
fn p2FsStubGetFlags(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return fsStubWriteUnsupported(caller, retptr, 1);
}
fn p2FsStubMetadataHash(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return fsStubWriteUnsupported(caller, retptr, 8);
}

fn p2SockStubSubscribe(caller: *Caller, _: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.POLLABLE_RT, 0);
}

/// Bind the trampoline for `op` under the core import `name` in namespace
/// `module`. The name is whatever the core module imports; the trampoline is
/// chosen by the classified `op`, not by the name.
fn defineClassifiedFunc(lk: *Linker, module: []const u8, name: []const u8, op: adapter.P2Op, ctx: *WasiP2Ctx) !void {
    switch (op) {
        .cli_get_stdout => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, p2GetStdout),
        .cli_get_stderr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, p2GetStderr),
        .cli_stdout_write_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2StdoutWriteViaStream),
        .cli_stderr_write_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2StderrWriteViaStream),
        .cli_stdin_read_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2StdinReadViaStream),
        .out_stream_write, .out_stream_blocking_write_and_flush => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2OutStreamWrite),
        // Any classified `canon resource.drop` (classifyCoreExport returns
        // out_stream_drop for all) routes to the generic drop — correct for both
        // output-stream and descriptor handles (both rep = a P1 fd).
        .out_stream_drop, .fs_descriptor_drop, .in_stream_drop => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ResourceDrop),
        .cli_get_stdin => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, p2GetStdin),
        .in_stream_read => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2InStreamRead),
        .in_stream_blocking_read => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2InStreamBlockingRead),
        .fs_descriptor_write => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u64, u32) WasiP2Error!void, p2DescriptorWrite),
        .fs_get_directories => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2GetDirectories),
        .fs_descriptor_open_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorOpenAt),
        .cli_exit => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2Exit),
        .cli_exit_with_code => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ExitWithCode),
        // The async wait funcs under a SYNC lower: the call blocks in the host.
        .clocks_wait_until => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, i64) WasiP2Error!void, p2WaitUntilSync),
        .clocks_wait_for => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, i64) WasiP2Error!void, p2WaitForSync),
        .clocks_monotonic_now => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!i64, p2MonotonicNow),
        .clocks_wall_now => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2WallNow),
        .clocks_system_now => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2SystemNow),
        .clocks_system_get_resolution => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!i64, p2SystemGetResolution),
        .clocks_monotonic_get_resolution => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!i64, p2MonotonicGetResolution),
        // insecure shares the secure handler: identical signature, and the host's
        // secure fill over-satisfies the insecure contract (no separate RNG state).
        .random_get_bytes, .random_insecure_get_bytes => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u64, u32) WasiP2Error!void, p2RandomGetBytes),
        .out_stream_blocking_flush => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2OutStreamFlush),
        .fs_descriptor_read => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u64, u32) WasiP2Error!void, p2DescriptorRead),
        .fs_descriptor_sync => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2DescriptorSync),
        .fs_descriptor_stat => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2DescriptorStat),
        .fs_descriptor_get_type => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2DescriptorGetType),
        .poll_pollable_ready => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2PollableReady),
        .poll_pollable_block => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2PollableBlock),
        .poll_poll => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, p2Poll),
        .in_stream_subscribe, .out_stream_subscribe => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2Subscribe),
        .clocks_subscribe_instant, .clocks_subscribe_duration => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u64) WasiP2Error!u32, p2SubscribeClock),
        .cli_get_environment => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2GetEnvironment),
        .cli_get_arguments => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2GetArguments),
        .cli_initial_cwd, .cli_get_terminal_stdin, .cli_get_terminal_stdout, .cli_get_terminal_stderr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ReturnNone),
        .out_stream_check_write => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2CheckWrite),
        .random_get_u64, .random_insecure_get_u64 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!i64, p2RandomGetU64),
        .random_insecure_seed => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2RandomInsecureSeed),
        .fs_descriptor_stat_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorStatAt),
        .fs_descriptor_create_directory_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorCreateDirectoryAt),
        .fs_descriptor_remove_directory_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorRemoveDirectoryAt),
        .fs_descriptor_unlink_file_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorUnlinkFileAt),
        .fs_descriptor_rename_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorRenameAt),
        .fs_descriptor_link_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorLinkAt),
        .fs_descriptor_symlink_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorSymlinkAt),
        .fs_descriptor_sync_data => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2DescriptorSyncData),
        .fs_descriptor_readlink_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorReadlinkAt),
        .fs_descriptor_read_directory => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2DescriptorReadDirectory),
        .fs_dir_entry_stream_read => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2DirEntryStreamReadEntry),
        .fs_dir_entry_stream_drop => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ResourceDrop),
        .io_resource_drop => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ResourceDrop),
        // The wasi:{filesystem,sockets,http}@0.3.0 arms live with the P3 host
        // layer (ADR-0207 registerP3Arms); listing the tags here keeps the
        // switch compile-time exhaustive — a new P3 op fails HERE, loudly.
        .fs3_advise, .fs3_append_via_stream, .fs3_create_directory_at, .fs3_get_flags, .fs3_get_type, .fs3_is_same_object, .fs3_link_at, .fs3_metadata_hash, .fs3_metadata_hash_at, .fs3_open_at, .fs3_read_directory, .fs3_read_via_stream, .fs3_readlink_at, .fs3_remove_directory_at, .fs3_rename_at, .fs3_set_size, .fs3_set_times, .fs3_set_times_at, .fs3_stat, .fs3_stat_at, .fs3_symlink_at, .fs3_sync, .fs3_sync_data, .fs3_unlink_file_at, .fs3_write_via_stream, .http3_client_send, .http3_fields_append, .http3_fields_clone, .http3_fields_copy_all, .http3_fields_delete, .http3_fields_from_list, .http3_fields_get, .http3_fields_get_and_delete, .http3_fields_has, .http3_fields_new, .http3_fields_set, .http3_reqopts_between_bytes_get, .http3_reqopts_between_bytes_set, .http3_reqopts_clone, .http3_reqopts_connect_get, .http3_reqopts_connect_set, .http3_reqopts_first_byte_get, .http3_reqopts_first_byte_set, .http3_reqopts_new, .http3_request_consume_body, .http3_request_get_authority, .http3_request_get_headers, .http3_request_get_method, .http3_request_get_options, .http3_request_get_pwq, .http3_request_get_scheme, .http3_request_new, .http3_request_set_authority, .http3_request_set_method, .http3_request_set_pwq, .http3_request_set_scheme, .http3_response_consume_body, .http3_response_get_headers, .http3_response_get_status, .http3_response_new, .http3_response_set_status, .sock3_resolve_addresses, .sock3_tcp_bind, .sock3_tcp_connect, .sock3_tcp_create, .sock3_tcp_family, .sock3_tcp_hop_get, .sock3_tcp_hop_set, .sock3_tcp_is_listening, .sock3_tcp_ka_count_get, .sock3_tcp_ka_count_set, .sock3_tcp_ka_enabled_get, .sock3_tcp_ka_enabled_set, .sock3_tcp_ka_idle_get, .sock3_tcp_ka_idle_set, .sock3_tcp_ka_interval_get, .sock3_tcp_ka_interval_set, .sock3_tcp_listen, .sock3_tcp_local_addr, .sock3_tcp_rcvbuf_get, .sock3_tcp_rcvbuf_set, .sock3_tcp_receive, .sock3_tcp_remote_addr, .sock3_tcp_send, .sock3_tcp_set_backlog, .sock3_tcp_sndbuf_get, .sock3_tcp_sndbuf_set, .sock3_udp_bind, .sock3_udp_connect, .sock3_udp_create, .sock3_udp_disconnect, .sock3_udp_family, .sock3_udp_hop_get, .sock3_udp_hop_set, .sock3_udp_local_addr, .sock3_udp_rcvbuf_get, .sock3_udp_rcvbuf_set, .sock3_udp_receive, .sock3_udp_remote_addr, .sock3_udp_send, .sock3_udp_sndbuf_get, .sock3_udp_sndbuf_set => {
            if (try p3h.registerP3Arms(lk, module, name, op, ctx)) return;
            return error.UnsupportedWasiImport;
        },
        .fs_stub_via_stream_offset => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2FsStubViaStreamOffset),
        .fs_stub_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2FsStubViaStream),
        .fs_stub_get_flags => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2FsStubGetFlags),
        .fs_stub_metadata_hash => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2FsStubMetadataHash),
        .sock_instance_network => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, p2InstanceNetwork),
        .sock_create_tcp => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2CreateTcpSocket),
        .sock_tcp_start_bind => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2TcpStartBind),
        .sock_tcp_finish_bind => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpFinishBind),
        .sock_tcp_start_connect => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2TcpStartConnect),
        .sock_tcp_finish_connect => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpFinishConnect),
        .sock_tcp_subscribe => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2TcpSubscribe),
        .sock_tcp_shutdown => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, p2TcpShutdown),
        .sock_tcp_is_listening => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2TcpIsListening),
        .sock_tcp_start_listen => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpStartListen),
        .sock_tcp_finish_listen => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpFinishListen),
        .sock_tcp_accept => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpAccept),
        .sock_tcp_local_address => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpLocalAddress),
        .sock_tcp_remote_address => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpRemoteAddress),
        .sock_tcp_set_backlog => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2TcpSetListenBacklog),
        .sock_tcp_drop => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ResourceDrop),
        .sock_stub_unit2 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2SockStubUnit2),
        .sock_stub_unit3i => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, p2SockStubUnit3i),
        .sock_stub_unit3l => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2SockStubUnit3l),
        .sock_stub_unit15 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2SockStubUnit15),
        .sock_stub_val1 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2SockStubVal1),
        .sock_stub_val4 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2SockStubVal4),
        .sock_stub_val8 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2SockStubVal8),
        .sock_stub_val15_4 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2SockStubVal15_4),
        .sock_stub_resolve => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2SockStubResolve),
        .sock_stub_recv => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2SockStubRecv),
        .sock_stub_send => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2SockStubSend),
        .sock_stub_subscribe => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2SockStubSubscribe),
    }
}

/// The Nth `.core_module` section body in a decoded component.
fn nthCoreModule(decoded: *const decode.Component, n: u32) ?[]const u8 {
    var i: u32 = 0;
    for (decoded.sections.items) |sec| {
        if (sec.id != .core_module) continue;
        if (i == n) return sec.body;
        i += 1;
    }
    return null;
}

/// The (first) `canon lift`'s underlying core-instance export — the lowered
/// `run` the host invokes (resolved through the unified core-func index space).
fn firstLiftCoreExport(info: *const ctypes.TypeInfo) ?ctypes.TypeInfo.CoreExportRef {
    for (info.canons.items) |c| {
        if (c == .lift) return info.resolveCoreFuncExport(c.lift.core_func);
    }
    return null;
}

// ============================================================
// General component instantiation engine (ADR-0175)
// ============================================================
//
// A component's core-instance index space is built in definition order
// (each `.instantiate`'s `with` args reference earlier instances). A guest
// instance is a real `*Instance`; a synthetic (`.inline_exports`) instance is a
// name→`Def` table where `Def` is a host WASI trampoline, a re-exported guest
// func, or a re-exported guest table. This subsumes the hand-authored fixtures
// (main + libc + host-wasi inline_exports) AND real wit-bindgen output (a
// `$shim` guest module exporting `call_indirect` trampolines + a table, the
// memory-needing lowers materialised as host funcs, and a `$fixup` whose active
// `elem` fills the shim table — built like any other instance).

/// What a synthetic instance's export resolves to when poured into an importer.
const Def = union(enum) {
    host_op: adapter.P2Op,
    guest_func: struct { inst: *Instance, name: []const u8 },
    guest_table: struct { inst: *Instance, name: []const u8 },
    /// A synthesized `canon resource.new/drop/rep` builtin for a
    /// GUEST-defined resource (D-322); `type_index` keys the handle table.
    resource_builtin: struct { kind: ResourceBuiltinKind, type_index: u32 },
    /// `canon task.return` (WASI 0.3, ADR-0189 ζ2): the async task's
    /// result-delivery import; the trampoline records the value in
    /// `WasiP2Ctx.task_return`.
    task_return_builtin,
    /// `canon task.return` whose result flattens to >1 core param (e.g. the
    /// http handler's result<own<response>, error-code> = 8): bound via
    /// `defineFuncRaw` with the exact flat signature; the trampoline records
    /// disc + payload.
    task_return_raw: []const zir_mod.ValType,
    /// A `canon stream.*`/`future.*` builtin (WASI 0.3, ADR-0189 ζ2). `op`
    /// selects the trampoline; `type_index` is the stream/future type. Slice 2
    /// wires `stream.new`/`future.new`; the rest are a later slice.
    async_builtin: struct { op: ctypes.StreamFutureOp, type_index: u32, elem_size: u32 = 1 },
    /// A `canon waitable-set.new/join/poll/drop` builtin (WASI 0.3, ADR-0190
    /// E2b + ADR-0205 phase A) on the per-task `WaitableSetTable`. `wait`
    /// stays rejected (stackless: a guest blocks via the callback WAIT return).
    waitable_set_builtin: ctypes.WaitableSetOp,
    /// An ASYNC-lowered host import (`canon lower ... async`, ADR-0205 phase
    /// A): the trampoline returns the packed subtask status. Only ops with a
    /// genuine async host path bind here; the rest are async-EAGER via their
    /// sync trampolines (D5) or rejected until their phase lands.
    host_op_async: adapter.P2Op,
    /// A `canon context.{get,set}` builtin over `WasiP2Ctx.task_context`.
    context_builtin: struct { is_set: bool, slot: ctypes.ContextSlot },
    /// `canon task.cancel` / `subtask.{cancel,drop}` / `thread.yield` (ADR-0205
    /// phase A): linkable; unimplemented ones fail loudly at CALL time.
    async_support_builtin: AsyncSupportOp,
};

const AsyncSupportOp = enum { task_cancel, subtask_cancel, subtask_drop, thread_yield };

/// Per-definition context for a synthesized async builtin (mirrors
/// `ResourceBuiltinCtx`): the heap-stable ctx + the stream/future type index.
const ResourceBuiltinKind = enum { new, drop, rep };

fn isGuestResourceType(info: *const ctypes.TypeInfo, ti: u32) bool {
    if (ti >= info.type_space.items.len) return false;
    return switch (info.type_space.items[ti]) {
        .def => |d| info.deftypes.items[d] == .resource,
        .named => false,
    };
}
/// D-335: lowered byte size of a `stream<T>`/`future<T>`'s element type `T`,
/// for typed multi-byte marshalling. Returns 1 (byte semantics) for a
/// payload-less stream/future, a non-stream `type_index`, or any resolution
/// failure. `arena` (the build's synth_arena) owns any compound CanonType.
fn streamElemByteSize(arena: Allocator, info: *const ctypes.TypeInfo, type_index: u32) u32 {
    const resolved = canon.resolveTypeIndex(arena, info, type_index) catch return 1;
    const payload: ?ctypes.ValType = switch (resolved.dt) {
        .stream => |s| s.payload,
        .future => |f| f.payload,
        else => return 1,
    };
    const p = payload orelse return 1;
    const ct = canon.canonTypeFromDecoded(arena, info, p) catch return 1;
    const sz = canon.sizeOf(ct);
    return if (sz == 0) 1 else @intCast(sz);
}

const SynthExport = struct { name: []const u8, def: Def };
const Built = union(enum) { guest: *Instance, synthetic: []const SynthExport };

/// Resolve one `core:inlineexport` to the `Def` an importer should bind, or
/// null when it is not a host-relevant export (skipped). `built` holds the
/// already-constructed earlier instances (aliases only reference those).
fn synthDef(arena: Allocator, info: *const ctypes.TypeInfo, built: []const ?Built, ex: ctypes.CoreInlineExport) !?Def {
    switch (ex.sort) {
        .func => switch (info.coreFunc(ex.index) orelse return null) {
            .lower => |l| {
                const ref = info.resolveComponentImport(l.func) orelse return null;
                const op = adapter.classifyImport(ref.interface, ref.func, ref.gen) orelse return error.UnsupportedWasiImport;
                if (l.opts.is_async) return .{ .host_op_async = op };
                return .{ .host_op = op };
            },
            .resource_new => |ti| return .{ .resource_builtin = .{ .kind = .new, .type_index = ti } },
            .resource_rep => |ti| return .{ .resource_builtin = .{ .kind = .rep, .type_index = ti } },
            // A drop of a GUEST-defined resource goes through its own handle
            // table (+ dtor); drops of imported host resources keep the
            // generic stream-drop route.
            .resource_drop => |ti| {
                if (isGuestResourceType(info, ti)) return .{ .resource_builtin = .{ .kind = .drop, .type_index = ti } };
                return .{ .host_op = .out_stream_drop };
            },
            // task.return (CM-async) is satisfied by the P3 runner's host
            // builtin (ADR-0189 ζ2); it records the task's delivered result.
            // A result flattening to >1 core param (payload-carrying variants
            // like the http handler's result<own<response>, error-code>)
            // takes the raw-signature route (ADR-0205 D-3).
            .task_return => |tr| {
                if (tr.result) |vt| {
                    var flat_types: std.ArrayList(canon.CoreType) = .empty;
                    const ct = canon.canonTypeFromDecoded(arena, info, vt) catch return .task_return_builtin;
                    canon.flattenType(arena, ct, &flat_types) catch return .task_return_builtin;
                    if (flat_types.items.len > 1) {
                        const params = try arena.alloc(zir_mod.ValType, flat_types.items.len);
                        for (flat_types.items, 0..) |ft, i| params[i] = switch (ft) {
                            .i32 => .i32,
                            .i64 => .i64,
                            .f32 => .f32,
                            .f64 => .f64,
                        };
                        return .{ .task_return_raw = params };
                    }
                }
                return .task_return_builtin;
            },
            // waitable-set.new/join/poll/drop are host-wired (ADR-0190 E2b +
            // ADR-0205 phase A); `wait` is the stackful path (zwasm stackless
            // re-enters via the callback WAIT return, not a guest wait call).
            .waitable_set => |ws| switch (ws.op) {
                .new, .join, .poll, .drop => return .{ .waitable_set_builtin = ws.op },
                .wait => return error.UnsupportedWasiImport,
            },
            .task_cancel => return .{ .async_support_builtin = .task_cancel },
            .subtask_cancel => return .{ .async_support_builtin = .subtask_cancel },
            .subtask_drop => return .{ .async_support_builtin = .subtask_drop },
            .context_get => |cg| return .{ .context_builtin = .{ .is_set = false, .slot = cg } },
            .context_set => |cs| return .{ .context_builtin = .{ .is_set = true, .slot = cs } },
            .thread_yield => return .{ .async_support_builtin = .thread_yield },
            // stream.new/future.new are wired (ADR-0189 ζ2 Slice 2); the rest of
            // the stream/future builtins (read/write/cancel/drop) land in a later
            // slice — fail loudly rather than silently mis-bind until then.
            // all stream/future builtins are now host-satisfied (ADR-0189 ζ2);
            // a guest-to-guest read/write COMPLETION still needs a peer (Unit E).
            // D-335: `type_index` is the `stream<T>`/`future<T>` TYPE; resolve
            // its payload T's lowered byte size for typed multi-byte marshalling
            // (default 1 = payload-less / u8 / unresolvable).
            .stream_future => |sf| return .{ .async_builtin = .{ .op = sf.op, .type_index = sf.type_index, .elem_size = streamElemByteSize(arena, info, sf.type_index) } },
            .alias => |t| switch (t) {
                .core_export => |ce| {
                    const prov = built[ce.instance] orelse return error.ImportUnsatisfied;
                    switch (prov) {
                        .guest => |gi| return .{ .guest_func = .{ .inst = gi, .name = ce.name } },
                        .synthetic => |se| {
                            for (se) |e| if (std.mem.eql(u8, e.name, ce.name)) return e.def;
                            return null;
                        },
                    }
                },
                else => return null,
            },
        },
        .table => {
            const ref = info.resolveCoreTableExport(ex.index) orelse return null;
            const prov = built[ref.instance] orelse return error.ImportUnsatisfied;
            return switch (prov) {
                .guest => |gi| .{ .guest_table = .{ .inst = gi, .name = ref.name } },
                .synthetic => null,
            };
        },
        else => return null, // memory/global inline exports: not yet needed
    }
}

/// `canon resource.new` for a guest-defined resource: store the rep, mint
/// an OWN handle in the component's guest table.
/// Pour one synthetic export into `lk` under namespace `ns` as import `e.name`.
fn defineSynth(lk: *Linker, ns: []const u8, e: SynthExport, ctx: *WasiP2Ctx) !void {
    switch (e.def) {
        .host_op => |op| try defineClassifiedFunc(lk, ns, e.name, op, ctx),
        .resource_builtin => |rb| {
            const rbc = try ctx.alloc.create(ResourceBuiltinCtx);
            errdefer ctx.alloc.destroy(rbc);
            rbc.* = .{ .ctx = ctx, .type_index = rb.type_index };
            try ctx.rb_ctxs.append(ctx.alloc, rbc);
            switch (rb.kind) {
                .new => try lk.defineFuncCtx(ns, e.name, @ptrCast(rbc), fn (*Caller, u32) WasiP2Error!u32, p2GuestResourceNew),
                .drop => try lk.defineFuncCtx(ns, e.name, @ptrCast(rbc), fn (*Caller, u32) WasiP2Error!void, p2GuestResourceDrop),
                .rep => try lk.defineFuncCtx(ns, e.name, @ptrCast(rbc), fn (*Caller, u32) WasiP2Error!u32, p2GuestResourceRep),
            }
        },
        .task_return_builtin => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, i32) WasiP2Error!void, p2TaskReturn),
        .task_return_raw => |params| try lk.defineFuncRaw(ns, e.name, @ptrCast(ctx), params, &.{}, p2TaskReturnRaw),
        .waitable_set_builtin => |op| switch (op) {
            .new => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller) WasiP2Error!u32, p2WaitableSetNew),
            .join => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2WaitableJoin),
            .poll => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, u32, u32) WasiP2Error!u32, p2WaitableSetPoll),
            .drop => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, u32) WasiP2Error!void, p2WaitableSetDrop),
            .wait => unreachable, // synthDef rejects it
        },
        .host_op_async => |op| try p3h.defineAsyncLoweredOp(lk, ns, e.name, op, ctx),
        .context_builtin => |cb| {
            if (cb.slot.slot >= 2) return error.UnsupportedWasiImport; // spec ContextLocalStorage bound
            const cbc = try ctx.alloc.create(ContextBuiltinCtx);
            errdefer ctx.alloc.destroy(cbc);
            cbc.* = .{ .ctx = ctx, .slot = cb.slot.slot };
            try ctx.cb_ctxs.append(ctx.alloc, cbc);
            if (cb.is_set) {
                if (cb.slot.is_i64) {
                    try lk.defineFuncCtx(ns, e.name, @ptrCast(cbc), fn (*Caller, i64) WasiP2Error!void, p2ContextSet64);
                } else {
                    try lk.defineFuncCtx(ns, e.name, @ptrCast(cbc), fn (*Caller, u32) WasiP2Error!void, p2ContextSet32);
                }
            } else {
                if (cb.slot.is_i64) {
                    try lk.defineFuncCtx(ns, e.name, @ptrCast(cbc), fn (*Caller) WasiP2Error!i64, p2ContextGet64);
                } else {
                    try lk.defineFuncCtx(ns, e.name, @ptrCast(cbc), fn (*Caller) WasiP2Error!u32, p2ContextGet32);
                }
            }
        },
        .async_support_builtin => |op| switch (op) {
            .task_cancel => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller) WasiP2Error!void, p2TaskCancel),
            .subtask_cancel => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2SubtaskCancel),
            .subtask_drop => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, u32) WasiP2Error!void, p2SubtaskDrop),
            .thread_yield => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller) WasiP2Error!u32, p2ThreadYield),
        },
        .async_builtin => |ab| {
            const abc = try ctx.alloc.create(AsyncBuiltinCtx);
            errdefer ctx.alloc.destroy(abc);
            abc.* = .{ .ctx = ctx, .type_index = ab.type_index, .elem_size = ab.elem_size };
            try ctx.ab_ctxs.append(ctx.alloc, abc);
            switch (ab.op) {
                .stream_new => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller) WasiP2Error!u64, p2StreamNew),
                .future_new => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller) WasiP2Error!u64, p2FutureNew),
                .stream_drop_readable, .stream_drop_writable, .future_drop_readable, .future_drop_writable => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller, u32) WasiP2Error!void, p2StreamFutureDrop),
                .stream_read, .stream_write => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller, u32, u32, u32) WasiP2Error!u32, p2StreamFutureCopy),
                // future.{read,write} core ABI is (handle, ptr) — no count (a
                // future carries exactly one value; CanonicalABI `future_copy`).
                .future_read, .future_write => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller, u32, u32) WasiP2Error!u32, p2FutureCopy),
                .stream_cancel_read, .stream_cancel_write, .future_cancel_read, .future_cancel_write => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller, u32) WasiP2Error!u32, p2StreamFutureCancel),
            }
        },
        .guest_func => |g| try lk.defineCrossModuleFunc(ns, e.name, g.inst, g.name),
        .guest_table => |g| {
            const rt = g.inst.handle.runtime orelse return error.ImportUnsatisfied;
            for (g.inst.handle.exports_storage) |exp| {
                if (exp.kind == .table and std.mem.eql(u8, exp.name, g.name)) {
                    try lk.defineTable(ns, e.name, rt.tables[exp.idx]);
                    return;
                }
            }
            return error.ImportUnsatisfied;
        },
    }
}

/// A fully-BUILT component instance graph (ADR-0175) with its WASI-P2 host
/// wiring intact — the reusable seam under `runWasiP2Main` and the typed
/// embedder invoke (ADR-0183 F3: real-toolchain components import wasi, so
/// typed calls need the same build the CLI run uses).
/// REQ-5 — the failure set of `BuiltComponent.dropResource`: the resource
/// table's own errors (stale handle / still-borrowed) plus a guest
/// destructor trap.
pub const DropResourceError = resource_table.Error || error{DestructorTrapped};

pub const BuiltComponent = struct {
    alloc: Allocator,
    /// Owned copy of the component bytes — `decoded`, its `info` names, and the
    /// core `modules` slice it, so the build is self-contained vs the caller's
    /// load buffer (REQ-7 / D-326).
    owned_bytes: []const u8,
    decoded: decode.Component,
    info: ctypes.TypeInfo,
    /// Heap-stable: trampolines hold this pointer for the build's lifetime.
    ctx: *WasiP2Ctx,
    modules: std.ArrayList(*Module) = .empty,
    instances: std.ArrayList(*Instance) = .empty,
    linkers: std.ArrayList(*Linker) = .empty,
    synth_arena: std.heap.ArenaAllocator,
    built: []?Built,

    pub fn deinit(self: *BuiltComponent) void {
        const alloc = self.alloc;
        for (self.instances.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        for (self.linkers.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        for (self.modules.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        self.instances.deinit(alloc);
        self.linkers.deinit(alloc);
        self.modules.deinit(alloc);
        alloc.free(self.built);
        self.synth_arena.deinit();
        self.ctx.deinit();
        alloc.destroy(self.ctx);
        self.info.deinit();
        self.decoded.deinit(alloc);
        alloc.free(self.owned_bytes);
    }

    /// REQ-3 (cw CM-API) — introspect a func export's full typed signature
    /// to the `WitType` tree (specialization-preserving + labels). `arena`
    /// owns the tree; names borrow from this build's `TypeInfo`. Mirrors
    /// `ComponentInstance.resolveFuncSig` for the WASI-P2 graph path.
    pub fn resolveFuncSig(self: *const BuiltComponent, arena: Allocator, name: []const u8) wit_type.Error!?wit_type.FuncSig {
        return wit_type.resolveFuncSig(arena, &self.info, name);
    }

    /// REQ-5 (cw CM-API) — host-facing drop of a guest-defined resource
    /// `handle` (typically an `own` handle a host cached from a constructor
    /// result and frees in a finaliser). Removes it from the guest resource
    /// table and, for an `own` handle, runs the resource's declared
    /// destructor over its rep — the same effect as the guest calling
    /// `canon resource.drop`, but driven from the host without knowing the
    /// resource type (the table's stored `rt` selects the destructor).
    /// Traps on a stale/double-drop or a still-borrowed owning handle.
    pub fn dropResource(self: *BuiltComponent, handle: u32) DropResourceError!void {
        const removed = try self.ctx.guest_resources.dropAny(handle);
        if (removed) |h| {
            for (self.ctx.guest_dtors.items) |gd| {
                if (gd.type_index != h.rt) continue;
                var args = [_]Value{.{ .i32 = @bitCast(h.rep) }};
                gd.inst.invoke(gd.name, &args, &.{}) catch return DropResourceError.DestructorTrapped;
                break;
            }
        }
    }

    /// The guest `*Instance` a core-instance index resolved to (null for
    /// synthetic instances / out of range).
    pub fn guestInstance(self: *const BuiltComponent, index: u32) ?*Instance {
        if (index >= self.built.len) return null;
        const b = self.built[index] orelse return null;
        return switch (b) {
            .guest => |gi| gi,
            .synthetic => null,
        };
    }
};

/// Decode + validate + build EVERY core instance of `bytes` in definition
/// order with the WASI-P2 host wiring (the ADR-0175 general engine,
/// extracted from `runWasiP2Main`). Caller owns the result (`deinit`).
/// `opts` is the per-instance budget applied to every guest instance
/// (REQ-4, cw CM-API); pass `.{}` for the default budget.
pub fn buildWasiP2Component(engine: *Engine, alloc: Allocator, bytes: []const u8, host: *wasi_host.Host, opts: Module.InstantiateOpts) anyerror!BuiltComponent {
    // Own the bytes so the build is self-contained (REQ-7 / D-326).
    const owned_bytes = try alloc.dupe(u8, bytes);
    errdefer alloc.free(owned_bytes);

    var decoded = try decode.decode(alloc, owned_bytes);
    errdefer decoded.deinit(alloc);
    var info = try ctypes.decodeTypeInfo(alloc, &decoded);
    errdefer info.deinit();
    try cvalidate.validate(&info); // ADR-0176: reject invalid components pre-instantiate

    const cis = info.core_instances.items;

    const ctx = try alloc.create(WasiP2Ctx);
    errdefer alloc.destroy(ctx);
    ctx.* = try WasiP2Ctx.init(alloc, host);
    errdefer ctx.deinit();
    // ADR-0207: the P3 hook table installs at ctx creation (init itself must
    // not name P3 symbols — the substrate imports no sibling).
    p3h.installP3Hooks(ctx);

    var self: BuiltComponent = .{
        .alloc = alloc,
        .owned_bytes = owned_bytes,
        .decoded = decoded,
        .info = info,
        .ctx = ctx,
        .synth_arena = std.heap.ArenaAllocator.init(alloc),
        .built = try alloc.alloc(?Built, cis.len),
    };
    @memset(self.built, null);
    errdefer {
        // Tear down only what THIS fn built; decoded/info/ctx have their own
        // errdefers above (self.deinit would double-free them on early error).
        for (self.instances.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        for (self.linkers.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        for (self.modules.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        self.instances.deinit(alloc);
        self.linkers.deinit(alloc);
        self.modules.deinit(alloc);
        alloc.free(self.built);
        self.synth_arena.deinit();
    }

    for (cis, 0..) |ci, i| {
        self.built[i] = switch (ci) {
            .inline_exports => |exps| blk: {
                const list = try self.synth_arena.allocator().alloc(SynthExport, exps.len);
                var n: usize = 0;
                for (exps) |ex| {
                    const def = (try synthDef(self.synth_arena.allocator(), &self.info, self.built, ex)) orelse continue;
                    list[n] = .{ .name = ex.name, .def = def };
                    n += 1;
                }
                break :blk .{ .synthetic = list[0..n] };
            },
            .instantiate => |it| blk: {
                const mb = nthCoreModule(&self.decoded, it.module) orelse return error.NoCoreModule;
                const mod = try alloc.create(Module);
                mod.* = try engine.compile(mb);
                try self.modules.append(alloc, mod);

                const lk = try alloc.create(Linker);
                lk.* = engine.linker();
                try self.linkers.append(alloc, lk);

                // Pour each `with` argument's instance into the linker under
                // its namespace, satisfying this module's imports.
                for (it.args) |arg| {
                    if (arg.instance >= cis.len) return error.ImportUnsatisfied;
                    const provider = self.built[arg.instance] orelse return error.ImportUnsatisfied;
                    switch (provider) {
                        .guest => |gi| try lk.defineInstance(arg.name, gi),
                        .synthetic => |se| for (se) |e| try defineSynth(lk, arg.name, e, ctx),
                    }
                }

                const gi = try alloc.create(Instance);
                gi.* = try lk.instantiate(mod, opts);
                try self.instances.append(alloc, gi);
                // The instance exporting cabi_realloc is the list/string
                // return-area allocator the trampolines call via nested
                // invoke; the memory-exporting instance is the lowers' bound
                // memory.
                if (ctx.realloc_instance == null and instanceExportsFunc(gi, ctx.realloc_name))
                    ctx.realloc_instance = gi;
                if (ctx.mem_instance == null and instanceExportsMemory(gi))
                    ctx.mem_instance = gi;
                break :blk .{ .guest = gi };
            },
        };
    }

    // Resolve guest-resource destructors (D-322): a resource deftype's
    // `dtor` is a core-func index — chase it to the exporting guest
    // instance so `canon resource.drop` can run it on own-handle drops.
    for (info.type_space.items, 0..) |entry, ti| {
        const d = switch (entry) {
            .def => |d| d,
            .named => continue,
        };
        const rt = switch (info.deftypes.items[d]) {
            .resource => |r| r,
            else => continue,
        };
        const dtor_idx = rt.dtor orelse continue;
        const cf = info.coreFunc(dtor_idx) orelse continue;
        switch (cf) {
            .alias => |t| switch (t) {
                .core_export => |ce| {
                    const prov = self.built[ce.instance] orelse continue;
                    switch (prov) {
                        .guest => |gi| try ctx.guest_dtors.append(alloc, .{
                            .type_index = @intCast(ti),
                            .inst = gi,
                            .name = ce.name,
                        }),
                        .synthetic => {},
                    }
                },
                else => {},
            },
            else => {},
        }
    }
    return self;
}

pub fn runWasiP2Main(engine: *Engine, alloc: Allocator, bytes: []const u8, host: *wasi_host.Host, opts: Module.InstantiateOpts) anyerror!void {
    var built = try buildWasiP2Component(engine, alloc, bytes, host, opts);
    defer built.deinit();
    try runWasiP2MainBuilt(&built);
}

/// The post-build half of `runWasiP2Main` (the sync `wasi:cli/run` path):
/// invoke the first `canon lift` export. Split out so the unified
/// `runWasiMain` dispatcher (P3) can reuse it after building once.
pub fn runWasiP2MainBuilt(built: *BuiltComponent) anyerror!void {
    const run_ref = firstLiftCoreExport(&built.info) orelse return error.NoRunExport;
    const main_inst = built.guestInstance(run_ref.instance) orelse return error.NoRunExport;
    var results = [_]Value{.{ .i32 = 0 }};
    main_inst.invoke(run_ref.name, &.{}, &results) catch |err| {
        // wasi:cli/exit unwinds with ProcExit after recording host.exit_code —
        // a clean termination, not a failure.
        if (err == error.ProcExit) return;
        return err;
    };
    // `run: func() -> result` — an `err` return (flat discriminant 1) is exit
    // code 1 per the wasi:cli command contract (official run-with-err.wasm).
    if (results[0].i32 != 0 and built.ctx.host.exit_code == null) built.ctx.host.exit_code = 1;
}

/// The unified WASI-component entry (D-335 Unit F): build once, then dispatch —
/// an **async-lifted** export (a `canon lift` with `opts.is_async`) goes through
/// the P3 stackless callback loop, else the sync `wasi:cli/run` path. This is
/// the surface the CLI / embedders call so an async P3 component "just runs".
///
/// ADR-0193 P3: the async branch is `comptime build_options.enable_wasi_p3`-gated
/// (relocated here from `component_wasi_p3.zig` so a `wasi_level < .p3` build
/// never references the P3 driver — `component_wasi_p3.zig` is then unimported).
/// At a p2 build an async component falls through to the sync runner, which
/// surfaces `NoRunExport` if it has no sync `wasi:cli/run` export.
pub fn runWasiMain(engine: *Engine, alloc: Allocator, bytes: []const u8, host: *wasi_host.Host, opts: Module.InstantiateOpts) anyerror!void {
    var built = try buildWasiP2Component(engine, alloc, bytes, host, opts);
    defer built.deinit();
    if (comptime build_options.enable_wasi_p3) {
        const cwasi3 = @import("component_wasi_p3.zig");
        for (built.info.canons.items) |c| {
            if (c == .lift and c.lift.opts.is_async) return cwasi3.driveAsyncMain(&built);
        }
    }
    return runWasiP2MainBuilt(&built);
}
