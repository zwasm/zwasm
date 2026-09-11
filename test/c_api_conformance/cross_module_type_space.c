/* zwasm v2 — C-API conformance: a cross-module func import's type is compared
 * across both modules' type spaces.
 *
 * A signature that names a type INDEX — `(ref $cb)` — means what `$cb` means
 * in the module the signature came from. Before #387 the binder read the
 * exporter's signature in the IMPORTER's type space: here the exporter's
 * `(ref 1)` would be read as the importer's type 1, the wrong type, so a link
 * that is valid by Wasm 3.0 §4.5.10 failed (NULL) on both engines. The
 * exporter's types are now retained, and the two type-definitions are compared
 * canonically (`canonicalEqualCross` / `superReachesCross`).
 *
 * `ok` puts `$cb` at index 1 in the exporter and index 0 in the importer; the
 * definitions are equal, so the import links and the exporter's `apply` calls
 * back into the importer's `dbl` through the typed reference: 21 * 2. `bad`
 * declares `$cb` with an i64 parameter, so the definitions differ and
 * instantiation must fail (NULL, no trap — #353's surface). Both run on `auto`,
 * `jit` and `interp`. Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (type $pad (func (param i64)))
 *         (type $cb (func (param i32) (result i32)))
 *         (type $take (func (param (ref $cb)) (result i32)))
 *         (func (export "apply") (type $take) (call_ref $cb (i32.const 21) (local.get 0)))) */
static const uint8_t kExporter[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03, 0x60,
    0x01, 0x7e, 0x00, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x01, 0x64, 0x01,
    0x01, 0x7f, 0x03, 0x02, 0x01, 0x02, 0x07, 0x09, 0x01, 0x05, 0x61, 0x70,
    0x70, 0x6c, 0x79, 0x00, 0x00, 0x0a, 0x0a, 0x01, 0x08, 0x00, 0x41, 0x15,
    0x20, 0x00, 0x14, 0x01, 0x0b,
};

/* (module (type $cb (func (param i32) (result i32)))
 *         (type $take (func (param (ref $cb)) (result i32)))
 *         (import "t" "apply" (func $apply (type $take)))
 *         (func $dbl (type $cb) (i32.mul (local.get 0) (i32.const 2)))
 *         (elem declare func $dbl)
 *         (func (export "test") (result i32) (call $apply (ref.func $dbl)))) */
static const uint8_t kImporterOk[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03, 0x60,
    0x01, 0x7f, 0x01, 0x7f, 0x60, 0x01, 0x64, 0x00, 0x01, 0x7f, 0x60, 0x00,
    0x01, 0x7f, 0x02, 0x0b, 0x01, 0x01, 0x74, 0x05, 0x61, 0x70, 0x70, 0x6c,
    0x79, 0x00, 0x01, 0x03, 0x03, 0x02, 0x00, 0x02, 0x07, 0x08, 0x01, 0x04,
    0x74, 0x65, 0x73, 0x74, 0x00, 0x02, 0x09, 0x05, 0x01, 0x03, 0x00, 0x01,
    0x01, 0x0a, 0x10, 0x02, 0x07, 0x00, 0x20, 0x00, 0x41, 0x02, 0x6c, 0x0b,
    0x06, 0x00, 0xd2, 0x01, 0x10, 0x00, 0x0b,
};

/* As `ok`, with (type $cb (func (param i64) (result i32))) and a constant `test` body. */
static const uint8_t kImporterBad[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03, 0x60,
    0x01, 0x7e, 0x01, 0x7f, 0x60, 0x01, 0x64, 0x00, 0x01, 0x7f, 0x60, 0x00,
    0x01, 0x7f, 0x02, 0x0b, 0x01, 0x01, 0x74, 0x05, 0x61, 0x70, 0x70, 0x6c,
    0x79, 0x00, 0x01, 0x03, 0x02, 0x01, 0x02, 0x07, 0x08, 0x01, 0x04, 0x74,
    0x65, 0x73, 0x74, 0x00, 0x01, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x00,
    0x0b,
};

static const uint8_t kEngines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };

static const char* engine_name(uint8_t kind) {
    switch (kind) {
        case ZWASM_ENGINE_JIT: return "jit";
        case ZWASM_ENGINE_INTERP: return "interp";
        default: return "auto";
    }
}

