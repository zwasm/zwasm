//! x86_64 prologue layout — single source of truth for byte offsets.
//!
//! Mirror of `arm64/prologue.zig` (ADR-0021). D-052 discharge:
//! the per-arch helper isolates prologue-shape knowledge to one
//! place so future Phase 8 / 15 changes (regalloc upgrade, AOT
//! skeleton, JIT-execution sentinel D-055) don't cascade through
//! the ~50-80 test sites that currently hardcode prologue byte
//! offsets via `out.bytes[N..M]` slices. D-081 (legacy
//! `emit_test_int.zig` / `emit_test_float.zig` rename) is the
//! follow-up that rides this helper landing.
//!
//! Prologue layout (per ADR-0026 Cc-pivot):
//!
//!   PUSH RBP                        (1 byte — 0x55)
//!   PUSH R15                        (2 bytes — REX.B + 0x57)  [if uses_runtime_ptr]
//!   MOV RBP, RSP                    (3 bytes — REX.W + 0x89 + modrm)
//!   MOV R15, <entry_arg0>           (3 bytes — REX.W + REX.R/B + 0x89 + modrm) [if uses_runtime_ptr]
//!   SUB RSP, frame_bytes            (4 or 7 bytes — imm8 vs imm32)  [if frame_bytes > 0]
//!
//! Body byte offsets (post-ADR-0105 D2 — uses_runtime_ptr cases
//! include the 21-byte stack-probe `LEA RAX, [RSP - frame_bytes]` (8)
//! + `CMP RAX, [R15 + stack_limit_off]` (7) + `JBE rel32` (6) inserted
//! BEFORE the 11-byte sentinel `MOV [R15 + flag_off], 1`):
//!
//!   uses_runtime_ptr | frame range | body_start_offset
//!   -----------------|-------------|-------------------
//!   false            | 0           |  4
//!   false            | 1..127      |  8
//!   false            | 128..       | 11
//!   true             | 1..127      | 105
//!   true             | 128..       | 108
//!
//! Probe + sentinel are gated on uses_runtime_ptr because both
//! use R15 (only loaded in the uses_runtime_ptr branch). The
//! probe is the x86_64 sibling of the arm64 prologue's
//! LDR X16 / SUB X17,SP,#frame / CMP / B.LS sequence (ADR-0105 D2).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");

/// Prologue prefix opcodes pinned by the SysV / Win64 ABI. These
/// are fixed regardless of frame shape; their byte offsets are
/// `0` (PUSH RBP) and either `1` (no R15) or `3` (with R15) for
/// the MOV RBP, RSP.
pub const Prefix = struct {
    /// `PUSH RBP` (opcode 0x50 + rbp.low3 = 0x55)
    pub const push_rbp: u8 = 0x55;
    /// `PUSH R15` REX.B + opcode (0x41, 0x57)
    pub const push_r15: [2]u8 = .{ 0x41, 0x57 };
    /// `MOV RBP, RSP` REX.W + 89 + modrm (0x48, 0x89, 0xE5)
    pub const mov_rbp_rsp: [3]u8 = .{ 0x48, 0x89, 0xE5 };
};

