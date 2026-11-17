//! x86_64 shared tail for the GC allocation emit handlers (#364).
//!
//! The `jitGcAlloc` / `jitGcAllocArray` / `jitGcAllocArrayFill` trampolines
//! return the `GcRef` in EAX, or 0 when the allocation fails — the GC heap's
//! 4 GiB cap, a type index out of range, or an unmaterialised GC substrate.
//! `emit` appends the zero-check that routes that 0 to the out_of_memory trap
//! stub (code 20), so the allocating instruction traps at the allocation
//! instead of pushing a null ref and running on. The five GC-alloc emits
//! (array.new, array.new_default, array.new_fixed, struct.new,
//! struct.new_default) call this right after their alloc CALL; EAX is left
//! untouched (TEST does not write it) for the caller to capture on the
//! fall-through path.
//!
//! Lowering: TEST EAX, EAX ; JE rel32 → oom stub. Intel SDM Vol.2
//! (TEST 0x85, Jcc 0x0F 0x84).

const ctx_mod = @import("../../ctx.zig");
const inst = @import("../../inst.zig");

/// Append `TEST EAX, EAX ; JE <oom stub>` and record the branch for the
/// function-close stub patch. Call with the helper's return value live in EAX.
pub fn emit(ctx: *ctx_mod.EmitCtx) ctx_mod.Error!void {
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.d, .rax, .rax).slice());
    const fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.oom_fixups.append(ctx.allocator, fixup);
}
