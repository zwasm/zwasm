//! Wasm 3.0 GC array allocation + element access interp handlers
//! (10.G op_gc cycle 24+ per `.dev/phase10_g_op_bundle_plan.md`).
//!
//! Mirrors `struct_ops.zig` (cycle 22-23) for the array catalogue:
//! consumes the cycle-21 Instance.gc_type_infos.array_infos[typeidx]
//! + the cycle-3 GC Heap slab, writes ArrayHeader (ObjectHeader +
//! length slot per ADR-0116 §3a) at offset 0, then N * element.size
//! bytes of payload.
//!
//! Encoding:
//!   - `array.new typeidx`         (0xFB 0x06): pop init + i32 size,
//!                                              allocate, fill N copies.
//!   - `array.new_default typeidx` (0xFB 0x07): pop i32 size, alloc,
//!                                              zero-init payload.
//!   - `array.new_fixed typeidx N` (0xFB 0x08): pop N values (reverse),
//!                                              alloc, fill.
//!
//! Push shape: GcRef as `.ref = @as(u64, ref_u32)` (same as struct_ops).
//!
//! Zone 1 (`src/instruction/`).

const std = @import("std");

const dispatch = @import("../../ir/dispatch_table.zig");
const zir = @import("../../ir/zir.zig");
const runtime = @import("../../runtime/runtime.zig");
const type_info_mod = @import("../../feature/gc/type_info.zig");
const root_scope = @import("../../feature/gc/root_scope.zig");
const object_alloc = @import("../../feature/gc/object_alloc.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const InterpCtx = dispatch.InterpCtx;
const Runtime = runtime.Runtime;
const Value = runtime.Value;
const Instance = runtime.Instance;

const ObjectHeader = type_info_mod.ObjectHeader;
const ObjectKind = type_info_mod.ObjectKind;
const ArrayHeader = type_info_mod.ArrayHeader;
const ArrayInfo = type_info_mod.ArrayInfo;
const array_header_size: u32 = @sizeOf(ArrayHeader);

inline fn op(o: ZirOp) usize {
    return @backingInt(o);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"array.new")] = arrayNew;
    table.interp[op(.@"array.new_default")] = arrayNewDefault;
    table.interp[op(.@"array.new_fixed")] = arrayNewFixed;
    table.interp[op(.@"array.new_data")] = arrayNewData;
    table.interp[op(.@"array.new_elem")] = arrayNewElem;
    table.interp[op(.@"array.get")] = arrayGet;
    table.interp[op(.@"array.get_s")] = arrayGetS;
    table.interp[op(.@"array.get_u")] = arrayGetU;
    table.interp[op(.@"array.set")] = arraySet;
    table.interp[op(.@"array.fill")] = arrayFill;
    table.interp[op(.@"array.copy")] = arrayCopy;
    table.interp[op(.@"array.init_data")] = arrayInitData;
    table.interp[op(.@"array.init_elem")] = arrayInitElem;
    // array.len: cycle-12 stub in ref_convert_ops.zig is now
    // overridden by the real impl reading ArrayHeader.length.
    table.interp[op(.@"array.len")] = arrayLen;
}

fn resolveArrayInfo(inst: *const Instance, typeidx: u32) anyerror!ArrayInfo {
    const gti = inst.gc_type_infos orelse return runtime.Trap.NullReference;
    if (typeidx >= gti.array_infos.len) return runtime.Trap.NullReference;
    return gti.array_infos[typeidx] orelse runtime.Trap.NullReference;
}

/// Allocate an array of `length` elements on the GC heap; write
/// ArrayHeader at offset 0. Returns the 32-bit GcRef.
fn allocateArray(rt: *Runtime, typeidx: u32, length: u32, element_size: u8) anyerror!u32 {
    const heap = rt.gc_heap orelse return runtime.Trap.NullReference;
    // §15.1 chunk 1c (ADR-0146): drive a collection under heap pressure
    // before bump-allocating. Interp path only (JIT trampoline = D-258).
    if (rt.instance) |inst_opaque| {
        const inst = @as(*const runtime.Instance, @ptrCast(@alignCast(inst_opaque)));
        if (inst.gc_type_infos) |*gti| root_scope.maybeCollect(heap, gti, rt);
    }
    // D-455: delegate the size arithmetic (u64 overflow guard → OutOfHeap),
    // slab allocation, and ArrayHeader stamp to the shared `object_alloc`
    // helper — one allocator, one size-arithmetic site (mirrors struct_ops
    // delegating to allocStructObject). `zero_init = false`: every interp
    // caller overwrites the payload (new_default @memsets; new/new_fixed/
    // new_data/new_elem copy values). Interp-only maybeCollect stays above
    // (the JIT trampoline drives its own collection).
    return object_alloc.allocArrayObject(heap, typeidx, length, element_size, false);
}

