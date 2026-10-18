//! `.cwasm` binary format types + write/parse helpers
//! (per ADR-0039).
//!
//! Inline-bytes container: header + per-func metadata +
//! types + relocs + code sections in one file. Producer-only
//! on matching arch (cross-arch deferred to Phase 12+ per
//! ADR-0039 §"Alternative D"). Phase 12's loader reads via
//! the symmetric `parseHeader` / `parseFuncMeta` /
//! `parseReloc` helpers.
//!
//! All multi-byte fields are little-endian. The header is
//! `header_size` bytes, each per-func metadata entry
//! `func_meta_size` and each reloc `reloc_size` (packed). All three are
//! fixed-shape so the loader can mmap the file and index
//! sections without sequential parsing.
//!
//! Zone 2 (`src/engine/codegen/aot/`). Class-blind +
//! arch-blind: the arch tag in the header identifies which
//! backend produced the code section, but this module
//! itself doesn't import from `arm64/` or `x86_64/`. The
//! producer (`compile.zig`) supplies the arch tag.

const std = @import("std");

pub const magic = [4]u8{ 'C', 'W', 'A', 'S' };
pub const version_v0_1: u32 = 0x0001_0000; // (major << 16) | minor — superseded
pub const version_v0_2: u32 = 0x0002_0000; // superseded: exports section (ADR-0138)
pub const version_v0_3: u32 = 0x0003_0000; // superseded: + globals section (ADR-0139)
pub const version_v0_4: u32 = 0x0004_0000; // superseded: + imports-metadata section (D-251 AOT-WASI)
// v0.5 (ADR-0203 stage 2): + embedded original wasm_bytes (the loader hands
// the REAL module bytes to the normal setup path — zero re-encode
// divergence), + per-func extras {frame_bytes, oob_stub_off} and the
// module-level exception table (compiler output the full-fidelity
// deserializer cannot re-derive; everything else IS re-derived from the
// embedded bytes with the same section decoders compileWasm uses).
pub const version_v0_5: u32 = 0x0005_0000; // current

pub const arch_arm64: u32 = 1;
pub const arch_x86_64: u32 = 2;

pub const header_size: u32 = 136; // v0.5: 112 + {wasm_bytes,func_extras,eh}_{offset,size}

/// `flags` bit 0 — the module declares a linear memory (the
/// `memory_*` header fields + memory_init data section are meaningful).
pub const flag_has_memory: u32 = 0x1;
/// `flags` bit 1 — the module declares table 0 (the `table0_size` +
/// elem_data section are meaningful; cycle-2a single-table MVP).
pub const flag_has_table: u32 = 0x2;
/// `flags` bit 2 (ADR-0203 stage 4 / ADR-0202 D5 / D-515(1)) — the code
/// was compiled with memory0 scalar bounds checks ELIDED (guard-page
/// codegen). The loader restores `CompiledWasm.bounds_elided`; the re-link
/// re-registers the oob-stub trap entries against the loaded block, and
/// setup binds the guarded reservation (no plain-heap fallback for a
/// qualifying memory — allocBacking fails loudly instead).
pub const flag_bounds_elided: u32 = 0x4;
pub const func_meta_size: u32 = 16; // v0.3 cycle-2a: + canon_typeidx (was 12)
pub const reloc_size: u32 = 9; // 4 + 4 + 1 (no padding)
pub const reloc_kind_direct_call: u8 = 0;

pub const Error = error{
    BadMagic,
    UnsupportedVersion,
    UnknownArch,
    TruncatedHeader,
    TruncatedFuncMeta,
    TruncatedReloc,
    TruncatedExport,
    TruncatedImportEntry,
    TruncatedEhEntry,
};

