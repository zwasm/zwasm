//! Runtime ⇄ native-facade `Value` conversion (ADR-0109). Shared by
//! `instance.zig` (invoke arg/result marshalling) and `global.zig`
//! (Global get/set) so the ref heap-type mapping (ADR-0115/0116) lives
//! in exactly one place rather than being duplicated per accessor.

const _runtime_value = @import("../runtime/value.zig");
const _zir = @import("../ir/zir.zig");
const _zwasm = @import("../zwasm.zig");

pub fn zwasmToRuntime(v: _zwasm.Value) _runtime_value.Value {
    return switch (v) {
        .i32 => |x| _runtime_value.Value.fromI32(x),
        .i64 => |x| _runtime_value.Value.fromI64(x),
        .f32 => |b| _runtime_value.Value.fromF32Bits(b),
        .f64 => |b| _runtime_value.Value.fromF64Bits(b),
        .v128 => |b| .{ .bits128 = b },
        .funcref => |r| _runtime_value.Value.fromRef(r orelse 0),
        .externref => |r| _runtime_value.Value.fromRef(r orelse 0),
    };
}

pub fn runtimeToZwasm(v: _runtime_value.Value, vt: _zir.ValType) _zwasm.Value {
    return switch (vt) {
        .i32 => .{ .i32 = v.i32 },
        .i64 => .{ .i64 = v.i64 },
        .f32 => .{ .f32 = @truncate(v.bits64) },
        .f64 => .{ .f64 = v.bits64 },
        .v128 => .{ .v128 = v.bits128 },
        // ADR-0123 Cycle 2: ValType pivoted to union(enum). Map
        // each ref-shape to the native facade's Value variant.
        // Per ADR-0115 §6 / ADR-0116, non-func abstract heads + all
        // concrete typed refs marshal as `.externref` (host opaque
        // u64 ref); only func head gets the `.funcref` variant for
        // call_ref / table.set marshalling.
        .ref => |r| switch (r.heap_type) {
            .abstract => |a| if (a == .func)
                .{ .funcref = if (v.ref == 0) null else v.ref }
            else
                .{ .externref = if (v.ref == 0) null else v.ref },
            .concrete => .{ .externref = if (v.ref == 0) null else v.ref },
        },
    };
}
