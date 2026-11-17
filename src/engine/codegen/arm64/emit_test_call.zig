//! arm64 emit pass — call / call_indirect tests.
//!
//! Family scope: direct call (no-arg, i64/f32 result, mixed args,
//! void callee, 8 i32 args overflow, spill-aware result),
//! call_indirect with bounds + sig + funcptr lowering.
//!
//! Zone 2 (`src/engine/codegen/arm64/`). Pure relocation per
//! ADR-0021 sub-deliverable b; bytes / assertions
//! identical to the pre-split `emit_test.zig`.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_fp = @import("inst_fp.zig");
const abi = @import("abi.zig");
const prologue = @import("prologue.zig");
const regalloc = @import("../shared/regalloc.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const emit = @import("emit.zig");

const ZirFunc = zir.ZirFunc;
const compile = emit.compile;
const deinit = emit.deinit;

const testing = std.testing;

test "compile: call N (no-arg skeleton) emits BL placeholder + records fixup + result MOV W_dest, W0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // call func_idx = 7 — a forward callee whose body offset isn't
    // known to compile(); the post-emit linker patches the BL via
    // EmitOutput.call_fixups.
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    // func_sigs[7] = i32-returning, no args.
    var sigs: [8]zir.FuncType = undefined;
    for (&sigs) |*s| s.* = .{ .params = &.{}, .results = &.{} };
    sigs[7] = .{ .params = &.{}, .results = &.{.i32} };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    const body0 = prologue.body_start_offset(false);
    // Body sequence for `call N` no-args:
    //   ORR X0,XZR,X19 / BL 0 / ORR W9,WZR,W0 (capture i32 result).
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBL(0)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 0)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));

    // One fixup recorded with byte_offset = body0+4 (the BL slot)
    // + target_func_idx = 7.
    try testing.expectEqual(@as(usize, 1), out.call_fixups.len);
    try testing.expectEqual(@as(u32, body0 + 4), out.call_fixups[0].byte_offset);
    try testing.expectEqual(@as(u32, 7), out.call_fixups[0].target_func_idx);
}

