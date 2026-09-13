/* zwasm v2 — C-API conformance: once a `wasm_table_new` table has been
 * IMPORTED, neither side may grow it — the grow is declined, not staled (#449).
 *
 *   imported: (module (import "e" "t" (table 1 funcref))
 *               (func (export "grow") (result i32)
 *                 ref.null func i32.const 4 table.grow 0)
 *               (func (export "size") (result i32) table.size 0)
 *               (func (export "get0") (result i32)
 *                 i32.const 0 table.get 0 ref.is_null))
 *   own:      (module (table 1 funcref)
 *               (func (export "grow") (result i32)
 *                 ref.null func i32.const 4 table.grow 0)
 *               (func (export "size") (result i32) table.size 0))
 *   reexport: (module (import "e" "t" (table 1 funcref))
 *               (export "t" (table 0))
 *               (func (export "size") (result i32) table.size 0)
 *               (func (export "get0") (result i32)
 *                 i32.const 0 table.get 0 ref.is_null))
 *   owntab:   (module (table (export "t") 1 funcref)
 *               (func (export "size") (result i32) table.size 0))
 *   mismatch: (module (import "e" "t" (table 2 funcref))
 *               (func (export "size") (result i32) table.size 0))
 *   starttrap:(module (import "e" "t" (table 1 funcref))
 *               (func $boom unreachable)
 *               (start $boom)
 *               (func (export "size") (result i32) table.size 0))
 *
 * The binder hands the importer a VALUE COPY of the host's `TableInstance`,
 * whose `refs` slice header aliases the same backing. A grow on either side
 * reallocs that backing and writes the new header into ONE of the two copies:
 * the host's `wasm_table_grow` leaves the importer's header pointing at the
 * freed buffer, and the guest's `table.grow` leaves the handle's. Both are a
 * use-after-free on the next access — measured before the fix, scenario 1's
 * `ref.is_null` answered 0 out of released memory.
 *
 * Until the two sides share one `*TableInstance` (the shape `MemoryImport`
 * already has, tracked in #449), `TableInstance.host_imported` marks the table
 * from the moment the binder takes it and both grows decline instead. That is
 * an answer the spec and `wasm.h` both allow — `table.grow` may return -1 for
 * any reason, `wasm_table_grow` may return false — unlike the stale pointer.
 *
 * The mark has to be read after the handle is resolved, not while it is being
 * resolved: `wasm_instance_exports` hands back an INSTANCE-backed handle for a
 * re-exported import, whose `rt.tables[i]` is the binder's copy of the host
 * table. A check that sat in the standalone arm alone would miss that handle
 * and realloc the shared backing anyway — scenario 5 is the reading that says
 * so.
 *
 * The mark also has a MOMENT, not just a place. The binder runs before
 * `checkImportTypeMatches` and before the runtime exists, so a mark set where
 * the copy is made would cost a host table its growth for an importer that
 * never came to exist. The copy is marked as it is made — a start function
 * must not grow through it — but the SOURCE is marked at a commit point right
 * after the runtime is built and before the start function runs. Scenarios 7
 * and 8 are the two sides of that boundary.
 *
 * Eight things are measured:
 *
 *   1. the HOST's grow is declined after the import, the size is unchanged,
 *      and the guest's `ref.is_null` on slot 0 still answers 1 — the
 *      no-use-after-free evidence, since that is the read that answered 0
 *      before the fix;
 *   2. the GUEST's grow is declined after the import: `table.grow` is -1,
 *      `table.size` stays 1, and so does `wasm_table_size` on the handle;
 *   3. a table that was NEVER imported still grows — the mark is what gates
 *      the refusal, not the table being host-created;
 *   4. a guest's OWN table still grows — the mark is never set on it, so the
 *      refusal did not spread to ordinary module-defined tables;
 *   5. the host table RE-EXPORTED by its importer declines the same grow —
 *      the handle is instance-backed, so this is the path a standalone-only
 *      check would have let through: both sizes stay 1 and `ref.is_null` on
 *      slot 0 still answers 1;
 *   6. a guest's own table RE-EXPORTED to the embedder still grows through
 *      `wasm_table_grow` — the instance-backed arm is not refusing wholesale,
 *      only for the copies the binder marked;
 *   7. an instantiation REFUSED by `checkImportTypeMatches` (the module asks
 *      for a min the host table does not meet) leaves the host table growable:
 *      `zwasm_instance_new_ex` is NULL and the host's grow then succeeds,
 *      because the mark was never committed — measured before the commit
 *      point moved, this grow returned false and the table was stuck at 1
 *      for the rest of its life;
 *   8. an instantiation that fails because its START FUNCTION TRAPS still
 *      declines the grow. This is the other side of the boundary: the failure
 *      lands past the commit point, the runtime already holds the binder's
 *      copy, and it parks rather than being unwound — so the source must
 *      decline. Measured on both engines: the instance is NULL with a
 *      ZWASM_TRAP_UNREACHABLE trap, which is what says the START is the
 *      reason it failed and not something earlier.
 *
 * `wasm_table_get` allocates and returns a `wasm_ref_t*` even for a null slot
 * (the payload is the null ref), so a non-NULL return says nothing about
 * nullness — which is why scenario 1 asks the GUEST's `ref.is_null` instead.
 *
 * Engines: a forced `.jit` binds no table import at all, so the imported
 * scenarios (1, 2, 5, 7 and 8) run on `auto` and `interp` only — an engine that
 * cannot make the binding has nothing to say about what the binding forbids.
 * Scenarios 3, 4 and 6 need no table import and run on all three: 6 was
 * measured on a forced `.jit` too, and the grow through the exported handle
 * succeeds there. Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* wasm-tools parse + strip --all of the `imported` module above.
 * Exports: grow -> func 0, size -> func 1, get0 -> func 2. */
