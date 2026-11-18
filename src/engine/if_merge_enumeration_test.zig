//! Enumerates control-frame shapes around an arm that ends early, or whose
//! edges deliver values that sit where another edge's values go, and checks
//! the JIT against the interpreter for each: same value, same trap, or a JIT
//! decline counted as such. The axes are the frame kind, its params and
//! results and their types, how each arm ends (`End`), and the values below
//! the frame.
//!
//! The modules are assembled in-test (no committed binary). `f` always has
//! type `(i32, i32) -> (i32)`: local 0 is the `if` condition, local 1 the
//! `br_if` / `br_table` / outer-skip condition, and the body folds every
//! value the frame leaves (weighted by position), plus the values below it,
//! into one i32, so a vreg the JIT reads from the wrong place changes the
//! result.
//!
//! A loop with params is checked against the value the generator computes
//! (`loopValue`), since the interpreter traps on one (#244); it takes only
//! the arms that function knows. Every loop also runs on the JIT a second
//! time without fuel metering, which a back edge polls, and must give what
//! the metered run gave.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const zwasm = @import("../zwasm.zig");
const parallel_move = @import("codegen/shared/parallel_move.zig");

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
    /// params and that value, each one slot below where it sat.
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
    /// One more value above the params, `br_if 0` on local 1 (it carries the
    /// top params and that value, each one slot below where it sat), drop
    /// that value, fall through with the params. On a loop the branch is a
    /// back edge, taken at most once.
    brif_shift,
    /// The same, then `br_if 0` on local 0 with the params.
    brif_shift_again,
    /// A nested block that takes the params, pushes one more value and
    /// branches to its own end: the arm leaves the top params and that
    /// value, each one slot below where it sat.
    nest_shift,
    /// One more value above the params, then an `if` that takes the top
    /// params and that value and `br`s to the loop with them, at most once;
    /// drop that value (loop only).
    loop_br_shift,
    /// The same with `br_table`, its index a constant.
    loop_brt_shift,
    /// Drop the params; inside a nested block the results and `br_if 1` on
    /// local 1, to this frame; drop them; after the block, other results.
    nest_brif,
    /// The params go into locals and come back rotated by one, above one
    /// more value; a back edge on local 1 carries them, at most once; then
    /// they go through the locals again to drop that value (loop only).
    loop_rot,
    /// The same, the back edge a `br` inside an `if` that takes them.
    loop_br_rot,
    /// The same with `br_table`, its index a constant.
    loop_brt_rot,
    /// The params go into locals and come back rotated by one, above one
    /// more value; `br_if 0` on local 1 carries them; then they go through
    /// the locals once more, rotated again, and that value is dropped.
    rot_brif,
    /// The same, then `br_if 0` on local 0 with the twice-rotated values.
    rot_brif_again,
    /// `loop_rot` with `br_on_null` as the back edge, on a reference that is
    /// null when local 1 is set. A call at the loop's head and one before
    /// the branch put the params and the carried values in spill slots, and
    /// two values pushed and dropped reorder the slots the carried ones
    /// take, so the edge's moves form a cycle (loop only).
    loop_null_rot,
    /// The same with `br_on_cast` (which calls) on a reference that is an
    /// i31 when local 1 is set; the loop carries that reference as one more
    /// param and result, above the others.
    loop_cast_rot,
    /// The same with `br_on_cast_fail`, on a reference that is null when
    /// local 1 is set.
    loop_cast_fail_rot,
    /// The same with `br_on_non_null`, on a reference that is an i31 when
    /// local 1 is set. With no params the loop carries the reference alone.
    loop_non_null_rot,
    /// `br_on_null` as the back edge of a loop that has no params, on a
    /// reference that is null when local 1 is set, taken at most once. Each
    /// pass adds 7 to local 2 first, so the number of passes is in the fold.
    loop_null,
};

/// An arm whose edge delivers values to places other than where they sat.
fn shifts(e: End) bool {
    return e == .br_self_shift or e == .brif_shift or e == .brif_shift_again or
        e == .nest_shift or e == .loop_br_shift or e == .loop_brt_shift or rotates(e);
}

/// An arm that passes the params through locals 3.. (of the frame's type).
fn rotates(e: End) bool {
    return loopRotates(e) or e == .rot_brif or e == .rot_brif_again;
}

