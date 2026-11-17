//! x86_64 emit handler for `br_on_null` — Wasm 3.0 function-references
//! §3.3.8.7. Mirror of `arm64/ops/wasm_3_0/br_on_null.zig`: pop a ref;
//! if null, branch to label at `payload` depth (passing the label's k
//! expected values from below the ref on the operand stack); if
//! non-null, push the ref back as a (non-null) typed ref and fall
//! through.
//!
//! First-cut scope: forward-block targets only. Function-return
//! (`payload == labels.items.len`) + loop targets return
//! `Error.UnsupportedOp` (D-194 first-impl bound, paired with the
//! arm64 first-cut at cycle 54b).
//!
//! Pattern (mirrors `emitBrIf` tgt_is_block_with_capture path at
//! `op_control.zig:843-854`, but with `TEST R, R (.q)` + inverted
//! condition + push src back for non-null fall-through):
//!
//! ```
//!     TEST Rn, Rn  (.q — funcref is u64)
//!     JNE skip_byte    ; if non-null, skip the merge+JMP
//!     <captureOrEmitBlockMergeMovCtx tgt_idx>  ; place label values
//!     JMP rel32 (placeholder) → labels[tgt_idx].pending (insn_size=5)
//!     skip_byte:
//!     <push src vreg back to pushed_vregs>
//! ```
//!
//! No `usesRuntimePtr` concern: label-fixups, not bounds-fixups → no
//! trap stub touched → R15 invariant unaffected (mirrors the arm64
//! note re X19/D-180).

const meta = @import("../../../../../instruction/wasm_3_0/br_on_null.zig");
const ctx_mod = @import("../../ctx.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const op_control = @import("../../op_control.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    if (ctx.pushed_vregs.items.len < 1) return ctx_mod.Error.AllocationMissing;
    const src = ctx.pushed_vregs.pop().?;
    const rn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src, 0);

    // First-cut: only forward-block targets supported.
    if (ins.payload >= ctx.labels.items.len) return ctx_mod.Error.UnsupportedOp;
    const tgt_idx: usize = @intCast(ctx.labels.items.len - 1 - @as(usize, @intCast(ins.payload)));
    if (ctx.labels.items[tgt_idx].kind != .block) return ctx_mod.Error.UnsupportedOp;

    // TEST Rn, Rn (.q — funcref is u64).
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, rn, rn).slice());
    // JNE skip placeholder — if non-null, skip past the merge + JMP
    // and fall through to push-src-back.
    const jne_at: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.ne, 0).slice());

    // Branch-taken (null) path: place label's k expected values, then
    // unconditional JMP rel32 → label fixup.
    // The condition was tested above; nothing but the flags is read after.
    _ = try op_control.captureOrEmitBlockMergeMovCtx(ctx, tgt_idx, null);
    const jmp_at: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJmpRel32(0).slice());
    try ctx.labels.items[tgt_idx].pending.append(ctx.allocator, .{ .byte_offset = jmp_at, .insn_size = 5 });

    // Patch JNE skip disp (insn_size = 6 for `0x0F 0x85 disp32`) to
    // land at the fall-through target (current buf end).
    const skip_byte: u32 = @intCast(ctx.buf.items.len);
    const jne_disp: i32 = @as(i32, @intCast(skip_byte)) - @as(i32, @intCast(jne_at)) - 6;
    const patched = inst.encJccRel32(.ne, jne_disp);
    @memcpy(ctx.buf.items[jne_at .. jne_at + patched.len], patched.slice());

    // Non-null fall-through: push src vreg back so the ref stays on
    // the operand stack for the next consumer.
    try ctx.pushed_vregs.append(ctx.allocator, src);
}
