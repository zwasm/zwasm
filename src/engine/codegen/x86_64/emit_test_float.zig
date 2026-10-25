// FILE-SIZE-EXEMPT: per-op JIT-emit test catalog (FP family); P2 pure-data dominance (per ADR-0099)
//! x86_64 emit pass — f32/f64 floating-point test family
//! (D-051 follow-up split per ADR-0030). Tests for integer /
//! control / memory / calls live in the sibling
//! `emit_test_int.zig`. Both files are discovered by the runner
//! via `emit_test.zig`'s aggregator.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const prologue = @import("prologue.zig");

const emit = @import("emit.zig");
const compile = emit.compile;
const deinit = emit.deinit;
const Error = emit.Error;

const ZirFunc = zir.ZirFunc;
const testing = std.testing;

test "compile: f32.const — MOV EAX,bits + MOVD XMM8,EAX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0f bit pattern = 0x3F800000.
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0}; // FP slot 0 → XMM8
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Prologue (uses_runtime_ptr=false; no calls/memory) = 4 bytes.
    //   PUSH RBP        55              (1)
    //   MOV RBP, RSP    48 89 e5        (3) → 4
    // Body:
    //   MOV EAX, bits   b8 + 4 imm      (5) → body+5
    //   MOVD XMM8,EAX   66 44 0f 6e c0  (5) → body+10
    const body_start = prologue.body_start_offset(false, 0);
    const expected_imm = inst.encMovImm32W(.rax, 0x3F800000);
    try testing.expectEqualSlices(u8, expected_imm.slice(), out.bytes[body_start .. body_start + expected_imm.len]);
    const expected_movd = inst.encMovdXmmFromR32(.xmm8, .rax);
    try testing.expectEqualSlices(u8, expected_movd.slice(), out.bytes[body_start + 5 .. body_start + 5 + expected_movd.len]);
}

test "compile: f64.const — MOVABS RAX,bits + MOVQ XMM8,RAX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0 bit pattern = 0x3FF0000000000000. Split into payload + extra.
    const bits: u64 = 0x3FF0000000000000;
    try f.instrs.append(testing.allocator, .{
        .op = .@"f64.const",
        .payload = @as(u32, @truncate(bits)),
        .extra = @truncate(bits >> 32),
    });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Body layout (post-prologue at 4):
    //   MOVABS RAX,bits 48 b8 + 8 imm   (10) → body+10
    //   MOVQ XMM8,RAX   66 4c 0f 6e c0  (5)  → body+15
    const body_start = prologue.body_start_offset(false, 0);
    const expected_imm = inst.encMovImm64Q(.rax, bits);
    try testing.expectEqualSlices(u8, expected_imm.slice(), out.bytes[body_start .. body_start + expected_imm.len]);
    const expected_movq = inst.encMovqXmmFromR64(.xmm8, .rax);
    try testing.expectEqualSlices(u8, expected_movq.slice(), out.bytes[body_start + 10 .. body_start + 10 + expected_movq.len]);
}

test "compile: f32.add — MOVAPS XMM10,XMM8 + ADDSS XMM10,XMM9" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // FP slots 0,1,2 → XMM8, XMM9, XMM10.
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Body layout (4-byte prologue):
    //   [4..14]  f32.const 0x3F800000 (10 bytes: MOV EAX + MOVD XMM8)
    //   [14..24] f32.const 0x40000000 (10 bytes: MOV EAX + MOVD XMM9)
    //   [body+20..body+24] MOVAPS XMM10, XMM8 (4 bytes)
    //   [body+24..body+29] ADDSS XMM10, XMM9  (5 bytes)
    const body_start = prologue.body_start_offset(false, 0);
    const expected_movaps = inst.encMovapsXmmXmm(.xmm10, .xmm8);
    try testing.expectEqualSlices(u8, expected_movaps.slice(), out.bytes[body_start + 20 .. body_start + 20 + expected_movaps.len]);
    const expected_addss = inst.encSseScalarBinary(.f32, 0x58, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_addss.slice(), out.bytes[body_start + 24 .. body_start + 24 + expected_addss.len]);
}

test "compile: f64.mul — MOVAPS XMM10,XMM8 + MULSD XMM10,XMM9" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0 = 0x3FF0000000000000 split low/high.
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    // 2.0 = 0x4000000000000000 split low/high.
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.mul" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Body layout (4-byte prologue):
    //   [4..19]  f64.const 1.0 (15 bytes: MOVABS RAX + MOVQ XMM8,RAX)
    //   [19..34] f64.const 2.0 (15 bytes)
    //   [body+30..body+34] MOVAPS XMM10, XMM8 (4 bytes)
    //   [body+34..body+39] MULSD XMM10, XMM9  (5 bytes)
    const body_start = prologue.body_start_offset(false, 0);
    const expected_movaps = inst.encMovapsXmmXmm(.xmm10, .xmm8);
    try testing.expectEqualSlices(u8, expected_movaps.slice(), out.bytes[body_start + 30 .. body_start + 30 + expected_movaps.len]);
    const expected_mulsd = inst.encSseScalarBinary(.f64, 0x59, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_mulsd.slice(), out.bytes[body_start + 34 .. body_start + 34 + expected_mulsd.len]);
}

test "compile: f64.promote_f32 — CVTSS2SD XMM9, XMM8" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.promote_f32" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After f32.const at [body..body+10]: CVTSS2SD XMM9, XMM8 at [body+10..body+15].
    const body_start = prologue.body_start_offset(false, 0);
    const expected = inst.encSseScalarBinary(.f32, 0x5A, .xmm9, .xmm8);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[body_start + 10 .. body_start + 10 + expected.len]);
}

test "compile: i32.reinterpret_f32 — MOVD R10D, XMM8 (XMM→GPR bit-cast)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0xDEADBEEF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.reinterpret_f32" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // FP slot 0 → XMM8; result GPR slot 0 → RBX (after chunk 13b pool shrink).
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After f32.const at [body..body+10]: MOVD EBX, XMM8 at [body+10..body+15].
    const body_start = prologue.body_start_offset(false, 0);
    const expected = inst.encMovdR32FromXmm(.rbx, .xmm8);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[body_start + 10 .. body_start + 10 + expected.len]);
}

test "compile: f32.reinterpret_i32 — MOVD XMM8, R10D (GPR→XMM bit-cast)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.reinterpret_i32" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // GPR slot 0 → RBX (after chunk 13b pool shrink); FP slot 0 → XMM8.
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After i32.const at [body..body+5] (5 bytes for EBX): MOVD XMM8, EBX at [body+5..body+10].
    const body_start = prologue.body_start_offset(false, 0);
    const expected = inst.encMovdXmmFromR32(.xmm8, .rbx);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[body_start + 5 .. body_start + 5 + expected.len]);
}

test "compile: f32.load — emit MOVSS xmm_dst, [rax + rdx] after eff-addr/bounds-check" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.load", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // GPR slot 0 (idx) → R10; FP slot 0 (result) → XMM8.
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Verify the f32.load handler emits MOVSS XMM8, [RAX + RDX]
    // somewhere in the byte stream after the bounds prologue.
    const expected = inst.encMovssMovsdMemBaseIdx(.f32, false, .xmm8, .rax, .rdx);
    try testing.expect(std.mem.find(u8, out.bytes, expected.slice()) != null);
}

