//! wasm-c-api module introspection — `wasm_module_imports` / `_exports`
//! (§13.2 / Phase 13). Extracted from `api/instance.zig` (a genuinely
//! separable subsystem per ADR-0099 §D2 P3 / the D-171 restructure note):
//! it decodes a `Module`'s import/export sections into the `api/types.zig`
//! externtype descriptors. One-way dependency on `instance.Module` (no
//! cycle — instance does not import this).
//!
//! Zone 3 (`src/api/`). Re-exported via `api/wasm.zig`.

const std = @import("std");
const testing = std.testing;

const parser = @import("../parse/parser.zig");
const sections = @import("../parse/sections.zig");
const zir = @import("../ir/zir.zig");
const types = @import("types.zig");
const vec = @import("vec.zig");
const instance = @import("instance.zig");

const Module = instance.Module;
const ca = std.heap.c_allocator;

/// Map an internal `zir.ValType` → a `wasm_valkind_t` byte (wasm.h:
/// I32=0..F64=3, EXTERNREF=128, FUNCREF=129). v128 has no base-enum
/// valkind → mapped to 4 (best-effort; rare in import/export functypes).
/// Non-funcref refs (Wasm 3.0 GC) collapse to EXTERNREF.
fn valKindOf(vt: zir.ValType) u8 {
    return switch (vt) {
        .i32 => 0,
        .i64 => 1,
        .f32 => 2,
        .f64 => 3,
        .v128 => 4,
        .ref => if (vt.isFuncref()) 129 else 128,
    };
}

/// Build a `wasm_valtype_vec_t` from internal valtypes (each a fresh owned
/// `wasm_valtype_t`). Empty vec for an empty slice; null when any part of it
/// cannot be allocated, with everything built so far released.
///
/// The failures have to be told apart here, because none of them is visible
/// downstream: a short vec reads as a shorter signature, a null element reads
/// as `i32` through `wasm_valtype_kind`, and an empty one is what an empty
/// slice legitimately gives — so a caller could only report the wrong
/// signature as a good one (#475).
fn buildValTypeVec(vts: []const zir.ValType) ?types.ValTypeVec {
    if (vts.len == 0) return .{ .size = 0, .data = null };
    const tmp = ca.alloc(?*types.ValType, vts.len) catch return null;
    defer ca.free(tmp);
    for (vts, 0..) |vt, i| {
        tmp[i] = types.wasm_valtype_new(valKindOf(vt)) orelse {
            for (tmp[0..i]) |p| types.wasm_valtype_delete(p);
            return null;
        };
    }
    var out: types.ValTypeVec = undefined;
    types.wasm_valtype_vec_new(&out, vts.len, tmp.ptr); // copies the owned pointers in
    if (out.size != vts.len) {
        for (tmp) |p| types.wasm_valtype_delete(p);
        return null;
    }
    return out;
}

// Shared per-kind type builders. The `*Of` variants return the owned per-kind
// type (`wasm_functype_t` etc.) used by both the per-object accessors
// (`wasm_func_type` …) and the `*Extern` wrappers that wasm_extern_type +
// import/export resolution use.

/// Owned `wasm_functype_t` from internal param/result valtypes.
fn functypeFromValTypes(params: []const zir.ValType, results: []const zir.ValType) ?*types.FuncType {
    var pv = buildValTypeVec(params) orelse return null;
    var rv = buildValTypeVec(results) orelse {
        types.wasm_valtype_vec_delete(&pv);
        return null;
    };
    return types.wasm_functype_new(&pv, &rv) orelse {
        types.wasm_valtype_vec_delete(&pv);
        types.wasm_valtype_vec_delete(&rv);
        return null;
    };
}

/// functype from a typeidx into the (decoded) type section.
fn functypeOf(typeidx: u32, func_types: ?sections.Types) ?*types.FuncType {
    const ts = func_types orelse return null;
    if (typeidx >= ts.items.len) return null;
    const ft = ts.items[typeidx];
    return functypeFromValTypes(ft.params, ft.results);
}

fn functypeExtern(typeidx: u32, func_types: ?sections.Types) ?*types.ExternType {
    const ftype = functypeOf(typeidx, func_types) orelse return null;
    return types.wasm_functype_as_externtype(ftype);
}

