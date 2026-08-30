//! ARM64 emit pass — function call handlers.
//!
//! Per ADR-0021 sub-deliverable b (emit.zig
//! 9-module split): direct `call N` and indirect `call_indirect
//! type_idx` ZirOps, with the AAPCS64 arg-marshalling and
//! return-capture helpers they share.
//!
//! Direct call (`call N`):
//!   - Marshal args into X1..X7 / V0..V7.
//!   - Restore X0 = runtime_ptr (ADR-0017 sub-2d-ii: X0 is
//!     caller-saved per AAPCS64; may have been clobbered by an
//!     earlier call).
//!   - Emit BL placeholder; append CallFixup for the post-emit
//!     linker to patch with the concrete imm26 disp.
//!   - Capture return value into the next vreg.
//!
//! Indirect call (`call_indirect type_idx`):
//!   - Pop the index; marshal args.
//!   - Bounds check (CMP W17, W25 = table_size; B.HS trap).
//!   - Sig check (LDR typeidx[idx]; CMP vs expected; B.NE trap).
//!   - Funcptr load (LDR X17, [X26, X17, LSL #3]); null check
//!     (CMP X17, #0; B.EQ trap — D-586); restore X0; BLR X17.
//!   - Capture return value.
//!
//! marshalCallArgs / captureCallResult: ≤ 7 GPR + ≤ 8 FP args in
//! registers (X1..X7 + V0..V7); overflow args spill to the
//! caller's pre-allocated outgoing-args region per AAPCS64 §6.4.2.
//! This region sits at the BOTTOM of the
//! caller's frame: locals + spills shift up by `local_base_off`
//! so `[SP, #(K*8)]` for K = 0..n_stack_args-1 is reserved for
//! outgoing args and the callee reads them at `[X29, #(16+8*K)]`.
//! No SP movement around BL/BLR is needed — the region stays
//! allocated for the function's lifetime. Reftype params (funcref
//! / externref) ride the i64 X-form gpr-class path per ADR-0061
//! (D-093); v128 has its own SIMD-class path.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const dbg = @import("../../../support/dbg.zig");
const builtin = @import("builtin");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_fp = @import("inst_fp.zig");
const inst_neon = @import("inst_neon.zig");
const abi = @import("abi.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const canonical_type = @import("../shared/canonical_type.zig");
const func_mod = @import("../../../runtime/instance/func.zig");

const ZirInstr = zir.ZirInstr;
const FuncType = zir.FuncType;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;
const CallFixup = ctx_mod.CallFixup;

/// ADR-0155 stage 2 (D-265 Phase IV) — spill EVERY register-homed local to its
/// in-frame slot BEFORE a BL/BLR, then reload after. D-291: this MUST include
/// callee-saved-bank homes (X20..X22) — per ADR-0060 the JIT prologue installs
/// invariants into X19..X28 WITHOUT stack-saving them, so a JIT callee that homes
/// a local in X20..X22 clobbers the caller's value (NOT AAPCS64 callee-preserved).
/// Call after args are marshalled (so the home register still holds the local's
/// current value — `local.set` writes the home reg directly, so the register IS
/// the live value). Paired with `reloadHomedCallerSaved` after the call (omitted
/// for tail calls, where control does not return).
fn spillHomedCallerSaved(ctx: *EmitCtx) Error!void {
    try homedCallerSavedSpillReload(ctx, .spill);
}

/// Reload every register-homed local from its in-frame slot AFTER a BL/BLR
/// (before the result is captured). Inverse of `spillHomedCallerSaved`.
pub fn reloadHomedCallerSaved(ctx: *EmitCtx) Error!void {
    try homedCallerSavedSpillReload(ctx, .reload);
}

const SpillDir = enum { spill, reload };

/// Shared body for the spill-before / reload-after of register-homed locals.
/// For each homed rank, resolves the home pseudo-vreg's regalloc slot; every
/// register-resident home (caller- OR callee-saved, D-291) emits an STR (spill) /
/// LDR (reload) at `local_base_off + local_offsets[lidx]`.
/// i32 homes use the W-form (zero-extended, matching the prologue seed + the
/// `local.get`/`set` W-form contract); i64 homes use the X-form.
fn homedCallerSavedSpillReload(ctx: *EmitCtx, dir: SpillDir) Error!void {
    const homing = ctx.homing;
    if (homing.count == 0) return;
    var r: u32 = 0;
    while (r < homing.count) : (r += 1) {
        const home_vreg: u32 = ctx.n_temp + r;
        const home_reg: inst.Xn = switch (ctx.alloc.slot(home_vreg, .gpr)) {
            // D-291: the callee-saved bank (X20..X22) is NOT preserved across a
            // JIT-to-JIT call — per ADR-0060 the JIT prologue installs runtime
            // invariants into X19..X28 but does NOT stack-save them, and a callee
            // that homes a local in X20..X22 clobbers it. So a call-crossing local
            // homed in a callee-saved reg must ALSO be spilled/reloaded here (the
            // old `id >= callee_saved_slot_boundary → continue` skip wrongly assumed
            // AAPCS64 callee-preservation; func 11 in ed25519 lost its saved-SP
            // local2 across `call 14`/`call 17`, over-restoring __stack_pointer).
            .reg => |id| abi.slotToReg(id) orelse return Error.SlotOverflow,
            // A spilled home already lives in its frame slot across the call;
            // nothing to save/restore.
            .spill => continue,
        };
        const lidx: u32 = homing.local_idx[r];
        const off_u: u32 = ctx.local_base_off + ctx.local_offsets[lidx];
        const ty = ctx.func.localValType(lidx);
        switch (ty) {
            // D-331(B): large-frame-safe. The reload destination doubles as the
            // address scratch (frameLdrGpr); the spill value occupies home_reg so
            // its store materialises the address into spill_stage_gprs[0] (X14 —
            // non-allocatable, free across the call). Small offsets stay
            // byte-identical to the prior inline STR/LDR.
            .i32 => switch (dir) {
                .spill => try gpr.frameStrGpr(ctx.allocator, ctx.buf, home_reg, off_u, true, abi.spill_stage_gprs[0]),
                .reload => try gpr.frameLdrGpr(ctx.allocator, ctx.buf, home_reg, off_u, true),
            },
            .i64 => switch (dir) {
                .spill => try gpr.frameStrGpr(ctx.allocator, ctx.buf, home_reg, off_u, false, abi.spill_stage_gprs[0]),
                .reload => try gpr.frameLdrGpr(ctx.allocator, ctx.buf, home_reg, off_u, false),
            },
            // local_homing.isHomeableType only homes i32/i64.
            .f32, .f64, .v128, .ref => unreachable,
        }
    }
}

/// ADR-0069: per-call overflow-args byte
/// count, mirroring `marshalCallArgs`'s allocation logic. Returns
/// the size of the `[SP, #0..N-1]` overflow region this call's
/// stack args occupy. The MEMORY-class return buffer (when the
/// callee triggers it) sits immediately above at
/// `[SP, #N..N + n_results*8 - 1]`. v128 args are excluded
/// (current callees' v128 args ride V0..V7 in-pool; future
/// overflow-v128 needs its own 16 B aligned slot accounting).
fn computeCallOverflowBytes(callee_sig: FuncType) u32 {
    var n_int: u32 = 0;
    var n_fp: u32 = 0;
    for (callee_sig.params) |p| {
        switch (p) {
            .i32, .i64, .ref => n_int += 1,
            .f32, .f64 => n_fp += 1,
            .v128 => {},
        }
    }
    const n_int_overflow: u32 = if (n_int > 7) n_int - 7 else 0;
    const n_fp_overflow: u32 = if (n_fp > 8) n_fp - 8 else 0;
    return (n_int_overflow + n_fp_overflow) * 8;
}

/// Wasm spec §3.4.7 (call N) — direct call. Looks up
/// `func_sigs[N]` for the callee signature, marshals args, emits
/// BL placeholder + CallFixup, captures the result.
///
/// If `N < num_imports` (the leading
/// wasm-space slots that name imports), the call routes to the
/// function-local trap stub instead of a body-relative BL —
/// **every import call traps unconditionally** until the
/// host-call dispatcher is wired up. Args are still marshalled
/// (harmless waste; the trap branch jumps over the rest of the
/// call sequence) and the result vreg is still allocated /
/// pushed so post-call ops that pop it find a slot, even though
/// they never execute (the unconditional B redirects control to
/// the trap stub which RETs out of the function).
pub fn emitCall(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ins.payload >= ctx.func_sigs.len) return Error.AllocationMissing;
    const callee_sig: FuncType = ctx.func_sigs[ins.payload];

    try marshalCallArgs(ctx, callee_sig);

    // ADR-0017 2026-05-18 amend / ADR-0069:
    // when callee returns MEMORY-class (struct > 16 B per AAPCS64
    // §6.8.2; v2 trigger = `results.len > 2`), allocate a buffer
    // at the top of THIS call's outgoing-args footprint and LEA
    // its address into X8 before the BL. The callee's prologue
    // saves X8 to its own frame slot; the epilogue writes each
    // result via `[X8, #(i*8)]`. After return, this caller reads
    // results back from the same buffer in `captureCallResult`.
    const memory_class_return: bool = callee_sig.results.len > 2;
    const return_buffer_off: u32 = if (memory_class_return) computeCallOverflowBytes(callee_sig) else 0;
    if (memory_class_return) {
        if (return_buffer_off > 4095) return Error.UnsupportedOp; // imm12 budget
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(8, 31, @intCast(return_buffer_off)));
    }

    if (ins.payload < ctx.num_imports) {
        // Host-import dispatch. Indirect call via
        // `JitRuntime.host_dispatch_base[idx]`. Args are already in
        // X1..X7 (marshalCallArgs above); restore X0 = runtime_ptr
        // so the host stub sees the JitRuntime ptr as its hidden
        // first arg (the host fn signature is
        // `fn(rt: *JitRuntime, ...wasm_args) callconv(.c)`).
        //
        //   (see emitImportDispatch for the 4-instr sequence)
        try spillHomedCallerSaved(ctx);
        try emitImportDispatch(ctx, @intCast(ins.payload));
        try reloadHomedCallerSaved(ctx);
        try captureCallResult(ctx, callee_sig, memory_class_return, return_buffer_off);
        try emitPostCallTrapCheck(ctx);
        return;
    }

    // ADR-0017 sub-2d-ii: restore runtime_ptr in X0 (X0 is
    // caller-saved per AAPCS64, may have been clobbered by an
    // earlier call in this function).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));

    // ADR-0155 stage 2 — spill caller-saved register-homed locals before the
    // BL (after args + rt-ptr restore, so the spill captures the live home reg).
    try spillHomedCallerSaved(ctx);

    // BL placeholder; the post-emit linker patches via
    // EmitOutput.call_fixups once function-body offsets are known.
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBL(0));
    try ctx.call_fixups.append(ctx.allocator, CallFixup{
        .byte_offset = fixup_at,
        .target_func_idx = @intCast(ins.payload),
    });

    // Reload the homed locals from their slots before capturing the result.
    try reloadHomedCallerSaved(ctx);

    try captureCallResult(ctx, callee_sig, memory_class_return, return_buffer_off);
    try emitPostCallTrapCheck(ctx);
}

