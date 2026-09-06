//! Component Model spec corpus runner (E1 — ADR-0170 campaign).
//!
//! Parallels `spec_assert_runner.zig` (core-wasm) but drives the
//! Component Model host API (`zwasm.component.host`): decode +
//! instantiate a real component, then assert on its lifted exports.
//! Built against a `-Dcomponent=true` `zwasm` module (see build.zig).
//!
//! Walks subdirectories of a corpus root; each subdir has a
//! `manifest.txt` with directives:
//!
//!   `component <path>`                     — decode (classify==component) + instantiate single component
//!   `component_p2 <path>`                  — build via the WASI-P2 host graph (wit-bindgen components import wasi)
//!   `graph <path>`                         — instantiate a multi-component graph (cross-module link)
//!   `assert_string <export> <arg> -> <s>`  — invokeStringExport; compare UTF-8 result (<s> may contain spaces)
//!   `assert_flat_i32 <export> <a..> -> <v>`— invokeFlat (i32 args); compare results[0].i32
//!   `assert_typed <export> (<v>, ..) -> <v>` — TYPED invoke (ADR-0183): parse each arg against the export's
//!                                          WIT param type, invokeTyped/invokeTypedBuilt, render the result
//!                                          canonically and compare TEXT. Value syntax (canonical render):
//!                                          ints/floats bare (`-5`, `1.5`), `true`/`false`, `"str"` (\\ \" \n \t \r),
//!                                          `'c'`, lists `[v, v]`, records `{name: v, ..}` (declared field order),
//!                                          tuples `(v, v)`, variant/option/result by case name (`ok(v)`, `none`,
//!                                          `some(v)`); enum renders `enum<N>`, flags `flags<0xN>` (ordinals —
//!                                          `ComponentValue` carries no label names for these).
//!   `skip-impl <reason>`                   — implementation gap; counts toward the `skip-impl == 0` gate
//!   `skip-adr-<id> <reason>`               — design-deferred per the named skip-ADR; waived from gate
//!
//! Unlike `spec_assert_runner`, fixture paths are resolved relative to
//! the repo-root cwd (`zig build` runs there), NOT the corpus subdir.
//! This lets a manifest REUSE the single committed fixture under
//! `test/component/` instead of duplicating it into the corpus tree.
//!
//! Per ADR-0174 (win-harden-I lesson): a MISSING corpus root is a hard
//! `exit(1)`, never a silent "0 manifests" skip.
//!
//! Usage: component_model_assert_runner <corpus-root>
//! Exits non-zero if any assertion failed OR the corpus root is absent.
//!
//! Zone: test/ (outside the src/ zone hierarchy per ADR-0023 §A1).

const std = @import("std");

const zwasm = @import("zwasm");
const host = zwasm.feature.component.host;
const cdecode = zwasm.feature.component.decode;
const ctypes = zwasm.feature.component.types;
const cvalidate = zwasm.feature.component.validate;
const canon = zwasm.feature.component.canon;
const wasi_host = zwasm.wasi.host;
const Value = zwasm.Value;
const ComponentValue = host.ComponentValue;

/// A `component_p2`-loaded fixture: the WASI host must outlive the built
/// graph (trampolines hold a pointer to it).
const BuiltP2 = struct {
    wh: *wasi_host.Host,
    bc: host.BuiltComponent,
};

const Current = union(enum) {
    none,
    single: host.ComponentInstance,
    graph: host.ComponentGraph,
    built: BuiltP2,
};

