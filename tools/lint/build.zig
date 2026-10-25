//! `zig build lint` lives here, not in the root `build.zig`, so that the
//! zlinter dependency stays out of the root package's dependency graph.
//! The root build file delegates to this one; see the `lint` step there.
//!
//! Zig resolves a build file's manifest by the fixed name `build.zig.zon`
//! next to it, so a second manifest needs a second directory — that, and not
//! zlinter's API shape, is why the lint wiring moved out of the root build
//! file rather than staying there behind a lazy dependency (ADR-0214).
const std = @import("std");
// TODO(adr-0009): drop the zlinter dep when Zig ships the @deprecated()
// builtin + -fdeprecated flag (ziglang/zig#22822, accepted on urgent
// milestone, expected 0.17+; measured absent on 0.16.0 2026-08-22).
// Tracked in .dev/proposal_watch.md.
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    // zlinter defaults its include set to this build file's own root, which
    // is `tools/lint`, so the tree to lint has to be named explicitly. The
    // linter runs with `tools/lint` as its cwd, hence an absolute path.
    const repo_root = b.pathResolve(&.{b.root.joinString(b.allocator, "../..") catch @panic("OOM")});

    // Fail closed on a mis-resolved root. Measured: an include root that does
    // not exist panics in zlinter's walk, but one that exists and holds no
    // Zig files reports "No issues!" and exits 0 — a lint gate that passes
    // having linted nothing. This turns that into a build error.
    b.root.access(b.graph.io, "../../src", .{ .read = true }) catch |err|
        std.debug.panic(
            "lint root {s} does not contain src/ ({s}) — tools/lint moved?",
            .{ repo_root, @errorName(err) },
        );

    // Rule chain per ADR-0009 + the Phase B expansion. See
    // `private/zlinter-builtins-survey-2026-05-03.md` for per-rule rationale
    // and the spike-time finding counts.
    const lint_step = b.step("lint", "Lint source code (zlinter).");
    lint_step.dependOn(blk: {
        var builder = zlinter.builder(b, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{});
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        builder.addRule(.{ .builtin = .no_empty_block }, .{});
        builder.addRule(.{ .builtin = .require_exhaustive_enum_switch }, .{});
        builder.addRule(.{ .builtin = .no_unused }, .{});
        builder.addPaths(.{ .include = &.{.{ .cwd_relative = repo_root }} });
        break :blk builder.build();
    });
}
