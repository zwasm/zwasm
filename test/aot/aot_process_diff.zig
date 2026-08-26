//! CROSS-PROCESS `.wasm`-vs-`.cwasm` differential (AOT-full-fidelity
//! campaign Phase II; see
//! `.dev/meta_audits/2026-07-09-aot-full-fidelity-investigation.md`).
//!
//! For every `.wasm` fixture in the given corpora, spawns the REAL zwasm CLI
//! three times:
//!   lane A: `zwasm run <fixture>`            (fresh JIT compile + run)
//!   compile: `zwasm compile <fixture> -o t`  (produce the `.cwasm`)
//!   lane B: `zwasm run <t>`                  (load the artifact, run)
//! and byte-compares stdout + exit code across the lanes.
//!
//! WHY subprocesses (not the in-process fuzz-diff lane): the D-516 bug class
//! — Zig-helper ABSOLUTE ADDRESSES baked into emitted code — is invisible
//! in-process (same address space ⇒ the stale addresses still work). Only a
//! fresh process (new PIE/ASLR slide) exposes it. Lane B always runs in its
//! own process, so this harness sees exactly what a real
//! compile-on-one-day / run-on-another deployment sees.
//!
//! argv[0] parity: guests like `c_hello_wasi` echo argv[0], and the CLI
//! passes the module path through as guest argv[0]. Both lanes therefore run
//! with cwd = the file's directory and a bare-basename argv — and lane B's
//! artifact is written under the SAME basename as the `.wasm` (the CLI
//! detects `.cwasm` by CWAS magic, not extension), so the guest-visible
//! argv[0] bytes are identical.
//!
//! Expectations table: fixtures with a KNOWN divergence carry a `D-NNN`
//! reason and one of two classes:
//!   - `.wrong_result` — deterministic divergence (mini-runtime logic gap:
//!     D-517 memory.grow unsupported, D-518 start-function skipped). A lane
//!     match here is a RATCHET FLIP: the gap was fixed, the table entry must
//!     be removed in the same PR (the gate trips to force it).
//!   - `.unsound` — ASLR-dependent outcome (D-516 baked helper addresses):
//!     crash on most runs, may accidentally "work" under a lucky/absent
//!     slide. Reported, never gated, until the de-baking stage flips it to
//!     an implicit `.match`.
//! Everything else defaults to `.match` — any divergence is a finding and
//! the gate exits non-zero.
//!
//! Usage: `zig build test-aot-diff` /
//!        `zwasm-aot-process-diff <zwasm-cli> <corpus-dir> [corpus-dir...]`

const std = @import("std");

const Expectation = union(enum) {
    match,
    wrong_result: []const u8, // deterministic known divergence (D-NNN reason)
    unsound: []const u8, // ASLR-dependent (D-516 class) — report only
};

const KnownEntry = struct { name: []const u8, exp: Expectation };

// Keys are fixture basenames (unique across all driven corpora).
//
// EMPTY since ADR-0203 stage 3: the full-fidelity load path (deserialize →
// the normal setup) discharged every pinned divergence — D-517 (memory.grow /
// GC arena / EH tables: all 8 Go fixtures, rust/cpp/c alloc paths, the
// crafted gc_struct/eh_throw/mem_grow shapes) and D-518 (start function).
// Every fixture the producer accepts now MATCHES its source `.wasm`. A
// future finding gets a new row citing a fresh D-NNN; fixing it trips
// RATCHET-FLIP to force the row's removal in the same PR.
const known_table = [_]KnownEntry{};

fn expectationFor(name: []const u8) Expectation {
    for (known_table) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.exp;
    }
    return .match;
}

/// Guests needing a preopened dir (mirrors diff_runner.zig) — both lanes get
/// the same fresh scratch preopen so behaviour stays comparable.
fn fixtureNeedsPreopen(name: []const u8) bool {
    return std.mem.eql(u8, name, "rust_file_io.wasm");
}

const LaneResult = struct {
    stdout: []u8,
    exit: u8,
    crashed: bool, // term was not a clean .exited

    fn deinit(self: *LaneResult, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
    }
};

