//! Tests for the pure const-expr sub-language in `validator_helpers.zig`.
//!
//! Split from `validator_tests.zig` rather than raising that file's cap: these
//! exercise the extracted helper module, not `Validator` state, so the sibling
//! placement matches what they test (ADR-0099 P/N split over marker bump).

const std = @import("std");
const testing = std.testing;

const validator = @import("validator.zig");
const sections = @import("../parse/sections.zig");
const zir = @import("../ir/zir.zig");
const ValType = zir.ValType;
const GlobalEntry = validator.GlobalEntry;

test "validateConstExpr: is_const opcode set + arity + global.get mutability (§3.3.13.1)" {
    var types: sections.Types = .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .items = &.{},
        .kinds = &.{},
        .struct_defs = &.{},
        .array_defs = &.{},
        .supertypes = &.{},
        .finals = &.{},
        .rec_span = &.{},
    };
    defer types.deinit();

    const globals = [_]GlobalEntry{
        .{ .valtype = .i32, .mutable = false }, // 0: immutable
        .{ .valtype = .i32, .mutable = true }, // 1: mutable
    };
    const fti = [_]u32{0};
    const scope: validator.ConstExprScope = .{
        .globals = &globals,
        .func_type_indices = &fti,
        .types = &types,
    };

    // Well-formed: i32.const 7; end
    try testing.expectEqual(validator.ConstExprVerdict.ok, validator.validateConstExpr(&[_]u8{ 0x41, 0x07, 0x0B }, .i32, scope));
    // extended-const: i32.const 20; i32.const 2; i32.mul; end
    try testing.expectEqual(validator.ConstExprVerdict.ok, validator.validateConstExpr(&[_]u8{ 0x41, 0x14, 0x41, 0x02, 0x6C, 0x0B }, .i32, scope));
    // global.get 0 (immutable) is const
    try testing.expectEqual(validator.ConstExprVerdict.ok, validator.validateConstExpr(&[_]u8{ 0x23, 0x00, 0x0B }, .i32, scope));

    // global.get 1 reads a MUTABLE global — `is_const` excludes it.
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0x23, 0x01, 0x0B }, .i32, scope));
    // global.get 2 is out of the scope's window.
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0x23, 0x02, 0x0B }, .i32, scope));
    // Empty expression produces nothing where one value is required.
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{0x0B}, .i32, scope));
    // Two values left on the stack.
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0x41, 0x00, 0x41, 0x00, 0x0B }, .i32, scope));
    // Result type mismatch: f32.const into an i32 slot.
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0x43, 0x00, 0x00, 0x00, 0x00, 0x0B }, .i32, scope));
    // i32.add over i64 operands.
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0x42, 0x01, 0x42, 0x02, 0x6A, 0x0B }, .i64, scope));
    // An opcode outside `is_const` (i32.eqz).
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0x41, 0x00, 0x45, 0x0B }, .i32, scope));
    // ref.func with an out-of-range funcidx.
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0xD2, 0x09, 0x0B }, ValType.funcref, scope));
    // Trailing bytes after `end`.
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0x41, 0x00, 0x0B, 0x41, 0x00 }, .i32, scope));

    // The GC family is admissible per `is_const`. `ref.i31` wraps one i32
    // into a `(ref i31)`, which an i31ref position accepts and an i32 one
    // does not.
    try testing.expectEqual(validator.ConstExprVerdict.ok, validator.validateConstExpr(&[_]u8{ 0x41, 0x01, 0xFB, 0x1C, 0x0B }, ValType.i31ref, scope));
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0x41, 0x01, 0xFB, 0x1C, 0x0B }, .i32, scope));
    // struct.new names a type this (empty) type section does not define.
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0xFB, 0x00, 0x03, 0x0B }, ValType.anyref, scope));
    // The walk continues past the GC form (PR #428 review): a numeric value
    // left beside the reference, a missing operand, and a non-const GC op
    // (`array.len`) are each invalid, as they are for the reference
    // interpreter.
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0x41, 0x01, 0xFB, 0x1C, 0x41, 0x02, 0x0B }, ValType.i31ref, scope));
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0xFB, 0x1C, 0x0B }, ValType.i31ref, scope));
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0x41, 0x01, 0xFB, 0x1C, 0xFB, 0x0F, 0x0B }, ValType.i31ref, scope));

    // An expression deeper than a single instruction's arity is typed, not
    // waved through: extended-const can push many operands before folding.
    try testing.expectEqual(validator.ConstExprVerdict.ok, validator.validateConstExpr(&[_]u8{ 0x41, 0x01, 0x41, 0x02, 0x41, 0x03, 0x6A, 0x6A, 0x0B }, .i32, scope));
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0x41, 0x01, 0x42, 0x02, 0x6A, 0x0B }, .i32, scope));
}

