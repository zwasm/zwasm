//! WASM Spec §4.2.10 "Frames" + §4.2.11 "Activations" + label
//! stack.
//!
//! Per ADR-0023 §3 P-D: extracted from the previous
//! `runtime/runtime.zig` so each WASM Spec §4.2 concept owns its
//! file. `max_operand_stack` / `max_frame_stack` /
//! `max_label_stack` constants live here because they bound the
//! frame's inline buffers; per ROADMAP §P3 (cold-start: no
//! per-call allocation) the buffers are inline-fixed.
//!
//! Zone 1 (`src/runtime/`).

const std = @import("std");

const value = @import("value.zig");
const trap_mod = @import("trap.zig");
const zir = @import("../ir/zir.zig");

const FuncType = zir.FuncType;
const Value = value.Value;
const Trap = trap_mod.Trap;

pub const max_operand_stack: u32 = 4096;
/// Frames held inline in the Runtime (zero-alloc common case; ROADMAP §P3
/// cold-start). Deeper call chains spill into heap chunks of the same size,
/// allocated on first use and kept until `Runtime.deinit`.
pub const frame_chunk_len: u32 = 256;
/// Default call-depth cap (`Runtime.max_frame_depth`). The interp also recurses
/// on the host stack per wasm call, so the native-stack check (D-288 /
/// ADR-0167) usually binds first; this cap is the hard ceiling that keeps
/// runaway recursion a `CallStackExhausted` trap on any stack size. Language
/// runtimes nest deeper than the old fixed 256 during their own init, so the
/// default sits well above it.
pub const default_max_frame_depth: u32 = 16 * 1024;
/// The inline frame capacity (kept for callers sized against it).
pub const max_frame_stack: u32 = frame_chunk_len;
/// Inline per-frame label capacity (zero-alloc common case). Frames
/// nesting control deeper than this spill into `Frame.label_overflow`
/// (D-242) — keeps the common Frame small so per-call copies stay cheap.
pub const inline_label_stack: u32 = 128;
/// Total per-frame control-label depth cap = the validator's
/// `max_control_stack` (shared `zir.max_control_stack`). The runtime MUST
/// hold every control depth the validator accepts; a stale literal 128 <
/// 1024 wrongly tripped StackOverflow on validator-accepted deeply-nested
/// functions, e.g. standard-Go's wasip1 output (D-242, D-241 drift family).
pub const max_label_stack: u32 = @intCast(zir.max_control_stack);

/// Control-label record. `block` / `if` push a label whose
/// `target_pc` points one past the matching `end`; `loop` pushes a
/// label whose `target_pc` points just after the `loop` opcode (so
/// that `br` to a loop re-enters the body).
///
/// Two arities because `loop` distinguishes them: `arity` is the
/// number of result values the matching `end` transfers (i.e. the
/// blocktype's result count); `branch_arity` is the number a `br`
/// to this label transfers (= results for block/if; = params for
/// loop, which is 0 in Wasm 1.0 — multivalue loop-with-params is
/// a Phase 2 carry-over per ROADMAP §9.2 chunk 3b).
pub const Label = struct {
    height: u32,
    arity: u32,
    branch_arity: u32,
    target_pc: u32,
    /// Index into the owning `ZirFunc.blocks` — set by every
    /// block-pushing op (`block` / `loop` / `if` / `try_table`)
    /// from the `ZirInstr.payload` field. Wasm 3.0 EH's interp
    /// unwinder (10.E-5b) uses this to identify `.try_table`
    /// labels by reading `func.blocks.items[block_idx].kind`,
    /// then looks up the matching `LandingPad` in
    /// `func.eh_landing_pads`. Defaults to 0 so existing
    /// ad-hoc test fixtures that don't construct a real func
    /// still produce well-defined Labels (BlockInfo at index
    /// 0 is fine to read; the unwinder only consults the
    /// kind, and `.block` is the safe default).
    block_idx: u32 = 0,
};

