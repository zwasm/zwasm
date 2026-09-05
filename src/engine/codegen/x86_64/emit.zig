// FILE-SIZE-EXEMPT: x86_64 emit driver (prologue + epilogue + dispatch); P1 SysV/Win64 spec-defined emit boundary; per-op handlers already extracted to op_*.zig sibling files (per ADR-0099)
//! x86_64 emit pass — skeleton.
//!
//! Mirrors the role of `arm64/emit.zig`'s `compile()` entry but
//! covers the minimal `(i32.const N) end` cycle to prove the
//! ZIR → x86_64 byte-stream pipeline end-to-end. Subsequent
//! chunks layer on op coverage (i32 ALU, memory, control flow,
//! calls, FP) and the reserved_invariant_gprs reservation
//! decision.
//!
//! Skeleton scope (this commit):
//! - Function prologue: PUSH RBP ; MOV RBP, RSP (no SUB RSP yet
//!   — locals + spills land with the regalloc port).
//! - `i32.const N` → MOV r32(slot 0), #N (zero-extended to 64 by
//!   the W-form of MOV-imm).
//! - Function-level `end` → MOV EAX, r32(top vreg) ; POP RBP ;
//!   RET. EAX is RAX low 32 bits — Wasm i32 return per SysV
//!   x86_64 §3.2.4.
//!
//! What's INTENTIONALLY NOT in this skeleton:
//! - Multi-call X0-style runtime_ptr restore: arm64's ADR-0017
//!   sub-2d-ii doesn't apply here yet because there are no
//!   calls. The reserved_invariant_gprs decision (load-once at
//!   prologue vs reload-from-runtime-ptr at point of use) lands
//!   when the first call / memory op handler arrives.
//! - Frame extension for locals / spills (no LOCAL ops in the
//!   skeleton — `func.locals.len > 0` → `UnsupportedOp`).
//! - Call fixups (no `call` ops — `EmitOutput.call_fixups` is
//!   declared but always empty in this chunk).
//! - Bounds-check trap stub (no memory ops yet).
//! - Label / control flow stack (no `block` / `loop` / `br`
//!   / `if` ops).
//!
//! The shape mirrors arm64/emit.zig (compile() returns
//! EmitOutput; `func.liveness` must agree with `alloc.slots`)
//! so the three-way differential can compare ARM64
//! and x86_64 outputs at the same byte-stream layer.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const std = @import("std");
const liveness_parity = @import("../shared/liveness_parity.zig");
const dbg = @import("../../../support/dbg.zig");
const call_profile = @import("../../../support/call_profile.zig");

