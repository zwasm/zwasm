//! arm64 emit handler for `struct.new_default` — Wasm 3.0 GC §3.3.13.
//! Allocate a zero-inited struct of type `ins.payload` (typeidx) on
//! the GC heap and push the GcRef. The allocation (payload_size
//! lookup + header stamp + zero-init) runs in the `jitGcAlloc`
//! trampoline — the heap may realloc its slab on grow, so it MUST be
//! a runtime call, not inlined. Non-variadic (0 operands) → no field
//! marshalling; vregs live ACROSS the BLR force-spill via the
//! regalloc `is_call` entry (regalloc_compute.zig).
//!
//! Lowering (mirrors throw.zig address-materialise + table_grow.zig
//! result-capture): MOV X0, X19 (rt); MOVZ/MOVK W1 = typeidx;
//! MOVZ/MOVK X16 = &jitGcAlloc; BLR X16; capture W0 (GcRef) →
//! result vreg. AAPCS64: X16 = IP0 (caller-saved scratch); X19
//! (pinned rt) survives the BLR. The GcRef (u32) is `.scalar`/GPR.

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

const scratch: inst.Xn = 16; // IP0 (AAPCS64 §6.4 caller-saved).

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);

    // X0 = rt (the pinned runtime ptr, X19).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    // W1 = typeidx.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(1, @intCast(typeidx & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(1, @intCast((typeidx >> 16) & 0xFFFF), 1));
    // MOVZ/MOVK X16 = &jitGcAlloc; BLR X16.
    // ADR-0203 D1 — helper via the rt slot ([X19+off]), not a baked imm64 (D-516 PIC).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_alloc_fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));
    // #364 — a failed alloc returns 0; trap out_of_memory before capturing W0.
    try gc_alloc_trap.emit(ctx);

    // Capture W0 (GcRef) → result vreg (mirror op_table.emitTableGrow).
    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return ctx_mod.Error.SlotOverflow;
    switch (ctx.alloc.slot(result, .gpr)) {
        .reg => |id| {
            const wd = abi.slotToReg(id) orelse return ctx_mod.Error.SlotOverflow;
            if (wd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(wd, 31, 0));
        },
        .spill => |off| {
            const abs_off: u32 = ctx.spill_base_off + off;
            if (abs_off > 32760) return ctx_mod.Error.SlotOverflow;
            // A GcRef Value is a clean zero-extended u32 (ADR-0116, null_ref=0);
            // a 64-bit consumer (table.set / ref.test callout) reads the WHOLE
            // slot. jitGcAlloc returns the ref in W0 with X0's upper bits
            // unspecified, so STR W would leave the slot's high half stale →
            // `(stale<<32)|ref`. Zero-extend W0 into X0 then STR X (full 64-bit).
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(0, 31, 0));
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(0, 31, @intCast(abs_off)));
        },
    }
    try ctx.pushed_vregs.append(ctx.allocator, result);
}
