//! Interp call depth: frames past the inline 256 spill to heap chunks, so a
//! wasm call chain deeper than 256 runs (bounded by the native-stack check
//! and `Runtime.max_frame_depth`), and runaway recursion still traps.

const std = @import("std");
const testing = std.testing;
const zwasm = @import("../zwasm.zig");

// (module
//   (func $f (export "f") (param i32) (result i32)
//     local.get 0
//     if (result i32)
//       local.get 0  i32.const 1  i32.sub  call $f  i32.const 1  i32.add
//     else
//       i32.const 0
//     end)
//   (func $loop (export "loop") (param i32) (result i32)
//     local.get 0  call $loop))
const depth_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type 0: (i32)->(i32)
    0x03, 0x03, 0x02, 0x00, 0x00, // funcs: 0, 1 : type 0
    0x07, 0x0c, 0x02, // exports: 2
    0x01, 'f', 0x00, 0x00, // "f" = func 0
    0x04, 'l', 'o', 'o', 'p', 0x00, 0x01, // "loop" = func 1
    0x0a, 0x1d, 0x02, // code: 2 bodies
    0x14, 0x00, // body 0: size 20, no locals
    0x20, 0x00, 0x04, 0x7f, // local.get 0; if (result i32)
    0x20, 0x00, 0x41, 0x01, 0x6b, // local.get 0; i32.const 1; i32.sub
    0x10, 0x00, 0x41, 0x01, 0x6a, // call 0; i32.const 1; i32.add
    0x05, 0x41, 0x00, 0x0b, // else; i32.const 0; end
    0x0b, // end
    0x06, 0x00, // body 1: size 6, no locals
    0x20, 0x00, 0x10, 0x01, 0x0b, // local.get 0; call 1; end
};

fn callDepth(inst: *zwasm.Instance, name: []const u8, n: i32) !i32 {
    var args = [_]zwasm.Value{.{ .i32 = n }};
    var res = [_]zwasm.Value{.{ .i32 = 0 }};
    try inst.invoke(name, &args, &res);
    return res[0].i32;
}

// Runs on a thread with a known large stack so the native-stack check
// (D-288), which binds before the frame cap on small stacks, does not decide
// the outcome.
fn onBigStack(comptime f: fn () anyerror!void) !void {
    const Wrap = struct {
        fn run(out: *?anyerror) void {
            f() catch |e| {
                out.* = e;
            };
        }
    };
    var err: ?anyerror = null;
    const t = try std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, Wrap.run, .{&err});
    t.join();
    if (err) |e| return e;
}

fn deepRecursionBody() anyerror!void {
    var eng = try zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&depth_wasm);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .interp });
    defer inst.deinit();
    // 257 frames was the old fixed limit; 2000 crosses several heap chunks.
    try testing.expectEqual(@as(i32, 257), try callDepth(&inst, "f", 257));
    try testing.expectEqual(@as(i32, 2000), try callDepth(&inst, "f", 2000));
    // The same instance is reusable after a deep call unwinds.
    try testing.expectEqual(@as(i32, 3), try callDepth(&inst, "f", 3));
}

fn runawayBody() anyerror!void {
    var eng = try zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&depth_wasm);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .interp });
    defer inst.deinit();
    try testing.expectError(error.CallStackExhausted, callDepth(&inst, "loop", 1));
    // Still usable after the trap.
    try testing.expectEqual(@as(i32, 10), try callDepth(&inst, "f", 10));
}

test "interp: wasm recursion past the old 256-frame limit runs to depth N" {
    try onBigStack(deepRecursionBody);
}

test "interp: unbounded recursion still traps CallStackExhausted" {
    try onBigStack(runawayBody);
}

test "interp: unbounded recursion traps on the calling thread's own stack" {
    try runawayBody();
}
