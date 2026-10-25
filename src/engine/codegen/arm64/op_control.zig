//! ARM64 emit pass — control-flow handlers.
//!
//! Per ADR-0021 sub-deliverable b (emit.zig
//! 9-module split): Wasm structured-control ops that push /
//! pop the per-function label stack and patch forward fixups.
//!
//! Handlers in this module:
//!   - block / loop — push a Label frame; loop captures the
//!     current buf offset for backward branches.
//!   - br / br_if — branch to label N (depth-indexed). Backward
//!     (loop) targets resolve immediately to a concrete disp;
//!     forward (block / if family) targets append a Fixup that
//!     `emitEndIntra` patches at the matching end.
//!   - br_table — linear CMP+B.NE+B chain over the in-range
//!     case targets, with an unconditional B to the default at
//!     the tail. Each case branch goes through the same
//!     forward-vs-backward dispatch as a single br.
//!   - if — pop cond, emit CBZ skip placeholder, push
//!     Label.if_then with the skip byte recorded. The skip
//!     resolves at the matching `else` (to else-body start) or
//!     `end` (to end-of-if).
//!   - else — emit B-uncond placeholder (jumps to end-of-if),
//!     patch the if's CBZ to the current byte (= else-body
//!     start), transition the label to .else_open. Captures
//!     the then arm's result vreg as the merge target per
//!     D-027 fix.
//!   - emitEndIntra — intra-function `end`: pops a label,
//!     patches its forward fixups, runs the D-027 merge MOV
//!     when an else_open frame had a captured merge target.
//!     Function-level `end` (epilogue + RET + trap stub) stays
//!     in emit.zig orchestrator.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");
const dbg = @import("../../../support/dbg.zig");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_neon = @import("inst_neon.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const abi = @import("abi.zig");
const jit_abi = @import("../shared/jit_abi.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

/// Mirror of `Label.merge_top_vregs.len` — comptime-knowable cap
/// on Wasm 2.0 multi-value if/else result arity. Wasm spec
/// imposes no tight limit but production guests typically use
/// ≤ 4. 8 is generous and keeps the Label struct compact.
const merge_top_vregs_cap: u8 = 8;

// Merge-MOV + ParallelMove helpers extracted to
// `op_control_merge_mov.zig` per ADR-0093. Cross-file references
// use `merge_mov.X` syntax.
const merge_mov = @import("op_control_merge_mov.zig");

/// `block` — push a forward-resolving label frame.
pub fn emitBlock(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const ar = merge_mov.unpackBlockArity(ins.extra);
    if (ar.results > merge_top_vregs_cap) return Error.UnsupportedOp;
    try ctx.labels.append(ctx.allocator, .{
        .kind = .block,
        .target_byte_offset = 0, // unknown until matching `end`
        .pending = .empty,
        .result_arity = ar.results,
        .param_arity = ar.params,
        .entry_stack_depth = @intCast(ctx.pushed_vregs.items.len),
    });
}

/// `loop` — push a backward-resolving label frame; capture the
/// current buf offset as the loop entry.
pub fn emitLoop(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const ar = merge_mov.unpackBlockArity(ins.extra);
    if (ar.results > merge_top_vregs_cap) return Error.UnsupportedOp;
    if (ar.params > merge_top_vregs_cap) return Error.UnsupportedOp;
    // D-099: capture the loop's entry param vregs. At a
    // backward `br $l` (or `br_if $l`), top `param_arity` vregs
    // are the NEW values for the next iteration; emit needs to
    // MOV those into the captured param vreg slots BEFORE the
    // back-branch so the loop body's first ops (which read the
    // param vreg slots) see the next-iter values.
    var param_top: [merge_top_vregs_cap]u32 = undefined;
    if (ar.params > 0 and ctx.pushed_vregs.items.len >= ar.params) {
        const base = ctx.pushed_vregs.items.len - ar.params;
        var i: u32 = 0;
        while (i < ar.params) : (i += 1) {
            param_top[i] = ctx.pushed_vregs.items[base + i];
        }
    }
    try ctx.labels.append(ctx.allocator, .{
        .kind = .loop,
        .target_byte_offset = @intCast(ctx.buf.items.len),
        .pending = .empty,
        .result_arity = ar.results,
        .param_arity = ar.params,
        .entry_stack_depth = @intCast(ctx.pushed_vregs.items.len),
        .param_top_vregs = param_top,
    });
}

/// D-093 — marshal function results into AAPCS64 result
/// registers (X0..X7 / V0..V7) before a function-level
/// br / br_if / end. Walks `func.sig.results` in order; per-
/// class index maps the i-th result to Xi/Vi (independent
/// GPR / FP counters). Top N vregs on pushed_vregs are the
/// results (deepest = result[0], top = result[N-1]). Stack
/// overflow (>8 results per class) → UnsupportedOp.
///
/// **No parallel-move hazard**: allocatable pool excludes
/// X0..X7 and V0..V7 by ADR-0017's reservation, so MOV-in-
/// order is correct.
pub fn marshalFunctionReturn(ctx: *EmitCtx) Error!void {
    if (ctx.func.sig.results.len == 0) return;
    if (ctx.pushed_vregs.items.len < ctx.func.sig.results.len) return;
    // ADR-0017 2026-05-18 amend / ADR-0069:
    // MEMORY-class returns (struct > 16 B per AAPCS64 §6.8.2;
    // v2 trigger = `sig.results.len > 2`) write each result to
    // `*(X8 + i*8)` instead of marshalling into X0..X7 / V0..V7.
    // Prologue captured X8 to `ctx.indirect_result_slot_off`;
    // load it into X16 (IP0 intra-procedure scratch, AAPCS64
    // §6.4 caller-saved, outside regalloc pool AND
    // `abi.spill_stage_gprs` X14/X15) and emit per-result
    // indirect stores. X16 chosen over X14 because
    // `gprLoadSpilled` clobbers X14/X15 when staging spilled
    // source vregs. v128 results deferred (no spec fixture in
    // the 3-int-result / large-sig cohort).
    // ADR-0106 path (a) — the buffer-write ABI reuses the
    // MEMORY-class shape (load captured ptr to X16; write per-result
    // to `[X16, #(i*8)]`). Slot sourced from the prologue's STR X1
    // (buffer_write) instead of STR X8 (MEMORY-class); read here is
    // identical.
    if (ctx.return_is_memory_class or ctx.alloc.result_abi == .buffer_write) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, 31, @intCast(ctx.indirect_result_slot_off)));
        const result_base = ctx.pushed_vregs.items.len - ctx.func.sig.results.len;
        var byte_off: u32 = 0;
        for (ctx.func.sig.results, 0..) |result_kind, i| {
            const src_vreg = ctx.pushed_vregs.items[result_base + i];
            if (src_vreg < ctx.alloc.slots.len) {
                switch (result_kind) {
                    .i32, .i64, .ref => {
                        const src_xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(src_xn, 16, @intCast(byte_off)));
                    },
                    .f32 => {
                        const src_vn = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrSImm(src_vn, 16, @intCast(byte_off)));
                    },
                    .f64 => {
                        const src_vn = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrDImm(src_vn, 16, @intCast(byte_off)));
                    },
                    .v128 => return Error.UnsupportedOp,
                }
            }
            byte_off += 8;
        }
        return;
    }
    var n_gpr_cap: u8 = 0;
    var n_fp_cap: u8 = 0;
    for (ctx.func.sig.results) |rt| switch (rt) {
        .i32, .i64, .ref => n_gpr_cap += 1,
        .f32, .f64, .v128 => n_fp_cap += 1,
    };
    if (n_gpr_cap > 8 or n_fp_cap > 8) return Error.UnsupportedOp;

    var n_gpr: u8 = 0;
    var n_fp: u8 = 0;
    const result_base = ctx.pushed_vregs.items.len - ctx.func.sig.results.len;
    for (ctx.func.sig.results, 0..) |result_kind, i| {
        const src_vreg = ctx.pushed_vregs.items[result_base + i];
        if (src_vreg >= ctx.alloc.slots.len) {
            // D-093: dead-fall-through placeholder; skip.
            switch (result_kind) {
                .i32, .i64, .ref => n_gpr += 1,
                .f32, .f64, .v128 => n_fp += 1,
            }
            continue;
        }
        switch (result_kind) {
            .f32, .f64 => {
                const dst: inst.Vn = @intCast(n_fp);
                n_fp += 1;
                const src_vn = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (src_vn != dst) {
                    const base: u32 = if (result_kind == .f64) 0x1E604000 else 0x1E204000;
                    try gpr.writeU32(ctx.allocator, ctx.buf, base | (@as(u32, src_vn) << 5) | @as(u32, dst));
                }
            },
            .v128 => {
                const dst: inst_neon.Vn = @intCast(n_fp);
                n_fp += 1;
                const src_vn = try gpr.resolveFp(ctx.alloc, src_vreg);
                if (src_vn != dst) {
                    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(dst, src_vn));
                }
            },
            .i32, .i64, .ref => {
                const dst: inst.Xn = @intCast(n_gpr);
                n_gpr += 1;
                const src_xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (src_xn != dst) {
                    try gpr.writeU32(ctx.allocator, ctx.buf, 0xAA0003E0 | (@as(u32, src_xn) << 16) | @as(u32, dst));
                }
            },
        }
    }
}

