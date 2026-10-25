//! `.cwasm` v0.1 producer orchestrator (per
//! ADR-0039).
//!
//! Takes a `CompiledWasm` (the JIT pipeline's output, per
//! `src/engine/runner.zig:84:compileWasm`) and produces a
//! `.cwasm` byte stream. Bridges the per-func emit outputs
//! (bytes + n_slots + call_fixups) into the arch-blind
//! `Input` shape consumed by `serialise.produceCwasm`.
//!
//! Pipeline reuse per ADR-0039 §"Decision":
//!   wasm bytes
//!   → parse / validate / lower / liveness / regalloc / coalesce / emit
//!   → CompiledWasm { func_results, func_sigs, num_imports, … }
//!   → produceFromCompiledWasm                      (this module)
//!   → serialise.produceCwasm                       (format wrapper)
//!   → .cwasm bytes
//!
//! Zone 2 (`src/engine/codegen/aot/`).

const std = @import("std");
const builtin = @import("builtin");

const format = @import("format.zig");
const serialise = @import("serialise.zig");

const dbg = @import("../../../support/dbg.zig");
const zir = @import("../../../ir/zir.zig");
const runner = @import("../../runner.zig");
const parser = @import("../../../parse/parser.zig");
const sections = @import("../../../parse/sections.zig");
const instantiate = @import("../../../runtime/instance/instantiate.zig");
const runner_validate = @import("../../runner_validate.zig");
const canonical_type = @import("../shared/canonical_type.zig");

const Allocator = std.mem.Allocator;

pub const Error = serialise.Error || error{
    ParamCountTooLarge,
    ResultCountTooLarge,
    UnsupportedHostArch,
    /// A defined global's init-expr is outside the cycle-1 subset
    /// (simple i32/i64/f/v128.const + ref.null). ref.func / global.get-import
    /// / struct.new globals are cycle-2 — surfaced loudly, not zero-filled.
    UnsupportedGlobalInit,
    /// Re-parsing `wasm_bytes` for the global/memory sections failed (should
    /// not happen — `compileWasm` already parsed+validated the same bytes).
    GlobalSectionParseFailed,
    /// A memory/data segment is outside the cycle-1b subset (a
    /// non-const active-data offset, or a memory larger than the loader cap).
    UnsupportedMemoryState,
    /// A table/element segment is outside the cycle-2a subset (a
    /// non-const active-elem offset, or an offset past u32).
    UnsupportedTableState,
    /// ADR-0203 stage 2 (D-519) — an active `ZWASM_DEBUG` channel can
    /// instrument emitted code with this process's diagnostic-counter
    /// ABSOLUTE addresses (`jit.callcount` / `global.trace`); such bytes
    /// must never be serialized. Re-run `zwasm compile` without
    /// `ZWASM_DEBUG`.
    DbgInstrumentedNotAotSerializable,
};

/// Table-0 + element state collected for the producer (v0.3 cycle-2a).
pub const TableState = struct {
    has_table: bool = false,
    table0_size: u32 = 0,
    /// Active element segments; `funcidxs` allocator-owned (duped — the
    /// decoder's are arena-backed, freed before serialise).
    elem: []format.CwasmElemSeg = &.{},
    /// Canonical typeidx per defined function (allocator-owned). Empty when
    /// no table (canon typeidx only matters for table slots).
    canon_typeidx: []u32 = &.{},
};

/// Linear-memory state collected for the producer (v0.3 cycle-1b).
pub const MemoryState = struct {
    has_memory: bool = false,
    min_pages: u32 = 0,
    max_pages: u32 = format.memory_max_none,
    /// Active data segments (offset pre-evaluated); `bytes` alias `wasm_bytes`.
    data: []format.CwasmDataSeg = &.{},
};

