/* zwasm v2 — C-API conformance: a trap on the interpreter carries its origin and trace (#498, ADR-0232)
 *
 * Contract pinned here: on the interpreter, `wasm_trap_origin` is the frame
 * that trapped and `wasm_trap_trace` every frame the trap unwound, innermost
 * first, with the function index and the offsets `wasm-tools print
 * --print-offsets` shows; `wasm_frame_instance` is NULL. On the JIT both are
 * empty. Module A:
 *
 *   (module
 *     (import "host" "reenter" (func $reenter))        ;; 0
 *     (tag $e)
 *     (func $helper (param i32) (result i32) (local i64)  ;; 1, starts @0x5d
 *       local.get 0 unreachable)                          ;;    unreachable @0x62
 *     (func $inner (param i32) (result i32)               ;; 2, @0x65
 *       local.get 0 call $helper)                         ;;    call @0x68
 *     (func $boom (export "boom") (param i32) (result i32) ;; 3, @0x6c
 *       local.get 0 call $inner)                          ;;    call @0x6f
 *     (func $tail_target (local i32 i32) unreachable)     ;; 4, @0x73, unreachable @0x76
 *     (func (export "tailboom") return_call $tail_target) ;; 5
 *     (func (export "outer") nop call $reenter)           ;; 6, @0x7e, call @0x80
 *     (func (export "throw") throw $e))                   ;; 7
 *
 * Module B imports A's "boom":
 *
 *   (module
 *     (import "a" "boom" (func $boom (param i32) (result i32)))
 *     (func (export "via") (param i32) (result i32)       ;; 1, @0x2d
 *       local.get 0 call $boom))                          ;;    call @0x30
 *
 * The host's "reenter" calls A's "boom" and returns the trap it got: the trace
 * of "outer" starts at its own call site and holds none of boom's frames.
 *
 * A start function's trap reaches `wasm_instance_new`'s trap out-param with its
 * trace, for a defined start and an imported one (A's "tailboom"):
 *
 *   (module (func $s (local i32) nop unreachable) (start $s))  ;; 0, @0x19, unreachable @0x1d
 *   (module (import "a" "tailboom" (func $t)) (start $t))
 *
 * And a trap 101 calls deep keeps the innermost 64 frames:
 *
 *   (module (func $r (export "deep") (param i32)              ;; 0, @0x21
 *     local.get 0 i32.eqz if unreachable end                   ;;    unreachable @0x27
 *     local.get 0 i32.const 1 i32.sub call $r))                ;;    call @0x2e
 *
 * Exits 0 when every frame matches.
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include <wasm.h>
#include <zwasm.h>

static const uint8_t kA[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x09, 0x02, 0x60,
    0x00, 0x00, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x02, 0x10, 0x01, 0x04, 0x68,
    0x6f, 0x73, 0x74, 0x07, 0x72, 0x65, 0x65, 0x6e, 0x74, 0x65, 0x72, 0x00,
    0x00, 0x03, 0x08, 0x07, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x0d,
    0x03, 0x01, 0x00, 0x00, 0x07, 0x23, 0x04, 0x04, 0x62, 0x6f, 0x6f, 0x6d,
    0x00, 0x03, 0x08, 0x74, 0x61, 0x69, 0x6c, 0x62, 0x6f, 0x6f, 0x6d, 0x00,
    0x05, 0x05, 0x6f, 0x75, 0x74, 0x65, 0x72, 0x00, 0x06, 0x05, 0x74, 0x68,
    0x72, 0x6f, 0x77, 0x00, 0x07, 0x0a, 0x2d, 0x07, 0x07, 0x01, 0x01, 0x7e,
    0x20, 0x00, 0x00, 0x0b, 0x06, 0x00, 0x20, 0x00, 0x10, 0x01, 0x0b, 0x06,
    0x00, 0x20, 0x00, 0x10, 0x02, 0x0b, 0x05, 0x01, 0x02, 0x7f, 0x00, 0x0b,
    0x04, 0x00, 0x12, 0x04, 0x0b, 0x05, 0x00, 0x01, 0x10, 0x00, 0x0b, 0x04,
    0x00, 0x08, 0x00, 0x0b, 0x00, 0x39, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01,
    0x2c, 0x05, 0x00, 0x07, 0x72, 0x65, 0x65, 0x6e, 0x74, 0x65, 0x72, 0x01,
    0x06, 0x68, 0x65, 0x6c, 0x70, 0x65, 0x72, 0x02, 0x05, 0x69, 0x6e, 0x6e,
    0x65, 0x72, 0x03, 0x04, 0x62, 0x6f, 0x6f, 0x6d, 0x04, 0x0b, 0x74, 0x61,
    0x69, 0x6c, 0x5f, 0x74, 0x61, 0x72, 0x67, 0x65, 0x74, 0x0b, 0x04, 0x01,
    0x00, 0x01, 0x65,
};

static const uint8_t kB[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60,
    0x01, 0x7f, 0x01, 0x7f, 0x02, 0x0a, 0x01, 0x01, 0x61, 0x04, 0x62, 0x6f,
    0x6f, 0x6d, 0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03,
    0x76, 0x69, 0x61, 0x00, 0x01, 0x0a, 0x08, 0x01, 0x06, 0x00, 0x20, 0x00,
    0x10, 0x00, 0x0b, 0x00, 0x0e, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01, 0x07,
    0x01, 0x00, 0x04, 0x62, 0x6f, 0x6f, 0x6d,
};

static const uint8_t kC[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60,
    0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x08, 0x01, 0x00, 0x0a, 0x08, 0x01,
    0x06, 0x01, 0x01, 0x7f, 0x01, 0x00, 0x0b, 0x00, 0x0b, 0x04, 0x6e, 0x61,
    0x6d, 0x65, 0x01, 0x04, 0x01, 0x00, 0x01, 0x73,
};

static const uint8_t kD[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60,
    0x00, 0x00, 0x02, 0x0e, 0x01, 0x01, 0x61, 0x08, 0x74, 0x61, 0x69, 0x6c,
    0x62, 0x6f, 0x6f, 0x6d, 0x00, 0x00, 0x08, 0x01, 0x00, 0x00, 0x0b, 0x04,
    0x6e, 0x61, 0x6d, 0x65, 0x01, 0x04, 0x01, 0x00, 0x01, 0x74,
};

static const uint8_t kE[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x01, 0x7f, 0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x64,
    0x65, 0x65, 0x70, 0x00, 0x00, 0x0a, 0x12, 0x01, 0x10, 0x00, 0x20, 0x00,
    0x45, 0x04, 0x40, 0x00, 0x0b, 0x20, 0x00, 0x41, 0x01, 0x6b, 0x10, 0x00,
    0x0b, 0x00, 0x0b, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01, 0x04, 0x01, 0x00,
    0x01, 0x72,
};

enum { EXP_BOOM = 0, EXP_TAILBOOM = 1, EXP_OUTER = 2, EXP_THROW = 3 };

typedef struct { uint32_t func; size_t module_offset; size_t func_offset; } want_frame;

static const want_frame kBoomTrace[] = { { 1, 0x62, 5 }, { 2, 0x68, 3 }, { 3, 0x6f, 3 } };
static const want_frame kTailTrace[] = { { 4, 0x76, 3 } };
static const want_frame kOuterTrace[] = { { 6, 0x80, 2 } };
static const want_frame kViaTrace[] = { { 1, 0x62, 5 }, { 2, 0x68, 3 }, { 3, 0x6f, 3 }, { 1, 0x30, 3 } };
static const want_frame kStartTrace[] = { { 0, 0x1d, 4 } };

enum { DEEP_ARG = 100, TRACE_CAP = 64 };

static const wasm_func_t* g_boom = NULL;

static wasm_trap_t* reenter(void* env, const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    (void) env;
    (void) args;
    (void) results;
    wasm_val_t arg = WASM_I32_VAL(1);
    wasm_val_t res = WASM_INIT_VAL;
    wasm_val_vec_t a = { 1, &arg };
    wasm_val_vec_t r = { 1, &res };
    return wasm_func_call(g_boom, &a, &r);
}

static bool frame_is(const char* what, size_t i, const wasm_frame_t* f, want_frame w) {
    if (!f) { fprintf(stderr, "%s: frame %zu missing\n", what, i); return false; }
    uint32_t func = wasm_frame_func_index(f);
    size_t mod = wasm_frame_module_offset(f);
    size_t fn = wasm_frame_func_offset(f);
    if (func != w.func || mod != w.module_offset || fn != w.func_offset || wasm_frame_instance(f) != NULL) {
        fprintf(stderr, "%s: frame %zu is func %u @0x%zx (+%zu), want func %u @0x%zx (+%zu) with no instance\n",
                what, i, func, mod, fn, w.func, w.module_offset, w.func_offset);
        return false;
    }
    return true;
}

/* The trap's origin and trace match `want` (n == 0: no origin, empty trace). */
static bool trap_is(const char* what, const wasm_trap_t* trap, const want_frame* want, size_t n) {
    if (!trap) { fprintf(stderr, "%s: did not trap\n", what); return false; }
    bool ok = true;
    wasm_frame_t* origin = wasm_trap_origin(trap);
    if (n == 0) {
        if (origin) { fprintf(stderr, "%s: origin is not NULL\n", what); ok = false; }
    } else {
        ok = frame_is(what, 0, origin, want[0]) && ok;
    }
    if (origin) wasm_frame_delete(origin);

    wasm_frame_vec_t trace;
    wasm_trap_trace(trap, &trace);
    if (trace.size != n) {
        fprintf(stderr, "%s: trace has %zu frames, want %zu\n", what, trace.size, n);
        ok = false;
    } else {
        for (size_t i = 0; i < n; i++) ok = frame_is(what, i, trace.data[i], want[i]) && ok;
    }
    wasm_frame_vec_delete(&trace);
    return ok;
}

