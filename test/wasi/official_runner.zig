//! Official `wasi-testsuite` wasm32-wasip1 conformance runner (D-582).
//!
//! Walks the vendored corpus under `test/wasi/wasip1_official/<lang>/`, drives
//! every `.wasm` through the CLI run path, and asserts the upstream manifest's
//! expectations. Supersedes `test-wasi-p1` as the conformance claim — that
//! step stays (ADR-0208 D2) and still covers the `.expected_exit` / `.env`
//! sidecar path, but the corpus it walks is `hello` / `env_echo` /
//! `proc_exit_42`, so nothing in it could catch a preview1 regression.
//!
//! Usage:
//!   official_runner <corpus-root> [interp|jit]     # default: interp
//!
//! Exit code: 2 on a usage error, 1 on anything below, 0 otherwise.
//!
//! - a test failed (`failed`) or could not be run (`errored`);
//! - the corpus ROOT is unopenable;
//! - a suite carries upstream's descriptor but enumerates no tests;
//! - the root holds no suites at all;
//! - the run executed a number of tests other than `vendored_total`.
//!
//! The last four are the same rule: the corpus is committed, so its absence
//! is a path or vendoring failure, and "0 tests, all green" must never be a
//! reachable verdict (ADR-0174 no-silent-skip, the posture the spec-assert
//! runners take). The per-suite checks do not close it on their own — a suite
//! that kept 2 of its 46 tests still enumerates non-empty — which is why
//! ADR-0208 D2 requires the total too. The exact PER-LANGUAGE counts stay in
//! `scripts/vendor_wasip1_official.sh`, which asserts them at regen; only the
//! single total is repeated here.
//!
//! ## Upstream manifest subset
//!
//! Each `<test>.json` beside the binary may carry `args` / `env` / `root` /
//! `stdout` / `exit_code`; absent manifest = run with no argv/env/preopen and
//! expect exit 0. Those five keys are the whole schema in use at the pinned
//! commit (surveyed across all 55 test manifests), so an unknown key is
//! reported rather than ignored — upstream growing the schema must be a loud
//! event, not a silently-dropped expectation.
//!
//! ## Two constraints this runner exists to honour
//!
//! 1. **A fresh preopen tree per test.** The tests mutate the tree, and a
//!    reused one turns a real failure into a pass: `dangling_symlink` fails on
//!    a clean tree (20/20), leaves `dangling_symlink_symlink.cleanup` behind,
//!    and every later run against that same tree passes. Measuring with a
//!    shared tree under-reports (D-583).
//! 2. **A pinned engine, one lane at a time.** The default `.auto` prefers the
//!    JIT, so an unpinned lane silently measures the JIT and calls it preview1
//!    coverage. `interp` and `jit` diverge by 4 tests today (D-583).

const std = @import("std");

const zwasm = @import("zwasm");
const cli_run = zwasm.cli.run;

/// Tests in the committed corpus: 46 rust + 14 c + 12 assemblyscript, the
/// `EXPECT` line of `scripts/vendor_wasip1_official.sh`. Held in the binary
/// rather than read from the corpus, so a partial checkout cannot drop the
/// expectation along with the tests it exists to detect. A corpus bump edits
/// both places; missing this one fails loudly at test time.
const vendored_total: u32 = 72;

/// Upstream per-test manifest, flattened. Defaults are upstream's "no
/// manifest" behaviour: no argv beyond argv[0], no env, no preopen, exit 0.
///
/// Every string field BORROWS from `parsed`, so `Expect` owns it: keeping the
/// two in one struct means one `deinit` frees both in the right order and no
/// future edit can outlive the arena by moving one and not the other. The
/// borrow is from the arena, not from the manifest bytes — `Value.jsonParse`
/// hands the scanner `.alloc_always` whatever `ParseOptions.allocate` says, so
/// the bytes can be freed as soon as the parse returns.
const Expect = struct {
    parsed: ?std.json.Parsed(std.json.Value) = null,
    args: std.ArrayList([]const u8) = .empty,
    env_keys: std.ArrayList([]const u8) = .empty,
    env_vals: std.ArrayList([]const u8) = .empty,
    /// Preopen tree name relative to the suite dir (always `fs-tests.dir` at
    /// the pinned commit). Copied per test; never preopened in place.
    root: ?[]const u8 = null,
    stdout: ?[]const u8 = null,
    exit_code: u8 = 0,

    fn deinit(self: *Expect, alloc: std.mem.Allocator) void {
        self.args.deinit(alloc);
        self.env_keys.deinit(alloc);
        self.env_vals.deinit(alloc);
        // Last: the slices above point into this arena.
        if (self.parsed) |*p| p.deinit();
    }
};

