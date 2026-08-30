// FILE-SIZE-EXEMPT: already the ADR-0079 Step-2 carve-out from runner.zig; per-section init helpers share compile state (N2) (investigated 2026-08-12, per ADR-0099)
// AUTO-EXTRACTED from src/engine/runner.zig at ADR-0079 Step 2
// (close-plan §6 (g)). Carve-out: `compileWasm` + per-section
// helpers (`applyDefinedGlobalsInit`, `resolveFuncrefGlobals`,
// `applyTableInit*`, `patchTableImportFuncptrs*`,
// `countDeclaredTables`, `declaredTableMin`, `declaredTableMax`,
// `applyActiveDataSegments*`). Re-export from runner.zig keeps
// the public surface stable.
//
// Zone 2 (`src/engine/`); same import boundaries as runner.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

const parser = @import("../parse/parser.zig");
const sections = @import("../parse/sections.zig");
const zir = @import("../ir/zir.zig");
const validator_mod = @import("../validate/validator.zig");
const leb128 = @import("../support/leb128.zig");
const dbg = @import("../support/dbg.zig");
const FuncType = zir.FuncType;
const compile_func = @import("codegen/shared/compile.zig");
const linker = @import("codegen/shared/linker.zig");
const exception_table = @import("codegen/shared/exception_table.zig");
const rv = @import("runner_validate.zig");

const runner_mod = @import("runner.zig");
const Error = runner_mod.Error;
const CompiledWasm = runner_mod.CompiledWasm;
const runtime_mod = @import("../runtime/runtime.zig");
const needs_heap_detector = @import("../feature/gc/needs_heap_detector.zig");
const memory_backing = @import("../runtime/instance/memory_backing.zig");

/// ADR-0202 D5 — bounds-check mode knob. `.auto` (default) elides the
/// memory0 scalar bounds check when memory0 qualifies for a guard-page
/// reservation; `.explicit` forces the inline check everywhere (the
/// D-510 differential-fuzz axis + a debugging escape hatch). Process-
/// global so a fuzz harness can flip it between compiles without
/// threading it through `compileWasm`'s 56 call sites.
pub const BoundsChecks = enum { auto, explicit };
var bounds_checks_mode: BoundsChecks = .auto;
pub fn setBoundsChecks(m: BoundsChecks) void {
    bounds_checks_mode = m;
}
pub fn boundsChecksMode() BoundsChecks {
    return bounds_checks_mode;
}

/// Compile for AOT serialization. Since ADR-0203 stage 4 this honours the
/// ambient bounds mode — elided codegen serializes (the header carries
/// `flag_bounds_elided`; the loader re-registers trap entries and setup
/// binds the guarded reservation, ADR-0202 D5 clauses D-515(1)), so the
/// historical forced-`.explicit` is gone. Kept as a named entry point so
/// AOT-destined call sites stay greppable.
pub fn compileWasmForAot(allocator: Allocator, wasm_bytes: []const u8) Error!CompiledWasm {
    return compileWasm(allocator, wasm_bytes);
}

