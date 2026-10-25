//! arm64 FP encoder catalog — extracted from `inst.zig` per ADR-0084.
//!
//! FP encoder functions covering int↔FP conversions, FP binary
//! ALU, FP unary + rounding, FP register move + conditional
//! select. Pure bit-pattern encoders, no state, no allocator.
//! Tested per Arm IHI 0055 + llvm-mc -triple=aarch64 cross-check
//! (test blocks below match the same shape as their source-file
//! counterparts).
//!
//! Callers cluster in op_alu_float.zig + op_convert.zig +
//! bounds_check.zig (v128 zero-comparison) + emit_test_alu_float.zig;
//! shared Xn/Vn/Cond types imported from inst.zig.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");
const testing = std.testing;

const inst = @import("inst.zig");
const Xn = inst.Xn;
const Vn = inst.Vn;

/// `SCVTF Sd, Wn` — single-prec from signed 32-bit int.
/// Encoding base 0x1E220000.
pub fn encScvtfSFromW(vd: Vn, wn: Xn) u32 {
    return 0x1E220000 | (@as(u32, wn) << 5) | @as(u32, vd);
}

/// `SCVTF Sd, Xn` — single-prec from signed 64-bit int.
/// Encoding base 0x9E220000.
pub fn encScvtfSFromX(vd: Vn, xn: Xn) u32 {
    return 0x9E220000 | (@as(u32, xn) << 5) | @as(u32, vd);
}

/// `UCVTF Sd, Wn` — single-prec from unsigned 32-bit int.
/// Encoding base 0x1E230000.
pub fn encUcvtfSFromW(vd: Vn, wn: Xn) u32 {
    return 0x1E230000 | (@as(u32, wn) << 5) | @as(u32, vd);
}

/// `UCVTF Sd, Xn` — single-prec from unsigned 64-bit int.
/// Encoding base 0x9E230000.
pub fn encUcvtfSFromX(vd: Vn, xn: Xn) u32 {
    return 0x9E230000 | (@as(u32, xn) << 5) | @as(u32, vd);
}

/// `SCVTF Dd, Wn` — double-prec from signed 32-bit int.
/// Encoding base 0x1E620000.
pub fn encScvtfDFromW(vd: Vn, wn: Xn) u32 {
    return 0x1E620000 | (@as(u32, wn) << 5) | @as(u32, vd);
}

/// `SCVTF Dd, Xn` — double-prec from signed 64-bit int.
/// Encoding base 0x9E620000.
pub fn encScvtfDFromX(vd: Vn, xn: Xn) u32 {
    return 0x9E620000 | (@as(u32, xn) << 5) | @as(u32, vd);
}

/// `UCVTF Dd, Wn` — double-prec from unsigned 32-bit int.
/// Encoding base 0x1E630000.
pub fn encUcvtfDFromW(vd: Vn, wn: Xn) u32 {
    return 0x1E630000 | (@as(u32, wn) << 5) | @as(u32, vd);
}

/// `UCVTF Dd, Xn` — double-prec from unsigned 64-bit int.
/// Encoding base 0x9E630000.
pub fn encUcvtfDFromX(vd: Vn, xn: Xn) u32 {
    return 0x9E630000 | (@as(u32, xn) << 5) | @as(u32, vd);
}

