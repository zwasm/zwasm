// FILE-SIZE-EXEMPT: 53% in-file C-ABI round-trip tests (P4-alone insufficient); impl is the closed §13.2 constructor set (investigated 2026-08-12, per ADR-0099)
//! Runtime-entity construction layer of the C ABI (§13.2): the
//! `wasm_{func,global,table,memory}_as_extern[_const]` conversions
//! (entity → Extern) + the host-side `wasm_{global,table,memory}_new`
//! and `wasm_func_new[_with_env]` constructors.
//!
//! Extracted from `instance.zig` per ADR-0099 §D2 (the `module_introspect.zig`
//! precedent): instance.zig sits at its 3200 FILE-SIZE-EXEMPT cap, and the
//! entity-construction surface is a cohesive separable concern. One-way
//! dependency on `instance.zig` (no cycle): this file imports the entity +
//! Extern types; instance.zig never imports back.
//!
//! Because Func / Global / Table / Memory are SEPARATE structs from Extern
//! (not a reinterpret cast as in upstream wasm-c-api), `*_as_extern` WRAPS
//! the entity in a borrowed-view Extern cached on the entity's `extern_view`
//! field — repeat calls return the same pointer, the entity stays the sole
//! owner (freeing the view in its own delete), and `wasm_extern_delete`
//! no-ops on a view (`Extern.borrowed`) so a C host can't double-free.
//!
//! Zone 3 — same as the rest of `src/api/`.

const std = @import("std");
const testing = std.testing;

const instance = @import("instance.zig");
const vec = @import("vec.zig");
const types = @import("types.zig");
const runtime = @import("../runtime/runtime.zig");
const memory_backing = @import("../runtime/instance/memory_backing.zig");
const zir = @import("../ir/zir.zig");
const trap_surface = @import("trap_surface.zig");
const module_introspect = @import("module_introspect.zig");

const Extern = instance.Extern;
const Func = instance.Func;
const Global = instance.Global;
const Table = instance.Table;
const Memory = instance.Memory;

pub export fn wasm_func_as_extern(f: ?*Func) callconv(.c) ?*Extern {
    const handle = f orelse return null;
    if (handle.extern_view) |v| return v;
    // instance (export-derived) OR Store (standalone host func).
    const store = if (handle.instance) |i| (i.store orelse return null) else (handle.store orelse return null);
    const alloc = instance.storeAllocator(store) orelse return null;
    const v = alloc.create(Extern) catch return null;
    v.* = .{ .kind = .func, .instance = handle.instance, .func = handle, .borrowed = true };
    handle.extern_view = v;
    return v;
}

pub export fn wasm_global_as_extern(g: ?*Global) callconv(.c) ?*Extern {
    const handle = g orelse return null;
    if (handle.extern_view) |v| return v;
    // Allocator comes from the instance (export-derived) OR the Store
    // (standalone host global from `wasm_global_new`, instance == null).
    const store = if (handle.instance) |i| (i.store orelse return null) else (handle.store orelse return null);
    const alloc = instance.storeAllocator(store) orelse return null;
    const v = alloc.create(Extern) catch return null;
    v.* = .{ .kind = .global, .instance = handle.instance, .global = handle, .global_idx = handle.global_idx, .borrowed = true };
    handle.extern_view = v;
    return v;
}

pub export fn wasm_table_as_extern(t: ?*Table) callconv(.c) ?*Extern {
    const handle = t orelse return null;
    if (handle.extern_view) |v| return v;
    // instance (export-derived) OR Store (standalone host table).
    const store = if (handle.instance) |i| (i.store orelse return null) else (handle.store orelse return null);
    const alloc = instance.storeAllocator(store) orelse return null;
    const v = alloc.create(Extern) catch return null;
    v.* = .{ .kind = .table, .instance = handle.instance, .table = handle, .table_idx = handle.table_idx, .borrowed = true };
    handle.extern_view = v;
    return v;
}

pub export fn wasm_memory_as_extern(m: ?*Memory) callconv(.c) ?*Extern {
    const handle = m orelse return null;
    if (handle.extern_view) |v| return v;
    // instance (export-derived) OR Store (standalone host memory).
    const store = if (handle.instance) |i| (i.store orelse return null) else (handle.store orelse return null);
    const alloc = instance.storeAllocator(store) orelse return null;
    const v = alloc.create(Extern) catch return null;
    v.* = .{ .kind = .memory, .instance = handle.instance, .memory = handle, .memory_idx = handle.memory_idx, .borrowed = true };
    handle.extern_view = v;
    return v;
}

/// Const-qualified `*_as_extern`. C `const` is advisory; the lazily cached
/// view is an implementation detail, so these forward through the mutable
/// form via `@constCast` and re-narrow the result.
pub export fn wasm_func_as_extern_const(f: ?*const Func) callconv(.c) ?*const Extern {
    return wasm_func_as_extern(@constCast(f));
}

pub export fn wasm_global_as_extern_const(g: ?*const Global) callconv(.c) ?*const Extern {
    return wasm_global_as_extern(@constCast(g));
}

pub export fn wasm_table_as_extern_const(t: ?*const Table) callconv(.c) ?*const Extern {
    return wasm_table_as_extern(@constCast(t));
}

pub export fn wasm_memory_as_extern_const(m: ?*const Memory) callconv(.c) ?*const Extern {
    return wasm_memory_as_extern(@constCast(m));
}

// ----------------------------------------------------------------
// Host-created standalone entities: `wasm_{global,table,memory}_new`
// (own backing aliased into an importing instance) + `wasm_func_new
// [_with_env]` (host callback dispatched via a HostCall thunk, below).
// ----------------------------------------------------------------

/// Map a `wasm_valkind_t` byte to the internal scalar valtype. v128
/// (no `wasm_val_t` slot) and ref kinds are NOT part of the c_api
/// scalar-global surface (see the v128-spec-boundary lesson), so
/// `wasm_global_new` of those returns null.
fn scalarValType(kind: u8) ?zir.ValType {
    return switch (kind) {
        0 => .i32,
        1 => .i64,
        2 => .f32,
        3 => .f64,
        else => null,
    };
}

/// `wasm_global_new(store, globaltype, val) -> own wasm_global_t*` —
/// a host-owned standalone global holding its own `*Value` cell. The
/// host get/sets it via `wasm_global_get/set`; passing
/// `wasm_global_as_extern(g)` into `wasm_instance_new`'s imports aliases
/// the cell into the guest (one shared cell). Caller owns it
/// (`wasm_global_delete`). Null on a non-scalar valtype or OOM.
pub export fn wasm_global_new(
    store: ?*instance.Store,
    gt: ?*const types.GlobalType,
    val: ?*const instance.Val,
) callconv(.c) ?*Global {
    const s = store orelse return null;
    const gtype = gt orelse return null;
    const v = val orelse return null;
    const content = types.wasm_globaltype_content(gtype) orelse return null;
    const vt = scalarValType(content.kind) orelse return null;
    const alloc = instance.storeAllocator(s) orelse return null;
    const cell = alloc.create(runtime.Value) catch return null;
    cell.* = instance.marshalValIn(v.*);
    const g = alloc.create(Global) catch {
        alloc.destroy(cell);
        return null;
    };
    g.* = .{
        .instance = null,
        .global_idx = 0,
        .valtype = vt,
        .mutable = types.wasm_globaltype_mutability(gtype) != 0,
        .cell = cell,
        .store = s,
    };
    return g;
}