fn loopRotates(e: End) bool {
    return e == .loop_rot or e == .loop_br_rot or e == .loop_brt_rot or brOnLoop(e);
}

/// A loop arm whose back edge is a `br_on_*` and carries values.
fn brOnLoop(e: End) bool {
    return e == .loop_null_rot or refTail(e);
}

/// One whose loop carries an i31ref above its other params and results.
fn refTail(e: End) bool {
    return castLoop(e) or e == .loop_non_null_rot;
}

/// One whose back edge is `br_on_cast` or `br_on_cast_fail`.
fn castLoop(e: End) bool {
    return e == .loop_cast_rot or e == .loop_cast_fail_rot;
}

fn loopOnly(e: End) bool {
    return e == .loop_br_shift or e == .loop_brt_shift or e == .loop_null or loopRotates(e);
}

/// The arms paired with only `partners` and each other, to bound the sweep.
fn paired(e: End) bool {
    return (shifts(e) and e != .br_self_shift) or e == .nest_brif;
}

fn partner(e: End) bool {
    return paired(e) or e == .normal or e == .short0 or e == .ret or e == .br_self or
        e == .brif_param or e == .brif_live or e == .br_self_shift;
}

/// The arms `loopValue` computes: the ones a loop with params takes.
fn loopArm(e: End) bool {
    return e == .normal or e == .brif_shift or e == .loop_br_shift or e == .loop_brt_shift or e == .nest_shift or loopRotates(e);
}

/// The sweep's extent. Three params or results, and every count of values
/// below the frame up to 14 (so the frame's values sit in registers, in
/// spill slots, or across both, on either arch), are swept only for an arm
/// that shifts two or more values, beside `normal`, `brif_param` or another
/// such arm.
fn inSweep(sh: Shape) bool {
    const wide = sh.params == 3 or sh.results == 3 or !(sh.enclosing == 0 or sh.enclosing == 1 or sh.enclosing == 3);
    const any_paired = paired(sh.body) or (sh.else_ != null and paired(sh.else_.?));
    if (!any_paired and !wide) return true;
    if (!wide) return partner(sh.body) and (sh.else_ == null or partner(sh.else_.?));
    if (sh.outer_skip or sh.params != sh.results or sh.params < 2) return false;
    if (!shifts(sh.body) and !(sh.else_ != null and shifts(sh.else_.?))) return false;
    return besideWide(sh.body) and (sh.else_ == null or besideWide(sh.else_.?));
}

fn besideWide(e: End) bool {
    return shifts(e) or e == .normal or e == .brif_param;
}

const Shape = struct {
    kind: Kind,
    ty: Ty,
    pty: PTy,
    params: u8,
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
    if (needsTypeIndex(sh)) {
        try sleb(out, a, 1);
    } else if (sh.results == 0) {
        try out.append(a, 0x40);
    } else {
        try out.append(a, valByte(sh.ty));
    }
}

