//! Tests for `types.zig` — the component-model type model + `Binary.md`
//! deftype decoder. Extracted to keep `types.zig` under the 2000-line hard
//! cap (ADR-0099) as the WASI-0.3 (D-335) campaign grows the decoder. Tests
//! reach `types.zig` through its public API + the `decode.zig` entry point.

const std = @import("std");
const types = @import("types.zig");
const decode = @import("decode.zig");

const Error = types.Error;
const ExternDesc = types.ExternDesc;
const PrimValType = types.PrimValType;
const Sort = types.Sort;
const CoreSort = types.CoreSort;
const TypeInfo = types.TypeInfo;
const TypeSpaceEntry = types.TypeSpaceEntry;
const TypeBound = types.TypeBound;
const StringEncoding = types.StringEncoding;
const ValType = types.ValType;
const decodeTypeInfo = types.decodeTypeInfo;

const testing = std.testing;

/// Build a component binary from a slice of (section-id, body) pairs.
fn buildComponent(comptime sections: []const struct { u8, []const u8 }) []const u8 {
    comptime {
        var out: []const u8 = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
        for (sections) |s| {
            out = out ++ [_]u8{ s[0], @intCast(s[1].len) } ++ s[1];
        }
        return out;
    }
}

fn decodeBoth(bytes: []const u8) !TypeInfo {
    var comp = try decode.decode(testing.allocator, bytes);
    defer comp.deinit(testing.allocator);
    return decodeTypeInfo(testing.allocator, &comp);
}

test "type section: a single primitive deftype" {
    // type section: count=1, deftype = primvaltype string (0x73)
    const bytes = comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x73 } }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 1), info.deftypes.items.len);
    try testing.expectEqual(PrimValType.string, info.deftypes.items[0].value.primitive);
}

test "type section: functype (string) -> (string)" {
    // functype 0x40, 1 param "x":string(0x73), resultlist 0x00 string(0x73)
    const body = [_]u8{
        0x01, // count = 1 deftype
        0x40, // functype
        0x01, // 1 param
        0x01, 0x78, // label' "x"
        0x73, // valtype string
        0x00, 0x73, // resultlist: one result, string
    };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();

    const ft = info.deftypes.items[0].func;
    try testing.expectEqual(@as(usize, 1), ft.params.len);
    try testing.expectEqualStrings("x", ft.params[0].name);
    try testing.expectEqual(PrimValType.string, ft.params[0].ty.primitive);
    try testing.expectEqual(PrimValType.string, ft.result.?.primitive);
    try testing.expect(!ft.is_async);
}

test "functype with no results (0x01 0x00) + a typeidx param" {
    const body = [_]u8{
        0x01, 0x40, // count, functype
        0x01, 0x01, 0x61, 0x00, // 1 param "a" : valtype typeidx 0
        0x01, 0x00, // resultlist: no results
    };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    const ft = info.deftypes.items[0].func;
    try testing.expectEqual(@as(u32, 0), ft.params[0].ty.type_index);
    try testing.expectEqual(@as(?ValType, null), ft.result);
}

test "round-trip: an imported AND exported func type resolves via the index space" {
    // type[0] = (func (param "s" string) (result string))
    const type_body = [_]u8{ 0x01, 0x40, 0x01, 0x01, 0x73, 0x73, 0x00, 0x73 };
    // import "host:greet" (func (type 0))   — externdesc 0x01 typeidx 0
    const import_body = [_]u8{ 0x01, 0x00, 0x0a, 'h', 'o', 's', 't', ':', 'g', 'r', 'e', 'e', 't', 0x01, 0x00 };
    // export "greet" sortidx(func=0x01, idx 0) externdesc? = 0x01 (func type 0)
    const export_body = [_]u8{ 0x01, 0x00, 0x05, 'g', 'r', 'e', 'e', 't', 0x01, 0x00, 0x01, 0x01, 0x00 };
    const bytes = comptime buildComponent(&.{
        .{ 7, &type_body },
        .{ 10, &import_body },
        .{ 11, &export_body },
    });
    var info = try decodeBoth(bytes);
    defer info.deinit();

    try testing.expectEqual(@as(usize, 1), info.imports.items.len);
    try testing.expectEqualStrings("host:greet", info.imports.items[0].name);
    try testing.expectEqual(@as(u32, 0), info.imports.items[0].desc.func);

    try testing.expectEqual(@as(usize, 1), info.exports.items.len);
    try testing.expectEqualStrings("greet", info.exports.items[0].name);
    try testing.expectEqual(Sort.func, info.exports.items[0].sort);
    try testing.expectEqual(@as(u32, 0), info.exports.items[0].desc.?.func);

    // both the import and export resolve to the same func deftype.
    const dt = info.deftype(info.imports.items[0].desc.func).?;
    try testing.expectEqual(PrimValType.string, dt.func.params[0].ty.primitive);
}