test "compile: call N — i64 callee result captured via X-form ORR" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{.{ .params = &.{}, .results = &.{.i64} }};
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOV X0,X19 + BL: ORR X9,XZR,X0 (X-form for i64) at body+8.
    try testing.expectEqual(@as(u32, inst.encOrrReg(9, 31, 0)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: call N — f32 callee result captured via FMOV S, S0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{.{ .params = &.{}, .results = &.{.f32} }};
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOV X0,X19 + BL: FMOV S16, S0 (f32 slot 0 → V16) at body+8.
    try testing.expectEqual(@as(u32, inst_fp.encFmovSReg(16, 0)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: call N — i32 + i64 args marshalled into W1/X2 (X0=runtime ptr per ADR-0017), result in W0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // (i32.const 7) (i64.const 0xDEADBEEF) call 0  ; callee: (i32, i64) → i32
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xDEADBEEF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 }, // arg0 i32 → slot 0
            .{ .def_pc = 1, .last_use_pc = 2 }, // arg1 i64 → slot 1
            .{ .def_pc = 2, .last_use_pc = 3 }, // result   → slot 0 (reuses)
        },
    };
    const slots = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const sigs = [_]zir.FuncType{
        .{ .params = &.{ .i32, .i64 }, .results = &.{.i32} },
    };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Layout (bytes, post-ADR-0017 prologue = 32, sub-2d-ii):
    //   [32..36]  MOVZ W9, #7               ; arg0 → slot 0 → X9
    //   [36..40]  MOVZ X10, #0xBEEF         ; arg1 lo16
    //   [40..44]  MOVK X10, #0xDEAD lsl#16  ; arg1 hi16
    //   [44..48]  ORR W1, WZR, W9           ; marshal arg0 i32 → W1
    //   [48..52]  ORR X2, XZR, X10          ; marshal arg1 i64 → X2
    //   [52..56]  ORR X0, XZR, X19          ; restore runtime_ptr
    //   [56..60]  BL 0                      ; call placeholder
    //   [60..64]  ORR W9, WZR, W0           ; capture i32 result
    const body0 = prologue.body_start_offset(false);
    // After MOVZ W9 (body+0) + 2-word MOVZ/MOVK X10 (body+4..12):
    // arg-marshal at body+12.. then BL.
    try testing.expectEqual(@as(u32, inst.encOrrRegW(1, 31, 9)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(2, 31, 10)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBL(0)), std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
}

test "compile: call N — f32 + f64 args marshalled into S0/D1" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // f32.const + f64.const + call 0 ; callee: (f32, f64) → f32
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 }); // 2.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 }); // 3.0
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const sigs = [_]zir.FuncType{
        .{ .params = &.{ .f32, .f64 }, .results = &.{.f32} },
    };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // The two arg-marshal MOVs land just before the BL: search the
    // tail for FMOV S0, S16 + FMOV D1, D17 + BL 0.
    // These are stable within the byte stream irrespective of how
    // the const-load prologue lays out — we locate the BL and walk
    // backwards.
    var bl_off: usize = 0;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == inst.encBL(0)) {
            bl_off = p;
            break;
        }
    }
    try testing.expect(bl_off >= 12);
    // Layout immediately before BL (post-sub-2d-ii):
    //   [bl_off-12] FMOV S0, S16     ; arg0
    //   [bl_off-8]  FMOV D1, D17     ; arg1
    //   [bl_off-4]  ORR X0, XZR, X19 ; restore runtime_ptr
    try testing.expectEqual(@as(u32, inst_fp.encFmovSReg(0, 16)), std.mem.readInt(u32, out.bytes[bl_off - 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst_fp.encFmovDReg(1, 17)), std.mem.readInt(u32, out.bytes[bl_off - 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[bl_off - 4 ..][0..4], .little));
}

test "compile: call N — void callee pushes no result vreg" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const sigs = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    const out = try compile(testing.allocator, &f, empty, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // Body: MOV X0,X19 / BL / (epilogue follows).
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBL(0)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

// Caller-side AAPCS64 stack-arg lowering.
// When a callee's signature has > 7 int params (X1..X7 exhausted)
// or > 8 fp params (V0..V7 exhausted), the overflow args land in
// the caller's pre-allocated outgoing-args region at the BOTTOM of
// the frame: `[SP, #off]`, `off` per `abi.ArgCursor`. Locals and
// spills shift upward by `local_base_off = max_stack_arg_bytes`
// across the function. The caller's `[SP, #off]` and the callee's
// `[X29, #(16 + off)]` are the same byte address.

test "compile: call N — 8 i32 args, 8th arg spills to caller stack [SP, #0] (STR W)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 8 (i32.const K) + call 0 ; callee: 8 i32 → i32.
    var k: u32 = 0;
    while (k < 8) : (k += 1) {
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = k });
    }
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    // 9 vregs total (8 args + 1 result).
    var ranges: [9]zir.LiveRange = undefined;
    var ri: usize = 0;
    while (ri < 8) : (ri += 1) {
        ranges[ri] = .{ .def_pc = @intCast(ri), .last_use_pc = 8 };
    }
    ranges[8] = .{ .def_pc = 8, .last_use_pc = 9 };
    f.liveness = .{ .ranges = &ranges };
    const slots = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 8 };
    const sigs = [_]zir.FuncType{
        .{ .params = &.{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .results = &.{.i32} },
    };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Caller-side marshal: args 0..6 go to W1..W7, arg 7 (overflow)
    // is loaded from its vreg's home (slot 7 → X22 per abi.slotToReg)
    // and STR W to [SP, #0] — the outgoing-args slot at the bottom
    // of the caller's frame.
    const str_w_to_sp0 = inst.encStrImmW(abi.slotToReg(7).?, 31, 0);
    var found_stack_arg: bool = false;
    var i: usize = 0;
    while (i + 4 <= out.bytes.len) : (i += 4) {
        if (std.mem.readInt(u32, out.bytes[i..][0..4], .little) == str_w_to_sp0) {
            found_stack_arg = true;
            break;
        }
    }
    try testing.expect(found_stack_arg);
}

// Spill-aware captureCallResult — when the result
// vreg's slot is ≥ max_reg_slots_gpr (= 8) it lives in the spill
// region, not a register. The handler must STR W0/X0/S0/D0 to
// `[SP, #(spill_base_off + spill_off)]` instead of MOV-ing into a
// home register that doesn't exist.