const Engine = enum { interp, jit };

const Counts = struct {
    passed: u32 = 0,
    /// The test ran and gave the wrong answer. These are the D-583 items.
    failed: u32 = 0,
    /// The test could not be run at all — unreadable `.wasm`, malformed
    /// manifest, unsupported preopen entry. Counted apart from `failed`
    /// because it means the CORPUS is broken, not the runtime, and reading it
    /// as one of the expected 14 would be exactly wrong. Any of these makes
    /// the run fatal regardless of the pass/fail tally.
    errored: u32 = 0,

    fn ran(self: Counts) u32 {
        return self.passed + self.failed + self.errored;
    }
};

/// Does this error mean "the test gave the wrong answer" (a D-583 item) or
/// "the corpus could not be read" (a vendoring problem)?
fn isTestVerdict(err: anyerror) bool {
    return switch (err) {
        TestError.ExitCodeMismatch, TestError.StdoutMismatch => true,
        else => false,
    };
}

pub fn main(init: std.process.Init) !void {
    zwasm.support.dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const root_arg = arg_it.next() orelse {
        try out.print("usage: official_runner <corpus-root> [interp|jit]\n", .{});
        try out.flush();
        std.process.exit(2);
    };
    const corpus_root = try gpa.dupe(u8, root_arg);
    defer gpa.free(corpus_root);

    const engine: Engine = if (arg_it.next()) |e| blk: {
        if (std.mem.eql(u8, e, "interp")) break :blk .interp;
        if (std.mem.eql(u8, e, "jit")) break :blk .jit;
        try out.print("usage: official_runner <corpus-root> [interp|jit]\n", .{});
        try out.flush();
        std.process.exit(2);
    } else .interp;

    const cwd = std.Io.Dir.cwd();
    var root_dir = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
        // ADR-0174: the corpus is committed. Failing to open it is a real
        // error, and must not be reportable as "0 tests, all green".
        try out.print(
            "FAIL  corpus root '{s}' not openable: {t}\n" ++
                "      the corpus is committed — regen with scripts/vendor_wasip1_official.sh\n",
            .{ corpus_root, err },
        );
        try out.flush();
        std.process.exit(1);
    };
    defer root_dir.close(io);

    // Scratch space for the per-test preopen copies. Keyed by engine so the
    // two lanes can run concurrently without colliding.
    const scratch_root = try std.fmt.allocPrint(gpa, ".zig-cache/wasip1-scratch-{t}", .{engine});
    defer gpa.free(scratch_root);
    discardAbsent(cwd.deleteTree(io, scratch_root));
    try cwd.createDirPath(io, scratch_root);
    // NOTE: no `defer` for the cleanup — this function leaves via
    // `std.process.exit`, which does not run defers. Each `exit` path below
    // therefore deletes the scratch tree explicitly; adding a new one means
    // adding the delete with it. An error returned from `main` skips the
    // cleanup as well, by design: the `deleteTree` above reclaims the whole
    // engine-keyed root before the next run uses it.

    var total: Counts = .{};
    var suites: u32 = 0;

    var root_it = root_dir.iterate();
    while (try root_it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // A suite is a directory carrying upstream's descriptor. Without this
        // any stray directory under the corpus root would be reported as a
        // suite with zero tests, and the diagnostic below would then blame
        // the corpus for being empty rather than naming the real oddity.
        var probe = root_dir.openDir(io, entry.name, .{}) catch |err| {
            try out.print("--- {s}: cannot open ({t}), skipped\n", .{ entry.name, err });
            continue;
        };
        defer probe.close(io);
        probe.access(io, "manifest.json", .{}) catch |err| switch (err) {
            // A directory without the descriptor is genuinely not a suite.
            error.FileNotFound => {
                try out.print("--- {s}: not a suite (no manifest.json), skipped\n", .{entry.name});
                continue;
            },
            // Anything else — a permission error, most likely — is a broken
            // corpus wearing the same costume. Naming it saves the operator
            // from chasing a missing file that is actually there.
            else => {
                try out.print("--- {s}: manifest.json unreadable ({t}), skipped\n", .{ entry.name, err });
                continue;
            },
        };

        const suite = try runSuite(gpa, io, out, corpus_root, entry.name, engine, scratch_root);
        total.passed += suite.passed;
        total.failed += suite.failed;
        total.errored += suite.errored;
        suites += 1;

        // Each vendored suite holds tests. A suite that enumerates to nothing
        // means the corpus did not vendor, and "0 passed, 0 failed" must not
        // read as green — the ADR-0174 failure mode (a leg reporting OK while
        // every category was `pass=0`) one layer up. This catches an EMPTY
        // suite only; a partially-vendored one is caught by the
        // `vendored_total` check after the loop. The per-language counts live
        // in scripts/vendor_wasip1_official.sh and are asserted there.
        if (suite.ran() == 0) {
            try out.print(
                "FAIL  suite '{s}' has a descriptor but no tests — the corpus did\n" ++
                    "      not vendor. Regen with scripts/vendor_wasip1_official.sh.\n",
                .{entry.name},
            );
            try out.flush();
            discardAbsent(cwd.deleteTree(io, scratch_root));
            std.process.exit(1);
        }
    }

    if (suites == 0) {
        try out.print(
            "FAIL  corpus root '{s}' holds no suites — nothing ran, which must\n" ++
                "      not report green. Regen with scripts/vendor_wasip1_official.sh.\n",
            .{corpus_root},
        );
        try out.flush();
        discardAbsent(cwd.deleteTree(io, scratch_root));
        std.process.exit(1);
    }

    // Always print the real numbers. An OK/NG verdict alone is how a broken
    // phase hides behind a green step (ADR-0174 context: a windows leg
    // reported OK while every spec category was pass=0).
    try out.print(
        "\nwasi_p1_official [{t}]: {d} passed, {d} failed, {d} errored, {d} total (over {d} suites)\n",
        .{ engine, total.passed, total.failed, total.errored, total.ran(), suites },
    );
    if (total.errored != 0) {
        try out.print(
            "      {d} test(s) could not be RUN — that is a broken corpus, not a\n" ++
                "      runtime verdict. Regen with scripts/vendor_wasip1_official.sh.\n",
            .{total.errored},
        );
    }
    // A suite that kept some of its tests passes every check above: the
    // per-suite guard only rejects an EMPTY one. Without this the lane reports
    // "all green" over a fraction of the corpus (ADR-0208 D2).
    const partial = total.ran() != vendored_total;
    if (partial) {
        try out.print(
            "      ran {d} of the vendored {d} — the corpus is PARTIAL, so these\n" ++
                "      counts are not a conformance result. Regen with\n" ++
                "      scripts/vendor_wasip1_official.sh.\n",
            .{ total.ran(), vendored_total },
        );
    }
    try out.flush();
    discardAbsent(cwd.deleteTree(io, scratch_root));
    if (total.failed != 0 or total.errored != 0 or partial) std.process.exit(1);
}

