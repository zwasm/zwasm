// FILE-SIZE-EXEMPT: the ADR-0207 (a) substrate — WasiP2Ctx + tables + poll/park/deliver + host-stream engine form one state machine over shared tables; ADR-0207 M4 measured the three-way split outcome and further extraction has no positive ADR-0099 condition (investigated 2026-08-12).
//! WASI **Preview 2** host trampolines + the single-component WASI-P2 runner
//! (CM campaign Phase D). Extracted from `component.zig` (D-309): the
//! Component-Model orchestration there crossed the file-size smell cap as the
//! WASI-P2 surface grew (stdio / clocks / random / exit / filesystem / poll).
//!
//! These satisfy a P2 component's canon-lowered `wasi:*` core imports by
//! name-mapping (`wasi/adapter.zig`) onto the existing Preview-1 impl
//! (`wasi/fd.zig` etc.), reusing it wholesale. Registered via
//! `Linker.defineFuncCtx` so each `*Caller` reaches both guest memory and the
//! per-run `WasiP2Ctx`. Zone 3 (touches `invoke`). A handful of `p2*` helpers
//! are `pub` solely for the in-tree e2e/unit tests that live in `component.zig`.

const std = @import("std");
const dbg = @import("../support/dbg.zig");

const wasi_host = @import("../wasi/host.zig");
const wasi_fd = @import("../wasi/fd.zig");
const wasi_path = @import("../wasi/path.zig");
const wasi_clocks = @import("../wasi/clocks.zig");
const wasi_p1 = @import("../wasi/preview1.zig");
const p2sock = @import("../wasi/p2_sockets.zig");
const p3http = @import("../wasi/p3_http.zig");
const resource_table = @import("../feature/component/resource_table.zig");
const async_mod = @import("../feature/component/async.zig");
const Caller = @import("../zwasm/caller.zig").Caller;

const Allocator = std.mem.Allocator;
const Engine = @import("../zwasm/engine.zig").Engine;
const Module = @import("../zwasm/module.zig").Module;
const Instance = @import("../zwasm/instance.zig").Instance;
const Linker = @import("../zwasm/linker.zig").Linker;
const Value = @import("../zwasm.zig").Value;
const rt_value = @import("../runtime/value.zig");

// ============================================================
// WASI Preview 2 host trampolines (CM campaign chunk D1-2)
// ============================================================
//
// A P2 component's canon-lowered core module imports flat core funcs for the
// WASI interfaces it uses (e.g. `io.get-stdout`, `io.write`, `io.drop-os`).
// These host trampolines satisfy those imports by name-mapping (per
// `wasi/adapter.zig`) onto the EXISTING Preview 1 impl (`wasi/fd.zig`),
// reusing it wholesale. They are registered via `Linker.defineFuncCtx` so the
// `*Caller` reaches both the guest memory and this per-run host context.

/// Per-run host context for the WASI-P2 → P1 trampolines. `get-stdout` mints
/// an output-stream handle in `streams` whose `rep` is the P1 fd it is bound to
/// (1 = stdout); `write` forwards the flat `list<u8>` to `wasi/fd.zig
/// writeSlice` on that fd; `drop-os` drops the handle. Threaded into each
/// trampoline via `Caller.data`.
/// A guest `stream.read` parked at a host source (ADR-0191 E2c): the destination
/// buffer the delivered bytes are copied into when the source becomes ready.
pub const PendingRead = struct { ptr: u32, cap: u32, elem_size: u32 = 1 };
pub const PendingWrite = struct { ptr: u32, count: u32, elem_size: u32 = 1 };
/// A socket read (accept / tcp-rx) that returned BLOCKED: the tcp socket rep
/// plus the parked destination span, executed at readiness by
/// `pollBlockedSockets` (the socket analogue of `PendingRead`).
pub const ParkedSockRead = struct { rep: u32, ptr: u32, cap: u32, elem_size: u32 = 1 };
/// A `tcp.send` sink: the tcp socket rep + the send's result-future handle,
/// so a drain failure (peer reset / shutdown) flips the future to err before
/// the guest awaits it (official sockets-tcp-receive test_drop_read_half).
pub const TcpTxRole = struct { rep: u32, fut: u32 };
/// A parked `udp.receive` subtask: the udp socket rep + the async call's
/// retptr, completed (recvfrom + marshal + SUBTASK event) at readiness by
/// `pollBlockedUdpReceives` — the timer-subtask pattern (ADR-0205 D2).
pub const ParkedUdpReceive = struct { rep: u32, retptr: u32 };
/// Harness-supplied request-body bytes served to guest stream reads.
pub const HostBodyBytes = struct { data: []u8, pos: usize = 0 };
/// A parked `wasi:http/client.send` (ADR-0205 D-5): the request rep, the
/// async call's retptr, its subtask waitable, and the request body being
/// collected via a capture sink. The blocking HTTP exchange runs once the
/// guest closes its body stream (`pollPendingClientSends`). Heap-allocated
/// — the capture sink holds a pointer to `body`.
pub const PendingClientSend = struct {
    req_rep: u32,
    retptr: u32,
    subtask: u32,
    body: std.ArrayList(u8) = .empty,
    body_shared: ?u32 = null,
};

