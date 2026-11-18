// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig).
//! A `try_table` catch clause and the label it targets, over every shape the
//! axes below span, run with `zwasm run --engine interp` and `--engine jit`
//! (#369). Each module is built here and written to the scratch directory.
//!
//! Axes: the label is a `block`, a `loop`, or the function itself, 0–2 blocks
//! sit between it and the `try_table`, the clause is each of the four kinds, the
//! tag carries nothing, an i32, an f64 or a funcref, a loop has no result, an
//! i32 or a `(ref $s)`, and the label's values come from constants, from a block
//! that ends in `unreachable`, or from such a block in a function that makes no
//! other value (the throw is in a callee); for the function label, also from a
//! body that does not throw. What a clause delivers is the label's
//! type: a loop's params, a block's results, the function's results.
//!
//! A loop runs three times, thrown out of and caught back into twice; a block
//! is left by its one catch. Each value the label receives is folded into an
//! accumulator, and `f` returns `acc * 1000 + iterations`. The runner computes
//! that value too, so a result is checked even where the interpreter traps on
//! a loop with params (#244). Each engine must print it, or trap `unreachable`
//! when the label's values come from `unreachable`; the JIT may instead decline
//! a loop whose params come from `unreachable` in a function with no other value.
//!
//! A catch to the function's own label is a `br` to it: the function returns the
//! delivered values. Those `func` shapes make `f` return the clause's type
//! directly (not the i32 fold), throw inline or in the callee, and check the
//! printed results on both engines. A third `func` variant does NOT throw: the
//! `try_table` body is empty and `f` returns its fall-through values (distinct
//! constants), the shape that runs past the clause's landing pad at the function
//! `end`. A result the CLI JIT entry cannot invoke
//! (a sole reference, or a reference mixed with a floating value —
//! `UnsupportedEntrySignature`) is skipped; the reify path is covered by the
//! kept multi-result `_ref` shapes.
//!
//! Usage: `zig build test-catch-label-matrix` /
//!        `zwasm-catch-label-matrix <zwasm-cli> <scratch-dir>`

const std = @import("std");
const spawned_cli = @import("spawned_cli");

const Kind = enum { block, loop, func };
const Clause = enum { catch_, catch_ref, catch_all, catch_all_ref };
const Payload = enum { none, i32, f64, funcref };
const LoopResult = enum { none, i32, ref_s };
const Pre = enum { values, unreachable_block, unreachable_alone, no_throw };

const Shape = struct {
    kind: Kind,
    depth: u8,
    clause: Clause,
    payload: Payload,
    result: LoopResult,
    pre: Pre,
};

const vt_i32: u8 = 0x7f;
const vt_i64: u8 = 0x7e;
const vt_f64: u8 = 0x7c;
const vt_funcref: u8 = 0x70;
const vt_exnref: u8 = 0x69;
const vt_ref: u8 = 0x64;

/// What the clause hands its label, deepest first.
fn delivered(s: Shape, out: *[2]u8) []const u8 {
    var n: usize = 0;
    if (s.clause == .catch_ or s.clause == .catch_ref) {
        if (payloadType(s.payload)) |t| {
            out[n] = t;
            n += 1;
        }
    }
    if (s.clause == .catch_ref or s.clause == .catch_all_ref) {
        out[n] = vt_exnref;
        n += 1;
    }
    return out[0..n];
}

/// Whether the CLI JIT entry can invoke a function with result types `d`: it
/// rejects (`UnsupportedEntrySignature`) a sole reference result and a reference
/// mixed with a floating value, while accepting i32/i64/f64 sole results and a
/// reference beside an integer.
fn funcResultInvocable(d: []const u8) bool {
    var has_ref = false;
    var has_fp = false;
    for (d) |t| {
        if (t == vt_funcref or t == vt_exnref) has_ref = true;
        if (t == vt_f64) has_fp = true; // the payload axis has no f32
    }
    if (d.len == 1 and has_ref) return false;
    if (has_ref and has_fp) return false;
    return true;
}

