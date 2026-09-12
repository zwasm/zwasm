/* zwasm v2 — C-API conformance: a re-exported HOST callback links across the
 * chain and is reached by the importer's call (#427).
 *
 *   h: a `wasm_func_new` callback (i32) -> (i32), returns arg + 1
 *   B: (module (import "h" "f" (func $f (param i32) (result i32))) (export "f" (func $f)))
 *   C: (module (import "b" "f" (func $f (param i32) (result i32)))
 *             (func (export "test") (param i32) (result i32) (local.get 0) (call $f)))
 *
 * C's import is satisfied with B's export extern, which is the host callback
 * re-exported. The binder copies the callback binding B holds into C, so
 * C's `call` runs the callback on C's own operand stack — the same route a
 * `call_indirect` through B's slot takes. B is deleted before C is called;
 * the callback handle stays, as it must (nothing counts its takers).
 *
 * Run on `interp` only. On `auto` the re-exporter compiles — a module whose
 * only func is a host-callback import has nothing the JIT declines — so B is
 * JIT-backed and has no interpreter runtime for C's binder to read, and the
 * JIT's own target lookup has no entry address for an import slot a host
 * callback fills. C links on neither engine there. That is the JIT-side hole
 * (#388's) plus the unchanged rule that an interp importer cannot bind a
 * JIT-backed source; measured on `main` at 8c6e19cb4, untouched by #427.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (import "h" "f" (func (param i32) (result i32))) (export "f" (func 0))) */
static const uint8_t kBWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,             /* type (i32)->(i32) */
    0x02, 0x07, 0x01, 0x01, 0x68, 0x01, 0x66, 0x00, 0x00,       /* import h.f */
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,                   /* export "f" -> 0 (the import) */
};

/* (module (import "b" "f" (func (param i32) (result i32)))
 *         (func (export "test") (param i32) (result i32) (local.get 0) (call 0))) */
static const uint8_t kCWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,             /* type (i32)->(i32) */
    0x02, 0x07, 0x01, 0x01, 0x62, 0x01, 0x66, 0x00, 0x00,       /* import b.f */
    0x03, 0x02, 0x01, 0x00,                                     /* func[1]: type 0 */
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x01, /* export "test" -> 1 */
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b, /* local.get 0; call 0 */
};

static const uint8_t kEngines[] = { ZWASM_ENGINE_INTERP };

static const char* engine_name(uint8_t kind) {
    switch (kind) {
        case ZWASM_ENGINE_JIT: return "jit";
        case ZWASM_ENGINE_INTERP: return "interp";
        default: return "auto";
    }
}

static wasm_trap_t* add_one(const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    results->data[0].kind = WASM_I32;
    results->data[0].of.i32 = args->data[0].of.i32 + 1;
    return NULL;
}

typedef struct {
    wasm_module_t* module;
    wasm_instance_t* instance;
    wasm_extern_vec_t exports;
} link_t;

static int link_up(wasm_store_t* store, uint8_t engine, const char* who, const char* label,
                   const uint8_t* wasm, size_t len, wasm_extern_vec_t* imports, link_t* out) {
    wasm_byte_vec_t binary = { len, (wasm_byte_t*) wasm };
    out->module = wasm_module_new(store, &binary);
    if (!out->module) { fprintf(stderr, "[%s] %s failed to parse\n", who, label); return 1; }
    wasm_trap_t* trap = NULL;
    out->instance = zwasm_instance_new_ex(store, out->module, imports, &trap, engine);
    if (trap) wasm_trap_delete(trap);
    if (!out->instance) { fprintf(stderr, "[%s] %s failed to instantiate\n", who, label); return 1; }
    wasm_instance_exports(out->instance, &out->exports);
    if (out->exports.size < 1 || !out->exports.data[0]) {
        fprintf(stderr, "[%s] %s exposed nothing\n", who, label);
        return 1;
    }
    return 0;
}

static void unlink_all(link_t* l) {
    if (l->exports.data) wasm_extern_vec_delete(&l->exports);
    l->exports.data = NULL;
    if (l->instance) wasm_instance_delete(l->instance);
    l->instance = NULL;
    if (l->module) wasm_module_delete(l->module);
    l->module = NULL;
}

static int chain_on(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    link_t b = { 0 }, c = { 0 };
    wasm_func_t* host_fn = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_functype_t* ft = wasm_functype_new_1_1(wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32));
    host_fn = wasm_func_new(store, ft, add_one);
    wasm_functype_delete(ft);
    if (!host_fn) { fprintf(stderr, "[%s] wasm_func_new failed\n", who); goto cleanup; }

    wasm_extern_t* b_externs[1] = { wasm_func_as_extern(host_fn) };
    wasm_extern_vec_t b_imports = { 1, b_externs };
    if (link_up(store, engine, who, "B (re-exporting the host callback)", kBWasm, sizeof(kBWasm), &b_imports, &b) != 0) goto cleanup;

    wasm_extern_t* c_externs[1] = { b.exports.data[0] };
    wasm_extern_vec_t c_imports = { 1, c_externs };
    if (link_up(store, engine, who, "C (importing B's re-export)", kCWasm, sizeof(kCWasm), &c_imports, &c) != 0) goto cleanup;
    if (wasm_extern_kind(c.exports.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] C is missing its `test` export\n", who);
        goto cleanup;
    }

    /* The re-exporter goes before the call; the callback handle stays. */
    unlink_all(&b);

    wasm_val_t args_data[1] = { { WASM_I32, { 41 } } };
    wasm_val_t results[1] = { { WASM_I32, { 0 } } };
    wasm_val_vec_t args = { 1, args_data };
    wasm_val_vec_t res = { 1, results };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(c.exports.data[0]), &args, &res);
    if (trap) {
        fprintf(stderr, "[%s] the chained call trapped after B was deleted\n", who);
        wasm_trap_delete(trap);
        goto cleanup;
    }
    if (results[0].kind != WASM_I32 || results[0].of.i32 != 42) {
        fprintf(stderr, "[%s] expected the callback's 42 through B, got kind=%d value=%d\n",
                who, (int) results[0].kind, (int) results[0].of.i32);
        goto cleanup;
    }
    rc = 0;

cleanup:
    unlink_all(&c);
    unlink_all(&b);
    if (host_fn) wasm_func_delete(host_fn);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    for (size_t i = 0; i < sizeof(kEngines) / sizeof(kEngines[0]); i++) {
        if (chain_on(kEngines[i]) != 0) return 1;
    }
    return 0;
}
