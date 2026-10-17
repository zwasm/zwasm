// FILE-SIZE-EXEMPT: uniform `(ctx, ins)` adapter catalog (per ADR-0075)
//! x86_64 emit pass - SIMD-128 integer compare / lane / extend /
//! narrow / extmul / bitmask / all_true / swizzle / shuffle
//! op handlers (split from `op_simd.zig` per ADR-0054).
//!
//! Houses all integer comparison ops, lane access, narrow,
//! extend_low/high, extmul, extadd_pairwise, bitmask,
//! all_true dispatchers, swizzle, and shuffle. Recipe helpers
//! are file-private; cross-class primitives reach into
//! `op_simd.zig`.
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
// i8x16 compare cohort (10 ops). eq is 6-arg (has spill_base_off);
// remaining 9 are 5-arg.

pub fn emitI8x16EqCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16Eq(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16NeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16Ne(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16LtSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16LtS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16LtUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16LtU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16GtSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16GtS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16GtUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16GtU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16LeSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16LeS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16LeUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16LeU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16GeSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16GeS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16GeUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16GeU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapters for the
// i16x8 compare cohort (10 ops). eq is 6-arg; others 5-arg.

pub fn emitI16x8EqCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8Eq(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8NeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8Ne(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8LtSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8LtS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8LtUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8LtU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8GtSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8GtS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8GtUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8GtU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8LeSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8LeS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8LeUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8LeU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8GeSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8GeS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8GeUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8GeU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapters for the
// i32x4 compare cohort (10 ops). eq is 6-arg; others 5-arg.

pub fn emitI32x4EqCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4Eq(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4NeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4Ne(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4LtSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4LtS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4LtUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4LtU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4GtSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4GtS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4GtUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4GtU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4LeSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4LeS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4LeUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4LeU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4GeSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4GeS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4GeUCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4GeU(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapters for the
// i64x2 compare cohort (6 ops; no _u variants per Wasm SIMD
// spec). eq is 6-arg; others 5-arg.

pub fn emitI64x2EqCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2Eq(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2NeCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2Ne(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2LtSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2LtS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2GtSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2GtS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2LeSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2LeS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2GeSCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2GeS(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapters for SIMD
// bool reductions (8 ops: all_true × 4 widths + bitmask × 4 widths).
// All 6-arg.

pub fn emitI8x16AllTrueCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16AllTrue(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8AllTrueCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8AllTrue(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4AllTrueCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4AllTrue(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2AllTrueCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2AllTrue(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16BitmaskCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16Bitmask(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8BitmaskCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8Bitmask(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4BitmaskCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4Bitmask(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2BitmaskCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2Bitmask(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

// `(ctx, ins)` adapters for the
// SIMD narrow + extend cohort (16 ops). 12 extend (5-arg) + 4
// narrow (6-arg).

pub fn emitI16x8ExtendLowI8x16SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8ExtendLowI8x16S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8ExtendLowI8x16UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8ExtendLowI8x16U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8ExtendHighI8x16SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8ExtendHighI8x16S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8ExtendHighI8x16UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8ExtendHighI8x16U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ExtendLowI16x8SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4ExtendLowI16x8S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ExtendLowI16x8UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4ExtendLowI16x8U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ExtendHighI16x8SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4ExtendHighI16x8S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ExtendHighI16x8UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4ExtendHighI16x8U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2ExtendLowI32x4SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2ExtendLowI32x4S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2ExtendLowI32x4UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2ExtendLowI32x4U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2ExtendHighI32x4SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2ExtendHighI32x4S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2ExtendHighI32x4UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2ExtendHighI32x4U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16NarrowI16x8SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16NarrowI16x8S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16NarrowI16x8UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16NarrowI16x8U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8NarrowI32x4SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8NarrowI32x4S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8NarrowI32x4UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8NarrowI32x4U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8ExtmulLowI8x16SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8ExtmulLowI8x16S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8ExtmulHighI8x16SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8ExtmulHighI8x16S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8ExtmulLowI8x16UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8ExtmulLowI8x16U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8ExtmulHighI8x16UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8ExtmulHighI8x16U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ExtmulLowI16x8SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4ExtmulLowI16x8S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ExtmulHighI16x8SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4ExtmulHighI16x8S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ExtmulLowI16x8UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4ExtmulLowI16x8U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ExtmulHighI16x8UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4ExtmulHighI16x8U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2ExtmulLowI32x4SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2ExtmulLowI32x4S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2ExtmulHighI32x4SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2ExtmulHighI32x4S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2ExtmulLowI32x4UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2ExtmulLowI32x4U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2ExtmulHighI32x4UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2ExtmulHighI32x4U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16SplatCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16Splat(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8SplatCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8Splat(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4SplatCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4Splat(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI64x2SplatCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI64x2Splat(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI8x16SwizzleCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI8x16Swizzle(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8ExtaddPairwiseI8x16SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8ExtaddPairwiseI8x16S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI16x8ExtaddPairwiseI8x16UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI16x8ExtaddPairwiseI8x16U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ExtaddPairwiseI16x8SCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4ExtaddPairwiseI16x8S(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

pub fn emitI32x4ExtaddPairwiseI16x8UCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    _ = ins;
    return emitI32x4ExtaddPairwiseI16x8U(ctx.allocator, ctx.buf, ctx.alloc, ctx.pushed_vregs, ctx.next_vreg, ctx.spill_base_off);
}

/// Wasm spec §4.4.3 (i32x4.splat) — pop scalar i32, push v128
/// with all four lanes equal to the scalar. x86_64 lowering:
/// `MOVD xmm, r32` (zero-extends to 128 bits) followed by
/// `PSHUFD xmm, xmm, 0x00` to broadcast lane 0 to lanes 1-3.
///
/// Mirror of arm64's `emitI32x4Splat` (DUP V<vd>.4S, W<wn>) per
/// ROADMAP P7. The 2-instruction x86_64 sequence has no native
/// equivalent until AVX2's VPBROADCASTD; under ADR-0041's SSE4.1
/// baseline the MOVD + PSHUFD pair is the canonical idiom.
pub fn emitI32x4Splat(
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

    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    // D-461: spill-aware v128 dst (was resolveXmm-reject when the splat result
    // force-spills, e.g. feeding array.new_fixed). No internal XMM scratch
    // (movd+pshufd), so the dst safely uses stage0/XMM14.
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);

    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst_x, src_r).slice());
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, dst_x, 0x00).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (i32x4.extract_lane <imm>) — pop v128, push
/// scalar i32 = the lane at the immediate index. x86_64 lowering:
/// single `PEXTRD r32, xmm, imm8` (SSE4.1, mandated by ADR-0041
/// §"5. SSE4.1 minimum baseline"). The lane immediate is in
/// `ins.payload` (the lower pass's 1-byte encoding).
pub fn emitI32x4ExtractLane(
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

    // D-461: spill-aware v128 source (was resolveXmm-reject) — load a spilled
    // v128 into the stage XMM, mirroring the arm64 slice-1 (`97afa4d4`).
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    const lane: u2 = @intCast(payload & 0b11);
    try buf.appendSlice(allocator, inst.encPextrD(dst_r, src_x, lane).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (i64x2.extract_lane <imm>) — pop v128, push
/// scalar i64 = the 64-bit lane at the immediate index. Single
/// `PEXTRQ r64, xmm, imm8` (SSE4.1 REX.W=1; lane is u1 since
/// i64x2 has 2 lanes). Mirror of i32x4.extract_lane with
/// the .q-form encoder.
pub fn emitI64x2ExtractLane(
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

    // D-461: spill-aware v128 source (was resolveXmm-reject), same shape as
    // the tested i32x4.extract_lane (single src → PEXTR).
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    const lane: u1 = @intCast(payload & 0b1);
    try buf.appendSlice(allocator, inst.encPextrQ(dst_r, src_x, lane).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (signed lt_s/gt_s/le_s/ge_s) — pop two v128,
/// push v128 with all-ones lanes where the signed compare holds.
/// PCMPGT_<shape> is SSE2; the four Wasm variants synthesise as:
///
///   gt_s: PCMPGT(dst=lhs, rhs)              ; lhs > rhs
///   lt_s: PCMPGT(dst=rhs, lhs)              ; rhs > lhs ⇔ lhs < rhs
///   le_s: NOT PCMPGT(dst=lhs, rhs)          ; ¬(lhs > rhs) ⇔ lhs ≤ rhs
///   ge_s: NOT PCMPGT(dst=rhs, lhs)          ; ¬(lhs < rhs) ⇔ lhs ≥ rhs
///
/// NOT applies via PXOR with an all-ones mask (PCMPEQB scratch,
/// scratch on XMM14) — same idiom as emitV128IntNe.
const SignedCmpKind = enum { gt, lt, le, ge };

fn emitV128IntCmpSigned(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder_gt: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    kind: SignedCmpKind,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // For lt_s / ge_s the operand sense is reversed:
    // PCMPGT(dst=rhs, lhs) computes "rhs > lhs" = "lhs < rhs".
    const swap = (kind == .lt) or (kind == .ge);
    const base_v = if (swap) rhs_v else lhs_v;
    const cmp_v = if (swap) lhs_v else rhs_v;

    // D-034 (g): spill-aware 3-v128-operand (base, cmp, dst), mirroring
    // emitV128FpCmp. cmp → stage1/XMM15 when spilled; dst → home or XMM7; base
    // loaded into dst (MOVAPS reg-home, or RBP-disp v128 load when spilled). The
    // D-066 alias dst==cmp (both home) is covered by the XMM7 stash. le/ge's
    // all-ones inversion uses stage0/XMM14 — free here (cmp on stage1, base→dst).
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
    try buf.appendSlice(allocator, encoder_gt(dst_x, cmp_for_op).slice());

    // le_s / ge_s: invert via PXOR with all-ones.
    if (kind == .le or kind == .ge) {
        const ones = abi.fp_spill_stage_xmms[0]; // XMM14
        try buf.appendSlice(allocator, inst.encPcmpeqB(ones, ones).slice());
        try buf.appendSlice(allocator, inst.encPxor(dst_x, ones).slice());
    }

    if (result_slot == .spill) {
        const disp = try gpr.v128SpillDisp(spill_base_off, result_slot.spill);
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16GtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtB, .gt);
}

pub fn emitI8x16LtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtB, .lt);
}

pub fn emitI8x16LeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtB, .le);
}

pub fn emitI8x16GeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtB, .ge);
}

pub fn emitI16x8GtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtW, .gt);
}

pub fn emitI16x8LtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtW, .lt);
}

pub fn emitI16x8LeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtW, .le);
}

pub fn emitI16x8GeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtW, .ge);
}

pub fn emitI32x4GtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtD, .gt);
}

pub fn emitI32x4LtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtD, .lt);
}

pub fn emitI32x4LeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtD, .le);
}

pub fn emitI32x4GeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtD, .ge);
}

/// Wasm spec §4.4.4 (i64x2.gt_s) — pop two v128, push v128 where
/// each 64-bit lane is all-ones if lhs > rhs (signed) else
/// all-zero. Threads the SSE4.2 PCMPGTQ encoder through the
/// shared `emitV128IntCmpSigned` helper (operand swap for lt;
/// PXOR-with-all-ones for le/ge). Per ADR-0041 §5 (SSE4.2
/// amendment) — synthesis from SSE4.1 primitives rejected.
pub fn emitI64x2GtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtQ, .gt);
}

