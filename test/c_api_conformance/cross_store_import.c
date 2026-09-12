/* zwasm v2 — C-API conformance: an import extern from ANOTHER store is refused
 * at instantiation (#436).
 *
 * wasm-c-api's import vector says nothing about which store its externs came
 * from: `wasm_instance_new(store, module, imports, ...)` takes whatever handles
 * the embedder passes. zwasm's binder aliases the SOURCE's guts into the
 * importer — the exporter's interp runtime, or its JIT entry address — and the
 * retention that keeps those alive is the exporter's own store (`parkAsZombie`
 * defers a runtime to store teardown, per ADR-0014 §2.1). Across a boundary
 * that retention does not reach: `wasm_store_delete` on the exporter's store
 * would leave the importer calling freed code, with nothing in the contract
 * saying it must not. The binder therefore refuses the binding outright —
 * NULL, with a ZWASM_TRAP_BINDING_ERROR trap naming the boundary.
 *
 *   exporter:      (module (func (export "get") (result i32) (i32.const 7)))
 *   importer:      (module (import "e" "get" (func $g (result i32)))
 *                          (func (export "test") (result i32) (call $g)))
 *   host-importer: (module (import "h" "cb" (func $cb (param i32) (result i32)))
 *                          (func (export "test") (result i32) (i32.const 5) (call $cb)))
 *   mem-exporter:  (module (memory (export "m") 1))
 *   mem-importer:  (module (import "e" "m" (memory 1))
 *                          (func (export "test") (result i32) (i32.const 0) (i32.load)))
 *   glob-importer: (module (import "e" "g" (global i32))
 *                          (func (export "test") (result i32) (global.get 0)))
 *   wasi-importer: (module (import "wasi_snapshot_preview1" "fd_write"
 *                            (func (param i32 i32 i32 i32) (result i32)))
 *                          (memory (export "memory") 1)
 *                          (func (export "test") (result i32) (i32.const 7)))
 *   wasi-unknown:  (module (import "wasi_snapshot_preview1" "custom"
 *                            (func $c (result i32)))
 *                          (func (export "test") (result i32) (call $c)))
 *
 * Both sources the guard covers get a case: an extern exported by an INSTANCE
 * in another store, and a standalone `wasm_func_new_with_env` handle created on
 * another store. The instance arm is covered at BOTH kinds an `ext.instance`
 * can carry — a func export and a non-func (memory) one — because the kind is
 * what decides which binder even gets to ask: a non-func import is outside what
 * the JIT binder can satisfy, so a capability decline there would answer the
 * cross-store case with a bare NULL and no trap while the other two engines
 * name the boundary. The first two cases are each paired with the same
 * composition inside ONE store, which must still bind and still answer — what
 * the guard refuses is the boundary, not the composition.
 *
 * The standalone arm reaches all four kinds (#446). `wasm_global_new`'s cell,
 * like the `_with_env` payload above, belongs to the STORE that made it and
 * dies with it — so a global created on store B and imported in store A is
 * refused on the same ground. It was NOT refused while that cell belonged to
 * the handle instead: nothing about the boundary had changed, only who owned
 * what the binding would alias.
 *
 * The MODULE is under the rule too (#447). A JIT-backed instance BORROWS the
 * module's bytes and `wasm_module_delete` defers them to the MODULE's store, so
 * instantiating store B's module in store A reads out of a buffer B frees. Same
 * refusal, and the message names the route that does work: `wasm_module_share`
 * + `wasm_module_obtain` COPY the bytes into the obtaining store. That route is
 * measured right after the refusal, because a refusal is only defensible if the
 * sanctioned path still instantiates and still answers the exporter's 7.
 *
 * One more rule can answer at the same slot, and it OUTRANKS this one: the
 * KIND. An extern of the wrong kind for the import declaration — B's memory
 * export fed to a slot declared `(func)` — never binds, so it fails the same
 * way whatever store it came from, and the boundary is not the reason worth
 * reporting. So that refusal is a bare NULL with no trap, and it is asserted
 * TWICE: across a boundary and inside one store, which must answer alike. The
 * two engines disagreed on exactly this input — the interpreter judged the kind
 * first, while the JIT's cross-store precheck ran before any kind judgement and
 * named the boundary with a BINDING_ERROR.
 *
 * Some slots are EXEMPT, and what draws that line is what the JIT PLANTS — not
 * the module name. `setup` plants a `wasi_snapshot_preview1` import only where
 * `jit_dispatch` implements that field; a planted slot is satisfied out of band
 * from the store's own WASI host, the embedder's vector slot for it is never
 * read, and so no alias crosses anything. The rule is about a binding that
 * would reach into another store's guts; where no binding is built from the
 * slot, there is nothing to reach. A precheck that walked a planted slot anyway
 * refused — with `Final` severity, so `auto` did not even fall back — a module
 * the interpreter instantiated fine.
 *
 * The exemption stops exactly there. An UNKNOWN preview1 field is planted by
 * nobody, so `collectFromExterns` reads its slot and binds whatever sits in it
 * — a cross-store extern included, which deleting the other store then leaves
 * as freed code under the importer's call. So the last two cases are a pair and
 * must pass together: `fd_write` (planted → exempt, links on all three engines)
 * and `custom` (planted by nobody → the store rule applies, refused).
 *
 * Run on `auto`, `jit` and `interp`: the JIT-backed and interp paths reach the
 * check through different binders, so a guard on one is no evidence about the
 * other — all three must refuse identically, with the same trap kind. Exits 0
 * on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wasm.h>
#include <wasi.h>
#include <zwasm.h>

/* (module (func (export "get") (result i32) (i32.const 7))) */
static const uint8_t kExporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,                   /* type ()->(i32) */
    0x03, 0x02, 0x01, 0x00,                                     /* func[0]: type 0 */
    0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00,       /* export "get" -> 0 */
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x07, 0x0b,             /* body: i32.const 7 */
};

