//! Where a call's arguments go, the frame reserved for them and the
//! MEMORY-class return buffer follow one rule (`abi.ArgCursor`, walked whole by
//! `abi.callStackLayout`), checked here for both calling conventions on any
//! host: the convention is a parameter, not the build target. The numbers are
//! hand-computed from the ABI, and every placement is checked against what the
//! marshaller and the callee's prologue rely on.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const abi = @import("abi.zig");
const emit_setup = @import("emit_setup.zig");
const op_call = @import("op_call.zig");

const testing = std.testing;
const ValType = zir.ValType;

fn sig(params: []const ValType, results: []const ValType) zir.FuncType {
    return .{ .params = params, .results = results };
}

/// Where a MEMORY-class callee's return buffer begins under `cc`.
fn bufOff(cc: abi.Cc, params: []const ValType, results: []const ValType) u32 {
    return abi.callStackLayout(cc, sig(params, results)).return_buffer_off;
}

const one = [_]ValType{.i64};
const three = [_]ValType{ .i64, .i64, .i64 };
const four = [_]ValType{ .i64, .i64, .i64, .i64 };
const i64x5: [5]ValType = @splat(.i64);
const i64x6: [6]ValType = @splat(.i64);
const f64x8: [8]ValType = @splat(.f64);
const f64x9: [9]ValType = @splat(.f64);
const v128x8: [8]ValType = @splat(.v128);
const f8_v128 = f64x8 ++ [_]ValType{.v128};
const i6_f8_v128 = i64x6 ++ f64x8 ++ [_]ValType{.v128};
const i5_f8_v128 = i64x5 ++ f64x8 ++ [_]ValType{.v128};
const i64x3: [3]ValType = @splat(.i64);
const i64x4: [4]ValType = @splat(.i64);
const i3_v128 = i64x3 ++ [_]ValType{.v128};
const i4_v128 = i64x4 ++ [_]ValType{.v128};
const v128_1 = [_]ValType{.v128};

// SysV §3.2.3: 5 user integer registers (4 when the callee is MEMORY-class and
// &buffer takes one), 8 XMM, one shared NSAA stream of eightbytes, and a
// `v128` overflow takes two 16-aligned eightbytes.
test "callStackLayout SysV: scalars ride registers or the NSAA stream" {
    // Everything in registers.
    try testing.expectEqual(@as(u32, 0), bufOff(.sysv, &.{}, &one));
    try testing.expectEqual(@as(u32, 0), bufOff(.sysv, &i64x5, &one));
    try testing.expectEqual(@as(u32, 0), bufOff(.sysv, &f64x8, &one));
    // The sixth integer and the ninth float each take one eightbyte.
    try testing.expectEqual(@as(u32, 8), bufOff(.sysv, &i64x6, &one));
    try testing.expectEqual(@as(u32, 8), bufOff(.sysv, &f64x9, &one));
}

test "callStackLayout SysV: a v128 stack argument takes two 16-aligned eightbytes" {
    // Eight floats fill XMM0..7; the v128 overflows to [RSP+0..15], ending at 16.
    try testing.expectEqual(@as(u32, 16), bufOff(.sysv, &f8_v128, &one));
    // Six integers overflow one eightbyte (NSAA=1); the v128 then rounds NSAA to
    // 2 before its two eightbytes, ending at 32 — the eightbyte-per-scalar count
    // reported 24 and left the top half of the v128 past the region.
    try testing.expectEqual(@as(u32, 32), bufOff(.sysv, &i6_f8_v128, &one));
    // A v128 inside the XMM pool rides a register, nothing on the stack.
    try testing.expectEqual(@as(u32, 0), bufOff(.sysv, &v128x8, &one));
}

test "callStackLayout SysV: a MEMORY-class callee loses one integer register, buffer above the args" {
    // Three results ⇒ &buffer in RDI, rt in RSI: four user integer registers.
    // Eight floats + v128 overflow end at 16; the buffer starts there.
    try testing.expectEqual(@as(u32, 16), bufOff(.sysv, &f8_v128, &three));
    // Five integers now spill the fifth (four user registers), then the v128.
    try testing.expectEqual(@as(u32, 32), bufOff(.sysv, &i5_f8_v128, &three));
}

