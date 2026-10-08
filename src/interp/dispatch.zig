//! Threaded-code dispatch loop (Phase 2 / §9.2 / 2.1).
//!
//! Looks up the handler for each `ZirInstr.op` in
//! `DispatchTable.interp` and invokes it. Per ROADMAP §A12 the
//! dispatcher does not branch on feature flags; an unbound slot
//! is `Trap.Unreachable`. The full MVP handler set lands in
//! §9.2 / 2.2 (feature/mvp/runtime.zig); 2.1 only delivers the
//! dispatch primitive plus a smoke-shaped `run` outer loop.
//!
//! The Zig 0.16 toolchain does not guarantee tail-call elimination
//! per the wasm3 idiom (`m3_exec.c` macro tower). zwasm v2's
//! divergence: a plain `while` loop over `[]const ZirInstr` indexed
//! by `pc`. The cost vs. wasm3-style threaded code is measurable
//! and gets revisited in Phase 15 (§4.3 — "interpreter / JIT / AOT
//! share one path"); for the Phase-2 spec gate, correctness is the
//! priority over μs/op throughput.
//!
//! Zone 2 (`src/interp/`) — may import Zone 0 + 1 + sibling
//! `src/runtime/runtime.zig`.

const std = @import("std");

pub const zir = @import("../ir/zir.zig");
const dispatch_table = @import("../ir/dispatch_table.zig");
const runtime = @import("../runtime/runtime.zig");

const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;
const DispatchTable = dispatch_table.DispatchTable;
const Runtime = runtime.Runtime;
const Trap = runtime.Trap;

/// Run a single instruction by looking up its handler in `table` and
/// invoking it. An unbound slot returns `Trap.Unreachable` per
/// ROADMAP §A12 — the alternative would be silent passthrough.
pub fn step(
    rt: *Runtime,
    table: *const DispatchTable,
    instr: *const ZirInstr,
) anyerror!void {
    const idx = @intFromEnum(instr.op);
    if (idx >= dispatch_table.N_OPS) return Trap.Unreachable;
    const handler = table.interp[idx] orelse return Trap.Unreachable;
    const saved_pc = if (rt.frame_len > 0) rt.currentFrame().pc else 0;
    try handler(rt.toOpaque(), instr);
    if (rt.trace_cb) |cb| {
        cb(rt.trace_ctx.?, .{
            .pc = saved_pc,
            .op = instr.op,
            .operand_top = if (rt.operand_len > 0) rt.operand_buf[rt.operand_len - 1] else null,
            .frame_depth = rt.frame_len,
        });
    }
}

/// Walk an instruction sequence linearly. The loop tracks `pc`
/// on the **current frame** (`rt.currentFrame().pc`) so control-
/// flow handlers (`br` / `br_if` / `br_table` / `return` / `if`
/// / `else` / `end`) can mutate it directly. If a handler does
/// not change `pc`, the loop advances by 1.
///
/// If no frame is active when `run` is called, an ephemeral frame
/// (empty sig + empty locals) is pushed for the duration. This
/// keeps small handler tests green without forcing every test to
/// stage a full frame.
///
/// `rt.debug_hook` is read once here and picks one of two loops, so with no
/// hook the loop has no per-instruction check. A hook installed while a call
/// runs is first seen by the next call into `run`; a tail call switches bodies
/// inside the loop and does not re-enter.
pub fn run(
    rt: *Runtime,
    table: *const DispatchTable,
    initial_instrs: []const ZirInstr,
) anyerror!void {
    if (rt.debug_hook != null) return runImpl(true, rt, table, initial_instrs);
    return runImpl(false, rt, table, initial_instrs);
}

