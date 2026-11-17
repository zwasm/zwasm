//! x86_64 emit handler for `struct.new_default` — Wasm 3.0 GC §3.3.13.
//! Mirror of the arm64 handler: allocate a zero-inited struct of type
//! `ins.payload` (typeidx) on the GC heap and push the GcRef. The
//! allocation (payload_size lookup + header stamp + zero-init) runs in
//! the `jitGcAlloc` trampoline — the heap may realloc its slab on grow,
//! so it MUST be a runtime call, not inlined. Non-variadic (0 operands)
//! → no field marshalling; vregs live ACROSS the CALL are force-spilled
//! via the regalloc `is_call` entry (arch-independent; shared with arm64).
//!
//! Lowering: MOV RDI, R15 (rt); MOV ESI, typeidx; MOVABS R10 =
//! &jitGcAlloc; CALL R10; capture EAX (GcRef) → result vreg. SysV:
//! arg0 = RDI, arg1 = ESI, return = EAX; R15 (pinned rt) is callee-saved
//! and survives the call. R10 is emit scratch (caller-saved, not in the
//! regalloc pool); reusing it for the result-store stage after the call
//! is safe (the call already clobbered it). Intel SDM Vol.2 (MOV 0x89,
//! MOV-imm32 0xB8, MOVABS REX.W 0xB8, CALL 0xFF /2).

const meta = @import("../../../../../instruction/wasm_3_0/struct_new_default.zig");
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

/// Emit scratch (caller-saved R10, not in the regalloc pool) — holds
/// the trampoline address for the indirect CALL.
const call_scratch: abi.Gpr = .r10;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);

    // Marshal SysV args: RDI = rt (R15), ESI = typeidx immediate.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[0], abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(abi.current.arg_gprs[1], typeidx).slice());
    // Materialise &jitGcAlloc into R10 (emit scratch) and CALL it.
    // ADR-0203 D1 — helper via the rt slot ([R15+off]), not a baked imm64 (D-516 PIC).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(call_scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_alloc_fn_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());
    // #364 — a failed alloc returns 0; trap out_of_memory before capturing EAX.
    try gc_alloc_trap.emit(ctx);

    // Capture EAX (GcRef, i32) → fresh result vreg's home (mirror
    // arm64 struct_new_default + the i31 result-vreg pattern: a 0-input
    // op allocates its own result vreg). gprDefSpilled returns the home
    // reg (or stage-0 = R10 if spilled — safe, the call clobbered R10).
    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return ctx_mod.Error.SlotOverflow;
    const rd = try gpr.gprDefSpilled(ctx.alloc, result, 0);
    // Always zero-extend EAX→RAX (a u32 C-return leaves RAX's upper 32 bits
    // unspecified): a GcRef Value fills the whole 64-bit slot, and gprStoreSpilled
    // stores 64-bit, so a `rd == rax` skip would leak stale upper bits into the
    // ref (table.set / ref.test then read `(stale<<32)|ref`). `mov eax,eax` when
    // rd==rax is a valid zero-extend.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, rd, .rax).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result);
}
