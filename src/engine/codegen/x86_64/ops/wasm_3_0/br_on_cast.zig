//! x86_64 emit handler for `br_on_cast` / `br_on_cast_fail` — Wasm 3.0 GC
//! §3.3.5.5 / §4.4.5. Mirror of the arm64 handler: PEEK the top reftype
//! operand (it STAYS on the stack — branch carries the narrowed ref to the
//! label, fall-through keeps it), test it against target heap-type `ht2` via
//! `jitGcRefTest(rt, ref, ht2|nullbit)`, then conditionally branch to the
//! label at `payload` depth (`br_on_cast` on match, `br_on_cast_fail` on
//! NON-match — the bool is inverted first).
//!
//! The branch body is the shared `op_control.branchOnReg` (Cycle A
//! `7a44f910`), reached via the `branchOnRegCtx` adapter. branchOnReg's first
//! emitted instruction in every case is `TEST cond_r, cond_r`, so RAX (the
//! cast bool; outside the regalloc pool) survives the merge MOVs.
//!
//! D-453 ZirInstr: `payload = labelidx | (ht2_encoded << 32)`, `extra =
//! flags`. `ht2 = payload >> 32` (full TARGET heap-type — idx ≥ 64
//! representable), `ht2_nullable = (extra&0x02)!=0`. Null folds inside the
//! trampoline (arg2 bit 0x4000_0000). ht1 (source) is dropped at lower time. The
//! shared `branchOnRegCtx` reads `ins.payload` as the depth, so it gets a
//! copy masked to the low 32 bits. Shares `emit` with `br_on_cast_fail.zig`
//! (sense from `ins.op`; mirror ref_test_null).

const meta = @import("../../../../../instruction/wasm_3_0/br_on_cast.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const op_control = @import("../../op_control.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const call_scratch: abi.Gpr = .r10; // emit scratch — &fn, then CALL target.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    if (ctx.pushed_vregs.items.len < 1) return ctx_mod.Error.AllocationMissing;
    const is_fail = ins.op == .br_on_cast_fail;
    const ht2: u32 = @truncate(ins.payload >> 32);
    const ht2_nullable = (ins.extra & 0x02) != 0;
    const arg2: u32 = ht2 | (if (ht2_nullable) @as(u32, 0x4000_0000) else 0);

    // PEEK the ref (do NOT pop — stays as the block-result top vreg).
    const src = ctx.pushed_vregs.items[ctx.pushed_vregs.items.len - 1];
    const rsrc = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src, 0);
    // RSI = ref (64-bit); RDI = rt (R15); EDX = ht2|nullbit.
    if (rsrc != abi.current.arg_gprs[1]) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[1], rsrc).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[0], abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(abi.current.arg_gprs[2], arg2).slice());
    // MOVABS R10 = &jitGcRefTest; CALL R10 → EAX = 0/1.
    // ADR-0203 D1 — helper via the rt slot ([R15+off]), not a baked imm64 (D-516 PIC).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(call_scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_ref_test_fn_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());

    // br_on_cast_fail: invert EAX = (EAX == 0) ? 1 : 0 so branchOnReg (branch
    // when cond reg is non-zero) takes the branch on NON-match.
    if (is_fail) {
        try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.d, .rax, .rax).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encSetccR(.e, .rax).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovzxR32R8(.rax, .rax).slice());
    }

    // Conditional branch on the cast bool in RAX. branchOnRegCtx reads
    // `ins.payload` as the label depth; D-453 packs ht2 into bits 32+, so
    // hand it a copy masked to the low 32 (labelidx).
    var br_ins = ins.*;
    br_ins.payload = @as(u32, @truncate(ins.payload));
    try op_control.branchOnRegCtx(ctx, &br_ins, .rax);
}
