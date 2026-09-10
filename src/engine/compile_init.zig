//! Post-compile module-init runtime helpers — extracted from
//! `compile.zig` per ADR-0091.
//!
//! Apply / patch / count / declared-* helpers consumed by the
//! Instance lifecycle (runner.zig re-exports a subset). All
//! top-level pub fns; no methods, no state. Re-exported by
//! `compile.zig` so callers reach `compile.applyDefinedGlobalsInit`
//! etc. unchanged (preserves runner.zig's existing re-exports).
//!
//! Zone 2 (`src/engine/`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const parser = @import("../parse/parser.zig");
const sections = @import("../parse/sections.zig");
const zir = @import("../ir/zir.zig");
const FuncType = zir.FuncType;
const linker = @import("codegen/shared/linker.zig");
const canonical_type = @import("codegen/shared/canonical_type.zig");
const rv = @import("runner_validate.zig");
const runner_mod = @import("runner.zig");
const Error = runner_mod.Error;
const CompiledWasm = runner_mod.CompiledWasm;

/// ADR-0052 — write each defined global's init-expression value
/// into `globals_buf` at the per-global byte offset. Scalar
/// globals (i32/i64/f32/f64/refs) → 8 bytes; v128 → 16 bytes.
/// Buffers smaller than `globals_valtypes.len * 16` are rejected.
pub fn applyDefinedGlobalsInit(
    allocator: Allocator,
    wasm_bytes: []const u8,
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
    globals_buf: []u8,
    num_global_imports: u32,
) Error!void {
    if (globals_offsets.len <= num_global_imports) return;
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try parser.parse(ta, wasm_bytes);
    const section = module.find(.global) orelse return;
    var globals_decoded = try sections.decodeGlobals(ta, section.body);
    defer globals_decoded.deinit();
    if (globals_decoded.items.len + num_global_imports != globals_offsets.len) return Error.UnsupportedEntrySignature;
    // Pre-populated imports prefix at [0..num_global_imports) lets
    // `(global.get N)` in defined-global init exprs resolve when
    // N references an imported immutable global (Wasm spec §3.3.3).
    // Callers that haven't populated the import prefix get the
    // ctx but its buf reads zeros — matching pre-cohort-1 behaviour
    // for fixtures that don't use global.get in init exprs.
    for (globals_decoded.items, 0..) |gd, gi| {
        const off = globals_offsets[num_global_imports + gi];
        const vt = globals_valtypes[num_global_imports + gi];
        // §3.3.13.1 — this global's init may read the imports and the
        // globals before it, all written by the time it is evaluated.
        const gctx: rv.GlobalsCtx = .{
            .offsets = globals_offsets,
            .valtypes = globals_valtypes,
            .buf = globals_buf,
            .num_imports = num_global_imports,
            .readable = num_global_imports + @as(u32, @intCast(gi)),
        };
        // Post-ADR-0110 widen: every slot is uniform 16 bytes.
        if (off + 16 > globals_buf.len) return Error.UnsupportedEntrySignature;
        switch (vt) {
            .v128 => {
                const bytes = try rv.evalConstV128Expr(gd.init_expr);
                @memcpy(globals_buf[off..][0..16], &bytes);
            },
            .i32, .i64, .f32, .f64, .ref => {
                // 10.G op_gc cycle 2: i31ref shares the scalar
                // const-expr init shape (low-bit-tagged u32 GcRef
                // per ADR-0116; fits the 8-byte slot like other
                // reftypes). Real `ref.i31` init-expr support
                // lands at sub-chunk 4 (i31 op family); this arm
                // unblocks parse-time global declarations.
                const raw = try rv.evalConstScalarRawCtx(gd.init_expr, gctx);
                std.mem.writeInt(u64, globals_buf[off..][0..8], raw, .little);
            },
        }
    }
}

