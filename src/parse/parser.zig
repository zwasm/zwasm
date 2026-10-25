//! Wasm binary module **header + section iterator** (Phase 1 / §9.1 / 1.4).
//!
//! Validates magic + version, then walks the section sequence, returning
//! a `Module` struct that borrows raw section bodies from the input.
//! Per ROADMAP §P3 (cold-start) and §P6 (single-pass), no per-section
//! body decoding happens here — that lives in 1.5 (validator) / 1.6
//! (lowerer). The parser allocates only the `sections` list.
//!
//! Wasm 1.0 spec §5.5 mandates a strict order for known section ids
//! (1..=11). The bulk-memory data-count section (id 12) appears between
//! import (2) and code (10) when present. Custom sections (id 0) may
//! appear anywhere and any number of times. Tag section (id 13,
//! exception handling) is reserved for Phase 1.5+ — currently rejected
//! as an unknown id.
//!
//! Zone 1 (`src/frontend/`) — may import Zone 0 (`src/support/leb128.zig`)
//! and Zone 1 (`src/ir/`). No upward imports.

const std = @import("std");

const leb128 = @import("../support/leb128.zig");
const module_mod = @import("../runtime/module.zig");
const needs_heap_detector = @import("../feature/gc/needs_heap_detector.zig");
const diagnostic = @import("../diagnostic/diagnostic.zig");

const Allocator = std.mem.Allocator;
const Module = module_mod.Module;

pub const MAGIC = [4]u8{ 0x00, 0x61, 0x73, 0x6d };
pub const VERSION: u32 = 1;

pub const SectionId = enum(u8) {
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
    data_count = 12,
    /// Wasm 3.0 exception-handling proposal (§4.5 binary format):
    /// the tag section declares exception tags + their typeidx
    /// payload signatures. Per the proposal binary format, the
    /// section appears between memory (5) and global (6) in the
    /// canonical section order. This file currently accepts the
    /// section's bytes and stores it on `Module.sections`; entry
    /// decoding lands per 10.E-N sub-chunks.
    tag = 13,
    _,
};

pub const Section = struct {
    id: SectionId,
    body: []const u8,
};

pub const Error = error{
    TruncatedHeader,
    InvalidMagic,
    UnsupportedVersion,
    UnknownSectionId,
    SectionTooLarge,
    SectionOutOfOrder,
    DuplicateSection,
    OutOfMemory,
} || leb128.Error;

/// Parse the magic/version header and the section sequence.
/// Section bodies are borrowed slices of `input`; the caller must keep
/// `input` alive for as long as the returned `Module` is used.
pub fn parse(alloc: Allocator, input: []const u8) Error!Module {
    if (input.len < 8) {
        diagnostic.setDiag(.parse, .other, .unknown, "truncated module header: need 8 bytes for magic+version, got {d}", .{input.len});
        return Error.TruncatedHeader;
    }
    if (!std.mem.eql(u8, input[0..4], &MAGIC)) {
        diagnostic.setDiag(.parse, .other, .unknown, "invalid magic bytes at offset 0x0 (expected 00 61 73 6d '\\0asm')", .{});
        return Error.InvalidMagic;
    }
    const version = std.mem.readInt(u32, input[4..8], .little);
    if (version != VERSION) {
        diagnostic.setDiag(.parse, .other, .unknown, "unsupported binary version {d} at offset 0x4 (expected {d})", .{ version, VERSION });
        return Error.UnsupportedVersion;
    }

    var sections: std.ArrayList(Section) = .empty;
    errdefer sections.deinit(alloc);

    var pos: usize = 8;
    var last_known_order: u8 = 0;
    var seen: [14]bool = @splat(false);

    while (pos < input.len) {
        const section_start = pos;
        const id_byte = input[pos];
        pos += 1;
        const size = try leb128.readUleb128(u32, input, &pos);
        const size_usize: usize = @intCast(size);
        if (size_usize > input.len - pos) {
            diagnostic.setDiag(.parse, .other, .unknown, "section (id {d}) size {d} exceeds remaining input at offset 0x{x}", .{ id_byte, size_usize, section_start });
            return Error.SectionTooLarge;
        }
        const body = input[pos .. pos + size_usize];
        pos += size_usize;

        if (id_byte == 0) {
            // Wasm spec §5.5.4: a custom section body must start
            // with a LEB128-prefixed UTF-8 name. The name LEB
            // itself must be canonical (no over-long encoding,
            // no overflow). §9.9 / 9.9-l-1b-d093-d84 drains
            // custom.{4,5} (name LEB missing / truncated) and
            // binary-leb128.{30,55} (name LEB over-long /
            // overflow).
            var cpos: usize = 0;
            const name_len = try leb128.readUleb128(u32, body, &cpos);
            if (name_len > body.len - cpos) {
                diagnostic.setDiag(.parse, .other, .unknown, "custom section name length {d} exceeds section body at offset 0x{x}", .{ name_len, section_start });
                return Error.SectionTooLarge;
            }
            try sections.append(alloc, .{ .id = .custom, .body = body });
            continue;
        }
        if (id_byte > 13) {
            diagnostic.setDiag(.parse, .other, .unknown, "unknown section id {d} at offset 0x{x} (valid: 0-13)", .{ id_byte, section_start });
            return Error.UnknownSectionId;
        }

        if (seen[id_byte]) {
            diagnostic.setDiag(.parse, .other, .unknown, "duplicate section id {d} at offset 0x{x}", .{ id_byte, section_start });
            return Error.DuplicateSection;
        }
        seen[id_byte] = true;

        const ord = orderIndex(id_byte);
        if (ord <= last_known_order) {
            diagnostic.setDiag(.parse, .other, .unknown, "section id {d} out of order at offset 0x{x} (Wasm §5.5 ordering)", .{ id_byte, section_start });
            return Error.SectionOutOfOrder;
        }
        last_known_order = ord;

        try sections.append(alloc, .{ .id = @fromBackingInt(@intCast(id_byte)), .body = body });
    }

    var module = Module{ .input = input, .sections = sections };
    // 10.G-foundation cycle 2 (ADR-0115 §1 + D2) — populate the
    // parse-time GC predicate. Detector is byte-level + false-
    // positive-tolerant (over-counts an empty heap walk at
    // instantiate, never breaks correctness). When false, GC
    // heap + collector vtable + root walk all skip.
    module.needs_gc_heap = needs_heap_detector.detectNeedsGcHeap(&module);
    return module;
}

