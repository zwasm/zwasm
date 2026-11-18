//! arm64 emit handler for `br_on_non_null` — Wasm 3.0 function-
//! references §3.3.8.8. Pop a ref; if **non-null**, branch to label at
//! `payload` depth passing the label's k+1 expected values (the ref is
//! the topmost of those k+1); if **null**, discard ref and fall
//! through.
//!
//! First-cut scope: forward-block targets only. Function-return
//! (payload == labels.items.len) + loop targets return
//! `Error.UnsupportedOp`. Covered by D-194 (paired with the existing
//! x86_64 deferral).
//!
//! Pattern (mirror of br_on_null at this same wasm_3_0/ dir, but with
//! inverse condition + ref-IS-part-of-label-values handling). For
//! br_on_null the label expects `k` values (ref consumed on branch);
//! for br_on_non_null the label expects `k+1` (ref passed AS the
//! topmost label value). So:
//!
//! - **Peek** ref vreg (don't pop yet) → merge_mov sees pushed_vregs
//!   with k+1 entries (matching label.result_arity == k+1).
//! - `CMP Xn, #0` + `B.EQ skip_byte` (skip past merge+B on null).
//! - `captureOrEmitBlockMergeMov(ctx, tgt_idx)` — places k+1 values
//!   (including ref) at label positions.
//! - `B 0` placeholder → append fixup to `labels[tgt_idx].pending`.
//! - Patch `B.EQ` skip disp.
//! - **Pop** ref from pushed_vregs (consumed on null fall-through; the
//!   peek meant we never popped, so pop now to reach fall-through
//!   state with ref discarded).
//!
//! No usesRuntimePtr concern (label fixups, not bounds_fixups). Same
//! D-180 sidestep as br_on_null.

const std = @import("std");
const meta = @import("../../../../../instruction/wasm_3_0/br_on_non_null.zig");
const ctx_mod = @import("../../ctx.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const merge_mov = @import("../../op_control_merge_mov.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    if (ctx.pushed_vregs.items.len < 1) return ctx_mod.Error.AllocationMissing;
    // Peek the top vreg — DON'T pop until after merge_mov (the ref
    // must be visible in pushed_vregs because the label's k+1 result
    // values include it as the topmost).
    const src = ctx.pushed_vregs.items[ctx.pushed_vregs.items.len - 1];
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src, 0);

    if (ins.payload >= ctx.labels.items.len) return ctx_mod.Error.UnsupportedOp;
    const tgt_idx: usize = @intCast(ctx.labels.items.len - 1 - @as(usize, @intCast(ins.payload)));
    if (ctx.labels.items[tgt_idx].kind != .block) return ctx_mod.Error.UnsupportedOp;

    // CMP Xn, #0 (X-form null check on the funcref).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xn, 0));
    // B.EQ skip placeholder — if ref IS null, skip past the merge+B
    // and fall through to the consumed-ref state.
    const beq_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));

    // Branch-taken (non-null) path: ref is on pushed_vregs (we peeked,
    // didn't pop). merge_mov sees k+1 values including ref + writes
    // MOVs into label-expected positions. Then unconditional B → label
    // fixup.
    // The condition was tested above; nothing but the flags is read after.
    _ = try merge_mov.captureOrEmitBlockMergeMov(ctx, tgt_idx, null);
    const b_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    try ctx.labels.items[tgt_idx].pending.append(ctx.allocator, .{ .byte_offset = b_at, .kind = .b_uncond });

    // Patch B.EQ skip disp to current buf end (skip target = where
    // null-path execution lands).
    const skip_byte: u32 = @intCast(ctx.buf.items.len);
    const beq_disp_words: i19 = @intCast(@divExact(@as(i32, @intCast(skip_byte)) - @as(i32, @intCast(beq_at)), 4));
    std.mem.writeInt(u32, ctx.buf.items[beq_at..][0..4], inst.encBCond(.eq, beq_disp_words), .little);

    // Fall-through (null) state: ref is consumed. Pop the peeked
    // vreg so pushed_vregs reflects [t*] (ref gone).
    _ = ctx.pushed_vregs.pop().?;
}
