// FILE-SIZE-EXEMPT: ARM64 emit driver (prologue + epilogue + dispatch); P1 AAPCS64 spec-defined emit boundary; per-op handlers already extracted to op_*.zig sibling files (per ADR-0099)
//! ZIR → ARM64 emit pass (skeleton).
//!
//! Walks a `ZirFunc.instrs` stream (consumed in def_pc order)
//! and emits a fixed-width AArch64 instruction stream into a
//! caller-supplied byte buffer. Slot ids from the
//! regalloc map to physical X-registers via
//! `abi.slotToReg`.
//!
//! Skeleton scope:
//! - Function prologue: save FP/LR, set up frame pointer.
//! - Function epilogue: restore FP/LR, RET.
//! - `i32.const` → `MOVZ Xd, #imm16` (lower 16 bits) +
//!   optional `MOVK` lanes for the upper 16 bits. Emits to a
//!   single result register dictated by the function's return
//!   slot.
//! - `end` of function → epilogue.
//!
//! AAPCS64 prologue / epilogue shape (per Arm IHI 0055 §6.4):
//!
//!   prologue:
//!     STP FP, LR, [SP, #-16]!     // push FP/LR pair
//!     MOV FP, SP                   // set frame pointer
//!     [optional: SUB SP, SP, #N for locals]
//!
//!   epilogue:
//!     [optional: ADD SP, SP, #N]
//!     LDP FP, LR, [SP], #16        // pop FP/LR pair
//!     RET
//!
//! The skeleton omits the optional stack-frame
//! adjustment (no spilled vregs in straight-line MVP code with
//! ≤17 GPRs available; spills are a follow-up).
//!
//! Zone 2 (`src/jit_arm64/`) — must NOT import `src/jit_x86/`
//! per ROADMAP §A3.

const std = @import("std");
const liveness_parity = @import("../shared/liveness_parity.zig");
const dbg = @import("../../../support/dbg.zig");
const builtin = @import("builtin");

const zir = @import("../../../ir/zir.zig");
const sections = @import("../../../parse/sections.zig");
const local_homing = @import("../../../ir/analysis/local_homing.zig");
const dispatch_collector = @import("../dispatch_collector.zig");
const inst = @import("inst.zig");
const inst_fp = @import("inst_fp.zig");
const inst_neon = @import("inst_neon.zig");
const abi = @import("abi.zig");
const label_mod = @import("label.zig");
const regalloc = @import("../shared/regalloc.zig");

// Setup-phase helpers extracted to `emit_setup.zig` per ADR-0085.
// Aliases keep `compile()` call sites unchanged (mirror of
// ADR-0081 / x86_64/emit_setup.zig pattern).
const setup = @import("emit_setup.zig");
const computeOutgoingMaxBytes = setup.computeOutgoingMaxBytes;
const computeLocalLayout = setup.computeLocalLayout;
const LocalLayout = setup.LocalLayout;
const jit_abi = @import("../shared/jit_abi.zig");
const exception_table = @import("../shared/exception_table.zig");
const trap_registry = @import("../../../platform/trap_registry.zig"); // ADR-0202 D3
const build_options = @import("build_options");

/// EH / tail-call / func-references ops (Wasm 3.0) are dispatched manually here
/// (not via dispatch_collector, which is build-level-DCE'd) because arm64 EmitCtx
/// lacks the `dead_code: *bool` ctx field. Gating each manual arm behind this
/// comptime const keeps the 3.0 `*.emit` symbols out of `-Dwasm=v1_0|v2_0`
/// binaries (ADR-0073 "absent from binary"; ADR-0130 / D-230 leak fix). The arms
/// are unreachable in sub-3.0 builds anyway (feature_level_check forbids lowering).
const wasm_v3_plus = @intFromEnum(build_options.wasm_level) >=
    @intFromEnum(@TypeOf(build_options.wasm_level).v3_0);

