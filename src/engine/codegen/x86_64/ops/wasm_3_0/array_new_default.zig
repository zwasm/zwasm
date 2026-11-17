//! x86_64 emit handler for `array.new_default` — Wasm 3.0 GC §3.3.5.6.6.
//! Mirror of the arm64 handler: pop the i32 length, allocate a zero-inited
//! array via the `jitGcAllocArray` trampoline, push the GcRef. The length
//! is a RUNTIME operand → marshaled into arg2 (EDX) before the CALL
//! consumes it (so it does NOT force-spill; array.new_default is still a
//! regalloc `is_call` PC for vregs that SPAN it). Zero-init in trampoline.
//!
//! Lowering: MOV EDX = length; MOV RDI, R15 (rt); MOV ESI, typeidx;
//! MOVABS R10 = &jitGcAllocArray; CALL R10; capture EAX (GcRef) → result.
//! SysV args: RDI/ESI/EDX; ret EAX; R15 (rt) callee-saved survives. Intel
//! SDM Vol.2 (MOV 0x89, MOV-imm32 0xB8, MOVABS 0xB8, CALL 0xFF /2).

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

const call_scratch: abi.Gpr = .r10; // emit scratch — &fn, then CALL target.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);

    const args = try ctx.popUnary();
    // EDX = length (loaded + moved into arg2 BEFORE R10 is reused for &fn).
    const xlen = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    if (xlen != abi.current.arg_gprs[2]) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, abi.current.arg_gprs[2], xlen).slice());
    // RDI = rt (R15); ESI = typeidx.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[0], abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(abi.current.arg_gprs[1], typeidx).slice());
    // MOVABS R10 = &jitGcAllocArray; CALL R10.
    // ADR-0203 D1 — helper via the rt slot ([R15+off]), not a baked imm64 (D-516 PIC).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(call_scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_alloc_array_fn_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());
    // #364 — a failed alloc returns 0; trap out_of_memory before capturing EAX.
    try gc_alloc_trap.emit(ctx);

    // Capture EAX (GcRef) → result vreg (mirror struct_new_default).
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    if (rd != .rax) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, rd, .rax).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
