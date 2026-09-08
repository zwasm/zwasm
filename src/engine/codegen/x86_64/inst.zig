// FILE-SIZE-EXEMPT: uniform pure-encoder catalog (SysV/Win64 x86_64 ISA encoders); P2 pure-data dominance (per ADR-0099)
//! x86_64 instruction encoder.
//!
//! Mirrors the role of `arm64/inst.zig` but x86_64 instructions
//! are variable-width (1–15 bytes) so encoder fns return an
//! `EncodedInsn` value (max-sized stack buffer + length) instead
//! of a fixed `u32`. The caller writes `enc.slice()` to its
//! `*std.ArrayList(u8)` buffer — same "pure encoder + caller-
//! owned buffer" shape as arm64, just with a slice instead of a
//! u32 word.
//!
//! This file is the orchestrator: it owns the public types
//! (`Gpr`, `Xmm`, `Width`, `Cond`, `ShiftKind`, `EncodedInsn`,
//! `SseScalarKind`, `SsePackedKind`, `max_insn_bytes`) and the
//! shared prefix / ModR/M / SIB byte builders, then re-exports
//! every `enc*` function from the per-family sibling modules
//! grouped by Intel SDM ISA family:
//!
//!   - `inst_alu.zig`    — ALU register/immediate (§3.4 / §3.5).
//!   - `inst_mem.zig`    — Memory load/store + sign/zero extension.
//!   - `inst_branch.zig` — Control flow + stack + integer divide.
//!   - `inst_sse.zig`    — XMM scalar/packed + FP-related.
//!
//! Bit patterns from AMD64 Architecture Programmer's Manual
//! Vol. 3 (Pub. 24594) and Intel® 64 Vol. 2 (Order 325383).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const std = @import("std");

const reg_class = @import("reg_class.zig");

const inst_alu = @import("inst_alu.zig");
const inst_mem = @import("inst_mem.zig");
const inst_branch = @import("inst_branch.zig");
const inst_sse = @import("inst_sse.zig");
const inst_sse_packed = @import("inst_sse_packed.zig");
const inst_sse_scalar = @import("inst_sse_scalar.zig");

pub const Gpr = reg_class.Gpr;
pub const Xmm = reg_class.Xmm;
pub const Width = reg_class.Width;

/// Maximum encoded length of a single x86_64 instruction. Per
/// the AMD64 manual §1.2.5 a single instruction is bounded at
/// 15 bytes (legacy + REX + opcode + ModR/M + SIB + disp +
/// immediate). The foundation ops in this chunk top out at 4
/// bytes (REX + opcode + ModR/M); the bound is stated for the
/// later chunks that add immediates and SIB.
pub const max_insn_bytes: u8 = 15;

/// One encoded instruction. Caller appends `slice()` to its
/// output buffer:
///
///   const enc = inst.encMovRR(.q, .rax, .rcx);
///   try buf.appendSlice(allocator, enc.slice());
///
/// Stack-allocated; no allocation needed.
pub const EncodedInsn = struct {
    bytes: [max_insn_bytes]u8 = @splat(0),
    len: u8 = 0,

    pub fn slice(self: *const EncodedInsn) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn push(self: *EncodedInsn, b: u8) void {
        self.bytes[self.len] = b;
        self.len += 1;
    }
};

// ============================================================
// Prefix / ModR/M / SIB byte builders (shared with sibling
// modules; pub-visible so inst_alu / inst_mem / inst_branch /
// inst_sse can compose them without duplicating logic).
// ============================================================

/// Encode the REX prefix byte. The four payload bits:
///   - W (bit 3): operand size — 1 = 64-bit, 0 = default.
///   - R (bit 2): high-bit extension of ModR/M.reg.
///   - X (bit 1): high-bit extension of SIB.index.
///   - B (bit 0): high-bit extension of ModR/M.rm OR SIB.base
///                OR opcode-embedded reg.
/// The fixed top half is `0100` per AMD64 Vol.3 §1.2.7.
pub inline fn encodeRex(w: bool, r: u1, x: u1, b: u1) u8 {
    return 0x40 |
        (@as(u8, @intFromBool(w)) << 3) |
        (@as(u8, r) << 2) |
        (@as(u8, x) << 1) |
        @as(u8, b);
}

/// Encode the ModR/M byte. `mod` selects addressing mode (3 =
/// register-direct, 0/1/2 = memory with 0/8/32-bit disp), `reg`
/// is the low 3 bits of the source/extension reg, `rm` is the
/// low 3 bits of the destination/base.
pub inline fn encodeModrm(mod: u2, reg: u3, rm: u3) u8 {
    return (@as(u8, mod) << 6) | (@as(u8, reg) << 3) | @as(u8, rm);
}

/// Encode the SIB byte. `scale` is 0/1/2/3 (1/2/4/8x), `index`
/// is the low 3 bits of the index reg, `base` is the low 3 bits
/// of the base reg. Only used when ModR/M.rm == 0b100 in memory
/// addressing modes.
pub inline fn encodeSib(scale: u2, index: u3, base: u3) u8 {
    return (@as(u8, scale) << 6) | (@as(u8, index) << 3) | @as(u8, base);
}

/// Decide whether REX must be emitted for a 2-operand reg/reg
/// instruction, given the operand size. REX.W is set for 64-bit;
/// REX.R / REX.B are set when reg / rm are R8..R15.
///
/// For 32-bit ops we only emit REX when at least one extension
/// bit (R or B) is set — the 32-bit encoding is the default and
/// the prefix is otherwise redundant. For 64-bit ops REX is
/// always emitted (to set the W bit).
pub inline fn rexForRR(size: Width, reg: Gpr, rm: Gpr) ?u8 {
    const w = size == .q;
    const r = reg.extBit();
    const b = rm.extBit();
    if (!w and r == 0 and b == 0) return null;
    return encodeRex(w, r, 0, b);
}

// ============================================================
// Shared enums
// ============================================================

/// EFLAGS condition code per AMD64 Vol.3 §3.1.4 (J<cc> /
/// SET<cc> / CMOV<cc> share the same 4-bit cc field). The
/// numeric value is the cc encoding (e.g. SETE = 0x0F 0x94 →
/// 0x90 + 4).
pub const Cond = enum(u4) {
    o = 0x0,
    no = 0x1,
    b = 0x2,
    ae = 0x3,
    e = 0x4,
    ne = 0x5,
    be = 0x6,
    a = 0x7,
    s = 0x8,
    ns = 0x9,
    p = 0xA,
    np = 0xB,
    l = 0xC,
    ge = 0xD,
    le = 0xE,
    g = 0xF,
};

/// Shift / rotate variants for the 0xD3 r/m, CL family. The
/// numeric value matches the ModR/M.reg field. AMD64 Vol.3
/// Table 4.5: `D3 /4` SHL, `/5` SHR, `/7` SAR, `/0` ROL, `/1`
/// ROR. Wasm doesn't use the carry-rotate (RCL/RCR = /2 //3) or
/// the SAL alias (= SHL = /6).
pub const ShiftKind = enum(u3) {
    rol = 0,
    ror = 1,
    shl = 4,
    shr = 5,
    sar = 7,
};

/// Mandatory prefix for SSE scalar ops. F3 = single-precision
/// (operates on the low 32 bits of XMM = f32). F2 = double-
/// precision (operates on the low 64 bits = f64).
pub const SseScalarKind = enum(u8) {
    f32 = 0xF3,
    f64 = 0xF2,
};

/// SSE packed bitwise op kind. f32 = no prefix (operates on
/// single-precision-aligned packed lanes); f64 = 0x66 prefix
/// (double-precision lanes). For abs/neg in scalar contexts
/// the choice only affects the prefix byte; all 128 bits are
/// AND/XOR'd identically.
pub const SsePackedKind = enum(u8) {
    f32 = 0,
    f64 = 0x66,
};

// ============================================================
// ALU re-exports (inst_alu.zig)
// ============================================================

pub const encMovRR = inst_alu.encMovRR;
pub const encAddRR = inst_alu.encAddRR;
pub const encSubRR = inst_alu.encSubRR;
// Wasm wide-arithmetic (ADR-0168 v0.2).
pub const encAdcRR = inst_alu.encAdcRR;
pub const encSbbRR = inst_alu.encSbbRR;
pub const encMul1 = inst_alu.encMul1;
pub const encImul1 = inst_alu.encImul1;
pub const encAndRR = inst_alu.encAndRR;
pub const encOrRR = inst_alu.encOrRR;
pub const encXorRR = inst_alu.encXorRR;
pub const encCmpRR = inst_alu.encCmpRR;
pub const encShiftRCl = inst_alu.encShiftRCl;
pub const encTestRR = inst_alu.encTestRR;
pub const encCmpRImm32 = inst_alu.encCmpRImm32;
pub const encTestRImm32 = inst_alu.encTestRImm32;
pub const encCmpRImm8 = inst_alu.encCmpRImm8;
pub const encImulRR = inst_alu.encImulRR;
pub const encAddR64Imm32 = inst_alu.encAddR64Imm32;
pub const encSubRSpImm8 = inst_alu.encSubRSpImm8;
pub const encSubMem64Disp32Imm8 = inst_alu.encSubMem64Disp32Imm8;
pub const encAddRSpImm8 = inst_alu.encAddRSpImm8;
pub const encSubRSpImm32 = inst_alu.encSubRSpImm32;
pub const encAddRSpImm32 = inst_alu.encAddRSpImm32;
pub const encMovImm64Q = inst_alu.encMovImm64Q;
pub const encShrRImm8 = inst_alu.encShrRImm8;
pub const encShlRImm8 = inst_alu.encShlRImm8;
pub const encSarRImm8 = inst_alu.encSarRImm8;
pub const encAndRImm8 = inst_alu.encAndRImm8;
pub const encOrRImm8 = inst_alu.encOrRImm8;
pub const encMovImm32W = inst_alu.encMovImm32W;

