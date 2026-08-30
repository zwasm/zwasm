//! Trap surface of the C ABI binding (§9.5 / 5.0 chunk b
//! carve-out from `wasm.zig` per ADR-0007).
//!
//! Holds the `TrapKind` classification, the `Trap` shape itself,
//! the interp-error → kind mapping, the message lookup, the
//! binding-internal `allocTrap` helper, and the three
//! `wasm_trap_*` C exports.
//!
//! `Store` and `ByteVec` are still defined in `wasm.zig`;
//! we reach back through a module-level circular import (Zig 0.16
//! resolves it because the references are pointer-only — no
//! struct-layout cycle).
//!
//! `wasm_byte_vec_delete` ADR-listed alongside this file but
//! actually has zero Trap coupling; it stays in `wasm.zig`
//! and moves later with the rest of the vec family in chunk c.
//!
//! Zone 3 — same as the rest of `src/api/`.

const std = @import("std");
const wasm_c_api = @import("wasm.zig");
const handles = @import("handles.zig"); // for `Ref` (wasm_trap_as_ref view); pointer-only cycle

const testing = std.testing;

// ============================================================
// Trap classification + shape
// ============================================================

/// `wasm_trap_kind_t` — internal classification of a Trap.
/// Maps `runtime.Trap` conditions to the spec-conformant message
/// strings the C host expects (per Wasm spec assertion text);
/// also covers binding-layer failures such as arg-count
/// mismatches that wasm.h surfaces as traps too.
pub const TrapKind = enum(u32) {
    binding_error = 0,
    unreachable_ = 1,
    div_by_zero = 2,
    int_overflow = 3,
    invalid_conversion = 4,
    oob_memory = 5,
    oob_table = 6,
    uninitialized_elem = 7,
    indirect_call_mismatch = 8,
    stack_overflow = 9,
    out_of_memory = 10,
    // D-293 slice-4a — Wasm 3.0 GC/typed-ref/EH trap kinds. These already
    // exist in `runtime.Trap` (NullReference / CastFailure / UncaughtException)
    // but were missing from the surface enum, so the interp mis-reported them as
    // `binding_error` ("host invocation error"). Appended (stable C-ABI values).
    null_reference = 11,
    cast_failure = 12,
    uncaught_exception = 13,
    // Wasm threads/atomics (ADR-0168): unaligned atomic effective address.
    // Spec reason "unaligned atomic"; distinct C-ABI value (appended).
    unaligned_atomic = 14,
    // Wasm threads/atomics (ADR-0168): memory.atomic.wait* on a non-shared
    // memory. Spec reason "expected shared memory"; appended C-ABI value.
    expected_shared_memory = 15,
    // Sandboxing (ADR-0179 #3a): a host raised the cooperative-interruption
    // flag (cancel / timeout) and the guest's next poll trapped. The interp
    // already produces `error.Interrupted`; before this it mis-surfaced as
    // `binding_error`. The JIT prologue/back-edge poll will emit stub code 16.
    interrupted = 16,
    // Sandboxing (ADR-0179 #3b): the metered fuel budget hit -1. Interp =
    // `error.OutOfFuel` (per-instruction units); JIT = poll-site-crossing
    // units (prologue + loop back-edges, stub code 17). Same kind either way.
    out_of_fuel = 17,
    // Issue #331 — a WASI guest called `proc_exit`. Host-originated: the guest
    // asked to terminate, it did not fault, so it is neither `unreachable_` nor
    // an embedder failure. The status itself is read out-of-band with
    // `zwasm_store_wasi_exit_code`; this kind only says which path ended the run.
    wasi_exit = 18,
};

/// `wasm_trap_t` — runtime trap surface. Carries the trap kind +
/// a heap-allocated message (always populated; freed in
/// `wasm_trap_delete`) + a back-pointer to the originating Store
/// so `_delete` can recover the allocator without a global.
pub const Trap = extern struct {
    store: ?*wasm_c_api.Store,
    kind: TrapKind,
    message_ptr: ?[*]u8,
    message_len: usize,
    /// host_info (wasm.h `WASM_DECLARE_REF_BASE`); accessors in
    /// `host_info.zig`, finalizer fired in `wasm_trap_delete`.
    host_info: ?*anyopaque = null,
    host_info_finalizer: ?*const fn (?*anyopaque) callconv(.c) void = null,
    /// Cached borrowed `wasm_ref_t` view (`wasm_trap_as_ref`, ADR-0158;
    /// payload = `@intFromPtr(self)`; freed in `wasm_trap_delete`).
    ref_view: ?*handles.Ref = null,
};

