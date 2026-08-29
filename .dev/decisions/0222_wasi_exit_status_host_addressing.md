# 0222 — The WASI exit status is read from the host the called instance captured

- **Status**: Accepted
- **Date**: 2026-08-29
- **Author**: Junji Takakura
- **Tags**: c-abi, wasi, store, exit-status

## Context

`zwasm_store_wasi_exit_code` resolved the WASI host from `store.wasi_host` —
whichever config is installed *now*. A guest writes `exit_code` on the host its
instance captured at instantiate time: `host_call.ctx` per WASI import for the
interpreter (`src/api/instance.zig` `buildBindings`), `jit.owned.rt.wasi_host`
for the JIT (`instantiateJit`). ADR-0219 then made `zwasm_store_set_wasi` move
`store.wasi_host` on while keeping the displaced host alive on
`retired_wasi_hosts`, precisely because instances still hold its address.

So the writer and the reader address different hosts as soon as the config
moves, and `include/wasi.h` already tells a C host that an instance keeps using
the config it was built with. Nothing in the header says the exit status is an
exception, and a host following the two rules the accessor's comment states
misclassifies the termination either way.

Measured on `62d9452d5`, x86_64-linux, through the C ABI. One Store; an
instance built under config A that always calls `proc_exit(7)`; the config then
moved on; then that instance's `_start`. Expected `code=7`. Identical on auto,
jit and interp:

| how the config moved on | `62d9452d5` | parent of #341 |
|---|---|---|
| replaced, new host never ran | `has_code=0` | `has_code=0` |
| replaced, new host carries a 5 of its own | `has_code=0` | **`code=5`** |
| detached with `NULL` | `has_code=0` | `has_code=0` |

The second row is why the regression case asserts the **code**. A check on
`has_code` alone passes on the `code=5` reading, which is the worse of the two
failures: one guest's status reported as another's, with nothing to distinguish
it from a correct answer.

#341 did not cause this and does not reach it. Its per-call clear operates on
the installed host, so it changed the second row's symptom from a fabricated
status to no status; the addressing was wrong before it and after it.

**The defect was filed twice, 40 minutes apart** — #345 (07:30Z) and #350
(08:11Z) — with the same mechanism cited down to the same line numbers. #350
adds the third row above, the `NULL` detach, which #345's investigation had
not covered. Both are closed by this decision; the duplication is recorded
here because the second report is what produced the third case.

## Decision

**The Store records the WASI host each call actually reaches, and the accessor
reads that. The signature does not change.**

- `Store.active_wasi_host: ?*anyopaque` — the host the most recent call
  reached. `Instance.wasi_host: ?*anyopaque` — the host that instance captured.
- Both are written at exactly the two sites that already set
  `wasi_host_captured`, and **before** the start function runs. Keying on the
  flag rather than on `wasi_host != null` is what makes the stored pointer
  safe: the flag is the condition under which ADR-0219 retires the host
  instead of freeing it.
- `wasm_func_call` sets `active_wasi_host` from the called instance, then
  clears that host's status (#341's clear, now aimed at the right host). A
  `wasm_func_new` handle has no instance, so it records no host.
- `zwasm_store_wasi_exit_code` resolves through `active_wasi_host`, with **no
  fallback** to `wasi_host`.
- `src/cli/run.zig`'s trap-vs-exit branch resolves through the same helper. It
  was the second Store-mediated reader of the field.

`include/wasi.h` gains the half it was leaving to inference: the status is read
from the setup the *called* instance was built with, so moving the Store's
config on neither hides an older instance's status nor lets a newer instance's
stand in for it.

## Alternatives considered

**Make the accessor instance-scoped (`wasm_instance_t*`).** #341 rejected this
on sequencing — `zwasm-rust-sdk` was pinning the contract, and changing a
signature underneath that is backwards. **That reason has expired**: the SDK is
still pinned at `278587f60`, before `zwasm_store_wasi_exit_code` existed, so no
published consumer holds the signature and the window is genuinely open. It is
rejected here on two new grounds instead, and they are the ones that survive
the window closing:

1. A `wasm_instance_t*` parameter carries no information the Store cannot
   already resolve. The Store knows which instance made the last call; the
   caller would be handing back a fact the Store just recorded.
2. It strands `src/cli/run.zig`. That reader sits after
   `invoke_args_mod.invokeFormatted` returns and has no instance handle in
   scope — only the Store. An instance-scoped accessor would leave the CLI on
   the old addressing, which is the two-readers-disagree shape this decision
   exists to remove.

Recorded explicitly because the expired reason is the one on the record, and
without this the option reads as merely deferred.

**Ship both (Store-scoped and instance-scoped).** Rejected for the reasons
above plus the cost of keeping two contracts in step for one field.

**Clear the status inside `zwasm_store_set_wasi`.** Cheaper, and wrong in the
direction that matters: it makes the second row read like the first — an
exited guest reported as a fault — rather than making either correct.

**Fall back to `store.wasi_host` when nothing has been recorded.** Rejected.
With the recording done at capture time there is no state where the fallback
reports something true, and it would restore the defect on the direct-callback
path, where the right answer is "no guest ran".

## Consequences

**Reading a retired host is safe by construction, not by inspection.**
`active_wasi_host` is only ever set to a host an instantiation captured, which
is exactly ADR-0219's retire-instead-of-free condition; `wasm_store_delete`
frees `retired_wasi_hosts` after the instance and zombie cascade. The
corollary is the rule at the write sites: recording a host that was *not*
captured is the one thing that could dangle, which is why the condition is the
flag.