/// `wasm_memory_new(store, memorytype) -> own wasm_memory_t*` — a
/// host-owned standalone linear memory holding its own `*MemoryInstance`
/// (min pages, zeroed). `wasm_memory_data/size/grow` operate on it;
/// `wasm_memory_as_extern(m)` into `wasm_instance_new`'s imports shares
/// the `*MemoryInstance` so `rt.memory` aliases its bytes (guest +
/// host see one buffer). Caller owns it (`wasm_memory_delete`).
pub export fn wasm_memory_new(store: ?*instance.Store, mt: ?*const types.MemoryType) callconv(.c) ?*Memory {
    const s = store orelse return null;
    const mtype = mt orelse return null;
    const lim = types.wasm_memorytype_limits(mtype) orelse return null;
    const alloc = instance.storeAllocator(s) orelse return null;
    // ADR-0202 D1 — host-created memories route through the same backing
    // selection as instantiate-defined ones (wasm-c-api memories are
    // i32 / 64 KiB pages, so they qualify on supported hosts).
    const backing = memory_backing.allocBacking(
        alloc,
        @as(usize, lim.min) * 65536,
        .i32,
        16,
    ) catch return null;
    const mi = alloc.create(runtime.MemoryInstance) catch {
        memory_backing.freeBacking(alloc, backing);
        return null;
    };
    mi.* = .{
        .bytes = backing.bytes,
        .pages_min = lim.min,
        .pages_max = if (lim.max == 0xffff_ffff) null else lim.max,
        .reservation = backing.reservation,
    };
    const m = alloc.create(Memory) catch {
        memory_backing.freeBacking(alloc, backing);
        alloc.destroy(mi);
        return null;
    };
    m.* = .{ .instance = null, .memory_idx = 0, .minst = mi, .store = s };
    return m;
}

/// Map a table-element `wasm_valkind_t` byte to the internal ref valtype
/// (funcref=129 / externref=128 per `valKindOf`). Non-ref kinds aren't
/// valid table elements → null.
fn elemRefValType(kind: u8) ?zir.ValType {
    return switch (kind) {
        129 => zir.ValType.funcref,
        128 => zir.ValType.externref,
        else => null,
    };
}

/// `wasm_table_new(store, tabletype, init) -> own wasm_table_t*` — a
/// host-owned standalone table holding its own `*TableInstance` (`min`
/// ref slots, each = `init`'s payload or null). get/set/size/grow operate
/// on it; `wasm_table_as_extern(t)` into `wasm_instance_new`'s imports
/// value-copies the `TableInstance` (refs aliased) so set/get share the
/// slot array. Caller owns it (`wasm_table_delete`).
pub export fn wasm_table_new(store: ?*instance.Store, tt: ?*const types.TableType, init: ?*instance.Ref) callconv(.c) ?*Table {
    const s = store orelse return null;
    const ttype = tt orelse return null;
    const lim = types.wasm_tabletype_limits(ttype) orelse return null;
    const elem = types.wasm_tabletype_element(ttype) orelse return null;
    const et = elemRefValType(elem.kind) orelse return null;
    const alloc = instance.storeAllocator(s) orelse return null;
    const refs = alloc.alloc(runtime.Value, lim.min) catch return null;
    const payload: u64 = if (init) |r| r.ref else runtime.Value.null_ref;
    for (refs) |*slot| slot.* = .{ .ref = payload };
    const max: ?u64 = if (lim.max == 0xffff_ffff) null else @as(u64, lim.max);
    const ti = alloc.create(runtime.TableInstance) catch {
        alloc.free(refs);
        return null;
    };
    ti.* = .{ .refs = refs, .elem_type = et, .max = max };
    const tbl = alloc.create(Table) catch {
        alloc.free(refs);
        alloc.destroy(ti);
        return null;
    };
    tbl.* = .{ .instance = null, .table_idx = 0, .elem_type = et, .min = lim.min, .max = max, .tinst = ti, .store = s };
    return tbl;
}

/// Map a `wasm_valkind_t` byte to the internal valtype for a func
/// signature (scalars + funcref/externref). v128 has no `wasm_val_t`
/// slot → null (rejects the whole `wasm_func_new`).
fn cValKindToZir(kind: u8) ?zir.ValType {
    return switch (kind) {
        0 => .i32,
        1 => .i64,
        2 => .f32,
        3 => .f64,
        128 => zir.ValType.externref,
        129 => zir.ValType.funcref,
        else => null,
    };
}

/// Copy a `wasm_valtype_vec_t` into an owned `[]zir.ValType` (the func's
/// marshalled arity). Returns null on OOM or an unsupported valtype.
fn buildArity(alloc: std.mem.Allocator, v: types.ValTypeVec) ?[]zir.ValType {
    const out = alloc.alloc(zir.ValType, v.size) catch return null;
    if (v.size > 0) {
        const data = v.data orelse {
            alloc.free(out);
            return null;
        };
        for (0..v.size) |i| {
            const vt = data[i] orelse {
                alloc.free(out);
                return null;
            };
            out[i] = cValKindToZir(vt.kind) orelse {
                alloc.free(out);
                return null;
            };
        }
    }
    return out;
}

fn funcNewImpl(
    store: ?*instance.Store,
    ft: ?*const types.FuncType,
    cb: ?instance.WasmFuncCallback,
    cb_env: ?instance.WasmFuncCallbackEnv,
    env: ?*anyopaque,
    finalizer: ?*const fn (?*anyopaque) callconv(.c) void,
) ?*Func {
    const s = store orelse return null;
    const ftype = ft orelse return null;
    const alloc = instance.storeAllocator(s) orelse return null;
    const params = buildArity(alloc, ftype.params) orelse return null;
    const results = buildArity(alloc, ftype.results) orelse {
        alloc.free(params);
        return null;
    };
    const payload = alloc.create(instance.HostFuncPayload) catch {
        alloc.free(params);
        alloc.free(results);
        return null;
    };
    payload.* = .{ .callback = cb, .callback_env = cb_env, .env = env, .finalizer = finalizer, .params = params, .results = results };
    const fh = alloc.create(Func) catch {
        alloc.free(params);
        alloc.free(results);
        alloc.destroy(payload);
        return null;
    };
    fh.* = .{ .instance = null, .func_idx = 0, .host = payload, .store = s };
    return fh;
}

/// `wasm_func_new(store, functype, callback) -> own wasm_func_t*` — a
/// host function the guest can `call`. The callback is invoked from the
/// interp via a `HostCall` thunk that marshals operand-stack args ↔
/// `wasm_val_vec_t`. Usable only as an import (`wasm_func_as_extern` →
/// `wasm_instance_new`). Caller owns it (`wasm_func_delete`).
pub export fn wasm_func_new(store: ?*instance.Store, ft: ?*const types.FuncType, callback: instance.WasmFuncCallback) callconv(.c) ?*Func {
    return funcNewImpl(store, ft, callback, null, null, null);
}