/// Wasm spec §4.4.4 (i64x2.lt_s) — see emitI64x2GtS docstring.
pub fn emitI64x2LtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtQ, .lt);
}

/// Wasm spec §4.4.4 (i64x2.le_s) — see emitI64x2GtS docstring.
pub fn emitI64x2LeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtQ, .le);
}

/// Wasm spec §4.4.4 (i64x2.ge_s) — see emitI64x2GtS docstring.
pub fn emitI64x2GeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpgtQ, .ge);
}

/// Wasm spec §4.4.4 (i*x*.{lt_u, gt_u, le_u, ge_u}) — pop two v128,
/// push v128 where each lane is all-ones if lhs op rhs (unsigned)
/// else all-zero. PMINU/PMAXU + PCMPEQ recipe (cranelift
/// `lower.isle:2016-2080`):
///
///   gt_u(a,b): max=PMAXU(a,b) ; result = NOT PCMPEQ(max,b)
///   lt_u(a,b): min=PMINU(a,b) ; result = NOT PCMPEQ(min,b)
///   ge_u(a,b): max=PMAXU(a,b) ; result = PCMPEQ(a,max)
///   le_u(a,b): min=PMINU(a,b) ; result = PCMPEQ(a,min)
///
/// dst gets MOVAPS lhs first (skip-elision when dst==lhs) then the
/// PMINU/PMAXU encoder writes max/min into dst. For ge/le, PCMPEQ
/// dst, lhs computes (max/min == lhs) which is the unsigned ≥/≤
/// result. For gt/lt, PCMPEQ dst, rhs computes (max/min == rhs)
/// then PXOR with all-ones (XMM14 scratch) inverts.
///
/// Two-instruction MOVAPS+PMINU/PMAXU (when dst != lhs) plus the
/// ≤ 3-instr tail mirrors `emitV128IntCmpSigned`'s MOVAPS-elide
/// pattern. Aliasing `dst == rhs` is not handled (matches
/// emitV128IntCmpSigned's stance — current x86_64 regalloc allocates
/// fresh xmm slots for new vregs; D-036 / Phase 15 class-aware
/// allocation will revisit alongside coalescer-driven aliasing).
const UnsignedCmpKind = enum { gt, lt, le, ge };

