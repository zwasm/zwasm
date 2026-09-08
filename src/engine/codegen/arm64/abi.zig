//! AAPCS64 calling-convention tables.
//!
//! Declares the AArch64 register inventory the emit
//! pass consults: which X-registers carry function arguments,
//! which are caller-saved vs callee-saved, the link / frame /
//! stack pointer slots, and a `slotToReg` mapper translating a
//! regalloc slot id into a concrete `Xn`.
//!
//! Per AAPCS64 (Arm IHI 0055 — Procedure Call Standard for the
//! Arm 64-bit Architecture):
//!
//!   X0..X7      arg / return registers (also caller-saved)
//!   X8          indirect result location
//!   X9..X15     temporaries (caller-saved)
//!   X16, X17    intra-procedure-call scratch (IP0, IP1)
//!   X18         platform reg (do not use on Apple/Darwin)
//!   X19..X28    callee-saved
//!   X29 (FP)    frame pointer
//!   X30 (LR)    link register
//!   X31         SP / XZR (depends on opcode)
//!
//! Declarative tables only + the `slotToReg` mapper. Real
//! spill-slot allocation lives in the regalloc; this module
//! only translates "slot N of the GPR class" into "Xn".
//!
//! Zone 2 (`src/jit_arm64/`).

const std = @import("std");

const inst = @import("inst.zig");
const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const Xn = inst.Xn;

/// First 8 X-registers carry function arguments + return values
/// (X0 is the primary return register).
pub const arg_gprs = [_]Xn{ 0, 1, 2, 3, 4, 5, 6, 7 };

/// X8 is the indirect-result-location pointer when the callee
/// returns a struct via memory.
pub const indirect_result_gpr: Xn = 8;

/// Caller-saved (volatile) GPRs other than args. AAPCS64
/// classifies X9..X15 as caller-clobberable temporaries; the
/// emit pass uses these as scratch between calls.
/// (X0..X7 are caller-saved too but conceptually serve as args/
/// returns rather than scratch.)
pub const caller_saved_scratch_gprs = [_]Xn{ 9, 10, 11, 12, 13, 14, 15 };

/// Reserved for spill load/store staging (per ADR-0018). The
/// emit pass uses these as scratches when materialising a
/// spilled vreg's value into a register before an op, or
/// writing a result back to its spill slot. Two stage regs
/// support binary ops where both operands are spilled.
///
/// Excluded from `allocatable_gprs` by construction. X16/X17
/// (IP0/IP1) cannot serve this role because the emit pass
/// already uses them mid-op for call_indirect's idx/typeidx
/// pipeline; using them for spill staging would clobber
/// in-flight values.
pub const spill_stage_gprs = [_]Xn{ 14, 15 };

/// Caller-saved scratch minus the spill-stage carve-out. Used by
/// `allocatable_gprs` so the regalloc never lands a vreg on a
/// stage reg.
pub const allocatable_caller_saved_scratch_gprs = [_]Xn{ 9, 10, 11, 12, 13 };

/// Named scratch pool for table.* / memory.* emit handlers
/// (D-132 / D-133 sweep per ADR-0072).
/// These registers MUST be disjoint from `allocatable_*_gprs`
/// because table/memory emit runs inline within an op handler
/// (no separate save/restore boundary) and the regalloc must
/// not have placed a live vreg on them. The disjointness
/// check below (comptime block) enforces this; if a future
/// edit attempts to add these to allocatable, the build fails.
///
/// **Intentional overlap with `spill_stage_gprs`**: these pools
/// share X14/X15 because (a) table/memory emit handlers do not
/// themselves spill mid-op (vregs are live-locked across the
/// op's emit boundary), so X14/X15 are guaranteed free at
/// op entry; (b) carving out a third disjoint pool would consume
/// allocatable_callee_saved_gprs slots that the regalloc relies
/// on. The d-64 refactor pattern (load-then-overwrite a single
/// scratch reg) keeps simultaneous use ≤ 2 registers per op.
/// When D-133 sweep lands, this assumption is what makes the
/// substitution safe; if a future op needs ≥ 3 simultaneous
/// scratch slots, file an ADR before extending the pool size.
///
/// Pairs with `.claude/rules/comment_as_invariant.md` —
/// invariant in code, not prose.
pub const table_emit_scratch_gprs = [_]Xn{ 14, 15 };
pub const memory_emit_scratch_gprs = [_]Xn{ 14, 15 };