/// `br N` — unconditional branch to label at depth N (0 =
/// innermost). Backward (loop) targets resolve to a concrete
/// disp now; forward targets emit a placeholder + append a
/// Fixup for the matching end to patch. When `N` equals the
/// number of explicit labels, the branch targets the implicit
/// function-level block (= `return`); marshal the function's
/// ADR-0179 #3a / D-314 — loop back-edge cooperative-interruption poll.
/// Mirrors the prologue poll (emit.zig) but its B.NE fixup routes to a
/// POST-frame interrupted stub (fb=frame_bytes). Inserted just BEFORE a
/// backward branch (to a `loop` header) so the host flag is checked every
/// iteration — the prologue poll alone misses a tight `(loop)` with no calls.
/// `LDR X16←interrupt_ptr; CBZ +4 (skip when null); LDR W17←[X16]; CMP W17,WZR;
/// B.NE → back_edge_interrupt_fixups`. X16/X17 = IP0/IP1 caller-saved scratch,
/// free at a control-flow boundary; CMP+B.NE (not CBNZ) per the EmitCindStub
/// patcher; the CMP's flags don't disturb a following CBNZ (compare-and-branch
/// on a register, not NZCV).
fn emitBackEdgeInterruptPoll(ctx: *EmitCtx) Error!void {
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.interrupt_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbz(16, 4));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(17, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(17, 31));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ne, 0));
    try ctx.back_edge_interrupt_fixups.append(ctx.allocator, fixup_at);
    // ADR-0179 #3b / D-314 — fuel poll, beside the interrupt poll at every
    // back-edge (prologue sibling in emit.zig). `LDR W16 ← fuel_metered;
    // CBZ W16, +6 (unmetered); LDR X17 ← fuel_cell; SUB X17, #1; STR X17;
    // CMP X17, XZR; B.MI → back_edge_fuel_fixups` (code 17, POST-frame stub).
    // 7 instrs / 28 bytes; total back-edge poll block = 48 bytes.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(16, abi.runtime_ptr_save_gpr, jit_abi.fuel_metered_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(16, 6));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(17, abi.runtime_ptr_save_gpr, jit_abi.fuel_cell_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(17, abi.runtime_ptr_save_gpr, jit_abi.fuel_cell_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(17, 31));
    const fuel_fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.mi, 0));
    try ctx.back_edge_fuel_fixups.append(ctx.allocator, fuel_fixup_at);
}