/// `wasm_func_new_with_env(store, functype, callback, env, finalizer)` —
/// as `wasm_func_new` but the callback receives `env`; `finalizer(env)`
/// runs at `wasm_func_delete`.
pub export fn wasm_func_new_with_env(
    store: ?*instance.Store,
    ft: ?*const types.FuncType,
    callback: instance.WasmFuncCallbackEnv,
    env: ?*anyopaque,
    finalizer: ?*const fn (?*anyopaque) callconv(.c) void,
) callconv(.c) ?*Func {
    return funcNewImpl(store, ft, null, callback, env, finalizer);
}

// ----------------------------------------------------------------
// Base `wasm_ref_t` ops (WASM_DECLARE_REF_BASE for `ref`). The funcref
// cross-casts (`wasm_func_as_ref` / `wasm_ref_as_func`), `wasm_foreign`,
// and per-handle host_info are tracked in D-253 (driven by §13.4).
// ----------------------------------------------------------------

/// `wasm_ref_copy(ref) -> own wasm_ref_t*` — duplicate a ref handle
/// (same referent payload, fresh owned handle the caller deletes).
/// Null on a standalone (instance-less) ref until D-253 adds the
/// foreign/externref store path.
pub export fn wasm_ref_copy(r: ?*const instance.Ref) callconv(.c) ?*instance.Ref {
    const handle = r orelse return null;
    // instance-backed (table ref) OR instance-less (foreign externref).
    const store = if (handle.instance) |i| (i.store orelse return null) else (handle.store orelse return null);
    const alloc = instance.storeAllocator(store) orelse return null;
    const c = alloc.create(instance.Ref) catch return null;
    c.* = .{ .instance = handle.instance, .ref = handle.ref, .store = handle.store };
    return c;
}

/// `wasm_ref_same(a, b) -> bool` — whether two refs denote the same
/// referent. funcref/externref identity IS the payload (`*FuncEntity`
/// ptr / externref ptr), so payload equality is referent equality.
/// Two nulls are the same; one null is not.
pub export fn wasm_ref_same(a: ?*const instance.Ref, b: ?*const instance.Ref) callconv(.c) bool {
    const ra = a orelse return b == null;
    const rb = b orelse return false;
    return ra.ref == rb.ref;
}

/// `wasm_func_as_ref(func) -> wasm_ref_t*` (borrowed) — a funcref `Ref`
/// denoting `func`. Payload = `@intFromPtr(&rt.func_entities[func_idx])`
/// (the funcref encoding). Cached as `func.ref_view` (freed in
/// `wasm_func_delete`). Null for a standalone host func (no
/// `func_entities` slot — D-253) or null arg.
pub export fn wasm_func_as_ref(f: ?*Func) callconv(.c) ?*instance.Ref {
    const handle = f orelse return null;
    if (handle.ref_view) |rv| return rv;
    const inst = handle.instance orelse return null;
    const rt = inst.runtime orelse return null;
    if (handle.func_idx >= rt.func_entities.len) return null;
    const store = inst.store orelse return null;
    const alloc = instance.storeAllocator(store) orelse return null;
    const rv = alloc.create(instance.Ref) catch return null;
    rv.* = .{ .instance = handle.instance, .ref = runtime.Value.fromFuncRef(&rt.func_entities[handle.func_idx]).ref };
    handle.ref_view = rv;
    return rv;
}

/// `wasm_ref_as_func(ref) -> wasm_func_t*` (borrowed) — the Func a
/// funcref `ref` denotes, decoded via `*FuncEntity` →
/// `fe.runtime.instance` → a synthesized `{instance, func_idx}` Func
/// (cached as `ref.func_view`, freed in `wasm_ref_delete`). Null if the
/// ref is null/not a funcref, or the source instance is gone.
pub export fn wasm_ref_as_func(r: ?*instance.Ref) callconv(.c) ?*Func {
    const handle = r orelse return null;
    if (handle.func_view) |fv| return fv;
    const fe = runtime.Value.refAsFuncEntity(.{ .ref = handle.ref }) orelse return null;
    // D-496/D-498 — prefer the Ref's own carried instance (set by wasm_table_get /
    // funcref-result marshalling). A JIT-built FuncEntity has `runtime = undefined`
    // (setup.zig: no interp Runtime on the JIT path), so `fe.runtime.instance` would
    // dereference garbage → SEGV. The interp path falls back to fe.runtime.instance.
    const inst: *instance.Instance = handle.instance orelse blk: {
        const inst_opaque = fe.runtime.instance orelse return null;
        break :blk @ptrCast(@alignCast(inst_opaque));
    };
    const store = inst.store orelse return null;
    const alloc = instance.storeAllocator(store) orelse return null;
    const fv = alloc.create(Func) catch return null;
    fv.* = .{ .instance = inst, .func_idx = fe.func_idx };
    handle.func_view = fv;
    return fv;
}

pub export fn wasm_func_as_ref_const(f: ?*const Func) callconv(.c) ?*const instance.Ref {
    return wasm_func_as_ref(@constCast(f));
}

pub export fn wasm_ref_as_func_const(r: ?*const instance.Ref) callconv(.c) ?*const Func {
    return wasm_ref_as_func(@constCast(r));
}

// ----------------------------------------------------------------
// `wasm_foreign` — a host-defined opaque object usable as an externref
// (WASM_DECLARE_REF(foreign) + wasm_foreign_new). Its identity (the
// `*Foreign` pointer) IS the externref payload. host_info lets the host
// attach/retrieve its own data. (D-253 D)
// ----------------------------------------------------------------

pub const Foreign = struct {
    store: ?*instance.Store,
    host_info: ?*anyopaque = null,
    host_info_finalizer: ?*const fn (?*anyopaque) callconv(.c) void = null,
    /// Cached borrowed externref `wasm_ref_t` view (`wasm_foreign_as_ref`;
    /// owned by this Foreign, freed in `wasm_foreign_delete`).
    ref_view: ?*instance.Ref = null,
};

pub export fn wasm_foreign_new(store: ?*instance.Store) callconv(.c) ?*Foreign {
    const s = store orelse return null;
    const alloc = instance.storeAllocator(s) orelse return null;
    const f = alloc.create(Foreign) catch return null;
    f.* = .{ .store = s };
    return f;
}

pub export fn wasm_foreign_delete(f: ?*Foreign) callconv(.c) void {
    const handle = f orelse return;
    const s = handle.store orelse return;
    const alloc = instance.storeAllocator(s) orelse return;
    if (handle.host_info_finalizer) |fin| fin(handle.host_info);
    if (handle.ref_view) |rv| alloc.destroy(rv);
    alloc.destroy(handle);
}

/// `wasm_foreign_as_ref(foreign) -> wasm_ref_t*` (borrowed) — an
/// externref `Ref` whose payload is `@intFromPtr(foreign)` (the Foreign's
/// identity). Cached as `foreign.ref_view`. The Foreign must outlive any
/// table/global slot holding the ref (host lifetime responsibility).
pub export fn wasm_foreign_as_ref(f: ?*Foreign) callconv(.c) ?*instance.Ref {
    const handle = f orelse return null;
    if (handle.ref_view) |rv| return rv;
    const s = handle.store orelse return null;
    const alloc = instance.storeAllocator(s) orelse return null;
    const rv = alloc.create(instance.Ref) catch return null;
    rv.* = .{ .instance = null, .ref = @intFromPtr(handle), .store = s };
    handle.ref_view = rv;
    return rv;
}