fn needsTypeIndex(sh: Shape) bool {
    return refTail(sh.body) or !(sh.params == 0 and (sh.results == 0 or sh.results == 1));
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
        .brif_shift, .brif_shift_again => {
            try pushConst(out, a, sh.ty, tag * 16 + 3);
            try localGet(out, a, 1);
            if (sh.kind == .loop) try out.appendSlice(a, &take_once);
            try out.appendSlice(a, &.{ 0x0d, 0x00, 0x1a }); // br_if 0 ; drop
            if (end == .brif_shift_again) {
                try localGet(out, a, 0);
                try out.appendSlice(a, &.{ 0x0d, 0x00 }); // br_if 0
            }
        },
        .nest_shift => {
            try out.append(a, 0x02); // block (type 1)
            try sleb(out, a, 1);
            try pushConst(out, a, sh.ty, tag * 16 + 3);
            try out.appendSlice(a, &.{ 0x0c, 0x00, 0x0b }); // br 0 ; end
        },
        .loop_br_shift, .loop_brt_shift => {
            try pushConst(out, a, sh.ty, tag * 16 + 3);
            try localGet(out, a, 1);
            try out.appendSlice(a, &take_once);
            try out.append(a, 0x04); // if (type 1)
            try sleb(out, a, 1);
            if (end == .loop_br_shift) {
                try out.appendSlice(a, &.{ 0x0c, 0x01 }); // br 1 (the loop)
            } else {
                try out.appendSlice(a, &.{ 0x41, 0x00, 0x0e, 0x01, 0x01, 0x01 }); // i32.const 0 ; br_table [1] default 1
            }
            try out.appendSlice(a, &.{ 0x0b, 0x1a }); // end ; drop
        },
        .loop_rot, .loop_br_rot, .loop_brt_rot => {
            try setLocals(out, a, sh.params);
            try pushConst(out, a, sh.ty, tag * 16 + 3);
            var i: u8 = 0;
            while (i < sh.params) : (i += 1) try localGet(out, a, 3 + (i + 1) % sh.params);
            try localGet(out, a, 1);
            try out.appendSlice(a, &take_once);
            if (end == .loop_rot) {
                try out.appendSlice(a, &.{ 0x0d, 0x00 }); // br_if 0
            } else {
                try out.append(a, 0x04); // if (type 1)
                try sleb(out, a, 1);
                if (end == .loop_br_rot) {
                    try out.appendSlice(a, &.{ 0x0c, 0x01 }); // br 1 (the loop)
                } else {
                    try out.appendSlice(a, &.{ 0x41, 0x00, 0x0e, 0x01, 0x01, 0x01 }); // i32.const 0 ; br_table [1] default 1
                }
                try out.append(a, 0x0b);
            }
            try setLocals(out, a, sh.params);
            try out.append(a, 0x1a); // drop
            i = 0;
            while (i < sh.params) : (i += 1) try localGet(out, a, 3 + i);
        },
        .rot_brif, .rot_brif_again => {
            try setLocals(out, a, sh.params);
            try pushConst(out, a, sh.ty, tag * 16 + 3);
            var i: u8 = 0;
            while (i < sh.params) : (i += 1) try localGet(out, a, 3 + (i + 1) % sh.params);
            try localGet(out, a, 1);
            try out.appendSlice(a, &.{ 0x0d, 0x00 }); // br_if 0
            try setLocals(out, a, sh.params);
            try out.append(a, 0x1a); // drop
            i = 0;
            while (i < sh.params) : (i += 1) try localGet(out, a, 3 + (i + 1) % sh.params);
            if (end == .rot_brif_again) {
                try localGet(out, a, 0);
                try out.appendSlice(a, &.{ 0x0d, 0x00 }); // br_if 0
            }
        },
        .loop_null => {
            try out.appendSlice(a, &.{ 0x20, 0x02, 0x41, 0x07, 0x6a, 0x21, 0x02 }); // local 2 += 7
            try out.appendSlice(a, &.{ 0xd0, 0x6c, 0x41, 0x05, 0xfb, 0x1c }); // ref.null i31 ; i32.const 5 ; ref.i31
            try localGet(out, a, 1);
            try out.appendSlice(a, &.{ 0x1c, 0x01, 0x6c }); // select (result i31ref): null when local 1 is set
            try out.appendSlice(a, &take_once);
            try out.appendSlice(a, &.{ 0xd5, 0x00, 0x1a }); // br_on_null 0 ; drop
            try pushResults(out, a, sh, sh.results, tag);
        },
        .loop_null_rot, .loop_cast_rot, .loop_cast_fail_rot, .loop_non_null_rot => {
            const ref_local: u32 = 3 + @as(u32, sh.params);
            try out.appendSlice(a, &.{ 0x10, 0x01 }); // call 1
            if (refTail(end)) {
                try out.append(a, 0x21); // local.set: the carried reference
                try uleb(out, a, ref_local);
            }
            try setLocals(out, a, sh.params);
            try out.appendSlice(a, &.{ 0x20, 0x03, 0x20, 0x03, 0x1a, 0x1a }); // local.get 3 twice ; drop twice
            var i: u8 = 0;
            while (i < sh.params) : (i += 1) try localGet(out, a, 3 + (i + 1) % sh.params);
            const some_i31 = [_]u8{ 0x41, 0x05, 0xfb, 0x1c }; // i32.const 5 ; ref.i31
            const null_i31 = [_]u8{ 0xd0, 0x6c }; // ref.null i31
            // `select` gives its first operand when local 1 is set.
            try out.appendSlice(a, if (end == .loop_cast_rot or end == .loop_non_null_rot) &(some_i31 ++ null_i31) else &(null_i31 ++ some_i31));
            try localGet(out, a, 1);
            try out.appendSlice(a, &.{ 0x1c, 0x01, 0x6c }); // select (result i31ref)
            try out.appendSlice(a, &take_once);
            if (end == .loop_null_rot) {
                try out.appendSlice(a, &.{ 0x10, 0x01, 0xd5, 0x00, 0x1a }); // call 1 ; br_on_null 0 ; drop
            } else if (end == .loop_cast_rot) {
                try out.appendSlice(a, &.{ 0xfb, 0x18, 0x01, 0x00, 0x6c, 0x6c }); // br_on_cast 0 i31ref (ref i31)
            } else if (end == .loop_cast_fail_rot) {
                try out.appendSlice(a, &.{ 0xfb, 0x19, 0x01, 0x00, 0x6c, 0x6c }); // br_on_cast_fail
            } else {
                try out.appendSlice(a, &.{ 0xd6, 0x00 }); // br_on_non_null 0: falls through without the reference
            }
            if (castLoop(end)) {
                try out.append(a, 0x21);
                try uleb(out, a, ref_local);
            }
            try setLocals(out, a, sh.params);
            i = 0;
            while (i < sh.params) : (i += 1) try localGet(out, a, 3 + i);
            if (castLoop(end)) try localGet(out, a, ref_local);
            if (end == .loop_non_null_rot) try out.appendSlice(a, &.{ 0xd0, 0x6c }); // ref.null i31
        },
        .nest_brif => {
            try drops(out, a, sh.params);
            try out.appendSlice(a, &.{ 0x02, 0x40 }); // block (void)
            try pushResults(out, a, sh, sh.results, tag);
            try localGet(out, a, 1);
            try out.appendSlice(a, &.{ 0x0d, 0x01 }); // br_if 1 (this frame)
            try drops(out, a, sh.results);
            try out.append(a, 0x0b);
            try pushResults(out, a, sh, sh.results, tag + 4);
        },
    }
}

