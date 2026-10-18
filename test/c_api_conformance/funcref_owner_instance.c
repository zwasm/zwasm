/* zwasm v2 — C-API conformance: a funcref handed to the host names the
 * function's own instance, whichever instance handed it over (#566)
 *
 * Contract pinned here: wasm_ref_as_func on a funcref B minted resolves to
 * B's function, whether the host reads it out of A's table or A's global,
 * gets it back as A's result, or is handed it as an argument by a host call
 * A makes. B's $fb and A's function 1 share an index, so resolving against A
 * runs A's function (112, or 113 in H) instead of B's (222), with no trap.
 *
 *   A: (module
 *        (table (export "t") 2 funcref)
 *        (global (export "g") (mut funcref) (ref.null func))
 *        (func $fa0 (result i32) i32.const 111)
 *        (func $fa1 (result i32) i32.const 112)
 *        (func (export "id") (param funcref) (result funcref) local.get 0)
 *        (func (export "id2") (param funcref) (result funcref i32)
 *          local.get 0 i32.const 7))
 *   B: (module
 *        (func $pad (result i32) i32.const 221)
 *        (func $fb (export "fb") (result i32) i32.const 222)
 *        (elem declare func $fb)
 *        (func (export "get") (result funcref) ref.func $fb))
 *   H: (module
 *        (import "h" "h" (func $h (param funcref)))
 *        (func $fh1 (result i32) i32.const 113)
 *        (func (export "pass") (param funcref) (call $h (local.get 0))))
 *   W: (module          ;; B's shape, writing $fb into A's table itself
 *        (import "a" "t" (table 2 funcref))
 *        (func $pad (result i32) i32.const 221)
 *        (func $fb (result i32) i32.const 222)
 *        (elem (i32.const 0) func $fb))
 *   I: (module          ;; imports B's $fb at index 0
 *        (type $r (func (result i32)))
 *        (import "b" "fb" (func $fb (result i32)))
 *        (table 1 funcref)
 *        (elem declare func $fb)
 *        (func (export "get") (result funcref) ref.func $fb)
 *        (func (export "ci") (result i32)
 *          (table.set (i32.const 0) (ref.func $fb))
 *          (call_indirect (type $r) (i32.const 0))))
 *
 * B's funcref comes from its "get" result, which names B on both engines
 * (wasm_func_as_ref is NULL for a JIT-backed function). Every A × B engine
 * pair runs, except: H only on the interpreter, because the JIT's host bridge
 * declines a funcref parameter; W only with A and W both on the interpreter,
 * because a JIT-backed instance cannot import a table. I's funcref to its
 * import names B, the defining instance, and I's own call_indirect through it
 * still reaches B; I runs on B's engine. The same funcref of B's resolves
 * after B is deleted, until the store goes.
 * Exits 0 when every path yields 222.
 */

#include <stdio.h>
#include <stdint.h>

#include <wasm.h>
#include <zwasm.h>

static const uint8_t kA[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03, 0x60,
    0x00, 0x01, 0x7f, 0x60, 0x01, 0x70, 0x01, 0x70, 0x60, 0x01, 0x70, 0x02,
    0x70, 0x7f, 0x03, 0x05, 0x04, 0x00, 0x00, 0x01, 0x02, 0x04, 0x04, 0x01,
    0x70, 0x00, 0x02, 0x06, 0x06, 0x01, 0x70, 0x01, 0xd0, 0x70, 0x0b, 0x07,
    0x14, 0x04, 0x01, 0x74, 0x01, 0x00, 0x01, 0x67, 0x03, 0x00, 0x02, 0x69,
    0x64, 0x00, 0x02, 0x03, 0x69, 0x64, 0x32, 0x00, 0x03, 0x0a, 0x19, 0x04,
    0x05, 0x00, 0x41, 0xef, 0x00, 0x0b, 0x05, 0x00, 0x41, 0xf0, 0x00, 0x0b,
    0x04, 0x00, 0x20, 0x00, 0x0b, 0x06, 0x00, 0x20, 0x00, 0x41, 0x07, 0x0b,
    0x00, 0x12, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01, 0x0b, 0x02, 0x00, 0x03,
    0x66, 0x61, 0x30, 0x01, 0x03, 0x66, 0x61, 0x31,
};

