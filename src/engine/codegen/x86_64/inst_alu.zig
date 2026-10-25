//! x86_64 ALU + immediate encoder family — Intel SDM Vol 2 §3.4
//! ADD/SUB/MOV/AND/OR/XOR/CMP/TEST + Vol 2 §3.5 SHL/SHR/SAR
//! shifts. Reg-reg ALU, reg-imm ALU, RSP frame helpers, and the
//! MOV-imm immediate-load encoders. Pure encoder (returns
//! `EncodedInsn` value); caller appends `enc.slice()` to its
//! buffer.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const inst = @import("inst.zig");
const reg_class = @import("reg_class.zig");

const Gpr = reg_class.Gpr;
const Width = reg_class.Width;
const EncodedInsn = inst.EncodedInsn;
const ShiftKind = inst.ShiftKind;
const encodeRex = inst.encodeRex;
const encodeModrm = inst.encodeModrm;
const encodeSib = inst.encodeSib;
const rexForRR = inst.rexForRR;

/// `MOV r/m, r` (opcode 0x89) — copy `src` into `dst`. Width
/// `.d` = 32-bit (zero-extends to 64), `.q` = 64-bit.
///
/// Encoding (no SIB, mod=11 register-direct):
///   [REX?] 89 ModR/M
///   ModR/M.mod = 0b11, ModR/M.reg = src.low3, ModR/M.rm = dst.low3
pub fn encMovRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x89);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `ADD r/m, r` (opcode 0x01) — `dst += src`.
pub fn encAddRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x01);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `SUB r/m, r` (opcode 0x29) — `dst -= src`.
pub fn encSubRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x29);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `AND r/m, r` (opcode 0x21) — `dst &= src`.
pub fn encAndRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x21);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `OR r/m, r` (opcode 0x09) — `dst |= src`.
pub fn encOrRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x09);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `XOR r/m, r` (opcode 0x31) — `dst ^= src`.
pub fn encXorRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x31);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `CMP r/m, r` (opcode 0x39) — sets EFLAGS based on `dst -
/// src` (no result stored). Same operand-role + REX layout as
/// ADD/SUB.
pub fn encCmpRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x39);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `<shift> r/m, CL` (opcode 0xD3 + ModR/M.reg = kind) —
/// shift / rotate the destination by the count in CL. Width
/// `.d` shifts the low 32 bits (zero-extends to 64); `.q`
/// shifts all 64 bits. Caller is responsible for moving the
/// shift count into ECX/RCX before this instruction.
///
/// **Caller invariant**: dst should not be RCX (the count
/// register). The emit-side handler checks this and surfaces
/// `UnsupportedOp` rather than emitting a self-clobbering
/// sequence.
pub fn encShiftRCl(size: Width, kind: ShiftKind, dst: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    // REX.R is unused (kind sits in ModR/M.reg, all kinds < 8).
    // Pass .rax as a no-op for the reg-position arg of rexForRR
    // so REX.R = 0 and only REX.W + REX.B contribute.
    if (rexForRR(size, .rax, dst)) |rex| enc.push(rex);
    enc.push(0xD3);
    enc.push(encodeModrm(0b11, @backingInt(kind), dst.low3()));
    return enc;
}

/// `TEST r/m, r` (opcode 0x85) — sets EFLAGS based on bitwise
/// AND of `dst` and `src` (no result stored). Same operand-role
/// + REX layout as CMP. Used by Wasm `eqz` as `TEST x, x` →
/// ZF=1 iff x==0.
pub fn encTestRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x85);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `CMP r/m32, imm32` (opcode 0x81 /7) — sign-extended 32-bit
/// compare. Used by `emitCallIndirect`'s sig check vs the
/// call-site's expected typeidx (a u32 module-type index).
pub fn encCmpRImm32(dst: Gpr, imm: u32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(.d, .rax, dst)) |rex| enc.push(rex);
    enc.push(0x81);
    enc.push(encodeModrm(0b11, 7, dst.low3())); // /7 = CMP
    enc.push(@truncate(imm));
    enc.push(@truncate(imm >> 8));
    enc.push(@truncate(imm >> 16));
    enc.push(@truncate(imm >> 24));
    return enc;
}

/// `TEST r/m32, imm32` (opcode 0xF7 /0) — sign-extended 32-bit
/// AND with imm32, sets EFLAGS, no result. Useful for explicit
/// non-zero comparison (TEST r, r is shorter for that). Used by
/// the divide-by-zero check before `IDIV`/`DIV`.
pub fn encTestRImm32(size: Width, dst: Gpr, imm: u32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, .rax, dst)) |rex| enc.push(rex);
    enc.push(0xF7);
    enc.push(encodeModrm(0b11, 0, dst.low3()));
    enc.push(@truncate(imm));
    enc.push(@truncate(imm >> 8));
    enc.push(@truncate(imm >> 16));
    enc.push(@truncate(imm >> 24));
    return enc;
}

