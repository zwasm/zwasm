//! arm64 emit pass — local + const + frame + smoke tests.
//!
//! Family scope: i32/i64/f32/f64.const, local.get / set / tee,
//! prologue + epilogue + frame layout (locals, mixed params,
//! 8-arg overflow), regalloc spill round-trip + slot boundary,
//! and the empty-body + UnsupportedOp + AllocationMissing
//! smoke probes.
//!
//! Zone 2 (`src/engine/codegen/arm64/`). Pure relocation per
//! ADR-0021 sub-deliverable b; bytes / assertions
//! identical to the pre-split `emit_test.zig`.

const std = @import("std");
const builtin = @import("builtin");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_fp = @import("inst_fp.zig");
const prologue = @import("prologue.zig");
const regalloc = @import("../shared/regalloc.zig");
const liveness = @import("../../../ir/analysis/liveness.zig");
const emit = @import("emit.zig");

const ZirFunc = zir.ZirFunc;
const Error = emit.Error;
const compile = emit.compile;
const deinit = emit.deinit;

const testing = std.testing;

test "compile: empty body without liveness errors" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false));
}

test "compile: empty function (no instrs, empty liveness) emits prologue+epilogue" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    // No `end` op in the stream → emit walks zero instrs and
    // returns just the prologue (no epilogue). That's the expected
    // shape for a malformed body; the gate filters such
    // funcs at validate-time, so emit doesn't enforce well-formedness.
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // 2 prologue u32s = 8 bytes. (Empty body has no `end` op so the
    // stack-overflow trap stub is not emitted; only the prologue is
    // present. Prologue grew from 40 → 56 with ADR-0105 D2 probe.)
    try testing.expectEqual(@as(usize, 104), out.bytes.len);
    // Use the centralised opcode constants; ABI-pinned offsets [0..4] / [4..8].
    try prologue.assertPrologueOpcodes(out.bytes);
}

test "compile: (i32.const 42) end yields 5-instr body returning 42 in X0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Expected stream: prologue (incl. ADR-0105 probe) + MOVZ X9,#42 +
    // MOV X0,X9 + LDP + RET + 7-instr stack-overflow trap stub.
    // = 56 + 4*4 + 7*4 = 100 bytes.
    try testing.expectEqual(@as(usize, 204), out.bytes.len);

    // Word 0: STP prologue (ABI-pinned per AAPCS64; offset fixed).
    try testing.expectEqual(prologue.FpLrSave.stp_word, std.mem.readInt(u32, out.bytes[0..4], .little));
    // Word 1: MOV X29, SP (ABI-pinned).
    try testing.expectEqual(prologue.FpLrSave.mov_fp_word, std.mem.readInt(u32, out.bytes[4..8], .little));
    // Body words use `prologue.body_start_offset(has_frame)` so a
    // future prologue-shape change updates one helper, not 142 sites.
    const body0 = prologue.body_start_offset(false);
    // Word 2: MOVZ X9, #42 — slot 0 → X9 per abi.slotToReg.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 42)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    // Word 3: MOV X0, X9 (ORR X0, XZR, X9).
    try testing.expectEqual(@as(u32, 0xAA0903E0), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    // Word 4: LDP epilogue.
    try testing.expectEqual(@as(u32, 0xA8C17BFD), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    // Word 5: RET.
    try testing.expectEqual(@as(u32, 0xD65F03C0), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
}

test "compile: i32.const 0x12345678 emits MOVZ + MOVK (full 32-bit)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x12345678 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // 7 u32s now: STP / MOV-FP-SP / MOVZ / MOVK / MOV-X0 / LDP / RET.
    try testing.expectEqual(@as(usize, 208), out.bytes.len);
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0x5678)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0x1234, 1)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: unsupported op surfaces UnsupportedOp" {
    // The probe needs a ZirOp the enum reserves but no codegen path
    // implements (hits the emit switch `else => UnsupportedOp`). The probe
    // uses `memory.discard` — the Memory Control proposal op, reserved in
    // the ZIR enum with NO validate/lower/liveness/emit path.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"memory.discard" });
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false));
}

