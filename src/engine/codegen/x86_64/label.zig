//! x86_64 emit pass — control-flow label + fixup types (D-030
//! chunk-a).
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314. The Label
//! shape mirrors arm64's `Label` (per ADR-0014 §6.K.5 +
//! `single_slot_dual_meaning.md` — start vs end semantics live
//! on `kind`, not on a polymorphic field). `merge_top_vreg` is
//! the D-027 if-result merge fix mirror; `if_skip_byte` is the
//! JE-skip patch site for `if_then` frames.
//!
//! Behaviour change zero — emit.zig re-exports `LabelKind`
//! and uses `Fixup` / `Label` via the new import.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

/// Why a Label was pushed on the control stack. block / loop /
/// if_then / else_open mirror arm64's LabelKind for parity at
/// the three-way differential.
pub const LabelKind = enum { block, loop, if_then, else_open };

/// Forward-jump fixup awaiting target resolution. `byte_offset`
/// is the position of the JMP/Jcc instruction's first byte;
/// `insn_size` is 5 (JMP rel32) or 6 (Jcc rel32). `emitEndIntra`
/// patches the disp32 field via `inst.patchRel32`.
pub const Fixup = struct {
    byte_offset: u32,
    insn_size: u8,
};

/// One frame on the per-function control stack.
///   target_byte_offset — for `.loop`, the byte offset of the
///       loop entry. For `.block` / `.if_then` / `.else_open`,
///       undefined until `end`.
///   pending — branch fixups awaiting target resolution.
///   if_skip_byte — when `.if_then`, the byte offset of the
///       JE that skips the then-body. Patched at `else` (to
///       else-body start) or at `end` (to end of if). Cleared
///       when transitioning to `.else_open`.
///   merge_top_vregs — D-027 fix mirror extended to Wasm 2.0
///       multi-value (D-035 chunk-d035-c): for `(if (result
///       T1 .. TN))` blocks, the then arm's top N result vregs
///       are captured at `else`; the else arm's N results are
///       MOVed into the corresponding merge slots at the
///       if-frame's `end` so both paths converge on the same
///       physical regs. Indices `[0..result_arity)` are valid.
///       Mirrors arm64/label.zig.
///   result_arity — Wasm 2.0 multi-value blocktype's result
///       count, captured from `ZirInstr.extra` at the matching
///       block / loop / if push. Cap = `merge_top_vregs.len`;
///       larger arities surface as `UnsupportedOp` at emitIf.
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
    /// whose params are the merge. Mirrors arm64/label.zig.
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

    /// D-093 (d-6) — Wasm 2.0 multi-value block param count.
    /// Mirrors `arm64/label.zig:Label.param_arity`.
    param_arity: u8 = 0,
    /// D-093 (d-10) — `if (param T1 .. TK)` else-arm restore.
    /// Mirrors `arm64/label.zig:Label.param_top_vregs`. emitIf
    /// captures top `param_arity` vregs; emitElse re-pushes them
    /// onto the operand stack at else-arm entry (Wasm spec §3.4.4).
    param_top_vregs: [8]u32 = undefined,
};
