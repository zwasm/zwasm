//! Regression runner for issue #302: whichever entry point a process reaches
//! FIRST must arm the fault handler and publish `rt.stack_limit`.
//!
//! Contract: with guard-page bounds elision (ADR-0202 D4), an oob access in
//! JIT code is a hardware fault the production handler redirects to the oob
//! stub — but only if a handler is armed. `entry.invokeAndCheck` /
//! `invokeAndCheckVoid` armed it; the three mixed multi-result inline-asm
//! thunks and `entry_buffer_write.invokeBufferWrite` did not, so a process
//! whose first JIT call was one of those ran JIT code with no handler armed:
//! a guest oob access killed it with SIGSEGV instead of trapping, and the
//! prologue's stack probe read an unset `stack_limit` (0 disables the probe).
//!
//! Why a standalone exe: the install flag is process-global and sticky, and
//! any in-process JIT invoke arms it via `ensureInstalled` — no test inside a
//! shared test binary can rely on a virgin flag. This parent never executes
//! JIT code (it only compiles and sets up guarded memory) and forks one child
//! per export, so each child's first JIT instruction is the entry point under
//! test. A child that dies by signal, or returns a non-trap error, is the
//! regression.
//!
//! Windows: fork is unavailable, so the runner self-skips (exit 0), as
//! `signal_install_order_runner.zig` does. fork/waitpid/_exit = ADR-0070
//! necessary (test-only).

const std = @import("std");
const builtin = @import("builtin");
const zwasm = @import("zwasm");
const runner = zwasm.engine.runner;
const entry = zwasm.engine.codegen.shared.entry;

/// A child that faults with no handler armed dies by signal — that is the
/// regression this runner reports — so Zig's own handler stays off.
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

const EXIT_OK: u8 = 0;
const EXIT_NO_TRAP: u8 = 9;
const EXIT_INFRA: u8 = 12;

const Scenario = enum { mixed_i32f64, mixed_f64i32, mixed_f64f32, buffer_write };

const Row = struct { scenario: Scenario, export_name: []const u8 };

const rows = [_]Row{
    // The production multi-result path (wrapper thunk → invokeBufferWrite).
    .{ .scenario = .buffer_write, .export_name = "multi3" },
    // The three inline-asm mixed multi-result thunks, one export each.
    .{ .scenario = .mixed_i32f64, .export_name = "i32f64" },
    .{ .scenario = .mixed_f64i32, .export_name = "f64i32" },
    .{ .scenario = .mixed_f64f32, .export_name = "f64f32" },
};

const Outcome = enum { trapped, no_trap, killed_by_signal, infra };

/// One JIT entry through `scenario`'s entry point; `true` when the guest's
/// elided oob load surfaces as `error.Trap`. Any other answer — including the
/// process dying — is a failure, so the caller reads it out of the child's
/// exit status instead of an in-process `catch`.
fn firstEntryTraps(
    inst: *runner.JitInstance,
    func_idx: u32,
    scenario: Scenario,
    export_name: []const u8,
    gpa: std.mem.Allocator,
) bool {
    var results: [3]runner.TypedResult = undefined;
    return switch (scenario) {
        .buffer_write => if (inst.invokeMulti(gpa, export_name, &.{}, results[0..3])) |_| false else |err| err == error.Trap,
        .mixed_i32f64 => if (entry.callI32f64NoArgs(inst.compiled.module, func_idx, &inst.owned.rt)) |_| false else |err| err == error.Trap,
        .mixed_f64i32 => if (entry.callF64i32NoArgs(inst.compiled.module, func_idx, &inst.owned.rt)) |_| false else |err| err == error.Trap,
        .mixed_f64f32 => if (entry.callF64f32NoArgs(inst.compiled.module, func_idx, &inst.owned.rt)) |_| false else |err| err == error.Trap,
    };
}

fn runRow(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    row: Row,
) !Outcome {
    // Heap-pinned for a stable address across the fork and the JIT call.
    const inst = try gpa.create(runner.JitInstance);
    defer gpa.destroy(inst);
    inst.* = try runner.JitInstance.init(gpa, wasm_bytes);
    defer inst.deinit(gpa);
    const func_idx = try runner.findExportFunc(gpa, wasm_bytes, row.export_name);

    const pid = std.c.fork();
    if (pid == -1) return .infra;
    if (pid == 0) {
        std.c._exit(if (firstEntryTraps(inst, func_idx, row.scenario, row.export_name, gpa)) EXIT_OK else EXIT_NO_TRAP);
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    if (!std.posix.W.IFEXITED(ustatus)) return .killed_by_signal;
    return switch (std.posix.W.EXITSTATUS(ustatus)) {
        EXIT_OK => .trapped,
        EXIT_NO_TRAP => .no_trap,
        else => .infra,
    };
}

pub fn main(init: std.process.Init) !u8 {
    if (comptime builtin.os.tag == .windows) {
        std.debug.print("first-entry-arm: SKIP (fork unavailable on Windows; the entry arm is shared with the POSIX paths but unexercised here)\n", .{});
        return 0;
    }
    const io = init.io;
    const gpa = init.gpa;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const fixture_dir = arg_it.next() orelse return error.MissingFixtureDir;
    const path = try std.fmt.allocPrint(gpa, "{s}/oob_entries.wasm", .{fixture_dir});
    defer gpa.free(path);
    const wasm_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(wasm_bytes);

    var failed: u32 = 0;
    for (rows) |row| {
        const outcome = runRow(gpa, wasm_bytes, row) catch |err| {
            std.debug.print("first-entry-arm {s}: INFRA {s}\n", .{ row.export_name, @errorName(err) });
            failed += 1;
            continue;
        };
        if (outcome != .trapped) failed += 1;
        std.debug.print("first-entry-arm {s}: {s}\n", .{ row.export_name, @tagName(outcome) });
    }
    if (failed != 0) {
        std.debug.print("first-entry-arm: {d} scenario(s) did not trap (#302)\n", .{failed});
        return 1;
    }
    return 0;
}
