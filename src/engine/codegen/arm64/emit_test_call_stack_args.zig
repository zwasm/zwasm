//! #425 — a call's stack arguments, the frame reserved for them and the
//! MEMORY-class return buffer are laid out by one rule, checked here for both
//! packings on any host: the packing is a parameter, not the build target.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const abi = @import("abi.zig");
const ctx_mod = @import("ctx.zig");
const emit_setup = @import("emit_setup.zig");
const op_call = @import("op_call.zig");

const testing = std.testing;
const ValType = zir.ValType;

const max_ints = 12;
const max_fps = 10;
const max_params = max_ints + max_fps;

/// End of the highest store to `[SP, #off]` in `code`. Decodes "load/store
/// register (unsigned immediate)" (Arm ARM C4.1): size:111:V:01:opc:imm12:Rn:Rt,
/// a store when opc is 00, or 10 with V=1 and size=00 (a 128-bit STR).
fn spStoreEnd(code: []const u8) u32 {
    var end: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= code.len) : (i += 4) {
        const w = std.mem.readInt(u32, code[i..][0..4], .little);
        if (w & 0x3B00_0000 != 0x3900_0000) continue;
        if ((w >> 5) & 31 != 31) continue;
        const size: u5 = @intCast(w >> 30);
        const v = (w >> 26) & 1;
        const opc = (w >> 22) & 3;
        const bytes: u32 = if (opc == 0)
            @as(u32, 1) << size
        else if (opc == 2 and v == 1 and size == 0)
            16
        else
            continue;
        end = @max(end, ((w >> 10) & 0xFFF) * bytes + bytes);
    }
    return end;
}

/// Run the real marshaller over `sig` and return where its stack writes end.
fn marshalledEnd(packing: abi.StackArgPacking, sig: zir.FuncType) !u32 {
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(a);
    var slots: [max_params]u16 = undefined;
    for (&slots, 0..) |*s, i| s.* = @intCast(i);
    for (0..sig.params.len) |i| try pushed.append(a, @intCast(i));

    // The marshaller reads only these fields.
    var ctx: ctx_mod.EmitCtx = undefined;
    ctx.allocator = a;
    ctx.buf = &buf;
    ctx.alloc = .{ .slots = &slots, .n_slots = max_params };
    ctx.pushed_vregs = &pushed;
    ctx.spill_base_off = 1024;
    try op_call.marshalCallArgsPacked(&ctx, packing, sig);
    return spStoreEnd(buf.items);
}

/// What the frame prescan reserves for a function whose one call is to `sig`.
fn frameReserved(packing: abi.StackArgPacking, sig: zir.FuncType) !u32 {
    var f = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    return emit_setup.computeOutgoingMaxBytes(packing, &f, &.{sig}, &.{}, 0);
}

const IntKind = enum { i32, i64, mixed };
const FpKind = enum { f32, f64, mixed, v128 };
const Order = enum { ints_first, fps_first, alternating };

fn intType(kind: IntKind, i: usize) ValType {
    return switch (kind) {
        .i32 => .i32,
        .i64 => .i64,
        .mixed => if (i % 2 == 0) .i32 else .i64,
    };
}

fn fpType(kind: FpKind, i: usize) ValType {
    return switch (kind) {
        .f32 => .f32,
        .f64 => .f64,
        .mixed => if (i % 2 == 0) .f32 else .f64,
        .v128 => .v128,
    };
}

fn fillParams(out: *[max_params]ValType, n_int: usize, ik: IntKind, n_fp: usize, fk: FpKind, order: Order) []const ValType {
    var n: usize = 0;
    var i: usize = 0;
    var f: usize = 0;
    while (i < n_int or f < n_fp) {
        const take_int = switch (order) {
            .ints_first => i < n_int,
            .fps_first => f >= n_fp,
            .alternating => i < n_int and (f >= n_fp or i <= f),
        };
        if (take_int) {
            out[n] = intType(ik, i);
            i += 1;
        } else {
            out[n] = fpType(fk, f);
            f += 1;
        }
        n += 1;
    }
    return out[0..n];
}

fn align16(n: u32) u32 {
    return (n + 15) & ~@as(u32, 15);
}

test "call stack arguments: the marshaller, the frame prescan and the return-buffer offset agree for both packings (#425)" {
    const results = [_]ValType{ .i64, .i64, .i64, .i64 };
    var disagree = [_]u32{ 0, 0 };
    var params_buf: [max_params]ValType = undefined;
    for ([_]abi.StackArgPacking{ .aapcs64, .apple }, 0..) |packing, pi| {
        for (0..max_ints + 1) |n_int| for (std.enums.values(IntKind)) |ik| {
            for (0..max_fps + 1) |n_fp| for (std.enums.values(FpKind)) |fk| {
                for (std.enums.values(Order)) |order| for (1..5) |n_res| {
                    const sig: zir.FuncType = .{
                        .params = fillParams(&params_buf, n_int, ik, n_fp, fk, order),
                        .results = results[0..n_res],
                    };
                    const written = try marshalledEnd(packing, sig);
                    const reserved = try frameReserved(packing, sig);
                    const args_end = align16(written);
                    // The argument region ends where the last write does, rounded
                    // as the frame rounds; a MEMORY-class buffer starts there and
                    // ends with the reservation.
                    const ok = if (n_res > 2)
                        abi.callReturnBufferOff(packing, sig) == args_end and
                            reserved == args_end + n_res * 8
                    else
                        reserved == args_end;
                    if (!ok) {
                        if (disagree[pi] == 0) std.debug.print("first disagreement, {s}: {any} -> {d} results\n", .{ @tagName(packing), sig.params, n_res });
                        disagree[pi] += 1;
                    }
                    // The bridge thunk copies by the 8-byte-stride count on every
                    // target (ADR-0228): one word per scalar past X1..X7 / V0..V7,
                    // and never less than the Apple region.
                    const words = abi.callStackArgBytes(.aapcs64, sig) / 8;
                    try testing.expect(words * 8 >= abi.callStackArgBytes(.apple, sig));
                    if (fk != .v128) try testing.expectEqual((n_int -| 7) + (n_fp -| 8), words);
                };
            };
        };
    }
    try testing.expectEqual([_]u32{ 0, 0 }, disagree);
}

test "call stack arguments: eleven i32 and three results on Apple — 16 bytes of arguments, buffer at 16, 40 reserved (#425)" {
    const params: [11]ValType = @splat(.i32);
    const sig: zir.FuncType = .{ .params = &params, .results = &.{ .i32, .i32, .i32 } };
    try testing.expectEqual(@as(u32, 16), try marshalledEnd(.apple, sig));
    try testing.expectEqual(@as(u32, 16), abi.callReturnBufferOff(.apple, sig));
    try testing.expectEqual(@as(u32, 40), try frameReserved(.apple, sig));
    // The 8-byte stride: four slots (the last STR W ends at 28), buffer at 32,
    // 56 reserved.
    try testing.expectEqual(@as(u32, 28), try marshalledEnd(.aapcs64, sig));
    try testing.expectEqual(@as(u32, 32), abi.callReturnBufferOff(.aapcs64, sig));
    try testing.expectEqual(@as(u32, 56), try frameReserved(.aapcs64, sig));
}