/// Wasm 1.0 §5.5 declares the order:
///   type(1), import(2), function(3), table(4), memory(5), global(6),
///   export(7), start(8), element(9), code(10), data(11)
/// Bulk-memory adds data_count(12) which sits between **element(9)
/// and code(10)** per the Bulk Memory Operations proposal §3.4
/// (the section was inserted at that position so producers can
/// declare data segment count before parsing code that references
/// it via `memory.init` / `data.drop`). TinyGo emits data_count
/// at this position; an earlier mistaken placement between import
/// and function rejected those modules with `SectionOutOfOrder`.
/// Wasm 3.0 exception-handling proposal §4.5 adds tag(13) between
/// memory(5) and global(6).
/// Returns 0 for unknown ids; callers must reject those before calling.
fn orderIndex(id: u8) u8 {
    return switch (id) {
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 5,
        13 => 6, // tag (Wasm 3.0 EH; between memory and global)
        6 => 7,
        7 => 8,
        8 => 9,
        9 => 10,
        12 => 11,
        10 => 12,
        11 => 13,
        else => 0,
    };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const empty_module_bytes = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x01, 0x00, 0x00, 0x00, // version 1
};

test "parse: empty MVP module (header only)" {
    var m = try parse(testing.allocator, &empty_module_bytes);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), m.sections.items.len);
    try testing.expectEqual(@as(usize, 8), m.input.len);
}

test "parse: GC abstract heap reftypes in imported table + element ref.null are accepted (fuzz-found gap)" {
    // (import "e" "t" (table 1 anyref)) (elem structref (ref.null struct)).
    // Both the imported-table elem_type parser (sections.zig) and the element
    // ref.null heaptype reader (sections_element.zig) hardcoded a funcref/
    // externref-only switch, wrongly rejecting valid Wasm 3.0 GC modules with
    // "module decode/validate failed" (wasm-tools accepts them). Both now route
    // through the shared reftype reader. wasm-tools-validated 51-byte module.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x02, 0x09, 0x01, 0x01, 0x65, 0x01, 0x74, 0x01, 0x6e, 0x00, 0x01, 0x03, 0x02, 0x01,
        0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x09, 0x07, 0x01, 0x05, 0x6b, 0x01,
        0xd0, 0x6b, 0x0b, 0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };
    var m = try parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
}

test "parse: element-segment items global.get + concrete typed-ref accepted (D-476, fuzz-found)" {
    // (elem funcref (global.get $g)) + (elem (ref null $t) (ref.null $t)). The
    // element-item reader rejected a global.get-marker in the funcidx-range
    // check (interp validator, out of sync with the JIT) and a `ref.null $t`
    // CONCRETE typeidx (readValType only handled abstract heads). Both fixed:
    // the funcidx-range loop skips the global.get marker, and the 0xD0 reader
    // routes through readTypedRef (abstract head OR concrete s33 index).
    // wasm-tools-validated 84-byte module; instantiates on both engines.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x03, 0x02, 0x00, 0x00, 0x06, 0x06, 0x01, 0x70, 0x00, 0xd2, 0x00, 0x0b, 0x07,
        0x05, 0x01, 0x01, 0x66, 0x00, 0x01, 0x09, 0x0e, 0x02, 0x05, 0x70, 0x01, 0x23, 0x00,
        0x0b, 0x05, 0x63, 0x00, 0x01, 0xd0, 0x00, 0x0b, 0x0a, 0x07, 0x02, 0x02, 0x00, 0x0b,
        0x02, 0x00, 0x0b, 0x00, 0x17, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01, 0x04, 0x01, 0x00,
        0x01, 0x61, 0x04, 0x04, 0x01, 0x00, 0x01, 0x74, 0x07, 0x04, 0x01, 0x00, 0x01, 0x67,
    };
    var m = try parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
}