fn emitV128IntCmpUnsigned(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder_minmax: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    encoder_pcmpeq: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    kind: UnsignedCmpKind,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware 3-v128-operand. dst → home or XMM7; a spilled rhs
    // loads into stage1/XMM15 (survives minmax + the gt/lt tail), a spilled lhs
    // into stage0/XMM14 (dead after the MOVAPS for gt/lt; survives for ge/le,
    // which never builds the XMM14 all-ones). The D-066 XMM7 aliasing stashes
    // below only fire when dst is a home reg (a stage/XMM7 never equals a home
    // reg), so the no-spill emit is byte-identical. result-spill flushes XMM7.
    const rhs_x = try resolveOrLoadV128(allocator, buf, alloc, spill_base_off, rhs_v, abi.fp_spill_stage_xmms[1]);
    const lhs_x = try resolveOrLoadV128(allocator, buf, alloc, spill_base_off, lhs_v, abi.fp_spill_stage_xmms[0]);
    const result_slot = alloc.slot(result_v, .fpr);
    const dst_x: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };

    // Aliasing safety (D-066 mirror; D-071 part c discharge).
    // Two independent risky aliases:
    //   - `dst == rhs`: the min/max overwrites rhs before the
    //     gt/lt tail reads it again (PCMPEQ dst, rhs_for_op).
    //     Stash rhs through XMM7.
    //   - `dst == lhs` (ge/le only): the min/max overwrites lhs
    //     before the ge/le tail reads it (PCMPEQ dst, lhs_x).
    //     Stash lhs through XMM7. Mutually exclusive with the
    //     dst==rhs stash since dst can't equal both unless
    //     lhs == rhs (degenerate self-compare; behaviour preserved
    //     either way).
    var rhs_for_op = rhs_x;
    var lhs_for_tail = lhs_x;
    if (dst_x != lhs_x and dst_x == rhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, rhs_x).slice());
        rhs_for_op = .xmm7;
    }
    if ((kind == .ge or kind == .le) and dst_x == lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, lhs_x).slice());
        lhs_for_tail = .xmm7;
    }
    if (dst_x != lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, lhs_x).slice());
    }
    try buf.appendSlice(allocator, encoder_minmax(dst_x, rhs_for_op).slice());

    switch (kind) {
        .ge, .le => {
            try buf.appendSlice(allocator, encoder_pcmpeq(dst_x, lhs_for_tail).slice());
        },
        .gt, .lt => {
            try buf.appendSlice(allocator, encoder_pcmpeq(dst_x, rhs_for_op).slice());
            const ones = abi.fp_spill_stage_xmms[0];
            try buf.appendSlice(allocator, inst.encPcmpeqB(ones, ones).slice());
            try buf.appendSlice(allocator, inst.encPxor(dst_x, ones).slice());
        },
    }

    if (result_slot == .spill) {
        const disp = try gpr.v128SpillDisp(spill_base_off, result_slot.spill);
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

/// D-034 (g): dst register — its home XMM when not spilled, else XMM7 (flushed
/// at the end via storeV128IfSpilledLocal).
fn dstHomeOrXmm7Cmp(alloc: regalloc.Allocation, result_v: usize) Error!inst.Xmm {
    return switch (alloc.slot(result_v, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse Error.SlotOverflow,
        .spill => .xmm7,
    };
}

/// D-034 (g): put operand `v`'s value into `reg` (MOVAPS from its home XMM,
/// skipped when `reg` already IS the home; or an RBP-disp v128 load when spilled).
fn loadV128IntoCmp(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, spill_base_off: u32, reg: inst.Xmm, v: usize) Error!void {
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

/// D-034 (g) file-local v128 spill helper: returns the operand's home XMM when
/// not spilled (no emit); when spilled, emits an RBP-disp v128 load into `temp`
/// and returns `temp`. Mirrors op_simd_float.zig's resolveOrLoadV128.
fn resolveOrLoadV128(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    v: usize,
    temp: inst.Xmm,
) Error!inst.Xmm {
    return switch (alloc.slot(v, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => |off| blk: {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(temp, disp).slice());
            break :blk temp;
        },
    };
}

/// D-034 (g) file-local: flush XMM7 → the result's spill slot when result spilled
/// (a no-op when result is in a home reg). Pairs with the `dst → home or XMM7`
/// idiom used by the spill-aware handlers in this file.
fn storeV128IfSpilledLocal(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    result_v: usize,
) Error!void {
    switch (alloc.slot(result_v, .fpr)) {
        .reg => {},
        .spill => |off| {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
        },
    }
}

pub fn emitI8x16GtU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaxub, inst.encPcmpeqB, .gt);
}

pub fn emitI8x16LtU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPminub, inst.encPcmpeqB, .lt);
}

pub fn emitI8x16LeU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPminub, inst.encPcmpeqB, .le);
}

pub fn emitI8x16GeU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaxub, inst.encPcmpeqB, .ge);
}

pub fn emitI16x8GtU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaxuw, inst.encPcmpeqW, .gt);
}

pub fn emitI16x8LtU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPminuw, inst.encPcmpeqW, .lt);
}

pub fn emitI16x8LeU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPminuw, inst.encPcmpeqW, .le);
}

pub fn emitI16x8GeU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaxuw, inst.encPcmpeqW, .ge);
}

pub fn emitI32x4GtU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaxud, inst.encPcmpeqD, .gt);
}

pub fn emitI32x4LtU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPminud, inst.encPcmpeqD, .lt);
}

pub fn emitI32x4LeU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPminud, inst.encPcmpeqD, .le);
}

pub fn emitI32x4GeU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmaxud, inst.encPcmpeqD, .ge);
}

pub fn emitI8x16AllTrue(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128AllTrue(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqB);
}

pub fn emitI16x8AllTrue(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128AllTrue(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqW);
}

pub fn emitI32x4AllTrue(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128AllTrue(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqD);
}

pub fn emitI64x2AllTrue(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128AllTrue(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqQ);
}

