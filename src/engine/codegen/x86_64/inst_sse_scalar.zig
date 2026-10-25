//! x86_64 SSE scalar + FP-packed encoder family — `encSseScalarBinary`,
//! `encUcomi{ss,sd}`, `encRoundss/sd`, `encSsePackedBinary`, and the
//! FP-domain packed shapes (ADDPS/SUBPS/MULPS/DIVPS/MINPS/MAXPS/
//! SQRTPS/CMPPS + PD variants, ORPS/ORPD/XORPS/XORPD/ANDPS/ANDPD/
//! ANDNPS/ANDNPD, ROUNDPS/ROUNDPD, CMPPS/CMPPD, CVTDQ2PS/CVTPS2PD/
//! CVTPD2PS/CVTDQ2PD/CVTTPS2DQ/CVTTPD2DQ, SHUFPS, UNPCKLPS, INSERTPS).
//!
//! Split from `inst_sse.zig` per ADR-0041 +
//! `.dev/phase10_prep/track_b_source_split.md` §4.2 (x86_64 encoder
//! source partition; chunk C/6).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");

const inst = @import("inst.zig");
const reg_class = @import("reg_class.zig");

const Xmm = reg_class.Xmm;
const EncodedInsn = inst.EncodedInsn;
const SseScalarKind = inst.SseScalarKind;
const SsePackedKind = inst.SsePackedKind;
const encodeRex = inst.encodeRex;
const encodeModrm = inst.encodeModrm;

/// SSE single-precision packed FP binop helper — `[REX?] 0F <opcode> /r`
/// (no 66 prefix). Used by PS-form FP packed encoders (ADDPS/SUBPS/
/// MULPS/DIVPS/MINPS/MAXPS/SQRTPS) and PS-form bitwise encoders
/// (ORPS/XORPS/ANDPS/ANDNPS).
fn encSseFpPsBinop(opcode: u8, dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// PD-form / 66-prefixed packed FP binop helper — `66 [REX?] 0F <opcode> /r`.
/// Bit-identical to `inst_sse_packed.encSsePackedIntBinop`; the
/// duplication keeps the two source files mutually independent.
fn encSsePd66Binop(opcode: u8, dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

// ---------------------------------------------------------------
// Scalar binary / compare / round family — SSE/SSE2 scalar shapes.
// ---------------------------------------------------------------

/// SSE2 scalar binary op (ADDSS / ADDSD / SUBSS / SUBSD /
/// MULSS / MULSD / DIVSS / DIVSD). Encoding:
///   <prefix> [REX?] 0x0F <opcode> ModR/M
/// where `<prefix>` is F3 (f32) or F2 (f64); `<opcode>` is
/// 0x58 (add), 0x5C (sub), 0x59 (mul), 0x5E (div).
pub fn encSseScalarBinary(kind: SseScalarKind, opcode: u8, dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(@backingInt(kind));
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// SSE2 packed bitwise binary (ANDPS/ANDPD/ORPS/ORPD/XORPS/XORPD).
/// `kind == .f32` skips the 66 prefix (PS form); `kind == .f64` adds it.
pub fn encSsePackedBinary(kind: SsePackedKind, opcode: u8, dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (kind != .f32) enc.push(@backingInt(kind));
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `ROUNDSS xmm, xmm/m32, imm8` (66 0F 3A 0A /r ib) — SSE4.1.
pub fn encRoundss(dst: Xmm, src: Xmm, mode: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x0A);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(mode);
    return enc;
}

/// `ROUNDSD xmm, xmm/m64, imm8` (66 0F 3A 0B /r ib) — SSE4.1.
pub fn encRoundsd(dst: Xmm, src: Xmm, mode: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x0B);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(mode);
    return enc;
}

/// `UCOMISS xmm, xmm/m32` (0x0F 0x2E /r). Sets ZF/CF/PF on the
/// comparison result. Used by emitFpCompare → SETcc.
pub fn encUcomiss(a: Xmm, b: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (a.extBit() != 0 or b.extBit() != 0) {
        enc.push(encodeRex(false, a.extBit(), 0, b.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x2E);
    enc.push(encodeModrm(0b11, a.low3(), b.low3()));
    return enc;
}

/// `UCOMISD xmm, xmm/m64` (0x66 prefix + 0x0F 0x2E /r).
pub fn encUcomisd(a: Xmm, b: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (a.extBit() != 0 or b.extBit() != 0) {
        enc.push(encodeRex(false, a.extBit(), 0, b.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x2E);
    enc.push(encodeModrm(0b11, a.low3(), b.low3()));
    return enc;
}

// ---------------------------------------------------------------
// FP packed bitwise — ORPS/ORPD/XORPS/XORPD/ANDPS/ANDPD/ANDNPS/ANDNPD.
// ---------------------------------------------------------------

/// `ORPS xmm, xmm` ([REX?] 0F 56 /r) — SSE bitwise OR (PS-form).
pub fn encOrps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x56, dst, src);
}

/// `ORPD xmm, xmm` (66 [REX?] 0F 56 /r) — SSE2 bitwise OR (PD-form).
pub fn encOrpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0x56, dst, src);
}

/// `XORPS xmm, xmm` ([REX?] 0F 57 /r) — SSE bitwise XOR.
pub fn encXorps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x57, dst, src);
}

