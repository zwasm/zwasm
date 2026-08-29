//! Interp-vs-JIT EXECUTION differential fuzzer (D-469; extended per D-510).
//!
//! Walks one or more corpora of `.wasm` modules and, for each one that BOTH
//! engines instantiate, invokes every 0-param / single-scalar-result (i32/i64/
//! f32/f64) export under the interp (`Instance.invoke`) AND the JIT
//! (`JitInstance.invoke`) with a deterministic fuel budget, then compares the
//! outcomes. A divergence — interp returns a value the JIT doesn't (or vice
//! versa), the two return DIFFERENT values, both trap with DIFFERENT precise
//! kinds, or the post-invoke LINEAR-MEMORY SNAPSHOTS differ — is a finding
//! (the D-330/D-331A/D-468 JIT-execute-miscompile class + the D-470/GC-trap-kind
//! precision class + the silent-wrong-store class the value compare alone
//! misses). A process-level CRASH (panic / unreachable / SEGV) is likewise a
//! finding (external detection: the process dies, the runner sees the signal exit).
//!
//! Two JIT lanes per module (D-510 / ADR-0202 D4): the default `.auto` lane
//! (guard-page bounds-check ELISION on qualifying memories) and an `.explicit`
//! lane compiled with the inline check forced. Both diff against the interp
//! oracle, so an elision-specific miscompile (guard fault mis-redirected, check
//! wrongly removed) diverges from BOTH the oracle and its own explicit twin.
//!
//! Trap-kind compare: both engines map a trap to the shared `trap_surface.TrapKind`
//! (interp error → `mapInterpTrap`; JIT raw code → `jitTrapCode`). Kinds are only
//! compared when BOTH sides name one precisely; an interp `binding_error` (host
//! catch-all) or a JIT generic-bucket code (raw 0/1, codegen-unsplit) is treated
//! as incomparable and falls back to the lenient both-trap-OK rule — no false
//! mismatch, but a genuine kind divergence (e.g. interp `null_reference` vs JIT
//! `oob_memory`) is caught.
//!
//! Memory-snapshot compare: after an outcome where every lane is PRECISE
//! (matching values, or matching precisely-named trap kinds — deterministic
//! execution pins the same trap point), the interp's memory0 slice is
//! byte-compared against each JIT lane's. After a LENIENT outcome (fuel on any
//! engine, incomparable trap kind, interp unimplemented-op bailout) the
//! instances may have executed to DIFFERENT points, so the module's remaining
//! exports are skipped — comparing values or memory on top of divergent state
//! would be unsound (false-positive source).
//!
//! Why FOCUSED (0-param, 1 scalar result): it sidesteps argument generation and
//! the multi-result / v128 / ref-result marshalling mismatch between the two
//! invoke ABIs (interp `[]Value`; JIT `[]u64 → ?u64`), while still exercising the
//! full function body under both engines. Widening to (zero-filled) i32/i64 PARAMS
//! was measured to add 0 funcs (the single-scalar-RESULT filter is binding, not
//! params), so params stay at 0; the RESULT filter does include f32/f64 — FP
//! execution is a prime divergence source and the bit-compare is sound under the
//! corpus's `canonicalize-nans`.
//!
//! Fuel: both engines are bounded so an infinite-loop smith body can't hang the
//! fuzzer. The fuel UNITS differ (interp = per-instruction; JIT = poll-site
//! crossings), so `out_of_fuel` on EITHER side is NOT comparable. Modules with
//! imports are skipped (interp instantiate fails without a host → the whole
//! module is skipped, avoiding an import asymmetry).
//!
//! GATING: prints each MISMATCH (module / func / values) and exits non-zero if
//! any divergence is seen (the campaign baseline confirmed 122 funcs / 0 mismatch).
//!
//! Usage: `zig build fuzz-diff` (= `test-fuzz-exec`; committed exec_seed +
//! regression corpora) / `zwasm-fuzz-exec <dir> [dir...]` (campaign corpora).

const std = @import("std");

const zwasm = @import("zwasm");
const engine_runner = zwasm.engine.runner;
const trap_surface = zwasm.api.trap_surface;
const TrapKind = trap_surface.TrapKind;

const FUEL: u64 = 200_000;
const OUT_OF_FUEL_KIND: u32 = 17; // jit raw trap_kind for out_of_fuel