/// ADR-0199 (D-468): after ANY call, if the callee set `trap_flag` (proc_exit,
/// a trapping host import, or a transitively-trapping wasm callee), unwind to
/// this function's epilogue HERE instead of executing the next op. Mirrors the
/// interp's "check exit/trap after each host-call return + short-circuit"
/// (proc.zig/mvp.zig). Branches to the CLEAN epilogue (via `return_fixups`, an
/// unconditional B patched at finalization) — NOT the trap stub — so the
/// host-set `trap_flag`/`trap_kind`/`exit_code` survive (proc_exit must still
/// surface "program-requested exit"). W17 is scratch (not in the regalloc pool)
/// and the call result is already captured, so clobbering it is safe.
fn emitPostCallTrapCheck(ctx: *EmitCtx) Error!void {
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(17, abi.runtime_ptr_save_gpr, jit_abi.trap_flag_off));
    // trap_flag == 0 → skip the branch (CBZ lands 2 words ahead, past the B).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbz(17, 2));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    try ctx.return_fixups.append(ctx.allocator, fixup_at);
}

/// Emit the host-import indirect dispatch (ADR-0066): load
/// the resolved slot from
/// `JitRuntime.host_dispatch_base[import_idx]`, restore X0 =
/// runtime_ptr (the host stub / bridge thunk's hidden first arg),
/// then `BLR X16`:
///
///   LDR X16, [X19, #host_dispatch_base_off]   ; ptr-of-ptrs
///   LDR X16, [X16, #(idx*8)]                   ; actual fn / thunk ptr
///   ORR X0, XZR, X19                           ; restore rt_ptr
///   BLR X16
///
/// Args MUST already be marshalled into X1..X7 / V0..V7; the result
/// lands in the AAPCS64 return register(s) per the callee sig. Shared
/// by `emitCall`'s import branch and
/// `op_tail_call.emitCrossModuleReturnCall` (the cross-module
/// `return_call` call-and-return path, ADR-0112 Amendment 2026-05-30).
/// `idx * 8` must fit the LDR imm12 budget (≤ 32760) — UnsupportedOp
/// otherwise (realistic import counts stay well under).
pub fn emitImportDispatch(ctx: *EmitCtx, import_idx: u32) Error!void {
    const idx_byte_off_u: u64 = @as(u64, import_idx) * 8;
    if (idx_byte_off_u > 32760) return Error.UnsupportedOp;
    const idx_byte_off: u15 = @intCast(idx_byte_off_u);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.host_dispatch_base_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, 16, idx_byte_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(16));
}