test "type_space: definition order across def / import / export minting" {
    // type[0] = (record (field "f" u32)) — local def.
    const type_body = [_]u8{ 0x01, 0x72, 0x01, 0x01, 'f', 0x79 };
    // import "t" (type (eq 0)) — mints type[1] as NAMED.
    const import_body = [_]u8{ 0x01, 0x00, 0x01, 't', 0x03, 0x00, 0x00 };
    // export "u" (type 1) — mints type[2] as NAMED.
    const export_body = [_]u8{ 0x01, 0x00, 0x01, 'u', 0x03, 0x01, 0x00 };
    const bytes = comptime buildComponent(&.{
        .{ 7, &type_body },
        .{ 10, &import_body },
        .{ 11, &export_body },
    });
    var info = try decodeBoth(bytes);
    defer info.deinit();

    try testing.expectEqual(@as(u32, 3), info.type_space_len);
    try testing.expectEqual(@as(usize, 3), info.type_space.items.len);
    try testing.expectEqual(@as(u32, 0), info.type_space.items[0].def);
    try testing.expectEqual(std.meta.Tag(TypeSpaceEntry).named, std.meta.activeTag(info.type_space.items[1]));
    try testing.expectEqual(std.meta.Tag(TypeSpaceEntry).named, std.meta.activeTag(info.type_space.items[2]));
}

test "export with no externdesc (optional absent)" {
    // export "x" sortidx(func 0x01, idx 2), externdesc? = 0x00
    const export_body = [_]u8{ 0x01, 0x00, 0x01, 'x', 0x01, 0x02, 0x00 };
    const bytes = comptime buildComponent(&.{.{ 11, &export_body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(u32, 2), info.exports.items[0].index);
    try testing.expectEqual(@as(?ExternDesc, null), info.exports.items[0].desc);
}

test "import name 0x02 prefix carries a dropped version suffix" {
    // import 0x02 "p:i" version "1.0" (func type 0)
    const import_body = [_]u8{ 0x01, 0x02, 0x03, 'p', ':', 'i', 0x03, '1', '.', '0', 0x01, 0x00 };
    const bytes = comptime buildComponent(&.{.{ 10, &import_body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqualStrings("p:i", info.imports.items[0].name);
}

test "core-module externdesc (0x00 0x11)" {
    // import "m" (core module (type 3)) : 0x00 0x11 idx 3
    const import_body = [_]u8{ 0x01, 0x00, 0x01, 'm', 0x00, 0x11, 0x03 };
    const bytes = comptime buildComponent(&.{.{ 10, &import_body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(u32, 3), info.imports.items[0].desc.core_module);
}

test "record decode: 0x72 named fields" {
    // record { x: u32, y: string }: 0x72 count=2, "x" u32(0x79), "y" string(0x73)
    const body = [_]u8{ 0x01, 0x72, 0x02, 0x01, 'x', 0x79, 0x01, 'y', 0x73 };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    const r = info.deftypes.items[0].record;
    try testing.expectEqual(@as(usize, 2), r.fields.len);
    try testing.expectEqualStrings("x", r.fields[0].name);
    try testing.expectEqual(PrimValType.u32, r.fields[0].ty.primitive);
    try testing.expectEqual(PrimValType.string, r.fields[1].ty.primitive);
}

test "list decode: variable (0x70) and fixed (0x67)" {
    // type[0] = list<u8>, type[1] = list<u8, 4>
    const body = [_]u8{ 0x02, 0x70, 0x7d, 0x67, 0x7d, 0x04 };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(?u32, null), info.deftypes.items[0].list.fixed_length);
    try testing.expectEqual(PrimValType.u8, info.deftypes.items[0].list.element.primitive);
    try testing.expectEqual(@as(?u32, 4), info.deftypes.items[1].list.fixed_length);
}

test "variant/option/result decode" {
    // variant { "a", "b"(u32) } : 0x71 count=2; "a" none 0x00; "b" some(u32) 0x00
    const variant_body = [_]u8{ 0x01, 0x71, 0x02, 0x01, 'a', 0x00, 0x00, 0x01, 'b', 0x01, 0x79, 0x00 };
    var v = try decodeBoth(comptime buildComponent(&.{.{ 7, &variant_body }}));
    defer v.deinit();
    const variant = v.deftypes.items[0].variant;
    try testing.expectEqual(@as(usize, 2), variant.cases.len);
    try testing.expectEqual(@as(?ValType, null), variant.cases[0].payload);
    try testing.expectEqual(PrimValType.u32, variant.cases[1].payload.?.primitive);

    // option<string>: 0x6b string
    var o = try decodeBoth(comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x6b, 0x73 } }}));
    defer o.deinit();
    try testing.expectEqual(PrimValType.string, o.deftypes.items[0].option.payload.primitive);

    // result<u32, string>: 0x6a 0x01 u32 0x01 string
    var r = try decodeBoth(comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x6a, 0x01, 0x79, 0x01, 0x73 } }}));
    defer r.deinit();
    try testing.expectEqual(PrimValType.u32, r.deftypes.items[0].result.ok.?.primitive);
    try testing.expectEqual(PrimValType.string, r.deftypes.items[0].result.err.?.primitive);
}