// Pop the top `n` values into locals 3..3+n, the top one into the last.
fn setLocals(out: *std.ArrayList(u8), a: std.mem.Allocator, n: u8) !void {
    var i: u8 = n;
    while (i > 0) {
        i -= 1;
        try out.append(a, 0x21); // local.set
        try uleb(out, a, 3 + i);
    }
}

// `i32.const 0 ; local.set 1`, between reading local 1 and branching on it:
// a loop's back edge is then taken at most once.
const take_once = [_]u8{ 0x41, 0x00, 0x21, 0x01 };

// Pop `results` values of type `ty` off the top, converting each to i32 and
// folding it into local 2 as `value + 3 * local 2`, so two results that
// trade places change the fold.
fn accumulate(out: *std.ArrayList(u8), a: std.mem.Allocator, results: u8, ty: Ty) !void {
    var r: u8 = 0;
    while (r < results) : (r += 1) {
        try toI32(out, a, ty);
        try localGet(out, a, 2);
        try out.appendSlice(a, &.{ 0x41, 0x03, 0x6c, 0x6a }); // i32.const 3 ; i32.mul ; i32.add
        try out.append(a, 0x21); // local.set 2
        try uleb(out, a, 2);
    }
}

// What `toI32` gives for `pushConst(t, n)`.
fn constI32(t: Ty, n: u32) i32 {
    return switch (t) {
        .i32, .f64 => @intCast(n + 1),
        .ref => @intCast(n % 2),
    };
}