pub const WasiP2Ctx = struct {
    host: *wasi_host.Host,
    /// One handle table keyed by resource-type id; each P2 resource the host
    /// models gets a distinct id (output-stream rep = P1 fd, descriptor rep = P1 fd).
    resources: resource_table.ResourceTable,
    /// GUEST-defined resources (D-322): handles minted by the component's
    /// own `canon resource.new/drop/rep` builtins. SEPARATE from the host
    /// `resources` table — its rt ids are the component's TYPE-SPACE
    /// indices, which would collide with the hardcoded host RT ids.
    guest_resources: resource_table.ResourceTable,
    /// Per-definition contexts for the synthesized resource builtins.
    rb_ctxs: std.ArrayList(*ResourceBuiltinCtx) = .empty,
    /// Resolved guest-resource destructors (type-space index -> core func).
    guest_dtors: std.ArrayList(GuestDtor) = .empty,
    /// Instance exporting `cabi_realloc` (set AFTER instantiation) — lets a
    /// trampoline allocate guest memory for list/string results (e.g.
    /// `get-directories`) via a nested invoke. See lesson
    /// `2026-06-07-engine-invoke-is-reentrant-stack-disciplined`.
    realloc_instance: ?*Instance = null,
    realloc_name: []const u8 = "cabi_realloc",
    /// Instance whose linear memory the lowered funcs read/write — the
    /// canon-lower-bound memory (the memory-exporting instance: `$main`, or
    /// `$libc` in the hand-authored fixtures). NOT the immediate caller's: a
    /// lower reached via wit-bindgen's shim `call_indirect` has the memory-less
    /// shim as caller, so trampolines must source memory from here (D-310).
    mem_instance: ?*Instance = null,
    /// Allocator backing `dir_streams` (the per-run cursor state below).
    alloc: Allocator,
    /// Live directory-entry-stream cursors; a DIR_STREAM_RT handle's rep
    /// indexes this list.
    dir_streams: std.ArrayList(DirStream) = .empty,
    /// Live tcp sockets (ADR-0180); a TCP_SOCKET_RT / SOCK_*_STREAM_RT /
    /// SOCK_POLLABLE_RT handle's rep (low bits) indexes this list.
    tcp_sockets: std.ArrayList(p2sock.TcpSocket) = .empty,
    /// CM-async (WASI 0.3, ADR-0189 ζ2): the value the async task delivered via
    /// `canon task.return` — surfaced to the P3 runner after the callback loop
    /// exits. Minimal single-`i32`-lowered-result form; typed/multi-value is a
    /// later ζ2 slice. `null` until the guest calls `task.return`.
    task_return: ?u32 = null,
    /// The ok-payload slot of a raw task.return (e.g. the response handle
    /// the http handler delivered); valid when `task_return == 0`.
    task_return_payload: ?u32 = null,
    /// CM-async per-task state (ADR-0189 ζ2): the stream/future end handle table,
    /// the shared-rendezvous arena, and the waitable-set table. Lives here (not
    /// in the P3 runner's frame) so the canon async builtins reach it via
    /// `Caller.data`. Empty for a P2 component (P2 mints no async builtins).
    streams: async_mod.StreamFutureTable,
    shared: async_mod.SharedTable,
    sets: async_mod.WaitableSetTable,
    /// Per-definition contexts for the synthesized async builtins.
    ab_ctxs: std.ArrayList(*AsyncBuiltinCtx) = .empty,
    /// Per-definition contexts for the `canon context.{get,set}` builtins.
    cb_ctxs: std.ArrayList(*ContextBuiltinCtx) = .empty,
    /// WASI 0.3 host stream peers (ADR-0190): a `SharedStream` handle whose
    /// readable end the host drains → the P1 fd it sinks to. A guest
    /// `stream.write` to such a stream COMPLETES immediately (stdout/stderr are
    /// always write-ready), the bytes marshalled to `fd`.
    host_sinks: std.AutoHashMapUnmanaged(u32, wasi_p1.Fd) = .empty,
    /// WASI 0.3 host stream SOURCES (ADR-0190, the read direction): a
    /// `SharedStream` handle whose readable end the guest reads → the P1 fd the
    /// host supplies bytes from (stdin). A guest `stream.read` pulls available
    /// bytes from `fd` into guest memory.
    host_sources: std.AutoHashMapUnmanaged(u32, wasi_p1.Fd) = .empty,
    /// WAIT-path (ADR-0191 E2c): a guest `stream.read` on a host source that is
    /// not yet ready PARKS — the read request is recorded here (keyed by the
    /// readable end handle = the waitable a set joins) and delivered at `waitOn`
    /// time. `defer_host_source_reads` forces the park branch (host policy:
    /// "source not ready yet"); default off = E3's deliver-immediately.
    pending_reads: std.AutoHashMapUnmanaged(u32, PendingRead) = .empty,
    defer_host_source_reads: bool = false,
    /// WASI 0.3 (ADR-0190/ADR-0205): the readable end of a
    /// `future<result<_,error-code>>` that a `*-via-stream` func returned,
    /// mapped to its outcome — null = ok (the peer succeeded / is still
    /// clean), else the 0.3 `error-code` ordinal a failed file stream
    /// recorded. A guest `future.read` COMPLETES immediately either way.
    host_result_futures: std.AutoHashMapUnmanaged(u32, ?u8) = .empty,
    /// `insecure-seed`'s cached 128-bit value — a moral value import: every
    /// call must observe the same seed (official random.wasm asserts it).
    insecure_seed: ?[2]u64 = null,
    /// WASI-0.3 filesystem via-stream roles (ADR-0205 phase B): a stream whose
    /// peer is a host FILE at a tracked byte position — `read-via-stream`
    /// (guest reads → host preads + advances) and `write/append-via-stream`
    /// (guest writes → host pwrites + advances). Keyed by the stream's SHARED
    /// id (like `host_sinks`); scrubbed on last-end drop.
    host_file_streams: std.AutoHashMapUnmanaged(u32, FileStreamRole) = .empty,
    /// WASI-0.3 `read-directory` stream roles: shared id → index into
    /// `dir_streams` (the same P1 readdir cursor the 0.2 entry-stream uses).
    host_dir_streams: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// A guest `stream.write` that BLOCKED (no peer yet): the source span it
    /// offered, keyed by the writable end handle — a host role registered
    /// AFTERWARDS (`write-via-stream(data, ...)` arrives while `write_all` is
    /// already parked under `futures::join!`) drains it at registration.
    pending_writes: std.AutoHashMapUnmanaged(u32, PendingWrite) = .empty,
    /// WASI-0.3 sockets (ADR-0205 phase C): live UDP sockets (a
    /// UDP_SOCKET3_RT handle's rep indexes this list) + the socket stream
    /// roles, all keyed by the stream's SHARED id like the file roles:
    /// `host_accept_streams` (listen → stream<tcp-socket>), `host_tcp_rx`
    /// (receive → stream<u8>), `host_tcp_tx` (send's drained data stream).
    /// Values = the tcp socket list index (rep).
    udp_sockets: std.ArrayList(p2sock.UdpSocket) = .empty,
    /// WASI-0.3 `wasi:http/types` `fields` resources (ADR-0205 phase D);
    /// a HTTP_FIELDS_RT handle's rep indexes this list. Dropped entries are
    /// deinit'ed in place (slot stays; reps are never reused).
    http_fields: std.ArrayList(p3http.HttpFields) = .empty,
    http_requests: std.ArrayList(p3http.HttpRequest) = .empty,
    http_responses: std.ArrayList(p3http.HttpResponse) = .empty,
    http_reqopts: std.ArrayList(p3http.HttpRequestOptions) = .empty,
    /// Host-resolved trailers futures (keyed by READABLE handle): a guest
    /// read completes immediately with `ok(none)` — the shape a
    /// harness-built request's `consume-body` hands out (ADR-0205 D-3).
    host_trailer_ok_futures: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Harness-supplied request-body bytes (keyed by the stream's SHARED
    /// id): a guest read drains from the buffer, then observes DROPPED.
    host_body_bytes: std.AutoHashMapUnmanaged(u32, HostBodyBytes) = .empty,
    /// Harness capture sinks (keyed by SHARED id): a guest WRITE into the
    /// stream appends to the harness's buffer and completes — how the
    /// harness collects a response body without a host-side stream reader.
    host_capture_sinks: std.AutoHashMapUnmanaged(u32, *std.ArrayList(u8)) = .empty,
    /// Parked `client.send` calls awaiting their request body (ADR-0205
    /// D-5); resolved by `pollPendingClientSends`.
    pending_client_sends: std.ArrayList(*PendingClientSend) = .empty,
    host_accept_streams: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    host_tcp_rx: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    host_tcp_tx: std.AutoHashMapUnmanaged(u32, TcpTxRole) = .empty,
    /// Socket-read stream ends (accept / rx) that returned BLOCKED and now
    /// await socket readiness — the scheduler's no-progress hook polls them
    /// (mirrors the D2 timer path) and EXECUTES the parked read. Key = the
    /// readable end HANDLE (the waitable a set joins).
    blocked_socket_reads: std.AutoHashMapUnmanaged(u32, ParkedSockRead) = .empty,
    /// Parked `udp.receive` subtasks awaiting datagram readiness, keyed by
    /// the subtask waitable handle.
    blocked_udp_receives: std.AutoHashMapUnmanaged(u32, ParkedUdpReceive) = .empty,
    /// Optional external-actor seam (official sockets-echo: the conformance
    /// harness plays the REMOTE CLIENT — connect / send — while the guest
    /// is parked): called at the scheduler's no-progress point; returns
    /// true if it performed an action (the scheduler retries).
    external_sock_step: ?*const fn (*anyopaque) bool = null,
    external_sock_ctx: ?*anyopaque = null,
    /// WASI-0.3 `open-at`'s REQUESTED `descriptor-flags` per descriptor
    /// handle — `get-flags` reflects the request (official
    /// filesystem-flags-and-type.wasm: an empty-flags open reads back READ
    /// alone), not the host's actual open mode.
    descriptor_open_flags: std.AutoHashMapUnmanaged(u32, u8) = .empty,
    /// CM-async `canon context.{get,set}` task-local storage (ADR-0205 phase A;
    /// spec `ContextLocalStorage`). One pair per TASK — valid while every
    /// runner keeps ≤ 1 live task per ctx (the single-component runner seeds
    /// exactly one; the graph runner gives each child component its own ctx).
    /// When a runner ever multiplexes tasks over one ctx, this moves into
    /// `TaskDescriptor`.
    task_context: [2]u64 = .{ 0, 0 },
    /// Substrate→P3 fn-pointer set (ADR-0207); see `P3Hooks` below.
    p3_hooks: ?P3Hooks = null,

    /// Resource-type ids for the P2 resources the host models (`pub` for the
    /// in-tree tests that mint handles directly).
    pub const OUTPUT_STREAM_RT: u32 = 1;
    pub const DESCRIPTOR_RT: u32 = 2;
    pub const INPUT_STREAM_RT: u32 = 3;
    /// A `wasi:io/poll` pollable. Its rep is NOT a P1 fd (it carries no host
    /// resource for a synchronous always-ready host), so the generic drop must
    /// NOT `fd_close` it — see `p2ResourceDrop`.
    pub const POLLABLE_RT: u32 = 4;
    /// A `wasi:filesystem/types` directory-entry-stream. Its rep is an index
    /// into `dir_streams` (NOT a P1 fd — the stream shares the minting
    /// descriptor's fd, which the descriptor handle owns), so the generic drop
    /// must NOT `fd_close` it either.
    pub const DIR_STREAM_RT: u32 = 5;
    /// wasi:sockets (ADR-0180): a tcp-socket. Rep indexes `tcp_sockets`
    /// (NOT a P1 fd); its drop closes the OS socket via TcpSocket.deinit.
    pub const TCP_SOCKET_RT: u32 = 6;
    /// The `wasi:sockets/network` singleton (ambient network; rep unused).
    pub const NETWORK_RT: u32 = 7;
    /// Socket-backed input/output-streams minted by finish-connect. Rep
    /// indexes `tcp_sockets`; dropping a stream does NOT close the socket
    /// (the tcp-socket handle owns it).
    pub const SOCK_INPUT_STREAM_RT: u32 = 8;
    pub const SOCK_OUTPUT_STREAM_RT: u32 = 9;
    /// A socket-backed pollable (REAL readiness per ADR-0180). Rep packs
    /// `tcp_sockets` index (low 24 bits) | interest tag (high bits:
    /// 1 = read, 2 = write, 3 = either).
    pub const SOCK_POLLABLE_RT: u32 = 10;
    /// WASI-0.3 `udp-socket` (rep = index into `udp_sockets`).
    pub const UDP_SOCKET3_RT: u32 = 11;
    /// WASI-0.3 `wasi:http/types` `fields` (rep = index into `http_fields`;
    /// drop frees the entry's pair storage — no OS handle).
    pub const HTTP_FIELDS_RT: u32 = 12;
    /// A BORROWED view onto a fields rep (minted by `request.get-headers` /
    /// `response.get-headers`): drop releases only the handle — the parent
    /// request/response owns the storage.
    pub const HTTP_FIELDS_VIEW_RT: u32 = 13;
    /// `request` (rep = index into `http_requests`).
    pub const HTTP_REQUEST_RT: u32 = 14;
    /// `response` (rep = index into `http_responses`).
    pub const HTTP_RESPONSE_RT: u32 = 15;
    /// `request-options` (rep = index into `http_reqopts`; plain values, no
    /// heap) and its borrowed view (`request.get-options`).
    pub const HTTP_REQOPTS_RT: u32 = 16;
    pub const HTTP_REQOPTS_VIEW_RT: u32 = 17;

    /// Iteration state of one live directory-entry-stream: the directory's
    /// P1 fd + the P1 readdir cookie to resume after.
    pub const DirStream = struct { fd: wasi_p1.Fd, cookie: u64 };

    /// A WASI-0.3 file via-stream peer: the P1 fd + the tracked byte position
    /// the next pread/pwrite uses (advanced per completed copy).
    pub const FileStreamRole = struct { fd: wasi_p1.Fd, pos: u64, result_future: u32 = 0 };

    /// The substrate→P3 reverse-dep inversion (ADR-0207): the shared engine /
    /// drop / poll paths reach the 0.3 trampoline layer ONLY through these
    /// fn-pointers, so the substrate never names a P3 symbol. Installed by
    /// `init` while co-located (M1); moves to the P3 host file's
    /// `installP3Hooks` at extraction (M2).
    pub const P3Hooks = struct {
        drop_transferred_end: *const fn (*WasiP2Ctx, u32) void,
        udp_receive_complete: *const fn (*WasiP2Ctx, u32, u32) WasiP2Error!void,
        fail_file_stream: *const fn (*WasiP2Ctx, *async_mod.StreamFutureEnd, *FileStreamRole, wasi_p1.Errno) WasiP2Error!u32,
        resolve_send_future: *const fn (*WasiP2Ctx, u32, ?u8) WasiP2Error!void,
        sock_err_code: *const fn (anyerror) u8,
        dir_stream_read: *const fn (*WasiP2Ctx, u32, *async_mod.StreamFutureEnd, u32, u32) WasiP2Error!u32,
    };

    /// Reaching an unset hook requires a live P3 resource, which only exists
    /// once the P3 layer installed the hooks — so this is a programmer error,
    /// not a runtime condition (`platform_panic_vs_error.md`).
    pub fn p3(self: *WasiP2Ctx) *const P3Hooks {
        if (self.p3_hooks) |*h| return h;
        @panic("P3 hook uninstalled (ADR-0207)");
    }

    pub fn init(alloc: Allocator, host: *wasi_host.Host) !WasiP2Ctx {
        return .{
            .alloc = alloc,
            .host = host,
            .resources = try resource_table.ResourceTable.init(alloc),
            .guest_resources = try resource_table.ResourceTable.init(alloc),
            .streams = try async_mod.StreamFutureTable.init(alloc),
            .shared = async_mod.SharedTable.init(alloc),
            .sets = try async_mod.WaitableSetTable.init(alloc),
        };
    }

    pub fn deinit(self: *WasiP2Ctx) void {
        if (self.host.io) |io| {
            for (self.tcp_sockets.items) |*sock| {
                if (sock.state != .closed) sock.deinit(io);
            }
        }
        self.tcp_sockets.deinit(self.alloc);
        if (self.host.io) |io2| {
            for (self.udp_sockets.items) |*u| u.deinit(io2);
        }
        self.udp_sockets.deinit(self.alloc);
        for (self.http_fields.items) |*f| f.deinit(self.alloc);
        self.http_fields.deinit(self.alloc);
        for (self.http_requests.items) |*r| r.deinit(self.alloc);
        self.http_requests.deinit(self.alloc);
        self.http_responses.deinit(self.alloc);
        self.http_reqopts.deinit(self.alloc);
        self.host_trailer_ok_futures.deinit(self.alloc);
        var body_it = self.host_body_bytes.iterator();
        while (body_it.next()) |e| self.alloc.free(e.value_ptr.data);
        self.host_body_bytes.deinit(self.alloc);
        self.host_capture_sinks.deinit(self.alloc);
        for (self.pending_client_sends.items) |pcs| {
            pcs.body.deinit(self.alloc);
            self.alloc.destroy(pcs);
        }
        self.pending_client_sends.deinit(self.alloc);
        self.host_accept_streams.deinit(self.alloc);
        self.host_tcp_rx.deinit(self.alloc);
        self.host_tcp_tx.deinit(self.alloc);
        self.blocked_socket_reads.deinit(self.alloc);
        self.blocked_udp_receives.deinit(self.alloc);
        self.dir_streams.deinit(self.alloc);
        self.resources.deinit();
        self.guest_resources.deinit();
        for (self.rb_ctxs.items) |p| self.alloc.destroy(p);
        self.rb_ctxs.deinit(self.alloc);
        self.guest_dtors.deinit(self.alloc);
        for (self.ab_ctxs.items) |p| self.alloc.destroy(p);
        self.ab_ctxs.deinit(self.alloc);
        for (self.cb_ctxs.items) |p| self.alloc.destroy(p);
        self.cb_ctxs.deinit(self.alloc);
        self.host_file_streams.deinit(self.alloc);
        self.host_dir_streams.deinit(self.alloc);
        self.descriptor_open_flags.deinit(self.alloc);
        self.pending_writes.deinit(self.alloc);
        self.host_sinks.deinit(self.alloc);
        self.host_sources.deinit(self.alloc);
        self.pending_reads.deinit(self.alloc);
        self.host_result_futures.deinit(self.alloc);
        self.streams.deinit();
        self.shared.deinit();
        self.sets.deinit();
    }

    /// Allocate `size` bytes of fresh guest memory via the guest's
    /// `cabi_realloc` (old_ptr=0). Used to build list/string return areas.
    pub fn reallocGuest(self: *WasiP2Ctx, size: u32, alignment: u32) WasiP2Error!u32 {
        const inst = self.realloc_instance orelse return WasiP2Error.NoRealloc;
        var args = [_]Value{ .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = @bitCast(alignment) }, .{ .i32 = @bitCast(size) } };
        var res = [_]Value{.{ .i32 = 0 }};
        inst.invoke(self.realloc_name, &args, &res) catch return WasiP2Error.ReallocFailed;
        const ptr: u32 = @bitCast(res[0].i32);
        if (ptr == 0 and size != 0) return WasiP2Error.ReallocFailed;
        return ptr;
    }

    /// The guest linear memory the lowered funcs operate on (`mem_instance`).
    pub fn memory(self: *WasiP2Ctx) WasiP2Error!Memory {
        const inst = self.mem_instance orelse return WasiP2Error.NoMemory;
        const rt = inst.handle.runtime orelse return WasiP2Error.NoMemory;
        if (rt.memory.len == 0) return WasiP2Error.NoMemory;
        return .{ .backing = .{ .interp = rt } };
    }

    /// The host monotonic clock (P1 clock id 1) in ns — the time base for
    /// `monotonic-clock.now` AND the timer subtask deadlines, so `wait-until`
    /// comparisons are exact.
    pub fn monotonicNowNs(self: *WasiP2Ctx) WasiP2Error!u64 {
        return wasi_clocks.clockTimeNs(self.host, 1) catch WasiP2Error.NoHostIo;
    }

    /// Resolve every due timer subtask against the clock now (ADR-0205 D2).
    /// Returns the nearest still-future deadline (the scheduler's sleep bound).
    /// No armed timer → no clock read (hosts without `io` never need one).
    pub fn fireDueTimers(self: *WasiP2Ctx) WasiP2Error!?u64 {
        if (!self.streams.hasArmedTimer()) return null;
        return self.streams.fireDueTimers(try self.monotonicNowNs());
    }

    /// Poll blocked socket-read ends (accept / tcp-rx); a now-ready socket's
    /// PARKED READ EXECUTES here (accept / recv into the parked destination)
    /// and the event completes with the real element count — the socket
    /// analogue of `deliverParkedReads`. A bare "re-read" poke (payload 0)
    /// is NOT an option: the guest stream runtime reads a 0-element
    /// completion as end-of-stream (`accept.next()` → None). Returns true
    /// if any completed (the scheduler retries).
    pub fn pollBlockedSockets(self: *WasiP2Ctx) WasiP2Error!bool {
        if (self.blocked_socket_reads.count() == 0) return false;
        var progressed = false;
        var it = self.blocked_socket_reads.iterator();
        var ready_handles: [64]u32 = undefined;
        var n_ready: usize = 0;
        while (it.next()) |entry| {
            const sock = self.tcpSocketRep(entry.value_ptr.rep) orelse continue;
            if (sock.ready(p2sock.POLL_IN) catch false) {
                if (n_ready < ready_handles.len) {
                    ready_handles[n_ready] = entry.key_ptr.*;
                    n_ready += 1;
                }
            }
        }
        for (ready_handles[0..n_ready]) |h| {
            const pr = self.blocked_socket_reads.get(h) orelse continue;
            const end = self.streams.get(h) catch continue;
            const mem = try self.memory();
            const io = try ctxIo(self);
            if (dbg.on("async.host")) std.debug.print("[host] sock-ready handle={d} cap={d}\n", .{ h, pr.cap });
            if (self.host_accept_streams.get(end.shared) != null) {
                // Accept stream: mint an own<tcp-socket> handle per queued
                // connection (elements are u32 handles).
                var filled: u32 = 0;
                while (filled < pr.cap) {
                    const listener = self.tcpSocketRep(pr.rep) orelse break;
                    const conn = listener.accept(io) catch break;
                    const idx: u32 = @intCast(self.tcp_sockets.items.len);
                    self.tcp_sockets.append(self.alloc, conn) catch return WasiP2Error.OutOfMemory;
                    const nh = try self.resources.new(TCP_SOCKET_RT, idx);
                    try mem.write(pr.ptr + filled * 4, nh);
                    filled += 1;
                }
                if (filled == 0) continue; // spurious readiness — stay parked
                end.state = .done;
                end.setPendingEvent(.{ .code = .stream_read, .index = h, .payload = (async_mod.ReturnCode{ .completed = @intCast(filled) }).encode() });
            } else if (self.host_tcp_rx.get(end.shared) != null) {
                const sock = self.tcpSocketRep(pr.rep) orelse continue;
                const buf = mem.sliceAt(pr.ptr, pr.cap * pr.elem_size) catch return WasiP2Error.OutOfBounds;
                const n = sock.recv(io, buf) catch 0;
                if (n == 0) {
                    // Ready-then-zero = peer FIN → the stream closes.
                    switch ((try self.shared.get(end.shared)).*) {
                        .stream => |*sh_s| sh_s.dropped = true,
                        .future, .subtask => continue,
                    }
                    end.state = .done;
                    end.setPendingEvent(.{ .code = .stream_read, .index = h, .payload = (async_mod.ReturnCode{ .dropped = 0 }).encode() });
                } else {
                    end.state = .done;
                    end.setPendingEvent(.{ .code = .stream_read, .index = h, .payload = (async_mod.ReturnCode{ .completed = @intCast(n / pr.elem_size) }).encode() });
                }
                if (dbg.on("async.host")) std.debug.print("[host] sock-rx-complete handle={d} n={d}\n", .{ h, n });
            } else continue;
            _ = self.blocked_socket_reads.remove(h);
            progressed = true;
        }
        return progressed;
    }

    /// Poll parked `udp.receive` subtasks; a ready socket's receive EXECUTES
    /// (recvfrom + marshal at the saved retptr) and the subtask flips to
    /// RETURNED with its SUBTASK event pending (the timer-fire shape).
    pub fn pollBlockedUdpReceives(self: *WasiP2Ctx) WasiP2Error!bool {
        if (self.blocked_udp_receives.count() == 0) return false;
        var progressed = false;
        var it = self.blocked_udp_receives.iterator();
        var ready_handles: [64]u32 = undefined;
        var n_ready: usize = 0;
        while (it.next()) |entry| {
            const sock = ctxUdpSocket(self, entry.value_ptr.rep) catch continue;
            if (sock.readyIn() catch false) {
                if (n_ready < ready_handles.len) {
                    ready_handles[n_ready] = entry.key_ptr.*;
                    n_ready += 1;
                }
            }
        }
        for (ready_handles[0..n_ready]) |h| {
            const pr = self.blocked_udp_receives.get(h) orelse continue;
            const end = self.streams.get(h) catch continue;
            try self.p3().udp_receive_complete(self, pr.rep, pr.retptr);
            end.subtask_state = .returned;
            end.setPendingEvent(.{ .code = .subtask, .index = h, .payload = @intFromEnum(async_mod.SubtaskState.returned) });
            _ = self.blocked_udp_receives.remove(h);
            progressed = true;
        }
        return progressed;
    }

    fn tcpSocketRep(self: *WasiP2Ctx, rep: u32) ?*p2sock.TcpSocket {
        const idx = rep & 0x00FF_FFFF;
        if (idx >= self.tcp_sockets.items.len) return null;
        return &self.tcp_sockets.items[idx];
    }

    /// WAIT-path delivery (ADR-0191 E2c): for each member of `set` with a parked
    /// host-source read, copy the now-available bytes into the read's buffer and
    /// set the end's `STREAM_READ` pending event so `WaitableSet.poll` delivers
    /// it. The runner calls this just before polling at `waitOn`.
    pub fn deliverParkedReads(self: *WasiP2Ctx, set: *async_mod.WaitableSet) WasiP2Error!void {
        for (set.elems.items) |m| {
            const pr = self.pending_reads.get(m) orelse continue;
            const end = self.streams.get(m) catch continue;
            if (self.host_sources.get(end.shared) == null) continue;
            const mem = try self.memory();
            // D-335: cap is in ELEMENTS; slice cap*elem_size bytes, COMPLETE in elements.
            const buf = mem.sliceAt(pr.ptr, pr.cap * pr.elem_size) catch return WasiP2Error.OutOfBounds;
            const n: u32 = @intCast(wasi_fd.readStdinSlice(self.host, buf));
            end.state = .done;
            end.setPendingEvent(.{ .code = .stream_read, .index = m, .payload = (async_mod.ReturnCode{ .completed = @intCast(n / pr.elem_size) }).encode() });
            _ = self.pending_reads.remove(m);
        }
    }
};