fn payloadType(p: Payload) ?u8 {
    return switch (p) {
        .none => null,
        .i32 => vt_i32,
        .f64 => vt_f64,
        .funcref => vt_funcref,
    };
}

const Buf = std.ArrayList(u8);

const Enc = struct {
    gpa: std.mem.Allocator,
    b: *Buf,

    fn byte(e: Enc, x: u8) !void {
        try e.b.append(e.gpa, x);
    }
    fn bytes(e: Enc, xs: []const u8) !void {
        try e.b.appendSlice(e.gpa, xs);
    }
    fn uleb(e: Enc, v: u32) !void {
        var x = v;
        while (true) {
            const lo: u8 = @intCast(x & 0x7f);
            x >>= 7;
            if (x == 0) return e.byte(lo);
            try e.byte(lo | 0x80);
        }
    }
    fn sleb(e: Enc, v: i64) !void {
        var x = v;
        while (true) {
            const lo: u8 = @intCast(x & 0x7f);
            x >>= 7;
            if ((x == 0 and lo & 0x40 == 0) or (x == -1 and lo & 0x40 != 0)) return e.byte(lo);
            try e.byte(lo | 0x80);
        }
    }
    fn i32Const(e: Enc, v: i32) !void {
        try e.byte(0x41);
        try e.sleb(v);
    }
    fn f64Const(e: Enc, v: f64) !void {
        try e.byte(0x44);
        try e.bytes(&std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(v))));
    }
    fn section(e: Enc, id: u8, body: []const u8) !void {
        try e.byte(id);
        try e.uleb(@intCast(body.len));
        try e.bytes(body);
    }
};

const local_i: u8 = 0;
const local_acc: u8 = 1;

/// Fold the value on top of the stack, of type `t`, into the accumulator.
fn fold(e: Enc, t: u8) !void {
    switch (t) {
        vt_i32 => {},
        vt_f64 => try e.byte(0xaa), // i32.trunc_f64_s
        vt_funcref, vt_exnref => try e.byte(0xd1), // ref.is_null
        else => unreachable,
    }
    try e.bytes(&.{ 0x20, local_acc });
    try e.i32Const(3);
    try e.bytes(&.{ 0x6c, 0x6a, 0x21, local_acc }); // i32.mul, i32.add, local.set
}

fn pushDefault(e: Enc, t: u8, iv: i32) !void {
    switch (t) {
        vt_i32 => try e.i32Const(iv),
        vt_f64 => try e.f64Const(@as(f64, @floatFromInt(iv)) + 0.5),
        vt_funcref => try e.bytes(&.{ 0xd0, 0x70 }),
        vt_exnref => try e.bytes(&.{ 0xd0, 0x69 }),
        else => unreachable,
    }
}