/// Produce `.cwasm` bytes for the given CompiledWasm. The
/// arch tag is derived from the host architecture
/// (producer-only-on-matching-arch per ADR-0039 §Alternative
/// D); cross-arch production is a Phase 12+ concern.
///
/// Caller owns the returned slice; pair with `allocator.free`.
pub fn produceFromCompiledWasm(
    allocator: Allocator,
    compiled: *const runner.CompiledWasm,
    wasm_bytes: []const u8,
) Error![]u8 {
    // ADR-0203 stage 4 (D-515(1)) — elided codegen is now serializable:
    // the header carries `flag_bounds_elided`, the loader's re-link
    // re-registers the oob-stub trap entries against the loaded block, and
    // setup's `allocBacking` binds the guarded reservation with NO
    // plain-heap fallback for a qualifying memory (fails loudly instead),
    // so the ADR-0202 "elided ⇒ guarded binding" invariant holds end-to-end.
    // ADR-0203 stage 2 (D-519) — refuse to serialize dbg-instrumented
    // codegen: an active ZWASM_DEBUG channel (jit.callcount / global.trace)
    // bakes this process's diagnostic-counter ABSOLUTE addresses into the
    // emitted bytes, which would silently corrupt memory when the artifact
    // runs in another process (the D-516 class, via a developer flag).
    if (dbg.anyActive()) return Error.DbgInstrumentedNotAotSerializable;
    const arch = try hostArch();

    const n_funcs = compiled.func_results.len;

    var bytes_per_func = try allocator.alloc([]const u8, n_funcs);
    defer allocator.free(bytes_per_func);
    var n_slots_per_func = try allocator.alloc(u16, n_funcs);
    defer allocator.free(n_slots_per_func);
    var sig_idx_per_func = try allocator.alloc(u16, n_funcs);
    defer allocator.free(sig_idx_per_func);

    var n_relocs: usize = 0;
    for (compiled.func_results) |r| n_relocs += r.out.call_fixups.len;
    var relocs = try allocator.alloc(format.CwasmReloc, n_relocs);
    defer allocator.free(relocs);
    var func_idx_for_reloc = try allocator.alloc(u32, n_relocs);
    defer allocator.free(func_idx_for_reloc);

    var reloc_w: usize = 0;
    for (compiled.func_results, 0..) |r, defined_idx| {
        bytes_per_func[defined_idx] = r.out.bytes;
        n_slots_per_func[defined_idx] = r.out.n_slots;
        // sig_idx maps to types-section index; v0.1 emits one
        // FuncType per defined function in func-order, so
        // sig_idx == defined_idx.
        sig_idx_per_func[defined_idx] = @intCast(defined_idx);

        const wasm_idx: u32 = @as(u32, @intCast(defined_idx)) + compiled.num_imports;
        // CallFixup shape is identical across arm64 + x86_64
        // (both expose `byte_offset` + `target_func_idx`); we
        // access fields polymorphically rather than naming
        // the type, keeping aot/ arch-blind per A12.
        for (r.out.call_fixups) |cf| {
            relocs[reloc_w] = .{
                .code_offset = cf.byte_offset,
                .target_func_idx = cf.target_func_idx,
                .kind = format.reloc_kind_direct_call,
            };
            func_idx_for_reloc[reloc_w] = wasm_idx;
            reloc_w += 1;
        }
    }

    // Serialise the types section: one FuncType per defined
    // function (v0.1 doesn't dedupe — Phase 12+ may add type
    // hash-consing). Format per ADR-0039 §"Types section":
    //   per FuncType:
    //     u8 params_count
    //     u8 results_count
    //     params_count × u8 (ValType byte: @intFromEnum)
    //     results_count × u8
    var types_buf: std.ArrayList(u8) = .empty;
    defer types_buf.deinit(allocator);
    for (compiled.func_results, 0..) |_, defined_idx| {
        const wasm_idx = compiled.num_imports + @as(u32, @intCast(defined_idx));
        const ty = compiled.func_sigs[wasm_idx];
        if (ty.params.len > std.math.maxInt(u8)) return Error.ParamCountTooLarge;
        if (ty.results.len > std.math.maxInt(u8)) return Error.ResultCountTooLarge;
        try types_buf.append(allocator, @intCast(ty.params.len));
        try types_buf.append(allocator, @intCast(ty.results.len));
        for (ty.params) |p| try types_buf.append(allocator, @backingInt(p));
        for (ty.results) |rs| try types_buf.append(allocator, @backingInt(rs));
    }

    // Map the func-export table → the format's export shape (identical
    // fields). produceCwasm copies names into the output, so this temp
    // can be freed after; the source names are arena-owned by `compiled`.
    var exports = try allocator.alloc(format.CwasmExport, compiled.exports.len);
    defer allocator.free(exports);
    for (compiled.exports, 0..) |e, i| {
        exports[i] = .{ .name = e.name, .func_idx = e.func_idx };
    }

    // Pre-evaluate defined-global init values (v0.3) so the loader
    // reconstructs `globals_base` by memcpy, no init-expr eval at load.
    const globals = try collectGlobalInits(allocator, wasm_bytes);
    defer allocator.free(globals);

    // Linear memory (v0.3 cycle-1b): min/max pages + active data segments
    // (offsets pre-evaluated). `mem.data` bytes alias `wasm_bytes`.
    const mem = try collectMemory(allocator, wasm_bytes);
    defer allocator.free(mem.data);

    // Table 0 + element segments + per-func canonical typeidx (v0.3 cycle-2a).
    const tbl = try collectTables(allocator, wasm_bytes, compiled);
    defer {
        for (tbl.elem) |seg| allocator.free(seg.funcidxs);
        allocator.free(tbl.elem);
        allocator.free(tbl.canon_typeidx);
    }

    // Imports metadata (v0.4 §D-251): `(module, name, kind)` per declared
    // import in wasm-space order, so a standalone `.cwasm` rebuilds
    // `host_dispatch_base` (WASI). module/name alias `wasm_bytes` (the
    // produceCwasm copy duplicates them); the slice itself is freed here.
    const imports = try collectImports(allocator, wasm_bytes);
    defer allocator.free(imports);

    // v0.5 (ADR-0203 stage 2): per-func re-link extras + the module
    // exception table (?tag_idx null → `eh_tag_none` sentinel).
    const func_extras = try allocator.alloc(format.CwasmFuncExtra, n_funcs);
    defer allocator.free(func_extras);
    for (compiled.func_results, 0..) |r, i| {
        func_extras[i] = .{
            .frame_bytes = r.out.frame_bytes,
            .oob_stub_off = r.out.oob_stub_off,
        };
    }
    const eh_src = compiled.exception_table.entries;
    const eh_entries = try allocator.alloc(format.CwasmEhEntry, eh_src.len);
    defer allocator.free(eh_entries);
    for (eh_src, 0..) |e, i| {
        eh_entries[i] = .{
            .pc_start = e.pc_start,
            .pc_end = e.pc_end,
            .tag_idx = e.tag_idx orelse format.eh_tag_none,
            .landing_pad_pc = e.landing_pad_pc,
            .kind = @backingInt(e.kind),
        };
    }

    const input: serialise.Input = .{
        .arch = arch,
        .bytes_per_func = bytes_per_func,
        .n_slots_per_func = n_slots_per_func,
        .sig_idx_per_func = sig_idx_per_func,
        .relocs = relocs,
        .func_idx_for_reloc = func_idx_for_reloc,
        .types_serialised = types_buf.items,
        .n_imports = compiled.num_imports,
        .n_types = @intCast(n_funcs),
        .exports = exports,
        .globals = globals,
        .has_memory = mem.has_memory,
        .mem_min_pages = mem.min_pages,
        .mem_max_pages = mem.max_pages,
        .mem_data = mem.data,
        .has_table = tbl.has_table,
        .table0_size = tbl.table0_size,
        .elem = tbl.elem,
        .canon_typeidx_per_func = tbl.canon_typeidx,
        .imports = imports,
        .wasm_bytes = wasm_bytes,
        .func_extras = func_extras,
        .eh_entries = eh_entries,
        .bounds_elided = compiled.bounds_elided,
    };

    return serialise.produceCwasm(allocator, input);
}

