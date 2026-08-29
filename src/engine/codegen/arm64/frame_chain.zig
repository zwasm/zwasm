//! AAPCS64 frame-chain read helper (ADR-0114 D6 / D5).
//!
//! Reads the caller's saved FP + saved LR out of an AAPCS64
//! frame prefix planted by the function prologue's
//! `STP X29, X30, [SP, #-16]!`. Per AAPCS64 §6.4 / Arm IHI 0055
//! the prologue's first two words are pinned at offsets:
//!
//!   [X29, #0]  = caller's saved FP (X29 of the caller)
//!   [X29, #8]  = caller's saved LR (X30 of the caller — the
//!                return address into the caller's function)
//!
//! This file owns the raw frame-prefix read. The trampoline
//! composes it into a
//! `unwind.FrameChainLoader` via a PC-normalization callback
//! (saved-LR is an absolute return address; the
//! `ExceptionTable.lookup` consumes module-relative PC, so the
//! trampoline converts the LR through the per-function
//! code-map lookup before calling `unwind.walk`).
//!
//! Unreadable frame pointer → null, which the trampoline
//! interprets as `.uncaught`. Two cases produce it: `fp == 0`, the
//! top-of-Wasm-stack sentinel the entry shim plants when it enters
//! the JIT body so the unwinder can detect "no more Wasm frames"
//! deterministically; and a non-zero `fp` that is not
//! machine-word-aligned, which cannot be a frame pointer at all
//! (see `readableFrame`).
//!
//! INVARIANT (paired with ADR-0114 D5 + ADR-0112 D7): this
//! function performs only two pointer-relative loads, no
//! allocator calls, no host-call invocations, no signal-check
//! branches.
//!
//! Spec: AAPCS64 §6.4 + Arm IHI 0055 §6.4.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");

/// One AAPCS64 frame prefix read. The trampoline converts
/// `caller_lr` (= the raw saved LR, an absolute return address)
/// to a module-relative PC via the active function's code-map
/// lookup before calling `unwind.walk`.
pub const RawFrameLink = struct {
    caller_fp: usize,
    caller_lr: usize,
};

/// A frame prefix is only readable at a machine-word-aligned `fp`. `fp == 0` is
/// the entry shim's top-of-Wasm-stack sentinel; a non-zero misaligned `fp` is
/// not a frame pointer at all — the chain escaped into host frames and the read
/// picked up a garbage stack word. Both mean "no caller frame this reader can
/// trust": return null and let `unwind.walk` report `.uncaught`. Dereferencing
/// instead panics ("incorrect alignment") in every safety-checked build.
inline fn readableFrame(fp: usize) bool {
    return fp != 0 and std.mem.isAligned(fp, @alignOf(usize));
}

/// Read the AAPCS64 frame prefix at `[fp, 0]` + `[fp, 8]`.
/// Returns null for the top-of-Wasm-stack sentinel (`fp == 0`)
/// planted by the entry shim.
///
/// Reads two 8-byte words from `fp`-relative memory. Caller is
/// responsible for ensuring `fp` is a valid X29 value (either
/// the trampoline's captured throw-site X29 or a walk-traversed
/// `caller_fp` from a prior step).
pub fn loadFrame(fp: usize) ?RawFrameLink {
    if (!readableFrame(fp)) return null;
    const slots: [*]const usize = @ptrFromInt(fp);
    return .{
        .caller_fp = slots[0],
        .caller_lr = slots[1],
    };
}

// ---------------------------------------------------------------------
// Unit tests — pure pointer read; synthetic frame planted in test
// memory. No JIT emit / no actual stack walk required.
// ---------------------------------------------------------------------

const testing = std.testing;

test "loadFrame: fp == 0 sentinel → null (top-of-stack)" {
    try testing.expectEqual(@as(?RawFrameLink, null), loadFrame(0));
}

test "loadFrame: reads [fp, 0] as caller_fp and [fp, 8] as caller_lr" {
    // Synthetic frame: a 2-slot u64 array on the stack acts as the
    // AAPCS64 frame prefix. Slot 0 = caller_fp; slot 1 = caller_lr.
    var frame: [2]usize = .{ 0xDEADBEEFCAFE, 0xFEEDFACE0001 };
    const fp: usize = @intFromPtr(&frame);

    const link = loadFrame(fp).?;
    try testing.expectEqual(@as(usize, 0xDEADBEEFCAFE), link.caller_fp);
    try testing.expectEqual(@as(usize, 0xFEEDFACE0001), link.caller_lr);
}

test "loadFrame: caller_fp == 0 propagates (next walk step would terminate)" {
    // The middle of a frame chain where the caller is top-of-stack:
    // saved FP = 0, saved LR = some entry-shim address.
    var frame: [2]usize = .{ 0, 0xAAAA1234 };
    const fp: usize = @intFromPtr(&frame);

    const link = loadFrame(fp).?;
    try testing.expectEqual(@as(usize, 0), link.caller_fp);
    try testing.expectEqual(@as(usize, 0xAAAA1234), link.caller_lr);
}

test "loadFrame: chained read — outer frame points at inner frame's prefix" {
    // Two-link chain: inner frame's saved-FP points back into
    // outer frame's slot-0 (which is the saved-FP-of-outer).
    var outer: [2]usize = .{ 0, 0x1111 };
    var inner: [2]usize = .{ @intFromPtr(&outer), 0x2222 };
    const inner_fp: usize = @intFromPtr(&inner);

    const inner_link = loadFrame(inner_fp).?;
    try testing.expectEqual(@intFromPtr(&outer), inner_link.caller_fp);
    try testing.expectEqual(@as(usize, 0x2222), inner_link.caller_lr);

    // Walk one step further.
    const outer_link = loadFrame(inner_link.caller_fp).?;
    try testing.expectEqual(@as(usize, 0), outer_link.caller_fp);
    try testing.expectEqual(@as(usize, 0x1111), outer_link.caller_lr);
}

test "loadFrame: unaligned fp → null (never dereferenced)" {
    // #323's twin on this arch. The x86_64 reader panicked ("incorrect
    // alignment") on a garbage `caller_fp` picked up once the chain escaped
    // into optimized host frames; AAPCS64 reaches the same reader through the
    // same `unwind.walk` loop, so it declines a misaligned `fp` the same way it
    // declines the `fp == 0` sentinel. Every misalignment 1..7 is covered: a
    // guard written against a narrower alignment would let +2 / +4 through.
    var frame: [2]usize = .{ 0xDEADBEEFCAFE, 0xFEEDFACE0001 };
    const aligned_fp: usize = @intFromPtr(&frame);
    for (1..@alignOf(usize)) |off| {
        try testing.expectEqual(@as(?RawFrameLink, null), loadFrame(aligned_fp + off));
    }
}
