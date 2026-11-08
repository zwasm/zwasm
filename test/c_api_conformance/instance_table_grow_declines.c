/* zwasm v2 — C-API conformance: once a table one instance EXPORTED has been
 * imported by another, neither side may grow it (#449). The cross-instance
 * counterpart of `host_table_grow_declines.c`, whose header has the mechanism.
 *
 *   exporter: (module (table (export "t") 1 funcref)
 *               (func (export "grow") (result i32)
 *                 ref.null func i32.const 4 table.grow 0)
 *               (func (export "size") (result i32) table.size 0))
 *   importer: (module (import "e" "t" (table 1 funcref))
 *               (func (export "grow") (result i32)
 *                 ref.null func i32.const 4 table.grow 0)
 *               (func (export "size") (result i32) table.size 0)
 *               (func (export "get0") (result i32)
 *                 i32.const 0 table.get 0 ref.is_null))
 *   mismatch: (module (import "e" "t" (table 2 funcref))
 *               (func (export "size") (result i32) table.size 0))
 *
 * Before the fix the exporter's `table.grow` answered 1 and reallocated the
 * backing the importer's copy still aliased; the importer's `ref.is_null` then
 * read freed memory. That read is not deterministic, so the grows' answers are
 * the assertion and `get0` is read only as a cross-check.
 *
 *   1. the exporter's guest grow, the exporter's handle grow and the importer's
 *      guest grow are all declined, both sizes stay 1, slot 0 stays null;
 *   2. an exported table nobody imported still grows;
 *   3. an import refused by `checkImportTypeMatches` leaves the exporter's
 *      table growable — the source is marked where the host-made one is.
 *
 * Engines: a JIT-backed exporter has no runtime to bind a table from, so both
 * instances are forced to the interpreter. Exits 0 on success. */

#include <stdio.h>
#include <stdint.h>

#include <wasm.h>
#include <zwasm.h>

/* wasm-tools parse + strip --all of `exporter`.
 * Exports: t -> table 0, grow -> func 0, size -> func 1. */
static const unsigned char kExporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04, 0x04, 0x01, 0x70,
    0x00, 0x01, 0x07, 0x13, 0x03, 0x01, 0x74, 0x01, 0x00, 0x04, 0x67, 0x72,
    0x6f, 0x77, 0x00, 0x00, 0x04, 0x73, 0x69, 0x7a, 0x65, 0x00, 0x01, 0x0a,
    0x11, 0x02, 0x09, 0x00, 0xd0, 0x70, 0x41, 0x04, 0xfc, 0x0f, 0x00, 0x0b,
    0x05, 0x00, 0xfc, 0x10, 0x00, 0x0b,
};

/* wasm-tools parse + strip --all of `importer` (the `imported` module of
 * `host_table_grow_declines.c`). Exports: grow, size, get0. */
static const unsigned char kImporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x02, 0x09, 0x01, 0x01, 0x65, 0x01, 0x74, 0x01, 0x70,
    0x00, 0x01, 0x03, 0x04, 0x03, 0x00, 0x00, 0x00, 0x07, 0x16, 0x03, 0x04,
    0x67, 0x72, 0x6f, 0x77, 0x00, 0x00, 0x04, 0x73, 0x69, 0x7a, 0x65, 0x00,
    0x01, 0x04, 0x67, 0x65, 0x74, 0x30, 0x00, 0x02, 0x0a, 0x19, 0x03, 0x09,
    0x00, 0xd0, 0x70, 0x41, 0x04, 0xfc, 0x0f, 0x00, 0x0b, 0x05, 0x00, 0xfc,
    0x10, 0x00, 0x0b, 0x07, 0x00, 0x41, 0x00, 0x25, 0x00, 0xd1, 0x0b,
};

/* wasm-tools parse + strip --all of `mismatch`: its min of 2 is not met by the
 * exporter's min-1 table. Exports: size. */
static const unsigned char kMismatchWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x02, 0x09, 0x01, 0x01, 0x65, 0x01, 0x74, 0x01, 0x70,
    0x00, 0x02, 0x03, 0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x73, 0x69,
    0x7a, 0x65, 0x00, 0x00, 0x0a, 0x07, 0x01, 0x05, 0x00, 0xfc, 0x10, 0x00,
    0x0b,
};

enum { kExpTable = 0, kExpGrow = 1, kExpSize = 2 };
enum { kImpGrow = 0, kImpSize = 1, kImpGet0 = 2 };
enum { kInitialSize = 1, kGrowDelta = 4, kGrownSize = 5, kGrowDeclined = -1, kSlotIsNull = 1 };

static int call_expect_i32(wasm_extern_t* fn, int32_t expected, const char* what, const char* which) {
    wasm_val_t results[1] = { { WASM_I32, { 0 } } };
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t res = { 1, results };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(fn), &no_args, &res);
    if (trap) {
        fprintf(stderr, "%s: `%s` trapped\n", what, which);
        wasm_trap_delete(trap);
        return 1;
    }
    if (results[0].of.i32 != expected) {
        fprintf(stderr, "%s: `%s` expected %d, got %d\n", what, which, (int) expected, (int) results[0].of.i32);
        return 1;
    }
    return 0;
}

