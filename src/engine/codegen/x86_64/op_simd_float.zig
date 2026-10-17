// FILE-SIZE-EXEMPT: per-op handler catalog (Wasm SIMD-128 FP sub-language); P1 spec-defined (per ADR-0099)
//! x86_64 emit pass - SIMD-128 FP op handlers (split from
//! `op_simd.zig` per ADR-0054).
//!
//! Houses all `emitF32x4*` / `emitF64x2*` handlers + FP-class
//! recipes (`emitV128FpCmp`, `emitV128FpUnop`, `emitV128FpMin`,
//! `emitV128FpMax`, `emitV128FpAbs`, `emitV128FpNeg`,
//! `emitV128FpRound`, `emitV128FpPseudoBinop`) plus the
//! trunc-sat FP conversion handlers.
//!
//! Cross-class consumers (e.g. `op_simd_int_arith` Abs handlers
//! reaching `emitV128FpUnop`) import this module and use its
//! `pub` recipe helpers.
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

const Allocator = std.mem.Allocator;
const Error = types.Error;

// `(ctx, ins)` adapters for the
// SIMD f32x4 arith cohort (8 ops). add/sub/mul/div are 6-arg;
// min/max/pmin/pmax are 5-arg.

pub fn emitF32x4AddCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Add(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4SubCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Sub(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4MulCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Mul(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4DivCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Div(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4MinCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Min(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4MaxCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Max(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4PminCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Pmin(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4PmaxCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Pmax(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapters for the
// SIMD f64x2 arith cohort (8 ops; mirror of the f32x4 cohort).

pub fn emitF64x2AddCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Add(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2SubCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Sub(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2MulCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Mul(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2DivCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Div(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2MinCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Min(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2MaxCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Max(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2PminCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Pmin(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2PmaxCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Pmax(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapters for the
// SIMD float unary cohort (14 ops; all 5-arg).

pub fn emitF32x4AbsCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Abs(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4NegCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Neg(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4SqrtCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Sqrt(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4CeilCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Ceil(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4FloorCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Floor(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4TruncCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Trunc(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4NearestCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Nearest(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2AbsCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Abs(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2NegCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Neg(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2SqrtCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Sqrt(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2CeilCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Ceil(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2FloorCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Floor(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2TruncCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Trunc(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2NearestCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Nearest(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapters for the
// SIMD float compare cohort (12 ops; all 5-arg).

pub fn emitF32x4EqCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Eq(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4NeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Ne(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4LtCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Lt(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4GtCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Gt(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4LeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Le(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4GeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Ge(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2EqCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Eq(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2NeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Ne(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2LtCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Lt(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2GtCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Gt(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2LeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Le(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2GeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Ge(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

/// Wasm spec §4.4.4 (f*x*.{eq, ne, lt, gt, le, ge}) — pop two
/// v128, push v128 where each lane is all-ones if the IEEE-754
/// comparison holds else all-zero. Wasm requires ordered eq / lt /
/// gt / le / ge (NaN inputs ⇒ false) and unordered ne (NaN ⇒
/// true). Mapped to CMPPS / CMPPD imm8 predicates per Intel SDM
/// Vol 2A "CMPPS" Table 3-7:
///   0 = EQ_OQ  (Wasm eq)
///   1 = LT_OS  (Wasm lt; via swap covers gt)
///   2 = LE_OS  (Wasm le; via swap covers ge)
///   4 = NEQ_UQ (Wasm ne)
///
/// gt and ge use `swap_operands = true` with predicate LT / LE
/// per cranelift `lower.isle:2169-2172` (no native ordered-gt
/// predicate exists in the legacy 0..7 imm8 range; CMPPS(b, a, LT)
/// computes b < a which is a > b). One-instruction emit + the
/// MOVAPS preamble matches the integer signed-compare shape.
fn emitV128FpCmp(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm, imm8: u8) inst.EncodedInsn,
    imm8: u8,
    swap_operands: bool,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const base_v = if (swap_operands) rhs_v else lhs_v;
    const cmp_v = if (swap_operands) lhs_v else rhs_v;

    // D-034 (g): spill-aware 3-v128-operand shape (base, cmp, dst) that keeps the
    // common (no-spill) emit byte-identical. cmp stays where it resolves (home,
    // or stage1/XMM15 when spilled — no forced copy); dst → home or XMM7 when
    // spilled; base loaded into dst (MOVAPS reg-home, or RBP-disp v128 load when
    // spilled); CMPPS dst, cmp; store XMM7 → dst slot when spilled. The only
    // clobber hazard is dst==cmp (both home, the classic D-066 alias) — a stage
    // reg never equals a home reg, so the XMM7 stash still covers exactly that.
    const cmp_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, cmp_v, 1);
    const result_slot = alloc.slot(result_v, .fpr);
    const dst_x: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };
    const base_is_dst = switch (alloc.slot(base_v, .fpr)) {
        .reg => |id| (abi.fpSlotToReg(id) orelse return Error.SlotOverflow) == dst_x,
        .spill => false,
    };

    var cmp_for_op = cmp_x;
    if (!base_is_dst and dst_x == cmp_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, cmp_x).slice());
        cmp_for_op = .xmm7;
    }
    switch (alloc.slot(base_v, .fpr)) {
        .reg => |id| {
            const base_home = abi.fpSlotToReg(id) orelse return Error.SlotOverflow;
            if (dst_x != base_home) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, base_home).slice());
        },
        .spill => |off| {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(dst_x, disp).slice());
        },
    }
    try buf.appendSlice(allocator, encoder(dst_x, cmp_for_op, imm8).slice());

    if (result_slot == .spill) {
        const disp = try gpr.v128SpillDisp(spill_base_off, result_slot.spill);
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitF32x4Eq(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCmpps, 0x00, false);
}

pub fn emitF32x4Ne(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCmpps, 0x04, false);
}

pub fn emitF32x4Lt(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCmpps, 0x01, false);
}

pub fn emitF32x4Gt(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCmpps, 0x01, true);
}

pub fn emitF32x4Le(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCmpps, 0x02, false);
}

pub fn emitF32x4Ge(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCmpps, 0x02, true);
}

pub fn emitF64x2Eq(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCmppd, 0x00, false);
}

pub fn emitF64x2Ne(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCmppd, 0x04, false);
}

pub fn emitF64x2Lt(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCmppd, 0x01, false);
}

pub fn emitF64x2Gt(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCmppd, 0x01, true);
}

pub fn emitF64x2Le(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCmppd, 0x02, false);
}

pub fn emitF64x2Ge(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCmppd, 0x02, true);
}

/// Wasm spec §4.4.4 (f*x*.{add, sub, mul, div}) — pop two v128,
/// push v128 with per-lane IEEE-754 binary FP result. Reuses
/// the `op_simd.emitV128IntBinop` shape unchanged because the encoder
/// signature `(dst, src) → EncodedInsn` is identical (the int /
/// fp distinction is purely in the encoder's opcode byte). NaN
/// propagation matches Wasm spec since SSE FP-arith instructions
/// (add/sub/mul/div) are canonical IEEE-754 ops — NaN inputs
/// produce NaN outputs without correction.
///
/// f32x4/f64x2.min and .max are NOT in this chunk because SSE
/// MINPS/MAXPS use "if unordered, return src2" semantics that
/// differ from Wasm's IEEE-754-2019 minimum/maximum (NaN-
/// propagating, signed-zero-aware). Cranelift wraps MINPS/MAXPS
/// with a 7-instruction NaN/zero correction sequence per
/// `lower.isle` "F32X4 (fmin _ x y)" — deferred with
/// proper synthesis.
pub fn emitF32x4Add(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encAddps);
}

pub fn emitF32x4Sub(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encSubps);
}

pub fn emitF32x4Mul(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encMulps);
}

pub fn emitF32x4Div(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encDivps);
}

pub fn emitF64x2Add(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encAddpd);
}

pub fn emitF64x2Sub(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encSubpd);
}

pub fn emitF64x2Mul(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encMulpd);
}

pub fn emitF64x2Div(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encDivpd);
}

/// Wasm spec §4.4.4 (f*x*.sqrt) — pop one v128, push v128 with
/// per-lane sqrt result. Single-instruction emit (SQRTPS/SQRTPD
/// xmm_dst, xmm_src) — no MOVAPS preamble needed because SQRT is
/// pure unary (src is read-only; dst is written). NaN inputs
/// propagate canonically per IEEE-754.
pub fn emitV128FpUnop(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const val_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware v128 src+dst. Single-instruction unary (SQRTPS/PD,
    // CVTDQ2PS/PD, CVTPS2PD, CVTPD2PS) with NO internal scratch → clean 2-stage
    // split (src→stage0/XMM14, dst→stage1/XMM15), like emitV128FpRound.
    const val_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, val_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);

    try buf.appendSlice(allocator, encoder(dst_x, val_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitF32x4Sqrt(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encSqrtps);
}

pub fn emitF64x2Sqrt(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encSqrtpd);
}

/// Wasm spec §4.4.4 (f*x*.{min, max}) — pop two v128, push v128
/// with per-lane IEEE-754-2019 minimum / maximum (NaN-propagating,
/// signed-zero-aware). Native SSE MINPS/MAXPS use "if unordered,
/// return src2" semantics that don't match the spec; cranelift's
/// recipe (`lower.isle:2783-2939`) wraps MINPS/MAXPS with a NaN
/// /zero-correction synthesis sequence per
/// `lessons_vs_adr.md` cross-reference.
///
/// fmin (10 instr): MINPS twice (forced ordering) + ORPS to merge
/// signed-zero distinguishability + CMPPS-UNORD to detect NaN
/// lanes + ORPS to lift NaN payloads + PSRLD to leave canonical
/// QNaN bits + ANDNPS to mask off non-canonical NaN payload bits.
///
/// fmax (13 instr): MAXPS twice + XORPS to detect divergence +
/// ORPS to compose NaN exponent + SUBPS to ensure +0 over -0 in
/// the +0/-0 mismatch case + CMPPS-UNORD self-compare for NaN
/// detection + PSRLD + ANDNPS for NaN canonicalisation.
///
/// F32X4 uses PSRLD shift=10 (1 sign + 8 exponent + 1 QNaN bit
/// preserved); F64X2 uses PSRLQ shift=13 (1 + 11 + 1).
///
/// Two scratch xmms are needed: XMM14 (fp_spill_stage_xmms[0])
/// and XMM15 (fp_spill_stage_xmms[1]) per abi.zig. Aliasing
/// invariants match emitV128IntCmpSigned (current x86_64 regalloc
/// allocates fresh xmm slots for new vregs; D-036 / Phase 15
/// class-aware allocation will revisit alongside coalescer-driven
/// aliasing).
const FpMinMaxEncoders = struct {
    minmax: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    or_: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    xor_: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    sub: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    cmp: *const fn (dst: inst.Xmm, src: inst.Xmm, imm8: u8) inst.EncodedInsn,
    andn: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    psrl_imm: *const fn (dst: inst.Xmm, count: u8) inst.EncodedInsn,
    shift_count: u8, // 10 for F32X4, 13 for F64X2
};

const f32x4_minmax_encs: FpMinMaxEncoders = .{
    .minmax = undefined, // set per call (encMinps for fmin, encMaxps for fmax)
    .or_ = inst.encOrps,
    .xor_ = inst.encXorps,
    .sub = inst.encSubps,
    .cmp = inst.encCmpps,
    .andn = inst.encAndnps,
    .psrl_imm = inst.encPsrldImm,
    .shift_count = 10,
};

const f64x2_minmax_encs: FpMinMaxEncoders = .{
    .minmax = undefined,
    .or_ = inst.encOrpd,
    .xor_ = inst.encXorpd,
    .sub = inst.encSubpd,
    .cmp = inst.encCmppd,
    .andn = inst.encAndnpd,
    .psrl_imm = inst.encPsrlqImm,
    .shift_count = 13,
};

/// fmin recipe (10 instructions). dst ends holding the canonical
/// fmin result. scratch (XMM14) holds intermediate min2; scratch2
/// (XMM15) holds intermediate min_or → is_nan_mask → masked.
fn emitV128FpMin(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encs: FpMinMaxEncoders,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware fmin (5 v128 roles, peak-4-live). dst→home or XMM7;
    // scratch XMM14, scratch2 XMM15. Spilled lhs/rhs are loaded just-in-time:
    // scratch2 (XMM15) doubles as the temp for a spilled rhs (steps 2-3) then a
    // spilled lhs (step 4) — its own scratch2 role only begins at step 6. The
    // no-spill path stays byte-identical (loadV128Into / resolveOrLoadV128 emit
    // nothing extra for home regs).
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14
    const scratch2_x = abi.fp_spill_stage_xmms[1]; // XMM15
    const result_slot = alloc.slot(result_v, .fpr);
    const dst_x: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };

    // 1. dst = lhs (MOVAPS reg-home — skip if dst==home — or RBP-disp load).
    try loadV128Into(allocator, buf, alloc, spill_base_off, dst_x, lhs_v);
    // 2. dst = MIN(dst, rhs).
    const rhs_reg = try resolveOrLoadV128(allocator, buf, alloc, spill_base_off, rhs_v, scratch2_x);
    try buf.appendSlice(allocator, encs.minmax(dst_x, rhs_reg).slice());
    // 3. scratch = MOVAPS rhs (rhs is in its home reg or scratch2 from step 2).
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch_x, rhs_reg).slice());
    // 4. scratch = MIN(scratch, lhs). rhs is dead → scratch2 free to hold a spilled lhs.
    const lhs_reg = try resolveOrLoadV128(allocator, buf, alloc, spill_base_off, lhs_v, scratch2_x);
    try buf.appendSlice(allocator, encs.minmax(scratch_x, lhs_reg).slice());
    // 5. dst = OR(dst, scratch)         ; dst = min_or
    try buf.appendSlice(allocator, encs.or_(dst_x, scratch_x).slice());
    // 6. scratch2 = MOVAPS dst          ; scratch2 = min_or
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch2_x, dst_x).slice());
    // 7. dst = CMP(dst, scratch, UNORD=3) ; dst = is_nan_mask
    try buf.appendSlice(allocator, encs.cmp(dst_x, scratch_x, 0x03).slice());
    // 8. scratch2 = OR(scratch2, dst)   ; scratch2 = min_or_2
    try buf.appendSlice(allocator, encs.or_(scratch2_x, dst_x).slice());
    // 9. dst = PSRL(dst, shift_count)   ; dst = nan_fraction_mask
    try buf.appendSlice(allocator, encs.psrl_imm(dst_x, encs.shift_count).slice());
    // 10. dst = ANDN(dst, scratch2)     ; dst = ~nan_fraction_mask & min_or_2 = final
    try buf.appendSlice(allocator, encs.andn(dst_x, scratch2_x).slice());

    try storeV128IfSpilled(allocator, buf, spill_base_off, result_slot);
    try pushed_vregs.append(allocator, result_v);
}

/// D-034 (g) helpers for the spill-aware fmin/fmax (5-v128-role ops).
/// `loadV128Into`: put operand `v`'s value into `reg` (MOVAPS from its home reg,
/// skipped when reg already IS the home; or an RBP-disp v128 load when spilled).
fn loadV128Into(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, spill_base_off: u32, reg: inst.Xmm, v: usize) Error!void {
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

/// `resolveOrLoadV128`: return the operand's home reg directly when not spilled
/// (no emit); when spilled, load it into `temp` and return `temp`.
fn resolveOrLoadV128(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, spill_base_off: u32, v: usize, temp: inst.Xmm) Error!inst.Xmm {
    return switch (alloc.slot(v, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => |off| blk: {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(temp, disp).slice());
            break :blk temp;
        },
    };
}

/// `storeV128IfSpilled`: flush XMM7 → the result's spill slot when the result spilled.
fn storeV128IfSpilled(allocator: Allocator, buf: *std.ArrayList(u8), spill_base_off: u32, result_slot: regalloc.Slot) Error!void {
    if (result_slot == .spill) {
        const disp = try gpr.v128SpillDisp(spill_base_off, result_slot.spill);
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
}

/// fmax recipe (13 instructions). dst ends holding the canonical
/// fmax result.
fn emitV128FpMax(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encs: FpMinMaxEncoders,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware fmax. dst is NOT written until step 5, so its reg
    // (home or XMM7) doubles as the just-in-time temp for a spilled rhs (steps
    // 2-3) then a spilled lhs (step 4); from step 5 it carries the result.
    // No-spill path stays byte-identical.
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14
    const scratch2_x = abi.fp_spill_stage_xmms[1]; // XMM15
    const result_slot = alloc.slot(result_v, .fpr);
    const dst_x: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };

    // 1. scratch = MOVAPS lhs (or RBP-disp load when spilled).
    try loadV128Into(allocator, buf, alloc, spill_base_off, scratch_x, lhs_v);
    // 2. scratch = MAX(scratch, rhs).
    const rhs_reg = try resolveOrLoadV128(allocator, buf, alloc, spill_base_off, rhs_v, dst_x);
    try buf.appendSlice(allocator, encs.minmax(scratch_x, rhs_reg).slice());
    // 3. scratch2 = MOVAPS rhs (home reg or dst_x from step 2).
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch2_x, rhs_reg).slice());
    // 4. scratch2 = MAX(scratch2, lhs). rhs dead → dst_x free to hold a spilled lhs.
    const lhs_reg = try resolveOrLoadV128(allocator, buf, alloc, spill_base_off, lhs_v, dst_x);
    try buf.appendSlice(allocator, encs.minmax(scratch2_x, lhs_reg).slice());
    // 5. dst = MOVAPS scratch              ; dst = max1
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, scratch_x).slice());
    // 6. dst = XOR(dst, scratch2)          ; dst = max_xor (= max1 ^ max2)
    try buf.appendSlice(allocator, encs.xor_(dst_x, scratch2_x).slice());
    // 7. scratch = OR(scratch, dst)        ; scratch = max1 | max_xor = max_blended_nan
    try buf.appendSlice(allocator, encs.or_(scratch_x, dst_x).slice());
    // 8. scratch2 = MOVAPS scratch         ; scratch2 = max_blended_nan
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch2_x, scratch_x).slice());
    // 9. scratch = SUB(scratch, dst)       ; scratch = max_blended_nan - max_xor = max_blended_nan_positive
    try buf.appendSlice(allocator, encs.sub(scratch_x, dst_x).slice());
    // 10. scratch2 = CMP(scratch2, scratch2, UNORD=3) ; scratch2 = is_nan_mask
    try buf.appendSlice(allocator, encs.cmp(scratch2_x, scratch2_x, 0x03).slice());
    // 11. dst = MOVAPS scratch2            ; dst = is_nan_mask
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, scratch2_x).slice());
    // 12. dst = PSRL(dst, shift_count)     ; dst = nan_fraction_mask
    try buf.appendSlice(allocator, encs.psrl_imm(dst_x, encs.shift_count).slice());
    // 13. dst = ANDN(dst, scratch)         ; dst = ~nan_fraction_mask & max_blended_nan_positive = final
    try buf.appendSlice(allocator, encs.andn(dst_x, scratch_x).slice());

    try storeV128IfSpilled(allocator, buf, spill_base_off, result_slot);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitF32x4Min(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    var encs = f32x4_minmax_encs;
    encs.minmax = inst.encMinps;
    return emitV128FpMin(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, encs);
}

pub fn emitF32x4Max(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    var encs = f32x4_minmax_encs;
    encs.minmax = inst.encMaxps;
    return emitV128FpMax(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, encs);
}

pub fn emitF64x2Min(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    var encs = f64x2_minmax_encs;
    encs.minmax = inst.encMinpd;
    return emitV128FpMin(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, encs);
}

pub fn emitF64x2Max(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    var encs = f64x2_minmax_encs;
    encs.minmax = inst.encMaxpd;
    return emitV128FpMax(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, encs);
}

// Relaxed-SIMD min/max — RAW hardware MINPS/MAXPS/MINPD/MAXPD (single
// instr), NOT the strict NaN/±0-propagating fixup recipe above (ADR-0169:
// relaxed ops take per-arch hardware semantics; NaN/±0 are impl-defined and
// MINPS returns the 2nd operand there). arm64 reuses its strict FMIN/FMAX
// (already raw NaN-propagating NEON). Plain 2-op→1 xmm binop.
pub fn emitF32x4RelaxedMin(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encMinps);
}
pub fn emitF32x4RelaxedMax(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encMaxps);
}
pub fn emitF64x2RelaxedMin(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encMinpd);
}
pub fn emitF64x2RelaxedMax(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encMaxpd);
}

// Relaxed-SIMD madd/nmadd — x86 has no FMA in the SSE2/SSE4 baseline,
// so emit UNFUSED MULPS+ADDPS (madd) / MULPS+SUBPS (nmadd). Per ADR-0169 the
// 2-rounding result is a valid relaxed_madd (impl-defined vs arm64's fused
// FMLA); edge fixtures use exact-representable inputs so both agree.
// 3-operand: pop c (acc, top), b, a → a*b+c (madd) / c-a*b (nmadd). b,c are
// force-copied into the stage XMMs (XMM14=c, XMM15=b) so they are alias-safe
// against dst (dst = result home reg, or XMM7 when spilled).
fn emitV128FpFmaX86(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32, is_sub: bool, is_f64: bool) Error!void {
    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const c_v = pushed_vregs.pop().?;
    const b_v = pushed_vregs.pop().?;
    const a_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const FpBinEnc = *const fn (inst.Xmm, inst.Xmm) inst.EncodedInsn;
    const mul: FpBinEnc = if (is_f64) inst.encMulpd else inst.encMulps;
    const add: FpBinEnc = if (is_f64) inst.encAddpd else inst.encAddps;
    const sub: FpBinEnc = if (is_f64) inst.encSubpd else inst.encSubps;
    const xmm14 = abi.fp_spill_stage_xmms[0];
    const xmm15 = abi.fp_spill_stage_xmms[1];

    // Force b → XMM15, c → XMM14 (in-reg operands are copied, spilled ones
    // already land in their stage reg). Both then survive any dst write.
    const c_home = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, c_v, 0);
    if (c_home != xmm14) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(xmm14, c_home).slice());
    const b_home = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, b_v, 1);
    if (b_home != xmm15) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(xmm15, b_home).slice());

    const result_slot = alloc.slot(result_v, .fpr);
    const dst: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };
    // Load a into dst (no-op when dst already is a's home reg).
    switch (alloc.slot(a_v, .fpr)) {
        .reg => |id| {
            const a_home = abi.fpSlotToReg(id) orelse return Error.SlotOverflow;
            if (dst != a_home) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, a_home).slice());
        },
        .spill => |off| {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(dst, disp).slice());
        },
    }

    try buf.appendSlice(allocator, mul(dst, xmm15).slice()); // dst = a*b
    if (is_sub) {
        // nmadd: c - a*b → compute in XMM14, copy back.
        try buf.appendSlice(allocator, sub(xmm14, dst).slice()); // xmm14 = c - a*b
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, xmm14).slice());
    } else {
        try buf.appendSlice(allocator, add(dst, xmm14).slice()); // dst = a*b + c
    }

    if (result_slot == .spill) {
        const disp = try gpr.v128SpillDisp(spill_base_off, result_slot.spill);
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitF32x4RelaxedMadd(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpFmaX86(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, false, false);
}
pub fn emitF32x4RelaxedNmadd(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpFmaX86(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, true, false);
}
pub fn emitF64x2RelaxedMadd(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpFmaX86(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, false, true);
}
pub fn emitF64x2RelaxedNmadd(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpFmaX86(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, true, true);
}

/// Wasm spec §4.4.4 (i8x16.shr_s) — pop count (i32), pop vec
/// (v128), push v128 with each byte signed-shifted right by
/// `c & 7`. SSE has no native byte arithmetic shift and no
/// PSRAQ; synthesise per cranelift `lower.isle:846+` by sign-
/// extending bytes to words, applying PSRAW per half, and
/// packing back with signed saturation:
///
///   AND count_r, 7
///   PXOR XMM14, XMM14                ; XMM14 = zero
///   PCMPGTB XMM14, vec                ; XMM14 = sign-mask of src
///                                     ;   (0xFF where src byte < 0, else 0x00)
///   MOVAPS XMM15, vec                 ; XMM15 = src (preserve for high-half)
///   MOVAPS dst, vec                   ; (skip-elide if dst==vec)
///   PUNPCKLBW dst, XMM14              ; dst = sign-extended low 8 bytes (8 i16)
///   PUNPCKHBW XMM15, XMM14            ; XMM15 = sign-extended high 8 bytes
///   MOVD XMM14, count_r               ; XMM14 = count (sign-mask consumed)
///   PSRAW dst, XMM14                  ; signed shift low half
///   PSRAW XMM15, XMM14                ; signed shift high half
///   PACKSSWB dst, XMM15               ; pack 16 i16 → 16 i8 with signed saturation
///
/// Saturation is a no-op in this path because each i16 word
/// holds an in-range sign-extended-then-shifted i8 value (the
/// PSRAW preserves the sign bit invariant, and the resulting
/// magnitude is bounded by the original i8 range). 11
/// instructions; uses both XMM14 + XMM15 scratches.
/// Wasm spec §4.4.4 (f*x*.{abs, neg}) — sign-mask synthesis
/// inline (no const-pool dep). 5-instr abs / 4-instr neg.
///
/// abs(x) = x AND ~sign-mask:
///   PCMPEQB XMM14, XMM14            ; 0xFF per byte
///   PSLL{D,Q} XMM14, {31,63}        ; sign-mask per dword/qword
///   MOVAPS dst, src                 ; (skip-elide if alias)
///   PANDN XMM14, dst                ; XMM14 = ~sign-mask & src = abs
///   MOVAPS dst, XMM14
///
/// neg(x) = x XOR sign-mask:
///   PCMPEQB XMM14, XMM14
///   PSLL{D,Q} XMM14, {31,63}
///   MOVAPS dst, src                 ; (skip-elide)
///   PXOR dst, XMM14                 ; dst = src XOR sign-mask = -x
fn emitV128FpAbs(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    psll_imm: *const fn (dst: inst.Xmm, count: u8) inst.EncodedInsn,
    shift_count: u8,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware v128 src+dst. The sign-bit mask moves to XMM7 (a
    // reserved scratch unused by abs) so BOTH stages are free: src→stage0/XMM14,
    // dst→stage1/XMM15. Under deep pressure src and dst both spill (dst's
    // vreg-index > src's), so a single free stage would not suffice.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const mask_x: inst.Xmm = .xmm7;

    try buf.appendSlice(allocator, inst.encPcmpeqB(mask_x, mask_x).slice());
    try buf.appendSlice(allocator, psll_imm(mask_x, shift_count).slice());
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPandn(mask_x, dst_x).slice()); // mask = ~mask & dst = abs
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, mask_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

fn emitV128FpNeg(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    psll_imm: *const fn (dst: inst.Xmm, count: u8) inst.EncodedInsn,
    shift_count: u8,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware v128 src+dst; sign-bit mask on XMM7 frees both
    // stages (src→stage0, dst→stage1). See emitV128FpAbs for the rationale.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const mask_x: inst.Xmm = .xmm7;

    try buf.appendSlice(allocator, inst.encPcmpeqB(mask_x, mask_x).slice());
    try buf.appendSlice(allocator, psll_imm(mask_x, shift_count).slice());
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPxor(dst_x, mask_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitF32x4Abs(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpAbs(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPslldImm, 31);
}

pub fn emitF64x2Abs(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpAbs(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsllqImm, 63);
}

pub fn emitF32x4Neg(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpNeg(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPslldImm, 31);
}

pub fn emitF64x2Neg(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpNeg(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsllqImm, 63);
}

/// Wasm spec §4.4.4 (f*x*.{ceil, floor, trunc, nearest}) —
/// SSE4.1 ROUNDPS/ROUNDPD with imm8 mode bits + suppress
/// precision exception (bit 3 set). Single-instr unary.
fn emitV128FpRound(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm, imm8: u8) inst.EncodedInsn,
    mode: u8,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware v128 src+dst. ROUNDPS/PD uses NO internal scratch
    // XMM, so both stages are free: src→stage0/XMM14, dst→stage1/XMM15.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    try buf.appendSlice(allocator, encoder(dst_x, src_x, 0x08 | (mode & 0x03)).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitF32x4Ceil(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encRoundps, 0b10);
}

pub fn emitF32x4Floor(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encRoundps, 0b01);
}

pub fn emitF32x4Trunc(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encRoundps, 0b11);
}

pub fn emitF32x4Nearest(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encRoundps, 0b00);
}

