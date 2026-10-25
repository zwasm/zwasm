//! Trap-semantics audit tests (Phase 2 / §9.2 / 2.4).
//!
//! Concentrates the spec-conformant trap-condition tests that
//! cross multiple opcodes. Per-opcode trap behaviour is unit-
//! tested next to the handler in `mvp.zig` / `memory_ops.zig` /
//! `ext_2_0/*`; this file holds the call_indirect path tests
//! that need a full ZirFunc + Runtime + table + module_types
//! setup, and any other spec traps whose verification spans
//! multiple subsystems.
//!
//! Zone 2.

const std = @import("std");

const dispatch = @import("../ir/dispatch_table.zig");
const zir = @import("../ir/zir.zig");
const runtime = @import("../runtime/runtime.zig");
const mvp = @import("mvp.zig");
const dispatch_loop = @import("dispatch.zig");

const DispatchTable = dispatch.DispatchTable;
const Runtime = runtime.Runtime;
const Trap = runtime.Trap;

const testing = std.testing;

test "call_indirect: selector OOB → OutOfBoundsTableAccess" {
    var caller = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .call_indirect, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]runtime.Value{.{ .ref = runtime.Value.null_ref }};
    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try testing.expectError(Trap.OutOfBoundsTableAccess, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

test "call_indirect: null table cell → UninitializedElement" {
    var caller = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .call_indirect, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]runtime.Value{.{ .ref = runtime.Value.null_ref }};
    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try testing.expectError(Trap.UninitializedElement, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

test "call_indirect: sig mismatch → IndirectCallTypeMismatch" {
    const i32_arr = [_]zir.ValType{.i32};
    // callee () -> i32; expected (per type_idx=0): () -> ()
    var callee = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .call_indirect, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;
    var entities = [_]runtime.FuncEntity{.{ .runtime = &rt, .func_idx = 0, .typeidx = 0, .funcptr = 0 }};
    rt.func_entities = &entities;
    var refs = [_]runtime.Value{runtime.Value.fromFuncRef(&entities[0])};
    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try testing.expectError(Trap.IndirectCallTypeMismatch, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

test "call_indirect: matching sig invokes callee through table" {
    const i32_arr = [_]zir.ValType{.i32};
    var callee = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .call_indirect, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;
    var entities = [_]runtime.FuncEntity{.{ .runtime = &rt, .func_idx = 0, .typeidx = 0, .funcptr = 0 }};
    rt.func_entities = &entities;
    var refs = [_]runtime.Value{runtime.Value.fromFuncRef(&entities[0])};
    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &i32_arr }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try dispatch_loop.run(&rt, &t, caller.instrs.items);
    try testing.expectEqual(@as(u32, 42), rt.popOperand().u32);
}

test "br: function-level br 0 returns the result (Wasm §4.4.8 implicit outermost block)" {
    // `(func (result i32) i32.const 42 (br 0))` — `br 0` at the function top
    // level (no enclosing blocks → label_len=0) targets the implicit function
    // body block = a return carrying the result. Previously trapped Unreachable
    // (doBranch `depth >= label_len`); now returns 42 (gc/type-subtyping.17 run).
    const i32_arr = [_]zir.ValType{.i32};
    var caller = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .br, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try dispatch_loop.run(&rt, &t, caller.instrs.items);
    try testing.expectEqual(@as(u32, 42), rt.popOperand().u32);
}

test "6.K.1: null funcref round-trip — ref.is_null + call_indirect" {
    var caller = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .call_indirect, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]runtime.Value{.{ .ref = runtime.Value.null_ref }};
    // Encoding contract per ADR-0014 §2.1 / 6.K.1: null is literal 0.
    try testing.expectEqual(@as(u64, 0), refs[0].ref);

    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try testing.expectError(Trap.UninitializedElement, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

test "6.K.1: two runtimes share a table; FuncEntity routes to source" {
    // Source runtime A owns callee_a (returns 42); importer rt_b
    // calls A's func 0 via call_indirect. The FuncEntity pointer
    // stored in rt_b's table cell carries A's identity, so dispatch
    // resolves rt_a.funcs[0] even though rt_b.funcs is empty.
    const i32_arr = [_]zir.ValType{.i32};
    var callee_a = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee_a.deinit(testing.allocator);
    try callee_a.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42, .extra = 0 });
    try callee_a.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var rt_a = Runtime.init(testing.allocator);
    defer rt_a.deinit();
    const funcs_a = [_]*const zir.ZirFunc{&callee_a};
    rt_a.funcs = &funcs_a;
    var entities_a = [_]runtime.FuncEntity{.{ .runtime = &rt_a, .func_idx = 0, .typeidx = 0, .funcptr = 0 }};
    rt_a.func_entities = &entities_a;

    var caller = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .call_indirect, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt_b = Runtime.init(testing.allocator);
    defer rt_b.deinit();
    // rt_b has no funcs of its own — proves dispatch routes to rt_a.
    var refs = [_]runtime.Value{runtime.Value.fromFuncRef(&entities_a[0])};
    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt_b.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &i32_arr }};
    rt_b.module_types = &types;

    try rt_b.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt_b.popFrame();
    try dispatch_loop.run(&rt_b, &t, caller.instrs.items);
    try testing.expectEqual(@as(u32, 42), rt_b.popOperand().u32);
}

