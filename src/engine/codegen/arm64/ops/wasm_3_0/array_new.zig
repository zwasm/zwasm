//! arm64 emit handler for `array.new` — Wasm 3.0 GC §3.3.5.6.6.
//! Pop the i32 length (stack top) + the init value, allocate an array of
//! that length and fill every element with the init value, push the
//! GcRef. The element count is RUNTIME, so the fill runs inside the
//! `jitGcAllocArrayFill(rt, typeidx, length, init)` trampoline (mirrors
//! the interp arrayNew) — the per-arch emit stays a plain marshal+CALL
//! (no emitted loop). Both operands are consumed into arg registers
//! BEFORE the BLR (length → W2, init → X3), so neither force-spills
//! (strict `is_call`; only vregs SPANNING it do).
//!
//! NOTE: the init is marshaled into X3 — from a GPR for i32/i64/ref; for an
//! f32/f64 element (D-212), by FMOV from an FP register or a GPR load from the
//! spill slot (see the switch below). The helper writes the low `esz` bytes, so
//! W3 (f32) / X3 (f64) suffice.
//!
//! Lowering: MOV W2 = length; set X3 = init; MOV X0, X19 (rt); MOVZ/MOVK
//! W1 = typeidx; MOVZ/MOVK X16 = &jitGcAllocArrayFill; BLR X16; W0 → ref.

const meta = @import("../../../../../instruction/wasm_3_0/array_new.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const inst_fp = @import("../../inst_fp.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const gc_alloc_trap = @import("gc_alloc_trap.zig");
const decline_note = @import("../../../shared/decline_note.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const scratch: inst.Xn = 16; // IP0 — &fn.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);
    const elem_vt = ctx.func.arrayElemValType(typeidx); // D-212
    // D-495 — the fill marshals the init through a u64, so a v128 (16-byte)
    // element has no path: jitGcAllocArrayFill returns 0 (esz>8) and #364's
    // zero-check would surface it as out_of_memory, which it is not. Decline
    // instead, so the default engine runs it on the interpreter.
    if (elem_vt == 0x7B) {
        decline_note.set("array.new", .v128_array_element);
        return ctx_mod.Error.UnsupportedOp;
    }
    // args.lhs = init value; args.rhs = i32 length (stack top); result = ref.
    const args = try ctx.popBinary();
    // W2 = length (rhs).
    const xsize = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 0);
    if (xsize != 2) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(2, 31, xsize));
    // X3 = init. An f32/f64 init lives in the FP class (D-212). In an FP
    // register: FMOV its bits into W3 (f32, zero-extends) / X3 (f64). Spilled:
    // load the bits straight from the slot into W3/X3 with the large-offset-safe
    // GPR frame load — the GPR loader, not fpLoadSpilled, so this path carries no
    // 32,760-byte frame bound. i32/i64/ref come from a GPR.
    switch (elem_vt) {
        0x7D, 0x7C => {
            const is_w = elem_vt == 0x7D;
            switch (ctx.alloc.slot(args.lhs, .fpr)) {
                .reg => |id| {
                    const vs = abi.fpSlotToReg(id) orelse return ctx_mod.Error.SlotOverflow;
                    if (is_w)
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovWFromS(3, vs))
                    else
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovXFromD(3, vs));
                },
                .spill => |off| try gpr.frameLdrGpr(ctx.allocator, ctx.buf, 3, ctx.spill_base_off + off, is_w),
            }
        },
        else => {
            const xinit = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 1);
            if (xinit != 3) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(3, 31, xinit));
        },
    }
    // X0 = rt; W1 = typeidx.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(1, @intCast(typeidx & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(1, @intCast((typeidx >> 16) & 0xFFFF), 1));
    // MOVZ/MOVK X16 = &jitGcAllocArrayFill; BLR X16.
    // ADR-0203 D1 — helper via the rt slot ([X19+off]), not a baked imm64 (D-516 PIC).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_alloc_array_fill_fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));
    // #364 — a failed alloc returns 0; trap out_of_memory before capturing W0.
    try gc_alloc_trap.emit(ctx);

    // Capture W0 (GcRef) → result vreg.
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    if (rd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(rd, 31, 0));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