/// D-235 — ARM64 `call_indirect` emit for SUBTYPING modules (Wasm §3.3.5.5).
/// Replaces the inline D-111 structural sig CMP (finality/subtype-blind) with
/// a `jitCallIndirectResolve` trampoline. Sequence: read idx → CALL resolve
/// (rt, table_idx, idx, expected_raw) → X0 = funcptr | 0 → trap on 0 → stash
/// funcptr in X17 (survives the arg marshal — marshal touches X1..X7/V0..V7 +
/// stage regs + SP, never X16/X17) → marshal args → MEMORY-class X8 buffer →
/// MOV X0,rt ; BLR X17 → capture. The trampoline runs BEFORE marshalling so
/// its caller-saved clobber can't corrupt marshalled args; operands are
/// force-spilled (regalloc inclusive crossing for call_indirect when the
/// module uses subtyping) so they survive it. `expected_raw` / `table_idx`
/// must fit MOVZ imm16 (4096+-type modules are rejected elsewhere).
fn emitCallIndirectSubtype(
    ctx: *EmitCtx,
    ins: *const ZirInstr,
    callee_sig: FuncType,
    idx_vreg: u32,
    table_idx: u32,
) Error!void {
    const expected_raw: u32 = @intCast(ins.payload);
    if (expected_raw > 0xFFFF or table_idx > 0xFFFF) return Error.UnsupportedOp;

    // ADR-0155 stage 2 — spill caller-saved homed locals BEFORE the resolve
    // trampoline (it clobbers caller-saved regs just like the final BLR). The
    // home regs are still live here (idx is read via stage/temp regs, not a
    // home); they are reloaded after the final BLR below. No homed local is
    // read between here and the reload (marshalCallArgs reads temps).
    try spillHomedCallerSaved(ctx);

    // Trampoline args: X0=rt, W1=table_idx, X2=idx (u64 per D-475 —
    // an i32 table's idx stages W-form zero-extended; an i64 table's
    // full 64 bits via X-form), W3=expected_raw. Read idx into X2
    // first; its home reg is never X0..X3 (those aren't in the regalloc
    // pool), so the later arg-reg writes can't clobber it.
    const idx64 = ctx.func.tableIdxType(table_idx) == .i64;
    const w_idx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_vreg, 0);
    if (w_idx != 2) try gpr.writeU32(ctx.allocator, ctx.buf, if (idx64) inst.encOrrReg(2, 31, w_idx) else inst.encOrrRegW(2, 31, w_idx));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(1, @intCast(table_idx)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(3, @intCast(expected_raw)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    // ADR-0203 D1 — helper via the rt slot ([X19+off]), not a baked imm64 (D-516 PIC).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.call_indirect_resolve_fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(16));

    // X0 = funcptr | 0 (sig-subtype fail) | 1 (NULL_ELEM_SENTINEL) | 2 (OOB_ELEM_SENTINEL).
    // D-294 residual: CMP X0,#1 FIRST → uninitialized_elem (code 13), so a null
    // elem under a subtyping module matches the inline non-subtyping path + interp
    // + wasmtime/wasmer, instead of the generic sig-mismatch the 0-trap reports.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(0, 1));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
        try ctx.uninit_elem_fixups.append(ctx.allocator, fixup_at);
    }
    // CMP X0,#2 ; B.EQ → call_indirect bounds stub (trap_kind 2, #357).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(0, 2));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at);
    }
    // CMP X0,#0 (64-bit) ; B.EQ → call_indirect sig-trap stub (trap_kind 3).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(0, 0));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
        try ctx.cind_sig_fixups.append(ctx.allocator, fixup_at);
    }
    // Stash funcptr in X17 (reserved scratch; survives marshalCallArgs).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(17, 31, 0));

    // Marshal args now (trampoline done → no marshalled-arg clobber).
    try marshalCallArgs(ctx, callee_sig);
    const memory_class_return: bool = callee_sig.results.len > 2;
    const return_buffer_off: u32 = if (memory_class_return) computeCallOverflowBytes(callee_sig) else 0;
    if (memory_class_return) {
        if (return_buffer_off > 4095) return Error.UnsupportedOp;
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(8, 31, @intCast(return_buffer_off)));
    }
    // MOV X0, rt ; BLR X17.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(17));
    try reloadHomedCallerSaved(ctx);
    try captureCallResult(ctx, callee_sig, memory_class_return, return_buffer_off);
    try emitPostCallTrapCheck(ctx);
}

