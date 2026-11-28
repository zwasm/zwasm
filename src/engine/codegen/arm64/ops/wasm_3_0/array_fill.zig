//! arm64 emit handler for `array.fill` — Wasm 3.0 GC §3.3.5.6.14.
//! Pop the array GcRef + i32 index + value + i32 count (count on top),
//! null-check + bounds-check + fill `count` slots from `index` with
//! `value`. The bounds-check + fill run inside the `jitGcArrayFill(rt,
//! typeidx, ref, idx, value, count)` trampoline (returns 1=ok / 0=trap),
//! so the per-arch emit is a plain 6-arg marshal + CALL + a trap branch
//! on a 0 result. No result push (4 → 0).
//!
//! All four operands are consumed into arg registers BEFORE the BLR (so
//! `array.fill` is a strict `is_call`; only vregs SPANNING it spill).
//! The arg registers X0..X5 are NOT in the regalloc allocatable pool, so
//! marshalling each operand (gprLoadSpilled stage → MOV arg) cannot
//! clobber another operand's source — no parallel-move hazard.
//!
//! Lowering: MOV X0, X19 (rt); MOVZ/MOVK W1 = typeidx; MOV W2 = ref;
//! MOV W3 = idx; MOV X4 = value; MOV W5 = count; MOVZ/MOVK X16 =
//! &jitGcArrayFill; BLR X16 → W0 = 1/0. Then CMP W0, #0 ; B.EQ → trap
//! stub (null/OOB). Encoders: Arm IHI 0055 §C6.2.34 (BLR), §C6.2.179
//! (MOVZ/MOVK), §C6.2.207 (ORR/MOV reg), §C6.2.65 (CMP imm), §C6.2.27 (B.cond).

const meta = @import("../../../../../instruction/wasm_3_0/array_fill.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const inst_fp = @import("../../inst_fp.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const scratch: inst.Xn = 16; // IP0 — &jitGcArrayFill.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);
    const elem_vt = ctx.func.arrayElemValType(typeidx); // D-212
    // Operand stack: [.., ref, idx, value, count] (count on top). Pop reverse.
    if (ctx.pushed_vregs.items.len < 4) return ctx_mod.Error.AllocationMissing;
    const count_vreg = ctx.pushed_vregs.pop().?;
    const value_vreg = ctx.pushed_vregs.pop().?;
    const idx_vreg = ctx.pushed_vregs.pop().?;
    const ref_vreg = ctx.pushed_vregs.pop().?;

    // Marshal each operand into its arg reg (W2=ref, W3=idx, X4=value,
    // W5=count). Each loads into stage-0 (or returns a pool reg) then MOVs
    // to the arg; arg regs ∉ pool, so no source is clobbered.
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, ref_vreg, 0);
    if (xref != 2) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(2, 31, xref));
    const xidx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_vreg, 0);
    if (xidx != 3) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(3, 31, xidx));
    // X4 = value. An f32/f64 value lives in the FP class (D-212). In an FP
    // register: FMOV its bits into W4 (f32, zero-extends) / X4 (f64). Spilled:
    // load the bits straight from the slot into W4/X4 with the large-offset-safe
    // GPR frame load — the GPR loader, not fpLoadSpilled, so this path carries no
    // 32,760-byte frame bound. i32/i64/ref come from a GPR.
    switch (elem_vt) {
        0x7D, 0x7C => {
            const is_w = elem_vt == 0x7D;
            switch (ctx.alloc.slot(value_vreg, .fpr)) {
                .reg => |id| {
                    const vs = abi.fpSlotToReg(id) orelse return ctx_mod.Error.SlotOverflow;
                    if (is_w)
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovWFromS(4, vs))
                    else
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovXFromD(4, vs));
                },
                .spill => |off| try gpr.frameLdrGpr(ctx.allocator, ctx.buf, 4, ctx.spill_base_off + off, is_w),
            }
        },
        else => {
            const xval = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 0);
            if (xval != 4) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(4, 31, xval));
        },
    }
    const xcount = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, count_vreg, 0);
    if (xcount != 5) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(5, 31, xcount));

    // X0 = rt; W1 = typeidx.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(1, @intCast(typeidx & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(1, @intCast((typeidx >> 16) & 0xFFFF), 1));
    // MOVZ/MOVK X16 = &jitGcArrayFill; BLR X16.
    // ADR-0203 D1 — helper via the rt slot ([X19+off]), not a baked imm64 (D-516 PIC).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_array_fill_fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));

    // W0: 1=ok, 0=OOB, 2=ARRAY_NULL_SENTINEL (D-293 array_oob). CMP #2 → null_reference (10);
    // CMP #0 → oob_memory (6); else (1) proceed. Matches array.get/set + interp.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(0, jit_abi.ARRAY_NULL_SENTINEL));
    var fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.null_ref_fixups.append(ctx.allocator, fixup);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(0, 0));
    fixup = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.oob_fixups.append(ctx.allocator, fixup);
    // array.fill is 4 → 0: no result vreg pushed.
}
