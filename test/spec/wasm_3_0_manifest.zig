//! Wasm 3.0 spec assertion manifest parser (10.E spec corpus
//! runner foundation; first cycle of the planned bundle).
//!
//! The wasm-3.0-assert corpus (10.T-2a) bakes per-proposal
//! sub-directories with a `manifest.txt` per `.wast` source. Each
//! line is one directive:
//!
//!   module <path>
//!   assert_return <funcname> [<typed-arg>...] -> [<typed-result>...]
//!   assert_trap <funcname> [<typed-arg>...]
//!   assert_exception <funcname> [<typed-arg>...]
//!   assert_invalid <wasm-path>
//!   assert_malformed <wasm-path>
//!   skip-impl <reason>
//!   skip-validator <reason>
//!   skip-runtime <reason>
//!
//! Typed args + results use the shape `<wasm-type>:<decimal>`:
//!   i32:42, i64:18446744073709551612, f32:1165172736 (bit
//!   pattern), f64:4634211053438658150 (bit pattern). Empty
//!   result `()` means void; multi-value return is the rare
//!   `( v1 v2 ... )` shape (post-1.0 multi-value proposal — out
//!   of scope this cycle; will land alongside the test runner
//!   when needed).
//!
//! This file lands the parser only (no execution dispatch yet).
//! The future spec_assert_runner_wasm_3_0.zig consumer will:
//!   (1) iterate manifests under corpus_root,
//!   (2) call `parseLine` on each line to get a Directive,
//!   (3) dispatch each Directive against cli_run.runWasmCaptured
//!       (assert_return / assert_trap) or the relevant validator
//!       hook (assert_invalid / assert_malformed) etc.
//!
//! Zone 3 test-tree helper (`test/spec/`) — may import any Zone.

const std = @import("std");

const runtime = @import("zwasm").runtime;

pub const TypedValue = struct {
    /// "i32" / "i64" / "f32" / "f64". v128 / refs land when a
    /// fixture in the corpus requires them.
    ty: []const u8,
    /// Raw decimal payload after the colon. Caller parses to the
    /// target type — `parseLine` keeps the slice borrowed from
    /// the input line so the parser stays alloc-free.
    payload: []const u8,
};

pub const Kind = enum {
    module,
    /// D-191 — wast `(invoke "fn" args)` action directive between
    /// asserts; drives state mutation for subsequent state-dependent
    /// assertions. Carries args + func_name; no results section.
    invoke,
    assert_return,
    assert_trap,
    assert_exception,
    assert_invalid,
    assert_malformed,
    /// D-200 — module compiles but traps at instantiation; the runner
    /// instantiates it (expecting failure) so partial active-segment
    /// writes to shared imported memory/table persist.
    assert_uninstantiable,
    /// cyc193 (D-198 bundle) — module fails to LINK (import type/kind
    /// mismatch). The runner instantiates against the linker; PASS if
    /// instantiation fails. Verifies the REJECT direction of cross-
    /// module import subtyping (cyc192 funcTypeImportCompatible).
    assert_unlinkable,
    /// 10.M-D195b cycle 70 — wast `(register "name" $module_id?)`
    /// directive. The most-recent instance gets registered under
    /// `name` so subsequent modules' imports can resolve through
    /// the spec runner's per-name registry. `func_name` carries the
    /// registered-as name; binding wiring lands in subsequent
    /// cycles (cycle 71: memory imports; cycle 72: func + invoke
    /// dispatch routing).
    register,
    skip_impl,
    skip_validator,
    skip_runtime,
    /// `skip-adr-<ADR-id> <reason>` — waived per the named ADR. The
    /// wasm-3.0 corpus carries 95 of these (all
    /// `skip-adr-skip_text_format_parser`); before they had a kind
    /// they fell through to `.unknown`, which the runner's switch
    /// dropped with no counter — 95 directives absent from every
    /// tally AND from the printed denominator.
    skip_adr,
    unknown,
};

pub const Directive = struct {
    kind: Kind,
    /// `module <path>` → the wasm path (basename relative to
    /// the manifest dir). `assert_invalid` / `assert_malformed`
    /// → the wasm path. Else empty.
    module_path: []const u8 = "",
    /// Function name for assert_return / assert_trap /
    /// assert_exception. Empty otherwise.
    func_name: []const u8 = "",
    /// `skip-*` reason (the substring after the first space).
    reason: []const u8 = "",
    /// 10.M-D195b cycle 72 — optional module tag. Set for:
    ///   - `.module $<id> <path>` directives (the wast `(module $X …)`
    ///     name-binding form); the runner stores the instance under
    ///     this name in its registry.
    ///   - assert / invoke directives whose action targets a tagged
    ///     module (`$X::field` syntax); the runner dispatches the
    ///     call to the registered `$X` instance instead of the
    ///     most-recent one.
    /// Empty when not present.
    module_id: []const u8 = "",
    /// Caller stages args + results into these arrays. Parser
    /// writes by index up to the slice length; returns
    /// `OutOfRange` if more typed tokens appear than fit. The
    /// `*_len` fields name the populated count.
    args: []TypedValue,
    results: []TypedValue,
    args_len: u8 = 0,
    results_len: u8 = 0,
};

pub const Error = error{
    OutOfRange,
    MalformedTypedValue,
};

pub const PayloadError = error{
    UnknownType,
    InvalidDecimal,
    Overflow,
};

/// Parse a `TypedValue` token's payload into the runtime `Value`
/// union arm. f32 / f64 payloads in the corpus are decimal-encoded
/// **bit patterns** (per `wast-importer.sh`'s f32/f64 emission); the
/// payload `1165172736` for `f32:` means `@bitCast(@as(u32,
/// 1165172736)) → f32`. i32 / i64 use the same parseInt path but
/// the parsed value lands directly in the signed-arm via @bitCast
/// (Wasm const literals are nominally unsigned wraparound).
pub fn parsePayload(tv: TypedValue) PayloadError!runtime.Value {
    if (std.mem.eql(u8, tv.ty, "i32")) {
        const u = std.fmt.parseInt(u32, tv.payload, 10) catch |err| return mapParseErr(err);
        return runtime.Value{ .i32 = @bitCast(u) };
    }
    if (std.mem.eql(u8, tv.ty, "i64")) {
        const u = std.fmt.parseInt(u64, tv.payload, 10) catch |err| return mapParseErr(err);
        return runtime.Value{ .i64 = @bitCast(u) };
    }
    if (std.mem.eql(u8, tv.ty, "f32")) {
        const u = std.fmt.parseInt(u32, tv.payload, 10) catch |err| return mapParseErr(err);
        return runtime.Value{ .f32 = @bitCast(u) };
    }
    if (std.mem.eql(u8, tv.ty, "f64")) {
        const u = std.fmt.parseInt(u64, tv.payload, 10) catch |err| return mapParseErr(err);
        return runtime.Value{ .f64 = @bitCast(u) };
    }
    // `ref.null <ht>` distills to `<reftype>:null` (externref/funcref/
    // anyref/structref/...). All null refs share the null_ref sentinel (0).
    // Without this, a null-ref ARG (e.g. table.grow's init in
    // function-references/table_grow) failed parseInt → the call was skipped
    // → false value mismatches downstream (ADR-0192; companion to D-456).
    if (std.mem.eql(u8, tv.payload, "null")) {
        return runtime.Value{ .ref = runtime.Value.null_ref };
    }
    if (std.mem.eql(u8, tv.ty, "externref")) {
        // Host externref `ref.extern N`: bind a non-null opaque sentinel
        // distinct per N. Placed far above the GC heap range + low-bit-0
        // so ref.test's readObjKind bounds-guard classifies it as a
        // non-GC host ref (coarse extern/any match per gcAbstractMatch)
        // and isI31Ref(v) is false. Lets `invoke init externref:N`
        // populate externref tables (ref_test / ref_cast / br_on_cast
        // init() previously no-op'd, cascading their asserts to fail).
        const n = std.fmt.parseInt(u32, tv.payload, 10) catch |err| return mapParseErr(err);
        return runtime.Value{ .ref = HOST_EXTERN_BASE + @as(u64, n) * 2 };
    }
    // v128 / funcref payloads land when a manifest in the corpus emits
    // them; the wasm-3.0-assert sub-corpora baked so far use only
    // i32/i64/f32/f64 + externref.
    return PayloadError.UnknownType;
}

/// Host-externref sentinel base for `ref.extern N` args (see parsePayload).
const HOST_EXTERN_BASE: u64 = 0x7000_0000_0000_0000;

fn mapParseErr(err: std.fmt.ParseIntError) PayloadError {
    return switch (err) {
        error.Overflow => PayloadError.Overflow,
        error.InvalidCharacter => PayloadError.InvalidDecimal,
    };
}

const zwasm_root = @import("zwasm");

pub const RunError = error{
    LoadFailed,
    InvokeFailed,
} || std.mem.Allocator.Error;

