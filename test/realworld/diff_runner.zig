//! Realworld stdout differential runner (§9.6 / 6.F).
//!
//! For each `.wasm` fixture in the corpus, runs `wasmtime run`
//! to capture a reference stdout, then drives the same fixture
//! through `cli/run.zig:runWasmCaptured` and byte-compares the
//! two outputs. The §9.6 / 6.F exit criterion is: 30+ samples
//! match `wasmtime run` byte-for-byte (the ADR-0006 target,
//! retargeted from §9.4 / 4.10).
//!
//! Outcome categories:
//!
//!   MATCH       — both runtimes produced identical stdout AND
//!                 the v2 run completed (any u8 exit). Counted
//!                 toward the 30+ gate.
//!   MISMATCH    — both runtimes produced stdout but bytes
//!                 differ. Surfaces a real semantic gap; a
//!                 single MISMATCH fails the gate.
//!   SKIP-EMPTY  — both runtimes produced empty stdout (silent
//!                 guests; trivially "matching" but uninformative,
//!                 so excluded from the 30+ count).
//!   SKIP-WASMTIME-FAIL — wasmtime exited non-zero / errored;
//!                 nothing to diff against.
//!   SKIP-V2-*   — v2 surfaced an error class run_runner already
//!                 categorises (WASI host gap / validator gap /
//!                 no entry); orthogonal to differential coverage.
//!   SKIP-WASMTIME-MISSING — wasmtime not on PATH; runner exits
//!                 0 with a "no diffs run on this host" notice.
//!                 Hosts with wasmtime installed see the real gate.
//!
//! The `--jit` lane (D-283) re-runs the same corpus through the
//! WASI-aware `--engine jit` path and byte-diffs against the same
//! wasmtime reference — the realworld JIT-correctness net. It is
//! a lane `test-all` runs, and it gates on every way the JIT can
//! fail to answer for a fixture the oracle ran: MISMATCH-JIT,
//! SKIP-JIT-*, and — as a structural guard — a fixture that never
//! reached the lane (see the gate at the bottom of `main`).
//! Counting only mismatches would let a lane that verified nothing
//! report success.
//!
//! The `--interp` lane (issue #215) is the same differential with the
//! engine PINNED to the interpreter (`Limits{ .engine = .interp }`, the
//! D-496 selection surface). It exists because both default-`Limits`
//! realworld runners resolve `.auto`, which prefers the JIT — so without
//! it no lane in `test-all` executes the realworld corpus on the interp
//! and checks the result. It gates like the JIT lane (mismatch, skip,
//! and shortfall all fatal; identity printed and checked), with one more
//! bucket: fixtures whose forced-interp wall-clock dominates the corpus
//! are enumerated out as SKIP-INTERP-SLOW — printed and counted, never
//! silent (ADR-0210) — and stay covered by the manual `--interp-all`
//! variant.
//!
//! Usage:
//!   zig build test-realworld-diff         # shared (.auto) lane only
//!   zig build test-realworld-diff-jit     # + the gating JIT + forced-interp lanes (test-all)
//!   zig build test-realworld-diff-interp  # forced-interp over the FULL corpus (manual)
//!   diff_runner_exe <corpus-dir> [--jit|--aot|--wasmer|--interp|--interp-all]

const std = @import("std");

const zwasm = @import("zwasm");
const cli_run = zwasm.cli.run;

/// Fixtures that need a writable WASI preopen to run to completion (they
/// `path_open` a file relative to a preopen dir). The diff runner hands
/// BOTH wasmtime and v2 the same scratch dir mapped at guest "." so their
/// stdout matches byte-for-byte (D-243). Self-cleaning fixtures (create →
/// write → read → unlink) can share one scratch dir across the two runs.
fn fixtureNeedsPreopen(name: []const u8) bool {
    return std.mem.eql(u8, name, "rust_file_io.wasm");
}

/// cwd-relative scratch dir handed to needs-preopen fixtures as guest ".".
/// The wasmtime subprocess inherits the runner's cwd, so both runtimes
/// resolve the same host path. Recreated empty per run.
const preopen_scratch = "zig-out/diff-preopen-scratch";

/// Recreate the preopen scratch dir empty. Called before EVERY engine's run,
/// not once per fixture. The lanes execute in sequence against the same host
/// directory, so anything one leaves behind is visible to the next and the
/// order they run in becomes load-bearing — which it should not be, and which
/// changed when the AOT and JIT lanes moved above the shared run. Resetting per
/// run gives every engine the same initial state, so a lane's bytes cannot
/// depend on which lanes preceded it. (The one needs-preopen fixture,
/// `rust_file_io`, is self-cleaning today — measured 0 residue on both engines
/// — so this is hardening against a future fixture, or a run that dies between
/// create and unlink.)
fn resetPreopenScratch(io: std.Io, cwd: std.Io.Dir) !void {
    // EXEMPT-FALLBACK (no_workaround.md): an absent dir is exactly the desired
    // post-state of deleteTree; createDirPath is the call whose failure matters.
    cwd.deleteTree(io, preopen_scratch) catch {};
    try cwd.createDirPath(io, preopen_scratch);
}

/// AOT lane fixture-size cap (bytes). The opt-in `--aot` lane JIT-compiles
/// each fixture in-process; libc/Go/Rust guests above this size take minutes
/// to compile and trap under `--engine jit` anyway, so they are SKIP-AOT-LARGE
/// — the small compute/WASI fixtures under the cap are the achievable AOT
/// differential. Tune up once a subprocess-based (timeout-able) lane lands.
const aot_size_cap: usize = 64 * 1024;

/// Fixtures enumerated OUT of the gating `--interp` lane. Cutline: forced-
/// interp wall-clock >= 10s (x86_64-linux Debug, main @ 053f0c942,
/// 2026-08-21) — together 81.7s of the corpus's 116.0s total, versus +34s
/// for the 52 fixtures the gating lane keeps (the cost class the JIT lane's
/// +29s established for `test-all`). Each is printed as SKIP-INTERP-SLOW and
/// counted in the lane's identity (ADR-0210: an exclusion is enumerated and
/// accounted, never silent); `--interp-all` (the manual
/// `test-realworld-diff-interp` step) runs them too, so full-corpus interp
/// coverage stays one command away. A row whose fixture vanishes from the
/// corpus fails the lane (stale-entry check in the gate) rather than rotting.
const InterpSlowSkip = struct { name: []const u8, measured: []const u8 };
const interp_slow_skips = [_]InterpSlowSkip{
    .{ .name = "c_large_memory.wasm", .measured = "35.7s" },
    .{ .name = "rust_fib_compute.wasm", .measured = "21.0s" },
    .{ .name = "go_json_marshal.wasm", .measured = "13.3s" },
    .{ .name = "go_sort_benchmark.wasm", .measured = "11.7s" },
};