const Outcome = union(enum) {
    value: u64, // normalised result bits (i32 zero-extended into the low 32)
    // A non-fuel trap. The payload is the PRECISE trap kind when both ABIs can
    // name it (interp error → `mapInterpTrap`; JIT raw code → `jitTrapCode`), or
    // `null` when incomparable — interp `binding_error` (host catch-all) or JIT
    // generic bucket (raw 0/1, codegen-unsplit). Comparing kinds catches the
    // D-470 / GC-trap-kind-precision class (both engines trap, but with DIFFERENT
    // kinds) that a plain both-trap-OK check silently passes; `null` on either
    // side falls back to that lenient both-trap-OK to avoid a false mismatch.
    trap: ?TrapKind,
    fuel, // out_of_fuel — not comparable across engines
};

/// Per-lane compare verdict. `ok_lenient` passes the gate but marks the
/// instances' execution states as no-longer-provably-symmetric.
const LaneVerdict = enum { ok_precise, ok_lenient, mismatch };

const Stats = struct {
    processed: u32 = 0,
    modules_compared: u32 = 0,
    funcs_compared: u32 = 0,
    mem_compared: u32 = 0,
    mismatched: u32 = 0,
};

fn kindName(k: ?TrapKind) []const u8 {
    return if (k) |kk| @tagName(kk) else "(incomparable)";
}

// f32/f64 results: the smith corpus is generated with `canonicalize-nans` so a
// NaN result is the single canonical bit pattern in BOTH engines — a direct bit
// compare is sound (a differing NaN payload would be a real spec divergence). The
// curated f32/f64 exec_seed cases return non-NaN finite values, so the committed
// gate doesn't depend on the canonicalisation either way.

/// Normalise an interp result Value to its raw bits (32-bit scalars zero-extended
/// into the low 32, matching the JIT's `dispatchNoArg` carrier encoding).
fn valueBits(v: zwasm.Value) u64 {
    return switch (v) {
        .i32 => |x| @as(u64, @as(u32, @bitCast(x))),
        .f32 => |x| @as(u64, @as(u32, @bitCast(x))),
        .i64 => |x| @bitCast(x),
        .f64 => |x| @bitCast(x),
        else => 0, // filtered out before invoke
    };
}

fn interpInvoke(inst: *zwasm.Instance, name: []const u8) Outcome {
    var results: [1]zwasm.Value = undefined;
    inst.invoke(name, &.{}, results[0..1]) catch |err| {
        if (err == error.OutOfFuel) return .fuel;
        const k = trap_surface.mapInterpTrap(err);
        // `binding_error` is the host catch-all bucket, not a spec trap kind the
        // JIT path emits — treat as incomparable rather than risk a false mismatch.
        return .{ .trap = if (k == .binding_error) null else k };
    };
    return .{ .value = valueBits(results[0]) };
}

fn jitInvoke(jit: *engine_runner.JitInstance, gpa: std.mem.Allocator, name: []const u8) Outcome {
    // `JitInstance.invoke` returns the scalar result as a u64 carrier already
    // zero-extended for 32-bit types (dispatchNoArg) — matches `valueBits`.
    const r = jit.invoke(gpa, name, &.{}) catch {
        const raw = jit.owned.rt.trap_kind;
        if (raw == OUT_OF_FUEL_KIND) return .fuel;
        // `jitTrapCode` → null for the generic bucket (raw 0/1) the codegen does
        // not split per-kind; null = incomparable (preserve the both-trap-OK path).
        return .{ .trap = trap_surface.jitTrapCode(raw) };
    };
    return .{ .value = r orelse 0 };
}

/// Arm the deterministic fuel budget and clear the shared trap-kind slot so a
/// trap on THIS invoke can't read a stale code from a prior export (raw 0 →
/// `jitTrapCode` null → lenient).
fn armJit(jit: *engine_runner.JitInstance) void {
    jit.owned.rt.fuel_cell = std.math.cast(i64, FUEL) orelse std.math.maxInt(i64);
    jit.owned.rt.fuel_metered = 1;
    jit.owned.rt.trap_kind = 0;
}