// ============================================================
// Memory re-exports (inst_mem.zig)
// ============================================================

pub const encMovzxR32R8 = inst_mem.encMovzxR32R8;
pub const encMovzxR32R16 = inst_mem.encMovzxR32R16;
pub const encMovR32FromBaseIdxLsl2 = inst_mem.encMovR32FromBaseIdxLsl2;
pub const encMovR64FromBaseIdxLsl3 = inst_mem.encMovR64FromBaseIdxLsl3;
pub const encMovsxdR64R32 = inst_mem.encMovsxdR64R32;
pub const encMovsxR32R8 = inst_mem.encMovsxR32R8;
pub const encMovsxR32R16 = inst_mem.encMovsxR32R16;
pub const encMovsxR64R8 = inst_mem.encMovsxR64R8;
pub const encMovsxR64R16 = inst_mem.encMovsxR64R16;
pub const encMovR64FromMemDisp32 = inst_mem.encMovR64FromMemDisp32;
pub const encMovR32FromMemDisp32 = inst_mem.encMovR32FromMemDisp32;
pub const encStoreR32MemDisp32 = inst_mem.encStoreR32MemDisp32;
pub const encStoreR64MemDisp32 = inst_mem.encStoreR64MemDisp32;
pub const encMovMemDisp32Imm32 = inst_mem.encMovMemDisp32Imm32;
pub const encCmpR64MemDisp32 = inst_mem.encCmpR64MemDisp32;
pub const encMovR32FromBaseIdx = inst_mem.encMovR32FromBaseIdx;
pub const encStoreR32MemBaseIdx = inst_mem.encStoreR32MemBaseIdx;
pub const encStoreR16MemBaseIdx = inst_mem.encStoreR16MemBaseIdx;
pub const encStoreR8MemBaseIdx = inst_mem.encStoreR8MemBaseIdx;
pub const encMovzxR32_8MemBaseIdx = inst_mem.encMovzxR32_8MemBaseIdx;
pub const encMovsxR32_8MemBaseIdx = inst_mem.encMovsxR32_8MemBaseIdx;
pub const encMovzxR32_16MemBaseIdx = inst_mem.encMovzxR32_16MemBaseIdx;
pub const encMovsxR32_16MemBaseIdx = inst_mem.encMovsxR32_16MemBaseIdx;
pub const encMovR64FromBaseIdx = inst_mem.encMovR64FromBaseIdx;
pub const encStoreR64MemBaseIdx = inst_mem.encStoreR64MemBaseIdx;
pub const encStoreR64MemBaseIdxLsl3 = inst_mem.encStoreR64MemBaseIdxLsl3;
pub const encMovzxR64_8MemBaseIdx = inst_mem.encMovzxR64_8MemBaseIdx;
pub const encMovsxR64_8MemBaseIdx = inst_mem.encMovsxR64_8MemBaseIdx;
pub const encMovzxR64_16MemBaseIdx = inst_mem.encMovzxR64_16MemBaseIdx;
pub const encMovsxR64_16MemBaseIdx = inst_mem.encMovsxR64_16MemBaseIdx;
pub const encMovsxdR64_32MemBaseIdx = inst_mem.encMovsxdR64_32MemBaseIdx;
pub const encLeaR64BaseDisp8 = inst_mem.encLeaR64BaseDisp8;
pub const encLeaR64BaseDisp32 = inst_mem.encLeaR64BaseDisp32;
pub const encLeaR64BaseRspDisp32 = inst_mem.encLeaR64BaseRspDisp32;
pub const encStoreImm32MemDisp32 = inst_mem.encStoreImm32MemDisp32;
pub const encStoreImm8MemBaseDisp32 = inst_mem.encStoreImm8MemBaseDisp32;
pub const encStoreR32MemRBP = inst_mem.encStoreR32MemRBP;
pub const encLoadR32MemRBP = inst_mem.encLoadR32MemRBP;
pub const encStoreR64MemRBP = inst_mem.encStoreR64MemRBP;
pub const encLoadR64MemRBP = inst_mem.encLoadR64MemRBP;
pub const encStoreR32MemRBPDisp32 = inst_mem.encStoreR32MemRBPDisp32;
pub const encLoadR32MemRBPDisp32 = inst_mem.encLoadR32MemRBPDisp32;
pub const encStoreR64MemRBPDisp32 = inst_mem.encStoreR64MemRBPDisp32;
pub const encLoadR64MemRBPDisp32 = inst_mem.encLoadR64MemRBPDisp32;
pub const encStoreR32MemRSPDisp32 = inst_mem.encStoreR32MemRSPDisp32;
pub const encStoreR64MemRSPDisp32 = inst_mem.encStoreR64MemRSPDisp32;

// ============================================================
// Branch re-exports (inst_branch.zig)
// ============================================================

pub const encSetccR = inst_branch.encSetccR;
pub const encCmovccRR = inst_branch.encCmovccRR;
pub const encCallRel32 = inst_branch.encCallRel32;
pub const encCallReg = inst_branch.encCallReg;
pub const encJccRel8 = inst_branch.encJccRel8;
pub const encJmpReg = inst_branch.encJmpReg;
pub const encJmpRel32 = inst_branch.encJmpRel32;
pub const encJccRel32 = inst_branch.encJccRel32;
pub const patchRel32 = inst_branch.patchRel32;
pub const encRet = inst_branch.encRet;
pub const encNop = inst_branch.encNop;
pub const encPushR = inst_branch.encPushR;
pub const encPushMem64 = inst_branch.encPushMem64;
pub const encPopR = inst_branch.encPopR;
pub const encCdq = inst_branch.encCdq;
pub const encCqo = inst_branch.encCqo;
pub const encIdivR32 = inst_branch.encIdivR32;
pub const encDivR32 = inst_branch.encDivR32;
pub const encIdivR64 = inst_branch.encIdivR64;
pub const encDivR64 = inst_branch.encDivR64;
pub const encLzcntR32 = inst_branch.encLzcntR32;
pub const encTzcntR32 = inst_branch.encTzcntR32;
pub const encPopcntR32 = inst_branch.encPopcntR32;
pub const encLzcntR64 = inst_branch.encLzcntR64;
pub const encTzcntR64 = inst_branch.encTzcntR64;
pub const encPopcntR64 = inst_branch.encPopcntR64;

// ============================================================
// SSE re-exports (inst_sse.zig + inst_sse_packed.zig +
// inst_sse_scalar.zig per ADR-0041)
// ============================================================

// -- Foundation (inst_sse.zig) — mem load/store XMM + MOV reg
//    forms + scalar CVT helpers + RIP-rel placeholder.
pub const encStoreXmmF32MemRBP = inst_sse.encStoreXmmF32MemRBP;
pub const encLoadXmmF32MemRBP = inst_sse.encLoadXmmF32MemRBP;
pub const encStoreXmmF64MemRBP = inst_sse.encStoreXmmF64MemRBP;
pub const encLoadXmmF64MemRBP = inst_sse.encLoadXmmF64MemRBP;
pub const encStoreXmmF32MemRBPDisp32 = inst_sse.encStoreXmmF32MemRBPDisp32;
pub const encLoadXmmF32MemRBPDisp32 = inst_sse.encLoadXmmF32MemRBPDisp32;
pub const encStoreXmmF64MemRBPDisp32 = inst_sse.encStoreXmmF64MemRBPDisp32;
pub const encLoadXmmF64MemRBPDisp32 = inst_sse.encLoadXmmF64MemRBPDisp32;
pub const encStoreXmmV128MemRBP = inst_sse.encStoreXmmV128MemRBP;
pub const encLoadXmmV128MemRBP = inst_sse.encLoadXmmV128MemRBP;
pub const encStoreXmmV128MemRBPDisp32 = inst_sse.encStoreXmmV128MemRBPDisp32;
pub const encLoadXmmV128MemRBPDisp32 = inst_sse.encLoadXmmV128MemRBPDisp32;
pub const encStoreXmmF32MemRSPDisp32 = inst_sse.encStoreXmmF32MemRSPDisp32;
pub const encStoreXmmF64MemRSPDisp32 = inst_sse.encStoreXmmF64MemRSPDisp32;
pub const encStoreXmmV128MemRSPDisp32 = inst_sse.encStoreXmmV128MemRSPDisp32;
pub const encMovdXmmFromR32 = inst_sse.encMovdXmmFromR32;
pub const encMovqXmmFromR64 = inst_sse.encMovqXmmFromR64;
pub const encMovapsXmmXmm = inst_sse.encMovapsXmmXmm;
pub const encMovssMovsdMemBaseIdx = inst_sse.encMovssMovsdMemBaseIdx;
pub const encMovssMovsdXmmMemBaseDisp32 = inst_sse.encMovssMovsdXmmMemBaseDisp32;
pub const encMovupsMemBaseIdx = inst_sse.encMovupsMemBaseIdx;
pub const encMovupsXmmMemBaseDisp32 = inst_sse.encMovupsXmmMemBaseDisp32;
pub const encCvttScalar2Int = inst_sse.encCvttScalar2Int;
pub const encCvtsi2Scalar = inst_sse.encCvtsi2Scalar;
pub const encMovdR32FromXmm = inst_sse.encMovdR32FromXmm;
pub const encMovqR64FromXmm = inst_sse.encMovqR64FromXmm;
pub const encMovsdXmmXmm = inst_sse.encMovsdXmmXmm;
pub const encMovlhps = inst_sse.encMovlhps;
pub const encMovupsXmmRipRelPlaceholder = inst_sse.encMovupsXmmRipRelPlaceholder;
pub const patchRipRelDisp32 = inst_sse.patchRipRelDisp32;

