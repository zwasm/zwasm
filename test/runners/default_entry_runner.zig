// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig); std.process.run with no environ_map hands the child this process's environment, so a channel set on this lane reaches it.
//! Default-entry parity across the CLI's run paths (#220). `zwasm run` has two
//! drivers — the `.wasm` default goes through `runWasmCapturedFull`, while
//! `.cwasm` and `--engine jit` go through `runWasmJitCaptured` — and each
//! decides on its own what happens to the entry the lenient chain resolved.
//! The same module must get the same answer from both: this runner spawns the
//! REAL CLI on each fixture as `.wasm`, as `--engine=jit`, and as the
//! `.cwasm` that `zwasm compile` produces, and requires the exit code, stdout
//! and stderr of the JIT-driver lanes to equal the `.wasm` lane's.
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

fn runCli(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Observed {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit = switch (result.term) {
        .exited => |c| c,
        else => 255,
    } };
}

fn report(label: []const u8, lane: []const u8, o: Observed, ok: bool) void {
    std.debug.print("default-entry {s:<18} {s:<14} exit {d} stdout \"{f}\" stderr \"{f}\" {s}\n", .{
        label, lane, o.exit, std.zig.fmtString(o.stdout), std.zig.fmtString(o.stderr), if (ok) "ok" else "FAIL",
    });
}

/// The whole answer: exit code, stdout and stderr.
fn sameAnswer(a: Observed, b: Observed) bool {
    return a.exit == b.exit and std.mem.eql(u8, a.stdout, b.stdout) and std.mem.eql(u8, a.stderr, b.stderr);
}

/// Item 1 — the fixture's `_start` traps: the `.wasm` lane exits non-zero
/// with the trap on stderr, and the `--engine=jit` / `.cwasm` lanes must say
/// the same thing. Returns the number of lanes that diverged.
fn checkTrapParity(gpa: std.mem.Allocator, io: std.Io, cli: []const u8, wasm_path: []const u8, cwasm_path: []const u8) !u32 {
    const label = std.Io.Dir.path.basename(wasm_path);
    var failed: u32 = 0;

    var base = try runCli(gpa, io, &.{ cli, "run", wasm_path });
    defer base.deinit(gpa);
    // The reference lane must itself be loud: two silent-success lanes would
    // "match" and prove nothing.
    const base_ok = base.exit != 0 and base.stderr.len > 0;
    report(label, ".wasm", base, base_ok);
    if (!base_ok) failed += 1;

    var jit = try runCli(gpa, io, &.{ cli, "run", "--engine=jit", wasm_path });
    defer jit.deinit(gpa);
    const jit_ok = sameAnswer(jit, base);
    report(label, "--engine=jit", jit, jit_ok);
    if (!jit_ok) failed += 1;

    var cwasm = try runCli(gpa, io, &.{ cli, "run", cwasm_path });
    defer cwasm.deinit(gpa);
    const cwasm_ok = sameAnswer(cwasm, base);
    report(label, ".cwasm", cwasm, cwasm_ok);
    if (!cwasm_ok) failed += 1;

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

    const start_multi_trap = try std.fmt.allocPrint(gpa, "{s}/start_multi_trap.wasm", .{fixture_dir});
    defer gpa.free(start_multi_trap);
    const start_multi_trap_cwasm = try std.fmt.allocPrint(gpa, "{s}/start_multi_trap.cwasm", .{tmp_dir});
    defer gpa.free(start_multi_trap_cwasm);
    const compiled = try std.process.run(gpa, io, .{ .argv = &.{ cli, "compile", start_multi_trap, "-o", start_multi_trap_cwasm } });
    defer gpa.free(compiled.stdout);
    defer gpa.free(compiled.stderr);
    if (compiled.term != .exited or compiled.term.exited != 0) {
        std.debug.print("default-entry start_multi_trap: compile failed: {s}\n", .{compiled.stderr});
        return 1;
    }
    failed += try checkTrapParity(gpa, io, cli, start_multi_trap, start_multi_trap_cwasm);

    return if (failed != 0) 1 else 0;
}
