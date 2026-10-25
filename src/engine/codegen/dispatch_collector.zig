//! Zone 2 codegen dispatch collector — arm64 / x86_64 axes per ADR-0074
//! (per-op file zone split along axis boundary).
//!
//! ## Why this file exists
//!
//! ADR-0073 + ADR-0023 §4.5 amend established the per-op file pattern;
//! ADR-0074 refined it: the 5 dispatch axes split across two
//! zones to keep handler bodies at the same zone as their ctx types
//! (preserves comptime DCE on every axis).
//!
//!   Zone 1 collector: `src/ir/dispatch_collector.zig`
//!     IRAxis = { .validate, .lower, .interp }
//!     Imports `src/instruction/wasm_X_Y/<op>.zig` (Zone 1).
//!
//!   Zone 2 collector: THIS FILE.
//!     ArchAxis = { .arm64, .x86_64 }
//!     Imports `src/engine/codegen/<arch>/ops/wasm_X_Y/<op>.zig`
//!     (Zone 2). Each arch op file in turn imports the Zone 1
//!     identity anchor for `op_tag` / `wasm_level` / `wasi_level`.
//!
//! The two collectors share `WasmLevel` / `WasiLevel` / `enabledByBuild`
//! (re-exported from Zone 1) so the build-option filter applies
//! uniformly across all 5 axes.
//!
//! ## Dispatch contract
//!
//! `dispatch(axis, op, args)` returns `!bool`:
//!   - `true`: the per-arch handler for `op` ran (errors propagated
//!     via the `try`-propagating inferred error set).
//!   - `false`: no per-arch op file is registered for `op` (= legacy
//!     switch in `<arch>/emit.zig` retains authority).
//!   - error: whatever the per-arch handler raised; the caller's
//!     enclosing fn's `Error` set must include it (per-arch handlers
//!     return `arm64/ctx.Error!void` or `x86_64/ctx.Error!void`,
//!     matching the wire-call's enclosing fn).
//!
//! Per-arch op file shape:
//!
//!   pub const op_tag: ZirOp = ...;        // mirrored from Zone 1
//!   pub const wasm_level: ?WasmLevel = ...;
//!   pub const wasi_level: ?WasiLevel = ...;
//!   pub fn emit(...) Error!void { ... }   // real body; per-arch ctx
//!
//! Zone 2 (`src/engine/codegen/`).

const std = @import("std");
const zir = @import("../../ir/zir.zig");
const ir_collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;

pub const WasmLevel = ir_collector.WasmLevel;
pub const WasiLevel = ir_collector.WasiLevel;
pub const enabledByBuild = ir_collector.enabledByBuild;

/// Per-arch codegen axes (per ADR-0074). The IR-axis counterparts
/// live at Zone 1's `IRAxis` enum.
pub const ArchAxis = enum {
    arm64,
    x86_64,
};

/// Comptime contract check for per-arch op modules.
pub fn validateArchOpModule(comptime mod: type) void {
    comptime {
        if (!@hasDecl(mod, "op_tag")) {
            @compileError("per-arch op file missing `pub const op_tag: ZirOp = ...;`");
        }
        if (!@hasDecl(mod, "wasm_level")) {
            @compileError("per-arch op file missing `pub const wasm_level: ?WasmLevel = ...;`");
        }
        if (!@hasDecl(mod, "emit")) {
            @compileError("per-arch op file missing `pub fn emit(...) Error!void { ... }`");
        }
    }
}

/// ADR-0113 §A — regalloc 3-axis classification. A per-op file
/// may declare any subset of `{is_terminator, n_successor_edges,
/// is_safepoint}`; absent declarations fall back to safe
/// defaults that match the regular-call shape (returns to
/// caller, single successor, no GC safepoint). The defaults are
/// chosen so a per-op file that hasn't opted into the 3-axis
/// regime still classifies sanely for the regalloc layer.
///
/// As regalloc consumers come online (tail-call terminator-class,
/// EH N-successor catch dispatch, GC stack-map safepoint
/// walking), per-op files opt in by overriding the axes they
/// diverge from. Per ADR-0113 §A's per-op file convention.
pub const Axis3 = struct {
    is_terminator: bool,
    n_successor_edges: u8,
    is_safepoint: bool,
};

pub fn axisOf(comptime mod: type) Axis3 {
    return comptime .{
        .is_terminator = if (@hasDecl(mod, "is_terminator")) mod.is_terminator else false,
        .n_successor_edges = if (@hasDecl(mod, "n_successor_edges")) mod.n_successor_edges else 1,
        .is_safepoint = if (@hasDecl(mod, "is_safepoint")) mod.is_safepoint else false,
    };
}

