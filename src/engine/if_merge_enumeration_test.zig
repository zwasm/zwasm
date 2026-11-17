//! Enumerates control-frame shapes that close short and checks the JIT
//! against the interpreter for each: same value, same trap, or a JIT
//! decline counted as such (#751). The four defects this PR's branch found
//! — #739's else-arm and implicit-else shapes, #399's dead-body block, the
//! parameterised-else drift (Devin) and the twin-short-arm drift (review) —
//! all live in the sweep, so a fifth shape of the same class fails here
//! instead of reaching a release.
//!
//! The modules are assembled in-test (no committed binary). `f` always has
//! type `(i32) -> (i32)`: local 0 is the branch condition, and the body
//! folds every value the frame leaves, plus the enclosing values below it,
//! into one i32, so a vreg the JIT numbers one off changes the result.

const std = @import("std");
const testing = std.testing;
const zwasm = @import("../zwasm.zig");

const Ty = enum { i32, f64, ref };
const Kind = enum { if_, block, loop };
// How the then-arm (if) or the body (block/loop) ends.
const BodyEnd = enum { normal, short0, short1 };
// The else arm of an `if`.
const Else = enum { none, normal, short0, short1 };

const Shape = struct {
    kind: Kind,
    ty: Ty,
    params: u8, // frame params (if only; 0 for block/loop)
    results: u8, // frame results
    enclosing: u8, // i32 values below the frame
    body: BodyEnd,
    else_: Else,
    outer_skip: bool, // wrap in `block … br_if 0` and observe a tail witness
};

// --- wasm encoding ---------------------------------------------------------

fn uleb(out: *std.ArrayList(u8), a: std.mem.Allocator, v: u64) !void {
    var x = v;
    while (true) {
        const b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x == 0) {
            try out.append(a, b);
            break;
        }
        try out.append(a, b | 0x80);
    }
}

fn sleb(out: *std.ArrayList(u8), a: std.mem.Allocator, v: i64) !void {
    var x = v;
    while (true) {
        const b: u8 = @intCast(@as(u64, @bitCast(x)) & 0x7f);
        x >>= 7;
        const done = (x == 0 and (b & 0x40) == 0) or (x == -1 and (b & 0x40) != 0);
        if (done) {
            try out.append(a, b);
            break;
        }
        try out.append(a, b | 0x80);
    }
}

fn valByte(t: Ty) u8 {
    return switch (t) {
        .i32 => 0x7f,
        .f64 => 0x7c,
        .ref => 0x70, // funcref
    };
}

// Push one value of type `t`; `n` makes successive values distinct.
fn pushConst(out: *std.ArrayList(u8), a: std.mem.Allocator, t: Ty, n: u32) !void {
    switch (t) {
        .i32 => {
            try out.append(a, 0x41); // i32.const
            try sleb(out, a, @as(i64, n) + 1);
        },
        .f64 => {
            try out.append(a, 0x44); // f64.const
            const f: f64 = @floatFromInt(n + 1);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @bitCast(f), .little);
            try out.appendSlice(a, &buf);
        },
        .ref => {
            if (n % 2 == 0) {
                try out.append(a, 0xd2); // ref.func
                try uleb(out, a, 0); // func 0 (declared below)
            } else {
                try out.append(a, 0xd0); // ref.null
                try out.append(a, 0x70); // func heaptype
            }
        },
    }
}

// Convert the top-of-stack value of type `t` to i32 in place.
fn toI32(out: *std.ArrayList(u8), a: std.mem.Allocator, t: Ty) !void {
    switch (t) {
        .i32 => {},
        .f64 => {
            try out.append(a, 0xfc); // i32.trunc_sat_f64_s
            try out.append(a, 0x02);
        },
        .ref => try out.append(a, 0xd1), // ref.is_null
    }
}

// Blocktype for `params` params / `results` results of type `t`, written
// either as the short single-byte form or an s33 type index.
fn writeBlockType(out: *std.ArrayList(u8), a: std.mem.Allocator, sh: Shape, type_index: u32) !void {
    if (sh.params == 0 and sh.results == 0) {
        try out.append(a, 0x40);
    } else if (sh.params == 0 and sh.results == 1) {
        try out.append(a, valByte(sh.ty));
    } else {
        try sleb(out, a, @intCast(type_index));
    }
}

fn needsTypeIndex(sh: Shape) bool {
    return !(sh.params == 0 and (sh.results == 0 or sh.results == 1));
}

