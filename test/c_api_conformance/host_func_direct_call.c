/* zwasm v2 — C-API conformance: calling a host func directly (#315)
 *
 * `callback.c` covers the guest->host direction: a `wasm_func_new` func
 * passed as an import and reached through the guest's `call`. This covers
 * the direction a C host reaches for when it wants to invoke that same
 * func itself — `wasm_func_call` straight on the handle, no instance in
 * between. wasmtime permits it, so ported code compiles and runs; before
 * #315 zwasm returned NULL (= no trap = success) without running the
 * callback, leaving `results` untouched. That is invisible from the call
 * site, which is why it gets a C-side test and not only a Zig one.
 *
 * Three things are pinned here:
 *   1. the callback actually runs and writes `results`;
 *   2. a trap the callback returns reaches the caller with ITS OWN
 *      message — the direct path does not consume it the way the
 *      guest-boundary thunk does;
 *   3. an arity mismatch traps rather than silently doing nothing.
 *
 * Exits 0 on success.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>

/* host callback: results[0] = args[0] + 1 */
static wasm_trap_t* add_one(const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    results->data[0].kind = WASM_I32;
    results->data[0].of.i32 = args->data[0].of.i32 + 1;
    return NULL;
}

/* host callback with env: results[0] = args[0] + *(int*)env */
static wasm_trap_t* add_env(void* env, const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    results->data[0].kind = WASM_I32;
    results->data[0].of.i32 = args->data[0].of.i32 + *(int32_t*) env;
    return NULL;
}

static const char kRefusal[] = "host refused";
static wasm_store_t* g_store = NULL;

/* host callback that fails: hands back an owned trap of its own making */
static wasm_trap_t* refuse(const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    (void) args;
    (void) results;
    wasm_byte_vec_t msg = { sizeof(kRefusal) - 1, (wasm_byte_t*) kRefusal };
    return wasm_trap_new(g_store, &msg);
}

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    wasm_functype_t* ft_plain = NULL;
    wasm_functype_t* ft_env = NULL;
    wasm_functype_t* ft_refuse = NULL;
    wasm_func_t* plain_fn = NULL;
    wasm_func_t* env_fn = NULL;
    wasm_func_t* refuse_fn = NULL;
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }
    g_store = store;

    ft_plain = wasm_functype_new_1_1(wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32));
    plain_fn = wasm_func_new(store, ft_plain, add_one);
    if (!plain_fn) { fputs("wasm_func_new failed\n", stderr); goto cleanup; }

    /* The arity surface answers for a host func, so an embedder that
     * pre-validates its argument shape gets clean answers here and then
     * an empty result — the reason #315 is invisible from the call site. */
    if (wasm_func_param_arity(plain_fn) != 1 || wasm_func_result_arity(plain_fn) != 1) {
        fputs("host func arity wrong\n", stderr);
        goto cleanup;
    }

    /* 1. the callback runs. Poison `results` first: a silent success
     *    leaves it exactly as it was. */
    wasm_val_t args_data[2] = {
        { .kind = WASM_I32, .of = { .i32 = 41 } },
        { .kind = WASM_I32, .of = { .i32 = 0 } },
    };
    wasm_val_vec_t args = { 1, args_data };
    wasm_val_t results_data[1] = { { .kind = WASM_I32, .of = { .i32 = -12345 } } };
    wasm_val_vec_t results = { 1, results_data };

    wasm_trap_t* trap = wasm_func_call(plain_fn, &args, &results);
    if (trap) { fputs("direct host call trapped\n", stderr); wasm_trap_delete(trap); goto cleanup; }
    if (results_data[0].kind != WASM_I32 || results_data[0].of.i32 != 42) {
        fprintf(stderr, "direct host call: expected 42, got %d\n", results_data[0].of.i32);
        goto cleanup;
    }
    printf("zwasm c_api_conformance/host_func_direct_call: h(41) = %d\n", results_data[0].of.i32);

    /* the _with_env form reaches its env the same way */
    int32_t bump = 10;
    ft_env = wasm_functype_new_1_1(wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32));
    env_fn = wasm_func_new_with_env(store, ft_env, add_env, &bump, NULL);
    if (!env_fn) { fputs("wasm_func_new_with_env failed\n", stderr); goto cleanup; }
    args_data[0].of.i32 = 5;
    results_data[0].of.i32 = -12345;
    trap = wasm_func_call(env_fn, &args, &results);
    if (trap) { fputs("direct env host call trapped\n", stderr); wasm_trap_delete(trap); goto cleanup; }
    if (results_data[0].of.i32 != 15) {
        fprintf(stderr, "direct env host call: expected 15, got %d\n", results_data[0].of.i32);
        goto cleanup;
    }

    /* 2. the callback's own trap reaches the caller, message intact */
    ft_refuse = wasm_functype_new_1_1(wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32));
    refuse_fn = wasm_func_new(store, ft_refuse, refuse);
    if (!refuse_fn) { fputs("wasm_func_new (refuse) failed\n", stderr); goto cleanup; }
    trap = wasm_func_call(refuse_fn, &args, &results);
    if (!trap) { fputs("refusing host callback reported success\n", stderr); goto cleanup; }
    wasm_byte_vec_t msg = { 0, NULL };
    wasm_trap_message(trap, &msg);
    int msg_ok = msg.data && msg.size == sizeof(kRefusal) - 1 &&
                 memcmp(msg.data, kRefusal, msg.size) == 0;
    if (msg.data) wasm_byte_vec_delete(&msg);
    wasm_trap_delete(trap);
    if (!msg_ok) { fputs("host trap message did not survive the call\n", stderr); goto cleanup; }

    /* 3. an arity mismatch traps */
    wasm_val_vec_t two_args = { 2, args_data };
    trap = wasm_func_call(plain_fn, &two_args, &results);
    if (!trap) { fputs("arity mismatch reported success\n", stderr); goto cleanup; }
    wasm_trap_delete(trap);

    /* a null handle keeps the existing null-argument discipline */
    if (wasm_func_call(NULL, &args, &results) != NULL) {
        fputs("null func handle produced a trap\n", stderr);
        goto cleanup;
    }

    rc = 0;

cleanup:
    if (refuse_fn) wasm_func_delete(refuse_fn);
    if (env_fn) wasm_func_delete(env_fn);
    if (plain_fn) wasm_func_delete(plain_fn);
    if (ft_refuse) wasm_functype_delete(ft_refuse);
    if (ft_env) wasm_functype_delete(ft_env);
    if (ft_plain) wasm_functype_delete(ft_plain);
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
