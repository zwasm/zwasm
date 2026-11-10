//! Test-only: the HTTP echo endpoint the 0.3 `http-client` official test and
//! the 0.2 client tests (`component_wasi_p2_http.zig`) send to. Imported only
//! from test code, so no product build compiles it.

const std = @import("std");
const net = std.Io.net;
const p2_sockets = @import("../wasi/p2_sockets.zig");

/// The manifest `endpoints` echo server (http-client, ADR-0205 D-5): one
/// HTTP/1.1 connection served on a background thread — read head +
/// content-length body, echo it back. The listener is created on the main
/// io (Threaded is thread-safe); `stop` dials a wake-up connection if the
/// guest never connected.
pub const EchoEndpoint = struct {
    io: std.Io,
    server: net.Server,
    port: u16,
    thread: std.Thread,

    pub fn start(io: std.Io) !*EchoEndpoint {
        const self = try std.heap.page_allocator.create(EchoEndpoint);
        errdefer std.heap.page_allocator.destroy(self);
        const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(0) };
        self.io = io;
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
        const body = buf[head_end..n];
        var out: [66000]u8 = undefined;
        const resp = std.mem.print(&out, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
        const data = [_][]const u8{resp};
        _ = p2_sockets.netWrite(io, conn.socket.handle, &data) catch return;
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

/// One HTTP/1.1 connection that records the request as it came over the
/// wire (head plus a content-length or chunked body) and answers `response`
/// verbatim — for asserting the client's framing, and for serving framing
/// `EchoEndpoint` does not write. `request` is readable after `stop`.
pub const RawEndpoint = struct {
    io: std.Io,
    server: net.Server,
    port: u16,
    thread: std.Thread,
    response: []const u8,
    buf: [65536]u8 = undefined,
    len: usize = 0,

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
        var conn = self.server.accept(io) catch return;
        defer conn.close(io);
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
        const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(self.port) };
        if (addr.connect(self.io, .{ .mode = .stream, .protocol = .tcp })) |s| s.close(self.io) else |_| {
            // Already connected/served — the accept has returned; nothing to wake.
        }
        self.thread.join();
        self.server.deinit(self.io);
    }

    pub fn destroy(self: *RawEndpoint) void {
        std.heap.page_allocator.destroy(self);
    }
};