/// `CMP r/m32, imm8` (opcode 0x83 /7) — sign-extended 8-bit
/// compare. Used by br_table case-checks. imm8 covers Wasm
/// case indices 0..127; larger requires the 0x81 /7 imm32
/// form (currently surfaces as UnsupportedOp at the
/// emit-handler level rather than here).
pub fn encCmpRImm8(size: Width, dst: Gpr, imm: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, .rax, dst)) |rex| enc.push(rex);
    enc.push(0x83);
    enc.push(encodeModrm(0b11, 7, dst.low3())); // /7 = CMP
    enc.push(@bitCast(imm));
    return enc;
}

/// `IMUL r, r/m` (2-byte opcode 0x0F 0xAF /r) — `dst *= src`,
/// signed/unsigned identical for the low N bits (Wasm i32.mul
/// doesn't distinguish signedness).
///
/// **Operand-role inversion vs ADD/SUB/AND/OR/XOR**: IMUL's
/// 2-operand form puts `dst` in the ModR/M.reg field and `src`
/// in r/m, opposite to ADD/SUB/etc. So REX.R extends `dst`
/// (not `src`) and REX.B extends `src` (not `dst`).
pub fn encImulRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, dst, src)) |rex| enc.push(rex);
    enc.push(0x0F);
    enc.push(0xAF);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

// Wasm wide-arithmetic (ADR-0168 v0.2) — 128-bit carry chain + full
// 128-bit product. ADC/SBB consume the CF set by ADD/SUB; MUL/IMUL
// (one-operand, F7 /4 // /5) compute RDX:RAX = RAX × src.

/// `ADC r/m, r` (opcode 0x11 /r) — `dst = dst + src + CF`.
pub fn encAdcRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x11);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `SBB r/m, r` (opcode 0x19 /r) — `dst = dst - src - CF` (borrow).
pub fn encSbbRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x19);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `MUL r/m` (opcode 0xF7 /4) — unsigned RDX:RAX = RAX × src. The
/// reg field is the /4 opcode extension (REX.R = 0); REX.B covers an
/// extended `src` (mirror encTestRImm32's F7 REX pattern).
pub fn encMul1(size: Width, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, .rax, src)) |rex| enc.push(rex);
    enc.push(0xF7);
    enc.push(encodeModrm(0b11, 4, src.low3()));
    return enc;
}

/// `IMUL r/m` (opcode 0xF7 /5) — signed RDX:RAX = RAX × src.
pub fn encImul1(size: Width, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, .rax, src)) |rex| enc.push(rex);
    enc.push(0xF7);
    enc.push(encodeModrm(0b11, 5, src.low3()));
    return enc;
}

/// `ADD r/m64, imm32` (opcode 0x81 /0 with REX.W). 4-byte
/// little-endian immediate. Used to fold the Wasm static offset
/// into the effective address before bounds check.
pub fn encAddR64Imm32(dst: Gpr, imm: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, dst.extBit()));
    enc.push(0x81);
    enc.push(encodeModrm(0b11, 0, dst.low3())); // /0 = ADD
    const u: u32 = @bitCast(imm);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `SUB RSP, imm8` (sign-extended) — opcode 0x83 /5 with REX.W.
/// 4-byte encoding. Caller responsibility to pass `imm` in
/// i8 range; larger frame extensions need the 6-byte imm32 form
/// (out of scope for the skeleton — capped at 15
/// locals = 120-byte frame).
pub fn encSubRSpImm8(imm: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, 0));
    enc.push(0x83);
    enc.push(encodeModrm(0b11, 5, 4)); // /5 = SUB, rm=4 (RSP)
    enc.push(@bitCast(imm));
    return enc;
}

/// `SUB QWORD PTR [base + disp32], imm8` (sign-extended) — opcode 0x83 /5
/// with REX.W (+ REX.B for R8..R15 bases), mod=10 disp32. 8-byte encoding
/// for an R15 base. ADR-0179 #3b / D-314: the JIT fuel poll's in-memory
/// budget decrement (`SUB [R15+fuel_cell_off], 1` → SF set when the cell
/// goes negative → JS out-of-fuel stub).
pub fn encSubMem64Disp32Imm8(base: Gpr, disp: i32, imm: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, base.extBit()));
    enc.push(0x83);
    enc.push(encodeModrm(0b10, 5, base.low3())); // /5 = SUB
    if (base.low3() == 4) {
        // SIB: scale=00, index=100 (none), base = base.low3().
        enc.push(encodeSib(0b00, 0b100, base.low3()));
    }
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    enc.push(@bitCast(imm));
    return enc;
}

/// `ADD RSP, imm8` (sign-extended) — opcode 0x83 /0 with REX.W.
pub fn encAddRSpImm8(imm: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, 0));
    enc.push(0x83);
    enc.push(encodeModrm(0b11, 0, 4)); // /0 = ADD
    enc.push(@bitCast(imm));
    return enc;
}

