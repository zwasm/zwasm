//! x86_64 emit handler for `throw` — Zone 2 per ADR-0074 +
//! ADR-0114 D2 + ADR-0119. Mirror of arm64 sibling.
//!
//! Wasm spec 3.0 §3.3.10.7. Per ADR-0114 D6 marshals
//! (tag_idx, payload) into argregs and CALLs the `zwasm_throw`
//! dispatcher.
//!
//! ## Current shape (tag_idx marshal)
//!
//! Marshals `tag_idx` (= `ins.payload`, u32) into the platform's
//! first-arg register before MOVABS R10, addr + CALL R10:
//! - SysV (Linux / Mac): MOV EDI, imm32 — RDI is SysV first arg.
//!   Trampoline naked stub re-routes RDI → RDX (= trampolineCore
//!   tag_idx arg2).
//! - Win64: MOV ECX, imm32 — RCX is Win64 first arg. Trampoline
//!   stashes RCX → R10 then routes → R8 (= trampolineCore arg2).
//!
//! Byte layout (SysV — 22 bytes; Win64 — 22 bytes):
//!   MOV E{DI,CX}, imm32  ; 5 bytes
//!   MOVABS R10, imm64    ; 10 bytes (49 ba + 8-byte addr)
//!   CALL R10             ; 3 bytes (41 ff d2)
//!   JMP <trap_stub>      ; 5 bytes (e9 + disp32, patched)
//!
//! R10 is SysV/Win64 caller-saved scratch; the trampoline's body
//! also clobbers R10 (matching this site's expectations). R15
//! (the pinned runtime ptr per ADR-0017 Cc-pivot) is inherited
//! across the CALL.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const builtin = @import("builtin");
const std = @import("std");
const meta = @import("../../../../../instruction/wasm_3_0/throw.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const op_call = @import("../../op_call.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A + ADR-0114 D6 — terminator axis.
pub const is_terminator: bool = true;
pub const n_successor_edges: u8 = 0;
pub const is_safepoint: bool = false;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    // A throw leaves this frame through the trampoline, never returning to
    // the post-call reload; the landing pad reloads register-homed locals
    // from their frame slots, so their current values must be there.
    try op_call.spillHomedCallerSaved(ctx);
    const tag_idx: u32 = @intCast(ins.payload);

    // ADR-0120 — mirror of arm64
    // sibling. Pop N payload values, store each as a 64-bit
    // write at `[R15 + eh_payload_buf_off + i*8]`, then store N
    // (or 0) to `[R15 + eh_payload_len_off]`. See arm64
    // throw.emit for the operand-stack-order rationale.
    //
    // Gpr-class only this cycle; f32/f64/v128/exnref tag params
    // deferred per ADR-0120 Consequence §3.
    const n_payload: u32 = if (ctx.tag_param_counts.len > tag_idx)
        ctx.tag_param_counts[tag_idx]
    else
        0;
    std.debug.assert(n_payload <= 16);

    if (n_payload > 0) {
        if (ctx.pushed_vregs.items.len < n_payload) return ctx_mod.Error.AllocationMissing;
        var i: u32 = n_payload;
        while (i > 0) {
            i -= 1;
            const val_vreg = ctx.pushed_vregs.pop().?;
            const stage_reg = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_vreg, 0);
            const slot_off: i32 = @intCast(jit_abi.eh_payload_buf_off + i * 8);
            try ctx.buf.appendSlice(ctx.allocator, inst.encStoreR64MemDisp32(stage_reg, abi.runtime_ptr_save_gpr, slot_off).slice());
        }
    }

    // Write N to eh_payload_len. encMovMemDisp32Imm32 stores a
    // 32-bit immediate (works for both N=0 and N>0).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovMemDisp32Imm32(abi.runtime_ptr_save_gpr, jit_abi.eh_payload_len_off, n_payload).slice());

    // Marshal tag_idx into the platform's first-arg register so
    // the trampoline's naked stub can re-route it to
    // `trampolineCore`'s arg2. SysV → RDI; Win64 → RCX.
    const first_arg_reg = if (builtin.target.os.tag == .windows)
        inst.Gpr.rcx
    else
        inst.Gpr.rdi;
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(first_arg_reg, tag_idx).slice());

    try emitTrampolineCallAndTrap(ctx, jit_abi.throw_trampoline_fn_off);
    ctx.dead_code.* = true;
}

/// Shared emit for `throw` + `throw_ref` (same shape for now; will
/// diverge once exnref handling lands). The trampoline is reached
/// through its `JitRuntime` slot (ADR-0203 D1 — never a baked
/// imm64, the D-516 PIC invariant).
pub fn emitTrampolineCallAndTrap(ctx: *ctx_mod.EmitCtx, trampoline_slot_off: u12) ctx_mod.Error!void {
    // MOV R10, [R15 + slot] — 7-8 bytes.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.r10, abi.runtime_ptr_save_gpr, trampoline_slot_off).slice());
    // CALL R10 — 3 bytes (REX.B + FF /2).
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(.r10).slice());
    // JMP rel32 placeholder — 5 bytes; patched at function-end. D-292 C: route to
    // the dedicated uncaught_exception stub (code 12), NOT unreach_fixups (code 5)
    // — an escaped throw/throw_ref previously mis-reported `kind=unreachable`.
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJmpRel32(0).slice());
    try ctx.uncaught_exc_fixups.append(ctx.allocator, fixup_at);
}