pub fn emitF64x2Ceil(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encRoundpd, 0b10);
}

pub fn emitF64x2Floor(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encRoundpd, 0b01);
}

pub fn emitF64x2Trunc(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encRoundpd, 0b11);
}

pub fn emitF64x2Nearest(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encRoundpd, 0b00);
}

/// Wasm spec §4.4.4 (FP convert family — signed + promote/demote)
/// — single-instr unaries via emitV128FpUnop:
///
///   f32x4.convert_i32x4_s   → CVTDQ2PS (4 i32 → 4 f32)
///   f64x2.convert_low_i32x4_s → CVTDQ2PD (2 low i32 → 2 f64)
///   f64x2.promote_low_f32x4 → CVTPS2PD (2 low f32 → 2 f64)
///   f32x4.demote_f64x2_zero → CVTPD2PS (2 f64 → 2 low f32, high 0)
///
/// Unsigned conversions and trunc-sat ops defer to later chunks
/// (cranelift uses const-pool float magic numbers per
/// `lower.isle:3761+`; pending ADR-0042 plumbing).
pub fn emitF32x4ConvertI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCvtdq2ps);
}

pub fn emitF64x2ConvertLowI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCvtdq2pd);
}

pub fn emitF64x2PromoteLowF32x4(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCvtps2pd);
}

