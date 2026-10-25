//! Wasm 3.0 GC `ref.test` / `ref.test_null` interp handlers
//! (10.G op_gc cycle 7 per `.dev/phase10_g_op_bundle_plan.md`).
//!
//! Encoding (Wasm 3.0 GC §3.3.5.3):
//!   - `ref.test heap_type` (0xFB 0x14): pop reftype; push i32
//!     (1 if value is a non-null instance of heap_type, else 0).
//!   - `ref.test_null heap_type` (0xFB 0x15): pop reftype; push
//!     i32 (1 if value is a (ref null heap_type), else 0). Null
//!     always matches the `_null` variant.
//!
//! Cycle-7 semantics (no RTT yet):
//!   - The validator already type-checked the heap_type → the
//!     operand statically matches the heap_type's parent class.
//!   - Without RTT (ADR-0116 type_hierarchy.zig lands later),
//!     we can't refine cast-to-subtype. The runtime trusts the
//!     validator's static narrowing and only distinguishes null
//!     from non-null at the value level:
//!       * `ref.test`: 1 if non-null, 0 if null.
//!       * `ref.test_null`: 1 always (null + non-null both match).
//!   - This matches simple corpus fixtures where heap_type ==
//!     declared reftype; cast-to-subtype refinement lands with
//!     RTT TypeInfo at sub-chunk 7's later cycles.
//!
//! Zone 1 (`src/instruction/`).

const std = @import("std");

const dispatch = @import("../../ir/dispatch_table.zig");
const zir = @import("../../ir/zir.zig");
const runtime = @import("../../runtime/runtime.zig");
const type_info_mod = @import("../../feature/gc/type_info.zig");
const heap_mod = @import("../../feature/gc/heap.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const InterpCtx = dispatch.InterpCtx;
const Runtime = runtime.Runtime;
const Value = runtime.Value;
const Instance = runtime.Instance;
const AbstractHeapType = zir.AbstractHeapType;
const ObjectHeader = type_info_mod.ObjectHeader;
const ObjectKind = type_info_mod.ObjectKind;
const GcTypeInfos = type_info_mod.GcTypeInfos;
const Heap = heap_mod.Heap;

inline fn op(o: ZirOp) usize {
    return @backingInt(o);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"ref.test")] = refTest;
    table.interp[op(.@"ref.test_null")] = refTestNull;
    table.interp[op(.@"ref.cast")] = refCast;
    table.interp[op(.@"ref.cast_null")] = refCastNull;
}

/// Concrete-index tag bit for the D-453 encoded heap-type `u32`
/// (`init_expr.readHeapType`): when set, the low 31 bits are a concrete
/// typeidx ≥ 64; when clear, the value is a bare wire byte (abstract head
/// or concrete idx < 64).
const concrete_tag: u32 = 0x8000_0000;

/// Bits 0..29 of the D-453 encoded heap-type — the concrete typeidx range.
/// Bit 31 is `concrete_tag`; bit 30 is the JIT trampoline's null flag
/// (`jit_abi.zig`), so a tagged index must mask it off to recover the idx.
const idx_mask: u32 = 0x3FFF_FFFF;

/// Map a heap-type wire byte to its abstract head, or null for a
/// concrete typeidx byte (single-byte indices 0x00..0x3F don't collide
/// with the 0x69..0x74 abstract set; tagged multi-byte indices ≥ 64 are
/// handled by the `concrete_tag` branch before this is reached). Mirrors
/// `init_expr.readTypedRef`'s abstract switch.
fn decodeAbstract(b: u8) ?AbstractHeapType {
    return switch (b) {
        0x70 => .func,
        0x6F => .extern_,
        0x6E => .any,
        0x6D => .eq,
        0x6C => .i31,
        0x6B => .struct_,
        0x6A => .array,
        0x69 => .exn,
        0x71 => .none,
        0x72 => .noextern,
        0x73 => .nofunc,
        0x74 => .noexn,
        else => null,
    };
}

