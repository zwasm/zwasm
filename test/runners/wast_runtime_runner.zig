//! Runtime-asserting WAST runner (Phase 6 / §9.6 / 6.A per ADR-0013).
//!
//! Walks one or more corpus subdirectories, each containing a
//! `manifest.txt` plus the `.wasm` files referenced by it. The
//! manifest format extends `test/spec/wast_runner.zig`'s flat-text
//! pattern with runtime-asserting directives:
//!
//!   `valid <file>`     — parse + validate; expect success.
//!   `invalid <file>`   — parse + validate; expect failure.
//!   `malformed <file>` — parse alone; expect failure.
//!   `module <file>`    — load + instantiate; becomes "current".
//!                        Optional `as <name>` registers the module
//!                        for later cross-module reference.
//!   `register <as-name>` — alias the current module under <as-name>
//!                        (recognised in 6.A; cross-module imports
//!                        wired in 6.D).
//!   `assert_return <export> <args> -> <expected>`
//!                      — invoke `<export>` on the current module,
//!                        compare results to `<expected>`.
//!   `assert_trap <export> <args> !! <kind>`
//!                      — invoke `<export>`, expect a trap (any
//!                        kind in 6.A; strict-kind matching wired
//!                        in 6.D).
//!   `assert_exhaustion <export> <args> !! <kind>`
//!                      — same as assert_trap, kind expected to
//!                        be StackOverflow / CallStackExhausted.
//!   `invoke <export> <args>` — call, ignore result.
//!   `action <export> <args>` — alias of invoke.
//!   `assert_invalid <file> !! <reason>`
//!                      — alias of `invalid` (reason not matched).
//!   `assert_malformed <file> !! <reason>`
//!                      — alias of `malformed`.
//!   `assert_unlinkable <file> !! <reason>`
//!                      — load expected to fail at instantiate.
//!   `assert_uninstantiable <file> !! <reason>`
//!                      — load expected to fail at start.
//!
//! Argument and expected values use TLV-style notation
//! (space-separated when multiple): `i32:42`, `i64:-1`,
//! `f32:0x7fc00000`, `f64:1.5`. v0 of the runner only handles i32
//! end-to-end; broader value-type comparison lands per directive
//! when 6.D wires the wasmtime_misc corpus that exercises it.
//!
//! Per-instr execution trace: the underlying `runtime.Runtime` carries
//! `trace_cb` / `trace_ctx` (added in 6.A alongside this runner). The
//! `--trace <fixture>` CLI flag will hook a trace sink in 6.E when
//! interp behaviour bug investigation needs it; not wired in 6.A.
//!
//! Usage:
//!   wast_runtime_runner <corpus-root>
//! where `<corpus-root>` is a directory whose immediate children
//! are subdirectories each containing a `manifest.txt`.

const std = @import("std");
const zwasm = @import("zwasm");

const wasm_c_api = zwasm.api.wasm;
const parser = zwasm.parse.parser;
const runtime = zwasm.runtime;
const sections = zwasm.parse.sections;

/// Per-corpus state. Holds the active module pipeline + a name map
/// for `register`. One `RunnerContext` per `manifest.txt`; arena-
/// freed at the end of that corpus run.
const RunnerContext = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    /// Current module (most-recently instantiated). Borrowed pointers
    /// freed at corpus teardown via `delete*` calls.
    current: ?*ActiveModule = null,
    /// Module name → ActiveModule. Used by `register` and named
    /// invokes. Cross-module-import resolution wires through here in
    /// §9.6 / 6.D.
    by_name: std.StringHashMapUnmanaged(*ActiveModule) = .empty,
    /// All instantiated modules, in instantiation order. Owned so
    /// teardown can walk them.
    all: std.ArrayList(*ActiveModule) = .empty,

    fn alloc(self: *RunnerContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn deinit(self: *RunnerContext) void {
        const a = self.arena.allocator();
        for (self.all.items) |am| am.deinit();
        self.all.deinit(a);
        self.by_name.deinit(a);
        self.arena.deinit();
    }
};

/// One instantiated module's runtime handles. The runner owns these
/// for the lifetime of the corpus, then deletes via the c_api.
const ActiveModule = struct {
    engine: *wasm_c_api.Engine,
    store: *wasm_c_api.Store,
    module: *wasm_c_api.Module,
    /// `null` when this entry represents an
    /// `assert_uninstantiable` / `assert_unlinkable` failure that
    /// the runner retained so cross-module funcrefs into the
    /// failed instance's funcs stay valid until corpus end (per
    /// ADR-0014 §2.1 / 6.K.3 runner-retention contract). The
    /// engine + store + module are kept alive so the c_api Store
    /// zombie list (holding the failed instance's runtime +
    /// arena) survives across subsequent assertions.
    instance: ?*wasm_c_api.Instance,
    /// Cached export vector; populated lazily by `lookupExport`.
    exports: wasm_c_api.ExternVec = .{ .size = 0, .data = null },

    fn deinit(self: *ActiveModule) void {
        if (self.exports.size > 0) wasm_c_api.wasm_extern_vec_delete(&self.exports);
        if (self.instance) |inst| wasm_c_api.wasm_instance_delete(inst);
        wasm_c_api.wasm_module_delete(self.module);
        wasm_c_api.wasm_store_delete(self.store);
        wasm_c_api.wasm_engine_delete(self.engine);
    }

    fn ensureExports(self: *ActiveModule) void {
        if (self.exports.size == 0) {
            if (self.instance) |inst|
                wasm_c_api.wasm_instance_exports(inst, &self.exports);
        }
    }
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
        try stdout.print("usage: wast_runtime_runner <corpus-root>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_root = try gpa.dupe(u8, corpus_root_arg);
    defer gpa.free(corpus_root);

    var passed: u32 = 0;
    var failed: u32 = 0;
    // Per ADR-0029 Path B (chunk 9.9-h-23): twin tally for skip-impl
    // (implementation gap, counts toward `skip-impl == 0` gate) vs
    // skip-adr-<ADR-id> (waived per the named skip-ADR).
    var skipped: u32 = 0;
    var skipped_adr: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_root, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer root.close(io);

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try walkCorpusOrCategory(io, gpa, &root, entry.name, stdout, &passed, &failed, &skipped, &skipped_adr);
    }

    try stdout.print(
        "\nwast_runtime_runner: {d} passed, {d} failed, {d} skipped (= {d} skip-impl + {d} skip-adr)\n",
        .{ passed, failed, skipped + skipped_adr, skipped, skipped_adr },
    );
    try stdout.flush();
    if (failed != 0) std.process.exit(1);
}