pub fn emitF32x4DemoteF64x2Zero(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encCvtpd2ps);
}

/// Wasm spec §4.4.3 (f64x2.splat) — pop scalar f64 (XMM low 64),
/// push v128 with both 64-bit lanes equal. Single-instruction
/// `PSHUFD dst, src, 0x44` broadcasts the source's low qword
/// across both destination qwords (imm 0x44 = 0b01_00_01_00
/// selects src dwords 0,1,0,1 → dst.q[0] = (src.d[0], src.d[1]) =
/// src.q[0] and dst.q[1] = (src.d[0], src.d[1]) = src.q[0]).
pub fn emitF64x2Splat(
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

    // D-461: spill-aware FP-scalar source + v128 dst, stage 0 (PSHUFD is
    // read-before-write so dst==src stage reuse is safe). Mirrors f32x4.splat.
    const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);

    try buf.appendSlice(allocator, inst.encPshufd(dst_x, src_x, 0x44).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (f64x2.extract_lane <imm>) — pop v128, push
/// scalar f64 (XMM low 64). PSHUFD imm: lane=0 → 0x44 (= splat
/// shape, low qword copied through); lane=1 → 0xEE
/// (= 0b11_10_11_10, selecting src dwords 2,3,2,3 → dst.q[0] =
/// src.q[1]). The result XMM's high qword is duplicated; Wasm
/// consumers read only the low 64.
pub fn emitF64x2ExtractLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-461: spill-aware v128 src (16-byte) + FP-scalar dst (stages 0/1).
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilled(alloc, result_v, 1);

    const lane: u1 = @intCast(payload & 0b1);
    const imm8: u8 = if (lane == 0) 0x44 else 0xEE;
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, src_x, imm8).slice());
    try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (f64x2.replace_lane <imm>) — pop scalar f64,
