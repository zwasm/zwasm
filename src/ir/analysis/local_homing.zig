//! Register-homed scalar GPR locals — stage-1 plan (ADR-0155, D-265 Phase IV).
//!
//! A wasm local can be given a *register home* instead of a stack slot: the
//! local becomes a single function-spanning pseudo-vreg (mutable, multi-def),
//! loaded once in the prologue and read/written in-register for its whole
//! lifetime — so a loop body's `local.get`/`local.set` cost zero memory access
//! and the value crosses the loop back-edge in a register (the D-265 win).
//!
//! This module is the SINGLE SOURCE OF TRUTH for the plan. `liveness.compute`,
//! `regalloc_compute`, and the arm64 emit driver each
//! call `plan(func)` and MUST observe the identical mapping (the lockstep
//! invariant from the spike). Because every caller re-derives the plan purely
//! from `*const ZirFunc`, the three passes cannot drift.
//!
//! ## Numbering scheme (fix A — APPEND, ADR-0155 stage 1)
//!
//! The K pseudo-vregs are given the HIGHEST vreg ids, AFTER every temporary
//! vreg liveness mints during its operand-stack walk. So temporary numbering is
//! UNCHANGED vs the un-homed model — no shift, no renumbering of any
//! block/if/else/br arithmetic in liveness. The pseudo-vreg for the r-th homed
//! local has id `n_temp + r`, where `n_temp` is the count of temporary vregs
//! (= `liveness.ranges.len - K`). Regalloc then PRIORITISES these K high-id
//! pseudo-vregs onto the low register slots (0..K-1) so they stay
//! register-resident despite their high ids.
//!
//! ## Stage gates (conservative; widened in later ADR-0155 stages)
//!
//! - **aarch64 + x86_64** (stage 4 added x86_64) — K=0 on every other arch.
//!   The per-arch `max_homed` keeps `temp_reserve` GPRs for temporaries and,
//!   on x86_64, the homes inside the callee-saved head of the pool (cap 4 vs
//!   arm64's 6).
//! - **no GC/memory TRAMPOLINE op** (stage 2b) — `memory.grow`, `struct.new*`,
//!   `array.*`, `ref.test*`, `ref.cast*`, `br_on_cast*` route through a Zig
//!   trampoline whose caller-saved clobber the call-site spill/reload does not
//!   yet cover; any function containing one homes nothing. Plain calls
//!   (`.call` / `.call_indirect` / `.call_ref` / `.return_call*`) ARE allowed
//!   from stage 2: the arm64 op_call emit spills caller-saved homed locals
//!   before the BL/BLR and reloads them after (tail calls need no reload —
//!   control does not return).
//! - **scalar GPR locals only** — i32 / i64 / ref. f32/f64/v128 are FP-class
//!   (stage 3); GcRef stays slot-homed for GC-scan visibility (ADR-0155
//!   anti-regression invariant 2; reftype here means a non-GC funcref/externref
//!   which the conservative scan does not chase into registers — but to stay on
//!   the safe side we home only i32/i64, NOT ref, in stage 1).
//! - **capacity** — at most `max_homed` locals are homed (the low GPR slots
//!   reserved for homing); the rest stay slot-homed (overflow).
//!
//! Zone 1 (`src/ir/`).

const std = @import("std");
const builtin = @import("builtin");

const zir = @import("../zir.zig");

const ZirFunc = zir.ZirFunc;
const ZirOp = zir.ZirOp;
const ValType = zir.ValType;

/// Global ceiling on homed locals across all arches (ADR-0155). The per-arch
/// `max_homed` never exceeds this regardless of how many GPRs the arch has.
const max_homed_global: u32 = 6;

/// Temporaries always need *some* registers; reserve at least this many GPRs for
/// them so homing a function's locals never starves the greedy temporary scan
/// (the x86_64 SysV failure mode: 4 allocatable GPRs, all 4 reserved for homes →
/// every temporary spills → PERF REGRESSION). ADR-0155 stage 4.
const temp_reserve: u32 = 2;

/// GPRs the shared regalloc may assign on this build's target, and how many
/// of them, from slot 0, a home may occupy. Zone 1 cannot import the Zone-2
/// abi tables, so `x86_64/abi.zig` checks both against its pool at comptime.
/// A home keeps its register for the whole function and is saved only around
/// the call family, so on x86_64 it may sit only in the callee-saved head
/// (RBX, R12-R14) that a C callee preserves (D-268).
pub const n_allocatable_gpr: u32 = switch (builtin.target.cpu.arch) {
    .aarch64 => 8,
    .x86_64 => 8,
    else => 0,
};
pub const n_home_gpr: u32 = switch (builtin.target.cpu.arch) {
    .aarch64 => 8,
    .x86_64 => 4,
    else => 0,
};

