//! Byte-level tests for x86_64 SIMD floating-point op
//! handlers. Mirror of `op_simd_float.zig` per ADR-0054
//! §"Naming convention" (4-way mirror split with
//! `<source>_test.zig` suffix). Extracted from
//! `op_simd_test.zig`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");
const testing = std.testing;

const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const types = @import("types.zig");
const op_simd_float = @import("op_simd_float.zig");

const Error = types.Error;

test "emitF32x4Eq: direct CMPPS imm=0x00 (no swap)" {
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

    try op_simd_float.emitF32x4Eq(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encCmpps(.xmm10, .xmm9, 0x00).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Gt: swap path — MOVAPS dst, rhs + CMPPS dst, lhs, imm=0x01 (LT)" {
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

    try op_simd_float.emitF32x4Gt(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // gt = swap + LT: MOVAPS dst, rhs (XMM9) ; CMPPS dst, lhs (XMM8), 0x01.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encCmpps(.xmm10, .xmm8, 0x01).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Lt: direct CMPPD imm=0x01 (no swap)" {
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

    try op_simd_float.emitF64x2Lt(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encCmppd(.xmm10, .xmm9, 0x01).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Ge: swap + CMPPD imm=0x02 (LE)" {
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

    try op_simd_float.emitF64x2Ge(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // ge = swap + LE: MOVAPS dst, rhs (XMM9) ; CMPPD dst, lhs (XMM8), 0x02.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encCmppd(.xmm10, .xmm8, 0x02).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Add: dispatches via emitV128IntBinop with encAddps (no 66 prefix)" {
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

    try op_simd_float.emitF32x4Add(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encAddps(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Mul: dispatches via emitV128IntBinop with encMulpd (66 prefix)" {
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

    try op_simd_float.emitF64x2Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encMulpd(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Sqrt: unary path — single SQRTPS dst, src (no MOVAPS)" {
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

    try op_simd_float.emitF32x4Sqrt(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encSqrtps(.xmm9, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Sqrt: unary path — single SQRTPD dst, src" {
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

    try op_simd_float.emitF64x2Sqrt(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encSqrtpd(.xmm9, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Min: 10-instruction NaN-correction synthesis" {
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

    try op_simd_float.emitF32x4Min(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const scratch = abi.fp_spill_stage_xmms[0]; // XMM14
    const scratch2 = abi.fp_spill_stage_xmms[1]; // XMM15
    // 1. MOVAPS dst, lhs                  (lhs=XMM8, dst=XMM10)
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    // 2. MINPS dst, rhs
    try expected.appendSlice(testing.allocator, inst.encMinps(.xmm10, .xmm9).slice());
    // 3. MOVAPS scratch, rhs
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch, .xmm9).slice());
    // 4. MINPS scratch, lhs
    try expected.appendSlice(testing.allocator, inst.encMinps(scratch, .xmm8).slice());
    // 5. ORPS dst, scratch
    try expected.appendSlice(testing.allocator, inst.encOrps(.xmm10, scratch).slice());
    // 6. MOVAPS scratch2, dst
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch2, .xmm10).slice());
    // 7. CMPPS dst, scratch, 3
    try expected.appendSlice(testing.allocator, inst.encCmpps(.xmm10, scratch, 0x03).slice());
    // 8. ORPS scratch2, dst
    try expected.appendSlice(testing.allocator, inst.encOrps(scratch2, .xmm10).slice());
    // 9. PSRLD dst, 10
    try expected.appendSlice(testing.allocator, inst.encPsrldImm(.xmm10, 10).slice());
    // 10. ANDNPS dst, scratch2
    try expected.appendSlice(testing.allocator, inst.encAndnps(.xmm10, scratch2).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Max: 13-instruction NaN-correction synthesis" {
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

    try op_simd_float.emitF32x4Max(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const scratch = abi.fp_spill_stage_xmms[0];
    const scratch2 = abi.fp_spill_stage_xmms[1];
    // 1. MOVAPS scratch, lhs
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch, .xmm8).slice());
    // 2. MAXPS scratch, rhs
    try expected.appendSlice(testing.allocator, inst.encMaxps(scratch, .xmm9).slice());
    // 3. MOVAPS scratch2, rhs
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch2, .xmm9).slice());
    // 4. MAXPS scratch2, lhs
    try expected.appendSlice(testing.allocator, inst.encMaxps(scratch2, .xmm8).slice());
    // 5. MOVAPS dst, scratch
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, scratch).slice());
    // 6. XORPS dst, scratch2
    try expected.appendSlice(testing.allocator, inst.encXorps(.xmm10, scratch2).slice());
    // 7. ORPS scratch, dst
    try expected.appendSlice(testing.allocator, inst.encOrps(scratch, .xmm10).slice());
    // 8. MOVAPS scratch2, scratch
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch2, scratch).slice());
    // 9. SUBPS scratch, dst
    try expected.appendSlice(testing.allocator, inst.encSubps(scratch, .xmm10).slice());
    // 10. CMPPS scratch2, scratch2, 3
    try expected.appendSlice(testing.allocator, inst.encCmpps(scratch2, scratch2, 0x03).slice());
    // 11. MOVAPS dst, scratch2
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, scratch2).slice());
    // 12. PSRLD dst, 10
    try expected.appendSlice(testing.allocator, inst.encPsrldImm(.xmm10, 10).slice());
    // 13. ANDNPS dst, scratch
    try expected.appendSlice(testing.allocator, inst.encAndnps(.xmm10, scratch).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Min: PD encoders + PSRLQ shift=13 (10 instr)" {
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

    try op_simd_float.emitF64x2Min(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const scratch = abi.fp_spill_stage_xmms[0];
    const scratch2 = abi.fp_spill_stage_xmms[1];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encMinpd(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMinpd(scratch, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encOrpd(.xmm10, scratch).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch2, .xmm10).slice());
    try expected.appendSlice(testing.allocator, inst.encCmppd(.xmm10, scratch, 0x03).slice());
    try expected.appendSlice(testing.allocator, inst.encOrpd(scratch2, .xmm10).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlqImm(.xmm10, 13).slice());
    try expected.appendSlice(testing.allocator, inst.encAndnpd(.xmm10, scratch2).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Splat: PSHUFD dst, src, 0x44 — broadcast low qword" {
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

    try op_simd_float.emitF64x2Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    try testing.expectEqualSlices(u8, inst.encPshufd(.xmm9, .xmm8, 0x44).slice(), buf.items);
}

test "emitF64x2ExtractLane: lane 1 → PSHUFD imm 0xEE (select high qword)" {
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

    try op_simd_float.emitF64x2ExtractLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 1);

    try testing.expectEqualSlices(u8, inst.encPshufd(.xmm9, .xmm8, 0xEE).slice(), buf.items);
}

test "emitF64x2ReplaceLane: lane 0 → MOVAPS + MOVSD (preserves high qword)" {
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
    try pushed.append(testing.allocator, 0); // vec
    try pushed.append(testing.allocator, 1); // value
    var next_vreg: u32 = 2;

    try op_simd_float.emitF64x2ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encMovsdXmmXmm(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2ReplaceLane: lane 1 → MOVAPS + MOVLHPS (writes value to dst's high qword)" {
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

    try op_simd_float.emitF64x2ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 1);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encMovlhps(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2ReplaceLane: dst aliases value — stash value to XMM7 (D-078 (a) fix)" {
    // slot_ids = {0, 1, 1} → vreg 0 (vec) → XMM8, vreg 1 (value) → XMM9,
    // vreg 2 (result) → XMM9 (LIFO-reuse after value's slot is freed).
    // Pre-fix: MOVAPS dst, vec clobbered value before MOVSD dst, value
    // read it; symptom on simd_lane.137 / f64x2_extract_lane was
    // result = vec instead of (value_lo, vec_hi).
    var slot_ids = [_]u16{ 0, 1, 1 };
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
    try pushed.append(testing.allocator, 0); // vec
    try pushed.append(testing.allocator, 1); // value
    var next_vreg: u32 = 2;

    try op_simd_float.emitF64x2ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // Pre-stash value (XMM9) into XMM7 before the vec MOVAPS overwrites
    // it; subsequent MOVSD reads from XMM7 instead of the clobbered XMM9.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm7, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encMovsdXmmXmm(.xmm9, .xmm7).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4ReplaceLane: dst aliases value — stash value to XMM7" {
    var slot_ids = [_]u16{ 0, 1, 1 };
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
    try pushed.append(testing.allocator, 0); // vec
    try pushed.append(testing.allocator, 1); // value
    var next_vreg: u32 = 2;

    try op_simd_float.emitF32x4ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm7, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encInsertps(.xmm9, .xmm7, 0).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Splat: PSHUFD dst, src, 0x00" {
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

    try op_simd_float.emitF32x4Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    try testing.expectEqualSlices(u8, inst.encPshufd(.xmm9, .xmm8, 0x00).slice(), buf.items);
}

test "emitF32x4ExtractLane: lane 2 → PSHUFD dst, src, 0xAA" {
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

    try op_simd_float.emitF32x4ExtractLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 2);

    // lane 2 → 2 * 0x55 = 0xAA.
    try testing.expectEqualSlices(u8, inst.encPshufd(.xmm9, .xmm8, 0xAA).slice(), buf.items);
}

test "emitF32x4ReplaceLane: lane 1 → MOVAPS + INSERTPS imm 0x10" {
    // vec @ slot 0 (XMM8); value @ slot 1 (XMM9); result @ slot 2
    // (XMM10). MOVAPS preamble + INSERTPS with count_d=lane=1.
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
    try pushed.append(testing.allocator, 0); // vec
    try pushed.append(testing.allocator, 1); // value
    var next_vreg: u32 = 2;

    try op_simd_float.emitF32x4ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 1);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encInsertps(.xmm10, .xmm9, 0x10).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Abs: PCMPEQB + PSLLD-31 + (MOVAPS dst,src) + PANDN + MOVAPS" {
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

    try op_simd_float.emitF32x4Abs(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // src = xmm8, dst = xmm9, mask = xmm7.
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm7, .xmm7).slice());
    try expected.appendSlice(testing.allocator, inst.encPslldImm(.xmm7, 31).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPandn(.xmm7, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm7).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Abs: PCMPEQB + PSLLQ-63 (qword sign-mask) for f64x2" {
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

    try op_simd_float.emitF64x2Abs(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm7, .xmm7).slice());
    try expected.appendSlice(testing.allocator, inst.encPsllqImm(.xmm7, 63).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPandn(.xmm7, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm7).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Neg: PCMPEQB + PSLLD-31 + MOVAPS dst,src + PXOR dst, mask (4 instr)" {
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

    try op_simd_float.emitF32x4Neg(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm7, .xmm7).slice());
    try expected.appendSlice(testing.allocator, inst.encPslldImm(.xmm7, 31).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm9, .xmm7).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Neg: PCMPEQB + PSLLQ-63 + MOVAPS + PXOR" {
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

    try op_simd_float.emitF64x2Neg(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm7, .xmm7).slice());
    try expected.appendSlice(testing.allocator, inst.encPsllqImm(.xmm7, 63).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm9, .xmm7).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Ceil: ROUNDPS dst, src, imm=0x0A (suppress-precision | ceil)" {
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

    try op_simd_float.emitF32x4Ceil(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encRoundps(.xmm9, .xmm8, 0x0A).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Floor / Trunc / Nearest: ROUNDPS imm bits 09 / 0B / 08" {
    var slot_ids = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 2,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    inline for (.{
        .{ op_simd_float.emitF32x4Floor, @as(u8, 0x09) },
        .{ op_simd_float.emitF32x4Trunc, @as(u8, 0x0B) },
        .{ op_simd_float.emitF32x4Nearest, @as(u8, 0x08) },
    }) |pair| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var pushed: std.ArrayList(u32) = .empty;
        defer pushed.deinit(testing.allocator);
        try pushed.append(testing.allocator, 0);
        var next_vreg: u32 = 1;

        try pair[0](testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(testing.allocator);
        try expected.appendSlice(testing.allocator, inst.encRoundps(.xmm9, .xmm8, pair[1]).slice());
        try testing.expectEqualSlices(u8, expected.items, buf.items);
    }
}

test "emitF32x4ConvertI32x4U: 11-instr split-and-recombine recipe" {
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

    try op_simd_float.emitF32x4ConvertI32x4U(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // src = xmm8, dst = xmm9, a_lo = xmm14, a_hi = xmm15. D-034 (g): src is
    // first loaded into dst (MOVAPS xmm9, xmm8) and the recipe then reads dst.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm14, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPslldImm(.xmm14, 16).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrldImm(.xmm14, 16).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm15, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPsubD(.xmm15, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encCvtdq2ps(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrldImm(.xmm15, 1).slice());
    try expected.appendSlice(testing.allocator, inst.encCvtdq2ps(.xmm15, .xmm15).slice());
    try expected.appendSlice(testing.allocator, inst.encAddps(.xmm15, .xmm15).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm15).slice());
    try expected.appendSlice(testing.allocator, inst.encAddps(.xmm9, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4TruncSatF32x4S: 9-instr NaN-mask + XOR-fix recipe" {
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

    try op_simd_float.emitI32x4TruncSatF32x4S(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // src = xmm8, dst = xmm9, tmp = xmm7 (D-034 (g): NaN-mask parked on XMM7).
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm7, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encCmpps(.xmm7, .xmm8, 0x00).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encAndps(.xmm9, .xmm7).slice());
    try expected.appendSlice(testing.allocator, inst.encXorps(.xmm7, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encCvttps2dq(.xmm9, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPand(.xmm7, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPsradImm(.xmm7, 31).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm9, .xmm7).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Pmin: MOVAPS dst,rhs + MINPS dst,lhs (operand swap)" {
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
    try pushed.append(testing.allocator, 0); // lhs (c1) — slot 0 → xmm8
    try pushed.append(testing.allocator, 1); // rhs (c2) — slot 1 → xmm9
    var next_vreg: u32 = 2;

    try op_simd_float.emitF32x4Pmin(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // dst = xmm10, rhs = xmm9, lhs = xmm8.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMinps(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Pmax: MOVAPS dst,rhs + MAXPD dst,lhs (operand swap)" {
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

    try op_simd_float.emitF64x2Pmax(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMaxpd(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4TruncSatF32x4U: 14-instr two-path inline-magic recipe" {
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

    try op_simd_float.emitI32x4TruncSatF32x4U(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // src = xmm8, dst = xmm9, tmp2 = xmm14, tmp1 = xmm15. D-034 (g): src is
    // loaded into dst first (in-place), so MOVAPS dst,src precedes the XORPS.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encXorps(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encMaxps(.xmm9, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqD(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrldImm(.xmm14, 1).slice());
    try expected.appendSlice(testing.allocator, inst.encCvtdq2ps(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm15, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encCvttps2dq(.xmm9, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encSubps(.xmm15, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encCmpps(.xmm14, .xmm15, 0x02).slice());
    try expected.appendSlice(testing.allocator, inst.encCvttps2dq(.xmm15, .xmm15).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm15, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaxsd(.xmm15, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPaddD(.xmm9, .xmm15).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2 Ceil/Floor/Trunc/Nearest: ROUNDPD imm bits 0A/09/0B/08" {
    var slot_ids = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 2,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    inline for (.{
        .{ op_simd_float.emitF64x2Ceil, @as(u8, 0x0A) },
        .{ op_simd_float.emitF64x2Floor, @as(u8, 0x09) },
        .{ op_simd_float.emitF64x2Trunc, @as(u8, 0x0B) },
        .{ op_simd_float.emitF64x2Nearest, @as(u8, 0x08) },
    }) |pair| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var pushed: std.ArrayList(u32) = .empty;
        defer pushed.deinit(testing.allocator);
        try pushed.append(testing.allocator, 0);
        var next_vreg: u32 = 1;

        try pair[0](testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(testing.allocator);
        try expected.appendSlice(testing.allocator, inst.encRoundpd(.xmm9, .xmm8, pair[1]).slice());
        try testing.expectEqualSlices(u8, expected.items, buf.items);
    }
}
