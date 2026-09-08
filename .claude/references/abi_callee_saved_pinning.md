# Project-pinned callee-saved register safety — full detail

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → read on demand only). Stub: [`../rules/abi_callee_saved_pinning.md`](../rules/abi_callee_saved_pinning.md).

# Project-pinned callee-saved register safety

Auto-loaded when editing arm64 / x86_64 `abi`, `prologue`, `thunk`,
`emit`, `op_call`, or `op_control` sources, plus
`shared/thunk.zig`. Codifies the lesson from D-142 (cycle 6,
2026-05-17) — the bridge-thunk X19 corruption + uninit
`host_dispatch_base` chain.

## Why this rule exists

ABI conventions (AAPCS64 §6.4.1 for arm64; SysV / Win64 for
x86_64) designate certain registers as **callee-saved**: a
called function MUST preserve them across the call. The v2
project pins some of these regs for project-specific invariant
use:

- **arm64**: X19 (runtime_ptr) + X23 (globals_base, ADR-0027) +
  X24..X28 (typeidx_base / table_size / funcptr_base / mem_limit /
  vm_base) per ADR-0017 + ADR-0018. D-144 (2026-05-18) found §A1's
  X19-only thunk fix was insufficient because X24-X28 are equally
  pinned-callee-saved and equally violated by the same prologue shape.
  **The cohort is canonical in `abi.zig::reserved_invariant_gprs`, and a
  boundary must read it rather than restate it** — #413 (2026-09-08) is
  the second time an enumeration written beside a boundary went stale,
  X23 having joined the array after the bridge thunk's list was written.
- **x86_64**: R15 = runtime-ptr save (per ADR-0026 Cc-pivot).
  Single-register pinning — other invariants reload from
  `[R15 + offset]` at point of use (so cross-module bridge
  thunks only need to save/restore R15; D-144 does not apply).

The trap: same-module-call hides the violation. Both caller
and callee use the same `*JitRuntime` value, so the callee's
prologue `MOV pinned_reg, X0` (which overwrites without
saving) produces the same value the caller would expect to
read. **Cross-instance / cross-module calls break this** —
caller_rt ≠ callee_rt, so the callee's `MOV X19, X0`
corrupts X19 for the caller's continuation.

## The rule

When editing a function prologue that **overwrites a
callee-saved register without first stack-saving it** (the
v2 convention for X19 / R15), audit ALL call boundaries where
the caller's value in that register may differ from the
callee's:

1. **Same-module direct call** (`call N`): caller_rt ≡ callee_rt
   → no divergence, safe.
2. **Same-module call_indirect through a table whose
   entries are all same-module funcs**: still caller_rt ≡
   callee_rt → safe.
3. **Cross-module call via bridge thunk** (resolver-emitted
   thunk in `arm64/thunk.zig` / `x86_64/thunk.zig`):
   caller_rt ≠ callee_rt → **the callee MUST not corrupt
   pinned callee-saved regs OR the thunk MUST save/restore
   them on the caller's behalf**.
4. **Host import call via `host_dispatch_base[i]` direct
   pointer**: the host C-ABI fn doesn't follow v2's prologue
   convention; it preserves callee-saved per its platform
   ABI → safe.
5. **`assert_trap` recovery via `siglongjmp`**: skips the
   normal epilogue; X19's last value is whatever the JIT
   body left it. If the JIT body did a cross-module call
   then the value is wrong even on recovery.

## Discharge patterns

### Option A: bridge thunk does call-and-return + saves caller's pinned regs

The bridge thunk wraps the cross-module call with a save-
restore block for the full pinned-callee-saved cohort:

```text
arm64 (96 bytes per ADR-0066 §A2 amendment, D-144 cycle 4 —
was 56 in §A1):
   STP X29, X30, [SP, #-80]!          ; save FP/LR + alloc frame
   STR X19, [SP, #16]                 ; save caller's X19
   STR X24, [SP, #24]                 ; save caller's X24
   STR X25, [SP, #32]                 ; save caller's X25
   STR X26, [SP, #40]                 ; save caller's X26
   STR X27, [SP, #48]                 ; save caller's X27
   STR X28, [SP, #56]                 ; save caller's X28
   ADR X16, +<offset>                 ; literal pool ptr
   LDR X0, [X16]                      ; X0 ← callee_rt
   LDR X16, [X16, #8]                 ; X16 ← callee_entry
   BLR X16                            ; CALL
   LDR X19, [SP, #16]                 ; restore X19
   LDR X24, [SP, #24]                 ; ... X24
   LDR X25, [SP, #32]                 ; ... X25
   LDR X26, [SP, #40]                 ; ... X26
   LDR X27, [SP, #48]                 ; ... X27
   LDR X28, [SP, #56]                 ; ... X28
   LDP X29, X30, [SP], #80            ; restore FP/LR, pop
   RET
   (4-byte pad + 16-byte literal pool follow)
```

ADR-0066 §A2 amendment (D-144 cycle 4) — the §A1 fix
addressed only X19; §A2 extended to the full reserved-
invariant cohort once `imports.1.wasm` print64
call_indirect sig-mismatch surfaced the gap.

```text
x86_64 (27 bytes — single pinned reg R15 per ADR-0026):
   PUSH R15                ; save caller's R15
   MOV  RDI, callee_rt
   MOV  RAX, callee_entry
   CALL RAX
   POP  R15                ; restore R15
   RET
```

### Option B: callee prologue saves pinned reg

Add `STR pinned_reg, [SP, ...]` to the prologue before
`MOV pinned_reg, X0`; add the paired `LDR pinned_reg, [SP, ...]`
to the epilogue. Pros: makes the v2 ABI AAPCS-compliant
universally. Cons: every function pays the cost even though
99% of calls are same-module.

### Option C: rename the pinned reg to a NON-callee-saved scratch

E.g., use a caller-saved reg for runtime_ptr_save. Caller would
need to re-MOV X0 → save reg after every call (the caller-side
cost) rather than the callee saving (the callee-side cost).
Substantial refactor; not chosen for v2 historically per
ADR-0017.

## Reviewer checklist

Before merging a change that touches the prologue, bridge
thunk, op_call, or op_control:

- [ ] Does the prologue write to any AAPCS64 callee-saved
      reg (X19..X28) WITHOUT first STP-saving it? If yes,
      identify the cross-instance call paths and verify
      they're covered by option A / B / C.
- [ ] If introducing a NEW pinned callee-saved invariant
      (e.g., a future ADR adds another `reserved_invariant_
      gpr`), update this rule's pinned-reg list AND audit
      the bridge thunk shape.
- [ ] If touching `arm64/thunk.zig` or `x86_64/thunk.zig`,
      verify the thunk shape matches the documented
      ADR-0066 (or its amendment) convention. Tail-jump
      bridges are unsafe under v2's pinning convention; only
      call-and-return is correct.

## Anti-pattern

```zig
// v2 arm64 prologue word 7:
encOrrReg(19, 31, 0);  // = MOV X19, X0
// No prior STR X19. Wrong for cross-module callee.
```

Without a paired stack save before this MOV, the function
violates AAPCS64 callee-saved semantics for X19.

## Forbidden phrasing in commit / ADR text

- "X19 doesn't need saving — same-module calls always use
  the same rt" — true for the common case but the rule
  exists because the uncommon case (cross-module bridge)
  silently corrupts the caller.

## Why this case matters (motivation)

D-142 (Mac aarch64 SEGV at cross-module dispatch boundary)
spent **6 cycles** of investigation rejecting 5 hypotheses
before the X19-corruption + `host_dispatch_base = undefined`
combo was identified. The bug was invisible for 5+ cycles
because **same-module integration tests cannot exercise
it**. Only cross-module bridge thunk integration surfaces
the divergence. Pre-merge auditing per this rule would have
caught it at ADR-0066 design time.

See `.dev/lessons/2026-05-17-gamma3d-dispatch-write-segv-bisect.md`
"Root cause identified" §.