// ============================================================
// Internal helpers
// ============================================================

pub fn trapMessageFor(kind: TrapKind) []const u8 {
    return switch (kind) {
        .binding_error => "host invocation error",
        .unreachable_ => "unreachable",
        .div_by_zero => "integer divide by zero",
        .int_overflow => "integer overflow",
        .invalid_conversion => "invalid conversion to integer",
        .oob_memory => "out of bounds memory access",
        .oob_table => "out of bounds table access",
        .uninitialized_elem => "uninitialized element",
        .indirect_call_mismatch => "indirect call type mismatch",
        .stack_overflow => "call stack exhausted",
        .out_of_memory => "out of memory",
        // D-293 slice-4a — spec reason strings (Wasm 3.0 typed-ref / GC / EH).
        .null_reference => "null reference",
        .cast_failure => "cast failure",
        .uncaught_exception => "uncaught exception",
        .unaligned_atomic => "unaligned atomic",
        .expected_shared_memory => "expected shared memory",
        .interrupted => "interrupted",
        .out_of_fuel => "all fuel consumed",
        .wasi_exit => "wasi proc_exit",
    };
}

/// Map a JIT/AOT codegen trap-kind code (the numeric value the shared trap
/// stub records in `JitRuntime.trap_kind`) to a precise `TrapKind`, or `null`
/// when the code is the generic bucket (0 unmarked / 1 generic) that the
/// codegen does not yet split per-kind. ADR-0164 workstream A surfaces these;
/// widening the generic bucket into oob_memory / unreachable / div_by_zero /
/// int_overflow / … at the codegen trap sites is D-292. The precise codes
/// match `arm64/emit.zig` (call_indirect stubs) + `x86_64/op_control.zig`
/// (stack-probe stub).
pub fn jitTrapCode(code: u32) ?TrapKind {
    return switch (code) {
        2 => .oob_table, // call_indirect bounds (B.HS)
        3 => .indirect_call_mismatch, // call_indirect signature (B.NE)
        4 => .stack_overflow, // x86_64 stack-probe stub
        5 => .unreachable_, // D-292 A1 — dedicated `unreachable` stub (both arches)
        6 => .oob_memory, // D-292 A3 — memory load/store/bulk-memory oob stub
        7 => .div_by_zero, // D-292 A2 — div-by-zero stub
        8 => .int_overflow, // D-292 A2 — div_s INT_MIN/-1 signed-overflow stub; D-293 slice-3 — trunc range
        9 => .invalid_conversion, // D-293 slice-3 — trapping-trunc NaN (UCOMI/FCMP self → JP/B.VS)
        10 => .null_reference, // D-293 slice-4b — call_ref null + ref.as_non_null (TEST/CMP → JE/B.EQ)
        11 => .cast_failure, // D-293 slice-4d — ref.cast / ref.cast_null subtype mismatch (jitGcRefCast → 0)
        12 => .uncaught_exception, // D-292 C — throw / throw_ref escaped all try_table catches (zwasm_throw .uncaught)
        13 => .uninitialized_elem, // D-294 — call_indirect on a null (uninitialized) in-bounds table elem (typeidx == maxInt sentinel → CMP/CMN → JE/B.EQ)
        14 => .unaligned_atomic, // ADR-0168 rmw/cmpxchg/wait callout helper
        15 => .expected_shared_memory, // ADR-0168 wait* on non-shared (callout)
        16 => .interrupted, // ADR-0179 #3a — JIT prologue/back-edge interruption poll stub
        17 => .out_of_fuel, // ADR-0179 #3b — JIT fuel poll stub (prologue/back-edge SUB → negative)
        // #331 — the two host-originated paths carry their own codes so the
        // generic bucket keeps meaning "the codegen has not split this yet"
        // (D-292) rather than absorbing traps the codegen never emitted.
        18 => .wasi_exit, // `wasi/jit_dispatch.zig` proc_exit
        19 => .binding_error, // `api/jit_host_bridge.zig` trapResult
        else => null, // 0 unmarked / 1 generic — still-shared bounds kinds (D-293)
    };
}

