//! arm64 emit handler for `ref.as_non_null` — Wasm 3.0 function-
//! references §3.3.8.5. Pop a ref, trap (NullReference) if it's the
//! null sentinel (0), else leave it on the stack (identity).
//!
//! Implementation: pop src vreg, load into Xn, `CMP Xn, #0`,
//! `B.EQ → null_ref_fixups` (the null_reference stub, code 10, at the
//! function epilogue — D-293 slice-4b). Identity
//! passthrough: push the SAME src vreg back (no new result vreg, no
//! register-to-register MOV) — src's storage is unmodified, the
//! next consumer reads it from the same slot.

const meta = @import("../../../../../instruction/wasm_3_0/ref_as_non_null.zig");
const ctx_mod = @import("../../ctx.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, _: *const zir.ZirInstr) ctx_mod.Error!void {
    if (ctx.pushed_vregs.items.len < 1) return ctx_mod.Error.AllocationMissing;
    const src = ctx.pushed_vregs.pop().?;
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xn, 0));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.null_ref_fixups.append(ctx.allocator, fixup_at); // D-293 slice-4b null_reference (code 10)
    // Identity: push src back. No new result vreg; src's storage
    // (register or spill slot) holds the funcref unchanged for the
    // next consumer.
    try ctx.pushed_vregs.append(ctx.allocator, src);
}
