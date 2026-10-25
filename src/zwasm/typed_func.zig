//! `TypedFunc(comptime Sig: type)` — comptime-marshal factory per
//! ADR-0109 §3.1 + `docs/zig_api_design.md` §3.1.
//!
//! Takes a Zig function type (`fn(i32, i32) i32`,
//! `fn(i32, i32) struct { i32, i32 }`, etc.) and emits a wrapper
//! whose `.call(args_tuple)` marshals the Zig argument tuple
//! through the host-boundary `Value` slice, drives
//! `Instance.invoke`, and marshals the result tuple back. NaN
//! payloads are preserved bit-exact per ADR-0109 §3.6 (no
//! canonicalisation at the boundary).
//!
//! v0.1 supported scalars: i32 / i64 / f32 / f64. Reference types
//! (funcref / externref) + v128 land at J.5 alongside Linker work.

const std = @import("std");

const _zwasm = @import("../zwasm.zig");
const Value = _zwasm.Value;

/// Builds the wrapper type for a given function signature.
pub fn TypedFunc(comptime Sig: type) type {
    const fn_info = @typeInfo(Sig).@"fn";
    const ArgsT = std.meta.ArgsTuple(Sig);
    const Ret = fn_info.return_type orelse @compileError("TypedFunc: signature must declare a return type (use void for no result)");

    return struct {
        instance: *_zwasm.Instance,
        export_name: []const u8,

        const Self = @This();

        pub fn call(self: Self, args: ArgsT) _zwasm.Instance.InvokeError!Ret {
            var arg_values: [fn_info.param_types.len]Value = undefined;
            inline for (fn_info.param_types, 0..) |p_type, i| {
                const PT = p_type orelse @compileError("TypedFunc: anytype params not supported");
                arg_values[i] = zigToValue(PT, args[i]);
            }

            const result_count = comptime resultCount(Ret);
            var result_values: [result_count]Value = undefined;

            try self.instance.invoke(self.export_name, arg_values[0..], result_values[0..]);

            return marshalResult(Ret, &result_values);
        }
    };
}

fn resultCount(comptime Ret: type) comptime_int {
    if (Ret == void) return 0;
    return switch (@typeInfo(Ret)) {
        .@"struct" => |s| s.field_names.len,
        else => 1,
    };
}

fn zigToValue(comptime T: type, v: T) Value {
    return switch (T) {
        i32 => Value.fromI32(v),
        u32 => Value.fromI32(@bitCast(v)),
        i64 => Value.fromI64(v),
        u64 => Value.fromI64(@bitCast(v)),
        f32 => Value.fromF32Bits(@bitCast(v)),
        f64 => Value.fromF64Bits(@bitCast(v)),
        else => @compileError("TypedFunc: unsupported param type " ++ @typeName(T)),
    };
}

fn marshalResult(comptime Ret: type, results: anytype) Ret {
    if (Ret == void) return;
    switch (@typeInfo(Ret)) {
        .@"struct" => |s| {
            var out: Ret = undefined;
            inline for (s.field_names, s.field_types, 0..) |f_name, f_type, i| {
                @field(out, f_name) = valueToZig(f_type, results[i]);
            }
            return out;
        },
        else => return valueToZig(Ret, results[0]),
    }
}

fn valueToZig(comptime T: type, v: Value) T {
    return switch (T) {
        i32 => v.i32,
        u32 => @bitCast(v.i32),
        i64 => v.i64,
        u64 => @bitCast(v.i64),
        // `Value.f32` carries the IEEE-754 bit pattern as u32 to keep
        // signaling-NaN bits intact across the host boundary.
        f32 => @bitCast(v.f32),
        f64 => @bitCast(v.f64),
        else => @compileError("TypedFunc: unsupported result type " ++ @typeName(T)),
    };
}