// -- Scalar / FP-packed (inst_sse_scalar.zig).
pub const encSseScalarBinary = inst_sse_scalar.encSseScalarBinary;
pub const encSsePackedBinary = inst_sse_scalar.encSsePackedBinary;
pub const encRoundss = inst_sse_scalar.encRoundss;
pub const encRoundsd = inst_sse_scalar.encRoundsd;
pub const encUcomiss = inst_sse_scalar.encUcomiss;
pub const encUcomisd = inst_sse_scalar.encUcomisd;
pub const encOrps = inst_sse_scalar.encOrps;
pub const encOrpd = inst_sse_scalar.encOrpd;
pub const encXorps = inst_sse_scalar.encXorps;
pub const encXorpd = inst_sse_scalar.encXorpd;
pub const encAndps = inst_sse_scalar.encAndps;
pub const encAndpd = inst_sse_scalar.encAndpd;
pub const encAndnps = inst_sse_scalar.encAndnps;
pub const encAndnpd = inst_sse_scalar.encAndnpd;
pub const encAddps = inst_sse_scalar.encAddps;
pub const encSubps = inst_sse_scalar.encSubps;
pub const encMulps = inst_sse_scalar.encMulps;
pub const encDivps = inst_sse_scalar.encDivps;
pub const encSqrtps = inst_sse_scalar.encSqrtps;
pub const encMinps = inst_sse_scalar.encMinps;
pub const encMaxps = inst_sse_scalar.encMaxps;
pub const encAddpd = inst_sse_scalar.encAddpd;
pub const encSubpd = inst_sse_scalar.encSubpd;
pub const encMulpd = inst_sse_scalar.encMulpd;
pub const encDivpd = inst_sse_scalar.encDivpd;
pub const encSqrtpd = inst_sse_scalar.encSqrtpd;
pub const encMinpd = inst_sse_scalar.encMinpd;
pub const encMaxpd = inst_sse_scalar.encMaxpd;
pub const encCmpps = inst_sse_scalar.encCmpps;
pub const encCmppd = inst_sse_scalar.encCmppd;
pub const encRoundps = inst_sse_scalar.encRoundps;
pub const encRoundpd = inst_sse_scalar.encRoundpd;
pub const encCvtdq2ps = inst_sse_scalar.encCvtdq2ps;
pub const encCvtps2pd = inst_sse_scalar.encCvtps2pd;
pub const encCvtpd2ps = inst_sse_scalar.encCvtpd2ps;
pub const encCvtdq2pd = inst_sse_scalar.encCvtdq2pd;
pub const encCvttps2dq = inst_sse_scalar.encCvttps2dq;
pub const encCvttpd2dq = inst_sse_scalar.encCvttpd2dq;
pub const encShufps = inst_sse_scalar.encShufps;
pub const encUnpcklps = inst_sse_scalar.encUnpcklps;
pub const encInsertps = inst_sse_scalar.encInsertps;

// -- Packed integer (inst_sse_packed.zig).
pub const encPaddB = inst_sse_packed.encPaddB;
pub const encPaddW = inst_sse_packed.encPaddW;
pub const encPaddD = inst_sse_packed.encPaddD;
pub const encPaddQ = inst_sse_packed.encPaddQ;
pub const encPsubB = inst_sse_packed.encPsubB;
pub const encPsubW = inst_sse_packed.encPsubW;
pub const encPsubD = inst_sse_packed.encPsubD;
pub const encPsubQ = inst_sse_packed.encPsubQ;
pub const encPmullW = inst_sse_packed.encPmullW;
pub const encPmullD = inst_sse_packed.encPmullD;
pub const encPmuludq = inst_sse_packed.encPmuludq;
pub const encPmuldq = inst_sse_packed.encPmuldq;
pub const encPslldImm = inst_sse_packed.encPslldImm;
pub const encPsllwImm = inst_sse_packed.encPsllwImm;
pub const encPsrlwImm = inst_sse_packed.encPsrlwImm;
pub const encPsrldImm = inst_sse_packed.encPsrldImm;
pub const encPsrlqImm = inst_sse_packed.encPsrlqImm;
pub const encPsllqImm = inst_sse_packed.encPsllqImm;
pub const encPsradImm = inst_sse_packed.encPsradImm;
pub const encPsllwReg = inst_sse_packed.encPsllwReg;
pub const encPslldReg = inst_sse_packed.encPslldReg;
pub const encPsllqReg = inst_sse_packed.encPsllqReg;
pub const encPsrlwReg = inst_sse_packed.encPsrlwReg;
pub const encPsrldReg = inst_sse_packed.encPsrldReg;
pub const encPsrlqReg = inst_sse_packed.encPsrlqReg;
pub const encPsrawReg = inst_sse_packed.encPsrawReg;
pub const encPsradReg = inst_sse_packed.encPsradReg;
pub const encPsubq = inst_sse_packed.encPsubq;
pub const encPxor = inst_sse_packed.encPxor;
pub const encPand = inst_sse_packed.encPand;
pub const encPor = inst_sse_packed.encPor;
pub const encPandn = inst_sse_packed.encPandn;
pub const encPtest = inst_sse_packed.encPtest;
pub const encPcmpeqB = inst_sse_packed.encPcmpeqB;
pub const encPcmpeqW = inst_sse_packed.encPcmpeqW;
pub const encPcmpeqD = inst_sse_packed.encPcmpeqD;
pub const encPcmpeqQ = inst_sse_packed.encPcmpeqQ;
pub const encPcmpgtB = inst_sse_packed.encPcmpgtB;
pub const encPcmpgtW = inst_sse_packed.encPcmpgtW;
pub const encPcmpgtD = inst_sse_packed.encPcmpgtD;
pub const encPcmpgtQ = inst_sse_packed.encPcmpgtQ;
pub const encPshufd = inst_sse_packed.encPshufd;
pub const encPshufb = inst_sse_packed.encPshufb;
pub const encPshuflw = inst_sse_packed.encPshuflw;
pub const encPunpcklqdq = inst_sse_packed.encPunpcklqdq;
pub const encPunpcklbw = inst_sse_packed.encPunpcklbw;
pub const encPunpckhbw = inst_sse_packed.encPunpckhbw;
pub const encPacksswb = inst_sse_packed.encPacksswb;
pub const encPackssdw = inst_sse_packed.encPackssdw;
pub const encPackuswb = inst_sse_packed.encPackuswb;
pub const encPackusdw = inst_sse_packed.encPackusdw;
pub const encPextrD = inst_sse_packed.encPextrD;
pub const encPextrQ = inst_sse_packed.encPextrQ;
pub const encPinsrD = inst_sse_packed.encPinsrD;
pub const encPinsrQ = inst_sse_packed.encPinsrQ;
pub const encPextrB = inst_sse_packed.encPextrB;
pub const encPextrW = inst_sse_packed.encPextrW;
pub const encPinsrB = inst_sse_packed.encPinsrB;
pub const encPinsrW = inst_sse_packed.encPinsrW;
pub const encPabsb = inst_sse_packed.encPabsb;
pub const encPabsw = inst_sse_packed.encPabsw;
pub const encPabsd = inst_sse_packed.encPabsd;
pub const encPmovsxbw = inst_sse_packed.encPmovsxbw;
pub const encPmovsxwd = inst_sse_packed.encPmovsxwd;
pub const encPmovsxdq = inst_sse_packed.encPmovsxdq;
pub const encPmovzxbw = inst_sse_packed.encPmovzxbw;
pub const encPmovzxwd = inst_sse_packed.encPmovzxwd;
pub const encPmovzxdq = inst_sse_packed.encPmovzxdq;
pub const encPmaddubsw = inst_sse_packed.encPmaddubsw;
pub const encPmulhrsw = inst_sse_packed.encPmulhrsw;
pub const encPmaddwd = inst_sse_packed.encPmaddwd;
pub const encPmaxub = inst_sse_packed.encPmaxub;
pub const encPminub = inst_sse_packed.encPminub;
pub const encPmaxuw = inst_sse_packed.encPmaxuw;
pub const encPminuw = inst_sse_packed.encPminuw;
pub const encPmaxud = inst_sse_packed.encPmaxud;
pub const encPminud = inst_sse_packed.encPminud;
pub const encPmaxsd = inst_sse_packed.encPmaxsd;
pub const encPminsb = inst_sse_packed.encPminsb;
pub const encPmaxsb = inst_sse_packed.encPmaxsb;
pub const encPminsw = inst_sse_packed.encPminsw;
pub const encPmaxsw = inst_sse_packed.encPmaxsw;
pub const encPminsd = inst_sse_packed.encPminsd;
pub const encPaddsb = inst_sse_packed.encPaddsb;
pub const encPaddsw = inst_sse_packed.encPaddsw;
pub const encPsubsb = inst_sse_packed.encPsubsb;
pub const encPsubsw = inst_sse_packed.encPsubsw;
pub const encPaddusb = inst_sse_packed.encPaddusb;
pub const encPaddusw = inst_sse_packed.encPaddusw;
pub const encPsubusb = inst_sse_packed.encPsubusb;
pub const encPsubusw = inst_sse_packed.encPsubusw;
pub const encPavgb = inst_sse_packed.encPavgb;
pub const encPavgw = inst_sse_packed.encPavgw;
pub const encMovmskps = inst_sse_packed.encMovmskps;
pub const encMovmskpd = inst_sse_packed.encMovmskpd;
pub const encPmovmskb = inst_sse_packed.encPmovmskb;

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "encodeRex: bit positions" {
    // W=1, R=0, X=0, B=0 → 0x48 (canonical 64-bit operand prefix)
    try testing.expectEqual(@as(u8, 0x48), encodeRex(true, 0, 0, 0));
    // W=0 default → 0x40
    try testing.expectEqual(@as(u8, 0x40), encodeRex(false, 0, 0, 0));
    // W=1, R=1, B=1 → 0x4D (used for mov r9, r8 etc.)
    try testing.expectEqual(@as(u8, 0x4D), encodeRex(true, 1, 0, 1));
    // W=0, B=1 → 0x41 (32-bit access into R8..R15)
    try testing.expectEqual(@as(u8, 0x41), encodeRex(false, 0, 0, 1));
}