/// §9.9-III γ.3 (ADR-0068 follow-up): resolve ref.func-initialised
/// funcref globals from raw funcidx (placeholder) to FuncEntity*.
/// Runs AFTER applyDefinedGlobalsInit + func_entities allocation.
pub fn resolveFuncrefGlobals(
    allocator: Allocator,
    wasm_bytes: []const u8,
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
    globals_buf: []u8,
    func_entities: []const @import("../runtime/instance/func.zig").FuncEntity,
    num_global_imports: u32,
) Error!void {
    if (globals_offsets.len <= num_global_imports) return;
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try parser.parse(ta, wasm_bytes);
    const section = module.find(.global) orelse return;
    var globals_decoded = try sections.decodeGlobals(ta, section.body);
    defer globals_decoded.deinit();
    if (globals_decoded.items.len + num_global_imports != globals_offsets.len) return Error.UnsupportedEntrySignature;
    for (globals_decoded.items, 0..) |gd, gi| {
        if (!globals_valtypes[num_global_imports + gi].isFuncref()) continue;
        const fidx = rv.initExprRefFunc(gd.init_expr) orelse continue;
        if (fidx >= func_entities.len) continue;
        const off = globals_offsets[num_global_imports + gi];
        // Post-ADR-0110 widen: every slot is uniform 16 bytes; an 8-byte
        // scalar write lands in the low half of the slot.
        if (off + 16 > globals_buf.len) return Error.UnsupportedEntrySignature;
        std.mem.writeInt(u64, globals_buf[off..][0..8], @intFromPtr(&func_entities[fidx]), .little);
    }
}

/// D-063 (§9.9 / 9.9-h-4) — populate caller-owned funcptrs+typeidxs
/// from active element segments. Mirrors c_api `setupRuntime` shape.
/// `typeidxs_buf` is pre-seeded to maxInt(u32) (no-func sentinel).
pub fn applyTableInit(
    allocator: Allocator,
    wasm_bytes: []const u8,
    compiled: *const CompiledWasm,
    funcptrs_buf: []u64,
    typeidxs_buf: []u32,
) Error!void {
    return applyTableInitForTable(allocator, wasm_bytes, compiled, 0, funcptrs_buf, typeidxs_buf);
}

/// Ctx-aware variant per close-plan §6 (j) Step B cohort 1.
/// `(elem (offset (global.get N)) ...)` resolves N against the
/// importer-side global buffer when ctx is non-null.
pub fn applyTableInitCtx(
    allocator: Allocator,
    wasm_bytes: []const u8,
    compiled: *const CompiledWasm,
    funcptrs_buf: []u64,
    typeidxs_buf: []u32,
    ctx: ?rv.GlobalsCtx,
) Error!void {
    return applyTableInitForTableCtx(allocator, wasm_bytes, compiled, 0, funcptrs_buf, typeidxs_buf, ctx);
}

/// §9.9 / 9.9-l-1b-d093-d42b (D-112): per-table variant of
/// `applyTableInit`. `tableidx` selects which declared table's
/// active element segments are applied; segments targeting any
/// other table are skipped. Used by spec_assert harness's
/// `setupMultiTableScratch` to populate per-table
/// funcptr/typeidx scratch arrays for non-zero tables.
pub fn applyTableInitForTable(
    allocator: Allocator,
    wasm_bytes: []const u8,
    compiled: *const CompiledWasm,
    tableidx: u32,
    funcptrs_buf: []u64,
    typeidxs_buf: []u32,
) Error!void {
    return applyTableInitForTableCtx(allocator, wasm_bytes, compiled, tableidx, funcptrs_buf, typeidxs_buf, null);
}

