//! x86_64 emit pass — call / call_indirect family (D-030 chunk-g).
// FILE-SIZE-EXEMPT: per-call-class emit catalog (call / call_indirect / call_ref + shared marshalCallArgs / captureCallResult / overflow-buffer helpers) — single concern, no valid extraction (per ADR-0099)
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314 + the ARM64
//! ADR-0021 sub-b mirror shape (`arm64/op_call.zig`). Behaviour
//! change zero — handler bodies are unchanged from their pre-split
//! shape; only their home file moves.
//!
//! Handlers in this module:
//!   - `emitCall`           — direct `call N` (marshal args, restore
//!     entry_arg0 = runtime_ptr from R15, CALL placeholder + linker
//!     fixup, capture return).
//!   - `emitCallIndirect`   — `call_indirect type_idx` (bounds check
//!     against table_size, sig check against typeidx[idx], load
//!     funcptr[idx], CALL through RAX).
//!   - `emitShadowAlloc` / `emitShadowFree` — Win64 32-byte shadow
//!     space wrapper (SysV no-op).
//!   - `marshalCallArgs`    — pop N arg vregs, MOV into the per-CC
//!     arg_gprs slots (RDI/RCX is reserved for runtime_ptr).
//!   - `captureCallResult`  — i32 return → next vreg via EAX.
//!
//! Module-private wrappers (emitShadowAlloc / Free + marshalCallArgs
//! / captureCallResult) are `pub fn` so the call_indirect / call
//! handlers above can share them; nothing in `compile()` calls
//! them directly.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const ctx_mod = @import("ctx.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const gpr = @import("gpr.zig");
const rbp_disp = @import("rbp_disp.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const types = @import("types.zig");
const op_control = @import("op_control.zig");
const canonical_type = @import("../shared/canonical_type.zig");
const func_mod = @import("../../../runtime/instance/func.zig");

/// Helper: per-call v128-scratch base for Win64.
/// Returns the [RSP + N] offset where the first 16-byte v128
/// scratch slot lives in the caller's outgoing-args region.
/// Must agree with `emit.zig:computeOutgoingMaxBytes` Win64
/// branch. Mirror of cranelift's prologue-time
/// `ABIArg::ImplicitPtrArg` offset finalisation
/// (cranelift `cranelift/codegen/src/isa/x64/abi.rs:383-395`).
fn win64V128ScratchBase(callee_sig: zir.FuncType) u32 {
    var n_int: u32 = 0;
    var n_fp: u32 = 0;
    var n_v128: u32 = 0;
    for (callee_sig.params) |p| switch (p) {
        .i32, .i64 => n_int += 1,
        .f32, .f64 => n_fp += 1,
        .v128 => n_v128 += 1,
        .ref => {},
    };
    const n_total = n_int + n_v128 + n_fp;
    const n_overflow: u32 = if (n_total > 3) n_total - 3 else 0;
    const shadow_and_overflow = abi.current.shadow_space_bytes + n_overflow * 8;
    return (shadow_and_overflow + 15) & ~@as(u32, 15);
}

const Allocator = std.mem.Allocator;
const Error = types.Error;
const CallFixup = types.CallFixup;

const SpillDir = enum { spill, reload };

/// ADR-0155 stage 4 (D-265 Phase IV) — spill / reload every register-resident
/// homed local around a CALL/CALL-indirect/CALL-ref. Mirror of
/// `arm64/op_call.zig:homedCallerSavedSpillReload`, BUT the x86_64 pool has NO
/// callee-saved-survives-a-call exemption: although `abi.allocatable_gprs`
/// (RBX/R12-R14) ARE C-ABI callee-saved, a JIT *callee* (itself a JIT function)
/// does NOT push/restore the callee-saved GPRs it clobbers as temporaries — the
/// un-homed model keeps every cross-call-live value in a STACK SLOT, never a
/// register, so the JIT prologue only saves RBP/R15. A homed local is the first
/// value the JIT ever leaves in RBX/R12-R14 across a call; the recursive callee
/// reuses the SAME registers for ITS temporaries (and homes) and clobbers them
/// (the `rust_fib` `55 → 511` / recursive-loop hang). So EVERY register-resident
/// home is spilled to its frame slot before the CALL and reloaded after — the
/// register is the live value at the call site (`local.set` writes the home reg
/// directly). A spilled home (slot ≥ pool) already lives in its slot; skipped.
/// Width matches the prologue seed + get/set contract: i32 → 32-bit MOV (the
/// home is zero-extended), i64 → 64-bit MOV. `local_offsets[lidx]` is the local
/// slot's RBP-relative disp (already negative). No-op when `homing.count == 0`.
fn homedSpillReload(ctx: *ctx_mod.EmitCtx, dir: SpillDir) Error!void {
    const homing = ctx.homing;
    if (homing.count == 0) return;
    var r: u32 = 0;
    while (r < homing.count) : (r += 1) {
        const home_vreg: u32 = ctx.n_temp + r;
        const home_reg: abi.Gpr = switch (ctx.alloc.slot(home_vreg, .gpr)) {
            .reg => |id| abi.slotToReg(id) orelse return Error.SlotOverflow,
            // A spilled home already lives in its own frame slot across the call.
            .spill => continue,
        };
        const lidx: u32 = homing.local_idx[r];
        const disp: i32 = ctx.local_offsets[lidx];
        switch (ctx.func.localValType(lidx)) {
            .i32 => switch (dir) {
                .spill => try ctx.buf.appendSlice(ctx.allocator, rbp_disp.rbpStoreR32(disp, home_reg).slice()),
                .reload => try ctx.buf.appendSlice(ctx.allocator, rbp_disp.rbpLoadR32(home_reg, disp).slice()),
            },
            .i64 => switch (dir) {
                .spill => try ctx.buf.appendSlice(ctx.allocator, rbp_disp.rbpStoreR64(disp, home_reg).slice()),
                .reload => try ctx.buf.appendSlice(ctx.allocator, rbp_disp.rbpLoadR64(home_reg, disp).slice()),
            },
            // local_homing.isHomeableType only homes i32/i64.
            .f32, .f64, .v128, .ref => unreachable,
        }
    }
}

fn spillHomedCallerSaved(ctx: *ctx_mod.EmitCtx) Error!void {
    try homedSpillReload(ctx, .spill);
}

pub fn reloadHomedCallerSaved(ctx: *ctx_mod.EmitCtx) Error!void {
    try homedSpillReload(ctx, .reload);
}

/// `(ctx, ins)` adapters for the call
/// cohort (`call`, `call_indirect`). Two distinct adapters
/// (heterogeneous — call uses func_sigs+num_imports;
/// call_indirect uses module_types+oobtable_fixups+ins.extra).
pub fn emitCallCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    // ADR-0155 stage 4 — spill register-resident homes before the CALL (the
    // callee clobbers RBX/R12-R14), reload after (the result is already
    // captured into a non-home vreg by `emitCall`).
    try spillHomedCallerSaved(ctx);
    try emitCall(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.call_fixups,
        ctx.spill_base_off,
        ctx.outgoing_max_bytes,
        ctx.func_sigs,
        ctx.num_imports,
        @as(u32, @intCast(ins.payload)),
    );
    try reloadHomedCallerSaved(ctx);
    try op_control.emitPostCallTrapCheck(ctx);
}

