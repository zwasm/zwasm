//! Component binary **discriminator + top-level section walk** (CM campaign
//! chunk A1; spec `component-model/design/mvp/Binary.md`).
//!
//! The Component Model defines a *second* binary format that shares the
//! `\0asm` magic with a core module but reinterprets the 4 bytes after the
//! magic as a `version:u16` + `layer:u16` pair: `layer == 0` is a core module
//! (with `version == 1`), `layer == 1` is a component (current pre-standard
//! `version == 0x0d`). This module discriminates the two and, for a component,
//! enumerates its top-level sections WITHOUT interpreting their bodies —
//! mirroring the core parser's header+section-iterator split
//! (`parse/parser.zig`); body decoding lands in later chunks (A2+).
//!
//! DIVERGENCE from the core section walk: component sections are NEITHER
//! strictly ordered NOR unique (e.g. multiple `core-module`, `type`, or
//! `component` sections are valid — `Binary.md` `section*`). So there is no
//! order/duplicate check here, unlike `parse/parser.zig`.
//!
//! Zone-2 new layer (ADR-0170 / `component_model_survey`): consumes the core
//! runtime as a black box and never alters it. The component-level value model
//! is kept DISTINCT from `runtime.Value` (`single_slot_dual_meaning`); A1
//! introduces no value type yet (decode only). Gated on `wasi_level >= .p2`
//! (ADR-0193 folded the former `-Dcomponent` flag into the `-Dwasi` axis).

const std = @import("std");

const leb128 = @import("../../support/leb128.zig");

const Allocator = std.mem.Allocator;

/// Shared with the core module preamble (`parse/parser.zig` `MAGIC`).
pub const MAGIC = [4]u8{ 0x00, 0x61, 0x73, 0x6d };

/// Pre-standard component `version` field. Per `Binary.md`, this is bumped
/// from `0x0d` upwards as the proposal evolves, then set to `0x1` at final
/// standardization (mirroring the Core Wasm 1.0 path). zwasm pins the current
/// prototype value and rejects others as unsupported.
pub const COMPONENT_VERSION: u16 = 0x000d;

/// `layer` discriminator: 0 = core module, 1 = component (`Binary.md`).
pub const LAYER_CORE: u16 = 0x0000;
pub const LAYER_COMPONENT: u16 = 0x0001;

/// Result of preamble discrimination.
pub const Kind = enum { core_module, component };

/// Component top-level section ids (`Binary.md` `section ::= section_0..12`).
/// The `core_*` variants embed core-binary sub-grammars; `component` nests a
/// whole child component.
pub const SectionId = enum(u8) {
    custom = 0,
    core_module = 1,
    core_instance = 2,
    core_type = 3,
    component = 4,
    instance = 5,
    alias = 6,
    type = 7,
    canon = 8,
    start = 9,
    import = 10,
    @"export" = 11,
    value = 12,
    _,
};

/// One top-level section; `body` is a borrowed slice of the decoded input.
pub const Section = struct {
    id: SectionId,
    body: []const u8,
};

/// A decoded component shell: the discriminated preamble plus its top-level
/// section list. Bodies are borrowed from `input`; the caller must keep
/// `input` alive while the `Component` is used.
pub const Component = struct {
    /// Borrowed input bytes. Section bodies — and the TypeInfo names that slice
    /// them (`decodeLabel`) — point into THIS, so the decoded component is only
    /// valid while `input` lives. A long-lived handle (`ComponentInstance` /
    /// `BuiltComponent`) therefore owns a copy of the bytes and decodes against
    /// it, decoupling the handle from the caller's buffer (REQ-7 / D-326).
    input: []const u8,
    sections: std.ArrayList(Section),

    pub fn deinit(self: *Component, alloc: Allocator) void {
        self.sections.deinit(alloc);
    }
};

pub const Error = error{
    TruncatedHeader,
    InvalidMagic,
    InvalidLayer,
    UnsupportedComponentVersion,
    NotAComponent,
    UnknownSectionId,
    SectionTooLarge,
    OutOfMemory,
} || leb128.Error;

/// Discriminate a core module from a component by the preamble `layer` field.
/// Both share `\0asm`; the next 4 bytes are `version:u16 LE` + `layer:u16 LE`.
fn readLayer(input: []const u8) Error!struct { version: u16, layer: u16 } {
    if (input.len < 8) return Error.TruncatedHeader;
    if (!std.mem.eql(u8, input[0..4], &MAGIC)) return Error.InvalidMagic;
    return .{
        .version = std.mem.readInt(u16, input[4..6], .little),
        .layer = std.mem.readInt(u16, input[6..8], .little),
    };
}

/// Classify a wasm preamble as a core module or a component. A component
/// preamble whose `version` is not the pinned prototype is rejected so a
/// future spec bump can't be silently mis-decoded.
pub fn classify(input: []const u8) Error!Kind {
    const pre = try readLayer(input);
    return switch (pre.layer) {
        LAYER_CORE => .core_module,
        LAYER_COMPONENT => if (pre.version == COMPONENT_VERSION)
            .component
        else
            Error.UnsupportedComponentVersion,
        else => Error.InvalidLayer,
    };
}