pub fn applyTableInitForTableCtx(
    allocator: Allocator,
    wasm_bytes: []const u8,
    compiled: *const CompiledWasm,
    tableidx: u32,
    funcptrs_buf: []u64,
    typeidxs_buf: []u32,
    ctx: ?rv.GlobalsCtx,
) Error!void {
    if (funcptrs_buf.len != typeidxs_buf.len) return Error.UnsupportedEntrySignature;
    @memset(funcptrs_buf, 0);
    @memset(typeidxs_buf, std.math.maxInt(u32));

    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try parser.parse(ta, wasm_bytes);
    const section = module.find(.element) orelse return;
    var elems = try sections.decodeElement(ta, section.body);
    defer elems.deinit();

    // D-111: canonicalize the funcref's stored typeidx so the
    // call_indirect runtime sig check (`CMP EAX, #canonical`)
    // matches structurally-equivalent types declared at different
    // typeidx (Wasm spec §3.4.6 + §4.4.10.1). The codegen side
    // canonicalizes the call_indirect's annotated typeidx
    // identically; both sides see the lowest-index typeidx for a
    // given shape, so the bytewise compare implements structural
    // matching. Module types are decoded once (re-parsed from the
    // wasm bytes — the temp arena scope keeps the slice alive
    // through the loop).
    const types_section = module.find(.type) orelse {
        // No types section ⇒ no funcs ⇒ no element-segment funcidxs
        // to write. Spec-malformed modules with elems but no types
        // would fail earlier in compileWasm.
        return;
    };
    var types = try sections.decodeTypes(ta, types_section.body);
    defer types.deinit();

    for (elems.items) |seg| {
        if (seg.kind != .active) continue;
        if (seg.tableidx != tableidx) continue;
        // D-475: a table64 elem offset is an `i64.const` (or i64 global.get)
        // — evaluate at u64 width; guard `base` first so the sum can't wrap.
        const off_u = rv.evalConstOffsetU64Ctx(seg.offset_expr, ctx) catch return Error.UnsupportedEntrySignature;
        const base: usize = std.math.cast(usize, off_u) orelse return Error.UnsupportedEntrySignature;
        if (base > funcptrs_buf.len or base + seg.funcidxs.len > funcptrs_buf.len) return Error.UnsupportedEntrySignature;
        for (seg.funcidxs, 0..) |fidx, i| {
            if (fidx == std.math.maxInt(u32)) continue; // ref.null funcref
            // Close-plan §6 (j) Step B cohort 6 — global.get N marker:
            // dereference the imported funcref global at
            // `scratch_globals[ctx.offsets[N]]` (= 8-byte FuncEntity
            // pointer, populated by the spec runner's
            // applyImportedGlobalsFromRegistered) and copy out
            // .funcptr / .typeidx for the table entry.
            if (sections.elemEntryIsGlobalGet(fidx)) {
                const c = ctx orelse return Error.UnsupportedEntrySignature;
                const gidx = sections.elemEntryGlobalIdx(fidx);
                if (gidx >= c.num_imports or gidx >= c.offsets.len) return Error.UnsupportedEntrySignature;
                const g_off = c.offsets[gidx];
                if (g_off + 8 > c.buf.len) return Error.UnsupportedEntrySignature;
                const ptr_value = std.mem.readInt(u64, c.buf[g_off..][0..8], .little);
                if (ptr_value == 0) continue; // null funcref via uninitialised global
                const FuncEntity = @import("../runtime/instance/func.zig").FuncEntity;
                const fe: *const FuncEntity = @ptrFromInt(@as(usize, @intCast(ptr_value)));
                funcptrs_buf[base + i] = fe.funcptr;
                typeidxs_buf[base + i] = fe.typeidx;
                continue;
            }
            if (fidx >= compiled.func_sigs.len) return Error.UnsupportedEntrySignature;
            const f_off = compiled.module.func_offsets[fidx];
            const raw_typeidx = compiled.func_typeidxs[fidx];
            typeidxs_buf[base + i] = canonical_type.canonicalTypeidx(types.items, raw_typeidx);
            if (f_off == linker.IMPORT_SENTINEL_OFFSET) continue;
            funcptrs_buf[base + i] = @intFromPtr(compiled.module.block.bytes.ptr + f_off);
        }
    }
}

/// §9.9-III (c)-2.3-γ-5 per ADR-0066: for `tableidx`'s active
/// element segments, substitute `dispatch[fidx]` (bridge-thunk
/// addr from β-2b's resolver) into `funcptrs_buf` for any
/// import entry (fidx < num_imports). Discharges the
/// `applyTableInitForTable` IMPORT_SENTINEL → funcptr=0 path
/// that would SEGV on `call_indirect`. No-op when `dispatch`
/// is empty.
pub fn patchTableImportFuncptrs(allocator: Allocator, wasm_bytes: []const u8, num_imports: u32, tableidx: u32, dispatch: []const usize, funcptrs_buf: []u64) Error!void {
    return patchTableImportFuncptrsCtx(allocator, wasm_bytes, num_imports, tableidx, dispatch, funcptrs_buf, null);
}

pub fn patchTableImportFuncptrsCtx(allocator: Allocator, wasm_bytes: []const u8, num_imports: u32, tableidx: u32, dispatch: []const usize, funcptrs_buf: []u64, ctx: ?rv.GlobalsCtx) Error!void {
    if (num_imports == 0 or dispatch.len == 0) return;
    var ta = std.heap.ArenaAllocator.init(allocator);
    defer ta.deinit();
    const a = ta.allocator();
    var module = try parser.parse(a, wasm_bytes);
    const sec = module.find(.element) orelse return;
    var elems = try sections.decodeElement(a, sec.body);
    defer elems.deinit();
    for (elems.items) |seg| {
        if (seg.kind != .active or seg.tableidx != tableidx) continue;
        // D-475: u64-width offset eval + wrap-safe base guard (a huge
        // base would wrap `base + i` back into bounds otherwise).
        const off_u = rv.evalConstOffsetU64Ctx(seg.offset_expr, ctx) catch return Error.UnsupportedEntrySignature;
        const base: usize = std.math.cast(usize, off_u) orelse return Error.UnsupportedEntrySignature;
        if (base >= funcptrs_buf.len) continue;
        for (seg.funcidxs, 0..) |fidx, i| {
            if (fidx >= num_imports or fidx >= dispatch.len or base + i >= funcptrs_buf.len) continue;
            funcptrs_buf[base + i] = dispatch[fidx];
        }
    }
}