pub fn emitCallIndirectCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    try spillHomedCallerSaved(ctx);
    try emitCallIndirect(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.oobtable_fixups,
        ctx.cind_sig_fixups,
        ctx.uninit_elem_fixups,
        ctx.spill_base_off,
        ctx.outgoing_max_bytes,
        ctx.module_types,
        @as(u32, @intCast(ins.payload)),
        ins.extra,
        ctx.uses_type_subtyping,
        // D-475: table_idx = ins.extra; i64 tables pop a 64-bit index.
        ctx.func.tableIdxType(ins.extra) == .i64,
    );
    try reloadHomedCallerSaved(ctx);
    try op_control.emitPostCallTrapCheck(ctx);
}

/// Wasm spec §3.4.7 (call N) — direct call. Mirrors
/// `arm64/op_call.zig:emitCall`: marshals args into per-CC arg
/// regs, restores entry_arg0 (= runtime_ptr) from R15 (caller-
/// saved RDI/RCX may have been clobbered by a previous call),
/// emits CALL placeholder + records `CallFixup` for the post-emit
/// linker, captures return into the next vreg.
///
/// Chunk 7.9-d: if `callee_idx < num_imports`, dispatch via
/// `JitRuntime.host_dispatch_base[idx]` — the host-import path
/// is an indirect call through the dispatch table populated by
/// the runner before invoking the entry. Args are passed
/// per the platform C ABI; the JIT-side calling convention
/// reserves arg0 for the runtime_ptr (= JitRuntime ptr), so host
/// fn signatures take `(rt: *JitRuntime, ...wasm_args)
/// callconv(.c)`.
///
/// **Scope**: i32 args + i32 / void return only. f32/f64/i64
/// args + return surface as UnsupportedOp (lifted alongside
/// 7.7-fp / globals i64 chunks).
/// ADR-0069 §Phase 2 chunk (b)-e-3 / D-165 close 2026-05-23 —
/// returns the byte offset within THIS call's outgoing-args
/// footprint where the MEMORY-class return buffer is placed.
/// SysV §3.2.3: buffer immediately above the overflow-args region
/// at the bottom of outgoing-args. Win64 (D-165): buffer at top
/// of outgoing-args, above shadow(32) + overflow + v128 scratch.
/// v128 args excluded from SysV path (rare + 16B alignment
/// complications). For non-MEMORY callees, return value is
/// unused.
fn computeCallReturnBufferOff(callee_sig: zir.FuncType) u32 {
    var n_int: u32 = 0;
    var n_fp: u32 = 0;
    var n_v128: u32 = 0;
    for (callee_sig.params) |p| {
        switch (p) {
            .i32, .i64, .ref => n_int += 1,
            .f32, .f64 => n_fp += 1,
            .v128 => n_v128 += 1,
        }
    }
    const callee_is_memory_class = callee_sig.results.len > 2;
    return switch (abi.current_cc) {
        .sysv => blk: {
            // SysV: MEMORY callees consume 2 slots (RDI=buffer,
            // RSI=rt) → 4 user int regs (RDX/RCX/R8/R9); non-MEMORY
            // 5 user int regs (RSI..R9).
            const n_user_int_regs: u32 = if (callee_is_memory_class) 4 else 5;
            const n_int_overflow: u32 = if (n_int > n_user_int_regs) n_int - n_user_int_regs else 0;
            const n_fp_overflow: u32 = if (n_fp > 8) n_fp - 8 else 0;
            break :blk (n_int_overflow + n_fp_overflow) * 8;
        },
        .win64 => blk: {
            // Win64 D-165: mirror of SysV with 2-slot shift for
            // MEMORY (RCX=buffer, RDX=rt) → 2 user int regs
            // (R8/R9); non-MEMORY 3 user int regs (RDX/R8/R9).
            // Buffer sits above shadow + overflow + v128 scratch.
            const n_int_w = n_int + n_v128;
            const n_total = n_int_w + n_fp;
            const n_user_int_regs: u32 = if (callee_is_memory_class) 2 else 3;
            const n_overflow: u32 = if (n_total > n_user_int_regs) n_total - n_user_int_regs else 0;
            const shadow_and_overflow = abi.current.shadow_space_bytes + n_overflow * 8;
            const scratch_base = (shadow_and_overflow + 15) & ~@as(u32, 15);
            break :blk scratch_base + n_v128 * 16;
        },
    };
}

pub fn emitCall(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    call_fixups: *std.ArrayList(CallFixup),
    spill_base_off: u32,
    outgoing_max_bytes: u32,
    func_sigs: []const zir.FuncType,
    num_imports: u32,
    callee_idx: u32,
) Error!void {
    if (callee_idx >= func_sigs.len) return Error.AllocationMissing;
    const callee_sig = func_sigs[callee_idx];

    const memory_class_return: bool = callee_sig.results.len > 2;
    try marshalCallArgs(allocator, buf, alloc, pushed_vregs, spill_base_off, callee_sig);

    // ADR-0026 2026-05-18 Convention Swap / ADR-0069 §Phase 2 +
    // D-165 close 2026-05-23 (Win64 mirror). When callee returns
    // MEMORY-class (results.len > 2), LEA the per-call return
    // buffer's address into the hidden-ptr arg reg just before
    // CALL — RDI on SysV (slot 0; SysV §3.2.3), RCX on Win64
    // (slot 0; Microsoft x64 §"Return values for >8 B structs").
    // Emitted after `marshalCallArgs` because the arg shuffle may
    // stage spilled values through R10/R11; the LEA happens after
    // the last stage use. SysV buffer placement = above overflow
    // args at bottom of outgoing region; Win64 placement = above
    // shadow + overflow + v128 scratch at top. Computed by
    // `computeCallReturnBufferOff`.
    const return_buffer_off: u32 = if (memory_class_return) computeCallReturnBufferOff(callee_sig) else 0;
    if (memory_class_return) {
        const hidden_ptr_gpr: abi.Gpr = if (abi.current_cc == .win64) .rcx else .rdi;
        try buf.appendSlice(allocator, inst.encLeaR64BaseRspDisp32(hidden_ptr_gpr, @intCast(return_buffer_off)).slice());
    }

    if (callee_idx < num_imports) {
        // Chunk 7.9-d: host-import dispatch via JitRuntime.
        // host_dispatch_base[idx]. Args are already in the per-CC
        // arg regs (marshalCallArgs above). Restore entry_arg0 =
        // runtime_ptr so the host stub sees the JitRuntime ptr as
        // its hidden first arg (signature
        // `fn(rt: *JitRuntime, ...wasm_args) callconv(.c)`).
        //
        //   (see emitImportDispatch for the sequence)
        try emitImportDispatch(allocator, buf, outgoing_max_bytes, callee_idx);
        try captureCallResult(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, callee_sig, memory_class_return, return_buffer_off);
        return;
    }

    // Restore <runtime_ptr arg slot> = runtime_ptr from R15 before
    // transferring control. The callee's prologue captures that
    // slot into its own R15 (per ADR-0026). The slot is caller-
    // saved in both SysV (RDI) and Win64 (RCX) and may have been
    // clobbered by an earlier call.
    //
    // ADR-0026 2026-05-18 Convention Swap + D-165 close 2026-05-23
    // (Win64 mirror): when the callee returns MEMORY-class, slot 0
    // is now occupied by &result_buffer (RDI on SysV / RCX on
    // Win64) and rt moves to slot 1 (RSI on SysV / RDX on Win64).
    const rt_dst_gpr: abi.Gpr = if (memory_class_return)
        (if (abi.current_cc == .win64) .rdx else .rsi)
    else
        abi.current.entry_arg0_gpr;
    try buf.appendSlice(allocator, inst.encMovRR(.q, rt_dst_gpr, abi.runtime_ptr_save_gpr).slice());

    // Win64 ABI: caller reserves 32 bytes of shadow space below
    // the call site for the callee to optionally spill its 4
    // register args. Folds shadow allocation into
    // the prologue's outgoing-args region (`outgoing_max_bytes`
    // already includes shadow when any call exists), so this
    // helper becomes a no-op when prologue pre-allocation took
    // ownership. Falls back to per-call SUB RSP, 32 only when
    // outgoing_max_bytes == 0 (= no calls; defensive — emitCall
    // would not be reached).
    try emitShadowAlloc(allocator, buf, outgoing_max_bytes);

    // CALL placeholder; linker patches via call_fixups once
    // function-body offsets are known.
    const fixup_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encCallRel32(0).slice());
    try call_fixups.append(allocator, .{
        .byte_offset = fixup_at,
        .target_func_idx = callee_idx,
    });

    try emitShadowFree(allocator, buf, outgoing_max_bytes);

    try captureCallResult(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, callee_sig, memory_class_return, return_buffer_off);
}