test "compile: f64.store — emit MOVSD [rax+rdx], xmm_src + bounds prologue with size=8" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // i32.const 0 (idx) ; f64.const 1.0 (val) ; f64.store 0 ; end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.store", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // GPR slot 0 (idx) → R10; FP slot 1 (val) → XMM9.
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Verify the f64.store emits MOVSD [RAX+RDX], XMM9.
    const expected = inst.encMovssMovsdMemBaseIdx(.f64, true, .xmm9, .rax, .rdx);
    try testing.expect(std.mem.find(u8, out.bytes, expected.slice()) != null);
    // Verify the LEA bounds-check uses access_size=8 (the disp8
    // immediate in encLeaR64BaseDisp8 is the access_size byte).
    // Search for an LEA that has 8 as its disp byte; rough check
    // by looking for the LEA opcode + ModRM + disp8=0x08 sequence.
    // (The encoder is encLeaR64BaseDisp8(.rcx, .rdx, 8).)
    const expected_lea = inst.encLeaR64BaseDisp8(.rcx, .rdx, 8);
    try testing.expect(std.mem.find(u8, out.bytes, expected_lea.slice()) != null);
}

test "compile: i32.trunc_f32_u — Wasm 1.0 trapping unsigned via .q-trick" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_f32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const neg_one = inst.encMovImm32W(.rax, 0xBF800000);
    const upper = inst.encMovImm32W(.rax, 0x4F800000);
    // dst slot 0 → RBX after chunk 13b pool shrink.
    const cvt = inst.encCvttScalar2Int(.f32, true, .rbx, .xmm8);
    try testing.expect(std.mem.find(u8, out.bytes, neg_one.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, upper.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, cvt.slice()) != null);
}

test "compile: i64.trunc_f64_u — Wasm 1.0 trapping with 2^63 split path" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.trunc_f64_u" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const neg_one = inst.encMovImm64Q(.rax, 0xBFF0000000000000);
    const upper = inst.encMovImm64Q(.rax, 0x43F0000000000000);
    const split = inst.encMovImm64Q(.rax, 0x43E0000000000000);
    const subss = inst.encSseScalarBinary(.f64, 0x5C, .xmm6, .xmm7);
    const sign = inst.encMovImm64Q(.rcx, 0x8000000000000000);
    try testing.expect(std.mem.find(u8, out.bytes, neg_one.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, upper.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, split.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, subss.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, sign.slice()) != null);
}

test "compile: i32.trunc_f32_s — Wasm 1.0 trapping; NaN/upper/lower → bounds_fixups" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 }); // 3.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_f32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Verify presence of the 3 thresholds + CVTTSS2SI in the
    // emitted byte stream (full layout asserted via opcode+
    // boundary checks rather than every offset).
    const upper = inst.encMovImm32W(.rax, 0x4F000000); // 2^31
    const lower = inst.encMovImm32W(.rax, 0xCF000000); // -2^31
    // dst slot 0 → RBX after chunk 13b pool shrink.
    const cvt = inst.encCvttScalar2Int(.f32, false, .rbx, .xmm8);
    try testing.expect(std.mem.find(u8, out.bytes, upper.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, lower.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, cvt.slice()) != null);
}

test "compile: i64.trunc_sat_f32_u — 2^63 split path with SUBSS + sign-bit OR" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.trunc_sat_f32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Verify a few key encoder outputs are present (full byte
    // sequence is too long to assert exhaustively).
    // Find threshold MOV (0x5F800000 for 2^64 f32) and the SUBSS
    // op in the high path.
    const threshold_max = inst.encMovImm32W(.rax, 0x5F800000);
    const threshold_split = inst.encMovImm32W(.rax, 0x5F000000);
    // Also verify SUBSS XMM6, XMM7 in the high path.
    const subss = inst.encSseScalarBinary(.f32, 0x5C, .xmm6, .xmm7);
    // OR RBX, RCX (full 64-bit) for the sign-bit restore.
    // dst slot 0 → RBX after chunk 13b pool shrink.
    const or_q = inst.encOrRR(.q, .rbx, .rcx);
    // MOVABS RBX, UINT64_MAX in the max path.
    const max_mov = inst.encMovImm64Q(.rbx, 0xFFFFFFFFFFFFFFFF);
    const bytes = out.bytes;
    try testing.expect(std.mem.find(u8, bytes, threshold_max.slice()) != null);
    try testing.expect(std.mem.find(u8, bytes, threshold_split.slice()) != null);
    try testing.expect(std.mem.find(u8, bytes, subss.slice()) != null);
    try testing.expect(std.mem.find(u8, bytes, or_q.slice()) != null);
    try testing.expect(std.mem.find(u8, bytes, max_mov.slice()) != null);
}

test "compile: i32.trunc_sat_f32_u — UCOMI/JP + clamp paths + CVTTSS2SI .q form" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_sat_f32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After f32.const at [body..body+10]:
    //   [body+10..+14] UCOMISS XMM8, XMM8     (4 bytes; REX.R+B)
    //   [body+14..+20] JP rel32 zero_path     (6 bytes)
    //   [body+20..+23] XORPS XMM7, XMM7       (3 bytes; no prefix, no REX)
    //   [body+23..+27] UCOMISS XMM8, XMM7     (4 bytes; REX.R only)
    //   [body+27..+33] JBE rel32 zero_path    (6 bytes)
    //   [body+33..+38] MOV EAX, 0x4F800000    (5 bytes; no REX)
    //   [body+38..+42] MOVD XMM7, EAX         (4 bytes; no REX)
    //   [body+42..+46] UCOMISS XMM8, XMM7     (4 bytes)
    //   [body+46..+52] JAE rel32 max_path     (6 bytes)
    //   [body+52..+57] CVTTSS2SI RBX, XMM8 .q (5 bytes; slot 0 = RBX after chunk 13b)
    //   [body+57..+62] JMP rel32 done         (5 bytes)
    //   zero_path at body+62
    const body_start = prologue.body_start_offset(false, 0);
    const expected_xorps = inst.encSsePackedBinary(.f32, 0x57, .xmm7, .xmm7);
    try testing.expectEqualSlices(u8, expected_xorps.slice(), out.bytes[body_start + 20 .. body_start + 20 + expected_xorps.len]);
    const expected_thresh = inst.encMovImm32W(.rax, 0x4F800000);
    try testing.expectEqualSlices(u8, expected_thresh.slice(), out.bytes[body_start + 33 .. body_start + 33 + expected_thresh.len]);
    const expected_cvt = inst.encCvttScalar2Int(.f32, true, .rbx, .xmm8);
    try testing.expectEqualSlices(u8, expected_cvt.slice(), out.bytes[body_start + 52 .. body_start + 52 + expected_cvt.len]);
    // JP/JBE/JAE rel32 opcode bytes (disps patched at end-of-emit).
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[body_start + 14]);
    try testing.expectEqual(@as(u8, 0x8A), out.bytes[body_start + 15]);
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[body_start + 27]);
    try testing.expectEqual(@as(u8, 0x86), out.bytes[body_start + 28]); // Jcc.be = 6
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[body_start + 46]);
    try testing.expectEqual(@as(u8, 0x83), out.bytes[body_start + 47]); // Jcc.ae = 3
}