test "compile: call N — i32 result in spill slot lands STR W0 (spill-aware)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    // Force the call result into the spill region by handing
    // regalloc-generated `slots = {8}` (slot id 8 is the first
    // spill slot since max_reg_slots_gpr = 8). spillBytes() returns
    // (9-8)*8 = 8.
    const slots = [_]u16{8};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 9 };
    const sigs = [_]zir.FuncType{
        .{ .params = &.{}, .results = &.{.i32} },
    };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Expect STR W0, [SP, #0] after the BL — the call's i32 result
    // (W0 per AAPCS64) flushed to spill_base_off = 0 (no locals,
    // no outgoing args, so spill region starts at SP+0).
    const expected = inst.encStrImmW(0, 31, 0);
    var found: bool = false;
    var i: usize = 0;
    while (i + 4 <= out.bytes.len) : (i += 4) {
        if (std.mem.readInt(u32, out.bytes[i..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: table.grow i64-table — spilled result stores X-form STR X0 (D-475 boundary)" {
    // D-475 boundary fixture: an i64 table's grow result is a full i64
    // in X0; a spilled result vreg MUST be stored X-form (STR X0), or
    // the X-form spill reload picks up stale upper 32 bits (the -1
    // failure sentinel becomes a garbage positive). The i32 twin below
    // pins the byte-identical W-form fast path.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.table_idx_types = &.{.i64};
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0, .extra = 0 }); // init ref (null)
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 5, .extra = 0 }); // delta
    try f.instrs.append(testing.allocator, .{ .op = .@"table.grow", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // Result vreg → slot 8 = first spill slot (max_reg_slots_gpr = 8).
    const slots = [_]u16{ 0, 1, 8 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 9 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const expected_x = inst.encStrImm(0, 31, 0); // STR X0, [SP, #0]
    const wrong_w = inst.encStrImmW(0, 31, 0); // the D-475 F1 bug shape
    var found_x = false;
    var found_w = false;
    var i: usize = 0;
    while (i + 4 <= out.bytes.len) : (i += 4) {
        const word = std.mem.readInt(u32, out.bytes[i..][0..4], .little);
        if (word == expected_x) found_x = true;
        if (word == wrong_w) found_w = true;
    }
    try testing.expect(found_x);
    try testing.expect(!found_w);
}

test "compile: table.grow i32-table — spilled result keeps W-form STR W0 (byte-identical fast path)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // No table_idx_types → tableIdxType defaults .i32.
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"table.grow", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 8 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 9 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const expected_w = inst.encStrImmW(0, 31, 0); // STR W0, [SP, #0]
    var found_w = false;
    var i: usize = 0;
    while (i + 4 <= out.bytes.len) : (i += 4) {
        if (std.mem.readInt(u32, out.bytes[i..][0..4], .little) == expected_w) {
            found_w = true;
            break;
        }
    }
    try testing.expect(found_w);
}

test "compile: call_indirect — bounds (CMP/B.HS) + sig (LDR/CMP/B.NE) + funcptr (LDR-LSL3/BLR)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .call_indirect, .payload = 3, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    // module_types[3] is what `call_indirect type_idx=3` consults.
    var types: [4]zir.FuncType = undefined;
    for (&types) |*t| t.* = .{ .params = &.{}, .results = &.{} };
    types[3] = .{ .params = &.{}, .results = &.{.i32} };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &types, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Layout (post-sub-2d-ii prologue=32; D-294 inserted CMN+B.EQ null-check
    // between the sig load and the sig CMP; D-586 inserted CMP+B.EQ after the
    // funcptr load — a host-cleared slot leaves a zero funcptr and the
    // call would otherwise execute it):
    //   [32..36] MOVZ W9, #5                   ; idx const
    //   [36..40] ORR W17, WZR, W9              ; zero-extend idx
    //   [40..44] CMP X17, X25                  ; bounds (X-width, D-475)
    //   [44..48] B.HS trap_stub                ; placeholder
    //   [48..52] LDR W16, [X24, X17, LSL #2]   ; sig load
    //   [52..56] CMN W16, #1                   ; D-294 null check (W16 == maxInt?)
    //   [56..60] B.EQ trap_stub                ; D-294 placeholder (code 13)
    //   [60..64] CMP W16, #3                   ; sig compare
    //   [64..68] B.NE trap_stub                ; placeholder
    //   [68..72] LDR X17, [X26, X17, LSL #3]   ; funcptr
    //   [72..76] CMP X17, #0                   ; D-586 null-funcptr check
    //   [76..80] B.EQ trap_stub                ; D-586 placeholder (code 3)
    //   [80..84] ORR X0, XZR, X19              ; restore runtime_ptr
    //   [84..88] BLR X17
    //   [88..92] ORR W9, WZR, W0               ; capture
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encOrrRegW(17, 31, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCmpRegX(17, 25)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    const bhs = std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0x2), bhs & 0xF); // cond=.hs
    try testing.expectEqual(@as(u32, inst.encLdrWRegLsl2(16, 24, 17)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    // D-294 null-element check (CMN W16,#1 ; B.EQ → uninitialized_elem code 13).
    try testing.expectEqual(@as(u32, inst.encCmnImmW(16, 1)), std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
    const beq = std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0x0), beq & 0xF); // cond=.eq
    try testing.expectEqual(@as(u32, inst.encCmpImmW(16, 3)), std.mem.readInt(u32, out.bytes[body0 + 28 ..][0..4], .little));
    const bne = std.mem.readInt(u32, out.bytes[body0 + 32 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0x1), bne & 0xF); // cond=.ne
    try testing.expectEqual(@as(u32, inst.encLdrXRegLsl3(17, 26, 17)), std.mem.readInt(u32, out.bytes[body0 + 36 ..][0..4], .little));
    // D-586 null-funcptr check (CMP X17,#0 ; B.EQ → the cind sig trap stub).
    try testing.expectEqual(@as(u32, inst.encCmpImmX(17, 0)), std.mem.readInt(u32, out.bytes[body0 + 40 ..][0..4], .little));
    const beq_fp = std.mem.readInt(u32, out.bytes[body0 + 44 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0x0), beq_fp & 0xF); // cond=.eq
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[body0 + 48 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBLR(17)), std.mem.readInt(u32, out.bytes[body0 + 52 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 0)), std.mem.readInt(u32, out.bytes[body0 + 56 ..][0..4], .little));
}

test "compile: bundled Class C MEMORY-class — caller LEA X8 + callee STR X8 + buffer capture (ADR-0069)" {
    // Wasm spec §3.4.5 multi-value + AAPCS64 §6.8.2 Composite Type
    // return. The test function `() -> (i32, i32, i32)` is itself
    // MEMORY-class (3 × 8 B = 24 B > 16 B), and it calls func[0]
    // which has the SAME signature → caller-side also goes through
    // the MEMORY-class path. One commit exercises:
    //   - callee prologue: STR X8, [SP, #slot] to save caller's
    //     hidden indirect-result-pointer.
    //   - caller: ADD X8, SP, #buffer_off LEA before BL.
    //   - caller capture: LDR W from buffer × 3 (since the func's
    //     own result slots receive func[0]'s output).
    //   - callee epilogue: LDR X16, [SP, #slot] + STR Xn, [X16,
    //     #(i*8)] × 3 — drains the operand stack into the caller's
    //     buffer via X16.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32, .i32, .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const sigs = [_]zir.FuncType{.{ .params = &.{}, .results = &.{ .i32, .i32, .i32 } }};
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Frame layout:
    //   outgoing_max = 24 (caller's return buffer for the 3-result
    //     sub-call; no overflow args), locals = 0, spill = 0,
    //     indirect_result_slot_bytes = 8 (callee MEMORY-class).
    //   frame_unaligned = 24 + 0 + 0 + 8 = 32 → frame_bytes = 32.
    //   local_base_off = outgoing_max = 24
    //   spill_base_off = local_base_off + locals_bytes = 24
    //   indirect_result_slot_off = spill_base_off + spill_bytes = 24
    //   Layout:
    //     [SP+0..23]  = outgoing-args region (used during sub-call
    //                    as the caller-allocated return buffer)
    //     [SP+24..31] = THIS function's own X8 capture slot
    //                    (set by prologue, read by epilogue)
    // Body starts at body_start_offset_memory_return() = 64
    // (post-ADR-0105 D2 probe shifted +16).
    try testing.expectEqual(@as(u32, 112), prologue.body_start_offset_memory_return());

    // STR X8, [SP, #24] at body_start_offset(true) = 60 (post-SUB-SP,
    // just before body).
    try testing.expectEqual(
        @as(u32, inst.encStrImm(8, 31, 24)),
        std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true)..][0..4], .little),
    );

    // Caller-side prologue at body0 = 64:
    //   [64..68] ADD X8, SP, #0   ; LEA outgoing buffer
    //   [68..72] ORR X0, XZR, X19 ; restore runtime_ptr
    //   [72..76] BL 0             ; call fixup
    //   [76..88] LDR W?, [SP, #0/8/16]  ; capture 3 results
    try testing.expectEqual(
        @as(u32, inst.encAddImm12(8, 31, 0)),
        std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true) + 4 ..][0..4], .little),
    );
    try testing.expectEqual(
        @as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)),
        std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true) + 8 ..][0..4], .little),
    );
    try testing.expectEqual(
        @as(u32, inst.encBL(0)),
        std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true) + 12 ..][0..4], .little),
    );
    // LDR W unsigned-offset: 0xB9400000 | (imm12<<10) | (rn<<5) | rt
    // imm12 = byte_off >> 2. rn = 31 (SP). opcode prefix = 0x2E5
    // (= 0xB9400000 >> 22 = 0x2E5).
    for ([_]u32{ 0, 8, 16 }, 0..) |abs_off, i| {
        const w = std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true) + 16 + @as(u32, @intCast(i)) * 4 ..][0..4], .little);
        try testing.expectEqual(@as(u32, abs_off >> 2), (w >> 10) & 0xFFF);
        try testing.expectEqual(@as(u32, 31), (w >> 5) & 0x1F);
        try testing.expectEqual(@as(u32, 0x2E5), w >> 22);
    }

    // Callee-side epilogue: scan post-capture for `LDR X16, [SP, #24]`
    // (loads captured X8 buffer-ptr from THIS function's slot)
    // followed by 3 × STR Xn, [X16, #i*8].
    const ldr_x16 = inst.encLdrImm(16, 31, 24);
    var found_ldr_at: ?usize = null;
    var scan: usize = prologue.body_start_offset(true) + 28; // post the 3 LDR-W capture words
    while (scan + 4 <= out.bytes.len) : (scan += 4) {
        const word = std.mem.readInt(u32, out.bytes[scan..][0..4], .little);
        if (word == ldr_x16) {
            found_ldr_at = scan;
            break;
        }
    }
    try testing.expect(found_ldr_at != null);
    const epi = found_ldr_at.?;
    for (0..3) |i| {
        const w = std.mem.readInt(u32, out.bytes[epi + 4 + i * 4 ..][0..4], .little);
        try testing.expectEqual(@as(u32, @intCast(i)), (w >> 10) & 0xFFF); // imm12 = byte_off >> 3
        try testing.expectEqual(@as(u32, 16), (w >> 5) & 0x1F); // rn = X16
        try testing.expectEqual(@as(u32, 0x3E4), w >> 22); // STR Xt opcode prefix
    }
}

