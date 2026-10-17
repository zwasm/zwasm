/* zwasm v2 — C-API conformance: a deleted instance's function, reached through
 * a funcref, is not found (#539)
 *
 * Contract pinned here: after wasm_instance_delete(A), A's runtime still runs
 * for an instance that imported from it, and a funcref into A that a host is
 * handed resolves through wasm_ref_as_func to a function wasm_func_call answers
 * with a BINDING_ERROR trap — not found — rather than one that runs or reads
 * freed memory. Before the delete the same call runs. Interpreter only: a
 * JIT-backed instance cannot import an interp-backed one.
 *
 *   A: (module
 *        (import "h" "h" (func $h (param funcref)))
 *        (func $g)
 *        (elem declare func $g)
 *        (func (export "f") (call $h (ref.func $g))))
 *   B: (module (import "a" "f" (func $f)) (func (export "call") call $f))
 *
 * The host calls the funcref it is handed and records the trap kind (-1: none).
 * Exits 0 when the call runs before the delete and is not found after it.
 */

#include <stdio.h>
#include <stdint.h>

#include <wasm.h>
#include <zwasm.h>

static const uint8_t kA[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60,
    0x01, 0x70, 0x00, 0x60, 0x00, 0x00, 0x02, 0x07, 0x01, 0x01, 0x68, 0x01,
    0x68, 0x00, 0x00, 0x03, 0x03, 0x02, 0x01, 0x01, 0x07, 0x05, 0x01, 0x01,
    0x66, 0x00, 0x02, 0x09, 0x05, 0x01, 0x03, 0x00, 0x01, 0x01, 0x0a, 0x0b,
    0x02, 0x02, 0x00, 0x0b, 0x06, 0x00, 0xd2, 0x01, 0x10, 0x00, 0x0b, 0x00,
    0x0e, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01, 0x07, 0x02, 0x00, 0x01, 0x68,
    0x01, 0x01, 0x67,
};

static const uint8_t kB[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60,
    0x00, 0x00, 0x02, 0x07, 0x01, 0x01, 0x61, 0x01, 0x66, 0x00, 0x00, 0x03,
    0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x63, 0x61, 0x6c, 0x6c, 0x00,
    0x01, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b, 0x00, 0x0b, 0x04,
    0x6e, 0x61, 0x6d, 0x65, 0x01, 0x04, 0x01, 0x00, 0x01, 0x66,
};

static int32_t g_kind = -2; /* -2: the host was not called */

static wasm_trap_t* host(const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    (void) results;
    g_kind = -3; /* -3: the funcref did not resolve to a function */
    wasm_func_t* fn = wasm_ref_as_func(args->data[0].of.ref);
    if (!fn) return NULL;
    wasm_val_vec_t none = { 0, NULL };
    wasm_val_vec_t no_res = { 0, NULL };
    wasm_trap_t* trap = wasm_func_call(fn, &none, &no_res);
    g_kind = trap ? zwasm_trap_kind(trap) : -1;
    if (trap) wasm_trap_delete(trap);
    return NULL;
}

static wasm_trap_t* call0(wasm_extern_t* e) {
    wasm_val_vec_t none = { 0, NULL };
    wasm_val_vec_t no_res = { 0, NULL };
    return wasm_func_call(wasm_extern_as_func(e), &none, &no_res);
}

int main(void) {
    int rc = 1;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    wasm_module_t* mod_a = NULL;
    wasm_module_t* mod_b = NULL;
    wasm_functype_t* ft = NULL;
    wasm_func_t* h = NULL;
    wasm_instance_t* inst_b = NULL;
    wasm_extern_vec_t ex_b = { 0, NULL };
    wasm_trap_t* t = NULL;
    if (!store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t bin_a = { sizeof(kA), (wasm_byte_t*) kA };
    wasm_byte_vec_t bin_b = { sizeof(kB), (wasm_byte_t*) kB };
    mod_a = wasm_module_new(store, &bin_a);
    mod_b = wasm_module_new(store, &bin_b);
    if (!mod_a || !mod_b) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    ft = wasm_functype_new_1_0(wasm_valtype_new(WASM_FUNCREF));
    h = wasm_func_new(store, ft, host);
    wasm_extern_t* imp_a[] = { wasm_func_as_extern(h) };
    wasm_extern_vec_t imports_a = { 1, imp_a };
    wasm_instance_t* inst_a = zwasm_instance_new_ex(store, mod_a, &imports_a, &t, ZWASM_ENGINE_INTERP);
    if (t) { wasm_trap_delete(t); t = NULL; }
    if (!inst_a) { fputs("instantiate A failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t ex_a;
    wasm_instance_exports(inst_a, &ex_a);
    t = call0(ex_a.data[0]);
    if (t || g_kind != -1) {
        fprintf(stderr, "before delete: trap=%p kind=%d, want no trap and the funcref call run (-1)\n", (void*) t, (int) g_kind);
        wasm_extern_vec_delete(&ex_a);
        wasm_instance_delete(inst_a);
        goto cleanup;
    }
    wasm_extern_t* imp_b[] = { ex_a.data[0] };
    wasm_extern_vec_t imports_b = { 1, imp_b };
    inst_b = zwasm_instance_new_ex(store, mod_b, &imports_b, &t, ZWASM_ENGINE_INTERP);
    if (t) { wasm_trap_delete(t); t = NULL; }
    wasm_extern_vec_delete(&ex_a);
    wasm_instance_delete(inst_a);
    if (!inst_b) { fputs("instantiate B failed\n", stderr); goto cleanup; }

    g_kind = -2;
    wasm_instance_exports(inst_b, &ex_b);
    t = call0(ex_b.data[0]);
    if (t || g_kind != ZWASM_TRAP_BINDING_ERROR) {
        fprintf(stderr, "after delete: trap=%p kind=%d, want no trap and the funcref call not found (%d)\n",
                (void*) t, (int) g_kind, ZWASM_TRAP_BINDING_ERROR);
        goto cleanup;
    }
    printf("[interp] a deleted instance's function is not found through a funcref — ok\n");
    rc = 0;

cleanup:
    if (t) wasm_trap_delete(t);
    wasm_extern_vec_delete(&ex_b);
    if (inst_b) wasm_instance_delete(inst_b);
    if (h) wasm_func_delete(h);
    if (ft) wasm_functype_delete(ft);
    if (mod_b) wasm_module_delete(mod_b);
    if (mod_a) wasm_module_delete(mod_a);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}
