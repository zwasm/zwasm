/* zwasm v2 — minimal C host example (§9.3 / 3.8)
 *
 * Drives the binding end-to-end through the standard wasm-c-api
 * surface: engine -> store -> module -> instance -> exports ->
 * func_call. The wasm payload is a hand-rolled
 *
 *   (module (func (export "main") (result i32) (i32.const 42)))
 *
 * — embedded as a byte array so the example stays import-free
 * (no WASI dependency, no external assembler / wabt step).
 *
 * `zig build test-c-api` builds libzwasm.a and this example and runs it.
 * To compile it the way an embedder would — against the installed archive
 * and headers rather than through the build script:
 *
 *   zig build static-lib -Doptimize=ReleaseSafe -Dcompiler-rt=true
 *   cc -I zig-out/include docs/examples/c_host/hello.c \
 *      zig-out/lib/libzwasm.a -lm -Wl,-z,noexecstack -o c_host
 *
 * What each flag is for: docs/tutorial.md section 5.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>

/* (module (func (export "main") (result i32) (i32.const 42))) */
static const uint8_t kHelloWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x08, 0x01, 0x04, 0x6D, 0x61, 0x69, 0x6E, 0x00, 0x00,
    0x0A, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2A, 0x0B,
};

static void print_trap_and_delete(wasm_trap_t* trap) {
    if (!trap) return;
    wasm_message_t msg;
    wasm_trap_message(trap, &msg);
    fprintf(stderr, "trap: %.*s\n", (int)msg.size, msg.data);
    wasm_byte_vec_delete(&msg);
    wasm_trap_delete(trap);
}

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = NULL;
    wasm_store_t* store = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };

    engine = wasm_engine_new();
    if (!engine) { fputs("wasm_engine_new failed\n", stderr); goto cleanup; }

    store = wasm_store_new(engine);
    if (!store) { fputs("wasm_store_new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary;
    binary.size = sizeof(kHelloWasm);
    binary.data = (wasm_byte_t*) kHelloWasm;
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* instantiation_trap = NULL;
    instance = wasm_instance_new(store, module, &imports, &instantiation_trap);
    if (!instance) {
        fputs("wasm_instance_new failed\n", stderr);
        print_trap_and_delete(instantiation_trap);
        goto cleanup;
    }

    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || exports.data == NULL) {
        fputs("module declared no exports\n", stderr);
        goto cleanup;
    }

    wasm_extern_t* main_extern = exports.data[0];
    if (!main_extern || wasm_extern_kind(main_extern) != WASM_EXTERN_FUNC) {
        fputs("first export is not a func\n", stderr);
        goto cleanup;
    }
    wasm_func_t* main_fn = wasm_extern_as_func(main_extern);
    if (!main_fn) { fputs("wasm_extern_as_func failed\n", stderr); goto cleanup; }

    wasm_val_t results_data[1];
    memset(results_data, 0, sizeof(results_data));
    wasm_val_vec_t results;
    results.size = 1;
    results.data = results_data;
    wasm_val_vec_t args = { 0, NULL };

    wasm_trap_t* call_trap = wasm_func_call(main_fn, &args, &results);
    if (call_trap) {
        print_trap_and_delete(call_trap);
        goto cleanup;
    }

    if (results_data[0].kind != WASM_I32) {
        fprintf(stderr, "result kind %u != WASM_I32\n", results_data[0].kind);
        goto cleanup;
    }

    printf("zwasm c_host: main() returned %d\n", results_data[0].of.i32);
    rc = (results_data[0].of.i32 == 42) ? 0 : 2;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