/// Intra-procedure-call scratch (linker-clobbered). Reserved
/// for the platform's PLT veneer; emit may use these only
/// short-lived.
pub const ip_gprs = [_]Xn{ 16, 17 };

/// Platform-reserved register — Apple/Darwin AAPCS reserves X18
/// for the OS, so we treat it as never-allocatable.
pub const platform_gpr: Xn = 18;

/// Callee-saved (non-volatile) GPRs per AAPCS64 §6.4.1.
/// Callee must preserve these across calls; saved in prologue,
/// restored in epilogue. The full callee-saved range is
/// X19..X28; `reserved_invariant_gprs` carves out X19 + X23..X28 for
/// JitRuntime-derived invariants (per ADR-0017 / 0018 / 0027), leaving
/// `allocatable_callee_saved_gprs` (X20..X22) available to the
/// regalloc.
pub const callee_saved_gprs = [_]Xn{ 19, 20, 21, 22, 23, 24, 25, 26, 27, 28 };

/// Registers reserved for runtime invariants (per ADR-0017 +
/// ADR-0018):
///   X28 — vm_base       (linear-memory base pointer)
///   X27 — mem_limit     (linear-memory size in bytes)
///   X26 — funcptr_base  (table 0 — array of u64 funcptrs)
///   X25 — table_size    (W25 = u32 count of entries)
///   X24 — typeidx_base  (parallel array of u32 typeidx values)
///   X19 — runtime_ptr   (saved copy of *const JitRuntime; the
///                        ADR-0017 sub-2d-ii amendment — used to
///                        restore X0 before each BL/BLR since
///                        AAPCS64 caller-saves X0)
///
/// The function prologue MOVs X0 → X19 to preserve the runtime ptr
/// across calls and LDRs X24..X28 from `*X0`; X23 is loaded only by
/// functions that touch globals (prescan-driven, ADR-0027).
///
/// Adding or removing a reserved reg propagates to everything that
/// DERIVES from this array — `allocatable_gprs` is its complement, and
/// the arm64 bridge thunk's save block iterates it (ADR-0228 D4). It
/// does NOT reach a consumer that writes the members out again: #413
/// was the thunk holding six of these for the 3.5 months after X23
/// joined. Read the array.
pub const reserved_invariant_gprs = [_]Xn{ 19, 23, 24, 25, 26, 27, 28 };

/// Mnemonic alias for the X19 = runtime_ptr_save reservation
/// (per ADR-0017 sub-2d-ii). The prologue's `MOV X19, X0`
/// stages the runtime ptr here; each call site emits `MOV X0,
/// X19` before BL/BLR.
pub const runtime_ptr_save_gpr: Xn = 19;

/// Mnemonic alias for the X23 = globals_base_save reservation
/// (per ADR-0027). Functions touching `global.get` / `global.set`
/// pre-load `[X19 + globals_base_off]` into X23 at function
/// prologue (after the existing 5-invariant load), then the
/// global op handlers emit `LDR Rd, [X23, Ridx, LSL #3]` etc.
/// Functions without globals skip the X23 prologue load
/// (prescan-driven) so existing zero-globals tests stay
/// unchanged.
pub const globals_base_save_gpr: Xn = 23;

/// Allocatable callee-saved GPRs = callee_saved_gprs minus the
/// reserved subset. Three regs (X20..X22) post-ADR-0027 (was
/// X20..X23). Kept as its own constant so `allocatable_gprs`
/// reads cleanly and `audit_scaffolding` can spot-check the
/// reservation invariant (ADR-0018 §I + ADR-0027).
pub const allocatable_callee_saved_gprs = [_]Xn{ 20, 21, 22 };