/// `wasm_ref_as_foreign(ref) -> wasm_foreign_t*` (borrowed) — reinterpret
/// an externref payload as the `*Foreign` it denotes. Per wasm-c-api, the
/// caller guarantees the ref is a foreign (no runtime tag distinguishes
/// externref kinds); null payload → null.
pub export fn wasm_ref_as_foreign(r: ?*instance.Ref) callconv(.c) ?*Foreign {
    const handle = r orelse return null;
    if (handle.ref == 0) return null;
    return @ptrFromInt(handle.ref);
}

pub export fn wasm_foreign_as_ref_const(f: ?*const Foreign) callconv(.c) ?*const instance.Ref {
    return wasm_foreign_as_ref(@constCast(f));
}
pub export fn wasm_ref_as_foreign_const(r: ?*const instance.Ref) callconv(.c) ?*const Foreign {
    return wasm_ref_as_foreign(@constCast(r));
}

/// `wasm_foreign_copy` — null. A Foreign owns its `host_info` (+ finalizer): a
/// shared copy would double-finalize, a fresh Foreign would lose the externref
/// identity. Safe duplication needs a per-store registry (D-253-D).
pub export fn wasm_foreign_copy(_: ?*const Foreign) callconv(.c) ?*Foreign {
    return null;
}

pub export fn wasm_foreign_get_host_info(f: ?*const Foreign) callconv(.c) ?*anyopaque {
    return (f orelse return null).host_info;
}

pub export fn wasm_foreign_set_host_info(f: ?*Foreign, info: ?*anyopaque) callconv(.c) void {
    const handle = f orelse return;
    handle.host_info = info;
    handle.host_info_finalizer = null;
}

pub export fn wasm_foreign_set_host_info_with_finalizer(
    f: ?*Foreign,
    info: ?*anyopaque,
    finalizer: ?*const fn (?*anyopaque) callconv(.c) void,
) callconv(.c) void {
    const handle = f orelse return;
    handle.host_info = info;
    handle.host_info_finalizer = finalizer;
}

// =====================================================================
// Tests
// =====================================================================

test "wasm_*_as_extern: entity → borrowed-view Extern round-trips + is cached + extern_delete no-ops" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = instance.mixed_exports_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const inst = instance.wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const data = exports.data orelse return error.ExportsDataNull;

    // func extern → Func → func_as_extern → view; view round-trips back to
    // the SAME Func, the view's kind is func, and a second as_extern call
    // returns the identical (cached) pointer.
    const func = instance.wasm_extern_as_func(data[0]) orelse return error.NotFunc;
    const view = wasm_func_as_extern(func) orelse return error.NoView;
    try testing.expectEqual(@as(u8, @intFromEnum(instance.ExternKind.func)), instance.wasm_extern_kind(view));
    try testing.expectEqual(func, instance.wasm_extern_as_func(view).?);
    try testing.expectEqual(view, wasm_func_as_extern(func).?); // cached
    // extern_delete on a borrowed view is a no-op: the cached view survives.
    instance.wasm_extern_delete(view);
    try testing.expectEqual(view, wasm_func_as_extern(func).?);

    // memory / table / global wrap to the matching kind.
    const mem = instance.wasm_extern_as_memory(data[1]) orelse return error.NotMem;
    try testing.expectEqual(@as(u8, @intFromEnum(instance.ExternKind.memory)), instance.wasm_extern_kind(wasm_memory_as_extern(mem).?));
    const tbl = instance.wasm_extern_as_table(data[2]) orelse return error.NotTable;
    try testing.expectEqual(@as(u8, @intFromEnum(instance.ExternKind.table)), instance.wasm_extern_kind(wasm_table_as_extern(tbl).?));
    const glb = instance.wasm_extern_as_global(data[3]) orelse return error.NotGlobal;
    try testing.expectEqual(@as(u8, @intFromEnum(instance.ExternKind.global)), instance.wasm_extern_kind(wasm_global_as_extern(glb).?));

    try testing.expect(wasm_func_as_extern(null) == null);
    try testing.expect(wasm_func_as_extern_const(null) == null);
}

test "wasm_global_new: standalone host global get/set + immutable rejects set" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    // mutable i32 global = 7 (globaltype_new consumes the valtype)
    const gt = types.wasm_globaltype_new(types.wasm_valtype_new(0), 1) orelse return error.GlobalTypeAllocFailed;
    defer types.wasm_globaltype_delete(gt);
    var init_val: instance.Val = .{ .kind = .i32, .of = .{ .i32 = 7 } };
    const g = wasm_global_new(s, gt, &init_val) orelse return error.GlobalNewFailed;
    defer instance.wasm_global_delete(g);

    var out: instance.Val = undefined;
    instance.wasm_global_get(g, &out);
    try testing.expectEqual(@as(i32, 7), out.of.i32);
    var nine: instance.Val = .{ .kind = .i32, .of = .{ .i32 = 9 } };
    instance.wasm_global_set(g, &nine);
    instance.wasm_global_get(g, &out);
    try testing.expectEqual(@as(i32, 9), out.of.i32);
    // as_extern wraps the standalone global to kind global.
    try testing.expectEqual(@as(u8, @intFromEnum(instance.ExternKind.global)), instance.wasm_extern_kind(wasm_global_as_extern(g).?));

    // immutable global: set is a no-op.
    const gt2 = types.wasm_globaltype_new(types.wasm_valtype_new(0), 0) orelse return error.GlobalTypeAllocFailed;
    defer types.wasm_globaltype_delete(gt2);
    var five: instance.Val = .{ .kind = .i32, .of = .{ .i32 = 5 } };
    const gi = wasm_global_new(s, gt2, &five) orelse return error.GlobalNewFailed;
    defer instance.wasm_global_delete(gi);
    instance.wasm_global_set(gi, &nine);
    instance.wasm_global_get(gi, &out);
    try testing.expectEqual(@as(i32, 5), out.of.i32);

    try testing.expect(wasm_global_new(null, gt, &init_val) == null);
}

// (module (import "env" "g" (global (mut i32)))
//   (func (export "get") (result i32) global.get 0))
const import_global_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> i32
    0x02, 0x0a, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x67, 0x03, 0x7f, 0x01, // import env.g global (mut i32)
    0x03, 0x02, 0x01, 0x00, // func[0]: type 0
    0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, // export "get" → func 0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x23, 0x00, 0x0b, // code: global.get 0
};

test "wasm_global_new: host global imported — guest global.get sees host value + host set shares the cell" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    const gt = types.wasm_globaltype_new(types.wasm_valtype_new(0), 1) orelse return error.GlobalTypeAllocFailed;
    defer types.wasm_globaltype_delete(gt);
    var init_val: instance.Val = .{ .kind = .i32, .of = .{ .i32 = 42 } };
    const hg = wasm_global_new(s, gt, &init_val) orelse return error.GlobalNewFailed;
    defer instance.wasm_global_delete(hg);

    var bytes = import_global_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);

    var iarr = [_]?*Extern{wasm_global_as_extern(hg)};
    var imports: vec.ExternVec = .{ .size = iarr.len, .data = &iarr };
    const inst = instance.wasm_instance_new(s, m, &imports, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const getf = instance.wasm_extern_as_func(exports.data.?[0]) orelse return error.NotFunc;

    const args: vec.ValVec = .{ .size = 0, .data = null };
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };
    try testing.expect(instance.wasm_func_call(getf, &args, &results) == null);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32); // guest reads host's value

    // Host writes the shared cell; guest re-read sees it.
    var hundred: instance.Val = .{ .kind = .i32, .of = .{ .i32 = 100 } };
    instance.wasm_global_set(hg, &hundred);
    try testing.expect(instance.wasm_func_call(getf, &args, &results) == null);
    try testing.expectEqual(@as(i32, 100), results_data[0].of.i32);
}

