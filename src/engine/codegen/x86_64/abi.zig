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

/// The argument registers the pool also hands out (slots 4-7): all four
/// carry arguments under SysV, R8/R9 under Win64.
pub const allocatable_arg_gprs = [_]Gpr{ .rsi, .rdi, .r8, .r9 };

/// The regalloc pool, callee-saved first: slots 0-3 are the only homes for
/// register-homed locals (ADR-0155), which stay put across runtime callouts.
/// RSI/RDI/R8/R9 are argument registers; a value live across a call goes to
/// a slot (ADR-0060), the call family moves its arguments in parallel
/// (`gpr.ParallelMove`), and the other handlers that write them are fenced
/// (`op_regs`, ADR-0077). Out of the pool: RAX/RCX/RDX (fixed roles in
/// division, shifts and the memory ops), RSP, RBP, R15 (ADR-0026), R10/R11
/// (spill stage).
pub const allocatable_gprs = allocatable_callee_saved_gprs ++ allocatable_arg_gprs;

comptime {
    const fixed = [_]Gpr{ .rax, .rcx, .rdx, stack_pointer, frame_pointer } ++ reserved_invariant_gprs ++ spill_stage_gprs;
    for (allocatable_gprs) |a| {
        for (fixed) |f| {
            if (a == f) @compileError("regalloc pool holds " ++ @tagName(a) ++ ", which has a fixed role");
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
///    SysV's caller-saved). The pool is the same under both.
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

// ============================================================
// ADR-0077 op-internal register reservations
// ============================================================

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const jit_abi = @import("../shared/jit_abi.zig");

const zir_op_count = @typeInfo(zir.ZirOp).@"enum".fields.len;

/// What an op's handler writes outside the value it defines, stated as
/// registers. The slot ids the regalloc fences follow from the pool, so a
/// register that is not in it fences nothing.
const OpRegs = struct {
    /// Scratch with no call around it: a vreg live across the op loses it.
    scratch: []const Gpr = &.{},
    /// Written before the handler has read every operand.
    operand: []const Gpr = &.{},
};

/// The call family (`call`, `call_indirect`, `call_ref`, `return_call*`)
/// moves its arguments in parallel (`gpr.ParallelMove`) and reserves nothing.
const op_regs: [zir_op_count]OpRegs = blk: {
    @setEvalBranchQuota(100_000);
    var t = [_]OpRegs{.{}} ** zir_op_count;
    t[@intFromEnum(zir.ZirOp.@"memory.init")] = .{ .scratch = &.{ .rdi, .r8, .r9 } };
    t[@intFromEnum(zir.ZirOp.@"table.set")] = .{ .scratch = &.{.r9} };
    for ([_]zir.ZirOp{ .@"table.fill", .@"table.copy", .@"table.init" }) |op| {
        t[@intFromEnum(op)] = .{ .scratch = &.{ .rsi, .rdi, .r8, .r9 }, .operand = &.{.r8} };
    }
    // Callouts that route their operands into the argument registers one at a
    // time, so an early argument can land on a later operand.
    for ([_]zir.ZirOp{
        .@"array.copy", .@"array.fill",     .@"array.init_data", .@"array.init_elem",
        .@"array.new",  .@"array.new_data", .@"array.new_elem",  .@"table.grow",
    }) |op| {
        t[@intFromEnum(op)] = .{ .operand = &current.arg_gprs };
    }
    for (0..zir_op_count) |i| {
        const op: zir.ZirOp = @enumFromInt(i);
        if (jit_abi.isAtomicRmw(op) or jit_abi.isAtomicCmpxchg(op) or
            jit_abi.isAtomicNotify(op) or jit_abi.isAtomicWait(op))
        {
            t[i] = .{ .operand = &current.arg_gprs };
        }
    }
    break :blk t;
};

fn poolSlots(comptime regs: []const Gpr) []const u16 {
    comptime {
        var ids: [regs.len]u16 = undefined;
        var n: usize = 0;
        for (regs) |r| {
            for (allocatable_gprs, 0..) |p, i| {
                if (p == r) {
                    ids[n] = i;
                    n += 1;
                }
            }
        }
        const out = ids[0..n].*;
        return &out;
    }
}

fn slotTable(comptime field: []const u8) [zir_op_count][]const u16 {
    @setEvalBranchQuota(100_000);
    var t: [zir_op_count][]const u16 = undefined;
    for (op_regs, 0..) |e, i| t[i] = poolSlots(@field(e, field));
    return t;
}

const op_scratch_slots = slotTable("scratch");
const op_operand_slots = slotTable("operand");

comptime {
    @setEvalBranchQuota(100_000);
    regalloc.validateRegallocOpScratchReservation(op_scratch_slots, allocatable_gprs.len);
    regalloc.validateRegallocOpScratchReservation(op_operand_slots, allocatable_gprs.len);
}

const local_homing = @import("../../../ir/analysis/local_homing.zig");

// A register-homed local holds a slot below `n_home_gpr` for the whole
// function and is saved only around the call family (D-268), so those slots
// must be callee-saved under both conventions and fenced by no op.
// `local_homing` sizes itself for the build target, so only an x86_64 target
// is checked against this pool.
comptime {
    if (builtin.target.cpu.arch == .x86_64) {
        @setEvalBranchQuota(100_000);
        if (local_homing.n_allocatable_gpr != allocatable_gprs.len) @compileError("local_homing.n_allocatable_gpr is not the pool size");
        for (allocatable_gprs[0..local_homing.n_home_gpr]) |g| {
            if (!isCalleeSaved(g)) @compileError("a home slot holds " ++ @tagName(g) ++ ", which a C callee may clobber");
        }
        for (op_scratch_slots ++ op_operand_slots) |sids| {
            for (sids) |sid| {
                if (sid < local_homing.n_home_gpr) @compileError("an op fences a home slot");
            }
        }
    }
}

/// `shared/regalloc.zig::ScratchReservationFn` for x86_64.
pub fn opScratchReservation(op: zir.ZirOp) regalloc.Reservation {
    const i = @intFromEnum(op);
    return .{ .scratch = op_scratch_slots[i], .operand = op_operand_slots[i] };
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

test "allocatable_gprs: the callee-saved four, then RSI, RDI, R8, R9" {
    try testing.expectEqualSlices(Gpr, &.{ .rbx, .r12, .r13, .r14, .rsi, .rdi, .r8, .r9 }, &allocatable_gprs);
}

test "runtime_ptr_save_gpr is R15 (ADR-0026 reservation)" {
    try testing.expectEqual(Gpr.r15, runtime_ptr_save_gpr);
    try testing.expectEqual(@as(usize, 1), reserved_invariant_gprs.len);
    try testing.expectEqual(Gpr.r15, reserved_invariant_gprs[0]);
}

test "slotToReg: slot 0 → RBX, slot 7 → R9, slot 8 → null (spill territory)" {
    try testing.expectEqual(Gpr.rbx, slotToReg(0).?);
    try testing.expectEqual(Gpr.r9, slotToReg(7).?);
    try testing.expect(slotToReg(8) == null);
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

test "poolSlots: a register maps to its pool slot, one outside the pool to nothing" {
    try testing.expectEqualSlices(u16, &.{ 0, 2 }, comptime poolSlots(&.{ .rbx, .rax, .r13 }));
    try testing.expectEqual(@as(usize, 0), comptime poolSlots(&.{ .r10, .r11, .r15 }).len);
}

test "opScratchReservation: every fenced slot holds a register its handler writes" {
    for (op_regs, 0..) |e, i| {
        const res = opScratchReservation(@enumFromInt(i));
        for (res.scratch) |sid| try testing.expect(std.mem.findScalar(Gpr, e.scratch, allocatable_gprs[sid]) != null);
        for (res.operand) |sid| try testing.expect(std.mem.findScalar(Gpr, e.operand, allocatable_gprs[sid]) != null);
    }
}

/// The registers of `regs` that the pool also hands out.
fn inPool(comptime regs: []const Gpr) []const Gpr {
    comptime {
        var out: [regs.len]Gpr = undefined;
        var n: usize = 0;
        for (regs) |r| {
            if (std.mem.findScalar(Gpr, &allocatable_gprs, r) != null) {
                out[n] = r;
                n += 1;
            }
        }
        const final = out[0..n].*;
        return &final;
    }
}

/// Fillers v0-v3 take slots 0-3 and die at pc 7; v4-v7, defined at pc 4-7,
/// end at the op on pc 8 (`across` = false: its operands) or one pc past it
/// (`across` = true: live across it). Without a fence v4-v7 land in slots
/// 4-7, the argument registers. Returns the register each of v4-v7 got.
fn fencedRegs(op: zir.ZirOp, across: bool, fence: ?regalloc.ScratchReservationFn) ![4]?Gpr {
    var f = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer f.deinit(testing.allocator);
    for (0..10) |pc| try f.instrs.append(testing.allocator, .{ .op = if (pc == 8) op else .nop });
    var ranges: [8]zir.LiveRange = undefined;
    for (0..4) |i| ranges[i] = .{ .def_pc = @intCast(i), .last_use_pc = 7 };
    for (4..8) |i| ranges[i] = .{ .def_pc = @intCast(i), .last_use_pc = if (across) 9 else 8 };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try regalloc.computeWith(testing.allocator, &f, allocatable_gprs.len, fence, .{ .gpr = allocatable_gprs.len, .fp = allocatable_xmms.len });
    defer regalloc.deinit(testing.allocator, alloc);
    var regs: [4]?Gpr = undefined;
    for (&regs, 4..) |*r, v| r.* = switch (alloc.slot(v, .gpr)) {
        .reg => |id| slotToReg(id),
        .spill => null,
    };
    return regs;
}

/// `op`'s operands (or the vregs live across it) get none of `avoid`, and
/// would without the fence.
fn expectFenced(op: zir.ZirOp, across: bool, avoid: []const Gpr) !void {
    const hits = struct {
        fn count(regs: [4]?Gpr, set: []const Gpr) usize {
            var n: usize = 0;
            for (regs) |r| {
                if (r) |g| {
                    if (std.mem.findScalar(Gpr, set, g) != null) n += 1;
                }
            }
            return n;
        }
    };
    try testing.expect(hits.count(try fencedRegs(op, across, null), avoid) > 0);
    try testing.expectEqual(@as(usize, 0), hits.count(try fencedRegs(op, across, &opScratchReservation), avoid));
}

const arg_regs_in_pool = inPool(&current.arg_gprs);

test "fence: memory.init — nothing live across it in RDI, R8, R9" {
    try expectFenced(.@"memory.init", true, comptime inPool(&.{ .rdi, .r8, .r9 }));
}

test "fence: table.set — nothing live across it in R9" {
    try expectFenced(.@"table.set", true, comptime inPool(&.{.r9}));
}

test "fence: table.fill — operands not in R8, nothing live across it in RSI, RDI, R8, R9" {
    try expectFenced(.@"table.fill", false, comptime inPool(&.{.r8}));
    try expectFenced(.@"table.fill", true, comptime inPool(&.{ .rsi, .rdi, .r8, .r9 }));
}

test "fence: table.copy — operands not in R8, nothing live across it in RSI, RDI, R8, R9" {
    try expectFenced(.@"table.copy", false, comptime inPool(&.{.r8}));
    try expectFenced(.@"table.copy", true, comptime inPool(&.{ .rsi, .rdi, .r8, .r9 }));
}

test "fence: table.init — operands not in R8, nothing live across it in RSI, RDI, R8, R9" {
    try expectFenced(.@"table.init", false, comptime inPool(&.{.r8}));
    try expectFenced(.@"table.init", true, comptime inPool(&.{ .rsi, .rdi, .r8, .r9 }));
}

test "fence: array.copy — operands not in an argument register" {
    try expectFenced(.@"array.copy", false, arg_regs_in_pool);
}

test "fence: array.fill — operands not in an argument register" {
    try expectFenced(.@"array.fill", false, arg_regs_in_pool);
}

test "fence: array.init_data — operands not in an argument register" {
    try expectFenced(.@"array.init_data", false, arg_regs_in_pool);
}

test "fence: array.init_elem — operands not in an argument register" {
    try expectFenced(.@"array.init_elem", false, arg_regs_in_pool);
}

test "fence: array.new — operands not in an argument register" {
    try expectFenced(.@"array.new", false, arg_regs_in_pool);
}

test "fence: array.new_data — operands not in an argument register" {
    try expectFenced(.@"array.new_data", false, arg_regs_in_pool);
}

test "fence: array.new_elem — operands not in an argument register" {
    try expectFenced(.@"array.new_elem", false, arg_regs_in_pool);
}

test "fence: table.grow — operands not in an argument register" {
    try expectFenced(.@"table.grow", false, arg_regs_in_pool);
}

fn expectAtomicFamilyFenced(comptime pred: fn (zir.ZirOp) bool) !void {
    var n: usize = 0;
    for (0..zir_op_count) |i| {
        const op: zir.ZirOp = @enumFromInt(i);
        if (!pred(op)) continue;
        try expectFenced(op, false, arg_regs_in_pool);
        n += 1;
    }
    try testing.expect(n > 0);
}

test "fence: every atomic rmw — operands not in an argument register" {
    try expectAtomicFamilyFenced(jit_abi.isAtomicRmw);
}

test "fence: every atomic cmpxchg — operands not in an argument register" {
    try expectAtomicFamilyFenced(jit_abi.isAtomicCmpxchg);
}

test "fence: memory.atomic.notify — operands not in an argument register" {
    try expectAtomicFamilyFenced(jit_abi.isAtomicNotify);
}

test "fence: memory.atomic.wait32 / wait64 — operands not in an argument register" {
    try expectAtomicFamilyFenced(jit_abi.isAtomicWait);
}