// Win64 §"Parameter passing": 3 user positions shared by integer/FP/v128 (2
// when MEMORY-class), a 32-byte shadow below the call, and each `v128` a hidden
// pointer plus a 16-byte scratch slot above shadow + overflow.
test "callStackLayout Win64: shadow, shared positions and v128 scratch" {
    // No stack arguments still reserves the 32-byte shadow.
    try testing.expectEqual(abi.CallStackLayout{ .return_buffer_off = 32, .v128_scratch_base = 32 }, abi.callStackLayout(.win64, sig(&.{}, &one)));
    try testing.expectEqual(@as(u32, 32), bufOff(.win64, &i64x3, &one));
    // The fourth position overflows one eightbyte; the region rounds to 16.
    try testing.expectEqual(@as(u32, 48), bufOff(.win64, &i64x4, &one));
    // One v128 in a register position: scratch at the shadow top, buffer above.
    try testing.expectEqual(abi.CallStackLayout{ .return_buffer_off = 48, .v128_scratch_base = 32 }, abi.callStackLayout(.win64, sig(&v128_1, &one)));
    // Three integers fill the positions, the v128 overflows its pointer.
    try testing.expectEqual(@as(u32, 64), bufOff(.win64, &i3_v128, &one));
}

test "callStackLayout Win64: a MEMORY-class callee loses one position" {
    // Two user positions (RCX=&buffer, RDX=rt): of four integers and a v128,
    // three overflow (integers 3 and 4, then the v128's pointer), 32 + 24 = 56,
    // and the scratch rounds up to 64.
    try testing.expectEqual(abi.CallStackLayout{ .return_buffer_off = 80, .v128_scratch_base = 64 }, abi.callStackLayout(.win64, sig(&i4_v128, &three)));
}

// ADR-0061: a reference rides the i64 integer class, so it takes an integer
// register or position like any other.
test "callStackLayout: a reference parameter takes an integer position on both conventions" {
    const r = ValType.funcref;
    // SysV: five references fill RSI..R9, the sixth overflows one eightbyte.
    try testing.expectEqual(@as(u32, 8), bufOff(.sysv, &.{ r, r, r, r, r, r }, &one));
    // Win64: references 1-3 fill RDX/R8/R9, the fourth and the v128's pointer
    // overflow two positions (32 + 16 = 48), the scratch starts there.
    try testing.expectEqual(abi.CallStackLayout{ .return_buffer_off = 64, .v128_scratch_base = 48 }, abi.callStackLayout(.win64, sig(&.{ r, r, r, r, .v128 }, &one)));
}

const max_params = 24;
const IntKind = enum { i32, i64, ref };
const FpKind = enum { f32, f64, v128, mixed };
const Order = enum { ints_first, fps_first, alternating };

fn fillParams(out: *[max_params]ValType, n_int: usize, ik: IntKind, n_fp: usize, fk: FpKind, order: Order) []const ValType {
    var n: usize = 0;
    var i: usize = 0;
    var f: usize = 0;
    while (i < n_int or f < n_fp) : (n += 1) {
        const take_int = switch (order) {
            .ints_first => i < n_int,
            .fps_first => f >= n_fp,
            .alternating => i < n_int and (f >= n_fp or i <= f),
        };
        if (take_int) {
            out[n] = switch (ik) {
                .i32 => .i32,
                .i64 => .i64,
                .ref => ValType.funcref,
            };
            i += 1;
        } else {
            out[n] = switch (fk) {
                .f32 => .f32,
                .f64 => .f64,
                .v128 => .v128,
                .mixed => switch (f % 3) {
                    0 => .f64,
                    1 => .v128,
                    else => .f32,
                },
            };
            f += 1;
        }
    }
    return out[0..n];
}

const Span = struct { lo: u32, hi: u32 };

