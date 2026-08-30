//! x86_64 tail-call emit helpers (ADR-0112 D2 + D4).
//!
//! Mirror of `arm64/op_tail_call.zig`. Per ADR-0112 D4 the
//! emit sequence is:
//!
//!   (1) marshal args → RDI/RSI/RDX/RCX/R8/R9 + XMM0..7
//!   (2) load callee_rt → RDI
//!   (3) load callee_entry → R11
//!   (4) frame_teardown.emit(…)
//!   (5) JMP R11
//!
//! This file currently lands step (5) — `emitTailJump` — as the
//! observable foundation. Subsequent chunks layer on the rest.
//!
//! INVARIANT (ADR-0112 D7): the segment from frame_teardown
//! start through JMP R11 contains NO allocator calls, NO
//! host-call dispatches, NO signal-check branches.
//!
//! Spec: Wasm Core 3.0 §3.3.8.18-20 (tail-call proposal).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");

const inst = @import("inst.zig");
const abi = @import("abi.zig");
const types = @import("types.zig");
const ctx_mod = @import("ctx.zig");
const op_call = @import("op_call.zig");
// D-185 sibling fix (arm64 root cause): the shared facade is
// host-dispatched. x86_64 emit always wants x86_64 bytes regardless
// of host, so import the sibling directly.
const frame_teardown = @import("frame_teardown.zig");
const gpr = @import("gpr.zig");
const canonical_type = @import("../shared/canonical_type.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const zir = @import("../../../ir/zir.zig");
const func_mod = @import("../../../runtime/instance/func.zig");

/// R11 — System V AMD64 caller-saved scratch (no fixed role in
/// the ABI) per System V §3.2.3. ADR-0066 § (bridge thunk)
/// already uses RAX as the callee-target-load register; tail-
/// call uses R11 to keep RAX free for the callee's prologue
/// (which expects RAX clobber by `marshalReturnRegs` on RET).
/// R11 also matches the convention in
/// `src/engine/codegen/x86_64/op_call.zig`'s indirect-call path
/// where R11 holds the resolved funcptr through the CALL.
pub const tail_target_gpr: inst.Gpr = .r11;

/// Emit step (2) of the ADR-0112 D4 tail-call sequence for
/// the SAME-MODULE case: restore RDI = runtime_ptr so the
/// callee's prologue (which does `MOV R15, RDI` per ADR-0026
/// Cc-pivot) sees the correct runtime pointer. For
/// same-module tail-call, caller_rt == callee_rt and R15 is
/// already correct, so we simply `MOV RDI, R15`.
///
/// Cross-module tail-call (ADR-0112 D4) loads callee_rt from
/// the caller's literal pool instead;
/// that path lives in `cross_module_tail_call.zig`.
pub fn emitLoadCalleeRtSameModule(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
) !void {
    // MOV RDI, R15 — 64-bit reg-to-reg move.
    const enc = inst.encMovRR(.q, .rdi, abi.runtime_ptr_save_gpr);
    try buf.appendSlice(allocator, enc.slice());
}

/// Emit step (5) of the ADR-0112 D4 tail-call sequence: the
/// `JMP R11` unconditional indirect branch to the callee entry.
/// Caller MUST have already loaded the callee target into R11
/// and emitted `frame_teardown.emit(...)` immediately above this
/// (the safepoint-free invariant per ADR-0112 D7).
pub fn emitTailJump(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    target: inst.Gpr,
) !void {
    const enc = inst.encJmpReg(target);
    try buf.appendSlice(allocator, enc.slice());
}

/// Same-module direct tail-call alternative to the JMP R11
/// path: emit `JMP rel32` placeholder (0xE9 + 4-byte disp32=0)
/// and register a `CallFixup{is_tail=true}` so the post-emit
/// linker patches disp32 to a PC-relative offset targeting the
/// callee body. Refinement of ADR-0112 D4 (not deviation): D4
/// prescribes JMP R11 for cross-module where the callee target
/// isn't reachable by rel32; for same-module direct the linker
/// has the offset and a single JMP rel32 (5 bytes) is shorter
/// than the load-then-JMP-R11 sequence.
///
/// `patchRel32` on the linker side preserves the opcode byte
/// (0xE9) and only writes disp32, so the JMP-vs-CALL choice is
/// made here at emit-time (the arm64 sibling does it at link-
/// time because `encBL` rewrites the whole word).
///
/// Caller MUST have already:
///   (1) marshalled args into RDI/RSI/RDX/RCX/R8/R9 + XMM0..7,
///   (2) emitted `emitLoadCalleeRtSameModule` (RDI ← R15),
///   (3) emitted `frame_teardown.emit(.uses_runtime_ptr)`
///       (caller's R15 + RBP popped, frame gone).
pub fn emitDirectTailJump(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    call_fixups: *std.ArrayList(types.CallFixup),
    target_func_idx: u32,
) !void {
    const fixup_at: u32 = @intCast(buf.items.len);
    const enc = inst.encJmpRel32(0);
    try buf.appendSlice(allocator, enc.slice());
    try call_fixups.append(allocator, types.CallFixup{
        .byte_offset = fixup_at,
        .target_func_idx = target_func_idx,
        .is_tail = true,
    });
}

/// Wasm spec 3.0 §3.3.8.18 (tail-call proposal) — `return_call N`
/// on x86_64 SysV. Mirror of `arm64/op_tail_call.emitDirectReturnCall`.
/// Orchestrates the ADR-0112 D4 sequence for the same-module
/// direct case:
///   (1) marshal args via `op_call.marshalCallArgs`,
///   (2) restore RDI = R15 via `emitLoadCalleeRtSameModule`,
///   (3) `frame_teardown.emit({frame_bytes, uses_runtime_ptr})`,
///   (4) `emitDirectTailJump(target_func_idx)`.
///
/// Step (3) of D4 (load callee_entry → R11) is elided here —
/// the linker materialises the callee body offset directly into
/// the JMP rel32 disp32 (saving the load + indirect-jump steps).
/// Cross-module / indirect / ref tail-calls (which can't reach
/// via rel32) take the JMP R11 path through follow-on chunks.
///
/// Import-as-callee (`ins.payload < num_imports`) routes to
/// `emitCrossModuleReturnCall` — the cross-module call-and-return
/// lowering through the ADR-0066 bridge thunk (ADR-0112 Amendment
/// 2026-05-30). x86_64's per-frame R15 save would actually permit a
/// frame-consuming JMP here, but both arches stay on call-and-return
/// so cross-module tail-recursion depth doesn't diverge by host.
pub fn emitDirectReturnCall(
    ctx: *ctx_mod.EmitCtx,
    ins: *const zir.ZirInstr,
) ctx_mod.Error!void {
    if (ins.payload >= ctx.func_sigs.len) return ctx_mod.Error.AllocationMissing;
    if (ins.payload < ctx.num_imports) return emitCrossModuleReturnCall(ctx, ins);
    const callee_sig: zir.FuncType = ctx.func_sigs[ins.payload];

    try op_call.marshalCallArgs(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.spill_base_off,
        callee_sig,
    );
    try emitLoadCalleeRtSameModule(ctx.allocator, ctx.buf);
    try frame_teardown.emit(ctx.allocator, ctx.buf, .{
        .frame_bytes = ctx.frame_bytes,
        .uses_runtime_ptr = ctx.uses_runtime_ptr,
    });
    try emitDirectTailJump(ctx.allocator, ctx.buf, ctx.call_fixups, @intCast(ins.payload));
}

/// Cross-module `return_call $import` (ADR-0112 Amendment 2026-05-30,
/// D-206 step 2). Lowered as **call-and-return** through the ADR-0066
/// bridge thunk (planted in `host_dispatch_base[idx]`, which
/// PUSH/POP-preserves the caller's R15 across its CALL) followed by
/// the normal frame teardown + RET — i.e. the emit shape of
/// `call $import` immediately followed by the function epilogue:
///
///   (1) marshal args → per-CC arg regs
///   (2) emitImportDispatch — CALL the resolved thunk; the callee's
///       result lands in RAX/XMM0 and the thunk restores R15
///   (3) frame_teardown (ADD RSP + POP R15? + POP RBP) + RET
///
/// On x86_64 the per-frame R15 save (`uses_runtime_ptr`) makes a
/// frame-consuming `JMP R11` cohort-safe too, but both arches stay
/// on call-and-return so cross-module tail-recursion depth doesn't
/// diverge observably by host (the arm64 prologue MOV-installs its
/// cohort and cannot do frame-consuming cross-module tail-call until
/// D-210). No `captureCallResult` runs: the result already sits in
/// the return register the epilogue's RET hands back. ≤ 2 results
/// only (MEMORY-class return buffer is a D-210 follow-on).
fn emitCrossModuleReturnCall(
    ctx: *ctx_mod.EmitCtx,
    ins: *const zir.ZirInstr,
) ctx_mod.Error!void {
    const callee_sig: zir.FuncType = ctx.func_sigs[ins.payload];
    if (callee_sig.results.len > 2) return ctx_mod.Error.UnsupportedOp; // D-210: MEMORY-class return buffer
    try op_call.marshalCallArgs(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.spill_base_off,
        callee_sig,
    );
    try op_call.emitImportDispatch(ctx.allocator, ctx.buf, ctx.outgoing_max_bytes, @intCast(ins.payload));
    try frame_teardown.emit(ctx.allocator, ctx.buf, .{
        .frame_bytes = ctx.frame_bytes,
        .uses_runtime_ptr = ctx.uses_runtime_ptr,
    });
    try ctx.buf.appendSlice(ctx.allocator, inst.encRet().slice());
}

/// Wasm spec 3.0 §3.3.8.19 (tail-call proposal) —
/// `return_call_indirect type_idx tableidx` on x86_64 SysV.
/// Mirror of `arm64/op_tail_call.emitIndirectReturnCall`. Uses the
/// JMP R11 path (D4 prescribed) since the callee target comes from
/// a runtime table lookup, not the linker.
///
/// Tables: `table_idx == 0` uses the scalar JitRuntime fields;
/// any other table loads size + bases from tables_ptr +
/// tables_jit_ci_ptr at the call site (D-210). Restriction:
///   - `callee_sig.results.len <= 2`.
///
/// Sequence (single-table fast path):
///   (1) pop idx vreg, marshal args,
///   (2) load idx_r,
///   (3) bounds: MOV EAX,[R15+table_size_off] ; CMP idx_r,EAX ;
///       JAE rel32 → bounds_fixups,
///   (4) sig: MOV RAX,[R15+typeidx_base_off] ; MOV EAX,[RAX+idx_r*4] ;
///       CMP EAX,canonical ; JNE rel32 → bounds_fixups,
///   (5) funcptr: MOV RAX,[R15+funcptr_base_off] ;
///       MOV R11,[RAX+idx_r*8],
///   (6) null-funcptr: TEST R11,R11 ; JE rel32 → cind_sig_fixups
///       (D-586; reached when a host cleared the mirror via
///       `tableSetRef`, which leaves the typeidx valid so the
///       D-294 sentinel does not fire),
///   (7) MOV RDI, R15 (emitLoadCalleeRtSameModule),
///   (8) frame_teardown.emit (ADD RSP + POP R15? + POP RBP, no RET),
///   (9) JMP R11 (emitTailJump).
///
/// Why this may JMP to an import while the direct cross-module path
/// refuses to: see the arm64 mirror's note. A cross-module wasm
/// import holds the ADR-0066 thunk, which PUSH/POPs R15 around its
/// CALL and RETs; a WASI import, an embedder host func or the
/// `hostDispatchTrap` fallback holds an ordinary `callconv(.c)`
/// function, safe because SysV §3.2.1 makes R15 callee-saved. Either
/// way a same-module grand-caller sees its own pinned runtime
/// pointer, but the second case is the one the fixtures pin.
///
/// There is no `emitPostCallTrapCheck` here and there cannot be —
/// control never returns. A tail-called import that raises
/// `trap_flag` (`proc_exit`, or `hostDispatchTrap` for an unresolved
/// import) returns past this frame to the grand-caller, whose own
/// post-call check raises it; at the entry frame the runner's
/// trap-flag read does. Every intermediate frame is safe because a
/// tail-called frame executes nothing after the jump.
///
/// Note (x86_64 fixup-list shape, D-293): cind bounds route to
/// `oobtable_fixups` (oob_table, code 2) and cind sig to
/// `cind_sig_fixups` (indirect_call_mismatch, code 3), each demuxed to
/// a dedicated per-kind trap stub at function tail. Mirrors arm64's
/// `cind_bounds_fixups` + `cind_sig_fixups` split (both now per-kind).
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

    try op_call.marshalCallArgs(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.spill_base_off,
        callee_sig,
    );

    // Load idx AFTER marshalCallArgs (D-097 d-18 mirror — marshalling
    // stages spilled args through R10/scratch; loading idx before
    // would risk clobber).
    // D-475: an i64 table pops a 64-bit index — the bounds CMPs below
    // widen to .q per the table's idx_type.
    const ci_idx64 = ctx.func.tableIdxType(table_idx) == .i64;
    const idx_r = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_vreg, 0);

    const expected_typeidx: u32 = canonical_type.canonicalTypeidx(ctx.module_types, @intCast(ins.payload));

    if (table_idx == 0) {
        // Table-0 fast path: scalar JitRuntime fields (table_size_off /
        // typeidx_base_off / funcptr_base_off) back table 0.
        // Bounds: MOV RAX, [R15+table_size_off] ; CMP idx_r, RAX/EAX ; JAE trap.
        // 64-bit load (D-475: table_size is u64); the CMP is .q for an
        // i64 table and stays .d on the i32 fast path.
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.table_size_off).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encCmpRR(if (ci_idx64) .q else .d, idx_r, .rax).slice());
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.ae, 0).slice());
            try ctx.oobtable_fixups.append(ctx.allocator, fixup_at); // oob_table (code 2, #357)
        }

        // Sig: MOV RAX, [R15+typeidx_base_off] ; MOV EAX, [RAX + idx_r*4] ;
        //      CMP EAX, canonical ; JNE trap.
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.typeidx_base_off).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR32FromBaseIdxLsl2(.rax, .rax, idx_r).slice());
        // D-294: null slot's typeidx is the maxInt(u32) sentinel — check before sig.
        try ctx.buf.appendSlice(ctx.allocator, inst.encCmpRImm32(.rax, 0xFFFFFFFF).slice());
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
            try ctx.uninit_elem_fixups.append(ctx.allocator, fixup_at); // D-294 uninitialized_elem (code 13)
        }
        try ctx.buf.appendSlice(ctx.allocator, inst.encCmpRImm32(.rax, expected_typeidx).slice());
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.ne, 0).slice());
            try ctx.cind_sig_fixups.append(ctx.allocator, fixup_at); // D-293 slice-2 indirect_call_mismatch (code 3)
        }

        // Funcptr: MOV RAX, [R15+funcptr_base_off] ; MOV R11, [RAX + idx_r*8].
        // Loading into R11 (tail target) directly — RAX is the LDR-base
        // scratch; R11 is the JMP target per `tail_target_gpr`.
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.funcptr_base_off).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromBaseIdxLsl3(tail_target_gpr, .rax, idx_r).slice());
        // D-586 — zero funcptr (host-cleared slot, typeidx valid): trap, do not JMP.
        try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, tail_target_gpr, tail_target_gpr).slice());
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
            try ctx.cind_sig_fixups.append(ctx.allocator, fixup_at);
        }
    } else {
        // Multi-table slow path (D-210): load per-table size + bases from
        // JitRuntime.tables_ptr[table_idx] + tables_jit_ci_ptr[table_idx],
        // mirroring op_call.emitCallIndirect's else-branch. RAX is the only
        // scratch, so each base load reloads the array pointer; the funcptr
        // lands in tail_target_gpr (R11) for the JMP.
        if (jit_abi.table_jit_ci_size != 16) @compileError("multi-table tail-call assumes TableJitCallInfo stride 16");
        const tbl_slice_disp: i32 = @intCast((table_idx * jit_abi.table_slice_size) + jit_abi.tableslice_len_off);
        const ci_funcptr_disp: i32 = @intCast(table_idx * 16);
        const ci_typeidx_disp: i32 = @intCast((table_idx * 16) + 8);

        // Bounds: MOV RAX, [R15+tables_ptr_off] ; MOV RAX, [RAX+tbl_slice_disp] (len, u64 D-475)
        //         CMP idx_r, RAX/EAX ; JAE trap (.q for an i64 table).
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, .rax, tbl_slice_disp).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encCmpRR(if (ci_idx64) .q else .d, idx_r, .rax).slice());
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.ae, 0).slice());
            try ctx.oobtable_fixups.append(ctx.allocator, fixup_at); // oob_table (code 2, #357)
        }

        // Sig: MOV RAX, [R15+tables_jit_ci_ptr_off] ; MOV RAX, [RAX+ci_typeidx_disp]
        //      MOV EAX, [RAX+idx_r*4] ; CMP EAX, canonical ; JNE trap.
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, .rax, ci_typeidx_disp).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR32FromBaseIdxLsl2(.rax, .rax, idx_r).slice());
        // D-294: null slot's typeidx is the maxInt(u32) sentinel — check before sig.
        try ctx.buf.appendSlice(ctx.allocator, inst.encCmpRImm32(.rax, 0xFFFFFFFF).slice());
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
            try ctx.uninit_elem_fixups.append(ctx.allocator, fixup_at); // D-294 uninitialized_elem (code 13)
        }
        try ctx.buf.appendSlice(ctx.allocator, inst.encCmpRImm32(.rax, expected_typeidx).slice());
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.ne, 0).slice());
            try ctx.cind_sig_fixups.append(ctx.allocator, fixup_at); // D-293 slice-2 indirect_call_mismatch (code 3)
        }

        // Funcptr: MOV RAX, [R15+tables_jit_ci_ptr_off] ; MOV RAX, [RAX+ci_funcptr_disp]
        //          MOV R11, [RAX+idx_r*8].
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(.rax, .rax, ci_funcptr_disp).slice());
        try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromBaseIdxLsl3(tail_target_gpr, .rax, idx_r).slice());
        // D-586 — zero funcptr (host-cleared slot, typeidx valid): trap, do not JMP.
        try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, tail_target_gpr, tail_target_gpr).slice());
        {
            const fixup_at: u32 = @intCast(ctx.buf.items.len);
            try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
            try ctx.cind_sig_fixups.append(ctx.allocator, fixup_at);
        }
    }

    try emitLoadCalleeRtSameModule(ctx.allocator, ctx.buf);
    try frame_teardown.emit(ctx.allocator, ctx.buf, .{
        .frame_bytes = ctx.frame_bytes,
        .uses_runtime_ptr = ctx.uses_runtime_ptr,
    });
    try emitTailJump(ctx.allocator, ctx.buf, tail_target_gpr);
}

