/* zwasm v2 — C-API conformance: an invalid module is refused on AUTO and JIT
 * alike, with a trap that names the verdict (issue #233).
 *
 * Two modules the front-end validator lets through today (#285's remainder)
 * and the JIT's module-level check refuses:
 *
 *   (module (func $s (param i32)) (start $s))            ; start is not [] -> []
 *   (module (func) (export "a" (func 0)) (export "a" (func 0)))  ; duplicate export
 *
 * ZWASM_ENGINE_AUTO must not fall through to the interpreter on a validity
 * verdict, and ZWASM_ENGINE_JIT must not return a bare NULL: both return NULL
 * with a ZWASM_TRAP_INVALID_MODULE trap whose message names the reason.
 * ZWASM_ENGINE_INTERP's answer is not asserted (it changes when #285 closes,
 * and so does wasm_module_new's — then pick a module the JIT alone judges).
 *
 * Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

static const uint8_t kStartParam[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00, /* type (i32) -> () */
    0x03, 0x02, 0x01, 0x00, /* func 0: type 0 */
    0x08, 0x01, 0x00, /* start 0 */
    0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, /* code: end */
};

static const uint8_t kDupExport[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, /* type () -> () */
    0x03, 0x02, 0x01, 0x00, /* func 0: type 0 */
    0x07, 0x09, 0x02, 0x01, 0x61, 0x00, 0x00, 0x01, 0x61, 0x00, 0x00, /* export "a" twice */
    0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, /* code: end */
};

/* One (module, engine) probe: NULL instance + INVALID_MODULE trap naming `reason`. */
static int probe(wasm_store_t* store, const uint8_t* bytes, size_t len, uint8_t engine, const char* reason, const char* label) {
    int ok = 0;
    wasm_byte_vec_t binary = { len, (wasm_byte_t*) bytes };
    wasm_module_t* module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "%s: wasm_module_new refused the module (did #285 close? see the header)\n", label); return 0; }

    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* trap = NULL;
    wasm_instance_t* instance = zwasm_instance_new_ex(store, module, &imports, &trap, engine);
    if (instance) { fprintf(stderr, "%s: instantiated an invalid module\n", label); wasm_instance_delete(instance); goto done; }
    if (!trap) { fprintf(stderr, "%s: NULL with no trap\n", label); goto done; }
    if (zwasm_trap_kind(trap) != ZWASM_TRAP_INVALID_MODULE) { fprintf(stderr, "%s: trap kind %d != INVALID_MODULE\n", label, (int) zwasm_trap_kind(trap)); goto done; }
    {
        wasm_message_t msg;
        wasm_trap_message(trap, &msg);
        int named = msg.data && strstr(msg.data, reason) != NULL;
        if (!named) fprintf(stderr, "%s: trap message \"%s\" does not name %s\n", label, msg.data ? msg.data : "", reason);
        wasm_byte_vec_delete(&msg);
        if (!named) goto done;
    }
    printf("auto_rejects_invalid: %s -> NULL + INVALID_MODULE (%s)\n", label, reason);
    ok = 1;
done:
    if (trap) wasm_trap_delete(trap);
    wasm_module_delete(module);
    return ok;
}

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    int ok = 1;
    ok &= probe(store, kStartParam, sizeof(kStartParam), ZWASM_ENGINE_AUTO, "InvalidStartFunction", "start_param/AUTO");
    ok &= probe(store, kStartParam, sizeof(kStartParam), ZWASM_ENGINE_JIT, "InvalidStartFunction", "start_param/JIT");
    ok &= probe(store, kDupExport, sizeof(kDupExport), ZWASM_ENGINE_AUTO, "DuplicateExport", "dup_export/AUTO");
    ok &= probe(store, kDupExport, sizeof(kDupExport), ZWASM_ENGINE_JIT, "DuplicateExport", "dup_export/JIT");
    if (ok) rc = 0;

cleanup:
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