pub fn compileWasm(allocator: Allocator, wasm_bytes: []const u8) Error!CompiledWasm {
    var module = try parser.parse(allocator, wasm_bytes);
    defer module.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Decode the import section (chunk 7.9-b). Imports are accepted
    // in MVP shape; only function imports contribute to the wasm
    // function index space. Memory / table / global imports are
    // recorded as kind-only — table-size / globals_base / mem
    // wiring lands at chunk 7.9-c when host-call dispatch arrives.
    var imports_buf: ?sections.Imports = null;
    defer if (imports_buf) |*ib| ib.deinit();
    if (module.find(.import)) |s| imports_buf = try sections.decodeImports(allocator, s.body);

    // D-219 — memidx-0 idx_type. Active-DATA segment offset exprs are i64
    // for memory64, i32 otherwise; the JIT compile gate must validate them
    // against the right type (else it rejects memory64 modules with active
    // data at InvalidGlobalInitExpr). Imported memory takes precedence
    // (memidx 0), else the first defined memory. (Elem offsets stay i32 —
    // tables are i32-indexed.)
    const mem0_is_i64 = blk: {
        if (imports_buf) |ib| {
            for (ib.items) |imp| if (imp.kind == .memory) break :blk imp.payload.memory.idx_type == .i64;
        }
        if (module.find(.memory)) |ms| {
            var mb = sections.decodeMemory(a, ms.body) catch break :blk false;
            defer mb.deinit();
            if (mb.items.len > 0) break :blk mb.items[0].idx_type == .i64;
        }
        break :blk false;
    };
    const data_off_vt: zir.ValType = if (mem0_is_i64) .i64 else .i32;

    // §9.9 / 9.9-l-1b-d093-d84 (skip-impl drainage):
    // Wasm spec §5.5.3 type section canonical encoding. Eager
    // decode catches malformed LEB128 (over-long / overflow) in
    // count / param_count / result_count, non-0x60 functype
    // tags, malformed valtype bytes, and trailing bytes. Without
    // this proactive decode, modules with type section but no
    // imports / function section silently passed (the type
    // section's content was never read). Drains
    // binary-leb128.{31,32,56,57,90} + binary.74.
    if (module.find(.type)) |ts| {
        var t = try sections.decodeTypes(a, ts.body);
        t.deinit();
    }

    // §9.9 / 9.9-l-1b-d093-d75 (skip-impl drainage):
    // Wasm spec §3.4.4 memory section validation. Three rules:
    //   (a) Total memories (import + defined) ≤ 1 in Wasm 2.0
    //       (multi-memory is a Wasm 3.0 proposal; rejected).
    //   (b) For each memory's limits: min ≤ 65536 (4 GiB cap),
    //       max ≤ 65536 if specified, AND max ≥ min if both
    //       specified.
    //   (c) Data segments require a memory to exist (active
    //       segments with memidx≥mem_count, or any data segment
    //       in a module with zero memories, are invalid).
    // Drains the `memory` + portions of `data` SKIP-VALIDATOR-GAP
    // families — previously compileWasm accepted these shapes
    // and the runner surfaced SKIP-VALIDATOR-GAP at the
    // `.assert_invalid` arm.
    {
        // Per-idx_type max page counts (Wasm 3.0 §A.1 implementation
        // limits). i32: 4 GiB / 64 KiB page = 65536 pages. i64:
        // spec-defined ceiling is 2^48 bytes = 2^32 pages; runtime
        // cascade (10.M-2) may further restrict per host.
        const max_mem_pages_i32: u64 = 65536;
        const max_mem_pages_i64: u64 = @as(u64, 1) << 32;
        var num_memory_imports: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| if (imp.kind == .memory) {
                num_memory_imports += 1;
            };
        }
        var defined_memories: u32 = 0;
        if (module.find(.memory)) |ms| {
            var ms_buf = try sections.decodeMemory(a, ms.body);
            defer ms_buf.deinit();
            defined_memories = @intCast(ms_buf.items.len);
            for (ms_buf.items) |mem_entry| {
                const cap: u64 = switch (mem_entry.idx_type) {
                    .i32 => max_mem_pages_i32,
                    .i64 => max_mem_pages_i64,
                };
                if (mem_entry.min > cap) return Error.InvalidMemoryLimit;
                if (mem_entry.max) |max| {
                    if (max > cap) return Error.InvalidMemoryLimit;
                    if (max < mem_entry.min) return Error.InvalidMemoryLimit;
                }
            }
        }
        if (num_memory_imports + defined_memories > 1) return Error.MultipleMemories;
        // Data section requires a memory to exist (Wasm 2.0
        // §3.4.7 — `C.mems[memidx]` must be defined). With our
        // memidx fixed at 0 (single-memory MVP), the requirement
        // collapses to "≥ 1 memory exists".
        if (module.find(.data)) |ds| {
            var ds_buf = try sections.decodeData(a, ds.body);
            defer ds_buf.deinit();
            for (ds_buf.items) |seg| {
                if (seg.kind != .passive) {
                    // Active or active-with-memidx (kind 0 / 2):
                    // segment requires a memory.
                    if (num_memory_imports + defined_memories == 0) {
                        return Error.DataSegmentRequiresMemory;
                    }
                    if (seg.memidx >= num_memory_imports + defined_memories) {
                        return Error.DataSegmentRequiresMemory;
                    }
                }
            }
        }
    }

    // §9.9 / 9.9-l-1b-d093-d76 (skip-impl drainage):
    // Wasm spec §3.4.5 table + §3.4.6 element validation.
    //   (a) §3.4.5 Table limits: `min ≤ max` if max specified.
    //       (Unlike memory, table doesn't have a hard cap on
    //       count in spec text — Wasm 2.0 §A.3 limits to one
    //       table at-instance-time only; we keep that as a
    //       Phase-10+ refinement.)
    //   (b) §3.4.6 Element segment table reference: an active
    //       elem segment's tableidx must reference an existing
    //       table (import + defined).
    // Also §3.4.9 import typeidx validation: each function
    // import's `typeidx` must reference a defined type.
    // Drains `table` (size mins/max + unknown table) and
    // portions of `elem` (unknown table) SKIP-VALIDATOR-GAP.
    {
        // Build a combined table reftype map (imports + defined)
        // so the elem-segment validation can check reftype
        // compatibility (§3.4.6 — active elem.elem_type must
        // match its target table's elem_type).
        var num_table_imports: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| if (imp.kind == .table) {
                num_table_imports += 1;
            };
        }
        var defined_tables: u32 = 0;
        var defined_tables_reftypes: []const zir.ValType = &.{};
        if (module.find(.table)) |ts| {
            var ts_buf = try sections.decodeTables(a, ts.body);
            defer ts_buf.deinit();
            defined_tables = @intCast(ts_buf.items.len);
            for (ts_buf.items) |tbl_entry| {
                if (tbl_entry.max) |max| {
                    if (max < tbl_entry.min) return Error.InvalidTableLimit;
                }
            }
            // Copy reftypes into arena-allocated slice that
            // outlives the local `ts_buf`.
            const reftypes_mut = try a.alloc(zir.ValType, ts_buf.items.len);
            for (ts_buf.items, 0..) |t, i| reftypes_mut[i] = t.elem_type;
            defined_tables_reftypes = reftypes_mut;
        }
        const total_tables = num_table_imports + defined_tables;
        // Compute total funcs (imports + defined) so elem
        // segments can be range-checked. Used by the
        // §9.9 / 9.9-l-1b-d093-d83 funcidx-range check below.
        var num_func_imports_early: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| if (imp.kind == .func) {
                num_func_imports_early += 1;
            };
        }
        var defined_funcs_count_early: u32 = 0;
        if (module.find(.function)) |fs| {
            const fs_buf = try sections.decodeFunctions(a, fs.body);
            defined_funcs_count_early = @intCast(fs_buf.len);
        }
        const total_funcs_early = num_func_imports_early + defined_funcs_count_early;
        // Active elem segments require a referenced table AND
        // their elem_type must match the table's elem_type
        // (§9.9 / 9.9-l-1b-d093-d80 elem reftype check).
        // §9.9 / 9.9-l-1b-d093-d83: all elem segments (active /
        // passive / declarative) must have every non-null
        // funcidx in [0, total_funcs). `funcidxs[i] ==
        // maxInt(u32)` encodes `ref.null` (init-expr form);
        // skip those.
        if (module.find(.element)) |es| {
            var es_buf = try sections.decodeElement(a, es.body);
            defer es_buf.deinit();
            for (es_buf.items) |seg| {
                // Wasm 3.0 GC (D-218): an i31ref/eqref/anyref elem segment's
                // `funcidxs` carry i31-ENCODED values ((n<<1)|1), NOT funcidxs
                // (decoder: i32ToI31Truncate; see setup.zig elem-init D-221).
                // Skip the funcidx range check for them — else the encoded
                // value (e.g. (123<<1)|1) trips `>= total_funcs`. Mirrors the
                // setup discriminator (abstract i31/eq/any only).
                const seg_is_i31 = seg.elem_type == .ref and switch (seg.elem_type.ref.heap_type) {
                    .abstract => |aa| aa == .i31 or aa == .eq or aa == .any,
                    .concrete => false,
                };
                if (!seg_is_i31) for (seg.funcidxs) |fidx| {
                    if (fidx == std.math.maxInt(u32)) continue;
                    // Close-plan §6 (j) Step B cohort 6 — `global.get N`
                    // marker (top-bit set): skip the funcidx range
                    // check, the entry is resolved at table-init time.
                    if (sections.elemEntryIsGlobalGet(fidx)) continue;
                    if (fidx >= total_funcs_early) return Error.InvalidFuncIndex;
                };
                if (seg.kind == .active) {
                    if (seg.tableidx >= total_tables) {
                        return Error.ElemSegmentRequiresTable;
                    }
                    // Look up the referenced table's reftype.
                    const tbl_reftype: zir.ValType = blk: {
                        if (seg.tableidx < num_table_imports) {
                            // Walk imports to find the N-th table import.
                            var seen: u32 = 0;
                            const ib = imports_buf orelse return Error.ElemSegmentRequiresTable;
                            for (ib.items) |imp| {
                                if (imp.kind != .table) continue;
                                if (seen == seg.tableidx) break :blk imp.payload.table.elem_type;
                                seen += 1;
                            }
                            return Error.ElemSegmentRequiresTable;
                        } else {
                            const di = seg.tableidx - num_table_imports;
                            break :blk defined_tables_reftypes[di];
                        }
                    };
                    // Wasm 3.0 §3.3.3 (elem segment): the segment's element type
                    // must be a SUBTYPE of the table's element type — e.g.
                    // `(ref $t)` into `(ref null $t)` (ref_is_null.0) or `(ref
                    // i31)` into an i31ref/anyref table (gc/i31.6). The typed-ref
                    // table runtime already supports these (D-218 i31-encoded
                    // elems + null-safe funcptr-derive in table.init/get/set), so
                    // the flip from exact-`eql` to subtype no longer SEGVs (the
                    // D-240 warning predated that runtime). Context-free
                    // `valTypeIsSubtype` suffices: the corpus only exercises
                    // nullable-loosening (same concrete index) + the abstract GC
                    // lattice, neither of which needs the module supertype chain.
                    // TODO(p11): concrete→concrete elem subtyping via a declared
                    // supertype chain would need the context-aware `subtypeCtx`.
                    if (!validator_mod.Validator.valTypeIsSubtype(seg.elem_type, tbl_reftype)) {
                        return Error.ElemSegmentTypeMismatch;
                    }
                }
            }
        }
        // §3.4.9 / §3.2.9 import typeidx range: `(import "x" "y"
        // (func (type N)))` requires `N < types.len`. The main
        // path already enforces this at line ~250 via the
        // tidx-vs-types-len check, but only when sig_count > 0
        // hits that branch. Mirror the check here so it fires
        // unconditionally regardless of the empty-fn vs main
        // path.
        if (imports_buf) |ib| {
            // Skip when no type section AND no function imports
            // (nothing to validate).
            const has_func_imports = blk: {
                for (ib.items) |imp| if (imp.kind == .func) break :blk true;
                break :blk false;
            };
            if (has_func_imports) {
                const type_section = module.find(.type) orelse return Error.MissingTypeSection;
                var types_buf = try sections.decodeTypes(a, type_section.body);
                defer types_buf.deinit();
                for (ib.items) |imp| {
                    if (imp.kind != .func) continue;
                    if (imp.payload.func_typeidx >= types_buf.items.len) {
                        return Error.ImportTypeIdxOutOfRange;
                    }
                }
            }
        }
    }

    // Per Wasm spec: type / function / code sections are all
    // OPTIONAL — a module with no defined functions is valid
    // (just header + optional non-function sections). Bail out
    // early with an empty CompiledWasm in that case rather than
    // demanding a type section. (A module may have imports but no
    // defined functions; that case also returns an empty
    // JitModule — call-by-export to an import-only function is
    // unreachable from JIT-compiled code today.)
    // D-127 (d-52): Wasm spec allows an EMPTY Function section
    // (count=0) without a corresponding Type section
    // (binary.60.wasm). Treat empty function section like absent
    // function section — both bypass the type-section requirement
    // since neither contributes defined funcs.
    const func_section_opt = blk: {
        const opt = module.find(.function);
        if (opt) |s| {
            // Empty function section body = single LEB128 0x00 byte.
            if (s.body.len == 1 and s.body[0] == 0x00) break :blk null;
        }
        break :blk opt;
    };
    // §9.9 / 9.9-l-1b-d093-d84 (skip-impl drainage):
    // Wasm spec §5.5.6: function and code sections must be
    // present together and have equal entry counts. The
    // function-section + code-section count match is enforced
    // in the main path below; this mirror catches "code
    // section without function section" (binary.57.wasm).
    if (func_section_opt == null) {
        if (module.find(.code)) |cs| {
            // Decode the code section and reject when non-empty.
            var c_buf = try sections.decodeCodes(a, cs.body);
            defer c_buf.deinit();
            if (c_buf.items.len != 0) return Error.MissingFunctionSection;
        }
    }
    // §9.9 / 9.9-l-1b-d093-d84 (skip-impl drainage):
    // Wasm spec §5.5.13 data count section: when present, its
    // value must equal the number of data segments in the data
    // section. Absence of data section with non-zero
    // data_count, or count mismatch, is malformed.
    // Drains binary.{62,63,64}.
    if (module.find(.data_count)) |dcs| {
        var pos: usize = 0;
        const dc_value = try leb128.readUleb128(u32, dcs.body, &pos);
        if (pos != dcs.body.len) return Error.TrailingBytes;
        const data_seg_count: u32 = if (module.find(.data)) |ds| blk: {
            var ds_buf = try sections.decodeData(a, ds.body);
            defer ds_buf.deinit();
            break :blk @intCast(ds_buf.items.len);
        } else 0;
        if (dc_value != data_seg_count) return Error.DataCountMismatch;
    }
    if (func_section_opt == null) {
        // §9.9 / 9.9-l-1b-d093-d69 (D-135 discharge): each
        // allocation below was previously uncovered by errdefer.
        // The downstream `Error.MissingTypeSection` paths (at the
        // `module.find(.type) orelse return` site below and at
        // the `tidx >= types.items.len` check) leaked the
        // already-made allocations under the runCorpus
        // `.assert_invalid` arm on OrbStack Linux x86_64 (4 leak
        // sites per process exit per d-65 valgrind / d-69 stack
        // traces). The fix is structural: pair each `alloc` with
        // an `errdefer free` so an error return after the alloc
        // unwinds cleanly. The success-path `return` does not
        // fire errdefers, so the returned `CompiledWasm` still
        // owns the allocations and the caller's `c.deinit(gpa)`
        // path remains correct.
        const empty_results = try allocator.alloc(compile_func.FuncResult, 0);
        errdefer allocator.free(empty_results);
        // Build func_sigs from import-only function entries (if any)
        // so `findExportFunc` → wasm-space idx → func_sigs[idx]
        // resolution remains valid for export-import re-exports.
        var sig_count: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| {
                if (imp.kind == .func) sig_count += 1;
            }
        }
        var empty_module = try linker.link(allocator, &.{}, sig_count);
        errdefer empty_module.deinit(allocator);
        const sigs = try allocator.alloc(FuncType, sig_count);
        errdefer allocator.free(sigs);
        const typeidxs = try allocator.alloc(u32, sig_count);
        errdefer allocator.free(typeidxs);
        const elay = try @import("export_lookup.zig").computeGlobalsLayout(allocator, wasm_bytes); // D-152 §9.12-E
        errdefer allocator.free(elay.offsets);
        errdefer allocator.free(elay.valtypes);
        if (imports_buf) |ib| {
            // Need a type section to resolve func imports' typeidx.
            if (sig_count > 0) {
                const type_section = module.find(.type) orelse return Error.MissingTypeSection;
                var types = try sections.decodeTypes(a, type_section.body);
                defer types.deinit();
                var w: u32 = 0;
                for (ib.items) |imp| {
                    if (imp.kind != .func) continue;
                    const tidx = imp.payload.func_typeidx;
                    if (tidx >= types.items.len) return Error.MissingTypeSection;
                    sigs[w] = types.items[tidx];
                    typeidxs[w] = tidx;
                    w += 1;
                }
            }
        }
        // §9.9 / 9.9-l-1b-d093-d74 export validation (empty-fn path
        // mirror of the main-path check below). Wasm spec §3.4.10:
        // each export's idx must reference a defined entity AND
        // names must be pairwise distinct. Many `assert_invalid`
        // modules in `exports.wast` lack a function section (e.g.
        // `(module (export "a" (func 0)))` with zero funcs) so
        // they take this empty-fn early-return path; without this
        // check they'd compileWasm-accept and surface as
        // SKIP-VALIDATOR-GAP.

        // §9.9 / 9.9-l-1b-d093-d77 mirror — empty-fn path
        // global init-expr validation. Most `global.wast`
        // assert_invalid modules consist of a global section
        // only (no function/code), so they take this branch.
        // Without this check the global init-expr validator
        // would never fire on them.
        var num_global_imports_empty: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| if (imp.kind == .global) {
                num_global_imports_empty += 1;
            };
        }
        // §9.9 / 9.9-l-1b-d093-d82 — total_funcs for empty-fn
        // path = number of function imports only (no defined
        // functions). Used by validateGlobalInitExpr's ref.func
        // arm for range-checking funcidxs in global / offset
        // const-exprs.
        const total_funcs_empty_for_init: u32 = sig_count;
        if (module.find(.global)) |gs| {
            var gs_buf = try sections.decodeGlobals(a, gs.body);
            defer gs_buf.deinit();
            for (gs_buf.items) |gd| {
                try rv.validateGlobalInitExpr(gd.init_expr, gd.valtype, num_global_imports_empty, imports_buf, total_funcs_empty_for_init);
            }
        }
        // §9.9 / 9.9-l-1b-d093-d78 mirror — empty-fn path
        // elem + data active-offset_expr validation.
        if (module.find(.data)) |ds| {
            var ds_buf = try sections.decodeData(a, ds.body);
            defer ds_buf.deinit();
            for (ds_buf.items) |seg| {
                if (seg.kind == .active) {
                    try rv.validateGlobalInitExpr(seg.offset_expr, data_off_vt, num_global_imports_empty, imports_buf, total_funcs_empty_for_init);
                }
            }
        }
        if (module.find(.element)) |es| {
            var es_buf = try sections.decodeElement(a, es.body);
            defer es_buf.deinit();
            // D-475: a table64 elem offset is i64-typed (§3.3.6) — decode
            // the table section for the per-table expected offset type.
            var empty_tables_buf: ?sections.Tables = null;
            defer if (empty_tables_buf) |*t| t.deinit();
            if (module.find(.table)) |ts| empty_tables_buf = try sections.decodeTables(a, ts.body);
            for (es_buf.items) |seg| {
                if (seg.kind == .active) {
                    const off_vt = elemOffsetValType(imports_buf, empty_tables_buf, seg.tableidx);
                    try rv.validateGlobalInitExpr(seg.offset_expr, off_vt, num_global_imports_empty, imports_buf, total_funcs_empty_for_init);
                }
            }
        }

        if (module.find(.@"export")) |es| {
            var exports = try sections.decodeExports(a, es.body);
            defer exports.deinit();
            var num_table_imports: u32 = 0;
            var num_memory_imports: u32 = 0;
            var num_global_imports: u32 = 0;
            if (imports_buf) |ib| {
                for (ib.items) |imp| switch (imp.kind) {
                    .func => {},
                    .table => num_table_imports += 1,
                    .memory => num_memory_imports += 1,
                    .global => num_global_imports += 1,
                    .tag => {}, // EH tag imports don't shift table/mem/global import bases (10.E)
                };
            }
            const defined_tables: u32 = if (module.find(.table)) |ts| blk: {
                var ts_buf = try sections.decodeTables(a, ts.body);
                defer ts_buf.deinit();
                break :blk @intCast(ts_buf.items.len);
            } else 0;
            const defined_memories: u32 = if (module.find(.memory)) |ms| blk: {
                var ms_buf = try sections.decodeMemory(a, ms.body);
                defer ms_buf.deinit();
                break :blk @intCast(ms_buf.items.len);
            } else 0;
            const defined_globals_section: u32 = if (module.find(.global)) |gs| blk: {
                var gs_buf = try sections.decodeGlobals(a, gs.body);
                defer gs_buf.deinit();
                break :blk @intCast(gs_buf.items.len);
            } else 0;
            const total_tables_empty: u32 = num_table_imports + defined_tables;
            const total_memories_empty: u32 = num_memory_imports + defined_memories;
            const total_globals_empty: u32 = num_global_imports + defined_globals_section;
            const total_funcs_empty: u32 = sig_count;
            var seen_names: std.StringHashMap(void) = .init(a);
            defer seen_names.deinit();
            try seen_names.ensureTotalCapacity(@intCast(exports.items.len));
            for (exports.items) |e| {
                const gop = try seen_names.getOrPut(e.name);
                if (gop.found_existing) return Error.DuplicateExport;
                const ok = switch (e.kind) {
                    .func => e.idx < total_funcs_empty,
                    .table => e.idx < total_tables_empty,
                    .memory => e.idx < total_memories_empty,
                    .global => e.idx < total_globals_empty,
                };
                if (!ok) return Error.ExportIdxOutOfRange;
            }
        }
        // Wasm 3.0 EH (10.E-N-3) — build tag_param_counts even
        // for the empty-function module path. A valid Wasm
        // module may declare just types + tags (no functions);
        // the interp Runtime still wants the slot populated so
        // a host-side throw could marshal payload via the
        // standard pop path.
        const TagInfo = struct { counts: []u32, slot_counts: []u32 };
        const empty_tag_info: TagInfo = blk: {
            // Tag index space = imported tags ++ defined tags (§3.4); a
            // defined-only table mis-indexes a host throw against an
            // imported tag. Same full-space invariant as the main path.
            var imp_tags: usize = 0;
            if (imports_buf) |ib| for (ib.items) |imp| {
                if (imp.kind == .tag) imp_tags += 1;
            };
            const defined_only: []const sections.TagEntry = if (module.find(.tag)) |tag_section|
                try sections.decodeTags(a, tag_section.body)
            else
                &.{};
            const total = imp_tags + defined_only.len;
            if (total == 0) break :blk .{ .counts = &.{}, .slot_counts = &.{} };
            const type_section_for_tags = module.find(.type) orelse return Error.MissingTypeSection;
            var types_for_tags = try sections.decodeTypes(a, type_section_for_tags.body);
            defer types_for_tags.deinit();
            const out_counts = try allocator.alloc(u32, total);
            errdefer allocator.free(out_counts);
            const out_slots = try allocator.alloc(u32, total);
            errdefer allocator.free(out_slots);
            var ti: usize = 0;
            if (imports_buf) |ib| for (ib.items) |imp| {
                if (imp.kind != .tag) continue;
                if (imp.payload.tag_typeidx >= types_for_tags.items.len) return Error.InvalidFuncIndex;
                const params = types_for_tags.items[imp.payload.tag_typeidx].params;
                out_counts[ti] = @intCast(params.len);
                var slots: u32 = 0;
                for (params) |p| slots += runtime_mod.slotCountForValType(p);
                out_slots[ti] = slots;
                ti += 1;
            };
            for (defined_only) |tag| {
                if (tag.typeidx >= types_for_tags.items.len) return Error.InvalidFuncIndex;
                const params = types_for_tags.items[tag.typeidx].params;
                out_counts[ti] = @intCast(params.len);
                var slots: u32 = 0;
                for (params) |p| slots += runtime_mod.slotCountForValType(p);
                out_slots[ti] = slots;
                ti += 1;
            }
            break :blk .{ .counts = out_counts, .slot_counts = out_slots };
        };
        errdefer if (empty_tag_info.counts.len > 0) allocator.free(empty_tag_info.counts);
        errdefer if (empty_tag_info.slot_counts.len > 0) allocator.free(empty_tag_info.slot_counts);

        return .{
            .module = empty_module,
            .func_results = empty_results,
            .func_sigs = sigs,
            .func_typeidxs = typeidxs,
            .num_imports = sig_count,
            .globals_offsets = elay.offsets,
            .globals_valtypes = elay.valtypes,
            .num_global_imports = num_global_imports_empty,
            .tag_param_counts = empty_tag_info.counts,
            .tag_param_slot_counts = empty_tag_info.slot_counts,
            // No defined functions → no JIT exception entries (IT-5).
            .exception_table = .{ .entries = &.{} },
            // No defined functions → nothing AOT-runnable to name (any
            // export here targets an import, which can't be an entry).
            .exports = &.{},
            .arena = arena,
        };
    }

    const type_section = module.find(.type) orelse return Error.MissingTypeSection;
    var types = try sections.decodeTypes(a, type_section.body);
    defer types.deinit();

    const defined_func_typeidx = try sections.decodeFunctions(a, func_section_opt.?.body);

    const code_section = module.find(.code) orelse return Error.MissingCodeSection;
    var codes = try sections.decodeCodes(a, code_section.body);
    defer codes.deinit();

    if (codes.items.len != defined_func_typeidx.len) return Error.MissingCodeSection;

    // §9.9 / 9.9-l-1b-d093-d84 (skip-impl drainage): track
    // whether the optional data_count section is present. Wasm
    // spec §5.5.10 requires the section whenever any function
    // body uses `memory.init` (0xFC 0x08) or `data.drop` (0xFC
    // 0x09). The validator enforces this via its
    // `data_count_section_present` field during opcode walk
    // (drains binary.{66,67}).
    const data_count_section_present: bool = module.find(.data_count) != null;

    // Count function + global imports (B150 / D-153 — global-prefix).
    var num_imports: u32 = 0;
    var nm_global_imports: u32 = 0;
    if (imports_buf) |ib| for (ib.items) |imp| {
        if (imp.kind == .func) num_imports += 1 else if (imp.kind == .global) nm_global_imports += 1;
    };

    // Build the unified wasm-space func_sigs vector:
    // `[import_func_sigs..., defined_func_sigs...]`. Indexed by
    // wasm function index throughout (validator, lower, emit).
    const total_funcs = num_imports + @as(u32, @intCast(defined_func_typeidx.len));
    const func_sigs = try allocator.alloc(FuncType, total_funcs);
    errdefer allocator.free(func_sigs);
    const func_typeidxs = try allocator.alloc(u32, total_funcs);
    errdefer allocator.free(func_typeidxs);
    if (imports_buf) |ib| {
        var w: u32 = 0;
        for (ib.items) |imp| {
            if (imp.kind != .func) continue;
            const tidx = imp.payload.func_typeidx;
            if (tidx >= types.items.len) return Error.MissingTypeSection;
            func_sigs[w] = types.items[tidx];
            func_typeidxs[w] = tidx;
            w += 1;
        }
    }
    for (defined_func_typeidx, 0..) |type_idx, i| {
        if (type_idx >= types.items.len) return Error.MissingTypeSection;
        func_sigs[num_imports + i] = types.items[type_idx];
        func_typeidxs[num_imports + i] = type_idx;
    }

    // §9.9 / 9.9-l-1b-d093-d76 (skip-impl drainage):
    // Wasm spec §3.4.8 start function validation. A start
    // section (id=8) carries a single funcidx; the referenced
    // function must (a) exist in the function index space and
    // (b) have signature `[] → []` (no params, no results).
    // Drains `start.wast` SKIP-VALIDATOR-GAP for "unknown
    // function" / "start function must be [] → []".
    if (module.find(.start)) |ss| {
        var pos: usize = 0;
        const start_funcidx = try leb128.readUleb128(u32, ss.body, &pos);
        if (pos != ss.body.len) return Error.UnsupportedEntrySignature; // trailing bytes in start section
        if (start_funcidx >= total_funcs) return Error.InvalidStartFunction;
        const start_sig = func_sigs[start_funcidx];
        if (start_sig.params.len != 0 or start_sig.results.len != 0) {
            return Error.InvalidStartFunction;
        }
    }

    // 7.5-close-d042-prep: decode globals / tables / data /
    // elements so we can build the validator's per-function
    // type-checking context. Sections are OPTIONAL; absent
    // sections yield empty slices / 0 counts.
    var globals_buf: ?sections.Globals = null;
    defer if (globals_buf) |*g| g.deinit();
    var tables_buf: ?sections.Tables = null;
    defer if (tables_buf) |*t| t.deinit();
    var datas_buf: ?sections.Datas = null;
    defer if (datas_buf) |*d| d.deinit();
    var elems_buf: ?sections.Elements = null;
    defer if (elems_buf) |*e| e.deinit();

    if (module.find(.global)) |s| globals_buf = try sections.decodeGlobals(allocator, s.body);
    if (module.find(.table)) |s| tables_buf = try sections.decodeTables(allocator, s.body);
    if (module.find(.data)) |s| datas_buf = try sections.decodeData(allocator, s.body);
    if (module.find(.element)) |s| elems_buf = try sections.decodeElement(allocator, s.body);

    // §9.9 / 9.9-l-1b-d093-d77 (skip-impl drainage):
    // Wasm spec §3.4.3 / §3.3.2 global init-expression
    // validation. Per spec, a defined global's init_expr
    // must be a "constant expression": single const opcode
    // (i32/i64/f32/f64.const, ref.null, ref.func, or
    // global.get of an *imported* *immutable* global)
    // followed by `end (0x0B)`, AND the result type must
    // match the declared valtype.
    // Count global imports once for d-77 + d-78 const-expr
    // checks (init-expr `global.get` must reference an
    // imported immutable global).
    var num_global_imports_main: u32 = 0;
    if (imports_buf) |ib| {
        for (ib.items) |imp| if (imp.kind == .global) {
            num_global_imports_main += 1;
        };
    }
    if (globals_buf) |g| {
        for (g.items) |gd| {
            try rv.validateGlobalInitExpr(gd.init_expr, gd.valtype, num_global_imports_main, imports_buf, total_funcs);
        }
    }

    // §9.9 / 9.9-l-1b-d093-d78 (skip-impl drainage):
    // Wasm spec §3.4.6 / §3.4.7 — active elem/data segment
    // **offset expressions** must be `i32`-typed constant
    // expressions per §3.3.2. Drains `elem` + `data`
    // SKIP-VALIDATOR-GAP entries with "type mismatch",
    // "constant expression required", "unknown global" in
    // offset positions.
    if (datas_buf) |d| {
        for (d.items) |seg| {
            if (seg.kind == .active) {
                try rv.validateGlobalInitExpr(seg.offset_expr, data_off_vt, num_global_imports_main, imports_buf, total_funcs);
            }
        }
    }
    if (elems_buf) |e| {
        for (e.items) |seg| {
            if (seg.kind == .active) {
                // D-475: a table64 elem offset is i64-typed (§3.3.6).
                const off_vt = elemOffsetValType(imports_buf, tables_buf, seg.tableidx);
                try rv.validateGlobalInitExpr(seg.offset_expr, off_vt, num_global_imports_main, imports_buf, total_funcs);
            }
        }
    }

    // §9.12-E / B158: validator_globals indexed by FULL wasm global
    // index space (imports prefix + defined; mirrors B153/B154's
    // globals_offsets shape). Without this, opGlobalGet/Set rejects
    // imported-global references as out-of-bounds (B156 Errors 1+2).
    const defined_globals_n: usize = if (globals_buf) |g| g.items.len else 0;
    const validator_globals = try a.alloc(validator_mod.GlobalEntry, @as(usize, nm_global_imports) + defined_globals_n);
    if (imports_buf) |ib| {
        var gi: usize = 0;
        for (ib.items) |imp| {
            if (imp.kind != .global) continue;
            validator_globals[gi] = .{ .valtype = imp.payload.global.valtype, .mutable = imp.payload.global.mutable };
            gi += 1;
        }
    }
    if (globals_buf) |g| {
        for (g.items, 0..) |gd, gi| {
            validator_globals[@as(usize, nm_global_imports) + gi] = .{ .valtype = gd.valtype, .mutable = gd.mutable };
        }
    }

    // ADR-0052 §9.9 / 9.9-h-2 — per-global byte offsets via
    // export_lookup helper (§9.12-E / B154; mirrors the empty-fn
    // path). Result indexed by FULL wasm global index space:
    // imports prefix at [0..nm_global_imports), defined at
    // [nm_global_imports..total).
    const elay = try @import("export_lookup.zig").computeGlobalsLayout(allocator, wasm_bytes);
    const globals_offsets = elay.offsets;
    errdefer allocator.free(globals_offsets);
    const globals_valtypes = elay.valtypes;
    errdefer allocator.free(globals_valtypes);
    // close-plan §6 (j) Step B cohort 3 — validator table-index space is
    // imports prefix + defined. Pre-fix shape only exposed defined tables
    // so `call_indirect`/`table.*` against an imported table (e.g.
    // `(import "spectest" "table" ...)` in elem.57 / linking.17 /
    // imports.60-61 / table_grow.6) surfaced as `InvalidFuncIndex` at
    // table_idx=0 even though the imported table existed.
    var num_table_imports_main: u32 = 0;
    if (imports_buf) |ib| {
        for (ib.items) |imp| if (imp.kind == .table) {
            num_table_imports_main += 1;
        };
    }
    const validator_tables: []const zir.TableEntry = blk: {
        const total: usize = @as(usize, num_table_imports_main) + (if (tables_buf) |t| t.items.len else 0);
        if (total == 0) break :blk &.{};
        const out = try a.alloc(zir.TableEntry, total);
        var write_idx: usize = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| {
                if (imp.kind != .table) continue;
                out[write_idx] = .{
                    .elem_type = imp.payload.table.elem_type,
                    .min = imp.payload.table.min,
                    .max = imp.payload.table.max,
                    .idx_type = imp.payload.table.idx_type,
                };
                write_idx += 1;
            }
        }
        if (tables_buf) |t| {
            for (t.items) |tbl| {
                out[write_idx] = tbl;
                write_idx += 1;
            }
        }
        break :blk out;
    };
    // D-475 — per-table idx_type slice for the emitters (imports-first
    // wasm table index space, same source as `validator_tables`). The
    // former JitTable64Unsupported guard is gone: the emitters index
    // tables at their declared width (C2/C3) and the descriptors are
    // u64 (C1), so i64-indexed tables compile natively.
    const table_idx_types: []const zir.IdxType = blk: {
        if (validator_tables.len == 0) break :blk &.{};
        const out = try a.alloc(zir.IdxType, validator_tables.len);
        for (validator_tables, 0..) |t, i| out[i] = t.idx_type;
        break :blk out;
    };
    const validator_data_count: u32 = if (datas_buf) |d| @intCast(d.items.len) else 0;
    const validator_elem_count: u32 = if (elems_buf) |e| @intCast(e.items.len) else 0;

    // §9.9 / 9.9-l-1b-d093-d74 (skip-impl drainage):
    // Wasm spec §3.4.10 export validation. Decode the export
    // section (when present) and verify:
    //   (a) Each export's idx references a defined entity in
    //       its kind's index space (func / table / memory /
    //       global).
    //   (b) All exported names within a module are pairwise
    //       distinct (no duplicates).
    // Drains `assert_invalid` modules whose validity hinges on
    // these spec rules — previously SKIP-VALIDATOR-GAP at the
    // `.assert_invalid` runner arm because compileWasm
    // accepted them.
    if (module.find(.@"export")) |s| {
        var exports = try sections.decodeExports(a, s.body);
        defer exports.deinit();

        // Count imports per kind (memory / table / global
        // imports occupy slots 0..N before any defined entity).
        var num_table_imports: u32 = 0;
        var num_memory_imports: u32 = 0;
        var num_global_imports: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| switch (imp.kind) {
                .func => {},
                .table => num_table_imports += 1,
                .memory => num_memory_imports += 1,
                .global => num_global_imports += 1,
                .tag => {}, // EH tag imports don't shift table/mem/global bases (10.E)
            };
        }
        const total_tables: u32 = num_table_imports + @as(u32, @intCast(if (tables_buf) |t| t.items.len else 0));
        const total_globals: u32 = num_global_imports + @as(u32, @intCast(if (globals_buf) |g| g.items.len else 0));
        // Memory section: at most one memory in Wasm 2.0
        // (multi-memory is a Wasm 3.0 proposal; out of scope).
        const defined_memories: u32 = if (module.find(.memory)) |ms| blk: {
            var ms_buf = try sections.decodeMemory(a, ms.body);
            defer ms_buf.deinit();
            break :blk @intCast(ms_buf.items.len);
        } else 0;
        const total_memories: u32 = num_memory_imports + defined_memories;

        // Track names for duplicate detection. Backed by the
        // arena `a` (function-local), released on compileWasm
        // return.
        var seen_names: std.StringHashMap(void) = .init(a);
        defer seen_names.deinit();
        try seen_names.ensureTotalCapacity(@intCast(exports.items.len));
        for (exports.items) |e| {
            const gop = try seen_names.getOrPut(e.name);
            if (gop.found_existing) return Error.DuplicateExport;
            const ok = switch (e.kind) {
                .func => e.idx < total_funcs,
                .table => e.idx < total_tables,
                .memory => e.idx < total_memories,
                .global => e.idx < total_globals,
            };
            if (!ok) return Error.ExportIdxOutOfRange;
        }
    }

    // Compile each defined function. On failure, log the
    // offending func_idx to stderr — the spec-jit-compile runner
    // captures this via `2>&1 > /tmp/<host>.log` so root-cause
    // bisection (which fixture, which function) is visible
    // without re-running the gate.
    // §9.9 / 9.9-l-1b-d093-d79: count memories (imports +
    // defined) so the validator can reject memory ops
    // (load/store/size/grow/fill/copy/init) in function bodies
    // when the module has no memory.
    var validator_memory_count: u32 = 0;
    // ADR-0111 D4 — memory 0's idx_type. Threaded into per-func
    // emit so codegen can select i32 fast-path vs i64 wrap-check.
    // Imports take precedence (memidx 0 is the first imported
    // memory if any); otherwise the first defined memory.
    var memory0_idx_type: sections.MemoryEntry.IdxType = .i32;
    var memory0_page_size_log2: u8 = 16; // ADR-0202 D4 — memory0 qualification
    var memory0_idx_type_known = false;
    // D-324 — collect the full per-memory idx_type slice (imports
    // first, then defined) so mixed i32/i64 multi-memory bodies
    // validate each memory op against ITS memory. Arena-allocated.
    var memory_idx_types: std.ArrayList(sections.MemoryEntry.IdxType) = .empty;
    if (imports_buf) |ib| {
        for (ib.items) |imp| if (imp.kind == .memory) {
            if (!memory0_idx_type_known) {
                memory0_idx_type = imp.payload.memory.idx_type;
                memory0_page_size_log2 = imp.payload.memory.page_size_log2;
                memory0_idx_type_known = true;
            }
            try memory_idx_types.append(a, imp.payload.memory.idx_type);
            validator_memory_count += 1;
        };
    }
    if (module.find(.memory)) |ms| {
        var ms_buf = try sections.decodeMemory(a, ms.body);
        defer ms_buf.deinit();
        if (!memory0_idx_type_known and ms_buf.items.len > 0) {
            memory0_idx_type = ms_buf.items[0].idx_type;
            memory0_page_size_log2 = ms_buf.items[0].page_size_log2;
            memory0_idx_type_known = true;
        }
        for (ms_buf.items) |me| try memory_idx_types.append(a, me.idx_type);
        validator_memory_count += @intCast(ms_buf.items.len);
    }

    // §9.9 / 9.9-l-1b-d093-d83 (skip-impl drainage):
    // Wasm spec §3.3.5.20 table.init elem-vs-table reftype
    // matching. Build the per-elem-segment reftype slice; the
    // validator's opTableInit compares against the destination
    // table's reftype.
    const elem_types_slice: []const zir.ValType = if (elems_buf) |e| blk: {
        const out = try a.alloc(zir.ValType, e.items.len);
        for (e.items, 0..) |seg, i| out[i] = seg.elem_type;
        break :blk out;
    } else &.{};

    // Wasm 3.0 EH §4.5 (10.E-N-1): decode the tag section so the
    // validator can range-check `throw tag_idx` + try_table catch /
    // catch_ref `tag_idx` and pop each tag's param types.
    //
    // The wasm tag index space is imported tags (kind .tag) ++ defined
    // tags (section 13), per spec ordering (§3.4). A defined-only slice
    // mis-resolves every catch/throw index by the imported-tag count →
    // wrong tag's params → StackTypeMismatch at validate (e.g.
    // exception-handling/try_table.1, which imports 2 tags). The
    // tag_param_counts / slot_counts built below index off this same
    // slice and feed the JIT throw/catch pop-count, so the full space is
    // load-bearing there too. Mirrors the interp (instantiate.zig cyc114
    // validator + cyc116 throw wiring). Arena-allocated (freed with `a`).
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

    // Wasm 3.0 EH (10.E-N-3) — pre-resolve per-tag param count
    // from `tags[i].typeidx → module_types[typeidx].params.len`.
    // The interp's `throwOp` reads this to pop the right number
    // of operand values into the Exception payload at throw
    // time; without it, real-world tag-using Wasm would always
    // pop 0 (the safe-fallback default). Allocated on the
    // outer (caller-owned) allocator so the slice survives the
    // arena tear-down and lands in `CompiledWasm.tag_param_counts`.
    const tag_param_counts: []u32 = blk: {
        if (tags_slice.len == 0) break :blk &.{};
        const out = try allocator.alloc(u32, tags_slice.len);
        errdefer allocator.free(out);
        for (tags_slice, 0..) |tag, i| {
            if (tag.typeidx >= types.items.len) return Error.InvalidFuncIndex;
            out[i] = @intCast(types.items[tag.typeidx].params.len);
        }
        break :blk out;
    };
    errdefer if (tag_param_counts.len > 0) allocator.free(tag_param_counts);

    // ADR-0120 D5 / cycle 1 — parallel slot-count table (v128 = 2
    // slots; all v0.1 numeric/ref types = 1). The JIT throw / catch
    // emit reads this to compute `[runtime_ptr + payload_off + i*8]`
    // offsets when v128 tag params are present. Default `&.{}`
    // keeps behaviour-preserving for modules without tags.
    const tag_param_slot_counts: []u32 = blk: {
        if (tags_slice.len == 0) break :blk &.{};
        const out = try allocator.alloc(u32, tags_slice.len);
        errdefer allocator.free(out);
        for (tags_slice, 0..) |tag, i| {
            if (tag.typeidx >= types.items.len) return Error.InvalidFuncIndex;
            var slots: u32 = 0;
            for (types.items[tag.typeidx].params) |p| {
                slots += runtime_mod.slotCountForValType(p);
            }
            out[i] = slots;
        }
        break :blk out;
    };
    errdefer if (tag_param_slot_counts.len > 0) allocator.free(tag_param_slot_counts);

    // 10.G GC-on-JIT (A-3) — typeidx-indexed struct field counts for the
    // lowerer to stamp into `struct.new`'s `ZirInstr.extra` (the variadic
    // pop/store count). Non-struct typeidx → 0. Arena-allocated: read only
    // during this call's lowering, not stored in CompiledWasm.
    const struct_field_counts: []u32 = blk: {
        if (types.struct_defs.len == 0) break :blk &.{};
        const out = try a.alloc(u32, types.struct_defs.len);
        for (types.struct_defs, 0..) |sd, i| {
            out[i] = if (sd) |s| @intCast(s.fields.len) else 0;
        }
        break :blk out;
    };

    // 10.G GC-on-JIT (A-6a) — typeidx-indexed array element valtype bytes
    // (Wasm §5.3.5 wire byte: 0x78 i8 / 0x77 i16 / 0x7F i32 …) for the
    // lowerer to stamp into `array.get_s`'s `ZirInstr.extra`, so the emit
    // knows the packed width (i8 → SXTB, i16 → SXTH) without re-deriving the
    // type section. Non-array typeidx → 0. Arena-allocated; read only during
    // this call's lowering.
    const array_elem_valtypes: []u8 = blk: {
        if (types.array_defs.len == 0) break :blk &.{};
        const out = try a.alloc(u8, types.array_defs.len);
        for (types.array_defs, 0..) |ad, i| {
            out[i] = if (ad) |d| d.element.storage.specByte() else 0;
        }
        break :blk out;
    };

    // 10.G GC-on-JIT (D-212) — typeidx-indexed rows of struct field valtype
    // bytes, so the regalloc vreg-class classifier + struct.get emit can
    // FP-class an f32/f64 field result (the f32-return / call boundary reads
    // the FP home; a GPR-class struct.get result left V0/XMM0 stale).
    const struct_field_valtypes: [][]const u8 = blk: {
        if (types.struct_defs.len == 0) break :blk &.{};
        const out = try a.alloc([]const u8, types.struct_defs.len);
        for (types.struct_defs, 0..) |sd, i| {
            if (sd) |s| {
                const row = try a.alloc(u8, s.fields.len);
                for (s.fields, 0..) |f, j| row[j] = f.storage.specByte();
                out[i] = row;
            } else {
                out[i] = &.{};
            }
        }
        break :blk out;
    };

    // §9.9 / 9.9-l-1b-d093-d82 (skip-impl drainage):
    // Wasm spec §3.4.7.3 / §3.4.10 declared-funcrefs set. A
    // funcidx is "declared" iff it appears in some global
    // initializer, element segment (funcidx or init-expr), or
    // export (kind=func). Function code bodies and the start
    // function do NOT contribute. Used by the validator's
    // `opRefFunc` to reject `ref.func N` when N is not in the
    // declared set ("undeclared function reference").
    const declared_funcs = try a.alloc(bool, total_funcs);
    @memset(declared_funcs, false);
    if (globals_buf) |g| {
        for (g.items) |gd| {
            if (rv.initExprRefFunc(gd.init_expr)) |fidx| {
                if (fidx < total_funcs) declared_funcs[fidx] = true;
            }
        }
    }
    if (elems_buf) |e| {
        for (e.items) |seg| {
            for (seg.funcidxs) |fidx| {
                // ref.null entries are encoded as maxInt(u32);
                // skip those.
                if (fidx != std.math.maxInt(u32) and fidx < total_funcs) {
                    declared_funcs[fidx] = true;
                }
            }
        }
    }
    if (module.find(.@"export")) |s| {
        var exports = try sections.decodeExports(a, s.body);
        defer exports.deinit();
        for (exports.items) |e| {
            if (e.kind == .func and e.idx < total_funcs) {
                declared_funcs[e.idx] = true;
            }
        }
    }

    // D-235 — module-level func-subtyping flag, computed once and threaded
    // into every function's emit so `call_indirect` routes through the
    // `jitCallIndirectSubtypeOk` trampoline (the inline D-111 structural sig
    // compare is finality/subtype-blind). Must match `setup.zig`'s
    // `store_raw_typeidx` (both derive from the same `usesTypeSubtyping`).
    const uses_type_subtyping = needs_heap_detector.usesTypeSubtyping(types);

    // ADR-0202 D4 — elide memory0 scalar bounds checks when the knob is
    // `.auto` AND memory0 qualifies for a guard-page reservation. The SAME
    // `memory_backing.qualifies` predicate drives the runtime backing choice
    // (setup.zig / instantiate.zig / wasm_memory_new), so elided code is only
    // ever bound to a guarded memory0 — the binding-time soundness invariant
    // holds by construction (no non-guarded path exists for a qualifying
    // memory). `.explicit` forces checks (D-510 differential-fuzz axis).
    const bounds_elided = boundsChecksMode() == .auto and
        memory0_idx_type_known and // a module with no memory0 has nothing to elide
        memory_backing.qualifies(memory0_idx_type, memory0_page_size_log2);

    const results = try allocator.alloc(compile_func.FuncResult, defined_func_typeidx.len);
    errdefer allocator.free(results);
    var compiled: usize = 0;
    errdefer for (results[0..compiled]) |*r| compile_func.deinitFuncResult(allocator, r);
    for (codes.items, 0..) |code, i| {
        // Defined function K's wasm-space index = num_imports + K.
        const wasm_idx: u32 = num_imports + @as(u32, @intCast(i));
        const sig = func_sigs[wasm_idx];
        // 7.5-close-d042-impl: validate before compile. Surfaces
        // type-mismatch / unknown-local / unknown-global etc. as
        // ValidationFailed instead of silent miscompile or arbitrary
        // lower-side errors. The full validator-context split is
        // documented in `.dev/lessons/2026-05-07-validator-dead-
        // code-in-runtime.md`.
        // D-115 d-39: collect per-untyped-`select` resolved valtype
        // bytes so lower can populate `ZirInstr.extra` for the emit
        // dispatch (FCSEL / FpSelect vs gpr32 CSEL).
        var select_types: std.ArrayList(u8) = .empty;
        defer select_types.deinit(allocator);
        validator_mod.validateFunctionAndCollectSelectTypesWithMemory(
            allocator,
            sig,
            code.locals,
            code.body,
            func_sigs,
            validator_globals,
            types.items,
            validator_data_count,
            validator_tables,
            validator_elem_count,
            validator_memory_count,
            declared_funcs,
            elem_types_slice,
            data_count_section_present,
            &select_types,
            memory0_idx_type,
            memory_idx_types.items,
            tags_slice,
            // 10.G GC-on-JIT: thread the type section's kind + struct/array
            // defs so struct.new* / array.* validate (vs InvalidFuncIndex).
            types.kinds,
            types.struct_defs,
            types.array_defs,
            types.supertypes,
            // D-239: typed `ref.func N` → precise `(ref func_typeidxs[N])`
            // (ADR-0123 D4); else abstract funcref → StackTypeMismatch vs a
            // `(ref $t)` param (br_on_null / br_on_non_null / ref_as_non_null).
            func_typeidxs,
            // ADR-0126: full Types so subtypeCtx uses iso-recursive canonical
            // equality on concrete→concrete (cross-rec-group identity).
            &types,
        ) catch |err| {
            dbg.print("codegen", "compileWasm: func[{d}] params={d} results={d} → validate {s}\n", .{
                wasm_idx,
                sig.params.len,
                sig.results.len,
                @errorName(err),
            });
            return err;
        };
        results[i] = compile_func.compileOne(
            allocator,
            wasm_idx,
            sig,
            code.body,
            code.locals,
            types.items,
            func_sigs,
            num_imports,
            globals_offsets,
            globals_valtypes,
            select_types.items,
            .register_write,
            memory0_idx_type,
            tag_param_counts,
            struct_field_counts,
            array_elem_valtypes,
            struct_field_valtypes,
            uses_type_subtyping,
            bounds_elided,
            table_idx_types,
        ) catch |err| {
            dbg.print("codegen", "compileWasm: func[{d}] params={d} results={d} → {s}\n", .{
                wasm_idx,
                sig.params.len,
                sig.results.len,
                @errorName(err),
            });
            return err;
        };
        compiled += 1;
    }

    // Link into one JitModule. The linker reserves the first
    // `num_imports` slots in `func_offsets` for import sentinels;
    // import calls never produce a CallFixup (the emit pass routes
    // them to the function-local trap stub directly), so the
    // sentinel slots are never read.
    //
    // ADR-0106 cycle 3e Phase 2'h: collect wrapper specs for every
    // multi-result function (results.len >= 2). The linker's pass-2
    // calls `wrapper_thunk.emit` per spec; shapes that aren't yet
    // supported return UnsupportedOp and the linker silently skips
    // them (sets `thunk_offsets[idx] = NO_THUNK`). Bodies stay
    // register_write per cycle 3d; the wrapper bridges to
    // buffer-write convention only at the entry helper boundary.
    const bodies = try allocator.alloc(linker.FuncBody, results.len);
    defer allocator.free(bodies);
    for (results, 0..) |r, i| {
        bodies[i] = .{
            .bytes = r.out.bytes,
            .call_fixups = r.out.call_fixups,
            .frame_bytes = r.out.frame_bytes,
            .oob_stub_off = r.out.oob_stub_off, // ADR-0202 D3
        };
        // Permanent JIT-bytes dump primitive (debug_jit_auto Recipe 16):
        // `ZWASM_DEBUG=jit.dump` prints each function's body-relative
        // machine code as a hex line, so a miscompile can be disassembled
        // (`objdump -b binary`/`ndisasm`) at the instruction level instead
        // of guessing at the IR/vreg level. Body-relative (pre-link), so
        // call/branch targets are not yet fixed up.
        if (dbg.on("jit.dump")) {
            const wasm_idx = num_imports + @as(u32, @intCast(i));
            std.debug.print("[jit.dump] func={d} len={d} hex=", .{ wasm_idx, r.out.bytes.len });
            for (r.out.bytes) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print("\n", .{});
        }
    }
    // D-477: a buffer-write thunk is also needed for EXPORTED multi-arg
    // functions — `JitInstance.invoke` / `runWasiLenient --invoke` marshal N
    // args through the wrapper when the shape-specific `callXxx` helpers cap
    // out. Only exported funcs are host-invocable, so gate on the export set
    // to avoid emitting a thunk per internal function. `emit` still returns
    // UnsupportedOp for shapes it can't lower (FP, v128, >7 params); the
    // linker skips those (NO_THUNK), so over-requesting here is harmless.
    var exported_funcs: std.AutoHashMap(u32, void) = .init(allocator);
    defer exported_funcs.deinit();
    if (module.find(.@"export")) |es| {
        var exports = try sections.decodeExports(allocator, es.body);
        defer exports.deinit();
        for (exports.items) |e| {
            if (e.kind == .func) try exported_funcs.put(e.idx, {});
        }
    }
    var wrapper_specs_list: std.ArrayList(linker.WrapperSpec) = .empty;
    defer wrapper_specs_list.deinit(allocator);
    for (results, 0..) |_, i| {
        const wasm_idx = num_imports + @as(u32, @intCast(i));
        const sig = func_sigs[wasm_idx];
        const wants_thunk = sig.results.len >= 2 or
            (sig.params.len >= 1 and exported_funcs.contains(wasm_idx));
        if (wants_thunk) {
            try wrapper_specs_list.append(allocator, .{
                .func_idx = wasm_idx,
                .sig = sig,
            });
        }
    }
    const linked = try linker.linkWithThunks(allocator, bodies, num_imports, wrapper_specs_list.items);
    errdefer {
        var l = linked;
        l.deinit(allocator);
    }

    // Phase 10.E IT-5 — collect per-function HandlerEntry slices
    // into a single per-Instance ExceptionTable. pc shifts use
    // `linked.func_offsets` so the resulting pcs are module-
    // relative (consistent with the FP-walk unwinder's
    // `absolute_pc - block_addr` lookup key).
    const per_func_handlers = try allocator.alloc([]const exception_table.HandlerEntry, results.len);
    defer allocator.free(per_func_handlers);
    for (results, 0..) |r, i| {
        per_func_handlers[i] = r.out.exception_handlers;
    }
    const exception_entries = try exception_table.collectModuleTable(
        allocator,
        per_func_handlers,
        linked.func_offsets,
        num_imports,
    );
    errdefer if (exception_entries.len > 0) allocator.free(exception_entries);

    // Func-kind exports for the AOT producer (ADR-0138). Names + slice
    // are arena-allocated via `a`, so they live as long as the returned
    // CompiledWasm and need no explicit free in `deinit`.
    const func_exports = try collectFuncExports(a, &module, total_funcs);

    return .{
        .module = linked,
        .func_results = results,
        .func_sigs = func_sigs,
        .func_typeidxs = func_typeidxs,
        .num_imports = num_imports,
        .globals_offsets = globals_offsets,
        .globals_valtypes = globals_valtypes,
        .num_global_imports = nm_global_imports,
        .tag_param_counts = tag_param_counts,
        .tag_param_slot_counts = tag_param_slot_counts,
        .exception_table = .{ .entries = exception_entries },
        .exports = func_exports,
        .bounds_elided = bounds_elided,
        .arena = arena,
    };
}

