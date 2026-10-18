//! ARM64 prologue layout — single source of truth for byte offsets.
//!
//! Background (regret #6 from 2026-05-04 retrospective): test
//! suites in this layer hard-coded byte offsets like
//! `out.bytes[32..36]` to assert that the first body instruction
//! lands at byte 32 (after the 32-byte ARM64 prologue). When the
//! prologue grew during sub-2 (ADR-0017's 5 LDRs) the offset
//! cascade required manual updates at 124+ sites. Future prologue
//! changes (Phase 8 optimisation, Phase 15 v1 ports) would
//! re-trigger the same cascade.
//!
//! This module isolates prologue-shape knowledge to one place.
//! Per ADR-0021 (sub-deliverable a), the helper lands first; the
//! ~128 site bulk relativisation is sequenced under
//! sub-deliverable b alongside the emit.zig split.
//!
//! Prologue layout (per ADR-0017 + ADR-0034 + ADR-0105 D2):
//!
//!   Word 0:   STP X29, X30, [SP, #-16]!     (4 bytes — ABI-pinned)
//!   Word 1:   MOV X29, SP                   (4 bytes — ABI-pinned)
//!   Words 2-6: 5 LDRs into X28/X27/X26/W25/X24 (20 bytes — ADR-0017)
//!   Word 7:   ORR X19, XZR, X0  (= MOV X19, X0)  (4 bytes — ADR-0017 sub-2d-ii)
//!   Words 8-11: ADR-0105 D2 stack-probe         (16 bytes)
//!               LDR X16, [X19, #stack_limit_off]
//!               SUB X17, SP, #frame_bytes   (ADD X17, SP, #0 when no frame;
//!                                            a frame >= 4 KiB adds a word,
//!                                            as its SUB SP does)
//!               CMP X17, X16
//!               B.LS stack_overflow_trap_stub  (fixup)
//!   Words 12-16: ADR-0179 #3a / D-314 interrupt poll (20 bytes)
//!               LDR X16, [X19, #interrupt_ptr_off]
//!               CBZ X16, +4   (skip when no interrupt configured)
//!               LDR W17, [X16]
//!               CMP W17, WZR
//!               B.NE interrupted_trap_stub  (fixup)
//!   Words 17-23: ADR-0179 #3b / D-314 fuel poll (28 bytes)
//!               LDR W16, [X19, #fuel_metered_off]
//!               CBZ W16, +6   (skip when unmetered)
//!               LDR X17, [X19, #fuel_cell_off]
//!               SUB X17, X17, #1
//!               STR X17, [X19, #fuel_cell_off]
//!               CMP X17, XZR
//!               B.MI out_of_fuel_trap_stub  (fixup)
//!   Words 24-25: MOVZ X17,#1 + STR W17,[X19,#flag_off] (ADR-0034)
//!   Word 26 (optional, frame > 0): SUB SP, SP, #frame_bytes  (4 bytes)
//!
//! Total: 104 bytes (no frame) or 108 bytes (frame > 0). Words 0-1
//! are pinned by AAPCS64 (Arm IHI 0055 §6.4); the optional SUB SP
//! only appears when the function has locals + spill bytes.
//!
//! Zone 2 (`src/jit_arm64/`) — must NOT import `src/jit_x86/`
//! per ROADMAP §A3.

const std = @import("std");

/// AAPCS64-pinned prologue prefix opcodes. These are fixed by the
/// ABI; their offsets are byte 0 and byte 4 regardless of frame.
pub const FpLrSave = struct {
    /// `STP X29, X30, [SP, #-16]!`
    pub const stp_word: u32 = 0xA9BF7BFD;
    /// `MOV X29, SP` (encoded as `ADD X29, SP, #0`)
    pub const mov_fp_word: u32 = 0x910003FD;
};