static const uint8_t kB[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x09, 0x02, 0x60,
    0x00, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x70, 0x03, 0x04, 0x03, 0x00, 0x00,
    0x01, 0x07, 0x0c, 0x02, 0x02, 0x66, 0x62, 0x00, 0x01, 0x03, 0x67, 0x65,
    0x74, 0x00, 0x02, 0x09, 0x05, 0x01, 0x03, 0x00, 0x01, 0x01, 0x0a, 0x12,
    0x03, 0x05, 0x00, 0x41, 0xdd, 0x01, 0x0b, 0x05, 0x00, 0x41, 0xde, 0x01,
    0x0b, 0x04, 0x00, 0xd2, 0x01, 0x0b, 0x00, 0x11, 0x04, 0x6e, 0x61, 0x6d,
    0x65, 0x01, 0x0a, 0x02, 0x00, 0x03, 0x70, 0x61, 0x64, 0x01, 0x02, 0x66,
    0x62,
};

static const uint8_t kH[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x09, 0x02, 0x60,
    0x01, 0x70, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x02, 0x07, 0x01, 0x01, 0x68,
    0x01, 0x68, 0x00, 0x00, 0x03, 0x03, 0x02, 0x01, 0x00, 0x07, 0x08, 0x01,
    0x04, 0x70, 0x61, 0x73, 0x73, 0x00, 0x02, 0x0a, 0x0e, 0x02, 0x05, 0x00,
    0x41, 0xf1, 0x00, 0x0b, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b, 0x00,
    0x10, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01, 0x09, 0x02, 0x00, 0x01, 0x68,
    0x01, 0x03, 0x66, 0x68, 0x31,
};

static const uint8_t kW[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x02, 0x09, 0x01, 0x01, 0x61, 0x01, 0x74, 0x01, 0x70,
    0x00, 0x02, 0x03, 0x03, 0x02, 0x00, 0x00, 0x09, 0x07, 0x01, 0x00, 0x41,
    0x00, 0x0b, 0x01, 0x01, 0x0a, 0x0d, 0x02, 0x05, 0x00, 0x41, 0xdd, 0x01,
    0x0b, 0x05, 0x00, 0x41, 0xde, 0x01, 0x0b, 0x00, 0x11, 0x04, 0x6e, 0x61,
    0x6d, 0x65, 0x01, 0x0a, 0x02, 0x00, 0x03, 0x70, 0x61, 0x64, 0x01, 0x02,
    0x66, 0x62,
};

static const uint8_t kI[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x09, 0x02, 0x60,
    0x00, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x70, 0x02, 0x08, 0x01, 0x01, 0x62,
    0x02, 0x66, 0x62, 0x00, 0x00, 0x03, 0x03, 0x02, 0x01, 0x00, 0x04, 0x04,
    0x01, 0x70, 0x00, 0x01, 0x07, 0x0c, 0x02, 0x03, 0x67, 0x65, 0x74, 0x00,
    0x01, 0x02, 0x63, 0x69, 0x00, 0x02, 0x09, 0x05, 0x01, 0x03, 0x00, 0x01,
    0x00, 0x0a, 0x14, 0x02, 0x04, 0x00, 0xd2, 0x00, 0x0b, 0x0d, 0x00, 0x41,
    0x00, 0xd2, 0x00, 0x26, 0x00, 0x41, 0x00, 0x11, 0x00, 0x00, 0x0b,
};

static const char* const kEngineName[] = { "interp", "jit" };
static const uint8_t kEngine[] = { ZWASM_ENGINE_INTERP, ZWASM_ENGINE_JIT };

static wasm_store_t* g_store;
static int g_failures;

static wasm_instance_t* instantiate(const uint8_t* bytes, size_t len, wasm_extern_vec_t* imports, int engine) {
    wasm_byte_vec_t bin = { len, (wasm_byte_t*) bytes };
    wasm_module_t* mod = wasm_module_new(g_store, &bin);
    if (!mod) return NULL;
    wasm_extern_vec_t none = { 0, NULL };
    wasm_trap_t* t = NULL;
    wasm_instance_t* inst = zwasm_instance_new_ex(g_store, mod, imports ? imports : &none, &t, kEngine[engine]);
    if (t) wasm_trap_delete(t);
    wasm_module_delete(mod);
    return inst;
}

/* Resolve r and call it. -1: no ref, -2: no function, -100-kind: a trap. */
static int call_ref(wasm_ref_t* r) {
    if (!r) return -1;
    wasm_func_t* fn = wasm_ref_as_func(r);
    if (!fn) return -2;
    wasm_val_t out[1];
    wasm_val_vec_t none = { 0, NULL };
    wasm_val_vec_t res = { 1, out };
    wasm_trap_t* t = wasm_func_call(fn, &none, &res);
    if (t) {
        int kind = (int) zwasm_trap_kind(t);
        wasm_trap_delete(t);
        return -100 - kind;
    }
    return out[0].of.i32;
}

static void check(const char* path, int a, int b, int got) {
    if (got == 222) {
        printf("[A=%s B=%s] %s — ok\n", kEngineName[a], kEngineName[b], path);
    } else {
        fprintf(stderr, "[A=%s B=%s] %s: got %d, want 222\n", kEngineName[a], kEngineName[b], path, got);
        g_failures++;
    }
}

