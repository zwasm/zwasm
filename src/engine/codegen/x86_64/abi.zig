//! x86_64 calling-convention tables.
//!
//! Mirrors the role of `arm64/abi.zig`'s ABI tables but for the
//! AMD64 / Intel® 64 architecture under the System V x86_64 ABI
//! (Linux, macOS, BSD). Win64 ABI (Windows) lands in a follow-up
//! chunk c2 — selecting between the two adds a `Cc` enum + a
//! per-target binding layer that emit.zig consumes; today there
//! is no x86_64 emit pass yet so the second-CC plumbing has no
//! consumer.
//!
//! Per the AMD64 ABI v0.99.6 §3.2:
//!
//!   RAX                  primary return value
//!   RDX                  secondary return (128-bit / pair)
//!   RDI, RSI, RDX, RCX,
//!   R8, R9               integer args (in order; 6 regs)
//!   XMM0..XMM7           FP args (in order; 8 regs)
//!   XMM0, XMM1           FP return values
//!   RBX, RBP, R12, R13,
//!   R14, R15             callee-saved (preserved across calls)
//!   RAX, RCX, RDX, RSI,
//!   RDI, R8, R9, R10,
//!   R11, XMM0..XMM15     caller-saved (volatile across calls)
//!   RSP                  stack pointer
//!   R10                  static chain (rarely used)
//!   R11                  intra-procedure scratch (PLT, etc.)
//!
//! Declarative ABI tables + the
//! `slotToReg` / `fpSlotToReg` mappers + the **single-
//! reservation invariant model per ADR-0026** (R15 holds the
//! saved runtime ptr; other JitRuntime invariants reload from
//! [R15 + offset] at point of use).
//!
//! One load-bearing consumer remains intentionally deferred:
//!
//!   - **`spill_stage_gprs`** (mirrors arm64's X14/X15). Awaits
//!     the spill-aware emit port that mirrors arm64's sub-1c.
//!
//! Win64 ABI tables live alongside SysV in this file — see the
//! `sysv` and `win64` namespaces and the `Cc` enum below. The
//! emit-side Cc-pivot wiring (selecting `arg_gprs` etc. per
//! target at compile time per ADR-0026 line 229-232). Today
//! the top-level aliases (`arg_gprs`, `return_gpr`, …)
//! continue to expose the SysV values so existing emit byte-
//! tests are unchanged.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");

const reg_class = @import("reg_class.zig");

pub const Gpr = reg_class.Gpr;
pub const Xmm = reg_class.Xmm;

