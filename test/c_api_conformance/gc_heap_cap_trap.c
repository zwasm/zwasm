/* zwasm v2 — C-API conformance: a GC heap-cap trap is OUT_OF_MEMORY (#361)
 *
 *   (module
 *     (type $a (array (mut i32)))
 *     (func (export "huge") (result i32)
 *       (drop (array.new_default $a (i32.const 0x7fffffff)))
 *       (i32.const 42)))
 *
 * The array asks for ~8 GiB, past the GC heap's 4 GiB cap. The Zig API
 * reports that as OutOfMemory; the C surface used to report
 * ZWASM_TRAP_BINDING_ERROR ("host invocation error") for the same condition,
 * telling the host its own import wiring broke. Interpreter only: the JIT
 * does not trap on the cap at all (#364), and this case grows a JIT lane when
 * that lands.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include <wasm.h>
#include <zwasm.h>

static const uint8_t kGuest[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x5e,
    0x7f, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07, 0x08,
    0x01, 0x04, 0x68, 0x75, 0x67, 0x65, 0x00, 0x00, 0x0a, 0x10, 0x01, 0x0e,
    0x00, 0x41, 0xff, 0xff, 0xff, 0xff, 0x07, 0xfb, 0x07, 0x00, 0x1a, 0x41,
    0x2a, 0x0b,
};

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kGuest), (wasm_byte_t*) kGuest };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, ZWASM_ENGINE_INTERP);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) { fputs("instantiate failed\n", stderr); goto cleanup; }
    wasm_instance_exports(instance, &exports);
    if (exports.size < 1) { fputs("missing export\n", stderr); goto cleanup; }

    wasm_val_t res[1];
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t results = { 1, res };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(exports.data[0]), &no_args, &results);
    if (!trap) { fputs("huge did not trap\n", stderr); goto cleanup; }
    int32_t kind = zwasm_trap_kind(trap);
    wasm_trap_delete(trap);
    if (kind != ZWASM_TRAP_OUT_OF_MEMORY) {
        fprintf(stderr, "kind=%d, want ZWASM_TRAP_OUT_OF_MEMORY (%d)\n", (int) kind, ZWASM_TRAP_OUT_OF_MEMORY);
        goto cleanup;
    }
    puts("gc heap cap → OUT_OF_MEMORY — ok");
    rc = 0;

cleanup:
    wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