pub fn mapInterpTrap(err: anyerror) TrapKind {
    return switch (err) {
        error.Unreachable => .unreachable_,
        error.DivByZero => .div_by_zero,
        error.IntOverflow => .int_overflow,
        error.InvalidConversionToInt => .invalid_conversion,
        error.OutOfBoundsLoad, error.OutOfBoundsStore => .oob_memory,
        error.OutOfBoundsTableAccess => .oob_table,
        error.UninitializedElement => .uninitialized_elem,
        error.IndirectCallTypeMismatch => .indirect_call_mismatch,
        error.StackOverflow, error.CallStackExhausted => .stack_overflow,
        error.OutOfMemory => .out_of_memory,
        // The GC heap's 4 GiB cap (huge array.new* / struct.new) is the same
        // "allocation size too large" condition; the Zig facade already maps
        // it to OutOfMemory (#361).
        error.OutOfHeap => .out_of_memory,
        // D-293 slice-4a — Wasm 3.0 GC/typed-ref/EH traps (were mis-mapped to binding_error).
        error.NullReference => .null_reference,
        error.CastFailure => .cast_failure,
        error.UncaughtException => .uncaught_exception,
        error.UnalignedAtomic => .unaligned_atomic,
        error.ExpectedSharedMemory => .expected_shared_memory,
        // Sandboxing (ADR-0179 #3a): host cancel/timeout. Was mis-mapped to
        // binding_error ("host invocation error") — the default engine traps
        // `error.Interrupted` but the surface hid the kind.
        error.Interrupted => .interrupted,
        // Sandboxing (ADR-0179 #3b): interp fuel exhaustion (dispatch.zig
        // per-instruction decrement) — same kind as the JIT's code-17 stub.
        error.OutOfFuel => .out_of_fuel,
        // #331 — a host callback trapped, or the binding could not complete.
        error.HostTrap => .binding_error,
        // #331 — the interp's preview1 `proc_exit` thunk unwinds with this; the
        // JIT reaches the same kind through stub code 18. Without this arm the
        // `else` below reports a clean exit as an embedder failure, which is how
        // the two engines came to disagree (interp 0 vs JIT 1).
        error.WasiExit => .wasi_exit,
        else => .binding_error,
    };
}

pub fn allocTrap(alloc: std.mem.Allocator, store: ?*wasm_c_api.Store, kind: TrapKind) ?*Trap {
    const msg = trapMessageFor(kind);
    const buf = alloc.dupe(u8, msg) catch return null;
    const t = alloc.create(Trap) catch {
        alloc.free(buf);
        return null;
    };
    t.* = .{
        .store = store,
        .kind = kind,
        .message_ptr = buf.ptr,
        .message_len = buf.len,
    };
    return t;
}

// ============================================================
// C exports
// ============================================================

/// `wasm_trap_new(store, message)` — allocate a Trap whose
/// message is a copy of the byte_vec contents. Used by C hosts
/// to surface their own host-side errors as traps; the binding
/// itself prefers `allocTrap` with a `TrapKind` so it can map
/// runtime conditions to the spec-conformant strings.
pub export fn wasm_trap_new(s: ?*wasm_c_api.Store, message: ?*const wasm_c_api.ByteVec) callconv(.c) ?*Trap {
    const store = s orelse return null;
    const alloc = wasm_c_api.storeAllocator(store) orelse return null;
    const m = message orelse return null;
    const data_ptr = m.data orelse return null;
    const buf = alloc.dupe(u8, data_ptr[0..m.size]) catch return null;
    const t = alloc.create(Trap) catch {
        alloc.free(buf);
        return null;
    };
    t.* = .{
        .store = store,
        .kind = .binding_error,
        .message_ptr = buf.ptr,
        .message_len = buf.len,
    };
    return t;
}

/// `zwasm_trap_kind` (ADR-0179 #3a-4) — project extension exposing the
/// machine-readable trap kind beside upstream wasm.h's message-only
/// surface, so a C host can distinguish e.g. `interrupted` (16) and
/// `out_of_fuel` (17) from genuine guest faults without string-matching.
/// Values = the `TrapKind` enum (documented in zwasm.h); -1 on null.
pub export fn zwasm_trap_kind(t: ?*const Trap) callconv(.c) i32 {
    const trap = t orelse return -1;
    return @intCast(@intFromEnum(trap.kind));
}

/// `wasm_trap_delete(*Trap)` — free a Trap returned by any path
/// (binding-internal `allocTrap`, `wasm_trap_new`, or
/// `wasm_func_call`). Releases the message bytes first, then
/// the struct. Null-tolerant.
pub export fn wasm_trap_delete(t: ?*Trap) callconv(.c) void {
    const handle = t orelse return;
    if (handle.host_info_finalizer) |fin| fin(handle.host_info);
    const store = handle.store orelse return;
    const alloc = wasm_c_api.storeAllocator(store) orelse return;
    if (handle.ref_view) |rv| alloc.destroy(rv); // object-identity as_ref view (ADR-0158)
    if (handle.message_ptr) |p| alloc.free(p[0..handle.message_len]);
    alloc.destroy(handle);
}