test "compile: 1 local — prologue includes SUB SP,SP,#16; epilogue ADD SP,SP,#16" {
    // ADR-0155 stage-1 register-homing gates on the HOST arch (local_homing.plan
    // checks builtin.target.cpu.arch); this test asserts the HOMED layout, which
    // only occurs on an aarch64 host. On x86_64 the arm64 emitter runs un-homed
    // (K=0) → skip (the x86_64 emitter has its own tests; homing is stage 4 there).
    // SIBLING-AT: src/engine/codegen/x86_64/op_locals.zig (x86_64 local emit — un-homed; homing is ADR-0155 stage 4)
    if (comptime builtin.cpu.arch != .aarch64) return;
    // ADR-0155 stage 1: the declared i32 local is REGISTER-HOMED. The prologue
    // still zero-inits its stack slot (STR XZR) + seeds the home register from
    // it (LDR W); `local.set`/`local.get` become reg→reg MOVs (no STR/LDR to the
    // slot). Driven through the real liveness+regalloc pipeline so the alloc is
    // consistent with the appended pseudo-vreg (the hand-built alloc the
    // pre-homing test used is incompatible). Frame still has the local slot.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const locals = [_]zir.ValType{.i32};
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.set", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = try liveness.compute(testing.allocator, &f, &.{}, &.{}, &.{});
    defer if (f.liveness) |lv| liveness.deinit(testing.allocator, lv);
    const alloc = try regalloc.compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    const body0 = prologue.body_start_offset(true);
    // SUB SP at the last prologue word (body0 - 4); 16-byte frame for the local.
    try testing.expectEqual(@as(u32, inst.encSubImm12(31, 31, 16)), std.mem.readInt(u32, out.bytes[body0 - 4 ..][0..4], .little));
    // STR XZR [SP, #0] (local zero-init) at body+0 — unchanged by homing.
    try testing.expectEqual(@as(u32, inst.encStrImm(31, 31, 0)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    // body+4 = LDR W X9, [SP,#0] (seed home reg from the zero-inited slot) —
    // the homing prologue load. Home reg = allocatable_gprs[0] = X9. The slot
    // is dormant thereafter (set/get are reg→reg MOVs).
    try testing.expectEqual(@as(u32, inst.encLdrImmW(9, 31, 0)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: 3 locals — frame rounds up to 32 bytes (3*8=24 → align to 32)" {
    // ADR-0155 stage-1 homing is host-aarch64-gated; this asserts the homed layout
    // → skip on non-aarch64 host (the arm64 emitter runs un-homed there).
    // SIBLING-AT: src/engine/codegen/x86_64/op_locals.zig (x86_64 local emit — un-homed; homing is ADR-0155 stage 4)
    if (comptime builtin.cpu.arch != .aarch64) return;
    // ADR-0155 stage 1: the 3 declared i32 locals are register-homed, but their
    // stack slots still exist + are zero-inited in the prologue (the frame size
    // is unchanged). Driven through the real pipeline. local.set 2 / local.get 2
    // are now reg→reg MOVs (not STR/LDR to slot 2), so the body is shorter; the
    // assertions check the frame + the per-local zero-init STRs (still present).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const locals = [_]zir.ValType{ .i32, .i32, .i32 };
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.set", .payload = 2 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 2 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = try liveness.compute(testing.allocator, &f, &.{}, &.{}, &.{});
    defer if (f.liveness) |lv| liveness.deinit(testing.allocator, lv);
    const alloc = try regalloc.compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(true);
    // SUB SP, SP, #32 (3*8=24 → aligned 32) at body0 - 4 — frame unchanged.
    try testing.expectEqual(@as(u32, inst.encSubImm12(31, 31, 32)), std.mem.readInt(u32, out.bytes[body0 - 4 ..][0..4], .little));
    // 3 STR XZR at body+0, +4, +8 (local zero-init for slots 0,1,2) — unchanged.
    try testing.expectEqual(@as(u32, inst.encStrImm(31, 31, 0)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encStrImm(31, 31, 8)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encStrImm(31, 31, 16)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    // body+12,+16,+20 = the 3 homing prologue LDR W (seed home regs X9/X10/X11
    // from slots 0/8/16). local 2 (the set/get target) homes to slot 2 = X11.
    try testing.expectEqual(@as(u32, inst.encLdrImmW(9, 31, 0)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encLdrImmW(10, 31, 8)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encLdrImmW(11, 31, 16)), std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
}

test "compile: local.tee writes to local but keeps value pushed" {
    // ADR-0155 stage-1 homing is host-aarch64-gated; this asserts the homed layout
    // → skip on non-aarch64 host (the arm64 emitter runs un-homed there).
    // SIBLING-AT: src/engine/codegen/x86_64/op_locals.zig (x86_64 local emit — un-homed; homing is ADR-0155 stage 4)
    if (comptime builtin.cpu.arch != .aarch64) return;
    // ADR-0155 stage 1: the declared i32 local is register-homed. `local.tee 0`
    // MOVs the (peeked) value into the home register and leaves it on the
    // operand stack — the slot is no longer written. Driven through the real
    // pipeline; we assert the local zero-init + prologue home-seed are present
    // and the local.tee does NOT emit an STR-to-slot (homed = reg→reg).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const locals = [_]zir.ValType{.i32};
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.tee", .payload = 0 });
    // After tee, vreg0 still on stack. end consumes it.
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = try liveness.compute(testing.allocator, &f, &.{}, &.{}, &.{});
    defer if (f.liveness) |lv| liveness.deinit(testing.allocator, lv);
    const alloc = try regalloc.compute(testing.allocator, &f);
    defer regalloc.deinit(testing.allocator, alloc);
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(true);
    // STR XZR (zero-init) at body+0 — unchanged.
    try testing.expectEqual(@as(u32, inst.encStrImm(31, 31, 0)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    // body+4 = LDR W X9, [SP,#0] (homing prologue seed of the home reg).
    try testing.expectEqual(@as(u32, inst.encLdrImmW(9, 31, 0)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    // No STR-to-slot for the tee: assert the slot-0 store (encStrImmW(_,31,0))
    // appears ONLY once (the zero-init at body+0), not again for the tee.
    var slot0_stores: usize = 0;
    var i: usize = body0;
    while (i + 4 <= out.bytes.len) : (i += 4) {
        const w = std.mem.readInt(u32, out.bytes[i..][0..4], .little);
        if (w == inst.encStrImmW(9, 31, 0)) slot0_stores += 1;
    }
    try testing.expectEqual(@as(usize, 0), slot0_stores);
}

test "compile: i64.const small value emits single MOVZ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 42, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // Single MOVZ X9, #42 at body+0.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 42)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
}

test "compile: i64.const 0xCAFEBABEDEADBEEF emits MOVZ + 3 MOVK lanes" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 0xCAFEBABEDEADBEEF: low_32=0xDEADBEEF, high_32=0xCAFEBABE.
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xDEADBEEF, .extra = 0xCAFEBABE });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // MOVZ #BEEF / MOVK #DEAD lsl 16 / MOVK #BABE lsl 32 / MOVK #CAFE lsl 48 at body+0,4,8,12.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0xBEEF)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0xDEAD, 1)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0xBABE, 2)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0xCAFE, 3)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
}

test "compile: f32.const emits emitConstU32 + FMOV S, W" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0f bits = 0x3F800000.
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP (8 bytes): MOVZ + MOVK (lo=0x0000, hi=0x3F80)
    // — but lo=0 so just MOVK fires? No wait: emitConstU32 always
    // emits MOVZ (low 16) and conditionally MOVK (high 16). For
    // 0x3F800000: low 16 = 0x0000, high 16 = 0x3F80. MOVZ #0; MOVK
    // #0x3F80 lsl 16; FMOV S16, W9.
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0x3F80, 1)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst_fp.encFmovStoFromW(16, 9)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    // end with f32 result → FMOV S0, S16 = 0x1E204000 | (16<<5) = 0x1E204200.
    try testing.expectEqual(@as(u32, 0x1E204200), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
}

// AAPCS64 stack-arg lowering on the callee side.
// Prologue accepts > 7 params by loading the overflow args from
// `[X29, #(16 + 8*K)]` (K = 0-based NSAA index) into the local
// slot at `[SP, #(p_idx*8)]`. Caller-side stack-arg marshal
// remains capped at the marshalCallArgs `arg_vregs[8]` limit
// (chunk d-8 will lift that with FP-relative spill addressing).

test "compile: function with 8 i32 params lowers param[7] from caller stack" {
    // 8 i32 params: X1..X7 hold params 0..6 (7 regs), param 7
    // overflows to caller stack at [X29, #16].
    const params = [_]zir.ValType{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 };
    const sig: zir.FuncType = .{ .params = &params, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // Body: `(i32.const 0) end` — exercises only the prologue's
    // param-marshal sequence; body / result marshalling unchanged.
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Locate the LDR W16, [X29, #16] / STR W16, [SP, #56] pair
    // — the overflow load for param 7 (8th param, p_idx = 7,
    // local slot 7 lives at [SP+56]).
    const ldr_w16 = inst.encLdrImmW(16, 29, 16);
    const str_w16 = inst.encStrImmW(16, 31, 56);
    var found: bool = false;
    var i: usize = 0;
    while (i + 8 <= out.bytes.len) : (i += 4) {
        const a = std.mem.readInt(u32, out.bytes[i..][0..4], .little);
        const b = std.mem.readInt(u32, out.bytes[i + 4 ..][0..4], .little);
        if (a == ldr_w16 and b == str_w16) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (param i64) — prologue stores X1 to [SP, #0] (STR X width)" {
    const params = [_]zir.ValType{.i64};
    const sig: zir.FuncType = .{ .params = &params, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // Body is just `(i32.const 0) end` — exercises only the
    // prologue's STR X for the param; result-type marshalling is
    // outside this chunk's scope.
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // STR X1, [SP, #0] for the i64 param at byte 36 (post-
    // prologue with frame). encStrImm width-X vs encStrImmW.
    const expected_str_x = inst.encStrImm(1, 31, 0);
    try testing.expectEqual(expected_str_x, std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true)..][0..4], .little));
}

test "compile: (param f32) — prologue stores S0 to [SP, #0] (STR S width)" {
    const params = [_]zir.ValType{.f32};
    const sig: zir.FuncType = .{ .params = &params, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const expected = inst.encStrSImm(0, 31, 0);
    try testing.expectEqual(expected, std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true)..][0..4], .little));
}

test "compile: (param f64) — prologue stores D0 to [SP, #0] (STR D width)" {
    const params = [_]zir.ValType{.f64};
    const sig: zir.FuncType = .{ .params = &params, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const expected = inst.encStrDImm(0, 31, 0);
    try testing.expectEqual(expected, std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true)..][0..4], .little));
}

test "compile: mixed (param i32 f32 i64 f64) — independent X/V counters" {
    const params = [_]zir.ValType{ .i32, .f32, .i64, .f64 };
    const sig: zir.FuncType = .{ .params = &params, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Param marshalling at byte 36 (post-prologue):
    //   STR W1, [SP, #0]   (i32 → X int_arg=1)
    //   STR S0, [SP, #8]   (f32 → V fp_arg=0)
    //   STR X2, [SP, #16]  (i64 → X int_arg=2)
    //   STR D1, [SP, #24]  (f64 → V fp_arg=1)
    try testing.expectEqual(inst.encStrImmW(1, 31, 0), std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true)..][0..4], .little));
    try testing.expectEqual(inst.encStrSImm(0, 31, 8), std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true) + 4 ..][0..4], .little));
    try testing.expectEqual(inst.encStrImm(2, 31, 16), std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true) + 8 ..][0..4], .little));
    try testing.expectEqual(inst.encStrDImm(1, 31, 24), std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true) + 12 ..][0..4], .little));
}

