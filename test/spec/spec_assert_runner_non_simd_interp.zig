//! Interpreter lane of the Wasm 2.0 non-SIMD assertion runner
//! (`ZWASM_SPEC_ENGINE=interp`, #655). The JIT callbacks in
//! `spec_assert_runner_non_simd.zig` call compiled bodies directly; these
//! instantiate each module on the interpreter through the Zig facade's
//! `Linker` and call it with `Instance.invoke`.
//!
//! Scope, by design: the modules the JIT compiles. `base.runCorpus`
//! JIT-compiles every module before handing it here, so a module the JIT
//! rejects is a FAIL or a skip on both lanes, never an interp result, and an
//! interpreter-only module does not reach this lane. Reaching it means
//! `base.runCorpus` not compiling for this lane, a change to the runner every
//! lane shares.
//!
//! A `register` alias links to the live instance it names, found by its
//! bytes (base keeps only a copy of them), so a later module sees that
//! instance's state, as the spec requires.

const std = @import("std");

const zwasm = @import("zwasm");
const runner_mod = zwasm.engine.runner;
const base = @import("spec_assert_runner_base.zig");

const ArgValue = base.ArgValue;
const ValType = zwasm.ir.zir.ValType;

const Loaded = struct {
    bytes: []u8,
    module: *zwasm.Module,
    inst: *zwasm.Instance,
};

/// One manifest's interpreter state; `beginManifest` / `endManifest`
/// bracket each `base.runCorpus` call.
const State = struct {
    engine: *zwasm.Engine,
    linker: zwasm.Linker,
    loaded: std.ArrayList(Loaded) = .empty,
    /// Aliases already defined in `linker`.
    linked: std.StringHashMapUnmanaged(void) = .empty,
    current: ?*zwasm.Instance = null,
};

var state: ?State = null;

const instantiate_opts: zwasm.Module.InstantiateOpts = .{
    .fuel = .unmetered,
    .max_memory_pages = .unmetered,
    .max_table_elements = .unmetered,
    .engine = .interp,
};

pub fn beginManifest(gpa: std.mem.Allocator) !void {
    const engine = try gpa.create(zwasm.Engine);
    errdefer gpa.destroy(engine);
    engine.* = try zwasm.Engine.init(gpa, .{});
    state = .{ .engine = engine, .linker = zwasm.Linker.init(engine) };
}

pub fn endManifest(gpa: std.mem.Allocator) void {
    const s = if (state) |*st| st else return;
    // Instances first: an importer holds pointers into its exporters.
    var i = s.loaded.items.len;
    while (i > 0) {
        i -= 1;
        const l = s.loaded.items[i];
        l.inst.deinit();
        gpa.destroy(l.inst);
        l.module.deinit();
        gpa.destroy(l.module);
        gpa.free(l.bytes);
    }
    s.loaded.deinit(gpa);
    s.linked.deinit(gpa);
    s.linker.deinit();
    s.engine.deinit();
    gpa.destroy(s.engine);
    state = null;
}

fn instantiate(gpa: std.mem.Allocator, s: *State, bytes: []const u8) !*zwasm.Instance {
    const module = try gpa.create(zwasm.Module);
    errdefer gpa.destroy(module);
    module.* = try s.engine.compile(bytes);
    errdefer module.deinit();
    const inst = try gpa.create(zwasm.Instance);
    errdefer gpa.destroy(inst);
    inst.* = try s.linker.instantiate(module, instantiate_opts);
    errdefer inst.deinit();
    const owned = try gpa.dupe(u8, bytes);
    errdefer gpa.free(owned);
    try s.loaded.append(gpa, .{ .bytes = owned, .module = module, .inst = inst });
    return inst;
}

