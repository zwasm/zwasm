//! x86_64 memory load/store + sign/zero-extension encoder family
//! — Intel SDM Vol 2 §3.2 MOV/MOVZX/MOVSX/MOVSXD + §3.5 LEA.
//! Covers RBP-relative disp8 / disp32 stack-slot access, RSP-
//! relative caller-side stack-arg stores, base+index SIB
//! addressing for memory ops, and the sub-word extension
//! variants for i32/i64 load{8,16,32}_{s,u}.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const inst = @import("inst.zig");
const reg_class = @import("reg_class.zig");

const Gpr = reg_class.Gpr;
const EncodedInsn = inst.EncodedInsn;
const encodeRex = inst.encodeRex;
const encodeModrm = inst.encodeModrm;
const encodeSib = inst.encodeSib;
const rexForRR = inst.rexForRR;

/// `MOVZX r32, r/m8` (2-byte opcode 0x0F 0xB6 /r) — zero-extend
/// the low byte of `src` into the 32-bit form of `dst` (which
/// implicitly zero-extends to 64 bits). dst occupies ModR/M.reg,
/// src occupies r/m (same role inversion as IMUL).
///
/// **REX always emitted** for the same low-byte addressability
/// reason as SETcc.
pub fn encMovzxR32R8(dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    enc.push(0x0F);
    enc.push(0xB6);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOV r32, [base + idx*4]` (opcode 0x8B with SIB scale=2 →
/// ×4). 32-bit load with 4-scaled index; used by
/// `emitCallIndirect` to read `typeidx_base[idx]` (each entry
/// is a u32). mod=00 + rm=4 signals SIB-byte addressing
/// (no displacement).
pub fn encMovR32FromBaseIdxLsl2(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = dst.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x8B);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b10, idx.low3(), base.low3())); // scale = ×4
    return enc;
}

/// `MOV r64, [base + idx*8]` (REX.W + opcode 0x8B with SIB
/// scale=3 → ×8). 64-bit load with 8-scaled index; used by
/// `emitCallIndirect` to read `funcptr_base[idx]` (each entry
/// is a u64 native funcptr).
pub fn encMovR64FromBaseIdxLsl3(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), idx.extBit(), base.extBit()));
    enc.push(0x8B);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b11, idx.low3(), base.low3())); // scale = ×8
    return enc;
}

/// `MOV [base + idx*8], r64` (REX.W + opcode 0x89 with SIB
/// scale=3 → ×8). Mirror of `encMovR64FromBaseIdxLsl3` for the
/// store direction. Used by `table.set`:
/// `MOV [Rrefs + Ridx*8], Rval` writes `table.refs[idx]`.
pub fn encStoreR64MemBaseIdxLsl3(src: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, src.extBit(), idx.extBit(), base.extBit()));
    enc.push(0x89);
    enc.push(encodeModrm(0b00, src.low3(), 0b100));
    enc.push(encodeSib(0b11, idx.low3(), base.low3())); // scale = ×8
    return enc;
}

/// `MOV [base + idx*4], r32` (opcode 0x89 with SIB scale=2 →
/// ×4). 32-bit store with 4-scaled index — mirror of
/// `encMovR32FromBaseIdxLsl2`. Used by ADR-0068 emitTableCopy
/// typeidx mirror: `MOV [Xdst_ti + Xidx*4], Wsrc_ti`.
pub fn encStoreR32MemBaseIdxLsl2(src: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = src.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x89);
    enc.push(encodeModrm(0b00, src.low3(), 0b100));
    enc.push(encodeSib(0b10, idx.low3(), base.low3())); // scale = ×4
    return enc;
}

/// `MOVSXD r64, r/m32` (REX.W + 0x63 /r) — sign-extend 32-bit
/// source into 64-bit destination. Used by `i64.extend_i32_s`.
/// dst occupies ModR/M.reg, src occupies r/m (IMUL-style
/// operand inversion). REX.W is mandatory.
pub fn encMovsxdR64R32(dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), 0, src.extBit()));
    enc.push(0x63);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOVSX r32, r/m8` (2-byte opcode 0x0F 0xBE /r) — sign-extend
/// the low 8 bits of `src` into the 32-bit form of `dst` (which
/// implicitly zero-extends to 64). Used by Wasm 2.0
/// `i32.extend8_s` (Intel SDM Vol 2 §3.2 MOVSX). REX always
/// emitted for low-byte addressability (BL/BPL/SIL/DIL aliasing
/// with BH/CH/DH/AH in 64-bit mode).
pub fn encMovsxR32R8(dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    enc.push(0x0F);
    enc.push(0xBE);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOVSX r32, r/m16` (2-byte opcode 0x0F 0xBF /r) — sign-extend
/// the low 16 bits. Used by `i32.extend16_s`.
pub fn encMovsxR32R16(dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(.d, dst, src)) |rex| enc.push(rex);
    enc.push(0x0F);
    enc.push(0xBF);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOVZX r32, r/m16` (2-byte opcode 0x0F 0xB7 /r) — zero-extend
/// the low 16 bits. Used by `array.get_u` on packed i16
/// element arrays. Mirror of `encMovsxR32R16` (0x0F 0xBF); no
/// REX.W (32-bit dest) and conditional REX (16-bit source has no
/// byte-register ambiguity, unlike `encMovzxR32R8`).
pub fn encMovzxR32R16(dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(.d, dst, src)) |rex| enc.push(rex);
    enc.push(0x0F);
    enc.push(0xB7);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOVSX r64, r/m8` (REX.W + 0x0F 0xBE /r) — sign-extend low 8
/// bits into 64-bit dst. Used by `i64.extend8_s`.
pub fn encMovsxR64R8(dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), 0, src.extBit()));
    enc.push(0x0F);
    enc.push(0xBE);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOVSX r64, r/m16` (REX.W + 0x0F 0xBF /r) — Used by
/// `i64.extend16_s`.
pub fn encMovsxR64R16(dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), 0, src.extBit()));
    enc.push(0x0F);
    enc.push(0xBF);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOV r64, [base + disp32]` (opcode 0x8B with REX.W, mod=10).
/// Used to reload JitRuntime invariants from `[R15 + offset]`
/// per ADR-0026.
///
/// When `base.low3() == 4` (RSP or R12), AMD64 requires a SIB byte
/// after the ModR/M; the SIB byte encodes "no index, base = X.low3()".
/// Without this, the disp32 bytes would be misinterpreted as part
/// of the ModR/M+SIB stream. (ADR-0068 chunk γ surfaced this when
/// `val_r` happened to be R12 via the regalloc pool.)
pub fn encMovR64FromMemDisp32(dst: Gpr, base: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), 0, base.extBit()));
    enc.push(0x8B);
    enc.push(encodeModrm(0b10, dst.low3(), base.low3()));
    if (base.low3() == 4) {
        // SIB: scale=00, index=100 (none), base = base.low3().
        enc.push(encodeSib(0b00, 0b100, base.low3()));
    }
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV r32, [base + disp32]` (opcode 0x8B without REX.W, mod=10).
/// 32-bit load with disp32; zero-extends to 64-bit dst. Used by
/// `global.get` (i32) to read `[globals_base + idx*8]` for the
/// low 4 bytes of the 8-byte Value slot. SIB-byte injection for
/// RSP/R12 base mirrors `encMovR64FromMemDisp32` (see D-126
/// chunk γ fix).
pub fn encMovR32FromMemDisp32(dst: Gpr, base: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() == 1 or base.extBit() == 1) {
        enc.push(encodeRex(false, dst.extBit(), 0, base.extBit()));
    }
    enc.push(0x8B);
    enc.push(encodeModrm(0b10, dst.low3(), base.low3()));
    if (base.low3() == 4) {
        enc.push(encodeSib(0b00, 0b100, base.low3()));
    }
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV [base + disp32], r64` (opcode 0x89 with REX.W, mod=10).
/// 64-bit store with disp32. Used by `global.set` (i64) to write
/// the full 8-byte Value slot at `[globals_base + byte_off]`.
pub fn encStoreR64MemDisp32(src: Gpr, base: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, src.extBit(), 0, base.extBit()));
    enc.push(0x89);
    enc.push(encodeModrm(0b10, src.low3(), base.low3()));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV [base + disp32], r32` (opcode 0x89 without REX.W, mod=10).