/// Wasm spec §4.4.4 (i*x*.bitmask) — pop v128, push i32 with the
/// high bit of each lane packed into the low bits of the result.
/// Per-shape recipes from cranelift `lower.isle:4962-4981`:
///   i8x16: PMOVMSKB direct (1 instr; 16-bit mask in low 16 bits).
///   i32x4: MOVMSKPS direct (1 instr; 4-bit mask).
///   i64x2: MOVMSKPD direct (1 instr; 2-bit mask).
///   i16x8: PACKSSWB(src, src) duplicates word high bits into byte
///          high bits, then PMOVMSKB extracts 16 bits, SHR 8 keeps
///          one half (8-bit mask).
pub fn emitI8x16Bitmask(
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

    // D-461: spill-aware v128 source (stage 0; no scratch XMM used here, so no
    // stage collision). Result already gprDefSpilled-aware.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    try buf.appendSlice(allocator, inst.encPmovmskb(dst_r, src_x).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI16x8Bitmask(
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

    // D-461: spill-aware v128 source — load into STAGE 1 (XMM15), NOT stage 0,
    // because this op uses stage-0 XMM14 as its PACKSSWB scratch (`scratch_x`
    // below). A stage-0 load would clobber the source. Backward-compatible
    // (home XMM when not spilled).
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 1);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14

    // scratch = MOVAPS src ; scratch = PACKSSWB(scratch, src) — packs
    // 8 words from each operand into 16 saturated bytes; high bit of
    // each output byte = high bit of source word. Both halves carry
    // the same pattern when src is duplicated.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch_x, src_x).slice());
    try buf.appendSlice(allocator, inst.encPacksswb(scratch_x, src_x).slice());
    try buf.appendSlice(allocator, inst.encPmovmskb(dst_r, scratch_x).slice());
    try buf.appendSlice(allocator, inst.encShrRImm8(.d, dst_r, 8).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI32x4Bitmask(
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

    // D-461: spill-aware v128 source (stage 0; no scratch XMM used here).
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    try buf.appendSlice(allocator, inst.encMovmskps(dst_r, src_x).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI64x2Bitmask(
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

    // D-461: spill-aware v128 source (stage 0; no scratch XMM used here).
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    try buf.appendSlice(allocator, inst.encMovmskpd(dst_r, src_x).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.5 (i8x16.swizzle) — pop idx (v128), pop v
/// (v128), push v128 with `out[i] = (idx[i] < 16) ? v[idx[i]] :
/// 0`. SSE PSHUFB has different semantics for ctrl bytes in
/// 16..127 (it indexes into src instead of zeroing); cranelift's
/// PADDUSB(0x70) saturating-fixup approach needs a const-pool
/// constant. This handler synthesises the correction inline
/// without const-pool by detecting `idx > 15` via PCMPGTB
/// (signed compare) and OR-ing the high bit into the corrected
/// ctrl. PSHUFB itself handles idx in 128..255 correctly (high
/// bit of ctrl = zero output).
///
/// 10-instruction emit:
///   PCMPEQB XMM14, XMM14            ; XMM14 = 0xFF per byte
///   PSRLW XMM14, 12                  ; XMM14 = 0x000F per word
///                                    ;   (low byte = 0x0F)
///   PXOR XMM15, XMM15                ; XMM15 = zero ctrl
///   PSHUFB XMM14, XMM15              ; XMM14 = 0x0F broadcast
///   MOVAPS XMM15, idx                 ; preserve idx in scratch
///   PCMPGTB XMM15, XMM14              ; XMM15 = (idx > 15) ? 0xFF : 0
///   POR XMM15, idx                    ; XMM15 = idx | mask =
///                                    ;   corrected ctrl (high bit
///                                    ;   set for idx>15 → PSHUFB → 0)
///   MOVAPS dst, v                     ; (skip-elide if dst==v)
///   PSHUFB dst, XMM15                 ; dst = shuffle(v, corrected_idx)
pub fn emitI8x16Swizzle(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const v_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware. f_x=XMM14, c_x=XMM15 internal; dst→home/XMM7. idx is
    // read twice — a home idx is used directly (byte-identical no-spill); a spilled
    // idx loads into c_x for the first read and is reloaded into the now-dead f_x
    // for the POR. v is loaded just-in-time into dst (its only use; dst==idx is safe
    // since idx is read before dst is written).
    const dst_x = try dstHomeOrXmm7Cmp(alloc, result_v);
    const f_x = abi.fp_spill_stage_xmms[0]; // XMM14: 0x0F broadcast, then idx reload
    const c_x = abi.fp_spill_stage_xmms[1]; // XMM15: corrected ctrl
    const idx_reg: ?inst.Xmm = switch (alloc.slot(idx_v, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => null,
    };

    try buf.appendSlice(allocator, inst.encPcmpeqB(f_x, f_x).slice());
    try buf.appendSlice(allocator, inst.encPsrlwImm(f_x, 12).slice());
    try buf.appendSlice(allocator, inst.encPxor(c_x, c_x).slice());
    try buf.appendSlice(allocator, inst.encPshufb(f_x, c_x).slice()); // f_x = 0x0F broadcast
    if (idx_reg) |r| {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(c_x, r).slice());
    } else try loadV128IntoCmp(allocator, buf, alloc, spill_base_off, c_x, idx_v);
    try buf.appendSlice(allocator, inst.encPcmpgtB(c_x, f_x).slice());
    if (idx_reg) |r| {
        try buf.appendSlice(allocator, inst.encPor(c_x, r).slice());
    } else {
        // f_x (0x0F broadcast) is dead after PCMPGTB → reuse it to reload idx.
        try loadV128IntoCmp(allocator, buf, alloc, spill_base_off, f_x, idx_v);
        try buf.appendSlice(allocator, inst.encPor(c_x, f_x).slice());
    }
    try loadV128IntoCmp(allocator, buf, alloc, spill_base_off, dst_x, v_v);
    try buf.appendSlice(allocator, inst.encPshufb(dst_x, c_x).slice());
    try storeV128IfSpilledLocal(allocator, buf, alloc, spill_base_off, result_v);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i*x*.narrow_*_s / _u) — pop two v128, push
/// v128 with each pair of input lanes packed/saturated to a
/// half-width lane. SSE2/SSE4.1 PACK* instructions match the
/// Wasm spec exactly: signed pack saturates to signed half-
/// width range; unsigned pack clamps signed input to unsigned
/// half-width range.
pub fn emitI8x16NarrowI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPacksswb);
}

pub fn emitI8x16NarrowI16x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPackuswb);
}

pub fn emitI16x8NarrowI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPackssdw);
}

pub fn emitI16x8NarrowI32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPackusdw);
}

/// Wasm spec §4.4.4 (i*x*.extend_low / extend_high) — pop one
/// v128, push one v128 with each lane sign- or zero-extended to
/// the wider lane width. SSE4.1 PMOVSX*/PMOVZX* directly handle
/// the LOW half (low 8 bytes / 4 i16 / 2 i32 of src extended).
/// HIGH half: shuffle src's upper 64 bits into the lower 64 via
/// PSHUFD imm=0xEE (selects lanes 2,3,2,3 — upper qword
/// duplicated into both 64-bit halves), then PMOVSX/ZX on the
/// shuffled register.
fn emitV128ExtendLow(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-461: spill-aware src (stage 0 / XMM14) + dst (stage 1 / XMM15) so a spilled
    // v128 operand/result no longer rejects at `resolveXmm`. No internal scratch
    // (PMOVSX/ZX low half) → no stage collision.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    try buf.appendSlice(allocator, encoder(dst_x, src_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

fn emitV128ExtendHigh(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-461: spill-aware src (stage 0 / XMM14) + dst (stage 1 / XMM15). PSHUFD then
    // reads stage-0, writes stage-1, and the encoder reads/writes stage-1 — distinct
    // stage XMMs, so the dst-as-PSHUFD-scratch never collides with the src load.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    // PSHUFD(dst, src, 0xEE): selects src lanes [2,3,2,3] →
    // dst's low 64 = src's upper 64. Then encoder reads low 64
    // of dst (now = src's upper 64) and extends to dst's lanes.
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, src_x, 0xEE).slice());
    try buf.appendSlice(allocator, encoder(dst_x, dst_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI16x8ExtendLowI8x16S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128ExtendLow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovsxbw);
}

pub fn emitI16x8ExtendLowI8x16U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128ExtendLow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovzxbw);
}

pub fn emitI16x8ExtendHighI8x16S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128ExtendHigh(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovsxbw);
}

pub fn emitI16x8ExtendHighI8x16U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128ExtendHigh(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovzxbw);
}

pub fn emitI32x4ExtendLowI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128ExtendLow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovsxwd);
}

pub fn emitI32x4ExtendLowI16x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128ExtendLow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovzxwd);
}

pub fn emitI32x4ExtendHighI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128ExtendHigh(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovsxwd);
}

pub fn emitI32x4ExtendHighI16x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128ExtendHigh(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovzxwd);
}

pub fn emitI64x2ExtendLowI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128ExtendLow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovsxdq);
}

pub fn emitI64x2ExtendLowI32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128ExtendLow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovzxdq);
}

pub fn emitI64x2ExtendHighI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128ExtendHigh(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovsxdq);
}

pub fn emitI64x2ExtendHighI32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128ExtendHigh(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovzxdq);
}

/// Wasm spec §4.4.4 (i*x*.eq variants) — pop two v128, push v128
/// where each lane is all-ones if the inputs match else all-zero.
/// Per-shape encoders (PCMPEQB / PCMPEQW / PCMPEQD / PCMPEQQ)
/// reuse the shared `op_simd.emitV128IntBinop` helper unchanged —
/// equality comparison's structural shape (pop 2, push 1, MOVAPS-
/// elide when aliased) is identical to int add/sub.
pub fn emitI8x16Eq(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqB);
}

pub fn emitI16x8Eq(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqW);
}

pub fn emitI32x4Eq(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqD);
}

pub fn emitI64x2Eq(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return op_simd.emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqQ);
}