/// Wasm spec 3.0 §3.3.8.20 (`return_call_ref $sig`) — tail-call
/// through a typed funcref. x86_64 mirror of `arm64/op_tail_call.zig:
/// emitReturnCallRef`: `op_call.emitCallRef`'s funcref front-half
/// (pop *FuncEntity, OR-null-check, MOV R11 from funcentity_funcptr_
/// offset) + this file's tail (frame_teardown + JMP R11) instead of
/// CALL + capture. No runtime sig check (validator guarantees the
/// funcref's type ⊑ `$sig`). Terminator + safepoint-free (ADR-0112 D7).
pub fn emitReturnCallRef(
    ctx: *ctx_mod.EmitCtx,
    ins: *const zir.ZirInstr,
) ctx_mod.Error!void {
    if (ins.payload >= ctx.module_types.len) return ctx_mod.Error.AllocationMissing;
    const callee_sig: zir.FuncType = ctx.module_types[ins.payload];
    if (callee_sig.results.len > 2) return ctx_mod.Error.UnsupportedOp;

    if (ctx.pushed_vregs.items.len < 1) return ctx_mod.Error.AllocationMissing;
    const funcref_vreg = ctx.pushed_vregs.pop().?;

    try op_call.marshalCallArgs(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.spill_base_off,
        callee_sig,
    );

    // Funcref ptr → reg (AFTER marshalCallArgs, D-097 d-18 mirror).
    const funcref_r = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, funcref_vreg, 0);

    // Null check: OR funcref_r, funcref_r (ZF iff null) ; JZ → null_reference
    // stub (code 10), the kind `call_ref` reports for the same null.
    try ctx.buf.appendSlice(ctx.allocator, inst.encOrRR(.q, funcref_r, funcref_r).slice());
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
        try ctx.null_ref_fixups.append(ctx.allocator, fixup_at);
    }

    // Native entry: MOV R11, [funcref_r + funcentity_funcptr_offset]
    // (R11 = tail_target_gpr — matches the JMP R11 below).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(tail_target_gpr, funcref_r, @intCast(func_mod.funcentity_funcptr_offset)).slice());

    try emitLoadCalleeRtSameModule(ctx.allocator, ctx.buf);
    try frame_teardown.emit(ctx.allocator, ctx.buf, .{
        .frame_bytes = ctx.frame_bytes,
        .uses_runtime_ptr = ctx.uses_runtime_ptr,
    });
    try emitTailJump(ctx.allocator, ctx.buf, tail_target_gpr);
}

