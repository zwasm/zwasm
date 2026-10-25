//! In-file test suite extracted from `interp/mvp.zig` (ADR-0099 P4
//! test-isolation; 2026-08 sweep S1 triage — the impl file sat at 1948
//! lines with a ~840-line test tail). Exercises the registered MVP
//! interp handlers through the public dispatch surface.

const std = @import("std");
const mvp = @import("mvp.zig");
const zir = @import("../ir/zir.zig");
const runtime = @import("../runtime/runtime.zig");
const dispatch = @import("../ir/dispatch_table.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const Runtime = runtime.Runtime;
const Trap = runtime.Trap;
const Value = runtime.Value;
const DispatchTable = dispatch.DispatchTable;
const register = mvp.register;
const invoke = mvp.invoke;

/// Handler-table index of an op (same shape as the impl-side helper).
inline fn op(t: ZirOp) usize {
    return @backingInt(t);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("dispatch.zig");

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "register: const + drop slots populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"i32.const")] != null);
    try testing.expect(t.interp[op(.@"i64.const")] != null);
    try testing.expect(t.interp[op(.drop)] != null);
}
test "locals: get/set/tee round-trip via current frame" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var locals = [_]Value{ Value.fromI32(0), Value.fromI32(0) };
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    try rt.pushFrame(.{ .sig = sig, .locals = &locals, .operand_base = 0, .pc = 0 });

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 42)), 0);
    try driveOne(&rt, &t, .@"local.set", 0, 0);
    try testing.expectEqual(@as(i32, 42), locals[0].i32);

    try driveOne(&rt, &t, .@"local.get", 0, 0);
    try testing.expectEqual(@as(i32, 42), rt.popOperand().i32);

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 99)), 0);
    try driveOne(&rt, &t, .@"local.tee", 1, 0);
    try testing.expectEqual(@as(i32, 99), locals[1].i32);
    try testing.expectEqual(@as(i32, 99), rt.popOperand().i32);
}
test "call: invokes callee, args pop and result push round-trip" {
    // callee: fn (i32, i32) -> i32 { local.get 0 ; local.get 1 ; i32.add ; end }
    const param_arr = [_]zir.ValType{ .i32, .i32 };
    const result_arr = [_]zir.ValType{.i32};
    var callee = zir.ZirFunc.init(0, .{ .params = &param_arr, .results = &result_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 1, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.add", .payload = 0, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    // caller: fn () -> i32 { i32.const 5 ; i32.const 7 ; call 0 ; end }
    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &result_arr }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .call, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try dispatch_loop.run(&rt, &t, caller.instrs.items);

    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 12), rt.popOperand().u32);
}

test "block + end: arity=0, operand stack restored" {
    // ZirFunc with 1 block (start=0, end=2). instrs: [block, i32.const 7, end, i32.const 99, end]
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 0, .end_inst = 2 });
    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = @as(u64, @as(u32, @bitCast(@as(i32, 7)))), .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = @as(u64, @as(u32, @bitCast(@as(i32, 99)))), .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    // After block (arity=0): operand stack popped back to 0, then i32.const 99
    // pushed, then function-level end fires.
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 99), rt.popOperand().i32);
}

test "br 0 from inside block: jumps past end" {
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 0, .end_inst = 4 });
    // block; i32.const 1; br 0; i32.const 2 (skipped); end; i32.const 3; end
    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .br, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 3, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    // br 0 (arity=0) discarded the i32.const 1 result. Then i32.const 3 pushed.
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 3), rt.popOperand().u32);
}

test "interp invoke: traps Interrupted at function entry when the host flag is raised (ADR-0179 #3a)" {
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var flag = std.atomic.Value(u32).init(1); // host requested interruption
    rt.interrupt = &flag;
    try testing.expectError(Trap.Interrupted, invoke(&rt, &t, &fnz));

    flag.store(0, .monotonic); // cleared → the same function runs to completion
    try invoke(&rt, &t, &fnz);
}