test "encodeModrm: register-direct mode" {
    // mod=11, reg=001 (rcx), rm=000 (rax) → 0xc8 (the canonical
    // mov rax, rcx ModR/M byte).
    try testing.expectEqual(@as(u8, 0xC8), encodeModrm(0b11, 1, 0));
    // mod=00, reg=000, rm=000 → 0x00 ([rax])
    try testing.expectEqual(@as(u8, 0x00), encodeModrm(0b00, 0, 0));
}

test "encodeSib: scale + index + base" {
    // scale=2 (×4), index=001 (rcx), base=000 (rax) → 0x88
    try testing.expectEqual(@as(u8, 0x88), encodeSib(0b10, 1, 0));
}

test "encMovRR: mov rax, rcx (q) → 48 89 c8" {
    const enc = encMovRR(.q, .rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xC8 }, enc.slice());
}

test "encMovRR: mov eax, ecx (d) → 89 c8 (no REX)" {
    const enc = encMovRR(.d, .rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x89, 0xC8 }, enc.slice());
}

test "encMovRR: mov r8, rcx (q) → 49 89 c8 (REX.W + REX.B)" {
    const enc = encMovRR(.q, .r8, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x89, 0xC8 }, enc.slice());
}

test "encMovRR: mov rax, r9 (q) → 4c 89 c8 (REX.W + REX.R)" {
    const enc = encMovRR(.q, .rax, .r9);
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x89, 0xC8 }, enc.slice());
}

test "encMovRR: mov r9d, r8d (d) → 45 89 c1 (REX.R + REX.B, no W)" {
    const enc = encMovRR(.d, .r9, .r8);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x89, 0xC1 }, enc.slice());
}

test "encAddRR: add rax, rcx (q) → 48 01 c8" {
    const enc = encAddRR(.q, .rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x01, 0xC8 }, enc.slice());
}

test "encSubRR: sub rax, rcx (q) → 48 29 c8" {
    const enc = encSubRR(.q, .rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x29, 0xC8 }, enc.slice());
}

test "encRet: single 0xC3" {
    const enc = encRet();
    try testing.expectEqualSlices(u8, &.{0xC3}, enc.slice());
}

test "encNop: single 0x90" {
    const enc = encNop();
    try testing.expectEqualSlices(u8, &.{0x90}, enc.slice());
}

test "EncodedInsn: max len bound" {
    try testing.expectEqual(@as(u8, 15), max_insn_bytes);
}

test "encPushR: push rbp → 55" {
    const enc = encPushR(.rbp);
    try testing.expectEqualSlices(u8, &.{0x55}, enc.slice());
}

test "encPushR: push r12 → 41 54 (REX.B)" {
    const enc = encPushR(.r12);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x54 }, enc.slice());
}

test "encPushMem64: push qword [r10] → 41 ff 32 (REX.B, /6); [rax] → ff 30" {
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0xFF, 0x32 }, encPushMem64(.r10).slice());
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x30 }, encPushMem64(.rax).slice());
}

test "encPopR: pop rbp → 5d" {
    const enc = encPopR(.rbp);
    try testing.expectEqualSlices(u8, &.{0x5D}, enc.slice());
}

test "encPopR: pop r12 → 41 5c (REX.B)" {
    const enc = encPopR(.r12);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x5C }, enc.slice());
}

test "encMovImm32W: mov eax, #42 → b8 2a 00 00 00" {
    const enc = encMovImm32W(.rax, 42);
    try testing.expectEqualSlices(u8, &.{ 0xB8, 0x2A, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encMovImm32W: mov r10d, #42 → 41 ba 2a 00 00 00 (REX.B)" {
    const enc = encMovImm32W(.r10, 42);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xBA, 0x2A, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encMovImm32W: little-endian imm32 (0xDEADBEEF)" {
    const enc = encMovImm32W(.rax, 0xDEADBEEF);
    try testing.expectEqualSlices(u8, &.{ 0xB8, 0xEF, 0xBE, 0xAD, 0xDE }, enc.slice());
}

test "encSubRSpImm8: sub rsp, 16 → 48 83 ec 10" {
    const enc = encSubRSpImm8(16);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xEC, 0x10 }, enc.slice());
}

test "encSubMem64Disp32Imm8: sub qword [r15+0x230], 1 → 49 83 af 30 02 00 00 01" {
    const enc = encSubMem64Disp32Imm8(.r15, 0x230, 1);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x83, 0xAF, 0x30, 0x02, 0x00, 0x00, 0x01 }, enc.slice());
}

test "encSubMem64Disp32Imm8: rsp base emits SIB → 48 83 ac 24 10 00 00 00 01" {
    const enc = encSubMem64Disp32Imm8(.rsp, 16, 1);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xAC, 0x24, 0x10, 0x00, 0x00, 0x00, 0x01 }, enc.slice());
}

test "encAddRSpImm8: add rsp, 16 → 48 83 c4 10" {
    const enc = encAddRSpImm8(16);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xC4, 0x10 }, enc.slice());
}

test "encStoreR32MemRBP: mov [rbp-8], r10d → 44 89 55 f8 (REX.R)" {
    const enc = encStoreR32MemRBP(-8, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x89, 0x55, 0xF8 }, enc.slice());
}

test "encStoreR32MemRBP: mov [rbp-8], ebx → 89 5d f8 (no REX)" {
    const enc = encStoreR32MemRBP(-8, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x89, 0x5D, 0xF8 }, enc.slice());
}

test "encLoadR32MemRBP: mov r10d, [rbp-8] → 44 8b 55 f8" {
    const enc = encLoadR32MemRBP(.r10, -8);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x8B, 0x55, 0xF8 }, enc.slice());
}

test "encLoadR32MemRBP: mov ebx, [rbp-16] → 8b 5d f0" {
    const enc = encLoadR32MemRBP(.rbx, -16);
    try testing.expectEqualSlices(u8, &.{ 0x8B, 0x5D, 0xF0 }, enc.slice());
}

test "encJmpRel32: jmp +0 → e9 00 00 00 00 (placeholder shape)" {
    const enc = encJmpRel32(0);
    try testing.expectEqualSlices(u8, &.{ 0xE9, 0x00, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encJmpRel32: jmp +5 → e9 05 00 00 00" {
    const enc = encJmpRel32(5);
    try testing.expectEqualSlices(u8, &.{ 0xE9, 0x05, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encJmpRel32: jmp -7 → e9 f9 ff ff ff (sign-extended disp)" {
    const enc = encJmpRel32(-7);
    try testing.expectEqualSlices(u8, &.{ 0xE9, 0xF9, 0xFF, 0xFF, 0xFF }, enc.slice());
}

test "encJccRel32: jne +0 → 0f 85 00 00 00 00 (cc=ne=5)" {
    const enc = encJccRel32(.ne, 0);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x85, 0x00, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encJccRel32: je +10 → 0f 84 0a 00 00 00 (cc=e=4)" {
    const enc = encJccRel32(.e, 10);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x84, 0x0A, 0x00, 0x00, 0x00 }, enc.slice());
}

test "patchRel32: rewrite JMP placeholder disp" {
    var buf = [_]u8{ 0xE9, 0, 0, 0, 0 };
    patchRel32(&buf, 0, 5, 42);
    try testing.expectEqualSlices(u8, &.{ 0xE9, 0x2A, 0x00, 0x00, 0x00 }, &buf);
}

test "patchRel32: rewrite Jcc placeholder disp" {
    var buf = [_]u8{ 0x0F, 0x84, 0, 0, 0, 0 };
    patchRel32(&buf, 0, 6, -100);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x84, 0x9C, 0xFF, 0xFF, 0xFF }, &buf);
}