/// result and append to `return_fixups` so the final `end`
/// patches it to the regular epilogue.
pub fn emitBr(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ins.payload == ctx.labels.items.len) {
        // br <function-depth>: equivalent to `return`.
        // Marshal top N result vregs into AAPCS64 result regs, emit
        // a B-fixup pointing at the function epilogue.
        try marshalFunctionReturn(ctx);
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
        try ctx.return_fixups.append(ctx.allocator, fixup_at);
        return;
    }
    if (ins.payload > ctx.labels.items.len) return Error.UnsupportedOp;
    const tgt_idx = ctx.labels.items.len - 1 - ins.payload;
    if (ctx.labels.items[tgt_idx].kind == .loop) {
        // D-099: Wasm 2.0 multi-value loop with params. The
        // loop's label-type is its param type (not result); a
        // backward br supplies the NEXT iteration's param values
        // on top of stack. Emit MOVs from top `param_arity` vregs
        // into the captured `param_top_vregs` (the loop body's
        // initial param vreg slots) so the next iter's body reads
        // the new values. Earlier this was a no-op (loops
        // without params worked; multi-param loops like fac-ssa
        // returned wrong values).
        const param_arity = ctx.labels.items[tgt_idx].param_arity;
        if (param_arity > 0 and ctx.pushed_vregs.items.len >= param_arity) {
            const base = ctx.pushed_vregs.items.len - param_arity;
            var i: u32 = 0;
            while (i < param_arity) : (i += 1) {
                const src_vreg = ctx.pushed_vregs.items[base + i];
                const dst_vreg = ctx.labels.items[tgt_idx].param_top_vregs[i];
                if (src_vreg != dst_vreg) {
                    try merge_mov.emitMergeMov(ctx, src_vreg, dst_vreg, 1, 0);
                }
            }
        }
        // D-314 — back-edge poll before the unconditional backward B (an
        // infinite `(loop (br 0))` is caught here, the prologue poll can't).
        try emitBackEdgeInterruptPoll(ctx);
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        const tgt_byte = ctx.labels.items[tgt_idx].target_byte_offset;
        const disp_words: i32 = @as(i32, @intCast(tgt_byte)) -
            @as(i32, @intCast(fixup_at));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(@divExact(disp_words, 4)));
        return;
    }
    // Forward branch (block / if_then with br inside / else_open).
    // D-093: for `.block` with result_arity > 0, the FIRST
    // br captures top arity vregs as merge target (no MOV); a
    // SUBSEQUENT br emits MOVs from current top → merge regs so
    // both paths converge on the same physical regs.
    _ = try merge_mov.captureOrEmitBlockMergeMov(ctx, tgt_idx);
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    try ctx.labels.items[tgt_idx].pending.append(ctx.allocator, .{ .byte_offset = fixup_at, .kind = .b_uncond });
}

/// `br_if N` — pop cond; branch to label at depth N if non-zero.
/// When N equals the number of explicit labels, the conditional
/// branch targets the implicit function-level block (= conditional
/// `return`); CBZ skip + marshal + B epilogue placeholder.
pub fn emitBrIf(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const cond = ctx.pushed_vregs.pop().?;
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, cond, 0);
    try branchOnReg(ctx, ins, wn);
}

