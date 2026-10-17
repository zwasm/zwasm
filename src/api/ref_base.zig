//! `WASM_DECLARE_REF_BASE` / `WASM_DECLARE_REF` surface — the `wasm_X_same`
//! identity tests (this file, E3b-1), and (later sub-chunks) `wasm_X_as_ref` /
//! `wasm_ref_as_X` casts + `wasm_X_copy` clones, for the entity handles
//! func / global / table / memory / extern / instance / module / trap / foreign.
//!
//! Model: ADR-0158. `same` is ENTITY identity, not pointer identity, because
//! `wasm_instance_exports` returns a fresh handle each call — two handles to the
//! same export must compare same. Instance-backed func/global/table/memory
//! compare `(instance, idx)`; standalone (host-created, no instance) compare
//! pointer identity (the handle IS the entity); instance/module/trap/foreign are
//! pointer-identity objects. `wasm_ref_same` (funcref/externref payload) stays in
//! `extern_new.zig`.
//!
//! Zone 3 (`src/api/`); re-exported via `api/wasm.zig`.

const std = @import("std");
const testing = std.testing;

const handles = @import("handles.zig");
const instance = @import("instance.zig");
const trap_surface = @import("trap_surface.zig");
const trap_trace = @import("../interp/trap_trace.zig");
const extern_new = @import("extern_new.zig");
const types = @import("types.zig"); // test-only: build types for as_ref round-trips
const vec = @import("vec.zig"); // test-only: ByteVec/ExternVec for the extern/module round-trip

/// Entity identity for the instance-backed handles (func/global/table/memory):
/// same iff both are backed by the same instance AND the same index; a
/// standalone handle (no instance) is identity-compared by pointer.
fn entitySame(comptime T: type, a: ?*const T, b: ?*const T, comptime idx_field: []const u8) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    if (x.instance) |xi| {
        const yi = y.instance orelse return false; // x instance-backed, y standalone → distinct
        return xi == yi and @field(x, idx_field) == @field(y, idx_field);
    }
    return x == y; // standalone → pointer identity
}

/// Pointer identity for the per-object handles (instance/module/trap/foreign).
fn ptrSame(comptime T: type, a: ?*const T, b: ?*const T) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return x == y;
}

pub export fn wasm_func_same(a: ?*const handles.Func, b: ?*const handles.Func) callconv(.c) bool {
    return entitySame(handles.Func, a, b, "func_idx");
}
pub export fn wasm_global_same(a: ?*const handles.Global, b: ?*const handles.Global) callconv(.c) bool {
    return entitySame(handles.Global, a, b, "global_idx");
}
pub export fn wasm_table_same(a: ?*const handles.Table, b: ?*const handles.Table) callconv(.c) bool {
    return entitySame(handles.Table, a, b, "table_idx");
}
pub export fn wasm_memory_same(a: ?*const handles.Memory, b: ?*const handles.Memory) callconv(.c) bool {
    return entitySame(handles.Memory, a, b, "memory_idx");
}

/// extern same: same kind AND the wrapped entity same (delegates per kind).
pub export fn wasm_extern_same(a: ?*const handles.Extern, b: ?*const handles.Extern) callconv(.c) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    if (x.kind != y.kind) return false;
    return switch (x.kind) {
        .func => wasm_func_same(x.func, y.func),
        .global => wasm_global_same(x.global, y.global),
        .table => wasm_table_same(x.table, y.table),
        .memory => wasm_memory_same(x.memory, y.memory),
    };
}

pub export fn wasm_instance_same(a: ?*const instance.Instance, b: ?*const instance.Instance) callconv(.c) bool {
    return ptrSame(instance.Instance, a, b);
}
pub export fn wasm_module_same(a: ?*const instance.Module, b: ?*const instance.Module) callconv(.c) bool {
    return ptrSame(instance.Module, a, b);
}
pub export fn wasm_trap_same(a: ?*const trap_surface.Trap, b: ?*const trap_surface.Trap) callconv(.c) bool {
    return ptrSame(trap_surface.Trap, a, b);
}
pub export fn wasm_foreign_same(a: ?*const extern_new.Foreign, b: ?*const extern_new.Foreign) callconv(.c) bool {
    return ptrSame(extern_new.Foreign, a, b);
}