/// Read a non-null heap GC object's `ObjectHeader.kind` (struct_ / array)
/// from the slot the GcRef offset points at. Null on a malformed heap.
fn readObjKindHeap(heap_opt: ?*const Heap, v: Value) ?ObjectKind {
    const heap = heap_opt orelse return null;
    const hdr_size = @sizeOf(ObjectHeader);
    // `v.ref` may NOT be a GC-heap offset — `ref.test (ref struct)` can be
    // reached with an anyref holding a host pointer (an `any.convert_extern`
    // result). Reject anything at/beyond the heap (as u64) BEFORE the u32
    // cast — the cast panics on a > u32 pointer. Such a value is simply not
    // a struct/array → no match.
    if (v.ref >= heap.bytes.len) return null;
    const ref: u32 = @intCast(v.ref);
    if (@as(usize, ref) + hdr_size > heap.bytes.len) return null;
    var hdr: ObjectHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr)[0..hdr_size], heap.bytes[ref .. ref + hdr_size]);
    return hdr.kind;
}

/// Runtime type-test of a NON-NULL ref `v` against heap-type byte `ht`
/// (Wasm 3.0 GC §3.3.5.3 / §4.4). The validator statically narrows the
/// operand to `ht`'s hierarchy, so the top of each hierarchy (any / eq /
/// func / extern / exn) matches any non-null operand; the bottoms (none /
/// nofunc / noextern / noexn) match nothing; i31 / struct / array test
/// the concrete runtime shape. Concrete-typeidx targets fall back to a
/// coarse non-null match (precise supertype walk lands with
/// `TypeInfo.supertype_chain` threading, next cycle).
/// Read a non-null heap GC object's `ObjectHeader.info` (its typeidx).
/// Same untagged-ref guard as `readObjKindHeap` (bounds-check as u64 before
/// the u32 cast — `v.ref` may be a non-GC host pointer).
fn readObjInfoHeap(heap_opt: ?*const Heap, v: Value) ?u32 {
    const heap = heap_opt orelse return null;
    const hdr_size = @sizeOf(ObjectHeader);
    if (v.ref >= heap.bytes.len) return null;
    const ref: u32 = @intCast(v.ref);
    if (@as(usize, ref) + hdr_size > heap.bytes.len) return null;
    var hdr: ObjectHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr)[0..hdr_size], heap.bytes[ref .. ref + hdr_size]);
    return hdr.info;
}

/// Does the object whose runtime typeidx is `obj_idx` reach concrete
/// target type `target` via its declared supertype chain (self-inclusive)?
/// Reads the per-Instance `TypeInfo.supertype_chain` materialised at
/// instantiate (ADR-0116 §3).
pub fn concreteReachesGti(gti: *const GcTypeInfos, obj_idx: u32, target: u32) bool {
    if (obj_idx >= gti.entries.len) return false;
    const ti = gti.entries[obj_idx];
    // ADR-0126 Phase-10a — match the target by raw index OR structural
    // canonical id along the self-inclusive supertype chain, so ref.test
    // against a canonically-equal-but-distinct-index type succeeds
    // (ref_test test-canon: $t1 / $t1' both `(sub $t0 (struct (field i32)))`).
    const target_cid: ?u64 = if (target < gti.canonical_ids.len) gti.canonical_ids[target] else null;
    for (ti.supertype_chain[0..ti.depth]) |s| {
        if (s == target) return true;
        if (target_cid) |tc| {
            if (s < gti.canonical_ids.len and gti.canonical_ids[s] == tc) return true;
        }
    }
    return false;
}

