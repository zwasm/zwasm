//! `zwasm run` on a component (#622, ADR-0230): with no `--invoke` the entry
//! is the `wasi:cli/run` export, by name; `--invoke NAME[=ARGS]` calls a func
//! export through the typed facade, its arguments parsed by the WIT param
//! types. A refusal is one stderr line naming the exports, built here.
//!
//! Signatures print from the decoded `ValType`, not the resolved `WitType`:
//! only the former still carries a named type's label (`payload`).

const std = @import("std");
const component = @import("../api/component.zig");
const decode = @import("../feature/component/decode.zig");
const ctypes = @import("../feature/component/types.zig");
const wasi_host = @import("../wasi/host.zig");
const Engine = @import("../zwasm/engine.zig").Engine;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const TypeInfo = ctypes.TypeInfo;
const WitType = component.WitType;
const ComponentValue = component.ComponentValue;

/// The run was refused before the guest ran; the stderr line is in the
/// caller's `refusal` buffer.
pub const Error = error{ComponentRefused};

pub const Invoke = struct {
    name: []const u8,
    /// The text after `=`; null when `--invoke NAME` had none.
    args: ?[]const u8,
};

fn primName(p: ctypes.PrimValType) []const u8 {
    return if (p == .error_context) "error-context" else @tagName(p);
}

/// The name a type index was introduced under, when it has one.
fn typeLabel(info: *const TypeInfo, origin: ctypes.NamedOrigin) ?[]const u8 {
    return switch (origin) {
        .@"export" => |i| info.exports.items[i].name,
        .import => |i| info.imports.items[i].name,
        .alias => |i| switch (info.aliases.items[i].target) {
            .component_export => |ce| ce.name,
            .core_export, .outer => null,
        },
    };
}

/// WIT spelling of `vt`: a named type by its label, a structural one by its
/// shape (`list<u32>`, `result<payload, string>`).
fn writeValType(w: *Writer, info: *const TypeInfo, vt: ctypes.ValType) Writer.Error!void {
    const ti = switch (vt) {
        .primitive => |p| return w.writeAll(primName(p)),
        .type_index => |ti| ti,
    };
    if (ti >= info.type_space.items.len) return w.writeAll("?");
    switch (info.type_space.items[ti]) {
        .named => |origin| try w.writeAll(typeLabel(info, origin) orelse "type"),
        .def => |d| try writeDefType(w, info, info.deftypes.items[d]),
    }
}

fn writeDefType(w: *Writer, info: *const TypeInfo, dt: ctypes.DefType) Writer.Error!void {
    switch (dt) {
        .value => |vt| try writeValType(w, info, vt),
        .list => |l| {
            try w.writeAll("list<");
            try writeValType(w, info, l.element.*);
            if (l.fixed_length) |n| try w.print(", {d}", .{n});
            try w.writeAll(">");
        },
        .map => |m| {
            try w.writeAll("map<");
            try writeValType(w, info, m.key);
            try w.writeAll(", ");
            try writeValType(w, info, m.value);
            try w.writeAll(">");
        },
        .option => |o| {
            try w.writeAll("option<");
            try writeValType(w, info, o.payload.*);
            try w.writeAll(">");
        },
        .result => |r| {
            try w.writeAll("result");
            if (r.ok == null and r.err == null) return;
            try w.writeAll("<");
            if (r.ok) |ok| try writeValType(w, info, ok) else try w.writeAll("_");
            if (r.err) |err| {
                try w.writeAll(", ");
                try writeValType(w, info, err);
            }
            try w.writeAll(">");
        },
        .tuple => |t| {
            try w.writeAll("tuple<");
            for (t.types, 0..) |et, i| {
                if (i > 0) try w.writeAll(", ");
                try writeValType(w, info, et);
            }
            try w.writeAll(">");
        },
        inline .stream, .future => |s, tag| {
            try w.writeAll(@tagName(tag));
            if (s.payload) |p| {
                try w.writeAll("<");
                try writeValType(w, info, p);
                try w.writeAll(">");
            }
        },
        inline .own, .borrow => |res, tag| {
            try w.print("{s}<", .{@tagName(tag)});
            try writeValType(w, info, .{ .type_index = res });
            try w.writeAll(">");
        },
        .record => try w.writeAll("record"),
        .variant => try w.writeAll("variant"),
        .enum_ => try w.writeAll("enum"),
        .flags => try w.writeAll("flags"),
        .func => try w.writeAll("func"),
        .instance_type => try w.writeAll("instance"),
        .resource => try w.writeAll("resource"),
        .component_type => try w.writeAll("component"),
    }
}

/// `name: func(a: u32, b: u32) -> u32`.
fn writeSignature(w: *Writer, info: *const TypeInfo, name: []const u8, ft: ctypes.FuncType) Writer.Error!void {
    try w.print("{s}: {s}func(", .{ name, if (ft.is_async) "async " else "" });
    for (ft.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s}: ", .{p.name});
        try writeValType(w, info, p.ty);
    }
    try w.writeAll(")");
    if (ft.result) |r| {
        try w.writeAll(" -> ");
        try writeValType(w, info, r);
    }
}

