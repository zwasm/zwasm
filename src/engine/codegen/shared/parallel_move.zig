//! Orders the moves of a parallel assignment so that no move reads a place
//! an earlier move wrote. The per-arch emitters use it for the values an
//! edge delivers to a merge; a place is whatever they key it by (a register
//! or a spill cell), and the copy a cycle needs goes to a park register
//! they pick.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

/// Most moves in one set: a label's value count (`Label.merge_top_vregs`).
pub const cap = 8;

pub const Step = union(enum) {
    /// Emit move `i`. It reads the park if a `park` step named it.
    move: u8,
    /// Copy move `i`'s source to the park; move `i` reads the park from here.
    park: u8,
};

/// Park steps scheduled since the process started. A test reads it around a
/// compile to pin where a cycle forms and where none does.
pub var parks: std.atomic.Value(u64) = .init(0);

pub const Error = error{
    /// Two moves of the set write one place: not a parallel assignment.
    RepeatedDestination,
    /// A second cycle would take the park while the first still holds it.
    /// With each destination written once this cannot happen (the first
    /// cycle unwinds before the next is broken); kept as the refusal if that
    /// argument is ever wrong.
    ParkHeld,
};

/// Orders `dsts[i] ← srcs[i]`. Equal keys are one place, unequal keys are
/// disjoint places. The caller leaves out a move whose source is its
/// destination. A set that writes one place twice is refused; a caller turns
/// either error into a decline of the function.
///
/// A move goes out once no pending move reads its destination; with no
/// overlap that is queue order. When none can, every pending destination is
/// still read, and since each is written once the pending moves are disjoint
/// cycles: the first one's destination is parked for its reader, that move
/// goes out, and its cycle unwinds through to the reader before another cycle
/// is broken. So one park holds one value at a time.
pub fn schedule(srcs: []const u64, dsts: []const u64, steps: *[2 * cap]Step) Error![]const Step {
    std.debug.assert(srcs.len == dsts.len and srcs.len <= cap);
    const n = srcs.len;
    for (dsts, 0..) |d, i| {
        if (std.mem.findScalar(u64, dsts[0..i], d) != null) return error.RepeatedDestination;
    }
    var pending: [cap]bool = @splat(false);
    var parked: [cap]bool = @splat(false);
    @memset(pending[0..n], true);
    var left = n;
    var len: usize = 0;
    while (left > 0) {
        const ready: usize = for (0..n) |i| {
            if (pending[i] and !readByOther(srcs, dsts[i], i, &pending, &parked)) break i;
        } else blk: {
            const first = std.mem.findScalar(bool, pending[0..n], true).?;
            for (0..n) |j| {
                if (pending[j] and parked[j]) return error.ParkHeld;
            }
            for (0..n) |j| {
                if (!pending[j] or srcs[j] != dsts[first]) continue;
                steps[len] = .{ .park = @intCast(j) };
                len += 1;
                parked[j] = true;
                _ = parks.fetchAdd(1, .monotonic);
            }
            break :blk first;
        };
        steps[len] = .{ .move = @intCast(ready) };
        len += 1;
        pending[ready] = false;
        left -= 1;
    }
    return steps[0..len];
}