/// Compare one JIT lane's outcome against the interp oracle's; print any
/// mismatch. Caller pre-filters `.fuel` (never reaches here).
fn compareLane(
    stdout: *std.Io.Writer,
    module_name: []const u8,
    func_name: []const u8,
    lane: []const u8,
    io_out: Outcome,
    jo_out: Outcome,
) !LaneVerdict {
    const verdict: LaneVerdict = switch (io_out) {
        // Both trap: OK iff the kinds match, OR either side is incomparable
        // (interp host bucket / JIT generic bucket) → lenient both-trap-OK.
        .trap => |ik| switch (jo_out) {
            .trap => |jk| if (ik == null or jk == null)
                .ok_lenient
            else if (ik.? == jk.?)
                .ok_precise
            else
                .mismatch,
            else => .mismatch,
        },
        .value => |iv| if (jo_out == .value and jo_out.value == iv) .ok_precise else .mismatch,
        .fuel => unreachable,
    };
    if (verdict == .mismatch) {
        try stdout.print("MISMATCH  {s} / {s} [{s}]: interp={s} jit={s}\n", .{
            module_name, func_name, lane, @tagName(io_out), @tagName(jo_out),
        });
        if (io_out == .value and jo_out == .value) {
            try stdout.print("          interp=0x{x} jit=0x{x}\n", .{ io_out.value, jo_out.value });
        } else if (io_out == .trap and jo_out == .trap) {
            try stdout.print("          interp-kind={s} jit-kind={s}\n", .{
                kindName(io_out.trap), kindName(jo_out.trap),
            });
        }
    }
    return verdict;
}

/// Byte-compare the interp's post-invoke memory0 snapshot against a JIT lane's
/// (D-510 silent-wrong-store class). Returns true on mismatch (printed).
fn compareMemory(
    stdout: *std.Io.Writer,
    module_name: []const u8,
    func_name: []const u8,
    lane: []const u8,
    interp_mem: []const u8,
    jit_mem: []const u8,
) !bool {
    if (interp_mem.len == jit_mem.len and std.mem.eql(u8, interp_mem, jit_mem)) return false;
    if (interp_mem.len != jit_mem.len) {
        try stdout.print("MEM-MISMATCH  {s} / {s} [{s}]: interp-len={d} jit-len={d}\n", .{
            module_name, func_name, lane, interp_mem.len, jit_mem.len,
        });
        return true;
    }
    var off: usize = 0;
    while (off < interp_mem.len and interp_mem[off] == jit_mem[off]) : (off += 1) {}
    try stdout.print("MEM-MISMATCH  {s} / {s} [{s}]: first diff at 0x{x}: interp=0x{x:0>2} jit=0x{x:0>2}\n", .{
        module_name, func_name, lane, off, interp_mem[off], jit_mem[off],
    });
    return true;
}

