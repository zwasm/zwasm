/* zwasm v2 — C-API conformance: a host callback's payload belongs to the
 * STORE, which reaps it exactly once whether or not the embedder ever deleted
 * the handle (#439).
 *
 *   h:     a `wasm_func_new_with_env` callback (i32) -> (i32), returns arg + env
 *   guest: (module (import "h" "cb" (func $cb (param i32) (result i32)))
 *                  (func (export "test") (result i32) (i32.const 5) (call $cb)))
 *
 * Upstream `wasm.h` declares `wasm_func_t` through `WASM_DECLARE_REF`: the
 * handle is a REFERENCE, and the function instance behind it belongs to the
 * store. An import binding made from that handle keeps only the payload's raw
 * address — the interp in `host_calls[i].ctx`, the JIT in `host_payloads[]` —
 * and nothing counts those takers, so freeing the payload in
 * `wasm_func_delete` left a live instance calling into released memory and ran
 * the embedder's finalizer while the callback was still reachable.
 *
 * The finalizer is the witness throughout: it must not run while the callback
 * is still reachable, and `wasm_store_delete` must run it exactly once — not
 * zero, which leaks the payload, and not twice. The env is a distinctive
 * addend the callback adds, so an answer computed out of a released payload is
 * not the right answer.
 *
 * BOTH teardown orderings are measured, because the store's bookkeeping is
 * what has to be indifferent to them:
 *
 *   A. handle deleted first — import the callback, `wasm_func_delete` the
 *      HANDLE while the instance lives, call the guest export again (that
 *      sequence is the original defect's own), then delete the store.
 *   B. handle never deleted — import the callback, call the export, drop the
 *      exports vector / instance / module, and delete the STORE with the
 *      handle still live. Nothing but the store's own registry can reach the
 *      payload here, so a registration made only at `wasm_func_delete` would
 *      never run the finalizer at all.
 *
 * Run on `auto`, `jit` and `interp`: the two engines park the payload's
 * address in different places, so the reap is only established for the engine
 * measured. Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (import "h" "cb" (func (param i32) (result i32)))
 *         (func (export "test") (result i32) (i32.const 5) (call 0))) */
static const uint8_t kGuestWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0a, 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f, /* (i32)->(i32), ()->(i32) */
    0x02, 0x08, 0x01, 0x01, 0x68, 0x02, 0x63, 0x62, 0x00, 0x00, /* import h.cb : type 0 */
    0x03, 0x02, 0x01, 0x01,                                     /* func[1]: type 1 */
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x01, /* export "test" -> 1 */
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x05, 0x10, 0x00, 0x0b, /* body: i32.const 5; call 0 */
};

static const uint8_t kEngines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };

static const char* engine_name(uint8_t kind) {
    switch (kind) {
        case ZWASM_ENGINE_JIT: return "jit";
        case ZWASM_ENGINE_INTERP: return "interp";
        default: return "auto";
    }
}

enum { kAddend = 24301, kExpected = 5 + kAddend };

/* The callback's env. File-scope so the finalizer can tell its own payload
 * from any other, and so it outlives every handle in the case. */
static int32_t g_env_addend = kAddend;
static int g_finalizer_calls = 0;
static int g_finalizer_env_wrong = 0;

static wasm_trap_t* add_env(void* env, const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    results->data[0].kind = WASM_I32;
    results->data[0].of.i32 = args->data[0].of.i32 + *(const int32_t*) env;
    return NULL;
}

static void count_finalize(void* env) {
    if (env != &g_env_addend) g_finalizer_env_wrong = 1;
    g_finalizer_calls++;
}

/* `test` takes nothing and returns what the callback made of its 5. */
static int call_reaches_callback(wasm_extern_t* test_export, const char* who, const char* when) {
    wasm_val_t results[1] = { { WASM_I32, { 0 } } };
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t res = { 1, results };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(test_export), &no_args, &res);
    if (trap) {
        fprintf(stderr, "[%s] the guest call %s trapped\n", who, when);
        wasm_trap_delete(trap);
        return 1;
    }
    if (results[0].kind != WASM_I32 || results[0].of.i32 != kExpected) {
        fprintf(stderr, "[%s] the guest call %s expected the callback's %d, got kind=%d value=%d\n",
                who, when, (int) kExpected, (int) results[0].kind, (int) results[0].of.i32);
        return 1;
    }
    return 0;
}

