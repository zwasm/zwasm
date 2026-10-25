// FILE-SIZE-EXEMPT: single TcpSocket state machine (ADR-0180 transitions); a mid-machine split forces an N2 pub-leak of state helpers (investigated 2026-08-12, per ADR-0099)
//! WASI Preview 2 `wasi:sockets` host backing (ADR-0180 Phase 1).
//!
//! The TCP-client subset's OS-facing half: a `TcpSocket` state machine
//! (`wasi:sockets/tcp` documented transitions: unbound → bind-in-progress →
//! bound → connect-in-progress → connected) over `std.Io.net` (the pinned
//! Zig 0.16 stdlib has NO raw `std.posix` socket surface — networking is
//! io-based, the same discipline the WASI fs host already follows via
//! `host.io`). The component trampolines (impl-2) lower WIT records onto
//! this surface; nothing here touches guest memory.
//!
//! DIVERGENCE from the wasmtime shape (noted in ADR-0180): `std.Io.net`'s
//! `connect` is synchronous, so the OS connect executes inside
//! `start-connect` and `finish-connect` returns the cached result — the
//! guest-observable contract (validate at start; establishment failures
//! surface at finish) is preserved without an async runtime. Readiness for
//! the poll(2)-honest pollables still comes from `posix.poll` on the
//! socket handle (`ready`).
//!
//! Phase-2 DIVERGENCE (same root cause): the pinned stdlib has no
//! separate bind/listen steps for stream sockets (`netListenIp` is
//! socket+bind+listen atomically; `IpAddress.bind` is the DATAGRAM path),
//! so `start-bind` only validates + stores the address and the OS bind
//! executes inside `start-listen`. Consequences, both truthful:
//! bind-level failures (address-in-use, ...) surface at `finish-listen`
//! instead of `finish-bind`, and `local-address` of a `bound`-but-not-
//! listening socket reports the REQUESTED port (an ephemeral `:0` stays 0
//! until listen resolves it). A connected socket's endpoints are tracked
//! in explicit `local_addr`/`remote_addr` fields because the stdlib's
//! `Stream.socket.address` means DIFFERENT things per creation path
//! (connect: the getsockname/AFD-BIND-resolved LOCAL endpoint; accept:
//! the accept(2) PEER sockaddr).
//!
//! Zone 2 (`src/wasi/`). `std.Io.net` + `std.posix.poll` only — no new
//! libc surface (`libc_boundary`).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.Io.net;

/// `wasi:sockets/network` `error-code` — spec-pinned ordinals 0–20
/// (sockets.wit `enum error-code` declaration order).
pub const ErrorCode = enum(u8) {
    unknown = 0,
    access_denied = 1,
    not_supported = 2,
    invalid_argument = 3,
    out_of_memory = 4,
    timeout = 5,
    concurrency_conflict = 6,
    not_in_progress = 7,
    would_block = 8,
    invalid_state = 9,
    new_socket_limit = 10,
    address_not_bindable = 11,
    address_in_use = 12,
    remote_unreachable = 13,
    connection_refused = 14,
    connection_reset = 15,
    connection_aborted = 16,
    datagram_too_large = 17,
    name_unresolvable = 18,
    temporary_resolver_failure = 19,
    permanent_resolver_failure = 20,
};

/// `wasi:sockets/network` `ip-address-family` (enum: ipv4, ipv6).
pub const AddressFamily = enum(u8) { ipv4 = 0, ipv6 = 1 };

/// Map a Zig networking error onto the spec `error-code`. Errors with no
/// spec counterpart fall back to `unknown` (the spec's catch-all).
pub fn errorToCode(err: anyerror) ErrorCode {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.AddressFamilyUnsupported, error.ProtocolUnsupportedByAddressFamily, error.ProtocolUnsupportedBySystem, error.SocketModeUnsupported, error.OptionUnsupported => .not_supported,
        error.InvalidArgument, error.AddressUnavailable => .invalid_argument,
        error.SystemResources, error.OutOfMemory => .out_of_memory,
        error.ConnectionTimedOut, error.Timeout => .timeout,
        error.WouldBlock => .would_block,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => .new_socket_limit,
        error.AddressInUse => .address_in_use,
        error.NetworkUnreachable, error.NetworkDown, error.HostUnreachable => .remote_unreachable,
        error.ConnectionRefused => .connection_refused,
        error.ConnectionResetByPeer => .connection_reset,
        error.ConnectionAborted => .connection_aborted,
        error.MessageTooBig, error.MessageOversize => .datagram_too_large,
        else => .unknown,
    };
}

/// poll(2) interest bits, comptime-gated: `std.posix.POLL` is absent on
/// Windows. The windows values are LOCAL tags only — `afdPollOnce` maps
/// them onto AFD_POLL_* event masks (winsock is unusable on the pinned
/// stdlib's raw NT/AFD socket handles; see the AFD section below).
pub const POLL_IN: i16 = switch (builtin.os.tag) {
    .windows => 0x0001,
    else => posix.POLL.IN,
};
pub const POLL_OUT: i16 = switch (builtin.os.tag) {
    .windows => 0x0004,
    else => posix.POLL.OUT,
};

/// `wasi:sockets/tcp` documented state machine.
pub const TcpState = enum { unbound, bind_started, bound, connect_started, connected, listen_started, listening, closed };

/// Default listen backlog when the guest set none (matches the pinned
/// stdlib's `default_kernel_backlog`).
const default_backlog: u31 = 128;

/// TCP listen honouring the WIT `bind` contract: TIME_WAIT rebind ok,
/// live-listener rebind rejected with address-in-use.
///
/// POSIX gets `posixListen` (raw SO_REUSEADDR **without** SO_REUSEPORT). The
/// pinned stdlib couples SO_REUSEPORT into `reuse_address`, and clearing it
/// after bind is INEFFECTIVE on Linux — the bind bucket caches its
/// `fastreuseport` decision at the first bind, so a later second bind on the
/// live listener still joins the reuseport group and wrongly succeeds
/// (confirmed in `private/spikes/linux-reuseport-bind`). Raw composition never
/// sets SO_REUSEPORT, giving exactly the WIT semantics.
///
/// Windows composes its own AFD bind+listen (`winListen`): the stdlib's
/// listen path binds with the AFD REUSE share type even when
/// `reuse_address = false`, which lets a second bind on a live listener
/// wrongly succeed (see the AFD section below).
fn listenReuseAddr(io: std.Io, addr: net.IpAddress, backlog: u31) !net.Server {
    _ = io;
    if (builtin.os.tag == .windows) return winListen(addr, backlog);
    return posixListen(addr, backlog);
}

/// POSIX raw socket + SO_REUSEADDR-only + bind + listen, wrapped as a
/// `net.Server` (the fd then plugs into the stdlib accept path, whose
/// `AcceptOptions` is `void` on POSIX). See `listenReuseAddr` for why the
/// stdlib `reuse_address` cannot be used. ADR-0070 amendment: adds
/// `posix.system.{listen,getsockname}` to the raw-socket family already used
/// by `rawBoundConnect`.
fn posixListen(addr: net.IpAddress, backlog: u31) !net.Server {
    const af: c_uint = switch (addr) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
    const fd = posix.system.socket(af, posix.SOCK.STREAM, 0);
    if (posix.errno(fd) != .SUCCESS) return error.SystemResources;
    errdefer _ = posix.system.close(fd);
    const on = std.mem.toBytes(@as(c_int, 1));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &on);
    var storage: std.Io.Threaded.PosixAddress = undefined;
    const len = std.Io.Threaded.addressToPosix(&addr, &storage);
    switch (posix.errno(posix.system.bind(fd, &storage.any, len))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .ACCES => return error.AccessDenied,
        else => return error.Unexpected,
    }
    switch (posix.errno(posix.system.listen(fd, @intCast(backlog)))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => return error.Unexpected,
    }
    var resolved: std.Io.Threaded.PosixAddress = undefined;
    var rlen: posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    if (posix.errno(posix.system.getsockname(fd, &resolved.any, &rlen)) != .SUCCESS) return error.Unexpected;
    return .{ .socket = .{ .handle = fd, .address = std.Io.Threaded.addressFromPosix(&resolved) }, .options = {} };
}