fn globaltypeOf(valtype: zir.ValType, mutable: bool) ?*types.GlobalType {
    const vt = types.wasm_valtype_new(valKindOf(valtype)) orelse return null;
    return types.wasm_globaltype_new(vt, if (mutable) 1 else 0) orelse {
        types.wasm_valtype_delete(vt);
        return null;
    };
}

fn globaltypeExtern(valtype: zir.ValType, mutable: bool) ?*types.ExternType {
    const gt = globaltypeOf(valtype, mutable) orelse return null;
    return types.wasm_globaltype_as_externtype(gt);
}

fn tabletypeOf(elem_type: zir.ValType, min: u64, max: ?u64) ?*types.TableType {
    const vt = types.wasm_valtype_new(valKindOf(elem_type)) orelse return null;
    // table64 limits are u64; the wasm-c-api TableType is u32 — saturate a
    // wider i64-table bound to u32-max (the closest expressible value).
    var lim: types.Limits = .{
        .min = std.math.cast(u32, min) orelse 0xffff_ffff,
        .max = if (max) |mx| (std.math.cast(u32, mx) orelse 0xffff_ffff) else 0xffff_ffff,
    };
    return types.wasm_tabletype_new(vt, &lim) orelse {
        types.wasm_valtype_delete(vt);
        return null;
    };
}

fn tabletypeExtern(elem_type: zir.ValType, min: u64, max: ?u64) ?*types.ExternType {
    const tt = tabletypeOf(elem_type, min, max) orelse return null;
    return types.wasm_tabletype_as_externtype(tt);
}

fn memorytypeOf(min: u64, max: ?u64) ?*types.MemoryType {
    var lim: types.Limits = .{
        .min = std.math.cast(u32, min) orelse return null,
        .max = if (max) |mx| (std.math.cast(u32, mx) orelse 0xffff_ffff) else 0xffff_ffff,
    };
    return types.wasm_memorytype_new(&lim);
}

fn memorytypeExtern(min: u64, max: ?u64) ?*types.ExternType {
    const mt = memorytypeOf(min, max) orelse return null;
    return types.wasm_memorytype_as_externtype(mt);
}

fn tagtypeExtern(typeidx: u32, func_types: ?sections.Types) ?*types.ExternType {
    const ftype = functypeOf(typeidx, func_types) orelse return null;
    const tt = types.wasm_tagtype_new(ftype) orelse {
        types.wasm_functype_delete(ftype);
        return null;
    };
    return types.wasm_tagtype_as_externtype(tt);
}

/// Build the `wasm_externtype_t` for one decoded import.
fn buildImportExternType(it: sections.Import, func_types: ?sections.Types) ?*types.ExternType {
    return switch (it.payload) {
        .func_typeidx => |ti| functypeExtern(ti, func_types),
        .global => |g| globaltypeExtern(g.valtype, g.mutable),
        .table => |t| tabletypeExtern(t.elem_type, t.min, t.max),
        .memory => |mem| memorytypeExtern(mem.min, mem.max),
        .tag_typeidx => |ti| tagtypeExtern(ti, func_types),
    };
}

