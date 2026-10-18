/* zwasm v2 — C-API conformance: a parked instance's function, reached through
 * a funcref, still runs (#539, #555)
 *
 * Contract pinned here: after wasm_instance_delete(A), A's runtime still runs
 * for an instance that imported from it, and a funcref into A that a host is
 * handed resolves through wasm_ref_as_func to a function wasm_func_call runs,
 * as the import does, rather than one that reads freed memory. The same holds
 * for C, whose instantiation fails after its first element segment wrote into
 * a host table: the funcref it left there runs. A parked instance lives until
 * wasm_store_delete (ADR-0014 §2.1). Interpreter only: a JIT-backed instance
 * cannot import an interp-backed one.
 *
 *   A: (module
 *        (import "h" "h" (func $h (param funcref)))
 *        (func $g)
 *        (elem declare func $g)
 *        (func (export "f") (call $h (ref.func $g))))
 *   B: (module (import "a" "f" (func $f)) (func (export "call") call $f))
 *   C: (module
 *        (import "t" "t" (table 2 funcref))
 *        (func $fc (result i32) i32.const 222)
 *        (elem (i32.const 0) func $fc)
 *        (elem (i32.const 5) func $fc))   ;; out of bounds: instantiation traps
 *
 * The host calls the funcref it is handed and records the trap kind (-1: none).
 * Exits 0 when the call runs both before and after the delete, and C's runs.
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

static const uint8_t kC[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x02, 0x09, 0x01, 0x01, 0x74, 0x01, 0x74, 0x01, 0x70,
    0x00, 0x02, 0x03, 0x02, 0x01, 0x00, 0x09, 0x0d, 0x02, 0x00, 0x41, 0x00,
    0x0b, 0x01, 0x00, 0x00, 0x41, 0x05, 0x0b, 0x01, 0x00, 0x0a, 0x07, 0x01,
    0x05, 0x00, 0x41, 0xde, 0x01, 0x0b, 0x00, 0x0c, 0x04, 0x6e, 0x61, 0x6d,
    0x65, 0x01, 0x05, 0x01, 0x00, 0x02, 0x66, 0x63,
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

/* C fails to instantiate after writing $fc into slot 0 of a host table; a
 * standalone table's Ref names no instance, so wasm_ref_as_func finds C's.
 * Returns 0 when that funcref runs and yields 222. */
static int failed_instance_funcref(wasm_store_t* store) {
    int rc = 1;
    wasm_byte_vec_t bin = { sizeof(kC), (wasm_byte_t*) kC };
    wasm_module_t* mod = wasm_module_new(store, &bin);
    wasm_limits_t lim = { 2, 2 };
    wasm_tabletype_t* tt = wasm_tabletype_new(wasm_valtype_new(WASM_FUNCREF), &lim);
    wasm_table_t* tab = mod ? wasm_table_new(store, tt, NULL) : NULL;
    wasm_ref_t* r = NULL;
    wasm_trap_t* t = NULL;
    if (!tab) { fputs("module C / table new failed\n", stderr); goto out; }
    wasm_extern_t* imp[] = { wasm_table_as_extern(tab) };
    wasm_extern_vec_t imports = { 1, imp };
    wasm_instance_t* inst = zwasm_instance_new_ex(store, mod, &imports, &t, ZWASM_ENGINE_INTERP);
    if (t) { wasm_trap_delete(t); t = NULL; }
    if (inst) { fputs("instantiate C succeeded, want it to fail\n", stderr); wasm_instance_delete(inst); goto out; }
    r = wasm_table_get(tab, 0);
    wasm_func_t* fn = r ? wasm_ref_as_func(r) : NULL;
    if (!fn) { fputs("failed C: slot 0 holds no function\n", stderr); goto out; }
    wasm_val_t out[1];
    wasm_val_vec_t none = { 0, NULL };
    wasm_val_vec_t res = { 1, out };
    t = wasm_func_call(fn, &none, &res);
    if (t || out[0].of.i32 != 222) {
        fprintf(stderr, "failed C: trap kind=%d value=%d, want 222\n",
                t ? (int) zwasm_trap_kind(t) : -1, t ? 0 : (int) out[0].of.i32);
        goto out;
    }
    printf("[interp] a failed instance's function runs through a funcref — ok\n");
    rc = 0;
out:
    if (t) wasm_trap_delete(t);
    if (r) wasm_ref_delete(r);
    if (tab) wasm_table_delete(tab);
    wasm_tabletype_delete(tt);
    if (mod) wasm_module_delete(mod);
    return rc;
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
    if (t || g_kind != -1) {
        fprintf(stderr, "after delete: trap=%p kind=%d, want no trap and the funcref call run (-1)\n", (void*) t, (int) g_kind);
        goto cleanup;
    }
    printf("[interp] a deleted instance's function runs through a funcref — ok\n");
    rc = failed_instance_funcref(store);

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