/// Collect imports metadata (v0.4 §D-251): re-parse `wasm_bytes` for the
/// import section and map each entry to `format.CwasmImport`
/// `(module, name, @intFromEnum(kind))`. module/name are slices of the
/// section body, which aliases `wasm_bytes` (borrowed by the parser) — so
/// they outlive the local `module`/`imports` deinit and stay valid for the
/// `produceCwasm` copy. Returns an empty slice when the module declares no
/// imports. Caller frees the slice (not the borrowed strings).
fn collectImports(allocator: Allocator, wasm_bytes: []const u8) Error![]format.CwasmImport {
    var module = parser.parse(allocator, wasm_bytes) catch return Error.GlobalSectionParseFailed;
    defer module.deinit(allocator);

    const is = module.find(.import) orelse return allocator.alloc(format.CwasmImport, 0);
    var imports = sections.decodeImports(allocator, is.body) catch return Error.GlobalSectionParseFailed;
    defer imports.deinit();

    const out = try allocator.alloc(format.CwasmImport, imports.items.len);
    errdefer allocator.free(out);
    for (imports.items, 0..) |imp, i| {
        out[i] = .{ .module = imp.module, .name = imp.name, .kind = @backingInt(imp.kind) };
    }
    return out;
}

/// Evaluate each DEFINED global's init-expr into its 16-byte `Value` bits
/// (v0.3). Re-parses `wasm_bytes` for the global section (a one-time
/// generator cost; mirrors `setup.setupRuntime`'s eval). Returns an empty
/// slice for modules with no global section. Cycle-1 handles simple const
/// inits only — `ref.func` / `global.get` / `struct.new` globals (which need
/// func_entities / imported-global values / a GC heap) surface as
/// `UnsupportedGlobalInit` (cycle-2), never silently zero-filled.
fn collectGlobalInits(allocator: Allocator, wasm_bytes: []const u8) Error![]u128 {
    var module = parser.parse(allocator, wasm_bytes) catch return Error.GlobalSectionParseFailed;
    defer module.deinit(allocator);

    const gs = module.find(.global) orelse return allocator.alloc(u128, 0);
    var globals = sections.decodeGlobals(allocator, gs.body) catch return Error.GlobalSectionParseFailed;
    defer globals.deinit();

    const out = try allocator.alloc(u128, globals.items.len);
    errdefer allocator.free(out);
    for (globals.items, 0..) |gd, i| {
        const v = instantiate.evalConstExprValue(gd.init_expr) catch return Error.UnsupportedGlobalInit;
        out[i] = v.bits128;
    }
    return out;
}

