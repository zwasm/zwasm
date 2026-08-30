//! x86_64 emit handler for `try_table` — Zone 2 per ADR-0074
//! + ADR-0114 D2. Mirror of arm64 sibling.
//!
//! Wasm spec 3.0 §3.3.10.6. Emits one NOP (see arm64); registers
//! handler entries into `ExceptionTable.Builder` for the
//! FP-walk unwinder.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const std = @import("std");

const meta = @import("../../../../../instruction/wasm_3_0/try_table.zig");
const ctx_mod = @import("../../ctx.zig");
const inst = @import("../../inst.zig");
const exception_table = @import("../../../shared/exception_table.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A/B + ADR-0114 D2 — fallthrough into inner block.
pub const is_terminator: bool = false;
pub const n_successor_edges: u8 = 1;
pub const is_safepoint: bool = false;

/// Wasm spec 3.0 §3.3.10.6 (try_table) — mirror of arm64 sibling.
/// See arm64/ops/wasm_3_0/try_table.zig for the
/// rationale (HandlerEntry registration + landing_pad_pc forward
/// fixup).
pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    std.debug.assert(ctx.exception_table_builder != null);
    std.debug.assert(ctx.open_try_tables != null);
    std.debug.assert(ctx.landing_pad_fixups != null);
    const builder = ctx.exception_table_builder.?;

    const block_idx: u32 = @intCast(ins.payload);
    const landing_pads = ctx.func.eh_landing_pads orelse return error.UnsupportedOp;
    // Catchless try_table (zero catch clauses): the lowerer appends its
    // LandingPad but no catch entries, so eh_catch_entries is null when all of
    // a func's try_tables are catchless. The catch loop over the empty range is
    // a no-op — coerce null to empty, don't reject. (Mirrors arm64.)
    const catch_entries: []const zir.CatchEntry = ctx.func.eh_catch_entries orelse &.{};

    var lp_opt: ?zir.LandingPad = null;
    for (landing_pads) |lp| {
        if (lp.block_idx == block_idx) {
            lp_opt = lp;
            break;
        }
    }
    const lp = lp_opt orelse return error.UnsupportedOp;

    // One NOP so this try_table's PC range starts strictly inside any
    // enclosing one: `ExceptionTable.lookup` picks the smallest covering
    // range, and blocks / arity-0 `end`s emit no bytes, so without it a
    // nested try_table could share its enclosing range exactly.
    try ctx.buf.appendSlice(ctx.allocator, inst.encNop().slice());
    const pc_start: u32 = @intCast(ctx.buf.items.len);
    const entry_start: u32 = @intCast(builder.entries.items.len);
    const range_start: usize = lp.catches_start;
    const range_end: usize = lp.catches_end;

    // Snapshot labels depth BEFORE pushing try_table's own label —
    // catch clause label_idx is resolved against the ENCLOSING
    // context (Wasm 3.0 EH spec: catch labels treat the try_table
    // as transparent in the label stack). So `catch_all 0` targets
    // the surrounding block, not the try_table itself. The
    // try_table's own label is still pushed for intra-body `br 0`
    // resolution.
    const labels_depth_outer: u32 = @intCast(ctx.labels.items.len);

    // Mirror op_control.emitBlock: the try_table label carries the
    // blocktype arity (lowerer packs it into ins.extra; block_idx is in
    // ins.payload). Hardcoding arity 0 dropped the try_table result vreg
    // at the matching `end` truncation → stale-register return (a
    // miscompile). results/params > 8 overflow the shared end-merge
    // buffer (merge_top_vregs_cap); reject as emitBlock does. (Mirrors arm64.)
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
            .pc_end = pc_start + 1, // placeholder; end-op patches
            .tag_idx = if (is_catch_all) null else ce.tag_idx,
            .landing_pad_pc = ce.label_idx, // placeholder; landing-pad fixup patches
            .kind = switch (ce.kind) {
                .catch_ => .catch_,
                .catch_ref => .catch_ref,
                .catch_all => .catch_all,
                .catch_all_ref => .catch_all_ref,
            },
        });
        // Patch fires when the label at outer-resolved depth is
        // popped (its matching `end` op).
        try ctx.landing_pad_fixups.?.append(ctx.allocator, .{
            .entry_idx = entry_start + @as(u32, @intCast(i)),
            .target_labels_depth = labels_depth_outer - ce.label_idx,
        });
    }
    const entry_count: u32 = @intCast(range_end - range_start);

    try exception_table.captureCatchTargetMerge(ctx, catch_entries[range_start..range_end], labels_depth_outer);

    try ctx.open_try_tables.?.append(ctx.allocator, .{
        .labels_depth = labels_depth_after_push,
        .entry_start = entry_start,
        .entry_count = entry_count,
    });
}