/// Wasm spec §4.4.4 (i*x*.ne variants) — invert PCMPEQ via XOR
/// against an all-ones mask. The mask is generated cheaply with
/// `PCMPEQB scratch, scratch` (any width works; byte chosen as
/// shortest encoding) on `abi.fp_spill_stage_xmms[0]` (XMM14).
///
/// Emit sequence (4 instructions plus optional MOVAPS preamble +
/// optional rhs-stash for the `dst==rhs` alias case):
///   MOVAPS xmm7, rhs           ; only when dst!=lhs && dst==rhs
///   MOVAPS dst, lhs            ; only when dst != lhs
///   <PCMPEQ_eq> dst, rhs_op    ; per-shape encoder; rhs_op = xmm7 when stashed
///   PCMPEQB scratch, scratch   ; build all-ones mask
///   PXOR    dst, scratch       ; flip every bit → ne result
///
/// Aliasing safety (D-071 part c-actual; mirrors the D-066 guard
/// already present in `emitV128IntCmpSigned` / `emitV128IntCmpUnsigned`):
/// regalloc's LIFO slot-reuse can place `result_v` in the same
/// physical XMM as `rhs_v`. Naive `MOVAPS dst, lhs` would clobber
/// rhs before PCMPEQ reads it, leaving the comparison to read
/// `lhs ?== lhs` → all-ones, which the trailing PXOR with
/// all-ones flips to all-zeros. Stash through XMM7 (project SIMD
/// scratch) when the alias is detected.
fn emitV128IntNe(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder_eq: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware, mirroring emitV128IntCmpSigned's template (eq is
    // symmetric → base = lhs into dst, cmp = rhs on stage1/XMM15; the D-066 alias
    // dst==rhs is covered by the XMM7 stash). The all-ones inversion uses
    // stage0/XMM14 — free here (cmp on stage1, base went to dst).
    const cmp_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, rhs_v, 1);
    const result_slot = alloc.slot(result_v, .fpr);
    const dst_x: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };
    const base_is_dst = switch (alloc.slot(lhs_v, .fpr)) {
        .reg => |id| (abi.fpSlotToReg(id) orelse return Error.SlotOverflow) == dst_x,
        .spill => false,
    };

    var cmp_for_op = cmp_x;
    if (!base_is_dst and dst_x == cmp_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, cmp_x).slice());
        cmp_for_op = .xmm7;
    }
    switch (alloc.slot(lhs_v, .fpr)) {
        .reg => |id| {
            const base_home = abi.fpSlotToReg(id) orelse return Error.SlotOverflow;
            if (dst_x != base_home) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, base_home).slice());
        },
        .spill => |off| {
            const disp = try gpr.v128SpillDisp(spill_base_off, off);
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(dst_x, disp).slice());
        },
    }
    const ones = abi.fp_spill_stage_xmms[0]; // XMM14 — all-ones scratch
    try buf.appendSlice(allocator, encoder_eq(dst_x, cmp_for_op).slice());
    try buf.appendSlice(allocator, inst.encPcmpeqB(ones, ones).slice());
    try buf.appendSlice(allocator, inst.encPxor(dst_x, ones).slice());

    if (result_slot == .spill) {
        const disp = try gpr.v128SpillDisp(spill_base_off, result_slot.spill);
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16Ne(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntNe(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqB);
}

pub fn emitI16x8Ne(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntNe(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqW);
}

pub fn emitI32x4Ne(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntNe(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqD);
}

pub fn emitI64x2Ne(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    return emitV128IntNe(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqQ);
}

/// Wasm spec §4.4.3 (i8x16.splat) — pop scalar i32, push v128
/// with all 16 byte lanes equal to the low 8 bits of the scalar.
/// x86_64 lowering: `MOVD xmm_dst, src_gpr` (zero-extends to
/// 128) — places `src8` in byte 0 with the rest cleared. Then
/// `PXOR scratch, scratch` (build all-zero PSHUFB control mask)
/// + `PSHUFB xmm_dst, scratch` — PSHUFB reads each control byte's
/// low 4 bits as a source-lane index; an all-zero ctrl makes
/// every output byte = source byte 0 = `src8`.
///
/// **Scratch reuse**: borrows `abi.fp_spill_stage_xmms[0]` as
/// the zero ctrl mask (mirrors the i64x2.mul scratch
/// strategy). Safe — the handler is atomic; no nested
/// `xmmLoadSpilled` intervenes.
pub fn emitI8x16Splat(
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

    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    // D-461: spill-aware v128 dst on STAGE1/XMM15 — the PSHUFB zero-ctrl mask
    // scratch occupies stage0/XMM14, so the dst must not alias it (LANDMINE).
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const ctrl = abi.fp_spill_stage_xmms[0]; // XMM14 — zero ctrl mask scratch

    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst_x, src_r).slice());
    try buf.appendSlice(allocator, inst.encPxor(ctrl, ctrl).slice());
    try buf.appendSlice(allocator, inst.encPshufb(dst_x, ctrl).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (i16x8.splat) — pop scalar i32, push v128
/// with 8 word lanes equal to the low 16 bits of the scalar.
/// Lowering: `MOVD xmm_dst, src_gpr` (low 32 bits of XMM = src,
/// rest zeroed) → `PSHUFLW xmm_dst, xmm_dst, 0x00` (broadcasts
/// word 0 to lanes 0-3 of the lower 64) → `PSHUFD xmm_dst,
/// xmm_dst, 0x00` (broadcasts dword 0 across all 4 dwords,
/// filling the upper 64 bits).
pub fn emitI16x8Splat(
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

    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    // D-461: spill-aware v128 dst. No internal XMM scratch (movd+pshuflw+
    // pshufd), so the dst safely uses stage0/XMM14.
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);

    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst_x, src_r).slice());
    try buf.appendSlice(allocator, inst.encPshuflw(dst_x, dst_x, 0x00).slice());
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, dst_x, 0x00).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (i64x2.splat) — pop scalar i64, push v128
/// with both 64-bit lanes equal to the scalar. Lowering: `MOVQ
/// xmm_dst, src_gpr` (zero-extends i64 into the low 64 bits;
/// upper 64 cleared) → `PUNPCKLQDQ xmm_dst, xmm_dst` (unpacks
/// low qwords from both operands — same XMM here — producing
/// `(src64, src64)`).
pub fn emitI64x2Splat(
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

    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    // D-461: spill-aware v128 dst. No internal XMM scratch (movq+punpcklqdq),
    // so the dst safely uses stage0/XMM14.
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);

    try buf.appendSlice(allocator, inst.encMovqXmmFromR64(dst_x, src_r).slice());
    try buf.appendSlice(allocator, inst.encPunpcklqdq(dst_x, dst_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (i8x16 / i16x8 extract_lane variants) — pop
/// v128, push i32. PEXTRB / PEXTRW write the byte/word lane into
/// the destination GPR's low 8/16 bits zero-extended to 32 bits.
/// `i*.extract_lane_u` accepts that result directly; `_s` follows
/// up with `MOVSX r32, r8` / `MOVSX r32, r16` to sign-extend.
const NarrowExtractKind = enum { i8x16_s, i8x16_u, i16x8_s, i16x8_u };

fn emitV128IntExtractLaneNarrow(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
    kind: NarrowExtractKind,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-461: spill-aware v128 source (was resolveXmm-reject), same single-source
    // shape as the tested i32x4.extract_lane. Covers i8x16/i16x8 extract_lane s/u.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    switch (kind) {
        .i8x16_s, .i8x16_u => {
            const lane: u4 = @intCast(payload & 0xF);
            try buf.appendSlice(allocator, inst.encPextrB(dst_r, src_x, lane).slice());
            if (kind == .i8x16_s) {
                try buf.appendSlice(allocator, inst.encMovsxR32R8(dst_r, dst_r).slice());
            }
        },
        .i16x8_s, .i16x8_u => {
            const lane: u3 = @intCast(payload & 0b111);
            try buf.appendSlice(allocator, inst.encPextrW(dst_r, src_x, lane).slice());
            if (kind == .i16x8_s) {
                try buf.appendSlice(allocator, inst.encMovsxR32R16(dst_r, dst_r).slice());
            }
        },
    }
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16ExtractLaneS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntExtractLaneNarrow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, .i8x16_s);
}

