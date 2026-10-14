# 0165 — Validator/runtime control-stack depth cap: raise 1024 → 4096

- **Status**: Accepted (2026-06-06; autonomous-with-ADR per ADR-0153 — rejecting
  valid real-toolchain wasm is a completeness miss, the あるべき論 is to accept it).
- **Date**: 2026-06-06
- **Author**: claude (D-287 discharge; Phase-16 completion-finalization).
- **Tags**: validator, runtime, limits, completeness, §16, D-287, D-241/D-242
- **Amends**: raises a single implementation limit (`zir.max_control_stack`).
  Routine per §18; ADR'd because it touches a §-level limit + carries a memory
  rationale (the debt-row contract for D-287).

## Context

The validator rejected valid deeply-nested modules at the control-stack cap.
`bench/runners/wasm/shootout/switch.wasm` (an LLVM-lowered large C `switch`)
fails `ControlStackOverflow at op 0x2 (block)`; its measured max control-nesting
depth is **2568**, above the cap `zir.max_control_stack = 1024`
(`src/ir/zir.zig:29`). wasmtime accepts the deeper nesting. Rejecting valid wasm
that real toolchains emit is a 100%-spec / full-featured completeness miss.

`zir.max_control_stack` is the single source of truth for: the validator's
`control_buf: [max_control_stack]ControlFrame` (`validator.zig:666`), the
verifier's branch-target ceiling (`verifier.zig:70`, a *check* not an array),
and — mirrored via `frame.zig:34 max_label_stack` — the runtime label stack.
They MUST stay equal (the D-241/D-242 drift family: the runtime must hold every
depth the validator accepts).

## Memory model (why this is a design decision, not a reflexive bump)

- **Validator** — `control_buf` is a FIXED array inside the stack-allocated
  `Validator` struct (`var v = Validator{...}`), so the cap bounds the
  validator's **host-stack** footprint. `ControlFrame` ≈ 64 B (two `BlockType`
  slices + height/kind/flags). At 4096: control_buf ≈ 256 KB; the whole Validator
  struct (also `operand_buf:[1024]` + `locals_init:[1024]`) ≈ ~280 KB. The
  **binding constraint is Windows' 1 MB default thread stack** (vs Unix 8 MB):
  ~280 KB is a comfortable ~28%, whereas 8192 (~540 KB) would be a thin margin on
  Windows. Validation runs at module load on the main thread → safe at 4096.
- **Runtime** — the label stack is HYBRID (`frame.zig`): a small inline
  `label_buf` + a LAZILY heap-allocated `label_overflow` sized to
  `max_label_stack - inline_label_stack`, allocated only when a function actually
  nests past the inline buffer. Raising the cap only raises the lazy-alloc
  ceiling; non-deeply-nested functions pay nothing.
- **Verifier** — `max_block_depth` is only a `>=` ceiling check; no array.

## Decision

Raise `zir.max_control_stack` from **1024 to 4096** (single edit; propagates to
validator + verifier + runtime). Rationale for 4096 specifically: it accepts the
measured real-program depth (switch.wasm = 2568, ~1.6× headroom) while keeping the
validator's host-stack Validator struct (~280 KB) comfortable on Windows' 1 MB
thread stack — a justified, measured value bounded by the Windows stack, not a
reflexive doubling. (8192 was considered but rejected: ~540 KB is a thin margin on
a 1 MB Windows stack.)

## Consequences

- `switch.wasm` and similarly deeply-nested real modules now validate + run.
- Validator host-stack footprint grows ~192 KB (1024→4096 × 64 B) — bounded,
  load-time, main-thread → safe.
- Modules nesting > 4096 control frames are still rejected — pathological /
  adversarial depth, not real-toolchain output.
- **Forward-ref (full spec-completeness)**: the spec imposes NO control-nesting
  limit. A future improvement makes the validator's `control_buf` heap-backed
  (matching the runtime's hybrid-lazy model) so the cap can be removed entirely.
  Tracked as a follow-on under D-287's lineage; out of scope here (keeps this a
  bounded, host-stack-safe change).

## Revision 2026-10-14 — the lowerer sources the cap

The lowerer (`src/ir/lower.zig`) kept its own copy at 1024 and was not reached
by the single edit above; it now sources this constant (#520). The title read
8192 from the first commit (`3176f6b6b`), which chose 4096; it now says 4096.