// D-325 — cross-instance `call_indirect` must run the callee in ITS runtime
// context (own globals/memory), not the caller's. The `6.K.1` test above pins
// cross-runtime table DISPATCH (value routing); the GLOBALS-context boundary is
// pinned end-to-end by the REQ-5 dropResource test (component_tests.zig): a
// wit-bindgen guest destructor reached via the shim's `$imports` table accesses
// module 0's globals, which trapped pre-fix. A synthetic two-runtime unit test
// would need a fully-instantiated source runtime (heap-owned globals + frame
// storage) — the real e2e test is the authentic, ownership-correct fixture.

// ============================================================
// Wasm 3.0 function-references: call_ref (10.R-4)
// ============================================================
//
// Tests push the funcref directly onto the operand stack rather
// than driving `ref.null` / `ref.func` (those handlers live in
// the Wasm-2.0 reference_types module, separately registered);
// this keeps the call_ref tests isolated to mvp.register's slot.

test "call_ref: null funcref → Trap.NullReference" {
    var caller = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .call_ref, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.table = &t;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try rt.pushOperand(.{ .ref = runtime.Value.null_ref });
    try testing.expectError(Trap.NullReference, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

test "call_ref: matching sig invokes callee via funcref on stack" {
    const i32_arr = [_]zir.ValType{.i32};
    var callee = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .call_ref, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.table = &t;
    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;
    var entities = [_]runtime.FuncEntity{.{ .runtime = &rt, .func_idx = 0, .typeidx = 0, .funcptr = 0 }};
    rt.func_entities = &entities;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &i32_arr }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try rt.pushOperand(runtime.Value.fromFuncRef(&entities[0]));
    try dispatch_loop.run(&rt, &t, caller.instrs.items);
    try testing.expectEqual(@as(u32, 7), rt.popOperand().u32);
}

test "call_ref: sig mismatch → Trap.IndirectCallTypeMismatch" {
    const i32_arr = [_]zir.ValType{.i32};
    // callee: () -> i32; expected (typeidx=0): () -> ()
    var callee = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .call_ref, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.table = &t;
    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;
    var entities = [_]runtime.FuncEntity{.{ .runtime = &rt, .func_idx = 0, .typeidx = 0, .funcptr = 0 }};
    rt.func_entities = &entities;
    // module_types[0] = () -> () but callee.sig = () -> i32 → mismatch.
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try rt.pushOperand(runtime.Value.fromFuncRef(&entities[0]));
    try testing.expectError(Trap.IndirectCallTypeMismatch, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

// ============================================================
// Wasm 3.0 function-references + tail-call: return_call_ref (10.R-5)
// ============================================================

test "return_call_ref: null funcref → Trap.NullReference" {
    var caller = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .return_call_ref, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.table = &t;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try rt.pushOperand(.{ .ref = runtime.Value.null_ref });
    try testing.expectError(Trap.NullReference, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

test "return_call_ref: matching sig — callee result becomes caller result; caller frame done" {
    const i32_arr = [_]zir.ValType{.i32};
    var callee = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 11, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    // caller: () -> i32. The funcref is pushed manually; then
    // return_call_ref typeidx=0 promotes callee's 11 to caller's result.
    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .return_call_ref, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.table = &t;
    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;
    var entities = [_]runtime.FuncEntity{.{ .runtime = &rt, .func_idx = 0, .typeidx = 0, .funcptr = 0 }};
    rt.func_entities = &entities;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &i32_arr }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try rt.pushOperand(runtime.Value.fromFuncRef(&entities[0]));
    try dispatch_loop.run(&rt, &t, caller.instrs.items);
    // After the tail-call: callee's 11 promoted to caller's result;
    // caller frame marked done; stack reset to caller's operand_base + arity=1.
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 11), rt.popOperand().u32);
    try testing.expect(rt.currentFrame().done);
}

// ============================================================
// Wasm 3.0 tail-call: return_call + return_call_indirect (10.TC-1)
// ============================================================

test "return_call: invokes callee + promotes its result to caller frame done" {
    const i32_arr = [_]zir.ValType{.i32};
    var callee = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 21, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .return_call, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.table = &t;
    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try dispatch_loop.run(&rt, &t, caller.instrs.items);
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 21), rt.popOperand().u32);
    try testing.expect(rt.currentFrame().done);
}