/// Collect func-kind exports (name → wasm func idx) for the AOT
/// producer. Names and the returned slice are allocated via `a` (the
/// CompiledWasm arena), so they share the module's lifetime. Returns an
/// empty slice when there is no export section. Out-of-range targets are
/// skipped defensively (the validator already rejects them upstream).
/// D-475 (table64) — expected offset type of an ACTIVE elem segment =
/// the target table's idx_type (imports-first wasm table index space;
/// mirrors the D-219 `data_off_vt` treatment for memory64 data
/// segments). Missing/unknown table → `.i32` (the validator rejects the
/// out-of-range tableidx separately).
fn elemOffsetValType(imports_buf: anytype, tables_buf: anytype, tableidx: u32) zir.ValType {
    var k: u32 = tableidx;
    if (imports_buf) |ib| {
        for (ib.items) |imp| {
            if (imp.kind != .table) continue;
            if (k == 0) return if (imp.payload.table.idx_type == .i64) .i64 else .i32;
            k -= 1;
        }
    }
    if (tables_buf) |t| {
        if (k < t.items.len) return if (t.items[k].idx_type == .i64) .i64 else .i32;
    }
    return .i32;
}

pub fn collectFuncExports(a: Allocator, module: anytype, total_funcs: u32) Error![]const runner_mod.FuncExport {
    const es = module.find(.@"export") orelse return &.{};
    var exports = try sections.decodeExports(a, es.body);
    defer exports.deinit();

    var list: std.ArrayList(runner_mod.FuncExport) = .empty;
    errdefer list.deinit(a);
    for (exports.items) |e| {
        if (e.kind != .func or e.idx >= total_funcs) continue;
        try list.append(a, .{ .name = try a.dupe(u8, e.name), .func_idx = e.idx });
    }
    return list.toOwnedSlice(a);
}