test "wasm_memory_new: standalone host memory data/size/grow" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    var lim: types.Limits = .{ .min = 1, .max = 0xffff_ffff };
    const mt = types.wasm_memorytype_new(&lim) orelse return error.MemTypeAllocFailed;
    defer types.wasm_memorytype_delete(mt);
    const m = wasm_memory_new(s, mt) orelse return error.MemNewFailed;
    defer instance.wasm_memory_delete(m);

    try testing.expectEqual(@as(u32, 1), instance.wasm_memory_size(m));
    try testing.expectEqual(@as(usize, 65536), instance.wasm_memory_data_size(m));
    const data = instance.wasm_memory_data(m) orelse return error.NoData;
    data[0] = 42;
    try testing.expectEqual(@as(u8, 42), (instance.wasm_memory_data(m).?)[0]);
    // grow by one page.
    try testing.expect(instance.wasm_memory_grow(m, 1));
    try testing.expectEqual(@as(u32, 2), instance.wasm_memory_size(m));
    // grown region is zeroed; original byte preserved.
    try testing.expectEqual(@as(u8, 42), (instance.wasm_memory_data(m).?)[0]);
    // as_extern wraps to kind memory.
    try testing.expectEqual(@as(u8, @intFromEnum(instance.ExternKind.memory)), instance.wasm_extern_kind(wasm_memory_as_extern(m).?));
}

// (module (import "env" "m" (memory 1))
//   (func (export "r") (result i32) (i32.const 0) (i32.load)))
const import_memory_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> i32
    0x02, 0x0a, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x6d, 0x02, 0x00, 0x01, // import env.m memory min 1
    0x03, 0x02, 0x01, 0x00, // func[0]: type 0
    0x07, 0x05, 0x01, 0x01, 0x72, 0x00, 0x00, // export "r" → func 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0b, // code: i32.load (i32.const 0)
};

test "wasm_memory_new: host memory imported — guest i32.load reads bytes the host wrote (shared buffer)" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    var lim: types.Limits = .{ .min = 1, .max = 0xffff_ffff };
    const mt = types.wasm_memorytype_new(&lim) orelse return error.MemTypeAllocFailed;
    defer types.wasm_memorytype_delete(mt);
    const hm = wasm_memory_new(s, mt) orelse return error.MemNewFailed;
    defer instance.wasm_memory_delete(hm);

    var bytes = import_memory_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);

    var iarr = [_]?*Extern{wasm_memory_as_extern(hm)};
    var imports: vec.ExternVec = .{ .size = iarr.len, .data = &iarr };
    const inst = instance.wasm_instance_new(s, m, &imports, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    // Host writes the shared buffer AFTER instantiation; guest i32.load sees it.
    const data = instance.wasm_memory_data(hm) orelse return error.NoData;
    data[0] = 42; // little-endian i32 = 42

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const rf = instance.wasm_extern_as_func(exports.data.?[0]) orelse return error.NotFunc;

    const args: vec.ValVec = .{ .size = 0, .data = null };
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };
    try testing.expect(instance.wasm_func_call(rf, &args, &results) == null);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32);
}

test "wasm_table_new: standalone host table size/get/set/grow + bounds" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    // funcref table, min 2 (tabletype_new consumes the valtype). 129 = funcref.
    var lim: types.Limits = .{ .min = 2, .max = 0xffff_ffff };
    const tt = types.wasm_tabletype_new(types.wasm_valtype_new(129), &lim) orelse return error.TableTypeAllocFailed;
    defer types.wasm_tabletype_delete(tt);
    const t = wasm_table_new(s, tt, null) orelse return error.TableNewFailed;
    defer instance.wasm_table_delete(t);

    try testing.expectEqual(@as(u32, 2), instance.wasm_table_size(t));
    const r0 = instance.wasm_table_get(t, 0) orelse return error.NoRef; // null-ref handle is non-null
    defer instance.wasm_ref_delete(r0);
    try testing.expect(instance.wasm_table_get(t, 5) == null); // out of range
    try testing.expect(instance.wasm_table_set(t, 0, null)); // set null ok
    try testing.expect(!instance.wasm_table_set(t, 5, null)); // oob set fails
    try testing.expect(instance.wasm_table_grow(t, 1, null));
    try testing.expectEqual(@as(u32, 3), instance.wasm_table_size(t));
    try testing.expectEqual(@as(u8, @intFromEnum(instance.ExternKind.table)), instance.wasm_extern_kind(wasm_table_as_extern(t).?));
}

// (module (import "env" "t" (table 3 funcref))
//   (func (export "sz") (result i32) (table.size 0)))
const import_table_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> i32
    0x02, 0x0b, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x74, 0x01, 0x70, 0x00, 0x03, // import env.t table funcref min 3
    0x03, 0x02, 0x01, 0x00, // func[0]: type 0
    0x07, 0x06, 0x01, 0x02, 0x73, 0x7a, 0x00, 0x00, // export "sz" → func 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0xfc, 0x10, 0x00, 0x0b, // code: table.size 0
};

test "wasm_table_new: host table imported — guest table.size sees the host table's size" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    var lim: types.Limits = .{ .min = 3, .max = 0xffff_ffff };
    const tt = types.wasm_tabletype_new(types.wasm_valtype_new(129), &lim) orelse return error.TableTypeAllocFailed;
    defer types.wasm_tabletype_delete(tt);
    const ht = wasm_table_new(s, tt, null) orelse return error.TableNewFailed;
    defer instance.wasm_table_delete(ht);

    var bytes = import_table_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);

    var iarr = [_]?*Extern{wasm_table_as_extern(ht)};
    var imports: vec.ExternVec = .{ .size = iarr.len, .data = &iarr };
    const inst = instance.wasm_instance_new(s, m, &imports, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const szf = instance.wasm_extern_as_func(exports.data.?[0]) orelse return error.NotFunc;

    const args: vec.ValVec = .{ .size = 0, .data = null };
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };
    try testing.expect(instance.wasm_func_call(szf, &args, &results) == null);
    try testing.expectEqual(@as(i32, 3), results_data[0].of.i32);
}

// (module (type (func (param i32) (result i32)))
//   (import "env" "h" (func (type 0)))
//   (func (export "f") (type 0) (local.get 0) (call 0)))
const import_func_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type (i32)->(i32)
    0x02, 0x09, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x68, 0x00, 0x00, // import env.h func type0
    0x03, 0x02, 0x01, 0x00, // func[1]: type 0 (defined)
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x01, // export "f" → funcidx 1
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b, // code: local.get 0; call 0
};