/// Conditional-branch-to-label body shared by `br_if` and `br_on_cast`:
/// branch to the label at `ins.payload` depth when `wn != 0`. Five cases —
/// conditional function-return (depth == labels.len), loop+param, loop-direct,
/// forward block-with-captured-merge, forward simple. The caller supplies the
/// condition already loaded in `wn`: `br_if` pops the operand; `br_on_cast`
/// passes the `jitGcRefTest` result (and `br_on_cast_fail` inverts it first).
pub fn branchOnReg(ctx: *EmitCtx, ins: *const ZirInstr, wn: inst.Xn) Error!void {
    if (ins.payload == ctx.labels.items.len) {
        // Conditional return: CBZ cond, skip ; marshal ; B
        // epilogue ; skip:
        const cbz_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(wn, 0));
        try marshalFunctionReturn(ctx);
        const b_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
        try ctx.return_fixups.append(ctx.allocator, b_at);
        // Patch the CBZ to skip past the B (i.e. land at the
        // current buf end — the next instruction).
        const skip_byte: u32 = @intCast(ctx.buf.items.len);
        const cbz_disp_words: i19 = @intCast(@divExact(@as(i32, @intCast(skip_byte)) - @as(i32, @intCast(cbz_at)), 4));
        std.mem.writeInt(u32, ctx.buf.items[cbz_at..][0..4], inst.encCbzW(wn, cbz_disp_words), .little);
        return;
    }
    if (ins.payload > ctx.labels.items.len) return Error.UnsupportedOp;
    const tgt_idx = ctx.labels.items.len - 1 - ins.payload;
    if (ctx.labels.items[tgt_idx].kind == .loop) {
        // D-099: loop with params — MOVs must run only when
        // cond ≠ 0 (= when the back-branch is taken). Without
        // params, fall through to the simpler CBNZ-direct shape
        // since no MOVs are needed.
        const param_arity = ctx.labels.items[tgt_idx].param_arity;
        if (param_arity > 0 and ctx.pushed_vregs.items.len >= param_arity) {
            const cbz_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(wn, 0));
            const base = ctx.pushed_vregs.items.len - param_arity;
            var i: u32 = 0;
            while (i < param_arity) : (i += 1) {
                const src_vreg = ctx.pushed_vregs.items[base + i];
                const dst_vreg = ctx.labels.items[tgt_idx].param_top_vregs[i];
                if (src_vreg != dst_vreg) {
                    try merge_mov.emitMergeMov(ctx, src_vreg, dst_vreg, 1, 0);
                }
            }
            // D-314 — back-edge poll runs only when the branch is TAKEN
            // (inside the cond≠0 region), before the backward B.
            try emitBackEdgeInterruptPoll(ctx);
            const b_at: u32 = @intCast(ctx.buf.items.len);
            const tgt_byte = ctx.labels.items[tgt_idx].target_byte_offset;
            const disp_words: i32 = @as(i32, @intCast(tgt_byte)) -
                @as(i32, @intCast(b_at));
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(@divExact(disp_words, 4)));
            // Patch CBZ to skip past the MOVs + B.
            const skip_byte: u32 = @intCast(ctx.buf.items.len);
            const cbz_disp_words: i19 = @intCast(@divExact(@as(i32, @intCast(skip_byte)) - @as(i32, @intCast(cbz_at)), 4));
            std.mem.writeInt(u32, ctx.buf.items[cbz_at..][0..4], inst.encCbzW(wn, cbz_disp_words), .little);
            return;
        }
        // D-314 — back-edge poll before the conditional backward CBNZ. Runs
        // each iteration check (one harmless extra poll on the exit pass).
        try emitBackEdgeInterruptPoll(ctx);
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        const tgt_byte = ctx.labels.items[tgt_idx].target_byte_offset;
        const disp_words: i32 = @as(i32, @intCast(tgt_byte)) -
            @as(i32, @intCast(fixup_at));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(wn, @divExact(disp_words, 4)));
        return;
    }
    // Forward branch. D-093: for `.block` with merge already
    // captured, MOVs must run only when cond ≠ 0. Wrap the MOVs +
    // B inside a CBZ-skip sequence so the fall-through path
    // (cond == 0) bypasses both. First br_if to a block (capture
    // path, no MOV) still uses the canonical CBNZ-forward shape.
    const tgt_is_block_with_capture =
        ctx.labels.items[tgt_idx].kind == .block and
        ctx.labels.items[tgt_idx].result_arity > 0 and
        ctx.labels.items[tgt_idx].merge_captured;
    if (tgt_is_block_with_capture) {
        const cbz_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(wn, 0));
        _ = try merge_mov.captureOrEmitBlockMergeMov(ctx, tgt_idx);
        const b_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
        try ctx.labels.items[tgt_idx].pending.append(ctx.allocator, .{ .byte_offset = b_at, .kind = .b_uncond });
        const skip_byte: u32 = @intCast(ctx.buf.items.len);
        const cbz_disp_words: i19 = @intCast(@divExact(@as(i32, @intCast(skip_byte)) - @as(i32, @intCast(cbz_at)), 4));
        std.mem.writeInt(u32, ctx.buf.items[cbz_at..][0..4], inst.encCbzW(wn, cbz_disp_words), .little);
        return;
    }
    // First br_if to a .block: capture merge target (no MOV).
    // Other forward kinds (if_then with br inside, else_open):
    // unchanged — no merge mechanism applies.
    _ = try merge_mov.captureOrEmitBlockMergeMov(ctx, tgt_idx);
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(wn, 0));
    try ctx.labels.items[tgt_idx].pending.append(ctx.allocator, .{ .byte_offset = fixup_at, .kind = .cbnz_w });
}

/// Emit a `B target_for_depth` for a single br_table case (or
/// the default tail). Backward (loop) → direct disp; forward →
/// placeholder + Fixup append. When `depth == labs.len` the
/// branch targets the implicit function-level block (= return);
/// marshal the function's results and append to return_fixups.
fn emitBranchToDepth(ctx: *EmitCtx, depth: u32) Error!void {
    if (depth == ctx.labels.items.len) {
        // br_table case targeting function-depth: same shape as
        // emitBr's return path. Wasm spec §3.4.5 br_table to
        // function-level transfers the labelled result list (the
        // function's result type) onto the result registers;
        // delegate to marshalFunctionReturn so multi-result
        // functions (e.g. `(result i32 i32)`) marshal both
        // result vregs into X0+X1 rather than just the first.
        try marshalFunctionReturn(ctx);
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
        try ctx.return_fixups.append(ctx.allocator, fixup_at);
        return;
    }
    if (depth > ctx.labels.items.len) return Error.UnsupportedOp;
    const tgt_idx = ctx.labels.items.len - 1 - depth;
    if (ctx.labels.items[tgt_idx].kind == .loop) {
        // D-099: mirror emitBr's loop-param MOV path.
        const param_arity = ctx.labels.items[tgt_idx].param_arity;
        if (param_arity > 0 and ctx.pushed_vregs.items.len >= param_arity) {
            const base = ctx.pushed_vregs.items.len - param_arity;
            var i: u32 = 0;
            while (i < param_arity) : (i += 1) {
                const src_vreg = ctx.pushed_vregs.items[base + i];
                const dst_vreg = ctx.labels.items[tgt_idx].param_top_vregs[i];
                if (src_vreg != dst_vreg) {
                    try merge_mov.emitMergeMov(ctx, src_vreg, dst_vreg, 1, 0);
                }
            }
        }
        // D-314 — back-edge poll before the backward B (a br_table whose
        // taken case/default is a loop header is a back edge too; without
        // this a br_table-driven tight loop is uninterruptible). Sits inside
        // the per-case B.NE-skipped body; the poll's CMP clobbers NZCV but
        // the next case re-CMPs, and X16/X17 never hold the br_table index
        // (allocatable pool + X14/X15 stages only).
        try emitBackEdgeInterruptPoll(ctx);
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        const tgt_byte = ctx.labels.items[tgt_idx].target_byte_offset;
        const disp_words: i32 = @as(i32, @intCast(tgt_byte)) -
            @as(i32, @intCast(fixup_at));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(@divExact(disp_words, 4)));
        return;
    }
    // D-093: forward branch — same block-merge mechanism
    // as emitBr / emitBrIf. First br to a `.block` target with
    // `result_arity > 0` captures merge_top_vregs; subsequent
    // brs emit MOVs from current top → merge regs before the B
    // fixup. br_table dispatches multiple cases through this
    // helper; per-case CMP+B.NE-skip in emitBrTable is patched
    // with variable disp to cover the MOVs + B span.
    _ = try merge_mov.captureOrEmitBlockMergeMov(ctx, tgt_idx);
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    try ctx.labels.items[tgt_idx].pending.append(ctx.allocator, .{ .byte_offset = fixup_at, .kind = .b_uncond });
}

