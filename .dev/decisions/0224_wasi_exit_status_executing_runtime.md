# 0224 — The WASI exit status is read from the host that was written, not from an addressed one

- **Status**: Proposed
- **Date**: 2026-08-29
- **Author**: Junji Takakura
- **Tags**: c-abi, wasi, store, exit-status

## Context

ADR-0222 made `zwasm_store_wasi_exit_code` resolve through
`Store.active_wasi_host` — the WASI host the *called* instance captured. That
is the right host for every call that stays inside the instance it entered, and
ADR-0222 recorded the case where it is not: an instance that imports another
instance's export runs the SOURCE instance's body with the SOURCE instance's
WASI binding, so `proc_exit` writes the host that instance captured while the
record names the called one.

The decision this replaces is not wrong. Its granularity is: it keys on the
instance that was called, and the thing that writes the status is the runtime
that ran `proc_exit`.

Measured on `3583e2db1`, x86_64-linux, through the C ABI. One Store; `I1`
built under config A exits 7; the config moves on; `I2` is built under config B,
reaches into `I1`, and is called. Expected `code=7`.

| how `I2` reaches `I1` | dispatch site | before | after |
|---|---|---|---|
| `call` on an imported func | `src/api/cross_module.zig:53` | `has_code=0` | `code=7` |
| `call_indirect` on an imported table | `src/interp/mvp.zig:518` | `has_code=0` | `code=7` |

The second row is why this is not a wiring change to
`cross_module.CallCtx`. That path carries `source_rt` and could be made to
retarget the record; the table path carries no `CallCtx`, has no Store in
scope, and is a different function. Reading `src/interp/mvp.zig`, they are two
of **seven** places where interp dispatch enters another instance's guest code:

| site | shape |
|---|---|
| `src/api/cross_module.zig:53` | `call` → imported func's body |
| `src/interp/mvp.zig:507` | `call_indirect` → foreign instance's own import thunk |
| `src/interp/mvp.zig:518` | `call_indirect` → foreign body |
| `src/interp/mvp.zig:568` | `call_ref` → foreign instance's own import thunk |
| `src/interp/mvp.zig:577` | `call_ref` → foreign body |
| `src/interp/mvp.zig:675` | `return_call_ref` → foreign instance's own import thunk |
| `src/interp/mvp.zig:655`, `:717` | `return_call_ref` / `return_call_indirect` → foreign body |

Two are measured; the other five are the same branch in a sibling handler. The
count is the point: any decision that repairs the record AT the dispatch site
has to be re-applied at each of them, and at the next one added. ADR-0222 has
already recorded what that costs — "a second reader keyed on `wasi_host` is how
the halves drifted apart to begin with".

`auto` and `jit` cannot instantiate the caller in either shape: `buildBindings`
resolves a cross-module import through the source instance's interpreter
runtime (`src/api/instance.zig:576`) and a JIT-backed instance has none
(ADR-0200). The defect is therefore unreachable on those engines today. That is
a separate defect with its own fix and is **not** addressed here; the
regression cases report it rather than skipping it, and assert in full the
moment the instantiation starts succeeding.

## Decision

**The status is read from whichever of this Store's WASI hosts a `proc_exit`
actually wrote. Nothing addresses a host in advance.**

The Store's set of hosts is closed and already materialised: `Store.wasi_host`
plus `Store.retired_wasi_hosts`. Every host an instance in this Store can write
came from `Store.wasi_host` at capture time, and `zwasm_store_set_wasi` either
retires it onto that list (captured) or frees it (never captured — so nothing
can write it). `wasm_store_delete` already walks exactly this set.

Three rules, one per role:

- **Write — unchanged.** `src/wasi/proc.zig:62` stays the single place a
  guest's exit status is recorded, on the host the executing runtime holds.
  Both engines reach it: the interp thunk (`src/api/wasi.zig:191`) and the JIT
  stub (`src/wasi/jit_dispatch.zig:335`) call the same `procExit`.
- **Clear.** Any Store-mediated entry into guest code clears `exit_code` on
  every host in the set on the way in; a *nested* one also clears on the way
  out. `Store.wasi_call_depth` is what "nested" means, and keeps its ADR-0222
  role.
- **Read.** `activeWasiHost` becomes a scan of the set for the one host
  carrying an `exit_code`. `zwasm_store_wasi_exit_code` and
  `src/cli/run.zig`'s trap-vs-exit branch keep going through it, so the two
  readers still cannot drift.

`Store.active_wasi_host` and `Instance.wasi_host` are removed, along with the
capture-time recording at `src/api/instance.zig:835-841`, `:1133-1139` and
`:2126-2127`. They existed only to name a host in advance, which is the part
that was too coarse. The signature does not change.

**At most one host in the set carries a code at any read point.** A `proc_exit`
unwinds the whole call, so the guest that wrote one cannot run again and no
second write can follow it inside that call. The one way two could coexist is a
host callback that makes a nested `wasm_func_call`, swallows the trap its guest
raised, and returns to an outer guest that then exits on a different host —
which is what the clear-on-the-way-out of a nested entry removes. It is safe to
clear there because the outer guest cannot already hold a status: if it had
exited, the callback would never have run.

`include/wasi.h` states the read rule without naming an instance: the status is
whichever exit this Store's last call or instantiation produced, and the
embedder does not have to know which of its setups the guest reached.

## Alternatives considered