inline fn runImpl(
    comptime with_hook: bool,
    rt: *Runtime,
    table: *const DispatchTable,
    initial_instrs: []const ZirInstr,
) anyerror!void {
    const saved_table = rt.table;
    rt.table = table;
    defer rt.table = saved_table;

    const entry_depth = rt.frame_len;
    const ephemeral = rt.frame_len == 0;
    if (ephemeral) {
        const empty_sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
        try rt.pushFrame(.{
            .sig = empty_sig,
            .locals = &.{},
            .operand_base = rt.operand_len,
            .pc = 0,
        });
    }
    defer if (ephemeral) {
        _ = rt.popFrame();
    };

    // Trampoline state (10.TC interp trampoline; D-187 discharge).
    // Each tail-call switch allocates fresh callee locals; the
    // PREVIOUS iteration's trampoline alloc is freed at the
    // start of the next switch. The locals for the LAST callee
    // in the chain are freed at exit (defer). The initial
    // frame's locals — alloc'd by the caller of dispatch.run
    // (`Instance.invoke` / `mvp.invoke`) — are NOT touched here;
    // the caller's own defer-free retains ownership.
    var prev_trampoline_locals: ?[]runtime.Value = null;
    defer if (prev_trampoline_locals) |l| rt.alloc.free(l);

    // `debug_trap` hears the error that ends the call from here, errors raised
    // outside an instruction (fuel, interrupt, the hook's own stop) included.
    // Declared after the defer above so it runs first, while a tail callee's
    // locals are still allocated; `invoke` pops the frame only after `run`
    // returns, so its pc is where the call stopped. At another depth the frame
    // is not this call's — a frame `run` pushed for itself, or a tail-call
    // switch that failed after popping — and the report is left to the caller.
    // With this `errdefer |err|` in the function, Zig 0.16 rejects returning a
    // named error-set value, so the returns below spell `error.X`.
    errdefer |err| {
        if (comptime with_hook) {
            if (rt.debug_trap) |report| {
                if (entry_depth > 0 and rt.frame_len == entry_depth) report(rt.debug_ctx.?, rt.currentFrame().pc, err);
            }
        }
    }

    var instrs = initial_instrs;
    while (true) {
        const f = rt.currentFrame();
        f.pc = 0;
        f.done = false;
        while (f.pc < instrs.len and !f.done) {
            // ADR-0179 #3a: throttled cooperative-interrupt poll so a tight
            // `(loop (br 0))` with no calls is still interruptible. Zero cost
            // when no flag is configured (one predictable optional-unwrap).
            if (rt.interrupt) |flag| {
                rt.interrupt_tick +%= 1;
                if (rt.interrupt_tick & runtime.Runtime.INTERRUPT_CHECK_MASK == 0 and
                    flag.load(.monotonic) != 0) return error.Interrupted;
            }
            // ADR-0179 #3b: deterministic fuel — exact per-instruction decrement
            // (no throttle, unlike the interrupt poll), trap at exhaustion.
            if (rt.fuel) |*remaining| {
                if (remaining.* == 0) return error.OutOfFuel;
                remaining.* -= 1;
            }
            const cur = f.pc;
            if (comptime with_hook) {
                if (rt.debug_hook.?(rt.debug_ctx.?, cur)) return error.Interrupted;
            }
            try step(rt, table, &instrs[cur]);
            if (f.pc == cur) f.pc += 1;
        }

        const next_callee = rt.pending_tail_call orelse break;
        rt.pending_tail_call = null;

        // Tail-call frame switch: caller already marked done by
        // `returnCallOp` (sig leaves args at top of operand
        // stack: operand_buf[caller.operand_base..operand_len]).
        // Pop caller frame, alloc fresh callee locals, pop args
        // into locals, zero-init declared locals, push callee.
        _ = rt.popFrame();

        const params_len = next_callee.sig.params.len;
        const total = params_len + next_callee.locals.len;
        const new_locals = try rt.alloc.alloc(runtime.Value, total);

        // Pop args in reverse so last param popped first lands at
        // locals[params_len-1]. operand_len underflow guard
        // mirrors `mvp.invoke`'s defensive check.
        var i: usize = params_len;
        while (i > 0) {
            i -= 1;
            if (rt.operand_len == 0) {
                rt.alloc.free(new_locals);
                return error.StackOverflow;
            }
            new_locals[i] = rt.popOperand();
        }
        var j: usize = params_len;
        while (j < total) : (j += 1) new_locals[j] = runtime.Value.zero;

        rt.pushFrame(.{
            .sig = next_callee.sig,
            .locals = new_locals,
            .operand_base = rt.operand_len,
            .pc = 0,
            .func = next_callee,
        }) catch |e| {
            rt.alloc.free(new_locals);
            return @as(anyerror!void, e);
        };

        // Free PREVIOUS iteration's trampoline alloc — that
        // frame just got popped, and the alloc is no longer
        // referenced. The very first switch has nothing to free
        // (the popped frame's locals belong to the caller of
        // dispatch.run, not the trampoline).
        if (prev_trampoline_locals) |l| rt.alloc.free(l);
        prev_trampoline_locals = new_locals;

        // Switch to the callee's instruction stream — without this
        // the outer loop would re-run the caller's instrs against
        // the new frame and tail-call indefinitely.
        instrs = next_callee.instrs.items;
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const StubHandlers = struct {
    fn nop(_: *dispatch_table.InterpCtx, _: *const ZirInstr) anyerror!void {
        // Test stub — intentionally empty.
    }

    fn pushI32Const(opaque_ctx: *dispatch_table.InterpCtx, instr: *const ZirInstr) anyerror!void {
        const rt = Runtime.fromOpaque(opaque_ctx);
        const v: i32 = @bitCast(@as(u32, @truncate(instr.payload)));
        try rt.pushOperand(.{ .i32 = v });
    }
};

fn buildSmokeTable() DispatchTable {
    var t = DispatchTable.init();
    t.interp[@intFromEnum(ZirOp.nop)] = StubHandlers.nop;
    t.interp[@intFromEnum(ZirOp.@"i32.const")] = StubHandlers.pushI32Const;
    return t;
}

test "step: unbound op slot returns Trap.Unreachable" {
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const table = DispatchTable.init();
    const instr: ZirInstr = .{ .op = .@"i32.const", .payload = 0, .extra = 0 };
    try testing.expectError(Trap.Unreachable, step(&rt, &table, &instr));
}

test "step: bound i32.const handler pushes the payload" {
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const table = buildSmokeTable();

    const instr: ZirInstr = .{ .op = .@"i32.const", .payload = @as(u64, @as(u32, @bitCast(@as(i32, 42)))), .extra = 0 };
    try step(&rt, &table, &instr);

    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 42), rt.popOperand().i32);
}