/// Top-level container header (per ADR-0039 + Revision 2; v0.2 per
/// ADR-0138). 68 bytes; field offsets are stable for v0.2.
pub const CwasmHeader = struct {
    arch: u32, // arch_arm64 | arch_x86_64
    flags: u32 = 0, // reserved (debug info, signing, …)
    n_funcs: u32,
    n_types: u32,
    n_imports: u32,
    code_offset: u32,
    code_size: u32,
    metadata_offset: u32,
    metadata_size: u32,
    types_offset: u32,
    types_size: u32,
    relocs_offset: u32,
    relocs_size: u32,
    // v0.2 (ADR-0138): exports section so a loaded `.cwasm` resolves
    // entry points by name without re-parsing the original `.wasm`.
    exports_offset: u32 = 0,
    exports_size: u32 = 0,
    // v0.3 (ADR-0139): globals section — pre-evaluated defined-global
    // init values (16 B each, `Value.bits128`) so a standalone runtime
    // reconstructs `globals_base` without re-evaluating init-exprs.
    globals_offset: u32 = 0,
    globals_size: u32 = 0,
    // v0.3 cycle-1b: linear-memory state (valid iff flags & flag_has_memory).
    // `memory_init` section = active data segments (offset pre-evaluated).
    memory_min_pages: u32 = 0,
    memory_max_pages: u32 = 0, // 0xFFFF_FFFF = no explicit max (spec ceiling)
    memory_init_offset: u32 = 0,
    memory_init_size: u32 = 0,
    // v0.3 cycle-2a: table 0 (valid iff flags & flag_has_table). `table0_size`
    // = declared min (slot count); `elem_data` section = active element
    // segments (offsets pre-evaluated). funcptr/typeidx arrays are computed
    // at load from func_offsets + per-func canon_typeidx.
    table0_size: u32 = 0,
    elem_offset: u32 = 0,
    elem_size: u32 = 0,
    // v0.4 (D-251 AOT-WASI): imports-metadata section — `(module, name,
    // kind)` per declared import, in wasm-space order. Lets a standalone
    // runner rebuild `host_dispatch_base` (WASI syscall fn-ptrs) without
    // the original `.wasm`. Only module/name/kind are needed (the dispatch
    // populate reads no payload), so the section is intentionally minimal.
    imports_offset: u32 = 0,
    imports_size: u32 = 0,
    // v0.5 (ADR-0203 stage 2): the original module bytes, verbatim. The
    // full-fidelity load path re-derives all module metadata from these with
    // the SAME section decoders compileWasm uses, and hands them to the
    // normal setup path (setupRuntimeLinked re-decodes ~15 sections).
    wasm_bytes_offset: u32 = 0,
    wasm_bytes_size: u32 = 0,
    // v0.5: per-DEFINED-func extras the re-link needs beyond v0.4's
    // metadata: `{frame_bytes: u32, oob_stub_off: u32}` × n_funcs
    // (`func_extra_size` each, func-idx order; oob sentinel = no_stub).
    func_extras_offset: u32 = 0,
    func_extras_size: u32 = 0,
    // v0.5: the module-level exception table (`[n: u32]` + n ×
    // `eh_entry_size`). pcs are module-relative and stay valid because
    // `linkWithThunks` layout is a pure function of the (identical)
    // serialized bodies — the deserializer asserts the re-linked
    // `func_offsets` match the artifact's as the nondeterminism tripwire.
    eh_offset: u32 = 0,
    eh_size: u32 = 0,
};

/// v0.5 per-defined-func extras entry size: frame_bytes + oob_stub_off.
pub const func_extra_size: u32 = 8;
/// v0.5 exception-table entry size: pc_start + pc_end + tag_idx(sentinel
/// `eh_tag_none` = catch_all/null) + landing_pad_pc (4 × u32) + kind (u8).
pub const eh_entry_size: u32 = 17;
/// Sentinel for a serialised null `HandlerEntry.tag_idx` (catch_all/_ref).
pub const eh_tag_none: u32 = 0xFFFF_FFFF;

/// Sentinel `memory_max_pages` value for "no explicit max declared".
pub const memory_max_none: u32 = 0xFFFF_FFFF;

/// Bytes per serialised global value (one `runtime.Value` = 16 B).
pub const global_value_size: u32 = 16;

/// One active data segment for the memory_init section: a destination
/// byte offset (pre-evaluated from the offset-expr at produce time) +
/// the init bytes. On parse, `bytes` aliases into the source buffer.
pub const CwasmDataSeg = struct {
    mem_offset: u32,
    bytes: []const u8,
};

/// One active element segment for the elem_data section (v0.3 cycle-2a):
/// a table destination offset (pre-evaluated) + the funcidx list. On parse,
/// `funcidxs` aliases into the source buffer (read via `readInt`).
pub const CwasmElemSeg = struct {
    table_offset: u32,
    funcidxs: []const u32,
};

