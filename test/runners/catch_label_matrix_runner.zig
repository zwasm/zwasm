// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig).
//! A `try_table` catch clause and the label it targets, over every shape the
//! axes below span, run with `zwasm run --engine interp` and `--engine jit`
//! (#369). Each module is built here and written to the scratch directory.
//!
//! Axes: the label is a `block` or a `loop`, 0–2 blocks sit between it and the
//! `if` holding the `try_table`, the clause is each of the four kinds, the tag
//! carries nothing, an i32, an f64 or a funcref, a loop has no result, an i32
//! or a `(ref $s)`, and the label's values come from constants, from a block
//! that ends in `unreachable`, or from such a block in a function that makes no
//! other value (the throw is in a callee). What a clause delivers is the label's
//! type: a loop's params, a block's results.
//!
//! A loop runs three times, thrown out of and caught back into twice; a block
//! is left by its one catch. Each value the label receives is folded into an
//! accumulator, and `f` returns `acc * 1000 + iterations`. The runner computes
//! that value too, so a result is checked even where the interpreter traps on
//! a loop with params (#244). Each engine must print it, or trap `unreachable`
//! when the label's values come from `unreachable`; the JIT may instead decline
//! a loop whose params come from `unreachable` in a function with no other value.
//!
//! Usage: `zig build test-catch-label-matrix` /
//!        `zwasm-catch-label-matrix <zwasm-cli> <scratch-dir>`

const std = @import("std");
const spawned_cli = @import("spawned_cli");

const Kind = enum { block, loop };
const Clause = enum { catch_, catch_ref, catch_all, catch_all_ref };
const Payload = enum { none, i32, f64, funcref };
const LoopResult = enum { none, i32, ref_s };
const Pre = enum { values, unreachable_block, unreachable_alone };

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
        .block => {
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

    try e.section(3, &.{ 0x02, 0x01, 0x05 });
    try e.section(13, &.{ 0x01, 0x00, 0x02 });
    try e.section(7, &.{ 0x01, 0x01, 'f', 0x00, 0x00 });

    var body: Buf = .empty;
    defer body.deinit(gpa);
    const be: Enc = .{ .gpa = gpa, .b = &body };
    if (s.pre == .unreachable_alone) try encodeAlone(be, s, d) else try encodeCounted(be, s, d);

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

fn encodeCounted(be: Enc, s: Shape, d: []const u8) !void {
    try be.bytes(&.{ 0x01, 0x02, vt_i32 }); // locals: $i, $acc

    switch (s.pre) {
        .values => if (s.kind == .loop) for (d) |t| try pushDefault(be, t, 7),
        .unreachable_block => switch (s.kind) {
            .loop => try be.bytes(&.{ 0x02, 0x04, 0x00, 0x0b }),
            .block => try be.bytes(&.{ 0x02, 0x40, 0x00, 0x0b }),
        },
        .unreachable_alone => unreachable,
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
            try shapes.append(gpa, .{ .kind = kind, .depth = @intCast(depth), .clause = clause, .payload = payload, .result = result, .pre = pre });
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
        for ([_][]const u8{ "interp", "jit" }, 0..) |engine, k| {
            const r = try std.process.run(gpa, io, .{ .argv = &.{ cli, "run", "--timeout", "10000", "--engine", engine, "--invoke", "f", path } });
            held[k] = .{ r.stdout, r.stderr };
            got[k] = outcomeOf(r.term, r.stdout, r.stderr);
        }
        defer for (held) |h| {
            gpa.free(h[0]);
            gpa.free(h[1]);
        };
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
