//! x86_64 emit handler for `ref.test` / `ref.test_null` — Wasm 3.0 GC
//! §3.3.5.3. Mirror of the arm64 handler: pop one reftype operand (the full
//! 64-bit reftype value), push i32 (1 if the value is an instance of the
//! heap-type immediate, else 0) via the `jitGcRefTest(rt, ref, ht_nullbit)`
//! trampoline. Emit = 3-arg marshal + CALL + capture EAX. 1 → 1. No trap.
//!
//! `ref.test` / `ref.test_null` share this handler — the null-handling bit
//! is folded into arg2 (`ht | (nullbit << 30)`) from `ins.op`, so emit is
//! straight-line. ht is the D-453 encoded u32 (ins.payload); the ref is the
//! popped operand (RSI, 64-bit), read before any argument register is
//! written.
//!
//! Lowering: MOV RSI, ref ; MOV RDI, R15 (rt) ; MOV EDX = ht|nullbit ;
//! MOVABS R10 = &jitGcRefTest ; CALL R10 → EAX = 0/1 ; capture EAX.

const meta = @import("../../../../../instruction/wasm_3_0/ref_test.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const call_scratch: abi.Gpr = .r10; // emit scratch — &fn, then CALL target.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const null_bit: u32 = if (ins.op == .@"ref.test_null") 0x4000_0000 else 0;
    // D-453: ht is the full encoded u32 (concrete-tag = bit 31, idx = bits
    // 0..29, or a bare wire byte) — must NOT be masked to one byte, or a
    // concrete idx ≥ 64 is lost. The null flag is bit 30 (non-colliding).
    const arg2: u32 = @as(u32, @truncate(ins.payload)) | null_bit;
    const args = try ctx.popUnary(); // src=ref, result=i32
    // RSI = ref (64-bit reftype value).
    const xsrc = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    if (xsrc != abi.current.arg_gprs[1]) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[1], xsrc).slice());
    // RDI = rt (R15); EDX = ht|nullbit.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[0], abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(abi.current.arg_gprs[2], arg2).slice());
    // MOVABS R10 = &jitGcRefTest; CALL R10.
    const addr: u64 = @intFromPtr(&jit_abi.jitGcRefTest);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm64Q(call_scratch, addr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());

    // Capture EAX (i32 0/1) → result vreg.
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    if (rd != .rax) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, rd, .rax).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