/// Decode the top-level section sequence of a component. Each section is
/// `id:u8 size:uleb128 body[size]` (same framing as a core section). Returns
/// `NotAComponent` if the preamble discriminates to a core module.
pub fn decode(alloc: Allocator, input: []const u8) Error!Component {
    if (try classify(input) != .component) return Error.NotAComponent;

    var sections: std.ArrayList(Section) = .empty;
    errdefer sections.deinit(alloc);

    var pos: usize = 8;
    while (pos < input.len) {
        const id_byte = input[pos];
        pos += 1;
        const size = try leb128.readUleb128(u32, input, &pos);
        const size_usize: usize = @intCast(size);
        if (size_usize > input.len - pos) return Error.SectionTooLarge;
        const body = input[pos .. pos + size_usize];
        pos += size_usize;

        if (id_byte > @backingInt(SectionId.value)) return Error.UnknownSectionId;
        try sections.append(alloc, .{ .id = @fromBackingInt(@intCast(id_byte)), .body = body });
    }

    return .{ .input = input, .sections = sections };
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

/// `wasm-tools component new`-shaped empty component preamble: magic +
/// version 0x0d + layer 0x01, no sections.
const empty_component = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // \0asm
    0x0d, 0x00, // version 0x0d
    0x01, 0x00, // layer 0x01 (component)
};

/// Core module preamble (version 1, layer 0): the no-op module.
const core_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // \0asm
    0x01, 0x00, 0x00, 0x00, // version 1 / layer 0
};

test "classify: layer field discriminates core module from component" {
    try testing.expectEqual(Kind.core_module, try classify(&core_module));
    try testing.expectEqual(Kind.component, try classify(&empty_component));
}

test "decode: empty component yields zero sections" {
    var comp = try decode(testing.allocator, &empty_component);
    defer comp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), comp.sections.items.len);
}

test "decode: enumerates the top-level sections of a component" {
    // Component with a custom section (id 0, name "x") and an empty type
    // section (id 7, count 0) — exercises id mapping + body borrowing.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, // \0asm
        0x0d, 0x00, 0x01, 0x00, // version 0x0d / layer 0x01
        0x00, 0x03, 0x01, 0x78, 0x00, // custom: size=3, name_len=1 "x", 1 trailing byte
        0x07, 0x01, 0x00, // type section: size=1, count=0
    };
    var comp = try decode(testing.allocator, &bytes);
    defer comp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), comp.sections.items.len);
    try testing.expectEqual(SectionId.custom, comp.sections.items[0].id);
    try testing.expectEqual(SectionId.type, comp.sections.items[1].id);
    try testing.expectEqual(@as(usize, 3), comp.sections.items[0].body.len);
    try testing.expectEqual(@as(usize, 1), comp.sections.items[1].body.len);
}

test "decode: repeated + out-of-order sections are accepted (component divergence)" {
    // Two type sections out of canonical order around a core-module section —
    // the core parser would reject this; a component must not.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, // \0asm
        0x0d, 0x00, 0x01, 0x00, // component preamble
        0x07, 0x01, 0x00, // type (id 7)
        0x01, 0x01, 0x00, // core-module (id 1) — "earlier" id after a later one
        0x07, 0x01, 0x00, // type again (id 7) — duplicate id
    };
    var comp = try decode(testing.allocator, &bytes);
    defer comp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), comp.sections.items.len);
}

test "decode: a core module is rejected as NotAComponent" {
    try testing.expectError(Error.NotAComponent, decode(testing.allocator, &core_module));
}

test "classify: rejects bad magic, short input, unknown layer, future version" {
    try testing.expectError(Error.TruncatedHeader, classify(&[_]u8{ 0x00, 0x61, 0x73 }));
    try testing.expectError(Error.InvalidMagic, classify(&[_]u8{ 0x01, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 }));
    // layer 0x02 is neither core nor component.
    try testing.expectError(Error.InvalidLayer, classify(&[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x02, 0x00 }));
    // layer 0x01 (component) but version 0x0e (a future bump) is unsupported.
    try testing.expectError(Error.UnsupportedComponentVersion, classify(&[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0e, 0x00, 0x01, 0x00 }));
}

test "decode: unknown section id is rejected" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, // component preamble
        0x0d, 0x00, // section id 13 (undefined) size 0
    };
    try testing.expectError(Error.UnknownSectionId, decode(testing.allocator, &bytes));
}

test "decode: truncated section size is rejected" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, // component preamble
        0x07, 0x05, 0x00, // type section claims size 5 but only 1 body byte follows
    };
    try testing.expectError(Error.SectionTooLarge, decode(testing.allocator, &bytes));
}
