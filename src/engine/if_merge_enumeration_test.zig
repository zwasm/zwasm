//! Enumerates control-frame shapes around an arm that ends early and checks
//! the JIT against the interpreter for each: same value, same trap, or a JIT
//! decline counted as such. The axes are the frame kind, its params and
//! results and their types, how each arm ends (`End`), and the values below
//! the frame.
//!
//! The modules are assembled in-test (no committed binary). `f` always has
//! type `(i32, i32) -> (i32)`: local 0 is the `if` condition, local 1 the
//! `br_if` / `br_table` / outer-skip condition, and the body folds every
//! value the frame leaves, plus the values below it, into one i32, so a vreg
//! the JIT reads from the wrong place changes the result.

const std = @import("std");
const testing = std.testing;
const zwasm = @import("../zwasm.zig");

const Ty = enum { i32, f64, ref };
const Kind = enum { if_, block, loop };
/// The type of an `if`'s params: its results' type, or another one.
const PTy = enum { same, other };
/// How an arm (an `if`'s then or else, a block or loop body) ends.
const End = enum {
    /// Drop the params, push the results.
    normal,
    /// `unreachable`, with the params still on the stack.
    short0,
    /// Drop the params, `unreachable`.
    drop0,
    /// One result value, `unreachable`.
    short1,
    /// One value of another type, `unreachable`.
    other1,
    /// Drop the params, one value more than the frame returns, `unreachable`.
    over,
    /// An i32, `return`.
    ret,
    /// A value of another type, `br` past the frame (outer skip only).
    br_out,
    /// A value of another type, `br_table` past the frame (outer skip only).
    brt_out,
    /// `br` to the function's label with an i32: the top param when it is
    /// one, else a fresh constant. A constant pushed and dropped first gives
    /// the regalloc a def to put in the carried value's register.
    br_fn,
    /// The same with `br_table`, its index a constant.
    brt_fn,
    /// `return` with the top param (an i32), after the same pushed-and-dropped
    /// constant.
    ret_param,
    /// The results, `br 0`: a branch to the frame's own label. Odd-numbered
    /// values, so a ref result is null where the `if`'s ref param is not.
    br_self,
    /// The same with `br_table`, its index a constant.
    brt_self,
    /// One more value above the params, `br 0`: the branch carries the top
    /// params and that value, each one slot below where it sat (as a then
    /// arm, on an `if` with no else).
    br_self_shift,
    /// The results, `br_if 0` on local 1, drop them, `unreachable`.
    brif_dead,
    /// The results, `br_if 0` on local 1, fall through with them.
    brif_live,
    /// The results, `br_if 0`, other values of their types, `br_if 0` again,
    /// drop those, fall through with the first.
    brif_twice,
    /// The results, `br_if 0`, drop them, other values of their types, fall
    /// through with those.
    brif_replace,
    /// A `try_table` whose catch clause targets this frame, a `throw` of the
    /// results' values, then `unreachable`: the arm is dead and the frame's
    /// `.end` is reached only through the landing pad.
    catch_self,
    /// `br_if 0` with the params still on the stack, so it carries them as
    /// the results, then as `normal` (params and results of one type and
    /// count only).
    brif_param,
};

