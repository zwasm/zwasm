//! Edge-case fixture runner (sub-7.5b-iii).
//!
//! Walks `test/edge_cases/p<N>/<concept>/<case>.wasm` triples,
//! reads the sibling `.expect`, runs the wasm through the JIT
//! via `engine.runner.runI32Export`, and compares the result.
//! Reports pass/fail counts to stdout.
//!
//! Usage:
//!   zwasm-edge-runner <corpus-dir>
//!
//! §9.9 / 9.9-j-2b (per ADR-0056): host-arch gate removed
//! (D-086 close). Phase 9 SIMD work proved the JIT pipeline
//! works end-to-end on both Mac aarch64 and OrbStack x86_64;
//! the sub-7.5b-iii era "panic on non-darwin-aarch64" guard
//! is stale. Runs on all hosts that can compile the engine.

const std = @import("std");

const zwasm = @import("zwasm");
const run_wasm = zwasm.engine.runner;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?; // executable name
    const corpus_dir_arg = arg_it.next() orelse {
        try stdout.print("usage: zwasm-edge-runner <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };

    var passed: u32 = 0;
    var failed: u32 = 0;
    try walkAndRun(io, gpa, stdout, corpus_dir_arg, &passed, &failed);

    // A corpus may state which of its directories are supposed to yield
    // result-checked fixtures. Without that statement this runner cannot tell
    // an empty directory from a passing one — both report zero failures — so a
    // directory whose fixtures were never produced reads as green forever.
    const unmet = try checkExpected(io, gpa, stdout, corpus_dir_arg);

    // `unmet` belongs on this line: a ledger violation exits 1, and a summary
    // reading "0 failed" next to that exit is what a CI log tail would show.
    if (unmet) {
        try stdout.print("\nedge-case runner: {d} passed, {d} failed, corpus does not match EXPECTED.txt\n", .{ passed, failed });
    } else {
        try stdout.print("\nedge-case runner: {d} passed, {d} failed\n", .{ passed, failed });
    }
    try stdout.flush();
    if (failed != 0 or unmet) std.process.exit(1);
}

/// Reads `<root>/EXPECTED.txt` if present and reports on it. Returns true when
/// the corpus does not match what it says about itself.
///
/// Each non-comment line is `<dir> expect=fixtures` or
/// `<dir> expect=skip <reason>`:
///
///   - `expect=fixtures` and the directory yields no fixture this runner can
///     reach a verdict on — reported and fails the lane.
///   - `expect=skip` — printed with its reason and does not fail. The reason
///     is required; a skip with nothing to say is the silence this file exists
///     to remove.
///   - a directory named here that does not exist — fails.
///   - a directory present in the corpus and NOT named here — fails.
///
/// That last rule is what makes this a ledger rather than a roster. Listing
/// only the directories someone remembered to list would close today's silent
/// green and leave the next one open: drop in a new directory holding nothing
/// but a README and it would pass unmentioned, which is exactly the defect.
/// The cost is that adding a directory means adding a line here.
///
/// Absent `EXPECTED.txt`, nothing changes: the other corpora this runner
/// serves keep their plain walk.
fn checkExpected(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    root_path: []const u8,
) !bool {
    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, root_path, .{ .iterate = true }) catch |err| {
        // Reverting to the plain walk on an unreadable root would report green
        // for a corpus nothing examined — the same silence the ledger removes.
        stdout.print("EXPECTED  cannot open the corpus root: {s}\n", .{@errorName(err)}) catch {};
        return true;
    };
    defer root.close(io);

    const text = root.readFileAlloc(io, "EXPECTED.txt", gpa, .limited(64 << 10)) catch |err| {
        // Only "there is no such file" means this corpus opted out. Anything
        // else — unreadable, too large — is a corpus that HAS a ledger the
        // runner could not consult, and silently reverting to the plain walk
        // there would reinstate the very silence this file removes.
        if (err == error.FileNotFound) return false;
        stdout.print("EXPECTED  cannot read EXPECTED.txt: {s}\n", .{@errorName(err)}) catch {};
        return true;
    };
    defer gpa.free(text);

    // Every directory in the root must be accounted for, so collect them and
    // strike each off as its line is read.
    var seen = std.StringHashMap(void).init(gpa);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit();
    }
    {
        var it = root.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            const owned = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(owned);
            // Dropping this entry would remove it from the leftover sweep, so
            // the directory would never be reported as unmentioned.
            try seen.put(owned, {});
        }
    }

    var unmet = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const dir_name = fields.next() orelse continue;
        const expect_field = fields.next() orelse {
            try stdout.print("EXPECTED  {s}: malformed line (no expect=)\n", .{dir_name});
            unmet = true;
            continue;
        };
        const want_fixtures = std.mem.eql(u8, expect_field, "expect=fixtures");
        const want_skip = std.mem.eql(u8, expect_field, "expect=skip");
        if (!want_fixtures and !want_skip) {
            try stdout.print("EXPECTED  {s}: unknown '{s}'\n", .{ dir_name, expect_field });
            unmet = true;
            continue;
        }

        if (seen.fetchRemove(dir_name)) |kv| {
            gpa.free(kv.key);
        } else {
            // Either the directory is missing, or an earlier line already
            // claimed it. Both are the ledger disagreeing with the corpus.
            try stdout.print("EXPECTED  {s}: named here but not present as an unclaimed directory\n", .{dir_name});
            unmet = true;
            continue;
        }

        const reason = std.mem.trim(u8, fields.rest(), " \t");
        if (want_skip and reason.len == 0) {
            try stdout.print("EXPECTED  {s}: expect=skip needs a reason\n", .{dir_name});
            unmet = true;
            continue;
        }
        if (want_fixtures and reason.len != 0) {
            try stdout.print("EXPECTED  {s}: trailing text after expect=fixtures: '{s}'\n", .{ dir_name, reason });
            unmet = true;
            continue;
        }
        if (want_skip) {
            const after_prefix = if (std.mem.startsWith(u8, reason, "reason=")) reason["reason=".len..] else reason;
            const shown = std.mem.trim(u8, after_prefix, " \t");
            if (shown.len == 0) {
                try stdout.print("EXPECTED  {s}: expect=skip needs a reason\n", .{dir_name});
                unmet = true;
                continue;
            }
            try stdout.print("SKIP      {s}: {s}\n", .{ dir_name, shown });
            continue;
        }

        var sub = root.openDir(io, dir_name, .{ .iterate = true }) catch {
            try stdout.print("EXPECTED  {s}: cannot open the directory\n", .{dir_name});
            unmet = true;
            continue;
        };
        defer sub.close(io);
        if (try countResultChecked(io, gpa, &sub) == 0) {
            try stdout.print("EXPECTED  {s}: expected fixtures this runner can judge, found none\n", .{dir_name});
            unmet = true;
        }
    }

    // Whatever is left was never mentioned.
    var leftover = seen.keyIterator();
    while (leftover.next()) |name| {
        try stdout.print("EXPECTED  {s}: present in the corpus but absent from EXPECTED.txt\n", .{name.*});
        unmet = true;
    }
    return unmet;
}

