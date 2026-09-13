/* zwasm v2 — C-API conformance: an instance says which engine runs it
 * (ADR-0200 D3).
 *
 * `ZWASM_ENGINE_AUTO` runs a module the JIT declines on the interpreter
 * without telling the embedder, so a host that reports per-engine numbers (a
 * benchmark row, an SDK's engine selector) needs the resolved kind read back.
 * `zwasm_instance_engine` answers JIT or INTERP, never AUTO.
 *
 * The declined module is convention-independent on purpose: its callee returns
 * THREE results, and no calling convention returns three values in registers,
 * so `tailFrameCanCarry` refuses it on x86_64 and arm64 alike. An
 * overflow-argument module would not do — the register budget differs per ABI
 * (SysV 5 user int args, Win64 3, AAPCS64 7).
 *
 * Exits 0 on success.
 */

#include <stdio.h>
#include <stdint.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (func (export "add") (param i32 i32) (result i32)
 *   local.get 0 local.get 1 i32.add)) — the JIT compiles this. */
static const uint8_t kAdd[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, /* type (i32 i32) -> i32 */
    0x03, 0x02, 0x01, 0x00, /* func 0: type 0 */
    0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, /* export "add" */
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
};

/* (module (func $tri (param i32) (result i32 i32 i32) local.get 0 i32.const 2 i32.const 3)
 *         (func $tail (result i32 i32 i32) i32.const 1 return_call $tri)
 *         (func (export "go") (result i32) call $tail i32.add i32.add))
 * The MEMORY-class tail-call callee the JIT declines on every convention
 * (#424); the interpreter runs it. Shares its bytes with
 * `src/engine/runner_tail_call_test.zig`'s `tail_three_results_wasm`. */
static const uint8_t kMemoryClassTail[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x12, 0x03, 0x60,
    0x01, 0x7f, 0x03, 0x7f, 0x7f, 0x7f, 0x60, 0x00, 0x03, 0x7f, 0x7f, 0x7f,
    0x60, 0x00, 0x01, 0x7f, 0x03, 0x04, 0x03, 0x00, 0x01, 0x02, 0x07, 0x06,
    0x01, 0x02, 0x67, 0x6f, 0x00, 0x02, 0x0a, 0x18, 0x03, 0x08, 0x00, 0x20,
    0x00, 0x41, 0x02, 0x41, 0x03, 0x0b, 0x06, 0x00, 0x41, 0x01, 0x12, 0x00,
    0x0b, 0x06, 0x00, 0x10, 0x01, 0x6a, 0x6a, 0x0b, 0x00, 0x1a, 0x04, 0x6e,
    0x61, 0x6d, 0x65, 0x01, 0x0c, 0x02, 0x00, 0x03, 0x74, 0x72, 0x69, 0x01,
    0x04, 0x74, 0x61, 0x69, 0x6c, 0x04, 0x05, 0x01, 0x00, 0x02, 0x72, 0x33,
};

/* Instantiate `bytes` on `requested` and assert the read-back says `want`. */
static int probe(wasm_store_t* store, const uint8_t* bytes, size_t len, uint8_t requested, int32_t want, const char* label) {
    int ok = 0;
    wasm_byte_vec_t binary = { len, (wasm_byte_t*) bytes };
    wasm_module_t* module = wasm_module_new(store, &binary);
    if (!module) { fprintf(stderr, "%s: wasm_module_new failed\n", label); return 0; }

    wasm_extern_vec_t imports = { 0, NULL };
    wasm_instance_t* instance = zwasm_instance_new_ex(store, module, &imports, NULL, requested);
    if (!instance) { fprintf(stderr, "%s: instantiation failed\n", label); goto done; }

    int32_t got = -1;
    if (!zwasm_instance_engine(instance, &got)) { fprintf(stderr, "%s: read-back declined a live instance\n", label); goto release; }
    if (got != want) { fprintf(stderr, "%s: engine %d, wanted %d\n", label, (int) got, (int) want); goto release; }
    printf("engine_readback: %s -> %s\n", label, got == ZWASM_ENGINE_JIT ? "JIT" : "INTERP");
    ok = 1;
release:
    wasm_instance_delete(instance);
done:
    wasm_module_delete(module);
    return ok;
}

/* A null instance is refused, and `out` keeps the value the caller left in it. */
static int probe_null(void) {
    int32_t sentinel = 0x5eed;
    if (zwasm_instance_engine(NULL, &sentinel)) { fputs("null: read-back accepted a NULL instance\n", stderr); return 0; }
    if (sentinel != 0x5eed) { fprintf(stderr, "null: out written (%d)\n", (int) sentinel); return 0; }
    printf("engine_readback: NULL -> false, out untouched\n");
    return 1;
}

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    int ok = 1;
    ok &= probe(store, kAdd, sizeof(kAdd), ZWASM_ENGINE_JIT, ZWASM_ENGINE_JIT, "add/JIT");
    ok &= probe(store, kAdd, sizeof(kAdd), ZWASM_ENGINE_INTERP, ZWASM_ENGINE_INTERP, "add/INTERP");
    ok &= probe(store, kAdd, sizeof(kAdd), ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT, "add/AUTO");
    ok &= probe(store, kMemoryClassTail, sizeof(kMemoryClassTail), ZWASM_ENGINE_AUTO, ZWASM_ENGINE_INTERP, "memory_class_tail/AUTO");
    ok &= probe_null();
    if (ok) rc = 0;

cleanup:
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
