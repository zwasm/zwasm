// FILE-SIZE-EXEMPT: per-op handler catalog (Wasm SIMD int arith sub-language); P1 spec-defined (per ADR-0099)
//! x86_64 emit pass - SIMD-128 integer arithmetic op handlers
//! (split from `op_simd.zig` per ADR-0054).
//!
//! Houses int ALU (add/sub/mul/neg/abs), saturating arith
//! (add_sat / sub_sat), shift (shl / shr_s / shr_u), min/max
//! (signed + unsigned), avgr_u, popcnt, q15mulr_sat_s, and
//! dot product. Uses `op_simd.emitV128IntBinop` for the 2-op
//! MOVAPS-preamble + encoder dispatch shape; FP-class single-
//! instr unaries (e.g. PABSB/W/D via `op_simd_float.emitV128FpUnop`)
//! are reached cross-module.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) - must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP Sec A3.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const gpr = @import("gpr.zig");
const types = @import("types.zig");
const ctx_mod = @import("ctx.zig");
const op_simd = @import("op_simd.zig");
const op_simd_float = @import("op_simd_float.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;

// D-034 (g) file-local v128 spill helpers for the both-stages-internal ops
// (i8x16/i64x2 shifts, popcnt, i64x2 mul) where the two FP stage regs are the
// op's own scratch, so dst → home or XMM7 and a spilled operand is reloaded
// just-in-time from its RBP-disp slot rather than parked in a persistent reg.

/// dst register: its home XMM when not spilled, else XMM7 (flushed at the end).
fn dstHomeOrXmm7(alloc: regalloc.Allocation, result_v: usize) Error!inst.Xmm {
    return switch (alloc.slot(result_v, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse Error.SlotOverflow,
        .spill => .xmm7,
    };
}

/// Put operand `v`'s value into `reg`: MOVAPS from its home XMM (skipped when
/// `reg` already IS the home), or an RBP-disp v128 load when spilled.
fn loadV128IntoLocal(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, spill_base_off: u32, reg: inst.Xmm, v: usize) Error!void {
    switch (alloc.slot(v, .fpr)) {
        .reg => |id| {
            const home = abi.fpSlotToReg(id) orelse return Error.SlotOverflow;
            if (reg != home) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(reg, home).slice());
        },
        .spill => |off| {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(reg, disp).slice());
        },
    }
}

/// Flush XMM7 → the result's spill slot when result spilled (no-op for home regs).
fn storeXmm7IfSpilledLocal(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, spill_base_off: u32, result_v: usize) Error!void {
    switch (alloc.slot(result_v, .fpr)) {
        .reg => {},
        .spill => |off| {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
        },
    }
}

// `(ctx, ins)` adapters for the SIMD
// int binary arith cohort (8 add/sub + 2 native mul + 1 synthesised
// i64x2.mul = 11 ops). Each wraps its existing helper. ins is
// always ignored (one helper per op).

pub fn emitI8x16AddCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16Add(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16SubCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16Sub(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8AddCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8Add(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8SubCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8Sub(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4AddCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4Add(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4SubCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4Sub(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2AddCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2Add(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2SubCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2Sub(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8MulCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8Mul(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4MulCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4Mul(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2MulCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2Mul(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapters for the SIMD
// int neg/abs cohort (8 ops). All helpers are 5-arg (no
// spill_base_off).

pub fn emitI8x16NegCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16Neg(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8NegCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8Neg(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4NegCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4Neg(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2NegCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2Neg(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16AbsCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16Abs(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8AbsCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8Abs(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4AbsCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4Abs(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2AbsCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2Abs(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapters for the
// SIMD int shifts cohort (12 ops: i{8x16,16x8,32x4,64x2}.shl/
// shr_s/shr_u). All 6-arg helpers.

pub fn emitI8x16ShlCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16Shl(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16ShrSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16ShrS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16ShrUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16ShrU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8ShlCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8Shl(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8ShrSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8ShrS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8ShrUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8ShrU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ShlCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4Shl(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ShrSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4ShrS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ShrUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4ShrU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2ShlCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2Shl(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2ShrSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2ShrS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2ShrUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2ShrU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapters for the
// SIMD int min/max cohort (12 ops: i{8x16,16x8,32x4}.min_s/min_u/
// max_s/max_u). All 6-arg helpers.

pub fn emitI8x16MinSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16MinS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16MinUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16MinU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16MaxSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16MaxS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16MaxUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16MaxU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8MinSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8MinS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8MinUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8MinU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8MaxSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8MaxS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8MaxUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8MaxU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4MinSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4MinS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4MinUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4MinU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4MaxSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4MaxS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4MaxUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4MaxU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapters for the
// SIMD int sat arith cohort (10 ops: i8x16/i16x8.add_sat_s/
// add_sat_u/sub_sat_s/sub_sat_u + i8x16/i16x8.avgr_u). All 6-arg.

pub fn emitI8x16AddSatSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16AddSatS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16AddSatUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16AddSatU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16SubSatSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16SubSatS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16SubSatUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16SubSatU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8AddSatSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8AddSatS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8AddSatUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8AddSatU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8SubSatSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8SubSatS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8SubSatUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8SubSatU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16AvgrUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16AvgrU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8AvgrUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8AvgrU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16Add(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPaddB);
}

pub fn emitI8x16Sub(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsubB);
}

pub fn emitI16x8Add(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPaddW);
}

pub fn emitI16x8Sub(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsubW);
}

pub fn emitI32x4Add(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPaddD);
}

pub fn emitI32x4Sub(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsubD);
}

pub fn emitI64x2Add(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPaddQ);
}

pub fn emitI64x2Sub(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsubQ);
}

// Native multiply ops. i16x8.mul reaches PMULLW (SSE2);
// i32x4.mul reaches PMULLD (SSE4.1). i64x2.mul has no native
// SSE4.1 instruction and synthesises via PMULUDQ + shifts/adds.
// The Wasm spec's modular-wraparound semantics
// match the CPU's truncating low-half multiply for both ops.

pub fn emitI16x8Mul(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmullW);
}

pub fn emitI32x4Mul(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmullD);
}

/// Wasm spec §4.4.4 (i*x*.{shl, shr_s, shr_u}) for shapes that
/// have direct SSE2 packed-shift instructions — i16x8 / i32x4 /
/// i64x2 (with PSRAQ / i8x16 deferred for synthesis).
/// Stack: pop count (i32), pop vec (v128), push v128.
///
/// SSE shift count semantics differ from Wasm: Intel SDM "If the
/// count value is greater than the operand size, destination is
/// set to all-zeros (PSLL/PSRL) or sign-extended (PSRA)". Wasm
/// requires `c mod lane_width` semantics. The explicit
/// `AND count_r, lane_width-1` aligns the two — when c <
/// lane_width, both behave identically.
///
/// 5-instruction emit:
///   AND count_r, mask_imm           ; mask to lane bits
///   MOVD scratch_xmm, count_r       ; count → low 32 of scratch
///   MOVAPS dst, vec                 ; (skip if dst==vec)
///   <shift> dst, scratch_xmm        ; shift dst in-place
fn emitV128IntShift(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder_shift: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    mask_imm: i8,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const count_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const count_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, count_v, 0);
    // D-034 (g/f): spill-aware v128 vec+dst. vec/dst share spill stage0 (XMM14) —
    // dst is in-place after MOVAPS (vec dies into dst), so one stage suffices; the
    // count broadcast moves to stage1 (XMM15) to free stage0 for the spilled vec.
    const vec_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, vec_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);
    const scratch_x = abi.fp_spill_stage_xmms[1]; // XMM15

    try buf.appendSlice(allocator, inst.encAndRImm8(.d, count_r, mask_imm).slice());
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(scratch_x, count_r).slice());
    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    try buf.appendSlice(allocator, encoder_shift(dst_x, scratch_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI16x8Shl(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsllwReg, 15);
}

pub fn emitI16x8ShrS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsrawReg, 15);
}

pub fn emitI16x8ShrU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsrlwReg, 15);
}

pub fn emitI32x4Shl(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPslldReg, 31);
}

pub fn emitI32x4ShrS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsradReg, 31);
}

pub fn emitI32x4ShrU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsrldReg, 31);
}

pub fn emitI64x2Shl(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsllqReg, 63);
}

pub fn emitI64x2ShrU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsrlqReg, 63);
}

