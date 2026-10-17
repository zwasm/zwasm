//! x86_64 emit handler for `array.get` — Wasm 3.0 GC §3.3.5.6.10.
//! Mirror of the arm64 handler: pop i32 index + array GcRef (trap null OR
//! index OOB), load the 8-byte element at `base + 12 + index*8`, push it.
//! Element offset is RUNTIME + 4-mod-8 → register-offset MOV (base+=12
//! first). A single UNSIGNED compare `index >= length` (JAE) also catches
//! a negative index. null → `null_ref_fixups` (code 10), OOB → `oob_fixups`
//! (code 6) per D-293 slice-4c (NOT the generic bounds_fixups).
//!
//! Registers: ref → stage-0 (R10), index → stage-1 (R11). The object base
//! needs a 3rd reg while both ref and index are live → RAX (caller-saved,
//! outside the regalloc pool, not rt R15). R10 is reused
//! for the length after ref is consumed into the base. Intel SDM Vol.2
//! (TEST 0x85, MOV 0x8B, ADD 0x01/0x81, CMP 0x39, JE/JAE 0x0F 0x84/0x83).

const meta = @import("../../../../../instruction/wasm_3_0/array_get.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const heap_mod = @import("../../../../../feature/gc/heap.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const header_size: i32 = 12; // ObjectHeader (8) + length:u32 (4).
const length_off: i32 = 8;
const base: abi.Gpr = .rax; // object-base scratch (3rd reg; caller-saved).
const len_scratch: abi.Gpr = .r10; // stage-0 reused for length.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    // D-212 — element valtype selects the result register class (FP for
    // f32/f64; the GPR-only load left the value in a GPR while the f32
    // consumer reads the XMM home → stale).
    const elem_vt = ctx.func.arrayElemValType(@intCast(ins.payload));
    const args = try ctx.popBinary(); // lhs=ref, rhs=index, result=element
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const xidx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    // Null-ref trap.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, xref, xref).slice());
    var fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.null_ref_fixups.append(ctx.allocator, fixup); // D-293 slice-4c null_reference (code 10)

    // base = slab + ref; length [base+8] → R10 (ref dead).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(base, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(base, base, @offsetOf(heap_mod.Heap, "bytes")).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, base, xref).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR32FromMemDisp32(len_scratch, base, length_off).slice());
    // OOB trap: CMP index, length ; JAE (unsigned >=) → trap stub.
    try ctx.buf.appendSlice(ctx.allocator, inst.encCmpRR(.d, xidx, len_scratch).slice());
    fixup = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.ae, 0).slice());
    try ctx.oob_fixups.append(ctx.allocator, fixup); // D-293 slice-4c array index OOB → oob_memory (code 6)

    // base += header → element[0]; MOV element[index] (8-byte slot).
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddR64Imm32(base, header_size).slice());
    switch (elem_vt) {
        0x7D, 0x7C => {
            // FP element: load the 8-byte slot into a scratch GPR (R10,
            // dead after the OOB check) then MOVD/MOVQ into the XMM result.
            try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromBaseIdxLsl3(len_scratch, base, xidx).slice());
            const xd = try gpr.xmmDefSpilled(ctx.alloc, args.result, 0);
            if (elem_vt == 0x7D)
                try ctx.buf.appendSlice(ctx.allocator, inst.encMovdXmmFromR32(xd, len_scratch).slice())
            else
                try ctx.buf.appendSlice(ctx.allocator, inst.encMovqXmmFromR64(xd, len_scratch).slice());
            try gpr.xmmStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
        },
        0x7B => {
            // v128 (D-460): 16-byte element. SIB scale tops out at 8, so
            // scale the index by 16 (idx<<4) into R10 (length, dead after
            // the OOB check), then MOVUPS [base + R10].
            try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, len_scratch, xidx).slice());
            try ctx.buf.appendSlice(ctx.allocator, inst.encShlRImm8(.q, len_scratch, 4).slice());
            const xd = try gpr.xmmDefSpilledV128(ctx.alloc, args.result, 0);
            try ctx.buf.appendSlice(ctx.allocator, inst.encMovupsMemBaseIdx(false, xd, base, len_scratch).slice());
            try gpr.xmmStoreSpilledV128(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
        },
        else => {
            const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
            try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromBaseIdxLsl3(rd, base, xidx).slice());
            try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
        },
    }
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
