//! Test-only: the HTTP endpoint the 0.3 `http-client*` official tests and the
//! 0.2 client tests (`component_wasi_p2_http.zig`) send to. Imported only
//! from test code, so no product build compiles it.

const std = @import("std");
const http = std.http;
const net = std.Io.net;
const p2_sockets = @import("../wasi/p2_sockets.zig");

/// A manifest server (ADR-0205 D-5), after upstream's
/// `_EndpointRequestHandler` (wasi-testsuite
/// `test-runner/wasi_test_runner/test_suite_runner.py`): HTTP/1.1, one
/// request per connection, each connection on its own thread as upstream's
/// `ThreadingHTTPServer` runs it. The listener is created on the main io
/// (Threaded is thread-safe).
pub const HttpEndpoint = struct {
    io: std.Io,
    server: net.Server,
    port: u16,
    thread: std.Thread,
    /// null answers every request as `echo_body` (the 0.2 client tests);
    /// otherwise a request no route names gets 404.
    routes: ?[]const Route,
    stopping: std.atomic.Value(bool) = .init(false),

    /// Matched on the method and the exact request-target, query included.
    pub const Route = struct {
        method: []const u8 = "GET",
        path: []const u8 = "/",
        reply: Reply,
    };

    pub const Reply = union(enum) {
        static: Static,
        /// 200 with the request body.
        echo_body,
        /// 200 with an empty body and, as response headers, the request's
        /// method, target, headers (`x-echo-<name>`) and trailers
        /// (`x-trailer-<name>`).
        echo_headers,
    };

    pub const Static = struct {
        status: u16 = 200,
        headers: []const http.Header = &.{},
        body: []const u8 = "",
        /// Sent with chunked framing, one chunk per element, in place of `body`.
        chunks: ?[]const []const u8 = null,
        /// Sent after the last chunk and announced in a `Trailer` header.
        trailers: []const http.Header = &.{},
    };

    const max_body_bytes = 16 << 20;
    const gpa = std.heap.page_allocator;

    pub fn start(io: std.Io, routes: ?[]const Route) !*HttpEndpoint {
        const self = try gpa.create(HttpEndpoint);
        errdefer gpa.destroy(self);
        const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(0) };
        self.* = .{
            .io = io,
            .routes = routes,
            .server = try addr.listen(io, .{ .mode = .stream, .protocol = .tcp }),
            .port = undefined,
            .thread = undefined,
        };
        errdefer self.server.deinit(io);
        self.port = self.server.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    /// A loopback port with nothing listening on it (a manifest server of
    /// `kind: closed`): connecting to it is refused.
    pub fn reserveClosedPort(io: std.Io) !u16 {
        const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(0) };
        var server = try addr.listen(io, .{ .mode = .stream, .protocol = .tcp });
        defer server.deinit(io);
        return server.socket.address.getPort();
    }

    pub fn stop(self: *HttpEndpoint) void {
        // The accept loop only sees the flag once a connection wakes it.
        self.stopping.store(true, .release);
        const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(self.port) };
        if (addr.connect(self.io, .{ .mode = .stream, .protocol = .tcp })) |s| s.close(self.io) else |_| {
            // The listener is already gone, so the loop has ended.
        }
        self.thread.join();
        self.server.deinit(self.io);
        gpa.destroy(self);
    }

    fn acceptLoop(self: *HttpEndpoint) void {
        var workers: std.ArrayList(std.Thread) = .empty;
        defer {
            for (workers.items) |w| w.join();
            workers.deinit(gpa);
        }
        while (true) {
            const conn = self.server.accept(self.io) catch return;
            if (self.stopping.load(.acquire)) return conn.close(self.io);
            workers.ensureUnusedCapacity(gpa, 1) catch return conn.close(self.io);
            const worker = std.Thread.spawn(.{}, serveConnection, .{ self, conn }) catch return conn.close(self.io);
            workers.appendAssumeCapacity(worker);
        }
    }

    fn serveConnection(self: *const HttpEndpoint, conn: net.Stream) void {
        defer conn.close(self.io);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        // A failed exchange reaches the test as the client's own error.
        self.answer(arena.allocator(), conn) catch return;
    }

    fn answer(self: *const HttpEndpoint, arena: std.mem.Allocator, conn: net.Stream) !void {
        var in_buf: [16 * 1024]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var reader = conn.reader(self.io, &in_buf);
        var writer = conn.writer(self.io, &out_buf);
        var server = http.Server.init(&reader.interface, &writer.interface);

        const head_buffer = try server.reader.receiveHead();
        const head = http.Server.Request.Head.parse(head_buffer) catch |err| {
            const status: http.Status = if (err == error.UnknownHttpMethod) .not_implemented else .bad_request;
            try writer.interface.print("HTTP/1.1 {d} {s}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", .{ @backingInt(status), status.phrase().? });
            return writer.interface.flush();
        };
        var request: http.Server.Request = .{ .server = &server, .head_buffer = head_buffer, .head = head };

        // The head's strings die when the body reader starts: copy them first.
        const target = try arena.dupe(u8, head.target);
        var headers: std.ArrayList(http.Header) = .empty;
        var it = request.iterateHeaders();
        while (it.next()) |h| try headers.append(arena, .{
            .name = try std.ascii.allocLowerString(arena, h.name),
            .value = try arena.dupe(u8, h.value),
        });

        var body: []const u8 = "";
        var trailers: std.ArrayList(http.Header) = .empty;
        // Not `readerExpectContinue`: it reads no body under GET or HEAD,
        // where upstream reads whatever the framing announces.
        if (head.transfer_encoding == .chunked or head.content_length != null) {
            const expects = head.expect != null;
            try request.writeExpectContinue();
            if (expects) try server.out.flush();
            var body_buf: [4096]u8 = undefined;
            const body_reader = server.reader.bodyReader(&body_buf, head.transfer_encoding, head.content_length);
            body = try body_reader.allocRemaining(arena, .limited(max_body_bytes));
            if (server.reader.trailers.len != 0) {
                var tit: http.HeaderIterator = .{ .bytes = server.reader.trailers, .index = 0, .is_trailer = true };
                next: while (tit.next()) |t| {
                    const name = try std.ascii.allocLowerString(arena, t.name);
                    const value = try arena.dupe(u8, t.value);
                    // A repeated trailer keeps its last value, as upstream's dict does.
                    for (trailers.items) |*seen| if (std.mem.eql(u8, seen.name, name)) {
                        seen.value = value;
                        continue :next;
                    };
                    try trailers.append(arena, .{ .name = name, .value = value });
                }
            }
        }

        const method = @tagName(head.method);
        const reply: Reply = if (self.routes) |routes| findRoute(routes, method, target) orelse
            return request.respond("", .{ .status = .not_found, .keep_alive = false }) else .echo_body;
        switch (reply) {
            .echo_body => try request.respond(body, .{ .keep_alive = false }),
            .echo_headers => {
                var echoed: std.ArrayList(http.Header) = .empty;
                try echoed.append(arena, .{ .name = "x-request-method", .value = method });
                try echoed.append(arena, .{ .name = "x-request-path", .value = target });
                // Grouped by name in order of first appearance, as upstream sends them.
                for (headers.items, 0..) |first, i| {
                    const earlier = for (headers.items[0..i]) |h| {
                        if (std.mem.eql(u8, h.name, first.name)) break true;
                    } else false;
                    if (earlier) continue;
                    const name = try std.mem.concat(arena, u8, &.{ "x-echo-", first.name });
                    for (headers.items[i..]) |h| {
                        if (std.mem.eql(u8, h.name, first.name)) try echoed.append(arena, .{ .name = name, .value = h.value });
                    }
                }
                for (trailers.items) |t| try echoed.append(arena, .{
                    .name = try std.mem.concat(arena, u8, &.{ "x-trailer-", t.name }),
                    .value = t.value,
                });
                try request.respond("", .{ .extra_headers = echoed.items, .keep_alive = false });
            },
            .static => |s| {
                const status: http.Status = @fromBackingInt(@intCast(s.status));
                const chunks = s.chunks orelse return request.respond(s.body, .{
                    .status = status,
                    .extra_headers = s.headers,
                    .keep_alive = false,
                });
                var extra: std.ArrayList(http.Header) = .empty;
                try extra.appendSlice(arena, s.headers);
                if (s.trailers.len != 0) {
                    var names: std.ArrayList(u8) = .empty;
                    for (s.trailers, 0..) |t, i| {
                        if (i != 0) try names.appendSlice(arena, ", ");
                        try names.appendSlice(arena, t.name);
                    }
                    try extra.append(arena, .{ .name = "Trailer", .value = names.items });
                }
                // Unbuffered, so each write is one chunk on the wire.
                var body_writer = try request.respondStreaming(&.{}, .{ .respond_options = .{
                    .status = status,
                    .extra_headers = extra.items,
                    .keep_alive = false,
                } });
                for (chunks) |chunk| {
                    try body_writer.writer.writeAll(chunk);
                    try body_writer.flush();
                }
                try body_writer.endChunked(.{ .trailers = s.trailers });
            },
        }
    }

    /// The last route that matches, as a later entry replaces an earlier one
    /// in upstream's route table.
    fn findRoute(routes: []const Route, method: []const u8, target: []const u8) ?Reply {
        var i = routes.len;
        while (i > 0) {
            i -= 1;
            const r = routes[i];
            if (std.ascii.eqlIgnoreCase(r.method, method) and std.mem.eql(u8, r.path, target)) return r.reply;
        }
        return null;
    }
};

