/* zwasm v2 — C-API conformance: a standalone global / memory / table's BACKING
 * belongs to the STORE, so an import binding made from it survives the
 * embedder deleting the handle (#446).
 *
 *   global: (module (import "e" "g" (global i32))
 *                   (func (export "test") (result i32) global.get 0))
 *   memory: (module (import "e" "m" (memory 1))
 *                   (func (export "test") (result i32) i32.const 0 i32.load))
 *   table:  (module (import "e" "t" (table 3 funcref))
 *                   (func (export "test") (result i32)
 *                     i32.const 0 table.get 0 ref.is_null))
 *
 * Upstream `wasm.h` declares all three through `WASM_DECLARE_REF`: the handle
 * is a REFERENCE and the entity behind it belongs to the store, exactly as
 * #439 established for `wasm_func_new`'s payload. zwasm hung the backing off
 * the HANDLE instead — `wasm_global_new`'s cell, `wasm_memory_new`'s
 * `MemoryInstance` and its pages, `wasm_table_new`'s `TableInstance` and its
 * refs — and the `_delete` of each freed it. An import binding keeps only the
 * raw address of that backing, and nothing counts the takers, so a handle
 * deleted while an importing instance was still live left the guest reading
 * released memory. Measured before the fix, one store, interp: the memory case
 * took SIGSEGV, the global case read garbage, the table case answered wrong.
 *
 * Each kind is measured the same way, and the shape is #439's:
 *
 *   1. create the entity on a store, import it, call the guest export that
 *      reads it, and get the right answer;
 *   2. delete the ENTITY HANDLE while the instance still holds a binding made
 *      from it — the original defect's own sequence — and call the export
 *      again. The answer must be unchanged: the backing is the store's, and
 *      nothing that died with the handle was load-bearing;
 *   3. delete the store, which is what frees the backing. Reaching here
 *      without a double free is the other half of the claim.
 *
 * Run on `auto`, `jit` and `interp`. A non-func import is outside what the JIT
 * binder can satisfy, so a forced `.jit` legitimately declines to instantiate
 * these three modules; that pair is SKIPPED with its reason printed rather
 * than asserted, because an engine that cannot make the binding at all has
 * nothing to say about the binding's lifetime. The siblings
 * `{global,memory,table}_import.c` take the same modules through plain
 * `wasm_instance_new`. Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (import "e" "g" (global i32))
 *         (func (export "test") (result i32) (global.get 0))) */
static const unsigned char kGlobalGuestWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,                   /* type ()->(i32) */
    0x02, 0x08, 0x01, 0x01, 0x65, 0x01, 0x67, 0x03, 0x7f, 0x00, /* import e.g : global i32 const */
    0x03, 0x02, 0x01, 0x00,                                     /* func[0]: type 0 */
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, /* export "test" -> 0 */
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x23, 0x00, 0x0b,             /* body: global.get 0 */
};

/* (module (import "e" "m" (memory 1))
 *         (func (export "test") (result i32) (i32.const 0) (i32.load))) */
static const unsigned char kMemoryGuestWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,                   /* type ()->(i32) */
    0x02, 0x08, 0x01, 0x01, 0x65, 0x01, 0x6d, 0x02, 0x00, 0x01, /* import e.m : memory min 1 */
    0x03, 0x02, 0x01, 0x00,                                     /* func[0]: type 0 */
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, /* export "test" -> 0 */
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0b, /* body: i32.const 0; i32.load */
};

/* (module (import "e" "t" (table 3 funcref))
 *         (func (export "test") (result i32)
 *           (i32.const 0) (table.get 0) (ref.is_null))) */
static const unsigned char kTableGuestWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,                   /* type ()->(i32) */
    0x02, 0x09, 0x01, 0x01, 0x65, 0x01, 0x74, 0x01, 0x70, 0x00, 0x03, /* import e.t : table funcref min 3 */
    0x03, 0x02, 0x01, 0x00,                                     /* func[0]: type 0 */
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, /* export "test" -> 0 */
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x41, 0x00, 0x25, 0x00, 0xd1, 0x0b, /* body: i32.const 0; table.get 0; ref.is_null */
};

static const uint8_t kEngines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };

static const char* engine_name(uint8_t kind) {
    switch (kind) {
        case ZWASM_ENGINE_JIT: return "jit";
        case ZWASM_ENGINE_INTERP: return "interp";
        default: return "auto";
    }
}