/// pop v128, push v128 with one lane replaced.
///
/// Sequence:
///   MOVAPS dst, vec   (elided when dst aliases vec)
///   lane=0: MOVSD dst, value (overwrites low qword, preserves high)
///   lane=1: MOVLHPS dst, value (writes value's low qword to
///           dst's high qword, preserves dst's low qword)
///
/// Both reg-reg paths preserve the unchanged qword without an
/// extra MOVAPS or SHUFPD imm dance.
pub fn emitF64x2ReplaceLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const value_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-461 (i): spill-aware v128 vec-read (stage0/XMM14) + dst-write
    // (stage1/XMM15), mirroring arm64 emitV128ReplaceLaneFp.
    // D-034 (c): the new-lane FP scalar is now spill-aware too — loaded into
    // stage1 (XMM15 = dst's stage) when spilled; the XMM7 aliasing stash below
    // (dst == value, both XMM15 when both spilled) preserves it across the
    // MOVAPS-from-vec, exactly as in the all-home alias case.
    const value_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, value_v, 1);
    const vec_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, vec_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);

    // D-066 mirror class (D-078 (a) discharge):
    // when regalloc's LIFO slot-reuse aliases `dst == value &&
    // dst != vec`, the unconditional `MOVAPS dst, vec` clobbers
    // value before the subsequent MOVSD/MOVLHPS reads it. Stash
    // value through XMM7 (project-reserved scratch outside any
    // popcnt sequence; mutually exclusive with the dst==vec
    // case since that takes the MOVAPS-elide branch). Symptom
    // pre-fix on simd_lane.137 / `f64x2_extract_lane`: result
    // returned vec unchanged (= 0...0) instead of (value, vec_hi).
    var value_for_op = value_x;
    if (dst_x != vec_x and dst_x == value_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, value_x).slice());
        value_for_op = .xmm7;
    }
    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    const lane: u1 = @intCast(payload & 0b1);
    if (lane == 0) {
        try buf.appendSlice(allocator, inst.encMovsdXmmXmm(dst_x, value_for_op).slice());
    } else {
        try buf.appendSlice(allocator, inst.encMovlhps(dst_x, value_for_op).slice());
    }
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (f32x4.splat) — pop scalar f32 (XMM-class
/// vreg with the value in lane 0), push v128 with all four lanes
/// equal to the scalar. x86_64 lowering: a single `PSHUFD dst,
/// src, 0x00` broadcasts source lane 0 across all four 32-bit
/// destination lanes. Uses the integer-domain shuffle (PSHUFD)
/// even on FP data — the bit-level operation is identical, and
/// modern Intel / AMD micro-architectures bypass the FP↔int
/// domain crossing penalty when the surrounding ops also stay
/// in one domain.
pub fn emitF32x4Splat(
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

    // D-461: spill-aware FP-scalar source (8-byte MOVSD) + v128 dst. Both on
    // stage 0 (XMM14) — PSHUFD reads src dword 0 before writing dst, so a
    // dst==src stage reuse is safe (mirrors arm64 emitV128SplatFromV's DUP).
    const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);

    try buf.appendSlice(allocator, inst.encPshufd(dst_x, src_x, 0x00).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (f32x4.extract_lane <imm>) — pop v128, push
/// scalar f32 (XMM-class result with the chosen lane in low 32).
/// x86_64 lowering: a single `PSHUFD dst, src, lane * 0x55`.
/// `lane * 0x55` produces 0x00, 0x55, 0xAA, 0xFF — each value
/// has all four 2-bit fields equal to `lane`, so PSHUFD broadcasts
/// the source's `lane`-th dword across all four destination lanes
/// (lane 0 holds the desired value; subsequent FP scalar ops only
/// read low 32, so the duplication is harmless).
pub fn emitF32x4ExtractLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-461: spill-aware v128 src (16-byte) + FP-scalar dst. src→stage0/XMM14,
    // dst→stage1/XMM15 (distinct stages; PSHUFD reads src, writes dst).
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilled(alloc, result_v, 1);

    const lane: u8 = @intCast(payload & 0b11);
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, src_x, lane *% 0x55).slice());
    try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (f32x4.replace_lane <imm>) — pop scalar f32