/// Wasm spec §4.4.4 (i64x2.shr_s) — pop count (i32), pop vec
/// (v128), push v128 with arithmetic (signed) shift-right per
/// 64-bit lane. SSE2 lacks PSRAQ (added in AVX-512); synthesise
/// per cranelift `lower.isle:943-951` with runtime sign-bit-mask
/// generation (avoids the const-pool plumbing the cranelift code
/// uses via `flip_high_bit_mask`):
///
///   AND count_r, 63                ; mask count
///   PCMPEQB scratch_mask, scratch_mask ; XMM14 = all-ones
///   PSLLQ-imm scratch_mask, 63     ; XMM14 = 0x80...0 per qword (sign bits)
///   MOVD scratch_count, count_r    ; XMM15 = count
///   PSRLQ-reg scratch_mask, scratch_count ; XMM14 = sign_bit_loc =
///                                  ;   0x80...0 >> c per qword
///   MOVAPS dst, vec                ; (skip if dst==vec)
///   PSRLQ-reg dst, scratch_count   ; ushr lanes
///   PXOR dst, scratch_mask         ; flip sign-bit-loc bits
///   PSUBQ dst, scratch_mask        ; subtract sign_bit_loc → arithmetic shr
///
/// 9-instruction emit; XMM14 holds sign_bit_loc (= mask shifted),
/// XMM15 holds count. dst gets the canonical signed-shifted result.
/// Wasm spec §4.4.4 (i8x16.shl) — pop count (i32), pop vec
/// (v128), push v128 with each byte shifted left by `c & 7`.
/// SSE has no native byte shift; synthesise via 16-bit-lane
/// shift + AND-mask broadcast (cranelift's approach uses a
/// const-pool table; we synthesise the mask inline to avoid
/// the still-pending ADR-0042 const-pool dependency).
///
/// 9-instruction emit:
///   AND count_r, 7                    ; mask count
///   PCMPEQB XMM14, XMM14              ; XMM14 = all-0xFF
///   MOVD XMM15, count_r                ; XMM15 = count
///   PSLLW XMM14, XMM15                  ; XMM14 = 0xFFFF<<c per word;
///                                      ;   low byte of each word = 0xFF<<c (= mask byte)
///   MOVAPS dst, vec                    ; (skip-elide if dst==vec)
///   PSLLW dst, XMM15                    ; shift vec lanes (16-bit shift; carry pollutes high bytes)
///   PXOR XMM15, XMM15                   ; reuse XMM15 as zero-control for PSHUFB
///   PSHUFB XMM14, XMM15                 ; broadcast byte 0 of XMM14 to all 16 bytes (uniform mask)
///   PAND dst, XMM14                     ; clear cross-byte carry bits
pub fn emitI8x16Shl(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const count_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware. mask=XMM14, count=XMM15 are internal scratch, so
    // dst → home/XMM7 and vec is loaded just-in-time into dst (its only use).
    const dst_x = try dstHomeOrXmm7(alloc, result_v);
    const count_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, count_v, 0);
    const mask_x = abi.fp_spill_stage_xmms[0]; // XMM14
    const count_x = abi.fp_spill_stage_xmms[1]; // XMM15

    try buf.appendSlice(allocator, inst.encAndRImm8(.d, count_r, 7).slice());
    try buf.appendSlice(allocator, inst.encPcmpeqB(mask_x, mask_x).slice());
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(count_x, count_r).slice());
    try buf.appendSlice(allocator, inst.encPsllwReg(mask_x, count_x).slice());
    try loadV128IntoLocal(allocator, buf, alloc, spill_base_off, dst_x, vec_v);
    try buf.appendSlice(allocator, inst.encPsllwReg(dst_x, count_x).slice());
    try buf.appendSlice(allocator, inst.encPxor(count_x, count_x).slice()); // reuse as zero ctrl
    try buf.appendSlice(allocator, inst.encPshufb(mask_x, count_x).slice()); // broadcast byte 0
    try buf.appendSlice(allocator, inst.encPand(dst_x, mask_x).slice());
    try storeXmm7IfSpilledLocal(allocator, buf, alloc, spill_base_off, result_v);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i8x16.shr_u) — pop count (i32), pop vec,