/* The host global's value, the byte written into the host memory, and what
 * `ref.is_null` says about a host table whose slots were never filled. Each is
 * distinctive enough that an answer computed out of released backing is not
 * the right answer. */
enum { kGlobalValue = 4919, kMemoryByte = 42, kTableIsNull = 1 };

/* `test` takes nothing and returns what the guest read out of the imported
 * entity. `when` names which side of the handle's deletion this call is on. */
static int call_reads_entity(wasm_extern_t* test_export, int32_t expected,
                             const char* who, const char* what, const char* when) {
    wasm_val_t results[1] = { { WASM_I32, { 0 } } };
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t res = { 1, results };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(test_export), &no_args, &res);
    if (trap) {
        fprintf(stderr, "[%s] %s: the guest call %s trapped\n", who, what, when);
        wasm_trap_delete(trap);
        return 1;
    }
    if (results[0].kind != WASM_I32 || results[0].of.i32 != expected) {
        fprintf(stderr, "[%s] %s: the guest call %s expected %d, got kind=%d value=%d\n",
                who, what, when, (int) expected, (int) results[0].kind, (int) results[0].of.i32);
        return 1;
    }
    return 0;
}

/* Only a FORCED JIT may decline: it binds no non-func import at all, which is
 * not this guard's subject. AUTO falls back to the interpreter and INTERP binds
 * these directly, so a failure there is a regression and must fail the case —
 * skipping on any engine would let one pass by not running. Returns 0 when the
 * skip is legitimate, 1 when it is a failure to report. */
static int skip_is_legitimate(uint8_t engine, const char* who, const char* what,
                              const wasm_trap_t* trap) {
    wasm_message_t msg = { 0, NULL };
    if (trap) wasm_trap_message(trap, &msg);
    const int kind = trap ? (int) zwasm_trap_kind(trap) : -1;
    const int len = msg.data ? (int) msg.size : 0;
    const char* text = msg.data ? msg.data : "";
    int rc;
    if (engine == ZWASM_ENGINE_JIT) {
        fprintf(stderr, "[%s] %s: SKIPPED — a forced JIT binds no non-func import "
                        "(trap kind %d \"%.*s\")\n", who, what, kind, len, text);
        rc = 0;
    } else {
        fprintf(stderr, "[%s] %s: did not instantiate, and only a forced JIT may "
                        "(trap kind %d \"%.*s\")\n", who, what, kind, len, text);
        rc = 1;
    }
    if (msg.data) wasm_byte_vec_delete(&msg);
    return rc;
}

/* `wasm_global_new`'s cell. The guest's `global.get 0` reads it directly, so a
 * cell freed with the handle is read back as whatever the allocator left. */
static int global_backing_outlives_handle(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    const char* what = "global";
    wasm_globaltype_t* gt = NULL;
    wasm_global_t* hg = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    gt = wasm_globaltype_new(wasm_valtype_new(WASM_I32), WASM_CONST);
    wasm_val_t init = { WASM_I32, { kGlobalValue } };
    hg = wasm_global_new(store, gt, &init);
    wasm_globaltype_delete(gt);
    gt = NULL;
    if (!hg) { fprintf(stderr, "[%s] %s: wasm_global_new failed\n", who, what); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kGlobalGuestWasm), (wasm_byte_t*) kGlobalGuestWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] %s: the guest failed to parse\n", who, what); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_global_as_extern(hg) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (!instance) rc = skip_is_legitimate(engine, who, what, itrap) == 0 ? 0 : 1;
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) goto cleanup;
    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0] ||
        wasm_extern_kind(exports.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] %s: the guest is missing its `test` export\n", who, what);
        goto cleanup;
    }

    /* 1. the binding reaches the host cell. */
    if (call_reads_entity(exports.data[0], kGlobalValue, who, what,
                          "before the handle was deleted") != 0) goto cleanup;

    /* 2. the embedder releases the HANDLE while the instance still holds a
     * binding made from it — and 3. the binding still reads a live cell. */
    wasm_global_delete(hg);
    hg = NULL;
    if (call_reads_entity(exports.data[0], kGlobalValue, who, what,
                          "after the handle was deleted") != 0) goto cleanup;
    rc = 0;