/// First 6 GPR arg slots per System V x86_64 ABI §3.2.3, in
/// canonical pass order (arg0 → RDI, arg1 → RSI, …).
pub const arg_gprs = [_]Gpr{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

/// First 8 XMM slots carry FP args per System V §3.2.3 (arg0 →
/// XMM0, arg1 → XMM1, …, arg7 → XMM7).
pub const arg_xmms = [_]Xmm{ .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7 };

/// Primary integer return register (RAX). Secondary (RDX) is
/// used for 128-bit / pair returns; emit currently rejects
/// multi-result so RDX-as-return-2 is unimplemented.
pub const return_gpr: Gpr = .rax;

/// Primary FP return register (XMM0). Secondary (XMM1) is used
/// for pair returns; same multi-result restriction applies.
pub const return_xmm: Xmm = .xmm0;

/// Callee-saved (non-volatile) GPRs per System V §3.2.1. Callee
/// must preserve these across calls; saved in prologue, restored
/// in epilogue. Note: this set is identical to the SysV-∩-Win64
/// intersection (Win64 also has RBX/RBP/R12-R15 as callee-saved
/// plus RDI/RSI), so picking from this list keeps a future Cc-
/// agnostic reservation portable.
pub const callee_saved_gprs = [_]Gpr{ .rbx, .rbp, .r12, .r13, .r14, .r15 };

/// Caller-saved (volatile) GPRs per System V §3.2.1. Caller must
/// save these before a call if the value is needed afterwards.
/// Includes the 6 arg regs + RAX (return) + R10 (static chain) +
/// R11 (intra-procedure scratch).
pub const caller_saved_gprs = [_]Gpr{ .rax, .rcx, .rdx, .rdi, .rsi, .r8, .r9, .r10, .r11 };

/// Stack pointer (always RSP per AMD64 spec).
pub const stack_pointer: Gpr = .rsp;

/// Frame pointer (RBP by convention; AMD64 omits-frame-pointer
/// is permitted). Phase 7.7 emit will adopt the non-FP shape
/// per ROADMAP P3 (cold-start; smaller prologue) unless the
/// ADR-0017 mapping for x86_64 prologue revisits this.
pub const frame_pointer: Gpr = .rbp;

/// Caller-saved scratch GPRs other than args / return. Per
/// D-045 chunk 13b, R10 + R11 have been removed from the
/// allocatable pool — they are now reserved as
/// `spill_stage_gprs` (consumed by `gpr.zig`'s spill-aware
/// helpers). The constant remains as an empty slice so the
/// `allocatable_gprs = scratch ++ callee_saved` shape stays
/// readable.
pub const allocatable_caller_saved_scratch_gprs = [_]Gpr{};

/// Reserved for runtime-ptr save per ADR-0026. Mirrors the
/// role of arm64's `runtime_ptr_save_gpr` (X19, ADR-0017
/// sub-2d-ii): the function prologue captures the inbound RDI
/// (`*const JitRuntime`) into R15, and every memory op /
/// call_indirect / host call reloads other JitRuntime
/// invariants from `[R15 + offset]` at point of use.
///
/// R15 is callee-saved in BOTH System V x86_64 and Win64, so
/// the reservation is Cc-agnostic. Caller-saved RDI carries
/// the runtime ptr at function entry per ADR-0017 / SysV
/// §3.2.3; the prologue's `MOV R15, RDI` snapshots it before
/// any call site can clobber RDI.
pub const runtime_ptr_save_gpr: Gpr = .r15;

/// Reserved-from-the-pool set per ADR-0026. Single-reservation
/// model: only R15 (= `runtime_ptr_save`). Other JitRuntime
/// invariants (vm_base / mem_limit / funcptr_base / table_size
/// / typeidx_base) reload from `[R15 + offset]` at point of use
/// rather than holding callee-saved slots — the arm64 mirror
/// model (`arm64/abi.zig::reserved_invariant_gprs`) is
/// unworkable on x86_64 because
/// only 6 callee-saved GPRs exist total and `frame_pointer`
/// (RBP) takes one. See ADR-0026 §"Decision".
pub const reserved_invariant_gprs = [_]Gpr{runtime_ptr_save_gpr};

/// Allocatable callee-saved GPRs = `callee_saved_gprs` minus
/// `frame_pointer` (RBP) minus `reserved_invariant_gprs` (R15).
/// Four regs (RBX, R12, R13, R14). Kept as its own constant
/// so `allocatable_gprs` reads cleanly and `audit_scaffolding`
/// can spot-check the reservation invariant (mirrors arm64
/// `allocatable_callee_saved_gprs`).
pub const allocatable_callee_saved_gprs = [_]Gpr{ .rbx, .r12, .r13, .r14 };

/// Pool of GPRs the regalloc may freely use, in priority order:
/// caller-saved scratch first (cheapest, no prologue save),
/// then allocatable callee-saved (forces save/restore but
/// invariant-safe).
///
/// **Excluded from the pool by construction**:
///   - RDI, RSI, RDX, RCX, R8, R9 (arg marshalling — caller
///     must own these around call sites)
///   - RAX (return slot)
///   - RSP (stack pointer)
///   - RBP (frame pointer per the prologue convention; ADR-0026
///     §"Frame-pointer policy")
///   - R15 (`reserved_invariant_gprs` per ADR-0026)
///   - R10, R11 (`spill_stage_gprs` per D-045 chunk 13b — used
///     to stage spilled vregs through physical regs in the
///     spill-aware emit path)
///
/// Pool size: 4 (RBX, R12, R13, R14) post-13b. For comparison
/// arm64's pool is 8 — x86_64 has fewer GPRs to start with
/// (16 vs 31), so the asymmetry is structural and accepted
/// per P3 (cold-start) / ADR-0026.
pub const allocatable_gprs = allocatable_caller_saved_scratch_gprs ++ allocatable_callee_saved_gprs;

// Compile-time invariant: allocatable_gprs is pairwise disjoint
// with arg_gprs / return_gpr / stack_pointer / frame_pointer /
// reserved_invariant_gprs — the arm64-style W54-class structural
// fix against pool/role overlap (per ADR-0018; same shape as
// arm64/abi.zig comptime block).
comptime {
    for (allocatable_gprs) |a| {
        for (arg_gprs) |arg| {
            if (a == arg) @compileError("regalloc pool overlaps arg_gprs — SysV §3.2.3 invariant violated");
        }
        if (a == return_gpr) @compileError("regalloc pool overlaps return_gpr — SysV §3.2.1 invariant violated");
        if (a == stack_pointer) @compileError("regalloc pool overlaps stack_pointer");
        if (a == frame_pointer) @compileError("regalloc pool overlaps frame_pointer — ADR-0026 prologue convention violated");
        for (reserved_invariant_gprs) |r| {
            if (a == r) @compileError("regalloc pool overlaps reserved_invariant_gprs — ADR-0026 invariant violated");
        }
        // D-045 chunk 13b: pool ∩ spill_stage = ∅. Stage regs
        // are reserved exclusively for `gpr.zig`'s spill-aware
        // helpers; allowing the regalloc to assign them would
        // race with handlers that load spilled operands into
        // them mid-instruction.
        for (spill_stage_gprs) |s| {
            if (a == s) @compileError("regalloc pool overlaps spill_stage_gprs — D-045 13b invariant violated");
        }
    }
    // Same disjointness for the FP / XMM side.
    for (allocatable_xmms) |a| {
        for (fp_spill_stage_xmms) |s| {
            if (a == s) @compileError("regalloc XMM pool overlaps fp_spill_stage_xmms — D-045 13b invariant violated");
        }
    }
}

/// XMM regalloc pool. SysV calls have all of XMM0..XMM15 as
/// caller-saved, so we use XMM6..XMM15 (skipping the arg regs
/// XMM0..XMM5 which marshal at call sites; XMM6, XMM7 are also
/// arg slots 6/7 — but realistic functions take ≤ 6 FP args so
/// XMM6/XMM7 are usable for vregs in the common case). XMM7
/// is reserved as a SIMD scratch (mirroring arm64's V31 popcnt
/// scratch); the regalloc pool starts at XMM8.
///
/// TODO(p7-7.7): when emit.zig has a concrete consumer, decide
/// whether to make XMM6/XMM7 allocatable and arrange call-site
/// save/restore — saving 2 slots may matter for FP-heavy code.
pub const allocatable_xmms = [_]Xmm{
    .xmm8, .xmm9, .xmm10, .xmm11, .xmm12, .xmm13,
};

/// Spill staging GPRs (mirrors arm64's `spill_stage_gprs` =
/// X14/X15 per ADR-0021). Used by `x86_64/gpr.zig`'s spill-aware
/// helpers (`gprLoadSpilled` / `gprDefSpilled` / `gprStoreSpilled`)
/// to pipe a spilled vreg through a physical register on the way
/// to/from the spill frame slot.
///
/// **Choice**: R10/R11 — caller-saved scratch in both SysV
/// (§3.2.1 "static chain" / "intra-procedure scratch") and Win64
/// (caller-clobberable, not used for arg passing or returns).
/// These are the only x86_64 GPRs that are caller-saved AND not
/// otherwise reserved AND ABI-portable (RAX/RDX = return; RCX =
/// shift count + Win64 arg0; RDX/R8/R9 = args).
///
/// **Two stage regs** (matching arm64's count) so binary ops can
/// stage two spilled operands without collision (`stage_idx`
/// 0 → R10, 1 → R11).
pub const spill_stage_gprs = [_]Gpr{ .r10, .r11 };

/// XMM-class counterpart of `spill_stage_gprs`. XMM14/XMM15 are
/// caller-saved under SysV (§3.2.3) and callee-saved under Win64, where
/// XMM6-XMM15 all are; the JIT saves none of them, so both host→JIT seams
/// carry the whole range — `entry.jit_cohort_clobbers` for the trampoline and
/// `entry.x86_64_win64_call_clobbers` for the mixed-result thunks (#286).
pub const fp_spill_stage_xmms = [_]Xmm{ .xmm14, .xmm15 };

/// The Microsoft x64 ABI's non-volatile XMMs. Pure data, so a containment
/// check against the pools compiles on any host — which is what lets the
/// cohort coverage test in `entry.zig` run somewhere other than Windows.
/// Every register the JIT may touch has to be inside this set for the
/// host→JIT seams to be able to cover it: the regalloc pool, the spill stage,
/// `xmm7` (the SIMD scratch this file reserves above) and `xmm6` (the
/// conversion scratch in `op_convert.zig`).
pub const win64_nonvolatile_xmms = [_]Xmm{
    .xmm6,  .xmm7,  .xmm8,  .xmm9,  .xmm10,
    .xmm11, .xmm12, .xmm13, .xmm14, .xmm15,
};

/// Translate a regalloc slot id (from `engine/codegen/shared/
/// regalloc.compute`) into a concrete GPR via the allocatable
/// pool. Returns null when the slot id exceeds the pool size —
/// the emit pass treats that as a cue to spill.
pub fn slotToReg(slot_id: u16) ?Gpr {
    if (slot_id >= allocatable_gprs.len) return null;
    return allocatable_gprs[slot_id];
}

/// FP-class counterpart of `slotToReg`.
pub fn fpSlotToReg(slot_id: u16) ?Xmm {
    if (slot_id >= allocatable_xmms.len) return null;
    return allocatable_xmms[slot_id];
}

/// Is `g` caller-saved per SysV x86_64? Used by emit to decide
/// whether a vreg held in `g` needs a save before a call.
pub fn isCallerSaved(g: Gpr) bool {
    for (caller_saved_gprs) |c| {
        if (c == g) return true;
    }
    return false;
}

/// Is `g` callee-saved per SysV x86_64? Inverse of caller-saved
/// for the allocatable range; RSP returns false.
pub fn isCalleeSaved(g: Gpr) bool {
    for (callee_saved_gprs) |c| {
        if (c == g) return true;
    }
    return false;
}

// ============================================================
// Calling convention selector + per-Cc tables
// ============================================================

/// x86_64 calling convention. Selected at zwasm compile time
/// (per ADR-0026 line 229-232: "Cc selection happens at compile
/// time of zwasm itself, not at JIT time"). The emit pass
/// consumes the right namespace via comptime; there is no
/// runtime dispatch.
pub const Cc = enum { sysv, win64 };

/// System V x86_64 ABI tables (Linux, macOS, BSD). Mirror of
/// the top-level `arg_gprs` / `return_gpr` / etc. aliases — kept
/// here so `abi.sysv.X` reads symmetrically with `abi.win64.X`
/// in future Cc-pivot wiring. The top-level aliases continue to
/// expose these same values for existing callers.
pub const sysv = struct {
    pub const arg_gprs = [_]Gpr{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };
    pub const arg_xmms = [_]Xmm{ .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7 };
    pub const return_gpr: Gpr = .rax;
    pub const return_xmm: Xmm = .xmm0;
    pub const callee_saved_gprs = [_]Gpr{ .rbx, .rbp, .r12, .r13, .r14, .r15 };
    pub const caller_saved_gprs = [_]Gpr{ .rax, .rcx, .rdx, .rdi, .rsi, .r8, .r9, .r10, .r11 };
    /// Allocatable GPRs under SysV (D-045 chunk 13b: 4 regs;
    /// R10/R11 reserved as spill-stage). Mirrors top-level
    /// `allocatable_gprs` for symmetry with `win64.allocatable_gprs`.
    pub const allocatable_gprs = [_]Gpr{ .rbx, .r12, .r13, .r14 };
    /// SysV does not reserve a shadow space below the call site.
    pub const shadow_space_bytes: u32 = 0;
    /// First arg in RDI per SysV §3.2.3 — the entry shim's
    /// `MOV R15, RDI` snapshots `*const JitRuntime` into the
    /// runtime-ptr-save register.
    pub const entry_arg0_gpr: Gpr = .rdi;
    pub const runtime_ptr_save_gpr: Gpr = .r15;
};

/// Microsoft Win64 ABI tables (Windows x86_64). Differs from
/// SysV in three load-bearing ways:
///
/// 1. **Arg regs**: RCX/RDX/R8/R9 (only 4 GPRs), XMM0..XMM3
///    (only 4 XMMs). FP and integer args share positions —
///    arg_n in either RXX_n or XMMn but not both.
/// 2. **Callee-saved**: RDI/RSI promoted to callee-saved (vs
///    SysV's caller-saved). Pool grows by 2 if Win64 is the
///    target.
/// 3. **Shadow space**: 32 bytes reserved by the caller below
///    the call site. The callee owns these bytes (may spill
///    its 4 register args there).
///
/// R15 reservation stays Cc-agnostic (callee-saved in both
/// ABIs); only the entry-arg0 register changes (`RCX` here vs
/// `RDI` for SysV). See ADR-0026 line 225-232.
pub const win64 = struct {
    pub const arg_gprs = [_]Gpr{ .rcx, .rdx, .r8, .r9 };
    pub const arg_xmms = [_]Xmm{ .xmm0, .xmm1, .xmm2, .xmm3 };
    pub const return_gpr: Gpr = .rax;
    pub const return_xmm: Xmm = .xmm0;
    pub const callee_saved_gprs = [_]Gpr{ .rbx, .rbp, .rdi, .rsi, .r12, .r13, .r14, .r15 };
    pub const caller_saved_gprs = [_]Gpr{ .rax, .rcx, .rdx, .r8, .r9, .r10, .r11 };
    pub const shadow_space_bytes: u32 = 32;
    pub const entry_arg0_gpr: Gpr = .rcx;
    pub const runtime_ptr_save_gpr: Gpr = .r15;

    /// Allocatable GPRs under Win64. Two more than SysV because
    /// RDI + RSI are callee-saved here (caller-saved on SysV).
    /// **Order intentionally mirrors SysV for slots 0..5** so a
    /// codegen pass that uses ≤ 6 slots produces identical
    /// register choices under both ABIs (lets Mac-host byte-
    /// level emit tests stay encoding-stable when the build
    /// target switches). Slots 6/7 add RDI/RSI as a Win64-only
    /// extension. RBP is the frame pointer; R15 is the reserved
    /// runtime-ptr-save register.
    pub const allocatable_gprs = [_]Gpr{ .rbx, .r12, .r13, .r14, .rdi, .rsi };
};

// ============================================================
// Compile-time selected current Cc + alias namespace
// ============================================================

const builtin = @import("builtin");

/// The active calling convention for this zwasm build, selected
/// at compile time per ADR-0026 line 229-232. emit.zig consumes
/// `abi.current.X` to produce ABI-correct prologue / call-site
/// marshalling without any runtime branch.
pub const current_cc: Cc = switch (builtin.target.os.tag) {
    .windows => .win64,
    else => .sysv,
};

/// Alias to the active Cc's table namespace. Use as
/// `abi.current.entry_arg0_gpr`, `abi.current.arg_gprs`, etc.
/// On macOS / Linux / BSD targets this points at `sysv`; on
/// Windows targets at `win64`.
pub const current = switch (current_cc) {
    .sysv => sysv,
    .win64 => win64,
};

// Compile-time invariants for the Win64 pool — same shape as
// the SysV block above (W54-class structural fix against
// pool/role overlap).
comptime {
    for (win64.allocatable_gprs) |a| {
        for (win64.arg_gprs) |arg| {
            if (a == arg) @compileError("win64 regalloc pool overlaps win64.arg_gprs — Microsoft x64 §arg-passing violated");
        }
        if (a == win64.return_gpr) @compileError("win64 regalloc pool overlaps win64.return_gpr");
        if (a == stack_pointer) @compileError("win64 regalloc pool overlaps stack_pointer");
        if (a == frame_pointer) @compileError("win64 regalloc pool overlaps frame_pointer");
        if (a == win64.runtime_ptr_save_gpr) @compileError("win64 regalloc pool overlaps win64.runtime_ptr_save_gpr — ADR-0026 invariant violated");
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "arg_gprs covers RDI, RSI, RDX, RCX, R8, R9 in SysV order" {
    try testing.expectEqual(@as(usize, 6), arg_gprs.len);
    try testing.expectEqual(Gpr.rdi, arg_gprs[0]);
    try testing.expectEqual(Gpr.rsi, arg_gprs[1]);
    try testing.expectEqual(Gpr.rdx, arg_gprs[2]);
    try testing.expectEqual(Gpr.rcx, arg_gprs[3]);
    try testing.expectEqual(Gpr.r8, arg_gprs[4]);
    try testing.expectEqual(Gpr.r9, arg_gprs[5]);
}

test "arg_xmms covers XMM0..XMM7" {
    try testing.expectEqual(@as(usize, 8), arg_xmms.len);
    try testing.expectEqual(Xmm.xmm0, arg_xmms[0]);
    try testing.expectEqual(Xmm.xmm7, arg_xmms[7]);
}

test "callee_saved_gprs covers RBX, RBP, R12..R15" {
    try testing.expectEqual(@as(usize, 6), callee_saved_gprs.len);
    try testing.expectEqual(Gpr.rbx, callee_saved_gprs[0]);
    try testing.expectEqual(Gpr.rbp, callee_saved_gprs[1]);
    try testing.expectEqual(Gpr.r12, callee_saved_gprs[2]);
    try testing.expectEqual(Gpr.r15, callee_saved_gprs[5]);
}

test "return_gpr is RAX, return_xmm is XMM0" {
    try testing.expectEqual(Gpr.rax, return_gpr);
    try testing.expectEqual(Xmm.xmm0, return_xmm);
}

test "allocatable_gprs is 4 regs (RBX, R12..R14) post-D-045-13b" {
    // D-045 chunk 13b: R10/R11 removed from the pool — reserved
    // as spill-stage regs for spill-aware emit.
    try testing.expectEqual(@as(usize, 4), allocatable_gprs.len);
    try testing.expectEqual(Gpr.rbx, allocatable_gprs[0]);
    try testing.expectEqual(Gpr.r12, allocatable_gprs[1]);
    try testing.expectEqual(Gpr.r13, allocatable_gprs[2]);
    try testing.expectEqual(Gpr.r14, allocatable_gprs[3]);
}

test "allocatable_gprs is disjoint from arg/return/SP/FP/reserved at runtime" {
    for (allocatable_gprs) |a| {
        for (arg_gprs) |arg| try testing.expect(a != arg);
        try testing.expect(a != return_gpr);
        try testing.expect(a != stack_pointer);
        try testing.expect(a != frame_pointer);
        for (reserved_invariant_gprs) |r| try testing.expect(a != r);
    }
}

test "runtime_ptr_save_gpr is R15 (ADR-0026 reservation)" {
    try testing.expectEqual(Gpr.r15, runtime_ptr_save_gpr);
    try testing.expectEqual(@as(usize, 1), reserved_invariant_gprs.len);
    try testing.expectEqual(Gpr.r15, reserved_invariant_gprs[0]);
}

test "slotToReg: slot 0 → RBX (first allocatable post-13b; R10/R11 are spill-stage)" {
    try testing.expectEqual(Gpr.rbx, slotToReg(0).?);
}

test "slotToReg: slot 3 → R14 (last in the 4-slot pool post-13b)" {
    try testing.expectEqual(Gpr.r14, slotToReg(3).?);
}

test "slotToReg: slot 4 returns null (pool exhausted; spill territory)" {
    try testing.expect(slotToReg(4) == null);
}

test "fpSlotToReg: slot 0 → XMM8 (first allocatable XMM after arg regs)" {
    try testing.expectEqual(Xmm.xmm8, fpSlotToReg(0).?);
}

test "fpSlotToReg: slot 5 → XMM13 (last in the 6-slot pool post-13b; XMM14/15 spill-stage)" {
    try testing.expectEqual(Xmm.xmm13, fpSlotToReg(5).?);
}

test "fpSlotToReg: slot 6 returns null" {
    try testing.expect(fpSlotToReg(6) == null);
}

test "isCallerSaved: SysV caller-saved set" {
    try testing.expect(isCallerSaved(.rax));
    try testing.expect(isCallerSaved(.rcx));
    try testing.expect(isCallerSaved(.rdi));
    try testing.expect(isCallerSaved(.r10));
    try testing.expect(isCallerSaved(.r11));
    try testing.expect(!isCallerSaved(.rbx));
    try testing.expect(!isCallerSaved(.r15));
}

test "isCalleeSaved: SysV callee-saved set" {
    try testing.expect(isCalleeSaved(.rbx));
    try testing.expect(isCalleeSaved(.rbp));
    try testing.expect(isCalleeSaved(.r12));
    try testing.expect(isCalleeSaved(.r15));
    try testing.expect(!isCalleeSaved(.rax));
    try testing.expect(!isCalleeSaved(.rdi));
    try testing.expect(!isCalleeSaved(.rsp));
}

test "frame_pointer + stack_pointer tracked" {
    try testing.expectEqual(Gpr.rbp, frame_pointer);
    try testing.expectEqual(Gpr.rsp, stack_pointer);
}

// Win64 ABI tables (Microsoft x64 calling convention). Tracked
// alongside the SysV tables but not yet consumed by emit.zig.
// ADR-0026 line 225-232 documents the relationship.

test "Cc enum lists the two x86_64 calling conventions" {
    try testing.expectEqual(Cc.sysv, @as(Cc, .sysv));
    try testing.expectEqual(Cc.win64, @as(Cc, .win64));
}

test "win64.arg_gprs covers RCX, RDX, R8, R9 in Win64 order (4 regs vs SysV's 6)" {
    try testing.expectEqual(@as(usize, 4), win64.arg_gprs.len);
    try testing.expectEqual(Gpr.rcx, win64.arg_gprs[0]);
    try testing.expectEqual(Gpr.rdx, win64.arg_gprs[1]);
    try testing.expectEqual(Gpr.r8, win64.arg_gprs[2]);
    try testing.expectEqual(Gpr.r9, win64.arg_gprs[3]);
}

test "win64.arg_xmms covers XMM0..XMM3 (4 regs vs SysV's 8)" {
    try testing.expectEqual(@as(usize, 4), win64.arg_xmms.len);
    try testing.expectEqual(Xmm.xmm0, win64.arg_xmms[0]);
    try testing.expectEqual(Xmm.xmm3, win64.arg_xmms[3]);
}

test "win64.return_gpr is RAX, win64.return_xmm is XMM0 (same as SysV)" {
    try testing.expectEqual(Gpr.rax, win64.return_gpr);
    try testing.expectEqual(Xmm.xmm0, win64.return_xmm);
}

test "win64.callee_saved_gprs adds RDI/RSI vs SysV (8 regs total)" {
    try testing.expectEqual(@as(usize, 8), win64.callee_saved_gprs.len);
    // RDI + RSI are callee-saved under Win64 (caller-saved under SysV).
    var saw_rdi = false;
    var saw_rsi = false;
    for (win64.callee_saved_gprs) |g| {
        if (g == .rdi) saw_rdi = true;
        if (g == .rsi) saw_rsi = true;
    }
    try testing.expect(saw_rdi);
    try testing.expect(saw_rsi);
}

test "win64.caller_saved_gprs excludes RDI/RSI (the SysV/Win64 divergence)" {
    for (win64.caller_saved_gprs) |g| {
        try testing.expect(g != .rdi);
        try testing.expect(g != .rsi);
    }
}

test "win64.shadow_space_bytes = 32 (Microsoft x64 mandates 32-byte shadow)" {
    try testing.expectEqual(@as(u32, 32), win64.shadow_space_bytes);
}

test "sysv.shadow_space_bytes = 0 (SysV has no shadow space)" {
    try testing.expectEqual(@as(u32, 0), sysv.shadow_space_bytes);
}

test "win64.runtime_ptr_save_gpr is R15 (Cc-agnostic per ADR-0026)" {
    try testing.expectEqual(Gpr.r15, win64.runtime_ptr_save_gpr);
}

test "win64.entry_arg0_gpr is RCX (Win64 first arg)" {
    // SysV passes *const JitRuntime in RDI; Win64 in RCX. The
    // entry shim's `MOV R15, <arg0>` differs by Cc.
    try testing.expectEqual(Gpr.rcx, win64.entry_arg0_gpr);
    try testing.expectEqual(Gpr.rdi, sysv.entry_arg0_gpr);
}

test "win64.allocatable_gprs adds RDI+RSI vs SysV (6 regs vs 4) post-D-045-13b" {
    // D-045 chunk 13b: R10/R11 removed from the pool. SysV pool
    // is 4 (RBX, R12..R14); Win64 adds RDI+RSI for 6.
    try testing.expectEqual(@as(usize, 6), win64.allocatable_gprs.len);
}

test "win64.allocatable_gprs slots 0..3 mirror SysV (cross-Cc test stability)" {
    // Slot 0..3 must agree byte-for-byte with SysV so tests that
    // exercise ≤ 4 slots produce identical encodings under both
    // ABIs. RDI/RSI are appended as slots 4 / 5 post-13b.
    try testing.expectEqual(allocatable_gprs[0], win64.allocatable_gprs[0]);
    try testing.expectEqual(allocatable_gprs[3], win64.allocatable_gprs[3]);
    try testing.expectEqual(Gpr.rdi, win64.allocatable_gprs[4]);
    try testing.expectEqual(Gpr.rsi, win64.allocatable_gprs[5]);
}

test "current_cc matches the build target (.windows → .win64; else → .sysv)" {
    const expected: Cc = switch (builtin.target.os.tag) {
        .windows => .win64,
        else => .sysv,
    };
    try testing.expectEqual(expected, current_cc);
}

test "current.entry_arg0_gpr and runtime_ptr_save_gpr match the active Cc" {
    switch (current_cc) {
        .sysv => {
            try testing.expectEqual(Gpr.rdi, current.entry_arg0_gpr);
            try testing.expectEqual(Gpr.r15, current.runtime_ptr_save_gpr);
        },
        .win64 => {
            try testing.expectEqual(Gpr.rcx, current.entry_arg0_gpr);
            try testing.expectEqual(Gpr.r15, current.runtime_ptr_save_gpr);
        },
    }
}
