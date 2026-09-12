/* zwasm v2 — C-API conformance: a call shape the engine cannot marshal traps
 * ZWASM_TRAP_UNSUPPORTED, not ZWASM_TRAP_BINDING_ERROR (issue #431).
 *
 *   (module
 *     (func (export "pair") (result i32 f32) i32.const 1 f32.const 2)
 *     (func (export "id") (param i32) (result i32) local.get 0))
 *
 * `pair` returns a mixed multi-value: the JIT emits wrapper thunks for the
 * 2-int register-class and 3-int MEMORY-class shapes only, so it has no entry
 * helper for this one. The binding is right and the module is valid — the
 * engine simply cannot make the call, which is its own kind. The message names
 * the shape.
 *
 * Four probes:
 *   JIT    `pair` -> UNSUPPORTED, message naming "(i32 f32)"
 *   AUTO   `pair` -> UNSUPPORTED — a decline at call time cannot fall back,
 *                    the instance is already JIT-backed (ADR-0229 covers the
 *                    instantiation-time decline, not this one)
 *   INTERP `pair` -> no trap, 1 and 2.0 — the decline is the engine's, not the
 *                    module's
 *   JIT    `id` with no argument -> BINDING_ERROR, unchanged: an argument count
 *                    that is not the signature's is still the embedder's own
 *
 * Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

static const uint8_t kGuest[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0b, 0x02, 0x60, 0x00, 0x02, 0x7f, 0x7d, /* type 0: () -> (i32 f32) */
    0x60, 0x01, 0x7f, 0x01, 0x7f, /* type 1: (i32) -> (i32) */
    0x03, 0x03, 0x02, 0x00, 0x01, /* func 0: type 0, func 1: type 1 */
    0x07, 0x0d, 0x02, 0x04, 0x70, 0x61, 0x69, 0x72, 0x00, 0x00,
    0x02, 0x69, 0x64, 0x00, 0x01, /* export "pair" -> 0, "id" -> 1 */
    0x0a, 0x10, 0x02,
    0x09, 0x00, 0x41, 0x01, 0x43, 0x00, 0x00, 0x00, 0x40, 0x0b, /* i32.const 1; f32.const 2 */
    0x04, 0x00, 0x20, 0x00, 0x0b, /* local.get 0 */
};

static const char* engine_name(uint8_t kind) {
    switch (kind) {
    case ZWASM_ENGINE_AUTO: return "auto";
    case ZWASM_ENGINE_JIT: return "jit";
    case ZWASM_ENGINE_INTERP: return "interp";
    default: return "?";
    }
}

/* Instantiate on `engine` and call export `idx` with `args`. Writes the trap
 * kind to *kind_out (-1 when the call did not trap) and the trap's message to
 * `msg_out` (empty when there was none). Returns 1 on success. */
static int call_export(uint8_t engine, size_t idx, wasm_val_vec_t* args, wasm_val_vec_t* results,
                       int32_t* kind_out, char* msg_out, size_t msg_cap) {
    int ok = 0;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kGuest), (wasm_byte_t*) kGuest };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) { fprintf(stderr, "[%s] instantiate failed\n", engine_name(engine)); goto cleanup; }

    wasm_instance_exports(instance, &exports);
    if (exports.size < 2) { fputs("missing exports\n", stderr); goto cleanup; }

    msg_out[0] = '\0';
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(exports.data[idx]), args, results);
    if (!trap) {
        *kind_out = -1;
    } else {
        *kind_out = zwasm_trap_kind(trap);
        wasm_message_t msg;
        wasm_trap_message(trap, &msg);
        /* Copied by size, not read as a C string: zwasm's `wasm_trap_message`
         * returns exactly the message bytes, where `wasm.h` declares
         * `wasm_message_t` NUL-terminated (#441). */
        if (msg.data) {
            size_t n = msg.size < msg_cap - 1 ? msg.size : msg_cap - 1;
            memcpy(msg_out, msg.data, n);
            msg_out[n] = '\0';
        }
        wasm_byte_vec_delete(&msg);
        wasm_trap_delete(trap);
    }
    ok = 1;

cleanup:
    wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return ok;
}

/* `pair` on an engine that has no helper for its shape. */
static int probe_declines(uint8_t engine) {
    wasm_val_t rdata[2];
    wasm_val_vec_t args = { 0, NULL };
    wasm_val_vec_t results = { 2, rdata };
    int32_t kind = -2;
    char msg[256];
    if (!call_export(engine, 0, &args, &results, &kind, msg, sizeof(msg))) return 0;

    if (kind != ZWASM_TRAP_UNSUPPORTED) {
        fprintf(stderr, "[%s] pair: kind=%d, want UNSUPPORTED (%d)%s\n", engine_name(engine),
                (int) kind, ZWASM_TRAP_UNSUPPORTED,
                kind == ZWASM_TRAP_BINDING_ERROR ? " — the binding is right, the engine has no helper" : "");
        return 0;
    }
    if (strstr(msg, "(i32 f32)") == NULL) {
        fprintf(stderr, "[%s] pair: message \"%s\" does not name the shape\n", engine_name(engine), msg);
        return 0;
    }
    printf("trap_unsupported_shape: [%s] pair -> UNSUPPORTED (%s)\n", engine_name(engine), msg);
    return 1;
}

/* `pair` on the interpreter: both values come back. */
static int probe_runs(void) {
    wasm_val_t rdata[2];
    wasm_val_vec_t args = { 0, NULL };
    wasm_val_vec_t results = { 2, rdata };
    int32_t kind = -2;
    char msg[256];
    if (!call_export(ZWASM_ENGINE_INTERP, 0, &args, &results, &kind, msg, sizeof(msg))) return 0;

    if (kind != -1) { fprintf(stderr, "[interp] pair trapped with kind %d\n", (int) kind); return 0; }
    if (rdata[0].kind != WASM_I32 || rdata[0].of.i32 != 1 ||
        rdata[1].kind != WASM_F32 || rdata[1].of.f32 != 2.0f) {
        fprintf(stderr, "[interp] pair returned (%d, %f), want (1, 2.0)\n", (int) rdata[0].of.i32, (double) rdata[1].of.f32);
        return 0;
    }
    printf("trap_unsupported_shape: [interp] pair -> 1, 2.0\n");
    return 1;
}

/* `id` called with no argument: the embedder's own error, on the same engine
 * that declines `pair`. The contrast is the point — one kind must not absorb
 * the other. */
static int probe_binding_error(void) {
    wasm_val_t rdata[1];
    wasm_val_vec_t args = { 0, NULL };
    wasm_val_vec_t results = { 1, rdata };
    int32_t kind = -2;
    char msg[256];
    if (!call_export(ZWASM_ENGINE_JIT, 1, &args, &results, &kind, msg, sizeof(msg))) return 0;

    if (kind != ZWASM_TRAP_BINDING_ERROR) {
        fprintf(stderr, "[jit] id with no argument: kind=%d, want BINDING_ERROR (%d)\n",
                (int) kind, ZWASM_TRAP_BINDING_ERROR);
        return 0;
    }
    printf("trap_unsupported_shape: [jit] id with no argument -> BINDING_ERROR\n");
    return 1;
}

int main(void) {
    int ok = 1;
    ok &= probe_declines(ZWASM_ENGINE_JIT);
    ok &= probe_declines(ZWASM_ENGINE_AUTO);
    ok &= probe_runs();
    ok &= probe_binding_error();
    return ok ? 0 : 1;
}