fn arrayNew(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const ai = try resolveArrayInfo(inst, typeidx);
    // Stack top: size:i32; under it: init value.
    const size_val = rt.popOperand();
    const size_i32 = size_val.i32;
    if (size_i32 < 0) return runtime.Trap.OutOfBoundsStore;
    const length: u32 = @intCast(size_i32);
    const init_val = rt.popOperand();
    const ref = try allocateArray(rt, typeidx, length, ai.element.size);
    const heap = rt.gc_heap.?;
    var i: u32 = 0;
    while (i < length) : (i += 1) {
        const dst_off = ref + array_header_size + i * ai.element.size;
        const dst = heap.bytes[dst_off .. dst_off + ai.element.size];
        @memcpy(dst, std.mem.asBytes(&init_val)[0..ai.element.size]);
    }
    try rt.pushOperand(.{ .ref = @as(u64, ref) });
}

fn arrayNewDefault(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const ai = try resolveArrayInfo(inst, typeidx);
    const size_val = rt.popOperand();
    const size_i32 = size_val.i32;
    if (size_i32 < 0) return runtime.Trap.OutOfBoundsStore;
    const length: u32 = @intCast(size_i32);
    const ref = try allocateArray(rt, typeidx, length, ai.element.size);
    const heap = rt.gc_heap.?;
    const payload_start = ref + array_header_size;
    const payload_end = payload_start + length * @as(u32, ai.element.size);
    @memset(heap.bytes[payload_start..payload_end], 0);
    try rt.pushOperand(.{ .ref = @as(u64, ref) });
}

fn arrayNewFixed(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const ai = try resolveArrayInfo(inst, typeidx);
    const length: u32 = instr.extra;
    const ref = try allocateArray(rt, typeidx, length, ai.element.size);
    const heap = rt.gc_heap.?;
    // Pop N values in reverse: stack top = last element.
    var i: u32 = length;
    while (i > 0) {
        i -= 1;
        const v = rt.popOperand();
        const dst_off = ref + array_header_size + i * ai.element.size;
        const dst = heap.bytes[dst_off .. dst_off + ai.element.size];
        @memcpy(dst, std.mem.asBytes(&v)[0..ai.element.size]);
    }
    try rt.pushOperand(.{ .ref = @as(u64, ref) });
}

/// Wasm 3.0 GC §3.3.5.6.7 — `array.new_data $t $d`: pop [offset:i32,
/// size:i32], build a `size`-element array of $t whose payload is the
/// raw bytes copied from data segment $d at byte `offset` (element
/// slots are packed `element.size` bytes — the segment layout matches).
/// Trap OutOfBoundsLoad if offset + size*element.size exceeds the
/// segment length; the validator enforced $t is arraydef + $d in range.
fn arrayNewData(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const dataidx: u32 = instr.extra;
    const ai = try resolveArrayInfo(inst, typeidx);
    const size_i32 = rt.popOperand().i32;
    const offset_i32 = rt.popOperand().i32;
    if (size_i32 < 0 or offset_i32 < 0) return runtime.Trap.OutOfBoundsLoad;
    const size: u32 = @intCast(size_i32);
    const offset: u64 = @intCast(offset_i32);
    if (dataidx >= rt.datas.len) return runtime.Trap.OutOfBoundsLoad;
    const seg: []const u8 = if (dataidx < rt.data_dropped.len and rt.data_dropped[dataidx]) &.{} else rt.datas[dataidx];
    // The data segment holds NATURAL-size elements (i32=4, i8=1, …); the
    // array slot is the uniform 8-byte slot. Read `nat` bytes per element
    // (little-endian, zero-extended) into the slot.
    const nat = dataElemNaturalSize(ai.element.valtype_byte) orelse return runtime.Trap.NullReference;
    const byte_len: u64 = @as(u64, size) * nat;
    if (offset + byte_len > seg.len) return runtime.Trap.OutOfBoundsLoad;
    const ref = try allocateArray(rt, typeidx, size, ai.element.size);
    const heap = rt.gc_heap.?;
    const off_lo: usize = @intCast(offset);
    var i: u32 = 0;
    while (i < size) : (i += 1) {
        // D-493: zero the slot then copy `nat` natural bytes — handles every
        // element width incl. v128 (nat=16). The prior u64-pack loop overflowed
        // its shift for nat=16; a direct memcpy zero-extends scalars (nat<slot)
        // and copies v128 in full (nat==slot==16).
        const src = off_lo + i * nat;
        const dst_off = ref + array_header_size + i * ai.element.size;
        const slot = heap.bytes[dst_off .. dst_off + ai.element.size];
        @memset(slot, 0);
        @memcpy(slot[0..nat], seg[src .. src + nat]);
    }
    try rt.pushOperand(.{ .ref = @as(u64, ref) });
}