/// Emit the host-import indirect dispatch (Chunk 7.9-d) via
/// `JitRuntime.host_dispatch_base[import_idx]`:
///
///   MOV RAX, [R15 + host_dispatch_base_off]   ; ptr-of-ptrs
///   MOV RAX, [RAX + idx*8]                     ; actual fn / thunk ptr
///   MOV <entry_arg0>, R15                      ; restore rt_ptr
///   [Win64: SUB RSP, 32 — shadow space]
///   CALL RAX
///   [Win64: ADD RSP, 32]
///
/// Args MUST already be marshalled into the per-CC arg regs; the
/// result lands in the per-CC return reg per the callee sig. Shared
/// by `emitCall`'s import branch and
/// `op_tail_call.emitCrossModuleReturnCall` (the cross-module
/// `return_call` call-and-return path, ADR-0112 Amendment 2026-05-30).
/// `idx * 8` must fit the disp32 budget (≤ 0x7FFF_FFFF) —
/// UnsupportedOp otherwise.
pub fn emitImportDispatch(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    outgoing_max_bytes: u32,
    import_idx: u32,
) Error!void {
    const idx_byte_off_u: u64 = @as(u64, import_idx) * 8;
    if (idx_byte_off_u > 0x7FFF_FFFF) return Error.UnsupportedOp;
    const idx_byte_off: i32 = @intCast(idx_byte_off_u);
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.host_dispatch_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rax, idx_byte_off).slice());
    try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());
    try emitShadowAlloc(allocator, buf, outgoing_max_bytes);
    try buf.appendSlice(allocator, inst.encCallReg(.rax).slice());
    try emitShadowFree(allocator, buf, outgoing_max_bytes);
}

/// Reserve Win64 shadow space below the upcoming CALL. No-op when
/// `outgoing_max_bytes > 0` (shadow already allocated by the
/// prologue) or when SysV (`shadow_space_bytes
/// == 0`). Per ADR-0026 / Microsoft x64.
pub fn emitShadowAlloc(allocator: Allocator, buf: *std.ArrayList(u8), outgoing_max_bytes: u32) Error!void {
    if (abi.current.shadow_space_bytes == 0) return;
    if (outgoing_max_bytes > 0) return;
    try buf.appendSlice(allocator, inst.encSubRSpImm8(@intCast(abi.current.shadow_space_bytes)).slice());
}

/// Free Win64 shadow space after CALL returns. Mirror of
/// `emitShadowAlloc` (same gating).
pub fn emitShadowFree(allocator: Allocator, buf: *std.ArrayList(u8), outgoing_max_bytes: u32) Error!void {
    if (abi.current.shadow_space_bytes == 0) return;
    if (outgoing_max_bytes > 0) return;
    try buf.appendSlice(allocator, inst.encAddRSpImm8(@intCast(abi.current.shadow_space_bytes)).slice());
}