/// One entry in the exports section (v0.2). Func-kind exports only —
/// `zwasm run` invokes functions. On parse, `name` aliases into the
/// source buffer; on write, `name` is caller-owned.
pub const CwasmExport = struct {
    name: []const u8,
    func_idx: u32, // wasm-space function index (imports included)
};

/// One entry in the imports-metadata section (v0.4). The standalone
/// runner replays these in wasm-space order to rebuild the host-dispatch
/// table; `kind` is `@intFromEnum(sections.ImportKind)` (func=0, …) so the
/// runner increments the function-import index only on func entries. On
/// parse, `module`/`name` alias into the source buffer; on write they are
/// caller-owned.
pub const CwasmImport = struct {
    module: []const u8,
    name: []const u8,
    kind: u8,
};

/// Per-function metadata entry, emitted in `func_idx` order so the
/// loader can index by `func_idx * func_meta_size`.
pub const CwasmFuncMeta = struct {
    code_offset: u32, // offset within code section
    code_size: u32, // bytes of machine code for this func
    n_slots: u16, // regalloc.Allocation.n_slots (frame sizing)
    sig_idx: u16, // index into types section
    // v0.3 cycle-2a: canonical typeidx (the value the runtime puts in
    // `typeidx_base` for a table slot holding this func; what call_indirect's
    // type check compares against). 0 when unused. Default keeps pre-cycle-2a
    // synthetic Input call sites compiling.
    canon_typeidx: u32 = 0,
};

/// Reloc entry: a call-site within the code section that
/// must be patched at load time once function-body
/// addresses are known. Mirrors `arm64/ctx.CallFixup` shape
/// but with an explicit `kind` byte for forward-compat
/// (Phase 12+ may add additional reloc kinds for indirect-
/// call, table-base, etc.).
pub const CwasmReloc = struct {
    code_offset: u32,
    target_func_idx: u32,
    kind: u8, // reloc_kind_direct_call (0) for v0.1
};

// =====================================================================
// Header serialisation
// =====================================================================

pub fn writeHeader(buf: []u8, h: CwasmHeader) Error!void {
    if (buf.len < header_size) return Error.TruncatedHeader;
    @memcpy(buf[0..4], &magic);
    std.mem.writeInt(u32, buf[4..8], version_v0_5, .little);
    std.mem.writeInt(u32, buf[8..12], h.arch, .little);
    std.mem.writeInt(u32, buf[12..16], h.flags, .little);
    std.mem.writeInt(u32, buf[16..20], h.n_funcs, .little);
    std.mem.writeInt(u32, buf[20..24], h.n_types, .little);
    std.mem.writeInt(u32, buf[24..28], h.n_imports, .little);
    std.mem.writeInt(u32, buf[28..32], h.code_offset, .little);
    std.mem.writeInt(u32, buf[32..36], h.code_size, .little);
    std.mem.writeInt(u32, buf[36..40], h.metadata_offset, .little);
    std.mem.writeInt(u32, buf[40..44], h.metadata_size, .little);
    std.mem.writeInt(u32, buf[44..48], h.types_offset, .little);
    std.mem.writeInt(u32, buf[48..52], h.types_size, .little);
    std.mem.writeInt(u32, buf[52..56], h.relocs_offset, .little);
    std.mem.writeInt(u32, buf[56..60], h.relocs_size, .little);
    std.mem.writeInt(u32, buf[60..64], h.exports_offset, .little);
    std.mem.writeInt(u32, buf[64..68], h.exports_size, .little);
    std.mem.writeInt(u32, buf[68..72], h.globals_offset, .little);
    std.mem.writeInt(u32, buf[72..76], h.globals_size, .little);
    std.mem.writeInt(u32, buf[76..80], h.memory_min_pages, .little);
    std.mem.writeInt(u32, buf[80..84], h.memory_max_pages, .little);
    std.mem.writeInt(u32, buf[84..88], h.memory_init_offset, .little);
    std.mem.writeInt(u32, buf[88..92], h.memory_init_size, .little);
    std.mem.writeInt(u32, buf[92..96], h.table0_size, .little);
    std.mem.writeInt(u32, buf[96..100], h.elem_offset, .little);
    std.mem.writeInt(u32, buf[100..104], h.elem_size, .little);
    std.mem.writeInt(u32, buf[104..108], h.imports_offset, .little);
    std.mem.writeInt(u32, buf[108..112], h.imports_size, .little);
    std.mem.writeInt(u32, buf[112..116], h.wasm_bytes_offset, .little);
    std.mem.writeInt(u32, buf[116..120], h.wasm_bytes_size, .little);
    std.mem.writeInt(u32, buf[120..124], h.func_extras_offset, .little);
    std.mem.writeInt(u32, buf[124..128], h.func_extras_size, .little);
    std.mem.writeInt(u32, buf[128..132], h.eh_offset, .little);
    std.mem.writeInt(u32, buf[132..136], h.eh_size, .little);
}