/// Natural (packed) byte width of an array element for array.new_data,
/// from its Wasm valtype byte: i8=1, i16=2, i32/f32=4, i64/f64=8.
/// Reftypes (which can't be initialised from raw data bytes) → null.
fn dataElemNaturalSize(valtype_byte: u8) ?u8 {
    return switch (valtype_byte) {
        0x78 => 1, // i8 (packed)
        0x77 => 2, // i16 (packed)
        0x7F, 0x7D => 4, // i32, f32
        0x7E, 0x7C => 8, // i64, f64
        0x7B => 16, // v128 (vectype packs into 16 data bytes; D-493)
        else => null,
    };
}

/// Wasm 3.0 GC §3.3.5.6.8 — `array.new_elem $t $e`: pop [offset:i32,
/// size:i32], build a `size`-element array of $t whose elements are the
/// `size` ref Values copied from element segment $e starting at
/// `offset`. Trap OutOfBoundsLoad if offset + size exceeds the segment.
fn arrayNewElem(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const elemidx: u32 = instr.extra;
    const ai = try resolveArrayInfo(inst, typeidx);
    const size_i32 = rt.popOperand().i32;
    const offset_i32 = rt.popOperand().i32;
    if (size_i32 < 0 or offset_i32 < 0) return runtime.Trap.OutOfBoundsLoad;
    const size: u32 = @intCast(size_i32);
    const offset: u32 = @intCast(offset_i32);
    if (elemidx >= rt.elems.len) return runtime.Trap.OutOfBoundsLoad;
    const seg: []const Value = if (elemidx < rt.elem_dropped.len and rt.elem_dropped[elemidx]) &.{} else rt.elems[elemidx];
    if (@as(u64, offset) + @as(u64, size) > seg.len) return runtime.Trap.OutOfBoundsLoad;
    const ref = try allocateArray(rt, typeidx, size, ai.element.size);
    const heap = rt.gc_heap.?;
    var i: u32 = 0;
    while (i < size) : (i += 1) {
        const v = seg[offset + i];
        const dst_off = ref + array_header_size + i * ai.element.size;
        @memcpy(heap.bytes[dst_off .. dst_off + ai.element.size], std.mem.asBytes(&v)[0..ai.element.size]);
    }
    try rt.pushOperand(.{ .ref = @as(u64, ref) });
}

/// Read ArrayHeader at offset 0 of the GC object; caller has
/// already validated GcRef is non-null. Returns the length slot
/// for bounds-check use; the kind field is implicitly trusted
/// (validator narrowed the operand type to arrayref-class).
fn readArrayHeader(heap: anytype, ref: u32) ArrayHeader {
    var hdr: ArrayHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr)[0..array_header_size], heap.bytes[ref .. ref + array_header_size]);
    return hdr;
}

/// Wasm 3.0 GC §3.3.5.6.10 — `array.get typeidx`: pop i32 idx +
/// GcRef (trap null), bounds-check against ArrayHeader.length,
/// read 8-byte element slot, push Value (validator-narrowed
/// declared element type tells consumer which union arm is live).
fn arrayGet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const ai = try resolveArrayInfo(inst, typeidx);
    const idx_val = rt.popOperand();
    const idx_i32 = idx_val.i32;
    const ref_val = rt.popOperand();
    if (ref_val.ref == Value.null_ref) return runtime.Trap.NullReference;
    const ref: u32 = @intCast(ref_val.ref);
    const heap = rt.gc_heap orelse return runtime.Trap.NullReference;
    const hdr = readArrayHeader(heap, ref);
    if (idx_i32 < 0 or @as(u32, @intCast(idx_i32)) >= hdr.length) {
        return runtime.Trap.OutOfBoundsLoad;
    }
    const idx: u32 = @intCast(idx_i32);
    const src_off = ref + array_header_size + idx * ai.element.size;
    var v: Value = undefined;
    @memcpy(std.mem.asBytes(&v)[0..ai.element.size], heap.bytes[src_off .. src_off + ai.element.size]);
    try rt.pushOperand(v);
}