/// (per ADR-0059) — `memory.grow`
/// callout via `JitRuntime.memory_grow_fn`. C-ABI args:
/// `entry_arg0 = rt`, `arg1 = delta_pages`; result in EAX.
/// x86_64 reads `vm_base` / `mem_limit` from `[R15+off]` on
/// every memory op (no prologue cache; per ADR-0017 asymmetry),
/// so no post-call invariant reload is needed.
pub fn emitMemoryGrow(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    outgoing_max_bytes: u32,
    mem64: bool,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const delta_v = pushed_vregs.pop().?;
    const second_arg = abi.current.arg_gprs[1];
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, delta_v, 0);
    if (src_r != second_arg) {
        try buf.appendSlice(allocator, inst.encMovRR(.d, second_arg, src_r).slice());
    }
    try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.memory_grow_fn_off).slice());
    try emitShadowAlloc(allocator, buf, outgoing_max_bytes);
    try buf.appendSlice(allocator, inst.encCallReg(.rax).slice());
    try emitShadowFree(allocator, buf, outgoing_max_bytes);
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    if (mem64) {
        // memory64 grow result is i64 — sign-extend EAX so the -1 failure
        // sentinel widens to i64 -1 (D-216). Always emit (even dst==RAX:
        // MOVSXD RAX,EAX in place; a 32-bit MOV would zero-extend).
        try buf.appendSlice(allocator, inst.encMovsxdR64R32(dst_r, abi.return_gpr).slice());
    } else if (dst_r != abi.return_gpr) {
        try buf.appendSlice(allocator, inst.encMovRR(.d, dst_r, abi.return_gpr).slice());
    }
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §3.4.7 (call_indirect type_idx) — pops the index,
/// marshals args, runs bounds + sig checks (both branch to the
/// shared trap stub via bounds_fixups), loads the funcptr from (then null-tests it, D-586)
/// `funcptr_base[idx]`, restores RDI = runtime_ptr, and CALLs
/// through RAX.
///
/// **Scratch register strategy**: RAX is used as scratch
/// throughout. RAX is NOT in the regalloc pool (`abi.zig`
/// excludes it as `return_gpr`), so it cannot collide with any
/// live vreg. This avoids needing a `spill_stage_gprs`
/// reservation (the arm64 X16/X17 mirror) for x86_64 — RAX is
/// dead from prologue through every instruction up to the CALL
/// itself, then comes alive holding the return value.
///
/// **JitRuntime invariant access** per ADR-0026: each of
/// `table_size`, `typeidx_base`, `funcptr_base` reloads from
/// `[R15 + offset]` at point of use rather than holding
/// callee-saved slots. The cost (3 extra MOVs vs ARM64's
/// 3 reserved-reg reads) is accepted per ADR-0026 §"Decision".
pub fn emitCallIndirect(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    oobtable_fixups: *std.ArrayList(u32),
    cind_sig_fixups: *std.ArrayList(u32),
    uninit_elem_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    outgoing_max_bytes: u32,
    module_types: []const zir.FuncType,
    type_idx: u32,
    table_idx: u32,
    /// D-235 — subtyping module: route the sig check through the
    /// `jitCallIndirectResolve` trampoline (vs the finality/subtype-blind
    /// inline D-111 CMP). `false` keeps the byte-identical inline path.
    uses_type_subtyping: bool,
    /// D-475 (table64) — the target table is i64-indexed: stage/compare
    /// the popped index at .q width instead of the i32 .d fast path.
    ci_idx64: bool,
) Error!void {
    if (type_idx >= module_types.len) return Error.AllocationMissing;
    const callee_sig = module_types[type_idx];

    // Stack at entry: [args..., idx]. Pop idx first.
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_vreg = pushed_vregs.pop().?;

    // D-235: subtyping modules check bounds + subtype via the
    // `jitCallIndirectResolve` trampoline BEFORE marshalling (the inline
    // D-111 CMP is finality/subtype-blind). The C-ABI trampoline preserves
    // callee-saved regs; the x86_64 regalloc pool is ALL callee-saved
    // ({RBX,R12-R14}) + force-spilled operands (regalloc inclusive crossing
    // for subtyping call_indirect), so idx survives the call and the inline
    // funcptr load below re-derives it. The trampoline's funcptr return is
    // used only for the trap test here (re-derived inline); the inline
    // bounds + sig blocks are gated off below.
    if (uses_type_subtyping) {
        const expected_raw: u32 = type_idx;
        const ag = abi.current.arg_gprs; // SysV: rdi,rsi,rdx,rcx · Win64: rcx,rdx,r8,r9
        const idx_r0 = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_vreg, 0);
        // args: ag[0]=rt, ag[1]=table_idx, ag[2]=idx, ag[3]=expected_raw.
        // idx_r0 ∉ arg_gprs (it is callee-saved pool or a stage reg), so the
        // arg-reg writes can't clobber it.
        if (idx_r0 != ag[2]) try buf.appendSlice(allocator, inst.encMovRR(if (ci_idx64) .q else .d, ag[2], idx_r0).slice());
        try buf.appendSlice(allocator, inst.encMovRR(.q, ag[0], abi.runtime_ptr_save_gpr).slice());
        try buf.appendSlice(allocator, inst.encMovImm32W(ag[1], table_idx).slice());
        try buf.appendSlice(allocator, inst.encMovImm32W(ag[3], expected_raw).slice());
        // ADR-0203 D1 — helper via the rt slot ([R15+off]), not a baked imm64 (D-516 PIC).
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.call_indirect_resolve_fn_off).slice());
        try buf.appendSlice(allocator, inst.encCallReg(.rax).slice());
        // RAX = funcptr | 0 (OOB/sig) | 1 (NULL_ELEM_SENTINEL). D-294 residual:
        // CMP RAX,1 ; JE → uninitialized_elem (code 13) FIRST, so a null elem under
        // a subtyping module matches the inline path + interp + wasmtime/wasmer.
        try buf.appendSlice(allocator, inst.encCmpRImm8(.q, .rax, 1).slice());
        {
            const fixup_at: u32 = @intCast(buf.items.len);
            try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
            try uninit_elem_fixups.append(allocator, fixup_at);
        }
        // CMP RAX,2 ; JE → oob_table (code 2): index past the table (#357).
        try buf.appendSlice(allocator, inst.encCmpRImm8(.q, .rax, 2).slice());
        {
            const fixup_at: u32 = @intCast(buf.items.len);
            try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
            try oobtable_fixups.append(allocator, fixup_at);
        }
        // RAX = funcptr | 0 (subtype mismatch). TEST RAX,RAX ; JE → sig stub (code 3).
        try buf.appendSlice(allocator, inst.encTestRR(.q, .rax, .rax).slice());
        {
            const fixup_at: u32 = @intCast(buf.items.len);
            try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
            try cind_sig_fixups.append(allocator, fixup_at);
        }
    }

    try marshalCallArgs(allocator, buf, alloc, pushed_vregs, spill_base_off, callee_sig);

    // D-097 d-18: load idx AFTER marshalCallArgs. The marshalling
    // stages spilled args through R10 (stage 0); loading idx_r
    // before would let marshalling clobber its R10 home (when idx
    // is spilled), so the bounds + sig + funcptr-index loads later
    // would read whatever-arg-was-last-staged instead of the
    // call_indirect idx. Surfaced when ADR-0060 d-16 force-spilled
    // a call-crossing if-result fed into call_indirect's idx slot
    // (`if.wast:as-call_indirect-{first,mid,last}` × 3).
    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_vreg, 0);

    const expected_typeidx: u32 = canonical_type.canonicalTypeidx(module_types, type_idx);

    if (table_idx == 0) {
        // Table-0 fast path: bounds via [R15+table_size_off], sig
        // via [R15+typeidx_base_off], funcptr via
        // [R15+funcptr_base_off]. Scalar JitRuntime fields stay
        // backed by table 0's funcptrs/typeidxs.

        // D-235: subtyping modules already validated bounds + subtype via the
        // resolve trampoline above → skip the inline bounds + sig (the inline
        // D-111 CMP is finality/subtype-blind). funcptr re-derived below.
        if (!uses_type_subtyping) {
            // Bounds: MOV RAX, [R15 + table_size_off] ; CMP idx_r, RAX/EAX ; JAE trap.
            // 64-bit load (D-475: table_size is u64); the CMP is .q for an
            // i64 table (full 64-bit index) and stays .d on the i32 fast path.
            try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.table_size_off).slice());
            try buf.appendSlice(allocator, inst.encCmpRR(if (ci_idx64) .q else .d, idx_r, .rax).slice());
            {
                const fixup_at: u32 = @intCast(buf.items.len);
                try buf.appendSlice(allocator, inst.encJccRel32(.ae, 0).slice());
                try oobtable_fixups.append(allocator, fixup_at); // D-293 oob_table (code 2)
            }

            // Sig: MOV RAX, [R15 + typeidx_base_off] (load u32* table)
            //      MOV EAX, [RAX + idx_r * 4]        (load expected typeidx)
            //      CMP EAX, canonical (imm32) ; JNE trap.
            // Wasm spec §3.4.6 + §4.4.10.1 — sig check is **structural**
            // FuncType equality. Compare against the canonical (lowest-
            // index) typeidx whose shape matches `module_types[type_idx]`;
            // `applyTableInit` writes the same canonicalization on the
            // funcref's stored typeidx. D-111.
            try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.typeidx_base_off).slice());
            try buf.appendSlice(allocator, inst.encMovR32FromBaseIdxLsl2(.rax, .rax, idx_r).slice());
            // D-294: null slot's typeidx is maxInt(u32) (no-func sentinel). Check it
            // BEFORE the sig CMP so a null elem reports uninitialized_elem (code 13),
            // not indirect_call_mismatch. CMP leaves EAX intact for the sig CMP below.
            try buf.appendSlice(allocator, inst.encCmpRImm32(.rax, 0xFFFFFFFF).slice());
            {
                const fixup_at: u32 = @intCast(buf.items.len);
                try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
                try uninit_elem_fixups.append(allocator, fixup_at); // D-294 uninitialized_elem (code 13)
            }
            try buf.appendSlice(allocator, inst.encCmpRImm32(.rax, expected_typeidx).slice());
            {
                const fixup_at: u32 = @intCast(buf.items.len);
                try buf.appendSlice(allocator, inst.encJccRel32(.ne, 0).slice());
                try cind_sig_fixups.append(allocator, fixup_at); // D-293 slice-2 indirect_call_mismatch (code 3)
            }
        }

        // Funcptr: MOV RAX, [R15 + funcptr_base_off] ; MOV RAX, [RAX + idx_r*8].
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.funcptr_base_off).slice());
        try buf.appendSlice(allocator, inst.encMovR64FromBaseIdxLsl3(.rax, .rax, idx_r).slice());
        // D-586 — a zero funcptr with a VALID typeidx: a host cleared this
        // slot through `tableSetRef`, which leaves the typeidx mirror intact so
        // the D-294 sentinel does not fire. Imports themselves hold the bridge
        // thunk. Without this test the CALL executed the zero and the process
        // died; test for it as the subtyping path above already does.
        try buf.appendSlice(allocator, inst.encTestRR(.q, .rax, .rax).slice());
        {
            const fixup_at: u32 = @intCast(buf.items.len);
            try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
            try cind_sig_fixups.append(allocator, fixup_at);
        }
    } else {
        // Multi-table slow path (D-112):
        // load per-table size + bases from
        // `JitRuntime.tables_ptr[table_idx].len` +
        // `JitRuntime.tables_jit_ci_ptr[table_idx]` at the call
        // site. RAX remains the only scratch (per the "RAX is not
        // in the regalloc pool" invariant above), so each base
        // load reloads the array pointer.
        if (jit_abi.table_jit_ci_size != 16) @compileError("multi-table x86_64 emit assumes TableJitCallInfo stride 16");

        // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
        // TableSlice stride is `table_slice_size` (32 after the D-475
        // u64 len/max widen). TableJitCallInfo stride stays 16.
        const tbl_slice_disp: i32 = @intCast((table_idx * jit_abi.table_slice_size) + jit_abi.tableslice_len_off);
        const ci_funcptr_disp: i32 = @intCast(table_idx * 16);
        const ci_typeidx_disp: i32 = @intCast((table_idx * 16) + 8);

        // D-235: subtyping modules already validated bounds + subtype via the
        // resolve trampoline above → skip the inline bounds + sig.
        if (!uses_type_subtyping) {
            // Bounds: MOV RAX, [R15 + tables_ptr_off]
            //         MOV RAX, [RAX + (table_idx*table_slice_size + len_off)]  ; TableSlice.len (u64, D-475)
            //         CMP idx_r, RAX/EAX ; JAE trap (.q for an i64 table).
            try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off).slice());
            try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rax, tbl_slice_disp).slice());
            try buf.appendSlice(allocator, inst.encCmpRR(if (ci_idx64) .q else .d, idx_r, .rax).slice());
            {
                const fixup_at: u32 = @intCast(buf.items.len);
                try buf.appendSlice(allocator, inst.encJccRel32(.ae, 0).slice());
                try oobtable_fixups.append(allocator, fixup_at); // D-293 oob_table (code 2)
            }

            // Sig: MOV RAX, [R15 + tables_jit_ci_ptr_off]
            //      MOV RAX, [RAX + (table_idx*16 + 8)]  ; typeidx_base
            //      MOV EAX, [RAX + idx_r * 4]
            //      CMP EAX, canonical ; JNE trap.
            try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off).slice());
            try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rax, ci_typeidx_disp).slice());
            try buf.appendSlice(allocator, inst.encMovR32FromBaseIdxLsl2(.rax, .rax, idx_r).slice());
            // D-294: null slot's typeidx is the maxInt(u32) sentinel — check before sig.
            try buf.appendSlice(allocator, inst.encCmpRImm32(.rax, 0xFFFFFFFF).slice());
            {
                const fixup_at: u32 = @intCast(buf.items.len);
                try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
                try uninit_elem_fixups.append(allocator, fixup_at); // D-294 uninitialized_elem (code 13)
            }
            try buf.appendSlice(allocator, inst.encCmpRImm32(.rax, expected_typeidx).slice());
            {
                const fixup_at: u32 = @intCast(buf.items.len);
                try buf.appendSlice(allocator, inst.encJccRel32(.ne, 0).slice());
                try cind_sig_fixups.append(allocator, fixup_at); // D-293 slice-2 indirect_call_mismatch (code 3)
            }
        }

        // Funcptr: MOV RAX, [R15 + tables_jit_ci_ptr_off]
        //          MOV RAX, [RAX + (table_idx*16 + 0)]  ; funcptr_base
        //          MOV RAX, [RAX + idx_r * 8].
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.tables_jit_ci_ptr_off).slice());
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rax, ci_funcptr_disp).slice());
        try buf.appendSlice(allocator, inst.encMovR64FromBaseIdxLsl3(.rax, .rax, idx_r).slice());
        // D-586 — a zero funcptr with a VALID typeidx: a host cleared this
        // slot through `tableSetRef`, which leaves the typeidx mirror intact so
        // the D-294 sentinel does not fire. Imports themselves hold the bridge
        // thunk. Without this test the CALL executed the zero and the process
        // died; test for it as the subtyping path above already does.
        try buf.appendSlice(allocator, inst.encTestRR(.q, .rax, .rax).slice());
        {
            const fixup_at: u32 = @intCast(buf.items.len);
            try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
            try cind_sig_fixups.append(allocator, fixup_at);
        }
    }

    // ADR-0026 2026-05-18 Convention Swap / ADR-0069 §Phase 2 +
    // D-165 close 2026-05-23 (Win64 mirror): mirror of `emitCall`
    // — for MEMORY-class callees, LEA the return buffer's address
    // into the hidden-ptr arg reg (RDI on SysV / RCX on Win64).
    // Placed AFTER the bounds/sig/funcptr load (which uses RAX
    // as scratch) but BEFORE the runtime_ptr-slot restore + CALL.
    const memory_class_return: bool = callee_sig.results.len > 2;
    const return_buffer_off: u32 = if (memory_class_return) computeCallReturnBufferOff(callee_sig) else 0;
    if (memory_class_return) {
        const hidden_ptr_gpr: abi.Gpr = if (abi.current_cc == .win64) .rcx else .rdi;
        try buf.appendSlice(allocator, inst.encLeaR64BaseRspDisp32(hidden_ptr_gpr, @intCast(return_buffer_off)).slice());
    }

    // Restore runtime_ptr arg slot (callee's prologue reads it
    // as its inbound JitRuntime ptr per ADR-0026 / Convention Swap
    // + D-165 close): slot 0 (RDI SysV / RCX Win64) when non-
    // MEMORY; slot 1 (RSI SysV / RDX Win64) when MEMORY-class.
    const rt_dst_gpr: abi.Gpr = if (memory_class_return)
        (if (abi.current_cc == .win64) .rdx else .rsi)
    else
        abi.current.entry_arg0_gpr;
    try buf.appendSlice(allocator, inst.encMovRR(.q, rt_dst_gpr, abi.runtime_ptr_save_gpr).slice());

    // Win64 shadow space (32 bytes; SysV no-op; both no-op when
    // prologue pre-allocation took ownership).
    try emitShadowAlloc(allocator, buf, outgoing_max_bytes);

    // CALL RAX (indirect).
    try buf.appendSlice(allocator, inst.encCallReg(.rax).slice());

    try emitShadowFree(allocator, buf, outgoing_max_bytes);

    try captureCallResult(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, callee_sig, memory_class_return, return_buffer_off);
}