/// The lowered-WASI guest memory for a trampoline. Prefers the canon-lower-bound
/// memory recorded on `WasiP2Ctx` (`mem_instance`) — the immediate caller may be
/// the memory-less wit-bindgen shim (D-310). Falls back to `caller.memory()`
/// when no `mem_instance` is set (direct-call unit tests that build a ctx by
/// hand), preserving the original direct-dispatch behaviour.
pub fn ctxMemory(caller: *Caller) WasiP2Error!Memory {
    const ctx = caller.data(WasiP2Ctx);
    if (ctx.mem_instance != null) return ctx.memory();
    return caller.memory() orelse return WasiP2Error.NoMemory;
}

pub const WasiP2Error = error{ NoMemory, OutOfBounds, WriteFailed, NoRealloc, ReallocFailed, ProcExit, OutOfMemory, NoHostIo, Unreachable, UnsupportedAsyncBuiltin } ||
    resource_table.Error || Memory.Error || async_mod.Error;

pub const Memory = @import("../zwasm/memory.zig").Memory;

/// `wasi:cli/stdout` `get-stdout` → mint an output-stream handle bound to fd 1.
pub fn ctxTcpSocket(ctx: *WasiP2Ctx, rep: u32) WasiP2Error!*p2sock.TcpSocket {
    const idx = rep & 0x00FF_FFFF;
    if (idx >= ctx.tcp_sockets.items.len) return resource_table.Error.InvalidHandle;
    return &ctx.tcp_sockets.items[idx];
}