test "tuple decode + empty record rejected" {
    // tuple<u32, f64>: 0x6f count=2
    var t = try decodeBoth(comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x6f, 0x02, 0x79, 0x75 } }}));
    defer t.deinit();
    try testing.expectEqual(@as(usize, 2), t.deftypes.items[0].tuple.types.len);

    // empty record (count 0) is malformed.
    try testing.expectError(Error.InvalidDefType, decodeBoth(comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x72, 0x00 } }})));
}

test "own/borrow decode (0x69 / 0x68)" {
    // type[0] = own<3>, type[1] = borrow<3>
    const body = [_]u8{ 0x02, 0x69, 0x03, 0x68, 0x03 };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(u32, 3), info.deftypes.items[0].own);
    try testing.expectEqual(@as(u32, 3), info.deftypes.items[1].borrow);
}

test "externdesc type-bound (sub resource / eq) on an import" {
    // import "r" (type (sub resource)) : externdesc 0x03 0x01
    const sub = [_]u8{ 0x01, 0x00, 0x01, 'r', 0x03, 0x01 };
    var s = try decodeBoth(comptime buildComponent(&.{.{ 10, &sub }}));
    defer s.deinit();
    try testing.expectEqual(TypeBound.sub_resource, s.imports.items[0].desc.type_bound);

    // import "t" (type (eq 5)) : externdesc 0x03 0x00 5
    const eq = [_]u8{ 0x01, 0x00, 0x01, 't', 0x03, 0x00, 0x05 };
    var e = try decodeBoth(comptime buildComponent(&.{.{ 10, &eq }}));
    defer e.deinit();
    try testing.expectEqual(@as(u32, 5), e.imports.items[0].desc.type_bound.eq);
}

test "stream<T>/future<T> decode (0x66/0x65) with optional payload" {
    // type[0] stream<u32>: 0x66 0x01 u32(0x79); type[1] stream (none): 0x66 0x00;
    // type[2] future<type 0>: 0x65 0x01 typeidx 0.
    const body = [_]u8{
        0x03,
        0x66, 0x01, 0x79, // stream<u32>
        0x66, 0x00, //       stream (no element)
        0x65, 0x01, 0x00, // future<type 0>
    };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(PrimValType.u32, info.deftypes.items[0].stream.payload.?.primitive);
    try testing.expect(info.deftypes.items[1].stream.payload == null);
    try testing.expectEqual(@as(u32, 0), info.deftypes.items[2].future.payload.?.type_index);
}