static const unsigned char kImportedWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x02, 0x09, 0x01, 0x01, 0x65, 0x01, 0x74, 0x01, 0x70,
    0x00, 0x01, 0x03, 0x04, 0x03, 0x00, 0x00, 0x00, 0x07, 0x16, 0x03, 0x04,
    0x67, 0x72, 0x6f, 0x77, 0x00, 0x00, 0x04, 0x73, 0x69, 0x7a, 0x65, 0x00,
    0x01, 0x04, 0x67, 0x65, 0x74, 0x30, 0x00, 0x02, 0x0a, 0x19, 0x03, 0x09,
    0x00, 0xd0, 0x70, 0x41, 0x04, 0xfc, 0x0f, 0x00, 0x0b, 0x05, 0x00, 0xfc,
    0x10, 0x00, 0x0b, 0x07, 0x00, 0x41, 0x00, 0x25, 0x00, 0xd1, 0x0b,
};

/* wasm-tools parse + strip --all of the `own` module above.
 * Exports: grow -> func 0, size -> func 1. */
static const unsigned char kOwnWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04, 0x04, 0x01, 0x70,
    0x00, 0x01, 0x07, 0x0f, 0x02, 0x04, 0x67, 0x72, 0x6f, 0x77, 0x00, 0x00,
    0x04, 0x73, 0x69, 0x7a, 0x65, 0x00, 0x01, 0x0a, 0x11, 0x02, 0x09, 0x00,
    0xd0, 0x70, 0x41, 0x04, 0xfc, 0x0f, 0x00, 0x0b, 0x05, 0x00, 0xfc, 0x10,
    0x00, 0x0b,
};

/* wasm-tools parse + strip --all of the `reexport` module above. It imports the
 * host table and hands it straight back out, so the embedder's handle for it is
 * INSTANCE-backed.
 * Exports: t -> table 0, size -> func 0, get0 -> func 1. */
