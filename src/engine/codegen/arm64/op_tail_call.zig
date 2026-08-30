//! ARM64 tail-call emit helpers (ADR-0112 D2 + D3).
//!
//! Separate from `op_call.zig` per ADR-0112 D2: regular `call`
//! returns to the caller (LR-restored on RET); tail-call
//! consumes the caller's frame and BR-jumps without LR
//! preserving caller's LR for the callee's eventual RET (which
//! returns to caller's caller). Mixing the two shapes in one
//! file would invite single_slot_dual_meaning drift across
//! future work.
//!
//! Per ADR-0112 D3 the full tail-call emit sequence is:
//!
//!   (1) marshal args → X1..X7 / V0..V7   (caller frame still live)
//!   (2) load callee_rt → X0              (from caller's literal pool)
//!   (3) load callee_entry → X16
//!   (4) frame_teardown.emit(…)           (caller's frame disappears)
//!   (5) BR X16                           (no LR; callee RETs to caller's caller)
//!
//! `emitDirectReturnCall` (same-module direct) +
//! `emitIndirectReturnCall` (table-0, ≤2 results) — both wired into
//! `arm64/emit.zig` dispatch via the `ops/wasm_3_0/return_call*.zig`
//! per-op files, and exercised end-to-end through `runI32Export`
//! (the liveness pass treats return_call* as a terminator per
//! ADR-0113 §A; D-205).
//!
//! INVARIANT (ADR-0112 D7): the segment from frame_teardown
//! start through the BR X16 contains NO allocator calls, NO
//! host-call dispatches, NO signal-check branches. This file
//! is the natural home for that invariant's audit.
//!
//! Spec: Wasm Core 3.0 §3.3.8.18-20 (tail-call proposal).
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");