test "encCmpRImm8: cmp ebx, 5 → 83 fb 05" {
    const enc = encCmpRImm8(.d, .rbx, 5);
    try testing.expectEqualSlices(u8, &.{ 0x83, 0xFB, 0x05 }, enc.slice());
}

test "encCmpRImm8: cmp r10d, 0 → 41 83 fa 00 (REX.B)" {
    const enc = encCmpRImm8(.d, .r10, 0);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x83, 0xFA, 0x00 }, enc.slice());
}

test "encJccRel8: jne +5 → 75 05 (cc=ne=5; the canonical br_table skip)" {
    const enc = encJccRel8(.ne, 5);
    try testing.expectEqualSlices(u8, &.{ 0x75, 0x05 }, enc.slice());
}

test "encJccRel8: je -10 → 74 f6" {
    const enc = encJccRel8(.e, -10);
    try testing.expectEqualSlices(u8, &.{ 0x74, 0xF6 }, enc.slice());
}

test "encMovR64FromMemDisp32: mov rax, [r15+0] → 49 8b 87 00 00 00 00" {
    const enc = encMovR64FromMemDisp32(.rax, .r15, 0);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x8B, 0x87, 0, 0, 0, 0 }, enc.slice());
}

test "encMovR64FromMemDisp32: mov rdx, [r15+8] → 49 8b 97 08 00 00 00" {
    const enc = encMovR64FromMemDisp32(.rdx, .r15, 8);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x8B, 0x97, 0x08, 0, 0, 0 }, enc.slice());
}

test "encMovR32FromMemDisp32: mov ebx, [rax+8] → 8b 98 08 00 00 00 (no REX)" {
    const enc = encMovR32FromMemDisp32(.rbx, .rax, 8);
    try testing.expectEqualSlices(u8, &.{ 0x8B, 0x98, 0x08, 0, 0, 0 }, enc.slice());
}

test "encMovR32FromMemDisp32: mov r10d, [rax+16] → 44 8b 90 10 00 00 00 (REX.R)" {
    const enc = encMovR32FromMemDisp32(.r10, .rax, 16);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x8B, 0x90, 0x10, 0, 0, 0 }, enc.slice());
}

test "encStoreR32MemDisp32: mov [rax+8], ebx → 89 98 08 00 00 00 (no REX)" {
    const enc = encStoreR32MemDisp32(.rbx, .rax, 8);
    try testing.expectEqualSlices(u8, &.{ 0x89, 0x98, 0x08, 0, 0, 0 }, enc.slice());
}

test "encStoreR32MemDisp32: mov [rax+16], r10d → 44 89 90 10 00 00 00 (REX.R)" {
    const enc = encStoreR32MemDisp32(.r10, .rax, 16);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x89, 0x90, 0x10, 0, 0, 0 }, enc.slice());
}

test "encCmpR64MemDisp32: cmp rdx, [r15+8] → 49 3b 97 08 00 00 00" {
    const enc = encCmpR64MemDisp32(.rdx, .r15, 8);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x3B, 0x97, 0x08, 0, 0, 0 }, enc.slice());
}

test "encMovR32FromBaseIdx: mov ebx, [rax + rdx] → 8b 1c 10" {
    const enc = encMovR32FromBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x8B, 0x1C, 0x10 }, enc.slice());
}

test "encMovR32FromBaseIdx: mov r10d, [r15 + rax] → 45 8b 14 07 (REX.R+REX.B)" {
    const enc = encMovR32FromBaseIdx(.r10, .r15, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x8B, 0x14, 0x07 }, enc.slice());
}

test "encStoreR32MemBaseIdx: mov [rax+rdx], ebx → 89 1c 10" {
    const enc = encStoreR32MemBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x89, 0x1C, 0x10 }, enc.slice());
}

test "encStoreR32MemBaseIdx: mov [r15+rax], r10d → 45 89 14 07 (REX.R+REX.B)" {
    const enc = encStoreR32MemBaseIdx(.r10, .r15, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x89, 0x14, 0x07 }, enc.slice());
}

test "encStoreR16MemBaseIdx: mov [rax+rdx], bx → 66 89 1c 10" {
    const enc = encStoreR16MemBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x89, 0x1C, 0x10 }, enc.slice());
}

test "encStoreR8MemBaseIdx: mov [rax+rdx], bl → 40 88 1c 10 (forced REX)" {
    const enc = encStoreR8MemBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x88, 0x1C, 0x10 }, enc.slice());
}

test "encStoreR8MemBaseIdx: mov [rax+rdx], r10b → 44 88 14 10 (REX.R)" {
    const enc = encStoreR8MemBaseIdx(.r10, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x88, 0x14, 0x10 }, enc.slice());
}

test "encMovzxR32_8MemBaseIdx: movzx ebx, byte [rax+rdx] → 0f b6 1c 10" {
    const enc = encMovzxR32_8MemBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xB6, 0x1C, 0x10 }, enc.slice());
}

test "encMovsxR32_8MemBaseIdx: movsx r10d, byte [rax+rdx] → 44 0f be 14 10 (REX.R)" {
    const enc = encMovsxR32_8MemBaseIdx(.r10, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x0F, 0xBE, 0x14, 0x10 }, enc.slice());
}

test "encMovzxR32_16MemBaseIdx: movzx ebx, word [rax+rdx] → 0f b7 1c 10" {
    const enc = encMovzxR32_16MemBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xB7, 0x1C, 0x10 }, enc.slice());
}

test "encMovsxR32_16MemBaseIdx: movsx ebx, word [rax+rdx] → 0f bf 1c 10" {
    const enc = encMovsxR32_16MemBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xBF, 0x1C, 0x10 }, enc.slice());
}

test "encLeaR64BaseDisp8: lea rcx, [rdx+4] → 48 8d 4a 04" {
    const enc = encLeaR64BaseDisp8(.rcx, .rdx, 4);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x8D, 0x4A, 0x04 }, enc.slice());
}

test "encLeaR64BaseDisp8: lea rcx, [r15+8] → 49 8d 4f 08 (REX.B)" {
    const enc = encLeaR64BaseDisp8(.rcx, .r15, 8);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x8D, 0x4F, 0x08 }, enc.slice());
}

test "encLeaR64BaseDisp32: lea rdx, [rbp-256] → 48 8d 95 00 ff ff ff" {
    // Win64 v128 marshal: caller writes v128 into
    // scratch at [RBP+disp32], LEAs the disp into the int-arg-reg.
    // disp32 = -256 (i32 little-endian 0xFFFFFF00).
    const enc = encLeaR64BaseDisp32(.rdx, .rbp, -256);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x8D, 0x95, 0x00, 0xFF, 0xFF, 0xFF }, enc.slice());
}

test "encLeaR64BaseDisp32: lea r9, [rbp-1024] → 4c 8d 8d 00 fc ff ff (REX.R)" {
    // R9 is one of the Win64 int-arg regs (slot 4 = RCX runtime-ptr,
    // R9 = user-arg slot 3).
    const enc = encLeaR64BaseDisp32(.r9, .rbp, -1024);
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x8D, 0x8D, 0x00, 0xFC, 0xFF, 0xFF }, enc.slice());
}

test "encLeaR64BaseRspDisp32: lea rdx, [rsp+48] → 48 8d 94 24 30 00 00 00 (SIB 0x24 for RSP base)" {
    // Win64 v128 marshal caller-side: scratch
    // is in the outgoing-args region at [RSP + scratch_disp];
    // LEA the address into the int-arg slot (RDX for arg 1).
    // RSP base mandates SIB byte 0x24 (rm=100 ⇒ SIB-escape per
    // AMD64); distinct encoder from encLeaR64BaseDisp32.
    const enc = encLeaR64BaseRspDisp32(.rdx, 48);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x8D, 0x94, 0x24, 0x30, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encLeaR64BaseRspDisp32: lea r8, [rsp+64] → 4c 8d 84 24 40 00 00 00 (REX.R for R8)" {
    // R8 = Win64 int-arg slot 3 (after RCX runtime-ptr, RDX, R8).
    const enc = encLeaR64BaseRspDisp32(.r8, 64);
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x8D, 0x84, 0x24, 0x40, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encStoreXmmV128MemRSPDisp32: movups [rsp+48], xmm1 → 0f 11 8c 24 30 00 00 00" {
    // Win64 v128 marshal caller-side scratch write.
    // ModR/M mod=10, reg=001 (xmm1), rm=100 (SIB-escape for RSP).
    // SIB = 0x24 (scale=00, index=100=none, base=100=RSP).
    const enc = encStoreXmmV128MemRSPDisp32(.xmm1, 48);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x11, 0x8C, 0x24, 0x30, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encStoreXmmV128MemRSPDisp32: movups [rsp+64], xmm12 → 44 0f 11 a4 24 40 00 00 00 (REX.R for xmm12)" {
    const enc = encStoreXmmV128MemRSPDisp32(.xmm12, 64);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x0F, 0x11, 0xA4, 0x24, 0x40, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encAddR64Imm32: add rdx, 4 → 48 81 c2 04 00 00 00" {
    const enc = encAddR64Imm32(.rdx, 4);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x81, 0xC2, 0x04, 0, 0, 0 }, enc.slice());
}