static const unsigned char kReexportWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x02, 0x09, 0x01, 0x01, 0x65, 0x01, 0x74, 0x01, 0x70,
    0x00, 0x01, 0x03, 0x03, 0x02, 0x00, 0x00, 0x07, 0x13, 0x03, 0x01, 0x74,
    0x01, 0x00, 0x04, 0x73, 0x69, 0x7a, 0x65, 0x00, 0x00, 0x04, 0x67, 0x65,
    0x74, 0x30, 0x00, 0x01, 0x0a, 0x0f, 0x02, 0x05, 0x00, 0xfc, 0x10, 0x00,
    0x0b, 0x07, 0x00, 0x41, 0x00, 0x25, 0x00, 0xd1, 0x0b,
};

/* wasm-tools parse + strip --all of the `owntab` module above — the same
 * instance-backed handle shape as `kReexportWasm`, over a table the binder
 * never touched.
 * Exports: t -> table 0, size -> func 0. */
static const unsigned char kOwnTableWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00,
    0x01, 0x07, 0x0c, 0x02, 0x01, 0x74, 0x01, 0x00, 0x04, 0x73, 0x69, 0x7a,
    0x65, 0x00, 0x00, 0x0a, 0x07, 0x01, 0x05, 0x00, 0xfc, 0x10, 0x00, 0x0b,
};

/* wasm-tools parse + strip --all of the `mismatch` module above. Its import
 * asks for a min of 2, which the min-1 host table does not meet, so
 * `checkImportTypeMatches` refuses the instantiation AFTER the binder has
 * already built (and marked) its copy.
 * Exports: size -> func 0. */
static const unsigned char kMismatchWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x02, 0x09, 0x01, 0x01, 0x65, 0x01, 0x74, 0x01, 0x70,
    0x00, 0x02, 0x03, 0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x73, 0x69,
    0x7a, 0x65, 0x00, 0x00, 0x0a, 0x07, 0x01, 0x05, 0x00, 0xfc, 0x10, 0x00,
    0x0b,
};

/* wasm-tools parse + strip --all of the `starttrap` module above. The import
 * matches, so the instantiation gets past the commit point; its `(start)` then
 * executes `unreachable` and fails it.
 * Exports: size -> func 1 (func 0 is the start function). */
static const unsigned char kStartTrapWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60,
    0x00, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x02, 0x09, 0x01, 0x01, 0x65, 0x01,
    0x74, 0x01, 0x70, 0x00, 0x01, 0x03, 0x03, 0x02, 0x00, 0x01, 0x07, 0x08,
    0x01, 0x04, 0x73, 0x69, 0x7a, 0x65, 0x00, 0x01, 0x08, 0x01, 0x00, 0x0a,
    0x0b, 0x02, 0x03, 0x00, 0x00, 0x0b, 0x05, 0x00, 0xfc, 0x10, 0x00, 0x0b,
};

/* Export slots in `kImportedWasm` / `kOwnWasm`, in declaration order. */
enum { kGrowExport = 0, kSizeExport = 1, kGet0Export = 2 };

/* Export slots in `kReexportWasm` / `kOwnTableWasm`: the table comes first. */
enum { kTableExport = 0, kTableSizeExport = 1, kTableGet0Export = 2 };

/* The guest asks for 4 more cells on a table whose min is 1: a grow that
 * succeeds answers the previous size and leaves `table.size` at 5, a grow that
 * is declined answers -1 and leaves it at 1. */
enum { kInitialSize = 1, kGrowDelta = 4, kGrownSize = 5, kGrowDeclined = -1 };

/* Every slot of a `wasm_table_new(..., NULL)` table is the null ref. */
enum { kSlotIsNull = 1 };

/* A forced `.jit` binds no table import, so the imported scenarios cannot run
 * there; scenarios 3 and 4 need no import and take the full set. */
static const uint8_t kImportEngines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_INTERP };
static const uint8_t kAllEngines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };

static const char* engine_name(uint8_t kind) {
    switch (kind) {
        case ZWASM_ENGINE_JIT: return "jit";
        case ZWASM_ENGINE_INTERP: return "interp";
        default: return "auto";
    }
}

