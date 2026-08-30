//! arm64 emit handler for `throw` — Zone 2 per ADR-0074 +
//! ADR-0114 D2 + ADR-0119.
//!
//! Wasm spec 3.0 §3.3.10.7. Per ADR-0114 D6 the full throw op
//! marshals (tag_idx, payload) into argregs and CALLs the
//! `zwasm_throw` dispatcher; on .uncaught it sets trap_flag=1
//! and returns, on .handler it JMPs to the landing pad.
//!
//! ## Current shape (tag_idx marshal)
//!
//! Marshals `tag_idx` (= `ins.payload`; the payload field is u64
//! but tag indices fit in u32) into W0 before the BLR. The
//! trampoline's naked stub (`shared/throw_trampoline.zig`) reads
//! W0/X0 as the throw-site tag indicator and re-routes it to X2
//! (= trampolineCore's `tag_idx` arg) before calling
//! `dispatchThrow`. The dispatcher matches it against installed
//! `HandlerEntry.tag_idx` for tagged catches (`.catch_` /
//! `.catch_ref`); catch_all / catch_all_ref clauses ignore it.
//!
//! Byte layout (32 bytes — was 24 pre-marshal):
//!   MOVZ W0, #(tag_idx & 0xFFFF)             ; 4 bytes
//!   MOVK W0, #((tag_idx >> 16) & 0xFFFF), LSL #16  ; 4 bytes
//!   MOVZ X16, #(addr & 0xFFFF)               ; 4 bytes
//!   MOVK X16, #((addr >> 16) & 0xFFFF), LSL #16  ; 4 bytes
//!   MOVK X16, #((addr >> 32) & 0xFFFF), LSL #32  ; 4 bytes
//!   MOVK X16, #((addr >> 48) & 0xFFFF), LSL #48  ; 4 bytes
//!   BLR X16                                    ; 4 bytes
//!   B  <trap_stub_fixup>                       ; 4 bytes (patched)
//!
//! X16 is the AAPCS64 intra-procedure scratch (IP0), free to
//! clobber across calls. Per ADR-0017 X19 (the pinned runtime
//! ptr) is inherited intact through the BLR — the trampoline
//! reads `[X19, #trap_flag_off]` from it. W0 is caller-saved and
//! used as the AAPCS64 first int arg; the trampoline shuffles
//! it to its actual arg position (X2) before calling core.
//!
//! Zone 2 (`src/engine/codegen/arm64/ops/`).

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

// ADR-0113 §A + ADR-0114 D6 — regalloc 3-axis classification.
// throw is a terminator (control transfers via the dispatcher
// to either a landing pad or the entry shim). Zero in-function
// CFG successor edges. Not a safepoint.
pub const is_terminator: bool = true;
pub const n_successor_edges: u8 = 0;
pub const is_safepoint: bool = false;

/// X16 = IP0 (intra-procedure scratch, AAPCS64 §6.4 caller-saved,
/// outside the regalloc-managed pool). Loaded with the trampoline
/// address then BLR'd.
const scratch: inst.Xn = 16;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    // A throw leaves this frame through the trampoline, never returning to
    // the post-call reload; the landing pad reloads register-homed locals
    // from their frame slots, so their current values must be there.
    try op_call.spillHomedCallerSaved(ctx);
    const tag_idx: u32 = @intCast(ins.payload);

    // ADR-0120 — pop N payload values
    // from the regalloc operand stack and store each at
    // `[X19 + eh_payload_buf_off + i*8]`, then write N to
    // `[X19 + eh_payload_len_off]`. Per ADR-0120 D1 cap N ≤ 16
    // (matches `Exception.payload[16]` ADR-0114 D1). Wasm
    // operand-stack order: [..., p_0, p_1, ..., p_{N-1}] with
    // p_{N-1} on top; popping in reverse means the last-popped
    // value goes to index 0. Loop from high index down so each
    // pop deposits into its natural buf slot.
    //
    // For tag_idx outside `tag_param_counts.len` (test-side
    // EmitCtx defaults to `&.{}`), N=0 — same as pre-Cycle-4
    // shape; no pops, just a `STR Wzr` for the length.
    //
    // Gpr-class only this cycle: i32 / i64 / funcref / externref
    // operand values flow through `gprLoadSpilled`. f32 / f64 /
    // v128 / exnref tag params fall back to v0.2 scope per
    // ADR-0120 Consequence §3.
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
            const slot_off: u14 = @intCast(jit_abi.eh_payload_buf_off + i * 8);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(stage_reg, abi.runtime_ptr_save_gpr, slot_off));
        }
    }

    // Write N to eh_payload_len. For N=0 emit STR Wzr (1 instr);
    // for N>0 materialise N into W17 via MOVZ then STR.
    if (n_payload == 0) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImmW(31, abi.runtime_ptr_save_gpr, jit_abi.eh_payload_len_off));
    } else {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(17, @intCast(n_payload)));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImmW(17, abi.runtime_ptr_save_gpr, jit_abi.eh_payload_len_off));
    }

    // Marshal tag_idx into W0 — the trampoline's naked stub reads
    // X0 as the throw-site tag indicator and re-routes it to X2
    // (= trampolineCore's `tag_idx` arg). MOVZ + MOVK covers the
    // full u32 range; for typical small tag indices the high MOVK
    // could be elided but emitting both keeps the byte layout
    // uniform (8 bytes always) and avoids a per-call branch.
    const tag_lo: u16 = @intCast(tag_idx & 0xFFFF);
    const tag_hi: u16 = @intCast((tag_idx >> 16) & 0xFFFF);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(0, tag_lo));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(0, tag_hi, 1));

    try emitTrampolineCallAndTrap(ctx, jit_abi.throw_trampoline_fn_off);
}

/// Shared emit for `throw` + `throw_ref` (`throw_ref` re-uses the
/// same slot-load + BLR + trap-stub-fallback shape this cycle; the
/// two will diverge once exnref handling lands). The trampoline is
/// reached through its `JitRuntime` slot (ADR-0203 D1 — never a
/// baked imm64, the D-516 PIC invariant).
pub fn emitTrampolineCallAndTrap(ctx: *ctx_mod.EmitCtx, trampoline_slot_off: u12) ctx_mod.Error!void {
    // LDR X16, [X19, #slot]
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(scratch, abi.runtime_ptr_save_gpr, trampoline_slot_off));
    // BLR X16 — call the trampoline. Returns here with trap_flag=1.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));
    // B <trap_stub> — patched at function-end. D-292 C: route to the dedicated
    // uncaught_exception stub (code 12), not the generic bounds bucket, so an
    // escaped throw/throw_ref surfaces `kind=uncaught_exception` (interp parity).
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    try ctx.uncaught_exc_fixups.append(ctx.allocator, fixup_at);
}