fn addOneCallback(args: ?*const vec.ValVec, results: ?*vec.ValVec) callconv(.c) ?*trap_surface.Trap {
    const a = args orelse return null;
    const r = results orelse return null;
    const x = a.data.?[0].of.i32;
    r.data.?[0] = .{ .kind = .i32, .of = .{ .i32 = x + 1 } };
    return null;
}

test "wasm_func_new: host callback imported — guest call invokes it (i32 -> i32, +1)" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    // functype (i32) -> (i32); functype_new consumes the vecs.
    var p_arr = [_]?*types.ValType{types.wasm_valtype_new(0)};
    var r_arr = [_]?*types.ValType{types.wasm_valtype_new(0)};
    var pv: types.ValTypeVec = undefined;
    var rv: types.ValTypeVec = undefined;
    types.wasm_valtype_vec_new(&pv, 1, &p_arr);
    types.wasm_valtype_vec_new(&rv, 1, &r_arr);
    const ft = types.wasm_functype_new(&pv, &rv) orelse return error.FuncTypeAllocFailed;
    defer types.wasm_functype_delete(ft);
    const hf = wasm_func_new(s, ft, addOneCallback) orelse return error.FuncNewFailed;
    defer instance.wasm_func_delete(hf);

    var bytes = import_func_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);

    var iarr = [_]?*Extern{wasm_func_as_extern(hf)};
    var imports: vec.ExternVec = .{ .size = iarr.len, .data = &iarr };
    const inst = instance.wasm_instance_new(s, m, &imports, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const ff = instance.wasm_extern_as_func(exports.data.?[0]) orelse return error.NotFunc;

    var args_data = [_]instance.Val{.{ .kind = .i32, .of = .{ .i32 = 41 } }};
    const args: vec.ValVec = .{ .size = 1, .data = &args_data };
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };
    try testing.expect(instance.wasm_func_call(ff, &args, &results) == null);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32); // guest call → host cb 41+1
}

// (module (table (export "t") 1 funcref))
const defined_table_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x04, 0x04, 0x01, 0x70, 0x00, 0x01, // table funcref min 1
    0x07, 0x05, 0x01, 0x01, 0x74, 0x01, 0x00, // export "t" → table 0
};

test "wasm_ref_copy/same: dup an instance-backed table ref + identity compare" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = defined_table_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const inst = instance.wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const tbl = instance.wasm_extern_as_table(exports.data.?[0]) orelse return error.NotTable;
    const r0 = instance.wasm_table_get(tbl, 0) orelse return error.NoRef;
    defer instance.wasm_ref_delete(r0);

    const c0 = wasm_ref_copy(r0) orelse return error.RefCopyFailed;
    defer instance.wasm_ref_delete(c0);
    try testing.expect(wasm_ref_same(r0, c0)); // copy denotes the same referent
    try testing.expect(!wasm_ref_same(r0, null));
    try testing.expect(wasm_ref_same(null, null));
}

// (module (func (export "f") (result i32) (i32.const 42)))
const func_export_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> i32
    0x03, 0x02, 0x01, 0x00, // func[0]: type 0
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" → func 0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b, // code: i32.const 42
};

test "wasm_func_as_ref / wasm_ref_as_func: funcref round-trip recovers a callable func" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = func_export_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const inst = instance.instanceNewWithEngine(s, m, null, null, .interp) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const func0 = instance.wasm_extern_as_func(exports.data.?[0]) orelse return error.NotFunc;

    const ref = wasm_func_as_ref(func0) orelse return error.AsRefFailed;
    try testing.expectEqual(ref, wasm_func_as_ref(func0).?); // cached
    const func1 = wasm_ref_as_func(ref) orelse return error.RefAsFuncFailed;
    try testing.expectEqual(func1, wasm_ref_as_func(ref).?); // cached

    // The recovered func calls to the same body (returns 42).
    const args: vec.ValVec = .{ .size = 0, .data = null };
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };
    try testing.expect(instance.wasm_func_call(func1, &args, &results) == null);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32);

    try testing.expect(wasm_ref_as_func(null) == null);
    try testing.expect(wasm_func_as_ref(null) == null);
}

// (module (func (result i32) i32.const 42) (table (export "t") 1 1 funcref)
//  (elem (i32.const 0) func 0)) — funcref table call (mirrors
// test/c_api_conformance/funcref_table_call.c). D-498 RED on `.jit`: SEGV
// (wasm_ref_as_func deref of the JIT FuncEntity's `runtime=undefined`) + dispatch
// gap (wasmFuncCallJit by export NAME; func 0 is NOT exported).
const funcref_table_call_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x04, 0x05, 0x01, 0x70, 0x01,
    0x01, 0x01, 0x07, 0x05, 0x01, 0x01, 0x74, 0x01, 0x00, 0x09, 0x07, 0x01,
    0x00, 0x41, 0x00, 0x0b, 0x01, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41,
    0x2a, 0x0b,
};

test "D-498 JIT C-path: funcref from a table is callable (table_get→ref_as_func→func_call) (.jit)" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = funcref_table_call_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const inst = instance.instanceNewWithEngine(s, m, null, null, .jit) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);
    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const tab = instance.wasm_extern_as_table(exports.data.?[0]) orelse return error.TableNull;
    const ref = instance.wasm_table_get(tab, 0) orelse return error.RefNull;
    defer instance.wasm_ref_delete(ref);
    const f = wasm_ref_as_func(ref) orelse return error.RefNotFunc;
    const args: vec.ValVec = .{ .size = 0, .data = null };
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };
    try testing.expect(instance.wasm_func_call(f, &args, &results) == null);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32);
}

// (module (type (func (result i32))) (type (func (result funcref)))
//  (func (result i32) i32.const 42) (func (export "get") (result funcref) ref.func 0)
//  (table (export "t") 1 1 funcref) (elem (i32.const 0) func 0)) — funcref RESULT
// (mirrors funcref_result_call.c). D-498 RED on `.jit`: ref result was dropped.
const funcref_result_call_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x09, 0x02, 0x60,
    0x00, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x70, 0x03, 0x03, 0x02, 0x00, 0x01,
    0x04, 0x05, 0x01, 0x70, 0x01, 0x01, 0x01, 0x07, 0x0b, 0x02, 0x03, 0x67,
    0x65, 0x74, 0x00, 0x01, 0x01, 0x74, 0x01, 0x00, 0x09, 0x07, 0x01, 0x00,
    0x41, 0x00, 0x0b, 0x01, 0x00, 0x0a, 0x0b, 0x02, 0x04, 0x00, 0x41, 0x2a,
    0x0b, 0x04, 0x00, 0xd2, 0x00, 0x0b,
};

test "D-498 JIT C-path: funcref returned from a call is callable (func_call→result.ref→ref_as_func→call) (.jit)" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = funcref_result_call_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const inst = instance.instanceNewWithEngine(s, m, null, null, .jit) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);
    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const getf = instance.wasm_extern_as_func(exports.data.?[0]) orelse return error.FuncNull; // export[0]="get"
    const gargs: vec.ValVec = .{ .size = 0, .data = null };
    var gres_data: [1]instance.Val = undefined;
    var gres: vec.ValVec = .{ .size = 1, .data = &gres_data };
    try testing.expect(instance.wasm_func_call(getf, &gargs, &gres) == null);
    try testing.expectEqual(instance.ValKind.funcref, gres_data[0].kind);
    // `Val.of.ref` is the C-opaque `?*anyopaque` wasm_ref_t*; cast to the Zig handle.
    const ref_opaque = gres_data[0].of.ref orelse return error.ResultRefNull;
    const ref: *instance.Ref = @ptrCast(@alignCast(ref_opaque));
    const f = wasm_ref_as_func(ref) orelse return error.RefNotFunc;
    const args: vec.ValVec = .{ .size = 0, .data = null };
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };
    try testing.expect(instance.wasm_func_call(f, &args, &results) == null);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32);
}

