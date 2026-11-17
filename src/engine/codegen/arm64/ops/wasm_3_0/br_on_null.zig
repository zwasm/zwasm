//! arm64 emit handler for `br_on_null` — Wasm 3.0 function-references
//! §3.3.8.7. Pop a ref; if null, branch to label at `payload` depth
//! (passing the label's k expected values from below the ref on the
//! operand stack); if non-null, push ref back as a (non-null) typed
//! ref and fall through.
//!
//! Implemented via the shared `op_control.branchOnReg` (the same helper
//! br_if / br_on_cast use) so ALL target shapes work — forward block,
//! loop, and function-return (payload == labels.items.len). The ref is
//! the null-CONDITION, not a value passed to the label, so unlike
//! br_on_cast we POP it first (the label's k values sit below it), feed
//! a 0/1 null-flag (`CMP Xn,#0; CSET Wn, EQ` → 1 iff null) as the branch
//! condition (`branchOnReg` branches when the reg != 0), then push the
//! ref back for the non-null fall-through. D-239 (was first-cut
//! forward-block-only → UnsupportedOp on br_on_null.1's function-return).
//!
//! No usesRuntimePtr concern: label fixups (br_if machinery), not
//! bounds_fixups → trap stub not triggered → X19 not implicitly required.

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
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src, 0);

    // Null-flag in a RESERVED scratch (W16/IP0 — NOT an allocatable vreg
    // home, so it does not clobber the ref; branchOnReg reads it before it
    // emits a merge move, which may park in X16): CMP Xn,#0 (X-form —
    // funcref is u64) ; CSET W16, EQ → 1 iff null. CMP only READS Xn, so when `src` is register-resident the ref
    // value stays live in Xn for the non-null fall-through push below
    // (CSET-into-Xn would have destroyed it — the block-path regression).
    // `branchOnReg` branches when the reg != 0 (= null).
    const flag: inst.Xn = 16;
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xn, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(flag, .eq));

    // Shared branch body — handles function-return / loop / forward-block,
    // marshalling the label's k values (now the pushed_vregs top, the ref
    // having been popped). branchOnReg validates the depth + target shape.
    try op_control.branchOnReg(ctx, ins, flag);

    // Non-null fall-through: ref stays on the operand stack for the next
    // consumer (kept generic-funcref per ADR-0123 D2 — no narrowing).
    try ctx.pushed_vregs.append(ctx.allocator, src);
}
