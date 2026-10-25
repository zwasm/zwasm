//! Register class of the value an op pushes, which `liveness.compute`
//! records per vreg next to its range. The count of pushes stays
//! `liveness_stack_effect`'s; this file answers only "which class".
//!
//! Zone 1 (`src/ir/analysis/`).

const std = @import("std");

const zir = @import("../zir.zig");
const stack_effect = @import("liveness_stack_effect.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const ZirFunc = zir.ZirFunc;
const ValType = zir.ValType;
const RegClass = zir.RegClass;

pub fn ofValType(t: ValType) RegClass {
    return switch (t) {
        .i32, .i64, .ref => .gpr,
        .f32, .f64 => .fpr,
        .v128 => .simd,
    };
}

/// Wasm spec §5.3.1 — a value type's binary byte. Reference types and the
/// `0` that untyped `select` carries for i32/i64 operands are GPR-class.
pub fn ofSpecByte(b: u8) RegClass {
    return switch (b) {
        0x7D, 0x7C => .fpr,
        0x7B => .simd,
        else => .gpr,
    };
}

/// The class an op's result has by its name alone, or null when it depends
/// on an operand (`ofInstr` handles those). Wasm names an op after the type
/// it produces, except comparisons and the SIMD lane reductions, which
/// produce an i32.
pub fn ofOpName(op: ZirOp) ?RegClass {
    const name = @tagName(op);
    if (startsWithAny(name, &.{ "i32.", "i64.", "memory.", "table.", "ref.", "i31.", "array.", "struct." })) return .gpr;
    if (startsWithAny(name, &.{ "f32.", "f64." })) {
        return if (endsWithAny(name, &.{ ".eq", ".ne", ".lt", ".gt", ".le", ".ge" })) .gpr else .fpr;
    }
    if (zir.isSimdZirOp(op)) {
        if (std.mem.find(u8, name, ".extract_lane") != null) {
            return if (startsWithAny(name, &.{ "f32x4.", "f64x2." })) .fpr else .gpr;
        }
        if (endsWithAny(name, &.{ ".any_true", ".all_true", ".bitmask" })) return .gpr;
        return .simd;
    }
    return null;
}

/// Class of the value `instr` pushes, for the ops `stackEffect` gives a
/// non-zero push count (multi-push ops push values of one class). Null
/// when the local, global or type it reads is out of range.
pub fn ofInstr(instr: ZirInstr, func: *const ZirFunc, globals_valtypes: []const ValType) ?RegClass {
    return switch (instr.op) {
        .@"local.get" => if (instr.payload < func.sig.params.len + func.totalLocalCount()) ofValType(func.localValType(@intCast(instr.payload))) else null,
        .@"global.get" => if (instr.payload < globals_valtypes.len) ofValType(globals_valtypes[@intCast(instr.payload)]) else null,
        .select, .select_typed => ofSpecByte(@intCast(instr.extra)),
        .@"struct.get" => ofSpecByte(func.structFieldValType(@intCast(instr.payload), instr.extra)),
        .@"array.get" => ofSpecByte(func.arrayElemValType(@intCast(instr.payload))),
        else => ofOpName(instr.op),
    };
}

fn startsWithAny(name: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

fn endsWithAny(name: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |s| if (std.mem.endsWith(u8, name, s)) return true;
    return false;
}

const testing = std.testing;

test "ofOpName: every op stackEffect gives a push resolves to a class" {
    const operand_typed = [_]ZirOp{ .@"local.get", .@"global.get", .select, .select_typed, .@"struct.get", .@"array.get" };
    const ti = @typeInfo(ZirOp).@"enum";
    inline for (ti.field_names, ti.field_values) |f_name, f_value| {
        const op: ZirOp = @fromBackingInt(@intCast(f_value));
        const pushes = if (stack_effect.stackEffect(op)) |e| e.pushes else 0;
        if (pushes > 0 and std.mem.findScalar(ZirOp, &operand_typed, op) == null) {
            if (ofOpName(op) == null) {
                std.debug.print("no result class for {s}\n", .{f_name});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "ofOpName: the name rule's exceptions" {
    try testing.expectEqual(RegClass.fpr, ofOpName(.@"f32.add").?);
    try testing.expectEqual(RegClass.gpr, ofOpName(.@"f64.lt").?);
    try testing.expectEqual(RegClass.gpr, ofOpName(.@"i32.reinterpret_f32").?);
    try testing.expectEqual(RegClass.fpr, ofOpName(.@"f32.convert_i64_u").?);
    try testing.expectEqual(RegClass.simd, ofOpName(.@"f32x4.eq").?);
    try testing.expectEqual(RegClass.fpr, ofOpName(.@"f32x4.extract_lane").?);
    try testing.expectEqual(RegClass.gpr, ofOpName(.@"i16x8.extract_lane_s").?);
    try testing.expectEqual(RegClass.gpr, ofOpName(.@"v128.any_true").?);
    try testing.expectEqual(RegClass.gpr, ofOpName(.@"i8x16.bitmask").?);
}
