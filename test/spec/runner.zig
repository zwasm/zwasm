//! Wasm spec test runner (Phase 1 / §9.1 / 1.8 → 1.9).
//!
//! Walks a directory of `.wasm` files and for each one runs:
//!   parser.parse  →  sections.decodeTypes + decodeFunctions +
//!   decodeCodes  →  validator.validateFunction (per function).
//!
//! Reports pass / fail counts to stdout and exits 0 iff all
//! fixtures parsed and validated.
//!
//! Usage:
//!   zig build test-spec               # walks test/spec/smoke/
//!   spec_runner_exe <corpus-dir>      # walks the given dir

const std = @import("std");

const zwasm = @import("zwasm");
const parser = zwasm.parse.parser;
const runtime = zwasm.runtime;
const sections = zwasm.parse.sections;
const validator = zwasm.validate.validator;

pub fn main(init: std.process.Init) !void {
    zwasm.support.dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?; // executable name
    const corpus_dir_arg = arg_it.next() orelse {
        try stdout.print("usage: spec_runner <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_dir = try gpa.dupe(u8, corpus_dir_arg);
    defer gpa.free(corpus_dir);
    var passed: u32 = 0;
    var failed: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_dir, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer dir.close(io);

    // ADR-0210 — the enumeration denominator. Re-derivable without the
    // runner (`ls <corpus>/*.wasm | wc -l`), so "N passed" can be checked
    // against the set actually walked rather than taken on trust.
    var enumerated: u32 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;
        enumerated += 1;

        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20)) catch |err| {
            try stdout.print("FAIL  {s}: read error {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer gpa.free(bytes);

        var module = parser.parse(gpa, bytes) catch |err| {
            try stdout.print("FAIL  {s}: parse error {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer module.deinit(gpa);

        runOne(gpa, &module) catch |err| {
            try stdout.print("FAIL  {s}: {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };
        try stdout.print("PASS  {s} ({d} sections)\n", .{ entry.name, module.sections.items.len });
        passed += 1;
    }

    // Two corpora run under this binary (`smoke`, `wasm-1.0`); name which
    // one a summary belongs to. Basename only — the absolute path is a
    // build-machine detail that just makes the line hard to read.
    const corpus_name = std.Io.Dir.path.basename(corpus_dir);
    try stdout.print("\nspec_runner[{s}]: {d} passed, {d} failed (of {d} enumerated)\n", .{ corpus_name, passed, failed, enumerated });
    try stdout.flush();

    // ADR-0210 — every enumerated module reaches pass or fail; this
    // runner has no skip column, so a gap means a path returned without
    // recording a verdict.
    if (passed + failed != enumerated) {
        try stdout.print("spec_runner[{s}]: ACCOUNTING OPEN — {d} enumerated but {d} recorded a verdict\n", .{ corpus_name, enumerated, passed + failed });
        try stdout.flush();
        std.process.exit(1);
    }
    if (failed != 0) std.process.exit(1);
}

/// Decode the type / function / code sections of a parsed module and
/// run the validator over each defined function. Returns on the first
/// error (caller treats it as a per-fixture failure).
fn runOne(gpa: std.mem.Allocator, module: *runtime.Module) !void {
    const type_section = module.find(.type);
    const import_section = module.find(.import);
    const func_section = module.find(.function);
    const table_section = module.find(.table);
    const global_section = module.find(.global);
    const code_section = module.find(.code);

    // No code section → nothing to validate (imports / type-only modules).
    const code_body = if (code_section) |s| s.body else return;

    var types_owned = if (type_section) |s|
        try sections.decodeTypes(gpa, s.body)
    else
        sections.Types{ .arena = std.heap.ArenaAllocator.init(gpa), .items = &.{}, .kinds = &.{}, .struct_defs = &.{}, .array_defs = &.{}, .supertypes = &.{}, .finals = &.{} };
    defer types_owned.deinit();

    var imports_owned: ?sections.Imports = if (import_section) |s|
        try sections.decodeImports(gpa, s.body)
    else
        null;
    defer if (imports_owned) |*im| im.deinit();

    const defined_func_indices = if (func_section) |s|
        try sections.decodeFunctions(gpa, s.body)
    else
        try gpa.alloc(u32, 0);
    defer gpa.free(defined_func_indices);

    var codes = try sections.decodeCodes(gpa, code_body);
    defer codes.deinit();

    if (codes.items.len != defined_func_indices.len) return error.FunctionCountMismatch;

    // Function-index space = imported funcs (in import order) + defined funcs.
    var imp_func_count: usize = 0;
    if (imports_owned) |im| {
        for (im.items) |it| if (it.kind == .func) {
            imp_func_count += 1;
        };
    }
    const total_funcs = imp_func_count + defined_func_indices.len;
    const func_types = try gpa.alloc(zwasm.ir.zir.FuncType, total_funcs);
    defer gpa.free(func_types);
    {
        var cursor: usize = 0;
        if (imports_owned) |im| {
            for (im.items) |it| if (it.kind == .func) {
                const ti = it.payload.func_typeidx;
                if (ti >= types_owned.items.len) return error.InvalidTypeIndex;
                func_types[cursor] = types_owned.items[ti];
                cursor += 1;
            };
        }
        for (defined_func_indices) |type_idx| {
            if (type_idx >= types_owned.items.len) return error.InvalidTypeIndex;
            func_types[cursor] = types_owned.items[type_idx];
            cursor += 1;
        }
    }

    // Global-index space = imported globals + defined globals.
    var globals_owned: ?sections.Globals = if (global_section) |s|
        try sections.decodeGlobals(gpa, s.body)
    else
        null;
    defer if (globals_owned) |*g| g.deinit();

    var imp_global_count: usize = 0;
    if (imports_owned) |im| {
        for (im.items) |it| if (it.kind == .global) {
            imp_global_count += 1;
        };
    }
    const def_global_count: usize = if (globals_owned) |g| g.items.len else 0;
    const total_globals = imp_global_count + def_global_count;
    const global_entries = try gpa.alloc(validator.GlobalEntry, total_globals);
    defer gpa.free(global_entries);
    {
        var cursor: usize = 0;
        if (imports_owned) |im| {
            for (im.items) |it| if (it.kind == .global) {
                global_entries[cursor] = .{
                    .valtype = it.payload.global.valtype,
                    .mutable = it.payload.global.mutable,
                };
                cursor += 1;
            };
        }
        if (globals_owned) |g| {
            for (g.items) |gd| {
                global_entries[cursor] = .{ .valtype = gd.valtype, .mutable = gd.mutable };
                cursor += 1;
            }
        }
    }

    // Tables: imported tables (limits-only) + defined tables.
    var tables_owned: ?sections.Tables = if (table_section) |s|
        try sections.decodeTables(gpa, s.body)
    else
        null;
    defer if (tables_owned) |*t| t.deinit();

    var imp_table_count: usize = 0;
    if (imports_owned) |im| for (im.items) |it| if (it.kind == .table) {
        imp_table_count += 1;
    };
    const def_table_count: usize = if (tables_owned) |t| t.items.len else 0;
    const total_tables = imp_table_count + def_table_count;
    const table_entries = try gpa.alloc(zwasm.ir.zir.TableEntry, total_tables);
    defer gpa.free(table_entries);
    {
        // Imported table descriptions are recorded as kind-only (§A10);
        // we synthesise a permissive funcref entry so the validator's
        // bounds-check passes for `table.*` ops indexing imported
        // tables. Spec compliance for imports' explicit tabletype
        // lands when sections.decodeImports surfaces it.
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
        try validator.validateFunction(
            sig,
            code.locals,
            code.body,
            func_types,
            global_entries,
            types_owned.items,
            0, // data_count: data section decoding deferred to §9.2 / 2.8 follow-up
            table_entries,
            0, // elem_count: element section decoding deferred likewise
        );
    }
}
