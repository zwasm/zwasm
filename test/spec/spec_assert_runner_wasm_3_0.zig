//! Wasm 3.0 spec assertion runner (10.T-2b, JIT-executing since Phase 10).
//!
//! Sub-corpus selector for the Wasm 3.0 proposals (memory64 / multi-memory /
//! tail-call / exception-handling / gc / function-references): enumerates the
//! baked manifests under `<corpus-root>/<proposal>/<name>/manifest.txt` and
//! executes the assertions — assert_return / assert_trap / assert_invalid /
//! assert_unlinkable / assert_malformed / assert_exception — with real
//! pass/fail accounting, plus an opt-in JIT-return lane
//! (`ZWASM_SPEC_ENGINE=jit`) whose enumerated skips are the D-217
//! harness-shape gaps, not silent omissions.
//!
//! `zig build test-spec-wasm-3.0-assert` builds + runs it against the
//! committed corpus. A
//! missing corpus ROOT `exit(1)`s — the corpus is committed, so a
//! missing root is a real error, not a fresh-checkout state
//! (ADR-0174 no-silent-skip), matching the other assert runners.
//! (Per-proposal subdirs keep their finer "(no subdir)" tolerance.)
//!
//! Usage:
//!   spec_assert_runner_wasm_3_0 <corpus-root>
//!
//! Per ROADMAP §10 / 10.T-2b + Phase 10 design plan §4.6.

const std = @import("std");
const builtin = @import("builtin");

const manifest_parser = @import("wasm_3_0_manifest.zig");
const zwasm = @import("zwasm");
const TypedResult = zwasm.engine.runner.TypedResult;
const liveness_parity = zwasm.engine.codegen.shared.liveness_parity;

/// Widen a multi-value `TypedResult` slot to the u64 carrier
/// `jitScalarResultMatches` compares (i32/f32 zero-extended in the low 32).
fn typedResultBits(tr: TypedResult) u64 {
    return switch (tr) {
        inline else => |v| @as(u64, v),
    };
}

// 10.M-D195b cycle 75 — host stubs for the Wasm spec testsuite's
// `spectest.print*` conventional imports. The wast harness uses them
// for trace prints; semantically they're side-effect-only no-ops, so
// our binding ignores the args entirely (still pops them off the
// operand stack per the Wasm ABI).
fn spectestPrint(_: *zwasm.Caller) void {
    // no-op (trace print semantics)
}
fn spectestPrintI32(_: *zwasm.Caller, _: i32) void {
    // no-op (trace print semantics)
}
fn spectestPrintI64(_: *zwasm.Caller, _: i64) void {
    // no-op (trace print semantics)
}
fn spectestPrintF32(_: *zwasm.Caller, _: f32) void {
    // no-op (trace print semantics)
}
fn spectestPrintF64(_: *zwasm.Caller, _: f64) void {
    // no-op (trace print semantics)
}
fn spectestPrintI32F32(_: *zwasm.Caller, _: i32, _: f32) void {
    // no-op (trace print semantics)
}
fn spectestPrintF64F64(_: *zwasm.Caller, _: f64, _: f64) void {
    // no-op (trace print semantics)
}

// D-225 — read an exported global's value (as a u64 carrier) from a
// registered exporter instance's live global storage. `mod_name` is the
// register-`<as>` name (or `$id`); both alias into `name_to_idx`.
fn resolveExportedGlobal(
    instances_list: *const std.ArrayList(zwasm.Instance),
    name_to_idx: *const std.StringHashMap(usize),
    mod_name: []const u8,
    field: []const u8,
) ?u64 {
    const idx = name_to_idx.get(mod_name) orelse return null;
    if (idx >= instances_list.items.len) return null;
    const rt = instances_list.items[idx].handle.runtime orelse return null;
    for (instances_list.items[idx].handle.exports_storage) |exp| {
        if (exp.kind == .global and std.mem.eql(u8, exp.name, field)) {
            if (exp.idx >= rt.globals.len) return null;
            return rt.globals[exp.idx].bits64;
        }
    }
    return null;
}

// D-225 — resolve a JIT module's imported-global VALUES in global-import
// order, so the §1 JIT setup-time const-exprs (`global.get N`,
// N < num_global_imports) read the real value — e.g. gc/i31.3/4's
// `(ref.i31 (global.get $env.g))` resolves env.g=42 instead of a null slot.
// Returns a gpa-owned []u64 (empty if the module has no global imports).
fn jitResolveImportedGlobals(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    instances_list: *const std.ArrayList(zwasm.Instance),
    name_to_idx: *const std.StringHashMap(usize),
) ![]u64 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var module = zwasm.parse.parser.parse(a, wasm_bytes) catch return &.{};
    const imp_sec = module.find(.import) orelse return &.{};
    var imports = zwasm.parse.sections.decodeImports(a, imp_sec.body) catch return &.{};
    defer imports.deinit();

    var vals: std.ArrayList(u64) = .empty;
    errdefer vals.deinit(gpa);
    for (imports.items) |it| {
        if (it.kind != .global) continue;
        const v = resolveExportedGlobal(instances_list, name_to_idx, it.module, it.name) orelse 0;
        try vals.append(gpa, v);
    }
    return vals.toOwnedSlice(gpa);
}

// D-225 — resolve a JIT module's cross-module FUNC import targets in
// func-import order: for each `(import "M" "f" (func …))`, look up the
// registered exporter JitInstance "M" + its exported func "f" entry/rt.
// The importer setup emits a bridge thunk per resolved target into
// dispatch[N] so the cross-module call dispatches to the exporter (else
// hostDispatchTrap). Unresolved → zero target (slot stays trap). gpa-owned.
fn jitResolveFuncImports(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    jit_exporters: *const std.StringHashMap(*zwasm.engine.runner.JitInstance),
) ![]zwasm.engine.runner.FuncImportTarget {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var module = zwasm.parse.parser.parse(a, wasm_bytes) catch return &.{};
    const imp_sec = module.find(.import) orelse return &.{};
    var imports = zwasm.parse.sections.decodeImports(a, imp_sec.body) catch return &.{};
    defer imports.deinit();

    var targets: std.ArrayList(zwasm.engine.runner.FuncImportTarget) = .empty;
    errdefer targets.deinit(gpa);
    for (imports.items) |it| {
        if (it.kind != .func) continue;
        const t: zwasm.engine.runner.FuncImportTarget = blk: {
            const exp = jit_exporters.get(it.module) orelse break :blk .{};
            break :blk exp.exportedFuncTarget(gpa, it.name) orelse .{};
        };
        try targets.append(gpa, t);
    }
    return targets.toOwnedSlice(gpa);
}

// ADR-0134 D3 — resolve a JIT module's cross-module TAG import identities
// in tag-import order: for each `(import "M" "e" (tag …))`, look up the
// registered exporter JitInstance "M" + its exported tag "e" identity id.
// The importer's setup writes the id into its own `tag_ids[k]` so a
// cross-module throw and catch compare equal. Unresolved → zero
// (importer falls back to a local within-module identity). gpa-owned.
fn jitResolveTagImports(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    jit_exporters: *const std.StringHashMap(*zwasm.engine.runner.JitInstance),
) ![]zwasm.engine.runner.TagImportTarget {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var module = zwasm.parse.parser.parse(a, wasm_bytes) catch return &.{};
    const imp_sec = module.find(.import) orelse return &.{};
    var imports = zwasm.parse.sections.decodeImports(a, imp_sec.body) catch return &.{};
    defer imports.deinit();

    var targets: std.ArrayList(zwasm.engine.runner.TagImportTarget) = .empty;
    errdefer targets.deinit(gpa);
    for (imports.items) |it| {
        if (it.kind != .tag) continue;
        const t: zwasm.engine.runner.TagImportTarget = blk: {
            const exp = jit_exporters.get(it.module) orelse break :blk .{};
            break :blk exp.exportedTagTarget(gpa, it.name) orelse .{};
        };
        try targets.append(gpa, t);
    }
    return targets.toOwnedSlice(gpa);
}

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
};

const PROPOSALS = [_][]const u8{
    "memory64",
    "tail-call",
    "exception-handling",
    "gc",
    "function-references",
    // 10.M cycle 65 — multi-memory corpus. Treated as a sibling
    // proposal subdir under `wasm-3.0-assert/` because the upstream
    // fixtures live in `memory64/test/core/multi-memory/` (the
    // memory64 + multi-memory proposals are jointly tracked
    // upstream). Bundle 10.M-multi-memory exercises load/store
    // routing through MemArgExtra.memidx (cycle 64 substrate).
    "multi-memory",
};

/// One assertion category's tally. The runner's central invariant is
/// that this closes: every directive of the category reaches exactly one
/// of pass / fail / skip. Before ADR-0210 several arms had `continue`
/// paths that incremented none of them, so `total` silently exceeded
/// pass+fail and the difference had no name (73 assert_return directives
/// on the interp lane).
const KindTally = struct {
    total: u32 = 0,
    pass: u32 = 0,
    fail: u32 = 0,
    skip: u32 = 0,

    fn closes(self: KindTally) bool {
        return self.total == self.pass + self.fail + self.skip;
    }

    fn add(self: *KindTally, other: KindTally) void {
        self.total += other.total;
        self.pass += other.pass;
        self.fail += other.fail;
        self.skip += other.skip;
    }
};

const ProposalSummary = struct {
    name: []const u8,
    manifests: u32 = 0,
    /// ADR-0210 — the enumeration denominator: every non-blank manifest
    /// line seen. Externally re-derivable without running the runner:
    ///   cat <proposal>/*/manifest.txt | wc -l
    /// (the corpus is one directive per line, no blanks and no comments;
    /// `check_spec_manifest_shape.sh` pins that).
    lines: u32 = 0,
    // ---- non-assertion directives: executed, but carry no verdict ----
    modules: u32 = 0,
    registers: u32 = 0,
    invokes: u32 = 0,
    /// Manifest-level skip lines ONLY (`skip-impl` / `skip-validator` /
    /// `skip-runtime` / `skip-adr-<id>`). Pre-ADR-0210 this doubled as a
    /// dumping ground for per-assertion skips raised by the module /
    /// register / return / trap arms, which both double-counted (the
    /// assert kind had already been tallied) and made the printed
    /// `skip=` unattributable to any category.
    skips: u32 = 0,
    /// Parsed fine but named no kind the runner handles. Was `=> {}`:
    /// 95 `skip-adr-*` lines vanished here before the parser learned
    /// the kind, and any future corpus directive would too.
    unknown: u32 = 0,
    /// `parseLine` returned an error. Was `catch continue` — 3 corpus
    /// lines (1 over-wide result list + 2 spaced export names) were
    /// dropped before reaching the kind switch, so they were absent
    /// even from `asserts_return`.
    unparsed: u32 = 0,
    /// A sub-corpus the runner could not read at all (manifest read,
    /// engine init, or sub-dir open). NOT part of the line identity —
    /// it CANNOT be, because a manifest that never opened contributes
    /// zero to both sides of it. That is precisely why it needs its own
    /// counter and its own gate: the identity is invariant under
    /// "silently drop a whole manifest", so on its own it would certify
    /// a run that skipped thousands of assertions.
    manifest_errors: u32 = 0,
    // ---- assertion categories ----
    ret: KindTally = .{},
    trap: KindTally = .{},
    invalid: KindTally = .{},
    unlinkable: KindTally = .{},
    /// Split out of `trap` by ADR-0210. Merging the two made the printed
    /// `trap=2573` irreconcilable with the corpus's 2553 `assert_trap`
    /// lines (the 20 `assert_uninstantiable` lines were hiding in it).
    uninstantiable: KindTally = .{},
    malformed: KindTally = .{},
    exception: KindTally = .{},
    // §1 (ADR-0128) — JIT execution-mode tally for assert_return
    // (populated only when ZWASM_SPEC_ENGINE=jit). pass/fail are real JIT
    // outcomes; skip = a shape not yet wired through the JIT (see
    // jitReturnEligible). `total` mirrors `ret.total`, so this closes
    // against the same denominator the interp lane uses.
    jit_return: KindTally = .{},

    /// ADR-0210 — the whole point of the accounting: every line read from
    /// a manifest lands in exactly one bucket, and every assertion
    /// category resolves to pass / fail / skip. Both halves are checked;
    /// a false verdict fails the run rather than printing a number nobody
    /// can reconcile.
    fn closes(self: ProposalSummary) bool {
        const bucketed = self.modules + self.registers + self.invokes +
            self.skips + self.unknown + self.unparsed +
            self.ret.total + self.trap.total + self.invalid.total +
            self.unlinkable.total + self.uninstantiable.total +
            self.malformed.total + self.exception.total;
        if (bucketed != self.lines) return false;
        return self.ret.closes() and self.trap.closes() and
            self.invalid.closes() and self.unlinkable.closes() and
            self.uninstantiable.closes() and self.malformed.closes() and
            self.exception.closes();
    }
};

/// §1 (ADR-0128) — JIT execution-mode eligibility for an `assert_return`
/// directive. The first increment routes only the no-arg + single-i32-
/// result, same-module subset through the JIT entry (`runI32Export` →
/// `callI32NoArgs`). Everything else (args, i64/fp/v128 results, multi-
/// value, void side-effect, cross-module `$M::field`) is enumerated as a
/// JIT skip so the not-yet-supported set is tracked, not silently
/// dropped — the per-backend should_fail list of wasmtime's
/// `tests/wast.rs` pattern. Skips shrink as the general arg/result
/// dispatcher lands in follow-on cycles.
fn isScalarTy(ty: []const u8) bool {
    return std.mem.eql(u8, ty, "i32") or std.mem.eql(u8, ty, "i64") or
        std.mem.eql(u8, ty, "f32") or std.mem.eql(u8, ty, "f64");
}

/// A reference result type (arrayref / eqref / anyref / funcref / externref /
/// structref / i31ref / nullref / exnref). The JIT runs these for side effects
/// (uncompared, `:?`); the manifest spells them all `*ref`. D-222.
fn isRefResultTy(ty: []const u8) bool {
    return std.mem.endsWith(u8, ty, "ref");
}

fn jitReturnEligible(args_len: usize, results_len: usize, result_ty: []const u8, arg0_ty: []const u8, module_id_len: usize) bool {
    if (module_id_len != 0) return false; // cross-module `$M::field` not wired
    // 0..3 scalar args; result void / scalar / REF. Void + ref results are
    // eligible — they RUN for their side effects (store / global.set, or a
    // `new` doing `global.set (array.new …)`) so the persistent JitInstance
    // accumulates state for later asserts (D-214/D-222). A ref result isn't
    // compared (spec encodes it `:?`); the JIT runs it via the void path.
    // arg1 scalar-ness enforced downstream; non-scalar arg0 / v128 result /
    // 4+ args stay enumerated skips (D-217).
    if (args_len > 3) return false;
    if (args_len >= 1 and !isScalarTy(arg0_ty)) return false;
    // Multi-value (results_len > 1) is eligible count-wise; per-result
    // scalar-ness is checked at the call site against the full `d.results`
    // (this fn only sees results[0]). v128/ref multi-value defers there.
    if (results_len == 1 and !isScalarTy(result_ty) and !isRefResultTy(result_ty)) return false;
    return true;
}

/// Pack a parsed scalar arg `zwasm.Value` into the 64-bit carrier
/// `runScalar1Export` expects (i32/f32 in the low 32, i64/f64 the full
/// 64). null for a non-scalar type. ADR-0128 §1 single-arg dispatch.
fn scalarArgBits(zv: zwasm.Value, ty: []const u8) ?u64 {
    if (std.mem.eql(u8, ty, "i32")) return @as(u32, @bitCast(zv.i32));
    if (std.mem.eql(u8, ty, "i64")) return @as(u64, @bitCast(zv.i64));
    if (std.mem.eql(u8, ty, "f32")) return @as(u32, @bitCast(zv.f32));
    if (std.mem.eql(u8, ty, "f64")) return @as(u64, @bitCast(zv.f64));
    // D-226 — reftype args ride the u64 carrier (a ref is a u64 in a GPR; the
    // JIT entry passes it via the i64 path, see runner.paramScalarKey). null →
    // 0 (= null_ref). Lets `(invoke "init" (ref.extern 0))` populate the
    // ref.test/ref.cast tables under ZWASM_SPEC_ENGINE=jit.
    if (std.mem.eql(u8, ty, "externref")) return zv.externref orelse 0;
    if (std.mem.eql(u8, ty, "funcref")) return zv.funcref orelse 0;
    return null;
}