/// Indirect call: `call_indirect type_idx tableidx`. Pops the
/// index, marshals args, runs bounds + sig checks (both branch
/// to the shared trap stub via ctx.bounds_fixups), loads the
/// funcptr, restores X0, BLR.
///
/// **Multi-table dispatch** (D-112):
/// `ins.extra` carries the table_idx LEB128 byte from
/// lower.zig:927 (Wasm 2.0 §3.4.6 `call_indirect tableidx
/// typeidx`). For table_idx == 0 the fast path uses the
/// reserved-reg preloads X25 (table_size) / X24 (typeidx_base)
/// / X26 (funcptr_base) populated by the prologue from the
/// scalar JitRuntime fields. For table_idx > 0 the slow path
/// loads per-table size + bases from
/// `JitRuntime.tables_ptr[table_idx].len` + `tables_jit_ci_ptr
/// [table_idx]` at the call site; the legacy scalar regs stay
/// table-0-only.
pub fn emitCallIndirect(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ins.payload >= ctx.module_types.len) return Error.AllocationMissing;
    const callee_sig: FuncType = ctx.module_types[ins.payload];
    const table_idx: u32 = ins.extra;

    // Stack at entry: [args..., idx]. Pop idx first.
    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_vreg = ctx.pushed_vregs.pop().?;

    // D-235: subtyping modules route the sig check through the
    // `jitCallIndirectResolve` trampoline (the inline D-111 structural CMP
    // is finality/subtype-blind). The trampoline runs BEFORE marshalling, so
    // its caller-saved clobber can't corrupt marshalled args; operands are
    // force-spilled (regalloc inclusive crossing) so they survive it.
    if (ctx.uses_type_subtyping) {
        return emitCallIndirectSubtype(ctx, ins, callee_sig, idx_vreg, table_idx);
    }

    try marshalCallArgs(ctx, callee_sig);

    // ADR-0017 2026-05-18 amend / ADR-0069:
    // Mirror of `emitCall`'s MEMORY-class LEA — when callee returns
    // > 16 B composite, the caller hands a buffer pointer in X8.
    // Emitted post-marshalCallArgs so the buffer LEA doesn't fight
    // X1..X7 / V0..V7 arg shuffling; X16/X17 used later for sig +
    // funcptr work are caller-saved scratch disjoint from X8.
    const memory_class_return: bool = callee_sig.results.len > 2;
    const return_buffer_off: u32 = if (memory_class_return) computeCallOverflowBytes(callee_sig) else 0;
    if (memory_class_return) {
        if (return_buffer_off > 4095) return Error.UnsupportedOp;
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(8, 31, @intCast(return_buffer_off)));
    }

    // Bounds + sig check using the trap-stub at function tail
    // (shared with memory bounds — single trap reason today;
    // Diagnostic M3 / D-022 splits them later). D-475: an i64 table
    // pops a full 64-bit index (X-form ORR into X17).
    const ci_idx64 = ctx.func.tableIdxType(table_idx) == .i64;
    const w_idx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (ci_idx64) inst.encOrrReg(17, 31, w_idx) else inst.encOrrRegW(17, 31, w_idx));

    const expected_typeidx: u32 = canonical_type.canonicalTypeidx(ctx.module_types, @intCast(ins.payload));
    // Skeleton restricts expected typeidx to imm12 range
    // (4096 distinct types is well above any realistic module's
    // needs); larger canonical typeidx → UnsupportedOp.
    if (expected_typeidx >= 4096) return Error.UnsupportedOp;

    if (table_idx == 0) {
        // Table-0 fast path: bounds via X25, sig via X24, funcptr via X26.

        // Bounds: CMP X17, X25 ; B.HS trap. X-width (D-475): the
        // pinned table_size is u64; the i32-table idx in X17 is
        // zero-extended by its W-form stage, so the wider compare
        // is byte-identical in outcome.
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(17, 25));
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
            try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at);
        }

        // Sig: LDR W16, [X24, X17, LSL #2] ; CMP W16, #canonical ;
        // B.NE trap. Wasm spec §3.4.6 + §4.4.10.1 — the sig check is
        // **structural** FuncType equality. Compare against the
        // canonical (lowest-index) typeidx whose shape matches
        // `module_types[ins.payload]`; `applyTableInit` writes the
        // same canonicalization on the funcref's stored typeidx. D-111.
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrWRegLsl2(16, 24, 17));
        // D-294: null slot's typeidx is maxInt(u32) (no-func sentinel). CMN W16,#1
        // sets Z iff W16 == 0xFFFFFFFF; check BEFORE the sig CMP so a null elem
        // reports uninitialized_elem (code 13). CMN leaves W16 intact for the CMP.
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

        // Funcptr load + BLR. Restore X0 = runtime_ptr (ADR-0017
        // sub-2d-ii) before transferring control.
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(17, 26, 17));
        // D-586 — see the x86_64 mirror. X17 = funcptr; zero means a host
        // cleared the slot via `tableSetRef` (typeidx still valid).
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(17, 0));
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
            try ctx.cind_sig_fixups.append(ctx.allocator, fixup_at);
        }
    } else {
        // Multi-table slow path: load per-table size + bases from
        // JitRuntime at the call site. Stride-16 indexing into
        // tables_jit_ci_ptr matches `TableJitCallInfo`'s extern
        // layout (funcptr_base @ +0, typeidx_base @ +8).
        const ci_stride: u32 = jit_abi.table_jit_ci_size;
        if (ci_stride != 16) @compileError("multi-table emit assumes TableJitCallInfo stride 16");
        // The runtime_ptr lives in X19 (= abi.runtime_ptr_save_gpr).
        const rt_reg: inst.Xn = abi.runtime_ptr_save_gpr;

        // TODO: table storage shape — see D-126 / ADR-0068.
        // Bounds: load size from tables_ptr[table_idx].len (TableSlice
        // len offset within the `table_slice_size` stride; u64 X-form
        // load per D-475). Reject if table_idx exceeds the per-call
        // imm12 budget; the @intCast on the encoded X-form imm12
        // catches out-of-range at codegen time.
        const tbl_slice_byte_off: u32 = (table_idx * jit_abi.table_slice_size) + jit_abi.tableslice_len_off;
        if (tbl_slice_byte_off > 32760) return Error.UnsupportedOp;
        // LDR X16, [rt, #tables_ptr_off]
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, rt_reg, jit_abi.tables_ptr_off));
        // LDR X16, [X16, #(table_idx*table_slice_size + len_off)]
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, 16, @intCast(tbl_slice_byte_off)));
        // CMP X17, X16 (X-width, D-475: len is u64)
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(17, 16));
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
            try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at);
        }

        // Sig: load typeidx_base = tables_jit_ci_ptr[table_idx].typeidx_base.
        const ci_typeidx_byte_off: u32 = (table_idx * 16) + 8;
        if (ci_typeidx_byte_off > 32760) return Error.UnsupportedOp;
        // LDR X16, [rt, #tables_jit_ci_ptr_off]
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, rt_reg, jit_abi.tables_jit_ci_ptr_off));
        // LDR X16, [X16, #(table_idx*16 + 8)]  — typeidx_base pointer
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, 16, @intCast(ci_typeidx_byte_off)));
        // LDR W16, [X16, W17, LSL #2]  — typeidx_base[idx]
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

        // Funcptr: load funcptr_base = tables_jit_ci_ptr[table_idx].funcptr_base.
        const ci_funcptr_byte_off: u32 = table_idx * 16;
        if (ci_funcptr_byte_off > 32760) return Error.UnsupportedOp;
        // LDR X16, [rt, #tables_jit_ci_ptr_off]
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, rt_reg, jit_abi.tables_jit_ci_ptr_off));
        // LDR X16, [X16, #(table_idx*16 + 0)]  — funcptr_base pointer
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, 16, @intCast(ci_funcptr_byte_off)));
        // LDR X17, [X16, X17, LSL #3]  — funcptr_base[idx]
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(17, 16, 17));
        // D-586 — see the x86_64 mirror. X17 = funcptr; zero means a host
        // cleared the slot via `tableSetRef` (typeidx still valid).
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(17, 0));
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
            try ctx.cind_sig_fixups.append(ctx.allocator, fixup_at);
        }
    }

    // ADR-0155 stage 2 — spill caller-saved homed locals just before the BLR
    // (after the bounds/sig/funcptr pipeline, which uses X16/X17 + W17 = idx,
    // none of which is a homed local's home register).
    try spillHomedCallerSaved(ctx);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(17));
    try reloadHomedCallerSaved(ctx);

    try captureCallResult(ctx, callee_sig, memory_class_return, return_buffer_off);
    try emitPostCallTrapCheck(ctx);
}