pub fn main(init: std.process.Init) !void {
    zwasm.support.dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const corpus_root_arg = arg_it.next() orelse {
        try stdout.print("usage: component_model_assert_runner <corpus-root>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_root = try gpa.dupe(u8, corpus_root_arg);
    defer gpa.free(corpus_root);

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;
    var skipped_adr: u32 = 0;
    var manifest_count: u32 = 0;

    var engine = try zwasm.Engine.init(gpa, .{});
    defer engine.deinit();

    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
        // ADR-0174: a missing corpus root is a hard failure, not a
        // silent skip (the windowsmini "0 manifests" exit-0 anomaly).
        try stdout.print("error: cannot open corpus root '{s}': {s}\n", .{ corpus_root, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer root.close(io);

    var it = root.iterate();
    while (try it.next(io)) |dir_entry| {
        if (dir_entry.kind != .directory) continue;
        manifest_count += 1;
        runCorpus(io, gpa, &engine, &root, dir_entry.name, stdout, &passed, &failed, &skipped, &skipped_adr) catch |err| {
            try stdout.print("FAIL  {s}: corpus error {s}\n", .{ dir_entry.name, @errorName(err) });
            failed += 1;
        };
    }

    try stdout.print("\ncomponent_model_assert_runner: {d} passed, {d} failed, {d} skipped (= {d} skip-impl + {d} skip-adr) (over {d} manifests)\n", .{ passed, failed, skipped + skipped_adr, skipped, skipped_adr, manifest_count });
    try stdout.flush();
    if (failed != 0) std.process.exit(1);
}

fn runCorpus(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *zwasm.Engine,
    root: *std.Io.Dir,
    name: []const u8,
    stdout: *std.Io.Writer,
    passed: *u32,
    failed: *u32,
    skipped: *u32,
    skipped_adr: *u32,
) !void {
    var dir = try root.openDir(io, name, .{});
    defer dir.close(io);

    const manifest_bytes = try dir.readFileAlloc(io, "manifest.txt", gpa, .limited(1 << 16));
    defer gpa.free(manifest_bytes);

    const cwd = std.Io.Dir.cwd();
    var current: Current = .none;
    var current_bytes: ?[]u8 = null;
    defer {
        deinitCurrent(gpa, &current);
        if (current_bytes) |b| gpa.free(b);
    }

    var line_it = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "skip-impl ")) {
            skipped.* += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "skip-adr-")) {
            skipped_adr.* += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "component_p2 ")) {
            const path = std.mem.trim(u8, line["component_p2 ".len..], " ");
            deinitCurrent(gpa, &current);
            if (current_bytes) |b| gpa.free(b);
            current_bytes = null;

            const bytes = cwd.readFileAlloc(io, path, gpa, .limited(8 << 20)) catch |err| {
                try stdout.print("FAIL  {s}: read '{s}': {s}\n", .{ name, path, @errorName(err) });
                failed.* += 1;
                continue;
            };
            current_bytes = bytes;

            const wh = try gpa.create(wasi_host.Host);
            wh.* = try wasi_host.Host.init(gpa);
            wh.io = io;
            const bc = host.buildWasiP2Component(engine, gpa, bytes, wh, .{}) catch |err| {
                wh.deinit();
                gpa.destroy(wh);
                try stdout.print("FAIL  {s}: buildWasiP2Component '{s}': {s}\n", .{ name, path, @errorName(err) });
                failed.* += 1;
                continue;
            };
            current = .{ .built = .{ .wh = wh, .bc = bc } };
            continue;
        }

        if (std.mem.startsWith(u8, line, "component ") or std.mem.startsWith(u8, line, "graph ")) {
            const is_graph = line[0] == 'g';
            const path = std.mem.trim(u8, line[if (is_graph) 6 else 10..], " ");
            // Reset prior fixture state before loading the next one.
            deinitCurrent(gpa, &current);
            if (current_bytes) |b| gpa.free(b);
            current_bytes = null;

            const bytes = cwd.readFileAlloc(io, path, gpa, .limited(8 << 20)) catch |err| {
                try stdout.print("FAIL  {s}: read '{s}': {s}\n", .{ name, path, @errorName(err) });
                failed.* += 1;
                continue;
            };
            current_bytes = bytes;

            if (is_graph) {
                const g = host.instantiateGraph(engine, gpa, bytes, .{}) catch |err| {
                    try stdout.print("FAIL  {s}: instantiateGraph '{s}': {s}\n", .{ name, path, @errorName(err) });
                    failed.* += 1;
                    continue;
                };
                current = .{ .graph = g };
            } else {
                const ci = host.instantiate(engine, gpa, bytes, .{}) catch |err| {
                    try stdout.print("FAIL  {s}: instantiate '{s}': {s}\n", .{ name, path, @errorName(err) });
                    failed.* += 1;
                    continue;
                };
                current = .{ .single = ci };
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_string ")) {
            if (runAssertString(gpa, &current, line["assert_string ".len..])) |ok| {
                if (ok) {
                    passed.* += 1;
                    try stdout.print("PASS  {s}: {s}\n", .{ name, line });
                } else {
                    failed.* += 1;
                    try stdout.print("FAIL  {s}: {s} (mismatch)\n", .{ name, line });
                }
            } else |err| {
                failed.* += 1;
                try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_flat_i32 ")) {
            if (runAssertFlatI32(&current, line["assert_flat_i32 ".len..])) |ok| {
                if (ok) {
                    passed.* += 1;
                    try stdout.print("PASS  {s}: {s}\n", .{ name, line });
                } else {
                    failed.* += 1;
                    try stdout.print("FAIL  {s}: {s} (mismatch)\n", .{ name, line });
                }
            } else |err| {
                failed.* += 1;
                try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_typed ")) {
            if (runAssertTyped(gpa, &current, line["assert_typed ".len..], stdout, name)) |ok| {
                if (ok) {
                    passed.* += 1;
                    try stdout.print("PASS  {s}: {s}\n", .{ name, line });
                } else {
                    failed.* += 1;
                    try stdout.print("FAIL  {s}: {s} (mismatch)\n", .{ name, line });
                }
            } else |err| {
                failed.* += 1;
                try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
            }
            continue;
        }

        // `assert_invalid <path>` / `assert_malformed <path>`: the component
        // must be REJECTED by decode / decodeTypeInfo / validate (ADR-0176).
        // An error at any stage = pass; clean decode-through-validate = fail.
        if (std.mem.startsWith(u8, line, "assert_invalid ") or std.mem.startsWith(u8, line, "assert_malformed ")) {
            const sp = std.mem.findScalar(u8, line, ' ').?;
            const path = std.mem.trim(u8, line[sp + 1 ..], " ");
            const bytes = cwd.readFileAlloc(io, path, gpa, .limited(8 << 20)) catch |err| {
                try stdout.print("FAIL  {s}: read '{s}': {s}\n", .{ name, path, @errorName(err) });
                failed.* += 1;
                continue;
            };
            defer gpa.free(bytes);
            if (decodeValidate(gpa, bytes)) {
                try stdout.print("FAIL  {s}: {s} (accepted an invalid component)\n", .{ name, line });
                failed.* += 1;
            } else |err| {
                passed.* += 1;
                // The reject REASON is forensic gold: a case passing via an
                // unrelated decode gap (vs the real rule) reads differently.
                try stdout.print("PASS  {s}: {s} (rejected: {s})\n", .{ name, line, @errorName(err) });
            }
            continue;
        }

        try stdout.print("FAIL  {s}: unrecognised directive: {s}\n", .{ name, line });
        failed.* += 1;
    }
}

/// Decode → decodeTypeInfo → validate. Errors when the component is rejected at
/// any stage (the `assert_invalid` / `assert_malformed` success condition).
fn decodeValidate(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var decoded = try cdecode.decode(gpa, bytes);
    defer decoded.deinit(gpa);
    var info = try ctypes.decodeTypeInfo(gpa, &decoded);
    defer info.deinit();
    try cvalidate.validate(&info);
}

/// `assert_string <export> <arg> -> <expected>` — `<expected>` may
/// contain spaces (e.g. "Hello, zwasm!"); `<arg>` is a single token.
fn runAssertString(gpa: std.mem.Allocator, current: *Current, rest: []const u8) !bool {
    const arrow = std.mem.find(u8, rest, " -> ") orelse return error.BadDirective;
    const lhs = std.mem.trim(u8, rest[0..arrow], " ");
    const expected = rest[arrow + 4 ..];
    const sp = std.mem.findScalar(u8, lhs, ' ') orelse return error.BadDirective;
    const export_name = lhs[0..sp];
    const arg = std.mem.trim(u8, lhs[sp + 1 ..], " ");

    const ci = switch (current.*) {
        .single => |*c| c,
        else => return error.NoComponent,
    };
    const result = try ci.invokeStringExport(export_name, arg, gpa);
    defer gpa.free(result);
    return std.mem.eql(u8, result, expected);
}

/// Drop the active fixture (and its WASI host, for `component_p2`).
fn deinitCurrent(gpa: std.mem.Allocator, current: *Current) void {
    switch (current.*) {
        .none => {},
        .single => |*ci| ci.deinit(),
        .graph => |*g| g.deinit(),
        .built => |*b| {
            b.bc.deinit();
            b.wh.deinit();
            gpa.destroy(b.wh);
        },
    }
    current.* = .none;
}

/// `assert_typed <export> (<value>, ..) -> <expected>` — parse each arg
/// against the export's WIT param type (from the self-describing binary),
/// invoke TYPED, render the result canonically, compare text.
fn runAssertTyped(
    gpa: std.mem.Allocator,
    current: *Current,
    rest: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !bool {
    const arrow = std.mem.find(u8, rest, " -> ") orelse return error.BadDirective;
    const lhs = std.mem.trim(u8, rest[0..arrow], " ");
    const expected = std.mem.trim(u8, rest[arrow + 4 ..], " ");
    const sp = std.mem.findScalar(u8, lhs, ' ') orelse return error.BadDirective;
    const export_name = lhs[0..sp];
    const args_text = std.mem.trim(u8, lhs[sp + 1 ..], " ");
    if (args_text.len < 2 or args_text[0] != '(' or args_text[args_text.len - 1] != ')')
        return error.BadDirective;
    const inner = args_text[1 .. args_text.len - 1];

    const info: *const ctypes.TypeInfo = switch (current.*) {
        .single => |*c| &c.info,
        .built => |*b| &b.bc.info,
        else => return error.NoComponent,
    };
    const ft = info.resolveFuncType(export_name) orelse return error.ExportNotResolved;

    // Arena owns the parsed args AND the invoke result — dropped wholesale.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const args = try a.alloc(ComponentValue, ft.params.len);
    var pos: usize = 0;
    for (ft.params, args, 0..) |param, *slot, i| {
        skipWs(inner, &pos);
        if (i != 0) {
            try expectChar(inner, &pos, ',');
            skipWs(inner, &pos);
        }
        const ct = try canon.canonTypeFromDecoded(a, info, param.ty);
        slot.* = try parseTypedValue(a, inner, &pos, ct);
    }
    skipWs(inner, &pos);
    if (pos != inner.len) return error.BadDirective;

    const out = switch (current.*) {
        .single => |*c| try c.invokeTyped(export_name, args, a),
        .built => |*b| try host.invokeTypedBuilt(&b.bc, export_name, args, a),
        else => unreachable,
    };

    var rendered: std.ArrayList(u8) = .empty;
    if (out) |o| try renderValue(a, &rendered, o);
    const ok = std.mem.eql(u8, rendered.items, expected);
    if (!ok) try stdout.print("      {s}: actual = {s}\n", .{ corpus_name, rendered.items });
    return ok;
}

// ---- typed value text: parser (CanonType-driven) + canonical renderer ----

fn skipWs(text: []const u8, pos: *usize) void {
    while (pos.* < text.len and (text[pos.*] == ' ' or text[pos.*] == '\t')) pos.* += 1;
}

fn expectChar(text: []const u8, pos: *usize, c: u8) !void {
    if (pos.* >= text.len or text[pos.*] != c) return error.BadValue;
    pos.* += 1;
}

/// Consume `c` if present; report whether it was.
fn consumeChar(text: []const u8, pos: *usize, c: u8) bool {
    if (pos.* < text.len and text[pos.*] == c) {
        pos.* += 1;
        return true;
    }
    return false;
}

/// kebab-case identifier (field / case names, `true`/`false`, `none`).
fn parseIdent(text: []const u8, pos: *usize) ![]const u8 {
    const start = pos.*;
    while (pos.* < text.len) : (pos.* += 1) {
        const c = text[pos.*];
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) break;
    }
    if (pos.* == start) return error.BadValue;
    return text[start..pos.*];
}

/// Bare numeric token (until a delimiter); base prefixes via parseInt base-0.
fn numberToken(text: []const u8, pos: *usize) ![]const u8 {
    const start = pos.*;
    while (pos.* < text.len) : (pos.* += 1) {
        const c = text[pos.*];
        if (c == ',' or c == ')' or c == ']' or c == '}' or c == ' ' or c == '\t') break;
    }
    if (pos.* == start) return error.BadValue;
    return text[start..pos.*];
}

fn parseIntToken(comptime T: type, text: []const u8, pos: *usize) !T {
    return std.fmt.parseInt(T, try numberToken(text, pos), 0);
}

/// `"…"` with \\ \" \n \t \r escapes; result is arena-owned.
fn parseStringLit(a: std.mem.Allocator, text: []const u8, pos: *usize) ![]const u8 {
    try expectChar(text, pos, '"');
    var out: std.ArrayList(u8) = .empty;
    while (pos.* < text.len) {
        const c = text[pos.*];
        pos.* += 1;
        if (c == '"') return out.toOwnedSlice(a);
        if (c == '\\') {
            if (pos.* >= text.len) return error.BadValue;
            const e = text[pos.*];
            pos.* += 1;
            try out.append(a, switch (e) {
                '\\' => '\\',
                '"' => '"',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => return error.BadValue,
            });
        } else {
            try out.append(a, c);
        }
    }
    return error.BadValue; // unterminated
}

/// `'c'` (one Unicode scalar; same escapes as strings).
fn parseCharLit(text: []const u8, pos: *usize) !u21 {
    try expectChar(text, pos, '\'');
    if (pos.* >= text.len) return error.BadValue;
    var cp: u21 = undefined;
    if (text[pos.*] == '\\') {
        pos.* += 1;
        if (pos.* >= text.len) return error.BadValue;
        cp = switch (text[pos.*]) {
            '\\' => '\\',
            '\'' => '\'',
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            else => return error.BadValue,
        };
        pos.* += 1;
    } else {
        const len = std.unicode.utf8ByteSequenceLength(text[pos.*]) catch return error.BadValue;
        if (pos.* + len > text.len) return error.BadValue;
        const view = std.unicode.Utf8View.init(text[pos.* .. pos.* + len]) catch return error.BadValue;
        var cp_it = view.iterator();
        cp = cp_it.nextCodepoint() orelse return error.BadValue;
        pos.* += len;
    }
    try expectChar(text, pos, '\'');
    return cp;
}

/// Parse one value at `pos` against its WIT (despecialized) type. Records
/// require declared field order; despecialized tuples (all-empty field
/// names) use positional `(v, v)`; variant/option/result go by case name.
fn parseTypedValue(a: std.mem.Allocator, text: []const u8, pos: *usize, ct: canon.CanonType) anyerror!ComponentValue {
    skipWs(text, pos);
    switch (ct) {
        // Resource handles: bare integers `own<N>` semantics don't apply to
        // manifest text — parse as a plain handle number.
        .own => return .{ .own = try parseIntToken(u32, text, pos) },
        .borrow => return .{ .borrow = try parseIntToken(u32, text, pos) },
        .prim => |p| switch (p) {
            .bool => {
                const id = try parseIdent(text, pos);
                if (std.mem.eql(u8, id, "true")) return .{ .bool = true };
                if (std.mem.eql(u8, id, "false")) return .{ .bool = false };
                return error.BadValue;
            },
            .s8 => return .{ .s8 = try parseIntToken(i8, text, pos) },
            .u8 => return .{ .u8 = try parseIntToken(u8, text, pos) },
            .s16 => return .{ .s16 = try parseIntToken(i16, text, pos) },
            .u16 => return .{ .u16 = try parseIntToken(u16, text, pos) },
            .s32 => return .{ .s32 = try parseIntToken(i32, text, pos) },
            .u32 => return .{ .u32 = try parseIntToken(u32, text, pos) },
            .s64 => return .{ .s64 = try parseIntToken(i64, text, pos) },
            .u64 => return .{ .u64 = try parseIntToken(u64, text, pos) },
            .f32 => return .{ .f32 = try std.fmt.parseFloat(f32, try numberToken(text, pos)) },
            .f64 => return .{ .f64 = try std.fmt.parseFloat(f64, try numberToken(text, pos)) },
            .char => return .{ .char = try parseCharLit(text, pos) },
            .string => return .{ .string = try parseStringLit(a, text, pos) },
            .error_context => return error.BadValue,
        },
        .enum_ => |n| {
            const v = try parseIntToken(u32, text, pos);
            if (v >= n) return error.BadValue;
            return .{ .@"enum" = .{ .index = v } };
        },
        .flags => |n| {
            const v = try parseIntToken(u32, text, pos);
            if (n < 32 and v >= (@as(u32, 1) << @intCast(n))) return error.BadValue;
            return .{ .flags = .{ .bits = v } };
        },
        .list => |elem| {
            try expectChar(text, pos, '[');
            var items: std.ArrayList(ComponentValue) = .empty;
            skipWs(text, pos);
            if (!consumeChar(text, pos, ']')) {
                while (true) {
                    try items.append(a, try parseTypedValue(a, text, pos, elem.*));
                    skipWs(text, pos);
                    if (consumeChar(text, pos, ',')) continue;
                    try expectChar(text, pos, ']');
                    break;
                }
            }
            return .{ .list = try items.toOwnedSlice(a) };
        },
        .record => |fields| {
            if (fields.len > 0 and fields[0].name.len == 0) {
                // Despecialized tuple — positional.
                try expectChar(text, pos, '(');
                const out = try a.alloc(ComponentValue, fields.len);
                for (fields, out, 0..) |f, *slot, i| {
                    skipWs(text, pos);
                    if (i != 0) {
                        try expectChar(text, pos, ',');
                        skipWs(text, pos);
                    }
                    slot.* = try parseTypedValue(a, text, pos, f.ty);
                }
                skipWs(text, pos);
                try expectChar(text, pos, ')');
                return .{ .tuple = out };
            }
            try expectChar(text, pos, '{');
            const out = try a.alloc(ComponentValue.Field, fields.len);
            for (fields, out, 0..) |f, *slot, i| {
                skipWs(text, pos);
                if (i != 0) {
                    try expectChar(text, pos, ',');
                    skipWs(text, pos);
                }
                const ident = try parseIdent(text, pos);
                if (!std.mem.eql(u8, ident, f.name)) return error.BadValue;
                skipWs(text, pos);
                try expectChar(text, pos, ':');
                slot.* = .{ .name = f.name, .value = try parseTypedValue(a, text, pos, f.ty) };
            }
            skipWs(text, pos);
            try expectChar(text, pos, '}');
            return .{ .record = out };
        },
        .variant => |cases| {
            const ident = try parseIdent(text, pos);
            for (cases, 0..) |c, i| {
                if (!std.mem.eql(u8, c.name, ident)) continue;
                var payload: ?*ComponentValue = null;
                if (c.payload) |pt| {
                    try expectChar(text, pos, '(');
                    const slot = try a.create(ComponentValue);
                    slot.* = try parseTypedValue(a, text, pos, pt);
                    skipWs(text, pos);
                    try expectChar(text, pos, ')');
                    payload = slot;
                }
                return .{ .variant = .{ .case = @intCast(i), .payload = payload } };
            }
            return error.BadValue;
        },
        // stream/future values are async handles, not manifest-text literals
        // (no P3 corpus exercises them as assert values yet).
        .stream, .future => return error.BadValue,
    }
}

/// Render `v` in the canonical text form `parseTypedValue` reads (the
/// directive's expected side is compared against exactly this output).
fn renderValue(a: std.mem.Allocator, out: *std.ArrayList(u8), v: ComponentValue) anyerror!void {
    switch (v) {
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        inline .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64 => |x| {
            try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{x}));
        },
        .char => |cp| {
            try out.append(a, '\'');
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadValue;
            try out.appendSlice(a, buf[0..n]);
            try out.append(a, '\'');
        },
        .string => |s| {
            try out.append(a, '"');
            for (s) |c| switch (c) {
                '\\' => try out.appendSlice(a, "\\\\"),
                '"' => try out.appendSlice(a, "\\\""),
                '\n' => try out.appendSlice(a, "\\n"),
                '\t' => try out.appendSlice(a, "\\t"),
                '\r' => try out.appendSlice(a, "\\r"),
                else => try out.append(a, c),
            };
            try out.append(a, '"');
        },
        .list => |items| {
            try out.append(a, '[');
            for (items, 0..) |item, i| {
                if (i != 0) try out.appendSlice(a, ", ");
                try renderValue(a, out, item);
            }
            try out.append(a, ']');
        },
        .tuple => |items| {
            try out.append(a, '(');
            for (items, 0..) |item, i| {
                if (i != 0) try out.appendSlice(a, ", ");
                try renderValue(a, out, item);
            }
            try out.append(a, ')');
        },
        .record => |fields| {
            try out.append(a, '{');
            for (fields, 0..) |f, i| {
                if (i != 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, f.name);
                try out.appendSlice(a, ": ");
                try renderValue(a, out, f.value);
            }
            try out.append(a, '}');
        },
        // `ComponentValue` carries case ORDINALS only (names live in the
        // type); option/result re-specialize so their names are structural.
        .variant => |vr| {
            try out.appendSlice(a, try std.fmt.allocPrint(a, "variant<{d}>", .{vr.case}));
            if (vr.payload) |p| {
                try out.append(a, '(');
                try renderValue(a, out, p.*);
                try out.append(a, ')');
            }
        },
        .@"enum" => |c| try out.appendSlice(a, try std.fmt.allocPrint(a, "enum<{d}>", .{c.index})),
        .option => |opt| {
            if (opt) |p| {
                try out.appendSlice(a, "some(");
                try renderValue(a, out, p.*);
                try out.append(a, ')');
            } else {
                try out.appendSlice(a, "none");
            }
        },
        .result => |r| {
            try out.appendSlice(a, if (r.is_ok) "ok" else "err");
            if (r.payload) |p| {
                try out.append(a, '(');
                try renderValue(a, out, p.*);
                try out.append(a, ')');
            }
        },
        .flags => |f| try out.appendSlice(a, try std.fmt.allocPrint(a, "flags<0x{x}>", .{f.bits})),
        .own => |h| try out.appendSlice(a, try std.fmt.allocPrint(a, "own<{d}>", .{h})),
        .borrow => |h| try out.appendSlice(a, try std.fmt.allocPrint(a, "borrow<{d}>", .{h})),
    }
}