const zir = @import("../../../ir/zir.zig");
const sections = @import("../../../parse/sections.zig");
const dispatch_collector = @import("../dispatch_collector.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const usage = @import("usage.zig");
const abi = @import("abi.zig");
const build_options = @import("build_options");
// D-231 — comptime build-level guard (arm64 parity, emit.zig:73). The
// D-239 br_on_null cohort below is in the legacy switch (not the
// dispatch_collector's comptime `enabledByBuild`), so it needs an explicit
// `if (comptime wasm_v3_plus)` to DCE in `-Dwasm=v1_0` — else the x86_64 v1_0
// binary retains dead wasm_3_0 codegen (caught by check_build_dce on x86).
const wasm_v3_plus = @intFromEnum(build_options.wasm_level) >=
    @intFromEnum(@TypeOf(build_options.wasm_level).v3_0);
const jit_abi = @import("../shared/jit_abi.zig");
const exception_table = @import("../shared/exception_table.zig");
const types = @import("types.zig");
const ctx_mod = @import("ctx.zig");
const label_mod = @import("label.zig");
const op_alu_int = @import("op_alu_int.zig");
const op_alu_float = @import("op_alu_float.zig");
const op_convert = @import("op_convert.zig");
const op_call = @import("op_call.zig");
// D-239 — function-references null-ref branch ops (handler files existed
// but were never wired into the dispatch → UnsupportedOp). Arm64 parity.
const op_br_on_null = @import("ops/wasm_3_0/br_on_null.zig");
const op_br_on_non_null = @import("ops/wasm_3_0/br_on_non_null.zig");
const op_ref_as_non_null = @import("ops/wasm_3_0/ref_as_non_null.zig");
const op_memory = @import("op_memory.zig");
const op_control = @import("op_control.zig");
const op_simd = @import("op_simd.zig");
const op_simd_int_arith = @import("op_simd_int_arith.zig");
const op_simd_int_cmp_lane = @import("op_simd_int_cmp_lane.zig");
const op_simd_float = @import("op_simd_float.zig");
const rbp_disp = @import("rbp_disp.zig");
const gpr = @import("gpr.zig");
const local_homing = @import("../../../ir/analysis/local_homing.zig");

// rbp/rsp form-selectors live in rbp_disp.zig per D-052
// progression (extract when emit.zig approached the 2000-LOC
// hard cap). Call-site shape is unchanged.
const rbpStoreR32 = rbp_disp.rbpStoreR32;
const rbpLoadR32 = rbp_disp.rbpLoadR32;
const rbpStoreR64 = rbp_disp.rbpStoreR64;
const rbpLoadR64 = rbp_disp.rbpLoadR64;
const rbpStoreXmmF32 = rbp_disp.rbpStoreXmmF32;
const rbpLoadXmmF32 = rbp_disp.rbpLoadXmmF32;
const rbpStoreXmmF64 = rbp_disp.rbpStoreXmmF64;
const rbpLoadXmmF64 = rbp_disp.rbpLoadXmmF64;
const rbpStoreXmmV128 = rbp_disp.rbpStoreXmmV128;
const rbpLoadXmmV128 = rbp_disp.rbpLoadXmmV128;
const rspSub = rbp_disp.rspSub;
const rspAdd = rbp_disp.rspAdd;

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;

// Re-exports from `types.zig` (D-030 chunk-a) — external callers
// (`src/zwasm.zig`, `src/diagnostic/trace.zig`, the linker) and
// the inner emit-pass code keep referencing these via the original
// `x86_64/emit.zig` paths.
pub const Error = types.Error;
pub const CallFixup = types.CallFixup;
pub const EmitOutput = types.EmitOutput;
pub const deinit = types.deinit;

// Internal types from `label.zig` (D-030 chunk-a). Aliased so the
// dispatch loop body keeps reading like the pre-split code.
const LabelKind = label_mod.LabelKind;
const Fixup = label_mod.Fixup;
const Label = label_mod.Label;

// Setup-phase helpers extracted to `emit_setup.zig` per ADR-0081
// Phase 1. Aliases here keep `compile()` call sites unchanged.
// `localDisp` is re-exported below as `pub const` for test files
// that reference `emit.localDisp` directly.
const setup = @import("emit_setup.zig");
const computeOutgoingMaxBytes = setup.computeOutgoingMaxBytes;
const computeLocalLayout = setup.computeLocalLayout;
const LocalLayout = setup.LocalLayout;

// `win64V128ScratchBase` helper lives in `op_call.zig` (used by
// the caller-side marshal).

/// Emit x86_64 machine code for `func`. Requires `alloc.slots`
/// to be populated (call `regalloc.compute` first; pass the
/// `Allocation` here). `func_sigs` and `module_types` are
/// declared for shape-parity with arm64 but unused in this
/// skeleton (no `call` / `call_indirect` handlers yet).
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
    /// param counts threaded into EmitCtx via InitArgs for throw /
    /// try_table payload marshalling. Pass `&.{}` for tag-less modules.
    tag_param_counts: []const u32,
    /// D-235 — module-level func-subtyping flag (`usesTypeSubtyping`).
    /// Routes `call_indirect` through the subtype trampoline. `false` for
    /// non-subtyping modules + test helpers.
    uses_type_subtyping: bool,
    /// ADR-0202 D4 — elide the memory0 scalar bounds check + force-emit
    /// the kind=6 redirect stub. `false` for non-qualifying / `.explicit`.
    bounds_elided: bool,
) Error!EmitOutput {
    if (alloc.slots.len != (func.liveness orelse return Error.AllocationMissing).ranges.len) {
        return Error.AllocationMissing;
    }
    // Lift the params=0 reject. Mirrors
    // arm64/emit.zig:134 ("Multi-arg entry"). For now i32-only
    // params are supported; i64/f32/f64 surface UnsupportedOp
    // until the type-aware local + FP-marshal chunks land.
    // SysV reserves RDI for the runtime ptr (ADR-0026), so user
    // int args start at RSI (max 5). Win64 reserves RCX → user
    // int args start at RDX (max 3). The total runs through the
    // arch-specific `abi.current.arg_gprs` array, indexed past
    // the runtime-ptr save reg.
    const num_params: u32 = @intCast(func.sig.params.len);
    for (func.sig.params) |p| {
        switch (p) {
            // v128 is supported under both ABIs.
            // SysV uses direct XMM0..XMM7 + stack-overflow (16-byte
            // aligned eightbyte pair). Win64 uses hidden-pointer
            // marshal per Microsoft x64 ABI §"Parameter passing"
            // (`__m128` passed via pointer in int-arg reg slot;
            // ADR-0055).
            // D-093: reftype params share the i64 gpr-class
            // 8-byte slot per ADR-0061.
            .i32, .i64, .f32, .f64, .v128, .ref => {},
        }
    }
    const num_locals: u32 = func.totalLocalCount();
    const total_locals: u32 = num_params + num_locals;
    // localDisp now returns i32 + auto-helpers
    // pick disp8 / disp32 form per offset, so total_locals is no
    // longer capped at 15. Practical cap = i32 disp range / 8 =
    // ~268M slots — far past any realistic Wasm function.

    // Prescan: does this function need the runtime-ptr save?
    // Helper in `usage.zig`. Per ADR-0026
    // (D-087/088/089 cohort) — see helper doc for the full
    // op set.
    const uses_runtime_ptr = usage.usesRuntimePtr(func);

    // Frame-bytes formula depends on prologue shape (SysV §3.2.2
    // 16-byte stack alignment; CALL pushes ret addr → entry RSP
    // ≡ 8 mod 16; PUSH RBP → 0 mod 16; PUSH R15 → 8 mod 16):
    //   - 1-PUSH:  frame ≡ 0 mod 16  (current shape; rounds up locals_bytes to 16)
    //   - 2-PUSH:  frame ≡ 8 mod 16  (per ADR-0026 prologue)
    //
    // D-045 chunk 13b: extend frame by spill region. Layout
    // (frame grows DOWN from RBP):
    //   [RBP - 8]                     R15 save (if uses_runtime_ptr)
    //   [RBP - 8*(K+1)]               local K  (without R15)
    //   [RBP - 8 - 8*(K+1)]           local K  (with R15)
    //   [RBP - spill_base_off - off]  spill slot at offset `off`
    // `spill_base_off` = locals_bytes + (uses_runtime_ptr ? 8 : 0) + 8
    // (the +8 puts spill slot 0 in the next 8-byte cell below
    // the deepest local). `gpr.zig`'s `rbpDispNegI8` consumes it
    // as `disp = -(spill_base_off + spill_off)`.
    // Per-function frame layout (group-by-type).
    // Mirror of arm64/emit.zig's LocalLayout: scalars at 8-byte
    // stride, v128 at 16-byte stride. `base_off_for_locals` is
    // -8 if uses_runtime_ptr (R15 save occupies [RBP-8]) else 0;
    // disps[i] is the most-negative byte of v128 slot `i` (since
    // MOVUPS [RBP+disp] writes UPWARD from disp).
    const base_off_for_locals: i32 = if (uses_runtime_ptr) -8 else 0;
    var layout = try computeLocalLayout(allocator, func, base_off_for_locals);
    defer layout.deinit(allocator);
    const locals_bytes: u32 = layout.total_bytes;
    const spill_bytes: u32 = alloc.spillBytes();
    const r15_save_bytes: u32 = if (uses_runtime_ptr) 8 else 0;
    // ADR-0026 2026-05-18 amend (Convention Swap) / ADR-0069 §Phase 2:
    // MEMORY-class returns (struct > 16 B per SysV §3.2.3; v2
    // trigger = `sig.results.len > 2`) follow the standard SysV
    // §3.2.3 hidden-arg shape — RDI = &result_buffer, RSI = rt
    // (= the function's natural arg0 shifted one int-slot deeper).
    // ADR-0106: extended to Win64 — hidden ptr
    // in RCX (instead of RDI), rt in RDX (instead of RSI). The
    // epilogue's `[RAX + i*8]` write shape stays identical since
    // RAX is loaded from the captured-pointer frame slot.
    // Aligns with Zig's auto-generated `callconv(.c)` lowering for
    // struct returns > 16 B so entry.zig helpers don't need inline-
    // asm thunks. The prologue captures the hidden ptr into an
    // 8-byte frame slot positioned BELOW the spill region; the
    // epilogue (`marshalReturnRegs`) loads it into RAX and writes
    // each result to `[RAX + i*8]`.
    const return_is_memory_class: bool = func.sig.results.len > 2 and
        (abi.current_cc == .sysv or abi.current_cc == .win64);
    // ADR-0106 path (a) — buffer-write ABI also needs a
    // captured-pointer slot (for the results ptr passed in RSI on
    // SysV / RDX on Win64). Shares storage with the MEMORY-class
    // slot when only one applies; the buffer-write flag overrides
    // the rt_src_gpr selection in the prologue capture below.
    const buffer_write: bool = alloc.result_abi == .buffer_write;
    const indirect_result_slot_bytes: u32 = if (return_is_memory_class or buffer_write) 8 else 0;
    // ADR-0155 stage 4 (D-265 Phase IV) — register-homed-local callee-saved
    // save area. The x86_64 regalloc pool (`abi.allocatable_gprs`) is ALL
    // callee-saved (RBX/R12/R13/R14) — unlike arm64, whose first homed slots are
    // caller-saved scratch (X9..X13). A homed local therefore lives in a
    // callee-saved GPR the SysV/Win64 ABI requires this function to preserve for
    // its CALLER (the entry trampoline + any same-module caller, neither of which
    // lists RBX/R12-R14 as call-clobbered). The prologue MUST snapshot each used
    // home reg's incoming value before seeding it, and every return path MUST
    // restore it — else a call-free homed function corrupts the host's RBX (the
    // fac entry-trampoline miscompile) and a recursive homed call corrupts the
    // caller's home (the rust_fib `55 → 511` miscompile). One 8-byte slot per
    // homed local (homing.count is the upper bound; each homes a distinct reg).
    const homing_plan_pre = local_homing.plan(func);
    const home_save_count: u32 = if (alloc.slots.len >= homing_plan_pre.count) homing_plan_pre.count else 0;
    const home_save_bytes: u32 = home_save_count * 8;
    const spill_base_off: u32 = locals_bytes + r15_save_bytes + 8;
    // Buffer-ptr capture slot lives BELOW the spill region (deeper
    // into the frame, larger RBP-negative offset). Slot anchored at
    // `[RBP - (spill_base_off + spill_bytes)]`; the +8 below
    // gives the slot its own 8-byte cell.
    const indirect_result_slot_neg_off: u32 = spill_base_off + spill_bytes;
    // Home-save area occupies the DEEPEST `home_save_bytes` of the frame (below
    // locals + spill + indirect-result + r15-save), so rank j's slot is at
    // `[RBP - (locals + spill + indirect + r15 + (j+1)*8)]`. This base is the sum
    // of every non-outgoing, non-home frame component + 8 (the first cell); the
    // deepest slot (j = count-1) lands exactly at the bottom of the non-outgoing
    // region, which `frame_unaligned` covers via its `home_save_bytes` term. The
    // earlier anchor (off `indirect_result_slot_neg_off`, which carries
    // `spill_base_off`'s extra +8 reserved cell) over-reached the frame by 8 when
    // outgoing==0, putting the deepest save slot below RSP where the recursive
    // CALL's return-address push clobbered it.
    const home_save_base_neg_off: u32 = locals_bytes + spill_bytes + indirect_result_slot_bytes + r15_save_bytes + 8;
    const home_save_base_disp: i32 = -@as(i32, @intCast(home_save_base_neg_off));
    // Outgoing-args region pre-allocated at the
    // BOTTOM of the frame (`[RSP, #0]` upward). For SysV this is
    // pure overflow bytes; for Win64 it includes the 32-byte
    // shadow space when any call exists. When `outgoing_max_bytes`
    // > 0 the per-call `emitShadowAlloc` / `Free` become no-ops
    // (the shadow is already part of the prologue's SUB RSP).
    const outgoing_max_bytes: u32 = computeOutgoingMaxBytes(func, func_sigs, module_types);
    // D-054: include r15_save_bytes so local 0 at
    // [RBP-16] (when uses_runtime_ptr=true) lives INSIDE the frame.
    // The prologue does PUSH R15 before MOV RBP,RSP so R15 actually
    // saves at [RBP+0], NOT [RBP-8] — but localDisp's comment +
    // formula assume the slot at [RBP-8] is reserved for R15 (it
    // is, just above the locals). Without this +r15_save_bytes,
    // SysV (no shadow space) under-allocates and the next CALL's
    // pushed return address lands on local 0 at [RBP-16]. Win64's
    // 32-byte shadow_space inflates the frame enough that it hid
    // this bug until OrbStack runs (= Linux x86_64 SysV).
    const frame_unaligned: u32 = outgoing_max_bytes + locals_bytes + spill_bytes + indirect_result_slot_bytes + r15_save_bytes + home_save_bytes;
    const frame_bytes: u32 = if (uses_runtime_ptr)
        ((frame_unaligned + 7) & ~@as(u32, 15)) + 8
    else
        (frame_unaligned + 15) & ~@as(u32, 15);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Prologue:
    //   PUSH RBP
    //   PUSH R15           (only if uses_runtime_ptr; saves callee-saved R15)
    //   MOV RBP, RSP       (frame pointer captured AFTER any extra push)
    //   MOV R15, RDI       (only if uses_runtime_ptr; capture runtime_ptr arg)
    //   SUB RSP, frame_bytes
    //
    // Local layout (Wasm ZirFunc.locals): local K at
    //   [RBP - 8*(K+1)]               when !uses_runtime_ptr
    //   [RBP - 8 - 8*(K+1)]           when  uses_runtime_ptr (R15 occupies [RBP-8])
    try buf.appendSlice(allocator, inst.encPushR(.rbp).slice());
    if (uses_runtime_ptr) {
        try buf.appendSlice(allocator, inst.encPushR(.r15).slice());
    }
    try buf.appendSlice(allocator, inst.encMovRR(.q, .rbp, .rsp).slice());
    // D-489 call-count primitive (ZWASM_DEBUG=jit.callcount): per-function-entry
    // counter, bumped via an absolute-address `INC qword [&counts[idx]]`. RAX is
    // dead at prologue entry (not an arg reg) and RSP/RBP/frame are untouched, so
    // this has zero frame-layout impact. Compile-time gated → no cost when off.
    if (dbg.on("jit.callcount") and func.func_idx < call_profile.max_funcs) {
        const counts_addr: u64 = @intFromPtr(&call_profile.counts[func.func_idx]);
        try buf.appendSlice(allocator, inst.encMovImm64Q(.rax, counts_addr).slice());
        try buf.appendSlice(allocator, &.{ 0x48, 0xFF, 0x00 }); // INC qword ptr [RAX]
    }
    var stack_probe_fixup: u32 = 0;
    var interrupt_fixup: u32 = 0;
    var fuel_fixup: u32 = 0;
    if (uses_runtime_ptr) {
        // MOV R15, <runtime_ptr_arg_gpr> — entry shim's runtime_ptr
        // snapshot. Cc-pivot per ADR-0026: SysV passes *const
        // JitRuntime in RDI for non-MEMORY-class returns; for
        // MEMORY-class returns (ADR-0026 2026-05-18 Convention Swap)
        // SysV §3.2.3 inserts the hidden &buffer ptr into RDI and
        // shifts rt to RSI. Win64 passes in RCX (MEMORY-class Win64
        // deferred). Both encodings are 3 bytes (REX.W+B + opcode +
        // modrm) so the prologue's frame-bytes formula stays Cc-agnostic.
        // ADR-0106: Cc-aware MEMORY-class rt
        // source. SysV §3.2.3 shifts rt to RSI (slot 1) when slot 0
        // holds the hidden &buffer ptr (RDI). Win64 shifts rt to
        // RDX (slot 1) when slot 0 holds the hidden ptr (RCX).
        const rt_src_gpr: abi.Gpr = if (return_is_memory_class)
            (if (abi.current_cc == .win64) .rdx else .rsi)
        else
            abi.current.entry_arg0_gpr;
        try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.runtime_ptr_save_gpr, rt_src_gpr).slice());
        // ADR-0105 D2 — JIT-prologue stack-probe. Sibling to arm64's
        // probe at the same prologue position (per ADR-0105 D2 syntax
        // translated to Intel: `CMP RSP, [R15 + stack_limit_off]`
        // followed by `JBE rel32` to the stack-overflow trap stub).
        // When stack_limit = 0 (default; probe disabled), JBE never
        // fires since RSP > 0 always. Probe placed BEFORE the
        // jit_executed_flag sentinel so a probe-trap doesn't pollute
        // the "function executed" flag. Gated on uses_runtime_ptr
        // since the probe reads via R15. Functions without R15
        // cannot recurse (no `call` op → no `uses_runtime_ptr` per
        // `usage.usesRuntimePtr`) so they cannot stack-overflow.
        try buf.appendSlice(allocator, inst.encCmpR64MemDisp32(.rsp, .r15, @intCast(jit_abi.stack_limit_off)).slice());
        stack_probe_fixup = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.be, 0).slice());
        // ADR-0179 #3a / D-314 — cooperative-interruption poll (sibling to the
        // arm64 poll). Same pre-frame position as the probe (stub fb=0, no RSP
        // restore); reads via R15 so it lives inside the uses_runtime_ptr block.
        // MOV RAX←interrupt_ptr; TEST RAX,RAX; JZ skip (null = not configured);
        // MOV EAX←[RAX] (flag); TEST EAX,EAX; JNE → interrupted stub (kind 16).
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .r15, @intCast(jit_abi.interrupt_ptr_off)).slice());
        try buf.appendSlice(allocator, inst.encTestRR(.q, .rax, .rax).slice());
        const interrupt_skip_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
        try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(.rax, .rax, 0).slice());
        try buf.appendSlice(allocator, inst.encTestRR(.d, .rax, .rax).slice());
        interrupt_fixup = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, 0).slice());
        // Patch the JZ skip to land just after the JNE (skip the poll when null).
        const after_poll: u32 = @intCast(buf.items.len);
        inst.patchRel32(buf.items, interrupt_skip_at, 6, @as(i32, @intCast(after_poll)) - (@as(i32, @intCast(interrupt_skip_at)) + 6));
        // ADR-0179 #3b / D-314 — fuel poll (prologue crossing; arm64 sibling
        // in arm64/emit.zig). MOV R11D←fuel_metered; TEST; JZ skip (unmetered);
        // SUB QWORD [R15+fuel_cell_off],1 (sets SF); JS → out-of-fuel stub
        // (kind 17, fb=0 pre-frame). 30 bytes.
        try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(.r11, .r15, @intCast(jit_abi.fuel_metered_off)).slice());
        try buf.appendSlice(allocator, inst.encTestRR(.d, .r11, .r11).slice());
        const fuel_skip_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
        try buf.appendSlice(allocator, inst.encSubMem64Disp32Imm8(.r15, @intCast(jit_abi.fuel_cell_off), 1).slice());
        fuel_fixup = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.s, 0).slice());
        const after_fuel_poll: u32 = @intCast(buf.items.len);
        inst.patchRel32(buf.items, fuel_skip_at, 6, @as(i32, @intCast(after_fuel_poll)) - (@as(i32, @intCast(fuel_skip_at)) + 6));
        // (ADR-0034) — JIT-execution sentinel: write 1
        // to `JitRuntime.jit_executed_flag` so post-call readers can
        // distinguish "JIT body actually ran" from "compile-passed
        // but never invoked". `MOV DWORD PTR [R15 + flag_off], 1`
        // is 7 bytes (REX.B + C7 + ModR/M + disp32 + imm32). Gated on
        // uses_runtime_ptr because the sentinel uses R15. Mirrors
        // the ARM64 inject at d6e29ac (D-055 close).
        try buf.appendSlice(allocator, inst.encMovMemDisp32Imm32(.r15, jit_abi.jit_executed_flag_off, 1).slice());
    }
    if (frame_bytes > 0) {
        // Pick imm8 / imm32 form per range.
        // imm8 form is 4 bytes; imm32 is 7 bytes.
        try buf.appendSlice(allocator, rspSub(frame_bytes).slice());
    }
    // ADR-0026 2026-05-18 amend (Convention Swap) / ADR-0069 §Phase 2:
    // MEMORY-class returns — capture the caller-supplied SysV
    // hidden indirect-result-pointer (RDI per §3.2.3) into the
    // frame slot just below the spill region. Emitted AFTER
    // `SUB RSP, frame_bytes` so the slot offset is RBP-relative
    // and stable through the body. RDI's user value (= the
    // shifted runtime_ptr) was already stashed into R15 above;
    // this STR captures RDI itself for the epilogue's MEMORY-class
    // write path. Param shuffle below uses RDX/RCX/R8/R9 +
    // XMM0..XMM7 when self is MEMORY-class (slots 2-5 instead
    // of 1-5). The body's `gprLoadSpilled` staging through
    // R10/R11 is unaffected.
    // ADR-0106 path (a) — buffer_write takes precedence
    // over MEMORY-class. For `sig.results.len > 2` SysV buffer_write
    // both flags fire; we want RSI (results ptr) in the slot, not
    // RDI (the MEMORY-class hidden ptr).
    if (buffer_write) {
        const disp: i32 = -@as(i32, @intCast(indirect_result_slot_neg_off));
        const results_ptr_gpr: abi.Gpr = if (abi.current_cc == .win64) .rdx else .rsi;
        try buf.appendSlice(allocator, inst.encStoreR64MemRBPDisp32(disp, results_ptr_gpr).slice());
    } else if (return_is_memory_class) {
        const disp: i32 = -@as(i32, @intCast(indirect_result_slot_neg_off));
        // ADR-0106: Cc-aware MEMORY-class hidden-ptr
        // capture. SysV puts the hidden &buffer ptr in RDI (slot 0);
        // Win64 puts it in RCX (slot 0).
        const hidden_ptr_gpr: abi.Gpr = if (abi.current_cc == .win64) .rcx else .rdi;
        try buf.appendSlice(allocator, inst.encStoreR64MemRBPDisp32(disp, hidden_ptr_gpr).slice());
    }

    // Marshal i32 params from arg regs to
    // local slots. Per ADR-0026 Cc-pivot:
    //   SysV: arg_gprs = {RDI, RSI, RDX, RCX, R8, R9}; RDI = runtime
    //         ptr, user int args from RSI (max 5)
    //   Win64: arg_gprs = {RCX, RDX, R8, R9}; RCX = runtime ptr,
    //         user int args from RDX (max 3)
    // The base index into arg_gprs is set so index 0 of the user
    // params lands on the first non-runtime-ptr arg reg.
    param_marshal: {
        var p_idx: u32 = 0;
        // Cc-aware arg-reg index counters. SysV (§3.2.3) tracks
        // int and FP args independently — `int_arg_idx` starts
        // at 1 (skip runtime_ptr in RDI = arg_gprs[0]); FP args
        // use a separate `fp_arg_idx` from XMM0. Win64 (Microsoft
        // ABI) shares slot positions: arg N occupies either
        // arg_gprs[N] OR arg_xmms[N], so `fp_arg_idx` mirrors
        // the int-side slot counter and both advance per arg.
        // Win64 args at slot >= 4 land on the stack at
        // [RBP + 16 + 8*slot] (Microsoft x64 ABI §"Argument
        // Passing"); the prologue copies them via RAX scratch
        // into the local frame slot.
        // ADR-0026 2026-05-18 Convention Swap: when SELF returns
        // MEMORY-class, SysV §3.2.3 places &buffer in RDI (slot 0)
        // and shifts rt to RSI (slot 1); user int args begin at
        // RDX (slot 2). For non-MEMORY-class, slot 0 = RDI = rt;
        // user int args begin at RSI (slot 1).
        // ADR-0106 path (a) — buffer_write ABI: args
        // come from `[args_ptr + i*8]` (args_ptr in RDX on SysV
        // / R8 on Win64; the 3rd `callconv(.c)` arg after rt
        // (RDI/RCX) + results (RSI/RDX)). Skip the per-class
        // arg-reg shuffle for buffer_write. v128 deferred (a
        // u64 slot can't hold a 128-bit value).
        // Win64 deferred (R8 + shadow-space).
        if (buffer_write and abi.current_cc == .sysv) {
            while (p_idx < num_params) : (p_idx += 1) {
                const off: i32 = layout.disps[p_idx];
                const ptype = func.sig.params[p_idx];
                if (ptype == .v128) return Error.UnsupportedOp;
                // MOV RAX, [RDX + 8*p_idx]
                try buf.appendSlice(
                    allocator,
                    inst.encMovR64FromMemDisp32(.rax, .rdx, @intCast(p_idx * 8)).slice(),
                );
                switch (ptype) {
                    .i32 => try buf.appendSlice(allocator, rbpStoreR32(off, .rax).slice()),
                    .i64, .f32, .f64, .ref => try buf.appendSlice(allocator, rbpStoreR64(off, .rax).slice()),
                    .v128 => unreachable, // guarded above.
                }
            }
            // Skip the legacy per-class loop entirely.
            break :param_marshal;
        }
        var int_arg_idx: usize = if (return_is_memory_class) 2 else 1;
        var fp_arg_idx: usize = if (abi.current_cc == .win64) 1 else 0;
        // Per-overflow NSAA index for SysV. Mirror of
        // the caller-side counter in op_call.marshalCallArgs.
        // Both classes share the NSAA stream in declaration
        // order — increment per overflowed arg regardless of class.
        var nsaa_idx: u32 = 0;
        while (p_idx < num_params) : (p_idx += 1) {
            // Per-local disp from layout.
            // Auto-helpers pick disp8 / disp32 form per offset range.
            const off: i32 = layout.disps[p_idx];
            const ptype = func.sig.params[p_idx];
            switch (ptype) {
                .i32, .i64, .f32, .f64, .v128, .ref => {},
            }
            // Win64 stack-arg fallback for slot >= 4. The shared
            // slot is `int_arg_idx` (== `fp_arg_idx` under Win64).
            // Read from the shadow-space-relative location and
            // write to local slot.
            //   [RBP + 16 + r15_save_off + 8*slot]
            // where +16 = saved RBP (8) + return addr (8); the
            // +r15_save_off (8 bytes) covers our PUSH R15 prologue
            // shifting RBP one cell deeper than the std ABI shape.
            // Without it, [RBP + 48] (the standard "first overflow
            // at slot 4") reads the saved-RBP slot instead of
            // caller-written arg bytes when uses_runtime_ptr fires.
            if (abi.current_cc == .win64 and int_arg_idx >= abi.current.arg_gprs.len) {
                const r15_save_off: i32 = if (uses_runtime_ptr) 8 else 0;
                const stack_disp: i32 = 16 + r15_save_off + @as(i32, @intCast(int_arg_idx * 8));
                switch (ptype) {
                    .i32 => {
                        try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(.rax, .rbp, stack_disp).slice());
                        try buf.appendSlice(allocator, rbpStoreR32(off, .rax).slice());
                    },
                    // D-093 (d-33): reftype shares i64 8-byte gpr slot.
                    .i64, .f32, .f64, .ref => {
                        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rbp, stack_disp).slice());
                        try buf.appendSlice(allocator, rbpStoreR64(off, .rax).slice());
                    },
                    .v128 => {
                        // Win64 v128 hidden-pointer
                        // marshal — stack-overflow slot. Per Microsoft
                        // x64 ABI §"Parameter passing" the caller wrote
                        // an 8-byte pointer at the int-arg stack slot;
                        // the pointed-to memory holds the 16-byte v128
                        // value (16-byte aligned per ABI). Load pointer
                        // → RAX, then MOVUPS xmm_tmp ← [RAX] and store
                        // to local slot.
                        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rbp, stack_disp).slice());
                        try buf.appendSlice(allocator, inst.encMovupsXmmMemBaseDisp32(false, .xmm0, .rax, 0).slice());
                        try buf.appendSlice(allocator, rbpStoreXmmV128(off, .xmm0).slice());
                    },
                }
                int_arg_idx += 1;
                fp_arg_idx += 1;
                continue;
            }
            // SysV per-overflow stack-arg read (mirror of
            // op_call.marshalCallArgs's NSAA write path).
            // `[RBP + 16 + r15_save_off + 8 * nsaa_idx]` matches the
            // caller's `[RSP + 8 * nsaa_idx]` write after RET addr +
            // saved RBP (+ saved R15) push. Win64 already handled
            // above; this branch is structurally SysV-only.
            const sysv_int_overflow = (ptype == .i32 or ptype == .i64 or ptype == .ref) and int_arg_idx >= abi.current.arg_gprs.len;
            const sysv_fp_overflow = (ptype == .f32 or ptype == .f64) and fp_arg_idx >= abi.current.arg_xmms.len;
            if (sysv_int_overflow or sysv_fp_overflow) {
                const r15_save_off: i32 = if (uses_runtime_ptr) 8 else 0;
                const stack_disp: i32 = 16 + r15_save_off + @as(i32, @intCast(nsaa_idx * 8));
                switch (ptype) {
                    .i32 => {
                        try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(.rax, .rbp, stack_disp).slice());
                        try buf.appendSlice(allocator, rbpStoreR32(off, .rax).slice());
                    },
                    // D-093 (d-33): reftype shares i64 8-byte gpr slot.
                    .i64, .f32, .f64, .ref => {
                        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rbp, stack_disp).slice());
                        try buf.appendSlice(allocator, rbpStoreR64(off, .rax).slice());
                    },
                    .v128 => unreachable, // Win64 v128 hidden-ptr handled above
                }
                nsaa_idx += 1;
                if (sysv_int_overflow) int_arg_idx += 1 else fp_arg_idx += 1;
                continue;
            }
            switch (ptype) {
                .i32 => {
                    try buf.appendSlice(allocator, rbpStoreR32(off, abi.current.arg_gprs[int_arg_idx]).slice());
                    int_arg_idx += 1;
                    if (abi.current_cc == .win64) fp_arg_idx += 1;
                },
                // D-093 (d-33): reftype shares i64 8-byte gpr slot.
                .i64, .ref => {
                    try buf.appendSlice(allocator, rbpStoreR64(off, abi.current.arg_gprs[int_arg_idx]).slice());
                    int_arg_idx += 1;
                    if (abi.current_cc == .win64) fp_arg_idx += 1;
                },
                .f32 => {
                    try buf.appendSlice(allocator, rbpStoreXmmF32(off, abi.current.arg_xmms[fp_arg_idx]).slice());
                    fp_arg_idx += 1;
                    if (abi.current_cc == .win64) int_arg_idx += 1;
                },
                .f64 => {
                    try buf.appendSlice(allocator, rbpStoreXmmF64(off, abi.current.arg_xmms[fp_arg_idx]).slice());
                    fp_arg_idx += 1;
                    if (abi.current_cc == .win64) int_arg_idx += 1;
                },
                .v128 => {
                    if (abi.current_cc == .win64) {
                        // Win64 v128 hidden-pointer
                        // marshal — register slot. Per Microsoft x64
                        // ABI §"Parameter passing" the caller wrote
                        // the v128 into a 16-byte aligned scratch buf
                        // in its outgoing-args region and passed the
                        // address in the int-arg-reg slot (RDX/R8/R9).
                        // Load via MOVUPS xmm_tmp ← [ptr_reg] and
                        // store to local slot.
                        const ptr_reg = abi.current.arg_gprs[int_arg_idx];
                        try buf.appendSlice(allocator, inst.encMovupsXmmMemBaseDisp32(false, .xmm0, ptr_reg, 0).slice());
                        try buf.appendSlice(allocator, rbpStoreXmmV128(off, .xmm0).slice());
                        int_arg_idx += 1;
                        fp_arg_idx += 1;
                    } else {
                        // SysV co-discharge:
                        // SysV v128 in XMM0..XMM7 direct (AMD64 ABI §3.2.3
                        // SSE class); stack-overflow at `fp_arg_idx >= 8`
                        // reads 16 consecutive aligned bytes from the
                        // NSAA stream (SSE class → 2 eightbytes on stack).
                        if (fp_arg_idx >= abi.current.arg_xmms.len) {
                            // SysV NSAA v128 alignment: each v128 takes
                            // 2 eightbyte slots, 16-byte aligned. Round
                            // nsaa_idx up to even before consuming.
                            if ((nsaa_idx & 1) != 0) nsaa_idx += 1;
                            const r15_save_off: i32 = if (uses_runtime_ptr) 8 else 0;
                            const stack_disp: i32 = 16 + r15_save_off + @as(i32, @intCast(nsaa_idx * 8));
                            try buf.appendSlice(allocator, inst.encMovupsXmmMemBaseDisp32(false, .xmm0, .rbp, stack_disp).slice());
                            try buf.appendSlice(allocator, rbpStoreXmmV128(off, .xmm0).slice());
                            nsaa_idx += 2;
                            fp_arg_idx += 1;
                        } else {
                            try buf.appendSlice(allocator, rbpStoreXmmV128(off, abi.current.arg_xmms[fp_arg_idx]).slice());
                            fp_arg_idx += 1;
                        }
                    }
                },
            }
        }
    }

    // Wasm spec §4.5.3.1 — locals beyond params are initialised to
    // zero on entry. Mirror of arm64/emit.zig:263-267 (STR XZR per
    // slot). x86_64: `XOR EAX, EAX` zeros RAX (32-bit XOR zero-
    // extends to 64); then `MOV [RBP+disp], RAX` writes 8 bytes per
    // local slot. RAX is the return reg, overwritten at function-
    // end, so its temporary use here is invariant-clean.
    if (num_locals > 0) {
        try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice());
        var loc_idx: u32 = num_params;
        while (loc_idx < total_locals) : (loc_idx += 1) {
            const loc_disp = layout.disps[loc_idx];
            const ty = func.localValType(loc_idx);
            if (ty == .v128) {
                // Zero-init v128 declared local — write
                // 16 bytes via two STR XZR (RAX, already zeroed
                // above). MOVUPS-with-zero would need a const
                // pool constant; the two MOVs are bench-cost
                // identical and avoid a pool insertion.
                try buf.appendSlice(allocator, rbpStoreR64(loc_disp, .rax).slice());
                try buf.appendSlice(allocator, rbpStoreR64(loc_disp + 8, .rax).slice());
            } else {
                try buf.appendSlice(allocator, rbpStoreR64(loc_disp, .rax).slice());
            }
        }
    }

    // ADR-0155 stage 4 (D-265 Phase IV) — register-homed locals (x86_64 port).
    // liveness APPENDED `homing.count` function-spanning pseudo-vregs (the last
    // K vregs); their home pseudo-vreg id is `n_temp + rank` where `n_temp` =
    // temporary-vreg count = `slots.len - count`. A homed `local.get` reads the
    // home register into a fresh temporary (MOV, not LOAD-from-slot); a homed
    // `local.set`/`tee` MOVs a temporary into the home register. The value
    // crosses the loop back-edge in-register (the D-265 win). The mapping is the
    // SSOT plan re-derived identically by liveness / regalloc / emit.
    // Hand-built test allocations (emit_test_*.zig) construct `liveness` /
    // `alloc` directly and do NOT include the K function-spanning homing pseudo-
    // vregs that `liveness.compute` appends on the real path. Detect that
    // (slots.len < homing.count → the appended pseudo-vreg slots are absent) and
    // run un-homed for that compile; the real regalloc path always sizes
    // `slots.len == ranges.len ≥ count`, so homing stays on there.
    const planned = local_homing.plan(func);
    const homing = if (alloc.slots.len >= planned.count) planned else local_homing.Plan{};
    const n_temp: u32 = @intCast(alloc.slots.len - homing.count);

    // ADR-0155 stage 4 — prologue-load each register-homed local's initial value
    // from its stack slot into its pinned home register. The slot already holds
    // the correct initial value (param marshalled above, or zero-inited for
    // declared locals), so a single MOV seeds the register; from here the slot
    // is dormant. Width: i32 → 32-bit MOV (zero-extends), i64 → 64-bit MOV.
    // Mirrors arm64/emit.zig's homing seed.
    if (homing.count > 0) {
        var hr: u32 = 0;
        while (hr < homing.count) : (hr += 1) {
            const lidx = homing.local_idx[hr];
            const home_vreg = n_temp + hr;
            // Snapshot the home reg's CALLER value into its frame save slot
            // BEFORE the seed overwrites it (callee-saved ABI contract — see the
            // home_save_bytes comment). Only a register-resident home actually
            // holds a callee-saved reg; a spilled home lives in its own frame
            // slot and clobbers nothing. Every return path restores from here.
            switch (alloc.slot(home_vreg, .gpr)) {
                .reg => |id| {
                    const home_phys = abi.slotToReg(id) orelse return Error.SlotOverflow;
                    try buf.appendSlice(allocator, rbpStoreR64(home_save_base_disp - @as(i32, @intCast(hr)) * 8, home_phys).slice());
                },
                .spill => {},
            }
            const home_reg = try gpr.gprDefSpilled(alloc, home_vreg, 0);
            const loc_disp = layout.disps[lidx];
            switch (func.localValType(lidx)) {
                .i32 => try buf.appendSlice(allocator, rbpLoadR32(home_reg, loc_disp).slice()),
                .i64 => try buf.appendSlice(allocator, rbpLoadR64(home_reg, loc_disp).slice()),
                // local_homing.isHomeableType only returns true for i32/i64.
                .f32, .f64, .v128, .ref => unreachable,
            }
            try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, home_vreg, 0);
        }
    }

    // ============================================================
    // Body: walk instrs, dispatch per op.
    //
    // For 7.7 skeleton: track a "result vreg" cursor that records
    // which vreg holds the latest pushed value. `end` reads that
    // vreg, ensures it ends up in EAX (the SysV x86_64 i32 return
    // register), and then runs the epilogue.
    // ============================================================
    var pushed_vregs: std.ArrayList(u32) = .empty;
    defer pushed_vregs.deinit(allocator);
    var next_vreg: u32 = 0;
    const parity_on = liveness_parity.on();

    // Control-stack: Wasm structured-control labels (block /
    // loop). Forward fixups (br to block) land in `pending`;
    // backward jumps (br to loop) resolve immediately at the
    // `br` site since the target was captured on push.
    var labels: std.ArrayList(Label) = .empty;
    defer {
        for (labels.items) |*l| l.pending.deinit(allocator);
        labels.deinit(allocator);
    }

    // Bounds-check trap fixups: each memory op emits a
    // JAE rel32 placeholder that branches to the trap stub
    // emitted at function-final `end`. Each Fixup records the
    // Jcc instruction's byte_offset; the function-level end
    // patches them all to the trap stub address.
    var bounds_fixups: std.ArrayList(u32) = .empty;
    defer bounds_fixups.deinit(allocator);
    // Distinct list because JMP rel32
    // placeholders are 5 bytes (0xE9 + 4-byte disp32) while the
    // bounds-check Jcc rel32 placeholders are 6 bytes (0x0F 0x8x +
    // 4-byte disp32). Both target the same trap stub but the
    // disp formula differs by 1 byte. Patched at function-end
    // trap-stub block alongside bounds_fixups.
    var unreach_fixups: std.ArrayList(u32) = .empty;
    defer unreach_fixups.deinit(allocator);
    // ADR-0164 A2 / D-292 — div-by-zero (7) + div_s overflow (8) demuxed from
    // bounds_fixups so each reaches a precise per-kind trap stub.
    var divzero_fixups: std.ArrayList(u32) = .empty;
    defer divzero_fixups.deinit(allocator);
    var overflow_fixups: std.ArrayList(u32) = .empty;
    defer overflow_fixups.deinit(allocator);
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
    // D-303 — atomic load/store unaligned-access (code 14 = unaligned_atomic).
    var unaligned_atomic_fixups: std.ArrayList(u32) = .empty;
    defer unaligned_atomic_fixups.deinit(allocator);
    // D-293 — table/cind oob_table (code 2) demuxed from bounds_fixups.
    var oobtable_fixups: std.ArrayList(u32) = .empty;
    defer oobtable_fixups.deinit(allocator);
    // D-293 slice-2 — cind signature-mismatch (code 3) demuxed from bounds_fixups.
    var cind_sig_fixups: std.ArrayList(u32) = .empty;
    defer cind_sig_fixups.deinit(allocator);
    // D-294 — call_indirect null-element (uninitialized_elem, code 13); checked
    // before the sig CMP so a null slot reports code 13, not the sig code 3.
    var uninit_elem_fixups: std.ArrayList(u32) = .empty;
    defer uninit_elem_fixups.deinit(allocator);
    // ADR-0179 #3a / D-314 — loop back-edge interrupt poll (code 16, POST-frame).
    var back_edge_interrupt_fixups: std.ArrayList(u32) = .empty;
    defer back_edge_interrupt_fixups.deinit(allocator);
    // ADR-0179 #3b / D-314 — loop back-edge fuel poll (code 17, POST-frame).
    var back_edge_fuel_fixups: std.ArrayList(u32) = .empty;
    defer back_edge_fuel_fixups.deinit(allocator);

    // Direct-call placeholders awaiting linker patch.
    var call_fixups: std.ArrayList(CallFixup) = .empty;
    errdefer call_fixups.deinit(allocator);

    // SIMD const-pool fixups (per ADR-0042). Each
    // entry records a MOVUPS-RIP-rel placeholder's disp32 byte
    // offset and post-instruction byte plus the `func.simd_consts`
    // index. The post-emit pass appends the per-function const
    // pool past the trap stub (16-byte aligned) and patches each
    // disp32 to the PC-relative offset of the target const.
    var simd_const_fixups: std.ArrayList(types.SimdConstFixup) = .empty;
    defer simd_const_fixups.deinit(allocator);

    // Emit-time-derived const-pool entries (per-op
    // shared 16-byte constants like INT32_MAX_f64-broadcast for
    // trunc_sat). These extend `func.simd_consts` (which carries
    // only per-instance `v128.const` / shuffle-mask literals from
    // the lower pass). At post-emit pool placement the two lists
    // are concatenated; const_idx in fixups maps uniformly into
    // the concat'd pool.
    var extra_consts: std.ArrayList([16]u8) = .empty;
    defer extra_consts.deinit(allocator);

    // dead_code tracking. After
    // `unreachable` / `return` mid-function, subsequent ops are
    // unreachable per Wasm spec §3.3 polymorphic-stack rules; the
    // validator already accepts them but this emitter would
    // attempt to lower them and trip UnsupportedOp on rare ops
    // like memory.grow inside dead code (e.g. unreachable.wast's
    // `as-memory.grow-size`). Mirror of arm64 7.5-emit-deadcode.
    var dead_code: bool = false;

    // EH integration (ADR-0114 D2 + phase10_eh_integration_plan):
    // scan once for try_table presence and allocate a
    // per-function `ExceptionTable.Builder`. Mirror of the arm64
    // setup; the per-op `try_table.emit` populates entries.
    var has_try_table: bool = false;
    for (func.instrs.items) |scan_ins| {
        if (scan_ins.op == .try_table) {
            has_try_table = true;
            break;
        }
    }
    var eh_builder: exception_table.Builder = .empty;
    defer eh_builder.deinit(allocator);
    // See arm64/emit.zig open_try_tables comment.
    var open_try_tables: std.ArrayList(exception_table.OpenTryTable) = .empty;
    defer open_try_tables.deinit(allocator);
    // See arm64/emit.zig landing_pad_fixups comment.
    var landing_pad_fixups: std.ArrayList(exception_table.LandingPadFixup) = .empty;
    defer landing_pad_fixups.deinit(allocator);

    // Per-function emit context.
    var ctx = ctx_mod.EmitCtx.init(.{
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
        .unreach_fixups = &unreach_fixups,
        .divzero_fixups = &divzero_fixups,
        .overflow_fixups = &overflow_fixups,
        .invalid_conv_fixups = &invalid_conv_fixups,
        .null_ref_fixups = &null_ref_fixups,
        .cast_fail_fixups = &cast_fail_fixups,
        .uncaught_exc_fixups = &uncaught_exc_fixups,
        .oob_fixups = &oob_fixups,
        .unaligned_atomic_fixups = &unaligned_atomic_fixups,
        .back_edge_interrupt_fixups = &back_edge_interrupt_fixups,
        .back_edge_fuel_fixups = &back_edge_fuel_fixups,
        .oobtable_fixups = &oobtable_fixups,
        .cind_sig_fixups = &cind_sig_fixups,
        .uninit_elem_fixups = &uninit_elem_fixups,
        .call_fixups = &call_fixups,
        .simd_const_fixups = &simd_const_fixups,
        .extra_consts = &extra_consts,
        .spill_base_off = spill_base_off,
        .outgoing_max_bytes = outgoing_max_bytes,
        .return_is_memory_class = return_is_memory_class,
        .indirect_result_slot_neg_off = indirect_result_slot_neg_off,
        .num_imports = num_imports,
        .globals_offsets = globals_offsets,
        .globals_valtypes = globals_valtypes,
        .dead_code = &dead_code,
        .frame_bytes = frame_bytes,
        .uses_runtime_ptr = uses_runtime_ptr,
        .total_locals = total_locals,
        .local_disps = layout.disps,
        .stack_probe_fixup = stack_probe_fixup,
        .interrupt_fixup = interrupt_fixup,
        .fuel_fixup = fuel_fixup,
        .memory0_idx_type = memory0_idx_type,
        .bounds_elided = bounds_elided,
        .exception_table_builder = if (has_try_table) &eh_builder else null,
        .open_try_tables = if (has_try_table) &open_try_tables else null,
        .landing_pad_fixups = if (has_try_table) &landing_pad_fixups else null,
        .tag_param_counts = tag_param_counts,
        .uses_type_subtyping = uses_type_subtyping,
        // ADR-0155 stage 4 — register-homed-local emit + (no-op) call-site spill.
        .homing = homing,
        .n_temp = n_temp,
        .local_offsets = layout.disps,
        .home_save_base_disp = home_save_base_disp,
    });

    for (func.instrs.items, 0..) |ins, pc| {
        // D-596 — liveness's operand-stack simulation must still agree with
        // what this loop does to `pushed_vregs`. Off unless the diagnostic is.
        if (parity_on) {
            liveness_parity.check(func, pc, ins.op, pushed_vregs.items, labels.items);
        }
        // `end` / `else` always exit the dead region — emit's own
        // bookkeeping (label-stack pop / arm switch) must run.
        // Mirror of arm64/emit.zig:381-414.
        if (ins.op == .end or ins.op == .@"else") {
            dead_code = false;
        }
        if (dead_code) {
            // Maintain label-stack consistency for structural ops
            // inside the dead region: push placeholder labels for
            // block / loop / if so the matching end / else find a
            // frame. Without this, unreachable.wast's `as-if-cond`
            // (where `(unreachable)` is the if-cond) surfaces
            // `emitElse without if_then` once the inner else fires.
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
        // Route through dispatch_collector before the legacy switch —
        // mirror of arm64/emit.zig wire (bool-return + inferred-error
        // pattern).
        // Per ADR-0074 + `.dev/dispatcher_wire_design.md` §2.3.
        if (try dispatch_collector.dispatch(.x86_64, ins.op, .{
            allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op,
        })) {
            continue;
        }
        // (ADR-0073 + ADR-0075) — inline-switch
        // dispatcher cutover for x86_64 ctx cohort. Walks
        // collected_x86_64_ctx_ops (391 ops); the giant
        // switch below now only handles ops outside the ctx tuple
        // (extract_lane / replace_lane / shuffle / i64x2.mul /
        // v128.const / load_lane / store_lane / popcnt /
        // trunc_sat_f64x2 / convert_low_i32x4_u).
        // If this `end` closes a try_table block, patch the
        // pc_end of its catch entries BEFORE dispatch (which would
        // pop the matching label and break the depth match). Mirror
        // of the arm64 emit.zig logic, hoisted above the ctx
        // dispatcher because `.end` is in `collected_x86_64_ctx_ops`.
        const end_pre_pop_depth: u32 = if (ins.op == .end) @intCast(labels.items.len) else 0;
        if (ins.op == .end and labels.items.len > 0 and open_try_tables.items.len > 0) {
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
        if (try dispatch_collector.dispatchX86_64Ctx(ins.op, &ctx, &ins)) {
            // D-182 — post-dispatch
            // landing_pad_pc patch (mirror of arm64 emit.zig). See
            // arm64 sibling for the per-clause-prelude rationale;
            // x86_64 differs only in the encoders (MOV r64 ← [R15
            // + disp32] / MOV [RBP - off], r64 / JMP rel32).
            if (ins.op == .end and end_pre_pop_depth > 0 and landing_pad_fixups.items.len > 0) {
                // A catch lands here straight from the unwinder, bypassing the
                // post-call reload of register-homed locals: their home registers
                // hold whatever the unwound callees left. The prelude must reload
                // them from their frame slots, so take the per-clause path.
                var any_payload = ctx.homing.count > 0;
                var probe_i: usize = 0;
                while (probe_i < landing_pad_fixups.items.len) : (probe_i += 1) {
                    const fx = landing_pad_fixups.items[probe_i];
                    if (fx.target_labels_depth != end_pre_pop_depth) continue;
                    const k = eh_builder.entries.items[fx.entry_idx].kind;
                    // D-327: any _ref clause needs the per-clause path to emit the
                    // exnref reify call (even with 0 payload).
                    if (k == .catch_ref or k == .catch_all_ref) {
                        any_payload = true;
                        break;
                    }
                    if (k == .catch_ or k == .catch_ref) {
                        if (eh_builder.entries.items[fx.entry_idx].tag_idx) |t| {
                            if (ctx.tag_param_counts.len > t and ctx.tag_param_counts[t] > 0) {
                                any_payload = true;
                                break;
                            }
                        }
                    }
                }

                if (!any_payload) {
                    const land_pc: u32 = @intCast(buf.items.len);
                    var i: usize = 0;
                    while (i < landing_pad_fixups.items.len) {
                        const fx = landing_pad_fixups.items[i];
                        if (fx.target_labels_depth == end_pre_pop_depth) {
                            eh_builder.entries.items[fx.entry_idx].landing_pad_pc = land_pc;
                            _ = landing_pad_fixups.swapRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                } else {
                    var jmp_placeholders: std.ArrayList(u32) = .empty;
                    defer jmp_placeholders.deinit(allocator);
                    // The block's fall-through path arrives here too and must not run
                    // the landing-pad preludes laid out inline below; jump it straight
                    // to the common continuation.
                    try jmp_placeholders.append(allocator, @intCast(buf.items.len));
                    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());

                    var i: usize = 0;
                    while (i < landing_pad_fixups.items.len) {
                        const fx = landing_pad_fixups.items[i];
                        if (fx.target_labels_depth != end_pre_pop_depth) {
                            i += 1;
                            continue;
                        }
                        const entry = &eh_builder.entries.items[fx.entry_idx];
                        const clause_start: u32 = @intCast(buf.items.len);

                        const is_ref = entry.kind == .catch_ref or entry.kind == .catch_all_ref;
                        // D-327 (ADR-0120 D6) — reify the exnref FIRST (before the
                        // param prelude) into the TOP result vreg. The reify is an
                        // emit-synthesized CALL the regalloc doesn't model (clobbers
                        // caller-saved), so params written after survive. Win64 arg0
                        // = RCX, SysV = RDI (abi.current.entry_arg0_gpr).
                        if (is_ref) {
                            if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                            const exnref_vreg = pushed_vregs.items[pushed_vregs.items.len - 1];
                            try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());
                            try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, @intCast(jit_abi.reify_exnref_fn_off)).slice());
                            // Win64: reifyExnref is a regular C-ABI fn that homes
                            // its reg arg to the 32-byte shadow space; reserve it
                            // (no-op on SysV / when the frame already has outgoing
                            // space). D-327 Win64 fix.
                            try op_call.emitShadowAlloc(allocator, &buf, outgoing_max_bytes);
                            try buf.appendSlice(allocator, inst.encCallReg(.rax).slice());
                            try op_call.emitShadowFree(allocator, &buf, outgoing_max_bytes);
                            const dest_reg = try gpr.gprDefSpilled(alloc, exnref_vreg, 0);
                            try buf.appendSlice(allocator, inst.encMovRR(.q, dest_reg, abi.return_gpr).slice());
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
                                // D-328/D-327: tag params are the DEEPEST np result
                                // vregs; for catch_ref the exnref is the TOP result, so
                                // the base skips it.
                                const extra: usize = if (is_ref) 1 else 0;
                                if (pushed_vregs.items.len < n_payload + extra) return Error.AllocationMissing;
                                const base = pushed_vregs.items.len - n_payload - extra;
                                var k: u32 = 0;
                                while (k < n_payload) : (k += 1) {
                                    const target_vreg = pushed_vregs.items[base + k];
                                    const dest_reg = try gpr.gprDefSpilled(alloc, target_vreg, 0);
                                    const off: i32 = @intCast(jit_abi.eh_payload_buf_off + k * 8);
                                    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(dest_reg, abi.runtime_ptr_save_gpr, off).slice());
                                    try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, target_vreg, 0);
                                }
                            }
                        }

                        const jmp_off: u32 = @intCast(buf.items.len);
                        try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
                        try jmp_placeholders.append(allocator, jmp_off);

                        entry.landing_pad_pc = clause_start;
                        _ = landing_pad_fixups.swapRemove(i);
                    }

                    const common_pc: u32 = @intCast(buf.items.len);
                    for (jmp_placeholders.items) |fx_byte| {
                        const disp: i32 = @as(i32, @intCast(common_pc)) -
                            @as(i32, @intCast(fx_byte)) - 5;
                        inst.patchRel32(buf.items, fx_byte, 5, disp);
                    }
                }
            }
            continue;
        }
        switch (ins.op) {
            // any.convert_extern / extern.convert_any: pure identity — the
            // value flows through in-place (externref/anyref share the
            // Value.ref slot; the distinction is validator-only). No machine
            // code, no vreg change; liveness models them transparent 0→0.
            .@"any.convert_extern", .@"extern.convert_any" => {},
            // atomic.fence (threads, ADR-0168): single-threaded substrate
            // → every atomic op is trivially seq-cst and the JIT emits
            // memory ops in program order, so the fence needs no machine
            // code (0→0 transparent, like the convert pair).
            .@"atomic.fence" => {},
            // i32.const + i64.const inline bodies
            // extracted into `op_alu_int.emitI{32,64}Const` adapters.
            .@"i32.const" => try op_alu_int.emitI32Const(&ctx, &ins),
            .@"i64.const" => try op_alu_int.emitI64Const(&ctx, &ins),
            // Per ADR-0056: Wasm 2.0 reference-types
            // partial — null + is_null. ref.func deferred
            // (needs JitRuntime extension). ref.null = push 0
            // (XOR r,r zeroes the 64-bit reg via implicit upper-32
            // clear on 32-bit ops). ref.is_null = reuse i64.eqz.
            // ref.null inline body extracted into
            // `op_alu_int.emitRefNull` `(ctx, ins)` adapter.
            .@"ref.null" => try op_alu_int.emitRefNull(&ctx, &ins),
            // ref.func idx — load
            // func_entities_ptr from JitRuntime, add idx * size.
            // Recipe:
            //   MOV r_dst, [r15 + func_entities_ptr_off]
            //   ADD r_dst, imm32 (= idx * sizeOf(FuncEntity))
            // ref.func inline body extracted into
            // `op_alu_int.emitRefFunc` `(ctx, ins)` adapter.
            .@"ref.func" => try op_alu_int.emitRefFunc(&ctx, &ins),
            // Integer divide / remainder.
            // The i32+i64 div/rem cohort delegates to the
            // corresponding ctx adapter in op_alu_int.
            .@"i32.div_s" => try op_alu_int.emitI32DivS(&ctx, &ins),
            .@"i32.div_u" => try op_alu_int.emitI32DivU(&ctx, &ins),
            .@"i32.rem_s" => try op_alu_int.emitI32RemS(&ctx, &ins),
            .@"i32.rem_u" => try op_alu_int.emitI32RemU(&ctx, &ins),
            .@"i64.div_s" => try op_alu_int.emitI64DivS(&ctx, &ins),
            .@"i64.div_u" => try op_alu_int.emitI64DivU(&ctx, &ins),
            .@"i64.rem_s" => try op_alu_int.emitI64RemS(&ctx, &ins),
            .@"i64.rem_u" => try op_alu_int.emitI64RemU(&ctx, &ins),
            .@"f32.const" => try op_alu_float.emitF32Const(&ctx, &ins),
            .@"f64.const" => try op_alu_float.emitF64Const(&ctx, &ins),
            .@"f64.promote_f32" => try op_convert.emitF64PromoteF32(&ctx, &ins),
            .@"f32.demote_f64" => try op_convert.emitF32DemoteF64(&ctx, &ins),
            .@"i32.reinterpret_f32" => try op_convert.emitI32ReinterpretF32(&ctx, &ins),
            .@"i64.reinterpret_f64" => try op_convert.emitI64ReinterpretF64(&ctx, &ins),
            .@"f32.reinterpret_i32" => try op_convert.emitF32ReinterpretI32(&ctx, &ins),
            .@"f64.reinterpret_i64" => try op_convert.emitF64ReinterpretI64(&ctx, &ins),
            .@"f32.convert_i32_s" => try op_convert.emitF32ConvertI32S(&ctx, &ins),
            .@"f32.convert_i64_s" => try op_convert.emitF32ConvertI64S(&ctx, &ins),
            .@"f64.convert_i32_s" => try op_convert.emitF64ConvertI32S(&ctx, &ins),
            .@"f64.convert_i64_s" => try op_convert.emitF64ConvertI64S(&ctx, &ins),
            .@"f32.convert_i32_u" => try op_convert.emitF32ConvertI32U(&ctx, &ins),
            .@"f64.convert_i32_u" => try op_convert.emitF64ConvertI32U(&ctx, &ins),
            .@"f32.convert_i64_u" => try op_convert.emitF32ConvertI64U(&ctx, &ins),
            .@"f64.convert_i64_u" => try op_convert.emitF64ConvertI64U(&ctx, &ins),
            .@"i32.trunc_sat_f32_s" => try op_convert.emitI32TruncSatF32S(&ctx, &ins),
            .@"i32.trunc_sat_f64_s" => try op_convert.emitI32TruncSatF64S(&ctx, &ins),
            .@"i64.trunc_sat_f32_s" => try op_convert.emitI64TruncSatF32S(&ctx, &ins),
            .@"i64.trunc_sat_f64_s" => try op_convert.emitI64TruncSatF64S(&ctx, &ins),
            .@"i32.trunc_sat_f32_u" => try op_convert.emitI32TruncSatF32U(&ctx, &ins),
            .@"i32.trunc_sat_f64_u" => try op_convert.emitI32TruncSatF64U(&ctx, &ins),
            .@"i64.trunc_sat_f32_u" => try op_convert.emitI64TruncSatF32U(&ctx, &ins),
            .@"i64.trunc_sat_f64_u" => try op_convert.emitI64TruncSatF64U(&ctx, &ins),
            .@"i32.trunc_f32_s" => try op_convert.emitI32TruncF32S(&ctx, &ins),
            .@"i32.trunc_f64_s" => try op_convert.emitI32TruncF64S(&ctx, &ins),
            .@"i64.trunc_f32_s" => try op_convert.emitI64TruncF32S(&ctx, &ins),
            .@"i64.trunc_f64_s" => try op_convert.emitI64TruncF64S(&ctx, &ins),
            .@"i32.trunc_f32_u" => try op_convert.emitI32TruncF32U(&ctx, &ins),
            .@"i32.trunc_f64_u" => try op_convert.emitI32TruncF64U(&ctx, &ins),
            .@"i64.trunc_f32_u" => try op_convert.emitI64TruncF32U(&ctx, &ins),
            .@"i64.trunc_f64_u" => try op_convert.emitI64TruncF64U(&ctx, &ins),
            .@"i32.load" => try op_memory.emitI32Load(&ctx, &ins),
            // i32.atomic.load (threads, ADR-0168) — legacy-switch path
            // like atomic.fence; forwards to the shared mem emitter.
            // Single-threaded substrate → plain aligned load (B2 = trap).
            .@"i32.atomic.load" => try op_memory.emitI32AtomicLoad(&ctx, &ins),
            .@"i64.atomic.load" => try op_memory.emitI64AtomicLoad(&ctx, &ins),
            .@"i32.atomic.load8_u" => try op_memory.emitI32AtomicLoad8U(&ctx, &ins),
            .@"i32.atomic.load16_u" => try op_memory.emitI32AtomicLoad16U(&ctx, &ins),
            .@"i64.atomic.load8_u" => try op_memory.emitI64AtomicLoad8U(&ctx, &ins),
            .@"i64.atomic.load16_u" => try op_memory.emitI64AtomicLoad16U(&ctx, &ins),
            .@"i64.atomic.load32_u" => try op_memory.emitI64AtomicLoad32U(&ctx, &ins),
            .@"i32.atomic.store" => try op_memory.emitI32AtomicStore(&ctx, &ins),
            .@"i64.atomic.store" => try op_memory.emitI64AtomicStore(&ctx, &ins),
            .@"i32.atomic.store8" => try op_memory.emitI32AtomicStore8(&ctx, &ins),
            .@"i32.atomic.store16" => try op_memory.emitI32AtomicStore16(&ctx, &ins),
            .@"i64.atomic.store8" => try op_memory.emitI64AtomicStore8(&ctx, &ins),
            .@"i64.atomic.store16" => try op_memory.emitI64AtomicStore16(&ctx, &ins),
            .@"i64.atomic.store32" => try op_memory.emitI64AtomicStore32(&ctx, &ins),
            // tNN.atomic.rmw* (threads, ADR-0168): callout through
            // JitRuntime.atomic_rmw_fn (mirror arm64).
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
            // memory.atomic.notify / wait{32,64} (threads, ADR-0168).
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
            .@"i32.load8_s" => try op_memory.emitI32Load8S(&ctx, &ins),
            .@"i32.load8_u" => try op_memory.emitI32Load8U(&ctx, &ins),
            .@"i32.load16_s" => try op_memory.emitI32Load16S(&ctx, &ins),
            .@"i32.load16_u" => try op_memory.emitI32Load16U(&ctx, &ins),
            .@"i32.store" => try op_memory.emitI32Store(&ctx, &ins),
            .@"i32.store8" => try op_memory.emitI32Store8(&ctx, &ins),
            .@"i32.store16" => try op_memory.emitI32Store16(&ctx, &ins),
            .@"i64.load" => try op_memory.emitI64Load(&ctx, &ins),
            .@"i64.load8_s" => try op_memory.emitI64Load8S(&ctx, &ins),
            .@"i64.load8_u" => try op_memory.emitI64Load8U(&ctx, &ins),
            .@"i64.load16_s" => try op_memory.emitI64Load16S(&ctx, &ins),
            .@"i64.load16_u" => try op_memory.emitI64Load16U(&ctx, &ins),
            .@"i64.load32_s" => try op_memory.emitI64Load32S(&ctx, &ins),
            .@"i64.load32_u" => try op_memory.emitI64Load32U(&ctx, &ins),
            .@"i64.store" => try op_memory.emitI64Store(&ctx, &ins),
            .@"i64.store8" => try op_memory.emitI64Store8(&ctx, &ins),
            .@"i64.store16" => try op_memory.emitI64Store16(&ctx, &ins),
            .@"i64.store32" => try op_memory.emitI64Store32(&ctx, &ins),
            .@"f32.load" => try op_memory.emitF32Load(&ctx, &ins),
            .@"f64.load" => try op_memory.emitF64Load(&ctx, &ins),
            .@"f32.store" => try op_memory.emitF32Store(&ctx, &ins),
            .@"f64.store" => try op_memory.emitF64Store(&ctx, &ins),
            // data.drop / elem.drop — write 1 to
            // the dropped-flag byte. No operands; no result. The
            // validator already bounds-checks idx.
            //   MOV r10, [r15 + ptr_off]      ; load base
            //   MOV BYTE [r10 + idx], 1
            .@"data.drop" => {
                try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r10, abi.runtime_ptr_save_gpr, jit_abi.data_dropped_ptr_off).slice());
                try buf.appendSlice(allocator, inst.encStoreImm8MemBaseDisp32(.r10, @intCast(ins.payload), 1).slice());
            },
            .@"elem.drop" => {
                try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r10, abi.runtime_ptr_save_gpr, jit_abi.elem_dropped_ptr_off).slice());
                try buf.appendSlice(allocator, inst.encStoreImm8MemBaseDisp32(.r10, @intCast(ins.payload), 1).slice());
            },
            // Per ADR-0058: table ops cohort
            // — `(ctx, ins)` per-op adapters bundle the unified
            // bounds-checked load/store + grow/fill/copy/init paths
            // against the per-table TableSlice descriptor.
            // SIMD-128 packed integer add/sub
            // family (8 ops). Wires the FP-class regalloc +
            // shape-tag pipeline on x86_64 per ADR-0041; spilled
            // v128 vregs surface UnsupportedOp until MOVDQU
            // helpers land.
            // i64x2.mul synthesis (no native SSE4.1 form;
            // PMULUDQ + shift/add idiom uses XMM14/15 as scratch).
            .@"i64x2.mul" => try op_simd_int_arith.emitI64x2Mul(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // Lane access foundation (i32x4 only — other
            // shapes follow). Splat broadcasts a scalar i32
            // across 4 lanes; extract_lane pulls one lane back to
            // scalar via PEXTRD (SSE4.1).
            .@"i32x4.extract_lane" => try op_simd_int_cmp_lane.emitI32x4ExtractLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            // i64x2.extract_lane via PEXTRQ (SSE4.1
            // REX.W=1 variant of PEXTRD). Mirror of i32x4.extract_
            // lane handler with u1 lane (i64x2 has 2 lanes).
            .@"i64x2.extract_lane" => try op_simd_int_cmp_lane.emitI64x2ExtractLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            // replace_lane for the wide-int v128 shapes.
            // PINSRD (32-bit) / PINSRQ (64-bit, REX.W mandatory) plus a
            // MOVAPS preamble when dst doesn't alias the input vec.
            .@"i32x4.replace_lane" => try op_simd_int_cmp_lane.emitI32x4ReplaceLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            .@"i64x2.replace_lane" => try op_simd_int_cmp_lane.emitI64x2ReplaceLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            // Narrow-int lane access (i8x16 / i16x8).
            // PEXTRB / PEXTRW + optional MOVSX for signed extract.
            // PINSRB / PINSRW + MOVAPS preamble for replace.
            .@"i8x16.extract_lane_s" => try op_simd_int_cmp_lane.emitI8x16ExtractLaneS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            .@"i8x16.extract_lane_u" => try op_simd_int_cmp_lane.emitI8x16ExtractLaneU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            .@"i16x8.extract_lane_s" => try op_simd_int_cmp_lane.emitI16x8ExtractLaneS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            .@"i16x8.extract_lane_u" => try op_simd_int_cmp_lane.emitI16x8ExtractLaneU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            .@"i8x16.replace_lane" => try op_simd_int_cmp_lane.emitI8x16ReplaceLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            .@"i16x8.replace_lane" => try op_simd_int_cmp_lane.emitI16x8ReplaceLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            // Integer splat siblings (i32x4 already
            // landed). i8x16 via PSHUFB-broadcast; i16x8
            // via PSHUFLW + PSHUFD; i64x2 via PUNPCKLQDQ.
            // f32x4 lane access trio. XMM-source
            // semantics — splat / extract reuse encPshufd; replace
            // uses the new INSERTPS encoder (SSE4.1 3A 21 /r ib).
            .@"f32x4.extract_lane" => try op_simd_float.emitF32x4ExtractLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            .@"f32x4.replace_lane" => try op_simd_float.emitF32x4ReplaceLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            // f64x2 lane access trio. splat + extract_lane
            // reuse encPshufd (imm 0x44 / 0xEE for low/high qword).
            // replace_lane uses MOVAPS preamble + MOVSD (lane=0) /
            // MOVLHPS (lane=1).
            .@"f64x2.extract_lane" => try op_simd_float.emitF64x2ExtractLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            .@"f64x2.replace_lane" => try op_simd_float.emitF64x2ReplaceLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, @as(u32, @intCast(ins.payload))),
            // Int compare eq/ne family. PCMPEQ B/W/D
            // (SSE2) + PCMPEQQ (SSE4.1); ne paths apply NOT via
            // PXOR with an all-ones mask (PCMPEQB scratch, scratch).
            // Signed lt/gt/le/ge for 8/16/32-bit shapes
            // (12 ops). PCMPGT_<shape> direct for gt; operand swap for
            // lt; PXOR-with-all-ones NOT for le/ge. i64x2 signed
            // compares defer (PCMPGTQ is SSE4.2 — needs ADR).
            // i64x2 signed compare lt_s/gt_s/le_s/ge_s
            // (4 ops). PCMPGTQ (SSE4.2 0F 38 37) threaded through
            // the emitV128IntCmpSigned helper. Per ADR-0041 §5
            // amend — x86_64 baseline raised SSE4.1 →
            // SSE4.2 (Steam Apr 2026 98.18% adoption).
            // Unsigned compares lt_u/gt_u/le_u/ge_u for
            // 8/16/32-bit shapes (12 ops). PMINU/PMAXU + PCMPEQ
            // (cranelift `lower.isle:2016-2080`): gt/lt = NOT eq(min/max,
            // rhs); ge/le = eq(lhs, max/min). PMAXUB/PMINUB SSE2;
            // PMAXU{W,D} / PMINU{W,D} SSE4.1. i64x2 unsigned not in
            // Wasm SIMD spec.
            // FP compare eq/ne/lt/gt/le/ge for f32x4 +
            // f64x2 (12 ops). CMPPS (SSE 0F C2 /r ib) + CMPPD (SSE2
            // 66 0F C2 /r ib) with imm8 predicate per Intel SDM Vol
            // 2A "CMPPS" Table 3-7. eq/ne/lt/le direct with imm
            // 0/4/1/2; gt/ge swap operands + imm 1/2 per cranelift
            // `lower.isle:2169-2172`.
            // FP arithmetic add/sub/mul/div + sqrt
            // for f32x4 + f64x2 (10 ops). ADDPS/SUBPS/MULPS/DIVPS/
            // SQRTPS (SSE 0F 58/5C/59/5E/51) + PD variants (SSE2 66
            // prefix). Binary ops reuse emitV128IntBinop;
            // sqrt uses new emitV128FpUnop. min/max defer
            // (NaN-correction synthesis ~7 instr per cranelift
            // `lower.isle` F32X4/F64X2 fmin/fmax).
            // f32x4 + f64x2 min/max NaN-correction
            // synthesis (4 ops). MINPS/MAXPS / MINPD/MAXPD wrapped
            // with cranelift's 10-instr (fmin) / 13-instr (fmax)
            // recipe per `lower.isle:2783-2939` — produces canonical
            // IEEE-754-2019 minimum/maximum (NaN-propagating, signed-
            // zero-aware) where naive MIN/MAX would return src2 on
            // unordered inputs (off-spec). XMM14 + XMM15 used as
            // scratch.
            // v128 bitwise ops + v128.any_true (7 ops).
            // PAND/POR/PXOR/PANDN (SSE2) for and/or/xor/andnot;
            // 3-instr synthesis for not (PCMPEQB ones,ones + PXOR);
            // 5-instr PAND/PANDN/POR chain for bitselect; PTEST +
            // SETNE + MOVZX for any_true (SSE4.1 PTEST).
            // Per-shape all_true + bitmask reductions
            // (8 ops). all_true via SSE4.1 PXOR + PCMPEQ_<lane> +
            // PTEST + SETZ + MOVZX (5 instr per cranelift
            // `lower.isle:4936`). bitmask via PMOVMSKB / MOVMSKPS /
            // MOVMSKPD direct for i8/i32/i64; i16x8 needs PACKSSWB
            // + PMOVMSKB + SHR 8 (cranelift `lower.isle:4977`).
            // i*x* packed shifts shl/shr_s/shr_u for
            // i16x8 + i32x4 + i64x2 (8 ops; i8x16 + i64x2.shr_s
            // synthesis defer). 5-instr emit per shift:
            // AND mask (lane_width - 1), MOVD count→xmm, MOVAPS
            // dst,vec (skip-elide), <shift> dst,scratch.
            // i64x2.shr_s synthesis (no native PSRAQ
            // in SSE; runtime-mask sign-bit fixup recipe per
            // cranelift `lower.isle:943-951` — 9 instr, no
            // const-pool needed since the sign-bit mask is
            // PCMPEQB+PSLLQ-imm-synthesised inline). i8x16 shifts
            // defer (count-dependent broadcast mask
            // synthesis or const-pool dependency per ADR-0042).
            // i8x16.shl + i8x16.shr_u via inline-mask
            // synthesis (no const-pool dep). 9-/10-instr recipes
            // using PSLLW/PSRLW + PCMPEQB-derived all-ones + PSHUFB
            // broadcast of byte-0 of the shifted-mask word.
            // i8x16.shr_s defers (byte→word extension via
            // PUNPCKLBW + PSRAW + PACKSSWB — structurally different).
            // i8x16.shr_s via cranelift sign-extension
            // synthesis (`lower.isle:846+`). 11-instr: PCMPGTB sign-
            // mask + PUNPCKL/HBW byte→word extension + PSRAW per
            // half + PACKSSWB pack.
            // i*x*.extend_{low,high}_*_{s,u} (12 ops).
            // Low half: 1-instr SSE4.1 PMOVSX*/PMOVZX* direct.
            // High half: PSHUFD imm=0xEE swaps upper qword to lower
            // position + PMOVSX/ZX. 2 instr per high-extend.
            // i*x*.narrow_*_{s,u} (4 ops). PACKSSWB
            // (SSE2) + PACKUSWB (SSE2) for i8x16; PACKSSDW (SSE2)
            // + PACKUSDW (SSE4.1) for i16x8. All single-instr via
            // emitV128IntBinop.
            // i*x*.abs (4 ops). PABSB/W/D (SSSE3
            // 0F 38 1C/1D/1E) for 8/16/32-bit lanes — single-instr
            // unary via emitV128FpUnop. i64x2.abs synthesises via
            // 5-instr sign-mask + PXOR + PSUBQ recipe (no PABSQ
            // in SSE; SSE4.2 PCMPGTQ available per ADR-0041).
            // i*x*.neg (4 ops). 3-instr recipe via
            // emitV128IntNeg helper: PXOR XMM14,XMM14 + PSUB_<shape>
            // XMM14, src + MOVAPS dst, XMM14. Aliasing-safe.
            // FP convert signed + promote/demote
            // (4 ops). Single-instr unary CVT* via emitV128FpUnop.
            // u-variants and trunc-sat defer (cranelift uses
            // const-pool float magic numbers; ADR-0042 pending).
            // 2 inline-synth FP convert / trunc-sat
            // ops. The 4 const-pool-dependent variants
            // (f64x2.convert_low_i32x4_u, i32x4.trunc_sat_f32x4_u,
            // i32x4.trunc_sat_f64x2_{s,u}_zero) defer
            // pending ADR-0042 const-pool plumbing.
            // i32x4.trunc_sat_f32x4_u closes the
            // last of the 4 deferred u-variants. The
            // "3-scratch" framing turned out to be a non-issue:
            // dst (regalloc'd from XMM8..XMM13) + XMM14 + XMM15
            // gives 3 distinct physical xmms within the existing
            // fp_spill_stage_xmms reservation. No ABI change.
            // Int min/max + saturating arith +
            // avgr_u (22 ops). All single-instruction native
            // SSE2/SSE4.1 ops; each wrapper dispatches via
            // emitV128IntBinop with the matching encoder. No new
            // helpers; cranelift maps 1-to-1 (`inst.isle:2470-2486`).
            // f32x4/f64x2 .pmin/pmax (4 ops). Direct
            // dispatch to MINPS/MAXPS/MINPD/MAXPD with operands
            // swapped (dst=c2, src=c1) to align Wasm pseudo-min/max
            // semantics with x86's "return src on equal/NaN/zero".
            // Cranelift maps the same way (`lower.isle:1542-1545`).
            // v128.load + v128.store foundation
            // memory ops. Mirror scalar emitMemOp shape with
            // access_size=16 + MOVUPS final encoding. RAX/RCX/RDX
            // scratches reused (pool-excluded). bounds_fixups +
            // spill_base_off + ins.payload threading mirrors i32.load.
            .@"v128.load" => try op_simd.emitV128Load(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            .@"v128.store" => try op_simd.emitV128Store(allocator, &buf, alloc, &pushed_vregs, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            // v128.load{8,16,32,64}_splat (4 ops).
            // All reuse v128MemPrologue with appropriate access_size
            // + a per-lane-width broadcast tail. 8/16-bit go through
            // GPR (MOVZX + MOVD); 32/64-bit use MOVSS/MOVSD direct
            // load + PSHUFD broadcast.
            .@"v128.load8_splat" => try op_simd.emitV128Load8Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            .@"v128.load16_splat" => try op_simd.emitV128Load16Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            .@"v128.load32_splat" => try op_simd.emitV128Load32Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            .@"v128.load64_splat" => try op_simd.emitV128Load64Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            // v128.load{32,64}_zero (2 ops). Single-
            // instruction MOVSS/MOVSD memory load — the scalar form
            // already zero-extends the upper bits per Intel SDM.
            .@"v128.load32_zero" => try op_simd.emitV128Load32Zero(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            .@"v128.load64_zero" => try op_simd.emitV128Load64Zero(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            // v128.load_lane / store_lane × 4 sizes
            // (8 ops). payload = memarg.offset; extra = lane byte.
            // Uses GPR roundtrip (MOVZX/MOV + PINSR/PEXTR reg-form);
            // store_lane PUSH/POPs RCX around the prologue's RCX-
            // clobbering LEA.
            .@"v128.load8_lane" => try op_simd.emitV128Load8Lane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), ins.extra, func.func_idx),
            .@"v128.load16_lane" => try op_simd.emitV128Load16Lane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), ins.extra, func.func_idx),
            .@"v128.load32_lane" => try op_simd.emitV128Load32Lane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), ins.extra, func.func_idx),
            .@"v128.load64_lane" => try op_simd.emitV128Load64Lane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), ins.extra, func.func_idx),
            .@"v128.store8_lane" => try op_simd.emitV128Store8Lane(allocator, &buf, alloc, &pushed_vregs, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), ins.extra, func.func_idx),
            .@"v128.store16_lane" => try op_simd.emitV128Store16Lane(allocator, &buf, alloc, &pushed_vregs, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), ins.extra, func.func_idx),
            .@"v128.store32_lane" => try op_simd.emitV128Store32Lane(allocator, &buf, alloc, &pushed_vregs, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), ins.extra, func.func_idx),
            .@"v128.store64_lane" => try op_simd.emitV128Store64Lane(allocator, &buf, alloc, &pushed_vregs, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), ins.extra, func.func_idx),
            // v128.load{8x8,16x4,32x2}_{s,u} (6 ops).
            // MOVSD load + PMOVSX/ZX{BW,WD,DQ} extend. No new
            // encoders. Closes the v128 op surface.
            .@"v128.load8x8_s" => try op_simd.emitV128Load8x8S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            .@"v128.load8x8_u" => try op_simd.emitV128Load8x8U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            .@"v128.load16x4_s" => try op_simd.emitV128Load16x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            .@"v128.load16x4_u" => try op_simd.emitV128Load16x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            .@"v128.load32x2_s" => try op_simd.emitV128Load32x2S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            .@"v128.load32x2_u" => try op_simd.emitV128Load32x2U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &oob_fixups, spill_base_off, @as(u32, @intCast(ins.payload)), func.func_idx),
            // Native single-instr multiply-and-add
            // pair. PMULHRSW (SSSE3) implements Q15 multiply-round-
            // saturate exactly per Wasm spec; PMADDWD (SSE2)
            // implements pairwise dot product with wrapping i32
            // accumulation matching the Wasm spec.
            // i16x8.extmul × 4. Cranelift recipe
            // `lower.isle:1197-1285` — PMOVSX/ZX BW each operand
            // (extend i8→i16) + PMULLW. High variants prefix
            // PSHUFD imm=0xEE to swap upper 64 bits down before
            // extending. No new encoders.
            // i32x4.extmul × 4 (i16x8 → i32x4).
            // Same recipe as i16x8.extmul with PMOVSXWD/PMOVZXWD +
            // PMULLD substituted; helpers reused unchanged.
            // i64x2.extmul × 4 (i32x4 → i64x2).
            // Different shape: PMULDQ/PMULUDQ already widen
            // i32→i64, so PSHUFD imm=0x{50,FA} is the only
            // positioning needed (no PMOVSX/ZX prefix).
            // i16x8.extadd_pairwise_i8x16 × 2.
            // PCMPEQB + PABSB synthesises a 0x01-per-byte vector;
            // PMADDUBSW (SSSE3) reduces to pairwise add. No
            // const-pool dep.
            // i32x4.extadd_pairwise_i16x8_s.
            // Inline-synth 0x00010001-per-dword mask + PMADDWD.
            // The _u variant is deferred (PMADDWD reads i16 as
            // signed; u16 inputs need pre-correction via ADR-0042
            // const-pool sign-flip + post-add fixup).
            // i32x4.extadd_pairwise_i16x8_u via
            // sign-flip XOR + PMADDWD-with-+1 + bias-correction-add.
            // 11-instr inline-synth (no const-pool dep) — closes
            // the extadd_pairwise family.
            // i8x16.shuffle via PSHUFB-pair + POR.
            // The handler reads the original Wasm mask from
            // func.simd_consts[ins.payload], derives a-mask /
            // b-mask, and appends both to extra_consts.
            .@"i8x16.shuffle" => {
                const simd_consts_base: u32 = if (func.simd_consts) |sc| @intCast(sc.len) else 0;
                try op_simd_int_cmp_lane.emitI8x16Shuffle(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, &simd_const_fixups, &extra_consts, simd_consts_base, func.simd_consts, @as(u32, @intCast(ins.payload)));
            },
            // v128.const via ADR-0042 const-pool
            // (mirror of ARM64). Lower pass stored
            // const_idx in ins.payload pointing into
            // func.simd_consts.
            .@"v128.const" => try op_simd.emitV128Const(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &simd_const_fixups, @as(u32, @intCast(ins.payload)), spill_base_off),
            // i32x4.trunc_sat_f64x2_s_zero. Recipe
            // needs a shared INT32_MAX_f64-broadcast const; placed
            // into per-emit-pass extra_consts.
            .@"i32x4.trunc_sat_f64x2_s_zero" => {
                const simd_consts_base: u32 = if (func.simd_consts) |sc| @intCast(sc.len) else 0;
                try op_simd_float.emitI32x4TruncSatF64x2SZero(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, &simd_const_fixups, &extra_consts, simd_consts_base);
            },
            // i8x16.popcnt via SSSE3 PSHUFB-LUT
            // (1 op, 2 const-pool entries shared via extra_consts).
            .@"i8x16.popcnt" => {
                const simd_consts_base: u32 = if (func.simd_consts) |sc| @intCast(sc.len) else 0;
                try op_simd_int_arith.emitI8x16Popcnt(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, &simd_const_fixups, &extra_consts, simd_consts_base);
            },
            // f64x2.convert_low_i32x4_u via IEEE-754
            // mantissa-overlay trick (5 instr + 2 const-pool entries).
            .@"f64x2.convert_low_i32x4_u" => {
                const simd_consts_base: u32 = if (func.simd_consts) |sc| @intCast(sc.len) else 0;
                try op_simd_float.emitF64x2ConvertLowI32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, &simd_const_fixups, &extra_consts, simd_consts_base);
            },
            // i32x4.trunc_sat_f64x2_u_zero via the
            // ROUNDPD + ADDPD-magic + SHUFPS-extract recipe per
            // cranelift `lower.isle:5061-5093`.
            .@"i32x4.trunc_sat_f64x2_u_zero" => {
                const simd_consts_base: u32 = if (func.simd_consts) |sc| @intCast(sc.len) else 0;
                try op_simd_float.emitI32x4TruncSatF64x2UZero(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, &simd_const_fixups, &extra_consts, simd_consts_base);
            },
            // STRICT (non-relaxed) f32↔i32 + f64.convert_low_s conversions (D-457).
            // Complete handlers, shared with the relaxed-simd trunc variants below;
            // only the dispatch wiring was missing (validate also rejected them
            // pre-79fd589e).
            .@"f32x4.convert_i32x4_s" => try op_simd_float.emitF32x4ConvertI32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f32x4.convert_i32x4_u" => try op_simd_float.emitF32x4ConvertI32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.convert_low_i32x4_s" => try op_simd_float.emitF64x2ConvertLowI32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.trunc_sat_f32x4_s" => try op_simd_float.emitI32x4TruncSatF32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.trunc_sat_f32x4_u" => try op_simd_float.emitI32x4TruncSatF32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // Remaining float conversions + rounding + narrow + i64x2.extmul
            // (D-457 systemic close): complete handlers, dispatch was unwired —
            // the old corpus never had simd_conversions / *_rounding /
            // simd_i64x2_extmul_i32x4 so the gap stayed hidden.
            .@"f32x4.demote_f64x2_zero" => try op_simd_float.emitF32x4DemoteF64x2Zero(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.promote_low_f32x4" => try op_simd_float.emitF64x2PromoteLowF32x4(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // FP rounding (ROUNDPS/ROUNDPD imm8 mode; SSE4.1).
            .@"f32x4.ceil" => try op_simd_float.emitF32x4Ceil(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f32x4.floor" => try op_simd_float.emitF32x4Floor(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f32x4.trunc" => try op_simd_float.emitF32x4Trunc(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f32x4.nearest" => try op_simd_float.emitF32x4Nearest(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.ceil" => try op_simd_float.emitF64x2Ceil(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.floor" => try op_simd_float.emitF64x2Floor(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.trunc" => try op_simd_float.emitF64x2Trunc(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.nearest" => try op_simd_float.emitF64x2Nearest(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // Saturating narrow (PACKSSWB/PACKUSWB/PACKSSDW/PACKUSDW).
            .@"i8x16.narrow_i16x8_s" => try op_simd_int_cmp_lane.emitI8x16NarrowI16x8S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.narrow_i16x8_u" => try op_simd_int_cmp_lane.emitI8x16NarrowI16x8U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.narrow_i32x4_s" => try op_simd_int_cmp_lane.emitI16x8NarrowI32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.narrow_i32x4_u" => try op_simd_int_cmp_lane.emitI16x8NarrowI32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // i64x2.extmul (PMULDQ/PMULUDQ with low/high lane shuffle).
            .@"i64x2.extmul_low_i32x4_s" => try op_simd_int_cmp_lane.emitI64x2ExtmulLowI32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i64x2.extmul_high_i32x4_s" => try op_simd_int_cmp_lane.emitI64x2ExtmulHighI32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i64x2.extmul_low_i32x4_u" => try op_simd_int_cmp_lane.emitI64x2ExtmulLowI32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i64x2.extmul_high_i32x4_u" => try op_simd_int_cmp_lane.emitI64x2ExtmulHighI32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // Relaxed-SIMD trunc — NaN/OOB → saturating clamp (v2 choice),
            // behaviourally identical to trunc_sat; reuse those emits.
            .@"i32x4.relaxed_trunc_f32x4_s" => try op_simd_float.emitI32x4TruncSatF32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.relaxed_trunc_f32x4_u" => try op_simd_float.emitI32x4TruncSatF32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.relaxed_trunc_f64x2_s_zero" => {
                const simd_consts_base: u32 = if (func.simd_consts) |sc| @intCast(sc.len) else 0;
                try op_simd_float.emitI32x4TruncSatF64x2SZero(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, &simd_const_fixups, &extra_consts, simd_consts_base);
            },
            .@"i32x4.relaxed_trunc_f64x2_u_zero" => {
                const simd_consts_base: u32 = if (func.simd_consts) |sc| @intCast(sc.len) else 0;
                try op_simd_float.emitI32x4TruncSatF64x2UZero(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, &simd_const_fixups, &extra_consts, simd_consts_base);
            },
            // Relaxed-SIMD min/max — RAW MINPS/MAXPS/MINPD/MAXPD (single
            // instr), not the strict NaN/±0-propagating recipe (ADR-0169).
            .@"f32x4.relaxed_min" => try op_simd_float.emitF32x4RelaxedMin(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f32x4.relaxed_max" => try op_simd_float.emitF32x4RelaxedMax(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.relaxed_min" => try op_simd_float.emitF64x2RelaxedMin(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.relaxed_max" => try op_simd_float.emitF64x2RelaxedMax(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // Relaxed-SIMD madd/nmadd — unfused MULPS+ADDPS/SUBPS (no SSE FMA; ADR-0169).
            .@"f32x4.relaxed_madd" => try op_simd_float.emitF32x4RelaxedMadd(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f32x4.relaxed_nmadd" => try op_simd_float.emitF32x4RelaxedNmadd(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.relaxed_madd" => try op_simd_float.emitF64x2RelaxedMadd(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.relaxed_nmadd" => try op_simd_float.emitF64x2RelaxedNmadd(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // Relaxed-SIMD laneselect — full bitwise (a&m)|(b&~m) = exactly
            // v128.bitselect (ADR-0169); lane width irrelevant.
            .@"i8x16.relaxed_laneselect",
            .@"i16x8.relaxed_laneselect",
            .@"i32x4.relaxed_laneselect",
            .@"i64x2.relaxed_laneselect",
            => try op_simd.emitV128Bitselect(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // Relaxed-SIMD q15mulr — overflow → INT16_MAX = strict PMULHRSW
            // saturation (ADR-0169); reuse strict q15mulr_sat_s.
            .@"i16x8.relaxed_q15mulr_s" => try op_simd_int_arith.emitI16x8Q15mulrSatS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // Relaxed-SIMD dot (i8×i8 → i16x8 pairwise): single PMADDUBSW.
            .@"i16x8.relaxed_dot_i8x16_i7x16_s" => try op_simd_int_arith.emitI16x8RelaxedDot(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // Relaxed-SIMD dot+accumulate: PMADDUBSW + PMADDWD(ones) + PADDD(c).
            .@"i32x4.relaxed_dot_i8x16_i7x16_add_s" => try op_simd_int_arith.emitI32x4RelaxedDotAdd(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // i8x16.swizzle (1 op). 10-instr inline
            // recipe synthesises 0x0F broadcast + PCMPGTB-detect of
            // idx>15 + POR-correct + PSHUFB. No const-pool dep.
            // FP unop family (12 ops). abs / neg
            // via inline sign-mask synthesis (PCMPEQB ones +
            // PSLL{D,Q}-imm 31/63); ceil/floor/trunc/nearest via
            // SSE4.1 ROUNDPS/ROUNDPD imm with precision-exception
            // suppression (bit 3 set).
            // select + select_typed share emitSelectCtx.
            // `.select` is in `collected_x86_64_ctx_ops`; `.select_typed`
            // has no Zone 1 meta yet so it stays as an inline switch arm
            // (select_typed needs its own arm since it wasn't covered
            // by the dispatcher path).
            // adapter (handles v128 / fp / GPR 3-path dispatch).
            .select_typed => try op_alu_int.emitSelectCtx(&ctx, &ins),
            // unreachable inline body extracted into
            // `op_control.emitUnreachableCtx` `(ctx, ins)` adapter
            // (ctx extended with `dead_code: *bool` field).
            // nop inline body extracted into
            // `op_control.emitNopCtx` `(ctx, ins)` adapter.
            // drop inline body extracted into
            // `op_control.emitDropCtx` `(ctx, ins)` adapter.
            // return inline body extracted into
            // `op_control.emitReturnCtx` `(ctx, ins)` adapter
            // (ctx extended with `frame_bytes` + `uses_runtime_ptr`).
            // br family extracted into `(ctx, ins)`
            // adapters in op_control. emitBrCtx sets dead_code
            // (br is unconditional); br_if / br_table fall through.
            // if + else extracted into `(ctx, ins)`
            // adapters in op_control.
            .end => {
                // Per ADR-0075: both forms route
                // through op_control.emitEndCtx. Function-level
                // form (label stack empty pre-call) breaks the
                // body loop; intra-function form continues.
                // The try_table patch lives ABOVE the ctx dispatcher
                // (line ~746), since `.end` is now in the ctx
                // tuple — this switch arm is dead-path safety.
                const at_function_end = labels.items.len == 0;
                try op_control.emitEndCtx(&ctx, &ins);
                if (at_function_end) break;
            },
            // D-239 — function-references null-ref branch ops (arm64 parity).
            // D-231 — comptime-guard so v1_0/v2_0 builds DCE the v3 codegen.
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
            else => {
                dbg.print("codegen", "x86_64/emit: UnsupportedOp[body-op-{s}] (func_idx={d})\n", .{ @tagName(ins.op), func.func_idx });
                return Error.UnsupportedOp;
            },
        }
    }

    // See arm64/emit.zig harvest comment.
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
        .oob_stub_off = ctx.oob_stub_off, // ADR-0202 D3
    };
}

/// Compute the i8 displacement for local index `idx`. Layout:
///   local 0 at [RBP - 8],  local K at [RBP - 8*(K+1)]
///       when !uses_runtime_ptr (1-PUSH prologue).
///   local 0 at [RBP - 16], local K at [RBP - 8 - 8*(K+1)]
///       when  uses_runtime_ptr (R15 occupies [RBP-8]).
/// Surfaces `UnsupportedOp` for indices the i8 disp cannot
/// reach (15 locals max either way; coincidentally same cap).
/// localDisp returns i32 (was i8). The i8 form
/// previously capped total_locals at 15 (deepest local at
/// `[RBP - 136]` overflows i8). i32 widening uses the disp32
/// form encoders for slots beyond i8 range; smaller slots stay
/// on the disp8 form via `rbpStoreR{32,64}` / `rbpLoadR{32,64}`
/// auto-helpers that pick form per offset.
///
/// Layout-aware overload via `localDispLayout`.
/// The pure-formula form below remains for non-v128 callers
/// (e.g. test fixtures + scalar emit_test_local sites that
/// hard-code the `(idx+1)*8` shape). v128-aware emit paths must
/// route through `localDispLayout(layout, idx, ...)` so the
/// per-type stride is honoured.
///
/// Re-exported from `emit_setup.zig` per ADR-0081 Phase 1.
/// `emit_test_int.zig` and `emit_test_float.zig` reference this
/// via `emit.localDisp`; the alias preserves their import path.
pub const localDisp = setup.localDisp;

// rbp/rsp form-selectors moved to rbp_disp.zig (D-052 progression);
// aliased at the top of this file so call-sites stay the same.