test "validateConstExpr: the readable-global window is positional (§3.3.13.1 context order)" {
    var types: sections.Types = .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .items = &.{},
        .kinds = &.{},
        .struct_defs = &.{},
        .array_defs = &.{},
        .supertypes = &.{},
        .finals = &.{},
        .rec_span = &.{},
    };
    defer types.deinit();

    const all = [_]GlobalEntry{
        .{ .valtype = .i32, .mutable = false }, // 0: imported
        .{ .valtype = .i32, .mutable = false }, // 1: defined
    };
    const fti = [_]u32{};
    const get1 = [_]u8{ 0x23, 0x01, 0x0B }; // global.get 1; end

    // A table init expr sees imports only — `check_module` folds tables before
    // globals — so global 1 is out of scope there.
    const imports_only: validator.ConstExprScope = .{ .globals = all[0..1], .func_type_indices = &fti, .types = &types };
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&get1, .i32, imports_only));

    // A data or elem offset sees every global.
    const everything: validator.ConstExprScope = .{ .globals = &all, .func_type_indices = &fti, .types = &types };
    try testing.expectEqual(validator.ConstExprVerdict.ok, validator.validateConstExpr(&get1, .i32, everything));
}

fn concrete(nullable: bool, t: u32) ValType {
    return .{ .ref = .{ .nullable = nullable, .heap_type = .{ .concrete = t } } };
}

fn abstract(ht: zir.AbstractHeapType, nullable: bool) ValType {
    return .{ .ref = zir.RefType.abs(ht, nullable) };
}

/// 0: (sub (struct (field i32)))           — open, so 4 can extend it
/// 1: (struct (field (ref 0)))             — a non-defaultable field
/// 2: (array (mut i8))                     — packed: takes an i32
/// 3: (array (ref null 0))
/// 4: (sub 0 (struct (field i32) (field i64)))  — a proper subtype of 0
/// 5: (array (ref 0))                      — a non-defaultable element
const gc_type_body = [_]u8{
    0x06,
    0x50,
    0x00,
    0x5F,
    0x01,
    0x7F,
    0x00,
    0x5F,
    0x01,
    0x64,
    0x00,
    0x00,
    0x5E,
    0x78,
    0x01,
    0x5E,
    0x63,
    0x00,
    0x00,
    0x50,
    0x01,
    0x00,
    0x5F,
    0x02,
    0x7F,
    0x00,
    0x7E,
    0x00,
    0x5E,
    0x64,
    0x00,
    0x00,
};

/// `struct.new 4` over (i32.const 1) (i64.const 2): a `(ref 4)`, which is a
/// proper subtype of `(ref 0)`.
const s4 = [_]u8{ 0x41, 0x01, 0x42, 0x02, 0xFB, 0x00, 0x04 };

const ok = validator.ConstExprVerdict.ok;
const invalid = validator.ConstExprVerdict.invalid;

fn gcVerdict(expr: []const u8, expected: ValType) !validator.ConstExprVerdict {
    var types = try sections.decodeTypes(testing.allocator, &gc_type_body);
    defer types.deinit();
    return validator.validateConstExpr(expr, expected, .{ .globals = &.{}, .func_type_indices = &.{}, .types = &types });
}

test "validateConstExpr: struct.new takes a subtype of each field (#430)" {
    try testing.expectEqual(ok, try gcVerdict(&(s4 ++ [_]u8{ 0xFB, 0x00, 0x01, 0x0B }), concrete(false, 1)));
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0xD0, 0x71, 0xFB, 0x00, 0x01, 0x0B }, concrete(false, 1))); // nullref into (ref 0)
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0x42, 0x07, 0xFB, 0x00, 0x00, 0x0B }, concrete(false, 0))); // i64 into i32
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0x42, 0x02, 0x41, 0x01, 0xFB, 0x00, 0x04, 0x0B }, concrete(false, 4))); // fields swapped
}

test "validateConstExpr: a GC constructor is the concrete (ref $t) (#430)" {
    try testing.expectEqual(ok, try gcVerdict(&(s4 ++ [_]u8{0x0B}), concrete(true, 0)));
    try testing.expectEqual(ok, try gcVerdict(&(s4 ++ [_]u8{0x0B}), abstract(.struct_, false)));
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0x41, 0x01, 0xFB, 0x00, 0x00, 0x0B }, concrete(false, 4)));
    try testing.expectEqual(invalid, try gcVerdict(&(s4 ++ [_]u8{0x0B}), abstract(.array, true)));
    try testing.expectEqual(invalid, try gcVerdict(&(s4 ++ [_]u8{0x0B}), .i32));
}