static wasm_instance_t* instantiate(wasm_store_t* store, const unsigned char* bytes, size_t len,
                                    wasm_extern_t* import, wasm_module_t** module_out) {
    wasm_byte_vec_t binary = { len, (wasm_byte_t*) bytes };
    *module_out = wasm_module_new(store, &binary);
    if (!*module_out) return NULL;
    wasm_extern_t* externs[1] = { import };
    wasm_extern_vec_t imports = { import ? 1 : 0, import ? externs : NULL };
    wasm_trap_t* trap = NULL;
    wasm_instance_t* inst = zwasm_instance_new_ex(store, *module_out, &imports, &trap, ZWASM_ENGINE_INTERP);
    if (trap) wasm_trap_delete(trap);
    return inst;
}

/* 1, 2 and 3 share this shape: `importer` names which module imports the
 * exporter's table (NULL for none), and the rest asserts what each grow says. */
static int run(const char* what, const unsigned char* importer, size_t importer_len, int expect_linked) {
    int rc = 1;
    wasm_module_t* exp_mod = NULL;
    wasm_module_t* imp_mod = NULL;
    wasm_instance_t* exp_inst = NULL;
    wasm_instance_t* imp_inst = NULL;
    wasm_extern_vec_t exp_ex = { 0, NULL };
    wasm_extern_vec_t imp_ex = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!store) { fprintf(stderr, "%s: engine/store new failed\n", what); goto cleanup; }

    exp_inst = instantiate(store, kExporterWasm, sizeof(kExporterWasm), NULL, &exp_mod);
    if (!exp_inst) { fprintf(stderr, "%s: the exporter did not instantiate\n", what); goto cleanup; }
    wasm_instance_exports(exp_inst, &exp_ex);
    if (exp_ex.size <= kExpSize) { fprintf(stderr, "%s: the exporter is missing its exports\n", what); goto cleanup; }
    wasm_table_t* table = wasm_extern_as_table(exp_ex.data[kExpTable]);

    if (importer) {
        imp_inst = instantiate(store, importer, importer_len, exp_ex.data[kExpTable], &imp_mod);
        if ((imp_inst != NULL) != expect_linked) {
            fprintf(stderr, "%s: the importer %s\n", what, imp_inst ? "instantiated" : "did not instantiate");
            goto cleanup;
        }
    }

    if (imp_inst) {
        wasm_instance_exports(imp_inst, &imp_ex);
        if (imp_ex.size <= kImpGet0) { fprintf(stderr, "%s: the importer is missing its exports\n", what); goto cleanup; }
        if (call_expect_i32(imp_ex.data[kImpGet0], kSlotIsNull, what, "importer get0, before") != 0) goto cleanup;
        if (call_expect_i32(exp_ex.data[kExpGrow], kGrowDeclined, what, "exporter grow") != 0) goto cleanup;
        if (wasm_table_grow(table, kGrowDelta, NULL)) {
            fprintf(stderr, "%s: wasm_table_grow on the exporter's handle returned true\n", what);
            goto cleanup;
        }
        if (call_expect_i32(imp_ex.data[kImpGrow], kGrowDeclined, what, "importer grow") != 0) goto cleanup;
        if (call_expect_i32(imp_ex.data[kImpSize], kInitialSize, what, "importer size") != 0) goto cleanup;
        if (call_expect_i32(exp_ex.data[kExpSize], kInitialSize, what, "exporter size") != 0) goto cleanup;
        if (call_expect_i32(imp_ex.data[kImpGet0], kSlotIsNull, what, "importer get0, after") != 0) goto cleanup;
    } else {
        /* The previous size, 1, is what a successful grow answers. */
        if (call_expect_i32(exp_ex.data[kExpGrow], kInitialSize, what, "exporter grow") != 0) goto cleanup;
        if (call_expect_i32(exp_ex.data[kExpSize], kGrownSize, what, "exporter size") != 0) goto cleanup;
    }
    rc = 0;

cleanup:
    if (imp_ex.data) wasm_extern_vec_delete(&imp_ex);
    if (exp_ex.data) wasm_extern_vec_delete(&exp_ex);
    if (imp_inst) wasm_instance_delete(imp_inst);
    if (imp_mod) wasm_module_delete(imp_mod);
    if (exp_inst) wasm_instance_delete(exp_inst);
    if (exp_mod) wasm_module_delete(exp_mod);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    if (run("imported", kImporterWasm, sizeof(kImporterWasm), 1) != 0) return 1;
    if (run("never imported", NULL, 0, 0) != 0) return 1;
    if (run("import refused", kMismatchWasm, sizeof(kMismatchWasm), 0) != 0) return 1;
    return 0;
}