// ---------------------------------------------------------------------
// Unit tests — byte-level snapshots for the JMP r encoder. Mac-host
// tests verify the encoding directly via the x86_64 encoders.
// ---------------------------------------------------------------------

const testing = std.testing;

test "op_tail_call x86_64: emitTailJump R11 → 41 FF E3 (REX.B + JMP r/m64 /4)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitTailJump(testing.allocator, &buf, tail_target_gpr);
    try testing.expectEqual(@as(usize, 3), buf.items.len);
    // JMP R11 = 41 FF E3
    //   41 = REX.B (R11 high bit)
    //   FF = FF /4 opcode for JMP r/m64
    //   E3 = ModR/M: mod=11, reg=4 (/4 = JMP), rm=3 (R11 low 3 bits)
    try testing.expectEqual(@as(u8, 0x41), buf.items[0]);
    try testing.expectEqual(@as(u8, 0xFF), buf.items[1]);
    try testing.expectEqual(@as(u8, 0xE3), buf.items[2]);
}

test "op_tail_call x86_64: emitTailJump RAX → FF E0 (no REX, ADR-0066 bridge thunk shape)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitTailJump(testing.allocator, &buf, .rax);
    try testing.expectEqual(@as(usize, 2), buf.items.len);
    try testing.expectEqual(@as(u8, 0xFF), buf.items[0]);
    try testing.expectEqual(@as(u8, 0xE0), buf.items[1]);
}