**Over-marking is harmless here and is left in place.** `wasi_host_captured`
is sticky across instances, so an instance with no WASI imports, built in a
Store where another instance captured the host, records it too. That host is
retained by definition, and such an instance cannot record a status — its calls
only clear one. Same posture as ADR-0219's over-mark, for the same reason.

**A start-function `proc_exit` stays readable.** `(start)` runs during
`wasm_instance_new`, not through `wasm_func_call`. Setting `active_wasi_host`
at capture time — before `jit.runStart()` and before the interp start block —
preserves behaviour that has always worked; recording only in `wasm_func_call`
would have dropped it silently.

**The read window closes at the next instantiation, not only at the next
call.** Writing `active_wasi_host` at capture time is what keeps a `(start)`'s
`proc_exit` readable — a `(start)` runs inside `wasm_instance_new`, never
through `wasm_func_call`. That makes instantiation a read point of its own, so
it has to invalidate the previous status exactly as a call does, and it clears
the host it is making active before running the start function.

Clearing unconditionally rather than only when the config moved is what makes
the rule statable. Without it, `wasm_instance_new` invalidates the status when
`zwasm_store_set_wasi` happened to move the setup and preserves it when it did
not, and two readings measured on `62d9452d5` and unchanged by the addressing
fix alone are wrong: a second guest built on the SAME config leaves the first
guest's status readable as if it were the new one's, and a `(start)` that faults
WITHOUT calling `proc_exit` reads back as the earlier guest's exit. The second
is #341's exact failure shape at the read point this decision introduces.

The cost is that a status left unread across `wasm_func_call` →
`wasm_instance_new` is gone. It is accepted: the alternative — not writing at
capture time — trades it for silently dropping the start-function status, which
is the worse failure because nothing signals it. What moves instead is the rule
`include/wasi.h` states, which now names both events: "read it before calling
into the Store again, or creating another instance in it — either one clears
it." Two regression cases pin it, because no other case in that file asks a
Store anything after building a second instance.

**Trap classification is untouched, and measured to be.**
`ZWASM_TRAP_WASI_EXIT` is raised from the engine's own unwind —
`error.WasiExit` from the interp thunk, kind 18 from `src/wasi/jit_dispatch.zig`
— and `src/api/trap_surface.zig:152` / `:189` map both without reading
`host.exit_code`. The kind therefore survives a swap that the status did not:
measured on `b3d031525` as `kind=18` for control, replaced and detached alike,
on all three engines (#350). This is the boundary of the change — nothing about
how a `proc_exit` trap is recognised had to move, only which host the read and
the clear address.

**A cross-module call still writes a host this record does not name.** When an
instance imports another instance's export, dispatch enters the SOURCE
instance's body with the SOURCE instance's WASI binding, so `proc_exit` writes
the host that instance captured while the record names the called instance's.
Measured on `interp`, identical before and after this change (`auto` and `jit`
cannot instantiate a cross-module func import at all). It is #352, not this
decision: keying on the called instance is right for every call that does not
leave it, and following the executing runtime instead is a different mechanism
with its own question.

**`src/cli/run.zig`'s divergence was unreachable and is fixed anyway.** The CLI
installs one config and never swaps, so the two addressings agreed there. It is
changed because #345 is itself a case of an addressing that looked unreachable
until someone reconfigured a Store, and because a second reader keyed on
`wasi_host` is how the halves drifted apart to begin with.

**#344 is not closed by this and is not touched.** The component guards
(`component_wasi_p2.zig:1995`, `component_wasi_p3.zig:184`) read
`built.ctx.host.exit_code` on a host their caller handed them, reached through
`Instance.invoke`, never through `wasm_func_call` or a Store. This decision
adds state to `Store` and a hook to `wasm_func_call`; the component path has
neither. Its own question — whether to clear per run or to key the guards on
something else — is untouched and stays open.

**`src/zwasm/linker.zig` records nothing.** It binds its own host and never
writes `store.wasi_host` or the flag (`linker.zig:592-598`), so a
Linker-built instance leaves `active_wasi_host` alone. Correct: its host was
never the Store's, and this accessor was never the way to read it.

**Not verified on macOS or Windows before merge.** The evidence above is
x86_64-linux. Nothing in the change is platform-specific — it is pointer
bookkeeping on structs that already exist — so the 3-OS `ci-required` gate is
the first and sufficient check there.

## References

- Issues #345 and #350 (the same defect, filed twice).
- ADR-0219 — the retire-instead-of-free rule that makes a captured host
  readable after the swap, and the source of the `wasi_host_captured`
  condition this decision keys on.
- #341 (`62d9452d5`) — the per-call clear this extends; it aimed at the
  installed host, and now aims at the captured one.
- #344 — the third reader of `host.exit_code`, on the component path, out of
  scope here.
- #352 — a `proc_exit` reached through a cross-module func import writes the
  SOURCE instance's host, so the guest that exits is not the called instance
  this decision keys on. Measured identical before and after, on `interp`;
  fixing it needs the record to follow the runtime that runs `proc_exit`.
- #348 — `wasi.h`'s "do not branch on the trap kind" paragraph, stale since
  #331. Untouched here; the read-window consequence above is what gives it a
  cost, and is recorded on that issue.
- `test/c_api_conformance/wasi_exit_code.c` — three regression cases, one per
  way the config can move on, asserting the code on auto / jit / interp, plus
  two pinning where the read window closes and what instantiation clears.
