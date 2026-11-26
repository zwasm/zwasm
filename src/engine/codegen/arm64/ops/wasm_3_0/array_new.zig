//! arm64 emit handler for `array.new` — Wasm 3.0 GC §3.3.5.6.6.
//! Pop the i32 length (stack top) + the init value, allocate an array of
//! that length and fill every element with the init value, push the
//! GcRef. The element count is RUNTIME, so the fill runs inside the
//! `jitGcAllocArrayFill(rt, typeidx, length, init)` trampoline (mirrors
//! the interp arrayNew) — the per-arch emit stays a plain marshal+CALL
//! (no emitted loop). Both operands are consumed into arg registers
//! BEFORE the BLR (length → W2, init → X3), so neither force-spills
//! (strict `is_call`; only vregs SPANNING it do).
//!
//! NOTE: the init is marshaled from a GPR (`MOV X3, Xinit`) — correct for
//! i32/i64/ref element arrays; f32/f64 and v128 element arrays decline to the
//! interpreter (see emit; an FP marshal via FMOV is the post-release option).
//!
//! Lowering: MOV W2 = length; MOV X3 = init; MOV X0, X19 (rt); MOVZ/MOVK
//! W1 = typeidx; MOVZ/MOVK X16 = &jitGcAllocArrayFill; BLR X16; W0 → ref.

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

const scratch: inst.Xn = 16; // IP0 — &fn.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);
    // D-495 — the fill marshals the init through a GPR, so a v128 (16-byte)
    // element has no path: jitGcAllocArrayFill returns 0 (esz>8) and #364's
    // zero-check would surface it as out_of_memory, which it is not. Decline
    // instead, so the default engine runs it on the interpreter.
    const elem_vt = ctx.func.arrayElemValType(typeidx);
    if (elem_vt == 0x7B) {
        decline_note.set("array.new", .v128_array_element);
        return ctx_mod.Error.UnsupportedOp;
    }
    // f32 (0x7D) / f64 (0x7C): the init below is marshaled through a GPR, but an
    // f32/f64 init sits in an FP register, so the GPR load is of the wrong bits.
    // Decline (the interpreter fills it), as for a v128 element above.
    if (elem_vt == 0x7D or elem_vt == 0x7C) {
        decline_note.set("array.new", .fp_array_element);
        return ctx_mod.Error.UnsupportedOp;
    }
    // args.lhs = init value; args.rhs = i32 length (stack top); result = ref.
    const args = try ctx.popBinary();
    // W2 = length (rhs); X3 = init (lhs, full 8-byte value bits).
    const xsize = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 0);
    if (xsize != 2) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(2, 31, xsize));
    const xinit = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 1);
    if (xinit != 3) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(3, 31, xinit));
    // X0 = rt; W1 = typeidx.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(1, @intCast(typeidx & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(1, @intCast((typeidx >> 16) & 0xFFFF), 1));
    // MOVZ/MOVK X16 = &jitGcAllocArrayFill; BLR X16.
    // ADR-0203 D1 — helper via the rt slot ([X19+off]), not a baked imm64 (D-516 PIC).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_alloc_array_fill_fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));
    // #364 — a failed alloc returns 0; trap out_of_memory before capturing W0.
    try gc_alloc_trap.emit(ctx);

    // Capture W0 (GcRef) → result vreg.
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    if (rd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(rd, 31, 0));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