test "run: walks sequence, leaves operand stack with the const sequence" {
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const table = buildSmokeTable();

    const instrs = [_]ZirInstr{
        .{ .op = .@"i32.const", .payload = @as(u64, @as(u32, @bitCast(@as(i32, 1)))), .extra = 0 },
        .{ .op = .@"i32.const", .payload = @as(u64, @as(u32, @bitCast(@as(i32, 2)))), .extra = 0 },
        .{ .op = .nop, .payload = 0, .extra = 0 },
        .{ .op = .@"i32.const", .payload = @as(u64, @as(u32, @bitCast(@as(i32, 3)))), .extra = 0 },
    };
    try run(&rt, &table, &instrs);

    try testing.expectEqual(@as(u32, 3), rt.operand_len);
    try testing.expectEqual(@as(i32, 3), rt.popOperand().i32);
    try testing.expectEqual(@as(i32, 2), rt.popOperand().i32);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}

test "trace_cb: receives one event per dispatched instruction" {
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const table = buildSmokeTable();

    const TraceSink = struct {
        events: [16]runtime.TraceEvent = undefined,
        len: u32 = 0,

        fn cb(ctx: *anyopaque, ev: runtime.TraceEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.len < self.events.len) {
                self.events[self.len] = ev;
                self.len += 1;
            }
        }
    };
    var sink: TraceSink = .{};
    rt.trace_cb = TraceSink.cb;
    rt.trace_ctx = @ptrCast(&sink);

    const instrs = [_]ZirInstr{
        .{ .op = .@"i32.const", .payload = @as(u64, @as(u32, @bitCast(@as(i32, 11)))), .extra = 0 },
        .{ .op = .nop, .payload = 0, .extra = 0 },
        .{ .op = .@"i32.const", .payload = @as(u64, @as(u32, @bitCast(@as(i32, 22)))), .extra = 0 },
    };
    try run(&rt, &table, &instrs);

    try testing.expectEqual(@as(u32, 3), sink.len);
    try testing.expectEqual(ZirOp.@"i32.const", sink.events[0].op);
    try testing.expectEqual(@as(i32, 11), sink.events[0].operand_top.?.i32);
    try testing.expectEqual(ZirOp.nop, sink.events[1].op);
    try testing.expectEqual(@as(i32, 11), sink.events[1].operand_top.?.i32);
    try testing.expectEqual(ZirOp.@"i32.const", sink.events[2].op);
    try testing.expectEqual(@as(i32, 22), sink.events[2].operand_top.?.i32);
}