/// First body instruction byte offset.
///
/// `has_frame` = true when the function has any locals OR any
/// spilled vregs (i.e. `frame_bytes > 0` in emit.zig). Tests
/// that exercise pure-register code pass `false`.
///
/// ADR-0034 JIT-execution sentinel adds 8 bytes
/// to every prologue (MOVZ X17, #1 + STR W17, [X19, #flag_off]),
/// shifting body_start from 32 → 40 (no frame) and 36 → 44
/// (with frame). ADR-0105 D2 adds the JIT-prologue stack-probe
/// (4 instructions / 16 bytes), shifting again to 56 → 60.
/// ADR-0179 #3a / D-314 adds the interrupt poll (5 instructions /
/// 20 bytes) after the stack probe, shifting to 76 → 80. ADR-0179
/// #3b adds the fuel poll (7 instructions / 28 bytes) after it,
/// shifting to 104 → 108.
///
/// Assumes a frame under 4 KiB. A frame of 4 KiB or more whose low
/// 12 bits are nonzero adds a word to the stack probe and another to
/// the frame allocation (#495), so its body starts 8 bytes later.
pub fn body_start_offset(has_frame: bool) u32 {
    return if (has_frame) 108 else 104;
}

/// Body-start offset for MEMORY-class returns (AAPCS64 §6.8.2;
/// ADR-0017 2026-05-18 amend + ADR-0069 §Phase 2 chunk (b)-e-1).
/// MEMORY-class functions emit a `STR X8, [SP, #slot]` (4 B)
/// after `SUB SP, SP, #frame_bytes` to capture the caller's
/// hidden indirect-result-pointer. The slot itself forces
/// `frame_bytes > 0`, so the base is `body_start_offset(true)`.
pub fn body_start_offset_memory_return() u32 {
    return body_start_offset(true) + 4;
}

/// Read a u32 word at `byte_offset` in `bytes` (little-endian).
/// Convenience wrapper for the common test pattern
/// `std.mem.readInt(u32, bytes[off..][0..4], .little)`.
pub fn wordAt(bytes: []const u8, byte_offset: u32) u32 {
    return std.mem.readInt(u32, bytes[byte_offset..][0..4], .little);
}

/// Read the prologue's first two ABI-pinned words and assert
/// they match the AAPCS64-mandated opcodes. One-line ABI sanity
/// check for tests that don't otherwise inspect the prologue.
pub fn assertPrologueOpcodes(bytes: []const u8) error{ PrologueTooShort, BadStpOpcode, BadMovFpOpcode }!void {
    if (bytes.len < 8) return error.PrologueTooShort;
    if (wordAt(bytes, 0) != FpLrSave.stp_word) return error.BadStpOpcode;
    if (wordAt(bytes, 4) != FpLrSave.mov_fp_word) return error.BadMovFpOpcode;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "body_start_offset: 104 bytes no frame, 108 bytes with frame (post-D-314 interrupt + fuel polls)" {
    try testing.expectEqual(@as(u32, 104), body_start_offset(false));
    try testing.expectEqual(@as(u32, 108), body_start_offset(true));
}

test "body_start_offset_memory_return: 112 bytes (MEMORY-class STR X8 after frame-SUB)" {
    try testing.expectEqual(@as(u32, 112), body_start_offset_memory_return());
}

test "wordAt reads u32 little-endian at offset" {
    const bytes = [_]u8{ 0xFD, 0x7B, 0xBF, 0xA9, 0xFD, 0x03, 0x00, 0x91 };
    try testing.expectEqual(FpLrSave.stp_word, wordAt(&bytes, 0));
    try testing.expectEqual(FpLrSave.mov_fp_word, wordAt(&bytes, 4));
}

test "assertPrologueOpcodes: accepts well-formed prefix" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], FpLrSave.stp_word, .little);
    std.mem.writeInt(u32, buf[4..8], FpLrSave.mov_fp_word, .little);
    try assertPrologueOpcodes(&buf);
}

test "assertPrologueOpcodes: rejects bad STP opcode" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0xDEADBEEF, .little);
    std.mem.writeInt(u32, buf[4..8], FpLrSave.mov_fp_word, .little);
    try testing.expectError(error.BadStpOpcode, assertPrologueOpcodes(&buf));
}

test "assertPrologueOpcodes: rejects bad MOV FP opcode" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], FpLrSave.stp_word, .little);
    std.mem.writeInt(u32, buf[4..8], 0xDEADBEEF, .little);
    try testing.expectError(error.BadMovFpOpcode, assertPrologueOpcodes(&buf));
}

test "assertPrologueOpcodes: rejects too-short input" {
    const buf: [4]u8 = undefined;
    try testing.expectError(error.PrologueTooShort, assertPrologueOpcodes(&buf));
}
