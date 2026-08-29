# C API reference (wasm-c-api)

zwasm implements the standard **wasm-c-api** so a C host that drives any
wasm-c-api runtime (wasmtime, wasmer, …) drives zwasm unchanged. Three
headers in [`include/`](../../include/):

| Header                             | Origin                                                           | Status                                                                                                                  |
|------------------------------------|------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
| [`wasm.h`](../../include/wasm.h)   | Upstream `WebAssembly/wasm-c-api`, vendored read-only (ADR-0004) | **Complete** — every declared `extern` function is implemented (293/293; `scripts/capi_surface_gap.sh` enforces gap=0) |
| [`wasi.h`](../../include/wasi.h)   | Hand-authored project extension (ADR-0005)                       | WASI 0.1 host-setup (`zwasm_wasi_config_*`, `zwasm_store_set_wasi`) + the guest's exit status (`zwasm_store_wasi_exit_code`) — no canonical upstream `wasi.h` exists |
| [`zwasm.h`](../../include/zwasm.h) | Hand-authored project extension (ADR-0179 #3a-4)                 | Runtime version (`zwasm_version`) + instance sandboxing setters (fuel / memory cap / interrupt) + `zwasm_trap_kind` + per-instance engine selection (`zwasm_instance_new_ex`) + `zwasm_instance_get_func` — see below |

The header IS the reference — `wasm.h` is the upstream standard
documented at <https://github.com/WebAssembly/wasm-c-api>. This page
maps the families to zwasm specifics.

## Standard surface (`wasm.h`)

Full coverage of the wasm-c-api families:

- **Lifecycle**: `wasm_engine_new` / `wasm_store_new` / `wasm_module_new`
  (parse + validate) / `wasm_module_validate` / `wasm_instance_new` / the
  `_delete` for each.
- **Externals**: `wasm_func_*` (incl. host callbacks + `wasm_func_call`),
  `wasm_global_get`/`_set`, `wasm_table_get`/`_set`/`_grow`/`_size`,
  `wasm_memory_data`/`_size`/`_grow`.
- **Types**: `wasm_*type_*` (functype / globaltype / tabletype / memorytype
  / valtype / externtype / importtype / exporttype) + the tagtype family
  (EH).
- **Values + vectors**: `wasm_val_*`, `wasm_*_vec_new`/`_copy`/`_delete`.
- **Traps + frames**: `wasm_trap_*`, `wasm_frame_*`.
- **Refs + sharing**: `wasm_ref_*` (`_same`/`_as_*`/`_copy`), host_info
  accessors, `wasm_module_serialize`/`_deserialize`/`_share`/`_obtain`.

Residual *semantic* limits (functions exist + behave honestly, not
link-stubbed): `wasm_val` `of.ref` = raw payload (D-269); standalone /
instance / foreign `_copy` → null (D-253-D); `serialize` = source bytes,
no AOT cache (D-271).

## WASI host-setup (`wasi.h`)

A C host that already drives `wasm.h` configures WASI via
`zwasm_wasi_config_new()` → `zwasm_wasi_config_set_args` /
`inherit_stdio` / … → `zwasm_store_set_wasi(store, cfg)` (takes
ownership). See the worked example in
[`include/wasi.h`](../../include/wasi.h) and
[`docs/examples/c_host/`](../examples/c_host/).

**Reading the exit status.** A WASI command ends by calling `proc_exit` —
including when it succeeds, since a `wasi-libc` `_start` that returns normally
calls `proc_exit(0)` — and zwasm surfaces that as a trap. So `wasm_func_call`
alone cannot separate a clean termination from a fault, and
`zwasm_store_wasi_exit_code(store, &out)` is what does:

- trap **and** `true` — the guest terminated itself; `*out` is its status, and
  `0` there means success.
- trap **and** `false` — a genuine fault (unreachable, out of bounds, …).
  `wasm_trap_message` / `zwasm_trap_kind` describe it.

The status is **per call** — each `wasm_func_call` into the Store clears it
before running, so a `true` describes the call just made and never an earlier
guest's (#341). Read it before calling into the Store again, or creating
another instance in it — either one clears it.

Which of a Store's WASI setups a `true` is read from — when it has held more
than one, or had one replaced or detached mid-run — is contract, stated once in
[`include/wasi.h`](../../include/wasi.h) (#345) and not restated here.

`zwasm_trap_kind` answers a different question and does not replace this one:
since ADR-0218 it reports `ZWASM_TRAP_WASI_EXIT` for a `proc_exit` on every
engine, but it never carries the status, which is what an embedder needs.

## `zwasm.h` extensions

**Runtime version.** `zwasm_version()` returns the linked library's semantic
version — `build.zig.zon`'s `.version`, as `MAJOR.MINOR.PATCH` — NUL-terminated
in static storage, never NULL, nothing to free. Semver alone, not build identity: `-Dwasm` / `-Dwasi` / `-Dengine` change
what the library can do, and two builds of one commit differing in all three
return the same string (ADR-0221).

Instance-level budget setters (ADR-0179 #3a-4) mirroring the Zig facade —
post-instantiate and re-armable mid-workload (v1's config-level
`zwasm_config_set_*` shape was deliberately rejected). All null-tolerant.

**Engine selection.** Stock `wasm_instance_new` builds an `.auto`-engine
instance (JIT where supported, interpreter otherwise). To force the engine from
C, use `zwasm_instance_new_ex(store, module, imports, trap_out, engine_kind)`
with `ZWASM_ENGINE_AUTO` / `ZWASM_ENGINE_JIT` / `ZWASM_ENGINE_INTERP`.
`zwasm_instance_get_func(instance, idx)` fetches an export function by index
(caller owns the result → release with `wasm_func_delete`).

| Function                                                            | Effect                                                                                                                                   |
|---------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| `zwasm_instance_set_fuel(i, n)` / `zwasm_instance_disable_fuel(i)`  | deterministic budget; exhaustion traps `all fuel consumed` (kind 17). Interp units = instructions                                        |
| `zwasm_instance_fuel_remaining(i, &out)`                            | remaining budget; returns `false` when unmetered                                                                                         |
| `zwasm_instance_set_memory_pages_limit(i, p)` / `…_clear_…(i)`    | host ceiling below the declared max; `memory.grow` past it returns the spec `-1`                                                         |
| `zwasm_instance_interrupt(i)` / `zwasm_instance_clear_interrupt(i)` | cooperative cancel/timeout from any thread; traps `interrupted` (kind 16) at the next poll                                               |
| `zwasm_trap_kind(trap)`                                             | machine-readable trap kind beside wasm.h's message-only surface (`ZWASM_TRAP_INTERRUPTED`/`ZWASM_TRAP_OUT_OF_FUEL` macros); `-1` on NULL. Host-originated traps are separable from guest faults on every engine — `ZWASM_TRAP_WASI_EXIT` (18) for a `proc_exit`, `ZWASM_TRAP_BINDING_ERROR` (0) for a host callback's own trap (ADR-0218) |

## Not shipped (`zwasm.h` residuals)

Allocator injection and the kind-less `zwasm_func_call_fast` hot path
remain unimplemented (evaluated-on-demand, in keeping with the
lightweight design).