/// Per-fixture deadline for the gating `--interp` lane, via the cooperative
/// interrupt the interp dispatch loop polls (ADR-0179 #3a-4) — the interp
/// runs in-process, so like the JIT lane a hang would otherwise wedge
/// `test-all` to CI's cap instead of failing loudly. Slowest gated fixture
/// measured 9.5s (`emcc_fannkuch`, x86_64-linux Debug, 2026-08-21); 120s is
/// ~12x headroom, sized to the JIT lane's precedent (60s ≈ 18x its 3.4s
/// slowest) rather than to the one host measured — the deadline costs
/// nothing on the green path, and what it must not do is turn a slow CI
/// leg into a fatal SKIP-INTERP-TRAP that reads as an interp bug. A real
/// hang still fails loudly, 120s per hung fixture. `--interp-all` uses
/// 480s (~13x): the enumerated fixtures it re-admits measure up to 35.7s.
const interp_deadline_ms: u64 = 120_000;
const interp_all_deadline_ms: u64 = 480_000;

pub fn main(init: std.process.Init) !void {
    zwasm.support.dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const corpus_dir_arg = arg_it.next() orelse {
        try stdout.print("usage: diff_runner <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_dir = try gpa.dupe(u8, corpus_dir_arg);
    defer gpa.free(corpus_dir);

    // Extra lanes, parsed from any remaining args in any order (all OFF by
    // default; `--jit` is the one `test-all` turns on):
    //   --aot     in-process AOT-WASI vs wasmtime (D-283 widen / D-251 validate).
    //             REPORT-ONLY diagnostic target.
    //   --wasmer  wasmer as a 2nd reference oracle vs wasmtime (§9.6 A3). The
    //             value: a wasmtime/wasmer disagreement is the divergence a
    //             single-reference gate can't see. REPORT-ONLY.
    //   --jit     run via the WASI-aware `--engine jit` path (`runWasmJitCaptured`)
    //             + byte-diff vs wasmtime (D-283). The realworld JIT-correctness
    //             net: GATING, wired into `test-all`, and the realworld gate
    //             whose oracle is an independent runtime rather than a
    //             checked-in expectation or zwasm itself.
    //   --interp  run via the captured path with the engine pinned to the
    //             interpreter (`Limits{ .engine = .interp }`) + byte-diff vs
    //             wasmtime (issue #215). GATING, wired into `test-all`
    //             alongside `--jit`; the `interp_slow_skips` fixtures are
    //             enumerated skips. `--interp-all` is the same lane with the
    //             skip table ignored and a larger deadline (manual step).
    var aot_lane = false;
    var wasmer_lane = false;
    var jit_lane = false;
    var interp_lane = false;
    var interp_all = false;
    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "--aot")) {
            aot_lane = true;
        } else if (std.mem.eql(u8, a, "--wasmer")) {
            wasmer_lane = true;
        } else if (std.mem.eql(u8, a, "--jit")) {
            jit_lane = true;
        } else if (std.mem.eql(u8, a, "--interp")) {
            interp_lane = true;
        } else if (std.mem.eql(u8, a, "--interp-all")) {
            interp_lane = true;
            interp_all = true;
        }
    }

    const wasmtime_path_opt = try resolveWasmtime(gpa, io);
    defer if (wasmtime_path_opt) |p| gpa.free(p);

    if (wasmtime_path_opt == null) {
        try stdout.print(
            "SKIP-WASMTIME-MISSING — wasmtime not on PATH (and no nix-store wrapper found). " ++
                "§9.6 / 6.F differential gate is non-fatal on this host; the gate is real on " ++
                "hosts with wasmtime installed (the dev shell pins it via flake.nix).\n",
            .{},
        );
        try stdout.flush();
        return;
    }
    const wasmtime_path = wasmtime_path_opt.?;

    // Second-oracle resolution (only when --wasmer): wasmer is Mac-only in the
    // flake, so it is absent on the x86_64 hosts — the lane then skips with a
    // notice and the wasmtime gate still runs (parallels SKIP-WASMTIME-MISSING).
    const wasmer_path_opt: ?[]u8 = if (wasmer_lane) try resolveWasmer(gpa, io) else null;
    defer if (wasmer_path_opt) |p| gpa.free(p);
    if (wasmer_lane and wasmer_path_opt == null) {
        try stdout.print(
            "SKIP-WASMER-MISSING — wasmer not on PATH; the A3 second-oracle lane needs " ++
                "`nix develop .#bench` (wasmer is Mac-only per flake.nix). wasmtime gate still runs.\n",
            .{},
        );
        try stdout.flush();
    }

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_dir, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer dir.close(io);

    var matched: u32 = 0;
    var mismatched: u32 = 0;
    var skipped_empty: u32 = 0;
    var skipped_wasmtime_fail: u32 = 0;
    var skipped_v2: u32 = 0;
    var total: u32 = 0;

    // AOT lane (D-283 widen / D-251 validate): run the SAME fixture through
    // standalone AOT-WASI (`.cwasm` produce → run) and byte-compare vs
    // wasmtime, independent of the interp outcome. REPORT-ONLY this chunk
    // (loud per-fixture logging, no gate-fail) — first triage of how much of
    // the corpus the AOT path covers; a follow-up chunk gates once clean.
    var aot_matched: u32 = 0;
    var aot_mismatched: u32 = 0;
    var aot_skipped: u32 = 0;

    // wasmer second-oracle lane (§9.6 A3, opt-in). Agreement is measured
    // against the wasmtime reference (not v2) — the point is to corroborate or
    // contradict the gate's single oracle. REPORT-ONLY.
    var wasmer_agree: u32 = 0;
    var wasmer_disagree: u32 = 0;
    var wasmer_skipped: u32 = 0;

    // JIT lane (D-283). Runs each fixture via the WASI-aware JIT path and
    // byte-diffs stdout vs wasmtime — the real `--engine jit` correctness signal.
    var jit_matched: u32 = 0;
    var jit_mismatched: u32 = 0;
    var jit_skipped: u32 = 0;
    var jit_skipped_empty: u32 = 0;
    // Denominator for the JIT lane: fixtures the oracle ANSWERED for — i.e.
    // wasmtime spawned and produced a stdout + exit code, whatever that exit
    // code was. Not "fixtures wasmtime ran successfully": a non-zero `wt_exit`
    // still gives the lane something to diff against, exactly as it does for
    // the shared lane, so it still owes a verdict. `jit_matched +
    // jit_mismatched + jit_skipped + jit_skipped_empty` MUST equal this.
    //
    // The lane sits directly below the increment, so today nothing can come
    // between them — this counts anyway, as the structural guard for exactly
    // that property. Any `continue` later inserted above the lane turns into a
    // loud shortfall instead of a fixture that silently stops being checked.
    // wasmtime-less hosts leave it at 0, so the invariant stays portable.
    var jit_eligible: u32 = 0;
    // The two ways a fixture leaves the corpus WITHOUT reaching the JIT lane.
    // ADR-0210 rule 5: a tally that cannot account for its own denominator reads
    // as authoritative and is not — so these are counted and printed, not merely
    // logged, and the identity below reconciles them against `total`.
    var jit_oracle_failed: u32 = 0;
    var jit_pre_oracle: u32 = 0;

    // Forced-interp lane (issue #215). Same bucketing discipline as the JIT
    // lane, with two differences: the identity has one extra bucket (the
    // enumerated slow skips), and oracle-unspawnable gets its OWN counter
    // instead of reusing `skipped_wasmtime_fail` — an enumerated fixture whose
    // oracle also fails to spawn must land in exactly one interp bucket, and
    // the shared counter cannot know about the enumeration.
    var interp_matched: u32 = 0;
    var interp_mismatched: u32 = 0;
    var interp_skipped: u32 = 0;
    var interp_skipped_empty: u32 = 0;
    var interp_eligible: u32 = 0;
    var interp_oracle_failed: u32 = 0;
    var interp_unspawnable: u32 = 0;
    var interp_pre_oracle: u32 = 0;
    var interp_enum_skipped: u32 = 0;
    // Which `interp_slow_skips` rows matched a real corpus file this walk —
    // the gate fails on a row that matched none (stale entry), so the table
    // cannot silently outlive a renamed or deleted fixture.
    var interp_enum_seen = [_]bool{false} ** interp_slow_skips.len;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;
        total += 1;

        const fixture_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ corpus_dir, entry.name });
        defer gpa.free(fixture_path);

        // Enumerated slow-skip check for the gating `--interp` lane — BEFORE
        // the read and the oracle spawn on purpose. The exclusion is a
        // corpus-level property of the fixture NAME, so it must land in
        // exactly one interp bucket whatever else fails for the fixture:
        // matched after the read, the stale-entry gate would misreport an
        // unreadable-but-present enumerated fixture as "no such fixture";
        // counted after an oracle-side skip, the same fixture would land in
        // two buckets and break the identity on exactly the host where it
        // matters (e.g. wasmtime-unusable, where every spawn fails).
        const interp_enum_measured: ?[]const u8 = blk: {
            if (!interp_lane or interp_all) break :blk null;
            for (interp_slow_skips, 0..) |row, i| {
                if (std.mem.eql(u8, row.name, entry.name)) {
                    interp_enum_seen[i] = true;
                    break :blk row.measured;
                }
            }
            break :blk null;
        };
        if (interp_enum_measured) |measured| {
            try stdout.print(
                "  SKIP-INTERP-SLOW  {s} (enumerated: forced-interp {s} measured; excluded from the gating lane, covered by --interp-all)\n",
                .{ entry.name, measured },
            );
            interp_enum_skipped += 1;
        }

        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(64 << 20)) catch {
            try stdout.print("SKIP-V2-READ  {s}\n", .{entry.name});
            skipped_v2 += 1;
            jit_pre_oracle += 1;
            // Exactly-one-bucket: an enumerated fixture is already accounted.
            if (interp_lane and interp_enum_measured == null) interp_pre_oracle += 1;
            continue;
        };
        defer gpa.free(bytes);

        const needs_preopen = fixtureNeedsPreopen(entry.name);
        // `try`, not a categorised skip: being unable to create a directory
        // under `zig-out/` is a broken host, not a property of the fixture, and
        // the three per-lane resets below cannot `continue` anyway without
        // breaking the JIT lane's accounting. One failure mode, one handling.
        if (needs_preopen) try resetPreopenScratch(io, cwd);
        defer if (needs_preopen) {
            cwd.deleteTree(io, preopen_scratch) catch {};
        };

        // Spawn wasmtime, capturing stdout. wasmtime exits with
        // the guest's proc_exit code (0 on success); a non-zero
        // exit + non-empty stderr usually means the guest itself
        // failed, but we still try the byte compare since that
        // is what §9.6 / 6.F measures. Needs-preopen fixtures get
        // `--dir <scratch>::.` (wasmtime host::guest syntax).
        const wt_argv: []const []const u8 = if (needs_preopen)
            &.{ wasmtime_path, "run", "--dir", preopen_scratch ++ "::.", fixture_path }
        else
            &.{ wasmtime_path, "run", fixture_path };
        const wt_result = std.process.run(gpa, io, .{
            .argv = wt_argv,
        }) catch |err| {
            try stdout.print("SKIP-WASMTIME-FAIL  {s}: {s}\n", .{ entry.name, @errorName(err) });
            skipped_wasmtime_fail += 1;
            if (interp_lane and interp_enum_measured == null) interp_unspawnable += 1;
            continue;
        };
        defer gpa.free(wt_result.stdout);
        defer gpa.free(wt_result.stderr);
        const wt_stdout = wt_result.stdout;
        const wt_exit: u8 = switch (wt_result.term) {
            .exited => |c| c,
            else => 1,
        };
        // The JIT lane owes a verdict only where the oracle RAN, not merely
        // spawned. A non-zero `wt_exit` means wasmtime itself could not complete
        // the fixture, so there is no trustworthy reference to diff against —
        // the same guard SKIP-JIT-TRAP already applies one level down. Without
        // it an oracle-side gap fails the gate blaming the JIT, and that is
        // reachable: CI pins wasmtime 45.0.0 (`.github/versions.lock`) while
        // this corpus is measured against newer builds. All 56 fixtures exit 0
        // under the runner's own invocation today, so this changes nothing now.
        const jit_owed = jit_lane and wt_exit == 0;
        if (jit_owed) jit_eligible += 1;
        if (jit_lane and wt_exit != 0) {
            try stdout.print("  ORACLE-FAILED-JIT  {s} (wasmtime exit={d} — outside the differential's scope)\n", .{ entry.name, wt_exit });
            jit_oracle_failed += 1;
        }

        // Same owed-a-verdict rule as the JIT lane, minus the enumerated
        // fixtures — those are already in their own bucket above.
        const interp_owed = interp_lane and wt_exit == 0 and interp_enum_measured == null;
        if (interp_owed) interp_eligible += 1;
        if (interp_lane and wt_exit != 0 and interp_enum_measured == null) {
            try stdout.print("  ORACLE-FAILED-INTERP  {s} (wasmtime exit={d} — outside the differential's scope)\n", .{ entry.name, wt_exit });
            interp_oracle_failed += 1;
        }

        // Mirror wasmtime's default of `argv[0] = <wasm filename>`
        // so guests like `c_hello_wasi` that print argv[0] produce
        // identical bytes.
        const v2_argv: [1][]const u8 = .{entry.name};

        // The AOT, JIT, and forced-interp lanes run BEFORE the shared (.auto)
        // lane, not after. None reads a shared-lane result — only `bytes` and
        // the wasmtime reference — and every exit from the shared block below
        // (its error `catch`, SKIP-V2-TRAP, SKIP-EMPTY) is a `continue` that
        // would otherwise deny these lanes a fixture the oracle DID run. That
        // mattered once the JIT lane started gating on its denominator: a
        // shared-lane skip, which that lane itself tolerates, failed the JIT
        // gate with the wrong explanation.
        // The wasmer lane genuinely needs `v2_stdout`, so it stays below.
        //
        // BISECT NOTE: this puts up to three in-process executions (two native,
        // one interpreted) ahead of the shared lane's run of the same fixture.
        // D-489 investigated exactly that class — tinygo_json diverged under
        // the diff runner but not standalone, an in-process ripple (`zig build
        // d489-repro`). Measured green on x86_64-linux across all lanes after
        // the move, but if a shared-lane MISMATCH ever appears on another
        // host, suspect this ordering before the engines.
        //
        // Flush per fixture so incremental output shows progress.
        if (aot_lane) {
            if (needs_preopen) try resetPreopenScratch(io, cwd);
            if (bytes.len > aot_size_cap) {
                // The AOT lane JIT-compiles each fixture in-process; large libc
                // / Go / Rust guests (100KB–1MB) take minutes to compile AND
                // already trap under `--engine jit` (a separate v2 gap), so
                // they can't validate AOT either. Cap to keep the run practical;
                // the small compute/WASI fixtures are the achievable validation.
                try stdout.print("  SKIP-AOT-LARGE  {s} ({d} bytes > {d} cap)\n", .{ entry.name, bytes.len, aot_size_cap });
                aot_skipped += 1;
            } else switch (try aotCompare(gpa, io, bytes, entry.name, &v2_argv, needs_preopen, wt_stdout, wt_exit, stdout)) {
                .match => aot_matched += 1,
                .mismatch => aot_mismatched += 1,
                .skip => aot_skipped += 1,
            }
            try stdout.flush();
        }

        if (jit_owed) {
            if (needs_preopen) try resetPreopenScratch(io, cwd);
            switch (try jitCompare(gpa, io, bytes, entry.name, &v2_argv, needs_preopen, wt_stdout, wt_exit, stdout)) {
                .match => jit_matched += 1,
                .mismatch => jit_mismatched += 1,
                .skip => jit_skipped += 1,
                .skip_empty => jit_skipped_empty += 1,
            }
            try stdout.flush();
        }

        if (interp_owed) {
            if (needs_preopen) try resetPreopenScratch(io, cwd);
            const deadline_ms: u64 = if (interp_all) interp_all_deadline_ms else interp_deadline_ms;
            switch (try interpCompare(gpa, io, bytes, entry.name, &v2_argv, needs_preopen, wt_stdout, wt_exit, deadline_ms, stdout)) {
                .match => interp_matched += 1,
                .mismatch => interp_mismatched += 1,
                .skip => interp_skipped += 1,
                .skip_empty => interp_skipped_empty += 1,
            }
            try stdout.flush();
        }

        var v2_stdout: std.ArrayList(u8) = .empty;
        // capture_alloc contract (2d99e5a2): runWasmCaptured* grows the
        // capture buffer with the CALLER's allocator — free with the same
        // `gpa` or glibc aborts with `free(): invalid pointer`.
        defer v2_stdout.deinit(gpa);

        if (needs_preopen) try resetPreopenScratch(io, cwd);
        const v2_result = if (needs_preopen)
            cli_run.runWasmCapturedOpts(gpa, io, bytes, &v2_argv, &v2_stdout, null, &.{
                .{ .host_path = preopen_scratch, .guest_path = "." },
            }, &.{}, &.{}, null, .{})
        else
            cli_run.runWasmCaptured(gpa, io, bytes, &v2_argv, &v2_stdout, null);
        const v2_exit: u8 = v2_result catch |err| {
            try stdout.print("SKIP-V2-{s}  {s}\n", .{ @errorName(err), entry.name });
            skipped_v2 += 1;
            continue;
        };

        // wasmer second-oracle lane (opt-in) — placed before the v2-trap/empty
        // continues so the references are compared even where v2 can't complete.
        if (wasmer_lane and wasmer_path_opt != null) {
            if (needs_preopen) try resetPreopenScratch(io, cwd);
            switch (try wasmerCompare(gpa, io, wasmer_path_opt.?, corpus_dir, entry.name, needs_preopen, wt_stdout, wt_exit, v2_stdout.items, stdout)) {
                .agree => wasmer_agree += 1,
                .disagree => wasmer_disagree += 1,
                .skip => wasmer_skipped += 1,
            }
            try stdout.flush();
        }

        // v2 trapped / exited non-zero where wasmtime ran to a clean exit
        // (0) = v2 could NOT complete the run — a v2 limitation, not an
        // output regression. Categorise skipped-v2, consistent with
        // instantiate-fail skips. Both-completed-but-different-output still
        // falls through to MISMATCH below, so genuine output regressions are
        // NOT masked. (The standard-Go CallStackExhausted case that used to
        // land here was the label-stack depth bug, resolved in D-242.)
        if (v2_exit != 0 and wt_exit == 0) {
            try stdout.print("SKIP-V2-TRAP  {s} (v2 exit={d}, wasmtime exit=0 — v2 could not complete)\n", .{ entry.name, v2_exit });
            skipped_v2 += 1;
            continue;
        }

        if (wt_stdout.len == 0 and v2_stdout.items.len == 0) {
            try stdout.print("SKIP-EMPTY  {s}\n", .{entry.name});
            skipped_empty += 1;
            continue;
        }

        if (std.mem.eql(u8, wt_stdout, v2_stdout.items)) {
            try stdout.print("MATCH  {s} ({d} bytes)\n", .{ entry.name, wt_stdout.len });
            matched += 1;
        } else {
            try stdout.print(
                "MISMATCH  {s} (wasmtime={d} bytes, v2={d} bytes)\n",
                .{ entry.name, wt_stdout.len, v2_stdout.items.len },
            );
            mismatched += 1;
        }
    }

    try stdout.print(
        "\ndiff_runner: {d}/{d} matched, {d} mismatched, {d} skipped-empty, " ++
            "{d} skipped-wasmtime-fail, {d} skipped-v2\n",
        .{ matched, total, mismatched, skipped_empty, skipped_wasmtime_fail, skipped_v2 },
    );
    // AOT lane summary (opt-in, report-only; D-283 widen / D-251 validate).
    if (aot_lane) {
        try stdout.print(
            "diff_runner [aot]: {d}/{d} matched, {d} mismatched, {d} skipped (AOT-unsupported / trap) — REPORT-ONLY\n",
            .{ aot_matched, total, aot_mismatched, aot_skipped },
        );
    }
    if (wasmer_lane and wasmer_path_opt != null) {
        try stdout.print(
            "diff_runner [wasmer]: {d}/{d} agree-with-wasmtime, {d} REF-DISAGREE, {d} skipped — REPORT-ONLY\n",
            .{ wasmer_agree, total, wasmer_disagree, wasmer_skipped },
        );
    }
    if (jit_lane) {
        try stdout.print(
            "diff_runner [jit]: {d}/{d} matched vs wasmtime, {d} mismatched, {d} skipped (JIT-unsupported / trap), " ++
                "{d} skipped-empty, {d} unaccounted — GATING (fatal on mismatch, skip, or shortfall)\n",
            .{ jit_matched, jit_eligible, jit_mismatched, jit_skipped, jit_skipped_empty, jit_eligible -| (jit_matched + jit_mismatched + jit_skipped + jit_skipped_empty) },
        );
        // ADR-0210 rule 4: print the identity, do not leave it implied. `{d}/{d}`
        // above is against the ELIGIBLE set, so the corpus-level denominator has
        // to be reconciled separately or the ratio reads as full coverage.
        const jit_denominator = jit_eligible + jit_oracle_failed + skipped_wasmtime_fail + jit_pre_oracle;
        try stdout.print(
            "diff_runner [jit] RECONCILE: total {d} = eligible {d} + oracle-failed {d} + oracle-unspawnable {d} + dropped-before-oracle {d} → {s}\n",
            .{ total, jit_eligible, jit_oracle_failed, skipped_wasmtime_fail, jit_pre_oracle, if (jit_denominator == total) "CLOSED" else "OPEN" },
        );
    }
    if (interp_lane) {
        try stdout.print(
            "diff_runner [interp]: {d}/{d} matched vs wasmtime, {d} mismatched, {d} skipped (interp-unsupported / trap), " ++
                "{d} skipped-empty, {d} unaccounted — GATING (fatal on mismatch, skip, or shortfall)\n",
            .{ interp_matched, interp_eligible, interp_mismatched, interp_skipped, interp_skipped_empty, interp_eligible -| (interp_matched + interp_mismatched + interp_skipped + interp_skipped_empty) },
        );
        // Same rule-4 print as the JIT lane, one bucket wider: the enumerated
        // slow skips are part of the corpus-level denominator, so a fixture
        // enumerated out is visibly NOT part of the `{d}/{d}` coverage ratio.
        const interp_denominator = interp_eligible + interp_enum_skipped + interp_oracle_failed + interp_unspawnable + interp_pre_oracle;
        try stdout.print(
            "diff_runner [interp] RECONCILE: total {d} = eligible {d} + enumerated-slow {d} + oracle-failed {d} + oracle-unspawnable {d} + dropped-before-oracle {d} → {s}\n",
            .{ total, interp_eligible, interp_enum_skipped, interp_oracle_failed, interp_unspawnable, interp_pre_oracle, if (interp_denominator == total) "CLOSED" else "OPEN" },
        );
    }
    // Flush the summary unconditionally: the green path (no mismatch, matched
    // >= 30) returns at the bottom WITHOUT hitting any of the branch-local
    // flushes below, so the summary line would otherwise be lost in the
    // buffered writer (observed: "diff_runner: 53/" truncation).
    try stdout.flush();

    if (mismatched != 0) std.process.exit(1);
    // D-283 discharge (2026-06-20): the JIT-vs-wasmtime lane is a REAL gate (was
    // REPORT-ONLY). The realworld corpus reached 56/56 matched under `--engine
    // jit` once the (A) 2 miscompiles (c_sha256/emcc_fasta, D-330) and (B) 9 go_*
    // hangs (proc_exit JIT termination, D-468/ADR-0199) cleared.
    //
    // The lane must account for its own denominator (ADR-0210's rule, applied
    // here): "no mismatch" alone is satisfied by a lane that verified NOTHING,
    // because every way the JIT can fail to produce output — a compile error, a
    // trap, a fixture dropped before the lane by an earlier `continue` — lands
    // outside `jit_mismatched`. So all three arms gate:
    //
    //   mismatch    a fixture's JIT stdout differs from wasmtime's
    //   skip        the JIT could not complete a fixture the oracle answered for
    //   shortfall   a fixture the oracle answered for never reached the lane —
    //               unreachable as the loop is written today (the lane sits
    //               directly under the increment); it is the guard that keeps
    //               it that way
    //
    // Safe on wasmtime-less hosts: `jit_eligible` stays 0 there, so every arm is
    // vacuous and the lane cannot fire falsely.
    if (jit_lane) {
        const accounted = jit_matched + jit_mismatched + jit_skipped + jit_skipped_empty;
        if (jit_mismatched != 0) {
            try stdout.print("error: JIT lane byte-mismatched vs wasmtime on {d} fixture(s)\n", .{jit_mismatched});
            try stdout.flush();
            std.process.exit(1);
        }
        if (jit_skipped != 0) {
            try stdout.print(
                "error: JIT lane could not complete {d} of {d} fixture(s) the oracle answered for; a skip is " ++
                    "an unverified fixture, not a pass (fix the JIT gap or shrink the corpus deliberately)\n",
                .{ jit_skipped, jit_eligible },
            );
            try stdout.flush();
            std.process.exit(1);
        }
        const jit_denominator = jit_eligible + jit_oracle_failed + skipped_wasmtime_fail + jit_pre_oracle;
        if (jit_denominator != total) {
            try stdout.print(
                "error: JIT lane accounting OPEN — {d} of {d} fixture(s) fall in no bucket; the matched " ++
                    "ratio is against the eligible set and cannot be read as corpus coverage\n",
                .{ total -| jit_denominator, total },
            );
            try stdout.flush();
            std.process.exit(1);
        }
        if (accounted != jit_eligible) {
            try stdout.print(
                "error: JIT lane accounted for {d} of {d} fixture(s) the oracle answered for — {d} left the " ++
                    "corpus without a JIT verdict; a `continue` was added above the lane in the loop\n",
                // Saturating: `accounted > jit_eligible` is unreachable (the lane
                // runs at most once per eligible fixture), but a gate that panics
                // on an impossible state is worse than one that still reports.
                .{ accounted, jit_eligible, jit_eligible -| accounted },
            );
            try stdout.flush();
            std.process.exit(1);
        }
    }
    // Forced-interp lane gates (issue #215) — the JIT lane's arms, plus the
    // stale-entry check on the enumerated-skip table. Vacuous on wasmtime-less
    // and wasmtime-unusable hosts for the same reason the JIT gates are:
    // `interp_eligible` stays 0 there, and the enumerated bucket is counted
    // before the oracle spawn so the identity still closes.
    if (interp_lane) {
        const interp_accounted = interp_matched + interp_mismatched + interp_skipped + interp_skipped_empty;
        if (interp_mismatched != 0) {
            try stdout.print("error: interp lane byte-mismatched vs wasmtime on {d} fixture(s)\n", .{interp_mismatched});
            try stdout.flush();
            std.process.exit(1);
        }
        if (interp_skipped != 0) {
            try stdout.print(
                "error: interp lane could not complete {d} of {d} fixture(s) the oracle answered for; a skip is " ++
                    "an unverified fixture, not a pass (fix the interp gap or enumerate the exclusion deliberately)\n",
                .{ interp_skipped, interp_eligible },
            );
            try stdout.flush();
            std.process.exit(1);
        }
        // Only the gating config consults the table, so only it can vouch for
        // the rows; `--interp-all` never matches entries against the corpus.
        if (!interp_all) {
            for (interp_slow_skips, interp_enum_seen) |row, seen| {
                if (!seen) {
                    try stdout.print(
                        "error: interp lane enumerated-skip entry '{s}' matched no fixture in the corpus — " ++
                            "stale entry; remove the row or restore the fixture\n",
                        .{row.name},
                    );
                    try stdout.flush();
                    std.process.exit(1);
                }
            }
        }
        const interp_denominator = interp_eligible + interp_enum_skipped + interp_oracle_failed + interp_unspawnable + interp_pre_oracle;
        if (interp_denominator != total) {
            try stdout.print(
                "error: interp lane accounting OPEN — {d} of {d} fixture(s) fall in no bucket; the matched " ++
                    "ratio is against the eligible set and cannot be read as corpus coverage\n",
                .{ total -| interp_denominator, total },
            );
            try stdout.flush();
            std.process.exit(1);
        }
        if (interp_accounted != interp_eligible) {
            try stdout.print(
                "error: interp lane accounted for {d} of {d} fixture(s) the oracle answered for — {d} left the " ++
                    "corpus without an interp verdict; a `continue` was added above the lane in the loop\n",
                .{ interp_accounted, interp_eligible, interp_eligible -| interp_accounted },
            );
            try stdout.flush();
            std.process.exit(1);
        }
    }
    // wasmtime resolved via `which` but every spawn failed (e.g. on
    // windowsmini, where `which wasmtime` finds a stub that doesn't
    // actually execute). Treat as SKIP-WASMTIME-MISSING so the gate
    // remains portable; the gate is real on hosts where wasmtime
    // genuinely runs.
    if (matched == 0 and skipped_wasmtime_fail == total and total > 0) {
        try stdout.print(
            "SKIP-WASMTIME-UNUSABLE — wasmtime resolved but every spawn failed " ++
                "({d} of {d} fixtures); §9.6 / 6.F differential gate is non-fatal on this host.\n",
            .{ skipped_wasmtime_fail, total },
        );
        try stdout.flush();
        return;
    }
    if (matched < 30) {
        try stdout.print("error: §9.6 / 6.F requires 30+ matches; saw only {d}\n", .{matched});
        try stdout.flush();
        std.process.exit(1);
    }
}