/// Compare a `runScalar1Export` carrier result against the expected value
/// per result type. FP uses an exact BIT compare (NaN-safe; the corpus
/// encodes FP results as literal bit patterns). ADR-0128 §1.
fn jitScalarResultMatches(ty: []const u8, got: u64, exp_zv: zwasm.Value) bool {
    if (std.mem.eql(u8, ty, "i64")) return @as(i64, @bitCast(got)) == exp_zv.i64;
    if (std.mem.eql(u8, ty, "f32")) return @as(u32, @truncate(got)) == @as(u32, @bitCast(exp_zv.f32));
    if (std.mem.eql(u8, ty, "f64")) return got == @as(u64, @bitCast(exp_zv.f64));
    return @as(i32, @bitCast(@as(u32, @truncate(got)))) == exp_zv.i32; // i32 default
}

/// §1 (ADR-0128) — classify a `runI32Export` error so the JIT RED signal
/// means "JIT executed and produced the wrong observable behaviour", not
/// "the JIT entry could not even attempt this shape". A compile- or setup-
/// stage rejection (multi-memory, an unemitted op, a const-expr/validate
/// gap) means the JIT never executed — that is a *skip*, structurally the
/// same as the args/i64/fp eligibility skips above (wasmtime tests/wast.rs
/// should_fail pattern), and is enumerated (printed under --fail-detail),
/// not silently dropped. Only an execution-stage outcome counts as a
/// *fail*: `error.Trap` (JIT ran and trapped where a value was expected)
/// or a value mismatch (handled at the comparison site, not here).
///
/// Empirical basis (2026-05-31 --fail-detail sweep, Mac aarch64): of the
/// 96 "JITfail"s, 87 were compile/setup rejections (66 MultipleMemories,
/// 11 UnsupportedOp, 4 InvalidFuncIndex, 3 InvalidGlobalInitExpr, 2
/// StackTypeMismatch, 1 ElemSegmentTypeMismatch) — the JIT never ran them.
/// `else => false` keeps `error.Trap` AND any unanticipated error as a
/// loud fail (a new gap must surface, never hide).
fn jitErrorIsUnwiredShape(e: zwasm.engine.runner.Error) bool {
    return switch (e) {
        error.MultipleMemories,
        error.UnsupportedOp,
        error.InvalidFuncIndex,
        error.InvalidGlobalInitExpr,
        error.StackTypeMismatch,
        error.ElemSegmentTypeMismatch,
        error.UnsupportedEntrySignature,
        error.ExportNotFound,
        error.ExportIsNotFunction,
        => true,
        else => false,
    };
}

/// ADR-0210 / ADR-0174 — the committed corpus's size, held in the binary so
/// that losing part of it is loud instead of arithmetic.
///
/// The identity the runner checks is invariant under "the corpus got
/// smaller": every remaining directive still lands in exactly one bucket, so
/// a corpus missing a whole manifest directory printed a smaller `lines=`,
/// `ACCOUNTING: CLOSED`, and exited 0 (measured 2026-09-02 by moving
/// `exception-handling/try_table` aside: `lines` 15478 → 15424, `exception`
/// 4 → 0, still green). `scripts/check_spec_manifest_shape.sh` does not close
/// it either — it checks the corpus's SHAPE and prints the total it finds,
/// with nothing to compare that total against.
///
/// Both numbers are re-derivable from outside the binary, which is the point:
///   find test/spec/wasm-3.0-assert -mindepth 3 -maxdepth 3 -name manifest.txt | wc -l
///   cat test/spec/wasm-3.0-assert/*/*/manifest.txt | wc -l
/// A corpus regen edits these two constants in the same commit as the corpus.
/// Same rule as `vendored_total` in `test/wasi/official_runner.zig`.
const corpus_manifests: u32 = 86;
const corpus_lines: u32 = 15478;

/// §1 (ADR-0128) — one KNOWN-WRONG JIT outcome, enumerated so the lane can
/// gate on `ret.fail` like every other category instead of exempting itself.
///
/// This list is NOT a suppression. It is the lane's claim about what is
/// broken, checked in both directions: an unlisted fail turns the run red,
/// and so does a listed one that stopped failing. Shrinking it is how the
/// underlying defect gets closed; growing it silently is what the exact
/// match prevents.
const JitKnownFail = struct {
    /// `<proposal>/<manifest-dir>/<export>` — the same triple the
    /// `--fail-detail` `JITval` / `JITfail` lines print, so a new fail can
    /// be turned into a row by copying it off the diagnostic output.
    key: []const u8,
    /// Failing DIRECTIVES for that export, not distinct exports: the corpus
    /// asserts `throw-catch-param-f32` twice (5.0 and 10.5) and both fail.
    /// A set keyed on the export alone would report 4 where there are 8 and
    /// would not notice one of the pair being fixed.
    count: u32,
};

/// x86_64 — measured 2026-09-02 on x86_64-linux, `ZWASM_SPEC_ENGINE=jit`.
///
/// These 8 are every f32/f64 `assert_return` directive in the
/// exception-handling corpus, and they are the ONLY float directives in it;
/// every non-float directive passes. The JIT returns a constant bit pattern
/// that does not depend on the argument (f32 → 0x66666666 for both the 5.0
/// and 10.5 cases, f64 → 0x4050066666666666 for both), so this is a wrong
/// value returned without an error — not a trap and not a refusal to
/// compile. The mechanism is NOT diagnosed here: the symptom is #378, and
/// this row exists so the lane can gate on everything else meanwhile.
///
/// Windows is x86_64 too but does NOT share this row — see below.
const jit_known_fail_x86_64_sysv: []const JitKnownFail = &.{
    .{ .key = "exception-handling/try_table/throw-catch-param-f32", .count = 2 },
    .{ .key = "exception-handling/try_table/throw-catch-param-f64", .count = 2 },
    .{ .key = "exception-handling/try_table/throw-catch_ref-param-f32", .count = 2 },
    .{ .key = "exception-handling/try_table/throw-catch_ref-param-f64", .count = 2 },
};

/// x86_64-windows — measured 2026-09-02 by this lane's own first CI run.
///
/// The same 8 float directives. A ninth row, `imported-mismatch` (a no-arg
/// `-> i32:3` assert, #379), stood here until #385: its `$imported-throw` is a
/// func import from the `register`ed "test" module, so the call crosses the
/// D-225 bridge thunk — which was SysV-only and handed the Win64 callee the
/// IMPORTER's runtime. The thrown tag then compared against the wrong
/// instance's identity and the inner `catch $e0` caught what `catch_all`
/// should have. Measured by this gate's own stale signal: `0 stale` on
/// main + #384, `1 stale` with the Cc-aware thunk. Keyed on the target and
/// not the arch for the same reason as before: the Win64 float rows are
/// theirs alone.
const jit_known_fail_x86_64_windows: []const JitKnownFail = &.{
    .{ .key = "exception-handling/try_table/throw-catch-param-f32", .count = 2 },
    .{ .key = "exception-handling/try_table/throw-catch-param-f64", .count = 2 },
    .{ .key = "exception-handling/try_table/throw-catch_ref-param-f32", .count = 2 },
    .{ .key = "exception-handling/try_table/throw-catch_ref-param-f64", .count = 2 },
};

/// aarch64 (the macOS leg) — measured 2026-09-02 by this lane's own first CI
/// run: `8 failed`, `4 enumerated, 0 unexpected, 0 stale`. The same 8
/// directives as the SysV x86_64 row, which is why the defect is not in
/// either backend's register allocator.
///
/// Written first as a prediction copied from x86_64 and left to be falsified,
/// rather than defaulted to empty: an empty row fails the leg with 8
/// unexpected entries and reports only that nobody had looked.
const jit_known_fail_aarch64: []const JitKnownFail = &.{
    .{ .key = "exception-handling/try_table/throw-catch-param-f32", .count = 2 },
    .{ .key = "exception-handling/try_table/throw-catch-param-f64", .count = 2 },
    .{ .key = "exception-handling/try_table/throw-catch_ref-param-f32", .count = 2 },
    .{ .key = "exception-handling/try_table/throw-catch_ref-param-f64", .count = 2 },
};

/// A target with no row expects ZERO JIT fails. That is the loud default: a
/// host nobody measured reports every fail as unexpected rather than
/// inheriting somebody else's excuse.
fn jitKnownFails() []const JitKnownFail {
    return switch (builtin.cpu.arch) {
        .x86_64 => if (builtin.os.tag == .windows)
            jit_known_fail_x86_64_windows
        else
            jit_known_fail_x86_64_sysv,
        .aarch64 => jit_known_fail_aarch64,
        else => &.{},
    };
}

/// Names the row in the diagnostics, so a mismatch says which list to edit.
const jit_target_label = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

/// Every JIT return-fail the run actually observed, one entry per failing
/// directive. Recorded at all three `jit_return.fail` sites so the gate sees
/// the same population the counter does.
const JitFailLog = struct {
    gpa: std.mem.Allocator,
    keys: std.ArrayList([]const u8) = .empty,

    fn record(self: *JitFailLog, proposal: []const u8, manifest: []const u8, func: []const u8) !void {
        // The manifest name is borrowed from a directory iterator whose
        // buffer is reused, so the key is copied rather than referenced.
        const key = try std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}", .{ proposal, manifest, func });
        errdefer self.gpa.free(key);
        try self.keys.append(self.gpa, key);
    }

    fn deinit(self: *JitFailLog) void {
        for (self.keys.items) |k| self.gpa.free(k);
        self.keys.deinit(self.gpa);
    }

    fn countFor(self: JitFailLog, key: []const u8) u32 {
        var n: u32 = 0;
        for (self.keys.items) |k| {
            if (std.mem.eql(u8, k, key)) n += 1;
        }
        return n;
    }
};

/// ADR-0226 — one module whose JIT compile the D-596 liveness parity check
/// (`ZWASM_DEBUG=liveverify`, `liveness_parity.check`) reports residuals
/// for, enumerated so the liveverify lane can gate on an exact match the way
/// `jitKnownFails` does.
///
/// Same contract as that list: NOT a suppression. A module no row names turns
/// the lane red, so does a listed one firing more than its row enumerates
/// (both `unexpected`), and so does one firing fewer (`stale`) — a fix lowers
/// or removes its row in the same PR. Every row has its line in #400's
/// table; a new drift lands as a row here AND a row there (ADR-0226 D4).
const LvKnown = struct {
    /// `<proposal>/<manifest-dir>/<module>.wasm` — the path the runner's
    /// `[liveverify] module …` line prints, so a new row is copied off the
    /// output. A `.wasm`, not a directive triple: residuals fire at compile
    /// time, before any directive runs.
    key: []const u8,
    /// Residual LINES for that module (one per `[liveverify] func[N] …`
    /// print on stderr), not distinct funcs: per row so "one func fixed,
    /// one regressed" in the same module is visible (ADR-0225's reason).
    count: u32,
};

/// x86_64 SysV — measured 2026-09-05 on x86_64-linux at `main` 7c7e434ea
/// (ADR-0226 D2), by this lane's red-first run with the table empty:
/// 69 residual lines over 10 modules, `0 enumerated, 10 unexpected`; CI's
/// Linux leg (run 33939200603, job 101233144116) then read the same ten
/// rows as `10 enumerated, 0 unexpected, 0 stale`. Each
/// row names its #400 table row; the funcs are the `func[N]` of its stderr
/// lines. #400's own module list was taken with #398 applied, so a module
/// (or func) absent from it is in #398's `.end` / `return` class by that
/// measurement: a row wholly of that class drops when #398 lands, a mixed
/// row's count falls — re-take the table then,
/// do not edit it by hand.
const lv_known_x86_64_sysv: []const LvKnown = &.{
    // `.end` ×20, `i32.add` ×4, `drop` ×1 over 17 funcs — #398's class.
    .{ .key = "memory64/br_table/br_table.0.wasm", .count = 25 },
    // `return` ×9 (funcs 8–15, 19) — #398's class.
    .{ .key = "exception-handling/try_table/try_table.1.wasm", .count = 9 },
    // #400 `br_on_cast` row (funcs 3, 4); funcs 5, 6 are #398's class.
    .{ .key = "gc/br_on_cast/br_on_cast.0.wasm", .count = 13 },
    // #400 `br_on_cast` row (func 1).
    .{ .key = "gc/br_on_cast/br_on_cast.1.wasm", .count = 1 },
    // #400 `br_on_cast_fail` row (funcs 2, 3); funcs 4–6 are #398's class.
    .{ .key = "gc/br_on_cast_fail/br_on_cast_fail.0.wasm", .count = 11 },
    // #400 `br_on_cast_fail` row (funcs 1, 2).
    .{ .key = "gc/br_on_cast_fail/br_on_cast_fail.1.wasm", .count = 2 },
    // #400 `br_on_null` / `br_on_non_null` row (funcs 0, 1, 6) — the traced mechanism.
    .{ .key = "function-references/br_on_non_null/br_on_non_null.0.wasm", .count = 3 },
    // `drop` ×3 (funcs 0–2), absent from #400's list — #398's class.
    .{ .key = "function-references/br_on_non_null/br_on_non_null.1.wasm", .count = 3 },
    // #400 `br_on_null` / `br_on_non_null` row (func 1).
    .{ .key = "function-references/br_on_non_null/br_on_non_null.2.wasm", .count = 1 },
    // #400 `br_on_null` / `br_on_non_null` row (func 1).
    .{ .key = "function-references/br_on_null/br_on_null.2.wasm", .count = 1 },
};

/// x86_64-windows — measured 2026-09-05 by this lane's own first CI run
/// (run 33939200603, job 101233144158; ADR-0226 D2), with the table empty:
/// `0 enumerated, 10 unexpected, 0 stale`. Written from that output, not
/// copied from SysV: the Win64 emit is not the SysV one, so a copied row
/// would have described nothing CI runs. That the rows came out identical
/// — same ten modules, same counts, on the Linux leg too — is itself the
/// measurement: the divergence is on the liveness side, which is
/// arch-independent, not in either emit. Per-row attribution as the SysV
/// table.
const lv_known_x86_64_windows: []const LvKnown = &.{
    .{ .key = "memory64/br_table/br_table.0.wasm", .count = 25 },
    .{ .key = "exception-handling/try_table/try_table.1.wasm", .count = 9 },
    .{ .key = "gc/br_on_cast/br_on_cast.0.wasm", .count = 13 },
    .{ .key = "gc/br_on_cast/br_on_cast.1.wasm", .count = 1 },
    .{ .key = "gc/br_on_cast_fail/br_on_cast_fail.0.wasm", .count = 11 },
    .{ .key = "gc/br_on_cast_fail/br_on_cast_fail.1.wasm", .count = 2 },
    .{ .key = "function-references/br_on_non_null/br_on_non_null.0.wasm", .count = 3 },
    .{ .key = "function-references/br_on_non_null/br_on_non_null.1.wasm", .count = 3 },
    .{ .key = "function-references/br_on_non_null/br_on_non_null.2.wasm", .count = 1 },
    .{ .key = "function-references/br_on_null/br_on_null.2.wasm", .count = 1 },
};

/// aarch64 (the macOS leg) — measured 2026-09-05 by the same first CI run
/// (job 101233144280), table empty: `0 enumerated, 10 unexpected, 0 stale`.
/// Identical to the two x86_64 tables, for the reason given above; a second
/// backend agreeing with the first against liveness is what rules the emit
/// out. Per-row attribution as the SysV table.
const lv_known_aarch64: []const LvKnown = &.{
    .{ .key = "memory64/br_table/br_table.0.wasm", .count = 25 },
    .{ .key = "exception-handling/try_table/try_table.1.wasm", .count = 9 },
    .{ .key = "gc/br_on_cast/br_on_cast.0.wasm", .count = 13 },
    .{ .key = "gc/br_on_cast/br_on_cast.1.wasm", .count = 1 },
    .{ .key = "gc/br_on_cast_fail/br_on_cast_fail.0.wasm", .count = 11 },
    .{ .key = "gc/br_on_cast_fail/br_on_cast_fail.1.wasm", .count = 2 },
    .{ .key = "function-references/br_on_non_null/br_on_non_null.0.wasm", .count = 3 },
    .{ .key = "function-references/br_on_non_null/br_on_non_null.1.wasm", .count = 3 },
    .{ .key = "function-references/br_on_non_null/br_on_non_null.2.wasm", .count = 1 },
    .{ .key = "function-references/br_on_null/br_on_null.2.wasm", .count = 1 },
};