fn encodeModule(gpa: std.mem.Allocator, s: Shape, out: *Buf) !void {
    var dbuf: [2]u8 = undefined;
    const d = delivered(s, &dbuf);
    const e: Enc = .{ .gpa = gpa, .b = out };
    try e.bytes(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    var sec: Buf = .empty;
    defer sec.deinit(gpa);
    const se: Enc = .{ .gpa = gpa, .b = &sec };

    // Types: 0 struct $s (i64), 1 () -> i32, 2 the tag, 3 the label, 4 () -> label
    // values, 5 () -> () for the thrower.
    try se.uleb(6);
    try se.bytes(&.{ 0x5f, 0x01, vt_i64, 0x00 });
    try se.bytes(&.{ 0x60, 0x00, 0x01, vt_i32 });
    try se.bytes(&.{ 0x60, if (payloadType(s.payload) != null) 1 else 0 });
    if (payloadType(s.payload)) |t| try se.byte(t);
    try se.byte(0x00);
    try se.byte(0x60);
    switch (s.kind) {
        .loop => {
            try se.uleb(@intCast(d.len));
            try se.bytes(d);
            switch (s.result) {
                .none => try se.byte(0x00),
                .i32 => try se.bytes(&.{ 0x01, vt_i32 }),
                .ref_s => try se.bytes(&.{ 0x01, vt_ref, 0x00 }),
            }
        },
        // A block's label type is `() -> d`; `func` has no explicit label (the
        // clause targets the function), so type 3 is unused — build the same
        // valid shape.
        .block, .func => {
            try se.byte(0x00);
            try se.uleb(@intCast(d.len));
            try se.bytes(d);
        },
    }
    try se.bytes(&.{ 0x60, 0x00 });
    try se.uleb(@intCast(d.len));
    try se.bytes(d);
    try se.bytes(&.{ 0x60, 0x00, 0x00 });
    try e.section(1, sec.items);

    // `f` is type 1 (() -> i32) for block/loop, which fold their received
    // values into an i32; for `func` the clause returns the delivered values
    // straight out, so `f` is type 4 (() -> d).
    const f_type: u8 = if (s.kind == .func) 0x04 else 0x01;
    try e.section(3, &.{ 0x02, f_type, 0x05 });
    try e.section(13, &.{ 0x01, 0x00, 0x02 });
    try e.section(7, &.{ 0x01, 0x01, 'f', 0x00, 0x00 });

    var body: Buf = .empty;
    defer body.deinit(gpa);
    const be: Enc = .{ .gpa = gpa, .b = &body };
    if (s.kind == .func)
        try encodeFunc(be, s)
    else if (s.pre == .unreachable_alone)
        try encodeAlone(be, s, d)
    else
        try encodeCounted(be, s, d);

    var thrower: Buf = .empty;
    defer thrower.deinit(gpa);
    const te: Enc = .{ .gpa = gpa, .b = &thrower };
    try te.byte(0x00);
    switch (s.payload) {
        .none => {},
        .i32 => try te.i32Const(11),
        .f64 => try te.f64Const(11.5),
        .funcref => try te.bytes(&.{ 0xd0, 0x70 }),
    }
    try te.bytes(&.{ 0x08, 0x00, 0x0b });

    sec.clearRetainingCapacity();
    try se.uleb(2);
    for ([_][]const u8{ body.items, thrower.items }) |code| {
        try se.uleb(@intCast(code.len));
        try se.bytes(code);
    }
    try e.section(10, sec.items);
}

/// The label's values come from `unreachable` and `f` makes no value of its
/// own: the clause sits right in the label's inner blocks and the throw is in
/// the callee.
fn encodeAlone(be: Enc, s: Shape, d: []const u8) !void {
    try be.byte(0x00); // no locals
    try be.bytes(if (s.kind == .loop) &.{ 0x02, 0x04, 0x00, 0x0b } else &.{ 0x02, 0x40, 0x00, 0x0b });
    try be.bytes(&.{ if (s.kind == .loop) 0x03 else 0x02, 0x03 });
    if (s.kind == .loop) for (d) |_| try be.byte(0x1a); // drop
    for (0..s.depth) |_| try be.bytes(&.{ 0x02, 0x40 });
    try be.bytes(&.{ 0x1f, 0x40, 0x01 });
    try encodeClause(be, s, s.depth);
    try be.bytes(&.{ 0x10, 0x01, 0x0b }); // call $thrower, end try_table
    for (0..s.depth) |_| try be.byte(0x0b);
    try be.bytes(&.{ 0x00, 0x0b, 0x00, 0x0b });
}

fn encodeClause(be: Enc, s: Shape, label: u8) !void {
    switch (s.clause) {
        .catch_ => try be.bytes(&.{ 0x00, 0x00, label }),
        .catch_ref => try be.bytes(&.{ 0x01, 0x00, label }),
        .catch_all => try be.bytes(&.{ 0x02, label }),
        .catch_all_ref => try be.bytes(&.{ 0x03, label }),
    }
}

/// `f`'s label is its own: the clause targets the function (index `depth`, past
/// the blocks between it and the `try_table`), so the catch returns the
/// delivered values. `f` has type `() -> d`. The `try_table` body throws the
/// tag — inline (`.values`) or in the callee `$thrower` (`.unreachable_alone`) —
/// and the function returns what the clause delivers. The fall-through past the
/// `try_table` is dead but must still type-check, so an `unreachable` closes it.
fn encodeFunc(be: Enc, s: Shape) !void {
    try be.byte(0x00); // no locals
    for (0..s.depth) |_| try be.bytes(&.{ 0x02, 0x40 }); // block () -> ()
    try be.bytes(&.{ 0x1f, 0x40, 0x01 }); // try_table () -> (), one clause
    try encodeClause(be, s, s.depth); // the function label sits at depth
    switch (s.pre) {
        .values => {
            switch (s.payload) {
                .none => {},
                .i32 => try be.i32Const(11),
                .f64 => try be.f64Const(11.5),
                .funcref => try be.bytes(&.{ 0xd0, 0x70 }),
            }
            try be.bytes(&.{ 0x08, 0x00 }); // throw $e
        },
        .unreachable_alone => try be.bytes(&.{ 0x10, 0x01 }), // call $thrower
        .no_throw => {}, // empty try_table body: the fall-through runs, no throw
        .unreachable_block => unreachable, // not generated for func
    }
    try be.byte(0x0b); // end try_table
    for (0..s.depth) |_| try be.byte(0x0b); // end blocks
    if (s.pre == .no_throw) {
        // No throw: the function returns its fall-through values of type d
        // (distinct constants from the thrown payload, so a value delivered by
        // the pad would not pass). They sit AFTER the clause's landing pad,
        // which the JIT appends at the function `end`.
        var dbuf: [2]u8 = undefined;
        for (delivered(s, &dbuf)) |t| try pushDefault(be, t, 5);
        try be.byte(0x0b); // end function
    } else {
        // The fall-through past the `try_table` is dead but must type-check.
        try be.bytes(&.{ 0x00, 0x0b }); // unreachable, end function
    }
}

/// The stdout `f` prints for a `func` shape: the delivered values, deepest
/// first, one per line (`invoke_args.formatScalar`). A caught live exception's
/// exnref is non-null (`ref`); the thrown tag params are the fixed values the
/// body throws (11 / 11.5 / a null funcref).
fn funcWant(s: Shape, buf: []u8) ![]const u8 {
    var w: usize = 0;
    if (s.pre == .no_throw) {
        // No throw: f returns the fall-through values `encodeFunc` pushed
        // (`pushDefault(t, 5)`), of type d — i32 as 5, f64 as 5.5. d has no
        // exnref (no_throw is generated only for catch_ / catch_all).
        var dbuf: [2]u8 = undefined;
        for (delivered(s, &dbuf)) |t| {
            const part: []const u8 = switch (t) {
                vt_i32 => "5\n",
                vt_f64 => "5.5\n",
                else => unreachable,
            };
            @memcpy(buf[w .. w + part.len], part);
            w += part.len;
        }
        return buf[0..w];
    }
    if (s.clause == .catch_ or s.clause == .catch_ref) {
        const part: []const u8 = switch (s.payload) {
            .none => "",
            .i32 => "11\n",
            .f64 => "11.5\n",
            .funcref => "null\n",
        };
        @memcpy(buf[w .. w + part.len], part);
        w += part.len;
    }
    if (s.clause == .catch_ref or s.clause == .catch_all_ref) {
        @memcpy(buf[w .. w + 4], "ref\n");
        w += 4;
    }
    return buf[0..w];
}

fn encodeCounted(be: Enc, s: Shape, d: []const u8) !void {
    try be.bytes(&.{ 0x01, 0x02, vt_i32 }); // locals: $i, $acc

    switch (s.pre) {
        .values => if (s.kind == .loop) for (d) |t| try pushDefault(be, t, 7),
        .unreachable_block => switch (s.kind) {
            .loop => try be.bytes(&.{ 0x02, 0x04, 0x00, 0x0b }),
            .block => try be.bytes(&.{ 0x02, 0x40, 0x00, 0x0b }),
            .func => unreachable, // func routes to encodeFunc, never here
        },
        .unreachable_alone => unreachable,
        .no_throw => unreachable, // func-only axis; func routes to encodeFunc
    }
    try be.bytes(&.{ if (s.kind == .loop) 0x03 else 0x02, 0x03 });
    if (s.kind == .loop) {
        var k = d.len;
        while (k > 0) : (k -= 1) try fold(be, d[k - 1]);
    }
    try be.bytes(&.{ 0x20, local_i });
    try be.i32Const(1);
    try be.bytes(&.{ 0x6a, 0x21, local_i });
    for (0..s.depth) |_| try be.bytes(&.{ 0x02, 0x40 });
    try be.bytes(&.{ 0x20, local_i });
    try be.i32Const(3);
    try be.bytes(&.{ 0x48, 0x04, 0x40 }); // i32.lt_s, if
    try be.bytes(&.{ 0x1f, 0x40, 0x01 }); // try_table, one clause
    try encodeClause(be, s, s.depth + 1);
    switch (s.payload) {
        .none => {},
        .i32 => {
            try be.bytes(&.{ 0x20, local_i });
            try be.i32Const(10);
            try be.byte(0x6a);
        },
        .f64 => {
            try be.bytes(&.{ 0x20, local_i, 0xb7 });
            try be.f64Const(10.5);
            try be.byte(0xa0);
        },
        .funcref => try be.bytes(&.{ 0xd0, 0x70 }),
    }
    try be.bytes(&.{ 0x08, 0x00, 0x0b, 0x0b }); // throw, end try_table, end if
    for (0..s.depth) |_| try be.byte(0x0b);
    switch (s.kind) {
        .loop => switch (s.result) {
            .none => {},
            .i32 => try be.i32Const(100),
            .ref_s => try be.bytes(&.{ 0x42, 0x2a, 0xfb, 0x00, 0x00 }), // i64.const 42, struct.new $s
        },
        .block => for (d) |t| try pushDefault(be, t, 1),
        .func => unreachable,
    }
    try be.byte(0x0b);
    switch (s.kind) {
        .loop => switch (s.result) {
            .none => {},
            .i32 => try fold(be, vt_i32),
            .ref_s => {
                try be.bytes(&.{ 0xfb, 0x02, 0x00, 0x00, 0xa7 }); // struct.get $s 0, i32.wrap_i64
                try fold(be, vt_i32);
            },
        },
        .block => {
            var k = d.len;
            while (k > 0) : (k -= 1) try fold(be, d[k - 1]);
        },
        .func => unreachable,
    }
    try be.bytes(&.{ 0x20, local_acc });
    try be.i32Const(1000);
    try be.bytes(&.{ 0x6c, 0x20, local_i, 0x6a, 0x0b });
}

fn foldValue(acc: i32, v: i32) i32 {
    return v +% acc *% 3;
}

/// The value one received value folds as.
fn asI32(t: u8, iv: i32, from_throw: bool) i32 {
    return switch (t) {
        vt_i32 => iv,
        vt_f64 => iv, // iv + 0.5 truncated
        vt_funcref => 1, // always null
        vt_exnref => if (from_throw) 0 else 1,
        else => unreachable,
    };
}

/// What `f` returns, or null when it traps `unreachable`.
fn expected(s: Shape) ?i32 {
    if (s.pre != .values) return null;
    var dbuf: [2]u8 = undefined;
    const d = delivered(s, &dbuf);
    var acc: i32 = 0;
    switch (s.kind) {
        .loop => {
            var i: i32 = 0;
            var from_throw = false;
            while (true) {
                // The label's values: the constants before the loop, then what
                // the throw at the previous iteration carried.
                const iv: i32 = if (from_throw) i + 10 else 7;
                var k = d.len;
                while (k > 0) : (k -= 1) acc = foldValue(acc, asI32(d[k - 1], iv, from_throw));
                i += 1;
                if (i >= 3) break;
                from_throw = true;
            }
            switch (s.result) {
                .none => {},
                .i32 => acc = foldValue(acc, 100),
                .ref_s => acc = foldValue(acc, 42),
            }
            return acc *% 1000 +% i;
        },
        .block => {
            var k = d.len;
            while (k > 0) : (k -= 1) acc = foldValue(acc, asI32(d[k - 1], 11, true));
            return acc *% 1000 +% 1;
        },
        .func => unreachable, // func shapes check stdout directly, not this model
    }
}

const Outcome = union(enum) {
    value: i32,
    trap: []const u8,
    declined,
    other: u8,
};

fn outcomeOf(term: std.process.Child.Term, stdout: []const u8, stderr: []const u8) Outcome {
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => return .{ .other = 255 },
    };
    if (code == 0) {
        const t = std.mem.trim(u8, stdout, " \r\n");
        return if (std.fmt.parseInt(i32, t, 10)) |v| .{ .value = v } else |_| .{ .other = 0 };
    }
    if (code != 1) return .{ .other = code };
    const needle = "trap kind=";
    if (std.mem.find(u8, stderr, needle)) |at| {
        const rest = stderr[at + needle.len ..];
        const end = std.mem.findAny(u8, rest, " \r\n") orelse rest.len;
        return .{ .trap = rest[0..end] };
    }
    return .declined;
}