pub fn ctxIo(ctx: *WasiP2Ctx) WasiP2Error!std.Io {
    return ctx.host.io orelse WasiP2Error.NoHostIo;
}

/// The live `UdpSocket` behind a UDP3 handle rep (shared with the P3 host
/// layer — ADR-0207 straddle accessor).
pub fn ctxUdpSocket(ctx: *WasiP2Ctx, rep: u32) WasiP2Error!*p2sock.UdpSocket {
    if (rep >= ctx.udp_sockets.items.len) return resource_table.Error.InvalidHandle;
    return &ctx.udp_sockets.items[rep];
}

pub const FilestatResult = union(enum) { ok: wasi_p1.Filestat, err: wasi_p1.Errno };

/// `metadata-hash-value{lower, upper}` for one filestat, shared by the 0.2
/// (`component_wasi_p2`) and 0.3 (`component_wasi_p3_host`) `metadata-hash`
/// families so a guest sees ONE identity per object whichever generation it
/// speaks: a Wyhash over (dev, ino, size, mtim) — stable while the object is
/// unmodified, changes when it changes (the spec's encouraged properties;
/// none is required).
pub fn metadataHash(fs: wasi_p1.Filestat) [2]u64 {
    var h = std.hash.Wyhash.init(0x7a77_6173_6d5f_6673); // "zwasm_fs"
    h.update(std.mem.asBytes(&fs.dev));
    h.update(std.mem.asBytes(&fs.ino));
    h.update(std.mem.asBytes(&fs.size));
    h.update(std.mem.asBytes(&fs.mtim));
    const lo = h.final();
    var h2 = std.hash.Wyhash.init(lo);
    h2.update(std.mem.asBytes(&fs.ino));
    return .{ lo, h2.final() };
}

/// Stat the fd bound to `self` via P1 `fd_filestat_get` into a scratch buffer,
/// returning the raw `Filestat` (the shared P1→P2 front-half for stat/get-type).
pub fn descriptorFilestat(ctx: *WasiP2Ctx, mem: Memory, fd: wasi_p1.Fd) WasiP2Error!FilestatResult {
    const scratch = try ctx.reallocGuest(@sizeOf(wasi_p1.Filestat), 8);
    const errno = wasi_fd.fdFilestatGet(ctx.host, mem.slice(), fd, scratch);
    if (errno != .success) return .{ .err = errno };
    const bytes = mem.sliceAt(scratch, @sizeOf(wasi_p1.Filestat)) catch return WasiP2Error.OutOfBounds;
    return .{ .ok = std.mem.bytesToValue(wasi_p1.Filestat, bytes) };
}

/// Path-addressed variant: stat `path` relative to the directory fd via P1
/// `path_filestat_get` (the stat-at front-half).
pub fn pathFilestat(ctx: *WasiP2Ctx, mem: Memory, dirfd: wasi_p1.Fd, lookupflags: u32, path_ptr: u32, path_len: u32) WasiP2Error!FilestatResult {
    const scratch = try ctx.reallocGuest(@sizeOf(wasi_p1.Filestat), 8);
    const errno = wasi_path.pathFilestatGet(ctx.host, mem.slice(), dirfd, lookupflags, path_ptr, path_len, scratch);
    if (errno != .success) return .{ .err = errno };
    const bytes = mem.sliceAt(scratch, @sizeOf(wasi_p1.Filestat)) catch return WasiP2Error.OutOfBounds;
    return .{ .ok = std.mem.bytesToValue(wasi_p1.Filestat, bytes) };
}

/// `wasi:filesystem/types` `[method]descriptor.get-type` (self, retptr): store
/// `result<descriptor-type, error-code>` at `retptr` (disc@0; payload@1).
pub fn decodeIpSocketAddress(disc: u32, p: [11]u32) ?std.Io.net.IpAddress {
    switch (disc) {
        0 => return .{ .ip4 = .{
            .port = @truncate(p[0]),
            .bytes = .{ @truncate(p[1]), @truncate(p[2]), @truncate(p[3]), @truncate(p[4]) },
        } },
        1 => {
            var bytes: [16]u8 = undefined;
            for (0..8) |i| {
                const seg: u16 = @truncate(p[2 + i]);
                bytes[i * 2] = @intCast(seg >> 8); // big-endian segments
                bytes[i * 2 + 1] = @truncate(seg);
            }
            return .{ .ip6 = .{ .port = @truncate(p[0]), .bytes = bytes, .flow = p[1] } };
        },
        else => return null,
    }
}

test "D-444 II: decodeIpSocketAddress — ipv4/ipv6 flat decode, u16 truncation, invalid disc" {
    // ipv4: p0=port (u16 truncation is the CABI i32→u16 lowering), p1..p4=octets.
    const v4 = decodeIpSocketAddress(0, .{ 0x0001_2345, 192, 168, 1, 2, 0, 0, 0, 0, 0, 0 }).?;
    try std.testing.expectEqual(@as(u16, 0x2345), v4.ip4.port);
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 1, 2 }, &v4.ip4.bytes);
    // ipv6: p0=port, p1=flow, p2..p9=segments packed big-endian into bytes.
    const v6 = decodeIpSocketAddress(1, .{ 0xBEEF, 0x1122_3344, 0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1, 0 }).?;
    try std.testing.expectEqual(@as(u16, 0xBEEF), v6.ip6.port);
    try std.testing.expectEqual(@as(u32, 0x1122_3344), v6.ip6.flow);
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 0x01, 0x0D, 0xB8 }, v6.ip6.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01 }, v6.ip6.bytes[14..16]);
    // Variant has exactly 2 cases; anything else is a decode failure, not a trap.
    try std.testing.expectEqual(@as(?std.Io.net.IpAddress, null), decodeIpSocketAddress(2, @splat(0)));
}