/// Wasm spec 3.0 §3.3.8.13 (`call_ref $sig`) — call through a typed
/// funcref. Mirror of `arm64/op_call.zig:emitCallRef`. The funcref
/// operand is `@intFromPtr(*const FuncEntity)` (the `ref.func` /
/// `Value.fromFuncRef` encoding). Mirrors `emitCallIndirect` MINUS
/// the bounds/sig check: the validator guarantees the funcref's
/// actual type ⊑ `$sig`, so only a null trap is needed (call_ref of
/// a null funcref traps, §4.4.8.13).
///   (1) pop funcref vreg (stack: [args..., funcref]),
///   (2) marshalCallArgs,
///   (3) funcref ptr → reg ; `OR reg,reg ; JZ trap` (null check,
///       null_reference code 10 via null_ref_fixups — D-293 slice-4b),
///   (4) MOV RAX, [reg + funcentity_funcptr_offset]  (native entry),
///   (5) MEMORY-class buffer LEA + restore runtime_ptr + shadow,
///   (6) CALL RAX, captureCallResult.
pub fn emitCallRefCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    try spillHomedCallerSaved(ctx);
    try emitCallRef(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.null_ref_fixups,
        ctx.spill_base_off,
        ctx.outgoing_max_bytes,
        ctx.module_types,
        @as(u32, @intCast(ins.payload)),
    );
    try reloadHomedCallerSaved(ctx);
    try op_control.emitPostCallTrapCheck(ctx);
}