fn eqlOutcome(a: Outcome, b: Outcome) bool {
    return switch (a) {
        .value => |v| b == .value and b.value == v,
        .trap => |k| b == .trap and std.mem.eql(u8, b.trap, k),
        .declined => b == .declined,
        .other => |c| b == .other and b.other == c,
    };
}

fn fits(o: Outcome, want: ?i32) bool {
    return if (want) |v| o == .value and o.value == v else o == .trap and std.mem.eql(u8, o.trap, "unreachable_");
}

fn shapeName(buf: []u8, s: Shape) ![]const u8 {
    return std.mem.print(buf, "{t}-d{d}-{t}-{t}-{t}-{t}", .{ s.kind, s.depth, s.clause, s.payload, s.result, s.pre });
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const cli = arg_it.next() orelse return error.MissingCliPath;
    const scratch = arg_it.next() orelse return error.MissingScratchDir;
    try spawned_cli.assertRunnerBuildMode(gpa, io, cli);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, scratch);

    var shapes: std.ArrayList(Shape) = .empty;
    defer shapes.deinit(gpa);
    for (std.enums.values(Kind)) |kind| for (0..3) |depth| for (std.enums.values(Clause)) |clause|
        for (std.enums.values(Payload)) |payload| for (std.enums.values(LoopResult)) |result| for (std.enums.values(Pre)) |pre| {
            // A block's results are what the clause delivers; only a loop has its own.
            if (kind == .block and result != .none) continue;
            // `no_throw` is a function-only axis: the `try_table` body does not
            // throw, so `f` returns its fall-through values. It is the shape that
            // runs past the clause's landing pad, which the JIT appends at the
            // function `end` — the others all throw and never reach it.
            if (kind != .func and pre == .no_throw) continue;
            const s: Shape = .{ .kind = kind, .depth = @intCast(depth), .clause = clause, .payload = payload, .result = result, .pre = pre };
            if (kind == .func) {
                if (result != .none) continue; // a function label carries no loop result
                if (pre == .unreachable_block) continue; // func delivers via the throw: inline (.values) or in the callee (.unreachable_alone)
                // A no-throw fall-through returns values of type d; keep it to the
                // clauses whose d has no exnref (catch_ / catch_all), so the
                // fall-through needs no reified exnref. The pad-placement this
                // covers is clause-independent.
                if (pre == .no_throw and (clause == .catch_ref or clause == .catch_all_ref)) continue;
                // Skip a result the CLI JIT entry cannot invoke
                // (UnsupportedEntrySignature): a sole reference, or a reference
                // mixed with a floating value. The reify / register-move path is
                // still covered by the kept `_ref` shapes (a ref beside an i32, a
                // ref beside a funcref) and the fp return by the kept `catch_` f64
                // shape.
                var sb: [2]u8 = undefined;
                if (!funcResultInvocable(delivered(s, &sb))) continue;
            }
            try shapes.append(gpa, s);
        };

    var agree: u32 = 0;
    var declined: u32 = 0;
    var interp_244: u32 = 0;
    var differ: u32 = 0;
    var module: Buf = .empty;
    defer module.deinit(gpa);
    for (shapes.items) |s| {
        var name_buf: [96]u8 = undefined;
        const name = try shapeName(&name_buf, s);
        var path_buf: [512]u8 = undefined;
        const path = try std.mem.print(&path_buf, "{s}/{s}.wasm", .{ scratch, name });
        module.clearRetainingCapacity();
        try encodeModule(gpa, s, &module);
        try cwd.writeFile(io, .{ .sub_path = path, .data = module.items });

        var got: [2]Outcome = undefined;
        var held: [2][2][]u8 = undefined;
        var codes: [2]u8 = undefined;
        for ([_][]const u8{ "interp", "jit" }, 0..) |engine, k| {
            const r = try std.process.run(gpa, io, .{ .argv = &.{ cli, "run", "--timeout", "10000", "--engine", engine, "--invoke", "f", path } });
            held[k] = .{ r.stdout, r.stderr };
            got[k] = outcomeOf(r.term, r.stdout, r.stderr);
            codes[k] = switch (r.term) {
                .exited => |c| c,
                else => 255,
            };
        }
        defer for (held) |h| {
            gpa.free(h[0]);
            gpa.free(h[1]);
        };
        // A `func` clause returns its delivered values straight out, so check
        // the printed results against the spec value on BOTH engines instead of
        // the fold model.
        if (s.kind == .func) {
            var wbuf: [16]u8 = undefined;
            const want_s = try funcWant(s, &wbuf);
            const i_ok = codes[0] == 0 and std.mem.eql(u8, held[0][0], want_s);
            const j_ok = codes[1] == 0 and std.mem.eql(u8, held[1][0], want_s);
            if (i_ok and j_ok) {
                agree += 1;
            } else {
                differ += 1;
                std.debug.print("catch-label-matrix DIFFER {s}: want \"{f}\", interp({d}) \"{f}\", jit({d}) \"{f}\"\n", .{
                    name,
                    std.zig.fmtString(want_s),
                    codes[0],
                    std.zig.fmtString(std.mem.trimEnd(u8, held[0][0], "\n")),
                    codes[1],
                    std.zig.fmtString(std.mem.trimEnd(u8, held[1][0], "\n")),
                });
            }
            continue;
        }
        const want = expected(s);
        const interp, const jit = got;
        var dbuf: [2]u8 = undefined;
        const has_params = s.kind == .loop and delivered(s, &dbuf).len > 0;
        // The interpreter traps `unreachable` on a loop with params (#244).
        const is_244 = has_params and want != null and interp == .trap and std.mem.eql(u8, interp.trap, "unreachable_");
        // The JIT may decline only a loop param that no value was made for.
        const jit_ok = fits(jit, want) or (jit == .declined and has_params and s.pre == .unreachable_alone);
        const kind: enum { agree, declined, interp_244, differ } =
            if (!jit_ok) .differ else if (is_244) .interp_244 else if (!fits(interp, want)) .differ else if (jit == .declined) .declined else if (eqlOutcome(interp, jit)) .agree else .differ;
        switch (kind) {
            .agree => agree += 1,
            .declined => declined += 1,
            .interp_244 => interp_244 += 1,
            .differ => {
                differ += 1;
                std.debug.print("catch-label-matrix DIFFER {s}: want {?d}, interp {any} \"{f}\", jit {any} \"{f}\"\n", .{
                    name,   want,
                    interp, std.zig.fmtString(std.mem.trimEnd(u8, held[0][1], "\n")),
                    jit,    std.zig.fmtString(std.mem.trimEnd(u8, held[1][1], "\n")),
                });
            },
        }
    }
    std.debug.print("catch-label-matrix: {d} shapes, {d} agree, {d} declined by the JIT, {d} interp traps on a loop with params (#244), {d} differ\n", .{
        shapes.items.len, agree, declined, interp_244, differ,
    });
    return if (differ != 0) 1 else 0;
}
