/* zwasm v2 — C-API conformance: a `wasi_snapshot_preview1` import binds the
 * extern the embedder supplies, on both engines (#488).
 *
 * wasm-c-api's import vector is positional and the module name is data, so a
 * slot the embedder fills binds whatever its import is called. Only a NULL slot
 * is the store's WASI host's to serve. Before #488 the interpreter never read
 * the slot of a preview1 import — a module with one `fd_write` import and no
 * WASI host was NULL with no trap, with the embedder's function sitting in the
 * vector — while the JIT read it only for fields `jit_dispatch` does not
 * implement.
 *
 *   guest:   (module (import "wasi_snapshot_preview1" "fd_write"
 *                      (func $f (param i32 i32 i32 i32) (result i32)))
 *                    (memory (export "memory") 1)
 *                    (func (export "run") (result i32)
 *                      (call $f (i32.const 1) (i32.const 0) (i32.const 0) (i32.const 8))))
 *   unknown: the same, importing `nonexistent` instead of `fd_write`
 *
 * Per engine (JIT and INTERP, forced, so neither answer is the other's fallback):
 *   1. the embedder's function in the slot, no host  → instantiates; run() is
 *      the function's 7 and its env counts one call
 *   2. NULL slot, host configured                    → instantiates; run() is
 *      the host's fd_write of zero iovecs, errno 0
 *   3. NULL slot, no host                            → what each engine did
 *      before: the interpreter refuses (NULL, no trap), the JIT plants a stub
 *   4. a function from ANOTHER store in the slot     → NULL with a
 *      BINDING_ERROR trap: a supplied slot is under the store rule (#436)
 *   5. an unknown field with the embedder's function → instantiates; run() is 7
 *
 * Run by `test-c-api-conformance`. Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>
#include <wasi.h>
#include <zwasm.h>

static const uint8_t kFdWriteGuest[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0d, 0x02, 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f,
    0x60, 0x00, 0x01, 0x7f,                                     /* (i32 i32 i32 i32)->(i32), ()->(i32) */
    0x02, 0x23, 0x01,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68,
    0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31,
    0x08, 0x66, 0x64, 0x5f, 0x77, 0x72, 0x69, 0x74, 0x65, 0x00, 0x00, /* import wasi_snapshot_preview1.fd_write */
    0x03, 0x02, 0x01, 0x01,                                     /* func[1]: type 1 */
    0x05, 0x03, 0x01, 0x00, 0x01,                               /* memory 0: min 1 */
    0x07, 0x10, 0x02, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,
    0x03, 0x72, 0x75, 0x6e, 0x00, 0x01,                         /* export "memory" -> mem 0, "run" -> 1 */
    0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x41, 0x01, 0x41, 0x00, 0x41, 0x00, 0x41, 0x08,
    0x10, 0x00, 0x0b,                                           /* body: call 0 (1, 0, 0, 8) */
};

static const uint8_t kUnknownFieldGuest[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0d, 0x02, 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f,
    0x60, 0x00, 0x01, 0x7f,
    0x02, 0x26, 0x01,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68,
    0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31,
    0x0b, 0x6e, 0x6f, 0x6e, 0x65, 0x78, 0x69, 0x73, 0x74, 0x65, 0x6e, 0x74,
    0x00, 0x00,                                                 /* import wasi_snapshot_preview1.nonexistent */
    0x03, 0x02, 0x01, 0x01,
    0x05, 0x03, 0x01, 0x00, 0x01,
    0x07, 0x10, 0x02, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,
    0x03, 0x72, 0x75, 0x6e, 0x00, 0x01,
    0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x41, 0x01, 0x41, 0x00, 0x41, 0x00, 0x41, 0x08,
    0x10, 0x00, 0x0b,
};

static const uint8_t kEngines[] = { ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };

static const char* engine_name(uint8_t kind) {
    return kind == ZWASM_ENGINE_JIT ? "jit" : "interp";
}

/* The embedder's stand-in for fd_write: counts the call in its env, answers 7. */
static wasm_trap_t* seven_env(void* env, const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    (void) args;
    *(int32_t*) env += 1;
    results->data[0].kind = WASM_I32;
    results->data[0].of.i32 = 7;
    return NULL;
}