comptime {
    // A duplicated key would be counted once by `countFor` and twice in
    // `enumerated`; the table would then claim more than it checks.
    for ([_][]const LvKnown{ lv_known_x86_64_sysv, lv_known_x86_64_windows, lv_known_aarch64 }) |table| {
        for (table, 0..) |a, i| {
            for (table[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.key, b.key)) {
                    @compileError("liveverify table lists '" ++ a.key ++ "' twice");
                }
            }
            // `record` is called only for n > 0 and `countFor` returns 0 when
            // absent, so a zero row matches whether the module fires or not:
            // it can never red the lane, and it inflates `enumerated`.
            if (a.count == 0) {
                @compileError("liveverify row '" ++ a.key ++ "' has count 0 — it can never fire; delete the row");
            }
        }
    }
}

/// Selected the way `jitKnownFails` selects, with the same loud default: a
/// target with no row expects ZERO residuals and reports every one it sees.
fn liveverifyKnown() []const LvKnown {
    return switch (builtin.cpu.arch) {
        .x86_64 => if (builtin.os.tag == .windows)
            lv_known_x86_64_windows
        else
            lv_known_x86_64_sysv,
        .aarch64 => lv_known_aarch64,
        else => &.{},
    };
}

/// Every module the liveverify run attributed residuals to, with the count.
/// One entry per module, not one per residual — the count is the row's unit
/// — which is the one shape difference from `JitFailLog`.
const LvLog = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { key: []const u8, count: u32 };

    fn record(self: *LvLog, proposal: []const u8, manifest: []const u8, module_path: []const u8, n: u32) !void {
        // The manifest name is borrowed from a directory iterator whose
        // buffer is reused, so the key is copied rather than referenced.
        const key = try std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}", .{ proposal, manifest, module_path });
        errdefer self.gpa.free(key);
        // A manifest that names the same module twice compiles it twice;
        // the row counts the module, so the second compile adds to it.
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.count += n;
                self.gpa.free(key);
                return;
            }
        }
        try self.entries.append(self.gpa, .{ .key = key, .count = n });
    }

    fn deinit(self: *LvLog) void {
        for (self.entries.items) |e| self.gpa.free(e.key);
        self.entries.deinit(self.gpa);
    }

    /// 0 when absent — a listed module that never fired is `stale`.
    fn countFor(self: LvLog, key: []const u8) u32 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.count;
        }
        return 0;
    }
};

/// Shared catch-classifier for the §1 JIT no-arg dispatch arms (i32 / i64 /
/// f32 / f64): compile/setup rejects → an enumerated skip (the JIT never
/// executed this shape), execution-stage outcomes (e.g. `error.Trap`) → fail.
/// One copy so every result-type arm classifies identically.
fn recordJitRunErr(
    e: zwasm.engine.runner.Error,
    summary: *ProposalSummary,
    jit_fail_log: *JitFailLog,
    fail_detail: bool,
    stdout: anytype,
    proposal: []const u8,
    ename: []const u8,
    fname: []const u8,
) !void {
    if (jitErrorIsUnwiredShape(e)) {
        summary.jit_return.skip += 1;
        if (fail_detail) try stdout.print("  JITskip [{s}/{s}] {s} (unwired shape: err={s})\n", .{ proposal, ename, fname, @errorName(e) });
    } else {
        summary.jit_return.fail += 1;
        try jit_fail_log.record(proposal, ename, fname);
        if (fail_detail) try stdout.print("  JITfail [{s}/{s}] {s} err={s}\n", .{ proposal, ename, fname, @errorName(e) });
    }
}