const inst = @import("inst.zig");
const gpr = @import("gpr.zig");
const abi = @import("abi.zig");
const ctx_mod = @import("ctx.zig");
const op_call = @import("op_call.zig");
// D-185 root cause: the shared `frame_teardown` facade dispatches
// on `builtin.target.cpu.arch` (host arch). When this arm64 emit
// runs on an x86_64 host (cross-arch byte-snapshot test), the
// shared facade routes to `x86_64/frame_teardown` and writes 1
// byte (POP RBP) instead of 4 (LDP X29,X30) — silent corruption
// of the arm64 byte stream. arm64 emit always wants arm64 bytes
// regardless of host, so import the sibling directly.
const frame_teardown = @import("frame_teardown.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const canonical_type = @import("../shared/canonical_type.zig");
const zir = @import("../../../ir/zir.zig");
const func_mod = @import("../../../runtime/instance/func.zig");

/// X16 — the AAPCS64 intra-procedure-call scratch (IP0) per
/// Arm IHI 0055 §6.4. ADR-0066 § (bridge thunk) already uses
/// X16 as the callee-target-load register; tail-call reuses
/// the same convention so the regalloc layer's pinned-cohort
/// stays a single set.
pub const tail_target_gpr: inst.Xn = 16;

/// Emit step (2) of the ADR-0112 D3 tail-call sequence for
/// the SAME-MODULE case: restore X0 = runtime_ptr so the
/// callee's prologue (which does `MOV X19, X0` per ADR-0017
/// sub-2d-ii) sees the correct runtime pointer. For
/// same-module tail-call, caller_rt == callee_rt and X19 is
/// already correct, so we simply `MOV X0, X19` (encoded as
/// `ORR X0, XZR, X19` per the canonical AAPCS64 idiom).
///
/// Cross-module tail-call (ADR-0112 D4)
/// loads callee_rt from the caller's literal pool instead;
/// that path lives in `cross_module_tail_call.zig`.
pub fn emitLoadCalleeRtSameModule(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
) !void {
    // ORR X0, XZR, X19  ≡  MOV X0, X19 (the canonical move
    // between two GPRs in the AAPCS64 encoding — XZR is reg 31).
    try gpr.writeU32(allocator, buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
}

/// Emit step (5) of the ADR-0112 D3 tail-call sequence: the
/// `BR X16` unconditional branch to the callee entry. Caller
/// MUST have already loaded the callee target into X16 and
/// emitted `frame_teardown.emit(...)` immediately above this
/// (the safepoint-free invariant per ADR-0112 D7).
///
/// `target` is parameterised (default `tail_target_gpr` = 16)
/// so future tests can verify the encoder against alternate
/// targets without polluting the call sites.
pub fn emitTailJump(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    target: inst.Xn,
) !void {
    try gpr.writeU32(allocator, buf, inst.encBr(target));
}

/// Same-module direct tail-call alternative to the BR X16 path:
/// emit a `B 0` placeholder + register a `CallFixup{is_tail=true}`
/// so the post-emit linker patches the imm26 to a PC-relative B
/// (0x14...) targeting the callee body. Refinement of ADR-0112
/// D4 (not deviation): D4 prescribes BR X16 for the cross-module
/// case where the callee target isn't reachable by imm26; for
/// same-module direct the linker has the offset and a single B
/// (one instr) is structurally equivalent to load-then-BR-X16.
///
/// Caller MUST have:
///   (1) marshalled args into X1..X7 / V0..V7,
///   (2) emitted `emitLoadCalleeRtSameModule` (X0 ← X19),
///   (3) emitted `frame_teardown.emit(...)` (caller's frame gone).
/// This helper emits step (5) of the D3 sequence; step (3) is
/// elided because the linker materialises the target directly
/// into the B instruction's imm26.
pub fn emitDirectTailJump(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    call_fixups: *std.ArrayList(ctx_mod.CallFixup),
    target_func_idx: u32,
) !void {
    const fixup_at: u32 = @intCast(buf.items.len);
    try gpr.writeU32(allocator, buf, inst.encB(0));
    try call_fixups.append(allocator, ctx_mod.CallFixup{
        .byte_offset = fixup_at,
        .target_func_idx = target_func_idx,
        .is_tail = true,
    });
}

/// Wasm spec 3.0 §3.3.8.18 (tail-call proposal) — `return_call N`.
/// Orchestrates the ADR-0112 D3 sequence for the same-module
/// direct case:
///   (1) marshal args via `op_call.marshalCallArgs` (X1..X7 + V0..V7),
///   (2) restore X0 = X19 via `emitLoadCalleeRtSameModule`,
///   (3) `frame_teardown.emit(frame_bytes)` (caller's frame gone),
///   (4) `emitDirectTailJump(target_func_idx)` (B + CallFixup).
///
/// Step (3) of D3 (load callee_entry → X16) is elided here because
/// the linker materialises the callee body offset directly into the
/// B instruction's imm26 — saving one instruction over the BR X16
/// path. Cross-module / indirect / ref tail-calls (which can't
/// reach via imm26) take the BR X16 path through follow-on chunks.
///
/// Import-as-callee (`ins.payload < num_imports`) routes to
/// `emitCrossModuleReturnCall` — the cross-module call-and-return
/// lowering (ADR-0112 Amendment 2026-05-30). A frame-consuming
/// tail-jump to a host import doesn't follow v2's prologue
/// convention and would corrupt a same-module grand-caller's pinned
/// cohort; the bridge-thunk call-and-return preserves it.
pub fn emitDirectReturnCall(
    ctx: *ctx_mod.EmitCtx,
    ins: *const zir.ZirInstr,
) ctx_mod.Error!void {
    if (ins.payload >= ctx.func_sigs.len) return ctx_mod.Error.AllocationMissing;
    if (ins.payload < ctx.num_imports) return emitCrossModuleReturnCall(ctx, ins);
    const callee_sig: zir.FuncType = ctx.func_sigs[ins.payload];

    try op_call.marshalCallArgs(ctx, callee_sig);
    try emitLoadCalleeRtSameModule(ctx.allocator, ctx.buf);
    try frame_teardown.emit(ctx.allocator, ctx.buf, .{ .frame_bytes = ctx.frame_bytes });
    try emitDirectTailJump(ctx.allocator, ctx.buf, ctx.call_fixups, @intCast(ins.payload));
}

/// Cross-module `return_call $import` (ADR-0112 Amendment 2026-05-30,
/// D-206 step 2). Lowered as **call-and-return** through the ADR-0066
/// bridge thunk (planted in `host_dispatch_base[idx]`, which
/// save/restores the full pinned cohort X19 + X24-X28 across its BLR)
/// followed by the normal frame teardown + RET — i.e. the emit shape
/// of `call $import` immediately followed by the function epilogue:
///
///   (1) marshal args → X1..X7 / V0..V7
///   (2) emitImportDispatch — BLR the resolved thunk; the callee's
///       result lands in X0/V0 and the thunk restores A's cohort
///   (3) frame_teardown (ADD SP + LDP X29,X30) + RET
///
/// NOT frame-consuming on the cross-module path: arm64 MOV-installs
/// X19 and LOADs X24-X28 from the rt (it does not stack-save the
/// cohort), so a frame-consuming `BR X16` to a different-rt callee
/// would leave the callee's cohort installed when control returns to
/// a same-module grand-caller — the D-142 corruption class in
/// tail-call form. The thunk's call-and-return preserves the cohort.
/// Proper-tail-call cross-module (frame consumed) is deferred to the
/// arm64-prologue-cohort-save work (D-210).
///
/// No `captureCallResult` runs: validation requires the callee result
/// type == this function's result type, so the result already sits in
/// the return register the epilogue's RET hands back. ≤ 2 results only
/// (MEMORY-class return buffer is a D-210 follow-on).
fn emitCrossModuleReturnCall(
    ctx: *ctx_mod.EmitCtx,
    ins: *const zir.ZirInstr,
) ctx_mod.Error!void {
    const callee_sig: zir.FuncType = ctx.func_sigs[ins.payload];
    if (callee_sig.results.len > 2) return ctx_mod.Error.UnsupportedOp; // D-210: MEMORY-class return buffer
    try op_call.marshalCallArgs(ctx, callee_sig);
    try op_call.emitImportDispatch(ctx, @intCast(ins.payload));
    try frame_teardown.emit(ctx.allocator, ctx.buf, .{ .frame_bytes = ctx.frame_bytes });
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encRet(abi.link_register));
}

/// Wasm spec 3.0 §3.3.8.19 (tail-call proposal) —
/// `return_call_indirect type_idx tableidx`. Mirror of
/// `op_call.emitCallIndirect` minus the captureCallResult tail,
/// with frame_teardown inserted between funcptr load and BR X16.
///
/// Tables: `table_idx == 0` uses the pinned per-call cohort (W25 size
/// / X24 typeidx / X26 funcptr); any other table loads size + bases
/// from the JitRuntime at the call site (D-210, mirrors
/// emitCallIndirect's multi-table else-branch). `results.len <= 2`
/// (no MEMORY-class return-buffer dance; the tail-called frame
/// inherits the caller's X8 if any).
///
/// Sequence:
///   (1) pop idx vreg, marshal args (caller's frame still live
///       for outgoing-args stack region),
///   (2) bounds check (CMP W17, W25 ; B.HS cind_bounds_fixup) —
///       trap stub does full epilogue+RET, caller's frame OK,
///   (3) sig check (LDR W16, [X24, X17, LSL #2] ; CMP imm ;
///       B.NE cind_sig_fixup),
///   (4) funcptr load (LDR X16, [X26, X17, LSL #3]),
///   (5) null-funcptr check (CMP X16, #0 ; B.EQ cind_sig_fixup —
///       D-586; reached when a host cleared the mirror via
///       `tableSetRef`, which leaves the typeidx valid so the
///       D-294 sentinel does not fire),
///   (6) MOV X0, X19 (emitLoadCalleeRtSameModule),
///   (7) frame_teardown.emit (caller's frame gone),
///   (8) BR X16 (emitTailJump).
/// Steps (2)-(5) take the multi-table form for `table_idx != 0`.
///
/// NOT-a-safepoint invariant (ADR-0112 D7): the bounds / sig /
/// null-funcptr (D-586) branches all target the trap stub (which
/// does its own epilogue); the path from teardown to BR X16 has no
/// allocator / host-call / signal-check branch.
///
/// Why this may BR to an import while `emitCrossModuleReturnCall`
/// refuses to (D-586): that path routes `return_call $import`
/// through call-and-return because a frame-consuming BR to a
/// different-rt callee would leave the callee's cohort installed
/// when control reaches a same-module grand-caller. Whatever
/// `dispatch[i]` holds returns the cohort intact, but for two
/// DIFFERENT reasons. A cross-module wasm import holds the ADR-0066
/// thunk, which STRs X19/X24, BLRs, LDRs them back and RETs
/// (`shared/thunk.zig`) — an explicit save list, load-bearing rather
/// than incidental: an earlier 56-byte thunk saved only X19, left X24
/// stale, and surfaced as an `imports.1.wasm` sig mismatch. A WASI
/// import, an embedder host func or the `hostDispatchTrap` fallback
/// holds an ordinary `callconv(.c)` function instead, safe because
/// AAPCS64 §6.4.1 makes X19..X28 callee-saved. The fixtures in
/// `runner_trap_test.zig` pin the SECOND case, so do not read the
/// thunk's save list as the guarantee for all of them.
pub fn emitIndirectReturnCall(
    ctx: *ctx_mod.EmitCtx,
    ins: *const zir.ZirInstr,
) ctx_mod.Error!void {
    if (ins.payload >= ctx.module_types.len) return ctx_mod.Error.AllocationMissing;
    const callee_sig: zir.FuncType = ctx.module_types[ins.payload];
    const table_idx: u32 = ins.extra;
    if (callee_sig.results.len > 2) return ctx_mod.Error.UnsupportedOp;

    if (ctx.pushed_vregs.items.len < 1) return ctx_mod.Error.AllocationMissing;
    const idx_vreg = ctx.pushed_vregs.pop().?;

    try op_call.marshalCallArgs(ctx, callee_sig);

    // D-475: an i64 table pops a full 64-bit index (X-form ORR into X17).
    const ci_idx64 = ctx.func.tableIdxType(table_idx) == .i64;
    const w_idx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (ci_idx64) inst.encOrrReg(17, 31, w_idx) else inst.encOrrRegW(17, 31, w_idx));

    const expected_typeidx: u32 = canonical_type.canonicalTypeidx(ctx.module_types, @intCast(ins.payload));
    if (expected_typeidx >= 4096) return ctx_mod.Error.UnsupportedOp;

    if (table_idx == 0) {
        // Table-0 fast path: bounds via X25, sig via X24, funcptr via X26
        // (the pinned per-call cohort) — mirrors emitCallIndirect.
        // Bounds: CMP X17, X25 ; B.HS trap (X-width, D-475: table_size u64).
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(17, 25));
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
            try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at);
        }
        // Sig: LDR W16, [X24, X17, LSL #2] ; CMP W16, #expected ; B.NE trap.
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrWRegLsl2(16, 24, 17));
        // D-294: null slot's typeidx is the maxInt(u32) sentinel — CMN W16,#1 + B.EQ before sig.
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmnImmW(16, 1));
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
            try ctx.uninit_elem_fixups.append(ctx.allocator, fixup_at); // D-294 uninitialized_elem (code 13)
        }
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(16, @intCast(expected_typeidx)));
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ne, 0));
            try ctx.cind_sig_fixups.append(ctx.allocator, fixup_at);
        }
        // Funcptr load: LDR X16, [X26, X17, LSL #3]. X16 = tail-target
        // (per `tail_target_gpr`) — matches the BR X16 in step (7).
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(tail_target_gpr, 26, 17));
        // D-586 — zero funcptr (host-cleared slot, typeidx valid): trap, do not BR.
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(tail_target_gpr, 0));
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
            try ctx.cind_sig_fixups.append(ctx.allocator, fixup_at);
        }
    } else {
        // Multi-table slow path (D-210): load per-table size + bases from
        // the JitRuntime at the call site, mirroring emitCallIndirect's
        // else-branch. Stride-16 indexing into tables_jit_ci_ptr matches
        // TableJitCallInfo (funcptr_base @ +0, typeidx_base @ +8). The
        // funcptr lands in tail_target_gpr (X16) for the BR.
        if (jit_abi.table_jit_ci_size != 16) @compileError("multi-table tail-call assumes TableJitCallInfo stride 16");
        const rt_reg: inst.Xn = abi.runtime_ptr_save_gpr;
        // Bounds: len = tables_ptr[table_idx].len (u64 X-form, D-475).
        const tbl_slice_byte_off: u32 = (table_idx * jit_abi.table_slice_size) + jit_abi.tableslice_len_off;
        if (tbl_slice_byte_off > 32760) return ctx_mod.Error.UnsupportedOp;
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, rt_reg, jit_abi.tables_ptr_off));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, 16, @intCast(tbl_slice_byte_off)));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(17, 16));
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
            try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at);
        }
        // Sig: typeidx_base = tables_jit_ci_ptr[table_idx].typeidx_base ;
        // LDR W16, typeidx_base[idx] ; CMP ; B.NE trap.
        const ci_typeidx_byte_off: u32 = (table_idx * 16) + 8;
        if (ci_typeidx_byte_off > 32760) return ctx_mod.Error.UnsupportedOp;
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, rt_reg, jit_abi.tables_jit_ci_ptr_off));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, 16, @intCast(ci_typeidx_byte_off)));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrWRegLsl2(16, 16, 17));
        // D-294: null slot's typeidx is the maxInt(u32) sentinel — CMN W16,#1 + B.EQ before sig.
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmnImmW(16, 1));
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
            try ctx.uninit_elem_fixups.append(ctx.allocator, fixup_at); // D-294 uninitialized_elem (code 13)
        }
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(16, @intCast(expected_typeidx)));
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ne, 0));
            try ctx.cind_sig_fixups.append(ctx.allocator, fixup_at);
        }
        // Funcptr: funcptr_base = tables_jit_ci_ptr[table_idx].funcptr_base ;
        // LDR X16, funcptr_base[idx] → tail_target_gpr for the BR.
        const ci_funcptr_byte_off: u32 = table_idx * 16;
        if (ci_funcptr_byte_off > 32760) return ctx_mod.Error.UnsupportedOp;
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, rt_reg, jit_abi.tables_jit_ci_ptr_off));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, 16, @intCast(ci_funcptr_byte_off)));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(tail_target_gpr, 16, 17));
        // D-586 — zero funcptr (host-cleared slot, typeidx valid): trap, do not BR.
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(tail_target_gpr, 0));
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
            try ctx.cind_sig_fixups.append(ctx.allocator, fixup_at);
        }
    }

    try emitLoadCalleeRtSameModule(ctx.allocator, ctx.buf);
    try frame_teardown.emit(ctx.allocator, ctx.buf, .{ .frame_bytes = ctx.frame_bytes });
    try emitTailJump(ctx.allocator, ctx.buf, tail_target_gpr);
}

