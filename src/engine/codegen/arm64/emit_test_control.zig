//! arm64 emit pass — control-flow tests.
//!
//! Family scope: block / loop / if / else / end, br / br_if /
//! br_table forward + backward fixups.
//!
//! Zone 2 (`src/engine/codegen/arm64/`). Pure relocation per
//! ADR-0021 sub-deliverable b chunk 10; bytes / assertions
//! identical to the pre-split `emit_test.zig`.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const prologue = @import("prologue.zig");
const abi = @import("abi.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const regalloc = @import("../shared/regalloc.zig");
const emit = @import("emit.zig");
const exception_table = @import("../shared/exception_table.zig");

const ZirFunc = zir.ZirFunc;
const compile = emit.compile;
const deinit = emit.deinit;
const Error = emit.Error;

const testing = std.testing;

test "compile: block + br 0 + end — forward unconditional branch fixup" {
    // (block (i32.const 7) (br 0) (i32.const 99) end (i32.const 1) end)
    // The br skips the second i32.const; the third lands as the
    // returned value (just to keep the func valid). For sub-e1
    // skeleton, just check the bytes — no execution.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .block });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .br, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 1, .last_use_pc = 5 }, // dropped at br but tracked
            .{ .def_pc = 4, .last_use_pc = 5 },
        },
    };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP                (prologue)
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #7         (i32.const 7)
    // [12]  B + (forward, patched)  ← block-end fixup
    // [16]  MOVZ W9 #1         (i32.const 1, after block)
    // [20]  MOV X0, X9
    // [24]  LDP, RET ...
    //
    // Verify the B at body+4 points 1 word forward.
    const body0 = prologue.body_start_offset(false);
    const b_word = std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little);
    try testing.expectEqual(@as(u32, inst.encB(1)), b_word);
}

test "compile: loop + br 0 + end — backward unconditional branch" {
    // (loop (br 0) end (i32.const 1) end) — infinite-loop pattern
    // (the loop's br targets the loop's start). Verify the B's
    // disp is negative.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .loop });
    try f.instrs.append(testing.allocator, .{ .op = .br, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 3, .last_use_pc = 4 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Loop entry recorded at body0. D-314: the `br 0` emits the loop back-edge
    // polls FIRST — interrupt (5 instrs / 20 B, #3a) then fuel (7 instrs /
    // 28 B, #3b) — then the backward B. So body0 is the interrupt poll's
    // `LDR X16, [X19, #interrupt_ptr_off]`, body0+20 is the fuel poll's
    // `LDR W16, [X19, #fuel_metered_off]`, and the B is at body0+48 targeting
    // body0 → disp = -12 words (negative, as intended).
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(
        @as(u32, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.interrupt_ptr_off)),
        std.mem.readInt(u32, out.bytes[body0..][0..4], .little),
    );
    try testing.expectEqual(
        @as(u32, inst.encLdrImmW(16, abi.runtime_ptr_save_gpr, jit_abi.fuel_metered_off)),
        std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little),
    );
    const b_word = std.mem.readInt(u32, out.bytes[body0 + 48 ..][0..4], .little);
    try testing.expectEqual(@as(u32, inst.encB(-12)), b_word);
}

test "compile: if (i32.const N) end — single-arm if; CBZ skips to end" {
    // (i32.const 1) (if) (i32.const 7) (end) (i32.const 99) (end)
    // The if takes the cond from the const 1, and unconditionally
    // executes its then-body (i32.const 7) since 1 != 0. We're
    // testing the byte layout, not execution.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"if" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .end }); // closes if
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .end }); // closes function
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 }, // cond
            .{ .def_pc = 2, .last_use_pc = 3 }, // then-body's const
            .{ .def_pc = 4, .last_use_pc = 5 }, // post-if
        },
    };
    const slots = [_]u16{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP                     (prologue)
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #1               (cond)
    // [12]  CBZ  W9, +2 (= byte 20)  (if-skip; patched at end)
    // [16]  MOVZ W9 #7               (then-body)
    // [20]  MOVZ W9 #99              (post-if; if's `end` lands here)
    // CBZ disp = 2 words. CBZ lives at body+4.
    const body0 = prologue.body_start_offset(false);
    const cbz = std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little);
    try testing.expectEqual(@as(u32, inst.encCbzW(9, 2)), cbz);
}