pub fn main(init: std.process.Init) !void {
    zwasm.support.dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));
    // ADR-0202 D5 — JIT-executes via base's bespoke non-guarded memory →
    // explicit bounds checks mandatory (binding-time soundness). D-515.
    zwasm.engine.runner.setBoundsChecks(.explicit);
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next() orelse return;
    const corpus_root = args.next() orelse {
        try stdout.print("usage: spec_assert_runner_wasm_3_0 <corpus-root> [--fail-detail]\n", .{});
        try stdout.flush();
        return;
    };
    // Per-assert FAIL detail (cycle 163 diagnostic infra). Emitted via
    // the buffered `stdout` (reliable) — NOT std.debug.print, which
    // under-reported vs the per-manifest breakdown in cyc161. Opt-in via
    // a `--fail-detail` arg; off by default so gate runs stay clean.
    // `zig build test-spec-wasm-3.0-assert` can't append argv to the run
    // step, so the env var form (ZWASM_SPEC_DETAIL=1) is the only way to
    // get per-assert detail through the build runner.
    const fail_detail = if (args.next()) |a|
        std.mem.eql(u8, a, "--fail-detail")
    else
        init.environ_map.get("ZWASM_SPEC_DETAIL") != null;

    // §1 (ADR-0128) — opt-in JIT execution mode. Default = interp, so
    // `zig build test-spec-wasm-3.0-assert` (and test-all) is unchanged.
    // `ZWASM_SPEC_ENGINE=jit` routes the no-arg-i32 assert_return subset
    // through the JIT entry (runI32Export) and reports jit pass/fail/skip
    // alongside the interp totals — the verification backbone that makes
    // "both backends" mechanically checkable. The JIT entry re-compiles
    // the module per call (runI32Export owns its own runtime). A
    // 2026-05-31 --fail-detail sweep settled the originally-suspected
    // "stale cross-directive state" worry: of 96 raw fails, ZERO were
    // state-dependent — 87 were compile/setup rejections (66 multi-memory,
    // 11 unemitted-op, + setup/validate gaps) now routed to
    // `jit_return_skip` by `jitErrorIsUnwiredShape`, leaving fail = JIT
    // actually executed and produced the wrong observable result (trap or
    // value mismatch). A shared-runtime state bridge was therefore dropped
    // as a zero-yield next chunk; the live lever is widening the
    // JIT-runnable shape set (see .dev/lessons + handover bundle).
    const jit_mode = if (init.environ_map.get("ZWASM_SPEC_ENGINE")) |v|
        std.mem.eql(u8, v, "jit")
    else
        false;
    // ADR-0226 — the liveverify lane: the jit lane run once more with the
    // D-596 parity check on. `ZWASM_DEBUG=liveverify` is set by the
    // `test-spec-wasm-3.0-assert-liveverify` build step and nowhere else.
    // The check fires only inside JIT compilation, so the mode is a property
    // of the jit lane: with the env unset, or on the interp lane, none of the
    // `lv_mode` branches run and the lane's output is what it is without them.
    const lv_mode = jit_mode and liveness_parity.on();
    // The gate below lives entirely inside `if (lv_mode)`, down to its summary
    // line, so a dark channel is not a quieter lane — it is this step exiting 0
    // having compared nothing, with no line saying so. `compiled_in` is false
    // in ReleaseFast / ReleaseSmall and `core_rs` takes `-Doptimize` above
    // Debug, so `zig build test-all -Doptimize=ReleaseFast` reaches it today.
    // The step asked for the channel; if it is not on, that is the failure.
    if (jit_mode and !lv_mode) {
        if (init.environ_map.get("ZWASM_DEBUG")) |v| {
            if (std.mem.indexOf(u8, v, "liveverify") != null) {
                try stdout.print(
                    "LIVEVERIFY-CHANNEL-DARK  ZWASM_DEBUG={s} asked for the channel and liveness_parity.on() is false (compiled_in={}, mode={s}) — this lane would have compared nothing and exited 0\n",
                    .{ v, liveness_parity.compiled_in, @tagName(builtin.mode) },
                );
                try stdout.flush();
                std.process.exit(1);
            }
        }
    }

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_root, .{}) catch |err| {
        // Committed corpus (wasm-3.0-assert) — a missing root is a real
        // error, not a fresh-checkout / pre-10.T state. FAIL loud so a
        // silent exit-0 can't mask a host-specific path-resolution gap
        // behind a green test-all (ADR-0174). Per-proposal subdirs below
        // keep their own finer-grained "(no subdir)" tolerance.
        try stdout.print("[wasm-3.0-assert] corpus root not found: {s} ({s}) — FAIL (committed corpus; missing root is a real error, ADR-0174)\n", .{ corpus_root, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer dir.close(io);

    // ADR-0210 — the grand total is the same shape as a per-proposal
    // summary, so the identity that is checked per proposal is checked
    // once more over the whole corpus by exactly the same code.
    var grand: ProposalSummary = .{ .name = "wasm-3.0-assert" };
    var mismatched_proposals: u32 = 0;
    // Populated only in jit mode (the interp arms never touch it), and read
    // once after the loop to check the observed fails against the enumerated
    // ones. Kept beside `grand` because it is the same kind of thing: state
    // the run accumulates and then has to reconcile before it may exit 0.
    var jit_fail_log: JitFailLog = .{ .gpa = gpa };
    defer jit_fail_log.deinit();
    // ADR-0226 — same kind of thing for the liveverify lane: one entry per
    // module the parity check reported on, reconciled against
    // `liveverifyKnown()` after the loop.
    var lv_log: LvLog = .{ .gpa = gpa };
    defer lv_log.deinit();

    for (PROPOSALS) |proposal| {
        var summary: ProposalSummary = .{ .name = proposal };

        // ADR-0210 — the fourth sibling of the swallow points below, and the
        // widest: dropping a PROPOSALS entry removes a whole proposal's
        // assertions from both sides of the identity, so the run still
        // printed `[gc] (no subdir; 0 manifests)` and `ACCOUNTING: CLOSED`
        // and exited 0. All six directories are committed (verified
        // 2026-08-15), so the Phase-10 build-out tolerance this message was
        // written for no longer has anything to tolerate — any failure to
        // open one is the ADR-0174 path-resolution class, exactly like the
        // corpus root above.
        var pdir = dir.openDir(io, proposal, .{ .iterate = true }) catch |err| {
            // Straight onto `grand`: this `continue` skips the accumulation
            // at the end of the loop, so an increment on `summary` would be
            // discarded — and would silently become a double count the day
            // someone moves the accumulation earlier.
            grand.manifest_errors += 1;
            try stdout.print("PROPOSAL-DIR-FAIL  {s}: {s} — a committed sub-corpus that cannot be opened is a real error, not 0 manifests\n", .{ proposal, @errorName(err) });
            continue;
        };
        defer pdir.close(io);

        var it = pdir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, "raw")) continue;

            const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.txt", .{entry.name});
            defer gpa.free(manifest_path);

            // ADR-0210 — the identity is invariant under "drop a whole
            // manifest": both `lines` and the buckets shrink by the same
            // amount, so a manifest that never opened still printed CLOSED
            // and exited 0. That is the failure mode ADR-0174 exists for
            // (the windows path-resolution class), and the corpus root
            // already FAILs loudly for it — a per-manifest read failure has
            // to as well, or the denominator only ever certifies the subset
            // the runner happened to reach.
            const manifest = pdir.readFileAlloc(io, manifest_path, gpa, .limited(1 << 20)) catch |err| {
                summary.manifest_errors += 1;
                try stdout.print("MANIFEST-READ-FAIL  {s}/{s}: {s}\n", .{ proposal, entry.name, @errorName(err) });
                continue;
            };
            defer gpa.free(manifest);

            summary.manifests += 1;
            // Per-manifest fail breakdown (cycle 160 diagnostic infra):
            // snapshot fail counters so the loop can attribute return/
            // trap fails to the specific sub-corpus manifest. Printed
            // below only when this manifest contributed > 0 fails — turns
            // the diffuse per-proposal totals into a targetable per-feature
            // map for the next cycle.
            const mf_ret_fail0 = summary.ret.fail;
            const mf_trap_fail0 = summary.trap.fail;
            // In jit mode the assert_return verdict lands in `jit_return`
            // (the interp path is bypassed), so `ret.fail` stays 0 for the
            // whole loop and the locator below never fired — a JIT
            // return-fail was counted in the totals with nothing naming the
            // manifest it came from unless `--fail-detail` was passed.
            // That was the originally-reported symptom, and closing the
            // accounting alone did not close it.
            const mf_jit_fail0 = summary.jit_return.fail;

            // Active module bytes for assert_return dispatch. A new
            // `module <path>` directive replaces the slice; the
            // sub-corpus dir owns the alloc (freed below).
            var cur_module_bytes: ?[]u8 = null;
            // D-225 — a registered JIT exporter's `JitInstance.wasm_bytes`
            // BORROWS cur_module_bytes; the importer's later module directive
            // would free it → exportedFuncTarget re-parses freed memory. So at
            // `register`, ownership of the exporter's bytes transfers here
            // (kept alive for the run); `cur_bytes_kept` stops the next module
            // directive from freeing them.
            var kept_bytes: std.ArrayList([]u8) = .empty;
            var cur_bytes_kept = false;
            // D-237 — when the LAST module's bytes were transferred to
            // kept_bytes, this defer must not free them again (the
            // kept_bytes defer below owns them).
            defer if (cur_module_bytes) |b| {
                if (!cur_bytes_kept) gpa.free(b);
            };
            defer {
                for (kept_bytes.items) |b| gpa.free(b);
                kept_bytes.deinit(gpa);
            }

            // §1 / D-214 — persistent per-module JIT runtime. Instantiated
            // once per `module` directive (jit mode only); every subsequent
            // invoke routes through it so memory.grow / stores / global.set
            // accumulate across asserts (vs the old recompile-per-assert that
            // lost cross-directive state). null = no module / JIT-compile rejected.
            // D-225 — cur_jit is heap-pinned (`?*JitInstance`): a registered
            // exporter's rt address is baked into importer bridge thunks, so
            // its JitInstance must NOT move. `jit_owned` owns every kept
            // (registered) instance (freed once at cleanup); `jit_exporters`
            // maps register-`<as>` name → ptr (non-owning). Non-registered
            // cur_jit is freed at the next module directive (as before).
            const JitInstanceT = zwasm.engine.runner.JitInstance;
            var cur_jit: ?*JitInstanceT = null;
            var cur_jit_kept = false;
            // §1 (ADR-0128) — set when a jit-mode `(invoke …)` setup action for
            // the current module could NOT run (non-scalar arg the JIT invoke
            // path can't pack — e.g. `(invoke "init" (ref.extern 0))` — or it
            // errored). Subsequent jit asserts read incompletely-initialised
            // state (empty tables → ref.test/ref.cast read null → wrong), so
            // they are enumerated SKIPs ("JIT couldn't attempt this shape"),
            // NOT fails. Reset per `.module`. Real fix = externref-arg invoke
            // support (D-NNN).
            var jit_setup_failed = false;
            var jit_owned: std.ArrayList(*JitInstanceT) = .empty;
            var jit_exporters: std.StringHashMap(*JitInstanceT) = std.StringHashMap(*JitInstanceT).init(gpa);
            // ADR-0134 D2 — the cross-instance EH registry is process-global;
            // each manifest fully owns its instances, so clear any stale
            // registrations from a prior manifest's error-path leak.
            zwasm.engine.runner.eh_registry.reset();
            defer {
                for (jit_owned.items) |p| {
                    zwasm.engine.runner.eh_registry.unregister(&p.owned.rt);
                    if (p.owned.thunk_arena) |a| if (a.bytes.len > 0)
                        zwasm.engine.runner.eh_registry.unregisterThunkArena(@intFromPtr(a.bytes.ptr));
                    p.deinit(gpa);
                    gpa.destroy(p);
                }
                jit_owned.deinit(gpa);
                jit_exporters.deinit();
            }
            defer if (cur_jit) |j| {
                if (!cur_jit_kept) {
                    zwasm.engine.runner.eh_registry.unregister(&j.owned.rt);
                    if (j.owned.thunk_arena) |a| if (a.bytes.len > 0)
                        zwasm.engine.runner.eh_registry.unregisterThunkArena(@intFromPtr(a.bytes.ptr));
                    j.deinit(gpa);
                    gpa.destroy(j);
                }
            };

            // 10.M-D195b cycle 71 — multi-instance lifetime for
            // cross-module `(register …)` support. Pre-cycle-71 each
            // `module` directive tore down the prior Engine/Module/
            // Linker/Instance and created fresh state. Cross-module
            // imports + Linker.defineMemory entries need shared
            // state across modules — so the runner now keeps a
            // single Engine + Linker per manifest, accumulating
            // Modules + Instances in arrays. Each instantiate
            // resolves against the cumulative Linker entries
            // (populated by prior `register <as>` directives).
            // Same class as the manifest read above: skipping the engine
            // drops every directive in this manifest from the denominator
            // as well as from the buckets, so the identity still closes.
            var cur_engine: zwasm.Engine = zwasm.Engine.init(gpa, .{}) catch |err| {
                summary.manifest_errors += 1;
                try stdout.print("MANIFEST-ENGINE-FAIL  {s}/{s}: {s}\n", .{ proposal, entry.name, @errorName(err) });
                continue;
            };
            defer cur_engine.deinit();
            var cur_linker: zwasm.Linker = zwasm.Linker.init(&cur_engine);
            defer cur_linker.deinit();
            var modules_list: std.ArrayList(zwasm.Module) = .empty;
            defer {
                for (modules_list.items) |*m| m.deinit();
                modules_list.deinit(gpa);
            }
            var instances_list: std.ArrayList(zwasm.Instance) = .empty;
            defer {
                for (instances_list.items) |*i| i.deinit();
                instances_list.deinit(gpa);
            }
            // The most-recently-instantiated index into `instances_list`,
            // or null when no module is currently active (compile /
            // instantiate failed).
            var cur_inst_idx: ?usize = null;
            // 10.M-D195b cycle 72 — name → instance-idx map. Keyed
            // by `$<id>` (from `module $<id> <path>` directives) AND
            // by `<as>` (from `register <as>` directives). Lets
            // tagged asserts (`$M::field`) dispatch to the registered
            // instance instead of the most-recent one.
            var name_to_idx: std.StringHashMap(usize) = std.StringHashMap(usize).init(gpa);
            defer name_to_idx.deinit();

            // 10.M-D195b cycle 74 — pre-register a synthetic
            // `spectest` module's memory before processing any
            // manifest directive. The Wasm spec testsuite expects
            // a host-provided `spectest` module with conventional
            // exports (memory, globals, table, print funcs); many
            // multi-memory fixtures (imports2/4, linking2, data0.3/5)
            // declare `(import "spectest" "memory" …)` and currently
            // fail with UnknownImport. This synth covers the memory
            // export only; globals / table / funcs land in cycle 75+
            // when fixtures surface the gap.
            //
            // Bytes: `(module (memory (export "memory") 1 2)
            //                 (global (export "global_i32") i32 i32.const 666)
            //                 (global (export "global_i64") i64 i64.const 666)
            //                 (global (export "global_f32") f32 f32.const 0)
            //                 (global (export "global_f64") f64 f64.const 0))`
            // Synth carries memory + 4 globals; covers the Wasm spec
            // testsuite's conventional `spectest` host module exports
            // that current corpus fixtures actually reference.
            //
            // Section layout (raw bytes; comments name section IDs):
            //  - magic + version (8 bytes)
            //  - memory section (id 5): 1 entry, flags=1 min=1 max=2
            //  - global section (id 6): 4 entries (i32/i64/f32/f64 = 666/666/0/0,
            //    all immutable per spec testsuite convention)
            //  - export section (id 7): 5 entries (memory + 4 globals)
            const spectest_bytes = [_]u8{
                0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
                // table section (id 4, before memory's id 5): 1 entry,
                // funcref (0x70), flags=1 (has max), min=10, max=20 — the
                // shape the spec's own `spectest` module exports.
                0x04, 0x05, 0x01, 0x70, 0x01, 0x0a, 0x14,
                // memory section: 1 entry, flags=1, min=1, max=2
                0x05,
                0x04, 0x01, 0x01, 0x01, 0x02,
                // global section: 4 entries (33 bytes content)
                //   each: valtype byte + mutable byte + init_expr + 0x0B end
                0x06, 0x21, 0x04,
                //   global 0: i32 (0x7F) const 0x9A 0x05 (666 LEB128) — immutable
                0x7f, 0x00, 0x41, 0x9a, 0x05, 0x0b,
                //   global 1: i64 (0x7E) const 0x9A 0x05 (666) — immutable
                0x7e, 0x00,
                0x42, 0x9a, 0x05, 0x0b,
                //   global 2: f32 (0x7D) const 0.0 — immutable
                0x7d, 0x00, 0x43, 0x00,
                0x00, 0x00, 0x00, 0x0b,
                //   global 3: f64 (0x7C) const 0.0 — immutable
                0x7c, 0x00, 0x44, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0b,
                // export section: 6 entries (70 bytes content)
                0x07, 0x46, 0x06,
                //   "table" table 0
                0x05, 't',  'a',  'b',  'l',
                'e',  0x01, 0x00,
                //   "memory" memory 0
                0x06, 'm',  'e',  'm',  'o',
                'r',  'y',  0x02, 0x00,
                //   "global_i32" global 0
                0x0a, 'g',  'l',  'o',
                'b',  'a',  'l',  '_',  'i',  '3',  '2',  0x03,
                0x00,
                //   "global_i64" global 1
                0x0a, 'g',  'l',  'o',  'b',  'a',  'l',
                '_',  'i',  '6',  '4',  0x03, 0x01,
                //   "global_f32" global 2
                0x0a, 'g',
                'l',  'o',  'b',  'a',  'l',  '_',  'f',  '3',
                '2',  0x03, 0x02,
                //   "global_f64" global 3
                0x0a, 'g',  'l',  'o',  'b',
                'a',  'l',  '_',  'f',  '6',  '4',  0x03, 0x03,
            };
            if (cur_engine.compile(&spectest_bytes)) |spectest_mod_compiled| {
                var spectest_mod = spectest_mod_compiled;
                if (modules_list.append(gpa, spectest_mod)) |_| {
                    const m_ptr = &modules_list.items[modules_list.items.len - 1];
                    if (cur_linker.instantiate(m_ptr, .{})) |inst| {
                        var inst_mut = inst;
                        if (instances_list.append(gpa, inst_mut)) |_| {
                            const inst_ptr = &instances_list.items[instances_list.items.len - 1];
                            if (inst_ptr.memory()) |mem| {
                                cur_linker.defineMemory("spectest", "memory", mem) catch {};
                            }
                            // Bound so `(import "spectest" "table" …)` resolves.
                            // Without it the runner reports its own missing host
                            // surface as the module failing to instantiate.
                            if (inst_ptr.handle.runtime) |rt| {
                                for (inst_ptr.handle.exports_storage) |exp| {
                                    if (exp.kind == .table) {
                                        cur_linker.defineTable("spectest", "table", rt.tables[exp.idx]) catch {};
                                    }
                                }
                            }
                            // 10.M-D195b cycle 77 — register the
                            // synth module's global exports under
                            // the `spectest` name so fixtures that
                            // declare `(import "spectest" "global_*"
                            // (global …))` resolve via findEntry.
                            cur_linker.defineGlobal("spectest", "global_i32", inst_ptr, "global_i32") catch {};
                            cur_linker.defineGlobal("spectest", "global_i64", inst_ptr, "global_i64") catch {};
                            cur_linker.defineGlobal("spectest", "global_f32", inst_ptr, "global_f32") catch {};
                            cur_linker.defineGlobal("spectest", "global_f64", inst_ptr, "global_f64") catch {};
                        } else |_| {
                            inst_mut.deinit();
                        }
                    } else |_| {
                        // spectest instantiate failure is non-fatal:
                        // fixtures that don't reference spectest still
                        // run; ones that do will fail UnknownImport.
                    }
                } else |_| {
                    spectest_mod.deinit();
                }
            } else |_| {
                // spectest compile failure is non-fatal — see above.
            }
            // 10.M-D195b cycle 75 — spectest.print* host funcs.
            // No-op semantics; defineFunc returning errors is also
            // non-fatal (fixtures that don't reference them still run).
            cur_linker.defineFunc("spectest", "print", fn (*zwasm.Caller) void, spectestPrint) catch {};
            cur_linker.defineFunc("spectest", "print_i32", fn (*zwasm.Caller, i32) void, spectestPrintI32) catch {};
            cur_linker.defineFunc("spectest", "print_i64", fn (*zwasm.Caller, i64) void, spectestPrintI64) catch {};
            cur_linker.defineFunc("spectest", "print_f32", fn (*zwasm.Caller, f32) void, spectestPrintF32) catch {};
            cur_linker.defineFunc("spectest", "print_f64", fn (*zwasm.Caller, f64) void, spectestPrintF64) catch {};
            cur_linker.defineFunc("spectest", "print_i32_f32", fn (*zwasm.Caller, i32, f32) void, spectestPrintI32F32) catch {};
            cur_linker.defineFunc("spectest", "print_f64_f64", fn (*zwasm.Caller, f64, f64) void, spectestPrintF64F64) catch {};

            // Sub-corpus dir (e.g. `tail-call/return_call/`) — both
            // the manifest AND the .wasm files it cites live here.
            var sub_dir = pdir.openDir(io, entry.name, .{}) catch |err| {
                summary.manifest_errors += 1;
                try stdout.print("MANIFEST-DIR-FAIL  {s}/{s}: {s}\n", .{ proposal, entry.name, @errorName(err) });
                continue;
            };
            defer sub_dir.close(io);

            var lines = std.mem.splitScalar(u8, manifest, '\n');
            while (lines.next()) |raw| {
                // Strip trailing CR (+ surrounding ws): a windowsmini checkout
                // gets the LF-committed manifests as CRLF (git autocrlf), so the
                // `\n`-split leaves a trailing `\r` on every line → `module_path`
                // ended in `\r` → readFileAlloc → error.BadPathName on Win64 →
                // EVERY wasm-3.0-assert module silently un-loaded (the ADR-0174
                // pass=0 anomaly). The other 4 runners (base/spec/wast/component)
                // already trim `" \r\t"`; the wasm-3.0 runner was the lone miss.
                const line = std.mem.trim(u8, raw, " \r\t");
                if (line.len == 0) continue;
                summary.lines += 1;
                var args_buf: [4]manifest_parser.TypedValue = undefined;
                // Corpus max is 8 (gc/type-subtyping's 8×i32 multi-value
                // `run`); a [4] buffer made that line OutOfRange, and the
                // `catch continue` below then erased it entirely.
                var results_buf: [16]manifest_parser.TypedValue = undefined;
                const d = manifest_parser.parseLine(line, &args_buf, &results_buf) catch |err| {
                    // ADR-0210 / ADR-0174 no-silent-skip: a manifest line the
                    // parser cannot read is a REAL gap in the harness, not an
                    // absent directive. Counted into the denominator and named
                    // on stdout so it cannot masquerade as "nothing was there".
                    summary.unparsed += 1;
                    try stdout.print("UNPARSED  {s}/{s}: {s} ({s})\n", .{ proposal, entry.name, line, @errorName(err) });
                    continue;
                };
                switch (d.kind) {
                    .module => {
                        summary.modules += 1;
                        if (cur_jit) |j| {
                            // Kept (registered) instances are owned by jit_owned;
                            // free only the transient ones here (D-225).
                            if (!cur_jit_kept) {
                                zwasm.engine.runner.eh_registry.unregister(&j.owned.rt);
                                if (j.owned.thunk_arena) |a| if (a.bytes.len > 0)
                                    zwasm.engine.runner.eh_registry.unregisterThunkArena(@intFromPtr(a.bytes.ptr));
                                j.deinit(gpa);
                                gpa.destroy(j);
                            }
                            cur_jit = null;
                        }
                        cur_jit_kept = false;
                        jit_setup_failed = false; // new module → fresh setup state
                        // Don't free bytes a registered exporter borrows (D-225);
                        // kept_bytes owns them now.
                        if (cur_module_bytes) |b| {
                            if (!cur_bytes_kept) gpa.free(b);
                        }
                        cur_bytes_kept = false;
                        cur_module_bytes = sub_dir.readFileAlloc(io, d.module_path, gpa, .limited(4 << 20)) catch |err| {
                            // ADR-0174 no-silent-skip: a manifest-referenced module
                            // .wasm that can't be read is a REAL error, not a skip —
                            // surfacing it roots-caused the windowsmini pass=0 anomaly
                            // (every module silently un-loaded → asserts un-evaluated).
                            // ADR-0210 — and it must GATE, which printing alone did
                            // not do. Every later assert for this module takes the
                            // `cur_module_bytes orelse` path and lands in `ret.skip` /
                            // `trap.skip`, so the identity closes and the run exits 0
                            // with hundreds of assertions quietly downgraded to skips.
                            // Counted with the other sub-corpus-level read failures,
                            // and on stdout so it sits in the same stream as the
                            // accounting it invalidates (std.debug.print goes to
                            // stderr, which the summary reader never sees).
                            summary.manifest_errors += 1;
                            try stdout.print("MODULE-READ-FAIL  {s}/{s}: {s} — later asserts for this module become skips\n", .{ proposal, d.module_path, @errorName(err) });
                            cur_module_bytes = null;
                            cur_inst_idx = null;
                            continue;
                        };
                        // §1 / D-214 — instantiate the persistent JIT runtime
                        // for this module (jit mode only). A compile/setup
                        // reject (multi-memory, unemitted op, …) leaves cur_jit
                        // null → asserts against it become enumerated skips.
                        if (jit_mode) {
                            // D-225 — resolve this module's imported-global
                            // VALUES (global-import order) from registered
                            // exporter instances, so setup-time const-exprs
                            // (gc/i31.3/4 `(ref.i31 (global.get $env.g))`)
                            // read the real value, not a null import slot.
                            const gvals = jitResolveImportedGlobals(gpa, cur_module_bytes.?, &instances_list, &name_to_idx) catch &.{};
                            defer if (gvals.len > 0) gpa.free(gvals);
                            // D-225 — resolve cross-module FUNC import targets
                            // from registered exporter JitInstances (bridge-thunk
                            // dispatch; else hostDispatchTrap → ref_func call-f traps).
                            const ftargets = jitResolveFuncImports(gpa, cur_module_bytes.?, &jit_exporters) catch &.{};
                            defer if (ftargets.len > 0) gpa.free(ftargets);
                            // Capture the module-reject cause (else this skip
                            // class is SILENT — see lesson
                            // 2026-06-02-spec-jit-skips-weight-by-root-cause).
                            // Heap-pinned (D-225): the rt address may be baked into
                            // a later importer's thunk if this module is registered.
                            // ADR-0134 D3 — resolve cross-module TAG import
                            // identities so a module-1 throw and a module-2 catch
                            // on the imported tag compare equal (the JIT analog of
                            // the interp's shared `*TagInstance`).
                            const ttargets = jitResolveTagImports(gpa, cur_module_bytes.?, &jit_exporters) catch &.{};
                            defer if (ttargets.len > 0) gpa.free(ttargets);
                            cur_jit = blk: {
                                const built = JitInstanceT.initLinked(gpa, cur_module_bytes.?, gvals, ftargets, ttargets, &.{}) catch |e| {
                                    if (fail_detail) try stdout.print("  JITmodrej [{s}/{s}] err={s}\n", .{ proposal, d.module_path, @errorName(e) });
                                    break :blk null;
                                };
                                const pp = gpa.create(JitInstanceT) catch {
                                    var tmp = built;
                                    tmp.deinit(gpa);
                                    break :blk null;
                                };
                                pp.* = built;
                                // ADR-0134 D2 — register the heap-pinned
                                // instance's rt for cross-instance unwind
                                // dispatch (stable address; unregistered
                                // at every free site below).
                                zwasm.engine.runner.eh_registry.register(&pp.owned.rt);
                                // D-238 / ADR-0185 (b) — register this instance's
                                // bridge-thunk arena range so the x86_64 EH sniff
                                // resolves a thunk-return frame across instances.
                                if (pp.owned.thunk_arena) |a| if (a.bytes.len > 0)
                                    zwasm.engine.runner.eh_registry.registerThunkArena(@intFromPtr(a.bytes.ptr), a.bytes.len);
                                break :blk pp;
                            };
                            // ADR-0226 D3 — attribute this module's residuals.
                            // Read here per module, and once more after the
                            // loop for what fired outside any compile, so a
                            // residual is carried into the next module's count,
                            // where it reds the
                            // lane as unexpected or stale, instead of being
                            // dropped. Read after `initLinked` whether or not it
                            // succeeded: the emit ran either way.
                            if (lv_mode) {
                                const n = liveness_parity.takeResiduals();
                                if (n > 0) {
                                    try stdout.print("[liveverify] module {s}/{s}/{s}: {d} residual line(s)\n", .{ proposal, entry.name, d.module_path, n });
                                    try lv_log.record(proposal, entry.name, d.module_path, n);
                                }
                            }
                        }
                        // 10.M-D195b cycle 71 — compile + instantiate
                        // against the shared engine + linker, then
                        // accumulate. Cross-module imports declared
                        // by the new module resolve against the
                        // linker's existing entries (populated by
                        // prior `register <as>` directives).
                        zwasm.diagnostic.clearDiag();
                        var compiled = cur_engine.compile(cur_module_bytes.?) catch |e| {
                            // ADR-0016 M3 — surface the attributed validate
                            // failure (op/offset/fn) instead of the bare
                            // CompileError tag (permanent replacement for
                            // the GC bring-up op-probe).
                            if (zwasm.diagnostic.lastDiagnostic()) |dg| {
                                switch (dg.location) {
                                    .validate => |v| std.debug.print("[wasm-3.0-assert] {s}/{s} compile FAIL: {s} — {s} [fn={d} off={d} op=0x{x}]\n", .{ proposal, d.module_path, @errorName(e), dg.message(), v.fn_idx, v.body_offset, v.opcode }),
                                    else => std.debug.print("[wasm-3.0-assert] {s}/{s} compile FAIL: {s} — {s}\n", .{ proposal, d.module_path, @errorName(e), dg.message() }),
                                }
                            } else {
                                std.debug.print("[wasm-3.0-assert] {s}/{s} compile FAIL: {s}\n", .{ proposal, d.module_path, @errorName(e) });
                            }
                            cur_inst_idx = null;
                            continue;
                        };
                        modules_list.append(gpa, compiled) catch {
                            compiled.deinit();
                            cur_inst_idx = null;
                            continue;
                        };
                        const m_ptr = &modules_list.items[modules_list.items.len - 1];
                        var inst = cur_linker.instantiate(m_ptr, .{}) catch |e| {
                            std.debug.print("[wasm-3.0-assert] {s}/{s} instantiate FAIL: {s}\n", .{ proposal, d.module_path, @errorName(e) });
                            cur_inst_idx = null;
                            continue;
                        };
                        instances_list.append(gpa, inst) catch {
                            inst.deinit();
                            cur_inst_idx = null;
                            continue;
                        };
                        cur_inst_idx = instances_list.items.len - 1;
                        // 10.M-D195b cycle 72 — register the new
                        // instance under its `$<id>` tag (when the
                        // wast bound a name via `(module $X …)`).
                        // Subsequent asserts can dispatch to this
                        // instance via `$X::field`.
                        if (d.module_id.len > 0) {
                            name_to_idx.put(d.module_id, cur_inst_idx.?) catch {};
                        }
                    },
                    .register => {
                        summary.registers += 1;
                        // 10.M-D195b cycle 71 — bind the most-recent
                        // instance's memory exports into the shared
                        // Linker under `<as>` so subsequent modules'
                        // `(import "<as>" "<name>" memory)` resolves
                        // via Linker.findEntry. Only memory exports
                        // wired this cycle (func/table/global cross-
                        // module imports are out of scope until a
                        // fixture surfaces the gap).
                        // No live instance to register — already counted as a
                        // `register` directive; adding to `skips` on top would
                        // double-count it against the denominator.
                        const idx = cur_inst_idx orelse continue;
                        const inst = &instances_list.items[idx];
                        const exports = inst.handle.exports_storage;
                        const inst_rt = inst.handle.runtime;
                        for (exports) |exp| {
                            switch (exp.kind) {
                                .memory => {
                                    // 10.M-D195b cycle 75 — bind each
                                    // memory export at its specific
                                    // memidx (was memory0 only). The
                                    // raw-bytes overload of defineMemory
                                    // indexes into rt.memories directly.
                                    if (inst_rt) |rt| {
                                        if (exp.idx < rt.memories.len) {
                                            // D-199 — share the live *MemoryInstance.
                                            cur_linker.defineMemoryInstance(d.func_name, exp.name, rt.memories[exp.idx]) catch {};
                                        }
                                    }
                                },
                                .func => {
                                    // 10.M-D195b cycle 74 — bind every
                                    // func export through the cross-
                                    // module thunk so the importer
                                    // resolves via `findEntry` and
                                    // dispatches into the source
                                    // instance's runtime.
                                    cur_linker.defineCrossModuleFunc(d.func_name, exp.name, inst, exp.name) catch {};
                                },
                                .global => {
                                    // 10.G cycle 165 — bind global exports
                                    // (mirrors the spectest pre-register +
                                    // Linker.defineGlobal alias). gc/i31.3
                                    // + i31.4 `(import "env" "g")` need this.
                                    cur_linker.defineGlobal(d.func_name, exp.name, inst, exp.name) catch {};
                                },
                                .table => {
                                    // D-201b — bind each table export
                                    // (refs aliased) so cross-module
                                    // imports + their elem writes share it.
                                    if (inst_rt) |rt| {
                                        if (exp.idx < rt.tables.len) {
                                            cur_linker.defineTable(d.func_name, exp.name, rt.tables[exp.idx]) catch {};
                                        }
                                    }
                                },
                            }
                        }
                        // 10.E-xmodule-tags cycle 116 — bind each EH tag
                        // export (from the parallel tag_exports side-table,
                        // since tags are absent from exports_storage) so an
                        // importer's `(import <as> <name> (tag …))` resolves
                        // via the Linker.
                        for (inst.handle.tag_exports) |te| {
                            cur_linker.defineCrossModuleTag(d.func_name, te.name, inst, te.tag_index) catch {};
                        }
                        // 10.M-D195b cycle 72 — also register the
                        // instance under the `<as>` name so tagged
                        // asserts (`<as>::field`) dispatch to it.
                        name_to_idx.put(d.func_name, idx) catch {};
                        // D-225 — keep this module's JIT side alive + pinned so a
                        // later importer's cross-module FUNC call can bridge-thunk
                        // to its exported func entry + rt. Append to jit_owned once
                        // (a module registered under multiple names is owned once).
                        if (cur_jit) |j| {
                            if (!cur_jit_kept) {
                                jit_owned.append(gpa, j) catch {};
                                cur_jit_kept = true;
                                // Transfer ownership of the bytes j.wasm_bytes
                                // borrows so they outlive the next module directive
                                // (exportedFuncTarget re-parses them). D-225.
                                if (cur_module_bytes) |b| {
                                    kept_bytes.append(gpa, b) catch {};
                                    cur_bytes_kept = true;
                                }
                            }
                            jit_exporters.put(d.func_name, j) catch {};
                        }
                    },
                    .assert_return => {
                        summary.ret.total += 1;
                        // §1 (ADR-0128) — JIT execution mode. The no-arg-i32
                        // same-module subset runs through the JIT entry and
                        // is compared; every other shape is a tracked skip.
                        // Bypasses the interp path entirely in jit mode (the
                        // re-compile-per-call path owns its own runtime).
                        if (jit_mode) {
                            // §1 / D-214 — route through the PERSISTENT per-module
                            // JitInstance so state (memory.grow / stores / global.set)
                            // accumulates across asserts. Exact BIT compare for FP
                            // (corpus encodes FP literally; no NaN-class matcher).
                            const elig = jitReturnEligible(
                                d.args_len,
                                d.results_len,
                                if (d.results_len == 1) d.results[0].ty else "",
                                if (d.args_len >= 1) d.args[0].ty else "",
                                d.module_id.len,
                            );
                            if (!elig) {
                                summary.jit_return.skip += 1;
                                if (fail_detail) try stdout.print("  JITskip [{s}/{s}] {s} (args={d} results={d} — scalar 0/1-arg only)\n", .{ proposal, entry.name, d.func_name, d.args_len, d.results_len });
                                continue;
                            }
                            const inst = if (cur_jit) |j| j else {
                                // module did not JIT-compile/instantiate → enumerated skip
                                summary.jit_return.skip += 1;
                                continue;
                            };
                            if (jit_setup_failed) {
                                // A prior setup `(invoke …)` couldn't run (non-scalar
                                // arg) → state incomplete → can't attempt → skip.
                                summary.jit_return.skip += 1;
                                if (fail_detail) try stdout.print("  JITskip [{s}/{s}] {s} (setup invoke unrun — non-scalar arg)\n", .{ proposal, entry.name, d.func_name });
                                continue;
                            }
                            // Pack scalar args into bit-carriers (declaration order).
                            var arg_bits: [4]u64 = undefined;
                            var args_ok = true;
                            var ai: u8 = 0;
                            while (ai < d.args_len) : (ai += 1) {
                                const tv = d.args[ai];
                                const rvv = manifest_parser.parsePayload(tv) catch {
                                    args_ok = false;
                                    break;
                                };
                                const zvv = manifest_parser.runtimeToZwasm(rvv, tv.ty);
                                arg_bits[ai] = scalarArgBits(zvv, tv.ty) orelse {
                                    args_ok = false;
                                    break;
                                };
                            }
                            if (!args_ok) {
                                summary.jit_return.skip += 1;
                                continue;
                            }
                            // Multi-value result — route through invokeMulti
                            // (ADR-0106 entry_buf buffer-write path). All results
                            // must be scalar to compare; v128/ref multi defers.
                            if (d.results_len > 1) {
                                var all_scalar = true;
                                for (d.results[0..d.results_len]) |rvt| {
                                    if (!isScalarTy(rvt.ty)) {
                                        all_scalar = false;
                                        break;
                                    }
                                }
                                if (!all_scalar) {
                                    summary.jit_return.skip += 1;
                                    if (fail_detail) try stdout.print("  JITskip [{s}/{s}] {s} (multi-value with non-scalar result)\n", .{ proposal, entry.name, d.func_name });
                                    continue;
                                }
                                var rbuf: [16]TypedResult = undefined;
                                inst.invokeMulti(gpa, d.func_name, arg_bits[0..d.args_len], rbuf[0..d.results_len]) catch |e| {
                                    try recordJitRunErr(e, &summary, &jit_fail_log, fail_detail, stdout, proposal, entry.name, d.func_name);
                                    continue;
                                };
                                var mv_match = true;
                                var mv_parse_ok = true;
                                for (d.results[0..d.results_len], 0..) |exp_tv, ri| {
                                    const exp_rv = manifest_parser.parsePayload(exp_tv) catch {
                                        mv_parse_ok = false;
                                        break;
                                    };
                                    const exp_zv = manifest_parser.runtimeToZwasm(exp_rv, exp_tv.ty);
                                    if (!jitScalarResultMatches(exp_tv.ty, typedResultBits(rbuf[ri]), exp_zv)) {
                                        mv_match = false;
                                        if (fail_detail) try stdout.print("  JITval [{s}/{s}] {s} result[{d}] ty={s} got=0x{x:0>16}\n", .{ proposal, entry.name, d.func_name, ri, exp_tv.ty, typedResultBits(rbuf[ri]) });
                                        break;
                                    }
                                }
                                if (!mv_parse_ok) {
                                    summary.jit_return.skip += 1;
                                } else if (mv_match) {
                                    summary.jit_return.pass += 1;
                                } else {
                                    summary.jit_return.fail += 1;
                                    try jit_fail_log.record(proposal, entry.name, d.func_name);
                                }
                                continue;
                            }
                            const got = inst.invoke(gpa, d.func_name, arg_bits[0..d.args_len]) catch |e| {
                                try recordJitRunErr(e, &summary, &jit_fail_log, fail_detail, stdout, proposal, entry.name, d.func_name);
                                continue;
                            };
                            // got == null ⇒ nothing to compare: a void result
                            // OR a REF result run for side effects (D-222). Pass
                            // = invoke ran without trapping; its side effect now
                            // persists for later asserts.
                            const got_val = got orelse {
                                summary.jit_return.pass += 1;
                                continue;
                            };
                            const exp_tv = d.results[0];
                            const exp_rv = manifest_parser.parsePayload(exp_tv) catch {
                                summary.jit_return.skip += 1;
                                continue;
                            };
                            const exp_zv = manifest_parser.runtimeToZwasm(exp_rv, exp_tv.ty);
                            if (jitScalarResultMatches(exp_tv.ty, got_val, exp_zv)) {
                                summary.jit_return.pass += 1;
                            } else {
                                summary.jit_return.fail += 1;
                                try jit_fail_log.record(proposal, entry.name, d.func_name);
                                if (fail_detail) try stdout.print("  JITval [{s}/{s}] {s} ty={s} got=0x{x:0>16}\n", .{ proposal, entry.name, d.func_name, exp_tv.ty, got_val });
                            }
                            continue;
                        }
                        // ADR-0210 — each of the four gates below is a real
                        // "the interp lane could not attempt this shape"
                        // outcome, i.e. a skip. They used to `continue` with no
                        // increment at all, which is how 73 assert_return
                        // directives ended up in neither pass, fail nor skip.
                        _ = cur_module_bytes orelse {
                            summary.ret.skip += 1;
                            if (fail_detail) try stdout.print("  SKIPret [{s}/{s}] {s} (no module in scope)\n", .{ proposal, entry.name, d.func_name });
                            continue;
                        };
                        // Build args slice (zwasm.Value); skip if any
                        // typed arg can't parse (e.g. v128 / refs not yet
                        // mapped). Skip BEFORE instance gate so unsupported
                        // shapes stay attributable regardless of setup state.
                        var call_args: [4]zwasm.Value = undefined;
                        var call_args_ok = true;
                        var ai: u8 = 0;
                        while (ai < d.args_len) : (ai += 1) {
                            const tv = d.args[ai];
                            const rv = manifest_parser.parsePayload(tv) catch {
                                call_args_ok = false;
                                break;
                            };
                            call_args[ai] = manifest_parser.runtimeToZwasm(rv, tv.ty);
                        }
                        if (!call_args_ok) {
                            summary.ret.skip += 1;
                            if (fail_detail) try stdout.print("  SKIPret [{s}/{s}] {s} (unparseable arg payload)\n", .{ proposal, entry.name, d.func_name });
                            continue;
                        }
                        // Multi-value defer (cycle-3 scope); void
                        // (0 results) handled inline below so the
                        // state-mutating call still runs.
                        if (d.results_len > 1) {
                            summary.ret.skip += 1;
                            if (fail_detail) try stdout.print("  SKIPret [{s}/{s}] {s} (multi-value: {d} results)\n", .{ proposal, entry.name, d.func_name, d.results_len });
                            continue;
                        }
                        // 10.M-D195b cycle 72 — tagged dispatch.
                        const idx_ret: usize = if (d.module_id.len > 0)
                            (name_to_idx.get(d.module_id) orelse {
                                summary.ret.fail += 1;
                                if (fail_detail) try stdout.print("  FAILdispatch [{s}/{s}] {s} id={s}\n", .{ proposal, entry.name, d.func_name, d.module_id });
                                continue;
                            })
                        else
                            (cur_inst_idx orelse {
                                // Setup failure earlier in this module block;
                                // count as fail since the assert couldn't
                                // be evaluated.
                                summary.ret.fail += 1;
                                if (fail_detail) try stdout.print("  FAILsetup [{s}/{s}] {s}\n", .{ proposal, entry.name, d.func_name });
                                continue;
                            });
                        const instance = &instances_list.items[idx_ret];
                        if (d.results_len == 0) {
                            // Void-result assert_return — invoke for
                            // side effects (store ops, table.set, etc.)
                            // so subsequent state-dependent directives
                            // see the mutation. Pass on clean return,
                            // fail on trap or setup error.
                            manifest_parser.invokeInstanceVoid(instance, d.func_name, call_args[0..d.args_len]) catch |e| {
                                summary.ret.fail += 1;
                                if (fail_detail) try stdout.print("  FAILvoid [{s}/{s}] {s} err={s}\n", .{ proposal, entry.name, d.func_name, @errorName(e) });
                                continue;
                            };
                            summary.ret.pass += 1;
                            continue;
                        }
                        const expected_tv = d.results[0];
                        const expected_rv = manifest_parser.parsePayload(expected_tv) catch {
                            summary.ret.skip += 1;
                            if (fail_detail) try stdout.print("  SKIPret [{s}/{s}] {s} (unparseable expected payload ty={s})\n", .{ proposal, entry.name, d.func_name, expected_tv.ty });
                            continue;
                        };
                        const got = manifest_parser.invokeInstance(instance, d.func_name, call_args[0..d.args_len]) catch |e| {
                            summary.ret.fail += 1;
                            if (fail_detail) try stdout.print("  FAILtrap [{s}/{s}] {s} err={s}\n", .{ proposal, entry.name, d.func_name, @errorName(e) });
                            continue;
                        };
                        const ty = expected_tv.ty;
                        const is_numeric = std.mem.eql(u8, ty, "i32") or std.mem.eql(u8, ty, "i64") or std.mem.eql(u8, ty, "f32") or std.mem.eql(u8, ty, "f64");
                        if (!is_numeric) {
                            // Ref-typed result (D-456). Switch on `got`'s ACTIVE tag
                            // (never cross-access a union field). Exactly comparable:
                            // an externref result (null or the `ref.extern N` host
                            // sentinel) and a NULL funcref. Non-null funcref identity +
                            // GC refs (anyref/structref/i31ref — collapsed to externref
                            // by runtimeToZwasm, no native variant) + v128 are not yet
                            // modelled → skip (not fail), so an uncomparable result
                            // never masquerades as a value bug.
                            const is_null = std.mem.eql(u8, expected_tv.payload, "null");
                            const verdict: ?bool = switch (got) {
                                .externref => |g| if (std.mem.eql(u8, ty, "externref"))
                                    (g == (if (is_null) null else expected_rv.ref))
                                else
                                    null,
                                .funcref => |g| if (is_null) (g == null) else null,
                                else => null,
                            };
                            if (verdict) |ok| {
                                if (ok) {
                                    summary.ret.pass += 1;
                                } else {
                                    summary.ret.fail += 1;
                                    if (fail_detail) try stdout.print("  FAILref [{s}/{s}] {s} ty={s} exp_null={}\n", .{ proposal, entry.name, d.func_name, ty, is_null });
                                }
                            } else {
                                // Uncomparable ref shape. Belongs to this
                                // assertion's own skip column — routing it to
                                // the shared `skips` also left `ret.total`
                                // incremented, double-counting it against the
                                // denominator.
                                summary.ret.skip += 1;
                                if (fail_detail) try stdout.print("  SKIPret [{s}/{s}] {s} (uncomparable ref result ty={s})\n", .{ proposal, entry.name, d.func_name, ty });
                            }
                            continue;
                        }
                        const expected_zv = manifest_parser.runtimeToZwasm(expected_rv, ty);
                        // Compare by the result type's discriminator (is_numeric ⇒ one of i32/i64/f32/f64).
                        const match = if (std.mem.eql(u8, ty, "i32")) got.i32 == expected_zv.i32 else if (std.mem.eql(u8, ty, "i64")) got.i64 == expected_zv.i64 else if (std.mem.eql(u8, ty, "f32")) got.f32 == expected_zv.f32 else got.f64 == expected_zv.f64;
                        if (match) summary.ret.pass += 1 else {
                            summary.ret.fail += 1;
                            if (fail_detail) {
                                if (std.mem.eql(u8, ty, "i32")) {
                                    try stdout.print("  FAILval [{s}/{s}] {s} exp={d} got={d} ty=i32\n", .{ proposal, entry.name, d.func_name, expected_zv.i32, got.i32 });
                                } else if (std.mem.eql(u8, ty, "i64")) {
                                    try stdout.print("  FAILval [{s}/{s}] {s} exp={d} got={d} ty=i64\n", .{ proposal, entry.name, d.func_name, expected_zv.i64, got.i64 });
                                } else {
                                    try stdout.print("  FAILval [{s}/{s}] {s} ty={s} (fp result)\n", .{ proposal, entry.name, d.func_name, ty });
                                }
                            }
                        }
                    },
                    .assert_trap => {
                        summary.trap.total += 1;
                        // §10 both-backends (D-233) — in jit_mode evaluate the
                        // trap on the JIT (cur_jit), NOT the interp instance
                        // (whose setup state the jit-mode `(invoke)` action never
                        // populates → stale → false "no trap"). Pack scalar args;
                        // an unwired shape (multi-param / module reject) → skip;
                        // any non-unwired Error → the func trapped → pass (mirrors
                        // invokeInstanceTrap "any InvokeError = trapped"); a normal
                        // return → fail (the expected trap did not fire).
                        if (jit_mode) {
                            const inst = if (cur_jit) |j| j else {
                                summary.trap.skip += 1;
                                continue;
                            };
                            if (jit_setup_failed) {
                                summary.trap.skip += 1;
                                continue;
                            }
                            var ab: [4]u64 = undefined;
                            var ab_ok = true;
                            var k: u8 = 0;
                            while (k < d.args_len) : (k += 1) {
                                const tv = d.args[k];
                                const rvv = manifest_parser.parsePayload(tv) catch {
                                    ab_ok = false;
                                    break;
                                };
                                const zvv = manifest_parser.runtimeToZwasm(rvv, tv.ty);
                                ab[k] = scalarArgBits(zvv, tv.ty) orelse {
                                    ab_ok = false;
                                    break;
                                };
                            }
                            if (!ab_ok) {
                                summary.trap.skip += 1;
                                continue;
                            }
                            _ = inst.invoke(gpa, d.func_name, ab[0..d.args_len]) catch |e| {
                                if (jitErrorIsUnwiredShape(e)) {
                                    summary.trap.skip += 1;
                                } else {
                                    summary.trap.pass += 1; // trapped = expected
                                }
                                continue;
                            };
                            summary.trap.fail += 1;
                            if (fail_detail) try stdout.print("  FAILtrapNoTrap [{s}/{s}] {s} (jit returned; expected trap)\n", .{ proposal, entry.name, d.func_name });
                            continue;
                        }
                        _ = cur_module_bytes orelse {
                            summary.trap.skip += 1;
                            if (fail_detail) try stdout.print("  SKIPtrap [{s}/{s}] {s} (no module in scope)\n", .{ proposal, entry.name, d.func_name });
                            continue;
                        };
                        // Build args (skip if any typed arg can't
                        // parse — same gate as assert_return).
                        var call_args: [4]zwasm.Value = undefined;
                        var call_args_ok = true;
                        var ai: u8 = 0;
                        while (ai < d.args_len) : (ai += 1) {
                            const tv = d.args[ai];
                            const rv = manifest_parser.parsePayload(tv) catch {
                                call_args_ok = false;
                                break;
                            };
                            call_args[ai] = manifest_parser.runtimeToZwasm(rv, tv.ty);
                        }
                        if (!call_args_ok) {
                            summary.trap.skip += 1;
                            if (fail_detail) try stdout.print("  SKIPtrap [{s}/{s}] {s} (unparseable arg payload)\n", .{ proposal, entry.name, d.func_name });
                            continue;
                        }
                        const idx_trap: usize = if (d.module_id.len > 0)
                            (name_to_idx.get(d.module_id) orelse {
                                summary.trap.fail += 1;
                                if (fail_detail) try stdout.print("  FAILtrapDispatch [{s}/{s}] {s} id={s}\n", .{ proposal, entry.name, d.func_name, d.module_id });
                                continue;
                            })
                        else
                            (cur_inst_idx orelse {
                                summary.trap.fail += 1;
                                if (fail_detail) try stdout.print("  FAILtrapSetup [{s}/{s}] {s}\n", .{ proposal, entry.name, d.func_name });
                                continue;
                            });
                        const instance = &instances_list.items[idx_trap];
                        // assert_trap directives carry no results
                        // section in the baked manifest — invokeInstanceTrap
                        // looks up sig.results.len internally. Any
                        // InvokeError counts as the expected trap;
                        // setup errors (compile/instantiate/sig
                        // lookup) propagate as RunError → counted as
                        // fail (the assert couldn't be evaluated).
                        const outcome = manifest_parser.invokeInstanceTrap(instance, d.func_name, call_args[0..d.args_len]) catch |e| {
                            summary.trap.fail += 1;
                            if (fail_detail) try stdout.print("  FAILtrapErr [{s}/{s}] {s} err={s}\n", .{ proposal, entry.name, d.func_name, @errorName(e) });
                            continue;
                        };
                        switch (outcome) {
                            .trapped => summary.trap.pass += 1,
                            .returned_normally => {
                                summary.trap.fail += 1;
                                if (fail_detail) try stdout.print("  FAILtrapNoTrap [{s}/{s}] {s} (returned normally; expected trap)\n", .{ proposal, entry.name, d.func_name });
                            },
                        }
                    },
                    .assert_invalid => {
                        summary.invalid.total += 1;
                        // Read the named .wasm sibling and try to
                        // compile it; rejection = pass, acceptance
                        // = fail. read errors / OOM = fail (the
                        // assert couldn't be evaluated).
                        const inv_bytes = sub_dir.readFileAlloc(io, d.module_path, gpa, .limited(4 << 20)) catch {
                            summary.invalid.fail += 1;
                            continue;
                        };
                        defer gpa.free(inv_bytes);
                        const outcome = manifest_parser.compileExpectInvalid(gpa, inv_bytes) catch {
                            summary.invalid.fail += 1;
                            continue;
                        };
                        switch (outcome) {
                            .rejected => summary.invalid.pass += 1,
                            .accepted => {
                                std.debug.print("[wasm-3.0-assert] {s}/{s} invalid-accepted (D-188 / D-195 — depends)\n", .{ proposal, d.module_path });
                                summary.invalid.fail += 1;
                            },
                        }
                    },
                    .assert_malformed => {
                        summary.malformed.total += 1;
                        const mal_bytes = sub_dir.readFileAlloc(io, d.module_path, gpa, .limited(4 << 20)) catch {
                            summary.malformed.fail += 1;
                            continue;
                        };
                        defer gpa.free(mal_bytes);
                        // compile bundles parse + validate today;
                        // spec-level distinction (parser-stage
                        // reject vs validator-stage reject) isn't
                        // surfaced by the c_api boundary. Any
                        // compile-side rejection counts as pass.
                        const outcome = manifest_parser.compileExpectInvalid(gpa, mal_bytes) catch {
                            summary.malformed.fail += 1;
                            continue;
                        };
                        switch (outcome) {
                            .rejected => summary.malformed.pass += 1,
                            .accepted => summary.malformed.fail += 1,
                        }
                    },
                    .assert_uninstantiable => {
                        // D-200 — the module compiles but TRAPS at
                        // instantiation (active data/elem OOB). Instantiate
                        // it against the current linker; PASS if
                        // instantiation fails. The partial active-segment
                        // writes to SHARED imported memory/table persist
                        // (D-199 shared memory + aliased table refs), which
                        // subsequent asserts depend on. Does NOT change the
                        // "current" instance (tagged asserts target the
                        // registered module).
                        summary.uninstantiable.total += 1;
                        const un_bytes = sub_dir.readFileAlloc(io, d.module_path, gpa, .limited(4 << 20)) catch {
                            summary.uninstantiable.fail += 1;
                            continue;
                        };
                        defer gpa.free(un_bytes);
                        zwasm.diagnostic.clearDiag();
                        var compiled = cur_engine.compile(un_bytes) catch {
                            // Rejected at compile — still did not
                            // instantiate; count pass (no side effects).
                            summary.uninstantiable.pass += 1;
                            continue;
                        };
                        modules_list.append(gpa, compiled) catch {
                            compiled.deinit();
                            summary.uninstantiable.fail += 1;
                            continue;
                        };
                        const m_ptr = &modules_list.items[modules_list.items.len - 1];
                        if (cur_linker.instantiate(m_ptr, .{})) |inst| {
                            var bad_inst = inst;
                            bad_inst.deinit();
                            summary.uninstantiable.fail += 1; // unexpectedly instantiated
                        } else |_| {
                            summary.uninstantiable.pass += 1; // failed as expected
                        }
                    },
                    .assert_unlinkable => {
                        // cyc193 (D-198 bundle) — the module is valid but
                        // fails to LINK (import type/kind/limits mismatch).
                        // Instantiate against the current linker; PASS if
                        // instantiation fails. Verifies the REJECT direction
                        // of cross-module import subtyping (cyc192
                        // funcTypeImportCompatible).
                        summary.unlinkable.total += 1;
                        const ul_bytes = sub_dir.readFileAlloc(io, d.module_path, gpa, .limited(4 << 20)) catch {
                            summary.unlinkable.fail += 1;
                            continue;
                        };
                        defer gpa.free(ul_bytes);
                        zwasm.diagnostic.clearDiag();
                        var compiled = cur_engine.compile(ul_bytes) catch {
                            // Rejected at compile — never linked; count pass.
                            summary.unlinkable.pass += 1;
                            continue;
                        };
                        modules_list.append(gpa, compiled) catch {
                            compiled.deinit();
                            summary.unlinkable.fail += 1;
                            continue;
                        };
                        const m_ptr = &modules_list.items[modules_list.items.len - 1];
                        if (cur_linker.instantiate(m_ptr, .{})) |inst| {
                            var bad_inst = inst;
                            bad_inst.deinit();
                            summary.unlinkable.fail += 1; // unexpectedly linked
                        } else |_| {
                            summary.unlinkable.pass += 1; // failed to link as expected
                        }
                    },
                    .assert_exception => {
                        // ASYMMETRY, deliberate and worth naming: unlike
                        // assert_return / assert_trap this arm has no jit
                        // branch, so under ZWASM_SPEC_ENGINE=jit it still
                        // evaluates the INTERP instance — whose state the
                        // jit-mode `.invoke` arm never drives (that arm
                        // routes setup through cur_jit and continues before
                        // invokeInstanceVoid). The printed row therefore
                        // carries `return=` as the engine-under-test's
                        // verdict next to `exception=`, which is interp-only
                        // in both lanes. All four corpus directives are
                        // stateless enough that nothing is hidden today; a
                        // future STATEFUL exception fixture would fail the
                        // jit lane for a harness reason and read as an
                        // engine defect. Give this arm a jit branch before
                        // adding one.
                        summary.exception.total += 1;
                        _ = cur_module_bytes orelse {
                            summary.exception.skip += 1;
                            if (fail_detail) try stdout.print("  SKIPexc [{s}/{s}] {s} (no module in scope)\n", .{ proposal, entry.name, d.func_name });
                            continue;
                        };
                        // Parse args (same gate as assert_return /
                        // assert_trap); v128 / refs skip.
                        var call_args: [4]zwasm.Value = undefined;
                        var call_args_ok = true;
                        var ai: u8 = 0;
                        while (ai < d.args_len) : (ai += 1) {
                            const tv = d.args[ai];
                            const rv = manifest_parser.parsePayload(tv) catch {
                                call_args_ok = false;
                                break;
                            };
                            call_args[ai] = manifest_parser.runtimeToZwasm(rv, tv.ty);
                        }
                        if (!call_args_ok) {
                            summary.exception.skip += 1;
                            if (fail_detail) try stdout.print("  SKIPexc [{s}/{s}] {s} (unparseable arg payload)\n", .{ proposal, entry.name, d.func_name });
                            continue;
                        }
                        const idx_exc: usize = if (d.module_id.len > 0)
                            (name_to_idx.get(d.module_id) orelse {
                                summary.exception.fail += 1;
                                continue;
                            })
                        else
                            (cur_inst_idx orelse {
                                summary.exception.fail += 1;
                                continue;
                            });
                        const instance = &instances_list.items[idx_exc];
                        const outcome = manifest_parser.invokeInstanceExpectException(instance, d.func_name, call_args[0..d.args_len]) catch {
                            summary.exception.fail += 1;
                            continue;
                        };
                        switch (outcome) {
                            .uncaught_exception => summary.exception.pass += 1,
                            .returned_normally, .other_trap => summary.exception.fail += 1,
                        }
                    },
                    .invoke => {
                        // Counted so it lands in the denominator; an action
                        // carries no expected outcome, so it has no tally.
                        summary.invokes += 1;
                        // D-191 — wast `(invoke "fn" args)` action.
                        // Side-effect driver for subsequent state-
                        // dependent asserts. Drop result silently
                        // (matches spec: an action by itself has
                        // no expected outcome other than non-trap).
                        // §1 / D-214 — in jit mode, drive the persistent
                        // JitInstance so the side effect persists for later
                        // JIT asserts (bypasses interp, like assert_return).
                        if (jit_mode) {
                            const inst = if (cur_jit) |j| j else continue;
                            var ab: [4]u64 = undefined;
                            var ab_ok = true;
                            var k: u8 = 0;
                            while (k < d.args_len) : (k += 1) {
                                const tv = d.args[k];
                                const rvv = manifest_parser.parsePayload(tv) catch {
                                    ab_ok = false;
                                    break;
                                };
                                const zvv = manifest_parser.runtimeToZwasm(rvv, tv.ty);
                                ab[k] = scalarArgBits(zvv, tv.ty) orelse {
                                    ab_ok = false;
                                    break;
                                };
                            }
                            // A setup action that can't pack its args (non-scalar,
                            // e.g. an externref host ref) or that errors leaves the
                            // module's state incomplete → mark so dependent jit
                            // asserts SKIP rather than read empty state and "fail".
                            if (ab_ok) {
                                _ = inst.invoke(gpa, d.func_name, ab[0..d.args_len]) catch {
                                    jit_setup_failed = true;
                                };
                            } else {
                                jit_setup_failed = true;
                            }
                            continue;
                        }
                        _ = cur_module_bytes orelse continue;
                        var call_args: [4]zwasm.Value = undefined;
                        var call_args_ok = true;
                        var ai: u8 = 0;
                        while (ai < d.args_len) : (ai += 1) {
                            const tv = d.args[ai];
                            const rv = manifest_parser.parsePayload(tv) catch {
                                call_args_ok = false;
                                break;
                            };
                            call_args[ai] = manifest_parser.runtimeToZwasm(rv, tv.ty);
                        }
                        if (!call_args_ok) continue;
                        const idx_inv: usize = if (d.module_id.len > 0)
                            (name_to_idx.get(d.module_id) orelse continue)
                        else
                            (cur_inst_idx orelse continue);
                        const instance = &instances_list.items[idx_inv];
                        // Failure is informational only — the action
                        // wasn't an assertion. Counters don't increment.
                        manifest_parser.invokeInstanceVoid(instance, d.func_name, call_args[0..d.args_len]) catch {};
                    },
                    .skip_impl, .skip_validator, .skip_runtime, .skip_adr => summary.skips += 1,
                    .unknown => {
                        // ADR-0210 — a directive the runner has no arm for is
                        // a harness gap, not an absence. Named on stdout so a
                        // future corpus regen that introduces a new directive
                        // cannot slip past as silently-executed-zero.
                        summary.unknown += 1;
                        try stdout.print("UNKNOWN-DIRECTIVE  {s}/{s}: {s}\n", .{ proposal, entry.name, line });
                    },
                }
            }
            const mf_ret_fail = summary.ret.fail - mf_ret_fail0;
            const mf_trap_fail = summary.trap.fail - mf_trap_fail0;
            const mf_jit_fail = summary.jit_return.fail - mf_jit_fail0;
            if (mf_ret_fail + mf_trap_fail + mf_jit_fail > 0) {
                try stdout.print("  [{s}/{s}] return_fail={d} trap_fail={d} jit_return_fail={d}\n", .{ proposal, entry.name, mf_ret_fail, mf_trap_fail, mf_jit_fail });
            }
        }

        // In jit mode the assert_return arm bypasses the interp path
        // entirely (every branch inside `if (jit_mode)` ends in `continue`),
        // so the verdict lives in `jit_return` and `ret` holds only the
        // denominator. Mirror it back: `ret` is "this category's verdict on
        // the engine under test", whichever engine that is, so the identity
        // is one rule rather than one rule per lane. Measured 2026-08-15:
        // without this the jit lane printed `return=11292(p=0 f=0 s=0)` and
        // the interp identity read OPEN for a reason that was an artifact of
        // the model, not a lost directive.
        if (jit_mode) {
            summary.jit_return.total = summary.ret.total;
            summary.ret.pass = summary.jit_return.pass;
            summary.ret.fail = summary.jit_return.fail;
            summary.ret.skip = summary.jit_return.skip;
        }
        try printProposal(stdout, proposal, summary, jit_mode);
        if (!summary.closes()) mismatched_proposals += 1;

        grand.manifests += summary.manifests;
        grand.lines += summary.lines;
        grand.modules += summary.modules;
        grand.registers += summary.registers;
        grand.invokes += summary.invokes;
        grand.skips += summary.skips;
        grand.unknown += summary.unknown;
        grand.unparsed += summary.unparsed;
        grand.manifest_errors += summary.manifest_errors;
        grand.ret.add(summary.ret);
        grand.trap.add(summary.trap);
        grand.invalid.add(summary.invalid);
        grand.unlinkable.add(summary.unlinkable);
        grand.uninstantiable.add(summary.uninstantiable);
        grand.malformed.add(summary.malformed);
        grand.exception.add(summary.exception);
        grand.jit_return.add(summary.jit_return);
    }

    // ADR-0210 — the runner walks the hard-coded `PROPOSALS` list, so a
    // corpus regen that adds a seventh proposal directory would raise the
    // on-disk line count while `lines=` stayed put and the run still
    // printed CLOSED. The identity certifies that everything ENUMERATED is
    // accounted for; this certifies that the enumeration covers the corpus.
    var unenumerated_dirs: u32 = 0;
    {
        // `dir` above is opened without `.iterate` (it is only ever used to
        // open per-proposal subdirs), so this needs its own handle.
        var root_iter_dir = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
            try stdout.print("[wasm-3.0-assert] corpus root not re-openable for the enumeration cross-check: {s}\n", .{@errorName(err)});
            try stdout.flush();
            std.process.exit(1);
        };
        defer root_iter_dir.close(io);
        var root_it = root_iter_dir.iterate();
        while (try root_it.next(io)) |e| {
            if (e.kind != .directory) continue;
            var known = false;
            for (PROPOSALS) |p| {
                if (std.mem.eql(u8, p, e.name)) known = true;
            }
            if (known) continue;
            unenumerated_dirs += 1;
            try stdout.print("UNENUMERATED-PROPOSAL  {s}: present on disk, absent from PROPOSALS — its directives are in no tally\n", .{e.name});
        }
    }

    try printProposal(stdout, "TOTAL", grand, jit_mode);
    if (jit_mode) {
        try stdout.print(
            "[wasm-3.0-assert] JIT execution mode (ADR-0128 §1): skip = JIT could not attempt this shape: eligibility-gated [args / v128 / multi-value / void / cross-module] OR compile/setup-rejected [multi-memory / unemitted-op / const-expr-or-validate gap, per jitErrorIsUnwiredShape]; fail = JIT executed and got the wrong observable result [trap or value mismatch]\n",
            .{},
        );
    }

    // ADR-0210 — the reconciliation. `lines` is the enumeration
    // denominator and is re-derivable without running this binary:
    //   cat test/spec/wasm-3.0-assert/*/*/manifest.txt | wc -l
    // Printing the identity term-by-term is what lets a third party check
    // the conformance numbers instead of taking them on trust.
    const bucketed = grand.modules + grand.registers + grand.invokes +
        grand.skips + grand.unknown + grand.unparsed +
        grand.ret.total + grand.trap.total + grand.invalid.total +
        grand.unlinkable.total + grand.uninstantiable.total +
        grand.malformed.total + grand.exception.total;
    try stdout.print(
        "[wasm-3.0-assert] RECONCILE: lines={d} = module {d} + register {d} + invoke {d} + skip {d} + unknown {d} + unparsed {d} + return {d} + trap {d} + invalid {d} + unlinkable {d} + uninstantiable {d} + malformed {d} + exception {d} => {d} [{s}]\n",
        .{ grand.lines, grand.modules, grand.registers, grand.invokes, grand.skips, grand.unknown, grand.unparsed, grand.ret.total, grand.trap.total, grand.invalid.total, grand.unlinkable.total, grand.uninstantiable.total, grand.malformed.total, grand.exception.total, bucketed, if (bucketed == grand.lines) "OK" else "MISMATCH" },
    );
    const closed = grand.closes() and mismatched_proposals == 0;
    try stdout.print(
        "[wasm-3.0-assert] ACCOUNTING: {s} ({d} proposal(s) failed the identity)\n",
        .{ if (closed) "CLOSED" else "OPEN", mismatched_proposals },
    );

    // The lane's own verdict line, in the same vocabulary as
    // `test/wasi/official_runner.zig` ("N passed, N failed, N total") so the
    // two conformance lanes cannot describe their coverage two different
    // ways. `skipped` is this lane's extra term: ADR-0128 keeps shapes like
    // multi-memory out of the JIT's scope, and a shape the engine could not
    // attempt is neither a pass nor a failure. It stays in the denominator.
    //
    // Printing the numbers rather than an OK/NG verdict is the ADR-0174
    // rule the RECONCILE line above already follows: a bare verdict is how a
    // lane with pass=0 hides behind a green step.
    const asserts_pass = grand.ret.pass + grand.trap.pass + grand.invalid.pass +
        grand.unlinkable.pass + grand.uninstantiable.pass + grand.malformed.pass +
        grand.exception.pass;
    const asserts_fail = grand.ret.fail + grand.trap.fail + grand.invalid.fail +
        grand.unlinkable.fail + grand.uninstantiable.fail + grand.malformed.fail +
        grand.exception.fail;
    const asserts_skip = grand.ret.skip + grand.trap.skip + grand.invalid.skip +
        grand.unlinkable.skip + grand.uninstantiable.skip + grand.malformed.skip +
        grand.exception.skip;
    const asserts_total = grand.ret.total + grand.trap.total + grand.invalid.total +
        grand.unlinkable.total + grand.uninstantiable.total + grand.malformed.total +
        grand.exception.total;
    try stdout.print(
        "wasm_3_0_assert [{s}]: {d} passed, {d} failed, {d} skipped, {d} total (over {d} proposals)\n",
        .{ if (jit_mode) "jit" else "interp", asserts_pass, asserts_fail, asserts_skip, asserts_total, PROPOSALS.len },
    );

    // Which engine produced the `passed` above is not what the label says.
    // `ZWASM_SPEC_ENGINE` routes exactly two categories — assert_return and
    // assert_trap — through `cur_jit`. Every other category builds against
    // `cur_engine`, and a `cur_engine` instance is the INTERPRETER (the arms
    // themselves say so: the assert_exception ASYMMETRY note names the interp
    // instance, and the jit `.invoke` arm routes setup through `cur_jit`
    // *instead of* it).
    //
    // So the interp lane's number needs no qualification — everything ran on
    // the interpreter — while the jit lane's does: 808 of its passes are
    // interpreter work sitting under a `[jit]` label. Split on passes, not
    // totals: a skip is nobody's coverage and already has its own column.
    if (jit_mode) {
        const jit_pass = grand.ret.pass + grand.trap.pass;
        const interp_pass = asserts_pass - jit_pass;
        try stdout.print(
            "wasm_3_0_assert [jit]: {d} of those passes came from the JIT, {d} from the interpreter (assert_invalid / unlinkable / uninstantiable / malformed build against cur_engine; assert_exception has no jit branch)\n",
            .{ jit_pass, interp_pass },
        );
    } else {
        try stdout.print(
            "wasm_3_0_assert [interp]: all {d} of those passes came from the interpreter\n",
            .{asserts_pass},
        );
    }

    // §1 (ADR-0128) — the JIT lane's exact-match gate. Both directions:
    //   unexpected — a fail with no row: a regression, or a host nobody
    //                measured. Red.
    //   stale      — a row whose fails stopped happening: the defect was
    //                fixed and the row is now suppressing nothing while
    //                claiming to. Red, so the list shrinks when the bug does.
    // This REPLACES the old `if (jit_mode) 0` exemption on `ret.fail`. Two
    // mechanisms for one job is how the wrong one wins, so there is one.
    var jit_unexpected: u32 = 0;
    var jit_stale: u32 = 0;
    if (jit_mode) {
        const known = jitKnownFails();
        for (known) |kf| {
            const seen = jit_fail_log.countFor(kf.key);
            if (seen == kf.count) continue;
            // Same split as the liveverify block below: a rise is a regression
            // on an enumerated key, not a row that stopped firing.
            if (seen > kf.count) {
                jit_unexpected += 1;
                try stdout.print(
                    "JIT-UNEXPECTED-FAIL  {s}: {d} failing directive(s) against the {d} its row enumerates — the JIT got more wrong here than the row claims\n",
                    .{ kf.key, seen, kf.count },
                );
                continue;
            }
            jit_stale += 1;
            try stdout.print(
                "JIT-EXPECTATION-STALE  {s}: enumerated {d} failing directive(s), observed {d} — the row over-claims; lower the {s} row in spec_assert_runner_wasm_3_0.zig\n",
                .{ kf.key, kf.count, seen, jit_target_label },
            );
        }
        for (jit_fail_log.keys.items) |k| {
            var listed = false;
            for (known) |kf| {
                if (std.mem.eql(u8, kf.key, k)) listed = true;
            }
            if (listed) continue;
            jit_unexpected += 1;
            try stdout.print(
                "JIT-UNEXPECTED-FAIL  {s}: the JIT executed this and got the wrong result, and no row enumerates it\n",
                .{k},
            );
        }
        try stdout.print(
            "[wasm-3.0-assert] JIT known-wrong ({s}): {d} enumerated, {d} unexpected, {d} stale\n",
            .{ jit_target_label, known.len, jit_unexpected, jit_stale },
        );
    }

    // ADR-0226 — the liveverify lane's exact-match gate, the block above in
    // its second instance, over the parity check's residuals per module.
    // Both directions for the same reasons; the failure text names the row
    // to edit, since a red of this kind is new to the lane.
    var lv_unexpected: u32 = 0;
    var lv_stale: u32 = 0;
    if (lv_mode) {
        const known = liveverifyKnown();
        for (known) |k| {
            const seen = lv_log.countFor(k.key);
            if (seen == k.count) continue;
            // A row can miss in two directions and they call for opposite work.
            // Fewer lines than enumerated is the ratchet: the row over-claims,
            // lower it. More is a divergence this list never saw, on a module
            // that happens to be listed — the same event as an unlisted module
            // firing, so it counts as that and the text says so.
            if (seen > k.count) {
                lv_unexpected += 1;
                try stdout.print(
                    "LIVEVERIFY-UNEXPECTED  {s}: {d} residual line(s) against the {d} its row enumerates — a new liveness/emit divergence on an enumerated module; fix it or add its funcs to #400 before the {s} row moves\n",
                    .{ k.key, seen, k.count, jit_target_label },
                );
                continue;
            }
            lv_stale += 1;
            try stdout.print(
                "LIVEVERIFY-EXPECTATION-STALE  {s}: enumerated {d} residual line(s), observed {d} — the row over-claims; lower the {s} row in spec_assert_runner_wasm_3_0.zig and retire its line on #400\n",
                .{ k.key, k.count, seen, jit_target_label },
            );
        }
        for (lv_log.entries.items) |e| {
            var listed = false;
            for (known) |k| {
                if (std.mem.eql(u8, k.key, e.key)) listed = true;
            }
            if (listed) continue;
            lv_unexpected += 1;
            try stdout.print(
                "LIVEVERIFY-UNEXPECTED  {s}: {d} residual line(s) and no row enumerates it — liveness and the emit diverge on this module; add the {s} row and a line on #400\n",
                .{ e.key, e.count, jit_target_label },
            );
        }
        // Residuals after the last module compile have no module to be
        // carried into; they would otherwise vanish.
        const stray = liveness_parity.takeResiduals();
        if (stray > 0) {
            lv_unexpected += 1;
            try stdout.print(
                "LIVEVERIFY-UNEXPECTED  (after the last module): {d} residual line(s) fired outside a module compile, so nothing could attribute them\n",
                .{stray},
            );
        }
        try stdout.print(
            "[wasm-3.0-assert] liveverify ({s}): {d} enumerated, {d} unexpected, {d} stale\n",
            .{ jit_target_label, known.len, lv_unexpected, lv_stale },
        );
    }
    try stdout.flush();

    // ADR-0174 — GATE on declarative-assert fails (close the "OK-verdict-hides-
    // pass=0" anomaly fully: the CRLF fix restored real windows coverage, but the
    // runner still always-exit-0'd, so a future real wasm-3.0 fail wouldn't turn
    // test-all red). The interp lane has 0 fails on all 3 hosts; the JIT lane's
    // known-wrong outcomes are enumerated in `jitKnownFails`, not exempted.
    // In jit mode `ret.fail` is the JIT verdict, and every one of those fails
    // is either enumerated above or already counted as unexpected — summing
    // it here as well would gate the same fail twice and make the enumerated
    // ones permanently red. The reconciliation IS the gate for this lane —
    // and the liveverify reconciliation joins it the same way (ADR-0226; its
    // two terms are 0 unless `lv_mode`).
    const ret_fail_unaccounted = if (jit_mode) jit_unexpected + jit_stale + lv_unexpected + lv_stale else grand.ret.fail;
    const grand_assert_fail = ret_fail_unaccounted + grand.trap.fail +
        grand.invalid.fail + grand.unlinkable.fail + grand.uninstantiable.fail +
        grand.malformed.fail + grand.exception.fail;
    // ADR-0210 — an unclosed identity gates too. A conformance number
    // computed from a tally that does not account for its own denominator
    // is worse than no number: it reads as authoritative and isn't.
    // NOTE: `unparsed` / `unknown` are NOT themselves gated — they are
    // named on stdout and counted into the denominator, so they stay
    // visible without turning a harness gap into a spec-failure claim.
    // A sub-corpus the runner never read is invisible to the identity, so
    // it gates separately. Same reasoning as ADR-0174's missing-corpus-root
    // FAIL: the corpus is COMMITTED, so failing to open part of it is a
    // real error, never a fresh-checkout state.
    if (grand.manifest_errors > 0) {
        try stdout.print("[wasm-3.0-assert] {d} sub-corpora could not be read — the printed denominator covers only what was reachable\n", .{grand.manifest_errors});
        try stdout.flush();
    }
    // A corpus that shrank is not a smaller conformance result, it is a
    // missing one — and unlike the buckets above it cannot be detected from
    // inside the tally, which closes just as happily over a fraction.
    const partial = grand.manifests != corpus_manifests or grand.lines != corpus_lines;
    if (partial) {
        try stdout.print(
            "[wasm-3.0-assert] PARTIAL CORPUS: read {d} manifests / {d} lines, committed corpus is {d} / {d}\n" ++
                "      these counts are not a conformance result. The corpus is committed —\n" ++
                "      a missing part is a checkout or path-resolution failure, not a fresh tree.\n",
            .{ grand.manifests, grand.lines, corpus_manifests, corpus_lines },
        );
        try stdout.flush();
    }
    if (grand_assert_fail > 0 or !closed or grand.manifest_errors > 0 or unenumerated_dirs > 0 or partial) std.process.exit(1);
}