test "op_tail_call x86_64: tail_target_gpr is R11 (System V scratch, not RAX)" {
    try testing.expectEqual(inst.Gpr.r11, tail_target_gpr);
}

test "op_tail_call x86_64: emitLoadCalleeRtSameModule emits MOV RDI, R15 (4C 89 FF)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitLoadCalleeRtSameModule(testing.allocator, &buf);
    try testing.expectEqual(@as(usize, 3), buf.items.len);
    // MOV RDI, R15 → 4C 89 FF
    //   4C = REX.W + REX.R (R15 is reg-side via the MOV r/m, r form)
    //   89 = MOV r/m64, r64
    //   FF = ModR/M: mod=11, reg=7 (R15 low 3), rm=7 (RDI)
    try testing.expectEqual(@as(u8, 0x4C), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x89), buf.items[1]);
    try testing.expectEqual(@as(u8, 0xFF), buf.items[2]);
}

test "op_tail_call x86_64: emitLoadCalleeRtSameModule uses abi.runtime_ptr_save_gpr (R15) as source" {
    try testing.expectEqual(inst.Gpr.r15, abi.runtime_ptr_save_gpr);
}

test "op_tail_call x86_64: emitDirectTailJump emits 0xE9 + 4-byte disp32=0 + records CallFixup{is_tail=true}" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var fixups: std.ArrayList(types.CallFixup) = .empty;
    defer fixups.deinit(testing.allocator);

    // Pre-pad so byte_offset is non-zero (regression value).
    try buf.appendSlice(testing.allocator, &.{ 0x90, 0x90 }); // 2 NOPs

    try emitDirectTailJump(testing.allocator, &buf, &fixups, 11);

    // 2 NOPs + 5-byte JMP rel32 placeholder.
    try testing.expectEqual(@as(usize, 7), buf.items.len);
    try testing.expectEqual(@as(u8, 0xE9), buf.items[2]); // JMP rel32 opcode
    try testing.expectEqual(@as(u8, 0x00), buf.items[3]);
    try testing.expectEqual(@as(u8, 0x00), buf.items[4]);
    try testing.expectEqual(@as(u8, 0x00), buf.items[5]);
    try testing.expectEqual(@as(u8, 0x00), buf.items[6]);

    try testing.expectEqual(@as(usize, 1), fixups.items.len);
    try testing.expectEqual(@as(u32, 2), fixups.items[0].byte_offset);
    try testing.expectEqual(@as(u32, 11), fixups.items[0].target_func_idx);
    try testing.expectEqual(true, fixups.items[0].is_tail);
}

test "op_tail_call x86_64: emitDirectTailJump byte_offset == JMP opcode position (not pre-pad start)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var fixups: std.ArrayList(types.CallFixup) = .empty;
    defer fixups.deinit(testing.allocator);

    try buf.appendSlice(testing.allocator, &.{ 0x90, 0x90, 0x90, 0x90 }); // 4 NOPs
    try emitDirectTailJump(testing.allocator, &buf, &fixups, 0);
    try testing.expectEqual(@as(u32, 4), fixups.items[0].byte_offset);
}
