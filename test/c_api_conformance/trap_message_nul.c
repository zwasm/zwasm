/* zwasm v2 — C-API conformance: a trap message is NUL-terminated and its size
 * counts the NUL (issue #441).
 *
 * `include/wasm.h:393` types the out-parameter as
 * `typedef wasm_name_t wasm_message_t;  // null terminated`. Upstream spells
 * the same string two ways — `wasm_name_new_from_string` sizes it `strlen(s)`,
 * `wasm_name_new_from_string_nt` sizes it `strlen(s) + 1` — and
 * `wasm_message_t` is the `_nt` shape. So `size` includes the NUL and a C host
 * may read the vector with `strstr` / `printf("%s")` without running off the
 * allocation.
 *
 * Two probes:
 *   1. A guest trap's message: `strlen(data) == size - 1` and `data[size-1]`
 *      is 0. Before #441 this read `strlen=42` against `size=36`.
 *   2. Round-trip through `wasm_trap_new`: a host hands its message in both
 *      shapes (body only, and body + NUL) and gets the same size back, so a
 *      message crossing the boundary twice does not grow a NUL per trip.
 *
 * Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (func (export "boom") unreachable)) */
static const uint8_t kGuest[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x08, 0x01, 0x04, 0x62, 0x6f, 0x6f, 0x6d, 0x00, 0x00,
    0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b,
};

/* Asserts the contract on one message vector; consumes it. */
static int check(wasm_message_t* msg, const char* what) {
    if (!msg->data || msg->size == 0) {
        fprintf(stderr, "%s: empty message vector\n", what);
        return 0;
    }
    if (msg->data[msg->size - 1] != '\0') {
        fprintf(stderr, "%s: last byte is %d, not the NUL wasm.h declares\n",
                what, (int) (unsigned char) msg->data[msg->size - 1]);
        return 0;
    }
    size_t len = strlen(msg->data);
    if (len != msg->size - 1) {
        fprintf(stderr, "%s: strlen %zu != size - 1 (%zu) — the string runs past the vector\n",
                what, len, msg->size - 1);
        return 0;
    }
    printf("trap_message_nul: %s -> size=%zu strlen=%zu \"%s\"\n", what, msg->size, len, msg->data);
    return 1;
}

/* A guest `unreachable`: the message zwasm itself produced. */
static int probe_guest_trap(wasm_store_t* store) {
    int ok = 0;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };

    wasm_byte_vec_t binary = { sizeof(kGuest), (wasm_byte_t*) kGuest };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }
    wasm_extern_vec_t imports = { 0, NULL };
    instance = wasm_instance_new(store, module, &imports, NULL);
    if (!instance) { fputs("instantiate failed\n", stderr); goto cleanup; }
    wasm_instance_exports(instance, &exports);
    if (exports.size < 1) { fputs("missing export\n", stderr); goto cleanup; }

    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t no_res = { 0, NULL };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(exports.data[0]), &no_args, &no_res);
    if (!trap) { fputs("boom did not trap\n", stderr); goto cleanup; }
    wasm_message_t msg;
    wasm_trap_message(trap, &msg);
    ok = check(&msg, "guest trap");
    wasm_byte_vec_delete(&msg);
    wasm_trap_delete(trap);

cleanup:
    wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    return ok;
}

/* A host message in, the same message out — at the same length either way.
 * `nt` selects the `wasm_name_new_from_string_nt` shape (NUL inside size). */
static int probe_round_trip(wasm_store_t* store, int nt, const char* what) {
    static const char kText[] = "host said no";
    wasm_byte_vec_t in = { nt ? sizeof(kText) : sizeof(kText) - 1, (wasm_byte_t*) kText };
    wasm_trap_t* trap = wasm_trap_new(store, &in);
    if (!trap) { fprintf(stderr, "%s: wasm_trap_new failed\n", what); return 0; }

    wasm_message_t msg;
    wasm_trap_message(trap, &msg);
    int ok = check(&msg, what);
    if (ok && msg.size != sizeof(kText)) {
        fprintf(stderr, "%s: size %zu != %zu — the round trip changed the length\n",
                what, msg.size, sizeof(kText));
        ok = 0;
    }
    if (ok && strcmp(msg.data, kText) != 0) {
        fprintf(stderr, "%s: message came back as \"%s\"\n", what, msg.data);
        ok = 0;
    }
    wasm_byte_vec_delete(&msg);
    wasm_trap_delete(trap);
    return ok;
}

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    int ok = 1;
    ok &= probe_guest_trap(store);
    ok &= probe_round_trip(store, 0, "round trip, body only");
    ok &= probe_round_trip(store, 1, "round trip, body + NUL");
    if (ok) rc = 0;

cleanup:
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