/// One live TCP socket: spec state + the `std.Io.net` objects backing it.
/// The OS socket is created lazily by connect/listen (`std.Io.net` has no
/// bare-socket constructor; wasmtime is lazy the same way). The component
/// layer owns the resource handle; this struct owns the OS handle(s).
pub const TcpSocket = struct {
    family: AddressFamily,
    state: TcpState = .unbound,
    /// Stored by start-bind; the OS bind executes inside start-listen
    /// (see the Phase-2 DIVERGENCE note in the module docstring).
    bound_addr: ?net.IpAddress = null,
    /// Set once the connect succeeded (start-connect path).
    stream: ?net.Stream = null,
    /// OS-resolved local endpoint of a connected socket (connect path:
    /// the stdlib-resolved bind address; accept path: the listener's
    /// resolved endpoint).
    local_addr: ?net.IpAddress = null,
    /// Peer endpoint of a connected socket (connect path: the connect
    /// target; accept path: the accept(2) peer sockaddr).
    remote_addr: ?net.IpAddress = null,
    /// Set once the listen succeeded (start-listen path).
    server: ?net.Server = null,
    /// Establishment failure cached by start-connect, surfaced by
    /// finish-connect (the spec's two-phase contract).
    connect_err: ?anyerror = null,
    /// Bind/listen failure cached by start-listen, surfaced by finish-listen.
    listen_err: ?anyerror = null,
    /// `set-listen-backlog-size` before listen; applied at the OS listen.
    backlog: ?u31 = null,
    /// WASI-0.3 socket-option store (ADR-0205 phase C): the OS socket is
    /// lazy, so options are recorded (with the spec's clamp-permitting
    /// semantics) and read back from here; defaults per common OS defaults.
    opt_keep_alive: bool = false,
    opt_ka_idle_ns: u64 = 7200 * std.time.ns_per_s,
    opt_ka_interval_ns: u64 = 75 * std.time.ns_per_s,
    opt_ka_count: u32 = 9,
    opt_hop_limit: u8 = 64,
    opt_rcvbuf: u64 = 64 * 1024,
    opt_sndbuf: u64 = 64 * 1024,
    /// WASI-0.3 `receive` is single-shot per socket: a second call must
    /// fail invalid-state (official sockets-tcp-receive
    /// test_multiple_receive). Set by the component layer when it mints
    /// the rx stream.
    rx_taken: bool = false,

    /// `tcp-create-socket.create-tcp-socket` — records the family; the OS
    /// socket is created by the first connect/listen.
    pub fn create(family: AddressFamily) TcpSocket {
        return .{ .family = family };
    }

    pub fn deinit(self: *TcpSocket, io: std.Io) void {
        if (self.stream) |s| s.close(io);
        if (self.server) |*s| s.deinit(io);
        self.stream = null;
        self.server = null;
        self.state = .closed;
    }

    /// `tcp.start-bind`. Validates + stores the address; the OS bind is
    /// deferred to start-listen (Phase-2 DIVERGENCE, module docstring).
    pub fn startBind(self: *TcpSocket, io: std.Io, addr: net.IpAddress) !void {
        _ = io;
        if (self.state != .unbound) return error.InvalidState;
        if (!familyMatches(self.family, addr)) return error.InvalidArgument;
        self.bound_addr = addr;
        self.state = .bind_started;
    }

    /// `tcp.finish-bind`.
    pub fn finishBind(self: *TcpSocket) !void {
        if (self.state != .bind_started) return error.NotInProgress;
        self.state = .bound;
    }

    /// `tcp.start-listen`. The OS socket+bind+listen executes here
    /// (`netListenIp` is atomic in the pinned stdlib); failures are cached
    /// for finish-listen (the spec's two-phase contract).
    pub fn startListen(self: *TcpSocket, io: std.Io) !void {
        if (self.state != .bound) return error.InvalidState;
        const addr = self.bound_addr.?; // .bound implies a stored address
        self.state = .listen_started;
        self.server = listenReuseAddr(io, addr, self.backlog orelse default_backlog) catch |err| {
            self.listen_err = err;
            return;
        };
    }

    /// `tcp.finish-listen` — the cached start-listen result.
    pub fn finishListen(self: *TcpSocket) !void {
        if (self.state != .listen_started) return error.NotInProgress;
        if (self.listen_err) |err| {
            self.state = .closed;
            return err;
        }
        self.state = .listening;
    }

    /// WASI-0.3 one-shot `bind` (ADR-0205 phase C): the OS bind executes NOW
    /// so `get-local-address` reports the resolved ephemeral port (the 0.2
    /// path defers to listen). Implemented as an immediate listen-capable
    /// socket held in the `.bound` state; `listenNow` is then a pure state
    /// transition.
    pub fn bindNow(self: *TcpSocket, io: std.Io) !void {
        if (self.state != .bound) return error.InvalidState;
        const addr = self.bound_addr.?;
        self.server = listenReuseAddr(io, addr, self.backlog orelse default_backlog) catch |err| {
            self.state = .closed;
            return err;
        };
        self.bound_addr = self.server.?.socket.address;
    }

    /// WASI-0.3 `listen` on a `bindNow`-bound socket (or an unbound one via
    /// an implicit any-address bind).
    pub fn listenNow(self: *TcpSocket, io: std.Io) !void {
        if (self.state == .listening) return error.AlreadyListening;
        if (self.state == .unbound) {
            const any: net.IpAddress = switch (self.family) {
                .ipv4 => .{ .ip4 = net.Ip4Address.parse("0.0.0.0", 0) catch unreachable },
                .ipv6 => .{ .ip6 = net.Ip6Address.parse("::", 0) catch unreachable },
            };
            try self.startBind(io, any);
            try self.finishBind();
            try self.bindNow(io);
        }
        if (self.state != .bound or self.server == null) return error.InvalidState;
        self.state = .listening;
    }

    /// `tcp.set-listen-backlog-size` — stored and applied at the OS listen.
    /// Updating a LIVE listener is optional per spec; truthful not-supported.
    pub fn setListenBacklog(self: *TcpSocket, value: u64) !void {
        if (value == 0) return error.InvalidArgument;
        switch (self.state) {
            .listen_started, .listening => return error.OptionUnsupported,
            .closed => return error.InvalidState,
            .unbound, .bind_started, .bound, .connect_started, .connected => {},
        }
        self.backlog = std.math.cast(u31, value) orelse std.math.maxInt(u31);
    }

    /// `tcp.accept` — non-blocking: `would-block` unless poll(2) reports a
    /// queued connection. On success mints the accepted socket as a fresh
    /// `connected` TcpSocket (the component layer registers the resource
    /// and pairs the streams, same as finish-connect).
    pub fn accept(self: *TcpSocket, io: std.Io) !TcpSocket {
        if (self.state != .listening) return error.InvalidState;
        const srv = &self.server.?;
        if (!try pollOnce(srv.socket.handle, POLL_IN)) return error.WouldBlock;
        const stream = try srv.accept(io);
        return .{
            .family = self.family,
            .state = .connected,
            .stream = stream,
            .local_addr = srv.socket.address,
            .remote_addr = stream.socket.address,
        };
    }

    /// `tcp.remote-address` — the peer endpoint of a connected socket.
    pub fn remoteAddress(self: *TcpSocket) !net.IpAddress {
        if (self.state != .connected) return error.InvalidState;
        return self.remote_addr.?;
    }

    /// `tcp.local-address`. Listening sockets report the RESOLVED address
    /// (ephemeral `:0` becomes the real port); `bound` reports the stored
    /// request; connected sockets the OS-resolved endpoint (module
    /// docstring on the per-path `Stream.socket.address` semantics).
    pub fn localAddress(self: *TcpSocket) !net.IpAddress {
        return switch (self.state) {
            .listening => self.server.?.socket.address,
            .bound => self.bound_addr.?,
            .connected => self.local_addr.?,
            .unbound, .bind_started, .connect_started, .listen_started, .closed => error.InvalidState,
        };
    }

    /// `tcp.start-connect`. The synchronous `std.Io.net` connect executes
    /// here; a failure is cached for finish-connect (see module docstring).
    /// Connecting FROM an explicitly bound socket is `connectFromBound`
    /// (the WASI-0.3 path) — the 0.2 deferred-bind path stays truthful
    /// not-supported.
    pub fn startConnect(self: *TcpSocket, io: std.Io, addr: net.IpAddress) !void {
        if (self.state == .bound or self.state == .bind_started) return error.OptionUnsupported;
        if (self.state != .unbound) return error.InvalidState;
        if (!familyMatches(self.family, addr)) return error.InvalidArgument;
        self.state = .connect_started;
        if (builtin.os.tag == .windows) {
            // Own AFD path: the stdlib windows connect maps no failure
            // statuses (CONNECTION_REFUSED etc. surface as Unexpected).
            const any: net.IpAddress = switch (self.family) {
                .ipv4 => .{ .ip4 = net.Ip4Address.parse("0.0.0.0", 0) catch unreachable },
                .ipv6 => .{ .ip6 = net.Ip6Address.parse("::", 0) catch unreachable },
            };
            const handle = winBoundConnect(self.family, any, addr) catch |err| {
                self.connect_err = err;
                return;
            };
            const local = winAfdGetSockName(handle) catch any;
            self.stream = .{ .socket = .{ .handle = handle, .address = local } };
            self.local_addr = local;
            self.remote_addr = addr;
            return;
        }
        self.stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
            self.connect_err = err;
            return;
        };
        self.local_addr = self.stream.?.socket.address;
        self.remote_addr = addr;
    }

    /// WASI-0.3 `connect` on an explicitly BOUND socket (official
    /// sockets-tcp-connect test_explicit_bind): the `bindNow` placeholder
    /// listener is dropped and a fresh socket re-binds the SAME resolved
    /// address then connects — raw posix composition with SO_REUSEADDR on
    /// POSIX (`rawBoundConnect`), the own AFD bind+connect on windows
    /// (`winBoundConnect`; the just-released port rebinds under the
    /// windows default semantics without a reuse option).
    pub fn connectFromBound(self: *TcpSocket, io: std.Io, addr: net.IpAddress) !void {
        if (self.state != .bound or self.server == null) return error.InvalidState;
        if (!familyMatches(self.family, addr)) return error.InvalidArgument;
        const local = self.bound_addr.?; // bindNow resolved it
        self.server.?.deinit(io);
        self.server = null;
        self.state = .connect_started;
        const handle = (if (builtin.os.tag == .windows)
            winBoundConnect(self.family, local, addr)
        else
            rawBoundConnect(local, addr)) catch |err| {
            self.connect_err = err;
            return;
        };
        self.stream = .{ .socket = .{ .handle = handle, .address = local } };
        self.local_addr = local;
        self.remote_addr = addr;
    }

    /// `tcp.finish-connect` — the cached start-connect result.
    pub fn finishConnect(self: *TcpSocket) !void {
        if (self.state != .connect_started) return error.NotInProgress;
        if (self.connect_err) |err| {
            self.state = .closed;
            return err;
        }
        self.state = .connected;
    }

    /// Socket-backed input-stream `read` (one-shot; blocks under the
    /// Threaded io until data arrives — the `blocking-read` contract; the
    /// non-blocking `read` trampoline gates on `ready` first).
    pub fn recv(self: *TcpSocket, io: std.Io, buf: []u8) !usize {
        const stream = self.connectedStream() orelse return error.InvalidState;
        var bufs = [_][]u8{buf};
        return netRead(io, stream.socket.handle, &bufs);
    }

    /// Socket-backed output-stream `write` (one-shot).
    pub fn send(self: *TcpSocket, io: std.Io, bytes: []const u8) !usize {
        const stream = self.connectedStream() orelse return error.InvalidState;
        if (builtin.os.tag == .windows) return winAfdSend(stream.socket.handle, bytes);
        const data = [_][]const u8{bytes};
        return netWrite(io, stream.socket.handle, &data);
    }

    /// Readiness for the poll(2)-honest pollable (ADR-0180): is the
    /// connected socket ready for `interest` (POLL.IN / POLL.OUT) now?
    /// A listening socket's POLL.IN = "a connection is queued for accept".
    pub fn ready(self: *TcpSocket, interest: i16) !bool {
        if (self.state == .listening) return pollOnce(self.server.?.socket.handle, interest);
        const stream = self.connectedStream() orelse return error.InvalidState;
        return pollOnce(stream.socket.handle, interest);
    }

    /// `tcp.shutdown(shutdown-type)` — half/full-close a connected socket.
    pub fn shutdown(self: *TcpSocket, io: std.Io, how: net.ShutdownHow) !void {
        const stream = self.connectedStream() orelse return error.InvalidState;
        try stream.shutdown(io, how);
    }

    fn connectedStream(self: *TcpSocket) ?net.Stream {
        if (self.state != .connected) return null;
        return self.stream;
    }
};