/// Place every argument of `s` and check what the marshaller and the callee's
/// prologue rely on: each register and each position is used once, no two
/// stack writes overlap, a SysV `v128` sits on 16 bytes, Win64 arguments sit
/// above the shadow and its scratch above them, and the return buffer starts
/// past every write (for SysV, right where the last one ends).
fn checkPlacement(cc: abi.Cc, s: zir.FuncType) !void {
    const n_gpr: usize = switch (cc) {
        .sysv => abi.sysv.arg_gprs.len,
        .win64 => abi.win64.arg_gprs.len,
    };
    const n_xmm: usize = switch (cc) {
        .sysv => abi.sysv.arg_xmms.len,
        .win64 => abi.win64.arg_xmms.len,
    };
    const shadow: u32 = switch (cc) {
        .sysv => abi.sysv.shadow_space_bytes,
        .win64 => abi.win64.shadow_space_bytes,
    };
    // Win64 shares one position sequence between the two register files.
    var gpr_used: [8]bool = @splat(false);
    var xmm_used: [8]bool = @splat(false);
    var spans: [2 * max_params]Span = undefined;
    var n_spans: usize = 0;
    var overflow_end: u32 = shadow;
    var scratch_lo: u32 = std.math.maxInt(u32);
    var cursor = abi.ArgCursor.init(cc, s);
    for (s.params) |p| {
        switch (cursor.next(p)) {
            .gpr => |i| {
                try testing.expect(i < n_gpr and !gpr_used[i] and !(cc == .win64 and xmm_used[i]));
                gpr_used[i] = true;
            },
            .xmm => |i| {
                try testing.expect(i < n_xmm and !xmm_used[i] and !(cc == .win64 and gpr_used[i]));
                xmm_used[i] = true;
            },
            .stack => |off| {
                const size: u32 = if (p == .v128) 16 else 8;
                try testing.expect(off >= shadow and off % size == 0);
                spans[n_spans] = .{ .lo = off, .hi = off + size };
                n_spans += 1;
                overflow_end = @max(overflow_end, off + size);
            },
            .win64_v128 => |w| {
                try testing.expect(cc == .win64 and w.scratch % 16 == 0);
                spans[n_spans] = .{ .lo = w.scratch, .hi = w.scratch + 16 };
                n_spans += 1;
                scratch_lo = @min(scratch_lo, w.scratch);
                switch (w.ptr) {
                    .gpr => |i| {
                        try testing.expect(i < n_gpr and !gpr_used[i] and !xmm_used[i]);
                        gpr_used[i] = true;
                    },
                    .stack => |off| {
                        try testing.expect(off >= shadow and off % 8 == 0);
                        spans[n_spans] = .{ .lo = off, .hi = off + 8 };
                        n_spans += 1;
                        overflow_end = @max(overflow_end, off + 8);
                    },
                }
            },
        }
    }
    for (spans[0..n_spans], 0..) |a, i| for (spans[i + 1 .. n_spans]) |b| {
        try testing.expect(a.hi <= b.lo or b.hi <= a.lo);
    };
    if (scratch_lo != std.math.maxInt(u32)) try testing.expect(scratch_lo >= overflow_end);
    const layout = abi.callStackLayout(cc, s);
    var writes_end: u32 = 0;
    for (spans[0..n_spans]) |sp| writes_end = @max(writes_end, sp.hi);
    try testing.expect(layout.return_buffer_off >= writes_end);
    if (cc == .sysv) try testing.expectEqual(writes_end, layout.return_buffer_off);
}

// The signature axes the boundaries live on: integer kind and count across the
// SysV 5 (4 MEMORY-class) and Win64 3 (2) register budgets, FP/SIMD kind and
// count across the 8-XMM bank, their order (which moves the SysV `v128`
// padding), and the result count across the MEMORY-class threshold.
test "ArgCursor: every placement is disjoint and below the return buffer, both conventions" {
    var params_buf: [max_params]ValType = undefined;
    var cells: usize = 0;
    for ([_]abi.Cc{ .sysv, .win64 }) |cc| {
        for (0..9) |n_int| for (std.enums.values(IntKind)) |ik| {
            for (0..11) |n_fp| for (std.enums.values(FpKind)) |fk| {
                for (std.enums.values(Order)) |order| for (1..5) |n_res| {
                    const s = sig(fillParams(&params_buf, n_int, ik, n_fp, fk, order), four[0..n_res]);
                    try checkPlacement(cc, s);
                    cells += 1;
                };
            };
        };
    }
    try testing.expectEqual(@as(usize, 2 * 9 * 3 * 11 * 4 * 3 * 4), cells);
}

/// The frame a function reserves for its one call to `callee`.
fn frameReserved(callee: zir.FuncType) !u32 {
    var f = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    return emit_setup.computeOutgoingMaxBytes(&f, &.{callee}, &.{}, 0);
}

// The prescan adds a MEMORY-class callee's N×8-byte buffer above the stack
// arguments; the return-buffer offset is where the buffer begins.
test "the frame prescan reserves the stack arguments and a MEMORY-class buffer (host convention)" {
    const shapes = [_]zir.FuncType{
        sig(&.{}, &one),
        sig(&i64x6, &one),
        sig(&f8_v128, &one),
        sig(&i6_f8_v128, &one),
        sig(&f8_v128, &three),
        sig(&i5_f8_v128, &three),
    };
    for (shapes) |s| {
        const args_end = abi.callStackLayout(abi.current_cc, s).return_buffer_off;
        if (s.results.len > 2) {
            try testing.expectEqual(args_end, op_call.computeCallReturnBufferOff(s));
        }
        const buf: u32 = if (s.results.len > 2) @intCast(s.results.len * 8) else 0;
        try testing.expectEqual(args_end + buf, try frameReserved(s));
    }
}