const Shape = struct {
    kind: Kind,
    ty: Ty,
    pty: PTy,
    params: u8, // frame params (if only; 0 for block / loop)
    results: u8,
    enclosing: u8, // i32 values below the frame
    body: End, // the then arm, or the block / loop body
    else_: ?End, // the else arm; null = none (if only)
    outer_skip: bool, // inside `block … local.get 1 ; br_if 0 … end` with a tail witness
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

fn otherTy(t: Ty) Ty {
    return switch (t) {
        .i32 => .f64,
        .f64, .ref => .i32,
    };
}

fn paramTy(sh: Shape) Ty {
    return if (sh.pty == .same) sh.ty else otherTy(sh.ty);
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

fn localGet(out: *std.ArrayList(u8), a: std.mem.Allocator, idx: u32) !void {
    try out.append(a, 0x20);
    try uleb(out, a, idx);
}

// Blocktype: the short single-byte form, or type index 1 (the frame's type).
fn writeBlockType(out: *std.ArrayList(u8), a: std.mem.Allocator, sh: Shape) !void {
    if (sh.params == 0 and sh.results == 0) {
        try out.append(a, 0x40);
    } else if (sh.params == 0 and sh.results == 1) {
        try out.append(a, valByte(sh.ty));
    } else {
        try sleb(out, a, 1);
    }
}

fn needsTypeIndex(sh: Shape) bool {
    return !(sh.params == 0 and (sh.results == 0 or sh.results == 1));
}

fn drops(out: *std.ArrayList(u8), a: std.mem.Allocator, n: u8) !void {
    var i: u8 = 0;
    while (i < n) : (i += 1) try out.append(a, 0x1a);
}

fn pushResults(out: *std.ArrayList(u8), a: std.mem.Allocator, sh: Shape, n: u8, tag: u32) !void {
    var i: u8 = 0;
    while (i < n) : (i += 1) try pushConst(out, a, sh.ty, tag * 16 + i);
}

// Emit one arm. The stack on entry holds the frame's params (if any).
fn emitArm(out: *std.ArrayList(u8), a: std.mem.Allocator, sh: Shape, end: End, tag: u32) !void {
    switch (end) {
        .normal => {
            try drops(out, a, sh.params);
            try pushResults(out, a, sh, sh.results, tag);
        },
        .short0 => try out.append(a, 0x00), // unreachable
        .drop0 => {
            try drops(out, a, sh.params);
            try out.append(a, 0x00);
        },
        .short1 => {
            try pushConst(out, a, sh.ty, tag * 16 + 9);
            try out.append(a, 0x00);
        },
        .other1 => {
            try pushConst(out, a, otherTy(sh.ty), tag * 16 + 9);
            try out.append(a, 0x00);
        },
        .over => {
            try drops(out, a, sh.params);
            try pushResults(out, a, sh, sh.results + 1, tag);
            try out.append(a, 0x00);
        },
        .ret => {
            try pushConst(out, a, .i32, tag * 16 + 7);
            try out.append(a, 0x0f); // return
        },
        .br_out => {
            try pushConst(out, a, otherTy(sh.ty), tag * 16 + 9);
            try out.append(a, 0x0c); // br 1 (the outer skip block)
            try uleb(out, a, 1);
        },
        .brt_out => {
            try pushConst(out, a, otherTy(sh.ty), tag * 16 + 9);
            try localGet(out, a, 1);
            try out.appendSlice(a, &.{ 0x0e, 0x01, 0x01, 0x01 }); // br_table [1] default 1
        },
        .br_fn, .brt_fn, .ret_param => {
            if (!carriesParam(sh)) try pushConst(out, a, .i32, tag * 16 + 5);
            try pushConst(out, a, .i32, tag * 16 + 6);
            try out.append(a, 0x1a); // drop
            const fn_depth: u8 = if (sh.outer_skip) 2 else 1;
            if (end == .br_fn) {
                try out.appendSlice(a, &.{ 0x0c, fn_depth }); // br
            } else if (end == .brt_fn) {
                try pushConst(out, a, .i32, 0);
                try out.appendSlice(a, &.{ 0x0e, 0x01, fn_depth, fn_depth }); // br_table
            } else {
                try out.append(a, 0x0f); // return
            }
        },
        .br_self, .brt_self => {
            try drops(out, a, sh.params);
            var i: u8 = 0;
            while (i < sh.results) : (i += 1) try pushConst(out, a, sh.ty, tag * 16 + 1 + 2 * @as(u32, i));
            if (end == .br_self) {
                try out.appendSlice(a, &.{ 0x0c, 0x00 }); // br 0
            } else {
                try pushConst(out, a, .i32, 0);
                try out.appendSlice(a, &.{ 0x0e, 0x01, 0x00, 0x00 }); // br_table [0] default 0
            }
        },
        .br_self_shift => {
            try pushConst(out, a, sh.ty, tag * 16 + 3);
            try out.appendSlice(a, &.{ 0x0c, 0x00 }); // br 0
        },
        .brif_dead, .brif_live => {
            try drops(out, a, sh.params);
            try pushResults(out, a, sh, sh.results, tag);
            try localGet(out, a, 1);
            try out.append(a, 0x0d); // br_if 0 (this frame)
            try uleb(out, a, 0);
            if (end == .brif_dead) {
                try drops(out, a, sh.results);
                try out.append(a, 0x00);
            }
        },
        .brif_replace => {
            try drops(out, a, sh.params);
            try pushResults(out, a, sh, sh.results, tag);
            try localGet(out, a, 1);
            try out.appendSlice(a, &.{ 0x0d, 0x00 }); // br_if 0
            try drops(out, a, sh.results);
            try pushResults(out, a, sh, sh.results, tag + 4);
        },
        .catch_self => {
            try out.appendSlice(a, &.{ 0x1f, 0x40, 0x01, 0x00, 0x00, 0x00 }); // try_table (catch tag 0 → label 0)
            try pushResults(out, a, sh, sh.results, tag + 4);
            try out.appendSlice(a, &.{ 0x08, 0x00, 0x0b, 0x00 }); // throw 0 ; end ; unreachable
        },
        .brif_param => {
            try localGet(out, a, 1);
            try out.appendSlice(a, &.{ 0x0d, 0x00 }); // br_if 0
            try drops(out, a, sh.params);
            try pushResults(out, a, sh, sh.results, tag);
        },
        .brif_twice => {
            try drops(out, a, sh.params);
            try pushResults(out, a, sh, sh.results, tag);
            try localGet(out, a, 1);
            try out.appendSlice(a, &.{ 0x0d, 0x00 }); // br_if 0
            try pushResults(out, a, sh, sh.results, tag + 4);
            try localGet(out, a, 1);
            try out.appendSlice(a, &.{ 0x0d, 0x00 }); // br_if 0
            try drops(out, a, sh.results);
        },
    }
}

// Pop `results` values of type `ty` off the top, converting each to i32 and
// adding it into local 2.
fn accumulate(out: *std.ArrayList(u8), a: std.mem.Allocator, results: u8, ty: Ty) !void {
    var r: u8 = 0;
    while (r < results) : (r += 1) {
        try toI32(out, a, ty);
        try localGet(out, a, 2);
        try out.append(a, 0x6a); // i32.add
        try out.append(a, 0x21); // local.set 2
        try uleb(out, a, 2);
    }
}

// Fold E enclosing i32s + R frame results (type ty) into one i32. Each result
// is converted to i32 and added into local 2 (an i32 accumulator) as it
// reaches the top, so a conversion never sees a value of the wrong type.
fn emitFold(out: *std.ArrayList(u8), a: std.mem.Allocator, enclosing: u8, results: u8, ty: Ty) !void {
    try accumulate(out, a, results, ty);
    try localGet(out, a, 2);
    var i: u8 = 0;
    while (i < enclosing) : (i += 1) try out.append(a, 0x6a);
}

fn carriesParam(sh: Shape) bool {
    return sh.params >= 1 and paramTy(sh) == .i32;
}

fn validArm(sh: Shape, end: End) bool {
    return switch (end) {
        .short1 => sh.results >= 1,
        .ret_param => carriesParam(sh),
        .drop0 => sh.params >= 1, // with no params it is `short0`
        .brif_param => sh.kind != .loop and sh.params >= 1 and sh.params == sh.results and sh.pty == .same,
        .br_out, .brt_out => sh.kind == .if_ and sh.outer_skip,
        .br_self_shift => sh.kind == .if_ and sh.pty == .same and sh.params >= 1 and sh.results >= 1 and sh.params + 1 >= sh.results,
        .br_self, .brt_self, .brif_dead, .brif_live, .brif_twice, .brif_replace => sh.kind != .loop, // a branch to a loop's label is a back edge
        .catch_self => sh.kind != .loop, // the catch would branch to the header
        .normal, .short0, .other1, .over, .ret, .br_fn, .brt_fn => true,
    };
}

fn build(a: std.mem.Allocator, sh: Shape) !?[]u8 {
    // Reject shapes we do not emit as valid wasm.
    if (sh.kind != .if_ and (sh.params != 0 or sh.else_ != null or sh.outer_skip or sh.pty != .same)) return null;
    if (sh.pty == .other and sh.params == 0) return null; // no params: `other` is `same`
    if (sh.kind == .if_ and sh.else_ == null and (sh.params != sh.results or sh.pty != .same)) return null;
    if (!validArm(sh, sh.body)) return null;
    if (sh.body == .br_self_shift and sh.else_ != null) return null;
    if (sh.else_) |e| if (!validArm(sh, e)) return null;
    // ref.func needs func 0 declared; keep the ref family small.
    if (sh.ty == .ref and (sh.results > 1 or sh.enclosing > 1)) return null;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);

    const use_ref = sh.ty == .ref or paramTy(sh) == .ref;

    var e: u8 = 0;
    while (e < sh.enclosing) : (e += 1) {
        try body.append(a, 0x41);
        try sleb(&body, a, @as(i64, e) + 100);
    }

    if (sh.outer_skip) {
        try body.appendSlice(a, &.{ 0x02, 0x40 }); // block (void)
        try localGet(&body, a, 1);
        try body.appendSlice(a, &.{ 0x0d, 0x00 }); // br_if 0
    }

    switch (sh.kind) {
        .if_ => {
            var p: u8 = 0;
            while (p < sh.params) : (p += 1) try pushConst(&body, a, paramTy(sh), 50 + p);
            try localGet(&body, a, 0); // condition
            try body.append(a, 0x04); // if
            try writeBlockType(&body, a, sh);
            try emitArm(&body, a, sh, sh.body, 1);
            if (sh.else_) |else_end| {
                try body.append(a, 0x05); // else
                try emitArm(&body, a, sh, else_end, 2);
            }
            try body.append(a, 0x0b);
        },
        .block, .loop => {
            try body.append(a, if (sh.kind == .block) @as(u8, 0x02) else 0x03);
            try writeBlockType(&body, a, sh);
            try emitArm(&body, a, sh, sh.body, 1);
            try body.append(a, 0x0b);
        },
    }

    if (sh.outer_skip) {
        // Fold the frame's results into local 2 inside the block, so a wrong
        // merge shows in the value even when an arm branches past the frame.
        try accumulate(&body, a, sh.results, sh.ty);
        try body.append(a, 0x0b); // end (outer block)
        // Tail witness: six distinct consts summed, so the regalloc keeps
        // several live temporaries a misnumbered vreg can collide with.
        const tail_consts = [_]i64{ 7, 11, 13, 17, 19, 23 };
        for (tail_consts) |c| {
            try body.append(a, 0x41);
            try sleb(&body, a, c);
        }
        var k: u32 = 1;
        while (k < tail_consts.len) : (k += 1) try body.append(a, 0x6a);
        try localGet(&body, a, 2);
        try body.append(a, 0x6a);
        var i: u32 = 0;
        while (i < sh.enclosing) : (i += 1) try body.append(a, 0x6a);
    } else {
        try emitFold(&body, a, sh.enclosing, sh.results, sh.ty);
    }

    // --- assemble module ---
    var mod: std.ArrayList(u8) = .empty;
    defer mod.deinit(a);
    try mod.appendSlice(a, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    // type 0 = (i32 i32) -> (i32); type 1 = the frame's type when it needs one
    var types: std.ArrayList(u8) = .empty;
    defer types.deinit(a);
    const emit_frame_type = needsTypeIndex(sh);
    try types.append(a, 0); // the type count, set below
    try types.appendSlice(a, &.{ 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f });
    if (emit_frame_type) {
        try types.append(a, 0x60);
        try uleb(&types, a, sh.params);
        var p: u8 = 0;
        while (p < sh.params) : (p += 1) try types.append(a, valByte(paramTy(sh)));
        try uleb(&types, a, sh.results);
        var r: u8 = 0;
        while (r < sh.results) : (r += 1) try types.append(a, valByte(sh.ty));
    }
    // The tag `catch_self` throws: its params are the frame's results, the
    // values its label takes.
    const use_tag = sh.body == .catch_self or sh.else_ == .catch_self;
    const tag_type: u8 = if (emit_frame_type) 2 else 1;
    if (use_tag) {
        try types.append(a, 0x60);
        try uleb(&types, a, sh.results);
        var r: u8 = 0;
        while (r < sh.results) : (r += 1) try types.append(a, valByte(sh.ty));
        try types.append(a, 0x00);
    }
    types.items[0] = tag_type + @intFromBool(use_tag); // type count
    try section(&mod, a, 1, types.items);
    try section(&mod, a, 3, &.{ 0x01, 0x00 }); // func 0 : type 0
    if (use_tag) try section(&mod, a, 13, &.{ 0x01, 0x00, tag_type }); // tag 0
    try section(&mod, a, 7, &.{ 0x01, 0x01, 'f', 0x00, 0x00 }); // export "f"
    if (use_ref) {
        // Declarative elem segment for func 0 so `ref.func 0` validates
        // (section 9 follows the export section, §5.5 order).
        try section(&mod, a, 9, &.{ 0x01, 0x03, 0x00, 0x01, 0x00 });
    }
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(a);
    try uleb(&code, a, 1);
    var func_body: std.ArrayList(u8) = .empty;
    defer func_body.deinit(a);
    try func_body.appendSlice(a, &.{ 0x01, 0x01, 0x7f }); // 1 × i32: the fold accumulator, local 2
    try func_body.appendSlice(a, body.items);
    try func_body.append(a, 0x0b);
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

const inputs = [_][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };

const RunResult = union(enum) {
    value: i32,
    trap: anyerror,
    decline, // compile / instantiate failed (invalid module, or JIT decline)
};

// One compile and instantiation per engine, then every input.
fn runAll(bytes: []const u8, use_jit: bool) [inputs.len]RunResult {
    var out: [inputs.len]RunResult = @splat(.decline);
    var eng = zwasm.Engine.init(testing.allocator, .{}) catch return out;
    defer eng.deinit();
    var mod = eng.compile(bytes) catch return out;
    defer mod.deinit();
    var inst = mod.instantiate(.{ .engine = if (use_jit) .jit else .interp }) catch return out;
    defer inst.deinit();
    for (inputs, &out) |in, *r| {
        var args = [_]zwasm.Value{ .{ .i32 = in[0] }, .{ .i32 = in[1] } };
        var res = [_]zwasm.Value{.{ .i32 = 0 }};
        r.* = blk: {
            inst.invoke("f", &args, &res) catch |e| break :blk .{ .trap = e };
            break :blk .{ .value = res[0].i32 };
        };
    }
    return out;
}

const Tally = struct {
    cur: Shape = undefined,
    shapes: u32 = 0, // shapes the generator emitted bytes for
    invalid: u32 = 0, // emitted modules the interpreter would not validate — a generator bug
    value_agree: u32 = 0, // both ran, same value
    trap_agree: u32 = 0, // both trapped the same way
    declined: u32 = 0, // the interpreter ran, the JIT declined the (valid) module
    mismatch: u32 = 0,
    // Real comparisons (value_agree + trap_agree) per axis value, so one that
    // never reached a running pair on both engines shows as 0.
    by_kind: [std.enums.values(Kind).len]u32 = @splat(0),
    by_ty: [std.enums.values(Ty).len]u32 = @splat(0),
    by_body: [std.enums.values(End).len]u32 = @splat(0),
    by_else: [std.enums.values(End).len]u32 = @splat(0),

    fn credit(t: *Tally) void {
        t.by_kind[@backingInt(t.cur.kind)] += 1;
        t.by_ty[@backingInt(t.cur.ty)] += 1;
        t.by_body[@backingInt(t.cur.body)] += 1;
        if (t.cur.else_) |e| t.by_else[@backingInt(e)] += 1;
    }
};

fn compareShape(t: *Tally, bytes: []const u8) void {
    const iv = runAll(bytes, false);
    if (iv[0] == .decline) {
        // The interpreter declines no valid module, so this is one the
        // generator emitted wrongly — the comparison never happened. Counted
        // and asserted to be zero, so a broken shape cannot hide as skipped.
        t.invalid += 1;
        return;
    }
    const jv = runAll(bytes, true);
    if (jv[0] == .decline) {
        t.declined += 1;
        return;
    }
    for (iv, jv, inputs) |i, j, in| {
        const agree = switch (i) {
            .value => |x| j == .value and j.value == x,
            .trap => |x| j == .trap and j.trap == x,
            .decline => false,
        };
        if (agree) {
            if (i == .value) t.value_agree += 1 else t.trap_agree += 1;
            t.credit();
        } else {
            t.mismatch += 1;
            printMismatch(t, in, i, j);
        }
    }
}

fn printMismatch(t: *Tally, in: [2]i32, i: RunResult, j: RunResult) void {
    if (t.mismatch > 30) return;
    const sh = t.cur;
    std.debug.print("  MISMATCH kind={s} ty={s} pty={s} P={d} R={d} E={d} body={s} else={s} skip={} in=({d},{d}) interp={f} jit={f}\n", .{
        @tagName(sh.kind), @tagName(sh.ty),                           @tagName(sh.pty),
        sh.params,         sh.results,                                sh.enclosing,
        @tagName(sh.body), if (sh.else_) |e| @tagName(e) else "none", sh.outer_skip,
        in[0],             in[1],                                     Fmt{ .r = i },
        Fmt{ .r = j },
    });
}

const Fmt = struct {
    r: RunResult,
    pub fn format(self: Fmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.r) {
            .value => |v| try w.print("{d}", .{v}),
            .trap => |e| try w.print("trap:{s}", .{@errorName(e)}),
            .decline => try w.writeAll("decline"),
        }
    }
};

const all_ends = std.enums.values(End);

// Builds every shape, runs it on both engines, and tallies the comparison.
fn sweep(report: *Tally) !void {
    const a = testing.allocator;
    for (std.enums.values(Kind)) |kind| {
        for (std.enums.values(Ty)) |ty| {
            for (std.enums.values(PTy)) |pty| {
                for ([_]u8{ 0, 1, 2 }) |params| {
                    for ([_]u8{ 0, 1, 2 }) |results| {
                        for ([_]u8{ 0, 1, 3 }) |enclosing| {
                            for (all_ends) |body| {
                                for (0..all_ends.len + 1) |ei| {
                                    const else_: ?End = if (ei == 0) null else all_ends[ei - 1];
                                    for ([_]bool{ false, true }) |outer_skip| {
                                        const sh = Shape{
                                            .kind = kind,
                                            .ty = ty,
                                            .pty = pty,
                                            .params = params,
                                            .results = results,
                                            .enclosing = enclosing,
                                            .body = body,
                                            .else_ = else_,
                                            .outer_skip = outer_skip,
                                        };
                                        const bytes = (try build(a, sh)) orelse continue;
                                        defer a.free(bytes);
                                        report.shapes += 1;
                                        report.cur = sh;
                                        compareShape(report, bytes);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

test "jit vs interp: control-frame shapes around an arm that ends early agree (#739 / #399)" {
    var report = Tally{};
    try sweep(&report);
    std.debug.print(
        "if-merge-enum: {d} shapes, {d} invalid, {d} value-agree, {d} trap-agree, {d} jit-declined, {d} mismatch\n" ++
            "  by kind {any}; by type {any}; by body end {any}; by else end {any}\n",
        .{
            report.shapes,   report.invalid,  report.value_agree, report.trap_agree,
            report.declined, report.mismatch, report.by_kind,     report.by_ty,
            report.by_body,  report.by_else,
        },
    );
    try testing.expectEqual(@as(u32, 0), report.mismatch);
    // Every shape the generator emits must validate and run on the interpreter;
    // a nonzero count means a module the comparison silently skipped.
    try testing.expectEqual(@as(u32, 0), report.invalid);
    // The JIT declines none of these shapes. One that moves from agreeing to
    // declining changes this count.
    try testing.expectEqual(@as(u32, 0), report.declined);
    try testing.expect(report.shapes > 1000);
    try testing.expect(report.value_agree > 1000);
    try testing.expect(report.trap_agree > 0);
    // Every axis value reached a real comparison on both engines.
    for (report.by_kind) |n| try testing.expect(n > 0);
    for (report.by_ty) |n| try testing.expect(n > 0);
    for (report.by_body) |n| try testing.expect(n > 0);
    for (report.by_else) |n| try testing.expect(n > 0);
}