test "return_call: chained A→B→C tail calls preserve frame depth (safepoint-free)" {
    // Wasm tail-call semantics: each `return_call` REPLACES the
    // current frame (not stacks). A chain of N return_calls
    // should keep frame_len == 1 throughout; observed value
    // propagates through the chain to the original caller's
    // result slot. Per ADR-0112 D7 safepoint-free invariant.
    const i32_arr = [_]zir.ValType{.i32};
    const sig: zir.FuncType = .{ .params = &.{}, .results = &i32_arr };

    var fn_c = zir.ZirFunc.init(0, sig, &.{});
    defer fn_c.deinit(testing.allocator);
    try fn_c.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 33, .extra = 0 });
    try fn_c.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var fn_b = zir.ZirFunc.init(1, sig, &.{});
    defer fn_b.deinit(testing.allocator);
    try fn_b.instrs.append(testing.allocator, .{ .op = .return_call, .payload = 0, .extra = 0 });
    try fn_b.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var fn_a = zir.ZirFunc.init(2, sig, &.{});
    defer fn_a.deinit(testing.allocator);
    try fn_a.instrs.append(testing.allocator, .{ .op = .return_call, .payload = 1, .extra = 0 });
    try fn_a.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.table = &t;
    const funcs = [_]*const zir.ZirFunc{ &fn_c, &fn_b, &fn_a };
    rt.funcs = &funcs;

    try rt.pushFrame(.{ .sig = fn_a.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fn_a });
    defer _ = rt.popFrame();
    const initial_frame_len = rt.frame_len;
    try dispatch_loop.run(&rt, &t, fn_a.instrs.items);
    // Tail-call invariant: frame depth unchanged after the chain.
    try testing.expectEqual(initial_frame_len, rt.frame_len);
    // Result from leaf (fn_c) propagated to the originally-pushed frame.
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 33), rt.popOperand().u32);
    try testing.expect(rt.currentFrame().done);
}

test "return_call: funcidx OOB → Trap.Unreachable" {
    var caller = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .return_call, .payload = 99, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.table = &t;
    // rt.funcs is empty → idx=99 is OOB.

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try testing.expectError(Trap.Unreachable, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

test "return_call_indirect: matching sig → callee result becomes caller result" {
    const i32_arr = [_]zir.ValType{.i32};
    var callee = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 13, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    // caller: i32.const 0 ; return_call_indirect typeidx=0 tableidx=0 → 13
    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .return_call_indirect, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.table = &t;
    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;
    var entities = [_]runtime.FuncEntity{.{ .runtime = &rt, .func_idx = 0, .typeidx = 0, .funcptr = 0 }};
    rt.func_entities = &entities;
    var refs = [_]runtime.Value{runtime.Value.fromFuncRef(&entities[0])};
    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &i32_arr }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try dispatch_loop.run(&rt, &t, caller.instrs.items);
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 13), rt.popOperand().u32);
    try testing.expect(rt.currentFrame().done);
}

test "return_call_indirect: sig mismatch → Trap.IndirectCallTypeMismatch" {
    const i32_arr = [_]zir.ValType{.i32};
    var callee = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .return_call_indirect, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.table = &t;
    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;
    var entities = [_]runtime.FuncEntity{.{ .runtime = &rt, .func_idx = 0, .typeidx = 0, .funcptr = 0 }};
    rt.func_entities = &entities;
    var refs = [_]runtime.Value{runtime.Value.fromFuncRef(&entities[0])};
    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    // module_types[0] = () -> (); callee.sig = () -> i32 → mismatch.
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try testing.expectError(Trap.IndirectCallTypeMismatch, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

test "return_call_ref: sig mismatch → Trap.IndirectCallTypeMismatch" {
    const i32_arr = [_]zir.ValType{.i32};
    // callee: () -> i32; expected (typeidx=0): () -> () → mismatch.
    var callee = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .return_call_ref, .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .end, .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.table = &t;
    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;
    var entities = [_]runtime.FuncEntity{.{ .runtime = &rt, .func_idx = 0, .typeidx = 0, .funcptr = 0 }};
    rt.func_entities = &entities;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try rt.pushOperand(runtime.Value.fromFuncRef(&entities[0]));
    try testing.expectError(Trap.IndirectCallTypeMismatch, dispatch_loop.run(&rt, &t, caller.instrs.items));
}