/// Wasm 3.0 GC §3.3.5.6.11 — `array.get_s` / `array.get_u typeidx`:
/// pop i32 idx + arrayref (trap null / OOB), read the packed (i8/i16)
/// element from its 8-byte slot, sign-/zero-extend to i32 (ADR-0125
/// B-exec). Validator restricts these to packed-element arrays.
fn arrayGetS(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    return arrayGetPacked(c, instr, true);
}
fn arrayGetU(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    return arrayGetPacked(c, instr, false);
}
fn arrayGetPacked(c: *InterpCtx, instr: *const ZirInstr, signed: bool) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const ai = try resolveArrayInfo(inst, typeidx);
    const idx_val = rt.popOperand();
    const idx_i32 = idx_val.i32;
    const ref_val = rt.popOperand();
    if (ref_val.ref == Value.null_ref) return runtime.Trap.NullReference;
    const ref: u32 = @intCast(ref_val.ref);
    const heap = rt.gc_heap orelse return runtime.Trap.NullReference;
    const hdr = readArrayHeader(heap, ref);
    if (idx_i32 < 0 or @as(u32, @intCast(idx_i32)) >= hdr.length) {
        return runtime.Trap.OutOfBoundsLoad;
    }
    const idx: u32 = @intCast(idx_i32);
    const src_off = ref + array_header_size + idx * ai.element.size;
    var v: Value = undefined;
    @memcpy(std.mem.asBytes(&v)[0..8], heap.bytes[src_off .. src_off + 8]);
    const ext = type_info_mod.extendPackedToI32(v.i32, ai.element.valtype_byte, signed) orelse return runtime.Trap.NullReference;
    try rt.pushOperand(.{ .i32 = ext });
}

/// Wasm 3.0 GC §3.3.5.6.12 — `array.set typeidx`: pop value +
/// i32 idx + GcRef (trap null), bounds-check, write element.
fn arraySet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const ai = try resolveArrayInfo(inst, typeidx);
    const v = rt.popOperand();
    const idx_val = rt.popOperand();
    const idx_i32 = idx_val.i32;
    const ref_val = rt.popOperand();
    if (ref_val.ref == Value.null_ref) return runtime.Trap.NullReference;
    const ref: u32 = @intCast(ref_val.ref);
    const heap = rt.gc_heap orelse return runtime.Trap.NullReference;
    const hdr = readArrayHeader(heap, ref);
    if (idx_i32 < 0 or @as(u32, @intCast(idx_i32)) >= hdr.length) {
        return runtime.Trap.OutOfBoundsStore;
    }
    const idx: u32 = @intCast(idx_i32);
    const dst_off = ref + array_header_size + idx * ai.element.size;
    const dst = heap.bytes[dst_off .. dst_off + ai.element.size];
    @memcpy(dst, std.mem.asBytes(&v)[0..ai.element.size]);
}

/// Wasm 3.0 GC §3.3.5.6.14 — `array.fill typeidx`: pop count +
/// value + i32 idx + GcRef (trap null), bounds-check
/// `idx + count ≤ length`, fill `count` slots with `value`.
fn arrayFill(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const ai = try resolveArrayInfo(inst, typeidx);
    const count_val = rt.popOperand();
    const v = rt.popOperand();
    const idx_val = rt.popOperand();
    const count_i32 = count_val.i32;
    const idx_i32 = idx_val.i32;
    const ref_val = rt.popOperand();
    if (ref_val.ref == Value.null_ref) return runtime.Trap.NullReference;
    const ref: u32 = @intCast(ref_val.ref);
    const heap = rt.gc_heap orelse return runtime.Trap.NullReference;
    const hdr = readArrayHeader(heap, ref);
    if (idx_i32 < 0 or count_i32 < 0) return runtime.Trap.OutOfBoundsStore;
    const idx: u32 = @intCast(idx_i32);
    const count: u32 = @intCast(count_i32);
    const end_widened = @addWithOverflow(idx, count);
    if (end_widened[1] != 0 or end_widened[0] > hdr.length) {
        return runtime.Trap.OutOfBoundsStore;
    }
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const dst_off = ref + array_header_size + (idx + i) * ai.element.size;
        const dst = heap.bytes[dst_off .. dst_off + ai.element.size];
        @memcpy(dst, std.mem.asBytes(&v)[0..ai.element.size]);
    }
}