/// 32-bit store with disp32. Used by `global.set` (i32) to write
/// `[globals_base + idx*8]` for the low 4 bytes of the 8-byte
/// Value slot. The upper 4 bytes are left untouched (acceptable
/// for i32-typed globals because the slot is zero-initialised at
/// module load).
pub fn encStoreR32MemDisp32(src: Gpr, base: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (src.extBit() == 1 or base.extBit() == 1) {
        enc.push(encodeRex(false, src.extBit(), 0, base.extBit()));
    }
    enc.push(0x89);
    enc.push(encodeModrm(0b10, src.low3(), base.low3()));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV DWORD PTR [base + disp32], imm32` (opcode 0xC7 /0,
/// mod=10). Stores a 32-bit immediate into memory; no register
/// dependency. Used by the ADR-0034 JIT-execution
/// sentinel: prologue stores `1` into
/// `[entry_arg0 + jit_executed_flag_off]` unconditionally.
/// 7 bytes (no REX) for RAX/RCX/RDX/RBX/RSP/RBP/RSI/RDI bases;
/// 8 bytes (with REX.B) for R8-R15 bases.
pub fn encMovMemDisp32Imm32(base: Gpr, disp: i32, imm: u32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (base.extBit() == 1) {
        enc.push(encodeRex(false, 0, 0, base.extBit()));
    }
    enc.push(0xC7);
    enc.push(encodeModrm(0b10, 0, base.low3()));
    const ud: u32 = @bitCast(disp);
    enc.push(@truncate(ud));
    enc.push(@truncate(ud >> 8));
    enc.push(@truncate(ud >> 16));
    enc.push(@truncate(ud >> 24));
    enc.push(@truncate(imm));
    enc.push(@truncate(imm >> 8));
    enc.push(@truncate(imm >> 16));
    enc.push(@truncate(imm >> 24));
    return enc;
}

/// `CMP r64, [base + disp32]` (opcode 0x3B with REX.W, mod=10).
/// Used by memory bounds check to compare eff_addr against
/// `[R15 + mem_limit_off]`.
pub fn encCmpR64MemDisp32(reg: Gpr, base: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, reg.extBit(), 0, base.extBit()));
    enc.push(0x3B);
    enc.push(encodeModrm(0b10, reg.low3(), base.low3()));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV r32, [base + idx]` (opcode 0x8B with SIB, scale=1).
/// Used by memory loads to read the actual word from
/// `[vm_base + eff_addr]`. mod=00 + rm=4 signals SIB-byte
/// addressing (no disp).
pub fn encMovR32FromBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = dst.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x8B);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOV [base + idx], r32` (opcode 0x89 with SIB, scale=1).
/// 32-bit store; ModR/M.reg = source register. Mirror of
/// `encMovR32FromBaseIdx` for the store direction (i32.store).
pub fn encStoreR32MemBaseIdx(src: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = src.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x89);
    enc.push(encodeModrm(0b00, src.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOV [base + idx], r16` (operand-size prefix 0x66 + opcode
/// 0x89 with SIB). 16-bit store; used by i32.store16.
pub fn encStoreR16MemBaseIdx(src: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66); // operand-size override
    const r = src.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x89);
    enc.push(encodeModrm(0b00, src.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOV [base + idx], r8` (opcode 0x88 with SIB). 8-bit store;
/// used by i32.store8. **Always emits REX** so r8-r15 + the
/// SPL/BPL/SIL/DIL low-byte forms encode correctly (without REX,
/// reg=4..7 means AH/CH/DH/BH).
///
/// TODO(perf, optimisation-phase): when src ∈ {RAX, RCX, RDX, RBX}
/// (low-byte AL/CL/DL/BL accessible without REX), the prefix can
/// be omitted for a 1-byte saving per insn. Deferred until the
/// benchmark loop surfaces store8-dominant fixtures; until then
/// the unconditional REX keeps the encoder simple and uniform.
pub fn encStoreR8MemBaseIdx(src: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(false, src.extBit(), idx.extBit(), base.extBit())); // force REX
    enc.push(0x88);
    enc.push(encodeModrm(0b00, src.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVZX r32, byte ptr [base + idx]` (opcode 0x0F 0xB6 with
/// SIB). 8→32 zero-extend load; used by i32.load8_u.
pub fn encMovzxR32_8MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = dst.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x0F);
    enc.push(0xB6);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVSX r32, byte ptr [base + idx]` (opcode 0x0F 0xBE with
/// SIB). 8→32 sign-extend load; used by i32.load8_s.
pub fn encMovsxR32_8MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = dst.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x0F);
    enc.push(0xBE);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVZX r32, word ptr [base + idx]` (opcode 0x0F 0xB7 with
/// SIB). 16→32 zero-extend load; used by i32.load16_u.
pub fn encMovzxR32_16MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = dst.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x0F);
    enc.push(0xB7);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVSX r32, word ptr [base + idx]` (opcode 0x0F 0xBF with
/// SIB). 16→32 sign-extend load; used by i32.load16_s.
pub fn encMovsxR32_16MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = dst.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x0F);
    enc.push(0xBF);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

// ============================================================
// 64-bit mem load/store (i64.load / i64.store family). Same
// SIB shape as the R32 variants
// above; differ only in REX.W (always set) and the sign/zero-
// extending opcodes for sub-word loads.
// ============================================================

/// `MOV r64, qword ptr [base + idx]` (REX.W + 0x8B with SIB).
/// 8-byte load; used by i64.load.
pub fn encMovR64FromBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), idx.extBit(), base.extBit()));
    enc.push(0x8B);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOV qword ptr [base + idx], r64` (REX.W + 0x89 with SIB).
/// 8-byte store; used by i64.store.
pub fn encStoreR64MemBaseIdx(src: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, src.extBit(), idx.extBit(), base.extBit()));
    enc.push(0x89);
    enc.push(encodeModrm(0b00, src.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVZX r64, byte ptr [base + idx]` (REX.W + 0x0F 0xB6 with
/// SIB). Zero-extends a byte to 64 bits; used by i64.load8_u.
pub fn encMovzxR64_8MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), idx.extBit(), base.extBit()));
    enc.push(0x0F);
    enc.push(0xB6);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVSX r64, byte ptr [base + idx]` (REX.W + 0x0F 0xBE with
/// SIB). Sign-extends a byte to 64 bits; used by i64.load8_s.
pub fn encMovsxR64_8MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), idx.extBit(), base.extBit()));
    enc.push(0x0F);
    enc.push(0xBE);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVZX r64, word ptr [base + idx]` (REX.W + 0x0F 0xB7 with
/// SIB). Zero-extends a word to 64 bits; used by i64.load16_u.
pub fn encMovzxR64_16MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), idx.extBit(), base.extBit()));
    enc.push(0x0F);
    enc.push(0xB7);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVSX r64, word ptr [base + idx]` (REX.W + 0x0F 0xBF with
/// SIB). Sign-extends a word to 64 bits; used by i64.load16_s.
pub fn encMovsxR64_16MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), idx.extBit(), base.extBit()));
    enc.push(0x0F);
    enc.push(0xBF);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVSXD r64, dword ptr [base + idx]` (REX.W + 0x63 with SIB).
/// Sign-extends a dword to 64 bits; used by i64.load32_s.
/// Counterpart of `encMovsxdR64R32` for memory-source operands.
/// (i64.load32_u uses the existing `encMovR32FromBaseIdx` because
/// MOV to r32 on x86_64 zero-extends to r64 implicitly.)
pub fn encMovsxdR64_32MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), idx.extBit(), base.extBit()));
    enc.push(0x63);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `LEA r64, [base + disp8]` (opcode 0x8D /r with REX.W,
/// ModR/M mod=01, disp8). Used by spec-strict bounds check to
/// compute `ea + access_size` into a separate scratch reg without
/// mutating `base`. disp8 covers access_size ∈ {1..8}.
///
/// **Caller constraint**: `base` must NOT be RSP (low3=0b100). With
/// mod=01 + rm=0b100 the AMD64 ISA mandates a SIB byte; this encoder
/// emits no SIB and would produce a malformed instruction. RBP is
/// safe (mod=01 always carries disp8). Current call sites pass
/// `.rdx` only.
pub fn encLeaR64BaseDisp8(dst: Gpr, base: Gpr, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), 0, base.extBit()));
    enc.push(0x8D);
    enc.push(encodeModrm(0b01, dst.low3(), base.low3()));
    enc.push(@bitCast(disp));
    return enc;
}

/// `LEA r64, [base + disp32]` (opcode 0x8D /r with REX.W,
/// ModR/M mod=10, disp32). disp32 form for offsets that exceed
/// i8 range. Win64 v128 marshal caller-side path:
/// compute `[RBP + scratch_disp]` (scratch_disp typically deep
/// in the local frame, well past i8 range) into the int-arg-reg
/// slot per Microsoft x64 ABI §"Parameter passing" hidden-
/// pointer recipe.
///
/// **Caller constraint** (same as disp8 sibling): `base` must NOT
/// be RSP (low3=0b100). RBP / R13 are safe (mod=10 disp32 form is
/// direct disp, no SIB). RSP base would mandate a SIB byte; this
/// encoder emits none and would produce a malformed instruction.
pub fn encLeaR64BaseDisp32(dst: Gpr, base: Gpr, disp: i32) EncodedInsn {
    // base.low3() != 4 (RSP) — would mandate a SIB byte; this
    // encoder emits none. Current callers pass only `.rbp`.
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), 0, base.extBit()));
    enc.push(0x8D);
    enc.push(encodeModrm(0b10, dst.low3(), base.low3()));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `LEA r64, [RSP + disp32]` (opcode 0x8D /r with REX.W,
/// ModR/M mod=10, rm=100, SIB 0x24). RSP base mandates a SIB
/// byte (rm=100 ⇒ SIB-escape per AMD64). Win64
/// v128 marshal caller-side: compute scratch slot address into
/// an int-arg register (RDX/R8/R9). Distinct encoder from
/// `encLeaR64BaseDisp32` because the latter excludes RSP base.
pub fn encLeaR64BaseRspDisp32(dst: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), 0, 0));
    enc.push(0x8D);
    enc.push(encodeModrm(0b10, dst.low3(), 0b100));
    enc.push(0x24); // SIB: scale=00, index=100 (none), base=100 (RSP)
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV BYTE PTR [base + disp32], imm8` (opcode 0xC6 /0).
/// Used by `data.drop` / `elem.drop` to write
/// `1` into the dropped-flag table.
pub fn encStoreImm8MemBaseDisp32(base: Gpr, disp: i32, imm: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (base.extBit() == 1) enc.push(encodeRex(false, 0, 0, 1));
    enc.push(0xC6);
    enc.push(encodeModrm(0b10, 0, base.low3())); // /0 in reg field
    const ud: u32 = @bitCast(disp);
    enc.push(@truncate(ud));
    enc.push(@truncate(ud >> 8));
    enc.push(@truncate(ud >> 16));
    enc.push(@truncate(ud >> 24));
    enc.push(imm);
    return enc;
}

