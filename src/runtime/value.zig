//! WASM Spec §4.2.2 "Values" — runtime value representation.
//!
//! Per ADR-0023 §3 P-D: extracted from the previous monolithic
//! `runtime/runtime.zig` so each WASM Spec §4.2 concept lives in
//! its own file under `runtime/`. The extern union shape is
//! load-bearing per ROADMAP §P3 (cold-start: no per-slot type
//! byte) and §P13 (type up-front: invariants fixed at design time).
//!
//! Zone 1 (`src/runtime/`).

const std = @import("std");
const builtin = @import("builtin");

const FuncEntity = @import("instance/func.zig").FuncEntity;

/// 128-bit value slot (per ADR-0110, widened from 8 bytes in
/// §9.13-V Phase A.3 — v128 SIMD is now first-class; Wasm v3.0
/// terminal width). The dispatch loop knows the type from the
/// `ZirOp`; the union never carries a runtime tag (per §P3
/// cold-start: no per-slot type byte). Float values are stored as
/// their IEEE-754 bit pattern via `bits64` on entry/exit so NaN
/// canonicalisation can be deferred to the boundary opcodes that
/// need it (Wasm 1.0 §6.2.3).
///
/// Slot layout (little-endian; scalar variants alias the low 8 B
/// of the 16-byte slot — Value-shape transparency for existing
/// scalar Wasm semantics):
/// ```
///   bytes [0..8]   = scalar payload (i32/i64/f32/f64/ref).
///   bytes [8..16]  = high half. v128 spans full [0..16].
/// ```
/// `bits128` is the canonical full-slot accessor; `bits64` aliases
/// the low 8 bytes for backward-compatible read/write. Phase A.4
/// cascade migrates JIT codegen / regalloc / globals stride to
/// the 16-byte uniform stride.
pub const Value = extern union {
    i32: i32,
    u32: u32,
    i64: i64,
    u64: u64,
    f32: f32,
    f64: f64,
    bits64: u64,
    /// Full 128-bit slot view. Used for v128 SIMD payload and as
    /// the canonical zero-init (per `Value.zero` below). The
    /// low 64 bits coincide with `bits64`; the high 64 bits are
    /// observable only via this accessor or `v128`.
    bits128: u128,
    /// 16-byte view for Wasm v128 SIMD (Wasm 2.0 §2.3.4). Lane
    /// indexing is little-endian per Wasm spec — lane 0 is byte
    /// [0..N], lane MAX is byte [16-N..16].
    v128: [16]u8,
    /// Reference value (Wasm 2.0 §9.2 / 2.3 chunk 5). Funcref:
    /// `@intFromPtr(*const FuncEntity)` — the pointer carries
    /// source-runtime identity so cross-module `call_indirect`
    /// can route to the source's function table without a
    /// separate routing layer (per ADR-0014 §2.1 / 6.K.1).
    /// Externref: opaque 64-bit host handle (unchanged). The
    /// sentinel `null_ref` represents the spec null reference;
    /// it equals literal `0` because `c_allocator.alloc` cannot
    /// return address 0 on any of the three target platforms
    /// (Mac aarch64 darwin, Linux x86_64 glibc/musl, Windows
    /// x86_64 ucrt) per the C-standard `malloc` contract.
    ref: u64,
    /// Wasm 3.0 GC `anyref` (Internal hierarchy) — 32-bit GcRef
    /// (offset into the per-Store GC slab). `0` = null sentinel
    /// (offset 0 reserved; never allocated). Lives in parallel
    /// with `ref: u64` (Phase 2 funcref / externref); ADR-0115 §6
    /// authorises this arm as the cycle-1 substrate for 10.G
    /// WasmGC. Future cycles add eqref / structref / arrayref
    /// (all share this u32 GcRef encoding per ADR-0116) + i31ref
    /// (tagged via low-bit discriminant per ADR-0116 §135-149).
    anyref: u32,

    pub const zero: Value = .{ .bits128 = 0 };
    pub const null_ref: u64 = 0;

    // The `from*` constructors define all 16 bytes: the value's own
    // bytes at the low end, zero above them. Each initialises the whole
    // slot through `bits128`.
    pub fn fromI32(v: i32) Value {
        return .{ .bits128 = @as(u32, @bitCast(v)) };
    }
    pub fn fromI64(v: i64) Value {
        return .{ .bits128 = @as(u64, @bitCast(v)) };
    }
    pub fn fromF32Bits(b: u32) Value {
        return .{ .bits128 = b };
    }
    pub fn fromF64Bits(b: u64) Value {
        return .{ .bits128 = b };
    }
    pub fn fromRef(r: u64) Value {
        return .{ .bits128 = r };
    }

    /// Construct a Value from a v128 byte array (Wasm 2.0 §2.3.4
    /// — lane 0 at byte [0..N], lane MAX at byte [16-N..16]).
    pub fn fromV128(bytes: [16]u8) Value {
        return .{ .v128 = bytes };
    }

    /// Encode a `*FuncEntity` as a funcref `Value`. The pointer
    /// must outlive every read of this Value (its lifetime is
    /// tied to the owning Runtime's `func_entities` array, which
    /// the per-instance arena holds for the Runtime's lifetime).
    pub fn fromFuncRef(fe: *const FuncEntity) Value {
        return fromRef(@intFromPtr(fe));
    }

    /// Decode a funcref `Value` to its `*const FuncEntity` source,
    /// or `null` if the cell holds the null reference.
    pub fn refAsFuncEntity(v: Value) ?*const FuncEntity {
        if (v.ref == null_ref) return null;
        return @ptrFromInt(v.ref);
    }

    /// Wasm 3.0 EH (10.E-exnref-a) — encode an `Exception` heap
    /// object pointer as an `exnref` `Value`. The pointer must
    /// outlive every read of the ref (lifetime tied to the owning
    /// Runtime's `live_exceptions` tracker, freed at
    /// `Runtime.deinit`). Same bit-level layout as `fromFuncRef`;
    /// disambiguation between funcref / exnref is validator-
    /// enforced (the operand stack type tracking knows which
    /// reftype is in play at each pop site).
    pub fn fromExceptionRef(exc: *anyopaque) Value {
        return fromRef(@intFromPtr(exc));
    }

    /// Decode an exnref `Value` to its `*anyopaque` source (caller
    /// reinterprets as `*Exception` from `feature/exception_handling`).
    /// Returns `null` for the null exnref sentinel.
    pub fn refAsExceptionPtr(v: Value) ?*anyopaque {
        if (v.ref == null_ref) return null;
        return @ptrFromInt(v.ref);
    }

    /// Encode an i32 as an i31-tagged GC reference (Wasm 3.0 GC
    /// proposal §3.x). Stores the i31-packed payload in the low
    /// 32 bits of the `ref` slot per ADR-0116 D4; the high 32 bits
    /// are zeroed. Spec `ref.i31` truncates wider-than-31-bit
    /// inputs silently — `i32ToI31Truncate` mirrors that.
    ///
    /// Phase 10 punts on the dedicated `anyref: u32` arm (ADR-0116
    /// D4) until the GC heap impl needs to disambiguate i31 from
    /// heap-pointer encodings; the ref slot is sufficient while
    /// no heap-ref Value exists.
    pub fn fromI31Truncate(x: i32) Value {
        return fromRef(i31_pack.i32ToI31Truncate(x));
    }

    /// Decode an i31-tagged ref to a signed i32 (Wasm 3.0
    /// `i31.get_s`). Caller MUST verify `isI31Ref(v)` first; the
    /// runtime handler reads the low 32 bits of the ref slot and
    /// passes them through `i31ToI32Signed`.
    pub fn refAsI31Signed(v: Value) i32 {
        return i31_pack.i31ToI32Signed(@truncate(v.ref));
    }

    /// Decode an i31-tagged ref to an unsigned i32 (Wasm 3.0
    /// `i31.get_u`). High bit zero-extends.
    pub fn refAsI31Unsigned(v: Value) u32 {
        return i31_pack.i31ToI32Unsigned(@truncate(v.ref));
    }

    /// Discriminate an i31 ref from a heap-ref / null. Per
    /// ADR-0116 D4: low bit `1` marks an i31; low bit `0` marks
    /// heap pointer or null.
    pub fn isI31Ref(v: Value) bool {
        return i31_pack.isI31(@truncate(v.ref));
    }
};

