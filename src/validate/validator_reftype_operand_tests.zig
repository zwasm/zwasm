//! Tests for the reference operands whose type the spec pins to a hierarchy
//! (#322): `throw_ref`, `ref.test`, `ref.cast`, `array.len`,
//! `br_on_cast{,_fail}` and `i31.get_{s,u}`. Each arm gets a refused operand
//! from another hierarchy and an accepted operand that is a proper subtype.
//! A sibling of `validator_tests.zig`, which is past its size cap.

const std = @import("std");
const testing = std.testing;

const validator = @import("validator.zig");
const zir = @import("../ir/zir.zig");
const sections = @import("../parse/sections.zig");

const Error = validator.Error;
const ValType = zir.ValType;
const FuncType = zir.FuncType;

fn abs(ht: zir.AbstractHeapType, nullable: bool) ValType {
    return .{ .ref = zir.RefType.abs(ht, nullable) };
}

fn conc(idx: u32, nullable: bool) ValType {
    return .{ .ref = .{ .nullable = nullable, .heap_type = .{ .concrete = idx } } };
}

// 0: (struct)  1: (array i32)  2: (func)
const kinds = [_]sections.TypeKind{ .structdef, .arraydef, .func };
const empty_fields = [_]sections.StructFieldType{};
const struct_defs = [_]?sections.StructDef{ .{ .fields = &empty_fields }, null, null };
const array_defs = [_]?sections.ArrayDef{ null, .{ .element = .{ .storage = .{ .val = .i32 }, .mutable = false } }, null };
const items = [_]FuncType{ .{ .params = &.{}, .results = &.{} }, .{ .params = &.{}, .results = &.{} }, .{ .params = &.{}, .results = &.{} } };

/// Validate `body` as a function taking one `param` and returning nothing,
/// with the three typedefs above in scope.
fn check(param: ValType, body: []const u8) Error!void {
    const params = [_]ValType{param};
    const sig: FuncType = .{ .params = &params, .results = &.{} };
    return validator.validateFunctionWithGcTypes(sig, &.{}, body, &.{}, &.{}, &items, &kinds, &struct_defs, &array_defs, 0, &.{}, 0);
}

test "validate: throw_ref takes an exnref (#322)" {
    //   local.get 0 ; throw_ref ; end
    const body = [_]u8{ 0x20, 0x00, 0x0A, 0x0B };
    try testing.expectError(Error.StackTypeMismatch, check(ValType.externref, &body));
    try testing.expectError(Error.StackTypeMismatch, check(ValType.anyref, &body));
    try check(abs(.exn, false), &body);
    try check(abs(.noexn, true), &body);
}

test "validate: ref.test takes a reference in its target's hierarchy (#322)" {
    //   local.get 0 ; ref.test (ref i31) ; drop ; end
    const body_i31 = [_]u8{ 0x20, 0x00, 0xFB, 0x14, 0x6C, 0x1A, 0x0B };
    try testing.expectError(Error.StackTypeMismatch, check(ValType.funcref, &body_i31));
    try testing.expectError(Error.StackTypeMismatch, check(ValType.externref, &body_i31));
    try check(abs(.eq, false), &body_i31);
    try check(conc(0, true), &body_i31); // a struct is in the any hierarchy
    //   local.get 0 ; ref.test (ref $f) ; drop ; end — a func typedef's
    //   hierarchy is func.
    const body_f = [_]u8{ 0x20, 0x00, 0xFB, 0x14, 0x02, 0x1A, 0x0B };
    try testing.expectError(Error.StackTypeMismatch, check(ValType.anyref, &body_f));
    try check(abs(.nofunc, true), &body_f);
}

test "validate: ref.cast takes a reference in its target's hierarchy (#322)" {
    //   local.get 0 ; ref.cast (ref null i31) ; drop ; end
    const body_i31 = [_]u8{ 0x20, 0x00, 0xFB, 0x17, 0x6C, 0x1A, 0x0B };
    try testing.expectError(Error.StackTypeMismatch, check(ValType.funcref, &body_i31));
    try check(abs(.struct_, false), &body_i31);
    //   local.get 0 ; ref.cast (ref $s) ; drop ; end — a struct typedef's
    //   hierarchy is any.
    const body_s = [_]u8{ 0x20, 0x00, 0xFB, 0x16, 0x00, 0x1A, 0x0B };
    try testing.expectError(Error.StackTypeMismatch, check(ValType.externref, &body_s));
    try check(conc(1, false), &body_s);
}

test "validate: array.len takes an arrayref (#322)" {
    //   local.get 0 ; array.len ; drop ; end
    const body = [_]u8{ 0x20, 0x00, 0xFB, 0x0F, 0x1A, 0x0B };
    try testing.expectError(Error.StackTypeMismatch, check(ValType.funcref, &body));
    try testing.expectError(Error.StackTypeMismatch, check(abs(.struct_, true), &body));
    try check(conc(1, false), &body);
    try check(abs(.none, true), &body);
}

test "validate: br_on_cast and br_on_cast_fail take a subtype of rt1 (#322)" {
    //   block (result (ref null i31))
    //     local.get 0 ; br_on_cast 0 anyref (ref null i31) ; drop
    //     ref.null i31
    //   end ; drop ; end
    const body = [_]u8{ 0x02, 0x63, 0x6C, 0x20, 0x00, 0xFB, 0x18, 0x03, 0x00, 0x6E, 0x6C, 0x1A, 0xD0, 0x6C, 0x0B, 0x1A, 0x0B };
    try testing.expectError(Error.StackTypeMismatch, check(ValType.funcref, &body));
    try check(abs(.eq, false), &body);
    try check(conc(0, true), &body);
    //   block (result anyref)
    //     local.get 0 ; br_on_cast_fail 0 anyref (ref null i31) ; drop
    //     ref.null any
    //   end ; drop ; end
    const body_fail = [_]u8{ 0x02, 0x6E, 0x20, 0x00, 0xFB, 0x19, 0x03, 0x00, 0x6E, 0x6C, 0x1A, 0xD0, 0x6E, 0x0B, 0x1A, 0x0B };
    try testing.expectError(Error.StackTypeMismatch, check(ValType.externref, &body_fail));
    try check(abs(.i31, false), &body_fail);
}

test "validate: i31.get_s and i31.get_u take an i31ref (#322)" {
    //   local.get 0 ; i31.get_s ; drop ; end   (and i31.get_u)
    const body_s = [_]u8{ 0x20, 0x00, 0xFB, 0x1D, 0x1A, 0x0B };
    const body_u = [_]u8{ 0x20, 0x00, 0xFB, 0x1E, 0x1A, 0x0B };
    try testing.expectError(Error.StackTypeMismatch, check(ValType.externref, &body_s));
    try testing.expectError(Error.StackTypeMismatch, check(abs(.eq, true), &body_u));
    try check(abs(.i31, false), &body_s);
    try check(abs(.none, true), &body_u);
}

test "validate: a cast's operand in an unreachable region stays polymorphic (#322)" {
    //   unreachable ; ref.cast (ref i31) ; drop ; unreachable ; array.len ;
    //   drop ; unreachable ; throw_ref ; end
    const body = [_]u8{ 0x00, 0xFB, 0x16, 0x6C, 0x1A, 0x00, 0xFB, 0x0F, 0x1A, 0x00, 0x0A, 0x0B };
    try check(ValType.i32, &body);
}