/// `XORPD xmm, xmm` (66 [REX?] 0F 57 /r) — SSE2 bitwise XOR.
pub fn encXorpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0x57, dst, src);
}

/// `ANDPS xmm, xmm` ([REX?] 0F 54 /r) — SSE bitwise AND.
pub fn encAndps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x54, dst, src);
}

/// `ANDPD xmm, xmm` (66 [REX?] 0F 54 /r) — SSE2 bitwise AND.
pub fn encAndpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0x54, dst, src);
}

/// `ANDNPS xmm, xmm` ([REX?] 0F 55 /r) — SSE bitwise AND-NOT.
pub fn encAndnps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x55, dst, src);
}

/// `ANDNPD xmm, xmm` (66 [REX?] 0F 55 /r) — SSE2 bitwise AND-NOT.
pub fn encAndnpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0x55, dst, src);
}

// ---------------------------------------------------------------
// FP packed arithmetic — ADDPS/SUBPS/MULPS/DIVPS/SQRTPS/MINPS/MAXPS
// and the PD counterparts.
// ---------------------------------------------------------------

/// `ADDPS xmm, xmm` ([REX?] 0F 58 /r) — Wasm `f32x4.add`.
pub fn encAddps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x58, dst, src);
}

/// `SUBPS xmm, xmm` ([REX?] 0F 5C /r) — Wasm `f32x4.sub`.
pub fn encSubps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x5C, dst, src);
}

/// `MULPS xmm, xmm` ([REX?] 0F 59 /r) — Wasm `f32x4.mul`.
pub fn encMulps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x59, dst, src);
}

/// `DIVPS xmm, xmm` ([REX?] 0F 5E /r) — Wasm `f32x4.div`.
pub fn encDivps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x5E, dst, src);
}

/// `SQRTPS xmm, xmm` ([REX?] 0F 51 /r) — Wasm `f32x4.sqrt`.
pub fn encSqrtps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x51, dst, src);
}

/// `MINPS xmm, xmm` ([REX?] 0F 5D /r) — SSE packed min (PS-form).
pub fn encMinps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x5D, dst, src);
}

/// `MAXPS xmm, xmm` ([REX?] 0F 5F /r) — SSE packed max (PS-form).
pub fn encMaxps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x5F, dst, src);
}

/// `MINPD xmm, xmm` (66 [REX?] 0F 5D /r) — SSE2 packed min (PD-form).
pub fn encMinpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0x5D, dst, src);
}

/// `MAXPD xmm, xmm` (66 [REX?] 0F 5F /r) — SSE2 packed max (PD-form).
pub fn encMaxpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0x5F, dst, src);
}

/// `ADDPD xmm, xmm` (66 [REX?] 0F 58 /r) — Wasm `f64x2.add`.
pub fn encAddpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0x58, dst, src);
}

/// `SUBPD xmm, xmm` (66 [REX?] 0F 5C /r) — Wasm `f64x2.sub`.
pub fn encSubpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0x5C, dst, src);
}

/// `MULPD xmm, xmm` (66 [REX?] 0F 59 /r) — Wasm `f64x2.mul`.
pub fn encMulpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0x59, dst, src);
}

/// `DIVPD xmm, xmm` (66 [REX?] 0F 5E /r) — Wasm `f64x2.div`.
pub fn encDivpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0x5E, dst, src);
}

/// `SQRTPD xmm, xmm` (66 [REX?] 0F 51 /r) — Wasm `f64x2.sqrt`.
pub fn encSqrtpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0x51, dst, src);
}