/// (XMM low 32), pop v128, push v128 with lane `imm` replaced.
/// x86_64 lowering: `MOVAPS dst, vec` (elided when aliased) +
/// `INSERTPS dst, value, (lane << 4)`. The INSERTPS imm encodes
/// (count_s = 0, count_d = lane, ZMASK = 0): copy lane 0 of
/// `value` (= the scalar) into lane `lane` of `dst`, leave the
/// other three lanes untouched.
pub fn emitF32x4ReplaceLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const value_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-461 (i): spill-aware v128 vec-read (stage0) + dst-write (stage1).
    // D-034 (c): the new-lane FP scalar is now spill-aware too — loaded into
    // stage1 (XMM15 = dst's stage) when spilled; the existing XMM7 aliasing-stash
    // below (dst == value) already preserves it across the MOVAPS-from-vec.
    const value_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, value_v, 1);
    const vec_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, vec_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);

    // D-066 mirror class (bug-fix-time grep
    // sibling of `emitF64x2ReplaceLane`): when `dst == value &&
    // dst != vec`, the MOVAPS-from-vec clobbers value before
    // INSERTPS reads it. Stash value through XMM7 first.
    var value_for_op = value_x;
    if (dst_x != vec_x and dst_x == value_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, value_x).slice());
        value_for_op = .xmm7;
    }
    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    const lane: u8 = @intCast(payload & 0b11);
    const imm8: u8 = lane << 4;
    try buf.appendSlice(allocator, inst.encInsertps(dst_x, value_for_op, imm8).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (f32x4.convert_i32x4_u) — convert 4 unsigned
/// i32 lanes to f32. SSE has no native CVTUDQ2PS (AVX-512 only);
/// recipe per cranelift `lower.isle:3811-3831` splits each u32 into
/// low/high 16-bit halves, converts each via signed CVTDQ2PS, and
/// recombines: low half is exact, high half is shifted-right-1
/// then doubled to fit signed conversion's range. 11-instruction
/// inline recipe, no const-pool dep.
pub fn emitF32x4ConvertI32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware 2-internal-scratch convert. Both stages are the
    // recipe's scratch (a_lo/a_hi), so src+dst share one reg via the FMA-template
    // shape: load src INTO dst (home or XMM7 when spilled), then the recipe reads
    // dst (src is read-only and dead by the final write at step 10). +1 MOVAPS in
    // the common case — negligible for a rare convert.
    const a_lo = abi.fp_spill_stage_xmms[0]; // XMM14
    const a_hi = abi.fp_spill_stage_xmms[1]; // XMM15
    const result_slot = alloc.slot(result_v, .fpr);
    const dst_x: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };
    switch (alloc.slot(src_v, .fpr)) {
        .reg => |id| {
            const src_home = abi.fpSlotToReg(id) orelse return Error.SlotOverflow;
            if (dst_x != src_home) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_home).slice());
        },
        .spill => |off| {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(dst_x, disp).slice());
        },
    }

    // 1-3: a_lo = dst masked to low 16 bits per lane.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(a_lo, dst_x).slice());
    try buf.appendSlice(allocator, inst.encPslldImm(a_lo, 16).slice());
    try buf.appendSlice(allocator, inst.encPsrldImm(a_lo, 16).slice());

    // 4-5: a_hi = dst - a_lo gives the high 16 bits in each lane
    // (still up high; we never shifted them down).
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(a_hi, dst_x).slice());
    try buf.appendSlice(allocator, inst.encPsubD(a_hi, a_lo).slice());

    // 6: convert low halves via signed CVTDQ2PS (low halves fit
    // signed range cleanly — at most 0xFFFF).
    try buf.appendSlice(allocator, inst.encCvtdq2ps(a_lo, a_lo).slice());

    // 7-9: shift a_hi right by 1 to clear the sign bit so signed
    // CVTDQ2PS is exact, then double via ADDPS to undo the /2.
    try buf.appendSlice(allocator, inst.encPsrldImm(a_hi, 1).slice());
    try buf.appendSlice(allocator, inst.encCvtdq2ps(a_hi, a_hi).slice());
    try buf.appendSlice(allocator, inst.encAddps(a_hi, a_hi).slice());

    // 10-11: dst = a_hi + a_lo (overwrites dst, which held src — now dead).
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, a_hi).slice());
    try buf.appendSlice(allocator, inst.encAddps(dst_x, a_lo).slice());

    if (result_slot == .spill) {
        const disp = try gpr.v128SpillDisp(spill_base_off, result_slot.spill);
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i32x4.trunc_sat_f32x4_s) — saturating truncate
/// f32→i32. CVTTPS2DQ produces 0x80000000 for both NaN and OOR; the
/// Wasm spec requires NaN→0 and positive-OOR→INT32_MAX. Recipe per
/// cranelift `lower.isle:3848-3869`: 9-instruction inline path that
/// uses CMPPS-self-eq to detect NaN, AND-masks NaN to +0.0 before
/// CVTTPS2DQ, then XOR-corrects positive-OOR's 0x80000000 to
/// 0x7FFFFFFF via a sign-extend-of-bit-31 derived mask.
pub fn emitI32x4TruncSatF32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): 1-scratch XMM7-park — park the NaN-mask tmp on XMM7, freeing
    // both stages for src(0)+dst(1). src/dst/tmp are all live at once (step 3
    // MOVAPS dst,src while tmp holds the mask) but are 3 distinct reserved regs;
    // src stays in stage0 (nothing in the recipe overwrites it after step 3).
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const tmp: inst.Xmm = .xmm7;

    // 1-2: tmp = CMPPS(src, src, EQ_OQ) → all-1s where lane is not
    // NaN (since x==x is false only for NaN), 0 elsewhere.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(tmp, src_x).slice());
    try buf.appendSlice(allocator, inst.encCmpps(tmp, src_x, 0x00).slice());

    // 3-4: dst = src AND tmp → NaN lanes become +0.0, valid lanes
    // pass through.
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encAndps(dst_x, tmp).slice());

    // 5: tmp ^= dst — high bit of each lane is (¬NaN) XOR (sign of
    // src). Captures the "should be MAX" hint for positive OOR.
    try buf.appendSlice(allocator, inst.encXorps(tmp, dst_x).slice());

    // 6: trunc-saturate. NaN was already zeroed; positive OOR and
    // negative OOR both produce 0x80000000 (INT_MIN sentinel).
    try buf.appendSlice(allocator, inst.encCvttps2dq(dst_x, dst_x).slice());

    // 7-9: derive a per-lane mask = (positive-OOR? all-1s : 0),
    // applied via XOR to flip 0x80000000 → 0x7FFFFFFF without
    // touching valid or negative-OOR lanes.
    try buf.appendSlice(allocator, inst.encPand(tmp, dst_x).slice());
    try buf.appendSlice(allocator, inst.encPsradImm(tmp, 31).slice());
    try buf.appendSlice(allocator, inst.encPxor(dst_x, tmp).slice());

    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i32x4.trunc_sat_f32x4_u) — saturating
