//! What the emit declined, in terms a caller outside Zone 2 can name.
//!
//! `Error.UnsupportedOp` is one error name for every structural path the emit
//! cannot take, so `--engine jit` could only report the name and leave the
//! user to guess which construct in the module it was (#424). This slot
//! carries the missing half: the op, and the callee shape that refused it.
//!
//! **Why not `diagnostic.setDiag`.** That channel is the reason a run FAILED,
//! and a decline is not one — under `.auto` the interpreter runs the module
//! and the process exits 0, so a diagnostic set here would stand in the slot
//! for whatever the interpreter reported next (`cli/run.zig` keeps that slot
//! clean after a decline on purpose, and a test pins it). Zone 2 records the
//! fact; Zone 3 decides whether it is the user's failure, and reads the note
//! only on the `--engine jit` path where a decline IS the failure.
//!
//! `threadlocal`, like `diagnostic`'s own slot.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

/// Why an emit site refused the shape. One reason, not a set: a decline is a
/// single refusal, and the site reports the first condition that failed.
/// Counts, not prose — the wording is the reporting layer's to choose.
pub const Reason = union(enum) {
    /// 8-byte slots of overflow (stack) arguments the callee needs.
    overflow_words: u32,
    /// FP/SIMD arguments, where the register bank holds fewer.
    simd_args: u32,
    /// The callee's result count, above the 2 that return in registers.
    memory_class_results: u32,
};

pub const Note = struct {
    /// The declining op's wasm name — a static string.
    op: []const u8,
    reason: Reason,
};

threadlocal var last: ?Note = null;

/// Record what was declined, immediately before `return
/// Error.UnsupportedOp`. A compile stops at its first decline, so the note a
/// reader takes is the one that failed it.
pub fn set(op: []const u8, reason: Reason) void {
    @branchHint(.cold);
    last = .{ .op = op, .reason = reason };
}

/// Read and clear — a decline already reported must not be reported twice.
pub fn take() ?Note {
    defer last = null;
    return last;
}

/// Drop any note. Entry points call this before a compile so a note from
/// an earlier one cannot be read as this compile's reason.
pub fn clear() void {
    last = null;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "decline_note: take reads once and clears" {
    clear();
    defer clear();

    try testing.expectEqual(@as(?Note, null), take());
    set("return_call", .{ .overflow_words = 6 });
    const n = take().?;
    try testing.expectEqualStrings("return_call", n.op);
    try testing.expectEqual(@as(u32, 6), n.reason.overflow_words);
    // Consumed: a second read reports nothing, so one decline cannot be
    // printed twice.
    try testing.expectEqual(@as(?Note, null), take());
}

test "decline_note: the last decline wins, and carries its own reason" {
    clear();
    defer clear();

    set("return_call", .{ .overflow_words = 6 });
    set("return_call_ref", .{ .simd_args = 9 });
    const n = take().?;
    try testing.expectEqualStrings("return_call_ref", n.op);
    try testing.expectEqual(@as(u32, 9), n.reason.simd_args);
}
