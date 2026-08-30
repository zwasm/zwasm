//! arm64 emit handler for `try_table` — Zone 2 per ADR-0074
//! + ADR-0114 D2.
//!
//! Wasm spec 3.0 §3.3.10.6 (try_table). Per ADR-0114 D2 the
//! try_table itself emits **zero JIT bytes** — it only
//! registers handler entries into the per-Instance
//! `ExceptionTable.Builder` so the FP-walk unwinder can find
//! them at throw time. The body's PC range is recorded in the
//! HandlerEntry; the JIT body for the inner block continues
//! to emit normally.
//!
//! Zone 2 (`src/engine/codegen/arm64/ops/`).

const std = @import("std");

const meta = @import("../../../../../instruction/wasm_3_0/try_table.zig");
const ctx_mod = @import("../../ctx.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A/B + ADR-0114 D2 — regalloc 3-axis classification.
// try_table falls through into the inner block (NOT a
// terminator); the per-op constant n_successor_edges = 1
// covers the catch-all shape (1 normal-fallthrough edge). The
// per-callsite N (1 + N_catch_clauses for the EH-aware
// callsite metadata per ADR-0113 D3) is populated at lower
// time when the parsed catch-vec count is known. Not a
// safepoint — try_table itself does no GC-observable work
// (handler registration is build-time data; the per-Instance
// ExceptionTable.Builder accumulates outside the emit hot
// path).
pub const is_terminator: bool = false;
pub const n_successor_edges: u8 = 1;
pub const is_safepoint: bool = false;

/// Wasm spec 3.0 §3.3.10.6 (try_table) — register one
/// HandlerEntry per catch clause; emit zero JIT bytes (the inner
/// block emits via regular dispatch; matching `end` patches
/// pc_end and matching catch-label `end` patches
/// landing_pad_pc — in the parent emit driver).
pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    std.debug.assert(ctx.exception_table_builder != null);
    std.debug.assert(ctx.open_try_tables != null);
    std.debug.assert(ctx.landing_pad_fixups != null);
    const builder = ctx.exception_table_builder.?;

    // ZirInstr.payload is u64; block_idx is the ZirFunc.blocks
    // index, always in u32 range by construction.
    const block_idx: u32 = @intCast(ins.payload);
    const landing_pads = ctx.func.eh_landing_pads orelse return error.UnsupportedOp;
    // A catchless try_table (zero catch clauses — e.g. `(try_table (param i32)
    // (drop))`) catches nothing; the lowerer appends its LandingPad but no
    // catch entries, so eh_catch_entries stays null when ALL of a func's
    // try_tables are catchless. The catch loop below over the empty
    // [catches_start, catches_end) range is then a no-op — null must coerce to
    // an empty slice, not reject the whole module.
    const catch_entries: []const zir.CatchEntry = ctx.func.eh_catch_entries orelse &.{};

    // Linear search — landing_pads.len is typically O(1)-few; the
    // per-function arena owns the slice. Sorted-by-block_idx
    // refinement is left to Phase 11 if profiling shows need.
    var lp_opt: ?zir.LandingPad = null;
    for (landing_pads) |lp| {
        if (lp.block_idx == block_idx) {
            lp_opt = lp;
            break;
        }
    }
    const lp = lp_opt orelse return error.UnsupportedOp;

    const pc_start: u32 = @intCast(ctx.buf.items.len);
    const entry_start: u32 = @intCast(builder.entries.items.len);
    const range_start: usize = lp.catches_start;
    const range_end: usize = lp.catches_end;

    // Snapshot labels depth BEFORE pushing try_table's own label —
    // catch clause label_idx is resolved against the ENCLOSING
    // context (Wasm 3.0 EH spec: catch labels are validated as if
    // the try_table is transparent in the label stack). So
    // `catch_all 0` targets the surrounding block, not the
    // try_table itself. The try_table's own label is needed for
    // intra-body `br 0` resolution and gets pushed below.
    const labels_depth_outer: u32 = @intCast(ctx.labels.items.len);

    // Mirror op_control.emitBlock: the try_table label carries the
    // blocktype arity (the lowerer packs it into ins.extra; block_idx is
    // in ins.payload). Hardcoding arity 0 here dropped the try_table's
    // result vreg at the matching `end` truncation (new_len = entry_depth
    // − param_arity + result_arity) → a later consumer (return / br /
    // outer-block result) marshalled a stale register (miscompile).
    // results/params > 8 would overflow the shared end-merge buffer
    // (= op_control merge_top_vregs_cap); reject as emitBlock does.
    const tt_results: u8 = @intCast(ins.extra & 0xFF);
    const tt_params: u8 = @intCast((ins.extra >> 8) & 0xFF);
    if (tt_results > 8 or tt_params > 8) return error.UnsupportedOp;
    try ctx.labels.append(ctx.allocator, .{
        .kind = .block,
        .target_byte_offset = 0,
        .pending = .empty,
        .result_arity = tt_results,
        .param_arity = tt_params,
        .entry_stack_depth = @intCast(ctx.pushed_vregs.items.len),
    });
    const labels_depth_after_push: u32 = @intCast(ctx.labels.items.len);

    for (catch_entries[range_start..range_end], 0..) |ce, i| {
        const is_catch_all = (ce.kind == .catch_all or ce.kind == .catch_all_ref);
        try builder.add(ctx.allocator, .{
            .pc_start = pc_start,
            // pc_end placeholder; patched by the matching `end`
            // op in compile()'s emit loop.
            .pc_end = pc_start + 1,
            .tag_idx = if (is_catch_all) null else ce.tag_idx,
            // landing_pad_pc placeholder; patched by the matching
            // catch-label's `end` op. The raw relative
            // br-depth `ce.label_idx` lives here pending the patch.
            .landing_pad_pc = ce.label_idx,
            .kind = switch (ce.kind) {
                .catch_ => .catch_,
                .catch_ref => .catch_ref,
                .catch_all => .catch_all,
                .catch_all_ref => .catch_all_ref,
            },
        });
        // register the per-catch forward fixup keyed
        // by the target label's depth. With label_idx resolved
        // against the OUTER context (labels_depth_outer), the
        // target lives at `labels_depth_outer - ce.label_idx`. The
        // patch fires when the label at that depth is popped (its
        // matching `end` op).
        try ctx.landing_pad_fixups.?.append(ctx.allocator, .{
            .entry_idx = entry_start + @as(u32, @intCast(i)),
            .target_labels_depth = labels_depth_outer - ce.label_idx,
        });
    }
    const entry_count: u32 = @intCast(range_end - range_start);

    // A catch clause is one more forward edge into its target block, carrying
    // values the unwinder delivers rather than any op. Give the target its
    // canonical merge vregs now (fresh ones — no operand exists yet) so the
    // body's fall-through and any `br` merge into the same slots at `.end`,
    // where the landing-pad prelude writes the caught payload. Liveness mints
    // the same vregs at this op (lockstep).
    for (catch_entries[range_start..range_end]) |ce| {
        if (ce.label_idx >= labels_depth_outer) continue;
        const tgt = &ctx.labels.items[labels_depth_outer - 1 - ce.label_idx];
        if (tgt.kind != .block or tgt.merge_captured or tgt.result_arity == 0) continue;
        var i: u32 = 0;
        while (i < tgt.result_arity) : (i += 1) {
            tgt.merge_top_vregs[i] = ctx.next_vreg.*;
            ctx.next_vreg.* += 1;
            if (tgt.merge_top_vregs[i] >= ctx.alloc.slots.len) return error.SlotOverflow;
        }
        tgt.merge_captured = true;
    }

    try ctx.open_try_tables.?.append(ctx.allocator, .{
        .labels_depth = labels_depth_after_push,
        .entry_start = entry_start,
        .entry_count = entry_count,
    });
}
