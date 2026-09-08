//! x86_64 control-flow + stack + integer extension encoder family
//! — Intel SDM Vol 2 §3.2 CALL/RET/JMP/Jcc/PUSH/POP/NOP/SETcc/
//! CMOVcc + Vol 2 §3.2 CDQ/CQO/IDIV/DIV + Vol 2 §3.2
//! LZCNT/TZCNT/POPCNT (BMI1 / POPCNT extensions). Includes the
//! `patchRel32` post-emit fixup helper used by linker.zig.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const std = @import("std");
const inst = @import("inst.zig");
const reg_class = @import("reg_class.zig");

const Gpr = reg_class.Gpr;
const Width = reg_class.Width;
const EncodedInsn = inst.EncodedInsn;
const Cond = inst.Cond;
const encodeRex = inst.encodeRex;
const encodeModrm = inst.encodeModrm;
const rexForRR = inst.rexForRR;

/// Common shape for the `F3 0F <opcode> /r` family used by
/// LZCNT / TZCNT / POPCNT. dst occupies ModR/M.reg and src is
/// in r/m (IMUL-style operand inversion). The mandatory 0xF3
/// prefix precedes any REX byte per AMD64 Vol.3 §1.2.6. `size`
/// = `.d` → r/m32; `.q` → r/m64 (REX.W set).
inline fn encF3_0F_RR(size: Width, opcode: u8, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (rexForRR(size, dst, src)) |rex| enc.push(rex);
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

inline fn encF3_0F_R32R(opcode: u8, dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_RR(.d, opcode, dst, src);
}

/// `SETcc r/m8` (2-byte opcode 0x0F 0x90+cc) — write 0 or 1 to
/// the low byte of `dst` based on the EFLAGS condition. ModR/M:
/// mod=11, reg=0 (always for SETcc), rm = dst.low3.
///
/// **REX is always emitted.** For R8..R15 the REX.B bit is
/// needed; for RBX/RBP/RSI/RDI any REX (including 0x40) is
/// required to access the low-byte form (BL/BPL/SIL/DIL) rather
/// than the high-byte aliases (BH/CH/DH/AH) which clash in
/// 64-bit mode.
pub fn encSetccR(cc: Cond, dst: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(false, 0, 0, dst.extBit()));
    enc.push(0x0F);
    enc.push(0x90 | @as(u8, @intFromEnum(cc)));
    enc.push(encodeModrm(0b11, 0, dst.low3()));
    return enc;
}

/// `CMOVcc r, r/m` (2-byte opcode 0x0F 0x4? /r — `?` is cc).
/// Conditional move. dst occupies ModR/M.reg, src occupies r/m
/// (IMUL-style operand inversion). `size` = `.d` → r32 (zero-
/// extends to r64); `.q` → r64 (REX.W). Used by `select` /
/// `select_typed` (D-045 chunk 8).
pub fn encCmovccRR(size: Width, cc: Cond, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, dst, src)) |rex| enc.push(rex);
    enc.push(0x0F);
    enc.push(0x40 | @as(u8, @intFromEnum(cc)));
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `CALL rel32` (opcode 0xE8) — direct call with 32-bit
/// signed displacement from the byte AFTER the disp32 (i.e.
/// the next instruction). Used by `emitCall` as a placeholder
/// (disp=0); the post-emit linker patches the disp via
/// `patchRel32` once function offsets are known.
pub fn encCallRel32(disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xE8);
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `CALL r/m64` (opcode 0xFF /2) — indirect call through a
/// 64-bit register. CALL is implicitly 64-bit on x86_64; REX.W
/// is NOT required. REX.B is set if `target` is R8..R15. Used
/// by `emitCallIndirect` after the funcptr is loaded into a
/// scratch register.
pub fn encCallReg(target: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (target.extBit() != 0) {
        enc.push(encodeRex(false, 0, 0, target.extBit()));
    }
    enc.push(0xFF);
    enc.push(encodeModrm(0b11, 2, target.low3())); // /2 = CALL
    return enc;
}

/// `Jcc rel8` (opcode 0x70+cc) — short conditional jump with
/// 8-bit signed displacement (-128..127). 2 bytes total.
/// Used by br_table to skip a single 5-byte JMP rel32 (disp = +5).
pub fn encJccRel8(cc: Cond, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x70 | @as(u8, @intFromEnum(cc)));
    enc.push(@bitCast(disp));
    return enc;
}