// ADR-0112 D3 — return_call_indirect
// emit body byte-snapshot. Mirror of the call_indirect probe
// minus the captureCallResult tail, with frame_teardown +
// BR X16 in place of BLR X17 + capture.
test "compile: return_call_indirect — bounds + sig + funcptr-to-X16 + frame_teardown + BR X16" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .return_call_indirect, .payload = 3, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    var types: [4]zir.FuncType = undefined;
    for (&types) |*t| t.* = .{ .params = &.{}, .results = &.{} };
    types[3] = .{ .params = &.{}, .results = &.{.i32} };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &types, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    const body0 = prologue.body_start_offset(false);
    // After MOVZ W9 #5 (body+0):
    //   [+4]  ORR W17, WZR, W9               ; zero-extend idx
    //   [+8]  CMP X17, X25                   ; bounds (X-width, D-475)
    //   [+12] B.HS trap_stub                 ; placeholder
    //   [+16] LDR W16, [X24, X17, LSL #2]    ; sig load
    //   [+20] CMN W16, #1                    ; D-294 null check (W16 == maxInt?)
    //   [+24] B.EQ trap_stub                 ; D-294 placeholder (code 13)
    //   [+28] CMP W16, #3                    ; sig compare
    //   [+32] B.NE trap_stub                 ; placeholder
    //   [+36] LDR X16, [X26, X17, LSL #3]    ; funcptr → X16 (tail target)
    //   [+40] CMP X16, #0                    ; D-586 null-funcptr check
    //   [+44] B.EQ trap_stub                 ; D-586 placeholder (code 3)
    //   [+48] ORR X0, XZR, X19               ; restore runtime_ptr
    //   [+52] LDP X29, X30, [SP], #16        ; frame_teardown (frame_bytes=0)
    //   [+56] BR X16                         ; tail-jump
    try testing.expectEqual(@as(u32, inst.encOrrRegW(17, 31, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCmpRegX(17, 25)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    const bhs = std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0x2), bhs & 0xF); // cond=.hs
    try testing.expectEqual(@as(u32, inst.encLdrWRegLsl2(16, 24, 17)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    // D-294 null-element check (CMN W16,#1 ; B.EQ → uninitialized_elem code 13).
    try testing.expectEqual(@as(u32, inst.encCmnImmW(16, 1)), std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
    const beq = std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0x0), beq & 0xF); // cond=.eq
    try testing.expectEqual(@as(u32, inst.encCmpImmW(16, 3)), std.mem.readInt(u32, out.bytes[body0 + 28 ..][0..4], .little));
    const bne = std.mem.readInt(u32, out.bytes[body0 + 32 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0x1), bne & 0xF); // cond=.ne
    try testing.expectEqual(@as(u32, inst.encLdrXRegLsl3(16, 26, 17)), std.mem.readInt(u32, out.bytes[body0 + 36 ..][0..4], .little));
    // D-586 null-funcptr check, BEFORE frame teardown so the cind sig stub's
    // full-epilogue discipline holds (CMP X16,#0 ; B.EQ → code 3 provisional).
    try testing.expectEqual(@as(u32, inst.encCmpImmX(16, 0)), std.mem.readInt(u32, out.bytes[body0 + 40 ..][0..4], .little));
    const beq_fp = std.mem.readInt(u32, out.bytes[body0 + 44 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0x0), beq_fp & 0xF); // cond=.eq
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[body0 + 48 ..][0..4], .little));
    // LDP X29, X30, [SP], #16 (frame_teardown for frame_bytes=0)
    try testing.expectEqual(@as(u32, 0xA8C17BFD), std.mem.readInt(u32, out.bytes[body0 + 52 ..][0..4], .little));
    // BR X16 = 0xD61F0200
    try testing.expectEqual(@as(u32, 0xD61F0200), std.mem.readInt(u32, out.bytes[body0 + 56 ..][0..4], .little));
}