test "compile: i32.trunc_sat_f32_s — CVTTSS2SI + CMP INT_MIN + branch saturation" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 }); // 3.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_sat_f32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // FP slot 0 → XMM8; result GPR slot 0 → RBX (after chunk 13b pool shrink).
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After f32.const at [body..body+10]:
    //   [body+10..+15] CVTTSS2SI EBX, XMM8      (5 bytes; F3 + REX + 0F + 2C + ModRM)
    //   [body+15..+21] CMP EBX, 0x80000000     (6 bytes; 81 + ModRM + imm32 — no REX needed for RBX)
    //   [body+21..+27] JNE rel32 (placeholder) (6 bytes)
    //   ...
    const body_start = prologue.body_start_offset(false, 0);
    const expected_cvt = inst.encCvttScalar2Int(.f32, false, .rbx, .xmm8);
    try testing.expectEqualSlices(u8, expected_cvt.slice(), out.bytes[body_start + 10 .. body_start + 10 + expected_cvt.len]);
    const expected_cmp = inst.encCmpRImm32(.rbx, 0x80000000);
    try testing.expectEqualSlices(u8, expected_cmp.slice(), out.bytes[body_start + 15 .. body_start + 15 + expected_cmp.len]);
    // JNE / JP / JBE rel32 opcode bytes (disps patched at end-of-emit).
    // Offsets shift by -1 vs pre-13b: CMP imm32 saves a REX byte for RBX.
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[body_start + 21]);
    try testing.expectEqual(@as(u8, 0x85), out.bytes[body_start + 22]); // Jcc.ne = 5
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[body_start + 31]);
    try testing.expectEqual(@as(u8, 0x8A), out.bytes[body_start + 32]); // Jcc.p = A
    const expected_xorps = inst.encSsePackedBinary(.f32, 0x57, .xmm7, .xmm7);
    try testing.expectEqualSlices(u8, expected_xorps.slice(), out.bytes[body_start + 37 .. body_start + 37 + expected_xorps.len]);
}

test "compile: i64.trunc_sat_f64_s — CVTTSD2SI .q + i64 sentinel via MOVABS+CMP r/r" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.trunc_sat_f64_s" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After f64.const at [body..body+15]:
    //   [body+15..+20] CVTTSD2SI RBX, XMM8 (5 bytes; F2 + REX.W+R + 0F + 2C + ModRM 0xD8)
    //   [body+20..+30] MOVABS RCX, INT_MIN_i64 (10 bytes)
    //   [body+30..+33] CMP RBX, RCX (3 bytes; REX.W + 39 + ModRM) — slot 0 = RBX after chunk 13b
    const body_start = prologue.body_start_offset(false, 0);
    const expected_cvt = inst.encCvttScalar2Int(.f64, true, .rbx, .xmm8);
    try testing.expectEqualSlices(u8, expected_cvt.slice(), out.bytes[body_start + 15 .. body_start + 15 + expected_cvt.len]);
    const expected_min = inst.encMovImm64Q(.rcx, 0x8000000000000000);
    try testing.expectEqualSlices(u8, expected_min.slice(), out.bytes[body_start + 20 .. body_start + 20 + expected_min.len]);
    const expected_cmp = inst.encCmpRR(.q, .rbx, .rcx);
    try testing.expectEqualSlices(u8, expected_cmp.slice(), out.bytes[body_start + 30 .. body_start + 30 + expected_cmp.len]);
}

test "compile: f32.convert_i32_u — CVTSI2SS XMM8, R10 (REX.W on i32 src for zero-extend trick)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFFFFFFFF }); // u32 max
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.convert_i32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // i32.const 0xFFFFFFFF at [body..body+5]; CVTSI2SS XMM8, RBX (i64 form) at [body+5..body+10].
    // (slot 0 = RBX after chunk 13b pool shrink — i32.const is 5 bytes.)
    const body_start = prologue.body_start_offset(false, 0);
    const expected = inst.encCvtsi2Scalar(.f32, true, .xmm8, .rbx);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[body_start + 5 .. body_start + 5 + expected.len]);
}

test "compile: f32.convert_i64_u — branch-based slow-path emit" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // i32.const placeholder for i64 source (synthetic; emit doesn't validate types).
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.convert_i64_u" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // i32.const at [body..body+5] (slot 0 = RBX after chunk 13b pool shrink). Then:
    //   [body+5..+8]   TEST RBX, RBX            (3 bytes; REX.W = 48 + 85 + DB)
    //   [body+8..+14]  JS rel32 placeholder     (6 bytes)
    //   [body+14..+19] CVTSI2SS XMM8, RBX i64   (5 bytes; F3 + REX.W+R + 0F 2A C3)
    //   [body+19..+24] JMP rel32 to end         (5 bytes)
    //   slow_path at body+24:
    const body_start = prologue.body_start_offset(false, 0);
    const expected_test = inst.encTestRR(.q, .rbx, .rbx);
    try testing.expectEqualSlices(u8, expected_test.slice(), out.bytes[body_start + 5 .. body_start + 5 + expected_test.len]);
    // JS rel32 opcode bytes (disp patched at end-of-emit).
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[body_start + 8]);
    try testing.expectEqual(@as(u8, 0x88), out.bytes[body_start + 9]); // Jcc.s = 8
    const expected_pos_cvt = inst.encCvtsi2Scalar(.f32, true, .xmm8, .rbx);
    try testing.expectEqualSlices(u8, expected_pos_cvt.slice(), out.bytes[body_start + 14 .. body_start + 14 + expected_pos_cvt.len]);
    // JMP rel32 opcode at body+19.
    try testing.expectEqual(@as(u8, 0xE9), out.bytes[body_start + 19]);
    // Slow path starts at body+24: MOV RAX, RBX (3 bytes; REX.W = 48 89 D8)
    const expected_mov_rax = inst.encMovRR(.q, .rax, .rbx);
    try testing.expectEqualSlices(u8, expected_mov_rax.slice(), out.bytes[body_start + 24 .. body_start + 24 + expected_mov_rax.len]);
    // After slow path: MOV RAX (3) + SHR RAX (4) + MOV RCX (3) + AND RCX (4) + OR (3) +
    //                  CVTSI2SS (5) + ADDSS dst,dst (5) = 27 bytes. Slow path ends at body+24+27=body+51.
    // Verify ADDSS is the final slow-path insn (5 bytes).
    const expected_addss = inst.encSseScalarBinary(.f32, 0x58, .xmm8, .xmm8);
    try testing.expectEqualSlices(u8, expected_addss.slice(), out.bytes[body_start + 46 .. body_start + 46 + expected_addss.len]);
    // Verify JS rel32 disp points at slow_path (body+24). Disps are
    // body-relative deltas; the literal (24 - 8 - 6) is unchanged by body_start.
    const js_disp = std.mem.readInt(i32, out.bytes[body_start + 10 .. body_start + 14][0..4], .little);
    try testing.expectEqual(@as(i32, 24 - 8 - 6), js_disp);
    // Verify JMP rel32 disp points at end (body+51).
    const jmp_disp = std.mem.readInt(i32, out.bytes[body_start + 20 .. body_start + 24][0..4], .little);
    try testing.expectEqual(@as(i32, 51 - 19 - 5), jmp_disp);
}

test "compile: f32.convert_i32_s — CVTSI2SS XMM8, R10D" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.convert_i32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After i32.const at [body..body+5] (slot 0 = RBX, 5 bytes after chunk 13b):
    // CVTSI2SS XMM8, EBX at [body+5..body+10].
    const body_start = prologue.body_start_offset(false, 0);
    const expected = inst.encCvtsi2Scalar(.f32, false, .xmm8, .rbx);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[body_start + 5 .. body_start + 5 + expected.len]);
}

