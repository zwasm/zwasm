//! Shared base for spec-assertion runners (§9.9 / 9.9-l-1a per ADR-0057).
//!
//! Extraction substrate for code shared between `simd_assert_runner.zig`
//! (existing) and `spec_assert_runner_non_simd.zig` (l-1b). This file
//! starts with the mechanically-extractable scalar token parsers +
//! quoted-export name splitter; subsequent l-1a sub-chunks extend it
//! with the full manifest-loop + module-init + RunnerCallbacks trait
//! per ADR-0057 §"Decision".
//!
//! Each function here is **stateless** and **format-agnostic** — the
//! tokens it parses come from text manifests produced by
//! `scripts/regen_spec_*_assert.sh` (Python distillation of upstream
//! WebAssembly testsuite `.wast` files). The behaviour matches the
//! pre-extraction shape exactly; SIMD test gate verifies green-to-green.
//!
//! Zone: test/ (outside the src/ zone hierarchy per ADR-0023 §A1).

const std = @import("std");

const zwasm = @import("zwasm");
const runner_mod = zwasm.engine.runner;
const entry = zwasm.engine.codegen.shared.entry;
const jit_mem = zwasm.platform.jit_mem;
const shared_thunk = zwasm.engine.codegen.shared.thunk;
const Value = zwasm.runtime.Value;
const spectest_catalog = @import("spectest_catalog.zig");

/// Parse a decimal integer token into its u32 bit pattern. Wasm
/// asserts emit i32 results as decimal strings; signed values may
/// appear (negative literals in the source ⇒ negative decimal here).
/// Spec semantics treat the bits as u32; both u32 and i32 parsings
/// produce the same bit pattern via `@bitCast`.
pub fn parseI32Token(tok: []const u8) !u32 {
    return std.fmt.parseInt(u32, tok, 10) catch
        @as(u32, @bitCast(std.fmt.parseInt(i32, tok, 10) catch return error.BadValue));
}

/// 64-bit mirror of `parseI32Token`. Wasm `i64` result tokens map to
/// u64 bit patterns; signed literals roundtrip via `@bitCast`.
pub fn parseI64Token(tok: []const u8) !u64 {
    return std.fmt.parseInt(u64, tok, 10) catch
        @as(u64, @bitCast(std.fmt.parseInt(i64, tok, 10) catch return error.BadValue));
}

/// Split an `assert_return` / `assert_trap` directive's left-hand
/// side into `(fn_name, args_s)`. Handles single-quoted export
/// names (Wasm 2.0 chunk 9.9-h-29 Part B: names like
/// `'v128.load align=16'` contain spaces and must stay grouped).
///
/// Returns `error.BadDirective` for malformed input (missing close
/// quote, no space after quoted name, unquoted name with no args).
pub fn splitFnAndArgs(lhs: []const u8) !struct { fn_name: []const u8, args_s: []const u8 } {
    if (lhs.len > 0 and lhs[0] == '\'') {
        const close = std.mem.findScalarPos(u8, lhs, 1, '\'') orelse return error.BadDirective;
        if (close + 1 >= lhs.len) return error.BadDirective;
        if (lhs[close + 1] != ' ') return error.BadDirective;
        return .{ .fn_name = lhs[1..close], .args_s = lhs[close + 2 ..] };
    }
    const sp1 = std.mem.findScalar(u8, lhs, ' ') orelse return error.BadDirective;
    return .{ .fn_name = lhs[0..sp1], .args_s = lhs[sp1 + 1 ..] };
}

/// §9.9 / 9.9-l-1b-d093-d53 (D-128): when an export name contains
/// control chars / quotes / whitespace, the distiller emits it as
/// `:hex:<utf8-hex>` (e.g. `:hex:0a09` for `\n\t`). This decoder
/// reverses the hex into raw bytes (UTF-8). Callers pass a stack
/// buffer; the slice returned aliases either `fn_name` directly
/// (when no `:hex:` prefix) or the buffer's first N bytes.
pub fn decodeFnName(fn_name: []const u8, buf: []u8) ![]const u8 {
    const HEX_PREFIX = ":hex:";
    if (!std.mem.startsWith(u8, fn_name, HEX_PREFIX)) return fn_name;
    const hex = fn_name[HEX_PREFIX.len..];
    if (hex.len % 2 != 0) return error.BadDirective;
    const decoded_len = hex.len / 2;
    if (decoded_len > buf.len) return error.BadDirective;
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        const hi = std.fmt.charToDigit(hex[i], 16) catch return error.BadDirective;
        const lo = std.fmt.charToDigit(hex[i + 1], 16) catch return error.BadDirective;
        buf[i / 2] = (hi << 4) | lo;
    }
    return buf[0..decoded_len];
}

/// Per-runner tally of assertion outcomes. Per ADR-0029 Path B
/// (chunk 9.9-h-21): twin counters for `skip-impl` (counts toward
/// release gate) and `skip-adr-<id>` (waived per the named ADR).
///
/// Close-plan §6 (e) (2026-05-21) split the historical `skipped`
/// counter into two strictly-distinguished counters — manifest
/// skip lines vs runtime SKIP-* events — because conflating them
/// hid the actual "skip-impl == 0" gate signal under runtime
/// SKIP events (e.g. SKIP-CROSS-MODULE-IMPORTS in §9.12-E).
///
/// Summary line shape:
/// `skipped (= N skip-impl + R runtime-skip + M skip-adr)`.
/// The exit-non-zero gate (`failed > 0`) is checked by the
/// caller; tally just collects.
pub const AssertTally = struct {
    /// ADR-0210 — the enumeration denominator: every non-blank manifest
    /// line this tally saw. Re-derivable without running the runner
    /// (`cat <corpus>/*/manifest.txt | wc -l`), which is what lets a
    /// third party check the printed pass/fail/skip against the work
    /// actually enumerated instead of taking the summary on trust.
    /// `residual()` names whatever the verdict columns do not cover.
    lines: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    /// Manifest `skip-impl <reason>` lines (and bare-legacy
    /// `skip <reason>` pre-chunk 9.9-h-22 regen lines) — counts
    /// toward the `skip-impl == 0` release gate (ADR-0029 Path B
    /// + ADR-0050 D-5). A non-zero value means the manifest has
    /// yet-to-be-classified gaps that need either a `skip-adr-<id>`
    /// reclassification or an implementation that lets the line
    /// be removed entirely.
    manifest_skip_impl: u32 = 0,
    /// Runtime SKIP-* events emitted by assertion-time code when
    /// a fixture would otherwise FAIL because of a structural
    /// barrier the runner can't paper over (SKIP-CROSS-MODULE-
    /// IMPORTS / SKIP-V2-InstanceAllocFailed / SKIP-VALIDATOR-GAP
    /// / SKIP-WASMTIME-UNUSABLE / etc.). These are NOT counted
    /// against the manifest gate but ARE reported separately so
    /// audit / ratchet logic can distinguish "manifest-marked
    /// gap" from "runtime-detected gap". Paired skip-token
    /// taxonomy ADR pending (close-plan §6 (f)).
    runtime_skip: u32 = 0,
    /// `skip-adr-<ADR-id> <reason>` — waived per the named ADR.
    skipped_adr: u32 = 0,

    /// Lines that reached a verdict or an enumerated skip.
    pub fn accounted(self: AssertTally) u32 {
        return self.passed + self.failed + self.manifest_skip_impl +
            self.runtime_skip + self.skipped_adr;
    }

    /// ADR-0210 — manifest lines that reached NO column. Non-assertion
    /// directives (`module` / `register` / `invoke` / …) legitimately
    /// live here, but so does every silently-dropped line, and before
    /// the denominator was printed the two were indistinguishable from
    /// outside. Printing it does not by itself say which is which; it
    /// says how much is unexplained, which is the prerequisite for
    /// explaining it.
    ///
    /// NOT a clean count of non-assertion directives: `accounted()`
    /// includes `runtime_skip`, and `runCorpus` raises that on
    /// non-assertion lines too (`SKIP-CROSS-MODULE-IMPORTS` fires while
    /// handling a `module` directive). Such a line is both a
    /// non-assertion directive and "accounted", so it drops out of
    /// `residual`. That is why the simd lane reconciles as
    /// `482 module - 2 runtime-skips = 480` rather than a round 482 —
    /// anyone doing the hand reconciliation needs to know it. Making
    /// these lanes report a real identity instead is D-591.
    pub fn residual(self: AssertTally) u32 {
        const acc = self.accounted();
        return if (self.lines > acc) self.lines - acc else 0;
    }

    /// Columns claiming MORE lines than were read. Two causes, and the
    /// counter does not distinguish them: a line tallied twice (the
    /// wasm-3.0 shared `skips` bucket did exactly this), or a verdict
    /// recorded for a manifest whose lines were never counted at all —
    /// `runCorpus` increments `failed` when the manifest read itself
    /// fails, before any line is seen. Either way the printed columns no
    /// longer describe the lines read, which is what the reader needs to
    /// know. `residual()` alone cannot show it: it saturates at zero, so
    /// an over-count reads exactly like a perfectly accounted corpus.
    pub fn overcounted(self: AssertTally) u32 {
        const acc = self.accounted();
        return if (acc > self.lines) acc - self.lines else 0;
    }
};

/// ADR-0029 Path B classification — categorise a manifest line's
/// directive prefix into the skip family (or .other for everything
/// that isn't a skip). The caller increments the matching tally
/// counter; .bare_legacy additionally triggers a WARN print.
pub const SkipKind = enum { skip_impl, skip_adr, bare_legacy, other };

/// Classify a trimmed manifest line. Returns `.other` for lines
/// that don't start with `skip*`; the caller dispatches non-skip
/// directives separately.
pub fn classifySkipLine(line: []const u8) SkipKind {
    if (std.mem.startsWith(u8, line, "skip-impl ")) return .skip_impl;
    if (std.mem.startsWith(u8, line, "skip-adr-")) return .skip_adr;
    if (std.mem.startsWith(u8, line, "skip ")) return .bare_legacy;
    return .other;
}

/// Non-skip directive kinds in the manifest format. The caller
/// dispatches on this enum; `.unknown` lets specialisations decide
/// what to do (warn, ignore, fail) for unrecognised lines.
pub const DirectiveKind = enum {
    module,
    assert_return,
    assert_trap,
    assert_invalid,
    assert_malformed,
    /// d-57: module is valid but instantiation fails (active
    /// data/elem OOB, start-fn trap, …). PASS on any init-time
    /// error; FAIL if instantiation completes cleanly.
    assert_uninstantiable,
    /// d-58: module fails to link — `unknown import` (no provider
    /// for the named import) or `incompatible import type`
    /// (provider exists but type mismatch). PASS if compile
    /// rejects OR hasUnbindableImports trips; FAIL if the module
    /// resolves cleanly under our scaffolding.
    assert_unlinkable,
    /// d-62: module traps due to call-stack exhaustion (runaway
    /// recursion). Same dispatch as assert_trap from our scaffold's
    /// perspective — native stack-guard-page SIGSEGV is converted
    /// to `Error.Trap` by the d-29 sigsetjmp/siglongjmp handler,
    /// and trap_flag=set or recovery=true both PASS. The distinct
    /// directive name is preserved for manifest auditability.
    assert_exhaustion,
    /// d-36: bare `(invoke FN ARGS)` action — invoke for side
    /// effects, ignore result, propagate traps as FAIL.
    invoke_action,
    /// §9.12-E / B137 — wast `(get "field")` same-module action
    /// (Wasm spec §A.2.4 "Actions"). Body is the export name +
    /// typed expected value, space-separated:
    /// `get-action <field> <type> <value>`. Replaces the prior
    /// `skip-impl non-invoke-action` placeholder (master plan
    /// §5.3 SKIP-EXPORTS site). Runners implementing
    /// `handle_get_action` look up the global by export name +
    /// compare its current value against the expected; runners
    /// without the callback emit `SKIP-NON-INVOKE-ACTION` as
    /// skip-adr.
    get_action,
    /// Phase 9 §9.9-III chunk (c)-1c per ADR-0065: wast
    /// `(register "M" $inst)` directive — binds the current
    /// module under a host-import alias. Body is the alias name.
    /// Runner stores the current module's wasm bytes under the
    /// alias in a session-local registry for subsequent
    /// cross-module imports (consumer in chunk (c)-2). Previously
    /// emitted as `skip-adr-skip_cross_module_register`.
    register,
    unknown,
};

/// Pair returned by `classifyDirective` — the directive kind and
/// the body (= line content after the prefix + single space).
pub const ClassifiedDirective = struct {
    kind: DirectiveKind,
    body: []const u8,
};

/// Inverse of `classifySkipLine` for the non-skip half: identify
/// which assert/module directive a line carries and return the
/// trailing body. Caller MUST have already routed through
/// `classifySkipLine` and seen `.other` before invoking this.
///
/// For `.unknown` the body is the full line (no prefix was
/// stripped); the caller can quote it back into a WARN/FAIL.
pub fn classifyDirective(line: []const u8) ClassifiedDirective {
    if (std.mem.startsWith(u8, line, "module ")) {
        return .{ .kind = .module, .body = line[7..] };
    }
    if (std.mem.startsWith(u8, line, "assert_return ")) {
        return .{ .kind = .assert_return, .body = line[14..] };
    }
    if (std.mem.startsWith(u8, line, "assert_trap ")) {
        return .{ .kind = .assert_trap, .body = line[12..] };
    }
    if (std.mem.startsWith(u8, line, "assert_invalid ")) {
        return .{ .kind = .assert_invalid, .body = line[15..] };
    }
    if (std.mem.startsWith(u8, line, "assert_malformed ")) {
        return .{ .kind = .assert_malformed, .body = line[17..] };
    }
    if (std.mem.startsWith(u8, line, "assert_uninstantiable ")) {
        return .{ .kind = .assert_uninstantiable, .body = line[22..] };
    }
    if (std.mem.startsWith(u8, line, "assert_unlinkable ")) {
        return .{ .kind = .assert_unlinkable, .body = line[18..] };
    }
    if (std.mem.startsWith(u8, line, "assert_exhaustion ")) {
        return .{ .kind = .assert_exhaustion, .body = line[18..] };
    }
    if (std.mem.startsWith(u8, line, "invoke-action ")) {
        return .{ .kind = .invoke_action, .body = line[14..] };
    }
    if (std.mem.startsWith(u8, line, "get-action ")) {
        return .{ .kind = .get_action, .body = line[11..] };
    }
    if (std.mem.startsWith(u8, line, "register ")) {
        return .{ .kind = .register, .body = line[9..] };
    }
    return .{ .kind = .unknown, .body = line };
}

/// Construct a `JitRuntime` from caller-owned scratch buffers
/// (memory + globals + funcref table). The buffer ownership lives
/// in the runner specialisation (since v128 globals demand
/// 16-byte alignment that scalar runners don't need); base only
/// stamps the `JitRuntime` struct shape so both runners produce
/// byte-identical layouts when handing off to the JIT entry
/// helpers.
///
/// Per ADR-0045 (scratch-buffer-direct path): spec runners bypass
/// `setupRuntime`'s per-module allocation; this helper is the
/// uniform construction point. Per ADR-0052: `globals_base` is a
/// `[*]Value` so the existing 8-byte-stride field type keeps
/// compiling; actual access width per global is decided by the
/// JIT emit (8 B scalars vs 16 B v128 via MOVUPS / LDR-Q).
///
/// Per ADR-0059 (§9.9 / 9.9-l-1b-d093-d8c): `memory_grow_fn` is
/// wired to `growableMemoryGrowFn` (below) so spec corpora that
/// exercise `memory.grow` (nop/block/loop/local_tee
/// `as-memory.grow-*` fixtures) see real growth within the
/// `growable_memory` pool. Callers must use `growable_memory[0..
/// current_mem_bytes]` as the `memory` arg (the runner's
/// on_module_loaded hook calls `resetGrowableMemory(1)` first).
pub fn makeJitRuntime(
    memory: []u8,
    globals: []u8,
    funcptrs: []u64,
    typeidxs: []u32,
    // §9.9-III (c)-2.3-β-1 per ADR-0066: optional per-module
    // dispatch override. When `dispatch_override` is non-null,
    // `host_dispatch_base` points at the caller-provided slice
    // (typically: trap stubs initially, with some slots
    // overwritten by `shared.thunk.emitThunk` addresses for
    // cross-module-resolved imports). When null, falls back to
    // the static `host_dispatch_stubs` global (the pre-(c)-2.3
    // shape — all imports route to the host-trap stub). The
    // length of the slice (or HOST_DISPATCH_STUB_CAPACITY in
    // the null case) populates `host_dispatch_count`.
    dispatch_override: ?[]const usize,
) entry.JitRuntime {
    // §9.9 / 9.9-l-1b-d093-d42b (D-112): always wire entry 0 of
    // the multi-table descriptor to point at the (funcptrs,
    // typeidxs) args. `setupMultiTableScratch` (called from each
    // runner's on_module_loaded) writes entries `k > 0` and
    // updates `active_table_count` to the module's actual table
    // count. JIT call_indirect with `ins.extra > 0` will read
    // through `tables_jit_ci_ptr[k]` for tables 1..N.
    scratch_table_jit_ci[0] = .{ .funcptr_base = funcptrs.ptr, .typeidx_base = typeidxs.ptr };
    // §9.9 / 9.9-l-1b-d093-d47 (D-121 fix): do NOT reset
    // scratch_tables_descriptor[0] here. The d-42b / d-43
    // pre-d-47 version overwrote `.len` to `funcptrs.len`
    // (= harness scratch capacity 32) on every makeJitRuntime
    // call, clobbering the module-derived `tbl_min` that
    // `setupMultiTableScratch` populated at on_module_loaded.
    // The bug surfaced as `table_get.wast: get-externref(2)`
    // not trapping — the JIT's bounds check saw len=32 instead
    // of the declared 2 for the externref table. setupMulti's
    // table-0 bind at on_module_loaded is authoritative for
    // the lifetime of the module; spec_assert harness's
    // module-switch sequence (on_module_loaded fires before
    // any assert) guarantees setupMulti has run before any
    // makeJitRuntime that consumes the descriptor.
    return .{
        .vm_base = memory.ptr,
        .mem_limit = memory.len,
        .funcptr_base = funcptrs.ptr,
        .table_size = @intCast(funcptrs.len),
        .typeidx_base = typeidxs.ptr,
        .trap_flag = 0,
        .globals_base = @ptrCast(@alignCast(globals.ptr)),
        .globals_count = @intCast(globals.len / @sizeOf(Value)),
        .tables_ptr = &scratch_tables_descriptor,
        .tables_count = active_table_count,
        .tables_jit_ci_ptr = &scratch_table_jit_ci,
        .tables_jit_ci_count = active_table_count,
        .func_entities_ptr = @ptrCast(&scratch_func_entities),
        .func_entities_count = active_func_count,
        // D-093 (d-35): point host_dispatch_base at the spec-runner
        // import-trap stub table. Modules that import functions
        // (e.g. start.wast `(import "spectest" "print_i32")`) emit
        // `LDR X16, [X19, host_dispatch_base_off]; LDR X16,
        // [X16, idx*8]; BLR X16` for `(call N)` when N < num_imports;
        // before d-35 host_dispatch_base was `undefined` (0xaa…),
        // so the LDR dereferenced garbage and SEGV'd. The stub
        // table satisfies the LDR chain and traps cleanly via
        // `trap_flag`. Sized to `HOST_DISPATCH_STUB_CAPACITY` (≥
        // any realistic module's import count); unused slots also
        // point to the trap stub so out-of-range indices remain
        // safe.
        .host_dispatch_base = if (dispatch_override) |d| d.ptr else &host_dispatch_stubs,
        .host_dispatch_count = if (dispatch_override) |d| @intCast(d.len) else HOST_DISPATCH_STUB_CAPACITY,
        .memory_grow_fn = growableMemoryGrowFn,
        .table_grow_fn = growableTableGrowFn,
        // §9.9 / 9.9-l-1b-d093-d49 (D-123): elem-segment scratch
        // populated by `setupElemSegments` (called from
        // `setupMultiTableScratch`). JIT `table.init` indexes
        // `elem_segments_ptr` with stride 16; `elem.drop` /
        // `table.init` consult `elem_dropped_ptr[idx]` to
        // override seg.len = 0 when the segment was dropped.
        .elem_segments_ptr = if (active_elem_segments_count == 0) @as([*]const entry.ElemSlice, undefined) else &scratch_elem_segments,
        .elem_segments_count = active_elem_segments_count,
        .elem_dropped_ptr = &scratch_elem_dropped,
        .elem_dropped_count = active_elem_segments_count,
        // §9.9 / 9.9-l-1b-d093-d50 (D-119/D-120): data-segment
        // scratch wired so JIT `memory.init` / `data.drop` see
        // valid pointers. Mirror of d-49's elem-segment fix.
        .data_segments_ptr = if (active_data_segments_count == 0) @as([*]const entry.SegmentSlice, undefined) else &scratch_data_segments,
        .data_segments_count = active_data_segments_count,
        .data_dropped_ptr = &scratch_data_dropped,
        .data_dropped_count = active_data_segments_count,
        // Threads/atomics (ADR-0168): memory-0 shared flag so
        // `memory.atomic.wait{32,64}` runs vs trapping kind=15. Seeded
        // per-module by the runner's on_module_loaded (default 0).
        .mem0_shared = current_mem_shared,
    };
}

/// Spec-runner import binding stub for `spectest.*` per Phase 9
/// Cat III chunk (c)-1b (per ADR-0065). The Wasm spectest module
/// (defined by the spec testsuite host contract) exposes only
/// **void-return** functions (`print_i32(i32)→()`, `print_f32(f32)
/// →()`, etc.) plus non-function globals/table/memory. The print
/// family is pure side-effect for human-observable test output;
/// per Wasm spec §A.2 the assert-return semantics check return
/// values, not host-side prints, so a no-op stub that doesn't set
/// `trap_flag` is semantically equivalent to a real spectest binding
/// **for fixtures that only assert return values**.
///
/// Architecture: a single `host_dispatch_base` slot points at this
/// stub; all imports route through it. The stub takes the minimum
/// viable shape (`fn(rt)→void`) — most arches' C ABIs let a callee
/// with this shape legally consume args / produce no return when
/// the actual import-site shape was `fn(rt, ...args)→result`. Caller
/// cleans the stack on x86_64 SysV / arm64 AAPCS64; the unread arg
/// registers don't affect the callee, and the void return matches
/// every spectest function in the testsuite.
///
/// `HOST_IMPORT_TRAP_SENTINEL` (0xBADC0DE) is kept as historical
/// reference for the pre-(c)-1b trap-stub-set-flag behaviour; it
/// is no longer written by the live stub but `printCallTrap` /
/// `dispatchVoidResult` still recognise it for back-compat in any
/// stale binary path that hasn't been re-baked. Once Cat III sub-
/// chunks (c)-2 (cross-module import linker) and (c)-4 (per-import
/// resolved binding) land, this stub can be replaced by per-import
/// dispatch.
pub const HOST_IMPORT_TRAP_SENTINEL: u32 = 0xBADC0DE;

/// §9.9-III D-144 γ.4 cycle 2 — permanent diagnostic counter for
/// hostImportTrapStub fires. Increments per stub invocation;
/// pairs with `host_import_stub_trap_flag_at_entry` to localise
/// which call sets trap_flag during cross-module fixture runs.
/// Reset per assert dispatch (D-129 pending_host_import_skip
/// pattern). Per `hypothesis_enumeration.md` step-4 discipline
/// (permanent diagnostic infra per multi-cycle debug).
pub var host_import_stub_call_count: u32 = 0;
pub var host_import_stub_last_trap_flag: u32 = 0;

/// Per-defined-function JIT hex-dump toggle (D-163 origin closed). Off by
/// default — the runner main sets it from `ZWASM_DUMP_JIT`. Kept reachable
/// for D-279 investigation; default-off removes the per-func `std.debug.print`
/// flood that drowned every test-all log (D-279 H7 probe).
pub var dump_jit_enabled: bool = false;

fn hostImportTrapStub(rt: *entry.JitRuntime) callconv(.c) void {
    // Phase 9 Cat III chunk (c)-1b: no-op return for spectest void
    // imports. Side-effect prints skipped (per Wasm spec §A.2 the
    // assert checks return values, not side prints).
    host_import_stub_call_count += 1;
    host_import_stub_last_trap_flag = rt.trap_flag;
}

/// §9.9 / 9.9-l-1b-d093-d54 (D-129): callback-set side channel
/// for "this assert tripped the host-import trap stub; treat as
/// skip-adr instead of FAIL". `runCorpus` resets this before
/// each callback dispatch and reads it after `ok=false` to
/// route the outcome correctly. Single-threaded by construction
/// (the runner is single-threaded; tests don't fork goroutines).
pub var pending_host_import_skip: bool = false;