test "compile: if/else/end — CBZ skips to else; B-uncond skips to end" {
    // (i32.const 0) (if) (i32.const 7) (else) (i32.const 99) (end) (end)
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"if" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"else" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .end }); // closes if
    try f.instrs.append(testing.allocator, .{ .op = .end }); // closes function
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 }, // cond
            .{ .def_pc = 2, .last_use_pc = 3 }, // then-body
            .{ .def_pc = 4, .last_use_pc = 6 }, // else-body
        },
    };
    const slots = [_]u16{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #0   (cond)
    // [12]  CBZ  W9, ?   (patched at `else` to skip then-body)
    // [16]  MOVZ W9 #7   (then-body)
    // [20]  B    ?       (skip else-body; patched at `end`)
    // [24]  MOVZ W9 #99  (else-body; CBZ patched to here)
    // [28]  ...           (if's `end` lands here; B patched to here)
    //
    // CBZ disp = 3 words; B disp = 2 words.
    const body0 = prologue.body_start_offset(false);
    const cbz = std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little);
    const b = std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little);
    try testing.expectEqual(@as(u32, inst.encCbzW(9, 3)), cbz);
    try testing.expectEqual(@as(u32, inst.encB(2)), b);
}

test "compile: br_table — emits CMP+B.NE+B chain + default B" {
    // (block               ; outer block 1 (depth 1)
    //   (block             ; inner block 0 (depth 0)
    //     (i32.const 0)    ; index value
    //     (br_table 0 1)   ; case 0 → depth 0, default → depth 1
    //     (i32.const 7)    ; never reached
    //   end)               ; inner end
    //   (i32.const 99)
    // end)                 ; outer end
    // (i32.const 1) (end)  ; func end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // Build branch_targets: [0, 1] — case 0 → 0, default → 1.
    try f.branch_targets.append(testing.allocator, 0);
    try f.branch_targets.append(testing.allocator, 1);
    try f.instrs.append(testing.allocator, .{ .op = .block });
    try f.instrs.append(testing.allocator, .{ .op = .block });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .br_table, .payload = 1, .extra = 0 }); // count=1, start=0
    try f.instrs.append(testing.allocator, .{ .op = .end }); // inner block end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .end }); // outer block end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end }); // func end
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 2, .last_use_pc = 3 }, // index
            .{ .def_pc = 5, .last_use_pc = 6 }, // post-inner block
            .{ .def_pc = 7, .last_use_pc = 8 }, // post-outer block
        },
    };
    const slots = [_]u16{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #0      (index)
    // [12]  CMP W9, #0       (br_table case 0 cmp)
    // [16]  B.NE +2          (skip the next B if not equal)
    // [20]  B  ?             (forward fixup → inner-block end target)
    // [24]  B  ?             (forward fixup → outer-block end / default)
    // [28]  MOVZ W9 #99       ← inner-block-end target lands here
    // [32]  MOVZ W9 #1        ← outer-block-end target lands here
    // CMP at byte 12; B.NE at 16; case-0 B at 20 → +2 = byte 28; default B at 24 → +2 = byte 32.
    const body0 = prologue.body_start_offset(false);
    // After MOVZ #0 (body+0): CMP / B.NE / B(case-0) / B(default).
    try testing.expectEqual(@as(u32, inst.encCmpImmW(9, 0)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBCond(.ne, 2)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encB(2)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encB(2)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
}

test "compile: br_if 0 — forward CBNZ fixup" {
    // (block (i32.const 0) (br_if 0) (i32.const 7) end (i32.const 1) end)
    // br_if 0 reads the cond (0 → no branch, continues to const 7).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .block });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .br_if, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 3, .last_use_pc = 5 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP                (prologue)
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #0         (i32.const 0 → the cond)
    // [12]  CBNZ W9, +2        (br_if; patched to skip past const 7 → end of block)
    // [16]  MOVZ W9 #7         (i32.const 7)
    // [20]  block end → target lands here
    // CBNZ at body+4, disp_words = 2.
    const body0 = prologue.body_start_offset(false);
    const cbnz = std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little);
    try testing.expectEqual(@as(u32, inst.encCbnzW(9, 2)), cbnz);
}

/// `(block (i32.const 0) (br_if 0) <n × i64.const> end)` with four 16-bit
/// chunks per constant, so each is MOVZ + 3 MOVK: 16 bytes of code between
/// the `br_if` and the block's end.
fn compileBrIfOverConsts(n: u32) Error!emit.EmitOutput {
    const a = testing.allocator;
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(a);
    try f.instrs.append(a, .{ .op = .block });
    try f.instrs.append(a, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(a, .{ .op = .br_if, .payload = 0 });
    const ranges = try a.alloc(zir.LiveRange, n + 1);
    defer a.free(ranges);
    const slots = try a.alloc(u16, n + 1);
    defer a.free(slots);
    @memset(slots, 0);
    ranges[0] = .{ .def_pc = 1, .last_use_pc = 2 };
    for (ranges[1..], 3..) |*r, pc| {
        try f.instrs.append(a, .{ .op = .@"i64.const", .payload = 0x1111_2222, .extra = 0x3333_4444 });
        r.* = .{ .def_pc = @intCast(pc), .last_use_pc = @intCast(pc) };
    }
    try f.instrs.append(a, .{ .op = .end });
    try f.instrs.append(a, .{ .op = .end });
    f.liveness = .{ .ranges = ranges };
    const alloc: regalloc.Allocation = .{ .slots = slots, .n_slots = 1 };
    return compile(a, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
}

test "compile: a function whose branches all reach compiles; one a conditional branch cannot span is declined" {
    const decline_note = @import("../shared/decline_note.zig");
    decline_note.clear();
    defer decline_note.clear();
    const reach = inst.reachBytes(i19);

    // 60000 constants: 960000 bytes, under imm19's 1 MiB.
    const out = try compileBrIfOverConsts(60000);
    defer deinit(testing.allocator, out);
    try testing.expect(out.bytes.len < reach);
    const body0 = prologue.body_start_offset(false);
    const cbnz = std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little);
    try testing.expectEqual(inst.encCbnzW(9, 1 + 60000 * 4), cbnz);

    // 70000 constants: 1120000 bytes, past it.
    try testing.expectError(Error.UnsupportedOp, compileBrIfOverConsts(70000));
    const note = decline_note.take().?;
    try testing.expectEqualStrings("imm19", note.op);
    try testing.expect(note.reason.out_of_reach.distance > reach);
    try testing.expectEqual(reach, note.reason.out_of_reach.reach);
}

test "compile: try_table emit populates EmitOutput.exception_handlers" {
    // EH integration — compile() of a function with
    // a populated try_table block produces an
    // `EmitOutput.exception_handlers` slice with one HandlerEntry
    // per catch clause, with kind/tag_idx round-tripped from the
    // ZirFunc catch-vec. pc_end is patched by the matching `end`
    // op to the current buf offset (= pc_start for an empty inner
    // body, in this minimal fixture).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);

    // Wrap try_table in an enclosing block so catch_all label_idx=0
    // resolves to a real outer label (Wasm 3.0 EH spec — catch
    // clause labels are evaluated against the surrounding context,
    // not the try_table itself). Structure:
    //   block; try_table; end (try_table); end (block); end (fn).
    try f.instrs.append(testing.allocator, .{ .op = .block, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .try_table, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .end });

    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };

    // One LandingPad referencing two catch clauses: catch_all and
    // catch_ with tag_idx=7. The codegen iterates the half-open
    // slice and adds one HandlerEntry per clause.
    f.eh_landing_pads = try testing.allocator.dupe(zir.LandingPad, &[_]zir.LandingPad{
        .{ .block_idx = 0, .catches_start = 0, .catches_end = 2 },
    });
    f.eh_catch_entries = try testing.allocator.dupe(zir.CatchEntry, &[_]zir.CatchEntry{
        .{ .kind = .catch_all, .tag_idx = 0, .label_idx = 0 },
        .{ .kind = .catch_, .tag_idx = 7, .label_idx = 0 },
    });

    const alloc: regalloc.Allocation = .{ .slots = &[_]u16{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.exception_handlers.len);

    // Entry 0 — catch_all (no tag).
    try testing.expectEqual(exception_table.CatchKind.catch_all, out.exception_handlers[0].kind);
    try testing.expectEqual(@as(?u32, null), out.exception_handlers[0].tag_idx);

    // Entry 1 — catch_ with tag_idx=7.
    try testing.expectEqual(exception_table.CatchKind.catch_, out.exception_handlers[1].kind);
    try testing.expectEqual(@as(?u32, 7), out.exception_handlers[1].tag_idx);

    // Both entries share pc_start (same try_table). pc_end is
    // patched to the post-inner-block buf offset; in this empty-
    // body case it equals pc_start (the matching `end` fired
    // immediately after the try_table emit). The placeholder
    // value `pc_start + 1` MUST have been overwritten.
    try testing.expectEqual(out.exception_handlers[0].pc_start, out.exception_handlers[1].pc_start);
    try testing.expectEqual(out.exception_handlers[0].pc_start, out.exception_handlers[0].pc_end);

    // landing_pad_pc patched to the buf offset right after the
    // enclosing block's `end` op (Wasm 3.0 EH: catch label_idx=0
    // targets the surrounding block). With zero-byte inner body
    // and zero-arity blocks, the outer-block's end emits nothing
    // additional → land_pc equals pc_end.
    try testing.expectEqual(out.exception_handlers[0].pc_end, out.exception_handlers[0].landing_pad_pc);
    try testing.expectEqual(out.exception_handlers[1].pc_end, out.exception_handlers[1].landing_pad_pc);
}

test "compile: throw emits B placeholder + appends bounds_fixup (trap-path)" {
    // EH integration minimum — throw emits a single
    // unconditional B placeholder targeting the function trap
    // stub (mirror of `unreachable`). Full dispatcher CALL +
    // handler branch lands later. The byte count after compile
    // must include the prologue + the 4-byte B placeholder + the
    // trap-stub epilogue (patched by the function-end pass).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);

    try f.instrs.append(testing.allocator, .{ .op = .throw, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });

    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const alloc: regalloc.Allocation = .{ .slots = &[_]u16{}, .n_slots = 0 };

    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Prologue (STP + MOV FP, SP = 8 bytes) + B placeholder
    // (4 bytes) + trap stub (~24 bytes: MOVZ W17, STR trap_flag,
    // STR trap_kind, MOVZ X0, LDP, RET = 6 * 4 = 24 bytes).
    // Conservative lower bound: prologue + B + first 3 trap-stub
    // words = 8 + 4 + 12 = 24 bytes.
    try testing.expect(out.bytes.len >= 24);
    // The throw op does NOT register any HandlerEntry (only
    // try_table does); exception_handlers slice stays empty.
    try testing.expectEqual(@as(usize, 0), out.exception_handlers.len);
}

test "compile: throw of a tag with more than 16 payload values declines, not aborts" {
    // The payload buffer is Exception.payload[16] (ADR-0114 D1); nothing
    // validates the tag's arity (exception.zig claims it does, but no path
    // enforces it), so a guest can throw a 17-parameter tag. Marshalling it
    // used to assert n_payload <= 16 — a process abort in a safety build —
    // before the out-of-range slot writes. Decline instead so the
    // interpreter runs the module.
    const seventeen: [17]zir.ValType = @splat(.i32);
    const tag_sig: zir.FuncType = .{ .params = &seventeen, .results = &.{} };
    const module_types = [_]zir.FuncType{tag_sig};
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .throw, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const alloc: regalloc.Allocation = .{ .slots = &[_]u16{}, .n_slots = 0 };
    try testing.expectError(
        Error.UnsupportedOp,
        compile(testing.allocator, &f, alloc, &.{}, &module_types, 0, &.{}, &.{}, .i32, &[_]u32{0}, false, false),
    );
}

test "compile: try_table reaches per-op emit with ExceptionTable.Builder wired" {
    // EH integration — compile() detects `.try_table`
    // ops in func.instrs and allocates a per-function
    // `ExceptionTable.Builder`, threading it through
    // `ctx.exception_table_builder`. The per-op stub still returns
    // `UnsupportedOp` (the emit body lands later); this test only
    // verifies the dispatcher reaches the stub with the builder
    // wired (the stub's `std.debug.assert(builder != null)` would
    // panic otherwise).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .try_table, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const alloc: regalloc.Allocation = .{ .slots = &[_]u16{}, .n_slots = 0 };
    try testing.expectError(
        Error.UnsupportedOp,
        compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false),
    );
}
