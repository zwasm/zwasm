//! Parallel-move + merge-MOV helpers for ARM64 control-flow
//! emit handlers — extracted from `op_control.zig` per ADR-0093.
//!
//! Private helper cluster: `ParallelMove` struct + cycle-aware
//! batch resolver + per-move emitter + branch-merge capturer +
//! arity unpacker. Used only by `op_control.zig`'s emit handlers
//! (block / loop / br / br_if / br_table / if / else / end).
//! Pub-ified for cross-file access; no external callers — pub
//! surface bounded to op_control.zig's internal use.
//!
//! See lesson `2026-05-18-parallel-move-cycle-in-if-merge.md`
//! (D-147) for the cycle-aware resolver design.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const ctx_mod = @import("ctx.zig");
const abi = @import("abi.zig");
const inst = @import("inst.zig");
const inst_fp = @import("inst_fp.zig");
const gpr = @import("gpr.zig");
const inst_neon = @import("inst_neon.zig");
const regalloc = @import("../shared/regalloc.zig");

const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

const merge_top_vregs_cap: u8 = 8;

/// D-147 / lesson `2026-05-18-parallel-move-cycle-in-if-merge.md`:
/// resolve a batch of GPR register-to-register merge moves
/// (cycle-aware), breaking any cycle via X16 (IP0; caller-saved,
/// outside the regalloc pool and outside the `abi.spill_stage_gprs`
/// X14/X15 cohort — safe scratch for the duration of the merge
/// batch).
///
/// Algorithm: iterate until empty. At each step, find a LEAF (a
/// pending move whose destination register is no other pending
/// move's source). Emit it and remove. If no leaf exists →
/// CYCLE: save one pending move's dst to X16, rewrite all pending
/// sources that referred to that register to use X16 instead.
/// Re-iterate (a leaf will now exist because the cycle is broken).
///
/// Cost: 1 extra MOV per cycle (regardless of cycle length).
/// O(N²) loop is fine for N ≤ `merge_top_vregs_cap` = 8.
// Same-file helper; not called outside this module (per ADR-0094 audit).
fn resolveAndEmitMergeMovsRegBatch(ctx: *EmitCtx, moves: []ParallelMove) Error!void {
    var pending: u32 = 0;
    for (moves) |m| {
        if (!m.done) pending += 1;
    }
    while (pending > 0) {
        var leaf_idx: ?usize = null;
        for (moves, 0..) |m, i| {
            if (m.done) continue;
            var has_user = false;
            for (moves, 0..) |o, j| {
                if (i == j or o.done) continue;
                if (m.dst_reg == o.src_reg) {
                    has_user = true;
                    break;
                }
            }
            if (!has_user) {
                leaf_idx = i;
                break;
            }
        }
        if (leaf_idx) |idx| {
            const m = moves[idx];
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(m.dst_reg, 31, m.src_reg));
            moves[idx].done = true;
            pending -= 1;
        } else {
            // Cycle. Save first pending move's dst to X16; rewrite
            // any pending move whose src is that register to use X16.
            for (moves, 0..) |m, i| {
                if (m.done) continue;
                const cycle_dst = m.dst_reg;
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(16, 31, cycle_dst));
                for (moves, 0..) |o, j| {
                    if (o.done or j == i) continue;
                    if (o.src_reg == cycle_dst) moves[j].src_reg = 16;
                }
                break;
            }
            // No move removed this iteration; loop will find the leaf next.
        }
    }
}

// SIBLING-PUB: op_control.zig (per ADR-0093 extraction)
pub const ParallelMove = struct {
    src_reg: inst.Xn,
    dst_reg: inst.Xn,
    done: bool,
};

