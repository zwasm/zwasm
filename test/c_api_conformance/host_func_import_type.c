/* zwasm v2 — C-API conformance: a host function in an import slot binds only
 * when its type matches the import's declaration, on both engines (#514).
 *
 * Before #514 a `wasm_func_new` callback bound to a func import with no type
 * compare, and was called with the import's signature: a `() -> f64` callback
 * in a `(param i32) (result i32)` slot answered 1060053464 on the JIT (the low
 * 32 bits of 1.5) and 0 on the interpreter, and neither trapped.
 *
 *   guest: (module (import "env" "cb" (func (param i32) (result i32)))
 *                  (func (export "test") (result i32) (call 0 (i32.const 7))))
 *
 * Per engine (JIT and INTERP, forced, so neither answer is the other's fallback):
 *   1. a `() -> f64` callback      → NULL, no trap (#353, as a cross-module
 *                                    type mismatch is)
 *   2. a `(i32) -> i32` callback   → instantiates; test() is 7 + 1 = 8
 *   3. a `(i64) -> i32` callback   → NULL, no trap (params differ, arity equal)
 *   4. a `(i32) -> i64` callback   → NULL, no trap (results differ, arity equal)
 *
 * Run by `test-c-api-conformance`. Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

static const uint8_t kGuest[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0a, 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f,
    0x60, 0x00, 0x01, 0x7f,                                     /* (i32)->(i32), ()->(i32) */
    0x02, 0x0a, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x02, 0x63, 0x62,
    0x00, 0x00,                                                 /* import env.cb: type 0 */
    0x03, 0x02, 0x01, 0x01,                                     /* func[1]: type 1 */
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x01, /* export "test" -> 1 */
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x07, 0x10, 0x00, 0x0b, /* body: call 0 (7) */
};

static const uint8_t kEngines[] = { ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };

static const char* engine_name(uint8_t kind) {
    return kind == ZWASM_ENGINE_JIT ? "jit" : "interp";
}

/* Case 2: counts the call in its env, answers its i32 param + 1. */
static wasm_trap_t* plus_one_env(void* env, const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    *(int32_t*) env += 1;
    results->data[0].kind = WASM_I32;
    results->data[0].of.i32 = args->data[0].of.i32 + 1;
    return NULL;
}

/* Cases 1, 3, 4: never reached when the slot is refused. */
static wasm_trap_t* never_called(const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    (void) args;
    (void) results;
    fputs("a mistyped callback was called\n", stderr);
    return NULL;
}

/* `(param?) -> (result)`; the caller deletes it. */
static wasm_functype_t* shape(int has_param, wasm_valkind_t param, wasm_valkind_t result) {
    wasm_valtype_vec_t params, results;
    if (has_param) {
        wasm_valtype_t* p[1] = { wasm_valtype_new(param) };
        wasm_valtype_vec_new(&params, 1, p);
    } else {
        wasm_valtype_vec_new_empty(&params);
    }
    wasm_valtype_t* r[1] = { wasm_valtype_new(result) };
    wasm_valtype_vec_new(&results, 1, r);
    return wasm_functype_new(&params, &results);
}

/* Instantiates kGuest with `host_fn` in the slot. Refused: NULL and no trap.
 * Otherwise test() must answer `want` after one call counted in `calls`. */
static int run_case(uint8_t engine, wasm_store_t* store, wasm_func_t* host_fn, int refused,
                    const int32_t* calls, int32_t want, const char* label) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_extern_vec_t exports = { 0, NULL };

    wasm_byte_vec_t binary = { sizeof(kGuest), (wasm_byte_t*) kGuest };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] %s: guest failed to parse\n", who, label); goto cleanup; }
    wasm_extern_t* externs[1] = { wasm_func_as_extern(host_fn) };
    wasm_extern_vec_t imports = { 1, externs };
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (refused) {
        if (instance || itrap) {
            fprintf(stderr, "[%s] %s: expected NULL with no trap, got %s%s\n",
                    who, label, instance ? "an instance" : "NULL", itrap ? " with a trap" : "");
            goto cleanup;
        }
        rc = 0;
        goto cleanup;
    }
    if (!instance) {
        fprintf(stderr, "[%s] %s: not instantiated (trap kind %d)\n",
                who, label, itrap ? (int) zwasm_trap_kind(itrap) : -1);
        goto cleanup;
    }
    wasm_instance_exports(instance, &exports);
    if (exports.size != 1 || !exports.data[0] || wasm_extern_kind(exports.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] %s: no test export\n", who, label);
        goto cleanup;
    }
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_t res_data[1];
    memset(res_data, 0, sizeof(res_data));
    wasm_val_vec_t res = { 1, res_data };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(exports.data[0]), &no_args, &res);
    if (trap) {
        fprintf(stderr, "[%s] %s: test() trapped, kind %d\n", who, label, (int) zwasm_trap_kind(trap));
        wasm_trap_delete(trap);
        goto cleanup;
    }
    if (res_data[0].of.i32 != want || *calls != 1) {
        fprintf(stderr, "[%s] %s: test() = %d after %d call(s), expected %d after 1\n",
                who, label, (int) res_data[0].of.i32, (int) *calls, (int) want);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (itrap) wasm_trap_delete(itrap);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    return rc;
}

static int run_engine(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    int32_t calls = 0;
    wasm_func_t* fns[4] = { NULL, NULL, NULL, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_functype_t* ft;
    ft = shape(0, WASM_I32, WASM_F64);
    fns[0] = wasm_func_new(store, ft, never_called);
    wasm_functype_delete(ft);
    ft = shape(1, WASM_I32, WASM_I32);
    fns[1] = wasm_func_new_with_env(store, ft, plus_one_env, &calls, NULL);
    wasm_functype_delete(ft);
    ft = shape(1, WASM_I64, WASM_I32);
    fns[2] = wasm_func_new(store, ft, never_called);
    wasm_functype_delete(ft);
    ft = shape(1, WASM_I32, WASM_I64);
    fns[3] = wasm_func_new(store, ft, never_called);
    wasm_functype_delete(ft);
    for (int i = 0; i < 4; i++) {
        if (!fns[i]) { fprintf(stderr, "[%s] host func %d: new failed\n", who, i); goto cleanup; }
    }

    if (run_case(engine, store, fns[0], 1, &calls, 0, "() -> f64") != 0) goto cleanup;
    if (run_case(engine, store, fns[1], 0, &calls, 8, "(i32) -> i32") != 0) goto cleanup;
    if (run_case(engine, store, fns[2], 1, &calls, 0, "(i64) -> i32") != 0) goto cleanup;
    if (run_case(engine, store, fns[3], 1, &calls, 0, "(i32) -> i64") != 0) goto cleanup;
    rc = 0;

cleanup:
    for (int i = 0; i < 4; i++) if (fns[i]) wasm_func_delete(fns[i]);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    for (size_t i = 0; i < sizeof(kEngines) / sizeof(kEngines[0]); i++) {
        if (run_engine(kEngines[i]) != 0) return 1;
    }
    return 0;
}