/// One live UDP socket (WASI-0.3 `wasi:sockets` `udp-socket`, ADR-0205 phase
/// C): `IpAddress.bind(mode=.dgram)` backs the bound/implicit-bind states;
/// the WIT `connect` on an UNBOUND socket is a real OS connect (the pinned
/// stdlib's dgram connect resolves the implicit-bind LOCAL address via
/// getsockname — the official udp-connect test expects 127.0.0.1 back, not
/// the wildcard).
pub const UdpSocket = struct {
    family: AddressFamily,
    socket: ?net.Socket = null,
    bound_addr: ?net.IpAddress = null,
    remote: ?net.IpAddress = null,
    /// Socket created by an OS-level dgram connect: sends go through the
    /// connected fd (a sendto WITH an address on it is EISCONN — an
    /// errnoBug panic in the pinned stdlib).
    os_connected: bool = false,
    opt_hop_limit: u8 = 64,
    opt_rcvbuf: u64 = 64 * 1024,
    opt_sndbuf: u64 = 64 * 1024,

    pub fn create(family: AddressFamily) UdpSocket {
        return .{ .family = family };
    }

    pub fn deinit(self: *UdpSocket, io: std.Io) void {
        if (self.socket) |*sock| sock.close(io);
        self.socket = null;
    }

    pub fn bind(self: *UdpSocket, io: std.Io, addr: net.IpAddress) !void {
        if (self.socket != null) return error.InvalidState;
        if (!familyMatches(self.family, addr)) return error.InvalidArgument;
        if (builtin.os.tag == .windows) {
            // Own AFD bind: the stdlib swallows the NT address statuses
            // (doc-address bind must surface AddressUnavailable, not io).
            self.socket = try winUdpBind(self.family, addr);
            self.bound_addr = self.socket.?.address;
            return;
        }
        var a = addr;
        self.socket = a.bind(io, .{ .mode = .dgram }) catch |e| return e;
        self.bound_addr = a;
    }

    /// The WIT's implicit bind (send-to on an unbound socket).
    pub fn ensureBound(self: *UdpSocket, io: std.Io) !void {
        if (self.socket != null) return;
        var any: net.IpAddress = switch (self.family) {
            .ipv4 => .{ .ip4 = net.Ip4Address.parse("0.0.0.0", 0) catch unreachable },
            .ipv6 => .{ .ip6 = net.Ip6Address.parse("::", 0) catch unreachable },
        };
        if (builtin.os.tag == .windows) {
            self.socket = try winUdpBind(self.family, any);
            self.bound_addr = self.socket.?.address;
            return;
        }
        self.socket = any.bind(io, .{ .mode = .dgram }) catch |e| return e;
        self.bound_addr = any;
    }

    pub fn connect(self: *UdpSocket, io: std.Io, addr: net.IpAddress) !void {
        if (!familyMatches(self.family, addr)) return error.InvalidArgument;
        if (builtin.os.tag == .windows) {
            // AFD dgram connect on the (implicitly) bound handle. The stdlib
            // connect path is unusable here: it sets SO_REUSE_UNICASTPORT,
            // which AFD rejects with INVALID_PARAMETER on datagram sockets.
            try self.ensureBound(io);
            try winAfdConnect(self.socket.?.handle, addr);
            // The connect rewrites the local endpoint to the route source
            // (the same getsockname truth the POSIX path observes) — the
            // received-datagram `sender` must equal it.
            self.socket.?.address = try winAfdGetSockName(self.socket.?.handle);
            self.bound_addr = self.socket.?.address;
            self.os_connected = true;
            self.remote = addr;
            return;
        }
        if (self.socket != null and !self.os_connected) {
            // Explicitly bound: the local endpoint is already resolved, so
            // connect stays the WIT's "local socket configuration" filter.
            self.remote = addr;
            return;
        }
        // Unbound, or a re-connect of an OS-connected socket: a fresh OS
        // dgram connect (the pinned stdlib has no connect-existing-fd).
        var a = addr;
        const stream = a.connect(io, .{ .mode = .dgram, .protocol = .udp }) catch |e| return e;
        if (self.socket) |*old| old.close(io);
        self.socket = stream.socket;
        self.bound_addr = stream.socket.address;
        self.os_connected = true;
        self.remote = addr;
    }

    pub fn disconnect(self: *UdpSocket, io: std.Io) !void {
        if (self.remote == null) return error.InvalidState;
        if (self.os_connected) {
            // No AF_UNSPEC dissolve in the pinned stdlib: drop the fd (the
            // socket returns to the unbound state; nothing observable in
            // the WIT contract retains the local port across disconnect).
            if (self.socket) |*sock| sock.close(io);
            self.socket = null;
            self.bound_addr = null;
            self.os_connected = false;
        }
        self.remote = null;
    }

    pub fn sendTo(self: *UdpSocket, io: std.Io, dest: net.IpAddress, bytes: []const u8) !void {
        // The UDP length field is 16-bit including its 8-byte header, so a
        // payload over 65507 (v4, incl. the 20-byte IP header) / 65527 (v6)
        // can never be sent — pre-checked because the windows AFD status for
        // it is unmapped (POSIX would say EMSGSIZE, the same error).
        const max_payload: usize = switch (self.family) {
            .ipv4 => 65507,
            .ipv6 => 65527,
        };
        if (bytes.len > max_payload) return error.MessageOversize;
        if (self.os_connected) {
            const data = [_][]const u8{bytes};
            _ = try netWrite(io, self.socket.?.handle, &data);
            return;
        }
        try self.ensureBound(io);
        try self.socket.?.send(io, &dest, bytes);
    }

    /// POLL.IN readiness: a datagram is queued for `receiveFrom`.
    pub fn readyIn(self: *UdpSocket) !bool {
        const sock = self.socket orelse return error.InvalidState;
        return pollOnce(sock.handle, POLL_IN);
    }

    pub fn receiveFrom(self: *UdpSocket, io: std.Io, buf: []u8) !struct { n: usize, from: net.IpAddress } {
        const sock = self.socket orelse return error.InvalidState;
        const msg = try sock.receive(io, buf);
        return .{ .n = msg.data.len, .from = msg.from };
    }

    pub fn localAddress(self: *UdpSocket) !net.IpAddress {
        const sock = self.socket orelse return error.InvalidState;
        // The bind-resolved address (ephemeral `:0` becomes the real port —
        // `Socket.address` carries the OS-resolved sockaddr).
        return sock.address;
    }

    pub fn remoteAddress(self: *UdpSocket) !net.IpAddress {
        return self.remote orelse error.InvalidState;
    }
};

