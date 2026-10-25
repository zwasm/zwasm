// prime_sieve.zig — Sieve of Eratosthenes over a stack array.
// Exercises linear memory, nested loops, and branch-heavy control flow.
const std = @import("std");
const w = std.os.wasi;

fn writeStr(s: []const u8) void {
    var iov = [_]w.ciovec_t{.{ .base = s.ptr, .len = s.len }};
    var n: usize = undefined;
    _ = w.fd_write(1, &iov, 1, &n);
}

pub fn main() void {
    const N = 200;
    var sieve: [N + 1]bool = @splat(true);
    sieve[0] = false;
    sieve[1] = false;
    var i: usize = 2;
    while (i * i <= N) : (i += 1) {
        if (!sieve[i]) continue;
        var j = i * i;
        while (j <= N) : (j += i) sieve[j] = false;
    }
    var buf: [16]u8 = undefined;
    var count: usize = 0;
    var k: usize = 2;
    while (k <= N) : (k += 1) {
        if (!sieve[k]) continue;
        count += 1;
        const s = std.mem.print(&buf, "{d}\n", .{k}) catch return;
        writeStr(s);
    }
    const cs = std.mem.print(&buf, "count={d}\n", .{count}) catch return;
    writeStr(cs);
}