pub fn emitI8x16ExtractLaneU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntExtractLaneNarrow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, .i8x16_u);
}

pub fn emitI16x8ExtractLaneS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntExtractLaneNarrow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, .i16x8_s);
}

pub fn emitI16x8ExtractLaneU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntExtractLaneNarrow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, .i16x8_u);
}

/// Wasm spec §4.4.3 (i8x16 / i16x8 replace_lane) — pop scalar
/// (i32, treated as i8/i16 by truncation), pop v128, push v128
/// with the lane updated. `MOVAPS dst, vec` (elided when aliased)
/// + `PINSRB / PINSRW dst, value, lane`.
const NarrowReplaceKind = enum { i8x16, i16x8 };

fn emitV128IntReplaceLaneNarrow(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
    kind: NarrowReplaceKind,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const value_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const value_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, value_v, 0);
    // D-461: spill-aware v128 vec-read (stage0/XMM14) + dst-write (stage1/XMM15).
    // PINSR uses the GPR `value_r`, so no internal XMM scratch — stages never
    // collide (same shape as load_lane).
    const vec_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, vec_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);

    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    switch (kind) {
        .i8x16 => {
            const lane: u4 = @intCast(payload & 0xF);
            try buf.appendSlice(allocator, inst.encPinsrB(dst_x, value_r, lane).slice());
        },
        .i16x8 => {
            const lane: u3 = @intCast(payload & 0b111);
            try buf.appendSlice(allocator, inst.encPinsrW(dst_x, value_r, lane).slice());
        },
    }
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16ReplaceLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntReplaceLaneNarrow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, .i8x16);
}

pub fn emitI16x8ReplaceLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntReplaceLaneNarrow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, .i16x8);
}

/// Wasm spec §4.4.3 (i32x4.replace_lane <imm>) — pop scalar i32
/// `value`, pop v128 `vec`; push a v128 with lane `imm` set to
/// `value` and the other three lanes preserved from `vec`.
/// x86_64 lowering: copy `vec` into `dst` via MOVAPS (elided
/// when dst already aliases vec), then `PINSRD dst, value, lane`.
fn emitV128IntReplaceLane32Or64(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
    is_64: bool,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const value_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const value_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, value_v, 0);
    // D-461: spill-aware v128 vec-read (stage0) + dst-write (stage1); PINSR uses
    // the GPR value_r, so no internal XMM scratch (same shape as load_lane).
    const vec_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, vec_v, 0);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);

    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    if (is_64) {
        const lane: u1 = @intCast(payload & 0b1);
        try buf.appendSlice(allocator, inst.encPinsrQ(dst_x, value_r, lane).slice());
    } else {
        const lane: u2 = @intCast(payload & 0b11);
        try buf.appendSlice(allocator, inst.encPinsrD(dst_x, value_r, lane).slice());
    }
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI32x4ReplaceLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntReplaceLane32Or64(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, false);
}

pub fn emitI64x2ReplaceLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntReplaceLane32Or64(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, true);
}

/// Wasm spec §4.4.4 (i16x8.extmul_low_i8x16_{s,u}) — extend low 8
/// i8 lanes of each operand to i16 then multiply pairwise. 3-instr
/// recipe per cranelift `lower.isle:1197-1285`: PMOVSX/ZX BW on
/// each operand into XMM14 + dst, then PMULLW.
fn emitV128IntExtmulLow(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder_extend: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    encoder_mul: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware. lhs is extended into tmp=XMM14 (consumed before dst
    // is touched), rhs is extended into dst — the in-place PMOVSX/ZX make dst==rhs
    // safe, so no aliasing stash is needed. A spilled lhs/rhs loads into stage1/
    // XMM15 (reused: lhs is dead once in XMM14 before rhs loads); dst → home/XMM7.
    const dst_x: inst.Xmm = switch (alloc.slot(result_v, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };
    const tmp = abi.fp_spill_stage_xmms[0]; // XMM14
    const lhs_x = try resolveOrLoadV128(allocator, buf, alloc, spill_base_off, lhs_v, abi.fp_spill_stage_xmms[1]);
    try buf.appendSlice(allocator, encoder_extend(tmp, lhs_x).slice());
    const rhs_x = try resolveOrLoadV128(allocator, buf, alloc, spill_base_off, rhs_v, abi.fp_spill_stage_xmms[1]);
    try buf.appendSlice(allocator, encoder_extend(dst_x, rhs_x).slice());
    try buf.appendSlice(allocator, encoder_mul(dst_x, tmp).slice());
    try storeV128IfSpilledLocal(allocator, buf, alloc, spill_base_off, result_v);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i16x8.extmul_high_i8x16_{s,u}) — like extmul_low
/// but operates on the HIGH half of each i8x16. 5-instr recipe:
/// PSHUFD imm=0xEE on each operand to swap high→low into scratches,
/// then PMOVSX/ZX BW + PMULLW.
fn emitV128IntExtmulHigh(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder_extend: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    encoder_mul: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): both stages (t1=XMM14, t2=XMM15) are internal PSHUFD scratch, so a
    // spilled operand can't use a stage as its load reg. Instead dst doubles as the
    // load temp: each operand is loaded into dst, PSHUFD'd into its stage, and is
    // dead before dst is written as the result — so dst==lhs/rhs aliases are safe
    // and the no-spill emit (operands in home regs → no load) stays byte-identical.
    const t1 = abi.fp_spill_stage_xmms[0]; // XMM14
    const t2 = abi.fp_spill_stage_xmms[1]; // XMM15
    const dst_x: inst.Xmm = switch (alloc.slot(result_v, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };
    const lhs_x = try resolveOrLoadV128(allocator, buf, alloc, spill_base_off, lhs_v, dst_x);
    try buf.appendSlice(allocator, inst.encPshufd(t1, lhs_x, 0xEE).slice());
    const rhs_x = try resolveOrLoadV128(allocator, buf, alloc, spill_base_off, rhs_v, dst_x);
    try buf.appendSlice(allocator, inst.encPshufd(t2, rhs_x, 0xEE).slice());
    try buf.appendSlice(allocator, encoder_extend(t1, t1).slice());
    try buf.appendSlice(allocator, encoder_extend(dst_x, t2).slice());
    try buf.appendSlice(allocator, encoder_mul(dst_x, t1).slice());
    try storeV128IfSpilledLocal(allocator, buf, alloc, spill_base_off, result_v);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI16x8ExtmulLowI8x16S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntExtmulLow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovsxbw, inst.encPmullW);
}

pub fn emitI16x8ExtmulHighI8x16S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntExtmulHigh(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovsxbw, inst.encPmullW);
}

pub fn emitI16x8ExtmulLowI8x16U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntExtmulLow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovzxbw, inst.encPmullW);
}

pub fn emitI16x8ExtmulHighI8x16U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntExtmulHigh(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovzxbw, inst.encPmullW);
}