/// push v128 with each byte logically shifted right by `c & 7`.
/// 10-instruction synthesis: PSRLW(0xFFFF, 8) → 0x00FF per word,
/// PSRLW that by c → 0x00FF >> c whose low byte = 0xFF >> c =
/// per-byte mask. PSHUFB-broadcast then PAND.
pub fn emitI8x16ShrU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const count_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware (mask=XMM14, count=XMM15 internal; dst→home/XMM7,
    // vec loaded just-in-time into dst).
    const dst_x = try dstHomeOrXmm7(alloc, result_v);
    const count_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, count_v, 0);
    const mask_x = abi.fp_spill_stage_xmms[0]; // XMM14
    const count_x = abi.fp_spill_stage_xmms[1]; // XMM15

    try buf.appendSlice(allocator, inst.encAndRImm8(.d, count_r, 7).slice());
    try buf.appendSlice(allocator, inst.encPcmpeqB(mask_x, mask_x).slice());
    try buf.appendSlice(allocator, inst.encPsrlwImm(mask_x, 8).slice()); // → 0x00FF per word
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(count_x, count_r).slice());
    try buf.appendSlice(allocator, inst.encPsrlwReg(mask_x, count_x).slice()); // → 0x00FF >> c per word
    try loadV128IntoLocal(allocator, buf, alloc, spill_base_off, dst_x, vec_v);
    try buf.appendSlice(allocator, inst.encPsrlwReg(dst_x, count_x).slice());
    try buf.appendSlice(allocator, inst.encPxor(count_x, count_x).slice()); // zero ctrl
    try buf.appendSlice(allocator, inst.encPshufb(mask_x, count_x).slice()); // broadcast byte 0
    try buf.appendSlice(allocator, inst.encPand(dst_x, mask_x).slice());
    try storeXmm7IfSpilledLocal(allocator, buf, alloc, spill_base_off, result_v);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i*x*.neg) — pop one v128, push v128 with
/// per-lane signed negation. Computed as `0 - src` via PSUB:
///
///   PXOR XMM14, XMM14            ; XMM14 = zero
///   PSUB_<shape> XMM14, src      ; XMM14 = 0 - src = -src
///   MOVAPS dst, XMM14            ; dst = -src
///
/// 3-instruction emit; aliasing-safe (dst is written only at
/// the end, after src has been fully consumed). PSUB doesn't
/// saturate at INT_MIN so the negation wraps modulo lane width
/// (matches Wasm spec).
fn emitV128IntNeg(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder_psub: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware v128 src+dst. The PXOR/PSUB scratch moves to XMM7
    // (mirror of the done FP abs/neg), freeing both stages for src(0) + dst(1).
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const scratch_x: inst.Xmm = .xmm7;

    try buf.appendSlice(allocator, inst.encPxor(scratch_x, scratch_x).slice());
    try buf.appendSlice(allocator, encoder_psub(scratch_x, src_x).slice());
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, scratch_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16Neg(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntNeg(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsubB);
}

pub fn emitI16x8Neg(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntNeg(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsubW);
}

pub fn emitI32x4Neg(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntNeg(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsubD);
}

pub fn emitI64x2Neg(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntNeg(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsubq);
}

/// Wasm spec §4.4.4 (i*x*.abs) — pop one v128, push v128 with
/// per-lane signed absolute value. SSSE3 PABSB/W/D directly
/// handle 8/16/32-bit lanes. i64x2.abs has no native SSE
/// instruction (PABSQ is AVX-512); synthesise per cranelift
/// `lower.isle:vec_int_abs` via sign-mask + PXOR/PSUBQ:
///
///   sign_mask = (src < 0) ? 0xFF...F : 0     (per qword)
///   result = (src ^ sign_mask) - sign_mask
///
/// For src >= 0: sign_mask = 0; result = src.
/// For src < 0:  sign_mask = -1; result = ~src - (-1) = -src.
pub fn emitI8x16Abs(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd_float.emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPabsb);
}

pub fn emitI16x8Abs(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd_float.emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPabsw);
}

pub fn emitI32x4Abs(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd_float.emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPabsd);
}

