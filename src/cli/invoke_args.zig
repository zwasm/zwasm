//! `zwasm run --invoke NAME=ARG1,ARG2,...` argument marshalling + typed
//! result printing (D-273(1)).
//!
//! The CLI lets a user invoke a named compute export, pass typed arguments,
//! and SEE the typed results — the core compute-CLI use wasmtime serves.
//! Syntax (loop-designed, not a wasmtime copy): a single `--invoke` token
//! `NAME=ARGS` keeps everything unambiguous against the trailing WASI argv
//! (no second positional to disambiguate). `--invoke NAME` (no `=`) stays
//! the zero-arg entry form.
//!
//! Args parse by the export's declared param types; results print bare
//! (one value per line, pipe-friendly), typed off each result Val's kind.
//!
//! Zone 3 — CLI may import `api/` (the C-API is conventionally driven from
//! the CLI; `invokeFormatted` wraps `wasm_func_call` with sized arg/result
//! vecs so a value-returning export no longer fails the arity check).

const std = @import("std");
const wasm = @import("../api/wasm.zig");

pub const ArgError = error{ UnsupportedArgType, InvalidArgValue, ArgCountMismatch };

/// Map a `wasm_valtype_t` kind byte to a `ValKind`, rejecting any byte
/// outside the C-ABI value-kind set (e.g. v128, which the boundary `Val`
/// union cannot carry) so the caller surfaces UnsupportedArgType instead
/// of `@enumFromInt` tripping a safety panic.
fn valKindFromByte(b: u8) ?wasm.ValKind {
    return switch (b) {
        0 => .i32,
        1 => .i64,
        2 => .f32,
        3 => .f64,
        128 => .anyref,
        129 => .funcref,
        else => null,
    };
}

/// i32 accepts both the signed decimal form and any bit-pattern reachable
/// as an unsigned u32 (`0xFFFFFFFF` → -1) — a guest's i32 is bits, and a
/// user passing `4294967295` means the same word as `-1`. Hex/octal/binary
/// via base 0. InvalidCharacter propagates; only Overflow re-tries unsigned.
fn parseI32(text: []const u8) !i32 {
    return std.fmt.parseInt(i32, text, 0) catch |e| switch (e) {
        error.Overflow => @bitCast(try std.fmt.parseInt(u32, text, 0)),
        else => return e,
    };
}

fn parseI64(text: []const u8) !i64 {
    return std.fmt.parseInt(i64, text, 0) catch |e| switch (e) {
        error.Overflow => @bitCast(try std.fmt.parseInt(u64, text, 0)),
        else => return e,
    };
}

/// Parse one argument token against an expected value kind into a boundary
/// `Val`. Ref kinds are not CLI-expressible (no literal syntax for a host
/// reference) → UnsupportedArgType.
pub fn parseArg(kind: wasm.ValKind, text: []const u8) ArgError!wasm.Val {
    return switch (kind) {
        .i32 => .{ .kind = .i32, .of = .{ .i32 = parseI32(text) catch return error.InvalidArgValue } },
        .i64 => .{ .kind = .i64, .of = .{ .i64 = parseI64(text) catch return error.InvalidArgValue } },
        .f32 => .{ .kind = .f32, .of = .{ .f32 = std.fmt.parseFloat(f32, text) catch return error.InvalidArgValue } },
        .f64 => .{ .kind = .f64, .of = .{ .f64 = std.fmt.parseFloat(f64, text) catch return error.InvalidArgValue } },
        .anyref, .funcref => error.UnsupportedArgType,
    };
}