test "parse: needs_gc_heap flag set true when type section declares struct (10.G-foundation cycle 2; ADR-0115 §1)" {
    // Wire test: parser runs needs_heap_detector at the end of
    // parse() so Module.needs_gc_heap reflects the module's
    // actual GC-type usage. Struct-tag byte 0x5F in type section
    // body flips the flag.
    const bytes = empty_module_bytes ++ [_]u8{ 0x01, 0x03, 0x01, 0x5F, 0x00 };
    var m = try parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(true, m.needs_gc_heap);
}

test "parse: needs_gc_heap stays false for non-GC module (clean i32 functype)" {
    // type section: count=1, (i32) -> (i32). No GC bytes anywhere.
    const bytes = empty_module_bytes ++ [_]u8{ 0x01, 0x06, 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F };
    var m = try parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(false, m.needs_gc_heap);
}

test "parse: rejects truncated header" {
    const r = parse(testing.allocator, &[_]u8{ 0x00, 0x61, 0x73, 0x6d });
    try testing.expectError(Error.TruncatedHeader, r);
}

test "parse: rejects bad magic" {
    const bad = [_]u8{
        0x00, 0x61, 0x73, 0x6e, // magic last byte wrong
        0x01, 0x00, 0x00, 0x00,
    };
    try testing.expectError(Error.InvalidMagic, parse(testing.allocator, &bad));
}

test "parse: F6 — reject sites populate a parse diagnostic with byte offset" {
    // bad magic → parse-phase diagnostic, no longer a bare @errorName.
    diagnostic.clearDiag();
    const bad_magic = [_]u8{ 0x00, 0x61, 0x73, 0x6e, 0x01, 0x00, 0x00, 0x00 };
    try testing.expectError(Error.InvalidMagic, parse(testing.allocator, &bad_magic));
    const d1 = diagnostic.lastDiagnostic().?;
    try testing.expectEqual(diagnostic.Phase.parse, d1.phase);
    try testing.expect(std.mem.find(u8, d1.message(), "invalid magic") != null);

    // unknown section id 99 sits at byte offset 0x8 (right after the 8-byte header).
    diagnostic.clearDiag();
    const bad_sec = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 99, 0x00 };
    try testing.expectError(Error.UnknownSectionId, parse(testing.allocator, &bad_sec));
    const d2 = diagnostic.lastDiagnostic().?;
    try testing.expect(std.mem.find(u8, d2.message(), "unknown section id 99") != null);
    try testing.expect(std.mem.find(u8, d2.message(), "0x8") != null);
}

test "parse: rejects bad version (0)" {
    const bad = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x00, 0x00, 0x00, 0x00,
    };
    try testing.expectError(Error.UnsupportedVersion, parse(testing.allocator, &bad));
}

test "parse: rejects bad version (2)" {
    const bad = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x02, 0x00, 0x00, 0x00,
    };
    try testing.expectError(Error.UnsupportedVersion, parse(testing.allocator, &bad));
}

test "parse: iterates two known sections in order (type, function)" {
    // type section (id=1, body 0x60 -> empty type vec disguised as size=1 byte 0x00)
    // For 1.4 we don't validate body contents, so any 1-byte payload works.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x01, 0x00, // section id=1 (type), size=1, body=0x00
        0x03, 0x02, 0xAA, 0xBB, // section id=3 (function), size=2, body=0xAA 0xBB
    };
    var m = try parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), m.sections.items.len);
    try testing.expectEqual(SectionId.type, m.sections.items[0].id);
    try testing.expectEqual(@as(usize, 1), m.sections.items[0].body.len);
    try testing.expectEqual(@as(u8, 0x00), m.sections.items[0].body[0]);
    try testing.expectEqual(SectionId.function, m.sections.items[1].id);
    try testing.expectEqual(@as(usize, 2), m.sections.items[1].body.len);
    try testing.expectEqual(@as(u8, 0xBB), m.sections.items[1].body[1]);
}

test "parse: rejects out-of-order known sections (function before type)" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x03, 0x00, // function (3) first
        0x01, 0x00, // then type (1)
    };
    try testing.expectError(Error.SectionOutOfOrder, parse(testing.allocator, &bytes));
}