/// i64x2.abs synthesis (no PABSQ in SSE; SSE4.2 PCMPGTQ
/// available per ADR-0041 baseline). 5-instr recipe:
///   PXOR XMM14, XMM14                ; XMM14 = zero
///   PCMPGTQ XMM14, src                ; XMM14 = sign-mask of src
///                                     ;   (0xFF...F where src < 0, else 0)
///   MOVAPS dst, src                   ; (skip-elide if alias)
///   PXOR dst, XMM14                   ; flip bits where negative
///   PSUBQ dst, XMM14                  ; subtract sign-mask → abs
pub fn emitI64x2Abs(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware. The PCMPGTQ sign-mask scratch moves to XMM7 (mirror
    // of i*x*.neg), freeing both stages for src(0) + dst(1).
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const mask_x: inst.Xmm = .xmm7;

    try buf.appendSlice(allocator, inst.encPxor(mask_x, mask_x).slice());
    try buf.appendSlice(allocator, inst.encPcmpgtQ(mask_x, src_x).slice());
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPxor(dst_x, mask_x).slice());
    try buf.appendSlice(allocator, inst.encPsubq(dst_x, mask_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16ShrS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const count_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware. sign_x=XMM14, high_x=XMM15 internal; dst→home/XMM7.
    // vec is read 3× — materialise it into high_x first, take the PCMPGTB sign-mask
    // from high_x (= vec), then reload vec into dst just-in-time.
    const dst_x = try dstHomeOrXmm7(alloc, result_v);
    const count_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, count_v, 0);
    const sign_x = abi.fp_spill_stage_xmms[0]; // XMM14: sign-mask, then count
    const high_x = abi.fp_spill_stage_xmms[1]; // XMM15: src copy, then high-half sign-extended

    try buf.appendSlice(allocator, inst.encAndRImm8(.d, count_r, 7).slice());
    try loadV128IntoLocal(allocator, buf, alloc, spill_base_off, high_x, vec_v); // high_x = vec
    try buf.appendSlice(allocator, inst.encPxor(sign_x, sign_x).slice());
    try buf.appendSlice(allocator, inst.encPcmpgtB(sign_x, high_x).slice()); // sign-mask from high_x(=vec)
    try loadV128IntoLocal(allocator, buf, alloc, spill_base_off, dst_x, vec_v); // dst = vec (reload)
    try buf.appendSlice(allocator, inst.encPunpcklbw(dst_x, sign_x).slice());
    try buf.appendSlice(allocator, inst.encPunpckhbw(high_x, sign_x).slice());
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(sign_x, count_r).slice()); // sign_x repurposed → count
    try buf.appendSlice(allocator, inst.encPsrawReg(dst_x, sign_x).slice());
    try buf.appendSlice(allocator, inst.encPsrawReg(high_x, sign_x).slice());
    try buf.appendSlice(allocator, inst.encPacksswb(dst_x, high_x).slice());
    try storeXmm7IfSpilledLocal(allocator, buf, alloc, spill_base_off, result_v);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI64x2ShrS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const count_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware (mask=XMM14, count=XMM15 internal; dst→home/XMM7,
    // vec loaded just-in-time into dst).
    const dst_x = try dstHomeOrXmm7(alloc, result_v);
    const count_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, count_v, 0);
    const mask_x = abi.fp_spill_stage_xmms[0]; // XMM14 — sign_bit_loc
    const count_x = abi.fp_spill_stage_xmms[1]; // XMM15 — count broadcast

    try buf.appendSlice(allocator, inst.encAndRImm8(.d, count_r, 63).slice());
    try buf.appendSlice(allocator, inst.encPcmpeqB(mask_x, mask_x).slice());
    try buf.appendSlice(allocator, inst.encPsllqImm(mask_x, 63).slice());
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(count_x, count_r).slice());
    try buf.appendSlice(allocator, inst.encPsrlqReg(mask_x, count_x).slice());
    try loadV128IntoLocal(allocator, buf, alloc, spill_base_off, dst_x, vec_v);
    try buf.appendSlice(allocator, inst.encPsrlqReg(dst_x, count_x).slice());
    try buf.appendSlice(allocator, inst.encPxor(dst_x, mask_x).slice());
    try buf.appendSlice(allocator, inst.encPsubq(dst_x, mask_x).slice());
    try storeXmm7IfSpilledLocal(allocator, buf, alloc, spill_base_off, result_v);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i64x2.mul) — pop two v128, push their