/// Per-arch cap on homed locals, keeping `temp_reserve` registers for
/// temporaries: arm64 → 6, x86_64 → 4.
pub const max_homed: u32 = @min(max_homed_global, n_home_gpr, n_allocatable_gpr -| temp_reserve);

/// A resolved homing plan for one function. `count` pseudo-vregs are homed; the
/// homed local's absolute wasm local index is `local_idx[r]` for rank
/// `r in 0..count`. `rank_of[local_idx]` (via `rankOf`) is the inverse map.
pub const Plan = struct {
    count: u32 = 0,
    /// rank → absolute wasm local index. Only `[0..count)` is meaningful.
    local_idx: [max_homed]u32 = undefined,
    /// Absolute wasm local index → rank, or null when that local is NOT homed.
    /// Sized to the function's total local count at plan time; backed by
    /// `rank_buf`.
    rank_buf: [max_local_scan]i32 = undefined,
    n_locals: u32 = 0,

    /// Rank of a homed local, or null if `local_idx` is not register-homed.
    pub fn rankOf(self: *const Plan, local_idx: u32) ?u32 {
        if (local_idx >= self.n_locals) return null;
        const r = self.rank_buf[local_idx];
        if (r < 0) return null;
        return @intCast(r);
    }

    /// The pseudo-vreg id of a homed local given `n_temp` (the count of
    /// temporary vregs = `liveness.ranges.len - count`), or null if not homed.
    pub fn pseudoVreg(self: *const Plan, local_idx: u32, n_temp: u32) ?u32 {
        const r = self.rankOf(local_idx) orelse return null;
        return n_temp + r;
    }
};

/// Upper bound on locals we scan for homing eligibility. A function with more
/// locals than this homes nothing past the bound (the early ones still home).
const max_local_scan: u32 = 256;

/// True if the op routes through a GC/memory Zig TRAMPOLINE whose caller-saved
/// clobber is NOT covered by the arm64 op_call call-site spill/reload (stage 2b
/// territory). A function containing one of these homes nothing. Plain calls
/// (`.call` / `.call_indirect` / `.call_ref` / `.return_call*`) are deliberately
/// EXCLUDED here: from stage 2 they spill/reload caller-saved homed locals at
/// the BL/BLR emit site (`arm64/op_call.zig`).
fn isTrampolineLike(op: ZirOp) bool {
    return switch (op) {
        .@"memory.grow",
        .@"struct.new",
        .@"struct.new_default",
        .@"array.new",
        .@"array.new_default",
        .@"array.new_fixed",
        .@"array.fill",
        .@"array.copy",
        .@"array.new_data",
        .@"array.new_elem",
        .@"ref.test",
        .@"ref.test_null",
        .@"ref.cast",
        .@"ref.cast_null",
        .br_on_cast,
        .br_on_cast_fail,
        => true,
        else => false,
    };
}

/// Scalar GPR local eligible for register homing (stage 1): i32 / i64 only.
/// `ref` is excluded for GC-scan conservatism (ADR-0155 invariant 2); f32/f64
/// are FP-class (stage 3); v128 needs a V-register home (stage 3).
fn isHomeableType(ty: ValType) bool {
    return switch (ty) {
        .i32, .i64 => true,
        .f32, .f64, .v128, .ref => false,
    };
}

