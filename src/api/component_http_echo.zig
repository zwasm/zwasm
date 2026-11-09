//! Test-only: the HTTP echo endpoint the 0.3 `http-client` official test and
//! the 0.2 client tests (`component_wasi_p2_http.zig`) send to. Imported only
//! from test code, so no product build compiles it.

const std = @import("std");
const net = std.Io.net;
const p2_sockets = @import("../wasi/p2_sockets.zig");

/// A manifest server's `echo-body` endpoints (ADR-0205 D-5), after
/// upstream's `_EndpointRequestHandler` (wasi-testsuite
/// `test-runner/wasi_test_runner/test_suite_runner.py`): one HTTP/1.1
/// connection served on a background thread — read head + content-length
/// body, echo it back. A chunked request body is not read: zwasm's client
/// always sends a content-length (`component_wasi_ctx.zig`). The listener is
/// created on the main io (Threaded is thread-safe); `stop` dials a wake-up
/// connection if the guest never connected.
pub const EchoEndpoint = struct {
    io: std.Io,
    server: net.Server,
    port: u16,
    thread: std.Thread,
    /// null echoes every request (the 0.2 client tests); otherwise a request
    /// no route names gets 404, as upstream answers it.
    routes: ?[]const Route,

    pub const Route = struct { method: []const u8, path: []const u8 };

    pub fn start(io: std.Io, routes: ?[]const Route) !*EchoEndpoint {
        const self = try std.heap.page_allocator.create(EchoEndpoint);
        errdefer std.heap.page_allocator.destroy(self);
        const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(0) };
        self.io = io;
        self.routes = routes;
        self.server = try addr.listen(io, .{ .mode = .stream, .protocol = .tcp });
        self.port = self.server.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn serve(self: *EchoEndpoint) void {
        const io = self.io;
        var conn = self.server.accept(io) catch return;
        defer conn.close(io);
        var buf: [65536]u8 = undefined;
        var n: usize = 0;
        // Read until the header terminator, then the content-length body.
        var head_end: usize = 0;
        while (head_end == 0) {
            var bufs = [_][]u8{buf[n..]};
            const got = p2_sockets.netRead(io, conn.socket.handle, &bufs) catch return;
            if (got == 0) return;
            n += got;
            if (std.mem.find(u8, buf[0..n], "\r\n\r\n")) |p| head_end = p + 4;
        }
        var content_len: usize = 0;
        var lines = std.mem.splitSequence(u8, buf[0..head_end], "\r\n");
        while (lines.next()) |line| {
            const prefix = "content-length:";
            if (line.len > prefix.len and std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) {
                content_len = std.fmt.parseInt(usize, std.mem.trim(u8, line[prefix.len..], " "), 10) catch 0;
            }
        }
        while (n - head_end < content_len) {
            var bufs = [_][]u8{buf[n..]};
            const got = p2_sockets.netRead(io, conn.socket.handle, &bufs) catch return;
            if (got == 0) break;
            n += got;
        }
        const body = if (self.routed(buf[0..head_end])) buf[head_end..n] else null;
        var out: [66000]u8 = undefined;
        const resp = if (body) |b|
            std.mem.print(&out, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ b.len, b }) catch return
        else
            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        const data = [_][]const u8{resp};
        _ = p2_sockets.netWrite(io, conn.socket.handle, &data) catch return;
    }

    fn routed(self: *const EchoEndpoint, head: []const u8) bool {
        const routes = self.routes orelse return true;
        var parts = std.mem.splitScalar(u8, head[0 .. std.mem.find(u8, head, "\r\n") orelse head.len], ' ');
        const method = parts.next() orelse return false;
        const target = parts.next() orelse return false;
        for (routes) |r| {
            if (std.ascii.eqlIgnoreCase(r.method, method) and std.mem.eql(u8, r.path, target)) return true;
        }
        return false;
    }

    pub fn stop(self: *EchoEndpoint) void {
        // Unblock a never-connected accept, then reap the thread.
        const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(self.port) };
        if (addr.connect(self.io, .{ .mode = .stream, .protocol = .tcp })) |s| s.close(self.io) else |_| {
            // Already connected/served — the accept has returned; nothing to wake.
        }
        self.thread.join();
        self.server.deinit(self.io);
        std.heap.page_allocator.destroy(self);
    }
};