test "parse: rejects duplicate known section" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x00, // type (empty)
        0x01, 0x00, // type again
    };
    try testing.expectError(Error.DuplicateSection, parse(testing.allocator, &bytes));
}

test "parse: data_count slots between import and code" {
    // import(2), data_count(12), code(10), data(11)
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x02, 0x00, // import
        0x0c, 0x00, // data_count
        0x0a, 0x00, // code
        0x0b, 0x00, // data
    };
    var m = try parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), m.sections.items.len);
    try testing.expectEqual(SectionId.import, m.sections.items[0].id);
    try testing.expectEqual(SectionId.data_count, m.sections.items[1].id);
    try testing.expectEqual(SectionId.code, m.sections.items[2].id);
    try testing.expectEqual(SectionId.data, m.sections.items[3].id);
}

test "parse: rejects data_count after code (out of order)" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x0a, 0x00, // code
        0x0c, 0x00, // data_count after code — illegal
    };
    try testing.expectError(Error.SectionOutOfOrder, parse(testing.allocator, &bytes));
}

test "parse: custom sections allowed anywhere; do not affect ordering" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x02, 0x00, 0xff, // custom before type (empty name, 1-byte content)
        0x01, 0x00, // type
        0x00, 0x01, 0x00, // custom (empty name, no content) between sections
        0x03, 0x00, // function
        0x00, 0x03, 0x00, 0xaa, 0xbb, // custom after function (empty name, 2-byte content)
    };
    var m = try parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), m.sections.items.len);
    try testing.expectEqual(@as(usize, 3), m.countCustom());
    try testing.expect(m.find(.type) != null);
    try testing.expect(m.find(.function) != null);
}

test "parse: rejects unknown section id" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x0e, 0x00, // id=14 (not yet defined)
    };
    try testing.expectError(Error.UnknownSectionId, parse(testing.allocator, &bytes));
}

test "parse: accepts tag section (id=13; Wasm 3.0 EH §4.5)" {
    // Empty tag section (count=0); body decoding lands per 10.E-N.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x0d, 0x01, 0x00, // id=13 (tag), size=1, body=[count=0]
    };
    var m = try parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), m.sections.items.len);
    try testing.expectEqual(SectionId.tag, m.sections.items[0].id);
}

test "parse: tag section ordering — memory(5) before tag(13) before global(6)" {
    // Canonical Wasm 3.0 EH §4.5 ordering. Three sections in id-byte
    // order 5 / 13 / 6 — orderIndex maps these to ord 5 / 6 / 7,
    // which is strictly ascending and parses cleanly.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x01, 0x00, // memory section (count=0)
        0x0d, 0x01, 0x00, // tag section (count=0)
        0x06, 0x01, 0x00, // global section (count=0)
    };
    var m = try parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), m.sections.items.len);
    try testing.expectEqual(SectionId.memory, m.sections.items[0].id);
    try testing.expectEqual(SectionId.tag, m.sections.items[1].id);
    try testing.expectEqual(SectionId.global, m.sections.items[2].id);
}

test "parse: tag section out of order — global(6) before tag(13) fails" {
    // Reverse: global(6) appears before tag(13). orderIndex maps
    // global to ord 7 and tag to ord 6 — non-ascending → reject.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x06, 0x01, 0x00, // global section (count=0)
        0x0d, 0x01, 0x00, // tag section (count=0) — out of order
    };
    try testing.expectError(Error.SectionOutOfOrder, parse(testing.allocator, &bytes));
}

test "parse: rejects section size that overruns input" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0xaa, 0xbb, // claims size=5 but only 2 bytes follow
    };
    try testing.expectError(Error.SectionTooLarge, parse(testing.allocator, &bytes));
}

test "parse: rejects truncated leb128 size" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x80, // size byte with continuation but no follow-up
    };
    try testing.expectError(leb128.Error.Truncated, parse(testing.allocator, &bytes));
}

test "Module.find / countCustom on empty module" {
    var m = try parse(testing.allocator, &empty_module_bytes);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(?Section, null), m.find(.type));
    try testing.expectEqual(@as(usize, 0), m.countCustom());
}

test "SectionId enum tags match Wasm spec ids" {
    try testing.expectEqual(@as(u8, 0), @backingInt(SectionId.custom));
    try testing.expectEqual(@as(u8, 1), @backingInt(SectionId.type));
    try testing.expectEqual(@as(u8, 7), @backingInt(SectionId.@"export"));
    try testing.expectEqual(@as(u8, 11), @backingInt(SectionId.data));
    try testing.expectEqual(@as(u8, 12), @backingInt(SectionId.data_count));
    try testing.expectEqual(@as(u8, 13), @backingInt(SectionId.tag));
}
