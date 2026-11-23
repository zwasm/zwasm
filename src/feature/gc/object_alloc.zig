//! Shared GC object allocation (10.G GC-on-JIT, ADR-0128 §2).
//!
//! The allocate + `ObjectHeader`-stamp + optional zero-init step,
//! factored out of the interp `instruction/wasm_3_0/struct_ops.zig`
//! so the JIT alloc trampoline (10.G cycle A-2 per
//! `.dev/phase10_g_op_bundle_plan.md`) can call the SAME logic
//! instead of re-deriving it. The caller resolves the `StructInfo`
//! (it owns the typeidx → payload_size lookup); this fn does the
//! heap mechanics only, so it depends on neither `Runtime` nor
//! `GcTypeInfos` and is callable from both Zones.
//!
//! Zone 1 (`src/feature/gc/`).

const std = @import("std");

const heap_mod = @import("heap.zig");
const type_info = @import("type_info.zig");

const Heap = heap_mod.Heap;
const ObjectHeader = type_info.ObjectHeader;
const header_size: u32 = @sizeOf(ObjectHeader);
const ArrayHeader = type_info.ArrayHeader;
const array_header_size: u32 = @sizeOf(ArrayHeader);

/// Allocate `header_size + payload_size` bytes on the GC slab, stamp
/// the `ObjectHeader` (`.struct_` kind + `typeidx` in `info`), and —
/// when `zero_init` — zero the payload. Returns the `GcRef` (u32 slab
/// offset). Propagates `Heap.allocate`'s error on OOM.
///
/// Wasm spec 3.0 §3.3.13 (struct.new / struct.new_default): the
/// object is `header_size`-prefixed; `struct.new` overwrites the
/// payload with field values (so it passes `zero_init = false`),
/// `struct.new_default` keeps the zeroed payload.
pub fn allocStructObject(heap: *Heap, typeidx: u32, payload_size: u32, zero_init: bool) Heap.Error!u32 {
    const total: u32 = header_size + payload_size;
    const ref = try heap.allocate(total);
    const header: ObjectHeader = .{ .kind = .struct_, .info = typeidx };
    @memcpy(heap.bytes[ref .. ref + header_size], std.mem.asBytes(&header));
    if (zero_init) @memset(heap.bytes[ref + header_size .. ref + total], 0);
    return ref;
}

/// Allocate `array_header_size + length*element_size` bytes on the GC
/// slab, stamp the `ArrayHeader` (`.array` kind + `typeidx` in `info` +
/// `length`), and — when `zero_init` — zero the payload. Returns the
/// `GcRef`. The SAME mechanics the interp `array_ops.zig` allocateArray
/// uses, so the JIT `jitGcAllocArray` trampoline can share it (10.G
/// GC-on-JIT array A-1). Unlike struct allocation, the total size
/// depends on the runtime `length`, so the caller passes it in.
///
/// Wasm spec 3.0 §3.3.13 (array.new_default keeps the zeroed payload;
/// array.new / array.new_fixed overwrite it, passing `zero_init = false`).
pub fn allocArrayObject(heap: *Heap, typeidx: u32, length: u32, element_size: u8, zero_init: bool) Heap.Error!u32 {
    // u64 size arithmetic: a huge array.new* length overflows the u32
    // product before Heap.allocate's 4 GiB cap fires — trap OutOfHeap
    // ("allocation size too large") instead of panicking (wasmtime
    // gc/array-alloc-too-large). Mirrors interp array_ops.allocateArray.
    const total_u64: u64 = @as(u64, array_header_size) + @as(u64, length) * @as(u64, element_size);
    if (total_u64 > std.math.maxInt(u32)) return Heap.Error.OutOfHeap;
    const total: u32 = @intCast(total_u64);
    const ref = try heap.allocate(total);
    const header: ArrayHeader = .{ .header = .{ .kind = .array, .info = typeidx }, .length = length };
    @memcpy(heap.bytes[ref .. ref + array_header_size], std.mem.asBytes(&header)[0..array_header_size]);
    if (zero_init) @memset(heap.bytes[ref + array_header_size .. ref + total], 0);
    return ref;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "allocStructObject: stamps struct_ header + zero-inits payload over poison" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var heap = Heap.init(arena.allocator(), testing.allocator);
    // Grow the slab, then poison the whole buffer so the zero-init
    // has something non-zero to overwrite (newly-grown pages are
    // already zero, which would not exercise the @memset).
    _ = try heap.allocate(64);
    @memset(heap.bytes, 0xAA);

    const ref = try allocStructObject(&heap, 7, 8, true);
    try testing.expect(ref >= 2);

    var hdr: ObjectHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr)[0..header_size], heap.bytes[ref .. ref + header_size]);
    try testing.expectEqual(type_info.ObjectKind.struct_, hdr.kind);
    try testing.expectEqual(@as(u32, 7), hdr.info);

    var payload: u64 = undefined;
    @memcpy(std.mem.asBytes(&payload), heap.bytes[ref + header_size .. ref + header_size + 8]);
    try testing.expectEqual(@as(u64, 0), payload);
}

test "allocArrayObject: stamps array header (kind+typeidx+length) + zero-inits payload over poison" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var heap = Heap.init(arena.allocator(), testing.allocator);
    _ = try heap.allocate(128);
    @memset(heap.bytes, 0xAA);

    // 3 elements × 8-byte slot (slot_size this cut). zero_init = true
    // (array.new_default path).
    const ref = try allocArrayObject(&heap, 5, 3, 8, true);
    try testing.expect(ref >= 2);

    var hdr: ArrayHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr)[0..array_header_size], heap.bytes[ref .. ref + array_header_size]);
    try testing.expectEqual(type_info.ObjectKind.array, hdr.header.kind);
    try testing.expectEqual(@as(u32, 5), hdr.header.info);
    try testing.expectEqual(@as(u32, 3), hdr.length);

    // All 3 element slots zero-inited (over the 0xAA poison).
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const off = ref + array_header_size + i * 8;
        var slot: u64 = undefined;
        @memcpy(std.mem.asBytes(&slot), heap.bytes[off .. off + 8]);
        try testing.expectEqual(@as(u64, 0), slot);
    }
}

test "allocStructObject: zero_init=false leaves payload untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var heap = Heap.init(arena.allocator(), testing.allocator);
    _ = try heap.allocate(64);
    @memset(heap.bytes, 0xAA);

    const ref = try allocStructObject(&heap, 0, 8, false);
    // Payload keeps the poison bytes (struct.new overwrites them with
    // real field values; the alloc step itself must not zero).
    var payload: u64 = undefined;
    @memcpy(std.mem.asBytes(&payload), heap.bytes[ref + header_size .. ref + header_size + 8]);
    try testing.expectEqual(@as(u64, 0xAAAA_AAAA_AAAA_AAAA), payload);
    // Header is still stamped.
    var hdr: ObjectHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr)[0..header_size], heap.bytes[ref .. ref + header_size]);
    try testing.expectEqual(type_info.ObjectKind.struct_, hdr.kind);
}