/// D-097 (ADR-0060 follow-up): unified merge-MOV dispatcher.
///
/// Copies `src_vreg`'s value into `merge_vreg`'s storage. Picks the
/// right register-class path:
///   - `.v128` (per `alloc.shapeTag`)  → q-form (16-byte) MOV
///   - `.fpr`  (per `regalloc.vregClass`) → FMOV D (8-byte)
///   - `.gpr`  (default)                → 32-bit ORR (legacy)
///
/// Earlier code only dispatched on `.v128` — FP scalar fell through
/// to GPR MOV which silently corrupted f32/f64 if-frame merges
/// because the GPR view of an FP slot is a different physical
/// register on both arm64 (X_n vs V_n) and x86_64 (RBX vs XMM8
/// etc.). compose_no_call.wat on x86_64 + the 8 x86_64-specific
/// `if.wast` residuals all traced back to this single gap.
///
/// `stage_src` / `stage_dst` index the per-class spill stage
/// register pool so concurrent loads + defs of the same class
/// never alias (R10/R11 on x86_64, X14/X15 on arm64; V29/V30
/// for FP / v128 stage on arm64; XMM14/XMM15 on x86_64).
// SIBLING-PUB: op_control.zig (per ADR-0093 extraction)
pub fn emitMergeMov(
    ctx: *EmitCtx,
    src_vreg: u32,
    merge_vreg: u32,
    stage_src: u8,
    stage_dst: u8,
) Error!void {
    if (ctx.alloc.shapeTag(merge_vreg) == .v128) {
        const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, stage_src);
        const merge_v = try gpr.qDefSpilled(ctx.alloc, merge_vreg, stage_dst);
        if (merge_v != src_v) {
            try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(merge_v, src_v));
        }
        try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, merge_vreg, stage_dst);
        return;
    }
    if (regalloc.vregClass(ctx.func, merge_vreg) == .fpr) {
        const src_v = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, stage_src);
        const merge_v = try gpr.fpDefSpilled(ctx.alloc, merge_vreg, stage_dst);
        if (merge_v != src_v) {
            try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovDReg(merge_v, src_v));
        }
        try gpr.fpStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, merge_vreg, stage_dst);
        return;
    }
    const src_r = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, stage_src);
    const merge_r = try gpr.gprDefSpilled(ctx.alloc, merge_vreg, stage_dst);
    if (merge_r != src_r) {
        // X-form (64-bit) ORR — preserves all 64 bits. W-form would
        // truncate upper 32 bits on i64 vregs; for i32 the upper
        // bits are don't-care per AAPCS64, so X-form is safe for
        // both. (Earlier the else_open merge path used W-form
        // throughout — load-bearing for i32 corpus but quietly
        // wrong for i64. The implicit-else path had to
        // re-derive the same fix locally; the unified merge
        // helper now applies it everywhere.)
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(merge_r, 31, src_r));
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, merge_vreg, stage_dst);
}