/// Fixtures in `dir` (recursively) that this runner would actually check: a
/// `.wasm` whose sibling `.expect` states an expectation this runner
/// understands.
///
/// The `.expect` must PARSE, not merely exist. A sidecar the runner cannot
/// read an expectation out of fails the lane at run time, so counting it here
/// would let a directory satisfy `expect=fixtures` on the strength of a
/// fixture that is about to be reported broken.
fn countResultChecked(io: std.Io, gpa: std.mem.Allocator, dir: *std.Io.Dir) !u32 {
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var n: u32 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".wasm")) continue;
        const expect_path = try std.mem.concat(gpa, u8, &.{
            entry.path[0 .. entry.path.len - ".wasm".len],
            ".expect",
        });
        defer gpa.free(expect_path);
        // An unreadable sidecar is propagated rather than skipped: silently
        // not counting it lets a sibling that does parse satisfy
        // `expect=fixtures` on the directory's behalf.
        const bytes = dir.readFileAlloc(io, expect_path, gpa, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer gpa.free(bytes);
        if (parseExpect(bytes) != .unsupported) n += 1;
    }
    return n;
}

/// Recursively walks `root_path`. For each `<case>.wasm` whose
/// sibling `<case>.expect` exists, runs the fixture and
/// compares the result.
fn walkAndRun(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    root_path: []const u8,
    passed: *u32,
    failed: *u32,
) !void {
    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, root_path, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ root_path, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry_| {
        if (entry_.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry_.path, ".wasm")) continue;

        const wasm_bytes = root.readFileAlloc(io, entry_.path, gpa, .limited(1 << 20)) catch |err| {
            try stdout.print("FAIL  {s}: read .wasm: {s}\n", .{ entry_.path, @errorName(err) });
            failed.* += 1;
            continue;
        };
        defer gpa.free(wasm_bytes);

        // Sibling `.expect` (replace `.wasm` extension).
        const expect_path = try std.mem.concat(gpa, u8, &.{
            entry_.path[0 .. entry_.path.len - ".wasm".len],
            ".expect",
        });
        defer gpa.free(expect_path);
        const expect_bytes = root.readFileAlloc(io, expect_path, gpa, .limited(4096)) catch |err| {
            try stdout.print("FAIL  {s}: read .expect: {s}\n", .{ entry_.path, @errorName(err) });
            failed.* += 1;
            continue;
        };
        defer gpa.free(expect_bytes);

        runOne(gpa, stdout, entry_.path, wasm_bytes, expect_bytes, passed, failed) catch |err| {
            try stdout.print("FAIL  {s}: {s}\n", .{ entry_.path, @errorName(err) });
            failed.* += 1;
        };
    }
}