/// Runtime type-test of a NON-NULL ref `v` against heap-type byte `ht`
/// (Wasm 3.0 GC §3.3.5.3 / §4.4), parameterised on the materialised GC
/// type table + heap DIRECTLY (not a `*Runtime`) so BOTH the interp
/// (`gcRefMatchesNonNull` below) and the JIT `jitGcRefTest` / `jitGcRefCast`
/// trampolines (`engine/codegen/shared/jit_abi.zig`) share one algorithm —
/// the interp `Runtime` and the JIT `JitRuntime` are distinct types but
/// both expose the same materialised `GcTypeInfos` + `Heap`. The validator
/// statically narrows the operand to `ht`'s hierarchy, so the top of each
/// hierarchy (any / eq / func / extern / exn) matches any non-null operand;
/// the bottoms (none / nofunc / noextern / noexn) match nothing; i31 /
/// struct / array test the concrete runtime shape; a concrete typeidx
/// target walks the supertype chain (ADR-0116). `gti` null → concrete path
/// can't resolve (no match); abstract path still works without it.
pub fn gcRefMatchesNonNullCore(gti: ?*const GcTypeInfos, heap: ?*const Heap, v: Value, ht: u32) bool {
    const is_i31 = Value.isI31Ref(v);
    // D-453: a concrete typeidx target is either the high-bit-tagged form
    // (idx ≥ 64) OR a bare byte not in the abstract set (idx < 64). Both
    // resolve to a u32 concrete index `cidx`; only abstract heads fall
    // through to `gcAbstractMatch`.
    const cidx: ?u32 = if (ht & concrete_tag != 0)
        // Mask to bits 0..29 (idx_mask): the concrete-tag is bit 31 and the
        // JIT trampoline reserves bit 30 for its null flag. The trampoline
        // strips the null flag BEFORE calling here, so bit 30 is normally
        // clear (and interp never sets it) — this mask is defensive so a
        // stray bit-30 can't leak into the index (D-453 nullbit fix).
        ht & idx_mask
    else if (decodeAbstract(@truncate(ht)) == null)
        ht
    else
        null;
    if (cidx) |target| {
        // i31 has no concrete type.
        if (is_i31) return false;
        const g = gti orelse return false;
        // ADR-0126 — a concrete FUNC-type target tests a funcref operand:
        // resolve the funcref's RAW declared typeidx via its FuncEntity
        // (funcrefs are NOT GC-heap objects, so `readObjInfoHeap` can't see
        // them → ref.test would wrongly return 0). struct/array targets
        // read the heap object's `ObjectHeader.info`.
        if (concreteTargetIsFuncGti(g, target)) {
            const fe = Value.refAsFuncEntity(v) orelse return false;
            return concreteReachesGti(g, fe.raw_typeidx, target);
        }
        const info = readObjInfoHeap(heap, v) orelse return false;
        return concreteReachesGti(g, info, target);
    }
    const obj_kind: ?ObjectKind = if (is_i31) null else readObjKindHeap(heap, v);
    return gcAbstractMatch(@truncate(ht), is_i31, obj_kind);
}

/// Interp entry point: resolves the materialised GC type table + heap from
/// `rt`, then delegates to `gcRefMatchesNonNullCore`. Shared with the
/// interp's br_on_cast handler (Zone 2 → Zone 1). Null handling (per the
/// op's nullability flag) is the caller's concern.
pub fn gcRefMatchesNonNull(rt: *Runtime, v: Value, ht: u32) bool {
    const gti: ?*const GcTypeInfos = blk: {
        const inst_opaque = rt.instance orelse break :blk null;
        const inst = @as(*const Instance, @ptrCast(@alignCast(inst_opaque)));
        break :blk if (inst.gc_type_infos) |*g| g else null;
    };
    return gcRefMatchesNonNullCore(gti, rt.gc_heap, v, ht);
}

/// Runtime concrete-type subtype test (Wasm 3.0 §3.3.5.5): is declared func
/// type `sub_idx` a subtype of `target` via its self-inclusive declared-
/// supertype chain (raw index OR canonical id)? Used by interp `call_indirect`
/// so a callee whose declared type is a SUBTYPE of the call's expected type is
/// accepted, not just a structurally-equal one. `rt` supplies the materialised
/// `GcTypeInfos`; null (non-GC module) → false (caller falls back to `sigEq`).
pub fn concreteReaches(rt: *Runtime, sub_idx: u32, target: u32) bool {
    // Require materialised GC types — func subtyping only exists with GC; a
    // non-GC module (no gti) uses pure `sigEq` (pre-GC exact match). NO raw
    // `sub_idx == target` shortcut: a `FuncEntity.raw_typeidx` may default to 0
    // and collide with a declared type 0 of a different shape (trap_audit
    // sig-mismatch). `concreteReachesGti`'s self-inclusive chain handles the
    // genuine same-type case.
    const inst_opaque = rt.instance orelse return false;
    const inst = @as(*const Instance, @ptrCast(@alignCast(inst_opaque)));
    const gti: *const GcTypeInfos = if (inst.gc_type_infos) |*g| g else return false;
    return concreteReachesGti(gti, sub_idx, target);
}