test "compile: return_call_indirect — multi-table (table_idx > 0) loads size+bases from JitRuntime (D-210)" {
    // Was rejected as UnsupportedOp (initial table-0-only scope); now the
    // multi-table slow path mirrors emitCallIndirect — bounds/sig/funcptr
    // come from tables_ptr + tables_jit_ci_ptr at the call site instead of
    // the pinned X24/X25/X26 cohort.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .return_call_indirect, .payload = 3, .extra = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    var types: [4]zir.FuncType = undefined;
    for (&types) |*t| t.* = .{ .params = &.{}, .results = &.{} };
    types[3] = .{ .params = &.{}, .results = &.{.i32} };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &types, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    const body0 = prologue.body_start_offset(false);
    const rt = abi.runtime_ptr_save_gpr;
    // After MOVZ idx (body+0) + ORR W17,WZR,W9 (body+4), the multi-table
    // tell: load tables_ptr, then table-1 size (u64 X-form, D-475), then
    // CMP X17,X16 (NOT X25).
    try testing.expectEqual(@as(u32, inst.encLdrImm(16, rt, jit_abi.tables_ptr_off)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encLdrImm(16, 16, 1 * jit_abi.table_slice_size + jit_abi.tableslice_len_off)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCmpRegX(17, 16)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    // BR X16 (tail-jump) is present in the body (trap stubs follow it, so it
    // is not the final word). End-to-end execution is covered by the
    // runner_test "return_call_indirect on a non-zero table index" case.
    try testing.expect(std.mem.find(u8, out.bytes, &[_]u8{ 0x00, 0x02, 0x1f, 0xd6 }) != null);
}