test "encStoreImm32MemDisp32: mov [r15+40], 1 → 41 c7 87 28 00 00 00 01 00 00 00" {
    const enc = encStoreImm32MemDisp32(.r15, 40, 1);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xC7, 0x87, 0x28, 0, 0, 0, 0x01, 0, 0, 0 }, enc.slice());
}

test "encAndRR: and ebx, ecx (d) → 21 cb" {
    const enc = encAndRR(.d, .rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x21, 0xCB }, enc.slice());
}

test "encOrRR: or ebx, ecx (d) → 09 cb" {
    const enc = encOrRR(.d, .rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x09, 0xCB }, enc.slice());
}

test "encXorRR: xor ebx, ecx (d) → 31 cb" {
    const enc = encXorRR(.d, .rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x31, 0xCB }, enc.slice());
}

test "encXorRR: xor rax, rax (q) → 48 31 c0 (canonical zero idiom)" {
    const enc = encXorRR(.q, .rax, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x31, 0xC0 }, enc.slice());
}

test "encImulRR: imul ebx, ecx (d) → 0f af d9" {
    const enc = encImulRR(.d, .rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xAF, 0xD9 }, enc.slice());
}

test "encImulRR: imul rbx, rcx (q) → 48 0f af d9" {
    const enc = encImulRR(.q, .rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x0F, 0xAF, 0xD9 }, enc.slice());
}

test "encImulRR: imul ebx, r10d (d) → 41 0f af da (REX.B for src)" {
    const enc = encImulRR(.d, .rbx, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x0F, 0xAF, 0xDA }, enc.slice());
}

test "encImulRR: imul r9d, ecx (d) → 44 0f af c9 (REX.R for dst)" {
    const enc = encImulRR(.d, .r9, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x0F, 0xAF, 0xC9 }, enc.slice());
}

test "encCmpRR: cmp ebx, ecx (d) → 39 cb" {
    const enc = encCmpRR(.d, .rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x39, 0xCB }, enc.slice());
}

test "encCmpRR: cmp r10d, r11d (d) → 45 39 da (REX.R + REX.B)" {
    const enc = encCmpRR(.d, .r10, .r11);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x39, 0xDA }, enc.slice());
}

test "encTestRR: test ebx, ebx (d) → 85 db" {
    const enc = encTestRR(.d, .rbx, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x85, 0xDB }, enc.slice());
}

test "encTestRR: test r10d, r10d (d) → 45 85 d2 (REX.R + REX.B)" {
    const enc = encTestRR(.d, .r10, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x85, 0xD2 }, enc.slice());
}

test "encTestRR: test rax, rax (q) → 48 85 c0 (canonical zero check)" {
    const enc = encTestRR(.q, .rax, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x85, 0xC0 }, enc.slice());
}

test "encShiftRCl: shl ebx, cl (.d, .shl) → d3 e3" {
    const enc = encShiftRCl(.d, .shl, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0xD3, 0xE3 }, enc.slice());
}

test "encShiftRCl: shr r10d, cl (.d, .shr) → 41 d3 ea (REX.B)" {
    const enc = encShiftRCl(.d, .shr, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xD3, 0xEA }, enc.slice());
}

test "encShiftRCl: sar ebx, cl (.d, .sar) → d3 fb (kind=7)" {
    const enc = encShiftRCl(.d, .sar, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0xD3, 0xFB }, enc.slice());
}

test "encShiftRCl: rol ebx, cl (.d, .rol) → d3 c3 (kind=0)" {
    const enc = encShiftRCl(.d, .rol, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0xD3, 0xC3 }, enc.slice());
}

test "encShiftRCl: ror ebx, cl (.d, .ror) → d3 cb (kind=1)" {
    const enc = encShiftRCl(.d, .ror, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0xD3, 0xCB }, enc.slice());
}

test "encShiftRCl: shl rbx, cl (.q) → 48 d3 e3 (REX.W)" {
    const enc = encShiftRCl(.q, .shl, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xD3, 0xE3 }, enc.slice());
}

test "encLzcntR32: lzcnt ebx, ecx → f3 0f bd d9" {
    const enc = encLzcntR32(.rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0xBD, 0xD9 }, enc.slice());
}

test "encLzcntR32: lzcnt r10d, r11d → f3 45 0f bd d3 (REX after F3)" {
    const enc = encLzcntR32(.r10, .r11);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x45, 0x0F, 0xBD, 0xD3 }, enc.slice());
}

test "encTzcntR32: tzcnt ebx, ecx → f3 0f bc d9" {
    const enc = encTzcntR32(.rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0xBC, 0xD9 }, enc.slice());
}

test "encPopcntR32: popcnt ebx, ecx → f3 0f b8 d9" {
    const enc = encPopcntR32(.rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0xB8, 0xD9 }, enc.slice());
}

test "encPopcntR32: popcnt r10d, r10d → f3 45 0f b8 d2" {
    const enc = encPopcntR32(.r10, .r10);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x45, 0x0F, 0xB8, 0xD2 }, enc.slice());
}

test "encSetccR: sete bl → 40 0f 94 c3 (bare REX for low-byte access)" {
    const enc = encSetccR(.e, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x0F, 0x94, 0xC3 }, enc.slice());
}

test "encSetccR: setl r10b → 41 0f 9c c2 (REX.B)" {
    const enc = encSetccR(.l, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x0F, 0x9C, 0xC2 }, enc.slice());
}

test "encSetccR: setb cl (unsigned-less) → 40 0f 92 c1" {
    const enc = encSetccR(.b, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x0F, 0x92, 0xC1 }, enc.slice());
}

test "encMovzxR32R8: movzx ebx, bl → 40 0f b6 db" {
    const enc = encMovzxR32R8(.rbx, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x0F, 0xB6, 0xDB }, enc.slice());
}

test "encMovzxR32R8: movzx r10d, r10b → 45 0f b6 d2 (REX.R + REX.B)" {
    const enc = encMovzxR32R8(.r10, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0xB6, 0xD2 }, enc.slice());
}

test "encMovsxdR64R32: movsxd rax, ecx → 48 63 c1" {
    const enc = encMovsxdR64R32(.rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x63, 0xC1 }, enc.slice());
}

test "encMovsxdR64R32: movsxd r10, r10d → 4d 63 d2 (REX.W + REX.R + REX.B)" {
    const enc = encMovsxdR64R32(.r10, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x4D, 0x63, 0xD2 }, enc.slice());
}

test "encMovsxdR64R32: movsxd r11, ecx → 4c 63 d9 (REX.W + REX.R)" {
    const enc = encMovsxdR64R32(.r11, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x63, 0xD9 }, enc.slice());
}

test "encCallRel32: call rel32 disp=0 → e8 00 00 00 00 (placeholder)" {
    const enc = encCallRel32(0);
    try testing.expectEqualSlices(u8, &.{ 0xE8, 0x00, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encCallRel32: call rel32 disp=0x12345678 little-endian" {
    const enc = encCallRel32(0x12345678);
    try testing.expectEqualSlices(u8, &.{ 0xE8, 0x78, 0x56, 0x34, 0x12 }, enc.slice());
}

test "encCallReg: call rax → ff d0 (no REX)" {
    const enc = encCallReg(.rax);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD0 }, enc.slice());
}

test "encCallReg: call r10 → 41 ff d2 (REX.B)" {
    const enc = encCallReg(.r10);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xFF, 0xD2 }, enc.slice());
}

test "encJmpReg: jmp rax → ff e0 (no REX, /4 = JMP, ADR-0066 thunk tail-call)" {
    const enc = encJmpReg(.rax);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xE0 }, enc.slice());
}

test "encJmpReg: jmp r10 → 41 ff e2 (REX.B)" {
    const enc = encJmpReg(.r10);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xFF, 0xE2 }, enc.slice());
}

test "encCmpRImm32: cmp eax, 0 → 81 f8 00 00 00 00 (no REX)" {
    const enc = encCmpRImm32(.rax, 0);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0xF8, 0x00, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encCmpRImm32: cmp r10d, 0xCAFE → 41 81 fa fe ca 00 00 (REX.B + LE imm32)" {
    const enc = encCmpRImm32(.r10, 0xCAFE);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x81, 0xFA, 0xFE, 0xCA, 0x00, 0x00 }, enc.slice());
}

test "encMovR32FromBaseIdxLsl2: mov eax, [rax + r10*4] → 42 8b 04 90 (REX.X)" {
    const enc = encMovR32FromBaseIdxLsl2(.rax, .rax, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x42, 0x8B, 0x04, 0x90 }, enc.slice());
}

test "encMovR32FromBaseIdxLsl2: mov ebx, [rcx + rdx*4] → 8b 1c 91 (no REX)" {
    const enc = encMovR32FromBaseIdxLsl2(.rbx, .rcx, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x8B, 0x1C, 0x91 }, enc.slice());
}