/// Wasm spec 3.0 §3.3.8.13 (`call_ref $sig`) — call through a typed
/// funcref. The funcref operand is `@intFromPtr(*const FuncEntity)`
/// (the `ref.func` / `Value.fromFuncRef` encoding, ADR-0014 §2.1).
/// Sequence mirrors `emitCallIndirect` MINUS the bounds/sig check:
/// the validator guarantees the funcref's actual type ⊑ `$sig`, so
/// only a null trap is needed (call_ref of a null funcref traps,
/// §4.4.8.13). NOT a terminator (returns + pushes results).
///   (1) pop funcref vreg (stack: [args..., funcref]),
///   (2) marshalCallArgs (X1..X7 / V0..V7),
///   (3) MEMORY-class return-buffer LEA into X8 if results.len > 2,
///   (4) funcref ptr → X17 ; CMP X17, #0 ; B.EQ trap (null),
///   (5) LDR X16, [X17, #funcentity_funcptr_offset]  (native entry),
///   (6) MOV X0, X19 (runtime_ptr) ; BLR X16,
///   (7) captureCallResult.
/// The null trap reuses the call_indirect bounds trap stub
/// (trap_kind 2 — single trap stub today; trap-message precision is
/// a follow-up).
pub fn emitCallRef(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ins.payload >= ctx.module_types.len) return Error.AllocationMissing;
    const callee_sig: FuncType = ctx.module_types[ins.payload];

    // Stack at entry: [args..., funcref]. Pop funcref first.
    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const funcref_vreg = ctx.pushed_vregs.pop().?;

    try marshalCallArgs(ctx, callee_sig);

    const memory_class_return: bool = callee_sig.results.len > 2;
    const return_buffer_off: u32 = if (memory_class_return) computeCallOverflowBytes(callee_sig) else 0;
    if (memory_class_return) {
        if (return_buffer_off > 4095) return Error.UnsupportedOp;
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(8, 31, @intCast(return_buffer_off)));
    }

    // Load funcref pointer into X17 (caller-saved scratch, disjoint
    // from X1..X7 args + X8 return-buffer).
    const x_funcref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, funcref_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(17, 31, x_funcref));

    // Null check: CMP X17, #0 ; B.EQ trap. D-293 slice-4b — a null call_ref is
    // null_reference (code 10), NOT oob_table; route to null_ref_fixups (was
    // mis-routed to cind_bounds_fixups → mis-reported trap_kind 2).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(17, 0));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
        try ctx.null_ref_fixups.append(ctx.allocator, fixup_at);
    }

    // Native entry: LDR X16, [X17, #funcentity_funcptr_offset].
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, 17, @intCast(func_mod.funcentity_funcptr_offset)));

    // ADR-0155 stage 2 — spill caller-saved homed locals before the BLR
    // (X16/X17 hold the funcptr pipeline, never a homed local's home reg).
    try spillHomedCallerSaved(ctx);
    // Restore X0 = runtime_ptr (ADR-0017 sub-2d-ii) ; BLR X16.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(16));
    try reloadHomedCallerSaved(ctx);

    try captureCallResult(ctx, callee_sig, memory_class_return, return_buffer_off);
    try emitPostCallTrapCheck(ctx);
}

