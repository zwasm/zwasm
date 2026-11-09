//! `zwasm serve <component.wasm>` (#688): a WASI 0.3 `wasi:http/service`
//! component answers HTTP/1.1. One instance built once, one request at a time,
//! one request per connection; the drive is `serviceHandle`, the one the
//! official lane's harness asserts on. Each request gets the default fuel
//! budget afresh; a handler that traps leaves the instance unusable (the
//! Component Model forbids re-entering it), so it is built again. No
//! trailers, no keep-alive, no HTTPS.
//!
//! Zone 3 (`src/cli/`). Compiled only at `-Dwasi=p3`.

const std = @import("std");
const builtin = @import("builtin");
const p3 = @import("../api/component_wasi_p3.zig");
const wasi_p2 = @import("../api/component_wasi_p2.zig");
const decode = @import("../feature/component/decode.zig");
const ctypes = @import("../feature/component/types.zig");
const wasi_host = @import("../wasi/host.zig");
const Engine = @import("../zwasm/engine.zig").Engine;
const Module = @import("../zwasm/module.zig").Module;
const cli_run = @import("run.zig");
const component_entry = @import("component_entry.zig");
const p2_sockets = @import("../wasi/p2_sockets.zig");

const Allocator = std.mem.Allocator;
const net = std.Io.net;
const http = std.http;

pub const default_addr = "127.0.0.1:8080";

/// A request body past this is answered 413 without reaching the guest.
const max_body_bytes = 16 << 20;

/// The whole request (head and body) must arrive within this, or it is
/// answered 408: one client cannot hold the one-at-a-time loop.
const request_read_timeout_s = 10;

pub const Options = struct {
    addr: net.IpAddress,
    argv: []const []const u8,
    preopens: []const cli_run.PreopenDir,
    env_keys: []const []const u8,
    env_vals: []const []const u8,
    allow_network: bool,
};