static int type_space_on(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* exporter = NULL; wasm_instance_t* exporter_inst = NULL;
    wasm_extern_vec_t exporter_exports = { 0, NULL };
    wasm_module_t* ok = NULL; wasm_instance_t* ok_inst = NULL;
    wasm_extern_vec_t ok_exports = { 0, NULL };
    wasm_module_t* bad = NULL;
    wasm_trap_t* trap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t exporter_bin = { sizeof(kExporter), (wasm_byte_t*) kExporter };
    exporter = wasm_module_new(store, &exporter_bin);
    if (!exporter) { fprintf(stderr, "[%s] exporter failed to parse\n", who); goto cleanup; }
    wasm_extern_vec_t no_imports = { 0, NULL };
    exporter_inst = zwasm_instance_new_ex(store, exporter, &no_imports, &trap, engine);
    if (trap) { wasm_trap_delete(trap); trap = NULL; }
    if (!exporter_inst) { fprintf(stderr, "[%s] exporter failed to instantiate\n", who); goto cleanup; }
    wasm_instance_exports(exporter_inst, &exporter_exports);
    if (exporter_exports.size != 1 || !exporter_exports.data[0]) {
        fprintf(stderr, "[%s] exporter exposed %zu externs\n", who, exporter_exports.size);
        goto cleanup;
    }
    wasm_extern_t* externs[1] = { exporter_exports.data[0] };
    wasm_extern_vec_t imports = { 1, externs };

    /* ok: equal definitions at different indices link, and the call goes through. */
    wasm_byte_vec_t ok_bin = { sizeof(kImporterOk), (wasm_byte_t*) kImporterOk };
    ok = wasm_module_new(store, &ok_bin);
    if (!ok) { fprintf(stderr, "[%s] ok importer failed to parse\n", who); goto cleanup; }
    ok_inst = zwasm_instance_new_ex(store, ok, &imports, &trap, engine);
    if (trap) { wasm_trap_delete(trap); trap = NULL; }
    if (!ok_inst) { fprintf(stderr, "[%s] ok importer failed to instantiate\n", who); goto cleanup; }
    wasm_instance_exports(ok_inst, &ok_exports);
    if (ok_exports.size != 1 || wasm_extern_kind(ok_exports.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] ok importer is missing its `test` export\n", who);
        goto cleanup;
    }
    wasm_val_t results[1] = { { WASM_I32, { 0 } } };
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t res = { 1, results };
    trap = wasm_func_call(wasm_extern_as_func(ok_exports.data[0]), &no_args, &res);
    if (trap) { fprintf(stderr, "[%s] the typed-reference call trapped\n", who); goto cleanup; }
    if (results[0].kind != WASM_I32 || results[0].of.i32 != 42) {
        fprintf(stderr, "[%s] expected 42 through the typed reference, got kind=%d value=%d\n",
                who, (int) results[0].kind, (int) results[0].of.i32);
        goto cleanup;
    }

    /* bad: differing definitions do not link. */
    wasm_byte_vec_t bad_bin = { sizeof(kImporterBad), (wasm_byte_t*) kImporterBad };
    bad = wasm_module_new(store, &bad_bin);
    if (!bad) { fprintf(stderr, "[%s] bad importer failed to parse\n", who); goto cleanup; }
    wasm_instance_t* bad_inst = zwasm_instance_new_ex(store, bad, &imports, &trap, engine);
    if (bad_inst) {
        fprintf(stderr, "[%s] bad importer instantiated against a differing type definition\n", who);
        wasm_instance_delete(bad_inst);
        goto cleanup;
    }
    if (trap) {
        fprintf(stderr, "[%s] bad importer produced a trap where NULL alone was expected\n", who);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (trap) wasm_trap_delete(trap);
    if (ok_exports.data) wasm_extern_vec_delete(&ok_exports);
    if (ok_inst) wasm_instance_delete(ok_inst);
    if (ok) wasm_module_delete(ok);
    if (bad) wasm_module_delete(bad);
    if (exporter_exports.data) wasm_extern_vec_delete(&exporter_exports);
    if (exporter_inst) wasm_instance_delete(exporter_inst);
    if (exporter) wasm_module_delete(exporter);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    for (size_t i = 0; i < sizeof(kEngines) / sizeof(kEngines[0]); i++) {
        if (type_space_on(kEngines[i]) != 0) return 1;
    }
    return 0;
}
