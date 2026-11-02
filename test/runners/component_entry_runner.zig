// DBG-INIT-EXEMPT: no zwasm import — the engine runs in the spawned CLI, which reads ZWASM_DEBUG itself (cli/main.zig); std.process.run with no environ_map hands the child this process's environment, so a channel set on this lane reaches it.
//! The CLI's entry contract for a component (#622, ADR-0230). `zwasm run`
//! without `--invoke` runs the `wasi:cli/run` export, found by name; a
//! component without one is refused with its export list on stderr and exit
//! 1. `--invoke NAME[=ARGS]` calls a func export with arguments parsed by its
//! WIT param types and prints the result; a name, an argument count, a value,
//! a param type or an async export it cannot take is refused the same way.
//!
//! Why a subprocess: the refusal is `main.zig`'s stderr line and exit code.
//!
//! Usage: `zig build test-cli-component-entry` /
//!        `zwasm-cli-component-entry <zwasm-cli> <test/component dir>`

const std = @import("std");
const spawned_cli = @import("spawned_cli");

const Observed = struct {
    stdout: []u8,
    stderr: []u8,
    exit: u8,

    fn deinit(self: *Observed, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

const Case = struct {
    fixture: []const u8,
    /// The `--invoke` operand; null runs the default entry.
    invoke: ?[]const u8 = null,
    exit: u8,
    stdout: []const u8 = "",
    /// Empty means stderr must be empty.
    stderr_contains: []const u8 = "",
};

const greet_list = "its exports are: greet: func(name: string) -> string (use --invoke NAME[=args])";
const arity = "--invoke: argument count does not match the export's parameters";

const cases = [_]Case{
    // The entry is `wasi:cli/run` by name, wherever it is lifted.
    .{ .fixture = "wasi_p2_hello", .exit = 0, .stdout = "hello\n" },
    .{ .fixture = "run_second_lift", .exit = 0 },
    // No `wasi:cli/run`: refused, naming the exports.
    .{ .fixture = "greet_component", .exit = 1, .stderr_contains = "has no wasi:cli/run export; " ++ greet_list },
    .{ .fixture = "add_component", .exit = 1, .stderr_contains = "has no wasi:cli/run export; its exports are: add: func(a: u32, b: u32) -> u32 (use --invoke NAME[=args])" },
    // `--invoke` reaches the export, typed by WIT.
    .{ .fixture = "greet_component", .invoke = "greet=world", .exit = 0, .stdout = "Hello, world!\n" },
    .{ .fixture = "greet_component", .invoke = "nope", .exit = 1, .stderr_contains = "has no export nope; " ++ greet_list },
    .{ .fixture = "greet_component", .invoke = "greet=a,b", .exit = 1, .stderr_contains = arity },
    .{ .fixture = "greet_component", .invoke = "greet=", .exit = 0, .stdout = "Hello, !\n" },
    .{ .fixture = "greet_component", .invoke = "greet", .exit = 1, .stderr_contains = arity },
    .{ .fixture = "add_component", .invoke = "add=2,3", .exit = 0, .stdout = "5\n" },
    .{ .fixture = "run_second_lift", .invoke = "add=2,3", .exit = 0, .stdout = "5\n" },
    .{ .fixture = "add_component", .invoke = "add=2", .exit = 1, .stderr_contains = arity },
    .{ .fixture = "add_component", .invoke = "add=x,3", .exit = 1, .stderr_contains = "--invoke: could not parse an argument for the export's parameter type" },
    .{ .fixture = "typed_payload", .invoke = "process=1", .exit = 1, .stderr_contains = "--invoke process: param 'input' is record payload; --invoke takes scalar, char and string parameters" },
    // An async lift needs the task driver, which `--invoke` does not drive.
    .{ .fixture = "async_stdout_write_via_stream", .invoke = "run", .exit = 1, .stderr_contains = "--invoke run: the export is async; --invoke calls sync exports" },
    // The default entry by its path name runs the same way.
    .{ .fixture = "wasi_p2_hello", .invoke = "wasi:cli/run@0.2.0#run", .exit = 0, .stdout = "hello\n" },
};

fn runCli(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Observed {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit = switch (result.term) {
        .exited => |c| c,
        else => 255,
    } };
}

fn matches(o: Observed, c: Case) bool {
    if (o.exit != c.exit or !std.mem.eql(u8, o.stdout, c.stdout)) return false;
    if (c.stderr_contains.len == 0) return o.stderr.len == 0;
    return std.mem.startsWith(u8, o.stderr, "zwasm run: component '") and std.mem.find(u8, o.stderr, c.stderr_contains) != null;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const cli = arg_it.next() orelse return error.MissingCliPath;
    const fixture_dir = arg_it.next() orelse return error.MissingFixtureDir;
    try spawned_cli.assertRunnerBuildMode(gpa, io, cli);

    var failed: u32 = 0;
    for (cases) |c| {
        const path = try gpa.print("{s}/{s}.wasm", .{ fixture_dir, c.fixture });
        defer gpa.free(path);
        var o = if (c.invoke) |spec|
            try runCli(gpa, io, &.{ cli, "run", "--invoke", spec, path })
        else
            try runCli(gpa, io, &.{ cli, "run", path });
        defer o.deinit(gpa);
        const ok = matches(o, c);
        std.debug.print("component-entry {s:<16} --invoke {s:<24} exit {d} stdout \"{f}\" stderr \"{f}\" {s}\n", .{
            c.fixture, c.invoke orelse "-", o.exit, std.zig.fmtString(o.stdout), std.zig.fmtString(o.stderr), if (ok) "ok" else "FAIL",
        });
        if (!ok) failed += 1;
    }
    return if (failed != 0) 1 else 0;
}