fn readByOther(srcs: []const u64, place: u64, skip: usize, pending: *const [cap]bool, parked: *const [cap]bool) bool {
    for (srcs, 0..) |s, j| {
        if (j != skip and pending[j] and !parked[j] and s == place) return true;
    }
    return false;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Run `steps` on a machine whose place `p` starts out holding `100 + p`, and
/// require the parallel assignment: every destination holds what its source
/// held at the start, and no other place changed.
fn expectParallel(srcs: []const u64, dsts: []const u64, places: usize) !void {
    var buf: [2 * cap]Step = undefined;
    const steps = try schedule(srcs, dsts, &buf);
    var vals: [16]u64 = undefined;
    for (0..places) |p| vals[p] = 100 + p;
    var park: ?u64 = null;
    var reads_park: [cap]bool = @splat(false);
    var moved: usize = 0;
    for (steps) |st| switch (st) {
        .park => |i| {
            park = vals[srcs[i]];
            reads_park[i] = true;
        },
        .move => |i| {
            vals[dsts[i]] = if (reads_park[i]) park.? else vals[srcs[i]];
            moved += 1;
        },
    };
    try testing.expectEqual(srcs.len, moved);
    var written: [16]bool = @splat(false);
    for (srcs, dsts) |s, d| {
        try testing.expectEqual(100 + s, vals[d]);
        written[d] = true;
    }
    for (0..places) |p| {
        if (!written[p]) try testing.expectEqual(100 + p, vals[p]);
    }
}

test "schedule: every set of up to four moves over six places is a parallel assignment" {
    const places = 6;
    var sets: u32 = 0;
    var srcs: [4]u64 = undefined;
    var dsts: [4]u64 = undefined;
    for (1..5) |n| {
        const combos = try std.math.powi(usize, places, 2 * n);
        next: for (0..combos) |code| {
            var c = code;
            for (0..n) |i| {
                srcs[i] = c % places;
                c /= places;
                dsts[i] = c % places;
                c /= places;
                if (srcs[i] == dsts[i]) continue :next;
                for (dsts[0..i]) |d| if (d == dsts[i]) continue :next;
            }
            try expectParallel(srcs[0..n], dsts[0..n], places);
            sets += 1;
        }
    }
    try testing.expectEqual(@as(u32, 30 + 750 + 15000 + 225000), sets);
}

test "schedule: moves that do not overlap go out in queue order, unparked" {
    var buf: [2 * cap]Step = undefined;
    const steps = try schedule(&.{ 0, 1, 2 }, &.{ 5, 6, 7 }, &buf);
    try testing.expectEqualSlices(Step, &.{ .{ .move = 0 }, .{ .move = 1 }, .{ .move = 2 } }, steps);
}

test "schedule: a set shifted one place up goes out last move first" {
    var buf: [2 * cap]Step = undefined;
    const steps = try schedule(&.{ 0, 1, 2 }, &.{ 1, 2, 3 }, &buf);
    try testing.expectEqualSlices(Step, &.{ .{ .move = 2 }, .{ .move = 1 }, .{ .move = 0 } }, steps);
}

test "schedule: a swap parks the first destination for its reader" {
    var buf: [2 * cap]Step = undefined;
    const steps = try schedule(&.{ 1, 0 }, &.{ 0, 1 }, &buf);
    try testing.expectEqualSlices(Step, &.{ .{ .park = 1 }, .{ .move = 0 }, .{ .move = 1 } }, steps);
}

test "schedule: eight moves in one cycle, in two cycles, and in a cycle with a tail" {
    try expectParallel(&.{ 7, 0, 1, 2, 3, 4, 5, 6 }, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, 8);
    try expectParallel(&.{ 1, 2, 3, 0, 5, 6, 7, 4 }, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, 8);
    try expectParallel(&.{ 1, 0, 0, 2, 3, 3, 1, 9 }, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, 10);
}

test "schedule: a set that writes one place twice is refused" {
    var buf: [2 * cap]Step = undefined;
    try testing.expectError(error.RepeatedDestination, schedule(&.{ 0, 1 }, &.{ 5, 5 }, &buf));
    try testing.expectError(error.RepeatedDestination, schedule(&.{ 1, 0, 2, 1 }, &.{ 0, 1, 1, 2 }, &buf));
}

test "schedule: each park step is counted" {
    var buf: [2 * cap]Step = undefined;
    const before = parks.load(.monotonic);
    _ = try schedule(&.{ 1, 0, 3, 2 }, &.{ 0, 1, 2, 3 }, &buf); // two swaps
    _ = try schedule(&.{ 0, 1 }, &.{ 1, 2 }, &buf); // a chain
    try testing.expectEqual(before + 2, parks.load(.monotonic));
}