/// `br_table` — pop index; emit a CMP+B.NE+B chain for each
/// in-range case, then an unconditional B to the default.
///
/// ZirInstr encoding (mvp.zig:brTableOp):
///   payload = count   (number of in-range targets)
///   extra   = start   (offset into func.branch_targets)
/// branch_targets[start..start+count] = case depths
/// branch_targets[start+count]        = default depth
pub fn emitBrTable(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_vreg = ctx.pushed_vregs.pop().?;
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_vreg, 0);
    const count = ins.payload;
    const start = ins.extra;
    const targets = ctx.func.branch_targets.items;
    if (start + count >= targets.len) return Error.UnsupportedOp;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // D-118: per-case CMP. Cases
        // i < 4096 fit `CMP Wn, #imm12` directly; for the wider
        // range (Wasm spec §3.4.5 br_table has no upper bound on
        // case count — br_table.wast `large` declares 16149
        // targets), materialise the imm into W16 via MOVZ + MOVK
        // and CMP Wn, W16. W16 / X16 is an intra-procedure scratch
        // outside the regalloc pool, safe to clobber here.
        if (i < (@as(u32, 1) << 12)) {
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(wn, @intCast(i)));
        } else {
            const lo16: u16 = @intCast(i & 0xFFFF);
            const hi16: u16 = @intCast((i >> 16) & 0xFFFF);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(16, lo16));
            if (hi16 != 0) {
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(16, hi16, 1));
            }
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(wn, 16));
        }
        // D-093: emitBranchToDepth may now emit MOVs +
        // B (when forward target is `.block` with merge
        // already captured). Patch B.NE-skip's disp after the
        // case body lands so it covers the actual span. Earlier code
        // used a fixed disp of 2 words (= skip a single 4-byte
        // B). Variable disp keeps the skip correct when MOVs
        // are emitted between B.NE and the per-case B.
        const bne_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ne, 0));
        try emitBranchToDepth(ctx, targets[start + i]);
        const after: u32 = @intCast(ctx.buf.items.len);
        const disp_words: i19 = @intCast(@divExact(@as(i32, @intCast(after)) - @as(i32, @intCast(bne_at)), 4));
        std.mem.writeInt(u32, ctx.buf.items[bne_at..][0..4], inst.encBCond(.ne, disp_words), .little);
    }
    try emitBranchToDepth(ctx, targets[start + count]);
}

/// `if` — pop cond; emit `CBZ Wn, 0` placeholder that skips the
/// then-body when cond=0; push Label.if_then with the skip byte
/// recorded. The skip resolves at matching `else` (to else-body
/// start) or `end` (to end-of-if).
///
/// **Multi-result support** (D-035): `ins.extra`
/// carries the blocktype result arity per `lower.zig:openBlock`
/// (Wasm 2.0 multi-value). The merge MOV path in emitElse /
/// emitEndIntra captures N then-arm result vregs at `else` and
/// emits N MOVs at the matching `end` to converge both arms.
/// Cap = `Label.merge_top_vregs.len`; larger surfaces as
/// `UnsupportedOp`.
pub fn emitIf(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const ar = merge_mov.unpackBlockArity(ins.extra);
    if (ar.results > merge_top_vregs_cap) return Error.UnsupportedOp;
    if (ar.params > merge_top_vregs_cap) return Error.UnsupportedOp;
    const cond = ctx.pushed_vregs.pop().?;
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, cond, 0);
    const skip_byte: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(wn, 0));
    // D-093 — capture top `param_arity` vregs so emitElse
    // can re-push them onto the operand stack at else-arm entry
    // (Wasm spec §3.4.4 specifies the else-arm starts with the
    // same shape as the then-arm did at if-entry).
    var param_top_vregs: [merge_top_vregs_cap]u32 = undefined;
    if (ar.params > 0) {
        if (ctx.pushed_vregs.items.len < ar.params) return Error.AllocationMissing;
        const base = ctx.pushed_vregs.items.len - ar.params;
        var i: u32 = 0;
        while (i < ar.params) : (i += 1) {
            param_top_vregs[i] = ctx.pushed_vregs.items[base + i];
        }
    }
    try ctx.labels.append(ctx.allocator, .{
        .kind = .if_then,
        .target_byte_offset = 0,
        .pending = .empty,
        .if_skip_byte = skip_byte,
        .result_arity = ar.results,
        .param_arity = ar.params,
        // D-093: entry_stack_depth measured AFTER popping
        // the if's condition vreg (matches the depth a
        // subsequent br would target).
        .entry_stack_depth = @intCast(ctx.pushed_vregs.items.len),
        .param_top_vregs = param_top_vregs,
    });
}