/// One HTTP/1.1 connection that records the request as it came over the
/// wire (head plus a content-length or chunked body) and answers `response`
/// verbatim — for asserting the bytes the client put on the wire, and for
/// answering a response the test spells out byte for byte. A later
/// connection is counted in `connections` and closed unanswered. `request`
/// and `connections` are readable after `stop`; `destroy` stops it first if
/// the test has not, so a test that fails early leaves no thread behind.
pub const RawEndpoint = struct {
    io: std.Io,
    server: net.Server,
    port: u16,
    thread: std.Thread,
    response: []const u8,
    buf: [65536]u8 = undefined,
    len: usize = 0,
    connections: u32 = 0,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn start(io: std.Io, response: []const u8) !*RawEndpoint {
        const self = try std.heap.page_allocator.create(RawEndpoint);
        errdefer std.heap.page_allocator.destroy(self);
        const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(0) };
        self.* = .{ .io = io, .server = try addr.listen(io, .{ .mode = .stream, .protocol = .tcp }), .port = 0, .thread = undefined, .response = response };
        self.port = self.server.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    pub fn request(self: *const RawEndpoint) []const u8 {
        return self.buf[0..self.len];
    }

    fn serve(self: *RawEndpoint) void {
        const io = self.io;
        while (true) {
            var conn = self.server.accept(io) catch return;
            defer conn.close(io);
            if (self.stopping.load(.acquire)) return;
            self.connections += 1;
            if (self.connections == 1) self.answer(conn);
        }
    }

    fn answer(self: *RawEndpoint, conn: net.Stream) void {
        const io = self.io;
        while (!self.complete()) {
            var bufs = [_][]u8{self.buf[self.len..]};
            const got = p2_sockets.netRead(io, conn.socket.handle, &bufs) catch return;
            if (got == 0) return;
            self.len += got;
        }
        const data = [_][]const u8{self.response};
        _ = p2_sockets.netWrite(io, conn.socket.handle, &data) catch return;
    }

    fn complete(self: *const RawEndpoint) bool {
        const got = self.request();
        const head_end = (std.mem.find(u8, got, "\r\n\r\n") orelse return false) + 4;
        const head = got[0..head_end];
        if (std.ascii.findIgnoreCase(head, "transfer-encoding: chunked") != null) {
            // The last chunk, then the trailer section up to its blank line.
            const body = got[head_end..];
            const last = if (std.mem.startsWith(u8, body, "0\r\n")) 0 else (std.mem.find(u8, body, "\r\n0\r\n") orelse return false) + 2;
            return std.mem.find(u8, body[last + 1 ..], "\r\n\r\n") != null;
        }
        var content_len: usize = 0;
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        while (lines.next()) |line| {
            const prefix = "content-length:";
            if (line.len > prefix.len and std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix))
                content_len = std.fmt.parseInt(usize, std.mem.trim(u8, line[prefix.len..], " "), 10) catch return true;
        }
        return got.len - head_end >= content_len;
    }

    pub fn stop(self: *RawEndpoint) void {
        if (self.stopping.swap(true, .acq_rel)) return;
        const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(self.port) };
        if (addr.connect(self.io, .{ .mode = .stream, .protocol = .tcp })) |s| s.close(self.io) else |_| {
            // The accept loop has returned; nothing to wake.
        }
        self.thread.join();
        self.server.deinit(self.io);
    }

    pub fn destroy(self: *RawEndpoint) void {
        self.stop();
        std.heap.page_allocator.destroy(self);
    }
};