fn runLane(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd_path: ?[]const u8,
) !LaneResult {
    const cwd_opt: std.process.Child.Cwd = if (cwd_path) |p| .{ .path = p } else .inherit;
    const result = try std.process.run(gpa, io, .{ .argv = argv, .cwd = cwd_opt });
    defer gpa.free(result.stderr);
    return .{
        .stdout = result.stdout,
        .exit = switch (result.term) {
            .exited => |c| c,
            else => 255,
        },
        .crashed = result.term != .exited,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const cli_arg = arg_it.next() orelse {
        try stdout.print("usage: zwasm-aot-process-diff <zwasm-cli> <corpus-dir> [corpus-dir...]\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const cwd = std.Io.Dir.cwd();
    // Lanes run with per-fixture cwds — the CLI path must survive them.
    const cli = try cwd.realPathFileAlloc(io, cli_arg, gpa);
    defer gpa.free(cli);
    // Scratch under .zig-cache (gitignored); artifact written per fixture
    // under the SAME basename as the source (argv[0] parity, magic-detected).
    //
    // Every scratch root carries a per-RUN random tag. Fixed names let a
    // second concurrent run of this harness delete the tree the first one is
    // mid-way through: the loser either dies on the open (FileNotFound) or —
    // worse — survives with `zwasm compile` failing WriteOutputFailed into
    // the deleted dir, which lands in `skipped_refused` and still exits 0.
    // Same generator as the cache writer's temp names (src/cli/cache.zig).
    var tag_bytes: [8]u8 = undefined;
    io.random(&tag_bytes);
    var tag_buf: [16]u8 = undefined;
    const tag = try std.fmt.bufPrint(&tag_buf, "{x:0>16}", .{std.mem.readInt(u64, &tag_bytes, .little)});

    const tmp_dir = try std.fmt.allocPrint(gpa, ".zig-cache/aot-diff-tmp-{s}", .{tag});
    defer gpa.free(tmp_dir);
    try cwd.createDirPath(io, tmp_dir);
    defer cwd.deleteTree(io, tmp_dir) catch {};
    const preopen_scratch = try std.fmt.allocPrint(gpa, ".zig-cache/aot-diff-preopen-{s}", .{tag});
    defer gpa.free(preopen_scratch);
    // Cache-lane scratch (ADR-0203 D6 stage-5 ratchet): one root shared
    // across fixtures so hits exercise a real multi-entry directory;
    // absolutized because the lanes run with per-fixture cwds.
    const cache_root_rel = try std.fmt.allocPrint(gpa, ".zig-cache/aot-diff-cache-{s}", .{tag});
    defer gpa.free(cache_root_rel);
    try cwd.createDirPath(io, cache_root_rel);
    defer cwd.deleteTree(io, cache_root_rel) catch {};
    const cache_root = try cwd.realPathFileAlloc(io, cache_root_rel, gpa);
    defer gpa.free(cache_root);
    const cache_flag = try std.fmt.allocPrint(gpa, "--cache={s}", .{cache_root});
    defer gpa.free(cache_flag);

    var total: u32 = 0;
    var matched: u32 = 0;
    var skipped_refused: u32 = 0;
    var expected_diverged: u32 = 0;
    var unsound_reported: u32 = 0;
    var unexpected: u32 = 0; // gate
    var ratchet_flips: u32 = 0; // gate (a known_table entry now matches)

    var n_dirs: u32 = 0;
    while (arg_it.next()) |corpus_dir_arg| {
        n_dirs += 1;
        const corpus_dir = try gpa.dupe(u8, corpus_dir_arg);
        defer gpa.free(corpus_dir);

        var dir = cwd.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
            try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_dir, @errorName(err) });
            try stdout.flush();
            std.process.exit(1);
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;
            total += 1;

            const fixture_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ corpus_dir, entry.name });
            defer gpa.free(fixture_path);
            const artifact_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ tmp_dir, entry.name });
            defer gpa.free(artifact_path);

            const needs_preopen = fixtureNeedsPreopen(entry.name);
            if (needs_preopen) {
                cwd.deleteTree(io, preopen_scratch) catch {};
                try cwd.createDirPath(io, preopen_scratch);
            }
            defer if (needs_preopen) cwd.deleteTree(io, preopen_scratch) catch {};
            // Preopen paths must resolve from BOTH lane cwds — absolutize.
            // Keep the sentinel type: realPathFileAlloc dupeZ's (len+1
            // allocation) and a plain-[]u8 coercion makes gpa.free
            // under-free by one (DebugAllocator size mismatch).
            const preopen_abs: ?[:0]u8 = if (needs_preopen)
                try cwd.realPathFileAlloc(io, preopen_scratch, gpa)
            else
                null;
            defer if (preopen_abs) |p| gpa.free(p);

            // Lane A — fresh JIT run of the source module (cwd = corpus dir,
            // bare-basename argv for argv[0] parity with lane B).
            const lane_a_argv: []const []const u8 = if (preopen_abs) |p|
                &.{ cli, "run", "--dir", p, entry.name }
            else
                &.{ cli, "run", entry.name };
            var lane_a = runLane(gpa, io, lane_a_argv, corpus_dir) catch |err| {
                try stdout.print("SKIP-SPAWN  {s}: lane A: {s}\n", .{ entry.name, @errorName(err) });
                skipped_refused += 1;
                continue;
            };
            defer lane_a.deinit(gpa);

            // Compile — a refusal is a RECORDED skip (the produce envelope is
            // its own characterization; the campaign widens it stage by stage).
            const compile_result = std.process.run(gpa, io, .{
                .argv = &.{ cli, "compile", fixture_path, "-o", artifact_path },
            }) catch |err| {
                try stdout.print("SKIP-SPAWN  {s}: compile: {s}\n", .{ entry.name, @errorName(err) });
                skipped_refused += 1;
                continue;
            };
            defer gpa.free(compile_result.stdout);
            defer gpa.free(compile_result.stderr);
            const compile_ok = compile_result.term == .exited and compile_result.term.exited == 0;
            if (!compile_ok) {
                const first_line = std.mem.sliceTo(compile_result.stderr, '\n');
                try stdout.print("SKIP-REFUSED  {s}: {s}\n", .{ entry.name, first_line });
                skipped_refused += 1;
                continue;
            }

            // Lane B — run the artifact in a FRESH process (cwd = tmp dir).
            const lane_b_argv: []const []const u8 = if (preopen_abs) |p|
                &.{ cli, "run", "--dir", p, entry.name }
            else
                &.{ cli, "run", entry.name };
            var lane_b = runLane(gpa, io, lane_b_argv, tmp_dir) catch |err| {
                try stdout.print("SKIP-SPAWN  {s}: lane B: {s}\n", .{ entry.name, @errorName(err) });
                skipped_refused += 1;
                continue;
            };
            defer lane_b.deinit(gpa);

            // Lane C — transparent cache (ADR-0203 D5/D6): the first
            // `--cache` run is a MISS (compile + store), the second a HIT
            // (loads the stored artifact); both must byte-match lane A.
            const lane_c_argv: []const []const u8 = if (preopen_abs) |p|
                &.{ cli, "run", cache_flag, "--dir", p, entry.name }
            else
                &.{ cli, "run", cache_flag, entry.name };
            var lane_miss = runLane(gpa, io, lane_c_argv, corpus_dir) catch |err| {
                try stdout.print("SKIP-SPAWN  {s}: lane C miss: {s}\n", .{ entry.name, @errorName(err) });
                skipped_refused += 1;
                continue;
            };
            defer lane_miss.deinit(gpa);
            var lane_hit = runLane(gpa, io, lane_c_argv, corpus_dir) catch |err| {
                try stdout.print("SKIP-SPAWN  {s}: lane C hit: {s}\n", .{ entry.name, @errorName(err) });
                skipped_refused += 1;
                continue;
            };
            defer lane_hit.deinit(gpa);

            const equal = lane_a.exit == lane_b.exit and std.mem.eql(u8, lane_a.stdout, lane_b.stdout);
            const cache_equal = lane_a.exit == lane_miss.exit and
                std.mem.eql(u8, lane_a.stdout, lane_miss.stdout) and
                lane_a.exit == lane_hit.exit and
                std.mem.eql(u8, lane_a.stdout, lane_hit.stdout);

            // `--engine interp --cache` must BYPASS the cache (D-496: the
            // explicit interp choice wins; the artifact is JIT code). Probe
            // once: interp+cache == plain interp, and NOTHING is stored.
            if (std.mem.eql(u8, entry.name, "compute_add.wasm")) {
                const iroot_rel = try std.fmt.allocPrint(gpa, ".zig-cache/aot-diff-cache-interp-{s}", .{tag});
                defer gpa.free(iroot_rel);
                try cwd.createDirPath(io, iroot_rel);
                defer cwd.deleteTree(io, iroot_rel) catch {};
                const iroot_abs = try cwd.realPathFileAlloc(io, iroot_rel, gpa);
                defer gpa.free(iroot_abs);
                const iflag = try std.fmt.allocPrint(gpa, "--cache={s}", .{iroot_abs});
                defer gpa.free(iflag);
                var interp_ref = try runLane(gpa, io, &.{ cli, "run", "--engine", "interp", entry.name }, corpus_dir);
                defer interp_ref.deinit(gpa);
                var interp_cached = try runLane(gpa, io, &.{ cli, "run", "--engine", "interp", iflag, entry.name }, corpus_dir);
                defer interp_cached.deinit(gpa);
                var stored: u32 = 0;
                var idir = try cwd.openDir(io, iroot_rel, .{ .iterate = true });
                defer idir.close(io);
                var idir_it = idir.iterate();
                while (try idir_it.next(io)) |_| stored += 1;
                if (interp_ref.exit != interp_cached.exit or
                    !std.mem.eql(u8, interp_ref.stdout, interp_cached.stdout) or stored != 0)
                {
                    unexpected += 1;
                    try stdout.print(
                        "INTERP-CACHE-BYPASS-FAIL  {s}: interp exit={d} vs interp+cache exit={d}, stored-entries={d} (want 0)\n",
                        .{ entry.name, interp_ref.exit, interp_cached.exit, stored },
                    );
                }
                // Explicit `.cwasm` + `--engine interp` is a contradictory
                // request (the artifact IS JIT code) — loud refusal, exit 2.
                var interp_cwasm = try runLane(gpa, io, &.{ cli, "run", "--engine", "interp", entry.name }, tmp_dir);
                defer interp_cwasm.deinit(gpa);
                if (interp_cwasm.exit != 2) {
                    unexpected += 1;
                    try stdout.print(
                        "INTERP-CWASM-REFUSAL-FAIL  {s}: exit={d} (want 2)\n",
                        .{ entry.name, interp_cwasm.exit },
                    );
                }
            }

            switch (expectationFor(entry.name)) {
                .match => {
                    if (equal and cache_equal) {
                        matched += 1;
                    } else {
                        unexpected += 1;
                        if (!equal) try stdout.print(
                            "AOT-DIVERGE  {s}: wasm(exit={d}, {d}B stdout) vs cwasm(exit={d}, {d}B stdout{s})\n",
                            .{
                                entry.name,  lane_a.exit,       lane_a.stdout.len,
                                lane_b.exit, lane_b.stdout.len, if (lane_b.crashed) ", CRASHED" else "",
                            },
                        );
                        if (!cache_equal) try stdout.print(
                            "CACHE-DIVERGE  {s}: wasm(exit={d}, {d}B) vs cache-miss(exit={d}, {d}B) / cache-hit(exit={d}, {d}B)\n",
                            .{
                                entry.name,          lane_a.exit,          lane_a.stdout.len,
                                lane_miss.exit,      lane_miss.stdout.len, lane_hit.exit,
                                lane_hit.stdout.len,
                            },
                        );
                    }
                },
                .wrong_result => |reason| {
                    if (equal) {
                        ratchet_flips += 1;
                        try stdout.print(
                            "RATCHET-FLIP  {s}: known divergence ({s}) now MATCHES — remove its known_table entry in this PR\n",
                            .{ entry.name, reason },
                        );
                    } else {
                        expected_diverged += 1;
                        try stdout.print("EXPECTED-DIVERGE  {s}: {s} (wasm exit={d} / cwasm exit={d})\n", .{
                            entry.name, reason, lane_a.exit, lane_b.exit,
                        });
                    }
                },
                .unsound => |reason| {
                    unsound_reported += 1;
                    try stdout.print("UNSOUND-{s}  {s}: {s}\n", .{
                        if (equal) "MATCH" else "DIVERGE", entry.name, reason,
                    });
                },
            }
            try stdout.flush();
        }
    }

    if (n_dirs == 0) {
        try stdout.print("usage: zwasm-aot-process-diff <zwasm-cli> <corpus-dir> [corpus-dir...]\n", .{});
        try stdout.flush();
        std.process.exit(2);
    }

    // The cache lanes must have actually STORED entries — a silently-broken
    // store would still "match" above by recompiling on every run.
    var stored_artifacts: u32 = 0;
    {
        var root_dir = try cwd.openDir(io, cache_root_rel, .{ .iterate = true });
        defer root_dir.close(io);
        var root_it = root_dir.iterate();
        while (try root_it.next(io)) |sub| {
            if (sub.kind != .directory) continue;
            var sub_dir = try root_dir.openDir(io, sub.name, .{ .iterate = true });
            defer sub_dir.close(io);
            var sub_it = sub_dir.iterate();
            while (try sub_it.next(io)) |e| {
                if (std.mem.endsWith(u8, e.name, ".cwasm")) stored_artifacts += 1;
            }
        }
    }
    if (matched > 0 and stored_artifacts == 0) {
        unexpected += 1;
        try stdout.print("CACHE-STORE-FAIL: cache lanes matched but zero .cwasm entries were stored\n", .{});
    }

    try stdout.print(
        "\naot_process_diff: {d} fixtures — {d} matched, {d} refused(skip), {d} expected-diverge, {d} unsound-reported, {d} UNEXPECTED, {d} ratchet-flips — GATING\n",
        .{ total, matched, skipped_refused, expected_diverged, unsound_reported, unexpected, ratchet_flips },
    );
    try stdout.flush();

    if (total == 0) {
        try stdout.print("error: empty corpus\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }
    // Gate: an unexpected divergence is a fidelity regression (or a new
    // finding to triage into the table with a D-NNN); a ratchet flip means a
    // known gap was fixed and the table must be updated in the same PR.
    if (unexpected != 0 or ratchet_flips != 0) std.process.exit(1);
}