/* Instantiates `bytes` and returns the trap its start function raised. */
static wasm_trap_t* start_trap(wasm_store_t* store, const uint8_t* bytes, size_t n,
                               wasm_extern_vec_t* imports, uint8_t engine) {
    wasm_byte_vec_t bin = { n, (wasm_byte_t*) bytes };
    wasm_module_t* mod = wasm_module_new(store, &bin);
    if (!mod) return NULL;
    wasm_trap_t* trap = NULL;
    wasm_instance_t* inst = zwasm_instance_new_ex(store, mod, imports, &trap, engine);
    if (inst) wasm_instance_delete(inst);
    wasm_module_delete(mod);
    return trap;
}

static wasm_trap_t* call(const wasm_extern_vec_t* exports, size_t idx, bool with_arg) {
    wasm_val_t arg = WASM_I32_VAL(1);
    wasm_val_t res = WASM_INIT_VAL;
    wasm_val_vec_t a = { with_arg ? 1 : 0, with_arg ? &arg : NULL };
    wasm_val_vec_t r = { with_arg ? 1 : 0, with_arg ? &res : NULL };
    return wasm_func_call(wasm_extern_as_func(exports->data[idx]), &a, &r);
}

static int run(uint8_t engine, const char* name) {
    int rc = 1;
    bool interp = engine == ZWASM_ENGINE_INTERP;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    wasm_module_t* mod_a = NULL;
    wasm_module_t* mod_b = NULL;
    wasm_functype_t* ft = NULL;
    wasm_func_t* host = NULL;
    wasm_instance_t* inst_a = NULL;
    wasm_instance_t* inst_b = NULL;
    wasm_extern_vec_t ex_a = { 0, NULL };
    wasm_extern_vec_t ex_b = { 0, NULL };
    wasm_module_t* mod_e = NULL;
    wasm_instance_t* inst_e = NULL;
    wasm_extern_vec_t ex_e = { 0, NULL };
    wasm_trap_t* t = NULL;
    if (!store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t bin_a = { sizeof(kA), (wasm_byte_t*) kA };
    wasm_byte_vec_t bin_b = { sizeof(kB), (wasm_byte_t*) kB };
    mod_a = wasm_module_new(store, &bin_a);
    mod_b = wasm_module_new(store, &bin_b);
    if (!mod_a || !mod_b) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    ft = wasm_functype_new_0_0();
    host = wasm_func_new_with_env(store, ft, reenter, NULL, NULL);
    wasm_extern_t* imp_a[] = { wasm_func_as_extern(host) };
    wasm_extern_vec_t imports_a = { 1, imp_a };
    wasm_trap_t* itrap = NULL;
    inst_a = zwasm_instance_new_ex(store, mod_a, &imports_a, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!inst_a) { fprintf(stderr, "[%s] instantiate A failed\n", name); goto cleanup; }
    wasm_instance_exports(inst_a, &ex_a);
    if (ex_a.size != 4) { fprintf(stderr, "[%s] A has %zu exports\n", name, ex_a.size); goto cleanup; }
    g_boom = wasm_extern_as_func(ex_a.data[EXP_BOOM]);

    t = call(&ex_a, EXP_BOOM, true);
    if (!trap_is("boom", t, interp ? kBoomTrace : NULL, interp ? 3 : 0)) goto cleanup;
    /* A copy carries the same frames. */
    wasm_trap_t* copy = wasm_trap_copy(t);
    bool copy_ok = trap_is("boom (copy)", copy, interp ? kBoomTrace : NULL, interp ? 3 : 0);
    if (copy) wasm_trap_delete(copy);
    wasm_trap_delete(t);
    t = NULL;
    if (!copy_ok) goto cleanup;

    /* The tail callee replaced its caller's frame, and its own is reported. */
    t = call(&ex_a, EXP_TAILBOOM, false);
    if (!trap_is("tailboom", t, interp ? kTailTrace : NULL, interp ? 1 : 0)) goto cleanup;
    wasm_trap_delete(t);

    /* The trap the host returned is a new failure at the host-call site. */
    t = call(&ex_a, EXP_OUTER, false);
    if (!trap_is("outer", t, interp ? kOuterTrace : NULL, interp ? 1 : 0)) goto cleanup;
    wasm_trap_delete(t);

    /* An exception no frame catches has no origin. */
    t = call(&ex_a, EXP_THROW, false);
    if (!trap_is("throw", t, NULL, 0)) goto cleanup;
    wasm_trap_delete(t);
    t = NULL;

    /* A start function's trap carries its trace too. */
    wasm_extern_vec_t no_imports = { 0, NULL };
    t = start_trap(store, kC, sizeof(kC), &no_imports, engine);
    if (!trap_is("start", t, interp ? kStartTrace : NULL, interp ? 1 : 0)) goto cleanup;
    wasm_trap_delete(t);
    t = NULL;

    /* Past 64 frames the trace keeps the innermost ones, the origin first. */
    wasm_byte_vec_t bin_e = { sizeof(kE), (wasm_byte_t*) kE };
    mod_e = wasm_module_new(store, &bin_e);
    itrap = NULL;
    inst_e = mod_e ? zwasm_instance_new_ex(store, mod_e, &no_imports, &itrap, engine) : NULL;
    if (itrap) wasm_trap_delete(itrap);
    if (!inst_e) { fprintf(stderr, "[%s] instantiate E failed\n", name); goto cleanup; }
    wasm_instance_exports(inst_e, &ex_e);
    {
        wasm_val_t arg = WASM_I32_VAL(DEEP_ARG);
        wasm_val_vec_t a = { 1, &arg };
        wasm_val_vec_t r = { 0, NULL };
        t = wasm_func_call(wasm_extern_as_func(ex_e.data[0]), &a, &r);
    }
    want_frame deep[TRACE_CAP];
    deep[0] = (want_frame) { 0, 0x27, 6 };
    for (size_t i = 1; i < TRACE_CAP; i++) deep[i] = (want_frame) { 0, 0x2e, 13 };
    if (!trap_is("deep", t, interp ? deep : NULL, interp ? TRACE_CAP : 0)) goto cleanup;
    wasm_trap_delete(t);
    t = NULL;

    if (interp) {
        /* An imported start reaches the exporting instance's frames. */
        wasm_extern_t* imp_d[] = { ex_a.data[EXP_TAILBOOM] };
        wasm_extern_vec_t imports_d = { 1, imp_d };
        t = start_trap(store, kD, sizeof(kD), &imports_d, engine);
        if (!trap_is("imported start", t, kTailTrace, 1)) goto cleanup;
        wasm_trap_delete(t);
        t = NULL;

        /* The trace crosses into the importing instance in call order. */
        wasm_extern_t* imp_b[] = { ex_a.data[EXP_BOOM] };
        wasm_extern_vec_t imports_b = { 1, imp_b };
        inst_b = zwasm_instance_new_ex(store, mod_b, &imports_b, &itrap, engine);
        if (itrap) wasm_trap_delete(itrap);
        if (!inst_b) { fprintf(stderr, "[%s] instantiate B failed\n", name); goto cleanup; }
        wasm_instance_exports(inst_b, &ex_b);
        t = call(&ex_b, 0, true);
        if (!trap_is("via", t, kViaTrace, 4)) goto cleanup;
        wasm_trap_delete(t);
        t = NULL;
    }

    printf("[%s] trap origin and trace — ok\n", name);
    rc = 0;

cleanup:
    if (t) wasm_trap_delete(t);
    wasm_extern_vec_delete(&ex_e);
    if (inst_e) wasm_instance_delete(inst_e);
    if (mod_e) wasm_module_delete(mod_e);
    wasm_extern_vec_delete(&ex_b);
    wasm_extern_vec_delete(&ex_a);
    if (inst_b) wasm_instance_delete(inst_b);
    if (inst_a) wasm_instance_delete(inst_a);
    if (host) wasm_func_delete(host);
    if (ft) wasm_functype_delete(ft);
    if (mod_b) wasm_module_delete(mod_b);
    if (mod_a) wasm_module_delete(mod_a);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    if (run(ZWASM_ENGINE_INTERP, "interp") != 0) return 1;
    if (run(ZWASM_ENGINE_JIT, "jit") != 0) return 1;
    return 0;
}