const op_throw = @import("ops/wasm_3_0/throw.zig");
const op_throw_ref = @import("ops/wasm_3_0/throw_ref.zig");
const op_return_call = @import("ops/wasm_3_0/return_call.zig");
const op_return_call_indirect = @import("ops/wasm_3_0/return_call_indirect.zig");
const op_return_call_ref = @import("ops/wasm_3_0/return_call_ref.zig");
// D-239 — function-references null-ref branch ops (handler files existed
// but were never wired into the dispatch → UnsupportedOp).
const op_br_on_null = @import("ops/wasm_3_0/br_on_null.zig");
const op_br_on_non_null = @import("ops/wasm_3_0/br_on_non_null.zig");
const op_ref_as_non_null = @import("ops/wasm_3_0/ref_as_non_null.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const op_const = @import("op_const.zig");
const op_memory = @import("op_memory.zig");
const op_alu_int = @import("op_alu_int.zig");
const op_control = @import("op_control.zig");
const op_call = @import("op_call.zig");
const op_simd = @import("op_simd.zig");
const op_simd_int_arith = @import("op_simd_int_arith.zig");
const op_simd_int_cmp_lane = @import("op_simd_int_cmp_lane.zig");
const op_simd_float = @import("op_simd_float.zig");

const Label = label_mod.Label;
const LabelKind = label_mod.LabelKind;
const Fixup = label_mod.Fixup;
const FixupKind = label_mod.FixupKind;

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;
const Xn = inst.Xn;
const EmitCtx = ctx_mod.EmitCtx;

/// Re-export from `ctx.zig`. The error set lives there so
/// op-handler modules can import it without reaching back to
/// emit.zig.
pub const Error = ctx_mod.Error;

/// Re-export from `ctx.zig`. See `ctx.CallFixup`.
pub const CallFixup = ctx_mod.CallFixup;

pub const EmitOutput = struct {
    /// Encoded function body bytes (little-endian u32 stream).
    /// Caller owns; pair with `deinit` to free.
    bytes: []u8,
    /// Distinct GPR slots used (mirrors `Allocation.n_slots`).
    /// Consulted for stack-frame sizing when the spill follow-up
    /// lands.
    n_slots: u16,
    /// `BL` fixup sites. Each is a placeholder that the caller
    /// patches once function-body addresses are known.
    /// Caller-owned; pair with `deinit` to free.
    call_fixups: []CallFixup,
    /// Per-function EH HandlerEntry slice harvested from the
    /// `ExceptionTable.Builder` at compile end. A later pass folds the
    /// per-function slices into the per-Instance ExceptionTable on
    /// CompiledWasm. Empty for functions without try_table.
    exception_handlers: []const exception_table.HandlerEntry = &.{},
    /// Per-function aligned frame size in
    /// bytes (= prologue's `SUB SP, SP, #N` value). Consumed by
    /// the linker to populate `CodeMap.Entry.frame_bytes`; the EH
    /// SP-restore path uses it to recover the handler frame's
    /// post-prologue SP boundary after `MOV SP, X29`.
    frame_bytes: u32 = 0,
    /// ADR-0202 D3 — byte offset (from body start) of this function's
    /// kind=6 oob trap stub, the guard-fault PC-redirect target. The
    /// linker adds the function's absolute base to build the trap
    /// registry's FuncEntry. `FuncEntry.no_stub` when the function has
    /// no bounds-checked memory access (a fault there is unclassified).
    oob_stub_off: u32 = trap_registry.FuncEntry.no_stub,
};

pub fn deinit(allocator: Allocator, out: EmitOutput) void {
    if (out.bytes.len != 0) allocator.free(out.bytes);
    if (out.call_fixups.len != 0) allocator.free(out.call_fixups);
    if (out.exception_handlers.len != 0) allocator.free(out.exception_handlers);
}

/// Emit ARM64 machine code for `func`. Requires `alloc.slots`
/// to be populated (call `regalloc.compute` first; pass the
/// `Allocation` here).
///
/// `func_sigs[k]` is the FuncType of function index `k`; consulted
/// by the `call N` handler to pick the result register class
/// (W0/X0/S0/D0). `module_types[t]` is the FuncType for type
/// index `t`; consulted by `call_indirect type_idx`. Both default
/// to empty slices for tests that don't exercise calls — the call
/// handlers fail with `AllocationMissing` if the index is out of
/// range, so callers must size the tables to the called indices.
pub fn compile(
    allocator: Allocator,
    func: *const ZirFunc,
    alloc: regalloc.Allocation,
    func_sigs: []const zir.FuncType,
    module_types: []const zir.FuncType,
    num_imports: u32,
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
    memory0_idx_type: sections.MemoryEntry.IdxType,
    /// Wasm 3.0 EH (ADR-0120) — per-tag
    /// param counts threaded into EmitCtx for throw / try_table
    /// payload marshalling. Pass `&.{}` for modules without tags.
    tag_param_counts: []const u32,
    /// D-235 — module-level func-subtyping flag (`usesTypeSubtyping`).
    /// Routes `call_indirect` through the subtype trampoline. `false` for
    /// non-subtyping modules + test helpers.
    uses_type_subtyping: bool,
    /// ADR-0202 D4 — drop the inline bounds check for memory0
    /// scalar/atomic/SIMD accesses (guard-page + fault→trap redirect
    /// own oob detection) and force-emit the kind=6 stub. `false` for
    /// non-qualifying modules, the `.explicit` knob, and test helpers.
    bounds_elided: bool,
) Error!EmitOutput {
    if (alloc.slots.len != (func.liveness orelse return Error.AllocationMissing).ranges.len) {
        return Error.AllocationMissing;
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // ============================================================
    // Prologue: STP FP, LR, [SP, #-16]! ; MOV FP, SP ; SUB SP, SP, #frame
    //
    // Locals layout (per ZirFunc.locals; params unsupported in this
    // skeleton — see scope note below): each i32 local occupies an
    // 8-byte slot at [SP, #(K*8)] for stable 8-byte alignment +
    // simple imm12 LDR/STR W addressing. Frame size rounds up to
    // 16 bytes per AAPCS64 §6.4 (SP must stay 16-byte aligned).
    // ============================================================
    // Multi-arg entry:
    // - AAPCS64 §6.4: int args in X0..X7; FP args in V0..V7.
    //   X0 is `*const JitRuntime` (ADR-0017), so user int args
    //   start at X1 (max 7). FP args have their own sequence
    //   starting at V0 (max 8). Mixed-type signatures interleave
    //   per declaration order but each type class indexes its own
    //   arg-reg counter.
    // - Per-class stores: i32 → STR W, i64 → STR X, f32 → STR S,
    //   f64 → STR D. v128 / refs still surface as UnsupportedOp.
    // - AAPCS64 §6.4.2 stack-arg lowering: when
    //   a class would overflow (int > X7 or fp > V7), the arg
    //   (and every subsequent arg of the SAME class) lands on
    //   the caller's stack at `[X29, #16 + 8*stack_arg_idx]`
    //   (the +16 skips the saved FP/LR pair pushed by the
    //   `STP X29,X30,[SP,#-16]!` prologue). Per AAPCS64 each
    //   class tracks its own overflow point independently;
    //   they share one NSAA stream. Loaded into X16 (GPR
    //   scratch) / V16 (FP scratch) and re-stored to the
    //   local-slot at `[SP, p_idx*8]`.
    for (func.sig.params) |p| {
        switch (p) {
            // D-093: reftype params share the i64 gpr-class
            // 8-byte slot per ADR-0061. i31ref
            // also lands in this class (Value.anyref u32 GcRef,
            // low-bit-tagged per ADR-0116; gpr-class slot suffices).
            .i32, .i64, .f32, .f64, .v128, .ref => {},
        }
    }
    const num_params: u32 = @intCast(func.sig.params.len);
    const num_locals: u32 = func.totalLocalCount();
    // Wasm local-index space: 0..num_params-1 = params,
    // num_params..num_params+num_locals-1 = declared locals.
    // Per-local frame layout split by type
    // (scalars 8-byte stride, v128 16-byte stride). See
    // `computeLocalLayout` doc for the strategy.
    const total_locals: u32 = num_params + num_locals;
    var layout = try computeLocalLayout(allocator, func);
    defer layout.deinit(allocator);
    const locals_bytes: u32 = layout.total_bytes;
    // ADR-0155 stage 1 — register-homed locals. liveness APPENDED `homing.count`
    // function-spanning pseudo-vregs (the highest vreg ids); their numbering is
    // `n_temp + rank` where `n_temp` = temporary-vreg count = slots.len - count.
    // A homed `local.get` reads the home register into a fresh temporary (MOV,
    // not LDR-from-slot); a homed `local.set`/`tee` MOVs a temporary into the
    // home register. The value crosses the loop back-edge in-register (D-265
    // win). `local.get`/`local.set` still mint/consume temporary vregs exactly
    // as the un-homed path, so emit's `next_vreg` stays in lockstep with
    // liveness (the spike's numbering-divergence bug is avoided by fix A).
    const homing = local_homing.plan(func);
    const n_temp: u32 = @intCast(alloc.slots.len - homing.count);
    // ADR-0018: extend frame by spill region. Layout:
    //   [SP + 0 .. locals_bytes-1]                   locals
    //   [SP + locals_bytes .. +spill_bytes-1]        spills
    // `spill_base_off` is the absolute SP-relative offset where
    // spill slot 0 lives; `gprLoadSpilled`/`gprStoreSpilled`
    // consume it via byte_offset = spill_base_off + slot.spill.
    const spill_bytes: u32 = alloc.spillBytes();
    // ADR-0017 2026-05-18 amend / ADR-0069 §Phase 2 chunk (b)-e-1:
    // when this function's return tuple is MEMORY-class per AAPCS64
    // §6.8.2 (v2 trigger = `sig.results.len > 2`), caller passes the
    // hidden indirect-result-pointer in X8 at entry. Prologue
    // captures X8 to an 8 B slot above the spill region; epilogue
    // (`marshalFunctionReturn`) loads it into X16 and writes each
    // result to `[X16, #(i*8)]` (X16 chosen over X14 to dodge the
    // `gprLoadSpilled` spill-stage clobber).
    const return_is_memory_class: bool = func.sig.results.len > 2;
    // ADR-0106 path (a) — buffer-write ABI also needs a
    // captured-pointer slot (for the results ptr passed in X1 per
    // AAPCS64). Shares the same slot the MEMORY-class path uses
    // for the hidden X8 indirect-result ptr.
    const buffer_write: bool = alloc.result_abi == .buffer_write;
    const indirect_result_slot_bytes: u32 = if (return_is_memory_class or buffer_write) 8 else 0;
    // Outgoing args (caller-side stack args)
    // occupy the BOTTOM of the frame so the callee reads them at
    // `[X29, #16 + 8*K]` (per AAPCS64 §6.4.2 stage C.13/C.14).
    // Locals + spills shift upward by `local_base_off`.
    //   [SP + 0 .. outgoing_max-1]                     outgoing args
    //   [SP + outgoing_max .. +locals_bytes-1]         locals
    //   [SP + outgoing_max + locals_bytes .. +spill]   spills
    //
    // When v128 locals are present, round the locals-
    // zone base up to 16 so `local_base_off + layout.offsets[v128
    // _idx]` is 16-aligned (`encStrQImm` / `encLdrQImm` reject
    // misaligned imm12). The 0-7 byte rounding waste is bounded
    // and amortised against the v128-bearing path.
    const outgoing_max_raw: u32 = computeOutgoingMaxBytes(func, func_sigs, module_types);
    const outgoing_max_bytes: u32 = if (layout.v128_count > 0) (outgoing_max_raw + 15) & ~@as(u32, 15) else outgoing_max_raw;
    const local_base_off: u32 = outgoing_max_bytes;
    const spill_base_off: u32 = local_base_off + locals_bytes;
    const frame_bytes_unaligned: u32 = outgoing_max_bytes + locals_bytes + spill_bytes + indirect_result_slot_bytes;
    const frame_bytes: u32 = (frame_bytes_unaligned + 15) & ~@as(u32, 15);
    // ADR-0202 D3 — byte offset of this function's oob (kind=6) trap stub,
    // the PC-redirect target for guard faults. Set below when the stub is
    // emitted; stays no_stub for functions with no bounds-checked access.
    var oob_stub_off: u32 = trap_registry.FuncEntry.no_stub;
    // SP-relative offset of the captured X8 slot (top of locals +
    // spill region, just below the 16-byte alignment pad).
    const indirect_result_slot_off: u32 = spill_base_off + spill_bytes;
    try gpr.writeU32(allocator, &buf, encStpFpLrPreIdx());
    try gpr.writeU32(allocator, &buf, encMovSpToFp());
    // ADR-0017 prologue: 5 LDRs from X0 = `*const JitRuntime`
    // into the reserved invariant regs. Per ROADMAP §2 P3 (cold-
    // start over peak throughput), 5 cycles uncached overhead is
    // acceptable for the baseline; a later optimisation may
    // elide loads when the function provably doesn't use the
    // corresponding invariant.
    try gpr.writeU32(allocator, &buf, inst.encLdrImm(28, 0, jit_abi.vm_base_off));
    try gpr.writeU32(allocator, &buf, inst.encLdrImm(27, 0, jit_abi.mem_limit_off));
    try gpr.writeU32(allocator, &buf, inst.encLdrImm(26, 0, jit_abi.funcptr_base_off));
    try gpr.writeU32(allocator, &buf, inst.encLdrImm(25, 0, jit_abi.table_size_off));
    try gpr.writeU32(allocator, &buf, inst.encLdrImm(24, 0, jit_abi.typeidx_base_off));
    // ADR-0027 prescan: load X23 ← globals_base only when this
    // function actually consults a global. Functions without
    // global ops keep the pre-ADR-0027 prologue shape (zero
    // churn for existing tests).
    const uses_globals = blk: {
        for (func.instrs.items) |ins| {
            switch (ins.op) {
                .@"global.get", .@"global.set" => break :blk true,
                else => {},
            }
        }
        break :blk false;
    };
    if (uses_globals) {
        try gpr.writeU32(allocator, &buf, inst.encLdrImm(abi.globals_base_save_gpr, 0, jit_abi.globals_base_off));
    }
    // ADR-0017 sub-2d-ii: save runtime ptr to X19 so multi-call
    // functions can restore X0 before each BL/BLR. X19 is callee-
    // saved per AAPCS64 — preserved across calls without explicit
    // save/restore.
    try gpr.writeU32(allocator, &buf, inst.encOrrReg(abi.runtime_ptr_save_gpr, 31, 0));
    // ADR-0105 D2 — JIT-prologue stack-probe. Insert BEFORE the
    // sentinel write so a probe-trap doesn't pollute the
    // jit_executed_flag (the function didn't actually run if it
    // trapped at entry). Layout: LDR X16 ← stack_limit; MOV X17 ←
    // SP (= ADD X17, SP, #0; rn=31 in ADD-imm means SP not XZR);
    // CMP X17, X16; B.LS placeholder. When stack_limit = 0
    // (probe disabled), CMP SP,0 is always > so B.LS never fires
    // — graceful no-op for tests / non-init paths. The B.LS
    // placeholder records its byte offset for end-of-function
    // patching against the stack-overflow trap stub.
    try gpr.writeU32(allocator, &buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.stack_limit_off));
    try gpr.writeU32(allocator, &buf, inst.encAddImm12(17, 31, 0));
    try gpr.writeU32(allocator, &buf, inst.encCmpRegX(17, 16));
    const stack_probe_fixup: u32 = @intCast(buf.items.len);
    try gpr.writeU32(allocator, &buf, inst.encBCond(.ls, 0));
    // ADR-0179 #3a / D-314 — cooperative-interruption poll. Same pre-frame
    // position as the stack probe (stub fb=0). `LDR X16 ← interrupt_ptr;
    // CBZ X16, skip` (null = not configured → no per-call cost beyond the
    // load+not-taken branch); `LDR W17 ← [X16]; CMP W17, WZR; B.NE` → the
    // interrupted stub. CMP+B.NE (not CBNZ) so EmitCindStub's B.cond patcher
    // re-targets the fixup correctly. X16/X17 = IP0/IP1 caller-saved scratch
    // (body not started). Skip disp = 4 words (over LDR/CMP/B.NE).
    try gpr.writeU32(allocator, &buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.interrupt_ptr_off));
    try gpr.writeU32(allocator, &buf, inst.encCbz(16, 4));
    try gpr.writeU32(allocator, &buf, inst.encLdrImmW(17, 16, 0));
    try gpr.writeU32(allocator, &buf, inst.encCmpRegW(17, 31));
    const interrupt_probe_fixup: u32 = @intCast(buf.items.len);
    try gpr.writeU32(allocator, &buf, inst.encBCond(.ne, 0));
    // ADR-0179 #3b / D-314 — fuel poll (prologue crossing). `LDR W16 ←
    // fuel_metered; CBZ W16, skip (unmetered → load + not-taken branch only);
    // LDR X17 ← fuel_cell; SUB X17, #1; STR X17 → fuel_cell; CMP X17, XZR;
    // B.MI` → the out-of-fuel stub (code 17, fb=0 pre-frame). Plain SUB (not
    // SUBS) + CMP so the patcher sees the canonical CMP+B.cond pair. Skip
    // disp = 6 words (over LDR/SUB/STR/CMP/B.MI).
    try gpr.writeU32(allocator, &buf, inst.encLdrImmW(16, abi.runtime_ptr_save_gpr, jit_abi.fuel_metered_off));
    try gpr.writeU32(allocator, &buf, inst.encCbzW(16, 6));
    try gpr.writeU32(allocator, &buf, inst.encLdrImm(17, abi.runtime_ptr_save_gpr, jit_abi.fuel_cell_off));
    try gpr.writeU32(allocator, &buf, inst.encSubImm12(17, 17, 1));
    try gpr.writeU32(allocator, &buf, inst.encStrImm(17, abi.runtime_ptr_save_gpr, jit_abi.fuel_cell_off));
    try gpr.writeU32(allocator, &buf, inst.encCmpRegX(17, 31));
    const fuel_probe_fixup: u32 = @intCast(buf.items.len);
    try gpr.writeU32(allocator, &buf, inst.encBCond(.mi, 0));
    // JIT-execution sentinel (ADR-0034): write 1 to
    // `JitRuntime.jit_executed_flag` so post-call readers can
    // distinguish "JIT body actually ran" from "compile-passed but
    // never invoked". MOVZ X17, #1 (W17 = 1) + STR W17, [X19,
    // #flag_off]. X17 = IP1 (Arm IHI 0055 §6.4 caller-saved scratch);
    // safe to clobber since the body has not started yet. 8 bytes /
    // 2 insns; runs unconditionally per ROADMAP §A12 (no build-flag
    // gate; cost amortised below bench noise).
    try gpr.writeU32(allocator, &buf, inst.encMovzImm16(17, 1));
    try gpr.writeU32(allocator, &buf, inst.encStrImmW(17, abi.runtime_ptr_save_gpr, jit_abi.jit_executed_flag_off));
    if (frame_bytes > 0) {
        // Chunk d-9: support frame_bytes up to 16 MiB-1 via the
        // two-step `SUB SP, SP, #(N>>12), lsl #12; SUB SP, SP,
        // #(N&0xFFF)` sequence. Larger needs a MOVZ/MOVK chain
        // (post-MVP). Long Go binaries with deep spill regions
        // exceed the prior 4096 cap.
        if (frame_bytes > 0xFFFFFF) {
            dbg.print("codegen", "arm64/emit: SlotOverflow frame_bytes={d} func[{d}]\n", .{ frame_bytes, func.func_idx });
            return Error.SlotOverflow;
        }
        const fb_high: u12 = @intCast((frame_bytes >> 12) & 0xFFF);
        const fb_low: u12 = @intCast(frame_bytes & 0xFFF);
        if (fb_high != 0) try gpr.writeU32(allocator, &buf, inst.encSubImm12Lsl12(31, 31, fb_high));
        if (fb_low != 0) try gpr.writeU32(allocator, &buf, inst.encSubImm12(31, 31, fb_low));
    }
    // ADR-0017 2026-05-18 amend / ADR-0069 §Phase 2 chunk (b)-e-1:
    // capture the caller-supplied hidden indirect-result-pointer
    // (X8) into the frame slot above the spill region. Emitted
    // AFTER frame-SUB (so SP sits at the function's stack bottom)
    // and BEFORE param shuffle (which uses X1..X7 + V0..V7 only —
    // X8 is safe until captured). The epilogue reads it back at
    // `marshalFunctionReturn`'s MEMORY-class branch.
    // ADR-0106 path (a) — buffer_write takes precedence
    // over the MEMORY-class case. When `sig.results.len > 2`
    // AND buffer_write, both flags fire; we want X1 (results
    // ptr) in the slot, not X8 (MEMORY-class hidden ptr).
    if (buffer_write) {
        try gpr.writeU32(allocator, &buf, inst.encStrImm(1, 31, @intCast(indirect_result_slot_off)));
    } else if (return_is_memory_class) {
        try gpr.writeU32(allocator, &buf, inst.encStrImm(8, 31, @intCast(indirect_result_slot_off)));
    }

    // Multi-arg entry: store params from X1..X{num_params} into
    // their stack slots [SP + 0], [SP + 8], … so subsequent
    // `local.get N` (N < num_params) reads from the same slot
    // shape as declared locals. Per AAPCS64 §6.4: i32 args are
    // passed with the upper 32 bits of the X register undefined,
    // so STR W (32-bit) is mandatory for .i32 to avoid storing
    // caller garbage in the high half. i64 args use STR X
    // (full 64-bit). AAPCS64 X0 = `*const JitRuntime` (already
    // snapshotted to X19 above), X1 = param 0, etc.
    var p_idx: u32 = 0;
    // ADR-0106 path (a) — buffer_write ABI: args come
    // from `[X2 + i*8]` (args_ptr is the 3rd AAPCS64 arg after
    // rt=X0, results=X1, args=X2). Skip the per-class arg-reg
    // shuffle entirely. v128 deferred (a u64
    // slot can't hold a 128-bit value).
    if (buffer_write) {
        while (p_idx < num_params) : (p_idx += 1) {
            const param_off_u: u32 = local_base_off + layout.offsets[p_idx];
            const param_ty = func.sig.params[p_idx];
            if (param_ty == .v128) return Error.UnsupportedOp;
            if (param_off_u > 32760) return Error.UnsupportedOp;
            // LDR X16, [X2, #(p_idx*8)]
            const args_off_u: u32 = @intCast(p_idx * 8);
            if (args_off_u > 32760) return Error.UnsupportedOp;
            try gpr.writeU32(allocator, &buf, inst.encLdrImm(16, 2, @intCast(args_off_u)));
            // Store per type: i32/f32 use STR W (low 32 bits); i64/f64/refs use STR X.
            switch (param_ty) {
                .i32, .f32 => try gpr.writeU32(allocator, &buf, inst.encStrImmW(16, 31, @intCast(param_off_u))),
                // i31ref shares the 8-byte
                // gpr-class slot with other reftypes (per ADR-0116
                // low-bit-tagged u32 GcRef).
                .i64, .f64, .ref => try gpr.writeU32(allocator, &buf, inst.encStrImm(16, 31, @intCast(param_off_u))),
                .v128 => unreachable, // guarded above.
            }
        }
        // Fall through — the existing per-class while loop below
        // checks `p_idx < num_params` and exits immediately since
        // p_idx now equals num_params.
    }
    var int_arg_idx: u5 = 1; // X0 = runtime ptr; user int args from X1
    var fp_arg_idx: u5 = 0; // V0..V7 for FP args
    // Overflow-args byte cursor in the caller's outgoing-args
    // region; reads at `[X29, #(16 + stack_byte_off)]` with +16
    // skipping the saved FP/LR pair pushed by the prologue's
    // pre-index STP.
    //
    // Standard AAPCS64 (Arm IHI 0055 §6.4.2 stage C.13/C.14):
    // every scalar overflow consumes 8 bytes regardless of width.
    //
    // **Apple arm64 (macOS / iOS / watchOS / tvOS)**: per Apple's
    // "Writing ARM64 Code for Apple Platforms" — stack overflow
    // args use their NATURAL size with natural alignment, NOT a
    // uniform 8-byte stride. Consecutive i32 + f32 thus pack into
    // 4+4 bytes, not 8+8. The `apple_natural_packing` flag picks
    // the appropriate cursor advance.
    const apple_natural_packing: bool = builtin.target.os.tag == .macos or
        builtin.target.os.tag == .ios or
        builtin.target.os.tag == .watchos or
        builtin.target.os.tag == .tvos;
    var stack_byte_off: u32 = 0;
    while (p_idx < num_params) : (p_idx += 1) {
        // Param slot lives at
        // `[SP, #(local_base_off + layout.offsets[p_idx])]`. The
        // local region sits above the outgoing-args region.
        // Per-type encoding caps:
        //   STR W (.i32 / .f32): byte_offset ≤ 16380 (imm12*4)
        //   STR X (.i64 / .f64): byte_offset ≤ 32760 (imm12*8)
        //   STR Q (.v128): byte_offset ≤ 65520 (imm12*16) +
        //   16-byte alignment (`local_base_off` rounded above).
        const param_off_u: u32 = local_base_off + layout.offsets[p_idx];
        const param_ty = func.sig.params[p_idx];
        const cap: u32 = switch (param_ty) {
            .i32, .f32 => 16380,
            // i31ref shares the 8-byte STR X slot.
            .i64, .f64, .ref => 32760,
            .v128 => 65520,
        };
        if (param_off_u > cap) return Error.UnsupportedOp;
        const param_off_w: u14 = if (param_ty == .i32 or param_ty == .f32) @intCast(param_off_u) else 0;
        const param_off_x: u15 = if (param_ty == .i64 or param_ty == .f64 or param_ty == .ref) @intCast(param_off_u) else 0;
        const param_off_v128: u16 = if (param_ty == .v128) @intCast(param_off_u) else 0;
        switch (param_ty) {
            .i32 => {
                if (int_arg_idx > 7) {
                    const slot_size: u32 = if (apple_natural_packing) 4 else 8;
                    const align_mask: u32 = slot_size - 1;
                    stack_byte_off = (stack_byte_off + align_mask) & ~align_mask;
                    const stack_off_u: u32 = 16 + stack_byte_off;
                    if (stack_off_u > 32760) return Error.UnsupportedOp;
                    const stack_off_w: u14 = @intCast(stack_off_u);
                    try gpr.writeU32(allocator, &buf, inst.encLdrImmW(16, 29, stack_off_w));
                    try gpr.writeU32(allocator, &buf, inst.encStrImmW(16, 31, param_off_w));
                    stack_byte_off += slot_size;
                } else {
                    try gpr.writeU32(allocator, &buf, inst.encStrImmW(int_arg_idx, 31, param_off_w));
                    int_arg_idx += 1;
                }
            },
            // D-093: reftype params share the i64 X-form
            // marshal path (8-byte gpr-class slot per ADR-0061).
            .i64, .ref => {
                if (int_arg_idx > 7) {
                    stack_byte_off = (stack_byte_off + 7) & ~@as(u32, 7);
                    const stack_off_u: u32 = 16 + stack_byte_off;
                    if (stack_off_u > 32760) return Error.UnsupportedOp;
                    const stack_off: u15 = @intCast(stack_off_u);
                    try gpr.writeU32(allocator, &buf, inst.encLdrImm(16, 29, stack_off));
                    try gpr.writeU32(allocator, &buf, inst.encStrImm(16, 31, param_off_x));
                    stack_byte_off += 8;
                } else {
                    try gpr.writeU32(allocator, &buf, inst.encStrImm(int_arg_idx, 31, param_off_x));
                    int_arg_idx += 1;
                }
            },
            .f32 => {
                if (fp_arg_idx > 7) {
                    const slot_size: u32 = if (apple_natural_packing) 4 else 8;
                    const align_mask: u32 = slot_size - 1;
                    stack_byte_off = (stack_byte_off + align_mask) & ~align_mask;
                    const stack_off_u: u32 = 16 + stack_byte_off;
                    if (stack_off_u > 32760) return Error.UnsupportedOp;
                    const stack_off: u14 = @intCast(stack_off_u);
                    try gpr.writeU32(allocator, &buf, inst.encLdrSImm(16, 29, stack_off));
                    try gpr.writeU32(allocator, &buf, inst.encStrSImm(16, 31, param_off_w));
                    stack_byte_off += slot_size;
                } else {
                    try gpr.writeU32(allocator, &buf, inst.encStrSImm(fp_arg_idx, 31, param_off_w));
                    fp_arg_idx += 1;
                }
            },
            .f64 => {
                if (fp_arg_idx > 7) {
                    stack_byte_off = (stack_byte_off + 7) & ~@as(u32, 7);
                    const stack_off_u: u32 = 16 + stack_byte_off;
                    if (stack_off_u > 32760) return Error.UnsupportedOp;
                    const stack_off: u15 = @intCast(stack_off_u);
                    try gpr.writeU32(allocator, &buf, inst.encLdrDImm(16, 29, stack_off));
                    try gpr.writeU32(allocator, &buf, inst.encStrDImm(16, 31, param_off_x));
                    stack_byte_off += 8;
                } else {
                    try gpr.writeU32(allocator, &buf, inst.encStrDImm(fp_arg_idx, 31, param_off_x));
                    fp_arg_idx += 1;
                }
            },
            // v128 param marshal per AAPCS64
            // §6.4 SIMD calling convention. v128 args arrive in
            // V0..V7; stash via `STR Q V<n>, [SP, #param_off_v128]`.
            // Overflow path per §6.4.2 stage C.4: align next stack
            // arg to 16, then load 16 bytes.
            .v128 => {
                if (fp_arg_idx > 7) {
                    stack_byte_off = (stack_byte_off + 15) & ~@as(u32, 15);
                    const stack_off_u: u32 = 16 + stack_byte_off;
                    if (stack_off_u > 65520) return Error.UnsupportedOp;
                    const stack_off: u16 = @intCast(stack_off_u);
                    try gpr.writeU32(allocator, &buf, inst_neon.encLdrQImm(16, 29, stack_off));
                    try gpr.writeU32(allocator, &buf, inst_neon.encStrQImm(16, 31, param_off_v128));
                    stack_byte_off += 16;
                } else {
                    try gpr.writeU32(allocator, &buf, inst_neon.encStrQImm(fp_arg_idx, 31, param_off_v128));
                    fp_arg_idx += 1;
                }
            },
        }
    }

    // Zero-initialise declared locals (Wasm spec §4.5.3.1: locals
    // beyond params are initialised to zero on entry). Scalar
    // slots (8 bytes) get STR XZR; v128 slots (16 bytes) get two
    // STR XZR (no SIMD-zero-immediate encoder; ZR-pair is the
    // canonical zero pattern and is bench-cost identical to
    // `MOVI V31.16B, #0; STR Q V31`).
    var loc_idx: u32 = num_params;
    while (loc_idx < total_locals) : (loc_idx += 1) {
        const loc_off_u: u32 = local_base_off + layout.offsets[loc_idx];
        const ty = func.localValType(loc_idx);
        if (ty == .v128) {
            // D-289/D-331(B): v128 slot zero-init = two STR XZR (8B each). Both
            // large-offset-safe via X16 — `frameStrGpr` emits the identical
            // `encStrImm(31,31,off)` for off<=32760 and routes through the X16
            // scratch base past the imm cap, so a frame with enough v128 locals
            // (offset >32760) no longer returns UnsupportedOp. X16 is dead during
            // prologue zero-init (same scratch the scalar branch below uses).
            try gpr.frameStrGpr(allocator, &buf, 31, loc_off_u, false, 16);
            try gpr.frameStrGpr(allocator, &buf, 31, loc_off_u + 8, false, 16);
        } else {
            // D-289: scalar slot zero-init (STR XZR), large-off-safe via X16.
            try gpr.frameStrGpr(allocator, &buf, 31, loc_off_u, false, 16);
        }
    }

    // ADR-0155 stage 1 — prologue-load each register-homed local's initial
    // value from its stack slot into its pinned home register. The slot already
    // holds the correct initial value (param marshalled above, or zero-inited
    // for declared locals), so a single LDR seeds the register. From here the
    // slot is dormant; the register is the home (local.get/set are reg ops).
    // Width: i32 → LDR W (low 32, zero-extended), i64 → LDR X.
    if (homing.count > 0) {
        var hr: u32 = 0;
        while (hr < homing.count) : (hr += 1) {
            const lidx = homing.local_idx[hr];
            const home_vreg = n_temp + hr;
            const xd = try gpr.gprDefSpilled(alloc, home_vreg, 0);
            const off_u: u32 = local_base_off + layout.offsets[lidx];
            const ty = localValType(func, num_params, lidx);
            switch (ty) {
                // D-289: home-seed LDR, large-off-safe (self-computes into xd).
                .i32 => try gpr.frameLdrGpr(allocator, &buf, xd, off_u, true),
                .i64 => try gpr.frameLdrGpr(allocator, &buf, xd, off_u, false),
                // local_homing.isHomeableType only returns true for i32/i64.
                .f32, .f64, .v128, .ref => unreachable,
            }
        }
    }

    // ============================================================
    // Body: walk instrs, dispatch per op.
    //
    // Track a "result vreg" cursor that
    // records which vreg holds the latest pushed value. The
    // function's `end` reads that vreg, ensures it ends up in X0
    // (the AAPCS64 return register), and then runs the epilogue.
    // ============================================================
    var pushed_vregs: std.ArrayList(u32) = .empty;
    defer pushed_vregs.deinit(allocator);
    var next_vreg: u32 = 0;

    // ============================================================
    // Label stack — supports `block` / `loop` + `br N` / `br_if N`.
    //
    // Each entry tracks:
    //   kind      — .block (forward branches resolve at `end`) or
    //               .loop (backward branches resolve at the loop
    //               entry).
    //   target_byte_offset — for .loop, the byte offset of the
    //               loop entry. For .block, undefined until `end`
    //               lands; pending fixups are patched at that
    //               point.
    //   pending   — fixup records (byte_offset of branch + kind)
    //               needing patch when the label resolves.
    //
    // This lives in emit.zig (not as a separate type) because the
    // patching machinery is tightly coupled to the buf layout.
    // ============================================================
    var labels: std.ArrayList(Label) = .empty;
    defer {
        for (labels.items) |*l| l.pending.deinit(allocator);
        labels.deinit(allocator);
    }

    // ============================================================
    // Memory-bounds trap fixup list.
    //
    // Caller-supplied invariants for memory ops in this skeleton:
    //   X28 = vm_base    (memory_base pointer)
    //   X27 = mem_limit  (size in bytes)
    // The caller arranges these before invoking the JIT body.
    // A follow-up wires Runtime → these regs structurally
    // (D-014 `Runtime.io` injection point dissolves there).
    //
    // Each i32.load / i32.store / etc. emits:
    //   ORR W16, WZR, W_addr   ; zero-extend addr to X16
    //   ADD X16, X16, #imm     ; effective addr
    //   CMP X16, X27           ; bounds
    //   B.HS  trap_stub        ; branch on unsigned >= (placeholder + fixup)
    //   LDR/STR W_dest, [X28, X16]
    //
    // The B.HS fixup byte_offset is appended here. At function-final
    // `end`, after the regular epilogue+RET, a trap stub is emitted
    // and all bounds_fixups are patched to point at it.
    var bounds_fixups: std.ArrayList(u32) = .empty;
    defer bounds_fixups.deinit(allocator);

    // D-144 — dedicated fixup lists for
    // call_indirect bounds (B.HS) + sig (B.NE) checks. Routed to
    // their own trap stubs that write distinct `trap_kind` codes
    // (2 / 3) so a post-mortem `printCallTrap` can disambiguate
    // call_indirect trap source from memory bounds / unreachable.
    var cind_bounds_fixups: std.ArrayList(u32) = .empty;
    defer cind_bounds_fixups.deinit(allocator);
    var cind_sig_fixups: std.ArrayList(u32) = .empty;
    defer cind_sig_fixups.deinit(allocator);
    // D-294 — call_indirect null-element (uninitialized_elem, code 13); checked
    // before the sig CMP so a null slot reports code 13, not the sig code 3.
    var uninit_elem_fixups: std.ArrayList(u32) = .empty;
    defer uninit_elem_fixups.deinit(allocator);

    // ADR-0164 A / D-292 — dedicated fixup list for `unreachable`
    // (unconditional-B placeholder). Routed to its own trap stub
    // that writes the precise `trap_kind` code 5, so JIT/AOT reach
    // interp-parity instead of the arch-divergent generic bucket
    // (was arm64 1 / x86_64 0). `throw` keeps the generic stub.
    var unreach_fixups: std.ArrayList(u32) = .empty;
    defer unreach_fixups.deinit(allocator);

    // ADR-0164 A2 / D-292 — div-by-zero (code 7) + div_s overflow (code 8)
    // demuxed from bounds_fixups so each reaches a precise per-kind trap stub.
    var divzero_fixups: std.ArrayList(u32) = .empty;
    defer divzero_fixups.deinit(allocator);
    var overflow_fixups: std.ArrayList(u32) = .empty;
    defer overflow_fixups.deinit(allocator);
    // D-303 — atomic load/store unaligned-access (code 14 = unaligned_atomic).
    var unaligned_atomic_fixups: std.ArrayList(u32) = .empty;
    defer unaligned_atomic_fixups.deinit(allocator);
    // D-293 slice-3 — trapping-trunc NaN (code 9 = invalid_conversion) demuxed from bounds_fixups.
    var invalid_conv_fixups: std.ArrayList(u32) = .empty;
    defer invalid_conv_fixups.deinit(allocator);
    // D-293 slice-4b — call_ref-null + ref.as_non_null (code 10 = null_reference).
    var null_ref_fixups: std.ArrayList(u32) = .empty;
    defer null_ref_fixups.deinit(allocator);
    // D-293 slice-4d — ref.cast / ref.cast_null subtype mismatch (code 11 = cast_failure).
    var cast_fail_fixups: std.ArrayList(u32) = .empty;
    defer cast_fail_fixups.deinit(allocator);
    // D-292 C — throw / throw_ref uncaught exception (code 12 = uncaught_exception).
    var uncaught_exc_fixups: std.ArrayList(u32) = .empty;
    defer uncaught_exc_fixups.deinit(allocator);
    // ADR-0164 A3 / D-292 — memory oob (code 6) demuxed from bounds_fixups.
    var oob_fixups: std.ArrayList(u32) = .empty;
    defer oob_fixups.deinit(allocator);
    // ADR-0179 #3a / D-314 — loop back-edge interrupt poll (code 16, fb=frame_bytes).
    var back_edge_interrupt_fixups: std.ArrayList(u32) = .empty;
    defer back_edge_interrupt_fixups.deinit(allocator);
    // ADR-0179 #3b / D-314 — loop back-edge fuel poll (code 17, fb=frame_bytes).
    var back_edge_fuel_fixups: std.ArrayList(u32) = .empty;
    defer back_edge_fuel_fixups.deinit(allocator);

    // Return fixup list: each `return` op
    // emits its result marshal inline and an unconditional B
    // placeholder; the byte_offset of the placeholder lives here.
    // At function-final `end`, after the marshal but before the
    // frame teardown, all return_fixups are patched to point at
    // the start of the teardown sequence (so `return` shares the
    // single epilogue path).
    var return_fixups: std.ArrayList(u32) = .empty;
    defer return_fixups.deinit(allocator);

    // Call fixup list — exposed via EmitOutput for the post-emit
    // linker / runtime to patch with concrete func-body offsets.
    // Only `call` uses this list; call_indirect uses a different
    // mechanism (table lookup + BLR).
    var call_fixups: std.ArrayList(CallFixup) = .empty;
    errdefer call_fixups.deinit(allocator);

    // SIMD const-pool fixups (per ADR-0042). Each LDR-Q-literal
    // placeholder records (byte_offset, simd_consts index); patched
    // at function close after the const-pool is appended past the
    // trap stub.
    var simd_const_fixups: std.ArrayList(ctx_mod.SimdConstFixup) = .empty;
    defer simd_const_fixups.deinit(allocator);

    // Emit-time-derived 16-byte SIMD constants (per ADR-0051;
    // mirror of x86_64's `extra_consts`). Per-op handlers append
    // shape masks / magic constants here; at function close the
    // list is concatenated after `func.simd_consts` in the flat
    // pool so fixups address both sources via a single global
    // const_idx.
    var extra_consts: std.ArrayList([16]u8) = .empty;
    defer extra_consts.deinit(allocator);

    // Base offset into the flat const-pool that extra_consts
    // entries map to. Lower-time entries occupy
    // `[0, simd_consts_base)`; extra_consts occupy
    // `[simd_consts_base, ...)`. Immutable for the function.
    const simd_consts_base: u32 = if (func.simd_consts) |sc|
        @intCast(sc.len)
    else
        0;

    // EH integration (ADR-0114 D2): scan once for try_table
    // presence and allocate a per-function `ExceptionTable.Builder`
    // on the function-emit arena. The per-op `try_table.emit`
    // populates entries; a later pass folds the builder into the
    // per-Instance `CompiledWasm.exception_table`. Functions without
    // EH pay one linear scan + no allocation (`.empty` ArrayList).
    var has_try_table: bool = false;
    for (func.instrs.items) |scan_ins| {
        if (scan_ins.op == .try_table) {
            has_try_table = true;
            break;
        }
    }
    var eh_builder: exception_table.Builder = .empty;
    defer eh_builder.deinit(allocator);
    // Stack of open try_table blocks awaiting matching `end`.
    // Each `try_table.emit` pushes; the `end` op pops + patches the
    // matched Builder rows' pc_end with the current buf offset.
    var open_try_tables: std.ArrayList(exception_table.OpenTryTable) = .empty;
    defer open_try_tables.deinit(allocator);
    // Per-catch landing_pad_pc forward fixups. Each
    // `try_table.emit` appends one per catch clause; the matching
    // catch-label's `end` patches `Builder.entries[i].landing_pad_pc`
    // to the post-end buf offset.
    var landing_pad_fixups: std.ArrayList(exception_table.LandingPadFixup) = .empty;
    defer landing_pad_fixups.deinit(allocator);

    // Bundle compile()'s mutable state behind a pointer-based
    // EmitCtx so extracted op-handler modules (op_const, op_alu,
    // …) observe the same backing storage as the still-inlined
    // handlers.
    var ctx: EmitCtx = .{
        .allocator = allocator,
        .buf = &buf,
        .func = func,
        .alloc = alloc,
        .func_sigs = func_sigs,
        .module_types = module_types,
        .pushed_vregs = &pushed_vregs,
        .next_vreg = &next_vreg,
        .labels = &labels,
        .bounds_fixups = &bounds_fixups,
        .cind_bounds_fixups = &cind_bounds_fixups,
        .cind_sig_fixups = &cind_sig_fixups,
        .uninit_elem_fixups = &uninit_elem_fixups,
        .divzero_fixups = &divzero_fixups,
        .overflow_fixups = &overflow_fixups,
        .unaligned_atomic_fixups = &unaligned_atomic_fixups,
        .invalid_conv_fixups = &invalid_conv_fixups,
        .null_ref_fixups = &null_ref_fixups,
        .cast_fail_fixups = &cast_fail_fixups,
        .uncaught_exc_fixups = &uncaught_exc_fixups,
        .oob_fixups = &oob_fixups,
        .back_edge_interrupt_fixups = &back_edge_interrupt_fixups,
        .back_edge_fuel_fixups = &back_edge_fuel_fixups,
        .return_fixups = &return_fixups,
        .call_fixups = &call_fixups,
        .simd_const_fixups = &simd_const_fixups,
        .extra_consts = &extra_consts,
        .simd_consts_base = simd_consts_base,
        .local_base_off = local_base_off,
        .spill_base_off = spill_base_off,
        .return_is_memory_class = return_is_memory_class,
        .indirect_result_slot_off = indirect_result_slot_off,
        .num_imports = num_imports,
        .globals_offsets = globals_offsets,
        .globals_valtypes = globals_valtypes,
        .memory0_idx_type = memory0_idx_type,
        .bounds_elided = bounds_elided,
        .exception_table_builder = if (has_try_table) &eh_builder else null,
        .open_try_tables = if (has_try_table) &open_try_tables else null,
        .landing_pad_fixups = if (has_try_table) &landing_pad_fixups else null,
        .tag_param_counts = tag_param_counts,
        .frame_bytes = frame_bytes,
        .uses_type_subtyping = uses_type_subtyping,
        // ADR-0155 stage 2 — register-homed-local call-site spill/reload.
        .homing = homing,
        .n_temp = n_temp,
        .local_offsets = layout.offsets,
    };

    // Track polymorphic-stack dead
    // regions per Wasm spec §3.3. After br / return /
    // unreachable, subsequent ops up to the next structural
    // marker (end / else) are dead — never executed at runtime
    // because the unconditional branch jumps over them. Skipping
    // them in emit avoids spurious AllocationMissing on pops
    // that the validator already deemed polymorphic-OK.
    var dead_code: bool = false;
    const parity_on = liveness_parity.on();
    for (func.instrs.items, 0..) |ins, pc| {
        // D-596 — mirror of the x86_64 call; see `shared/liveness_parity.zig`.
        if (parity_on) {
            liveness_parity.check(func, pc, ins.op, pushed_vregs.items, labels.items);
        }
        // Diagnostic surface: on any error return
        // from the per-op switch below, surface the failing op
        // tag + pc so the realworld_run_jit cap-removal regression
        // (D-053 + D-054) can localise to a specific opcode handler
        // instead of a generic `UnsupportedOp` at the runner.
        errdefer dbg.print(
            "codegen",
            "arm64/emit: failing op `{s}` at func[{d}] pc={d}\n",
            .{ @tagName(ins.op), func.func_idx, pc },
        );
        // Structural markers exit the dead region. `end` and
        // `else` always run their handlers — `end` to pop the
        // label stack / emit function epilogue; `else` to switch
        // to the else-arm of an if. Both are needed for emit's
        // own bookkeeping to stay aligned with the block nesting.
        if (ins.op == .end or ins.op == .@"else") {
            dead_code = false;
        }
        if (dead_code) {
            // Maintain labels-stack consistency for structural
            // ops in dead regions. Without these placeholder pushes,
            // subsequent `end` / `else` cannot find their
            // matching frame and surface as
            // `emitEndIntra`/`emitElse without if_then`.
            // Placeholders carry no real CBZ / branch fixup
            // (if_skip_byte = null marks the "no CBZ to patch"
            // case so emitElse skips the patch step).
            switch (ins.op) {
                .block => try labels.append(allocator, .{
                    .kind = .block,
                    .target_byte_offset = 0,
                    .pending = .empty,
                }),
                .loop => try labels.append(allocator, .{
                    .kind = .loop,
                    .target_byte_offset = @intCast(buf.items.len),
                    .pending = .empty,
                }),
                .@"if" => try labels.append(allocator, .{
                    .kind = .if_then,
                    .target_byte_offset = 0,
                    .pending = .empty,
                    .if_skip_byte = null,
                }),
                // try_table is block-like: its matching `end` pops one label.
                // In dead code it skips the real emit (handler registration),
                // but it STILL needs a placeholder so its `end` pops THIS frame,
                // not the enclosing block/loop — else the label stack under-
                // counts and a later catch's `labels_depth_outer - label_idx`
                // underflows into an integer-overflow panic (D-471).
                .try_table => try labels.append(allocator, .{
                    .kind = .block,
                    .target_byte_offset = 0,
                    .pending = .empty,
                }),
                else => {},
            }
            continue;
        }
        // Route through dispatch_collector before
        // the legacy switch. Returns true → per-arch handler ran,
        // skip legacy. Returns false → no per-arch op file for this
        // tag, legacy switch authoritative. Handler errors propagate
        // via the inferred error set (per-arch handlers return
        // `Error!void` matching the enclosing compile fn).
        // Per ADR-0074 + `.dev/dispatcher_wire_design.md` §2.3.
        if (try dispatch_collector.dispatch(.arm64, ins.op, .{ &ctx, &ins })) {
            continue;
        }
        switch (ins.op) {
            // any.convert_extern / extern.convert_any: pure identity — the
            // value flows through in-place (externref/anyref share the
            // Value.ref slot; the distinction is validator-only). No machine
            // code, no vreg change; liveness models them transparent 0→0.
            .@"any.convert_extern", .@"extern.convert_any" => {},
            // atomic.fence (threads, ADR-0168): on the single-threaded
            // substrate every atomic op is trivially seq-cst and the
            // JIT emits memory ops in program order, so the fence needs
            // no machine code (0→0 transparent, like the convert pair).
            .@"atomic.fence" => {},
            .@"i32.const" => try op_const.emitI32Const(&ctx, &ins),
            .@"i64.const" => try op_const.emitI64Const(&ctx, &ins),
            // Wasm 2.0 reference-types (per ADR-0056):
            // partial — null + is_null. ref.func deferred
            // (needs JitRuntime extension for `func_entities_ptr`).
            // ref.null: push 0 (null_ref sentinel per ADR-0014 §2.1
            // / 6.K.1; Value.null_ref == 0). MOVZ Xd, #0 = 0x00000000
            // → zeroes both halves of X (W form implicitly).
            // ref.is_null: semantically identical to i64.eqz (pop
            // 64-bit, push i32=1 if zero else 0) — reuse handler.
            .@"ref.null" => {
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) {
                    dbg.print("codegen", "arm64/emit: ref.null SlotOverflow vreg={d} slots.len={d} func[{d}]\n", .{ vreg, alloc.slots.len, func.func_idx });
                    return Error.SlotOverflow;
                }
                const xd = try gpr.gprDefSpilled(alloc, vreg, 0);
                try gpr.writeU32(allocator, &buf, inst.encMovzImm16(xd, 0));
                try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            // ref.func idx — produce
            // `@intFromPtr(&rt.func_entities[idx])` matching
            // `Value.fromFuncRef`'s encoding (interp parity per
            // ADR-0014 §2.1). Recipe:
            //   LDR Xresult, [X19, #func_entities_ptr_off]
            //   MOVZ X16, #(byte_off & 0xFFFF)
            //   MOVK X16, #(byte_off >> 16), LSL #16   (if needed)
            //   ADD Xresult, Xresult, X16
            // where byte_off = idx * @sizeOf(FuncEntity).
            .@"ref.func" => {
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) {
                    dbg.print("codegen", "arm64/emit: ref.func SlotOverflow vreg={d} slots.len={d} func[{d}]\n", .{ vreg, alloc.slots.len, func.func_idx });
                    return Error.SlotOverflow;
                }
                const xresult = try gpr.gprDefSpilled(alloc, vreg, 0);
                const byte_off: u64 = @as(u64, ins.payload) * jit_abi.func_entity_size;
                // Load base pointer.
                try gpr.writeU32(allocator, &buf, inst.encLdrImm(xresult, abi.runtime_ptr_save_gpr, jit_abi.func_entities_ptr_off));
                if (byte_off != 0) {
                    // Materialise byte_off in IP0 (X16). Up to 2-instr
                    // (MOVZ low16 + optional MOVK high16, LSL #16).
                    const low16: u16 = @truncate(byte_off & 0xFFFF);
                    const high16: u16 = @truncate((byte_off >> 16) & 0xFFFF);
                    try gpr.writeU32(allocator, &buf, inst.encMovzImm16(16, low16));
                    if (high16 != 0) {
                        try gpr.writeU32(allocator, &buf, inst.encMovkImm16(16, high16, 1));
                    }
                    // ADD Xresult, Xresult, X16.
                    try gpr.writeU32(allocator, &buf, inst.encAddReg(xresult, xresult, 16));
                }
                try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"f32.const" => {
                // Stage the IEEE-754 bits via a GPR const, then
                // FMOV S, W. The intermediate W-reg is the FP
                // vreg's slot's GPR-pool counterpart (slot K → X9+K
                // for K<7, etc.) reused as scratch for the move.
                // Per the per-class slot mapping note in abi.zig
                // (allocatable_v_regs comment), GPR slot 0 maps to
                // X9 — we use that as the immediate scratch.
                //
                // D-034 spill-aware: when the vreg's GPR-class slot
                // is spilled, gprDefSpilled returns the X16 stage
                // reg; the FMOV reads from that stage. The FP-class
                // dest uses fpDefSpilled + fpStoreSpilled to flush
                // V29 to the spill slot when the FP-class slot is
                // spilled.
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) {
                    dbg.print("codegen", "arm64/emit: f32.const SlotOverflow func[{d}] vreg={d} >= slots.len={d}\n", .{ func.func_idx, vreg, alloc.slots.len });
                    return Error.SlotOverflow;
                }
                const vd = try gpr.fpDefSpilled(alloc, vreg, 0);
                const w_scratch = try gpr.gprDefSpilled(alloc, vreg, 0);
                try op_const.emitConstU32(allocator, &buf, w_scratch, @truncate(ins.payload));
                try gpr.writeU32(allocator, &buf, inst_fp.encFmovStoFromW(vd, w_scratch));
                try gpr.fpStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"f64.const" => {
                // Similar to f32.const but for 64-bit (FMOV D, X).
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) {
                    dbg.print("codegen", "arm64/emit: f64.const SlotOverflow func[{d}] vreg={d} >= slots.len={d}\n", .{ func.func_idx, vreg, alloc.slots.len });
                    return Error.SlotOverflow;
                }
                const vd = try gpr.fpDefSpilled(alloc, vreg, 0);
                const x_scratch = try gpr.gprDefSpilled(alloc, vreg, 0);
                const value: u64 = (@as(u64, ins.extra) << 32) | @as(u64, ins.payload);
                const lane0: u16 = @truncate(value & 0xFFFF);
                const lane1: u16 = @truncate((value >> 16) & 0xFFFF);
                const lane2: u16 = @truncate((value >> 32) & 0xFFFF);
                const lane3: u16 = @truncate((value >> 48) & 0xFFFF);
                try gpr.writeU32(allocator, &buf, inst.encMovzImm16(x_scratch, lane0));
                if (lane1 != 0) try gpr.writeU32(allocator, &buf, inst.encMovkImm16(x_scratch, lane1, 1));
                if (lane2 != 0) try gpr.writeU32(allocator, &buf, inst.encMovkImm16(x_scratch, lane2, 2));
                if (lane3 != 0) try gpr.writeU32(allocator, &buf, inst.encMovkImm16(x_scratch, lane3, 3));
                try gpr.writeU32(allocator, &buf, inst_fp.encFmovDtoFromX(vd, x_scratch));
                try gpr.fpStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"local.get" => {
                // Push a fresh vreg holding the value loaded from
                // `[SP, #(local_base_off + layout.offsets[local_idx])]`.
                // Width follows declared local type (i32 → LDR W,
                // i64 → LDR X, v128 → LDR Q).
                const local_idx: u32 = @intCast(ins.payload);
                if (local_idx >= total_locals) return Error.UnsupportedOp;
                const ty = localValType(func, num_params, local_idx);
                const offset_u: u32 = local_base_off + layout.offsets[local_idx];
                // D-289: all widths (GPR + FP/v128) use the large-off-safe frame
                // helpers below — no imm12 cap. FP/v128 loads pass X16/IP0 as the
                // address scratch (the V-reg dst can't self-compute the address).
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) {
                    dbg.print("codegen", "arm64/emit: local.get SlotOverflow func[{d}] vreg={d} >= slots.len={d} local_idx={d}\n", .{ func.func_idx, vreg, alloc.slots.len, local_idx });
                    return Error.SlotOverflow;
                }
                // ADR-0155 stage 1 — register-homed local: read the home
                // register into the fresh temporary via reg→reg MOV (no
                // LDR-from-slot). The fresh temp insulates this value from a
                // later local.set $same (which rewrites the home register) —
                // hazard-free, and keeps `next_vreg` in lockstep with liveness.
                if (homing.pseudoVreg(local_idx, n_temp)) |home_vreg| {
                    const rs = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, home_vreg, 0);
                    const rd = try gpr.gprDefSpilled(alloc, vreg, 1);
                    // MOV Xd, Xs (= ORR Xd, XZR(31), Xs). i32/i64 share the
                    // X-form; an i32 home holds a zero-extended value (LDR W at
                    // prologue + W-form set MOV below), so the full X copy is
                    // correct.
                    try gpr.writeU32(allocator, &buf, inst.encOrrReg(rd, 31, rs));
                    try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, vreg, 1);
                    try pushed_vregs.append(allocator, vreg);
                    continue;
                }
                switch (ty) {
                    .i32 => {
                        const rd = try gpr.gprDefSpilled(alloc, vreg, 0);
                        try gpr.frameLdrGpr(allocator, &buf, rd, offset_u, true);
                        try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, vreg, 0);
                    },
                    .i64, .ref => {
                        // D-093: reftype shares the i64 X-form
                        // 8-byte slot per ADR-0061.
                        const rd = try gpr.gprDefSpilled(alloc, vreg, 0);
                        try gpr.frameLdrGpr(allocator, &buf, rd, offset_u, false);
                        try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, vreg, 0);
                    },
                    .f32 => {
                        const vd = try gpr.fpDefSpilled(alloc, vreg, 0);
                        try gpr.frameLdrFp(allocator, &buf, vd, offset_u, .s, 16);
                        try gpr.fpStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                    },
                    .f64 => {
                        const vd = try gpr.fpDefSpilled(alloc, vreg, 0);
                        try gpr.frameLdrFp(allocator, &buf, vd, offset_u, .d, 16);
                        try gpr.fpStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                    },
                    .v128 => {
                        // Wasm spec §3.5.3 + §4.4.5.1 — local.get
                        // copies the local's stored value (16 bytes
                        // for v128). LDR Q reads the full 128-bit
                        // lane group; q* spill helpers handle V-reg
                        // vs. spill-frame placement.
                        const vd = try gpr.qDefSpilled(alloc, vreg, 0);
                        try gpr.frameLdrFp(allocator, &buf, vd, offset_u, .q, 16);
                        try gpr.qStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                    },
                }
                try pushed_vregs.append(allocator, vreg);
            },
            .@"local.set" => {
                // Pop top vreg, write to
                // `[SP, #(local_base_off + layout.offsets[local_idx])]`.
                // Width follows declared local type.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const local_idx: u32 = @intCast(ins.payload);
                if (local_idx >= total_locals) return Error.UnsupportedOp;
                const ty = localValType(func, num_params, local_idx);
                const offset_u: u32 = local_base_off + layout.offsets[local_idx];
                // D-289: all widths use the large-off-safe frame helpers — no cap.
                const src = pushed_vregs.pop().?;
                // ADR-0155 stage 1 — register-homed local: MOV the popped src
                // into the home register (reg→reg, no STR-to-slot). i32 uses the
                // W-form MOV so the home stays zero-extended; i64 the X-form.
                if (homing.pseudoVreg(local_idx, n_temp)) |home_vreg| {
                    const rs = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                    const rd = try gpr.gprDefSpilled(alloc, home_vreg, 1);
                    if (ty == .i32) {
                        try gpr.writeU32(allocator, &buf, inst.encOrrRegW(rd, 31, rs));
                    } else {
                        try gpr.writeU32(allocator, &buf, inst.encOrrReg(rd, 31, rs));
                    }
                    try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, home_vreg, 1);
                    continue;
                }
                switch (ty) {
                    .i32 => {
                        const rs = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.frameStrGpr(allocator, &buf, rs, offset_u, true, 16);
                    },
                    .i64, .ref => {
                        const rs = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.frameStrGpr(allocator, &buf, rs, offset_u, false, 16);
                    },
                    .f32 => {
                        const vs = try gpr.fpLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.frameStrFp(allocator, &buf, vs, offset_u, .s, 16);
                    },
                    .f64 => {
                        const vs = try gpr.fpLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.frameStrFp(allocator, &buf, vs, offset_u, .d, 16);
                    },
                    .v128 => {
                        // Wasm spec §4.4.5.2 — local.set writes 16
                        // bytes for v128. STR Q via the q* helpers.
                        const vs = try gpr.qLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.frameStrFp(allocator, &buf, vs, offset_u, .q, 16);
                    },
                }
            },
            .@"local.tee" => {
                // Write top vreg to local slot WITHOUT popping —
                // the value remains pushed.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const local_idx: u32 = @intCast(ins.payload);
                if (local_idx >= total_locals) return Error.UnsupportedOp;
                const ty = localValType(func, num_params, local_idx);
                const offset_u: u32 = local_base_off + layout.offsets[local_idx];
                // D-289: all widths use the large-off-safe frame helpers — no cap.
                const src = pushed_vregs.items[pushed_vregs.items.len - 1];
                // ADR-0155 stage 1 — register-homed local: MOV the (peeked) src
                // into the home register; the value stays on the operand stack.
                if (homing.pseudoVreg(local_idx, n_temp)) |home_vreg| {
                    const rs = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                    const rd = try gpr.gprDefSpilled(alloc, home_vreg, 1);
                    if (ty == .i32) {
                        try gpr.writeU32(allocator, &buf, inst.encOrrRegW(rd, 31, rs));
                    } else {
                        try gpr.writeU32(allocator, &buf, inst.encOrrReg(rd, 31, rs));
                    }
                    try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, home_vreg, 1);
                    continue;
                }
                switch (ty) {
                    .i32 => {
                        const rs = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.frameStrGpr(allocator, &buf, rs, offset_u, true, 16);
                    },
                    .i64, .ref => {
                        const rs = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.frameStrGpr(allocator, &buf, rs, offset_u, false, 16);
                    },
                    .f32 => {
                        const vs = try gpr.fpLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.frameStrFp(allocator, &buf, vs, offset_u, .s, 16);
                    },
                    .f64 => {
                        const vs = try gpr.fpLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.frameStrFp(allocator, &buf, vs, offset_u, .d, 16);
                    },
                    .v128 => {
                        // Wasm spec §4.4.5.3 — local.tee mirrors
                        // local.set's 16-byte write.
                        const vs = try gpr.qLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.frameStrFp(allocator, &buf, vs, offset_u, .q, 16);
                    },
                }
            },
            .select, .select_typed => {
                // Wasm spec §4.4.4 / §3.3.2.2 (select / select_typed)
                // — pop c, val2, val1 (top of stack is c). Push val1
                // if c != 0, else val2. ARM64 lowering:
                //   CMP c_w, #0
                //   CSEL d_*, val1_*, val2_*, NE        (GPR types)
                //   FCSEL d_*, val1_*, val2_*, NE       (FP types — m-4b)
                //   v128 → op_simd.emitV128Select        (mask synth)
                //
                // Dispatch shape (per ADR-0056):
                //   - v128 (shape_tag): pre-existing SIMD mask emit
                //   - i32 (extra=0x7F or .select untyped default):
                //     CSEL Wd
                //   - i64 / funcref / externref (extra=0x7E/0x70/0x6F):
                //     CSEL Xd
                //   - f32 / f64 (extra=0x7D/0x7C): FCSEL S/D (m-4b)
                //   - untyped .select with non-i32 operands: handled
                //     via validator's `out_select_types` → lower's
                //     `select_types[idx]` → `ins.extra` byte, so the
                //     switch below dispatches correctly (D-090 close,
                //     2026-05-21 `2f54f753`)
                if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
                const cond_v = pushed_vregs.pop().?;
                const val2_v = pushed_vregs.pop().?;
                const val1_v = pushed_vregs.pop().?;
                const result_v = next_vreg;
                next_vreg += 1;
                if (result_v >= alloc.slots.len) {
                    dbg.print("codegen", "arm64/emit: select SlotOverflow func[{d}] vreg={d} >= slots.len={d}\n", .{ func.func_idx, result_v, alloc.slots.len });
                    return Error.SlotOverflow;
                }
                // Dispatch on val1's shape_tag. v128
                // operands need a SIMD-aware mask synthesis (CSETM +
                // DUP V.2D + BSL); GPR / FP fall through to CSEL.
                if (alloc.shapeTag(val1_v) == .v128) {
                    try op_simd.emitV128Select(&ctx, cond_v, val1_v, val2_v, result_v);
                    try pushed_vregs.append(allocator, result_v);
                } else {
                    // Dispatch on `ins.extra` — for select_typed
                    // (0x1C) lower emits the valtype byte directly;
                    // for untyped .select (0x1B) lower threads the
                    // validator-resolved valtype from
                    // `out_select_types[]` (D-090 close). extra=0
                    // (default fallback for bypass-the-validator unit
                    // tests) → i32 CSEL Wd.
                    const TypeClass = enum { gpr32, gpr64, fp32, fp64 };
                    const tc: TypeClass = switch (ins.extra) {
                        // 64-bit GPR: i64 + ALL reftypes (funcref/externref +
                        // GC/EH abstract refs — 64-bit pointers; D-492). Routing
                        // a reftype to .gpr32 would TRUNCATE the pointer.
                        0x7E, 0x70, 0x6F, 0x6E, 0x6D, 0x6C, 0x6B, 0x6A, 0x69, 0x71, 0x72, 0x73, 0x74 => .gpr64,
                        0x7D => .fp32, // f32
                        0x7C => .fp64, // f64
                        else => .gpr32, // 0x7F i32 or untyped .select
                    };
                    // CMP cond, #0 emits first (stage 0 for cond). After
                    // CMP, cond is dead; stage 0 free for reuse.
                    const cond_w = try gpr.gprLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, cond_v, 0);
                    try gpr.writeU32(allocator, &buf, inst.encCmpImmW(cond_w, 0));
                    switch (tc) {
                        .gpr32, .gpr64 => {
                            const val1_r = try gpr.gprLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, val1_v, 0);
                            const val2_r = try gpr.gprLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, val2_v, 1);
                            const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
                            const csel_word: u32 = if (tc == .gpr64)
                                inst.encCselX(dst_r, val1_r, val2_r, .ne)
                            else
                                inst.encCselW(dst_r, val1_r, val2_r, .ne);
                            try gpr.writeU32(allocator, &buf, csel_word);
                            try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, result_v, 0);
                        },
                        .fp32, .fp64 => {
                            const val1_v_phys = try gpr.fpLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, val1_v, 0);
                            const val2_v_phys = try gpr.fpLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, val2_v, 1);
                            const dst_v = try gpr.fpDefSpilled(alloc, result_v, 0);
                            const fcsel_word: u32 = if (tc == .fp64)
                                inst.encFcselD(dst_v, val1_v_phys, val2_v_phys, .ne)
                            else
                                inst.encFcselS(dst_v, val1_v_phys, val2_v_phys, .ne);
                            try gpr.writeU32(allocator, &buf, fcsel_word);
                            try gpr.fpStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, result_v, 0);
                        },
                    }
                    try pushed_vregs.append(allocator, result_v);
                }
            },
            .drop => {
                // Discard the top operand. Wasm spec §4.4.4: the
                // value is consumed without storage. No machine
                // bytes emitted; we simply remove the vreg from
                // the operand-stack tracker so subsequent ops see
                // the next vreg as top-of-stack.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                _ = pushed_vregs.pop().?;
            },
            .nop => {
                // Wasm spec §4.4.6.2: do nothing. No machine
                // bytes; no stack change. Validator already
                // accepts it; emit just skips.
            },
            .@"unreachable" => {
                // Wasm spec §4.4.6.1: trap unconditionally. Emit
                // an unconditional `B 0` placeholder; record the
                // byte_offset so the function-end trap-stub patch
                // pass redirects it to the trap stub. Unlike the
                // bounds-check Bcond placeholders, this one
                // carries the unconditional-B opcode (bits 31..26
                // = 000101); the patcher distinguishes by opcode.
                const fixup_at: u32 = @intCast(buf.items.len);
                try gpr.writeU32(allocator, &buf, inst.encB(0));
                try unreach_fixups.append(allocator, fixup_at);
                dead_code = true;
            },
            .@"return" => {
                // Wasm spec §4.4.7: pop the function's results and
                // exit. D-093 — use shared
                // `marshalFunctionReturn` helper so multi-result
                // signatures (Wasm 2.0 multi-value) marshal all N
                // results to AAPCS64 X0..X7 / V0..V7. Pre-d-14
                // inline only handled results[0], silently
                // dropping further results (= garbage in X1 etc.)
                // — surfaced as `if.wast:add64_u_saturated`
                // returning the wrong value because the i32 carry
                // wasn't written, leaving X1 garbage that the
                // caller's if-frame cond pop read as truthy.
                try op_control.marshalFunctionReturn(&ctx);
                const fixup_at: u32 = @intCast(buf.items.len);
                try gpr.writeU32(allocator, &buf, inst.encB(0));
                try return_fixups.append(allocator, fixup_at);
                dead_code = true;
            },
            .block => try op_control.emitBlock(&ctx, &ins),
            .loop => try op_control.emitLoop(&ctx, &ins),
            .br => {
                try op_control.emitBr(&ctx, &ins);
                dead_code = true;
            },
            // throw / throw_ref dispatched here
            // (rather than via dispatch_collector) so the local
            // `dead_code` can be set; arm64 EmitCtx lacks the
            // x86_64-style `dead_code: *bool` ctx field. Per-op
            // bodies emit a B-placeholder targeting the trap stub
            // (mirror of unreachable). The full dispatcher CALL +
            // handler dispatch is a follow-up.
            .throw => {
                if (comptime wasm_v3_plus) {
                    try op_throw.emit(&ctx, &ins);
                    dead_code = true;
                } else return Error.UnsupportedOp;
            },
            .throw_ref => {
                if (comptime wasm_v3_plus) {
                    try op_throw_ref.emit(&ctx, &ins);
                    dead_code = true;
                } else return Error.UnsupportedOp;
            },
            .call_indirect => try op_call.emitCallIndirect(&ctx, &ins),
            .call => try op_call.emitCall(&ctx, &ins),
            .call_ref => {
                if (comptime wasm_v3_plus) {
                    try op_call.emitCallRef(&ctx, &ins);
                } else return Error.UnsupportedOp;
            },
            // D-239 — function-references null-ref branch ops.
            .br_on_null => {
                if (comptime wasm_v3_plus) {
                    try op_br_on_null.emit(&ctx, &ins);
                } else return Error.UnsupportedOp;
            },
            .br_on_non_null => {
                if (comptime wasm_v3_plus) {
                    try op_br_on_non_null.emit(&ctx, &ins);
                } else return Error.UnsupportedOp;
            },
            .@"ref.as_non_null" => {
                if (comptime wasm_v3_plus) {
                    try op_ref_as_non_null.emit(&ctx, &ins);
                } else return Error.UnsupportedOp;
            },
            .return_call => {
                if (comptime wasm_v3_plus) {
                    try op_return_call.emit(&ctx, &ins);
                    dead_code = true;
                } else return Error.UnsupportedOp;
            },
            .return_call_indirect => {
                if (comptime wasm_v3_plus) {
                    try op_return_call_indirect.emit(&ctx, &ins);
                    dead_code = true;
                } else return Error.UnsupportedOp;
            },
            .return_call_ref => {
                if (comptime wasm_v3_plus) {
                    try op_return_call_ref.emit(&ctx, &ins);
                    dead_code = true;
                } else return Error.UnsupportedOp;
            },
            .@"memory.size" => {
                // Wasm memory.size returns current size in 64-KiB pages.
                // X27 carries the byte limit; pages = bytes >> 16.
                // Pop nothing (Wasm signature: () → i32). Push the
                // result vreg.
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) {
                    dbg.print("codegen", "arm64/emit: memory.size SlotOverflow func[{d}] vreg={d} >= slots.len={d}\n", .{ func.func_idx, result, alloc.slots.len });
                    return Error.SlotOverflow;
                }
                const wd = try gpr.gprDefSpilled(alloc, result, 0);
                // Custom-page-sizes (ADR-0168 v0.2): pages = mem_limit >>
                // page_size_log2 (default 16). Variable shift reads the rt
                // field (W16 scratch) so a 1-byte page reports the byte count.
                try gpr.writeU32(allocator, &buf, inst.encLdrImmW(16, abi.runtime_ptr_save_gpr, jit_abi.mem0_page_size_log2_off));
                try gpr.writeU32(allocator, &buf, inst.encLsrvRegW(wd, 27, 16));
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, result, 0);
                try pushed_vregs.append(allocator, result);
            },
            .@"memory.grow" => {
                // Wasm spec §4.4.7.6 — grow linear memory by N pages,
                // returning the previous page count, or -1 on failure.
                // Per ADR-0059: indirect call through
                // `JitRuntime.memory_grow_fn` with AAPCS64 args
                //   X0 = runtime_ptr (= X19), W1 = delta_pages.
                // BLR clobbers all caller-saved regs. AAPCS64
                // preserves X19..X28 but their *cached values*
                // (X28 = vm_base, X27 = mem_limit per ADR-0017)
                // become stale if the callout reallocated the
                // backing buffer — reload from JitRuntime tail
                // before any subsequent memory op.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const delta_vreg = pushed_vregs.pop().?;
                // Marshal delta into W1 (AAPCS64 second arg).
                const ws = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, delta_vreg, 0);
                if (ws != 1) try gpr.writeU32(allocator, &buf, inst.encOrrRegW(1, 31, ws));
                // Restore X0 = runtime_ptr (ADR-0017 sub-2d-ii).
                try gpr.writeU32(allocator, &buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
                // LDR X16, [X19, #memory_grow_fn_off]; BLR X16.
                try gpr.writeU32(allocator, &buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.memory_grow_fn_off));
                try gpr.writeU32(allocator, &buf, inst.encBLR(16));
                // Reload prologue-cached invariants (X28 vm_base,
                // X27 mem_limit) — they may have moved.
                try gpr.writeU32(allocator, &buf, inst.encLdrImm(28, abi.runtime_ptr_save_gpr, jit_abi.vm_base_off));
                try gpr.writeU32(allocator, &buf, inst.encLdrImm(27, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off));
                // Capture W0 → result vreg as i32. Mirror of
                // op_call.zig:captureCallResult.i32 (slot-aware
                // dispatch on .reg / .spill).
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) {
                    dbg.print("codegen", "arm64/emit: memory.grow SlotOverflow func[{d}] vreg={d} >= slots.len={d}\n", .{ func.func_idx, result, alloc.slots.len });
                    return Error.SlotOverflow;
                }
                // memory64 grow yields an i64; sign-extend W0 so the -1
                // failure sentinel widens to a full i64 -1 (D-216). mem32
                // stays i32 (zero-ext; canonical i32 form). Success page
                // counts are non-negative → identical either way.
                const grow_is_mem64 = ctx.memory0_idx_type == .i64;
                switch (alloc.slot(result, .gpr)) {
                    .reg => |id| {
                        const wd = abi.slotToReg(id) orelse {
                            dbg.print("codegen", "arm64/emit: memory.grow capture SlotOverflow func[{d}] result_vreg={d} slot_id={d}\n", .{ func.func_idx, result, id });
                            return Error.SlotOverflow;
                        };
                        if (grow_is_mem64) {
                            try gpr.writeU32(allocator, &buf, inst.encSxtw(wd, 0));
                        } else if (wd != 0) {
                            try gpr.writeU32(allocator, &buf, inst.encOrrRegW(wd, 31, 0));
                        }
                    },
                    .spill => |off| {
                        const abs_off: u32 = spill_base_off + off;
                        if (grow_is_mem64) {
                            try gpr.writeU32(allocator, &buf, inst.encSxtw(0, 0));
                            try gpr.frameStrGpr(allocator, &buf, 0, abs_off, false, abi.spill_stage_gprs[0]);
                        } else {
                            try gpr.frameStrGpr(allocator, &buf, 0, abs_off, true, abi.spill_stage_gprs[0]);
                        }
                    },
                }
                try pushed_vregs.append(allocator, result);
            },
            .@"memory.fill" => try op_memory.emitMemoryFill(&ctx),
            .@"memory.copy" => try op_memory.emitMemoryCopy(&ctx),
            // i32.atomic.load (threads, ADR-0168): routed through the
            // shared memory-op emitter like i32.load. Single-threaded
            // substrate → plain aligned load (runtime align-trap deferred).
            // Legacy-switch path (not dispatch_collector) per the bundle
            // decision — same as atomic.fence.
            .@"i32.atomic.load",
            .@"i64.atomic.load",
            .@"i32.atomic.load8_u",
            .@"i32.atomic.load16_u",
            .@"i64.atomic.load8_u",
            .@"i64.atomic.load16_u",
            .@"i64.atomic.load32_u",
            .@"i32.atomic.store",
            .@"i64.atomic.store",
            .@"i32.atomic.store8",
            .@"i32.atomic.store16",
            .@"i64.atomic.store8",
            .@"i64.atomic.store16",
            .@"i64.atomic.store32",
            => try op_memory.emitMemOp(&ctx, &ins),
            // tNN.atomic.rmw* (threads, ADR-0168): callout through
            // JitRuntime.atomic_rmw_fn (load-modify-store; reuses interp
            // logic, sidesteps the inline-emit D-299 alignment-trap gap).
            .@"i32.atomic.rmw.add",
            .@"i32.atomic.rmw.sub",
            .@"i32.atomic.rmw.and",
            .@"i32.atomic.rmw.or",
            .@"i32.atomic.rmw.xor",
            .@"i32.atomic.rmw.xchg",
            .@"i64.atomic.rmw.add",
            .@"i64.atomic.rmw.sub",
            .@"i64.atomic.rmw.and",
            .@"i64.atomic.rmw.or",
            .@"i64.atomic.rmw.xor",
            .@"i64.atomic.rmw.xchg",
            .@"i32.atomic.rmw8.add_u",
            .@"i32.atomic.rmw8.sub_u",
            .@"i32.atomic.rmw8.and_u",
            .@"i32.atomic.rmw8.or_u",
            .@"i32.atomic.rmw8.xor_u",
            .@"i32.atomic.rmw8.xchg_u",
            .@"i32.atomic.rmw16.add_u",
            .@"i32.atomic.rmw16.sub_u",
            .@"i32.atomic.rmw16.and_u",
            .@"i32.atomic.rmw16.or_u",
            .@"i32.atomic.rmw16.xor_u",
            .@"i32.atomic.rmw16.xchg_u",
            .@"i64.atomic.rmw8.add_u",
            .@"i64.atomic.rmw8.sub_u",
            .@"i64.atomic.rmw8.and_u",
            .@"i64.atomic.rmw8.or_u",
            .@"i64.atomic.rmw8.xor_u",
            .@"i64.atomic.rmw8.xchg_u",
            .@"i64.atomic.rmw16.add_u",
            .@"i64.atomic.rmw16.sub_u",
            .@"i64.atomic.rmw16.and_u",
            .@"i64.atomic.rmw16.or_u",
            .@"i64.atomic.rmw16.xor_u",
            .@"i64.atomic.rmw16.xchg_u",
            .@"i64.atomic.rmw32.add_u",
            .@"i64.atomic.rmw32.sub_u",
            .@"i64.atomic.rmw32.and_u",
            .@"i64.atomic.rmw32.or_u",
            .@"i64.atomic.rmw32.xor_u",
            .@"i64.atomic.rmw32.xchg_u",
            => try op_memory.emitAtomicRmw(&ctx, &ins),
            // tNN.atomic.rmw*.cmpxchg* (threads, ADR-0168): callout
            // through JitRuntime.atomic_cmpxchg_fns[width_log2].
            .@"i32.atomic.rmw.cmpxchg",
            .@"i64.atomic.rmw.cmpxchg",
            .@"i32.atomic.rmw8.cmpxchg_u",
            .@"i32.atomic.rmw16.cmpxchg_u",
            .@"i64.atomic.rmw8.cmpxchg_u",
            .@"i64.atomic.rmw16.cmpxchg_u",
            .@"i64.atomic.rmw32.cmpxchg_u",
            => try op_memory.emitAtomicCmpxchg(&ctx, &ins),
            // memory.atomic.notify / wait{32,64} (threads, ADR-0168):
            // callout through atomic_notify_fn / atomic_wait_fns[idx].
            .@"memory.atomic.notify" => try op_memory.emitAtomicNotify(&ctx, &ins),
            .@"memory.atomic.wait32",
            .@"memory.atomic.wait64",
            => try op_memory.emitAtomicWait(&ctx, &ins),
            // Wasm wide-arithmetic (ADR-0168 v0.2) — 128-bit multi-result.
            .@"i64.add128",
            .@"i64.sub128",
            => try op_alu_int.emitWideAddSub128(&ctx, &ins),
            .@"i64.mul_wide_s",
            .@"i64.mul_wide_u",
            => try op_alu_int.emitWideMul(&ctx, &ins),
            // data.drop / elem.drop — write 1 to
            // the dropped-flag byte at `[r15+ptr_off]+idx`. No
            // operands consumed; no result pushed. validator already
            // bounds-checks the index, so no trap path needed.
            .@"data.drop" => {
                if (ins.payload >= 4096) return Error.UnsupportedOp;
                try gpr.writeU32(allocator, &buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.data_dropped_ptr_off));
                try gpr.writeU32(allocator, &buf, inst.encMovzImm16(17, 1));
                try gpr.writeU32(allocator, &buf, inst.encStrbImm(17, 16, @intCast(ins.payload)));
            },
            .@"elem.drop" => {
                if (ins.payload >= 4096) return Error.UnsupportedOp;
                try gpr.writeU32(allocator, &buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.elem_dropped_ptr_off));
                try gpr.writeU32(allocator, &buf, inst.encMovzImm16(17, 1));
                try gpr.writeU32(allocator, &buf, inst.encStrbImm(17, 16, @intCast(ins.payload)));
            },
            // Table ops (per ADR-0058):
            // table.get / table.set / table.size — bounds-checked
            // load/store against the per-table TableSlice descriptor
            // in JitRuntime.
            // table.fill — inline loop writing N copies of val into
            // refs[dst..dst+n].
            // table.copy — element-typed memmove with same-table
            // backward arm.
            // table.init (ADR-0058 amendment) — copy from elem segment
            // to table; honours elem_dropped flag.
            .br_table => try op_control.emitBrTable(&ctx, &ins),
            .br_if => try op_control.emitBrIf(&ctx, &ins),
            .end => {
                // Two distinct forms:
                // (A) Intra-function `end`: pops a label off the stack
                //     and patches forward fixups (block) / no-op for loop.
                // (B) Function-level `end`: marshals result, runs
                //     epilogue, returns.
                //
                // Disambiguation: if `labels` is non-empty, we're in
                // form (A). Otherwise form (B).
                if (labels.items.len > 0) {
                    // If this `end` closes a try_table block,
                    // patch the pc_end of the catch entries this
                    // try_table registered. Match by labels-stack
                    // depth at try_table emit time.
                    if (open_try_tables.items.len > 0) {
                        const top = open_try_tables.items[open_try_tables.items.len - 1];
                        if (top.labels_depth == labels.items.len) {
                            const now: u32 = @intCast(buf.items.len);
                            const start: usize = top.entry_start;
                            const end_excl: usize = start + top.entry_count;
                            for (eh_builder.entries.items[start..end_excl]) |*e| {
                                e.pc_end = now;
                            }
                            _ = open_try_tables.pop();
                        }
                    }
                    // D-182 — snapshot
                    // the depth of the label about to be popped; for
                    // each landing_pad fixup whose `target_labels_depth`
                    // matches, emit a per-clause prelude:
                    //   - .catch_all / .catch_all_ref: zero-byte prelude
                    //     (post-emitEndIntra position is the landing).
                    //   - .catch_ / .catch_ref: load N=tag_param_counts
                    //     [tag_idx] values from `eh_payload_buf` into
                    //     the block-result vreg slots (= top N entries
                    //     of `pushed_vregs` after emitEndIntra), then
                    //     JMP to the common continuation. exnref push
                    //     (.catch_ref / .catch_all_ref) is v0.2 scope
                    //     per ADR-0120 §3.
                    const popped_depth: u32 = @intCast(labels.items.len);
                    try op_control.emitEndIntra(&ctx, &ins);
                    if (landing_pad_fixups.items.len > 0) {
                        // Detect if any matching clause needs a prelude.
                        // A catch lands here straight from the unwinder, bypassing the
                        // post-call reload of register-homed locals: their home registers
                        // hold whatever the unwound callees left. The prelude must reload
                        // them from their frame slots, so take the per-clause path.
                        var any_payload = ctx.homing.count > 0;
                        var probe_i: usize = 0;
                        while (probe_i < landing_pad_fixups.items.len) : (probe_i += 1) {
                            const fx = landing_pad_fixups.items[probe_i];
                            if (fx.target_labels_depth != popped_depth) continue;
                            const k = eh_builder.entries.items[fx.entry_idx].kind;
                            // D-327: any _ref clause needs the per-clause path to
                            // emit the exnref reify call (even with 0 payload).
                            if (k == .catch_ref or k == .catch_all_ref) {
                                any_payload = true;
                                break;
                            }
                            if (k == .catch_ or k == .catch_ref) {
                                const tag_idx_opt = eh_builder.entries.items[fx.entry_idx].tag_idx;
                                if (tag_idx_opt) |t| {
                                    if (ctx.tag_param_counts.len > t and ctx.tag_param_counts[t] > 0) {
                                        any_payload = true;
                                        break;
                                    }
                                }
                            }
                        }

                        if (!any_payload) {
                            // Simple path (pre-D-182 shape): all matching
                            // fixups land at post-emitEndIntra position.
                            const land_pc: u32 = @intCast(buf.items.len);
                            var i: usize = 0;
                            while (i < landing_pad_fixups.items.len) {
                                const fx = landing_pad_fixups.items[i];
                                if (fx.target_labels_depth == popped_depth) {
                                    eh_builder.entries.items[fx.entry_idx].landing_pad_pc = land_pc;
                                    _ = landing_pad_fixups.swapRemove(i);
                                } else {
                                    i += 1;
                                }
                            }
                        } else {
                            // Per-clause prelude path. For each matching
                            // fixup: snapshot clause_start, emit prelude,
                            // emit JMP-to-common placeholder, patch
                            // landing_pad_pc. After all matching fixups,
                            // patch JMPs to common_pc = buf.items.len.
                            var jmp_placeholders: std.ArrayList(u32) = .empty;
                            defer jmp_placeholders.deinit(allocator);
                            // The block's fall-through path arrives here too and must not run
                            // the landing-pad preludes laid out inline below; jump it straight
                            // to the common continuation.
                            try jmp_placeholders.append(allocator, @intCast(buf.items.len));
                            try gpr.writeU32(allocator, &buf, inst.encB(0));

                            var i: usize = 0;
                            while (i < landing_pad_fixups.items.len) {
                                const fx = landing_pad_fixups.items[i];
                                if (fx.target_labels_depth != popped_depth) {
                                    i += 1;
                                    continue;
                                }
                                const entry = &eh_builder.entries.items[fx.entry_idx];
                                const clause_start: u32 = @intCast(buf.items.len);

                                const is_ref = entry.kind == .catch_ref or entry.kind == .catch_all_ref;
                                // D-327 (ADR-0120 D6) — reify the exnref FIRST (before
                                // the param prelude), into the TOP result vreg (the
                                // single last result, above the params). The reify is an
                                // emit-synthesized CALL the regalloc doesn't model, so it
                                // clobbers caller-saved regs — doing it first means the
                                // params (written after) survive. BLR reify_exnref_fn(rt);
                                // store X0 (= *Exception). Cohort-safe: X19 callee-saved.
                                if (is_ref) {
                                    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                                    const exnref_vreg = pushed_vregs.items[pushed_vregs.items.len - 1];
                                    try gpr.writeU32(allocator, &buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)); // MOV X0, X19
                                    try gpr.writeU32(allocator, &buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, @intCast(jit_abi.reify_exnref_fn_off)));
                                    try gpr.writeU32(allocator, &buf, inst.encBLR(16));
                                    const dest_reg = try gpr.gprDefSpilled(alloc, exnref_vreg, 0);
                                    if (dest_reg != 0) try gpr.writeU32(allocator, &buf, inst.encOrrReg(dest_reg, 31, 0)); // MOV dest, X0
                                    try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, exnref_vreg, 0);
                                }
                                // After the reify call (it clobbers caller-saved
                                // homes) and before the payload loads.
                                try op_call.reloadHomedCallerSaved(&ctx);
                                if (entry.kind == .catch_ or entry.kind == .catch_ref) {
                                    const tag_idx = entry.tag_idx orelse return Error.UnsupportedOp;
                                    const n_payload: u32 = if (ctx.tag_param_counts.len > tag_idx)
                                        ctx.tag_param_counts[tag_idx]
                                    else
                                        0;
                                    if (n_payload > 0) {
                                        // D-328/D-327: the catch result vregs are the
                                        // DEEPEST `result_arity` slots; for catch_ref
                                        // the exnref is the single TOP result, so the
                                        // tag params are the deepest np (base skips the
                                        // exnref slot).
                                        const extra: usize = if (is_ref) 1 else 0;
                                        if (pushed_vregs.items.len < n_payload + extra) return Error.AllocationMissing;
                                        const base = pushed_vregs.items.len - n_payload - extra;
                                        var k: u32 = 0;
                                        while (k < n_payload) : (k += 1) {
                                            const target_vreg = pushed_vregs.items[base + k];
                                            const dest_reg = try gpr.gprDefSpilled(alloc, target_vreg, 0);
                                            const slot_off: u15 = @intCast(jit_abi.eh_payload_buf_off + k * 8);
                                            try gpr.writeU32(allocator, &buf, inst.encLdrImm(dest_reg, abi.runtime_ptr_save_gpr, slot_off));
                                            try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, target_vreg, 0);
                                        }
                                    }
                                }

                                // Emit JMP placeholder to common_pc.
                                const jmp_off: u32 = @intCast(buf.items.len);
                                try gpr.writeU32(allocator, &buf, inst.encB(0));
                                try jmp_placeholders.append(allocator, jmp_off);

                                entry.landing_pad_pc = clause_start;
                                _ = landing_pad_fixups.swapRemove(i);
                            }

                            // Patch all JMPs to common_pc.
                            const common_pc: u32 = @intCast(buf.items.len);
                            for (jmp_placeholders.items) |jmp_off| {
                                const disp_bytes: i32 = @intCast(@as(i64, common_pc) - @as(i64, jmp_off));
                                const disp_words: i32 = @divExact(disp_bytes, 4);
                                const enc = inst.encB(disp_words);
                                std.mem.writeInt(u32, buf.items[jmp_off..][0..4], enc, .little);
                            }
                        }
                    }
                    continue;
                }
                // Function-level end (labels stack is empty).
                // D-093: when the function body terminates
                // via a dead-fall-through loop (the function
                // never returns at runtime; an infinite loop or
                // br target above the function), pushed_vregs
                // may carry a placeholder vreg 0 with no
                // allocation entry. The marshal code would
                // be unreachable at runtime regardless, so skip
                // when top_vreg has no slot entry.
                // D-093: multi-result function return marshal
                // via shared op_control helper (mirrors the per-arch
                // X0..X7 / V0..V7 AAPCS64 ABI).
                try op_control.marshalFunctionReturn(&ctx);
                // ADR-0106 path (a) — buffer-write ABI
                // returns the trap-status ErrCode in W0 (= 0 on OK).
                // marshalFunctionReturn writes results to
                // `[X16 + i*8]` via the buffer-ptr capture and
                // leaves X0 with the captured buffer-ptr value;
                // we clobber W0 → 0 here so the entry helper's
                // `code != ErrCode_OK` check passes.
                if (buffer_write) {
                    // MOV W0, WZR ≡ ORR W0, WZR, WZR.
                    try gpr.writeU32(allocator, &buf, inst.encOrrReg(0, 31, 31));
                }
                // Capture the byte offset of the frame teardown.
                // `return` ops emitted earlier B-fixup placeholders
                // here (their result marshal already ran inline);
                // patch them to share this single epilogue path.
                const epilogue_byte: u32 = @intCast(buf.items.len);
                if (frame_bytes > 0) {
                    const fb_high: u12 = @intCast((frame_bytes >> 12) & 0xFFF);
                    const fb_low: u12 = @intCast(frame_bytes & 0xFFF);
                    if (fb_high != 0) try gpr.writeU32(allocator, &buf, inst.encAddImm12Lsl12(31, 31, fb_high));
                    if (fb_low != 0) try gpr.writeU32(allocator, &buf, inst.encAddImm12(31, 31, fb_low));
                }
                try gpr.writeU32(allocator, &buf, encLdpFpLrPostIdx());
                try gpr.writeU32(allocator, &buf, inst.encRet(abi.link_register));
                for (return_fixups.items) |fx_byte| {
                    const disp_words: i32 = @divExact(
                        @as(i32, @intCast(epilogue_byte)) - @as(i32, @intCast(fx_byte)),
                        4,
                    );
                    std.mem.writeInt(u32, buf.items[fx_byte..][0..4], inst.encB(disp_words), .little);
                }

                // Trap stub: emitted after the regular RET when the
                // function had any bounds-check / sig-mismatch /
                // NaN-trap / range-trap fixups. Each fixup's B.cond
                // is patched to land here.
                //
                // Per the ADR-0017 trap_flag amendment:
                // STR W17, [X19, #trap_flag_off] sets the runtime's
                // trap_flag = 1 (W17 holds the trap indicator).
                // Then a clean MOV X0, #0 + epilogue + RET unwinds
                // — the entry shim distinguishes trap-vs-return by
                // reading runtime.trap_flag, NOT by inspecting the
                // returned value (so a trap doesn't confuse with
                // "returned 0").
                if (bounds_fixups.items.len > 0) {
                    const trap_byte: u32 = @intCast(buf.items.len);
                    try gpr.writeU32(allocator, &buf, inst.encMovzImm16(17, 1));
                    try gpr.writeU32(allocator, &buf, inst.encStrImmW(17, abi.runtime_ptr_save_gpr, jit_abi.trap_flag_off));
                    // D-144 — generic kind=1
                    // mirror (every trap variant writes trap_kind so
                    // stale values from earlier invocations cannot
                    // poison the next FAIL's diagnostic).
                    try gpr.writeU32(allocator, &buf, inst.encStrImmW(17, abi.runtime_ptr_save_gpr, jit_abi.trap_kind_off));
                    try gpr.writeU32(allocator, &buf, inst.encMovzImm16(0, 0));
                    if (frame_bytes > 0) {
                        const fb_high: u12 = @intCast((frame_bytes >> 12) & 0xFFF);
                        const fb_low: u12 = @intCast(frame_bytes & 0xFFF);
                        if (fb_high != 0) try gpr.writeU32(allocator, &buf, inst.encAddImm12Lsl12(31, 31, fb_high));
                        if (fb_low != 0) try gpr.writeU32(allocator, &buf, inst.encAddImm12(31, 31, fb_low));
                    }
                    try gpr.writeU32(allocator, &buf, encLdpFpLrPostIdx());
                    try gpr.writeU32(allocator, &buf, inst.encRet(abi.link_register));
                    for (bounds_fixups.items) |fx_byte| {
                        const disp_words: i32 = @divExact(
                            @as(i32, @intCast(trap_byte)) - @as(i32, @intCast(fx_byte)),
                            4,
                        );
                        const orig = std.mem.readInt(u32, buf.items[fx_byte..][0..4], .little);
                        // Distinguish the placeholder shape by opcode:
                        //   bits 31..26 == 0b000101 → unconditional B
                        //                  (`unreachable` op, no condition).
                        //   bits 31..24 == 0x54     → B.cond (bounds /
                        //                  sig-mismatch / trap variants).
                        const new_word: u32 = if ((orig >> 26) == 0b000101)
                            inst.encB(disp_words)
                        else blk: {
                            const cond: inst.Cond = @enumFromInt(@as(u4, @intCast(orig & 0xF)));
                            break :blk inst.encBCond(cond, disp_words);
                        };
                        std.mem.writeInt(u32, buf.items[fx_byte..][0..4], new_word, .little);
                    }
                }

                // D-144 — dedicated trap stubs
                // for call_indirect bounds (kind=2) + sig (kind=3).
                // Each stub mirrors the generic trap stub's shape
                // (set trap_flag=1, return 0) plus a STR of the kind
                // code to `trap_kind_off`. Permanent diagnostic infra
                // per hypothesis_enumeration.md step-4: every future
                // call_indirect trap localises to bounds vs sig vs
                // SIGSEGV-recovery without per-bug instrumentation.
                const EmitCindStub = struct {
                    fn emit(
                        a: std.mem.Allocator,
                        b: *std.ArrayList(u8),
                        fixups: []const u32,
                        kind: u16,
                        fb: u32,
                    ) !void {
                        return emitForce(a, b, fixups, kind, fb, false);
                    }

                    /// `force` (ADR-0202 D4): emit the stub even with zero
                    /// fixups — an elided-bounds function has no B.HI sites
                    /// but the guard-fault PC-redirect needs the stub body.
                    fn emitForce(
                        a: std.mem.Allocator,
                        b: *std.ArrayList(u8),
                        fixups: []const u32,
                        kind: u16,
                        fb: u32,
                        force: bool,
                    ) !void {
                        if (fixups.len == 0 and !force) return;
                        const stub_byte: u32 = @intCast(b.items.len);
                        try gpr.writeU32(a, b, inst.encMovzImm16(17, 1));
                        try gpr.writeU32(a, b, inst.encStrImmW(17, abi.runtime_ptr_save_gpr, jit_abi.trap_flag_off));
                        try gpr.writeU32(a, b, inst.encMovzImm16(17, kind));
                        try gpr.writeU32(a, b, inst.encStrImmW(17, abi.runtime_ptr_save_gpr, jit_abi.trap_kind_off));
                        try gpr.writeU32(a, b, inst.encMovzImm16(0, 0));
                        if (fb > 0) {
                            const fb_high: u12 = @intCast((fb >> 12) & 0xFFF);
                            const fb_low: u12 = @intCast(fb & 0xFFF);
                            if (fb_high != 0) try gpr.writeU32(a, b, inst.encAddImm12Lsl12(31, 31, fb_high));
                            if (fb_low != 0) try gpr.writeU32(a, b, inst.encAddImm12(31, 31, fb_low));
                        }
                        try gpr.writeU32(a, b, encLdpFpLrPostIdx());
                        try gpr.writeU32(a, b, inst.encRet(abi.link_register));
                        for (fixups) |fx_byte| {
                            const disp_words: i32 = @divExact(
                                @as(i32, @intCast(stub_byte)) - @as(i32, @intCast(fx_byte)),
                                4,
                            );
                            const orig = std.mem.readInt(u32, b.items[fx_byte..][0..4], .little);
                            // Opcode-shape dispatch (mirror of the generic stub patch):
                            //   bits 31..26 == 0b000101 → unconditional B (`unreachable`);
                            //   else                    → B.cond (call_indirect variants).
                            const new_word: u32 = if ((orig >> 26) == 0b000101)
                                inst.encB(disp_words)
                            else blk: {
                                const cond: inst.Cond = @enumFromInt(@as(u4, @intCast(orig & 0xF)));
                                break :blk inst.encBCond(cond, disp_words);
                            };
                            std.mem.writeInt(u32, b.items[fx_byte..][0..4], new_word, .little);
                        }
                    }
                };
                try EmitCindStub.emit(allocator, &buf, cind_bounds_fixups.items, 2, frame_bytes);
                try EmitCindStub.emit(allocator, &buf, cind_sig_fixups.items, 3, frame_bytes);
                // D-294 — call_indirect null-element (uninitialized_elem, code 13).
                try EmitCindStub.emit(allocator, &buf, uninit_elem_fixups.items, 13, frame_bytes);
                // ADR-0164 A / D-292 — `unreachable` (5) + div-by-zero (7) +
                // div_s signed-overflow (8) stubs (interp-parity per-kind codes).
                try EmitCindStub.emit(allocator, &buf, unreach_fixups.items, 5, frame_bytes);
                try EmitCindStub.emit(allocator, &buf, divzero_fixups.items, 7, frame_bytes);
                try EmitCindStub.emit(allocator, &buf, overflow_fixups.items, 8, frame_bytes);
                // D-303 — atomic load/store unaligned-access (B.NE → code 14 = unaligned_atomic).
                try EmitCindStub.emit(allocator, &buf, unaligned_atomic_fixups.items, 14, frame_bytes);
                // D-293 slice-3 — trapping-trunc NaN (B.VS → code 9 = invalid_conversion).
                try EmitCindStub.emit(allocator, &buf, invalid_conv_fixups.items, 9, frame_bytes);
                // D-293 slice-4b — call_ref-null + ref.as_non_null (B.EQ → code 10 = null_reference).
                try EmitCindStub.emit(allocator, &buf, null_ref_fixups.items, 10, frame_bytes);
                // D-293 slice-4d — ref.cast / ref.cast_null subtype mismatch (B.EQ → code 11 = cast_failure).
                try EmitCindStub.emit(allocator, &buf, cast_fail_fixups.items, 11, frame_bytes);
                // D-292 C — throw / throw_ref uncaught exception (unconditional B → code 12).
                try EmitCindStub.emit(allocator, &buf, uncaught_exc_fixups.items, 12, frame_bytes);
                // ADR-0202 D3 — capture the oob (kind=6) stub's byte offset for
                // the trap registry's PC-redirect target. `EmitCindStub.emit`
                // sets stub_byte = b.items.len on entry then skips emission when
                // there are no fixups AND no force, so buf.items.len HERE is that
                // same offset (or no_stub when no stub is emitted). D4: elision
                // FORCE-emits the stub — with the CMP gone there are no fixups,
                // but the fault handler still needs the redirect target.
                const force_oob_stub = bounds_elided;
                if (oob_fixups.items.len > 0 or force_oob_stub) oob_stub_off = @intCast(buf.items.len);
                try EmitCindStub.emitForce(allocator, &buf, oob_fixups.items, 6, frame_bytes, force_oob_stub);
                // ADR-0179 #3a / D-314 — loop back-edge interrupt poll stub
                // (code 16, POST-frame → fb=frame_bytes; distinct from the
                // prologue interrupt stub which is fb=0).
                try EmitCindStub.emit(allocator, &buf, back_edge_interrupt_fixups.items, 16, frame_bytes);
                // ADR-0179 #3b / D-314 — loop back-edge fuel poll stub
                // (code 17, POST-frame → fb=frame_bytes).
                try EmitCindStub.emit(allocator, &buf, back_edge_fuel_fixups.items, 17, frame_bytes);
                // ADR-0105 D3 — stack-overflow trap stub. Probe fired
                // BEFORE `SUB SP, SP, frame_bytes`, so the stub must
                // NOT add frame_bytes back (SP is still at the post-
                // STP-FP/LR position). Mirrors EmitCindStub shape with
                // fb=0 + kind=4 (new code; 0=unmarked, 1=generic, 2=
                // cind-bounds, 3=cind-sig, 4=stack-overflow).
                try EmitCindStub.emit(allocator, &buf, &.{stack_probe_fixup}, 4, 0);
                // ADR-0179 #3a / D-314 — cooperative-interruption stub (code 16).
                // Fires at the same pre-frame position as the stack probe → fb=0.
                try EmitCindStub.emit(allocator, &buf, &.{interrupt_probe_fixup}, 16, 0);
                // ADR-0179 #3b / D-314 — prologue out-of-fuel stub (code 17, fb=0).
                try EmitCindStub.emit(allocator, &buf, &.{fuel_probe_fixup}, 17, 0);
                // SIMD const-pool flush +
                // LDR-Q-literal imm19 fixups (per ADR-0042 + ADR-0051).
                // After the trap stub, if any v128.const / i8x16.shuffle
                // / emit-time-derived ops emitted LDR-Q-literal
                // placeholders, append the per-function const-pool
                // 16-byte aligned and patch each placeholder. The pool
                // is the concatenation of `func.simd_consts`
                // (lower-time) followed by `extra_consts` (emit-time);
                // const_idx is a flat index across both ranges with
                // `simd_consts_base` as the boundary.
                if (simd_const_fixups.items.len > 0) {
                    if (func.simd_consts == null and extra_consts.items.len == 0) {
                        dbg.print("codegen", "arm64/emit: simd_const_fixups present but both simd_consts and extra_consts are empty\n", .{});
                        return Error.AllocationMissing;
                    }
                    // Pad to 16-byte alignment.
                    while (buf.items.len % 16 != 0) try buf.append(allocator, 0);
                    const pool_byte: u32 = @intCast(buf.items.len);
                    if (func.simd_consts) |consts| {
                        for (consts) |c| try buf.appendSlice(allocator, &c);
                    }
                    for (extra_consts.items) |c| try buf.appendSlice(allocator, &c);
                    // Patch each LDR-Q-literal's imm19 to point at
                    // its const-pool entry (signed offset / 4 bytes).
                    for (simd_const_fixups.items) |fx| {
                        const target_byte: u32 = pool_byte + fx.const_idx * 16;
                        const disp_words: i32 = @divExact(
                            @as(i32, @intCast(target_byte)) - @as(i32, @intCast(fx.byte_offset)),
                            4,
                        );
                        const orig = std.mem.readInt(u32, buf.items[fx.byte_offset..][0..4], .little);
                        const patched = inst_neon.patchLdrLiteralQImm19(orig, @intCast(disp_words));
                        std.mem.writeInt(u32, buf.items[fx.byte_offset..][0..4], patched, .little);
                    }
                }
                break;
            },
            // SIMD-128 MVP catalogue per ADR-0041.
            .@"v128.load" => try op_simd.emitV128Load(&ctx, &ins),
            .@"v128.store" => try op_simd.emitV128Store(&ctx, &ins),
            // v128 mem op family (load_zero / load_splat / load_extend).
            .@"v128.load32_zero" => try op_simd.emitV128Load32Zero(&ctx, &ins),
            .@"v128.load64_zero" => try op_simd.emitV128Load64Zero(&ctx, &ins),
            .@"v128.load8_splat" => try op_simd.emitV128Load8Splat(&ctx, &ins),
            .@"v128.load16_splat" => try op_simd.emitV128Load16Splat(&ctx, &ins),
            .@"v128.load32_splat" => try op_simd.emitV128Load32Splat(&ctx, &ins),
            .@"v128.load64_splat" => try op_simd.emitV128Load64Splat(&ctx, &ins),
            .@"v128.load8x8_s" => try op_simd.emitV128Load8x8S(&ctx, &ins),
            .@"v128.load8x8_u" => try op_simd.emitV128Load8x8U(&ctx, &ins),
            .@"v128.load16x4_s" => try op_simd.emitV128Load16x4S(&ctx, &ins),
            .@"v128.load16x4_u" => try op_simd.emitV128Load16x4U(&ctx, &ins),
            .@"v128.load32x2_s" => try op_simd.emitV128Load32x2S(&ctx, &ins),
            .@"v128.load32x2_u" => try op_simd.emitV128Load32x2U(&ctx, &ins),
            // v128 lane mem family (load_lane × 4,
            // store_lane × 4) sharing v128MemPrologue + scalar
            // load/store + INS/UMOV per Wasm spec §4.4.7.4 / §4.4.7.5.
            .@"v128.load8_lane" => try op_simd.emitV128Load8Lane(&ctx, &ins),
            .@"v128.load16_lane" => try op_simd.emitV128Load16Lane(&ctx, &ins),
            .@"v128.load32_lane" => try op_simd.emitV128Load32Lane(&ctx, &ins),
            .@"v128.load64_lane" => try op_simd.emitV128Load64Lane(&ctx, &ins),
            .@"v128.store8_lane" => try op_simd.emitV128Store8Lane(&ctx, &ins),
            .@"v128.store16_lane" => try op_simd.emitV128Store16Lane(&ctx, &ins),
            .@"v128.store32_lane" => try op_simd.emitV128Store32Lane(&ctx, &ins),
            .@"v128.store64_lane" => try op_simd.emitV128Store64Lane(&ctx, &ins),
            // Splat handlers for all 6 shapes.
            .@"i32x4.extract_lane" => try op_simd_int_cmp_lane.emitI32x4ExtractLane(&ctx, &ins),
            .@"i32x4.replace_lane" => try op_simd_int_cmp_lane.emitI32x4ReplaceLane(&ctx, &ins),
            // v128 bitwise (AND / OR / XOR / ANDNOT
            // / NOT / BITSELECT). Per Wasm spec §4.4 (bitwise SIMD)
            // + Arm IHI 0055 §C7.2.{6, 34, 39, 93, 244} (NEON
            // AND/BIC/BSL/EOR/MVN). x86_64 mirror at op_simd.zig.
            // Int-arith ADD/SUB across all 4 shapes.
            // (i64x2.mul dispatch lives below.)
            // Int min/max + avgr_u (14 ops). NEON
            // has no .2D form for these (and Wasm spec correspondingly
            // has no i64x2 min/max/avgr); i32x4.avgr_u also doesn't
            // exist in the Wasm proposal.
            // Int shifts (12 ops).
            // v128 reductions (any_true / all_true).
            // i*x*.bitmask (per ADR-0051; uses
            // emit-time-derived per-shape masks via extra_consts).
            // Int unops (abs / neg / popcnt).
            // Int lane access for B/H/D element forms.
            // i32x4 wired above; f32x4/f64x2 +
            // i64x2.mul below.
            .@"i8x16.extract_lane_s" => try op_simd_int_cmp_lane.emitI8x16ExtractLaneS(&ctx, &ins),
            .@"i8x16.extract_lane_u" => try op_simd_int_cmp_lane.emitI8x16ExtractLaneU(&ctx, &ins),
            .@"i8x16.replace_lane" => try op_simd_int_cmp_lane.emitI8x16ReplaceLane(&ctx, &ins),
            .@"i16x8.extract_lane_s" => try op_simd_int_cmp_lane.emitI16x8ExtractLaneS(&ctx, &ins),
            .@"i16x8.extract_lane_u" => try op_simd_int_cmp_lane.emitI16x8ExtractLaneU(&ctx, &ins),
            .@"i16x8.replace_lane" => try op_simd_int_cmp_lane.emitI16x8ReplaceLane(&ctx, &ins),
            .@"i64x2.extract_lane" => try op_simd_int_cmp_lane.emitI64x2ExtractLane(&ctx, &ins),
            .@"i64x2.replace_lane" => try op_simd_int_cmp_lane.emitI64x2ReplaceLane(&ctx, &ins),
            // f32x4 / f64x2 lane access. i64x2.mul
            // synthesis below (scratch-reg conv).
            .@"f32x4.extract_lane" => try op_simd_float.emitF32x4ExtractLane(&ctx, &ins),
            .@"f32x4.replace_lane" => try op_simd_float.emitF32x4ReplaceLane(&ctx, &ins),
            .@"f64x2.extract_lane" => try op_simd_float.emitF64x2ExtractLane(&ctx, &ins),
            .@"f64x2.replace_lane" => try op_simd_float.emitF64x2ReplaceLane(&ctx, &ins),
            // i64x2.mul multi-instr synthesis.
            .@"i64x2.mul" => try op_simd_int_arith.emitI64x2Mul(&ctx, &ins),
            // f32x4 / f64x2 binary FP arithmetic.
            // f32x4/f64x2 unary FP arithmetic.
            // f32x4/f64x2 min/max (NaN-propagating).
            // f32x4/f64x2 pmin/pmax synthesis (FCMGT + BSL).
            // Int per-lane compares (CMEQ/CMGT/CMGE/CMHI/CMHS family).
            // FP per-lane compares (FCMEQ/FCMGT/FCMGE).
            // i8x16.swizzle via NEON TBL (1-register form).
            // Extend low/high (SXTL/SXTL2/UXTL/UXTL2).
            // Saturating narrow (SQXTN/SQXTUN family).
            // i→f FP convert (SCVTF/UCVTF family).
            .@"f64x2.convert_low_i32x4_u" => try op_simd_float.emitF64x2ConvertLowI32x4U(&ctx, &ins),
            // FP promote/demote (FCVTL/FCVTN).
            // trunc_sat (FCVTZS/U + SQXTN/UQXTN family).
            .@"i32x4.trunc_sat_f64x2_s_zero" => try op_simd_float.emitI32x4TruncSatF64x2SZero(&ctx, &ins),
            .@"i32x4.trunc_sat_f64x2_u_zero" => try op_simd_float.emitI32x4TruncSatF64x2UZero(&ctx, &ins),
            // STRICT (non-relaxed) f32↔i32 + f64.convert_low_s conversions (D-457).
            // Handlers are complete + shared with the relaxed-simd variants below
            // (NEON SCVTF/UCVTF/FCVTZS/FCVTZU saturate per Wasm spec §4.3.2); only
            // the dispatch wiring was missing, so they never ran (validate also
            // rejected them pre-79fd589e).
            .@"f32x4.convert_i32x4_s" => try op_simd_float.emitF32x4ConvertI32x4S(&ctx, &ins),
            .@"f32x4.convert_i32x4_u" => try op_simd_float.emitF32x4ConvertI32x4U(&ctx, &ins),
            .@"f64x2.convert_low_i32x4_s" => try op_simd_float.emitF64x2ConvertLowI32x4S(&ctx, &ins),
            .@"i32x4.trunc_sat_f32x4_s" => try op_simd_float.emitI32x4TruncSatF32x4S(&ctx, &ins),
            .@"i32x4.trunc_sat_f32x4_u" => try op_simd_float.emitI32x4TruncSatF32x4U(&ctx, &ins),
            // Remaining float conversions + rounding + narrow + i64x2.extmul
            // (D-457 systemic close): handlers complete on both arches, only the
            // dispatch was unwired — the old corpus never had simd_conversions /
            // *_rounding / simd_i64x2_extmul_i32x4, so the gap stayed hidden.
            .@"f32x4.demote_f64x2_zero" => try op_simd_float.emitF32x4DemoteF64x2Zero(&ctx, &ins),
            .@"f64x2.promote_low_f32x4" => try op_simd_float.emitF64x2PromoteLowF32x4(&ctx, &ins),
            // FP rounding (FRINTP/M/Z/N).
            .@"f32x4.ceil" => try op_simd_float.emitF32x4Ceil(&ctx, &ins),
            .@"f32x4.floor" => try op_simd_float.emitF32x4Floor(&ctx, &ins),
            .@"f32x4.trunc" => try op_simd_float.emitF32x4Trunc(&ctx, &ins),
            .@"f32x4.nearest" => try op_simd_float.emitF32x4Nearest(&ctx, &ins),
            .@"f64x2.ceil" => try op_simd_float.emitF64x2Ceil(&ctx, &ins),
            .@"f64x2.floor" => try op_simd_float.emitF64x2Floor(&ctx, &ins),
            .@"f64x2.trunc" => try op_simd_float.emitF64x2Trunc(&ctx, &ins),
            .@"f64x2.nearest" => try op_simd_float.emitF64x2Nearest(&ctx, &ins),
            // Saturating narrow (SQXTN/SQXTUN family).
            .@"i8x16.narrow_i16x8_s" => try op_simd_int_cmp_lane.emitI8x16NarrowI16x8S(&ctx, &ins),
            .@"i8x16.narrow_i16x8_u" => try op_simd_int_cmp_lane.emitI8x16NarrowI16x8U(&ctx, &ins),
            .@"i16x8.narrow_i32x4_s" => try op_simd_int_cmp_lane.emitI16x8NarrowI32x4S(&ctx, &ins),
            .@"i16x8.narrow_i32x4_u" => try op_simd_int_cmp_lane.emitI16x8NarrowI32x4U(&ctx, &ins),
            // i64x2.extmul (SMULL/UMULL + SMULL2/UMULL2).
            .@"i64x2.extmul_low_i32x4_s" => try op_simd_int_arith.emitI64x2ExtmulLowI32x4S(&ctx, &ins),
            .@"i64x2.extmul_high_i32x4_s" => try op_simd_int_arith.emitI64x2ExtmulHighI32x4S(&ctx, &ins),
            .@"i64x2.extmul_low_i32x4_u" => try op_simd_int_arith.emitI64x2ExtmulLowI32x4U(&ctx, &ins),
            .@"i64x2.extmul_high_i32x4_u" => try op_simd_int_arith.emitI64x2ExtmulHighI32x4U(&ctx, &ins),
            // relaxed-SIMD trunc — NaN/OOB → saturating clamp (v2 choice),
            // behaviourally identical to trunc_sat; reuse those emits.
            .@"i32x4.relaxed_trunc_f32x4_s" => try op_simd_float.emitI32x4TruncSatF32x4S(&ctx, &ins),
            .@"i32x4.relaxed_trunc_f32x4_u" => try op_simd_float.emitI32x4TruncSatF32x4U(&ctx, &ins),
            .@"i32x4.relaxed_trunc_f64x2_s_zero" => try op_simd_float.emitI32x4TruncSatF64x2SZero(&ctx, &ins),
            .@"i32x4.relaxed_trunc_f64x2_u_zero" => try op_simd_float.emitI32x4TruncSatF64x2UZero(&ctx, &ins),
            // relaxed-SIMD min/max — raw hardware FMIN/FMAX (NEON is
            // already NaN-propagating); identical to strict on arm64 (ADR-0169).
            .@"f32x4.relaxed_min" => try op_simd_float.emitF32x4Min(&ctx, &ins),
            .@"f32x4.relaxed_max" => try op_simd_float.emitF32x4Max(&ctx, &ins),
            .@"f64x2.relaxed_min" => try op_simd_float.emitF64x2Min(&ctx, &ins),
            .@"f64x2.relaxed_max" => try op_simd_float.emitF64x2Max(&ctx, &ins),
            // relaxed-SIMD madd/nmadd — fused FMLA/FMLS (3-operand).
            .@"f32x4.relaxed_madd" => try op_simd_float.emitF32x4RelaxedMadd(&ctx, &ins),
            .@"f32x4.relaxed_nmadd" => try op_simd_float.emitF32x4RelaxedNmadd(&ctx, &ins),
            .@"f64x2.relaxed_madd" => try op_simd_float.emitF64x2RelaxedMadd(&ctx, &ins),
            .@"f64x2.relaxed_nmadd" => try op_simd_float.emitF64x2RelaxedNmadd(&ctx, &ins),
            // relaxed-SIMD laneselect — full bitwise (a&m)|(b&~m) = exactly
            // v128.bitselect (ADR-0169 full-bitselect choice); lane width irrelevant.
            .@"i8x16.relaxed_laneselect",
            .@"i16x8.relaxed_laneselect",
            .@"i32x4.relaxed_laneselect",
            .@"i64x2.relaxed_laneselect",
            => try op_simd.emitV128Bitselect(&ctx, &ins),
            // relaxed-SIMD q15mulr — overflow (INT16_MIN²) → INT16_MAX =
            // strict SQRDMULH saturation (ADR-0169); reuse strict q15mulr_sat_s.
            .@"i16x8.relaxed_q15mulr_s" => try op_simd_int_arith.emitI16x8Q15mulrSatS(&ctx, &ins),
            // relaxed-SIMD dot (i8×i8 → i16x8 pairwise): SMULL/SMULL2/ADDP.8H.
            .@"i16x8.relaxed_dot_i8x16_i7x16_s" => try op_simd_int_arith.emitI16x8RelaxedDot(&ctx, &ins),
            // relaxed-SIMD dot+accumulate (4-way i8 dot + c): + SADDLP.4S + ADD.4S.
            .@"i32x4.relaxed_dot_i8x16_i7x16_add_s" => try op_simd_int_arith.emitI32x4RelaxedDotAdd(&ctx, &ins),
            // v128.const + i8x16.shuffle (per ADR-0042
            // const-pool with PC-relative LDR-Q-literal + fixup pass).
            .@"v128.const" => try op_simd.emitV128Const(&ctx, &ins),
            .@"i8x16.shuffle" => try op_simd_int_cmp_lane.emitI8x16Shuffle(&ctx, &ins),

            else => {
                // Surface the unhandled op
                // tag to stderr so the spec-jit-compile-runner's
                // /tmp/<host>.log captures which Wasm op the
                // emit pass doesn't know yet. Without this, every
                // missing-op fixture reports the opaque
                // `UnsupportedOp` and triaging requires hand
                // bisecting the body.
                dbg.print(
                    "codegen",
                    "arm64/emit: unsupported op `{s}` (func_idx={d})\n",
                    .{ @tagName(ins.op), func.func_idx },
                );
                return Error.UnsupportedOp;
            },
        }
    }

    // ADR-0155 stage 1 lockstep guard: every temporary vreg emit mints in the
    // body walk must stay BELOW the homed pseudo-vreg base `n_temp` (= slots.len
    // - homing.count), so a temporary never aliases a homed local's register
    // slot. Emit may mint FEWER than n_temp temporaries (transparent ops like
    // ref.as_non_null push nothing), so the bound is `<=`, not `==`. A
    // violation = the liveness↔emit numbering divergence the spike hit.
    std.debug.assert(next_vreg <= n_temp);

    // Harvest the per-function EH handler entries into an
    // owned slice; the Builder.entries ArrayList transfers ownership
    // here so the surrounding `defer eh_builder.deinit(allocator)`
    // becomes a no-op for the entries slot (it still frees nothing
    // extra). Empty slice for non-EH functions.
    const exception_handlers: []const exception_table.HandlerEntry = if (has_try_table)
        try eh_builder.entries.toOwnedSlice(allocator)
    else
        &[_]exception_table.HandlerEntry{};

    return .{
        .bytes = try buf.toOwnedSlice(allocator),
        .n_slots = alloc.n_slots,
        .call_fixups = try call_fixups.toOwnedSlice(allocator),
        .exception_handlers = exception_handlers,
        .frame_bytes = frame_bytes,
        .oob_stub_off = oob_stub_off,
    };
}