/// Outcome of the AOT lane for one fixture. `skip` collapses every
/// AOT-unsupported reason (compile/produce error = §12.3b cycle-1 limits
/// like passive data / non-const globals; run error = unsupported entry
/// signature; trap = AOT couldn't complete where wasmtime did) — each is
/// logged with its specific reason for triage, none is silent.
const AotOutcome = enum { match, mismatch, skip };

/// Run `bytes` through standalone AOT-WASI (compile → `.cwasm` produce →
/// `runCwasmWasi` with stdout capture) and byte-compare vs `wt_stdout`.
/// Mirrors the interp lane's skip semantics: an AOT non-zero exit where
/// wasmtime exited 0 = AOT could not complete (skip, not a regression).
fn aotCompare(
    gpa: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    name: []const u8,
    argv: []const []const u8,
    needs_preopen: bool,
    wt_stdout: []const u8,
    wt_exit: u8,
    out: anytype,
) !AotOutcome {
    const zrunner = zwasm.engine.runner;
    const zproduce = zwasm.engine.codegen.aot.produce;

    var compiled = zrunner.compileWasm(gpa, bytes) catch |err| {
        try out.print("  SKIP-AOT-COMPILE  {s}: {s}\n", .{ name, @errorName(err) });
        return .skip;
    };
    defer compiled.deinit(gpa);

    const cwasm = zproduce.produceFromCompiledWasm(gpa, &compiled, bytes) catch |err| {
        try out.print("  SKIP-AOT-PRODUCE  {s}: {s}\n", .{ name, @errorName(err) });
        return .skip;
    };
    defer gpa.free(cwasm);

    var aot_stdout: std.ArrayList(u8) = .empty;
    defer aot_stdout.deinit(gpa);

    const preopens: []const cli_run.PreopenDir = if (needs_preopen)
        &.{.{ .host_path = preopen_scratch, .guest_path = "." }}
    else
        &.{};
    const aot_exit: u8 = cli_run.runCwasmWasi(gpa, io, cwasm, null, argv, preopens, &.{}, &.{}, &aot_stdout) catch |err| {
        try out.print("  SKIP-AOT-RUN  {s}: {s}\n", .{ name, @errorName(err) });
        return .skip;
    };
    if (aot_exit != 0 and wt_exit == 0) {
        try out.print("  SKIP-AOT-TRAP  {s} (aot exit={d}, wasmtime exit=0 — AOT could not complete)\n", .{ name, aot_exit });
        return .skip;
    }
    if (std.mem.eql(u8, wt_stdout, aot_stdout.items)) return .match;
    try out.print("  MISMATCH-AOT  {s} (wasmtime={d} bytes, aot={d} bytes)\n", .{ name, wt_stdout.len, aot_stdout.items.len });
    return .mismatch;
}