pub fn parseHeader(buf: []const u8) Error!CwasmHeader {
    if (buf.len < header_size) return Error.TruncatedHeader;
    if (!std.mem.eql(u8, buf[0..4], &magic)) return Error.BadMagic;
    const version = std.mem.readInt(u32, buf[4..8], .little);
    if (version != version_v0_5) return Error.UnsupportedVersion;
    const arch = std.mem.readInt(u32, buf[8..12], .little);
    if (arch != arch_arm64 and arch != arch_x86_64) return Error.UnknownArch;
    return .{
        .arch = arch,
        .flags = std.mem.readInt(u32, buf[12..16], .little),
        .n_funcs = std.mem.readInt(u32, buf[16..20], .little),
        .n_types = std.mem.readInt(u32, buf[20..24], .little),
        .n_imports = std.mem.readInt(u32, buf[24..28], .little),
        .code_offset = std.mem.readInt(u32, buf[28..32], .little),
        .code_size = std.mem.readInt(u32, buf[32..36], .little),
        .metadata_offset = std.mem.readInt(u32, buf[36..40], .little),
        .metadata_size = std.mem.readInt(u32, buf[40..44], .little),
        .types_offset = std.mem.readInt(u32, buf[44..48], .little),
        .types_size = std.mem.readInt(u32, buf[48..52], .little),
        .relocs_offset = std.mem.readInt(u32, buf[52..56], .little),
        .relocs_size = std.mem.readInt(u32, buf[56..60], .little),
        .exports_offset = std.mem.readInt(u32, buf[60..64], .little),
        .exports_size = std.mem.readInt(u32, buf[64..68], .little),
        .globals_offset = std.mem.readInt(u32, buf[68..72], .little),
        .globals_size = std.mem.readInt(u32, buf[72..76], .little),
        .memory_min_pages = std.mem.readInt(u32, buf[76..80], .little),
        .memory_max_pages = std.mem.readInt(u32, buf[80..84], .little),
        .memory_init_offset = std.mem.readInt(u32, buf[84..88], .little),
        .memory_init_size = std.mem.readInt(u32, buf[88..92], .little),
        .table0_size = std.mem.readInt(u32, buf[92..96], .little),
        .elem_offset = std.mem.readInt(u32, buf[96..100], .little),
        .elem_size = std.mem.readInt(u32, buf[100..104], .little),
        .imports_offset = std.mem.readInt(u32, buf[104..108], .little),
        .imports_size = std.mem.readInt(u32, buf[108..112], .little),
        .wasm_bytes_offset = std.mem.readInt(u32, buf[112..116], .little),
        .wasm_bytes_size = std.mem.readInt(u32, buf[116..120], .little),
        .func_extras_offset = std.mem.readInt(u32, buf[120..124], .little),
        .func_extras_size = std.mem.readInt(u32, buf[124..128], .little),
        .eh_offset = std.mem.readInt(u32, buf[128..132], .little),
        .eh_size = std.mem.readInt(u32, buf[132..136], .little),
    };
}

// =====================================================================
// v0.5 per-func extras + exception-table entry serialisation (ADR-0203)
// =====================================================================

/// Per-DEFINED-func re-link inputs beyond v0.4's metadata (frame size and
/// the guard-fault oob stub offset, both body-relative compiler output).
pub const CwasmFuncExtra = struct {
    frame_bytes: u32,
    oob_stub_off: u32,
};