static int g_host_got;

static wasm_trap_t* host(const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    (void) results;
    g_host_got = call_ref(args->data[0].of.ref);
    return NULL;
}

static void host_arg(wasm_ref_t* rb, int b) {
    wasm_functype_t* ft = wasm_functype_new_1_0(wasm_valtype_new(WASM_FUNCREF));
    wasm_func_t* h = wasm_func_new(g_store, ft, host);
    wasm_extern_t* imp[] = { wasm_func_as_extern(h) };
    wasm_extern_vec_t imports = { 1, imp };
    wasm_instance_t* ih = instantiate(kH, sizeof(kH), &imports, 0);
    if (!ih) {
        fprintf(stderr, "[A=interp B=%s] instantiate H failed\n", kEngineName[b]);
        g_failures++;
    } else {
        wasm_extern_vec_t xh;
        wasm_instance_exports(ih, &xh);
        wasm_val_t arg[1] = { { .kind = WASM_FUNCREF, .of = { .ref = rb } } };
        wasm_val_vec_t args = { 1, arg };
        wasm_val_vec_t no_res = { 0, NULL };
        g_host_got = -3; /* -3: the host was not called */
        wasm_trap_t* t = wasm_func_call(wasm_extern_as_func(xh.data[0]), &args, &no_res);
        if (t) wasm_trap_delete(t);
        check("host call argument", 0, b, g_host_got);
        wasm_extern_vec_delete(&xh);
        wasm_instance_delete(ih);
    }
    wasm_func_delete(h);
    wasm_functype_delete(ft);
}

/* W writes its own $fb into A's table through an element segment. */
static void elem_write(wasm_extern_t* table) {
    wasm_extern_t* imp[] = { table };
    wasm_extern_vec_t imports = { 1, imp };
    wasm_instance_t* iw = instantiate(kW, sizeof(kW), &imports, 0);
    if (!iw) {
        fputs("[A=interp B=interp] instantiate W failed\n", stderr);
        g_failures++;
        return;
    }
    wasm_ref_t* r = wasm_table_get(wasm_extern_as_table(table), 0);
    check("wasm_table_get after an element segment", 0, 0, call_ref(r));
    if (r) wasm_ref_delete(r);
    wasm_instance_delete(iw);
}

static void run_pair(int a, int b) {
    wasm_instance_t* ib = instantiate(kB, sizeof(kB), NULL, b);
    wasm_instance_t* ia = instantiate(kA, sizeof(kA), NULL, a);
    wasm_extern_vec_t xa = { 0, NULL };
    wasm_extern_vec_t xb = { 0, NULL };
    wasm_val_t got_b[1] = { { .kind = WASM_FUNCREF, .of = { .ref = NULL } } };
    if (!ia || !ib) {
        fprintf(stderr, "[A=%s B=%s] instantiate failed\n", kEngineName[a], kEngineName[b]);
        g_failures++;
        goto out;
    }
    wasm_instance_exports(ia, &xa);
    wasm_instance_exports(ib, &xb);

    wasm_val_vec_t none = { 0, NULL };
    wasm_val_vec_t res_b = { 1, got_b };
    wasm_trap_t* t = wasm_func_call(wasm_extern_as_func(xb.data[1]), &none, &res_b);
    if (t) {
        wasm_trap_delete(t);
        fprintf(stderr, "[A=%s B=%s] B.get trapped\n", kEngineName[a], kEngineName[b]);
        g_failures++;
        goto out;
    }
    wasm_ref_t* rb = got_b[0].of.ref;

    wasm_table_t* tab = wasm_extern_as_table(xa.data[0]);
    if (!wasm_table_set(tab, 0, rb)) {
        fprintf(stderr, "[A=%s B=%s] wasm_table_set refused\n", kEngineName[a], kEngineName[b]);
        g_failures++;
    }
    wasm_ref_t* r = wasm_table_get(tab, 0);
    check("wasm_table_get", a, b, call_ref(r));
    if (r) wasm_ref_delete(r);

    wasm_global_t* g = wasm_extern_as_global(xa.data[1]);
    wasm_val_t gv = { .kind = WASM_FUNCREF, .of = { .ref = rb } };
    wasm_global_set(g, &gv);
    wasm_val_t gout;
    wasm_global_get(g, &gout);
    check("wasm_global_get", a, b, call_ref(gout.of.ref));
    if (gout.of.ref) wasm_ref_delete(gout.of.ref);

    wasm_val_t arg[1] = { { .kind = WASM_FUNCREF, .of = { .ref = rb } } };
    wasm_val_vec_t args = { 1, arg };
    wasm_val_t out[2];
    wasm_val_vec_t res1 = { 1, out };
    t = wasm_func_call(wasm_extern_as_func(xa.data[2]), &args, &res1);
    if (t) { wasm_trap_delete(t); out[0].of.ref = NULL; }
    check("wasm_func_call result", a, b, call_ref(out[0].of.ref));
    if (out[0].of.ref) wasm_ref_delete(out[0].of.ref);
    wasm_val_vec_t res2 = { 2, out };
    t = wasm_func_call(wasm_extern_as_func(xa.data[3]), &args, &res2);
    if (t) { wasm_trap_delete(t); out[0].of.ref = NULL; }
    check("wasm_func_call multi-value result", a, b, call_ref(out[0].of.ref));
    if (out[0].of.ref) wasm_ref_delete(out[0].of.ref);

    if (a == 0) host_arg(rb, b);
    if (a == 0 && b == 0) elem_write(xa.data[0]);

out:
    if (got_b[0].of.ref) wasm_ref_delete(got_b[0].of.ref);
    wasm_extern_vec_delete(&xa);
    wasm_extern_vec_delete(&xb);
    if (ia) wasm_instance_delete(ia);
    if (ib) wasm_instance_delete(ib);
}

