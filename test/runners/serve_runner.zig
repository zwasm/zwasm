// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig); std.process.spawn with no environ_map hands the child this process's environment, so a channel set on this lane reaches it.
//! `zwasm serve` (#688): each vendored `http-service*` component is served on
//! a free port, the server URL is read from the first stderr line (as
//! wasi-testsuite's runner reads it), every `request` op of its manifest goes
//! over a real connection, and SIGINT ends the server with exit 0. A client
//! that never finishes its head is answered 408 and does not hold the next
//! one; more requests than one fuel budget covers all succeed. A component
//! without a 0.3 handler and a core module are refused with exit 1.
//!
//! Why a subprocess: the URL line, the signal and the exit code are the CLI's.
//!
//! Usage: `zig build test-cli-serve` /
//!        `zwasm-cli-serve <zwasm-cli> <test/component/wasip3_official dir> <core module>`

const std = @import("std");
const builtin = @import("builtin");
const spawned_cli = @import("spawned_cli");

const services = [_][]const u8{ "http-service", "http-service-echo", "http-service-uri" };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const cli = arg_it.next() orelse return error.MissingCliPath;
    const corpus = arg_it.next() orelse return error.MissingCorpusDir;
    const core_module = arg_it.next() orelse return error.MissingCoreModule;
    try spawned_cli.assertRunnerBuildMode(gpa, io, cli);

    var failures: usize = 0;
    for (services) |name| {
        serveManifest(gpa, io, cli, corpus, name) catch |err| {
            std.debug.print("FAIL  serve {s}: {t}\n", .{ name, err });
            failures += 1;
        };
    }
    serveIdleClient(gpa, io, cli, corpus) catch |err| {
        std.debug.print("FAIL  serve with an idle client: {t}\n", .{err});
        failures += 1;
    };
    servePastOneFuelBudget(gpa, io, cli, corpus) catch |err| {
        std.debug.print("FAIL  serve past one fuel budget: {t}\n", .{err});
        failures += 1;
    };

    const no_handler = try std.Io.Dir.path.join(gpa, &.{ corpus, "cli-env.wasm" });
    defer gpa.free(no_handler);
    const refusals = [_]struct { path: []const u8, says: []const u8 }{
        .{ .path = no_handler, .says = "exports no wasi:http/handler@0.3 handle; exports: wasi:cli/run@0.2.0#run" },
        .{ .path = core_module, .says = "exports no wasi:http/handler@0.3 handle; it is not a component" },
    };
    for (refusals) |r| {
        const result = try std.process.run(gpa, io, .{ .argv = &.{ cli, "serve", "--addr=127.0.0.1:0", r.path } });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        const exit: u8 = switch (result.term) {
            .exited => |c| c,
            else => 255,
        };
        if (exit != 1 or std.mem.find(u8, result.stderr, r.says) == null) {
            std.debug.print("FAIL  serve {s}: exit {d}, stderr \"{f}\", want exit 1 and \"{s}\"\n", .{ r.path, exit, std.zig.fmtString(result.stderr), r.says });
            failures += 1;
        }
    }

    std.debug.print("serve: {d} services, an idle client, past one fuel budget, {d} refusals; {d} failed\n", .{ services.len, refusals.len, failures });
    return if (failures == 0) 0 else 1;
}