pub fn writeFuncExtra(buf: []u8, e: CwasmFuncExtra) Error!void {
    if (buf.len < func_extra_size) return Error.TruncatedFuncMeta;
    std.mem.writeInt(u32, buf[0..4], e.frame_bytes, .little);
    std.mem.writeInt(u32, buf[4..8], e.oob_stub_off, .little);
}

pub fn parseFuncExtra(buf: []const u8) Error!CwasmFuncExtra {
    if (buf.len < func_extra_size) return Error.TruncatedFuncMeta;
    return .{
        .frame_bytes = std.mem.readInt(u32, buf[0..4], .little),
        .oob_stub_off = std.mem.readInt(u32, buf[4..8], .little),
    };
}

/// One serialised module-level exception-table entry (mirrors
/// `exception_table.HandlerEntry`; pcs module-relative; `tag_idx` null is
/// encoded as `eh_tag_none`; `kind` is `@intFromEnum(CatchKind)`).
pub const CwasmEhEntry = struct {
    pc_start: u32,
    pc_end: u32,
    tag_idx: u32, // eh_tag_none = null (catch_all/_ref)
    landing_pad_pc: u32,
    kind: u8,
};

pub fn writeEhEntry(buf: []u8, e: CwasmEhEntry) Error!void {
    if (buf.len < eh_entry_size) return Error.TruncatedEhEntry;
    std.mem.writeInt(u32, buf[0..4], e.pc_start, .little);
    std.mem.writeInt(u32, buf[4..8], e.pc_end, .little);
    std.mem.writeInt(u32, buf[8..12], e.tag_idx, .little);
    std.mem.writeInt(u32, buf[12..16], e.landing_pad_pc, .little);
    buf[16] = e.kind;
}

pub fn parseEhEntry(buf: []const u8) Error!CwasmEhEntry {
    if (buf.len < eh_entry_size) return Error.TruncatedEhEntry;
    return .{
        .pc_start = std.mem.readInt(u32, buf[0..4], .little),
        .pc_end = std.mem.readInt(u32, buf[4..8], .little),
        .tag_idx = std.mem.readInt(u32, buf[8..12], .little),
        .landing_pad_pc = std.mem.readInt(u32, buf[12..16], .little),
        .kind = buf[16],
    };
}

// =====================================================================
// Exports section serialisation (v0.2 per ADR-0138)
// =====================================================================
//
// Layout: [n_exports: u32] then n_exports entries, each
//   [name_len: u32][name: name_len bytes][func_idx: u32].

/// Serialised byte size of one export entry.
pub fn exportEntrySize(name_len: usize) usize {
    return 4 + name_len + 4;
}

/// Write one export entry at the start of `buf`; returns bytes written.
pub fn writeExportEntry(buf: []u8, e: CwasmExport) Error!usize {
    const need = exportEntrySize(e.name.len);
    if (buf.len < need) return Error.TruncatedExport;
    std.mem.writeInt(u32, buf[0..4], @intCast(e.name.len), .little);
    @memcpy(buf[4..][0..e.name.len], e.name);
    std.mem.writeInt(u32, buf[4 + e.name.len ..][0..4], e.func_idx, .little);
    return need;
}

/// Parse one export entry at the start of `buf`. The returned `name`
/// aliases into `buf`. `consumed` is the entry's byte length.
pub fn parseExportEntry(buf: []const u8) Error!struct { exp: CwasmExport, consumed: usize } {
    if (buf.len < 8) return Error.TruncatedExport; // name_len + func_idx minimum
    const name_len = std.mem.readInt(u32, buf[0..4], .little);
    const need = exportEntrySize(name_len);
    if (buf.len < need) return Error.TruncatedExport;
    return .{
        .exp = .{
            .name = buf[4..][0..name_len],
            .func_idx = std.mem.readInt(u32, buf[4 + name_len ..][0..4], .little),
        },
        .consumed = need,
    };
}

// =====================================================================
// Imports-metadata section serialisation (v0.4 per D-251 AOT-WASI)
// =====================================================================
//
// Layout: [n_imports: u32] then n_imports entries, each
//   [module_len: u32][module: bytes][name_len: u32][name: bytes][kind: u8].

/// Serialised byte size of one import entry.
pub fn importEntrySize(module_len: usize, name_len: usize) usize {
    return 4 + module_len + 4 + name_len + 1;
}

