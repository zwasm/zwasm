//! arm64 emit handler for `ref.cast_null` — Wasm 3.0 GC §3.3.5.4 (nullable
//! target). Pop one reftype operand; NULL passes through unchanged (no
//! trap); a non-null value traps if its runtime type is not a subtype of
//! the heap-type immediate, else passes through unchanged. 1 → 1.
//!
//! Unlike `ref.cast` (straight-line), the null-passes semantics needs an
//! INLINE null-skip branch: `CBZ ref, .done` jumps over the cast check so a
//! null operand is NOT trapped. On the non-null path it reuses the
//! `jitGcRefCast(rt, ref, ht)` trampoline (returns ref / 0=trap-on-mismatch)
//! and captures the matched ref from X0 AFTER the CALL (a register-allocated
//! result reg would be clobbered by the CALL otherwise — that is why the
//! result is set post-CALL on the cast path, and pre-branch on the null
//! path where no CALL runs). The `CBZ` displacement is patched in-place once
//! `.done`'s offset is known (a local forward branch; the trap `B.EQ` still
//! routes through `bounds_fixups`).
//!
//! Lowering: MOV rd, ref ; CBZ ref, .done ; { MOV X1,ref ; MOV X0,X19 ;
//! MOVZ W2=ht ; MOVZ/MOVK X16=&jitGcRefCast ; BLR ; CMP X0,#0 ; B.EQ → trap ;
//! MOV rd, X0 } ; .done: STR rd→slot.

const std = @import("std");

const meta = @import("../../../../../instruction/wasm_3_0/ref_cast_null.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const scratch: inst.Xn = 16; // IP0 — &jitGcRefCast.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    // D-453: ht is the full encoded u32 (bit31 concrete-tag | idx, or bare byte).
    const ht: u32 = @truncate(ins.payload);
    const args = try ctx.popUnary();
    const xsrc = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    // rd = operand (the result for the NULL path; on that path no CALL runs,
    // so rd survives to .done).
    if (rd != xsrc) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(rd, 31, xsrc));
    // CBZ ref, .done — null passes through unchanged (skip the cast check).
    const cbz_at: usize = ctx.buf.items.len;
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbz(xsrc, 0)); // placeholder disp

    // Non-null path: jitGcRefCast(rt, ref, ht) → X0 (ref / 0=trap-on-mismatch).
    if (xsrc != 1) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(1, 31, xsrc));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    // W2 = ht (full 32-bit: MOVZ low half + MOVK high half).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(2, @intCast(ht & 0xFFFF)));
    if (ht >> 16 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(2, @intCast((ht >> 16) & 0xFFFF), 1));
    // ADR-0203 D1 — helper via the rt slot ([X19+off]), not a baked imm64 (D-516 PIC).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_ref_cast_fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(0, 0));
    const fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.cast_fail_fixups.append(ctx.allocator, fixup); // D-293 slice-4d cast_failure (code 11)
    // Match: rd = the returned ref (X0; rd may have been CALL-clobbered).
    if (rd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(rd, 31, 0));

    // .done — patch the CBZ forward displacement (in words).
    const disp_words = try gpr.rel(i19, cbz_at, ctx.buf.items.len);
    std.mem.writeInt(u32, ctx.buf.items[cbz_at..][0..4], inst.encCbz(xsrc, disp_words), .little);

    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
