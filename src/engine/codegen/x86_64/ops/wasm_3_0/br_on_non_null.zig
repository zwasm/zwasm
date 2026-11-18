//! x86_64 emit handler for `br_on_non_null` — Wasm 3.0 function-
//! references §3.3.8.8. Mirror of
//! `arm64/ops/wasm_3_0/br_on_non_null.zig`: pop a ref; if **non-null**,
//! branch to label at `payload` depth passing the label's k+1 expected
//! values (the ref is the topmost of those k+1); if **null**, discard
//! ref and fall through.
//!
//! First-cut scope: forward-block targets only. Function-return
//! (payload == labels.items.len) + loop targets return
//! `Error.UnsupportedOp`. Paired with D-194 first-impl bound (mirror
//! of arm64 cycle 56).
//!
//! Pattern (mirror of `br_on_null.zig` at this same `wasm_3_0/` dir,
//! but with inverse condition + ref-IS-part-of-label-values handling).
//! For `br_on_null` the label expects `k` values (ref consumed on
//! branch); for `br_on_non_null` the label expects `k+1` (ref passed
//! AS the topmost label value). So:
//!
//! - **Peek** ref vreg (don't pop yet) → `pushed_vregs` carries k+1
//!   entries (matching `label.result_arity == k+1`).
//! - `TEST Rn, Rn (.q)` + `JE skip_byte` (skip past merge+JMP on null).
//! - `captureOrEmitBlockMergeMovCtx(ctx, tgt_idx)` — places k+1 values
//!   (including the ref) at label positions.
//! - `JMP rel32 (placeholder)` → append fixup to
//!   `labels[tgt_idx].pending`.
//! - Patch `JE` skip disp.
//! - **Pop** ref from `pushed_vregs` (consumed on null fall-through;
//!   the peek meant we never popped, so pop now).
//!
//! No `usesRuntimePtr` concern (label fixups, not bounds-fixups).

const meta = @import("../../../../../instruction/wasm_3_0/br_on_non_null.zig");
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
    // Peek the top vreg — DON'T pop until after merge_mov (the ref
    // must be visible in pushed_vregs because the label's k+1 result
    // values include it as the topmost).
    const src = ctx.pushed_vregs.items[ctx.pushed_vregs.items.len - 1];
    const rn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src, 0);

    if (ins.payload >= ctx.labels.items.len) return ctx_mod.Error.UnsupportedOp;
    const tgt_idx: usize = @intCast(ctx.labels.items.len - 1 - @as(usize, @intCast(ins.payload)));
    if (ctx.labels.items[tgt_idx].kind != .block) return ctx_mod.Error.UnsupportedOp;

    // TEST Rn, Rn (.q — funcref u64 null-check).
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, rn, rn).slice());
    // JE skip placeholder — if ref IS null, skip past the merge+JMP
    // and fall through to the consumed-ref state.
    const je_at: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());

    // Branch-taken (non-null) path: ref is on pushed_vregs (we peeked,
    // didn't pop). merge_mov sees k+1 values including ref + writes
    // MOVs into label-expected positions. Then unconditional JMP →
    // label fixup.
    // The condition was tested above; nothing but the flags is read after.
    _ = try op_control.captureOrEmitBlockMergeMovCtx(ctx, tgt_idx, null);
    const jmp_at: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJmpRel32(0).slice());
    try ctx.labels.items[tgt_idx].pending.append(ctx.allocator, .{ .byte_offset = jmp_at, .insn_size = 5 });

    // Patch JE skip disp to current buf end.
    const skip_byte: u32 = @intCast(ctx.buf.items.len);
    const je_disp: i32 = @as(i32, @intCast(skip_byte)) - @as(i32, @intCast(je_at)) - 6;
    const patched = inst.encJccRel32(.e, je_disp);
    @memcpy(ctx.buf.items[je_at .. je_at + patched.len], patched.slice());

    // Fall-through (null) state: ref is consumed. Pop the peeked
    // vreg so pushed_vregs reflects [t*] (ref gone).
    _ = ctx.pushed_vregs.pop().?;
}