/* (i32 i32 i32 i32) -> (i32); the caller deletes it. */
static wasm_functype_t* fd_write_shape(void) {
    wasm_valtype_t* p[4] = {
        wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32),
        wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32),
    };
    wasm_valtype_t* r[1] = { wasm_valtype_new(WASM_I32) };
    wasm_valtype_vec_t params, results;
    wasm_valtype_vec_new(&params, 4, p);
    wasm_valtype_vec_new(&results, 1, r);
    return wasm_functype_new(&params, &results);
}

/* Calls `run` and returns its i32 through `out`; non-zero when it trapped. */
static int call_run(wasm_instance_t* instance, int32_t* out, const char* who, const char* label) {
    int rc = 1;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_instance_exports(instance, &exports);
    wasm_func_t* run = NULL;
    for (size_t i = 0; i < exports.size; i++) {
        if (exports.data[i] && wasm_extern_kind(exports.data[i]) == WASM_EXTERN_FUNC) run = wasm_extern_as_func(exports.data[i]);
    }
    if (!run) { fprintf(stderr, "[%s] %s: no run export\n", who, label); goto cleanup; }
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_t res_data[1];
    memset(res_data, 0, sizeof(res_data));
    wasm_val_vec_t res = { 1, res_data };
    wasm_trap_t* trap = wasm_func_call(run, &no_args, &res);
    if (trap) {
        fprintf(stderr, "[%s] %s: run() trapped, kind %d\n", who, label, (int) zwasm_trap_kind(trap));
        wasm_trap_delete(trap);
        goto cleanup;
    }
    *out = res_data[0].of.i32;
    rc = 0;
cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    return rc;
}