const testing = std.testing;

/// Send `request` as written and return everything the endpoint answers
/// before it closes the connection.
fn rawExchange(io: std.Io, port: u16, request: []const u8) ![]u8 {
    const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
    const conn = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer conn.close(io);
    var out_buf: [1024]u8 = undefined;
    var writer = conn.writer(io, &out_buf);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var in_buf: [1024]u8 = undefined;
    var reader = conn.reader(io, &in_buf);
    return reader.interface.allocRemaining(testing.allocator, .limited(1 << 20));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) != null) return;
    std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
    return error.TestExpectedEqual;
}

const test_routes = [_]HttpEndpoint.Route{
    .{ .path = "/q?a=1", .reply = .{ .static = .{ .body = "query" } } },
    .{ .path = "/made", .reply = .{ .static = .{ .status = 201, .headers = &.{.{ .name = "x-kind", .value = "static" }}, .body = "made" } } },
    .{ .method = "HEAD", .path = "/made", .reply = .{ .static = .{ .body = "made" } } },
    .{ .path = "/chunked", .reply = .{ .static = .{
        .chunks = &.{ "pay", "load" },
        .trailers = &.{ .{ .name = "x-checksum", .value = "abc123" }, .{ .name = "x-parts", .value = "1" } },
    } } },
    .{ .method = "POST", .path = "/echo-body", .reply = .echo_body },
    .{ .method = "POST", .path = "/echo-headers", .reply = .echo_headers },
    .{ .path = "/echo-headers?x=1", .reply = .echo_headers },
};