/// Collect every import into `out`, one `wasm_importtype_t` per import in
/// section order. True = `out` holds all of them. False = `out` is
/// `{0, NULL}` and every entry built along the way has been released: a
/// short list is indistinguishable from a module with fewer imports, so a
/// partial answer is worse than none. Backs `wasm_module_imports` (which
/// has no way to say false) and `zwasm_module_imports_ex` (which does).
pub fn collectImports(m: ?*const Module, out: ?*types.ImportTypeVec) bool {
    const o = out orelse return false;
    o.* = .{ .size = 0, .data = null };
    const mod = m orelse return false;
    const bp = mod.bytes_ptr orelse return false;
    const bytes = bp[0..mod.bytes_len];

    var arena = std.heap.ArenaAllocator.init(ca);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = parser.parse(a, bytes) catch return false;
    defer parsed.deinit(a);
    const imp_sec = parsed.find(.import) orelse return true; // no import section → complete and empty
    var imps = sections.decodeImports(a, imp_sec.body) catch return false;
    defer imps.deinit();
    if (imps.items.len == 0) return true;

    var func_types: ?sections.Types = null;
    defer if (func_types) |*t| t.deinit();
    if (parsed.find(.type)) |ts| func_types = sections.decodeTypes(a, ts.body) catch null;

    var built: std.ArrayList(?*types.ImportType) = .empty;
    defer built.deinit(ca);
    // Unwind on any failure below. `wasm_importtype_delete` takes the entry's
    // module/name vecs and its externtype with it, so an entry that reached
    // `built` needs nothing else; the pieces of the entry being assembled when
    // the failure hit are freed at the failure site, before they are handed over.
    var complete = false;
    defer if (!complete) {
        for (built.items) |p| types.wasm_importtype_delete(p);
        o.* = .{ .size = 0, .data = null };
    };

    for (imps.items) |it| {
        const et = buildImportExternType(it, func_types) orelse return false;
        var modv: vec.ByteVec = undefined;
        var nmv: vec.ByteVec = undefined;
        vec.wasm_byte_vec_new(&modv, it.module.len, it.module.ptr);
        vec.wasm_byte_vec_new(&nmv, it.name.len, it.name.ptr);
        // An allocation failure there reads as `{0, NULL}`, which is also a
        // legitimately empty name — only the length separates them.
        const named = modv.size == it.module.len and nmv.size == it.name.len;
        const imp = if (named) types.wasm_importtype_new(&modv, &nmv, et) else null;
        const entry = imp orelse {
            types.wasm_externtype_delete(et);
            if (modv.data) |q| ca.free(q[0..modv.size]);
            if (nmv.data) |q| ca.free(q[0..nmv.size]);
            return false;
        };
        built.append(ca, entry) catch {
            types.wasm_importtype_delete(entry);
            return false;
        };
    }

    types.wasm_importtype_vec_new(o, built.items.len, built.items.ptr);
    if (o.size != built.items.len) return false; // the vec now owns nothing
    complete = true;
    return true;
}

/// `wasm_module_imports(module, own importtype_vec* out)` — one
/// `wasm_importtype_t` per import, in section order (module name + field
/// name + the import's externtype). A tag import's externtype has kind
/// `WASM_EXTERN_TAG`, and `wasm_externtype_as_tagtype` gives its functype.
/// `out` is owned by the caller (`importtype_vec_delete`). wasm.h returns
/// void, so a failure is an empty vec here; `zwasm_module_imports_ex`
/// reports it.
pub export fn wasm_module_imports(m: ?*const Module, out: ?*types.ImportTypeVec) callconv(.c) void {
    _ = collectImports(m, out);
}

// Index-space type descriptors (import prefix ++ defined section), used to
// resolve an export's `idx` → its type.
const GlobalInfo = struct { valtype: zir.ValType, mutable: bool };
const TableInfo = struct { elem_type: zir.ValType, min: u64, max: ?u64 };

