//! x86_64 emit handler for `array.init_elem` — Wasm 3.0 GC §3.3.5.6.17.
//! Mirror of the arm64 handler: pop array GcRef + i32 dst_off + i32 src_off +
//! i32 len, null-check + bounds-check + copy `len` ref Values DIRECT from
//! element segment $segidx into the existing array at dst_off inside the
//! `jitGcArrayInitElem(rt, segidx, ref, dst_off, src_off, len)` trampoline
//! (returns 1=ok / 0=trap). Emit = 6-arg marshal + CALL + trap branch on a 0
//! result. No result push (4 → 0).
//!
//! Identical marshal to array.init_data (esz=8 uniform per ADR-0116 §3a, so no
//! typeidx is needed); only the trampoline target differs. The operand fence
//! (`abi.op_regs`, ADR-0077) keeps the operands out of the argument registers.
//!
//! Lowering: MOV RDI, R15 (rt); MOV ESI, segidx; MOV EDX = ref; MOV ECX =
//! dst_off; MOV R8D = src_off; MOV R9D = len; MOVABS R10 = &jitGcArrayInitElem;
//! CALL R10 → EAX = 1/0. Then TEST EAX, EAX ; JE → trap stub.

const meta = @import("../../../../../instruction/wasm_3_0/array_init_elem.zig");
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
    const segidx: u32 = ins.extra;
    // Operand stack: [.., ref, dst_off, src_off, len] (len on top). Pop reverse.
    if (ctx.pushed_vregs.items.len < 4) return ctx_mod.Error.AllocationMissing;
    const len_vreg = ctx.pushed_vregs.pop().?;
    const src_off_vreg = ctx.pushed_vregs.pop().?;
    const dst_off_vreg = ctx.pushed_vregs.pop().?;
    const ref_vreg = ctx.pushed_vregs.pop().?;

    // Marshal user args 2..5 = ref, dst_off, src_off, len (arg 1 =
    // segidx immediate below) — all i32 (.d). SysV: arg_gprs[2..6] =
    // RDX/RCX/R8/R9 (all regs). Win64: arg_gprs[2..4] = R8/R9 →
    // src_off (arg 4) + len (arg 5) spill to [RSP+0x20]/[RSP+0x28]
    // (D-248). Operands are fenced off the arg regs (`abi.op_regs`).
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, ref_vreg, 0);
    // D-470 — inline null-ref check (→ null_reference, kind 10) before the call;
    // the residual result==0 is then only the segment/array OOB (oob_memory).
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, xref, xref).slice());
    const null_fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.null_ref_fixups.append(ctx.allocator, null_fixup);
    try gc_marshal.routeArg(ctx, 2, xref, .d);
    const xdst = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_off_vreg, 0);
    try gc_marshal.routeArg(ctx, 3, xdst, .d);
    const xsrc = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_off_vreg, 0);
    try gc_marshal.routeArg(ctx, 4, xsrc, .d);
    const xlen = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, len_vreg, 0);
    try gc_marshal.routeArg(ctx, 5, xlen, .d);

    // arg 0 = rt (R15); arg 1 = segidx immediate.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[0], abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(abi.current.arg_gprs[1], segidx).slice());
    // MOVABS R10 = &jitGcArrayInitElem; CALL R10.
    // ADR-0203 D1 — helper via the rt slot ([R15+off]), not a baked imm64 (D-516 PIC).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(call_scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_array_init_elem_fn_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());

    // Trap on result == 0 (segment/array OOB; null caught inline above):
    // TEST EAX, EAX ; JE → oob_memory stub (kind 6), matching interp.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.d, .rax, .rax).slice());
    const fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.oob_fixups.append(ctx.allocator, fixup);
    // array.init_elem is 4 → 0: no result vreg pushed.
}
