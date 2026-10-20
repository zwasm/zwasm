//! Full-fidelity `.cwasm` v0.5 deserializer (ADR-0203 stage 2 / D2).
//!
//! Rebuilds a REAL `runner.CompiledWasm` from a `.cwasm` so the normal
//! setup path (`setupRuntimeLinked`) — and therefore memory.grow, WASI,
//! GC, EH, fuel/interrupt — works identically to a fresh compile
//! (cache-hit == cache-miss). Two-source reconstruction:
//!
//!  - MODULE METADATA (func_sigs, typeidxs, import counts, globals layout,
//!    tag params, exports) is RE-DERIVED from the artifact's embedded
//!    original `wasm_bytes` using the SAME section decoders `compileWasm`
//!    uses — single source of truth, no re-encode divergence (the loops
//!    mirror `compile.zig`; line refs inline).
//!  - COMPILER OUTPUT (machine code, call fixups, frame sizes, oob stub
//!    offsets, the module exception table) comes from the artifact's
//!    code/meta/reloc/func_extras/eh sections, and is RE-LINKED through
//!    the same `linker.linkWithThunks` a fresh compile uses — thunks,
//!    func_offsets, and the code map are regenerated in THIS process
//!    (the wazero model: nothing address-bound is trusted from disk).
//!
//! The serialized exception table's module-relative pcs stay valid
//! because `linkWithThunks` layout is a pure function of the (identical)
//! bodies + wrapper specs; the stage-2 round-trip exit test invokes an
//! EH module through the deserialized instance, so a layout drift can
//! not land silently.
//!
//! `CompiledWasm.func_results` is left EMPTY (zero-length allocation):
//! nothing reads it at runtime (only `deinit` and the producer do), and
//! a deserialized module is never re-produced.
//!
//! Zone 2 (`src/engine/codegen/aot/`).

const std = @import("std");
const builtin = @import("builtin");

const format = @import("format.zig");
const parser = @import("../../../parse/parser.zig");
const sections = @import("../../../parse/sections.zig");
const zir = @import("../../../ir/zir.zig");
const runner = @import("../../runner.zig");
const compile_mod = @import("../../compile.zig");
const export_lookup = @import("../../export_lookup.zig");
const runtime_mod = @import("../../../runtime/runtime.zig");
const linker = @import("../shared/linker.zig");
const exception_table = @import("../shared/exception_table.zig");

const Allocator = std.mem.Allocator;

pub const Error = format.Error || linker.Error || sections.Error ||
    parser.Error || runner.Error || Allocator.Error || error{
    ArchMismatch,
    TruncatedImage,
    /// ADR-0202 D5 "non-D1-host reject": an ELIDED artifact's code has no
    /// inline bounds checks — running it on a host without guarded-memory
    /// support would be a silent-OOB hole. Today every jit_mem-capable
    /// platform is also guarded_mem-capable (the guard is vacuous), but the
    /// coupling is memory-safety-load-bearing, so the loader enforces it
    /// explicitly rather than by set-inclusion coincidence.
    ElidedArtifactNeedsGuardedHost,
};

pub const Deserialized = struct {
    compiled: runner.CompiledWasm,
    /// The embedded original module bytes — a view INTO the caller's
    /// `cwasm_bytes` buffer. The caller keeps that buffer alive for the
    /// setup call (`setupRuntimeLinked(compiled, wasm_bytes, ...)`).
    wasm_bytes: []const u8,
};

fn sectionSlice(cwasm: []const u8, offset: u32, size: u32) Error![]const u8 {
    if (@as(u64, offset) + size > cwasm.len) return Error.TruncatedImage;
    return cwasm[offset..][0..size];
}

/// The artifact's embedded ORIGINAL module bytes (a view into `cwasm_bytes`).
/// CLI-side helpers (export-type lookups for `--invoke` arg packing /
/// multi-result sizing) read module metadata through this so a `.cwasm`
/// behaves byte-identically to its source `.wasm`.
pub fn embeddedWasmBytes(cwasm_bytes: []const u8) Error![]const u8 {
    const h = try format.parseHeader(cwasm_bytes);
    return sectionSlice(cwasm_bytes, h.wasm_bytes_offset, h.wasm_bytes_size);
}