/// `component '<path>' <what>; its exports are: <sig>, <sig> (use --invoke NAME[=args])`.
fn writeMissing(alloc: Allocator, w: *Writer, info: *const TypeInfo, path: []const u8, what: []const u8) !void {
    const funcs = try info.exportedFuncs(alloc);
    defer TypeInfo.freeExportedFuncs(alloc, funcs);
    try w.print("zwasm run: component '{s}' has no {s}", .{ path, what });
    if (funcs.len == 0) return w.writeAll(" and no func export");
    try w.writeAll("; its exports are: ");
    for (funcs, 0..) |f, i| {
        if (i > 0) try w.writeAll(", ");
        try writeSignature(w, info, f.name, f.ty);
    }
    try w.writeAll(" (use --invoke NAME[=args])");
}

/// The refusal of a component run without `--invoke` that has no command
/// entry (the entry reported `NoRunExport`).
pub fn writeNoRunRefusal(alloc: Allocator, bytes: []const u8, path: []const u8, refusal: *std.ArrayList(u8)) !void {
    var decoded = try decode.decode(alloc, bytes);
    defer decoded.deinit(alloc);
    var info = try ctypes.decodeTypeInfo(alloc, &decoded);
    defer info.deinit();
    var aw: Writer.Allocating = .fromArrayList(alloc, refusal);
    defer refusal.* = aw.toArrayList();
    try writeMissing(alloc, &aw.writer, &info, path, "wasi:cli/run export");
}

/// What `--invoke` can write on the command line.
fn isArgType(t: WitType) bool {
    return t == .prim and t.prim != .error_context;
}

/// What `--invoke` can print: a scalar, char or string, or the payload-less
/// `result` of `wasi:cli/run`'s `run`, whose `err` is exit code 1.
fn isResultType(t: WitType) bool {
    return isArgType(t) or (t == .result and t.result.ok == null and t.result.err == null);
}

/// `vt` as a refusal names it: a record / variant / enum / flags by kind and
/// label (`record payload`), anything else as its signature spells it.
fn writeRefusedType(w: *Writer, info: *const TypeInfo, vt: ctypes.ValType, t: WitType) Writer.Error!void {
    switch (t) {
        .record, .variant, .enum_, .flags => if (vt == .type_index and info.type_space.items[vt.type_index] == .named) {
            try w.print("{s} ", .{switch (t) {
                .enum_ => "enum",
                else => @tagName(t),
            }});
        },
        else => {},
    }
    try writeValType(w, info, vt);
}

const ArgError = error{InvalidArgValue};

fn parseArg(t: WitType, tok: []const u8) ArgError!ComponentValue {
    const p = t.prim;
    return switch (p) {
        .bool => if (std.mem.eql(u8, tok, "true")) .{ .bool = true } else if (std.mem.eql(u8, tok, "false")) .{ .bool = false } else error.InvalidArgValue,
        inline .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64 => |tag| @unionInit(
            ComponentValue,
            @tagName(tag),
            std.fmt.parseInt(@FieldType(ComponentValue, @tagName(tag)), tok, 0) catch return error.InvalidArgValue,
        ),
        .f32 => .{ .f32 = std.fmt.parseFloat(f32, tok) catch return error.InvalidArgValue },
        .f64 => .{ .f64 = std.fmt.parseFloat(f64, tok) catch return error.InvalidArgValue },
        .char => blk: {
            const view = std.unicode.Utf8View.init(tok) catch return error.InvalidArgValue;
            var it = view.iterator();
            const c = it.nextCodepoint() orelse return error.InvalidArgValue;
            if (it.nextCodepoint() != null) return error.InvalidArgValue;
            break :blk .{ .char = c };
        },
        .string => .{ .string = tok },
        .error_context => error.InvalidArgValue,
    };
}

/// One result line, bare, as the core `--invoke` prints its results.
fn writeResult(w: *Writer, v: ComponentValue) Writer.Error!void {
    switch (v) {
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        inline .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64 => |x| try w.print("{d}", .{x}),
        .char => |c| try w.print("{u}", .{c}),
        .string => |s| try w.writeAll(s),
        // `isResultType` admits only the arms above and the payload-less result.
        .list, .record, .tuple, .variant, .@"enum", .option, .result, .flags, .own, .borrow => return,
    }
    try w.writeAll("\n");
}