/// Wasm 3.0 GC §3.3.5.6.14 — `array.copy dst_typeidx src_typeidx`: pop
/// [len:i32, src_off:i32, src_ref, dst_off:i32, dst_ref]; trap null /
/// OOB; copy `len` 8-byte slots src→dst (memmove semantics for overlap
/// within the same array). Slots are uniform 8 bytes (ADR-0116 §3a), so
/// element widths match regardless of dst/src declared element type.
fn arrayCopy(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const dst_ai = try resolveArrayInfo(inst, @intCast(instr.payload));
    const esz = dst_ai.element.size;
    const len_v = rt.popOperand();
    const src_off_v = rt.popOperand();
    const src_ref_v = rt.popOperand();
    const dst_off_v = rt.popOperand();
    const dst_ref_v = rt.popOperand();
    if (dst_ref_v.ref == Value.null_ref or src_ref_v.ref == Value.null_ref) return runtime.Trap.NullReference;
    if (len_v.i32 < 0 or src_off_v.i32 < 0 or dst_off_v.i32 < 0) return runtime.Trap.OutOfBoundsStore;
    const len: u32 = @intCast(len_v.i32);
    const src_off: u32 = @intCast(src_off_v.i32);
    const dst_off: u32 = @intCast(dst_off_v.i32);
    const dst_ref: u32 = @intCast(dst_ref_v.ref);
    const src_ref: u32 = @intCast(src_ref_v.ref);
    const heap = rt.gc_heap orelse return runtime.Trap.NullReference;
    const dst_hdr = readArrayHeader(heap, dst_ref);
    const src_hdr = readArrayHeader(heap, src_ref);
    const de = @addWithOverflow(dst_off, len);
    if (de[1] != 0 or de[0] > dst_hdr.length) return runtime.Trap.OutOfBoundsStore;
    const se = @addWithOverflow(src_off, len);
    if (se[1] != 0 or se[0] > src_hdr.length) return runtime.Trap.OutOfBoundsLoad;
    const overlap_backward = (dst_ref == src_ref and dst_off > src_off);
    var k: u32 = 0;
    while (k < len) : (k += 1) {
        const i = if (overlap_backward) len - 1 - k else k;
        const s = src_ref + array_header_size + (src_off + i) * esz;
        const d = dst_ref + array_header_size + (dst_off + i) * esz;
        // copyForwards (not @memcpy): a self-region copy with dst_off ==
        // src_off makes these slices identical, which @memcpy rejects as
        // aliasing. Cross-element overlap is already handled by the
        // overlap_backward iteration order above; per element the ranges
        // are either disjoint or identical, both safe for copyForwards.
        std.mem.copyForwards(u8, heap.bytes[d .. d + esz], heap.bytes[s .. s + esz]);
    }
}

/// Wasm 3.0 GC §3.3.5.6.16 — `array.init_data $t $d`: pop [len, src_off,
/// dst_off, dst_ref]; copy `len` natural-width elements from data segment
/// $d (LE zero-extended into the 8-byte slot, mirror array.new_data) into
/// the existing array at dst_off. (10.G cycle 158.)
fn arrayInitData(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const ai = try resolveArrayInfo(inst, @intCast(instr.payload));
    const dataidx: u32 = instr.extra;
    const len_i32 = rt.popOperand().i32;
    const src_off_i32 = rt.popOperand().i32;
    const dst_off_i32 = rt.popOperand().i32;
    const dst_ref_v = rt.popOperand();
    if (dst_ref_v.ref == Value.null_ref) return runtime.Trap.NullReference;
    if (len_i32 < 0 or src_off_i32 < 0 or dst_off_i32 < 0) return runtime.Trap.OutOfBoundsStore;
    const len: u32 = @intCast(len_i32);
    const src_off: u64 = @intCast(src_off_i32);
    const dst_off: u32 = @intCast(dst_off_i32);
    const dst_ref: u32 = @intCast(dst_ref_v.ref);
    const heap = rt.gc_heap orelse return runtime.Trap.NullReference;
    const hdr = readArrayHeader(heap, dst_ref);
    const de = @addWithOverflow(dst_off, len);
    if (de[1] != 0 or de[0] > hdr.length) return runtime.Trap.OutOfBoundsStore;
    if (dataidx >= rt.datas.len) return runtime.Trap.OutOfBoundsLoad;
    const seg: []const u8 = if (dataidx < rt.data_dropped.len and rt.data_dropped[dataidx]) &.{} else rt.datas[dataidx];
    const nat = dataElemNaturalSize(ai.element.valtype_byte) orelse return runtime.Trap.NullReference;
    if (src_off + @as(u64, len) * nat > seg.len) return runtime.Trap.OutOfBoundsLoad;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        // D-493: zero slot + copy `nat` bytes — handles v128 (nat=16) like arrayNewData.
        const s: usize = @intCast(src_off + @as(u64, i) * nat);
        const d = dst_ref + array_header_size + (dst_off + i) * ai.element.size;
        const slot = heap.bytes[d .. d + ai.element.size];
        @memset(slot, 0);
        @memcpy(slot[0..nat], seg[s .. s + nat]);
    }
}