test "HttpEndpoint: a static route answers its status, headers and body, on the exact target only" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ep = try HttpEndpoint.start(io, &test_routes);
    defer ep.stop();

    const made = try rawExchange(io, ep.port, "GET /made HTTP/1.1\r\nHost: t\r\n\r\n");
    defer testing.allocator.free(made);
    try testing.expectStringStartsWith(made, "HTTP/1.1 201 Created\r\n");
    try expectContains(made, "\r\nx-kind: static\r\n");
    try expectContains(made, "\r\nconnection: close\r\n");
    try testing.expectStringEndsWith(made, "\r\n\r\nmade");

    const head = try rawExchange(io, ep.port, "HEAD /made HTTP/1.1\r\nHost: t\r\n\r\n");
    defer testing.allocator.free(head);
    try expectContains(head, "\r\ncontent-length: 4\r\n");
    try testing.expectStringEndsWith(head, "\r\n\r\n");

    const query = try rawExchange(io, ep.port, "GET /q?a=1 HTTP/1.1\r\nHost: t\r\n\r\n");
    defer testing.allocator.free(query);
    try testing.expectStringEndsWith(query, "\r\n\r\nquery");

    for ([_][]const u8{ "GET /q HTTP/1.1\r\nHost: t\r\n\r\n", "POST /made HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n" }) |unrouted| {
        const got = try rawExchange(io, ep.port, unrouted);
        defer testing.allocator.free(got);
        try testing.expectStringStartsWith(got, "HTTP/1.1 404 Not Found\r\n");
    }
}