/// Wasm spec §3.4.7 (call N) — marshal call arguments per AAPCS64
/// §6.4.2. Pop N arg vregs in REVERSE stack order (top = arg N-1)
/// then emit MOV/FMOV from each arg's home register into X1..X7
/// (per ADR-0017 X0 reserved for runtime_ptr) or V0..V7. Args that
/// overflow the int (X1..X7, 7 slots) or fp (V0..V7, 8 slots) pools
/// land in the caller's pre-allocated outgoing-args region at
/// `[SP, #(K*8)]` for K = NSAA index. The
/// callee reads them at `[X29, #(16 + 8*K)]`.
///
/// **No source-clobber risk by construction**: vregs are allocated
/// out of `[X9..X15, X19..X28]` (GPR pool) and `[V16..V30]` (FP
/// pool), neither of which overlaps the arg-passing registers. So
/// a naive sequential MOV per arg is correct without parallel-move
/// analysis. For overflow args, `gprLoadSpilled(stage 0)` /
/// `fpLoadSpilled(stage 0)` lands the value in a staging register
/// that the immediately-following STR consumes before the next
/// arg's stage-0 load reuses it.
// Tail-call shares the AAPCS64 args marshal shape with regular call.
// The args land in X1..X7 / V0..V7 with the same overflow-region byte
// layout; tail-call just teardowns the caller's frame before B-jumping.
// SIBLING-PUB: op_tail_call.zig (per ADR-0112 D3)
pub fn marshalCallArgs(ctx: *EmitCtx, callee_sig: FuncType) Error!void {
    const n_args: u32 = @intCast(callee_sig.params.len);
    if (n_args == 0) return;
    if (ctx.pushed_vregs.items.len < n_args) return Error.AllocationMissing;

    // Pop in reverse stack order: top = arg N-1, deepest = arg 0.
    // Cap bumped 64 → 128 to fit `call.wast`'s 100-arg
    // fixture. Wasm spec has no upper bound on param count, but
    // realistic guests rarely exceed ~64; the extra 512 bytes
    // of stack-buffer per call site is harmless.
    const max_args: u32 = 128;
    var arg_vregs: [max_args]u32 = undefined;
    if (n_args > max_args) {
        dbg.print("codegen", "arm64/op_call: marshal n_args={d} > {d}\n", .{ n_args, max_args });
        return Error.UnsupportedOp;
    }
    var i: u32 = n_args;
    while (i > 0) {
        i -= 1;
        arg_vregs[i] = ctx.pushed_vregs.pop().?;
    }

    var gpr_arg_slot: inst.Xn = 1;
    var fp_arg_slot: inst.Vn = 0;
    // Per-call NSAA byte cursor (caller-side). Mirror of arm64
    // emit.zig prologue's stack-arg byte cursor.
    //
    // Standard AAPCS64: every scalar overflow consumes 8 bytes
    // regardless of width; v128 consumes 16 with 16-byte align.
    //
    // **Apple arm64 (macOS/iOS/watchOS/tvOS)** per Apple's
    // "Writing ARM64 Code for Apple Platforms": stack overflow
    // args use their NATURAL size with natural alignment, so
    // consecutive i32+f32 pack into 4+4=8 bytes (not 8+8).
    const apple_natural_packing: bool = builtin.target.os.tag == .macos or
        builtin.target.os.tag == .ios or
        builtin.target.os.tag == .watchos or
        builtin.target.os.tag == .tvos;
    var stack_byte_off: u32 = 0;
    var k: u32 = 0;
    while (k < n_args) : (k += 1) {
        const src_vreg = arg_vregs[k];
        switch (callee_sig.params[k]) {
            .i32 => {
                const ws = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (gpr_arg_slot >= 8) {
                    const slot_size: u32 = if (apple_natural_packing) 4 else 8;
                    const align_mask: u32 = slot_size - 1;
                    stack_byte_off = (stack_byte_off + align_mask) & ~align_mask;
                    if (stack_byte_off > 16380) return Error.UnsupportedOp;
                    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImmW(ws, 31, @intCast(stack_byte_off)));
                    stack_byte_off += slot_size;
                } else {
                    if (ws != gpr_arg_slot) {
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(gpr_arg_slot, 31, ws));
                    }
                    gpr_arg_slot += 1;
                }
            },
            .i64 => {
                const xs = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (gpr_arg_slot >= 8) {
                    stack_byte_off = (stack_byte_off + 7) & ~@as(u32, 7);
                    if (stack_byte_off > 32760) return Error.UnsupportedOp;
                    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(xs, 31, @intCast(stack_byte_off)));
                    stack_byte_off += 8;
                } else {
                    if (xs != gpr_arg_slot) {
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(gpr_arg_slot, 31, xs));
                    }
                    gpr_arg_slot += 1;
                }
            },
            .f32 => {
                const vs = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (fp_arg_slot >= 8) {
                    const slot_size: u32 = if (apple_natural_packing) 4 else 8;
                    const align_mask: u32 = slot_size - 1;
                    stack_byte_off = (stack_byte_off + align_mask) & ~align_mask;
                    if (stack_byte_off > 16380) return Error.UnsupportedOp;
                    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrSImm(vs, 31, @intCast(stack_byte_off)));
                    stack_byte_off += slot_size;
                } else {
                    if (vs != fp_arg_slot) {
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovSReg(fp_arg_slot, vs));
                    }
                    fp_arg_slot += 1;
                }
            },
            .f64 => {
                const vs = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (fp_arg_slot >= 8) {
                    stack_byte_off = (stack_byte_off + 7) & ~@as(u32, 7);
                    if (stack_byte_off > 32760) return Error.UnsupportedOp;
                    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrDImm(vs, 31, @intCast(stack_byte_off)));
                    stack_byte_off += 8;
                } else {
                    if (vs != fp_arg_slot) {
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovDReg(fp_arg_slot, vs));
                    }
                    fp_arg_slot += 1;
                }
            },
            // Caller-side v128 arg marshal per
            // AAPCS64 §6.4 SIMD calling convention. Mirror of
            // the callee-side param-marshal (V0..V7 are
            // SIMD arg regs; overflow goes to caller's outgoing
            // args region with 16-byte alignment per §6.4.2
            // stage C.4).
            .v128 => {
                const vs = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (fp_arg_slot >= 8) {
                    stack_byte_off = (stack_byte_off + 15) & ~@as(u32, 15);
                    if (stack_byte_off > 65520) return Error.UnsupportedOp;
                    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encStrQImm(vs, 31, @intCast(stack_byte_off)));
                    stack_byte_off += 16;
                } else {
                    if (vs != fp_arg_slot) {
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(fp_arg_slot, vs));
                    }
                    fp_arg_slot += 1;
                }
            },
            // D-093: reftype params share the i64 X-form
            // marshal path (8-byte gpr-class slot per ADR-0061).
            .ref => {
                const xs = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (gpr_arg_slot >= 8) {
                    stack_byte_off = (stack_byte_off + 7) & ~@as(u32, 7);
                    if (stack_byte_off > 32760) return Error.UnsupportedOp;
                    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(xs, 31, @intCast(stack_byte_off)));
                    stack_byte_off += 8;
                } else {
                    if (xs != gpr_arg_slot) {
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(gpr_arg_slot, 31, xs));
                    }
                    gpr_arg_slot += 1;
                }
            },
        }
    }
}