const push_rbp_size: u32 = 1;
const push_r15_size: u32 = 2;
const mov_rbp_rsp_size: u32 = 3;
const mov_r15_argptr_size: u32 = 3;
/// D-055 sentinel: `MOV DWORD PTR [R15 + flag_off], 1`
/// (REX.B + 0xC7 + ModR/M + disp32 + imm32 = 11 bytes for R15
/// base; REX.B is required since R15 is R8..R15 cohort). Emitted
/// inside the uses_runtime_ptr branch in emit.zig per ADR-0034.
const sentinel_size: u32 = 11;
/// ADR-0105 D2 stack-probe: `LEA RAX, [RSP - frame_bytes]` (8 bytes:
/// REX.W + 0x8D + ModR/M + SIB + disp32) + `CMP RAX, [R15 +
/// stack_limit_off]` (7 bytes: REX.W + 0x3B + ModR/M + disp32) + `JBE
/// rel32` (6 bytes: 0x0F 0x86 + disp32). Emitted inside the
/// uses_runtime_ptr branch BEFORE the sentinel; total 21 bytes.
const stack_probe_size: u32 = 21;
/// ADR-0179 #3a / D-314 interrupt poll (inside the uses_runtime_ptr branch,
/// after the stack probe, before the sentinel): MOV RAX,[R15+off] (7) +
/// TEST RAX,RAX (3) + JZ rel32 (6) + MOV EAX,[RAX] (6) + TEST EAX,EAX (2) +
/// JNE rel32 (6) = 30 bytes.
const interrupt_poll_size: u32 = 30;
/// ADR-0179 #3b / D-314 fuel poll (after the interrupt poll, before the
/// sentinel): MOV R11D,[R15+off] (7) + TEST R11D,R11D (3) + JZ rel32 (6) +
/// SUB QWORD [R15+off],1 (8) + JS rel32 (6) = 30 bytes.
const fuel_poll_size: u32 = 30;

/// SUB RSP, imm — picks imm8 (4 bytes) or imm32 (7 bytes) form
/// per `frame_bytes` range. Matches `rbp_disp.rspSub` dispatch:
/// `imm <= 127 → imm8`, otherwise `imm32`.
pub fn rsp_sub_size(frame_bytes: u32) u32 {
    if (frame_bytes == 0) return 0;
    return if (frame_bytes <= 127) 4 else 7;
}

/// First body instruction byte offset.
///
/// `uses_runtime_ptr` — true when the function body reads or
/// writes a runtime-derived value (memory access, host call,
/// dispatch slot). Prescan via `usage.usesRuntimePtr(func)` in
/// `emit.zig`.
///
/// `frame_bytes` — total stack space the prologue allocates:
/// locals + spill + outgoing_args + alignment padding. Per
/// emit.zig: `if (uses_runtime_ptr) ((frame_unaligned + 7) &
/// ~15) + 8` else `(frame_unaligned + 15) & ~15`.
///
/// When `frame_bytes == 0`, the SUB RSP step is omitted.
pub fn body_start_offset(uses_runtime_ptr: bool, frame_bytes: u32) u32 {
    var off: u32 = push_rbp_size + mov_rbp_rsp_size;
    if (uses_runtime_ptr) off += push_r15_size + mov_r15_argptr_size + stack_probe_size + interrupt_poll_size + fuel_poll_size + sentinel_size;
    off += rsp_sub_size(frame_bytes);
    return off;
}

/// Read a u32 word at `byte_offset` in `bytes` (little-endian).
/// Convenience for prologue-byte test patterns mirroring
/// `arm64/prologue.zig::wordAt`.
pub fn wordAt(bytes: []const u8, byte_offset: u32) u32 {
    return std.mem.readInt(u32, bytes[byte_offset..][0..4], .little);
}