test "interp loop: a tight (loop (br 0)) is interruptible at the back-edge (ADR-0179 #3a)" {
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .loop, .start_inst = 0, .end_inst = 2 });
    // loop; br 0 (→ loop header, infinite); end
    try fnz.instrs.append(testing.allocator, .{ .op = .loop, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .br, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    // Pre-raised flag: the throttled back-edge poll trips within
    // INTERRUPT_CHECK_MASK+1 (=1024) steps — bounded, no thread needed. If the
    // mechanism regressed, the loop would spin forever (test hang = failure).
    var flag = std.atomic.Value(u32).init(1);
    rt.interrupt = &flag;
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try testing.expectError(Trap.Interrupted, dispatch_loop.run(&rt, &t, fnz.instrs.items));
}

test "if cond=0 skips to end; cond=1 runs then-branch" {
    // (if (then i32.const 1) (else i32.const 2)) — sig: () -> i32
    // instrs: i32.const cond ; if ; i32.const 1 ; else ; i32.const 2 ; end ; end
    const i32_arr = [_]zir.ValType{.i32};
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .else_open, .start_inst = 1, .end_inst = 5, .else_inst = 3 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1, .extra = 0 }); // cond
    try fnz.instrs.append(testing.allocator, .{ .op = .@"if", .payload = 0, .extra = 1 }); // if (result i32) → arity 1
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 11, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"else", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 22, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);
    try testing.expectEqual(@as(u32, 11), rt.popOperand().u32);
}

test "return: ends function execution and produces sig.results" {
    const i32_arr = [_]zir.ValType{.i32};
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer fnz.deinit(testing.allocator);
    // i32.const 7 ; return ; i32.const 99 ; end
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"return", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 7), rt.popOperand().u32);
}

test "block + end: arity=2 multivalue — both results survive" {
    // Wasm 2.0 multivalue: block (result i32 i32) { i32.const 11 ; i32.const 22 }
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 0, .end_inst = 3 });
    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 2 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 11, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 22, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    // Both 11 and 22 should remain (arity=2 saved + restored).
    try testing.expectEqual(@as(u32, 2), rt.operand_len);
    try testing.expectEqual(@as(u32, 22), rt.popOperand().u32);
    try testing.expectEqual(@as(u32, 11), rt.popOperand().u32);
}
test "block (param i32): packed param byte → result-arity + params-excluded height (10.E cycle 118)" {
    // try-with-param shape generalised: [99, 0] ; block (param i32) { drop } ; end.
    // The typeidx blocktype packs instr.extra = (params=1 << 8)|results=0
    // = 0x100. The interp must (a) use the low byte for label arity
    // (else 0x100 > max_block_arity → Trap.Unreachable) and (b) exclude
    // params from the label height (else the 99 below the param is
    // mis-restored). After the block, only 99 remains.
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 2, .end_inst = 4 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 0x100 });
    try fnz.instrs.append(testing.allocator, .{ .op = .drop, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 99), rt.popOperand().u32);
}

test "unreachable: traps Trap.Unreachable" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try testing.expectError(Trap.Unreachable, driveOne(&rt, &t, .@"unreachable", 0, 0));
}

test "nop: leaves stack untouched" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 7 });
    try driveOne(&rt, &t, .nop, 0, 0);
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
}

test "select: cond != 0 picks first operand" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 11 }); // a
    try rt.pushOperand(.{ .i32 = 22 }); // b
    try rt.pushOperand(.{ .i32 = 1 }); // cond
    try driveOne(&rt, &t, .select, 0, 0);
    try testing.expectEqual(@as(i32, 11), rt.popOperand().i32);
}

test "select: cond == 0 picks second operand" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 11 });
    try rt.pushOperand(.{ .i32 = 22 });
    try rt.pushOperand(.{ .i32 = 0 });
    try driveOne(&rt, &t, .select, 0, 0);
    try testing.expectEqual(@as(i32, 22), rt.popOperand().i32);
}

test "select_typed: same runtime semantics as select" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 7 });
    try rt.pushOperand(.{ .ref = runtime.Value.null_ref });
    try rt.pushOperand(.{ .i32 = 1 }); // cond=true → pick first
    try driveOne(&rt, &t, .select_typed, 0, 0x70);
    try testing.expectEqual(@as(u64, 7), rt.popOperand().ref);
}