/// `SUB RSP, imm32` (REX.W + 0x81 /5) — disp32 form for frame
/// extensions > 127 bytes. Used when
/// total_locals × 8 + outgoing_max + spills exceeds the imm8
/// range. 7-byte encoding (vs 4 for imm8).
pub fn encSubRSpImm32(imm: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, 0));
    enc.push(0x81);
    enc.push(encodeModrm(0b11, 5, 4)); // /5 = SUB, rm=4 (RSP)
    const u: u32 = @bitCast(imm);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `ADD RSP, imm32` (REX.W + 0x81 /0) — disp32 ADD-form pair of
/// `encSubRSpImm32`.
pub fn encAddRSpImm32(imm: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, 0));
    enc.push(0x81);
    enc.push(encodeModrm(0b11, 0, 4)); // /0 = ADD
    const u: u32 = @bitCast(imm);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV r64, imm64` (REX.W + 0xB8+rd iq) — `MOVABS`-form
/// 64-bit immediate load. 10 bytes total. Used by FP const
/// handlers to materialise a 64-bit bit pattern in a GPR for
/// MOVQ → XMM transfer.
pub fn encMovImm64Q(dst: Gpr, imm: u64) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, dst.extBit()));
    enc.push(0xB8 | @as(u8, dst.low3()));
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        enc.push(@truncate(imm >> (i * 8)));
    }
    return enc;
}

/// `SHR r/m, imm8` (opcode 0xC1 /5 ib) — logical shift right
/// by an 8-bit immediate. Width selects 32/64-bit form via REX.W.
/// Used by f.convert_i64_u (slow-path divide-by-2 + round bit).
pub fn encShrRImm8(size: Width, dst: Gpr, imm: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, .rax, dst)) |rex| enc.push(rex);
    enc.push(0xC1);
    enc.push(encodeModrm(0b11, 5, dst.low3())); // /5 = SHR
    enc.push(imm);
    return enc;
}

/// `SHL r/m, imm8` (opcode 0xC1 /4 ib) — logical shift left by an
/// 8-bit immediate. Mirrors `encShrRImm8` with the /4 (= SHL/SAL)
/// modrm digit. Used by array.get/set of a v128 element to scale the
/// index by 16 (idx << 4) into a byte offset (the SIB scale tops out
/// at 8, so ×16 needs a pre-shift).
pub fn encShlRImm8(size: Width, dst: Gpr, imm: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, .rax, dst)) |rex| enc.push(rex);
    enc.push(0xC1);
    enc.push(encodeModrm(0b11, 4, dst.low3())); // /4 = SHL
    enc.push(imm);
    return enc;
}

/// `SAR r/m, imm8` (opcode 0xC1 /7 ib) — arithmetic (sign-
/// replicating) right shift. Mirrors `encShrRImm8` with the /7
/// modrm digit. Used by `i31.get_s` (sign-extend `payload >> 1`).
pub fn encSarRImm8(size: Width, dst: Gpr, imm: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, .rax, dst)) |rex| enc.push(rex);
    enc.push(0xC1);
    enc.push(encodeModrm(0b11, 7, dst.low3())); // /7 = SAR
    enc.push(imm);
    return enc;
}

/// `AND r/m, imm8` (opcode 0x83 /4 ib) — sign-extended 8-bit
/// AND. Used by f.convert_i64_u to extract the low bit (round
/// bit) before re-doubling.
pub fn encAndRImm8(size: Width, dst: Gpr, imm: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, .rax, dst)) |rex| enc.push(rex);
    enc.push(0x83);
    enc.push(encodeModrm(0b11, 4, dst.low3())); // /4 = AND
    enc.push(@bitCast(imm));
    return enc;
}

/// `OR r/m, imm8` (opcode 0x83 /1 ib) — sign-extended 8-bit OR.
/// Mirrors `encAndRImm8` with the /1 modrm digit. Used by `ref.i31`
/// to set the low-bit-1 i31 discriminant after the `<<1` double.
pub fn encOrRImm8(size: Width, dst: Gpr, imm: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, .rax, dst)) |rex| enc.push(rex);
    enc.push(0x83);
    enc.push(encodeModrm(0b11, 1, dst.low3())); // /1 = OR
    enc.push(@bitCast(imm));
    return enc;
}

/// `MOV r32, imm32` (opcode 0xB8+rd ib32) — load a 32-bit
/// immediate into a GPR. The 32-bit form zero-extends to 64
/// bits (Wasm i32 semantics map to this). REX.B for R8..R15.
///
/// `imm` is emitted little-endian per AMD64 Vol.3 §1.2.2.
pub fn encMovImm32W(dst: Gpr, imm: u32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() == 1) enc.push(encodeRex(false, 0, 0, 1));
    enc.push(0xB8 | @as(u8, dst.low3()));
    enc.push(@truncate(imm));
    enc.push(@truncate(imm >> 8));
    enc.push(@truncate(imm >> 16));
    enc.push(@truncate(imm >> 24));
    return enc;
}