pub fn emitCallRef(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    null_ref_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    outgoing_max_bytes: u32,
    module_types: []const zir.FuncType,
    type_idx: u32,
) Error!void {
    if (type_idx >= module_types.len) return Error.AllocationMissing;
    const callee_sig = module_types[type_idx];

    // Stack at entry: [args..., funcref]. Pop funcref first.
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const funcref_vreg = pushed_vregs.pop().?;

    try marshalCallArgs(allocator, buf, alloc, pushed_vregs, spill_base_off, callee_sig);

    // Load funcref pointer (mirror emitCallIndirect's idx load: AFTER
    // marshalCallArgs so its R10 staging doesn't clobber the load).
    const funcref_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, funcref_vreg, 0);

    // Null check: OR funcref_r, funcref_r (sets ZF iff null, value
    // unchanged) ; JZ trap. D-293 slice-4b — a null call_ref is null_reference
    // (code 10), routed to the dedicated null_ref trap stub.
    try buf.appendSlice(allocator, inst.encOrRR(.q, funcref_r, funcref_r).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
        try null_ref_fixups.append(allocator, fixup_at);
    }

    // Native entry: MOV RAX, [funcref_r + funcentity_funcptr_offset].
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, funcref_r, @intCast(func_mod.funcentity_funcptr_offset)).slice());

    // Tail identical to emitCallIndirect: MEMORY-class buffer LEA,
    // restore runtime_ptr arg slot, shadow alloc, CALL RAX, capture.
    const memory_class_return: bool = callee_sig.results.len > 2;
    const return_buffer_off: u32 = if (memory_class_return) computeCallReturnBufferOff(callee_sig) else 0;
    if (memory_class_return) {
        const hidden_ptr_gpr: abi.Gpr = if (abi.current_cc == .win64) .rcx else .rdi;
        try buf.appendSlice(allocator, inst.encLeaR64BaseRspDisp32(hidden_ptr_gpr, @intCast(return_buffer_off)).slice());
    }
    const rt_dst_gpr: abi.Gpr = if (memory_class_return)
        (if (abi.current_cc == .win64) .rdx else .rsi)
    else
        abi.current.entry_arg0_gpr;
    try buf.appendSlice(allocator, inst.encMovRR(.q, rt_dst_gpr, abi.runtime_ptr_save_gpr).slice());

    try emitShadowAlloc(allocator, buf, outgoing_max_bytes);
    try buf.appendSlice(allocator, inst.encCallReg(.rax).slice());
    try emitShadowFree(allocator, buf, outgoing_max_bytes);

    try captureCallResult(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, callee_sig, memory_class_return, return_buffer_off);
}