/* Call a no-argument i32-returning export and compare its answer. */
static int call_expect_i32(wasm_extern_t* fn, int32_t expected,
                           const char* who, const char* what, const char* which) {
    wasm_val_t results[1] = { { WASM_I32, { 0 } } };
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t res = { 1, results };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(fn), &no_args, &res);
    if (trap) {
        fprintf(stderr, "[%s] %s: the guest's `%s` trapped\n", who, what, which);
        wasm_trap_delete(trap);
        return 1;
    }
    if (results[0].kind != WASM_I32 || results[0].of.i32 != expected) {
        fprintf(stderr, "[%s] %s: the guest's `%s` expected %d, got kind=%d value=%d\n",
                who, what, which, (int) expected, (int) results[0].kind, (int) results[0].of.i32);
        return 1;
    }
    return 0;
}

/* `wasm_table_size` on the embedder's handle. */
static int expect_handle_size(const wasm_table_t* ht, uint32_t expected,
                              const char* who, const char* what, const char* when) {
    const uint32_t got = (uint32_t) wasm_table_size(ht);
    if (got != expected) {
        fprintf(stderr, "[%s] %s: wasm_table_size %s expected %u, got %u\n",
                who, what, when, (unsigned) expected, (unsigned) got);
        return 1;
    }
    return 0;
}

/* Build a min-1 funcref table on `store`, every slot null. */
static wasm_table_t* new_host_table(wasm_store_t* store) {
    wasm_limits_t lim = { kInitialSize, wasm_limits_max_default };
    wasm_tabletype_t* tt = wasm_tabletype_new(wasm_valtype_new(WASM_FUNCREF), &lim);
    if (!tt) return NULL;
    wasm_table_t* ht = wasm_table_new(store, tt, NULL);
    wasm_tabletype_delete(tt);
    return ht;
}

/* 1. The HOST's `wasm_table_grow` is declined once the table is imported, and
 * the guest still reads a live slot 0. Before the fix the grow succeeded, the
 * realloc moved the backing, and the importer's aliased header was left on the
 * freed buffer — `ref.is_null` then answered 0 out of released memory. */