test "compile: (param i32) (result i32) local.get 0 — prologue stores W1 to [SP, #0]" {
    const params = [_]zir.ValType{.i32};
    const sig: zir.FuncType = .{ .params = &params, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Prologue (has_frame=true): bytes 0..36 standard. Then
    // multi-arg STR W1, [SP, #0] at byte 36 (4 bytes). Body
    // starts at byte 40.
    const expected_str = inst.encStrImmW(1, 31, 0);
    try testing.expectEqual(expected_str, std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true)..][0..4], .little));
    // Body: LDR W into the param's vreg (slot 0 → W9 by AAPCS64
    // allocatable pool ordering).
    const expected_ldr = inst.encLdrImmW(9, 31, 0);
    try testing.expectEqual(expected_ldr, std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true) + 4 ..][0..4], .little));
}

test "compile: (param i32 i32) — prologue stores W1, W2 to [SP, #0], [SP, #8]" {
    const params = [_]zir.ValType{ .i32, .i32 };
    const sig: zir.FuncType = .{ .params = &params, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // STR W1, [SP, #0] at byte 36; STR W2, [SP, #8] at byte 40.
    try testing.expectEqual(inst.encStrImmW(1, 31, 0), std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true)..][0..4], .little));
    try testing.expectEqual(inst.encStrImmW(2, 31, 8), std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true) + 4 ..][0..4], .little));
    // Body LDR for local.get 1 → reads from [SP, #8].
    try testing.expectEqual(inst.encLdrImmW(9, 31, 8), std.mem.readInt(u32, out.bytes[prologue.body_start_offset(true) + 8 ..][0..4], .little));
}