/// element-wise 64-bit product per lane (2 lanes; modular
/// wraparound at 2^64). x86_64 has **no native instruction**
/// for 64×64→64 packed multiply at the SSE4.1 baseline (AVX-512
/// VPMULLQ exists but is gated by ADR-0041 §"5. SSE4.1 minimum
/// baseline").
///
/// Synthesis (cranelift idiom — 8 instructions, 2 SIMD scratches):
///
/// Let lhs = (a1:a0) and rhs = (b1:b0) per 64-bit lane (a1 / b1
/// = high 32, a0 / b0 = low 32). The product mod 2^64 is:
///   a*b ≡ (a_hi * b_lo + a_lo * b_hi) << 32 + a_lo * b_lo
///
///   1. MOVAPS s1, lhs              ; s1 = a
///   2. PSRLQ  s1, 32               ; s1 = (0:a_hi)
///   3. PMULUDQ s1, rhs             ; s1 = a_hi * b_lo
///   4. MOVAPS s2, rhs              ; s2 = b
///   5. PSRLQ  s2, 32               ; s2 = (0:b_hi)
///   6. PMULUDQ s2, lhs             ; s2 = b_hi * a_lo
///   7. PADDQ  s1, s2               ; s1 = a_hi*b_lo + a_lo*b_hi
///   8. PSLLQ  s1, 32               ; (cross terms) << 32
///   9. MOVAPS dst, lhs (if dst != lhs)
///  10. PMULUDQ dst, rhs            ; dst = a_lo * b_lo (full 64-bit)
///  11. PADDQ  dst, s1              ; final = low + (cross<<32)
///
/// **Scratch reservation**: reuses `abi.fp_spill_stage_xmms`
/// (XMM14 / XMM15) as in-handler SIMD scratch. Safe because the
/// synthesis is atomic — no nested `xmmLoadSpilled` calls
/// intervene between the MOVAPS s1/s2 setup and the final
/// PADDQ. Avoids a new ABI reservation; mirrors the principle
/// from ARM64 op_simd.zig that scratch reuse is preferable to
/// pool churn (per ROADMAP P3 cold-start).
///
/// Aliasing safety (D-071 part a; D-066 mirror): regalloc's LIFO
/// slot-reuse can place `result_v` in the same physical XMM as
/// `rhs_v` (with `dst != lhs`). Step 9's `MOVAPS dst, lhs` then
/// overwrites rhs before step 10's `PMULUDQ dst, rhs` reads it,
/// degenerating step 10 to `a_lo * a_lo`. Symptom on OrbStack
/// simd_i64x2_arith: i64x2.mul(1, 0xFFFFFFFFFFFFFFFF) →
/// 0xFFFFFFFF_00000001 (= 1*1 + cross<<32) instead of
/// 0xFFFFFFFFFFFFFFFF. Stash rhs through XMM7 (project SIMD
/// scratch — `abi.zig:200` reserves it mirroring arm64's V31)
/// when the alias is detected; reads at steps 3, 4, and 10 use
/// the stashed copy.
pub fn emitI64x2Mul(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const s1 = abi.fp_spill_stage_xmms[0]; // XMM14
    const s2 = abi.fp_spill_stage_xmms[1]; // XMM15

    // The PMULUDQ synthesis needs lhs+rhs each live across 3 reads + 2 scratch
    // (s1/s2) — at the SSE baseline there is no free reg to also stage a spilled
    // operand, and PMULUDQ has no memory form. So the all-in-register case keeps
    // the proven recipe verbatim (byte-identical, unit-tested), and only the
    // spill case (D-034 (g)) restructures with just-in-time reloads.
    if (alloc.slot(result_v, .fpr) == .reg and alloc.slot(lhs_v, .fpr) == .reg and alloc.slot(rhs_v, .fpr) == .reg) {
        const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
        const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
        const dst_x = try gpr.resolveXmm(alloc, result_v);

        var rhs_for_op = rhs_x;
        if (dst_x != lhs_x and dst_x == rhs_x) {
            try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, rhs_x).slice());
            rhs_for_op = .xmm7;
        }

        // 1-3: cross term a_hi * b_lo into s1.
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(s1, lhs_x).slice());
        try buf.appendSlice(allocator, inst.encPsrlqImm(s1, 32).slice());
        try buf.appendSlice(allocator, inst.encPmuludq(s1, rhs_for_op).slice());

        // 4-6: cross term a_lo * b_hi into s2.
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(s2, rhs_for_op).slice());
        try buf.appendSlice(allocator, inst.encPsrlqImm(s2, 32).slice());
        try buf.appendSlice(allocator, inst.encPmuludq(s2, lhs_x).slice());

        // 7-8: combine cross terms and shift into the high half.
        try buf.appendSlice(allocator, inst.encPaddQ(s1, s2).slice());
        try buf.appendSlice(allocator, inst.encPsllqImm(s1, 32).slice());

        // 9-11: low product into dst, then add cross terms.
        if (dst_x != lhs_x) {
            try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, lhs_x).slice());
        }
        try buf.appendSlice(allocator, inst.encPmuludq(dst_x, rhs_for_op).slice());
        try buf.appendSlice(allocator, inst.encPaddQ(dst_x, s1).slice());

        try pushed_vregs.append(allocator, result_v);
        return;
    }

    // Spill path: dst → home/XMM7; lhs/rhs reloaded just-in-time into s1/s2/dst.
    // dst==rhs home-alias stashes rhs → XMM7 before dst is overwritten by lhs
    // (fires only when dst is a home reg → XMM7 free; a spilled result lands dst
    // on XMM7, where rhs can never alias it).
    const dst_x = try dstHomeOrXmm7(alloc, result_v);
    const rhs_stashed = switch (alloc.slot(rhs_v, .fpr)) {
        .reg => |id| (abi.fpSlotToReg(id) orelse return Error.SlotOverflow) == dst_x,
        .spill => false,
    };
    if (rhs_stashed) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, dst_x).slice());

    // s1 = a_hi * b_lo  (s2 holds rhs across the multiply).
    try loadV128IntoLocal(allocator, buf, alloc, spill_base_off, s1, lhs_v); // s1 = lhs
    try buf.appendSlice(allocator, inst.encPsrlqImm(s1, 32).slice()); // s1 = a_hi
    if (rhs_stashed) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(s2, .xmm7).slice());
    } else try loadV128IntoLocal(allocator, buf, alloc, spill_base_off, s2, rhs_v); // s2 = rhs
    try buf.appendSlice(allocator, inst.encPmuludq(s1, s2).slice()); // s1 = a_hi * b_lo
    // s2 = b_hi * a_lo  (dst doubles as the a_lo holder, left holding lhs).
    try buf.appendSlice(allocator, inst.encPsrlqImm(s2, 32).slice()); // s2 = b_hi
    try loadV128IntoLocal(allocator, buf, alloc, spill_base_off, dst_x, lhs_v); // dst = lhs
    try buf.appendSlice(allocator, inst.encPmuludq(s2, dst_x).slice()); // s2 = b_hi * a_lo
    // combine cross terms into the high half.
    try buf.appendSlice(allocator, inst.encPaddQ(s1, s2).slice());
    try buf.appendSlice(allocator, inst.encPsllqImm(s1, 32).slice());
    // low product into dst (still = lhs = a_lo), then add cross terms.
    if (rhs_stashed) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(s2, .xmm7).slice());
    } else try loadV128IntoLocal(allocator, buf, alloc, spill_base_off, s2, rhs_v); // s2 = rhs (reload)
    try buf.appendSlice(allocator, inst.encPmuludq(dst_x, s2).slice()); // dst = a_lo * b_lo
    try buf.appendSlice(allocator, inst.encPaddQ(dst_x, s1).slice());

    try storeXmm7IfSpilledLocal(allocator, buf, alloc, spill_base_off, result_v);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i8x16.min_s) — packed signed 8-bit min.