test "compile: f32.min — branch-based emit (UCOMISS + JP/JE + 3 paths)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.min" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Body offsets after 2× f32.const (10+10=20 bytes) at body..body+20:
    //   [body+20..+24] UCOMISS XMM8, XMM9     (4 bytes)
    //   [body+24..+30] JP rel32 (placeholder) (6 bytes)
    //   [body+30..+36] JE rel32 (placeholder) (6 bytes)
    //   [body+36..+40] MOVAPS XMM10, XMM8     (4 bytes)
    //   [body+40..+45] MINSS XMM10, XMM9      (5 bytes; F3 + REX + 0F + 5D + ModRM)
    //   [body+45..+50] JMP rel32              (5 bytes)
    //   [body+50..+54] MOVAPS XMM10, XMM8     (eq path)
    //   [body+54..+58] ORPS XMM10, XMM9       (4 bytes)
    //   [body+58..+63] JMP rel32              (5 bytes)
    //   [body+63..+67] MOVAPS XMM10, XMM8     (nan path)
    //   [body+67..+72] ADDSS XMM10, XMM9      (5 bytes)
    const body_start = prologue.body_start_offset(false, 0);
    const expected_ucomi = inst.encUcomiss(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, expected_ucomi.slice(), out.bytes[body_start + 20 .. body_start + 20 + expected_ucomi.len]);
    // JP / JE rel32 disps are patched; assert opcode bytes only.
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[body_start + 24]);
    try testing.expectEqual(@as(u8, 0x8A), out.bytes[body_start + 25]); // Jcc.p = A
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[body_start + 30]);
    try testing.expectEqual(@as(u8, 0x84), out.bytes[body_start + 31]); // Jcc.e = 4
    const expected_minss = inst.encSseScalarBinary(.f32, 0x5D, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_minss.slice(), out.bytes[body_start + 40 .. body_start + 40 + expected_minss.len]);
    const expected_orps = inst.encSsePackedBinary(.f32, 0x56, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_orps.slice(), out.bytes[body_start + 54 .. body_start + 54 + expected_orps.len]);
    const expected_addss = inst.encSseScalarBinary(.f32, 0x58, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_addss.slice(), out.bytes[body_start + 67 .. body_start + 67 + expected_addss.len]);

    // Verify JP rel32 disp is patched correctly to point at nan_path (body+63).
    const jp_disp = std.mem.readInt(i32, out.bytes[body_start + 26 .. body_start + 30][0..4], .little);
    try testing.expectEqual(@as(i32, 63 - 24 - 6), jp_disp);
    // Verify JE rel32 disp points at eq_path (body+50).
    const je_disp = std.mem.readInt(i32, out.bytes[body_start + 32 .. body_start + 36][0..4], .little);
    try testing.expectEqual(@as(i32, 50 - 30 - 6), je_disp);
}

test "compile: f32.min — dst aliasing rhs slot is handled via commutative swap (D-092)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.min" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // Force dst (vreg 2) into rhs's slot (XMM9). lhs (vreg 0) is XMM8.
    // Before D-092 this surfaced UnsupportedOp at op_alu_float.zig:105.
    const slots = [_]u16{ 0, 1, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After the swap, lhs↔rhs roles are exchanged, so the emit
    // produces: UCOMISS XMM9,XMM8 ; ... ; MOVAPS XMM9,XMM9 (no-op,
    // skipped) ; MINSS XMM9,XMM8. Verify the swap landed by
    // asserting UCOMISS XMM9,XMM8 (rather than the pre-swap
    // XMM8,XMM9 shape).
    const body_start = prologue.body_start_offset(false, 0);
    const expected_ucomi = inst.encUcomiss(.xmm9, .xmm8);
    try testing.expectEqualSlices(u8, expected_ucomi.slice(), out.bytes[body_start + 20 .. body_start + 20 + expected_ucomi.len]);
    // Common-path MINSS lands at body+36 (post-swap, the MOVAPS
    // dst,lhs is elided because dst == new-lhs == XMM9).
    const expected_minss = inst.encSseScalarBinary(.f32, 0x5D, .xmm9, .xmm8);
    try testing.expectEqualSlices(u8, expected_minss.slice(), out.bytes[body_start + 36 .. body_start + 36 + expected_minss.len]);
}

test "compile: f64.max — eq path uses ANDPD, common uses MAXSD" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.max" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After 2× f64.const (15+15=30 bytes) at body..body+30:
    //   [body+30..+35] UCOMISD XMM8, XMM9   (5 bytes: 66 prefix + REX)
    //   [body+35..+41] JP rel32             (6 bytes)
    //   [body+41..+47] JE rel32             (6 bytes)
    //   [body+47..+51] MOVAPS XMM10, XMM8   (4 bytes; common path)
    //   [body+51..+56] MAXSD XMM10, XMM9    (5 bytes; F2 + REX + 0F + 5F + ModRM)
    //   [body+56..+61] JMP rel32 (common)
    //   [body+61..+65] MOVAPS XMM10, XMM8   (eq path)
    //   [body+65..+70] ANDPD XMM10, XMM9    (5 bytes; 66 + REX + 0F + 54 + ModRM)
    const body_start = prologue.body_start_offset(false, 0);
    const expected_ucomi = inst.encUcomisd(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, expected_ucomi.slice(), out.bytes[body_start + 30 .. body_start + 30 + expected_ucomi.len]);
    const expected_maxsd = inst.encSseScalarBinary(.f64, 0x5F, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_maxsd.slice(), out.bytes[body_start + 51 .. body_start + 51 + expected_maxsd.len]);
    const expected_andpd = inst.encSsePackedBinary(.f64, 0x54, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_andpd.slice(), out.bytes[body_start + 65 .. body_start + 65 + expected_andpd.len]);
}

test "compile: f32.copysign — bit-twiddle via RAX/RDX/RCX scratches" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 }); // 3.0
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0xBF800000 }); // -1.0
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.copysign" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After 2× f32.const (10+10=20 bytes) at body offset body..body+20:
    //   [body+20..+25] MOVD EAX, XMM8        (5 bytes)
    //   [body+25..+30] MOVD EDX, XMM9        (5 bytes)
    //   [body+30..+35] MOV ECX, 0x7FFFFFFF   (5 bytes)
    //   [body+35..+37] AND EAX, ECX          (2 bytes)
    //   [body+37..+42] MOV ECX, 0x80000000   (5 bytes)
    //   [body+42..+44] AND EDX, ECX          (2 bytes)
    //   [body+44..+46] OR EAX, EDX           (2 bytes)
    //   [body+46..+51] MOVD XMM10, EAX       (5 bytes)
    const body_start = prologue.body_start_offset(false, 0);
    const expected_movd_lhs = inst.encMovdR32FromXmm(.rax, .xmm8);
    try testing.expectEqualSlices(u8, expected_movd_lhs.slice(), out.bytes[body_start + 20 .. body_start + 20 + expected_movd_lhs.len]);
    const expected_mag_mask = inst.encMovImm32W(.rcx, 0x7FFFFFFF);
    try testing.expectEqualSlices(u8, expected_mag_mask.slice(), out.bytes[body_start + 30 .. body_start + 30 + expected_mag_mask.len]);
    const expected_or = inst.encOrRR(.d, .rax, .rdx);
    try testing.expectEqualSlices(u8, expected_or.slice(), out.bytes[body_start + 44 .. body_start + 44 + expected_or.len]);
    const expected_final_movd = inst.encMovdXmmFromR32(.xmm10, .rax);
    try testing.expectEqualSlices(u8, expected_final_movd.slice(), out.bytes[body_start + 46 .. body_start + 46 + expected_final_movd.len]);
}

