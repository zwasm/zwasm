/* zwasm v2 — C-API conformance: an embedder hears compile, instantiate, trap,
 * fuel exhaustion and memory growth, and hears nothing it did not ask for
 * (#216).
 *
 * One guest carries every event site:
 *
 *   (module
 *     (memory (export "mem") 1 10)
 *     (func (export "grow") (param i32) (result i32) (memory.grow (local.get 0)))
 *     (func (export "spin") (loop (br 0)))
 *     (func (export "boom") (unreachable))
 *     (func (export "size") (result i32) (memory.size)))
 *
 * `sequence()` drives it once, and is called TWICE per engine: once with the
 * five hooks registered and once with none. It writes every observable result
 * — the grow return values, the page counts, the trap kinds — into a
 * `results_t`, and the two runs' structs must match field for field. That is
 * the load-bearing half of the claim: an unregistered engine is the engine
 * that was always there, and a registered one changes nothing but what it
 * tells you. One function, called twice, so the two sequences cannot drift.
 *
 * Per registered run the counts are exact:
 *
 *   compile     4 — module_new(good) + module_new(bad) + validate(good) +
 *                   validate(bad); BOTH outcomes of BOTH calls are events.
 *   instantiate 1 — one success. The id is the engine's first, so 1.
 *   trap        2 — the guest's `unreachable` (kind 1) and the exhausted fuel
 *                   budget (kind 17), each naming the instantiated id and
 *                   carrying a non-empty message. The message is borrowed and
 *                   NOT NUL-terminated (zwasm.h rule 3), so only its length is
 *                   recorded here.
 *   fuel        1 — paired with the kind-17 trap event, not instead of it.
 *   growth      2 — the guest's `memory.grow` (1→2) and the host's
 *                   `wasm_memory_grow` (2→3). The REFUSED grow in between,
 *                   capped by zwasm_instance_set_memory_pages_limit, is the
 *                   spec's -1 and raises nothing: that is why growth is 2 and
 *                   not 3.
 *
 * `clear_check()` then registers all five, provokes each event once, clears
 * that slot with NULL and provokes it again: every counter must stand still.
 *
 * Run on ZWASM_ENGINE_INTERP and ZWASM_ENGINE_JIT, so both engines' raising
 * sites are exercised (the interpreter's `runtime.growMemory` and the JIT's
 * `jitMemoryGrow` are separate code). Exits 0 on success.
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* (module
 *   (memory (export "mem") 1 10)
 *   (func (export "grow") (param i32) (result i32) (memory.grow (local.get 0)))
 *   (func (export "spin") (loop (br 0)))
 *   (func (export "boom") (unreachable))
 *   (func (export "size") (result i32) (memory.size))) */
static const uint8_t kGuest[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    /* type: 0 = ()->(), 1 = (i32)->(i32), 2 = ()->(i32) */
    0x01, 0x0d, 0x03,
    0x60, 0x00, 0x00,
    0x60, 0x01, 0x7f, 0x01, 0x7f,
    0x60, 0x00, 0x01, 0x7f,
    /* func: grow=1, spin=0, boom=0, size=2 */
    0x03, 0x05, 0x04, 0x01, 0x00, 0x00, 0x02,
    /* memory 0: min 1, max 10 */
    0x05, 0x04, 0x01, 0x01, 0x01, 0x0a,
    /* export "grow"/0 "spin"/1 "boom"/2 "size"/3 "mem"/mem0 */
    0x07, 0x23, 0x05,
    0x04, 0x67, 0x72, 0x6f, 0x77, 0x00, 0x00,
    0x04, 0x73, 0x70, 0x69, 0x6e, 0x00, 0x01,
    0x04, 0x62, 0x6f, 0x6f, 0x6d, 0x00, 0x02,
    0x04, 0x73, 0x69, 0x7a, 0x65, 0x00, 0x03,
    0x03, 0x6d, 0x65, 0x6d, 0x02, 0x00,
    /* code */
    0x0a, 0x19, 0x04,
    0x06, 0x00, 0x20, 0x00, 0x40, 0x00, 0x0b,             /* grow: local.get 0; memory.grow 0 */
    0x07, 0x00, 0x03, 0x40, 0x0c, 0x00, 0x0b, 0x0b,       /* spin: loop; br 0; end */
    0x03, 0x00, 0x00, 0x0b,                               /* boom: unreachable */
    0x04, 0x00, 0x3f, 0x00, 0x0b,                         /* size: memory.size 0 */
};