test "encMovR64FromBaseIdxLsl3: mov rax, [rax + r10*8] → 4a 8b 04 d0 (REX.W + REX.X)" {
    const enc = encMovR64FromBaseIdxLsl3(.rax, .rax, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x4A, 0x8B, 0x04, 0xD0 }, enc.slice());
}

test "encMovR64FromBaseIdxLsl3: mov rcx, [rdx + rbx*8] → 48 8b 0c da (REX.W only)" {
    const enc = encMovR64FromBaseIdxLsl3(.rcx, .rdx, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x8B, 0x0C, 0xDA }, enc.slice());
}

test "encMovImm64Q: movabs rax, 0xDEADBEEFCAFEBABE → 48 b8 + LE 8-byte imm" {
    const enc = encMovImm64Q(.rax, 0xDEADBEEFCAFEBABE);
    try testing.expectEqualSlices(u8, &.{
        0x48, 0xB8, 0xBE, 0xBA, 0xFE, 0xCA, 0xEF, 0xBE, 0xAD, 0xDE,
    }, enc.slice());
}

test "encMovImm64Q: movabs r10, 0 → 49 ba + 8 zeros (REX.W + REX.B)" {
    const enc = encMovImm64Q(.r10, 0);
    try testing.expectEqualSlices(u8, &.{
        0x49, 0xBA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    }, enc.slice());
}

test "encMovdXmmFromR32: movd xmm0, eax → 66 0f 6e c0 (no REX)" {
    const enc = encMovdXmmFromR32(.xmm0, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x6E, 0xC0 }, enc.slice());
}

test "encMovdXmmFromR32: movd xmm8, eax → 66 44 0f 6e c0 (REX.R)" {
    const enc = encMovdXmmFromR32(.xmm8, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x44, 0x0F, 0x6E, 0xC0 }, enc.slice());
}

test "encMovqXmmFromR64: movq xmm0, rax → 66 48 0f 6e c0 (REX.W only)" {
    const enc = encMovqXmmFromR64(.xmm0, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x48, 0x0F, 0x6E, 0xC0 }, enc.slice());
}

test "encMovqXmmFromR64: movq xmm8, rax → 66 4c 0f 6e c0 (REX.W + REX.R)" {
    const enc = encMovqXmmFromR64(.xmm8, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x4C, 0x0F, 0x6E, 0xC0 }, enc.slice());
}

test "encMovapsXmmXmm: movaps xmm0, xmm1 → 0f 28 c1 (no REX)" {
    const enc = encMovapsXmmXmm(.xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x28, 0xC1 }, enc.slice());
}

test "encMovapsXmmXmm: movaps xmm10, xmm8 → 45 0f 28 d0 (REX.R + REX.B)" {
    const enc = encMovapsXmmXmm(.xmm10, .xmm8);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0x28, 0xD0 }, enc.slice());
}

test "encSseScalarBinary: addss xmm0, xmm1 → f3 0f 58 c1 (no REX)" {
    const enc = encSseScalarBinary(.f32, 0x58, .xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0x58, 0xC1 }, enc.slice());
}

test "encSseScalarBinary: addss xmm10, xmm9 → f3 45 0f 58 d1 (REX.R + REX.B)" {
    const enc = encSseScalarBinary(.f32, 0x58, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x45, 0x0F, 0x58, 0xD1 }, enc.slice());
}

test "encSseScalarBinary: mulsd xmm8, xmm9 → f2 45 0f 59 c1 (REX, F2 prefix, opcode 59)" {
    const enc = encSseScalarBinary(.f64, 0x59, .xmm8, .xmm9);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x45, 0x0F, 0x59, 0xC1 }, enc.slice());
}

test "encSseScalarBinary: divsd xmm0, xmm1 → f2 0f 5e c1 (no REX, opcode 5E)" {
    const enc = encSseScalarBinary(.f64, 0x5E, .xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x0F, 0x5E, 0xC1 }, enc.slice());
}

test "encUcomiss: ucomiss xmm0, xmm1 → 0f 2e c1 (no REX, no prefix)" {
    const enc = encUcomiss(.xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x2E, 0xC1 }, enc.slice());
}

test "encUcomiss: ucomiss xmm8, xmm9 → 45 0f 2e c1 (REX.R + REX.B)" {
    const enc = encUcomiss(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0x2E, 0xC1 }, enc.slice());
}

test "encUcomisd: ucomisd xmm0, xmm1 → 66 0f 2e c1 (66 prefix, no REX)" {
    const enc = encUcomisd(.xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x2E, 0xC1 }, enc.slice());
}

test "encUcomisd: ucomisd xmm8, xmm9 → 66 45 0f 2e c1 (66 prefix + REX)" {
    const enc = encUcomisd(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x2E, 0xC1 }, enc.slice());
}

test "encSsePackedBinary: andps xmm0, xmm1 → 0f 54 c1 (no prefix)" {
    const enc = encSsePackedBinary(.f32, 0x54, .xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x54, 0xC1 }, enc.slice());
}

test "encSsePackedBinary: xorpd xmm8, xmm9 → 66 45 0f 57 c1 (66 prefix + REX)" {
    const enc = encSsePackedBinary(.f64, 0x57, .xmm8, .xmm9);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x57, 0xC1 }, enc.slice());
}

test "encRoundss: roundss xmm0, xmm1, 2 → 66 0f 3a 0a c1 02 (ceil mode)" {
    const enc = encRoundss(.xmm0, .xmm1, 2);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x0A, 0xC1, 0x02 }, enc.slice());
}

test "encRoundss: roundss xmm8, xmm9, 1 → 66 45 0f 3a 0a c1 01 (REX + floor mode)" {
    const enc = encRoundss(.xmm8, .xmm9, 1);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x3A, 0x0A, 0xC1, 0x01 }, enc.slice());
}

test "encRoundsd: roundsd xmm0, xmm1, 3 → 66 0f 3a 0b c1 03 (trunc mode, opcode 0B)" {
    const enc = encRoundsd(.xmm0, .xmm1, 3);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x0B, 0xC1, 0x03 }, enc.slice());
}

test "encMovdR32FromXmm: movd eax, xmm0 → 66 0f 7e c0 (no REX)" {
    const enc = encMovdR32FromXmm(.rax, .xmm0);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x7E, 0xC0 }, enc.slice());
}

test "encMovdR32FromXmm: movd r10d, xmm8 → 66 45 0f 7e c2 (REX.R + REX.B)" {
    const enc = encMovdR32FromXmm(.r10, .xmm8);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x7E, 0xC2 }, enc.slice());
}

test "encMovqR64FromXmm: movq rax, xmm8 → 66 4c 0f 7e c0 (REX.W + REX.R)" {
    const enc = encMovqR64FromXmm(.rax, .xmm8);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x4C, 0x0F, 0x7E, 0xC0 }, enc.slice());
}

test "encMovqR64FromXmm: movq rcx, xmm0 → 66 48 0f 7e c1 (REX.W only)" {
    const enc = encMovqR64FromXmm(.rcx, .xmm0);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x48, 0x0F, 0x7E, 0xC1 }, enc.slice());
}

test "encCvtsi2Scalar: cvtsi2ss xmm0, eax → f3 0f 2a c0 (no REX)" {
    const enc = encCvtsi2Scalar(.f32, false, .xmm0, .rax);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0x2A, 0xC0 }, enc.slice());
}

test "encCvtsi2Scalar: cvtsi2ss xmm8, rax → f3 4c 0f 2a c0 (REX.W + REX.R)" {
    const enc = encCvtsi2Scalar(.f32, true, .xmm8, .rax);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x4C, 0x0F, 0x2A, 0xC0 }, enc.slice());
}

test "encCvtsi2Scalar: cvtsi2sd xmm8, r10d → f2 45 0f 2a c2 (REX.R + REX.B)" {
    const enc = encCvtsi2Scalar(.f64, false, .xmm8, .r10);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x45, 0x0F, 0x2A, 0xC2 }, enc.slice());
}

test "encCvtsi2Scalar: cvtsi2sd xmm0, rax → f2 48 0f 2a c0 (REX.W only)" {
    const enc = encCvtsi2Scalar(.f64, true, .xmm0, .rax);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x48, 0x0F, 0x2A, 0xC0 }, enc.slice());
}

test "encShrRImm8: shr rax, 1 → 48 c1 e8 01" {
    const enc = encShrRImm8(.q, .rax, 1);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xC1, 0xE8, 0x01 }, enc.slice());
}

test "encShrRImm8: shr r10, 1 → 49 c1 ea 01 (REX.W + REX.B)" {
    const enc = encShrRImm8(.q, .r10, 1);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0xC1, 0xEA, 0x01 }, enc.slice());
}

test "encShlRImm8: shl rax, 4 → 48 c1 e0 04 (/4 = SHL)" {
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xC1, 0xE0, 0x04 }, encShlRImm8(.q, .rax, 4).slice());
}

test "encShlRImm8: shl r10, 4 → 49 c1 e2 04 (REX.W + REX.B)" {
    try testing.expectEqualSlices(u8, &.{ 0x49, 0xC1, 0xE2, 0x04 }, encShlRImm8(.q, .r10, 4).slice());
}