/// `FCVT Sd, Dn` — float demote (double → single).
/// Encoding base 0x1E624000.
pub fn encFcvtSFromD(vd: Vn, vn: Vn) u32 {
    return 0x1E624000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// `FCVT Dd, Sn` — float promote (single → double).
/// Encoding base 0x1E22C000.
pub fn encFcvtDFromS(vd: Vn, vn: Vn) u32 {
    return 0x1E22C000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// `FCVTZS Wd, Sn` — saturating signed trunc (f32 → i32).
/// Encoding base 0x1E380000.
pub fn encFcvtzsWFromS(wd: Xn, vn: Vn) u32 {
    return 0x1E380000 | (@as(u32, vn) << 5) | @as(u32, wd);
}

/// `FCVTZS Wd, Dn` — saturating signed trunc (f64 → i32).
/// Encoding base 0x1E780000.
pub fn encFcvtzsWFromD(wd: Xn, vn: Vn) u32 {
    return 0x1E780000 | (@as(u32, vn) << 5) | @as(u32, wd);
}

/// `FCVTZU Wd, Sn` — saturating unsigned trunc (f32 → u32).
/// Encoding base 0x1E390000.
pub fn encFcvtzuWFromS(wd: Xn, vn: Vn) u32 {
    return 0x1E390000 | (@as(u32, vn) << 5) | @as(u32, wd);
}

/// `FCVTZU Wd, Dn` — saturating unsigned trunc (f64 → u32).
/// Encoding base 0x1E790000.
pub fn encFcvtzuWFromD(wd: Xn, vn: Vn) u32 {
    return 0x1E790000 | (@as(u32, vn) << 5) | @as(u32, wd);
}

/// `FCVTZS Xd, Sn` — saturating signed trunc (f32 → i64).
/// Encoding base 0x9E380000.
pub fn encFcvtzsXFromS(xd: Xn, vn: Vn) u32 {
    return 0x9E380000 | (@as(u32, vn) << 5) | @as(u32, xd);
}

/// `FCVTZS Xd, Dn` — saturating signed trunc (f64 → i64).
/// Encoding base 0x9E780000.
pub fn encFcvtzsXFromD(xd: Xn, vn: Vn) u32 {
    return 0x9E780000 | (@as(u32, vn) << 5) | @as(u32, xd);
}

/// `FCVTZU Xd, Sn` — saturating unsigned trunc (f32 → u64).
/// Encoding base 0x9E390000.
pub fn encFcvtzuXFromS(xd: Xn, vn: Vn) u32 {
    return 0x9E390000 | (@as(u32, vn) << 5) | @as(u32, xd);
}

/// `FCVTZU Xd, Dn` — saturating unsigned trunc (f64 → u64).
/// Encoding base 0x9E790000.
pub fn encFcvtzuXFromD(xd: Xn, vn: Vn) u32 {
    return 0x9E790000 | (@as(u32, vn) << 5) | @as(u32, xd);
}

/// `FMOV S<d>, S<n>` — single-precision register copy.
/// Used by sub-g3a's f32 result-capture path: the AAPCS64 ABI
/// places f32 returns in S0; this moves them into the result
/// vreg's V-register.
/// Encoding base 0x1E204000.
pub fn encFmovSReg(vd: Vn, vn: Vn) u32 {
    return 0x1E204000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// `FMOV D<d>, D<n>` — double-precision register copy. f64
/// counterpart of `encFmovSReg`. Encoding base 0x1E604000.
pub fn encFmovDReg(vd: Vn, vn: Vn) u32 {
    return 0x1E604000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// `FMOV Dd, Xn` — move 64-bit GPR to lower 64 of V-register
/// (D-form). Used by i64.popcnt to stage the value into the
/// SIMD unit. Encoding (FMOV general, sf=1, type=01 double,
/// opcode=111):
///   `1 0 0 11110 01 1 00 111 000000 [Rn:5] [Rd:5]` = `0x9E670000`.
/// Verified via `clang -target arm64-apple-darwin` assembler.
pub fn encFmovDtoFromX(vd: Vn, xn: Xn) u32 {
    return 0x9E670000 | (@as(u32, xn) << 5) | @as(u32, vd);
}

pub fn encFAddS(vd: Vn, vn: Vn, vm: Vn) u32 {
    return 0x1E202800 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFSubS(vd: Vn, vn: Vn, vm: Vn) u32 {
    return 0x1E203800 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFMulS(vd: Vn, vn: Vn, vm: Vn) u32 {
    return 0x1E200800 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFDivS(vd: Vn, vn: Vn, vm: Vn) u32 {
    return 0x1E201800 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFAddD(vd: Vn, vn: Vn, vm: Vn) u32 {
    return 0x1E602800 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFSubD(vd: Vn, vn: Vn, vm: Vn) u32 {
    return 0x1E603800 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFMulD(vd: Vn, vn: Vn, vm: Vn) u32 {
    return 0x1E600800 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFDivD(vd: Vn, vn: Vn, vm: Vn) u32 {
    return 0x1E601800 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// `FCMP Sn, Sm` — sets NZCV from FP compare (single).
/// Encoding (FP compare): `0 0 0 11110 00 1 [Rm:5] 0010 00 [Rn:5] 00000`
/// = `0x1E202000` | (Rm<<16) | (Rn<<5).
pub fn encFCmpS(vn: Vn, vm: Vn) u32 {
    return 0x1E202000 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5);
}

/// `FCMP Dn, Dm` — same as encFCmpS but D-form (type=01).
pub fn encFCmpD(vn: Vn, vm: Vn) u32 {
    return 0x1E602000 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5);
}

pub fn encFAbsS(vd: Vn, vn: Vn) u32 {
    return 0x1E20C000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFNegS(vd: Vn, vn: Vn) u32 {
    return 0x1E214000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFSqrtS(vd: Vn, vn: Vn) u32 {
    return 0x1E21C000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// FRINTP — round toward +∞ (Wasm `f32.ceil` / `f64.ceil`).
pub fn encFRintPS(vd: Vn, vn: Vn) u32 {
    return 0x1E24C000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// FRINTM — round toward -∞ (Wasm `floor`).
pub fn encFRintMS(vd: Vn, vn: Vn) u32 {
    return 0x1E254000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// FRINTZ — round toward zero (Wasm `trunc`).
pub fn encFRintZS(vd: Vn, vn: Vn) u32 {
    return 0x1E25C000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// FRINTN — round to nearest even (Wasm `nearest`).
pub fn encFRintNS(vd: Vn, vn: Vn) u32 {
    return 0x1E244000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFAbsD(vd: Vn, vn: Vn) u32 {
    return 0x1E60C000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFNegD(vd: Vn, vn: Vn) u32 {
    return 0x1E614000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFSqrtD(vd: Vn, vn: Vn) u32 {
    return 0x1E61C000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFRintPD(vd: Vn, vn: Vn) u32 {
    return 0x1E64C000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFRintMD(vd: Vn, vn: Vn) u32 {
    return 0x1E654000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFRintZD(vd: Vn, vn: Vn) u32 {
    return 0x1E65C000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFRintND(vd: Vn, vn: Vn) u32 {
    return 0x1E644000 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// FMIN / FMAX — NaN-propagating per Wasm spec semantics.
pub fn encFMinS(vd: Vn, vn: Vn, vm: Vn) u32 {
    return 0x1E205800 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFMaxS(vd: Vn, vn: Vn, vm: Vn) u32 {
    return 0x1E204800 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFMinD(vd: Vn, vn: Vn, vm: Vn) u32 {
    return 0x1E605800 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | @as(u32, vd);
}

pub fn encFMaxD(vd: Vn, vn: Vn, vm: Vn) u32 {
    return 0x1E604800 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// `FMOV Wd, Sn` — move 32-bit V-register lower 32 → GPR.
/// Counterpart of encFmovStoFromW. Encoding base 0x1E260000.
pub fn encFmovWFromS(wd: Xn, vn: Vn) u32 {
    return 0x1E260000 | (@as(u32, vn) << 5) | @as(u32, wd);
}

/// `FMOV Xd, Dn` — move 64-bit V-register → GPR.
/// Counterpart of encFmovDtoFromX. Encoding base 0x9E660000.
pub fn encFmovXFromD(xd: Xn, vn: Vn) u32 {
    return 0x9E660000 | (@as(u32, vn) << 5) | @as(u32, xd);
}

/// `FMOV S<d>, W<n>` — move 32-bit GPR to lower 32 of V<d>.
/// Encoding (FMOV general, type=00 single, opcode=111, sf=0):
///   `0 0 0 11110 00 1 00 111 000000 [Rn:5] [Rd:5]` = `0x1E270000`.
/// Verified via `clang -target arm64-apple-darwin` assembler.
pub fn encFmovStoFromW(vd: Vn, wn: Xn) u32 {
    return 0x1E270000 | (@as(u32, wn) << 5) | @as(u32, vd);
}

test "encScvtfSFromW s9, w10 → 0x1E220149" {
    try testing.expectEqual(@as(u32, 0x1E220149), encScvtfSFromW(9, 10));
}

test "encScvtfSFromX s9, x10 → 0x9E220149" {
    try testing.expectEqual(@as(u32, 0x9E220149), encScvtfSFromX(9, 10));
}

test "encUcvtfSFromW s9, w10 → 0x1E230149" {
    try testing.expectEqual(@as(u32, 0x1E230149), encUcvtfSFromW(9, 10));
}

test "encUcvtfSFromX s9, x10 → 0x9E230149" {
    try testing.expectEqual(@as(u32, 0x9E230149), encUcvtfSFromX(9, 10));
}

test "encScvtfDFromW d9, w10 → 0x1E620149" {
    try testing.expectEqual(@as(u32, 0x1E620149), encScvtfDFromW(9, 10));
}

test "encScvtfDFromX d9, x10 → 0x9E620149" {
    try testing.expectEqual(@as(u32, 0x9E620149), encScvtfDFromX(9, 10));
}

test "encUcvtfDFromW d9, w10 → 0x1E630149" {
    try testing.expectEqual(@as(u32, 0x1E630149), encUcvtfDFromW(9, 10));
}

test "encUcvtfDFromX d9, x10 → 0x9E630149" {
    try testing.expectEqual(@as(u32, 0x9E630149), encUcvtfDFromX(9, 10));
}

test "encFcvtSFromD s9, d10 → 0x1E624149" {
    try testing.expectEqual(@as(u32, 0x1E624149), encFcvtSFromD(9, 10));
}

test "encFcvtDFromS d9, s10 → 0x1E22C149" {
    try testing.expectEqual(@as(u32, 0x1E22C149), encFcvtDFromS(9, 10));
}

test "encFcvtzsWFromS w9, s10 → 0x1E380149" {
    try testing.expectEqual(@as(u32, 0x1E380149), encFcvtzsWFromS(9, 10));
}

test "encFcvtzsWFromD w9, d10 → 0x1E780149" {
    try testing.expectEqual(@as(u32, 0x1E780149), encFcvtzsWFromD(9, 10));
}

test "encFcvtzuWFromS w9, s10 → 0x1E390149" {
    try testing.expectEqual(@as(u32, 0x1E390149), encFcvtzuWFromS(9, 10));
}

test "encFcvtzuWFromD w9, d10 → 0x1E790149" {
    try testing.expectEqual(@as(u32, 0x1E790149), encFcvtzuWFromD(9, 10));
}

test "encFcvtzsXFromS x9, s10 → 0x9E380149" {
    try testing.expectEqual(@as(u32, 0x9E380149), encFcvtzsXFromS(9, 10));
}

test "encFcvtzsXFromD x9, d10 → 0x9E780149" {
    try testing.expectEqual(@as(u32, 0x9E780149), encFcvtzsXFromD(9, 10));
}

test "encFcvtzuXFromS x9, s10 → 0x9E390149" {
    try testing.expectEqual(@as(u32, 0x9E390149), encFcvtzuXFromS(9, 10));
}

test "encFcvtzuXFromD x9, d10 → 0x9E790149" {
    try testing.expectEqual(@as(u32, 0x9E790149), encFcvtzuXFromD(9, 10));
}

test "encFmovSReg s9, s0 — `fmov s9, s0` → 0x1E204009" {
    try testing.expectEqual(@as(u32, 0x1E204009), encFmovSReg(9, 0));
}

test "encFmovDReg d9, d0 — `fmov d9, d0` → 0x1E604009" {
    try testing.expectEqual(@as(u32, 0x1E604009), encFmovDReg(9, 0));
}

test "encFmovDtoFromX d31, x9 — `fmov d31, x9` → 0x9E67013F" {
    try testing.expectEqual(@as(u32, 0x9E67013F), encFmovDtoFromX(31, 9));
}

test "encFAddS s0, s1, s2 — `fadd s0, s1, s2` → 0x1E222820" {
    try testing.expectEqual(@as(u32, 0x1E222820), encFAddS(0, 1, 2));
}

test "encFSubS s0, s1, s2 — `fsub s0, s1, s2` → 0x1E223820" {
    try testing.expectEqual(@as(u32, 0x1E223820), encFSubS(0, 1, 2));
}

test "encFMulS s0, s1, s2 — `fmul s0, s1, s2` → 0x1E220820" {
    try testing.expectEqual(@as(u32, 0x1E220820), encFMulS(0, 1, 2));
}

test "encFDivS s0, s1, s2 — `fdiv s0, s1, s2` → 0x1E221820" {
    try testing.expectEqual(@as(u32, 0x1E221820), encFDivS(0, 1, 2));
}

test "encFAddD d0, d1, d2 — `fadd d0, d1, d2` → 0x1E622820" {
    try testing.expectEqual(@as(u32, 0x1E622820), encFAddD(0, 1, 2));
}

test "encFSubD d0, d1, d2 — `fsub d0, d1, d2` → 0x1E623820" {
    try testing.expectEqual(@as(u32, 0x1E623820), encFSubD(0, 1, 2));
}

test "encFMulD d0, d1, d2 — `fmul d0, d1, d2` → 0x1E620820" {
    try testing.expectEqual(@as(u32, 0x1E620820), encFMulD(0, 1, 2));
}

test "encFDivD d0, d1, d2 — `fdiv d0, d1, d2` → 0x1E621820" {
    try testing.expectEqual(@as(u32, 0x1E621820), encFDivD(0, 1, 2));
}

test "encFCmpS s1, s2 — `fcmp s1, s2` → 0x1E222020" {
    try testing.expectEqual(@as(u32, 0x1E222020), encFCmpS(1, 2));
}

test "encFCmpD d1, d2 — `fcmp d1, d2` → 0x1E622020" {
    try testing.expectEqual(@as(u32, 0x1E622020), encFCmpD(1, 2));
}

test "encFAbsS s0, s1 → 0x1E20C020" {
    try testing.expectEqual(@as(u32, 0x1E20C020), encFAbsS(0, 1));
}

test "encFNegS s0, s1 → 0x1E214020" {
    try testing.expectEqual(@as(u32, 0x1E214020), encFNegS(0, 1));
}

test "encFSqrtS s0, s1 → 0x1E21C020" {
    try testing.expectEqual(@as(u32, 0x1E21C020), encFSqrtS(0, 1));
}

test "encFRintPS s0, s1 → 0x1E24C020" {
    try testing.expectEqual(@as(u32, 0x1E24C020), encFRintPS(0, 1));
}

test "encFRintMS s0, s1 → 0x1E254020" {
    try testing.expectEqual(@as(u32, 0x1E254020), encFRintMS(0, 1));
}

test "encFRintZS s0, s1 → 0x1E25C020" {
    try testing.expectEqual(@as(u32, 0x1E25C020), encFRintZS(0, 1));
}

test "encFRintNS s0, s1 → 0x1E244020" {
    try testing.expectEqual(@as(u32, 0x1E244020), encFRintNS(0, 1));
}

test "encFAbsD d0, d1 → 0x1E60C020" {
    try testing.expectEqual(@as(u32, 0x1E60C020), encFAbsD(0, 1));
}

test "encFNegD d0, d1 → 0x1E614020" {
    try testing.expectEqual(@as(u32, 0x1E614020), encFNegD(0, 1));
}

test "encFSqrtD d0, d1 → 0x1E61C020" {
    try testing.expectEqual(@as(u32, 0x1E61C020), encFSqrtD(0, 1));
}

test "encFRintPD d0, d1 → 0x1E64C020" {
    try testing.expectEqual(@as(u32, 0x1E64C020), encFRintPD(0, 1));
}

test "encFRintMD d0, d1 → 0x1E654020" {
    try testing.expectEqual(@as(u32, 0x1E654020), encFRintMD(0, 1));
}

test "encFRintZD d0, d1 → 0x1E65C020" {
    try testing.expectEqual(@as(u32, 0x1E65C020), encFRintZD(0, 1));
}

test "encFRintND d0, d1 → 0x1E644020" {
    try testing.expectEqual(@as(u32, 0x1E644020), encFRintND(0, 1));
}

test "encFMinS s0, s1, s2 → 0x1E225820" {
    try testing.expectEqual(@as(u32, 0x1E225820), encFMinS(0, 1, 2));
}

test "encFMaxS s0, s1, s2 → 0x1E224820" {
    try testing.expectEqual(@as(u32, 0x1E224820), encFMaxS(0, 1, 2));
}

test "encFMinD d0, d1, d2 → 0x1E625820" {
    try testing.expectEqual(@as(u32, 0x1E625820), encFMinD(0, 1, 2));
}

test "encFMaxD d0, d1, d2 → 0x1E624820" {
    try testing.expectEqual(@as(u32, 0x1E624820), encFMaxD(0, 1, 2));
}

test "encFmovWFromS w0, s1 → 0x1E260020" {
    try testing.expectEqual(@as(u32, 0x1E260020), encFmovWFromS(0, 1));
}

test "encFmovXFromD x0, d1 → 0x9E660020" {
    try testing.expectEqual(@as(u32, 0x9E660020), encFmovXFromD(0, 1));
}

test "encFmovStoFromW s0, w0 — `fmov s0, w0` → 0x1E270000" {
    try testing.expectEqual(@as(u32, 0x1E270000), encFmovStoFromW(0, 0));
}

test "encFmovStoFromW s31, w9 — `fmov s31, w9` → 0x1E27013F" {
    // Rn=9 (<<5)=0x120; Rd=31; base=0x1E270000.
    try testing.expectEqual(@as(u32, 0x1E27013F), encFmovStoFromW(31, 9));
}
