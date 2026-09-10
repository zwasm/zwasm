// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig).
//! One verdict from every CLI path (#233). `zwasm run` has two drivers (the
//! `.wasm` default through the C API's `.auto`, `--engine=jit` through the JIT
//! runner) and `zwasm compile` a third path; an invalid module must fail on
//! all three with the reason on stderr — whether the front-end validator
//! judges it (`global_self_ref`) or only the JIT's module-level check does
//! (`start_param`, `dup_export`; #285's remainder). Before #233 the default
//! driver ran those two on the interpreter and exited 0.
//!
//! Usage: `zig build test-cli-invalid-module` /
//!        `zwasm-cli-invalid-module <zwasm-cli> <fixture-dir>`

const std = @import("std");

const Fixture = struct { file: []const u8, reason: []const u8 };

/// `reason` is what each lane's stderr must contain: the JIT's error name for
/// the two modules only it judges, the validator's message for the third.
const fixtures = [_]Fixture{
    .{ .file = "start_param.wasm", .reason = "InvalidStartFunction" },
    .{ .file = "dup_export.wasm", .reason = "DuplicateExport" },
    .{ .file = "global_self_ref.wasm", .reason = "constant expression" },
    // A rejection `frontendValidate` makes without setting a diagnostic (a
    // function's typeidx past the type section): every lane still says why,
    // generically (PR #429 review).
    .{ .file = "func_type_oob.wasm", .reason = "decode/validate failed" },
};

const Observed = struct { stderr: []u8, exit: u8 };

fn runCli(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Observed {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    gpa.free(result.stdout);
    return .{ .stderr = result.stderr, .exit = switch (result.term) {
        .exited => |c| c,
        else => 255,
    } };
}

/// exit 1 and the reason on stderr; anything else is a lane that let the
/// module through or lost the reason.
fn check(gpa: std.mem.Allocator, io: std.Io, lane: []const u8, argv: []const []const u8, fx: Fixture) !bool {
    const o = try runCli(gpa, io, argv);
    defer gpa.free(o.stderr);
    const ok = o.exit == 1 and std.mem.find(u8, o.stderr, fx.reason) != null;
    std.debug.print("invalid-module {s:<20} {s:<12} exit {d} stderr \"{f}\" {s}\n", .{
        fx.file, lane, o.exit, std.zig.fmtString(std.mem.trimEnd(u8, o.stderr, "\n")), if (ok) "ok" else "FAIL",
    });
    return ok;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const cli = arg_it.next() orelse return error.MissingCliPath;
    const fixture_dir = arg_it.next() orelse return error.MissingFixtureDir;

    // Scratch for `compile`'s output, tagged per run (the shape of
    // default_entry_runner.zig).
    const cwd = std.Io.Dir.cwd();
    var tag_bytes: [8]u8 = undefined;
    io.random(&tag_bytes);
    var tag_buf: [16]u8 = undefined;
    const tag = try std.fmt.bufPrint(&tag_buf, "{x:0>16}", .{std.mem.readInt(u64, &tag_bytes, .little)});
    const tmp_dir = try std.fmt.allocPrint(gpa, ".zig-cache/invalid-module-tmp-{s}", .{tag});
    defer gpa.free(tmp_dir);
    try cwd.createDirPath(io, tmp_dir);
    defer cwd.deleteTree(io, tmp_dir) catch {};
    const cwasm_path = try std.fmt.allocPrint(gpa, "{s}/out.cwasm", .{tmp_dir});
    defer gpa.free(cwasm_path);

    var failed: u32 = 0;
    for (fixtures) |fx| {
        const wasm_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ fixture_dir, fx.file });
        defer gpa.free(wasm_path);
        if (!try check(gpa, io, "run", &.{ cli, "run", wasm_path }, fx)) failed += 1;
        if (!try check(gpa, io, "run --engine=jit", &.{ cli, "run", "--engine=jit", wasm_path }, fx)) failed += 1;
        if (!try check(gpa, io, "compile", &.{ cli, "compile", wasm_path, "-o", cwasm_path }, fx)) failed += 1;
    }
    std.debug.print("invalid-module: {d} fixtures x 3 lanes, {d} failed\n", .{ fixtures.len, failed });
    return if (failed != 0) 1 else 0;
}