test "encAndRImm8: and rax, 1 → 48 83 e0 01" {
    const enc = encAndRImm8(.q, .rax, 1);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xE0, 0x01 }, enc.slice());
}

test "encAndRImm8: and rcx, 1 → 48 83 e1 01" {
    const enc = encAndRImm8(.q, .rcx, 1);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xE1, 0x01 }, enc.slice());
}

test "encSarRImm8: sar eax, 1 (d) → c1 f8 01 (no REX; i31.get_s)" {
    try testing.expectEqualSlices(u8, &.{ 0xC1, 0xF8, 0x01 }, encSarRImm8(.d, .rax, 1).slice());
}

test "encSarRImm8: sar rax, 1 (q) → 48 c1 f8 01 (REX.W, /7)" {
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xC1, 0xF8, 0x01 }, encSarRImm8(.q, .rax, 1).slice());
}

test "encOrRImm8: or eax, 1 (d) → 83 c8 01 (no REX; ref.i31 tag)" {
    try testing.expectEqualSlices(u8, &.{ 0x83, 0xC8, 0x01 }, encOrRImm8(.d, .rax, 1).slice());
}

test "encOrRImm8: or rcx, 1 (q) → 48 83 c9 01 (REX.W, /1)" {
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xC9, 0x01 }, encOrRImm8(.q, .rcx, 1).slice());
}

test "encCvttScalar2Int: cvttss2si eax, xmm0 → f3 0f 2c c0 (no REX)" {
    const enc = encCvttScalar2Int(.f32, false, .rax, .xmm0);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0x2C, 0xC0 }, enc.slice());
}

test "encCvttScalar2Int: cvttss2si r10, xmm8 → f3 4d 0f 2c d0 (REX.W+R+B; ModRM.reg=r10)" {
    const enc = encCvttScalar2Int(.f32, true, .r10, .xmm8);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x4D, 0x0F, 0x2C, 0xD0 }, enc.slice());
}

test "encCvttScalar2Int: cvttsd2si rax, xmm0 → f2 48 0f 2c c0 (REX.W only)" {
    const enc = encCvttScalar2Int(.f64, true, .rax, .xmm0);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x48, 0x0F, 0x2C, 0xC0 }, enc.slice());
}

test "encCvttScalar2Int: cvttsd2si eax, xmm8 → f2 41 0f 2c c0 (REX.B only)" {
    const enc = encCvttScalar2Int(.f64, false, .rax, .xmm8);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x41, 0x0F, 0x2C, 0xC0 }, enc.slice());
}

test "encMovssMovsdMemBaseIdx: movss xmm0, [rax+rdx] → f3 0f 10 04 10 (no REX)" {
    const enc = encMovssMovsdMemBaseIdx(.f32, false, .xmm0, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0x10, 0x04, 0x10 }, enc.slice());
}

test "encMovssMovsdMemBaseIdx: movsd xmm8, [rax+rdx] → f2 44 0f 10 04 10 (REX.R)" {
    const enc = encMovssMovsdMemBaseIdx(.f64, false, .xmm8, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x44, 0x0F, 0x10, 0x04, 0x10 }, enc.slice());
}

test "encMovssMovsdMemBaseIdx: movss [rax+rdx], xmm8 → f3 44 0f 11 04 10 (store, REX.R)" {
    const enc = encMovssMovsdMemBaseIdx(.f32, true, .xmm8, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x44, 0x0F, 0x11, 0x04, 0x10 }, enc.slice());
}

test "encMovssMovsdMemBaseIdx: movsd [r10+r11], xmm0 → f2 43 0f 11 04 1a (store, REX.B+X)" {
    const enc = encMovssMovsdMemBaseIdx(.f64, true, .xmm0, .r10, .r11);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x43, 0x0F, 0x11, 0x04, 0x1A }, enc.slice());
}

// Sign-extension + integer divide encoders.
// Hex bytes verified via `clang -target x86_64-linux-gnu` Intel-
// syntax assembler (encMovsxR32R8 etc.).
test "encMovsxR32R8: movsbl %bl, %eax → 40 0f be c3" {
    const enc = encMovsxR32R8(.rax, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x0F, 0xBE, 0xC3 }, enc.slice());
}
test "encMovsxR32R16: movswl %bx, %eax → 0f bf c3" {
    const enc = encMovsxR32R16(.rax, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xBF, 0xC3 }, enc.slice());
}
test "encMovzxR32R16: movzwl %bx, %eax → 0f b7 c3" {
    const enc = encMovzxR32R16(.rax, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xB7, 0xC3 }, enc.slice());
}
test "encMovsxR64R8: movsbq %bl, %rax → 48 0f be c3 (REX.W)" {
    const enc = encMovsxR64R8(.rax, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x0F, 0xBE, 0xC3 }, enc.slice());
}
test "encMovsxR64R16: movswq %bx, %rax → 48 0f bf c3" {
    const enc = encMovsxR64R16(.rax, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x0F, 0xBF, 0xC3 }, enc.slice());
}
test "encCdq → 0x99" {
    try testing.expectEqualSlices(u8, &.{0x99}, encCdq().slice());
}
test "encCqo → 48 99" {
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x99 }, encCqo().slice());
}
test "encIdivR32 idiv ebx → f7 fb" {
    try testing.expectEqualSlices(u8, &.{ 0xF7, 0xFB }, encIdivR32(.rbx).slice());
}
test "encDivR32 div ebx → f7 f3" {
    try testing.expectEqualSlices(u8, &.{ 0xF7, 0xF3 }, encDivR32(.rbx).slice());
}
test "encIdivR64 idiv rbx → 48 f7 fb" {
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xF7, 0xFB }, encIdivR64(.rbx).slice());
}
test "encDivR64 div rbx → 48 f7 f3" {
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xF7, 0xF3 }, encDivR64(.rbx).slice());
}
test "encIdivR32 idiv r10d → 41 f7 fa (REX.B)" {
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xF7, 0xFA }, encIdivR32(.r10).slice());
}
test "encDivR64 div r10 → 49 f7 f2 (REX.W + REX.B)" {
    try testing.expectEqualSlices(u8, &.{ 0x49, 0xF7, 0xF2 }, encDivR64(.r10).slice());
}

test "encStoreR32MemRSPDisp32 RBX, [RSP+0] → 89 9c 24 00 00 00 00 (no REX)" {
    try testing.expectEqualSlices(u8, &.{ 0x89, 0x9C, 0x24, 0x00, 0x00, 0x00, 0x00 }, encStoreR32MemRSPDisp32(.rbx, 0).slice());
}
test "encStoreR32MemRSPDisp32 R10, [RSP+8] → 44 89 94 24 08 00 00 00 (REX.R for r10)" {
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x89, 0x94, 0x24, 0x08, 0x00, 0x00, 0x00 }, encStoreR32MemRSPDisp32(.r10, 8).slice());
}
test "encStoreR64MemRSPDisp32 RBX, [RSP+16] → 48 89 9c 24 10 00 00 00 (REX.W)" {
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0x9C, 0x24, 0x10, 0x00, 0x00, 0x00 }, encStoreR64MemRSPDisp32(.rbx, 16).slice());
}
test "encStoreXmmF32MemRSPDisp32 XMM8, [RSP+0] → f3 44 0f 11 84 24 00 00 00 00 (REX.R for xmm8)" {
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x44, 0x0F, 0x11, 0x84, 0x24, 0x00, 0x00, 0x00, 0x00 }, encStoreXmmF32MemRSPDisp32(.xmm8, 0).slice());
}
test "encStoreXmmF64MemRSPDisp32 XMM0, [RSP+24] → f2 0f 11 84 24 18 00 00 00 (no REX for xmm0)" {
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x0F, 0x11, 0x84, 0x24, 0x18, 0x00, 0x00, 0x00 }, encStoreXmmF64MemRSPDisp32(.xmm0, 24).slice());
}

test "encStoreR32MemRBPDisp32 RBX, [RBP-160] → 89 9d 60 ff ff ff (mod=10 rm=101 disp32)" {
    try testing.expectEqualSlices(u8, &.{ 0x89, 0x9D, 0x60, 0xFF, 0xFF, 0xFF }, encStoreR32MemRBPDisp32(-160, .rbx).slice());
}
test "encStoreR64MemRBPDisp32 RBX, [RBP-160] → 48 89 9d 60 ff ff ff (REX.W mod=10 rm=101)" {
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0x9D, 0x60, 0xFF, 0xFF, 0xFF }, encStoreR64MemRBPDisp32(-160, .rbx).slice());
}
test "encLoadR32MemRBPDisp32 RBX, [RBP-160] → 8b 9d 60 ff ff ff" {
    try testing.expectEqualSlices(u8, &.{ 0x8B, 0x9D, 0x60, 0xFF, 0xFF, 0xFF }, encLoadR32MemRBPDisp32(.rbx, -160).slice());
}
test "encSubRSpImm32: sub rsp, 256 → 48 81 ec 00 01 00 00" {
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x81, 0xEC, 0x00, 0x01, 0x00, 0x00 }, encSubRSpImm32(256).slice());
}
test "encAddRSpImm32: add rsp, 256 → 48 81 c4 00 01 00 00" {
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x81, 0xC4, 0x00, 0x01, 0x00, 0x00 }, encAddRSpImm32(256).slice());
}