test "canon section: canon lift with opts (utf8 + memory 0 + realloc 1)" {
    // count=1; lift 0x00 0x00 funcidx=0 opts{utf8, memory 0, realloc 1} typeidx=0
    const body = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x03, 0x00, 0x03, 0x00, 0x04, 0x01, 0x00 };
    const bytes = comptime buildComponent(&.{.{ 8, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 1), info.canons.items.len);
    const lift = info.canons.items[0].lift;
    try testing.expectEqual(@as(u32, 0), lift.core_func);
    try testing.expectEqual(@as(u32, 0), lift.type_index);
    try testing.expectEqual(StringEncoding.utf8, lift.opts.string_encoding);
    try testing.expectEqual(@as(?u32, 0), lift.opts.memory);
    try testing.expectEqual(@as(?u32, 1), lift.opts.realloc);
    try testing.expectEqual(@as(?u32, null), lift.opts.post_return);
}

test "canon section: canon lift with async + callback opts (CM-async)" {
    // count=1; lift 0x00 0x00 funcidx=0 opts{async 0x06, callback 0x07 f=1} typeidx=0
    const body = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x02, 0x06, 0x07, 0x01, 0x00 };
    const bytes = comptime buildComponent(&.{.{ 8, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    const lift = info.canons.items[0].lift;
    try testing.expect(lift.opts.is_async);
    try testing.expectEqual(@as(?u32, 1), lift.opts.callback);
}

test "canon section: canon lower + empty opts + utf16/post-return" {
    // lower 0x01 0x00 func=2 opts{} ; then a second lower with utf16 + post-return 3
    const body = [_]u8{
        0x02,
        0x01, 0x00, 0x02, 0x00, // lower func 2, no opts
        0x01, 0x00, 0x07, 0x02, 0x01, 0x05, 0x03, // lower func 7, opts{utf16, post-return 3}
    };
    const bytes = comptime buildComponent(&.{.{ 8, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(u32, 2), info.canons.items[0].lower.func);
    try testing.expectEqual(StringEncoding.utf8, info.canons.items[0].lower.opts.string_encoding);
    try testing.expectEqual(StringEncoding.utf16, info.canons.items[1].lower.opts.string_encoding);
    try testing.expectEqual(@as(?u32, 3), info.canons.items[1].lower.opts.post_return);
}

test "canon section: resource builtins decode" {
    const body = [_]u8{ 0x01, 0x02, 0x05 }; // resource.new typeidx 5
    const bytes = comptime buildComponent(&.{.{ 8, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(u32, 5), info.canons.items[0].resource_new);
}

test "core-instance decode: instantiate + inline exports" {
    const body = [_]u8{
        0x02,
        0x00, 0x00, 0x00, // [0] instantiate module 0, 0 args
        0x01, 0x01, 0x01, 'm', 0x02, 0x00, // [1] inline: export "m" → core mem 0
    };
    const bytes = comptime buildComponent(&.{.{ 2, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 2), info.core_instances.items.len);
    try testing.expectEqual(@as(u32, 0), info.core_instances.items[0].instantiate.module);
    try testing.expectEqualStrings("m", info.core_instances.items[1].inline_exports[0].name);
    try testing.expectEqual(CoreSort.memory, info.core_instances.items[1].inline_exports[0].sort);
}

test "alias decode: core export + outer" {
    const body = [_]u8{
        0x02,
        0x00, 0x00, 0x01, 0x00, 0x05, 'g', 'r', 'e', 'e', 't', // (core func) core export inst 0 "greet"
        0x03, 0x02, 0x02, 0x03, // (type) outer ct 2 idx 3
    };
    const bytes = comptime buildComponent(&.{.{ 6, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 2), info.aliases.items.len);
    try testing.expectEqualStrings("greet", info.aliases.items[0].target.core_export.name);
    try testing.expectEqual(@as(u32, 0), info.aliases.items[0].target.core_export.instance);
    try testing.expectEqual(@as(u32, 2), info.aliases.items[1].target.outer.count);
    try testing.expectEqual(@as(u32, 3), info.aliases.items[1].target.outer.index);
}

test "component-instance decode: instantiate with arg + inline exports" {
    const body = [_]u8{
        0x02,
        0x00, 0x00, 0x01, 0x01, 'a', 0x05, 0x00, // instantiate comp 0, arg "a" → instance 0
        0x01, 0x01, 0x00, 0x01, 'f', 0x01, 0x00, // inline: export "f" → func 0
    };
    const bytes = comptime buildComponent(&.{.{ 5, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 2), info.component_instances.items.len);
    const inst0 = info.component_instances.items[0].instantiate;
    try testing.expectEqual(@as(u32, 0), inst0.component);
    try testing.expectEqualStrings("a", inst0.args[0].name);
    try testing.expectEqual(Sort.instance, inst0.args[0].sort);
    const inl = info.component_instances.items[1].inline_exports;
    try testing.expectEqualStrings("f", inl[0].name);
    try testing.expectEqual(Sort.func, inl[0].sort);
}

test "instance index space: each minting construct records its own origin, and a re-export resolves to what it names" {
    // import "i" (instance (type 0))                        -> instance 0 = import
    const import_body = [_]u8{ 0x01, 0x00, 0x01, 'i', 0x05, 0x00 };
    const inst_body_1 = [_]u8{
        0x02,
        0x01, 0x01, 0x00, 0x01, 'f', 0x01, 0x00, // inline: export "f" (func 0)      -> instance 1 = local 0
        0x01, 0x01, 0x00, 0x01, 'x', 0x05, 0x01, // inline: export "x" (instance 1)  -> instance 2 = local 1
    };
    // alias export 2 "x" (instance)                         -> instance 3 = alias 0
    const alias_body = [_]u8{ 0x01, 0x05, 0x00, 0x02, 0x01, 'x' };
    // export "a" (instance 1)                               -> instance 4 = re_export 0
    const export_body_1 = [_]u8{ 0x01, 0x00, 0x01, 'a', 0x05, 0x01, 0x00 };
    // inline: export "g" (func 0)                           -> instance 5 = local 2
    const inst_body_2 = [_]u8{ 0x01, 0x01, 0x01, 0x00, 0x01, 'g', 0x01, 0x00 };
    const export_body_2 = [_]u8{
        0x02,
        0x00, 0x01, 'b', 0x05, 0x05, 0x00, // export "b" (instance 5)  -> instance 6 = re_export 1
        0x00, 0x01, 'c', 0x05, 0x04, 0x00, // export "c" (instance 4)  -> instance 7 = re_export 2
    };
    const bytes = comptime buildComponent(&.{
        .{ 10, &import_body },
        .{ 5, &inst_body_1 },
        .{ 6, &alias_body },
        .{ 11, &export_body_1 },
        .{ 5, &inst_body_2 },
        .{ 11, &export_body_2 },
    });
    var info = try decodeBoth(bytes);
    defer info.deinit();

    const Tag = std.meta.Tag(types.InstanceOrigin);
    const origins = info.instance_origins.items;
    try testing.expectEqual(@as(usize, 8), origins.len);
    try testing.expectEqual(@as(usize, 3), info.component_instances.items.len);
    const want_tags = [_]Tag{ .import, .local, .local, .alias, .re_export, .local, .re_export, .re_export };
    for (want_tags, origins) |want, got| try testing.expectEqual(want, std.meta.activeTag(got));
    try testing.expectEqual(@as(u32, 0), origins[1].local);
    try testing.expectEqual(@as(u32, 1), origins[2].local);
    try testing.expectEqual(@as(u32, 0), origins[3].alias);
    try testing.expectEqual(@as(u32, 2), origins[5].local);
    try testing.expectEqual(@as(u32, 2), origins[7].re_export);

    // Index 5 has four non-import indices below it but is the THIRD
    // definition: an ordinal counted from the tags would land past the end.
    try testing.expectEqual(@as(?u32, 2), info.localInstanceOrdinal(5));
    // A re-export resolves to the definition it names, through a chain too
    // (7 -> 4 -> 1).
    try testing.expectEqual(@as(?u32, 2), info.localInstanceOrdinal(6));
    try testing.expectEqual(@as(?u32, 0), info.localInstanceOrdinal(7));
    try testing.expectEqual(@as(?u32, 0), info.localInstanceOrdinal(4));
    // Imported and alias-minted instances define nothing locally.
    try testing.expectEqual(@as(?u32, null), info.localInstanceOrdinal(0));
    try testing.expectEqual(@as(?u32, null), info.localInstanceOrdinal(3));
    try testing.expectEqualStrings("i", info.instanceOrigin(0).?.import);
    try testing.expectEqual(@as(u32, 0), info.instanceOrigin(3).?.alias);
    try testing.expect(info.instanceOrigin(8) == null);
}

test "instance index space: a re-export that does not name an earlier index resolves to nothing" {
    // export "a" (instance 0) with no instance defined: the export's own entry
    // is index 0, so it names itself. Validation rejects this; the resolver
    // must still terminate rather than follow the self-loop.
    const export_body = [_]u8{ 0x01, 0x00, 0x01, 'a', 0x05, 0x00, 0x00 };
    const bytes = comptime buildComponent(&.{.{ 11, &export_body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 1), info.instance_origins.items.len);
    try testing.expect(info.instanceOrigin(0) == null);
    try testing.expectEqual(@as(?u32, null), info.localInstanceOrdinal(0));
}

test "canon: bare async opt (no callback) decodes is_async" {
    // lift with opts{async 0x06}: is_async=true, callback stays null.
    const async_opt = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x00 };
    var info = try decodeBoth(comptime buildComponent(&.{.{ 8, &async_opt }}));
    defer info.deinit();
    try testing.expect(info.canons.items[0].lift.opts.is_async);
    try testing.expectEqual(@as(?u32, null), info.canons.items[0].lift.opts.callback);
}

test "canon section: task.return decode (0x09) mints a core func" {
    // count=1; task.return 0x09 resultlist{0x00 s32(0x7a)} opts{} → core func 0.
    const body = [_]u8{ 0x01, 0x09, 0x00, 0x7a, 0x00 };
    const bytes = comptime buildComponent(&.{.{ 8, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    const tr = info.canons.items[0].task_return;
    try testing.expectEqual(PrimValType.s32, tr.result.?.primitive);
    try testing.expectEqual(StringEncoding.utf8, tr.opts.string_encoding);
    try testing.expectEqual(PrimValType.s32, info.coreFunc(0).?.task_return.result.?.primitive);
}

test "canon section: stream/future builtins decode (0x0e–0x1b)" {
    // stream.new<5>: 0x0e 0x05; stream.read<5> opts{utf8}: 0x0f 0x05 0x01 0x00;
    // stream.cancel-read<5> async: 0x11 0x05 0x01; future.drop-writable<7>: 0x1b 0x07.
    const body = [_]u8{
        0x04,
        0x0e,
        0x05,
        0x0f,
        0x05,
        0x01,
        0x00,
        0x11,
        0x05,
        0x01,
        0x1b,
        0x07,
    };
    const bytes = comptime buildComponent(&.{.{ 8, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 4), info.canons.items.len);
    const c0 = info.canons.items[0].stream_future;
    try testing.expectEqual(types.StreamFutureOp.stream_new, c0.op);
    try testing.expectEqual(@as(u32, 5), c0.type_index);
    const c1 = info.canons.items[1].stream_future;
    try testing.expectEqual(types.StreamFutureOp.stream_read, c1.op);
    try testing.expectEqual(StringEncoding.utf8, c1.opts.?.string_encoding);
    const c2 = info.canons.items[2].stream_future;
    try testing.expectEqual(types.StreamFutureOp.stream_cancel_read, c2.op);
    try testing.expectEqual(@as(?bool, true), c2.is_async);
    const c3 = info.canons.items[3].stream_future;
    try testing.expectEqual(types.StreamFutureOp.future_drop_writable, c3.op);
    try testing.expectEqual(@as(u32, 7), c3.type_index);
    // Each builtin mints a core func (Binary.md: "(core func)").
    try testing.expectEqual(@as(usize, 4), info.core_funcs.items.len);
}

test "canon section: waitable-set builtins decode (0x1f–0x23)" {
    // count=4: waitable-set.new 0x1f; waitable.join 0x23; waitable-set.wait 0x20
    // cancel=0x01 mem=0; waitable-set.drop 0x22 → 4 core funcs.
    const body = [_]u8{ 0x04, 0x1f, 0x23, 0x20, 0x01, 0x00, 0x22 };
    const bytes = comptime buildComponent(&.{.{ 8, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(types.WaitableSetOp.new, info.canons.items[0].waitable_set.op);
    try testing.expectEqual(types.WaitableSetOp.join, info.canons.items[1].waitable_set.op);
    const w = info.canons.items[2].waitable_set;
    try testing.expectEqual(types.WaitableSetOp.wait, w.op);
    try testing.expectEqual(true, w.cancellable);
    try testing.expectEqual(@as(?u32, 0), w.memory);
    try testing.expectEqual(types.WaitableSetOp.drop, info.canons.items[3].waitable_set.op);
    // each mints a core func.
    try testing.expectEqual(@as(usize, 4), info.core_funcs.items.len);
    try testing.expectEqual(types.WaitableSetOp.wait, info.coreFunc(2).?.waitable_set.op);
}

test "enum decode: 0x6d label vec" {
    // enum { "red", "green" }: 0x6d count=2, "red" "green"
    const body = [_]u8{ 0x01, 0x6d, 0x02, 0x03, 'r', 'e', 'd', 0x05, 'g', 'r', 'e', 'e', 'n' };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    const e = info.deftypes.items[0].enum_;
    try testing.expectEqual(@as(usize, 2), e.labels.len);
    try testing.expectEqualStrings("red", e.labels[0]);
    try testing.expectEqualStrings("green", e.labels[1]);
}

test "flags decode: 0x6e label vec" {
    // flags { "a", "b", "c" }: 0x6e count=3
    const body = [_]u8{ 0x01, 0x6e, 0x03, 0x01, 'a', 0x01, 'b', 0x01, 'c' };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 3), info.deftypes.items[0].flags.labels.len);
}

test "enum with zero labels is rejected" {
    const bytes = comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x6d, 0x00 } }});
    try testing.expectError(Error.EmptyEnum, decodeBoth(bytes));
}

test "instancetype decode: an interface type with an exported func + own type" {
    // type[0] = instance { (export "f" (func (type 0))); (type own<0>) }
    //   0x42 count=2 | 0x04 exportname'("f") externdesc(0x01 func 0) | 0x01 own<0>(0x69 0x00)
    const body = [_]u8{
        0x01, 0x42, 0x02,
        0x04, 0x00, 0x01, 'f', 0x01, 0x00, // exportdecl "f" → func type 0
        0x01, 0x69, 0x00, // type def: own<0>
    };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    const it = info.deftypes.items[0].instance_type;
    try testing.expectEqual(@as(usize, 2), it.decls.len);
    try testing.expectEqualStrings("f", it.decls[0].export_decl.name);
    try testing.expectEqual(@as(u32, 0), it.decls[0].export_decl.desc.func);
    try testing.expectEqual(@as(u32, 0), it.decls[1].type_def.own);
}

test "componenttype decode: an import + a nested instance type" {
    // type[0] = component { (import "i" (instance (type 0))); 0x42 instance{} }
    //   0x41 count=2 | 0x03 importname'("i") externdesc(0x05 instance 0) | <instancedecl 0x42? no>
    // componentdecl: 0x03 importdecl | instancedecl. Use 0x03 import + a 0x04 export instancedecl.
    const body = [_]u8{
        0x01, 0x41, 0x02,
        0x03, 0x00, 0x01, 'i', 0x05, 0x00, // importdecl "i" → instance type 0
        0x04, 0x00, 0x01, 'e', 0x03, 0x01, // instancedecl exportdecl "e" → (type (sub resource))
    };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    const ct = info.deftypes.items[0].component_type;
    try testing.expectEqual(@as(usize, 2), ct.decls.len);
    try testing.expectEqualStrings("i", ct.decls[0].import_decl.name);
    try testing.expectEqual(@as(u32, 0), ct.decls[0].import_decl.desc.instance);
    try testing.expectEqualStrings("e", ct.decls[1].instance_decl.export_decl.name);
    try testing.expectEqual(TypeBound.sub_resource, ct.decls[1].instance_decl.export_decl.desc.type_bound);
}

test "deftype cannot be a bare typeidx" {
    // count=1, then SLEB 0x00 = 0 (non-negative) → InvalidDefType
    const bytes = comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x00 } }});
    try testing.expectError(Error.InvalidDefType, decodeBoth(bytes));
}

test "type section with trailing bytes is rejected" {
    const bytes = comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x73, 0xff } }});
    try testing.expectError(Error.TrailingBytes, decodeBoth(bytes));
}

test "resourcetype (0x3f) decodes — a valid resource def is no longer falsely rejected (D-322)" {
    // (component (type (resource (rep i32))))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, // preamble
        0x07, 0x04, 0x01, 0x3f, 0x7f, 0x00, // type section: 1 resourcetype, no dtor
    };
    var comp = try decode.decode(testing.allocator, &bytes);
    defer comp.deinit(testing.allocator);
    var info = try decodeTypeInfo(testing.allocator, &comp);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 1), info.deftypes.items.len);
    try testing.expectEqual(@as(?u32, null), info.deftypes.items[0].resource.dtor);
}