test "compile: ADR-0018 sub-1c — i32.const into spilled vreg, full round-trip via STR + LDR" {
    // Force vreg 0 into spill territory (slot 10). The frame
    // extends by spillBytes() = 8; spill base offset = 0
    // (no locals). i32.const handler emits MOVZ X14 #42 + STR
    // X14, [SP, #0]. end handler emits LDR X14, [SP, #0] + MOV
    // X0, X14. Inspect bytes for these key instructions.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{10};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 11,
        .max_reg_slots_gpr = 10,
    };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Bytes contain (in order): STP+MOVfp + SUB sp,#16 (frame
    // rounded up to 16) + MOVZ X14,#42 + STR X14,[SP] + ORR X0,XZR,X14
    // + ADD sp,#16 + LDP + RET.
    const expected_movz = inst.encMovzImm16(14, 42);
    const expected_str = inst.encStrImm(14, 31, 0);
    const expected_ldr_at_end = inst.encLdrImm(14, 31, 0);

    var saw_movz = false;
    var saw_str = false;
    var saw_ldr_at_end = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        const w = std.mem.readInt(u32, out.bytes[p..][0..4], .little);
        if (w == expected_movz) saw_movz = true;
        if (w == expected_str) saw_str = true;
        if (w == expected_ldr_at_end) saw_ldr_at_end = true;
    }
    try testing.expect(saw_movz);
    try testing.expect(saw_str);
    try testing.expect(saw_ldr_at_end);
}

test "compile: ADR-0018 — slot 9 = last reg (X23), slot 10 = first spill" {
    const slots_9 = [_]u16{9};
    const alloc_reg: regalloc.Allocation = .{
        .slots = &slots_9,
        .n_slots = 10,
        .max_reg_slots_gpr = 10,
    };
    try testing.expectEqual(regalloc.Slot{ .reg = 9 }, alloc_reg.slot(0, .gpr));

    const slots_10 = [_]u16{10};
    const alloc_spill: regalloc.Allocation = .{
        .slots = &slots_10,
        .n_slots = 11,
        .max_reg_slots_gpr = 10,
    };
    try testing.expectEqual(regalloc.Slot{ .spill = 0 }, alloc_spill.slot(0, .gpr));
}
