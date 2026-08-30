/* zwasm v2 — C-API conformance: the trap kind describes the call just made (#336, #357)
 *
 * Contract pinned here: `zwasm_trap_kind` on the trap a `wasm_func_call`
 * returns names that call's own fault, on every engine and host arch, and
 * `zwasm_store_wasi_exit_code` reports a status only for a call that exited.
 * The JIT clears its per-runtime kind on every entry, and each trap site
 * routes to a stub that writes its precise kind, so nothing a previous call
 * left behind can leak into the next answer.
 *
 *   (module
 *     (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
 *     (type $t (func))
 *     (tag $x)
 *     (func $f (type $t) (nop))
 *     (func $thrower (throw $x))
 *     (table 1 funcref)
 *     (elem (i32.const 0) $f)
 *     (func (export "quit") (i32.const 3) (call $exit))
 *     (func (export "oops") (i32.const 99) (return_call_indirect (type $t)))
 *     (func (export "boom") (call $thrower))
 *     (func (export "nullref") (return_call_ref $t (ref.null $t))))
 *
 * Sequence per engine: `quit` (WASI_EXIT, status 3) → `oops`, a tail call
 * through index 99 of a one-entry table (OOB_TABLE, no status) → `quit` →
 * `boom`, a throw no frame catches (UNCAUGHT_EXCEPTION, no status) → `quit`
 * → `nullref`, a tail call through a null funcref (NULL_REFERENCE, no
 * status). Exits 0 when every kind and status is the expected one.
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include <wasm.h>
#include <zwasm.h>
#include <wasi.h>

static const uint8_t kGuest[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60,
    0x00, 0x00, 0x60, 0x01, 0x7f, 0x00, 0x02, 0x24, 0x01, 0x16, 0x77, 0x61,
    0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f,
    0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6f,
    0x63, 0x5f, 0x65, 0x78, 0x69, 0x74, 0x00, 0x01, 0x03, 0x07, 0x06, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00, 0x01, 0x0d,
    0x03, 0x01, 0x00, 0x00, 0x07, 0x20, 0x04, 0x04, 0x71, 0x75, 0x69, 0x74,
    0x00, 0x03, 0x04, 0x6f, 0x6f, 0x70, 0x73, 0x00, 0x04, 0x04, 0x62, 0x6f,
    0x6f, 0x6d, 0x00, 0x05, 0x07, 0x6e, 0x75, 0x6c, 0x6c, 0x72, 0x65, 0x66,
    0x00, 0x06, 0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x01, 0x0a,
    0x26, 0x06, 0x03, 0x00, 0x01, 0x0b, 0x04, 0x00, 0x08, 0x00, 0x0b, 0x06,
    0x00, 0x41, 0x03, 0x10, 0x00, 0x0b, 0x08, 0x00, 0x41, 0xe3, 0x00, 0x13,
    0x00, 0x00, 0x0b, 0x04, 0x00, 0x10, 0x02, 0x0b, 0x06, 0x00, 0xd0, 0x00,
    0x15, 0x00, 0x0b, 0x00, 0x26, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01, 0x13,
    0x03, 0x00, 0x04, 0x65, 0x78, 0x69, 0x74, 0x01, 0x01, 0x66, 0x02, 0x07,
    0x74, 0x68, 0x72, 0x6f, 0x77, 0x65, 0x72, 0x04, 0x04, 0x01, 0x00, 0x01,
    0x74, 0x0b, 0x04, 0x01, 0x00, 0x01, 0x78
};

static const char* engine_name(uint8_t kind) {
    switch (kind) {
    case ZWASM_ENGINE_AUTO: return "auto";
    case ZWASM_ENGINE_JIT: return "jit";
    case ZWASM_ENGINE_INTERP: return "interp";
    default: return "?";
    }
}

/* Calls export `idx` (no args, no results); returns the trap kind, or -1 when
 * the call did not trap. */
static int32_t call_kind(wasm_extern_vec_t* exports, size_t idx) {
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t no_res = { 0, NULL };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(exports->data[idx]), &no_args, &no_res);
    if (!trap) return -1;
    int32_t kind = zwasm_trap_kind(trap);
    wasm_trap_delete(trap);
    return kind;
}