/// `wasm_module_exports(module, own exporttype_vec* out)` — decode the
/// export section into one `wasm_exporttype_t` per export. Unlike imports,
/// an export carries only an index, so the type is resolved through the
/// per-kind index space (import prefix ++ the defined section). `out` is
/// owned by the caller (`exporttype_vec_delete`).
pub export fn wasm_module_exports(m: ?*const Module, out: ?*types.ExportTypeVec) callconv(.c) void {
    const o = out orelse return;
    o.* = .{ .size = 0, .data = null };
    const mod = m orelse return;
    const bp = mod.bytes_ptr orelse return;
    const bytes = bp[0..mod.bytes_len];

    var arena = std.heap.ArenaAllocator.init(ca);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = parser.parse(a, bytes) catch return;
    defer parsed.deinit(a);
    const exp_sec = parsed.find(.@"export") orelse return; // no exports → empty vec
    var exports = sections.decodeExports(a, exp_sec.body) catch return;
    defer exports.deinit();
    if (exports.items.len == 0) return;

    var func_types: ?sections.Types = null;
    defer if (func_types) |*t| t.deinit();
    if (parsed.find(.type)) |ts| func_types = sections.decodeTypes(a, ts.body) catch null;

    // Build the per-kind index spaces: import prefix first, then defined.
    var func_tis: std.ArrayList(u32) = .empty;
    var globals: std.ArrayList(GlobalInfo) = .empty;
    var tables: std.ArrayList(TableInfo) = .empty;
    var mems: std.ArrayList(sections.MemoryEntry) = .empty;
    if (parsed.find(.import)) |imp_sec| {
        var imps = sections.decodeImports(a, imp_sec.body) catch return;
        defer imps.deinit();
        for (imps.items) |it| switch (it.payload) {
            .func_typeidx => |ti| func_tis.append(a, ti) catch return,
            .global => |g| globals.append(a, .{ .valtype = g.valtype, .mutable = g.mutable }) catch return,
            .table => |t| tables.append(a, .{ .elem_type = t.elem_type, .min = t.min, .max = t.max }) catch return,
            .memory => |mem| mems.append(a, mem) catch return,
            .tag_typeidx => {},
        };
    }
    if (parsed.find(.function)) |fs| {
        const tis = sections.decodeFunctions(a, fs.body) catch return;
        for (tis) |ti| func_tis.append(a, ti) catch return;
    }
    if (parsed.find(.global)) |gs| {
        var gd = sections.decodeGlobals(a, gs.body) catch return;
        defer gd.deinit();
        for (gd.items) |g| globals.append(a, .{ .valtype = g.valtype, .mutable = g.mutable }) catch return;
    }
    if (parsed.find(.table)) |ts| {
        var td = sections.decodeTables(a, ts.body) catch return;
        defer td.deinit();
        for (td.items) |t| tables.append(a, .{ .elem_type = t.elem_type, .min = t.min, .max = t.max }) catch return;
    }
    if (parsed.find(.memory)) |ms| {
        var md = sections.decodeMemory(a, ms.body) catch return;
        defer md.deinit();
        for (md.items) |mem| mems.append(a, mem) catch return;
    }

    var built: std.ArrayList(?*types.ExportType) = .empty;
    defer built.deinit(ca);
    for (exports.items) |e| {
        const et: ?*types.ExternType = switch (e.kind) {
            .func => if (e.idx < func_tis.items.len) functypeExtern(func_tis.items[e.idx], func_types) else null,
            .global => if (e.idx < globals.items.len) globaltypeExtern(globals.items[e.idx].valtype, globals.items[e.idx].mutable) else null,
            .table => if (e.idx < tables.items.len) tabletypeExtern(tables.items[e.idx].elem_type, tables.items[e.idx].min, tables.items[e.idx].max) else null,
            .memory => if (e.idx < mems.items.len) memorytypeExtern(mems.items[e.idx].min, mems.items[e.idx].max) else null,
        };
        const ext = et orelse continue;
        var nmv: vec.ByteVec = undefined;
        vec.wasm_byte_vec_new(&nmv, e.name.len, e.name.ptr);
        const xt = types.wasm_exporttype_new(&nmv, ext) orelse {
            types.wasm_externtype_delete(ext);
            if (nmv.data) |p| ca.free(p[0..nmv.size]);
            continue;
        };
        built.append(ca, xt) catch {
            types.wasm_exporttype_delete(xt);
            continue;
        };
    }
    types.wasm_exporttype_vec_new(o, built.items.len, if (built.items.len > 0) built.items.ptr else null);
}

/// The binding `Module` an Instance was instantiated from (held as an
/// opaque slot to avoid a Zone-3 import cycle; forward-cast here).
fn moduleOf(inst: ?*instance.Instance) ?*const Module {
    const i = inst orelse return null;
    const mp = i.module orelse return null;
    return @ptrCast(@alignCast(mp));
}