/// Deserialize a `.cwasm` v0.5 into a full `CompiledWasm`. Caller owns
/// the result (`compiled.deinit(allocator)`); `cwasm_bytes` must outlive
/// the returned value (the embedded wasm view aliases it).
pub fn deserializeToCompiledWasm(allocator: Allocator, cwasm_bytes: []const u8) Error!Deserialized {
    const h = try format.parseHeader(cwasm_bytes);
    const native_arch: u32 = switch (builtin.target.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => return Error.ArchMismatch,
    };
    if (h.arch != native_arch) return Error.ArchMismatch;
    // ADR-0202 D5 — reject an elided artifact on a non-guarded host (see
    // the Error variant doc; vacuous today, load-bearing by design).
    if ((h.flags & format.flag_bounds_elided) != 0 and
        !@import("../../../platform/guarded_mem.zig").supported)
    {
        return Error.ElidedArtifactNeedsGuardedHost;
    }

    const wasm_bytes = try sectionSlice(cwasm_bytes, h.wasm_bytes_offset, h.wasm_bytes_size);
    const code = try sectionSlice(cwasm_bytes, h.code_offset, h.code_size);
    const meta_bytes = try sectionSlice(cwasm_bytes, h.metadata_offset, h.metadata_size);
    const reloc_bytes = try sectionSlice(cwasm_bytes, h.relocs_offset, h.relocs_size);
    const extras_bytes = try sectionSlice(cwasm_bytes, h.func_extras_offset, h.func_extras_size);
    const eh_bytes = try sectionSlice(cwasm_bytes, h.eh_offset, h.eh_size);
    if (meta_bytes.len < @as(u64, h.n_funcs) * format.func_meta_size) return Error.TruncatedFuncMeta;
    if (extras_bytes.len < @as(u64, h.n_funcs) * format.func_extra_size) return Error.TruncatedFuncMeta;

    // ---- Module metadata, re-derived from the embedded wasm bytes with
    // the same decoders compileWasm uses. Arena mirrors compileWasm's
    // (types + export names live there; compile.zig:65).
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var module = try parser.parse(allocator, wasm_bytes);
    defer module.deinit(allocator);

    // Types (mirrors compile.zig:623 — arena-backed; FuncType param/result
    // slices in func_sigs alias these and share the CompiledWasm lifetime).
    // No type section is an empty type space, as compileWasm's no-function
    // early return treats it; a typeidx into it fails the range checks below.
    const types: []const zir.FuncType = if (module.find(.type)) |ts|
        (try sections.decodeTypes(a, ts.body)).items
    else
        &.{};

    // Imports (mirrors compile.zig:74-76 + :644-648).
    var imports_buf: ?sections.Imports = null;
    defer if (imports_buf) |*ib| ib.deinit();
    if (module.find(.import)) |s| imports_buf = try sections.decodeImports(allocator, s.body);
    var num_imports: u32 = 0;
    var num_global_imports: u32 = 0;
    if (imports_buf) |ib| for (ib.items) |imp| {
        if (imp.kind == .func) num_imports += 1 else if (imp.kind == .global) num_global_imports += 1;
    };
    if (num_imports != h.n_imports) return Error.TruncatedImage; // artifact/bytes disagree

    // Defined-function typeidx list (mirrors compile.zig:627).
    const defined_func_typeidx: []const u32 = if (module.find(.function)) |fs|
        try sections.decodeFunctions(a, fs.body)
    else
        &.{};
    if (defined_func_typeidx.len != h.n_funcs) return Error.TruncatedImage;

    // Unified wasm-space func_sigs/typeidxs (mirrors compile.zig:650-673).
    const total_funcs = num_imports + @as(u32, @intCast(defined_func_typeidx.len));
    const func_sigs = try allocator.alloc(zir.FuncType, total_funcs);
    errdefer allocator.free(func_sigs);
    const func_typeidxs = try allocator.alloc(u32, total_funcs);
    errdefer allocator.free(func_typeidxs);
    if (imports_buf) |ib| {
        var w: u32 = 0;
        for (ib.items) |imp| {
            if (imp.kind != .func) continue;
            const tidx = imp.payload.func_typeidx;
            if (tidx >= types.len) return Error.MissingTypeSection;
            func_sigs[w] = types[tidx];
            func_typeidxs[w] = tidx;
            w += 1;
        }
    }
    for (defined_func_typeidx, 0..) |type_idx, i| {
        if (type_idx >= types.len) return Error.MissingTypeSection;
        func_sigs[num_imports + i] = types[type_idx];
        func_typeidxs[num_imports + i] = type_idx;
    }

    // Globals layout (mirrors compile.zig:783-787 — same pure helper).
    const elay = try export_lookup.computeGlobalsLayout(allocator, wasm_bytes);
    const globals_offsets = elay.offsets;
    errdefer allocator.free(globals_offsets);
    const globals_valtypes = elay.valtypes;
    errdefer allocator.free(globals_valtypes);

    // Tag param/slot counts over the FULL tag space (mirrors
    // compile.zig:967-1030 — imports prefix + defined).
    var imp_tag_count: usize = 0;
    if (imports_buf) |ib| for (ib.items) |imp| {
        if (imp.kind == .tag) imp_tag_count += 1;
    };
    const defined_tags: []const sections.TagEntry = if (module.find(.tag)) |ts|
        try sections.decodeTags(a, ts.body)
    else
        &.{};
    const tags_slice: []const sections.TagEntry = if (imp_tag_count == 0)
        defined_tags
    else blk: {
        const combined = try a.alloc(sections.TagEntry, imp_tag_count + defined_tags.len);
        var ci: usize = 0;
        if (imports_buf) |ib| for (ib.items) |imp| {
            if (imp.kind != .tag) continue;
            combined[ci] = .{ .attribute = 0, .typeidx = imp.payload.tag_typeidx };
            ci += 1;
        };
        for (defined_tags) |t| {
            combined[ci] = t;
            ci += 1;
        }
        break :blk combined;
    };
    const tag_param_counts: []u32 = blk: {
        if (tags_slice.len == 0) break :blk &.{};
        const out = try allocator.alloc(u32, tags_slice.len);
        errdefer allocator.free(out);
        for (tags_slice, 0..) |tag, i| {
            if (tag.typeidx >= types.len) return Error.InvalidFuncIndex;
            out[i] = @intCast(types[tag.typeidx].params.len);
        }
        break :blk out;
    };
    errdefer if (tag_param_counts.len > 0) allocator.free(tag_param_counts);
    const tag_param_slot_counts: []u32 = blk: {
        if (tags_slice.len == 0) break :blk &.{};
        const out = try allocator.alloc(u32, tags_slice.len);
        errdefer allocator.free(out);
        for (tags_slice, 0..) |tag, i| {
            if (tag.typeidx >= types.len) return Error.InvalidFuncIndex;
            var slots: u32 = 0;
            for (types[tag.typeidx].params) |p| {
                slots += runtime_mod.slotCountForValType(p);
            }
            out[i] = slots;
        }
        break :blk out;
    };
    errdefer if (tag_param_slot_counts.len > 0) allocator.free(tag_param_slot_counts);

    // Exports (same helper as compileWasm; arena-owned names).
    const func_exports = try compile_mod.collectFuncExports(a, &module, total_funcs);

    // ---- Compiler output, reconstructed from the artifact.
    // Per-func bodies view into the code section + per-func extras.
    const n_funcs: usize = h.n_funcs;
    var metas = try allocator.alloc(format.CwasmFuncMeta, n_funcs);
    defer allocator.free(metas);
    for (0..n_funcs) |i| {
        metas[i] = try format.parseFuncMeta(meta_bytes[i * format.func_meta_size ..][0..format.func_meta_size]);
        if (@as(u64, metas[i].code_offset) + metas[i].code_size > code.len) return Error.TruncatedImage;
    }

    // Regroup the flat reloc section into per-func fixup lists. Serialized
    // reloc offsets are code-SECTION-relative (serialise.zig rebases at
    // write); invert via each func's [code_offset, +code_size) range.
    const n_relocs = reloc_bytes.len / format.reloc_size;
    var fixup_counts = try allocator.alloc(u32, n_funcs);
    defer allocator.free(fixup_counts);
    @memset(fixup_counts, 0);
    var reloc_owner = try allocator.alloc(u32, n_relocs);
    defer allocator.free(reloc_owner);
    var parsed_relocs = try allocator.alloc(format.CwasmReloc, n_relocs);
    defer allocator.free(parsed_relocs);
    for (0..n_relocs) |ri| {
        const r = try format.parseReloc(reloc_bytes[ri * format.reloc_size ..][0..format.reloc_size]);
        parsed_relocs[ri] = r;
        const owner = blk: {
            for (metas, 0..) |m, fi| {
                if (r.code_offset >= m.code_offset and r.code_offset < @as(u64, m.code_offset) + m.code_size)
                    break :blk fi;
            }
            return Error.TruncatedReloc;
        };
        reloc_owner[ri] = @intCast(owner);
        fixup_counts[owner] += 1;
    }
    // CallFixup lists (linker input; freed after link).
    const CallFixup = std.meta.Child(@FieldType(linker.FuncBody, "call_fixups"));
    var fixup_storage = try allocator.alloc(CallFixup, n_relocs);
    defer allocator.free(fixup_storage);
    var fixup_slices = try allocator.alloc([]CallFixup, n_funcs);
    defer allocator.free(fixup_slices);
    {
        var cursor: usize = 0;
        for (0..n_funcs) |fi| {
            fixup_slices[fi] = fixup_storage[cursor..][0..fixup_counts[fi]];
            cursor += fixup_counts[fi];
        }
        var write_idx = try allocator.alloc(u32, n_funcs);
        defer allocator.free(write_idx);
        @memset(write_idx, 0);
        for (0..n_relocs) |ri| {
            const fi = reloc_owner[ri];
            const r = parsed_relocs[ri];
            fixup_slices[fi][write_idx[fi]] = .{
                .byte_offset = r.code_offset - metas[fi].code_offset,
                .target_func_idx = r.target_func_idx,
            };
            write_idx[fi] += 1;
        }
    }

    var bodies = try allocator.alloc(linker.FuncBody, n_funcs);
    defer allocator.free(bodies);
    for (0..n_funcs) |i| {
        const extra = try format.parseFuncExtra(extras_bytes[i * format.func_extra_size ..][0..format.func_extra_size]);
        bodies[i] = .{
            .bytes = code[metas[i].code_offset..][0..metas[i].code_size],
            .call_fixups = fixup_slices[i],
            .frame_bytes = extra.frame_bytes,
            .oob_stub_off = extra.oob_stub_off,
        };
    }

    // Wrapper specs (mirrors compile.zig's derivation: multi-result, or
    // exported with >= 1 param — host-invocable shapes need a thunk).
    var exported_funcs: std.AutoHashMap(u32, void) = .init(allocator);
    defer exported_funcs.deinit();
    for (func_exports) |e| try exported_funcs.put(e.func_idx, {});
    var wrapper_specs_list: std.ArrayList(linker.WrapperSpec) = .empty;
    defer wrapper_specs_list.deinit(allocator);
    for (0..n_funcs) |i| {
        const wasm_idx = num_imports + @as(u32, @intCast(i));
        const sig = func_sigs[wasm_idx];
        const wants_thunk = sig.results.len >= 2 or
            (sig.params.len >= 1 and exported_funcs.contains(wasm_idx));
        if (wants_thunk) {
            try wrapper_specs_list.append(allocator, .{ .func_idx = wasm_idx, .sig = sig });
        }
    }

    const linked = try linker.linkWithThunks(allocator, bodies, num_imports, wrapper_specs_list.items);
    errdefer {
        var l = linked;
        l.deinit(allocator);
    }

    // Module exception table from the artifact (pcs module-relative; see
    // the module doc for why they survive the re-link).
    const n_eh = std.mem.readInt(u32, eh_bytes[0..4], .little);
    if (eh_bytes.len < 4 + @as(u64, n_eh) * format.eh_entry_size) return Error.TruncatedEhEntry;
    const eh_entries: []exception_table.HandlerEntry = if (n_eh == 0) &.{} else blk: {
        const out = try allocator.alloc(exception_table.HandlerEntry, n_eh);
        errdefer allocator.free(out);
        for (0..n_eh) |i| {
            const e = try format.parseEhEntry(eh_bytes[4 + i * format.eh_entry_size ..][0..format.eh_entry_size]);
            out[i] = .{
                .pc_start = e.pc_start,
                .pc_end = e.pc_end,
                .tag_idx = if (e.tag_idx == format.eh_tag_none) null else e.tag_idx,
                .landing_pad_pc = e.landing_pad_pc,
                .kind = @enumFromInt(e.kind),
            };
        }
        break :blk out;
    };
    errdefer if (eh_entries.len > 0) allocator.free(eh_entries);

    // func_results stays a real (freeable) zero-length allocation — see
    // the module doc.
    const empty_results = try allocator.alloc(std.meta.Child(@FieldType(runner.CompiledWasm, "func_results")), 0);

    return .{
        .compiled = .{
            .module = linked,
            .func_results = empty_results,
            .func_sigs = func_sigs,
            .func_typeidxs = func_typeidxs,
            .num_imports = num_imports,
            .globals_offsets = globals_offsets,
            .globals_valtypes = globals_valtypes,
            .num_global_imports = num_global_imports,
            .tag_param_counts = tag_param_counts,
            .tag_param_slot_counts = tag_param_slot_counts,
            .exception_table = .{ .entries = eh_entries },
            .exports = func_exports,
            // ADR-0203 stage 4 — restored from the header flag; the re-link
            // above already re-registered the oob-stub trap entries and
            // setup will bind the guarded reservation (loud-fail, no
            // plain-heap fallback for a qualifying memory).
            .bounds_elided = (h.flags & format.flag_bounds_elided) != 0,
            .arena = arena,
        },
        .wasm_bytes = wasm_bytes,
    };
}