/* A version the parser does not accept — the "rejected" half of the compile
 * event, for both wasm_module_new and wasm_module_validate. */
static const uint8_t kBadGuest[] = {
    0x00, 0x61, 0x73, 0x6d, 0x02, 0x00, 0x00, 0x00,
};

/* Export indices, in declaration order. */
#define EX_GROW 0
#define EX_SPIN 1
#define EX_BOOM 2
#define EX_SIZE 3
#define EX_MEM 4

#define MAX_EV 8

/* What the five hooks recorded. Hooks may not call back into the engine
 * (zwasm.h rule 1), so every callback here does nothing but append. */
typedef struct {
    int compile_n;
    int compile_accepted_n;
    size_t compile_len[MAX_EV];

    int instantiate_n;
    uint64_t instance_id;

    int trap_n;
    uint64_t trap_inst[MAX_EV];
    int32_t trap_kind[MAX_EV];
    size_t trap_msg_len[MAX_EV];
    int trap_msg_null_ptr;

    int fuel_n;
    uint64_t fuel_inst[MAX_EV];

    int growth_n;
    uint64_t growth_inst[MAX_EV];
    uint32_t growth_index[MAX_EV];
    uint64_t growth_old[MAX_EV];
    uint64_t growth_new[MAX_EV];
} obs_t;

/* Everything the sequence observes through the ordinary API — the half that
 * must be byte-identical with and without hooks. */
typedef struct {
    int32_t size_initial;
    int32_t guest_grow_ret;
    int32_t size_after_guest_grow;
    int32_t capped_grow_ret;
    int32_t size_after_capped_grow;
    int32_t host_grow_ok;
    int32_t host_pages_after;
    int32_t size_after_host_grow;
    int32_t boom_kind;
    int32_t spin_kind;
} results_t;

static void on_compile(void* ud, size_t wasm_len, bool accepted) {
    obs_t* o = (obs_t*) ud;
    if (o->compile_n < MAX_EV) o->compile_len[o->compile_n] = wasm_len;
    o->compile_n++;
    if (accepted) o->compile_accepted_n++;
}

static void on_instantiate(void* ud, uint64_t instance_id) {
    obs_t* o = (obs_t*) ud;
    o->instantiate_n++;
    o->instance_id = instance_id;
}

static void on_trap(void* ud, uint64_t instance_id, int32_t trap_kind,
                    const char* message, size_t message_len) {
    obs_t* o = (obs_t*) ud;
    if (!message) o->trap_msg_null_ptr++;
    if (o->trap_n < MAX_EV) {
        o->trap_inst[o->trap_n] = instance_id;
        o->trap_kind[o->trap_n] = trap_kind;
        o->trap_msg_len[o->trap_n] = message_len;
    }
    o->trap_n++;
}

static void on_fuel(void* ud, uint64_t instance_id) {
    obs_t* o = (obs_t*) ud;
    if (o->fuel_n < MAX_EV) o->fuel_inst[o->fuel_n] = instance_id;
    o->fuel_n++;
}

static void on_growth(void* ud, uint64_t instance_id, uint32_t memory_index,
                      uint64_t old_pages, uint64_t new_pages) {
    obs_t* o = (obs_t*) ud;
    if (o->growth_n < MAX_EV) {
        o->growth_inst[o->growth_n] = instance_id;
        o->growth_index[o->growth_n] = memory_index;
        o->growth_old[o->growth_n] = old_pages;
        o->growth_new[o->growth_n] = new_pages;
    }
    o->growth_n++;
}

static void register_all(wasm_engine_t* eng, obs_t* o) {
    zwasm_engine_set_compile_hook(eng, on_compile, o);
    zwasm_engine_set_instantiate_hook(eng, on_instantiate, o);
    zwasm_engine_set_trap_hook(eng, on_trap, o);
    zwasm_engine_set_fuel_exhausted_hook(eng, on_fuel, o);
    zwasm_engine_set_memory_growth_hook(eng, on_growth, o);
}

