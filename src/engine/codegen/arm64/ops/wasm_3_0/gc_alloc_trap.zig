//! arm64 shared tail for the GC allocation emit handlers (#364).
//!
//! The `jitGcAlloc` / `jitGcAllocArray` / `jitGcAllocArrayFill` trampolines
//! return the `GcRef` in W0, or 0 when the allocation fails — the GC heap's
//! 4 GiB cap, a type index out of range, or an unmaterialised GC substrate.
//! `emit` appends the zero-check that routes that 0 to the out_of_memory trap
//! stub (code 20), so the allocating instruction traps at the allocation
//! instead of pushing a null ref and running on. The five GC-alloc emits
//! (array.new, array.new_default, array.new_fixed, struct.new,
//! struct.new_default) call this right after their `BLR`; W0 is left untouched
//! for the caller to capture on the fall-through path.
//!
//! Lowering: CMP W0, #0 ; B.EQ → oom stub. The `B.EQ` placeholder matches the
//! form `EmitCindStub` patches (a B.cond whose target is the trap stub).

const ctx_mod = @import("../../ctx.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");

/// Append `CMP W0, #0 ; B.EQ <oom stub>` and record the branch for the
/// function-close stub patch. Call with the helper's return value live in W0.
pub fn emit(ctx: *ctx_mod.EmitCtx) ctx_mod.Error!void {
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(0, 0));
    const fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.oom_fixups.append(ctx.allocator, fixup);
}