/// Raw socket+SO_REUSEADDR+bind+connect composition (ADR-0070 amendment
/// 2026-08-11): the pinned `std.Io.net` cannot connect FROM a bound socket,
/// so the WASI-0.3 bind→connect transition composes one from
/// `posix.system` primitives (= libc on every zwasm build — `link_libc` is
/// always on) and the PUBLIC `std.Io.Threaded` sockaddr converters. The fd
/// then plugs into the normal `net.Stream` vtable paths (read/write/poll/
/// shutdown/close all take the handle). No CLOEXEC: the portable c surface
/// has no SOCK_CLOEXEC, and zwasm never execs.
fn rawBoundConnect(local: net.IpAddress, remote: net.IpAddress) !net.Socket.Handle {
    if (builtin.os.tag == .windows) return error.OptionUnsupported;
    const af: c_uint = switch (local) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
    const fd = posix.system.socket(af, posix.SOCK.STREAM, 0);
    if (posix.errno(fd) != .SUCCESS) return error.SystemResources;
    errdefer _ = posix.system.close(fd);
    // SO_REUSEADDR pre-bind: the same WIT bind contract as the listen
    // paths (TIME_WAIT must not block the rebind).
    const on = std.mem.toBytes(@as(c_int, 1));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &on);
    var local_storage: std.Io.Threaded.PosixAddress = undefined;
    const local_len = std.Io.Threaded.addressToPosix(&local, &local_storage);
    switch (posix.errno(posix.system.bind(fd, &local_storage.any, local_len))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .ACCES => return error.AccessDenied,
        else => return error.Unexpected,
    }
    var remote_storage: std.Io.Threaded.PosixAddress = undefined;
    const remote_len = std.Io.Threaded.addressToPosix(&remote, &remote_storage);
    switch (posix.errno(posix.system.connect(fd, &remote_storage.any, remote_len))) {
        .SUCCESS => {},
        .CONNREFUSED => return error.ConnectionRefused,
        .TIMEDOUT => return error.ConnectionTimedOut,
        .NETUNREACH => return error.NetworkUnreachable,
        .HOSTUNREACH => return error.HostUnreachable,
        .ADDRINUSE => return error.AddressInUse,
        else => return error.Unexpected,
    }
    return fd;
}

/// `resolve-addresses` failure classes, mirroring the ip-name-lookup WIT's
/// own error-code variant (mapped to its ordinals by the component layer).
pub const ResolveError = error{
    InvalidName,
    NameUnresolvable,
    TemporaryResolverFailure,
    PermanentResolverFailure,
    ResolverFailure,
};

/// `wasi:sockets/ip-name-lookup.resolve-addresses` core: IP literals parse
/// locally (the WIT fast path — no external request); everything else goes
/// through the pinned stdlib's real resolver (/etc/hosts + resolv.conf DNS
/// on POSIX). v4-mapped v6 results are dropped per the WIT ("never returns
/// IPv4-mapped IPv6 addresses"); an empty post-filter result is
/// name-unresolvable ("never succeeds with 0 results"). Completes eagerly
/// (async-eager, ADR-0205 D5) — resolver latency blocks the runtime, the
/// same class as the documented http-send eager path.
pub fn resolveAddresses(io: std.Io, name: []const u8, out: []net.IpAddress) (ResolveError || error{Canceled})!usize {
    if (net.IpAddress.parse(name, 0)) |a| {
        out[0] = a;
        return 1;
    } else |_| {
        // Not a literal — fall through to the resolver.
    }
    const hn = net.HostName.init(name) catch return error.InvalidName;
    var buffer: [32]net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(net.HostName.LookupResult) = .init(&buffer);
    hn.lookup(io, &queue, .{ .port = 0 }) catch |e| return switch (e) {
        error.UnknownHostName, error.NoAddressReturned => error.NameUnresolvable,
        error.NameServerFailure => error.TemporaryResolverFailure,
        error.InvalidDnsARecord, error.InvalidDnsAAAARecord, error.InvalidDnsCnameRecord => error.PermanentResolverFailure,
        error.Canceled => error.Canceled,
        else => error.ResolverFailure,
    };
    var n: usize = 0;
    while (queue.getOne(io)) |r| switch (r) {
        .address => |a| {
            if (n < out.len and !isV4MappedV6(a)) {
                out[n] = a;
                n += 1;
            }
        },
        .canonical_name => {},
    } else |err| switch (err) {
        error.Closed => {},
        error.Canceled => return error.Canceled,
    }
    if (n == 0) return error.NameUnresolvable;
    return n;
}