static const char* engine_name(uint8_t kind) {
    switch (kind) {
    case ZWASM_ENGINE_AUTO: return "auto";
    case ZWASM_ENGINE_JIT: return "jit";
    case ZWASM_ENGINE_INTERP: return "interp";
    default: return "?";
    }
}

/* Calls export `idx` with `argc` i32 arguments and `nres` i32 results.
 * Returns the trap kind, or -1 when the call did not trap; a result is
 * written through `out`. */
static int32_t call_export(wasm_extern_vec_t* ex, size_t idx, int argc, int32_t arg,
                           int nres, int32_t* out) {
    wasm_val_t args[1];
    wasm_val_t res[1];
    wasm_val_vec_t av = { (size_t) argc, argc ? args : NULL };
    wasm_val_vec_t rv = { (size_t) nres, nres ? res : NULL };
    wasm_trap_t* trap;
    args[0].kind = WASM_I32;
    args[0].of.i32 = arg;
    res[0].kind = WASM_I32;
    res[0].of.i32 = 0;
    trap = wasm_func_call(wasm_extern_as_func(ex->data[idx]), &av, &rv);
    if (trap) {
        int32_t kind = zwasm_trap_kind(trap);
        wasm_trap_delete(trap);
        return kind;
    }
    if (nres && out) *out = res[0].of.i32;
    return -1;
}

/* The one sequence, run with hooks (`o` non-NULL) and without (`o` NULL).
 * Fills `r` with what the ordinary API reported. Returns 0 on success. */
static int sequence(uint8_t engine, obs_t* o, results_t* r, const char* label) {
    int rc = 1;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_memory_t* mem = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    wasm_byte_vec_t good = { sizeof(kGuest), (wasm_byte_t*) kGuest };
    wasm_byte_vec_t bad = { sizeof(kBadGuest), (wasm_byte_t*) kBadGuest };
    wasm_module_t* refused = NULL;

    memset(r, 0, sizeof(*r));
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }
    if (o) register_all(eng, o);

    /* 1. Four compile events: accept, reject, accept, reject. */
    module = wasm_module_new(store, &good);
    if (!module) { fprintf(stderr, "%s: wasm_module_new failed\n", label); goto cleanup; }
    refused = wasm_module_new(store, &bad);
    if (refused) { fprintf(stderr, "%s: the bad module was accepted\n", label); wasm_module_delete(refused); goto cleanup; }
    if (!wasm_module_validate(store, &good)) { fprintf(stderr, "%s: validate(good) said no\n", label); goto cleanup; }
    if (wasm_module_validate(store, &bad)) { fprintf(stderr, "%s: validate(bad) said yes\n", label); goto cleanup; }

    /* 2. One instantiation. */
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) { wasm_trap_delete(itrap); itrap = NULL; }
    if (!instance) { fprintf(stderr, "%s: instantiate failed\n", label); goto cleanup; }
    wasm_instance_exports(instance, &exports);
    if (exports.size < 5) { fprintf(stderr, "%s: missing exports\n", label); goto cleanup; }

    /* 3. A guest memory.grow: 1 -> 2 pages, one growth event. */
    call_export(&exports, EX_SIZE, 0, 0, 1, &r->size_initial);
    call_export(&exports, EX_GROW, 1, 1, 1, &r->guest_grow_ret);
    call_export(&exports, EX_SIZE, 0, 0, 1, &r->size_after_guest_grow);

    /* 4. A REFUSED grow: capped at the current 2 pages, memory.grow answers
     *    the spec's -1 and raises NO event. */
    zwasm_instance_set_memory_pages_limit(instance, 2);
    call_export(&exports, EX_GROW, 1, 1, 1, &r->capped_grow_ret);
    call_export(&exports, EX_SIZE, 0, 0, 1, &r->size_after_capped_grow);
    zwasm_instance_clear_memory_pages_limit(instance);

    /* 5. The host's own grow: 2 -> 3 pages, the second growth event. */
    mem = wasm_extern_as_memory(exports.data[EX_MEM]);
    if (!mem) { fprintf(stderr, "%s: export \"mem\" is not a memory\n", label); goto cleanup; }
    r->host_grow_ok = wasm_memory_grow(mem, 1) ? 1 : 0;
    r->host_pages_after = (int32_t) wasm_memory_size(mem);
    call_export(&exports, EX_SIZE, 0, 0, 1, &r->size_after_host_grow);

    /* 6. A guest trap. */
    r->boom_kind = call_export(&exports, EX_BOOM, 0, 0, 0, NULL);

    /* 7. An exhausted fuel budget: a trap event AND a fuel event. */
    zwasm_instance_set_fuel(instance, 1000);
    r->spin_kind = call_export(&exports, EX_SPIN, 0, 0, 0, NULL);
    zwasm_instance_disable_fuel(instance);

    rc = 0;