/// Page-count cap mirroring `setup.zig`'s 256 MiB ceiling (256 MiB / 64 KiB).
const max_min_pages: u32 = 256 * 1024 * 1024 / 65536;

/// Collect linear-memory state (v0.3 cycle-1b): min/max pages + ACTIVE data
/// segments with offsets pre-evaluated (`runner_validate.evalConstOffsetU64`,
/// mirroring `setup.zig`). Passive segments are deferred (memory.init =
/// cycle-2). `data` bytes alias `wasm_bytes` (borrowed by the parser), so the
/// returned segs stay valid for the `produceCwasm` copy. Caller frees `.data`.
fn collectMemory(allocator: Allocator, wasm_bytes: []const u8) Error!MemoryState {
    var module = parser.parse(allocator, wasm_bytes) catch return Error.GlobalSectionParseFailed;
    defer module.deinit(allocator);

    var st: MemoryState = .{};
    if (module.find(.memory)) |s| {
        var memories = sections.decodeMemory(allocator, s.body) catch return Error.GlobalSectionParseFailed;
        defer memories.deinit();
        if (memories.items.len > 0) {
            const m0 = memories.items[0];
            if (m0.min > max_min_pages) return Error.UnsupportedMemoryState;
            st.has_memory = true;
            st.min_pages = @intCast(m0.min);
            st.max_pages = if (m0.max) |mx| (if (mx > std.math.maxInt(u32)) format.memory_max_none else @intCast(mx)) else format.memory_max_none;
        }
    }
    if (!st.has_memory) return st;

    if (module.find(.data)) |s| {
        var datas = sections.decodeData(allocator, s.body) catch return Error.GlobalSectionParseFailed;
        defer datas.deinit();
        var list: std.ArrayList(format.CwasmDataSeg) = .empty;
        errdefer list.deinit(allocator);
        for (datas.items) |seg| {
            if (seg.kind != .active) continue; // passive → memory.init (cycle-2)
            const off = runner_validate.evalConstOffsetU64(seg.offset_expr) catch return Error.UnsupportedMemoryState;
            if (off > std.math.maxInt(u32)) return Error.UnsupportedMemoryState;
            try list.append(allocator, .{ .mem_offset = @intCast(off), .bytes = seg.bytes });
        }
        st.data = try list.toOwnedSlice(allocator);
    }
    return st;
}

