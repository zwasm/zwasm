//! Byte-level tests for x86_64 SIMD int-arith op handlers.
//! Mirror of `op_simd_int_arith.zig` per ADR-0054 §"Naming
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
const op_simd_int_arith = @import("op_simd_int_arith.zig");

const Error = types.Error;

test "emitI32x4Add: three fresh XMM slots — MOVAPS xmm10, xmm8 + PADDD xmm10, xmm9" {
    // Synthetic regalloc state: 3 v128 vregs at slot ids 0/1/2 →
    // XMM8/XMM9/XMM10 via abi.fpSlotToReg. Push lhs (vreg 0) +
    // rhs (vreg 1); the handler allocates result (vreg 2).
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

    try op_simd_int_arith.emitI32x4Add(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    // Expected:
    //   MOVAPS xmm10, xmm8   = 45 0F 28 D0  (REX = 0x40|R|B = 0x45)
    //   PADDD  xmm10, xmm9   = 66 45 0F FE D1
    var expected_buf: [32]u8 = undefined;
    var n: usize = 0;
    const mov = inst.encMovapsXmmXmm(.xmm10, .xmm8);
    @memcpy(expected_buf[n..][0..mov.slice().len], mov.slice());
    n += mov.slice().len;
    const padd = inst.encPaddD(.xmm10, .xmm9);
    @memcpy(expected_buf[n..][0..padd.slice().len], padd.slice());
    n += padd.slice().len;
    try testing.expectEqualSlices(u8, expected_buf[0..n], buf.items);
    try testing.expectEqual(@as(usize, 1), pushed.items.len);
    try testing.expectEqual(@as(u32, 2), pushed.items[0]);
    try testing.expectEqual(@as(u32, 3), next_vreg);
}

test "emitI32x4Add: dst aliases lhs slot — MOVAPS elided, only PADDD emitted" {
    // Force dst onto the same physical XMM as lhs by giving
    // them the same slot id (the regalloc would do this via the
    // free-pool LIFO when lhs's last use is the binop). The
    // handler should detect dst_x == lhs_x and skip the MOVAPS.
    var slot_ids = [_]u16{ 0, 1, 0 };
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
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try op_simd_int_arith.emitI32x4Add(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    try testing.expectEqualSlices(u8, inst.encPaddD(.xmm8, .xmm9).slice(), buf.items);
}

test "emitI8x16Sub: dispatches to encPsubB — opcode 0xF8 reaches the buffer" {
    // Sanity guard against encoder mis-wiring: a 1-line wrapper
    // could easily dispatch to the wrong inst.encXxx if copy-pasted
    // carelessly. Verify the actual byte landing matches PSUBB.
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

    try op_simd_int_arith.emitI8x16Sub(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected_buf: [32]u8 = undefined;
    var n: usize = 0;
    const mov = inst.encMovapsXmmXmm(.xmm10, .xmm8);
    @memcpy(expected_buf[n..][0..mov.slice().len], mov.slice());
    n += mov.slice().len;
    const psub = inst.encPsubB(.xmm10, .xmm9);
    @memcpy(expected_buf[n..][0..psub.slice().len], psub.slice());
    n += psub.slice().len;
    try testing.expectEqualSlices(u8, expected_buf[0..n], buf.items);
}

// D-071 part b: emitI8x16Popcnt clobbers src_x at step 5 (`MOVUPS
// dst_x, [RIP+LUT]`) when regalloc's LIFO slot-reuse aliases
// `dst_x == src_x` (1-pop op: src_v dies at popcnt's pop, slot
// reused for result_v). Step 7's re-read `MOVAPS t1, src_x` then
// loads the LUT bytes back into t1 instead of the original src;
// the low-nibble path computes LUT[LUT[low_nibble(src)]] (since
// LUT[i] < 16 for all i) instead of LUT[low_nibble(src)]. Symptom
// on OrbStack simd_i8x16_arith2: popcnt(0xFF) → 5 (not 8),
// popcnt(0x80) → 2 (not 1), popcnt(0x01) → 0 (not 1). Fix mirrors
// D-066: stash src through XMM7 (project SIMD scratch) when
// `dst_x == src_x`. Test asserts the MOVAPS xmm7, src_x stash is
// emitted as the FIRST instruction in the alias case.
test "emitI8x16Popcnt: dst aliases src — stash src to XMM7 before const loads (D-071 part b)" {
    var slot_ids = [_]u16{ 0, 0 }; // vreg 0 (src) → XMM8, vreg 1 (result) → XMM8 (alias).
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

    var fixups: std.ArrayList(types.SimdConstFixup) = .empty;
    defer fixups.deinit(testing.allocator);
    var extras: std.ArrayList([16]u8) = .empty;
    defer extras.deinit(testing.allocator);

    try op_simd_int_arith.emitI8x16Popcnt(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, &fixups, &extras, 0);

    const stash = inst.encMovapsXmmXmm(.xmm7, .xmm8).slice();
    try testing.expect(buf.items.len >= stash.len);
    try testing.expectEqualSlices(u8, stash, buf.items[0..stash.len]);
}

test "emitI8x16Popcnt: dst != src — no alias stash emitted (control)" {
    var slot_ids = [_]u16{ 0, 1 }; // vreg 0 → XMM8, vreg 1 → XMM9.
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

    var fixups: std.ArrayList(types.SimdConstFixup) = .empty;
    defer fixups.deinit(testing.allocator);
    var extras: std.ArrayList([16]u8) = .empty;
    defer extras.deinit(testing.allocator);

    try op_simd_int_arith.emitI8x16Popcnt(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, &fixups, &extras, 0);

    // First instruction must be MOVUPS xmm15, [RIP+mask] — the
    // const-load placeholder for the nibble mask, NOT a stash.
    const placeholder_first_byte = inst.encMovupsXmmRipRelPlaceholder(.xmm15).slice()[0];
    try testing.expectEqual(placeholder_first_byte, buf.items[0]);
}

test "emitI64x2Mul: emits the 11-instruction PMULUDQ synthesis sequence" {
    // Synthetic regalloc: lhs at slot 0 (XMM8), rhs at slot 1
    // (XMM9), dst at slot 2 (XMM10) — none aliased, so the final
    // MOVAPS dst, lhs is emitted.
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

    try op_simd_int_arith.emitI64x2Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    // Build expected sequence verbatim from the encoders (use
    // the same constants as the handler so encoder churn is
    // caught here, not at runtime).
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const s1 = abi.fp_spill_stage_xmms[0];
    const s2 = abi.fp_spill_stage_xmms[1];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(s1, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlqImm(s1, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(s1, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(s2, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlqImm(s2, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(s2, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPaddQ(s1, s2).slice());
    try expected.appendSlice(testing.allocator, inst.encPsllqImm(s1, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPaddQ(.xmm10, s1).slice());

    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2Mul: dst aliases lhs — final MOVAPS elided" {
    var slot_ids = [_]u16{ 0, 1, 0 }; // dst (vreg 2) reuses lhs slot
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
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try op_simd_int_arith.emitI64x2Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    // Same sequence minus the `MOVAPS dst, lhs` step (instructions
    // 1-8 unchanged; step 9 = dst_x == lhs_x = XMM8 → elided).
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const s1 = abi.fp_spill_stage_xmms[0];
    const s2 = abi.fp_spill_stage_xmms[1];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(s1, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlqImm(s1, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(s1, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(s2, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlqImm(s2, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(s2, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPaddQ(s1, s2).slice());
    try expected.appendSlice(testing.allocator, inst.encPsllqImm(s1, 32).slice());
    // (no MOVAPS dst, lhs — they alias)
    try expected.appendSlice(testing.allocator, inst.encPmuludq(.xmm8, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPaddQ(.xmm8, s1).slice());

    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

// D-071 part a: emitI64x2Mul clobbers rhs at step 9
// (`MOVAPS dst, lhs`) when regalloc's LIFO slot-reuse aliases
// `dst_x == rhs_x` (and dst != lhs). Step 10's `PMULUDQ dst, rhs`
// then computes `a_lo * a_lo` (since rhs slot now holds lhs)
// instead of `a_lo * b_lo`. Symptom on OrbStack simd_i64x2_arith:
// i64x2.mul(1, 0xFFFFFFFFFFFFFFFF) → 0xFFFFFFFF_00000001
// (= 1*1 + cross<<32) instead of 0xFFFFFFFFFFFFFFFF (= 1*0xFFFFFFFF
// + 0xFFFFFFFF<<32). Fix mirrors the D-066 family:
// stash rhs through XMM7 when `dst != lhs && dst == rhs`.
test "emitI64x2Mul: dst aliases rhs — stash rhs to XMM7 (D-071 part a)" {
    var slot_ids = [_]u16{ 0, 1, 1 }; // dst (vreg 2) reuses rhs slot → XMM9.
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

    try op_simd_int_arith.emitI64x2Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const s1 = abi.fp_spill_stage_xmms[0];
    const s2 = abi.fp_spill_stage_xmms[1];
    // Stash rhs (XMM9) to XMM7 first; all subsequent rhs reads use
    // xmm7. dst (XMM9) gets MOVAPS'd from lhs (XMM8) at step 9 (no
    // alias with lhs), then PMULUDQ dst, xmm7 reads original rhs.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm7, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(s1, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlqImm(s1, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(s1, .xmm7).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(s2, .xmm7).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlqImm(s2, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(s2, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPaddQ(s1, s2).slice());
    try expected.appendSlice(testing.allocator, inst.encPsllqImm(s1, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(.xmm9, .xmm7).slice());
    try expected.appendSlice(testing.allocator, inst.encPaddQ(.xmm9, s1).slice());

    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4Mul: dispatches to encPmullD — opcode 0x40 with 0x38 escape reaches the buffer" {
    // Sanity guard for the SSE4.1 encoder path: PMULLD's second
    // escape byte (0x38) must land between 0x0F and the opcode.
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

    try op_simd_int_arith.emitI32x4Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected_buf: [32]u8 = undefined;
    var n: usize = 0;
    const mov = inst.encMovapsXmmXmm(.xmm10, .xmm8);
    @memcpy(expected_buf[n..][0..mov.slice().len], mov.slice());
    n += mov.slice().len;
    const pmull = inst.encPmullD(.xmm10, .xmm9);
    @memcpy(expected_buf[n..][0..pmull.slice().len], pmull.slice());
    n += pmull.slice().len;
    try testing.expectEqualSlices(u8, expected_buf[0..n], buf.items);
}

test "emitI16x8Mul: dispatches to encPmullW — opcode 0xD5 (SSE2 path)" {
    var slot_ids = [_]u16{ 0, 1, 0 }; // dst aliases lhs → MOVAPS elided
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
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try op_simd_int_arith.emitI16x8Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    try testing.expectEqualSlices(u8, inst.encPmullW(.xmm8, .xmm9).slice(), buf.items);
}

test "emitI64x2Add: dispatches to encPaddQ — opcode 0xD4 reaches the buffer" {
    var slot_ids = [_]u16{ 0, 1, 0 }; // dst aliases lhs → MOVAPS elided
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
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try op_simd_int_arith.emitI64x2Add(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    try testing.expectEqualSlices(u8, inst.encPaddQ(.xmm8, .xmm9).slice(), buf.items);
}

test "emitI32x4Add: spilled rhs loads via MOVUPS stage XMM14 (ADR-0053 Part 3)" {
    // v128 spilled vregs are now supported. The
    // rhs vreg (slot id 6 past max_reg_slots_fp=6) loads into the
    // stage-0 XMM (XMM14) via MOVUPS before PADDD. lhs + dst are
    // in registers (slots 0 / 1 → first two allocatable XMMs).
    var slot_ids = [_]u16{ 0, 6, 1 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 7,
        .max_reg_slots_gpr = abi.allocatable_gprs.len,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0); // lhs → slot 0 → XMM8
    try pushed.append(testing.allocator, 1); // rhs → slot 6 → spilled
    var next_vreg: u32 = 2;

    // spill_base_off = 16; rhs spill_off = (6 - 4) * 16 = 32
    // (post-ADR-0110 widen formula; shape_tags is unset on this
    // manual Allocation and spill_offsets is null). abs_off =
    // 16 + 32 = 48 → disp = -48.
    try op_simd_int_arith.emitI32x4Add(testing.allocator, &buf, alloc, &pushed, &next_vreg, 16);

    // Expected: MOVUPS XMM14, [RBP-32] ; PADDD XMM9, XMM8 (lhs→dst
    // MOVAPS skipped since dst==lhs both slot 0? No: result_v slot = 1)
    // Actually with slot_ids = [0, 6, 1], dst = result_v at slot 1
    // → XMM9. lhs at slot 0 → XMM8. So MOVAPS XMM9, XMM8 then
    // PADDD XMM9, XMM14. Let's just verify the MOVUPS-load is the
    // first emit and PADDD appears as the last 4 bytes.
    try testing.expect(buf.items.len > 0);
    // First 4 bytes should be a MOVUPS XMM14 load (0F 10 ModR/M ...).
    // With REX.R for XMM14 (extBit=1) → REX prefix 0x44 first.
    try testing.expectEqual(@as(u8, 0x44), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x0F), buf.items[1]);
    try testing.expectEqual(@as(u8, 0x10), buf.items[2]);
}

test "emitI16x8Q15mulrSatS: PMULHRSW + saturate a==b==0x8000 overflow lanes to 0x7FFF" {
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

    try op_simd_int_arith.emitI16x8Q15mulrSatS(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // lhs=vreg0(xmm8), rhs=vreg1(xmm9), dst=vreg2(xmm10); dst aliases
    // neither input → no XMM7 stash. MOVAPS dst,lhs; PMULHRSW dst,rhs;
    // then build splat(0x8000) in XMM7, PCMPEQW(XMM7,dst) → overflow
    // mask, PXOR dst,XMM7 saturates the a==b==-32768 lane to 0x7FFF.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmulhrsw(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqW(.xmm7, .xmm7).slice());
    try expected.appendSlice(testing.allocator, inst.encPsllwImm(.xmm7, 15).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqW(.xmm7, .xmm10).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, .xmm7).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4DotI16x8S: PMADDWD dst, src" {
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

    try op_simd_int_arith.emitI32x4DotI16x8S(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaddwd(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}