/// One assertion category: `<name>=<total>(p=… f=… s=…)`. The total is
/// printed next to its parts so `total == p+f+s` is checkable by eye on
/// the same line the runner checks it in code.
fn printTally(stdout: *std.Io.Writer, name: []const u8, t: KindTally) !void {
    try stdout.print(" | {s}={d}(p={d} f={d} s={d})", .{ name, t.total, t.pass, t.fail, t.skip });
}

/// ADR-0210 — one printer for a proposal row and for the grand total, so
/// the two can never drift into reporting different shapes. Every
/// assertion category prints its own denominator and its own skip column;
/// `unlinkable` and `uninstantiable` had no column at all before, which
/// is how 30 + 20 directives stayed invisible per proposal.
fn printProposal(
    stdout: *std.Io.Writer,
    label: []const u8,
    s: ProposalSummary,
    jit_mode: bool,
) !void {
    try stdout.print(
        "[{s:<22}] manifests={d:<3} lines={d:<5} | module={d:<3} register={d:<2} invoke={d:<3} skip={d:<3} unknown={d:<2} unparsed={d:<2} manifest_err={d:<2}",
        .{ label, s.manifests, s.lines, s.modules, s.registers, s.invokes, s.skips, s.unknown, s.unparsed, s.manifest_errors },
    );
    try printTally(stdout, "return", s.ret);
    try printTally(stdout, "trap", s.trap);
    try printTally(stdout, "invalid", s.invalid);
    try printTally(stdout, "unlinkable", s.unlinkable);
    try printTally(stdout, "uninst", s.uninstantiable);
    try printTally(stdout, "malformed", s.malformed);
    try printTally(stdout, "exception", s.exception);
    try stdout.print(" | {s}\n", .{if (s.closes()) "CLOSED" else "OPEN"});
    if (jit_mode) {
        try stdout.print(
            "[{s:<22}]   JIT: return={d} (pass={d} fail={d} skip={d}) [{s}]\n",
            .{ label, s.jit_return.total, s.jit_return.pass, s.jit_return.fail, s.jit_return.skip, if (s.jit_return.closes()) "CLOSED" else "OPEN" },
        );
    }
}