// ===========================================================================
// as_ref / ref_as (+const) — ADR-0158. A handle's `as_ref` returns a borrowed
// `ref_view` Ref whose payload is `@intFromPtr(handle)` (object identity);
// `ref_as_X` recovers it via `@ptrFromInt` (caller-guarantees-type, exactly as
// `wasm_ref_as_foreign`). The view is cached on the handle + freed in its
// `wasm_X_delete`. func/foreign as_ref live in extern_new.zig (funcref/externref
// payload, not object identity). This chunk: global/table/memory; extern/module/
// trap/instance follow (instance needs the Zone-1 anyopaque ref_view workaround).
// ===========================================================================

/// Cached object-identity `ref_view` for `handle` (payload `@intFromPtr(obj)`).
/// `store` is the handle's owning store (instance-backed → instance.store;
/// standalone → handle.store). Null store/OOM → null.
fn objAsRef(store: ?*instance.Store, obj: *const anyopaque, slot: *?*handles.Ref) ?*handles.Ref {
    if (slot.*) |rv| return rv;
    const s = store orelse return null;
    const alloc = instance.storeAllocator(s) orelse return null;
    const rv = alloc.create(handles.Ref) catch return null;
    rv.* = .{ .instance = null, .ref = @intFromPtr(obj), .store = s };
    slot.* = rv;
    return rv;
}

fn storeOf(inst: ?*instance.Instance, standalone: ?*instance.Store) ?*instance.Store {
    if (inst) |i| return i.store;
    return standalone;
}

pub export fn wasm_global_as_ref(g: ?*handles.Global) callconv(.c) ?*handles.Ref {
    const h = g orelse return null;
    return objAsRef(storeOf(h.instance, h.store), h, &h.ref_view);
}
pub export fn wasm_ref_as_global(r: ?*handles.Ref) callconv(.c) ?*handles.Global {
    const h = r orelse return null;
    if (h.ref == 0) return null;
    return @ptrFromInt(h.ref);
}
pub export fn wasm_global_as_ref_const(g: ?*const handles.Global) callconv(.c) ?*const handles.Ref {
    return wasm_global_as_ref(@constCast(g));
}
pub export fn wasm_ref_as_global_const(r: ?*const handles.Ref) callconv(.c) ?*const handles.Global {
    return wasm_ref_as_global(@constCast(r));
}

pub export fn wasm_table_as_ref(t: ?*handles.Table) callconv(.c) ?*handles.Ref {
    const h = t orelse return null;
    return objAsRef(storeOf(h.instance, h.store), h, &h.ref_view);
}
pub export fn wasm_ref_as_table(r: ?*handles.Ref) callconv(.c) ?*handles.Table {
    const h = r orelse return null;
    if (h.ref == 0) return null;
    return @ptrFromInt(h.ref);
}
pub export fn wasm_table_as_ref_const(t: ?*const handles.Table) callconv(.c) ?*const handles.Ref {
    return wasm_table_as_ref(@constCast(t));
}
pub export fn wasm_ref_as_table_const(r: ?*const handles.Ref) callconv(.c) ?*const handles.Table {
    return wasm_ref_as_table(@constCast(r));
}

pub export fn wasm_memory_as_ref(m: ?*handles.Memory) callconv(.c) ?*handles.Ref {
    const h = m orelse return null;
    return objAsRef(storeOf(h.instance, h.store), h, &h.ref_view);
}
pub export fn wasm_ref_as_memory(r: ?*handles.Ref) callconv(.c) ?*handles.Memory {
    const h = r orelse return null;
    if (h.ref == 0) return null;
    return @ptrFromInt(h.ref);
}
pub export fn wasm_memory_as_ref_const(m: ?*const handles.Memory) callconv(.c) ?*const handles.Ref {
    return wasm_memory_as_ref(@constCast(m));
}
pub export fn wasm_ref_as_memory_const(r: ?*const handles.Ref) callconv(.c) ?*const handles.Memory {
    return wasm_ref_as_memory(@constCast(r));
}