/// functype for the func at absolute funcidx `abs_idx` (imports first,
/// then defined) in the instance's module — mirrors the
/// `wasm_module_exports` func index-space build.
fn funcTypeAt(inst: ?*instance.Instance, abs_idx: u32) ?*types.FuncType {
    const mod = moduleOf(inst) orelse return null;
    const bp = mod.bytes_ptr orelse return null;
    var arena = std.heap.ArenaAllocator.init(ca);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = parser.parse(a, bp[0..mod.bytes_len]) catch return null;
    defer parsed.deinit(a);
    var func_types: ?sections.Types = null;
    defer if (func_types) |*t| t.deinit();
    if (parsed.find(.type)) |ts| func_types = sections.decodeTypes(a, ts.body) catch null;
    var func_tis: std.ArrayList(u32) = .empty;
    if (parsed.find(.import)) |imp_sec| {
        var imps = sections.decodeImports(a, imp_sec.body) catch return null;
        defer imps.deinit();
        for (imps.items) |it| switch (it.payload) {
            .func_typeidx => |ti| func_tis.append(a, ti) catch return null,
            else => {},
        };
    }
    if (parsed.find(.function)) |fs| {
        const tis = sections.decodeFunctions(a, fs.body) catch return null;
        for (tis) |ti| func_tis.append(a, ti) catch return null;
    }
    if (abs_idx >= func_tis.items.len) return null;
    return functypeOf(func_tis.items[abs_idx], func_types);
}

fn funcExternTypeAt(inst: ?*instance.Instance, abs_idx: u32) ?*types.ExternType {
    const ft = funcTypeAt(inst, abs_idx) orelse return null;
    return types.wasm_functype_as_externtype(ft);
}

/// memorytype for the memory at index `idx` (imports first, then
/// defined) in the instance's module.
fn memoryTypeAt(inst: ?*instance.Instance, idx: u32) ?*types.MemoryType {
    const mod = moduleOf(inst) orelse return null;
    const bp = mod.bytes_ptr orelse return null;
    var arena = std.heap.ArenaAllocator.init(ca);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = parser.parse(a, bp[0..mod.bytes_len]) catch return null;
    defer parsed.deinit(a);
    var mems: std.ArrayList(sections.MemoryEntry) = .empty;
    if (parsed.find(.import)) |imp_sec| {
        var imps = sections.decodeImports(a, imp_sec.body) catch return null;
        defer imps.deinit();
        for (imps.items) |it| switch (it.payload) {
            .memory => |mem| mems.append(a, mem) catch return null,
            else => {},
        };
    }
    if (parsed.find(.memory)) |ms| {
        var md = sections.decodeMemory(a, ms.body) catch return null;
        defer md.deinit();
        for (md.items) |mem| mems.append(a, mem) catch return null;
    }
    if (idx >= mems.items.len) return null;
    return memorytypeOf(mems.items[idx].min, mems.items[idx].max);
}

fn memoryExternTypeAt(inst: ?*instance.Instance, idx: u32) ?*types.ExternType {
    const mt = memoryTypeAt(inst, idx) orelse return null;
    return types.wasm_memorytype_as_externtype(mt);
}

/// `wasm_extern_type(*const Extern) -> own wasm_externtype_t*` — the
/// externtype of a runtime extern. global/table read the type cached
/// on the handle; func/memory resolve through the instance module's
/// per-kind index space. Owned result (caller `wasm_externtype_delete`).
pub export fn wasm_extern_type(e: ?*const instance.Extern) callconv(.c) ?*types.ExternType {
    const h = e orelse return null;
    return switch (h.kind) {
        .global => if (h.global) |g| globaltypeExtern(g.valtype, g.mutable) else null,
        .table => if (h.table) |t| tabletypeExtern(t.elem_type, t.min, t.max) else null,
        .func => if (h.func) |f| funcExternTypeAt(h.instance, f.func_idx) else null,
        .memory => if (h.memory) |mem| memoryExternTypeAt(h.instance, mem.memory_idx) else null,
    };
}

// =====================================================================
// Per-object type accessors (wasm.h:441-490). Each returns an owned
// per-kind type the caller frees with the matching `wasm_*type_delete`.
// Host-created funcs (instance == null) read the cached host payload;
// everything else resolves through the cached handle fields or the
// instance module's index space (same path as wasm_extern_type).
// =====================================================================

/// `wasm_func_type(const wasm_func_t*) -> own wasm_functype_t*` (wasm.h:441).
pub export fn wasm_func_type(f: ?*const instance.Func) callconv(.c) ?*types.FuncType {
    const h = f orelse return null;
    if (h.host) |hp| return functypeFromValTypes(hp.params, hp.results);
    return funcTypeAt(h.instance, h.func_idx);
}