fn isV4MappedV6(addr: net.IpAddress) bool {
    return switch (addr) {
        .ip4 => false,
        .ip6 => |a| std.mem.allEqual(u8, a.bytes[0..10], 0) and a.bytes[10] == 0xff and a.bytes[11] == 0xff,
    };
}

fn familyMatches(family: AddressFamily, addr: net.IpAddress) bool {
    return switch (addr) {
        .ip4 => family == .ipv4,
        .ip6 => family == .ipv6,
    };
}

/// `Io.VTable.netRead` / `netWrite` of Zig 0.16, which 0.17 folded into
/// `io.operate`.
pub fn netRead(io: std.Io, handle: net.Socket.Handle, data: [][]u8) !usize {
    return (try (try io.operate(.{ .net_read = .{ .socket_handle = handle, .data = data } })).net_read).data_len;
}

pub fn netWrite(io: std.Io, handle: net.Socket.Handle, data: []const []const u8) !usize {
    return (try io.operate(.{ .net_write = .{ .socket_handle = handle, .data = data } })).net_write;
}

/// One zero-timeout poll(2) on a single socket handle: true iff `interest`
/// (or an error/hup condition, which also unblocks a waiter) is pending.
fn pollOnce(handle: net.Socket.Handle, interest: i16) !bool {
    switch (builtin.os.tag) {
        .windows => return afdPollOnce(handle, interest),
        else => {
            var fds = [_]posix.pollfd{.{ .fd = handle, .events = interest, .revents = 0 }};
            const n = try posix.poll(&fds, 0);
            return n > 0 and (fds[0].revents & (interest | posix.POLL.ERR | posix.POLL.HUP)) != 0;
        },
    }
}

// ---- Windows readiness: IOCTL_AFD_POLL (D-319 probes #3/#4) ----
//
// The pinned `std.Io.net` windows backend drives sockets as raw NT/AFD
// handles: winsock is never initialized AND the handles are not
// winsock-registered SOCKETs (WSAPoll fails WSAENOTSOCK even after
// WSAStartup). Readiness therefore uses the NT-native AFD poll ioctl on
// the socket handle itself — the wepoll/libuv/mio approach — with a
// zero timeout (snapshot semantics: STATUS_TIMEOUT/0 handles = not
// ready).

const win = std.os.windows;

const AFD_POLL_RECEIVE: u32 = 0x0001;
const AFD_POLL_SEND: u32 = 0x0004;
const AFD_POLL_DISCONNECT: u32 = 0x0008;
const AFD_POLL_ABORT: u32 = 0x0010;
const AFD_POLL_ACCEPT: u32 = 0x0080;
const AFD_POLL_CONNECT_FAIL: u32 = 0x0100;

const AfdPollHandleInfo = extern struct {
    handle: win.HANDLE,
    events: u32,
    status: win.NTSTATUS,
};

const AfdPollInfo = extern struct {
    timeout: i64,
    number_of_handles: u32,
    exclusive: u32,
    handles: [1]AfdPollHandleInfo,
};

/// IOCTL_AFD_POLL (0x00012024).
const AFD_POLL_CTL: win.CTL_CODE = @bitCast(@as(u32, 0x00012024));

fn afdPollOnce(handle: net.Socket.Handle, interest: i16) !bool {
    if (builtin.os.tag != .windows) unreachable;
    const want: u32 = blk: {
        var w: u32 = 0;
        if (interest & POLL_IN != 0) w |= AFD_POLL_RECEIVE | AFD_POLL_DISCONNECT | AFD_POLL_ABORT | AFD_POLL_ACCEPT | AFD_POLL_CONNECT_FAIL;
        if (interest & POLL_OUT != 0) w |= AFD_POLL_SEND;
        break :blk w;
    };
    var info: AfdPollInfo = .{
        .timeout = 0, // snapshot: expire immediately when nothing is ready
        .number_of_handles = 1,
        .exclusive = 0,
        .handles = .{.{ .handle = handle, .events = want, .status = .SUCCESS }},
    };
    var iosb: win.IO_STATUS_BLOCK = undefined;
    const status = win.ntdll.NtDeviceIoControlFile(
        handle,
        null,
        null,
        null,
        &iosb,
        AFD_POLL_CTL,
        &info,
        @sizeOf(AfdPollInfo),
        &info,
        @sizeOf(AfdPollInfo),
    );
    switch (status) {
        .SUCCESS => {},
        .TIMEOUT => return false, // nothing ready within the zero timeout
        else => {
            // D-319 probe diagnostic: name the NTSTATUS on failure.
            std.log.scoped(.zwasm_sockets).warn("IOCTL_AFD_POLL failed: NTSTATUS=0x{x} (handle=0x{x}, want=0x{x})", .{ @backingInt(status), @intFromPtr(handle), want });
            return error.Unexpected;
        },
    }
    if (info.number_of_handles == 0) return false;
    return (info.handles[0].events & want) != 0;
}

// ---- Windows AFD control plane (bind / listen / dgram connect) ----
//
// Why not the pinned stdlib here: `netListenIpWindows` binds with AFD
// ShareType 1, whose NT semantics are SHARE-REUSE (the zig enum names
// {Unix,Passive,Active} mislead — the numeric values mean
// UNIQUE/REUSE/WILDCARD), so a second bind on a live listener wrongly
// succeeds — breaking the WIT address-in-use contract. And
// `netConnectIpWindows` sets SO_REUSE_UNICASTPORT unconditionally, which
// AFD rejects with INVALID_PARAMETER on datagram sockets. These helpers
// compose the same NT ioctls with a UNIQUE-share bind, no unicast-port
// option, and the address-status mapping the stdlib swallows
// (INVALID_ADDRESS_COMPONENT → AddressUnavailable, the WIT
// address-not-bindable). The produced handles plug into the stdlib data
// plane unchanged (netSend / netReceive / netAccept take the raw handle).

/// AFD BIND ShareType UNIQUE (0): the plain no-REUSEADDR winsock bind —
/// live-port rebind rejected, TIME_WAIT rebind allowed (windows default).
const AFD_SHARE_UNIQUE: win.AFD.BIND_INFO.MODE = @fromBackingInt(@intCast(0));

const WinAfdResult = struct { status: win.NTSTATUS, information: usize };

/// Issue one AFD ioctl, waiting on an NT event when the asynchronous
/// endpoint returns PENDING (the D-319 poll path never PENDs because of its
/// zero timeout; bind/listen/connect/send can).
fn winAfdControl(handle: win.HANDLE, code: win.CTL_CODE, in_buf: []const u8, out_buf: []u8) !WinAfdResult {
    var event: win.HANDLE = undefined;
    if (win.ntdll.NtCreateEvent(
        &event,
        .{ .STANDARD = .{ .SYNCHRONIZE = true }, .SPECIFIC = .{ .bits = 0x3 } },
        null,
        .Notification,
        .FALSE,
    ) != .SUCCESS) return error.Unexpected;
    defer win.CloseHandle(event);
    var iosb: win.IO_STATUS_BLOCK = undefined;
    var status = win.ntdll.NtDeviceIoControlFile(
        handle,
        event,
        null,
        null,
        &iosb,
        code,
        if (in_buf.len > 0) in_buf.ptr else null,
        @intCast(in_buf.len),
        if (out_buf.len > 0) out_buf.ptr else null,
        @intCast(out_buf.len),
    );
    if (status == .PENDING) {
        _ = win.ntdll.NtWaitForSingleObject(event, .FALSE, null);
        status = iosb.u.Status;
    }
    return .{ .status = status, .information = iosb.Information };
}

