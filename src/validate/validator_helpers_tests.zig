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

    // The GC family is admissible per `is_const` but not typed here. Every one
    // of its forms yields a reference, so the verdict splits on what the
    // position expects: a reference is undeterminable (an incomplete walker
    // must not reject a valid module), a numeric type is an outright mismatch.
    try testing.expectEqual(validator.ConstExprVerdict.undeterminable, validator.validateConstExpr(&[_]u8{ 0xFB, 0x00, 0x03, 0x0B }, ValType.anyref, scope));
    try testing.expectEqual(validator.ConstExprVerdict.invalid, validator.validateConstExpr(&[_]u8{ 0xFB, 0x00, 0x03, 0x0B }, .i32, scope));

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