/// `wasm_func_param_arity(const wasm_func_t*) -> size_t` (wasm.h:442).
pub export fn wasm_func_param_arity(f: ?*const instance.Func) callconv(.c) usize {
    const h = f orelse return 0;
    if (h.host) |hp| return hp.params.len;
    const ft = funcTypeAt(h.instance, h.func_idx) orelse return 0;
    defer types.wasm_functype_delete(ft);
    return ft.params.size;
}

/// `wasm_func_result_arity(const wasm_func_t*) -> size_t` (wasm.h:443).
pub export fn wasm_func_result_arity(f: ?*const instance.Func) callconv(.c) usize {
    const h = f orelse return 0;
    if (h.host) |hp| return hp.results.len;
    const ft = funcTypeAt(h.instance, h.func_idx) orelse return 0;
    defer types.wasm_functype_delete(ft);
    return ft.results.size;
}

/// `wasm_global_type(const wasm_global_t*) -> own wasm_globaltype_t*` (wasm.h:456).
pub export fn wasm_global_type(g: ?*const instance.Global) callconv(.c) ?*types.GlobalType {
    const h = g orelse return null;
    return globaltypeOf(h.valtype, h.mutable);
}

/// `wasm_table_type(const wasm_table_t*) -> own wasm_tabletype_t*` (wasm.h:471).
pub export fn wasm_table_type(t: ?*const instance.Table) callconv(.c) ?*types.TableType {
    const h = t orelse return null;
    return tabletypeOf(h.elem_type, h.min, h.max);
}

/// `wasm_memory_type(const wasm_memory_t*) -> own wasm_memorytype_t*` (wasm.h:490).
pub export fn wasm_memory_type(m: ?*const instance.Memory) callconv(.c) ?*types.MemoryType {
    const h = m orelse return null;
    if (h.minst) |mi| return memorytypeOf(mi.pages_min, mi.pages_max);
    return memoryTypeAt(h.instance, h.memory_idx);
}

// =====================================================================
// Tests
// =====================================================================

// (module (type (func (param i32))) (import "env" "f" (func (type 0))))
const func_import_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00, // type (i32) -> ()
    0x02, 0x09, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x66, 0x00, 0x00, // import env.f func type 0
};

test "wasm_module_imports: func import → importtype (env.f : (i32) -> ())" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = func_import_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);

    var imports: types.ImportTypeVec = undefined;
    wasm_module_imports(m, &imports);
    defer types.wasm_importtype_vec_delete(&imports);

    try testing.expectEqual(@as(usize, 1), imports.size);
    const it = imports.data.?[0].?;
    try testing.expectEqualStrings("env", types.wasm_importtype_module(it).?.data.?[0..3]);
    try testing.expectEqualStrings("f", types.wasm_importtype_name(it).?.data.?[0..1]);
    const et = types.wasm_importtype_type(it).?;
    try testing.expectEqual(types.extern_func, types.wasm_externtype_kind(et));
    const ft = types.wasm_externtype_as_functype_const(et).?;
    try testing.expectEqual(@as(usize, 1), ft.params.size);
    try testing.expectEqual(@as(u8, 0), types.wasm_valtype_kind(ft.params.data.?[0].?)); // i32
    try testing.expectEqual(@as(usize, 0), ft.results.size);
}

// (module (type (func (param i32)))
//   (import "env" "before" (func (type 0)))
//   (import "env" "error"  (tag  (type 0)))
//   (import "env" "after"  (func (type 0))))
const tag_import_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00, // type (i32) -> ()
    0x02, 0x27, 0x03, // import section, 3 entries
    0x03, 'e', 'n', 'v', 0x06, 'b', 'e', 'f', 'o', 'r', 'e', 0x00, 0x00, // func
    0x03, 'e', 'n', 'v', 0x05, 'e', 'r', 'r', 'o', 'r', 0x04, 0x00, 0x00, // tag
    0x03, 'e', 'n', 'v', 0x05, 'a', 'f', 't', 'e', 'r', 0x00, 0x00, // func
};