pub fn emitI8x16MinS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPminsb);
}

/// Wasm spec §4.4.4 (i8x16.min_u) — packed unsigned 8-bit min.
pub fn emitI8x16MinU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPminub);
}

/// Wasm spec §4.4.4 (i8x16.max_s) — packed signed 8-bit max.
pub fn emitI8x16MaxS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaxsb);
}

/// Wasm spec §4.4.4 (i8x16.max_u) — packed unsigned 8-bit max.
pub fn emitI8x16MaxU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaxub);
}

/// Wasm spec §4.4.4 (i16x8.min_s) — packed signed 16-bit min.
pub fn emitI16x8MinS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPminsw);
}

/// Wasm spec §4.4.4 (i16x8.min_u) — packed unsigned 16-bit min.
pub fn emitI16x8MinU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPminuw);
}

/// Wasm spec §4.4.4 (i16x8.max_s) — packed signed 16-bit max.
pub fn emitI16x8MaxS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaxsw);
}

/// Wasm spec §4.4.4 (i16x8.max_u) — packed unsigned 16-bit max.
pub fn emitI16x8MaxU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaxuw);
}

/// Wasm spec §4.4.4 (i32x4.min_s) — packed signed 32-bit min.
pub fn emitI32x4MinS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPminsd);
}

/// Wasm spec §4.4.4 (i32x4.min_u) — packed unsigned 32-bit min.
pub fn emitI32x4MinU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPminud);
}

/// Wasm spec §4.4.4 (i32x4.max_s) — packed signed 32-bit max.
pub fn emitI32x4MaxS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaxsd);
}

/// Wasm spec §4.4.4 (i32x4.max_u) — packed unsigned 32-bit max.
pub fn emitI32x4MaxU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaxud);
}

/// Wasm spec §4.4.4 (i8x16.add_sat_s) — packed signed saturating add.
pub fn emitI8x16AddSatS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPaddsb);
}

/// Wasm spec §4.4.4 (i8x16.add_sat_u) — packed unsigned saturating add.
pub fn emitI8x16AddSatU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPaddusb);
}

/// Wasm spec §4.4.4 (i8x16.sub_sat_s) — packed signed saturating sub.
pub fn emitI8x16SubSatS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsubsb);
}

/// Wasm spec §4.4.4 (i8x16.sub_sat_u) — packed unsigned saturating sub.
pub fn emitI8x16SubSatU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsubusb);
}

/// Wasm spec §4.4.4 (i16x8.add_sat_s) — packed signed saturating add.
pub fn emitI16x8AddSatS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPaddsw);
}

/// Wasm spec §4.4.4 (i16x8.add_sat_u) — packed unsigned saturating add.
pub fn emitI16x8AddSatU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPaddusw);
}

/// Wasm spec §4.4.4 (i16x8.sub_sat_s) — packed signed saturating sub.
pub fn emitI16x8SubSatS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsubsw);
}

/// Wasm spec §4.4.4 (i16x8.sub_sat_u) — packed unsigned saturating sub.
pub fn emitI16x8SubSatU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsubusw);
}

/// Wasm spec §4.4.4 (i8x16.avgr_u) — packed unsigned 8-bit
/// rounded average: (a+b+1) >> 1 per lane.
pub fn emitI8x16AvgrU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPavgb);
}

/// Wasm spec §4.4.4 (i16x8.avgr_u) — packed unsigned 16-bit
/// rounded average: (a+b+1) >> 1 per lane.
pub fn emitI16x8AvgrU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPavgw);
}

/// Wasm spec §4.4.4 (i16x8.q15mulr_sat_s) — Q15-format multiply
/// with rounding and saturating clamp to i16: result =
/// sat_s16(round((a*b) / 2^15)). PMULHRSW (SSSE3) computes the
/// round-and-shift but does NOT saturate the single overflowing
/// case: when a == b == -32768 (0x8000), round((-32768)^2 / 2^15)
/// = +32768 which PMULHRSW wraps to 0x8000 (-32768). The Wasm spec
/// (and arm64 SQRDMULH) require saturation to +32767 (0x7FFF).
///
/// Correction: every genuine PMULHRSW result lies in [-32767,
/// +32767] (|round(a*b/2^15)| ≤ 32767 for a,b in [-32768,32767]),
/// so a raw output of exactly 0x8000 occurs ONLY in the
/// a==b==-32768 overflow lane (verified exhaustively). Detect
/// product lanes equal to 0x8000 and flip them to 0x7FFF:
///   splat = 0x8000-per-word            (PCMPEQW ones; PSLLW 15)
///   prod  = PMULHRSW(a, b)
///   ovf   = PCMPEQW(prod, splat)        (0xFFFF where prod==0x8000)
///   result = prod XOR ovf               (0x8000 XOR 0xFFFF = 0x7FFF)
/// XOR 0x0000 leaves every non-overflow lane unchanged.
///
/// Only XMM7 (the project SIMD scratch) is free here: XMM14/XMM15
/// are the spill-staging registers that `xmmLoadSpilledV128` /
/// `xmmDefSpilledV128` may already hold the inputs/result in
/// (ADR-0053), so the splat mask + overflow detect both reuse
/// dst / XMM7 only.
pub fn emitI16x8Q15mulrSatS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const rhs_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, rhs_v, 0);
    const lhs_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, lhs_v, 1);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const splat: inst.Xmm = .xmm7; // 0x8000-per-word, then overflow mask

    // Stash rhs through XMM14 staging is unavailable (it may hold a
    // spilled input); instead compute the product into dst first
    // and re-read it for the overflow compare — dst is the only
    // register that survives the PMULHRSW write, so no input alias
    // can corrupt the compare.
    var rhs_for_op = rhs_x;
    if (dst_x != lhs_x and dst_x == rhs_x) {
        // dst aliases rhs: MOVAPS dst,lhs would clobber rhs before
        // PMULHRSW reads it. Stash rhs through XMM7 (reused as splat
        // afterwards — splat is only needed post-product).
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, rhs_x).slice());
        rhs_for_op = .xmm7;
    }
    if (dst_x != lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, lhs_x).slice());
    }
    // dst = round-mul-shift(a, b).
    try buf.appendSlice(allocator, inst.encPmulhrsw(dst_x, rhs_for_op).slice());
    // splat (XMM7) = 0x8000 per word.
    try buf.appendSlice(allocator, inst.encPcmpeqW(splat, splat).slice());
    try buf.appendSlice(allocator, inst.encPsllwImm(splat, 15).slice());
    // splat := (dst == 0x8000) ? 0xFFFF : 0x0000 — the overflow mask.
    try buf.appendSlice(allocator, inst.encPcmpeqW(splat, dst_x).slice());
    // dst ^= overflow mask: 0x8000 -> 0x7FFF on overflow lanes only.
    try buf.appendSlice(allocator, inst.encPxor(dst_x, splat).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i32x4.dot_i16x8_s) — pairwise dot product