/// Write the err-arm of a sockets `result<_, error-code>`: disc 1 at `retptr`,
/// then the `wasi:sockets/network` error-code ordinal at `retptr + off` (the
/// payload offset varies with the result's alignment across the tcp methods).
pub fn writeIpSocketAddressResult(mem: Memory, retptr: u32, addr: std.Io.net.IpAddress) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 0));
    switch (addr) {
        .ip4 => |a| {
            try mem.write(retptr + 4, @as(u8, 0));
            try mem.write(retptr + 8, a.port);
            for (a.bytes, 0..) |b, i| try mem.write(retptr + 10 + @as(u32, @intCast(i)), b);
        },
        .ip6 => |a| {
            try mem.write(retptr + 4, @as(u8, 1));
            try mem.write(retptr + 8, a.port);
            try mem.write(retptr + 12, a.flow);
            for (0..8) |i| {
                const seg: u16 = (@as(u16, a.bytes[i * 2]) << 8) | a.bytes[i * 2 + 1];
                try mem.write(retptr + 16 + @as(u32, @intCast(i * 2)), seg);
            }
            try mem.write(retptr + 32, @as(u32, 0)); // scope-id (not modeled)
        },
    }
}

test "D-444 II: writeIpSocketAddressResult — CABI in-memory layout for both address cases" {
    const Runtime = @import("../runtime/runtime.zig").Runtime;
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();
    rt.memory = try std.testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0xAA); // poison so untouched bytes are visible
    const mem: Memory = .{ .backing = .{ .interp = &rt } };

    try writeIpSocketAddressResult(mem, 0, .{ .ip4 = .{ .port = 0x1234, .bytes = .{ 192, 168, 1, 2 } } });
    try std.testing.expectEqual(@as(u8, 0), try mem.read(u8, 0)); // result disc = ok
    try std.testing.expectEqual(@as(u8, 0), try mem.read(u8, 4)); // variant disc = ipv4
    try std.testing.expectEqual(@as(u16, 0x1234), try mem.read(u16, 8));
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 1, 2 }, mem.slice()[10..14]);

    var b16: [16]u8 = undefined;
    for (0..16) |i| b16[i] = @intCast(i + 1);
    try writeIpSocketAddressResult(mem, 0, .{ .ip6 = .{ .port = 0xBEEF, .bytes = b16, .flow = 0x1122_3344 } });
    try std.testing.expectEqual(@as(u8, 1), try mem.read(u8, 4)); // variant disc = ipv6
    try std.testing.expectEqual(@as(u16, 0xBEEF), try mem.read(u16, 8));
    try std.testing.expectEqual(@as(u32, 0x1122_3344), try mem.read(u32, 12));
    // Segments re-compose big-endian from byte pairs: seg0 = 0x0102, seg7 = 0x0F10.
    try std.testing.expectEqual(@as(u16, 0x0102), try mem.read(u16, 16));
    try std.testing.expectEqual(@as(u16, 0x0F10), try mem.read(u16, 30));
    try std.testing.expectEqual(@as(u32, 0), try mem.read(u32, 32)); // scope-id fixed 0

    // Decode/write agree on the big-endian segment convention (round-trip).
    const back = decodeIpSocketAddress(1, .{ 0xBEEF, 0x1122_3344, 0x0102, 0x0304, 0x0506, 0x0708, 0x090A, 0x0B0C, 0x0D0E, 0x0F10, 0 }).?;
    try std.testing.expectEqualSlices(u8, &b16, &back.ip6.bytes);
}

/// `tcp.local-address` (self, retptr) -> result<ip-socket-address, error-code>.
pub const AsyncBuiltinCtx = struct { ctx: *WasiP2Ctx, type_index: u32, elem_size: u32 = 1 };

pub const ResourceBuiltinCtx = struct { ctx: *WasiP2Ctx, type_index: u32 };

pub const GuestDtor = struct { type_index: u32, inst: *Instance, name: []const u8 };

/// Is type-space entry `ti` a locally-DEFINED resource type (vs an
/// imported/host one)?
pub fn p2GuestResourceNew(caller: *Caller, rep_val: u32) WasiP2Error!u32 {
    const rbc = caller.data(ResourceBuiltinCtx);
    return rbc.ctx.guest_resources.new(rbc.type_index, rep_val);
}

/// `canon resource.rep`: handle -> stored representation.
pub fn p2GuestResourceRep(caller: *Caller, handle: u32) WasiP2Error!u32 {
    const rbc = caller.data(ResourceBuiltinCtx);
    return rbc.ctx.guest_resources.rep(rbc.type_index, handle);
}

/// `canon resource.drop`: remove the handle; an OWN handle additionally
/// runs the resource's declared destructor over the rep.
pub fn p2GuestResourceDrop(caller: *Caller, handle: u32) WasiP2Error!void {
    const rbc = caller.data(ResourceBuiltinCtx);
    const rep_opt = try rbc.ctx.guest_resources.drop(rbc.type_index, handle);
    if (rep_opt) |rep_val| {
        for (rbc.ctx.guest_dtors.items) |gd| {
            if (gd.type_index != rbc.type_index) continue;
            var args = [_]Value{.{ .i32 = @bitCast(rep_val) }};
            gd.inst.invoke(gd.name, &args, &.{}) catch return WasiP2Error.WriteFailed;
            break;
        }
    }
}

/// `canon task.return` (WASI 0.3, ADR-0189 ζ2): record the value the async task
/// delivered as its result. Minimal single-`i32`-lowered-result form; the P3
/// runner reads `ctx.task_return` after the callback loop exits.
pub fn p2TaskReturn(caller: *Caller, val: i32) WasiP2Error!void {
    caller.data(WasiP2Ctx).task_return = @bitCast(val);
}

/// The raw-signature `task.return` (result flattens to >1 core param):
/// slot 0 is the result discriminant, slot 1 the ok-payload (e.g. the
/// response handle of the http `handler.handle` export); the error-case
/// junk slots are ignored — the harness reads the payload only when
/// disc == 0.
pub fn p2TaskReturnRaw(caller: *Caller, args: []const rt_value.Value, results: []rt_value.Value) anyerror!void {
    _ = results;
    const ctx = caller.data(WasiP2Ctx);
    ctx.task_return = if (args.len > 0) @bitCast(args[0].i32) else 0;
    ctx.task_return_payload = if (args.len > 1) @as(u32, @bitCast(args[1].i32)) else null;
    if (dbg.on("async.host")) std.debug.print("[host] task-return-raw n={d} disc={?d} payload={?d}\n", .{ args.len, ctx.task_return, ctx.task_return_payload });
}

/// `canon stream.new` (ADR-0189 ζ2): mint a readable+writable end pair over a
/// fresh shared rendezvous; return the spec's packed `ri | (wi << 32)`.
pub fn p2StreamNew(caller: *Caller) WasiP2Error!u64 {
    const abc = caller.data(AsyncBuiltinCtx);
    const pair = try async_mod.newStreamPair(&abc.ctx.streams, &abc.ctx.shared, abc.type_index);
    return @as(u64, pair.readable) | (@as(u64, pair.writable) << 32);
}

/// `canon future.new` — symmetric to `p2StreamNew`.
pub fn p2FutureNew(caller: *Caller) WasiP2Error!u64 {
    const abc = caller.data(AsyncBuiltinCtx);
    const pair = try async_mod.newFuturePair(&abc.ctx.streams, &abc.ctx.shared, abc.type_index);
    return @as(u64, pair.readable) | (@as(u64, pair.writable) << 32);
}

/// `wasi:cli/stdout.write-via-stream` (WASI 0.3, ADR-0190): the host becomes the
/// readable end's reader, sinking to a P1 fd. Register the host sink keyed by
/// the stream's `SharedStream` handle (a guest `stream.write` then COMPLETES into
/// it), and return a fresh future handle (the spec's `future<result<_, error>>`;
/// its resolution is a later E-slice — the guest may drop it).
fn p2WriteViaStream(caller: *Caller, stream_handle: u32, fd: wasi_p1.Fd) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const end = try ctx.streams.get(stream_handle);
    try ctx.host_sinks.put(ctx.alloc, end.shared, fd);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null); // ok unless a stream failure records an error
    return fut.readable;
}

pub fn p2StdoutWriteViaStream(caller: *Caller, stream_handle: u32) WasiP2Error!u32 {
    return p2WriteViaStream(caller, stream_handle, 1);
}

pub fn p2StderrWriteViaStream(caller: *Caller, stream_handle: u32) WasiP2Error!u32 {
    return p2WriteViaStream(caller, stream_handle, 2);
}

/// `wasi:cli/stdin.read-via-stream` (WASI 0.3, ADR-0190): the host becomes the
/// stream's WRITER (supplying bytes from a P1 fd). Mint a stream pair + a future
/// and write the `tuple<stream<u8>, future<result<_,error-code>>>` result to the
/// guest's return pointer `retptr` (the tuple flattens past MAX_FLAT_RESULTS=1 →
/// a memory return: `ri` at `retptr`, the future handle at `retptr+4`). The
/// readable end is registered as a host source so a guest `stream.read` pulls
/// bytes from `fd` (stdin).
pub fn p2StdinReadViaStream(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    try ctx.host_sources.put(ctx.alloc, (try ctx.streams.get(pair.readable)).shared, 0); // fd 0 = stdin
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null); // ok unless a stream failure records an error
    const mem = try ctx.memory();
    try mem.write(retptr, pair.readable);
    try mem.write(retptr + 4, fut.readable);
}

