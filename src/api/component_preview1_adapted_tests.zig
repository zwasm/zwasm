//! Preview1-adapted components: a wasi_snapshot_preview1 core module wrapped
//! with the wasmtime preview1 adapter (`wasm-tools component new --adapt`).
//! The adapter core module imports WASI 0.2 interfaces unconditionally, so
//! every row it names must be served by the P2 host or the component does
//! not link. Fixtures: test/component/README_preview1_adapted.md.

const std = @import("std");
const testing = std.testing;

const component = @import("component.zig");
const adapter = @import("../wasi/adapter.zig");
const wasi_host = @import("../wasi/host.zig");
const Engine = @import("../zwasm/engine.zig").Engine;

const open = component.open;
const componentNeedsWasi = component.componentNeedsWasi;

/// Open a preview1-adapted component (see test/component/README_preview1_adapted.md),
/// invoke `call("op", request)` and return the echoed string (caller frees).
/// stdout is captured into `capture` when given.
fn openAdaptedAndCall(path: []const u8, request: []const u8, capture: ?*std.ArrayList(u8)) ![]u8 {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    // The adapter's imports are wasi:* 0.2 interfaces, so open takes the graph path.
    try testing.expect(try componentNeedsWasi(testing.allocator, bytes));

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    if (capture) |c| host.stdout_buffer = c;

    var opened = try open(&eng, testing.allocator, bytes, &host, .{});
    defer opened.deinit();

    // Two calls on one opened component: the reusable-state route an embedder
    // takes instead of a one-shot wasi command per call.
    for (0..2) |_| {
        const out = (try opened.invokeTyped("call", &.{ .{ .string = "op" }, .{ .string = request } }, testing.allocator)).?;
        out.deinit(testing.allocator);
    }
    const out = (try opened.invokeTyped("call", &.{ .{ .string = "op" }, .{ .string = request } }, testing.allocator)).?;
    defer out.deinit(testing.allocator);
    return testing.allocator.dupe(u8, out.string);
}

test "preview1-adapted reactor component links and invokes (filesystem-error-code, 0.2 clock resolution)" {
    // Before the `filesystem-error-code` row (and the 0.2 `resolution`
    // spellings) every component built with the wasi_snapshot_preview1
    // adapter failed to link with a bare UnknownImport, whatever the guest:
    // the adapter core module imports them unconditionally.
    const out = try openAdaptedAndCall("test/component/preview1_adapted_reactor.wasm", "hello", null);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "preview1-adapted reactor component: fd_write reaches the host's stdout through the adapter" {
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    const out = try openAdaptedAndCall("test/component/preview1_fd_write_reactor.wasm", "echo-me", &capture);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("echo-me", out);
    // three calls, each writes one line
    try testing.expectEqualStrings("P1-OK\nP1-OK\nP1-OK\n", capture.items);
}

test "preview1-adapted command component links and its exported func invokes" {
    const out = try openAdaptedAndCall("test/component/preview1_command.wasm", "cmd", null);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("cmd", out);
}

test "p2 filesystem-error-code answers none; wall-clock resolution is a datetime" {
    // Direct trampoline check through the classifier, the same way the
    // adapter reaches it: an import row the table did not classify could
    // never be linked.
    try testing.expectEqual(adapter.P2Op.fs_filesystem_error_code, adapter.classifyImport("wasi:filesystem/types", "filesystem-error-code", .p2).?);
    try testing.expectEqual(adapter.P2Op.clocks_wall_resolution, adapter.classifyImport("wasi:clocks/wall-clock", "resolution", .p2).?);
}
