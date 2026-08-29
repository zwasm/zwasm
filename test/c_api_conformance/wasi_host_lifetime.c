/* zwasm v2 — a WASI host outlives the instances that captured it.
 *
 * `zwasm_store_set_wasi` takes ownership of a config. Calling it a second
 * time therefore has to decide what happens to the first one, and an
 * instance created in between is the case that decides it: instantiation
 * bakes the host's address into the instance (the interpreter stores it as
 * each `wasi_snapshot_preview1` import's context; the JIT stores it on the
 * runtime the compiled body reads). Freeing the config out from under that
 * instance leaves the guest calling into released memory.
 *
 * The check below never reads released memory itself. It stages the
 * allocator instead: right after the second `zwasm_store_set_wasi`, it
 * creates fresh configs of its own, one of which lands on the block a
 * released host would have vacated. Then it runs a guest whose only act is
 * `proc_exit(42)` — a single store into `exit_code`. A config that we own
 * and that no guest has ever run against must not report an exit status.
 * If one does, the guest wrote through a dangling pointer into it.
 *
 * The staging is the one soft spot: an allocator that does not hand the
 * released block back to the next same-sized request would let this pass
 * without proving anything. It cannot report a false failure, though — the
 * probes are reachable only through the dangling pointer.
 *
 * Both engines are covered because they capture the host separately, and
 * both `set_wasi(store, cfg2)` and `set_wasi(store, NULL)` are covered
 * because both release the previous host.
 *
 * Run by `test-c-api-conformance`.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

#include <wasm.h>
#include <wasi.h>
#include <zwasm.h>

/* (module
 *   (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
 *   (func (export "_start") (call $exit (i32.const 42)))) */
static const uint8_t kExitWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00,
    0x02, 0x24, 0x01,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31,
    0x09, 0x70, 0x72, 0x6f, 0x63, 0x5f, 0x65, 0x78, 0x69, 0x74,
    0x00, 0x00,
    0x03, 0x02, 0x01, 0x01,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x01,
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x2a, 0x10, 0x00, 0x0b,
};

/* Enough probes that the released block is covered even if the allocator
 * serves a couple of other same-sized requests first. */
#define kProbes 4

static const uint8_t kEngines[] = { ZWASM_ENGINE_INTERP, ZWASM_ENGINE_JIT };

static const char* engine_name(uint8_t kind) {
    return kind == ZWASM_ENGINE_JIT ? "jit" : "interp";
}

/* `set_wasi(A)` → instantiate → `set_wasi(B or NULL)` → run the guest.
 * Returns 0 when no probe config saw the guest's write. */
static int run_case(uint8_t engine, bool detach) {
    const char* what = detach ? "set_wasi(NULL)" : "set_wasi(cfg2)";
    int rc = 1;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_store_t* probe_stores[kProbes] = { NULL };
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    zwasm_wasi_config_t* first = zwasm_wasi_config_new();
    if (!first) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, first); /* takes ownership */

    wasm_byte_vec_t binary = { sizeof(kExitWasm), (wasm_byte_t*) kExitWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) { fputs("zwasm_instance_new_ex failed\n", stderr); goto cleanup; }

    /* Built before the swap so their allocations cannot compete for the
     * block the swap releases. */
    for (size_t i = 0; i < kProbes; i++) {
        probe_stores[i] = wasm_store_new(eng);
        if (!probe_stores[i]) { fputs("probe store new failed\n", stderr); goto cleanup; }
    }

    /* The swap. `first` is now unreachable from C, but the instance above
     * still holds its address. */
    if (detach) {
        zwasm_store_set_wasi(store, NULL);
    } else {
        zwasm_wasi_config_t* second = zwasm_wasi_config_new();
        if (!second) { fputs("wasi config new failed\n", stderr); goto cleanup; }
        zwasm_store_set_wasi(store, second);
    }

    for (size_t i = 0; i < kProbes; i++) {
        zwasm_wasi_config_t* probe = zwasm_wasi_config_new();
        if (!probe) { fputs("probe config new failed\n", stderr); goto cleanup; }
        zwasm_store_set_wasi(probe_stores[i], probe);
    }

    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0] || wasm_extern_kind(exports.data[0]) != WASM_EXTERN_FUNC) {
        fputs("missing _start export\n", stderr);
        goto cleanup;
    }
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t no_res = { 0, NULL };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(exports.data[0]), &no_args, &no_res);
    if (!trap) {
        fprintf(stderr, "[%s] %s: proc_exit did not trap, so the guest never called the host\n",
                engine_name(engine), what);
        goto cleanup;
    }
    wasm_trap_delete(trap);

    rc = 0;
    for (size_t i = 0; i < kProbes; i++) {
        uint32_t code = 0;
        if (zwasm_store_wasi_exit_code(probe_stores[i], &code)) {
            fprintf(stderr,
                    "[%s] %s: probe config %zu reports exit status %u — the guest wrote "
                    "into a host released out from under its instance\n",
                    engine_name(engine), what, i, code);
            rc = 1;
        }
    }

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    for (size_t i = 0; i < kProbes; i++) {
        if (probe_stores[i]) wasm_store_delete(probe_stores[i]);
    }
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* Nothing captured the host, so releasing it right away stays correct:
 * a swap before any instantiation must not retain the first config. */
static int run_uncaptured(void) {
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); return 1; }
    for (int i = 0; i < 3; i++) {
        zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
        if (!cfg) { fputs("wasi config new failed\n", stderr); return 1; }
        zwasm_store_set_wasi(store, cfg);
    }
    zwasm_store_set_wasi(store, NULL);
    wasm_store_delete(store);
    wasm_engine_delete(eng);
    return 0;
}

int main(void) {
    for (size_t i = 0; i < sizeof(kEngines) / sizeof(kEngines[0]); i++) {
        if (run_case(kEngines[i], false)) return 1;
        if (run_case(kEngines[i], true)) return 1;
    }
    if (run_uncaptured()) return 1;
    puts("zwasm c_api_conformance/wasi_host_lifetime: a captured WASI host outlives its instances");
    return 0;
}