/// §9.9 / 9.9-l-1b-d093-d54 (D-129): unified trap-handling
/// printer for assert_return + invoke-action call sites in the
/// dispatch ladders. When `rt.trap_flag` matches the host-import
/// sentinel, sets `pending_host_import_skip` + prints
/// SKIP-HOST-IMPORT; otherwise prints the standard FAIL line.
/// `args_s == "()"` collapses to the no-args print form for
/// readability.
pub fn printCallTrap(
    rt: *entry.JitRuntime,
    name: []const u8,
    fn_name: []const u8,
    args_s: []const u8,
    err: anyerror,
    stdout: *std.Io.Writer,
) !void {
    if (rt.trap_flag == HOST_IMPORT_TRAP_SENTINEL) {
        pending_host_import_skip = true;
        try stdout.print("SKIP-HOST-IMPORT  {s}: {s}({s}) host-import stub trap\n", .{ name, fn_name, args_s });
        return;
    }
    // §9.9-III D-144 γ.4 cycle 2: emit stub-fire counter alongside
    // FAIL so cross-module-import-bearing fixtures localise their
    // trap source. `host_import_stub_call_count` increments per
    // hostImportTrapStub invocation; `last_trap_flag` snapshots
    // rt.trap_flag at the entry of the most-recent stub fire.
    // For a fixture whose body chains spectest-only no-op stubs +
    // exactly one cross-module call, the counter delta tells us
    // whether the trap happened before or after the cross-module
    // call. Per `hypothesis_enumeration.md` step-4 (permanent
    // diagnostic infra over throwaway probes).
    // §9.9-III D-144 γ.4 cycle 3 permanent diag: also emit
    // `rt.trap_flag` AT printCallTrap entry. The dispatcher
    // returned error.Trap because trap_flag became non-zero;
    // its value identifies the trap *kind* (JIT trap codes are
    // distinct per source: unreachable / OOB / sig-mismatch /
    // div-by-zero / etc.). Pairs with `last_tf` (= pre-stub
    // snapshot) to tell us whether the trap fired *during* a
    // stub or in JIT code between stubs / after the last stub.
    // §9.9-III D-144 γ.4 cycle 4 also emit `trap_kind` so callers
    // see WHICH JIT trap source fired:
    //   1  = generic (memory bounds / unreachable / NaN / range)
    //   2  = call_indirect bounds (B.HS)
    //   3  = call_indirect sig (B.NE)
    //   0  = unknown (SIGSEGV-recovered or pre-cycle-4 binary)
    if (std.mem.eql(u8, args_s, "()") or args_s.len == 0) {
        try stdout.print("FAIL  {s}: call {s}(): {s} [stubs={d} last_tf={d} tf={d} kind={d}]\n", .{ name, fn_name, @errorName(err), host_import_stub_call_count, host_import_stub_last_trap_flag, rt.trap_flag, rt.trap_kind });
    } else {
        try stdout.print("FAIL  {s}: call {s}({s}): {s} [stubs={d} last_tf={d} tf={d} kind={d}]\n", .{ name, fn_name, args_s, @errorName(err), host_import_stub_call_count, host_import_stub_last_trap_flag, rt.trap_flag, rt.trap_kind });
    }
}

/// §9.9 / 9.9-l-1b-d093-d42b (D-112): per-module multi-table
/// call_indirect scratch. The spec corpus's multi-table modules
/// (select.wast: 2 tables) fit comfortably in 4; tables beyond
/// SCRATCH_MAX_TABLES surface as `Error.UnsupportedEntrySignature`
/// from `setupMultiTableScratch`. Each non-zero table gets up to
/// SCRATCH_EXTRA_TABLE_CAPACITY funcptr/typeidx slots; the spec
/// corpus's non-zero tables are all small (≤ 16 entries in
/// `select.wast`).
pub const SCRATCH_MAX_TABLES: u32 = 4;
/// §9.9 / 9.9-l-1b-d093-d48 (D-122/D-125): bumped 64 → 1024 to
/// satisfy `table_grow.wast`'s `grow($t, 800)` sequence (mirrors
/// the d-21 `GROWABLE_MEMORY_CAPACITY` 64 → 1024 bump).
pub const SCRATCH_EXTRA_TABLE_CAPACITY: u32 = 1024;

/// Per-non-zero-table funcptr/typeidx scratch. Tables 1..N-1
/// (= up to SCRATCH_MAX_TABLES-1) each own one row; the JIT body
/// reads from these via `JitRuntime.tables_jit_ci_ptr[k]`.
pub var scratch_extra_funcptrs: [SCRATCH_MAX_TABLES - 1][SCRATCH_EXTRA_TABLE_CAPACITY]u64 = undefined;
pub var scratch_extra_typeidxs: [SCRATCH_MAX_TABLES - 1][SCRATCH_EXTRA_TABLE_CAPACITY]u32 = undefined;

/// Per-table `TableJitCallInfo` descriptors. Entry 0 is rebound
/// at every `makeJitRuntime` call to point at the caller's
/// (funcptrs, typeidxs) args (= table 0). Entries 1+ are bound
/// by `setupMultiTableScratch` to point into `scratch_extra_*`.
pub var scratch_table_jit_ci: [SCRATCH_MAX_TABLES]entry.TableJitCallInfo = undefined;

/// Per-table `TableSlice` descriptors backing the JIT multi-
/// table bounds check (`JitRuntime.tables_ptr[k].len`) AND the
/// per-table refs arena consumed by `table.get/set/grow/copy/
/// init`-class ops (`tables_ptr[k].refs[idx]`). Each entry's
/// `refs` pointer is bound by `setupMultiTableScratch` to a
/// slice of `scratch_table_refs[k]`. The refs arena is sized
/// to `SCRATCH_EXTRA_TABLE_CAPACITY` per table.
pub var scratch_tables_descriptor: [SCRATCH_MAX_TABLES]entry.TableSlice = undefined;

/// Per-table refs arena. Each entry is a `Value.ref`-encoded
/// u64 (FuncEntity pointer for funcref, host handle for
/// externref, or `Value.null_ref` for null). `setupMultiTable
/// Scratch` populates this from active element segments via
/// `runner_mod.applyTableInitForTable`'s funcptr path AND
/// directly here for the FuncEntity-ptr encoding (mirrors
/// `runner.zig::setupRuntime`'s table_refs arena).
pub var scratch_table_refs: [SCRATCH_MAX_TABLES][SCRATCH_EXTRA_TABLE_CAPACITY]u64 = undefined;

/// §9.9 / 9.9-l-1b-d093-d43 (D-113): per-module FuncEntity
/// array backing JIT `ref.func` + funcref-table elem populate.
/// Sized to a comfortable upper bound; modules exceeding it
/// surface as `Error.UnsupportedEntrySignature`. The struct
/// only carries `(runtime, func_idx)` — `runtime` is
/// `undefined` in the spec runner (the spec runner has no
/// full Runtime; only the FuncEntity's address matters for
/// ref.is_null / ref.eq semantics).
pub const SCRATCH_MAX_FUNCS: u32 = 1024;
pub var scratch_func_entities: [SCRATCH_MAX_FUNCS]@import("zwasm").runtime.FuncEntity = undefined;

/// §9.9 / 9.9-l-1b-d093-d49 (D-123): per-elem-segment slice
/// descriptors backing JIT `table.init`. Populated per-module
/// load by `setupElemSegmentScratch`; consumed via
/// `JitRuntime.elem_segments_ptr`. Pre-d-49 these were
/// `undefined` — JIT `table.init` SEGV'd on first deref. Sized
/// to a generous upper bound; modules exceeding it surface as
/// `UnsupportedEntrySignature`.
pub const SCRATCH_MAX_ELEM_SEGMENTS: u32 = 128;
pub const SCRATCH_ELEM_REFS_CAPACITY: u32 = 4096;
pub var scratch_elem_segments: [SCRATCH_MAX_ELEM_SEGMENTS]entry.ElemSlice = undefined;
pub var scratch_elem_refs_arena: [SCRATCH_ELEM_REFS_CAPACITY]u64 = undefined;
pub var scratch_elem_dropped: [SCRATCH_MAX_ELEM_SEGMENTS]u8 = undefined;
pub var active_elem_segments_count: u32 = 0;

/// §9.9 / 9.9-l-1b-d093-d50 (D-119/D-120): per-data-segment slice
/// descriptors backing JIT `memory.init` (`data.drop` flips the
/// `scratch_data_dropped[i]` byte). Pre-d-50 these were
/// `undefined` in the spec_assert harness — JIT `memory.init`
/// reads `[r15+data_segments_ptr_off][i]` and SEGV'd outside any
/// armed sigsetjmp on `bulk.wast`. Mirror of d-49's
/// elem-segment scratch.
pub const SCRATCH_MAX_DATA_SEGMENTS: u32 = 128;
pub const SCRATCH_DATA_BYTES_CAPACITY: u32 = 65536;
pub var scratch_data_segments: [SCRATCH_MAX_DATA_SEGMENTS]entry.SegmentSlice = undefined;
pub var scratch_data_arena: [SCRATCH_DATA_BYTES_CAPACITY]u8 = undefined;
pub var scratch_data_dropped: [SCRATCH_MAX_DATA_SEGMENTS]u8 = undefined;
pub var active_data_segments_count: u32 = 0;

/// Number of `scratch_table_jit_ci` entries that are live for
/// the currently-loaded module. Updated by `setupMultiTableScratch`
/// during each on_module_loaded; consumed by `makeJitRuntime` to
/// populate `JitRuntime.tables_jit_ci_count`. Defaults to 1 so
/// modules with a single table (the overwhelming majority) work
/// without explicit setup.
pub var active_table_count: u32 = 1;

/// §9.9 / 9.9-l-1b-d093-d43 (D-113): number of FuncEntity slots
/// the current module populated in `scratch_func_entities`.
/// `makeJitRuntime` wires this into `JitRuntime.func_entities_count`.
/// `setupMultiTableScratch` rebinds the entire `[0..num_funcs)`
/// range at on_module_loaded; subsequent modules overwrite.
pub var active_func_count: u32 = 0;

/// §9.9 / 9.9-l-1b-d093-d42b (D-112): wire `scratch_table_jit_ci`
/// + `scratch_extra_*` for the freshly-loaded module's tables 1..N.
/// Called from each runner's `on_module_loaded` after the legacy
/// table-0 `applyTableInit`. For single-table modules sets
/// `active_table_count = 1` and is a no-op past that; for
/// multi-table modules walks each non-zero table's element segments
/// via `runner_mod.applyTableInitForTable` into the per-table
/// scratch rows and updates the descriptor + count.
pub fn setupMultiTableScratch(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    table0_funcptrs: []u64,
    table0_typeidxs: []u32,
) anyerror!void {
    return setupMultiTableScratchCtx(gpa, wasm_bytes, compiled, table0_funcptrs, table0_typeidxs, null);
}

pub fn setupMultiTableScratchCtx(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    table0_funcptrs: []u64,
    table0_typeidxs: []u32,
    gctx: ?zwasm.engine.runner_validate.GlobalsCtx,
) anyerror!void {
    const num_tables = runner_mod.countDeclaredTables(gpa, wasm_bytes);
    if (num_tables > SCRATCH_MAX_TABLES) return error.UnsupportedEntrySignature;

    // §9.9 / 9.9-l-1b-d093-d43 (D-113): repopulate FuncEntity
    // scratch for this module. Each entry's address is what
    // `Value.fromFuncRef` encodes (ref.func + funcref-table elem
    // populate consume this).
    const num_funcs = compiled.func_sigs.len;
    if (num_funcs > SCRATCH_MAX_FUNCS) return error.UnsupportedEntrySignature;
    // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    // Populate `FuncEntity.{funcptr, typeidx}` per ADR-0068 chunks
    // α/γ.2: locals → module body addr + canonical typeidx;
    // imports → dispatch[i] + 0 (canonical typeidx is the import's
    // declared sig; pre-resolution we leave 0 — γ-4 resolution
    // rebinds via the bridge thunk path).
    var fe_canon_types_arena = std.heap.ArenaAllocator.init(gpa);
    defer fe_canon_types_arena.deinit();
    const fe_ta = fe_canon_types_arena.allocator();
    var fe_canon_types: ?zwasm.parse.sections.Types = null;
    defer if (fe_canon_types) |*t| t.deinit();
    {
        var fe_module = try zwasm.parse.parser.parse(fe_ta, wasm_bytes);
        if (fe_module.find(.type)) |ts| {
            fe_canon_types = try zwasm.parse.sections.decodeTypes(fe_ta, ts.body);
        }
    }
    for (0..num_funcs) |i| {
        const f_off = compiled.module.func_offsets[i];
        const funcptr: usize = if (f_off == zwasm.engine.codegen.shared.linker.IMPORT_SENTINEL_OFFSET)
            (if (current_dispatch) |d| (if (i < d.len) d[i] else 0) else 0)
        else
            @intFromPtr(compiled.module.block.bytes.ptr + f_off);
        const raw_ti = compiled.func_typeidxs[i];
        const canon_ti: u32 = if (fe_canon_types) |t|
            zwasm.engine.codegen.shared.canonical_type.canonicalTypeidx(t.items, raw_ti)
        else
            raw_ti;
        scratch_func_entities[i] = .{
            .runtime = undefined,
            .func_idx = @intCast(i),
            .typeidx = canon_ti,
            .funcptr = funcptr,
        };
    }
    active_func_count = @intCast(num_funcs);

    // Always rebind entry 0 — the JIT call_indirect emit reads
    // `tables_jit_ci_ptr[0]` for table_idx == 0 callees only when
    // the multi-table slow path is taken; the legacy table-0 fast
    // path keeps using the scalar JitRuntime fields. The rebind
    // keeps the multi-table view coherent with the scalar fields.
    scratch_table_jit_ci[0] = .{
        .funcptr_base = table0_funcptrs.ptr,
        .typeidx_base = table0_typeidxs.ptr,
    };

    // Per-table refs population (mirror of
    // `runner.zig::setupRuntime`'s elem-section loop). `applyTable
    // InitForTable` already populated `funcptrs/typeidxs`; here we
    // populate `scratch_table_refs[k]` with the FuncEntity-ptr
    // encoding for funcref entries and `null_ref` (= 0) for empty
    // / externref / ref.null slots. The arena is sized at compile
    // time via SCRATCH_EXTRA_TABLE_CAPACITY so we slice per-table.
    if (num_tables == 0) {
        active_table_count = 0;
        // §9.9 / 9.9-l-1b-d093-d50: don't early-return here — modules
        // with no tables (e.g. bulk.4.wasm: memory + passive data
        // segment, no tables) still need elem + data segment scratch
        // populated. The elem path is a no-op when no element section
        // exists; the data path is what bulk + memory_init exercise.
        try populateElemSegments(gpa, wasm_bytes, compiled);
        try populateDataSegments(gpa, wasm_bytes);
        return;
    }
    var k: u32 = 0;
    while (k < num_tables) : (k += 1) {
        // §9.9 / 9.9-l-1b-d093-d47 (D-121 fix): table 0's actual
        // declared min — NOT `table0_funcptrs.len` (= the harness's
        // fixed scratch_table_capacity 32). Pre-d-47 used the
        // scratch capacity for table 0, so `table.get`'s bounds
        // check on table 0 (e.g. `table_get.wast` `get-externref(2)`
        // with a `(table 2 externref)`-declared table) passed
        // through bounds (2 < 32) instead of trapping (2 >= 2).
        // The legacy `JitRuntime.table_size` scalar (consumed by
        // `call_indirect`'s W25 bounds check) stays at
        // scratch capacity — call_indirect's sig check still
        // traps on OOB indices because the typeidx slot is
        // sentinel-filled (maxInt = always-mismatch); the trap
        // reason is sig-mismatch instead of out-of-bounds, which
        // spec assert_trap accepts.
        const tbl_min = runner_mod.declaredTableMin(gpa, wasm_bytes, k);
        if (tbl_min > SCRATCH_EXTRA_TABLE_CAPACITY) return error.UnsupportedEntrySignature;
        const tbl_max = runner_mod.declaredTableMax(gpa, wasm_bytes, k);
        if (k > 0) {
            const fp_slice = scratch_extra_funcptrs[k - 1][0..tbl_min];
            const ti_slice = scratch_extra_typeidxs[k - 1][0..tbl_min];
            if (tbl_min > 0) {
                try runner_mod.applyTableInitForTableCtx(gpa, wasm_bytes, compiled, k, fp_slice, ti_slice, gctx);
                // §9.9-III (c)-2.3-γ-5 multi-table extension: patch
                // import-bearing entries in table k's funcptr slice
                // with resolved bridge-thunk addresses from
                // `current_dispatch`. Mirrors the table-0 patch in
                // each on_module_loaded; here for tables 1..N.
                if (current_dispatch) |disp| {
                    try runner_mod.patchTableImportFuncptrsCtx(
                        gpa,
                        wasm_bytes,
                        compiled.num_imports,
                        k,
                        disp,
                        fp_slice,
                        gctx,
                    );
                }
            }
            scratch_table_jit_ci[k] = .{
                .funcptr_base = if (tbl_min == 0) @as([*]const u64, undefined) else fp_slice.ptr,
                .typeidx_base = if (tbl_min == 0) @as([*]const u32, undefined) else ti_slice.ptr,
            };
        }
        const refs_slice = scratch_table_refs[k][0..tbl_min];
        @memset(refs_slice, Value.null_ref);
        try populateTableRefs(gpa, wasm_bytes, compiled, k, refs_slice, gctx);
        // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
        // funcref tables alias the funcptrs/extra_funcptrs slice;
        // externref tables get a null funcptrs base so the JIT
        // mirror guard skips deref (externref handles are opaque).
        const tbl_is_funcref = blk_ft: {
            var ta_arena = std.heap.ArenaAllocator.init(gpa);
            defer ta_arena.deinit();
            const ta = ta_arena.allocator();
            var module = zwasm.parse.parser.parse(ta, wasm_bytes) catch break :blk_ft true;
            const sec = module.find(.table) orelse break :blk_ft true;
            var tabs = zwasm.parse.sections.decodeTables(ta, sec.body) catch break :blk_ft true;
            defer tabs.deinit();
            break :blk_ft (k < tabs.items.len and tabs.items[k].elem_type.isFuncref());
        };
        const fp_slice: [*]allowzero u64 = if (!tbl_is_funcref)
            @ptrFromInt(0)
        else if (k == 0)
            table0_funcptrs.ptr
        else blk: {
            const slice = scratch_extra_funcptrs[k - 1][0..tbl_min];
            break :blk if (tbl_min == 0) @as([*]u64, undefined) else slice.ptr;
        };
        scratch_tables_descriptor[k] = .{
            .refs = if (tbl_min == 0) @as([*]u64, undefined) else refs_slice.ptr,
            .len = tbl_min,
            .max = tbl_max orelse entry.table_no_max,
            .funcptrs = fp_slice,
        };
    }
    active_table_count = num_tables;

    // §9.9 / 9.9-l-1b-d093-d49 (D-123): populate elem-segment
    // descriptor + refs arena + dropped flag table so JIT
    // `table.init` / `elem.drop` can index them via
    // `JitRuntime.elem_segments_ptr` / `elem_dropped_ptr`.
    // Mirrors `runner.zig::setupRuntime`'s elem_segments_buf
    // path. Pre-d-49 these were `undefined` and JIT body SEGV'd
    // on first deref.
    try populateElemSegments(gpa, wasm_bytes, compiled);
    // §9.9 / 9.9-l-1b-d093-d50 (D-119/D-120): mirror for data
    // segments — JIT `memory.init` reads `data_segments_ptr[i]`
    // for the source bytes ptr+len; `data.drop` flips
    // `data_dropped_ptr[i]`. Pre-d-50 both were `undefined`.
    try populateDataSegments(gpa, wasm_bytes);
}

/// §9.9 / 9.9-l-1b-d093-d49 (D-123): mirror of
/// `runner.zig::setupRuntime`'s elem_segments_buf population.
/// Walks the element section, writes per-segment `ElemSlice`
/// descriptors into `scratch_elem_segments`, packs the
/// `Value.ref`-encoded funcref pointers into a flat
/// `scratch_elem_refs_arena`, and zero-inits the dropped flags.
/// Externref segments and `ref.null` entries leave the slot at
/// `Value.null_ref` (the spec runner can't bind host externrefs).
fn populateElemSegments(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
) anyerror!void {
    @memset(scratch_elem_dropped[0..], 0);
    active_elem_segments_count = 0;

    var temp_arena = std.heap.ArenaAllocator.init(gpa);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try @import("zwasm").parse.parser.parse(ta, wasm_bytes);
    const sec = module.find(.element) orelse return;
    var elems = try @import("zwasm").parse.sections.decodeElement(ta, sec.body);
    defer elems.deinit();

    if (elems.items.len > SCRATCH_MAX_ELEM_SEGMENTS) return error.UnsupportedEntrySignature;

    var off: usize = 0;
    for (elems.items, 0..) |seg, i| {
        const seg_len: u32 = @intCast(seg.funcidxs.len);
        if (off + seg_len > SCRATCH_ELEM_REFS_CAPACITY) return error.UnsupportedEntrySignature;
        scratch_elem_segments[i] = .{
            .refs = scratch_elem_refs_arena[off..].ptr,
            .len = seg_len,
        };
        for (seg.funcidxs, 0..) |fidx, k| {
            if (fidx == std.math.maxInt(u32)) {
                scratch_elem_refs_arena[off + k] = Value.null_ref;
            } else if (zwasm.parse.sections.elemEntryIsGlobalGet(fidx)) {
                // Close-plan §6 (j) Step B cohort 6 — leave as
                // null_ref in the elem-segment scratch. Active
                // segments are marked dropped just below so JIT
                // table.init / elem.drop never reads this slot;
                // the table itself was populated with the resolved
                // FuncEntity ptr by populateTableRefs. Passive /
                // declarative globals.get-elems aren't supported
                // by the current corpus (would need ctx-aware
                // resolution here too).
                scratch_elem_refs_arena[off + k] = Value.null_ref;
            } else if (fidx >= compiled.func_sigs.len) {
                return error.UnsupportedEntrySignature;
            } else {
                scratch_elem_refs_arena[off + k] = @intFromPtr(&scratch_func_entities[fidx]);
            }
        }
        // Wasm 2.0 §4.5.4: active elem segments are consumed at
        // instantiation — their effective size becomes 0 for any
        // subsequent `table.init`. Mark them dropped so the JIT's
        // `elem_dropped[i]`-driven `seg_len → 0` CSEL fires.
        // Declarative segments are also effectively-dropped.
        // Passive segments stay live until an explicit `elem.drop`.
        if (seg.kind != .passive) scratch_elem_dropped[i] = 1;
        off += seg_len;
    }
    active_elem_segments_count = @intCast(elems.items.len);
}

/// §9.9 / 9.9-l-1b-d093-d50 (D-119/D-120): mirror of
/// `runner.zig::setupRuntime`'s data_segments_buf population.
/// Walks the data section, writes per-segment `SegmentSlice`
/// descriptors into `scratch_data_segments`, packs the segment
/// bytes into a flat `scratch_data_arena`, and flips active +
/// declarative segments to dropped per Wasm 2.0 §4.5.5 (active
/// data segments are consumed at instantiation).
fn populateDataSegments(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
) anyerror!void {
    @memset(scratch_data_dropped[0..], 0);
    active_data_segments_count = 0;

    var temp_arena = std.heap.ArenaAllocator.init(gpa);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try @import("zwasm").parse.parser.parse(ta, wasm_bytes);
    const sec = module.find(.data) orelse return;
    var datas = try @import("zwasm").parse.sections.decodeData(ta, sec.body);
    defer datas.deinit();

    if (datas.items.len > SCRATCH_MAX_DATA_SEGMENTS) return error.UnsupportedEntrySignature;

    var off: usize = 0;
    for (datas.items, 0..) |seg, i| {
        const seg_len: u64 = @intCast(seg.bytes.len);
        if (off + seg_len > SCRATCH_DATA_BYTES_CAPACITY) return error.UnsupportedEntrySignature;
        @memcpy(scratch_data_arena[off..][0..seg.bytes.len], seg.bytes);
        scratch_data_segments[i] = .{
            .ptr = scratch_data_arena[off..].ptr,
            .len = seg_len,
        };
        // Wasm 2.0 §4.5.5: active data segments are consumed at
        // instantiation — applyActiveDataSegments has already
        // copied their bytes into linear memory; subsequent
        // `memory.init` against them must trap on n>0 because
        // the segment's effective size is 0.
        if (seg.kind == .active) scratch_data_dropped[i] = 1;
        off += seg.bytes.len;
    }
    active_data_segments_count = @intCast(datas.items.len);
}