/// A `zwasm serve` child on a free port, its URL read from the first stderr line.
const Server = struct {
    child: std.process.Child,
    wd: *spawned_cli.Watchdog,
    /// `http://127.0.0.1:PORT`, no trailing slash.
    base: []u8,

    fn start(gpa: std.mem.Allocator, io: std.Io, cli: []const u8, wasm: []const u8) !Server {
        var child = try std.process.spawn(io, .{
            .argv = &.{ cli, "serve", "--addr", "127.0.0.1:0", wasm },
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .pipe,
        });
        errdefer child.kill(io);
        const wd = try spawned_cli.Watchdog.start(io, child.id.?, 60);
        errdefer wd.disarm();
        var err_buf: [1024]u8 = undefined;
        var err_rd = child.stderr.?.reader(io, &err_buf);
        const first = try err_rd.interface.takeDelimiterExclusive('\n');
        const url_at = std.mem.find(u8, first, "http://") orelse {
            std.debug.print("first stderr line has no URL: \"{f}\"\n", .{std.zig.fmtString(first)});
            return error.NoServerUrl;
        };
        const base = try gpa.dupe(u8, std.mem.trimEnd(u8, first[url_at..], "/"));
        return .{ .child = child, .wd = wd, .base = base };
    }

    fn port(self: *const Server) !u16 {
        const colon = std.mem.findScalarLast(u8, self.base, ':') orelse return error.NoServerUrl;
        return std.fmt.parseInt(u16, self.base[colon + 1 ..], 10);
    }

    /// SIGINT must end it with exit 0. Windows keeps the default Ctrl-C
    /// behaviour (`cli/serve.zig` `installStopHandlers`), so there it is killed.
    fn stop(self: *Server, gpa: std.mem.Allocator, io: std.Io) !void {
        defer self.deinit(gpa, io);
        if (comptime builtin.os.tag == .windows) return;
        try std.posix.kill(self.child.id.?, .INT);
        const term = try self.child.wait(io);
        if (term != .exited or term.exited != 0) {
            std.debug.print("after SIGINT: {any}, want exit 0\n", .{term});
            return error.UncleanStop;
        }
    }

    fn deinit(self: *Server, gpa: std.mem.Allocator, io: std.Io) void {
        self.wd.disarm();
        self.child.kill(io);
        gpa.free(self.base);
    }
};

fn serveManifest(gpa: std.mem.Allocator, io: std.Io, cli: []const u8, corpus: []const u8, name: []const u8) !void {
    const wasm = try gpa.print("{s}/{s}.wasm", .{ corpus, name });
    defer gpa.free(wasm);
    const manifest_path = try gpa.print("{s}/{s}.json", .{ corpus, name });
    defer gpa.free(manifest_path);
    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(1 << 20));
    defer gpa.free(manifest_bytes);
    const manifest = try std.json.parseFromSlice(std.json.Value, gpa, manifest_bytes, .{});
    defer manifest.deinit();

    var server = try Server.start(gpa, io, cli, wasm);
    errdefer server.deinit(gpa, io);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var requests: usize = 0;
    for (manifest.value.object.get("operations").?.array.items) |op| {
        if (!std.mem.eql(u8, op.object.get("type").?.string, "request")) continue;
        try checkRequest(gpa, &client, server.base, op.object);
        requests += 1;
    }
    if (requests == 0) return error.NoRequestOps;
    try server.stop(gpa, io);
}

/// A client that sends half a head and goes quiet: the next client is still
/// answered, the quiet one gets 408, and SIGINT still ends the server.
fn serveIdleClient(gpa: std.mem.Allocator, io: std.Io, cli: []const u8, corpus: []const u8) !void {
    const wasm = try gpa.print("{s}/http-service.wasm", .{corpus});
    defer gpa.free(wasm);
    var server = try Server.start(gpa, io, cli, wasm);
    errdefer server.deinit(gpa, io);

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(try server.port()) };
    var idle = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer idle.close(io);
    var idle_out: [64]u8 = undefined;
    var idle_w = idle.writer(io, &idle_out);
    try idle_w.interface.writeAll("GET / HTTP/1.1\r\n");
    try idle_w.interface.flush();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const url = try gpa.print("{s}/", .{server.base});
    defer gpa.free(url);
    const status, const body = try send(gpa, &client, .GET, url, &.{});
    defer gpa.free(body);
    if (status != 200) {
        std.debug.print("GET / behind an idle client: status {d}, want 200\n", .{status});
        return error.ResponseMismatch;
    }

    var idle_in: [256]u8 = undefined;
    var idle_r = idle.reader(io, &idle_in);
    const answer = try idle_r.interface.allocRemaining(gpa, .limited(256));
    defer gpa.free(answer);
    if (!std.mem.startsWith(u8, answer, "HTTP/1.1 408 ")) {
        std.debug.print("the idle client got \"{f}\", want a 408\n", .{std.zig.fmtString(answer)});
        return error.ResponseMismatch;
    }
    try server.stop(gpa, io);
}