/* (module (import "e" "get" (func (result i32)))
 *         (func (export "test") (result i32) (call 0))) */
static const uint8_t kImporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,                   /* type ()->(i32) */
    0x02, 0x09, 0x01, 0x01, 0x65, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, /* import e.get */
    0x03, 0x02, 0x01, 0x00,                                     /* func[1]: type 0 */
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x01, /* export "test" -> 1 */
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b,             /* body: call 0 */
};

/* (module (import "h" "cb" (func (param i32) (result i32)))
 *         (func (export "test") (result i32) (i32.const 5) (call 0))) */
static const uint8_t kHostImporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0a, 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f, /* (i32)->(i32), ()->(i32) */
    0x02, 0x08, 0x01, 0x01, 0x68, 0x02, 0x63, 0x62, 0x00, 0x00, /* import h.cb : type 0 */
    0x03, 0x02, 0x01, 0x01,                                     /* func[1]: type 1 */
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x01, /* export "test" -> 1 */
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x05, 0x10, 0x00, 0x0b, /* body: i32.const 5; call 0 */
};

/* (module (memory (export "m") 1)) */
static const unsigned char kMemExporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x05, 0x03, 0x01, 0x00, 0x01,                               /* memory 0: min 1 */
    0x07, 0x05, 0x01, 0x01, 0x6d, 0x02, 0x00,                   /* export "m" -> memory 0 */
};

/* (module (import "e" "m" (memory 1))
 *         (func (export "test") (result i32) (i32.const 0) (i32.load))) */
static const unsigned char kMemImporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,                   /* type ()->(i32) */
    0x02, 0x08, 0x01, 0x01, 0x65, 0x01, 0x6d, 0x02, 0x00, 0x01, /* import e.m : memory min 1 */
    0x03, 0x02, 0x01, 0x00,                                     /* func[0]: type 0 */
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, /* export "test" -> 0 */
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0b, /* body: i32.const 0; i32.load */
};

/* (module (import "wasi_snapshot_preview1" "fd_write"
 *           (func (param i32 i32 i32 i32) (result i32)))
 *         (memory (export "memory") 1)
 *         (func (export "test") (result i32) (i32.const 7))) */
static const unsigned char kWasiImporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0d, 0x02, 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f,
    0x60, 0x00, 0x01, 0x7f,                                     /* (i32 i32 i32 i32)->(i32), ()->(i32) */
    0x02, 0x23, 0x01,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68,
    0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31,
    0x08, 0x66, 0x64, 0x5f, 0x77, 0x72, 0x69, 0x74, 0x65, 0x00, 0x00, /* import wasi_snapshot_preview1.fd_write */
    0x03, 0x02, 0x01, 0x01,                                     /* func[1]: type 1 */
    0x05, 0x03, 0x01, 0x00, 0x01,                               /* memory 0: min 1 */
    0x07, 0x11, 0x02, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,
    0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x01,                   /* export "memory" -> mem 0, "test" -> 1 */
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x07, 0x0b,             /* body: i32.const 7 */
};

/* (module (import "wasi_snapshot_preview1" "custom" (func $c (result i32)))
 *         (func (export "test") (result i32) (call $c)))
 * `custom` is a field no `jit_dispatch` entry implements, so nothing plants it. */
static const unsigned char kWasiUnknownImporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,                   /* type ()->(i32) */
    0x02, 0x21, 0x01,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68,
    0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31,
    0x06, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x00, 0x00,       /* import wasi_snapshot_preview1.custom */
    0x03, 0x02, 0x01, 0x00,                                     /* func[1]: type 0 */
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x01, /* export "test" -> 1 */
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b,             /* body: call 0 */
};

/* (module (import "e" "g" (global i32))
 *         (func (export "test") (result i32) (global.get 0))) */
static const unsigned char kGlobalImporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,                   /* type ()->(i32) */
    0x02, 0x08, 0x01, 0x01, 0x65, 0x01, 0x67, 0x03, 0x7f, 0x00, /* import e.g : global i32 const */
    0x03, 0x02, 0x01, 0x00,                                     /* func[0]: type 0 */
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, /* export "test" -> 0 */
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x23, 0x00, 0x0b,             /* body: global.get 0 */
};