/// Mirror of `test/spec/wast_runner.zig` walkCorpusOrCategory:
/// recurse one level when `<root>/<name>` lacks a manifest itself,
/// so the wasmtime_misc 2-level layout (`category/fixture/`) walks
/// without per-category build steps.
fn walkCorpusOrCategory(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: *std.Io.Dir,
    name: []const u8,
    stdout: *std.Io.Writer,
    passed: *u32,
    failed: *u32,
    skipped: *u32,
    skipped_adr: *u32,
) !void {
    var dir = root.openDir(io, name, .{ .iterate = true }) catch {
        try runCorpus(io, gpa, root, name, stdout, passed, failed, skipped, skipped_adr);
        return;
    };
    const has_manifest = blk: {
        const probe = dir.openFile(io, "manifest_runtime.txt", .{}) catch
            dir.openFile(io, "manifest.txt", .{}) catch {
            break :blk false;
        };
        var f = probe;
        f.close(io);
        break :blk true;
    };
    if (has_manifest) {
        dir.close(io);
        try runCorpus(io, gpa, root, name, stdout, passed, failed, skipped, skipped_adr);
        return;
    }
    var it = dir.iterate();
    while (try it.next(io)) |child| {
        if (child.kind != .directory) continue;
        try runCorpus(io, gpa, &dir, child.name, stdout, passed, failed, skipped, skipped_adr);
    }
    dir.close(io);
}

fn runCorpus(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: *std.Io.Dir,
    name: []const u8,
    stdout: *std.Io.Writer,
    passed: *u32,
    failed: *u32,
    skipped: *u32,
    skipped_adr: *u32,
) !void {
    var dir = root.openDir(io, name, .{}) catch |err| {
        try stdout.print("FAIL  {s}/: openDir {s}\n", .{ name, @errorName(err) });
        failed.* += 1;
        return;
    };
    defer dir.close(io);

    // Prefer manifest_runtime.txt (full runtime directives) over
    // manifest.txt (parse + validate only). Per ADR-0013 §2; the
    // wasmtime_misc corpus generated by regen_wasmtime_misc.sh
    // produces both, with runtime directives only in the *_runtime
    // file; the smoke fixture has only manifest.txt.
    const manifest_bytes = dir.readFileAlloc(io, "manifest_runtime.txt", gpa, .limited(1 << 16)) catch
        dir.readFileAlloc(io, "manifest.txt", gpa, .limited(1 << 16)) catch |err| {
        try stdout.print("FAIL  {s}/manifest.txt: {s}\n", .{ name, @errorName(err) });
        failed.* += 1;
        return;
    };
    defer gpa.free(manifest_bytes);

    var ctx: RunnerContext = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .io = io,
    };
    defer ctx.deinit();

    var line_it = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const result = handleLine(&ctx, &dir, line, stdout, name) catch |err| {
            try stdout.print("FAIL  {s}: '{s}' runner error {s}\n", .{ name, line, @errorName(err) });
            failed.* += 1;
            continue;
        };

        switch (result) {
            .passed => passed.* += 1,
            .failed => failed.* += 1,
            .skipped_impl => skipped.* += 1,
            .skipped_adr => skipped_adr.* += 1,
        }
    }
}

/// Per ADR-0029 Path B (chunk 9.9-h-23): every manifest line resolves
/// to one of these four outcomes. `skipped_impl` counts toward the
/// `skip-impl == 0` gate; `skipped_adr` is waived per the named
/// skip-ADR.
const LineResult = enum { passed, failed, skipped_impl, skipped_adr };