/// `canon waitable-set.new` (ADR-0190 E2b): mint an empty waitable set.
pub fn p2WaitableSetNew(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.sets.add(async_mod.WaitableSet.init(ctx.alloc));
}

/// `canon waitable.join` (ADR-0190 E2b; `CanonicalABI.md canon_waitable_join`):
/// core args are `(waitable, set)` — set 0 = LEAVE the current set; a join
/// always moves (a waitable belongs to at most one set).
pub fn p2WaitableJoin(caller: *Caller, waitable: u32, set_handle: u32) WasiP2Error!void {
    return p2WaitableJoinInner(caller, waitable, set_handle) catch |e| mapAsyncFault(e);
}
fn p2WaitableJoinInner(caller: *Caller, waitable: u32, set_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    ctx.sets.unjoin(waitable);
    if (set_handle == 0) return;
    const set = try ctx.sets.get(set_handle); // bad set handle = guest fault → trap
    try set.join(waitable);
}

/// Map a WASI-P2 async-builtin error to the host-fn surface (D-445). A guest
/// supplies the handle/ptr, so a bad handle, illegal drop/cancel sequencing,
/// an exhausted table, or an out-of-bounds buffer is a GUEST fault → surface
/// the canonical guest trap (`error.Unreachable`), which `mapDispatchErr`
/// narrows cleanly. Without this those un-narrowed variants would hit
/// `mapDispatchErr`'s `else => @panic` and abort the host on guest input.
/// Genuine host failures (NoMemory, realloc, host I/O, OOM) propagate unchanged.
pub fn mapAsyncFault(e: WasiP2Error) WasiP2Error {
    return switch (e) {
        error.InvalidHandle,
        error.TableFull,
        error.CopyInProgress,
        error.NotCopying,
        error.InvalidCallbackCode,
        error.FutureDropBeforeWrite,
        error.CopyNotIdle,
        error.OutOfBounds,
        => error.Unreachable,
        else => |other| other,
    };
}

/// Packed return of an async-lowered import call (`CanonicalABI.md`
/// `canon_lower`, async case): `state | (subtask_handle << 4)`; an eager
/// completion returns bare `RETURNED` with no handle minted.
pub const SUBTASK_RETURNED: u32 = @intFromEnum(async_mod.SubtaskState.returned);

/// `wasi:clocks/monotonic-clock@0.3.0` `wait-until: async func(when: mark)`
/// under an async `canon lower` (ADR-0205 phase A). Already-elapsed deadline →
/// eager RETURNED (no subtask). Otherwise mint a TIMER subtask waitable; the
/// scheduler's poll path (`fireDueTimers`) resolves it and delivers the
/// SUBTASK event through the set the guest joins it into.
pub fn p2WaitUntil(caller: *Caller, when_raw: i64) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return p2WaitDeadlineAsync(ctx, @bitCast(when_raw)) catch |e| mapAsyncFault(e);
}

/// `wait-for: async func(how-long: duration)` — the relative-form sibling.
pub fn p2WaitFor(caller: *Caller, dur_raw: i64) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const now = try ctx.monotonicNowNs();
    const dur: u64 = @bitCast(dur_raw);
    return p2WaitDeadlineAsync(ctx, now +| dur) catch |e| mapAsyncFault(e);
}

fn p2WaitDeadlineAsync(ctx: *WasiP2Ctx, deadline_ns: u64) WasiP2Error!u32 {
    const now = try ctx.monotonicNowNs();
    if (deadline_ns <= now) return SUBTASK_RETURNED;
    const h = try ctx.streams.add(.{
        .kind = .subtask,
        .side = .readable,
        .elem_type = null,
        .subtask_state = .started,
        .deadline_ns = deadline_ns,
    });
    return @intFromEnum(async_mod.SubtaskState.started) | (h << 4);
}

/// The SYNC-lowered form of the async wait funcs (the Canonical ABI lets a
/// guest lower an `async func` synchronously — the call then blocks).
pub fn p2WaitUntilSync(caller: *Caller, when_raw: i64) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    return p2WaitDeadlineSync(ctx, @bitCast(when_raw));
}

pub fn p2WaitForSync(caller: *Caller, dur_raw: i64) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const now = try ctx.monotonicNowNs();
    const dur: u64 = @bitCast(dur_raw);
    return p2WaitDeadlineSync(ctx, now +| dur);
}

fn p2WaitDeadlineSync(ctx: *WasiP2Ctx, deadline_ns: u64) WasiP2Error!void {
    const now = try ctx.monotonicNowNs();
    if (deadline_ns <= now) return;
    const io = ctx.host.io orelse return WasiP2Error.NoHostIo;
    std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@intCast(deadline_ns - now)), .awake) catch |err| switch (err) {
        error.Canceled => {}, // a cancelled sleep just wakes early
    };
}

/// `canon waitable-set.poll` (non-blocking; `CanonicalABI.md`
/// `canon_waitable_set_poll` + `unpack_event`): deliver parked host-source
/// reads + fire due timers (the make-progress hooks), then poll the set. An
/// event writes `(p1, p2)` at `ptr`/`ptr+4` and returns its code; no event
/// returns NONE (0). Writes target the canon-lower-bound memory (`ctxMemory`),
/// matching every other retptr-writing trampoline here.
pub fn p2WaitableSetPoll(caller: *Caller, set_handle: u32, ptr: u32) WasiP2Error!u32 {
    return p2WaitableSetPollInner(caller, set_handle, ptr) catch |e| mapAsyncFault(e);
}
fn p2WaitableSetPollInner(caller: *Caller, set_handle: u32, ptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const set = try ctx.sets.get(set_handle);
    try ctx.deliverParkedReads(set);
    _ = try ctx.fireDueTimers();
    if (dbg.on("async.host")) std.debug.print("[host] poll set={d} members={d}\n", .{ set_handle, set.elems.items.len });
    const ev = (try set.poll(&ctx.streams)) orelse return 0; // EventCode.none
    const mem = try ctxMemory(caller);
    try mem.write(ptr, ev.index);
    try mem.write(ptr + 4, ev.payload);
    return @intFromEnum(ev.code);
}

/// `canon waitable-set.drop` — remove the set from the table (tearing down its
/// member list). Members themselves stay live (they just leave the set).
pub fn p2WaitableSetDrop(caller: *Caller, set_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    ctx.sets.remove(set_handle) catch |e| return mapAsyncFault(e);
}

/// `canon subtask.drop` — release a resolved subtask handle. Dropping an
/// UNRESOLVED subtask is a guest fault per spec (`Subtask.drop` traps before
/// `on_resolve` delivered), surfaced as the canonical guest trap.
pub fn p2SubtaskDrop(caller: *Caller, handle: u32) WasiP2Error!void {
    return p2SubtaskDropInner(caller, handle) catch |e| mapAsyncFault(e);
}
fn p2SubtaskDropInner(caller: *Caller, handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const end = try ctx.streams.get(handle);
    if (end.kind != .subtask) return WasiP2Error.InvalidHandle;
    switch (end.subtask_state) {
        .returned, .cancelled_before_started, .cancelled_before_returned => {},
        .starting, .started => return WasiP2Error.Unreachable, // drop before resolve = guest fault
    }
    _ = try ctx.streams.remove(handle);
}

/// `canon task.cancel` / `canon subtask.cancel` — CM-async cancellation is not
/// implemented (no current caller in the conformance corpus exercises it);
/// linking succeeds, a CALL fails loudly (never a silent no-op).
pub fn p2TaskCancel(caller: *Caller) WasiP2Error!void {
    _ = caller;
    return WasiP2Error.UnsupportedAsyncBuiltin;
}

pub fn p2SubtaskCancel(caller: *Caller, handle: u32) WasiP2Error!u32 {
    _ = caller;
    _ = handle;
    return WasiP2Error.UnsupportedAsyncBuiltin;
}

/// `canon thread.yield` — cooperative yield point; same not-implemented
/// posture as cancellation (fail loudly at call, not at link).
pub fn p2ThreadYield(caller: *Caller) WasiP2Error!u32 {
    _ = caller;
    return WasiP2Error.UnsupportedAsyncBuiltin;
}

/// Per-definition ctx for a `canon context.{get,set}` builtin: the slot index
/// into `WasiP2Ctx.task_context` (mirrors `ResourceBuiltinCtx`).
pub const ContextBuiltinCtx = struct { ctx: *WasiP2Ctx, slot: u32 };

pub fn p2ContextGet32(caller: *Caller) WasiP2Error!u32 {
    const cbc = caller.data(ContextBuiltinCtx);
    return @truncate(cbc.ctx.task_context[cbc.slot]);
}

pub fn p2ContextSet32(caller: *Caller, v: u32) WasiP2Error!void {
    const cbc = caller.data(ContextBuiltinCtx);
    cbc.ctx.task_context[cbc.slot] = v;
}

pub fn p2ContextGet64(caller: *Caller) WasiP2Error!i64 {
    const cbc = caller.data(ContextBuiltinCtx);
    return @bitCast(cbc.ctx.task_context[cbc.slot]);
}

pub fn p2ContextSet64(caller: *Caller, v: i64) WasiP2Error!void {
    const cbc = caller.data(ContextBuiltinCtx);
    cbc.ctx.task_context[cbc.slot] = @bitCast(v);
}

/// `canon stream.read`/`stream.write` (+ future) (ADR-0189 ζ2, re-scoped per
/// lesson 2026-06-16): drive one rendezvous step on the end named by `handle`
/// (`StreamFutureEnd.copy` dispatches read vs write on the end's side) and
/// return the packed `ReturnCode`. Single-task reaches only BLOCKED (no peer
/// ready) or DROPPED (peer dropped first); a count > 0 COMPLETION needs a host
/// stream peer (Unit E) — that path also wires the element marshalling at
/// `ptr`, so it traps here until then (unreachable single-task).
/// The future-copy trampoline: same rendezvous step, but the core ABI carries
/// no count (a future moves exactly one value).
pub fn p2FutureCopy(caller: *Caller, handle: u32, ptr: u32) WasiP2Error!u32 {
    return p2StreamFutureCopyInner(caller, handle, ptr, 1) catch |e| mapAsyncFault(e);
}