static const uint8_t kEngines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };

static const char* engine_name(uint8_t kind) {
    switch (kind) {
        case ZWASM_ENGINE_JIT: return "jit";
        case ZWASM_ENGINE_INTERP: return "interp";
        default: return "auto";
    }
}

/* The host callback the host-importer calls: 5 + 37 = 42. The env is read, so
 * the `_with_env` payload is what the guard is asked about, not just a bare
 * callback pointer. */
static wasm_trap_t* add_env(void* env, const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    results->data[0].kind = WASM_I32;
    results->data[0].of.i32 = args->data[0].of.i32 + *(const int32_t*) env;
    return NULL;
}

/* The refusal both cross-store cases must produce. Ownership stays with the
 * caller: an instance handed back here (the failure this asserts against) is
 * still the caller's to delete. */
static int refusal_is_binding_error(const wasm_instance_t* instance, const wasm_trap_t* trap,
                                    const char* who, const char* label) {
    if (instance) {
        fprintf(stderr, "[%s] %s: instantiated across a store boundary\n", who, label);
        return 1;
    }
    if (!trap) {
        fprintf(stderr, "[%s] %s: refused with NULL but no trap\n", who, label);
        return 1;
    }
    if (zwasm_trap_kind(trap) != ZWASM_TRAP_BINDING_ERROR) {
        fprintf(stderr, "[%s] %s: trap kind %d, expected BINDING_ERROR\n",
                who, label, (int) zwasm_trap_kind(trap));
        return 1;
    }
    /* #441 — the message carries its terminating NUL and `size` counts it, so
     * `data` reads as a C string and the text is `size - 1` bytes. */
    wasm_message_t msg;
    wasm_trap_message(trap, &msg);
    int names_boundary = msg.data && msg.size > 1 && strstr(msg.data, "store") != NULL;
    if (!names_boundary) {
        fprintf(stderr, "[%s] %s: trap message \"%.*s\" does not name the store boundary\n",
                who, label, msg.data ? (int) msg.size : 0, msg.data ? msg.data : "");
    }
    wasm_byte_vec_delete(&msg);
    return names_boundary ? 0 : 1;
}

/* The exporter is instantiated in store B; the importer's import vector carries
 * B's `get` extern into an instantiation in store A. */