// (module
//   (type (func (param funcref) (result funcref)))   ;; id
//   (type (func (result funcref)))                    ;; mk
//   (func (export "id") (param funcref) (result funcref) local.get 0)
//   (func (export "mk") (result funcref) ref.func 0)
//   (elem declare func 0))
// — exercises the NON-NULL funcref PARAM marshalling through the JIT call
// boundary (D-498: invokeRefIdx 1-param arm + cValToJitBits ref). `mk` sources a
// non-null funcref (wasm_func_as_ref is null on a pure-JIT instance, no runtime).
const funcref_id_param_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0a, 0x02, 0x60, 0x01, 0x70, 0x01, 0x70,
    0x60, 0x00, 0x01, 0x70, 0x03, 0x03, 0x02, 0x00,
    0x01, 0x07, 0x0b, 0x02, 0x02, 0x69, 0x64, 0x00,
    0x00, 0x02, 0x6d, 0x6b, 0x00, 0x01, 0x09, 0x05,
    0x01, 0x03, 0x00, 0x01, 0x00, 0x0a, 0x0b, 0x02,
    0x04, 0x00, 0x20, 0x00, 0x0b, 0x04, 0x00, 0xd2,
    0x00, 0x0b,
};

test "D-498 JIT C-path: non-null funcref PARAM round-trips through wasm_func_call (.jit)" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = funcref_id_param_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const inst = instance.instanceNewWithEngine(s, m, null, null, .jit) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    const id = instance.zwasm_instance_get_func(inst, 0) orelse return error.FuncResolveFailed;
    defer instance.wasm_func_delete(id);
    const mk = instance.zwasm_instance_get_func(inst, 1) orelse return error.FuncResolveFailed;
    defer instance.wasm_func_delete(mk);

    // mk() -> a non-null funcref denoting `id`.
    const empty: vec.ValVec = .{ .size = 0, .data = null };
    var mk_res_data: [1]instance.Val = undefined;
    var mk_res: vec.ValVec = .{ .size = 1, .data = &mk_res_data };
    try testing.expect(instance.wasm_func_call(mk, &empty, &mk_res) == null);
    const in_opaque = mk_res_data[0].of.ref orelse return error.MkRefNull;
    const in_ref: *instance.Ref = @ptrCast(@alignCast(in_opaque));

    // id(funcref) -> funcref: pass the non-null funcref as the param.
    var args_data: [1]instance.Val = .{.{ .kind = .funcref, .of = .{ .ref = in_ref } }};
    const args: vec.ValVec = .{ .size = 1, .data = &args_data };
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };
    try testing.expect(instance.wasm_func_call(id, &args, &results) == null);
    try testing.expectEqual(instance.ValKind.funcref, results_data[0].kind);
    const out_opaque = results_data[0].of.ref orelse return error.ResultRefNull;
    const out_ref: *instance.Ref = @ptrCast(@alignCast(out_opaque));
    // Identity: the returned funcref must carry the same payload it was passed.
    try testing.expectEqual(in_ref.ref, out_ref.ref);
}

var foreign_test_finalized: bool = false;
fn markForeignFinalized(info: ?*anyopaque) callconv(.c) void {
    _ = info;
    foreign_test_finalized = true;
}

test "wasm_foreign: new + host_info + as_ref/ref_as_foreign round-trip + finalizer fires" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    const f = wasm_foreign_new(s) orelse return error.ForeignNewFailed;
    try testing.expect(wasm_foreign_get_host_info(f) == null);
    var marker: u32 = 7;
    wasm_foreign_set_host_info(f, &marker);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&marker)), wasm_foreign_get_host_info(f));

    // as_ref payload = @intFromPtr(f); ref_as_foreign recovers f; cached.
    const ref = wasm_foreign_as_ref(f) orelse return error.AsRefFailed;
    try testing.expectEqual(ref, wasm_foreign_as_ref(f).?);
    try testing.expectEqual(f, wasm_ref_as_foreign(ref).?);
    try testing.expect(wasm_ref_as_foreign(null) == null);
    wasm_foreign_delete(f); // frees ref_view + foreign; finalizer null

    // with_finalizer fires at delete.
    foreign_test_finalized = false;
    const f2 = wasm_foreign_new(s) orelse return error.ForeignNewFailed;
    wasm_foreign_set_host_info_with_finalizer(f2, &marker, markForeignFinalized);
    wasm_foreign_delete(f2);
    try testing.expect(foreign_test_finalized);
}

// ----------------------------------------------------------------
// #315 — `wasm_func_call` on a `wasm_func_new` host func. Before the
// fix `wasm_func_call` returned null (= success) without running the
// callback, so the caller read an uninitialised `results` buffer as a
// successful invocation. These pin that the direct-call path invokes
// the callback for real, hands the callback's own trap back to the
// caller unconsumed (UNLIKE the guest-boundary `hostFuncThunk`, which
// converts it), and rejects an arity mismatch with a trap.
// ----------------------------------------------------------------

/// (i32) -> (i32) functype for the host-func direct-call tests. The
/// returned FuncType owns the vecs (`wasm_functype_new` consumes them).
fn hostFuncI32ToI32(_: void) ?*types.FuncType {
    var p_arr = [_]?*types.ValType{types.wasm_valtype_new(0)};
    var r_arr = [_]?*types.ValType{types.wasm_valtype_new(0)};
    var pv: types.ValTypeVec = undefined;
    var rv: types.ValTypeVec = undefined;
    types.wasm_valtype_vec_new(&pv, 1, &p_arr);
    types.wasm_valtype_vec_new(&rv, 1, &r_arr);
    return types.wasm_functype_new(&pv, &rv);
}

var direct_call_env_seen: i32 = 0;

fn addEnvCallback(env: ?*anyopaque, args: ?*const vec.ValVec, results: ?*vec.ValVec) callconv(.c) ?*trap_surface.Trap {
    const a = args orelse return null;
    const r = results orelse return null;
    const bump: *i32 = @ptrCast(@alignCast(env.?));
    direct_call_env_seen = bump.*;
    r.data.?[0] = .{ .kind = .i32, .of = .{ .i32 = a.data.?[0].of.i32 + bump.* } };
    return null;
}

var trapping_callback_store: ?*instance.Store = null;

fn trappingCallback(args: ?*const vec.ValVec, results: ?*vec.ValVec) callconv(.c) ?*trap_surface.Trap {
    _ = args;
    _ = results;
    var msg = [_]u8{ 'h', 'o', 's', 't', ' ', 's', 'a', 'i', 'd', ' ', 'n', 'o' };
    const bv: vec.ByteVec = .{ .size = msg.len, .data = &msg };
    return trap_surface.wasm_trap_new(trapping_callback_store, &bv);
}