/* Cases 1 and 5: the embedder's function in the slot, no host. */
static int supplied_extern_binds(uint8_t engine, const uint8_t* guest, size_t guest_len, const char* label) {
    int rc = 1;
    const char* who = engine_name(engine);
    int32_t calls = 0;
    wasm_func_t* host_fn = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_functype_t* ft = fd_write_shape();
    host_fn = wasm_func_new_with_env(store, ft, seven_env, &calls, NULL);
    wasm_functype_delete(ft);
    if (!host_fn) { fprintf(stderr, "[%s] %s: wasm_func_new_with_env failed\n", who, label); goto cleanup; }

    wasm_byte_vec_t binary = { guest_len, (wasm_byte_t*) guest };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] %s: guest failed to parse\n", who, label); goto cleanup; }
    wasm_extern_t* externs[1] = { wasm_func_as_extern(host_fn) };
    wasm_extern_vec_t imports = { 1, externs };
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (!instance) {
        fprintf(stderr, "[%s] %s: the embedder's function in the slot was not bound (NULL, trap kind %d)\n",
                who, label, itrap ? (int) zwasm_trap_kind(itrap) : -1);
        goto cleanup;
    }
    int32_t got = 0;
    if (call_run(instance, &got, who, label) != 0) goto cleanup;
    if (got != 7 || calls != 1) {
        fprintf(stderr, "[%s] %s: run() = %d after %d call(s), expected 7 after 1\n", who, label, (int) got, (int) calls);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (itrap) wasm_trap_delete(itrap);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (host_fn) wasm_func_delete(host_fn);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* Case 2: a NULL slot is the host's. */
static int null_slot_is_served_by_the_host(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
    if (!cfg) { fprintf(stderr, "[%s] wasi config new failed\n", who); goto cleanup; }
    zwasm_wasi_config_inherit_stdio(cfg);
    zwasm_store_set_wasi(store, cfg); /* takes ownership */

    wasm_byte_vec_t binary = { sizeof(kFdWriteGuest), (wasm_byte_t*) kFdWriteGuest };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] guest failed to parse\n", who); goto cleanup; }
    wasm_extern_t* externs[1] = { NULL };
    wasm_extern_vec_t imports = { 1, externs };
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (!instance) {
        fprintf(stderr, "[%s] NULL slot with a host: not instantiated (trap kind %d)\n",
                who, itrap ? (int) zwasm_trap_kind(itrap) : -1);
        goto cleanup;
    }
    int32_t got = -1;
    if (call_run(instance, &got, who, "NULL slot with a host") != 0) goto cleanup;
    if (got != 0) {
        fprintf(stderr, "[%s] NULL slot with a host: fd_write of no iovecs answered errno %d, expected 0\n", who, (int) got);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (itrap) wasm_trap_delete(itrap);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* Case 3: a NULL slot with no host — unchanged per engine. The interpreter
 * has nothing to serve it from and refuses; the JIT plants `jit_dispatch`'s
 * stub, which answers without a host. */
static int null_slot_without_a_host(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kFdWriteGuest), (wasm_byte_t*) kFdWriteGuest };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] guest failed to parse\n", who); goto cleanup; }
    wasm_extern_t* externs[1] = { NULL };
    wasm_extern_vec_t imports = { 1, externs };
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (engine == ZWASM_ENGINE_INTERP) {
        if (instance || itrap) {
            fprintf(stderr, "[%s] NULL slot, no host: expected NULL with no trap, got %s%s\n",
                    who, instance ? "an instance" : "NULL", itrap ? " with a trap" : "");
            goto cleanup;
        }
    } else if (!instance) {
        fprintf(stderr, "[%s] NULL slot, no host: the JIT no longer plants its stub (trap kind %d)\n",
                who, itrap ? (int) zwasm_trap_kind(itrap) : -1);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (itrap) wasm_trap_delete(itrap);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* Case 4: a supplied slot is under the store rule (#436) like any other. */
static int supplied_extern_from_another_store_is_refused(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    int32_t calls = 0;
    wasm_func_t* host_fn = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store_a = eng ? wasm_store_new(eng) : NULL;
    wasm_store_t* store_b = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store_a || !store_b) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_functype_t* ft = fd_write_shape();
    host_fn = wasm_func_new_with_env(store_b, ft, seven_env, &calls, NULL);
    wasm_functype_delete(ft);
    if (!host_fn) { fprintf(stderr, "[%s] wasm_func_new_with_env failed on store B\n", who); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kFdWriteGuest), (wasm_byte_t*) kFdWriteGuest };
    module = wasm_module_new(store_a, &binary);
    if (!module) { fprintf(stderr, "[%s] guest failed to parse\n", who); goto cleanup; }
    wasm_extern_t* externs[1] = { wasm_func_as_extern(host_fn) };
    wasm_extern_vec_t imports = { 1, externs };
    instance = zwasm_instance_new_ex(store_a, module, &imports, &itrap, engine);
    if (instance) { fprintf(stderr, "[%s] a preview1 slot bound a function from another store\n", who); goto cleanup; }
    if (!itrap || zwasm_trap_kind(itrap) != ZWASM_TRAP_BINDING_ERROR) {
        fprintf(stderr, "[%s] another store's function in a preview1 slot: trap kind %d, expected BINDING_ERROR\n",
                who, itrap ? (int) zwasm_trap_kind(itrap) : -1);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (itrap) wasm_trap_delete(itrap);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (host_fn) wasm_func_delete(host_fn);
    if (store_a) wasm_store_delete(store_a);
    if (store_b) wasm_store_delete(store_b);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    for (size_t i = 0; i < sizeof(kEngines) / sizeof(kEngines[0]); i++) {
        if (supplied_extern_binds(kEngines[i], kFdWriteGuest, sizeof(kFdWriteGuest), "fd_write supplied") != 0) return 1;
        if (null_slot_is_served_by_the_host(kEngines[i]) != 0) return 1;
        if (null_slot_without_a_host(kEngines[i]) != 0) return 1;
        if (supplied_extern_from_another_store_is_refused(kEngines[i]) != 0) return 1;
        if (supplied_extern_binds(kEngines[i], kUnknownFieldGuest, sizeof(kUnknownFieldGuest), "nonexistent supplied") != 0) return 1;
    }
    return 0;
}