test "globals: get/set round-trip" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    // Per ADR-0014 §2.1 / 6.K.3: Runtime.globals is `[]*Value`
    // (one pointer per slot, so cross-module imports can alias
    // source storage). Tests build the slot array on the stack.
    var storage = [_]Value{Value.fromI32(0)};
    var slots = [_]*Value{&storage[0]};
    rt.globals = &slots;
    defer rt.globals = &.{}; // prevent deinit from freeing the stack slice

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 17)), 0);
    try driveOne(&rt, &t, .@"global.set", 0, 0);
    try testing.expectEqual(@as(i32, 17), storage[0].i32);

    try driveOne(&rt, &t, .@"global.get", 0, 0);
    try testing.expectEqual(@as(i32, 17), rt.popOperand().i32);
}

test "throw + catch_all: catch dispatches to outer block end (10.E-5b)" {
    // (func (result i32)
    //   i32.const 42        ; result-to-be: lives on operand stack throughout
    //   (block              ; arity=0, block_idx=0
    //     (try_table        ; arity=0, block_idx=1, catch_all 0
    //       throw 0         ; tag_idx=0; catch_all match
    //     end)              ; try_table end — never reached
    //   end)                ; block end — catch_all branches here
    //   end                 ; function end → returns 42
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &[_]zir.ValType{.i32} }, &.{});
    defer fnz.deinit(testing.allocator);

    // Block-info table.
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 1, .end_inst = 5 });
    try fnz.blocks.append(testing.allocator, .{ .kind = .try_table, .start_inst = 2, .end_inst = 4 });

    // Catch metadata.
    const catches = try testing.allocator.dupe(zir.CatchEntry, &[_]zir.CatchEntry{
        .{ .kind = .catch_all, .tag_idx = 0, .label_idx = 0 },
    });
    fnz.eh_catch_entries = catches;
    const lps = try testing.allocator.dupe(zir.LandingPad, &[_]zir.LandingPad{
        .{ .block_idx = 1, .catches_start = 0, .catches_end = 1 },
    });
    fnz.eh_landing_pads = lps;

    // Instruction stream.
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .try_table, .payload = 1, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .throw, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 42), rt.popOperand().i32);
}

test "throw without enclosing try_table: propagates Trap.UncaughtException (10.E-5b)" {
    // (func throw 0 end) — no catch in current frame.
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.instrs.append(testing.allocator, .{ .op = .throw, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try testing.expectError(Trap.UncaughtException, dispatch_loop.run(&rt, &t, fnz.instrs.items));
}

test "throw + catch_ with matching tag_idx + i32 param: catch pushes param at target (10.E-5c)" {
    // (func (result i32)
    //   (block (result i32)       ; arity=1, block_idx=0
    //     (try_table              ; arity=0, block_idx=1, catch 0 0
    //       i32.const 77
    //       throw 0               ; tag 0 has 1 i32 param
    //     end)
    //   end)                      ; result = the catch's i32 payload
    //   end
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &[_]zir.ValType{.i32} }, &.{});
    defer fnz.deinit(testing.allocator);

    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 1, .end_inst = 5 });
    try fnz.blocks.append(testing.allocator, .{ .kind = .try_table, .start_inst = 2, .end_inst = 4 });

    const catches = try testing.allocator.dupe(zir.CatchEntry, &[_]zir.CatchEntry{
        .{ .kind = .catch_, .tag_idx = 0, .label_idx = 0 },
    });
    fnz.eh_catch_entries = catches;
    const lps = try testing.allocator.dupe(zir.LandingPad, &[_]zir.LandingPad{
        .{ .block_idx = 1, .catches_start = 0, .catches_end = 1 },
    });
    fnz.eh_landing_pads = lps;

    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 1 });
    try fnz.instrs.append(testing.allocator, .{ .op = .try_table, .payload = 1, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 77, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .throw, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // Tag 0 has 1 param (i32).
    const tag_counts = [_]u32{1};
    rt.tag_param_counts = &tag_counts;
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 77), rt.popOperand().i32);
}