/// Collect table-0 + element-segment state (v0.3 cycle-2a). Re-parses
/// `wasm_bytes` for the table/type/element sections. `table0_size` = table-0
/// declared min; `canon_typeidx[i]` = `canonicalTypeidx(module_types,
/// func_typeidxs[num_imports+i])` per defined func (the value the runtime
/// puts in `typeidx_base` for that func; call_indirect's type check compares
/// it). Active elem segments only (offsets pre-evaluated). `funcidxs` are
/// duped (the decoder's are arena-backed). Caller frees `.elem[].funcidxs`,
/// `.elem`, `.canon_typeidx`. MVP: single table 0, non-subtyping (canonical).
fn collectTables(allocator: Allocator, wasm_bytes: []const u8, compiled: *const runner.CompiledWasm) Error!TableState {
    var module = parser.parse(allocator, wasm_bytes) catch return Error.GlobalSectionParseFailed;
    defer module.deinit(allocator);

    var st: TableState = .{};
    if (module.find(.table)) |s| {
        var tables = sections.decodeTables(allocator, s.body) catch return Error.GlobalSectionParseFailed;
        defer tables.deinit();
        if (tables.items.len > 0) {
            st.has_table = true;
            // table64 min is u64 but the .cwasm format's table0_size is
            // u32. D-475 removed the JIT table64 guard, so a table64
            // module reaches AOT now; a min that genuinely exceeds u32
            // can't serialize losslessly → reject loudly (matches the
            // over-u32 elem-offset posture below). Sub-2^32 table64
            // mins serialize exactly.
            st.table0_size = std.math.cast(u32, tables.items[0].min) orelse return Error.UnsupportedTableState;
        }
    }
    if (!st.has_table) return st;

    // Canonical typeidx per defined func (needs the module's full type table).
    if (module.find(.type)) |ts| {
        var types = sections.decodeTypes(allocator, ts.body) catch return Error.GlobalSectionParseFailed;
        defer types.deinit();
        const n_defined = compiled.func_results.len;
        const canon = try allocator.alloc(u32, n_defined);
        errdefer allocator.free(canon);
        for (0..n_defined) |i| {
            const wasm_idx = compiled.num_imports + @as(u32, @intCast(i));
            canon[i] = canonical_type.canonicalTypeidx(types.items, compiled.func_typeidxs[wasm_idx]);
        }
        st.canon_typeidx = canon;
    }
    errdefer allocator.free(st.canon_typeidx);

    if (module.find(.element)) |s| {
        var elems = sections.decodeElement(allocator, s.body) catch return Error.GlobalSectionParseFailed;
        defer elems.deinit();
        var list: std.ArrayList(format.CwasmElemSeg) = .empty;
        errdefer {
            for (list.items) |e| allocator.free(e.funcidxs);
            list.deinit(allocator);
        }
        for (elems.items) |seg| {
            if (seg.kind != .active) continue; // passive/declarative → table.init (cycle-2+)
            const off = runner_validate.evalConstOffsetU64(seg.offset_expr) catch return Error.UnsupportedTableState;
            if (off > std.math.maxInt(u32)) return Error.UnsupportedTableState;
            const fids = try allocator.dupe(u32, seg.funcidxs);
            errdefer allocator.free(fids);
            try list.append(allocator, .{ .table_offset = @intCast(off), .funcidxs = fids });
        }
        st.elem = try list.toOwnedSlice(allocator);
    }
    return st;
}