/// Compute the register-homing plan for `func`. Pure function of the ZirFunc;
/// every consumer (liveness / regalloc / emit) gets the identical
/// plan. Returns `count == 0` when homing is gated off (non-aarch64, or the
/// function contains a call-like op).
pub fn plan(func: *const ZirFunc) Plan {
    var p: Plan = .{};

    const num_params: u32 = @intCast(func.sig.params.len);
    const total_locals: u32 = num_params + func.totalLocalCount();
    p.n_locals = @min(total_locals, max_local_scan);
    var li: u32 = 0;
    while (li < p.n_locals) : (li += 1) p.rank_buf[li] = -1;

    // Gate: aarch64 + x86_64 (ADR-0155 stage 4 added x86_64 parity). Every
    // other arch homes nothing (no register-resident emit path).
    if (builtin.target.cpu.arch != .aarch64 and builtin.target.cpu.arch != .x86_64) return p;

    // Gate: no GC/memory trampoline op in the body (stage 2b). Plain calls are
    // allowed from stage 2 (op_call spills caller-saved homed locals at the
    // BL/BLR site).
    for (func.instrs.items) |ins| {
        if (isTrampolineLike(ins.op)) return p;
    }

    // Home the first `max_homed` scalar-GPR DECLARED locals in index order.
    // Stage 1 homes declared locals (index ≥ num_params) only, NOT params: the
    // D-265 win is loop-carried declared locals (w45 $i/$a, arr_sum/fp_sum), and
    // leaving params slot-homed keeps the AAPCS64 param-marshalling ABI (+ its
    // byte-pinned tests) untouched. Param homing is a later-stage refinement.
    var local_idx: u32 = num_params;
    while (local_idx < p.n_locals and p.count < max_homed) : (local_idx += 1) {
        const ty = func.localValType(local_idx);
        if (!isHomeableType(ty)) continue;
        p.local_idx[p.count] = local_idx;
        p.rank_buf[local_idx] = @intCast(p.count);
        p.count += 1;
    }

    return p;
}

const testing = std.testing;

/// True on the arches that have a register-resident emit path (aarch64 +
/// x86_64). Drives the arch-conditional test expectations: where homing is
/// active the asserted counts are capped by `max_homed`.
const homing_active: bool =
    builtin.target.cpu.arch == .aarch64 or builtin.target.cpu.arch == .x86_64;

fn freshFunc(locals: []const ValType) ZirFunc {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    return ZirFunc.init(0, sig, locals);
}

test "plan: homes scalar GPR locals where active, gated off elsewhere" {
    var f = freshFunc(&.{ .i32, .i32, .i32 });
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const p = plan(&f);
    if (homing_active) {
        // 3 i32 locals, all homeable — within max_homed on both arches.
        const want: u32 = @min(@as(u32, 3), max_homed);
        try testing.expectEqual(want, p.count);
        try testing.expectEqual(@as(?u32, 0), p.rankOf(0));
        // pseudo-vreg id = n_temp + rank.
        try testing.expectEqual(@as(?u32, 10), p.pseudoVreg(0, 10));
        if (max_homed >= 3) {
            try testing.expectEqual(@as(?u32, 2), p.rankOf(2));
            try testing.expectEqual(@as(?u32, 12), p.pseudoVreg(2, 10));
        }
    } else {
        try testing.expectEqual(@as(u32, 0), p.count);
        try testing.expectEqual(@as(?u32, null), p.rankOf(0));
    }
}

test "plan: a GC/memory trampoline op gates homing off (stage 2b)" {
    var f = freshFunc(&.{ .i32, .i32 });
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"memory.grow", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const p = plan(&f);
    try testing.expectEqual(@as(u32, 0), p.count);
}

test "plan: a plain call does NOT gate homing off (stage 2)" {
    // Stage 2 (ADR-0155 D-265 Phase IV) — a function whose only call-like ops
    // are plain calls homes its declared GPR locals; op_call spills the
    // caller-saved homes around the BL/BLR.
    var f = freshFunc(&.{ .i32, .i32 });
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const p = plan(&f);
    if (homing_active) {
        // 2 i32 locals, both homeable — within every arch's max_homed (≥ 2).
        try testing.expectEqual(@as(u32, 2), p.count);
    } else {
        try testing.expectEqual(@as(u32, 0), p.count);
    }
}

test "plan: f32/f64/v128/ref locals stay slot-homed (skipped)" {
    var f = freshFunc(&.{ .f32, .i32, .v128, .i64, ValType.funcref });
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const p = plan(&f);
    if (homing_active) {
        // Only local 1 (i32) and local 3 (i64) are homeable; both fit (≤ 2 ≤
        // every arch's max_homed). f32/v128/ref are skipped (not homeable).
        try testing.expectEqual(@as(u32, 2), p.count);
        try testing.expectEqual(@as(?u32, null), p.rankOf(0));
        try testing.expectEqual(@as(?u32, 0), p.rankOf(1));
        try testing.expectEqual(@as(?u32, null), p.rankOf(2));
        try testing.expectEqual(@as(?u32, 1), p.rankOf(3));
        try testing.expectEqual(@as(?u32, null), p.rankOf(4));
    }
}

test "plan: caps at max_homed" {
    var f = freshFunc(&@as([10]ValType, @splat(.i32)));
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const p = plan(&f);
    if (homing_active) {
        try testing.expectEqual(max_homed, p.count);
        try testing.expectEqual(@as(?u32, null), p.rankOf(max_homed)); // beyond cap
    }
}