/// `MOV DWORD PTR [base + disp32], imm32` (opcode 0xC7 /0).
/// Used by trap stub to set `JitRuntime.trap_flag = 1` per
/// ADR-0017 sub-7.5b-ii equivalent.
pub fn encStoreImm32MemDisp32(base: Gpr, disp: i32, imm: u32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (base.extBit() == 1) enc.push(encodeRex(false, 0, 0, 1));
    enc.push(0xC7);
    enc.push(encodeModrm(0b10, 0, base.low3())); // /0 in reg field
    const ud: u32 = @bitCast(disp);
    enc.push(@truncate(ud));
    enc.push(@truncate(ud >> 8));
    enc.push(@truncate(ud >> 16));
    enc.push(@truncate(ud >> 24));
    enc.push(@truncate(imm));
    enc.push(@truncate(imm >> 8));
    enc.push(@truncate(imm >> 16));
    enc.push(@truncate(imm >> 24));
    return enc;
}

/// `MOV [RBP + disp8], r32` — store the low 32 bits of `src`
/// to a stack slot at `RBP + disp`. Opcode 0x89 with mod=01
/// (disp8) + rm=5 (RBP base). REX.R for src extension only
/// (no W since 32-bit; no B since base is RBP, low reg).
pub fn encStoreR32MemRBP(disp: i8, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x89);
    enc.push(encodeModrm(0b01, src.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOV r32, [RBP + disp8]` — load the 32-bit value at
/// `RBP + disp` into `dst` (zero-extends to 64 bits per the
/// W-form). Opcode 0x8B with mod=01 + rm=5.
pub fn encLoadR32MemRBP(dst: Gpr, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x8B);
    enc.push(encodeModrm(0b01, dst.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOV [RBP + disp8], r64` — REX.W form of `encStoreR32MemRBP`
/// for i64 locals / params (chunk 7 / D-045). Opcode 0x89 with
/// REX.W set.
pub fn encStoreR64MemRBP(disp: i8, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, src.extBit(), 0, 0));
    enc.push(0x89);
    enc.push(encodeModrm(0b01, src.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOV r64, [RBP + disp8]` — REX.W form of `encLoadR32MemRBP`.
pub fn encLoadR64MemRBP(dst: Gpr, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), 0, 0));
    enc.push(0x8B);
    enc.push(encodeModrm(0b01, dst.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

// ============================================================
// RBP-relative disp32 forms (total_locals > 15
// cap expansion). The disp8 forms above are 4 bytes per
// instruction; disp32 is 7 bytes (3 extra bytes for the wider
// displacement). They share the same opcode + ModR/M shape
// (mod=10 instead of mod=01); RBP base requires no SIB byte
// (rm=101 with mod≠00 is direct disp). Used by emit.zig's
// disp32-aware wrappers when the offset exceeds i8 range.
// ============================================================

/// `MOV [RBP + disp32], r32` — disp32 form of `encStoreR32MemRBP`.
pub fn encStoreR32MemRBPDisp32(disp: i32, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x89);
    enc.push(encodeModrm(0b10, src.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV r32, [RBP + disp32]` — disp32 form of `encLoadR32MemRBP`.
pub fn encLoadR32MemRBPDisp32(dst: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x8B);
    enc.push(encodeModrm(0b10, dst.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV [RBP + disp32], r64` — disp32 form of `encStoreR64MemRBP`.
pub fn encStoreR64MemRBPDisp32(disp: i32, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, src.extBit(), 0, 0));
    enc.push(0x89);
    enc.push(encodeModrm(0b10, src.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV r64, [RBP + disp32]` — disp32 form of `encLoadR64MemRBP`.
pub fn encLoadR64MemRBPDisp32(dst: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), 0, 0));
    enc.push(0x8B);
    enc.push(encodeModrm(0b10, dst.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

// ============================================================
// RSP-relative stores (caller-side stack-arg
// lowering). RSP encodes as r/m=100 which forces a SIB byte
// regardless of mod, so RSP base requires its own encoders
// distinct from the RBP-base helpers above. SIB byte for
// "RSP base, no index" = scale=00, index=100, base=100 = 0x24.
// disp32 form is used unconditionally (5-byte vs 4-byte for
// disp8) so the outgoing-args region can grow past 127 bytes
// without needing two encoder variants — Phase 7 P3 cold-start
// over peak-throughput trade per ROADMAP §2.
// ============================================================

/// Wasm spec §3.4.7 (caller-side stack-arg) — `MOV [RSP + disp32], r32`
/// (opcode 0x89, REX.R for src extension, ModR/M mod=10 + rm=100,
/// SIB 0x24, disp32). Used by `op_call.marshalCallArgs` to write
/// overflowed i32 args into the caller's outgoing-args region at
/// `[RSP + 8 * NSAA_idx]` (SysV) or `[RSP + 8 * shared_slot]` (Win64).
pub fn encStoreR32MemRSPDisp32(src: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x89);
    enc.push(encodeModrm(0b10, src.low3(), 0b100));
    enc.push(0x24); // SIB: scale=00, index=100 (none), base=100 (RSP)
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV [RSP + disp32], r64` (REX.W form). i64 caller-side stack
/// arg analog of `encStoreR32MemRSPDisp32`.
pub fn encStoreR64MemRSPDisp32(src: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, src.extBit(), 0, 0));
    enc.push(0x89);
    enc.push(encodeModrm(0b10, src.low3(), 0b100));
    enc.push(0x24);
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}