/// NtCreateFile on \Device\Afd\Endpoint with the socket open-packet EA —
/// the same endpoint shape the stdlib data plane drives.
fn winOpenSocketAfd(family: AddressFamily, mode: net.Socket.Mode) !win.HANDLE {
    const af: win.LONG = switch (family) {
        .ipv4 => 2, // AF_INET
        .ipv6 => 23, // AF_INET6
    };
    const sock_type: win.LONG = switch (mode) {
        .stream => 1, // SOCK_STREAM
        .dgram => 2, // SOCK_DGRAM
        .seqpacket, .raw, .rdm => return error.Unexpected,
    };
    const proto: win.LONG = switch (mode) {
        .stream => 6, // IPPROTO_TCP
        .dgram => 17, // IPPROTO_UDP
        .seqpacket, .raw, .rdm => return error.Unexpected,
    };
    var handle: win.HANDLE = undefined;
    var iosb: win.IO_STATUS_BLOCK = undefined;
    return switch (win.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{ .RIGHTS = .{ .WRITE_DAC = true }, .SYNCHRONIZE = true },
            .GENERIC = .{ .WRITE = true, .READ = true },
        },
        &.{
            .ObjectName = @constCast(&win.UNICODE_STRING.init(
                win.AFD.DEVICE_NAME ++ .{ '\\', 'E', 'n', 'd', 'p', 'o', 'i', 'n', 't' },
            )),
        },
        &iosb,
        null,
        .{},
        .{ .READ = true, .WRITE = true },
        .OPEN_IF,
        .{ .IO = .ASYNCHRONOUS },
        &win.AFD.OPEN_PACKET.FULL_EA_INFORMATION{ .Value = .{
            .EndpointType = .{
                .CONNECTIONLESS = mode == .dgram,
                .MESSAGEMODE = mode == .dgram,
                .RAW = false,
            },
            .GroupID = 0,
            .AddressFamily = af,
            .SocketType = sock_type,
            .Protocol = proto,
            .TransportDeviceNameLength = 0,
            .TransportDeviceName = undefined,
        } },
        @sizeOf(win.AFD.OPEN_PACKET.FULL_EA_INFORMATION),
    )) {
        .SUCCESS => handle,
        .PROTOCOL_NOT_SUPPORTED, .NO_SUCH_FILE => error.Unexpected,
        else => error.Unexpected,
    };
}

/// IOCTL_AFD_BIND with UNIQUE share, mapping the address statuses to the
/// WIT bind contract. Returns the OS-resolved local address (ephemeral
/// ports resolve here).
fn winAfdBind(handle: win.HANDLE, addr: net.IpAddress) !net.IpAddress {
    const Storage = extern struct { Info: win.AFD.BIND_INFO, Address: std.Io.Threaded.PosixAddress };
    var storage: Storage = .{ .Info = .{ .Mode = AFD_SHARE_UNIQUE }, .Address = undefined };
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &storage.Address);
    const in_bytes = @as([]const u8, @ptrCast(&storage))[0 .. @offsetOf(Storage, "Address") + addr_len];
    const out_bytes = @as([]u8, @ptrCast(&storage.Address))[0..addr_len];
    switch ((try winAfdControl(handle, win.IOCTL.AFD.BIND, in_bytes, out_bytes)).status) {
        .SUCCESS => {},
        .SHARING_VIOLATION, .ADDRESS_ALREADY_EXISTS => return error.AddressInUse,
        .INVALID_ADDRESS_COMPONENT, .INVALID_ADDRESS => return error.AddressUnavailable,
        .ACCESS_DENIED => return error.AccessDenied,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => return error.Unexpected,
    }
    return std.Io.Threaded.addressFromPosix(&storage.Address);
}

/// IOCTL_AFD_START_LISTEN (the stdlib shape, minus its REUSE-share bind).
fn winAfdListen(handle: win.HANDLE, backlog: u31) !void {
    const info: win.AFD.LISTEN_INFO = .{
        .UseSAN = .FALSE,
        .MaximumConnectionQueue = backlog,
        .UseDelayedAcceptance = .FALSE,
    };
    switch ((try winAfdControl(handle, win.IOCTL.AFD.START_LISTEN, std.mem.asBytes(&info), &.{})).status) {
        .SUCCESS => {},
        .SHARING_VIOLATION, .ADDRESS_ALREADY_EXISTS => return error.AddressInUse,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => return error.Unexpected,
    }
}

/// IOCTL_AFD_CONNECT for datagram sockets (sets the default peer). The
/// stream path stays on the stdlib (its SO_REUSE_UNICASTPORT is valid
/// there); dgram must avoid it.
fn winAfdConnect(handle: win.HANDLE, addr: net.IpAddress) !void {
    const Storage = extern struct { Reserved0: [3]usize = @splat(0), Address: std.Io.Threaded.PosixAddress };
    var storage: Storage = .{ .Address = undefined };
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &storage.Address);
    const in_bytes = @as([]const u8, @ptrCast(&storage))[0 .. @offsetOf(Storage, "Address") + addr_len];
    switch ((try winAfdControl(handle, win.IOCTL.AFD.CONNECT, in_bytes, &.{})).status) {
        .SUCCESS => {},
        .INVALID_ADDRESS_COMPONENT, .INVALID_ADDRESS => return error.AddressUnavailable,
        .CONNECTION_REFUSED => return error.ConnectionRefused,
        .NETWORK_UNREACHABLE => return error.NetworkUnreachable,
        .HOST_UNREACHABLE => return error.HostUnreachable,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => return error.Unexpected,
    }
}

/// IOCTL_AFD_GET_ADDRESS (getsockname): the OS-truth local endpoint. The
/// output is a plain sockaddr at offset 0 (NOT the TDI_ADDRESS_INFO shape
/// documentation suggests — verified by byte dump on real Windows:
/// `0200 <port> 7f000001…` for v4, `1700 <port> …` for v6).
fn winAfdGetSockName(handle: win.HANDLE) !net.IpAddress {
    var storage: std.Io.Threaded.PosixAddress = undefined;
    @memset(@as([]u8, @ptrCast(&storage))[0..@sizeOf(std.Io.Threaded.PosixAddress)], 0);
    switch ((try winAfdControl(handle, win.IOCTL.AFD.GET_ADDRESS, &.{}, @as([]u8, @ptrCast(&storage))[0..@sizeOf(std.Io.Threaded.PosixAddress)])).status) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    return std.Io.Threaded.addressFromPosix(&storage);
}

/// IOCTL_AFD_SEND for a connected TCP socket. Why not the stdlib netWrite:
/// its windows path maps NO failure statuses, so a send racing the peer's
/// close (STATUS_PIPE_DISCONNECTED etc.) surfaces as error.Unexpected and
/// the guest sees `other` instead of connection-reset (flaked the official
/// sockets-tcp-receive under full-suite load).
fn winAfdSend(handle: win.HANDLE, bytes: []const u8) !usize {
    const wsabuf = [1]win.AFD.WSABUF(.@"const"){.{ .len = @intCast(bytes.len), .buf = bytes.ptr }};
    const info: win.AFD.SEND_INFO = .{
        .BufferArray = &wsabuf,
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{},
    };
    const r = try winAfdControl(handle, win.IOCTL.AFD.SEND, std.mem.asBytes(&info), &.{});
    return switch (r.status) {
        .SUCCESS => r.information,
        .PIPE_DISCONNECTED, .CONNECTION_RESET, .REMOTE_DISCONNECT => error.ConnectionResetByPeer,
        .CONNECTION_ABORTED, .LOCAL_DISCONNECT => error.ConnectionAborted,
        .GRACEFUL_DISCONNECT => error.BrokenPipe,
        .INSUFFICIENT_RESOURCES => error.SystemResources,
        else => error.Unexpected,
    };
}