static wasm_ref_t* call_get(wasm_instance_t* inst, size_t export_idx) {
    wasm_extern_vec_t xs;
    wasm_instance_exports(inst, &xs);
    wasm_val_t out[1] = { { .kind = WASM_FUNCREF, .of = { .ref = NULL } } };
    wasm_val_vec_t none = { 0, NULL };
    wasm_val_vec_t res = { 1, out };
    wasm_trap_t* t = wasm_func_call(wasm_extern_as_func(xs.data[export_idx]), &none, &res);
    if (t) { wasm_trap_delete(t); out[0].of.ref = NULL; }
    wasm_extern_vec_delete(&xs);
    return out[0].of.ref;
}

/* I imports B's $fb; I's funcref to that import must name B. */
static void import_funcref(int e) {
    wasm_instance_t* ib = instantiate(kB, sizeof(kB), NULL, e);
    wasm_extern_vec_t xb = { 0, NULL };
    wasm_instance_t* ii = NULL;
    if (ib) {
        wasm_instance_exports(ib, &xb);
        wasm_extern_t* imp[] = { xb.data[0] };
        wasm_extern_vec_t imports = { 1, imp };
        ii = instantiate(kI, sizeof(kI), &imports, e);
    }
    if (!ii) {
        fprintf(stderr, "[%s] instantiate B / I failed\n", kEngineName[e]);
        g_failures++;
        goto out;
    }
    wasm_ref_t* r = call_get(ii, 0);
    check("funcref to an import", e, e, call_ref(r));
    if (r) wasm_ref_delete(r);

    wasm_extern_vec_t xi;
    wasm_instance_exports(ii, &xi);
    wasm_val_t out[1];
    wasm_val_vec_t none = { 0, NULL };
    wasm_val_vec_t res = { 1, out };
    wasm_trap_t* t = wasm_func_call(wasm_extern_as_func(xi.data[1]), &none, &res);
    int got;
    if (t) { got = -100 - (int) zwasm_trap_kind(t); wasm_trap_delete(t); }
    else got = out[0].of.i32;
    check("call_indirect through the import's funcref", e, e, got);
    wasm_extern_vec_delete(&xi);
out:
    if (ii) wasm_instance_delete(ii);
    wasm_extern_vec_delete(&xb);
    if (ib) wasm_instance_delete(ib);
}

/* A funcref outlives wasm_instance_delete of the instance that defines it. */
static void deleted_owner(int e) {
    wasm_instance_t* ib = instantiate(kB, sizeof(kB), NULL, e);
    if (!ib) {
        fprintf(stderr, "[%s] instantiate B failed\n", kEngineName[e]);
        g_failures++;
        return;
    }
    wasm_ref_t* r = call_get(ib, 1);
    wasm_instance_delete(ib);
    check("funcref after its instance is deleted", e, e, call_ref(r));
    if (r) wasm_ref_delete(r);
}

int main(void) {
    wasm_engine_t* eng = wasm_engine_new();
    g_store = eng ? wasm_store_new(eng) : NULL;
    if (!g_store) { fputs("engine/store new failed\n", stderr); return 1; }
    for (int a = 0; a < 2; a++)
        for (int b = 0; b < 2; b++) run_pair(a, b);
    for (int e = 0; e < 2; e++) {
        import_funcref(e);
        deleted_owner(e);
    }
    wasm_store_delete(g_store);
    wasm_engine_delete(eng);
    return g_failures == 0 ? 0 : 1;
}