/// §9.9 / 9.9-l-1b-d093-d43 (D-113): populate `refs_out` with
/// `Value.ref`-encoded FuncEntity pointers for the active
/// element segments targeting `tableidx`. Mirrors the elem-
/// section half of `runner.zig::setupRuntime`'s table_refs
/// arena fill. Null funcidxs (`ref.null funcref`) leave the
/// slot at `Value.null_ref`. Externref tables get no writes
/// here (their refs stay null — the spec runner can't bind
/// host `ref.extern N` values, distilled as `skip-impl
/// non-scalar-arg`).
fn populateTableRefs(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    tableidx: u32,
    refs_out: []u64,
    gctx: ?zwasm.engine.runner_validate.GlobalsCtx,
) anyerror!void {
    var temp_arena = std.heap.ArenaAllocator.init(gpa);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try @import("zwasm").parse.parser.parse(ta, wasm_bytes);
    const sections = @import("zwasm").parse.sections;
    const section = module.find(.element) orelse return;
    var elems = try sections.decodeElement(ta, section.body);
    defer elems.deinit();
    for (elems.items) |seg| {
        if (seg.kind != .active) continue;
        if (seg.tableidx != tableidx) continue;
        const off = zwasm.engine.runner_validate.evalConstI32ExprCtx(seg.offset_expr, gctx) catch return error.UnsupportedEntrySignature;
        if (off < 0) return error.UnsupportedEntrySignature;
        const base: usize = @intCast(off);
        if (base + seg.funcidxs.len > refs_out.len) return error.UnsupportedEntrySignature;
        for (seg.funcidxs, 0..) |fidx, i| {
            if (fidx == std.math.maxInt(u32)) {
                refs_out[base + i] = Value.null_ref;
                continue;
            }
            // Close-plan §6 (j) Step B cohort 6 — global.get N marker.
            // The imported funcref global's value at
            // scratch_globals[offsets[N]] IS the FuncEntity pointer
            // (resolved at exporter side via resolveFuncrefGlobals,
            // copied via applyImportedGlobalsFromRegistered).
            if (zwasm.parse.sections.elemEntryIsGlobalGet(fidx)) {
                const c = gctx orelse return error.UnsupportedEntrySignature;
                const gidx = zwasm.parse.sections.elemEntryGlobalIdx(fidx);
                if (gidx >= c.num_imports or gidx >= c.offsets.len) return error.UnsupportedEntrySignature;
                const g_off = c.offsets[gidx];
                if (g_off + 8 > c.buf.len) return error.UnsupportedEntrySignature;
                refs_out[base + i] = std.mem.readInt(u64, c.buf[g_off..][0..8], .little);
                continue;
            }
            if (fidx >= compiled.func_sigs.len) return error.UnsupportedEntrySignature;
            refs_out[base + i] = @intFromPtr(&scratch_func_entities[fidx]);
        }
    }
}

/// Capacity for the spec-runner's `host_dispatch_base` stub
/// array. Spec corpus modules typically import 0–2 functions
/// (start.wast's `spectest.print_i32`); 64 is comfortable
/// headroom and the JIT body's import-call emit caps `idx*8`
/// at imm12 budget (32760), which is far above 64.
pub const HOST_DISPATCH_STUB_CAPACITY: u32 = 64;

/// Static stub table — every slot points to `hostImportTrapStub`.
/// Populated once at module load via `initHostDispatchStubs()`.
pub var host_dispatch_stubs: [HOST_DISPATCH_STUB_CAPACITY]usize = undefined;

/// Initialise the stub table — called once from each runner main
/// before the corpus loop starts. Idempotent.
pub fn initHostDispatchStubs() void {
    for (&host_dispatch_stubs) |*slot| {
        slot.* = @intFromPtr(&hostImportTrapStub);
    }
}

// §9.9-III (c)-2.3-β-2b per ADR-0066: module-scope dispatch state.
// Allocated at the `.module` directive after compileWasm; freed at
// each module-switch + runCorpus deinit. When `current_dispatch`
// is non-null, makeJitRuntime callers pass it via
// `currentDispatchView()` so each fixture's JitRuntime sees the
// per-module dispatch slice (with `hostImportTrapStub` defaults
// for unresolved slots + thunk addresses for cross-module-resolved
// slots). When null (no module yet, or last module had zero
// imports), makeJitRuntime falls back to the static
// `host_dispatch_stubs` global — the pre-(c)-2.3 trap-stub
// behaviour preserved for the import-free majority.
pub var current_dispatch: ?[]usize = null;
pub var current_thunk_arena: jit_mem.JitBlock = .{ .bytes = &[_:0]u8{} };

// Close-plan §6 (j) Step B cohort 1 — corpus-scope handle on the
// runCorpus-local `registered` map so per-module `on_module_loaded`
// callbacks can populate the importer's `scratch_globals` from
// registered exporter values (`applyImportedGlobalsFromRegistered`).
// Set right after the spectest auto-register block in `runCorpus`;
// reset to null at runCorpus deinit.
pub var current_registered: ?*std.StringHashMapUnmanaged(RegisteredExporter) = null;

// Close-plan §6 (j) Step B cohort 1-residual — current `.wasm`
// filename within the active manifest, so per-module FAIL lines
// (data-init / table-init / multi-table-init / patch-funcptrs /
// resolve-funcref-globals / imported-globals-init) can identify
// the specific fixture instead of bisecting across the whole
// manifest. Set in runCorpus's `module` directive arm; reset to
// `null` at the next directive.
pub var current_module_file: ?[]const u8 = null;

/// Const view of `current_dispatch` for passing to
/// `makeJitRuntime`'s `dispatch_override` parameter.
pub fn currentDispatchView() ?[]const usize {
    return current_dispatch;
}

/// Free the per-module dispatch slice + thunk arena. Idempotent:
/// both `null` dispatch and the empty-sentinel arena are no-ops.
/// Called at each module-switch (before allocating the new
/// module's state) and at runCorpus deinit.
pub fn resetModuleDispatch(allocator: std.mem.Allocator) void {
    if (current_dispatch) |d| {
        allocator.free(d);
        current_dispatch = null;
    }
    shared_thunk.freeArena(current_thunk_arena);
    current_thunk_arena = .{ .bytes = &[_:0]u8{} };
}

// ============================================================
// §9.9-III chunk (c)-2.3: Cross-module import resolver substrate
// ============================================================
//
// Per ADR-0066: each `(register "M" $inst)` directive binds the
// current module's wasm bytes under alias "M". Subsequent
// importer modules with `(import "M" "f" (func ...))` resolve
// against this registry via a lazy-compile path: the first
// import that needs `M` triggers compileWasm of the exporter
// bytes; the resulting `CompiledWasm` is cached on the
// `RegisteredExporter` for the runCorpus session. Per-fixture
// thunk wiring happens in (c)-2.3 main when the resolver lands.
//
// This shape replaces the bytes-only map from (c)-1c. The
// struct is additive — current behaviour (no cross-module
// dispatch yet) is preserved as long as `compiled` stays null.
// Export-name → funcidx lookup uses the existing public API
// `runner_mod.findExportFunc` (no duplicate helper here).

/// Lazy-compiled cache for one registered exporter module.
/// Replaces the bytes-only value type that (c)-1c used. The
/// `bytes_owned` field is the same payload (gpa.dupe of the
/// importer-side `current_wasm`); `compiled` becomes non-null
/// the first time the resolver needs to look up an export's
/// JIT entry address.
pub const RegisteredExporter = struct {
    bytes_owned: []u8,
    /// Lazy: populated by (c)-2.3 resolver on first import-
    /// resolution that targets this exporter alias. Stays null
    /// for fixtures that register a module but no subsequent
    /// fixture imports from it.
    compiled: ?runner_mod.CompiledWasm = null,
    /// Lazy: per-exporter JitRuntime instance. Heap-allocated
    /// so the pointer remains stable across `registered`
    /// HashMap rehashes (struct-field pointers would invalidate
    /// on rehash). Embedded as `callee_rt` in every thunk that
    /// targets an export of this module.
    rt: ?*entry.JitRuntime = null,
    /// §9.9-III (c)-2.3-γ-1: per-exporter globals byte buffer.
    /// Allocated lazily in `ensureCompiledAndRt` sized to the
    /// exporter's `globals_valtypes.len * 16`, populated via
    /// `runner_mod.applyDefinedGlobalsInit`. The pointer is
    /// then wired into `rt.globals_base` so a cross-module
    /// callee touching `global.get` / `global.set` reads /
    /// writes the exporter's own globals (instead of the
    /// importer's static `scratch_globals`). Null until
    /// `ensureCompiledAndRt` runs; empty slice when the
    /// exporter has no defined globals.
    scratch_globals: ?[]u8 = null,
    /// §9.9-III (c)-2.3-γ-2: per-exporter linear memory pool.
    /// Allocated lazily in `ensureCompiledAndRt` sized to the
    /// declared `(memory min ...)` pages × 64 KiB, capped at
    /// `EXPORTER_MEMORY_CAPACITY` until a corpus fixture
    /// demands more. Populated via
    /// `runner_mod.applyActiveDataSegments`. The pointer is
    /// then wired into `rt.vm_base` + `rt.mem_limit` so a
    /// cross-module callee touching `memory.load` /
    /// `memory.store` reads / writes the exporter's own pool
    /// (instead of the importer's static `growable_memory`).
    /// Null when the exporter has no memory section.
    scratch_memory: ?[]u8 = null,
    /// §9.9-III (c)-2.3-γ-3: per-exporter table-0 funcptrs /
    /// typeidxs. Allocated lazily in `ensureCompiledAndRt`
    /// sized to the declared `(table min funcref)` count, capped
    /// at `EXPORTER_TABLE_CAPACITY`. Populated via
    /// `runner_mod.applyTableInit` (table-0 only); wired into
    /// `rt.funcptr_base` / `rt.typeidx_base` / `rt.table_size`
    /// so a cross-module callee doing `call_indirect` against
    /// table-0 reads the exporter's own funcref entries +
    /// canonical typeidxs (instead of the importer's static
    /// `scratch_funcptrs`). Null when the exporter has no
    /// table section. Multi-table (tables 1..N) support is
    /// γ-3.c — deferred until a corpus fixture demands it.
    scratch_funcptrs: ?[]u64 = null,
    scratch_typeidxs: ?[]u32 = null,
    /// §9.9-III (c)-2.3-γ-3.b-i: per-exporter `FuncEntity` array.
    /// `ref.func i` encodes `@intFromPtr(&func_entities[i])` so
    /// the JIT emit needs a stable `func_entities_ptr` that the
    /// callee can index into. Allocated lazily in
    /// `ensureCompiledAndRt` sized to `compiled.func_sigs.len`
    /// (covers both imports and defined funcs in wasm-space).
    /// Populated identically to the importer-side
    /// `scratch_func_entities` in `setupMultiTableScratch`:
    /// `{runtime = undefined, func_idx = i}`. The `runtime`
    /// field is a `*Runtime` placeholder — the spec runner
    /// doesn't materialise a `Runtime`; only the FuncEntity
    /// address matters for funcref encoding.
    scratch_func_entities: ?[]@import("zwasm").runtime.FuncEntity = null,
    /// §9.9-III (c)-2.3-γ-3.b-ii: per-exporter element-segment
    /// state. `scratch_elem_segments[i]` carries `{refs, len}`
    /// pointing into `scratch_elem_refs_arena` (flat
    /// funcref-encoded u64s); `scratch_elem_dropped[i]` is the
    /// 0/1 dropped flag consumed by JIT `table.init` /
    /// `elem.drop`. Active + declarative segments are marked
    /// dropped at instantiation per Wasm 2.0 §4.5.4. Null when
    /// the exporter has no element section.
    scratch_elem_segments: ?[]entry.ElemSlice = null,
    scratch_elem_dropped: ?[]u8 = null,
    scratch_elem_refs_arena: ?[]u64 = null,
    /// §9.9-III (c)-2.3-γ-3.b-ii: per-exporter data-segment
    /// state (mirror of elem). `scratch_data_segments[i].ptr`
    /// points into `scratch_data_bytes_arena`; active segments
    /// are dropped at instantiation per Wasm 2.0 §4.5.5. Null
    /// when the exporter has no data section.
    scratch_data_segments: ?[]entry.SegmentSlice = null,
    scratch_data_dropped: ?[]u8 = null,
    scratch_data_bytes_arena: ?[]u8 = null,

    pub fn deinit(self: *RegisteredExporter, allocator: std.mem.Allocator) void {
        if (self.scratch_data_bytes_arena) |a| allocator.free(a);
        if (self.scratch_data_dropped) |d| allocator.free(d);
        if (self.scratch_data_segments) |s| allocator.free(s);
        if (self.scratch_elem_refs_arena) |a| allocator.free(a);
        if (self.scratch_elem_dropped) |d| allocator.free(d);
        if (self.scratch_elem_segments) |s| allocator.free(s);
        if (self.scratch_func_entities) |fe| allocator.free(fe);
        if (self.scratch_typeidxs) |t| allocator.free(t);
        if (self.scratch_funcptrs) |f| allocator.free(f);
        if (self.scratch_memory) |m| {
            // Same alignment story as `scratch_globals` above —
            // `alignedAlloc(u8, .of(u128), ...)` at line ~990.
            const aligned: []align(@alignOf(u128)) u8 = @alignCast(m);
            allocator.free(aligned);
        }
        if (self.scratch_globals) |g| {
            // `scratch_globals` is allocated via
            // `alignedAlloc(u8, .of(u128), ...)` (line ~962);
            // Zig 0.16's DebugAllocator records the original
            // 16-byte alignment and rejects the `free` call when
            // the slice's alignment info is dropped to 1. Recast
            // back to the original alignment before freeing.
            const aligned: []align(@alignOf(u128)) u8 = @alignCast(g);
            allocator.free(aligned);
        }
        if (self.rt) |r| allocator.destroy(r);
        if (self.compiled) |*c| c.deinit(allocator);
        allocator.free(self.bytes_owned);
    }

    /// Lazy-compile + allocate JitRuntime on first lookup.
    /// Subsequent calls return the cached pair.
    pub fn ensureCompiledAndRt(
        self: *RegisteredExporter,
        allocator: std.mem.Allocator,
    ) !void {
        if (self.compiled == null) {
            self.compiled = try runner_mod.compileWasm(allocator, self.bytes_owned);
        }
        const compiled = &self.compiled.?;
        if (self.scratch_globals == null) {
            // 16-byte align so v128 globals' MOVUPS / LDR Q
            // reads / writes match the JIT alignment contract,
            // mirroring the importer-side `scratch_globals: [256]u8
            // align(16)` shape in spec_assert_runner_non_simd.
            // Post-ADR-0110 widen: every global occupies uniform 16 bytes;
            // total size = globals_valtypes.len * 16 (16-byte aligned).
            const globals_byte_size: u32 = @intCast(compiled.globals_valtypes.len * 16);
            const buf = try allocator.alignedAlloc(u8, .of(u128), globals_byte_size);
            @memset(buf, 0);
            try runner_mod.applyDefinedGlobalsInit(
                allocator,
                self.bytes_owned,
                compiled.globals_offsets,
                compiled.globals_valtypes,
                buf,
                compiled.num_global_imports,
            );
            self.scratch_globals = buf;
        }
        if (self.scratch_memory == null) {
            const mem_limits = extractMemoryLimits(allocator, self.bytes_owned);
            if (mem_limits.min > 0) {
                const declared_bytes: usize = @as(usize, mem_limits.min) * 65536;
                const capped = @min(declared_bytes, EXPORTER_MEMORY_CAPACITY);
                // 16-byte align so v128 MOVUPS / LDR Q from the
                // memory pool stays aligned (parity with the
                // importer's `growable_memory align(16)` shape).
                const buf = try allocator.alignedAlloc(u8, .of(u128), capped);
                @memset(buf, 0);
                try runner_mod.applyActiveDataSegments(allocator, self.bytes_owned, buf);
                self.scratch_memory = buf;
            }
        }
        if (self.scratch_funcptrs == null) {
            const table_min = extractTable0Min(allocator, self.bytes_owned);
            if (table_min > 0) {
                const capped: usize = @min(table_min, EXPORTER_TABLE_CAPACITY);
                const funcptrs = try allocator.alloc(u64, capped);
                errdefer allocator.free(funcptrs);
                const typeidxs = try allocator.alloc(u32, capped);
                errdefer allocator.free(typeidxs);
                try runner_mod.applyTableInit(
                    allocator,
                    self.bytes_owned,
                    compiled,
                    funcptrs,
                    typeidxs,
                );
                self.scratch_funcptrs = funcptrs;
                self.scratch_typeidxs = typeidxs;
            }
        }
        if (self.scratch_func_entities == null) {
            const num_funcs = compiled.func_sigs.len;
            if (num_funcs > 0) {
                const FuncEntity = @import("zwasm").runtime.FuncEntity;
                const fe = try allocator.alloc(FuncEntity, num_funcs);
                // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
                // RegisteredExporter scratch path — mirror the
                // setupMultiTableScratch funcptr split (locals vs
                // imports). `dispatch_override` is not yet plumbed here,
                // so imports default to 0; the chunk β/γ wire-up
                // refreshes this once cross-module resolution lands.
                // Decode types section once for canonical typeidx.
                var fe_canon_arena = std.heap.ArenaAllocator.init(allocator);
                defer fe_canon_arena.deinit();
                const fe_ta = fe_canon_arena.allocator();
                var fe_canon_types: ?zwasm.parse.sections.Types = null;
                defer if (fe_canon_types) |*t| t.deinit();
                {
                    var fe_module = try zwasm.parse.parser.parse(fe_ta, self.bytes_owned);
                    if (fe_module.find(.type)) |ts| {
                        fe_canon_types = try zwasm.parse.sections.decodeTypes(fe_ta, ts.body);
                    }
                }
                for (fe, 0..) |*slot, i| {
                    const f_off = compiled.module.func_offsets[i];
                    const funcptr: usize = if (f_off == zwasm.engine.codegen.shared.linker.IMPORT_SENTINEL_OFFSET)
                        0
                    else
                        @intFromPtr(compiled.module.block.bytes.ptr + f_off);
                    const raw_ti = compiled.func_typeidxs[i];
                    const canon_ti: u32 = if (fe_canon_types) |t|
                        zwasm.engine.codegen.shared.canonical_type.canonicalTypeidx(t.items, raw_ti)
                    else
                        raw_ti;
                    slot.* = .{
                        .runtime = undefined,
                        .func_idx = @intCast(i),
                        .typeidx = canon_ti,
                        .funcptr = funcptr,
                    };
                }
                self.scratch_func_entities = fe;
                // Close-plan §6 (j) Step B cohort 6 — now that
                // scratch_func_entities exists, resolve funcref-typed
                // defined globals from raw funcidx (placeholder) to
                // FuncEntity*. The exporter's scratch_globals slots
                // (already populated by applyDefinedGlobalsInit above)
                // get rewritten in place. Subsequent
                // applyImportedGlobalsFromRegistered byte-copies the
                // resolved pointer to importer-side scratch_globals.
                if (self.scratch_globals) |gbuf| {
                    try runner_mod.resolveFuncrefGlobals(
                        allocator,
                        self.bytes_owned,
                        compiled.globals_offsets,
                        compiled.globals_valtypes,
                        gbuf,
                        fe,
                        compiled.num_global_imports,
                    );
                }
            }
        }
        if (self.scratch_elem_segments == null) {
            try self.populateElemSegments(allocator);
        }
        if (self.scratch_data_segments == null) {
            try self.populateDataSegments(allocator);
        }
        if (self.rt == null) {
            const rt_ptr = try allocator.create(entry.JitRuntime);
            const globals_buf = self.scratch_globals.?;
            const memory_buf: ?[]u8 = self.scratch_memory;
            const funcptrs_buf: ?[]u64 = self.scratch_funcptrs;
            const typeidxs_buf: ?[]u32 = self.scratch_typeidxs;
            const fe_buf = self.scratch_func_entities;
            const elem_segs = self.scratch_elem_segments;
            const elem_drop = self.scratch_elem_dropped;
            const data_segs = self.scratch_data_segments;
            const data_drop = self.scratch_data_dropped;
            // D-142 fix (B): every `[*]const T` field whose
            // backing buffer is absent gets `SAFE_STUB_PTR_ADDR`
            // (= 0x1000) instead of `undefined`. See the const's
            // docstring + `.claude/rules/zig_tips.md` for the
            // rationale. The non-null branches keep their real
            // pointer; only the fallback arm changed.
            const stub_ptr = @as(usize, SAFE_STUB_PTR_ADDR);
            rt_ptr.* = .{
                .vm_base = if (memory_buf) |m| m.ptr else @ptrFromInt(stub_ptr),
                .mem_limit = if (memory_buf) |m| m.len else 0,
                .funcptr_base = if (funcptrs_buf) |f| f.ptr else @ptrFromInt(stub_ptr),
                .table_size = if (funcptrs_buf) |f| @intCast(f.len) else 0,
                .typeidx_base = if (typeidxs_buf) |t| t.ptr else @ptrFromInt(stub_ptr),
                .trap_flag = 0,
                .globals_base = @ptrCast(@alignCast(globals_buf.ptr)),
                .globals_count = @intCast(globals_buf.len / @sizeOf(Value)),
                .host_dispatch_base = @ptrFromInt(stub_ptr),
                .host_dispatch_count = 0,
                .func_entities_ptr = if (fe_buf) |fe| @ptrCast(fe.ptr) else @ptrFromInt(stub_ptr),
                .func_entities_count = if (fe_buf) |fe| @intCast(fe.len) else 0,
                .elem_segments_ptr = if (elem_segs) |es| es.ptr else @ptrFromInt(stub_ptr),
                .elem_segments_count = if (elem_segs) |es| @intCast(es.len) else 0,
                .elem_dropped_ptr = if (elem_drop) |ed| ed.ptr else @ptrFromInt(stub_ptr),
                .elem_dropped_count = if (elem_drop) |ed| @intCast(ed.len) else 0,
                .data_segments_ptr = if (data_segs) |ds| ds.ptr else @ptrFromInt(stub_ptr),
                .data_segments_count = if (data_segs) |ds| @intCast(ds.len) else 0,
                .data_dropped_ptr = if (data_drop) |dd| dd.ptr else @ptrFromInt(stub_ptr),
                .data_dropped_count = if (data_drop) |dd| @intCast(dd.len) else 0,
            };
            self.rt = rt_ptr;
        }
    }

    /// §9.9-III (c)-2.3-γ-3.b-ii: mirror of the active-module
    /// `populateElemSegments` helper (lines ~640) — walks the
    /// exporter's element section + writes per-segment
    /// `ElemSlice` descriptors into the exporter's own
    /// `scratch_elem_segments` array. Each funcref entry encodes
    /// `@intFromPtr(&self.scratch_func_entities[fidx])` (γ-3.b-i
    /// guarantees that array is non-null before this runs).
    /// Active + declarative segments mark `scratch_elem_dropped[i]
    /// = 1` per Wasm 2.0 §4.5.4.
    fn populateElemSegments(self: *RegisteredExporter, allocator: std.mem.Allocator) !void {
        var temp = std.heap.ArenaAllocator.init(allocator);
        defer temp.deinit();
        const ta = temp.allocator();
        var module = zwasm.parse.parser.parse(ta, self.bytes_owned) catch return;
        const sec = module.find(.element) orelse return;
        var elems = zwasm.parse.sections.decodeElement(ta, sec.body) catch return;
        defer elems.deinit();
        if (elems.items.len == 0) return;

        var total_refs: usize = 0;
        for (elems.items) |seg| total_refs += seg.funcidxs.len;

        const segments = try allocator.alloc(entry.ElemSlice, elems.items.len);
        errdefer allocator.free(segments);
        const dropped = try allocator.alloc(u8, elems.items.len);
        errdefer allocator.free(dropped);
        @memset(dropped, 0);
        const refs_arena = try allocator.alloc(u64, @max(total_refs, 1));
        errdefer allocator.free(refs_arena);

        const fe = self.scratch_func_entities orelse return error.UnsupportedEntrySignature;
        var off: usize = 0;
        for (elems.items, 0..) |seg, i| {
            const seg_len: u32 = @intCast(seg.funcidxs.len);
            segments[i] = .{ .refs = refs_arena[off..].ptr, .len = seg_len };
            for (seg.funcidxs, 0..) |fidx, k| {
                if (fidx == std.math.maxInt(u32)) {
                    refs_arena[off + k] = Value.null_ref;
                } else if (fidx >= fe.len) {
                    return error.UnsupportedEntrySignature;
                } else {
                    refs_arena[off + k] = @intFromPtr(&fe[fidx]);
                }
            }
            if (seg.kind != .passive) dropped[i] = 1;
            off += seg_len;
        }

        self.scratch_elem_segments = segments;
        self.scratch_elem_dropped = dropped;
        self.scratch_elem_refs_arena = refs_arena;
    }

    /// §9.9-III (c)-2.3-γ-3.b-ii: mirror of `populateDataSegments`
    /// — walks the exporter's data section + packs segment bytes
    /// into `scratch_data_bytes_arena`. Active segments mark
    /// `scratch_data_dropped[i] = 1` per Wasm 2.0 §4.5.5.
    fn populateDataSegments(self: *RegisteredExporter, allocator: std.mem.Allocator) !void {
        var temp = std.heap.ArenaAllocator.init(allocator);
        defer temp.deinit();
        const ta = temp.allocator();
        var module = zwasm.parse.parser.parse(ta, self.bytes_owned) catch return;
        const sec = module.find(.data) orelse return;
        var datas = zwasm.parse.sections.decodeData(ta, sec.body) catch return;
        defer datas.deinit();
        if (datas.items.len == 0) return;

        var total_bytes: usize = 0;
        for (datas.items) |seg| total_bytes += seg.bytes.len;

        const segments = try allocator.alloc(entry.SegmentSlice, datas.items.len);
        errdefer allocator.free(segments);
        const dropped = try allocator.alloc(u8, datas.items.len);
        errdefer allocator.free(dropped);
        @memset(dropped, 0);
        const bytes_arena = try allocator.alloc(u8, @max(total_bytes, 1));
        errdefer allocator.free(bytes_arena);

        var off: usize = 0;
        for (datas.items, 0..) |seg, i| {
            @memcpy(bytes_arena[off..][0..seg.bytes.len], seg.bytes);
            segments[i] = .{ .ptr = bytes_arena[off..].ptr, .len = @intCast(seg.bytes.len) };
            if (seg.kind == .active) dropped[i] = 1;
            off += seg.bytes.len;
        }

        self.scratch_data_segments = segments;
        self.scratch_data_dropped = dropped;
        self.scratch_data_bytes_arena = bytes_arena;
    }
};