// Post-compile init helpers extracted to `compile_init.zig` per
// ADR-0091. Re-exported here so callers (runner.zig + downstream)
// reach `compile.applyDefinedGlobalsInit` etc. unchanged.
const compile_init = @import("compile_init.zig");
pub const applyDefinedGlobalsInit = compile_init.applyDefinedGlobalsInit;
pub const resolveFuncrefGlobals = compile_init.resolveFuncrefGlobals;
pub const applyTableInit = compile_init.applyTableInit;
pub const applyTableInitCtx = compile_init.applyTableInitCtx;
pub const applyTableInitForTable = compile_init.applyTableInitForTable;
pub const applyTableInitForTableCtx = compile_init.applyTableInitForTableCtx;
pub const patchTableImportFuncptrs = compile_init.patchTableImportFuncptrs;
pub const patchTableImportFuncptrsCtx = compile_init.patchTableImportFuncptrsCtx;
pub const countDeclaredTables = compile_init.countDeclaredTables;
pub const declaredTableMin = compile_init.declaredTableMin;
pub const declaredTableMax = compile_init.declaredTableMax;
pub const applyActiveDataSegments = compile_init.applyActiveDataSegments;
pub const applyActiveDataSegmentsCtx = compile_init.applyActiveDataSegmentsCtx;
