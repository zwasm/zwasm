/* zwasm v2 — C-API conformance: a cross-module import binds to the extern
 * the embedder passed, not to whichever export shares the import's field name.
 *
 * wasm-c-api's import vector is positional: `imports.data[i]` is the entity
 * for import `i`, and the field name is the importer's business alone. Before
 * #386 the binder re-resolved the source by looking the FIELD NAME up among
 * the exporter's exports, with two consequences, both pinned here:
 *
 *   alias — the exporter has no export by that name: instantiation failed
 *           (NULL) although a matching extern was passed;
 *   decoy — the exporter exports a DIFFERENT entity under that name: the
 *           import bound the decoy (the interpreter returned its value, the
 *           JIT's bridge thunk jumped to its body), or its descriptor was
 *           checked in the passed entity's stead.
 *
 * Funcs run on `auto`, `jit` and `interp`. Tables, memories and globals run
 * with the exporter on `interp` and the importer on `auto` and `interp`: the
 * JIT satisfies no non-func import today and reaches for the exporter's
 * interpreter runtime, so a JIT-backed exporter cannot lend those kinds.
 * Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (func (export "original") (result i32) (i32.const 42))
 *         (func (export "renamed") (result i32) (i32.const 7))) */
static const uint8_t kExporterFuncs[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x00, 0x07, 0x16, 0x02, 0x08,
    0x6f, 0x72, 0x69, 0x67, 0x69, 0x6e, 0x61, 0x6c, 0x00, 0x00, 0x07, 0x72,
    0x65, 0x6e, 0x61, 0x6d, 0x65, 0x64, 0x00, 0x01, 0x0a, 0x0b, 0x02, 0x04,
    0x00, 0x41, 0x2a, 0x0b, 0x04, 0x00, 0x41, 0x07, 0x0b,
};

/* (module (import "x" "nope" (func (result i32)))
 *         (func (export "call") (result i32) (call 0))) */
static const uint8_t kImporterFuncAlias[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x02, 0x0a, 0x01, 0x01, 0x78, 0x04, 0x6e, 0x6f, 0x70,
    0x65, 0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x63,
    0x61, 0x6c, 0x6c, 0x00, 0x01, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x10, 0x00,
    0x0b,
};

/* (module (import "x" "renamed" (func (result i32)))
 *         (func (export "call") (result i32) (call 0))) */
static const uint8_t kImporterFuncDecoy[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x02, 0x0d, 0x01, 0x01, 0x78, 0x07, 0x72, 0x65, 0x6e,
    0x61, 0x6d, 0x65, 0x64, 0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x08,
    0x01, 0x04, 0x63, 0x61, 0x6c, 0x6c, 0x00, 0x01, 0x0a, 0x06, 0x01, 0x04,
    0x00, 0x10, 0x00, 0x0b,
};

/* (module (table (export "tab_decoy") 2 funcref) (table (export "tab_orig") 3 funcref)
 *         (memory (export "mem_decoy") 2) (memory (export "mem_orig") 1)
 *         (global (export "g_decoy") i32 (i32.const 7)) (global (export "g_orig") i32 (i32.const 42))) */
static const uint8_t kExporterEntities[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x04, 0x07, 0x02, 0x70,
    0x00, 0x02, 0x70, 0x00, 0x03, 0x05, 0x05, 0x02, 0x00, 0x02, 0x00, 0x01,
    0x06, 0x0b, 0x02, 0x7f, 0x00, 0x41, 0x07, 0x0b, 0x7f, 0x00, 0x41, 0x2a,
    0x0b, 0x07, 0x42, 0x06, 0x09, 0x74, 0x61, 0x62, 0x5f, 0x64, 0x65, 0x63,
    0x6f, 0x79, 0x01, 0x00, 0x08, 0x74, 0x61, 0x62, 0x5f, 0x6f, 0x72, 0x69,
    0x67, 0x01, 0x01, 0x09, 0x6d, 0x65, 0x6d, 0x5f, 0x64, 0x65, 0x63, 0x6f,
    0x79, 0x02, 0x00, 0x08, 0x6d, 0x65, 0x6d, 0x5f, 0x6f, 0x72, 0x69, 0x67,
    0x02, 0x01, 0x07, 0x67, 0x5f, 0x64, 0x65, 0x63, 0x6f, 0x79, 0x03, 0x00,
    0x06, 0x67, 0x5f, 0x6f, 0x72, 0x69, 0x67, 0x03, 0x01,
};

