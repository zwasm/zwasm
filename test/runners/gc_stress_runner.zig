// DBG-INIT-EXEMPT: addTest target in build.zig — only the in-file test blocks run; this main is never executed.
//! GC stress runner skeleton (10.T-3; impl-body lands with 10.G).
//!
//! Per Phase 10 design plan §3.5 — once `feature/gc/heap.zig` +
//! `collector_mark_sweep.zig` ship at row 10.G, this runner
//! exercises the three stress shapes:
//!
//!   1. Heap pressure: 10^5 obj alloc → collect → re-alloc
//!      (verifies sweep returns memory to the per-Store slab
//!      free-list per ADR-0115 D5)
//!   2. Allocation-during-collect reentry guard
//!      (verifies ADR-0115 D9: thread-local `in_collect` flag
//!      catches mid-collect alloc; assert in Debug, null return
//!      in Release)
//!   3. Cyclic struct collect (verifies mark-sweep correctly
//!      reclaims cycles per ADR-0115 D3 mark_sweep collector)
//!
//! Until 10.G lands, this runner reports "skeleton (10.G impl
//! pending)" + exits 0 so `test-all` stays green regardless.
//!
//! Per ROADMAP §10 / 10.T-3 + design plan §3.5 "test strategy".

const std = @import("std");

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
};

const STRESS_CASES = [_][]const u8{
    "heap_pressure_1e5",
    "alloc_during_collect_reentry",
    "cyclic_struct_collect",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("[gc_stress_runner] skeleton (10.G impl pending; ADR-0115 + ADR-0116 Accept gates first)\n", .{});
    for (STRESS_CASES) |c| {
        try stdout.print("  [SKIP-P10-GC-GAP] {s} — runner impl awaits feature/gc/ at row 10.G\n", .{c});
    }
    try stdout.flush();
}

test "gc_stress_runner: STRESS_CASES list matches design plan §3.5" {
    try std.testing.expectEqual(@as(usize, 3), STRESS_CASES.len);
    try std.testing.expectEqualStrings("heap_pressure_1e5", STRESS_CASES[0]);
    try std.testing.expectEqualStrings("alloc_during_collect_reentry", STRESS_CASES[1]);
    try std.testing.expectEqualStrings("cyclic_struct_collect", STRESS_CASES[2]);
}
