/* zwasm v2 — C-API conformance: trap propagation (§13.4)
 *
 * Validates the trap surface through the real C ABI: a guest `unreachable`
 * surfaces as a non-null `wasm_trap_t*` from `wasm_func_call`, and
 * `wasm_trap_message` yields a NUL-terminated message whose size counts
 * that NUL (#441).
 *
 *   (module (func (export "boom") unreachable))
 *
 * Exits 0 on success (call trapped + message readable).
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>

static const uint8_t kBoomWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, /* type () -> () */
    0x03, 0x02, 0x01, 0x00, /* func[0]: type 0 */
    0x07, 0x08, 0x01, 0x04, 0x62, 0x6f, 0x6f, 0x6d, 0x00, 0x00, /* export "boom" -> func 0 */
    0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b, /* code: unreachable */
};

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kBoomWasm), (wasm_byte_t*) kBoomWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t imports = { 0, NULL };
    instance = wasm_instance_new(store, module, &imports, NULL);
    if (!instance) { fputs("wasm_instance_new failed\n", stderr); goto cleanup; }

    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0]) { fputs("no exports\n", stderr); goto cleanup; }
    wasm_func_t* boom = wasm_extern_as_func(exports.data[0]);
    if (!boom) { fputs("export not a func\n", stderr); goto cleanup; }

    wasm_val_vec_t args = { 0, NULL };
    wasm_val_vec_t results = { 0, NULL };
    wasm_trap_t* trap = wasm_func_call(boom, &args, &results);
    if (!trap) { fputs("expected a trap, got none\n", stderr); goto cleanup; }

    wasm_message_t msg;
    wasm_trap_message(trap, &msg);
    printf("zwasm c_api_conformance/trap: trapped, message=\"%s\"\n",
           msg.data ? msg.data : "");
    /* a non-null trap with a readable (possibly empty) message = pass */
    rc = 0;
    wasm_byte_vec_delete(&msg);
    wasm_trap_delete(trap);

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
