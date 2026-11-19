//! arm64 emit handler for `array.new_fixed` — Wasm 3.0 GC §3.3.5.6.8.
//! Allocate a length-N array of type `ins.payload` (typeidx) on the GC
//! heap (N = `ins.extra`, the compile-time element count), store the N
//! field operands (popped from the stack, in declared order) into the
//! payload, and push the GcRef. Variadic mirror of `struct.new`; the only
//! shape differences are the array header (12 bytes vs struct's 8) and the
//! length-carrying alloc trampoline `jitGcAllocArray(rt, typeidx, N)` (N
//! marshaled into arg2 because the array size depends on the element
//! count, vs struct's compile-time payload_size). Allocation runs in the
//! trampoline (zero-inits the payload); the slab may realloc on grow, so
//! the slab base is RE-loaded AFTER the call.
//!
//! Element operands are read AFTER the alloc BLR (stored into the fresh
//! object), so the regalloc force-spills any vreg whose last_use is the
//! array.new_fixed PC (ADR-0060 inclusive `is_call`) — each element value
//! lives in its spill slot and is loaded back via gprLoadSpilled. (A value
//! left in a caller-saved register would be clobbered by the alloc BLR.)
//!
//! Lowering: MOVZ/MOVK W2 = N; MOV X0, X19 (rt); MOVZ/MOVK W1 = typeidx;
//! MOVZ/MOVK X16 = &jitGcAllocArray; BLR X16 → W0 = GcRef. Then MOV W17, W0
//! (zero-extend ref — a u32-returning call leaves X0's upper bits
//! unspecified); reload slab base X16 = [[X19,#gc_heap_off],
//! #offsetOf(Heap,bytes)]; ADD X16, X16, X17 (object base = slab + ref);
//! ADD X16, X16, #12 (element[0] addr — header is 12 bytes, so the scaled
//! 8-byte STR can't reach element[0] at the unaligned +12 directly; bias
//! the base instead). For each element i: load value (stage X14); STR X,
//! [X16, #(i*8)]. Push ref. Element slots are uniform 8-byte (ADR-0116
//! §3a). Encoders: Arm IHI 0055 §C6.2.179 (MOVZ/MOVK), §C6.2.34 (BLR),
//! §C6.2.131 (LDR imm), §C6.2.4 (ADD reg/imm), §C6.2.273 (STR imm).

const meta = @import("../../../../../instruction/wasm_3_0/array_new_fixed.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const inst_neon = @import("../../inst_neon.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const gc_alloc_trap = @import("gc_alloc_trap.zig");
const heap_mod = @import("../../../../../feature/gc/heap.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

/// ArrayHeader bytes (ObjectHeader 8 + length:u32 4); uniform 8-byte
/// element slots follow at offset 12 (ADR-0116 §3a).
const header_size: u32 = 12;
/// IP0 (AAPCS64 §6.4 caller-saved) — &jitGcAllocArray, then element base.
/// Disjoint from the regalloc pool + spill-stage regs {X14,X15}.
const fn_scratch: inst.Xn = 16;
/// IP1 (AAPCS64 §6.4 caller-saved) — zero-extended GcRef, preserved
/// across the element stores. Also disjoint from pool + stage regs.
const ref_reg: inst.Xn = 17;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);
    const n: u32 = ins.extra;
    if (ctx.pushed_vregs.items.len < n) return ctx_mod.Error.AllocationMissing;

    // Alloc: W2 = N (length); X0 = rt (pinned X19); W1 = typeidx.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(2, @intCast(n & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(2, @intCast((n >> 16) & 0xFFFF), 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(1, @intCast(typeidx & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(1, @intCast((typeidx >> 16) & 0xFFFF), 1));
    // ADR-0203 D1 — helper via the rt slot ([X19+off]), not a baked imm64 (D-516 PIC).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(fn_scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_alloc_array_fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(fn_scratch));
    // #364 — a failed alloc returns 0; trap out_of_memory before using the ref.
    try gc_alloc_trap.emit(ctx);

    // W17 = zero-extended ref; element base X16 = slab + ref + 12 (slab
    // base re-loaded post-call because alloc may have realloc-moved it).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(ref_reg, 31, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(fn_scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(fn_scratch, fn_scratch, @offsetOf(heap_mod.Heap, "bytes")));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(fn_scratch, fn_scratch, ref_reg));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(fn_scratch, fn_scratch, @intCast(header_size)));

    // Store elements. Operand stack top = last element (N-1); pop in
    // reverse so the bottom-most operand lands in element 0 (offset 0,
    // i.e. base+12). Offset i*8 is 8-byte aligned → scaled STR is valid.
    // D-460: a v128 element is a 16-byte slot (STR Q); stride is 16 not 8.
    const elem_vt = ctx.func.arrayElemValType(typeidx);
    var i: u32 = n;
    while (i > 0) {
        i -= 1;
        const evreg = ctx.pushed_vregs.pop().?;
        if (elem_vt == 0x7B) {
            // v128: STR Q. fn_scratch (element base) is reused across stores,
            // so compute the element address into X15 (a GPR stage reg, free
            // here — the value uses the FP stage) then STR Q [X15, #0]. Mirror
            // struct.new's v128 store.
            const elem_off: u32 = i * 16;
            if (elem_off > 4095) return ctx_mod.Error.SlotOverflow;
            const vs = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, evreg, 0);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(15, fn_scratch, @intCast(elem_off)));
            try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encStrQImm(vs, 15, 0));
        } else {
            const vreg_reg = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, evreg, 0);
            const elem_off: u32 = i * 8;
            if (elem_off > 32760) return ctx_mod.Error.SlotOverflow;
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(vreg_reg, fn_scratch, @intCast(elem_off)));
        }
    }

    // Push ref (result) — source from W17 (mirror struct.new).
    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return ctx_mod.Error.SlotOverflow;
    switch (ctx.alloc.slot(result, .gpr)) {
        .reg => |id| {
            const wd = abi.slotToReg(id) orelse return ctx_mod.Error.SlotOverflow;
            if (wd != ref_reg) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(wd, 31, ref_reg));
        },
        .spill => |off| {
            const abs_off: u32 = ctx.spill_base_off + off;
            if (abs_off > 32760) return ctx_mod.Error.SlotOverflow;
            // STR X (not W): a GcRef Value occupies the full 64-bit slot (a
            // 64-bit consumer like table.set reads it whole). ref_reg is already
            // zero-extended; STR W would leave the slot's high half stale.
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(ref_reg, 31, @intCast(abs_off)));
        },
    }
    try ctx.pushed_vregs.append(ctx.allocator, result);
}