cleanup:
    wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

static int expect_int(const char* label, const char* what, long long got, long long want) {
    if (got == want) return 0;
    fprintf(stderr, "%s: %s = %lld, want %lld\n", label, what, got, want);
    return 1;
}

static int same_field(const char* label, const char* what, long long hooked, long long bare) {
    if (hooked == bare) return 0;
    fprintf(stderr, "%s: %s differs — hooked=%lld, unhooked=%lld\n", label, what, hooked, bare);
    return 1;
}

/* Both halves of one engine: the registered run's counts and payloads, and
 * the unregistered run's identical results. */
static int run_engine(uint8_t engine) {
    const char* name = engine_name(engine);
    char label[64];
    obs_t o;
    results_t hooked, bare;
    int bad = 0;
    int i;

    memset(&o, 0, sizeof(o));
    snprintf(label, sizeof(label), "hooks[%s/registered]", name);
    if (sequence(engine, &o, &hooked, label) != 0) return 1;

    /* compile: four offers, two accepted; the first carries the guest's size. */
    bad |= expect_int(label, "compile events", o.compile_n, 4);
    bad |= expect_int(label, "compile accepted", o.compile_accepted_n, 2);
    if (o.compile_n >= 4) {
        bad |= expect_int(label, "compile[0] wasm_len", (long long) o.compile_len[0], (long long) sizeof(kGuest));
        bad |= expect_int(label, "compile[1] wasm_len", (long long) o.compile_len[1], (long long) sizeof(kBadGuest));
    }

    /* instantiate: one success, and the engine's first id is 1. */
    bad |= expect_int(label, "instantiate events", o.instantiate_n, 1);
    bad |= expect_int(label, "first instance id", (long long) o.instance_id, 1);

    /* trap: the guest's unreachable, then the exhausted budget. */
    bad |= expect_int(label, "trap events", o.trap_n, 2);
    bad |= expect_int(label, "trap message NULL pointers", o.trap_msg_null_ptr, 0);
    if (o.trap_n >= 2) {
        bad |= expect_int(label, "trap[0] kind", o.trap_kind[0], ZWASM_TRAP_UNREACHABLE);
        bad |= expect_int(label, "trap[1] kind", o.trap_kind[1], ZWASM_TRAP_OUT_OF_FUEL);
        for (i = 0; i < 2; i++) {
            char what[48];
            snprintf(what, sizeof(what), "trap[%d] instance id", i);
            bad |= expect_int(label, what, (long long) o.trap_inst[i], (long long) o.instance_id);
            if (o.trap_msg_len[i] == 0) {
                fprintf(stderr, "%s: trap[%d] carried an empty message\n", label, i);
                bad = 1;
            }
        }
    }

    /* fuel: raised IN ADDITION to the kind-17 trap, for the same instance. */
    bad |= expect_int(label, "fuel events", o.fuel_n, 1);
    if (o.fuel_n >= 1) bad |= expect_int(label, "fuel instance id", (long long) o.fuel_inst[0], (long long) o.instance_id);

    /* growth: the guest's 1->2 and the host's 2->3. The capped grow in
     * between is a refusal, not an event. */
    bad |= expect_int(label, "growth events", o.growth_n, 2);
    if (o.growth_n >= 2) {
        bad |= expect_int(label, "growth[0] memory_index", o.growth_index[0], 0);
        bad |= expect_int(label, "growth[0] old_pages", (long long) o.growth_old[0], 1);
        bad |= expect_int(label, "growth[0] new_pages", (long long) o.growth_new[0], 2);
        bad |= expect_int(label, "growth[0] instance id", (long long) o.growth_inst[0], (long long) o.instance_id);
        bad |= expect_int(label, "growth[1] memory_index", o.growth_index[1], 0);
        bad |= expect_int(label, "growth[1] old_pages", (long long) o.growth_old[1], 2);
        bad |= expect_int(label, "growth[1] new_pages", (long long) o.growth_new[1], 3);
        bad |= expect_int(label, "growth[1] instance id", (long long) o.growth_inst[1], (long long) o.instance_id);
    }

    /* The results the ordinary API reported, asserted once against the spec's
     * own answers; the unregistered run then has to match them exactly. */
    bad |= expect_int(label, "initial memory.size", hooked.size_initial, 1);
    bad |= expect_int(label, "guest memory.grow return", hooked.guest_grow_ret, 1);
    bad |= expect_int(label, "memory.size after grow", hooked.size_after_guest_grow, 2);
    bad |= expect_int(label, "capped memory.grow return", hooked.capped_grow_ret, -1);
    bad |= expect_int(label, "memory.size after the refusal", hooked.size_after_capped_grow, 2);
    bad |= expect_int(label, "wasm_memory_grow", hooked.host_grow_ok, 1);
    bad |= expect_int(label, "wasm_memory_size after", hooked.host_pages_after, 3);
    bad |= expect_int(label, "memory.size after the host grow", hooked.size_after_host_grow, 3);
    bad |= expect_int(label, "boom trap kind", hooked.boom_kind, ZWASM_TRAP_UNREACHABLE);
    bad |= expect_int(label, "spin trap kind", hooked.spin_kind, ZWASM_TRAP_OUT_OF_FUEL);
    if (bad) return 1;

    /* The unregistered path: the same sequence on an engine with no slots
     * filled, and the same observable answers. */
    snprintf(label, sizeof(label), "hooks[%s/unregistered]", name);
    if (sequence(engine, NULL, &bare, label) != 0) return 1;
    bad |= same_field(label, "initial memory.size", hooked.size_initial, bare.size_initial);
    bad |= same_field(label, "guest memory.grow return", hooked.guest_grow_ret, bare.guest_grow_ret);
    bad |= same_field(label, "memory.size after grow", hooked.size_after_guest_grow, bare.size_after_guest_grow);
    bad |= same_field(label, "capped memory.grow return", hooked.capped_grow_ret, bare.capped_grow_ret);
    bad |= same_field(label, "memory.size after the refusal", hooked.size_after_capped_grow, bare.size_after_capped_grow);
    bad |= same_field(label, "wasm_memory_grow", hooked.host_grow_ok, bare.host_grow_ok);
    bad |= same_field(label, "wasm_memory_size after", hooked.host_pages_after, bare.host_pages_after);
    bad |= same_field(label, "memory.size after the host grow", hooked.size_after_host_grow, bare.size_after_host_grow);
    bad |= same_field(label, "boom trap kind", hooked.boom_kind, bare.boom_kind);
    bad |= same_field(label, "spin trap kind", hooked.spin_kind, bare.spin_kind);
    if (bad) return 1;

    printf("hooks[%s]: compile=%d instantiate=%d trap=%d fuel=%d growth=%d; "
           "the unregistered run matched field for field\n",
           name, o.compile_n, o.instantiate_n, o.trap_n, o.fuel_n, o.growth_n);
    return 0;
}