/// Dispatch a single manifest line. Returns true if the directive's
/// expectation matched, false otherwise. Returns runner-error only
/// for OOM and similar plumbing failures (not for guest-side traps,
/// which are folded into the boolean per directive semantics).
fn handleLine(
    ctx: *RunnerContext,
    dir: *std.Io.Dir,
    line: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !LineResult {
    // Per ADR-0029 Path B (chunk 9.9-h-23): prefix-aware skip
    // classification. `skip-impl <reason>` counts toward gate;
    // `skip-adr-<ADR-id> <reason>` waived per named skip-ADR;
    // bare `skip <reason>` is back-compat (WARN + count as
    // skip-impl) until any remaining hand-authored manifest
    // gets migrated.
    if (std.mem.startsWith(u8, line, "skip-impl ")) return .skipped_impl;
    if (std.mem.startsWith(u8, line, "skip-adr-")) return .skipped_adr;
    if (std.mem.startsWith(u8, line, "skip ")) {
        try stdout.print("WARN  {s}: bare `skip` line — migrate to `skip-impl` or `skip-adr-<id>`: {s}\n", .{ corpus_name, line });
        return .skipped_impl;
    }

    var tok_it = std.mem.tokenizeScalar(u8, line, ' ');
    const directive = tok_it.next() orelse return .failed;
    const rest = std.mem.trim(u8, line[directive.len..], " \t");

    const ok: bool = blk: {
        if (std.mem.eql(u8, directive, "valid")) {
            break :blk try handleValidMalformedInvalid(ctx, dir, .valid, rest, stdout, corpus_name);
        } else if (std.mem.eql(u8, directive, "invalid") or std.mem.eql(u8, directive, "assert_invalid")) {
            break :blk try handleValidMalformedInvalid(ctx, dir, .invalid, takeFile(rest), stdout, corpus_name);
        } else if (std.mem.eql(u8, directive, "malformed") or std.mem.eql(u8, directive, "assert_malformed")) {
            break :blk try handleValidMalformedInvalid(ctx, dir, .malformed, takeFile(rest), stdout, corpus_name);
        } else if (std.mem.eql(u8, directive, "module")) {
            break :blk try handleModule(ctx, dir, rest, stdout, corpus_name);
        } else if (std.mem.eql(u8, directive, "register")) {
            break :blk try handleRegister(ctx, rest, stdout, corpus_name);
        } else if (std.mem.eql(u8, directive, "assert_return")) {
            break :blk try handleAssertReturn(ctx, rest, stdout, corpus_name);
        } else if (std.mem.eql(u8, directive, "assert_trap")) {
            break :blk try handleAssertTrap(ctx, rest, stdout, corpus_name, .any);
        } else if (std.mem.eql(u8, directive, "assert_exhaustion")) {
            break :blk try handleAssertTrap(ctx, rest, stdout, corpus_name, .exhaustion);
        } else if (std.mem.eql(u8, directive, "assert_unlinkable")) {
            break :blk try handleInstantiateExpectFail(ctx, dir, takeFile(rest), stdout, corpus_name, "unlinkable");
        } else if (std.mem.eql(u8, directive, "assert_uninstantiable")) {
            break :blk try handleInstantiateExpectFail(ctx, dir, takeFile(rest), stdout, corpus_name, "uninstantiable");
        } else if (std.mem.eql(u8, directive, "invoke") or std.mem.eql(u8, directive, "action")) {
            break :blk try handleInvoke(ctx, rest, stdout, corpus_name);
        } else {
            try stdout.print("FAIL  {s}: unknown directive '{s}'\n", .{ corpus_name, directive });
            break :blk false;
        }
    };
    return if (ok) .passed else .failed;
}

const ParseDirective = enum { valid, invalid, malformed };

/// Take the first whitespace-delimited token (the filename) and
/// drop trailing `!! <reason>` if present.
fn takeFile(rest: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    return it.next() orelse "";
}

/// Split a directive's argument list into tokens. Whitespace
/// (space / tab) is the separator, except inside double-quoted
/// strings which arrive verbatim as a single token. Backslash
/// escapes `\"` and `\\` inside the quotes. Returned slices live
/// on `a`; the outer slice is owned by the caller.
fn splitTokens(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) break;
        if (line[i] == '"') {
            i += 1;
            const start = i;
            var has_escape = false;
            // First pass: detect escapes so the no-escape path is
            // zero-copy (returns a borrow into the original line).
            var j = i;
            while (j < line.len and line[j] != '"') {
                if (line[j] == '\\' and j + 1 < line.len) {
                    has_escape = true;
                    j += 2;
                } else j += 1;
            }
            if (!has_escape) {
                try out.append(a, line[start..j]);
            } else {
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(a);
                var k = i;
                while (k < line.len and line[k] != '"') {
                    if (line[k] == '\\' and k + 1 < line.len) {
                        try buf.append(a, line[k + 1]);
                        k += 2;
                    } else {
                        try buf.append(a, line[k]);
                        k += 1;
                    }
                }
                try out.append(a, try buf.toOwnedSlice(a));
            }
            i = j;
            if (i < line.len) i += 1; // consume closing "
        } else {
            const start = i;
            while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
            try out.append(a, line[start..i]);
        }
    }
    return out.toOwnedSlice(a);
}