/// Write one import entry at the start of `buf`; returns bytes written.
pub fn writeImportEntry(buf: []u8, imp: CwasmImport) Error!usize {
    const need = importEntrySize(imp.module.len, imp.name.len);
    if (buf.len < need) return Error.TruncatedImportEntry;
    std.mem.writeInt(u32, buf[0..4], @intCast(imp.module.len), .little);
    @memcpy(buf[4..][0..imp.module.len], imp.module);
    var cur: usize = 4 + imp.module.len;
    std.mem.writeInt(u32, buf[cur..][0..4], @intCast(imp.name.len), .little);
    cur += 4;
    @memcpy(buf[cur..][0..imp.name.len], imp.name);
    cur += imp.name.len;
    buf[cur] = imp.kind;
    return need;
}

/// Parse one import entry at the start of `buf`. The returned
/// `module`/`name` alias into `buf`. `consumed` is the entry's byte length.
pub fn parseImportEntry(buf: []const u8) Error!struct { imp: CwasmImport, consumed: usize } {
    if (buf.len < 4) return Error.TruncatedImportEntry;
    const module_len = std.mem.readInt(u32, buf[0..4], .little);
    if (@as(u64, 4) + module_len + 4 > buf.len) return Error.TruncatedImportEntry;
    const name_at: usize = 4 + module_len;
    const name_len = std.mem.readInt(u32, buf[name_at..][0..4], .little);
    const need = importEntrySize(module_len, name_len);
    if (buf.len < need) return Error.TruncatedImportEntry;
    return .{
        .imp = .{
            .module = buf[4..][0..module_len],
            .name = buf[name_at + 4 ..][0..name_len],
            .kind = buf[need - 1],
        },
        .consumed = need,
    };
}

// =====================================================================
// Per-func metadata serialisation
// =====================================================================

pub fn writeFuncMeta(buf: []u8, m: CwasmFuncMeta) Error!void {
    if (buf.len < func_meta_size) return Error.TruncatedFuncMeta;
    std.mem.writeInt(u32, buf[0..4], m.code_offset, .little);
    std.mem.writeInt(u32, buf[4..8], m.code_size, .little);
    std.mem.writeInt(u16, buf[8..10], m.n_slots, .little);
    std.mem.writeInt(u16, buf[10..12], m.sig_idx, .little);
    std.mem.writeInt(u32, buf[12..16], m.canon_typeidx, .little);
}

pub fn parseFuncMeta(buf: []const u8) Error!CwasmFuncMeta {
    if (buf.len < func_meta_size) return Error.TruncatedFuncMeta;
    return .{
        .code_offset = std.mem.readInt(u32, buf[0..4], .little),
        .code_size = std.mem.readInt(u32, buf[4..8], .little),
        .n_slots = std.mem.readInt(u16, buf[8..10], .little),
        .sig_idx = std.mem.readInt(u16, buf[10..12], .little),
        .canon_typeidx = std.mem.readInt(u32, buf[12..16], .little),
    };
}

// =====================================================================
// Reloc serialisation
// =====================================================================

pub fn writeReloc(buf: []u8, r: CwasmReloc) Error!void {
    if (buf.len < reloc_size) return Error.TruncatedReloc;
    std.mem.writeInt(u32, buf[0..4], r.code_offset, .little);
    std.mem.writeInt(u32, buf[4..8], r.target_func_idx, .little);
    buf[8] = r.kind;
}