// What `f` returns for a loop with params (no outer skip): the fold of the
// results the arm leaves, plus the values below the frame.
fn loopValue(sh: Shape, in: [2]i32) i32 {
    var vals: [8]i32 = undefined; // the params, then the value pushed above them
    for (0..sh.params) |p| vals[p] = constI32(sh.ty, 50 + @as(u32, @intCast(p)));
    vals[sh.params] = constI32(sh.ty, 1 * 16 + 3);
    var res: [4]i32 = undefined;
    const r: usize = sh.results;
    std.debug.assert(loopArm(sh.body));
    if (loopRotates(sh.body)) {
        // Each pass rotates the params by one; the back edge adds a pass.
        const by: usize = if (in[1] != 0) 2 else 1;
        for (0..r) |i| res[i] = vals[(i + by) % r];
    } else if (sh.body == .normal) {
        for (0..r) |i| res[i] = constI32(sh.ty, 1 * 16 + @as(u32, @intCast(i)));
    } else if (sh.body == .nest_shift) {
        @memcpy(res[0..r], vals[sh.params + 1 - r ..][0..r]);
    } else {
        // The back edge, taken when local 1 is set, carries one slot up.
        const from: usize = if (in[1] != 0) 1 else 0;
        @memcpy(res[0..r], vals[from..][0..r]);
    }
    // A carried reference result is folded first: 1 when it is null, which
    // `br_on_cast` and `br_on_non_null` leave when they fall through. (No JIT
    // runs `loop_non_null_rot` yet, so its value here has met no run.)
    var acc: i32 = if (sh.body == .loop_cast_rot or sh.body == .loop_non_null_rot) 1 else 0;
    var i: usize = r;
    while (i > 0) {
        i -= 1;
        acc = res[i] +% acc *% 3;
    }
    for (0..sh.enclosing) |e| acc +%= @as(i32, @intCast(e)) + 100;
    return acc;
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
    if (sh.kind == .loop and sh.params > 0 and !loopArm(end)) return false;
    const same_count = sh.params >= 1 and sh.params == sh.results and sh.pty == .same;
    return switch (end) {
        .short1 => sh.results >= 1,
        .ret_param => carriesParam(sh),
        .drop0 => sh.params >= 1, // with no params it is `short0`
        .brif_param => sh.kind != .loop and sh.params >= 1 and sh.params == sh.results and sh.pty == .same,
        .br_out, .brt_out => sh.kind == .if_ and sh.outer_skip,
        .br_self_shift => sh.kind != .loop and sh.pty == .same and sh.params >= 1 and sh.results >= 1 and sh.params + 1 >= sh.results,
        .nest_shift => sh.pty == .same and sh.params >= 1 and sh.results >= 1 and sh.params + 1 >= sh.results,
        .brif_shift => same_count,
        .brif_shift_again => same_count and sh.kind != .loop,
        .loop_br_shift, .loop_brt_shift, .loop_rot, .loop_br_rot, .loop_brt_rot => same_count and sh.kind == .loop,
        .rot_brif, .rot_brif_again => same_count and sh.kind != .loop,
        // One reference type per frame: the i31ref these carry or test.
        .loop_null_rot, .loop_cast_rot, .loop_cast_fail_rot => same_count and sh.kind == .loop and sh.ty != .ref,
        .loop_non_null_rot => sh.kind == .loop and sh.params == sh.results and sh.pty == .same and sh.ty != .ref,
        .loop_null => sh.kind == .loop and sh.params == 0 and sh.ty != .ref,
        .nest_brif => sh.kind != .loop,
        .br_self, .brt_self, .brif_dead, .brif_live, .brif_twice, .brif_replace => sh.kind != .loop, // a branch to a loop's label is a back edge
        .catch_self => sh.kind != .loop, // the catch would branch to the header
        .normal, .short0, .other1, .over, .ret, .br_fn, .brt_fn => true,
    };
}

