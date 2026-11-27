/* zwasm v2 — C-API conformance: through `wasm_instance_new`, importing a
 * function whose signature is too wide for the arm64 bridge thunk is refused at
 * instantiation (NULL, no trap); a signature one parameter narrower links.
 *
 *   provider: (func (export "big") (param i32 x N) (result i32) local.get 0)
 *   importer: (import "b" "big" (func (param i32 x N) (result i32)))
 *             (func (export "go") (result i32) i32.const 7)
 *
 * Observed: with N=518 the importer is NULL (no trap) on arm64 and instantiates
 * on x86_64; with N=517 it instantiates on every host. `go` returns a constant
 * and never calls `big`, so the observable is the instantiation outcome alone:
 * the thunk for `big` is still emitted at setup (where the bound bites), no
 * cross-module thunk executes (so D-206's qemu limit does not bear on it), and
 * the importer's own body stays off the per-call argument-count cap a
 * 517-argument call would hit first.
 *
 * The bound: the arm64 thunk copies the callee's overflow arguments with a
 * `SUB`/`ADD SP` imm12 (<= 4095 bytes), which 518 `i32` parameters overflow and
 * 517 fit (`sigFitsThunk`, engine/codegen/arm64/thunk.zig); x86_64 uses a
 * `disp32` with no such cap. On arm64 the decline is `UnsupportedEntrySignature`
 * at setup, surfaced as a NULL with no trap because the interpreter cannot bind
 * a function of a JIT-backed instance, so there is no fallback (include/zwasm.h).
 * Exits 0 on the expected outcome for its host.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

static const char* engine_name(uint8_t kind) {
    switch (kind) {
        case ZWASM_ENGINE_JIT: return "jit";
        case ZWASM_ENGINE_INTERP: return "interp";
        default: return "auto";
    }
}

/* ---- a minimal wasm module builder ------------------------------------- */

typedef struct { uint8_t* p; size_t len, cap; } Buf;

static int reserve(Buf* b, size_t extra) {
    if (b->len + extra <= b->cap) return 1;
    size_t cap = b->cap ? b->cap : 256;
    while (cap < b->len + extra) cap *= 2;
    uint8_t* q = (uint8_t*) realloc(b->p, cap);
    if (!q) return 0;
    b->p = q;
    b->cap = cap;
    return 1;
}
static int put(Buf* b, uint8_t x) { if (!reserve(b, 1)) return 0; b->p[b->len++] = x; return 1; }
static int raw(Buf* b, const void* s, size_t n) { if (!reserve(b, n)) return 0; memcpy(b->p + b->len, s, n); b->len += n; return 1; }
static int uleb(Buf* b, uint32_t v) {
    do {
        uint8_t byte = (uint8_t) (v & 0x7f);
        v >>= 7;
        if (v) byte |= 0x80;
        if (!put(b, byte)) return 0;
    } while (v);
    return 1;
}
/* `body` as a section with the given id, length-prefixed. */
static int section(Buf* out, uint8_t id, const Buf* body) {
    return put(out, id) && uleb(out, (uint32_t) body->len) && raw(out, body->p, body->len);
}