pub fn parseReloc(buf: []const u8) Error!CwasmReloc {
    if (buf.len < reloc_size) return Error.TruncatedReloc;
    return .{
        .code_offset = std.mem.readInt(u32, buf[0..4], .little),
        .target_func_idx = std.mem.readInt(u32, buf[4..8], .little),
        .kind = buf[8],
    };
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "writeHeader/parseHeader: round-trip preserves all fields" {
    const want: CwasmHeader = .{
        .arch = arch_arm64,
        .flags = flag_has_memory | flag_has_table | flag_bounds_elided,
        .n_funcs = 3,
        .n_types = 2,
        .n_imports = 1,
        .code_offset = 200,
        .code_size = 300,
        .metadata_offset = 60,
        .metadata_size = 36,
        .types_offset = 96,
        .types_size = 50,
        .relocs_offset = 146,
        .relocs_size = 27,
        .exports_offset = 173,
        .exports_size = 19,
        .globals_offset = 192,
        .globals_size = 32,
        .memory_min_pages = 2,
        .memory_max_pages = memory_max_none,
        .memory_init_offset = 224,
        .memory_init_size = 40,
        .table0_size = 3,
        .elem_offset = 264,
        .elem_size = 24,
        .imports_offset = 288,
        .imports_size = 35,
        .wasm_bytes_offset = 323,
        .wasm_bytes_size = 512,
        .func_extras_offset = 835,
        .func_extras_size = 24,
        .eh_offset = 859,
        .eh_size = 4 + 2 * eh_entry_size,
    };
    var buf: [header_size]u8 = undefined;
    try writeHeader(&buf, want);
    const got = try parseHeader(&buf);
    try testing.expectEqual(want, got);
}

test "writeHeader/parseHeader: arch_x86_64 round-trips" {
    const want: CwasmHeader = .{
        .arch = arch_x86_64,
        .n_funcs = 1,
        .n_types = 1,
        .n_imports = 0,
        .code_offset = 60,
        .code_size = 16,
        .metadata_offset = 76,
        .metadata_size = 12,
        .types_offset = 88,
        .types_size = 4,
        .relocs_offset = 92,
        .relocs_size = 0,
    };
    var buf: [header_size]u8 = undefined;
    try writeHeader(&buf, want);
    const got = try parseHeader(&buf);
    try testing.expectEqual(want, got);
}

test "parseHeader: rejects bad magic" {
    var buf: [header_size]u8 = undefined;
    @memset(&buf, 0xAA);
    try testing.expectError(Error.BadMagic, parseHeader(&buf));
}

test "parseHeader: rejects unsupported version" {
    var buf: [header_size]u8 = undefined;
    @memcpy(buf[0..4], &magic);
    std.mem.writeInt(u32, buf[4..8], 0x0006_0000, .little); // v0.6 (future, unsupported)
    @memset(buf[8..], 0);
    try testing.expectError(Error.UnsupportedVersion, parseHeader(&buf));
}

test "parseHeader: rejects the superseded v0.1 / v0.2 / v0.3 / v0.4 versions" {
    var buf: [header_size]u8 = undefined;
    @memcpy(buf[0..4], &magic);
    @memset(buf[8..], 0);
    std.mem.writeInt(u32, buf[4..8], version_v0_1, .little);
    try testing.expectError(Error.UnsupportedVersion, parseHeader(&buf));
    std.mem.writeInt(u32, buf[4..8], version_v0_2, .little);
    try testing.expectError(Error.UnsupportedVersion, parseHeader(&buf));
    std.mem.writeInt(u32, buf[4..8], version_v0_3, .little);
    try testing.expectError(Error.UnsupportedVersion, parseHeader(&buf));
    // v0.4 lacks the embedded-wasm_bytes / func-extras / eh sections the
    // full-fidelity loader requires — a stale artifact is a clean
    // regenerate, never a partial read (ADR-0203 D3).
    std.mem.writeInt(u32, buf[4..8], version_v0_4, .little);
    try testing.expectError(Error.UnsupportedVersion, parseHeader(&buf));
}

test "writeFuncExtra/parseFuncExtra + writeEhEntry/parseEhEntry: round-trip" {
    var xbuf: [func_extra_size]u8 = undefined;
    const xe = CwasmFuncExtra{ .frame_bytes = 0x120, .oob_stub_off = 0xFFFF_FFFF };
    try writeFuncExtra(&xbuf, xe);
    try testing.expectEqual(xe, try parseFuncExtra(&xbuf));

    var ebuf: [eh_entry_size]u8 = undefined;
    const ee = CwasmEhEntry{
        .pc_start = 0x40,
        .pc_end = 0x80,
        .tag_idx = eh_tag_none,
        .landing_pad_pc = 0x7C,
        .kind = 2,
    };
    try writeEhEntry(&ebuf, ee);
    try testing.expectEqual(ee, try parseEhEntry(&ebuf));
}

test "parseHeader: rejects unknown arch" {
    var buf: [header_size]u8 = undefined;
    @memcpy(buf[0..4], &magic);
    std.mem.writeInt(u32, buf[4..8], version_v0_5, .little);
    std.mem.writeInt(u32, buf[8..12], 99, .little); // unknown arch
    @memset(buf[12..], 0);
    try testing.expectError(Error.UnknownArch, parseHeader(&buf));
}

test "parseHeader: rejects truncated buffer" {
    var buf: [header_size - 1]u8 = undefined;
    try testing.expectError(Error.TruncatedHeader, parseHeader(&buf));
}

test "writeFuncMeta/parseFuncMeta: round-trip preserves all fields" {
    const want: CwasmFuncMeta = .{
        .code_offset = 0x1234_5678,
        .code_size = 0x0042_0000,
        .n_slots = 7,
        .sig_idx = 2,
        .canon_typeidx = 0x00AB_CDEF,
    };
    var buf: [func_meta_size]u8 = undefined;
    try writeFuncMeta(&buf, want);
    const got = try parseFuncMeta(&buf);
    try testing.expectEqual(want, got);
}

test "parseFuncMeta: rejects truncated buffer" {
    var buf: [func_meta_size - 1]u8 = undefined;
    try testing.expectError(Error.TruncatedFuncMeta, parseFuncMeta(&buf));
}

test "writeReloc/parseReloc: round-trip preserves all fields" {
    const want: CwasmReloc = .{
        .code_offset = 64,
        .target_func_idx = 3,
        .kind = reloc_kind_direct_call,
    };
    var buf: [reloc_size]u8 = undefined;
    try writeReloc(&buf, want);
    const got = try parseReloc(&buf);
    try testing.expectEqual(want, got);
}

test "parseReloc: rejects truncated buffer" {
    var buf: [reloc_size - 1]u8 = undefined;
    try testing.expectError(Error.TruncatedReloc, parseReloc(&buf));
}

test "header_size + func_meta_size + reloc_size constants are stable" {
    try testing.expectEqual(@as(u32, 136), header_size); // v0.5 (ADR-0203 stage 2)
    try testing.expectEqual(@as(u32, 16), func_meta_size);
    try testing.expectEqual(@as(u32, 9), reloc_size);
    try testing.expectEqual(@as(u32, 8), func_extra_size);
    try testing.expectEqual(@as(u32, 17), eh_entry_size);
}

test "writeExportEntry/parseExportEntry: round-trip preserves name + func_idx" {
    const want: CwasmExport = .{ .name = "_start", .func_idx = 3 };
    var buf: [64]u8 = undefined;
    const written = try writeExportEntry(&buf, want);
    try testing.expectEqual(exportEntrySize(want.name.len), written);

    const got = try parseExportEntry(buf[0..written]);
    try testing.expectEqual(written, got.consumed);
    try testing.expectEqualStrings(want.name, got.exp.name);
    try testing.expectEqual(want.func_idx, got.exp.func_idx);
}

test "parseExportEntry: rejects a buffer truncated mid-name" {
    var buf: [64]u8 = undefined;
    _ = try writeExportEntry(&buf, .{ .name = "main", .func_idx = 0 });
    // Lop off the trailing func_idx + one name byte.
    try testing.expectError(Error.TruncatedExport, parseExportEntry(buf[0..6]));
}

test "writeImportEntry/parseImportEntry: round-trip preserves module + name + kind (v0.4)" {
    const want: CwasmImport = .{ .module = "wasi_snapshot_preview1", .name = "fd_write", .kind = 0x00 };
    var buf: [64]u8 = undefined;
    const written = try writeImportEntry(&buf, want);
    try testing.expectEqual(importEntrySize(want.module.len, want.name.len), written);

    const got = try parseImportEntry(buf[0..written]);
    try testing.expectEqual(written, got.consumed);
    try testing.expectEqualStrings(want.module, got.imp.module);
    try testing.expectEqualStrings(want.name, got.imp.name);
    try testing.expectEqual(want.kind, got.imp.kind);
}

test "parseImportEntry: rejects a buffer truncated mid-name" {
    var buf: [64]u8 = undefined;
    const n = try writeImportEntry(&buf, .{ .module = "env", .name = "memory", .kind = 0x02 });
    // Drop the trailing kind byte + part of the name.
    try testing.expectError(Error.TruncatedImportEntry, parseImportEntry(buf[0 .. n - 3]));
}
