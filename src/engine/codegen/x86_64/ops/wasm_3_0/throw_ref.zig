//! x86_64 emit handler for `throw_ref` — Zone 2 per ADR-0074
//! + ADR-0114 D2 + ADR-0119. Mirror of arm64 sibling.
//!
//! Wasm spec 3.0 §3.3.10.8. Pop the exnref (a `*Exception` handle the
//! JIT reified at a catch_ref/catch_all_ref landing pad, D-327), read its
//! tag_idx + payload back into the JIT payload-staging buffer via the
//! `rethrowFromExnref` helper, then re-enter the throw dispatcher exactly
//! as a fresh `throw` of that tag (round-trip identity, ADR-0120 D6).
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_3_0/throw_ref.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const op_call = @import("../../op_call.zig");
const throw_op = @import("throw.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A + ADR-0114 D6 — terminator axis like throw.
pub const is_terminator: bool = true;
pub const n_successor_edges: u8 = 0;
pub const is_safepoint: bool = false;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    _ = ins;
    // A throw leaves this frame through the trampoline, never returning to
    // the post-call reload; the landing pad reloads register-homed locals
    // from their frame slots, so their current values must be there.
    try op_call.spillHomedCallerSaved(ctx);
    if (ctx.pushed_vregs.items.len < 1) return ctx_mod.Error.AllocationMissing;
    const exn_vreg = ctx.pushed_vregs.pop().?;
    const exn_reg = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, exn_vreg, 0);
    const arg0 = abi.current.entry_arg0_gpr; // RDI (SysV) / RCX (Win64)
    const arg1 = abi.current.arg_gprs[1]; // RSI (SysV) / RDX (Win64)
    // arg1 = exc_ptr (set before arg0 in case exn_reg == arg0).
    if (exn_reg != arg1) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, arg1, exn_reg).slice());
    // arg0 = rt; CALL rethrowFromExnref → RAX = tag_idx, payload restored.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, arg0, abi.runtime_ptr_save_gpr).slice());
    // ADR-0203 D1 — helper via the rt slot ([R15+off]), not a baked imm64 (D-516 PIC).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.r10, abi.runtime_ptr_save_gpr, jit_abi.rethrow_exnref_fn_off).slice());
    // Win64: rethrowFromExnref is a regular C-ABI fn that homes its reg args
    // to the 32-byte shadow space; reserve it (no-op on SysV / when the frame
    // already reserves outgoing space). D-327 Win64 fix.
    try op_call.emitShadowAlloc(ctx.allocator, ctx.buf, ctx.outgoing_max_bytes);
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(.r10).slice());
    try op_call.emitShadowFree(ctx.allocator, ctx.buf, ctx.outgoing_max_bytes);
    // Move tag_idx (RAX) into arg0 — the trampoline reads the platform's
    // first-arg reg as the throw-site tag indicator (mirror of throw.emit's
    // marshal). The trampoline call below only clobbers R10, so arg0 survives.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, arg0, abi.return_gpr).slice());
    try throw_op.emitTrampolineCallAndTrap(ctx, jit_abi.throw_trampoline_fn_off);
    ctx.dead_code.* = true;
}