test "HttpEndpoint: a chunks route sends one chunk per element, then the trailers its Trailer header names" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ep = try HttpEndpoint.start(io, &test_routes);
    defer ep.stop();

    const raw = try rawExchange(io, ep.port, "GET /chunked HTTP/1.1\r\nHost: t\r\n\r\n");
    defer testing.allocator.free(raw);
    try expectContains(raw, "\r\ntransfer-encoding: chunked\r\n");
    try expectContains(raw, "\r\nTrailer: x-checksum, x-parts\r\n");
    try testing.expectStringEndsWith(raw, "\r\n\r\n00000003\r\npay\r\n00000004\r\nload\r\n0\r\nx-checksum: abc123\r\nx-parts: 1\r\n\r\n");

    // The same response through a client that parses the framing.
    var url_buf: [64]u8 = undefined;
    const uri = try std.Uri.parse(try std.mem.print(&url_buf, "http://127.0.0.1:{d}/chunked", .{ep.port}));
    var client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [256]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);
    try testing.expectEqual(http.Status.ok, resp.head.status);
    var transfer_buf: [256]u8 = undefined;
    const body = try resp.reader(&transfer_buf).allocRemaining(testing.allocator, .limited(1 << 10));
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("payload", body);
    var trailers = resp.iterateTrailers();
    const first = trailers.next().?;
    try testing.expectEqualStrings("x-checksum", first.name);
    try testing.expectEqualStrings("abc123", first.value);
    const second = trailers.next().?;
    try testing.expectEqualStrings("x-parts", second.name);
    try testing.expectEqualStrings("1", second.value);
    try testing.expectEqual(null, trailers.next());
}

test "HttpEndpoint: echo-body and echo-headers read a chunked request and its trailers" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ep = try HttpEndpoint.start(io, &test_routes);
    defer ep.stop();

    const chunked_tail = "Host: t\r\nX-Tag: a\r\nAccept: text/plain\r\nx-tag: b\r\nTransfer-Encoding: chunked\r\nTrailer: X-Sum\r\n\r\n" ++
        "3;ext=1\r\nabc\r\n2\r\nde\r\n0\r\nX-Sum: one\r\nx-sum: two\r\nX-Other: o\r\n\r\n";

    const body = try rawExchange(io, ep.port, "POST /echo-body HTTP/1.1\r\n" ++ chunked_tail);
    defer testing.allocator.free(body);
    try testing.expectStringStartsWith(body, "HTTP/1.1 200 OK\r\n");
    try expectContains(body, "\r\ncontent-length: 5\r\n");
    try testing.expectStringEndsWith(body, "\r\n\r\nabcde");

    const counted = try rawExchange(io, ep.port, "POST /echo-body HTTP/1.1\r\nHost: t\r\nContent-Length: 4\r\n\r\nping");
    defer testing.allocator.free(counted);
    try testing.expectStringEndsWith(counted, "\r\n\r\nping");

    const headers = try rawExchange(io, ep.port, "POST /echo-headers HTTP/1.1\r\n" ++ chunked_tail);
    defer testing.allocator.free(headers);
    try testing.expectStringStartsWith(headers, "HTTP/1.1 200 OK\r\n");
    try expectContains(headers, "\r\ncontent-length: 0\r\n");
    try testing.expectStringEndsWith(headers, "\r\nx-request-method: POST\r\nx-request-path: /echo-headers\r\n" ++
        "x-echo-host: t\r\nx-echo-x-tag: a\r\nx-echo-x-tag: b\r\nx-echo-accept: text/plain\r\n" ++
        "x-echo-transfer-encoding: chunked\r\nx-echo-trailer: X-Sum\r\n" ++
        "x-trailer-x-sum: two\r\nx-trailer-x-other: o\r\n\r\n");

    const get = try rawExchange(io, ep.port, "GET /echo-headers?x=1 HTTP/1.1\r\nHost: t\r\n\r\n");
    defer testing.allocator.free(get);
    try testing.expectStringEndsWith(get, "\r\nx-request-method: GET\r\nx-request-path: /echo-headers?x=1\r\nx-echo-host: t\r\n\r\n");
}

test "HttpEndpoint: without routes every request is echoed, and a closed port refuses the connection" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ep = try HttpEndpoint.start(io, null);
    defer ep.stop();

    const got = try rawExchange(io, ep.port, "PUT /anything HTTP/1.1\r\nHost: t\r\nContent-Length: 2\r\n\r\nhi");
    defer testing.allocator.free(got);
    try testing.expectStringEndsWith(got, "\r\n\r\nhi");

    const closed: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(try HttpEndpoint.reserveClosedPort(io)) };
    try testing.expectError(error.ConnectionRefused, closed.connect(io, .{ .mode = .stream, .protocol = .tcp }));
}