/// Map host arch → `.cwasm` arch tag. Producer-only-on-matching-
/// arch per ADR-0039.
pub fn hostArch() Error!u32 {
    return switch (builtin.target.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => Error.UnsupportedHostArch,
    };
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "hostArch maps to a valid .cwasm arch tag on supported hosts" {
    if (builtin.target.cpu.arch == .aarch64 or builtin.target.cpu.arch == .x86_64) {
        const a = try hostArch();
        try testing.expect(a == format.arch_arm64 or a == format.arch_x86_64);
    } else {
        try testing.expectError(Error.UnsupportedHostArch, hostArch());
    }
}

test "produceFromCompiledWasm: elided module serializes, deserializes, and guard-faults to a trap (ADR-0203 stage 4 / D-515(1))" {
    // A qualifying i32/64KiB memory + loads compiled with the DEFAULT .auto
    // knob elide the bounds check. Since stage 4 that SERIALIZES: the header
    // carries flag_bounds_elided, the deserializer's re-link re-registers
    // the oob-stub trap entries against the LOADED block, and setup binds
    // the guarded reservation — so an oob access in the deserialized
    // artifact faults into the guard page and surfaces as a clean trap
    // (Error.Trap), never a silent OOB. (guarded_mem.supported gate: on a
    // non-qualifying host nothing elides — skip there.)
    if (comptime !@import("../../../platform/guarded_mem.zig").supported) return;
    const load_compiled = @import("load_compiled.zig");
    // (module (memory 1)
    //   (func (export "ok")  (result i32) (i32.load (i32.const 0)))
    //   (func (export "oob") (result i32) (i32.load (i32.const 65533))))
    const mem_load_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x03, 0x02, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01, // memory min 1 (i32, 64 KiB)
        0x07, 0x0c, 0x02, 0x02, 0x6f,
        0x6b, 0x00, 0x00, 0x03, 0x6f,
        0x6f, 0x62, 0x00, 0x01, 0x0a,
        0x13, 0x02,
        0x07, 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0b, // ok: load @0
        0x09, 0x00, 0x41, 0xfd, 0xff, 0x03, 0x28, 0x02, 0x00, 0x0b, // oob: load @65533
    };
    runner.setBoundsChecks(.auto);
    defer runner.setBoundsChecks(.auto); // leave the default as other tests expect
    var compiled = try runner.compileWasm(testing.allocator, &mem_load_wasm);
    try testing.expect(compiled.bounds_elided); // .auto + qualifying → elided
    const cwasm = blk: {
        defer compiled.deinit(testing.allocator);
        break :blk try produceFromCompiledWasm(testing.allocator, &compiled, &mem_load_wasm);
    };
    defer testing.allocator.free(cwasm);

    const h = try format.parseHeader(cwasm[0..format.header_size]);
    try testing.expect((h.flags & format.flag_bounds_elided) != 0);

    const des = try load_compiled.deserializeToCompiledWasm(testing.allocator, cwasm);
    try testing.expect(des.compiled.bounds_elided);
    var inst = try runner.JitInstance.fromCompiled(testing.allocator, des.compiled, des.wasm_bytes);
    defer inst.deinit(testing.allocator);
    // In-bounds load works through the guarded binding.
    try testing.expectEqual(@as(?u64, 0), try inst.invoke(testing.allocator, "ok", &.{}));
    // The page-straddling load has NO inline check in elided code — it must
    // guard-fault and redirect through the RE-REGISTERED trap entries.
    try testing.expectError(runner.Error.Trap, inst.invoke(testing.allocator, "oob", &.{}));
}

