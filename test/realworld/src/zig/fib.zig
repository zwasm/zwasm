// fib.zig — recursive + integer math + bufPrint formatting over WASI stdout.
// Exercises deep call chains (JIT call/return stress) and i64 arithmetic.
const std = @import("std");
const w = std.os.wasi;

fn writeStr(s: []const u8) void {
    var iov = [_]w.ciovec_t{.{ .base = s.ptr, .len = s.len }};
    var n: usize = undefined;
    _ = w.fd_write(1, &iov, 1, &n);
}

fn fib(n: u64) u64 {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

pub fn main() void {
    var buf: [64]u8 = undefined;
    var i: u64 = 0;
    while (i < 25) : (i += 1) {
        const line = std.mem.print(&buf, "fib({d}) = {d}\n", .{ i, fib(i) }) catch return;
        writeStr(line);
    }
}