test "throw + catch_ with non-matching tag_idx: falls through to UncaughtException (10.E-5c)" {
    // try_table with only catch_ on tag 5, but throw 0 — no match.
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);

    try fnz.blocks.append(testing.allocator, .{ .kind = .try_table, .start_inst = 0, .end_inst = 2 });
    const catches = try testing.allocator.dupe(zir.CatchEntry, &[_]zir.CatchEntry{
        .{ .kind = .catch_, .tag_idx = 5, .label_idx = 0 },
    });
    fnz.eh_catch_entries = catches;
    const lps = try testing.allocator.dupe(zir.LandingPad, &[_]zir.LandingPad{
        .{ .block_idx = 0, .catches_start = 0, .catches_end = 1 },
    });
    fnz.eh_landing_pads = lps;

    try fnz.instrs.append(testing.allocator, .{ .op = .try_table, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .throw, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try testing.expectError(Trap.UncaughtException, dispatch_loop.run(&rt, &t, fnz.instrs.items));
}

test "Label.block_idx defaults to 0 and is populated by blockOp" {
    // Regression: ensure blockOp / loopOp / ifOp set block_idx so
    // the throw unwinder can identify try_table labels by reading
    // func.blocks.items[label.block_idx].kind. Without this, the
    // unwinder mis-identifies all labels as block kind.
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 0, .end_inst = 1 });
    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    // Execute just the block op; verify the pushed label carries
    // block_idx=0.
    const frame = rt.currentFrame();
    frame.pc = 0;
    try dispatch_loop.step(&rt, &t, &fnz.instrs.items[0]);
    try testing.expectEqual(@as(u32, 1), frame.label_len);
    try testing.expectEqual(@as(u32, 0), frame.labelAt(0).block_idx);
}

test "cross-frame throw: callee throws, outer try_table catch_all catches (10.E-5d)" {
    // Inner func: (func throw 0 end)  — empty params, empty results.
    var inner = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer inner.deinit(testing.allocator);
    try inner.instrs.append(testing.allocator, .{ .op = .throw, .payload = 0, .extra = 0 });
    try inner.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    // Outer func:
    //   (block (result i32)        ; outer_block, block_idx=0, end_inst=7
    //     (block                    ; inner_block, block_idx=1, end_inst=5
    //                               ;   — catch_all targets THIS label
    //                               ;     (arity=0 so no payload mismatch)
    //       (try_table              ; block_idx=2, end_inst=4
    //         call 0                ; func 0 = inner; throws uncaught
    //       end)
    //     end)                       ; catch_all branched here; stack=[]
    //     i32.const 42                ; pushed after catch
    //   end)                          ; outer_block end → pops i32 result
    //   end                           ; function end → returns 42
    var outer = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &[_]zir.ValType{.i32} }, &.{});
    defer outer.deinit(testing.allocator);

    try outer.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 1, .end_inst = 7 });
    try outer.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 2, .end_inst = 5 });
    try outer.blocks.append(testing.allocator, .{ .kind = .try_table, .start_inst = 3, .end_inst = 4 });

    const catches = try testing.allocator.dupe(zir.CatchEntry, &[_]zir.CatchEntry{
        .{ .kind = .catch_all, .tag_idx = 0, .label_idx = 0 },
    });
    outer.eh_catch_entries = catches;
    const lps = try testing.allocator.dupe(zir.LandingPad, &[_]zir.LandingPad{
        .{ .block_idx = 2, .catches_start = 0, .catches_end = 1 },
    });
    outer.eh_landing_pads = lps;

    try outer.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 1 });
    try outer.instrs.append(testing.allocator, .{ .op = .block, .payload = 1, .extra = 0 });
    try outer.instrs.append(testing.allocator, .{ .op = .try_table, .payload = 2, .extra = 0 });
    try outer.instrs.append(testing.allocator, .{ .op = .call, .payload = 0, .extra = 0 });
    try outer.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try outer.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try outer.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42, .extra = 0 });
    try outer.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try outer.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    // callOp consults rt.funcs[idx] for the callee body.
    const funcs = [_]*const zir.ZirFunc{&inner};
    rt.funcs = &funcs;
    defer rt.funcs = &.{};

    try rt.pushFrame(.{ .sig = outer.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &outer });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, outer.instrs.items);

    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 42), rt.popOperand().i32);
    // pending_exception cleared on cross-frame catch.
    try testing.expect(rt.pending_exception == null);
}

