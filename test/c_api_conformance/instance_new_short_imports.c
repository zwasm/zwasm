/* zwasm v2 — C-API conformance: an import vector shorter than the module's
 * import count must make instantiation fail, not read past the vector.
 *
 * `wasm_instance_new` takes a `wasm_extern_vec_t` ({size, data}). The binder
 * indexed `.data` by the module's import count and never looked at `.size`,
 * so a short vector read whatever lay beyond it and dereferenced it — a
 * segfault on every engine (#392). Under wasm-c-api a short vector is an
 * embedder error; the library's answer to it is NULL, not a crash.
 *
 * A 2-import module is handed a 1-entry vector, on all three engines; the
 * exporter's single export fills the one entry so the only thing wrong is the
 * length. Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (func (export "get") (result i32) (i32.const 42))) */
static const uint8_t kExporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
    0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, 0x0a, 0x06, 0x01, 0x04,
    0x00, 0x41, 0x2a, 0x0b,
};

/* (module (import "b" "get" (func (result i32)))
 *         (import "b" "get2" (func (result i32)))
 *         (func (export "test") (result i32) call 0)) */
static const uint8_t kTwoImportWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x02,
    0x12, 0x02, 0x01, 0x62, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, 0x01, 0x62, 0x04, 0x67, 0x65, 0x74,
    0x32, 0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00,
    0x02, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b,
};

static const uint8_t kEngines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };

static const char* engine_name(uint8_t kind) {
    switch (kind) {
        case ZWASM_ENGINE_JIT: return "jit";
        case ZWASM_ENGINE_INTERP: return "interp";
        default: return "auto";
    }
}

static int short_vector_is_null(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* exporter_module = NULL;
    wasm_instance_t* exporter = NULL;
    wasm_extern_vec_t exporter_exports = { 0, NULL };
    wasm_module_t* importer_module = NULL;
    wasm_instance_t* importer = NULL;
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

    wasm_byte_vec_t importer_binary = { sizeof(kTwoImportWasm), (wasm_byte_t*) kTwoImportWasm };
    importer_module = wasm_module_new(store, &importer_binary);
    if (!importer_module) { fprintf(stderr, "[%s] two-import module failed to parse\n", who); goto cleanup; }

    /* One valid entry for a module that declares two imports. What lies past
     * the entry on the stack is deliberately not a NULL: a NULL would be
     * caught as a missing import, and the point is that the runtime must not
     * read there at all. */
    wasm_extern_t* one_entry[2] = { exporter_exports.data[0], (wasm_extern_t*) (uintptr_t) 0x4141414141414141ull };
    wasm_extern_vec_t short_vec = { 1, one_entry };
    wasm_trap_t* itrap = NULL;
    importer = zwasm_instance_new_ex(store, importer_module, &short_vec, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (importer) {
        fprintf(stderr, "[%s] a 1-entry vector instantiated a 2-import module\n", who);
        goto cleanup;
    }
    rc = 0;

cleanup:
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
        if (short_vector_is_null(kEngines[i]) != 0) return 1;
    }
    return 0;
}
