/* zwasm v2 — C-API conformance: a tag export is listed at its position
 * (#478).
 *
 * `wasm_module_exports` promises one exporttype per export in section order.
 * A tag export used to be dropped at decode, so it was missing from the
 * vector and every later export shifted. It is now reported with kind
 * WASM_EXTERN_TAG and the tag's signature, resolved through the tag index
 * space (imported tags first). A tag has no wasm_extern_t, so
 * `wasm_instance_exports` leaves it out; this test pins that too.
 *
 * Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (type (func)) (func) (tag (type 0))
 *   (export "e0" (tag 0)) (export "f" (func 0))) */
static const uint8_t kTagThenFunc[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x00,
    0x0d, 0x03, 0x01, 0x00, 0x00,
    0x07, 0x0a, 0x02, 0x02, 'e', '0', 0x04, 0x00, 0x01, 'f', 0x00, 0x00,
    0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
};

/* (module (type (func (param i32))) (type (func))
 *   (import "env" "t" (tag (type 0))) (tag (type 1))
 *   (export "t2" (tag 0)) (export "t3" (tag 1))) */
static const uint8_t kImportedTagReexported[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00,
    0x02, 0x0a, 0x01, 0x03, 'e', 'n', 'v', 0x01, 't', 0x04, 0x00, 0x00,
    0x0d, 0x03, 0x01, 0x00, 0x01,
    0x07, 0x0b, 0x02, 0x02, 't', '2', 0x04, 0x00, 0x02, 't', '3', 0x04, 0x01,
};

static int check_name(const wasm_exporttype_t* xt, const char* want, const char* label) {
    const wasm_name_t* name = wasm_exporttype_name(xt);
    size_t want_len = strlen(want);
    if (name->size != want_len || memcmp(name->data, want, want_len) != 0) {
        fprintf(stderr, "%s: export is not named \"%s\"\n", label, want);
        return 0;
    }
    return 1;
}

/* The tag exporttype downcasts to a tagtype whose functype has `nparams`
 * params (all i32) and no results. */
static int check_tag(const wasm_exporttype_t* xt, size_t nparams, const char* label) {
    const wasm_externtype_t* et = wasm_exporttype_type(xt);
    if (wasm_externtype_kind(et) != WASM_EXTERN_TAG) {
        fprintf(stderr, "%s: kind %d, wanted WASM_EXTERN_TAG\n", label, (int) wasm_externtype_kind(et));
        return 0;
    }
    const wasm_tagtype_t* tt = wasm_externtype_as_tagtype_const(et);
    if (!tt) { fprintf(stderr, "%s: does not downcast to a tagtype\n", label); return 0; }
    const wasm_functype_t* ft = wasm_tagtype_functype(tt);
    const wasm_valtype_vec_t* params = wasm_functype_params(ft);
    const wasm_valtype_vec_t* results = wasm_functype_results(ft);
    if (params->size != nparams || results->size != 0) {
        fprintf(stderr, "%s: signature has %zu params / %zu results, wanted %zu / 0\n",
                label, params->size, results->size, nparams);
        return 0;
    }
    for (size_t i = 0; i < nparams; i++) {
        if (wasm_valtype_kind(params->data[i]) != WASM_I32) {
            fprintf(stderr, "%s: param %zu is not i32\n", label, i);
            return 0;
        }
    }
    return 1;
}

/* Both exports, in order; the tag first with its `()` signature. Then the
 * instance lists only the func. */
static int probe_tag_then_func(wasm_store_t* store) {
    int ok = 0;
    wasm_byte_vec_t binary = { sizeof(kTagThenFunc), (wasm_byte_t*) kTagThenFunc };
    wasm_module_t* module = wasm_module_new(store, &binary);
    if (!module) { fputs("tag_then_func: wasm_module_new failed\n", stderr); return 0; }

    wasm_exporttype_vec_t xs;
    wasm_module_exports(module, &xs);
    if (xs.size != 2) {
        fprintf(stderr, "tag_then_func: %zu exports, wanted 2\n", xs.size);
        goto done_exports;
    }
    if (!check_name(xs.data[0], "e0", "tag_then_func[0]") || !check_tag(xs.data[0], 0, "tag_then_func[0]")) goto done_exports;
    if (!check_name(xs.data[1], "f", "tag_then_func[1]")) goto done_exports;
    if (wasm_externtype_kind(wasm_exporttype_type(xs.data[1])) != WASM_EXTERN_FUNC) {
        fputs("tag_then_func[1]: kind is not WASM_EXTERN_FUNC\n", stderr);
        goto done_exports;
    }
    printf("module_exports_tag: e0/TAG (), f/FUNC\n");

    {
        wasm_extern_vec_t imports = { 0, NULL };
        wasm_instance_t* instance = wasm_instance_new(store, module, &imports, NULL);
        if (!instance) { fputs("tag_then_func: wasm_instance_new failed\n", stderr); goto done_exports; }
        wasm_extern_vec_t exts;
        wasm_instance_exports(instance, &exts);
        if (exts.size != 1) {
            fprintf(stderr, "tag_then_func: wasm_instance_exports has %zu entries, wanted 1\n", exts.size);
        } else if (wasm_extern_kind(exts.data[0]) != WASM_EXTERN_FUNC) {
            fputs("tag_then_func: the one extern is not the func\n", stderr);
        } else {
            printf("module_exports_tag: wasm_instance_exports -> 1 extern (FUNC), the tag omitted\n");
            ok = 1;
        }
        wasm_extern_vec_delete(&exts);
        wasm_instance_delete(instance);
    }

done_exports:
    wasm_exporttype_vec_delete(&xs);
    wasm_module_delete(module);
    return ok;
}

/* The tag index space starts with the imports: tag 0 is the imported (i32)
 * tag, tag 1 the defined () tag. */
static int probe_imported_tag_reexported(wasm_store_t* store) {
    int ok = 0;
    wasm_byte_vec_t binary = { sizeof(kImportedTagReexported), (wasm_byte_t*) kImportedTagReexported };
    wasm_module_t* module = wasm_module_new(store, &binary);
    if (!module) { fputs("imported_tag: wasm_module_new failed\n", stderr); return 0; }

    wasm_exporttype_vec_t xs;
    wasm_module_exports(module, &xs);
    if (xs.size != 2) {
        fprintf(stderr, "imported_tag: %zu exports, wanted 2\n", xs.size);
    } else if (check_name(xs.data[0], "t2", "imported_tag[0]") && check_tag(xs.data[0], 1, "imported_tag[0]") &&
               check_name(xs.data[1], "t3", "imported_tag[1]") && check_tag(xs.data[1], 0, "imported_tag[1]")) {
        printf("module_exports_tag: t2/TAG (i32) is the import, t3/TAG () the defined tag\n");
        ok = 1;
    }
    wasm_exporttype_vec_delete(&xs);
    wasm_module_delete(module);
    return ok;
}

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    if (!probe_tag_then_func(store)) goto cleanup;
    if (!probe_imported_tag_reexported(store)) goto cleanup;
    rc = 0;

cleanup:
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