/// §9.9-III (c)-2.3 D-142 fix (B): safe sentinel address used in
/// place of `undefined` for every `[*]const T` field of
/// `JitRuntime` whose backing buffer is absent on the exporter.
/// Zig fills `undefined` with `0xAA` poison bytes in Debug; when
/// the JIT-emitted body of an importer dereferences a poisoned
/// `host_dispatch_base` after a cross-module bridge thunk returns,
/// the fault address `0xAA...AA + offset` shows up FAR from the
/// originating struct init (D-142, Mac aarch64 SEGV). `0x1000` is
/// inside the macOS / Linux NULL-page reserve so a stray
/// dereference still SEGVs — but at a predictable, debuggable
/// address rather than a Zig-poisoned one — and matches the
/// pre-existing `vm_base` fallback shape in `ensureCompiledAndRt`
/// (used since (c)-2.3-γ-2). See `.claude/rules/zig_tips.md`
/// § "`undefined` in extern struct fields".
pub const SAFE_STUB_PTR_ADDR: usize = 0x1000;

/// §9.9-III (c)-2.3-γ-2: per-exporter memory pool cap. 1 MiB
/// covers all currently-skipped `linking.wast` exporter modules
/// (Mm declares `(memory 1)` = 64 KiB, Ms similar). The importer-
/// side `GROWABLE_MEMORY_CAPACITY` (64 MiB) accommodates
/// `memory_grow.wast`'s grow(800) — an active-module-only path.
/// Cross-module exporters that exercise `memory.grow` would need
/// γ-2.b growth-aware sizing; deferred until a fixture demands it.
pub const EXPORTER_MEMORY_CAPACITY: usize = 1 << 20;

/// §9.9-III (c)-2.3-γ-3: per-exporter table-0 cap. Matches the
/// importer-side `scratch_table_capacity = 1024` for parity
/// with `table_copy.wast`-class fixtures (those run in
/// active-module mode and declare 128-entry tables; the 1024
/// ceiling has headroom for the few cross-module exporters
/// that exercise call_indirect).
pub const EXPORTER_TABLE_CAPACITY: usize = 1024;

/// §9.9-III (c)-2.3-γ-3: parse the wasm bytes' table section
/// (id=4) and return table-0's declared `min` count. Returns 0
/// when no table section exists or table-0 is absent (in which
/// case `ensureCompiledAndRt` skips allocating per-exporter
/// table buffers). Parse-error paths also return 0 — downstream
/// `compileWasm` will surface the real error.
pub fn extractTable0Min(allocator: std.mem.Allocator, wasm_bytes: []const u8) u32 {
    var module = zwasm.parse.parser.parse(allocator, wasm_bytes) catch return 0;
    defer module.deinit(allocator);
    const sec = module.find(.table) orelse return 0;
    var tables = zwasm.parse.sections.decodeTables(allocator, sec.body) catch return 0;
    defer tables.deinit();
    if (tables.items.len == 0) return 0;
    return std.math.cast(u32, tables.items[0].min) orelse std.math.maxInt(u32);
}

/// §9.9-III (c)-2.3-β-2 per ADR-0066: walk an importer's import
/// section, for each `(import "M" "f" (func ...))` whose alias
/// `M` is registered, lazy-compile the exporter + emit a bridge
/// thunk into the caller-provided arena, then plant the thunk's
/// byte address into `dispatch[import_idx]`. Non-spectest
/// imports without a registered exporter remain untouched
/// (caller's `hostImportTrapStub` slot stays — trap at call
/// time). Spectest imports are also untouched (kept as
/// host-trap stub slots; they're handled by the existing d-35
/// path when surfaced as `error.Trap`).
///
/// Returns the count of thunks emitted (= slots overwritten in
/// `dispatch`). `arena_slot_count` is the pre-allocated arena
/// capacity in thunk slots; resolver returns
/// `error.OutOfMemory` if the importer has more resolvable
/// cross-module imports than the arena can hold.
///
/// `(c)-2.3-β scope limitation`: when a registered exporter's
/// callee touches memory / globals / tables, runtime behaviour
/// is undefined (the heap-allocated zero-state JitRuntime
/// doesn't carry the exporter's actual state). Per the survey
/// note, this is acceptable for the simplest cross-module
/// fixtures; (c)-2.3-γ adds per-exporter backing buffers.
pub const ResolverError = error{
    OutOfMemory,
    ImportSectionDecodeFailed,
    ExporterCompileFailed,
    ExporterExportNotFound,
};

pub fn resolveCrossModuleImports(
    allocator: std.mem.Allocator,
    importer_wasm: []const u8,
    dispatch: []usize,
    thunk_arena: jit_mem.JitBlock,
    arena_slot_count: usize,
    registered: *std.StringHashMapUnmanaged(RegisteredExporter),
) ResolverError!u32 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var module = zwasm.parse.parser.parse(aa, importer_wasm) catch return ResolverError.ImportSectionDecodeFailed;
    defer module.deinit(aa);
    const sec = module.find(.import) orelse return 0;
    var imports = zwasm.parse.sections.decodeImports(aa, sec.body) catch return ResolverError.ImportSectionDecodeFailed;
    defer imports.deinit();

    var slot_idx: u32 = 0;
    var import_idx: u32 = 0;
    for (imports.items) |imp| {
        defer if (imp.kind == .func) {
            import_idx += 1;
        };
        if (imp.kind != .func) continue;
        // Skip spectest imports — they keep the existing host-
        // trap stub slot (d-35 path); not in scope for (c)-2.3-β.
        if (std.mem.eql(u8, imp.module, "spectest")) continue;

        // Look up the exporter. Missing alias = leave the trap
        // stub in place (caller's slot remains untouched).
        const entry_ptr = registered.getPtr(imp.module) orelse continue;

        // Lazy-compile + lazy-rt. Failure surfaces as
        // ExporterCompileFailed so caller can fall back to the
        // trap-stub slot (not handled here — caller decides).
        // `ensureCompiledAndRt` triggers `runner_mod.compileWasm`
        // which on Mac aarch64 ends in RX mode (linker.linkBlock
        // closes with `setExecutable`). The next `emitThunk` write
        // would SEGV against the importer's MAP_JIT arena page —
        // reflip the current thread back to writable BEFORE the
        // emit, regardless of how many ensures fire. `setWritable`
        // is a per-thread global flag toggle; idempotent and cheap.
        // No-op on Linux/Windows where pages are RWX.
        entry_ptr.ensureCompiledAndRt(allocator) catch return ResolverError.ExporterCompileFailed;
        const compiled = &entry_ptr.compiled.?;
        const callee_rt = entry_ptr.rt.?;

        // Find the named export in the exporter's export
        // section. Missing = ExporterExportNotFound (callee
        // promised it but doesn't deliver).
        const callee_funcidx = runner_mod.findExportFunc(aa, entry_ptr.bytes_owned, imp.name) catch return ResolverError.ExporterExportNotFound;
        const callee_entry_addr = compiled.module.entryAddr(callee_funcidx);

        // Emit thunk into the arena's next slot.
        if (slot_idx >= arena_slot_count) return ResolverError.OutOfMemory;
        const slot = shared_thunk.thunkSlot(thunk_arena, slot_idx);
        // §9.9-III (c)-2.3-γ-3.b-arm-fix: see ensureCompiledAndRt
        // comment above. Re-flip thread to writable in case the
        // exporter compile left us in RX. Safe on empty arena
        // (caller-checked slot_idx<arena_slot_count, so arena.len>0).
        jit_mem.setWritable(thunk_arena) catch return ResolverError.OutOfMemory;
        shared_thunk.emitThunk(slot, @intFromPtr(callee_rt), callee_entry_addr, compiled.func_sigs[callee_funcidx]);

        // Plant the thunk's address into the importer's dispatch
        // slot (host_dispatch_base[import_idx] view).
        if (import_idx < dispatch.len) {
            dispatch[import_idx] = @intFromPtr(slot.ptr);
        }
        slot_idx += 1;
    }
    return slot_idx;
}

/// Close-plan §6 (j) Step B cohort 4 — compute the effective
/// table-0 size as the spec sees it during instantiation. When
/// table-0 is imported and the exporter is registered, the
/// EXPORTER's actual table min is used (the importer's declared
/// min is just a lower bound). When table-0 is imported but no
/// exporter is registered, fall back to the importer's declared
/// min. When table-0 is defined locally, return the declared min.
/// Returns 0 when no table-0 exists at all.
pub fn effectiveTable0Min(
    allocator: std.mem.Allocator,
    importer_wasm: []const u8,
    registered: ?*const std.StringHashMapUnmanaged(RegisteredExporter),
) u32 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = zwasm.parse.parser.parse(ta, importer_wasm) catch return 0;
    if (module.find(.import)) |s| {
        var imports = zwasm.parse.sections.decodeImports(ta, s.body) catch return 0;
        defer imports.deinit();
        for (imports.items) |imp| {
            if (imp.kind != .table) continue;
            // First table import = table-0.
            if (registered) |reg| {
                if (reg.getPtr(imp.module)) |exp| {
                    return extractExporterTableMin(allocator, exp.bytes_owned, imp.name) orelse (std.math.cast(u32, imp.payload.table.min) orelse std.math.maxInt(u32));
                }
            }
            return std.math.cast(u32, imp.payload.table.min) orelse std.math.maxInt(u32);
        }
    }
    return runner_mod.declaredTableMin(allocator, importer_wasm, 0);
}

/// Close-plan §6 (j) Step B cohort 1-residual — effective memory-0
/// min in pages (each page = 64 KiB). Mirror of `effectiveTable0Min`:
/// imported memory resolves to the exporter's actual min (the
/// importer's declared min is a lower bound), defined memory uses
/// its declared min, no memory returns 0.
pub fn effectiveMemory0Min(
    allocator: std.mem.Allocator,
    importer_wasm: []const u8,
    registered: ?*const std.StringHashMapUnmanaged(RegisteredExporter),
) u64 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = zwasm.parse.parser.parse(ta, importer_wasm) catch return 0;
    if (module.find(.import)) |s| {
        var imports = zwasm.parse.sections.decodeImports(ta, s.body) catch return 0;
        defer imports.deinit();
        for (imports.items) |imp| {
            if (imp.kind != .memory) continue;
            if (registered) |reg| {
                if (reg.getPtr(imp.module)) |exp| {
                    return extractExporterMemoryMin(allocator, exp.bytes_owned, imp.name) orelse imp.payload.memory.min;
                }
            }
            return imp.payload.memory.min;
        }
    }
    const limits = extractMemoryLimits(allocator, importer_wasm);
    return limits.min;
}

/// Close-plan §6 (j) Step B cohort 5 — effective memory-0 max
/// in pages. Imported memory resolves to MIN(exporter actual max,
/// importer declared max) per Wasm spec instantiation semantics
/// (the importer's `(memory N M)` only states an upper acceptable
/// bound; the runtime cap is the actual exporter's max). Defined
/// memory uses its declared max. `null` when no memory exists or
/// neither side declares a max.
pub fn effectiveMemory0Max(
    allocator: std.mem.Allocator,
    importer_wasm: []const u8,
    registered: ?*const std.StringHashMapUnmanaged(RegisteredExporter),
) ?u64 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = zwasm.parse.parser.parse(ta, importer_wasm) catch return null;
    if (module.find(.import)) |s| {
        var imports = zwasm.parse.sections.decodeImports(ta, s.body) catch return null;
        defer imports.deinit();
        for (imports.items) |imp| {
            if (imp.kind != .memory) continue;
            const importer_max = imp.payload.memory.max;
            if (registered) |reg| {
                if (reg.getPtr(imp.module)) |exp| {
                    const exporter_max = extractExporterMemoryMax(allocator, exp.bytes_owned, imp.name);
                    if (exporter_max) |em| {
                        if (importer_max) |im| return @min(em, im);
                        return em;
                    }
                }
            }
            return importer_max;
        }
    }
    const limits = extractMemoryLimits(allocator, importer_wasm);
    return limits.max;
}

fn extractExporterMemoryMax(
    allocator: std.mem.Allocator,
    exporter_wasm: []const u8,
    export_name: []const u8,
) ?u64 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = zwasm.parse.parser.parse(ta, exporter_wasm) catch return null;
    const export_sec = module.find(.@"export") orelse return null;
    var exports = zwasm.parse.sections.decodeExports(ta, export_sec.body) catch return null;
    defer exports.deinit();
    var exp_mem_idx: ?u32 = null;
    for (exports.items) |e| {
        if (e.kind != .memory) continue;
        if (!std.mem.eql(u8, e.name, export_name)) continue;
        exp_mem_idx = e.idx;
        break;
    }
    const midx = exp_mem_idx orelse return null;
    var seen: u32 = 0;
    if (module.find(.import)) |s| {
        var imports = zwasm.parse.sections.decodeImports(ta, s.body) catch return null;
        defer imports.deinit();
        for (imports.items) |imp| {
            if (imp.kind != .memory) continue;
            if (seen == midx) return imp.payload.memory.max;
            seen += 1;
        }
    }
    const m_sec = module.find(.memory) orelse return null;
    var mems = zwasm.parse.sections.decodeMemory(ta, m_sec.body) catch return null;
    defer mems.deinit();
    const defined_idx = midx - seen;
    if (defined_idx >= mems.items.len) return null;
    return mems.items[defined_idx].max;
}

fn extractExporterMemoryMin(
    allocator: std.mem.Allocator,
    exporter_wasm: []const u8,
    export_name: []const u8,
) ?u64 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = zwasm.parse.parser.parse(ta, exporter_wasm) catch return null;
    const export_sec = module.find(.@"export") orelse return null;
    var exports = zwasm.parse.sections.decodeExports(ta, export_sec.body) catch return null;
    defer exports.deinit();
    var exp_mem_idx: ?u32 = null;
    for (exports.items) |e| {
        if (e.kind != .memory) continue;
        if (!std.mem.eql(u8, e.name, export_name)) continue;
        exp_mem_idx = e.idx;
        break;
    }
    const midx = exp_mem_idx orelse return null;
    var seen: u32 = 0;
    if (module.find(.import)) |s| {
        var imports = zwasm.parse.sections.decodeImports(ta, s.body) catch return null;
        defer imports.deinit();
        for (imports.items) |imp| {
            if (imp.kind != .memory) continue;
            if (seen == midx) return imp.payload.memory.min;
            seen += 1;
        }
    }
    const m_sec = module.find(.memory) orelse return null;
    var mems = zwasm.parse.sections.decodeMemory(ta, m_sec.body) catch return null;
    defer mems.deinit();
    const defined_idx = midx - seen;
    if (defined_idx >= mems.items.len) return null;
    return mems.items[defined_idx].min;
}

fn extractExporterTableMin(
    allocator: std.mem.Allocator,
    exporter_wasm: []const u8,
    export_name: []const u8,
) ?u32 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = zwasm.parse.parser.parse(ta, exporter_wasm) catch return null;
    const export_sec = module.find(.@"export") orelse return null;
    var exports = zwasm.parse.sections.decodeExports(ta, export_sec.body) catch return null;
    defer exports.deinit();
    var exp_table_idx: ?u32 = null;
    for (exports.items) |e| {
        if (e.kind != .table) continue;
        if (!std.mem.eql(u8, e.name, export_name)) continue;
        exp_table_idx = e.idx;
        break;
    }
    const tidx = exp_table_idx orelse return null;
    // Walk imports first (imports prefix in exporter's table index space).
    var seen: u32 = 0;
    if (module.find(.import)) |s| {
        var imports = zwasm.parse.sections.decodeImports(ta, s.body) catch return null;
        defer imports.deinit();
        for (imports.items) |imp| {
            if (imp.kind != .table) continue;
            if (seen == tidx) return std.math.cast(u32, imp.payload.table.min) orelse std.math.maxInt(u32);
            seen += 1;
        }
    }
    const t_sec = module.find(.table) orelse return null;
    var tables = zwasm.parse.sections.decodeTables(ta, t_sec.body) catch return null;
    defer tables.deinit();
    const defined_idx = tidx - seen;
    if (defined_idx >= tables.items.len) return null;
    return std.math.cast(u32, tables.items[defined_idx].min) orelse std.math.maxInt(u32);
}

/// Close-plan §6 (j) Step B cohort 1 — walk the importer's global
/// imports and write each resolved value into the importer's
/// `scratch_globals` byte buffer at the import-slot offset.
///
/// Both spectest and fixture-to-fixture imports route through the
/// same path: look up the exporter in `registered`, ensure the
/// exporter's own scratch_globals is populated
/// (`ensureCompiledAndRt` triggers `applyDefinedGlobalsInit` on
/// the exporter side), then copy 16 bytes from the exporter's
/// slot to the importer's slot. Per ADR-0110 §9.13-V every slot
/// is uniform 16 bytes regardless of valtype; scalar writes
/// land in the low 8 bytes (high 8 stay zero from `@memset`).
///
/// Imports without a matching registered exporter, or imports
/// whose exporter doesn't actually export the requested global,
/// are silently skipped — the importer's slot stays zero. Caller-
/// side const-expr eval surfaces the absence as
/// `UnsupportedConstExpr` only when a const-expr actually reads
/// the unpopulated slot (the bindable-imports pre-filter catches
/// the genuinely unlinkable cases before reaching this helper).
pub fn applyImportedGlobalsFromRegistered(
    allocator: std.mem.Allocator,
    importer_wasm: []const u8,
    importer_globals_offsets: []const u32,
    importer_globals_valtypes: []const zwasm.ir.zir.ValType,
    importer_globals_buf: []u8,
    importer_num_global_imports: u32,
    registered: *std.StringHashMapUnmanaged(RegisteredExporter),
) !void {
    if (importer_num_global_imports == 0) return;
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try zwasm.parse.parser.parse(ta, importer_wasm);
    defer module.deinit(ta);
    const sec = module.find(.import) orelse return;
    var imports = try zwasm.parse.sections.decodeImports(ta, sec.body);
    defer imports.deinit();

    var importer_global_slot: u32 = 0;
    for (imports.items) |imp| {
        if (imp.kind != .global) continue;
        defer importer_global_slot += 1;
        if (importer_global_slot >= importer_num_global_imports) break;

        const exporter_ptr = registered.getPtr(imp.module) orelse continue;
        exporter_ptr.ensureCompiledAndRt(allocator) catch continue;
        const exporter_compiled = &exporter_ptr.compiled.?;
        const exporter_globals_buf = exporter_ptr.scratch_globals orelse continue;

        const exporter_global_idx = zwasm.engine.export_lookup.findExportGlobal(
            ta,
            exporter_ptr.bytes_owned,
            imp.name,
        ) catch continue;
        if (exporter_global_idx >= exporter_compiled.globals_valtypes.len) continue;
        const exporter_vt = exporter_compiled.globals_valtypes[exporter_global_idx];
        const exporter_off = exporter_compiled.globals_offsets[exporter_global_idx];

        const importer_off = importer_globals_offsets[importer_global_slot];
        const importer_vt = importer_globals_valtypes[importer_global_slot];
        if (!importer_vt.eql(exporter_vt)) continue;
        // Post-ADR-0110 widen: uniform 16-byte slot stride; the
        // per-valtype 8/16 byte-copy switch collapsed (R-new-8).
        // Scalar values occupy the low 8 bytes; high 8 stay zero
        // (init via `@memset(buf, 0)` in setupRuntime).
        if (exporter_off + 16 > exporter_globals_buf.len) continue;
        if (importer_off + 16 > importer_globals_buf.len) continue;
        @memcpy(
            importer_globals_buf[importer_off..][0..16],
            exporter_globals_buf[exporter_off..][0..16],
        );
    }
}

/// §9.9 / 9.9-l-1b-d093-d8c (per ADR-0059): growable memory pool
/// for spec runners. Bumped from 64 → 1024 pages (64 MiB) at d-21
/// to accommodate `memory_grow.wast`'s `grow(800)` + `grow(1)`
/// (=804 pages cumulative). 16-byte-aligned so the same pool
/// serves both the scalar non-simd runner and the simd runner
/// (the latter needs 16-byte alignment for `MOVUPS` / `LDR Q`).
pub const GROWABLE_MEMORY_CAPACITY: usize = 1024 * 65536;
pub var growable_memory: [GROWABLE_MEMORY_CAPACITY]u8 align(16) = undefined;

/// Module-scoped current memory size in bytes. Persists across
/// `assert_return` invocations within one module (so `memory.grow`
/// growth is observable by subsequent asserts) and resets on
/// module load via `resetGrowableMemory`.
pub var current_mem_bytes: u64 = 65536;

/// Module-scoped memory-0 shared flag (1 = `(memory … shared)`), consumed by
/// `makeJitRuntime` as `mem0_shared` so `memory.atomic.wait{32,64}` does not
/// trap kind=15 on the corpus's shared-memory modules. Reset to 0 (non-shared)
/// by `resetGrowableMemory`; each runner's `on_module_loaded` overrides it from
/// the module's declared memory.
pub var current_mem_shared: u32 = 0;

/// d-20: module-scoped max-pages cap. Wasm 1.0 §4.2.8 says
/// `memory.grow` returns -1 when the declared module-level max
/// would be exceeded. `null` means no max (= `GROWABLE_MEMORY_CAPACITY`
/// is the effective cap). Reset by `resetGrowableMemoryWithMax`
/// from each runner's `on_module_loaded`.
pub var current_mem_max_pages: ?u32 = null;

/// Reset the growable pool to `initial_pages` (Wasm-1.0 64 KiB pages).
/// Called from each runner's `on_module_loaded` callback. Zeros the
/// in-use region so prior module state doesn't leak into this one.
pub fn resetGrowableMemory(initial_pages: u32) void {
    current_mem_shared = 0; // default non-shared; on_module_loaded overrides for shared memories
    current_mem_bytes = @as(u64, initial_pages) * 65536;
    if (current_mem_bytes > GROWABLE_MEMORY_CAPACITY) {
        // Pathological declared initial size — clamp + log. Spec
        // corpus is well under this cap; if a future module trips
        // this we'd surface as a bounds error on first load.
        current_mem_bytes = GROWABLE_MEMORY_CAPACITY;
    }
    @memset(growable_memory[0..@intCast(current_mem_bytes)], 0);
}

/// d-20: parse the wasm bytes' memory section to discover the
/// module-declared `(min, max)` pages. Returns `{min: 0, max:
/// null}` when no memory section exists or parsing fails.
/// Used by runners' `on_module_loaded` to seed
/// `resetGrowableMemory` + `current_mem_max_pages` from the
/// module's own declaration — matters for `memory_size.wast`
/// and `memory_grow.wast` where the max-pages cap gates whether
/// a `memory.grow` succeeds vs returns -1.
pub fn extractMemoryLimits(allocator: std.mem.Allocator, wasm_bytes: []const u8) struct { min: u64, max: ?u64 } {
    var module = zwasm.parse.parser.parse(allocator, wasm_bytes) catch return .{ .min = 0, .max = null };
    defer module.deinit(allocator);
    const sec = module.find(.memory) orelse return .{ .min = 0, .max = null };
    var memories = zwasm.parse.sections.decodeMemory(allocator, sec.body) catch return .{ .min = 0, .max = null };
    defer memories.deinit();
    if (memories.items.len == 0) return .{ .min = 0, .max = null };
    return .{ .min = memories.items[0].min, .max = memories.items[0].max };
}

/// Returns 1 if the module's DEFINED memory 0 is `(memory … shared)`, else 0.
/// Used by runners' `on_module_loaded` to seed `current_mem_shared` so
/// `memory.atomic.wait{32,64}` runs (vs trapping kind=15) on the atomics
/// corpus's shared-memory modules. Imported shared memory is out of scope (no
/// corpus module imports a shared memory); parse failure / no-memory → 0.
pub fn extractMemory0Shared(allocator: std.mem.Allocator, wasm_bytes: []const u8) u32 {
    var module = zwasm.parse.parser.parse(allocator, wasm_bytes) catch return 0;
    defer module.deinit(allocator);
    const sec = module.find(.memory) orelse return 0;
    var memories = zwasm.parse.sections.decodeMemory(allocator, sec.body) catch return 0;
    defer memories.deinit();
    if (memories.items.len == 0) return 0;
    return if (memories.items[0].shared) 1 else 0;
}