// Emit the frame body (then-arm / block body) that ends per `be`, leaving
// `results` values of type `ty` or a terminator.
fn emitBody(out: *std.ArrayList(u8), a: std.mem.Allocator, sh: Shape, be: BodyEnd, tag: u32) !void {
    switch (be) {
        .normal => {
            // Drop any params, then push `results` fresh values.
            var i: u8 = 0;
            while (i < sh.params) : (i += 1) try out.append(a, 0x1a); // drop
            i = 0;
            while (i < sh.results) : (i += 1) try pushConst(out, a, sh.ty, tag * 16 + i);
        },
        .short0 => {
            try out.append(a, 0x00); // unreachable
        },
        .short1 => {
            try pushConst(out, a, sh.ty, tag * 16 + 9);
            try out.append(a, 0x00); // unreachable
        },
    }
}

// Fold E enclosing i32s + R frame results (type ty) on the stack into one
// i32, leaving exactly one result. Each result is converted to i32 and added
// into local 1 (an i32 accumulator) as it reaches the top, so a conversion
// never sees a value of the wrong type below it.
fn emitFold(out: *std.ArrayList(u8), a: std.mem.Allocator, enclosing: u8, results: u8, ty: Ty) !void {
    var r: u8 = 0;
    while (r < results) : (r += 1) {
        try toI32(out, a, ty); // current top (a result) → i32
        try out.append(a, 0x20); // local.get 1
        try uleb(out, a, 1);
        try out.append(a, 0x6a); // i32.add
        try out.append(a, 0x21); // local.set 1
        try uleb(out, a, 1);
    }
    // Stack is now the E enclosing i32s. Push the accumulated results, add them.
    try out.append(a, 0x20); // local.get 1
    try uleb(out, a, 1);
    var i: u8 = 0;
    while (i < enclosing) : (i += 1) try out.append(a, 0x6a); // i32.add
}

fn build(a: std.mem.Allocator, sh: Shape) !?[]u8 {
    // Reject shapes we do not emit as valid wasm.
    if (sh.kind != .if_ and sh.params != 0) return null;
    if (sh.kind == .if_ and sh.else_ == .none and sh.params != sh.results) return null;
    if (sh.kind != .if_ and sh.else_ != .none) return null;
    if (sh.body == .short1 and sh.results < 1) return null;
    if (sh.else_ == .short1 and sh.results < 1) return null;
    if (sh.outer_skip and sh.kind != .if_) return null;
    // ref.func needs func 0 declared; keep the ref family small.
    if (sh.ty == .ref and (sh.results > 1 or sh.enclosing > 1)) return null;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);

    const use_ref = sh.ty == .ref;

    // Enclosing i32 values below the frame.
    var e: u8 = 0;
    while (e < sh.enclosing) : (e += 1) {
        try body.append(a, 0x41);
        try sleb(&body, a, @as(i64, e) + 100);
    }

    if (sh.outer_skip) {
        // block … local.get 0 ; br_if 0 ; <frame> ; drop results ; end ; tail
        try body.append(a, 0x02); // block
        try body.append(a, 0x40); // void
        try body.append(a, 0x20); // local.get 0
        try uleb(&body, a, 0);
        try body.append(a, 0x0d); // br_if 0
        try uleb(&body, a, 0);
    }

    // Frame.
    const type_index: u32 = 1; // frame's functype is type 1 when needed
    switch (sh.kind) {
        .if_ => {
            // params then condition
            var p: u8 = 0;
            while (p < sh.params) : (p += 1) try pushConst(&body, a, sh.ty, 50 + p);
            try body.append(a, 0x20); // local.get 0 (condition)
            try uleb(&body, a, 0);
            try body.append(a, 0x04); // if
            try writeBlockType(&body, a, sh, type_index);
            try emitBody(&body, a, sh, sh.body, 1);
            if (sh.else_ != .none) {
                try body.append(a, 0x05); // else
                const ebe: BodyEnd = switch (sh.else_) {
                    .normal => .normal,
                    .short0 => .short0,
                    .short1 => .short1,
                    .none => unreachable,
                };
                try emitBody(&body, a, sh, ebe, 2);
            }
            try body.append(a, 0x0b); // end
        },
        .block, .loop => {
            try body.append(a, if (sh.kind == .block) @as(u8, 0x02) else 0x03);
            try writeBlockType(&body, a, sh, type_index);
            try emitBody(&body, a, sh, sh.body, 1);
            try body.append(a, 0x0b); // end
        },
    }

    if (sh.outer_skip) {
        // drop the frame's results, close the outer block, then a live tail
        var r: u8 = 0;
        while (r < sh.results) : (r += 1) try body.append(a, 0x1a); // drop
        try body.append(a, 0x0b); // end (outer block)
        // tail witness: six distinct consts summed, so the regalloc keeps
        // several live temporaries whose slots a drifted frame vreg can
        // collide with (#751), then fold with the enclosing values.
        const tail_consts = [_]i64{ 7, 11, 13, 17, 19, 23 };
        for (tail_consts) |c| {
            try body.append(a, 0x41);
            try sleb(&body, a, c);
        }
        var k: u32 = 1;
        while (k < tail_consts.len) : (k += 1) try body.append(a, 0x6a); // i32.add
        var i: u32 = 0;
        while (i < sh.enclosing) : (i += 1) try body.append(a, 0x6a); // i32.add
    } else {
        try emitFold(&body, a, sh.enclosing, sh.results, sh.ty);
    }

    // --- assemble module ---
    var mod: std.ArrayList(u8) = .empty;
    defer mod.deinit(a);
    try mod.appendSlice(a, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    // type section: type 0 = (i32)->(i32); type 1 = frame functype (if needed)
    var types: std.ArrayList(u8) = .empty;
    defer types.deinit(a);
    const emit_frame_type = needsTypeIndex(sh);
    const n_types: u32 = if (emit_frame_type) 2 else 1;
    try uleb(&types, a, n_types);
    // type 0
    try types.appendSlice(a, &.{ 0x60, 0x01, 0x7f, 0x01, 0x7f });
    if (emit_frame_type) {
        try types.append(a, 0x60);
        try uleb(&types, a, sh.params);
        var p: u8 = 0;
        while (p < sh.params) : (p += 1) try types.append(a, valByte(sh.ty));
        try uleb(&types, a, sh.results);
        var r: u8 = 0;
        while (r < sh.results) : (r += 1) try types.append(a, valByte(sh.ty));
    }
    try section(&mod, a, 1, types.items);

    // function section: func 0 : type 0
    try section(&mod, a, 3, &.{ 0x01, 0x00 });

    // export section: "f" = func 0
    try section(&mod, a, 7, &.{ 0x01, 0x01, 'f', 0x00, 0x00 });

    // (ref family) declarative elem segment declaring func 0 so `ref.func 0`
    // validates. Section 9 follows the export section (§5.5 order).
    if (use_ref) {
        var elem: std.ArrayList(u8) = .empty;
        defer elem.deinit(a);
        try uleb(&elem, a, 1); // 1 segment
        try elem.append(a, 0x03); // flags: declarative, elemkind + funcidxs
        try elem.append(a, 0x00); // elemkind: funcref
        try uleb(&elem, a, 1); // 1 funcidx
        try uleb(&elem, a, 0); // func 0
        try section(&mod, a, 9, elem.items);
    }

    // code section
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(a);
    try uleb(&code, a, 1); // 1 body
    var func_body: std.ArrayList(u8) = .empty;
    defer func_body.deinit(a);
    try func_body.appendSlice(a, &.{ 0x01, 0x01, 0x7f }); // 1 local group: 1 × i32 (the fold accumulator, local 1)
    try func_body.appendSlice(a, body.items);
    try func_body.append(a, 0x0b); // final end
    try uleb(&code, a, func_body.items.len);
    try code.appendSlice(a, func_body.items);
    try section(&mod, a, 10, code.items);

    return try mod.toOwnedSlice(a);
}

