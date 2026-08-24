//! Single-function JIT pipeline driver (Step 4 / sub-7.5a).
//!
//! Lowers a Wasm function-body byte stream through the full
//! frontend → IR → regalloc → emit chain into a flat
//! `EmitOutput` ready for `jit/linker` to splice into a
//! JitModule.
//!
//! Pipeline:
//!   raw wasm code-section body
//!     → frontend.lowerer.lowerFunctionBody → ZirFunc
//!     → ir.liveness.compute                → Liveness
//!     → jit.regalloc.compute               → Allocation
//!     → jit_arm64.emit.compile             → EmitOutput
//!
//! This module is the integration point — each individual stage
//! has its own tests; this driver verifies they compose into a
//! callable function. The spec gate consumes this for
//! every spec testsuite assertion.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const zir = @import("../../../ir/zir.zig");
const ZirFunc = zir.ZirFunc;
const FuncType = zir.FuncType;
const lowerer = @import("../../../ir/lower.zig");
const liveness = @import("../../../ir/analysis/liveness.zig");
const loop_info_mod = @import("../../../ir/analysis/loop_info.zig");
const hoist = @import("../../../ir/hoist/pass.zig");
const coalesce = @import("../../../ir/coalesce/pass.zig");
const regalloc = @import("regalloc.zig");
const trace = @import("../../../diagnostic/trace.zig");
const dbg = @import("../../../support/dbg.zig");

/// 7.5-close-d042 / 7.8 prep: comptime arch dispatch. ARM64 hosts
/// (Mac) use `arm64/emit.zig`; x86_64 hosts (Linux + Windows) use
/// `x86_64/emit.zig`. Both expose the same `compile() / deinit() /
/// EmitOutput / Error / CallFixup` surface so the dispatch is a
/// pure import switch.
const emit = switch (builtin.target.cpu.arch) {
    .aarch64 => @import("../arm64/emit.zig"),
    .x86_64 => @import("../x86_64/emit.zig"),
    else => @compileError("unsupported host arch — JIT requires aarch64 or x86_64"),
};

/// ADR-0077 — per-arch op-internal scratch reservation lookup.
/// arm64 supplies the 5-D-133-handler reservation set via
/// `arm64/abi.zig::opScratchReservation`. x86_64 has no current
/// hardcoded op-internal scratch (per ADR-0077 §Consequences);
/// future SIMD work that introduces such patterns will add the
/// mirror table and switch this arm.
const scratch_reservations: ?regalloc.ScratchReservationFn = switch (builtin.target.cpu.arch) {
    .aarch64 => &@import("../arm64/abi.zig").opScratchReservation,
    .x86_64 => null,
    else => @compileError("unsupported host arch"),
};

pub const Error = lowerer.Error || liveness.Error || regalloc.Error || emit.Error || hoist.Error || coalesce.Error || Allocator.Error;

/// One function's compilation result. `func` retains lowered
/// ZIR + liveness for downstream consumers (debug dump,
/// regalloc.verify, etc.); `out` carries the emitted bytes +
/// call_fixups for `jit/linker.link`. Caller owns both —
/// pair with `deinitFuncResult` to free.
pub const FuncResult = struct {
    func: ZirFunc,
    alloc_result: regalloc.Allocation,
    out: emit.EmitOutput,
};

pub fn deinitFuncResult(allocator: Allocator, r: *FuncResult) void {
    emit.deinit(allocator, r.out);
    regalloc.deinit(allocator, r.alloc_result);
    if (r.func.liveness) |lv| liveness.deinit(allocator, lv);
    if (r.func.loop_info) |li| loop_info_mod.deinit(allocator, li);
    hoist.deinitArtifacts(allocator, &r.func);
    coalesce.deinitArtifacts(allocator, &r.func);
    if (r.func.pass_diagnostics) |pd| zir.deinitPassDiagnostics(allocator, pd);
    r.func.deinit(allocator);
}