test "ADR-0210: a category that loses a directive fails its own tally" {
    // The property the whole accounting rests on: a directive that reaches
    // neither pass, fail nor skip must be detectable. Before ADR-0210 the
    // assert_return arm had four such paths and nothing noticed.
    try std.testing.expect((KindTally{ .total = 3, .pass = 1, .fail = 1, .skip = 1 }).closes());
    try std.testing.expect(!(KindTally{ .total = 3, .pass = 1, .fail = 1, .skip = 0 }).closes());
    // Over-counting is a failure too: it is how a skip routed to the shared
    // `skips` bucket used to be tallied twice against the denominator.
    try std.testing.expect(!(KindTally{ .total = 2, .pass = 1, .fail = 1, .skip = 1 }).closes());
}

test "ADR-0210: the summary identity catches an unbucketed line" {
    var s: ProposalSummary = .{ .name = "t" };
    s.lines = 10;
    s.modules = 2;
    s.registers = 1;
    s.invokes = 1;
    s.skips = 1;
    s.ret = .{ .total = 5, .pass = 3, .fail = 1, .skip = 1 };
    try std.testing.expect(s.closes());

    // An 11th line read but bucketed nowhere — exactly the shape of the
    // `catch continue` / `=> {}` drops (unparsed lines, unknown kinds).
    s.lines = 11;
    try std.testing.expect(!s.closes());

    // ...and naming it restores the identity. `unparsed` / `unknown` are
    // real buckets, not an excuse to stop counting.
    s.unparsed = 1;
    try std.testing.expect(s.closes());

    // A per-category hole must fail even when the line total balances.
    s.ret.skip = 0;
    s.skips = 2;
    try std.testing.expect(!s.closes());
}

