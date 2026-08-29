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
#include <string.h>

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

/* (module (func (export "_start") unreachable) (start 0)) — the start function
 * faults, so `wasm_instance_new` fails. It never calls `proc_exit`. */
static const uint8_t kBadStartWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00,
    0x08, 0x01, 0x00,
    0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b,
};

/* (module (func (export "_start") nop)) — imports nothing at all, so
 * instantiating it captures no WASI host. */
static const uint8_t kNoWasiWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00,
    0x0a, 0x05, 0x01, 0x03, 0x00, 0x01, 0x0b,
};

/* (module
 *   (import "m" "h" (func $h))
 *   (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
 *   (func (export "_start") (call $h) (i32.const 7) (call $exit)))
 * The host func runs FIRST, so it can call back into the Store before the
 * guest exits. */
static const uint8_t kHostThenExitWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x01, 0x7f, 0x00,
    0x02, 0x2a, 0x02,
    0x01, 0x6d, 0x01, 0x68, 0x00, 0x00,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31,
    0x09, 0x70, 0x72, 0x6f, 0x63, 0x5f, 0x65, 0x78, 0x69, 0x74,
    0x00, 0x01,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x02,
    0x0a, 0x0a, 0x01, 0x08, 0x00, 0x10, 0x00, 0x41, 0x07, 0x10, 0x01, 0x0b,
};

/* (module
 *   (import "m" "h" (func $h))
 *   (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
 *   (func (call $h) (i32.const 7) (call $exit))
 *   (start 2))
 * The start function calls the host func FIRST, so the callback can call back
 * into the Store before the start exits. Instantiation fails — the start
 * traps — but the status it requested is still the last thing that ran. */
static const uint8_t kReentrantStartWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x01, 0x7f, 0x00,
    0x02, 0x2a, 0x02,
    0x01, 0x6d, 0x01, 0x68, 0x00, 0x00,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31,
    0x09, 0x70, 0x72, 0x6f, 0x63, 0x5f, 0x65, 0x78, 0x69, 0x74,
    0x00, 0x01,
    0x03, 0x02, 0x01, 0x00,
    0x08, 0x01, 0x02,
    0x0a, 0x0a, 0x01, 0x08, 0x00, 0x10, 0x00, 0x41, 0x07, 0x10, 0x01, 0x0b,
};

/* (module
 *   (import "m1" "_start" (func $f))
 *   (func (export "_start") (call $f)))
 * Calls another instance's export and nothing else. Paired with `kExitWasm`
 * patched to 7 as the exporter, so the guest that reaches `proc_exit` is the
 * IMPORTED instance, not the one `wasm_func_call` was handed. */
static const uint8_t kCrossFuncCallerWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    0x02, 0x0d, 0x01,
    0x02, 0x6d, 0x31,
    0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74,
    0x00, 0x00,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x01,
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b,
};

/* (module
 *   (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
 *   (func $run (call $exit (i32.const 7)))
 *   (table (export "t") 1 funcref)
 *   (elem (i32.const 0) $run))
 * The same exit-7 guest as `kExitWasm`, reached through an exported TABLE
 * rather than an exported func — the wit-bindgen shim shape (D-325). */
static const uint8_t kCrossTableExporterWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60,
    0x00, 0x00, 0x02, 0x24, 0x01, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73,
    0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6f,
    0x63, 0x5f, 0x65, 0x78, 0x69, 0x74, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01, 0x04, 0x04, 0x01, 0x70,
    0x00, 0x01, 0x07, 0x05, 0x01, 0x01, 0x74, 0x01, 0x00, 0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b,
    0x01, 0x01, 0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x07, 0x10, 0x00, 0x0b,
};

/* (module
 *   (type $v (func))
 *   (import "m1" "t" (table 1 funcref))
 *   (func (export "_start") (i32.const 0) (call_indirect (type $v))))
 * Reaches the other instance through `call_indirect` on an imported table.
 * That dispatch never touches `cross_module.CallCtx`, so a fix confined to the
 * imported-func thunk leaves this case red. */
static const uint8_t kCrossTableCallerWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x02, 0x0a,
    0x01, 0x02, 0x6d, 0x31, 0x01, 0x74, 0x01, 0x70, 0x00, 0x01, 0x03, 0x02, 0x01, 0x00, 0x07, 0x0a,
    0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x41,
    0x00, 0x11, 0x00, 0x00, 0x0b,
};

static const uint8_t kEngines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT, ZWASM_ENGINE_INTERP };

static const char* engine_name(uint8_t kind) {
    switch (kind) {
        case ZWASM_ENGINE_JIT: return "jit";
        case ZWASM_ENGINE_INTERP: return "interp";
        default: return "auto";
    }
}

/* An instantiated module the caller keeps: `_start` can be called on it later,
 * after the Store's WASI config has moved on. */
typedef struct {
    wasm_module_t* module;
    wasm_instance_t* instance;
    wasm_extern_vec_t exports;
} guest_t;

