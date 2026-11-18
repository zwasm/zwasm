//\! ARM64 NEON foundational encoders (per ADR-0041).
//\!
//\! Foundation-tier SIMD-128 encoders kept after the source
//\! split:
//\!
//\! - Memory load/store Q-form (`LDR/STR Q<rt>, ...`, `LD1R`).
//\! - Reg-to-reg moves (`ORR/MOV V<d>.16B`).
//\! - Splat from GPR / scalar lane (`DUP V<d>.<T>, ...`).
//\! - Bitwise foundation (`AND/BIC/EOR/MVN/NOT V<d>.16B`,
//\!   `BSL` bitwise-select).
//\! - Const-pool placeholder (`LDR (literal), Q<t>` + imm19
//\!   patch).
//\! - Public type aliases `Vn` / `Xn` re-exported by the
//\!   sibling encoder modules.
//\!
//\! Arithmetic / FP-arith / FP-unary / conversion / TBL /
//\! extend-narrow / SSHR-immediate / reductions live in
//\! `inst_neon_arith.zig`. Lane access (UMOV/SMOV/INS) and
//\! integer + FP per-lane compares live in `inst_neon_lane_cmp
//\! .zig`.
//\!
//\! Bit patterns from the Arm Architecture Reference Manual
//\! (DDI 0487, A64 SIMD&FP instructions). Each `pub fn enc<X>`
//\! returns the little-endian `u32` ready to write to the code
//\! buffer; the emit pass packs them into `[]u8` via
//\! `std.mem.writeInt(u32, ..., .little)`.
//\!
//\! Per ADR-0041 §"Decision" / 2: Q registers map to the
//\! existing FP-class register pool (V0-V31; allocatable
//\! V16-V28 per ADR-0027 + D-037). The 128-bit Q view shares
//\! the underlying register file with scalar D/S forms — the
//\! `ShapeTag` axis on `Allocation` disambiguates which
//\! view emit should use.
//\!
//\! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//\! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");

/// V-register index 0..31. NEON's 128-bit view is `Q<n>`;
/// the same index also names the 64-bit `D<n>`, 32-bit `S<n>`,
/// 16-bit `H<n>`, and 8-bit `B<n>` views — opcode determines
/// which width is in use.
pub const Vn = u5;

/// X-register index alias (re-exported from `inst.zig`'s shape
/// for callers that import only `inst_neon.zig`). The encoders
/// here treat GPR sources as `Vn`-shaped u5 since the 5-bit
/// register field is identical across X and V register banks.
pub const Xn = u5;

// =====================================================================
// Memory ops (128-bit)
// =====================================================================

