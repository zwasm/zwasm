//! ARM64 emit pass — control-flow label + branch-fixup types.
//!
//! Per ADR-0023 §3 reference table + ADR-0021 sub-deliverable b
//! (emit.zig 9-module split): extracted from
//! the previous monolithic `emit.zig` so the control-flow
//! patching machinery has a discoverable home and so emit.zig
//! itself can shrink toward the < 1000 LOC orchestrator goal.
//!
//! ADR-0014 §6.K.5 + `.claude/rules/single_slot_dual_meaning.md`:
//! the `merge_top_vreg` slot is load-bearing for the D-027 fix
//! (`(if (result T))` arm convergence); a future change that
//! merges it with another field is a §14 violation.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

/// Why a Label was pushed on the control stack. Distinguishes
/// forward-resolving block / if branches from backward-resolving
/// loop branches.
pub const LabelKind = enum { block, loop, if_then, else_open };

/// Patching mechanism for an unresolved branch instruction.
/// `b_uncond` = unconditional `B` (br); `cbnz_w` = conditional
/// `CBNZ W` (br_if).
pub const FixupKind = enum { b_uncond, cbnz_w };

/// One pending branch awaiting target resolution. `byte_offset`
/// names the branch instruction's position in the emitted
/// buffer; the patcher recomputes its disp19 / disp26 when the
/// owning Label resolves.
pub const Fixup = struct {
    byte_offset: u32,
    kind: FixupKind,
};

/// One frame on the per-function control stack. The kind +
/// pending list combine to handle both block / loop / if /
/// else flow:
///
///   target_byte_offset — for `.loop`, the byte offset of the
///       loop entry (backward branches resolve immediately).
///       For `.block` / `.if_then` / `.else_open`, undefined
///       until `end` (or `else`) lands; pending fixups patch
///       at that point.
///   pending — branch fixups waiting on target resolution.
///   if_skip_byte — when `.if_then`, the byte offset of the
///       CBZ that skips the then-body. Patched at `else` (to
///       else-body start) or at `end` (to end of if). Cleared
///       when transitioning to `.else_open`.
///   merge_top_vregs — D-027 fix extended to
///       Wasm 2.0 multi-value (D-035): for `(if
///       (result T1 .. TN))` blocks, the then arm's top N
///       result vregs are captured at `else`; the else arm's
///       N results are MOVed into the corresponding merge
///       slots at the if-frame's `end` so both paths converge
///       on the same physical regs. Indices `[0..result_arity)`
///       are valid; remaining slots are undefined.
///   result_arity — Wasm 2.0 multi-value blocktype's result
///       count, captured from `ZirInstr.extra` at the matching
///       block / loop / if push. Cap = `merge_top_vregs.len`;
///       larger arities surface as `UnsupportedOp` at emitIf.
///       Block / loop don't merge two arms so the field is
///       advisory there.
pub const Label = struct {
    kind: LabelKind,
    target_byte_offset: u32,
    pending: std.ArrayList(Fixup),
    if_skip_byte: ?u32 = null,
    merge_top_vregs: [8]u32 = undefined,
    result_arity: u8 = 0,
    /// Whether `merge_top_vregs` names the frame's merge. Set by the
    /// first edge into the frame's `end` (a branch, or a live then arm
    /// at `else`), or by emitIf for an `if` with params and no else,
    /// whose params are the merge.
    merge_captured: bool = false,
    /// D-093 (d-1) — `pushed_vregs.items.len` snapshot at
    /// emitBlock / emitLoop / emitIf, used by emitEndIntra to
    /// truncate operand stack to `entry_stack_depth +
    /// result_arity` at block end. Necessary when a `br` inside
    /// the block left extra vregs on top of the operand stack
    /// (lower.zig strips post-br dead ZirInstrs but the br's
    /// own pre-arg pushes stay on the operand stack — only the
    /// top `branch_arity` vregs are spec-defined block
    /// results). Default 0; emitBlock / emitLoop / emitIf set
    /// the live value before pushing the Label.
    entry_stack_depth: u32 = 0,

    /// D-093 (d-6) — Wasm 2.0 multi-value block param count
    /// (typeidx blocktype's `ft.params.len`). The K params are
    /// already on the operand stack at block-open (validator's
    /// stack discipline) and get consumed by the block body.
    /// emitEndIntra computes `new_len = entry_stack_depth -
    /// param_arity + result_arity` so the truncate is correct
    /// when the body actually consumed the params and replaced
    /// them with results. Default 0; emitBlock / emitLoop /
    /// emitIf unpack from `ZirInstr.extra`'s high byte
    /// (`(params << 8) | results`).
    param_arity: u8 = 0,
    /// D-093 (d-10) — `if (param T1 .. TK)` else-arm restore.
    /// emitIf captures the top `param_arity` vregs from the
    /// operand stack so emitElse can re-push them when the
    /// else-arm begins (Wasm spec §3.4.4: else-arm starts with
    /// the same operand-stack shape as the then-arm did at
    /// `if` entry). Indices `[0..param_arity)` are valid;
    /// remaining slots are undefined. Block / loop / if-without-
    /// params leave the slot unused.
    param_top_vregs: [8]u32 = undefined,
};