/// Cycle 3: compile + invoke a wasm module's named export with
/// typed args, return the first result Value. Per ADR-0109 the
/// native Zig API (`zwasm.Engine` + `zwasm.Linker` +
/// `zwasm.Instance.invoke`) is the canonical path — no c_api
/// veneer.
///
/// Args + results use `zwasm.Value` (the Native API tagged union;
/// f32/f64 stored as bit patterns). runtime.Value (from cycle 2's
/// parsePayload) is the *internal* extern union; the caller
/// converts via the small `runtimeToZwasm` adapter below.
///
/// **Bytes-in, not path-in**: the caller supplies the wasm byte
/// slice (typically via `@embedFile` at the test call site). This
/// keeps runOne FS-free + io-free → callable from any unit test
/// without `std.process.Init` ceremony.
///
/// Scope (deliberate; multi-result + void lands when a manifest
/// entry needs it):
///   - exactly 1 result expected; void-returning funcs unsupported.
///   - invocation errors flatten to `RunError.InvokeFailed`;
///     trap-class discrimination is a follow-on cycle.
pub fn runOne(
    alloc: std.mem.Allocator,
    wasm_bytes: []const u8,
    func_name: []const u8,
    args: []const zwasm_root.Value,
) RunError!zwasm_root.Value {
    var engine = zwasm_root.Engine.init(alloc, .{}) catch return RunError.OutOfMemory;
    defer engine.deinit();
    var module = engine.compile(wasm_bytes) catch return RunError.InvokeFailed;
    defer module.deinit();
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    var instance = linker.instantiate(&module, .{}) catch return RunError.InvokeFailed;
    defer instance.deinit();

    var results: [1]zwasm_root.Value = undefined;
    instance.invoke(func_name, args, results[0..1]) catch return RunError.InvokeFailed;
    return results[0];
}

/// No-op `spectest.print_i32_f32` host stub. wg-3.0 `return_call.0.wasm`
/// gained a `tailprint_i32_f32` export that imports it (the conventional
/// spec-testsuite print module), so a fixture using that corpus can only
/// be instantiated once the import is satisfied.
fn spectestPrintI32F32(_: *zwasm_root.Caller, _: i32, _: f32) void {
    // no-op (trace print semantics)
}

/// Like `runOne` but registers the conventional `spectest.print_i32_f32`
/// host import. Needed for the wg-3.0 tail-call corpus's import-bearing
/// `return_call.0.wasm`; the import-free `runOne` cannot instantiate it.
pub fn runOneSpectest(
    alloc: std.mem.Allocator,
    wasm_bytes: []const u8,
    func_name: []const u8,
    args: []const zwasm_root.Value,
) RunError!zwasm_root.Value {
    var engine = zwasm_root.Engine.init(alloc, .{}) catch return RunError.OutOfMemory;
    defer engine.deinit();
    var module = engine.compile(wasm_bytes) catch return RunError.InvokeFailed;
    defer module.deinit();
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    linker.defineFunc("spectest", "print_i32_f32", fn (*zwasm_root.Caller, i32, f32) void, spectestPrintI32F32) catch return RunError.InvokeFailed;
    var instance = linker.instantiate(&module, .{}) catch return RunError.InvokeFailed;
    defer instance.deinit();

    var results: [1]zwasm_root.Value = undefined;
    instance.invoke(func_name, args, results[0..1]) catch return RunError.InvokeFailed;
    return results[0];
}

/// D-190 — `assert_return` invoke against an already-instantiated
/// Instance. The dispatch loop owns Engine/Module/Linker/Instance
/// per `module` directive so state-dependent sequences within a
/// module block accumulate (memory.grow → memory.size → load
/// etc.). Mirrors `runOne`'s single-scalar-result gate.
pub fn invokeInstance(
    instance: *zwasm_root.Instance,
    func_name: []const u8,
    args: []const zwasm_root.Value,
) RunError!zwasm_root.Value {
    var results: [1]zwasm_root.Value = undefined;
    instance.invoke(func_name, args, results[0..1]) catch return RunError.InvokeFailed;
    return results[0];
}

/// D-190 — void-result variant. Drives side-effecting funcs
/// (memory.store / table.set / global.set) that the spec runner
/// previously skipped because results_len != 1. Without this,
/// state-dependent sequences (`store_at_zero () → load_at_zero
/// () -> i32:2`) saw zeroed memory because the store never ran.
pub fn invokeInstanceVoid(
    instance: *zwasm_root.Instance,
    func_name: []const u8,
    args: []const zwasm_root.Value,
) RunError!void {
    var results: [0]zwasm_root.Value = .{};
    instance.invoke(func_name, args, results[0..0]) catch return RunError.InvokeFailed;
}

pub const TrapOutcome = enum {
    /// invoke errored — assert_trap passes (something trapped).
    trapped,
    /// invoke returned normally — assert_trap fails (no trap).
    returned_normally,
};

/// `assert_trap` execution path: compile + instantiate + look up
/// the export's sig (so results are sized correctly + the arity
/// check doesn't trip pre-execution), then invoke. Any
/// `Instance.InvokeError` from invoke is treated as a trap
/// (matches the v1 spec runner's lenient policy — the bake step
/// drops the original trap-reason string, so trap-class
/// discrimination is a follow-on enhancement). Returns
/// `.returned_normally` if invoke succeeds (assert_trap fail).
///
/// Setup errors (compile failure, instantiate failure, export
/// not found, not-a-func) propagate as `RunError` — the caller
/// can decide whether to count them as fail or skip.
pub fn runOneTrap(
    alloc: std.mem.Allocator,
    wasm_bytes: []const u8,
    func_name: []const u8,
    args: []const zwasm_root.Value,
) RunError!TrapOutcome {
    var engine = zwasm_root.Engine.init(alloc, .{}) catch return RunError.OutOfMemory;
    defer engine.deinit();
    var module = engine.compile(wasm_bytes) catch return RunError.LoadFailed;
    defer module.deinit();
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    var instance = linker.instantiate(&module, .{}) catch return RunError.LoadFailed;
    defer instance.deinit();

    const sig = instance.exportFuncSig(func_name) orelse return RunError.LoadFailed;
    const n_results = sig.results.len;
    // Stack-bounded; the wasm-3.0-assert corpus's assert_trap funcs
    // top out at single-scalar results today. Multi-result trap
    // funcs land alongside multi-value execution in a follow-on
    // cycle (matches the assert_return single-scalar gate).
    var results_buf: [4]zwasm_root.Value = undefined;
    if (n_results > results_buf.len) return RunError.InvokeFailed;
    const results = results_buf[0..n_results];

    instance.invoke(func_name, args, results) catch return .trapped;
    return .returned_normally;
}

/// D-190 — `assert_trap` invoke against an already-instantiated
/// Instance. Mirrors `runOneTrap`'s sig-lookup + lenient
/// trap-treatment logic but shares the caller-owned Instance.
pub fn invokeInstanceTrap(
    instance: *zwasm_root.Instance,
    func_name: []const u8,
    args: []const zwasm_root.Value,
) RunError!TrapOutcome {
    const sig = instance.exportFuncSig(func_name) orelse return RunError.LoadFailed;
    const n_results = sig.results.len;
    var results_buf: [4]zwasm_root.Value = undefined;
    if (n_results > results_buf.len) return RunError.InvokeFailed;
    const results = results_buf[0..n_results];
    instance.invoke(func_name, args, results) catch return .trapped;
    return .returned_normally;
}

pub const ExceptionOutcome = enum {
    /// invoke errored with `Trap.UncaughtException` —
    /// assert_exception passes.
    uncaught_exception,
    /// invoke returned normally — assert_exception fails (function
    /// completed without throwing).
    returned_normally,
    /// invoke errored with a non-exception trap (DivByZero, OOB,
    /// etc.) — assert_exception fails (function trapped but not
    /// via the EH path).
    other_trap,
};

/// `assert_exception` execution path: same compile + sig + invoke
/// shape as runOneTrap, but discriminates the trap class. Only
/// `Trap.UncaughtException` counts as the expected outcome; any
/// other trap (DivByZero, OOB, etc.) is `.other_trap` (failed
/// because the function trapped for an unrelated reason).
/// Requires the c_api `mapDispatchErr` to route UncaughtException
/// through (added alongside this helper).
pub fn runOneExpectException(
    alloc: std.mem.Allocator,
    wasm_bytes: []const u8,
    func_name: []const u8,
    args: []const zwasm_root.Value,
) RunError!ExceptionOutcome {
    var engine = zwasm_root.Engine.init(alloc, .{}) catch return RunError.OutOfMemory;
    defer engine.deinit();
    var module = engine.compile(wasm_bytes) catch return RunError.LoadFailed;
    defer module.deinit();
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    var instance = linker.instantiate(&module, .{}) catch return RunError.LoadFailed;
    defer instance.deinit();

    const sig = instance.exportFuncSig(func_name) orelse return RunError.LoadFailed;
    const n_results = sig.results.len;
    var results_buf: [4]zwasm_root.Value = undefined;
    if (n_results > results_buf.len) return RunError.InvokeFailed;
    const results = results_buf[0..n_results];

    instance.invoke(func_name, args, results) catch |err| {
        return if (err == error.UncaughtException) .uncaught_exception else .other_trap;
    };
    return .returned_normally;
}