/// Windows connect-from-a-bound-address (the stream analogue of
/// `rawBoundConnect`): fresh AFD stream socket, bind the released local
/// address, then the CONNECT ioctl (blocking via the event wait).
fn winBoundConnect(family: AddressFamily, local: net.IpAddress, remote: net.IpAddress) !win.HANDLE {
    const handle = try winOpenSocketAfd(family, .stream);
    errdefer win.CloseHandle(handle);
    _ = try winAfdBind(handle, local);
    try winAfdConnect(handle, remote);
    return handle;
}

/// Windows TCP listen with the WIT bind contract (UNIQUE share).
fn winListen(addr: net.IpAddress, backlog: u31) !net.Server {
    const handle = try winOpenSocketAfd(switch (addr) {
        .ip4 => .ipv4,
        .ip6 => .ipv6,
    }, .stream);
    errdefer win.CloseHandle(handle);
    const resolved = try winAfdBind(handle, addr);
    try winAfdListen(handle, backlog);
    return .{
        .socket = .{ .handle = handle, .address = resolved },
        .options = .{ .mode = .stream, .protocol = .tcp },
    };
}

/// Windows UDP bind with UNIQUE share + WIT status mapping.
fn winUdpBind(family: AddressFamily, addr: net.IpAddress) !net.Socket {
    const handle = try winOpenSocketAfd(family, .dgram);
    errdefer win.CloseHandle(handle);
    const resolved = try winAfdBind(handle, addr);
    return .{ .handle = handle, .address = resolved };
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "tcp client lifecycle: create → connect → echo against a loopback listener" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // In-test loopback listener on an ephemeral port (the impl-3 e2e host
    // echo server's seed).
    const listen_addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(0) };
    var server = try listen_addr.listen(io, .{ .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var client = TcpSocket.create(.ipv4);
    defer client.deinit(io);
    try client.startConnect(io, .{ .ip4 = net.Ip4Address.loopback(port) });
    try client.finishConnect();
    try testing.expectEqual(TcpState.connected, client.state);

    var conn = try server.accept(io);
    defer conn.close(io);

    // client → server
    try testing.expectEqual(@as(usize, 4), try client.send(io, "ping"));
    var srv_buf: [16]u8 = undefined;
    var srv_bufs = [_][]u8{&srv_buf};
    const got = try netRead(io, conn.socket.handle, &srv_bufs);
    try testing.expectEqualStrings("ping", srv_buf[0..got]);

    // server → client; readiness flips the client's POLL.IN pollable.
    const reply = [_][]const u8{"pong"};
    _ = try netWrite(io, conn.socket.handle, &reply);
    var attempts: u32 = 0;
    while (!(try client.ready(POLL_IN)) and attempts < 500) : (attempts += 1) {
        try io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake);
    }
    try testing.expect(try client.ready(POLL_IN));
    var cli_buf: [16]u8 = undefined;
    const echoed = try client.recv(io, &cli_buf);
    try testing.expectEqualStrings("pong", cli_buf[0..echoed]);
}

test "tcp state machine: invalid transitions are rejected" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sock = TcpSocket.create(.ipv4);
    defer sock.deinit(io);
    // finish before start → not-in-progress.
    try testing.expectError(error.NotInProgress, sock.finishBind());
    try testing.expectError(error.NotInProgress, sock.finishConnect());
    // recv/send/ready before connected → invalid-state.
    var buf: [4]u8 = undefined;
    try testing.expectError(error.InvalidState, sock.recv(io, &buf));
    try testing.expectError(error.InvalidState, sock.send(io, "x"));
    try testing.expectError(error.InvalidState, sock.ready(POLL_IN));
    // family mismatch → invalid-argument.
    try testing.expectError(error.InvalidArgument, sock.startConnect(io, .{ .ip6 = net.Ip6Address.loopback(1) }));
    // bind twice → invalid-state on the second start-bind.
    try sock.startBind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    try testing.expectError(error.InvalidState, sock.startBind(io, .{ .ip4 = net.Ip4Address.loopback(0) }));
    try sock.finishBind();
    try testing.expectEqual(TcpState.bound, sock.state);
    // bound → connect is Phase-2 scope (std.Io.net has no bound connect).
    try testing.expectError(error.OptionUnsupported, sock.startConnect(io, .{ .ip4 = net.Ip4Address.loopback(1) }));
}

test "tcp connect to a closed port surfaces connection-refused at finish-connect" {
    // D-323: the pinned Zig 0.16 stdlib's windows `netConnectIpWindows` not only
    // mis-maps NTSTATUS 0xC0000236 (CONNECTION_REFUSED) to error.Unexpected, it
    // can ABORT the test runner (ntdll crash through the Threaded-Io connect path
    // on a real loopback connect to a just-closed ephemeral port) — that aborts
    // the entire windows unit-test binary and blocks the Win64 gate. Skip the
    // real-network portion on windows until the pinned stdlib's windows connect is
    // robust; the pure error-code mapping is still asserted below on every host.
    if (builtin.os.tag != .windows) {
        var threaded: std.Io.Threaded = .init(testing.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        // Grab an ephemeral port, then close the listener so nothing accepts.
        const listen_addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(0) };
        var server = try listen_addr.listen(io, .{ .mode = .stream, .protocol = .tcp });
        const port = server.socket.address.getPort();
        server.deinit(io);

        var sock = TcpSocket.create(.ipv4);
        defer sock.deinit(io);
        try sock.startConnect(io, .{ .ip4 = net.Ip4Address.loopback(port) });
        try testing.expectError(error.ConnectionRefused, sock.finishConnect());
    }
    try testing.expectEqual(ErrorCode.connection_refused, errorToCode(error.ConnectionRefused));
}

test "tcp listener lifecycle: bind → listen → accept → echo (ADR-0180 Phase 2)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = TcpSocket.create(.ipv4);
    defer listener.deinit(io);
    try listener.setListenBacklog(8);
    try listener.startBind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    try listener.finishBind();
    // bound (pre-listen): local-address reports the REQUESTED port (0 —
    // the deferred-bind DIVERGENCE; resolution happens at listen).
    try testing.expectEqual(@as(u16, 0), (try listener.localAddress()).getPort());
    try listener.startListen(io);
    try listener.finishListen();
    try testing.expectEqual(TcpState.listening, listener.state);

    // listening: local-address now carries the RESOLVED ephemeral port.
    const local = try listener.localAddress();
    const port = local.getPort();
    try testing.expect(port != 0);

    // No queued connection yet → accept is would-block, readiness false.
    try testing.expect(!(try listener.ready(POLL_IN)));
    try testing.expectError(error.WouldBlock, listener.accept(io));

    // A client connects (kernel backlog completes the handshake).
    var client = TcpSocket.create(.ipv4);
    defer client.deinit(io);
    try client.startConnect(io, .{ .ip4 = net.Ip4Address.loopback(port) });
    try client.finishConnect();

    var attempts: u32 = 0;
    while (!(try listener.ready(POLL_IN)) and attempts < 500) : (attempts += 1) {
        try io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake);
    }
    var accepted = try listener.accept(io);
    defer accepted.deinit(io);
    try testing.expectEqual(TcpState.connected, accepted.state);

    // Echo through the accepted socket: client → accepted → client.
    try testing.expectEqual(@as(usize, 4), try client.send(io, "ping"));
    var srv_buf: [16]u8 = undefined;
    const got = try accepted.recv(io, &srv_buf);
    try testing.expectEqualStrings("ping", srv_buf[0..got]);
    try testing.expectEqual(@as(usize, 4), try accepted.send(io, "pong"));
    var cli_buf: [16]u8 = undefined;
    const echoed = try client.recv(io, &cli_buf);
    try testing.expectEqualStrings("pong", cli_buf[0..echoed]);
}

