# 0220 — `wasm_func_call` runs a host func's callback

- **Status**: Accepted
- **Date**: 2026-08-29
- **Author**: Junji Takakura
- **Tags**: c-abi, host-func, trap-surface

## Context

`wasm_func_call` on a func created by `wasm_func_new[_with_env]` returned NULL —
no trap, therefore success — without running the callback and without writing
`results`. The caller read its own uninitialised buffer as a completed call.

Measured on `29026a699`, both directions, through the real C ABI:

| call site | callback runs | `results` written | return |
|---|:-:|:-:|:-:|
| guest `call` through the import (`hostFuncThunk`) | yes | yes | trap or null |
| `wasm_func_call` on the handle | **no** | **no** | **null** |

Nothing at the call site distinguishes the second row from a real success.
`wasm_func_param_arity` / `wasm_func_result_arity` already answer for a host
func (`module_introspect.zig:385`), so an embedder that validates its argument
shape first gets clean answers and then an empty result. wasmtime permits the
direct call, so ported code compiles, runs, and reports success.

`wasm_func_call` has six `return null` exits. Reachability, measured by walking
the construction sites rather than reading the guards:

| # | exit | reachable by valid use |
|---|---|---|
| 1 | `f orelse` | yes — the documented null-argument discipline |
| 2 | `handle.instance orelse` | **yes** — `funcNewImpl` sets `instance = null`; this is the defect |
| 3 | `inst.store orelse` | no — both C-API instance constructors set `.store` non-null and nothing clears it (`.store = null` occurs only in `runtime/instance/instance.zig` unit fixtures) |
| 4 | `storeAllocator(store) orelse` | no — `wasm_store_new` is the only constructor and always sets an engine; nothing clears it |
| 5 | `inst.runtime == null` with no JIT | no — the interp constructor sets `runtime`, the JIT constructor sets `jit`; the one `handle.jit = null` is followed immediately by `destroy(handle)` |
| 6 | `const rt = inst.runtime orelse` | no — dead: the preceding `if (inst.runtime == null)` returns on both arms |

So there is one defect here, not three. Exits 3 and 4 could not return a trap
in any case: they are the steps that *recover* the allocator a trap needs.

The direct path needs no marshalling. The callback's signature takes
`(?*const ValVec, ?*ValVec)` — the types `wasm_func_call` was handed. It also
needs no ownership handling: both sides are the same host, so a ref-kind
`of.ref` is the caller's own pointer, and zwasm neither mints a `*Ref` view for
it nor frees one. That is the opposite of `hostFuncThunk`, whose `of.ref`
comment is about lending a handle *across the guest boundary*; the comment does
not transfer to this path.

## Decision

Invoke the callback. `wasm_func_call` checks `Func.host` before it dereferences
`Func.instance` and, when set, calls the callback with the caller's own vecs.
Two behaviours diverge from `hostFuncThunk` deliberately:

- **The callback's trap is returned unconsumed.** The thunk deletes it and
  raises a guest trap because a guest frame must fault; a direct call has no
  guest, so the caller gets the trap object it would have gotten from any other
  `wasm_func_call`, with the host's own message intact.
- **No ref handle is minted or freed.** See above.

An arity mismatch traps with `binding_error`, matching what the instance path
already does for the same mistake. A null `f` still returns null.

## Alternatives considered

### Alternative A — trap instead of running the callback

Return `binding_error` so the direct call fails loudly, declaring the direct
form out of scope. **Rejected.** It was only worth considering while the fix
looked expensive; the measurement above says it is not — no marshalling, no
ownership transfer, no new state. Trapping would also diverge from wasmtime for
no gain, and the surface wasm-c-api documents is `wasm_func_call(func, …)`, not
`wasm_func_call(export_of_instance, …)`.

### Alternative B — a `zwasm_func_is_host()` capability query

Let the embedder ask whether a handle is directly callable. **Rejected**: it
exports the problem. Every C host would have to learn a zwasm-specific
predicate to avoid a silent wrong answer, and one that forgot would be exactly
where it started. The issue rejects this itself.

## Consequences

- A C host can call a `wasm_func_new` func directly, as under wasmtime.
- No behaviour change for the guest→host direction: `hostFuncThunk` is
  untouched, and its trap-consuming semantics stay as ADR-0218 leaves them.
- `wasm_func_call` no longer reports success for anything reachable. Exits 3–6
  remain as defensive `return null`s: 3 and 4 have no allocator to build a trap
  with, 5 and 6 are unreachable, and none can be triggered from C.
- The direct path allocates only when it traps, so a host func call on the hot
  path costs one branch over calling the C function pointer directly.

## References

- Issue: zwasm/zwasm#315. Deliberately untouched neighbours: zwasm/zwasm#331
  (host-trap classification, ADR-0218), zwasm/zwasm#314 (host lifetime),
  zwasm/zwasm#337 (marshalling-failure kind inside `hostFuncThunk`)
- Related ADRs: ADR-0218 (host-originated trap classification — the guest-side
  twin of this path's trap handling), ADR-0157 (the `handles.zig` carve-out
  that owns `Func.host` / `HostFuncPayload`), ADR-0109 (host-func marshalling),
  ADR-0212 D1 (product semantics require maintainer sign-off)
- Files: `src/api/instance.zig`; tests in `src/api/extern_new.zig` and
  `test/c_api_conformance/host_func_direct_call.c`