/// D-190 — `assert_exception` invoke against an already-instantiated
/// Instance. Mirrors `runOneExpectException`'s trap-class
/// discrimination logic.
pub fn invokeInstanceExpectException(
    instance: *zwasm_root.Instance,
    func_name: []const u8,
    args: []const zwasm_root.Value,
) RunError!ExceptionOutcome {
    const sig = instance.exportFuncSig(func_name) orelse return RunError.LoadFailed;
    const n_results = sig.results.len;
    var results_buf: [4]zwasm_root.Value = undefined;
    if (n_results > results_buf.len) return RunError.InvokeFailed;
    const results = results_buf[0..n_results];
    instance.invoke(func_name, args, results) catch |err| {
        return if (err == error.UncaughtException) .uncaught_exception else .other_trap;
    };
    return .returned_normally;
}

pub const CompileOutcome = enum {
    /// Engine.compile errored — assert_invalid / assert_malformed
    /// passes (the validator/parser rejected as expected).
    rejected,
    /// Engine.compile succeeded — assert_invalid / assert_malformed
    /// fails (the bytes parsed AND validated clean).
    accepted,
};

/// `assert_invalid` / `assert_malformed` execution path: try
/// `Engine.compile` and report whether the module was rejected.
/// Currently both directives map to the same dispatch (compile
/// bundles parse + validate; the spec-level distinction —
/// assert_malformed targets the parser stage, assert_invalid the
/// validator — isn't surfaced by the c_api boundary today).
/// OutOfMemory propagates; everything else from compile is treated
/// as a rejection.
pub fn compileExpectInvalid(
    alloc: std.mem.Allocator,
    wasm_bytes: []const u8,
) std.mem.Allocator.Error!CompileOutcome {
    var engine = try zwasm_root.Engine.init(alloc, .{});
    defer engine.deinit();
    var module = engine.compile(wasm_bytes) catch return .rejected;
    module.deinit();
    return .accepted;
}

/// Adapter for the cycle-2 parsePayload output (runtime.Value
/// extern union) → cycle-3 runOne input (zwasm.Value tagged union).
/// The two types differ structurally: runtime.Value stores floats
/// natively; zwasm.Value stores floats as bit patterns (u32/u64).
/// This adapter handles the i32/i64/f32/f64 arms; v128 / ref arms
/// land when a manifest needs them.
pub fn runtimeToZwasm(rv: runtime.Value, ty: []const u8) zwasm_root.Value {
    if (std.mem.eql(u8, ty, "i32")) return .{ .i32 = rv.i32 };
    if (std.mem.eql(u8, ty, "i64")) return .{ .i64 = rv.i64 };
    if (std.mem.eql(u8, ty, "f32")) return .{ .f32 = @bitCast(rv.f32) };
    if (std.mem.eql(u8, ty, "f64")) return .{ .f64 = @bitCast(rv.f64) };
    // funcref: null → null, else the ref bits.
    if (std.mem.eql(u8, ty, "funcref")) return .{ .funcref = if (rv.ref == runtime.Value.null_ref) null else rv.ref };
    // externref + every other ref type (GC abstract/concrete heads — anyref/
    // structref/i31ref/(ref null $t)) collapse to the externref slot: the
    // C-API Value has no GC-ref variant. null → null; a non-null host
    // externref carries its sentinel. Result-side comparison skips
    // uncomparable refs (D-456), so a collapsed GC ref never asserts a bug —
    // this keeps the converter TOTAL so a null GC-ref ARG marshals instead of
    // hitting unreachable.
    return .{ .externref = if (rv.ref == runtime.Value.null_ref) null else rv.ref };
}

/// Parse one manifest line into a `Directive`. The caller owns
/// `args_buf` and `results_buf` (typically per-line stack
/// buffers of length 4 each — manifest cap inferred from the
/// 10.T-2a corpus: max-args-per-line ≈ 3 in practice, max-
/// results-per-line ≤ 2 for the wasm-3.0-assert subset before
/// multi-value).
pub fn parseLine(
    line: []const u8,
    args_buf: []TypedValue,
    results_buf: []TypedValue,
) Error!Directive {
    var directive: Directive = .{
        .kind = .unknown,
        .args = args_buf,
        .results = results_buf,
    };

    // Identify the directive head + capture the rest.
    const head = std.mem.findScalar(u8, line, ' ') orelse line.len;
    const kind_str = line[0..head];
    const rest = if (head == line.len) "" else line[head + 1 ..];

    if (std.mem.eql(u8, kind_str, "module")) {
        directive.kind = .module;
        // 10.M-D195b cycle 72 — `module $<id> <path>` carries an
        // optional name-binding tag (wast `(module $X …)` form).
        // If `rest` starts with `$`, split off the first space-
        // separated token as the module_id and the remainder as
        // the path.
        if (rest.len > 0 and rest[0] == '$') {
            const sp = std.mem.findScalar(u8, rest, ' ');
            if (sp) |sp_i| {
                directive.module_id = rest[0..sp_i];
                directive.module_path = rest[sp_i + 1 ..];
            } else {
                directive.module_path = rest;
            }
        } else {
            directive.module_path = rest;
        }
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "skip-impl")) {
        directive.kind = .skip_impl;
        directive.reason = rest;
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "skip-validator")) {
        directive.kind = .skip_validator;
        directive.reason = rest;
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "skip-runtime")) {
        directive.kind = .skip_runtime;
        directive.reason = rest;
        return directive;
    }
    if (std.mem.startsWith(u8, kind_str, "skip-adr-")) {
        directive.kind = .skip_adr;
        directive.reason = rest;
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "assert_invalid")) {
        directive.kind = .assert_invalid;
        directive.module_path = rest;
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "assert_malformed")) {
        directive.kind = .assert_malformed;
        directive.module_path = rest;
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "assert_uninstantiable")) {
        directive.kind = .assert_uninstantiable;
        directive.module_path = rest;
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "assert_unlinkable")) {
        directive.kind = .assert_unlinkable;
        directive.module_path = rest;
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "register")) {
        // 10.M-D195b cycle 70 — `register <as>` directive. The
        // registered-as name lands in func_name (the field is
        // generic; future-cycle handler reads it as the name).
        directive.kind = .register;
        directive.func_name = rest;
        return directive;
    }

    const is_assert_return = std.mem.eql(u8, kind_str, "assert_return");
    const is_assert_trap = std.mem.eql(u8, kind_str, "assert_trap");
    const is_assert_exception = std.mem.eql(u8, kind_str, "assert_exception");
    const is_invoke = std.mem.eql(u8, kind_str, "invoke");
    if (!is_assert_return and !is_assert_trap and !is_assert_exception and !is_invoke) {
        return directive; // .unknown
    }

    directive.kind = if (is_assert_return)
        .assert_return
    else if (is_assert_trap)
        .assert_trap
    else if (is_assert_exception)
        .assert_exception
    else
        .invoke;

    // Split rest into tokens; first non-typed token is funcname,
    // typed tokens (`<ty>:<val>`) until `->` are args, after
    // `->` are results.
    var tokens = std.mem.splitScalar(u8, rest, ' ');
    var seen_arrow: bool = false;
    // Byte span of the func name within `rest`. A wasm export name may
    // contain spaces (multi-memory/linking3 exports `get memory[0]` and
    // `get table[0]` literally), and the manifest is space-delimited, so
    // the name is whatever runs from the first token up to the first
    // `()` / `->` / typed `<ty>:<payload>` token. Parsing it as a single
    // token made those two lines `Error.MalformedTypedValue`, which the
    // runner's `catch continue` then dropped with no counter.
    var name_start: ?usize = null;
    var name_end: usize = 0;
    // The name run is CONTIGUOUS from the first token. Anything that is not
    // a name token closes it for good — including `()`, which is why this is
    // a flag rather than a `seen_arrow or args_len > 0` test: `()` consumes
    // itself with a bare `continue`, setting neither, so `assert_return f ()
    // g -> i32:1` would have glued `g` on and produced the name `"f () g"`
    // (the span covers the intervening bytes) instead of surfacing as
    // malformed. A corrupted corpus line would then have run against a
    // differently-named function and been tallied as a normal verdict.
    var name_run_open = true;
    while (tokens.next()) |tok| {
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "->")) {
            seen_arrow = true;
            name_run_open = false;
            continue;
        }
        const is_name_token = !std.mem.eql(u8, tok, "()") and
            (std.mem.findScalar(u8, tok, ':') == null or std.mem.find(u8, tok, "::") != null);
        if (is_name_token) {
            if (!name_run_open) return Error.MalformedTypedValue;
            const off = @intFromPtr(tok.ptr) - @intFromPtr(rest.ptr);
            if (name_start == null) {
                // 10.M-D195b cycle 72 — `$module::field` syntax splits
                // the FIRST name token at `::`; the module_id (with $
                // prefix) goes into directive.module_id, the rest starts
                // the func-name span.
                if (std.mem.find(u8, tok, "::")) |sep| {
                    directive.module_id = tok[0..sep];
                    name_start = off + sep + 2;
                } else {
                    name_start = off;
                }
            }
            name_end = off + tok.len;
            continue;
        }
        // Typed value or empty-result marker `()`.
        if (std.mem.eql(u8, tok, "()")) {
            // Void result — no typed value added, but the name run ends here.
            name_run_open = false;
            continue;
        }
        name_run_open = false;
        const colon = std.mem.findScalar(u8, tok, ':') orelse return Error.MalformedTypedValue;
        const tv: TypedValue = .{ .ty = tok[0..colon], .payload = tok[colon + 1 ..] };
        if (seen_arrow) {
            if (directive.results_len >= results_buf.len) return Error.OutOfRange;
            results_buf[directive.results_len] = tv;
            directive.results_len += 1;
        } else {
            if (directive.args_len >= args_buf.len) return Error.OutOfRange;
            args_buf[directive.args_len] = tv;
            directive.args_len += 1;
        }
    }

    if (name_start) |s| directive.func_name = rest[s..name_end];
    return directive;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "parseLine: module directive captures path" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("module return_call.0.wasm", &args, &results);
    try testing.expectEqual(Kind.module, d.kind);
    try testing.expectEqualStrings("return_call.0.wasm", d.module_path);
}