pub export fn wasm_extern_as_ref(e: ?*handles.Extern) callconv(.c) ?*handles.Ref {
    const h = e orelse return null;
    return objAsRef(storeOf(h.instance, null), h, &h.ref_view); // host-extern (null instance) → null
}
pub export fn wasm_ref_as_extern(r: ?*handles.Ref) callconv(.c) ?*handles.Extern {
    const h = r orelse return null;
    if (h.ref == 0) return null;
    return @ptrFromInt(h.ref);
}
pub export fn wasm_extern_as_ref_const(e: ?*const handles.Extern) callconv(.c) ?*const handles.Ref {
    return wasm_extern_as_ref(@constCast(e));
}
pub export fn wasm_ref_as_extern_const(r: ?*const handles.Ref) callconv(.c) ?*const handles.Extern {
    return wasm_ref_as_extern(@constCast(r));
}

pub export fn wasm_module_as_ref(m: ?*instance.Module) callconv(.c) ?*handles.Ref {
    const h = m orelse return null;
    return objAsRef(h.store, h, &h.ref_view);
}
pub export fn wasm_ref_as_module(r: ?*handles.Ref) callconv(.c) ?*instance.Module {
    const h = r orelse return null;
    if (h.ref == 0) return null;
    return @ptrFromInt(h.ref);
}
pub export fn wasm_module_as_ref_const(m: ?*const instance.Module) callconv(.c) ?*const handles.Ref {
    return wasm_module_as_ref(@constCast(m));
}
pub export fn wasm_ref_as_module_const(r: ?*const handles.Ref) callconv(.c) ?*const instance.Module {
    return wasm_ref_as_module(@constCast(r));
}

pub export fn wasm_trap_as_ref(t: ?*trap_surface.Trap) callconv(.c) ?*handles.Ref {
    const h = t orelse return null;
    return objAsRef(h.store, h, &h.ref_view);
}
pub export fn wasm_ref_as_trap(r: ?*handles.Ref) callconv(.c) ?*trap_surface.Trap {
    const h = r orelse return null;
    if (h.ref == 0) return null;
    return @ptrFromInt(h.ref);
}
pub export fn wasm_trap_as_ref_const(t: ?*const trap_surface.Trap) callconv(.c) ?*const handles.Ref {
    return wasm_trap_as_ref(@constCast(t));
}
pub export fn wasm_ref_as_trap_const(r: ?*const handles.Ref) callconv(.c) ?*const trap_surface.Trap {
    return wasm_ref_as_trap(@constCast(r));
}

/// `objAsRef` variant for a handle whose `ref_view` slot is `?*anyopaque`
/// (instance — a `?*Ref` field on the Zone-1 `runtime.Instance` would be an
/// upward import). The Zone-3 binding casts the slot to/from `*Ref`.
fn objAsRefOpaque(store: ?*instance.Store, obj: *const anyopaque, slot: *?*anyopaque) ?*handles.Ref {
    if (slot.*) |rv| return @ptrCast(@alignCast(rv));
    const s = store orelse return null;
    const alloc = instance.storeAllocator(s) orelse return null;
    const rv = alloc.create(handles.Ref) catch return null;
    rv.* = .{ .instance = null, .ref = @intFromPtr(obj), .store = s };
    slot.* = @ptrCast(rv);
    return rv;
}

pub export fn wasm_instance_as_ref(inst: ?*instance.Instance) callconv(.c) ?*handles.Ref {
    const h = inst orelse return null;
    return objAsRefOpaque(h.store, h, &h.ref_view);
}
pub export fn wasm_ref_as_instance(r: ?*handles.Ref) callconv(.c) ?*instance.Instance {
    const h = r orelse return null;
    if (h.ref == 0) return null;
    return @ptrFromInt(h.ref);
}
pub export fn wasm_instance_as_ref_const(inst: ?*const instance.Instance) callconv(.c) ?*const handles.Ref {
    return wasm_instance_as_ref(@constCast(inst));
}
pub export fn wasm_ref_as_instance_const(r: ?*const handles.Ref) callconv(.c) ?*const instance.Instance {
    return wasm_ref_as_instance(@constCast(r));
}

// ===========================================================================
// copy (ADR-0158). An INSTANCE-BACKED func/global/table/memory handle owns only
// `(instance, idx)` (+ lazy cached views) — a fresh handle copying those, with
// the view caches nulled, is independently deletable + denotes the same entity
// (no shared ownership → no double-free). A STANDALONE handle (host-created,
// owns Func.host / Global.cell / Table.tinst / Memory.minst) cannot be safely
// duplicated without a per-store registry → returns null (D-253-D, documented;
// not a silent wrong-clone). extern/module/trap/instance/foreign copy land next.
// ===========================================================================

