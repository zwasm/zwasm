# 0218 — Classify host-originated traps apart from guest faults

- **Status**: Accepted
- **Date**: 2026-08-29
- **Author**: Junji Takakura
- **Tags**: c-abi, trap-surface, wasi, jit

## Context

`zwasm_trap_kind` reported `ZWASM_TRAP_UNREACHABLE` (1) for three conditions
that do not originate in the guest. Measured on `5d56a3991` through the C ABI,
with the backend asserted so a silent JIT→interp fallback could not disguise the
result:

| case | auto | jit | interp |
|---|---|---|---|
| guest `unreachable` | 1 | 1 | 1 |
| `proc_exit(0)` / `proc_exit(3)` | 1 | 1 | 0 |
| host callback trap | 1 | 1 | 1 |

A C host calling plain `wasm_instance_new` gets `auto`, which resolves to the
JIT, so it could not tell a clean WASI termination from a genuine fault. The
engines also disagreed about `proc_exit` (1 vs 0), making the answer depend on
which engine `auto` happened to pick.

Four sites are responsible, not the two that issue #331 names:

1. `proc_exit` in `src/wasi/jit_dispatch.zig` — sets `trap_flag`, leaves
   `trap_kind` unwritten (0).
2. `trapResult` in `src/api/jit_host_bridge.zig` — writes the generic bucket (1).
3. `hostFuncThunk` in `src/api/instance.zig` — returns `Trap.Unreachable`. The
   interp twin of (2); leaving it would keep the engines disagreeing.
4. `mapInterpTrap` in `src/api/trap_surface.zig` — has no arm for the
   `error.WasiExit` that the interp's preview1 `proc_exit` thunk unwinds with,
   so it falls through `else => .binding_error`. The interp twin of (1), and
   the one the first draft of this decision missed: with (1) fixed alone the
   JIT reported 18 while the interp still reported 0, and the cross-engine test
   stayed red.

Sites (1) and (2) then fall through `jitTrapCode(...) orelse .unreachable_`.

Two distinct number spaces meet here and are easy to confuse: the JIT
stub-code space recorded in `JitRuntime.trap_kind`, and the public
`ZWASM_TRAP_*` / `TrapKind` space. They agree only from 14 upward, and by
coincidence — `unreachable` is stub 5 / public 1, `oob_table` is stub 2 /
public 6. `trap_surface.jitTrapCode` is the only place the two are related.

This is **not** the D-292 / D-293 codegen widening. That programme demultiplexes
traps the *codegen* emits; these three never reach codegen.

Timing: `zwasm/zwasm-rust-sdk` has not published 0.2.0. Its `TrapKind` is
`#[non_exhaustive]` with `Unknown(i32)`, so *adding* a kind never breaks
downstream — what costs downstream is a value moving between existing variants,
which is exactly what "`proc_exit` stops reporting `Unreachable`" is.

## Decision

**Host-originated traps get kinds of their own, distinct from any guest fault.**

