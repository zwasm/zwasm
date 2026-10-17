//! x86_64 emit handler for `ref.cast` — Wasm 3.0 GC §3.3.5.4 (non-null
//! target). Mirror of the arm64 handler: pop one reftype operand (full
//! 64-bit value), trap if null OR type-mismatch, else push it back
//! UNCHANGED — via the `jitGcRefCast(rt, ref, ht)` trampoline (returns the
//! ref, or 0 on trap). Emit = 3-arg marshal + CALL + trap branch on a 0
//! result + capture the 64-bit ref. 1 → 1.
//!
//! ht is an immediate (ins.payload byte); the ref is the popped operand
//! (RSI, 64-bit), read before any argument register is written. `0` is
//! an unambiguous trap sentinel (a successful non-null cast returns a
//! non-zero ref), so `TEST RAX,RAX` (64-bit — a funcref ptr fills all 64
//! bits) + JE → trap stub is exact.
//!
//! Lowering: MOV RSI, ref ; MOV RDI, R15 (rt) ; MOV EDX = ht ; MOVABS R10
//! = &jitGcRefCast ; CALL R10 → RAX = ref/0 ; TEST RAX,RAX ; JE → trap ;
//! else capture RAX.

const meta = @import("../../../../../instruction/wasm_3_0/ref_cast.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const call_scratch: abi.Gpr = .r10; // emit scratch — &fn, then CALL target.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    // D-453: full encoded u32 (concrete-tag bit 31 | idx bits 0..29, or a
    // bare wire byte) — must NOT mask to one byte or a concrete idx ≥ 64 is
    // lost. No null flag here (the non-null target traps null in the core).
    const ht: u32 = @truncate(ins.payload);
    const args = try ctx.popUnary(); // src=ref, result=ref (unchanged on success)
    // RSI = ref (64-bit reftype value).
    const xsrc = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    if (xsrc != abi.current.arg_gprs[1]) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[1], xsrc).slice());
    // RDI = rt (R15); EDX = ht.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[0], abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(abi.current.arg_gprs[2], ht).slice());
    // MOVABS R10 = &jitGcRefCast; CALL R10.
    // ADR-0203 D1 — helper via the rt slot ([R15+off]), not a baked imm64 (D-516 PIC).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(call_scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_ref_cast_fn_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());

    // Trap on result == 0 (null / type mismatch): TEST RAX,RAX ; JE → trap.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, .rax, .rax).slice());
    const fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.cast_fail_fixups.append(ctx.allocator, fixup); // D-293 slice-4d cast_failure (code 11)

    // Capture RAX (the cast ref, full 64-bit) → result vreg.
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    if (rd != .rax) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, rd, .rax).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