/// Serve until SIGINT / SIGTERM, then return 0. A component without a 0.3
/// handler returns `error.ComponentRefused` with its stderr line in `refusal`.
pub fn serve(gpa: Allocator, io: std.Io, bytes: []const u8, path: []const u8, opts: Options, refusal: *std.ArrayList(u8)) !u8 {
    if (!(try hasServiceHandler(gpa, bytes, path, refusal))) return error.ComponentRefused;

    var eng = try Engine.init(gpa, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(gpa);
    defer host.deinit();
    try cli_run.configureComponentHost(&host, io, opts.argv, opts.preopens, opts.env_keys, opts.env_vals, opts.allow_network, .inherit);
    var built = try wasi_p2.buildWasiP2Component(&eng, gpa, bytes, &host, .{});
    defer built.deinit();

    var server = try opts.addr.listen(io, .{ .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    // The first stderr line, read by wasi-testsuite's runner for the URL; the
    // wording is wasmtime's.
    try printErr(io, "Serving HTTP on http://{f}/\n", .{server.socket.address});

    installStopHandlers();
    while (!stop_requested.load(.acquire)) {
        if (!(try acceptReady(server.socket.handle))) continue;
        var conn = server.accept(io) catch |err| {
            try printErr(io, "zwasm serve: accept failed: {t}\n", .{err});
            continue;
        };
        defer conn.close(io);
        // Set before the 500 is written, so a client gone by then does not
        // hide a trap.
        var trapped = false;
        serveConnection(gpa, io, &built, conn, server.socket.address, &trapped) catch |err|
            try printErr(io, "zwasm serve: connection failed: {t}\n", .{err});
        if (trapped) {
            const fresh = try wasi_p2.buildWasiP2Component(&eng, gpa, bytes, &host, .{});
            built.deinit();
            built = fresh;
        }
    }
    return 0;
}

/// Read one request from `conn`, answer it, and leave the close to the caller.
fn serveConnection(gpa: Allocator, io: std.Io, built: *wasi_p2.BuiltComponent, conn: net.Stream, listen: net.IpAddress, trapped: *bool) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var reader: DeadlineReader = .init(io, conn, &in_buf, request_read_timeout_s);
    var writer = conn.writer(io, &out_buf);
    var server = http.Server.init(&reader.interface, &writer.interface);

    // Parsed here, not by `receiveHead`, so a method std does not know is
    // told apart from a malformed head.
    const head_buffer = server.reader.receiveHead() catch |err| {
        if (reader.timed_out) return respondBare(&writer.interface, .request_timeout);
        return err;
    };
    const head = http.Server.Request.Head.parse(head_buffer) catch |err| {
        return respondBare(&writer.interface, if (err == error.UnknownHttpMethod) .method_not_allowed else .bad_request);
    };
    var request: http.Server.Request = .{ .server = &server, .head_buffer = head_buffer, .head = head };

    // The head's strings die when the body reader starts: copy them first.
    const target = try arena.dupe(u8, head.target);
    var authority: ?[]const u8 = null;
    var headers: std.ArrayList(http.Header) = .empty;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        const name = try arena.dupe(u8, h.name);
        const value = try arena.dupe(u8, h.value);
        if (authority == null and std.ascii.eqlIgnoreCase(name, "host")) authority = value;
        try headers.append(arena, .{ .name = name, .value = value });
    }

    // HTTP/1.1 with neither content-length nor chunked has no body (RFC 9112
    // §6.3); std's reader would read to EOF instead.
    const has_body = head.content_length != null or head.transfer_encoding == .chunked;
    var body: []const u8 = "";
    if (has_body) {
        var body_buf: [4096]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&body_buf);
        body = body_reader.allocRemaining(arena, .limited(max_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return respondEmpty(&request, .payload_too_large),
            else => |e| {
                if (reader.timed_out) return respondEmpty(&request, .request_timeout);
                return e;
            },
        };
    }

    for (built.instances.items) |inst| inst.setFuel(Module.default_fuel);
    var resp = p3.serviceHandle(built, .{
        .method = @tagName(head.method),
        .path_with_query = target,
        .authority = authority orelse try arena.print("{f}", .{listen}),
        .headers = headers.items,
        .body = body,
    }) catch |err| switch (err) {
        error.UnknownMethod => return respondEmpty(&request, .method_not_allowed),
        else => {
            // An `err` result is a handler's answer; anything else stopped it.
            trapped.* = err != error.HandlerFailed;
            try printErr(io, "zwasm serve: handler failed: {t}\n", .{err});
            return respondEmpty(&request, .internal_server_error);
        },
    };
    defer resp.deinit(built.alloc);
    // `respond` cannot send an interim status as the final one.
    if (resp.status < 200) {
        try printErr(io, "zwasm serve: handler failed: status {d} is informational\n", .{resp.status});
        return respondEmpty(&request, .internal_server_error);
    }

    // `respond` writes the framing itself; a second copy from the guest would
    // contradict it.
    var extra: std.ArrayList(http.Header) = .empty;
    for (resp.headers) |h| {
        if (isFramingHeader(h.name)) continue;
        try extra.append(arena, h);
    }
    try request.respond(resp.body, .{
        .status = @fromBackingInt(@intCast(resp.status)),
        .extra_headers = extra.items,
        .keep_alive = false,
    });
}

fn respondEmpty(request: *http.Server.Request, status: http.Status) !void {
    try request.respond("", .{ .status = status, .keep_alive = false });
}

fn isFramingHeader(name: []const u8) bool {
    for ([_][]const u8{ "content-length", "transfer-encoding", "connection" }) |f| {
        if (std.ascii.eqlIgnoreCase(name, f)) return true;
    }
    return false;
}

/// A response to a head that never became a `Request`.
fn respondBare(w: *std.Io.Writer, status: http.Status) !void {
    try w.print("HTTP/1.1 {d} {s}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", .{ @backingInt(status), status.phrase() orelse "" });
    try w.flush();
}

/// The connection's reader with one deadline for every read of the request.
/// `std.Io.net.Stream.Reader` has no timeout, and the pinned std refuses a
/// timed `net_read` on Windows (`ConcurrencyUnavailable`), so each read first
/// waits for readiness, polling every 10 ms, then reads what is there.
const DeadlineReader = struct {
    io: std.Io,
    stream: net.Stream,
    deadline: std.Io.Clock.Timestamp,
    timed_out: bool = false,
    interface: std.Io.Reader,

    fn init(io: std.Io, stream: net.Stream, buffer: []u8, seconds: i96) DeadlineReader {
        return .{
            .io = io,
            .stream = stream,
            .deadline = .fromNow(io, .{ .raw = .{ .nanoseconds = seconds * std.time.ns_per_s }, .clock = .awake }),
            .interface = .{
                .vtable = &.{ .stream = streamImpl, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *DeadlineReader = @alignCast(@fieldParentPtr("interface", io_r));
        const handle = r.stream.socket.handle;
        while (!(p2_sockets.pollOnce(handle, p2_sockets.POLL_IN) catch return error.ReadFailed)) {
            if (r.deadline.durationFromNow(r.io).raw.nanoseconds <= 0) {
                r.timed_out = true;
                return error.ReadFailed;
            }
            r.io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch return error.ReadFailed;
        }
        var iovecs: [8][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs, data);
        const n = p2_sockets.netRead(r.io, handle, iovecs[0..dest_n]) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            io_r.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

/// The refusal names the exports, and a 0.2 `incoming-handler` as not served.
fn hasServiceHandler(gpa: Allocator, bytes: []const u8, path: []const u8, refusal: *std.ArrayList(u8)) !bool {
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, refusal);
    defer refusal.* = aw.toArrayList();
    const w = &aw.writer;
    const is_component = bytes.len >= 8 and std.mem.eql(u8, bytes[0..4], "\x00asm") and bytes[6] == 0x01;
    if (!is_component) {
        try w.print("zwasm serve: '{s}' exports no wasi:http/handler@0.3 handle; it is not a component", .{path});
        return false;
    }
    var decoded = try decode.decode(gpa, bytes);
    defer decoded.deinit(gpa);
    var info = try ctypes.decodeTypeInfo(gpa, &decoded);
    defer info.deinit();
    if (try p3.serviceHandler(gpa, &info) != null) return true;

    try w.print("zwasm serve: '{s}' exports no wasi:http/handler@0.3 handle", .{path});
    const funcs = try info.exportedFuncs(gpa);
    defer ctypes.TypeInfo.freeExportedFuncs(gpa, funcs);
    if (funcs.len > 0) {
        try w.writeAll("; exports: ");
        try component_entry.writeSignatures(w, &info, funcs);
    }
    for (info.exports.items) |e| {
        if (std.mem.startsWith(u8, e.name, "wasi:http/incoming-handler@"))
            try w.print("; {s} is not served (#688)", .{e.name});
    }
    return false;
}

var stop_requested: std.atomic.Value(bool) = .init(false);

fn onStopSignal(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

/// SIGINT / SIGTERM end the accept loop after the response in flight. On
/// Windows the default Ctrl-C behaviour (the process ends) is kept.
fn installStopHandlers() void {
    if (comptime builtin.os.tag == .windows) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onStopSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

/// Wait up to 100 ms for a pending connection, so a stop request is seen
/// while no client is connecting. Windows has no stop request to see.
fn acceptReady(handle: net.Socket.Handle) !bool {
    if (comptime builtin.os.tag == .windows) return true;
    var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
    return (try std.posix.poll(&fds, 100)) > 0;
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

/// `--addr`'s operand: `H:P`, `[V6]:P`; port 0 picks a free one.
pub fn parseAddr(text: []const u8) ?net.IpAddress {
    const addr = net.IpAddress.parseLiteral(text) catch return null;
    // `parseLiteral` reads a missing port as 0; `--addr` requires one.
    if (std.mem.findScalarLast(u8, text, ':') == null or text[text.len - 1] == ']') return null;
    return addr;
}

test "parseAddr: host and port, IPv6 in brackets, the port required" {
    const t = std.testing;
    try t.expectEqual(@as(u16, 8080), parseAddr("127.0.0.1:8080").?.getPort());
    try t.expectEqual(@as(u16, 0), parseAddr("127.0.0.1:0").?.getPort());
    try t.expectEqual(@as(u16, 9000), parseAddr("[::1]:9000").?.getPort());
    try t.expect(parseAddr("127.0.0.1") == null);
    try t.expect(parseAddr("[::1]") == null);
    try t.expect(parseAddr("localhost:80") == null);
    try t.expect(parseAddr("127.0.0.1:99999") == null);
}

test "isFramingHeader: the three respond writes, in any casing" {
    try std.testing.expect(isFramingHeader("Content-Length"));
    try std.testing.expect(isFramingHeader("transfer-encoding"));
    try std.testing.expect(isFramingHeader("CONNECTION"));
    try std.testing.expect(!isFramingHeader("content-type"));
}