// =====================================================================
// Stage-2 exit test (ADR-0203): produce → deserialize → the NORMAL
// setup path → invoke, compared against a fresh compile. The module
// deliberately exercises the D-518 shape ((start) writes memory; the
// export reads it back) so the round-trip proves memory + start-func
// fidelity through the FULL runtime — the two things the mini-runtime
// path can't do.
// =====================================================================

const testing = std.testing;
const produce = @import("produce.zig");

test "v0.5 round-trip: produce → deserialize → fromCompiled → invoke == fresh (stage-2 exit)" {
    // (module (memory 1)
    //   (func $init (i32.store (i32.const 0) (i32.const 42)))
    //   (start $init)
    //   (func (export "main") (result i32) (i32.load (i32.const 0))))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=()->(), [1]=()->(i32)
        0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x00,
        0x01, 0x7f,
        // func: [0]=type0 ($init), [1]=type1 (main)
        0x03, 0x03, 0x02, 0x00, 0x01,
        // memory: 1 page
        0x05,
        0x03, 0x01, 0x00, 0x01,
        // export "main" -> func 1
        0x07, 0x08, 0x01, 0x04,
        0x6d, 0x61, 0x69, 0x6e, 0x00, 0x01,
        // start: func 0
        0x08, 0x01,
        0x00,
        // code: $init = i32.const 0; i32.const 42; i32.store; end
        //       main  = i32.const 0; i32.load; end
        0x0a, 0x13, 0x02, 0x09, 0x00, 0x41, 0x00,
        0x41, 0x2a, 0x36, 0x02, 0x00, 0x0b, 0x07, 0x00,
        0x41, 0x00, 0x28, 0x02, 0x00, 0x0b,
    };

    // Fresh path (ambient bounds mode).
    var fresh = try runner.JitInstance.init(testing.allocator, &bytes);
    defer fresh.deinit(testing.allocator);
    try fresh.runStart();
    const fresh_r = try fresh.invoke(testing.allocator, "main", &.{});
    try testing.expectEqual(@as(?u64, 42), fresh_r);

    // AOT path: compile-for-AOT → produce → deserialize → SAME setup.
    var for_aot = try compile_mod.compileWasmForAot(testing.allocator, &bytes);
    const cwasm = blk: {
        defer for_aot.deinit(testing.allocator);
        break :blk try produce.produceFromCompiledWasm(testing.allocator, &for_aot, &bytes);
    };
    defer testing.allocator.free(cwasm);

    const des = try deserializeToCompiledWasm(testing.allocator, cwasm);

    // Metadata parity vs a fresh compile (the re-derive loops must agree).
    {
        var ref = try compile_mod.compileWasm(testing.allocator, &bytes);
        defer ref.deinit(testing.allocator);
        try testing.expectEqual(ref.num_imports, des.compiled.num_imports);
        try testing.expectEqual(ref.num_global_imports, des.compiled.num_global_imports);
        try testing.expectEqual(ref.func_sigs.len, des.compiled.func_sigs.len);
        try testing.expectEqual(ref.func_typeidxs.len, des.compiled.func_typeidxs.len);
        for (ref.func_typeidxs, des.compiled.func_typeidxs) |want, got| {
            try testing.expectEqual(want, got);
        }
        try testing.expectEqual(ref.exports.len, des.compiled.exports.len);
        try testing.expectEqual(ref.exception_table.entries.len, des.compiled.exception_table.entries.len);
    }

    // The embedded bytes are the original module, verbatim.
    try testing.expectEqualSlices(u8, &bytes, des.wasm_bytes);

    var inst = try runner.JitInstance.fromCompiled(testing.allocator, des.compiled, des.wasm_bytes);
    defer inst.deinit(testing.allocator);
    try inst.runStart(); // D-518 shape: start must run through the full path
    const aot_r = try inst.invoke(testing.allocator, "main", &.{});
    try testing.expectEqual(fresh_r, aot_r);
}
