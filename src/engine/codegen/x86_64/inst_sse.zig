//! x86_64 SSE / scalar FP encoder foundation — MOV{SS,SD,UPS}
//! mem load/store XMM (RBP / RSP disp8 / disp32 / SIB base+idx),
//! MOV register-shape XMM↔XMM / XMM↔GPR (MOVAPS, MOVD, MOVQ,
//! MOVSD reg-reg, MOVLHPS), and scalar CVT helpers
//! (CVTTSS2SI/CVTTSD2SI, CVTSI2SS/CVTSI2SD), plus the
//! MOVUPS-RIP-relative const-pool placeholder + patch helper.
//!
//! Packed `encP*` shapes live in `inst_sse_packed.zig`; scalar /
//! FP-packed shapes (UCOMI, ROUNDSS/SD, ADDPS/CMPPS family, packed
//! cvts, INSERTPS, SHUFPS, UNPCKLPS, FP-bitwise) live in
//! `inst_sse_scalar.zig`. Split per ADR-0041 +
//! `.dev/phase10_prep/track_b_source_split.md` §4.2 (chunk A/6).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");

const inst = @import("inst.zig");
const reg_class = @import("reg_class.zig");

const Gpr = reg_class.Gpr;
const Xmm = reg_class.Xmm;
const EncodedInsn = inst.EncodedInsn;
const SseScalarKind = inst.SseScalarKind;
const encodeRex = inst.encodeRex;
const encodeModrm = inst.encodeModrm;
const encodeSib = inst.encodeSib;