/// `--invoke NAME[=ARGS]` on a component: instantiate it, check NAME's
/// signature, call it, and append the result line to `out`. A payload-less
/// `result` that returns `err` sets exit code 1 (the `wasi:cli/run`
/// contract), so invoking `run` by name behaves as the default entry does.
pub fn invoke(
    alloc: Allocator,
    eng: *Engine,
    bytes: []const u8,
    host: *wasi_host.Host,
    path: []const u8,
    call: Invoke,
    out: *std.ArrayList(u8),
    refusal: *std.ArrayList(u8),
) !void {
    var opened = try component.open(eng, alloc, bytes, host, .{});
    defer opened.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const info = opened.typeInfo();

    var aw: Writer.Allocating = .fromArrayList(alloc, refusal);
    defer refusal.* = aw.toArrayList();
    const w = &aw.writer;

    const ft = info.resolveFuncType(call.name) orelse {
        const what = try arena.print("export {s}", .{call.name});
        try writeMissing(alloc, w, info, path, what);
        return error.ComponentRefused;
    };
    // An async lift is a task entry: its core func returns a task status and
    // needs the callback driver, which `invokeTyped` is not.
    const lifted_async = if (info.resolveLiftedFunc(call.name)) |l| l.is_async else false;
    if (ft.is_async or lifted_async) {
        try w.print("zwasm run: component '{s}': --invoke {s}: the export is async; --invoke calls sync exports", .{ path, call.name });
        return error.ComponentRefused;
    }
    const sig = (try opened.resolveFuncSig(arena, call.name)).?;
    for (ft.params, sig.params) |p, sp| {
        if (isArgType(sp.ty)) continue;
        try w.print("zwasm run: component '{s}': --invoke {s}: param '{s}' is ", .{ path, call.name, p.name });
        try writeRefusedType(w, info, p.ty, sp.ty);
        try w.writeAll("; --invoke takes scalar, char and string parameters");
        return error.ComponentRefused;
    }
    if (sig.result) |r| if (!isResultType(r)) {
        try w.print("zwasm run: component '{s}': --invoke {s}: result is ", .{ path, call.name });
        try writeRefusedType(w, info, ft.result.?, r);
        try w.writeAll("; --invoke prints scalar, char and string results");
        return error.ComponentRefused;
    };

    // A token is the text between commas, as given: a string argument cannot
    // hold a comma. `NAME=` passes one empty token to a one-parameter export
    // (an empty string) and none otherwise.
    const text = call.args orelse "";
    const ntok: usize = if (call.args == null or (text.len == 0 and sig.params.len != 1)) 0 else std.mem.countScalar(u8, text, ',') + 1;
    if (ntok != sig.params.len) {
        try w.print("zwasm run: component '{s}': --invoke: argument count does not match the export's parameters", .{path});
        return error.ComponentRefused;
    }
    const args = try arena.alloc(ComponentValue, ntok);
    var it = std.mem.splitScalar(u8, text, ',');
    for (args, sig.params) |*arg, sp| {
        const tok = it.next().?;
        arg.* = parseArg(sp.ty, if (sp.ty.prim == .string) tok else std.mem.trim(u8, tok, " ")) catch {
            try w.print("zwasm run: component '{s}': --invoke: could not parse an argument for the export's parameter type", .{path});
            return error.ComponentRefused;
        };
    }

    const result = try opened.invokeTyped(call.name, args, arena) orelse return;
    if (result == .result) {
        if (!result.result.is_ok and host.exit_code == null) host.exit_code = 1;
        return;
    }
    var ow: Writer.Allocating = .fromArrayList(alloc, out);
    defer out.* = ow.toArrayList();
    try writeResult(&ow.writer, result);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "parseArg: each WIT scalar by its own range, char as one scalar value" {
    try testing.expectEqual(@as(u32, 5), (try parseArg(.{ .prim = .u32 }, "5")).u32);
    try testing.expectEqual(@as(i8, -128), (try parseArg(.{ .prim = .s8 }, "-128")).s8);
    try testing.expectEqual(@as(u64, 255), (try parseArg(.{ .prim = .u64 }, "0xff")).u64);
    try testing.expectError(error.InvalidArgValue, parseArg(.{ .prim = .u32 }, "-1"));
    try testing.expectError(error.InvalidArgValue, parseArg(.{ .prim = .u8 }, "256"));
    try testing.expectEqual(true, (try parseArg(.{ .prim = .bool }, "true")).bool);
    try testing.expectError(error.InvalidArgValue, parseArg(.{ .prim = .bool }, "1"));
    try testing.expectEqual(@as(f64, 1.5), (try parseArg(.{ .prim = .f64 }, "1.5")).f64);
    try testing.expectEqual(@as(u21, 'é'), (try parseArg(.{ .prim = .char }, "é")).char);
    try testing.expectError(error.InvalidArgValue, parseArg(.{ .prim = .char }, "ab"));
    try testing.expectError(error.InvalidArgValue, parseArg(.{ .prim = .char }, ""));
    try testing.expectEqualStrings(" a b ", (try parseArg(.{ .prim = .string }, " a b ")).string);
}

test "writeResult: bare, one line" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeResult(&aw.writer, .{ .u32 = 5 });
    try writeResult(&aw.writer, .{ .bool = false });
    try writeResult(&aw.writer, .{ .char = 'é' });
    try writeResult(&aw.writer, .{ .string = "Hello, world!" });
    try testing.expectEqualStrings("5\nfalse\né\nHello, world!\n", aw.written());
}