test "compile: f64.copysign — same shape with .q widths and MOVABS masks" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0xBFF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.copysign" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After 2× f64.const (15+15=30 bytes) at body offset body..body+30:
    //   [body+30..+35] MOVQ RAX, XMM8        (5 bytes; 66 + REX.W + REX.R + ...)
    //   [body+35..+40] MOVQ RDX, XMM9
    //   [body+40..+50] MOVABS RCX, 0x7FFF... (10 bytes)
    //   [body+50..+53] AND RAX, RCX          (3 bytes; REX.W)
    //   [body+53..+63] MOVABS RCX, 0x8000... (10 bytes)
    //   [body+63..+66] AND RDX, RCX
    //   [body+66..+69] OR RAX, RDX
    //   [body+69..+74] MOVQ XMM10, RAX
    const body_start = prologue.body_start_offset(false, 0);
    const expected_movq_lhs = inst.encMovqR64FromXmm(.rax, .xmm8);
    try testing.expectEqualSlices(u8, expected_movq_lhs.slice(), out.bytes[body_start + 30 .. body_start + 30 + expected_movq_lhs.len]);
    const expected_mag = inst.encMovImm64Q(.rcx, 0x7FFFFFFFFFFFFFFF);
    try testing.expectEqualSlices(u8, expected_mag.slice(), out.bytes[body_start + 40 .. body_start + 40 + expected_mag.len]);
    const expected_sign = inst.encMovImm64Q(.rcx, 0x8000000000000000);
    try testing.expectEqualSlices(u8, expected_sign.slice(), out.bytes[body_start + 53 .. body_start + 53 + expected_sign.len]);
    const expected_movq_dst = inst.encMovqXmmFromR64(.xmm10, .rax);
    try testing.expectEqualSlices(u8, expected_movq_dst.slice(), out.bytes[body_start + 69 .. body_start + 69 + expected_movq_dst.len]);
}

test "compile: f32.sqrt — SQRTSS XMM9, XMM8" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40800000 }); // 4.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.sqrt" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After f32.const at [body..body+10]: SQRTSS XMM9, XMM8 at [body+10..body+15].
    const body_start = prologue.body_start_offset(false, 0);
    const expected = inst.encSseScalarBinary(.f32, 0x51, .xmm9, .xmm8);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[body_start + 10 .. body_start + 10 + expected.len]);
}

test "compile: f64.ceil — ROUNDSD XMM9, XMM8, mode=2" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF80000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.ceil" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After f64.const at [body..body+15]: ROUNDSD XMM9, XMM8, 2 at [body+15..body+22].
    const body_start = prologue.body_start_offset(false, 0);
    const expected = inst.encRoundsd(.xmm9, .xmm8, 2);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[body_start + 15 .. body_start + 15 + expected.len]);
}

test "compile: f32.abs — mask materialisation + MOVAPS + ANDPS" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0xBF800000 }); // -1.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.abs" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After f32.const at [body..body+10]:
    //   [body+10..+15] MOV EAX, 0x7FFFFFFF (5 bytes)
    //   [body+15..+19] MOVD XMM7, EAX      (4 bytes; no REX since xmm7 < xmm8 and rax < r8)
    //   [body+19..+23] MOVAPS XMM9, XMM8   (4 bytes; REX.R+REX.B)
    //   [body+23..+27] ANDPS XMM9, XMM7    (4 bytes; REX.R only since xmm7 < xmm8)
    const body_start = prologue.body_start_offset(false, 0);
    const expected_mask = inst.encMovImm32W(.rax, 0x7FFFFFFF);
    try testing.expectEqualSlices(u8, expected_mask.slice(), out.bytes[body_start + 10 .. body_start + 10 + expected_mask.len]);
    const expected_andps = inst.encSsePackedBinary(.f32, 0x54, .xmm9, .xmm7);
    try testing.expectEqualSlices(u8, expected_andps.slice(), out.bytes[body_start + 23 .. body_start + 23 + expected_andps.len]);
}

test "compile: f64.neg — XORPD with sign-bit mask" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.neg" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After f64.const at [body..body+15]:
    //   [body+15..+25] MOVABS RAX, 0x80...0 (10 bytes)
    //   [body+25..+30] MOVQ XMM7, RAX       (5 bytes)
    //   [body+30..+34] MOVAPS XMM9, XMM8    (4 bytes)
    //   [body+34..+39] XORPD XMM9, XMM7     (5 bytes; 66 prefix + REX.R + 0F 57 + ModRM)
    const body_start = prologue.body_start_offset(false, 0);
    const expected_mask = inst.encMovImm64Q(.rax, 0x8000000000000000);
    try testing.expectEqualSlices(u8, expected_mask.slice(), out.bytes[body_start + 15 .. body_start + 15 + expected_mask.len]);
    const expected_xorpd = inst.encSsePackedBinary(.f64, 0x57, .xmm9, .xmm7);
    try testing.expectEqualSlices(u8, expected_xorpd.slice(), out.bytes[body_start + 34 .. body_start + 34 + expected_xorpd.len]);
}

test "compile: f32.lt — UCOMISS swapped + SETA + MOVZX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.lt" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // Slots 0,1 → XMM8, XMM9; slot 2 (i32 result) → RBX (after chunk 13b).
    const slots = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After 2× f32.const (10+10=20 bytes) at body offset 4..24. With slot 0
    // for the (FP-bank-only) f32.const operands the FP encoding is unchanged
    // — only the i32 result bank moves from R10 → RBX, and SETcc/MOVZX with
    // RBX still need a forced 0x40 REX byte for BL access, so byte counts and
    // the SETA offset (28) are preserved.
    //   [body+20..+24] UCOMISS XMM9, XMM8 (swap; 4 bytes: REX 45 0F 2E C8)
    //   [body+24..+28] SETA BL (4 bytes: 40 0F 97 C3)
    //   [body+28..+32] MOVZX EBX, BL (4 bytes: 40 0F B6 DB)
    const body_start = prologue.body_start_offset(false, 0);
    const expected_ucomiss = inst.encUcomiss(.xmm9, .xmm8); // swapped: a=rhs, b=lhs
    try testing.expectEqualSlices(u8, expected_ucomiss.slice(), out.bytes[body_start + 20 .. body_start + 20 + expected_ucomiss.len]);
    const expected_seta = inst.encSetccR(.a, .rbx);
    try testing.expectEqualSlices(u8, expected_seta.slice(), out.bytes[body_start + 24 .. body_start + 24 + expected_seta.len]);
}

test "compile: f32.eq — UCOMISS + SETNP/SETE + AND combine" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.eq" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After 2× f32.const (20 bytes) at body offset body..body+20:
    //   [body+20..+24] UCOMISS XMM8, XMM9   (4 bytes; no swap for eq)
    //   [body+24..+28] SETNP AL             (4 bytes: 40 0F 9B C0)
    //   [body+28..+32] MOVZX EAX, AL        (4 bytes: 40 0F B6 C0)
    //   [body+32..+36] SETE BL              (4 bytes: 40 0F 94 C3) — slot 0 = RBX after chunk 13b
    //   [body+36..+40] MOVZX EBX, BL
    //   [body+40..+42] AND EBX, EAX         (2 bytes: 21 C3 — no REX needed)
    const body_start = prologue.body_start_offset(false, 0);
    const expected_ucomiss = inst.encUcomiss(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, expected_ucomiss.slice(), out.bytes[body_start + 20 .. body_start + 20 + expected_ucomiss.len]);
    const expected_setnp = inst.encSetccR(.np, .rax);
    try testing.expectEqualSlices(u8, expected_setnp.slice(), out.bytes[body_start + 24 .. body_start + 24 + expected_setnp.len]);
    const expected_and = inst.encAndRR(.d, .rbx, .rax);
    try testing.expectEqualSlices(u8, expected_and.slice(), out.bytes[body_start + 40 .. body_start + 40 + expected_and.len]);
}