/// d-37: detect whether a module imports state the spec runner
/// cannot bind. Returns true if any import is either:
///   - a function from a non-`spectest` module whose alias is
///     NOT in `registered` (the (c)-2.3-β resolver binds func
///     imports against registered exporters via bridge thunks;
///     unregistered aliases remain unbindable),
///   - a table / memory / global from any module (spectest's
///     table / global / memory aren't bound by the runner; the
///     d-35 trap stub only covers function imports, and
///     (c)-2.3-γ — per-exporter backing buffers — is the chunk
///     that would relax non-func cross-module binding).
///
/// Used by the corpus loop to convert "can't satisfy this
/// module's imports" from FAIL to SKIP. The runner is a
/// no-host-binding spec assertion harness per ADR-0061; binding
/// real host state (multi-module register graphs, spectest's
/// magic table / global, WASI) is Track-D scope.
///
/// Parses just the import section header (raw byte walk; no
/// validator allocation). Any parse error → returns false (the
/// downstream compileWasm gets the same bytes and surfaces a
/// real error, so the runner still reports something useful
/// rather than swallowing the malformed input as SKIP).
/// §9.12-E / B147 (D-153 Part 2): predicate for "this spectest
/// non-func import (global / table / memory) IS bindable per the
/// canonical catalog at `test/spec/spectest_catalog.zig`". Returns
/// true iff the imp.name is in the catalog AND the imp.kind matches
/// AND (for globals) the imp.payload.global.valtype matches.
///
/// Not yet wired into `hasUnbindableImports` — the wholesale
/// `.table/.memory/.global => return true` rejection stays, so
/// SKIP-CROSS-MODULE-IMPORTS keeps firing for now. B148+ will:
/// (1) call this predicate from hasUnbindableImports's Path #2,
/// (2) populate importer-side storage (scratch_globals slot,
/// scratch_funcptrs region, growable_memory pool) with the
/// catalog initial values + correct widths at `.module` setup.
pub fn isSpectestNonFuncBindable(imp: zwasm.parse.sections.Import) bool {
    if (!std.mem.eql(u8, imp.module, "spectest")) return false;
    const e = spectest_catalog.findNonFuncExport(imp.name) orelse return false;
    return switch (imp.kind) {
        .func => false,
        .global => e.kind == .global and imp.payload.global.valtype.eql(e.valtype),
        .table => e.kind == .table,
        .memory => e.kind == .memory,
        .tag => false, // spectest exports no tags (10.E-xmodule-tags)
    };
}

/// §9.12-E / B155 (D-153 Step 6): write spectest global-import
/// initial values into the importer's `scratch_globals` buffer
/// at the offsets `compiled.globals_offsets[0..num_global_imports]`
/// carved out by `computeGlobalsLayout`'s imports prefix.
/// Spec testsuite values per `spectest_catalog`. For each
/// non-spectest or non-global import the function silently
/// skips (caller's responsibility to ensure imports are
/// bindable via `isSpectestNonFuncBindable` first). Wires up
/// at the spec runner's `on_module_loaded` callback before
/// `applyDefinedGlobalsInit` runs (write disjoint regions).
pub fn applySpectestGlobalImports(
    allocator: std.mem.Allocator,
    wasm_bytes: []const u8,
    globals_offsets: []const u32,
    scratch_globals: []u8,
) void {
    var module = zwasm.parse.parser.parse(allocator, wasm_bytes) catch return;
    defer module.deinit(allocator);
    const sec = module.find(.import) orelse return;
    var imports = zwasm.parse.sections.decodeImports(allocator, sec.body) catch return;
    defer imports.deinit();
    var gi: u32 = 0;
    for (imports.items) |imp| {
        if (imp.kind != .global) continue;
        defer gi += 1;
        if (!std.mem.eql(u8, imp.module, "spectest")) continue;
        const e = spectest_catalog.findNonFuncExport(imp.name) orelse continue;
        if (e.kind != .global) continue;
        if (gi >= globals_offsets.len) return;
        const off: usize = globals_offsets[gi];
        if (off + 8 > scratch_globals.len) return;
        std.mem.writeInt(u64, scratch_globals[off..][0..8], e.init_bits, .little);
    }
}

pub fn hasUnbindableImports(
    allocator: std.mem.Allocator,
    wasm_bytes: []const u8,
    registered: *const std.StringHashMapUnmanaged(RegisteredExporter),
) bool {
    var module = zwasm.parse.parser.parse(allocator, wasm_bytes) catch return false;
    defer module.deinit(allocator);
    const sec = module.find(.import) orelse return false;
    var imports = zwasm.parse.sections.decodeImports(allocator, sec.body) catch return false;
    defer imports.deinit();
    for (imports.items) |imp| {
        const is_spectest = std.mem.eql(u8, imp.module, "spectest");
        switch (imp.kind) {
            .func => {
                if (is_spectest) continue;
                if (registered.contains(imp.module)) continue;
                return true;
            },
            // SPIKE D-153 (close-plan §6 (j), 2026-05-21): non-func
            // imports are bindable IFF the source module is
            // registered (auto-registered for "spectest" at
            // runCorpus start). Previously: unconditional return
            // true. Triggers preparatory infra (B146-B158) for
            // global / table / memory binding.
            .table, .memory, .global, .tag => {
                if (registered.contains(imp.module)) continue;
                return true;
            },
        }
    }
    return false;
}

/// §9.12-E / B141 — link-time func-import type-check against
/// the registered exporter map. Returns `true` iff at least one
/// `func` import in `wasm_bytes` has an actual signature
/// (resolved via the registered exporter's wasm) that does NOT
/// match the importer's expected signature (resolved via the
/// importer's type section at `imp.payload.func_typeidx`).
/// A `true` return means assert_unlinkable PASSes ("incompatible
/// import type"); `false` means every bindable import's type
/// matches and the directive falls through to the SKIP path.
///
/// Non-func imports (table / memory / global) are intentionally
/// not checked here — Wasm 2.0 spec testsuite's assert_unlinkable
/// for those would have already been caught by `hasUnbindableImports`
/// at the SIMD/Wasm-2.0 runner level (Track-D scope).
pub fn hasIncompatibleImportType(
    allocator: std.mem.Allocator,
    wasm_bytes: []const u8,
    registered: *const std.StringHashMapUnmanaged(RegisteredExporter),
) bool {
    var module = zwasm.parse.parser.parse(allocator, wasm_bytes) catch return false;
    defer module.deinit(allocator);
    const sec = module.find(.import) orelse return false;
    var imports = zwasm.parse.sections.decodeImports(allocator, sec.body) catch return false;
    defer imports.deinit();
    // Importer's type section — resolves imp.payload.func_typeidx
    // to a FuncType (params + results). Optional: non-func-only
    // import modules legitimately have no type section (e.g.
    // `(module (import "test" "unknown" (global i32)))`).
    var types_opt: ?zwasm.parse.sections.Types = if (module.find(.type)) |s|
        zwasm.parse.sections.decodeTypes(allocator, s.body) catch null
    else
        null;
    defer if (types_opt) |*t| t.deinit();

    // spectest is registered at runCorpus start (line 3014); both
    // spectest and cross-module imports use the same generic
    // registered-map lookup path below. The check covers (a)
    // export presence by name (catches "unknown" / missing
    // exports), (b) kind compatibility (catches declaring non-func
    // as func and vice-versa), and (c) full type matching —
    // global valtype/mutable, table elem-type + limits-subsume,
    // memory limits-subsume — per Wasm 2.0 §3.4.10.
    for (imports.items) |imp| {
        const exp = registered.getPtr(imp.module) orelse continue;
        switch (imp.kind) {
            .func => {
                const types = types_opt orelse return true;
                const want_tidx = imp.payload.func_typeidx;
                if (want_tidx >= types.items.len) return true;
                const want = types.items[want_tidx];
                const exporter_ft = zwasm.engine.export_lookup.getExportFuncType(allocator, exp.bytes_owned, imp.name) catch return true;
                defer allocator.free(exporter_ft.params);
                defer allocator.free(exporter_ft.results);
                if (exporter_ft.params.len != want.params.len) return true;
                if (exporter_ft.results.len != want.results.len) return true;
                for (exporter_ft.params, want.params) |sp, wp| if (!sp.eql(wp)) return true;
                for (exporter_ft.results, want.results) |sr, wr| if (!sr.eql(wr)) return true;
            },
            .global, .table, .memory => {
                // Mirror `instantiate.zig::checkImportTypeMatches`
                // for non-func imports. Walk the exporter's export
                // section to locate the named export; verify kind
                // matches; cross-reference the exporter's
                // global / table / memory section (including
                // imports prefix) to read the actual type.
                if (crossModuleNonFuncImportMismatch(allocator, exp.bytes_owned, imp)) return true;
            },
            .tag => {
                // EH tag imports aren't link-type-checked in this
                // (non-EH) runner; the wasm-3.0 runner owns EH
                // cross-module tags (10.E-xmodule-tags).
            },
        }
    }
    return false;
}

/// Returns `true` when the exporter's `imp.name` export does not
/// match `imp` (kind mismatch, missing export, or type mismatch).
/// Mirror of `runtime/instance/instantiate.zig::checkImportTypeMatches`
/// non-func arms, adapted to read the exporter's wasm bytes
/// directly rather than a binding descriptor.
fn crossModuleNonFuncImportMismatch(
    allocator: std.mem.Allocator,
    exporter_bytes: []const u8,
    imp: zwasm.parse.sections.Import,
) bool {
    var module = zwasm.parse.parser.parse(allocator, exporter_bytes) catch return true;
    defer module.deinit(allocator);
    const export_sec = module.find(.@"export") orelse return true;
    var exports = zwasm.parse.sections.decodeExports(allocator, export_sec.body) catch return true;
    defer exports.deinit();
    var found: ?zwasm.parse.sections.Export = null;
    for (exports.items) |e| {
        if (std.mem.eql(u8, e.name, imp.name)) {
            found = e;
            break;
        }
    }
    const e = found orelse return true;
    // Kind compatibility — declaring `(global ...)` against a
    // table export is a kind mismatch.
    const want_kind_byte: u8 = switch (imp.kind) {
        .func => 0,
        .table => 1,
        .memory => 2,
        .global => 3,
        .tag => 4, // EH tag import kind byte (10.E-xmodule-tags)
    };
    const exp_kind_byte: u8 = switch (e.kind) {
        .func => 0,
        .table => 1,
        .memory => 2,
        .global => 3,
    };
    if (want_kind_byte != exp_kind_byte) return true;
    switch (imp.kind) {
        .func => return false, // handled by caller
        .global => {
            const want = imp.payload.global;
            return crossModuleGlobalMismatch(allocator, &module, e.idx, want.valtype, want.mutable);
        },
        .table => {
            const want = imp.payload.table;
            const want_min = std.math.cast(u32, want.min) orelse std.math.maxInt(u32);
            const want_max: ?u32 = if (want.max) |m| (std.math.cast(u32, m) orelse std.math.maxInt(u32)) else null;
            return crossModuleTableMismatch(allocator, &module, e.idx, want.elem_type, want_min, want_max);
        },
        .memory => {
            const want = imp.payload.memory;
            return crossModuleMemoryMismatch(allocator, &module, e.idx, want.min, want.max);
        },
        // Unreachable: a tag import (want_kind_byte=4) can't match any
        // ExportDesc kind byte (0-3, tags filtered from exports), so
        // the kind-byte check above already returned. 10.E.
        .tag => return false,
    }
}

/// Walk the exporter's import + global sections to find the
/// global at `global_idx` and verify its valtype + mutability
/// match `want_valtype` / `want_mutable`.
fn crossModuleGlobalMismatch(
    allocator: std.mem.Allocator,
    module: *const zwasm.runtime.Module,
    global_idx: u32,
    want_valtype: zwasm.ir.zir.ValType,
    want_mutable: bool,
) bool {
    var imported_globals: u32 = 0;
    if (module.find(.import)) |is| {
        var imps = zwasm.parse.sections.decodeImports(allocator, is.body) catch return true;
        defer imps.deinit();
        for (imps.items) |im| {
            if (im.kind != .global) continue;
            if (imported_globals == global_idx) {
                return !im.payload.global.valtype.eql(want_valtype) or im.payload.global.mutable != want_mutable;
            }
            imported_globals += 1;
        }
    }
    const defined_idx = global_idx - imported_globals;
    const gs = module.find(.global) orelse return true;
    var globals = zwasm.parse.sections.decodeGlobals(allocator, gs.body) catch return true;
    defer globals.deinit();
    if (defined_idx >= globals.items.len) return true;
    const g = globals.items[defined_idx];
    return !g.valtype.eql(want_valtype) or g.mutable != want_mutable;
}

/// Walk the exporter's import + table sections to find the
/// table at `table_idx` and verify elem_type / min / max match
/// (per Wasm 2.0 §3.4.10 limits-matching: source.min >= want.min
/// and want.max >= source.max if want.max is set).
fn crossModuleTableMismatch(
    allocator: std.mem.Allocator,
    module: *const zwasm.runtime.Module,
    table_idx: u32,
    want_elem: zwasm.ir.zir.ValType,
    want_min: u32,
    want_max: ?u32,
) bool {
    var imported_tables: u32 = 0;
    if (module.find(.import)) |is| {
        var imps = zwasm.parse.sections.decodeImports(allocator, is.body) catch return true;
        defer imps.deinit();
        for (imps.items) |im| {
            if (im.kind != .table) continue;
            if (imported_tables == table_idx) {
                const t = im.payload.table;
                return tableLimitsMismatch(t.elem_type, std.math.cast(u32, t.min) orelse std.math.maxInt(u32), if (t.max) |m| (std.math.cast(u32, m) orelse std.math.maxInt(u32)) else null, want_elem, want_min, want_max);
            }
            imported_tables += 1;
        }
    }
    const defined_idx = table_idx - imported_tables;
    const ts = module.find(.table) orelse return true;
    var tables = zwasm.parse.sections.decodeTables(allocator, ts.body) catch return true;
    defer tables.deinit();
    if (defined_idx >= tables.items.len) return true;
    const t = tables.items[defined_idx];
    return tableLimitsMismatch(t.elem_type, std.math.cast(u32, t.min) orelse std.math.maxInt(u32), if (t.max) |m| (std.math.cast(u32, m) orelse std.math.maxInt(u32)) else null, want_elem, want_min, want_max);
}

fn tableLimitsMismatch(
    src_elem: zwasm.ir.zir.ValType,
    src_min: u32,
    src_max: ?u32,
    want_elem: zwasm.ir.zir.ValType,
    want_min: u32,
    want_max: ?u32,
) bool {
    if (!src_elem.eql(want_elem)) return true;
    if (src_min < want_min) return true;
    if (want_max) |wm| {
        const sm = src_max orelse return true;
        if (sm > wm) return true;
    }
    return false;
}

/// Walk the exporter's import + memory sections to find the
/// memory at `mem_idx` and verify limits (min / max) match.
fn crossModuleMemoryMismatch(
    allocator: std.mem.Allocator,
    module: *const zwasm.runtime.Module,
    mem_idx: u32,
    want_min: u64,
    want_max: ?u64,
) bool {
    var imported_mems: u32 = 0;
    if (module.find(.import)) |is| {
        var imps = zwasm.parse.sections.decodeImports(allocator, is.body) catch return true;
        defer imps.deinit();
        for (imps.items) |im| {
            if (im.kind != .memory) continue;
            if (imported_mems == mem_idx) {
                const m = im.payload.memory;
                return memLimitsMismatch(m.min, m.max, want_min, want_max);
            }
            imported_mems += 1;
        }
    }
    const defined_idx = mem_idx - imported_mems;
    const ms = module.find(.memory) orelse return true;
    var mems = zwasm.parse.sections.decodeMemory(allocator, ms.body) catch return true;
    defer mems.deinit();
    if (defined_idx >= mems.items.len) return true;
    const m = mems.items[defined_idx];
    return memLimitsMismatch(m.min, m.max, want_min, want_max);
}

fn memLimitsMismatch(src_min: u64, src_max: ?u64, want_min: u64, want_max: ?u64) bool {
    if (src_min < want_min) return true;
    if (want_max) |wm| {
        const sm = src_max orelse return true;
        if (sm > wm) return true;
    }
    return false;
}

/// d-22 (D-106): parse the wasm bytes' start section (id=8) to
/// discover the module's start funcidx. Returns `null` when no
/// start section exists (most modules) or parsing fails. The
/// start section body is a single LEB128 u32 funcidx per Wasm
/// spec §5.5.10. Callers invoke the result via
/// `entry.callVoidNoArgs(compiled.module, start_idx, &rt)` after
/// scratch state is set up so the start fn sees the same
/// runtime view as subsequent invocations.
pub fn extractStartFunc(allocator: std.mem.Allocator, wasm_bytes: []const u8) ?u32 {
    var module = zwasm.parse.parser.parse(allocator, wasm_bytes) catch return null;
    defer module.deinit(allocator);
    const sec = module.find(.start) orelse return null;
    var pos: usize = 0;
    return zwasm.support.leb128.readUleb128(u32, sec.body, &pos) catch null;
}

/// §9.9 / 9.9-l-1b-d093-d8c (per ADR-0059): `memory.grow` callout
/// for spec runners. Updates `current_mem_bytes` (module-scoped
/// persistent state) AND `rt.mem_limit` (per-call cached value)
/// so subsequent asserts within the same module see the grown
/// size. Returns -1 when growth would exceed `GROWABLE_MEMORY_CAPACITY`,
/// matching Wasm 1.0 spec §4.4.7.6 host-refuses-growth semantics.
/// §9.9 / 9.9-l-1b-d093-d48 (D-122/D-125): `table.grow` callout
/// for spec runners. Grows `scratch_tables_descriptor[tableidx]`
/// in place by appending `delta` slots filled with `init`. The
/// arena (`scratch_table_refs[tableidx]`) is fixed-capacity, so
/// growth past `SCRATCH_EXTRA_TABLE_CAPACITY` returns -1 per Wasm
/// 2.0 spec §4.4.10.1 host-refuses-growth semantics. Also returns
/// -1 when growth would exceed the descriptor's declared `max`.
pub fn growableTableGrowFn(rt: *entry.JitRuntime, tableidx: u32, init: u64, delta: u64) callconv(.c) i64 {
    if (tableidx >= active_table_count) return -1;
    const desc = &scratch_tables_descriptor[tableidx];
    const old_len = desc.len;
    // Overflow-safe (D-475): a table64 delta is a raw u64.
    const new_len: u64 = std.math.add(u64, old_len, delta) catch return -1;
    if (new_len > SCRATCH_EXTRA_TABLE_CAPACITY) return -1;
    if (desc.max != entry.table_no_max and new_len > desc.max) return -1;
    const arena = &scratch_table_refs[tableidx];
    // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    // Derive init's funcptr + typeidx for the parallel views IFF
    // this is a funcref table (`desc.funcptrs` non-null — externref
    // tables carry the null sentinel and skip both mirrors).
    // `init` is a Value.ref-encoded u64 — null_ref (0) → funcptr 0
    // + typeidx sentinel maxInt(u32); else a `*FuncEntity` cast.
    const FuncEntity = @import("zwasm").runtime.FuncEntity;
    const fp_base_ptr: usize = @intFromPtr(desc.funcptrs);
    const init_funcptr: u64 = if (fp_base_ptr == 0 or init == 0) 0 else blk: {
        const fe: *const FuncEntity = @ptrFromInt(init);
        break :blk fe.funcptr;
    };
    const init_typeidx: u32 = if (fp_base_ptr == 0 or init == 0) std.math.maxInt(u32) else blk: {
        const fe: *const FuncEntity = @ptrFromInt(init);
        break :blk fe.typeidx;
    };
    const ti_base: [*]u32 = if (fp_base_ptr != 0) blk: {
        // Same backing as scratch_table_jit_ci[tableidx].typeidx_base
        // (caller-passed table0_typeidxs for k=0, scratch_extra_typeidxs
        // [k-1] for k>0). Cast away const for the mirror write.
        const ti_const = scratch_table_jit_ci[tableidx].typeidx_base;
        break :blk @constCast(ti_const);
    } else undefined;
    var i: u64 = 0;
    while (i < delta) : (i += 1) {
        arena[old_len + i] = init;
        if (fp_base_ptr != 0) {
            desc.funcptrs[old_len + i] = init_funcptr;
            ti_base[old_len + i] = init_typeidx;
        }
    }
    desc.refs = arena;
    desc.len = new_len;
    _ = rt;
    return @intCast(old_len);
}

pub fn growableMemoryGrowFn(rt: *entry.JitRuntime, delta_pages: u32) callconv(.c) i32 {
    const page_size: u64 = 65536;
    const old_bytes = current_mem_bytes;
    const old_pages: u32 = @intCast(old_bytes / page_size);
    const new_pages: u64 = @as(u64, old_pages) + @as(u64, delta_pages);
    // d-20: respect module-declared max-pages. Wasm 1.0 §4.4.7.6 —
    // grow returns -1 when the result would exceed the declared
    // max. The pool capacity is a secondary cap.
    if (current_mem_max_pages) |max| {
        if (new_pages > max) return -1;
    }
    const new_bytes = new_pages * page_size;
    if (new_bytes > GROWABLE_MEMORY_CAPACITY) return -1;
    @memset(growable_memory[@intCast(old_bytes)..@intCast(new_bytes)], 0);
    current_mem_bytes = new_bytes;
    rt.mem_limit = new_bytes;
    return @intCast(old_pages);
}

/// Parse a 32-character hex token into 16 little-endian bytes —
/// the in-memory Wasm v128 layout (lane-0-byte-0 first). The
/// manifest format uses this for both v128 arguments and v128
/// result tokens (the `v128:<32 hex>` prefix is stripped by the
/// caller).
pub fn parseV128Token(tok: []const u8) ![16]u8 {
    if (tok.len != 32) return error.BadValue;
    var out: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const hi = try std.fmt.charToDigit(tok[i * 2], 16);
        const lo = try std.fmt.charToDigit(tok[i * 2 + 1], 16);
        out[i] = (hi << 4) | lo;
    }
    return out;
}

/// Wasm scalar + SIMD argument kinds visible in the manifest's
/// `assert_return` arg-list tokens. The non-SIMD specialisation
/// (l-1b) shares the enum + union so a single arg-buffer type
/// flows through both runners; the v128 variant is simply
/// unreachable in non-SIMD corpora.
pub const ArgKind = enum { i32, i64, f32, f64, v128 };
pub const ArgValue = union(ArgKind) {
    i32: u32,
    i64: u64,
    f32: u32,
    f64: u64,
    v128: [16]u8,
};

/// Parse one `<kind>:<value>` token into an ArgValue. FP tokens
/// reuse the integer parsers since the manifest emits FP values
/// as their bit-pattern integer (matches the runner harness's
/// `@bitCast` invocation pattern).
pub fn parseArgToken(tok: []const u8) !ArgValue {
    if (std.mem.startsWith(u8, tok, "i32:")) return .{ .i32 = try parseI32Token(tok[4..]) };
    if (std.mem.startsWith(u8, tok, "i64:")) return .{ .i64 = try parseI64Token(tok[4..]) };
    if (std.mem.startsWith(u8, tok, "f32:")) return .{ .f32 = try parseI32Token(tok[4..]) };
    if (std.mem.startsWith(u8, tok, "f64:")) return .{ .f64 = try parseI64Token(tok[4..]) };
    if (std.mem.startsWith(u8, tok, "v128:")) return .{ .v128 = try parseV128Token(tok[5..]) };
    return error.BadValue;
}

/// Tokenise an `assert_return` arg-list into `args_buf`. Returns
/// the count of parsed args. `"()"` is the zero-arg form (returns
/// 0 with no parsing).
///
/// Errors: `error.TooManyArgs` when the corpus exceeds the
/// caller-supplied buffer length (caller decides how to surface
/// it; the SIMD runner's buffer is `[4]ArgValue` per chunk
/// 9.9-h-3 / 9.9-h-28 / 9.9-h-29 dispatch ladder). `error.BadValue`
/// propagates from `parseArgToken` for an unrecognised prefix.
pub fn parseAssertReturnArgs(args_s: []const u8, args_buf: []ArgValue) !usize {
    if (std.mem.eql(u8, args_s, "()")) return 0;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, args_s, ' ');
    while (it.next()) |tok| {
        if (n >= args_buf.len) return error.TooManyArgs;
        args_buf[n] = try parseArgToken(tok);
        n += 1;
    }
    return n;
}

/// FP-result expectation per Wasm spec §A.2 "Result types"
/// + the testsuite's `nan:canonical` / `nan:arithmetic` tokens.
/// `exact` carries a literal bit pattern (caller decides u32 / u64
/// width); the two NaN variants accept any bit pattern matching
/// the spec-defined NaN class on the result FP width.
pub const ScalarFpSpec = union(enum) {
    exact: u64,
    canonical,
    arithmetic,
};