/// Swallow a cleanup error on a path that may legitimately not exist.
///
/// This is NOT the forbidden silent-fallback shape: nothing semantic is being
/// demoted to a default. `deleteTree` on scratch space either removes it or
/// tells us it was already gone, and neither outcome changes a test verdict —
/// the scratch tree is rebuilt from the committed corpus on every run. Naming
/// it keeps the intent auditable instead of leaving bare `catch {}` behind.
fn discardAbsent(result: anyerror!void) void {
    result catch {};
}

/// Run one language suite (`<corpus-root>/<name>/`), reporting its own counts.
/// Per-suite reporting mirrors the upstream python runner's granularity.
fn runSuite(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    corpus_root: []const u8,
    suite_name: []const u8,
    engine: Engine,
    scratch_root: []const u8,
) !Counts {
    const suite_path = try std.Io.Dir.path.join(gpa, &.{ corpus_root, suite_name });
    defer gpa.free(suite_path);

    var suite_dir = try std.Io.Dir.cwd().openDir(io, suite_path, .{ .iterate = true });
    defer suite_dir.close(io);

    // Suite descriptor carries upstream's display name; fall back to the
    // directory name so a missing descriptor degrades to a label, not a skip.
    var display = suite_name;
    var display_owned: ?[]u8 = null;
    defer if (display_owned) |d| gpa.free(d);
    if (suite_dir.readFileAlloc(io, "manifest.json", gpa, .limited(4096))) |mb| {
        defer gpa.free(mb);
        if (std.json.parseFromSlice(std.json.Value, gpa, mb, .{})) |parsed| {
            defer parsed.deinit();
            // Parsing succeeding does not make it an object: `[]` and `"x"`
            // are valid JSON, and reading `.object` off either is
            // illegal-union-access — an abort before any suite result is
            // printed. A non-object descriptor takes the same fallback as a
            // malformed one: the label is lost, the suite still runs.
            if (parsed.value == .object) {
                if (parsed.value.object.get("name")) |n| {
                    if (n == .string) {
                        display_owned = try gpa.dupe(u8, n.string);
                        display = display_owned.?;
                    }
                }
            }
        } else |_| {
            // Malformed descriptor: fall back to the directory name. The
            // descriptor only supplies a display label, so a parse failure
            // must not hide the suite's results.
        }
    } else |_| {
        // Absent descriptor: same fallback. Only the label is lost, and the
        // suite's tests are enumerated from the directory either way.
    }

    try out.print("--- {s}\n", .{display});

    var counts: Counts = .{};
    var it = suite_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;

        const stem = entry.name[0 .. entry.name.len - ".wasm".len];
        if (runOne(gpa, io, out, &suite_dir, suite_path, stem, entry.name, engine, scratch_root)) {
            counts.passed += 1;
        } else |err| if (isTestVerdict(err)) {
            try out.print("FAIL   {s}: {t}\n", .{ stem, err });
            counts.failed += 1;
        } else {
            try out.print("ERROR  {s}: {t} (could not run — corpus problem)\n", .{ stem, err });
            counts.errored += 1;
        }
    }
    try out.print("    {d} passed, {d} failed, {d} errored\n", .{ counts.passed, counts.failed, counts.errored });
    return counts;
}