fn cloneEntity(comptime T: type, h: ?*const T) ?*T {
    const src = h orelse return null;
    const i = src.instance orelse return null; // standalone (owns backing) → D-253-D
    const store = i.store orelse return null;
    const alloc = instance.storeAllocator(store) orelse return null;
    const c = alloc.create(T) catch return null;
    c.* = src.*;
    c.extern_view = null; // the copy gets its own lazy views
    c.ref_view = null;
    return c;
}

pub export fn wasm_func_copy(f: ?*const handles.Func) callconv(.c) ?*handles.Func {
    return cloneEntity(handles.Func, f);
}
pub export fn wasm_global_copy(g: ?*const handles.Global) callconv(.c) ?*handles.Global {
    return cloneEntity(handles.Global, g);
}
pub export fn wasm_table_copy(t: ?*const handles.Table) callconv(.c) ?*handles.Table {
    return cloneEntity(handles.Table, t);
}
pub export fn wasm_memory_copy(m: ?*const handles.Memory) callconv(.c) ?*handles.Memory {
    return cloneEntity(handles.Memory, m);
}

/// `wasm_extern_copy` — instance-backed → new Extern + a clone of the contained
/// handle (the copy owns it), borrowed=false, caches nulled. Borrowed views /
/// standalone (null instance) → null (D-253-D).
pub export fn wasm_extern_copy(e: ?*const handles.Extern) callconv(.c) ?*handles.Extern {
    const src = e orelse return null;
    if (src.borrowed) return null;
    const i = src.instance orelse return null;
    const store = i.store orelse return null;
    const alloc = instance.storeAllocator(store) orelse return null;
    const c = alloc.create(handles.Extern) catch return null;
    c.* = src.*;
    c.borrowed = false;
    c.ref_view = null;
    c.host_info = null;
    c.host_info_finalizer = null;
    c.func = null;
    c.global = null;
    c.memory = null;
    c.table = null;
    switch (src.kind) {
        .func => c.func = wasm_func_copy(src.func),
        .global => c.global = wasm_global_copy(src.global),
        .table => c.table = wasm_table_copy(src.table),
        .memory => c.memory = wasm_memory_copy(src.memory),
    }
    return c;
}

/// `wasm_module_copy` — fresh independent handle over a DUP of the bytes (so both
/// delete their own); caches nulled. Standalone module-handle (no instance back-
/// ref needed — it is a byte holder + store).
pub export fn wasm_module_copy(m: ?*const instance.Module) callconv(.c) ?*instance.Module {
    const src = m orelse return null;
    const store = src.store orelse return null;
    const alloc = instance.storeAllocator(store) orelse return null;
    const c = alloc.create(instance.Module) catch return null;
    c.* = src.*;
    c.host_info = null;
    c.host_info_finalizer = null;
    c.ref_view = null;
    if (src.bytes_ptr) |p| {
        const dup = alloc.alloc(u8, src.bytes_len) catch {
            alloc.destroy(c);
            return null;
        };
        @memcpy(dup, p[0..src.bytes_len]);
        c.bytes_ptr = dup.ptr;
    }
    return c;
}

/// `wasm_trap_copy` — fresh handle over a DUP of the message; caches nulled.
pub export fn wasm_trap_copy(t: ?*const trap_surface.Trap) callconv(.c) ?*trap_surface.Trap {
    const src = t orelse return null;
    const store = src.store orelse return null;
    const alloc = instance.storeAllocator(store) orelse return null;
    const c = alloc.create(trap_surface.Trap) catch return null;
    c.* = src.*;
    c.host_info = null;
    c.host_info_finalizer = null;
    c.ref_view = null;
    if (src.message_ptr) |p| {
        const dup = alloc.alloc(u8, src.message_len) catch {
            alloc.destroy(c);
            return null;
        };
        @memcpy(dup, p[0..src.message_len]);
        c.message_ptr = dup.ptr;
    }
    if (src.trace_ptr) |p| {
        const dup = alloc.dupe(trap_trace.Frame, p[0..src.trace_len]) catch {
            if (c.message_ptr) |m| alloc.free(m[0..c.message_len]);
            alloc.destroy(c);
            return null;
        };
        c.trace_ptr = dup.ptr;
    }
    return c;
}