/// Wasm spec 3.0 §3.3.8.20 (`return_call_ref $sig`) — tail-call
/// through a typed funcref. The tail-call variant of `call_ref`:
/// `op_call.emitCallRef`'s funcref front-half (pop `*FuncEntity` +
/// null-check + load native entry) followed by this file's tail
/// shape (MOV X0=X19 → frame_teardown → BR X16) instead of CALL +
/// capture. Sequence:
///   (1) pop funcref vreg (stack: [args..., funcref]),
///   (2) marshalCallArgs (caller frame still live for outgoing args),
///   (3) funcref ptr → X17 ; CMP X17, #0 ; B.EQ trap (null),
///   (4) LDR X16, [X17, #funcentity_funcptr_offset]  (native entry),
///   (5) MOV X0, X19 (runtime_ptr) ; frame_teardown ; BR X16.
/// No runtime sig check (validator guarantees funcref type ⊑ `$sig`).
/// Terminator + safepoint-free (ADR-0112 D7 / ADR-0113 §A); liveness
/// already classifies `return_call_ref` as a terminator.
pub fn emitReturnCallRef(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    if (ins.payload >= ctx.module_types.len) return ctx_mod.Error.AllocationMissing;
    const callee_sig: zir.FuncType = ctx.module_types[ins.payload];
    if (callee_sig.results.len > 2) return ctx_mod.Error.UnsupportedOp;

    if (ctx.pushed_vregs.items.len < 1) return ctx_mod.Error.AllocationMissing;
    const funcref_vreg = ctx.pushed_vregs.pop().?;

    try op_call.marshalCallArgs(ctx, callee_sig);

    // Funcref ptr → X17 ; null-check (CMP X17,#0 ; B.EQ trap). Reuses
    // the call_indirect bounds trap stub (cind_bounds_fixups).
    const x_funcref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, funcref_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(17, 31, x_funcref));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(17, 0));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
        try ctx.null_ref_fixups.append(ctx.allocator, fixup_at); // null_reference (code 10), as call_ref reports
    }

    // Native entry: LDR X16, [X17, #funcentity_funcptr_offset]
    // (X16 = tail_target_gpr — matches the BR X16 below).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(tail_target_gpr, 17, @intCast(func_mod.funcentity_funcptr_offset)));

    try emitLoadCalleeRtSameModule(ctx.allocator, ctx.buf);
    try frame_teardown.emit(ctx.allocator, ctx.buf, .{ .frame_bytes = ctx.frame_bytes });
    try emitTailJump(ctx.allocator, ctx.buf, tail_target_gpr);
}