fn section(mod: *std.ArrayList(u8), a: std.mem.Allocator, id: u8, payload: []const u8) !void {
    try mod.append(a, id);
    try uleb(mod, a, payload.len);
    try mod.appendSlice(a, payload);
}

// --- running ---------------------------------------------------------------

const RunResult = union(enum) {
    value: i32,
    trap: anyerror,
    decline, // compile / instantiate failed (invalid module, or JIT decline)
};

fn runOne(bytes: []const u8, use_jit: bool, cond: i32) RunResult {
    var eng = zwasm.Engine.init(testing.allocator, .{}) catch return .decline;
    defer eng.deinit();
    var mod = eng.compile(bytes) catch return .decline;
    defer mod.deinit();
    var inst = mod.instantiate(.{ .engine = if (use_jit) .jit else .interp }) catch return .decline;
    defer inst.deinit();
    var args = [_]zwasm.Value{.{ .i32 = cond }};
    var res = [_]zwasm.Value{.{ .i32 = 0 }};
    inst.invoke("f", &args, &res) catch |e| return .{ .trap = e };
    return .{ .value = res[0].i32 };
}

const Tally = struct {
    cur: Shape = undefined,
    shapes: u32 = 0, // shapes the generator emitted bytes for
    invalid: u32 = 0, // emitted bytes the interpreter would not validate — a generator bug
    value_agree: u32 = 0, // both ran, same value
    trap_agree: u32 = 0, // both trapped the same way
    declined: u32 = 0, // interp ran, the JIT declined the (valid) module
    mismatch: u32 = 0,
    // Real comparisons (value_agree + trap_agree) per kind / per type, so an
    // axis value that never reached a running pair on both engines shows as 0.
    by_kind: [3]u32 = .{ 0, 0, 0 },
    by_ty: [3]u32 = .{ 0, 0, 0 },

    fn credit(t: *Tally) void {
        t.by_kind[@backingInt(t.cur.kind)] += 1;
        t.by_ty[@backingInt(t.cur.ty)] += 1;
    }
};