/// Define in the linker every alias base has registered since the last
/// call. The newest instance with the alias's bytes is the one `register`
/// named; `spectest`, which base registers with no module directive, is
/// instantiated here.
fn linkRegistered(gpa: std.mem.Allocator, s: *State) !void {
    const registered = base.current_registered orelse return;
    var it = registered.iterator();
    while (it.next()) |e| {
        const alias = e.key_ptr.*;
        if (s.linked.contains(alias)) continue;
        const bytes = e.value_ptr.bytes_owned;
        const inst = for (0..s.loaded.items.len) |k| {
            const l = s.loaded.items[s.loaded.items.len - 1 - k];
            if (std.mem.eql(u8, l.bytes, bytes)) break l.inst;
        } else try instantiate(gpa, s, bytes);
        try s.linker.defineInstance(alias, inst);
        try s.linked.put(gpa, alias, {});
    }
}

fn onModuleLoaded(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    _: *const runner_mod.CompiledWasm,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!void {
    const s = &state.?;
    s.current = null;
    try linkRegistered(gpa, s);
    s.current = instantiate(gpa, s, wasm_bytes) catch |err| {
        try stdout.print("FAIL  {s}/{s}: interp instantiate: {s}\n", .{ name, base.current_module_file orelse "?", @errorName(err) });
        return err;
    };
}

/// The manifest writes a reference as `i64:<bits>`, `ref.null` as 0
/// (`scripts/regen_spec_2_0_assert.sh`, `fmt`); the facade carries it in
/// the `funcref` / `externref` arm the parameter's type names.
fn toValue(a: ArgValue, ty: ValType) zwasm.Value {
    if (ty == .ref) {
        const bits: ?u64 = if (a.i64 == 0) null else a.i64;
        return if (std.meta.eql(ty, ValType.funcref)) .{ .funcref = bits } else .{ .externref = bits };
    }
    return switch (a) {
        .i32 => |v| .{ .i32 = @bitCast(v) },
        .i64 => |v| .{ .i64 = @bitCast(v) },
        .f32 => |v| .{ .f32 = v },
        .f64 => |v| .{ .f64 = v },
        .v128 => unreachable, // rejected by `parseCall`
    };
}

const Call = struct {
    fn_name: []const u8,
    args_s: []const u8,
    args: [24]zwasm.Value = undefined,
    n_args: usize = 0,
    results: [16]zwasm.Value = undefined,
    n_results: usize = 0,
};

/// Parse `<fn> <args>` and size the results to the export's signature.
/// Prints the FAIL line and returns null when the call cannot be made.
fn parseCall(lhs: []const u8, fn_name_buf: []u8, stdout: *std.Io.Writer, name: []const u8) !?Call {
    const fa = try base.splitFnAndArgs(lhs);
    var call: Call = .{ .fn_name = try base.decodeFnName(fa.fn_name, fn_name_buf), .args_s = fa.args_s };
    const inst = state.?.current orelse {
        try stdout.print("FAIL  {s}: {s}: no interp instance\n", .{ name, call.fn_name });
        return null;
    };
    const sig = inst.exportFuncSig(call.fn_name) orelse {
        try stdout.print("FAIL  {s}: no exported func {s}\n", .{ name, call.fn_name });
        return null;
    };
    var parsed: [24]ArgValue = undefined;
    call.n_args = base.parseAssertReturnArgs(call.args_s, &parsed) catch |err| {
        try stdout.print("FAIL  {s}: unsupported args ({s}): {s}\n", .{ name, call.args_s, @errorName(err) });
        return null;
    };
    if (call.n_args != sig.params.len) {
        try stdout.print("FAIL  {s}: {s} takes {d} args, manifest passes {d}\n", .{ name, call.fn_name, sig.params.len, call.n_args });
        return null;
    }
    for (parsed[0..call.n_args], sig.params, call.args[0..call.n_args]) |a, ty, *v| {
        if (a == .v128) {
            try stdout.print("FAIL  {s}: v128 arg in non-SIMD runner ({s})\n", .{ name, call.args_s });
            return null;
        }
        v.* = toValue(a, ty);
    }
    if (sig.results.len > call.results.len) {
        try stdout.print("FAIL  {s}: {s}: {d} results unsupported\n", .{ name, call.fn_name, sig.results.len });
        return null;
    }
    call.n_results = sig.results.len;
    return call;
}

fn invoke(call: *Call) zwasm.Instance.InvokeError!void {
    return state.?.current.?.invoke(call.fn_name, call.args[0..call.n_args], call.results[0..call.n_results]);
}

/// The errors `invoke` returns without the function having run to a trap.
fn isTrap(err: zwasm.Instance.InvokeError) bool {
    return switch (err) {
        error.ExportNotFound,
        error.NotAFunc,
        error.ArgArityMismatch,
        error.ResultArityMismatch,
        error.ProcExit,
        error.UnsupportedEngineSignature,
        => false,
        else => true,
    };
}

fn resultMatches(tok: []const u8, got: zwasm.Value) !bool {
    if (tok.len < 4) return error.BadValue;
    const exp = tok[4..];
    if (std.mem.startsWith(u8, tok, "i32:")) {
        return got == .i32 and @as(u32, @bitCast(got.i32)) == try base.parseI32Token(exp);
    } else if (std.mem.startsWith(u8, tok, "i64:")) {
        const want = try base.parseI64Token(exp);
        return switch (got) {
            .i64 => |v| @as(u64, @bitCast(v)) == want,
            .funcref, .externref => |r| (r orelse 0) == want,
            else => false,
        };
    } else if (std.mem.startsWith(u8, tok, "f32:")) {
        return got == .f32 and base.matchScalarF32(got.f32, try base.parseScalarFpExpected(exp, 32));
    } else if (std.mem.startsWith(u8, tok, "f64:")) {
        return got == .f64 and base.matchScalarF64(got.f64, try base.parseScalarFpExpected(exp, 64));
    }
    return error.BadValue;
}

fn onAssertReturn(
    _: std.mem.Allocator,
    _: []const u8,
    _: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    const arrow = std.mem.find(u8, rest, " -> ") orelse return error.BadDirective;
    const results_s = rest[arrow + 4 ..];
    var fn_name_buf: [512]u8 = undefined;
    var call = (try parseCall(rest[0..arrow], &fn_name_buf, stdout, name)) orelse return false;

    var expected: [16][]const u8 = undefined;
    var n_expected: usize = 0;
    if (!std.mem.eql(u8, results_s, "()")) {
        var tok_it = std.mem.tokenizeScalar(u8, results_s, ' ');
        while (tok_it.next()) |tok| : (n_expected += 1) {
            if (n_expected == expected.len) return error.TooManyResults;
            expected[n_expected] = tok;
        }
    }
    if (n_expected != call.n_results) {
        try stdout.print("FAIL  {s}: {s} returns {d} values, manifest expects {d}\n", .{ name, call.fn_name, call.n_results, n_expected });
        return false;
    }

    invoke(&call) catch |err| {
        try stdout.print("FAIL  {s}: {s}({s}) → {s}, expected {s}\n", .{ name, call.fn_name, call.args_s, @errorName(err), results_s });
        return false;
    };
    for (expected[0..n_expected], call.results[0..n_expected]) |tok, got| {
        const ok = resultMatches(tok, got) catch {
            try stdout.print("FAIL  {s}: unsupported result token '{s}'\n", .{ name, tok });
            return false;
        };
        if (!ok) {
            try stdout.print("FAIL  {s}: {s}({s}) → got {any}, expected {s}\n", .{ name, call.fn_name, call.args_s, got, tok });
            return false;
        }
    }
    return true;
}

/// Also serves `assert_exhaustion`: base routes both here, and on the
/// interpreter call-depth exhaustion is a trap like any other.
fn onAssertTrap(
    _: std.mem.Allocator,
    _: []const u8,
    _: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    var fn_name_buf: [512]u8 = undefined;
    var call = (try parseCall(rest, &fn_name_buf, stdout, name)) orelse return false;
    invoke(&call) catch |err| {
        if (isTrap(err)) return true;
        try stdout.print("FAIL  {s}: assert_trap {s}({s}) → {s}, not a trap\n", .{ name, call.fn_name, call.args_s, @errorName(err) });
        return false;
    };
    try stdout.print("FAIL  {s}: assert_trap {s}({s}) returned\n", .{ name, call.fn_name, call.args_s });
    return false;
}

fn onInvokeAction(
    _: std.mem.Allocator,
    _: []const u8,
    _: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    var fn_name_buf: [512]u8 = undefined;
    var call = (try parseCall(rest, &fn_name_buf, stdout, name)) orelse return false;
    invoke(&call) catch |err| {
        try stdout.print("FAIL  {s}: invoke-action {s}({s}) → {s}\n", .{ name, call.fn_name, call.args_s, @errorName(err) });
        return false;
    };
    return true;
}

/// PASS only on `InstantiateFailed`: the module linked and then failed to
/// initialise. That error is coarser than a trap (the Linker passes no
/// `trap_out`, `src/zwasm/linker.zig` `instantiate`), so it also covers an
/// import whose limits do not match; a link or compile error is a FAIL.
fn onAssertUninstantiable(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    _: *const runner_mod.CompiledWasm,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    const s = &state.?;
    try linkRegistered(gpa, s);
    _ = instantiate(gpa, s, wasm_bytes) catch |err| {
        if (err == error.InstantiateFailed) return true;
        try stdout.print("FAIL  {s}: assert_uninstantiable: {s}, not an initialisation failure\n", .{ name, @errorName(err) });
        return false;
    };
    try stdout.print("FAIL  {s}: assert_uninstantiable: module instantiated\n", .{name});
    return false;
}

fn onGetAction(
    _: std.mem.Allocator,
    _: []const u8,
    _: *const runner_mod.CompiledWasm,
    body: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    var it = std.mem.tokenizeScalar(u8, body, ' ');
    const field = it.next() orelse return error.BadDirective;
    const type_str = it.next() orelse return error.BadDirective;
    const value_str = it.next() orelse return error.BadDirective;
    const inst = state.?.current orelse {
        try stdout.print("FAIL  {s}: get-action({s}): no interp instance\n", .{ name, field });
        return false;
    };
    const global = inst.global(field) orelse {
        try stdout.print("FAIL  {s}: get-action({s}): no exported global\n", .{ name, field });
        return false;
    };
    var tok_buf: [64]u8 = undefined;
    const tok = try std.mem.print(&tok_buf, "{s}:{s}", .{ type_str, value_str });
    if (try resultMatches(tok, global.get())) return true;
    try stdout.print("FAIL  {s}: get-action({s}) → {any}, expected {s}\n", .{ name, field, global.get(), tok });
    return false;
}

/// Manifests this lane does not run, each until the issue beside it is
/// fixed. Whoever fixes one deletes its row.
pub const excluded = [_]struct { manifest: []const u8, issue: []const u8 }{
    .{ .manifest = "loop", .issue = "#244" },
    .{ .manifest = "fac", .issue = "#244" }, // hangs, so the whole run stops
    .{ .manifest = "elem", .issue = "#282, #662" },
    .{ .manifest = "memory_grow", .issue = "#663" },
    .{ .manifest = "table_grow", .issue = "#663" },
};

pub fn exclusionFor(manifest: []const u8) ?[]const u8 {
    for (excluded) |e| if (std.mem.eql(u8, e.manifest, manifest)) return e.issue;
    return null;
}

pub const callbacks: base.RunnerCallbacks = .{
    .on_module_loaded = onModuleLoaded,
    .handle_assert_return = onAssertReturn,
    .handle_assert_trap = onAssertTrap,
    .handle_invoke_action = onInvokeAction,
    .handle_assert_uninstantiable = onAssertUninstantiable,
    .handle_get_action = onGetAction,
};