const TestError = error{
    ExitCodeMismatch,
    StdoutMismatch,
    UnknownManifestKey,
    ManifestShape,
    ManifestUnreadable,
};

fn runOne(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    suite_dir: *std.Io.Dir,
    suite_path: []const u8,
    stem: []const u8,
    wasm_name: []const u8,
    engine: Engine,
    scratch_root: []const u8,
) !void {
    const wasm_bytes = try suite_dir.readFileAlloc(io, wasm_name, gpa, .limited(64 << 20));
    defer gpa.free(wasm_bytes);

    const manifest_name = try std.fmt.allocPrint(gpa, "{s}.json", .{stem});
    defer gpa.free(manifest_name);

    var expect: Expect = .{};
    defer expect.deinit(gpa);

    if (suite_dir.readFileAlloc(io, manifest_name, gpa, .limited(1 << 20))) |mb| {
        defer gpa.free(mb);
        expect.parsed = try std.json.parseFromSlice(std.json.Value, gpa, mb, .{});
        try parseManifest(gpa, out, stem, &expect.parsed.?.value, &expect);
    } else |err| switch (err) {
        // Absent manifest is upstream's documented default, not an error.
        error.FileNotFound => {},
        // Anything else means the expectations are there and unreadable.
        // Running the test regardless would drop its checks silently — a
        // stdout-only manifest would leave `cap` null, skip the comparison,
        // and report a PASS on no evidence. This is the one place in the file
        // that used to degrade quietly; it is loud now, like the rest.
        else => {
            try out.print("      cannot read {s}: {t}\n", .{ manifest_name, err });
            return TestError.ManifestUnreadable;
        },
    }

    // A fresh copy of the preopen tree per test — see the header note on
    // `dangling_symlink`. The copy is recursive: the C suite ships
    // `fopendir.dir/` and `writeable/`, and a flat copy silently breaks
    // fdopendir-with-access and the pwrite-* tests.
    const cwd = std.Io.Dir.cwd();
    const scratch_path = try std.Io.Dir.path.join(gpa, &.{ scratch_root, stem });
    defer gpa.free(scratch_path);
    var preopens: []const cli_run.PreopenDir = &.{};
    var preopen_storage: [1]cli_run.PreopenDir = undefined;
    if (expect.root) |root_name| {
        discardAbsent(cwd.deleteTree(io, scratch_path));
        try cwd.createDirPath(io, scratch_path);
        const src_path = try std.Io.Dir.path.join(gpa, &.{ suite_path, root_name });
        defer gpa.free(src_path);
        try copyTree(gpa, io, src_path, scratch_path);
        preopen_storage[0] = .{ .host_path = scratch_path, .guest_path = "/" };
        preopens = preopen_storage[0..1];
    }
    defer if (expect.root != null) discardAbsent(cwd.deleteTree(io, scratch_path));

    // argv[0] is the path to the module, which is what the upstream python
    // runner hands its runtime (`argv += [test_path]`). Nothing in the
    // vendored corpus reads argv[0] — passing the basename instead changes no
    // verdict, measured both ways — so this is fidelity to the reference
    // harness rather than a behavioural requirement.
    const wasm_path = try std.Io.Dir.path.join(gpa, &.{ suite_path, wasm_name });
    defer gpa.free(wasm_path);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, wasm_path);
    try argv.appendSlice(gpa, expect.args.items);

    var stdout_cap: std.ArrayList(u8) = .empty;
    defer stdout_cap.deinit(gpa);
    const cap: ?*std.ArrayList(u8) = if (expect.stdout != null) &stdout_cap else null;

    const actual = switch (engine) {
        // `.auto` prefers the JIT, so the interp lane must say so explicitly.
        .interp => try cli_run.runWasmCapturedOpts(
            gpa,
            io,
            wasm_bytes,
            argv.items,
            cap,
            null,
            preopens,
            expect.env_keys.items,
            expect.env_vals.items,
            null,
            .{ .engine = .interp },
        ),
        // `--engine jit` is a dedicated path, not a `Limits.engine` value.
        .jit => try cli_run.runWasmJitCaptured(
            gpa,
            io,
            wasm_bytes,
            null,
            argv.items,
            preopens,
            expect.env_keys.items,
            expect.env_vals.items,
            .{},
            cap,
            null,
            null,
        ),
    };

    if (actual != expect.exit_code) {
        try out.print("      exit: expected {d}, got {d}\n", .{ expect.exit_code, actual });
        return TestError.ExitCodeMismatch;
    }
    if (expect.stdout) |want| {
        if (!std.mem.eql(u8, want, stdout_cap.items)) {
            try out.print(
                "      stdout: expected ({d}B) '{s}', got ({d}B) '{s}'\n",
                .{ want.len, want, stdout_cap.items.len, stdout_cap.items },
            );
            return TestError.StdoutMismatch;
        }
    }
}