/// `wasm_trap_message(*Trap, *out ByteVec)` — populate `out`
/// with a freshly-allocated copy of the trap's message (per
/// upstream wasm.h's `own` discipline: `out` becomes owned by
/// the caller and must be released via `wasm_byte_vec_delete`).
/// Writes a zero-length vec if the trap has no message or
/// allocation fails.
pub export fn wasm_trap_message(t: ?*const Trap, out: ?*wasm_c_api.ByteVec) callconv(.c) void {
    const out_ptr = out orelse return;
    out_ptr.* = .{ .size = 0, .data = null };
    const handle = t orelse return;
    const store = handle.store orelse return;
    const alloc = wasm_c_api.storeAllocator(store) orelse return;
    const ptr = handle.message_ptr orelse return;
    const copy = alloc.dupe(u8, ptr[0..handle.message_len]) catch return;
    out_ptr.* = .{ .size = copy.len, .data = copy.ptr };
}

// ============================================================
// Frames + trap stack introspection (§13.2)
//
// zwasm's Trap is a single-flag signal (TrapKind; the per-trap-kind +
// PC widening is ADR-0022 / D-022, deferred) — it does NOT capture a
// call-stack. So `wasm_trap_origin` honestly returns null and
// `wasm_trap_trace` an empty vec (the upstream contract permits a trap
// with no origin/trace). The `wasm_frame_*` surface + `frame_vec` are
// implemented for ABI completeness (a frame, if ever produced, exposes
// its fields); `instance` is held as an opaque ptr to avoid an
// instance.zig import cycle (instance.zig imports this file for Trap).
// ============================================================

pub const Frame = extern struct {
    instance: ?*anyopaque = null,
    func_index: u32 = 0,
    func_offset: usize = 0,
    module_offset: usize = 0,
};

pub const FrameVec = extern struct {
    size: usize,
    data: ?[*]?*Frame,
};

pub export fn wasm_frame_delete(f: ?*Frame) callconv(.c) void {
    if (f) |p| std.heap.c_allocator.destroy(p);
}

pub export fn wasm_frame_copy(f: ?*const Frame) callconv(.c) ?*Frame {
    const src = f orelse return null;
    const nf = std.heap.c_allocator.create(Frame) catch return null;
    nf.* = src.*;
    return nf;
}

pub export fn wasm_frame_instance(f: ?*const Frame) callconv(.c) ?*anyopaque {
    return (f orelse return null).instance;
}
pub export fn wasm_frame_func_index(f: ?*const Frame) callconv(.c) u32 {
    return (f orelse return 0).func_index;
}
pub export fn wasm_frame_func_offset(f: ?*const Frame) callconv(.c) usize {
    return (f orelse return 0).func_offset;
}
pub export fn wasm_frame_module_offset(f: ?*const Frame) callconv(.c) usize {
    return (f orelse return 0).module_offset;
}

pub export fn wasm_frame_vec_new_empty(out: ?*FrameVec) callconv(.c) void {
    (out orelse return).* = .{ .size = 0, .data = null };
}
pub export fn wasm_frame_vec_new_uninitialized(out: ?*FrameVec, size: usize) callconv(.c) void {
    const o = out orelse return;
    if (size == 0) {
        o.* = .{ .size = 0, .data = null };
        return;
    }
    const buf = std.heap.c_allocator.alloc(?*Frame, size) catch {
        o.* = .{ .size = 0, .data = null };
        return;
    };
    @memset(buf, null);
    o.* = .{ .size = size, .data = buf.ptr };
}
pub export fn wasm_frame_vec_new(out: ?*FrameVec, size: usize, src: ?[*]const ?*Frame) callconv(.c) void {
    const o = out orelse return;
    if (size == 0 or src == null) {
        o.* = .{ .size = 0, .data = null };
        return;
    }
    const buf = std.heap.c_allocator.alloc(?*Frame, size) catch {
        o.* = .{ .size = 0, .data = null };
        return;
    };
    @memcpy(buf, src.?[0..size]);
    o.* = .{ .size = size, .data = buf.ptr };
}
pub export fn wasm_frame_vec_copy(out: ?*FrameVec, src: ?*const FrameVec) callconv(.c) void {
    const o = out orelse return;
    const s = src orelse {
        o.* = .{ .size = 0, .data = null };
        return;
    };
    if (s.size == 0 or s.data == null) {
        o.* = .{ .size = 0, .data = null };
        return;
    }
    // Deep copy — each vec owns its own frames (shallow would double-free).
    const buf = std.heap.c_allocator.alloc(?*Frame, s.size) catch {
        o.* = .{ .size = 0, .data = null };
        return;
    };
    for (s.data.?[0..s.size], 0..) |opt, i| {
        buf[i] = if (opt) |fr| wasm_frame_copy(fr) else null;
    }
    o.* = .{ .size = s.size, .data = buf.ptr };
}
pub export fn wasm_frame_vec_delete(v: ?*FrameVec) callconv(.c) void {
    const handle = v orelse return;
    if (handle.data) |dp| {
        for (dp[0..handle.size]) |opt| {
            if (opt) |fr| wasm_frame_delete(fr);
        }
        std.heap.c_allocator.free(dp[0..handle.size]);
    }
    handle.* = .{ .size = 0, .data = null };
}