// ---------------------------------------------------------------
// FP packed compare — CMPPS/CMPPD with imm8 predicate.
// ---------------------------------------------------------------

/// `CMPPS xmm, xmm, imm8` ([REX?] 0F C2 /r ib) — SSE PS compare.
pub fn encCmpps(dst: Xmm, src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0xC2);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(imm8);
    return enc;
}

/// `CMPPD xmm, xmm, imm8` (66 [REX?] 0F C2 /r ib) — SSE2 PD compare.
pub fn encCmppd(dst: Xmm, src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0xC2);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(imm8);
    return enc;
}

// ---------------------------------------------------------------
// FP packed rounding — ROUNDPS/ROUNDPD (SSE4.1).
// ---------------------------------------------------------------

/// `ROUNDPS xmm, xmm, imm8` (66 [REX?] 0F 3A 08 /r ib) — SSE4.1.
pub fn encRoundps(dst: Xmm, src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x08);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(imm8);
    return enc;
}

/// `ROUNDPD xmm, xmm, imm8` (66 [REX?] 0F 3A 09 /r ib) — SSE4.1.
pub fn encRoundpd(dst: Xmm, src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x09);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(imm8);
    return enc;
}

// ---------------------------------------------------------------
// FP packed conversions — CVTDQ2PS / CVTPS2PD / CVTPD2PS / CVTDQ2PD
// / CVTTPS2DQ / CVTTPD2DQ.
// ---------------------------------------------------------------

/// `CVTDQ2PS xmm, xmm` ([REX?] 0F 5B /r) — Wasm `f32x4.convert_i32x4_s`.
pub fn encCvtdq2ps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x5B, dst, src);
}

/// `CVTPS2PD xmm, xmm` ([REX?] 0F 5A /r) — Wasm `f64x2.promote_low_f32x4`.
pub fn encCvtps2pd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x5A, dst, src);
}

/// `CVTPD2PS xmm, xmm` (66 [REX?] 0F 5A /r) — Wasm `f32x4.demote_f64x2_zero`.
pub fn encCvtpd2ps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0x5A, dst, src);
}

/// `CVTDQ2PD xmm, xmm` (F3 [REX?] 0F E6 /r) — Wasm `f64x2.convert_low_i32x4_s`.
pub fn encCvtdq2pd(dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0xE6);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `CVTTPS2DQ xmm, xmm` (F3 [REX?] 0F 5B /r) — SSE2 truncating
/// convert 4 packed f32 → 4 packed signed i32.
pub fn encCvttps2dq(dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x5B);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `CVTTPD2DQ xmm, xmm` (66 [REX?] 0F E6 /r) — SSE2 truncating
/// convert 2 packed f64 → 2 packed i32 (high half zeroed).
pub fn encCvttpd2dq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePd66Binop(0xE6, dst, src);
}

// ---------------------------------------------------------------
// FP packed shuffle / interleave / lane-insert — SHUFPS, UNPCKLPS,
// INSERTPS (SSE4.1 scalar-into-lane).
// ---------------------------------------------------------------

/// `SHUFPS xmm, xmm, imm8` ([REX?] 0F C6 /r ib) — SSE shuffle 4 packed
/// single-precision lanes per imm8 selector.
pub fn encShufps(dst: Xmm, src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0xC6);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(imm8);
    return enc;
}

/// `UNPCKLPS xmm, xmm` ([REX?] 0F 14 /r) — SSE interleave low.
pub fn encUnpcklps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x14, dst, src);
}

/// `INSERTPS xmm, xmm/m32, imm8` (66 [REX?] 0F 3A 21 /r ib) — SSE4.1.
pub fn encInsertps(xmm_dst: Xmm, xmm_src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_dst.extBit() != 0 or xmm_src.extBit() != 0) {
        enc.push(encodeRex(false, xmm_dst.extBit(), 0, xmm_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x21);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), xmm_src.low3()));
    enc.push(imm8);
    return enc;
}

const testing = std.testing;

test "encRoundps / encRoundpd opcode bytes (xmm0, xmm1, imm=0x0A ceil+suppress)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x08, 0xC1, 0x0A }, encRoundps(.xmm0, .xmm1, 0x0A).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x09, 0xC1, 0x0A }, encRoundpd(.xmm0, .xmm1, 0x0A).slice());
}