/// Outcome of the wasmer second-oracle lane for one fixture. `agree` =
/// wasmer's stdout equals wasmtime's (the gate's oracle is corroborated);
/// `disagree` = the two reference runtimes differ (REF-DISAGREE — the signal a
/// single-reference gate misses); `skip` = wasmer could not complete the run.
const WasmerOutcome = enum { agree, disagree, skip };

/// Run `fixture_path` through `wasmer run` and compare its stdout to the
/// wasmtime reference. On disagreement, also report which reference v2 (the
/// interp) matched, so the divergence is immediately triageable. Mirrors the
/// AOT/interp lanes' skip semantics: a wasmer non-zero exit where wasmtime
/// exited 0 = wasmer could not complete (skip, not a reference disagreement).
fn wasmerCompare(
    gpa: std.mem.Allocator,
    io: std.Io,
    wasmer_path: []const u8,
    corpus_dir: []const u8,
    name: []const u8,
    needs_preopen: bool,
    wt_stdout: []const u8,
    wt_exit: u8,
    v2_stdout: []const u8,
    out: anytype,
) !WasmerOutcome {
    // argv[0] convention differs at the CLI frontend: wasmtime (and v2) use the
    // fixture BASENAME, wasmer uses the path arg verbatim. To measure runtime
    // SEMANTICS — not the launcher's argv[0] policy — run wasmer FROM the corpus
    // dir with the bare basename, so its argv[0] matches wasmtime's. Without this
    // every argv[0]-printing guest is a spurious REF-DISAGREE.
    // The preopen fixture keeps the inherited cwd + relative `--mapdir` scratch
    // (its guest does not print a divergent argv[0]); only there is the full path
    // passed so the relative host scratch still resolves.
    // wasmer preopen syntax is `--mapdir <GUEST_DIR:HOST_DIR>` (single colon),
    // vs wasmtime's `--dir <HOST::GUEST>`.
    const fixture_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ corpus_dir, name });
    defer gpa.free(fixture_path);
    const wm_argv: []const []const u8 = if (needs_preopen)
        &.{ wasmer_path, "run", "--mapdir", "." ++ ":" ++ preopen_scratch, fixture_path }
    else
        &.{ wasmer_path, "run", name };
    const cwd_opt: std.process.Child.Cwd = if (needs_preopen) .inherit else .{ .path = corpus_dir };
    const wm_result = std.process.run(gpa, io, .{ .argv = wm_argv, .cwd = cwd_opt }) catch |err| {
        try out.print("  SKIP-WASMER-RUN  {s}: {s}\n", .{ name, @errorName(err) });
        return .skip;
    };
    defer gpa.free(wm_result.stdout);
    defer gpa.free(wm_result.stderr);
    const wm_exit: u8 = switch (wm_result.term) {
        .exited => |c| c,
        else => 1,
    };
    if (wm_exit != 0 and wt_exit == 0) {
        try out.print("  SKIP-WASMER-TRAP  {s} (wasmer exit={d}, wasmtime exit=0)\n", .{ name, wm_exit });
        return .skip;
    }
    if (std.mem.eql(u8, wt_stdout, wm_result.stdout)) return .agree;

    const v2_side = if (std.mem.eql(u8, v2_stdout, wm_result.stdout))
        "v2==wasmer"
    else if (std.mem.eql(u8, v2_stdout, wt_stdout))
        "v2==wasmtime"
    else
        "v2!=both";
    try out.print(
        "  REF-DISAGREE  {s} (wasmtime={d} bytes, wasmer={d} bytes; {s})\n",
        .{ name, wt_stdout.len, wm_result.stdout.len, v2_side },
    );
    return .disagree;
}

