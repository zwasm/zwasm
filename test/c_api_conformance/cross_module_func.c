/* zwasm v2 — C-API conformance: a cross-module func import under every engine.
 *
 * Two modules composed through the stock wasm-c-api: the exporter's `get`
 * extern is handed to the importer's `wasm_extern_vec_t`, and the importer's
 * `test` must return the exporter's 42.
 *
 *   (module (func (export "get") (result i32) (i32.const 42)))
 *   (module (import "b" "get" (func $get (result i32)))
 *           (func (export "test") (result i32) (call $get)))
 *
 * Run on `auto`, `jit` and `interp`. `interp` has always bound this; the
 * JIT-backed engines could not, because the binder resolved the import through
 * the source instance's interpreter runtime and a JIT-backed instance has none
 * (#360). Since ADR-0200 / D-496 `auto` is JIT-first, so the stock
 * `wasm_instance_new` entry point was the one that could not compose.
 *
 * The exporter is instantiated on the same engine as the importer — the case
 * the fix is about is exporter and importer both JIT-backed.
 *
 * `outlives_exporter` then deletes the exporter and its export handles before
 * calling the importer. wasm-c-api transfers no ownership at instantiation, so
 * an embedder may legitimately do that; the importer's bridge thunk holds the
 * exporter's runtime address and entry point, so the exporter's JIT state has
 * to outlive it. Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (func (export "get") (result i32) (i32.const 42))) */
static const uint8_t kExporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,                   /* type ()->(i32) */
    0x03, 0x02, 0x01, 0x00,                                     /* func[0]: type 0 */
    0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00,       /* export "get" -> 0 */
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b,             /* body: i32.const 42 */
};

/* (module (import "b" "get" (func (result i32)))
 *         (func (export "test") (result i32) (call 0))) */