/* (module (import "x" "nope_t" (table 3 funcref)) (import "x" "nope_m" (memory 1))
 *         (import "x" "nope_g" (global i32))
 *         (func (export "tsize") (result i32) (table.size 0))
 *         (func (export "msize") (result i32) (memory.size))
 *         (func (export "gget") (result i32) (global.get 0))) */
static const uint8_t kImporterEntitiesAlias[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x02, 0x26, 0x03, 0x01, 0x78, 0x06, 0x6e, 0x6f, 0x70,
    0x65, 0x5f, 0x74, 0x01, 0x70, 0x00, 0x03, 0x01, 0x78, 0x06, 0x6e, 0x6f,
    0x70, 0x65, 0x5f, 0x6d, 0x02, 0x00, 0x01, 0x01, 0x78, 0x06, 0x6e, 0x6f,
    0x70, 0x65, 0x5f, 0x67, 0x03, 0x7f, 0x00, 0x03, 0x04, 0x03, 0x00, 0x00,
    0x00, 0x07, 0x18, 0x03, 0x05, 0x74, 0x73, 0x69, 0x7a, 0x65, 0x00, 0x00,
    0x05, 0x6d, 0x73, 0x69, 0x7a, 0x65, 0x00, 0x01, 0x04, 0x67, 0x67, 0x65,
    0x74, 0x00, 0x02, 0x0a, 0x11, 0x03, 0x05, 0x00, 0xfc, 0x10, 0x00, 0x0b,
    0x04, 0x00, 0x3f, 0x00, 0x0b, 0x04, 0x00, 0x23, 0x00, 0x0b,
};

/* Same as the alias importer, importing "tab_decoy" / "mem_decoy" / "g_decoy". */
static const uint8_t kImporterEntitiesDecoy[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x02, 0x2d, 0x03, 0x01, 0x78, 0x09, 0x74, 0x61, 0x62,
    0x5f, 0x64, 0x65, 0x63, 0x6f, 0x79, 0x01, 0x70, 0x00, 0x03, 0x01, 0x78,
    0x09, 0x6d, 0x65, 0x6d, 0x5f, 0x64, 0x65, 0x63, 0x6f, 0x79, 0x02, 0x00,
    0x01, 0x01, 0x78, 0x07, 0x67, 0x5f, 0x64, 0x65, 0x63, 0x6f, 0x79, 0x03,
    0x7f, 0x00, 0x03, 0x04, 0x03, 0x00, 0x00, 0x00, 0x07, 0x18, 0x03, 0x05,
    0x74, 0x73, 0x69, 0x7a, 0x65, 0x00, 0x00, 0x05, 0x6d, 0x73, 0x69, 0x7a,
    0x65, 0x00, 0x01, 0x04, 0x67, 0x67, 0x65, 0x74, 0x00, 0x02, 0x0a, 0x11,
    0x03, 0x05, 0x00, 0xfc, 0x10, 0x00, 0x0b, 0x04, 0x00, 0x3f, 0x00, 0x0b,
    0x04, 0x00, 0x23, 0x00, 0x0b,
};

static const char* engine_name(uint8_t kind) {
    switch (kind) {
        case ZWASM_ENGINE_JIT: return "jit";
        case ZWASM_ENGINE_INTERP: return "interp";
        default: return "auto";
    }
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

/* Call export `i` of `l` (no args, one i32 result) and compare. */
static int expect_i32(const char* who, const char* label, link_t* l, size_t i, int32_t want) {
    if (l->exports.size <= i || !l->exports.data[i] ||
        wasm_extern_kind(l->exports.data[i]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] %s: export %zu is not a func\n", who, label, i);
        return 1;
    }
    wasm_val_t results[1] = { { WASM_I32, { 0 } } };
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t res = { 1, results };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(l->exports.data[i]), &no_args, &res);
    if (trap) {
        fprintf(stderr, "[%s] %s: export %zu trapped\n", who, label, i);
        wasm_trap_delete(trap);
        return 1;
    }
    if (results[0].kind != WASM_I32 || results[0].of.i32 != want) {
        fprintf(stderr, "[%s] %s: export %zu returned kind=%d value=%d, want %d\n",
                who, label, i, (int) results[0].kind, (int) results[0].of.i32, (int) want);
        return 1;
    }
    return 0;
}