/// `MOVSS [RBP + disp8], xmm` (F3 0F 11 /r) — store 32-bit FP
/// scalar to a stack slot. f32 local-store path (chunk 7).
pub fn encStoreXmmF32MemRBP(disp: i8, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b01, src.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOVSS xmm, [RBP + disp8]` (F3 0F 10 /r).
pub fn encLoadXmmF32MemRBP(dst: Xmm, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b01, dst.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOVSD [RBP + disp8], xmm` (F2 0F 11 /r) — 64-bit FP store.
pub fn encStoreXmmF64MemRBP(disp: i8, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b01, src.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOVSD xmm, [RBP + disp8]` (F2 0F 10 /r).
pub fn encLoadXmmF64MemRBP(dst: Xmm, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b01, dst.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOVSS [RBP + disp32], xmm` — disp32 form of `encStoreXmmF32MemRBP`.
pub fn encStoreXmmF32MemRBPDisp32(disp: i32, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b10, src.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVSS xmm, [RBP + disp32]` — disp32 form of `encLoadXmmF32MemRBP`.
pub fn encLoadXmmF32MemRBPDisp32(dst: Xmm, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b10, dst.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVSD [RBP + disp32], xmm` — disp32 form of `encStoreXmmF64MemRBP`.
pub fn encStoreXmmF64MemRBPDisp32(disp: i32, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b10, src.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVSD xmm, [RBP + disp32]` — disp32 form of `encLoadXmmF64MemRBP`.
pub fn encLoadXmmF64MemRBPDisp32(dst: Xmm, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b10, dst.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVUPS [RBP + disp8], xmm` (0F 11 /r) — 128-bit unaligned
/// packed-single store to a stack slot. v128
/// local-store path; mirror of `encStoreXmmF32MemRBP` minus the
/// F3 prefix (no prefix → MOVUPS form per Intel SDM Vol 2A).
pub fn encStoreXmmV128MemRBP(disp: i8, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b01, src.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOVUPS xmm, [RBP + disp8]` (0F 10 /r) — 128-bit load.
pub fn encLoadXmmV128MemRBP(dst: Xmm, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b01, dst.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOVUPS [RBP + disp32], xmm` — disp32 form of
/// `encStoreXmmV128MemRBP`.
pub fn encStoreXmmV128MemRBPDisp32(disp: i32, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b10, src.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVUPS xmm, [RBP + disp32]` — disp32 form of
/// `encLoadXmmV128MemRBP`.
pub fn encLoadXmmV128MemRBPDisp32(dst: Xmm, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b10, dst.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVUPS [RSP + disp32], xmm` (0F 11 /r) — 128-bit unaligned
/// store via RSP base. Win64 v128 marshal:
/// caller-side write into the 16-byte aligned scratch slot in
/// the outgoing-args region. RSP base requires a SIB byte
/// (scale=00, index=100 (none), base=100 (RSP) = 0x24) — that's
/// what differentiates this from `encMovupsXmmMemBaseDisp32`,
/// which asserts non-RSP base.
pub fn encStoreXmmV128MemRSPDisp32(src: Xmm, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b10, src.low3(), 0b100));
    enc.push(0x24);
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVSS [RSP + disp32], xmm` (F3 0F 11 /r). f32 caller-side
/// stack arg.
pub fn encStoreXmmF32MemRSPDisp32(src: Xmm, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b10, src.low3(), 0b100));
    enc.push(0x24);
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVSD [RSP + disp32], xmm` (F2 0F 11 /r). f64 caller-side
/// stack arg.
pub fn encStoreXmmF64MemRSPDisp32(src: Xmm, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b10, src.low3(), 0b100));
    enc.push(0x24);
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVD xmm, r/m32` (0x66 prefix + 0x0F 0x6E /r) — copy a
/// 32-bit GPR's low half into an XMM. Used by f32.const.
pub fn encMovdXmmFromR32(xmm_dst: Xmm, gpr_src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_dst.extBit() != 0 or gpr_src.extBit() != 0) {
        enc.push(encodeRex(false, xmm_dst.extBit(), 0, gpr_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x6E);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    return enc;
}

/// `MOVQ xmm, r/m64` (0x66 prefix + REX.W + 0x0F 0x6E /r) —
/// 64-bit MOVD-equivalent. REX.W is mandatory.
pub fn encMovqXmmFromR64(xmm_dst: Xmm, gpr_src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    enc.push(encodeRex(true, xmm_dst.extBit(), 0, gpr_src.extBit()));
    enc.push(0x0F);
    enc.push(0x6E);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    return enc;
}

/// `MOVAPS xmm, xmm` (0x0F 0x28 /r) — 128-bit aligned move
/// between XMM registers.
pub fn encMovapsXmmXmm(dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x28);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOVSS / MOVSD xmm,[base+idx]` and the store direction —
/// scalar single/double FP load/store with SIB scale=1.
pub fn encMovssMovsdMemBaseIdx(scalar_kind: SseScalarKind, is_store: bool, xmm: Xmm, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(@backingInt(scalar_kind));
    if (xmm.extBit() != 0 or base.extBit() != 0 or idx.extBit() != 0) {
        enc.push(encodeRex(false, xmm.extBit(), idx.extBit(), base.extBit()));
    }
    enc.push(0x0F);
    enc.push(if (is_store) @as(u8, 0x11) else 0x10);
    enc.push(encodeModrm(0b00, xmm.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVSS / MOVSD xmm, [base + disp32]` and the store direction —
/// scalar single/double FP load/store at a 32-bit displacement.
/// Used by `global.get` / `global.set` (f32 / f64) for 8-byte
/// Value slot at `[globals_base + byte_off]`.
pub fn encMovssMovsdXmmMemBaseDisp32(scalar_kind: SseScalarKind, is_store: bool, xmm: Xmm, base: Gpr, disp: i32) EncodedInsn {
    std.debug.assert(base.low3() != 4); // SIB escape — unsupported here
    var enc: EncodedInsn = .{};
    enc.push(@backingInt(scalar_kind));
    if (xmm.extBit() != 0 or base.extBit() != 0) {
        enc.push(encodeRex(false, xmm.extBit(), 0, base.extBit()));
    }
    enc.push(0x0F);
    enc.push(if (is_store) @as(u8, 0x11) else 0x10);
    enc.push(encodeModrm(0b10, xmm.low3(), base.low3()));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVUPS xmm, [base + disp32]` and the store direction — 128-bit
/// unaligned packed-single load/store at a 32-bit displacement.
pub fn encMovupsXmmMemBaseDisp32(is_store: bool, xmm: Xmm, base: Gpr, disp: i32) EncodedInsn {
    std.debug.assert(base.low3() != 4); // SIB escape — unsupported here
    var enc: EncodedInsn = .{};
    if (xmm.extBit() != 0 or base.extBit() != 0) {
        enc.push(encodeRex(false, xmm.extBit(), 0, base.extBit()));
    }
    enc.push(0x0F);
    enc.push(if (is_store) @as(u8, 0x11) else 0x10);
    enc.push(encodeModrm(0b10, xmm.low3(), base.low3()));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVUPS xmm, [base+idx]` and the store direction — 128-bit
/// unaligned packed-single load/store with SIB scale=1.
pub fn encMovupsMemBaseIdx(is_store: bool, xmm: Xmm, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (xmm.extBit() != 0 or base.extBit() != 0 or idx.extBit() != 0) {
        enc.push(encodeRex(false, xmm.extBit(), idx.extBit(), base.extBit()));
    }
    enc.push(0x0F);
    enc.push(if (is_store) @as(u8, 0x11) else 0x10);
    enc.push(encodeModrm(0b00, xmm.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `CVTTSS2SI r/m32 or r/m64, xmm/m32-or-64` — scalar truncating
/// float→signed-int conversion.
pub fn encCvttScalar2Int(scalar_kind: SseScalarKind, dst_is_64: bool, gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(@backingInt(scalar_kind));
    if (dst_is_64 or gpr_dst.extBit() != 0 or xmm_src.extBit() != 0) {
        enc.push(encodeRex(dst_is_64, gpr_dst.extBit(), 0, xmm_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x2C);
    enc.push(encodeModrm(0b11, gpr_dst.low3(), xmm_src.low3()));
    return enc;
}

/// `CVTSI2SS xmm, r/m32` / `CVTSI2SD xmm, r/m64` — signed integer
/// to scalar float conversion.
pub fn encCvtsi2Scalar(scalar_kind: SseScalarKind, src_is_64: bool, xmm_dst: Xmm, gpr_src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(@backingInt(scalar_kind));
    if (src_is_64 or xmm_dst.extBit() != 0 or gpr_src.extBit() != 0) {
        enc.push(encodeRex(src_is_64, xmm_dst.extBit(), 0, gpr_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x2A);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    return enc;
}

/// `MOVD r/m32, xmm` (0x66 + 0x0F 0x7E /r) — extract the low
/// 32 bits of an XMM into a GPR.
pub fn encMovdR32FromXmm(gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_src.extBit() != 0 or gpr_dst.extBit() != 0) {
        enc.push(encodeRex(false, xmm_src.extBit(), 0, gpr_dst.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x7E);
    enc.push(encodeModrm(0b11, xmm_src.low3(), gpr_dst.low3()));
    return enc;
}

/// `MOVQ r/m64, xmm` (0x66 + REX.W + 0x0F 0x7E /r) — extract
/// the low 64 bits of an XMM into a GPR. REX.W mandatory.
pub fn encMovqR64FromXmm(gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    enc.push(encodeRex(true, xmm_src.extBit(), 0, gpr_dst.extBit()));
    enc.push(0x0F);
    enc.push(0x7E);
    enc.push(encodeModrm(0b11, xmm_src.low3(), gpr_dst.low3()));
    return enc;
}

/// `MOVSD xmm, xmm` (F2 [REX?] 0F 10 /r, reg-reg form with mod=11) —
/// copies low 64 bits of src into low 64 of dst, preserving dst's
/// upper 64 (unlike the mem→reg load form which zeros the upper
/// 64 per Intel SDM Vol 2). Used by `f64x2.replace_lane` lane=0.
pub fn encMovsdXmmXmm(dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOVLHPS xmm, xmm` (0F 16 /r) — moves the low 64 bits of src
/// into the high 64 bits of dst. Used by `f64x2.replace_lane` lane=1.
pub fn encMovlhps(dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x16);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOVUPS xmm, [RIP+disp32]` placeholder — SSE PC-relative
/// 16-byte unaligned load. The disp32 field is initialised to 0;
/// the caller computes its byte offset post-append and records
/// a `SimdConstFixup` for the post-emit fixup pass to patch.
pub fn encMovupsXmmRipRelPlaceholder(dst: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, 0));
    }
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(0x05 | (@as(u8, dst.low3()) << 3));
    enc.push(0x00);
    enc.push(0x00);
    enc.push(0x00);
    enc.push(0x00);
    return enc;
}

/// Patch the disp32 field of a previously-emitted MOVUPS-RIP-rel
/// placeholder.
pub fn patchRipRelDisp32(buf: []u8, disp32_byte_offset: u32, disp32: i32) void {
    std.mem.writeInt(i32, buf[disp32_byte_offset..][0..4], disp32, .little);
}

const testing = std.testing;

test "encMovdXmmFromR32: xmm0, eax — 66 0F 6E ModRM" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x6E, 0xC0 }, encMovdXmmFromR32(.xmm0, .rax).slice());
}

test "encMovdXmmFromR32: xmm14, r10 — REX.R + REX.B" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x6E, 0xF2 }, encMovdXmmFromR32(.xmm14, .r10).slice());
}

test "encMovupsXmmRipRelPlaceholder: XMM0 → 6 bytes (0F 10 05 00 00 00 00)" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x10, 0x05, 0x00, 0x00, 0x00, 0x00 }, encMovupsXmmRipRelPlaceholder(.xmm0).slice());
}

test "encMovupsXmmRipRelPlaceholder: XMM8 → 7 bytes with REX.R (44 0F 10 05 00 00 00 00)" {
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x0F, 0x10, 0x05, 0x00, 0x00, 0x00, 0x00 }, encMovupsXmmRipRelPlaceholder(.xmm8).slice());
}

test "encMovupsXmmRipRelPlaceholder: XMM3 → ModR/M = 0x1D" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x10, 0x1D, 0x00, 0x00, 0x00, 0x00 }, encMovupsXmmRipRelPlaceholder(.xmm3).slice());
}

test "patchRipRelDisp32: writes signed disp32 to buf at offset" {
    var buf: [8]u8 = .{ 0, 0, 0, 0, 0xAA, 0xBB, 0xCC, 0xDD };
    patchRipRelDisp32(buf[0..], 4, -16);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0xF0, 0xFF, 0xFF, 0xFF }, &buf);
}

test "encMovsdXmmXmm: reg-reg (xmm0, xmm1) — F2 0F 10 with mod=11" {
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x0F, 0x10, 0xC1 }, encMovsdXmmXmm(.xmm0, .xmm1).slice());
}

test "encMovsdXmmXmm: REX.R+B (xmm8, xmm9)" {
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x45, 0x0F, 0x10, 0xC1 }, encMovsdXmmXmm(.xmm8, .xmm9).slice());
}

test "encMovlhps: reg-reg (xmm0, xmm1) — 0F 16 /r" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x16, 0xC1 }, encMovlhps(.xmm0, .xmm1).slice());
}

test "encMovlhps: REX.R+B (xmm8, xmm9)" {
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0x16, 0xC1 }, encMovlhps(.xmm8, .xmm9).slice());
}

test "encStoreXmmV128MemRBP: [RBP-16], xmm0 — `movups [rbp-16], xmm0` → 0F 11 45 F0" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x11, 0x45, 0xF0 }, encStoreXmmV128MemRBP(-16, .xmm0).slice());
}

test "encLoadXmmV128MemRBP: xmm0, [RBP-16] — `movups xmm0, [rbp-16]` → 0F 10 45 F0" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x10, 0x45, 0xF0 }, encLoadXmmV128MemRBP(.xmm0, -16).slice());
}

test "encStoreXmmV128MemRBP: [RBP+0], xmm0 — disp8=0 form" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x11, 0x45, 0x00 }, encStoreXmmV128MemRBP(0, .xmm0).slice());
}

test "encStoreXmmV128MemRBPDisp32: [RBP-1024], xmm15 — REX.R + disp32" {
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x0F, 0x11, 0xBD, 0x00, 0xFC, 0xFF, 0xFF }, encStoreXmmV128MemRBPDisp32(-1024, .xmm15).slice());
}

test "encLoadXmmV128MemRBPDisp32: xmm15, [RBP-1024] — REX.R + disp32" {
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x0F, 0x10, 0xBD, 0x00, 0xFC, 0xFF, 0xFF }, encLoadXmmV128MemRBPDisp32(.xmm15, -1024).slice());
}