/// Capture a call's return value(s) into next vreg(s), dispatching
/// on each callee result type. Per AAPCS64 §6.5: results map to
/// X0..X7 (integer class) and V0..V7 (FP / SIMD class) in order;
/// class counters are independent. Void callees push nothing.
/// Multi-result support (D-093) enables Wasm 2.0 multi-value
/// function returns (e.g. `add64_u_with_carry → (i64, i32)`).
/// Stack-overflow (> 8 results per class) surfaces as UnsupportedOp.
///
/// **No parallel-move hazard**: arm64's `allocatable_gprs` =
/// X9..X13 + X20..X22 and `allocatable_fp_vregs` = V16..V30; the
/// X0..X7 / V0..V7 source regs are NOT in the allocatable pool,
/// so capturing in order (result[0] from X0, result[1] from X1,
/// …) never overwrites a still-unread source.
fn captureCallResult(ctx: *EmitCtx, callee_sig: FuncType, memory_class: bool, buffer_off: u32) Error!void {
    if (callee_sig.results.len == 0) return;

    // ADR-0017 2026-05-18 amend / ADR-0069:
    // MEMORY-class returns — callee wrote each result to
    // `[X8, #(i*8)]` where X8 was our LEA into the outgoing-args
    // return buffer at `[SP, #buffer_off + i*8]`. Read each slot
    // back into the next result vreg. X14 (`abi.spill_stage_gprs[0]`)
    // serves as the load-into-then-store-to-spill stage when the
    // result vreg is spilled; in-pool result vregs receive the LDR
    // directly. v128 results deferred (no spec fixture in the
    // 3-int-result / large-sig cohort).
    if (memory_class) {
        var byte_off: u32 = 0;
        for (callee_sig.results) |result_type| {
            const result = ctx.next_vreg.*;
            ctx.next_vreg.* += 1;
            if (result >= ctx.alloc.slots.len) return Error.AllocationMissing;
            const abs_off: u32 = buffer_off + byte_off;
            switch (result_type) {
                .i32 => switch (ctx.alloc.slot(result, .gpr)) {
                    .reg => |id| {
                        const wd = abi.slotToReg(id) orelse return Error.SlotOverflow;
                        try gpr.frameLdrGpr(ctx.allocator, ctx.buf, wd, abs_off, true);
                    },
                    .spill => |off| {
                        const dst_off: u32 = ctx.spill_base_off + off;
                        try gpr.frameLdrGpr(ctx.allocator, ctx.buf, abi.spill_stage_gprs[0], abs_off, true);
                        try gpr.frameStrGpr(ctx.allocator, ctx.buf, abi.spill_stage_gprs[0], dst_off, true, abi.spill_stage_gprs[1]);
                    },
                },
                .i64, .ref => switch (ctx.alloc.slot(result, .gpr)) {
                    .reg => |id| {
                        const xd = abi.slotToReg(id) orelse return Error.SlotOverflow;
                        try gpr.frameLdrGpr(ctx.allocator, ctx.buf, xd, abs_off, false);
                    },
                    .spill => |off| {
                        const dst_off: u32 = ctx.spill_base_off + off;
                        try gpr.frameLdrGpr(ctx.allocator, ctx.buf, abi.spill_stage_gprs[0], abs_off, false);
                        try gpr.frameStrGpr(ctx.allocator, ctx.buf, abi.spill_stage_gprs[0], dst_off, false, abi.spill_stage_gprs[1]);
                    },
                },
                .f32 => switch (ctx.alloc.slot(result, .fpr)) {
                    .reg => |id| {
                        const vd = abi.fpSlotToReg(id) orelse return Error.SlotOverflow;
                        try gpr.frameLdrFp(ctx.allocator, ctx.buf, vd, abs_off, .s, abi.spill_stage_gprs[0]);
                    },
                    .spill => |off| {
                        const dst_off: u32 = ctx.spill_base_off + off;
                        // Stage via V29 (fp_spill_stage_vregs[0]); GPR address scratch = X14.
                        try gpr.frameLdrFp(ctx.allocator, ctx.buf, abi.fp_spill_stage_vregs[0], abs_off, .s, abi.spill_stage_gprs[0]);
                        try gpr.frameStrFp(ctx.allocator, ctx.buf, abi.fp_spill_stage_vregs[0], dst_off, .s, abi.spill_stage_gprs[0]);
                    },
                },
                .f64 => switch (ctx.alloc.slot(result, .fpr)) {
                    .reg => |id| {
                        const vd = abi.fpSlotToReg(id) orelse return Error.SlotOverflow;
                        try gpr.frameLdrFp(ctx.allocator, ctx.buf, vd, abs_off, .d, abi.spill_stage_gprs[0]);
                    },
                    .spill => |off| {
                        const dst_off: u32 = ctx.spill_base_off + off;
                        try gpr.frameLdrFp(ctx.allocator, ctx.buf, abi.fp_spill_stage_vregs[0], abs_off, .d, abi.spill_stage_gprs[0]);
                        try gpr.frameStrFp(ctx.allocator, ctx.buf, abi.fp_spill_stage_vregs[0], dst_off, .d, abi.spill_stage_gprs[0]);
                    },
                },
                .v128 => return Error.UnsupportedOp,
            }
            byte_off += 8;
            try ctx.pushed_vregs.append(ctx.allocator, result);
        }
        return;
    }

    // Pre-check class capacities.
    {
        var n_gpr: u8 = 0;
        var n_fp: u8 = 0;
        for (callee_sig.results) |rt| switch (rt) {
            .i32, .i64, .ref => n_gpr += 1,
            .f32, .f64, .v128 => n_fp += 1,
        };
        if (n_gpr > 8 or n_fp > 8) return Error.UnsupportedOp;
    }

    var n_gpr_used: u8 = 0;
    var n_fp_used: u8 = 0;
    for (callee_sig.results) |result_type| {
        const result = ctx.next_vreg.*;
        ctx.next_vreg.* += 1;
        if (result >= ctx.alloc.slots.len) return Error.AllocationMissing;

        const src_reg: inst.Xn = switch (result_type) {
            .i32, .i64, .ref => blk: {
                const id: inst.Xn = @intCast(n_gpr_used);
                n_gpr_used += 1;
                break :blk id;
            },
            .f32, .f64, .v128 => blk: {
                const id: inst.Xn = @intCast(n_fp_used);
                n_fp_used += 1;
                break :blk id;
            },
        };

        switch (result_type) {
            .i32 => switch (ctx.alloc.slot(result, .gpr)) {
                .reg => |id| {
                    const wd = abi.slotToReg(id) orelse {
                        dbg.print("codegen", "arm64/op_call: captureCallResult.i32 SlotOverflow func[{d}] result_vreg={d} slot_id={d}\n", .{ ctx.func.func_idx, result, id });
                        return Error.SlotOverflow;
                    };
                    if (wd != src_reg) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(wd, 31, src_reg));
                },
                .spill => |off| {
                    const abs_off: u32 = ctx.spill_base_off + off;
                    try gpr.frameStrGpr(ctx.allocator, ctx.buf, src_reg, abs_off, true, abi.spill_stage_gprs[0]);
                },
            },
            .i64, .ref => switch (ctx.alloc.slot(result, .gpr)) {
                .reg => |id| {
                    const xd = abi.slotToReg(id) orelse {
                        dbg.print("codegen", "arm64/op_call: captureCallResult.i64 SlotOverflow func[{d}] result_vreg={d} slot_id={d}\n", .{ ctx.func.func_idx, result, id });
                        return Error.SlotOverflow;
                    };
                    if (xd != src_reg) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(xd, 31, src_reg));
                },
                .spill => |off| {
                    const abs_off: u32 = ctx.spill_base_off + off;
                    try gpr.frameStrGpr(ctx.allocator, ctx.buf, src_reg, abs_off, false, abi.spill_stage_gprs[0]);
                },
            },
            .f32 => switch (ctx.alloc.slot(result, .fpr)) {
                .reg => |id| {
                    const vd = abi.fpSlotToReg(id) orelse {
                        dbg.print("codegen", "arm64/op_call: captureCallResult.f32 SlotOverflow func[{d}] result_vreg={d} slot_id={d}\n", .{ ctx.func.func_idx, result, id });
                        return Error.SlotOverflow;
                    };
                    if (vd != src_reg) try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovSReg(vd, src_reg));
                },
                .spill => |off| {
                    const abs_off: u32 = ctx.spill_base_off + off;
                    try gpr.frameStrFp(ctx.allocator, ctx.buf, src_reg, abs_off, .s, abi.spill_stage_gprs[0]);
                },
            },
            .f64 => switch (ctx.alloc.slot(result, .fpr)) {
                .reg => |id| {
                    const vd = abi.fpSlotToReg(id) orelse {
                        dbg.print("codegen", "arm64/op_call: captureCallResult.f64 SlotOverflow func[{d}] result_vreg={d} slot_id={d}\n", .{ ctx.func.func_idx, result, id });
                        return Error.SlotOverflow;
                    };
                    if (vd != src_reg) try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovDReg(vd, src_reg));
                },
                .spill => |off| {
                    const abs_off: u32 = ctx.spill_base_off + off;
                    try gpr.frameStrFp(ctx.allocator, ctx.buf, src_reg, abs_off, .d, abi.spill_stage_gprs[0]);
                },
            },
            // v128 capture via MOV V_dst.16B, V_src.16B (alias of
            // ORR), preserving all 128 bits. Spilled paths use
            // STR Q (16-byte stride).
            .v128 => switch (ctx.alloc.slot(result, .fpr)) {
                .reg => |id| {
                    const vd = abi.fpSlotToReg(id) orelse {
                        dbg.print("codegen", "arm64/op_call: captureCallResult.v128 SlotOverflow func[{d}] result_vreg={d} slot_id={d}\n", .{ ctx.func.func_idx, result, id });
                        return Error.SlotOverflow;
                    };
                    if (vd != src_reg) try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(vd, src_reg));
                },
                .spill => |off| {
                    const abs_off: u32 = ctx.spill_base_off + off;
                    try gpr.frameStrFp(ctx.allocator, ctx.buf, src_reg, abs_off, .q, abi.spill_stage_gprs[0]);
                },
            },
        }
        try ctx.pushed_vregs.append(ctx.allocator, result);
    }
}
