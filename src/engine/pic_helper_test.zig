//! ADR-0203 D1 (D-516) — position-independence of emitted code: the JIT
//! body must reach Zig helpers through `JitRuntime` fn-pointer fields
//! (`[rt + off]` loads, the `memory_grow_fn` pattern), never via imm64
//! addresses baked at compile time. Interposition proof: swapping the
//! field on a live instance must reroute the very next executed op — a
//! baked address ignores the swap (and dies under per-exec ASLR when a
//! `.cwasm` compiled by another process is loaded: the D-516 crash class,
//! pinned cross-process by `test/aot/aot_process_diff.zig`).
//! Discovered by the unit-test loader via `src/zwasm.zig`'s `test {}`.

const std = @import("std");
const testing = std.testing;

const runner = @import("runner.zig");
const JitInstance = runner.JitInstance;
const jit_abi = @import("codegen/shared/jit_abi.zig");

var interposed_gc_alloc_calls: u32 = 0;

fn countingGcAlloc(rt: *jit_abi.JitRuntime, typeidx: u32) callconv(.c) u32 {
    interposed_gc_alloc_calls += 1;
    return jit_abi.jitGcAlloc(rt, typeidx);
}

test "JIT struct.new_default reaches jitGcAlloc via the rt field, not a baked address (ADR-0203 D1)" {
    // (module (type (struct (field (mut i32))))
    //   (func (export "f") (result i32) struct.new_default 0  ref.is_null))
    // — the runner_gc_test A-2b-1 module (hand-encoded; wat2wasm predates GC).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x09, 0x02, 0x5f, 0x01, 0x7f, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07,
        0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a, 0x08,
        0x01, 0x06, 0x00, 0xfb, 0x01, 0x00, 0xd1, 0x0b,
    };
    var jit = try JitInstance.init(testing.allocator, &bytes);
    defer jit.deinit(testing.allocator);

    interposed_gc_alloc_calls = 0;
    jit.owned.rt.gc_alloc_fn = countingGcAlloc;

    const r = try jit.invoke(testing.allocator, "f", &.{});
    try testing.expectEqual(@as(?u64, 0), r); // fresh struct is non-null → 0
    // The emitted struct.new_default must have gone through the swapped
    // field — 0 here means the code called a compile-time-baked address.
    try testing.expect(interposed_gc_alloc_calls > 0);
}

fn helperSlotDefault(comptime field_name: []const u8) @FieldType(jit_abi.JitRuntime, field_name) {
    const ti = @typeInfo(jit_abi.JitRuntime).@"struct";
    inline for (ti.field_names, ti.field_attrs) |f_name, f_attrs| {
        if (comptime std.mem.eql(u8, f_name, field_name)) {
            const dv: *const @FieldType(jit_abi.JitRuntime, field_name) =
                @ptrCast(@alignCast(f_attrs.default_value_ptr.?));
            return dv.*;
        }
    }
    unreachable;
}

test "JitRuntime helper-slot defaults point at the real helpers, all 14 (ADR-0203 D1)" {
    // The defaults resolve in THIS process (ordinary binary relocation), so
    // any JitRuntime — including one rebuilt by a future `.cwasm` loader —
    // is correct without setup wiring. Exhaustive over every de-baked slot
    // so a future field whose default drifts off its helper is caught.
    try testing.expectEqual(&jit_abi.jitCallIndirectResolve, helperSlotDefault("call_indirect_resolve_fn"));
    try testing.expectEqual(&jit_abi.jitGcAlloc, helperSlotDefault("gc_alloc_fn"));
    try testing.expectEqual(&jit_abi.jitGcAllocArray, helperSlotDefault("gc_alloc_array_fn"));
    try testing.expectEqual(&jit_abi.jitGcAllocArrayFill, helperSlotDefault("gc_alloc_array_fill_fn"));
    try testing.expectEqual(&jit_abi.jitGcArrayFill, helperSlotDefault("gc_array_fill_fn"));
    try testing.expectEqual(&jit_abi.jitGcArrayCopy, helperSlotDefault("gc_array_copy_fn"));
    try testing.expectEqual(&jit_abi.jitGcArrayNewData, helperSlotDefault("gc_array_new_data_fn"));
    try testing.expectEqual(&jit_abi.jitGcArrayNewElem, helperSlotDefault("gc_array_new_elem_fn"));
    try testing.expectEqual(&jit_abi.jitGcArrayInitData, helperSlotDefault("gc_array_init_data_fn"));
    try testing.expectEqual(&jit_abi.jitGcArrayInitElem, helperSlotDefault("gc_array_init_elem_fn"));
    try testing.expectEqual(&jit_abi.jitGcRefTest, helperSlotDefault("gc_ref_test_fn"));
    try testing.expectEqual(&jit_abi.jitGcRefCast, helperSlotDefault("gc_ref_cast_fn"));
    try testing.expectEqual(&jit_abi.rethrowFromExnref, helperSlotDefault("rethrow_exnref_fn"));
    try testing.expectEqual(&@import("codegen/shared/throw_trampoline.zig").zwasmThrowTrampoline, helperSlotDefault("throw_trampoline_fn"));
}

var interposed_gc_alloc_array_calls: u32 = 0;

fn countingGcAllocArray(rt: *jit_abi.JitRuntime, typeidx: u32, length: u32) callconv(.c) u32 {
    interposed_gc_alloc_array_calls += 1;
    return jit_abi.jitGcAllocArray(rt, typeidx, length);
}

test "JIT array.new_default reaches jitGcAllocArray via the rt field (ADR-0203 D1)" {
    // (module (type (array (mut i32)))
    //   (func (export "f") (result i32)
    //     i32.const 3  array.new_default 0  array.len))
    // Second interposition family (alloc-array) — with the slot-defaults
    // test above, a re-bake regression on any GC-alloc-family slot is
    // caught by one of the two nets. array.new_default = fb 07; array.len
    // = fb 0f. Hand-encoded (wat2wasm predates GC).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=array{i32 mut} (5e 7f 01), [1]=func ()->(i32)
        0x01, 0x08, 0x02, 0x5e, 0x7f, 0x01, 0x60, 0x00,
        0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07, 0x05,
        0x01, 0x01, 0x66, 0x00, 0x00,
        // body: i32.const 3 [41 03], array.new_default 0 [fb 07 00],
        // array.len [fb 0f], end — 8 bytes + locals byte.
        0x0a, 0x0b, 0x01,
        0x09, 0x00, 0x41, 0x03, 0xfb, 0x07, 0x00, 0xfb,
        0x0f, 0x0b,
    };
    var jit = try JitInstance.init(testing.allocator, &bytes);
    defer jit.deinit(testing.allocator);

    interposed_gc_alloc_array_calls = 0;
    jit.owned.rt.gc_alloc_array_fn = countingGcAllocArray;

    const r = try jit.invoke(testing.allocator, "f", &.{});
    try testing.expectEqual(@as(?u64, 3), r); // array.len of the 3-elem array
    try testing.expect(interposed_gc_alloc_array_calls > 0);
}