/// `assert_flat_i32 <export> <i32-arg>* -> <i32>` — invoke a flat
/// export with i32 args and compare `results[0].i32`.
fn runAssertFlatI32(current: *Current, rest: []const u8) !bool {
    const arrow = std.mem.find(u8, rest, " -> ") orelse return error.BadDirective;
    const lhs = std.mem.trim(u8, rest[0..arrow], " ");
    const expected = try std.fmt.parseInt(i32, std.mem.trim(u8, rest[arrow + 4 ..], " "), 10);

    var arg_it = std.mem.tokenizeScalar(u8, lhs, ' ');
    const export_name = arg_it.next() orelse return error.BadDirective;
    var args: [host.MAX_FLAT_PARAMS]Value = undefined;
    var n: usize = 0;
    while (arg_it.next()) |tok| : (n += 1) {
        if (n >= args.len) return error.TooManyArgs;
        args[n] = .{ .i32 = try std.fmt.parseInt(i32, tok, 10) };
    }

    var results = [_]Value{.{ .i32 = 0 }};
    switch (current.*) {
        // A graph re-exports the linked child's flat func; a single
        // component exposes the lowered core export directly.
        .graph => |*g| try g.invokeFlat(export_name, args[0..n], results[0..1]),
        .single => |*c| try c.invokeCore(export_name, args[0..n], results[0..1]),
        else => return error.NoComponent,
    }
    return results[0].i32 == expected;
}