static const uint8_t kHeader[8] = { 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

/* (func (export "big") (param i32 x n) (result i32) local.get 0) */
static uint8_t* build_provider(uint32_t n, size_t* out_len) {
    Buf ty = { 0 }, fn = { 0 }, ex = { 0 }, code = { 0 }, fb = { 0 }, m = { 0 };
    uleb(&ty, 1); /* 1 type */
    put(&ty, 0x60);
    uleb(&ty, n);
    for (uint32_t k = 0; k < n; k++) put(&ty, 0x7f); /* i32 params */
    uleb(&ty, 1);
    put(&ty, 0x7f); /* i32 result */
    uleb(&fn, 1);
    uleb(&fn, 0); /* func[0] : type 0 */
    uleb(&ex, 1);
    uleb(&ex, 3);
    raw(&ex, "big", 3);
    put(&ex, 0x00);
    uleb(&ex, 0); /* export "big" -> func 0 */
    uleb(&fb, 0); /* 0 local groups */
    put(&fb, 0x20);
    uleb(&fb, 0); /* local.get 0 */
    put(&fb, 0x0b); /* end */
    uleb(&code, 1);
    uleb(&code, (uint32_t) fb.len);
    raw(&code, fb.p, fb.len);

    raw(&m, kHeader, 8);
    section(&m, 1, &ty);
    section(&m, 3, &fn);
    section(&m, 7, &ex);
    section(&m, 10, &code);

    free(ty.p); free(fn.p); free(ex.p); free(code.p); free(fb.p);
    *out_len = m.len;
    return m.p;
}

/* (import "b" "big" (func (param i32 x n) (result i32)))
 * (func (export "go") (result i32) i32.const 7) */
static uint8_t* build_importer(uint32_t n, size_t* out_len) {
    Buf ty = { 0 }, im = { 0 }, fn = { 0 }, ex = { 0 }, code = { 0 }, fb = { 0 }, m = { 0 };
    uleb(&ty, 2); /* 2 types */
    put(&ty, 0x60); /* type 0 = provider sig */
    uleb(&ty, n);
    for (uint32_t k = 0; k < n; k++) put(&ty, 0x7f);
    uleb(&ty, 1);
    put(&ty, 0x7f);
    put(&ty, 0x60); /* type 1 = () -> i32 */
    uleb(&ty, 0);
    uleb(&ty, 1);
    put(&ty, 0x7f);
    uleb(&im, 1); /* 1 import */
    uleb(&im, 1);
    raw(&im, "b", 1);
    uleb(&im, 3);
    raw(&im, "big", 3);
    put(&im, 0x00);
    uleb(&im, 0); /* func import of type 0 */
    uleb(&fn, 1);
    uleb(&fn, 1); /* func[1] (import is func 0) : type 1 */
    uleb(&ex, 1);
    uleb(&ex, 2);
    raw(&ex, "go", 2);
    put(&ex, 0x00);
    uleb(&ex, 1); /* export "go" -> func 1 */
    uleb(&fb, 0); /* 0 local groups */
    put(&fb, 0x41);
    uleb(&fb, 7); /* i32.const 7 */
    put(&fb, 0x0b); /* end — `big` is imported (forces its thunk) but not called */
    uleb(&code, 1);
    uleb(&code, (uint32_t) fb.len);
    raw(&code, fb.p, fb.len);

    raw(&m, kHeader, 8);
    section(&m, 1, &ty);
    section(&m, 2, &im);
    section(&m, 3, &fn);
    section(&m, 7, &ex);
    section(&m, 10, &code);

    free(ty.p); free(im.p); free(fn.p); free(ex.p); free(code.p); free(fb.p);
    *out_len = m.len;
    return m.p;
}

typedef enum { OUTCOME_RAN_7, OUTCOME_REFUSED, OUTCOME_ERROR } Outcome;

/* Instantiate provider then importer at width `n` on `engine`, and (when the
 * importer links) run `go` and require 7. OUTCOME_REFUSED is the importer
 * coming back NULL with no trap left behind. */
static Outcome link_at(uint8_t engine, uint32_t n) {
    Outcome outcome = OUTCOME_ERROR;
    const char* who = engine_name(engine);
    size_t plen = 0, ilen = 0;
    uint8_t* pbytes = build_provider(n, &plen);
    uint8_t* ibytes = build_importer(n, &ilen);
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    wasm_module_t* pm = NULL, *imz = NULL;
    wasm_instance_t* prov = NULL, *imp = NULL;
    wasm_extern_vec_t pexp = { 0, NULL }, iexp = { 0, NULL };
    if (!pbytes || !ibytes || !eng || !store) { fputs("setup failed\n", stderr); goto done; }

    wasm_byte_vec_t pbin = { plen, (wasm_byte_t*) pbytes };
    pm = wasm_module_new(store, &pbin);
    if (!pm) { fprintf(stderr, "[%s n=%u] provider failed to parse\n", who, n); goto done; }
    wasm_extern_vec_t no_imports = { 0, NULL };
    wasm_trap_t* ptrap = NULL;
    prov = zwasm_instance_new_ex(store, pm, &no_imports, &ptrap, engine);
    if (ptrap) wasm_trap_delete(ptrap);
    if (!prov) { fprintf(stderr, "[%s n=%u] provider failed to instantiate\n", who, n); goto done; }
    wasm_instance_exports(prov, &pexp);
    if (pexp.size < 1 || !pexp.data[0]) { fprintf(stderr, "[%s n=%u] provider exposed nothing\n", who, n); goto done; }

    wasm_byte_vec_t ibin = { ilen, (wasm_byte_t*) ibytes };
    imz = wasm_module_new(store, &ibin);
    if (!imz) { fprintf(stderr, "[%s n=%u] importer failed to parse\n", who, n); goto done; }
    wasm_extern_t* externs[1] = { pexp.data[0] };
    wasm_extern_vec_t imports = { 1, externs };
    wasm_trap_t* itrap = NULL;
    imp = zwasm_instance_new_ex(store, imz, &imports, &itrap, engine);
    if (!imp) {
        if (itrap) {
            fprintf(stderr, "[%s n=%u] importer refused WITH a trap (want NULL, no trap)\n", who, n);
            wasm_trap_delete(itrap);
            goto done;
        }
        outcome = OUTCOME_REFUSED;
        goto done;
    }
    if (itrap) wasm_trap_delete(itrap);
    wasm_instance_exports(imp, &iexp);
    if (iexp.size < 1 || !iexp.data[0] || wasm_extern_kind(iexp.data[0]) != WASM_EXTERN_FUNC) {
        fprintf(stderr, "[%s n=%u] importer is missing its `go` export\n", who, n);
        goto done;
    }
    wasm_val_t results[1] = { { WASM_I32, { 0 } } };
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t res = { 1, results };
    wasm_trap_t* ctrap = wasm_func_call(wasm_extern_as_func(iexp.data[0]), &no_args, &res);
    if (ctrap) { fprintf(stderr, "[%s n=%u] `go` trapped\n", who, n); wasm_trap_delete(ctrap); goto done; }
    if (results[0].kind != WASM_I32 || results[0].of.i32 != 7) {
        fprintf(stderr, "[%s n=%u] expected 7, got kind=%d value=%d\n", who, n, (int) results[0].kind, (int) results[0].of.i32);
        goto done;
    }
    outcome = OUTCOME_RAN_7;

done:
    if (iexp.data) wasm_extern_vec_delete(&iexp);
    if (imp) wasm_instance_delete(imp);
    if (imz) wasm_module_delete(imz);
    if (pexp.data) wasm_extern_vec_delete(&pexp);
    if (prov) wasm_instance_delete(prov);
    if (pm) wasm_module_delete(pm);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    free(pbytes);
    free(ibytes);
    return outcome;
}

static const uint8_t kEngines[] = { ZWASM_ENGINE_AUTO, ZWASM_ENGINE_JIT };

int main(void) {
    int fails = 0;

    /* 517 i32 parameters fit the arm64 thunk's overflow copy on every host:
     * both JIT-backed engines link and `go` returns 7. */
    for (size_t e = 0; e < sizeof(kEngines); e++) {
        if (link_at(kEngines[e], 517) != OUTCOME_RAN_7) {
            fprintf(stderr, "[%s] 517-param import did not link + return 7\n", engine_name(kEngines[e]));
            fails++;
        }
    }

    /* 518 is one past the arm64 thunk's imm12 overflow-copy cap. On arm64 the
     * importer is refused at instantiation (NULL, no trap); on x86_64 the
     * overflow copy is a disp32 with no cap, so it links and `go` returns 7. */
    for (size_t e = 0; e < sizeof(kEngines); e++) {
        Outcome got = link_at(kEngines[e], 518);
#if defined(__aarch64__)
        if (got != OUTCOME_REFUSED) {
            fprintf(stderr, "[%s] 518-param import was not refused on arm64\n", engine_name(kEngines[e]));
            fails++;
        }
#else
        if (got != OUTCOME_RAN_7) {
            fprintf(stderr, "[%s] 518-param import did not link + return 7 on this arch\n", engine_name(kEngines[e]));
            fails++;
        }
#endif
    }

    if (fails == 0) puts("cross_module_wide_signature: ok");
    return fails ? 1 : 0;
}