test "tcp connected endpoints: local-address is OS-resolved, remote-address is the peer" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = TcpSocket.create(.ipv4);
    defer listener.deinit(io);
    try listener.startBind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    try listener.finishBind();
    try listener.startListen(io);
    try listener.finishListen();
    const srv_port = (try listener.localAddress()).getPort();

    var client = TcpSocket.create(.ipv4);
    defer client.deinit(io);
    try client.startConnect(io, .{ .ip4 = net.Ip4Address.loopback(srv_port) });
    try client.finishConnect();

    // Client local endpoint: the OS-resolved ephemeral port (the pinned
    // stdlib resolves it on every connect path: getsockname on POSIX, the
    // AFD BIND output on windows).
    const cli_local = try client.localAddress();
    try testing.expect(cli_local.getPort() != 0);
    try testing.expect(cli_local.getPort() != srv_port);
    // Client remote endpoint: the listener's address.
    try testing.expectEqual(srv_port, (try client.remoteAddress()).getPort());

    var attempts: u32 = 0;
    while (!(try listener.ready(POLL_IN)) and attempts < 500) : (attempts += 1) {
        try io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake);
    }
    var accepted = try listener.accept(io);
    defer accepted.deinit(io);
    // Accepted remote endpoint: the client's OS-resolved local endpoint.
    try testing.expectEqual(cli_local.getPort(), (try accepted.remoteAddress()).getPort());
    // Accepted local endpoint: the listener's endpoint.
    try testing.expectEqual(srv_port, (try accepted.localAddress()).getPort());
}

test "tcp bind honors the spec's SO_REUSEADDR contract: TIME_WAIT rebind ok, active-listen bind rejected" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Establish a connection whose server side actively closes, leaving the
    // listener port's (P, client-port) pair in TIME_WAIT.
    var listener = TcpSocket.create(.ipv4);
    try listener.startBind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    try listener.finishBind();
    try listener.bindNow(io);
    try listener.listenNow(io);
    const port = (try listener.localAddress()).getPort();

    // While the listener is live: a second bind to the same port must be
    // address-in-use (the REUSEADDR contract must NOT leak SO_REUSEPORT,
    // which would let this bind succeed).
    var squatter = TcpSocket.create(.ipv4);
    defer squatter.deinit(io);
    try squatter.startBind(io, .{ .ip4 = net.Ip4Address.loopback(port) });
    try squatter.finishBind();
    try testing.expectError(error.AddressInUse, squatter.bindNow(io));

    var client = TcpSocket.create(.ipv4);
    try client.startConnect(io, .{ .ip4 = net.Ip4Address.loopback(port) });
    try client.finishConnect();
    var attempts: u32 = 0;
    while (!(try listener.ready(POLL_IN)) and attempts < 500) : (attempts += 1) {
        try io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake);
    }
    var accepted = try listener.accept(io);
    // Server side closes FIRST (the active closer holds TIME_WAIT on P).
    accepted.deinit(io);
    client.deinit(io);
    listener.deinit(io);

    // Immediate rebind of P must succeed per the sockets WIT implementors
    // note (implicit SO_REUSEADDR: bind is not affected by TIME_WAIT).
    var rebind = TcpSocket.create(.ipv4);
    defer rebind.deinit(io);
    try rebind.startBind(io, .{ .ip4 = net.Ip4Address.loopback(port) });
    try rebind.finishBind();
    try rebind.bindNow(io);
    try rebind.listenNow(io);
    try testing.expectEqual(port, (try rebind.localAddress()).getPort());
}

test "tcp connect from an explicitly bound socket preserves the bound port" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = TcpSocket.create(.ipv4);
    defer listener.deinit(io);
    try listener.startBind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    try listener.finishBind();
    try listener.bindNow(io);
    try listener.listenNow(io);
    const srv_port = (try listener.localAddress()).getPort();

    var client = TcpSocket.create(.ipv4);
    defer client.deinit(io);
    try client.startBind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    try client.finishBind();
    try client.bindNow(io);
    const bound_port = (try client.localAddress()).getPort();
    try testing.expect(bound_port != 0);

    try client.connectFromBound(io, .{ .ip4 = net.Ip4Address.loopback(srv_port) });
    try client.finishConnect();
    try testing.expectEqual(TcpState.connected, client.state);
    // The bound port survives the connect (the raw composition re-binds it).
    try testing.expectEqual(bound_port, (try client.localAddress()).getPort());
    try testing.expectEqual(srv_port, (try client.remoteAddress()).getPort());

    var attempts: u32 = 0;
    while (!(try listener.ready(POLL_IN)) and attempts < 500) : (attempts += 1) {
        try io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake);
    }
    var accepted = try listener.accept(io);
    defer accepted.deinit(io);
    try testing.expectEqual(bound_port, (try accepted.remoteAddress()).getPort());

    // Round-trip: the raw fd plugs into the normal io vtable paths.
    try testing.expectEqual(@as(usize, 4), try client.send(io, "ping"));
    var buf: [8]u8 = undefined;
    const got = try accepted.recv(io, &buf);
    try testing.expectEqualStrings("ping", buf[0..got]);
}

test "tcp listener state machine: invalid transitions are rejected" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sock = TcpSocket.create(.ipv4);
    defer sock.deinit(io);
    // listen before bound / finish before start / accept before listening.
    try testing.expectError(error.InvalidState, sock.startListen(io));
    try testing.expectError(error.NotInProgress, sock.finishListen());
    try testing.expectError(error.InvalidState, sock.accept(io));
    try testing.expectError(error.InvalidState, sock.localAddress());
    // backlog 0 is invalid-argument per spec.
    try testing.expectError(error.InvalidArgument, sock.setListenBacklog(0));

    try sock.startBind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    try sock.finishBind();
    try sock.startListen(io);
    try sock.finishListen();
    // live listener: backlog update is truthful not-supported.
    try testing.expectError(error.OptionUnsupported, sock.setListenBacklog(4));
    // connected-client local-address: the OS-resolved ephemeral endpoint.
    var client = TcpSocket.create(.ipv4);
    defer client.deinit(io);
    try client.startConnect(io, .{ .ip4 = net.Ip4Address.loopback((try sock.localAddress()).getPort()) });
    try client.finishConnect();
    try testing.expect((try client.localAddress()).getPort() != 0);
}

test "resolve-addresses core: literals parse locally, invalid names reject, localhost resolves" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: [8]net.IpAddress = undefined;

    // IP literals: parsed locally, returned as-is (the WIT fast path).
    try testing.expectEqual(@as(usize, 1), try resolveAddresses(io, "192.0.2.7", &out));
    try testing.expectEqual(@as(u8, 192), out[0].ip4.bytes[0]);
    try testing.expectEqual(@as(usize, 1), try resolveAddresses(io, "::1", &out));
    try testing.expectEqual(@as(u8, 1), out[0].ip6.bytes[15]);

    // Syntactically invalid → invalid-argument class.
    try testing.expectError(error.InvalidName, resolveAddresses(io, "bad name!", &out));

    // Real resolution via the hosts file (deterministic on POSIX runners;
    // the windows resolver path is exercised by the same core through the
    // stdlib but "localhost" hosts-file behavior there is not pinned).
    if (builtin.os.tag != .windows) {
        const n = try resolveAddresses(io, "localhost", &out);
        try testing.expect(n >= 1);
        for (out[0..n]) |a| switch (a) {
            .ip4 => |v| try testing.expectEqual(@as(u8, 127), v.bytes[0]),
            .ip6 => |v| try testing.expectEqual(@as(u8, 1), v.bytes[15]),
        };
    }
}

test "errorToCode: spec ordinals pinned" {
    try testing.expectEqual(@as(u8, 8), @backingInt(ErrorCode.would_block));
    try testing.expectEqual(@as(u8, 9), @backingInt(ErrorCode.invalid_state));
    try testing.expectEqual(@as(u8, 12), @backingInt(errorToCode(error.AddressInUse)));
    try testing.expectEqual(@as(u8, 14), @backingInt(errorToCode(error.ConnectionRefused)));
    try testing.expectEqual(@as(u8, 20), @backingInt(ErrorCode.permanent_resolver_failure));
    try testing.expectEqual(ErrorCode.unknown, errorToCode(error.Unexpected));
}
