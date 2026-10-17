# 0026 — x86_64 runtime invariant reservation: reload-from-runtime-ptr (single-reservation model)

- **Status**: Closed (Phase 7 DONE)
- **Date**: 2026-05-05
- **Author**: Shota / autonomous loop
- **Tags**: jit, abi, runtime, x86_64, phase7

## Context

ADR-0017 established the JIT calling convention with `*const
JitRuntime` carried in the first GPR arg slot (X0 on ARM64,
RDI on x86_64). The body's prologue loads five invariants
(`vm_base`, `mem_limit`, `funcptr_base`, `table_size`,
`typeidx_base`) from `*X0` into reserved callee-saved registers
(X28/X27/X26/X25/X24), plus X19 holds the saved runtime ptr
(sub-2d-ii amendment) — total **6 callee-saved GPRs reserved**
on ARM64.

ADR-0017 §"Per-arch parity by construction" claimed:

> x86_64 (ADR-0019) uses the same `JitRuntime` shape with
> arch-specific reg assignments (RDI = runtime ptr, etc.).

This phrasing implied **mirror reservation** on x86_64. In
practice that mirror is unworkable:

- ARM64 callee-saved GPRs: X19..X28 (10 regs). Reserving 6
  leaves 4 callee-saved + 7 caller-saved scratch (X9..X15) =
  pool of 9.
- x86_64 callee-saved GPRs (SysV ∩ Win64 intersection): RBX,
  RBP, R12, R13, R14, R15 (**6 regs**). RBP is the frame pointer
  in our prologue. Reserving 5 of the remaining 5 leaves zero
  allocatable callee-saved.
- Caller-saved scratch (excluding arg / return regs): R10, R11
  only.
- Mirror reservation pool: **2 caller-saved scratch + 0
  callee-saved = 2 regs**. Insufficient even for trivial bodies
  (a binary op needs lhs + rhs + result = 3 regs).

The §9.7 / 7.6 chunk-c (abi.zig SysV) deferred this with a
documented header note. The §9.7 / 7.7 skeleton + ALU + cmp +
shift + bitcount + locals chunks ran without runtime invariants
(no memory ops, no calls), so the deferral has held for 7
chunks. The next chunk to land memory ops (`i32.load/store` →
needs `vm_base` + `mem_limit`) forces the decision.

This ADR is filed BEFORE the memory-ops chunk so the design
choice is structural rather than emergent.

## Decision

**x86_64 adopts a single-reservation, reload-from-runtime-ptr
model**, not the ARM64 load-once mirror.

### Reserved GPRs on x86_64 (callee-saved, removed from pool)

- **R15 — `runtime_ptr_save`**. Captures `*const JitRuntime`
  in the prologue (`MOV R15, RDI`), persists across all calls
  in the body without explicit save/restore (R15 is callee-
  saved per SysV §3.2.1 + Win64). Mirrors the role of ARM64's
  X19 = `runtime_ptr_save_gpr` (ADR-0017 sub-2d-ii).

That's the **only** invariant register reserved. The other five
JitRuntime invariants (`vm_base`, `mem_limit`, `funcptr_base`,
`table_size`, `typeidx_base`) are **reloaded from R15 at point
of use** in each op handler that needs them.

### Memory-op emission shape (x86_64)

Each `i32.load offset=N` becomes:

```
MOV  R_tmp, [R15 + vm_base_off]    ; reload vm_base
MOV  R_addr, src_addr              ; (or MOVZX W → Q for index)
ADD  R_addr, N                     ; effective addr
CMP  R_addr, [R15 + mem_limit_off] ; bounds vs mem_limit
JAE  trap_stub                     ; trap if out-of-bounds
MOV  R_dst, [R_tmp + R_addr]       ; the actual load
```

vs the ARM64 equivalent which uses pre-loaded X28/X27 directly:

```
ORR  W16, WZR, W_addr              ; zero-extend addr
ADD  X16, X16, #N                  ; effective addr
CMP  X16, X27                      ; bounds vs mem_limit (in reg)
B.HS trap_stub
LDR  W_dst, [X28, X16]             ; load via pre-loaded vm_base
```

The x86_64 path emits **+1 LOAD per memory op** for the
`vm_base` reload (the `mem_limit` compare folds into the CMP's
memory operand without a separate load).

### Pool sizing on x86_64 (post-reservation)

```
Reserved (callee-saved):       R15
Frame pointer (callee-saved):  RBP
Allocatable callee-saved:      RBX, R12, R13, R14    (4 regs)
Allocatable caller-scratch:    R10, R11              (2 regs)
                               -------------------------------
                               Total pool: 6 GPR slots
```

Compare ARM64 post-ADR-0017+0018: 9 GPR slots. The x86_64
deficit is real but structurally bounded — for any function
that needs more than 6 concurrently-live i32 vregs, the
regalloc spills (per ADR-0018). This is consistent with P3
(cold-start over peak throughput): we accept smaller-pool
overhead in early phases, optimisation lands in Phase 8/15.

### Frame-pointer policy (x86_64)