/// of i16 lanes producing 4 i32 lanes. PMADDWD (SSE2,
/// `lower.isle:4073-4078`) implements exactly this in 1
/// instruction. Wrapping i32 accumulation matches Wasm spec
/// (INT16_MIN^2 + INT16_MIN^2 wraps modulo 2^32).
pub fn emitI32x4DotI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaddwd);
}

/// `i16x8.relaxed_dot_i8x16_i7x16_s` — single PMADDUBSW with SWAPPED
/// operands: PMADDUBSW(dst, src) = unsigned_dst × signed_src, but relaxed_dot
/// needs **signed a** × b. So dst = b (the i7 operand, treated unsigned — that
/// is the spec's b-latitude, `(either)`-covered) and src = a (signed). Passing
/// a as the unsigned dst is WRONG for a<0 (caught by the official corpus on
/// x86: a=0x80 gave +32512 vs signed −32512). arm64 SMULL is signed×signed.
/// Mirrors emitV128IntBinop but with dst←rhs(b), op-src←lhs(a).
pub fn emitI16x8RelaxedDot(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const b_v = pushed_vregs.pop().?; // rhs (top) = b (i7 operand → unsigned dst)
    const a_v = pushed_vregs.pop().?; // lhs = a (signed src)
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const a_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, a_v, 0);
    const b_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, b_v, 1);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    // dst = b; PMADDUBSW(dst, a). Stash a via XMM7 if dst aliases a (D-066 mirror).
    var a_for_op = a_x;
    if (dst_x != b_x and dst_x == a_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, a_x).slice());
        a_for_op = .xmm7;
    }
    if (dst_x != b_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, b_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPmaddubsw(dst_x, a_for_op).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// `i32x4.relaxed_dot_i8x16_i7x16_add_s` (3-pop a,b,c) — 4-way i8 dot +
/// accumulate: PMADDUBSW→i16x8; PMADDWD(·, ones_i16)→i32x4 pairwise sum;
/// PADDD(·, c). ones_i16 const-free via PCMPEQW+PSRLW#15. PMADDUBSW(dst,src) =
/// unsigned_dst × signed_src → dst MUST hold **b** (i7 operand, unsigned per
/// the spec b-latitude, `(either)`-covered) and src **a** (signed) — passing a
/// as unsigned dst is wrong for a<0 (official-corpus bug). Staging: force a→XMM15,
/// c→XMM14, b→dst; PMADDUBSW(dst=b, XMM15=a).
pub fn emitI32x4RelaxedDotAdd(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const c_v = pushed_vregs.pop().?;
    const b_v = pushed_vregs.pop().?;
    const a_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const xmm14 = abi.fp_spill_stage_xmms[0];
    const xmm15 = abi.fp_spill_stage_xmms[1];

    // Force a → XMM15 (signed src), c → XMM14 (alias-safe vs dst).
    const c_home = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, c_v, 0);
    if (c_home != xmm14) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(xmm14, c_home).slice());
    const a_home = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, a_v, 1);
    if (a_home != xmm15) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(xmm15, a_home).slice());

    const result_slot = alloc.slot(result_v, .fpr);
    const dst: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };
    // Load b into dst (the unsigned PMADDUBSW operand).
    switch (alloc.slot(b_v, .fpr)) {
        .reg => |id| {
            const b_home = abi.fpSlotToReg(id) orelse return Error.SlotOverflow;
            if (dst != b_home) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, b_home).slice());
        },
        .spill => |off| {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(dst, disp).slice());
        },
    }

    try buf.appendSlice(allocator, inst.encPmaddubsw(dst, xmm15).slice()); // dst = i16x8 dot (b unsigned × a signed)
    // ones_i16 → XMM15 (reuse, b dead): PCMPEQW gives -1, PSRLW#15 → 1 per lane.
    try buf.appendSlice(allocator, inst.encPcmpeqW(xmm15, xmm15).slice());
    try buf.appendSlice(allocator, inst.encPsrlwImm(xmm15, 15).slice());
    try buf.appendSlice(allocator, inst.encPmaddwd(dst, xmm15).slice()); // dst = i32x4 pairwise sum
    try buf.appendSlice(allocator, inst.encPaddD(dst, xmm14).slice()); // dst += c

    if (result_slot == .spill) {
        const disp = try gpr.v128SpillDisp(spill_base_off, result_slot.spill);
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

/// 16-byte 0x0F-per-byte mask used by popcnt's nibble-split path.
const NIBBLE_MASK_BROADCAST: [16]u8 = [_]u8{0x0F} ** 16;

/// Wasm spec §4.4.4 (i8x16.popcnt) per-byte popcount LUT used by
/// popcnt's PSHUFB-LUT path. Byte i = popcount(i) for i in 0..15.
const POPCNT_LUT: [16]u8 = [_]u8{ 0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4 };

/// Wasm spec §4.4.4 (i8x16.popcnt) — per-byte population count
/// via SSSE3 PSHUFB-LUT (cranelift `lower.isle:2491-2517`). Two
/// const-pool entries: 16-byte LUT[0..15] = popcount(i), and a
/// 0x0F-per-byte nibble mask. The recipe splits each byte into
/// low/high nibbles, looks each up in the LUT via PSHUFB, then
/// adds. PSHUFB clobbers its destination so the LUT must be
/// reloaded between the two halves.
///
/// Recipe (11 instr including 2 const loads, fits 2-scratch budget;
/// + optional 1-instr stash on the `dst==src` alias case):
/// 0.  MOVAPS XMM7, src                 ; only when dst_x == src_x
/// 1.  MOVUPS XMM15, [RIP+nibble_mask]
/// 2-4. compute high_nibbles into XMM14 (MOVAPS+PSRLW+PAND)
/// 5.  MOVUPS dst, [RIP+LUT]
/// 6.  PSHUFB dst, XMM14                ; popcount(high)
/// 7-8. compute low_nibbles into XMM14 (MOVAPS+PAND)
/// 9.  MOVUPS XMM15, [RIP+LUT]          ; reload (clobbers mask)
/// 10. PSHUFB XMM15, XMM14              ; popcount(low)
/// 11. PADDB dst, XMM15
///
/// Aliasing safety (D-071 part b; D-066 mirror): regalloc's LIFO
/// slot-reuse can place `result_v` in the same physical XMM as
/// `src_v` (1-pop op: src dies at popcnt's pop, slot reused for
/// result). Step 5's `MOVUPS dst, [RIP+LUT]` overwrites src
/// before step 7's `MOVAPS t1, src_x` re-reads it; the low-nibble
/// path then computes `LUT[LUT[low_nibble(src)]]` (since LUT[i] <
/// 16 for all i) instead of `LUT[low_nibble(src)]`. Symptom on
/// OrbStack simd_i8x16_arith2: popcnt(0xFF) → 5 vs 8, popcnt(0x80)
/// → 2 vs 1, popcnt(0x01) → 0 vs 1. Stash src through XMM7
/// (project SIMD scratch — `abi.zig:200` reserves it mirroring
/// arm64's V31).
pub fn emitI8x16Popcnt(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    simd_const_fixups: *std.ArrayList(@import("types.zig").SimdConstFixup),
    extra_consts: *std.ArrayList([16]u8),
    simd_consts_base: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware. t1=XMM14, t2=XMM15 are internal scratch; dst→home/
    // XMM7. src is read twice (into t1) — materialise it just-in-time: a home reg
    // directly, an XMM7 stash when dst aliases src's home (the D-071 alias, fires
    // only when dst is a home reg → XMM7 is free), or an RBP-disp reload from the
    // slot each time when spilled.
    const dst_x = try dstHomeOrXmm7(alloc, result_v);
    const t1 = abi.fp_spill_stage_xmms[0]; // XMM14
    const t2 = abi.fp_spill_stage_xmms[1]; // XMM15
    const src_reg: ?inst.Xmm = switch (alloc.slot(src_v, .fpr)) {
        .reg => |id| blk: {
            const home = abi.fpSlotToReg(id) orelse return Error.SlotOverflow;
            if (home == dst_x) {
                try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, home).slice());
                break :blk .xmm7;
            }
            break :blk home;
        },
        .spill => null,
    };

    const lut_idx = try op_simd.lookupOrAppendExtraConst(allocator, extra_consts, simd_consts_base, POPCNT_LUT);
    const mask_idx = try op_simd.lookupOrAppendExtraConst(allocator, extra_consts, simd_consts_base, NIBBLE_MASK_BROADCAST);

    // 1: t2 = nibble_mask (0x0F per byte).
    try op_simd.emitConstLoad(allocator, buf, simd_const_fixups, t2, mask_idx);
    // 2-4: t1 = high_nibbles per byte. PSRLW shifts at word level
    // so the mask AND is required.
    if (src_reg) |r| {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(t1, r).slice());
    } else try loadV128IntoLocal(allocator, buf, alloc, spill_base_off, t1, src_v);
    try buf.appendSlice(allocator, inst.encPsrlwImm(t1, 4).slice());
    try buf.appendSlice(allocator, inst.encPand(t1, t2).slice());
    // 5-6: dst = LUT, then PSHUFB(dst, t1) → dst = popcount(high).
    try op_simd.emitConstLoad(allocator, buf, simd_const_fixups, dst_x, lut_idx);
    try buf.appendSlice(allocator, inst.encPshufb(dst_x, t1).slice());
    // 7-8: t1 = low_nibbles per byte. PAND with mask suffices —
    // no shift needed.
    if (src_reg) |r| {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(t1, r).slice());
    } else try loadV128IntoLocal(allocator, buf, alloc, spill_base_off, t1, src_v);
    try buf.appendSlice(allocator, inst.encPand(t1, t2).slice());
    // 9-10: t2 = LUT (reload — t2 was the mask, no longer needed),
    // then PSHUFB(t2, t1) → t2 = popcount(low).
    try op_simd.emitConstLoad(allocator, buf, simd_const_fixups, t2, lut_idx);
    try buf.appendSlice(allocator, inst.encPshufb(t2, t1).slice());
    // 11: dst = popcount(high) + popcount(low) = popcount(byte).
    try buf.appendSlice(allocator, inst.encPaddB(dst_x, t2).slice());

    try storeXmm7IfSpilledLocal(allocator, buf, alloc, spill_base_off, result_v);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI32x4DotI16x8SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4DotI16x8S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8Q15mulrSatSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8Q15mulrSatS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}