/// Format one result `Val` bare (no newline) by its kind. Floats use Zig's
/// shortest round-trippable decimal (`{d}`); refs render `null` / `ref`
/// (a host reference has no meaningful textual value).
pub fn formatScalar(buf: []u8, val: wasm.Val) ![]const u8 {
    return switch (val.kind) {
        .i32 => std.fmt.bufPrint(buf, "{d}", .{val.of.i32}),
        .i64 => std.fmt.bufPrint(buf, "{d}", .{val.of.i64}),
        .f32 => std.fmt.bufPrint(buf, "{d}", .{val.of.f32}),
        .f64 => std.fmt.bufPrint(buf, "{d}", .{val.of.f64}),
        .anyref, .funcref => std.fmt.bufPrint(buf, "{s}", .{if (val.of.ref == null) "null" else "ref"}),
    };
}

/// Parse a comma-separated `args_str` against the func's `params`, allocating
/// the boundary `Val` array (caller frees with the same allocator). An empty
/// `args_str` is zero tokens; the token count must equal `params.size`.
pub fn parseArgsAlloc(alloc: std.mem.Allocator, params: *const wasm.ValTypeVec, args_str: []const u8) ![]wasm.Val {
    const n = params.size;
    const ntok: usize = if (args_str.len == 0) 0 else blk: {
        var c: usize = 1;
        for (args_str) |ch| {
            if (ch == ',') c += 1;
        }
        break :blk c;
    };
    if (ntok != n) return error.ArgCountMismatch;
    const out = try alloc.alloc(wasm.Val, n);
    errdefer alloc.free(out);
    if (n == 0) return out;
    const data = params.data orelse return error.ArgCountMismatch;
    var it = std.mem.splitScalar(u8, args_str, ',');
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        const vt = data[i] orelse return error.UnsupportedArgType;
        const kind = valKindFromByte(vt.kind) orelse return error.UnsupportedArgType;
        out[i] = try parseArg(kind, std.mem.trim(u8, tok, " "));
    }
    return out;
}

/// Invoke `entry_fn` with `invoke_args` (`null` = zero-arg) parsed against
/// its signature, appending each typed result to `out` as a bare decimal line.
/// Returns the trap pointer (non-null) untouched when the call traps — the
/// caller owns trap handling (proc_exit exit-code, stderr surface); `out` is
/// left empty in that case. A value-returning export now runs because the
/// results vec is sized to the result arity (was always 0 → arity mismatch).
pub fn invokeFormatted(
    alloc: std.mem.Allocator,
    entry_fn: *const wasm.Func,
    invoke_args: ?[]const u8,
    out: *std.ArrayList(u8),
) !?*wasm.Trap {
    const ft = wasm.wasm_func_type(entry_fn) orelse return error.NoFuncExport;
    defer wasm.wasm_functype_delete(ft);
    const params = wasm.wasm_functype_params(ft) orelse return error.NoFuncExport;
    const results_ty = wasm.wasm_functype_results(ft) orelse return error.NoFuncExport;

    const args = if (invoke_args) |astr|
        try parseArgsAlloc(alloc, params, astr)
    else blk: {
        if (params.size != 0) return error.ArgCountMismatch;
        break :blk @as([]wasm.Val, &.{});
    };
    defer if (args.len > 0) alloc.free(args);

    const rn = results_ty.size;
    const results_buf = if (rn > 0) try alloc.alloc(wasm.Val, rn) else @as([]wasm.Val, &.{});
    defer if (rn > 0) alloc.free(results_buf);

    var args_vec: wasm.ValVec = .{ .size = args.len, .data = if (args.len > 0) args.ptr else null };
    var results: wasm.ValVec = .{ .size = rn, .data = if (rn > 0) results_buf.ptr else null };
    const trap = wasm.wasm_func_call(entry_fn, &args_vec, &results);
    if (trap != null) return trap;

    for (results_buf[0..rn]) |v| {
        var b: [64]u8 = undefined;
        const s = try formatScalar(&b, v);
        try out.appendSlice(alloc, s);
        try out.append(alloc, '\n');
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "parseArg: integers (decimal / hex / negative / unsigned-wrap)" {
    try testing.expectEqual(@as(i32, 5), (try parseArg(.i32, "5")).of.i32);
    try testing.expectEqual(@as(i32, -3), (try parseArg(.i32, "-3")).of.i32);
    try testing.expectEqual(@as(i32, 255), (try parseArg(.i32, "0xff")).of.i32);
    // u32 max wraps to the same word as i32 -1.
    try testing.expectEqual(@as(i32, -1), (try parseArg(.i32, "4294967295")).of.i32);
    try testing.expectEqual(@as(i64, -1), (try parseArg(.i64, "18446744073709551615")).of.i64);
}

test "parseArg: floats and rejections" {
    try testing.expectEqual(@as(f64, 1.5), (try parseArg(.f64, "1.5")).of.f64);
    try testing.expect(std.math.isInf((try parseArg(.f32, "inf")).of.f32));
    try testing.expectError(error.InvalidArgValue, parseArg(.i32, "notanum"));
    try testing.expectError(error.UnsupportedArgType, parseArg(.funcref, "0"));
}

test "formatScalar: typed bare rendering" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("42", try formatScalar(&b, .{ .kind = .i32, .of = .{ .i32 = 42 } }));
    try testing.expectEqualStrings("-7", try formatScalar(&b, .{ .kind = .i64, .of = .{ .i64 = -7 } }));
    try testing.expectEqualStrings("1.5", try formatScalar(&b, .{ .kind = .f64, .of = .{ .f64 = 1.5 } }));
    try testing.expectEqualStrings("null", try formatScalar(&b, .{ .kind = .funcref, .of = .{ .ref = null } }));
}

// `(func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)`
const add_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60,
    0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20,
    0x00, 0x20, 0x01, 0x6a, 0x0b,
};