/// `wasm_trap_origin` — zwasm captures no stack frame for a trap → null
/// (spec permits a frame-less trap). Widening is ADR-0022 / D-022.
pub export fn wasm_trap_origin(t: ?*const Trap) callconv(.c) ?*Frame {
    _ = t;
    return null;
}

/// `wasm_trap_trace` — empty trace (no captured stack; see above).
pub export fn wasm_trap_trace(t: ?*const Trap, out: ?*FrameVec) callconv(.c) void {
    _ = t;
    (out orelse return).* = .{ .size = 0, .data = null };
}

// ============================================================
// Tests
// ============================================================

test "wasm_frame: copy/accessors + vec delete-cascade; trap origin null + trace empty" {
    var fr: Frame = .{ .instance = null, .func_index = 7, .func_offset = 16, .module_offset = 32 };
    const c = wasm_frame_copy(&fr) orelse return error.FrameCopyFailed;
    try testing.expectEqual(@as(u32, 7), wasm_frame_func_index(c));
    try testing.expectEqual(@as(usize, 16), wasm_frame_func_offset(c));
    try testing.expectEqual(@as(usize, 32), wasm_frame_module_offset(c));
    try testing.expect(wasm_frame_instance(c) == null);

    var elems = [_]?*Frame{c};
    var fv: FrameVec = undefined;
    wasm_frame_vec_new(&fv, 1, &elems);
    try testing.expectEqual(@as(usize, 1), fv.size);
    wasm_frame_vec_delete(&fv); // frees the copied frame
    try testing.expectEqual(@as(usize, 0), fv.size);

    // No stack capture → null origin + empty trace.
    try testing.expect(wasm_trap_origin(null) == null);
    var trace: FrameVec = undefined;
    wasm_trap_trace(null, &trace);
    try testing.expectEqual(@as(usize, 0), trace.size);
    wasm_frame_delete(null); // null-tolerant
}

test "wasm_frame_vec_copy: deep-independent copy + null discipline" {
    var fr0: Frame = .{ .instance = null, .func_index = 1, .func_offset = 8, .module_offset = 16 };
    var fr1: Frame = .{ .instance = null, .func_index = 2, .func_offset = 24, .module_offset = 48 };
    var elems = [_]?*Frame{ wasm_frame_copy(&fr0), wasm_frame_copy(&fr1) };
    var v: FrameVec = undefined;
    wasm_frame_vec_new(&v, elems.len, &elems);
    var c: FrameVec = undefined;
    wasm_frame_vec_copy(&c, &v);
    try testing.expectEqual(@as(usize, 2), c.size);
    try testing.expect(v.data.? != c.data.?); // independent array
    try testing.expect(v.data.?[1].? != c.data.?[1].?); // independent frames (deep copy)
    try testing.expectEqual(@as(u32, 2), wasm_frame_func_index(c.data.?[1].?));
    wasm_frame_vec_delete(&v);
    wasm_frame_vec_delete(&c);
    wasm_frame_vec_copy(null, null); // null-tolerant
}