test "parseLine: assert_return with no args + i32 result" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_return type-i32 () -> i32:306", &args, &results);
    try testing.expectEqual(Kind.assert_return, d.kind);
    try testing.expectEqualStrings("type-i32", d.func_name);
    try testing.expectEqual(@as(u8, 0), d.args_len);
    try testing.expectEqual(@as(u8, 1), d.results_len);
    try testing.expectEqualStrings("i32", d.results[0].ty);
    try testing.expectEqualStrings("306", d.results[0].payload);
}

test "parseLine: assert_return with typed args + i64 result" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_return fac-acc i64:5 i64:1 -> i64:120", &args, &results);
    try testing.expectEqual(Kind.assert_return, d.kind);
    try testing.expectEqualStrings("fac-acc", d.func_name);
    try testing.expectEqual(@as(u8, 2), d.args_len);
    try testing.expectEqualStrings("i64", d.args[0].ty);
    try testing.expectEqualStrings("5", d.args[0].payload);
    try testing.expectEqualStrings("1", d.args[1].payload);
    try testing.expectEqual(@as(u8, 1), d.results_len);
    try testing.expectEqualStrings("120", d.results[0].payload);
}

test "parseLine: assert_return with void result `()`" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_return store i64:18446744073709551612 i32:42 -> ()", &args, &results);
    try testing.expectEqual(Kind.assert_return, d.kind);
    try testing.expectEqual(@as(u8, 2), d.args_len);
    try testing.expectEqual(@as(u8, 0), d.results_len); // void
}

test "parseLine: invoke action (D-191) — args parsed, no results section" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("invoke zero_everything ()", &args, &results);
    try testing.expectEqual(Kind.invoke, d.kind);
    try testing.expectEqualStrings("zero_everything", d.func_name);
    try testing.expectEqual(@as(u8, 0), d.args_len);
    try testing.expectEqual(@as(u8, 0), d.results_len);
}

test "parseLine: invoke action with typed args (D-191)" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("invoke malloc i64:42", &args, &results);
    try testing.expectEqual(Kind.invoke, d.kind);
    try testing.expectEqualStrings("malloc", d.func_name);
    try testing.expectEqual(@as(u8, 1), d.args_len);
    try testing.expectEqualStrings("i64", d.args[0].ty);
    try testing.expectEqualStrings("42", d.args[0].payload);
}

test "parseLine: assert_trap no result" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_trap store i64:18446744073709551613 i32:13", &args, &results);
    try testing.expectEqual(Kind.assert_trap, d.kind);
    try testing.expectEqualStrings("store", d.func_name);
    try testing.expectEqual(@as(u8, 2), d.args_len);
    try testing.expectEqual(@as(u8, 0), d.results_len);
}

test "parseLine: skip-impl directive captures reason" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("skip-impl directive-action", &args, &results);
    try testing.expectEqual(Kind.skip_impl, d.kind);
    try testing.expectEqualStrings("directive-action", d.reason);
}

test "parseLine: register directive captures registered-as name (10.M-D195b cycle 70)" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("register M", &args, &results);
    try testing.expectEqual(Kind.register, d.kind);
    try testing.expectEqualStrings("M", d.func_name);
}

test "parseLine: module $<id> <path> carries module_id (10.M-D195b cycle 72)" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("module $M load1.0.wasm", &args, &results);
    try testing.expectEqual(Kind.module, d.kind);
    try testing.expectEqualStrings("$M", d.module_id);
    try testing.expectEqualStrings("load1.0.wasm", d.module_path);
}

test "parseLine: assert_return with \\$M::field tagged invoke (10.M-D195b cycle 72)" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_return $M::read i32:20 -> i32:1", &args, &results);
    try testing.expectEqual(Kind.assert_return, d.kind);
    try testing.expectEqualStrings("$M", d.module_id);
    try testing.expectEqualStrings("read", d.func_name);
    try testing.expectEqual(@as(u8, 1), d.args_len);
    try testing.expectEqual(@as(u8, 1), d.results_len);
}

test "parseLine: assert_invalid captures wasm path" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_invalid bad.wasm", &args, &results);
    try testing.expectEqual(Kind.assert_invalid, d.kind);
    try testing.expectEqualStrings("bad.wasm", d.module_path);
}

test "parseLine: args overflow → OutOfRange" {
    var args: [1]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    try testing.expectError(Error.OutOfRange, parseLine("assert_return foo i32:1 i32:2 -> ()", &args, &results));
}

test "parseLine: export name containing spaces spans tokens (multi-memory/linking3)" {
    // The wast fixture exports the literal names `get memory[0]` /
    // `get table[0]`. Space-delimited single-token name parsing made
    // these two corpus lines MalformedTypedValue, and the runner's
    // `catch continue` dropped them uncounted — 2 of the 3 lines by
    // which `asserts_return` (11289) undercounted the corpus (11292).
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_return $Ms::get memory[0] () -> i32:104", &args, &results);
    try testing.expectEqual(Kind.assert_return, d.kind);
    try testing.expectEqualStrings("$Ms", d.module_id);
    try testing.expectEqualStrings("get memory[0]", d.func_name);
    try testing.expectEqual(@as(u8, 0), d.args_len);
    try testing.expectEqual(@as(u8, 1), d.results_len);
    try testing.expectEqualStrings("104", d.results[0].payload);
}

test "parseLine: spaced export name without a module tag" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_return get table[0] () -> i32:57005", &args, &results);
    try testing.expectEqualStrings("", d.module_id);
    try testing.expectEqualStrings("get table[0]", d.func_name);
}

test "parseLine: a bare token after an arg stays malformed" {
    // Greedy name parsing must not absorb a stray token once args have
    // started — that would silently reinterpret a malformed line as a
    // differently-named call.
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    try testing.expectError(Error.MalformedTypedValue, parseLine("assert_return foo i32:1 bar -> i32:2", &args, &results));
    try testing.expectError(Error.MalformedTypedValue, parseLine("assert_return foo () -> i32:2 bar", &args, &results));
}

test "parseLine: `()` closes the name run" {
    // The empty-argument marker consumes itself; if it does not also END the
    // name run, a stray token after it is glued onto the name and the line
    // runs against a differently-named function instead of surfacing as
    // unparsed. The span covers the intervening bytes, so the name would
    // have come out as the literal "f () g".
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    try testing.expectError(Error.MalformedTypedValue, parseLine("assert_return f () g -> i32:1", &args, &results));
    // ...and the legitimate spaced-name form, where the run is contiguous
    // and `()` comes after it, still parses.
    const d = try parseLine("assert_return get table[0] () -> i32:1", &args, &results);
    try testing.expectEqualStrings("get table[0]", d.func_name);
}

test "parseLine: skip-adr-<id> classifies as skip_adr, not unknown" {
    // 95 corpus lines spell `skip-adr-skip_text_format_parser`; with no
    // matching kind they parsed as `.unknown`, which the runner dropped
    // with no counter and no denominator entry.
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("skip-adr-skip_text_format_parser wat literals unsupported", &args, &results);
    try testing.expectEqual(Kind.skip_adr, d.kind);
    try testing.expectEqualStrings("wat literals unsupported", d.reason);
}

test "parsePayload: i32 positive decimal lands in Value.i32" {
    const v = try parsePayload(.{ .ty = "i32", .payload = "306" });
    try testing.expectEqual(@as(i32, 306), v.i32);
}