pub fn p2StreamFutureCopy(caller: *Caller, handle: u32, ptr: u32, count: u32) WasiP2Error!u32 {
    const r = p2StreamFutureCopyInner(caller, handle, ptr, count) catch |e| return mapAsyncFault(e);
    if (dbg.on("async.host")) std.debug.print("[host] copy -> 0x{x}\n", .{r});
    return r;
}
fn p2StreamFutureCopyInner(caller: *Caller, handle: u32, ptr: u32, count: u32) WasiP2Error!u32 {
    const abc = caller.data(AsyncBuiltinCtx);
    const end = try abc.ctx.streams.get(handle);
    if (dbg.on("async.host")) std.debug.print("[host] copy handle={d} kind={s} side={s} count={d}\n", .{ handle, @tagName(end.kind), @tagName(end.side), count });
    // Host result future (ADR-0190): the `future<result<_,error-code>>` returned
    // by write/read-via-stream. A host stream peer always succeeds → a guest
    // `future.read` COMPLETES with the `ok` discriminant (0, 1 byte) — no
    // rendezvous, no general typed marshalling.
    // Harness-resolved trailers future (ADR-0205 D-3): completes with
    // `ok(none)` — result disc @0 AND the option disc must both be
    // written (a bare ok byte leaves the option disc as garbage). The
    // payload offset is 8: `error-code` carries u64 cases (align 8).
    if (abc.ctx.host_trailer_ok_futures.contains(handle)) {
        const mem = try abc.ctx.memory();
        const buf = mem.sliceAt(ptr, 9) catch return WasiP2Error.OutOfBounds;
        buf[0] = 0;
        buf[8] = 0;
        _ = abc.ctx.host_trailer_ok_futures.remove(handle);
        return (async_mod.ReturnCode{ .completed = 0 }).encode();
    }
    if (abc.ctx.host_result_futures.get(handle)) |outcome| {
        const mem = try abc.ctx.memory();
        if (outcome) |code| {
            // result<_, error-code> err: disc@0, error-code variant @4
            // (disc u8 @4, `other`'s option<string> @8 → none).
            const buf = mem.sliceAt(ptr, 9) catch return WasiP2Error.OutOfBounds;
            buf[0] = 1;
            buf[4] = code;
            buf[8] = 0;
        } else {
            const buf = mem.sliceAt(ptr, 1) catch return WasiP2Error.OutOfBounds;
            buf[0] = 0; // ok
        }
        // Future events never pack a count (CanonicalABI `future_event`:
        // "the number of elements copied ... always zero").
        return (async_mod.ReturnCode{ .completed = 0 }).encode();
    }
    // WASI-0.3 FILE via-stream peer (ADR-0205 phase B): positional
    // pread/pwrite at the role's tracked position, advanced per copy.
    if (abc.ctx.host_file_streams.getPtr(end.shared)) |role| {
        const mem = try abc.ctx.memory();
        // A position past i64 range would be an UNEXPECTED EINVAL inside
        // std.Io (debug panic); surface it as a failed stream + an
        // err(invalid) result future instead (official filesystem-io.wasm
        // preads at u64::MAX and expects error-code::invalid).
        const pos_invalid = role.pos > std.math.maxInt(i64);
        if (end.side == .writable) {
            const bytes = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
            const errno: wasi_p1.Errno = if (pos_invalid) .inval else wasi_fd.pwriteSlice(abc.ctx.host, role.fd, bytes, role.pos);
            if (errno != .success) return abc.ctx.p3().fail_file_stream(abc.ctx, end, role, errno);
            role.pos += bytes.len;
            return (async_mod.ReturnCode{ .completed = @intCast(count) }).encode();
        }
        const buf = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
        var n: usize = 0;
        const errno: wasi_p1.Errno = if (pos_invalid) .inval else wasi_fd.preadSlice(abc.ctx.host, role.fd, buf, role.pos, &n);
        if (errno != .success) return abc.ctx.p3().fail_file_stream(abc.ctx, end, role, errno);
        if (n == 0) {
            // EOF: the writer (host) side drops, so the guest observes a
            // CLOSED stream instead of retrying a 0-byte completion forever.
            switch ((try abc.ctx.shared.get(end.shared)).*) {
                .stream => |*sh_s| sh_s.dropped = true,
                .future, .subtask => return WasiP2Error.InvalidHandle,
            }
            end.state = .done;
            return (async_mod.ReturnCode{ .dropped = 0 }).encode();
        }
        role.pos += n;
        return (async_mod.ReturnCode{ .completed = @intCast(n / abc.elem_size) }).encode();
    }
    // WASI-0.3 TCP accept stream (ADR-0205 phase C): each element is a fresh
    // `own<tcp-socket>` handle for an accepted connection; ready connections
    // batch. No connection queued → PARK (blocked + readiness-hook
    // registration below) — waiting here would starve the guest's own
    // concurrent connecting task (the `futures::join!` shape of the official
    // tcp-listen / echo tests) and livelock the single-threaded runtime.
    if (abc.ctx.host_accept_streams.get(end.shared)) |rep| {
        if (end.side != .readable) return WasiP2Error.InvalidHandle;
        const mem = try abc.ctx.memory();
        const io = try ctxIo(abc.ctx);
        var filled: u32 = 0;
        while (filled < count) {
            const listener = try ctxTcpSocket(abc.ctx, rep);
            const conn = listener.accept(io) catch break;
            const idx: u32 = @intCast(abc.ctx.tcp_sockets.items.len);
            abc.ctx.tcp_sockets.append(abc.ctx.alloc, conn) catch return WasiP2Error.OutOfMemory;
            const h = try abc.ctx.resources.new(WasiP2Ctx.TCP_SOCKET_RT, idx);
            try mem.write(ptr + filled * 4, h);
            filled += 1;
        }
        if (filled == 0) {
            try abc.ctx.blocked_socket_reads.put(abc.ctx.alloc, handle, .{ .rep = rep, .ptr = ptr, .cap = count, .elem_size = abc.elem_size });
            end.state = .async_copying;
            return (async_mod.ReturnCode{ .blocked = {} }).encode();
        }
        _ = abc.ctx.blocked_socket_reads.remove(handle);
        return (async_mod.ReturnCode{ .completed = @intCast(filled) }).encode();
    }
    // WASI-0.3 TCP receive stream (phase C): bytes recv'd from the connected
    // socket; a 0-byte read (peer FIN) closes the stream.
    if (abc.ctx.host_tcp_rx.get(end.shared)) |rep| {
        if (end.side != .readable) return WasiP2Error.InvalidHandle;
        const mem = try abc.ctx.memory();
        const io = try ctxIo(abc.ctx);
        const sock = try ctxTcpSocket(abc.ctx, rep);
        // Not ready yet → BLOCKED + register for the readiness hook (do NOT
        // recv, which would block the whole runtime).
        if (!(sock.ready(p2sock.POLL_IN) catch true)) {
            try abc.ctx.blocked_socket_reads.put(abc.ctx.alloc, handle, .{ .rep = rep, .ptr = ptr, .cap = count, .elem_size = abc.elem_size });
            end.state = .async_copying;
            return (async_mod.ReturnCode{ .blocked = {} }).encode();
        }
        _ = abc.ctx.blocked_socket_reads.remove(handle);
        const buf = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
        const n = sock.recv(io, buf) catch 0;
        if (n == 0) {
            // Ready-then-zero = peer FIN → close the stream.
            switch ((try abc.ctx.shared.get(end.shared)).*) {
                .stream => |*sh_s| sh_s.dropped = true,
                .future, .subtask => return WasiP2Error.InvalidHandle,
            }
            end.state = .done;
            return (async_mod.ReturnCode{ .dropped = 0 }).encode();
        }
        return (async_mod.ReturnCode{ .completed = @intCast(n / abc.elem_size) }).encode();
    }
    // Harness request-body source (ADR-0205 D-3): serve bytes from the
    // stored buffer; exhausted → the stream closes (DROPPED).
    if (abc.ctx.host_body_bytes.getPtr(end.shared)) |body| {
        if (end.side != .readable) return WasiP2Error.InvalidHandle;
        const mem = try abc.ctx.memory();
        const remaining = body.data.len - body.pos;
        if (remaining == 0) {
            switch ((try abc.ctx.shared.get(end.shared)).*) {
                .stream => |*sh_s| sh_s.dropped = true,
                .future, .subtask => return WasiP2Error.InvalidHandle,
            }
            end.state = .done;
            return (async_mod.ReturnCode{ .dropped = 0 }).encode();
        }
        const n = @min(remaining, count * abc.elem_size);
        const buf = mem.sliceAt(ptr, @intCast(n)) catch return WasiP2Error.OutOfBounds;
        @memcpy(buf, body.data[body.pos..][0..n]);
        body.pos += n;
        return (async_mod.ReturnCode{ .completed = @intCast(n / abc.elem_size) }).encode();
    }
    // Harness capture sink (ADR-0205 D-3): a guest write appends to the
    // harness's buffer and completes — the response-body collector.
    if (abc.ctx.host_capture_sinks.get(end.shared)) |cap| {
        if (end.side != .writable) return WasiP2Error.InvalidHandle;
        const mem = try abc.ctx.memory();
        const bytes = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
        cap.appendSlice(abc.ctx.alloc, bytes) catch return WasiP2Error.OutOfMemory;
        return (async_mod.ReturnCode{ .completed = @intCast(count) }).encode();
    }
    // WASI-0.3 TCP send sink (phase C): drain the guest's bytes into the
    // connected socket.
    if (abc.ctx.host_tcp_tx.get(end.shared)) |role| {
        if (end.side != .writable) return WasiP2Error.InvalidHandle;
        const mem = try abc.ctx.memory();
        const io = try ctxIo(abc.ctx);
        const bytes = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
        const sock = try ctxTcpSocket(abc.ctx, role.rep);
        var off: usize = 0;
        while (off < bytes.len) {
            const n = sock.send(io, bytes[off..]) catch |e| {
                // Peer reset / shutdown: the send's result future carries
                // the error to the guest's `.await`.
                try abc.ctx.p3().resolve_send_future(abc.ctx, role.fut, abc.ctx.p3().sock_err_code(e));
                break;
            };
            if (n == 0) break;
            off += n;
        }
        return (async_mod.ReturnCode{ .completed = @intCast(count) }).encode();
    }
    // WASI-0.3 `read-directory` stream (ADR-0205 phase B): marshal
    // `directory-entry` records from the registered P1 readdir cursor.
    if (abc.ctx.host_dir_streams.get(end.shared)) |state_index| {
        if (end.side != .readable) return WasiP2Error.InvalidHandle;
        return abc.ctx.p3().dir_stream_read(abc.ctx, state_index, end, ptr, count);
    }
    // Host stream peer (Unit E, ADR-0190): the host is the always-ready reader,
    // so a guest write COMPLETES immediately — marshal the `count` u8s from guest
    // memory at `ptr` to the sink fd (the deferred ζ2 COMPLETION + marshalling).
    if (end.side == .writable) {
        if (abc.ctx.host_sinks.get(end.shared)) |fd| {
            const mem = try abc.ctx.memory();
            // D-335: `count` is in ELEMENTS; the byte span is count * elem_size.
            const bytes = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
            if (wasi_fd.writeSlice(abc.ctx.host, fd, bytes) != .success) return WasiP2Error.WriteFailed;
            return (async_mod.ReturnCode{ .completed = @intCast(count) }).encode();
        }
    }
    // Host stream SOURCE (Unit E3, the read direction): the host supplies bytes
    // from `fd` (stdin) → a guest read COMPLETES with the available count copied
    // into guest memory at `ptr`.
    if (end.side == .readable) {
        if (abc.ctx.host_sources.get(end.shared)) |_| {
            // WAIT-path (ADR-0191 E2c): when the source is "not ready", PARK —
            // record the read + return BLOCKED; the bytes are delivered at the
            // next `waitOn` (the guest reaches it after returning WAIT).
            if (abc.ctx.defer_host_source_reads) {
                try abc.ctx.pending_reads.put(abc.ctx.alloc, handle, .{ .ptr = ptr, .cap = count, .elem_size = abc.elem_size });
                end.state = .async_copying;
                return (async_mod.ReturnCode{ .blocked = {} }).encode();
            }
            const mem = try abc.ctx.memory();
            // D-335: `count` is in ELEMENTS; slice count*elem_size bytes, and
            // COMPLETE in elements (n bytes read / elem_size).
            const buf = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
            const n: u32 = @intCast(wasi_fd.readStdinSlice(abc.ctx.host, buf));
            return (async_mod.ReturnCode{ .completed = @intCast(n / abc.elem_size) }).encode();
        }
    }
    const sh = try abc.ctx.shared.get(end.shared);
    const step = switch (sh.*) {
        .stream => |*s| try end.copy(s, &abc.ctx.streams, handle, count),
        .future => |*f| try end.copy(f, &abc.ctx.streams, handle, count),
        .subtask => unreachable, // SharedTable never stores .subtask (subtask ends stay unlinked)
    };
    return switch (step.caller) {
        .blocked => blk: {
            // Remember a parked WRITE's source span: a host file role
            // registered after the fact (write-via-stream under
            // futures::join!) completes it at registration.
            if (end.kind == .stream and end.side == .writable)
                try abc.ctx.pending_writes.put(abc.ctx.alloc, handle, .{ .ptr = ptr, .count = count, .elem_size = abc.elem_size });
            // Remember a parked future READ's destination: a late host
            // resolution (tcp.send outcome at tx-drop / drain-error)
            // completes it in place (sock3ResolveSendFuture).
            if (end.kind == .future and end.side == .readable)
                try abc.ctx.pending_reads.put(abc.ctx.alloc, handle, .{ .ptr = ptr, .cap = count, .elem_size = abc.elem_size });
            break :blk (async_mod.ReturnCode{ .blocked = {} }).encode();
        },
        .dropped => (async_mod.ReturnCode{ .dropped = 0 }).encode(),
        // n==0 moves no bytes; n>0 needs marshalling at `ptr` (Unit E) and is
        // unreachable in the single-task model (no concurrent peer with data).
        .completed => |n| if (n == 0) (async_mod.ReturnCode{ .completed = 0 }).encode() else error.OutOfBounds,
    };
}