WASI `proc_exit` reports a new `ZWASM_TRAP_WASI_EXIT` = 18 (`TrapKind.wasi_exit`):
a guest that asks to terminate has not faulted, and a successful exit least of
all. The exit status itself stays where ADR-0156-era work and #330 put it —
`zwasm_store_wasi_exit_code` — so kind and status remain independent. A host
callback's trap, and any embedder-binding failure, reports `binding_error` (0)
on every engine: the meaning that kind already carries ("host invocation
error"), widened rather than invented.

Each engine reaches those two kinds by its own route. The JIT sites write
dedicated stub codes that `jitTrapCode` maps; the interp maps its own errors —
`error.WasiExit` to `wasi_exit`, and a new `error.HostTrap` to `binding_error`.
The `error.WasiExit` arm is what actually closes the cross-engine
disagreement.

Both JIT sites carry **dedicated stub codes** (18, 19) rather than being folded
into the generic bucket. The bucket must keep meaning "the codegen has not split
this trap yet" (D-292); absorbing host-originated traps into it would make the
still-generic codegen traps report `binding_error` — a different lie.

`runtime.Trap` gains `HostTrap`, in the same spec-external class as `Interrupted`
and `OutOfFuel`. It flows into `Instance.InvokeError` for free
(`InvokeError = {...} || Trap`), so the Zig facade gains the same distinction,
and Zig's exhaustive switches enumerate the mapping sites instead of an `else`
arm swallowing them.

Existing `ZWASM_TRAP_*` values are unchanged; 18 is appended, per the header's
append-only-stable declaration.

## Alternatives considered

### Alternative A — host-originated → `binding_error`, no new constant

- **Sketch**: route all three sites to the existing `binding_error` (0). Closes
  #331, makes the engines agree, adds nothing to the C ABI.
- **Why rejected**: it files a successful `proc_exit(0)` under "host invocation
  error", and forces a C host to make a second call
  (`zwasm_store_wasi_exit_code`) merely to discover that the reported failure
  was a normal termination. `proc_exit` is the host-originated trap a WASI
  embedder meets most often, so this is the case the surface should name, not
  the one it should obscure. The move off `Unreachable` has to happen either
  way; making it once, straight to the final value, is strictly cheaper than
  making it twice.

### Alternative B — carry the host callback's own trap detail across the bridge

- **Sketch**: instead of consuming the callback's `*Trap`, forward its `kind`
  (and ideally its message) to the C surface, so an embedder sees the trap it
  itself constructed.
- **Why rejected**: measured, the detail is not *structurally* lost — the
  callback's `*Trap` is in hand at both host-callback sites with a live `kind`
  and `message_ptr` and is deliberately deleted. But it cannot travel through
  `rt.trap_kind`: that field is stub-code space, the callback's kind is public
  `ZWASM_TRAP_*` space, and the two collide at exactly 0 and 1 — the values a
  callback most likely carries. Forwarding the kind needs a new `JitRuntime`
  field; forwarding the message needs new storage and an ownership contract on
  both paths. Out of proportion to this defect, and fully compatible with this
  decision if wanted later.

## Consequences

- **Positive**: a C host can distinguish a guest fault, a clean WASI exit, and
  its own callback's failure, and gets the same answer from every engine. The
  cross-engine `proc_exit` disagreement (1 vs 0) is closed. The Zig facade maps
  `wasi_exit` to the existing `error.ProcExit` ("a clean noreturn termination,
  NOT a wasm trap"), aligning the JIT path with the component-WASI path.
- **Negative**: a C host switching on `zwasm_trap_kind` sees changed values for
  every host-originated trap — `proc_exit` moves `1` → `18` on the JIT and
  `0` → `18` on the interp, and a host callback's trap moves `1` → `0` on both.
  This is a behaviour change on a public surface, taken deliberately before
  `zwasm-rust-sdk` 0.2.0 publishes, while nothing downstream observes the old
  values.
- **Neutral / follow-ups**:
  - `include/zwasm.h` grows one constant; `scripts/check_trap_abi_sync.sh`
    keeps the header and the enum matched by name and value.
  - One invariant-stating comment changes meaning: `jitTrapToError` describes
    `trap_kind` as "the stub-recorded code", which stops being true once host
    thunks write 18 and 19. Its other claims — including "honest pending the
    per-kind codegen widening" — stay true of the codegen bucket and stay as
    they are.
  - Not addressed here: the Zig facade's preview1 `proc_exit` path reaches
    `mapDispatchErr`, which has no `error.WasiExit` arm and would `@panic`. No
    known caller reaches it (the facade wires no preview1 host imports), so it
    is a latent gap rather than a live bug.
  - Not addressed here: the doc comment at `src/api/zwasm_ext.zig:113` still
    says `auto` resolves to the interp; measurement says the JIT. Same class as
    the header claim tracked by #309.

## References

- Issue: zwasm/zwasm#331; the exit-status reader it leaves untouched is
  zwasm/zwasm#330
- Related ADRs: ADR-0200 (JIT-backed engine surface, `jitTrapToError`),
  ADR-0199 (JIT `proc_exit` post-call `trap_flag` check), ADR-0179 (the
  `interrupted` / `out_of_fuel` precedent for spec-external trap kinds),
  ADR-0164 (trap/crash diagnostics programme), ADR-0212 D1 (product semantics
  require maintainer sign-off)
- Debt: D-292 / D-293 — the codegen generic-bucket widening this decision
  deliberately does not touch
- Files: `src/api/trap_surface.zig`, `src/wasi/jit_dispatch.zig`,
  `src/api/jit_host_bridge.zig`, `src/api/instance.zig`,
  `src/zwasm/instance.zig`, `src/runtime/trap.zig`, `include/zwasm.h`;
  tests in `src/api/zwasm_ext.zig` and the `trapKindName` arm in
  `test/runners/wast_runtime_runner.zig`