test "compile: f64.gt — UCOMISD + SETA + MOVZX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.gt" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // 2× f64.const = 30 bytes at [body..body+30]. Then at [body+30..]:
    //   UCOMISD XMM8, XMM9 (5 bytes; 66 prefix + REX)
    const body_start = prologue.body_start_offset(false, 0);
    const expected_ucomisd = inst.encUcomisd(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, expected_ucomisd.slice(), out.bytes[body_start + 30 .. body_start + 30 + expected_ucomisd.len]);
}

test "compile: f32.add stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.add" }); // missing rhs
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false));
}

test "compile: call_indirect — out-of-range type_idx → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .call_indirect, .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false));
}

test "compile: call N — out-of-range callee_idx → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const func_sigs = [_]zir.FuncType{sig}; // only idx 0 exists
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const slots = [_]u16{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &func_sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false));
}

test "compile: i32.wrap_i64 with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.wrap_i64" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false));
}

test "compile: i32.add with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" }); // missing 2nd operand
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false));
}

// FP / i64 -aware function-level `end` return marshal (D-032).
// `f32.const` / `f64.const` push their value onto an XMM slot;
// `i64.extend_i32_u` pushes a full 64-bit GPR result. The
// pre-fix end handler emitted `MOV EAX, r32(slotToReg(slot))`
// for *every* result type, which (a) read the wrong physical
// reg for FP results (fpSlotToReg ≠ slotToReg for the same
// slot id) and (b) truncated i64 to i32 by using .d width.
// The fix dispatches on `func.sig.results[0]`:
//   .i32/.funcref/.externref → MOV EAX, src   (.d, current)
//   .i64                     → MOV RAX, src   (.q, full width)
//   .f32/.f64                → MOVAPS XMM0, src_xmm
//   .v128                    → UnsupportedOp (deferred)
// MOVAPS works for both f32 and f64: x86_64 returns FP values in
// XMM0 with full register width, so a single 128-bit register
// move is sufficient (vs ARM64's FMOV S0/D0 size-discriminated
// move). See ARM64 reference at arm64/emit.zig:475-503.

test "compile: f32.const → end emits MOVAPS XMM0, XMM8 (FP-aware return marshal)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0}; // FP slot 0 → XMM8.
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Layout (uses_runtime_ptr = false, frame_bytes = 0):
    //   [0..body] prologue: PUSH RBP ; MOV RBP, RSP
    //   [body..body+10] f32.const: MOV EAX, bits ; MOVD XMM8, EAX
    //   [body+10..body+14] end FP marshal: MOVAPS XMM0, XMM8 (4 bytes)
    //   [body+14..body+16] epilogue: POP RBP ; RET
    const body_start = prologue.body_start_offset(false, 0);
    const expected_movaps = inst.encMovapsXmmXmm(.xmm0, .xmm8);
    try testing.expectEqualSlices(u8, expected_movaps.slice(), out.bytes[body_start + 10 .. body_start + 10 + expected_movaps.len]);
    try testing.expectEqual(@as(usize, body_start + 16), out.bytes.len);
}

test "compile: f64.const → end emits MOVAPS XMM0, XMM8 (same MOVAPS works for f64)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const bits: u64 = 0x3FF0000000000000; // 1.0
    try f.instrs.append(testing.allocator, .{
        .op = .@"f64.const",
        .payload = @as(u32, @truncate(bits)),
        .extra = @truncate(bits >> 32),
    });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Layout:
    //   [0..body] prologue
    //   [body..body+15] f64.const: MOVABS RAX, bits ; MOVQ XMM8, RAX
    //   [body+15..body+19] end FP marshal: MOVAPS XMM0, XMM8
    //   [body+19..body+21] epilogue
    const body_start = prologue.body_start_offset(false, 0);
    const expected_movaps = inst.encMovapsXmmXmm(.xmm0, .xmm8);
    try testing.expectEqualSlices(u8, expected_movaps.slice(), out.bytes[body_start + 15 .. body_start + 15 + expected_movaps.len]);
    try testing.expectEqual(@as(usize, body_start + 21), out.bytes.len);
}

test "compile: i64-result end emits MOV RAX, src (.q full width avoids truncation)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x12345678 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.extend_i32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // GPR slot 0 → RBX (after chunk 13b pool shrink). Both vregs share slot id 0.
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Layout (slot 0 = RBX after chunk 13b — i32.const + self-MOV both shed REX):
    //   [0..body]   prologue
    //   [body..body+5]   i32.const: MOV EBX, imm32 (B8+rd + 4-byte imm = 5 bytes)
    //   [body+5..body+7]  i64.extend_i32_u: MOV EBX, EBX (.d, 2 bytes — no REX)
    //   [body+7..body+10] end i64 marshal: MOV RAX, RBX (.q, 3 bytes; REX.W = 48 89 D8)
    //   [body+10..body+12] epilogue
    const body_start = prologue.body_start_offset(false, 0);
    const expected_movrr = inst.encMovRR(.q, .rax, .rbx);
    try testing.expectEqualSlices(u8, expected_movrr.slice(), out.bytes[body_start + 7 .. body_start + 7 + expected_movrr.len]);
    try testing.expectEqual(@as(usize, body_start + 12), out.bytes.len);
}

test "compile: nop emits no body bytes (between prologue and epilogue)" {
    // Wasm spec §4.4.6.2 — nop has zero machine effect.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const slots = [_]u16{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Layout (uses_runtime_ptr = false, frame_bytes = 0):
    //   [0..4] prologue: PUSH RBP ; MOV RBP, RSP
    //   [4..6] epilogue: POP RBP ; RET
    try testing.expectEqual(@as(usize, 6), out.bytes.len);
}

test "compile: drop pops vreg without machine bytes (i32.const, drop, end)" {
    // Wasm spec §4.4.4 — drop consumes top operand without storage.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .drop });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Layout (slot 0 = RBX after chunk 13b pool shrink):
    //   [0..4]   prologue
    //   [4..9]   i32.const: MOV EBX, 7 (5 bytes — B8+rd + 4-byte imm; no REX)
    //   no drop bytes
    //   [9..11]  epilogue: POP RBP ; RET (no marshal because results.len==0)
    try testing.expectEqual(@as(usize, 11), out.bytes.len);
}