/// Flatten one upstream manifest. Unknown keys are an error rather than a
/// silent drop: upstream extending the schema must surface, not be ignored.
fn parseManifest(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    stem: []const u8,
    value: *const std.json.Value,
    expect: *Expect,
) !void {
    if (value.* != .object) return;
    var it = value.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const v = kv.value_ptr.*;
        if (std.mem.eql(u8, key, "args")) {
            if (v != .array) return shapeError(out, stem, key, "array", v);
            for (v.array.items) |a| {
                if (a != .string) return shapeError(out, stem, key, "array of string", a);
                try expect.args.append(gpa, a.string);
            }
        } else if (std.mem.eql(u8, key, "env")) {
            if (v != .object) return shapeError(out, stem, key, "object", v);
            var eit = v.object.iterator();
            while (eit.next()) |ekv| {
                const ev = ekv.value_ptr.*;
                if (ev != .string) return shapeError(out, stem, key, "object of string", ev);
                try expect.env_keys.append(gpa, ekv.key_ptr.*);
                try expect.env_vals.append(gpa, ev.string);
            }
        } else if (std.mem.eql(u8, key, "root")) {
            if (v != .string) return shapeError(out, stem, key, "string", v);
            expect.root = v.string;
        } else if (std.mem.eql(u8, key, "stdout")) {
            if (v != .string) return shapeError(out, stem, key, "string", v);
            expect.stdout = v.string;
        } else if (std.mem.eql(u8, key, "exit_code")) {
            if (v != .integer) return shapeError(out, stem, key, "integer", v);
            // `@intCast` panics out of range, and the value is upstream's.
            if (v.integer < 0 or v.integer > 255) {
                try out.print(
                    "      manifest key 'exit_code' in {s}.json is {d}, outside 0..255\n",
                    .{ stem, v.integer },
                );
                return TestError.ManifestShape;
            }
            expect.exit_code = @intCast(v.integer);
        } else {
            try out.print("      unknown manifest key '{s}' in {s}.json\n", .{ key, stem });
            return TestError.UnknownManifestKey;
        }
    }
}

