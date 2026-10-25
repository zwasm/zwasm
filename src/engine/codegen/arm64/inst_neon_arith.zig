// FILE-SIZE-EXEMPT: uniform pure-encoder catalog (per ADR-0075 amendment 2026-05-21)
//\! ARM64 NEON arithmetic & conversion encoder family —
//\! ADD/SUB/MUL/MIN/MAX/ABS/NEG/CNT/AVGR/sat-arith encoders
//\! (per-shape variants), shifts (USHL/SSHL/SSHR imm),
//\! across-lane reductions (UMAXV/UMINV/ADDV), ZIP1/EXT
//\! (i8x16.bitmask recipe), TBL (swizzle / shuffle), extend
//\! (SXTL/UXTL low/high), saturating narrow (SQXTN/SQXTUN),
//\! integer↔FP conversion (SCVTF/UCVTF/FCVTL/FCVTN/FCVTZ*),
//\! FP three-same arithmetic (FADD/FSUB/FMUL/FDIV), FP unary
//\! (FABS/FNEG/FSQRT/FRINT*), FP min/max (FMAX/FMIN).
//\!
//\! Split from `inst_neon.zig` per ADR-0041 (arm64 encoder
//\! source partition).
//\!
//\! Bit patterns from the Arm Architecture Reference Manual
//\! (DDI 0487, A64 SIMD&FP instructions). Each `pub fn enc<X>`
//\! returns the little-endian `u32` ready to write to the code
//\! buffer.
//\!
//\! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//\! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");
const inst_neon = @import("inst_neon.zig");

const Vn = inst_neon.Vn;

// =====================================================================
// Integer arithmetic (i32x4)
// =====================================================================

/// `ADD V<d>.<T>, V<n>.<T>, V<m>.<T>` — element-wise integer
/// add across a SIMD-128 register. The size field at bits
/// [23:22] selects the lane shape:
///   00 → 16B (i8x16)
///   01 → 8H  (i16x8)
///   10 → 4S  (i32x4)
///   11 → 2D  (i64x2)
///
/// Encoding (SIMD ADD vector, U=0, Q=1):
///   `0 1 0 01110 [size:2] 1 [Rm:5] 100001 [Rn:5] [Rd:5]`
///   = `0x4E208400 | (size << 22) | (Rm << 16) | (Rn << 5) | Rd`
///
/// Per Arm IHI 0055 §C7.2.5. SUB shares the same encoding shape
/// with U=1 (bit[29] set; base += 0x20000000).
/// `ADD V<d>.16B, V<n>.16B, V<m>.16B` — i8x16 lanewise add.
pub fn encAdd16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E208400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ADD V<d>.8H, V<n>.8H, V<m>.8H` — i16x8 lanewise add.
pub fn encAdd8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E608400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ADD V<d>.4S, V<n>.4S, V<m>.4S` — i32x4 lanewise add.
pub fn encAdd4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA08400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ADD V<d>.2D, V<n>.2D, V<m>.2D` — i64x2 lanewise add.
pub fn encAdd2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EE08400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB V<d>.16B, V<n>.16B, V<m>.16B` — i8x16 lanewise sub.
/// SUB encoding mirrors ADD with U=1 (bit[29]). Per §C7.2.339.
pub fn encSub16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E208400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB V<d>.8H, V<n>.8H, V<m>.8H` — i16x8 lanewise sub.
pub fn encSub8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E608400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB V<d>.4S, V<n>.4S, V<m>.4S` — i32x4 lanewise sub.
pub fn encSub4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EA08400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB V<d>.2D, V<n>.2D, V<m>.2D` — i64x2 lanewise sub.
pub fn encSub2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EE08400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MUL V<d>.<T>, V<n>.<T>, V<m>.<T>` — element-wise integer
/// multiply. Same encoding shape as ADD but bits[15:11] = 10011
/// (vs ADD's 10000); delta from ADD base = 0x1800.
///
/// Encoding (SIMD MUL vector, U=0, Q=1):
///   `0 1 0 01110 [size:2] 1 [Rm:5] 100111 [Rn:5] [Rd:5]`
///
/// Per Arm IHI 0055 §C7.2.222.
///
/// **Note**: NEON has no `MUL Vd.2D` form — i64x2.mul requires
/// a multi-instr synthesis (extract / scalar mul / insert) and
/// defers to the other 64-bit-lane ops
/// that need synthesis.
/// `MUL V<d>.16B, V<n>.16B, V<m>.16B` — i8x16 lanewise mul.
pub fn encMul16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E209C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MUL V<d>.8H, V<n>.8H, V<m>.8H` — i16x8 lanewise mul.
pub fn encMul8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E609C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MUL V<d>.4S, V<n>.4S, V<m>.4S` — i32x4 lanewise mul.
/// SSE4.1's PMULLD per ADR-0041 §"5. SSE4.1 minimum baseline".
pub fn encMul4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA09C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// Widening multiply (SMULL/UMULL + SMULL2/UMULL2) — Advanced SIMD
// "three different", opcode=1100. Base SMULL.8H = 0x0E20C000; +U
// (0x2000_0000) = unsigned; +Q (0x4000_0000) = the "2" (high-half
// source lanes); size[23:22] = 00 (.8H←.8B) / 01 (.4S←.4H) / 10
// (.2D←.2S). Plus ADDP (three-same, opcode=10111) for the dot
// pairwise reduce. ALL constants verified via `clang -c` + `otool
// -tvVj` (D-246: i32x4.dot_i16x8_s + i{16x8,32x4,64x2}.extmul_*).
// =====================================================================

/// `SMULL V<d>.8H, V<n>.8B, V<m>.8B` — signed widen-mul i8→i16, low 8 lanes.
pub fn encSmull8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x0E20C000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `SMULL2 V<d>.8H, V<n>.16B, V<m>.16B` — signed widen-mul i8→i16, high 8 lanes.
pub fn encSmull2_8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E20C000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `UMULL V<d>.8H, V<n>.8B, V<m>.8B` — unsigned widen-mul i8→i16, low 8 lanes.
pub fn encUmull8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x2E20C000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `UMULL2 V<d>.8H, V<n>.16B, V<m>.16B` — unsigned widen-mul i8→i16, high 8 lanes.
pub fn encUmull2_8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E20C000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `SMULL V<d>.4S, V<n>.4H, V<m>.4H` — signed widen-mul i16→i32, low 4 lanes.
pub fn encSmull4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x0E60C000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `SMULL2 V<d>.4S, V<n>.8H, V<m>.8H` — signed widen-mul i16→i32, high 4 lanes.
pub fn encSmull2_4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E60C000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `UMULL V<d>.4S, V<n>.4H, V<m>.4H` — unsigned widen-mul i16→i32, low 4 lanes.
pub fn encUmull4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x2E60C000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `UMULL2 V<d>.4S, V<n>.8H, V<m>.8H` — unsigned widen-mul i16→i32, high 4 lanes.
pub fn encUmull2_4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E60C000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `SMULL V<d>.2D, V<n>.2S, V<m>.2S` — signed widen-mul i32→i64, low 2 lanes.
pub fn encSmull2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x0EA0C000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `SMULL2 V<d>.2D, V<n>.4S, V<m>.4S` — signed widen-mul i32→i64, high 2 lanes.
pub fn encSmull2_2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA0C000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `UMULL V<d>.2D, V<n>.2S, V<m>.2S` — unsigned widen-mul i32→i64, low 2 lanes.
pub fn encUmull2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x2EA0C000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `UMULL2 V<d>.2D, V<n>.4S, V<m>.4S` — unsigned widen-mul i32→i64, high 2 lanes.
pub fn encUmull2_2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EA0C000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `ADDP V<d>.4S, V<n>.4S, V<m>.4S` — pairwise add adjacent i32 lanes
/// (used to reduce dot's 8 partial products to 4). Three-same, opcode 10111.
pub fn encAddp4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA0BC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `ADDP V<d>.8H, V<n>.8H, V<m>.8H` — add adjacent i16 pairs (relaxed_dot).
/// Same as encAddp4S but size=01 (bits 23:22): 0x4EA0… → 0x4E60….
pub fn encAddp8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E60BC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

test "encAddp8H: V0,V1,V2 + size field (10→01) differs from 4S" {
    try testing.expectEqual(@as(u32, 0x4E62BC20), encAddp8H(0, 1, 2));
    // size bits 23:22 flip 10(S)→01(H) → XOR = 0xC00000.
    try testing.expectEqual(@as(u32, 0xC00000), encAddp4S(0, 1, 2) ^ encAddp8H(0, 1, 2));
}

// =====================================================================
// Saturating add/sub (SQADD/UQADD/SQSUB/UQSUB) + saturating rounding
// doubling-mul-high (SQRDMULH) — Advanced SIMD three-same. Plus
// add-long-pairwise (SADDLP/UADDLP) — two-reg misc (1-src, widening).
// D-246 residual: i{8x16,16x8}.{add,sub}_sat_{s,u} + i16x8.q15mulr_sat_s
// + i{16x8,32x4}.extadd_pairwise_*_{s,u}. ALL constants clang+otool
// verified (`(s|u)q(add|sub)`/`sqrdmulh`/`(s|u)addlp` on v0,v1,v2).
// =====================================================================