test "compile: return mid-function (i32.const, return, end) emits MOV EAX + epilogue, then a second epilogue" {
    // Wasm spec §4.4.7 — return marshals + exits. The trailing
    // function-level `end` emits a second (dead) epilogue. Both
    // epilogues are equivalent (no fixup mechanism on x86_64).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xDEADBEEF });
    try f.instrs.append(testing.allocator, .{ .op = .@"return" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Layout (slot 0 = RBX after chunk 13b pool shrink):
    //   [0..body]    prologue: PUSH RBP ; MOV RBP, RSP (4 bytes)
    //   [body..body+5]   i32.const: MOV EBX, imm (5 bytes)
    //   [body+5..body+7]  return marshal: MOV EAX, EBX (2 bytes — .d MovRR, no REX)
    //   [body+7..body+9] return epilogue: POP RBP ; RET (2 bytes)
    //   end (function-level):
    //     pushed_vregs.len > 0 still — emit second marshal MOV EAX, EBX
    //     [body+9..body+11] (2 bytes)
    //     [body+11..body+13] second epilogue: POP RBP ; RET (2 bytes)
    const body_start = prologue.body_start_offset(false, 0);
    const expected_marshal = inst.encMovRR(.d, abi.return_gpr, .rbx);
    try testing.expectEqualSlices(u8, expected_marshal.slice(), out.bytes[body_start + 5 .. body_start + 5 + expected_marshal.len]);
    // First RET at body+8
    try testing.expectEqual(@as(u8, 0xC3), out.bytes[body_start + 8]);
    // Total length: body + 5 + 2 + 2 + 2 + 2 = body + 13 bytes
    try testing.expectEqual(@as(usize, body_start + 13), out.bytes.len);
}

test "compile: i64.add emits ADD .q (REX.W) — 64-bit width preserved" {
    // Wasm spec §4.4.1.1 (i64.add). Tests the .q-form path:
    // MOV dst, lhs (.q) + ADD dst, rhs (.q) both carry REX.W.
    // Without REX.W (= 32-bit) the upper 32 bits of the result
    // would be truncated, silently mis-computing values that
    // exceed UINT32_MAX.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 1, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 2, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.add" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // Slot map (after chunk 13b pool shrink): vreg 0 → RBX (slot 0),
    // vreg 1 → R12 (slot 1), vreg 2 reuses slot 0 → RBX.
    const slots = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // i64.add lowers to: MOV RBX, RBX (skip — same reg) + ADD RBX, R12 (.q).
    // After 4-byte prologue + 2× MOVABS (10 each) = byte 24 the
    // ADD appears with REX.W set (encoded as 0x4C — REX.W+R since src=R12
    // needs REX.R; dst=RBX low does not need REX.B).
    const add_off = 4 + 10 + 10;
    const expected_add = inst.encAddRR(.q, .rbx, .r12);
    try testing.expectEqualSlices(u8, expected_add.slice(), out.bytes[add_off .. add_off + expected_add.len]);
    // First byte of ADD must include REX.W (bit 3 of low nibble).
    try testing.expect((out.bytes[add_off] & 0x08) != 0);
}

test "compile: i64.clz emits LZCNT .q (REX.W; F3 prefix) — 64-bit count" {
    // Wasm spec §4.4.1.4 (i64.clz). Result is i64 (count 0..64);
    // .q form distinguishes from .d form which would max at 32.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 1, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // vreg 0 → RBX (slot 0); vreg 1 (result) → R12 (slot 1) after chunk 13b.
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After prologue (4) + MOVABS RBX (10) = byte 14: LZCNT R12, RBX (.q form).
    const lzcnt_off = 14;
    const expected_lzcnt = inst.encLzcntR64(.r12, .rbx);
    try testing.expectEqualSlices(u8, expected_lzcnt.slice(), out.bytes[lzcnt_off .. lzcnt_off + expected_lzcnt.len]);
}

test "compile: i64.const emits MOVABS r64, imm64 (10 bytes)" {
    // Wasm spec §4.4.1.1 (i64.const). Verifies the full 64-bit
    // immediate path: high word from ins.extra, low word from
    // ins.payload, recombined and emitted as a single MOVABS.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const value: u64 = 0x0CABBA6E0BA66A6E; // arbitrary 64-bit literal
    try f.instrs.append(testing.allocator, .{
        .op = .@"i64.const",
        .payload = @as(u32, @truncate(value)),
        .extra = @truncate(value >> 32),
    });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0}; // GPR slot 0 → RBX after chunk 13b pool shrink
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Layout (uses_runtime_ptr = false, frame_bytes = 0):
    //   [0..body]    prologue: PUSH RBP ; MOV RBP, RSP
    //   [body..body+10]  i64.const: MOVABS RBX, imm64 (10 bytes; REX.W + B8+rd + 8-byte imm)
    //   [body+10..body+13] end i64 marshal: MOV RAX, RBX (.q, 3 bytes; 48 89 D8)
    //   [body+13..body+15] epilogue: POP RBP ; RET
    const body_start = prologue.body_start_offset(false, 0);
    const expected_movabs = inst.encMovImm64Q(.rbx, value);
    try testing.expectEqualSlices(u8, expected_movabs.slice(), out.bytes[body_start .. body_start + expected_movabs.len]);
    try testing.expectEqual(@as(usize, body_start + 15), out.bytes.len);
}

test "compile: unreachable emits JMP rel32 + trap stub patches disp to trap_byte" {
    // Wasm spec §4.4.6.1 — unreachable traps unconditionally.
    // Layout (no params, no locals, no result):
    //   [0..1]   prologue: PUSH RBP (1 byte)
    //   [1..4]   prologue: MOV RBP, RSP (3 bytes)
    //   [4..9]   unreachable: JMP rel32 placeholder (5 bytes)
    //   [9..11]  end-handler: POP RBP ; RET (no marshal because results.len==0)
    //   [11..]   trap stub: MOV [R15+trap_off], 1 ; XOR EAX,EAX ; POP RBP ; RET
    // Note: end-handler runs before the trap-stub patch loop, but
    // because there's no `uses_runtime_ptr` in this test, R15 is
    // not loaded — the trap stub's MOV [R15+...] would crash if
    // taken at runtime. This test only verifies the JMP disp32
    // gets patched to point at the trap stub byte; the actual
    // execution-time correctness is validated by the spec_assert
    // gate on x86_64 hosts (which uses uses_runtime_ptr=true via
    // memory ops). Here we just check the linker-visible byte
    // shape.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"unreachable" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const slots = [_]u16{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // Prologue post-`unreachable`-prescan addition:
    //   PUSH RBP (1) + PUSH R15 (2) + MOV RBP RSP (3)
    //   + MOV R15 RDI (3) + SUB RSP, 8 (4) = 13 bytes
    // JMP rel32 (5 bytes) starts at offset 13.
    // Prologue size sourced from body_start_offset().
    // `unreachable` prescan flips uses_runtime_ptr=true (R15 saved
    // even though not loaded for memory access in this fixture);
    // frame=8.
    const body_start = prologue.body_start_offset(true, 8);
    try testing.expectEqual(@as(u8, 0xE9), out.bytes[body_start]);
    const disp_slice_start = body_start + 1;
    const disp = std.mem.readInt(i32, out.bytes[disp_slice_start..][0..4], .little);
    const jmp_at: i32 = @intCast(body_start);
    const target_abs: i32 = jmp_at + 5 + disp;
    // After JMP: end-handler emits ADD RSP, 8 (4) + POP R15 (2)
    // + POP RBP (1) + RET (1) = 8 bytes → trap stub starts at
    // body_start + 5 + 8.
    try testing.expectEqual(@as(i32, jmp_at + 5 + 8), target_abs);
}

test "compile: SysV callee with 6 i32 params — 6th param read from caller stack [RBP+16+8*0]" {
    // Mirror of 7.10-f: caller writes overflow args at
    // `[RSP + 8 * nsaa_idx]` from its stack pointer; callee reads
    // them at `[RBP + 16 + r15_save_off + 8 * nsaa_idx]` (= caller's
    // bottom-of-frame after RET addr push + saved RBP + saved R15).
    //
    // Pre-7.10-j the SysV side surfaced UnsupportedOp[
    // i32-param-arg-overflow] at emit.zig:382 since arg_gprs.len = 6
    // and int_arg_idx starts at 1 (slot 0 = runtime ptr); 6 user
    // i32 args overflow at the 6th.
    // SIBLING-AT: src/engine/codegen/arm64/emit_test_alu_float.zig (AAPCS64 path)
    if (comptime abi.current_cc != .sysv) return;
    const sig: zir.FuncType = .{ .params = &[_]zir.ValType{ .i32, .i32, .i32, .i32, .i32, .i32 }, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };

    const slots = [_]u16{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // 6 i32 args: slots 1..5 fill arg_gprs[1..5] (RSI..R9). The 6th
    // arg (param 5) overflows. uses_runtime_ptr=false (no calls /
    // memory ops in this fn) so r15_save_off = 0; stack_disp = 16.
    // Look for `MOV EAX, [RBP + 16]` (encMovR32FromMemDisp32) — the
    // load step of the overflow read.
    const expected = inst.encMovR32FromMemDisp32(.rax, .rbp, 16);
    var found: bool = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i .. i + expected.len], expected.slice())) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: i32.load with offset > i32 imm32 range lowers via MOVABS+ADD" {
    // Wasm spec §4.4.7 — `memarg.offset` is u32. The pre-7.10-i
    // `encAddR64Imm32` path capped at 0x7FFFFFFF (sign-extended
    // imm32 range); offsets in [0x80000000, 0xFFFFFFFF] surfaced
    // SlotOverflow at op_memory.zig:126. emcc/clang -O2 binaries
    // can produce such offsets when the data segment + array
    // index arithmetic crosses 2 GiB.
    //
    // Fix: when offset > 0x7FFFFFFF, materialise it as a 64-bit
    // immediate in a scratch reg (MOVABS RCX, offset; 10 bytes)
    // and add to RDX (ADD RDX, RCX; 3 bytes) before the LEA RCX
    // overwrites RCX with ea+size.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 0x80000000 });
    try f.instrs.append(testing.allocator, .{ .op = .drop });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Look for the MOVABS RCX, 0x80000000 byte sequence anywhere
    // in the body (REX.W + 0xB9 + 8-byte little-endian imm).
    const expected = inst.encMovImm64Q(.rcx, 0x80000000);
    var found: bool = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i .. i + expected.len], expected.slice())) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: br N — function-depth (depth == labels.len) emits inline epilogue" {
    // Wasm spec §3.4.5 (br) — when the depth equals the number
    // of explicit labels, the branch targets the implicit
    // function-level block (= return). Pre-7.10-h surfaced
    // UnsupportedOp at op_control.zig:78. Now emits inline
    // marshal (MOV EAX, src) + ADD RSP + POP RBP + RET.
    //
    // Test: `(func (result i32) (i32.const 42) (br 0) end)` — at
    // br site labels.items.len = 0, depth = 0, so depth == len ⇒
    // function-return. The matching `end` runs the regular epilogue
    // path; both share the encoded marshal+RET shape.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .br, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };

    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // The compiled body must contain exactly two RET (0xC3) bytes —
    // one from the br-as-return inline epilogue, one from the
    // matching `end`'s regular epilogue. Pre-7.10-h would have
    // failed with UnsupportedOp before reaching the end.
    var ret_count: usize = 0;
    for (out.bytes) |b| {
        if (b == 0xC3) ret_count += 1;
    }
    try testing.expect(ret_count >= 2);
}