test "validateConstExpr: struct.new_default needs every field defaultable (#430)" {
    try testing.expectEqual(ok, try gcVerdict(&[_]u8{ 0xFB, 0x01, 0x00, 0x0B }, concrete(false, 0)));
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0xFB, 0x01, 0x01, 0x0B }, concrete(false, 1)));
}

test "validateConstExpr: array.new takes the element type and an i32 length (#430)" {
    // A packed element takes an i32.
    try testing.expectEqual(ok, try gcVerdict(&[_]u8{ 0x41, 0x07, 0x41, 0x03, 0xFB, 0x06, 0x02, 0x0B }, concrete(false, 2)));
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0x42, 0x07, 0x41, 0x03, 0xFB, 0x06, 0x02, 0x0B }, concrete(false, 2)));
    try testing.expectEqual(ok, try gcVerdict(&(s4 ++ [_]u8{ 0x41, 0x03, 0xFB, 0x06, 0x03, 0x0B }), concrete(false, 3)));
    try testing.expectEqual(invalid, try gcVerdict(&(s4 ++ [_]u8{ 0x42, 0x03, 0xFB, 0x06, 0x03, 0x0B }), concrete(false, 3))); // i64 length
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0x41, 0x00, 0x41, 0x03, 0xFB, 0x06, 0x03, 0x0B }, concrete(false, 3))); // i32 element
}

test "validateConstExpr: array.new_default needs a defaultable element and an i32 length (#430)" {
    try testing.expectEqual(ok, try gcVerdict(&[_]u8{ 0x41, 0x03, 0xFB, 0x07, 0x03, 0x0B }, concrete(false, 3)));
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0x41, 0x03, 0xFB, 0x07, 0x05, 0x0B }, concrete(false, 5)));
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0x42, 0x03, 0xFB, 0x07, 0x03, 0x0B }, concrete(false, 3)));
}

test "validateConstExpr: array.new_fixed takes N operands of the element type (#430)" {
    try testing.expectEqual(ok, try gcVerdict(&([_]u8{ 0xD0, 0x71 } ++ s4 ++ [_]u8{ 0xFB, 0x08, 0x03, 0x02, 0x0B }), concrete(false, 3)));
    try testing.expectEqual(invalid, try gcVerdict(&([_]u8{ 0x41, 0x00 } ++ s4 ++ [_]u8{ 0xFB, 0x08, 0x03, 0x02, 0x0B }), concrete(false, 3)));
    try testing.expectEqual(invalid, try gcVerdict(&(s4 ++ [_]u8{ 0xFB, 0x08, 0x03, 0x02, 0x0B }), concrete(false, 3)));
}

test "validateConstExpr: any.convert_extern takes the extern hierarchy and keeps nullability (#430)" {
    try testing.expectEqual(ok, try gcVerdict(&[_]u8{ 0xD0, 0x72, 0xFB, 0x1A, 0x0B }, ValType.anyref)); // noextern <: extern
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0xD0, 0x72, 0xFB, 0x1A, 0x0B }, abstract(.any, false)));
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0xD0, 0x71, 0xFB, 0x1A, 0x0B }, ValType.anyref));
}

test "validateConstExpr: extern.convert_any takes the any hierarchy and keeps nullability (#430)" {
    try testing.expectEqual(ok, try gcVerdict(&(s4 ++ [_]u8{ 0xFB, 0x1B, 0x0B }), abstract(.extern_, false)));
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0xD0, 0x72, 0xFB, 0x1B, 0x0B }, abstract(.extern_, true)));
    try testing.expectEqual(invalid, try gcVerdict(&(s4 ++ [_]u8{ 0xFB, 0x1B, 0x0B }), ValType.anyref));
}

test "validateConstExpr: ref.i31 takes an i32 and is a (ref i31) (#430)" {
    try testing.expectEqual(ok, try gcVerdict(&[_]u8{ 0x41, 0x01, 0xFB, 0x1C, 0x0B }, abstract(.eq, false)));
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0x42, 0x01, 0xFB, 0x1C, 0x0B }, ValType.i31ref));
    try testing.expectEqual(invalid, try gcVerdict(&[_]u8{ 0x41, 0x01, 0xFB, 0x1C, 0x0B }, concrete(true, 0)));
}