/// `LDR Q<rt>, [X<n>, #imm]` — load 128-bit at unsigned imm12
/// offset scaled by 16. `byte_offset` MUST be 16-byte aligned
/// and < 65536. Encoder shifts >>4 to produce the imm12 field.
///
/// Encoding (SIMD&FP load unsigned offset, size=00, opc=11):
///   `00 111 1 01 11 [imm12:12] [Rn:5] [Rt:5]`
///   = `0x3DC00000` | (imm12 << 10) | (Rn << 5) | Rt
///
/// Per Arm IHI 0055 §C7.2.184. The Q form (size=00, opc=11)
/// is distinct from D (size=11, opc=01) and S (size=10,
/// opc=01) — opcode bits select the 128-bit view.
pub fn encLdrQImm(rt: Vn, rn: Xn, byte_offset: u16) u32 {
    const imm12: u12 = @intCast(byte_offset >> 4);
    return 0x3DC00000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `STR Q<rt>, [X<n>, #imm]` — store 128-bit at unsigned imm12
/// offset scaled by 16. Same alignment constraint as
/// `encLdrQImm`.
///
/// Encoding (SIMD&FP store unsigned offset, size=00, opc=10):
///   `00 111 1 01 10 [imm12:12] [Rn:5] [Rt:5]`
///   = `0x3D800000` | (imm12 << 10) | (Rn << 5) | Rt
///
/// Per Arm IHI 0055 §C7.2.337.
pub fn encStrQImm(rt: Vn, rn: Xn, byte_offset: u16) u32 {
    const imm12: u12 = @intCast(byte_offset >> 4);
    return 0x3D800000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LDR Qt, [Xn, Xm]` — 128-bit Q-form load, register-offset
/// addressing (LSL #0). Wasm spec §4.4.6.1 (vector load): the
/// emit pass routes `v128.load`'s effective address through
/// X16 (= wasm-relative addr + memarg offset, zero-extended)
/// and uses X28 as `vm_base`, mirroring `op_memory.emitMemOp`.
/// SIMD&FP 128-bit reg-offset base is 0x3CE06800 (opc=11
/// load, V=1, size_lo=00, option=011 LSL, S=0). Verified
/// against `clang -arch arm64` of `ldr q0, [x28, x16]` →
/// 0x3CF06B80. Per Arm IHI 0055 "LDR (register, SIMD&FP)".
pub fn encLdrQReg(rt: Vn, rn: Xn, rm: Xn) u32 {
    return 0x3CE06800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `STR Qt, [Xn, Xm]` — 128-bit Q-form store, register-offset
/// addressing (LSL #0). Wasm spec §4.4.6.2 (vector store).
/// SIMD&FP 128-bit reg-offset base is 0x3CA06800 (opc=10 store
/// vs LDR's opc=11). Used by `v128.store` after the same
/// bounds-check prologue as scalar `op_memory.emitMemOp`.
pub fn encStrQReg(rt: Vn, rn: Xn, rm: Xn) u32 {
    return 0x3CA06800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LD1R {Vt.16B}, [Xn]` — load one byte from `[Xn]` and replicate
/// to all 16 lanes of Vt. Wasm spec §4.4.6.1 `v128.load8_splat`.
/// LD1R has no register-offset addressing; the emit pass folds
/// `vm_base + ea` into Xn first via `ADD X16, X28, X16`.
/// Encoding base 0x4D40C000 (Q=1, size=00, opcode=110, R=0).
/// Verified via clang-as: `ld1r {v0.16b}, [x28]` → 0x4D40C380.
pub fn encLd1r16B(rt: Vn, rn: Xn) u32 {
    return 0x4D40C000 | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LD1R {Vt.8H}, [Xn]` — `v128.load16_splat` (size=01).
/// Base 0x4D40C400. Verified `ld1r {v0.8h}, [x28]` → 0x4D40C780.
pub fn encLd1r8H(rt: Vn, rn: Xn) u32 {
    return 0x4D40C400 | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LD1R {Vt.4S}, [Xn]` — `v128.load32_splat` (size=10).
/// Base 0x4D40C800. Verified `ld1r {v0.4s}, [x28]` → 0x4D40CB80.
pub fn encLd1r4S(rt: Vn, rn: Xn) u32 {
    return 0x4D40C800 | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `LD1R {Vt.2D}, [Xn]` — `v128.load64_splat` (size=11).
/// Base 0x4D40CC00. Verified `ld1r {v0.2d}, [x28]` → 0x4D40CF80.
pub fn encLd1r2D(rt: Vn, rn: Xn) u32 {
    return 0x4D40CC00 | (@as(u32, rn) << 5) | @as(u32, rt);
}

// =====================================================================
// Register-to-register moves
// =====================================================================

/// `ORR V<d>.16B, V<n>.16B, V<m>.16B` — bitwise OR vector.
/// Used as the canonical 128-bit register-to-register move
/// (`MOV V<d>.16B, V<n>.16B` is an alias for `ORR V<d>.16B,
/// V<n>.16B, V<n>.16B`).
///
/// Encoding (SIMD ORR vector, Q=1):
///   `0 1 0 01110 1 0 1 [Rm:5] 0 00111 [Rn:5] [Rd:5]`
///   = `0x4EA01C00` | (Rm << 16) | (Rn << 5) | Rd
///
/// Per Arm IHI 0055 §C7.2.246.
pub fn encOrrV16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA01C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MOV V<d>.16B, V<n>.16B` — alias for `ORR V<d>.16B, V<n>.
/// 16B, V<n>.16B`. Convenience helper for SIMD reg-to-reg
/// move; emit pass uses this when copying v128 vregs in
/// merges or function-result marshalling.
pub fn encMovV16B(rd: Vn, rn: Vn) u32 {
    return encOrrV16B(rd, rn, rn);
}

// =====================================================================
// Splat (broadcast scalar to all lanes)
// =====================================================================

/// `DUP V<d>.4S, W<n>` — broadcast 32-bit GPR value to all
/// four 32-bit lanes of V<d> (i32x4.splat).
///
/// Encoding (SIMD DUP element from GPR, Q=1, imm5=00100 for
/// 4S):
///   `0 1 0 01110 000 [imm5:5] 0 0001 1 [Rn:5] [Rd:5]`
///   imm5 = 0b00100 (4S shape) → bits[20:16] = 00100
///   = `0x4E040C00` | (Rn << 5) | Rd
///
/// Per Arm IHI 0055 §C7.2.106. 4S form: imm5=xx100 with
/// xx=00 (no element index since SIMD-from-GPR uses only
/// the size-encoding bits).
pub fn encDup4S(rd: Vn, rn: Xn) u32 {
    return 0x4E040C00 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `DUP V<d>.2D, X<n>` — broadcast a 64-bit GPR value to both
/// 64-bit lanes. v128 select uses this to widen
/// CSETM's all-ones / all-zeros result into a 16-byte mask
/// consumed by BSL.
///
/// Encoding (SIMD DUP element from GPR, Q=1, imm5=01000 for
/// 2D):
///   `0 1 0 01110 000 [imm5:5] 0 0001 1 [Rn:5] [Rd:5]`
///   imm5 = 0b01000 (2D shape) → bits[20:16] = 01000
///   = `0x4E080C00` | (Rn << 5) | Rd
///
/// Per Arm IHI 0055 §C7.2.106 (DUP general — element from GPR).
pub fn encDupGen2D(rd: Vn, rn: Xn) u32 {
    return 0x4E080C00 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `DUP V<d>.16B, W<n>` — broadcast 8-bit GPR value to all
/// sixteen lanes (i8x16.splat). imm5=00001. bits[11:10]=11
/// (DUP general from GPR). Constants verified via `clang
/// -arch arm64`. Per Arm IHI 0055 §C7.2.106.
pub fn encDup16B(rd: Vn, rn: Xn) u32 {
    return 0x4E010C00 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `DUP V<d>.8H, W<n>` — broadcast 16-bit GPR value to all
/// eight lanes (i16x8.splat). imm5=00010.
pub fn encDup8H(rd: Vn, rn: Xn) u32 {
    return 0x4E020C00 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `DUP V<d>.4S, V<n>.S[0]` — broadcast lane 0 of an FP/SIMD
/// register to all four 32-bit lanes (f32x4.splat). DUP element
/// form: bit[11]=0 vs 1 for the GPR-broadcast form above. imm5
/// selects the source-lane index (here 0). Per Arm IHI 0055
/// §C7.2.105.
pub fn encDup4SFromS0(rd: Vn, rn: Vn) u32 {
    return 0x4E040400 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `DUP V<d>.2D, V<n>.D[0]` — broadcast lane 0 of an FP/SIMD
/// register to both 64-bit lanes (f64x2.splat). Element form,
/// imm5=01000.
pub fn encDup2DFromD0(rd: Vn, rn: Vn) u32 {
    return 0x4E080400 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `AND V<d>.16B, V<n>.16B, V<m>.16B` — bitwise AND across the
/// full 128 bits. v128.and. Encoding (SIMD AND
/// vector, U=0, size=00):
///   `0 1 0 01110 00 1 [Rm:5] 0 0011 1 [Rn:5] [Rd:5]`
///   = `0x4E201C00 | (Rm << 16) | (Rn << 5) | Rd`.
/// Per Arm IHI 0055 §C7.2.6.
pub fn encAnd16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E201C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `BIC V<d>.16B, V<n>.16B, V<m>.16B` — bitwise AND-NOT
/// (`Vd = Vn AND NOT Vm`); maps directly to Wasm `v128.andnot`.
/// Encoding (U=0, size=01):
///   `0 1 0 01110 01 1 [Rm:5] 0 0011 1 [Rn:5] [Rd:5]`
///   = `0x4E601C00 | (Rm << 16) | (Rn << 5) | Rd`.
/// Per Arm IHI 0055 §C7.2.34.
pub fn encBic16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E601C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `EOR V<d>.16B, V<n>.16B, V<m>.16B` — bitwise XOR across the
/// full 128 bits. v128.xor. Encoding (U=1, size=00):
///   `0 1 1 01110 00 1 [Rm:5] 0 0011 1 [Rn:5] [Rd:5]`
///   = `0x6E201C00 | (Rm << 16) | (Rn << 5) | Rd`.
/// Per Arm IHI 0055 §C7.2.93.
pub fn encEor16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E201C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MVN V<d>.16B, V<n>.16B` (alias of `NOT V<d>.16B, V<n>.16B`)
/// — bitwise NOT. v128.not. Encoding (NOT vector,
/// U=1, size=00, opcode=00101):
///   `0 1 1 01110 00 1 00000 0 0101 10 [Rn:5] [Rd:5]`
///   = `0x6E205800 | (Rn << 5) | Rd`.
/// Per Arm IHI 0055 §C7.2.244.
pub fn encMvn16B(rd: Vn, rn: Vn) u32 {
    return 0x6E205800 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// Const-pool placeholder LDR + bitselect/not
// =====================================================================
// LDR (literal, SIMD&FP) Q-form.
// Wasm v128.const + i8x16.shuffle materialise their 16-byte immediates
// from a per-function const-pool (per ADR-0042). The placeholder LDR
// instruction is patched with the final imm19 (signed offset / 4
// bytes from PC of LDR to const-pool entry).
//
// Encoding (LDR literal, SIMD&FP, Q form):
//   `10 011 1 00 imm19 Rt`
// per Arm IHI 0055 §C7.2.198. Base = 0x9C000000 (Rt=0, imm19=0).
// imm19 range: ±2^18 × 4 = ±1 MiB — sufficient for a single-function
// const-pool placed immediately after the function body.

/// `LDR Q<rt>, <label>` — PC-relative literal load of 128-bit value.
/// `imm19` is the signed offset in 4-byte words from LDR to label.
/// Use `0` as a placeholder; fixup pass patches with the real offset.
pub fn encLdrLiteralQ(rt: Vn, imm19: i19) u32 {
    return 0x9C000000 | (@as(u32, @as(u19, @bitCast(imm19))) << 5) | @as(u32, rt);
}

/// Patch the imm19 field of a previously-emitted LDR-literal-Q
/// placeholder. Used by the fixup pass after the const-pool has
/// been appended to the JIT block.
pub fn patchLdrLiteralQImm19(word: u32, imm19: i19) u32 {
    // Clear bits 23:5 (imm19) then OR new value.
    return (word & ~@as(u32, 0x00FFFFE0)) | (@as(u32, @as(u19, @bitCast(imm19))) << 5);
}

/// `BSL V<d>.16B, V<n>.16B, V<m>.16B` — bitwise select using V<d>
/// as the mask. Element width is irrelevant since BSL is bitwise.
pub fn encBsl16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E601C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `NOT V<d>.16B, V<n>.16B` — bitwise not. Used for `ne` synthesis
/// (CMEQ → NOT). Encoding (two-register misc):
///   `0 Q 1 01110 0 0 1 0000 00101 10 Rn Rd`
/// Per Arm IHI 0055 §C7.2.225.
pub fn encNotV16B(rd: Vn, rn: Vn) u32 {
    return 0x6E205800 | (@as(u32, rn) << 5) | @as(u32, rd);
}
// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "encLdrQImm: V0, [X1, #0]" {
    // LDR Q0, [X1] = LDR Q0, [X1, #0]
    // 0x3DC00000 | (0 << 10) | (1 << 5) | 0 = 0x3DC00020
    try testing.expectEqual(@as(u32, 0x3DC00020), encLdrQImm(0, 1, 0));
}

test "encLdrQImm: V0, [X1, #16] (imm12=1)" {
    // imm12 = 16/16 = 1
    // 0x3DC00000 | (1 << 10) | (1 << 5) | 0 = 0x3DC00420
    try testing.expectEqual(@as(u32, 0x3DC00420), encLdrQImm(0, 1, 16));
}

test "encLdrQImm: V31, [X29, #16] (max V index, FP base)" {
    // imm12 = 1
    // 0x3DC00000 | (1 << 10) | (29 << 5) | 31
    //   = 0x3DC00000 | 0x400 | 0x3A0 | 0x1F = 0x3DC007BF
    try testing.expectEqual(@as(u32, 0x3DC007BF), encLdrQImm(31, 29, 16));
}

test "encStrQImm: V0, [X1, #0]" {
    // 0x3D800000 | (0 << 10) | (1 << 5) | 0 = 0x3D800020
    try testing.expectEqual(@as(u32, 0x3D800020), encStrQImm(0, 1, 0));
}

test "encStrQImm: V31, [X1, #(4095*16)]" {
    // imm12 = 4095 (max u12); byte_offset = 65520 (just under u16 max).
    const imm: u32 = 4095;
    const expected: u32 = 0x3D800000 | (imm << 10) | (1 << 5) | 31;
    try testing.expectEqual(expected, encStrQImm(31, 1, 65520));
}

test "encLdrQReg: Q0, [X28, X16] — `ldr q0, [x28, x16]` → 0x3CF06B80" {
    // Verified against `clang -arch arm64 -c` of the asm.
    try testing.expectEqual(@as(u32, 0x3CF06B80), encLdrQReg(0, 28, 16));
}

test "encLdrQReg: Q31, [X28, X16] — max Vt index" {
    // 0x3CE06800 | (16 << 16) | (28 << 5) | 31 = 0x3CF06B9F
    try testing.expectEqual(@as(u32, 0x3CF06B9F), encLdrQReg(31, 28, 16));
}

test "encStrQReg: Q0, [X28, X16] — `str q0, [x28, x16]` → 0x3CB06B80" {
    try testing.expectEqual(@as(u32, 0x3CB06B80), encStrQReg(0, 28, 16));
}

test "encStrQReg: Q31, [X29, X17] — `str q31, [x29, x17]` → 0x3CB16BBF" {
    try testing.expectEqual(@as(u32, 0x3CB16BBF), encStrQReg(31, 29, 17));
}

test "encLd1r16B: V0, [X28] — `ld1r {v0.16b}, [x28]` → 0x4D40C380" {
    try testing.expectEqual(@as(u32, 0x4D40C380), encLd1r16B(0, 28));
}

test "encLd1r8H: V0, [X28] → 0x4D40C780" {
    try testing.expectEqual(@as(u32, 0x4D40C780), encLd1r8H(0, 28));
}

test "encLd1r4S: V0, [X28] → 0x4D40CB80" {
    try testing.expectEqual(@as(u32, 0x4D40CB80), encLd1r4S(0, 28));
}

test "encLd1r2D: V0, [X28] → 0x4D40CF80" {
    try testing.expectEqual(@as(u32, 0x4D40CF80), encLd1r2D(0, 28));
}

test "encLd1r16B: V31, [X29] — `ld1r {v31.16b}, [x29]` → 0x4D40C3BF" {
    try testing.expectEqual(@as(u32, 0x4D40C3BF), encLd1r16B(31, 29));
}

test "encOrrV16B: V0, V1, V2" {
    // 0x4EA01C00 | (2 << 16) | (1 << 5) | 0 = 0x4EA21C20
    try testing.expectEqual(@as(u32, 0x4EA21C20), encOrrV16B(0, 1, 2));
}

test "encOrrV16B: V31, V31, V31 (max indices)" {
    // 0x4EA01C00 | (31 << 16) | (31 << 5) | 31 = 0x4EBF1FFF
    try testing.expectEqual(@as(u32, 0x4EBF1FFF), encOrrV16B(31, 31, 31));
}

test "encMovV16B: V0, V1 — alias of ORR Vd, Vn, Vn" {
    // Mov V0, V1 = ORR V0, V1, V1 = 0x4EA01C00 | (1<<16) | (1<<5) | 0 = 0x4EA11C20
    try testing.expectEqual(@as(u32, 0x4EA11C20), encMovV16B(0, 1));
    // Equivalent to encOrrV16B(0, 1, 1).
    try testing.expectEqual(encOrrV16B(0, 1, 1), encMovV16B(0, 1));
}

test "encDup16B/8H/4S element forms: V0, V1 across shapes" {
    // Verified via `clang -arch arm64`.
    try testing.expectEqual(@as(u32, 0x4E010C20), encDup16B(0, 1));
    try testing.expectEqual(@as(u32, 0x4E020C20), encDup8H(0, 1));
    try testing.expectEqual(@as(u32, 0x4E040420), encDup4SFromS0(0, 1));
    try testing.expectEqual(@as(u32, 0x4E080420), encDup2DFromD0(0, 1));
}

test "encDup4S: V0, W1 (i32x4.splat)" {
    // 0x4E040C00 | (1 << 5) | 0 = 0x4E040C20
    try testing.expectEqual(@as(u32, 0x4E040C20), encDup4S(0, 1));
}

test "encDup4S: V31, W30 (max indices)" {
    // 0x4E040C00 | (30 << 5) | 31 = 0x4E040FDF
    try testing.expectEqual(@as(u32, 0x4E040FDF), encDup4S(31, 30));
}

test "encDupGen2D: V0, X1 — `dup v0.2d, x1` → 0x4E080C20" {
    try testing.expectEqual(@as(u32, 0x4E080C20), encDupGen2D(0, 1));
}

test "encDupGen2D: V0, X0 — `dup v0.2d, x0` → 0x4E080C00" {
    try testing.expectEqual(@as(u32, 0x4E080C00), encDupGen2D(0, 0));
}

test "encDupGen2D: V31, X30 — `dup v31.2d, x30` → 0x4E080FDF" {
    try testing.expectEqual(@as(u32, 0x4E080FDF), encDupGen2D(31, 30));
}

test "encAnd16B: V0, V1, V2 — `and v0.16b, v1.16b, v2.16b` → 0x4E221C20" {
    try testing.expectEqual(@as(u32, 0x4E221C20), encAnd16B(0, 1, 2));
}

test "encBic16B: V0, V1, V2 — `bic v0.16b, v1.16b, v2.16b` → 0x4E621C20" {
    try testing.expectEqual(@as(u32, 0x4E621C20), encBic16B(0, 1, 2));
}

test "encEor16B: V0, V1, V2 — `eor v0.16b, v1.16b, v2.16b` → 0x6E221C20" {
    try testing.expectEqual(@as(u32, 0x6E221C20), encEor16B(0, 1, 2));
}

test "encMvn16B: V0, V1 — `mvn v0.16b, v1.16b` → 0x6E205820" {
    try testing.expectEqual(@as(u32, 0x6E205820), encMvn16B(0, 1));
}
test "encLdrQImm vs encStrQImm: distinct opcode bits" {
    // Sanity: load and store at same operands differ.
    try testing.expect(encLdrQImm(0, 1, 0) != encStrQImm(0, 1, 0));
}

test "encBsl16B: V0, V1, V2 (bitwise select)" {
    // 0x6E601C00 | (2 << 16) | (1 << 5) | 0 = 0x6E621C20
    try testing.expectEqual(@as(u32, 0x6E621C20), encBsl16B(0, 1, 2));
}

test "encBsl16B: V31, V30, V29 (high indices)" {
    // 0x6E601C00 | (29 << 16) | (30 << 5) | 31 = 0x6E7D1FDF
    try testing.expectEqual(@as(u32, 0x6E7D1FDF), encBsl16B(31, 30, 29));
}
test "encNotV16B: V0, V1" {
    // 0x6E205800 | (1 << 5) | 0 = 0x6E205820
    try testing.expectEqual(@as(u32, 0x6E205820), encNotV16B(0, 1));
}
// ============================================================
// LDR (literal, SIMD&FP) Q-form
// ============================================================

test "encLdrLiteralQ: Q0, imm19=0 (base)" {
    // 0x9C000000 | (0 << 5) | 0 = 0x9C000000
    try testing.expectEqual(@as(u32, 0x9C000000), encLdrLiteralQ(0, 0));
}

test "encLdrLiteralQ: Q31, imm19=8 (fwd 32 bytes)" {
    // 0x9C000000 | (8 << 5) | 31 = 0x9C00011F
    try testing.expectEqual(@as(u32, 0x9C00011F), encLdrLiteralQ(31, 8));
}

test "encLdrLiteralQ: imm19=-1 (back 4 bytes; sign-extended)" {
    // imm19 = -1 = 0x7FFFF (19-bit sign-extended).
    // 0x9C000000 | (0x7FFFF << 5) | 0 = 0x9CFFFFE0
    try testing.expectEqual(@as(u32, 0x9CFFFFE0), encLdrLiteralQ(0, -1));
}

test "LDR (literal) places imm19's two extremes in bits 23..5" {
    try testing.expectEqual(@as(u32, 0x9C000000 | (0x3FFFF << 5)), encLdrLiteralQ(0, std.math.maxInt(i19)));
    try testing.expectEqual(@as(u32, 0x9C000000 | (0x40000 << 5)), encLdrLiteralQ(0, std.math.minInt(i19)));
    try testing.expectEqual(@as(u32, 0x9C000000 | (0x3FFFF << 5) | 7), patchLdrLiteralQImm19(encLdrLiteralQ(7, 0), std.math.maxInt(i19)));
    try testing.expectEqual(@as(u32, 0x9C000000 | (0x40000 << 5) | 7), patchLdrLiteralQImm19(encLdrLiteralQ(7, 0), std.math.minInt(i19)));
}

test "patchLdrLiteralQImm19: replaces imm19 field" {
    const orig = encLdrLiteralQ(5, 0);
    const patched = patchLdrLiteralQImm19(orig, 100);
    // Patched word should equal direct emit with the same imm19 + Rt.
    try testing.expectEqual(encLdrLiteralQ(5, 100), patched);
}
