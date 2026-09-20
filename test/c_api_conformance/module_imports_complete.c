/* zwasm v2 — C-API conformance: every import is listed, or the call says it
 * is not (#475).
 *
 * `wasm_module_imports` promises one importtype per import, and an SDK that
 * mirrors a module's import list walks the vector positionally. Two things
 * used to break that silently: a tag import was dropped, shifting every later
 * import onto the wrong declaration, and an allocation failure mid-build left
 * a short vector indistinguishable from a module with fewer imports.
 * `zwasm_module_imports_ex` is the same walk with a verdict.
 *
 * Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (type (func (param i32)))
 *   (import "env" "before" (func (type 0)))
 *   (import "env" "error"  (tag  (type 0)))
 *   (import "env" "after"  (func (type 0)))) */
static const uint8_t kTagBetweenFuncs[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00, /* type (i32) -> () */
    0x02, 0x27, 0x03, /* import section, 3 entries */
    0x03, 'e', 'n', 'v', 0x06, 'b', 'e', 'f', 'o', 'r', 'e', 0x00, 0x00,
    0x03, 'e', 'n', 'v', 0x05, 'e', 'r', 'r', 'o', 'r', 0x04, 0x00, 0x00,
    0x03, 'e', 'n', 'v', 0x05, 'a', 'f', 't', 'e', 'r', 0x00, 0x00,
};

/* (module (func)) — nothing imported. */
static const uint8_t kNoImports[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x00,
    0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
};

static const char* kWantNames[3] = { "before", "error", "after" };
static const wasm_externkind_t kWantKinds[3] = {
    WASM_EXTERN_FUNC, WASM_EXTERN_TAG, WASM_EXTERN_FUNC,
};

/* The three imports, in order, with the tag's signature intact. */
static int check_entries(const wasm_importtype_vec_t* v, const char* label) {
    if (v->size != 3) { fprintf(stderr, "%s: %zu entries, wanted 3\n", label, v->size); return 0; }
    for (size_t i = 0; i < 3; i++) {
        const wasm_importtype_t* it = v->data[i];
        const wasm_name_t* mod = wasm_importtype_module(it);
        const wasm_name_t* name = wasm_importtype_name(it);
        if (mod->size != 3 || memcmp(mod->data, "env", 3) != 0) {
            fprintf(stderr, "%s: [%zu] module name is not \"env\"\n", label, i); return 0;
        }
        size_t want_len = strlen(kWantNames[i]);
        if (name->size != want_len || memcmp(name->data, kWantNames[i], want_len) != 0) {
            fprintf(stderr, "%s: [%zu] name is not \"%s\"\n", label, i, kWantNames[i]); return 0;
        }
        const wasm_externtype_t* et = wasm_importtype_type(it);
        if (wasm_externtype_kind(et) != kWantKinds[i]) {
            fprintf(stderr, "%s: [%zu] kind %d, wanted %d\n", label, i,
                    (int) wasm_externtype_kind(et), (int) kWantKinds[i]);
            return 0;
        }
    }
    const wasm_tagtype_t* tt = wasm_externtype_as_tagtype_const(wasm_importtype_type(v->data[1]));
    if (!tt) { fprintf(stderr, "%s: the tag entry does not downcast to a tagtype\n", label); return 0; }
    const wasm_functype_t* ft = wasm_tagtype_functype(tt);
    const wasm_valtype_vec_t* params = wasm_functype_params(ft);
    const wasm_valtype_vec_t* results = wasm_functype_results(ft);
    if (params->size != 1 || wasm_valtype_kind(params->data[0]) != WASM_I32 || results->size != 0) {
        fprintf(stderr, "%s: the tag's signature is not (i32) -> ()\n", label); return 0;
    }
    printf("module_imports_complete: %s -> before/FUNC, error/TAG (i32), after/FUNC\n", label);
    return 1;
}

static int probe_module(wasm_store_t* store) {
    int ok = 0;
    wasm_byte_vec_t binary = { sizeof(kTagBetweenFuncs), (wasm_byte_t*) kTagBetweenFuncs };
    wasm_module_t* module = wasm_module_new(store, &binary);
    if (!module) { fputs("tag_between_funcs: wasm_module_new failed\n", stderr); return 0; }

    wasm_importtype_vec_t stock;
    wasm_module_imports(module, &stock);
    ok = check_entries(&stock, "wasm_module_imports");
    wasm_importtype_vec_delete(&stock);
    if (!ok) goto done;

    wasm_importtype_vec_t ex;
    ok = zwasm_module_imports_ex(module, &ex);
    if (!ok) { fputs("zwasm_module_imports_ex: false on a module it can read\n", stderr); goto done; }
    ok = check_entries(&ex, "zwasm_module_imports_ex");
    wasm_importtype_vec_delete(&ex);

done:
    wasm_module_delete(module);
    return ok;
}

/* No import section is a complete answer, not a failure. */
static int probe_no_imports(wasm_store_t* store) {
    wasm_byte_vec_t binary = { sizeof(kNoImports), (wasm_byte_t*) kNoImports };
    wasm_module_t* module = wasm_module_new(store, &binary);
    if (!module) { fputs("no_imports: wasm_module_new failed\n", stderr); return 0; }

    int ok = 0;
    wasm_importtype_vec_t v;
    if (!zwasm_module_imports_ex(module, &v)) {
        fputs("no_imports: false for a module with no import section\n", stderr);
    } else if (v.size != 0 || v.data != NULL) {
        fprintf(stderr, "no_imports: %zu entries, wanted an empty vec\n", v.size);
        wasm_importtype_vec_delete(&v);
    } else {
        printf("module_imports_complete: no imports -> true, {0, NULL}\n");
        ok = 1;
    }
    wasm_module_delete(module);
    return ok;
}

/* A NULL module reports false with an emptied `out`; a NULL `out` reports
 * false without dereferencing it. */
static int probe_null(void) {
    wasm_importtype_vec_t v = { 7, (wasm_importtype_t**) (void*) &v };
    if (zwasm_module_imports_ex(NULL, &v)) { fputs("null: accepted a NULL module\n", stderr); return 0; }
    if (v.size != 0 || v.data != NULL) { fputs("null: out left non-empty\n", stderr); return 0; }
    if (zwasm_module_imports_ex(NULL, NULL)) { fputs("null: accepted a NULL out\n", stderr); return 0; }
    printf("module_imports_complete: NULL -> false, out emptied\n");
    return 1;
}

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    int ok = 1;
    ok &= probe_module(store);
    ok &= probe_no_imports(store);
    ok &= probe_null();
    if (ok) rc = 0;

cleanup:
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