/// Parse the `<value>` portion of a `f32:` / `f64:` result token
/// (the runner has already stripped the `f32:` / `f64:` prefix).
/// Recognises `nan:canonical` / `nan:arithmetic` literals as the
/// corresponding `ScalarFpSpec` variants; falls back to
/// `parseI32Token` (for f32 results) / `parseI64Token` (for f64
/// results) via `bits` for any decimal bit-pattern literal.
///
/// `bits` chooses the integer parser. Pass `32` for f32 results,
/// `64` for f64. Mismatches surface as `error.BadValue`.
pub fn parseScalarFpExpected(value_s: []const u8, bits: u8) !ScalarFpSpec {
    if (std.mem.eql(u8, value_s, "nan:canonical")) return .canonical;
    if (std.mem.eql(u8, value_s, "nan:arithmetic")) return .arithmetic;
    switch (bits) {
        32 => return .{ .exact = @as(u64, try parseI32Token(value_s)) },
        64 => return .{ .exact = try parseI64Token(value_s) },
        else => return error.BadValue,
    }
}

/// Compare a f32 result's bit pattern against the expected spec.
/// Canonical NaN: sign-agnostic ±0x7fc00000. Arithmetic NaN:
/// exponent all-1s + mantissa MSB = 1 (= any quiet NaN, includes
/// canonical). Exact: u32 bit-pattern equality.
pub fn matchScalarF32(got_bits: u32, spec: ScalarFpSpec) bool {
    return switch (spec) {
        .canonical => got_bits == 0x7fc00000 or got_bits == 0xffc00000,
        .arithmetic => (got_bits & 0x7fc00000) == 0x7fc00000,
        .exact => |bits| got_bits == @as(u32, @intCast(bits & 0xffffffff)),
    };
}

/// f64 mirror of `matchScalarF32`. Canonical NaN bit pattern is
/// `±0x7ff8000000000000`; arithmetic is any quiet NaN
/// (exp all-1s + mantissa MSB = 1).
pub fn matchScalarF64(got_bits: u64, spec: ScalarFpSpec) bool {
    return switch (spec) {
        .canonical => got_bits == 0x7ff8000000000000 or got_bits == 0xfff8000000000000,
        .arithmetic => (got_bits & 0x7ff8000000000000) == 0x7ff8000000000000,
        .exact => |bits| got_bits == bits,
    };
}

// ============================================================
// SIGSEGV → trap recovery (D-103 / §9.9 / 9.9-l-1b-d093-d29).
//
// Some `assert_trap` paths (notably `elem.wast`) crash inside the
// JIT-compiled function before the trap stub sets `trap_flag` —
// the runner's `Error.Trap` check never sees the trap because the
// process has already SEGV'd. Wrapping the JIT entry call site
// with `sigsetjmp` + a SIGSEGV handler that `siglongjmp`s back
// converts an in-body fault into the same outcome as the trap
// stub: the call returns truthy (= recovered = trapped) instead
// of aborting the runner.
//
// Inline-call discipline: `sigsetjmp` MUST be invoked from the
// caller frame that the recovery should land in — its captured
// SP/PC point at the calling function. Wrapping `sigsetjmp` in
// a Zig helper that returns the value would bind the captured
// frame to the helper's (already-popped) frame, undefined
// behaviour on `longjmp`. So callers invoke `sigsetjmp` directly
// against `sigsegv_recover_buf`, then arm/disarm via
// `sigsegv_armed`.
// ============================================================

/// Backing storage for `sigsetjmp` / `siglongjmp`. Sized to fit
/// both `sigjmp_buf` layouts in scope: macOS arm64 = `int[49]`
/// (~196 B), Linux x86_64 glibc = `__jmp_buf_tag[1]` (~200 B).
/// 16-byte alignment matches both libcs' alignment requirements.
pub var sigsegv_recover_buf: [512]u8 align(16) = undefined;

/// Arming flag — when `true` the SIGSEGV handler `siglongjmp`s
/// back to the most recent `sigsetjmp` site; when `false` the
/// handler treats the SEGV as unexpected and exits with the
/// conventional `128 + 11 = 139` code (= a runner-internal bug
/// surfaces loudly instead of being swallowed).
///
/// §9.9 / 9.9-l-1b-d093-d62: typed as `std.atomic.Value(bool)`
/// (was plain `bool`) — under SA.ONSTACK the SIGSEGV handler
/// runs on a different stack from the dispatcher, and the Zig
/// 0.16 compiler can legitimately fold the BSS load when the
/// handler is invisible to its dataflow analysis (observed
/// under OrbStack `test-all` Debug builds even with `*volatile
/// bool` casts). `std.atomic.Value(bool)` forces a real memory
/// access via the canonical atomic intrinsics.
pub var sigsegv_armed: std.atomic.Value(bool) = .init(false);

// glibc exposes `sigsetjmp` as a macro that expands to
// `__sigsetjmp(env, savemask)`; the symbol available to the
// linker is `__sigsetjmp`. macOS / BSD libcs expose `sigsetjmp`
// directly. Resolve at comptime so the autonomous loop's 2-host
// gate (Mac arm64 + OrbStack Linux x86_64) finds the right
// linkage name on each side.
const SigsetjmpFn = *const fn (env: [*]u8, savemask: c_int) callconv(.c) c_int;
const SiglongjmpFn = *const fn (env: [*]u8, val: c_int) callconv(.c) noreturn;

// Windows has no `sigsetjmp` / `siglongjmp` symbol in MSVCRT.
// Surfaced by windowsmini D-084 reconcile (2026-05-17) as
// `lld-link: undefined symbol: sigsetjmp` once the
// `installSigsegvHandler` Win64 gate landed and the linker
// reached these `@extern` references. The SEGV-recovery contract
// is POSIX-only by design (see `installSigsegvHandler` early-
// return for the rationale); Windows uses noop stubs so the
// symbol references resolve. `sigsegv_armed` is never set on
// Windows (installSigsegvHandler returns before the arming flag
// is written), so `siglongjmp` is provably unreachable there.
pub const sigsetjmp: SigsetjmpFn = if (@import("builtin").os.tag == .windows)
    &sigsetjmpWindowsStub
else
    @extern(SigsetjmpFn, .{
        .name = if (@import("builtin").os.tag == .linux) "__sigsetjmp" else "sigsetjmp",
        .library_name = "c",
    });

pub const siglongjmp: SiglongjmpFn = if (@import("builtin").os.tag == .windows)
    &siglongjmpWindowsStub
else
    @extern(SiglongjmpFn, .{
        .name = "siglongjmp",
        .library_name = "c",
    });

/// Windows-only stub: always returns 0 so the protected code
/// runs through to completion; if a SEGV happens, the OS
/// terminates the process (default Windows behavior, same as
/// pre-d-62 baseline). Never called on POSIX targets.
///
/// TODO(D-136): this stub is a Windows-compat workaround, not a
/// real SEGV-recovery implementation. spec_assert_runner_non_simd
/// crashes mid-corpus on assert_trap fixtures because the OS
/// kills the process instead of returning to the assert harness.
/// Discharge requires either a Win64 SEH bridge (`__try`/
/// `__except`) producing equivalent recovery semantics, or
/// Windows-side per-directive skipping of assert_trap, or
/// scoping windowsmini reconcile to "build + non-assert_trap
/// runners" via ADR-0056 amend. See `.dev/debt.yaml` D-136 for
/// the full decision tree.
fn sigsetjmpWindowsStub(env: [*]u8, savemask: c_int) callconv(.c) c_int {
    _ = env;
    _ = savemask;
    return 0;
}

/// Windows-only stub: `unreachable` because the `sigsegv_armed`
/// flag is never set on Windows (installSigsegvHandler returns
/// before the trap-arming path), so the JIT-trap recovery branch
/// in `sigsegvHandler` never calls this. The stub satisfies the
/// linker's symbol reference; it would only be hit if the design
/// invariant breaks (= regression).
///
/// TODO(D-136): paired with `sigsetjmpWindowsStub` above; same
/// discharge plan.
fn siglongjmpWindowsStub(env: [*]u8, val: c_int) callconv(.c) noreturn {
    _ = env;
    _ = val;
    unreachable;
}

/// §9.9-III (c)-2.3-γ-4 DIAG: most-recently-loaded `.module`
/// directive's file name. Written by `runCorpus`'s `.module`
/// arm; read by `sigsegvHandler` to surface the crash fixture
/// before `_exit(142)`. Async-signal-safe access pattern: the
/// signal handler reads `last_module_name_len` first then
/// `last_module_name[0..len]`; runCorpus writes them in the
/// opposite order (bytes then length store) so a partial
/// observation produces an empty / safe slice rather than a
/// garbage one.
pub var last_module_name: [256]u8 = undefined;
pub var last_module_name_len: u32 = 0;

/// D-142 probe: count handler entries across the process lifetime.
/// Incremented unconditionally at handler entry (before the armed-
/// branch check), so re-entries triggered by a SEGV-during-
/// siglongjmp path show as count > 1. The unarmed branch emits
/// the count alongside the last-module trace. Permanent
/// infrastructure (like `last_module_name`); zero overhead in
/// the happy path.
pub var sigsegv_handler_entry_count: std.atomic.Value(u32) = .init(0);

/// D-142 probe: the most recent handler-entry serial that took
/// the armed branch (= just before its siglongjmp call). If a
/// subsequent unarmed entry has serial == armed_serial + 1, the
/// armed branch's siglongjmp itself re-faulted (since no other
/// SEGV intervened between the armed entry and the unarmed
/// entry). Initial value 0 means "no armed entry yet".
pub var sigsegv_last_armed_entry: std.atomic.Value(u32) = .init(0);

pub extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

/// Async-signal-safe u32 → decimal-ASCII formatter. Writes digits
/// at the end of `buf` and returns the slice that holds them.
/// `buf` MUST be at least 10 bytes (u32 max = 4_294_967_295). No
/// allocation, no stdio. Safe to call from a signal handler.
fn formatU32Decimal(value: u32, buf: []u8) []u8 {
    if (value == 0) {
        buf[buf.len - 1] = '0';
        return buf[buf.len - 1 ..];
    }
    var v = value;
    var i: usize = buf.len;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    return buf[i..];
}

/// Async-signal-safe usize → 16-hex-digit ASCII formatter (fixed
/// width, leading zeros preserved for alignment). `buf` MUST be
/// at least 16 bytes. Used by the SA_SIGINFO handler to emit
/// fault addresses for D-142 investigation.
fn formatU64Hex(value: u64, buf: []u8) []u8 {
    const hex_digits = "0123456789abcdef";
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex_digits[v & 0xf];
        v >>= 4;
    }
    return buf[0..16];
}

fn sigsegvHandler(_: std.posix.SIG, info: ?*const std.posix.siginfo_t, uctx: ?*anyopaque) callconv(.c) void {
    // ADR-0202 D2 "one handler, three dispositions" — disposition 1
    // FIRST: a classified guard fault (fault addr in a guarded
    // reservation AND pc in registered JIT code) is a wasm oob TRAP,
    // not a miscompile — redirect the PC to the function's kind=6
    // trap stub and resume; the sticky-flag path surfaces Error.Trap
    // normally. Runs BEFORE the armed-siglongjmp recovery so a guard
    // fault under the spec runner exercises the SAME production
    // mechanism the CLI uses (the corpus must not go green through
    // the recovery path — ADR-0202 verification note).
    if (info) |si| {
        if (zwasm.platform.sigcontext.pcPtr(uctx)) |pc_slot| {
            if (zwasm.platform.trap_registry.classify(
                zwasm.platform.sigcontext.faultAddr(si),
                pc_slot.*,
            )) |stub| {
                pc_slot.* = stub;
                return;
            }
        }
    }
    // D-142 probe: count every handler entry so the unarmed
    // branch can disambiguate "first SEGV with flag already
    // false" from "second entry after siglongjmp re-faulted".
    const this_entry = sigsegv_handler_entry_count.fetchAdd(1, .monotonic) + 1;
    // §9.9 / 9.9-l-1b-d093-d62: `std.atomic.Value` access pairs
    // with the release-store at the dispatch site and forces a
    // real memory access. The flag was plain `bool` pre-d-62 but
    // started getting elided under SA.ONSTACK once the handler
    // moved to the altstack — see the type-level docstring at
    // `sigsegv_armed`.
    if (sigsegv_armed.load(.acquire)) {
        // D-142 probe (2026-05-17): record the last armed-entry
        // serial so the unarmed branch can format `last-armed=N`
        // for re-entry analysis. Cheap (one swap); permanent
        // infrastructure — unlike the spammy stderr marker that
        // confirmed there's no siglongjmp re-entry at imports.1
        // (the unarmed entry is a fresh unrecovered SEGV, not a
        // re-fault from longjmp), this counter helps any future
        // SEGV-class investigation distinguish the two modes.
        _ = sigsegv_last_armed_entry.swap(this_entry, .release);
        sigsegv_armed.store(false, .release);
        siglongjmp(@ptrCast(&sigsegv_recover_buf), 1);
    }
    // §9.9-III (c)-2.3-γ-4 DIAG: SEGV outside an armed JIT
    // call. Before `_exit(142)`, surface the most-recently-
    // loaded module's file name to stderr (fd=2) so the
    // crash fixture is identifiable across rebuilds despite
    // the layout-sensitivity recorded in the
    // `gamma4-stdout-buf-layout-sensitivity` lesson. Both
    // `write(2)` and `_exit(2)` are async-signal-safe per
    // POSIX `signal-safety(7)`; no allocation, no stdio
    // buffering, no atexit handlers.
    const len = last_module_name_len;
    if (len > 0 and len <= last_module_name.len) {
        const prefix = "[γ-4 DIAG] SEGV after .module ";
        _ = write(2, prefix, prefix.len);
        _ = write(2, &last_module_name, len);
    } else {
        const msg = "[γ-4 DIAG] SEGV before any .module directive";
        _ = write(2, msg, msg.len);
    }
    // D-142 probe: emit handler-entry-count + last-armed-entry.
    // Re-entry from siglongjmp manifests as `this == armed + 1`
    // (= this unarmed entry follows the most recent armed entry
    // with no intervening SEGV, i.e. siglongjmp itself re-faulted
    // and the same SIGSEGV got delivered to the handler again
    // with the flag now `false`).
    {
        var ce_buf: [10]u8 = undefined;
        var ae_buf: [10]u8 = undefined;
        const ce_str = formatU32Decimal(
            sigsegv_handler_entry_count.load(.monotonic),
            &ce_buf,
        );
        const ae_str = formatU32Decimal(
            sigsegv_last_armed_entry.load(.acquire),
            &ae_buf,
        );
        const tail1 = " (handler-entry=";
        const tail2 = " last-armed=";
        _ = write(2, tail1, tail1.len);
        _ = write(2, ce_str.ptr, ce_str.len);
        _ = write(2, tail2, tail2.len);
        _ = write(2, ae_str.ptr, ae_str.len);
        // D-142 probe: emit the fault address from siginfo_t.addr
        // (POSIX-standard `si_addr` field). Mac aarch64 specific
        // (Zig's Linux siginfo_t routes through a union that's
        // non-trivial to navigate from a signal handler context).
        // Comparing against the stack-guard region, MAP_JIT ranges,
        // or the `callbacks.on_module_loaded` text address narrows
        // hypotheses (3) stack-guard hit vs (5) BLR-target near
        // MAP_JIT flip vs (4) layout coincidence.
        if (@import("builtin").os.tag == .macos and info != null) {
            const addr_int: u64 = @intFromPtr(info.?.addr);
            var fa_buf: [16]u8 = undefined;
            const fa_str = formatU64Hex(addr_int, &fa_buf);
            const tail3 = " fault-addr=0x";
            _ = write(2, tail3, tail3.len);
            _ = write(2, fa_str.ptr, fa_str.len);
        }
        _ = write(2, ")\n", 2);
    }
    // SEGV outside an armed JIT call: do not silently swallow.
    // `_exit(142)` is async-signal-safe (raw syscall, no atexit
    // handlers). Exit code 142 (= 128 + SIGALRM by bash
    // convention) is the D-134 disambiguation probe — distinct
    // from the conventional 139 (= 128 + SIGSEGV) so a
    // `zig build` report of "exited with code 142"
    // unambiguously indicates our handler fired and reached
    // this path, whereas a "process terminated with signal
    // SEGV" report means the kernel delivered SIGSEGV without
    // our handler running (handler-install race or signal-mask
    // block).
    std.c._exit(142);
}

/// Install the SIGSEGV / SIGBUS handler used by the assert_trap
/// path. Idempotent — safe to call from multiple runner main
/// entries. Process-wide; the previous handler (if any) is
/// overwritten without recording (the spec runners are leaf
/// processes that own the signal disposition).
// §9.9 / 9.9-l-1b-d093-d62: alternate signal stack used by the
// SIGSEGV/SIGBUS handler when the JIT body exhausts the native
// stack (assert_exhaustion fixtures — runaway recursion hits the
// stack-guard page, and without SA.ONSTACK the handler itself
// would crash for lack of stack). 256 KB matches Zig's
// `std.options.signal_stack_size` default. The buffer is a
// page-aligned static byte array — `sigaltstack` only requires
// the region be writable and at least `MINSIGSTKSZ` bytes, and
// 256 KB is comfortably larger than the per-OS minimum (16 KB on
// Linux, 32 KB on Darwin) plus our handler's modest frame use
// (`siglongjmp` + the trivial dispatcher in `sigsegvHandler`).
const SIGNAL_STACK_SIZE: usize = 1 << 18;
var signal_stack: [SIGNAL_STACK_SIZE]u8 align(std.heap.page_size_max) = undefined;

pub fn installSigsegvHandler() void {
    // ADR-0202 D5 — this harness backs JIT linear memory with its own
    // bespoke buffers (`scratch_memory` heap allocs + the static
    // `growable_memory` array), NOT guard-page reservations. Guard-page
    // bounds elision would then read past a plain buffer instead of
    // faulting (an oob assert would "not trap"), violating the D4/D5
    // binding-time soundness invariant (elided code MUST bind guarded
    // memory). Force `.explicit` so the corpus validates spec trap
    // semantics against the checked codegen; the elision path is covered
    // by the guarded runner_trap_test + the CLI oob test (debt D-515
    // tracks running the full corpus under elision via guarded harness
    // memory or the D-510 differential).
    zwasm.engine.runner.setBoundsChecks(.explicit);
    // Windows: POSIX signals don't apply; `std.posix.Sigaction` is
    // `void` on Win64. Surfaced by windowsmini test-all
    // (`type 'void' does not support struct initialization syntax`
    // at `.handler = .{ ... }` below) when D-084 reconcile ran
    // 2026-05-17. Early-return preserves the runner's structural
    // shape on Windows; the SEGV-recovery contract is POSIX-only
    // by design (no Mach exception ports / SEH bridge implemented).
    //
    // Windows: install the VEH-based trap bridge (ADR-0103 /
    // D-136 in-flight discharge). The bridge is process-wide
    // (single AddVectoredExceptionHandler registration) +
    // threadlocal recovery state, mirroring v1 + Wasmtime +
    // Wasmer. The matching `arm` / `disarm` callsites land in
    // a follow-up chunk (W3.b' — replacing the sigsetjmp pair
    // on the Windows arm of the JIT-entry callsites).
    if (@import("builtin").os.tag == .windows) {
        @import("zwasm").platform.windows_traphandler.install();
        return;
    }

    // Explicitly install our own alternate signal stack rather than
    // relying on Zig's start-up code: `Thread.maybeAttachSignalStack`
    // installs a *threadlocal* altstack, which works on Mac aarch64
    // (`MAC=0` post-d-62) but on Linux x86_64 the spec_assert runner
    // observed a hard SIGSEGV at the second-level handler invocation
    // (test-all bg task exit 1). Owning the altstack install at the
    // runner level removes the host-specific behavioural divergence.
    // siglongjmp restores the saved SP from `sigsegv_recover_buf`,
    // so jumping from the altstack back to the dispatch frame on
    // the main stack is sound regardless of which stack the handler
    // ran on.
    //
    // §9.9 / 9.9-l-1b-d093-d72 (D-134 hypothesis iii-a probe):
    // surface sigaltstack errors instead of swallowing via
    // `catch {}` so a silent install failure (suspect on OrbStack
    // Linux x86_64 after d-71 confirmed our handler doesn't fire)
    // becomes visible. Likewise add a sigaction-readback check so
    // a stale `SIG_DFL` disposition would surface on stderr at
    // install time.
    std.posix.sigaltstack(&.{
        .sp = &signal_stack,
        .flags = 0,
        .size = SIGNAL_STACK_SIZE,
    }, null) catch |err| {
        std.debug.print("installSigsegvHandler: sigaltstack failed: {s}\n", .{@errorName(err)});
    };
    // D-142 probe (2026-05-17): switch to the sa_sigaction form
    // (SA.SIGINFO flag) so the handler receives `siginfo_t*` and
    // can surface the fault address via `siginfo.addr` (POSIX
    // §"Signal Concepts"). Cross-platform safe: the union member
    // `.sigaction` is the standard POSIX `sa_sigaction` callback
    // form supported on every Sigaction layout.
    var act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = sigsegvHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.ONSTACK | std.posix.SA.SIGINFO,
    };
    std.posix.sigaction(.SEGV, &act, null);
    // SIGBUS covers the Mach-side variant (mis-aligned access on
    // arm64, mmap region truncation) so the runner survives the
    // same class of in-body fault on Mac.
    std.posix.sigaction(.BUS, &act, null);
    // ADR-0202 D4 — this recovery handler (classify-first, then
    // siglongjmp) now OWNS SIGSEGV/SIGBUS for the runner process;
    // tell the engine's auto-install to stand down so it never
    // clobbers this handler with the production exit-70 one.
    zwasm.platform.signal.markInstalled();

    // Readback verification: confirm our handler is the active
    // SEGV disposition immediately post-install. Prints on stderr
    // ONLY if the readback fails to match (so happy-path runs
    // stay quiet). If the printed line appears, some other path
    // has already replaced our SEGV sigaction before main's
    // installSigsegvHandler returned — diagnostic for D-134
    // hypothesis (iii-c).
    var oact: std.posix.Sigaction = undefined;
    std.posix.sigaction(.SEGV, null, &oact);
    // D-142 probe: handler is now the sa_sigaction form
    // (`.sigaction` union member) per the SA.SIGINFO upgrade
    // above; the readback compares against the same union slot.
    const installed_fn = oact.handler.sigaction;
    if (installed_fn != sigsegvHandler) {
        std.debug.print("installSigsegvHandler: SEGV disposition is NOT our handler (oact.handler.sigaction={?*})\n", .{installed_fn});
    }
}

/// Per-runner callbacks invoked by `runCorpus()`. Specialisations
/// (currently only `simd_assert_runner`; later `spec_assert_runner_non_simd`
/// per l-1b) provide function pointers that handle the type-specific
/// argument parsing, JIT invocation, and result comparison.
///
/// `on_module_loaded` runs after the base loop reads + compiles a
/// new module. Specialisations use it to repopulate any scratch
/// state the JIT will read from (memory bytes via active data
/// segments, defined-globals byte buffer, funcref table). On error
/// the base loop prints `FAIL` and sets `module_bad = true` so
/// subsequent asserts under the broken module silently skip
/// instead of cascading. The callback prints its own FAIL line
/// before returning the error (so the diagnostic carries
/// init-specific context — data-init vs globals-init vs table-init).
///
/// `handle_assert_return` / `handle_assert_trap` return `true` on
/// pass, `false` on a fixture mismatch (caller increments
/// `failed`). Returning an error is also a failure path; caller
/// prints a generic FAIL line with the error name.
pub const RunnerCallbacks = struct {
    on_module_loaded: *const fn (
        gpa: std.mem.Allocator,
        wasm_bytes: []const u8,
        compiled: *const runner_mod.CompiledWasm,
        stdout: *std.Io.Writer,
        name: []const u8,
    ) anyerror!void,
    handle_assert_return: *const fn (
        gpa: std.mem.Allocator,
        wasm_bytes: []const u8,
        compiled: *const runner_mod.CompiledWasm,
        body: []const u8,
        stdout: *std.Io.Writer,
        name: []const u8,
    ) anyerror!bool,
    handle_assert_trap: *const fn (
        gpa: std.mem.Allocator,
        wasm_bytes: []const u8,
        compiled: *const runner_mod.CompiledWasm,
        body: []const u8,
        stdout: *std.Io.Writer,
        name: []const u8,
    ) anyerror!bool,
    /// d-36: invoke-action handler — invokes a no-result action
    /// for its side effects. Returns true on success (no trap),
    /// false on trap; specialisations print their own FAIL line
    /// before returning false.
    handle_invoke_action: *const fn (
        gpa: std.mem.Allocator,
        wasm_bytes: []const u8,
        compiled: *const runner_mod.CompiledWasm,
        body: []const u8,
        stdout: *std.Io.Writer,
        name: []const u8,
    ) anyerror!bool,
    /// §9.12-E / B137: same-module `(get "field")` action handler.
    /// Body shape: `<field> <type> <value>` (e.g. `e i32 42`).
    /// Returns true on PASS, false on FAIL (value mismatch / global
    /// not found). Optional — runners that don't yet support
    /// non-invoke actions leave this null and base routes the
    /// directive to skipped_adr with a SKIP-NON-INVOKE-ACTION
    /// token (preserves the prior skip-impl behaviour while
    /// freeing the manifest format to encode it honestly).
    handle_get_action: ?*const fn (
        gpa: std.mem.Allocator,
        wasm_bytes: []const u8,
        compiled: *const runner_mod.CompiledWasm,
        body: []const u8,
        stdout: *std.Io.Writer,
        name: []const u8,
    ) anyerror!bool = null,
    /// d-57: attempt the same instantiation work as
    /// `on_module_loaded` but invert error semantics — return
    /// `true` (PASS) on any init-time failure (active data/elem
    /// OOB, start-fn trap, ...); return `false` (FAIL) iff
    /// instantiation completes cleanly. The compile step
    /// itself runs in `runCorpus` so this callback may assume
    /// `compiled` is well-formed; instantiation-only failures
    /// reach the callback. Optional — runners that don't yet
    /// support assert_uninstantiable leave this null and base
    /// routes the directive to `skipped` with a SKIP-* line.
    handle_assert_uninstantiable: ?*const fn (
        gpa: std.mem.Allocator,
        wasm_bytes: []const u8,
        compiled: *const runner_mod.CompiledWasm,
        stdout: *std.Io.Writer,
        name: []const u8,
    ) anyerror!bool = null,
};