// Compare interp and JIT for one (shape, cond). Returns true on a real
// mismatch (both engines ran and disagreed).
fn compareOne(t: *Tally, bytes: []const u8, cond: i32) bool {
    const i = runOne(bytes, false, cond);
    if (i == .decline) {
        // The interpreter has no shape it validly declines, so a decline here
        // is a module the generator emitted that does not validate — the
        // comparison never happened. Counted and asserted to be zero, so a
        // broken shape cannot hide as a skipped one.
        t.invalid += 1;
        return false;
    }
    const j = runOne(bytes, true, cond);
    switch (j) {
        .decline => {
            t.declined += 1;
            return false;
        },
        .value => |jv| {
            if (i == .value and i.value == jv) {
                t.value_agree += 1;
                t.credit();
                return false;
            }
            t.mismatch += 1;
            printMismatch(t, cond, i, j);
            return true;
        },
        .trap => |je| {
            if (i == .trap and i.trap == je) {
                t.trap_agree += 1;
                t.credit();
                return false;
            }
            t.mismatch += 1;
            printMismatch(t, cond, i, j);
            return true;
        },
    }
}

fn printMismatch(t: *Tally, cond: i32, i: RunResult, j: RunResult) void {
    if (t.mismatch > 20) return;
    const sh = t.cur;
    std.debug.print("  MISMATCH kind={s} ty={s} P={d} R={d} E={d} body={s} else={s} skip={} cond={d} interp={s} jit={s}\n", .{
        @tagName(sh.kind), @tagName(sh.ty),    sh.params,     sh.results, sh.enclosing,
        @tagName(sh.body), @tagName(sh.else_), sh.outer_skip, cond,       rstr(i),
        rstr(j),
    });
}

fn rstr(r: RunResult) []const u8 {
    return switch (r) {
        .value => "value",
        .trap => "trap",
        .decline => "decline",
    };
}

const all_kinds = [_]Kind{ .if_, .block, .loop };
const all_tys = [_]Ty{ .i32, .f64, .ref };
const all_body = [_]BodyEnd{ .normal, .short0, .short1 };
const all_else = [_]Else{ .none, .normal, .short0, .short1 };

// Builds every shape, runs it on both engines, and tallies the comparison.
fn sweep(report: *Tally) !void {
    const a = testing.allocator;
    for (all_kinds) |kind| {
        for (all_tys) |ty| {
            for ([_]u8{ 0, 1, 2 }) |params| {
                for ([_]u8{ 0, 1, 2 }) |results| {
                    for ([_]u8{ 0, 1, 2, 3 }) |enclosing| {
                        for (all_body) |body| {
                            for (all_else) |else_| {
                                for ([_]bool{ false, true }) |outer_skip| {
                                    const sh = Shape{
                                        .kind = kind,
                                        .ty = ty,
                                        .params = params,
                                        .results = results,
                                        .enclosing = enclosing,
                                        .body = body,
                                        .else_ = else_,
                                        .outer_skip = outer_skip,
                                    };
                                    const maybe = try build(a, sh);
                                    const bytes = maybe orelse continue;
                                    defer a.free(bytes);
                                    report.shapes += 1;
                                    report.cur = sh;
                                    _ = compareOne(report, bytes, 0);
                                    _ = compareOne(report, bytes, 1);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

test "jit vs interp: control-frame shapes that close short agree (#739 / #399)" {
    var report = Tally{};
    try sweep(&report);
    std.debug.print(
        "if-merge-enum: {d} shapes, {d} invalid, {d} value-agree, {d} trap-agree, {d} jit-declined, {d} mismatch\n" ++
            "  by kind: if={d} block={d} loop={d}; by type: i32={d} f64={d} ref={d}\n",
        .{
            report.shapes,     report.invalid,    report.value_agree,
            report.trap_agree, report.declined,   report.mismatch,
            report.by_kind[0], report.by_kind[1], report.by_kind[2],
            report.by_ty[0],   report.by_ty[1],   report.by_ty[2],
        },
    );
    try testing.expectEqual(@as(u32, 0), report.mismatch);
    // Every shape the generator emits must validate and run on the interpreter;
    // a nonzero count means a module the comparison silently skipped.
    try testing.expectEqual(@as(u32, 0), report.invalid);
    try testing.expect(report.shapes > 200);
    // Both result kinds were actually compared on running engines.
    try testing.expect(report.value_agree > 500);
    try testing.expect(report.trap_agree > 0);
    // Every axis value reached a real comparison on both engines: an all-zero
    // row would mean that kind or type is never actually tested.
    for (report.by_kind) |n| try testing.expect(n > 0);
    for (report.by_ty) |n| try testing.expect(n > 0);
}