/// `wasm_instance_copy` — null. An Instance owns its arena/runtime/zombie state;
/// a safe duplicate needs refcounting or a per-store registry (D-253-D). zwasm
/// does not refcount instances, so this is an honest documented limitation.
pub export fn wasm_instance_copy(_: ?*const instance.Instance) callconv(.c) ?*instance.Instance {
    return null;
}

/// `wasm_extern_vec_copy` — deep-copy each extern via `wasm_extern_copy`
/// (shallow would double-free on `wasm_extern_vec_delete`). Now unblocked by
/// `wasm_extern_copy`.
pub export fn wasm_extern_vec_copy(out: ?*vec.ExternVec, src: ?*const vec.ExternVec) callconv(.c) void {
    const o = out orelse return;
    const s = src orelse {
        o.* = .{ .size = 0, .data = null };
        return;
    };
    if (s.size == 0 or s.data == null) {
        o.* = .{ .size = 0, .data = null };
        return;
    }
    const buf = std.heap.c_allocator.alloc(?*handles.Extern, s.size) catch {
        o.* = .{ .size = 0, .data = null };
        return;
    };
    for (s.data.?[0..s.size], 0..) |opt, i| {
        buf[i] = if (opt) |ext| wasm_extern_copy(ext) else null;
    }
    o.* = .{ .size = s.size, .data = buf.ptr };
}

test "wasm_X_same: entity-identity (func/global/table/memory) + pointer (instance/module/trap/foreign)" {
    const inst_a: *instance.Instance = @ptrFromInt(0x1000); // fake, never deref'd by `same`
    var f1: handles.Func = .{ .instance = inst_a, .func_idx = 3 };
    var f2: handles.Func = .{ .instance = inst_a, .func_idx = 3 }; // same entity, distinct handle
    var f3: handles.Func = .{ .instance = inst_a, .func_idx = 4 };
    try testing.expect(wasm_func_same(&f1, &f2)); // (instance, idx) match
    try testing.expect(!wasm_func_same(&f1, &f3)); // idx differs
    var fs1: handles.Func = .{ .instance = null, .func_idx = 0 };
    var fs2: handles.Func = .{ .instance = null, .func_idx = 0 };
    try testing.expect(wasm_func_same(&fs1, &fs1)); // standalone → pointer identity
    try testing.expect(!wasm_func_same(&fs1, &fs2));
    try testing.expect(!wasm_func_same(&f1, &fs1)); // instance-backed vs standalone

    var g1: handles.Global = .{ .instance = inst_a, .global_idx = 1, .valtype = .i32, .mutable = false };
    var g2: handles.Global = .{ .instance = inst_a, .global_idx = 1, .valtype = .i32, .mutable = true };
    try testing.expect(wasm_global_same(&g1, &g2)); // identity ignores cached valtype/mutable

    var e1: handles.Extern = .{ .kind = .func, .instance = inst_a, .func = &f1 };
    var e2: handles.Extern = .{ .kind = .func, .instance = inst_a, .func = &f2 };
    var e3: handles.Extern = .{ .kind = .global, .instance = inst_a, .global = &g1 };
    try testing.expect(wasm_extern_same(&e1, &e2)); // same kind + same func entity
    try testing.expect(!wasm_extern_same(&e1, &e3)); // kind differs

    const ti: *trap_surface.Trap = @ptrFromInt(0x2000);
    try testing.expect(wasm_trap_same(ti, ti));
    try testing.expect(!wasm_trap_same(ti, @ptrFromInt(0x3000)));

    // null discipline (two nulls same; one null distinct).
    try testing.expect(wasm_func_same(null, null));
    try testing.expect(!wasm_func_same(&f1, null));
    try testing.expect(wasm_instance_same(null, null));
    try testing.expect(wasm_module_same(null, null));
    try testing.expect(wasm_foreign_same(null, null));
}