static void guest_close(guest_t* g) {
    if (g->exports.data) wasm_extern_vec_delete(&g->exports);
    if (g->instance) wasm_instance_delete(g->instance);
    if (g->module) wasm_module_delete(g->module);
    g->exports.size = 0;
    g->exports.data = NULL;
    g->instance = NULL;
    g->module = NULL;
}

/* Instantiate `wasm` in `store` under `engine`, leaving the handles with the
 * caller. Returns 0 on success; `*out` is safe to `guest_close` either way. */
static int guest_open(wasm_store_t* store, const uint8_t* wasm, size_t wasm_len, uint8_t engine,
                      guest_t* out) {
    out->module = NULL;
    out->instance = NULL;
    out->exports.size = 0;
    out->exports.data = NULL;

    wasm_byte_vec_t binary = { wasm_len, (wasm_byte_t*) wasm };
    out->module = wasm_module_new(store, &binary);
    if (!out->module) { fputs("wasm_module_new failed\n", stderr); return 1; }

    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    out->instance = zwasm_instance_new_ex(store, out->module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!out->instance) { fputs("zwasm_instance_new_ex failed\n", stderr); return 1; }

    wasm_instance_exports(out->instance, &out->exports);
    if (out->exports.size < 1 || !out->exports.data[0] ||
        wasm_extern_kind(out->exports.data[0]) != WASM_EXTERN_FUNC) {
        fputs("missing _start export\n", stderr);
        return 1;
    }
    return 0;
}

/* Call `_start` on an already-built guest, then read the status back off
 * `store`. Returns 0 on success. */
static int guest_call_start(wasm_store_t* store, guest_t* g,
                            bool* trapped, bool* has_code, uint32_t* code) {
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t no_res = { 0, NULL };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(g->exports.data[0]), &no_args, &no_res);
    *trapped = trap != NULL;
    if (trap) wasm_trap_delete(trap);

    *code = 0xdeadbeefu; /* a false return must leave this untouched */
    *has_code = zwasm_store_wasi_exit_code(store, code);
    return 0;
}

/* One `_start` run inside a store the caller owns. Returns 0 on success; writes
 * the observed outcome into `*trapped` / `*has_code` / `*code`. The store
 * outlives the call, so the same store can be asked more than once. */
static int run_in_store(wasm_store_t* store, const uint8_t* wasm, size_t wasm_len, uint8_t engine,
                        bool* trapped, bool* has_code, uint32_t* code) {
    guest_t g;
    int rc = guest_open(store, wasm, wasm_len, engine, &g);
    if (rc == 0) rc = guest_call_start(store, &g, trapped, has_code, code);
    guest_close(&g);
    return rc;
}

