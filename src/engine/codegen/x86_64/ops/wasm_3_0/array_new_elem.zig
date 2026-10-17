//! x86_64 emit handler for `array.new_elem` — Wasm 3.0 GC §3.3.5.6.8.
//! Mirror of the arm64 handler: pop i32 offset + i32 size, alloc a
//! `size`-element array and copy `size` ref Values from element segment
//! `ins.extra` starting at `offset` inside the `jitGcArrayNewElem(rt,
//! typeidx, segidx, offset, size)` trampoline (returns the GcRef, or 0 on
//! trap). Emit = 5-arg marshal + CALL + trap branch on a 0 result +
//! capture the ref. 2 → 1.
//!
//! Trivial variant of `array.new_data`: the trampoline copies each entry
//! DIRECT (already a u64 `Value.ref`; no LE-unpack), reusing table.init's
//! elem_segments_ptr plumbing. typeidx + segidx are immediates (ESI/EDX);
//! offset + size are the popped operands (ECX/R8D), fenced off the arg regs
//! (`abi.op_regs`, ADR-0077).
//!
//! Lowering: MOV ECX = offset; MOV R8D = size; MOV RDI, R15 (rt); MOV ESI =
//! typeidx; MOV EDX = segidx; MOVABS R10 = &jitGcArrayNewElem; CALL R10 →
//! EAX = ref/0. TEST EAX, EAX ; JE → trap stub; else capture EAX.

const meta = @import("../../../../../instruction/wasm_3_0/array_new_elem.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const gc_marshal = @import("gc_marshal.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const call_scratch: abi.Gpr = .r10; // emit scratch — &fn, then CALL target.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);
    const segidx: u32 = ins.extra;
    const args = try ctx.popBinary(); // lhs=offset, rhs=size, result=ref
    // Marshal user args 3..4 = offset, size (args 1/2 = typeidx/segidx
    // immediates below) — all i32 (.d). SysV: arg_gprs[3..5] = RCX/R8
    // (regs). Win64: arg_gprs[3] = R9 → size (arg 4) spills to
    // [RSP+0x20] (D-248). Operands are fenced off the arg regs.
    const xoff = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    try gc_marshal.routeArg(ctx, 3, xoff, .d);
    const xsize = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    try gc_marshal.routeArg(ctx, 4, xsize, .d);
    // arg 0 = rt (R15); arg 1 = typeidx; arg 2 = segidx (immediates).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[0], abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(abi.current.arg_gprs[1], typeidx).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(abi.current.arg_gprs[2], segidx).slice());
    // MOVABS R10 = &jitGcArrayNewElem; CALL R10.
    // ADR-0203 D1 — helper via the rt slot ([R15+off]), not a baked imm64 (D-516 PIC).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(call_scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_array_new_elem_fn_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());

    // Trap on result == 0 (segment OOB): TEST EAX, EAX ; JE → oob_memory stub
    // (kind 6), matching interp Trap.OutOfBoundsLoad — not the generic bucket.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.d, .rax, .rax).slice());
    const fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.oob_fixups.append(ctx.allocator, fixup);

    // Capture EAX (GcRef) → result vreg.
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    if (rd != .rax) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, rd, .rax).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