test "as_ref / ref_as round-trip (global/table/memory) — object identity + cache + null discipline" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    // memory — full round-trip + cache + lifetime.
    var mlim: types.Limits = .{ .min = 1, .max = 0xffff_ffff };
    const mt = types.wasm_memorytype_new(&mlim) orelse return error.MemTypeAllocFailed;
    defer types.wasm_memorytype_delete(mt);
    const mem = extern_new.wasm_memory_new(s, mt) orelse return error.MemoryAllocFailed;
    const mref = wasm_memory_as_ref(mem) orelse return error.NoRef;
    try testing.expectEqual(mem, wasm_ref_as_memory(mref).?); // round-trip → same handle
    try testing.expectEqual(mref, wasm_memory_as_ref(mem).?); // cached view (same Ref)
    instance.wasm_memory_delete(mem); // frees the ref_view (no leak/UAF)

    // global — round-trip.
    const gt = types.wasm_globaltype_new(types.wasm_valtype_new(0), 0) orelse return error.GtAllocFailed;
    defer types.wasm_globaltype_delete(gt);
    var gval: instance.Val = .{ .kind = .i32, .of = .{ .i32 = 7 } };
    const glob = extern_new.wasm_global_new(s, gt, &gval) orelse return error.GlobalAllocFailed;
    const gref = wasm_global_as_ref(glob) orelse return error.NoRef;
    try testing.expectEqual(glob, wasm_ref_as_global(gref).?);
    instance.wasm_global_delete(glob);

    // table — round-trip.
    var tlim: types.Limits = .{ .min = 1, .max = 0xffff_ffff };
    const tt = types.wasm_tabletype_new(types.wasm_valtype_new(129), &tlim) orelse return error.TtAllocFailed;
    defer types.wasm_tabletype_delete(tt);
    const tbl = extern_new.wasm_table_new(s, tt, null) orelse return error.TableAllocFailed;
    const tref = wasm_table_as_ref(tbl) orelse return error.NoRef;
    try testing.expectEqual(tbl, wasm_ref_as_table(tref).?);
    instance.wasm_table_delete(tbl);

    // null discipline.
    try testing.expect(wasm_memory_as_ref(null) == null);
    try testing.expect(wasm_ref_as_memory(null) == null);
    try testing.expect(wasm_global_as_ref(null) == null);
}

test "as_ref / ref_as round-trip (extern + module) — object identity" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    // module — round-trip via an empty `(module)`.
    var mbytes = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const mbv: vec.ByteVec = .{ .size = mbytes.len, .data = &mbytes };
    const m = instance.wasm_module_new(s, &mbv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const mref = wasm_module_as_ref(m) orelse return error.NoRef;
    try testing.expectEqual(m, wasm_ref_as_module(mref).?);
    try testing.expectEqual(mref, wasm_module_as_ref(m).?); // cached

    // extern — instance-backed memory export `(module (memory (export "m") 1))`.
    var ebytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01, // memory: min 1
        0x07, 0x05, 0x01, 0x01, 0x6d, 0x02, 0x00, // export "m" → memory 0
    };
    const ebv: vec.ByteVec = .{ .size = ebytes.len, .data = &ebytes };
    const em = instance.wasm_module_new(s, &ebv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(em);
    const inst = instance.wasm_instance_new(s, em, null, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);
    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const ext = exports.data.?[0].?;
    const eref = wasm_extern_as_ref(ext) orelse return error.NoRef;
    try testing.expectEqual(ext, wasm_ref_as_extern(eref).?); // round-trip (ref_view freed by extern_vec_delete)

    try testing.expect(wasm_extern_as_ref(null) == null);
    try testing.expect(wasm_module_as_ref(null) == null);
}

test "as_ref / ref_as round-trip (trap + instance) — object identity, ?*anyopaque ref_view" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    // trap (?*Ref ref_view).
    var msg = [_]u8{ 'o', 'o', 'p', 's', 0 };
    const mv: vec.ByteVec = .{ .size = msg.len, .data = &msg };
    const tr = trap_surface.wasm_trap_new(s, &mv) orelse return error.TrapAllocFailed;
    const tref = wasm_trap_as_ref(tr) orelse return error.NoRef;
    try testing.expectEqual(tr, wasm_ref_as_trap(tref).?);
    try testing.expectEqual(tref, wasm_trap_as_ref(tr).?); // cached
    trap_surface.wasm_trap_delete(tr); // frees ref_view

    // instance (?*anyopaque ref_view on the Zone-1 runtime Instance).
    var ibytes = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const ibv: vec.ByteVec = .{ .size = ibytes.len, .data = &ibytes };
    const m = instance.wasm_module_new(s, &ibv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const inst = instance.wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    const iref = wasm_instance_as_ref(inst) orelse return error.NoRef;
    try testing.expectEqual(inst, wasm_ref_as_instance(iref).?);
    try testing.expectEqual(iref, wasm_instance_as_ref(inst).?); // cached
    instance.wasm_instance_delete(inst); // frees ref_view (anyopaque cast)

    try testing.expect(wasm_trap_as_ref(null) == null);
    try testing.expect(wasm_instance_as_ref(null) == null);
}