// `(func (export "swap") (param i32 i64) (result i64 i32) local.get 1 local.get 0)`
const swap_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x01, 0x60,
    0x02, 0x7f, 0x7e, 0x02, 0x7e, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x08,
    0x01, 0x04, 0x73, 0x77, 0x61, 0x70, 0x00, 0x00, 0x0a, 0x08, 0x01, 0x06,
    0x00, 0x20, 0x01, 0x20, 0x00, 0x0b,
};

fn invokeExport(bytes: []const u8, name: []const u8, args: ?[]const u8, out: *std.ArrayList(u8)) !?*wasm.Trap {
    const engine = wasm.wasm_engine_new().?;
    defer wasm.wasm_engine_delete(engine);
    const store = wasm.wasm_store_new(engine).?;
    defer wasm.wasm_store_delete(store);
    var bv: wasm.ByteVec = .{ .size = bytes.len, .data = @constCast(bytes.ptr) };
    const module = wasm.wasm_module_new(store, &bv).?;
    defer wasm.wasm_module_delete(module);
    const instance = wasm.wasm_instance_new(store, module, null, null).?;
    defer wasm.wasm_instance_delete(instance);
    var exports: wasm.ExternVec = .{ .size = 0, .data = null };
    wasm.wasm_instance_exports(instance, &exports);
    defer wasm.wasm_extern_vec_delete(&exports);
    const i = wasm.externSlotOf(instance, name, .func).?;
    const entry = wasm.wasm_extern_as_func(exports.data.?[i].?);
    return invokeFormatted(testing.allocator, entry.?, args, out);
}

test "invokeFormatted: add(2,3) prints 5" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const trap = try invokeExport(&add_wasm, "add", "2,3", &out);
    try testing.expect(trap == null);
    try testing.expectEqualStrings("5\n", out.items);
}

test "invokeFormatted: multi-value swap(7,9) prints both results in order" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const trap = try invokeExport(&swap_wasm, "swap", "7,9", &out);
    try testing.expect(trap == null);
    try testing.expectEqualStrings("9\n7\n", out.items);
}

test "invokeFormatted: arg-count mismatch is a loud error" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.ArgCountMismatch, invokeExport(&add_wasm, "add", "2", &out));
    // A params-bearing export with no `=args` is also a mismatch, not a silent zero-arg call.
    try testing.expectError(error.ArgCountMismatch, invokeExport(&add_wasm, "add", null, &out));
}
