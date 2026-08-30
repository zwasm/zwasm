// FILE-SIZE-EXEMPT: uniform pure-encoder catalog (AAPCS64 ISA encoders); P2 pure-data dominance (per ADR-0099)
//! ARM64 instruction encoder.
//!
//! Produces fixed-width `u32` encodings for the AArch64 ops the
//! emit pass uses: register-register and register-
//! immediate ALU, MOV-immediate (movz / movk), branches (B / BL
//! / BR / RET), and load / store immediate-offset (LDR / STR).
//!
//! Bit patterns from the Arm Architecture Reference Manual
//! (DDI 0487, A64 base instructions). Each `pub fn enc<X>`
//! returns the little-endian `u32` ready to write to the code
//! buffer; the emit pass packs them into a `[]u8` via
//! `std.mem.writeInt(u32, ..., .little)`.
//!
//! Covers enough opcodes to lower the MVP arithmetic + control
//! flow + memory ops via the greedy-local regalloc. Float /
//! SIMD / exception / atomic encodings live elsewhere.
//!
//! Zone 2 (`src/jit_arm64/`) — must NOT import `src/jit_x86/`
//! per ROADMAP §A3 (Zone-2 inter-arch isolation).

const std = @import("std");

/// X-register index 0..30 (XZR = 31 is the zero register;
/// SP also encodes as 31 with opcode-dependent semantics). The
/// encoder accepts the raw u5 to keep the surface honest about
/// ARM64's 5-bit register field; `abi.zig` maps regalloc slot
/// ids to specific Xn values.
pub const Xn = u5;

/// Zero register — reads as 0; writes are discarded.
pub const xzr: Xn = 31;
/// Stack pointer — encoded as 31; opcode disambiguates from XZR.
pub const sp_reg: Xn = 31;

/// `RET Xn` — return via Xn (X30/LR is the canonical default).
/// Encoding: `1101 0110 0101 1111 0000 00 [Rn:5] 00000`
/// = base `0xD65F0000` | (rn << 5).
pub fn encRet(rn: Xn) u32 {
    return 0xD65F0000 | (@as(u32, rn) << 5);
}

/// `MOVZ Xd, #imm16, lsl #0` — move zero-extended 16-bit imm.
/// Encoding (64-bit MOVZ, hw=0):
/// `1 10 100101 00 [imm16:16] [Rd:5]` = `0xD2800000` | (imm<<5) | rd.
pub fn encMovzImm16(rd: Xn, imm16: u16) u32 {
    return 0xD2800000 | (@as(u32, imm16) << 5) | @as(u32, rd);
}

/// `MOVK Xd, #imm16, lsl #(hw*16)` — keep-other-bits insert.
/// Encoding (64-bit MOVK):
/// `1 11 100101 [hw:2] [imm16:16] [Rd:5]` = `0xF2800000` | (hw<<21)
/// | (imm<<5) | rd.
pub fn encMovkImm16(rd: Xn, imm16: u16, hw: u2) u32 {
    return 0xF2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | @as(u32, rd);
}