comptime {
    // ADR-0014 §6.K.5 + `.claude/rules/single_slot_dual_meaning.md`:
    // the dual-arity split is load-bearing. `arity` is consumed by
    // `endOp` (= block/loop result count); `branch_arity` is
    // consumed by `brOp` (= block/if results, but loop *params*).
    // Iter 11 of §9.6 / 6.E (commit 7b26760) split a previously
    // single `arity` slot after `tinygo_fib`'s `loop (result i32)`
    // dispatched the wrong pop-count. A future merge that drops
    // either field would silently re-introduce the underflow; this
    // assertion fails compilation if that happens.
    if (!@hasField(Label, "arity") or !@hasField(Label, "branch_arity")) {
        @compileError("Label.arity and Label.branch_arity must remain split per §14 (single_slot_dual_meaning).");
    }
}

/// Per-call activation record. `locals` holds params followed by
/// declared locals (validator's local-index space). `operand_base`
/// is the operand-stack height at frame entry — `end` / `return`
/// pop the stack down to this height before pushing results.
/// `pc` is the instruction index into the corresponding
/// `ZirFunc.instrs` array.
pub const Frame = struct {
    sig: FuncType,
    locals: []Value,
    operand_base: u32,
    pc: u32,
    /// Borrowed pointer to the active `ZirFunc` so control-flow
    /// handlers can resolve `instr.payload` (a block index) into
    /// `BlockInfo` (`start_inst`, `end_inst`, `else_inst`). Set
    /// by `call` / external runner; left null for ad-hoc test
    /// frames that don't exercise control flow.
    func: ?*const zir.ZirFunc = null,
    /// Set by `end` / `return` handlers to signal the dispatch
    /// loop to break out of the body. Distinct from `pc >=
    /// instrs.len` so handlers can stop early without computing
    /// the bound themselves.
    done: bool = false,

    label_buf: [inline_label_stack]Label = undefined,
    /// Heap spill for labels at index >= `inline_label_stack` — lazily
    /// allocated on first overflow (most frames never touch it), freed at
    /// `Runtime.popFrame` (D-242). Value-copied with the Frame, but only
    /// one owner frees it (the popFrame that retires the activation).
    label_overflow: []Label = &.{},
    label_len: u32 = 0,

    /// Stable `*Label` for label index `i` — inline buffer for the first
    /// `inline_label_stack`, else the heap overflow.
    fn labelSlot(self: *Frame, i: u32) *Label {
        if (i < inline_label_stack) return &self.label_buf[i];
        return &self.label_overflow[i - inline_label_stack];
    }

    pub fn pushLabel(self: *Frame, alloc: std.mem.Allocator, l: Label) Trap!void {
        if (self.label_len == max_label_stack) return Trap.StackOverflow;
        // Lazily allocate the overflow the first time labels exceed the
        // inline capacity — once, at full size (no realloc).
        if (self.label_len == inline_label_stack and self.label_overflow.len == 0) {
            self.label_overflow = alloc.alloc(Label, max_label_stack - inline_label_stack) catch return Trap.StackOverflow;
        }
        self.labelSlot(self.label_len).* = l;
        self.label_len += 1;
    }

    pub fn popLabel(self: *Frame) Label {
        std.debug.assert(self.label_len > 0);
        self.label_len -= 1;
        return self.labelSlot(self.label_len).*;
    }

    /// Index 0 = innermost. Caller must ensure depth < label_len.
    pub fn labelAt(self: *Frame, depth: u32) Label {
        std.debug.assert(depth < self.label_len);
        return self.labelSlot(self.label_len - 1 - depth).*;
    }
};

const testing = std.testing;

test "Label: arity and branch_arity hold distinct values without aliasing (ADR-0014 §6.K.5)" {
    const l: Label = .{
        .height = 0,
        .arity = 1, // matches `loop (result i32)`'s end-arity
        .branch_arity = 0, // matches `br` to a Wasm-1.0 loop (no params)
        .target_pc = 42,
    };
    try testing.expectEqual(@as(u32, 1), l.arity);
    try testing.expectEqual(@as(u32, 0), l.branch_arity);
    try testing.expect(l.arity != l.branch_arity);
}