// ============================================================
// AAPCS64 prologue / epilogue micro-encodings
//
// These are the four fixed encodings every leaf function body
// uses. Inlined here rather than added to inst.zig because
// they're convention-shaped (always the same operands) — adding
// a dedicated enc* in inst.zig would invite false flexibility.
// ============================================================

/// `STP X29, X30, [SP, #-16]!` — pre-index push of FP/LR pair.
/// Encoding (STP 64-bit pre-indexed):
///   `1010 1001 10 [imm7:7] [Rt2:5] [Rn:5] [Rt:5]`
/// imm7 = -16/8 = -2 (signed) = 7'b1111110 = 0x7E.
/// Rn = 31 (SP), Rt = 29 (FP), Rt2 = 30 (LR).
fn encStpFpLrPreIdx() u32 {
    // 0xA9BF7BFD = STP X29, X30, [SP, #-16]!
    return 0xA9BF7BFD;
}

/// Look up the declared Wasm value-type at a local index (params
/// followed by declared locals; per D-033 fix). Caller has already
/// validated `local_idx < total_locals`.
fn localValType(func: *const ZirFunc, num_params: u32, local_idx: u32) zir.ValType {
    _ = num_params;
    return func.localValType(local_idx);
}

/// `LDP X29, X30, [SP], #16` — post-index pop of FP/LR pair.
/// Encoding (LDP 64-bit post-indexed):
///   `1010 1000 11 [imm7:7] [Rt2:5] [Rn:5] [Rt:5]`
/// imm7 = +16/8 = 2.
fn encLdpFpLrPostIdx() u32 {
    // 0xA8C17BFD = LDP X29, X30, [SP], #16
    return 0xA8C17BFD;
}

/// `MOV X29, SP` — encoded as `ADD X29, SP, #0` (the canonical
/// MOV between SP-form and a register).
/// Encoding (ADD 64-bit imm, sh=0): `1 00 10001 00 0 0000 0000 0000 [Rn:5] [Rd:5]`
/// Rn = 31 (SP), Rd = 29 (FP).
fn encMovSpToFp() u32 {
    // 0x910003FD = mov x29, sp
    return 0x910003FD;
}