// ---------------------------------------------------------------------
// Unit tests — byte-level snapshots for the BR encoder. These run on
// every host since the arm64 encoders are pure comptime helpers.
// ---------------------------------------------------------------------

const testing = std.testing;

test "op_tail_call arm64: emitTailJump X16 → 0xD61F0200 (canonical AAPCS64 tail-jump)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitTailJump(testing.allocator, &buf, tail_target_gpr);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(@as(u32, 0xD61F0200), word);
}

test "op_tail_call arm64: emitTailJump X17 — alternate IP1 target (Arm IHI 0055 §6.4)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitTailJump(testing.allocator, &buf, 17);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst.encBr(17), word);
}

test "op_tail_call arm64: tail_target_gpr matches ADR-0066 thunk convention (X16 = IP0)" {
    try testing.expectEqual(@as(inst.Xn, 16), tail_target_gpr);
}

test "op_tail_call arm64: emitLoadCalleeRtSameModule emits MOV X0, X19 (ORR X0, XZR, X19)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitLoadCalleeRtSameModule(testing.allocator, &buf);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst.encOrrReg(0, 31, 19), word);
}

test "op_tail_call arm64: emitLoadCalleeRtSameModule uses abi.runtime_ptr_save_gpr (X19) as source" {
    try testing.expectEqual(@as(inst.Xn, 19), abi.runtime_ptr_save_gpr);
}