fn processModule(
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    module_name: []const u8,
    bytes: []const u8,
    stats: *Stats,
) !void {
    // Interp: compile + instantiate. Any error (invalid / imports / start
    // trap) → skip the whole module (keeps the engines symmetric).
    var eng = zwasm.Engine.init(gpa, .{}) catch return;
    defer eng.deinit();
    var mod = eng.compile(bytes) catch return;
    defer mod.deinit();
    var interp_inst = mod.instantiate(.{}) catch return;
    defer interp_inst.deinit();

    // JIT lane 1 (`.auto` — guard-page elision, ADR-0202 D4): instantiate.
    // UnsupportedOp / import / resource errors → skip.
    var jit = engine_runner.JitInstance.init(gpa, bytes) catch return;
    defer jit.deinit(gpa);

    // JIT lane 2 (`.explicit` — inline bounds check forced): the D-510
    // differential axis named in `compile.zig`. The knob is process-global;
    // restore `.auto` immediately after the compile. `.explicit` is strictly
    // more conservative than `.auto`, so an init failure here is itself
    // suspicious — but not a value divergence; run auto-only in that case.
    engine_runner.setBoundsChecks(.explicit);
    var jit_explicit: ?engine_runner.JitInstance = engine_runner.JitInstance.init(gpa, bytes) catch null;
    engine_runner.setBoundsChecks(.auto);
    defer if (jit_explicit) |*je| je.deinit(gpa);

    stats.modules_compared += 1;

    for (jit.compiled.exports) |fe| {
        const name = fe.name;
        const sig = interp_inst.exportFuncSig(name) orelse continue;
        if (sig.params.len != 0 or sig.results.len != 1) continue;
        // Single scalar result of any number type. f32/f64 EXECUTION is a prime
        // interp-vs-JIT divergence source (rounding, NaN); the carrier-bit
        // compare is sound under canonicalize-nans. v128/ref results excluded
        // (the JIT invoke runs them via the uncompared void path).
        switch (std.meta.activeTag(sig.results[0])) {
            .i32, .i64, .f32, .f64 => {},
            else => continue,
        }

        interp_inst.setFuel(FUEL);
        armJit(&jit);
        if (jit_explicit) |*je| armJit(je);

        const io_out = interpInvoke(&interp_inst, name);
        const jo_auto = jitInvoke(&jit, gpa, name);
        const jo_expl: ?Outcome = if (jit_explicit) |*je| jitInvoke(je, gpa, name) else null;

        // Fuel on ANY engine: units differ (interp per-instruction, JIT
        // poll-site), so execution was cut at DIFFERENT points — this export is
        // incomparable AND the instances' memory states may now disagree, making
        // every later export on this module unsound to compare. Skip the module.
        const expl_fuel = if (jo_expl) |jo| jo == .fuel else false;
        if (io_out == .fuel or jo_auto == .fuel or expl_fuel) return;

        // SIMD execution is JIT-ONLY by design (the SIMD spec suite runs on
        // the JIT runner; the interp has no SIMD handlers). The interp traps
        // `unreachable_` at the first op it doesn't implement — SIMD etc. —
        // via the dispatch null-slot. A GENUINE `unreachable` instruction
        // traps on BOTH engines, so an interp `unreachable_` that the JIT
        // does NOT mirror means the interp bailed on an unimplemented op, not
        // a JIT miscompile → incomparable; and the interp bailed MID-BODY, so
        // its state diverged from the JIT lanes' → skip the module's rest too.
        // This is sound: a real JIT failure-to-trap-unreachable can't hide here
        // (the JIT implements `unreachable`).
        if (io_out == .trap and io_out.trap != null and io_out.trap.? == .unreachable_) {
            const jit_unreachable = jo_auto == .trap and jo_auto.trap != null and jo_auto.trap.? == .unreachable_;
            if (!jit_unreachable) return;
        }
        stats.funcs_compared += 1;

        const v_auto = try compareLane(stdout, module_name, name, "auto", io_out, jo_auto);
        var all_precise = v_auto == .ok_precise;
        var any_mismatch = v_auto == .mismatch;
        if (jo_expl) |jo| {
            const v_expl = try compareLane(stdout, module_name, name, "explicit", io_out, jo);
            all_precise = all_precise and v_expl == .ok_precise;
            any_mismatch = any_mismatch or v_expl == .mismatch;
        }
        if (any_mismatch) stats.mismatched += 1;

        if (all_precise) {
            // Deterministic execution + precise-matching outcomes pin the same
            // execution (and trap) point on every lane → the memory snapshots
            // must agree byte-for-byte. memory0 only (multi-memory is
            // symmetric: neither side's extra memories are read here).
            const interp_mem: []const u8 = if (interp_inst.memory()) |m| m.slice() else &.{};
            stats.mem_compared += 1;
            if (try compareMemory(stdout, module_name, name, "auto", interp_mem, jit.memoryBytes()))
                stats.mismatched += 1;
            if (jit_explicit) |*je| {
                if (try compareMemory(stdout, module_name, name, "explicit", interp_mem, je.memoryBytes()))
                    stats.mismatched += 1;
            }
        } else if (!any_mismatch) {
            // Lenient pass (incomparable trap kind on some lane): the engines
            // may have trapped at DIFFERENT points, so the memory states are
            // unverifiable and every later export inherits them → skip the
            // module's rest rather than compare on top of divergent state.
            return;
        }
    }
}

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

    var stats: Stats = .{};
    var n_dirs: u32 = 0;
    const cwd = std.Io.Dir.cwd();

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
            // Corpus dirs may carry a README documenting the fixtures' wat
            // sources; only `.wasm` entries are modules.
            if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;
            const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20)) catch continue;
            defer gpa.free(bytes);
            stats.processed += 1;
            try processModule(gpa, stdout, entry.name, bytes, &stats);
        }
    }

    if (n_dirs == 0) {
        try stdout.print("usage: zwasm-fuzz-exec <corpus-dir> [corpus-dir...]\n", .{});
        try stdout.flush();
        std.process.exit(2);
    }

    try stdout.print(
        "\nfuzz_exec: {d} processed, {d} modules compared, {d} funcs compared (auto+explicit lanes), {d} memory snapshots, {d} mismatched (interp-vs-JIT) — GATING\n",
        .{ stats.processed, stats.modules_compared, stats.funcs_compared, stats.mem_compared, stats.mismatched },
    );
    try stdout.flush();

    if (stats.processed == 0) {
        try stdout.print("error: empty corpus\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }
    // GATING: a value/trap/memory divergence between the interp and a JIT lane
    // on the same function is a real bug (a JIT-execute miscompile). The campaign
    // run validated the comparison (122 funcs, 0 mismatch), so any future
    // mismatch is a finding.
    if (stats.mismatched != 0) std.process.exit(1);
}
