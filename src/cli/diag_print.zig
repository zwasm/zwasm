//! CLI-side renderer for `diagnostic/diagnostic.zig` payloads
//! (ADR-0016 phase 1).
//!
//! `formatDiagnostic` is the data-driven renderer the CLI / test
//! runners call when they have a populated diagnostic.
//! `renderFallback` is the path for unwired error sites — it
//! prints the legacy `error: failed to <verb>: <@errorName>` form
//! so the CLI never produces a less-informative message than v1.
//!
//! Phase 1 supports the `instantiate` case at full granularity
//! (the §5/Q-C case (c) shape from the survey) and the
//! `parse` / `validate` / `execute` / `wasi` cases at fall-through
//! (kind name only) until M2/M3 fill in the per-phase Location
//! variants.
//!
//! Zone 3 (`src/cli/`) — may import any layer below.

const std = @import("std");

const diagnostic = @import("../diagnostic/diagnostic.zig");

const Info = diagnostic.Info;
const Phase = diagnostic.Phase;

/// `Source` is the per-render context — filename for the message
/// header, optional bytes if the renderer wants to cite hex
/// around a byte offset (M2+ when the parse Location has byte
/// offsets). Phase 1 reads only `filename`.
pub const Source = struct {
    filename: []const u8,
    bytes: ?[]const u8 = null,
};

/// Render a diagnostic to `writer`. Output is one or more lines
/// ending in `\n`; the caller handles flushing.
pub fn formatDiagnostic(
    diag: *const Info,
    source: Source,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    switch (diag.phase) {
        .instantiate => {
            try writer.print("zwasm: instantiation failed for {s}: {s}\n", .{
                source.filename,
                diag.message(),
            });
        },
        .parse => {
            try writer.print("zwasm: parse error in {s}: {s}\n", .{
                source.filename,
                diag.message(),
            });
        },
        .validate => {
            // ADR-0016 M3 — surface the captured failure site (fn_idx + body
            // offset) the validator already records, instead of dropping it.
            if (diag.location == .validate) {
                const v = diag.location.validate;
                try writer.print("zwasm: validation error in {s} (func #{d} @ 0x{x}): {s}\n", .{
                    source.filename,
                    v.fn_idx,
                    v.body_offset,
                    diag.message(),
                });
            } else {
                try writer.print("zwasm: validation error in {s}: {s}\n", .{
                    source.filename,
                    diag.message(),
                });
            }
        },
        .execute => {
            try writer.print("zwasm: trapped in {s}: {s}\n", .{
                source.filename,
                diag.message(),
            });
        },
        .wasi => {
            try writer.print("zwasm: wasi error in {s}: {s}\n", .{
                source.filename,
                diag.message(),
            });
        },
        .unknown => {
            try writer.print("zwasm: error in {s} ({s}): {s}\n", .{
                source.filename,
                @tagName(diag.kind),
                diag.message(),
            });
        },
    }
}

/// Fallback renderer for the `lastDiagnostic() == null` case —
/// prints the legacy `error: failed to <verb>: <@errorName>` form
/// so unwired error sites still produce useful output.
pub fn renderFallback(
    err: anyerror,
    source: Source,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.print("zwasm: {s}: {s}\n", .{
        source.filename,
        @errorName(err),
    });
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "formatDiagnostic: instantiate phase renders the §5/Q-C (c) shape" {
    diagnostic.clearDiag();
    diagnostic.setDiag(
        .instantiate,
        .module_alloc_failed,
        .unknown,
        "module decode/validate failed (no further detail in phase 1)",
        .{},
    );
    const d = diagnostic.lastDiagnostic().?;

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatDiagnostic(d, .{ .filename = "foo.wasm" }, &w);

    const got = w.buffered();
    const want = "zwasm: instantiation failed for foo.wasm: module decode/validate failed (no further detail in phase 1)\n";
    try testing.expect(std.mem.eql(u8, got, want));
}

test "formatDiagnostic: validate phase renders the captured func# + body offset (M3 F5b)" {
    diagnostic.clearDiag();
    diagnostic.setDiag(
        .validate,
        .other,
        .{ .validate = .{ .fn_idx = 7, .body_offset = 0x12, .opcode = 0x20 } },
        "type mismatch",
        .{},
    );
    const d = diagnostic.lastDiagnostic().?;

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatDiagnostic(d, .{ .filename = "f.wasm" }, &w);

    const got = w.buffered();
    const want = "zwasm: validation error in f.wasm (func #7 @ 0x12): type mismatch\n";
    try testing.expect(std.mem.eql(u8, got, want));
}

test "formatDiagnostic: unknown phase prints kind tag" {
    diagnostic.clearDiag();
    diagnostic.setDiag(.unknown, .other, .unknown, "something happened", .{});
    const d = diagnostic.lastDiagnostic().?;

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatDiagnostic(d, .{ .filename = "x.wasm" }, &w);

    const got = w.buffered();
    try testing.expect(std.mem.startsWith(u8, got, "zwasm: error in x.wasm (other): something happened"));
}

test "renderFallback: prints @errorName form" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderFallback(error.ModuleAllocFailed, .{ .filename = "bar.wasm" }, &w);

    const got = w.buffered();
    try testing.expect(std.mem.eql(u8, got, "zwasm: bar.wasm: ModuleAllocFailed\n"));
}

test "formatDiagnostic: trailing-newline contract holds for every Phase variant" {
    const phases = [_]Phase{ .parse, .validate, .instantiate, .execute, .wasi, .unknown };
    for (phases) |p| {
        diagnostic.clearDiag();
        diagnostic.setDiag(p, .other, .unknown, "msg", .{});
        const d = diagnostic.lastDiagnostic().?;

        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try formatDiagnostic(d, .{ .filename = "f" }, &w);

        const got = w.buffered();
        try testing.expect(got.len > 0);
        try testing.expectEqual(@as(u8, '\n'), got[got.len - 1]);
    }
}