/// Does this runtime carry a materialised GC type-identity table? When true,
/// `concreteReaches` is the authoritative `call_indirect` / `call_ref` subtype
/// check (the structural `sigEq` is too loose — it ignores type identity /
/// finality); when false the module declares no subtyping and `sigEq` is
/// correct (D-232). Mirrors `concreteReaches`'s gti resolution.
pub fn hasGti(rt: *Runtime) bool {
    const inst_opaque = rt.instance orelse return false;
    const inst = @as(*const Instance, @ptrCast(@alignCast(inst_opaque)));
    return inst.gc_type_infos != null;
}

/// Is the concrete target type index a func typedef? (Selects the
/// funcref-resolution path in `gcRefMatchesNonNullCore`.)
fn concreteTargetIsFuncGti(gti: *const GcTypeInfos, target: u32) bool {
    if (target >= gti.entries.len) return false;
    return gti.entries[target].kind == .func;
}

/// Pure core of the non-null runtime type-test (testable without a
/// Runtime/heap): given the heap-type byte + the operand's extracted
/// runtime facts (`is_i31`, heap `obj_kind` when not i31), decide the
/// match. See `gcRefMatchesNonNull` for the spec rationale.
fn gcAbstractMatch(ht: u8, is_i31: bool, obj_kind: ?ObjectKind) bool {
    const a = decodeAbstract(ht) orelse return true; // concrete: coarse pre-supertype
    return switch (a) {
        .any, .func, .extern_, .exn => true,
        // 10.G cycle 169 — eq = i31 ∪ struct ∪ array (Wasm 3.0 GC §4.2.8).
        // A host externref brought into the any hierarchy via
        // any.convert_extern (obj_kind null — non-GC sentinel, not i31)
        // is anyref but NOT eq. ref_test ref_test_eq($ta[6]) expects 0.
        .eq => is_i31 or obj_kind != null,
        .none, .nofunc, .noextern, .noexn => false,
        .i31 => is_i31,
        .struct_ => !is_i31 and obj_kind == .struct_,
        .array => !is_i31 and obj_kind == .array,
    };
}

fn refTest(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const ht: u32 = @truncate(instr.payload);
    const matches: i32 = if (v.ref == Value.null_ref) 0 else @intFromBool(gcRefMatchesNonNull(rt, v, ht));
    try rt.pushOperand(.{ .i32 = matches });
}

fn refTestNull(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const ht: u32 = @truncate(instr.payload);
    // `_null` variant: null matches; otherwise same runtime test.
    const matches: i32 = if (v.ref == Value.null_ref) 1 else @intFromBool(gcRefMatchesNonNull(rt, v, ht));
    try rt.pushOperand(.{ .i32 = matches });
}

/// Wasm 3.0 GC §3.3.5.4 — `ref.cast heap_type`: pop reftype;
/// trap if value is null OR type doesn't match heap_type;
/// otherwise push the value back narrowed to heap_type.
///
/// `ref.cast heap_type` (Wasm 3.0 GC §4.4.5): trap `CastFailure` if the
/// operand is null (the non-null target rejects it) OR its runtime type
/// is not a subtype of `ht`; else push it back. ADR-0125/0116 cycle 152.
fn refCast(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const ht: u32 = @truncate(instr.payload);
    if (v.ref == Value.null_ref) return runtime.Trap.CastFailure;
    if (!gcRefMatchesNonNull(rt, v, ht)) return runtime.Trap.CastFailure;
    try rt.pushOperand(v);
}