/// Outcome of the JIT lane for one fixture — mirrors `AotOutcome`, plus
/// `skip_empty` so an empty-vs-empty pair is not counted as coverage (the
/// interp lane's SKIP-EMPTY, mirrored: comparing "" to "" verifies nothing).
const JitOutcome = enum { match, mismatch, skip, skip_empty };

/// Run `bytes` through the WASI-aware JIT path (`cli_run.runWasmJitCaptured` =
/// the real `--engine jit`, with a stdout-capture buffer) and byte-compare vs
/// `wt_stdout`. This is the realworld JIT-correctness net (D-283) — the WASI
/// host is what makes it one: its predecessor invoked `_start` with a null host
/// and so reported a trap for every fixture that reached `fd_write`/`proc_exit`.
/// Skip semantics mirror the interp/AOT lanes: a JIT non-zero exit where
/// wasmtime exited 0 = the JIT could not complete. Unlike those lanes a skip is
/// NOT tolerated — the caller's gate fails on it, because a fixture the JIT
/// could not run is an unverified fixture.
fn jitCompare(
    gpa: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    name: []const u8,
    argv: []const []const u8,
    needs_preopen: bool,
    wt_stdout: []const u8,
    wt_exit: u8,
    out: anytype,
) !JitOutcome {
    var jit_stdout: std.ArrayList(u8) = .empty;
    defer jit_stdout.deinit(gpa);
    const preopens: []const cli_run.PreopenDir = if (needs_preopen)
        &.{.{ .host_path = preopen_scratch, .guest_path = "." }}
    else
        &.{};
    // Per-fixture deadline. This lane runs the guest IN-PROCESS, so a JIT hang
    // (the D-468 `proc_exit` class) would wedge `test-all` until the CI job's
    // 120-minute cap rather than failing loudly. The removed `run_runner_jit`
    // run stage bounded its own guests with fork + SIGALRM; this is the
    // in-process equivalent, via the cooperative interrupt both engines poll
    // (ADR-0179 #3a-4). Slowest fixture measured 3.4s (`go_json_marshal`,
    // x86_64-linux), so 60s is ~18x headroom for a slower runner while still
    // turning a hang into a SKIP-JIT-TRAP the gate fails on.
    //
    // Bounded here only. The shared lane below still runs unbounded — that is
    // pre-existing (as is `test-realworld-run`'s), and arming it would change
    // what that lane exercises, so it is left alone rather than swept in.
    const jit_limits: cli_run.Limits = .{ .timeout_ms = 60_000 };
    const jit_exit: u8 = cli_run.runWasmJitCaptured(gpa, io, bytes, null, argv, preopens, &.{}, &.{}, jit_limits, &jit_stdout, null, .none) catch |err| {
        try out.print("  SKIP-JIT-RUN  {s}: {s}\n", .{ name, @errorName(err) });
        return .skip;
    };
    if (jit_exit != 0 and wt_exit == 0) {
        try out.print("  SKIP-JIT-TRAP  {s} (jit exit={d}, wasmtime exit=0 — JIT could not complete)\n", .{ name, jit_exit });
        return .skip;
    }
    if (wt_stdout.len == 0 and jit_stdout.items.len == 0) {
        try out.print("  SKIP-JIT-EMPTY  {s}\n", .{name});
        return .skip_empty;
    }
    if (std.mem.eql(u8, wt_stdout, jit_stdout.items)) return .match;
    try out.print("  MISMATCH-JIT  {s} (wasmtime={d} bytes, jit={d} bytes)\n", .{ name, wt_stdout.len, jit_stdout.items.len });
    return .mismatch;
}