/// Parse `expect_bytes` to determine the assertion (value or
/// trap), run the fixture, compare. Increments `passed` /
/// `failed` accordingly.
fn runOne(
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    name: []const u8,
    wasm_bytes: []const u8,
    expect_bytes: []const u8,
    passed: *u32,
    failed: *u32,
) !void {
    const expect = parseExpect(expect_bytes);
    const result = run_wasm.runI32Export(gpa, wasm_bytes, "test");

    switch (expect) {
        .i32 => |want| {
            if (result) |got| {
                if (got == want) {
                    try stdout.print("PASS  {s} = {d}\n", .{ name, got });
                    passed.* += 1;
                } else {
                    try stdout.print("FAIL  {s}: expected i32:{d}, got i32:{d}\n", .{ name, want, got });
                    failed.* += 1;
                }
            } else |err| switch (err) {
                error.Trap => {
                    try stdout.print("FAIL  {s}: expected i32:{d}, got trap\n", .{ name, want });
                    failed.* += 1;
                },
                else => |e| return e,
            }
        },
        .trap => {
            if (result) |got| {
                try stdout.print("FAIL  {s}: expected trap, got i32:{d}\n", .{ name, got });
                failed.* += 1;
            } else |err| switch (err) {
                error.Trap => {
                    try stdout.print("PASS  {s} (trap)\n", .{name});
                    passed.* += 1;
                },
                else => |e| return e,
            }
        },
        .unsupported => {
            // A sidecar the runner cannot parse is a broken fixture, not a
            // skip. Counting it as neither would drop it from the denominator
            // — #226 one level down, at file rather than directory grain.
            try stdout.print("FAIL  {s}: unsupported expectation format\n", .{name});
            failed.* += 1;
        },
    }
}

const Expectation = union(enum) {
    i32: u32,
    trap: void,
    unsupported: void,
};

fn parseExpect(bytes: []const u8) Expectation {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "i32:")) {
        const num_str = std.mem.trim(u8, trimmed["i32:".len..], " \t");
        const v = std.fmt.parseInt(i64, num_str, 10) catch return .unsupported;
        // Wrap negatives into u32 representation (i32.MIN → 0x80000000).
        return .{ .i32 = @bitCast(@as(i32, @intCast(v))) };
    }
    if (std.mem.startsWith(u8, trimmed, "trap:")) return .trap;
    return .unsupported;
}