/// Wasm 3.0 GC §3.3.5.6.17 — `array.init_elem $t $e`: pop [len, src_off,
/// dst_off, dst_ref]; copy `len` refs from element segment $e into the
/// existing array at dst_off (mirror array.new_elem). (10.G cycle 158.)
fn arrayInitElem(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const ai = try resolveArrayInfo(inst, @intCast(instr.payload));
    const elemidx: u32 = instr.extra;
    const len_i32 = rt.popOperand().i32;
    const src_off_i32 = rt.popOperand().i32;
    const dst_off_i32 = rt.popOperand().i32;
    const dst_ref_v = rt.popOperand();
    if (dst_ref_v.ref == Value.null_ref) return runtime.Trap.NullReference;
    if (len_i32 < 0 or src_off_i32 < 0 or dst_off_i32 < 0) return runtime.Trap.OutOfBoundsStore;
    const len: u32 = @intCast(len_i32);
    const src_off: u32 = @intCast(src_off_i32);
    const dst_off: u32 = @intCast(dst_off_i32);
    const dst_ref: u32 = @intCast(dst_ref_v.ref);
    const heap = rt.gc_heap orelse return runtime.Trap.NullReference;
    const hdr = readArrayHeader(heap, dst_ref);
    const de = @addWithOverflow(dst_off, len);
    if (de[1] != 0 or de[0] > hdr.length) return runtime.Trap.OutOfBoundsStore;
    if (elemidx >= rt.elems.len) return runtime.Trap.OutOfBoundsLoad;
    const seg: []const Value = if (elemidx < rt.elem_dropped.len and rt.elem_dropped[elemidx]) &.{} else rt.elems[elemidx];
    if (@as(u64, src_off) + @as(u64, len) > seg.len) return runtime.Trap.OutOfBoundsLoad;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const v = seg[src_off + i];
        const d = dst_ref + array_header_size + (dst_off + i) * ai.element.size;
        @memcpy(heap.bytes[d .. d + ai.element.size], std.mem.asBytes(&v)[0..ai.element.size]);
    }
}

/// Wasm 3.0 GC §3.3.5.6.13 — `array.len`: pop GcRef (trap null),
/// read ArrayHeader.length, push i32. Upgrades the cycle-12 stub
/// in `ref_convert_ops.zig` that always trapped NullReference.
fn arrayLen(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const ref_val = rt.popOperand();
    if (ref_val.ref == Value.null_ref) return runtime.Trap.NullReference;
    const ref: u32 = @intCast(ref_val.ref);
    const heap = rt.gc_heap orelse return runtime.Trap.NullReference;
    const hdr = readArrayHeader(heap, ref);
    try rt.pushOperand(.{ .i32 = @intCast(hdr.length) });
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("../../interp/dispatch.zig");
const sections = @import("../../parse/sections.zig");

fn buildInstanceForTypes(arena: *std.heap.ArenaAllocator, body: []const u8) !struct { rt: *Runtime, inst: *Instance } {
    const a = arena.allocator();
    var types = try sections.decodeTypes(testing.allocator, body);
    defer types.deinit();
    const gti = try type_info_mod.materialiseGcTypes(a, types);
    const rt = try a.create(Runtime);
    rt.* = Runtime.init(a);
    const heap = try a.create(@import("../../feature/gc/heap.zig").Heap);
    heap.* = @import("../../feature/gc/heap.zig").Heap.init(a);
    rt.gc_heap = heap;
    const inst = try a.create(Instance);
    inst.* = .{ .store = null, .module = null, .runtime = rt };
    inst.gc_type_infos = gti;
    rt.instance = @ptrCast(inst);
    return .{ .rt = rt, .inst = inst };
}

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "array.new_default: allocates ArrayHeader + zero-init payload (10.G op_gc cycle 24)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // array<i32 var>
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    try env.rt.pushOperand(.{ .i32 = 3 });
    try driveOne(env.rt, &t, .@"array.new_default", 0, 0);
    const ref: u32 = @intCast(env.rt.popOperand().ref);
    const heap = env.rt.gc_heap.?;
    var header: ArrayHeader = undefined;
    @memcpy(std.mem.asBytes(&header)[0..array_header_size], heap.bytes[ref .. ref + array_header_size]);
    try testing.expectEqual(ObjectKind.array, header.header.kind);
    try testing.expectEqual(@as(u32, 0), header.header.info);
    try testing.expectEqual(@as(u32, 3), header.length);
    // Payload zero-init (3 * 8 = 24 bytes).
    var i: u32 = 0;
    while (i < 24) : (i += 1) {
        try testing.expectEqual(@as(u8, 0), heap.bytes[ref + array_header_size + i]);
    }
}

