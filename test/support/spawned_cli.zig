//! What a runner that reaches the engine as a SPAWNED BINARY can settle about
//! it by asking (D-598).
//!
//! `scripts/check_releasesafe_runners.sh` holds the ADR-0177 ReleaseSafe floor
//! by grepping `build.zig` for the two channels its author had in mind — the
//! module import and the `addArtifactArg` spawn. A third spelling (an
//! installed `zig-out` path, `addSystemCommand`, a shell wrapper around the
//! CLI) is invisible to it again, and it would report OK while a corpus runner
//! drove the Debug binary for months, which is what happened once already
//! (issue #284). The grep stays — it names the fix at the line that needs
//! changing, before anything is built. This says what actually ran.

const std = @import("std");
const build_options = @import("build_options");

/// The mode the runners' CLI (`exe_rs`) is actually built at — NOT a fixed
/// `ReleaseSafe`. `runner_optimize` floors Debug at ReleaseSafe and passes any
/// other `-Doptimize` through (build.zig `runner_engine_optimize`, ADR-0209),
/// so `zig build test-all -Doptimize=ReleaseFast` hands these lanes a
/// ReleaseFast CLI and that IS the artifact the build selected. Reading the
/// floor as the literal string would red every optimized invocation.
const want_mode = @tagName(build_options.runner_engine_optimize);

/// Refuse to measure anything if the CLI about to be driven is not the build
/// the wiring was supposed to hand over. Called ONCE, before the corpus loop:
/// one binary answers for every fixture.
pub fn assertRunnerBuildMode(gpa: std.mem.Allocator, io: std.Io, exe_path: []const u8) !void {
    const result = try std.process.run(gpa, io, .{ .argv = &.{ exe_path, "--version" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (saysMode(result.stdout, want_mode)) return;
    std.debug.print("WRONG-BUILD-MODE  {s}: --version says \"{f}\", which is not `mode: {s}` (ADR-0177 floor, D-598)\n", .{
        exe_path, std.zig.fmtString(std.mem.trimEnd(u8, result.stdout, "\r\n")), want_mode,
    });
    return error.WrongBuildMode;
}

/// The needle carries the line's closing paren, so a mode never matches a
/// longer one it is a prefix of.
fn saysMode(version_output: []const u8, want: []const u8) bool {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "mode: {s})", .{want}) catch return false;
    return std.mem.find(u8, version_output, needle) != null;
}

test "saysMode: reads the mode field, and a prefix of a longer mode is not it" {
    const t = std.testing;
    try t.expect(saysMode("zwasm v2.7.0 (wasm: wasm_3_0, wasi: p2, engine: both, mode: ReleaseSafe)\n", "ReleaseSafe"));
    try t.expect(!saysMode("zwasm v2.7.0 (wasm: wasm_3_0, wasi: p2, engine: both, mode: Debug)\n", "ReleaseSafe"));
    try t.expect(!saysMode("zwasm v2.7.0 (wasm: wasm_3_0, wasi: p2, engine: both, mode: ReleaseSafe)\n", "Release"));
    // A CLI from before the field existed answers the question with a no.
    try t.expect(!saysMode("zwasm v2.7.0 (wasm: wasm_3_0, wasi: p2, engine: both)\n", "ReleaseSafe"));
}