fn build(a: std.mem.Allocator, sh: Shape) !?[]u8 {
    // Reject shapes we do not emit as valid wasm.
    if (sh.kind != .if_ and (sh.else_ != null or sh.outer_skip)) return null;
    if (sh.kind == .loop and sh.pty != .same) return null;
    if (sh.pty == .other and sh.params == 0) return null; // no params: `other` is `same`
    if (sh.kind == .if_ and sh.else_ == null and (sh.params != sh.results or sh.pty != .same)) return null;
    if (!validArm(sh, sh.body)) return null;
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

    var p: u8 = 0;
    while (p < sh.params) : (p += 1) try pushConst(&body, a, paramTy(sh), 50 + p);
    const ref_tail = refTail(sh.body);
    if (ref_tail) try body.appendSlice(a, &.{ 0xd0, 0x6c }); // ref.null i31
    switch (sh.kind) {
        .if_ => {
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
        if (ref_tail) try body.appendSlice(a, &.{ 0xd1, 0x21, 0x02 }); // ref.is_null ; local.set 2
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
        try uleb(&types, a, sh.params + @intFromBool(ref_tail));
        p = 0;
        while (p < sh.params) : (p += 1) try types.append(a, valByte(paramTy(sh)));
        if (ref_tail) try types.append(a, 0x6c); // i31ref
        try uleb(&types, a, sh.results + @intFromBool(ref_tail));
        var r: u8 = 0;
        while (r < sh.results) : (r += 1) try types.append(a, valByte(sh.ty));
        if (ref_tail) try types.append(a, 0x6c);
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
    // Func 1, `() -> ()`, for the arms that call.
    const use_nop = brOnLoop(sh.body);
    const nop_type: u8 = tag_type + @intFromBool(use_tag);
    if (use_nop) try types.appendSlice(a, &.{ 0x60, 0x00, 0x00 });
    types.items[0] = nop_type + @intFromBool(use_nop); // type count
    try section(&mod, a, 1, types.items);
    if (use_nop) {
        try section(&mod, a, 3, &.{ 0x02, 0x00, nop_type });
    } else {
        try section(&mod, a, 3, &.{ 0x01, 0x00 }); // func 0 : type 0
    }
    if (use_tag) try section(&mod, a, 13, &.{ 0x01, 0x00, tag_type }); // tag 0
    try section(&mod, a, 7, &.{ 0x01, 0x01, 'f', 0x00, 0x00 }); // export "f"
    if (use_ref) {
        // Declarative elem segment for func 0 so `ref.func 0` validates
        // (section 9 follows the export section, §5.5 order).
        try section(&mod, a, 9, &.{ 0x01, 0x03, 0x00, 0x01, 0x00 });
    }
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(a);
    try uleb(&code, a, 1 + @as(u64, @intFromBool(use_nop)));
    var func_body: std.ArrayList(u8) = .empty;
    defer func_body.deinit(a);
    if (ref_tail) {
        // as below, then the carried reference
        try func_body.appendSlice(a, &.{ 0x03, 0x01, 0x7f, sh.params, valByte(sh.ty), 0x01, 0x6c });
    } else if (rotates(sh.body) or (sh.else_ != null and rotates(sh.else_.?))) {
        // local 2, then one local of the frame's type per param
        try func_body.appendSlice(a, &.{ 0x02, 0x01, 0x7f, sh.params, valByte(sh.ty) });
    } else {
        try func_body.appendSlice(a, &.{ 0x01, 0x01, 0x7f }); // 1 × i32: the fold accumulator, local 2
    }
    try func_body.appendSlice(a, body.items);
    try func_body.append(a, 0x0b);
    try uleb(&code, a, func_body.items.len);
    try code.appendSlice(a, func_body.items);
    if (use_nop) try code.appendSlice(a, &.{ 0x02, 0x00, 0x0b });
    try section(&mod, a, 10, code.items);

    return try mod.toOwnedSlice(a);
}

fn section(mod: *std.ArrayList(u8), a: std.mem.Allocator, id: u8, payload: []const u8) !void {
    try mod.append(a, id);
    try uleb(mod, a, payload.len);
    try mod.appendSlice(a, payload);
}

// --- running ---------------------------------------------------------------

/// The fuel the engines run with; a loop also runs on the JIT without metering.
const metered: zwasm.Module.Budget = .{ .limited = zwasm.Module.default_fuel };

const inputs = [_][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };

const RunResult = union(enum) {
    value: i32,
    trap: anyerror,
    decline, // compile / instantiate failed (invalid module, or JIT decline)
};

// One compile and instantiation per engine, then every input.
fn runAll(bytes: []const u8, use_jit: bool, fuel: zwasm.Module.Budget) [inputs.len]RunResult {
    var out: [inputs.len]RunResult = @splat(.decline);
    var eng = zwasm.Engine.init(testing.allocator, .{}) catch return out;
    defer eng.deinit();
    var mod = eng.compile(bytes) catch return out;
    defer mod.deinit();
    var inst = mod.instantiate(.{ .engine = if (use_jit) .jit else .interp, .fuel = fuel }) catch return out;
    defer inst.deinit();
    // No fuel ends a loop that never exits: a timer interrupts it instead, so
    // such a loop is a mismatch (`Interrupted`) and not a hang.
    var timer: ?std.Io.Future(void) = null;
    defer if (timer) |*f| f.cancel(testing.io);
    if (fuel == .unmetered) timer = testing.io.concurrent(interruptAfter, .{ testing.io, &inst }) catch return out;
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

/// Interrupts `inst` once `unmetered_limit_ms` have passed, unless canceled.
fn interruptAfter(io: std.Io, inst: *zwasm.Instance) void {
    io.sleep(.{ .nanoseconds = @as(i96, unmetered_limit_ms) * std.time.ns_per_ms }, .awake) catch return;
    inst.interrupt();
}

/// Far past what the four inputs of one shape take (well under a millisecond).
const unmetered_limit_ms = 20_000;

const Tally = struct {
    cur: Shape = undefined,
    shapes: u32 = 0, // shapes the generator emitted bytes for
    invalid: u32 = 0, // emitted modules the interpreter would not validate — a generator bug
    value_agree: u32 = 0, // both ran, same value
    trap_agree: u32 = 0, // both trapped the same way
    computed_agree: u32 = 0, // a loop with params: the JIT gave `loopValue`
    unmetered_agree: u32 = 0, // a loop: the JIT without fuel metering gave what it gives with it
    // Park steps the JIT's merge moves took (a cycle among them), by where
    // the moves went: a loop's params, or a block's or an `if`'s merge.
    parks_loop: u64 = 0,
    parks_forward: u64 = 0,
    // Of `parks_loop`, those on a `br_on_cast` / `br_on_cast_fail` back edge
    // and on a `br_on_null` one.
    parks_cast: u64 = 0,
    parks_null: u64 = 0,
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
    const iv = runAll(bytes, false, metered);
    if (iv[0] == .decline) {
        // The interpreter declines no valid module, so this is one the
        // generator emitted wrongly — the comparison never happened. Counted
        // and asserted to be zero, so a broken shape cannot hide as skipped.
        t.invalid += 1;
        return;
    }
    const parks_before = parallel_move.parks.load(.monotonic);
    const jv = runAll(bytes, true, metered);
    const parks = parallel_move.parks.load(.monotonic) - parks_before;
    if (t.cur.kind == .loop) t.parks_loop += parks else t.parks_forward += parks;
    if (castLoop(t.cur.body)) t.parks_cast += parks;
    if (t.cur.body == .loop_null_rot) t.parks_null += parks;
    if (jv[0] == .decline) {
        t.declined += 1;
        return;
    }
    if (t.cur.kind == .loop and (t.cur.params > 0 or refTail(t.cur.body))) {
        for (jv, inputs) |j, in| {
            const want = loopValue(t.cur, in);
            if (j == .value and j.value == want) {
                t.computed_agree += 1;
                t.credit();
            } else {
                t.mismatch += 1;
                printMismatch(t, in, "computed", .{ .value = want }, "jit", j);
            }
        }
    } else for (iv, jv, inputs) |i, j, in| {
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
            printMismatch(t, in, "interp", i, "jit", j);
        }
    }
    if (t.cur.kind == .loop) {
        // A back edge polls the fuel: without metering the JIT gives the same.
        const ju = runAll(bytes, true, .unmetered);
        for (jv, ju, inputs) |j, u, in| {
            if (std.meta.eql(j, u)) {
                t.unmetered_agree += 1;
            } else {
                t.mismatch += 1;
                printMismatch(t, in, "jit", j, "jit-unmetered", u);
            }
        }
    }
}

fn printMismatch(t: *Tally, in: [2]i32, want_from: []const u8, want: RunResult, got_from: []const u8, got: RunResult) void {
    if (t.mismatch > 30) return;
    const sh = t.cur;
    std.debug.print("  MISMATCH kind={s} ty={s} pty={s} P={d} R={d} E={d} body={s} else={s} skip={} in=({d},{d}) {s}={f} {s}={f}\n", .{
        @tagName(sh.kind), @tagName(sh.ty),                           @tagName(sh.pty),
        sh.params,         sh.results,                                sh.enclosing,
        @tagName(sh.body), if (sh.else_) |e| @tagName(e) else "none", sh.outer_skip,
        in[0],             in[1],                                     want_from,
        Fmt{ .r = want },  got_from,                                  Fmt{ .r = got },
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
                for ([_]u8{ 0, 1, 2, 3 }) |params| {
                    for ([_]u8{ 0, 1, 2, 3 }) |results| {
                        for (0..15) |enclosing| {
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
                                            .enclosing = @intCast(enclosing),
                                            .body = body,
                                            .else_ = else_,
                                            .outer_skip = outer_skip,
                                        };
                                        if (!inSweep(sh)) continue;
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
        "if-merge-enum: {d} shapes, {d} invalid, {d} value-agree, {d} trap-agree, {d} computed-agree, {d} unmetered-agree, {d} jit-declined, {d} mismatch\n" ++
            "  parks: {d} into a loop's params ({d} on br_on_cast edges, {d} on br_on_null edges), {d} into a block's or an if's merge\n" ++
            "  by kind {any}; by type {any}; by body end {any}; by else end {any}\n",
        .{
            report.shapes,         report.invalid,         report.value_agree, report.trap_agree,
            report.computed_agree, report.unmetered_agree, report.declined,    report.mismatch,
            report.parks_loop,     report.parks_cast,      report.parks_null,  report.parks_forward,
            report.by_kind,        report.by_ty,           report.by_body,     report.by_else,
        },
    );
    try testing.expectEqual(@as(u32, 0), report.mismatch);
    // Every shape the generator emits must validate and run on the interpreter;
    // a nonzero count means a module the comparison silently skipped.
    try testing.expectEqual(@as(u32, 0), report.invalid);
    // The JIT declines these and no others; one that moves from agreeing to
    // declining changes the count.
    // - `br_on_non_null` takes only a block as its target, on both arches:
    //   the 72 `loop_non_null_rot` shapes.
    // - x86_64 takes only a block for `br_on_null` too: the 66
    //   `loop_null_rot` and the 18 `loop_null` shapes.
    // - x86_64 declines a `br_table` case whose moves, poll and jump are
    //   longer than the rel8 jump that skips them: here a loop with three f64
    //   params in spill slots whose back edge is a `br_table`
    //   (`loop_brt_shift`, `loop_brt_rot`), 17 shapes.
    const declines: u32 = if (builtin.cpu.arch == .x86_64) 72 + 66 + 18 + 17 else 72;
    try testing.expectEqual(declines, report.declined);
    try testing.expect(report.shapes > 1000);
    try testing.expect(report.value_agree > 1000);
    try testing.expect(report.trap_agree > 0);
    try testing.expect(report.computed_agree > 0);
    try testing.expect(report.unmetered_agree > 0);
    // A loop's params are dead between its header and a back edge, so the
    // values an edge carries can sit in them, in any order: the rotating
    // arms make cycles, and the moves park. A block's or an `if`'s merge
    // vregs stay live to the `end`, so no carried value sits in one and no
    // cycle forms: a shape whose outer frame is a block or an `if` (it holds
    // no loop) takes no park, and one that does means that no longer holds.
    try testing.expect(report.parks_loop > 0);
    try testing.expectEqual(@as(u64, 0), report.parks_forward);
    // The moves of a `br_on_*` back edge park too, in the register the
    // branch held its condition in (RAX for `br_on_cast` on x86_64, X16 for
    // `br_on_null` on arm64): the condition is read before them.
    try testing.expect(report.parks_cast > 0);
    try testing.expect(report.parks_null > 0 or builtin.cpu.arch == .x86_64); // declined there
    // Every axis value reached a real comparison on both engines.
    for (report.by_kind) |n| try testing.expect(n > 0);
    for (report.by_ty) |n| try testing.expect(n > 0);
    for (report.by_body, all_ends) |n, e| {
        // The arms every shape of which is declined (counted above).
        const declined = e == .loop_non_null_rot or
            ((e == .loop_null_rot or e == .loop_null) and builtin.cpu.arch == .x86_64);
        try testing.expect(n > 0 or declined);
    }
    for (report.by_else, all_ends) |n, e| {
        try testing.expect(n > 0 or loopOnly(e)); // a loop has no else arm
    }
}
