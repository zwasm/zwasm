//! Byte-level tests for x86_64 V128 SIMD op handlers — V128
//! memory + bitwise + bitselect family. Extracted from a
//! 4-way split of `op_simd_test.zig` per ADR-0054. Sibling test
//! files (`op_simd_int_arith_test.zig`,
//! `op_simd_int_cmp_lane_test.zig`, `op_simd_float_test.zig`)
//! cover the per-class handlers.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");
const testing = std.testing;

const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const types = @import("types.zig");
const op_simd = @import("op_simd.zig");

const Error = types.Error;

test "emitV128Not: 3-instr unary synthesis (MOVAPS + PCMPEQB + PXOR)" {
    var slot_ids = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 2,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    try op_simd.emitV128Not(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm9, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitV128And: dispatches to PAND via emitV128IntBinop" {
    var slot_ids = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 3,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try op_simd.emitV128And(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPand(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitV128Andnot: PANDN via MOVAPS dst,rhs + PANDN dst,lhs" {
    var slot_ids = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 3,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0); // lhs (a)
    try pushed.append(testing.allocator, 1); // rhs (b)
    var next_vreg: u32 = 2;

    try op_simd.emitV128Andnot(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // dst = MOVAPS rhs (= XMM9, b); dst = PANDN(dst, lhs=XMM8) = ~b & a.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPandn(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitV128Bitselect: 5-instr PAND/PANDN/POR chain" {
    var slot_ids = [_]u16{ 0, 1, 2, 3 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 4,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0); // a
    try pushed.append(testing.allocator, 1); // b
    try pushed.append(testing.allocator, 2); // c (top)
    var next_vreg: u32 = 3;

    try op_simd.emitV128Bitselect(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const scratch = abi.fp_spill_stage_xmms[0];
    // dst (XMM11) = MOVAPS a (XMM8) ; PAND dst, c (XMM10)
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm11, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPand(.xmm11, .xmm10).slice());
    // scratch = MOVAPS c ; PANDN scratch, b
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch, .xmm10).slice());
    try expected.appendSlice(testing.allocator, inst.encPandn(scratch, .xmm9).slice());
    // dst = POR(dst, scratch)
    try expected.appendSlice(testing.allocator, inst.encPor(.xmm11, scratch).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}