test "parsePayload: i32 large-unsigned wraps via @bitCast (Wasm const semantics)" {
    // 0xFFFFFFFF = u32 max; @bitCast → i32 -1.
    const v = try parsePayload(.{ .ty = "i32", .payload = "4294967295" });
    try testing.expectEqual(@as(i32, -1), v.i32);
}

test "parsePayload: i64 large-unsigned wraps to -1" {
    // 18446744073709551615 = u64 max.
    const v = try parsePayload(.{ .ty = "i64", .payload = "18446744073709551615" });
    try testing.expectEqual(@as(i64, -1), v.i64);
}

test "parsePayload: f32 bit pattern → @bitCast f32 (corpus shape)" {
    // 0x40000000 = 1073741824 = bit pattern for f32 2.0.
    const v = try parsePayload(.{ .ty = "f32", .payload = "1073741824" });
    try testing.expectEqual(@as(f32, 2.0), v.f32);
}

test "parsePayload: f64 bit pattern → @bitCast f64" {
    // 0x4000000000000000 = 4611686018427387904 = bit pattern for f64 2.0.
    const v = try parsePayload(.{ .ty = "f64", .payload = "4611686018427387904" });
    try testing.expectEqual(@as(f64, 2.0), v.f64);
}

test "parsePayload: f32 round-trip via @bitCast (corpus-style payload)" {
    // Confirm the bit-cast direction matches the manifest's
    // assumed encoding: a known f32 (3.14) → its u32 bit pattern
    // (decimal-stringified) → parsePayload → same f32.
    const bits: u32 = @bitCast(@as(f32, 3.14));
    var buf: [16]u8 = undefined;
    const s = try std.mem.print(&buf, "{d}", .{bits});
    const v = try parsePayload(.{ .ty = "f32", .payload = s });
    try testing.expectEqual(@as(f32, 3.14), v.f32);
}

test "parsePayload: ref.null <ht> (any reftype):null → null_ref sentinel" {
    for ([_][]const u8{ "externref", "funcref", "anyref", "structref" }) |ty| {
        const v = try parsePayload(.{ .ty = ty, .payload = "null" });
        try testing.expectEqual(runtime.Value.null_ref, v.ref);
    }
}

test "parsePayload: unknown type returns PayloadError.UnknownType" {
    try testing.expectError(PayloadError.UnknownType, parsePayload(.{ .ty = "v128", .payload = "0" }));
}

test "parsePayload: invalid decimal returns PayloadError.InvalidDecimal" {
    try testing.expectError(PayloadError.InvalidDecimal, parsePayload(.{ .ty = "i32", .payload = "abc" }));
}

test "parsePayload: overflow returns PayloadError.Overflow" {
    try testing.expectError(PayloadError.Overflow, parsePayload(.{ .ty = "i32", .payload = "4294967296" }));
}

test "parsePayload + parseLine round-trip: assert_return fac-acc i64:5 i64:1 → Value{i64:5} Value{i64:1}" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_return fac-acc i64:5 i64:1 -> i64:120", &args, &results);
    try testing.expectEqual(@as(u8, 2), d.args_len);
    const a0 = try parsePayload(d.args[0]);
    const a1 = try parsePayload(d.args[1]);
    const r0 = try parsePayload(d.results[0]);
    try testing.expectEqual(@as(i64, 5), a0.i64);
    try testing.expectEqual(@as(i64, 1), a1.i64);
    try testing.expectEqual(@as(i64, 120), r0.i64);
}

test "runOne e2e: return_call.0.wasm type-i32 () -> i32:306 (10.TC verify)" {
    // First end-to-end manifest entry execution via the Native Zig
    // API. Exercises the same-module direct tail-call codegen from
    // the just-closed 10.TC-emit-body bundle: fn `type-i32` ends in
    // `return_call type-first` (per the wast source); type-first
    // returns 306 (= 0x132).
    //
    // @embedFile pins the fixture at compile time — keeps runOne
    // FS-free + io-free, and the test fails fast if the corpus is
    // missing (rather than skipping silently).
    const wasm_bytes = @embedFile("wasm-3.0-assert/tail-call/return_call/return_call.0.wasm");
    const result = try runOneSpectest(testing.allocator, wasm_bytes, "type-i32", &.{});
    try testing.expectEqual(@as(i32, 306), result.i32);
}

test "D-190 invokeInstance shared-state: grow then size on memory64 returns post-grow page count" {
    // Spec runner state-persistence regression marker. The wasm-3.0-
    // assert dispatch loop previously created a fresh Engine + Module
    // + Instance per directive, so the memory_grow64.0 manifest's
    // `grow i64:1 -> i64:0` followed by `size () -> i64:1` always saw
    // a fresh-zero state on the second call. invokeInstance (this
    // cycle) reuses a single Instance across directives within a
    // `module` block.
    const wasm_bytes = @embedFile("wasm-3.0-assert/memory64/memory_grow64/memory_grow64.0.wasm");
    const alloc = testing.allocator;
    var engine = try zwasm_root.Engine.init(alloc, .{});
    defer engine.deinit();
    var module = try engine.compile(wasm_bytes);
    defer module.deinit();
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    var instance = try linker.instantiate(&module, .{});
    defer instance.deinit();

    // size () -> i64:0 (initial)
    const r0 = try invokeInstance(&instance, "size", &.{});
    try testing.expectEqual(@as(i64, 0), r0.i64);
    // grow i64:1 -> i64:0 (old size)
    const r1 = try invokeInstance(&instance, "grow", &.{.{ .i64 = 1 }});
    try testing.expectEqual(@as(i64, 0), r1.i64);
    // size () -> i64:1 (post-grow) — fails on stateless dispatch
    const r2 = try invokeInstance(&instance, "size", &.{});
    try testing.expectEqual(@as(i64, 1), r2.i64);
}

test "runOneTrap: handcrafted_trap always_traps reports .trapped" {
    // wasm-1.0 handcrafted_trap/m.wasm exports two fns: `always_traps`
    // (unconditional `unreachable`) and `trap_on_neg` (traps when arg
    // < 0). Cross-corpus fixture — Wasm 3.0 corpus's assert_trap
    // funcs require parser/codegen support that isn't all green yet
    // (memory64 / EH); the 1.0 fixture exercises ONLY the
    // runOneTrap dispatch surface, which is corpus-agnostic.
    const wasm_bytes = @embedFile("wasm-1.0-assert/handcrafted_trap/m.wasm");
    const outcome = try runOneTrap(testing.allocator, wasm_bytes, "always_traps", &.{});
    try testing.expectEqual(TrapOutcome.trapped, outcome);
}

test "runOneTrap: trap_on_neg i32:5 returns normally (no false trap)" {
    // Sanity guard: `trap_on_neg` with arg 5 (≥ 0) does NOT trap;
    // ensures the helper doesn't classify normal returns as trapped
    // (e.g. by swallowing a setup-side error).
    const wasm_bytes = @embedFile("wasm-1.0-assert/handcrafted_trap/m.wasm");
    const args = [_]zwasm_root.Value{.{ .i32 = 5 }};
    const outcome = try runOneTrap(testing.allocator, wasm_bytes, "trap_on_neg", &args);
    try testing.expectEqual(TrapOutcome.returned_normally, outcome);
}

test "runOneTrap: trap_on_neg i32:-1 traps" {
    // Pairs with the assert_return above; verifies the trap path
    // fires when arg < 0.
    const wasm_bytes = @embedFile("wasm-1.0-assert/handcrafted_trap/m.wasm");
    const args = [_]zwasm_root.Value{.{ .i32 = -1 }};
    const outcome = try runOneTrap(testing.allocator, wasm_bytes, "trap_on_neg", &args);
    try testing.expectEqual(TrapOutcome.trapped, outcome);
}

test "compileExpectInvalid: return_call.1.wasm rejected (assert_invalid path)" {
    // tail-call return_call.1.wasm is listed as assert_invalid in
    // the corpus manifest (one of 10 invalid fixtures). The
    // validator must reject it; this pins the assert_invalid
    // dispatch surface before the runner wires it in.
    const wasm_bytes = @embedFile("wasm-3.0-assert/tail-call/return_call/return_call.1.wasm");
    const outcome = try compileExpectInvalid(testing.allocator, wasm_bytes);
    try testing.expectEqual(CompileOutcome.rejected, outcome);
}

test "runOneExpectException: trap_on_neg i32:-1 reports .other_trap (not exception)" {
    // Sanity guard: a non-EH trap (here `unreachable` via
    // handcrafted_trap) must be classified `.other_trap`, NOT
    // `.uncaught_exception`. Verifies the trap-class discrimination
    // doesn't conflate generic traps with EH exceptions.
    const wasm_bytes = @embedFile("wasm-1.0-assert/handcrafted_trap/m.wasm");
    const args = [_]zwasm_root.Value{.{ .i32 = -1 }};
    const outcome = try runOneExpectException(testing.allocator, wasm_bytes, "trap_on_neg", &args);
    try testing.expectEqual(ExceptionOutcome.other_trap, outcome);
}