/// `ref.cast_null heap_type`: like ref.cast but null passes (the target
/// is `(ref null ht)`); a non-null operand still trap-checks its type.
fn refCastNull(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const ht: u32 = @truncate(instr.payload);
    if (v.ref == Value.null_ref) {
        try rt.pushOperand(v);
        return;
    }
    if (!gcRefMatchesNonNull(rt, v, ht)) return runtime.Trap.CastFailure;
    try rt.pushOperand(v);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("../../interp/dispatch.zig");

test "gcAbstractMatch: abstract heap-type runtime test (10.G cycle 149, ADR-0116 RTT)" {
    // i31 (0x6C): matches an i31 value, not a struct.
    try testing.expect(gcAbstractMatch(0x6C, true, null));
    try testing.expect(!gcAbstractMatch(0x6C, false, .struct_));
    // struct (0x6B) / array (0x6A): match by ObjectHeader.kind, reject i31.
    try testing.expect(gcAbstractMatch(0x6B, false, .struct_));
    try testing.expect(!gcAbstractMatch(0x6B, false, .array));
    try testing.expect(!gcAbstractMatch(0x6B, true, null)); // i31 ⊄ struct
    try testing.expect(gcAbstractMatch(0x6A, false, .array));
    // any (0x6E) / eq (0x6D): any non-null operand of the hierarchy matches.
    try testing.expect(gcAbstractMatch(0x6E, true, null));
    try testing.expect(gcAbstractMatch(0x6D, false, .struct_));
    // bottoms none (0x71) / nofunc (0x73) / noextern (0x72): match nothing.
    try testing.expect(!gcAbstractMatch(0x71, false, .struct_));
    try testing.expect(!gcAbstractMatch(0x73, true, null));
    // func (0x70) / extern (0x6F): top of their hierarchy → non-null matches.
    try testing.expect(gcAbstractMatch(0x70, false, null));
    // concrete typeidx byte (e.g. 0x01): coarse non-null match (pre-supertype).
    try testing.expect(gcAbstractMatch(0x01, false, .struct_));
}

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "ref.test: null ref returns 0 (10.G op_gc cycle 7)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try driveOne(&rt, &t, .@"ref.test", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "ref.test (ref any): non-null ref matches → 1 (10.G cycle 151)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0xDEADBEEF });
    // payload 0x6E = `any`: the hierarchy top matches any non-null operand.
    try driveOne(&rt, &t, .@"ref.test", 0x6E, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}

test "ref.test_null: null ref returns 1 (10.G op_gc cycle 7; null matches _null variant)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try driveOne(&rt, &t, .@"ref.test_null", 0, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}

test "ref.test_null (ref any): non-null ref matches → 1 (10.G cycle 151)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0xCAFEBABE });
    try driveOne(&rt, &t, .@"ref.test_null", 0x6E, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}

test "ref.cast: null ref traps CastFailure (10.G cycle 152)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    // payload 0x6E = any; null still fails the non-null `ref.cast`.
    try testing.expectError(runtime.Trap.CastFailure, driveOne(&rt, &t, .@"ref.cast", 0x6E, 0));
}

test "ref.cast (ref any): non-null ref round-trips unchanged (10.G cycle 152)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0xDEADBEEF });
    try driveOne(&rt, &t, .@"ref.cast", 0x6E, 0); // any: non-null matches
    try testing.expectEqual(@as(u64, 0xDEADBEEF), rt.popOperand().ref);
}

test "ref.cast_null: null ref round-trips unchanged (10.G op_gc cycle 8)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try driveOne(&rt, &t, .@"ref.cast_null", 0x6E, 0);
    try testing.expectEqual(Value.null_ref, rt.popOperand().ref);
}

test "ref.cast_null (ref any): non-null ref round-trips unchanged (10.G cycle 152)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0xCAFEBABE });
    try driveOne(&rt, &t, .@"ref.cast_null", 0x6E, 0); // any: non-null matches
    try testing.expectEqual(@as(u64, 0xCAFEBABE), rt.popOperand().ref);
}
