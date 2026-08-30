//! arm64 emit handler for `throw_ref` — Zone 2 per ADR-0074
//! + ADR-0114 D2 + ADR-0119.
//!
//! Wasm spec 3.0 §3.3.10.8. Pop the exnref (a `*Exception` handle the
//! JIT reified at a catch_ref/catch_all_ref landing pad, D-327), read its
//! tag_idx + payload back into the JIT payload-staging buffer via the
//! `rethrowFromExnref` helper, then re-enter the throw dispatcher exactly
//! as a fresh `throw` of that tag — giving the round-trip identity Wasm
//! `throw_ref` requires (ADR-0120 D6).
//!
//! Zone 2 (`src/engine/codegen/arm64/ops/`).

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

/// X16 = IP0 (intra-procedure scratch, AAPCS64 §6.4 caller-saved).
const scratch: inst.Xn = 16;

/// LDR X16, [X19, #slot_off]; BLR X16 — call a helper through its
/// `JitRuntime` slot (ADR-0203 D1: never a baked imm64, D-516 PIC). Plain
/// call, no trap-stub fallback — `rethrowFromExnref` returns normally.
fn emitSlotCall(ctx: *ctx_mod.EmitCtx, slot_off: u12) ctx_mod.Error!void {
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(scratch, abi.runtime_ptr_save_gpr, slot_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));
}

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    _ = ins;
    // A throw leaves this frame through the trampoline, never returning to
    // the post-call reload; the landing pad reloads register-homed locals
    // from their frame slots, so their current values must be there.
    try op_call.spillHomedCallerSaved(ctx);
    // Pop the exnref operand (= *Exception). Marshal into X1 (arg1).
    if (ctx.pushed_vregs.items.len < 1) return ctx_mod.Error.AllocationMissing;
    const exn_vreg = ctx.pushed_vregs.pop().?;
    const exn_reg = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, exn_vreg, 0);
    if (exn_reg != 1) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(1, 31, exn_reg)); // MOV X1, exn_reg
    // arg0 = rt (X0 = X19); call rethrowFromExnref → W0 = tag_idx, payload
    // restored into eh_payload_buf. X0 survives the trampoline call below
    // (it only clobbers X16), so the dispatcher reads it as the throw-site
    // tag exactly like `throw`.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try emitSlotCall(ctx, jit_abi.rethrow_exnref_fn_off);
    try throw_op.emitTrampolineCallAndTrap(ctx, jit_abi.throw_trampoline_fn_off);
}