pub fn emitI32x4ExtmulLowI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntExtmulLow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovsxwd, inst.encPmullD);
}

pub fn emitI32x4ExtmulHighI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntExtmulHigh(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovsxwd, inst.encPmullD);
}

pub fn emitI32x4ExtmulLowI16x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntExtmulLow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovzxwd, inst.encPmullD);
}

pub fn emitI32x4ExtmulHighI16x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntExtmulHigh(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPmovzxwd, inst.encPmullD);
}

/// Wasm spec §4.4.4 (i64x2.extmul_{low,high}_i32x4_{s,u}) —
/// distinct shape from i16x8/i32x4 extmul because PMULDQ /
/// PMULUDQ already widen i32→i64; no separate extend needed.
/// Recipe: PSHUFD imm to position the source lanes (0x50 for
/// low half: lanes 0/1 → slots 0/2; 0xFA for high half: lanes
/// 2/3 → slots 0/2), then PMULDQ (signed) or PMULUDQ (unsigned).
/// 3-instr inline.
fn emitV128I64x2Extmul(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    pshufd_imm: u8,
    encoder_mul: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware. lhs→dst (PSHUFD), rhs→tmp=XMM14 (PSHUFD); a spilled
    // operand loads via stage1/XMM15 (lhs is consumed into dst before rhs loads).
    // dst → home or XMM7. The dst==rhs alias is not handled (matches the original's
    // documented stance — the deterministic regalloc gives result a fresh slot).
    const dst_x: inst.Xmm = switch (alloc.slot(result_v, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };
    const tmp = abi.fp_spill_stage_xmms[0]; // XMM14
    const lhs_x = try resolveOrLoadV128(allocator, buf, alloc, spill_base_off, lhs_v, abi.fp_spill_stage_xmms[1]);
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, lhs_x, pshufd_imm).slice());
    const rhs_x = try resolveOrLoadV128(allocator, buf, alloc, spill_base_off, rhs_v, abi.fp_spill_stage_xmms[1]);
    try buf.appendSlice(allocator, inst.encPshufd(tmp, rhs_x, pshufd_imm).slice());
    try buf.appendSlice(allocator, encoder_mul(dst_x, tmp).slice());
    try storeV128IfSpilledLocal(allocator, buf, alloc, spill_base_off, result_v);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI64x2ExtmulLowI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128I64x2Extmul(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, 0x50, inst.encPmuldq);
}

pub fn emitI64x2ExtmulHighI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128I64x2Extmul(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, 0xFA, inst.encPmuldq);
}

pub fn emitI64x2ExtmulLowI32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128I64x2Extmul(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, 0x50, inst.encPmuludq);
}

pub fn emitI64x2ExtmulHighI32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128I64x2Extmul(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, 0xFA, inst.encPmuludq);
}