/// Run one corpus manifest end-to-end: open the directory, read
/// `manifest.txt`, classify and dispatch every line. Module / assert
/// behaviour is delegated to the callbacks; skip classification,
/// `assert_invalid` / `assert_malformed` SKIP-VALIDATOR-GAP /
/// SKIP-PARSER-GAP wiring, and tally bookkeeping stay in base
/// (uniform across SIMD + non-SIMD specialisations).
pub fn runCorpus(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: *std.Io.Dir,
    name: []const u8,
    stdout: *std.Io.Writer,
    tally: *AssertTally,
    callbacks: RunnerCallbacks,
) !void {
    var dir = try root.openDir(io, name, .{});
    defer dir.close(io);

    const manifest_bytes = dir.readFileAlloc(io, "manifest.txt", gpa, .limited(1 << 22)) catch |err| {
        try stdout.print("FAIL  {s}: manifest read: {s}\n", .{ name, @errorName(err) });
        tally.failed += 1;
        return;
    };
    defer gpa.free(manifest_bytes);

    var current_wasm: ?[]u8 = null;
    var current_compiled: ?runner_mod.CompiledWasm = null;
    // `module_bad` distinguishes "no module yet" from "module declared
    // but compile (or init) rejected it"; subsequent asserts under a
    // bad module are silently skipped (counted) rather than each
    // cascading as a separate FAIL.
    var module_bad: bool = false;
    // Phase 9 §9.9-III chunk (c)-1c per ADR-0065 + (c)-2.3 per
    // ADR-0066: session-local module-alias registry. Maps alias
    // → `RegisteredExporter` (lifetime tied to runCorpus).
    // `(register "M" $inst)` directives populate this; consumer
    // is the (c)-2.3 cross-module resolver. Until the resolver
    // wires in (next sub-chunk), the registry remains write-only
    // — the `compiled` field stays null and `RegisteredExporter`
    // behaves as bytes-only storage (parity with (c)-1c shape).
    var registered: std.StringHashMapUnmanaged(RegisteredExporter) = .empty;

    // Close-plan §6 (j) D-153 / direct-implementation route
    // (2026-05-21). Auto-register the canonical `spectest` host
    // module at corpus start. The bytes are compiled at build
    // time from `test/spec/spectest.wat` (see build.zig
    // `spectest_wat2wasm` step); `@embedFile` resolves through
    // the `spectest_module` anonymous module wired in build.zig.
    //
    // Effect: testsuite fixtures with `(import "spectest" ...)`
    // bind via the existing cross-module resolver (β path) —
    // no host-binding pathway needed. Eliminates 100+ runtime
    // SKIP-CROSS-MODULE-IMPORTS events that previously blocked
    // §9.12-E close.
    //
    // Canonical reference: WebAssembly/spec/interpreter/host/
    // spectest.ml (56 OCaml lines; the .wat is a faithful
    // re-derivation, cross-checked against zwasm v1 and
    // wazero's testdata/spectest.wat).
    {
        const spectest_module = @import("spectest_module");
        const alias_owned = try gpa.dupe(u8, "spectest");
        const bytes_owned = try gpa.dupe(u8, spectest_module.bytes);
        const gop = try registered.getOrPut(gpa, alias_owned);
        if (gop.found_existing) {
            gpa.free(alias_owned);
            gpa.free(bytes_owned);
        } else {
            gop.value_ptr.* = .{ .bytes_owned = bytes_owned };
        }
    }

    current_registered = &registered;
    defer current_registered = null;

    defer {
        if (current_wasm) |b| gpa.free(b);
        if (current_compiled) |*c| c.deinit(gpa);
        resetModuleDispatch(gpa);
        var reg_it = registered.iterator();
        while (reg_it.next()) |reg_entry| {
            gpa.free(reg_entry.key_ptr.*);
            reg_entry.value_ptr.deinit(gpa);
        }
        registered.deinit(gpa);
    }

    var line_it = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        tally.lines += 1;

        switch (classifySkipLine(line)) {
            .skip_impl => {
                tally.manifest_skip_impl += 1;
                continue;
            },
            .skip_adr => {
                tally.skipped_adr += 1;
                continue;
            },
            .bare_legacy => {
                try stdout.print("WARN  {s}: bare `skip` line — migrate to `skip-impl` or `skip-adr-<id>` (chunk 9.9-h-22 regen sweep): {s}\n", .{ name, line });
                tally.manifest_skip_impl += 1;
                continue;
            },
            .other => {},
        }

        // W4 reconcile diagnostic (D-136 in-flight): per-directive
        // beacon to stderr so a crash mid-manifest names the exact
        // directive. Cost: one write(2) per directive (~50/manifest
        // × ~60 manifests = ~3000 writes total); value: the
        // line-level crash locator when stdout's 1024B buffer drops
        // in-flight progress. The line content is truncated to 80
        // bytes to keep the beacon compact in /tmp/win.log.
        {
            const tag = "[W4 DIR] ";
            _ = write(2, tag, tag.len);
            _ = write(2, name.ptr, name.len);
            _ = write(2, " : ", 3);
            const max_dir_bytes: usize = 80;
            const dir_len = if (line.len > max_dir_bytes) max_dir_bytes else line.len;
            _ = write(2, line.ptr, dir_len);
            _ = write(2, "\n", 1);
        }

        const classified = classifyDirective(line);
        switch (classified.kind) {
            .module => {
                const file = classified.body;
                // §9.9-III (c)-2.3-γ-4 DIAG: stash `<corpus>/<file>`
                // into `last_module_name` so a subsequent
                // `_exit(142)` SEGV can name the fixture. Write
                // bytes BEFORE updating length so a racy handler
                // read sees either the prior fixture's name
                // (already valid) or the new one fully — never a
                // half-written buffer.
                {
                    const max = last_module_name.len;
                    var w: usize = 0;
                    for (name) |c| {
                        if (w >= max) break;
                        last_module_name[w] = c;
                        w += 1;
                    }
                    if (w < max) {
                        last_module_name[w] = '/';
                        w += 1;
                    }
                    for (file) |c| {
                        if (w >= max) break;
                        last_module_name[w] = c;
                        w += 1;
                    }
                    @atomicStore(u32, &last_module_name_len, @intCast(w), .release);
                }
                if (current_compiled) |*c| c.deinit(gpa);
                current_compiled = null;
                if (current_wasm) |b| gpa.free(b);
                current_wasm = null;
                resetModuleDispatch(gpa);
                module_bad = false;

                const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                    try stdout.print("FAIL  {s}/{s} module read: {s}\n", .{ name, file, @errorName(err) });
                    tally.failed += 1;
                    module_bad = true;
                    continue;
                };
                current_wasm = wasm_bytes;
                current_module_file = file;

                // d-37: skip modules whose imports the spec runner
                // cannot satisfy. `spectest.<fn>` function imports
                // route through the d-35 trap stub; func imports
                // against a `registered` alias route through the
                // (c)-2.3-β cross-module resolver below. Anything
                // else (table / memory / global imports OR any
                // non-spectest module name not in `registered`)
                // would need (c)-2.3-γ cross-module instance
                // state. Pre-empt the compile-stage FAIL for those.
                if (hasUnbindableImports(gpa, wasm_bytes, &registered)) {
                    try stdout.print("SKIP-CROSS-MODULE-IMPORTS  {s}/{s}: module imports state the spec runner cannot bind\n", .{ name, file });
                    tally.runtime_skip += 1;
                    module_bad = true;
                    continue;
                }

                const compiled = runner_mod.compileWasm(gpa, wasm_bytes) catch |err| {
                    // multi-memory-on-JIT is a ROADMAP Phase-14 deferral
                    // (compile.zig:125 rejects >1 memory; ~458 multi-memory/
                    // corpus skips already forward-ref'd). The simd_assert_runner
                    // is JIT-only, so simd_memory-multi.wast genuinely cannot run
                    // here — record the engine-capability boundary specifically
                    // rather than a generic FAIL.
                    if (err == error.MultipleMemories) {
                        try stdout.print("SKIP-JIT-MULTI-MEMORY  {s}/{s}: multi-memory on JIT deferred to Phase 14 (ROADMAP §14)\n", .{ name, file });
                        tally.runtime_skip += 1;
                        module_bad = true;
                        continue;
                    }
                    try stdout.print("FAIL  {s}/{s} compile: {s}\n", .{ name, file, @errorName(err) });
                    tally.failed += 1;
                    module_bad = true;
                    continue;
                };
                current_compiled = compiled;

                // Per-defined-function JIT hex dump for offline
                // disassembly (`llvm-objdump --disassemble -b binary
                // -m x86_64 --x86-asm-syntax=intel`). D-163 (its
                // origin) is CLOSED, so the previously-always-on dump
                // is now ENV-GATED — set `ZWASM_DUMP_JIT=1` to re-enable.
                // D-279 H7: the unconditional dump (a `std.debug.print`
                // per func of the full byte stream) flooded Win64 stdout
                // on every test-all and truncated mid-func right before
                // each exit-3 crash; gating it OFF by default removes the
                // noise AND probes whether D-279 persists without the dump
                // (dump-I/O trigger vs real compile-time fault).
                if (dump_jit_enabled) {
                    for (compiled.func_results, 0..) |*fr, def_idx| {
                        const wasm_idx = compiled.num_imports + @as(u32, @intCast(def_idx));
                        std.debug.print("[d-163-jit] func{d} (wasm_idx={d}) len={d} bytes=", .{ def_idx, wasm_idx, fr.out.bytes.len });
                        for (fr.out.bytes) |b| std.debug.print("{x:0>2}", .{b});
                        std.debug.print("\n", .{});
                    }
                }

                // §9.9-III (c)-2.3-β-2b per ADR-0066: allocate
                // per-module dispatch slice + thunk arena, then
                // resolve cross-module func imports against the
                // session's `registered` registry. Failures here
                // are compile-stage failures (FAIL + module_bad)
                // — the resolver's preconditions (registered
                // exporter compiles + has the named export) align
                // with how a real link would surface "unknown
                // function" / "incompatible import".
                if (compiled.num_imports > 0) {
                    const setup_ok = setup: {
                        const new_dispatch = gpa.alloc(usize, compiled.num_imports) catch |err| {
                            try stdout.print("FAIL  {s}/{s} dispatch alloc: {s}\n", .{ name, file, @errorName(err) });
                            break :setup false;
                        };
                        @memset(new_dispatch, @intFromPtr(&hostImportTrapStub));

                        const new_arena = shared_thunk.allocArena(compiled.num_imports) catch |err| {
                            gpa.free(new_dispatch);
                            try stdout.print("FAIL  {s}/{s} thunk arena alloc: {s}\n", .{ name, file, @errorName(err) });
                            break :setup false;
                        };

                        _ = resolveCrossModuleImports(
                            gpa,
                            wasm_bytes,
                            new_dispatch,
                            new_arena,
                            compiled.num_imports,
                            &registered,
                        ) catch |err| {
                            shared_thunk.freeArena(new_arena);
                            gpa.free(new_dispatch);
                            try stdout.print("FAIL  {s}/{s} resolve cross-module imports: {s}\n", .{ name, file, @errorName(err) });
                            break :setup false;
                        };

                        shared_thunk.finalizeArena(new_arena) catch |err| {
                            shared_thunk.freeArena(new_arena);
                            gpa.free(new_dispatch);
                            try stdout.print("FAIL  {s}/{s} thunk arena finalize: {s}\n", .{ name, file, @errorName(err) });
                            break :setup false;
                        };

                        current_dispatch = new_dispatch;
                        current_thunk_arena = new_arena;
                        break :setup true;
                    };
                    if (!setup_ok) {
                        tally.failed += 1;
                        module_bad = true;
                        continue;
                    }
                }

                callbacks.on_module_loaded(gpa, wasm_bytes, &compiled, stdout, name) catch |err| switch (err) {
                    // d-36: distinguished SKIP path for on_module_loaded
                    // — currently used by the start-fn invocation when
                    // an unbound host import trap surfaces, since the
                    // spec runner can't bind spectest imports
                    // (Track-D scope). The callback prints its own
                    // SKIP-* marker before returning.
                    error.SkipModule => {
                        tally.runtime_skip += 1;
                        module_bad = true;
                        continue;
                    },
                    // The callback printed its own init-specific FAIL line
                    // before returning the error; base just records the
                    // failure and marks module_bad to suppress cascade.
                    else => {
                        tally.failed += 1;
                        module_bad = true;
                        continue;
                    },
                };
            },
            .assert_return => {
                // ADR-0106 cycle 3e Phase 2'h step 2 (2026-05-23):
                // D-164 SKIP arm removed. The wrapper-thunk path
                // (`module.entry_buf` + buffer-write helpers, see
                // entry_buffer_write.invokeBufWin64NoArgs) bypasses
                // Win64's hidden-RCX struct-return ABI by using a
                // JIT-emitted wrapper that internally CALLs the body
                // via raw assembly (no callconv(.c) at the internal
                // call boundary). D-164 closed by the implementation
                // chain Phase 2'f–2'k (`4c7941c9` → `05ca0f05`).
                // Phase boundary windowsmini reconciliation per
                // ADR-0049 verifies runtime correctness.
                if (module_bad) {
                    tally.runtime_skip += 1;
                    continue;
                }
                const compiled_ptr: *const runner_mod.CompiledWasm = if (current_compiled) |*c| c else {
                    try stdout.print("FAIL  {s}: assert_return without prior module\n", .{name});
                    tally.failed += 1;
                    continue;
                };
                const wasm = current_wasm.?;
                pending_host_import_skip = false;
                host_import_stub_call_count = 0;
                host_import_stub_last_trap_flag = 0;
                const ok = callbacks.handle_assert_return(gpa, wasm, compiled_ptr, classified.body, stdout, name) catch |err| {
                    try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                if (ok) {
                    tally.passed += 1;
                } else if (pending_host_import_skip) {
                    tally.skipped_adr += 1;
                } else {
                    tally.failed += 1;
                }
            },
            .assert_trap => {
                // D-163 CLOSED at cycle 20 via D-166 fix
                // (`e5042b3e`): root cause was NOT a Win64-specific
                // trap-stub-RET issue but the spec runner's
                // scratch_typeidxs not being reset between modules.
                // The "silent process death" symptom on Win64 was a
                // wild call through a stale funcptr (sig-mismatch
                // false-negative because the leftover typeidx happened
                // to match the expected typeidx). With scratch_typeidxs
                // reset to maxInt(u32) sentinel between modules, OOB
                // call_indirect now correctly triggers the sig-mismatch
                // trap stub on all 3 hosts — the same trap stub the
                // bounds-check JAE would target. SKIP arm retired.
                if (module_bad) {
                    tally.runtime_skip += 1;
                    continue;
                }
                const compiled_ptr: *const runner_mod.CompiledWasm = if (current_compiled) |*c| c else {
                    try stdout.print("FAIL  {s}: assert_trap without prior module\n", .{name});
                    tally.failed += 1;
                    continue;
                };
                const wasm = current_wasm.?;
                const ok = callbacks.handle_assert_trap(gpa, wasm, compiled_ptr, classified.body, stdout, name) catch |err| {
                    try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                if (ok) tally.passed += 1 else tally.failed += 1;
            },
            .assert_exhaustion => {
                // d-62: same dispatch as assert_trap (the
                // PASS criterion — "invocation trapped" via
                // Error.Trap or SEGV-recovery — is identical
                // for our scaffold; trap-reason classification
                // is out of scope per D-022).
                //
                // ADR-0105 D5 (2026-05-23): D-162 close — Win64
                // assert_exhaustion skip arm REMOVED. The JIT-
                // prologue stack-probe (ADR-0105 D2, landed cycles
                // 2a-2c) traps cleanly via the dedicated stack-
                // overflow trap stub (kind=4) on all 3 hosts
                // BEFORE the OS guard page would fault — so Win64
                // no longer needs EXCEPTION_STACK_OVERFLOW
                // recovery (also removed from
                // `windows_traphandler.zig::vehHandler`).
                // POSIX paths unchanged: the probe replaces
                // SIGSEGV-handler+siglongjmp recovery as the
                // primary trap path; siglongjmp remains as a
                // safety net for memory-bounds traps.
                if (module_bad) {
                    tally.runtime_skip += 1;
                    continue;
                }
                const compiled_ptr: *const runner_mod.CompiledWasm = if (current_compiled) |*c| c else {
                    try stdout.print("FAIL  {s}: assert_exhaustion without prior module\n", .{name});
                    tally.failed += 1;
                    continue;
                };
                const wasm = current_wasm.?;
                const ok = callbacks.handle_assert_trap(gpa, wasm, compiled_ptr, classified.body, stdout, name) catch |err| {
                    try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                if (ok) tally.passed += 1 else tally.failed += 1;
            },
            .invoke_action => {
                if (module_bad) {
                    tally.runtime_skip += 1;
                    continue;
                }
                const compiled_ptr: *const runner_mod.CompiledWasm = if (current_compiled) |*c| c else {
                    try stdout.print("FAIL  {s}: invoke-action without prior module\n", .{name});
                    tally.failed += 1;
                    continue;
                };
                const wasm = current_wasm.?;
                pending_host_import_skip = false;
                host_import_stub_call_count = 0;
                host_import_stub_last_trap_flag = 0;
                const ok = callbacks.handle_invoke_action(gpa, wasm, compiled_ptr, classified.body, stdout, name) catch |err| {
                    try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                if (ok) {
                    tally.passed += 1;
                } else if (pending_host_import_skip) {
                    tally.skipped_adr += 1;
                } else {
                    tally.failed += 1;
                }
            },
            .get_action => {
                if (module_bad) {
                    tally.runtime_skip += 1;
                    continue;
                }
                const compiled_ptr: *const runner_mod.CompiledWasm = if (current_compiled) |*c| c else {
                    try stdout.print("FAIL  {s}: get-action without prior module\n", .{name});
                    tally.failed += 1;
                    continue;
                };
                const wasm = current_wasm.?;
                if (callbacks.handle_get_action) |handler| {
                    const ok = handler(gpa, wasm, compiled_ptr, classified.body, stdout, name) catch |err| {
                        try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
                        tally.failed += 1;
                        continue;
                    };
                    if (ok) tally.passed += 1 else tally.failed += 1;
                } else {
                    try stdout.print("SKIP-NON-INVOKE-ACTION  {s}: {s}\n", .{ name, line });
                    tally.skipped_adr += 1;
                }
            },
            .assert_invalid => {
                const file = classified.body;
                const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                    try stdout.print("FAIL  {s}/{s} (assert_invalid) read: {s}\n", .{ name, file, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                if (runner_mod.compileWasm(gpa, wasm_bytes)) |compiled_ok| {
                    var c = compiled_ok;
                    c.deinit(gpa);
                    try stdout.print("SKIP-VALIDATOR-GAP  {s}: assert_invalid {s}\n", .{ name, file });
                    tally.runtime_skip += 1;
                } else |_| {
                    tally.passed += 1;
                }
                gpa.free(wasm_bytes);
            },
            .assert_malformed => {
                const file = classified.body;
                const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                    try stdout.print("FAIL  {s}/{s} (assert_malformed) read: {s}\n", .{ name, file, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                if (runner_mod.compileWasm(gpa, wasm_bytes)) |compiled_ok| {
                    var c = compiled_ok;
                    c.deinit(gpa);
                    try stdout.print("SKIP-PARSER-GAP  {s}: assert_malformed {s}\n", .{ name, file });
                    tally.runtime_skip += 1;
                } else |_| {
                    tally.passed += 1;
                }
                gpa.free(wasm_bytes);
            },
            .assert_uninstantiable => {
                const file = classified.body;
                const cb = callbacks.handle_assert_uninstantiable orelse {
                    try stdout.print("SKIP-NO-INSTANTIATE-CB  {s}: assert_uninstantiable {s} (specialisation lacks callback)\n", .{ name, file });
                    tally.runtime_skip += 1;
                    continue;
                };
                const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                    try stdout.print("FAIL  {s}/{s} (assert_uninstantiable) read: {s}\n", .{ name, file, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                defer gpa.free(wasm_bytes);
                // d-37 pre-filter: cross-module-imports surface as
                // SKIP rather than failing the compile or
                // instantiation; assert_uninstantiable on such
                // modules is structurally untestable here.
                if (hasUnbindableImports(gpa, wasm_bytes, &registered)) {
                    try stdout.print("SKIP-CROSS-MODULE-IMPORTS  {s}/{s}: assert_uninstantiable on module the spec runner cannot bind\n", .{ name, file });
                    tally.runtime_skip += 1;
                    continue;
                }
                // Compile-stage failure is also a valid
                // `uninstantiable` outcome (the module never
                // becomes instantiable); count as PASS.
                var compiled_local = runner_mod.compileWasm(gpa, wasm_bytes) catch {
                    tally.passed += 1;
                    continue;
                };
                defer compiled_local.deinit(gpa);
                const ok = cb(gpa, wasm_bytes, &compiled_local, stdout, name) catch |err| {
                    try stdout.print("FAIL  {s}: assert_uninstantiable {s} callback errored: {s}\n", .{ name, file, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                if (ok) tally.passed += 1 else tally.failed += 1;
            },
            .assert_unlinkable => {
                const file = classified.body;
                const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                    try stdout.print("FAIL  {s}/{s} (assert_unlinkable) read: {s}\n", .{ name, file, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                defer gpa.free(wasm_bytes);
                // Path 1: hasUnbindableImports trips → structurally
                // unlinkable in our scaffold (any non-spectest
                // module name not in `registered` OR any non-function
                // spectest import). This catches the bulk of
                // imports.wast / linking.wast assert_unlinkable
                // cases ("unknown import").
                if (hasUnbindableImports(gpa, wasm_bytes, &registered)) {
                    tally.passed += 1;
                    continue;
                }
                // Path 2: compile-stage rejection (validator caught
                // the import-type mismatch via type-section /
                // import-section parse). Also a valid "unlinkable"
                // outcome.
                if (runner_mod.compileWasm(gpa, wasm_bytes)) |compiled_ok| {
                    var c = compiled_ok;
                    c.deinit(gpa);
                    // Path 3a (§9.12-E / B141): link-time
                    // import type-check vs the registered exporter
                    // map. A mismatch means the importer would
                    // fail to link → PASS assert_unlinkable. Per
                    // cycle 16 D-157 close, this covers all import
                    // kinds (func / table / memory / global).
                    if (hasIncompatibleImportType(gpa, wasm_bytes, &registered)) {
                        tally.passed += 1;
                        continue;
                    }
                    // Path 3b: module compiles, every bindable
                    // func import's type matches. Remaining
                    // assert_unlinkable cases need non-func
                    // import-type checking (table / memory /
                    // global) which is Track-D scope. SKIP-ADR
                    // for ratchet hygiene.
                    try stdout.print("SKIP-NO-LINK-TYPECHECK  {s}: assert_unlinkable {s} (compile + bindable; need non-func link-time type check)\n", .{ name, file });
                    tally.skipped_adr += 1;
                } else |_| {
                    tally.passed += 1;
                }
            },
            .register => {
                // Phase 9 §9.9-III chunk (c)-1c. Bind the current
                // module's wasm bytes under the alias. Skips when
                // no current module OR module is bad (consistent
                // with the upstream wast semantics — `(register)`
                // outside a module context is invalid).
                if (module_bad or current_wasm == null) {
                    tally.runtime_skip += 1;
                    continue;
                }
                const alias = classified.body;
                // Duplicate alias + bytes so the entry survives
                // the next `module` directive's free of current_wasm.
                const alias_owned = gpa.dupe(u8, alias) catch {
                    try stdout.print("FAIL  {s}: register {s} (alloc)\n", .{ name, alias });
                    tally.failed += 1;
                    continue;
                };
                const bytes_owned = gpa.dupe(u8, current_wasm.?) catch {
                    gpa.free(alias_owned);
                    try stdout.print("FAIL  {s}: register {s} (alloc)\n", .{ name, alias });
                    tally.failed += 1;
                    continue;
                };
                const gop = registered.getOrPut(gpa, alias_owned) catch {
                    gpa.free(alias_owned);
                    gpa.free(bytes_owned);
                    try stdout.print("FAIL  {s}: register {s} (map)\n", .{ name, alias });
                    tally.failed += 1;
                    continue;
                };
                if (gop.found_existing) {
                    // Re-register: deinit the prior exporter
                    // (frees its bytes + any lazy-compiled
                    // CompiledWasm) + free the duplicate alias
                    // key (the map already owns the original
                    // key). Wast semantics permit rebinding an
                    // alias.
                    gpa.free(alias_owned);
                    gop.value_ptr.deinit(gpa);
                    gop.value_ptr.* = .{ .bytes_owned = bytes_owned };
                } else {
                    gop.value_ptr.* = .{ .bytes_owned = bytes_owned };
                }
                // No tally bump: register is a directive, not an
                // assertion. Acknowledged silently.
            },
            .unknown => {
                try stdout.print("FAIL  {s}: unknown directive '{s}'\n", .{ name, line });
                tally.failed += 1;
            },
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "isSpectestNonFuncBindable: spectest.global_i32 as global i32 → true" {
    const imp: zwasm.parse.sections.Import = .{
        .module = "spectest",
        .name = "global_i32",
        .kind = .global,
        .payload = .{ .global = .{ .valtype = .i32, .mutable = false } },
    };
    try testing.expect(isSpectestNonFuncBindable(imp));
}

test "isSpectestNonFuncBindable: spectest.global_i32 as global f32 → false (valtype mismatch)" {
    const imp: zwasm.parse.sections.Import = .{
        .module = "spectest",
        .name = "global_i32",
        .kind = .global,
        .payload = .{ .global = .{ .valtype = .f32, .mutable = false } },
    };
    try testing.expect(!isSpectestNonFuncBindable(imp));
}

test "isSpectestNonFuncBindable: spectest.table as table → true" {
    const imp: zwasm.parse.sections.Import = .{
        .module = "spectest",
        .name = "table",
        .kind = .table,
        .payload = .{ .table = .{ .elem_type = .funcref, .min = 10, .max = 20 } },
    };
    try testing.expect(isSpectestNonFuncBindable(imp));
}

test "isSpectestNonFuncBindable: spectest.unknown → false (not in catalog)" {
    const imp: zwasm.parse.sections.Import = .{
        .module = "spectest",
        .name = "unknown",
        .kind = .global,
        .payload = .{ .global = .{ .valtype = .i32, .mutable = false } },
    };
    try testing.expect(!isSpectestNonFuncBindable(imp));
}

test "isSpectestNonFuncBindable: non-spectest module → false" {
    const imp: zwasm.parse.sections.Import = .{
        .module = "other_module",
        .name = "global_i32",
        .kind = .global,
        .payload = .{ .global = .{ .valtype = .i32, .mutable = false } },
    };
    try testing.expect(!isSpectestNonFuncBindable(imp));
}

test "parseI32Token: unsigned decimal" {
    try testing.expectEqual(@as(u32, 42), try parseI32Token("42"));
    try testing.expectEqual(@as(u32, 0), try parseI32Token("0"));
}

test "parseI32Token: negative decimal roundtrips through i32" {
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), try parseI32Token("-1"));
    try testing.expectEqual(@as(u32, 0x80000000), try parseI32Token("-2147483648"));
}

test "parseI32Token: out-of-range rejects" {
    try testing.expectError(error.BadValue, parseI32Token("9999999999"));
    try testing.expectError(error.BadValue, parseI32Token("abc"));
}

test "parseI64Token: signed/unsigned both roundtrip" {
    try testing.expectEqual(@as(u64, 42), try parseI64Token("42"));
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), try parseI64Token("-1"));
    try testing.expectEqual(@as(u64, 0x8000000000000000), try parseI64Token("-9223372036854775808"));
}

test "decodeFnName: no :hex: prefix passes through" {
    var buf: [16]u8 = undefined;
    const r = try decodeFnName("foo", &buf);
    try testing.expectEqualStrings("foo", r);
}

test "decodeFnName: :hex: empty → empty" {
    var buf: [16]u8 = undefined;
    const r = try decodeFnName(":hex:", &buf);
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "decodeFnName: :hex:0a09 → \\n\\t" {
    var buf: [16]u8 = undefined;
    const r = try decodeFnName(":hex:0a09", &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x0a, 0x09 }, r);
}

test "decodeFnName: :hex: utf8 multibyte (Å = 0xC3 0x85)" {
    var buf: [16]u8 = undefined;
    const r = try decodeFnName(":hex:c385", &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC3, 0x85 }, r);
}

test "decodeFnName: :hex: with odd hex length rejects" {
    var buf: [16]u8 = undefined;
    try testing.expectError(error.BadDirective, decodeFnName(":hex:abc", &buf));
}

test "decodeFnName: :hex: overflow buf rejects" {
    var buf: [2]u8 = undefined;
    try testing.expectError(error.BadDirective, decodeFnName(":hex:00112233", &buf));
}

test "splitFnAndArgs: unquoted name + args" {
    const r = try splitFnAndArgs("foo 1 2 3");
    try testing.expectEqualStrings("foo", r.fn_name);
    try testing.expectEqualStrings("1 2 3", r.args_s);
}

test "splitFnAndArgs: single-quoted name + args" {
    const r = try splitFnAndArgs("'v128.load align=16' 0 1");
    try testing.expectEqualStrings("v128.load align=16", r.fn_name);
    try testing.expectEqualStrings("0 1", r.args_s);
}

test "splitFnAndArgs: malformed (no close quote) rejects" {
    try testing.expectError(error.BadDirective, splitFnAndArgs("'foo bar"));
}

test "splitFnAndArgs: malformed (no space after close quote) rejects" {
    try testing.expectError(error.BadDirective, splitFnAndArgs("'foo'"));
}

test "classifySkipLine: skip-impl recognised" {
    try testing.expectEqual(SkipKind.skip_impl, classifySkipLine("skip-impl unsupported op"));
}

test "classifySkipLine: skip-adr-* recognised" {
    try testing.expectEqual(SkipKind.skip_adr, classifySkipLine("skip-adr-0029 waived"));
}

test "classifySkipLine: bare-legacy `skip ` recognised with WARN signal" {
    try testing.expectEqual(SkipKind.bare_legacy, classifySkipLine("skip legacy reason"));
}

test "classifySkipLine: regular directive returns .other" {
    try testing.expectEqual(SkipKind.other, classifySkipLine("assert_return foo 1"));
    try testing.expectEqual(SkipKind.other, classifySkipLine("module test.wasm"));
}

test "classifySkipLine: `skip-implfoo` (no space) is NOT classified as skip-impl" {
    // Defensive: the prefix is `skip-impl ` (with trailing space).
    // A directive named `skip-impl-something` shouldn't accidentally
    // route to skip-impl. classifySkipLine returns .other.
    try testing.expectEqual(SkipKind.other, classifySkipLine("skip-implfoo"));
}

test "AssertTally: defaults are zero" {
    const t: AssertTally = .{};
    try testing.expectEqual(@as(u32, 0), t.passed);
    try testing.expectEqual(@as(u32, 0), t.failed);
    try testing.expectEqual(@as(u32, 0), t.manifest_skip_impl);
    try testing.expectEqual(@as(u32, 0), t.runtime_skip);
    try testing.expectEqual(@as(u32, 0), t.skipped_adr);
}

test "classifyDirective: module strips `module ` prefix" {
    const r = classifyDirective("module test.wasm");
    try testing.expectEqual(DirectiveKind.module, r.kind);
    try testing.expectEqualStrings("test.wasm", r.body);
}

test "classifyDirective: assert_return strips prefix" {
    const r = classifyDirective("assert_return foo i32:42");
    try testing.expectEqual(DirectiveKind.assert_return, r.kind);
    try testing.expectEqualStrings("foo i32:42", r.body);
}

test "classifyDirective: assert_trap / assert_invalid / assert_malformed all routed" {
    try testing.expectEqual(DirectiveKind.assert_trap, classifyDirective("assert_trap bar").kind);
    try testing.expectEqual(DirectiveKind.assert_invalid, classifyDirective("assert_invalid baz").kind);
    try testing.expectEqual(DirectiveKind.assert_malformed, classifyDirective("assert_malformed qux").kind);
}

test "classifyDirective: unknown returns the full line in body" {
    const r = classifyDirective("garbage_line foo");
    try testing.expectEqual(DirectiveKind.unknown, r.kind);
    try testing.expectEqualStrings("garbage_line foo", r.body);
}

test "parseV128Token: 32 hex chars → 16 little-endian bytes" {
    const bytes = try parseV128Token("0102030405060708090a0b0c0d0e0f10");
    try testing.expectEqual(@as(u8, 0x01), bytes[0]);
    try testing.expectEqual(@as(u8, 0x10), bytes[15]);
}

test "parseV128Token: wrong length rejects" {
    try testing.expectError(error.BadValue, parseV128Token("0102"));
}

test "parseArgToken: scalar prefixes route to correct ArgKind" {
    const a = try parseArgToken("i32:42");
    try testing.expect(a == .i32);
    try testing.expectEqual(@as(u32, 42), a.i32);

    const b = try parseArgToken("i64:-1");
    try testing.expect(b == .i64);
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), b.i64);

    const c = try parseArgToken("f32:0");
    try testing.expect(c == .f32);

    const d = try parseArgToken("f64:0");
    try testing.expect(d == .f64);
}

test "parseArgToken: v128 returns 16-byte payload" {
    const a = try parseArgToken("v128:000102030405060708090a0b0c0d0e0f");
    try testing.expect(a == .v128);
    try testing.expectEqual(@as(u8, 0x00), a.v128[0]);
    try testing.expectEqual(@as(u8, 0x0f), a.v128[15]);
}

test "parseArgToken: unrecognised prefix rejects" {
    try testing.expectError(error.BadValue, parseArgToken("xyz:42"));
}

test "parseAssertReturnArgs: zero-arg form returns 0" {
    var buf: [4]ArgValue = undefined;
    try testing.expectEqual(@as(usize, 0), try parseAssertReturnArgs("()", &buf));
}

test "parseAssertReturnArgs: space-separated tokens" {
    var buf: [4]ArgValue = undefined;
    const n = try parseAssertReturnArgs("i32:1 i32:2 i32:3", &buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u32, 1), buf[0].i32);
    try testing.expectEqual(@as(u32, 2), buf[1].i32);
    try testing.expectEqual(@as(u32, 3), buf[2].i32);
}

test "parseAssertReturnArgs: TooManyArgs when buffer overflows" {
    var buf: [2]ArgValue = undefined;
    try testing.expectError(error.TooManyArgs, parseAssertReturnArgs("i32:1 i32:2 i32:3", &buf));
}

test "parseAssertReturnArgs: bad token propagates BadValue" {
    var buf: [4]ArgValue = undefined;
    try testing.expectError(error.BadValue, parseAssertReturnArgs("i32:1 xyz:2", &buf));
}

test "parseScalarFpExpected: nan:canonical / nan:arithmetic" {
    try testing.expectEqual(ScalarFpSpec.canonical, try parseScalarFpExpected("nan:canonical", 32));
    try testing.expectEqual(ScalarFpSpec.arithmetic, try parseScalarFpExpected("nan:arithmetic", 64));
}

test "parseScalarFpExpected: literal decimal routes to exact" {
    const got = try parseScalarFpExpected("42", 32);
    try testing.expect(got == .exact);
    try testing.expectEqual(@as(u64, 42), got.exact);
}

test "matchScalarF32: canonical NaN sign-agnostic" {
    try testing.expect(matchScalarF32(0x7fc00000, .canonical));
    try testing.expect(matchScalarF32(0xffc00000, .canonical));
    try testing.expect(!matchScalarF32(0x7fc00001, .canonical));
}

test "matchScalarF32: arithmetic NaN accepts any quiet NaN" {
    try testing.expect(matchScalarF32(0x7fc00000, .arithmetic));
    try testing.expect(matchScalarF32(0x7fc00001, .arithmetic));
    try testing.expect(matchScalarF32(0xffc00010, .arithmetic));
    // signalling NaN (mantissa MSB=0): rejected
    try testing.expect(!matchScalarF32(0x7f800001, .arithmetic));
}

test "matchScalarF32: exact bit-pattern equality" {
    try testing.expect(matchScalarF32(42, .{ .exact = 42 }));
    try testing.expect(!matchScalarF32(42, .{ .exact = 43 }));
}

test "matchScalarF64: canonical / arithmetic / exact" {
    try testing.expect(matchScalarF64(0x7ff8000000000000, .canonical));
    try testing.expect(matchScalarF64(0xfff8000000000000, .canonical));
    try testing.expect(matchScalarF64(0x7ff8000000000001, .arithmetic));
    try testing.expect(!matchScalarF64(0x7ff0000000000001, .arithmetic));
    try testing.expect(matchScalarF64(0xdeadbeef, .{ .exact = 0xdeadbeef }));
}

test "sigsegv guard: handler siglongjmps back to caller frame on raised SIGSEGV" {
    // POSIX-only test: the body exercises `std.posix.raise(.SEGV)`
    // + sigsetjmp recovery. Windows VEH equivalent (ADR-0103) is
    // exercised by `spec_assert_runner_non_simd` fixtures hitting
    // actual hardware faults — W4 reconcile validates that path.
    // SIBLING-AT: test/spec/spec_assert_runner_non_simd.zig (W4 VEH path)
    // — POSIX-only sigsetjmp; Windows path uses VEH per ADR-0103.
    if (comptime @import("builtin").os.tag == .windows) return;
    installSigsegvHandler();

    // Inline `sigsetjmp` — its captured frame is THIS test's
    // frame, so the handler's `siglongjmp` lands on the second
    // return below. `recovered` lives in module scope to survive
    // the longjmp (caller-frame locals may be in clobbered regs).
    const Recover = struct {
        var flag: bool = false;
    };
    Recover.flag = false;

    if (sigsetjmp(@ptrCast(&sigsegv_recover_buf), 1) == 0) {
        sigsegv_armed.store(true, .release);
        // Raise SIGSEGV; the handler longjmps back to the
        // sigsetjmp site, which then takes the else-branch.
        std.posix.raise(.SEGV) catch unreachable;
        // Should not reach: longjmp transferred control.
        try testing.expect(false);
    } else {
        sigsegv_armed.store(false, .release);
        Recover.flag = true;
    }

    try testing.expect(Recover.flag);
}

test "sigsegv guard: armed=false after recovery so subsequent SEGV is unexpected" {
    // POSIX-only — see prior `sigsegv guard` test.
    // SIBLING-AT: test/spec/spec_assert_runner_non_simd.zig (W4 VEH path)
    // — POSIX-only sigsetjmp; Windows path uses VEH per ADR-0103.
    if (comptime @import("builtin").os.tag == .windows) return;
    installSigsegvHandler();

    if (sigsetjmp(@ptrCast(&sigsegv_recover_buf), 1) == 0) {
        sigsegv_armed.store(true, .release);
        std.posix.raise(.SEGV) catch unreachable;
        try testing.expect(false);
    } else {
        // Recovery path must clear armed (handler does it; the
        // assertion confirms the contract end-to-end).
        try testing.expect(sigsegv_armed.load(.acquire) == false);
    }
}

test "RegisteredExporter γ-3.b-i: ensureCompiledAndRt populates scratch_func_entities + wires rt.func_entities_ptr" {
    // Minimal module with two defined functions so num_funcs > 0:
    //   (module (type (func)) (func) (func))
    //   magic + version : 00 61 73 6d 01 00 00 00
    //   type section    : id=01 size=04 count=01 func=60 0 params 0 results
    //   func section    : id=03 size=03 count=02 typeidx 00 00
    //   code section    : id=0a size=07 count=02 body0=(size=02 nlocals=00 end=0b) body1=same
    const wasm_bytes_const = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        // function
        0x03, 0x03,
        0x02, 0x00, 0x00,
        // code
        0x0a, 0x07, 0x02, 0x02, 0x00,
        0x0b, 0x02, 0x00, 0x0b,
    };
    const gpa = testing.allocator;
    var exporter: RegisteredExporter = .{ .bytes_owned = try gpa.dupe(u8, &wasm_bytes_const) };
    defer exporter.deinit(gpa);

    try exporter.ensureCompiledAndRt(gpa);

    const fe = exporter.scratch_func_entities orelse return error.MissingScratchFuncEntities;
    try testing.expectEqual(@as(usize, 2), fe.len);
    try testing.expectEqual(@as(u32, 0), fe[0].func_idx);
    try testing.expectEqual(@as(u32, 1), fe[1].func_idx);

    const rt = exporter.rt orelse return error.MissingRt;
    try testing.expectEqual(@as(usize, @intFromPtr(fe.ptr)), @intFromPtr(rt.func_entities_ptr));
    try testing.expectEqual(@as(u32, 2), rt.func_entities_count);
}

test "RegisteredExporter γ-3: ensureCompiledAndRt populates scratch_funcptrs + wires rt.funcptr_base" {
    // Minimal module exercising table-0 with one elem entry:
    //   (module
    //     (type (func))
    //     (func)              ;; func 0
    //     (table 1 funcref)
    //     (elem (i32.const 0) func 0))
    //   magic + version : 00 61 73 6d 01 00 00 00
    //   type section    : id=01 size=04 count=01 func=60 nparams=00 nresults=00
    //   func section    : id=03 size=02 count=01 typeidx=00
    //   table section   : id=04 size=04 count=01 funcref=70 flag=00 min=01
    //   elem section    : id=09 size=07 count=01 kind=00 offset=41 00 0b vec_count=01 funcidx=00
    //   code section    : id=0a size=04 count=01 body_size=02 nlocals=00 end=0b
    const wasm_bytes_const = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        // function
        0x03, 0x02,
        0x01, 0x00,
        // table
        0x04, 0x04, 0x01, 0x70, 0x00, 0x01,
        // element
        0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01,
        0x00,
        // code
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };
    const gpa = testing.allocator;
    var exporter: RegisteredExporter = .{ .bytes_owned = try gpa.dupe(u8, &wasm_bytes_const) };
    defer exporter.deinit(gpa);

    try exporter.ensureCompiledAndRt(gpa);

    const funcptrs = exporter.scratch_funcptrs orelse return error.MissingScratchFuncptrs;
    const typeidxs = exporter.scratch_typeidxs orelse return error.MissingScratchTypeidxs;
    try testing.expectEqual(@as(usize, 1), funcptrs.len);
    try testing.expectEqual(@as(usize, 1), typeidxs.len);
    // Table-0 entry 0 was initialised by the elem segment to func 0,
    // so its funcptr must be non-zero (= address inside the JIT
    // block) and the canonical typeidx for `(func)` is 0.
    try testing.expect(funcptrs[0] != 0);
    try testing.expectEqual(@as(u32, 0), typeidxs[0]);

    const rt = exporter.rt orelse return error.MissingRt;
    try testing.expectEqual(@as(usize, @intFromPtr(funcptrs.ptr)), @intFromPtr(rt.funcptr_base));
    try testing.expectEqual(@as(usize, @intFromPtr(typeidxs.ptr)), @intFromPtr(rt.typeidx_base));
    try testing.expectEqual(@as(u32, 1), rt.table_size);
}

test "RegisteredExporter γ-2: ensureCompiledAndRt populates scratch_memory + wires rt.vm_base" {
    // Minimal module: `(module (memory 1) (data (i32.const 0) "\\2a"))`.
    //   magic + version  : 00 61 73 6d 01 00 00 00
    //   memory section   : id=05 size=03 count=01 limits=00 (no max) min=01
    //   data section     : id=0b size=07 count=01 segkind=00 init_expr=41 00 0b
    //                      bytes_len=01 byte=2a
    const wasm_bytes_const = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // memory section
        0x05, 0x03, 0x01, 0x00, 0x01,
        // data section
        0x0b, 0x07, 0x01,
        0x00, 0x41, 0x00, 0x0b, 0x01, 0x2a,
    };
    const gpa = testing.allocator;
    var exporter: RegisteredExporter = .{ .bytes_owned = try gpa.dupe(u8, &wasm_bytes_const) };
    defer exporter.deinit(gpa);

    try exporter.ensureCompiledAndRt(gpa);

    const mem = exporter.scratch_memory orelse return error.MissingScratchMemory;
    // `(memory 1)` declares 1 page = 64 KiB; cap clamps no-ops here.
    try testing.expectEqual(@as(usize, 65536), mem.len);
    // Active data segment landed at offset 0 with byte 0x2a.
    try testing.expectEqual(@as(u8, 0x2a), mem[0]);
    try testing.expectEqual(@as(u8, 0x00), mem[1]);

    const rt = exporter.rt orelse return error.MissingRt;
    try testing.expectEqual(@as(usize, @intFromPtr(mem.ptr)), @intFromPtr(rt.vm_base));
    try testing.expectEqual(mem.len, rt.mem_limit);
}

test "RegisteredExporter D-142 (B): ensureCompiledAndRt avoids `undefined` poison for absent backing" {
    // Empty module `(module)` — magic + version only. Triggers
    // every absent-backing fallback in the rt init path: no
    // memory, no table, no funcs, no globals, no data, no elem.
    //
    // Pre-fix, the absent paths initialised the rt's `[*]const T`
    // pointer fields to `undefined`; Zig fills with 0xAA poison
    // in Debug. After a cross-module bridge thunk returned, the
    // importer's X19 carried the callee_rt pointer, and the
    // next host-import call dereferenced the poisoned
    // `host_dispatch_base` at offset +8 (= fault address
    // 0xAA...B2). Fix replaces every `undefined` with the named
    // `SAFE_STUB_PTR_ADDR` (= 0x1000) sentinel, matching the
    // pre-existing `vm_base` fallback shape. See
    // `.dev/lessons/2026-05-17-gamma3d-dispatch-write-segv-bisect.md`
    // and `.claude/rules/zig_tips.md` § "`undefined` in extern
    // struct fields".
    const wasm_bytes_const = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    };
    const gpa = testing.allocator;
    var exporter: RegisteredExporter = .{ .bytes_owned = try gpa.dupe(u8, &wasm_bytes_const) };
    defer exporter.deinit(gpa);

    try exporter.ensureCompiledAndRt(gpa);

    const rt = exporter.rt orelse return error.MissingRt;
    const stub: usize = SAFE_STUB_PTR_ADDR;
    try testing.expectEqual(stub, @intFromPtr(rt.funcptr_base));
    try testing.expectEqual(stub, @intFromPtr(rt.typeidx_base));
    try testing.expectEqual(stub, @intFromPtr(rt.host_dispatch_base));
    try testing.expectEqual(stub, @intFromPtr(rt.func_entities_ptr));
    try testing.expectEqual(stub, @intFromPtr(rt.elem_segments_ptr));
    try testing.expectEqual(stub, @intFromPtr(rt.elem_dropped_ptr));
    try testing.expectEqual(stub, @intFromPtr(rt.data_segments_ptr));
    try testing.expectEqual(stub, @intFromPtr(rt.data_dropped_ptr));
    // vm_base also takes the stub fallback (pre-existing path,
    // re-verified here so future refactors don't drop the
    // common shape).
    try testing.expectEqual(stub, @intFromPtr(rt.vm_base));
}

test "RegisteredExporter γ-1: ensureCompiledAndRt populates scratch_globals + wires rt.globals_base" {
    // Minimal module: `(module (func) (global i32 (i32.const 42)))`.
    // A `(func)` is included so `compileWasm` takes the full
    // globals-decoding path; the no-func-section early return at
    // `src/engine/runner.zig:585` short-circuits with
    // `globals_valtypes.len * 16 = 0` and would leave `scratch_globals`
    // an empty slice (= test pre-existing orphan rot surfaced
    // when the base file was wired into `zig build test`).
    //   magic + version : 00 61 73 6d 01 00 00 00
    //   type section    : id=01 size=04 count=01 func=60 0 params 0 results
    //   function section: id=03 size=02 count=01 typeidx 00
    //   global section  : id=06 size=06 count=01 i32=7f mut=00
    //                     init_expr=41 2a 0b
    //   code section    : id=0a size=04 count=01 body_size=02 nlocals=00 end=0b
    const wasm_bytes_const = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        // function
        0x03, 0x02,
        0x01, 0x00,
        // global
        0x06, 0x06, 0x01, 0x7f, 0x00, 0x41,
        0x2a, 0x0b,
        // code
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };
    const gpa = testing.allocator;
    var exporter: RegisteredExporter = .{ .bytes_owned = try gpa.dupe(u8, &wasm_bytes_const) };
    defer exporter.deinit(gpa);

    try exporter.ensureCompiledAndRt(gpa);

    const buf = exporter.scratch_globals orelse return error.MissingScratchGlobals;
    // Per ADR-0052 the i32 global occupies 8 bytes; check the
    // populated init value rather than just the buffer size.
    try testing.expect(buf.len >= 8);
    try testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, buf[0..8], .little));

    const rt = exporter.rt orelse return error.MissingRt;
    try testing.expectEqual(@as(usize, @intFromPtr(buf.ptr)), @intFromPtr(rt.globals_base));
}