/// Block-merge mechanism for forward `br` / `br_if` to a
/// `block (result T..)` target. Mirrors the if/else
/// `merge_top_vregs` mechanism (D-027 + D-035)
/// extended to `.block` per D-093.
///
/// On the FIRST forward branch to a block label with
/// `result_arity > 0`, captures the top `arity` vregs as the
/// canonical merge target. No MOV is emitted: the captured
/// vregs ARE the merge target (the operand stack is already
/// in the right slots).
///
/// On SUBSEQUENT forward branches, emits `arity` MOVs from
/// the current top `arity` vregs into the captured merge
/// target's physical registers, so all paths through the
/// block end on the same regs. Post-block consumers then
/// read from `merge_top_vregs`.
///
/// Returns `true` when MOVs were emitted (caller is a second-
/// or-later br/br_if and must structure its branch
/// accordingly — br_if wraps MOVs+B inside a CBZ skip so
/// the fall-through path doesn't run them).
///
/// No-op when the target is not `.block` or `result_arity ==
/// 0` (legacy single-arm shapes).
// SIBLING-PUB: op_control.zig, br_on_null.zig, br_on_non_null.zig (per ADR-0093 extraction; ops/wasm_3_0/br_on_null.zig sibling — same merge semantics for the null-branch path; br_on_non_null.zig — label expects k+1 values including the ref)
pub fn captureOrEmitBlockMergeMov(ctx: *EmitCtx, tgt_idx: usize) Error!bool {
    const arity: u32 = ctx.labels.items[tgt_idx].result_arity;
    if (arity == 0) return false;
    // D-096: br inside if-arm targets the if-frame. The br
    // skips past .end so the .end merge MOV never runs; the br
    // must carry the value into the if-frame's result slot itself.
    // Same shape as block-target br: capture top vregs on first br,
    // MOV from current top on subsequent brs (after .else has
    // captured merge_top_vregs).
    const kind = ctx.labels.items[tgt_idx].kind;
    if (kind != .block and kind != .if_then and kind != .else_open) return false;
    if (ctx.pushed_vregs.items.len < arity) return Error.AllocationMissing;

    if (!ctx.labels.items[tgt_idx].merge_captured) {
        const base = ctx.pushed_vregs.items.len - arity;
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            ctx.labels.items[tgt_idx].merge_top_vregs[i] = ctx.pushed_vregs.items[base + i];
        }
        ctx.labels.items[tgt_idx].merge_captured = true;
        return false;
    }

    const base = ctx.pushed_vregs.items.len - arity;
    // D-147 / lesson `2026-05-18-parallel-move-cycle-in-if-merge.md`:
    // if all moves are GPR reg-to-reg (no FP / v128 / spilled
    // participants), route them through the parallel-move resolver
    // so cyclic dependencies via LIFO slot reuse don't clobber
    // still-needed sources. Otherwise fall back to per-move
    // sequential emit (existing behaviour; FP / spill paths
    // historically passed because their cycle patterns weren't
    // exercised by the spec corpus).
    var moves_buf: [merge_top_vregs_cap]ParallelMove = undefined;
    var n_moves: u32 = 0;
    var all_gpr_reg_to_reg = true;
    {
        var k: u32 = 0;
        while (k < arity) : (k += 1) {
            const src_vreg = ctx.pushed_vregs.items[base + k];
            const merge_vreg = ctx.labels.items[tgt_idx].merge_top_vregs[k];
            if (src_vreg == merge_vreg) continue;
            if (ctx.alloc.shapeTag(merge_vreg) == .v128) {
                all_gpr_reg_to_reg = false;
                break;
            }
            if (regalloc.vregClass(ctx.func, merge_vreg) == .fpr) {
                all_gpr_reg_to_reg = false;
                break;
            }
            const src_slot = ctx.alloc.slot(src_vreg, .gpr);
            const merge_slot = ctx.alloc.slot(merge_vreg, .gpr);
            const src_reg: inst.Xn = switch (src_slot) {
                .reg => |id| abi.slotToReg(id) orelse {
                    all_gpr_reg_to_reg = false;
                    break;
                },
                .spill => {
                    all_gpr_reg_to_reg = false;
                    break;
                },
            };
            const dst_reg: inst.Xn = switch (merge_slot) {
                .reg => |id| abi.slotToReg(id) orelse {
                    all_gpr_reg_to_reg = false;
                    break;
                },
                .spill => {
                    all_gpr_reg_to_reg = false;
                    break;
                },
            };
            if (src_reg == dst_reg) continue;
            moves_buf[n_moves] = .{ .src_reg = src_reg, .dst_reg = dst_reg, .done = false };
            n_moves += 1;
        }
    }
    if (all_gpr_reg_to_reg) {
        try resolveAndEmitMergeMovsRegBatch(ctx, moves_buf[0..n_moves]);
    } else {
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            const src_vreg = ctx.pushed_vregs.items[base + i];
            const merge_vreg = ctx.labels.items[tgt_idx].merge_top_vregs[i];
            try emitMergeMov(ctx, src_vreg, merge_vreg, 1, 0);
        }
    }
    return true;
}

/// Unpack `(param_arity, result_arity)` from a block-open
/// ZirInstr's `extra` field. Per lower.zig's `readBlockArity`
/// the packing is `(params << 8) | results`, both u8.
// SIBLING-PUB: op_control.zig (per ADR-0093 extraction)
pub fn unpackBlockArity(extra: u32) struct { params: u8, results: u8 } {
    return .{
        .params = @intCast((extra >> 8) & 0xFF),
        .results = @intCast(extra & 0xFF),
    };
}