test "runOneExpectException: normal return reports .returned_normally" {
    // Sanity: a function that returns cleanly is `.returned_normally`,
    // not exception/trap. Mirrors the runOneTrap returned_normally
    // guard.
    const wasm_bytes = @embedFile("wasm-1.0-assert/handcrafted_trap/m.wasm");
    const args = [_]zwasm_root.Value{.{ .i32 = 5 }};
    const outcome = try runOneExpectException(testing.allocator, wasm_bytes, "trap_on_neg", &args);
    try testing.expectEqual(ExceptionOutcome.returned_normally, outcome);
}

test "D-188 bisect: EH + func-refs invalid-accepted fixtures (regression marker)" {
    // Identifies the 6 fixtures listed as assert_invalid that
    // current `Engine.compile` accepts. Pinned per D-188 — when
    // the validator's reject-set closes a case, the count goes
    // down; this test goes red as a prompt to update the marker.
    // Cross-corpus @embedFile pins the fixtures at compile time.
    const Case = struct { name: []const u8, bytes: []const u8 };
    const cases = [_]Case{
        // exception-handling try_table (7 fixtures: 6..12; 6 pass / 1 fail per runner)
        .{ .name = "try_table.6", .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.6.wasm") },
        .{ .name = "try_table.7", .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.7.wasm") },
        .{ .name = "try_table.8", .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.8.wasm") },
        .{ .name = "try_table.9", .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.9.wasm") },
        .{ .name = "try_table.10", .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.10.wasm") },
        .{ .name = "try_table.11", .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.11.wasm") },
        .{ .name = "try_table.12", .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.12.wasm") },
        // function-references ref (12 fixtures: 1..12; 7 pass / 5 fail per runner)
        .{ .name = "ref.1", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.1.wasm") },
        .{ .name = "ref.2", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.2.wasm") },
        .{ .name = "ref.3", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.3.wasm") },
        .{ .name = "ref.4", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.4.wasm") },
        .{ .name = "ref.5", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.5.wasm") },
        .{ .name = "ref.6", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.6.wasm") },
        .{ .name = "ref.7", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.7.wasm") },
        .{ .name = "ref.8", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.8.wasm") },
        .{ .name = "ref.9", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.9.wasm") },
        .{ .name = "ref.10", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.10.wasm") },
        .{ .name = "ref.11", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.11.wasm") },
        .{ .name = "ref.12", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.12.wasm") },
        // 10.R cycle 59 corpus expansion — ref_func.4 / ref_func.5
        // surface a NEW validator gap: `ref.func N` must reference a
        // function in the declared funcref set (elements section or
        // `(elem declare ...)`). Current validator accepts unrestricted
        // `ref.func 0`. Sub-gap (c) of D-195; ADR-0123-independent.
        .{ .name = "ref_func.4", .bytes = @embedFile("wasm-3.0-assert/function-references/ref_func/ref_func.4.wasm") },
        .{ .name = "ref_func.5", .bytes = @embedFile("wasm-3.0-assert/function-references/ref_func/ref_func.5.wasm") },
    };

    var accepted_count: u32 = 0;
    for (cases) |c| {
        const outcome = try compileExpectInvalid(testing.allocator, c.bytes);
        if (outcome == .accepted) {
            std.debug.print("[D-188 invalid-accepted] {s}\n", .{c.name});
            accepted_count += 1;
        }
    }
    // Current state: 0 fixtures incorrectly accepted (D-188 FULLY
    // discharged). Discharge SHAs:
    //   - ref.1..5 (function-references unknown-type cases): closed
    //     by the D-188 first-cycle fix in `instantiate.zig::
    //     frontendValidate` — pre-decode section-body validation
    //     forces type/global/table/elem decodes regardless of code-
    //     section presence.
    //   - ref_func.4 + ref_func.5 (`ref.func N` undeclared): closed
    //     cycle 60 (`e7666598`, D-195 sub-gap c) — declared-funcrefs
    //     bitset threaded through `frontendValidate` →
    //     `validateFunctionWithMemIdxAndTags` → opRefFunc rejects.
    //   - try_table.8 + try_table.10 (catch_ref + catch_all_ref label-
    //     type mismatch): closed cycle 61 — `validateCatchVec` now
    //     rejects `catch_ref` / `catch_all_ref` under v2's exnref-
    //     less ValType subset (no valid label-type can match a
    //     sequence containing exnref). Tighten to structural matching
    //     when exnref ValType lands (D-192 / ADR-0120).
    // Bisect kept as a regression marker — if a future change re-
    // opens any of the 9 invalid-accepted gates, this fires.
    try testing.expectEqual(@as(u32, 0), accepted_count);
}

test "D-189 partial: align64 invalid fixtures rejected (memarg natural-align rule)" {
    // All 37 wasm-3.0-assert/memory64/align64/*.wasm fixtures
    // are listed as assert_invalid with reason "alignment must
    // not be larger than natural" (Wasm spec §3.4.7). They
    // exercise the per-op natural-alignment cap (load8≤1,
    // load16≤2, load≤4, i64.load≤8, etc.). Before the fix
    // the validator consumed the align byte without validating
    // it → all 37 fixtures incorrectly compiled. After the fix
    // each fixture's align-too-large memarg triggers
    // `Error.AlignmentTooLarge` (or maps via the c_api boundary
    // to ParseFailed) → all 37 reject.
    // align64.0..align64.68 are baked VALID modules (per
    // memory64/align64/manifest.txt's `module` directives);
    // the assert_invalid fixtures start at align64.69 (37 total
    // through align64.105). Embed three representative invalids.
    const fixtures = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "align64.69", .bytes = @embedFile("wasm-3.0-assert/memory64/align64/align64.69.wasm") },
        .{ .name = "align64.70", .bytes = @embedFile("wasm-3.0-assert/memory64/align64/align64.70.wasm") },
        .{ .name = "align64.105", .bytes = @embedFile("wasm-3.0-assert/memory64/align64/align64.105.wasm") },
    };
    for (fixtures) |c| {
        const outcome = try compileExpectInvalid(testing.allocator, c.bytes);
        if (outcome != .rejected) {
            std.debug.print("[D-189 {s}] expected rejected, got accepted\n", .{c.name});
        }
        try testing.expectEqual(CompileOutcome.rejected, outcome);
    }
}

test "10.G-foundation cycle 5: clean module instantiates with gc_heap=null (zero-overhead invariant)" {
    // Sanity: a minimal valid module (clean (i32) -> (i32) functype,
    // no GC bytes) instantiates with Runtime.gc_heap left null —
    // verifies ADR-0115 §1's zero-overhead invariant end-to-end
    // through engine.compile + linker.instantiate. The mirror test
    // (needs_gc_heap=true → gc_heap non-null) requires a parser-
    // valid module that ALSO trips needs_heap_detector; synthesising
    // such bytes needs the GC valtype parser/validator extensions
    // that land in subsequent bundles. For cycle 5 the field-level
    // Runtime tests at `src/runtime/runtime.zig` cover the
    // materialise-then-deinit path directly.
    const clean_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, // magic
        0x01, 0x00, 0x00, 0x00, // version 1
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F, // (i32) -> (i32)
    };
    const alloc = testing.allocator;
    var engine = try zwasm_root.Engine.init(alloc, .{});
    defer engine.deinit();
    var module = try engine.compile(&clean_bytes);
    defer module.deinit();
    try testing.expectEqual(false, module.native.needs_gc_heap);
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    var instance = try linker.instantiate(&module, .{});
    defer instance.deinit();
    const rt = instance.handle.runtime.?;
    try testing.expectEqual(@as(?*zwasm_root.feature.gc.heap.Heap, null), rt.gc_heap);
}

test "EH module-compile: try_table.0.wasm compiles (10.E frontendValidate tags plumbing)" {
    // try_table.0.wasm has `(tag (type 0)) ... (func ... throw 0)`.
    // Previously frontendValidate routed through
    // validateFunctionWithMemIdx which doesn't thread the module's
    // tag section, so `throw 0` failed validator's
    // `tag_idx >= self.tags.len` check (tags.len=0) → ParseFailed.
    // Now frontendValidate decodes the tag section and threads it
    // into the validator alongside memory0_idx_type. Runtime EH
    // dispatch is a separate gap (next cycle).
    const wasm_bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.0.wasm");
    const alloc = testing.allocator;
    var engine = try zwasm_root.Engine.init(alloc, .{});
    defer engine.deinit();
    var module = try engine.compile(wasm_bytes);
    defer module.deinit();
}

test "memory64: address64.0.wasm compiles (frontendValidate memory0_idx_type plumbing)" {
    // Regression marker for the memory64 frontendValidate fix.
    // Before the fix, `validator.validateFunction` defaulted
    // memory0_idx_type to .i32, so memory64 fixtures (which load/
    // store at i64 addresses) failed with StackTypeMismatch.
    // After the fix, frontendValidate extracts the memory section's
    // idx_type and threads it into validator. Compile-side only;
    // runtime memory ops + invoke remain a separate gap.
    const wasm_bytes = @embedFile("wasm-3.0-assert/memory64/address64/address64.0.wasm");
    const alloc = testing.allocator;

    var engine = try zwasm_root.Engine.init(alloc, .{});
    defer engine.deinit();
    var module = try engine.compile(wasm_bytes);
    defer module.deinit();
}

test "memory64 instantiate: address64.0 succeeds (i64-offset active data segment)" {
    // Previously red as `error.InstantiateFailed` (bisect anchor
    // landed at `ea414cf0` for the handover-named "memory64
    // instantiate gap"). Root cause: address64.0 carries
    // `(data (i64.const 0) "abc...")` (Wasm spec §3.4.7 — active-
    // data offset's result type matches target memory's idx_type;
    // memory64 modules use `i64.const`, opcode 0x42, instead of
    // i32's 0x41). `evalConstI32Expr` rejected the i64.const with
    // `UnsupportedConstExpr`. Fix dispatches the const-expr
    // evaluator on the memory's idx_type at the data-install site
    // (and analogously at any other path that consumed
    // `evalConstI32Expr` for memory offsets).
    const wasm_bytes = @embedFile("wasm-3.0-assert/memory64/address64/address64.0.wasm");
    const alloc = testing.allocator;

    var engine = try zwasm_root.Engine.init(alloc, .{});
    defer engine.deinit();
    var module = try engine.compile(wasm_bytes);
    defer module.deinit();
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    var instance = try linker.instantiate(&module, .{});
    defer instance.deinit();
}

test "10.M cycle 66: memory.size on memidx=1 returns page count (interp)" {
    // 10.M-multi-memory cycle 66: memory.size / memory.grow now
    // accept a non-zero memidx (was reserved 0x00 / rejected with
    // BadBlockType in `lower.zig::emitMemoryReserved`). Build a
    // 2-memory module with memory[0] = 1 page + memory[1] = 3 pages;
    // call memory.size on memidx=1 and expect 3.
    //
    // Module (hand-crafted):
    //   (module
    //     (memory 1) (memory 3)
    //     (func (export "size1") (result i32)
    //       (memory.size (memory 1))))
    //
    // memory.size encoding (Wasm 3.0 §5.4.7): opcode 0x3F + memidx
    // LEB128. Pre-cycle-66 lower rejected memidx != 0 with
    // BadBlockType.
    const wasm_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: () -> (i32)
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        // function section: 1 func, type 0
        0x03,
        0x02, 0x01, 0x00,
        // memory section: memory[0]=min1, memory[1]=min3
        0x05, 0x05, 0x02, 0x00, 0x01,
        0x00, 0x03,
        // export section: "size1" func 0
        0x07, 0x09, 0x01, 0x05, 's',  'i',
        'z',  'e',  '1',  0x00, 0x00,
        // code section: 1 body, 4 bytes (locals=0, memory.size memidx=1, end)
        0x0a, 0x06, 0x01,
        0x04,
        0x00, // locals count
        0x3f, 0x01, // memory.size memidx=1
        0x0b, // end
    };
    const alloc = testing.allocator;

    var engine = try zwasm_root.Engine.init(alloc, .{});
    defer engine.deinit();
    var module = try engine.compile(&wasm_bytes);
    defer module.deinit();
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    var instance = try linker.instantiate(&module, .{});
    defer instance.deinit();

    var results: [1]zwasm_root.Value = undefined;
    try instance.invoke("size1", &.{}, results[0..1]);
    try testing.expectEqual(@as(i32, 3), results[0].i32);
}

test "10.M cycle 64: i32.store + i32.load via memidx=1 round-trip 42 (interp)" {
    // 10.M-multi-memory bundle cycle 64: interp memory handlers now
    // route through `MemArgExtra.memidx` instead of the hard-pinned
    // `rt.memory` alias. This test exercises the new path end-to-end:
    // store 42 to memidx=1 offset 0, then load from same → expect 42.
    // Pre-change: store + load both targeted memidx 0 (via rt.memory)
    // → the value would round-trip 42 in memory 0 but memory 1 would
    // stay all-zero. With the fix, the store lands in memory 1; the
    // load also reads from memory 1; round-trip is 42.
    //
    // Module (hand-crafted):
    //   (module
    //     (memory 1) (memory 1)
    //     (func (export "test") (result i32)
    //       (i32.store (memory 1) (i32.const 0) (i32.const 42))
    //       (i32.load  (memory 1) (i32.const 0))))
    //
    // memarg encoding (Wasm 3.0 §5.4.6): align byte sets bit 6 (0x40)
    // to signal a memidx LEB follows; effective log2-align = align & 0x3F.
    // For i32 natural align=4 (= 2^2), memarg align byte = 0x40 | 0x02 = 0x42,
    // followed by memidx LEB (0x01) then offset LEB (0x00).
    const wasm_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // \0asm + version
        // type section: () -> (i32)
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        // function section: 1 func, type 0
        0x03,
        0x02, 0x01, 0x00,
        // memory section: 2 memories, both min=1
        0x05, 0x05, 0x02, 0x00, 0x01,
        0x00, 0x01,
        // export section: "test" func 0
        0x07, 0x08, 0x01, 0x04, 't',  'e',
        's',  't',  0x00, 0x00,
        // code section
        0x0a, 0x12, 0x01, 0x10, // section header, body count + size
        0x00, // locals count
        0x41, 0x00, // i32.const 0 (store addr)
        0x41, 0x2a, // i32.const 42 (store value)
        0x36, 0x42, 0x01, 0x00, // i32.store memidx=1 align=2 offset=0
        0x41, 0x00, // i32.const 0 (load addr)
        0x28, 0x42, 0x01, 0x00, // i32.load memidx=1 align=2 offset=0
        0x0b, // end
    };
    const alloc = testing.allocator;

    var engine = try zwasm_root.Engine.init(alloc, .{});
    defer engine.deinit();
    var module = try engine.compile(&wasm_bytes);
    defer module.deinit();
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    var instance = try linker.instantiate(&module, .{});
    defer instance.deinit();

    var results: [1]zwasm_root.Value = undefined;
    try instance.invoke("test", &.{}, results[0..1]);
    try testing.expectEqual(@as(i32, 42), results[0].i32);
}

test "10.M cycle 62: two-defined-memory module instantiates (multi-memory relax)" {
    // Smallest red for the 10.M-multi-memory bundle cycle-62 chunk:
    // hand-craft a binary wasm with `(memory 1) (memory 1)` (two
    // defined memories). Pre-change: `instantiate.zig:825`'s
    // `if (memories.items.len > 1) return error.MultiMemoryUnsupported`
    // killed the instantiate. Post-change: the loop allocates N
    // MemoryInstance entries; `rt.memory` keeps aliasing memories[0]
    // for single-memory-shaped emit paths. memidx > 0 memory ops
    // remain out of scope (next bundle cycle).
    //
    // Module shape (raw bytes; no function section since the test
    // only exercises instantiate, not invoke):
    //   magic + version
    //   memory section: 2 entries, both `(min=1)`
    const wasm_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, // \0asm magic
        0x01, 0x00, 0x00, 0x00, // version 1
        0x05, 0x05, // section id 5 (memory), 5 bytes body
        0x02, //   count = 2
        0x00, 0x01, //   memory[0]: flags=0 (min only), min=1
        0x00, 0x01, //   memory[1]: flags=0 (min only), min=1
    };
    const alloc = testing.allocator;

    var engine = try zwasm_root.Engine.init(alloc, .{});
    defer engine.deinit();
    var module = try engine.compile(&wasm_bytes);
    defer module.deinit();
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    var instance = try linker.instantiate(&module, .{});
    defer instance.deinit();
    // Substrate verification: the runtime now holds 2 MemoryInstance
    // entries. (The native API doesn't expose `rt.memories.len`
    // directly; instantiate succeeding is the observable delta —
    // pre-change it returned `error.MultiMemoryUnsupported`.)
}

test "compileExpectInvalid: return_call.0.wasm accepted (no false rejection)" {
    // Sanity: the valid return_call.0.wasm (which the bisect test
    // executes 31/31 directives against) must NOT be reported as
    // rejected. Guards against the helper classifying valid
    // modules as invalid.
    const wasm_bytes = @embedFile("wasm-3.0-assert/tail-call/return_call/return_call.0.wasm");
    const outcome = try compileExpectInvalid(testing.allocator, wasm_bytes);
    try testing.expectEqual(CompileOutcome.accepted, outcome);
}

// ============================================================
// Tail-call FAIL bisect (D-187 — interp tail-call grows Zig stack)
// ============================================================
//
// wasm-3.0-assert/tail-call shows pass=25 / fail=6 out of 31
// assert_returns against `return_call.0.wasm`. Root cause (per
// `src/interp/mvp.zig:440-443` self-documented limitation): the
// interp's `returnCallOp` invokes the callee via Zig recursion
// (`invoke(callee)` then `tailReturn` — see mvp.zig:467-482),
// mirroring Wasm tail-calls onto the host call stack. Each
// `return_call` adds an interp Frame (max_frame_stack = 256 per
// `src/runtime/frame.zig:24`); recursion exceeding 256 deep hits
// `Trap.CallStackExhausted` at `runtime.zig:341`. The 6 failing
// cases (count/even/odd at 999+ iterations) need millions of
// tail-iterations and trip the ceiling well before completion.
// The JIT codegen (10.TC-emit-body bundle) implements
// frame_teardown + BR X16 / JMP R11 for actual frame-reuse;
// Native API `Instance.invoke` (src/zwasm/instance.zig:113) goes
// through `dispatch.run` → interp dispatch table, so the JIT
// path is not yet exercised by this runner.
//
// This test is a **regression marker** — `pass == 25` pins the
// current state. When D-187 discharges (either by routing the
// spec runner through the JIT or implementing a non-recursive
// interp dispatch for tail-call), this assertion fails red and
// must be retightened to `pass == 31, fail == 0`.
//
// The wg-3.0 corpus has 33 asserts against `return_call.0.wasm`; this
// marker enumerates the 31 single-result ones. The 2 added by wg-3.0 —
// `tailprint_i32_f32` (void result) + `type-f64-i64-to-i32-f32` (multi-
// value i32 f32 result) — are exercised by the spec assert runner, which
// models void/multi-value; this single-result harness deliberately omits
// them. Later `module` directives switch to unrelated fixtures.
test "tail-call bisect: enumerate 31 single-result assert_returns + print failures (D-187 regression marker)" {
    const wasm_bytes = @embedFile("wasm-3.0-assert/tail-call/return_call/return_call.0.wasm");
    const Case = struct {
        name: []const u8,
        args: []const zwasm_root.Value,
        want_kind: enum { i32, i64, f32, f64 },
        want_i32: i32 = 0,
        want_i64: i64 = 0,
        want_f32: u32 = 0,
        want_f64: u64 = 0,
    };
    const cases = [_]Case{
        .{ .name = "type-i32", .args = &.{}, .want_kind = .i32, .want_i32 = 306 },
        .{ .name = "type-i64", .args = &.{}, .want_kind = .i64, .want_i64 = 356 },
        .{ .name = "type-f32", .args = &.{}, .want_kind = .f32, .want_f32 = 1165172736 },
        .{ .name = "type-f64", .args = &.{}, .want_kind = .f64, .want_f64 = 4660882566700597248 },
        .{ .name = "type-first-i32", .args = &.{}, .want_kind = .i32, .want_i32 = 32 },
        .{ .name = "type-first-i64", .args = &.{}, .want_kind = .i64, .want_i64 = 64 },
        .{ .name = "type-first-f32", .args = &.{}, .want_kind = .f32, .want_f32 = 1068037571 },
        .{ .name = "type-first-f64", .args = &.{}, .want_kind = .f64, .want_f64 = 4610064722561534525 },
        .{ .name = "type-second-i32", .args = &.{}, .want_kind = .i32, .want_i32 = 32 },
        .{ .name = "type-second-i64", .args = &.{}, .want_kind = .i64, .want_i64 = 64 },
        .{ .name = "type-second-f32", .args = &.{}, .want_kind = .f32, .want_f32 = 1107296256 },
        .{ .name = "type-second-f64", .args = &.{}, .want_kind = .f64, .want_f64 = 4634211053438658150 },
        .{ .name = "fac-acc", .args = &[_]zwasm_root.Value{ .{ .i64 = 0 }, .{ .i64 = 1 } }, .want_kind = .i64, .want_i64 = 1 },
        .{ .name = "fac-acc", .args = &[_]zwasm_root.Value{ .{ .i64 = 1 }, .{ .i64 = 1 } }, .want_kind = .i64, .want_i64 = 1 },
        .{ .name = "fac-acc", .args = &[_]zwasm_root.Value{ .{ .i64 = 5 }, .{ .i64 = 1 } }, .want_kind = .i64, .want_i64 = 120 },
        .{ .name = "fac-acc", .args = &[_]zwasm_root.Value{ .{ .i64 = 25 }, .{ .i64 = 1 } }, .want_kind = .i64, .want_i64 = 7034535277573963776 },
        .{ .name = "count", .args = &[_]zwasm_root.Value{.{ .i64 = 0 }}, .want_kind = .i64, .want_i64 = 0 },
        .{ .name = "count", .args = &[_]zwasm_root.Value{.{ .i64 = 1000 }}, .want_kind = .i64, .want_i64 = 0 },
        .{ .name = "count", .args = &[_]zwasm_root.Value{.{ .i64 = 1000000 }}, .want_kind = .i64, .want_i64 = 0 },
        .{ .name = "even", .args = &[_]zwasm_root.Value{.{ .i64 = 0 }}, .want_kind = .i32, .want_i32 = 44 },
        .{ .name = "even", .args = &[_]zwasm_root.Value{.{ .i64 = 1 }}, .want_kind = .i32, .want_i32 = 99 },
        .{ .name = "even", .args = &[_]zwasm_root.Value{.{ .i64 = 100 }}, .want_kind = .i32, .want_i32 = 44 },
        .{ .name = "even", .args = &[_]zwasm_root.Value{.{ .i64 = 77 }}, .want_kind = .i32, .want_i32 = 99 },
        .{ .name = "even", .args = &[_]zwasm_root.Value{.{ .i64 = 1000000 }}, .want_kind = .i32, .want_i32 = 44 },
        .{ .name = "even", .args = &[_]zwasm_root.Value{.{ .i64 = 1000001 }}, .want_kind = .i32, .want_i32 = 99 },
        .{ .name = "odd", .args = &[_]zwasm_root.Value{.{ .i64 = 0 }}, .want_kind = .i32, .want_i32 = 99 },
        .{ .name = "odd", .args = &[_]zwasm_root.Value{.{ .i64 = 1 }}, .want_kind = .i32, .want_i32 = 44 },
        .{ .name = "odd", .args = &[_]zwasm_root.Value{.{ .i64 = 200 }}, .want_kind = .i32, .want_i32 = 99 },
        .{ .name = "odd", .args = &[_]zwasm_root.Value{.{ .i64 = 77 }}, .want_kind = .i32, .want_i32 = 44 },
        .{ .name = "odd", .args = &[_]zwasm_root.Value{.{ .i64 = 1000000 }}, .want_kind = .i32, .want_i32 = 99 },
        .{ .name = "odd", .args = &[_]zwasm_root.Value{.{ .i64 = 999999 }}, .want_kind = .i32, .want_i32 = 44 },
    };

    var pass: u32 = 0;
    var fail: u32 = 0;
    for (cases, 0..) |c, idx| {
        const got = runOneSpectest(testing.allocator, wasm_bytes, c.name, c.args) catch |err| {
            std.debug.print("[bisect fail #{d:>2}] {s} args={any} -> err={s}\n", .{ idx, c.name, c.args, @errorName(err) });
            fail += 1;
            continue;
        };
        const ok = switch (c.want_kind) {
            .i32 => got.i32 == c.want_i32,
            .i64 => got.i64 == c.want_i64,
            .f32 => got.f32 == c.want_f32,
            .f64 => got.f64 == c.want_f64,
        };
        if (ok) {
            pass += 1;
        } else {
            switch (c.want_kind) {
                .i32 => std.debug.print("[bisect fail #{d:>2}] {s} args={any} want=i32:{d} got=i32:{d}\n", .{ idx, c.name, c.args, c.want_i32, got.i32 }),
                .i64 => std.debug.print("[bisect fail #{d:>2}] {s} args={any} want=i64:{d} got=i64:{d}\n", .{ idx, c.name, c.args, c.want_i64, got.i64 }),
                .f32 => std.debug.print("[bisect fail #{d:>2}] {s} args={any} want=f32:{x} got=f32:{x}\n", .{ idx, c.name, c.args, c.want_f32, got.f32 }),
                .f64 => std.debug.print("[bisect fail #{d:>2}] {s} args={any} want=f64:{x} got=f64:{x}\n", .{ idx, c.name, c.args, c.want_f64, got.f64 }),
            }
            fail += 1;
        }
    }
    if (pass != cases.len or fail != 0) {
        std.debug.print("[tail-call bisect] pass={d} fail={d} (expected all-pass)\n", .{ pass, fail });
    }
    // D-187 discharged via the 10.TC interp trampoline (planned
    // row 10.TC scope) — `dispatch.run` now switches frames
    // in-place on `return_call`, so the host Zig call stack no
    // longer grows per Wasm tail-call. All 31 directives must pass.
    try testing.expectEqual(@as(u32, 0), fail);
    try testing.expectEqual(@as(u32, @intCast(cases.len)), pass);
}