pub const frame_pointer: Xn = 29;
pub const link_register: Xn = 30;

/// Pool of GPRs the regalloc may freely use, in priority order:
/// caller-saved scratch first (cheapest, no prologue cost), then
/// allocatable callee-saved (forces save/restore but invariant-safe).
///
/// **Excluded from the pool by construction**:
///   - X0..X7 (arg / return marshalling)
///   - X8 (indirect-result-location ptr)
///   - X16/X17 (IP0/IP1, used as op-handler scratches per
///     `single_slot_dual_meaning.md`)
///   - X18 (Apple/Darwin platform-reserved)
///   - `reserved_invariant_gprs` (X19 + X23..X28, ADR-0017/0018/0027)
///   - X29 (FP), X30 (LR), X31 (SP/XZR)
///
/// A function with more concurrently-live vregs than the pool holds
/// spills to the function's spill frame per ADR-0018: slot ids below
/// `allocatable_gprs.len` resolve via this table, the rest resolve to
/// `Slot.spill` byte offsets (consumed by the emit pass via
/// `regalloc.Allocation.slot()`). The length is pinned by a test below —
/// 17 pre-ADR-0018, 10 pre-ADR-0027.
pub const allocatable_gprs = allocatable_caller_saved_scratch_gprs ++ allocatable_callee_saved_gprs;

// Compile-time invariant: allocatable / reserved / spill_stage
// sets are pairwise disjoint. Catching overlap at comptime is
// the structural fix for the W54-class regression that motivated
// ADR-0018.
comptime {
    for (allocatable_gprs) |a| {
        for (reserved_invariant_gprs) |r| {
            if (a == r) @compileError("regalloc pool overlaps reserved_invariant_gprs — ADR-0018 invariant violated");
        }
        for (spill_stage_gprs) |s| {
            if (a == s) @compileError("regalloc pool overlaps spill_stage_gprs — ADR-0018 invariant violated");
        }
        for (table_emit_scratch_gprs) |s| {
            if (a == s) @compileError("regalloc pool overlaps table_emit_scratch_gprs — D-133 invariant violated (master plan §9.12-C)");
        }
        for (memory_emit_scratch_gprs) |s| {
            if (a == s) @compileError("regalloc pool overlaps memory_emit_scratch_gprs — D-133 invariant violated (master plan §9.12-C)");
        }
    }
}

/// Translate a regalloc slot id (from `jit/regalloc.compute`)
/// into a concrete X-register via the allocatable pool.
/// Returns null when the slot id exceeds the pool size — the
/// emit pass treats that as a cue to spill (today we error
/// rather than silently drop).
pub fn slotToReg(slot_id: u16) ?Xn {
    if (slot_id >= allocatable_gprs.len) return null;
    return allocatable_gprs[slot_id];
}

/// Float / SIMD V-register pool (caller-saved scratch range,
/// V16..V28 → 13 slots after D-037's V29/V30 carve-out for FP
/// spill staging). V31 is reserved for popcnt's V-register
/// pipeline. V0..V7 are arg/return; V8..V15 callee-saved (skipped
/// to avoid prologue cost). `fpSlotToReg` is the float-class
/// counterpart of `slotToReg` — the f32/f64
/// handlers use it.
///
/// **Mixing caveat**: a vreg's slot id is per-class via
/// `Allocation.slot(vreg, class)` (per D-036 class-aware split).
/// Within a single function's live ranges, a slot id used by a
/// GPR vreg and a slot id used by a V-vreg map to *different*
/// physical registers (X9 vs V16 for slot 0). The regalloc itself
/// stays class-blind; class-aware allocation is a follow-up
/// (D-036 §"option (b)").
pub const allocatable_v_regs = [_]Xn{
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
};