test "encCvtdq2ps / encCvtps2pd opcode bytes (xmm0, xmm1) — no 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x5B, 0xC1 }, encCvtdq2ps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x5A, 0xC1 }, encCvtps2pd(.xmm0, .xmm1).slice());
}

test "encCvtpd2ps opcode bytes (xmm0, xmm1) — 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x5A, 0xC1 }, encCvtpd2ps(.xmm0, .xmm1).slice());
}

test "encCvtdq2pd opcode bytes (xmm0, xmm1) — F3 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0xE6, 0xC1 }, encCvtdq2pd(.xmm0, .xmm1).slice());
}

test "encShufps: SSE (xmm0, xmm1, imm=0x88) opcode 0F C6" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xC6, 0xC1, 0x88 }, encShufps(.xmm0, .xmm1, 0x88).slice());
}

test "encUnpcklps: SSE (xmm0, xmm1) opcode 0F 14" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x14, 0xC1 }, encUnpcklps(.xmm0, .xmm1).slice());
}

test "encCvttpd2dq: SSE2 (xmm0, xmm1) opcode 66 0F E6" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xE6, 0xC1 }, encCvttpd2dq(.xmm0, .xmm1).slice());
}

test "encCvttps2dq: F3 0F 5B /r" {
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0x5B, 0xC1 }, encCvttps2dq(.xmm0, .xmm1).slice());
}

test "encMinps / encMaxps opcode bytes (xmm0, xmm1) — SSE no 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x5D, 0xC1 }, encMinps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x5F, 0xC1 }, encMaxps(.xmm0, .xmm1).slice());
}

test "encMinpd / encMaxpd opcode bytes (xmm0, xmm1) — SSE2 with 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x5D, 0xC1 }, encMinpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x5F, 0xC1 }, encMaxpd(.xmm0, .xmm1).slice());
}

test "encOrps / encXorps / encAndps / encAndnps opcode bytes (xmm0, xmm1) — SSE no 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x56, 0xC1 }, encOrps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x57, 0xC1 }, encXorps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x54, 0xC1 }, encAndps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x55, 0xC1 }, encAndnps(.xmm0, .xmm1).slice());
}

test "encOrpd / encXorpd / encAndnpd opcode bytes (xmm0, xmm1) — SSE2 with 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x56, 0xC1 }, encOrpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x57, 0xC1 }, encXorpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x55, 0xC1 }, encAndnpd(.xmm0, .xmm1).slice());
}

test "encInsertps: lane 1 with count_s=0, ZMASK=0 (xmm0, xmm1, 0x10)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x21, 0xC1, 0x10 }, encInsertps(.xmm0, .xmm1, 0x10).slice());
}

test "encInsertps: REX.R+B (xmm8, xmm9, 0x30) — lane 3" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x3A, 0x21, 0xC1, 0x30 }, encInsertps(.xmm8, .xmm9, 0x30).slice());
}

test "encAddps / encSubps / encMulps / encDivps / encSqrtps opcode bytes (xmm0, xmm1) — SSE no 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x58, 0xC1 }, encAddps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x5C, 0xC1 }, encSubps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x59, 0xC1 }, encMulps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x5E, 0xC1 }, encDivps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x51, 0xC1 }, encSqrtps(.xmm0, .xmm1).slice());
}

test "encAddpd / encSubpd / encMulpd / encDivpd / encSqrtpd opcode bytes (xmm0, xmm1) — SSE2 with 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x58, 0xC1 }, encAddpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x5C, 0xC1 }, encSubpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x59, 0xC1 }, encMulpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x5E, 0xC1 }, encDivpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x51, 0xC1 }, encSqrtpd(.xmm0, .xmm1).slice());
}

test "encAddps: REX.R+B (xmm10, xmm12)" {
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0x58, 0xD4 }, encAddps(.xmm10, .xmm12).slice());
}

test "encCmpps opcode bytes (xmm0, xmm1, imm=0x01 LT) — SSE no 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xC2, 0xC1, 0x01 }, encCmpps(.xmm0, .xmm1, 0x01).slice());
}

test "encCmpps: REX.R+B (xmm10, xmm12, imm=0x04 NEQ)" {
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0xC2, 0xD4, 0x04 }, encCmpps(.xmm10, .xmm12, 0x04).slice());
}

test "encCmppd opcode bytes (xmm0, xmm1, imm=0x00 EQ) — SSE2 with 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xC2, 0xC1, 0x00 }, encCmppd(.xmm0, .xmm1, 0x00).slice());
}
