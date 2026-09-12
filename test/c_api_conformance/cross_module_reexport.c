/* zwasm v2 — C-API conformance: a re-exported import links across three
 * modules, and the chain survives the defining module going away first.
 *
 *   A: (module (func (export "get") (result i32) (i32.const 42)))
 *   B: (module (import "a" "get" (func $get (result i32))) (export "get" (func $get)))
 *   C: (module (import "b" "get" (func $get (result i32)))
 *             (func (export "test") (result i32) (call $get)))
 *
 * C's import is satisfied with B's export extern, which is A's function
 * re-exported. Before #388 a JIT-backed B answered "not a defined function"
 * and C failed to instantiate; before #427 an interp-backed B bound C's
 * import to B's own func index 0 — B's import placeholder (body:
 * `unreachable`, the backstop `instantiate.zig` describes) — so C linked and
 * the chained call trapped there.
 *
 * Between instantiating C and calling it, A's instance and module are
 * deleted, then B's. On both engines C's thunk names A's runtime and entry
 * point (ADR-0228 / #427: B hands out what it resolved, so the thunk enters A
 * directly), and nothing counts that reference — A must stay alive until the
 * store goes. `wasm_instance_delete` parks every instance on the store and
 * `wasm_module_delete` defers a borrowed module's bytes, so it does. If a
 * refcount ever replaced the park, this is the test that would notice.
 *
 * Run on every engine. Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (func (export "get") (result i32) (i32.const 42))) */
static const uint8_t kAWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,                   /* type ()->(i32) */
    0x03, 0x02, 0x01, 0x00,                                     /* func[0]: type 0 */
    0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00,       /* export "get" -> 0 */
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b,             /* body: i32.const 42 */
};

/* (module (import "a" "get" (func (result i32))) (export "get" (func 0))) */
static const uint8_t kBWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,                   /* type ()->(i32) */
    0x02, 0x09, 0x01, 0x01, 0x61, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, /* import a.get */
    0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00,       /* export "get" -> 0 (the import) */
};

/* (module (import "b" "get" (func (result i32)))
 *         (func (export "test") (result i32) (call 0))) */
static const uint8_t kCWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,                   /* type ()->(i32) */
    0x02, 0x09, 0x01, 0x01, 0x62, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, /* import b.get */
    0x03, 0x02, 0x01, 0x00,                                     /* func[1]: type 0 */
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x01, /* export "test" -> 1 */
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b,             /* body: call 0 */
};

static const uint8_t kEngines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };

static const char* engine_name(uint8_t kind) {
    switch (kind) {
        case ZWASM_ENGINE_JIT: return "jit";
        case ZWASM_ENGINE_INTERP: return "interp";
        default: return "auto";
    }
}

/* One module of the chain: parse, instantiate with `imports`, fetch exports. */
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
    link_t a = { 0 }, b = { 0 }, c = { 0 };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t no_imports = { 0, NULL };
    if (link_up(store, engine, who, "A", kAWasm, sizeof(kAWasm), &no_imports, &a) != 0) goto cleanup;

    wasm_extern_t* b_externs[1] = { a.exports.data[0] };
    wasm_extern_vec_t b_imports = { 1, b_externs };
    if (link_up(store, engine, who, "B (re-exporting A's func)", kBWasm, sizeof(kBWasm), &b_imports, &b) != 0) goto cleanup;

    wasm_extern_t* c_externs[1] = { b.exports.data[0] };
    wasm_extern_vec_t c_imports = { 1, c_externs };
    if (link_up(store, engine, who, "C (importing B's re-export)", kCWasm, sizeof(kCWasm), &c_imports, &c) != 0) goto cleanup;
    if (wasm_extern_kind(c.exports.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] C is missing its `test` export\n", who);
        goto cleanup;
    }

    /* The defining module goes first, then the re-exporter. C must not. */
    unlink_all(&a);
    unlink_all(&b);

    wasm_val_t results[1] = { { WASM_I32, { 0 } } };
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t res = { 1, results };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(c.exports.data[0]), &no_args, &res);
    if (trap) {
        fprintf(stderr, "[%s] the chained call trapped after A and B were deleted\n", who);
        wasm_trap_delete(trap);
        goto cleanup;
    }
    if (results[0].kind != WASM_I32 || results[0].of.i32 != 42) {
        fprintf(stderr, "[%s] expected A's 42 through B, got kind=%d value=%d\n",
                who, (int) results[0].kind, (int) results[0].of.i32);
        goto cleanup;
    }
    rc = 0;

cleanup:
    unlink_all(&c);
    unlink_all(&b);
    unlink_all(&a);
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