RBP stays as the frame pointer (`PUSH RBP ; MOV RBP, RSP`)
even though SysV permits frame-pointer-omission. Rationale:

- Local-slot addressing via `[RBP + disp8]` is shorter than
  `[RSP + disp]` (which requires SIB).
- Stack-walking debuggers + Phase 8 unwind-info benefit from
  frame chaining.
- Symmetry with ARM64 (FP at X29) keeps the §9.7 / 7.11
  three-way differential reading the same shape across backends.

The trade-off (1 callee-saved reg consumed by FP) is accepted.
Phase 8 may revisit if benchmarks show pool pressure dominating
over hot-path code-density wins.

## Alternatives considered

### Alternative A — Mirror ARM64 (reserve 5 invariants + R15 = runtime_ptr)

- **Sketch**: `reserved_invariant_gprs = [R11, R12, R13, R14,
  R15]` (5 regs) + R10 if RBP is omitted. Allocatable callee-
  saved: ∅. Pool: caller-scratch only (R10, R11 — but those
  ARE the reserved set under this alternative).
- **Why rejected**: pool collapses to 0 unless we sacrifice
  scratch reservation, which then breaks `EncodedInsn` ID-vreg
  marshalling. Mirror reservation only works on ARM64 because
  ARM64 has 31 GPRs to start with.

### Alternative B — Reserve 3 invariants (R13/R14/R15 for vm_base/mem_limit/runtime_ptr)

- **Sketch**: most-frequent invariants get callee-saved slots;
  funcptr_base / table_size / typeidx_base reload at call_indirect
  sites (rarer than memory ops).
- **Why rejected**: introduces a per-invariant priority decision
  that's hard to defend without bench data. Phase 8 optimisation
  is the right place for such decisions; Phase 7 baseline picks
  the structurally simplest model. Also: `funcptr_base` IS used
  by every call_indirect, which is common in many Wasm modules
  (vtables, dispatch tables) — a 3-reg picking exercise risks
  being wrong and hurting the more important code path.

### Alternative C — Omit frame pointer (RBP allocatable)

- **Sketch**: skip `PUSH RBP ; MOV RBP, RSP`; locals at
  `[RSP + disp]` with SIB byte. Frees RBP for the regalloc
  pool, restoring 1 callee-saved slot.
- **Why rejected**: SIB-byte encoding adds 1 byte per local
  access (4-byte instruction → 5-byte). Most function bodies
  reference locals more often than they touch invariants;
  net code-size loses. Asymmetric vs ARM64 (which uses FP).
  Phase 8 is the right venue for this decision under bench
  pressure, not Phase 7 baseline.

### Alternative D — Pre-load invariants into R15-relative scratch on first use

- **Sketch**: per-function liveness analysis decides which
  invariants are actually used; pre-load only those into spare
  callee-saved at prologue.
- **Why rejected**: this IS the Phase 8/15 optimisation. ADR-0017
  §"Future Phase 8+ extensions" already mentions liveness-driven
  invariant load. Phase 7 baseline must pick a structural choice
  that doesn't require liveness analysis.

## Consequences

### Positive

- **Pool size known + bounded** (6 GPR + 8 XMM). Regalloc port
  for x86_64 plans against a fixed pool.
- **Structural disjointness check works** (the comptime block
  in abi.zig that asserts `allocatable_gprs ∩ reserved_invariant_gprs
  == ∅`). Mirrors the ARM64 W54-class structural fix from ADR-0018.
- **Per-arch divergence is documented, not hidden**. Future
  port work (RISC-V, Power, etc.) reads this ADR + ADR-0017
  + ADR-0018 and knows the per-arch reservation is a design
  decision, not a contract.
- **Phase 8/15 optimisation has a concrete starting point**
  (Alternative D + B, with bench data driving which invariants
  earn callee-saved promotion).

### Negative

- **+1 LOAD per memory op** vs ARM64. Acceptable per P3.
- **+1 LOAD per call_indirect** for the funcptr_base + typeidx_base
  reloads (call_indirect is already a 6-instr sequence; +2
  loads is ~33% overhead at the call site, acceptable for
  Phase 7 baseline since call_indirect is not a hot path in
  the realworld JIT corpus we benchmark against).