test "wasm_module_imports: a tag import keeps its position between the funcs" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = tag_import_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);

    var imports: types.ImportTypeVec = undefined;
    wasm_module_imports(m, &imports);
    defer types.wasm_importtype_vec_delete(&imports);

    try testing.expectEqual(@as(usize, 3), imports.size);
    const kinds = [_]u8{ types.extern_func, types.extern_tag, types.extern_func };
    const names = [_][]const u8{ "before", "error", "after" };
    for (kinds, names, 0..) |kind, name, i| {
        const it = imports.data.?[i].?;
        const nm = types.wasm_importtype_name(it).?;
        try testing.expectEqualStrings(name, nm.data.?[0..nm.size]);
        try testing.expectEqual(kind, types.wasm_externtype_kind(types.wasm_importtype_type(it).?));
    }
    // The tag's parameter signature survives the round-trip through externtype.
    const tt = types.wasm_externtype_as_tagtype_const(types.wasm_importtype_type(imports.data.?[1].?).?).?;
    const ft = types.wasm_tagtype_functype(tt).?;
    try testing.expectEqual(@as(usize, 1), ft.params.size);
    try testing.expectEqual(@as(u8, 0), types.wasm_valtype_kind(ft.params.data.?[0].?)); // i32
    try testing.expectEqual(@as(usize, 0), ft.results.size);
}

test "collectImports: a null module or out is false, not an empty success" {
    var imports: types.ImportTypeVec = .{ .size = 7, .data = null };
    try testing.expect(!collectImports(null, &imports));
    try testing.expectEqual(@as(usize, 0), imports.size);
    try testing.expect(!collectImports(null, null));
}

test "wasm_module_imports: null-arg → empty vec, no crash" {
    var imports: types.ImportTypeVec = undefined;
    wasm_module_imports(null, &imports);
    try testing.expectEqual(@as(usize, 0), imports.size);
    wasm_module_imports(null, null);
}

// (module (type (func (result i32))) (func (type 0) i32.const 7) (memory 1)
//   (export "f" (func 0)) (export "mem" (memory 0)))
const export_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> i32
    0x03, 0x02, 0x01, 0x00, // func[0] : type 0
    0x05, 0x03, 0x01, 0x00, 0x01, // memory min 1
    0x07, 0x0b, 0x02, 0x01, 0x66, 0x00, 0x00, 0x03, 0x6d, 0x65, 0x6d, 0x02, 0x00, // export "f"→func0, "mem"→mem0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x07, 0x0b, // code: i32.const 7
};

test "wasm_module_exports: func + memory exports → exporttype_vec (idx → type)" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = export_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);

    var exports: types.ExportTypeVec = undefined;
    wasm_module_exports(m, &exports);
    defer types.wasm_exporttype_vec_delete(&exports);

    try testing.expectEqual(@as(usize, 2), exports.size);
    const e0 = exports.data.?[0].?;
    try testing.expectEqualStrings("f", types.wasm_exporttype_name(e0).?.data.?[0..1]);
    const et0 = types.wasm_exporttype_type(e0).?;
    try testing.expectEqual(types.extern_func, types.wasm_externtype_kind(et0));
    try testing.expectEqual(@as(usize, 1), types.wasm_externtype_as_functype_const(et0).?.results.size);
    const e1 = exports.data.?[1].?;
    try testing.expectEqualStrings("mem", types.wasm_exporttype_name(e1).?.data.?[0..3]);
    try testing.expectEqual(types.extern_memory, types.wasm_externtype_kind(types.wasm_exporttype_type(e1).?));
}

test "wasm_module_exports: null-arg → empty vec, no crash" {
    var exports: types.ExportTypeVec = undefined;
    wasm_module_exports(null, &exports);
    try testing.expectEqual(@as(usize, 0), exports.size);
    wasm_module_exports(null, null);
}

// (module (table (export "t") 1 funcref) (global (export "g") (mut i32) (i32.const 7)))
const global_table_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x04, 0x04, 0x01, 0x70, 0x00, 0x01, // table: funcref min 1
    0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x07, 0x0b, // global: (mut i32) = 7
    0x07, 0x09, 0x02, 0x01, 0x74, 0x01, 0x00, 0x01, 0x67, 0x03, 0x00, // "t"→table0, "g"→global0
};