/// §9.9 / 9.9-l-1b-d093-d42b (D-112): count the number of
/// declared tables in `wasm_bytes`. Used by spec_assert harness
/// to decide whether multi-table scratch needs to be wired.
/// Returns 0 when the module has no table section.
pub fn countDeclaredTables(allocator: Allocator, wasm_bytes: []const u8) u32 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = parser.parse(ta, wasm_bytes) catch return 0;
    const section = module.find(.table) orelse return 0;
    var tables = sections.decodeTables(ta, section.body) catch return 0;
    defer tables.deinit();
    return @intCast(tables.items.len);
}

/// §9.9 / 9.9-l-1b-d093-d42b (D-112): per-table size lookup
/// (table `tableidx`'s declared `min`). Returns 0 when the
/// module has no table section OR `tableidx` is out of range.
pub fn declaredTableMin(allocator: Allocator, wasm_bytes: []const u8, tableidx: u32) u32 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = parser.parse(ta, wasm_bytes) catch return 0;
    const section = module.find(.table) orelse return 0;
    var tables = sections.decodeTables(ta, section.body) catch return 0;
    defer tables.deinit();
    if (tableidx >= tables.items.len) return 0;
    // table64 min is u64; this JIT cap helper is u32 (i64 tables are
    // JIT-guarded) — saturate defensively rather than truncate.
    return std.math.cast(u32, tables.items[tableidx].min) orelse std.math.maxInt(u32);
}

/// §9.9 / 9.9-l-1b-d093-d48 (D-122/D-125): per-table declared
/// `max` lookup. Returns `null` when the table has no max OR the
/// module has no table section OR `tableidx` is out of range.
/// Consumed by spec_assert harness to populate `TableSlice.max`
/// so JIT `table.grow`'s callout can enforce the cap (Wasm 2.0
/// §4.4.10.1 host-refuses-growth semantics).
pub fn declaredTableMax(allocator: Allocator, wasm_bytes: []const u8, tableidx: u32) ?u32 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = parser.parse(ta, wasm_bytes) catch return null;
    const section = module.find(.table) orelse return null;
    var tables = sections.decodeTables(ta, section.body) catch return null;
    defer tables.deinit();
    if (tableidx >= tables.items.len) return null;
    const m = tables.items[tableidx].max orelse return null;
    return std.math.cast(u32, m) orelse std.math.maxInt(u32);
}

/// Apply active data segments from `wasm_bytes` into `memory`
/// (a caller-owned buffer, e.g. a fixed-size scratch arena).
/// Mirrors the data-init half of `setupRuntime` (§9.9 / 9.9-d-7)
/// so spec-test runners reuse a stable scratch_memory across
/// modules. Rejects: negative offset, offset+bytes > memory.len,
/// non-const offset_expr. Passive / declarative skipped.
pub fn applyActiveDataSegments(
    allocator: Allocator,
    wasm_bytes: []const u8,
    memory: []u8,
) Error!void {
    return applyActiveDataSegmentsCtx(allocator, wasm_bytes, memory, null);
}

/// Ctx-aware variant per close-plan §6 (j) Step B cohort 1.
/// Resolves `(data (offset (global.get N)) ...)` when N references
/// an imported immutable global whose value is in `ctx.buf` at
/// `ctx.offsets[N]`.
pub fn applyActiveDataSegmentsCtx(
    allocator: Allocator,
    wasm_bytes: []const u8,
    memory: []u8,
    ctx: ?rv.GlobalsCtx,
) Error!void {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try parser.parse(ta, wasm_bytes);
    if (module.find(.data)) |s| {
        var datas = try sections.decodeData(ta, s.body);
        defer datas.deinit();
        for (datas.items) |seg| {
            if (seg.kind != .active) continue;
            const off = rv.evalConstI32ExprCtx(seg.offset_expr, ctx) catch return Error.UnsupportedEntrySignature;
            if (off < 0) return Error.UnsupportedEntrySignature;
            const off_u: u64 = @intCast(off);
            if (off_u + seg.bytes.len > memory.len) return Error.UnsupportedEntrySignature;
            @memcpy(memory[@intCast(off_u)..][0..seg.bytes.len], seg.bytes);
        }
    }
}