- **Backend-equality nuance**: ARM64 and x86_64 emit `len(memory_ops)
  + len(call_indirect_ops)` extra bytes per function (~5-6
  bytes per memory op vs ARM64's tighter encoding). The §9.7 /
  7.11 three-way differential operates on Wasm-observable
  output, not on emitted byte count, so backend equality (P7)
  is preserved.

### Neutral / follow-ups

- **`memory.grow` integration**: the host updates `vm_base` /
  `mem_limit` in the JitRuntime struct. **Cross-call**:
  subsequent function calls re-load (no code re-emission).
  **Within-call**: a `memory.grow` op handler must NOT cache
  the post-grow `vm_base`/`mem_limit` in registers — they get
  reloaded at the next memory op naturally because that's the
  baseline strategy. (ARM64 has the opposite invariant: the
  post-grow handler MUST re-LDR X28/X27. ADR-0017 §"memory.grow
  integration" notes this; our reload-each-time model sidesteps
  it on x86_64.)
- **Phase 8 optimisation roadmap**: liveness-driven invariant
  hoisting (`vm_base` / `mem_limit` into RBX or R14 when the
  function has ≥ N memory ops AND ≤ M concurrent vregs at any
  point). Captured as future ADR slot.
- **Win64 ABI integration** (ADR-0019 chunk c2): RBX/RBP/R12-R15
  are also callee-saved under Win64; R15 reservation is
  Cc-agnostic. Win64 also adds RDI/RSI to the callee-saved set
  (vs SysV caller-saved), which would extend the allocatable
  pool by 2 if Win64 is chosen. Cc selection happens at compile
  time of zwasm itself (not at JIT time), so the pool size is
  per-build constant; emit.zig consumes whichever set abi.zig
  exports.

## References

- ROADMAP §2 (P3 cold-start, P7 backend equality)
- ROADMAP §9.7 / 7.6 (deferred reservation), §9.7 / 7.7
  (where this lands operationally)
- ADR-0017 (`*const JitRuntime` ABI — load-once on ARM64)
- ADR-0018 (regalloc reserved set + spill — provides the
  comptime disjointness check shape)
- ADR-0019 (x86_64 in Phase 7 — operational scope)
- `src/engine/codegen/x86_64/abi.zig` (consumer; comptime
  invariant checks live here)
- `src/engine/codegen/arm64/abi.zig` lines 84-103 (the
  reference reservation pattern this ADR diverges from)
- AMD64 SysV ABI v0.99.6 §3.2.1 (callee-saved set)
- Microsoft Win64 ABI (callee-saved set; RDI/RSI added)

## Revision history

| Date       | Commit       | Summary                                                                                  |
|------------|--------------|------------------------------------------------------------------------------------------|
| 2026-05-05 | `bb404088` | Initial Decision; reload-from-runtime-ptr + R15-only reservation. Filed before memory-op chunk so the design is structural, not emergent. |
| 2026-05-06 | `f55ddb99` | First non-memory consumer landed: ADR-0027 globals access. `global.get` / `global.set` (i32) emit `MOV RAX, [R15 + globals_base_off=48]; MOV r/m32, [RAX + idx*8]` — exactly the reload-from-runtime-ptr pattern this ADR predicted. Validates that the abstraction generalises beyond memory ops. R15 single-reservation invariant unchanged. |
| 2026-05-18 | `53df1740` | **Amendment (superseded by Convention Swap below)**: MEMORY-class return originally specified R11 as the hidden indirect-result-pointer for `sig.results.len > 2` returns on SysV. Replaced 2026-05-18 by the Convention Swap. |
| 2026-05-18 | `0cba220b` | **Amendment — Convention Swap (D-140 close)**: x86_64 SysV MEMORY-class returns now follow standard SysV §3.2.3 — `RDI = &buffer`, `RSI = rt`, user int args from RDX (slot 2). The earlier R11-internal convention bridged Zig→JIT through inline-asm thunks for every Class C signature; that bridge becomes prohibitively complex at 17+ args (D-140 large-sig fixture). Aligning with the platform ABI lets entry helpers stay native `callconv(.c)`. **Impact**: `emit.zig` prologue captures RDI to the indirect-result frame slot and uses RSI as the rt source for R15. `op_call.zig::emitCall`/`emitCallIndirect` emit `LEA RDI, [RSP+buffer_off]` (replacing the previous LEA R11) and `MOV RSI, R15` (replacing MOV RDI, R15) when calling a MEMORY-class callee. `marshalCallArgs` starts `gpr_arg_slot` at 2 for MEMORY-class callees (RDX onward), shrinking the user-int reg pool to 4 (RDX/RCX/R8/R9). `marshalReturnRegs` MEMORY-class branch still reads the frame slot into RAX and writes via `[RAX + i*8]` (slot offset unchanged; only the prologue source changes from R11 to RDI). Non-MEMORY-class returns are unaffected. **Win64 MEMORY-class** remains deferred (§9.13-0). **References**: ADR-0017 2026-05-18 amend (arm64 X8 mirror, untouched), ADR-0069 §Phase 3 (D-140 close), lesson `2026-05-18-apple-arm64-natural-packing.md` (orthogonal arm64 ABI gap surfaced during D-140 close). |

## Revision 2026-10-17 — eight allocatable GPRs

The pool is RBX, R12, R13, R14, RSI, RDI, R8, R9 under both conventions (the
six-slot table above, with R10/R11, has been stale since D-045 13b made them
the spill stage). The callee-saved four come first, and only they hold
register-homed locals (ADR-0155), which stay in their register across a
runtime callout. Argument registers can be in the pool because a value live
across a call goes to a slot (ADR-0060), the call family moves its arguments
in parallel, and the other handlers that write them are fenced (ADR-0077,
operand set). The unwired Win64 table that added only RDI and RSI is gone.