test "produceFromCompiledWasm: tiny synthetic wasm round-trips through compileWasm + AOT producer" {
    // Synthetic wasm: () -> i32 returning 7.
    // Module sections: type, function, code.
    const wasm_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, // \0asm
        0x01, 0x00, 0x00, 0x00, // version 1
        // Type section: 1 entry, () -> i32
        0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f,
        // Function section: 1 func, type 0
        0x03,
        0x02, 0x01, 0x00,
        // Code section: 1 body, locals=0, i32.const 7, end
        0x0a,
        0x06, 0x01, 0x04, 0x00,
        0x41, 0x07, 0x0b,
    };

    var compiled = try runner.compileWasmForAot(testing.allocator, &wasm_bytes);
    defer compiled.deinit(testing.allocator);

    const out = try produceFromCompiledWasm(testing.allocator, &compiled, &wasm_bytes);
    defer testing.allocator.free(out);

    const h = try format.parseHeader(out[0..format.header_size]);
    try testing.expectEqual(@as(u32, 1), h.n_funcs);
    try testing.expectEqual(@as(u32, 1), h.n_types);
    try testing.expectEqual(@as(u32, 0), h.n_imports);
    const expected_arch = try hostArch();
    try testing.expectEqual(expected_arch, h.arch);

    // Per-func metadata.
    const meta = try format.parseFuncMeta(out[h.metadata_offset..][0..format.func_meta_size]);
    try testing.expectEqual(@as(u32, 0), meta.code_offset);
    try testing.expect(meta.code_size > 0);
    try testing.expectEqual(@as(u16, 0), meta.sig_idx);

    // Types section: 1 FuncType encoded as `params_count=0,
    // results_count=1, results=[i32 byte]`.
    const types_slice = out[h.types_offset..][0..h.types_size];
    try testing.expectEqual(@as(usize, 3), types_slice.len);
    try testing.expectEqual(@as(u8, 0), types_slice[0]); // 0 params
    try testing.expectEqual(@as(u8, 1), types_slice[1]); // 1 result
    try testing.expectEqual(@as(u8, @backingInt(zir.ValType.i32)), types_slice[2]);

    // Code bytes: ARM64 emits a non-empty function body for
    // `(func (result i32) (i32.const 7))`. Just assert
    // non-zero length matching meta.code_size.
    const code_slice = out[h.code_offset..][0..meta.code_size];
    try testing.expect(code_slice.len > 0);
}

test "produceFromCompiledWasm: a WASI import round-trips through the full-fidelity deserializer (D-251 / ADR-0203 stage 3)" {
    const load_compiled = @import("load_compiled.zig");
    // (module (import "wasi_snapshot_preview1" "proc_exit" (func (param i32)))
    //         (func (export "main") i32.const 42 call 0))
    const wasm_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x02, 0x60, 0x01, 0x7F, 0x00, 0x60,
        0x00, 0x00, 0x02, 0x24, 0x01, 0x16, 0x77, 0x61,
        0x73, 0x69, 0x5F, 0x73, 0x6E, 0x61, 0x70, 0x73,
        0x68, 0x6F, 0x74, 0x5F, 0x70, 0x72, 0x65, 0x76,
        0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6F,
        0x63, 0x5F, 0x65, 0x78, 0x69, 0x74, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x01, 0x07, 0x08, 0x01, 0x04,
        0x6D, 0x61, 0x69, 0x6E, 0x00, 0x01, 0x0A, 0x08,
        0x01, 0x06, 0x00, 0x41, 0x2A, 0x10, 0x00, 0x0B,
    };

    var compiled = try runner.compileWasmForAot(testing.allocator, &wasm_bytes);
    defer compiled.deinit(testing.allocator);
    const out = try produceFromCompiledWasm(testing.allocator, &compiled, &wasm_bytes);
    defer testing.allocator.free(out);

    const h = try format.parseHeader(out[0..format.header_size]);
    try testing.expectEqual(@as(u32, 1), h.n_imports); // one imported func

    // The deserializer re-derives the import space from the embedded
    // original bytes; num_imports must agree with both the fresh compile
    // and the artifact header.
    var des = try load_compiled.deserializeToCompiledWasm(testing.allocator, out);
    defer des.compiled.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), des.compiled.num_imports);
    try testing.expectEqual(compiled.num_imports, des.compiled.num_imports);
    try testing.expectEqualSlices(u8, &wasm_bytes, des.wasm_bytes);
}
