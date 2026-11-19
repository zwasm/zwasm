//! arm64 emit handler for `array.new_default` — Wasm 3.0 GC §3.3.5.6.6.
//! Pop the i32 length, allocate a zero-inited array of that length on the
//! GC heap via the `jitGcAllocArray` trampoline, push the GcRef. Unlike
//! `struct.new_default` (compile-time size), the array size depends on the
//! RUNTIME length operand → it is marshaled into arg2 (W2) before the BLR.
//! The length is CONSUMED into the arg register before the clobbering BLR
//! (not read after), so it does NOT force-spill; but `array.new_default`
//! is still a regalloc `is_call` PC so any vreg SPANNING it force-spills.
//! Zero-init happens inside the trampoline (default payload).
//!
//! Lowering (mirrors struct_new_default + table_grow operand-marshal):
//! MOV W2 = length; MOV X0, X19 (rt); MOVZ/MOVK W1 = typeidx; MOVZ/MOVK
//! X16 = &jitGcAllocArray; BLR X16; capture W0 (GcRef) → result vreg.

const meta = @import("../../../../../instruction/wasm_3_0/array_new_default.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const gc_alloc_trap = @import("gc_alloc_trap.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const scratch: inst.Xn = 16; // IP0 (AAPCS64 §6.4 caller-saved) — &fn.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);

    // args.src = length operand; args.result = the pushed GcRef.
    const args = try ctx.popUnary();
    // W2 = length (loaded + moved into arg2 BEFORE the BLR consumes it).
    const xlen = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    if (xlen != 2) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(2, 31, xlen));
    // X0 = rt (X19); W1 = typeidx.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(1, @intCast(typeidx & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(1, @intCast((typeidx >> 16) & 0xFFFF), 1));
    // MOVZ/MOVK X16 = &jitGcAllocArray; BLR X16.
    // ADR-0203 D1 — helper via the rt slot ([X19+off]), not a baked imm64 (D-516 PIC).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_alloc_array_fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));
    // #364 — a failed alloc returns 0; trap out_of_memory before capturing W0.
    try gc_alloc_trap.emit(ctx);

    // Capture W0 (GcRef) → result vreg (mirror struct_new_default).
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    if (rd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(rd, 31, 0));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