// ---------------------------------------------------------------------
// Per-arch collected op modules.
// ---------------------------------------------------------------------

// Op registry extracted to `dispatch_collector_ops.zig` per ADR-0086
// (mirror of ADR-0082's ir/dispatch_collector_ops.zig). The dispatcher
// framework + comptime validation stays in this file.
const ops_registry = @import("dispatch_collector_ops.zig");
pub const collected_arm64_ops = ops_registry.collected_arm64_ops;
pub const collected_x86_64_ops = ops_registry.collected_x86_64_ops;
pub const collected_x86_64_ctx_ops = ops_registry.collected_x86_64_ctx_ops;

comptime {
    @setEvalBranchQuota(10_000);
    for (collected_arm64_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
    for (collected_x86_64_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
    for (collected_x86_64_ctx_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
}

/// Count of registered arch ops, filtered by the active build
/// options. All comptime-resolved.
pub fn migratedArchOpCount(comptime axis: ArchAxis) usize {
    return comptime blk: {
        @setEvalBranchQuota(10_000);
        const ops = switch (axis) {
            .arm64 => collected_arm64_ops,
            .x86_64 => collected_x86_64_ops,
        };
        var n: usize = 0;
        for (ops) |op_mod| {
            if (enabledByBuild(op_mod)) {
                n += 1;
            }
        }
        break :blk n;
    };
}

/// Per-arch dispatch. Returns `true` if the per-arch handler ran;
/// `false` if no per-arch op file is registered (legacy switch should
/// take over). Handler errors propagate via the inferred error set.
///
/// `args` is a tuple matching the per-arch `emit` function's signature
/// (per-arch ctx types are Zone 2 concerns).
pub fn dispatch(comptime axis: ArchAxis, op: ZirOp, args: anytype) !bool {
    const ops = comptime switch (axis) {
        .arm64 => collected_arm64_ops,
        .x86_64 => collected_x86_64_ops,
    };
    inline for (ops) |op_mod| {
        if (comptime !enabledByBuild(op_mod)) continue;
        if (op == op_mod.op_tag) {
            try @call(.auto, op_mod.emit, args);
            return true;
        }
    }
    return false;
}

/// Inline-switch dispatcher for the x86_64 `(ctx, ins)` cohort
/// (ADR-0073 + ADR-0075). Walks `collected_x86_64_ctx_ops` and
/// dispatches to the matching per-op file's `emit(ctx, ins)`. Returns
/// `true` if handled; `false` lets
/// the giant switch in `x86_64/emit.zig` take over for ops outside
/// the ctx tuple (extract_lane / replace_lane / shuffle / i64x2.mul
/// / v128.const / load_lane / store_lane / popcnt / trunc_sat_f64x2
/// / convert_low_i32x4_u — payload-laden or no-Zone-1-meta).
pub fn dispatchX86_64Ctx(op: ZirOp, ctx_ptr: anytype, ins_ptr: anytype) !bool {
    @setEvalBranchQuota(20_000);
    inline for (collected_x86_64_ctx_ops) |op_mod| {
        if (comptime !enabledByBuild(op_mod)) continue;
        if (op == op_mod.op_tag) {
            try op_mod.emit(ctx_ptr, ins_ptr);
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------

test "ArchAxis enum has exactly 2 variants per ADR-0074 (Zone 2 arch-axes)" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(ArchAxis).@"enum".field_names.len);
}

test "migratedArchOpCount tracks collected per-arch tuples (arm64=409, x86_64=0)" {
    try std.testing.expectEqual(@as(usize, 409), migratedArchOpCount(.arm64));
    // x86_64's legacy (args-tuple) collection is empty — every x86_64 op
    // uses the `(ctx, ins)` shape, tracked in `collected_x86_64_ctx_ops`.
    try std.testing.expectEqual(@as(usize, 0), migratedArchOpCount(.x86_64));
}

test "collected_x86_64_ctx_ops tracks ctx-op migrations to `(ctx, ins)` shape" {
    try std.testing.expectEqual(@as(usize, 432), collected_x86_64_ctx_ops.len);
}

// Note: a `dispatch(.arm64, tag, args)` test at this layer would
// fail to compile because `inline for` expands the `@call(.auto,
// op_mod.emit, args)` at comptime against every registered per-arch
// handler — handlers require their real ctx tuples, not a smoke
// `.{}`. The dispatcher's wire contract is covered by integration
// tests at `arm64/emit.zig` (and `x86_64/emit.zig`) going through
// real spec-driven fixtures.

// ADR-0113 §A: 3-axis classification — comptime tests.

test "axisOf: per-op file without explicit axes falls back to call defaults" {
    // A struct with no axis declarations should resolve to the
    // "regular call" defaults: returns to caller, 1 successor,
    // not a safepoint.
    const FakeOp = struct {};
    const axis = axisOf(FakeOp);
    try std.testing.expectEqual(false, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 1), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: arm64 ops/wasm_1_0/call.zig declares regular-call axes (ADR-0113 §A)" {
    const call_mod = @import("arm64/ops/wasm_1_0/call.zig");
    const axis = axisOf(call_mod);
    try std.testing.expectEqual(false, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 1), axis.n_successor_edges);
    try std.testing.expectEqual(true, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_1_0/call.zig declares regular-call axes (ADR-0113 §A)" {
    const call_mod = @import("x86_64/ops/wasm_1_0/call.zig");
    const axis = axisOf(call_mod);
    try std.testing.expectEqual(false, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 1), axis.n_successor_edges);
    try std.testing.expectEqual(true, axis.is_safepoint);
}

test "axisOf: partial override — only is_terminator declared, others default" {
    const FakeTerminatorOp = struct {
        pub const is_terminator: bool = true;
    };
    const axis = axisOf(FakeTerminatorOp);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 1), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

// ADR-0112 D2 + ADR-0113 §A — return_call / return_call_indirect /
// return_call_ref are terminators (frame teardown + tail-jump
// leaves the function): is_terminator=true, n_successor_edges=0,
// is_safepoint=false (safepoint-free invariant between teardown
// and BR/JMP per ADR-0112 D7).

test "axisOf: arm64 ops/wasm_3_0/return_call.zig declares terminator axes (ADR-0112 + ADR-0113 §A)" {
    const rc_mod = @import("arm64/ops/wasm_3_0/return_call.zig");
    const axis = axisOf(rc_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: arm64 ops/wasm_3_0/return_call_indirect.zig declares terminator axes" {
    const rci_mod = @import("arm64/ops/wasm_3_0/return_call_indirect.zig");
    const axis = axisOf(rci_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: arm64 ops/wasm_3_0/return_call_ref.zig declares terminator axes" {
    const rcr_mod = @import("arm64/ops/wasm_3_0/return_call_ref.zig");
    const axis = axisOf(rcr_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_3_0/return_call.zig declares terminator axes" {
    const rc_mod = @import("x86_64/ops/wasm_3_0/return_call.zig");
    const axis = axisOf(rc_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_3_0/return_call_indirect.zig declares terminator axes" {
    const rci_mod = @import("x86_64/ops/wasm_3_0/return_call_indirect.zig");
    const axis = axisOf(rci_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_3_0/return_call_ref.zig declares terminator axes" {
    const rcr_mod = @import("x86_64/ops/wasm_3_0/return_call_ref.zig");
    const axis = axisOf(rcr_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

// ADR-0114 D2/D6 + ADR-0113 §A/B — EH op axes:
//   try_table = fallthrough (NOT terminator), 1 successor edge
//     per the catch-all per-op constant (per-callsite N
//     populated at lower time per ADR-0113 D3), not a safepoint.
//   throw / throw_ref = terminator (CALL into dispatcher;
//     never returns to caller), 0 in-function CFG edges, not
//     a safepoint (mirrors tail-call shape).

test "axisOf: arm64 ops/wasm_3_0/try_table.zig declares fallthrough axes (ADR-0114 D2)" {
    const tt_mod = @import("arm64/ops/wasm_3_0/try_table.zig");
    const axis = axisOf(tt_mod);
    try std.testing.expectEqual(false, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 1), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: arm64 ops/wasm_3_0/throw.zig declares terminator axes (ADR-0114 D6)" {
    const th_mod = @import("arm64/ops/wasm_3_0/throw.zig");
    const axis = axisOf(th_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: arm64 ops/wasm_3_0/throw_ref.zig declares terminator axes" {
    const tr_mod = @import("arm64/ops/wasm_3_0/throw_ref.zig");
    const axis = axisOf(tr_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_3_0/try_table.zig declares fallthrough axes" {
    const tt_mod = @import("x86_64/ops/wasm_3_0/try_table.zig");
    const axis = axisOf(tt_mod);
    try std.testing.expectEqual(false, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 1), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_3_0/throw.zig declares terminator axes" {
    const th_mod = @import("x86_64/ops/wasm_3_0/throw.zig");
    const axis = axisOf(th_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_3_0/throw_ref.zig declares terminator axes" {
    const tr_mod = @import("x86_64/ops/wasm_3_0/throw_ref.zig");
    const axis = axisOf(tr_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}