/// `ADD Xd, Xn, #imm12` (no shift). 64-bit ADD imm with sh=0:
/// `1 00 10001 0 0 [imm12:12] [Rn:5] [Rd:5]` = `0x91000000` | …
pub fn encAddImm12(rd: Xn, rn: Xn, imm12: u12) u32 {
    return 0x91000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ADDS Xd, Xn, #imm12` (no shift) — 64-bit ADD imm that SETS NZCV.
/// `1 01 10001 0 0 [imm12:12] [Rn:5] [Rd:5]` = `0xB1000000` | …. The
/// carry flag C records unsigned overflow; the memory64 bounds check
/// uses `ADDS ip1, ip0, #size; B.HS trap` so an `ea + size` that wraps
/// past 2^64 (ea near the top of the address space) traps instead of
/// aliasing a small in-bounds address (a `CMP` after a plain `ADD`
/// would miss the wrap).
pub fn encAddsImm12(rd: Xn, rn: Xn, imm12: u12) u32 {
    return 0xB1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ADD Xd, Xn, #imm12, lsl #12` — 64-bit ADD imm with sh=1. The
/// imm12 field shifts left by 12 to span offsets 0..16773120 in
/// 4096-byte steps. Used by `op_memory.zig` to lower the high
/// bits of a large constant offset (Wasm `i32.load offset=N`
/// where N > 0xFFF) without spilling a scratch GPR. The full
/// large-offset sequence is `ADD ip0, ip0, #(N >> 12), lsl #12;
/// ADD ip0, ip0, #(N & 0xFFF)` (skip either when zero).
/// Encoding: `1 00 10001 1 0 [imm12:12] [Rn:5] [Rd:5]` =
/// `0x91400000` | (imm12 << 10) | (Rn << 5) | Rd.
pub fn encAddImm12Lsl12(rd: Xn, rn: Xn, imm12: u12) u32 {
    return 0x91400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB Xd, Xn, #imm12` (no shift). 64-bit SUB imm with sh=0:
/// `1 10 10001 0 0 [imm12:12] [Rn:5] [Rd:5]` = `0xD1000000` | …
pub fn encSubImm12(rd: Xn, rn: Xn, imm12: u12) u32 {
    return 0xD1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB Xd, Xn, #imm12, lsl #12` — 64-bit SUB imm with sh=1.
/// imm12 shifts left by 12, spanning offsets 0..16 MiB-1 in
/// 4096-byte steps. Used by emit.zig prologue to lower
/// `frame_bytes` larger than 4095 via the `SUB SP, SP,
/// #(N>>12), lsl #12; SUB SP, SP, #(N&0xFFF)` sequence.
/// Encoding: `1 10 10001 1 0 [imm12:12] [Rn:5] [Rd:5]` =
/// `0xD1400000` | (imm12 << 10) | (Rn << 5) | Rd.
pub fn encSubImm12Lsl12(rd: Xn, rn: Xn, imm12: u12) u32 {
    return 0xD1400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ADD Xd, Xn, Xm` (no shift). 64-bit ADD shifted-reg, shift=0:
/// `1 00 01011 00 0 [Rm:5] 000000 [Rn:5] [Rd:5]` = `0x8B000000` | …
pub fn encAddReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB Xd, Xn, Xm` (no shift). 64-bit SUB shifted-reg, shift=0:
/// `1 10 01011 00 0 [Rm:5] 000000 [Rn:5] [Rd:5]` = `0xCB000000` | …
pub fn encSubReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0xCB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `LDR Xt, [Xn, #imm]` — load 64-bit at unsigned imm12 offset.
/// `byte_offset` MUST be 8-byte aligned; encoder shifts >>3 to
/// produce the imm12 field. Encoding (LDR 64-bit unsigned offs):
/// `1111 1001 01 [imm12:12] [Rn:5] [Rt:5]` = `0xF9400000` | …
pub fn encLdrImm(rt: Xn, rn: Xn, byte_offset: u15) u32 {
    const imm12: u12 = @intCast(byte_offset >> 3);
    return 0xF9400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `STR Xt, [Xn, #imm]` — store 64-bit at unsigned imm12 offset.
/// Same alignment constraint as `encLdrImm`. Encoding:
/// `1111 1001 00 [imm12:12] [Rn:5] [Rt:5]` = `0xF9000000` | …
pub fn encStrImm(rt: Xn, rn: Xn, byte_offset: u15) u32 {
    const imm12: u12 = @intCast(byte_offset >> 3);
    return 0xF9000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LDR Wt, [Xn, #imm]` — load 32-bit at unsigned imm12 offset
/// scaled by 4. byte_offset MUST be 4-byte aligned and < 16384.
/// Encoding (32-bit LDR unsigned offset):
///   `1011 1001 01 [imm12:12] [Rn:5] [Rt:5]` = `0xB9400000`.
pub fn encLdrImmW(rt: Xn, rn: Xn, byte_offset: u14) u32 {
    const imm12: u12 = @intCast(byte_offset >> 2);
    return 0xB9400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `STR Wt, [Xn, #imm]` — store 32-bit at unsigned imm12 offset
/// scaled by 4. Encoding:
///   `1011 1001 00 [imm12:12] [Rn:5] [Rt:5]` = `0xB9000000`.
pub fn encStrImmW(rt: Xn, rn: Xn, byte_offset: u14) u32 {
    const imm12: u12 = @intCast(byte_offset >> 2);
    return 0xB9000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LDR Wt, [Xn, Xm]` — 32-bit load with X-register offset
/// (no shift, full 64-bit add). Verified via clang assembler.
/// Encoding base 0xB8606800.
pub fn encLdrWReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0xB8606800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `STR Wt, [Xn, Xm]` — 32-bit store with X-register offset.
/// Encoding base 0xB8206800.
pub fn encStrWReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0xB8206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LDR Xt, [Xn, Xm]` — 64-bit load with X-register offset.
/// Encoding base 0xF8606800.
pub fn encLdrXReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0xF8606800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LDR Xt, [Xn, Xm, LSL #3]` — 64-bit load with X-register
/// offset scaled by element size (8 bytes). The S=1 bit is what
/// distinguishes this from the no-shift form. Used by
/// `call_indirect` table-lookup: `LDR X17, [X26, X_idx, LSL #3]`
/// loads `table_base[idx]` (each entry being a u64 funcptr).
pub fn encLdrXRegLsl3(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0xF8607800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LDR Wt, [Xn, Xm, LSL #2]` — 32-bit load with X-register
/// offset scaled by element size (4 bytes). 32-bit counterpart
/// of `encLdrXRegLsl3`. Used by call_indirect sig
/// check: `LDR W16, [X24, X17, LSL #2]` loads
/// `typeidx_array[idx]` (each entry a u32 typeidx).
pub fn encLdrWRegLsl2(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0xB8607800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `STR Xt, [Xn, Xm, LSL #3]` — 64-bit store with X-register
/// offset scaled by element size (8 bytes). Mirror of
/// `encLdrXRegLsl3` for table-style array stores. Used by
/// `table.set`: `STR Xval, [Xrefs, Xidx, LSL #3]`
/// writes `table.refs[idx]`.
pub fn encStrXRegLsl3(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0xF8207800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `STR Wt, [Xn, Xm, LSL #2]` — 32-bit store with X-register
/// offset scaled by element size (4 bytes). 32-bit counterpart
/// of `encStrXRegLsl3`. Used by ADR-0068 typeidx mirror in
/// `emitTableCopy`: `STR Wti, [Xdst_ti, Xidx, LSL #2]`.
pub fn encStrWRegLsl2(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0xB8207800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `SXTW Xd, Wn` — sign-extend 32-bit Wn into 64-bit Xd. Alias
/// for `SBFM Xd, Xn, #0, #31`. Used by `i64.extend_i32_s`.
/// Encoding base 0x93407C00.
pub fn encSxtw(xd: Xn, wn: Xn) u32 {
    return 0x93407C00 | (@as(u32, wn) << 5) | @as(u32, xd);
}

/// `SXTB Wd, Wn` — sign-extend low 8 bits of Wn into Wd
/// (Wasm `i32.extend8_s`). Alias for `SBFM Wd, Wn, #0, #7`
/// (Arm IHI 0055 §C6.2.220, SBFM 32-bit immr=0 imms=7).
/// Encoding base 0x13001C00; sf=0, N=0, immr=0, imms=7.
pub fn encSxtbW(wd: Xn, wn: Xn) u32 {
    return 0x13001C00 | (@as(u32, wn) << 5) | @as(u32, wd);
}

/// `SXTH Wd, Wn` — sign-extend low 16 bits (Wasm `i32.extend16_s`).
/// Alias for `SBFM Wd, Wn, #0, #15`. Encoding base 0x13003C00;
/// sf=0, immr=0, imms=15. Arm IHI 0055 §C6.2.220.
pub fn encSxthW(wd: Xn, wn: Xn) u32 {
    return 0x13003C00 | (@as(u32, wn) << 5) | @as(u32, wd);
}

/// `SXTB Xd, Wn` — sign-extend low 8 bits into 64-bit Xd
/// (Wasm `i64.extend8_s`). Alias for `SBFM Xd, Xn, #0, #7`.
/// Encoding base 0x93401C00; sf=1, N=1, immr=0, imms=7.
pub fn encSxtbX(xd: Xn, xn: Xn) u32 {
    return 0x93401C00 | (@as(u32, xn) << 5) | @as(u32, xd);
}

/// `SXTH Xd, Wn` — sign-extend low 16 bits into 64-bit Xd
/// (Wasm `i64.extend16_s`). Alias for `SBFM Xd, Xn, #0, #15`.
/// Encoding base 0x93403C00; sf=1, N=1, immr=0, imms=15.
pub fn encSxthX(xd: Xn, xn: Xn) u32 {
    return 0x93403C00 | (@as(u32, xn) << 5) | @as(u32, xd);
}

/// `UXTB Wd, Wn` — zero-extend low 8 bits of Wn into Wd
/// (`array.get_u` packed i8). Alias for `UBFM Wd, Wn, #0, #7`
/// (Arm IHI 0055 §C6.2.330, UBFM 32-bit immr=0 imms=7). Same
/// shape as `encSxtbW` but UBFM (opc=10) not SBFM (opc=00):
/// SBFM base 0x13001C00 | (opc bit30) → 0x53001C00.
pub fn encUxtbW(wd: Xn, wn: Xn) u32 {
    return 0x53001C00 | (@as(u32, wn) << 5) | @as(u32, wd);
}

/// `UXTH Wd, Wn` — zero-extend low 16 bits (`array.get_u`
/// packed i16). Alias for `UBFM Wd, Wn, #0, #15`. Encoding base
/// 0x53003C00; immr=0, imms=15.
pub fn encUxthW(wd: Xn, wn: Xn) u32 {
    return 0x53003C00 | (@as(u32, wn) << 5) | @as(u32, wd);
}

/// `SDIV Wd, Wn, Wm` — signed divide, 32-bit. Arm IHI 0055
/// §C6.2.234. Trapping behaviour deferred to caller (zero-check
/// + INT_MIN/-1 overflow check happen before this).
/// Encoding (32-bit SDIV): `0 00 11010110 [Rm:5] 000011 [Rn:5] [Rd:5]`
/// = base 0x1AC00C00.
pub fn encSdivRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x1AC00C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `UDIV Wd, Wn, Wm` — unsigned divide, 32-bit.
/// Encoding (32-bit UDIV): `0 00 11010110 [Rm:5] 000010 [Rn:5] [Rd:5]`
/// = base 0x1AC00800. Arm IHI 0055 §C6.2.337.
pub fn encUdivRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x1AC00800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SDIV Xd, Xn, Xm` — signed divide, 64-bit. sf=1.
/// Encoding base 0x9AC00C00.
pub fn encSdivRegX(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9AC00C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `UDIV Xd, Xn, Xm` — unsigned divide, 64-bit. Encoding base
/// 0x9AC00800. Arm IHI 0055 §C6.2.337.
pub fn encUdivRegX(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9AC00800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MSUB Wd, Wn, Wm, Wa` — Wd = Wa - (Wn × Wm), 32-bit.
/// Used to compute remainder = lhs - (lhs/rhs)*rhs.
/// Encoding (32-bit MSUB): `0 00 11011 000 [Rm:5] 1 [Ra:5] [Rn:5] [Rd:5]`
/// = base 0x1B008000. Arm IHI 0055 §C6.2.187.
pub fn encMsubRegW(rd: Xn, rn: Xn, rm: Xn, ra: Xn) u32 {
    return 0x1B008000 | (@as(u32, rm) << 16) | (@as(u32, ra) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MSUB Xd, Xn, Xm, Xa` — 64-bit MSUB. sf=1; encoding base
/// 0x9B008000.
pub fn encMsubRegX(rd: Xn, rn: Xn, rm: Xn, ra: Xn) u32 {
    return 0x9B008000 | (@as(u32, rm) << 16) | (@as(u32, ra) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ============================================================
// Int↔float conversions (SCVTF / UCVTF / FCVT).
// All verified via clang assembler.
//
// SCVTF/UCVTF: signed/unsigned int → float. The src reg's width
// (W vs X) and the dest reg's precision (S vs D) each toggle one
// bit in the base encoding:
//   S/D toggle: bit 22 (clear → S, set → D)        — `_S` vs `_D`
//   sf  toggle: bit 31 (clear → 32-bit, set → 64-bit src)
//   U   toggle: bit 16 (clear → SCVTF, set → UCVTF)
// Each combination has its own helper for clarity.
// ============================================================

// ============================================================
// Float→int trunc-toward-zero (FCVTZS / FCVTZU).
// ARM64 FCVTZ{S,U} natively implements Wasm 2.0 sat_trunc
// semantics: NaN → 0, ±Inf → INT_MAX/MIN, overflow saturates.
// (Wasm 1.0 trapping trunc reuses these encodings + adds
//  NaN/range branches.)
// All verified via clang assembler.
// ============================================================

/// `BLR Xn` — branch-with-link to register. Used by
/// `call_indirect` after the funcptr is materialized in a GPR.
/// Encoding: `1101 0110 0011 1111 0000 00 nnnnn 0 0000` —
/// 0xD63F0000 with Rn at bits 9..5.
pub fn encBLR(rn: Xn) u32 {
    return 0xD63F0000 | (@as(u32, rn) << 5);
}

/// `STR Xt, [Xn, Xm]` — 64-bit store with X-register offset.
/// Encoding base 0xF8206800.
pub fn encStrXReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0xF8206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}

// ============================================================
// Sub-byte + sign/zero-extending memory ops.
// All verified via clang assembler.
// ============================================================

pub fn encLdrbWReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0x38606800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}
pub fn encLdrsbWReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0x38E06800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}
pub fn encLdrsbXReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0x38A06800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}
pub fn encLdrhWReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0x78606800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}
pub fn encLdrshWReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0x78E06800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}
pub fn encLdrshXReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0x78A06800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}
pub fn encLdrswXReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0xB8A06800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}
pub fn encStrbWReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0x38206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}
pub fn encStrhWReg(rt: Xn, rn: Xn, rm: Xn) u32 {
    return 0x78206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `STRB Wt, [Xn, #imm12]` — 8-bit store at unsigned imm12 byte
/// offset. Encoding: `0011 1001 00 [imm12:12] [Rn:5] [Rt:5]`
/// = `0x39000000` | … . imm12 is unscaled (byte units).
/// Used by memory.fill / memory.copy inline byte-loops.
pub fn encStrbImm(rt: Xn, rn: Xn, imm12: u12) u32 {
    return 0x39000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LDRB Wt, [Xn, #imm12]` — 8-bit load (zero-extended) at
/// unsigned imm12 byte offset. Encoding:
/// `0011 1001 01 [imm12:12] [Rn:5] [Rt:5]` = `0x39400000` | … .
pub fn encLdrbImm(rt: Xn, rn: Xn, imm12: u12) u32 {
    return 0x39400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LDR St, [Xn, Xm]` — 32-bit FP load (lower 32 of V-register).
pub fn encLdrSReg(vt: Vn, rn: Xn, rm: Xn) u32 {
    return 0xBC606800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, vt);
}
pub fn encStrSReg(vt: Vn, rn: Xn, rm: Xn) u32 {
    return 0xBC206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, vt);
}
pub fn encLdrDReg(vt: Vn, rn: Xn, rm: Xn) u32 {
    return 0xFC606800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, vt);
}
pub fn encStrDReg(vt: Vn, rn: Xn, rm: Xn) u32 {
    return 0xFC206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, vt);
}

/// `STR Sn, [Xn|SP, #pimm]` — 32-bit FP store (low 32 of V).
/// Encoding: `1011 1101 00 [imm12] [Rn:5] [Rt:5]`. The imm12
/// field is a *scaled* offset = `byte_offset / 4`; byte_offset
/// must be aligned to 4. Used by the f32 param marshal at
/// `[SP + p_idx*8]` (always 8-aligned, fits).
pub fn encStrSImm(vt: Vn, rn: Xn, byte_offset: u14) u32 {
    std.debug.assert(byte_offset % 4 == 0);
    const imm12: u32 = @as(u32, byte_offset) >> 2;
    return 0xBD000000 | (imm12 << 10) | (@as(u32, rn) << 5) | @as(u32, vt);
}

/// `STR Dn, [Xn|SP, #pimm]` — 64-bit FP store (low 64 of V).
/// Encoding: `1111 1101 00 [imm12] [Rn:5] [Rt:5]`. imm12 =
/// `byte_offset / 8`; byte_offset must be aligned to 8.
pub fn encStrDImm(vt: Vn, rn: Xn, byte_offset: u15) u32 {
    std.debug.assert(byte_offset % 8 == 0);
    const imm12: u32 = @as(u32, byte_offset) >> 3;
    return 0xFD000000 | (imm12 << 10) | (@as(u32, rn) << 5) | @as(u32, vt);
}

/// `LDR Sn, [Xn|SP, #pimm]` — 32-bit FP load (zero-extending into low 32).
/// Mirror of `encStrSImm` with bit23 set (load).
pub fn encLdrSImm(vt: Vn, rn: Xn, byte_offset: u14) u32 {
    std.debug.assert(byte_offset % 4 == 0);
    const imm12: u32 = @as(u32, byte_offset) >> 2;
    return 0xBD400000 | (imm12 << 10) | (@as(u32, rn) << 5) | @as(u32, vt);
}

/// `LDR Dn, [Xn|SP, #pimm]` — 64-bit FP load (low 64 of V).
pub fn encLdrDImm(vt: Vn, rn: Xn, byte_offset: u15) u32 {
    std.debug.assert(byte_offset % 8 == 0);
    const imm12: u32 = @as(u32, byte_offset) >> 3;
    return 0xFD400000 | (imm12 << 10) | (@as(u32, rn) << 5) | @as(u32, vt);
}

/// `CSEL Wd, Wn, Wm, cond` — 32-bit conditional select.
/// `Wd = if (cond holds) Wn else Wm`. Encoding: `0 0 0 1 1 0 1 0
/// 1 0 0 [Rm:5] [cond:4] 0 0 [Rn:5] [Rd:5]` = `0x1A800000 |
/// (Rm<<16) | (cond<<12) | (Rn<<5) | Rd`.
pub fn encCselW(rd: Xn, rn: Xn, rm: Xn, cond: Cond) u32 {
    return 0x1A800000 |
        (@as(u32, rm) << 16) |
        (@as(u32, @intFromEnum(cond)) << 12) |
        (@as(u32, rn) << 5) |
        @as(u32, rd);
}

/// `CSEL Xd, Xn, Xm, cond` — 64-bit conditional select.
/// Same shape as encCselW with sf=1 → opcode base 0x9A800000.
pub fn encCselX(rd: Xn, rn: Xn, rm: Xn, cond: Cond) u32 {
    return 0x9A800000 |
        (@as(u32, rm) << 16) |
        (@as(u32, @intFromEnum(cond)) << 12) |
        (@as(u32, rn) << 5) |
        @as(u32, rd);
}

/// `FCSEL Sd, Sn, Sm, cond` — 32-bit FP conditional select
/// (single-precision). `Sd = if cond holds then Sn else Sm`.
/// ARMv8-A C6.2.84. Encoding:
///   `0 0 0 1 1 1 1 0 0 0 1 [Rm:5] [cond:4] 1 1 [Rn:5] [Rd:5]`
/// = `0x1E200C00 | (Rm<<16) | (cond<<12) | (Rn<<5) | Rd`. Used by
/// select_typed f32 dispatch.
pub fn encFcselS(vd: Vn, vn: Vn, vm: Vn, cond: Cond) u32 {
    return 0x1E200C00 |
        (@as(u32, vm) << 16) |
        (@as(u32, @intFromEnum(cond)) << 12) |
        (@as(u32, vn) << 5) |
        @as(u32, vd);
}

/// `FCSEL Dd, Dn, Dm, cond` — 64-bit FP conditional select
/// (double-precision). Same shape as `encFcselS` with `type` field
/// = 01 (sf-equivalent for FP class) → opcode base `0x1E600C00`.
pub fn encFcselD(vd: Vn, vn: Vn, vm: Vn, cond: Cond) u32 {
    return 0x1E600C00 |
        (@as(u32, vm) << 16) |
        (@as(u32, @intFromEnum(cond)) << 12) |
        (@as(u32, vn) << 5) |
        @as(u32, vd);
}

/// `LSR Wd, Wn, #imm` — alias for UBFM Wd, Wn, #imm, #31.
/// Logical right shift with immediate count (1..31). Encoding
/// (32-bit UBFM, sf=0, opc=10):
///   `0 10 100110 0 [immr:6] [imms:6] [Rn:5] [Rd:5]`
/// = 0x53000000 | (immr<<16) | (imms<<10) | (Rn<<5) | Rd.
/// For LSR: immr = imm, imms = 31.
pub fn encLsrImmW(rd: Xn, rn: Xn, imm: u5) u32 {
    return 0x53000000 |
        (@as(u32, imm) << 16) |
        (@as(u32, 31) << 10) |
        (@as(u32, rn) << 5) |
        @as(u32, rd);
}

/// `LSR Xd, Xn, #imm` — alias for UBFM Xd, Xn, #imm, #63.
/// Logical right shift with immediate count (1..63). Encoding
/// (64-bit UBFM, sf=1, opc=10, N=1):
///   `1 10 100110 1 [immr:6] [imms:6] [Rn:5] [Rd:5]`
/// = 0xD340FC00 | (immr<<16) | (Rn<<5) | Rd.
/// For LSR: immr = imm, imms = 63 (fixed → 0xFC00 contribution).
pub fn encLsrImmX(rd: Xn, rn: Xn, imm: u6) u32 {
    return 0xD340FC00 |
        (@as(u32, imm) << 16) |
        (@as(u32, rn) << 5) |
        @as(u32, rd);
}

/// `ASR Wd, Wn, #imm` — alias for SBFM Wd, Wn, #imm, #31.
/// Arithmetic right shift (sign-replicating) with immediate count
/// (1..31). Encoding (32-bit SBFM, sf=0, opc=00, N=0):
///   `0 00 100110 0 [immr:6] [imms:6] [Rn:5] [Rd:5]`
/// = 0x13000000 | (immr<<16) | (imms<<10) | (Rn<<5) | Rd.
/// For ASR: immr = imm, imms = 31 (0x1F → 31<<10 = 0x7C00).
/// Arm IHI 0055 §C6.2.13 (ASR immediate). Used by `i31.get_s`.
pub fn encAsrImmW(rd: Xn, rn: Xn, imm: u5) u32 {
    return 0x13000000 |
        (@as(u32, imm) << 16) |
        (@as(u32, 31) << 10) |
        (@as(u32, rn) << 5) |
        @as(u32, rd);
}

/// `ORR Wd, Wn, #1` — set bit 0. The logical-immediate value `1`
/// in a 32-bit register encodes as (N=0, immr=0, imms=0): a
/// size-32 element (imms top bit 0) with 1 one bit and no
/// rotation. Encoding (32-bit ORR immediate, sf=0, opc=01):
///   `0 01 100100 0 000000 000000 [Rn:5] [Rd:5]`
/// = 0x32000000 | (Rn<<5) | Rd. Arm IHI 0055 §C6.2.181.
/// Used by `ref.i31` to set the low-bit-1 i31 discriminant.
pub fn encOrrImm1W(rd: Xn, rn: Xn) u32 {
    return 0x32000000 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `TST Wn, #1` — alias for `ANDS WZR, Wn, #1` (sets Z when bit 0
/// is clear). Same logical-immediate encoding as `encOrrImm1W`
/// for the value `1`, but opc=11 (ANDS) and Rd = WZR (31).
/// Encoding (32-bit ANDS immediate, sf=0, opc=11):
///   `0 11 100100 0 000000 000000 [Rn:5] 11111`
/// = 0x72000000 | (Rn<<5) | 31. Arm IHI 0055 §C6.2.15 (TST imm).
/// Used by `i31.get_{s,u}` for the null / non-i31 trap check.
pub fn encTstImm1W(rn: Xn) u32 {
    return 0x72000000 | (@as(u32, rn) << 5) | @as(u32, 31);
}

/// `TST Wn, #((1<<n_bits)-1)` — test the low `n_bits` of Wn (32-bit ANDS
/// WZR, Wn, #mask). A contiguous low-bits mask encodes as N=0, immr=0,
/// imms = n_bits-1 (Arm IHI 0055 §C6.2.15 bitmask immediate). Used by the
/// atomic load/store alignment check (D-303): n_bits ∈ {1,2,3} for a
/// 2/4/8-byte access (ea & (size-1) ≠ 0 → unaligned). Generalises
/// `encTstImm1W` (n_bits=1). Tests only the low 32 bits, which is
/// sufficient — alignment depends solely on the low 3 bits of `ea`.
pub fn encTstImmLowBitsW(rn: Xn, n_bits: u3) u32 {
    return 0x72000000 | (@as(u32, n_bits - 1) << 10) | (@as(u32, rn) << 5) | @as(u32, 31);
}

/// `MOVN Wd, #imm16, lsl #0` — move ~imm16 (zeroed-then-NOT
/// the lower 16). `MOVN Wd, #0` produces 0xFFFFFFFF = -1
/// (used by memory.grow's "failure" stub return).
/// Encoding (32-bit MOVN, sf=0, hw=0):
///   `0 00 100101 hw imm16 Rd` = `0x12800000`.
pub fn encMovnImmW(rd: Xn, imm16: u16) u32 {
    return 0x12800000 | (@as(u32, imm16) << 5) | @as(u32, rd);
}

/// `BR Xn` — unconditional branch to register.
/// Encoding: `1101 0110 0001 1111 0000 00 [Rn:5] 00000`
/// = `0xD61F0000` | (rn << 5).
pub fn encBr(rn: Xn) u32 {
    return 0xD61F0000 | (@as(u32, rn) << 5);
}

/// `BLR Xn` — branch-with-link to register (= CALL Xn). Sets
/// X30 (LR) to PC+4 then branches. Used by ADR-0066 Amendment
/// §A1 bridge thunks to invoke the callee's JIT entry while
/// preserving the importer's return address so the thunk can
/// restore caller-saved state before its own RET.
/// Encoding: `1101 0110 0011 1111 0000 00 [Rn:5] 00000`
/// = `0xD63F0000` | (rn << 5).
pub fn encBlr(rn: Xn) u32 {
    return 0xD63F0000 | (@as(u32, rn) << 5);
}

/// `STP Xt, Xt2, [Xn, #imm]!` — store-pair 64-bit, pre-indexed
/// (writeback). `byte_offset` MUST be 8-byte-aligned and within
/// [-512, +504]; encoder shifts by 3 to produce the 7-bit signed
/// imm7 field. Used by ADR-0066 Amendment §A1 bridge thunks to
/// allocate the thunk's own stack frame (`STP X29, X30, [SP, #-32]!`)
/// in one instruction.
/// Encoding (STP 64-bit pre-indexed): `1010 1001 10 [imm7:7]
/// [Rt2:5] [Rn:5] [Rt:5]` = `0xA9800000` | (imm7 << 15) | …
pub fn encStpPreIdx(rt: Xn, rt2: Xn, rn: Xn, byte_offset: i10) u32 {
    std.debug.assert(@mod(byte_offset, 8) == 0);
    std.debug.assert(byte_offset >= -512 and byte_offset <= 504);
    const imm7_signed: i7 = @intCast(@divExact(byte_offset, 8));
    const imm7: u32 = @as(u32, @as(u7, @bitCast(imm7_signed)));
    return 0xA9800000 | (imm7 << 15) | (@as(u32, rt2) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LDP Xt, Xt2, [Xn], #imm` — load-pair 64-bit, post-indexed
/// (writeback). Same alignment + range constraints as
/// `encStpPreIdx`. Used by ADR-0066 Amendment §A1 bridge
/// thunks to restore the thunk frame in one instruction
/// (`LDP X29, X30, [SP], #32`).
/// Encoding (LDP 64-bit post-indexed): `1010 1000 11 [imm7:7]
/// [Rt2:5] [Rn:5] [Rt:5]` = `0xA8C00000` | (imm7 << 15) | …
pub fn encLdpPostIdx(rt: Xn, rt2: Xn, rn: Xn, byte_offset: i10) u32 {
    std.debug.assert(@mod(byte_offset, 8) == 0);
    std.debug.assert(byte_offset >= -512 and byte_offset <= 504);
    const imm7_signed: i7 = @intCast(@divExact(byte_offset, 8));
    const imm7: u32 = @as(u32, @as(u7, @bitCast(imm7_signed)));
    return 0xA8C00000 | (imm7 << 15) | (@as(u32, rt2) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `NOP`. Encoding: `0xD503201F`.
pub fn encNop() u32 {
    return 0xD503201F;
}

/// `B disp` — unconditional 26-bit-signed-offset branch (PC-relative,
/// in instruction units = 4 bytes). Range ±128 MiB.
/// Encoding: `0 00101 [imm26:26]` = `0x14000000`.
pub fn encB(disp_words: i32) u32 {
    const masked: u32 = @as(u32, @bitCast(disp_words)) & 0x03FFFFFF;
    return 0x14000000 | masked;
}

/// `BL disp` — branch-with-link (call). Same imm26 form as B
/// but with bit 31 set. Sets X30 (LR) to PC+4 then branches.
/// Encoding: `1 00101 [imm26:26]` = `0x94000000`.
pub fn encBL(disp_words: i32) u32 {
    const masked: u32 = @as(u32, @bitCast(disp_words)) & 0x03FFFFFF;
    return 0x94000000 | masked;
}

/// `ADR Xd, label` — PC-relative address. Forms `Xd = PC + imm21`
/// where `imm21` is a signed 21-bit byte offset (range
/// ±1 MiB). Per Arm IHI 0055 §C6.2.10. Encoding:
/// `0 immlo[2] 10000 immhi[19] Rd[5]` — bit 31 = 0 (ADR, not
/// ADRP), bits 30..29 = immlo (low 2 bits of imm21), bits
/// 28..24 = 10000, bits 23..5 = immhi (high 19 bits of imm21),
/// bits 4..0 = Rd. Used by ADR-0066 cross-module bridge thunks
/// to compute the in-thunk literal-pool base.
pub fn encAdr(rd: Xn, byte_offset: i21) u32 {
    const u: u32 = @as(u32, @bitCast(@as(i32, byte_offset))) & 0x1FFFFF;
    const immlo: u32 = u & 0x3;
    const immhi: u32 = (u >> 2) & 0x7FFFF;
    return 0x10000000 | (immlo << 29) | (immhi << 5) | @as(u32, rd);
}

/// `CBZ Wn, disp` — branch when Wn == 0; 19-bit signed
/// instruction-unit offset (range ±1 MiB).
/// Encoding: `0 011010 0 [imm19:19] [Rt:5]` = `0x34000000`.
pub fn encCbzW(rt: Xn, disp_words: i32) u32 {
    const masked: u32 = @as(u32, @bitCast(disp_words)) & 0x0007FFFF;
    return 0x34000000 | (masked << 5) | @as(u32, rt);
}

/// `CBNZ Wn, disp` — branch when Wn != 0; 19-bit signed offset.
/// Encoding: `0 011010 1 [imm19:19] [Rt:5]` = `0x35000000`.
pub fn encCbnzW(rt: Xn, disp_words: i32) u32 {
    const masked: u32 = @as(u32, @bitCast(disp_words)) & 0x0007FFFF;
    return 0x35000000 | (masked << 5) | @as(u32, rt);
}

/// `CBZ Xn, disp` — 64-bit form, branch when Xn == 0.
/// Encoding: `1 011010 0 [imm19:19] [Rt:5]` = `0xB4000000`.
pub fn encCbz(rt: Xn, disp_words: i32) u32 {
    const masked: u32 = @as(u32, @bitCast(disp_words)) & 0x0007FFFF;
    return 0xB4000000 | (masked << 5) | @as(u32, rt);
}

/// `CBNZ Xn, disp` — 64-bit form, branch when Xn != 0.
/// Encoding: `1 011010 1 [imm19:19] [Rt:5]` = `0xB5000000`.
pub fn encCbnz(rt: Xn, disp_words: i32) u32 {
    const masked: u32 = @as(u32, @bitCast(disp_words)) & 0x0007FFFF;
    return 0xB5000000 | (masked << 5) | @as(u32, rt);
}

/// `B.cond disp` — conditional branch; 19-bit signed offset.
/// Encoding: `01010100 [imm19:19] 0 [cond:4]` = `0x54000000`.
pub fn encBCond(cond: Cond, disp_words: i32) u32 {
    const masked: u32 = @as(u32, @bitCast(disp_words)) & 0x0007FFFF;
    return 0x54000000 | (masked << 5) | @as(u32, @intFromEnum(cond));
}

/// `MUL Xd, Xn, Xm` — alias for `MADD Xd, Xn, Xm, XZR`.
/// Encoding (64-bit MADD): `1 00 11011 000 [Rm:5] 0 [Ra:5] [Rn:5] [Rd:5]`
/// with Ra=31 (XZR). Base = `0x9B007C00` | (Rm<<16) | (Rn<<5) | Rd.
pub fn encMulReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9B007C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// Wasm wide-arithmetic (ADR-0168 v0.2) — 128-bit add/sub carry chain +
// 128-bit multiply high half. `ADDS`/`SUBS` set NZCV (carry/borrow);
// `ADC`/`SBC` consume it. `UMULH`/`SMULH` give the high 64 bits of the
// 128-bit product (`MUL` gives the low 64, encMulReg above). All
// 64-bit shifted-/3-source-register forms, shift=0.

/// `ADDS Xd, Xn, Xm` — add, set flags (carry into NZCV.C).
pub fn encAddsReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0xAB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ADC Xd, Xn, Xm` — add with carry (Xd = Xn + Xm + C).
pub fn encAdcReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUBS Xd, Xn, Xm` — subtract, set flags (borrow → NZCV.C cleared).
pub fn encSubsReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0xEB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SBC Xd, Xn, Xm` — subtract with carry (Xd = Xn - Xm - !C).
pub fn encSbcReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0xDA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `UMULH Xd, Xn, Xm` — high 64 bits of the unsigned 128-bit product.
pub fn encUmulh(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9BC07C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SMULH Xd, Xn, Xm` — high 64 bits of the signed 128-bit product.
pub fn encSmulh(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9B407C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `AND Xd, Xn, Xm` (no shift). 64-bit AND shifted-reg, shift=0:
/// `1 00 01010 00 0 [Rm:5] 000000 [Rn:5] [Rd:5]` = `0x8A000000` | …
pub fn encAndReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x8A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ORR Xd, Xn, Xm` (no shift). 64-bit ORR shifted-reg, shift=0:
/// `1 01 01010 00 0 [Rm:5] 000000 [Rn:5] [Rd:5]` = `0xAA000000` | …
pub fn encOrrReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0xAA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `EOR Xd, Xn, Xm` (no shift). 64-bit EOR shifted-reg, shift=0:
/// `1 10 01010 00 0 [Rm:5] 000000 [Rn:5] [Rd:5]` = `0xCA000000` | …
pub fn encEorReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0xCA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ============================================================
// W-register (32-bit) variants
//
// Wasm i32 ops are 32-bit modulo 2^32. The W-variants implicitly
// zero-extend the 32-bit result into the upper 32 bits of the
// 64-bit X-register, which is what the spec demands. Bit 31 of
// the encoding (sf) is the only structural difference vs the
// X-variants — when sf=0 the op is W; when sf=1 it's X.
// ============================================================

/// `ADD Wd, Wn, Wm` — 32-bit register add, no shift.
/// Encoding: same as ADD X but sf=0. Base = `0x0B000000`.
pub fn encAddRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x0B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB Wd, Wn, Wm` — 32-bit register subtract, no shift. Base = `0x4B000000`.
pub fn encSubRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x4B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MUL Wd, Wn, Wm` — alias for `MADD Wd, Wn, Wm, WZR` (sf=0).
/// Base = `0x1B007C00`.
pub fn encMulRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x1B007C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `AND Wd, Wn, Wm` (no shift). Base = `0x0A000000`.
pub fn encAndRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x0A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ORR Wd, Wn, Wm` (no shift). Base = `0x2A000000`.
pub fn encOrrRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x2A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `EOR Wd, Wn, Wm` (no shift). Base = `0x4A000000`.
pub fn encEorRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x4A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `LSL Wd, Wn, Wm` — variable left shift; ARM `LSLV`.
/// Encoding (32-bit LSLV):
///   `0 00 11010110 [Rm:5] 0010 00 [Rn:5] [Rd:5]` = `0x1AC02000`.
pub fn encLslvRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x1AC02000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `LSR Wd, Wn, Wm` — variable logical right shift; ARM `LSRV`.
/// Encoding: `... 0010 01 ...` = `0x1AC02400`.
pub fn encLsrvRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x1AC02400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ASR Wd, Wn, Wm` — variable arithmetic right shift; ARM `ASRV`.
/// Encoding: `... 0010 10 ...` = `0x1AC02800`.
pub fn encAsrvRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x1AC02800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ROR Wd, Wn, Wm` — variable right rotate; ARM `RORV`.
/// Encoding: `... 0010 11 ...` = `0x1AC02C00`.
pub fn encRorvRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x1AC02C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `CMP Wn, Wm` — alias for `SUBS WZR, Wn, Wm`. Sets NZCV; the
/// result is discarded into WZR. Encoding (32-bit SUBS shifted-
/// reg, shift=0): `0 11 01011 00 0 [Rm:5] 000000 [Rn:5] 11111`
/// = `0x6B00001F` | (Rm<<16) | (Rn<<5).
pub fn encCmpRegW(rn: Xn, rm: Xn) u32 {
    return 0x6B00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5);
}

/// `CMP Wn, #imm12` — alias for `SUBS WZR, Wn, #imm12, lsl #0`.
/// Encoding (32-bit SUBS imm, sh=0): `0 11 10001 0 0 [imm12:12]
/// [Rn:5] 11111` = `0x7100001F` | (imm12<<10) | (Rn<<5).
pub fn encCmpImmW(rn: Xn, imm12: u12) u32 {
    return 0x7100001F | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5);
}

/// `CMP Xn, Xm` — alias for `SUBS XZR, Xn, Xm`. 64-bit form.
/// Encoding: `1 11 01011 00 0 [Rm:5] 000000 [Rn:5] 11111`
/// = `0xEB00001F` | (Rm<<16) | (Rn<<5).
pub fn encCmpRegX(rn: Xn, rm: Xn) u32 {
    return 0xEB00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5);
}

/// `CMP Xn, #imm12` — alias for `SUBS XZR, Xn, #imm12, lsl #0`.
/// 64-bit form. Encoding:
///   `1 11 10001 0 0 [imm12:12] [Rn:5] 11111` = `0xF100001F`
///   | (imm12<<10) | (Rn<<5).
pub fn encCmpImmX(rn: Xn, imm12: u12) u32 {
    return 0xF100001F | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5);
}

/// `CMN Wn, #imm12` — alias for `ADDS WZR, Wn, #imm12, lsl #0`.
/// Z=1 iff Wn == -imm12 (because Wn + imm12 == 0). The
/// `i32.div_s` overflow check uses `CMN Wm, #1` to detect the
/// `Wm == -1` divisor in one instruction.
/// Encoding (32-bit ADDS imm, sh=0): `0 01 10001 0 0 [imm12:12]
/// [Rn:5] 11111` = `0x3100001F` | (imm12<<10) | (Rn<<5).
pub fn encCmnImmW(rn: Xn, imm12: u12) u32 {
    return 0x3100001F | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5);
}

/// `CMN Xn, #imm12` — 64-bit counterpart of `encCmnImmW`. Used
/// by `i64.div_s` overflow check.
/// Encoding (64-bit ADDS imm, sh=0): `1 01 10001 0 0 [imm12:12]
/// [Rn:5] 11111` = `0xB100001F` | (imm12<<10) | (Rn<<5).
pub fn encCmnImmX(rn: Xn, imm12: u12) u32 {
    return 0xB100001F | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5);
}

/// `NEGS WZR, Wm` — alias for `SUBS WZR, WZR, Wm`. Sets V=1 iff
/// Wm == INT_MIN_32 (negating INT_MIN overflows). The
/// `i32.div_s` overflow check tests this after confirming the
/// divisor was -1.
/// Encoding (32-bit SUBS shifted-reg, shift=0, Rd=31, Rn=31):
///   `0 11 01011 00 0 [Rm:5] 000000 11111 11111` = `0x6B0003FF`
///   | (Rm<<16).
pub fn encNegsRegW(rm: Xn) u32 {
    return 0x6B0003FF | (@as(u32, rm) << 16);
}

/// `NEGS XZR, Xm` — 64-bit counterpart of `encNegsRegW`. V=1 iff
/// Xm == INT_MIN_64.
/// Encoding (64-bit SUBS shifted-reg, shift=0, Rd=31, Rn=31):
///   `1 11 01011 00 0 [Rm:5] 000000 11111 11111` = `0xEB0003FF`
///   | (Rm<<16).
pub fn encNegsRegX(rm: Xn) u32 {
    return 0xEB0003FF | (@as(u32, rm) << 16);
}

/// ARM condition codes (4-bit). The cond fed to `encCsetW` is
/// the encoded condition under which the result becomes 0 (the
/// CSINC alias inverts the user's "set if X" condition by XOR-1
/// with the lowest bit; this enum uses the encoded form so
/// callers do the XOR explicitly when needed).
pub const Cond = enum(u4) {
    eq = 0x0,
    ne = 0x1,
    hs = 0x2, // unsigned >=
    lo = 0x3, // unsigned <
    mi = 0x4,
    pl = 0x5,
    vs = 0x6,
    vc = 0x7,
    hi = 0x8, // unsigned >
    ls = 0x9, // unsigned <=
    ge = 0xA, // signed >=
    lt = 0xB, // signed <
    gt = 0xC, // signed >
    le = 0xD, // signed <=
};

/// Invert the lowest bit of a `Cond` — the relationship between
/// "set if X" and the encoded form for `CSET`/`CSINC` aliases.
/// `EQ <-> NE`, `LT <-> GE`, `LO <-> HS`, etc.
pub fn invertCond(c: Cond) Cond {
    return @enumFromInt(@intFromEnum(c) ^ 1);
}

/// `CSET Wd, cond` — set Wd to 1 if cond holds, else 0. Encoded
/// as `CSINC Wd, WZR, WZR, invert(cond)`. The 32-bit CSINC:
/// `0 00 11010100 [Rm:5] [cond:4] 01 [Rn:5] [Rd:5]` with Rm = Rn
/// = WZR (31). Base = `0x1A9F07E0` | (encoded_cond<<12) | Rd.
pub fn encCsetW(rd: Xn, set_if: Cond) u32 {
    const enc = invertCond(set_if);
    return 0x1A9F07E0 | (@as(u32, @intFromEnum(enc)) << 12) | @as(u32, rd);
}

/// `CSETM Xd, cond` — set Xd to all-ones if cond holds, else 0.
/// Alias of `CSINV Xd, XZR, XZR, invert(cond)`. The 64-bit CSINV
/// (sf=1, op=1):
///   `1 1 0 11010100 [Rm:5] [cond:4] 00 [Rn:5] [Rd:5]`
/// with Rm = Rn = ZR (31). Base = `0xDA9F03E0` | (enc_cond<<12)
/// | Rd. v128 select uses CSETM + DUP V.2D + BSL
/// to materialise an all-ones / all-zeros 16-byte mask. Arm IHI
/// 0055 §C6.2.59 (CSETM alias of CSINV).
pub fn encCsetmX(rd: Xn, set_if: Cond) u32 {
    const enc = invertCond(set_if);
    return 0xDA9F03E0 | (@as(u32, @intFromEnum(enc)) << 12) | @as(u32, rd);
}

/// `CLZ Wd, Wn` — count leading zeros (32-bit). The i32.clz
/// handler emits this directly.
/// Encoding (Data Processing 1-source, sf=0):
///   `0 1 0 11010110 00000 000100 [Rn:5] [Rd:5]` = `0x5AC01000`.
pub fn encClzW(rd: Xn, rn: Xn) u32 {
    return 0x5AC01000 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `RBIT Wd, Wn` — reverse bits (32-bit). i32.ctz lowers to
/// `RBIT scratch, val ; CLZ result, scratch` (the canonical
/// ARM idiom). Encoding (Data Processing 1-source, sf=0):
///   `0 1 0 11010110 00000 000000 [Rn:5] [Rd:5]` = `0x5AC00000`.
pub fn encRbitW(rd: Xn, rn: Xn) u32 {
    return 0x5AC00000 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ============================================================
// 64-bit X-variants of the i32 ops (sf=1 form).
// ============================================================

/// `LSL Xd, Xn, Xm` — 64-bit variable left shift (LSLV X form).
/// Same as LSLV W with sf=1. Encoding base: `0x9AC02000`.
pub fn encLslvRegX(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9AC02000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `LSL Xd, Xn, #shift` — 64-bit immediate left shift (UBFM alias,
/// sf=1, N=1). immr = (-shift) mod 64, imms = 63 - shift. Used by
/// D-460 to scale a GC array index by the v128 element size (`<<4`)
/// for the register-offset Q load/store.
pub fn encLslImmX(rd: Xn, rn: Xn, shift: u6) u32 {
    const immr: u32 = (@as(u32, 64) - shift) & 63;
    const imms: u32 = 63 - @as(u32, shift);
    return 0xD3400000 | (immr << 16) | (imms << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `LSR Xd, Xn, Xm` — 64-bit variable logical right shift.
pub fn encLsrvRegX(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9AC02400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ASR Xd, Xn, Xm` — 64-bit variable arithmetic right shift.
pub fn encAsrvRegX(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9AC02800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ROR Xd, Xn, Xm` — 64-bit variable right rotate.
pub fn encRorvRegX(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9AC02C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `CLZ Xd, Xn` — 64-bit count leading zeros. sf=1 vs encClzW.
/// Encoding: `1 1 0 11010110 00000 000100 [Rn:5] [Rd:5]` = `0xDAC01000`.
pub fn encClzX(rd: Xn, rn: Xn) u32 {
    return 0xDAC01000 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `RBIT Xd, Xn` — 64-bit reverse bits.
/// Encoding: `1 1 0 11010110 00000 000000 [Rn:5] [Rd:5]` = `0xDAC00000`.
pub fn encRbitX(rd: Xn, rn: Xn) u32 {
    return 0xDAC00000 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ============================================================
// Floating-point binary ALU + compare (S/D forms).
//
// Bit pattern: `0 0 0 11110 type 1 [Rm:5] [opcode:4] 10 [Rn:5] [Rd:5]`
//   type = 00 (single, S-form) → bits 23-22 = 00
//   type = 01 (double, D-form) → bits 23-22 = 01 (flips bit 22)
//   opcode = 0010 (FADD), 0011 (FSUB), 0000 (FMUL), 0001 (FDIV)
//
// All verified via `clang -target arm64-apple-darwin` assembler.
// ============================================================

// ============================================================
// Floating-point unary ops (abs/neg/sqrt + 4 rounding modes)
// + binary min/max. All verified via clang assembler.
// S-form (type=00) bases; D-form flips bit 22 → +0x400000.
// ============================================================

// ============================================================
// BIC + FMOV float→general (used by copysign)
// ============================================================

/// `BIC Wd, Wn, Wm` — bitwise bit clear (Wd = Wn AND NOT Wm).
/// 32-bit AND shifted-reg with N=1 (invert Rm). Encoding base
/// 0x0A200000.
pub fn encBicRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x0A200000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `BIC Xd, Xn, Xm` — 64-bit form of BIC.
pub fn encBicRegX(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x8A200000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// V-register index 0..31 — ARM SIMD/FP register file. Same u5
/// width as `Xn` but a separate type for documentation; the
/// integer regalloc never allocates these (the popcnt
/// handler uses V31 as fixed scratch — it's
/// caller-saved per AAPCS64 so emit can clobber it freely).
pub const Vn = u5;

/// `CNT V<d>.8B, V<n>.8B` — Advanced SIMD count bits per byte
/// (8-byte form, lower 64 bits). Encoding:
///   `0 0 0 01110 00 1 00000 00101 1 0 [Rn:5] [Rd:5]` = `0x0E205800`.
pub fn encCntV8B(vd: Vn, vn: Vn) u32 {
    return 0x0E205800 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// `ADDV B<d>, V<n>.8B` — Advanced SIMD across-vector add of
/// bytes (sums 8 bytes into byte 0 of Vd; upper bytes zero).
/// Encoding:
///   `0 0 0 01110 00 1 1000 1 1011 10 [Rn:5] [Rd:5]` = `0x0E31B800`.
pub fn encAddvB8B(vd: Vn, vn: Vn) u32 {
    return 0x0E31B800 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// `UMOV W<d>, V<n>.B[0]` — Advanced SIMD extract byte 0 to
/// 32-bit GPR (zero-extends). Encoding:
///   `0 0 0 01110 000 00001 0 0111 1 [Rn:5] [Rd:5]` = `0x0E013C00`.
/// (imm5=00001 selects B-element, index 0.)
pub fn encUmovWFromVB0(wd: Xn, vn: Vn) u32 {
    return 0x0E013C00 | (@as(u32, vn) << 5) | @as(u32, wd);
}

// ============================================================
// Tests
//
// Bit patterns cross-checked against the Arm Architecture
// Reference Manual (DDI 0487 K.a) and `llvm-mc -triple=aarch64
// -show-encoding`. Each test cites the asm form so future readers
// can re-verify by pasting into `llvm-mc`.
// ============================================================

const testing = std.testing;

test "encRet x30 — `ret` (the canonical bare RET) → 0xD65F03C0" {
    try testing.expectEqual(@as(u32, 0xD65F03C0), encRet(30));
}

test "encRet x0 — `ret x0` → 0xD65F0000" {
    try testing.expectEqual(@as(u32, 0xD65F0000), encRet(0));
}

test "encMovzImm16 x0, #0 — `movz x0, #0` → 0xD2800000" {
    try testing.expectEqual(@as(u32, 0xD2800000), encMovzImm16(0, 0));
}

test "encMovzImm16 x0, #42 — `movz x0, #42` → 0xD2800540" {
    // imm16=42 (<<5)=0x540; rd=0; base=0xD2800000.
    try testing.expectEqual(@as(u32, 0xD2800540), encMovzImm16(0, 42));
}

test "encAsrImmW w0, w0, #1 — `asr w0, w0, #1` → 0x13017C00 (i31.get_s)" {
    // SBFM Wd,Wn,#imm,#31: base 0x13000000; immr=1 (<<16); imms=31 (<<10=0x7C00).
    try testing.expectEqual(@as(u32, 0x13017C00), encAsrImmW(0, 0, 1));
    // Register-field exercise: asr w2, w3, #1.
    try testing.expectEqual(@as(u32, 0x13017C62), encAsrImmW(2, 3, 1));
}

test "encOrrImm1W w0, w0 — `orr w0, w0, #1` → 0x32000000 (ref.i31 tag)" {
    try testing.expectEqual(@as(u32, 0x32000000), encOrrImm1W(0, 0));
    // Register-field exercise: orr w5, w6, #1.
    try testing.expectEqual(@as(u32, 0x320000C5), encOrrImm1W(5, 6));
}

test "encTstImm1W w0 — `tst w0, #1` (ANDS wzr,w0,#1) → 0x7200001F (i31 null check)" {
    try testing.expectEqual(@as(u32, 0x7200001F), encTstImm1W(0));
    // Register-field exercise: tst w7, #1.
    try testing.expectEqual(@as(u32, 0x720000FF), encTstImm1W(7));
}

test "encMovkImm16 x0, #1, lsl #16 — `movk x0, #1, lsl #16` → 0xF2A00020" {
    // hw=1 sets bit 21 (0x200000); imm16=1 (<<5)=0x20; base=0xF2800000.
    try testing.expectEqual(@as(u32, 0xF2A00020), encMovkImm16(0, 1, 1));
}

test "encAddImm12 x0, x1, #1 — `add x0, x1, #1` → 0x91000420" {
    // base 0x91000000; imm=1 (<<10)=0x400; rn=1 (<<5)=0x20; rd=0.
    try testing.expectEqual(@as(u32, 0x91000420), encAddImm12(0, 1, 1));
}

test "encAddImm12Lsl12 x16, x16, #1 — `add x16, x16, #1, lsl #12` → 0x91400610" {
    // base 0x91400000; imm=1 (<<10)=0x400; rn=16 (<<5)=0x200; rd=16.
    try testing.expectEqual(@as(u32, 0x91400610), encAddImm12Lsl12(16, 16, 1));
}

test "encSubImm12Lsl12 sp, sp, #1 — `sub sp, sp, #1, lsl #12` → 0xD14007FF" {
    // base 0xD1400000 | imm=1 (<<10) = 0x400 | rn=31 (<<5) = 0x3E0 | rd=31 = 0x1F.
    try testing.expectEqual(@as(u32, 0xD14007FF), encSubImm12Lsl12(31, 31, 1));
}

test "encSubImm12 x0, x1, #4 — `sub x0, x1, #4` → 0xD1001020" {
    try testing.expectEqual(@as(u32, 0xD1001020), encSubImm12(0, 1, 4));
}

test "encAddReg x0, x1, x2 — `add x0, x1, x2` → 0x8B020020" {
    // rm=2 (<<16)=0x20000; rn=1 (<<5)=0x20; rd=0.
    try testing.expectEqual(@as(u32, 0x8B020020), encAddReg(0, 1, 2));
}

test "encSubReg x3, x4, x5 — `sub x3, x4, x5` → 0xCB050083" {
    try testing.expectEqual(@as(u32, 0xCB050083), encSubReg(3, 4, 5));
}

test "encLdrImm x0, [x1, #0] — `ldr x0, [x1]` → 0xF9400020" {
    try testing.expectEqual(@as(u32, 0xF9400020), encLdrImm(0, 1, 0));
}

test "encLdrImm x0, [x1, #8] — `ldr x0, [x1, #8]` → 0xF9400420" {
    try testing.expectEqual(@as(u32, 0xF9400420), encLdrImm(0, 1, 8));
}

test "encStrImm x0, [x1, #16] — `str x0, [x1, #16]` → 0xF9000820" {
    try testing.expectEqual(@as(u32, 0xF9000820), encStrImm(0, 1, 16));
}

test "encStrImmW w9, [sp, #0] — `str w9, [sp]` → 0xB90003E9" {
    try testing.expectEqual(@as(u32, 0xB90003E9), encStrImmW(9, 31, 0));
}

test "encLdrImmW w10, [sp, #8] — `ldr w10, [sp, #8]` → 0xB9400BEA" {
    // imm12 = 8>>2 = 2; <<10 = 0x800.
    try testing.expectEqual(@as(u32, 0xB9400BEA), encLdrImmW(10, 31, 8));
}

test "encLdrWReg w0, [x28, x16] — `ldr w0, [x28, x16]` → 0xB8706B80" {
    try testing.expectEqual(@as(u32, 0xB8706B80), encLdrWReg(0, 28, 16));
}
test "encStrWReg w0, [x28, x16] — `str w0, [x28, x16]` → 0xB8306B80" {
    try testing.expectEqual(@as(u32, 0xB8306B80), encStrWReg(0, 28, 16));
}
test "encLdrXReg x0, [x28, x16] — `ldr x0, [x28, x16]` → 0xF8706B80" {
    try testing.expectEqual(@as(u32, 0xF8706B80), encLdrXReg(0, 28, 16));
}
test "encLdrXRegLsl3 x0, [x28, x16, lsl #3] → 0xF8707B80" {
    try testing.expectEqual(@as(u32, 0xF8707B80), encLdrXRegLsl3(0, 28, 16));
}
test "encLslImmX x0, x1, #4 → 0xD37CEC20 (D-460 v128 array stride)" {
    try testing.expectEqual(@as(u32, 0xD37CEC20), encLslImmX(0, 1, 4));
}
test "encStrXRegLsl3 x0, [x11, x17, lsl #3] → 0xF8317960" {
    try testing.expectEqual(@as(u32, 0xF8317960), encStrXRegLsl3(0, 11, 17));
}
test "encLdrWRegLsl2 w16, [x24, x17, lsl #2] → 0xB8717B10" {
    try testing.expectEqual(@as(u32, 0xB8717B10), encLdrWRegLsl2(16, 24, 17));
}
test "encSxtw x9, w10 — `sxtw x9, w10` → 0x93407D49" {
    try testing.expectEqual(@as(u32, 0x93407D49), encSxtw(9, 10));
}
test "encBLR x17 — `blr x17` → 0xD63F0220" {
    try testing.expectEqual(@as(u32, 0xD63F0220), encBLR(17));
}
test "encStrXReg x0, [x28, x16] — `str x0, [x28, x16]` → 0xF8306B80" {
    try testing.expectEqual(@as(u32, 0xF8306B80), encStrXReg(0, 28, 16));
}

test "encLdrbWReg w0, [x28, x16] → 0x38706B80" {
    try testing.expectEqual(@as(u32, 0x38706B80), encLdrbWReg(0, 28, 16));
}
test "encLdrsbWReg w0, [x28, x16] → 0x38F06B80" {
    try testing.expectEqual(@as(u32, 0x38F06B80), encLdrsbWReg(0, 28, 16));
}
test "encLdrsbXReg x0, [x28, x16] → 0x38B06B80" {
    try testing.expectEqual(@as(u32, 0x38B06B80), encLdrsbXReg(0, 28, 16));
}
test "encLdrhWReg w0, [x28, x16] → 0x78706B80" {
    try testing.expectEqual(@as(u32, 0x78706B80), encLdrhWReg(0, 28, 16));
}
test "encLdrshWReg w0, [x28, x16] → 0x78F06B80" {
    try testing.expectEqual(@as(u32, 0x78F06B80), encLdrshWReg(0, 28, 16));
}
test "encLdrshXReg x0, [x28, x16] → 0x78B06B80" {
    try testing.expectEqual(@as(u32, 0x78B06B80), encLdrshXReg(0, 28, 16));
}
test "encLdrswXReg x0, [x28, x16] → 0xB8B06B80" {
    try testing.expectEqual(@as(u32, 0xB8B06B80), encLdrswXReg(0, 28, 16));
}
test "encStrbWReg w0, [x28, x16] → 0x38306B80" {
    try testing.expectEqual(@as(u32, 0x38306B80), encStrbWReg(0, 28, 16));
}
test "encStrhWReg w0, [x28, x16] → 0x78306B80" {
    try testing.expectEqual(@as(u32, 0x78306B80), encStrhWReg(0, 28, 16));
}
test "encLdrSReg s0, [x28, x16] → 0xBC706B80" {
    try testing.expectEqual(@as(u32, 0xBC706B80), encLdrSReg(0, 28, 16));
}
test "encStrSReg s0, [x28, x16] → 0xBC306B80" {
    try testing.expectEqual(@as(u32, 0xBC306B80), encStrSReg(0, 28, 16));
}
test "encLdrDReg d0, [x28, x16] → 0xFC706B80" {
    try testing.expectEqual(@as(u32, 0xFC706B80), encLdrDReg(0, 28, 16));
}
test "encStrDReg d0, [x28, x16] → 0xFC306B80" {
    try testing.expectEqual(@as(u32, 0xFC306B80), encStrDReg(0, 28, 16));
}

test "encLsrImmX x0, x0, #63 → 0xD37FFC00" {
    try testing.expectEqual(@as(u32, 0xD37FFC00), encLsrImmX(0, 0, 63));
}

test "encLsrImmX x3, x4, #1 → 0xD341FC83" {
    try testing.expectEqual(@as(u32, 0xD341FC83), encLsrImmX(3, 4, 1));
}

test "encLsrImmW w0, w27, #16 → 0x53107F60" {
    try testing.expectEqual(@as(u32, 0x53107F60), encLsrImmW(0, 27, 16));
}
test "encMovnImmW w0, #0 → 0x12800000 (= -1 in W)" {
    try testing.expectEqual(@as(u32, 0x12800000), encMovnImmW(0, 0));
}

test "encBr x16 — `br x16` → 0xD61F0200" {
    try testing.expectEqual(@as(u32, 0xD61F0200), encBr(16));
}

test "encB +1 — `b 1f / nop / 1:` → 0x14000001" {
    try testing.expectEqual(@as(u32, 0x14000001), encB(1));
}

test "encB -1 — backward branch by 1 word → 0x17FFFFFF" {
    // imm26 sign-extended = -1; bit26 wraps. Mask to 26 bits = 0x3FFFFFF.
    try testing.expectEqual(@as(u32, 0x17FFFFFF), encB(-1));
}

test "encBL +1 — `bl 1f` (next instr) → 0x94000001" {
    try testing.expectEqual(@as(u32, 0x94000001), encBL(1));
}

test "encAdr x16, +16 — `adr x16, .+16` → 0x10000090 (cross-module thunk literal pool base)" {
    try testing.expectEqual(@as(u32, 0x10000090), encAdr(16, 16));
}

test "encAdr x0, 0 — `adr x0, .` → 0x10000000" {
    try testing.expectEqual(@as(u32, 0x10000000), encAdr(0, 0));
}

test "encAdr x1, +3 — odd byte offset packs immlo correctly" {
    // imm21 = 3 = 0b11. immlo = 0b11 → bits 30..29 = 0b11.
    // immhi = 0, Rd = 1. Pack:
    //   bit 31 = 0, bits 30..29 = 11, bits 28..24 = 10000,
    //   bits 23..5 = 0, bits 4..0 = 00001.
    // = 0_11_10000_0000000000000000000_00001 = 0x70000001.
    try testing.expectEqual(@as(u32, 0x70000001), encAdr(1, 3));
}

test "encCbnzW w0, +1 — `cbnz w0, 1f` → 0x35000020" {
    try testing.expectEqual(@as(u32, 0x35000020), encCbnzW(0, 1));
}

test "encCbzW w0, +1 — `cbz w0, 1f` → 0x34000020" {
    try testing.expectEqual(@as(u32, 0x34000020), encCbzW(0, 1));
}

test "encBCond .eq, +1 — `b.eq 1f` → 0x54000020" {
    try testing.expectEqual(@as(u32, 0x54000020), encBCond(.eq, 1));
}

test "encMulReg x0, x1, x2 — `mul x0, x1, x2` → 0x9B027C20" {
    // base 0x9B007C00; rm=2 (<<16)=0x20000; rn=1 (<<5)=0x20; rd=0.
    try testing.expectEqual(@as(u32, 0x9B027C20), encMulReg(0, 1, 2));
}

test "encAndReg x0, x1, x2 — `and x0, x1, x2` → 0x8A020020" {
    try testing.expectEqual(@as(u32, 0x8A020020), encAndReg(0, 1, 2));
}

test "encOrrReg x0, x1, x2 — `orr x0, x1, x2` → 0xAA020020" {
    try testing.expectEqual(@as(u32, 0xAA020020), encOrrReg(0, 1, 2));
}

test "encEorReg x0, x1, x2 — `eor x0, x1, x2` → 0xCA020020" {
    try testing.expectEqual(@as(u32, 0xCA020020), encEorReg(0, 1, 2));
}

test "encAddRegW w0, w1, w2 — `add w0, w1, w2` → 0x0B020020" {
    try testing.expectEqual(@as(u32, 0x0B020020), encAddRegW(0, 1, 2));
}

test "encSubRegW w0, w1, w2 — `sub w0, w1, w2` → 0x4B020020" {
    try testing.expectEqual(@as(u32, 0x4B020020), encSubRegW(0, 1, 2));
}

test "encMulRegW w0, w1, w2 — `mul w0, w1, w2` → 0x1B027C20" {
    try testing.expectEqual(@as(u32, 0x1B027C20), encMulRegW(0, 1, 2));
}

test "encAndRegW w0, w1, w2 — `and w0, w1, w2` → 0x0A020020" {
    try testing.expectEqual(@as(u32, 0x0A020020), encAndRegW(0, 1, 2));
}

test "encOrrRegW w0, w1, w2 — `orr w0, w1, w2` → 0x2A020020" {
    try testing.expectEqual(@as(u32, 0x2A020020), encOrrRegW(0, 1, 2));
}

test "encEorRegW w0, w1, w2 — `eor w0, w1, w2` → 0x4A020020" {
    try testing.expectEqual(@as(u32, 0x4A020020), encEorRegW(0, 1, 2));
}

test "encLslvRegW w0, w1, w2 — `lsl w0, w1, w2` → 0x1AC22020" {
    try testing.expectEqual(@as(u32, 0x1AC22020), encLslvRegW(0, 1, 2));
}

test "encLsrvRegW w0, w1, w2 — `lsr w0, w1, w2` → 0x1AC22420" {
    try testing.expectEqual(@as(u32, 0x1AC22420), encLsrvRegW(0, 1, 2));
}

test "encAsrvRegW w0, w1, w2 — `asr w0, w1, w2` → 0x1AC22820" {
    try testing.expectEqual(@as(u32, 0x1AC22820), encAsrvRegW(0, 1, 2));
}

test "encRorvRegW w0, w1, w2 — `ror w0, w1, w2` → 0x1AC22C20" {
    try testing.expectEqual(@as(u32, 0x1AC22C20), encRorvRegW(0, 1, 2));
}

test "encCmpRegW w1, w2 — `cmp w1, w2` → 0x6B02003F" {
    // base 0x6B00001F; rm=2 (<<16)=0x20000; rn=1 (<<5)=0x20.
    try testing.expectEqual(@as(u32, 0x6B02003F), encCmpRegW(1, 2));
}

test "encCmpImmW w1, #0 — `cmp w1, #0` → 0x7100003F" {
    try testing.expectEqual(@as(u32, 0x7100003F), encCmpImmW(1, 0));
}

test "encCmpImmW w1, #5 — `cmp w1, #5` → 0x7100143F" {
    // imm12=5 (<<10)=0x1400; rn=1 (<<5)=0x20.
    try testing.expectEqual(@as(u32, 0x7100143F), encCmpImmW(1, 5));
}

test "encCmpRegX x1, x2 — `cmp x1, x2` → 0xEB02003F" {
    try testing.expectEqual(@as(u32, 0xEB02003F), encCmpRegX(1, 2));
}

test "encCmpImmX x1, #0 — `cmp x1, #0` → 0xF100003F" {
    try testing.expectEqual(@as(u32, 0xF100003F), encCmpImmX(1, 0));
}

test "encCmnImmW w2, #1 — `cmn w2, #1` → 0x3100045F" {
    // Base 0x3100001F | imm12=1 (<<10) = 0x400 | rn=2 (<<5) = 0x40.
    try testing.expectEqual(@as(u32, 0x3100045F), encCmnImmW(2, 1));
}

test "encCmnImmX x3, #1 — `cmn x3, #1` → 0xB100047F" {
    // Base 0xB100001F | imm12=1 (<<10) = 0x400 | rn=3 (<<5) = 0x60.
    try testing.expectEqual(@as(u32, 0xB100047F), encCmnImmX(3, 1));
}

test "encNegsRegW wm=2 — `negs wzr, w2` → 0x6B0203FF" {
    // Base 0x6B0003FF | rm=2 (<<16) = 0x20000.
    try testing.expectEqual(@as(u32, 0x6B0203FF), encNegsRegW(2));
}

test "encNegsRegX xm=3 — `negs xzr, x3` → 0xEB0303FF" {
    // Base 0xEB0003FF | rm=3 (<<16) = 0x30000.
    try testing.expectEqual(@as(u32, 0xEB0303FF), encNegsRegX(3));
}

test "invertCond: eq <-> ne, lt <-> ge, lo <-> hs" {
    try testing.expectEqual(Cond.ne, invertCond(.eq));
    try testing.expectEqual(Cond.eq, invertCond(.ne));
    try testing.expectEqual(Cond.ge, invertCond(.lt));
    try testing.expectEqual(Cond.lt, invertCond(.ge));
    try testing.expectEqual(Cond.hs, invertCond(.lo));
    try testing.expectEqual(Cond.lo, invertCond(.hs));
}

test "encCsetW w0, eq — `cset w0, eq` → 0x1A9F17E0" {
    // CSET Wd, EQ → CSINC Wd, WZR, WZR, NE.
    // base 0x1A9F07E0; cond=NE (0x1 << 12) = 0x1000; Rd=0.
    try testing.expectEqual(@as(u32, 0x1A9F17E0), encCsetW(0, .eq));
}

test "encCsetW w3, lt — `cset w3, lt` → 0x1A9FA7E3" {
    // invert(LT=0xB) = 0xA = GE; (0xA << 12) = 0xA000; Rd=3.
    try testing.expectEqual(@as(u32, 0x1A9FA7E3), encCsetW(3, .lt));
}

test "encFcselS s0, s1, s2, ne — `fcsel s0, s1, s2, ne` → 0x1E221C20" {
    // FCSEL Sd, Sn, Sm, cond — single-precision FP conditional
    // select. base 0x1E200C00; Rm=2 (<<16=0x20000); cond=NE
    // (0x1 << 12 = 0x1000); Rn=1 (<<5=0x20); Rd=0. Used by
    // select_typed f32 dispatch.
    try testing.expectEqual(@as(u32, 0x1E221C20), encFcselS(0, 1, 2, .ne));
}

test "encFcselD d3, d5, d7, eq — `fcsel d3, d5, d7, eq` → 0x1E6700A3" {
    // FCSEL Dd, Dn, Dm, cond — double-precision FP conditional
    // select. base 0x1E600C00; Rm=7 (<<16=0x70000); cond=EQ
    // (0x0 << 12); Rn=5 (<<5=0xA0); Rd=3. Used by
    // select_typed f64 dispatch.
    try testing.expectEqual(@as(u32, 0x1E6700A3 | 0x0C00), encFcselD(3, 5, 7, .eq));
}

test "encCsetmX x0, ne — `csetm x0, ne` → 0xDA9F03E0" {
    // invert(NE) = EQ (0x0); base 0xDA9F03E0; Rd=0; cond field=0.
    try testing.expectEqual(@as(u32, 0xDA9F03E0), encCsetmX(0, .ne));
}

test "encCsetmX x17, eq — `csetm x17, eq` → 0xDA9F13F1" {
    // invert(EQ) = NE (0x1); (0x1<<12) = 0x1000; Rd=17.
    try testing.expectEqual(@as(u32, 0xDA9F13F1), encCsetmX(17, .eq));
}

test "encCsetmX x30, ne — `csetm x30, ne` → 0xDA9F03FE" {
    // Rd=30; cond field=0.
    try testing.expectEqual(@as(u32, 0xDA9F03FE), encCsetmX(30, .ne));
}

test "encClzW w0, w1 — `clz w0, w1` → 0x5AC01020" {
    // base 0x5AC01000; rn=1 (<<5)=0x20; rd=0.
    try testing.expectEqual(@as(u32, 0x5AC01020), encClzW(0, 1));
}

test "encRbitW w0, w1 — `rbit w0, w1` → 0x5AC00020" {
    try testing.expectEqual(@as(u32, 0x5AC00020), encRbitW(0, 1));
}

test "encLslvRegX x0, x1, x2 — `lsl x0, x1, x2` → 0x9AC22020" {
    try testing.expectEqual(@as(u32, 0x9AC22020), encLslvRegX(0, 1, 2));
}

test "encLsrvRegX x0, x1, x2 — `lsr x0, x1, x2` → 0x9AC22420" {
    try testing.expectEqual(@as(u32, 0x9AC22420), encLsrvRegX(0, 1, 2));
}

test "encAsrvRegX x0, x1, x2 — `asr x0, x1, x2` → 0x9AC22820" {
    try testing.expectEqual(@as(u32, 0x9AC22820), encAsrvRegX(0, 1, 2));
}

test "encRorvRegX x0, x1, x2 — `ror x0, x1, x2` → 0x9AC22C20" {
    try testing.expectEqual(@as(u32, 0x9AC22C20), encRorvRegX(0, 1, 2));
}

test "encClzX x0, x1 — `clz x0, x1` → 0xDAC01020" {
    try testing.expectEqual(@as(u32, 0xDAC01020), encClzX(0, 1));
}

test "encRbitX x0, x1 — `rbit x0, x1` → 0xDAC00020" {
    try testing.expectEqual(@as(u32, 0xDAC00020), encRbitX(0, 1));
}

test "encBicRegW w0, w1, w2 → 0x0A220020" {
    try testing.expectEqual(@as(u32, 0x0A220020), encBicRegW(0, 1, 2));
}
test "encBicRegX x0, x1, x2 → 0x8A220020" {
    try testing.expectEqual(@as(u32, 0x8A220020), encBicRegX(0, 1, 2));
}

// V-register encodings cross-checked via `clang -target
// arm64-apple-darwin` assembler. See verifier session in
// commit history (popcnt prep).

test "encCntV8B v0.8b ← v0.8b — `cnt v0.8b, v0.8b` → 0x0E205800" {
    try testing.expectEqual(@as(u32, 0x0E205800), encCntV8B(0, 0));
}

test "encCntV8B v31.8b ← v31.8b — `cnt v31.8b, v31.8b` → 0x0E205BFF" {
    try testing.expectEqual(@as(u32, 0x0E205BFF), encCntV8B(31, 31));
}

test "encAddvB8B b0 ← v0.8b — `addv b0, v0.8b` → 0x0E31B800" {
    try testing.expectEqual(@as(u32, 0x0E31B800), encAddvB8B(0, 0));
}

test "encAddvB8B b31 ← v31.8b — `addv b31, v31.8b` → 0x0E31BBFF" {
    try testing.expectEqual(@as(u32, 0x0E31BBFF), encAddvB8B(31, 31));
}

test "encUmovWFromVB0 w0 ← v0.B[0] — `umov w0, v0.b[0]` → 0x0E013C00" {
    try testing.expectEqual(@as(u32, 0x0E013C00), encUmovWFromVB0(0, 0));
}

test "encUmovWFromVB0 w10 ← v31.B[0] — `umov w10, v31.b[0]` → 0x0E013FEA" {
    try testing.expectEqual(@as(u32, 0x0E013FEA), encUmovWFromVB0(10, 31));
}

// Sign-extension + integer divide encoders.
// Hex bytes verified via `clang -target arm64-apple-darwin` assembler;
// see inst.zig docstrings for Arm IHI 0055 references.
test "encSxtbW w0, w0 → 0x13001C00" {
    try testing.expectEqual(@as(u32, 0x13001C00), encSxtbW(0, 0));
}
test "encSxthW w0, w0 → 0x13003C00" {
    try testing.expectEqual(@as(u32, 0x13003C00), encSxthW(0, 0));
}
test "encUxtbW w0, w1 → 0x53001C20 (uxtb w0, w1)" {
    try testing.expectEqual(@as(u32, 0x53001C20), encUxtbW(0, 1));
}
test "encUxthW w0, w1 → 0x53003C20 (uxth w0, w1)" {
    try testing.expectEqual(@as(u32, 0x53003C20), encUxthW(0, 1));
}
test "encSxtbX x0, w0 → 0x93401C00" {
    try testing.expectEqual(@as(u32, 0x93401C00), encSxtbX(0, 0));
}
test "encSxthX x0, w0 → 0x93403C00" {
    try testing.expectEqual(@as(u32, 0x93403C00), encSxthX(0, 0));
}
test "encSdivRegW w0, w1, w2 → 0x1AC20C20" {
    try testing.expectEqual(@as(u32, 0x1AC20C20), encSdivRegW(0, 1, 2));
}
test "encUdivRegW w0, w1, w2 → 0x1AC20820" {
    try testing.expectEqual(@as(u32, 0x1AC20820), encUdivRegW(0, 1, 2));
}
test "encSdivRegX x0, x1, x2 → 0x9AC20C20" {
    try testing.expectEqual(@as(u32, 0x9AC20C20), encSdivRegX(0, 1, 2));
}
test "encUdivRegX x0, x1, x2 → 0x9AC20820" {
    try testing.expectEqual(@as(u32, 0x9AC20820), encUdivRegX(0, 1, 2));
}
test "encMsubRegW w0, w1, w2, w3 → 0x1B028C20" {
    try testing.expectEqual(@as(u32, 0x1B028C20), encMsubRegW(0, 1, 2, 3));
}
test "encMsubRegX x0, x1, x2, x3 → 0x9B028C20" {
    try testing.expectEqual(@as(u32, 0x9B028C20), encMsubRegX(0, 1, 2, 3));
}
test "encBlr x16 → 0xD63F0200" {
    try testing.expectEqual(@as(u32, 0xD63F0200), encBlr(16));
}
test "encBlr x30 → 0xD63F03C0" {
    try testing.expectEqual(@as(u32, 0xD63F03C0), encBlr(30));
}
test "encStpPreIdx x29, x30, [sp, #-32]! → 0xA9BE7BFD" {
    try testing.expectEqual(@as(u32, 0xA9BE7BFD), encStpPreIdx(29, 30, sp_reg, -32));
}
test "encStpPreIdx x29, x30, [sp, #-16]! → 0xA9BF7BFD" {
    // imm7 = -16/8 = -2 → u7 0x7E → bits 21:15 = 1111110
    try testing.expectEqual(@as(u32, 0xA9BF7BFD), encStpPreIdx(29, 30, sp_reg, -16));
}
test "encLdpPostIdx x29, x30, [sp], #32 → 0xA8C27BFD" {
    try testing.expectEqual(@as(u32, 0xA8C27BFD), encLdpPostIdx(29, 30, sp_reg, 32));
}
test "encLdpPostIdx x29, x30, [sp], #16 → 0xA8C17BFD" {
    try testing.expectEqual(@as(u32, 0xA8C17BFD), encLdpPostIdx(29, 30, sp_reg, 16));
}