/// truncate f32→u32 (NaN→0, negative→0, OOR→UINT32_MAX). Recipe
/// per cranelift `lower.isle:3919-3962`: 14-instruction inline
/// path. CVTTPS2DQ saturates positive OOR to 0x80000000 (signed
/// INT_MIN), so the unsigned recipe splits into two paths:
/// (1) clamped src → CVTTPS2DQ direct for [0, INT_MAX]; (2) src
/// minus magic (INT_MAX+1 = 0x4f000000 as f32) → CVTTPS2DQ for
/// [INT_MAX+1, UINT_MAX]; mask the second-path result to 0 where
/// the lane belongs to path (1) and add. The "3 scratch xmm"
/// limit reported by cranelift's regalloc2 maps to dst (regalloc'd
/// from XMM8..XMM13) + XMM14 + XMM15 in zwasm — already covered
/// by the existing fp_spill_stage_xmms reservation; no ABI change
/// needed.
pub fn emitI32x4TruncSatF32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): 2-scratch in-place — both stages are the recipe's scratch
    // (tmp1/tmp2), so load src INTO dst (home or XMM7 when spilled); src is read
    // only here (the step-2 init), the rest of the recipe operates on dst.
    const tmp2 = abi.fp_spill_stage_xmms[0]; // XMM14: zero, then magic, then mask, then zero again
    const tmp1 = abi.fp_spill_stage_xmms[1]; // XMM15: second-path copy
    const result_slot = alloc.slot(result_v, .fpr);
    const dst_x: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };
    switch (alloc.slot(src_v, .fpr)) {
        .reg => |id| {
            const src_home = abi.fpSlotToReg(id) orelse return Error.SlotOverflow;
            if (dst_x != src_home) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_home).slice());
        },
        .spill => |off| {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(dst_x, disp).slice());
        },
    }

    // 1: tmp2 = 0 (XORPS XMM14, XMM14).
    try buf.appendSlice(allocator, inst.encXorps(tmp2, tmp2).slice());

    // 2: dst = MAXPS(dst, 0) — clamp negatives + NaN to 0 (dst already holds src).
    // (MAXPS returns 2nd operand on NaN per Intel SDM; with
    // 2nd operand = 0 the result is 0 for NaN lanes.)
    try buf.appendSlice(allocator, inst.encMaxps(dst_x, tmp2).slice());

    // 3-5: tmp2 = magic = 0x4f000000 (= f32(INT_MAX+1) via PSRLD-1
    // on all-ones then CVTDQ2PS round-up at the 2^23 boundary).
    try buf.appendSlice(allocator, inst.encPcmpeqD(tmp2, tmp2).slice());
    try buf.appendSlice(allocator, inst.encPsrldImm(tmp2, 1).slice());
    try buf.appendSlice(allocator, inst.encCvtdq2ps(tmp2, tmp2).slice());

    // 6: tmp1 = dst (clamped src) — second-path copy.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(tmp1, dst_x).slice());

    // 7: dst = CVTTPS2DQ(dst) — first path. Lanes in [0, INT_MAX]
    // produce correct i32; lanes >= INT_MAX+1 saturate to
    // 0x80000000 (signed INT_MIN sentinel) per Intel SDM.
    try buf.appendSlice(allocator, inst.encCvttps2dq(dst_x, dst_x).slice());

    // 8: tmp1 -= magic. Lanes in [0, INT_MAX] become negative;
    // lanes in [INT_MAX+1, UINT_MAX] become [0, INT_MAX]; lanes
    // >= UINT_MAX+1 become >= INT_MAX+1.
    try buf.appendSlice(allocator, inst.encSubps(tmp1, tmp2).slice());

    // 9: tmp2 = (magic LE tmp1) — mask: 0xFFFFFFFF where the
    // post-subtract value is >= magic (= original src >= UINT_MAX),
    // 0 elsewhere. CMPPS imm 0x02 = LE_OS.
    try buf.appendSlice(allocator, inst.encCmpps(tmp2, tmp1, 0x02).slice());

    // 10: tmp1 = CVTTPS2DQ(tmp1). Same saturation behaviour.
    try buf.appendSlice(allocator, inst.encCvttps2dq(tmp1, tmp1).slice());

    // 11: tmp1 ^= mask. Where the lane should saturate to UINT_MAX,
    // CVTTPS2DQ returned 0x80000000; XOR with 0xFFFFFFFF flips it
    // to 0x7FFFFFFF. (PADDD with first-path's 0x80000000 then
    // gives 0xFFFFFFFF = UINT_MAX.) Other lanes XOR with 0 = no-op.
    try buf.appendSlice(allocator, inst.encPxor(tmp1, tmp2).slice());

    // 12-13: clamp tmp1's first-path-only lanes (originally negative
    // post-subtract) to 0 via SMAX(tmp1, 0). Saturates to 0 the
    // [0, INT_MAX] lanes whose second path produced negative junk.
    try buf.appendSlice(allocator, inst.encPxor(tmp2, tmp2).slice());
    try buf.appendSlice(allocator, inst.encPmaxsd(tmp1, tmp2).slice());

    // 14: dst = first_path + second_path. For [0, INT_MAX] lanes
    // dst already holds the correct value + 0; for [INT_MAX+1,
    // UINT_MAX] dst holds 0x80000000 + (i32)(src - magic) = the
    // correct u32 reinterpreted as i32; for OOR-high lanes dst
    // holds 0x80000000 + 0x7FFFFFFF = 0xFFFFFFFF = UINT_MAX. ✓
    try buf.appendSlice(allocator, inst.encPaddD(dst_x, tmp1).slice());

    if (result_slot == .spill) {
        const disp = try gpr.v128SpillDisp(spill_base_off, result_slot.spill);
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

// =============================================================
// FP pseudo-min/max (4 ops: f32x4/f64x2.pmin/pmax)
// Wasm pmin(c1, c2) = if c2 < c1: c2 else c1. The MINPS/MINPD
// "return src on equal/NaN/both-zero" behaviour (Intel SDM Vol 2A)
// matches this exactly — provided we swap operands so dst holds
// c2 and src holds c1. cranelift `lower.isle:1542-1545` makes the
// same call via CLIF bitselect-of-fcmp-LT pattern matching MINPS.
// No new encoders; reuses encMinps/Maxps/Minpd/Maxpd.
// =============================================================

fn emitV128FpPseudoBinop(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware, mirroring emitV128FpCmp's 3-v128-operand template.
    // Pseudo-min/max lowers to `MOVAPS dst, rhs; OP dst, lhs` — the operand order
    // (NaN-propagating c1) must be preserved, so base = rhs (loaded into dst), the
    // second operand = lhs (stays home, or stage1/XMM15 when spilled). dst → home
    // or XMM7 when spilled. The only clobber hazard is the D-066 alias dst==lhs
    // (both home); the XMM7 stash covers exactly that (a stage reg never == home).
    const lhs_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, lhs_v, 1);
    const result_slot = alloc.slot(result_v, .fpr);
    const dst_x: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };
    const base_is_dst = switch (alloc.slot(rhs_v, .fpr)) {
        .reg => |id| (abi.fpSlotToReg(id) orelse return Error.SlotOverflow) == dst_x,
        .spill => false,
    };

    var lhs_for_op = lhs_x;
    if (!base_is_dst and dst_x == lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, lhs_x).slice());
        lhs_for_op = .xmm7;
    }
    try loadV128Into(allocator, buf, alloc, spill_base_off, dst_x, rhs_v);
    try buf.appendSlice(allocator, encoder(dst_x, lhs_for_op).slice());
    try storeV128IfSpilled(allocator, buf, spill_base_off, result_slot);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (f32x4.pmin) — pseudo-min, NaN-propagating c1.