test "cross-frame throw: callee throws, no outer try_table → propagates Trap.UncaughtException with payload stash set (10.E-5d)" {
    var inner = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer inner.deinit(testing.allocator);
    try inner.instrs.append(testing.allocator, .{ .op = .throw, .payload = 0, .extra = 0 });
    try inner.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var outer = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &.{} }, &.{});
    defer outer.deinit(testing.allocator);
    try outer.instrs.append(testing.allocator, .{ .op = .call, .payload = 0, .extra = 0 });
    try outer.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const funcs = [_]*const zir.ZirFunc{&inner};
    rt.funcs = &funcs;
    defer rt.funcs = &.{};
    try rt.pushFrame(.{ .sig = outer.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &outer });
    defer _ = rt.popFrame();

    try testing.expectError(Trap.UncaughtException, dispatch_loop.run(&rt, &t, outer.instrs.items));
    // pending_exception survives — outermost caller can inspect tag_idx if needed.
    try testing.expect(rt.pending_exception != null);
    try testing.expectEqual(@as(u32, 0), rt.pending_exception.?.tag_idx);
}

test "throw + catch_all_ref: catch pushes exnref pointing at Exception (10.E-exnref-a)" {
    // (func (result i32)
    //   (block (result i32)        ; outer_block, block_idx=0, end_inst=7
    //     (block (result i32)      ; inner_block, block_idx=1, arity=1, end_inst=5
    //                              ;   — catch_all_ref targets this label; pushes exnref
    //       (try_table             ; block_idx=2, end_inst=4
    //         throw 0
    //       end)
    //     end)                      ; catch_all_ref branched here with exnref on stack
    //                               ; (block's branch_arity=1 catches the exnref as the block result)
    //     drop                      ; discard the exnref
    //     i32.const 7                ; substitute return value
    //   end)
    //   end
    // The inner block has (result i32) so its branch_arity=1 matches
    // the single value (exnref reinterpreted as ref u64) catch_all_ref pushes.
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &[_]zir.ValType{.i32} }, &.{});
    defer fnz.deinit(testing.allocator);

    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 1, .end_inst = 7 });
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 2, .end_inst = 5 });
    try fnz.blocks.append(testing.allocator, .{ .kind = .try_table, .start_inst = 3, .end_inst = 4 });

    const catches = try testing.allocator.dupe(zir.CatchEntry, &[_]zir.CatchEntry{
        .{ .kind = .catch_all_ref, .tag_idx = 0, .label_idx = 0 },
    });
    fnz.eh_catch_entries = catches;
    const lps = try testing.allocator.dupe(zir.LandingPad, &[_]zir.LandingPad{
        .{ .block_idx = 2, .catches_start = 0, .catches_end = 1 },
    });
    fnz.eh_landing_pads = lps;

    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 1 });
    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 1, .extra = 1 });
    try fnz.instrs.append(testing.allocator, .{ .op = .try_table, .payload = 2, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .throw, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .drop, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 7), rt.popOperand().i32);
    // The Exception heap object survives in live_exceptions until Runtime.deinit.
    try testing.expectEqual(@as(usize, 1), rt.live_exceptions.items.len);
}

test "throw + catch_ref with matching tag: pushes params + exnref (10.E-exnref-a)" {
    // (func (result i32)
    //   (block (result i32)        ; outer_block, block_idx=0, end_inst=8
    //     (block (param i32 i32)   ; inner_block, block_idx=1
    //                              ;   — catch_ref expects [i32, exnref]
    //                              ;     but block's signature is tricky here;
    //                              ;     using arity=2 so branch_arity=2 captures both
    //       (try_table             ; block_idx=2
    //         i32.const 88
    //         throw 0              ; tag 0 has 1 i32 param → catch_ref pushes [88, exnref]
    //       end)
    //     end)                      ; catch_ref branched here with [88, exnref]
    //                               ; inner block's branch_arity=2 means br carries both
    //     drop                      ; drop exnref
    //                               ; stack=[88]
    //   end)                        ; outer block's branch_arity=1 → carry 88
    //   end
    //
    // Note: this test bypasses validator-enforced label type matching by
    // directly constructing ZirFunc. The arity-2 inner block is shorthand
    // for "branch_arity=2 captures whatever catch_ref pushes".
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &[_]zir.ValType{.i32} }, &.{});
    defer fnz.deinit(testing.allocator);

    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 1, .end_inst = 7 });
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 2, .end_inst = 6 });
    try fnz.blocks.append(testing.allocator, .{ .kind = .try_table, .start_inst = 3, .end_inst = 5 });

    const catches = try testing.allocator.dupe(zir.CatchEntry, &[_]zir.CatchEntry{
        .{ .kind = .catch_ref, .tag_idx = 0, .label_idx = 0 },
    });
    fnz.eh_catch_entries = catches;
    const lps = try testing.allocator.dupe(zir.LandingPad, &[_]zir.LandingPad{
        .{ .block_idx = 2, .catches_start = 0, .catches_end = 1 },
    });
    fnz.eh_landing_pads = lps;

    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 1 });
    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 1, .extra = 2 });
    try fnz.instrs.append(testing.allocator, .{ .op = .try_table, .payload = 2, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 88, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .throw, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .drop, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // Tag 0 has 1 param (i32).
    const tag_counts = [_]u32{1};
    rt.tag_param_counts = &tag_counts;
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 88), rt.popOperand().i32);
}

