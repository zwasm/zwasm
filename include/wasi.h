/**
 * \file wasi.h
 *
 * zwasm WASI 0.1 host-setup C API (project extension, not
 * upstream-portable).
 *
 * This header is hand-authored — there is no single canonical
 * upstream `wasi.h` for host-side WASI embedding
 * (`WebAssembly/wasm-c-api` does not ship one;
 * runtime-specific `wasi.h`s like wasmtime's depend on
 * runtime-private build-config headers and are not "verbatim
 * vendorable").
 *
 * The functions here let a C host that already drives the
 * standard `wasm.h` surface (`wasm_engine_new` / `_store_new` /
 * `_module_new` / `_instance_new` / `_func_call`) opt-in to
 * WASI 0.1 hosting:
 *
 *   wasm_engine_t* engine = wasm_engine_new();
 *   wasm_store_t*  store  = wasm_store_new(engine);
 *   zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
 *   const char* args[] = { "prog", "--flag" };
 *   zwasm_wasi_config_set_args(cfg, 2, args);
 *   zwasm_wasi_config_inherit_stdio(cfg);
 *   zwasm_store_set_wasi(store, cfg);   // takes ownership of cfg
 *   wasm_instance_t* inst = wasm_instance_new(store, module, NULL, NULL);
 *
 * After `_set_wasi`, modules importing `wasi_snapshot_preview1.*`
 * resolve those imports against the configured host. Without
 * `_set_wasi`, modules that import WASI fail at
 * `wasm_instance_new` with a binding-error trap.
 *
 * Names use the `zwasm_` prefix to signal that these are
 * project extensions, not cross-runtime portable.
 *
 * Implementation lives in `src/wasi/host.zig`.
 */

#ifndef ZWASM_WASI_H
#define ZWASM_WASI_H

#include "wasm.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Opaque WASI host-setup handle. Configured before
 * `wasm_instance_new` consumes a module that imports
 * `wasi_snapshot_preview1.*`; ownership transfers to the Store
 * via `zwasm_store_set_wasi`, after which the C host must NOT
 * call `zwasm_wasi_config_delete` on it.
 */
typedef struct zwasm_wasi_config_t zwasm_wasi_config_t;

WASM_API_EXTERN zwasm_wasi_config_t* zwasm_wasi_config_new(void);
WASM_API_EXTERN void                 zwasm_wasi_config_delete(zwasm_wasi_config_t*);

/**
 * Route the guest's stdin/stdout/stderr (fd 0/1/2) to the host
 * process's stdio. This is the default (`Host.init` installs the
 * three stdio fds), kept for API parity.
 *
 * Process argv inheritance (`inherit_argv`) is not provided:
 * Zig 0.16 offers no library-side cross-platform process-args
 * read. Use the explicit `set_args` below instead.
 */
WASM_API_EXTERN void zwasm_wasi_config_inherit_stdio(zwasm_wasi_config_t*);

/**
 * Snapshot the host process's environment into the config,
 * replacing any previously set envs (same replace semantics as
 * `set_envs`). Later host-process env changes are not reflected.
 * Returns true on success; false on NULL cfg or snapshot failure.
 */
WASM_API_EXTERN bool zwasm_wasi_config_inherit_env(zwasm_wasi_config_t*);

/**
 * Explicit argv / envs override. Each `argv` / `keys` / `vals`
 * array is borrowed for the duration of the call only — the
 * config copies the strings.
 */
WASM_API_EXTERN void zwasm_wasi_config_set_args(
    zwasm_wasi_config_t*,
    size_t argc,
    const char* const* argv);

WASM_API_EXTERN void zwasm_wasi_config_set_envs(
    zwasm_wasi_config_t*,
    size_t count,
    const char* const* keys,
    const char* const* vals);

/**
 * Queue a host directory for preopening: the guest sees
 * `host_path`'s contents under `guest_path` (fd 3, 4, ... in
 * preopen order). Both strings are borrowed for the call only —
 * the config copies them.
 *
 * The directory is opened at `wasm_instance_new` time via the
 * engine-owned io; an unopenable path makes
 * `wasm_instance_new` return NULL. Returns true when queued,
 * false on NULL args or allocation failure.
 */
WASM_API_EXTERN bool zwasm_wasi_config_preopen_dir(
    zwasm_wasi_config_t*,
    const char* host_path,
    const char* guest_path);

/**
 * Install the WASI setup on a Store. Takes ownership of the
 * config — the C host must not call `zwasm_wasi_config_delete`
 * on the same pointer afterwards.
 *
 * Calling twice on the same Store replaces the previous setup.
 * Pass `NULL` to uninstall WASI hosting on a Store.
 *
 * An instance created while a config was installed keeps using
 * THAT config for the rest of its life — instantiation records
 * the config's address. Replacing or removing the config
 * therefore does not free it once any instance has been created
 * since it was installed; it is freed with the Store instead.
 * Directories it preopened stay open until then, so a long-lived
 * Store that preopens per run should take a new Store per
 * configuration rather than re-setting the config.
 */
WASM_API_EXTERN void zwasm_store_set_wasi(wasm_store_t*, zwasm_wasi_config_t*);

/**
 * Read the exit status a guest requested through WASI `proc_exit`
 * into `*out`. Returns true only when this Store has a WASI setup
 * AND the guest actually called `proc_exit`; otherwise returns
 * false and leaves `*out` untouched.
 *
 * How an embedder reads a guest's termination:
 *
 *   - `wasm_func_call` returned a trap and this returns true — the
 *     guest terminated itself and `*out` is its status. This is the
 *     ordinary end of a WASI command, including a successful one: a
 *     `wasi-libc` `_start` that returns normally calls
 *     `proc_exit(0)`, so a status of 0 means success, not failure.
 *   - `wasm_func_call` returned a trap and this returns false — a
 *     genuine fault (unreachable, out of bounds, ...). Report it as
 *     a failure; `wasm_trap_message` and `zwasm_trap_kind` describe
 *     it.
 *
 * Do not branch on the trap kind to tell those two apart. The kind a
 * `proc_exit` trap carries differs between engines and is not part
 * of this contract.
 *
 * The status is per call: each `wasm_func_call` into this Store
 * clears it before running, so a `true` return describes the call
 * you just made, never an earlier guest's. Read it before calling
 * into the Store again.
 */
WASM_API_EXTERN bool zwasm_store_wasi_exit_code(const wasm_store_t*, uint32_t* out);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZWASM_WASI_H