test "wasm_extern_type: func + memory externs resolve via the module index-space decode" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = export_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const inst = instance.wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    try testing.expectEqual(@as(usize, 2), exports.size);
    const data = exports.data.?;

    const ft = wasm_extern_type(data[0]) orelse return error.NoFuncType;
    defer types.wasm_externtype_delete(ft);
    try testing.expectEqual(types.extern_func, types.wasm_externtype_kind(ft));
    try testing.expectEqual(@as(usize, 0), types.wasm_externtype_as_functype_const(ft).?.params.size);
    try testing.expectEqual(@as(usize, 1), types.wasm_externtype_as_functype_const(ft).?.results.size);

    const mt = wasm_extern_type(data[1]) orelse return error.NoMemType;
    defer types.wasm_externtype_delete(mt);
    try testing.expectEqual(types.extern_memory, types.wasm_externtype_kind(mt));

    try testing.expect(wasm_extern_type(null) == null);
}

test "wasm_extern_type: table + global externs resolve from the cached handle fields" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = global_table_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const inst = instance.wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    try testing.expectEqual(@as(usize, 2), exports.size);
    const data = exports.data.?;

    const tt = wasm_extern_type(data[0]) orelse return error.NoTableType;
    defer types.wasm_externtype_delete(tt);
    try testing.expectEqual(types.extern_table, types.wasm_externtype_kind(tt));

    const gt = wasm_extern_type(data[1]) orelse return error.NoGlobalType;
    defer types.wasm_externtype_delete(gt);
    try testing.expectEqual(types.extern_global, types.wasm_externtype_kind(gt));
}

test "wasm_func_type / arity + wasm_memory_type: from instance exports (() -> i32, mem min 1)" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = export_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const inst = instance.wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const data = exports.data.?;

    const func = instance.wasm_extern_as_func_const(data[0]) orelse return error.NotFunc;
    const ft = wasm_func_type(func) orelse return error.NoFuncType;
    defer types.wasm_functype_delete(ft);
    try testing.expectEqual(@as(usize, 0), ft.params.size);
    try testing.expectEqual(@as(usize, 1), ft.results.size);
    try testing.expectEqual(@as(u8, 0), types.wasm_valtype_kind(ft.results.data.?[0].?)); // i32
    try testing.expectEqual(@as(usize, 0), wasm_func_param_arity(func));
    try testing.expectEqual(@as(usize, 1), wasm_func_result_arity(func));

    const mem = instance.wasm_extern_as_memory_const(data[1]) orelse return error.NotMemory;
    const mt = wasm_memory_type(mem) orelse return error.NoMemType;
    defer types.wasm_memorytype_delete(mt);
    try testing.expectEqual(@as(u32, 1), types.wasm_memorytype_limits(mt).?.min);

    try testing.expect(wasm_func_type(null) == null);
    try testing.expectEqual(@as(usize, 0), wasm_func_param_arity(null));
    try testing.expectEqual(@as(usize, 0), wasm_func_result_arity(null));
    try testing.expect(wasm_memory_type(null) == null);
}

test "wasm_table_type + wasm_global_type: from instance exports (funcref min 1, mut i32)" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = global_table_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const inst = instance.wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const data = exports.data.?;

    const tbl = instance.wasm_extern_as_table_const(data[0]) orelse return error.NotTable;
    const tt = wasm_table_type(tbl) orelse return error.NoTableType;
    defer types.wasm_tabletype_delete(tt);
    try testing.expectEqual(@as(u8, 129), types.wasm_valtype_kind(types.wasm_tabletype_element(tt).?)); // funcref
    try testing.expectEqual(@as(u32, 1), types.wasm_tabletype_limits(tt).?.min);

    const glb = instance.wasm_extern_as_global_const(data[1]) orelse return error.NotGlobal;
    const gt = wasm_global_type(glb) orelse return error.NoGlobalType;
    defer types.wasm_globaltype_delete(gt);
    try testing.expectEqual(@as(u8, 0), types.wasm_valtype_kind(types.wasm_globaltype_content(gt).?)); // i32
    try testing.expectEqual(@as(u8, 1), types.wasm_globaltype_mutability(gt)); // WASM_VAR

    try testing.expect(wasm_table_type(null) == null);
    try testing.expect(wasm_global_type(null) == null);
}
