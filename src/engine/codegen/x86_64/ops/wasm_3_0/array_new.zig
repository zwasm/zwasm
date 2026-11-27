//! x86_64 emit handler for `array.new` — Wasm 3.0 GC §3.3.5.6.6.
//! Mirror of the arm64 handler: pop i32 length (top) + init value,
//! allocate + fill via the `jitGcAllocArrayFill(rt, typeidx, length,
//! init)` trampoline (runtime element count → fill inside the trampoline,
//! not an emitted loop), push the GcRef. Both operands consumed into arg
//! regs BEFORE the CALL (length → EDX, init → RCX) → strict `is_call`.
//!
//! NOTE: init marshaled into RCX — from a GPR for i32/i64/ref, and from the
//! XMM file (MOVD/MOVQ) for an f32/f64 element (D-212, as array.set reads it).
//! SysV args RDI/ESI/EDX/RCX; ret EAX. Intel SDM Vol.2 (MOV 0x89, MOVD/MOVQ
//! 66 0F 7E, MOVABS 0xB8, CALL 0xFF /2).

const meta = @import("../../../../../instruction/wasm_3_0/array_new.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const gc_alloc_trap = @import("gc_alloc_trap.zig");
const decline_note = @import("../../../shared/decline_note.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const call_scratch: abi.Gpr = .r10; // emit scratch — &fn, then CALL target.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);
    const elem_vt = ctx.func.arrayElemValType(typeidx); // D-212
    // D-495 — the fill marshals the init through a u64, so a v128 (16-byte)
    // element has no path: jitGcAllocArrayFill returns 0 (esz>8) and #364's
    // zero-check would surface it as out_of_memory, which it is not. Decline
    // instead, so the default engine runs it on the interpreter.
    if (elem_vt == 0x7B) {
        decline_note.set("array.new", .v128_array_element);
        return ctx_mod.Error.UnsupportedOp;
    }
    const args = try ctx.popBinary(); // lhs=init, rhs=length (top), result=ref
    // EDX = length (rhs).
    const xsize = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 0);
    if (xsize != abi.current.arg_gprs[2]) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, abi.current.arg_gprs[2], xsize).slice());
    // RCX = init. An f32/f64 init lives in the XMM file (D-212), so MOVD/MOVQ
    // its bits straight into the arg GPR; i32/i64/ref come from a GPR. The
    // helper writes the low `esz` bytes, so the low 32 (f32) / 64 (f64) suffice.
    switch (elem_vt) {
        0x7D, 0x7C => {
            const xv = try gpr.xmmLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
            if (elem_vt == 0x7D)
                try ctx.buf.appendSlice(ctx.allocator, inst.encMovdR32FromXmm(abi.current.arg_gprs[3], xv).slice())
            else
                try ctx.buf.appendSlice(ctx.allocator, inst.encMovqR64FromXmm(abi.current.arg_gprs[3], xv).slice());
        },
        else => {
            const xinit = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 1);
            if (xinit != abi.current.arg_gprs[3]) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[3], xinit).slice());
        },
    }
    // RDI = rt (R15); ESI = typeidx.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[0], abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(abi.current.arg_gprs[1], typeidx).slice());
    // MOVABS R10 = &jitGcAllocArrayFill; CALL R10.
    // ADR-0203 D1 — helper via the rt slot ([R15+off]), not a baked imm64 (D-516 PIC).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(call_scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_alloc_array_fill_fn_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());
    // #364 — a failed alloc returns 0; trap out_of_memory before capturing EAX.
    try gc_alloc_trap.emit(ctx);

    // Capture EAX (GcRef) → result vreg.
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    if (rd != .rax) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, rd, .rax).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