cleanup:
    /* 4. the store owns the cell, so its teardown is what frees it — once,
     * after every binding that pointed at it is gone. */
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (hg) wasm_global_delete(hg);
    if (gt) wasm_globaltype_delete(gt);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* `wasm_memory_new`'s `MemoryInstance` and pages. The host writes a
 * recognisable byte through `wasm_memory_data` BEFORE instantiating, so the
 * guest's `i32.load` answers out of the host's own buffer. */
static int memory_backing_outlives_handle(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    const char* what = "memory";
    wasm_memorytype_t* mt = NULL;
    wasm_memory_t* hm = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_limits_t lim = { 1, wasm_limits_max_default };
    mt = wasm_memorytype_new(&lim);
    hm = wasm_memory_new(store, mt);
    wasm_memorytype_delete(mt);
    mt = NULL;
    if (!hm) { fprintf(stderr, "[%s] %s: wasm_memory_new failed\n", who, what); goto cleanup; }
    uint8_t* data = (uint8_t*) wasm_memory_data(hm);
    if (!data) { fprintf(stderr, "[%s] %s: wasm_memory_data is NULL\n", who, what); goto cleanup; }
    data[0] = kMemoryByte; /* the rest of the page is zero, so `i32.load` reads the byte. */

    wasm_byte_vec_t binary = { sizeof(kMemoryGuestWasm), (wasm_byte_t*) kMemoryGuestWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] %s: the guest failed to parse\n", who, what); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_memory_as_extern(hm) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (!instance) rc = skip_is_legitimate(engine, who, what, itrap) == 0 ? 0 : 1;
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) goto cleanup;
    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0] ||
        wasm_extern_kind(exports.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] %s: the guest is missing its `test` export\n", who, what);
        goto cleanup;
    }

    if (call_reads_entity(exports.data[0], kMemoryByte, who, what,
                          "before the handle was deleted") != 0) goto cleanup;

    /* The pages are what `wasm_memory_delete` used to free; the guest's load
     * against them is the SIGSEGV this measured before the fix. */
    wasm_memory_delete(hm);
    hm = NULL;
    if (call_reads_entity(exports.data[0], kMemoryByte, who, what,
                          "after the handle was deleted") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (hm) wasm_memory_delete(hm);
    if (mt) wasm_memorytype_delete(mt);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* `wasm_table_new`'s `TableInstance` and its refs array. Every slot is null,
 * so `ref.is_null` on slot 0 is 1 — and a refs array freed with the handle
 * answers with whatever the allocator left in it. */
static int table_backing_outlives_handle(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    const char* what = "table";
    wasm_tabletype_t* tt = NULL;
    wasm_table_t* ht = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_limits_t lim = { 3, wasm_limits_max_default };
    tt = wasm_tabletype_new(wasm_valtype_new(WASM_FUNCREF), &lim);
    ht = wasm_table_new(store, tt, NULL);
    wasm_tabletype_delete(tt);
    tt = NULL;
    if (!ht) { fprintf(stderr, "[%s] %s: wasm_table_new failed\n", who, what); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kTableGuestWasm), (wasm_byte_t*) kTableGuestWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] %s: the guest failed to parse\n", who, what); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_table_as_extern(ht) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (!instance) rc = skip_is_legitimate(engine, who, what, itrap) == 0 ? 0 : 1;
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) goto cleanup;
    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0] ||
        wasm_extern_kind(exports.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] %s: the guest is missing its `test` export\n", who, what);
        goto cleanup;
    }

    if (call_reads_entity(exports.data[0], kTableIsNull, who, what,
                          "before the handle was deleted") != 0) goto cleanup;

    wasm_table_delete(ht);
    ht = NULL;
    if (call_reads_entity(exports.data[0], kTableIsNull, who, what,
                          "after the handle was deleted") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (ht) wasm_table_delete(ht);
    if (tt) wasm_tabletype_delete(tt);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    for (size_t i = 0; i < sizeof(kEngines) / sizeof(kEngines[0]); i++) {
        if (global_backing_outlives_handle(kEngines[i]) != 0) return 1;
        if (memory_backing_outlives_handle(kEngines[i]) != 0) return 1;
        if (table_backing_outlives_handle(kEngines[i]) != 0) return 1;
    }
    return 0;
}
