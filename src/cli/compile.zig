//! `zwasm compile <input.wasm> -o <output.cwasm>` subcommand
//! handler (§9.8b / 8b.3-d per ADR-0039).
//!
//! Reads a `.wasm` file, runs it through the JIT pipeline
//! (`engine.runner.compileWasm`), then wraps the per-func
//! emit outputs into a `.cwasm` v0.1 artifact via
//! `engine.codegen.aot.produce.produceFromCompiledWasm`,
//! and writes the artifact to disk.
//!
//! Generator side of the `.cwasm` pipeline; `zwasm run <file.cwasm>`
//! executes the artifact through the full-fidelity deserializer + the
//! normal JIT setup path (ADR-0203 stage 3 — same flow as a `.wasm`).
//!
//! Zone 3 (`src/cli/`).

const std = @import("std");

const zwasm = @import("zwasm");
const runner = zwasm.engine.runner;
const aot_produce = zwasm.engine.codegen.aot.produce;

const Allocator = std.mem.Allocator;

pub const Error = error{
    UsageError,
    ReadInputFailed,
    WriteOutputFailed,
    /// #233 — the front-end validator rejected the input; the diagnostic is
    /// already on stderr, the way `zwasm run` reports it.
    InvalidModule,
} || runner.Error || aot_produce.Error;

/// Drive the compile subcommand. `arg_it` is positioned past
/// the leading `compile` token; the handler consumes
/// `<input.wasm>` and `-o <output.cwasm>` (in either order).
/// Returns the exit code: 0 on success, non-zero on usage /
/// runtime failure (caller surfaces stderr separately).
pub fn run(
    gpa: Allocator,
    io: std.Io,
    arg_it: anytype,
) Error!u8 {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = arg_it.next() orelse return Error.UsageError;
        } else if (input_path == null) {
            input_path = arg;
        } else {
            return Error.UsageError;
        }
    }

    const in = input_path orelse return Error.UsageError;
    const out = output_path orelse return Error.UsageError;

    const cwd = std.Io.Dir.cwd();
    const wasm_bytes = cwd.readFileAlloc(io, in, gpa, .limited(64 * 1024 * 1024)) catch {
        return Error.ReadInputFailed;
    };
    defer gpa.free(wasm_bytes);

    // #233 — validate before compiling, as `zwasm run` and `wasm_module_new`
    // do, so `compile` starts from the same verdict; the JIT's own
    // module-level checks (#285's remainder) still follow in `compileWasm`.
    // Cleared first so a failure without a fresh diagnostic cannot print an
    // earlier one (PR #429 review).
    zwasm.diagnostic.clearDiag();
    if (!@import("../runtime/instance/instantiate.zig").frontendValidate(gpa, wasm_bytes)) {
        // Most of `frontendValidate`'s rejections set no diagnostic; say so
        // generically rather than exit in silence, as `zwasm run` does.
        if (zwasm.diagnostic.lastDiagnostic() == null) {
            zwasm.diagnostic.setDiag(.instantiate, .module_alloc_failed, .unknown, "module decode/validate failed", .{});
        }
        var stderr_buf: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
        const stderr = &stderr_writer.interface;
        if (zwasm.diagnostic.lastDiagnostic()) |diag| {
            // EXEMPT-FALLBACK: ADR-0016 phase 1 — diagnostic render is last-resort stderr; re-entry on failure is meaningless.
            zwasm.cli.diag_print.formatDiagnostic(diag, .{ .filename = in, .bytes = wasm_bytes }, stderr) catch {};
            // EXEMPT-FALLBACK: ADR-0016 phase 1 — flushing the stderr that just rendered the diagnostic; failure here is unrecoverable.
            stderr.flush() catch {};
        }
        return Error.InvalidModule;
    }

    // ADR-0203 stage 4 — the compile honours the ambient bounds mode
    // (default `.auto` → elided on qualifying memories); the artifact
    // records `flag_bounds_elided` and the loader upholds the ADR-0202
    // guarded-binding invariant.
    var compiled = try runner.compileWasmForAot(gpa, wasm_bytes);
    defer compiled.deinit(gpa);

    const cwasm_bytes = try aot_produce.produceFromCompiledWasm(gpa, &compiled, wasm_bytes);
    defer gpa.free(cwasm_bytes);

    cwd.writeFile(io, .{ .sub_path = out, .data = cwasm_bytes }) catch {
        return Error.WriteOutputFailed;
    };

    return 0;
}