/// `canon stream.cancel-{read,write}` / `future.cancel-{read,write}` (ADR-0189
/// ζ2): cancel an async copy in flight on the end named by `handle`
/// (`StreamFutureEnd.cancel` traps `NotCopying` unless the end is async-copying)
/// and return the packed `ReturnCode.cancelled` (count of elements transferred
/// before cancel — 0 for a still-blocked copy).
pub fn p2StreamFutureCancel(caller: *Caller, handle: u32) WasiP2Error!u32 {
    return p2StreamFutureCancelInner(caller, handle) catch |e| mapAsyncFault(e);
}
fn p2StreamFutureCancelInner(caller: *Caller, handle: u32) WasiP2Error!u32 {
    const abc = caller.data(AsyncBuiltinCtx);
    const end = try abc.ctx.streams.get(handle);
    const sh = try abc.ctx.shared.get(end.shared);
    const n = switch (sh.*) {
        .stream => |*s| try end.cancel(s),
        .future => |*f| try end.cancel(f),
        .subtask => unreachable, // SharedTable never stores .subtask (subtask ends stay unlinked)
    };
    return (async_mod.ReturnCode{ .cancelled = @intCast(n) }).encode();
}

/// `canon stream.drop-{readable,writable}` / `future.drop-{readable,writable}`
/// (ADR-0189 ζ2): mark the shared rendezvous dropped (so a blocked peer observes
/// DROPPED — traps if a copy is mid-flight) then release the end + its shared ref
/// (freed when the second end drops).
pub fn p2StreamFutureDrop(caller: *Caller, handle: u32) WasiP2Error!void {
    return p2StreamFutureDropInner(caller, handle) catch |e| mapAsyncFault(e);
}
fn p2StreamFutureDropInner(caller: *Caller, handle: u32) WasiP2Error!void {
    const abc = caller.data(AsyncBuiltinCtx);
    const ctx = abc.ctx;
    // Handle + shared slot ids are free-list-reused: scrub the host-role side
    // tables BEFORE the drop, or a reused slot inherits the old role (a reused
    // result-future handle short-circuited a fresh stream's writes to
    // completed(0) — the official cli-stdio-roundtrip hang).
    if (ctx.streams.get(handle)) |end| {
        // Guest closed the write half of a `tcp.send` data stream =
        // `shutdown(SHUT_WR)` per the WIT ("closing the stream is
        // equivalent to shutdown(SHUT_WR)") — the peer must observe FIN or
        // its `receive` collect hangs (official sockets-tcp-send
        // test_drop_write_half).
        if (end.kind == .stream and end.side == .writable) {
            if (ctx.host_tcp_tx.get(end.shared)) |role| blk: {
                // The stream is exhausted: resolve the send future (ok
                // unless a drain error resolved it first).
                try ctx.p3().resolve_send_future(ctx, role.fut, null);
                const sock = ctx.tcpSocketRep(role.rep) orelse break :blk;
                const io = ctxIo(ctx) catch break :blk;
                if (dbg.on("async.host")) std.debug.print("[host] tx-drop shutdown(WR) handle={d} rep={d}\n", .{ handle, role.rep });
                // Destructor path — a shutdown failure (socket already
                // closed / reset) has no guest-visible surface; the peer
                // observes the close at socket teardown instead.
                // EXEMPT-FALLBACK: destructor, no guest surface (D-568)
                sock.shutdown(io, .send) catch {};
            }
        }
        // Dropping the read half of a `tcp.receive` stream =
        // `shutdown(SHUT_RD)` per the same WIT note (official
        // sockets-tcp-receive test_drop_read_half: a peer write after this
        // must surface an error).
        if (end.kind == .stream and end.side == .readable) {
            if (ctx.host_tcp_rx.get(end.shared)) |rep| blk: {
                const sock = ctx.tcpSocketRep(rep) orelse break :blk;
                const io = ctxIo(ctx) catch break :blk;
                // EXEMPT-FALLBACK: destructor, no guest surface (D-568)
                sock.shutdown(io, .recv) catch {};
            }
        }
        _ = ctx.host_result_futures.remove(handle);
        _ = ctx.pending_reads.remove(handle);
        _ = ctx.pending_writes.remove(handle);
        if (end.shared != 0 and (ctx.shared.refcountOf(end.shared) orelse 0) == 1) {
            _ = ctx.host_sinks.remove(end.shared);
            _ = ctx.host_sources.remove(end.shared);
            _ = ctx.host_file_streams.remove(end.shared);
            _ = ctx.host_dir_streams.remove(end.shared);
            _ = ctx.host_accept_streams.remove(end.shared);
            _ = ctx.host_tcp_rx.remove(end.shared);
            _ = ctx.host_tcp_tx.remove(end.shared);
            _ = ctx.blocked_socket_reads.remove(handle);
        }
    } else |_| {
        // Stale handle: dropEndGuarded below surfaces the guest fault.
    }
    // Shared drop contract: future-writable-before-write traps
    // (FutureDropBeforeWrite, mapAsyncFault → guest trap) + marks the rendezvous
    // DROPPED for the surviving peer (same helper the graph path uses).
    try async_mod.dropEndGuarded(&ctx.streams, &ctx.shared, handle);
}