/* Each slot, cleared with NULL, goes quiet — and only that slot. Every event
 * is provoked once before the clear and once after; the counter must not
 * move the second time. */
static int clear_check(uint8_t engine) {
    const char* name = engine_name(engine);
    char label[64];
    int rc = 1;
    int bad = 0;
    obs_t o;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    wasm_byte_vec_t good = { sizeof(kGuest), (wasm_byte_t*) kGuest };
    int compile_before, trap_before, fuel_before, growth_before, instantiate_before;
    wasm_instance_t* second = NULL;

    memset(&o, 0, sizeof(o));
    snprintf(label, sizeof(label), "hooks[%s/cleared]", name);
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }
    register_all(eng, &o);

    /* compile */
    module = wasm_module_new(store, &good);
    if (!module) { fprintf(stderr, "%s: wasm_module_new failed\n", label); goto cleanup; }
    compile_before = o.compile_n;
    zwasm_engine_set_compile_hook(eng, NULL, NULL);
    if (!wasm_module_validate(store, &good)) { fprintf(stderr, "%s: validate said no\n", label); goto cleanup; }
    bad |= expect_int(label, "compile events after clearing", o.compile_n, compile_before);

    /* instantiate */
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) { wasm_trap_delete(itrap); itrap = NULL; }
    if (!instance) { fprintf(stderr, "%s: instantiate failed\n", label); goto cleanup; }
    instantiate_before = o.instantiate_n;
    zwasm_engine_set_instantiate_hook(eng, NULL, NULL);
    second = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) { wasm_trap_delete(itrap); itrap = NULL; }
    if (!second) { fprintf(stderr, "%s: second instantiate failed\n", label); goto cleanup; }
    wasm_instance_delete(second);
    second = NULL;
    bad |= expect_int(label, "instantiate events after clearing", o.instantiate_n, instantiate_before);

    wasm_instance_exports(instance, &exports);
    if (exports.size < 5) { fprintf(stderr, "%s: missing exports\n", label); goto cleanup; }

    /* memory growth */
    call_export(&exports, EX_GROW, 1, 1, 1, NULL);
    growth_before = o.growth_n;
    if (growth_before == 0) { fprintf(stderr, "%s: the first grow raised nothing\n", label); goto cleanup; }
    zwasm_engine_set_memory_growth_hook(eng, NULL, NULL);
    call_export(&exports, EX_GROW, 1, 1, 1, NULL);
    bad |= expect_int(label, "growth events after clearing", o.growth_n, growth_before);

    /* trap */
    call_export(&exports, EX_BOOM, 0, 0, 0, NULL);
    trap_before = o.trap_n;
    if (trap_before == 0) { fprintf(stderr, "%s: the first trap raised nothing\n", label); goto cleanup; }
    zwasm_engine_set_trap_hook(eng, NULL, NULL);
    call_export(&exports, EX_BOOM, 0, 0, 0, NULL);
    bad |= expect_int(label, "trap events after clearing", o.trap_n, trap_before);

    /* fuel exhaustion — still raised with the trap slot already empty, which
     * is the pairing read the other way: the two slots are independent. */
    zwasm_instance_set_fuel(instance, 1000);
    call_export(&exports, EX_SPIN, 0, 0, 0, NULL);
    fuel_before = o.fuel_n;
    if (fuel_before == 0) { fprintf(stderr, "%s: the first exhaustion raised nothing\n", label); goto cleanup; }
    bad |= expect_int(label, "trap events while the trap slot is empty", o.trap_n, trap_before);
    zwasm_engine_set_fuel_exhausted_hook(eng, NULL, NULL);
    zwasm_instance_set_fuel(instance, 1000);
    call_export(&exports, EX_SPIN, 0, 0, 0, NULL);
    bad |= expect_int(label, "fuel events after clearing", o.fuel_n, fuel_before);
    zwasm_instance_disable_fuel(instance);

    if (bad) goto cleanup;
    printf("hooks[%s]: each slot cleared with NULL went quiet, and only itself\n", name);
    rc = 0;

cleanup:
    wasm_extern_vec_delete(&exports);
    if (second) wasm_instance_delete(second);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

int main(void) {
    const uint8_t engines[] = { ZWASM_ENGINE_INTERP, ZWASM_ENGINE_JIT };
    size_t i;
    for (i = 0; i < sizeof(engines); i++) {
        if (run_engine(engines[i]) != 0) return 1;
        if (clear_check(engines[i]) != 0) return 1;
    }
    return 0;
}