static const uint8_t kImporterWasm[] = {
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

static int compose_on(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* exporter_module = NULL;
    wasm_instance_t* exporter = NULL;
    wasm_extern_vec_t exporter_exports = { 0, NULL };
    wasm_module_t* importer_module = NULL;
    wasm_instance_t* importer = NULL;
    wasm_extern_vec_t importer_exports = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t exporter_binary = { sizeof(kExporterWasm), (wasm_byte_t*) kExporterWasm };
    exporter_module = wasm_module_new(store, &exporter_binary);
    if (!exporter_module) { fprintf(stderr, "[%s] exporter failed to parse\n", who); goto cleanup; }
    wasm_extern_vec_t no_imports = { 0, NULL };
    wasm_trap_t* etrap = NULL;
    exporter = zwasm_instance_new_ex(store, exporter_module, &no_imports, &etrap, engine);
    if (etrap) wasm_trap_delete(etrap);
    if (!exporter) { fprintf(stderr, "[%s] exporter failed to instantiate\n", who); goto cleanup; }
    wasm_instance_exports(exporter, &exporter_exports);
    if (exporter_exports.size < 1 || !exporter_exports.data[0]) {
        fprintf(stderr, "[%s] exporter exposed nothing\n", who);
        goto cleanup;
    }

    wasm_byte_vec_t importer_binary = { sizeof(kImporterWasm), (wasm_byte_t*) kImporterWasm };
    importer_module = wasm_module_new(store, &importer_binary);
    if (!importer_module) { fprintf(stderr, "[%s] importer failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { exporter_exports.data[0] };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    importer = zwasm_instance_new_ex(store, importer_module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!importer) {
        fprintf(stderr, "[%s] the importer failed to instantiate — a cross-module func "
                        "import did not bind\n", who);
        goto cleanup;
    }
    wasm_instance_exports(importer, &importer_exports);
    if (importer_exports.size < 1 || !importer_exports.data[0] ||
        wasm_extern_kind(importer_exports.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] the importer is missing its `test` export\n", who);
        goto cleanup;
    }

    wasm_val_t results[1] = { { WASM_I32, { 0 } } };
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t res = { 1, results };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(importer_exports.data[0]), &no_args, &res);
    if (trap) {
        fprintf(stderr, "[%s] the cross-module call trapped\n", who);
        wasm_trap_delete(trap);
        goto cleanup;
    }
    if (results[0].kind != WASM_I32 || results[0].of.i32 != 42) {
        fprintf(stderr, "[%s] expected 42, got kind=%d value=%d\n",
                who, (int) results[0].kind, (int) results[0].of.i32);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (importer_exports.data) wasm_extern_vec_delete(&importer_exports);
    if (importer) wasm_instance_delete(importer);
    if (importer_module) wasm_module_delete(importer_module);
    if (exporter_exports.data) wasm_extern_vec_delete(&exporter_exports);
    if (exporter) wasm_instance_delete(exporter);
    if (exporter_module) wasm_module_delete(exporter_module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* The embedder deletes the exporter — instance, module and export handles —
 * and only then calls the importer. Nothing in the wasm-c-api contract keeps
 * the exporter alive: `wasm_instance_new` borrows the import externs for the
 * call and transfers no ownership. The interpreter has always survived this
 * (`wasm_instance_delete` parks the runtime + arena as a store zombie per
 * ADR-0014 §2.1, exactly so cross-module references stay valid); the JIT arm
 * freed its JitInstance outright, which was harmless only while no C-API
 * importer could reference one. Once one can, calling here entered released
 * code and took a fatal signal. */
static int outlives_exporter(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* exporter_module = NULL;
    wasm_instance_t* exporter = NULL;
    wasm_extern_vec_t exporter_exports = { 0, NULL };
    wasm_module_t* importer_module = NULL;
    wasm_instance_t* importer = NULL;
    wasm_extern_vec_t importer_exports = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t exporter_binary = { sizeof(kExporterWasm), (wasm_byte_t*) kExporterWasm };
    exporter_module = wasm_module_new(store, &exporter_binary);
    if (!exporter_module) { fprintf(stderr, "[%s] exporter failed to parse\n", who); goto cleanup; }
    wasm_extern_vec_t no_imports = { 0, NULL };
    wasm_trap_t* etrap = NULL;
    exporter = zwasm_instance_new_ex(store, exporter_module, &no_imports, &etrap, engine);
    if (etrap) wasm_trap_delete(etrap);
    if (!exporter) { fprintf(stderr, "[%s] exporter failed to instantiate\n", who); goto cleanup; }
    wasm_instance_exports(exporter, &exporter_exports);
    if (exporter_exports.size < 1 || !exporter_exports.data[0]) {
        fprintf(stderr, "[%s] exporter exposed nothing\n", who);
        goto cleanup;
    }

    wasm_byte_vec_t importer_binary = { sizeof(kImporterWasm), (wasm_byte_t*) kImporterWasm };
    importer_module = wasm_module_new(store, &importer_binary);
    if (!importer_module) { fprintf(stderr, "[%s] importer failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { exporter_exports.data[0] };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    importer = zwasm_instance_new_ex(store, importer_module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!importer) { fprintf(stderr, "[%s] the importer failed to instantiate\n", who); goto cleanup; }
    wasm_instance_exports(importer, &importer_exports);
    if (importer_exports.size < 1 || !importer_exports.data[0]) {
        fprintf(stderr, "[%s] the importer is missing its `test` export\n", who);
        goto cleanup;
    }

    /* The exporter goes away. The importer must not. */
    wasm_extern_vec_delete(&exporter_exports);
    exporter_exports.data = NULL;
    wasm_instance_delete(exporter);
    exporter = NULL;
    wasm_module_delete(exporter_module);
    exporter_module = NULL;

    wasm_val_t results[1] = { { WASM_I32, { 0 } } };
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t res = { 1, results };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(importer_exports.data[0]), &no_args, &res);
    if (trap) {
        fprintf(stderr, "[%s] the call trapped after the exporter was deleted\n", who);
        wasm_trap_delete(trap);
        goto cleanup;
    }
    if (results[0].kind != WASM_I32 || results[0].of.i32 != 42) {
        fprintf(stderr, "[%s] after deleting the exporter, expected 42, got kind=%d value=%d\n",
                who, (int) results[0].kind, (int) results[0].of.i32);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (importer_exports.data) wasm_extern_vec_delete(&importer_exports);
    if (importer) wasm_instance_delete(importer);
    if (importer_module) wasm_module_delete(importer_module);
    if (exporter_exports.data) wasm_extern_vec_delete(&exporter_exports);
    if (exporter) wasm_instance_delete(exporter);
    if (exporter_module) wasm_module_delete(exporter_module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    for (size_t i = 0; i < sizeof(kEngines) / sizeof(kEngines[0]); i++) {
        if (compose_on(kEngines[i]) != 0) return 1;
        if (outlives_exporter(kEngines[i]) != 0) return 1;
    }
    return 0;
}