static int run(uint8_t engine) {
    int rc = 1;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
    if (!cfg) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, cfg); /* takes ownership */

    wasm_byte_vec_t binary = { sizeof(kGuest), (wasm_byte_t*) kGuest };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) { fprintf(stderr, "[%s] instantiate failed\n", engine_name(engine)); goto cleanup; }
    wasm_instance_exports(instance, &exports);
    if (exports.size < 4) { fputs("missing exports\n", stderr); goto cleanup; }

    /* 1. quit: proc_exit(3) → WASI_EXIT, status 3. */
    int32_t k1 = call_kind(&exports, 0);
    uint32_t code1 = 0xdeadbeefu;
    bool has1 = zwasm_store_wasi_exit_code(store, &code1);
    if (k1 != ZWASM_TRAP_WASI_EXIT || !has1 || code1 != 3) {
        fprintf(stderr, "[%s] quit: kind=%d has=%d code=%u, want WASI_EXIT/true/3\n",
                engine_name(engine), (int) k1, (int) has1, code1);
        goto cleanup;
    }

    /* 2. oops: an ordinary guest fault after an exit — its own kind, no status. */
    int32_t k2 = call_kind(&exports, 1);
    uint32_t code = 0xdeadbeefu;
    bool has2 = zwasm_store_wasi_exit_code(store, &code);
    if (k2 < 0) { fprintf(stderr, "[%s] oops did not trap\n", engine_name(engine)); goto cleanup; }
    if (k2 != ZWASM_TRAP_OOB_TABLE || has2) {
        fprintf(stderr, "[%s] oops: kind=%d has=%d, want OOB_TABLE (%d) with no status\n",
                engine_name(engine), (int) k2, (int) has2, ZWASM_TRAP_OOB_TABLE);
        goto cleanup;
    }
    /* 3. quit again, then boom: an uncaught throw reports its own kind. */
    if (call_kind(&exports, 0) != ZWASM_TRAP_WASI_EXIT) { fprintf(stderr, "[%s] second quit\n", engine_name(engine)); goto cleanup; }
    int32_t k3 = call_kind(&exports, 2);
    code = 0xdeadbeefu;
    bool has3 = zwasm_store_wasi_exit_code(store, &code);
    if (k3 < 0) { fprintf(stderr, "[%s] boom did not trap\n", engine_name(engine)); goto cleanup; }
    if (k3 != ZWASM_TRAP_UNCAUGHT_EXCEPTION || has3) {
        fprintf(stderr, "[%s] boom: kind=%d has=%d, want UNCAUGHT_EXCEPTION (%d) with no status\n",
                engine_name(engine), (int) k3, (int) has3, ZWASM_TRAP_UNCAUGHT_EXCEPTION);
        goto cleanup;
    }
    /* 4. quit again, then nullref: a tail call through a null funcref. */
    if (call_kind(&exports, 0) != ZWASM_TRAP_WASI_EXIT) { fprintf(stderr, "[%s] third quit\n", engine_name(engine)); goto cleanup; }
    int32_t k4 = call_kind(&exports, 3);
    code = 0xdeadbeefu;
    bool has4 = zwasm_store_wasi_exit_code(store, &code);
    if (k4 != ZWASM_TRAP_NULL_REFERENCE || has4) {
        fprintf(stderr, "[%s] nullref: kind=%d has=%d, want NULL_REFERENCE (%d) with no status\n",
                engine_name(engine), (int) k4, (int) has4, ZWASM_TRAP_NULL_REFERENCE);
        goto cleanup;
    }
    printf("[%s] quit kind=%d code=%u; oops kind=%d; boom kind=%d; nullref kind=%d (no status) — ok\n",
           engine_name(engine), (int) k1, code1, (int) k2, (int) k3, (int) k4);
    rc = 0;

cleanup:
    wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    const uint8_t engines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };
    for (size_t i = 0; i < sizeof(engines); i++) {
        if (run(engines[i]) != 0) return 1;
    }
    return 0;
}