/// Marshal call arguments per SysV x86_64 §3.2.3 / Microsoft x64
/// §"Argument Passing": pop N arg vregs in REVERSE (top-of-stack =
/// rightmost arg), then emit MOV from each arg's home register
/// into the per-Cc arg slot. Args overflowing the register pool
/// land at `[RSP + outgoing_offset + 8 * K]` in the caller's
/// pre-allocated outgoing-args region (mirror of
/// arm64). The callee's prologue reads them at `[RBP + 16
/// + r15_save_off + 8 * K]`.
///
/// **Per-Cc overflow position**:
///   - SysV: outgoing_offset = 0; per-overflow slot K = NSAA index
///     (incremented per overflowed arg of EITHER class — both
///     classes share the NSAA stream in declaration order).
///   - Win64: outgoing_offset = 32 (shadow space); per-overflow
///     slot K = `shared_slot - 4` where shared_slot tracks the
///     int/fp shared counter and 4 is the per-Cc reg pool size.
///
/// **No source-clobber risk by construction**: the regalloc pool
/// (RBX, R12-R14 ± RDI/RSI on Win64) is disjoint from the per-Cc
/// arg regs, so naive sequential MOV per arg is correct without
/// parallel-move analysis. Spilled args stage through R10/R11
/// (GPR) or XMM14/15 (FP) via the spill-aware helpers — disjoint
/// from arg regs and from each other across stages.
///
/// **Scope**: ≤ 128 args (effectively unlimited). Reftype params
/// (funcref / externref) ride the i64 8-byte gpr-class path per
/// ADR-0061 (D-093 d-33).
pub fn marshalCallArgs(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    spill_base_off: u32,
    callee_sig: zir.FuncType,
) Error!void {
    const n_args: u32 = @intCast(callee_sig.params.len);
    if (n_args == 0) return;
    if (pushed_vregs.items.len < n_args) return Error.AllocationMissing;

    // d-25: cap bumped 64 → 128 to fit `call.wast`'s 100-arg fixture.
    var arg_vregs: [128]u32 = undefined;
    if (n_args > arg_vregs.len) return types.rejectUnsupported("src/engine/codegen/x86_64/op_call.zig:217", 0);
    var i: u32 = n_args;
    while (i > 0) {
        i -= 1;
        arg_vregs[i] = pushed_vregs.pop().?;
    }

    // arg_gprs slot 0 carries `*const JitRuntime` (RDI on SysV,
    // RCX on Win64) — skip; user int args start at slot 1.
    // ADR-0026 2026-05-18 Convention Swap: when the SysV callee
    // returns MEMORY-class (results.len > 2), SysV §3.2.3 places
    // &result_buffer in RDI (slot 0) and shifts rt to RSI (slot 1);
    // user int args then start at RDX = slot 2.
    // FP args use a separate slot counter on SysV (§3.2.3 — int and
    // FP register pools are independent), but a SHARED counter on
    // Win64 (Microsoft x64 §"Argument Passing" — arg N occupies
    // either arg_gprs[N] or arg_xmms[N], advancing both indices).
    //   SysV non-MEMORY: arg_gprs[1..6] = RSI, RDX, RCX, R8, R9
    //                    (5 user GPRs)
    //   SysV MEMORY    : arg_gprs[2..6] = RDX, RCX, R8, R9
    //                    (4 user GPRs)
    //   SysV (both)    : arg_xmms[0..7] = XMM0..XMM7 (8 user FP)
    //   Win64          : arg_gprs[1..4] = RDX, R8, R9 (3 user GPRs);
    //                    arg_xmms[1..4] = XMM1..XMM3 (shared count).
    // D-165 close 2026-05-23: Win64 MEMORY-class also shifts user
    // args by 1 slot (RCX=&buffer, RDX=rt → user starts at R8 =
    // slot 2). Mirror of SysV.
    const callee_is_memory_class: bool = callee_sig.results.len > 2;
    var gpr_arg_slot: usize = if (callee_is_memory_class) 2 else 1;
    // SysV: FP slots independent of GPR. Win64: shared counter
    // tracks combined int+fp slot, so init mirrors gpr_arg_slot
    // (= 2 for MEMORY else 1).
    var fp_arg_slot: usize = if (abi.current_cc == .win64)
        (if (callee_is_memory_class) 2 else 1)
    else
        0;
    // SysV NSAA index (per-overflow counter; increments only on
    // overflow). Win64 reuses gpr_arg_slot/fp_arg_slot's shared
    // value to derive its overflow slot.
    var nsaa_idx: u32 = 0;
    // Win64 v128 hidden-pointer scratch index.
    // Counts v128 args processed so far; the per-arg scratch
    // lives at `[RSP + win64V128ScratchBase(sig) + v128_idx*16]`.
    var v128_idx: u32 = 0;
    const win64_v128_scratch_base: u32 = if (abi.current_cc == .win64)
        win64V128ScratchBase(callee_sig)
    else
        0;
    var k: u32 = 0;
    while (k < n_args) : (k += 1) {
        const src_vreg = arg_vregs[k];
        switch (callee_sig.params[k]) {
            .i32 => {
                if (gpr_arg_slot >= abi.current.arg_gprs.len) {
                    // Overflow: stage src into R10 (or R11 if R10
                    // already holds a prior overflowed arg in
                    // flight — but the marshal sequence emits each
                    // store before staging the next, so stage 0 is
                    // safe here). Then STR W to outgoing region.
                    const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    const disp = computeOverflowDisp(nsaa_idx, gpr_arg_slot);
                    try buf.appendSlice(allocator, inst.encStoreR32MemRSPDisp32(src, disp).slice());
                    nsaa_idx += 1;
                } else {
                    const dst = abi.current.arg_gprs[gpr_arg_slot];
                    const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    if (src != dst) {
                        try buf.appendSlice(allocator, inst.encMovRR(.d, dst, src).slice());
                    }
                }
                gpr_arg_slot += 1;
                if (abi.current_cc == .win64) fp_arg_slot += 1;
            },
            // D-093 (d-33): reftype shares i64 8-byte gpr slot.
            .i64, .ref => {
                if (gpr_arg_slot >= abi.current.arg_gprs.len) {
                    const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    const disp = computeOverflowDisp(nsaa_idx, gpr_arg_slot);
                    try buf.appendSlice(allocator, inst.encStoreR64MemRSPDisp32(src, disp).slice());
                    nsaa_idx += 1;
                } else {
                    const dst = abi.current.arg_gprs[gpr_arg_slot];
                    const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    if (src != dst) {
                        try buf.appendSlice(allocator, inst.encMovRR(.q, dst, src).slice());
                    }
                }
                gpr_arg_slot += 1;
                if (abi.current_cc == .win64) fp_arg_slot += 1;
            },
            .f32 => {
                if (fp_arg_slot >= abi.current.arg_xmms.len) {
                    const src = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    const disp = computeOverflowDisp(nsaa_idx, fp_arg_slot);
                    try buf.appendSlice(allocator, inst.encStoreXmmF32MemRSPDisp32(src, disp).slice());
                    nsaa_idx += 1;
                } else {
                    const dst = abi.current.arg_xmms[fp_arg_slot];
                    const src = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    if (src != dst) {
                        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, src).slice());
                    }
                }
                fp_arg_slot += 1;
                if (abi.current_cc == .win64) gpr_arg_slot += 1;
            },
            .f64 => {
                if (fp_arg_slot >= abi.current.arg_xmms.len) {
                    const src = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    const disp = computeOverflowDisp(nsaa_idx, fp_arg_slot);
                    try buf.appendSlice(allocator, inst.encStoreXmmF64MemRSPDisp32(src, disp).slice());
                    nsaa_idx += 1;
                } else {
                    const dst = abi.current.arg_xmms[fp_arg_slot];
                    const src = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    if (src != dst) {
                        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, src).slice());
                    }
                }
                fp_arg_slot += 1;
                if (abi.current_cc == .win64) gpr_arg_slot += 1;
            },
            // SysV + Win64 caller-side
            // v128 marshal. SysV (§3.2.3 SIMD): XMM0..XMM7 direct,
            // overflow on stack as 2-eightbyte SSE class (16-byte
            // aligned). Win64 (Microsoft x64 §"Param passing"):
            // hidden-pointer — write v128 to 16-byte aligned scratch
            // in caller's outgoing-args region, pass scratch address
            // in the next int-arg-reg slot (RDX/R8/R9) or overflow
            // 8-byte stack slot. Spilled v128 vregs trip D-078 (c)
            // via `resolveXmm`'s explicit UnsupportedOp.
            .v128 => {
                if (abi.current_cc == .win64) {
                    // Write v128 source into the per-call scratch
                    // slot at `[RSP + scratch_base + v128_idx*16]`.
                    const src = try gpr.resolveXmm(alloc, src_vreg);
                    const scratch_disp: i32 = @intCast(win64_v128_scratch_base + v128_idx * 16);
                    try buf.appendSlice(allocator, inst.encStoreXmmV128MemRSPDisp32(src, scratch_disp).slice());
                    // Pass the scratch address in the int-arg-reg slot,
                    // or store the pointer onto the stack overflow.
                    if (gpr_arg_slot < abi.current.arg_gprs.len) {
                        const ptr_reg = abi.current.arg_gprs[gpr_arg_slot];
                        try buf.appendSlice(allocator, inst.encLeaR64BaseRspDisp32(ptr_reg, scratch_disp).slice());
                    } else {
                        // Stack overflow: caller writes the 8-byte
                        // pointer into the int-arg shared slot.
                        try buf.appendSlice(allocator, inst.encLeaR64BaseRspDisp32(.rax, scratch_disp).slice());
                        const disp = computeOverflowDisp(nsaa_idx, gpr_arg_slot);
                        try buf.appendSlice(allocator, inst.encStoreR64MemRSPDisp32(.rax, disp).slice());
                        nsaa_idx += 1;
                    }
                    gpr_arg_slot += 1;
                    fp_arg_slot += 1;
                    v128_idx += 1;
                } else {
                    // SysV path.
                    if (fp_arg_slot >= abi.current.arg_xmms.len) {
                        // SysV v128 stack-overflow co-discharge:
                        // write the 16-byte v128 to `[RSP + nsaa_disp]`,
                        // 16-byte aligned (NSAA SSE class takes 2 eightbytes).
                        if ((nsaa_idx & 1) != 0) nsaa_idx += 1;
                        const src = try gpr.resolveXmm(alloc, src_vreg);
                        const disp: i32 = @intCast(nsaa_idx * 8);
                        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRSPDisp32(src, disp).slice());
                        nsaa_idx += 2;
                        fp_arg_slot += 1;
                    } else {
                        const dst = abi.current.arg_xmms[fp_arg_slot];
                        const src = try gpr.resolveXmm(alloc, src_vreg);
                        if (src != dst) {
                            try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, src).slice());
                        }
                        fp_arg_slot += 1;
                    }
                }
            },
        }
    }
}

/// Compute the [RSP + disp] offset for an overflowed arg per
/// the active Cc. SysV uses the NSAA counter; Win64 uses the
/// shared int/fp slot index post-shadow-space (slot 4 = first
/// overflow at [RSP + 32]). See rationale on
/// `marshalCallArgs`.
fn computeOverflowDisp(nsaa_idx: u32, shared_slot: usize) i32 {
    return switch (abi.current_cc) {
        .sysv => @intCast(nsaa_idx * 8),
        .win64 => @intCast(shared_slot * 8),
    };
}