test "throw_ref: re-raises Exception caught via catch_all_ref by outer try_table (10.E-exnref-b)" {
    // (func (result i32)
    //   (block (result i32)        ; outer_block, block_idx=0, end_inst=10
    //     (block (result i32)      ; mid_block, block_idx=1, arity=1, end_inst=8
    //       (try_table             ; outer try_table, block_idx=2, end_inst=7
    //                              ;   — catch_all_ref grabs the exnref
    //         (try_table           ; inner try_table, block_idx=3, end_inst=5
    //                              ;   — catch_all_ref grabs the original throw
    //           throw 0            ; raises Exception
    //         end)
    //         throw_ref            ; re-raise (exnref on stack from inner catch_all_ref)
    //       end)
    //     end)                      ; mid_block end with exnref captured by outer catch
    //     drop                      ; discard the exnref
    //     i32.const 9
    //   end)
    //   end
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &[_]zir.ValType{.i32} }, &.{});
    defer fnz.deinit(testing.allocator);

    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 1, .end_inst = 10 });
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 2, .end_inst = 8 });
    try fnz.blocks.append(testing.allocator, .{ .kind = .try_table, .start_inst = 3, .end_inst = 7 });
    try fnz.blocks.append(testing.allocator, .{ .kind = .try_table, .start_inst = 4, .end_inst = 5 });

    const catches = try testing.allocator.dupe(zir.CatchEntry, &[_]zir.CatchEntry{
        .{ .kind = .catch_all_ref, .tag_idx = 0, .label_idx = 0 }, // outer try_table → mid_block
        .{ .kind = .catch_all_ref, .tag_idx = 0, .label_idx = 0 }, // inner try_table → outer try_table
    });
    fnz.eh_catch_entries = catches;
    const lps = try testing.allocator.dupe(zir.LandingPad, &[_]zir.LandingPad{
        .{ .block_idx = 2, .catches_start = 0, .catches_end = 1 }, // outer
        .{ .block_idx = 3, .catches_start = 1, .catches_end = 2 }, // inner
    });
    fnz.eh_landing_pads = lps;

    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 0, .extra = 1 });
    try fnz.instrs.append(testing.allocator, .{ .op = .block, .payload = 1, .extra = 1 });
    try fnz.instrs.append(testing.allocator, .{ .op = .try_table, .payload = 2, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .try_table, .payload = 3, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .throw, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .throw_ref, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .drop, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 9, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 9), rt.popOperand().i32);
    // Single Exception allocation (throw_ref reuses, not re-allocates).
    try testing.expectEqual(@as(usize, 1), rt.live_exceptions.items.len);
}

test "throw_ref: null exnref → Trap.NullReference (10.E-exnref-b)" {
    // Push a canonical null exnref (Value.ref = null_ref) and run
    // throw_ref. Pushing via `i32.const 0` would leave the upper
    // 4 bytes of the operand-stack Value uninitialised (extern
    // union — only the .i32 field is written; Debug poison makes
    // `.ref` non-zero garbage), so push the null ref directly.
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.instrs.append(testing.allocator, .{ .op = .throw_ref, .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();
    try rt.pushOperand(.{ .ref = Value.null_ref });

    try testing.expectError(Trap.NullReference, dispatch_loop.run(&rt, &t, fnz.instrs.items));
}
