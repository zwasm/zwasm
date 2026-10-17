// FILE-SIZE-EXEMPT: SIMD int-cmp/lane per-op test catalog; P2 pure-data dominance (per ADR-0099)
//! Byte-level tests for x86_64 SIMD int-cmp/lane op handlers.
//! Mirror of `op_simd_int_cmp_lane.zig` per ADR-0054 §"Naming
//! convention" (4-way mirror split with `<source>_test.zig`
//! suffix). Extracted from `op_simd_test.zig`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");
const testing = std.testing;

const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const types = @import("types.zig");
const op_simd_int_cmp_lane = @import("op_simd_int_cmp_lane.zig");

const Error = types.Error;

test "emitI32x4GtS: direct PCMPGT (no NOT, no swap) — MOVAPS + PCMPGTD" {
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

    try op_simd_int_cmp_lane.emitI32x4GtS(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtD(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8LtS: operand-swap path — MOVAPS dst, rhs + PCMPGTW dst, lhs" {
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
    try pushed.append(testing.allocator, 0); // lhs
    try pushed.append(testing.allocator, 1); // rhs
    var next_vreg: u32 = 2;

    try op_simd_int_cmp_lane.emitI16x8LtS(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // Swap: base=rhs (XMM9 → MOVAPS into dst XMM10), cmp=lhs (XMM8).
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtW(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI8x16LeS: gt + NOT (PCMPEQB scratch + PXOR)" {
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

    try op_simd_int_cmp_lane.emitI8x16LeS(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtB(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4GeS: lt + NOT (operand swap then NOT)" {
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

    try op_simd_int_cmp_lane.emitI32x4GeS(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    // ge: swap(rhs, lhs) → MOVAPS dst, rhs (XMM9) + PCMPGTD dst, lhs (XMM8) + NOT.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtD(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2GtS: direct PCMPGTQ (SSE4.2) — MOVAPS + PCMPGTQ" {
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

    try op_simd_int_cmp_lane.emitI64x2GtS(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtQ(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2LtS: operand-swap path — MOVAPS dst, rhs + PCMPGTQ dst, lhs" {
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
    try pushed.append(testing.allocator, 0); // lhs
    try pushed.append(testing.allocator, 1); // rhs
    var next_vreg: u32 = 2;

    try op_simd_int_cmp_lane.emitI64x2LtS(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // lt: swap → base=rhs (XMM9 → MOVAPS into dst XMM10), cmp=lhs (XMM8).
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtQ(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2LeS: gt + NOT (PCMPGTQ + PCMPEQB ones + PXOR)" {
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

    try op_simd_int_cmp_lane.emitI64x2LeS(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtQ(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI8x16GtU: PMAXUB + PCMPEQB rhs + PXOR all-ones (gt path)" {
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

    try op_simd_int_cmp_lane.emitI8x16GtU(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaxub(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8LtU: PMINUW + PCMPEQW rhs + PXOR all-ones (lt path)" {
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

    try op_simd_int_cmp_lane.emitI16x8LtU(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPminuw(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqW(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4LeU: PMINUD + PCMPEQD lhs (le path, no NOT)" {
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

    try op_simd_int_cmp_lane.emitI32x4LeU(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // dst = lhs ; dst = PMINUD(dst, rhs) ; dst = PCMPEQD(dst, lhs)
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPminud(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqD(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4GeU: PMAXUD + PCMPEQD lhs (ge path, no NOT)" {
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

    try op_simd_int_cmp_lane.emitI32x4GeU(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaxud(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqD(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

// D-071 part (c): IntCmpUnsigned `.ge/.le` reads `lhs_x` after the
// min/max overwrites dst. When regalloc's LIFO slot-reuse aliases
// `dst == lhs`, the `MOVAPS dst, lhs` is elided (correctly) but the
// final `PCMPEQ dst, lhs` then reads dst-after-min/max, which is no
// longer the original lhs. Stash lhs through XMM7 (project SIMD
// scratch) before the min/max.
test "emitI8x16GeU: dst aliases lhs — stash lhs to XMM7 before PMAXUB" {
    var slot_ids = [_]u16{ 0, 1, 0 }; // vreg 0 → XMM8, vreg 1 → XMM9, vreg 2 (result) → XMM8 (== lhs)
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

    try op_simd_int_cmp_lane.emitI8x16GeU(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // MOVAPS xmm7, xmm8 (stash lhs). MOVAPS dst, lhs elided. PMAXUB
    // xmm8, xmm9. PCMPEQB xmm8, xmm7 (original lhs from stash).
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm7, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaxub(.xmm8, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm8, .xmm7).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8LeU: dst aliases lhs — stash lhs to XMM7 before PMINUW" {
    var slot_ids = [_]u16{ 0, 1, 0 };
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

    try op_simd_int_cmp_lane.emitI16x8LeU(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm7, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPminuw(.xmm8, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqW(.xmm8, .xmm7).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI8x16AllTrue: 5-instr SSE4.1 PTEST recipe (PXOR + PCMPEQB + PTEST + SETZ + MOVZX)" {
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

    try op_simd_int_cmp_lane.emitI8x16AllTrue(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const scratch = abi.fp_spill_stage_xmms[0]; // XMM14
    try expected.appendSlice(testing.allocator, inst.encPxor(scratch, scratch).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(scratch, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPtest(scratch, scratch).slice());
    // dst_r = result vreg slot 1 → first allocatable GPR reg post-spill (depends on
    // alloc impl). Just check that the expected emit completes successfully without
    // attempting to enumerate the GPR — the byte-for-byte test would need the actual
    // allocated GPR slot. Trim the test to just assert the prefix matches via
    // expectEqual on the first 3 instructions' length.
    try testing.expect(buf.items.len > expected.items.len);
    try testing.expectEqualSlices(u8, expected.items, buf.items[0..expected.items.len]);
}

test "emitI8x16Bitmask: PMOVMSKB direct (1 instr)" {
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

    try op_simd_int_cmp_lane.emitI8x16Bitmask(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    // First instruction should be PMOVMSKB; subsequent instructions
    // depend on the spill-store mechanics for the i32 result. PMOVMSKB
    // bytes: 66 [REX?] 0F D7 ModRM. Skip REX (if present) when checking
    // 0F D7; first byte is always 0x66 prefix.
    try testing.expect(buf.items.len >= 4);
    try testing.expectEqual(@as(u8, 0x66), buf.items[0]);
    const after_prefix = if ((buf.items[1] & 0xF0) == 0x40) buf.items[2..] else buf.items[1..];
    try testing.expectEqual(@as(u8, 0x0F), after_prefix[0]);
    try testing.expectEqual(@as(u8, 0xD7), after_prefix[1]);
}

test "emitI64x2GeS: lt + NOT (operand swap then NOT)" {
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

    try op_simd_int_cmp_lane.emitI64x2GeS(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    // ge: swap(rhs, lhs) → MOVAPS dst, rhs (XMM9) + PCMPGTQ dst, lhs (XMM8) + NOT.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtQ(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4Eq: dispatches to encPcmpeqD via shared helper" {
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

    try op_simd_int_cmp_lane.emitI32x4Eq(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqD(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI8x16Ne: PCMPEQB + all-ones-mask + PXOR (4-instr sequence)" {
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

    try op_simd_int_cmp_lane.emitI8x16Ne(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2Ne: dispatches to PCMPEQQ (SSE4.1 0x29)" {
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

    try op_simd_int_cmp_lane.emitI64x2Ne(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqQ(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

// D-071 part c (actual): IntNe lacked the dst==rhs alias guard that
// IntCmpSigned / IntCmpUnsigned already carry. When regalloc's LIFO
// slot-reuse aliases `dst == rhs` (and dst != lhs), the unguarded
// `MOVAPS dst, lhs` clobbers rhs before `PCMPEQ dst, rhs` reads it,
// leaving PCMPEQ to compare lhs with itself → all-ones, which the
// trailing PXOR with all-ones flips to all-zeros (the symptom seen
// in simd_i16x8_cmp / simd_i32x4_cmp `ne` fixtures on OrbStack
// x86_64). Stash rhs through XMM7 (project SIMD scratch).
test "emitI16x8Ne: dst aliases rhs — stash rhs to XMM7 before PCMPEQW (D-071 part c-actual)" {
    var slot_ids = [_]u16{ 0, 1, 1 }; // result vreg 2 → XMM9 (== rhs).
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

    try op_simd_int_cmp_lane.emitI16x8Ne(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    // Stash rhs (XMM9) to XMM7, then MOVAPS dst, lhs, PCMPEQW dst,
    // xmm7 (original rhs), build all-ones mask, PXOR to invert.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm7, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqW(.xmm9, .xmm7).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm9, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI8x16Splat: MOVD + PXOR + PSHUFB sequence" {
    var slot_ids = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    try op_simd_int_cmp_lane.emitI8x16Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ctrl = abi.fp_spill_stage_xmms[0]; // XMM14
    try expected.appendSlice(testing.allocator, inst.encMovdXmmFromR32(.xmm8, .rbx).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(ctrl, ctrl).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufb(.xmm8, ctrl).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8Splat: MOVD + PSHUFLW + PSHUFD sequence" {
    var slot_ids = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    try op_simd_int_cmp_lane.emitI16x8Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovdXmmFromR32(.xmm8, .rbx).slice());
    try expected.appendSlice(testing.allocator, inst.encPshuflw(.xmm8, .xmm8, 0x00).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm8, .xmm8, 0x00).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2Splat: MOVQ + PUNPCKLQDQ sequence" {
    var slot_ids = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    try op_simd_int_cmp_lane.emitI64x2Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovqXmmFromR64(.xmm8, .rbx).slice());
    try expected.appendSlice(testing.allocator, inst.encPunpcklqdq(.xmm8, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI8x16ExtractLaneS: PEXTRB + MOVSX r32, r8" {
    var slot_ids = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    try op_simd_int_cmp_lane.emitI8x16ExtractLaneS(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 7);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPextrB(.rbx, .xmm8, 7).slice());
    try expected.appendSlice(testing.allocator, inst.encMovsxR32R8(.rbx, .rbx).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8ExtractLaneU: PEXTRW only (zero-extended already)" {
    var slot_ids = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    try op_simd_int_cmp_lane.emitI16x8ExtractLaneU(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 5);

    // Expect just PEXTRW; no MOVSX for unsigned.
    try testing.expectEqualSlices(u8, inst.encPextrW(.rbx, .xmm8, 5).slice(), buf.items);
}

test "emitI8x16ReplaceLane: MOVAPS + PINSRB at lane 12" {
    var slot_ids = [_]u16{ 0, 0, 1 };
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
    try pushed.append(testing.allocator, 0); // vec
    try pushed.append(testing.allocator, 1); // value
    var next_vreg: u32 = 2;

    try op_simd_int_cmp_lane.emitI8x16ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 12);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPinsrB(.xmm9, .rbx, 12).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4ReplaceLane: pop scalar + v128, emit MOVAPS + PINSRD" {
    // Synthetic regalloc:
    //   vreg 0 = vec (v128 input)  → XMM slot 0 = XMM8
    //   vreg 1 = value (i32 scalar) → GPR slot 0 = RBX
    //   vreg 2 = result (v128)      → XMM slot 1 = XMM9
    var slot_ids = [_]u16{ 0, 0, 1 };
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
    try pushed.append(testing.allocator, 0); // vec
    try pushed.append(testing.allocator, 1); // value (top of stack)
    var next_vreg: u32 = 2;

    // payload = lane 1.
    try op_simd_int_cmp_lane.emitI32x4ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 1);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPinsrD(.xmm9, .rbx, 1).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2ReplaceLane: dst aliases vec — MOVAPS elided, PINSRQ only" {
    // result vreg shares slot 0 with vec → MOVAPS elided.
    var slot_ids = [_]u16{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0); // vec
    try pushed.append(testing.allocator, 1); // value
    var next_vreg: u32 = 2;

    // payload = lane 1 (only 0 or 1 valid for i64x2).
    try op_simd_int_cmp_lane.emitI64x2ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 1);

    try testing.expectEqualSlices(u8, inst.encPinsrQ(.xmm8, .rbx, 1).slice(), buf.items);
}

test "emitI32x4Splat: GPR slot 0 → XMM slot 0 (RBX → XMM8) — MOVD + PSHUFD" {
    // SysV alloc: GPR pool starts at RBX (slot 0). XMM pool
    // starts at XMM8 (slot 0). The handler resolves vreg 0 as
    // GPR (i32 source) and vreg 1 as XMM (v128 result) — no
    // class collision because alloc.slot is class-aware.
    var slot_ids = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    try op_simd_int_cmp_lane.emitI32x4Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovdXmmFromR32(.xmm8, .rbx).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm8, .xmm8, 0x00).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4ExtractLane: lane 2 — single PEXTRD instruction" {
    var slot_ids = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    // payload = 2 → lane 2.
    try op_simd_int_cmp_lane.emitI32x4ExtractLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 2);

    // Expected: PEXTRD rbx, xmm8, 2. (vreg 0 v128 at slot 0 →
    // XMM8; vreg 1 i32 at slot 0 → RBX in the GPR class.)
    try testing.expectEqualSlices(u8, inst.encPextrD(.rbx, .xmm8, 2).slice(), buf.items);
}

test "emitI64x2ExtractLane: lane 1 — single PEXTRQ instruction (REX.W)" {
    var slot_ids = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    // payload = 1 → lane 1.
    try op_simd_int_cmp_lane.emitI64x2ExtractLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 1);

    try testing.expectEqualSlices(u8, inst.encPextrQ(.rbx, .xmm8, 1).slice(), buf.items);
}

test "emitI16x8ExtmulLowI8x16S: PMOVSXBW + PMOVSXBW + PMULLW (3 instr)" {
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

    try op_simd_int_cmp_lane.emitI16x8ExtmulLowI8x16S(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // lhs = xmm8, rhs = xmm9, dst = xmm10, tmp = xmm14.
    try expected.appendSlice(testing.allocator, inst.encPmovsxbw(.xmm14, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmovsxbw(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPmullW(.xmm10, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4ExtmulLowI16x8U: PMOVZXWD + PMOVZXWD + PMULLD (3 instr)" {
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

    try op_simd_int_cmp_lane.emitI32x4ExtmulLowI16x8U(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPmovzxwd(.xmm14, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmovzxwd(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPmullD(.xmm10, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4ExtaddPairwiseI16x8S: PCMPEQB + PSRLW imm=15 + MOVAPS + PMADDWD (4 instr)" {
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

    try op_simd_int_cmp_lane.emitI32x4ExtaddPairwiseI16x8S(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlwImm(.xmm14, 15).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaddwd(.xmm9, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8ExtaddPairwiseI8x16U: PCMPEQB + PABSB + MOVAPS + PMADDUBSW (4 instr)" {
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

    try op_simd_int_cmp_lane.emitI16x8ExtaddPairwiseI8x16U(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // src = xmm8, dst = xmm9, tmp = xmm14.
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPabsb(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaddubsw(.xmm9, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8ExtaddPairwiseI8x16S: PCMPEQB + PABSB scratch, MOVAPS dst, PMADDUBSW (4 instr; +1 mask built in XMM14 to keep src intact under dst==src alias)" {
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

    try op_simd_int_cmp_lane.emitI16x8ExtaddPairwiseI8x16S(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // +1 constant built in XMM14 (scratch), then MOVAPS into dst,
    // then PMADDUBSW(dst, src). dst(xmm9) != src(xmm8) so no XMM7
    // stash on this path.
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPabsb(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaddubsw(.xmm9, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2ExtmulLowI32x4S: PSHUFD imm=0x50 x2 + PMULDQ (3 instr)" {
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

    try op_simd_int_cmp_lane.emitI64x2ExtmulLowI32x4S(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm10, .xmm8, 0x50).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm14, .xmm9, 0x50).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuldq(.xmm10, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2ExtmulHighI32x4U: PSHUFD imm=0xFA x2 + PMULUDQ (3 instr)" {
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

    try op_simd_int_cmp_lane.emitI64x2ExtmulHighI32x4U(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm10, .xmm8, 0xFA).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm14, .xmm9, 0xFA).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(.xmm10, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4ExtmulHighI16x8S: PSHUFD x2 + PMOVSXWD x2 + PMULLD (5 instr)" {
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

    try op_simd_int_cmp_lane.emitI32x4ExtmulHighI16x8S(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm14, .xmm8, 0xEE).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm15, .xmm9, 0xEE).slice());
    try expected.appendSlice(testing.allocator, inst.encPmovsxwd(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPmovsxwd(.xmm10, .xmm15).slice());
    try expected.appendSlice(testing.allocator, inst.encPmullD(.xmm10, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8ExtmulHighI8x16U: PSHUFD x2 + PMOVZXBW x2 + PMULLW (5 instr)" {
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

    try op_simd_int_cmp_lane.emitI16x8ExtmulHighI8x16U(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm14, .xmm8, 0xEE).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm15, .xmm9, 0xEE).slice());
    try expected.appendSlice(testing.allocator, inst.encPmovzxbw(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPmovzxbw(.xmm10, .xmm15).slice());
    try expected.appendSlice(testing.allocator, inst.encPmullW(.xmm10, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

// D-071 part d (simd_lane shuffle cluster): emitI8x16Shuffle's
// step 2 `MOVAPS dst, lhs` is unconditional. When regalloc's LIFO
// slot-reuse aliases `dst == rhs` (LIFO-top free slot after the
// 2-pop is rhs's slot), the MOVAPS clobbers rhs before step 5's
// `MOVAPS t2, rhs` reads it; t2 gets dst-after-PSHUFB (= zeros if
// the shuffle takes nothing from lhs, e.g. v8x16_shuffle-2 that
// selects all from rhs). The final POR(dst, t2) merges 0 with 0
// and the result is all-zero. Fix mirrors the D-066
// family): stash rhs through XMM7 when `dst == rhs`. Test asserts
// the MOVAPS xmm7, rhs stash is the FIRST emitted instruction in
// the alias case.
test "emitI8x16Shuffle: dst aliases rhs — stash rhs to XMM7 (D-071 part d shuffle cluster)" {
    var slot_ids = [_]u16{ 0, 1, 1 }; // result vreg 2 → XMM9 (== rhs).
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

    var fixups: std.ArrayList(types.SimdConstFixup) = .empty;
    defer fixups.deinit(testing.allocator);
    var extras: std.ArrayList([16]u8) = .empty;
    defer extras.deinit(testing.allocator);

    // A pseudo-mask selecting all 16 lanes from rhs (indices 16..31).
    const all_rhs: [16]u8 = [_]u8{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };
    const consts = [_][16]u8{all_rhs};

    try op_simd_int_cmp_lane.emitI8x16Shuffle(
        testing.allocator,
        &buf,
        alloc,
        &pushed,
        &next_vreg,
        0, // spill_base_off
        &fixups,
        &extras,
        @intCast(consts.len), // simd_consts_base = past const-pool
        consts[0..],
        0,
    );

    const stash = inst.encMovapsXmmXmm(.xmm7, .xmm9).slice();
    try testing.expect(buf.items.len >= stash.len);
    try testing.expectEqualSlices(u8, stash, buf.items[0..stash.len]);
}
