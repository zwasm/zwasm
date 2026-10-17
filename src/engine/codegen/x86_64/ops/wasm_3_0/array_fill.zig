//! x86_64 emit handler for `array.fill` — Wasm 3.0 GC §3.3.5.6.14.
//! Mirror of the arm64 handler: pop array GcRef + i32 index + value +
//! i32 count, null-check + bounds-check + fill inside the
//! `jitGcArrayFill(rt, typeidx, ref, idx, value, count)` trampoline
//! (returns 1=ok / 0=trap). Emit = 6-arg marshal + CALL + trap branch on
//! a 0 result. No result push (4 → 0).
//!
//! All four operands consumed into arg regs BEFORE the CALL (strict
//! `is_call`). The operand fence (`abi.op_regs`, ADR-0077) keeps the
//! operands out of the argument registers, so marshalling each one
//! (gprLoadSpilled stage R10/R11 → MOV arg) cannot clobber another
//! operand's source.
//!
//! Lowering: MOV RDI, R15 (rt); MOV ESI, typeidx; MOV EDX = ref; MOV ECX =
//! idx; MOV R8 = value; MOV R9 = count; MOVABS R10 = &jitGcArrayFill; CALL
//! R10 → EAX = 1/0. Then TEST EAX, EAX ; JE → trap stub (null/OOB). Intel
//! SDM Vol.2 (MOV 0x89, MOVABS 0xB8, CALL 0xFF /2, TEST 0x85, Jcc 0x0F 0x84).

const meta = @import("../../../../../instruction/wasm_3_0/array_fill.zig");
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
    // Operand stack: [.., ref, idx, value, count] (count on top). Pop reverse.
    if (ctx.pushed_vregs.items.len < 4) return ctx_mod.Error.AllocationMissing;
    const count_vreg = ctx.pushed_vregs.pop().?;
    const value_vreg = ctx.pushed_vregs.pop().?;
    const idx_vreg = ctx.pushed_vregs.pop().?;
    const ref_vreg = ctx.pushed_vregs.pop().?;

    // Marshal user args 2..5 = ref, idx, value(.q!), count (arg 1 =
    // typeidx immediate below). SysV: arg_gprs[2..6] = RDX/RCX/R8/R9
    // (all regs). Win64: arg_gprs[2..4] = R8/R9 → value (arg 4) +
    // count (arg 5) spill to [RSP+0x20]/[RSP+0x28] (D-248). `value`
    // is 64-bit (.q); the rest i32 (.d). gprLoadSpilled stage =
    // R10/R11; operands are fenced off the arg regs (`abi.op_regs`).
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, ref_vreg, 0);
    try gc_marshal.routeArg(ctx, 2, xref, .d);
    const xidx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_vreg, 0);
    try gc_marshal.routeArg(ctx, 3, xidx, .d);
    const xval = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 0);
    try gc_marshal.routeArg(ctx, 4, xval, .q);
    const xcount = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, count_vreg, 0);
    try gc_marshal.routeArg(ctx, 5, xcount, .d);

    // arg 0 = rt (R15); arg 1 = typeidx immediate.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[0], abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(abi.current.arg_gprs[1], typeidx).slice());
    // MOVABS R10 = &jitGcArrayFill; CALL R10.
    // ADR-0203 D1 — helper via the rt slot ([R15+off]), not a baked imm64 (D-516 PIC).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(call_scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_array_fill_fn_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());

    // EAX: 1=ok, 0=OOB, 2=ARRAY_NULL_SENTINEL (D-293 array_oob). CMP EAX,2 ; JE →
    // null_reference (10); TEST EAX,EAX ; JE → oob_memory (6); else (1) proceed.
    try ctx.buf.appendSlice(ctx.allocator, inst.encCmpRImm8(.d, .rax, jit_abi.ARRAY_NULL_SENTINEL).slice());
    var fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.null_ref_fixups.append(ctx.allocator, fixup);
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.d, .rax, .rax).slice());
    fixup = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.oob_fixups.append(ctx.allocator, fixup);
    // array.fill is 4 → 0: no result vreg pushed.
}