/// `SQADD V<d>.16B, V<n>.16B, V<m>.16B` — signed saturating add i8x16.
pub fn encSqadd16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E200C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `UQADD V<d>.16B, V<n>.16B, V<m>.16B` — unsigned saturating add i8x16.
pub fn encUqadd16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E200C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `SQSUB V<d>.16B, V<n>.16B, V<m>.16B` — signed saturating sub i8x16.
pub fn encSqsub16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E202C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `UQSUB V<d>.16B, V<n>.16B, V<m>.16B` — unsigned saturating sub i8x16.
pub fn encUqsub16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E202C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `SQADD V<d>.8H, V<n>.8H, V<m>.8H` — signed saturating add i16x8.
pub fn encSqadd8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E600C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `UQADD V<d>.8H, V<n>.8H, V<m>.8H` — unsigned saturating add i16x8.
pub fn encUqadd8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E600C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `SQSUB V<d>.8H, V<n>.8H, V<m>.8H` — signed saturating sub i16x8.
pub fn encSqsub8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E602C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `UQSUB V<d>.8H, V<n>.8H, V<m>.8H` — unsigned saturating sub i16x8.
pub fn encUqsub8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E602C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `SQRDMULH V<d>.8H, V<n>.8H, V<m>.8H` — i16x8 saturating rounding
/// doubling multiply returning high half (Wasm `q15mulr_sat_s`).
pub fn encSqrdmulh8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E60B400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `SADDLP V<d>.8H, V<n>.16B` — signed add-long-pairwise i8→i16
/// (Wasm `i16x8.extadd_pairwise_i8x16_s`). Two-reg misc, 1-src.
pub fn encSaddlp8H(rd: Vn, rn: Vn) u32 {
    return 0x4E202800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `UADDLP V<d>.8H, V<n>.16B` — unsigned add-long-pairwise i8→i16.
pub fn encUaddlp8H(rd: Vn, rn: Vn) u32 {
    return 0x6E202800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `SADDLP V<d>.4S, V<n>.8H` — signed add-long-pairwise i16→i32.
pub fn encSaddlp4S(rd: Vn, rn: Vn) u32 {
    return 0x4E602800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `UADDLP V<d>.4S, V<n>.8H` — unsigned add-long-pairwise i16→i32.
pub fn encUaddlp4S(rd: Vn, rn: Vn) u32 {
    return 0x6E602800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// Integer unops (abs / neg / popcnt) — Advanced SIMD two-reg misc,
// Q=1, opcode=01011 (ABS/NEG) or 00101 (CNT, byte-only). U=0 → ABS,
// U=1 → NEG. size[23:22] selects 16B/8H/4S/2D. Constants verified
// via `clang -arch arm64`. Per Arm IHI 0055 §C7.2.1 / §C7.2.62 /
// §C7.2.230.
// =====================================================================

pub fn encAbs16B(rd: Vn, rn: Vn) u32 {
    return 0x4E20B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encAbs8H(rd: Vn, rn: Vn) u32 {
    return 0x4E60B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encAbs4S(rd: Vn, rn: Vn) u32 {
    return 0x4EA0B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encAbs2D(rd: Vn, rn: Vn) u32 {
    return 0x4EE0B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encNeg16B(rd: Vn, rn: Vn) u32 {
    return 0x6E20B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encNeg8H(rd: Vn, rn: Vn) u32 {
    return 0x6E60B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encNeg4S(rd: Vn, rn: Vn) u32 {
    return 0x6EA0B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encNeg2D(rd: Vn, rn: Vn) u32 {
    return 0x6EE0B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `CNT V<d>.16B, V<n>.16B` — per-byte popcount. Byte-only on
/// NEON (no 8H/4S/2D form). Same opcode field (00101) as MVN/NOT
/// but U=0 instead of U=1.
pub fn encCnt16B(rd: Vn, rn: Vn) u32 {
    return 0x4E205800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// Integer min/max + rounding-half-add (avgr_u) — Advanced SIMD three-same,
// Q=1. opcode 01101 = SMIN/UMIN, 01100 = SMAX/UMAX, 00010 = URHADD.
// U=0 → signed, U=1 → unsigned. size[23:22]: 00=.16B, 01=.8H, 10=.4S.
// NEON has no .2D form for these (per Arm IHI 0055 §C7.2.x); Wasm
// SIMD spec correspondingly omits i64x2 min/max/avgr. URHADD is
// unsigned-only and exists only for B/H per Wasm spec (no i32x4.avgr_u
// per the proposal). Constants verified via `clang -arch arm64`.
// =====================================================================

pub fn encSmin16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E206C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSmin8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E606C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSmin4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA06C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUmin16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E206C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUmin8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E606C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUmin4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EA06C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSmax16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E206400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSmax8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E606400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSmax4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA06400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUmax16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E206400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUmax8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E606400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUmax4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EA06400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUrhadd16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E201400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUrhadd8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E601400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// Per-element shifts — `USHL Vd.<T>, Vn.<T>, Vm.<T>` (vector form).
// Positive amount in Vm = shift left; negative = shift right (logical
// for U, arithmetic for S). Wasm shl uses USHL with positive amount;
// shr_u / shr_s use NEG-then-USHL/SSHL. Verified via `clang -arch
// arm64`. Per Arm IHI 0055 §C7.2.412 (USHL) / §C7.2.331 (SSHL).
// =====================================================================

pub fn encUshl16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E204400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUshl8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E604400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUshl4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EA04400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUshl2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EE04400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
// SSHL — signed counterpart of USHL (negative amount = arithmetic shift right). U=0.
pub fn encSshl16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E204400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSshl8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E604400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSshl4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA04400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSshl2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EE04400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// Across-lane reductions (UMAXV / UMINV) — Advanced SIMD across-lanes,
// Q=1, U=1, opcode=01010 (UMAXV) or 11010 (UMINV). size selects lane:
// 00=.16B, 01=.8H, 10=.4S. NEON has NO 2D form for these — i64x2
// reductions need GPR-side synthesis. Constants verified via
// `clang -arch arm64`. Per Arm IHI 0055 §C7.2.387 / §C7.2.394.
// =====================================================================

pub fn encUmaxv16B(rd: Vn, rn: Vn) u32 {
    return 0x6E30A800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUminv16B(rd: Vn, rn: Vn) u32 {
    return 0x6E31A800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUminv8H(rd: Vn, rn: Vn) u32 {
    return 0x6E71A800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUminv4S(rd: Vn, rn: Vn) u32 {
    return 0x6EB1A800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// Across-lane sum (ADDV) — Advanced SIMD across-lanes, Q=1, U=0,
// opcode=11011, size selects lane: 00=.16B, 01=.8H, 10=.4S. NEON
// has NO 2D form (i64x2 reductions take the scalar UMOV path).
// Per Arm IHI 0055 §C7.2.8. Constants verified by computing the
// Q-bit-set form of `encAddvB8B` (0x0E31B800 → 0x4E31B800).
// =====================================================================

pub fn encAddvB16B(rd: Vn, rn: Vn) u32 {
    return 0x4E31B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encAddvH8H(rd: Vn, rn: Vn) u32 {
    return 0x4E71B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encAddvS4S(rd: Vn, rn: Vn) u32 {
    return 0x4EB1B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// SSHR — Advanced SIMD vector right shift (signed, immediate).
// Encoding: `0 Q 0 011110 immh immb 0000 0 1 Rn Rd` with Q=1,
// immh:immb = (2*lane_width - shift). The high bits of immh
// discriminate lane width: 0001 → .16B, 001x → .8H, 01xx → .4S,
// 1xxx → .2D. Per Arm IHI 0055 §C7.2.325.
//
// Verified via clang-as on Mac aarch64:
//   sshr v0.16b, v1.16b, #7  → 0x4F090420
//   sshr v0.8h,  v1.8h,  #15 → 0x4F110420
//   sshr v0.4s,  v1.4s,  #31 → 0x4F210420
// =====================================================================

pub fn encSshrV16B(rd: Vn, rn: Vn, shift: u4) u32 {
    // shift ∈ 1..8. immh:immb = 16 - shift; immh = 0001, immb = (16-shift) & 7.
    const v: u32 = 16 - @as(u32, shift);
    return 0x4F000400 | (v << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

pub fn encSshrV8H(rd: Vn, rn: Vn, shift: u5) u32 {
    // shift ∈ 1..16. immh:immb = 32 - shift (occupies bits 22..16).
    const v: u32 = 32 - @as(u32, shift);
    return 0x4F000400 | (v << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

pub fn encSshrV4S(rd: Vn, rn: Vn, shift: u6) u32 {
    // shift ∈ 1..32. immh:immb = 64 - shift (occupies bits 22..16).
    const v: u32 = 64 - @as(u32, shift);
    return 0x4F000400 | (v << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// ZIP1 (vector, byte form) + EXT (vector, byte form). Used by the
// i8x16.bitmask recipe to fold 16 byte-mask lanes into 8 halfword
// reduction inputs. Per Arm IHI 0055 §C7.2.424 (ZIP1) / §C7.2.119
// (EXT). Constants verified via clang-as in the survey notes:
//   zip1 v0.16b, v1.16b, v2.16b   → 0x4E023820
//   ext  v0.16b, v1.16b, v2.16b, #8 → 0x6E024020
// =====================================================================

pub fn encZip1V16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E003800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

pub fn encExtV16B(rd: Vn, rn: Vn, rm: Vn, imm4: u4) u32 {
    return 0x6E000000 | (@as(u32, rm) << 16) | (@as(u32, imm4) << 11) | (@as(u32, rn) << 5) | @as(u32, rd);
}
/// `FADD V<d>.4S, V<n>.4S, V<m>.4S` — f32x4 lanewise add (IEEE-754
/// round-to-nearest-even, NaN-propagating per Wasm spec).
pub fn encFAdd4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E20D400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FADD V<d>.2D, V<n>.2D, V<m>.2D` — f64x2 lanewise add.
pub fn encFAdd2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E60D400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FSUB V<d>.4S, V<n>.4S, V<m>.4S` — f32x4 lanewise sub. Bit 23 = 1
/// (vs FADD's 0); same opcode bits[15:11] = 11010.
pub fn encFSub4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA0D400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FSUB V<d>.2D, V<n>.2D, V<m>.2D` — f64x2 lanewise sub.
pub fn encFSub2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EE0D400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FMUL V<d>.4S, V<n>.4S, V<m>.4S` — f32x4 lanewise mul. U=1,
/// opcode bits[15:11] = 11011.
pub fn encFMul4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E20DC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FMUL V<d>.2D, V<n>.2D, V<m>.2D` — f64x2 lanewise mul.
pub fn encFMul2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E60DC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FDIV V<d>.4S, V<n>.4S, V<m>.4S` — f32x4 lanewise div. U=1,
/// opcode bits[15:11] = 11111.
pub fn encFDiv4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E20FC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FDIV V<d>.2D, V<n>.2D, V<m>.2D` — f64x2 lanewise div.
pub fn encFDiv2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E60FC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ---------------------------------------------------------------------
// FP two-register-misc unary (FABS / FNEG / FSQRT /
// FRINTN / FRINTM / FRINTP / FRINTZ)
// ---------------------------------------------------------------------
// Wasm spec (SIMD) — `f32x4.{abs,neg,sqrt,ceil,floor,trunc,nearest}`
// and the f64x2 counterparts. Mapping:
//   abs     → FABS    (sign bit cleared)
//   neg     → FNEG    (sign bit toggled)
//   sqrt    → FSQRT   (IEEE-754 square root)
//   ceil    → FRINTP  (round toward +∞)
//   floor   → FRINTM  (round toward -∞)
//   trunc   → FRINTZ  (round toward zero)
//   nearest → FRINTN  (round to nearest, ties-to-even)
//
// Encoding family: "Advanced SIMD two-register miscellaneous (FP)"
//   `0 Q U 01110 a 1 sz 10000 opcode 10 Rn Rd`
// Q=1 for 128-bit form. U distinguishes (FABS/FRINT*=0, FNEG/FSQRT=1).
// Bit 23 ("a") + opcode disambiguate the op:
//   FABS    a=1 U=0 opcode=01111
//   FNEG    a=1 U=1 opcode=01111
//   FSQRT   a=1 U=1 opcode=11111
//   FRINTN  a=0 U=0 opcode=11000
//   FRINTM  a=0 U=0 opcode=11001
//   FRINTP  a=1 U=0 opcode=11000
//   FRINTZ  a=1 U=0 opcode=11001
// sz (bit 22) selects S (0) vs D (1) lanes. Bits 11:10 = 10.
// Per Arm IHI 0055 §C7.2.91 / §C7.2.135 / §C7.2.144 /
// §C7.2.138 / §C7.2.139 / §C7.2.140 / §C7.2.142.

pub fn encFAbs4S(rd: Vn, rn: Vn) u32 {
    return 0x4EA0F800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFAbs2D(rd: Vn, rn: Vn) u32 {
    return 0x4EE0F800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFNeg4S(rd: Vn, rn: Vn) u32 {
    return 0x6EA0F800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFNeg2D(rd: Vn, rn: Vn) u32 {
    return 0x6EE0F800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFSqrt4S(rd: Vn, rn: Vn) u32 {
    return 0x6EA1F800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFSqrt2D(rd: Vn, rn: Vn) u32 {
    return 0x6EE1F800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FRINTN V<d>.<T>, V<n>.<T>` — round to nearest, ties-to-even.
/// Wasm `f*x*.nearest`. a=0, opcode=11000.
pub fn encFRintN4S(rd: Vn, rn: Vn) u32 {
    return 0x4E218800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFRintN2D(rd: Vn, rn: Vn) u32 {
    return 0x4E618800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FRINTM V<d>.<T>, V<n>.<T>` — round toward -∞. Wasm `f*x*.floor`.
/// a=0, opcode=11001.
pub fn encFRintM4S(rd: Vn, rn: Vn) u32 {
    return 0x4E219800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFRintM2D(rd: Vn, rn: Vn) u32 {
    return 0x4E619800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FRINTP V<d>.<T>, V<n>.<T>` — round toward +∞. Wasm `f*x*.ceil`.
/// a=1, opcode=11000.
pub fn encFRintP4S(rd: Vn, rn: Vn) u32 {
    return 0x4EA18800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFRintP2D(rd: Vn, rn: Vn) u32 {
    return 0x4EE18800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FRINTZ V<d>.<T>, V<n>.<T>` — round toward zero. Wasm `f*x*.trunc`.
/// a=1, opcode=11001.
pub fn encFRintZ4S(rd: Vn, rn: Vn) u32 {
    return 0x4EA19800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFRintZ2D(rd: Vn, rn: Vn) u32 {
    return 0x4EE19800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ---------------------------------------------------------------------
// FMIN / FMAX (vector form, IEEE-754 NaN-propagating)
// ---------------------------------------------------------------------
// Wasm spec (SIMD) — `f32x4.{min,max}` and `f64x2.{min,max}`.
// IEEE-754-2008 min/max: NaN-propagating (any NaN input → NaN result).
// Maps directly to NEON FMIN/FMAX vector form:
//   FMAX: `0 Q 0 01110 0 sz 1 Rm 11110 1 Rn Rd` (bit 23 = 0)
//   FMIN: `0 Q 0 01110 1 sz 1 Rm 11110 1 Rn Rd` (bit 23 = 1)
// Per Arm IHI 0055 §C7.2.121 (FMAX) / §C7.2.125 (FMIN).
//
// `pmin` / `pmax` (pseudo-min/max) are synthesised
// via FCMGT + BSL since NEON has no direct pseudo-min instruction.

pub fn encFMax4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E20F400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFMax2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E60F400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFMin4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA0F400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFMin2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EE0F400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ---------------------------------------------------------------------
// FMLA / FMLS (vector, fused multiply-add/-subtract)
// ---------------------------------------------------------------------
// relaxed-SIMD `f{32,64}x4.relaxed_{madd,nmadd}` (ADR-0169: uniform
// fused on arm64). NEON FMLA Vd, Vn, Vm: `Vd = Vd + (Vn * Vm)` (single
// rounding); FMLS: `Vd = Vd - (Vn * Vm)`. The accumulator IS the dest,
// so the emit pre-loads `c` into Vd then FMLA/FMLS Vd, a, b.
//   madd  (a*b+c)    → Vd=c; FMLA Vd, a, b
//   nmadd (-(a*b)+c) → Vd=c; FMLS Vd, a, b
// Encoding `0 Q 0 01110 U sz 1 Rm 11001 1 Rn Rd` (opcode 11001, bit10=1);
// FMLS sets bit 23. Per Arm IHI 0055 §C7.2.131 (FMLA) / §C7.2.133 (FMLS).
pub fn encFmla4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E20CC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFmla2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E60CC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFmls4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA0CC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFmls2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EE0CC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

test "encFmla4S: V0,V1,V2 + FMLS bit23 + 2D sz bit22" {
    try testing.expectEqual(@as(u32, 0x4E22CC20), encFmla4S(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x800000), encFmls4S(0, 1, 2) ^ encFmla4S(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x400000), encFmla2D(0, 1, 2) ^ encFmla4S(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x4EFFCFFF), encFmls2D(31, 31, 31));
}
// ---------------------------------------------------------------------
// TBL (1-register table form)
// ---------------------------------------------------------------------
// Wasm spec (SIMD) — `i8x16.swizzle`:
//   for each lane k: output[k] = (indices[k] < 16) ? operand[indices[k]] : 0
//
// Maps directly to NEON `TBL Vd.16B, { Vn.16B }, Vm.16B`:
//   `0 Q 0 01110 00 0 Rm 0 len 0 00 Rn Rd` where len=00 (1-register table).
// NEON TBL semantics: output[k] = (Vm[k] < 16) ? Vn[Vm[k]] : 0 — exact
// Wasm match. Per Arm IHI 0055 §C7.2.299.
//
// `i8x16.shuffle` (with 16-byte index immediate) is deferred
// because TBL's 2-register form requires consecutive Rn, Rn+1 — the
// regalloc doesn't guarantee adjacency, so a copy-to-fixed-pair
// preamble is needed.

pub fn encTbl1Reg(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `TBL V<rd>.16B, { V<rn>.16B, V<rn+1>.16B }, V<rm>.16B` — table
/// lookup with 2-register table. Used for `i8x16.shuffle`. The table
/// occupies 32 bytes; indices 0..31 select; ≥32 → 0 (Wasm validates
/// this at parse, so OOB shouldn't reach codegen).
/// Encoding (TBL 2-register form): same base + len=01 (bits 14:13).
/// Per Arm IHI 0055 §C7.2.299. Rn must pair with Rn+1; the caller
/// ensures consecutive register placement (per ADR-0042 + audit
/// recommendation: copy-to-V30/V31 preamble at handler).
pub fn encTbl2Reg(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E002000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ---------------------------------------------------------------------
// SXTL / SXTL2 / UXTL / UXTL2 (extend low/high)
// ---------------------------------------------------------------------
// Wasm spec (SIMD) — `i*x*.extend_{low,high}_i*x*_{s,u}` (12 ops):
//   i16x8.extend_{low,high}_i8x16_{s,u}    via SXTL/SXTL2/UXTL/UXTL2 .8H
//   i32x4.extend_{low,high}_i16x8_{s,u}    via .4S forms
//   i64x2.extend_{low,high}_i32x4_{s,u}    via .2D forms
//
// Encoding family: "Advanced SIMD shift by immediate" (shift=0):
//   `0 Q U 01111 0 immh:4 immb:3 10100 1 Rn Rd`
// SXTL/UXTL are aliases of SSHLL/USHLL with immb=0; the "2" suffix
// (high-half form) sets Q=1, while the low-half form has Q=0.
// U=0 → signed extend (sign-bit copy); U=1 → unsigned (zero-fill).
// immh selects element-size:
//   0001 → 8B → 8H  (i16x8 ← i8x16)
//   0010 → 4H → 4S  (i32x4 ← i16x8)
//   0100 → 2S → 2D  (i64x2 ← i32x4)
// Per Arm IHI 0055 §C7.2.350 (SSHLL) / §C7.2.379 (USHLL) /
// §C7.2.393 (SXTL alias) / §C7.2.394 (UXTL alias).
// Handler shape is the standard `emitV128Unop` (pop 1 v128, push 1
// v128 — same as the FP unaries).

pub fn encSxtl8H(rd: Vn, rn: Vn) u32 {
    return 0x0F08A400 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSxtl2_8H(rd: Vn, rn: Vn) u32 {
    return 0x4F08A400 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSxtl4S(rd: Vn, rn: Vn) u32 {
    return 0x0F10A400 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSxtl2_4S(rd: Vn, rn: Vn) u32 {
    return 0x4F10A400 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSxtl2D(rd: Vn, rn: Vn) u32 {
    return 0x0F20A400 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSxtl2_2D(rd: Vn, rn: Vn) u32 {
    return 0x4F20A400 | (@as(u32, rn) << 5) | @as(u32, rd);
}

pub fn encUxtl8H(rd: Vn, rn: Vn) u32 {
    return 0x2F08A400 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUxtl2_8H(rd: Vn, rn: Vn) u32 {
    return 0x6F08A400 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUxtl4S(rd: Vn, rn: Vn) u32 {
    return 0x2F10A400 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUxtl2_4S(rd: Vn, rn: Vn) u32 {
    return 0x6F10A400 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUxtl2D(rd: Vn, rn: Vn) u32 {
    return 0x2F20A400 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUxtl2_2D(rd: Vn, rn: Vn) u32 {
    return 0x6F20A400 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ---------------------------------------------------------------------
// SQXTN/SQXTN2 + SQXTUN/SQXTUN2 (saturating narrow)
// ---------------------------------------------------------------------
// Wasm spec (SIMD) — `*.narrow_*_{s,u}` (4 ops):
//   i8x16.narrow_i16x8_s  → SQXTN  + SQXTN2 (.8H → .8B/.16B)
//   i8x16.narrow_i16x8_u  → SQXTUN + SQXTUN2 (.8H → .8B/.16B; signed
//                          source clamped to unsigned range — Wasm
//                          spec §4.4.3.X says negative inputs → 0)
//   i16x8.narrow_i32x4_s  → SQXTN  + SQXTN2 (.4S → .4H/.8H)
//   i16x8.narrow_i32x4_u  → SQXTUN + SQXTUN2 (.4S → .4H/.8H)
//
// NEON destination semantics (the design enabler):
//   Q=0 form (low):  Vd[63:0] = sat-narrow(Vn); Vd[127:64] = 0
//   Q=1 form (high): Vd[127:64] = sat-narrow(Vn); Vd[63:0] preserved
// Sequence: SQXTN result.<half>, lhs.<full>; SQXTN2 result.<full>, rhs.<full>
// — second instruction's preserve-lower semantics replaces the need
// for a scratch register (cranelift uses the same pattern).
//
// Encoding family "Advanced SIMD two-register miscellaneous":
//   `0 Q U 01110 size:2 10000 opcode:5 10 Rn Rd`
// SQXTN  : U=0, opcode=10100
// SQXTUN : U=1, opcode=10010
// size: 00=8H→8B, 01=4S→4H, 10=2D→2S (only 00/01 used by Wasm narrow).
// Per Arm IHI 0055 §C7.2.330 (SQXTN) / §C7.2.339 (SQXTUN).

pub fn encSqxtn8B(rd: Vn, rn: Vn) u32 {
    return 0x0E214800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSqxtn2_16B(rd: Vn, rn: Vn) u32 {
    return 0x4E214800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSqxtn4H(rd: Vn, rn: Vn) u32 {
    return 0x0E614800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSqxtn2_8H(rd: Vn, rn: Vn) u32 {
    return 0x4E614800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

pub fn encSqxtun8B(rd: Vn, rn: Vn) u32 {
    return 0x2E212800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSqxtun2_16B(rd: Vn, rn: Vn) u32 {
    return 0x6E212800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSqxtun4H(rd: Vn, rn: Vn) u32 {
    return 0x2E612800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encSqxtun2_8H(rd: Vn, rn: Vn) u32 {
    return 0x6E612800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ---------------------------------------------------------------------
// SCVTF / UCVTF (vector form, integer → FP)
// ---------------------------------------------------------------------
// Wasm spec — `f32x4.convert_i32x4_{s,u}` (single instruction) +
// `f64x2.convert_low_i32x4_{s,u}` (2-instruction synthesis: extend
// lower 2 i32 lanes to i64 via SXTL/UXTL .2D, then SCVTF/UCVTF .2D
// in place — same pattern cranelift uses per lower.isle).
//
// Encoding family "Advanced SIMD two-register miscellaneous (FP)":
//   `0 Q U 01110 0 sz 1 0000 1 11011 0 Rn Rd`
// Q=1 (vector form), sz=0 (.4S, i32→f32) or sz=1 (.2D, i64→f64).
// U=0 → SCVTF (signed), U=1 → UCVTF (unsigned).
// Per Arm IHI 0055 §C7.2.343 (SCVTF) / §C7.2.371 (UCVTF). Bases
// cross-checked against wasmtime/cranelift emit_tests.rs:5034-5046.
// IEEE-754 round-to-nearest-even (FPCR RMode=00 default) matches
// Wasm spec §4.3.2.11-13.

pub fn encScvtf4S(rd: Vn, rn: Vn) u32 {
    return 0x4E21D800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encScvtf2D(rd: Vn, rn: Vn) u32 {
    return 0x4E61D800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUcvtf4S(rd: Vn, rn: Vn) u32 {
    return 0x6E21D800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encUcvtf2D(rd: Vn, rn: Vn) u32 {
    return 0x6E61D800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ---------------------------------------------------------------------
// FCVTL / FCVTN (FP narrow / widen)
// ---------------------------------------------------------------------
// Wasm spec — `f64x2.promote_low_f32x4` (FCVTL .2D, .2S — widens
// lower 2 f32 lanes to 2 f64) + `f32x4.demote_f64x2_zero` (FCVTN
// .2S, .2D — narrows 2 f64 → lower 2 f32 lanes; Q=0 form zeros
// upper 64 bits, matching Wasm `_zero` semantic).
//
// Encoding family "Advanced SIMD two-register miscellaneous (FP)":
//   `0 Q U 01110 0 sz 1 0000 1 opcode 0 Rn Rd`
// FCVTL: opcode = 10111, sz = 01 → .2S source
// FCVTN: opcode = 10110, sz = 01 → .2D source / .2S dest
// Per Arm IHI 0055 §C7.2.116 (FCVTL) / §C7.2.118 (FCVTN). Bases
// cross-checked against wasmtime/cranelift emit_tests.rs:3111-3142.
// FPCR RMode=00 default → IEEE-754 round-to-nearest-even, matches
// Wasm spec §4.3.3.

pub fn encFCvtl_2D_2S(rd: Vn, rn: Vn) u32 {
    return 0x0E617800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFCvtn_2S_2D(rd: Vn, rn: Vn) u32 {
    return 0x0E616800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ---------------------------------------------------------------------
// FCVTZS/FCVTZU + SQXTN/UQXTN .2S form
// ---------------------------------------------------------------------
// Wasm spec — `i32x4.trunc_sat_f32x4_{s,u}` (single FCVTZS/U .4S
// instruction; NaN→0 + saturation match NEON default per Arm IHI
// 0055 §C7.2.131-133) + `i32x4.trunc_sat_f64x2_{s,u}_zero`
// (2-instruction synthesis: FCVTZS/U .2D narrows f64→i64 with sat,
// then SQXTN/UQXTN .2S narrows i64→i32 with sat; Q=0 form clears
// upper 2 lanes, matching Wasm `_zero` semantic).
//
// FCVTZS/FCVTZU encoding "Advanced SIMD two-register misc (FP)":
//   `0 Q U 01110 1 sz 1 0000 1 11011 0 Rn Rd`
// Q=1, U=0 → FCVTZS; U=1 → FCVTZU. sz=0 → .4S, sz=1 → .2D.
// Per Arm IHI 0055 §C7.2.131 (FCVTZS) / §C7.2.133 (FCVTZU).
// Bases cross-checked against wasmtime/cranelift emit_tests.rs:
// 4985-5025.
//
// SQXTN/UQXTN .2S form (i64→i32 saturating narrow): same family
// as the .8B/.4H forms with size=10 (.2D source → .2S dest).

pub fn encFcvtzs4S(rd: Vn, rn: Vn) u32 {
    return 0x4EA1B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFcvtzs2D(rd: Vn, rn: Vn) u32 {
    return 0x4EE1B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFcvtzu4S(rd: Vn, rn: Vn) u32 {
    return 0x6EA1B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFcvtzu2D(rd: Vn, rn: Vn) u32 {
    return 0x6EE1B800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SQXTN V<rd>.2S, V<rn>.2D` — signed sat narrow i64→i32.
/// Used for f64x2.trunc_sat_*_s_zero synthesis. size=10.
pub fn encSqxtn2S(rd: Vn, rn: Vn) u32 {
    return 0x0EA14800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `UQXTN V<rd>.2S, V<rn>.2D` — unsigned sat narrow u64→u32.
/// Used for f64x2.trunc_sat_*_u_zero synthesis. size=10, U=1.
pub fn encUqxtn2S(rd: Vn, rn: Vn) u32 {
    return 0x2EA14800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "encAdd4S: V0, V1, V2" {
    // 0x4EA08400 | (2 << 16) | (1 << 5) | 0 = 0x4EA28420
    try testing.expectEqual(@as(u32, 0x4EA28420), encAdd4S(0, 1, 2));
}

test "encAdd4S: V31, V31, V31" {
    // 0x4EA08400 | (31 << 16) | (31 << 5) | 31 = 0x4EBF87FF
    try testing.expectEqual(@as(u32, 0x4EBF87FF), encAdd4S(31, 31, 31));
}

test "encAdd4S vs encOrrV16B: distinct opcodes (4S add ≠ 16B or)" {
    // Sanity: same operands produce different bytes.
    try testing.expect(encAdd4S(0, 1, 2) != inst_neon.encOrrV16B(0, 1, 2));
}

// D-246: widening multiply + ADDP. Expected bytes verified via
// `clang -c` + `otool -tvVj` of `(s|u)mull(2)?` + `addp` on v0,v1,v2.
test "encSmull/Umull + Addp: V0,V1,V2 verified vs clang" {
    // .8H (i8→i16)
    try testing.expectEqual(@as(u32, 0x0E22C020), encSmull8H(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x4E22C020), encSmull2_8H(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x2E22C020), encUmull8H(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x6E22C020), encUmull2_8H(0, 1, 2));
    // .4S (i16→i32)
    try testing.expectEqual(@as(u32, 0x0E62C020), encSmull4S(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x4E62C020), encSmull2_4S(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x2E62C020), encUmull4S(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x6E62C020), encUmull2_4S(0, 1, 2));
    // .2D (i32→i64)
    try testing.expectEqual(@as(u32, 0x0EA2C020), encSmull2D(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x4EA2C020), encSmull2_2D(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x2EA2C020), encUmull2D(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x6EA2C020), encUmull2_2D(0, 1, 2));
    // ADDP.4S
    try testing.expectEqual(@as(u32, 0x4EA2BC20), encAddp4S(0, 1, 2));
}

// D-246 residual: saturating add/sub + SQRDMULH + add-long-pairwise.
// Expected bytes verified via `clang -c` + `otool -tvVj`.
test "encSqadd/Sqsub/Sqrdmulh/Saddlp etc: V0,V1,(V2) verified vs clang" {
    // sat add/sub .16B
    try testing.expectEqual(@as(u32, 0x4E220C20), encSqadd16B(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x6E220C20), encUqadd16B(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x4E222C20), encSqsub16B(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x6E222C20), encUqsub16B(0, 1, 2));
    // sat add/sub .8H
    try testing.expectEqual(@as(u32, 0x4E620C20), encSqadd8H(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x6E620C20), encUqadd8H(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x4E622C20), encSqsub8H(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x6E622C20), encUqsub8H(0, 1, 2));
    // SQRDMULH .8H (q15mulr_sat_s)
    try testing.expectEqual(@as(u32, 0x6E62B420), encSqrdmulh8H(0, 1, 2));
    // add-long-pairwise (1-src)
    try testing.expectEqual(@as(u32, 0x4E202820), encSaddlp8H(0, 1));
    try testing.expectEqual(@as(u32, 0x6E202820), encUaddlp8H(0, 1));
    try testing.expectEqual(@as(u32, 0x4E602820), encSaddlp4S(0, 1));
    try testing.expectEqual(@as(u32, 0x6E602820), encUaddlp4S(0, 1));
}

// Int-unop encoders. Expected bytes verified via
// `clang -arch arm64` of `(abs|neg).(16b|8h|4s|2d) v0, v1` and
// `cnt.16b v0, v1`.
test "encAbs/encNeg/encCnt: V0, V1 across shapes" {
    try testing.expectEqual(@as(u32, 0x4E20B820), encAbs16B(0, 1));
    try testing.expectEqual(@as(u32, 0x4E60B820), encAbs8H(0, 1));
    try testing.expectEqual(@as(u32, 0x4EA0B820), encAbs4S(0, 1));
    try testing.expectEqual(@as(u32, 0x4EE0B820), encAbs2D(0, 1));
    try testing.expectEqual(@as(u32, 0x6E20B820), encNeg16B(0, 1));
    try testing.expectEqual(@as(u32, 0x6E60B820), encNeg8H(0, 1));
    try testing.expectEqual(@as(u32, 0x6EA0B820), encNeg4S(0, 1));
    try testing.expectEqual(@as(u32, 0x6EE0B820), encNeg2D(0, 1));
    try testing.expectEqual(@as(u32, 0x4E205820), encCnt16B(0, 1));
}

test "encUmaxv/encUminv: V0, V1 across shapes" {
    // `clang -arch arm64` of `umaxv b0, v1.16b` / `uminv {b,h,s}0, v1.{16b,8h,4s}`.
    try testing.expectEqual(@as(u32, 0x6E30A820), encUmaxv16B(0, 1));
    try testing.expectEqual(@as(u32, 0x6E31A820), encUminv16B(0, 1));
    try testing.expectEqual(@as(u32, 0x6E71A820), encUminv8H(0, 1));
    try testing.expectEqual(@as(u32, 0x6EB1A820), encUminv4S(0, 1));
}

test "encAbs vs encNeg: U bit (29) is the only difference" {
    try testing.expectEqual(@as(u32, 0x20000000), encNeg16B(0, 0) ^ encAbs16B(0, 0));
    try testing.expectEqual(@as(u32, 0x20000000), encNeg2D(31, 30) ^ encAbs2D(31, 30));
    // Max indices.
    try testing.expectEqual(@as(u32, 0x4E20BBFF), encAbs16B(31, 31));
    try testing.expectEqual(@as(u32, 0x6EE0BBFF), encNeg2D(31, 31));
}
// ============================================================
// ADDV / SSHR / ZIP1 / EXT encoder tests
// (i*x*.bitmask recipe). Bit patterns cross-checked against
// clang-as on Mac aarch64.
// ============================================================

test "encAddvB16B: B0 ← addv V0.16B → 0x4E31B800" {
    try testing.expectEqual(@as(u32, 0x4E31B800), encAddvB16B(0, 0));
}
test "encAddvH8H: H0 ← addv V0.8H → 0x4E71B800" {
    try testing.expectEqual(@as(u32, 0x4E71B800), encAddvH8H(0, 0));
}
test "encAddvS4S: S0 ← addv V0.4S → 0x4EB1B800" {
    try testing.expectEqual(@as(u32, 0x4EB1B800), encAddvS4S(0, 0));
}

test "encSshrV16B: sshr v0.16b, v1.16b, #7 → 0x4F090420" {
    try testing.expectEqual(@as(u32, 0x4F090420), encSshrV16B(0, 1, 7));
}
test "encSshrV8H: sshr v0.8h, v1.8h, #15 → 0x4F110420" {
    try testing.expectEqual(@as(u32, 0x4F110420), encSshrV8H(0, 1, 15));
}
test "encSshrV4S: sshr v0.4s, v1.4s, #31 → 0x4F210420" {
    try testing.expectEqual(@as(u32, 0x4F210420), encSshrV4S(0, 1, 31));
}

test "encZip1V16B: zip1 v0.16b, v1.16b, v2.16b → 0x4E023820" {
    try testing.expectEqual(@as(u32, 0x4E023820), encZip1V16B(0, 1, 2));
}

test "encExtV16B: ext v0.16b, v1.16b, v2.16b, #8 → 0x6E024020" {
    try testing.expectEqual(@as(u32, 0x6E024020), encExtV16B(0, 1, 2, 8));
}
// ============================================================
// ADD/SUB across i8x16/i16x8/i64x2 (i32x4
// already in foundation tests). Tests verify size-field bit
// patterns + cross-shape distinctness sanity.
// ============================================================

test "encAdd16B: V0, V1, V2 (i8x16, size=00)" {
    // 0x4E208400 | (2 << 16) | (1 << 5) | 0 = 0x4E228420
    try testing.expectEqual(@as(u32, 0x4E228420), encAdd16B(0, 1, 2));
}

test "encAdd8H: V0, V1, V2 (i16x8, size=01)" {
    // 0x4E608400 | (2 << 16) | (1 << 5) | 0 = 0x4E628420
    try testing.expectEqual(@as(u32, 0x4E628420), encAdd8H(0, 1, 2));
}

test "encAdd2D: V0, V1, V2 (i64x2, size=11)" {
    // 0x4EE08400 | (2 << 16) | (1 << 5) | 0 = 0x4EE28420
    try testing.expectEqual(@as(u32, 0x4EE28420), encAdd2D(0, 1, 2));
}

test "encSub16B: V0, V1, V2 (i8x16, size=00, U=1)" {
    // 0x6E208400 | (2 << 16) | (1 << 5) | 0 = 0x6E228420
    try testing.expectEqual(@as(u32, 0x6E228420), encSub16B(0, 1, 2));
}

test "encSub8H: V0, V1, V2 (i16x8, size=01, U=1)" {
    // 0x6E608400 | ... = 0x6E628420
    try testing.expectEqual(@as(u32, 0x6E628420), encSub8H(0, 1, 2));
}

test "encSub4S: V0, V1, V2 (i32x4, size=10, U=1)" {
    // 0x6EA08400 | ... = 0x6EA28420
    try testing.expectEqual(@as(u32, 0x6EA28420), encSub4S(0, 1, 2));
}

test "encSub2D: V0, V1, V2 (i64x2, size=11, U=1)" {
    // 0x6EE08400 | ... = 0x6EE28420
    try testing.expectEqual(@as(u32, 0x6EE28420), encSub2D(0, 1, 2));
}

test "encSub vs encAdd: U bit set distinguishes; same shape size field" {
    // ADD/SUB at same shape (4S) differ only in bit[29] (U bit).
    const add_word = encAdd4S(0, 1, 2);
    const sub_word = encSub4S(0, 1, 2);
    try testing.expectEqual(@as(u32, 0x20000000), sub_word ^ add_word);
}

test "encAdd shapes pairwise distinct (size field separates)" {
    // 16B vs 8H vs 4S vs 2D — same operands, different bits[23:22].
    try testing.expect(encAdd16B(0, 1, 2) != encAdd8H(0, 1, 2));
    try testing.expect(encAdd8H(0, 1, 2) != encAdd4S(0, 1, 2));
    try testing.expect(encAdd4S(0, 1, 2) != encAdd2D(0, 1, 2));
}

// ============================================================
// MUL family (16B/8H/4S; 2D needs synthesis)
// ============================================================

test "encMul16B: V0, V1, V2 (i8x16.mul shape)" {
    // 0x4E209C00 | (2 << 16) | (1 << 5) | 0 = 0x4E229C20
    try testing.expectEqual(@as(u32, 0x4E229C20), encMul16B(0, 1, 2));
}

test "encMul8H: V0, V1, V2 (i16x8.mul)" {
    // 0x4E609C00 | ... = 0x4E629C20
    try testing.expectEqual(@as(u32, 0x4E629C20), encMul8H(0, 1, 2));
}

test "encMul4S: V0, V1, V2 (i32x4.mul)" {
    // 0x4EA09C00 | ... = 0x4EA29C20
    try testing.expectEqual(@as(u32, 0x4EA29C20), encMul4S(0, 1, 2));
}

test "encMul vs encAdd: bits[15:11] differ by 0b00011 << 11 = 0x1800" {
    // MUL bits[15:11] = 10011, ADD = 10000 → delta 0x1800.
    const add_word = encAdd4S(0, 1, 2);
    const mul_word = encMul4S(0, 1, 2);
    try testing.expectEqual(@as(u32, 0x1800), mul_word ^ add_word);
}
// ============================================================
// FP three-same arithmetic (FADD/FSUB/FMUL/FDIV)
// ============================================================

test "encFAdd4S: V0, V1, V2 (f32x4.add base)" {
    // 0x4E20D400 | (2 << 16) | (1 << 5) | 0 = 0x4E22D420
    try testing.expectEqual(@as(u32, 0x4E22D420), encFAdd4S(0, 1, 2));
}

test "encFAdd2D: V0, V1, V2 (f64x2.add)" {
    // 0x4E60D400 | (2 << 16) | (1 << 5) | 0 = 0x4E62D420
    try testing.expectEqual(@as(u32, 0x4E62D420), encFAdd2D(0, 1, 2));
}

test "encFSub4S vs encFAdd4S: bit 23 differs (op = add vs sub)" {
    // 0x4EA0D400 vs 0x4E20D400 → XOR = 0x00800000
    try testing.expectEqual(@as(u32, 0x00800000), encFSub4S(0, 1, 2) ^ encFAdd4S(0, 1, 2));
}

test "encFSub2D: V31, V31, V31 (max indices, f64x2.sub)" {
    // 0x4EE0D400 | (31 << 16) | (31 << 5) | 31 = 0x4EFFD7FF
    try testing.expectEqual(@as(u32, 0x4EFFD7FF), encFSub2D(31, 31, 31));
}

test "encFMul4S: V0, V1, V2 (f32x4.mul, U=1, opcode bit 11 set vs FADD/FSUB)" {
    // 0x6E20DC00 | ... = 0x6E22DC20
    try testing.expectEqual(@as(u32, 0x6E22DC20), encFMul4S(0, 1, 2));
}

test "encFMul2D: V0, V1, V2 (f64x2.mul)" {
    // 0x6E60DC00 | ... = 0x6E62DC20
    try testing.expectEqual(@as(u32, 0x6E62DC20), encFMul2D(0, 1, 2));
}

test "encFDiv4S: V0, V1, V2 (f32x4.div, opcode 11111)" {
    // 0x6E20FC00 | ... = 0x6E22FC20
    try testing.expectEqual(@as(u32, 0x6E22FC20), encFDiv4S(0, 1, 2));
}

test "encFDiv2D vs encFMul2D: opcode bit 13 differs" {
    // FDIV opcode 11111, FMUL 11011 → bit 13 differs → +0x2000.
    try testing.expectEqual(@as(u32, 0x2000), encFDiv2D(0, 1, 2) ^ encFMul2D(0, 1, 2));
}

test "FP arith: sz field selects 4S vs 2D (bit 22)" {
    // .4S has sz=0, .2D has sz=1 → bit 22 differs → +0x00400000.
    try testing.expectEqual(@as(u32, 0x00400000), encFAdd2D(0, 1, 2) ^ encFAdd4S(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x00400000), encFMul2D(0, 1, 2) ^ encFMul4S(0, 1, 2));
}

// ============================================================
// FP unary (FABS/FNEG/FSQRT/FRINT*)
// ============================================================

test "encFAbs4S: V0, V1 (f32x4.abs base)" {
    // 0x4EA0F800 | (1 << 5) | 0 = 0x4EA0F820
    try testing.expectEqual(@as(u32, 0x4EA0F820), encFAbs4S(0, 1));
}

test "encFAbs2D: V31, V31 (f64x2.abs max indices)" {
    // 0x4EE0F800 | (31 << 5) | 31 = 0x4EE0FBFF
    try testing.expectEqual(@as(u32, 0x4EE0FBFF), encFAbs2D(31, 31));
}

test "encFNeg vs encFAbs: U bit (bit 29) differs" {
    // FNEG U=1, FABS U=0 → XOR = 0x20000000.
    try testing.expectEqual(@as(u32, 0x20000000), encFNeg4S(0, 1) ^ encFAbs4S(0, 1));
}

test "encFSqrt vs encFNeg: opcode bit 16 differs (01111 vs 11111)" {
    // FSQRT opcode = 11111, FNEG opcode = 01111 → bit 16 differs → 0x10000.
    try testing.expectEqual(@as(u32, 0x10000), encFSqrt4S(0, 1) ^ encFNeg4S(0, 1));
}

test "encFSqrt2D: V0, V1 (f64x2.sqrt)" {
    // 0x6EE1F800 | (1 << 5) | 0 = 0x6EE1F820
    try testing.expectEqual(@as(u32, 0x6EE1F820), encFSqrt2D(0, 1));
}

test "encFRintN4S: V0, V1 (f32x4.nearest)" {
    // 0x4E218800 | (1 << 5) | 0 = 0x4E218820
    try testing.expectEqual(@as(u32, 0x4E218820), encFRintN4S(0, 1));
}

test "encFRintM vs encFRintN: opcode bit 12 differs (11001 vs 11000)" {
    // FRINTM opcode = 11001, FRINTN opcode = 11000 → bit 12 differs → 0x1000.
    try testing.expectEqual(@as(u32, 0x1000), encFRintM4S(0, 1) ^ encFRintN4S(0, 1));
}

test "encFRintP vs encFRintN: bit 23 ('a') differs (1 vs 0)" {
    // FRINTP a=1, FRINTN a=0 → bit 23 differs → 0x800000.
    try testing.expectEqual(@as(u32, 0x800000), encFRintP4S(0, 1) ^ encFRintN4S(0, 1));
}

test "encFRintZ2D: V0, V1 (f64x2.trunc)" {
    // 0x4EE19800 | (1 << 5) | 0 = 0x4EE19820
    try testing.expectEqual(@as(u32, 0x4EE19820), encFRintZ2D(0, 1));
}

test "FP unary 7 ops × 2 shapes: all distinct at identical operands" {
    const v0_v0_words = [_]u32{
        encFAbs4S(0, 0),   encFAbs2D(0, 0),
        encFNeg4S(0, 0),   encFNeg2D(0, 0),
        encFSqrt4S(0, 0),  encFSqrt2D(0, 0),
        encFRintN4S(0, 0), encFRintN2D(0, 0),
        encFRintM4S(0, 0), encFRintM2D(0, 0),
        encFRintP4S(0, 0), encFRintP2D(0, 0),
        encFRintZ4S(0, 0), encFRintZ2D(0, 0),
    };
    // Pairwise distinct.
    for (v0_v0_words, 0..) |a, i| {
        for (v0_v0_words[i + 1 ..]) |b| try testing.expect(a != b);
    }
}

// ============================================================
// FMAX / FMIN (vector, NaN-propagating)
// ============================================================

test "encFMax4S: V0, V1, V2 (f32x4.max base)" {
    // 0x4E20F400 | (2 << 16) | (1 << 5) | 0 = 0x4E22F420
    try testing.expectEqual(@as(u32, 0x4E22F420), encFMax4S(0, 1, 2));
}

test "encFMax2D: V31, V31, V31 (max indices)" {
    // 0x4E60F400 | (31 << 16) | (31 << 5) | 31 = 0x4E7FF7FF
    try testing.expectEqual(@as(u32, 0x4E7FF7FF), encFMax2D(31, 31, 31));
}

test "encFMin vs encFMax: bit 23 differs" {
    // FMIN bit 23 = 1, FMAX bit 23 = 0 → XOR = 0x800000.
    try testing.expectEqual(@as(u32, 0x800000), encFMin4S(0, 1, 2) ^ encFMax4S(0, 1, 2));
}

test "encFMin2D vs encFMin4S: sz field differs (bit 22)" {
    try testing.expectEqual(@as(u32, 0x400000), encFMin2D(0, 1, 2) ^ encFMin4S(0, 1, 2));
}
// ============================================================
// TBL 1-register (i8x16.swizzle)
// ============================================================

test "encTbl1Reg: V0, V1, V2 (tbl v0.16b, {v1.16b}, v2.16b)" {
    // 0x4E000000 | (2 << 16) | (1 << 5) | 0 = 0x4E020020
    try testing.expectEqual(@as(u32, 0x4E020020), encTbl1Reg(0, 1, 2));
}

test "encTbl1Reg: V31, V31, V31 (max indices)" {
    // 0x4E000000 | (31 << 16) | (31 << 5) | 31 = 0x4E1F03FF
    try testing.expectEqual(@as(u32, 0x4E1F03FF), encTbl1Reg(31, 31, 31));
}

test "encTbl2Reg: V0, V30, V2 (TBL with V30:V31 pair)" {
    // 0x4E002000 | (2 << 16) | (30 << 5) | 0 = 0x4E0223C0
    try testing.expectEqual(@as(u32, 0x4E0223C0), encTbl2Reg(0, 30, 2));
}

test "encTbl1Reg vs encTbl2Reg: len field (bits 14:13) differs" {
    // len=00 (1-reg) vs len=01 (2-reg) → bit 13 differs → 0x2000.
    try testing.expectEqual(@as(u32, 0x2000), encTbl2Reg(0, 0, 0) ^ encTbl1Reg(0, 0, 0));
}

// ============================================================
// SXTL/UXTL extend-low/high
// ============================================================
// Cranelift cross-references (wasmtime/cranelift/codegen/src/isa/
// aarch64/inst/emit_tests.rs:2826-2890):
//   sxtl  v4.8h,  v27.8b  → 0x0F08A764
//   sxtl2 v17.4s, v19.8h  → 0x4F10A671
//   sxtl  v30.2d, v6.2s   → 0x0F20A4DE
//   uxtl2 v3.8h,  v29.16b → 0x6F08A7A3
//   uxtl  v15.4s, v12.4h  → 0x2F10A58F
//   uxtl2 v28.2d, v2.4s   → 0x6F20A45C

test "encSxtl8H: v4.8h, v27.8b (cranelift cross-check)" {
    // 0x0F08A400 | (27 << 5) | 4 = 0x0F08A764
    try testing.expectEqual(@as(u32, 0x0F08A764), encSxtl8H(4, 27));
}

test "encSxtl2_4S: v17.4s, v19.8h (cranelift cross-check)" {
    // 0x4F10A400 | (19 << 5) | 17 = 0x4F10A671
    try testing.expectEqual(@as(u32, 0x4F10A671), encSxtl2_4S(17, 19));
}

test "encSxtl2D: v30.2d, v6.2s (cranelift cross-check)" {
    // 0x0F20A400 | (6 << 5) | 30 = 0x0F20A4DE
    try testing.expectEqual(@as(u32, 0x0F20A4DE), encSxtl2D(30, 6));
}

test "encUxtl2_8H: v3.8h, v29.16b (cranelift cross-check)" {
    // 0x6F08A400 | (29 << 5) | 3 = 0x6F08A7A3
    try testing.expectEqual(@as(u32, 0x6F08A7A3), encUxtl2_8H(3, 29));
}

test "encUxtl4S: v15.4s, v12.4h (cranelift cross-check)" {
    // 0x2F10A400 | (12 << 5) | 15 = 0x2F10A58F
    try testing.expectEqual(@as(u32, 0x2F10A58F), encUxtl4S(15, 12));
}

test "encUxtl2_2D: v28.2d, v2.4s (cranelift cross-check)" {
    // 0x6F20A400 | (2 << 5) | 28 = 0x6F20A45C
    try testing.expectEqual(@as(u32, 0x6F20A45C), encUxtl2_2D(28, 2));
}

test "Sxtl vs Uxtl: U bit differs (bit 29)" {
    try testing.expectEqual(@as(u32, 0x20000000), encUxtl8H(0, 0) ^ encSxtl8H(0, 0));
}

test "Sxtl vs Sxtl2: Q bit differs (bit 30)" {
    try testing.expectEqual(@as(u32, 0x40000000), encSxtl2_8H(0, 0) ^ encSxtl8H(0, 0));
}

test "Sxtl shapes pairwise distinct (immh field)" {
    try testing.expect(encSxtl8H(0, 0) != encSxtl4S(0, 0));
    try testing.expect(encSxtl4S(0, 0) != encSxtl2D(0, 0));
    try testing.expect(encSxtl8H(0, 0) != encSxtl2D(0, 0));
}
// ============================================================
// SQXTN/SQXTUN saturating narrow
// ============================================================
// Cranelift cross-references (wasmtime/cranelift/codegen/src/isa/
// aarch64/inst/emit_tests.rs:3016-3128):
//   sqxtn2 v7.16b,  v22.8h  → 0x4E214AC7
//   uqxtn  v31.4h,  v31.4s  → 0x2E614BFF (UQXTN; we use SQXTUN
//   for Wasm narrow_*_u — encoding pattern shape verified)

test "encSqxtn2_16B: v7.16b, v22.8h (cranelift cross-check)" {
    // 0x4E214800 | (22 << 5) | 7 = 0x4E214AC7
    try testing.expectEqual(@as(u32, 0x4E214AC7), encSqxtn2_16B(7, 22));
}

test "encSqxtn8B: v0.8b, v0.8h (low-form base)" {
    // 0x0E214800 | 0 | 0 = 0x0E214800
    try testing.expectEqual(@as(u32, 0x0E214800), encSqxtn8B(0, 0));
}

test "encSqxtn4H: v0.4h, v0.4s (size=01)" {
    // 0x0E614800 | 0 | 0 = 0x0E614800
    try testing.expectEqual(@as(u32, 0x0E614800), encSqxtn4H(0, 0));
}

test "encSqxtn vs encSqxtn2: Q bit (bit 30) differs" {
    try testing.expectEqual(@as(u32, 0x40000000), encSqxtn2_16B(0, 0) ^ encSqxtn8B(0, 0));
    try testing.expectEqual(@as(u32, 0x40000000), encSqxtn2_8H(0, 0) ^ encSqxtn4H(0, 0));
}

test "encSqxtun vs encSqxtn: U bit + opcode bit 14 differ (10010 vs 10100)" {
    // SQXTUN: U=1, opcode=10010. SQXTN: U=0, opcode=10100.
    // Bit-level diff: bit 29 (U) + bits 14, 13 (opcode 10010 ^ 10100 = 00110)
    //   = 0x20000000 + 0x4000 + 0x2000 = 0x20006000
    // Wait, opcode bits are at 16:12. 10010 = 18; 10100 = 20. XOR = 6 = 0b00110 = bit 13 + bit 14 set.
    // 13<<12 = 0x2000, 14<<12 = 0x4000. So opcode XOR contributes 0x6000.
    try testing.expectEqual(@as(u32, 0x20006000), encSqxtun8B(0, 0) ^ encSqxtn8B(0, 0));
}

test "encSqxtun4H: v0.4h, v0.4s (signed→unsigned narrow base)" {
    // 0x2E612800 | 0 | 0 = 0x2E612800
    try testing.expectEqual(@as(u32, 0x2E612800), encSqxtun4H(0, 0));
}

test "encSqxtun2_8H: v31.8h, v31.4s (max indices)" {
    // 0x6E612800 | (31 << 5) | 31 = 0x6E612BFF
    try testing.expectEqual(@as(u32, 0x6E612BFF), encSqxtun2_8H(31, 31));
}
// ============================================================
// SCVTF/UCVTF (vector, i→f)
// ============================================================
// Cranelift cross-references (wasmtime/cranelift/codegen/src/isa/
// aarch64/inst/emit_tests.rs:5034-5046):
//   scvtf v20.4s, v8.4s   → 0x4E21D914
//   ucvtf v10.2d, v19.2d  → 0x6E61DA6A

test "encScvtf4S: v20.4s, v8.4s (cranelift cross-check)" {
    // 0x4E21D800 | (8 << 5) | 20 = 0x4E21D914
    try testing.expectEqual(@as(u32, 0x4E21D914), encScvtf4S(20, 8));
}

test "encUcvtf2D: v10.2d, v19.2d (cranelift cross-check)" {
    // 0x6E61D800 | (19 << 5) | 10 = 0x6E61DA6A
    try testing.expectEqual(@as(u32, 0x6E61DA6A), encUcvtf2D(10, 19));
}

test "encScvtf2D: v0.2d, v0.2d (base)" {
    try testing.expectEqual(@as(u32, 0x4E61D800), encScvtf2D(0, 0));
}

test "encUcvtf4S: v0.4s, v0.4s (base)" {
    try testing.expectEqual(@as(u32, 0x6E21D800), encUcvtf4S(0, 0));
}

test "Ucvtf vs Scvtf: U bit (bit 29) differs" {
    try testing.expectEqual(@as(u32, 0x20000000), encUcvtf4S(0, 0) ^ encScvtf4S(0, 0));
    try testing.expectEqual(@as(u32, 0x20000000), encUcvtf2D(0, 0) ^ encScvtf2D(0, 0));
}

test "FP convert sz field: .2D vs .4S differs at bit 22" {
    try testing.expectEqual(@as(u32, 0x00400000), encScvtf2D(0, 0) ^ encScvtf4S(0, 0));
}
// ============================================================
// FCVTL / FCVTN (FP narrow / widen)
// ============================================================

test "encFCvtn_2S_2D: v2.2s, v7.2d (cranelift cross-check)" {
    // 0x0E616800 | (7 << 5) | 2 = 0x0E6168E2
    try testing.expectEqual(@as(u32, 0x0E6168E2), encFCvtn_2S_2D(2, 7));
}

test "encFCvtl_2D_2S: v16.2d, v1.2s (cranelift cross-check, low form of FCVTL2 v16,v1 high)" {
    // High-form (FCVTL2) v16,v1 was 0x4E617830 in cranelift.
    // Low form is bit 30 cleared: 0x0E617830.
    // 0x0E617800 | (1 << 5) | 16 = 0x0E617830
    try testing.expectEqual(@as(u32, 0x0E617830), encFCvtl_2D_2S(16, 1));
}

test "encFCvtn_2S_2D base: v0.2s, v0.2d" {
    try testing.expectEqual(@as(u32, 0x0E616800), encFCvtn_2S_2D(0, 0));
}

test "encFCvtl_2D_2S base: v0.2d, v0.2s" {
    try testing.expectEqual(@as(u32, 0x0E617800), encFCvtl_2D_2S(0, 0));
}

test "FCVTL vs FCVTN: opcode bit 12 differs (10111 vs 10110)" {
    try testing.expectEqual(@as(u32, 0x1000), encFCvtl_2D_2S(0, 0) ^ encFCvtn_2S_2D(0, 0));
}
// ============================================================
// FCVTZS/FCVTZU + SQXTN/UQXTN .2S
// ============================================================
// Cranelift cross-references (wasmtime/cranelift/codegen/src/isa/
// aarch64/inst/emit_tests.rs:4985-5025):
//   fcvtzs v4.4s, v22.4s  → 0x4EA1BAC4
//   fcvtzs v0.2d, v31.2d  → 0x4EE1BBE0
//   fcvtzu v29.2d, v15.2d → 0x6EE1B9FD
//   sqxtn  v14.2s, v20.2d → 0x0EA14A8E (already cross-checked
//                          via a different operand)

test "encFcvtzs4S: v4.4s, v22.4s (cranelift cross-check)" {
    // 0x4EA1B800 | (22 << 5) | 4 = 0x4EA1BAC4
    try testing.expectEqual(@as(u32, 0x4EA1BAC4), encFcvtzs4S(4, 22));
}

test "encFcvtzs2D: v0.2d, v31.2d (cranelift cross-check)" {
    // 0x4EE1B800 | (31 << 5) | 0 = 0x4EE1BBE0
    try testing.expectEqual(@as(u32, 0x4EE1BBE0), encFcvtzs2D(0, 31));
}

test "encFcvtzu2D: v29.2d, v15.2d (cranelift cross-check)" {
    // 0x6EE1B800 | (15 << 5) | 29 = 0x6EE1B9FD
    try testing.expectEqual(@as(u32, 0x6EE1B9FD), encFcvtzu2D(29, 15));
}

test "encFcvtzu4S: base" {
    try testing.expectEqual(@as(u32, 0x6EA1B800), encFcvtzu4S(0, 0));
}

test "Fcvtzs vs Fcvtzu: U bit differs" {
    try testing.expectEqual(@as(u32, 0x20000000), encFcvtzu4S(0, 0) ^ encFcvtzs4S(0, 0));
}

test "encSqxtn2S: v14.2s, v20.2d (cranelift cross-check)" {
    // 0x0EA14800 | (20 << 5) | 14 = 0x0EA14A8E
    try testing.expectEqual(@as(u32, 0x0EA14A8E), encSqxtn2S(14, 20));
}

test "encUqxtn2S: v0.2s, v0.2d (base)" {
    try testing.expectEqual(@as(u32, 0x2EA14800), encUqxtn2S(0, 0));
}

test "Sqxtn2S vs Uqxtn2S: U bit differs" {
    try testing.expectEqual(@as(u32, 0x20000000), encUqxtn2S(0, 0) ^ encSqxtn2S(0, 0));
}

test "encSmin/Umin/Smax/Umax/Urhadd: clang-verified bases for V0, V1, V2" {
    // SMIN
    try testing.expectEqual(@as(u32, 0x4E226C20), encSmin16B(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x4E626C20), encSmin8H(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x4EA26C20), encSmin4S(0, 1, 2));
    // UMIN
    try testing.expectEqual(@as(u32, 0x6E226C20), encUmin16B(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x6E626C20), encUmin8H(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x6EA26C20), encUmin4S(0, 1, 2));
    // SMAX
    try testing.expectEqual(@as(u32, 0x4E226420), encSmax16B(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x4E626420), encSmax8H(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x4EA26420), encSmax4S(0, 1, 2));
    // UMAX
    try testing.expectEqual(@as(u32, 0x6E226420), encUmax16B(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x6E626420), encUmax8H(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x6EA26420), encUmax4S(0, 1, 2));
    // URHADD (Wasm has only B + H avgr_u; no .4S)
    try testing.expectEqual(@as(u32, 0x6E221420), encUrhadd16B(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x6E621420), encUrhadd8H(0, 1, 2));
}