test "wasm_X_copy: instance-backed clone is same-entity + independently deletable; standalone → null" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    // instance-backed memory (from a memory-export module) → clone same entity.
    var ebytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01, // memory min 1
        0x07, 0x05, 0x01, 0x01, 0x6d, 0x02, 0x00, // export "m" → memory 0
    };
    const ebv: vec.ByteVec = .{ .size = ebytes.len, .data = &ebytes };
    const em = instance.wasm_module_new(s, &ebv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(em);
    const inst = instance.wasm_instance_new(s, em, null, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);
    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const mem = instance.wasm_extern_as_memory(exports.data.?[0]) orelse return error.NotMemory;
    const cp = wasm_memory_copy(mem) orelse return error.NoCopy;
    try testing.expect(cp != mem); // distinct handle
    try testing.expect(wasm_memory_same(mem, cp)); // same (instance, idx) entity
    instance.wasm_memory_delete(cp); // independently deletable (no double-free)

    // standalone memory → null (D-253-D: owns its backing, can't clone w/o registry).
    var mlim: types.Limits = .{ .min = 1, .max = 0xffff_ffff };
    const mt = types.wasm_memorytype_new(&mlim) orelse return error.MemTypeAllocFailed;
    defer types.wasm_memorytype_delete(mt);
    const sm = extern_new.wasm_memory_new(s, mt) orelse return error.MemoryAllocFailed;
    defer instance.wasm_memory_delete(sm);
    try testing.expect(wasm_memory_copy(sm) == null);

    try testing.expect(wasm_func_copy(null) == null);
}

test "wasm_X_copy (extern/module/trap deep-clone; instance/foreign null) + extern_vec_copy" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    // module copy — dup bytes, independently deletable.
    var mbytes = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const mbv: vec.ByteVec = .{ .size = mbytes.len, .data = &mbytes };
    const m = instance.wasm_module_new(s, &mbv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const mc = wasm_module_copy(m) orelse return error.NoCopy;
    try testing.expect(mc != m);
    instance.wasm_module_delete(mc); // independent (owns its own bytes dup)

    // trap copy — dup message.
    var tmsg = [_]u8{ 'x', 0 };
    const tmv: vec.ByteVec = .{ .size = tmsg.len, .data = &tmsg };
    const tr = trap_surface.wasm_trap_new(s, &tmv) orelse return error.TrapAllocFailed;
    defer trap_surface.wasm_trap_delete(tr);
    const tc = wasm_trap_copy(tr) orelse return error.NoCopy;
    try testing.expect(tc != tr);
    trap_surface.wasm_trap_delete(tc);

    // foreign copy → null (D-253-D).
    const fr = extern_new.wasm_foreign_new(s) orelse return error.ForeignAllocFailed;
    defer extern_new.wasm_foreign_delete(fr);
    try testing.expect(extern_new.wasm_foreign_copy(fr) == null);

    // extern copy + extern_vec_copy + instance copy(null) via a memory-export module.
    var ebytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x05, 0x01,
        0x01, 0x6d, 0x02, 0x00,
    };
    const ebv: vec.ByteVec = .{ .size = ebytes.len, .data = &ebytes };
    const em = instance.wasm_module_new(s, &ebv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(em);
    const inst = instance.wasm_instance_new(s, em, null, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);
    try testing.expect(wasm_instance_copy(inst) == null); // D-253-D

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const ext = exports.data.?[0].?;
    const ec = wasm_extern_copy(ext) orelse return error.NoCopy;
    try testing.expect(ec != ext);
    try testing.expect(wasm_extern_same(ext, ec)); // clone denotes same entity
    instance.wasm_extern_delete(ec); // independent (owns its cloned contained memory)

    var ev2: vec.ExternVec = .{ .size = 0, .data = null };
    wasm_extern_vec_copy(&ev2, &exports);
    defer instance.wasm_extern_vec_delete(&ev2);
    try testing.expectEqual(exports.size, ev2.size);
    try testing.expect(ev2.data.?[0].? != exports.data.?[0].?); // distinct extern handles
}