/// `else` — emit B-uncond placeholder (jumps from end-of-then
/// to end-of-if), patch the if's CBZ to current byte (= start
/// of else-body), transition label to .else_open. Captures the
/// then arm's top N result vregs as merge targets (D-027 fix
/// extended to Wasm 2.0 multi-value per D-035).
pub fn emitElse(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    if (ctx.labels.items.len == 0 or
        ctx.labels.items[ctx.labels.items.len - 1].kind != .if_then)
    {
        dbg.print("codegen", "arm64/op_control: emitElse without matching if_then frame (labels.len={d}, func_idx={d})\n", .{ ctx.labels.items.len, ctx.func.func_idx });
        return Error.UnsupportedOp;
    }
    const lbl_idx = ctx.labels.items.len - 1;
    const arity: u32 = ctx.labels.items[lbl_idx].result_arity;
    if (arity > 0 and ctx.pushed_vregs.items.len >= arity) {
        const base = ctx.pushed_vregs.items.len - arity;
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            ctx.labels.items[lbl_idx].merge_top_vregs[i] = ctx.pushed_vregs.items[base + i];
        }
        ctx.labels.items[lbl_idx].merge_captured = true;
    }
    const b_byte: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    const else_start: u32 = @intCast(ctx.buf.items.len);
    const lbl = &ctx.labels.items[lbl_idx];
    // D-093 — restore else-arm operand-stack shape. Wasm
    // spec §3.4.4: the else-arm starts with the if-frame's param
    // types pushed back onto the stack (same view the then-arm
    // had at entry). Truncate to `entry_stack_depth - param_arity`
    // (= state BEFORE params were placed), then push the captured
    // `param_top_vregs` back.
    if (lbl.param_arity > 0) {
        const entry_base: usize = @as(usize, lbl.entry_stack_depth) -| @as(usize, lbl.param_arity);
        if (ctx.pushed_vregs.items.len > entry_base) {
            ctx.pushed_vregs.shrinkRetainingCapacity(entry_base);
        }
        while (ctx.pushed_vregs.items.len < entry_base) {
            // Defensive — should not fire (validator guarantees
            // the operand-stack depth at .else matches the
            // entry-base + result_arity shape); padding here
            // preserves the entry-base invariant if a future
            // validator change drifts.
            try ctx.pushed_vregs.append(ctx.allocator, lbl.param_top_vregs[0]);
        }
        var i: u32 = 0;
        while (i < lbl.param_arity) : (i += 1) {
            try ctx.pushed_vregs.append(ctx.allocator, lbl.param_top_vregs[i]);
        }
    }
    // Patch the matching `if`'s CBZ skip — but only if the
    // if_then frame had one. Dead-code-pushed placeholder
    // frames carry
    // `if_skip_byte = null` to mark "no CBZ to patch"; in
    // that case the if itself never emitted bytes, so the
    // skip-patch step is a no-op.
    if (lbl.if_skip_byte) |skip_byte| {
        const skip_disp: i32 = @as(i32, @intCast(else_start)) -
            @as(i32, @intCast(skip_byte));
        const orig_cbz = std.mem.readInt(u32, ctx.buf.items[skip_byte..][0..4], .little);
        const cbz_rt: inst.Xn = @intCast(orig_cbz & 0x1F);
        const new_cbz = inst.encCbzW(cbz_rt, @divExact(skip_disp, 4));
        std.mem.writeInt(u32, ctx.buf.items[skip_byte..][0..4], new_cbz, .little);
    }
    lbl.if_skip_byte = null;
    lbl.kind = .else_open;
    try lbl.pending.append(ctx.allocator, .{ .byte_offset = b_byte, .kind = .b_uncond });
}