static int payload_outlives_handle(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_func_t* host_fn = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    g_finalizer_calls = 0;
    g_finalizer_env_wrong = 0;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_functype_t* ft = wasm_functype_new_1_1(wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32));
    host_fn = wasm_func_new_with_env(store, ft, add_env, &g_env_addend, count_finalize);
    wasm_functype_delete(ft);
    if (!host_fn) { fprintf(stderr, "[%s] wasm_func_new_with_env failed\n", who); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kGuestWasm), (wasm_byte_t*) kGuestWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] the guest failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_func_as_extern(host_fn) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) { fprintf(stderr, "[%s] the guest failed to instantiate\n", who); goto cleanup; }
    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0] ||
        wasm_extern_kind(exports.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] the guest is missing its `test` export\n", who);
        goto cleanup;
    }

    /* 1. the binding reaches the callback and its env. */
    if (call_reaches_callback(exports.data[0], who, "before the handle was deleted") != 0) goto cleanup;

    /* 2. the embedder releases the HANDLE while the instance still holds a
     * binding made from it. The function instance is not the handle, so the
     * finalizer has nothing to say yet. */
    wasm_func_delete(host_fn);
    host_fn = NULL;
    if (g_finalizer_calls != 0) {
        fprintf(stderr, "[%s] wasm_func_delete ran the finalizer %d time(s) while the "
                        "importing instance was still live\n", who, g_finalizer_calls);
        goto cleanup;
    }

    /* 3. and the binding still reaches a live payload — the defect. */
    if (call_reaches_callback(exports.data[0], who, "after the handle was deleted") != 0) goto cleanup;

    /* 4. the store owns the function instance, so its teardown is what reaps
     * the payload: once, after every binding that pointed at it is gone. */
    wasm_extern_vec_delete(&exports);
    exports.data = NULL;
    wasm_instance_delete(instance);
    instance = NULL;
    wasm_module_delete(module);
    module = NULL;
    if (g_finalizer_calls != 0) {
        fprintf(stderr, "[%s] the finalizer ran %d time(s) before wasm_store_delete\n",
                who, g_finalizer_calls);
        goto cleanup;
    }
    wasm_store_delete(store);
    store = NULL;
    if (g_finalizer_calls != 1) {
        fprintf(stderr, "[%s] wasm_store_delete ran the finalizer %d time(s), expected exactly 1\n",
                who, g_finalizer_calls);
        goto cleanup;
    }
    if (g_finalizer_env_wrong) {
        fprintf(stderr, "[%s] the finalizer was handed an env that is not the callback's\n", who);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (host_fn) wasm_func_delete(host_fn);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* Ordering B: the embedder never calls `wasm_func_delete`. The store is the
 * only thing left that knows the payload exists, so its teardown is the only
 * place the finalizer can run — and it still has to run exactly once. */
static int store_reaps_undeleted_handle(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_func_t* host_fn = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    g_finalizer_calls = 0;
    g_finalizer_env_wrong = 0;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_functype_t* ft = wasm_functype_new_1_1(wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32));
    host_fn = wasm_func_new_with_env(store, ft, add_env, &g_env_addend, count_finalize);
    wasm_functype_delete(ft);
    if (!host_fn) { fprintf(stderr, "[%s] wasm_func_new_with_env failed\n", who); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kGuestWasm), (wasm_byte_t*) kGuestWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] the guest failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_func_as_extern(host_fn) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) { fprintf(stderr, "[%s] the guest failed to instantiate\n", who); goto cleanup; }
    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0] ||
        wasm_extern_kind(exports.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] the guest is missing its `test` export\n", who);
        goto cleanup;
    }

    /* 1. the binding reaches the callback and its env. */
    if (call_reaches_callback(exports.data[0], who, "with the handle still held") != 0) goto cleanup;

    /* 2. everything the embedder built on top of the callback goes away — but
     * not the handle itself, which it simply keeps. Nothing here owns the
     * payload, so nothing here may finalize it. */
    wasm_extern_vec_delete(&exports);
    exports.data = NULL;
    wasm_instance_delete(instance);
    instance = NULL;
    wasm_module_delete(module);
    module = NULL;
    if (g_finalizer_calls != 0) {
        fprintf(stderr, "[%s] the finalizer ran %d time(s) before wasm_store_delete, with the "
                        "handle never deleted\n", who, g_finalizer_calls);
        goto cleanup;
    }

    /* 3. the store is torn down around the live handle. The payload was the
     * store's from the moment it was made, so this reaps it — exactly once.
     * A payload registered only by `wasm_func_delete` would be reaped zero
     * times here and its finalizer would never run. */
    host_fn = NULL; /* the store's teardown reclaims it; the handle is stale after. */
    wasm_store_delete(store);
    store = NULL;
    if (g_finalizer_calls != 1) {
        fprintf(stderr, "[%s] wasm_store_delete ran the finalizer %d time(s) for a handle the "
                        "embedder never deleted, expected exactly 1\n", who, g_finalizer_calls);
        goto cleanup;
    }
    if (g_finalizer_env_wrong) {
        fprintf(stderr, "[%s] the finalizer was handed an env that is not the callback's\n", who);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (host_fn) wasm_func_delete(host_fn);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    for (size_t i = 0; i < sizeof(kEngines) / sizeof(kEngines[0]); i++) {
        if (payload_outlives_handle(kEngines[i]) != 0) return 1;
        if (store_reaps_undeleted_handle(kEngines[i]) != 0) return 1;
    }
    return 0;
}