/// `JMP r/m64` (opcode 0xFF /4) — indirect near jump (tail-call)
/// through a 64-bit register. JMP is implicitly 64-bit on x86_64;
/// REX.W is NOT required. REX.B is set if `target` is R8..R15.
/// Per Intel SDM Vol 2 §3.2 JMP. Used by ADR-0066 cross-module
/// bridge thunks: after the caller's RIP is preserved on the
/// stack by the importer's CALL, the thunk replaces RDI with
/// the callee's JitRuntime pointer and JMPs to the callee's
/// entry — the callee's eventual RET pops the importer's RIP
/// and returns directly to the importer's call site.
pub fn encJmpReg(target: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (target.extBit() != 0) {
        enc.push(encodeRex(false, 0, 0, target.extBit()));
    }
    enc.push(0xFF);
    enc.push(encodeModrm(0b11, 4, target.low3())); // /4 = JMP
    return enc;
}

/// `JMP rel32` (opcode 0xE9) — unconditional near jump with
/// 32-bit signed displacement. Disp is relative to the byte
/// AFTER the 5-byte instruction. Use `encJmpRel32(0)` as a
/// placeholder for forward jumps that patch later via
/// `patchRel32` once the target is known.
pub fn encJmpRel32(disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xE9);
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `Jcc rel32` — conditional near jump (2-byte opcode 0x0F
/// 0x80+cc + 32-bit disp). 6 bytes total. Disp is relative to
/// the byte AFTER the instruction.
pub fn encJccRel32(cc: Cond, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x0F);
    enc.push(0x80 | @as(u8, @intFromEnum(cc)));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// In-place patch the disp32 field of a JMP/Jcc rel32 placeholder.
/// `at` is the byte offset of the instruction's first byte
/// (0xE9 for JMP or 0x0F for Jcc). `disp` is computed by the
/// caller as `target - (at + insn_size)` where insn_size is 5
/// (JMP) or 6 (Jcc). Writes 4 bytes little-endian.
pub fn patchRel32(buf: []u8, at: usize, insn_size: u8, disp: i32) void {
    const off = at + insn_size - 4;
    const u: u32 = @bitCast(disp);
    buf[off + 0] = @truncate(u);
    buf[off + 1] = @truncate(u >> 8);
    buf[off + 2] = @truncate(u >> 16);
    buf[off + 3] = @truncate(u >> 24);
}

/// `RET` near (opcode 0xC3) — pop return address from stack and
/// jump. Single byte; no operands.
pub fn encRet() EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xC3);
    return enc;
}

/// `NOP` (opcode 0x90) — single-byte no-op. Useful for
/// instruction-stream alignment (multi-byte NOPs land in a
/// later chunk).
pub fn encNop() EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x90);
    return enc;
}

/// `PUSH r64` (opcode 0x50+rd) — push a 64-bit GPR onto the
/// stack. REX.B (0x41) is needed for R8..R15. Width is implicit
/// 64-bit; no operand-size override exists for PUSH r64.
pub fn encPushR(reg: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (reg.extBit() == 1) enc.push(encodeRex(false, 0, 0, 1));
    enc.push(0x50 | @as(u8, reg.low3()));
    return enc;
}

/// `PUSH r/m64` (opcode 0xFF /6, mod=00) — push the 64-bit word at
/// `[base]`. `base` must not need a SIB byte or a displacement in the mod=00
/// form (RSP/R12 and RBP/R13 do), so it is asserted to be none of those.
/// Used by the bridge thunk's overflow-argument copy loop (ADR-0228).
pub fn encPushMem64(base: Gpr) EncodedInsn {
    std.debug.assert(base.low3() != 4 and base.low3() != 5);
    var enc: EncodedInsn = .{};
    if (base.extBit() == 1) enc.push(encodeRex(false, 0, 0, 1));
    enc.push(0xFF);
    enc.push(encodeModrm(0b00, 6, base.low3())); // /6 = PUSH
    return enc;
}

/// `POP r64` (opcode 0x58+rd) — pop a 64-bit GPR from the stack.
/// Same REX.B treatment as PUSH r64.
pub fn encPopR(reg: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (reg.extBit() == 1) enc.push(encodeRex(false, 0, 0, 1));
    enc.push(0x58 | @as(u8, reg.low3()));
    return enc;
}