/// One-line ABI sanity check: assert the prologue begins with
/// the ABI-pinned `PUSH RBP` byte. Optionally checks the
/// subsequent MOV RBP, RSP when `uses_runtime_ptr == false`
/// (when true, PUSH R15 intervenes — caller asserts that
/// separately if needed).
pub fn assertProloguePrefix(bytes: []const u8, uses_runtime_ptr: bool) error{
    PrologueTooShort,
    BadPushRbp,
    BadPushR15,
    BadMovRbpRsp,
}!void {
    if (bytes.len < push_rbp_size + mov_rbp_rsp_size) return error.PrologueTooShort;
    if (bytes[0] != Prefix.push_rbp) return error.BadPushRbp;
    if (uses_runtime_ptr) {
        if (bytes.len < push_rbp_size + push_r15_size + mov_rbp_rsp_size) return error.PrologueTooShort;
        if (bytes[1] != Prefix.push_r15[0] or bytes[2] != Prefix.push_r15[1]) return error.BadPushR15;
        const mov_off: usize = push_rbp_size + push_r15_size;
        if (!std.mem.eql(u8, bytes[mov_off..][0..mov_rbp_rsp_size], &Prefix.mov_rbp_rsp)) return error.BadMovRbpRsp;
    } else {
        if (!std.mem.eql(u8, bytes[push_rbp_size..][0..mov_rbp_rsp_size], &Prefix.mov_rbp_rsp)) return error.BadMovRbpRsp;
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "body_start_offset: no runtime_ptr, no frame → 4 bytes" {
    try testing.expectEqual(@as(u32, 4), body_start_offset(false, 0));
}

test "body_start_offset: no runtime_ptr, imm8 frame → 8 bytes" {
    try testing.expectEqual(@as(u32, 8), body_start_offset(false, 16));
    try testing.expectEqual(@as(u32, 8), body_start_offset(false, 127));
}

test "body_start_offset: no runtime_ptr, imm32 frame → 11 bytes" {
    try testing.expectEqual(@as(u32, 11), body_start_offset(false, 128));
    try testing.expectEqual(@as(u32, 11), body_start_offset(false, 4096));
}

test "body_start_offset: uses_runtime_ptr, imm8 frame → 105 bytes (incl. ADR-0105 probe +21 + D-055 sentinel +11)" {
    try testing.expectEqual(@as(u32, 105), body_start_offset(true, 16));
    try testing.expectEqual(@as(u32, 105), body_start_offset(true, 127));
}

test "body_start_offset: uses_runtime_ptr, imm32 frame → 108 bytes (incl. ADR-0105 probe +21 + D-055 sentinel +11)" {
    try testing.expectEqual(@as(u32, 108), body_start_offset(true, 128));
}

test "rsp_sub_size: 0 → 0, 1..127 → 4, >=128 → 7" {
    try testing.expectEqual(@as(u32, 0), rsp_sub_size(0));
    try testing.expectEqual(@as(u32, 4), rsp_sub_size(1));
    try testing.expectEqual(@as(u32, 4), rsp_sub_size(127));
    try testing.expectEqual(@as(u32, 7), rsp_sub_size(128));
    try testing.expectEqual(@as(u32, 7), rsp_sub_size(4096));
}

test "wordAt reads little-endian u32" {
    const bytes = [_]u8{ 0x55, 0x48, 0x89, 0xE5, 0xDE, 0xAD, 0xBE, 0xEF };
    try testing.expectEqual(@as(u32, 0xE5894855), wordAt(&bytes, 0));
    try testing.expectEqual(@as(u32, 0xEFBEADDE), wordAt(&bytes, 4));
}

test "assertProloguePrefix: accepts well-formed no-runtime-ptr prefix" {
    const bytes = [_]u8{ Prefix.push_rbp, 0x48, 0x89, 0xE5 };
    try assertProloguePrefix(&bytes, false);
}

test "assertProloguePrefix: accepts well-formed uses-runtime-ptr prefix" {
    const bytes = [_]u8{ Prefix.push_rbp, 0x41, 0x57, 0x48, 0x89, 0xE5 };
    try assertProloguePrefix(&bytes, true);
}

test "assertProloguePrefix: rejects bad PUSH RBP" {
    const bytes = [_]u8{ 0x00, 0x48, 0x89, 0xE5 };
    try testing.expectError(error.BadPushRbp, assertProloguePrefix(&bytes, false));
}

test "assertProloguePrefix: rejects bad MOV RBP RSP" {
    const bytes = [_]u8{ Prefix.push_rbp, 0xDE, 0xAD, 0xBE };
    try testing.expectError(error.BadMovRbpRsp, assertProloguePrefix(&bytes, false));
}

test "assertProloguePrefix: rejects too-short input" {
    const bytes = [_]u8{Prefix.push_rbp};
    try testing.expectError(error.PrologueTooShort, assertProloguePrefix(&bytes, false));
}

test "assertProloguePrefix: rejects bad PUSH R15 (uses-runtime-ptr)" {
    const bytes = [_]u8{ Prefix.push_rbp, 0x00, 0x00, 0x48, 0x89, 0xE5 };
    try testing.expectError(error.BadPushR15, assertProloguePrefix(&bytes, true));
}