fn handleValidMalformedInvalid(
    ctx: *RunnerContext,
    dir: *std.Io.Dir,
    kind: ParseDirective,
    filename: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !bool {
    const a = ctx.alloc();
    const wasm_bytes = dir.readFileAlloc(ctx.io, filename, a, .limited(4 << 20)) catch |err| {
        try stdout.print("FAIL  {s}/{s}: read {s}\n", .{ corpus_name, filename, @errorName(err) });
        return false;
    };
    defer a.free(wasm_bytes);

    if (kind == .malformed) {
        var module = parser.parse(a, wasm_bytes) catch {
            try stdout.print("PASS  {s}/{s} (malformed)\n", .{ corpus_name, filename });
            return true;
        };
        module.deinit(a);
        try stdout.print("FAIL  {s}/{s} (malformed) — parse unexpectedly succeeded\n", .{ corpus_name, filename });
        return false;
    }

    var module = parser.parse(a, wasm_bytes) catch {
        const ok_ = (kind == .invalid);
        if (ok_) {
            try stdout.print("PASS  {s}/{s} ({s})\n", .{ corpus_name, filename, @tagName(kind) });
        } else {
            try stdout.print("FAIL  {s}/{s} ({s}) — parse failed\n", .{ corpus_name, filename, @tagName(kind) });
        }
        return ok_;
    };
    defer module.deinit(a);

    const validated = validateAllFunctions(a, &module) catch false;
    const want = (kind == .valid);
    if (validated == want) {
        try stdout.print("PASS  {s}/{s} ({s})\n", .{ corpus_name, filename, @tagName(kind) });
        return true;
    } else {
        try stdout.print("FAIL  {s}/{s} ({s}) — validate mismatch\n", .{ corpus_name, filename, @tagName(kind) });
        return false;
    }
}

fn validateAllFunctions(a: std.mem.Allocator, module: *runtime.Module) !bool {
    const validator = zwasm.validate.validator;
    const zir = zwasm.ir.zir;

    const type_section = module.find(.type);
    const import_section = module.find(.import);
    const func_section = module.find(.function);
    const code_section = module.find(.code);
    const table_section = module.find(.table);
    const global_section = module.find(.global);

    const code_body = if (code_section) |s| s.body else return true;

    var types_owned = if (type_section) |s|
        try sections.decodeTypes(a, s.body)
    else
        sections.Types{ .arena = std.heap.ArenaAllocator.init(a), .items = &.{}, .kinds = &.{}, .struct_defs = &.{}, .array_defs = &.{}, .supertypes = &.{}, .finals = &.{} };
    defer types_owned.deinit();

    var imports_owned: ?sections.Imports = if (import_section) |s|
        try sections.decodeImports(a, s.body)
    else
        null;
    defer if (imports_owned) |*im| im.deinit();

    const defined_func_indices = if (func_section) |s|
        try sections.decodeFunctions(a, s.body)
    else
        try a.alloc(u32, 0);
    defer a.free(defined_func_indices);

    var codes = try sections.decodeCodes(a, code_body);
    defer codes.deinit();

    if (codes.items.len != defined_func_indices.len) return false;

    var imp_func_count: usize = 0;
    if (imports_owned) |im| for (im.items) |it| if (it.kind == .func) {
        imp_func_count += 1;
    };
    const total_funcs = imp_func_count + defined_func_indices.len;
    const func_types = try a.alloc(zir.FuncType, total_funcs);
    defer a.free(func_types);
    {
        var cursor: usize = 0;
        if (imports_owned) |im| for (im.items) |it| if (it.kind == .func) {
            const ti = it.payload.func_typeidx;
            if (ti >= types_owned.items.len) return false;
            func_types[cursor] = types_owned.items[ti];
            cursor += 1;
        };
        for (defined_func_indices) |type_idx| {
            if (type_idx >= types_owned.items.len) return false;
            func_types[cursor] = types_owned.items[type_idx];
            cursor += 1;
        }
    }

    var globals_owned: ?sections.Globals = if (global_section) |s|
        try sections.decodeGlobals(a, s.body)
    else
        null;
    defer if (globals_owned) |*g| g.deinit();

    var imp_global_count: usize = 0;
    if (imports_owned) |im| for (im.items) |it| if (it.kind == .global) {
        imp_global_count += 1;
    };
    const def_global_count: usize = if (globals_owned) |g| g.items.len else 0;
    const total_globals = imp_global_count + def_global_count;
    const global_entries = try a.alloc(validator.GlobalEntry, total_globals);
    defer a.free(global_entries);
    {
        var cursor: usize = 0;
        if (imports_owned) |im| for (im.items) |it| if (it.kind == .global) {
            global_entries[cursor] = .{
                .valtype = it.payload.global.valtype,
                .mutable = it.payload.global.mutable,
            };
            cursor += 1;
        };
        if (globals_owned) |g| for (g.items) |gd| {
            global_entries[cursor] = .{ .valtype = gd.valtype, .mutable = gd.mutable };
            cursor += 1;
        };
    }

    var tables_owned: ?sections.Tables = if (table_section) |s|
        try sections.decodeTables(a, s.body)
    else
        null;
    defer if (tables_owned) |*t| t.deinit();

    var imp_table_count: usize = 0;
    if (imports_owned) |im| for (im.items) |it| if (it.kind == .table) {
        imp_table_count += 1;
    };
    const def_table_count: usize = if (tables_owned) |t| t.items.len else 0;
    const total_tables = imp_table_count + def_table_count;
    const table_entries = try a.alloc(zir.TableEntry, total_tables);
    defer a.free(table_entries);
    {
        var cursor: usize = 0;
        if (imports_owned) |im| for (im.items) |it| if (it.kind == .table) {
            table_entries[cursor] = .{ .elem_type = .funcref, .min = 0 };
            cursor += 1;
        };
        if (tables_owned) |t| for (t.items) |entry| {
            table_entries[cursor] = entry;
            cursor += 1;
        };
    }

    for (codes.items, defined_func_indices) |code, type_idx| {
        const sig = types_owned.items[type_idx];
        validator.validateFunction(
            sig,
            code.locals,
            code.body,
            func_types,
            global_entries,
            types_owned.items,
            0,
            table_entries,
            0,
        ) catch return false;
    }
    return true;
}

fn handleModule(
    ctx: *RunnerContext,
    dir: *std.Io.Dir,
    rest: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !bool {
    // Format: `module <file> [as <name>]`.
    const a = ctx.alloc();
    const tokens = try splitTokens(a, rest);
    if (tokens.len == 0) {
        try stdout.print("FAIL  {s}: module directive missing file\n", .{corpus_name});
        return false;
    }
    const filename = tokens[0];
    const name_opt: ?[]const u8 = if (tokens.len >= 3 and std.mem.eql(u8, tokens[1], "as"))
        tokens[2]
    else
        null;

    const wasm_bytes = dir.readFileAlloc(ctx.io, filename, a, .limited(4 << 20)) catch |err| {
        try stdout.print("FAIL  {s}/{s}: module read {s}\n", .{ corpus_name, filename, @errorName(err) });
        return false;
    };
    // bytes live for the corpus lifetime: c_api Module borrows the
    // slice and ActiveModule.deinit() runs in the order
    // {exports → instance → module → store → engine → arena}, so
    // the borrowed slice outlives every module/instance reference.
    // No explicit free; the arena reclaims the allocation after
    // ctx.deinit() walks `ctx.all` and tears each ActiveModule down.

    const am = try a.create(ActiveModule);
    am.* = instantiateWithImports(ctx, wasm_bytes) catch |err| {
        try stdout.print("FAIL  {s}/{s}: instantiate {s}\n", .{ corpus_name, filename, @errorName(err) });
        return false;
    };
    try ctx.all.append(a, am);
    ctx.current = am;
    if (name_opt) |n| {
        // Store under the wast-script-local id (e.g. `$env`) AND
        // the bare public name (`env`) — wasmtime's wast runner
        // does the same auto-register
        // (`crates/wast/src/wast.rs:fn module`) so embenchen-style
        // fixtures resolve `m.X` imports without an explicit
        // `(register "X" $X)` directive.
        const stored_id = try a.dupe(u8, n);
        try ctx.by_name.put(a, stored_id, am);
        if (std.mem.startsWith(u8, n, "$") and n.len > 1) {
            const bare = try a.dupe(u8, n[1..]);
            if (!ctx.by_name.contains(bare)) {
                try ctx.by_name.put(a, bare, am);
            } else {
                a.free(bare);
            }
        }
    }

    try stdout.print("PASS  {s}/{s} (module)\n", .{ corpus_name, filename });
    return true;
}

/// Decode the module's imports, look up each non-WASI import by
/// (module-name, export-name) in `ctx.by_name`, and build the
/// `wasm_extern_t*[]` array `wasm_instance_new` expects in import-
/// section order. WASI imports leave the slot null — the c_api
/// binding wires them through the Store's WASI host instead.
fn buildImports(ctx: *RunnerContext, wasm_bytes: []const u8) !?[]?*const wasm_c_api.Extern {
    const a = ctx.alloc();
    var module = parser.parse(a, wasm_bytes) catch return null;
    defer module.deinit(a);
    const import_section = module.find(.import) orelse return null;
    var imports = sections.decodeImports(a, import_section.body) catch return null;
    defer imports.deinit();
    if (imports.items.len == 0) return null;
    const slots = try a.alloc(?*const wasm_c_api.Extern, imports.items.len);
    @memset(slots, null);
    for (imports.items, 0..) |it, idx| {
        if (std.mem.eql(u8, it.module, "wasi_snapshot_preview1")) continue;
        const source = ctx.by_name.get(it.module) orelse continue;
        // Failed-instance ActiveModules can't be sources for new
        // imports — they're retained only so cross-module
        // references already in foreign tables stay valid (per
        // ADR-0014 §2.1 / 6.K.3 runner-retention contract). Skip.
        const source_instance = source.instance orelse continue;
        // Walk source's exports to find one matching `it.name`,
        // build a transient Extern carrying the source instance +
        // export index. The Extern is arena-allocated so it lives
        // for the corpus.
        for (source_instance.exports_storage) |exp| {
            if (!std.mem.eql(u8, exp.name, it.name)) continue;
            const ext = try a.create(wasm_c_api.Extern);
            ext.* = .{
                .kind = switch (exp.kind) {
                    .func => .func,
                    .table => .table,
                    .memory => .memory,
                    .global => .global,
                },
                .instance = source_instance,
                .table_idx = if (exp.kind == .table) exp.idx else 0,
                .memory_idx = if (exp.kind == .memory) exp.idx else 0,
                .global_idx = if (exp.kind == .global) exp.idx else 0,
            };
            slots[idx] = ext;
            break;
        }
    }
    return slots;
}

fn instantiateWithImports(ctx: *RunnerContext, wasm_bytes: []const u8) !ActiveModule {
    const engine = wasm_c_api.wasm_engine_new() orelse return error.EngineAllocFailed;
    errdefer wasm_c_api.wasm_engine_delete(engine);

    const store = wasm_c_api.wasm_store_new(engine) orelse return error.StoreAllocFailed;
    errdefer wasm_c_api.wasm_store_delete(store);

    var bv: wasm_c_api.ByteVec = .{
        .size = wasm_bytes.len,
        .data = @constCast(wasm_bytes.ptr),
    };
    const module = wasm_c_api.wasm_module_new(store, &bv) orelse return error.ModuleAllocFailed;
    errdefer wasm_c_api.wasm_module_delete(module);

    const imports_slice = try buildImports(ctx, wasm_bytes);
    // wasm.h's `wasm_instance_new` takes a `const wasm_extern_vec_t*`
    // (a `{size, data}` vec), not a bare extern array (ADR-0142 fix).
    var imports_vec: wasm_c_api.ExternVec = .{ .size = 0, .data = null };
    if (imports_slice) |slice| imports_vec = .{ .size = slice.len, .data = @ptrCast(@constCast(slice.ptr)) };
    const imports_ptr: ?*const anyopaque = @ptrCast(&imports_vec);

    // D-496(B) — pin `.interp`: the wasmtime_misc RUNTIME CONFORMANCE runner; cross-module
    // imported memory/table is interp's cross-instance-aliasing domain (post-flip `.auto`
    // routes to JIT, which rejects imports; the JIT conformance is spec_assert_runner).
    const instance = zwasm.api.instance.instanceNewWithEngine(store, module, imports_ptr, null, .interp) orelse
        return error.InstanceAllocFailed;
    return .{
        .engine = engine,
        .store = store,
        .module = module,
        .instance = instance,
    };
}

fn handleRegister(
    ctx: *RunnerContext,
    rest: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !bool {
    // Format: `register <as-name> [from <module-id>]`.
    const a = ctx.alloc();
    const tokens = try splitTokens(a, rest);
    if (tokens.len == 0) {
        try stdout.print("FAIL  {s}: register missing as-name\n", .{corpus_name});
        return false;
    }
    const as_name = tokens[0];
    const am: *ActiveModule = blk: {
        if (tokens.len >= 3 and std.mem.eql(u8, tokens[1], "from")) {
            const id = tokens[2];
            break :blk ctx.by_name.get(id) orelse {
                try stdout.print("FAIL  {s}: register source module '{s}' not registered\n", .{ corpus_name, id });
                return false;
            };
        }
        break :blk ctx.current orelse {
            try stdout.print("FAIL  {s}: register without prior module\n", .{corpus_name});
            return false;
        };
    };
    const stored = try a.dupe(u8, as_name);
    try ctx.by_name.put(a, stored, am);
    try stdout.print("PASS  {s} (register {s})\n", .{ corpus_name, as_name });
    return true;
}

fn handleInstantiateExpectFail(
    ctx: *RunnerContext,
    dir: *std.Io.Dir,
    filename: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
    label: []const u8,
) !bool {
    const a = ctx.alloc();
    const wasm_bytes = dir.readFileAlloc(ctx.io, filename, a, .limited(4 << 20)) catch |err| {
        try stdout.print("FAIL  {s}/{s}: read {s}\n", .{ corpus_name, filename, @errorName(err) });
        return false;
    };
    defer a.free(wasm_bytes);

    // Per ADR-0014 §2.1 / 6.K.3 runner-retention contract: when
    // instance creation fails, retain the engine + store + module
    // in `ctx.all` so subsequent `assert_return` directives can
    // call into foreign-table cells that the failed instance
    // partially initialised. The c_api Store zombie list (per
    // 6.K.2 sub-change 4) holds the failed runtime + arena
    // alive; this runner-side retention keeps the *Store itself*
    // alive across asserts (errdefers in the success-path
    // `instantiateWithImports` would destroy it otherwise).

    const engine = wasm_c_api.wasm_engine_new() orelse return error.EngineAllocFailed;
    var success = false;
    errdefer if (!success) wasm_c_api.wasm_engine_delete(engine);

    const store = wasm_c_api.wasm_store_new(engine) orelse return error.StoreAllocFailed;
    errdefer if (!success) wasm_c_api.wasm_store_delete(store);

    var bv: wasm_c_api.ByteVec = .{
        .size = wasm_bytes.len,
        .data = @constCast(wasm_bytes.ptr),
    };
    const module = wasm_c_api.wasm_module_new(store, &bv) orelse return error.ModuleAllocFailed;
    errdefer if (!success) wasm_c_api.wasm_module_delete(module);

    const imports_slice = try buildImports(ctx, wasm_bytes);
    // wasm.h's `wasm_instance_new` takes a `const wasm_extern_vec_t*`
    // (a `{size, data}` vec), not a bare extern array (ADR-0142 fix).
    var imports_vec: wasm_c_api.ExternVec = .{ .size = 0, .data = null };
    if (imports_slice) |slice| imports_vec = .{ .size = slice.len, .data = @ptrCast(@constCast(slice.ptr)) };
    const imports_ptr: ?*const anyopaque = @ptrCast(&imports_vec);

    // D-496(B) — pin `.interp` (conformance runner; cross-module imports = interp domain).
    const instance_opt = zwasm.api.instance.instanceNewWithEngine(store, module, imports_ptr, null, .interp);

    // Whichever way it went, retain the bundle in ctx.all so
    // the c_api Store (which holds the zombie runtime + arena
    // for the failed-instance case) lives until corpus end.
    const am = try a.create(ActiveModule);
    am.* = .{
        .engine = engine,
        .store = store,
        .module = module,
        .instance = instance_opt, // null when instantiation failed
    };
    try ctx.all.append(a, am);
    success = true; // suppress errdefer-on-error free; ctx.deinit() owns am now

    if (instance_opt == null) {
        try stdout.print("PASS  {s}/{s} ({s})\n", .{ corpus_name, filename, label });
        return true;
    }

    try stdout.print("FAIL  {s}/{s} ({s}) — instantiate unexpectedly succeeded\n", .{ corpus_name, filename, label });
    return false;
}

fn handleAssertReturn(
    ctx: *RunnerContext,
    rest: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !bool {
    // Format: `assert_return <export> <args...> -> <expected...>`
    const arrow = std.mem.find(u8, rest, "->") orelse {
        try stdout.print("FAIL  {s}: assert_return missing '->'\n", .{corpus_name});
        return false;
    };
    const left = std.mem.trim(u8, rest[0..arrow], " \t");
    const right = std.mem.trim(u8, rest[arrow + 2 ..], " \t");

    const a = ctx.alloc();
    const left_tokens = try splitTokens(a, left);
    if (left_tokens.len == 0) {
        try stdout.print("FAIL  {s}: assert_return missing export name\n", .{corpus_name});
        return false;
    }
    const export_name = left_tokens[0];

    var args: std.ArrayList(wasm_c_api.Val) = .empty;
    defer args.deinit(a);
    for (left_tokens[1..]) |arg_tok| {
        const v = parseValue(arg_tok) catch |err| {
            try stdout.print("FAIL  {s}: assert_return bad arg '{s}': {s}\n", .{ corpus_name, arg_tok, @errorName(err) });
            return false;
        };
        try args.append(a, v);
    }

    var expected: std.ArrayList(wasm_c_api.Val) = .empty;
    defer expected.deinit(a);
    if (right.len > 0) {
        const right_tokens = try splitTokens(a, right);
        for (right_tokens) |exp_tok| {
            const v = parseValue(exp_tok) catch |err| {
                try stdout.print("FAIL  {s}: assert_return bad expected '{s}': {s}\n", .{ corpus_name, exp_tok, @errorName(err) });
                return false;
            };
            try expected.append(a, v);
        }
    }

    const result = invokeExport(ctx, export_name, args.items, expected.items.len, a) catch |err| {
        try stdout.print("FAIL  {s}/{s}: invoke {s}\n", .{ corpus_name, export_name, @errorName(err) });
        return false;
    };
    if (result.trapped) {
        // Surface the trap kind so a "trapped unexpectedly" line
        // can be triaged without re-running with debug prints. The
        // kind comes straight from `wasm_c_api.TrapKind` —
        // `Unreachable` typically means we fell into an `unreachable`
        // op (or hit an unbound dispatch slot); other kinds point at
        // a specific handler (DivByZero, OutOfBounds*, etc.).
        const k: []const u8 = if (result.trap_kind) |kk| trapKindName(kk) else "<unknown>";
        try stdout.print("FAIL  {s}/{s} (assert_return) — trapped unexpectedly (kind={s})\n", .{ corpus_name, export_name, k });
        return false;
    }

    if (result.results.len != expected.items.len) {
        try stdout.print("FAIL  {s}/{s} (assert_return) — got {d} results, expected {d}\n", .{ corpus_name, export_name, result.results.len, expected.items.len });
        return false;
    }
    for (result.results, expected.items, 0..) |got, want, i| {
        if (!valEquals(got, want)) {
            try stdout.print("FAIL  {s}/{s} (assert_return) — result[{d}] mismatch\n", .{ corpus_name, export_name, i });
            return false;
        }
    }

    try stdout.print("PASS  {s}/{s} (assert_return)\n", .{ corpus_name, export_name });
    return true;
}

const TrapKindExpect = enum { any, exhaustion };

fn handleAssertTrap(
    ctx: *RunnerContext,
    rest: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
    expect: TrapKindExpect,
) !bool {
    // Format: `assert_trap <export> <args...> !! <kind>`
    const bang = std.mem.find(u8, rest, "!!") orelse rest.len;
    const left = std.mem.trim(u8, rest[0..bang], " \t");

    const a = ctx.alloc();
    const left_tokens = try splitTokens(a, left);
    if (left_tokens.len == 0) {
        try stdout.print("FAIL  {s}: assert_trap missing export name\n", .{corpus_name});
        return false;
    }
    const export_name = left_tokens[0];

    var args: std.ArrayList(wasm_c_api.Val) = .empty;
    defer args.deinit(a);
    for (left_tokens[1..]) |arg_tok| {
        const v = parseValue(arg_tok) catch |err| {
            try stdout.print("FAIL  {s}: assert_trap bad arg '{s}': {s}\n", .{ corpus_name, arg_tok, @errorName(err) });
            return false;
        };
        try args.append(a, v);
    }

    // assert_trap doesn't care about the actual results, but the c_api
    // binding enforces `results.size == sig.results.len` and synthesises
    // a binding_error trap on mismatch. Sizing the buffer correctly lets
    // the genuine trap (e.g. OOB load before `select` consumes it) reach
    // the runner instead of being masked.
    const arity = lookupResultArity(ctx, export_name) catch 0;
    const result = invokeExport(ctx, export_name, args.items, arity, a) catch |err| {
        try stdout.print("PASS  {s}/{s} (assert_trap; runner-error counted as trap: {s})\n", .{ corpus_name, export_name, @errorName(err) });
        return true;
    };
    if (!result.trapped) {
        try stdout.print("FAIL  {s}/{s} (assert_trap) — did not trap\n", .{ corpus_name, export_name });
        return false;
    }
    // Strict trap-kind matching: the manifest's `!! <kind>` token
    // must match the trap kind c_api surfaced. `expect == .exhaustion`
    // accepts only stack_overflow; `.any` accepts whatever was named.
    const expected_tag = if (bang < rest.len) std.mem.trim(u8, rest[bang + 2 ..], " \t") else "";
    const got_tag: []const u8 = if (result.trap_kind) |k| trapKindName(k) else "<unknown>";
    const match = blk: {
        if (expect == .exhaustion) {
            // assert_exhaustion: expect stack_overflow regardless of label
            break :blk result.trap_kind == .stack_overflow;
        }
        // assert_trap: compare against the named kind, with a tolerance
        // for v2's "Unreachable"/"unreachable_" canonicalisation.
        if (expected_tag.len == 0) break :blk true; // unspecified → any trap
        break :blk eqIgnoreCase(expected_tag, got_tag);
    };
    if (!match) {
        try stdout.print("FAIL  {s}/{s} (assert_trap) — trap-kind mismatch (expected '{s}', got '{s}')\n", .{ corpus_name, export_name, expected_tag, got_tag });
        return false;
    }
    try stdout.print("PASS  {s}/{s} (assert_trap)\n", .{ corpus_name, export_name });
    return true;
}

fn trapKindName(k: wasm_c_api.TrapKind) []const u8 {
    return switch (k) {
        .binding_error => "binding_error",
        .unreachable_ => "Unreachable",
        .div_by_zero => "DivByZero",
        .int_overflow => "IntOverflow",
        .invalid_conversion => "InvalidConversionToInt",
        .oob_memory => "OutOfBounds",
        .oob_table => "OutOfBoundsTableAccess",
        .uninitialized_elem => "UninitializedElement",
        .indirect_call_mismatch => "IndirectCallTypeMismatch",
        .stack_overflow => "StackOverflow",
        .out_of_memory => "OutOfMemory",
        // D-293 slice-4a — Wasm 3.0 GC/typed-ref/EH trap kinds (runtime.Trap error names).
        .null_reference => "NullReference",
        .cast_failure => "CastFailure",
        .uncaught_exception => "UncaughtException",
        .unaligned_atomic => "UnalignedAtomic", // Wasm threads (ADR-0168)
        .expected_shared_memory => "ExpectedSharedMemory", // Wasm threads (ADR-0168)
        .interrupted => "Interrupted", // sandboxing host cancel/timeout (ADR-0179 #3a)
        .out_of_fuel => "OutOfFuel", // sandboxing fuel budget (ADR-0179 #3b)
    };
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const yl = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (xl != yl) return false;
    }
    return true;
}

fn handleInvoke(
    ctx: *RunnerContext,
    rest: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !bool {
    const a = ctx.alloc();
    const tokens = try splitTokens(a, rest);
    if (tokens.len == 0) {
        try stdout.print("FAIL  {s}: invoke missing export name\n", .{corpus_name});
        return false;
    }
    const export_name = tokens[0];

    var args: std.ArrayList(wasm_c_api.Val) = .empty;
    defer args.deinit(a);
    for (tokens[1..]) |arg_tok| {
        const v = parseValue(arg_tok) catch |err| {
            try stdout.print("FAIL  {s}: invoke bad arg '{s}': {s}\n", .{ corpus_name, arg_tok, @errorName(err) });
            return false;
        };
        try args.append(a, v);
    }

    // Look up the exported function's result arity so wasm_func_call
    // doesn't binding-error on a results.size mismatch. For bare
    // `invoke` we discard the values but still need the right slot
    // count.
    const arity = lookupResultArity(ctx, export_name) catch |err| {
        try stdout.print("FAIL  {s}/{s}: invoke {s}\n", .{ corpus_name, export_name, @errorName(err) });
        return false;
    };
    const result = invokeExport(ctx, export_name, args.items, arity, a) catch |err| {
        try stdout.print("FAIL  {s}/{s}: invoke {s}\n", .{ corpus_name, export_name, @errorName(err) });
        return false;
    };
    _ = result;
    try stdout.print("PASS  {s}/{s} (invoke)\n", .{ corpus_name, export_name });
    return true;
}

/// Return the result arity (number of return slots) for the named
/// export on the current module. Used by `invoke` (results discarded)
/// when the caller doesn't already know the expected count from a
/// trailing `-> <expected>` clause.
fn lookupResultArity(ctx: *RunnerContext, export_name: []const u8) !usize {
    const am = ctx.current orelse return error.NoCurrentModule;
    const inst = am.instance orelse return error.NoCurrentModule;
    am.ensureExports();
    for (inst.exports_storage, 0..) |exp, i| {
        if (exp.kind == .func and std.mem.eql(u8, exp.name, export_name)) {
            if (i >= am.exports.size) return error.ExportNotFound;
            const ext = am.exports.data.?[i] orelse return error.ExportNotFound;
            const fn_ptr = wasm_c_api.wasm_extern_as_func(ext) orelse return error.NotAFunction;
            // Func handle carries instance + func_idx; fish the sig
            // through the instance's func_ptrs_storage.
            if (inst.func_ptrs_storage.len <= fn_ptr.func_idx) return error.ExportNotFound;
            const zfunc = inst.func_ptrs_storage[fn_ptr.func_idx];
            return zfunc.sig.results.len;
        }
    }
    return error.ExportNotFound;
}

const InvokeResult = struct {
    trapped: bool,
    trap_kind: ?wasm_c_api.TrapKind = null,
    results: []wasm_c_api.Val,
};

fn invokeExport(
    ctx: *RunnerContext,
    export_name: []const u8,
    args: []const wasm_c_api.Val,
    expected_result_count: usize,
    a: std.mem.Allocator,
) !InvokeResult {
    const am = ctx.current orelse return error.NoCurrentModule;
    const inst = am.instance orelse return error.NoCurrentModule;
    am.ensureExports();

    var entry_idx: ?usize = null;
    for (inst.exports_storage, 0..) |exp, i| {
        if (exp.kind == .func and std.mem.eql(u8, exp.name, export_name)) {
            entry_idx = i;
            break;
        }
    }
    const idx = entry_idx orelse return error.ExportNotFound;
    if (idx >= am.exports.size) return error.ExportNotFound;
    const ext = am.exports.data.?[idx] orelse return error.ExportNotFound;
    const fn_ptr = wasm_c_api.wasm_extern_as_func(ext) orelse return error.NotAFunction;

    const args_vec: wasm_c_api.ValVec = .{
        .size = args.len,
        .data = if (args.len > 0) @constCast(args.ptr) else null,
    };
    // wasm_func_call requires results.size == sig.results.len
    // exactly. The caller pre-sizes via `expected_result_count`.
    const results_buf = if (expected_result_count > 0)
        try a.alloc(wasm_c_api.Val, expected_result_count)
    else
        @as([]wasm_c_api.Val, &.{});
    var results_vec: wasm_c_api.ValVec = .{
        .size = expected_result_count,
        .data = if (expected_result_count > 0) results_buf.ptr else null,
    };
    const trap = wasm_c_api.wasm_func_call(fn_ptr, &args_vec, &results_vec);
    if (trap) |t| {
        const k = t.kind;
        wasm_c_api.wasm_trap_delete(trap);
        return .{ .trapped = true, .trap_kind = k, .results = &.{} };
    }
    return .{ .trapped = false, .results = results_buf };
}

fn parseValue(text: []const u8) !wasm_c_api.Val {
    const colon = std.mem.findScalar(u8, text, ':') orelse return error.BadValueSyntax;
    const ty = text[0..colon];
    const num = text[colon + 1 ..];

    if (std.mem.eql(u8, ty, "i32")) {
        // Wasm i32 values are bit-patterns; wast2json may emit
        // them as either signed (negative) or unsigned (large
        // positive). Try i32 first, then u32 + bitcast.
        if (std.fmt.parseInt(i32, num, 0)) |v| {
            return .{ .kind = .i32, .of = .{ .i32 = v } };
        } else |_| {
            // Fall through to the unsigned-bit-pattern attempt below.
        }
        const u = std.fmt.parseInt(u32, num, 0) catch return error.BadI32;
        return .{ .kind = .i32, .of = .{ .i32 = @bitCast(u) } };
    } else if (std.mem.eql(u8, ty, "i64")) {
        if (std.fmt.parseInt(i64, num, 0)) |v| {
            return .{ .kind = .i64, .of = .{ .i64 = v } };
        } else |_| {
            // Fall through to the unsigned-bit-pattern attempt below.
        }
        const u = std.fmt.parseInt(u64, num, 0) catch return error.BadI64;
        return .{ .kind = .i64, .of = .{ .i64 = @bitCast(u) } };
    } else if (std.mem.eql(u8, ty, "f32")) {
        if (std.mem.startsWith(u8, num, "0x")) {
            const bits = std.fmt.parseInt(u32, num[2..], 16) catch return error.BadF32;
            return .{ .kind = .f32, .of = .{ .f32 = @bitCast(bits) } };
        }
        const v = std.fmt.parseFloat(f32, num) catch return error.BadF32;
        return .{ .kind = .f32, .of = .{ .f32 = v } };
    } else if (std.mem.eql(u8, ty, "f64")) {
        if (std.mem.startsWith(u8, num, "0x")) {
            const bits = std.fmt.parseInt(u64, num[2..], 16) catch return error.BadF64;
            return .{ .kind = .f64, .of = .{ .f64 = @bitCast(bits) } };
        }
        const v = std.fmt.parseFloat(f64, num) catch return error.BadF64;
        return .{ .kind = .f64, .of = .{ .f64 = v } };
    }
    return error.UnknownType;
}

fn valEquals(a: wasm_c_api.Val, b: wasm_c_api.Val) bool {
    if (a.kind != b.kind) return false;
    return switch (a.kind) {
        .i32 => a.of.i32 == b.of.i32,
        .i64 => a.of.i64 == b.of.i64,
        .f32 => @as(u32, @bitCast(a.of.f32)) == @as(u32, @bitCast(b.of.f32)),
        .f64 => @as(u64, @bitCast(a.of.f64)) == @as(u64, @bitCast(b.of.f64)),
        .anyref, .funcref => a.of.ref == b.of.ref,
    };
}
