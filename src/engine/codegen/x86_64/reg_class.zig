//! x86_64 per-arch register-naming module.
//!
//! Mirrors the role of `arm64/abi.zig`'s `Xn` typedef but x86_64
//! is more bit-pattern complex — register access ≥ R8 requires a
//! REX prefix bit, and operand width is encoded via REX.W (1 =
//! 64-bit) or the 0x66 size-override prefix. So this module owns
//! the per-register split:
//!
//!   - `Gpr` — the 16 general-purpose registers (RAX..R15) as
//!     a 4-bit-backed enum. `low3()` returns the 3-bit field
//!     that fits ModR/M; `extBit()` returns the REX prefix bit
//!     (0 for RAX..RDI, 1 for R8..R15).
//!   - `Xmm` — the 16 SSE/AVX XMM scalar/SIMD registers, same
//!     low3 / extBit split.
//!   - `Width` — operand-size selector (b/w/d/q) used by the
//!     encoder to choose REX.W and / or the 0x66 prefix.
//!
//! Calling-convention layouts (System V x86_64 + Win64) live in
//! sibling `abi.zig`. The instruction
//! encoder lives in `inst.zig` and consumes
//! `Gpr` / `Xmm` / `Width` from this module.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const std = @import("std");

/// 16 x86_64 general-purpose registers. Numeric value matches
/// the AMD64 register encoding (RAX=0, RCX=1, …, R15=15) so
/// `low3()` is a 3-bit truncation.
pub const Gpr = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    /// Low 3 bits — the field that fits in ModR/M reg / rm.
    pub fn low3(self: Gpr) u3 {
        return @truncate(@as(u4, @backingInt(self)));
    }

    /// REX extension bit — 0 for RAX..RDI, 1 for R8..R15.
    /// Caller ORs this into the appropriate REX byte field
    /// (REX.R for ModR/M.reg, REX.B for ModR/M.rm or opcode-
    /// embedded reg, REX.X for SIB.index).
    pub fn extBit(self: Gpr) u1 {
        return @intCast(@backingInt(self) >> 3);
    }
};

/// 16 SSE/AVX XMM registers. Same low3 / extBit split as `Gpr`
/// — XMM8..XMM15 require REX.R / REX.B in the same way R8..R15
/// do for GPR encoding.
pub const Xmm = enum(u4) {
    xmm0 = 0,
    xmm1 = 1,
    xmm2 = 2,
    xmm3 = 3,
    xmm4 = 4,
    xmm5 = 5,
    xmm6 = 6,
    xmm7 = 7,
    xmm8 = 8,
    xmm9 = 9,
    xmm10 = 10,
    xmm11 = 11,
    xmm12 = 12,
    xmm13 = 13,
    xmm14 = 14,
    xmm15 = 15,

    pub fn low3(self: Xmm) u3 {
        return @truncate(@as(u4, @backingInt(self)));
    }

    pub fn extBit(self: Xmm) u1 {
        return @intCast(@backingInt(self) >> 3);
    }
};

/// Operand-size selector. The encoder maps:
///   .b → no REX.W, no 0x66 (8-bit; high byte regs need extra care)
///   .w → no REX.W, 0x66 size-override prefix (16-bit)
///   .d → no REX.W, no prefix (32-bit; default, also implicitly
///        zero-extends to 64 bits for write targets)
///   .q → REX.W = 1 (64-bit)
///
/// Wasm i32 maps to .d (zero-extend semantics native), Wasm i64
/// to .q. Sub-32-bit Wasm load/store ops use .b / .w with the
/// corresponding zero/sign-extend opcode (MOVZX / MOVSX) handled
/// in the encoder.
pub const Width = enum { b, w, d, q };

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Gpr: low3 truncates to 3 bits" {
    try testing.expectEqual(@as(u3, 0), Gpr.rax.low3());
    try testing.expectEqual(@as(u3, 7), Gpr.rdi.low3());
    try testing.expectEqual(@as(u3, 0), Gpr.r8.low3());
    try testing.expectEqual(@as(u3, 7), Gpr.r15.low3());
}

test "Gpr: extBit splits low/high register banks" {
    try testing.expectEqual(@as(u1, 0), Gpr.rax.extBit());
    try testing.expectEqual(@as(u1, 0), Gpr.rdi.extBit());
    try testing.expectEqual(@as(u1, 1), Gpr.r8.extBit());
    try testing.expectEqual(@as(u1, 1), Gpr.r15.extBit());
}

test "Gpr: stack / frame pointer indices match AMD64 encoding" {
    try testing.expectEqual(@as(u4, 4), @backingInt(Gpr.rsp));
    try testing.expectEqual(@as(u4, 5), @backingInt(Gpr.rbp));
}

test "Xmm: low3 + extBit mirror Gpr" {
    try testing.expectEqual(@as(u3, 0), Xmm.xmm0.low3());
    try testing.expectEqual(@as(u3, 7), Xmm.xmm7.low3());
    try testing.expectEqual(@as(u3, 0), Xmm.xmm8.low3());
    try testing.expectEqual(@as(u3, 7), Xmm.xmm15.low3());
    try testing.expectEqual(@as(u1, 0), Xmm.xmm0.extBit());
    try testing.expectEqual(@as(u1, 1), Xmm.xmm8.extBit());
}

test "Width: 4 named variants" {
    try testing.expectEqual(@as(u8, 4), @typeInfo(Width).@"enum".field_names.len);
}