test "array.new: fills N copies of init value (10.G op_gc cycle 24)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    // Push init value then size; stack top = size.
    try env.rt.pushOperand(.{ .i32 = 42 });
    try env.rt.pushOperand(.{ .i32 = 4 });
    try driveOne(env.rt, &t, .@"array.new", 0, 0);
    const ref: u32 = @intCast(env.rt.popOperand().ref);
    const heap = env.rt.gc_heap.?;
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const off = ref + array_header_size + i * 8;
        var v: Value = undefined;
        @memcpy(std.mem.asBytes(&v)[0..8], heap.bytes[off .. off + 8]);
        try testing.expectEqual(@as(i32, 42), v.i32);
    }
}

test "array.new_fixed N=3: writes 3 values in declared order (10.G op_gc cycle 24)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    // Push 3 i32 values in declared order: 11, 22, 33. Stack top = 33 (last).
    try env.rt.pushOperand(.{ .i32 = 11 });
    try env.rt.pushOperand(.{ .i32 = 22 });
    try env.rt.pushOperand(.{ .i32 = 33 });
    try driveOne(env.rt, &t, .@"array.new_fixed", 0, 3);
    const ref: u32 = @intCast(env.rt.popOperand().ref);
    const heap = env.rt.gc_heap.?;
    const expected = [_]i32{ 11, 22, 33 };
    for (expected, 0..) |want, idx| {
        const off = ref + array_header_size + @as(u32, @intCast(idx)) * 8;
        var v: Value = undefined;
        @memcpy(std.mem.asBytes(&v)[0..8], heap.bytes[off .. off + 8]);
        try testing.expectEqual(want, v.i32);
    }
}

test "array.len reads ArrayHeader.length (10.G op_gc cycle 25)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    try env.rt.pushOperand(.{ .i32 = 7 });
    try driveOne(env.rt, &t, .@"array.new_default", 0, 0);
    // Stack: [GcRef]
    try driveOne(env.rt, &t, .@"array.len", 0, 0);
    try testing.expectEqual(@as(i32, 7), env.rt.popOperand().i32);
}

test "array.set then array.get round-trips at idx 2 (10.G op_gc cycle 25)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    try env.rt.pushOperand(.{ .i32 = 5 });
    try driveOne(env.rt, &t, .@"array.new_default", 0, 0);
    const ref_val = env.rt.popOperand();
    // set: [GcRef, idx, value]
    try env.rt.pushOperand(ref_val);
    try env.rt.pushOperand(.{ .i32 = 2 });
    try env.rt.pushOperand(.{ .i32 = 99 });
    try driveOne(env.rt, &t, .@"array.set", 0, 0);
    // get: [GcRef, idx]
    try env.rt.pushOperand(ref_val);
    try env.rt.pushOperand(.{ .i32 = 2 });
    try driveOne(env.rt, &t, .@"array.get", 0, 0);
    try testing.expectEqual(@as(i32, 99), env.rt.popOperand().i32);
}

test "array.get out-of-bounds idx traps OutOfBoundsLoad (10.G op_gc cycle 25)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    try env.rt.pushOperand(.{ .i32 = 3 });
    try driveOne(env.rt, &t, .@"array.new_default", 0, 0);
    const ref_val = env.rt.popOperand();
    try env.rt.pushOperand(ref_val);
    try env.rt.pushOperand(.{ .i32 = 5 }); // beyond length=3
    try testing.expectError(runtime.Trap.OutOfBoundsLoad, driveOne(env.rt, &t, .@"array.get", 0, 0));
}