/// One instance, and more 1 MiB echoes than the default fuel budget covers
/// (it ran out after about 60): every one is answered in full.
fn servePastOneFuelBudget(gpa: std.mem.Allocator, io: std.Io, cli: []const u8, corpus: []const u8) !void {
    const wasm = try gpa.print("{s}/http-service-echo.wasm", .{corpus});
    defer gpa.free(wasm);
    var server = try Server.start(gpa, io, cli, wasm);
    errdefer server.deinit(gpa, io);

    const payload = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(payload);
    @memset(payload, 'a');
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const url = try gpa.print("{s}/echo", .{server.base});
    defer gpa.free(url);
    for (0..72) |i| {
        const status, const body = try send(gpa, &client, .POST, url, payload);
        defer gpa.free(body);
        if (status != 200 or body.len != payload.len) {
            std.debug.print("POST /echo #{d}: status {d}, {d} bytes, want 200 and {d}\n", .{ i, status, body.len, payload.len });
            return error.ResponseMismatch;
        }
    }
    try server.stop(gpa, io);
}

/// One request on its own connection: the status and the whole body.
fn send(gpa: std.mem.Allocator, client: *std.http.Client, method: std.http.Method, url: []const u8, body: []u8) !struct { u16, []u8 } {
    var req = try client.request(method, try std.Uri.parse(url), .{ .keep_alive = false });
    defer req.deinit();
    if (method.requestHasBody()) try req.sendBodyComplete(body) else try req.sendBodiless();
    var redirect_buf: [1024]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);
    var transfer_buf: [4096]u8 = undefined;
    const got = try resp.reader(&transfer_buf).allocRemaining(gpa, .limited(4 << 20));
    return .{ @backingInt(resp.head.status), got };
}

/// One manifest `request` op: send it, compare status, each expected header
/// and the body, the way wasi-testsuite's `do_request` does.
fn checkRequest(gpa: std.mem.Allocator, client: *std.http.Client, base: []const u8, op: std.json.ObjectMap) !void {
    const path = op.get("path").?.string;
    const method = std.meta.stringToEnum(std.http.Method, op.get("method").?.string).?;
    const url = try gpa.print("{s}{s}", .{ base, path });
    defer gpa.free(url);

    var extra: std.ArrayList(std.http.Header) = .empty;
    defer extra.deinit(gpa);
    if (op.get("headers")) |hs| {
        var it = hs.object.iterator();
        while (it.next()) |e| try extra.append(gpa, .{ .name = e.key_ptr.*, .value = e.value_ptr.string });
    }

    var req = try client.request(method, try std.Uri.parse(url), .{ .extra_headers = extra.items, .keep_alive = false });
    defer req.deinit();
    if (method.requestHasBody()) {
        const body = try gpa.dupe(u8, if (op.get("body")) |b| b.string else "");
        defer gpa.free(body);
        try req.sendBodyComplete(body);
    } else try req.sendBodiless();
    var redirect_buf: [1024]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);

    const want = op.get("response").?.object;
    const want_status: u16 = @intCast(want.get("status").?.integer);
    var ok = @backingInt(resp.head.status) == want_status;
    if (want.get("headers")) |hs| {
        var it = hs.object.iterator();
        while (it.next()) |e| {
            var found = false;
            var hit = resp.head.iterateHeaders();
            while (hit.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, e.key_ptr.*) and std.mem.eql(u8, h.value, e.value_ptr.string)) found = true;
            }
            if (!found) {
                std.debug.print("{s} {s}: no response header {s}: {s}\n", .{ @tagName(method), path, e.key_ptr.*, e.value_ptr.string });
                ok = false;
            }
        }
    }
    var transfer_buf: [4096]u8 = undefined;
    const got_body = try resp.reader(&transfer_buf).allocRemaining(gpa, .limited(1 << 20));
    defer gpa.free(got_body);
    if (want.get("body")) |b| {
        if (!std.mem.eql(u8, got_body, b.string)) {
            std.debug.print("{s} {s}: body \"{f}\", want \"{f}\"\n", .{ @tagName(method), path, std.zig.fmtString(got_body), std.zig.fmtString(b.string) });
            ok = false;
        }
    }
    if (@backingInt(resp.head.status) != want_status)
        std.debug.print("{s} {s}: status {d}, want {d}\n", .{ @tagName(method), path, @backingInt(resp.head.status), want_status });
    if (!ok) return error.ResponseMismatch;
}