**Retarget `Store.active_wasi_host` at the cross-module dispatch point.** The
obvious fix: `cross_module.CallCtx` already carries `source_rt`, so the thunk
could point the record at the source instance's host and restore it on a normal
return. Rejected on the measurement above — it repairs one of seven sites, and
the `call_indirect` case stays red. The five unmeasured siblings would each
need the same three lines, in a Zone (`src/interp/`) that has no Store; getting
it there means a back-pointer on `Runtime` and the rule restated at every
dispatch handler. A rule that has to be restated per site is the failure mode
ADR-0222 already paid for once.

**Carry the host on the trap, and resolve the accessor through it.** Rejected.
By the time a trap object exists the identity is gone: the interp unwinds with
a bare `error.WasiExit` and the JIT with `trap_kind = 18`, neither of which
carries a pointer. Putting one there means threading a host through
`invokeCrossRuntime`'s error path and through the JIT's trap fields — the same
per-site enumeration as above, in a second place. It also does not reach the
readers: both `zwasm_store_wasi_exit_code` and `src/cli/run.zig:653` are handed
a Store, not a trap, and `src/cli/run.zig` has no trap object in scope at all.

**Make the accessor instance-scoped.** Rejected again, and now for a third
reason on top of ADR-0222's two: the instance the embedder holds is `I2`, and
`I2` is precisely the instance that did not exit. An instance-scoped accessor
would make the caller name the wrong instance by construction.

**Keep `active_wasi_host` and fall back to a scan when it carries no code.**
Rejected. Two resolution rules where one suffices, and the fallback fires in
exactly the case the primary rule gets wrong — so the primary rule is never
load-bearing and only obscures which one answered.

## Consequences

**The record stops modelling which instance was called.** What the Store keeps
is "clear before running", which is engine-independent, dispatch-independent,
and does not grow a case when a new cross-instance dispatch shape is added.
That is the whole reason to prefer it: the seven sites in the census need no
knowledge of the status at all.

**Reading a retired host stays safe by construction**, for ADR-0219's reason
unchanged: the set is `wasi_host` plus `retired_wasi_hosts`, and
`wasm_store_delete` frees the latter after the instance and zombie cascade.
This decision reads more of that list than ADR-0222 did but adds nothing to it.

**The clear and the read are O(number of setups this Store has held).** One for
an embedder that installs a config and leaves it, one more per
`zwasm_store_set_wasi` that displaced a captured host. It is the same list
`wasm_store_delete` already walks, and the work is a null store and a null
compare per entry. An embedder that swaps configs in a loop without deleting
the Store pays for it on every call; recorded because nothing else in the C
surface has a per-call cost that grows with embedder history.

**The read window is unchanged.** `zwasm_store_set_wasi` still does not clear,
so a status the embedder has not read yet survives a bare swap; the next call
or instantiation still closes the window, because both still clear. ADR-0222's
two regression cases pin that and keep passing unmodified.

**Trap classification is untouched.** `ZWASM_TRAP_WASI_EXIT` comes from the
engine's own unwind and never reads `host.exit_code`
(`src/api/trap_surface.zig:152` / `:189`). This decision moves only which host
the read and the clear reach.

**`src/zwasm/linker.zig` still records nothing, and now for a stated reason.**
Its host is bound directly (`linker.zig:592-608`) and never becomes
`store.wasi_host`, so it is not in the set and the accessor does not see it.
Same answer as ADR-0222 gave, arrived at by the set membership rather than by a
flag that happened not to be written.

**#344 is still not closed and still not touched.** The component guards
(`component_wasi_p2.zig:1995`, `component_wasi_p3.zig:184`) read
`built.ctx.host.exit_code` on a host their caller handed them, reached through
`Instance.invoke` and never through a Store. Neither the clear nor the read
here is on that path. Its own question stays open.

**AOT is unreachable from this defect and is left alone.** The AOT run path
(`src/engine/runner.zig:379` / `:482` / `:703`) sets one `wasi_host` on one
runtime per run and is not Store-mediated; and the cross-module import that
produces the mismatch cannot be built on a JIT-backed instance at all, which is
what AOT loads.

**Not verified on macOS or Windows before merge.** The evidence above is
x86_64-linux — `zig build test-all` and `test-c-api-conformance` green in Debug
and `test` / `test-c-api-conformance` green in ReleaseSafe, on that host only. The change is pointer bookkeeping on structs that already exist,
with no platform-conditional code, so the 3-OS `ci-required` gate is the first
and sufficient check there.

## References

- Issue #352 — the report, and the two questions it left open: whether the
  record should move at all, and whether the accessor should resolve through
  the trap instead. Both are answered above: it should not move, and it should
  not.
- ADR-0222 — the addressing this replaces. Its consequence
  "a cross-module call still writes a host this record does not name" is the
  defect; the decision itself stands, at a granularity that turned out to be
  one level too coarse.
- ADR-0219 — the retire-instead-of-free rule that makes the Store's host set
  closed, which is what this decision resolves through.
- ADR-0200 — why a JIT-backed instance has no interpreter runtime, hence why
  `auto` / `jit` cannot build the caller and are unmeasured here.
- #344 — the third reader of `host.exit_code`, on the component path, out of
  scope.
- `test/c_api_conformance/wasi_exit_code.c` — two regression cases, one per
  dispatch shape, asserting the code (not `has_code`) on auto / jit / interp,
  alongside ADR-0222's five.