test "wasm_trap_new / message / delete: round-trip from caller-supplied message" {
    const e = wasm_c_api.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_c_api.wasm_engine_delete(e);
    const s = wasm_c_api.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_c_api.wasm_store_delete(s);

    var msg_bytes = "host failure".*;
    const msg_bv: wasm_c_api.ByteVec = .{ .size = msg_bytes.len, .data = &msg_bytes };
    const trap = wasm_trap_new(s, &msg_bv) orelse return error.TrapAllocFailed;
    defer wasm_trap_delete(trap);

    var out: wasm_c_api.ByteVec = .{ .size = 0, .data = null };
    wasm_trap_message(trap, &out);
    defer wasm_c_api.wasm_byte_vec_delete(&out);
    try testing.expectEqual(@as(usize, 12), out.size);
    try testing.expectEqualStrings("host failure", out.data.?[0..out.size]);
}

test "jitTrapCode: precise codes map to interp-parity kinds; generic bucket is null (ADR-0164 A)" {
    try testing.expectEqual(TrapKind.oob_table, jitTrapCode(2).?);
    try testing.expectEqual(TrapKind.indirect_call_mismatch, jitTrapCode(3).?);
    try testing.expectEqual(TrapKind.stack_overflow, jitTrapCode(4).?);
    // D-292 widening — `unreachable` is the first of the common traps to leave the
    // generic bucket for a precise per-kind code (5), unified across arm64+x86_64.
    try testing.expectEqual(TrapKind.unreachable_, jitTrapCode(5).?);
    try testing.expectEqual(TrapKind.div_by_zero, jitTrapCode(7).?);
    try testing.expectEqual(TrapKind.int_overflow, jitTrapCode(8).?);
    try testing.expectEqual(TrapKind.oob_memory, jitTrapCode(6).?);
    // D-293 slice-3 — trapping-trunc NaN gets a precise code 9 (invalid_conversion).
    try testing.expectEqual(TrapKind.invalid_conversion, jitTrapCode(9).?);
    // 0 (unmarked) + 1 (generic) remain the legacy bucket — the still-shared
    // bounds_fixups kinds (null_reference / cast_failure / array_oob; see D-293).
    try testing.expect(jitTrapCode(0) == null);
    try testing.expect(jitTrapCode(1) == null);
    // Precise codes reuse the interp message table — true parity.
    try testing.expectEqualStrings("indirect call type mismatch", trapMessageFor(jitTrapCode(3).?));
}

test "mapInterpTrap: Wasm 3.0 GC/typed-ref/EH traps surface their precise kind (D-293 slice-4a)" {
    // Were mis-mapped to binding_error ("host invocation error") before slice-4a —
    // the interp itself gave the wrong message for a genuine wasm null-reference trap.
    try testing.expectEqual(TrapKind.null_reference, mapInterpTrap(error.NullReference));
    try testing.expectEqual(TrapKind.cast_failure, mapInterpTrap(error.CastFailure));
    try testing.expectEqual(TrapKind.uncaught_exception, mapInterpTrap(error.UncaughtException));
    try testing.expectEqualStrings("null reference", trapMessageFor(.null_reference));
    try testing.expectEqualStrings("cast failure", trapMessageFor(.cast_failure));
    try testing.expectEqualStrings("uncaught exception", trapMessageFor(.uncaught_exception));
    // Unmapped host errors still fall back to binding_error.
    try testing.expectEqual(TrapKind.binding_error, mapInterpTrap(error.SomeHostThing));
}

test "interrupted (ADR-0179 #3a): interp error + JIT code 16 both surface the same kind+message" {
    // The interp engine traps `error.Interrupted` on a host cancel/timeout;
    // it previously fell through to binding_error.
    try testing.expectEqual(TrapKind.interrupted, mapInterpTrap(error.Interrupted));
    // JIT stub code 16 maps to the same kind (the prologue/back-edge poll).
    try testing.expectEqual(TrapKind.interrupted, jitTrapCode(16).?);
    // Both paths reuse one message table → interp/JIT parity.
    try testing.expectEqualStrings("interrupted", trapMessageFor(.interrupted));
}

test "wasm_trap_*: null-arg discipline" {
    try testing.expect(wasm_trap_new(null, null) == null);
    wasm_trap_delete(null);
    var out: wasm_c_api.ByteVec = .{ .size = 0, .data = null };
    wasm_trap_message(null, &out);
    try testing.expectEqual(@as(usize, 0), out.size);
    wasm_c_api.wasm_byte_vec_delete(null);
}

// C-ABI drift guard for `include/zwasm.h` ZWASM_TRAP_* vs this `TrapKind` enum
// is mechanized cross-artifact by `scripts/check_trap_abi_sync.sh` (gate_commit):
// @embedFile can't reach include/ (outside the src package), so the C header ↔
// Zig enum value match is checked at the build-gate, not in a unit test.