/* One `_start` run in a store of its own. */
static int run_start(const uint8_t* wasm, size_t wasm_len, uint8_t engine, bool with_wasi,
                     bool* trapped, bool* has_code, uint32_t* code) {
    int rc = 1;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    if (with_wasi) {
        zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
        if (!cfg) { fputs("wasi config new failed\n", stderr); goto cleanup; }
        zwasm_store_set_wasi(store, cfg); /* takes ownership */
    }

    rc = run_in_store(store, wasm, wasm_len, engine, trapped, has_code, code);

cleanup:
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

/* One Store, one WASI setup, two guests. The status must describe the call
 * just made, not an earlier guest's. This is the case every function above is
 * structurally unable to reach: they each build a fresh engine + store, so no
 * store is ever asked twice. It matters because a WASI command exits through
 * `proc_exit` even when it succeeds, so one run leaves a "0" behind — and 0 is
 * exactly the value an embedder reads as success. */
static int expect_per_call(uint8_t engine) {
    int rc = 1;
    bool trapped = false, has_code = false;
    uint32_t code = 0;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
    if (!cfg) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, cfg); /* takes ownership */

    /* 1. a guest that exits cleanly. */
    kExitWasm[kRvalOffset] = 0;
    if (run_in_store(store, kExitWasm, sizeof(kExitWasm), engine, &trapped, &has_code, &code)) goto cleanup;
    if (!trapped || !has_code || code != 0) {
        fprintf(stderr, "[%s] same-store run 1: proc_exit(0) read back trapped=%d has_code=%d code=%u\n",
                engine_name(engine), (int) trapped, (int) has_code, code);
        goto cleanup;
    }

    /* 2. a genuine fault in the SAME store. No guest called proc_exit on this
     * call, so there is no status to report. */
    trapped = false;
    has_code = false;
    code = 0;
    if (run_in_store(store, kFaultWasm, sizeof(kFaultWasm), engine, &trapped, &has_code, &code)) goto cleanup;
    if (!trapped) {
        fprintf(stderr, "[%s] same-store run 2: expected a trap, got none\n", engine_name(engine));
        goto cleanup;
    }
    if (has_code) {
        fprintf(stderr, "[%s] same-store run 2: unreachable reported exit code %u — run 1's status is stale\n",
                engine_name(engine), code);
        goto cleanup;
    }
    if (code != 0xdeadbeefu) {
        fprintf(stderr, "[%s] same-store run 2: wrote through `out` while returning false\n", engine_name(engine));
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* What the Store's WASI setup looks like by the time the older instance is
 * finally called. */
typedef enum {
    kReplacedIdle,     /* replaced; the new host has never run anything */
    kReplacedCarries5, /* replaced; a guest of its own exited 5 on the new host */
    kDetached,         /* removed with NULL — the Store has no WASI setup at all */
} swap_kind;

static const char* swap_name(swap_kind k) {
    switch (k) {
        case kReplacedCarries5: return "config replaced, installed host carries 5";
        case kDetached: return "config detached with NULL";
        default: return "config replaced, installed host never ran";
    }
}

/* An instance reaches WASI through the host it captured when it was built —
 * `wasi.h` states an instance keeps using the config it was built with.
 * Moving the Store's config on must therefore not change which host that
 * instance's exit status is read from. All three ways it can move are the same
 * defect, and `zwasm_store_set_wasi`'s own comment documents all three.
 *
 * The assertion is on the code, not on `has_code`. `kReplacedCarries5` used to
 * answer 5 — a `has_code`-only check passes on that, reporting the wrong
 * guest's status as if it were right. */
static int expect_status_follows_captured_host(uint8_t engine, swap_kind swap) {
    int rc = 1;
    bool trapped = false, has_code = false;
    uint32_t code = 0;
    uint8_t exit7[sizeof(kExitWasm)];
    uint8_t exit5[sizeof(kExitWasm)];
    guest_t old_guest = { NULL, NULL, { 0, NULL } };
    guest_t new_guest = { NULL, NULL, { 0, NULL } };
    const char* what = swap_name(swap);
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    memcpy(exit7, kExitWasm, sizeof(kExitWasm));
    exit7[kRvalOffset] = 7;
    memcpy(exit5, kExitWasm, sizeof(kExitWasm));
    exit5[kRvalOffset] = 5;

    /* Config A, and an instance built under it. */
    zwasm_wasi_config_t* cfg_a = zwasm_wasi_config_new();
    if (!cfg_a) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, cfg_a); /* takes ownership */
    if (guest_open(store, exit7, sizeof(exit7), engine, &old_guest)) goto cleanup;

    /* A moves off the Store. It retires rather than being freed, because an
     * instantiation captured it (#314) — which is what keeps it readable. */
    if (swap == kDetached) {
        zwasm_store_set_wasi(store, NULL);
    } else {
        zwasm_wasi_config_t* cfg_b = zwasm_wasi_config_new();
        if (!cfg_b) { fputs("wasi config new failed\n", stderr); goto cleanup; }
        zwasm_store_set_wasi(store, cfg_b); /* takes ownership */
    }

    if (swap == kReplacedCarries5) {
        if (guest_open(store, exit5, sizeof(exit5), engine, &new_guest)) goto cleanup;
        if (guest_call_start(store, &new_guest, &trapped, &has_code, &code)) goto cleanup;
        if (!trapped || !has_code || code != 5) {
            fprintf(stderr, "[%s] %s: the new config's own guest read back trapped=%d has_code=%d code=%u\n",
                    engine_name(engine), what, (int) trapped, (int) has_code, code);
            goto cleanup;
        }
    }

    /* The older instance runs now, and exits 7 through the host it captured. */
    trapped = false;
    has_code = false;
    code = 0;
    if (guest_call_start(store, &old_guest, &trapped, &has_code, &code)) goto cleanup;
    if (!trapped) {
        fprintf(stderr, "[%s] %s: expected a trap, got none\n", engine_name(engine), what);
        goto cleanup;
    }
    if (!has_code) {
        fprintf(stderr, "[%s] %s: proc_exit(7) reported no status — a clean exit reads back as a fault\n",
                engine_name(engine), what);
        goto cleanup;
    }
    if (code != 7) {
        fprintf(stderr, "[%s] %s: proc_exit(7) read back %u\n", engine_name(engine), what, code);
        goto cleanup;
    }
    rc = 0;

cleanup:
    guest_close(&new_guest);
    guest_close(&old_guest);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* The read window closes at the next INSTANTIATION, not only at the next call.
 * Instantiating records the setup the new instance will use — that is what
 * makes a `(start)` calling `proc_exit` readable — and it moves the setup the
 * status is read from, exactly as another `wasm_func_call` would. `wasi.h`
 * states both halves, and this is the only case in this file that builds a
 * second instance after a swap, so nothing else pins them.
 *
 * The middle read is the one that matters: replacing the config alone does NOT
 * hide the status. The last read is the documented cost of writing the setup
 * at capture time, asserted so it cannot change silently. */
static int expect_read_window_closes_at_instantiate(uint8_t engine) {
    int rc = 1;
    bool trapped = false, has_code = false;
    uint32_t code = 0;
    uint8_t exit7[sizeof(kExitWasm)];
    uint8_t exit5[sizeof(kExitWasm)];
    guest_t old_guest = { NULL, NULL, { 0, NULL } };
    guest_t new_guest = { NULL, NULL, { 0, NULL } };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    memcpy(exit7, kExitWasm, sizeof(kExitWasm));
    exit7[kRvalOffset] = 7;
    memcpy(exit5, kExitWasm, sizeof(kExitWasm));
    exit5[kRvalOffset] = 5;

    zwasm_wasi_config_t* cfg_a = zwasm_wasi_config_new();
    if (!cfg_a) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, cfg_a); /* takes ownership */

    if (guest_open(store, exit7, sizeof(exit7), engine, &old_guest)) goto cleanup;
    if (guest_call_start(store, &old_guest, &trapped, &has_code, &code)) goto cleanup;
    if (!trapped || !has_code || code != 7) {
        fprintf(stderr, "[%s] read window: proc_exit(7) read back trapped=%d has_code=%d code=%u\n",
                engine_name(engine), (int) trapped, (int) has_code, code);
        goto cleanup;
    }

    /* Replace the config WITHOUT calling or instantiating. The status the
     * embedder has not read yet stays readable. */
    zwasm_wasi_config_t* cfg_b = zwasm_wasi_config_new();
    if (!cfg_b) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, cfg_b); /* takes ownership */

    code = 0xdeadbeefu;
    has_code = zwasm_store_wasi_exit_code(store, &code);
    if (!has_code || code != 7) {
        fprintf(stderr, "[%s] read window: the swap alone hid the status (has_code=%d code=%u)\n",
                engine_name(engine), (int) has_code, code);
        goto cleanup;
    }

    /* Building another instance moves the setup the status is read from, so
     * the unread status is gone. This is what `wasi.h` tells the embedder to
     * read before doing. */
    if (guest_open(store, exit5, sizeof(exit5), engine, &new_guest)) goto cleanup;

    code = 0xdeadbeefu;
    has_code = zwasm_store_wasi_exit_code(store, &code);
    if (has_code) {
        fprintf(stderr, "[%s] read window: a status survived a later instantiation (code=%u)\n",
                engine_name(engine), code);
        goto cleanup;
    }
    if (code != 0xdeadbeefu) {
        fprintf(stderr, "[%s] read window: wrote through `out` while returning false\n", engine_name(engine));
        goto cleanup;
    }
    rc = 0;

cleanup:
    guest_close(&new_guest);
    guest_close(&old_guest);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* Instantiating invalidates the status, whether or not the config moved.
 * `wasi.h` names instantiation alongside the next call as the point to read
 * before, and instantiation IS a read point of its own — a `(start)` can call
 * `proc_exit`. Both halves have to hold, or the sentence is only true when the
 * config happens to change:
 *
 *   - a second guest built on the SAME config must not leave the first's
 *     status readable
 *   - a `(start)` that faults WITHOUT exiting must not read back as the
 *     earlier guest's exit — that is #341's failure shape at this read point
 */
static int expect_instantiate_invalidates(uint8_t engine) {
    int rc = 1;
    bool trapped = false, has_code = false;
    uint32_t code = 0;
    uint8_t exit7[sizeof(kExitWasm)];
    guest_t first = { NULL, NULL, { 0, NULL } };
    guest_t second = { NULL, NULL, { 0, NULL } };
    wasm_module_t* bad_module = NULL;
    wasm_instance_t* bad_instance = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    memcpy(exit7, kExitWasm, sizeof(kExitWasm));
    exit7[kRvalOffset] = 7;

    zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
    if (!cfg) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, cfg); /* takes ownership */

    if (guest_open(store, exit7, sizeof(exit7), engine, &first)) goto cleanup;
    if (guest_call_start(store, &first, &trapped, &has_code, &code)) goto cleanup;
    if (!trapped || !has_code || code != 7) {
        fprintf(stderr, "[%s] instantiate-invalidates: proc_exit(7) read back trapped=%d has_code=%d code=%u\n",
                engine_name(engine), (int) trapped, (int) has_code, code);
        goto cleanup;
    }

    /* A second guest on the SAME config — nothing replaced, nothing detached. */
    if (guest_open(store, exit7, sizeof(exit7), engine, &second)) goto cleanup;
    code = 0xdeadbeefu;
    has_code = zwasm_store_wasi_exit_code(store, &code);
    if (has_code) {
        fprintf(stderr, "[%s] instantiate-invalidates: same-config instantiate left the earlier status readable (%u)\n",
                engine_name(engine), code);
        goto cleanup;
    }
    if (code != 0xdeadbeefu) {
        fprintf(stderr, "[%s] instantiate-invalidates: wrote through `out` while returning false\n", engine_name(engine));
        goto cleanup;
    }

    /* Now leave a status behind again, then fail an instantiation whose start
     * function faults without calling proc_exit. */
    if (guest_call_start(store, &second, &trapped, &has_code, &code)) goto cleanup;
    if (!has_code || code != 7) {
        fprintf(stderr, "[%s] instantiate-invalidates: second guest read back has_code=%d code=%u\n",
                engine_name(engine), (int) has_code, code);
        goto cleanup;
    }

    wasm_byte_vec_t bad_binary = { sizeof(kBadStartWasm), (wasm_byte_t*) kBadStartWasm };
    bad_module = wasm_module_new(store, &bad_binary);
    if (!bad_module) { fputs("bad-start module failed to parse\n", stderr); goto cleanup; }
    wasm_extern_vec_t no_imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    bad_instance = zwasm_instance_new_ex(store, bad_module, &no_imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (bad_instance) {
        fprintf(stderr, "[%s] instantiate-invalidates: a faulting start function instantiated\n",
                engine_name(engine));
        goto cleanup;
    }

    code = 0xdeadbeefu;
    has_code = zwasm_store_wasi_exit_code(store, &code);
    if (has_code) {
        fprintf(stderr, "[%s] instantiate-invalidates: a faulting start read back as exit %u\n",
                engine_name(engine), code);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (bad_instance) wasm_instance_delete(bad_instance);
    if (bad_module) wasm_module_delete(bad_module);
    guest_close(&second);
    guest_close(&first);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* A module that captures no WASI host still closes the read window.
 * `zwasm_store_set_wasi` clears `wasi_host_captured`, so the capture branch is
 * skipped for a module with no WASI imports built after a replace or a detach.
 * `wasi.h` states the rule without that qualifier — creating an instance
 * clears the status — so the clear cannot hang off the capture. */
static int expect_non_wasi_instantiate_invalidates(uint8_t engine, bool detach) {
    int rc = 1;
    bool trapped = false, has_code = false;
    uint32_t code = 0;
    uint8_t exit7[sizeof(kExitWasm)];
    guest_t first = { NULL, NULL, { 0, NULL } };
    guest_t plain = { NULL, NULL, { 0, NULL } };
    const char* what = detach ? "no-WASI instantiate after detach" : "no-WASI instantiate after replace";
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    memcpy(exit7, kExitWasm, sizeof(kExitWasm));
    exit7[kRvalOffset] = 7;

    zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
    if (!cfg) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, cfg); /* takes ownership */

    if (guest_open(store, exit7, sizeof(exit7), engine, &first)) goto cleanup;
    if (guest_call_start(store, &first, &trapped, &has_code, &code)) goto cleanup;
    if (!has_code || code != 7) {
        fprintf(stderr, "[%s] %s: proc_exit(7) read back has_code=%d code=%u\n",
                engine_name(engine), what, (int) has_code, code);
        goto cleanup;
    }

    if (detach) {
        zwasm_store_set_wasi(store, NULL);
    } else {
        zwasm_wasi_config_t* cfg2 = zwasm_wasi_config_new();
        if (!cfg2) { fputs("wasi config new failed\n", stderr); goto cleanup; }
        zwasm_store_set_wasi(store, cfg2); /* takes ownership */
    }

    if (guest_open(store, kNoWasiWasm, sizeof(kNoWasiWasm), engine, &plain)) goto cleanup;
    code = 0xdeadbeefu;
    has_code = zwasm_store_wasi_exit_code(store, &code);
    if (has_code) {
        fprintf(stderr, "[%s] %s: the earlier status stayed readable (%u)\n",
                engine_name(engine), what, code);
        goto cleanup;
    }
    if (code != 0xdeadbeefu) {
        fprintf(stderr, "[%s] %s: wrote through `out` while returning false\n", engine_name(engine), what);
        goto cleanup;
    }
    rc = 0;

cleanup:
    guest_close(&plain);
    guest_close(&first);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* How the caller reaches the other instance's guest code. Both shapes leave
 * the called instance and run the SOURCE instance's body with the SOURCE
 * instance's WASI binding; they share nothing else. */
typedef enum {
    kViaImportedFunc,  /* `call` on an imported func — src/api/cross_module.zig */
    kViaImportedTable, /* `call_indirect` on an imported table — src/interp/mvp.zig */
} cross_kind;

static const char* cross_name(cross_kind k) {
    return k == kViaImportedTable ? "cross-module via imported table"
                                  : "cross-module via imported func";
}

/* #352 — a `proc_exit` reached through another instance writes the SOURCE
 * instance's WASI host, while the record ADR-0222 keeps names the instance
 * `wasm_func_call` was handed.
 *
 * `I1` is built under config A and exits 7. The Store's config then moves on,
 * and `I2` — built under config B, doing nothing but reaching into `I1` — is
 * built and called. Dispatch enters `I1`'s body with `I1`'s WASI binding, so
 * `proc_exit` writes host A; the record names `I2`, which captured nothing. A
 * clean exit of 7 reads back as a fault.
 *
 * The granularity the status needs is the runtime that actually RAN
 * `proc_exit`, not the instance that was called. Nothing here contradicts
 * ADR-0222: for every call that does not leave the called instance the two are
 * the same runtime.
 *
 * BOTH shapes are asserted because they share no dispatch code. The imported
 * func goes through `cross_module.CallCtx`; the imported table goes through
 * `call_indirect`'s foreign-`fe.runtime` branch, which has no `CallCtx` and no
 * Store in scope. A fix confined to the first leaves the second red, so the
 * record cannot be repaired by retargeting at the dispatch sites one by one.
 *
 * The assertion is on the code, not on `has_code`, for #345's reason — a
 * `has_code`-only check passes on another guest's status.
 *
 * The JIT-backed engines cannot build `I2` in either shape: `buildBindings`
 * resolves a cross-module import through the source instance's interpreter
 * runtime, and a JIT-backed instance has none, so the instantiation fails.
 * That is a separate defect with its own fix, NOT this one. It is reported
 * here rather than skipped, and these assertions run in full as soon as the
 * instantiation starts succeeding. */
static int expect_status_follows_the_executing_runtime(uint8_t engine, cross_kind kind) {
    int rc = 1;
    uint8_t exit7[sizeof(kExitWasm)];
    const uint8_t* exporter_wasm;
    size_t exporter_len;
    const uint8_t* caller_wasm;
    size_t caller_len;
    wasm_module_t* exporter_module = NULL;
    wasm_instance_t* exporter = NULL;
    wasm_extern_vec_t exporter_exports = { 0, NULL };
    wasm_module_t* caller_module = NULL;
    wasm_instance_t* caller = NULL;
    wasm_extern_vec_t caller_exports = { 0, NULL };
    const char* what = cross_name(kind);
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    memcpy(exit7, kExitWasm, sizeof(kExitWasm));
    exit7[kRvalOffset] = 7;
    if (kind == kViaImportedTable) {
        exporter_wasm = kCrossTableExporterWasm;
        exporter_len = sizeof(kCrossTableExporterWasm);
        caller_wasm = kCrossTableCallerWasm;
        caller_len = sizeof(kCrossTableCallerWasm);
    } else {
        exporter_wasm = exit7;
        exporter_len = sizeof(exit7);
        caller_wasm = kCrossFuncCallerWasm;
        caller_len = sizeof(kCrossFuncCallerWasm);
    }

    /* Config A, and the exporter built under it. */
    zwasm_wasi_config_t* cfg_a = zwasm_wasi_config_new();
    if (!cfg_a) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, cfg_a); /* takes ownership */

    wasm_byte_vec_t exporter_binary = { exporter_len, (wasm_byte_t*) exporter_wasm };
    exporter_module = wasm_module_new(store, &exporter_binary);
    if (!exporter_module) { fputs("exporter module failed to parse\n", stderr); goto cleanup; }
    wasm_extern_vec_t no_imports = { 0, NULL };
    wasm_trap_t* etrap = NULL;
    exporter = zwasm_instance_new_ex(store, exporter_module, &no_imports, &etrap, engine);
    if (etrap) wasm_trap_delete(etrap);
    if (!exporter) {
        fprintf(stderr, "[%s] %s: the exporter failed to instantiate\n", engine_name(engine), what);
        goto cleanup;
    }
    wasm_instance_exports(exporter, &exporter_exports);
    if (exporter_exports.size < 1 || !exporter_exports.data[0]) {
        fprintf(stderr, "[%s] %s: the exporter exposed nothing\n", engine_name(engine), what);
        goto cleanup;
    }

    /* The config moves on. A retires rather than being freed — the exporter
     * captured it — which is what keeps its status readable at all. */
    zwasm_wasi_config_t* cfg_b = zwasm_wasi_config_new();
    if (!cfg_b) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, cfg_b); /* takes ownership */

    /* The caller, built under B, importing the exporter's func or table. */
    wasm_byte_vec_t caller_binary = { caller_len, (wasm_byte_t*) caller_wasm };
    caller_module = wasm_module_new(store, &caller_binary);
    if (!caller_module) { fputs("caller module failed to parse\n", stderr); goto cleanup; }
    wasm_extern_t* caller_import_externs[1] = { exporter_exports.data[0] };
    wasm_extern_vec_t caller_imports = { 1, caller_import_externs };
    wasm_trap_t* ctrap = NULL;
    caller = zwasm_instance_new_ex(store, caller_module, &caller_imports, &ctrap, engine);
    if (ctrap) wasm_trap_delete(ctrap);
    if (!caller) {
        if (engine == ZWASM_ENGINE_INTERP) {
            fprintf(stderr, "[interp] %s: the caller failed to instantiate\n", what);
            goto cleanup;
        }
        /* The separate defect named above. Not this case's subject, and not
         * silently passed over: it is why this engine contributes no evidence
         * here. */
        fprintf(stderr,
                "[%s] %s: a cross-module import cannot be built against a JIT-backed "
                "instance, so this engine is unmeasured\n",
                engine_name(engine), what);
        rc = 0;
        goto cleanup;
    }
    wasm_instance_exports(caller, &caller_exports);
    if (caller_exports.size < 1 || !caller_exports.data[0] ||
        wasm_extern_kind(caller_exports.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s] %s: the caller is missing its _start export\n", engine_name(engine), what);
        goto cleanup;
    }

    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t no_res = { 0, NULL };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(caller_exports.data[0]), &no_args, &no_res);
    if (!trap) {
        fprintf(stderr, "[%s] %s: expected a trap, got none\n", engine_name(engine), what);
        goto cleanup;
    }
    wasm_trap_delete(trap);

    uint32_t code = 0xdeadbeefu;
    if (!zwasm_store_wasi_exit_code(store, &code)) {
        fprintf(stderr,
                "[%s] %s: proc_exit(7) reported no status — the write went to the host the "
                "exporting instance captured and the read followed the called one\n",
                engine_name(engine), what);
        goto cleanup;
    }
    if (code != 7) {
        fprintf(stderr, "[%s] %s: proc_exit(7) read back %u\n", engine_name(engine), what, code);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (caller_exports.data) wasm_extern_vec_delete(&caller_exports);
    if (caller) wasm_instance_delete(caller);
    if (caller_module) wasm_module_delete(caller_module);
    if (exporter_exports.data) wasm_extern_vec_delete(&exporter_exports);
    if (exporter) wasm_instance_delete(exporter);
    if (exporter_module) wasm_module_delete(exporter_module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* A host callback that calls back into the Store must not retarget the status.
 * The embedder made ONE call; the guest behind it exits 7. A nested
 * `wasm_func_call` from inside the callback has no guest of its own — it is a
 * `wasm_func_new` func — so recording it would leave the outer guest's exit
 * unreadable, reporting a clean termination as a fault. */
static wasm_func_t* g_nested_target = NULL;

static wasm_trap_t* call_back_in(const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    (void) args;
    (void) results;
    if (g_nested_target) {
        wasm_val_vec_t no_args = { 0, NULL };
        wasm_val_vec_t no_res = { 0, NULL };
        wasm_trap_t* t = wasm_func_call(g_nested_target, &no_args, &no_res);
        if (t) wasm_trap_delete(t);
    }
    return NULL;
}

static wasm_trap_t* do_nothing(const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    (void) args;
    (void) results;
    return NULL;
}

static int expect_nested_call_keeps_the_outer_host(uint8_t engine) {
    int rc = 1;
    uint32_t code = 0;
    wasm_functype_t* inner_ft = NULL;
    wasm_functype_t* outer_ft = NULL;
    wasm_func_t* outer_host = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
    if (!cfg) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, cfg); /* takes ownership */

    inner_ft = wasm_functype_new_0_0();
    g_nested_target = inner_ft ? wasm_func_new(store, inner_ft, do_nothing) : NULL;
    outer_ft = wasm_functype_new_0_0();
    outer_host = outer_ft ? wasm_func_new(store, outer_ft, call_back_in) : NULL;
    if (!g_nested_target || !outer_host) { fputs("wasm_func_new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kHostThenExitWasm), (wasm_byte_t*) kHostThenExitWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("host-then-exit module failed\n", stderr); goto cleanup; }

    wasm_extern_t* import_externs[1] = { wasm_func_as_extern(outer_host) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) { fputs("host-then-exit instantiate failed\n", stderr); goto cleanup; }

    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0]) { fputs("missing _start export\n", stderr); goto cleanup; }

    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t no_res = { 0, NULL };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(exports.data[0]), &no_args, &no_res);
    if (!trap) {
        fprintf(stderr, "[%s] nested call: expected a trap from proc_exit, got none\n", engine_name(engine));
        goto cleanup;
    }
    wasm_trap_delete(trap);

    code = 0xdeadbeefu;
    if (!zwasm_store_wasi_exit_code(store, &code)) {
        fprintf(stderr, "[%s] nested call: proc_exit(7) reported no status — the nested call took the host\n",
                engine_name(engine));
        goto cleanup;
    }
    if (code != 7) {
        fprintf(stderr, "[%s] nested call: proc_exit(7) read back %u\n", engine_name(engine), code);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (outer_host) wasm_func_delete(outer_host);
    if (g_nested_target) wasm_func_delete(g_nested_target);
    g_nested_target = NULL;
    if (outer_ft) wasm_functype_delete(outer_ft);
    if (inner_ft) wasm_functype_delete(inner_ft);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* A `(start)` that calls back into the Store keeps its own exit status.
 * Instantiation is a read point — a `(start)` reaching `proc_exit` is why the
 * host is recorded at capture time — so while the start runs it owns the
 * status the same way an outermost `wasm_func_call` does. A host callback the
 * start invokes can call `wasm_func_call`, and without that ownership the
 * nested call retargets the record and the start's exit reads back as a
 * fault. */
static int expect_reentrant_start_keeps_its_status(uint8_t engine) {
    int rc = 1;
    uint32_t code = 0;
    wasm_functype_t* inner_ft = NULL;
    wasm_functype_t* outer_ft = NULL;
    wasm_func_t* outer_host = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
    if (!cfg) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, cfg); /* takes ownership */

    inner_ft = wasm_functype_new_0_0();
    g_nested_target = inner_ft ? wasm_func_new(store, inner_ft, do_nothing) : NULL;
    outer_ft = wasm_functype_new_0_0();
    outer_host = outer_ft ? wasm_func_new(store, outer_ft, call_back_in) : NULL;
    if (!g_nested_target || !outer_host) { fputs("wasm_func_new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kReentrantStartWasm), (wasm_byte_t*) kReentrantStartWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("reentrant-start module failed\n", stderr); goto cleanup; }

    wasm_extern_t* import_externs[1] = { wasm_func_as_extern(outer_host) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (instance) {
        fprintf(stderr, "[%s] reentrant start: a start calling proc_exit instantiated\n", engine_name(engine));
        goto cleanup;
    }

    code = 0xdeadbeefu;
    if (!zwasm_store_wasi_exit_code(store, &code)) {
        fprintf(stderr, "[%s] reentrant start: proc_exit(7) reported no status — the nested call took the host\n",
                engine_name(engine));
        goto cleanup;
    }
    if (code != 7) {
        fprintf(stderr, "[%s] reentrant start: proc_exit(7) read back %u\n", engine_name(engine), code);
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (outer_host) wasm_func_delete(outer_host);
    if (g_nested_target) wasm_func_delete(g_nested_target);
    g_nested_target = NULL;
    if (outer_ft) wasm_functype_delete(outer_ft);
    if (inner_ft) wasm_functype_delete(inner_ft);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* A `wasm_func_new` func called directly has no guest behind it, so its trap
 * carries no exit status — and must not read back as the last guest's. The
 * clear sits above the direct-callback branch for exactly this: without it the
 * trap reports a clean exit of 0 that no guest ever requested. */
static const char kRefusal[] = "host refused";
static wasm_store_t* g_refuse_store = NULL;

static wasm_trap_t* refuse(const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    (void) args;
    (void) results;
    wasm_byte_vec_t msg = { sizeof(kRefusal) - 1, (wasm_byte_t*) kRefusal };
    return wasm_trap_new(g_refuse_store, &msg);
}

static int expect_direct_call_clears(uint8_t engine) {
    int rc = 1;
    bool trapped = false, has_code = false;
    uint32_t code = 0;
    wasm_functype_t* ft = NULL;
    wasm_func_t* fn = NULL;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }
    g_refuse_store = store;

    zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
    if (!cfg) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    zwasm_store_set_wasi(store, cfg); /* takes ownership */

    /* A guest exits cleanly, leaving a status on the Store. */
    kExitWasm[kRvalOffset] = 0;
    if (run_in_store(store, kExitWasm, sizeof(kExitWasm), engine, &trapped, &has_code, &code)) goto cleanup;
    if (!trapped || !has_code || code != 0) {
        fprintf(stderr, "[%s] direct-call setup: proc_exit(0) read back trapped=%d has_code=%d code=%u\n",
                engine_name(engine), (int) trapped, (int) has_code, code);
        goto cleanup;
    }

    /* A host func of our own, called with no instance in between, traps. */
    ft = wasm_functype_new_0_0();
    fn = ft ? wasm_func_new(store, ft, refuse) : NULL;
    if (!fn) { fputs("wasm_func_new failed\n", stderr); goto cleanup; }

    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t no_res = { 0, NULL };
    wasm_trap_t* trap = wasm_func_call(fn, &no_args, &no_res);
    if (!trap) {
        fprintf(stderr, "[%s] direct call: expected the callback's trap, got none\n", engine_name(engine));
        goto cleanup;
    }
    wasm_trap_delete(trap);

    code = 0xdeadbeefu;
    has_code = zwasm_store_wasi_exit_code(store, &code);
    if (has_code) {
        fprintf(stderr, "[%s] direct call: host-func trap reported exit code %u — no guest ran\n",
                engine_name(engine), code);
        goto cleanup;
    }
    if (code != 0xdeadbeefu) {
        fprintf(stderr, "[%s] direct call: wrote through `out` while returning false\n", engine_name(engine));
        goto cleanup;
    }
    rc = 0;

cleanup:
    if (fn) wasm_func_delete(fn);
    if (ft) wasm_functype_delete(ft);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    g_refuse_store = NULL;
    return rc;
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
        if (expect_per_call(e)) return 1;
        if (expect_direct_call_clears(e)) return 1;
        if (expect_status_follows_captured_host(e, kReplacedIdle)) return 1;
        if (expect_status_follows_captured_host(e, kReplacedCarries5)) return 1;
        if (expect_status_follows_captured_host(e, kDetached)) return 1;
        if (expect_read_window_closes_at_instantiate(e)) return 1;
        if (expect_instantiate_invalidates(e)) return 1;
        if (expect_non_wasi_instantiate_invalidates(e, false)) return 1;
        if (expect_non_wasi_instantiate_invalidates(e, true)) return 1;
        if (expect_nested_call_keeps_the_outer_host(e)) return 1;
        if (expect_reentrant_start_keeps_its_status(e)) return 1;
        if (expect_status_follows_the_executing_runtime(e, kViaImportedFunc)) return 1;
        if (expect_status_follows_the_executing_runtime(e, kViaImportedTable)) return 1;
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