/// Wasm spec §4.4.4 (i16x8.extadd_pairwise_i8x16_u) — pairwise-
/// add adjacent unsigned i8 lanes, widening to i16. PMADDUBSW
/// (SSSE3) computes saturating dot product where the first
/// operand is read as unsigned bytes and the second as signed
/// bytes; with a +1 vector as the signed operand, this reduces
/// to plain pairwise-add. Synthesise the +1 vector inline via
/// PCMPEQB ones + PABSB → 0x01 per byte (no const-pool dep).
/// 4-instr recipe.
pub fn emitI16x8ExtaddPairwiseI8x16U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-461: spill-aware src+dst on STAGE1 (XMM15) — XMM14 (stage0) is the const scratch.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 1);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const tmp = abi.fp_spill_stage_xmms[0]; // XMM14

    // 1-2: tmp = 0x01 per byte (signed +1).
    try buf.appendSlice(allocator, inst.encPcmpeqB(tmp, tmp).slice());
    try buf.appendSlice(allocator, inst.encPabsb(tmp, tmp).slice());
    // 3-4: dst = src (unsigned bytes); PMADDUBSW dst, tmp →
    // result_word = u8(src[2i]) * 1 + u8(src[2i+1]) * 1.
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPmaddubsw(dst_x, tmp).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i32x4.extadd_pairwise_i16x8_s) — pairwise-
/// add adjacent signed i16 lanes, widening to i32. PMADDWD (SSE2)
/// computes pairwise dot product of i16 lanes; with +1-per-i16
/// as one operand it reduces to plain pairwise add. Synthesise
/// the 0x00010001-per-dword (= +1 per word) mask inline via
/// PCMPEQB ones + PSRLW imm 15 → 0x0001 per word. 4-instr recipe;
/// no const-pool dep. The _u variant cannot use the same recipe
/// (PMADDWD reads operands as signed i16, treating high u16 lanes
/// as negative) — deferred to a later chunk pending ADR-0042.
pub fn emitI32x4ExtaddPairwiseI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-461: spill-aware src+dst on STAGE1 (XMM15) — XMM14 (stage0) is the const scratch.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 1);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const tmp = abi.fp_spill_stage_xmms[0]; // XMM14

    // 1-2: tmp = 0x0001 per word (= +1 per i16 lane).
    try buf.appendSlice(allocator, inst.encPcmpeqB(tmp, tmp).slice());
    try buf.appendSlice(allocator, inst.encPsrlwImm(tmp, 15).slice());
    // 3-4: dst = src; PMADDWD dst, tmp computes adjacent pairs of
    // src's i16 lanes summed (multiplied by +1) into i32 lanes.
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPmaddwd(dst_x, tmp).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.5 (i8x16.shuffle) — pop 2 v128 (lhs, rhs), push
/// v128 result whose i-th byte = src[mask[i]] for mask[i] in 0..31
/// (lhs supplies indices 0..15, rhs supplies 16..31).
///
/// Recipe per cranelift `lower.isle:4710+`:
///   PSHUFB(src1, a_mask) | PSHUFB(src2, b_mask)
/// where a_mask[i] = mask[i]  if mask[i] < 16 else 0x80
///       b_mask[i] = mask[i]-16 if mask[i] >= 16 else 0x80.
/// PSHUFB writes 0 to a lane when its control byte's bit 7 is set
/// (= 0x80), so each side contributes only its valid lanes; POR
/// merges them.
///
/// 9-instr recipe (incl. 2 MOVUPS-RIP-rel const loads for derived
/// masks): 2 derived masks per call site, appended to extra_consts
/// (no dedup since masks are per-instance).
pub fn emitI8x16Shuffle(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    simd_const_fixups: *std.ArrayList(@import("types.zig").SimdConstFixup),
    extra_consts: *std.ArrayList([16]u8),
    simd_consts_base: u32,
    simd_consts: ?[]const [16]u8,
    const_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const consts = simd_consts orelse return Error.AllocationMissing;
    if (const_idx >= consts.len) return Error.AllocationMissing;
    const mask = consts[const_idx];

    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-034 (g): spill-aware. t1=XMM14, t2=XMM15 internal; dst→home/XMM7. lhs is
    // loaded just-in-time into dst; rhs is read once into t2 — a home rhs is used
    // directly, the D-066 dst==rhs alias stashes rhs→XMM7 (dst home → XMM7 free),
    // a spilled rhs reloads from its slot into t2.
    const dst_x = try dstHomeOrXmm7Cmp(alloc, result_v);
    const t1 = abi.fp_spill_stage_xmms[0]; // XMM14 — mask register
    const t2 = abi.fp_spill_stage_xmms[1]; // XMM15 — src2 PSHUFB result
    const rhs_reg: ?inst.Xmm = switch (alloc.slot(rhs_v, .fpr)) {
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

    // Derive a_mask + b_mask from the original Wasm mask. PSHUFB's
    // bit-7 = "zero output" semantics handles the cross-source
    // selection without a separate compare.
    var a_mask: [16]u8 = undefined;
    var b_mask: [16]u8 = undefined;
    for (mask, 0..) |m, i| {
        a_mask[i] = if (m < 16) m else 0x80;
        b_mask[i] = if (m >= 16 and m < 32) m - 16 else 0x80;
    }
    // Per-instance — append unconditionally (no dedup; future
    // instances of i8x16.shuffle land their own pair).
    const a_idx: u32 = simd_consts_base + @as(u32, @intCast(extra_consts.items.len));
    try extra_consts.append(allocator, a_mask);
    const b_idx: u32 = simd_consts_base + @as(u32, @intCast(extra_consts.items.len));
    try extra_consts.append(allocator, b_mask);

    // 1: t1 = a_mask.
    try op_simd.emitConstLoad(allocator, buf, simd_const_fixups, t1, a_idx);
    // 2: dst = lhs (just-in-time; clobbers a spilled-rhs slot? no — rhs reloads
    // from its own slot / the XMM7 stash already taken above for the dst==rhs alias).
    try loadV128IntoCmp(allocator, buf, alloc, spill_base_off, dst_x, lhs_v);
    // 3: PSHUFB dst, t1 → dst = lhs[a_mask] (zeros where a_mask
    // had bit 7 set = lanes that selected from rhs).
    try buf.appendSlice(allocator, inst.encPshufb(dst_x, t1).slice());
    // 4: t1 = b_mask.
    try op_simd.emitConstLoad(allocator, buf, simd_const_fixups, t1, b_idx);
    // 5: t2 = rhs (home reg / XMM7 stash, or reloaded from its slot).
    if (rhs_reg) |r| {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(t2, r).slice());
    } else try loadV128IntoCmp(allocator, buf, alloc, spill_base_off, t2, rhs_v);
    // 6: PSHUFB t2, t1 → t2 = rhs[b_mask] (zeros where b_mask had
    // bit 7 set = lanes that selected from lhs).
    try buf.appendSlice(allocator, inst.encPshufb(t2, t1).slice());
    // 7: dst = dst | t2 → merge the two halves.
    try buf.appendSlice(allocator, inst.encPor(dst_x, t2).slice());
    try storeV128IfSpilledLocal(allocator, buf, alloc, spill_base_off, result_v);

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i32x4.extadd_pairwise_i16x8_u) — pairwise-
/// add adjacent unsigned i16 lanes, widening to i32. PMADDWD
/// reads operands as signed i16 so we sign-flip src first
/// (XOR with 0x8000-per-word converts u16 → signed i16 in
/// [-0x8000, 0x7FFF]), pairwise-multiply with +1, then add a
/// per-i32-lane correction (0x00010000 = 65536) to undo the
/// 2*0x8000 = 0x10000 bias introduced by sign-flipping each pair.
///
/// 11-instr inline recipe (no const-pool dep):
/// 1-2: t1 = 0x8000-per-word    (PCMPEQB ones + PSLLW imm 15)
/// 3-4: dst = src XOR t1         (sign-flip; MOVAPS + PXOR)
/// 5-6: t1 = 0x0001-per-word    (PCMPEQB ones + PSRLW imm 15)
/// 7  : PMADDWD dst, t1          (pairwise sum into i32)
/// 8-10: t1 = 0x00010000-per-dword (PCMPEQB + PSRLD 31 + PSLLD 16)
/// 11 : PADDD dst, t1            (correction: + 0x10000 per i32)
pub fn emitI32x4ExtaddPairwiseI16x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-461: spill-aware src+dst on STAGE1 (XMM15) — XMM14 (stage0) is the const scratch.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 1);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const t1 = abi.fp_spill_stage_xmms[0]; // XMM14

    // 1-2: t1 = 0x8000-per-word (sign-flip mask).
    try buf.appendSlice(allocator, inst.encPcmpeqB(t1, t1).slice());
    try buf.appendSlice(allocator, inst.encPsllwImm(t1, 15).slice());
    // 3-4: dst = src XOR t1 (u16 → signed i16 via 2's-complement bias).
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPxor(dst_x, t1).slice());
    // 5-6: t1 = 0x0001-per-word (+1 mask for PMADDWD).
    try buf.appendSlice(allocator, inst.encPcmpeqB(t1, t1).slice());
    try buf.appendSlice(allocator, inst.encPsrlwImm(t1, 15).slice());
    // 7: PMADDWD dst, t1 → pairs of (i16+i16) sums in i32 lanes.
    try buf.appendSlice(allocator, inst.encPmaddwd(dst_x, t1).slice());
    // 8-10: t1 = 0x00010000-per-dword (correction; + 0x10000 per i32 to
    // undo the 2*0x8000 = 0x10000 bias from sign-flipping each pair).
    try buf.appendSlice(allocator, inst.encPcmpeqB(t1, t1).slice());
    try buf.appendSlice(allocator, inst.encPsrldImm(t1, 31).slice());
    try buf.appendSlice(allocator, inst.encPslldImm(t1, 16).slice());
    // 11: PADDD dst, t1 → recover the original (u16+u16) sum per i32.
    try buf.appendSlice(allocator, inst.encPaddD(dst_x, t1).slice());

    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i16x8.extadd_pairwise_i8x16_s) — pairwise-
/// add adjacent signed i8 lanes, widening to i16. Same PMADDUBSW
/// recipe as the unsigned variant but with operand roles swapped:
/// the +1 vector goes into the unsigned slot (dst) so PMADDUBSW
/// reads the source's signed bytes correctly.
///
/// The +1 constant is built in a scratch (XMM14), NOT directly in
/// dst: regalloc's LIFO slot-reuse can alias `dst == src` for a
/// 1-pop op (src dies here, its slot reused for the result).
/// Building 0x01 straight into dst via PCMPEQB(dst,dst) would then
/// clobber src before PMADDUBSW reads it — yielding 1*1+1*1 = 2
/// per lane instead of the pairwise byte sum. Stash src through
/// XMM7 on the alias path (D-066 / D-071 mirror; the `_u` variant
/// already keeps its constant out of dst, so it was never hit).
/// 4-instr recipe (+1 MOVAPS stash on the alias case).
pub fn emitI16x8ExtaddPairwiseI8x16S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // D-461: spill-aware src+dst on STAGE1 (XMM15) — XMM14 (stage0) is the const scratch.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 1);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const ones = abi.fp_spill_stage_xmms[0]; // XMM14 — 0x01-per-byte

    // 1-2: ones = 0x01 per byte (read as unsigned 1 by PMADDUBSW).
    try buf.appendSlice(allocator, inst.encPcmpeqB(ones, ones).slice());
    try buf.appendSlice(allocator, inst.encPabsb(ones, ones).slice());
    // 3: dst = ones (the unsigned operand). When dst aliases src,
    // stash src through XMM7 first so PMADDUBSW still sees the
    // original signed bytes.
    var src_for_op = src_x;
    if (dst_x == src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, src_x).slice());
        src_for_op = .xmm7;
    }
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, ones).slice());
    // 4: PMADDUBSW dst, src — result_word = unsigned(1)*signed(b0)
    // + unsigned(1)*signed(b1) = i8 + i8 (sign-extended sum).
    try buf.appendSlice(allocator, inst.encPmaddubsw(dst_x, src_for_op).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}