static int wasm_export_refused_across_stores(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* exporter_module = NULL;
    wasm_instance_t* exporter = NULL;
    wasm_extern_vec_t exporter_exports = { 0, NULL };
    wasm_module_t* importer_module = NULL;
    wasm_instance_t* importer = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store_a = eng ? wasm_store_new(eng) : NULL;
    wasm_store_t* store_b = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store_a || !store_b) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t exporter_binary = { sizeof(kExporterWasm), (wasm_byte_t*) kExporterWasm };
    exporter_module = wasm_module_new(store_b, &exporter_binary);
    if (!exporter_module) { fprintf(stderr, "[%s] exporter failed to parse\n", who); goto cleanup; }
    wasm_extern_vec_t no_imports = { 0, NULL };
    wasm_trap_t* etrap = NULL;
    exporter = zwasm_instance_new_ex(store_b, exporter_module, &no_imports, &etrap, engine);
    if (etrap) wasm_trap_delete(etrap);
    if (!exporter) { fprintf(stderr, "[%s] exporter failed to instantiate in store B\n", who); goto cleanup; }
    wasm_instance_exports(exporter, &exporter_exports);
    if (exporter_exports.size < 1 || !exporter_exports.data[0]) {
        fprintf(stderr, "[%s] exporter exposed nothing\n", who);
        goto cleanup;
    }

    wasm_byte_vec_t importer_binary = { sizeof(kImporterWasm), (wasm_byte_t*) kImporterWasm };
    importer_module = wasm_module_new(store_a, &importer_binary);
    if (!importer_module) { fprintf(stderr, "[%s] importer failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { exporter_exports.data[0] };
    wasm_extern_vec_t imports = { 1, import_externs };
    importer = zwasm_instance_new_ex(store_a, importer_module, &imports, &itrap, engine);
    if (refusal_is_binding_error(importer, itrap, who, "an export from another store") != 0) goto cleanup;
    rc = 0;

cleanup:
    /* The trap belongs to store A, so it goes before the stores do. The
     * exporter and its exports are untouched by a refused instantiation —
     * nothing was bound, and nothing was taken. */
    if (itrap) wasm_trap_delete(itrap);
    if (importer) wasm_instance_delete(importer);
    if (importer_module) wasm_module_delete(importer_module);
    if (exporter_exports.data) wasm_extern_vec_delete(&exporter_exports);
    if (exporter) wasm_instance_delete(exporter);
    if (exporter_module) wasm_module_delete(exporter_module);
    if (store_a) wasm_store_delete(store_a);
    if (store_b) wasm_store_delete(store_b);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* REGRESSION: the same two modules composed inside ONE store still link, and
 * the call through the import still returns the exporter's 7. */
static int wasm_export_binds_within_one_store(uint8_t engine) {
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
        fprintf(stderr, "[%s] the one-store composition was refused — the guard "
                        "fired on a binding inside a single store\n", who);
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
        fprintf(stderr, "[%s] the one-store cross-module call trapped\n", who);
        wasm_trap_delete(trap);
        goto cleanup;
    }
    if (results[0].kind != WASM_I32 || results[0].of.i32 != 7) {
        fprintf(stderr, "[%s] expected the exporter's 7, got kind=%d value=%d\n",
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

/* The other half of the guard: a standalone host callback has no source
 * instance, so the store it was created on is the only thing that says where it
 * belongs — and `wasm_func_delete` is the embedder's, but the payload the
 * binder points at is allocated out of that store's engine allocator. Created
 * on store B, imported in store A: refused. */
static int host_func_refused_across_stores(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    int32_t addend = 37;
    wasm_func_t* host_fn = NULL;
    wasm_module_t* importer_module = NULL;
    wasm_instance_t* importer = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store_a = eng ? wasm_store_new(eng) : NULL;
    wasm_store_t* store_b = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store_a || !store_b) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_functype_t* ft = wasm_functype_new_1_1(wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32));
    host_fn = wasm_func_new_with_env(store_b, ft, add_env, &addend, NULL);
    wasm_functype_delete(ft);
    if (!host_fn) { fprintf(stderr, "[%s] wasm_func_new_with_env failed on store B\n", who); goto cleanup; }

    wasm_byte_vec_t importer_binary = { sizeof(kHostImporterWasm), (wasm_byte_t*) kHostImporterWasm };
    importer_module = wasm_module_new(store_a, &importer_binary);
    if (!importer_module) { fprintf(stderr, "[%s] host-importer failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_func_as_extern(host_fn) };
    wasm_extern_vec_t imports = { 1, import_externs };
    importer = zwasm_instance_new_ex(store_a, importer_module, &imports, &itrap, engine);
    if (refusal_is_binding_error(importer, itrap, who, "a host callback from another store") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (itrap) wasm_trap_delete(itrap);
    if (importer) wasm_instance_delete(importer);
    if (importer_module) wasm_module_delete(importer_module);
    if (host_fn) wasm_func_delete(host_fn);
    if (store_a) wasm_store_delete(store_a);
    if (store_b) wasm_store_delete(store_b);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* REGRESSION: the same handle created on the store it is imported into still
 * binds, and the guest's `cb(5)` still reaches the callback's env for 42. */
static int host_func_binds_within_one_store(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    int32_t addend = 37;
    wasm_func_t* host_fn = NULL;
    wasm_module_t* importer_module = NULL;
    wasm_instance_t* importer = NULL;
    wasm_extern_vec_t importer_exports = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_functype_t* ft = wasm_functype_new_1_1(wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32));
    host_fn = wasm_func_new_with_env(store, ft, add_env, &addend, NULL);
    wasm_functype_delete(ft);
    if (!host_fn) { fprintf(stderr, "[%s] wasm_func_new_with_env failed\n", who); goto cleanup; }

    wasm_byte_vec_t importer_binary = { sizeof(kHostImporterWasm), (wasm_byte_t*) kHostImporterWasm };
    importer_module = wasm_module_new(store, &importer_binary);
    if (!importer_module) { fprintf(stderr, "[%s] host-importer failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_func_as_extern(host_fn) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    importer = zwasm_instance_new_ex(store, importer_module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!importer) {
        fprintf(stderr, "[%s] the one-store host import was refused — the guard "
                        "fired on a callback created on the importing store\n", who);
        goto cleanup;
    }
    wasm_instance_exports(importer, &importer_exports);
    if (importer_exports.size < 1 || !importer_exports.data[0] ||
        wasm_extern_kind(importer_exports.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] the host-importer is missing its `test` export\n", who);
        goto cleanup;
    }

    wasm_val_t results[1] = { { WASM_I32, { 0 } } };
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t res = { 1, results };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(importer_exports.data[0]), &no_args, &res);
    if (trap) {
        fprintf(stderr, "[%s] the one-store host call trapped\n", who);
        wasm_trap_delete(trap);
        goto cleanup;
    }
    if (results[0].kind != WASM_I32 || results[0].of.i32 != 42) {
        fprintf(stderr, "[%s] expected the callback's 42, got kind=%d value=%d\n",
                who, (int) results[0].kind, (int) results[0].of.i32);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (importer_exports.data) wasm_extern_vec_delete(&importer_exports);
    if (importer) wasm_instance_delete(importer);
    if (importer_module) wasm_module_delete(importer_module);
    if (host_fn) wasm_func_delete(host_fn);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* The same instance arm at a NON-func kind: store B's instance exports a
 * memory, and store A's module imports it. The kind is the point — a memory
 * import is not something the JIT binder can satisfy, so the store rule has to
 * be asked before that capability filter declines; otherwise a forced `.jit`
 * answers with a bare NULL and no trap while `auto` and `interp` name the
 * boundary.
 *
 * No same-store pair accompanies this one, unlike the two cases above. A
 * single-store memory import fails here for an unrelated, pre-existing reason:
 * on `auto` and `jit` the exporter instantiates JIT-backed, and the memory
 * binder needs the exporter's interp runtime, which a JIT-backed instance does
 * not have — so the one-store composition is refused on `auto` and `jit` and
 * links only on `interp`. That is a separate defect, and asserting it here
 * would tie this guard's case to it. */
static int memory_export_refused_across_stores(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* exporter_module = NULL;
    wasm_instance_t* exporter = NULL;
    wasm_extern_vec_t exporter_exports = { 0, NULL };
    wasm_module_t* importer_module = NULL;
    wasm_instance_t* importer = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store_a = eng ? wasm_store_new(eng) : NULL;
    wasm_store_t* store_b = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store_a || !store_b) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t exporter_binary = { sizeof(kMemExporterWasm), (wasm_byte_t*) kMemExporterWasm };
    exporter_module = wasm_module_new(store_b, &exporter_binary);
    if (!exporter_module) { fprintf(stderr, "[%s] memory exporter failed to parse\n", who); goto cleanup; }
    wasm_extern_vec_t no_imports = { 0, NULL };
    wasm_trap_t* etrap = NULL;
    exporter = zwasm_instance_new_ex(store_b, exporter_module, &no_imports, &etrap, engine);
    if (etrap) wasm_trap_delete(etrap);
    if (!exporter) { fprintf(stderr, "[%s] memory exporter failed to instantiate in store B\n", who); goto cleanup; }
    wasm_instance_exports(exporter, &exporter_exports);
    if (exporter_exports.size < 1 || !exporter_exports.data[0] ||
        wasm_extern_kind(exporter_exports.data[0]) != WASM_EXTERN_MEMORY) {
        fprintf(stderr, "[%s] the memory exporter is missing its `m` export\n", who);
        goto cleanup;
    }

    wasm_byte_vec_t importer_binary = { sizeof(kMemImporterWasm), (wasm_byte_t*) kMemImporterWasm };
    importer_module = wasm_module_new(store_a, &importer_binary);
    if (!importer_module) { fprintf(stderr, "[%s] memory importer failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { exporter_exports.data[0] };
    wasm_extern_vec_t imports = { 1, import_externs };
    importer = zwasm_instance_new_ex(store_a, importer_module, &imports, &itrap, engine);
    if (refusal_is_binding_error(importer, itrap, who, "a memory export from another store") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (itrap) wasm_trap_delete(itrap);
    if (importer) wasm_instance_delete(importer);
    if (importer_module) wasm_module_delete(importer_module);
    if (exporter_exports.data) wasm_extern_vec_delete(&exporter_exports);
    if (exporter) wasm_instance_delete(exporter);
    if (exporter_module) wasm_module_delete(exporter_module);
    if (store_a) wasm_store_delete(store_a);
    if (store_b) wasm_store_delete(store_b);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* The standalone arm at a NON-func kind: a `wasm_global_new` global created on
 * store B, imported by a module instantiating in store A. Its cell is store B's
 * (#446), so the binding would alias memory `wasm_store_delete` on B releases —
 * the same hazard the host-callback case above names, at a different kind. The
 * rule is asked before the JIT's capability filter, so all three engines name
 * the boundary rather than one of them declining with a bare NULL. */
static int host_global_refused_across_stores(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_globaltype_t* gt = NULL;
    wasm_global_t* hg = NULL;
    wasm_module_t* importer_module = NULL;
    wasm_instance_t* importer = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store_a = eng ? wasm_store_new(eng) : NULL;
    wasm_store_t* store_b = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store_a || !store_b) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    gt = wasm_globaltype_new(wasm_valtype_new(WASM_I32), WASM_CONST);
    wasm_val_t init = { WASM_I32, { 4919 } };
    hg = wasm_global_new(store_b, gt, &init);
    wasm_globaltype_delete(gt);
    gt = NULL;
    if (!hg) { fprintf(stderr, "[%s] wasm_global_new failed on store B\n", who); goto cleanup; }

    wasm_byte_vec_t importer_binary = { sizeof(kGlobalImporterWasm), (wasm_byte_t*) kGlobalImporterWasm };
    importer_module = wasm_module_new(store_a, &importer_binary);
    if (!importer_module) { fprintf(stderr, "[%s] global-importer failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { wasm_global_as_extern(hg) };
    wasm_extern_vec_t imports = { 1, import_externs };
    importer = zwasm_instance_new_ex(store_a, importer_module, &imports, &itrap, engine);
    if (refusal_is_binding_error(importer, itrap, who, "a host global from another store") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (itrap) wasm_trap_delete(itrap);
    if (importer) wasm_instance_delete(importer);
    if (importer_module) wasm_module_delete(importer_module);
    if (hg) wasm_global_delete(hg);
    if (gt) wasm_globaltype_delete(gt);
    if (store_a) wasm_store_delete(store_a);
    if (store_b) wasm_store_delete(store_b);
    if (eng) wasm_engine_delete(eng);
    return rc;
}


/* What a kind mismatch must look like: a bare NULL. The binder refuses on the
 * declaration's kind before it has anything to say about where the extern came
 * from, so no trap is produced. Ownership stays with the caller, as above. */
static int refusal_is_bare_null(const wasm_instance_t* instance, const wasm_trap_t* trap,
                                const char* who, const char* label) {
    if (instance) {
        fprintf(stderr, "[%s] %s: instantiated with an extern of the wrong kind\n", who, label);
        return 1;
    }
    if (trap) {
        fprintf(stderr, "[%s] %s: refused with trap kind %d — the store boundary was "
                        "reported over the kind mismatch\n",
                who, label, (int) zwasm_trap_kind(trap));
        return 1;
    }
    return 0;
}

/* The kind outranks the store rule. Store B's instance exports a MEMORY; store
 * A's module declares its single import as a FUNC and is handed that memory.
 * Both rules could answer — wrong kind, and another store — and the kind is the
 * one that must: NULL, no trap. Paired with the same feed inside ONE store
 * below; the two must agree, because an extern of the wrong kind never binds
 * and where it came from cannot change that. */
static int kind_mismatch_outranks_the_store_rule(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* exporter_module = NULL;
    wasm_instance_t* exporter = NULL;
    wasm_extern_vec_t exporter_exports = { 0, NULL };
    wasm_module_t* importer_module = NULL;
    wasm_instance_t* importer = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store_a = eng ? wasm_store_new(eng) : NULL;
    wasm_store_t* store_b = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store_a || !store_b) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t exporter_binary = { sizeof(kMemExporterWasm), (wasm_byte_t*) kMemExporterWasm };
    exporter_module = wasm_module_new(store_b, &exporter_binary);
    if (!exporter_module) { fprintf(stderr, "[%s] memory exporter failed to parse\n", who); goto cleanup; }
    wasm_extern_vec_t no_imports = { 0, NULL };
    wasm_trap_t* etrap = NULL;
    exporter = zwasm_instance_new_ex(store_b, exporter_module, &no_imports, &etrap, engine);
    if (etrap) wasm_trap_delete(etrap);
    if (!exporter) { fprintf(stderr, "[%s] memory exporter failed to instantiate in store B\n", who); goto cleanup; }
    wasm_instance_exports(exporter, &exporter_exports);
    if (exporter_exports.size < 1 || !exporter_exports.data[0] ||
        wasm_extern_kind(exporter_exports.data[0]) != WASM_EXTERN_MEMORY) {
        fprintf(stderr, "[%s] the memory exporter is missing its `m` export\n", who);
        goto cleanup;
    }

    /* The func-importing module from the first case: `(import "e" "get" (func
     * (result i32)))`. Feeding it a memory extern is the mismatch. */
    wasm_byte_vec_t importer_binary = { sizeof(kImporterWasm), (wasm_byte_t*) kImporterWasm };
    importer_module = wasm_module_new(store_a, &importer_binary);
    if (!importer_module) { fprintf(stderr, "[%s] importer failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { exporter_exports.data[0] };
    wasm_extern_vec_t imports = { 1, import_externs };
    importer = zwasm_instance_new_ex(store_a, importer_module, &imports, &itrap, engine);
    if (refusal_is_bare_null(importer, itrap, who, "a memory extern in a func slot, across stores") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (itrap) wasm_trap_delete(itrap);
    if (importer) wasm_instance_delete(importer);
    if (importer_module) wasm_module_delete(importer_module);
    if (exporter_exports.data) wasm_extern_vec_delete(&exporter_exports);
    if (exporter) wasm_instance_delete(exporter);
    if (exporter_module) wasm_module_delete(exporter_module);
    if (store_a) wasm_store_delete(store_a);
    if (store_b) wasm_store_delete(store_b);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* The same feed with NO boundary to cross: both modules in ONE store, the
 * memory extern still in the func slot. The outcome must be the one above,
 * byte for byte — NULL, no trap. The pairing is the assertion: if the boundary
 * could change the answer, the kind is not what decided it. */
static int kind_mismatch_refused_within_one_store(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* exporter_module = NULL;
    wasm_instance_t* exporter = NULL;
    wasm_extern_vec_t exporter_exports = { 0, NULL };
    wasm_module_t* importer_module = NULL;
    wasm_instance_t* importer = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t exporter_binary = { sizeof(kMemExporterWasm), (wasm_byte_t*) kMemExporterWasm };
    exporter_module = wasm_module_new(store, &exporter_binary);
    if (!exporter_module) { fprintf(stderr, "[%s] memory exporter failed to parse\n", who); goto cleanup; }
    wasm_extern_vec_t no_imports = { 0, NULL };
    wasm_trap_t* etrap = NULL;
    exporter = zwasm_instance_new_ex(store, exporter_module, &no_imports, &etrap, engine);
    if (etrap) wasm_trap_delete(etrap);
    if (!exporter) { fprintf(stderr, "[%s] memory exporter failed to instantiate\n", who); goto cleanup; }
    wasm_instance_exports(exporter, &exporter_exports);
    if (exporter_exports.size < 1 || !exporter_exports.data[0] ||
        wasm_extern_kind(exporter_exports.data[0]) != WASM_EXTERN_MEMORY) {
        fprintf(stderr, "[%s] the memory exporter is missing its `m` export\n", who);
        goto cleanup;
    }

    wasm_byte_vec_t importer_binary = { sizeof(kImporterWasm), (wasm_byte_t*) kImporterWasm };
    importer_module = wasm_module_new(store, &importer_binary);
    if (!importer_module) { fprintf(stderr, "[%s] importer failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { exporter_exports.data[0] };
    wasm_extern_vec_t imports = { 1, import_externs };
    importer = zwasm_instance_new_ex(store, importer_module, &imports, &itrap, engine);
    if (refusal_is_bare_null(importer, itrap, who, "a memory extern in a func slot, one store") != 0) goto cleanup;
    rc = 0;

cleanup:
    if (itrap) wasm_trap_delete(itrap);
    if (importer) wasm_instance_delete(importer);
    if (importer_module) wasm_module_delete(importer_module);
    if (exporter_exports.data) wasm_extern_vec_delete(&exporter_exports);
    if (exporter) wasm_instance_delete(exporter);
    if (exporter_module) wasm_module_delete(exporter_module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* The exemption: a `wasi_snapshot_preview1` slot is outside the store rule.
 * Store A has a WASI host, so its `fd_write` import is satisfied from that host
 * and the embedder's slot for it is never read. Store B's `get` extern is put
 * in that one slot anyway — the boundary it would cross is never crossed,
 * because nothing is bound from it. All three engines must instantiate; the
 * precheck that walked the slot refused on `auto` and `jit` (and `Final`, so
 * `auto` did not fall back to the interp that accepted it). */
static int wasi_slot_is_exempt_from_the_store_rule(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* exporter_module = NULL;
    wasm_instance_t* exporter = NULL;
    wasm_extern_vec_t exporter_exports = { 0, NULL };
    wasm_module_t* importer_module = NULL;
    wasm_instance_t* importer = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store_a = eng ? wasm_store_new(eng) : NULL;
    wasm_store_t* store_b = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store_a || !store_b) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
    if (!cfg) { fprintf(stderr, "[%s] wasi config new failed\n", who); goto cleanup; }
    zwasm_store_set_wasi(store_a, cfg); /* takes ownership */

    wasm_byte_vec_t exporter_binary = { sizeof(kExporterWasm), (wasm_byte_t*) kExporterWasm };
    exporter_module = wasm_module_new(store_b, &exporter_binary);
    if (!exporter_module) { fprintf(stderr, "[%s] exporter failed to parse\n", who); goto cleanup; }
    wasm_extern_vec_t no_imports = { 0, NULL };
    wasm_trap_t* etrap = NULL;
    exporter = zwasm_instance_new_ex(store_b, exporter_module, &no_imports, &etrap, engine);
    if (etrap) wasm_trap_delete(etrap);
    if (!exporter) { fprintf(stderr, "[%s] exporter failed to instantiate in store B\n", who); goto cleanup; }
    wasm_instance_exports(exporter, &exporter_exports);
    if (exporter_exports.size < 1 || !exporter_exports.data[0]) {
        fprintf(stderr, "[%s] exporter exposed nothing\n", who);
        goto cleanup;
    }

    wasm_byte_vec_t importer_binary = { sizeof(kWasiImporterWasm), (wasm_byte_t*) kWasiImporterWasm };
    importer_module = wasm_module_new(store_a, &importer_binary);
    if (!importer_module) { fprintf(stderr, "[%s] wasi-importer failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { exporter_exports.data[0] };
    wasm_extern_vec_t imports = { 1, import_externs };
    importer = zwasm_instance_new_ex(store_a, importer_module, &imports, &itrap, engine);
    if (!importer) {
        wasm_message_t msg = { 0, NULL };
        if (itrap) wasm_trap_message(itrap, &msg);
        fprintf(stderr, "[%s] a WASI import slot was subjected to the store rule: "
                        "refused with trap kind %d \"%.*s\"\n",
                who, itrap ? (int) zwasm_trap_kind(itrap) : -1,
                msg.data ? (int) msg.size : 0, msg.data ? msg.data : "");
        if (msg.data) wasm_byte_vec_delete(&msg);
        goto cleanup;
    }
    if (itrap) {
        fprintf(stderr, "[%s] the WASI-import instance came back with a trap\n", who);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (itrap) wasm_trap_delete(itrap);
    if (importer) wasm_instance_delete(importer);
    if (importer_module) wasm_module_delete(importer_module);
    if (exporter_exports.data) wasm_extern_vec_delete(&exporter_exports);
    if (exporter) wasm_instance_delete(exporter);
    if (exporter_module) wasm_module_delete(exporter_module);
    if (store_a) wasm_store_delete(store_a);
    if (store_b) wasm_store_delete(store_b);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* The edge of that exemption: the preview1 MODULE name is not the exemption.
 * `custom` is a field the JIT plants for nobody, so `collectFromExterns` reads
 * the embedder's slot and binds what is in it — here store B's `get`. A skip by
 * module name let exactly this through, and deleting store B then left the
 * importer calling freed code (exit 70, on `auto` and `jit`). The store rule
 * must be asked for an unplanted slot.
 *
 * The engines split on WHY it is refused, so the assertion splits too. On
 * `auto` and `jit` the store rule is what answers, with a BINDING_ERROR naming
 * the boundary. `interp` never gets that far: `buildBindings` serves every
 * preview1 name from the store's WASI host and has no thunk for `custom`, so it
 * refuses earlier and for a reason of its own — NULL with NO trap. Requiring a
 * trap there would assert the interpreter's error path, not this guard, so only
 * the refusal itself is asserted on `interp`. */
static int unknown_wasi_field_is_not_exempt(uint8_t engine) {
    int rc = 1;
    const char* who = engine_name(engine);
    wasm_module_t* exporter_module = NULL;
    wasm_instance_t* exporter = NULL;
    wasm_extern_vec_t exporter_exports = { 0, NULL };
    wasm_module_t* importer_module = NULL;
    wasm_instance_t* importer = NULL;
    wasm_trap_t* itrap = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store_a = eng ? wasm_store_new(eng) : NULL;
    wasm_store_t* store_b = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store_a || !store_b) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
    if (!cfg) { fprintf(stderr, "[%s] wasi config new failed\n", who); goto cleanup; }
    zwasm_store_set_wasi(store_a, cfg); /* takes ownership */

    wasm_byte_vec_t exporter_binary = { sizeof(kExporterWasm), (wasm_byte_t*) kExporterWasm };
    exporter_module = wasm_module_new(store_b, &exporter_binary);
    if (!exporter_module) { fprintf(stderr, "[%s] exporter failed to parse\n", who); goto cleanup; }
    wasm_extern_vec_t no_imports = { 0, NULL };
    wasm_trap_t* etrap = NULL;
    exporter = zwasm_instance_new_ex(store_b, exporter_module, &no_imports, &etrap, engine);
    if (etrap) wasm_trap_delete(etrap);
    if (!exporter) { fprintf(stderr, "[%s] exporter failed to instantiate in store B\n", who); goto cleanup; }
    wasm_instance_exports(exporter, &exporter_exports);
    if (exporter_exports.size < 1 || !exporter_exports.data[0]) {
        fprintf(stderr, "[%s] exporter exposed nothing\n", who);
        goto cleanup;
    }

    wasm_byte_vec_t importer_binary = {
        sizeof(kWasiUnknownImporterWasm), (wasm_byte_t*) kWasiUnknownImporterWasm
    };
    importer_module = wasm_module_new(store_a, &importer_binary);
    if (!importer_module) { fprintf(stderr, "[%s] wasi-unknown importer failed to parse\n", who); goto cleanup; }
    wasm_extern_t* import_externs[1] = { exporter_exports.data[0] };
    wasm_extern_vec_t imports = { 1, import_externs };
    importer = zwasm_instance_new_ex(store_a, importer_module, &imports, &itrap, engine);
    if (engine == ZWASM_ENGINE_INTERP) {
        if (importer) {
            fprintf(stderr, "[%s] an unknown WASI field bound an extern from another store\n", who);
            goto cleanup;
        }
    } else if (refusal_is_binding_error(importer, itrap, who,
                                        "an unknown WASI field fed from another store") != 0) {
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (itrap) wasm_trap_delete(itrap);
    if (importer) wasm_instance_delete(importer);
    if (importer_module) wasm_module_delete(importer_module);
    if (exporter_exports.data) wasm_extern_vec_delete(&exporter_exports);
    if (exporter) wasm_instance_delete(exporter);
    if (exporter_module) wasm_module_delete(exporter_module);
    if (store_a) wasm_store_delete(store_a);
    if (store_b) wasm_store_delete(store_b);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    for (size_t i = 0; i < sizeof(kEngines) / sizeof(kEngines[0]); i++) {
        if (wasm_export_refused_across_stores(kEngines[i]) != 0) return 1;
        if (wasm_export_binds_within_one_store(kEngines[i]) != 0) return 1;
        if (host_func_refused_across_stores(kEngines[i]) != 0) return 1;
        if (host_func_binds_within_one_store(kEngines[i]) != 0) return 1;
        if (memory_export_refused_across_stores(kEngines[i]) != 0) return 1;
        if (host_global_refused_across_stores(kEngines[i]) != 0) return 1;
        if (kind_mismatch_outranks_the_store_rule(kEngines[i]) != 0) return 1;
        if (kind_mismatch_refused_within_one_store(kEngines[i]) != 0) return 1;
        if (wasi_slot_is_exempt_from_the_store_rule(kEngines[i]) != 0) return 1;
        if (unknown_wasi_field_is_not_exempt(kEngines[i]) != 0) return 1;
    }
    return 0;
}
