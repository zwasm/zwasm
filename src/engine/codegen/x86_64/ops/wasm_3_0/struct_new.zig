//! x86_64 emit handler for `struct.new` — Wasm 3.0 GC §3.3.5.6.1.
//! Mirror of the arm64 handler: allocate a struct of type `ins.payload`
//! (typeidx) on the GC heap, store the `ins.extra` field operands
//! (popped in declared order) into the payload, and push the GcRef. The
//! alloc (payload_size lookup + header stamp) runs in the `jitGcAlloc`
//! trampoline — the heap may realloc its slab on grow, so the slab base
//! is RE-loaded AFTER the call.
//!
//! Field operands are force-spilled across the alloc CALL (ADR-0060
//! amendment, arch-independent regalloc), so each value lives in its
//! spill slot and is loaded via gprLoadSpilled (stage-0 = R10).
//!
//! Lowering: MOV RDI, R15 (rt); MOV ESI, typeidx; MOVABS R10 =
//! &jitGcAlloc; CALL R10 → EAX = GcRef. Then MOV R10D, EAX (zero-extend
//! ref); R11 = [[R15 + gc_heap_off] + offsetOf(Heap,bytes)] (slab base);
//! ADD R11, R10 (object base = slab + ref). For each field j: load value
//! (stage-0 = R10) ; MOV [R11 + (8 + j*8)], value (64-bit). EAX is
//! untouched by the field loop, so the result is captured from EAX last.
//! Field slots uniform 8-byte (ADR-0116 §3a). SysV: arg0=RDI, arg1=ESI,
//! ret=EAX; R15 (rt) callee-saved survives. Intel SDM Vol.2 (MOV 0x89/
//! 0x8B, MOVABS 0xB8, CALL 0xFF /2, ADD 0x01).

const meta = @import("../../../../../instruction/wasm_3_0/struct_new.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const gc_alloc_trap = @import("gc_alloc_trap.zig");
const heap_mod = @import("../../../../../feature/gc/heap.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

/// ObjectHeader bytes; uniform 8-byte field slots follow (ADR-0116 §3a).
const header_size: u32 = 8;
/// Emit scratch (caller-saved R10) — trampoline addr, then the
/// zero-extended ref (consumed into the object base), then the
/// gprLoadSpilled stage-0 field-value reg in the store loop.
const call_scratch: abi.Gpr = .r10;
/// Object-base scratch (emit stage-1 = R11; not in the regalloc pool).
/// Disjoint from gprLoadSpilled stage-0 (R10), so the field-value load
/// never clobbers the base.
const base_reg: abi.Gpr = .r11;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);
    const field_count: u32 = ins.extra;
    if (ctx.pushed_vregs.items.len < field_count) return ctx_mod.Error.AllocationMissing;

    // Alloc: RDI = rt (R15), ESI = typeidx, CALL &jitGcAlloc → EAX = ref.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[0], abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(abi.current.arg_gprs[1], typeidx).slice());
    // ADR-0203 D1 — helper via the rt slot ([R15+off]), not a baked imm64 (D-516 PIC).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(call_scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_alloc_fn_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());
    // #364 — a failed alloc returns 0; trap out_of_memory before using the ref.
    try gc_alloc_trap.emit(ctx);

    // Object base R11 = slab + ref (slab base re-loaded post-call). MOV
    // R10D, EAX zero-extends the u32 ref into R10 before the 64-bit ADD.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, call_scratch, .rax).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(base_reg, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(base_reg, base_reg, @offsetOf(heap_mod.Heap, "bytes")).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, base_reg, call_scratch).slice());

    // Store fields. Operand stack top = last field (field_count-1); pop
    // in reverse so the bottom-most operand lands in field 0.
    var j: u32 = field_count;
    while (j > 0) {
        j -= 1;
        const fvreg = ctx.pushed_vregs.pop().?;
        // D-460: running-sum offset (v128 fields are 16 bytes); mirrors arm64.
        const field_off: u32 = header_size + ctx.func.structFieldByteOffset(typeidx, j);
        if (ctx.func.structFieldValType(typeidx, j) == 0x7B) {
            // v128 field: 16-byte MOVUPS store. base_reg is reused across
            // stores; MOVUPS addresses [base_reg + field_off] directly.
            const xv = try gpr.xmmLoadSpilledV128(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, fvreg, 0);
            try ctx.buf.appendSlice(ctx.allocator, inst.encMovupsXmmMemBaseDisp32(true, xv, base_reg, @intCast(field_off)).slice());
        } else {
            const valreg = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, fvreg, 0);
            try ctx.buf.appendSlice(ctx.allocator, inst.encStoreR64MemDisp32(valreg, base_reg, @intCast(field_off)).slice());
        }
    }

    // Push ref (result) — EAX still holds it (the field loop touches only
    // R10/R11/mem). Mirror struct_new_default's EAX capture.
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
