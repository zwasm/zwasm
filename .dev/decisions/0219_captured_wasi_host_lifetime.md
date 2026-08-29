# 0219 — A captured WASI host outlives the instances that captured it

- **Status**: Accepted
- **Date**: 2026-08-29
- **Author**: Junji Takakura
- **Tags**: c-abi, wasi, lifetime, store

## Context

`zwasm_store_set_wasi` freed the previously installed host unconditionally,
while instantiation had already recorded that host's address in state that
outlives the call. A C host that installed a config, instantiated, and then
installed a second config left its guest calling into released memory — and
left the preopened directories the guest was still entitled to use already
closed. Issue #314.

Two sites capture the address; measured on `5d56a3991`, and they are all of
them:

| site | what it records | reachable until |
|---|---|---|
| `buildBindings` (`src/api/instance.zig`) | each `wasi_snapshot_preview1` import's `host_call.ctx` | **store teardown** |
| `instantiateJit` (`src/api/instance.zig`) | `jit.owned.rt.wasi_host` | instance delete, or store teardown |

The interp row is the one that decides the shape. `wasm_instance_delete` does
not free the arena the bindings live in — it parks the runtime + arena on
`store.zombies` precisely so the instance's funcs stay callable through
cross-module funcrefs (ADR-0014 §2.1 / 6.K.2 sub-change 4). So "no live
instance" does not mean "no captor", and the last reference dies with the
store, not with the instance.

Paths that do NOT capture the store's host, checked rather than assumed: AOT
(`wasm_module_deserialize` yields an ordinary `Module` and goes through the
same two sites), the component surface (`src/api/component.zig` `open` takes
`host: *wasi_host.Host` as an argument, and that file has no `export fn` at
all), and the Zig facade `Linker`, which owns its own host and says so at
`src/zwasm/linker.zig:594`.

What made this a defect rather than a documented sharp edge: `include/wasi.h`
described the ownership transfer and nothing else. It said neither that a
second call is constrained nor that instantiation records the address. A C
host writing exactly what the header describes hits the use-after-free.

## Decision

**Release stays immediate while nothing has captured the host; a captured
host retires and is freed with the Store.**

`Store` gains `wasi_host_captured: bool`, set at the two sites above, and
`retired_wasi_hosts`, walked and freed by `wasm_store_delete` beside
`wasi_host`. `zwasm_store_set_wasi` frees the displaced host when the flag is
clear and retires it when it is set; installing a host clears the flag.
Passing `null` follows the same rule.

The flag is deliberately never cleared by instance deletion. Clearing it there
would be wrong for the interp row above: the zombie's parked bindings still
name the host.

`include/wasi.h` states both halves — that an instance keeps using the config
that was installed when it was created, and that the config's preopened
directories stay open until the Store is deleted, so a Store that preopens per
run should take a new Store per configuration.

## Alternatives considered

**Defer every host to store teardown.** One line shorter and needs no flag.
Rejected: it retains hosts that no runtime can ever reach. The sequence it
penalises — install a config, notice it is wrong, install a corrected one,
*then* instantiate — is the ordinary one, and it is what
`src/api/instance.zig`'s `zwasm_store_set_wasi(*store, null)` test asserts.
What it retains there is memory, not fds (see Consequences), but it retains
it for nothing and it changes what that test means. One bool buys keeping
both.

**Reference counting.** Correct, and it cannot release any earlier than the
flag does. The last reference in the interp case is held by the parked zombie
arena, which `wasm_store_delete` is the only thing that frees — so a refcount's
release point *is* store teardown, reached through a count on every instance
create/delete plus a drop path in the zombie reaper. Same lifetime, more
machinery. Rejected on that ratio, not on correctness. Worth revisiting only
if the zombie list ever gains a reaper that runs before store teardown.

**Refuse the second call.** `zwasm_store_set_wasi` returns `void`, so there is
no way to report the refusal; adding a return value breaks the ABI. Reporting
it out of band would still leave the C host holding a config it must now free
itself, contradicting the ownership rule the header states, and it would break
callers that legitimately reconfigure before instantiating — the sequence that
works today.

## Consequences

**A retired host holds its preopen directory fds until the Store is deleted.**
Measured on Linux with one `zwasm_wasi_config_preopen_dir` per config, each
swap followed by an instantiation: the retained-fd count tracks the swap count
one for one and returns to baseline at `wasm_store_delete`. One fd per preopen
directory per retired host, linear. The header's "take a new Store per
configuration" is the advice that follows from it, and it is the reason that
advice is in the header rather than only here.

This cost is not what distinguishes the decision from the rejected first
alternative, and the obvious guess about it is wrong: preopens are opened by
`materializePendingPreopens` at instantiation, and instantiation is exactly
what captures. An uncaptured host therefore holds no fds at all, and a config
that never calls `preopen_dir` retires none either way — stdio 0/1/2 are `kind`
tags in the fd table, not host handles.

**The flag over-marks, and nothing compensates for it.** `buildBindings` also
runs on the throwaway arena inside `collectHostFuncTargets`, and
`instantiateJit` sets the flag before `runStart`, which can still fail the
instantiation. Both leave the flag set with no surviving captor. Over-marking
only defers a free; it can never produce a dangling pointer, so the correct
response is to say so at the sites rather than to unwind it.

**An OOM appending to the retire list takes the leak.** `catch {}`, marked
`EXEMPT-FALLBACK`, on the same reasoning and in the same shape as
`parkAsZombie`: a leak at store scope is preferable to a use-after-free.

**The downstream workaround can go.** `zwasm/zwasm-rust-sdk`'s
`Store::set_wasi` and `Store::unset_wasi` refuse after any instantiation, and
the refusal is permanent for the store's life — deliberately blunter than the
defect requires, because the store cannot see an instance's imports. Its own
doc names this issue and says the refusal can go once zwasm defers the free.
It now can. The SDK change is separate work.

**The verification is asymmetric across the OS gate, by construction.** The
direct evidence that a retained host is retained is a descriptor: a released
host closes its preopen directory fd, so the conformance case compares the
descriptor `open` hands out before and after the swap. Nothing about the
allocator enters that check, and it is the only observation that speaks to
this decision directly. Windows has no equivalent — zwasm's directory handles
there are not CRT descriptors — so the Windows leg falls back to the probe
check, whose `recycled` count is structurally `0/64` once the host is retained
and was `0/64` for one of its four cases before the fix as well. The same
number before and after means the Windows leg cannot detect a regression in
this behaviour; Linux and macOS are what guard it. The case does not hide
this: it prints `recycled` per case, and its header states how to read a zero
on each platform. Closing the gap needs a Windows-side equivalent of the
descriptor observation — counting process handles — which is not attempted
here, because an OS-specific path added to the merge gate without a host to
validate it trades a false pass for a false failure.

This asymmetry is deliberately recorded here and not in `.dev/debt.yaml` or as
an issue. The test declares it itself, and a second copy would drift from the
first (ADR-0216).

## References

- Issue #314.
- ADR-0184 — the engine-owned `Host.io` wiring that `zwasm_store_set_wasi`
  performs alongside the release decided here.
- ADR-0014 §2.1 / 6.K.2 sub-change 4 — the zombie list, which is why the
  interp capture outlives its instance.
- `src/runtime/store.zig` — the `wasi_host` / `wasi_host_captured` /
  `retired_wasi_hosts` ownership comments carry the rule at the field.