/// Outcome of the forced-interp lane for one fixture — mirrors `JitOutcome`.
const InterpOutcome = enum { match, mismatch, skip, skip_empty };

/// Run `bytes` through the captured-run path with the engine PINNED to the
/// interpreter (`Limits{ .engine = .interp }`, the D-496 selection surface —
/// same forcing as CLI `--engine interp`) and byte-compare vs `wt_stdout`.
/// This is the lane that makes "the realworld corpus runs on the interp and
/// the result is checked" true (issue #215): both default-`Limits` realworld
/// runners resolve `.auto`, which prefers the JIT, so before this lane an
/// interp-only miscompile in code these fixtures exercise could pass every
/// realworld gate. Skip semantics mirror the JIT lane, and as there a skip is
/// fatal in the caller's gate. `deadline_ms` arms the cooperative interrupt
/// the interp dispatch loop polls (ADR-0179 #3a-4): the guest runs in-process,
/// so a hang becomes a fatal SKIP-INTERP-TRAP instead of wedging `test-all`.
fn interpCompare(
    gpa: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    name: []const u8,
    argv: []const []const u8,
    needs_preopen: bool,
    wt_stdout: []const u8,
    wt_exit: u8,
    deadline_ms: u64,
    out: anytype,
) !InterpOutcome {
    var interp_stdout: std.ArrayList(u8) = .empty;
    defer interp_stdout.deinit(gpa);
    const preopens: []const cli_run.PreopenDir = if (needs_preopen)
        &.{.{ .host_path = preopen_scratch, .guest_path = "." }}
    else
        &.{};
    const limits: cli_run.Limits = .{ .engine = .interp, .timeout_ms = deadline_ms };
    const interp_exit: u8 = cli_run.runWasmCapturedOpts(gpa, io, bytes, argv, &interp_stdout, null, preopens, &.{}, &.{}, null, limits) catch |err| {
        try out.print("  SKIP-INTERP-RUN  {s}: {s}\n", .{ name, @errorName(err) });
        return .skip;
    };
    if (interp_exit != 0 and wt_exit == 0) {
        try out.print("  SKIP-INTERP-TRAP  {s} (interp exit={d}, wasmtime exit=0 — interp could not complete)\n", .{ name, interp_exit });
        return .skip;
    }
    if (wt_stdout.len == 0 and interp_stdout.items.len == 0) {
        try out.print("  SKIP-INTERP-EMPTY  {s}\n", .{name});
        return .skip_empty;
    }
    if (std.mem.eql(u8, wt_stdout, interp_stdout.items)) return .match;
    try out.print("  MISMATCH-INTERP  {s} (wasmtime={d} bytes, interp={d} bytes)\n", .{ name, wt_stdout.len, interp_stdout.items.len });
    return .mismatch;
}