test "wasm-3.0-assert: PROPOSALS list matches design plan §3.1-§3.5 + §4.6 + 10.M extension" {
    // 10.M cycle 65 (`1e88350f`) added "multi-memory" as the 6th
    // entry; the upstream proposal lives at memory64/test/core/
    // multi-memory/ (jointly tracked with memory64). ROADMAP §10
    // row 10.M explicitly names multi-memory in scope, so this is
    // a 10.M extension of the original 5-proposal design plan, not
    // a §4/§9 scope deviation needing an ADR (per §18 routine
    // additions to the test-infrastructure layer).
    try std.testing.expectEqual(@as(usize, 6), PROPOSALS.len);
    try std.testing.expectEqualStrings("memory64", PROPOSALS[0]);
    try std.testing.expectEqualStrings("tail-call", PROPOSALS[1]);
    try std.testing.expectEqualStrings("exception-handling", PROPOSALS[2]);
    try std.testing.expectEqualStrings("gc", PROPOSALS[3]);
    try std.testing.expectEqualStrings("function-references", PROPOSALS[4]);
    try std.testing.expectEqualStrings("multi-memory", PROPOSALS[5]);
}

test "wasm-3.0-assert §1: JIT execution-mode eligibility + no-arg i32/i64/f32/f64 JIT invoke (ADR-0128 §1)" {
    // §1 dispatcher increment — no-arg + single-result, same-module, with
    // result type ∈ {i32, i64, f32, f64} wired through the JIT. Scalars use
    // exact BIT comparison (correct for NaN bit patterns, which the corpus
    // encodes literally — `nan:canonical`/`nan:arithmetic` tokens are absent
    // from the wasm-3.0 result set, so no class matcher is needed). args /
    // multi-value / cross-module remain enumerated skips.
    try std.testing.expect(jitReturnEligible(0, 1, "i32", "", 0)); // no-arg wired
    try std.testing.expect(jitReturnEligible(0, 1, "i64", "", 0)); // no-arg wired
    try std.testing.expect(jitReturnEligible(0, 1, "f32", "", 0)); // no-arg wired
    try std.testing.expect(jitReturnEligible(0, 1, "f64", "", 0)); // no-arg wired
    try std.testing.expect(jitReturnEligible(1, 1, "i32", "i32", 0)); // single-scalar-arg wired
    try std.testing.expect(jitReturnEligible(1, 1, "i64", "f64", 0)); // single-scalar-arg wired
    try std.testing.expect(jitReturnEligible(0, 0, "", "", 0)); // void no-arg (state side-effect runs)
    try std.testing.expect(jitReturnEligible(1, 0, "", "i32", 0)); // void single-scalar-arg (store)
    try std.testing.expect(jitReturnEligible(2, 1, "i32", "i32", 0)); // 2-scalar-arg wired (D-217)
    try std.testing.expect(jitReturnEligible(2, 0, "", "i64", 0)); // 2-arg void store (D-217)
    try std.testing.expect(!jitReturnEligible(1, 1, "i32", "v128", 0)); // non-scalar arg0
    try std.testing.expect(jitReturnEligible(3, 1, "i32", "i32", 0)); // 3-scalar-arg wired (D-217)
    try std.testing.expect(!jitReturnEligible(4, 1, "i32", "i32", 0)); // 4-arg (future)
    try std.testing.expect(jitReturnEligible(0, 2, "i32", "", 0)); // multi-value eligible count-wise (per-result scalar check at call site)
    try std.testing.expect(!jitReturnEligible(0, 1, "v128", "", 0)); // v128 result (later)
    try std.testing.expect(!jitReturnEligible(0, 1, "i32", "", 3)); // cross-module ($M::field)

    // End-to-end: the no-arg i32 export executes THROUGH the JIT entry
    // (runI32Export → callI32NoArgs), not the interpreter. Hand-built
    // `(module (func (export "seven") (result i32) i32.const 7))`.
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> i32
        0x03, 0x02, 0x01, 0x00, // func: typeidx 0
        0x07, 0x09, 0x01, 0x05, 0x73, 0x65, 0x76, 0x65, 0x6e, 0x00, 0x00, // export "seven" func 0
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x07, 0x0b, // code: i32.const 7; end
    };
    const got = try zwasm.engine.runner.runI32Export(std.testing.allocator, &wasm, "seven");
    try std.testing.expectEqual(@as(u32, 7), got);

    // End-to-end i64: exercises the full 64-bit width via `i64.const -1`
    // (all-ones) so an i32-only path would mis-marshal. Hand-built
    // `(module (func (export "big") (result i64) i64.const -1))`.
    const wasm64 = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7e, // type: () -> i64
        0x03, 0x02, 0x01, 0x00, // func: typeidx 0
        0x07, 0x07, 0x01, 0x03, 0x62, 0x69, 0x67, 0x00, 0x00, // export "big" func 0
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x42, 0x7f, 0x0b, // code: i64.const -1; end
    };
    const got64 = try zwasm.engine.runner.runI64Export(std.testing.allocator, &wasm64, "big");
    try std.testing.expectEqual(@as(i64, -1), @as(i64, @bitCast(got64)));

    // End-to-end f32: the result is a canonical NaN bit pattern
    // (`0x7fc00000`). Comparing BITS (not float `==`, which is false for
    // NaN) is what makes the JIT FP path correct. Hand-built
    // `(module (func (export "qnan") (result f32) f32.const <0x7fc00000>))`.
    const wasm_f32 = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7d, // type: () -> f32
        0x03, 0x02, 0x01, 0x00, // func: typeidx 0
        0x07, 0x08, 0x01, 0x04, 0x71, 0x6e, 0x61, 0x6e, 0x00, 0x00, // export "qnan" func 0
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x43, 0x00, 0x00, 0xc0, 0x7f, 0x0b, // f32.const 0x7fc00000; end
    };
    const got_f32 = try zwasm.engine.runner.runF32Export(std.testing.allocator, &wasm_f32, "qnan");
    try std.testing.expectEqual(@as(u32, 0x7fc00000), @as(u32, @bitCast(got_f32)));

    // End-to-end f64: `f64.const 2.5` (bits 0x4004000000000000). Hand-built
    // `(module (func (export "two_half") (result f64) f64.const 2.5))`.
    const wasm_f64 = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7c, // type: () -> f64
        0x03, 0x02, 0x01, 0x00, // func: typeidx 0
        0x07, 0x0c, 0x01, 0x08, 0x74, 0x77, 0x6f, 0x5f, 0x68, 0x61, 0x6c, 0x66, 0x00, 0x00, // export "two_half" func 0
        0x0a, 0x0d, 0x01, 0x0b, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x40, 0x0b, // f64.const 2.5; end
    };
    const got_f64 = try zwasm.engine.runner.runF64Export(std.testing.allocator, &wasm_f64, "two_half");
    try std.testing.expectEqual(@as(u64, 0x4004000000000000), @as(u64, @bitCast(got_f64)));
}