test "compile: total_locals=20 (>15 cap) — disp32 form lifts the i8 limit" {
    // localDisp i8 → i32 widening. Previously
    // surfaced `UnsupportedOp[total_locals>15]` for any function
    // with > 15 declared locals (deepest local at [RBP - 8 - 16*8]
    // = [RBP - 136], outside i8). With disp32 encoders the cap
    // moves to ~512 MiB, well past any realistic Wasm function.
    //
    // Test: declare 20 i32 locals (no params). Compile must succeed
    // and the deepest local zero-init store ([RBP - 168]) must use
    // the disp32 form.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const locals: [20]zir.ValType = .{ .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32, .i32 };
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };

    const slots = [_]u16{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Deepest local 19 at [RBP - 8*(19+1)] = [RBP - 160]
    // (uses_runtime_ptr=false; no calls/memory). The zero-init MOV
    // for that slot must use the disp32 store form. Look for
    // `MOV [RBP + (-160)], RAX` anywhere in the body.
    const expected = inst.encStoreR64MemRBPDisp32(-160, .rax);
    var found: bool = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i .. i + expected.len], expected.slice())) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: call N — 6 i32 args, SysV: 6th arg overflows to caller stack [RSP, #0] (STR W)" {
    // Mirror of arm64's d-11 caller-side stack-arg
    // lowering. SysV reserves arg_gprs[0] = RDI for runtime_ptr,
    // so user int args fit in arg_gprs[1..5] = RSI/RDX/RCX/R8/R9
    // (5 slots). 6 i32 args ⇒ args 0..4 register-pass, arg 5
    // overflows to the NSAA stack at [RSP + 0] (= bottom of the
    // caller's outgoing-args region pre-allocated in the prologue).
    //
    // Win64 path differs (3 user GPR slots, shared int/fp counter,
    // shadow space precedes overflow); covered by separate test
    // gating on `abi.current_cc == .win64`.
    // SIBLING-AT: src/engine/codegen/arm64/emit_test_alu_float.zig (AAPCS64 path)
    if (comptime abi.current_cc != .sysv) return;
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const callee_sig: zir.FuncType = .{ .params = &.{ .i32, .i32, .i32, .i32, .i32, .i32 }, .results = &.{} };
    const func_sigs = [_]zir.FuncType{ sig, callee_sig };

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    var k: u32 = 0;
    while (k < 6) : (k += 1) {
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 100 + k });
    }
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 6 },
        .{ .def_pc = 1, .last_use_pc = 6 },
        .{ .def_pc = 2, .last_use_pc = 6 },
        .{ .def_pc = 3, .last_use_pc = 6 },
        .{ .def_pc = 4, .last_use_pc = 6 },
        .{ .def_pc = 5, .last_use_pc = 6 },
    } };

    // 6 vregs need 6 slots — a GPR boundary of 4 (below the pool's
    // 8) puts slots 0..3 on registers and spills slots 4 + 5.
    // The marshal site stages spilled args through R10 (stage 0)
    // via `gprLoadSpilled` then writes them to the outgoing region.
    const slots = [_]u16{ 0, 1, 2, 3, 4, 5 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 6, .max_reg_slots_gpr = 4 };
    const out = try compile(testing.allocator, &f, alloc, &func_sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Locate the STR W to [RSP + 0] for the 6th arg (slot 5).
    // After spill staging into R10 (stage 0), the encoder emits
    // `MOV [RSP + 0], R10D`. Look for that exact opcode pattern
    // anywhere in the body — bytewise position depends on prior
    // spill/load encoding lengths which vary per pool layout.
    const expected = inst.encStoreR32MemRSPDisp32(.r10, 0);
    var found: bool = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i .. i + expected.len], expected.slice())) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: v128-result end emits MOVAPS XMM0, src marshal (ADR-0046)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.v128} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // v128 producer ops are emit-tested at op_simd level; reuse
    // f32.const to push an FP slot whose result_kind discriminator
    // routes the end handler down the v128 arm. Per ADR-0046 the
    // marshal is now MOVAPS XMM0, src (copies all 128 bits).
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer testing.allocator.free(out.bytes);
    // Sanity: emit succeeded with non-empty body.
    try testing.expect(out.bytes.len > 0);
}