test "trace_cb: null callback is zero-cost (no error path)" {
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const table = buildSmokeTable();
    // rt.trace_cb left null by default.

    const instrs = [_]ZirInstr{
        .{ .op = .@"i32.const", .payload = @as(u64, @as(u32, @bitCast(@as(i32, 5)))), .extra = 0 },
    };
    try run(&rt, &table, &instrs);
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
}

test "debug_hook: stops before the instruction it rejects" {
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const table = buildSmokeTable();

    const Hook = struct {
        pcs: [8]u32 = undefined,
        len: u32 = 0,

        fn cb(ctx: *anyopaque, pc: u32) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.pcs[self.len] = pc;
            self.len += 1;
            return pc == 2;
        }
    };
    var h: Hook = .{};
    rt.debug_hook = Hook.cb;
    rt.debug_ctx = @ptrCast(&h);

    const instrs = [_]ZirInstr{
        .{ .op = .@"i32.const", .payload = 1, .extra = 0 },
        .{ .op = .@"i32.const", .payload = 2, .extra = 0 },
        .{ .op = .@"i32.const", .payload = 3, .extra = 0 },
    };
    try testing.expectError(Trap.Interrupted, run(&rt, &table, &instrs));

    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, h.pcs[0..h.len]);
    try testing.expectEqual(@as(u32, 2), rt.operand_len);
}

test "debug_trap: hears the error that ends the call, with the call's frame still on the stack" {
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var t = DispatchTable.init();
    t.interp[@intFromEnum(ZirOp.@"i32.const")] = StubHandlers.pushI32Const;
    // .nop slot left null → step fails with Trap.Unreachable at pc 1.

    const Sink = struct {
        rt: *Runtime,
        pc: ?u32 = null,
        err: ?anyerror = null,
        frame_len: u32 = 0,

        fn hook(_: *anyopaque, _: u32) bool {
            return false;
        }
        fn trap(ctx: *anyopaque, pc: u32, err: anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.pc = pc;
            self.err = err;
            self.frame_len = self.rt.frame_len;
        }
    };
    var sink: Sink = .{ .rt = &rt };
    rt.debug_hook = Sink.hook;
    rt.debug_trap = Sink.trap;
    rt.debug_ctx = @ptrCast(&sink);

    // The call's frame, pushed as `invoke` pushes it; `run` leaves it to the caller.
    try rt.pushFrame(.{ .sig = .{ .params = &.{}, .results = &.{} }, .locals = &.{}, .operand_base = 0, .pc = 0 });
    defer _ = rt.popFrame();

    const instrs = [_]ZirInstr{
        .{ .op = .@"i32.const", .payload = 7, .extra = 0 },
        .{ .op = .nop, .payload = 0, .extra = 0 },
    };
    try testing.expectError(Trap.Unreachable, run(&rt, &t, &instrs));

    try testing.expectEqual(@as(?u32, 1), sink.pc);
    try testing.expectEqual(@as(?anyerror, Trap.Unreachable), sink.err);
    try testing.expectEqual(@as(u32, 1), sink.frame_len);
}

test "run: bubbles handler trap and stops iteration" {
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var t = DispatchTable.init();
    t.interp[@intFromEnum(ZirOp.@"i32.const")] = StubHandlers.pushI32Const;
    // .nop slot left null → step returns Trap.Unreachable on the second instr.

    const instrs = [_]ZirInstr{
        .{ .op = .@"i32.const", .payload = @as(u64, @as(u32, @bitCast(@as(i32, 7)))), .extra = 0 },
        .{ .op = .nop, .payload = 0, .extra = 0 },
        .{ .op = .@"i32.const", .payload = @as(u64, @as(u32, @bitCast(@as(i32, 99)))), .extra = 0 },
    };
    try testing.expectError(Trap.Unreachable, run(&rt, &t, &instrs));

    // 7 was pushed before the trap; 99 was not reached.
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 7), rt.popOperand().i32);
}