/// Intra-function `end`: pops a label, patches its forward
/// fixups, runs the D-027 merge MOV when an else_open frame had
/// a captured merge target. Caller (emit.zig) gates on
/// `ctx.labels.items.len > 0`; the function-level `end` shape
/// (epilogue + RET + trap stub) stays inline in compile().
pub fn emitEndIntra(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    var lbl = ctx.labels.pop().?;
    defer lbl.pending.deinit(ctx.allocator);

    // D-027 fix extended to Wasm 2.0 multi-value
    // (D-035): when an else_open frame carries a
    // captured merge buffer (`result_arity > 0`), emit one MOV
    // per result slot before the join label so both arms
    // converge on the same physical regs. Stack at entry is
    // either:
    //   live  : [..., merge_0, ..., merge_{N-1}, else_0, ..., else_{N-1}]
    //   dead  : [..., merge_0, ..., merge_{N-1}]
    //           (else arm broke out via br / return / unreachable)
    // D-093: `.block` merge fall-through. When at least one
    // forward br/br_if captured a merge target during the block
    // body, the fall-through `end` must MOV the current top arity
    // vregs into the captured merge regs (live fall-through case);
    // or skip MOVs when the top vregs already ARE the merge target
    // (dead fall-through — every path exited via br). After this
    // step the canonical block result on the operand stack is the
    // merge_top_vregs (not the fall-through top), so post-block
    // consumers read from a stable vreg regardless of which path
    // ran at runtime.
    if (lbl.kind == .block and lbl.merge_captured and lbl.result_arity > 0) {
        const arity: u32 = lbl.result_arity;
        // D-093: block-with-params consumed `param_arity`
        // entry-time values; canonical post-block stack base
        // is `entry - param_arity`.
        const entry: usize = @as(usize, lbl.entry_stack_depth) -| @as(usize, lbl.param_arity);
        // Three shapes at block-end fall-through:
        //   (a) Live fall-through  — pushed_vregs.len >= entry +
        //       arity and top arity differ from merge_top_vregs.
        //       Emit MOVs from top → merge regs.
        //   (b) Dead fall-through  — pushed_vregs.len >= entry +
        //       arity and top arity == merge_top_vregs (the br
        //       that captured the merge target left them on top).
        //       Skip MOVs.
        //   (c) Dead fall-through with operand-stack emptied —
        //       pushed_vregs.len < entry + arity. An intervening
        //       end (loop / if) truncated below the block's
        //       fall-through height. The br that captured the
        //       merge already populated merge_top_vregs's slots
        //       at runtime (via fresh emit of source-vreg-into-
        //       merge-slot or by the first-br capture being its
        //       own merge); no MOV emit needed. Grow
        //       pushed_vregs to [...entry, merge_top_vregs] so
        //       post-block consumers see the canonical result.
        //       Surfaced by `labels.wast:loop1` (br $exit inside
        //       if-then inside loop inside block; loop's truncate
        //       emptied the stack at loop-end, leaving block-end
        //       with 0 entries but arity=1).
        if (ctx.pushed_vregs.items.len < entry + arity) {
            if (ctx.pushed_vregs.items.len > entry) {
                ctx.pushed_vregs.shrinkRetainingCapacity(entry);
            }
            // Pad up to entry with merge_top_vregs[0] as filler
            // when the stack is shorter than entry (a deeper-
            // than-expected truncate happened upstream; preserves
            // entry-base invariant for the post-block consumer).
            while (ctx.pushed_vregs.items.len < entry) {
                try ctx.pushed_vregs.append(ctx.allocator, lbl.merge_top_vregs[0]);
            }
            var i: u32 = 0;
            while (i < arity) : (i += 1) {
                try ctx.pushed_vregs.append(ctx.allocator, lbl.merge_top_vregs[i]);
            }
        } else {
            const top_base = ctx.pushed_vregs.items.len - arity;
            const dead_fallthrough = blk: {
                var i: u32 = 0;
                while (i < arity) : (i += 1) {
                    if (ctx.pushed_vregs.items[top_base + i] != lbl.merge_top_vregs[i]) break :blk false;
                }
                break :blk true;
            };
            if (!dead_fallthrough) {
                var i: u32 = 0;
                while (i < arity) : (i += 1) {
                    const src_vreg = ctx.pushed_vregs.items[top_base + i];
                    const merge_vreg = lbl.merge_top_vregs[i];
                    try merge_mov.emitMergeMov(ctx, src_vreg, merge_vreg, 1, 0);
                }
            }
            // Overwrite top arity slots with merge_top_vregs so the
            // downstream truncate (and consumers reading via
            // pushed_vregs) see the canonical merge result.
            var i: u32 = 0;
            while (i < arity) : (i += 1) {
                ctx.pushed_vregs.items[top_base + i] = lbl.merge_top_vregs[i];
            }
        }
    }

    if (lbl.kind == .else_open and lbl.merge_captured) {
        const arity: u32 = lbl.result_arity;
        const dead_else = blk: {
            if (ctx.pushed_vregs.items.len < arity) break :blk false;
            const base = ctx.pushed_vregs.items.len - arity;
            var i: u32 = 0;
            while (i < arity) : (i += 1) {
                if (ctx.pushed_vregs.items[base + i] != lbl.merge_top_vregs[i]) {
                    break :blk false;
                }
            }
            break :blk true;
        };
        if (dead_else) {
            // Merge targets already on top of stack from the
            // then arm. Skip MOVs; B fixups patched below.
        } else if (lbl.param_arity > 0) {
            // D-093 — `if (param T1..TK)` case: emitElse
            // truncated the phantom V_then_result below the
            // re-pushed params, so at .end the stack is just
            // [..., V_else_result_0 .. V_else_result_{N-1}].
            // MOV else-results into the captured merge slots
            // (= V_then_result vregs); the truncate at line 730+
            // collapses pushed_vregs to `entry_base + arity` and
            // back-fills the canonical merge_top_vregs into the
            // top slots. Mirrors the param=0 path's MOV+swap
            // shape, just without the "verify merge_base" check
            // (no phantom layer to verify against).
            if (ctx.pushed_vregs.items.len < arity) {
                dbg.print("codegen", "arm64/op_control: emitEndIntra (param else_open) needs >={d} pushed_vregs, got {d} (func_idx={d})\n", .{ arity, ctx.pushed_vregs.items.len, ctx.func.func_idx });
                return Error.UnsupportedOp;
            }
            var i: u32 = arity;
            while (i > 0) {
                i -= 1;
                const else_result = ctx.pushed_vregs.pop().?;
                const merge_vreg = lbl.merge_top_vregs[i];
                try merge_mov.emitMergeMov(ctx, else_result, merge_vreg, 1, 0);
            }
            // Push back canonical merge_top_vregs so the post-block
            // consumer reads the merged result.
            var j: u32 = 0;
            while (j < arity) : (j += 1) {
                try ctx.pushed_vregs.append(ctx.allocator, lbl.merge_top_vregs[j]);
            }
        } else if (ctx.pushed_vregs.items.len < 2 * arity) {
            dbg.print("codegen", "arm64/op_control: emitEndIntra (else_open merge) needs >={d} pushed_vregs, got {d} (func_idx={d})\n", .{ 2 * arity, ctx.pushed_vregs.items.len, ctx.func.func_idx });
            return Error.UnsupportedOp;
        } else {
            // Verify the slot below the else-results is the
            // captured merge buffer. Mismatch surfaces as
            // UnsupportedOp (matches single-result behaviour).
            const merge_base = ctx.pushed_vregs.items.len - 2 * arity;
            var v: u32 = 0;
            while (v < arity) : (v += 1) {
                if (ctx.pushed_vregs.items[merge_base + v] != lbl.merge_top_vregs[v]) {
                    dbg.print("codegen", "arm64/op_control: emitEndIntra merge mismatch at slot {d} — top vreg={d}, merge={d} (func_idx={d})\n", .{ v, ctx.pushed_vregs.items[merge_base + v], lbl.merge_top_vregs[v], ctx.func.func_idx });
                    return Error.UnsupportedOp;
                }
            }
            // D-038 discharge: spill-aware merge MOV. Convention:
            //   stage 0 = merge dest (def-then-store)
            //   stage 1 = else-arm operand load
            // For the unspilled common case both calls return home
            // regs and the store helper is a no-op. Pop in reverse
            // (top = else_{N-1}); MOVs are independent so order
            // doesn't matter for correctness, but reverse-pop
            // matches the natural top-of-stack consumption.
            //
            // Per-slot type dispatch — when the
            // merge target is v128 (per `alloc.shapeTag`), use the
            // q* helpers + `encMovV16B` so the full 128 bits move.
            // Earlier behaviour was 32-bit ORR W which silently
            // truncated v128 merges; surfaced via simd_const.386's
            // `as-block-retval` / `as-if-then-retval` exports.
            var i: u32 = arity;
            while (i > 0) {
                i -= 1;
                const else_result = ctx.pushed_vregs.pop().?;
                const merge_vreg = lbl.merge_top_vregs[i];
                try merge_mov.emitMergeMov(ctx, else_result, merge_vreg, 1, 0);
            }
        }
    }
    // D-093 — implicit-else marshal. `(if (param T1..TK)
    // (result T1..TK)) (then ...)` without an `.else` validates
    // per Wasm spec §3.4.4 (params == results required). The
    // cond=0 path takes an implicit identity else; the
    // post-frame result is the original param. To honour this
    // at runtime: MOV the then-body's top `result_arity` vregs
    // into the captured `param_top_vregs` slots BEFORE the
    // target_byte. cond=1 path falls through the MOVs (writing
    // V_param.slot with the new value); cond=0 path's CBZ
    // jumps to `target_byte` AFTER the MOVs (V_param.slot still
    // has its def value).
    if (lbl.kind == .if_then and lbl.param_arity > 0 and !lbl.merge_captured) {
        if (lbl.param_arity != lbl.result_arity) return Error.UnsupportedOp;
        const arity: u32 = lbl.result_arity;
        if (ctx.pushed_vregs.items.len < arity) return Error.UnsupportedOp;
        const top_base = ctx.pushed_vregs.items.len - arity;
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            const src_vreg = ctx.pushed_vregs.items[top_base + i];
            const dst_vreg = lbl.param_top_vregs[i];
            try merge_mov.emitMergeMov(ctx, src_vreg, dst_vreg, 1, 0);
        }
        // Replace top arity vregs with param_top_vregs so post-if
        // consumers read the canonical merged slot.
        var j: u32 = 0;
        while (j < arity) : (j += 1) {
            ctx.pushed_vregs.items[top_base + j] = lbl.param_top_vregs[j];
        }
    }
    const target_byte: u32 = @intCast(ctx.buf.items.len);
    // Patch the if-then's skip-CBZ if it's still pending (no
    // `else` was encountered).
    if (lbl.if_skip_byte) |skip_byte| {
        const disp: i32 = @as(i32, @intCast(target_byte)) -
            @as(i32, @intCast(skip_byte));
        const orig = std.mem.readInt(u32, ctx.buf.items[skip_byte..][0..4], .little);
        const rt: inst.Xn = @intCast(orig & 0x1F);
        const new_cbz = inst.encCbzW(rt, @divExact(disp, 4));
        std.mem.writeInt(u32, ctx.buf.items[skip_byte..][0..4], new_cbz, .little);
    }
    // Patch all forward br fixups that targeted this label
    // (block, if_then with br inside, else_open including the
    // else-end B). Loop labels have no pending fixups.
    if (lbl.kind == .block or lbl.kind == .if_then or lbl.kind == .else_open) {
        for (lbl.pending.items) |fx| {
            const disp_words: i32 = @as(i32, @intCast(target_byte)) -
                @as(i32, @intCast(fx.byte_offset));
            const new_word: u32 = switch (fx.kind) {
                .b_uncond => inst.encB(@divExact(disp_words, 4)),
                .cbnz_w => blk: {
                    const orig = std.mem.readInt(u32, ctx.buf.items[fx.byte_offset..][0..4], .little);
                    const rt: inst.Xn = @intCast(orig & 0x1F);
                    break :blk inst.encCbnzW(rt, @divExact(disp_words, 4));
                },
            };
            std.mem.writeInt(u32, ctx.buf.items[fx.byte_offset..][0..4], new_word, .little);
        }
    }

    // D-093: truncate pushed_vregs to entry_stack_depth +
    // result_arity, keeping the top result_arity values. When a
    // br inside the block left extra vregs on the operand stack
    // (e.g. `block (result i32) (i32.const 4) (i32.const 8)
    // (br 0)`: stack = [pre, V_four, V_eight] but block result
    // is just V_eight), the extras must be discarded so the
    // post-block consumer reads the correct vregs. For the
    // simple fall-through case (no br) the stack already has
    // exactly `entry + result_arity` entries; the truncation is
    // a no-op. For if/else with merge MOVs (else_open branch
    // above), the merge already aligned pushed_vregs to the
    // canonical merge target vregs, so this final truncation
    // collapses the redundant else-arm slots into a single
    // result slot.
    // D-093: account for Wasm 2.0 block params. The
    // block's body consumed `param_arity` values from the
    // entry-time operand stack (they were on top at block-open),
    // so the post-block height is
    // `entry_stack_depth - param_arity + result_arity`. Earlier
    // the truncate used `entry + result`, which over-counted
    // when the block had params (block:param tests).
    const entry_base: usize = @as(usize, lbl.entry_stack_depth) -| @as(usize, lbl.param_arity);
    const new_len: usize = entry_base + @as(usize, lbl.result_arity);
    if (ctx.pushed_vregs.items.len > new_len and lbl.result_arity > 0) {
        const top_start = ctx.pushed_vregs.items.len - lbl.result_arity;
        var i: usize = 0;
        while (i < lbl.result_arity) : (i += 1) {
            ctx.pushed_vregs.items[entry_base + i] = ctx.pushed_vregs.items[top_start + i];
        }
    }
    if (ctx.pushed_vregs.items.len > new_len) {
        ctx.pushed_vregs.shrinkRetainingCapacity(new_len);
    }
    // D-093: `.loop` fall-through dead — pad with
    // placeholder vreg 0 so the downstream post-loop pop
    // doesn't underflow. Extended (D-130) to all
    // block kinds: a block can become dead via `unreachable`
    // / `br_table` inside its body without any `br` having
    // captured a merge target (e.g. `unreached-valid.wast`
    // `meet-bottom`: br_table-in-dead-code emits nothing, the
    // merge-MOV mechanism never fires, and the block's `.end`
    // sees pushed_vregs.len < entry + result_arity). Pad with
    // vreg 0 (recognised as the dead-fall-through
    // placeholder by marshalFunctionReturn / `.drop` etc.).
    while (ctx.pushed_vregs.items.len < new_len) {
        try ctx.pushed_vregs.append(ctx.allocator, 0);
    }
}