test "array.fill writes count copies + array.get reads them back (10.G op_gc cycle 25)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    try env.rt.pushOperand(.{ .i32 = 5 });
    try driveOne(env.rt, &t, .@"array.new_default", 0, 0);
    const ref_val = env.rt.popOperand();
    // fill: [GcRef, idx=1, value=77, count=3]
    try env.rt.pushOperand(ref_val);
    try env.rt.pushOperand(.{ .i32 = 1 });
    try env.rt.pushOperand(.{ .i32 = 77 });
    try env.rt.pushOperand(.{ .i32 = 3 });
    try driveOne(env.rt, &t, .@"array.fill", 0, 0);
    // Verify slot 1..3 == 77 and slot 0, 4 stayed zero.
    const expected = [_]i32{ 0, 77, 77, 77, 0 };
    for (expected, 0..) |want, i| {
        try env.rt.pushOperand(ref_val);
        try env.rt.pushOperand(.{ .i32 = @intCast(i) });
        try driveOne(env.rt, &t, .@"array.get", 0, 0);
        try testing.expectEqual(want, env.rt.popOperand().i32);
    }
}

test "array.fill OOB range (idx+count > length) traps OutOfBoundsStore (10.G op_gc cycle 25)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    try env.rt.pushOperand(.{ .i32 = 3 });
    try driveOne(env.rt, &t, .@"array.new_default", 0, 0);
    const ref_val = env.rt.popOperand();
    // idx=2, count=5 → 2+5=7 > length=3
    try env.rt.pushOperand(ref_val);
    try env.rt.pushOperand(.{ .i32 = 2 });
    try env.rt.pushOperand(.{ .i32 = 11 });
    try env.rt.pushOperand(.{ .i32 = 5 });
    try testing.expectError(runtime.Trap.OutOfBoundsStore, driveOne(env.rt, &t, .@"array.fill", 0, 0));
}

test "array.len on null GcRef traps NullReference (10.G op_gc cycle 25)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    try env.rt.pushOperand(.{ .ref = Value.null_ref });
    try testing.expectError(runtime.Trap.NullReference, driveOne(env.rt, &t, .@"array.len", 0, 0));
}

test "array.new huge length traps OutOfHeap, not integer-overflow panic (ADR-0192; wasmtime gc)" {
    // Regression: length * element_size overflowed u32 before Heap.allocate's
    // 4 GiB cap could fire → @panic("integer overflow"). Must trap
    // "allocation size too large" (OutOfHeap). size = i32-max, element i32 →
    // 2147483647 * 4 ≈ 8.6 GiB > u32 max.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    try env.rt.pushOperand(.{ .i32 = 0 }); // init value
    try env.rt.pushOperand(.{ .i32 = 2147483647 }); // size
    try testing.expectError(error.OutOfHeap, driveOne(env.rt, &t, .@"array.new", 0, 0));
}

test "array.copy self-region with identical src/dst offset is alias-safe (ADR-0192; wasmtime gc corpus)" {
    // Regression: per-element `@memcpy` panicked "@memcpy arguments alias"
    // when copying a region of an array onto itself (same array,
    // dst_off == src_off) — identical slices alias. memmove semantics
    // (array.copy spec §3.3.5.6.14) must tolerate it as a no-op-equivalent.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    try env.rt.pushOperand(.{ .i32 = 4 });
    try driveOne(env.rt, &t, .@"array.new_default", 0, 0);
    const ref_val = env.rt.popOperand();
    const seed = [_]i32{ 10, 20, 30, 40 };
    for (seed, 0..) |v, i| {
        try env.rt.pushOperand(ref_val);
        try env.rt.pushOperand(.{ .i32 = @intCast(i) });
        try env.rt.pushOperand(.{ .i32 = v });
        try driveOne(env.rt, &t, .@"array.set", 0, 0);
    }
    // array.copy onto itself, dst_off == src_off == 1, len 2.
    // Stack bottom→top: dst_ref, dst_off, src_ref, src_off, len.
    try env.rt.pushOperand(ref_val);
    try env.rt.pushOperand(.{ .i32 = 1 });
    try env.rt.pushOperand(ref_val);
    try env.rt.pushOperand(.{ .i32 = 1 });
    try env.rt.pushOperand(.{ .i32 = 2 });
    try driveOne(env.rt, &t, .@"array.copy", 0, 0);
    for (seed, 0..) |want, i| {
        try env.rt.pushOperand(ref_val);
        try env.rt.pushOperand(.{ .i32 = @intCast(i) });
        try driveOne(env.rt, &t, .@"array.get", 0, 0);
        try testing.expectEqual(want, env.rt.popOperand().i32);
    }
}