static int host_grow_is_declined_after_import(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    const char* what = "host grow";
    wasm_table_t* ht = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    ht = new_host_table(store);
    if (!ht) { fprintf(stderr, "[%s] %s: wasm_table_new failed\n", who, what); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kImportedWasm), (wasm_byte_t*) kImportedWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] %s: the guest failed to parse\n", who, what); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_table_as_extern(ht) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) {
        fprintf(stderr, "[%s] %s: the guest did not instantiate\n", who, what);
        goto cleanup;
    }
    wasm_instance_exports(instance, &exports);
    if (exports.size <= kGet0Export || !exports.data[kGet0Export] ||
        wasm_extern_kind(exports.data[kGet0Export]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] %s: the guest is missing its exports\n", who, what);
        goto cleanup;
    }

    /* The binding reaches the host table before anything is grown. */
    if (call_expect_i32(exports.data[kGet0Export], kSlotIsNull, who, what, "get0") != 0) goto cleanup;

    /* The grow the importer's aliased header cannot survive: declined. */
    if (wasm_table_grow(ht, 5, NULL)) {
        fprintf(stderr, "[%s] %s: wasm_table_grow returned true after the import\n", who, what);
        goto cleanup;
    }
    if (expect_handle_size(ht, kInitialSize, who, what, "after the declined grow") != 0) goto cleanup;

    /* Nothing was reallocated, so the importer still reads the live backing.
     * Asked of the GUEST: `wasm_table_get` hands back a `wasm_ref_t*` even for
     * a null slot, so the host pointer cannot answer this. */
    if (call_expect_i32(exports.data[kGet0Export], kSlotIsNull, who, what,
                        "get0 after the declined grow") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (ht) wasm_table_delete(ht);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* 2. The GUEST's `table.grow` is declined on the same table, and neither side's
 * size moves. Before the fix this realloc left the HANDLE's header stale. */
static int guest_grow_is_declined_after_import(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    const char* what = "guest grow";
    wasm_table_t* ht = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    ht = new_host_table(store);
    if (!ht) { fprintf(stderr, "[%s] %s: wasm_table_new failed\n", who, what); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kImportedWasm), (wasm_byte_t*) kImportedWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] %s: the guest failed to parse\n", who, what); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_table_as_extern(ht) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) {
        fprintf(stderr, "[%s] %s: the guest did not instantiate\n", who, what);
        goto cleanup;
    }
    wasm_instance_exports(instance, &exports);
    if (exports.size <= kSizeExport || !exports.data[kGrowExport] ||
        wasm_extern_kind(exports.data[kGrowExport]) != WASM_EXTERN_FUNC ||
        wasm_extern_kind(exports.data[kSizeExport]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] %s: the guest is missing its exports\n", who, what);
        goto cleanup;
    }

    if (call_expect_i32(exports.data[kSizeExport], kInitialSize, who, what, "size") != 0) goto cleanup;
    if (call_expect_i32(exports.data[kGrowExport], kGrowDeclined, who, what, "grow") != 0) goto cleanup;
    if (call_expect_i32(exports.data[kSizeExport], kInitialSize, who, what,
                        "size after the declined grow") != 0) goto cleanup;
    if (expect_handle_size(ht, kInitialSize, who, what, "after the declined guest grow") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (ht) wasm_table_delete(ht);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* 3. A `wasm_table_new` table nobody imported has no second header to stale, so
 * it grows as it always did. Being host-created is not what gates the refusal.
 * No instance is involved, so every engine runs it. */
static int unimported_table_still_grows(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    const char* what = "unimported table";
    wasm_table_t* ht = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    ht = new_host_table(store);
    if (!ht) { fprintf(stderr, "[%s] %s: wasm_table_new failed\n", who, what); goto cleanup; }
    if (expect_handle_size(ht, kInitialSize, who, what, "before the grow") != 0) goto cleanup;
    if (!wasm_table_grow(ht, kGrowDelta, NULL)) {
        fprintf(stderr, "[%s] %s: wasm_table_grow returned false with no importer\n", who, what);
        goto cleanup;
    }
    if (expect_handle_size(ht, kGrownSize, who, what, "after the grow") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (ht) wasm_table_delete(ht);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* 4. A module-defined table is never handed through the binder, so the mark is
 * never set on it and `table.grow` still works — the regression guard for the
 * interpreter's new early return. */
static int guest_own_table_still_grows(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    const char* what = "guest own table";
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kOwnWasm), (wasm_byte_t*) kOwnWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] %s: the guest failed to parse\n", who, what); goto cleanup; }
    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) {
        fprintf(stderr, "[%s] %s: the guest did not instantiate\n", who, what);
        goto cleanup;
    }
    wasm_instance_exports(instance, &exports);
    if (exports.size <= kSizeExport || !exports.data[kGrowExport] ||
        wasm_extern_kind(exports.data[kGrowExport]) != WASM_EXTERN_FUNC ||
        wasm_extern_kind(exports.data[kSizeExport]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] %s: the guest is missing its exports\n", who, what);
        goto cleanup;
    }

    if (call_expect_i32(exports.data[kSizeExport], kInitialSize, who, what, "size") != 0) goto cleanup;
    /* A successful `table.grow` answers the size BEFORE the grow. */
    if (call_expect_i32(exports.data[kGrowExport], kInitialSize, who, what, "grow") != 0) goto cleanup;
    if (call_expect_i32(exports.data[kSizeExport], kGrownSize, who, what,
                        "size after the grow") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* 5. The importer RE-EXPORTS the host table, so `wasm_instance_exports` hands
 * back an instance-backed handle (`instance != NULL`) for the very table the
 * binder marked. The grow must still be declined: that handle resolves to the
 * binder's copy in `rt.tables`, and reallocating through it would move the
 * backing the standalone handle still points at. A `host_imported` check that
 * lived in the standalone arm alone never ran on this path. */
static int reexported_host_table_grow_is_declined(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    const char* what = "re-exported host table";
    wasm_table_t* ht = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    ht = new_host_table(store);
    if (!ht) { fprintf(stderr, "[%s] %s: wasm_table_new failed\n", who, what); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kReexportWasm), (wasm_byte_t*) kReexportWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] %s: the guest failed to parse\n", who, what); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_table_as_extern(ht) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) {
        fprintf(stderr, "[%s] %s: the guest did not instantiate\n", who, what);
        goto cleanup;
    }
    wasm_instance_exports(instance, &exports);
    if (exports.size <= kTableGet0Export || !exports.data[kTableExport] ||
        wasm_extern_kind(exports.data[kTableExport]) != WASM_EXTERN_TABLE ||
        wasm_extern_kind(exports.data[kTableGet0Export]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] %s: the guest is missing its exports\n", who, what);
        goto cleanup;
    }
    wasm_table_t* reexported = wasm_extern_as_table(exports.data[kTableExport]);
    if (!reexported) {
        fprintf(stderr, "[%s] %s: the re-export is not a table\n", who, what);
        goto cleanup;
    }

    /* The handle the embedder got back names the same table the host still
     * holds — both must decline, and the decline must leave both sizes put. */
    if (wasm_table_grow(reexported, 5, NULL)) {
        fprintf(stderr, "[%s] %s: wasm_table_grow returned true through the re-export\n", who, what);
        goto cleanup;
    }
    if (expect_handle_size(ht, kInitialSize, who, what, "on the host handle") != 0) goto cleanup;
    if (expect_handle_size(reexported, kInitialSize, who, what, "on the re-export") != 0) goto cleanup;

    /* Nothing moved, so the importer's own read of slot 0 is still live. */
    if (call_expect_i32(exports.data[kTableGet0Export], kSlotIsNull, who, what,
                        "get0 after the declined grow") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (ht) wasm_table_delete(ht);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* 6. The same instance-backed handle shape over a table the binder never saw:
 * a module defines its own table and exports it. `wasm_table_grow` must still
 * grow it, and the guest must see the new size — the mark, not the arm the
 * handle resolves through, is what declines. */
static int reexported_own_table_still_grows(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    const char* what = "exported own table";
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kOwnTableWasm), (wasm_byte_t*) kOwnTableWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] %s: the guest failed to parse\n", who, what); goto cleanup; }
    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) {
        fprintf(stderr, "[%s] %s: the guest did not instantiate\n", who, what);
        goto cleanup;
    }
    wasm_instance_exports(instance, &exports);
    if (exports.size <= kTableSizeExport || !exports.data[kTableExport] ||
        wasm_extern_kind(exports.data[kTableExport]) != WASM_EXTERN_TABLE ||
        wasm_extern_kind(exports.data[kTableSizeExport]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] %s: the guest is missing its exports\n", who, what);
        goto cleanup;
    }
    wasm_table_t* own = wasm_extern_as_table(exports.data[kTableExport]);
    if (!own) {
        fprintf(stderr, "[%s] %s: the export is not a table\n", who, what);
        goto cleanup;
    }

    if (expect_handle_size(own, kInitialSize, who, what, "before the grow") != 0) goto cleanup;
    if (!wasm_table_grow(own, kGrowDelta, NULL)) {
        fprintf(stderr, "[%s] %s: wasm_table_grow returned false on a table nobody imported\n",
                who, what);
        goto cleanup;
    }
    if (expect_handle_size(own, kGrownSize, who, what, "after the grow") != 0) goto cleanup;
    /* The guest sees the same table, so its `table.size` moved too. */
    if (call_expect_i32(exports.data[kTableSizeExport], kGrownSize, who, what,
                        "size after the grow") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* 7. An instantiation the IMPORT TYPE CHECK refuses leaves the host table
 * exactly as it found it. The binder has already built its copy and marked it
 * by the time `checkImportTypeMatches` compares the min-1 host table against
 * the module's min-2 import, so a mark written on the SOURCE there would be
 * written for an importer that never came to exist — and never taken back,
 * since nothing owns the undo. The source is marked at a commit point past
 * this check instead, so the grow here still succeeds. */
static int failed_instantiate_leaves_table_growable(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    const char* what = "refused import";
    wasm_table_t* ht = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    ht = new_host_table(store);
    if (!ht) { fprintf(stderr, "[%s] %s: wasm_table_new failed\n", who, what); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kMismatchWasm), (wasm_byte_t*) kMismatchWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] %s: the guest failed to parse\n", who, what); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_table_as_extern(ht) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (instance) {
        fprintf(stderr, "[%s] %s: the guest instantiated against a table below its min\n", who, what);
        goto cleanup;
    }

    /* No importer exists, so nothing can be staled and nothing is declined. */
    if (!wasm_table_grow(ht, 1, NULL)) {
        fprintf(stderr, "[%s] %s: wasm_table_grow returned false after a FAILED instantiation\n",
                who, what);
        goto cleanup;
    }
    if (expect_handle_size(ht, kInitialSize + 1, who, what, "after the grow") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (ht) wasm_table_delete(ht);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* 8. The other side of the same boundary: an instantiation whose START
 * FUNCTION traps also returns NULL, but by then the runtime holds the binder's
 * marked copy and parks rather than unwinding. The source must therefore still
 * decline — a commit point pushed any later than `instantiateRuntime` would
 * leave this copy able to realloc the backing the handle points at.
 *
 * The trap is read, not just deleted: ZWASM_TRAP_UNREACHABLE is what says the
 * START is the reason this failed, and not the import check of scenario 7. */
static int start_trap_still_declines_grow(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    const char* what = "start trap";
    wasm_table_t* ht = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    ht = new_host_table(store);
    if (!ht) { fprintf(stderr, "[%s] %s: wasm_table_new failed\n", who, what); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kStartTrapWasm), (wasm_byte_t*) kStartTrapWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "[%s] %s: the guest failed to parse\n", who, what); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_table_as_extern(ht) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (instance) {
        fprintf(stderr, "[%s] %s: the guest instantiated despite an unreachable start\n", who, what);
        if (itrap) wasm_trap_delete(itrap);
        goto cleanup;
    }
    if (!itrap) {
        fprintf(stderr, "[%s] %s: the failed instantiation reported no trap\n", who, what);
        goto cleanup;
    }
    const int32_t kind = zwasm_trap_kind(itrap);
    wasm_trap_delete(itrap);
    if (kind != ZWASM_TRAP_UNREACHABLE) {
        fprintf(stderr, "[%s] %s: expected trap kind %d (unreachable), got %d\n",
                who, what, (int) ZWASM_TRAP_UNREACHABLE, (int) kind);
        goto cleanup;
    }

    /* The mark was committed before the start ran, so it stands. */
    if (wasm_table_grow(ht, 1, NULL)) {
        fprintf(stderr, "[%s] %s: wasm_table_grow returned true after a trapping start\n", who, what);
        goto cleanup;
    }
    if (expect_handle_size(ht, kInitialSize, who, what, "after the declined grow") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (ht) wasm_table_delete(ht);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    for (size_t i = 0; i < sizeof(kImportEngines) / sizeof(kImportEngines[0]); i++) {
        if (host_grow_is_declined_after_import(kImportEngines[i]) != 0) return 1;
        if (guest_grow_is_declined_after_import(kImportEngines[i]) != 0) return 1;
        if (reexported_host_table_grow_is_declined(kImportEngines[i]) != 0) return 1;
        if (failed_instantiate_leaves_table_growable(kImportEngines[i]) != 0) return 1;
        if (start_trap_still_declines_grow(kImportEngines[i]) != 0) return 1;
    }
    for (size_t i = 0; i < sizeof(kAllEngines) / sizeof(kAllEngines[0]); i++) {
        if (unimported_table_still_grows(kAllEngines[i]) != 0) return 1;
        if (guest_own_table_still_grows(kAllEngines[i]) != 0) return 1;
        if (reexported_own_table_still_grows(kAllEngines[i]) != 0) return 1;
    }
    return 0;
}