pub fn emitF32x4Pmin(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpPseudoBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encMinps);
}

/// Wasm spec §4.4.4 (f32x4.pmax) — pseudo-max, NaN-propagating c1.
pub fn emitF32x4Pmax(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpPseudoBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encMaxps);
}

/// Wasm spec §4.4.4 (f64x2.pmin) — pseudo-min, NaN-propagating c1.
pub fn emitF64x2Pmin(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpPseudoBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encMinpd);
}

/// Wasm spec §4.4.4 (f64x2.pmax) — pseudo-max, NaN-propagating c1.
pub fn emitF64x2Pmax(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128FpPseudoBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encMaxpd);
}

// =============================================================
// int min/max + saturating arith + avgr_u (22 ops)
// All single-instruction native SSE2/SSE4.1 ops. Each wrapper
// dispatches through op_simd.emitV128IntBinop (2-in 1-out) with the
// matching encoder. No new helpers; cranelift maps the same way
// (`inst.isle:2470-2486`).
// =============================================================

/// Wasm spec §4.4.4 (i32x4.trunc_sat_f64x2_s_zero) — saturating
/// truncate low 2 f64 lanes → i32, with high 2 lanes of result
/// zeroed. Recipe per cranelift `lower.isle:4194-4214`:
///   1. NaN-detect via CMPPD self-EQ_OQ → mask
///   2. MINPD src, INT32_MAX_f64 → clamp positive OOR
///   3. ANDPD src, mask → zero NaN
///   4. CVTTPD2DQ dst, src → trunc; "_zero" suffix is automatic
///      (CVTTPD2DQ writes 2 i32 to low half, zeros high half).
/// Negative OOR (-INF / very-negative) becomes 0x80000000 by
/// CVTTPD2DQ's saturation semantics, matching Wasm INT32_MIN
/// clamp. The INT32_MAX_f64 const is stored in `extra_consts`
/// (a per-emit-pass pool extension since it's a shared static
/// constant rather than a per-instance literal).
const INT32_MAX_F64_BROADCAST: [16]u8 = blk: {
    // 2147483647.0 as f64 = 0x41DFFFFFFFC00000.
    // Per-qword broadcast, little-endian.
    var bytes: [16]u8 = undefined;
    const v: u64 = 0x41DFFFFFFFC00000;
    var i: usize = 0;
    while (i < 8) : (i += 1) bytes[i] = @intCast((v >> @intCast(i * 8)) & 0xFF);
    i = 0;
    while (i < 8) : (i += 1) bytes[8 + i] = bytes[i];
    break :blk bytes;
};

pub fn emitI32x4TruncSatF64x2SZero(
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

    // D-034 (g): 2-scratch in-place — both stages are scratch (tmp_const/tmp_mask),
    // so load src INTO dst (home or XMM7 when spilled); src is read only at step 2.
    const tmp_const = abi.fp_spill_stage_xmms[0]; // XMM14
    const tmp_mask = abi.fp_spill_stage_xmms[1]; // XMM15
    const result_slot = alloc.slot(result_v, .fpr);
    const dst_x: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };

    // Look up or append INT32_MAX_F64_BROADCAST in extra_consts.
    var const_idx: u32 = 0;
    var found = false;
    for (extra_consts.items, 0..) |c, i| {
        if (std.mem.eql(u8, &c, &INT32_MAX_F64_BROADCAST)) {
            const_idx = simd_consts_base + @as(u32, @intCast(i));
            found = true;
            break;
        }
    }
    if (!found) {
        const_idx = simd_consts_base + @as(u32, @intCast(extra_consts.items.len));
        try extra_consts.append(allocator, INT32_MAX_F64_BROADCAST);
    }

    // 1: load INT32_MAX_F64-broadcast → tmp_const (RIP-relative).
    const enc = inst.encMovupsXmmRipRelPlaceholder(tmp_const);
    const start_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, enc.slice());
    const enc_len: u32 = @intCast(enc.slice().len);
    try simd_const_fixups.append(allocator, .{
        .disp32_byte_offset = start_byte + enc_len - 4,
        .post_insn_byte = start_byte + enc_len,
        .const_idx = const_idx,
    });

    // 2: load src INTO dst (in-place; MOVAPS reg-home or RBP-disp load when spilled).
    switch (alloc.slot(src_v, .fpr)) {
        .reg => |id| {
            const src_home = abi.fpSlotToReg(id) orelse return Error.SlotOverflow;
            if (dst_x != src_home) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_home).slice());
        },
        .spill => |off| {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(dst_x, disp).slice());
        },
    }
    // 3: CMPPD tmp_mask, dst, EQ_OQ → mask of (lane==lane), 0 for NaN.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(tmp_mask, dst_x).slice());
    try buf.appendSlice(allocator, inst.encCmppd(tmp_mask, dst_x, 0x00).slice());
    // 4: MINPD dst, tmp_const → clamp upper to INT32_MAX_f64.
    try buf.appendSlice(allocator, inst.encMinpd(dst_x, tmp_const).slice());
    // 5: ANDPD dst, tmp_mask → zero NaN lanes.
    try buf.appendSlice(allocator, inst.encAndpd(dst_x, tmp_mask).slice());
    // 6: CVTTPD2DQ dst, dst → truncate; high 2 lanes auto-zeroed.
    try buf.appendSlice(allocator, inst.encCvttpd2dq(dst_x, dst_x).slice());

    if (result_slot == .spill) {
        const disp = try gpr.v128SpillDisp(spill_base_off, result_slot.spill);
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

/// 16-byte UINT32_MAX as f64 broadcast (4294967295.0 =
/// 0x41EFFFFFFFE00000 per qword). Used by `i32x4.trunc_sat_f64x2_u_zero`
/// to clamp positive OOR before the mantissa-overlay extraction.
const UINT32_MAX_F64_BROADCAST: [16]u8 = [_]u8{ 0x00, 0x00, 0xE0, 0xFF, 0xFF, 0xFF, 0xEF, 0x41 } ** 2;

/// 16-byte 0x43300000-per-dword broadcast — single-precision
/// pattern of 0x1.0p+52 used by `f64x2.convert_low_i32x4_u`'s
/// UNPCKLPS interleave.
const UINT_MASK_LOW: [16]u8 = [_]u8{ 0x00, 0x00, 0x30, 0x43 } ** 4;

/// 16-byte 0x4330000000000000-per-qword broadcast — f64 value of
/// 2^52, subtracted to extract the original u32 from the
/// mantissa-overlay.
const UINT_MASK_HIGH: [16]u8 = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x43 } ** 2;

