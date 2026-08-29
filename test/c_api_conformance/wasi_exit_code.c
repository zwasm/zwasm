/* zwasm v2 — a C host reads a WASI guest's exit status.
 *
 * A WASI command ends by calling `proc_exit`, including when it succeeds
 * (a wasi-libc `_start` that returns normally calls `proc_exit(0)`). zwasm
 * surfaces that as a trap, so from `wasm_func_call` alone a clean exit and a
 * genuine fault look identical. `zwasm_store_wasi_exit_code` is what tells
 * them apart, and this case pins the contract the header states:
 *
 *   trap + exit code present  → the guest terminated itself, *out is its status
 *   trap + no exit code       → a genuine fault
 *
 * The trap kind cannot stand in for it. The kind a `proc_exit` trap carries
 * differs between the interpreter and the JIT, and under the JIT it does not
 * differ from a real `unreachable` — which is why the contract is "is there an
 * exit status", not "what kind is the trap". The status itself must NOT depend
 * on the engine, so every assertion below runs under AUTO, JIT and INTERP.
 *
 * Run by `test-c-api-conformance`.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

#include <wasm.h>
#include <wasi.h>
#include <zwasm.h>

/* (module
 *   (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
 *   (func (export "_start") (call $exit (i32.const N)))) — N at kRvalOffset. */
static uint8_t kExitWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00,
    0x02, 0x24, 0x01,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31,
    0x09, 0x70, 0x72, 0x6f, 0x63, 0x5f, 0x65, 0x78, 0x69, 0x74,
    0x00, 0x00,
    0x03, 0x02, 0x01, 0x01,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x01,
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x03, 0x10, 0x00, 0x0b,
};
/* The i32.const operand of the proc_exit argument. Patched per case, so the
 * value must stay a single-byte signed LEB128 (0..63). */
#define kRvalOffset 78

/* (module (func (export "_start") unreachable)) — traps without proc_exit. */
static const uint8_t kFaultWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00,
    0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b,
};

static const uint8_t kEngines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };

static const char* engine_name(uint8_t kind) {
    switch (kind) {
        case ZWASM_ENGINE_JIT: return "jit";
        case ZWASM_ENGINE_INTERP: return "interp";
        default: return "auto";
    }
}

/* One `_start` run. Returns 0 on success; writes the observed outcome into
 * `*trapped` / `*has_code` / `*code`. */
static int run_start(const uint8_t* wasm, size_t wasm_len, uint8_t engine, bool with_wasi,
                     bool* trapped, bool* has_code, uint32_t* code) {
    int rc = 1;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    if (with_wasi) {
        zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
        if (!cfg) { fputs("wasi config new failed\n", stderr); goto cleanup; }
        zwasm_store_set_wasi(store, cfg); /* takes ownership */
    }

    wasm_byte_vec_t binary = { wasm_len, (wasm_byte_t*) wasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) { fputs("zwasm_instance_new_ex failed\n", stderr); goto cleanup; }

    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0] || wasm_extern_kind(exports.data[0]) != WASM_EXTERN_FUNC) {
        fputs("missing _start export\n", stderr);
        goto cleanup;
    }

    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t no_res = { 0, NULL };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(exports.data[0]), &no_args, &no_res);
    *trapped = trap != NULL;
    if (trap) wasm_trap_delete(trap);

    *code = 0xdeadbeefu; /* a false return must leave this untouched */
    *has_code = zwasm_store_wasi_exit_code(store, code);
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* A guest that called proc_exit(want): traps, and the status reads back. */
static int expect_exit(uint8_t engine, uint32_t want) {
    bool trapped = false, has_code = false;
    uint32_t code = 0;
    kExitWasm[kRvalOffset] = (uint8_t) want;
    if (run_start(kExitWasm, sizeof(kExitWasm), engine, true, &trapped, &has_code, &code)) return 1;
    if (!trapped) {
        fprintf(stderr, "[%s] proc_exit(%u): expected a trap, got none\n", engine_name(engine), want);
        return 1;
    }
    if (!has_code) {
        fprintf(stderr, "[%s] proc_exit(%u): no exit code recorded\n", engine_name(engine), want);
        return 1;
    }
    if (code != want) {
        fprintf(stderr, "[%s] proc_exit(%u): read back %u\n", engine_name(engine), want, code);
        return 1;
    }
    return 0;
}

/* A genuine fault, or a run with no WASI at all: no status, `out` untouched. */
static int expect_no_exit(uint8_t engine, bool with_wasi, const char* what) {
    bool trapped = false, has_code = false;
    uint32_t code = 0;
    if (run_start(kFaultWasm, sizeof(kFaultWasm), engine, with_wasi, &trapped, &has_code, &code)) return 1;
    if (!trapped) {
        fprintf(stderr, "[%s] %s: expected a trap, got none\n", engine_name(engine), what);
        return 1;
    }
    if (has_code) {
        fprintf(stderr, "[%s] %s: reported an exit code (%u)\n", engine_name(engine), what, code);
        return 1;
    }
    if (code != 0xdeadbeefu) {
        fprintf(stderr, "[%s] %s: wrote through `out` while returning false\n", engine_name(engine), what);
        return 1;
    }
    return 0;
}

int main(void) {
    for (size_t i = 0; i < sizeof(kEngines) / sizeof(kEngines[0]); i++) {
        const uint8_t e = kEngines[i];
        /* 0 is the case the trap kind cannot express: a WASI command that
         * SUCCEEDED still exits through proc_exit. */
        if (expect_exit(e, 0)) return 1;
        if (expect_exit(e, 3)) return 1;
        if (expect_exit(e, 42)) return 1;
        if (expect_no_exit(e, true, "unreachable with a WASI host")) return 1;
        if (expect_no_exit(e, false, "unreachable with no WASI host")) return 1;
    }

    /* Null-arg discipline, matching the rest of the extension surface. */
    uint32_t sink = 0;
    if (zwasm_store_wasi_exit_code(NULL, &sink)) {
        fputs("null store returned true\n", stderr);
        return 1;
    }

    puts("zwasm c_api_conformance/wasi_exit_code: exit status readable on auto/jit/interp");
    return 0;
}