test "#315 wasm_func_call: a wasm_func_new host func runs its callback" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    const ft = hostFuncI32ToI32({}) orelse return error.FuncTypeAllocFailed;
    defer types.wasm_functype_delete(ft);
    const hf = wasm_func_new(s, ft, addOneCallback) orelse return error.FuncNewFailed;
    defer instance.wasm_func_delete(hf);

    // The arity surface already answers for a host func, so an embedder
    // that pre-validates gets through cleanly — hence the silent zero.
    try testing.expectEqual(@as(usize, 1), module_introspect.wasm_func_param_arity(hf));
    try testing.expectEqual(@as(usize, 1), module_introspect.wasm_func_result_arity(hf));

    var args_data = [_]instance.Val{.{ .kind = .i32, .of = .{ .i32 = 41 } }};
    const args: vec.ValVec = .{ .size = 1, .data = &args_data };
    // Poison the result slot: a silent success leaves this untouched.
    var results_data = [_]instance.Val{.{ .kind = .i32, .of = .{ .i32 = -12345 } }};
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };

    try testing.expect(instance.wasm_func_call(hf, &args, &results) == null);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32);
}

test "#315 wasm_func_call: the with_env host func gets its env" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    const ft = hostFuncI32ToI32({}) orelse return error.FuncTypeAllocFailed;
    defer types.wasm_functype_delete(ft);
    var bump: i32 = 10;
    const hf = wasm_func_new_with_env(s, ft, addEnvCallback, &bump, null) orelse return error.FuncNewFailed;
    defer instance.wasm_func_delete(hf);

    direct_call_env_seen = 0;
    var args_data = [_]instance.Val{.{ .kind = .i32, .of = .{ .i32 = 5 } }};
    const args: vec.ValVec = .{ .size = 1, .data = &args_data };
    var results_data = [_]instance.Val{.{ .kind = .i32, .of = .{ .i32 = -12345 } }};
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };

    try testing.expect(instance.wasm_func_call(hf, &args, &results) == null);
    try testing.expectEqual(@as(i32, 10), direct_call_env_seen);
    try testing.expectEqual(@as(i32, 15), results_data[0].of.i32);
}

test "#315 wasm_func_call: the callback's own trap reaches the caller unconsumed" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    const ft = hostFuncI32ToI32({}) orelse return error.FuncTypeAllocFailed;
    defer types.wasm_functype_delete(ft);
    trapping_callback_store = s;
    defer trapping_callback_store = null;
    const hf = wasm_func_new(s, ft, trappingCallback) orelse return error.FuncNewFailed;
    defer instance.wasm_func_delete(hf);

    var args_data = [_]instance.Val{.{ .kind = .i32, .of = .{ .i32 = 1 } }};
    const args: vec.ValVec = .{ .size = 1, .data = &args_data };
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };

    const trap = instance.wasm_func_call(hf, &args, &results) orelse return error.ExpectedTrap;
    defer trap_surface.wasm_trap_delete(trap);
    // The direct path hands the callback's own trap object back — it is
    // NOT consumed and re-raised as a guest fault the way the guest-
    // boundary thunk does, so the host's own message survives.
    var msg: vec.ByteVec = .{ .size = 0, .data = null };
    trap_surface.wasm_trap_message(trap, &msg);
    defer vec.wasm_byte_vec_delete(&msg);
    try testing.expectEqualStrings("host said no", msg.data.?[0..msg.size]);
}

test "#315 wasm_func_call: an arity mismatch on a host func traps" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    const ft = hostFuncI32ToI32({}) orelse return error.FuncTypeAllocFailed;
    defer types.wasm_functype_delete(ft);
    const hf = wasm_func_new(s, ft, addOneCallback) orelse return error.FuncNewFailed;
    defer instance.wasm_func_delete(hf);

    // Two args for a one-param func.
    var args_data = [_]instance.Val{
        .{ .kind = .i32, .of = .{ .i32 = 1 } },
        .{ .kind = .i32, .of = .{ .i32 = 2 } },
    };
    const args: vec.ValVec = .{ .size = 2, .data = &args_data };
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };
    const t1 = instance.wasm_func_call(hf, &args, &results) orelse return error.ExpectedTrap;
    trap_surface.wasm_trap_delete(t1);

    // Zero result slots for a one-result func.
    var ok_args = [_]instance.Val{.{ .kind = .i32, .of = .{ .i32 = 1 } }};
    const args1: vec.ValVec = .{ .size = 1, .data = &ok_args };
    var no_results: vec.ValVec = .{ .size = 0, .data = null };
    const t2 = instance.wasm_func_call(hf, &args1, &no_results) orelse return error.ExpectedTrap;
    trap_surface.wasm_trap_delete(t2);
}

test "#315 wasm_func_call: a null func handle still returns null, not a trap" {
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };
    try testing.expect(instance.wasm_func_call(null, null, &results) == null);
}

var ref_passthrough_seen: ?*anyopaque = null;
var ref_passthrough_out: u32 = 0;

fn refEchoCallback(args: ?*const vec.ValVec, results: ?*vec.ValVec) callconv(.c) ?*trap_surface.Trap {
    ref_passthrough_seen = args.?.data.?[0].of.ref;
    results.?.data.?[0] = .{ .kind = .anyref, .of = .{ .ref = @ptrCast(&ref_passthrough_out) } };
    return null;
}

test "#315 wasm_func_call: a ref-kind val is passed through, not owned" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    // (externref) -> (externref)
    var p_arr = [_]?*types.ValType{types.wasm_valtype_new(128)};
    var r_arr = [_]?*types.ValType{types.wasm_valtype_new(128)};
    var pv: types.ValTypeVec = undefined;
    var rv: types.ValTypeVec = undefined;
    types.wasm_valtype_vec_new(&pv, 1, &p_arr);
    types.wasm_valtype_vec_new(&rv, 1, &r_arr);
    const ft = types.wasm_functype_new(&pv, &rv) orelse return error.FuncTypeAllocFailed;
    defer types.wasm_functype_delete(ft);
    const hf = wasm_func_new(s, ft, refEchoCallback) orelse return error.FuncNewFailed;
    defer instance.wasm_func_delete(hf);

    // A host-owned object, NOT a zwasm handle. Both sides of a direct call
    // are the same host, so the direct path mints no `*Ref` view for the
    // callback and frees none afterwards — unlike the guest-boundary
    // `hostFuncThunk`, which lends an owned handle and deletes it. If that
    // discipline leaked into this path, this pointer would be freed here.
    var host_owned: u64 = 0xfeed;
    ref_passthrough_seen = null;
    var args_data = [_]instance.Val{.{ .kind = .anyref, .of = .{ .ref = @ptrCast(&host_owned) } }};
    const args: vec.ValVec = .{ .size = 1, .data = &args_data };
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };

    try testing.expect(instance.wasm_func_call(hf, &args, &results) == null);
    // The callback saw the caller's own pointer, unwrapped.
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&host_owned)), ref_passthrough_seen);
    try testing.expectEqual(@as(u64, 0xfeed), host_owned);
    // And the caller got the callback's pointer back, unwrapped.
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&ref_passthrough_out)), results_data[0].of.ref);
}