/// Test whether `wasmtime` is reachable on PATH. Returns the
/// bare command name (`"wasmtime"`) if reachable, null otherwise.
///
/// We deliberately do NOT return the path from `which` /
/// `where.exe` because on Windows MSYS / Git-Bash hosts (e.g.
/// the project's `windowsmini`) `which` returns a Unix-style
/// `/c/...` path that Zig's native Windows process spawn cannot
/// resolve to the actual binary. Returning the bare command name
/// lets `std.process.run` do its own PATH lookup, which works
/// uniformly on Mac aarch64, OrbStack Ubuntu, and Windows native.
///
/// Discharges debt D-008 (the previous "wasmtime stub on
/// windowsmini" framing was wrong; wasmtime IS installed there
/// — `which`'s MSYS-format path was the actual blocker).
fn resolveWasmtime(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "wasmtime", "--version" },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return null;
    return try allocator.dupe(u8, "wasmtime");
}

/// Test whether `wasmer` is reachable on PATH (the §9.6 A3 second-oracle lane).
/// wasmer is Mac-only in the flake (no x86_64-linux binary-cache hit), so this
/// returns null off the Mac dev shell and the lane skips. Bare command name is
/// returned (PATH lookup) for the same cross-host reason as resolveWasmtime.
fn resolveWasmer(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "wasmer", "--version" },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return null;
    return try allocator.dupe(u8, "wasmer");
}