test "wasm-3.0-assert §1: JIT error classification — unwired-shape → skip, executed-wrong → fail (ADR-0128 §1)" {
    // Compile/setup-stage rejections (the JIT never executed) classify as
    // skip — structurally the same as the args/i64/fp eligibility skips,
    // enumerated not silently dropped. Empirically these are 87 of the 96
    // raw fails (66 multi-memory + 11 unemitted-op + setup/validate gaps).
    try std.testing.expect(jitErrorIsUnwiredShape(error.MultipleMemories));
    try std.testing.expect(jitErrorIsUnwiredShape(error.UnsupportedOp));
    try std.testing.expect(jitErrorIsUnwiredShape(error.InvalidFuncIndex));
    try std.testing.expect(jitErrorIsUnwiredShape(error.InvalidGlobalInitExpr));
    try std.testing.expect(jitErrorIsUnwiredShape(error.StackTypeMismatch));
    try std.testing.expect(jitErrorIsUnwiredShape(error.ElemSegmentTypeMismatch));
    try std.testing.expect(jitErrorIsUnwiredShape(error.UnsupportedEntrySignature));
    try std.testing.expect(jitErrorIsUnwiredShape(error.ExportNotFound));

    // Execution-stage outcome = the JIT ran and produced the wrong
    // observable behaviour → genuine fail (the meaningful both-backends
    // RED signal). `error.Trap` and any unanticipated error stay fail.
    try std.testing.expect(!jitErrorIsUnwiredShape(error.Trap));
}

test "ADR-0226: LvLog sums a module's residuals and reports 0 for one that never fired" {
    // `record`'s accumulate branch has no counterpart in `JitFailLog` (which
    // stores one entry per fail), and both halves of the exact-match gate
    // read through it: a module counted twice would red the lane as a false
    // regression, and an absent key returning anything but 0 would hide a
    // stale row.
    var log: LvLog = .{ .gpa = std.testing.allocator };
    defer log.deinit();

    try log.record("gc", "br_on_cast", "br_on_cast.0.wasm", 4);
    try log.record("gc", "br_on_cast", "br_on_cast.0.wasm", 9);
    try log.record("gc", "br_on_cast", "br_on_cast.1.wasm", 1);

    try std.testing.expectEqual(@as(usize, 2), log.entries.items.len);
    try std.testing.expectEqual(@as(u32, 13), log.countFor("gc/br_on_cast/br_on_cast.0.wasm"));
    try std.testing.expectEqual(@as(u32, 1), log.countFor("gc/br_on_cast/br_on_cast.1.wasm"));
    try std.testing.expectEqual(@as(u32, 0), log.countFor("gc/br_on_cast/br_on_cast.2.wasm"));
}