const i31_pack = @import("../feature/gc/i31.zig");

comptime {
    // Locks in the platform contract above: any future change to
    // null_ref must re-survey the malloc guarantees on all three
    // target hosts. A change here without an ADR is a §18 deviation.
    std.debug.assert(Value.null_ref == 0);
    // The scalar fields alias the low bytes of `bits128` (the layout
    // above), which the `from*` constructors rely on.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

// FuncEntity moved to runtime/instance/func.zig per ADR-0023 §7
// item 6 + §3 reference table.

const testing = std.testing;

test "Value: extern union slot is 16 bytes (ADR-0110 §9.13-V)" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(Value));
    // Wasm 2.0 §2.3.4 v128 requires 16-byte alignment for native
    // MOVUPS / LDR Q access; the union widening must lift @alignOf
    // accordingly so JIT-emitted vector loads on the operand stack
    // and globals storage don't fault on misalignment.
    try testing.expect(@alignOf(Value) >= 16);
}

test "Value.zero zeroes all 16 bytes (post-widen invariant)" {
    const z = Value.zero;
    for (z.v128) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expectEqual(@as(u128, 0), z.bits128);
}

test "Value.fromV128 round-trip preserves all lanes" {
    const lanes: [16]u8 = .{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    };
    const v = Value.fromV128(lanes);
    for (lanes, 0..) |want, i| try testing.expectEqual(want, v.v128[i]);
}

test "Value.fromI32 / fromI64 round-trip" {
    const a = Value.fromI32(-7);
    try testing.expectEqual(@as(i32, -7), a.i32);

    const b = Value.fromI64(0x7FFF_FFFF_FFFF_FFFF);
    try testing.expectEqual(@as(i64, 0x7FFF_FFFF_FFFF_FFFF), b.i64);
}

test "Value.fromF32Bits / fromF64Bits store IEEE bits" {
    const f32_one_bits: u32 = 0x3F800000;
    const a = Value.fromF32Bits(f32_one_bits);
    try testing.expectEqual(@as(u64, f32_one_bits), a.bits64);

    const f64_one_bits: u64 = 0x3FF0_0000_0000_0000;
    const b = Value.fromF64Bits(f64_one_bits);
    try testing.expectEqual(f64_one_bits, b.bits64);
}

test "Value.anyref: u32 arm exists (10.G-foundation cycle 1; ADR-0115 §6)" {
    // GC ValType `anyref` (Internal hierarchy) stores a 32-bit GcRef
    // (offset into the per-Store GC slab, 0 = null sentinel). Per
    // ADR-0115 §6 the arm is parallel to (future) funcref:u32 /
    // externref:u32 reshapes; cycle 1 lands the arm only, no
    // semantic consumers yet — needs_heap_detector / op_gc / heap.zig
    // come in subsequent cycles of the 10.G bundle.
    const v: Value = .{ .anyref = 0xDEAD_BEEF };
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), v.anyref);
    // Null sentinel: zero.
    const n: Value = .{ .anyref = 0 };
    try testing.expectEqual(@as(u32, 0), n.anyref);
}