/// Reserved for FP-class spill load/store staging (per D-037 — the
/// FP-class mirror of `spill_stage_gprs`). The emit pass uses
/// these as scratches when materialising a spilled V-vreg's value
/// before an op, or writing a result back to its spill slot. Two
/// stage regs support binary FP ops where both operands are
/// spilled. V31 stays reserved for popcnt's V-register pipeline
/// (per arm64/op_bitcount.zig).
///
/// Excluded from `allocatable_v_regs` by construction.
pub const fp_spill_stage_vregs = [_]Xn{ 29, 30 };

pub fn fpSlotToReg(slot_id: u16) ?Xn {
    if (slot_id >= allocatable_v_regs.len) return null;
    return allocatable_v_regs[slot_id];
}

// ============================================================
// ADR-0077 — per-op scratch reservation table (arm64).
// ============================================================

/// Slot ids that the 5 D-133 bulk handlers clobber as op-internal
/// scratch. The live-scratch census
/// (.dev/lessons/2026-05-20-d133-sweep-pool-size-insufficient.md)
/// shows table.fill / table.copy / table.init / memory.init hold
/// ≥ 4 simultaneously-live scratches across X9..X13 in their loop
/// bodies. Reserving the full {0..4} set is the conservative
/// formulation validated by the spike — per-handler tightening
/// is a future optimisation if profile shows spill pressure
/// regression. memory.copy / memory.fill are not in the bulk
/// cohort (they touch only X11/X12 transiently and the d-64
/// load-then-overwrite pattern already covers them).
const bulk_handler_reservation = [_]u16{ 0, 1, 2, 3, 4 };

const zir_op_count = @typeInfo(zir.ZirOp).@"enum".fields.len;

/// Per-op scratch reservation lookup table (ADR-0077).
///
/// Indexed by `@intFromEnum(ZirOp)`. Each entry is the slice of
/// regalloc slot ids that the op's emit handler will clobber
/// internally during code generation. Empty slice = no
/// reservation (default for every op). When the regalloc walker
/// is wired, it queries this table via
/// `opScratchReservation` and forbids live-vreg overlap on the
/// listed slot ids across the op's PC range.
///
/// Comptime block below asserts every reservation references
/// only allocatable slot ids (else the reservation is a no-op
/// declaration; enforced by the canonical
/// `validateRegallocOpScratchReservation` check).
pub const op_scratch_reservation_table: [zir_op_count][]const u16 = blk: {
    var t: [zir_op_count][]const u16 = .{&.{}} ** zir_op_count;
    t[@intFromEnum(zir.ZirOp.@"table.fill")] = &bulk_handler_reservation;
    t[@intFromEnum(zir.ZirOp.@"table.copy")] = &bulk_handler_reservation;
    t[@intFromEnum(zir.ZirOp.@"table.init")] = &bulk_handler_reservation;
    t[@intFromEnum(zir.ZirOp.@"memory.init")] = &bulk_handler_reservation;
    break :blk t;
};

// Comptime validation (ADR-0077). Delegates to the shared
// regalloc validator so the arm64 + future x86_64 tables stay in
// lockstep on what counts as a well-formed reservation.
comptime {
    regalloc.validateRegallocOpScratchReservation(
        op_scratch_reservation_table,
        allocatable_gprs.len,
    );
}

/// `shared/regalloc.zig::ScratchReservationFn` compatible accessor.
/// Pass `&opScratchReservation` as the 4th argument of
/// `computeWith` to enable the arm64 fence.
pub fn opScratchReservation(op: zir.ZirOp) []const u16 {
    const idx = @intFromEnum(op);
    if (idx >= zir_op_count) return &.{};
    return op_scratch_reservation_table[idx];
}

/// Is `xn` caller-saved per AAPCS64? Used by emit to decide
/// whether a vreg held in `xn` needs a save before a call.
pub fn isCallerSaved(xn: Xn) bool {
    if (xn <= 7) return true; // args/returns
    if (xn >= 9 and xn <= 17) return true; // scratch + IP0/1
    return false;
}