/// Capture a call's return value into the next vreg per SysV
/// §3.2.1: i32 → EAX. Single-result MVP only — multi-value
/// returns (Wasm 2.0) land at sub-g3 follow-up. Void callees
/// push nothing.
pub fn captureCallResult(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    callee_sig: zir.FuncType,
    memory_class: bool,
    buffer_off: u32,
) Error!void {
    if (callee_sig.results.len == 0) return;

    // ADR-0026 2026-05-18 amend / ADR-0069 §Phase 2 chunk (b)-e-3:
    // MEMORY-class capture — callee wrote each result via the
    // caller-supplied R11 buffer pointer. Read each slot back
    // from `[RSP + buffer_off + i*8]` into the next result vreg
    // (direct MOV-to-home when in-pool; LDR-then-spill-store
    // via R10 stage when spilled). f32/f64/v128 deferred (no
    // spec fixture in 3-int-result cohort).
    if (memory_class) {
        var byte_off: u32 = 0;
        for (callee_sig.results) |result_kind| {
            const result = next_vreg.*;
            next_vreg.* += 1;
            if (result >= alloc.slots.len) return Error.AllocationMissing;
            const abs_off: i32 = @intCast(buffer_off + byte_off);
            switch (result_kind) {
                .i32 => {
                    const dst = try gpr.gprDefSpilled(alloc, result, 0);
                    try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(dst, .rsp, abs_off).slice());
                    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result, 0);
                },
                .i64, .ref => {
                    const dst = try gpr.gprDefSpilled(alloc, result, 0);
                    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(dst, .rsp, abs_off).slice());
                    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result, 0);
                },
                .f32 => {
                    // Mirror of callee's MOVD R10D, xmm; MOV [RAX+disp], R10D
                    // chain but in reverse direction: load 4 B → R10D → MOVD
                    // xmm. The `encMovssMovsdXmmMemBaseDisp32` helper would
                    // be shorter (1 insn) but ASSERTs against RSP base (SIB
                    // escape unsupported); the 2-insn GPR-via path
                    // sidesteps that limitation cleanly. R10 = spill_stage
                    // [0]; safe because xmmDefSpilled below uses
                    // XMM14/XMM15 (fp_spill_stage), disjoint cohorts.
                    try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(.r10, .rsp, abs_off).slice());
                    const dst = try gpr.xmmDefSpilled(alloc, result, 0);
                    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst, .r10).slice());
                    try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result, 0);
                },
                .f64 => {
                    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r10, .rsp, abs_off).slice());
                    const dst = try gpr.xmmDefSpilled(alloc, result, 0);
                    try buf.appendSlice(allocator, inst.encMovqXmmFromR64(dst, .r10).slice());
                    try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result, 0);
                },
                .v128 => return Error.UnsupportedOp,
            }
            byte_off += 8;
            try pushed_vregs.append(allocator, result);
        }
        return;
    }

    // D-093 (d-11) — multi-result capture. SysV §3.2.3: GPR results
    // in RAX, RDX (≤2); FP / SIMD results in XMM0, XMM1 (≤2).
    // D-165 close 2026-05-23: Win64 cap bumped 1→2 (mirror of R2
    // `marshalReturnRegs` cap fix `aac986d9`). Body writes both
    // results to RAX+RDX (R2); caller MUST capture both, or the
    // second result becomes garbage and downstream uses see
    // corrupt values (the actual D-165 fac-ssa hang root cause —
    // pick0 is 2-i64-result register-class; truncating cap=1
    // dropped its second result, fac-ssa's loop state corrupts).
    const gpr_result_regs = [_]abi.Gpr{ .rax, .rdx };
    const xmm_result_regs = [_]abi.Xmm{ .xmm0, .xmm1 };
    const gpr_cap: u8 = 2;
    const xmm_cap: u8 = 2;

    // D-093 (d-12) — cap-exceed silent-truncate (workaround per
    // D-094 debt row). Mirrors marshalReturnRegs's cap handling.
    // Overflow results get fresh vregs (preserving stack shape)
    // but the MOV-from-result-reg is skipped — the slot holds
    // whatever garbage was there pre-call. Only affects funcs
    // with >2 GPR or >2 XMM results, which are excluded from
    // run-time observation via the runner's skip-impl filter.

    var gpr_used: u8 = 0;
    var xmm_used: u8 = 0;
    for (callee_sig.results) |result_kind| {
        const result = next_vreg.*;
        next_vreg.* += 1;
        if (result >= alloc.slots.len) return Error.AllocationMissing;

        switch (result_kind) {
            .i32 => {
                if (gpr_used >= gpr_cap) {
                    gpr_used += 1;
                } else {
                    const src = gpr_result_regs[gpr_used];
                    gpr_used += 1;
                    const dst = try gpr.gprDefSpilled(alloc, result, 0);
                    if (dst != src) {
                        try buf.appendSlice(allocator, inst.encMovRR(.d, dst, src).slice());
                    }
                    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result, 0);
                }
            },
            .i64, .ref => {
                if (gpr_used >= gpr_cap) {
                    gpr_used += 1;
                } else {
                    const src = gpr_result_regs[gpr_used];
                    gpr_used += 1;
                    const dst = try gpr.gprDefSpilled(alloc, result, 0);
                    if (dst != src) {
                        try buf.appendSlice(allocator, inst.encMovRR(.q, dst, src).slice());
                    }
                    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result, 0);
                }
            },
            .f32, .f64 => {
                if (xmm_used >= xmm_cap) {
                    xmm_used += 1;
                } else {
                    const src = xmm_result_regs[xmm_used];
                    xmm_used += 1;
                    const dst = try gpr.xmmDefSpilled(alloc, result, 0);
                    if (dst != src) {
                        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, src).slice());
                    }
                    try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result, 0);
                }
            },
            .v128 => {
                if (xmm_used >= xmm_cap) {
                    xmm_used += 1;
                } else {
                    const src = xmm_result_regs[xmm_used];
                    xmm_used += 1;
                    const dst = try gpr.resolveXmm(alloc, result);
                    if (dst != src) {
                        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, src).slice());
                    }
                }
            },
        }
        try pushed_vregs.append(allocator, result);
    }
}

/// `(ctx, ins)` adapter for
/// `memory.grow`. Threads `ctx.outgoing_max_bytes` into the
/// existing `emitMemoryGrow` helper (host-import call with
/// shadow-space alloc).
///
/// Wasm spec §4.4.7 (memory.grow).
pub fn emitMemoryGrowCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitMemoryGrow(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ctx.outgoing_max_bytes,
        ctx.memory0_idx_type == .i64,
    );
}

/// `(ctx, ins)` adapter for
/// `memory.size`. Loads mem_limit from R15+off and shifts right
/// 16 to produce 64-KiB page count. Extracted from emit.zig's
/// prior inline body.
///
/// Wasm spec §4.4.7 (memory.size).
pub fn emitMemorySizeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    const result_v = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_v >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const dst_r = try gpr.gprDefSpilled(ctx.alloc, result_v, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(dst_r, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
    // Custom-page-sizes (ADR-0168 v0.2): pages = mem_limit >> page_size_log2
    // (default 16). Variable shift via CL (RCX is non-allocatable, so this
    // scratch use is safe); a 1-byte page → shift 0 → byte count.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR32FromMemDisp32(.rcx, abi.runtime_ptr_save_gpr, @intCast(jit_abi.mem0_page_size_log2_off)).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encShiftRCl(.q, .shr, dst_r).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_v, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_v);
}
