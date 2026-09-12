// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig); std.process.run with no environ_map hands the child this process's environment, so a channel set on this lane reaches it.
//! The CLI's default-entry contract, re-derived on every run path (#220,
//! ADR-0230). `zwasm run` without `--invoke` resolves `_start`, else `main`;
//! a zero-parameter entry runs whatever its results and the results print;
//! anything else is refused with the reason on stderr and exit 1. The `.wasm`
//! default, `--engine interp`, `--engine jit` and the `.cwasm` that
//! `zwasm compile` produces must each give the answer the table below
//! states — one row per module shape, one column per path.
//!
//! Why a subprocess: only `main.zig` picks the driver, and the `.cwasm`
//! artifact only exists through `zwasm compile`.
//!
//! Usage: `zig build test-cli-default-entry` /
//!        `zwasm-cli-default-entry <zwasm-cli> <fixture-dir>`

const std = @import("std");

const Observed = struct {
    stdout: []u8,
    stderr: []u8,
    exit: u8,

    fn deinit(self: *Observed, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// What stderr must hold. `.contains` is the contract's wording — or, on a
/// lane an open issue owns, the wording it has today, so the row fails and is
/// updated when that issue lands.
const Stderr = union(enum) {
    empty,
    contains: []const u8,
};

const Expect = struct {
    exit: u8,
    stdout: []const u8 = "",
    stderr: Stderr = .empty,
};

/// One module shape: the same expectation on every path unless a lane says
/// otherwise.
const Row = struct {
    fixture: []const u8,
    auto: Expect,
    interp: Expect,
    jit: Expect,
    cwasm: Expect,

    fn same(fixture: []const u8, e: Expect) Row {
        return .{ .fixture = fixture, .auto = e, .interp = e, .jit = e, .cwasm = e };
    }
};

const no_entry: Expect = .{ .exit = 1, .stderr = .{ .contains = "no exported function found (looked for _start, main)" } };
const trap: Expect = .{ .exit = 1, .stderr = .{ .contains = "zwasm: trap kind=unreachable_" } };
/// C4 — the JIT has no call helper for the shape: said, exit 1.
const jit_cannot_call: Expect = .{ .exit = 1, .stderr = .{ .contains = "the JIT engine cannot call 'main': unsupported entry signature" } };

const rows = [_]Row{
    // C1 — `_start`, else `main`, else nothing.
    Row.same("start_void", .{ .exit = 0 }),
    Row.same("main_i32", .{ .exit = 0, .stdout = "42\n" }),
    Row.same("only_f", no_entry),
    // The `.cwasm` of a module with no function export fails to load before
    // the entry is judged — #432's answer, pinned as it is today.
    .{ .fixture = "no_func_export", .auto = no_entry, .interp = no_entry, .jit = no_entry, .cwasm = .{ .exit = 1, .stderr = .{ .contains = "MissingTypeSection" } } },
    // C2 — an entry with parameters is refused by name, on every path.
    Row.same("start_param", .{ .exit = 1, .stderr = .{ .contains = "the default entry '_start' takes 1 parameter and none were supplied" } }),
    Row.same("main_param", .{ .exit = 1, .stderr = .{ .contains = "the default entry 'main' takes 1 parameter and none were supplied" } }),
    // C3 — a zero-parameter entry runs whatever its results, and they print;
    // the exit code is the guest's, never the result.
    Row.same("start_i32", .{ .exit = 0, .stdout = "42\n" }),
    Row.same("main_multi", .{ .exit = 0, .stdout = "1\n2\n" }),
    Row.same("main_f64", .{ .exit = 0, .stdout = "1.5\n" }),
    Row.same("main_exit3", .{ .exit = 3 }),
    Row.same("start_multi_trap", trap),
    // C5 — instantiation precedes the entry on every path: a trapping
    // `(start)` is reported whether the entry would have been admitted or
    // refused (the validity verdict, ADR-0229, comes with instantiation and
    // must precede the refusal). The trap's wording is the driver's — the C
    // API reports it as the instantiation's reason (#233), the JIT driver as
    // a trap — so the rows pin the exit and the trap's name only.
    Row.same("start_section_trap", .{ .exit = 1, .stderr = .{ .contains = "unreachable" } }),
    Row.same("start_section_main_param", .{ .exit = 1, .stderr = .{ .contains = "unreachable" } }),
    // C4 — a shape the JIT cannot call is refused with the reason, not run as
    // instantiate-only exit 0. `--engine interp` runs it. On `auto` the call
    // reaches a JIT-backed instance and cannot fall back, so the decline traps
    // `unsupported` naming the shape (#431). Only `main_multi_f32` gets there —
    // the other two return a lone ref result, which the C API's JIT arm does
    // call (`invokeRefIdx`).
    .{
        .fixture = "main_ref",
        .auto = .{ .exit = 0, .stdout = "null\n" },
        .interp = .{ .exit = 0, .stdout = "null\n" },
        .jit = jit_cannot_call,
        .cwasm = jit_cannot_call,
    },
    .{
        .fixture = "main_ref_trap",
        .auto = trap,
        .interp = trap,
        .jit = jit_cannot_call,
        .cwasm = jit_cannot_call,
    },
    .{
        .fixture = "main_multi_f32",
        .auto = .{ .exit = 1, .stderr = .{ .contains = "zwasm: trap kind=unsupported msg=no JIT entry helper for () -> (i32 f32)" } },
        .interp = .{ .exit = 0, .stdout = "1\n2\n" },
        .jit = jit_cannot_call,
        .cwasm = jit_cannot_call,
    },
};

fn runCli(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Observed {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit = switch (result.term) {
        .exited => |c| c,
        else => 255,
    } };
}

fn report(label: []const u8, lane: []const u8, o: Observed, ok: bool) void {
    std.debug.print("default-entry {s:<16} {s:<15} exit {d} stdout \"{f}\" stderr \"{f}\" {s}\n", .{
        label, lane, o.exit, std.zig.fmtString(o.stdout), std.zig.fmtString(o.stderr), if (ok) "ok" else "FAIL",
    });
}

/// Exit code and stdout exactly; stderr per `Stderr`. No default-entry run
/// may mention `--invoke` (the flag was not passed, #220 (d)) or read as a
/// trap unless it is one.
fn matches(o: Observed, e: Expect) bool {
    if (o.exit != e.exit or !std.mem.eql(u8, o.stdout, e.stdout)) return false;
    if (std.mem.find(u8, o.stderr, "--invoke") != null) return false;
    return switch (e.stderr) {
        .empty => o.stderr.len == 0,
        .contains => |text| std.mem.find(u8, o.stderr, text) != null and !std.mem.startsWith(u8, o.stderr, "zwasm: trapped in"),
    };
}

/// Runs one row on its four paths. Returns the number of lanes that failed.
fn checkRow(gpa: std.mem.Allocator, io: std.Io, cli: []const u8, row: Row, wasm_path: []const u8, cwasm_path: []const u8) !u32 {
    var failed: u32 = 0;
    const lanes = [_]struct { name: []const u8, argv: []const []const u8, expect: Expect }{
        .{ .name = ".wasm", .argv = &.{ cli, "run", wasm_path }, .expect = row.auto },
        .{ .name = "--engine interp", .argv = &.{ cli, "run", "--engine", "interp", wasm_path }, .expect = row.interp },
        .{ .name = "--engine jit", .argv = &.{ cli, "run", "--engine", "jit", wasm_path }, .expect = row.jit },
        .{ .name = ".cwasm", .argv = &.{ cli, "run", cwasm_path }, .expect = row.cwasm },
    };
    for (lanes) |lane| {
        var o = try runCli(gpa, io, lane.argv);
        defer o.deinit(gpa);
        const ok = matches(o, lane.expect);
        report(row.fixture, lane.name, o, ok);
        if (!ok) failed += 1;
    }
    return failed;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const cli = arg_it.next() orelse return error.MissingCliPath;
    const fixture_dir = arg_it.next() orelse return error.MissingFixtureDir;

    // Scratch for the compiled artifacts, tagged per run so two overlapping
    // runs in one checkout cannot delete each other's tree (the same shape as
    // test/aot/aot_process_diff.zig).
    const cwd = std.Io.Dir.cwd();
    var tag_bytes: [8]u8 = undefined;
    io.random(&tag_bytes);
    var tag_buf: [16]u8 = undefined;
    const tag = try std.fmt.bufPrint(&tag_buf, "{x:0>16}", .{std.mem.readInt(u64, &tag_bytes, .little)});
    const tmp_dir = try std.fmt.allocPrint(gpa, ".zig-cache/default-entry-tmp-{s}", .{tag});
    defer gpa.free(tmp_dir);
    try cwd.createDirPath(io, tmp_dir);
    defer cwd.deleteTree(io, tmp_dir) catch {};

    var failed: u32 = 0;
    for (rows) |row| {
        const wasm_path = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm", .{ fixture_dir, row.fixture });
        defer gpa.free(wasm_path);
        const cwasm_path = try std.fmt.allocPrint(gpa, "{s}/{s}.cwasm", .{ tmp_dir, row.fixture });
        defer gpa.free(cwasm_path);
        const compiled = try std.process.run(gpa, io, .{ .argv = &.{ cli, "compile", wasm_path, "-o", cwasm_path } });
        defer gpa.free(compiled.stdout);
        defer gpa.free(compiled.stderr);
        if (compiled.term != .exited or compiled.term.exited != 0) {
            std.debug.print("default-entry {s}: compile failed: {s}\n", .{ row.fixture, compiled.stderr });
            failed += 1;
            continue;
        }
        failed += try checkRow(gpa, io, cli, row, wasm_path, cwasm_path);
    }

    // C1's escape hatch: the export the chain no longer reaches runs by name,
    // on both drivers.
    const only_f = try std.fmt.allocPrint(gpa, "{s}/only_f.wasm", .{fixture_dir});
    defer gpa.free(only_f);
    for ([_][]const []const u8{
        &.{ cli, "run", "--invoke", "f", only_f },
        &.{ cli, "run", "--engine", "jit", "--invoke", "f", only_f },
    }, [_][]const u8{ "--invoke f", "jit --invoke f" }) |argv, lane| {
        var o = try runCli(gpa, io, argv);
        defer o.deinit(gpa);
        const ok = o.exit == 0 and std.mem.eql(u8, o.stdout, "42\n") and o.stderr.len == 0;
        report("only_f", lane, o, ok);
        if (!ok) failed += 1;
    }

    return if (failed != 0) 1 else 0;
}