/// Is `xn` callee-saved per AAPCS64? Inverse of caller-saved
/// for the allocatable range; FP/LR/SP/PR return false.
pub fn isCalleeSaved(xn: Xn) bool {
    return xn >= 19 and xn <= 28;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "arg_gprs covers x0..x7" {
    try testing.expectEqual(@as(usize, 8), arg_gprs.len);
    for (arg_gprs, 0..) |x, i| {
        try testing.expectEqual(@as(Xn, @intCast(i)), x);
    }
}

test "callee_saved_gprs covers x19..x28" {
    try testing.expectEqual(@as(usize, 10), callee_saved_gprs.len);
    try testing.expectEqual(@as(Xn, 19), callee_saved_gprs[0]);
    try testing.expectEqual(@as(Xn, 28), callee_saved_gprs[9]);
}

test "allocatable_gprs covers allocatable-caller-scratch + allocatable-callee-saved (8 regs post-ADR-0027)" {
    try testing.expectEqual(@as(usize, 8), allocatable_gprs.len);
}

test "reserved_invariant_gprs is exactly X19, X23..X28 (7 regs after ADR-0027)" {
    try testing.expectEqual(@as(usize, 7), reserved_invariant_gprs.len);
    const expected = [_]Xn{ 19, 23, 24, 25, 26, 27, 28 };
    for (reserved_invariant_gprs, expected) |a, e| try testing.expectEqual(e, a);
}

test "globals_base_save_gpr alias resolves to X23" {
    try testing.expectEqual(@as(Xn, 23), globals_base_save_gpr);
}

test "runtime_ptr_save_gpr alias resolves to X19" {
    try testing.expectEqual(@as(Xn, 19), runtime_ptr_save_gpr);
}

test "spill_stage_gprs is exactly X14, X15 (2 regs for binary-op spill staging)" {
    try testing.expectEqual(@as(usize, 2), spill_stage_gprs.len);
    try testing.expectEqual(@as(Xn, 14), spill_stage_gprs[0]);
    try testing.expectEqual(@as(Xn, 15), spill_stage_gprs[1]);
}

test "allocatable_gprs is pairwise disjoint with reserved + spill_stage (runtime check; comptime guard above)" {
    for (allocatable_gprs) |a| {
        for (reserved_invariant_gprs) |r| try testing.expect(a != r);
        for (spill_stage_gprs) |s| try testing.expect(a != s);
    }
}

test "slotToReg: slot 0 maps to x9 (first allocatable caller-scratch)" {
    try testing.expectEqual(@as(Xn, 9), slotToReg(0).?);
}

test "slotToReg: slot 4 maps to x13 (last allocatable caller-scratch; X14/X15 reserved for spill staging)" {
    try testing.expectEqual(@as(Xn, 13), slotToReg(4).?);
}

test "slotToReg: slot 5 maps to x20 (first allocatable callee-saved; X19 now reserved as runtime_ptr_save)" {
    try testing.expectEqual(@as(Xn, 20), slotToReg(5).?);
}

test "slotToReg: slot 7 maps to x22 (last allocatable callee-saved post-ADR-0027; X23 reserved for globals_base_save)" {
    try testing.expectEqual(@as(Xn, 22), slotToReg(7).?);
}

test "slotToReg: slot 8 returns null (pool exhausted post-ADR-0027; spill territory)" {
    try testing.expect(slotToReg(8) == null);
}

test "slotToReg: out-of-pool slot returns null (cue to spill)" {
    try testing.expect(slotToReg(99) == null);
}

test "isCallerSaved: x0..x7, x9..x17" {
    try testing.expect(isCallerSaved(0));
    try testing.expect(isCallerSaved(7));
    try testing.expect(isCallerSaved(9));
    try testing.expect(isCallerSaved(17));
    try testing.expect(!isCallerSaved(19));
    try testing.expect(!isCallerSaved(28));
    try testing.expect(!isCallerSaved(30)); // LR
}

test "isCalleeSaved: x19..x28" {
    try testing.expect(isCalleeSaved(19));
    try testing.expect(isCalleeSaved(28));
    try testing.expect(!isCalleeSaved(0));
    try testing.expect(!isCalleeSaved(18)); // platform reg
    try testing.expect(!isCalleeSaved(29)); // FP
}

test "frame_pointer + link_register tracked" {
    try testing.expectEqual(@as(Xn, 29), frame_pointer);
    try testing.expectEqual(@as(Xn, 30), link_register);
}

test "fpSlotToReg: slot 0 → V16 (first caller-saved scratch V)" {
    try testing.expectEqual(@as(Xn, 16), fpSlotToReg(0).?);
}

test "fpSlotToReg: slot 12 → V28 (last in the 13-slot pool post-D-037; V29/V30 reserved as FP spill stages)" {
    try testing.expectEqual(@as(Xn, 28), fpSlotToReg(12).?);
}

test "fpSlotToReg: slot 13 returns null (V29 reserved as FP spill stage)" {
    try testing.expect(fpSlotToReg(13) == null);
}

test "allocatable_v_regs is pairwise disjoint with fp_spill_stage_vregs" {
    for (allocatable_v_regs) |a| {
        for (fp_spill_stage_vregs) |s| try testing.expect(a != s);
    }
}

test "fp_spill_stage_vregs is exactly V29, V30 (2 regs for binary FP-op spill staging, mirroring spill_stage_gprs)" {
    try testing.expectEqual(@as(usize, 2), fp_spill_stage_vregs.len);
    try testing.expectEqual(@as(Xn, 29), fp_spill_stage_vregs[0]);
    try testing.expectEqual(@as(Xn, 30), fp_spill_stage_vregs[1]);
}

// ============================================================
// ADR-0077 — op_scratch_reservation_table tests.
// ============================================================

test "opScratchReservation: table.fill reserves slots {0..4} (= X9..X13)" {
    const r = opScratchReservation(.@"table.fill");
    try testing.expectEqualSlices(u16, &[_]u16{ 0, 1, 2, 3, 4 }, r);
}

test "opScratchReservation: 4 bulk handlers all reserve the same set" {
    const expected = [_]u16{ 0, 1, 2, 3, 4 };
    try testing.expectEqualSlices(u16, &expected, opScratchReservation(.@"table.fill"));
    try testing.expectEqualSlices(u16, &expected, opScratchReservation(.@"table.copy"));
    try testing.expectEqualSlices(u16, &expected, opScratchReservation(.@"table.init"));
    try testing.expectEqualSlices(u16, &expected, opScratchReservation(.@"memory.init"));
}

test "opScratchReservation: non-bulk ops have empty reservation" {
    try testing.expectEqual(@as(usize, 0), opScratchReservation(.nop).len);
    try testing.expectEqual(@as(usize, 0), opScratchReservation(.@"i32.add").len);
    try testing.expectEqual(@as(usize, 0), opScratchReservation(.@"i32.const").len);
    // table.set / table.get / table.size / table.grow are NOT in
    // the bulk cohort — d-64 / d-66 already discharged them via
    // load-then-overwrite. Empty reservation here is intentional.
    try testing.expectEqual(@as(usize, 0), opScratchReservation(.@"table.set").len);
    try testing.expectEqual(@as(usize, 0), opScratchReservation(.@"table.get").len);
}

test "opScratchReservation: all reserved slot ids are in allocatable range" {
    // Runtime mirror of the comptime check; defensive guard so a
    // future edit that bypasses comptime (e.g. extracting the
    // table to a separate module) surfaces immediately.
    for (op_scratch_reservation_table) |reservation| {
        for (reservation) |sid| {
            try testing.expect(sid < allocatable_gprs.len);
        }
    }
}

test "opScratchReservation: shape matches shared.ScratchReservationFn" {
    // Compile-time confirmation that the accessor's signature is
    // assignable to the shared regalloc's ScratchReservationFn.
    // If the shared type drifts (renames its arg or return), this
    // line fails to compile.
    const fp: regalloc.ScratchReservationFn = &opScratchReservation;
    _ = fp;
}