/// Drive a single function body through the pipeline.
///
/// `func_idx` = wasm function index (passed through to ZirFunc).
/// `sig` = the function's FuncType.
/// `body` = the raw wasm code-section body for THIS function
///          (locals prefix + instructions, ending in `end`).
/// `locals` = the function's local-types list (post-decode).
/// `module_types` = the module's type table (for typeidx blocks).
/// `func_sigs` = sigs of all module functions (for `call N`),
///               wasm-space (imports first, defined after).
/// `num_imports` = leading wasm-space indices that name function
///                 imports (chunk 7.9-b foundation). The emit pass
///                 routes a `call N` with `N < num_imports` to the
///                 function-local trap stub instead of a body-
///                 relative BL/CALL — host-call dispatch lands at
///                 chunk 7.9-c.
pub fn compileOne(
    allocator: Allocator,
    func_idx: u32,
    sig: FuncType,
    body: []const u8,
    locals: []const zir.ValType,
    module_types: []const FuncType,
    func_sigs: []const FuncType,
    num_imports: u32,
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
    select_types: []const u8,
    /// ADR-0106 path (a) — result-marshal ABI selector for the
    /// JIT-emitted function. `.register_write` (default for legacy
    /// callsites) keeps the per-class C-ABI result regs (RAX/RDX
    /// or X0..X7,V0..V7). `.buffer_write` switches the emit to
    /// the uniform `fn(*JitRuntime, [*]u64 results, [*]const u64
    /// args) callconv(.c) ErrCode` shape. Set by upstream callers
    /// per-module (e.g. spec runner on Win64 for multi-result
    /// fixtures); ALL functions in one module must share the
    /// same ABI (per ADR-0106 §"The fundamental constraint").
    result_abi: @import("result_abi.zig").ResultAbi,
    /// ADR-0111 D4 — memory 0's idx_type. `.i32` (legacy
    /// ≤ 4 GiB; byte-identical fast path) or `.i64` (memory64
    /// 64-bit offset materialise + wrap-check). Per-module
    /// constant; codegen branches on it inside emitMemOp.
    memory0_idx_type: @import("../../../parse/sections.zig").MemoryEntry.IdxType,
    /// Wasm 3.0 EH (ADR-0120) — per-tag
    /// param counts threaded into per-arch EmitCtx for
    /// throw / try_table payload marshalling. `&.{}` for modules
    /// without tags.
    tag_param_counts: []const u32,
    /// GC-on-JIT: typeidx-indexed struct field counts (from
    /// the module's struct defs). Threaded into the lowerer so `struct.new`
    /// stamps its variadic field count into `ZirInstr.extra`. `&.{}` for
    /// modules without struct types.
    struct_field_counts: []const u32,
    /// GC-on-JIT: typeidx-indexed array element valtype bytes
    /// (0x78 i8 / 0x77 i16 / …). Threaded into the lowerer so `array.get_s`
    /// stamps the packed element width into `ZirInstr.extra` (the emit picks
    /// SXTB vs SXTH). `&.{}` for modules without array types.
    array_elem_valtypes: []const u8,
    /// GC-on-JIT (D-212) — typeidx-indexed struct field valtype byte
    /// rows. Referenced (not owned) by the produced `ZirFunc` so the
    /// regalloc vreg-class classifier + struct.get/array.get emit can
    /// FP-class f32/f64 field/element results. `&.{}` when no struct types.
    struct_field_valtypes: []const []const u8,
    /// D-235 — module-level func-subtyping flag (`usesTypeSubtyping`).
    /// Threaded into the per-arch EmitCtx so `call_indirect` routes through
    /// the `jitCallIndirectSubtypeOk` trampoline (the inline D-111 structural
    /// compare is finality/subtype-blind). `false` for non-subtyping modules.
    uses_type_subtyping: bool,
    /// ADR-0202 D4 — module-level guard-page bounds-elision flag. `true` only
    /// when memory0 qualifies (i32 × 64 KiB pages × guarded host) AND the
    /// engine knob is `.auto`. Threaded into the per-arch EmitCtx so memory0
    /// scalar accesses drop the inline check + force-emit the redirect stub.
    bounds_elided: bool,
    /// D-475 (table64) — per-table index types (imports-first wasm table
    /// index space). Attached to the produced `ZirFunc` so the table-op /
    /// call_indirect emitters pick 32- vs 64-bit index widths per table.
    /// `&.{}` for modules without tables (emitters default to `.i32`).
    table_idx_types: []const zir.IdxType,
) Error!FuncResult {
    var func = ZirFunc.init(func_idx, sig, locals);
    errdefer func.deinit(allocator);
    // D-212 — attach the module-level GC valtype tables so vregClassOfOp
    // + the gc-get emit can tell an f32/f64 field/element result apart
    // (→ FP-class). Set before regalloc/emit, which consult them.
    func.gc_array_elem_valtypes = array_elem_valtypes;
    func.gc_struct_field_valtypes = struct_field_valtypes;
    // D-235 — drives regalloc's inclusive force-spill of call_indirect
    // operands (so they survive the in-op subtype trampoline) + the
    // per-arch subtype emit path.
    func.uses_type_subtyping = uses_type_subtyping;
    // D-475 — per-table idx_type widths for the table-op emitters.
    func.table_idx_types = table_idx_types;

    // Per-pass diagnostic records (per ADR-0033).
    // Builds in-flight; transferred to `func.pass_diagnostics` at
    // function close. Comptime-elided when `trace.enabled == false`
    // (the ArrayList itself stays as an empty stack-resident value;
    // the `.append` calls fold to no-ops via the comptime branches).
    var pass_records: std.ArrayList(zir.PassRecord) = .empty;
    errdefer if (comptime trace.enabled) pass_records.deinit(allocator);

    trace.passEnter(func_idx, .lower);
    try lowerer.lowerFunctionBodyWith(allocator, body, &func, module_types, select_types, struct_field_counts, array_elem_valtypes);
    {
        const applied: u32 = @intCast(func.instrs.items.len);
        trace.passExit(func_idx, .lower, .{ .applied = applied, .skipped = 0, .extra = applied });
        if (comptime trace.enabled) {
            try pass_records.append(allocator, .{ .pass = .lower, .applied = applied, .skipped = 0, .extra = applied });
        }
    }

    // ZIR hoist pass with local-set/local-get
    // rewrite (D-053 redesign per amended ADR-0031). Lifts
    // loop-invariant `*.const` opcodes via fresh local indices,
    // decoupling the value's lifetime from operand-stack scope.
    // Pre-regalloc so the new `local.get` push order integrates
    // with liveness's vreg numbering naturally. Hoist is bounded
    // by a per-function MVP cap (`max_hoists_per_func` in
    // `pass.zig`) — functions with more hoist opportunities
    // skip transformation; the cap insulates the integration
    // from a still-unidentified emit-stage UnsupportedOp source
    // tracked under D-053.
    trace.passEnter(func_idx, .loop_info);
    const li = try loop_info_mod.compute(allocator, &func);
    errdefer loop_info_mod.deinit(allocator, li);
    func.loop_info = li;
    {
        const applied: u32 = @intCast(li.loop_headers.len);
        const total_blocks: u32 = @intCast(func.blocks.items.len);
        const skipped: u32 = if (total_blocks > applied) total_blocks - applied else 0;
        trace.passExit(func_idx, .loop_info, .{ .applied = applied, .skipped = skipped, .extra = 0 });
        if (comptime trace.enabled) {
            try pass_records.append(allocator, .{ .pass = .loop_info, .applied = applied, .skipped = skipped, .extra = 0 });
        }
    }

    trace.passEnter(func_idx, .hoist);
    try hoist.run(allocator, &func);
    errdefer hoist.deinitArtifacts(allocator, &func);
    {
        const applied: u32 = if (func.hoisted_constants) |h| @intCast(h.len) else 0;
        const synth: u32 = if (func.synthetic_locals) |s| @intCast(s.len) else 0;
        trace.passExit(func_idx, .hoist, .{ .applied = applied, .skipped = 0, .extra = synth });
        if (comptime trace.enabled) {
            try pass_records.append(allocator, .{ .pass = .hoist, .applied = applied, .skipped = 0, .extra = synth });
        }
    }

    trace.passEnter(func_idx, .liveness);
    const lv = try liveness.compute(allocator, &func, func_sigs, module_types);
    func.liveness = lv;
    // ZirFunc.deinit does NOT walk into the (optional) liveness
    // slot — that slot is owned by the FuncResult, freed via
    // `deinitFuncResult`. If regalloc / emit errors below, the
    // FuncResult is never constructed and the errdefer chain
    // would leak `lv.ranges`. Mirror deinitFuncResult's free
    // here so the unwind path is symmetric.
    errdefer liveness.deinit(allocator, lv);
    {
        const applied: u32 = @intCast(lv.ranges.len);
        trace.passExit(func_idx, .liveness, .{ .applied = applied, .skipped = 0, .extra = applied });
        if (comptime trace.enabled) {
            try pass_records.append(allocator, .{ .pass = .liveness, .applied = applied, .skipped = 0, .extra = applied });
        }
    }

    trace.passEnter(func_idx, .regalloc);
    // ADR-0060: force-spill threshold = max(GPR pool, FP pool) so
    // that call-crossing vregs of either class land in the spill
    // range. GPR class slot ≥ gpr_pool already spills via the
    // post-compute override; FP class needs the higher boundary or
    // it stays in V16..V28 / XMM8..13 (caller-clobbered on both
    // ABIs). The non-spans_call path is class-blind LIFO, so this
    // does not affect non-call-bearing functions.
    const force_spill_threshold: u16 = switch (builtin.target.cpu.arch) {
        .x86_64 => @max(
            @import("../x86_64/abi.zig").allocatable_gprs.len,
            @import("../x86_64/abi.zig").allocatable_xmms.len,
        ),
        .aarch64 => @max(
            @import("../arm64/abi.zig").allocatable_gprs.len,
            @import("../arm64/abi.zig").allocatable_v_regs.len,
        ),
        else => @compileError("unsupported host arch"),
    };
    // ADR-0077 fence supplier — arm64 supplies the 5-D-133-handler
    // reservation; x86_64 stays null (no current hardcoded
    // op-internal scratch). Comptime-resolved per
    // `scratch_reservations` const above.
    // ADR-0194 — the spill-frame origin = the per-arch GPR pool size
    // (the lowest slot id any class can spill at). Threaded into
    // `computeWith` so `spill_offsets` is sized+indexed from the SAME origin
    // `Allocation.slot()` resolves with (was: a hardcoded-8 sizing vs a
    // patched-pool resolve → the x86_64 v128-spill OOB, D-461).
    const gpr_pool: u16 = switch (builtin.target.cpu.arch) {
        .x86_64 => @import("../x86_64/abi.zig").allocatable_gprs.len,
        .aarch64 => @import("../arm64/abi.zig").allocatable_gprs.len,
        else => @compileError("unsupported host arch"),
    };
    var alloc = try regalloc.computeWith(allocator, &func, force_spill_threshold, scratch_reservations, gpr_pool);
    errdefer regalloc.deinit(allocator, alloc);
    // D-045 chunk 13b: the FP class boundary still needs the per-arch
    // override so slot ids past the host's XMM pool resolve to `.spill`
    // (not a null `slotToReg` the way the arm64-tuned default 13 would on
    // x86_64). The GPR boundary + spill-frame origin are now set at build
    // time by `computeWith(.., gpr_pool)` above (ADR-0194), so only
    // `max_reg_slots_fp` is patched here.
    switch (builtin.target.cpu.arch) {
        .x86_64 => {
            const x86_abi = @import("../x86_64/abi.zig");
            alloc.max_reg_slots_fp = x86_abi.allocatable_xmms.len;
        },
        .aarch64 => {
            // Default max_reg_slots_fp (13) already matches arm64.
        },
        else => @compileError("unsupported host arch"),
    }
    // D-489 diagnostic (ZWASM_DEBUG=regverify): run the regalloc overlap verifier
    // (test-only in production) on the live x86_64/arm64 allocation to catch an
    // invalid alloc (two liveness-overlapping vregs sharing a spill slot) on a real
    // module. Gated → zero cost off.
    if (dbg.on("regverify")) {
        regalloc.verifyWith(&func, alloc, scratch_reservations) catch |e| {
            std.debug.print("[regverify] func[{d}] FAIL: {s} (n_slots={d})\n", .{ func_idx, @errorName(e), alloc.n_slots });
        };
    }
    {
        const applied: u32 = alloc.n_slots;
        // High-water slot id ≈ `n_slots - 1` (the highest assigned
        // slot index); 0 when no slots assigned. `extra` carries
        // the high-water value per ADR-0033's per-pass table.
        const high_water: u32 = if (alloc.n_slots == 0) 0 else alloc.n_slots - 1;
        trace.passExit(func_idx, .regalloc, .{ .applied = applied, .skipped = 0, .extra = high_water });
        if (comptime trace.enabled) {
            try pass_records.append(allocator, .{ .pass = .regalloc, .applied = applied, .skipped = 0, .extra = high_water });
        }
    }

    // Post-regalloc slot-aliasing coalescer. Side-table metadata
    // pass; no IR or Allocation mutation. ADR-0035 designs the post-
    // regalloc slot-aliasing approach; ADR-0036 scopes this pass to
    // scaffolding-only with detection deferred to Phase 15.
    // The pass takes `alloc.slots` directly (not the full
    // `Allocation`) to keep coalesce in Zone 1 per
    // `.claude/rules/zone_deps.md`.
    try coalesce.run(allocator, &func, alloc.slots);
    errdefer coalesce.deinitArtifacts(allocator, &func);

    // ADR-0106 path (a) — set the result-marshal ABI on
    // the Allocation before the emit pass reads it. `alloc` is
    // a local `var`; the mutation is scoped to this function.
    alloc.result_abi = result_abi;
    trace.passEnter(func_idx, .emit);
    const out = try emit.compile(allocator, &func, alloc, func_sigs, module_types, num_imports, globals_offsets, globals_valtypes, memory0_idx_type, tag_param_counts, uses_type_subtyping, bounds_elided);
    errdefer emit.deinit(allocator, out);
    {
        const applied: u32 = @intCast(func.instrs.items.len);
        const bytes_emitted: u32 = @intCast(out.bytes.len);
        trace.passExit(func_idx, .emit, .{ .applied = applied, .skipped = 0, .extra = bytes_emitted });
        if (comptime trace.enabled) {
            try pass_records.append(allocator, .{ .pass = .emit, .applied = applied, .skipped = 0, .extra = bytes_emitted });
        }
    }

    if (comptime trace.enabled) {
        func.pass_diagnostics = .{ .entries = try pass_records.toOwnedSlice(allocator) };
    }

    return .{
        .func = func,
        .alloc_result = alloc,
        .out = out,
    };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const skip = @import("../../../test_support/skip.zig");
const linker = @import("linker.zig");
const entry = @import("entry.zig");

test "compileOne: pass_diagnostics records all 6 passes when trace enabled" {
    if (!trace.enabled) return error.SkipZigTest; // build-flag gate; ADR-0122 D7 exempt
    // D-193 triage: ungated. Pure compile-pipeline inspection (no JIT
    // execution) — portable across all hosts.
    trace.clear();

    // Pure instruction bytes: `i32.const 7` (0x41 0x07) + `end` (0x0B).
    const body = [_]u8{ 0x41, 0x07, 0x0B };
    const sig: FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var r = try compileOne(testing.allocator, 42, sig, &body, &.{}, &.{}, &.{sig}, 0, &.{}, &.{}, &.{}, .register_write, .i32, &.{}, &.{}, &.{}, &.{}, false, false, &.{});
    defer deinitFuncResult(testing.allocator, &r);

    // Per-function slot populated with 6 records, in pipeline order.
    try testing.expect(r.func.pass_diagnostics != null);
    const entries = r.func.pass_diagnostics.?.entries;
    try testing.expectEqual(@as(usize, 6), entries.len);
    try testing.expectEqual(trace.PassId.lower, entries[0].pass);
    try testing.expectEqual(trace.PassId.loop_info, entries[1].pass);
    try testing.expectEqual(trace.PassId.hoist, entries[2].pass);
    try testing.expectEqual(trace.PassId.liveness, entries[3].pass);
    try testing.expectEqual(trace.PassId.regalloc, entries[4].pass);
    try testing.expectEqual(trace.PassId.emit, entries[5].pass);
    // Lower processed at least 2 instructions (i32.const + end).
    try testing.expect(entries[0].applied >= 2);
    // No loops in this module: loop_info applied = 0.
    try testing.expectEqual(@as(u32, 0), entries[1].applied);
    // Hoist found nothing to hoist (no loops): applied = 0, synth = 0.
    try testing.expectEqual(@as(u32, 0), entries[2].applied);
    try testing.expectEqual(@as(u32, 0), entries[2].extra);
    // Emit produced non-zero bytes.
    try testing.expect(entries[5].extra > 0);

    // Ringbuffer captured 12 events (6 enter + 6 exit).
    try testing.expectEqual(@as(u64, 12), trace.writeCount());
}

test "compileOne: tiny straight-line module — (func (result i32) i32.const 7 end) returns 7" {
    // D-193 triage: ungated. compileOne (comptime arch dispatch) +
    // callI32NoArgs (callconv .c) are portable; mac-arm64 + linux-x86_64
    // both execute. Win deferred per ADR-0122 phaseEnd batch.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // Pure instruction bytes (locals prefix is consumed by
    // sections.decodeCodes before this function): `i32.const 7`
    // (0x41 0x07) + `end` (0x0B).
    const body = [_]u8{ 0x41, 0x07, 0x0B };
    const sig: FuncType = .{ .params = &.{}, .results = &.{.i32} };

    var r = try compileOne(testing.allocator, 0, sig, &body, &.{}, &.{}, &.{sig}, 0, &.{}, &.{}, &.{}, .register_write, .i32, &.{}, &.{}, &.{}, &.{}, false, false, &.{});
    defer deinitFuncResult(testing.allocator, &r);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = r.out.bytes, .call_fixups = r.out.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: entry.JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const result = try entry.callI32NoArgs(module, 0, &rt);
    try testing.expectEqual(@as(u32, 7), result);
}