/* The exporter's "original" (export 0) satisfies an import whose field name
 * is either absent from the exporter (alias) or names its "renamed" decoy. */
static int funcs_on(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    link_t x = { 0 }, alias = { 0 }, decoy = { 0 };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t no_imports = { 0, NULL };
    if (link_up(store, engine, who, "func exporter", kExporterFuncs, sizeof(kExporterFuncs), &no_imports, &x) != 0) goto cleanup;
    if (x.exports.size != 2) { fprintf(stderr, "[%s] func exporter exposed %zu externs\n", who, x.exports.size); goto cleanup; }

    wasm_extern_t* externs[1] = { x.exports.data[0] }; /* "original" */
    wasm_extern_vec_t imports = { 1, externs };
    if (link_up(store, engine, who, "func importer (alias)", kImporterFuncAlias, sizeof(kImporterFuncAlias), &imports, &alias) != 0) goto cleanup;
    if (expect_i32(who, "alias", &alias, 0, 42) != 0) goto cleanup;
    if (link_up(store, engine, who, "func importer (decoy)", kImporterFuncDecoy, sizeof(kImporterFuncDecoy), &imports, &decoy) != 0) goto cleanup;
    if (expect_i32(who, "decoy", &decoy, 0, 42) != 0) goto cleanup;
    rc = 0;

cleanup:
    unlink_all(&decoy);
    unlink_all(&alias);
    unlink_all(&x);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* The exporter's `*_orig` table / memory / global (exports 1, 3, 5) satisfy
 * imports whose field names are absent (alias) or name the `*_decoy` siblings.
 * The decoys differ in what the importer can observe: the decoy table is too
 * small for the import's `(table 3 funcref)`, the decoy memory has two pages
 * where the original has one, the decoy global holds 7. */
static int entities_on(uint8_t importer_engine) {
    int rc = 1;
    const char* who = engine_name(importer_engine);
    link_t x = { 0 }, alias = { 0 }, decoy = { 0 };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t no_imports = { 0, NULL };
    if (link_up(store, ZWASM_ENGINE_INTERP, who, "entity exporter", kExporterEntities, sizeof(kExporterEntities), &no_imports, &x) != 0) goto cleanup;
    if (x.exports.size != 6) { fprintf(stderr, "[%s] entity exporter exposed %zu externs\n", who, x.exports.size); goto cleanup; }

    wasm_extern_t* externs[3] = { x.exports.data[1], x.exports.data[3], x.exports.data[5] };
    wasm_extern_vec_t imports = { 3, externs };
    static const char* const labels[3] = { "table size", "memory size", "global value" };
    static const int32_t wants[3] = { 3, 1, 42 };
    if (link_up(store, importer_engine, who, "entity importer (alias)", kImporterEntitiesAlias, sizeof(kImporterEntitiesAlias), &imports, &alias) != 0) goto cleanup;
    for (size_t i = 0; i < 3; i++) if (expect_i32(who, labels[i], &alias, i, wants[i]) != 0) goto cleanup;
    if (link_up(store, importer_engine, who, "entity importer (decoy)", kImporterEntitiesDecoy, sizeof(kImporterEntitiesDecoy), &imports, &decoy) != 0) goto cleanup;
    for (size_t i = 0; i < 3; i++) if (expect_i32(who, labels[i], &decoy, i, wants[i]) != 0) goto cleanup;
    rc = 0;

cleanup:
    unlink_all(&decoy);
    unlink_all(&alias);
    unlink_all(&x);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    static const uint8_t func_engines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };
    static const uint8_t entity_engines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_INTERP };
    for (size_t i = 0; i < sizeof(func_engines) / sizeof(func_engines[0]); i++) {
        if (funcs_on(func_engines[i]) != 0) return 1;
    }
    for (size_t i = 0; i < sizeof(entity_engines) / sizeof(entity_engines[0]); i++) {
        if (entities_on(entity_engines[i]) != 0) return 1;
    }
    return 0;
}