/// `CDQ` (opcode 0x99) — sign-extend EAX into EDX:EAX (Intel
/// SDM Vol 2 §3.2 CDQ). One byte. Used as the dividend prep
/// step for IDIV r/m32 (signed 32-bit divide).
pub fn encCdq() EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x99);
    return enc;
}

/// `CQO` (REX.W + 0x99) — sign-extend RAX into RDX:RAX. Used as
/// the dividend prep step for IDIV r/m64.
pub fn encCqo() EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, 0)); // 0x48
    enc.push(0x99);
    return enc;
}

/// `IDIV r/m32` (opcode 0xF7 /7) — signed divide of EDX:EAX by
/// the operand; quotient → EAX, remainder → EDX. Intel SDM Vol 2
/// §3.2 IDIV. Wasm spec §4.4.1.1 (i32.div_s / i32.rem_s) —
/// caller is responsible for the divide-by-zero trap check + the
/// INT_MIN/-1 overflow check (IDIV raises #DE, but we trap via
/// the explicit pre-check so the JIT does not need a #DE
/// handler).
pub fn encIdivR32(divisor: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (divisor.extBit() != 0) {
        enc.push(encodeRex(false, 0, 0, divisor.extBit()));
    }
    enc.push(0xF7);
    enc.push(encodeModrm(0b11, 7, divisor.low3())); // /7 = IDIV
    return enc;
}

/// `DIV r/m32` (opcode 0xF7 /6) — unsigned divide of EDX:EAX by
/// operand. Wasm spec §4.4.1.1 (i32.div_u / i32.rem_u).
pub fn encDivR32(divisor: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (divisor.extBit() != 0) {
        enc.push(encodeRex(false, 0, 0, divisor.extBit()));
    }
    enc.push(0xF7);
    enc.push(encodeModrm(0b11, 6, divisor.low3())); // /6 = DIV
    return enc;
}

/// `IDIV r/m64` (REX.W + 0xF7 /7) — 64-bit signed divide.
pub fn encIdivR64(divisor: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, divisor.extBit()));
    enc.push(0xF7);
    enc.push(encodeModrm(0b11, 7, divisor.low3()));
    return enc;
}

/// `DIV r/m64` (REX.W + 0xF7 /6) — 64-bit unsigned divide.
pub fn encDivR64(divisor: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, divisor.extBit()));
    enc.push(0xF7);
    enc.push(encodeModrm(0b11, 6, divisor.low3()));
    return enc;
}

/// `LZCNT r32, r/m32` (F3 0F BD /r, BMI1) — count leading
/// zeros. Returns 32 if the input is 0; matches Wasm i32.clz
/// semantics exactly. Distinct from BSR (older op with
/// undefined behaviour at 0).
pub fn encLzcntR32(dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_R32R(0xBD, dst, src);
}

/// `TZCNT r32, r/m32` (F3 0F BC /r, BMI1) — count trailing
/// zeros. Returns 32 if the input is 0; matches Wasm i32.ctz.
/// Distinct from BSF (older op with undefined behaviour at 0).
pub fn encTzcntR32(dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_R32R(0xBC, dst, src);
}

/// `POPCNT r32, r/m32` (F3 0F B8 /r, POPCNT extension) —
/// population count (number of 1 bits). Matches Wasm i32.popcnt
/// directly.
pub fn encPopcntR32(dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_R32R(0xB8, dst, src);
}

/// `LZCNT r64, r/m64` (F3 REX.W 0F BD /r) — 64-bit form for
/// Wasm i64.clz. Returns 64 for input 0.
pub fn encLzcntR64(dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_RR(.q, 0xBD, dst, src);
}

/// `TZCNT r64, r/m64` (F3 REX.W 0F BC /r) — 64-bit form for
/// Wasm i64.ctz. Returns 64 for input 0.
pub fn encTzcntR64(dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_RR(.q, 0xBC, dst, src);
}

/// `POPCNT r64, r/m64` (F3 REX.W 0F B8 /r) — 64-bit form for
/// Wasm i64.popcnt.
pub fn encPopcntR64(dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_RR(.q, 0xB8, dst, src);
}