/// Report a manifest field whose JSON type is not the one the schema uses.
///
/// Returned rather than left to panic: reading `v.string` off a non-string
/// `std.json.Value` is illegal-union-access, which aborts the process — no
/// per-test `errored`, no report, no scratch cleanup. Upstream growing the
/// schema must surface the same way an unknown KEY does, as one loud test.
fn shapeError(
    out: *std.Io.Writer,
    stem: []const u8,
    key: []const u8,
    want: []const u8,
    got: std.json.Value,
) anyerror!void {
    try out.print(
        "      manifest key '{s}' in {s}.json is {s}, expected {s}\n",
        .{ key, stem, @tagName(got), want },
    );
    return TestError.ManifestShape;
}

/// Recursively copy `src` into the already-created `dest`.
///
/// Two passes, directories first. `std.Io.Dir.walk` documents its order as
/// *undefined*, so a single pass that creates each directory as it meets it
/// only works while the walk happens to yield parents before children —
/// `fopendir.dir/file-0` would fail to write if its parent had not come up
/// yet. Creating every directory before writing any file removes the
/// dependency on an order the stdlib does not promise.
fn copyTree(gpa: std.mem.Allocator, io: std.Io, src: []const u8, dest: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var src_dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);
    var dest_dir = try cwd.openDir(io, dest, .{});
    defer dest_dir.close(io);

    inline for (.{ true, false }) |dirs_pass| {
        var walker = try src_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            try copyEntry(gpa, io, &dest_dir, entry, dirs_pass);
        }
    }
}

/// One `copyTree` entry. `dirs_pass` selects which half of the two-pass walk
/// this call belongs to: directories on the first, regular files on the second.
fn copyEntry(
    gpa: std.mem.Allocator,
    io: std.Io,
    dest_dir: *std.Io.Dir,
    entry: std.Io.Dir.Walker.Entry,
    dirs_pass: bool,
) !void {
    switch (entry.kind) {
        .directory => if (dirs_pass) try dest_dir.createDirPath(io, entry.path),
        .file => if (!dirs_pass) {
            const data = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(8 << 20));
            defer gpa.free(data);
            try dest_dir.writeFile(io, .{ .sub_path = entry.path, .data = data });
        },
        // The preopen trees hold only regular files and directories at the
        // pinned commit — the tests create their own symlinks, device nodes
        // are not part of a conformance fixture, and vendoring is what would
        // have to introduce any of the rest. Enumerated rather than `else`-ed
        // so a future corpus bump that adds one of these surfaces here
        // instead of being copied as nothing.
        .sym_link,
        .block_device,
        .character_device,
        .named_pipe,
        .unix_domain_socket,
        .whiteout,
        .door,
        .event_port,
        .unknown,
        => return error.UnsupportedPreopenEntryKind,
    }
}