/// Wasm spec §4.4.4 (i32x4.trunc_sat_f64x2_u_zero) — saturating
/// truncate low 2 f64 lanes → u32, with high 2 lanes of result
/// zeroed. Recipe per cranelift `lower.isle:5061-5093`:
///   1. MOVAPD dst, src
///   2. XORPD t1, t1                ; clear t1 (zeros)
///   3. MAXPD dst, t1                ; NaN→0 (MAXPD propagates 2nd
///      operand on unordered) AND negative-OOR→0
///   4. MINPD dst, UMAX_f64          ; clamp positive OOR
///   5. ROUNDPD dst, dst, 0x0B        ; round-to-zero +
///      precision-suppress (0x08 | 0x03)
///   6. ADDPD dst, 2^52_f64           ; add magic; mantissa low
///      32 of each qword is now the truncated u32
///   7. SHUFPS dst, t1, 0x88          ; gather lane[0..1].low32
///      into result lanes 0/1, lanes 2/3 zero (from t1=zeros)
///
/// Reuses UINT_MASK_HIGH (= 2^52 magic) via extra_consts
/// dedup. New const: UINT32_MAX_F64_BROADCAST.
pub fn emitI32x4TruncSatF64x2UZero(
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

    // D-034 (g): 2-scratch in-place — both stages are scratch (t1/t2), so load
    // src INTO dst (home or XMM7 when spilled); src is read only at step 1.
    const t1 = abi.fp_spill_stage_xmms[0]; // XMM14 (zeros + final SHUFPS source)
    const t2 = abi.fp_spill_stage_xmms[1]; // XMM15 (const loads)
    const result_slot = alloc.slot(result_v, .fpr);
    const dst_x: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };

    const umax_idx = try op_simd.lookupOrAppendExtraConst(allocator, extra_consts, simd_consts_base, UINT32_MAX_F64_BROADCAST);
    const magic_idx = try op_simd.lookupOrAppendExtraConst(allocator, extra_consts, simd_consts_base, UINT_MASK_HIGH);

    // 1: load src INTO dst (in-place; MOVAPS reg-home or RBP-disp load when spilled).
    switch (alloc.slot(src_v, .fpr)) {
        .reg => |id| {
            const src_home = abi.fpSlotToReg(id) orelse return Error.SlotOverflow;
            if (dst_x != src_home) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_home).slice());
        },
        .spill => |off| {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(dst_x, disp).slice());
        },
    }
    // 2: t1 = zeros via PXOR.
    try buf.appendSlice(allocator, inst.encPxor(t1, t1).slice());
    // 3: MAXPD dst, t1 — NaN + negative-OOR clamp to 0.
    try buf.appendSlice(allocator, inst.encMaxpd(dst_x, t1).slice());
    // 4: MINPD dst, UMAX_f64 — clamp positive OOR.
    try op_simd.emitConstLoad(allocator, buf, simd_const_fixups, t2, umax_idx);
    try buf.appendSlice(allocator, inst.encMinpd(dst_x, t2).slice());
    // 5: ROUNDPD dst, dst, 0x0B — round-to-zero + suppress
    // precision exception.
    try buf.appendSlice(allocator, inst.encRoundpd(dst_x, dst_x, 0x0B).slice());
    // 6: ADDPD dst, 2^52_f64 — mantissa-overlay; low 32 of each
    // qword is now the truncated u32.
    try op_simd.emitConstLoad(allocator, buf, simd_const_fixups, t2, magic_idx);
    try buf.appendSlice(allocator, inst.encAddpd(dst_x, t2).slice());
    // 7: SHUFPS dst, t1, 0x88 — gather low 32 of each qword into
    // i32x4 lanes 0/1, lanes 2/3 zero (from t1=zeros).
    try buf.appendSlice(allocator, inst.encShufps(dst_x, t1, 0x88).slice());

    if (result_slot == .spill) {
        const disp = try gpr.v128SpillDisp(spill_base_off, result_slot.spill);
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (f64x2.convert_low_i32x4_u) — convert low 2
/// unsigned i32 lanes to f64. SSE has no native CVTUDQ2PD;
/// recipe per cranelift `lower.isle:3775-3779` exploits IEEE-754
/// mantissa placement: interleave each u32 with 0x43300000 (the
/// f64 exponent for 2^52) to form 0x4330000000000000 + u32, which
/// as f64 = 2^52 + u32; subtract 2^52 to recover u32 exactly.
///
/// 5-instr recipe: load uint_mask_low + UNPCKLPS interleave +
/// load uint_mask_high + SUBPD.
pub fn emitF64x2ConvertLowI32x4U(
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

    // D-034 (g): 1-scratch XMM7-park — park the const-load tmp on XMM7, freeing
    // both stages for src(0)+dst(1). src is read only at step 1 (MOVAPS dst,src);
    // dst then carries the value, tmp on XMM7. store dst→slot if spilled.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const tmp: inst.Xmm = .xmm7;

    const low_idx = try op_simd.lookupOrAppendExtraConst(allocator, extra_consts, simd_consts_base, UINT_MASK_LOW);
    const high_idx = try op_simd.lookupOrAppendExtraConst(allocator, extra_consts, simd_consts_base, UINT_MASK_HIGH);

    // 1: dst = src.
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    // 2: tmp = uint_mask_low (0x43300000-per-dword).
    try op_simd.emitConstLoad(allocator, buf, simd_const_fixups, tmp, low_idx);
    // 3: UNPCKLPS dst, tmp — interleave low 32-bit lanes.
    // dst.lanes = [dst[0], tmp[0], dst[1], tmp[1]].
    // After this each qword of dst is 0x4330_0000_<u32_lane>, which
    // as f64 = 2^52 + u32_lane.
    try buf.appendSlice(allocator, inst.encUnpcklps(dst_x, tmp).slice());
    // 4: tmp = uint_mask_high (0x4330000000000000-per-qword = 2^52 as f64).
    try op_simd.emitConstLoad(allocator, buf, simd_const_fixups, tmp, high_idx);
    // 5: SUBPD dst, tmp — dst = (2^52 + u32) - 2^52 = u32 as f64.
    try buf.appendSlice(allocator, inst.encSubpd(dst_x, tmp).slice());

    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitF32x4SplatCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4Splat(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2SplatCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2Splat(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4ConvertI32x4SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4ConvertI32x4S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4ConvertI32x4UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4ConvertI32x4U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2ConvertLowI32x4SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2ConvertLowI32x4S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF64x2PromoteLowF32x4Ctx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF64x2PromoteLowF32x4(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitF32x4DemoteF64x2ZeroCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitF32x4DemoteF64x2Zero(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4TruncSatF32x4SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4TruncSatF32x4S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4TruncSatF32x4UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4TruncSatF32x4U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}