test "op_tail_call arm64: emitDirectTailJump appends B 0 placeholder + is_tail=true CallFixup" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var fixups: std.ArrayList(ctx_mod.CallFixup) = .empty;
    defer fixups.deinit(testing.allocator);

    // Pre-pad the buffer so the fixup's byte_offset is non-zero
    // (better regression value than the trivial start-of-function
    // case).
    try gpr.writeU32(testing.allocator, &buf, inst.encOrrReg(0, 31, 19)); // 4-byte prelude

    try emitDirectTailJump(testing.allocator, &buf, &fixups, 7);

    // Buffer grew by exactly one 4-byte placeholder.
    try testing.expectEqual(@as(usize, 8), buf.items.len);
    const placeholder = std.mem.readInt(u32, buf.items[4..8], .little);
    try testing.expectEqual(inst.encB(0), placeholder);

    // Fixup records the right offset + target + is_tail flag.
    try testing.expectEqual(@as(usize, 1), fixups.items.len);
    try testing.expectEqual(@as(u32, 4), fixups.items[0].byte_offset);
    try testing.expectEqual(@as(u32, 7), fixups.items[0].target_func_idx);
    try testing.expectEqual(true, fixups.items[0].is_tail);
}

test "op_tail_call arm64: emitDirectTailJump byte_offset tracks pre-existing buf length" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var fixups: std.ArrayList(ctx_mod.CallFixup) = .empty;
    defer fixups.deinit(testing.allocator);

    // Three preludes — verify the fixup tracks current cursor.
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try gpr.writeU32(testing.allocator, &buf, inst.encOrrReg(0, 31, 19));
    }

    try emitDirectTailJump(testing.allocator, &buf, &fixups, 0);

    try testing.expectEqual(@as(u32, 12), fixups.items[0].byte_offset);
}
