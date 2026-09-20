/* zwasm-specific C extensions, subordinate to the standard wasm.h.
 *
 * STABILITY: zwasm is pre-1.0. These extension symbols and the wider
 * C ABI may change between releases until 1.0. The standard wasm.h
 * surface follows the upstream wasm-c-api interface.
 *
 * Instance-level sandboxing setters: per-instance budgets are set
 * post-instantiate and are mutable mid-workload (fuel, memory ceiling,
 * interrupt). wasm_instance_new compiles the module with the JIT and
 * instantiates the interpreter only when the JIT declines it, so each
 * setter routes to whichever engine ended up backing the instance —
 * see ZWASM_ENGINE_AUTO below. All functions are null-tolerant (a null
 * instance is a no-op).
 *
 * The WASI config family (zwasm_wasi_config_*, zwasm_store_set_wasi) is
 * declared in wasi.h; zwasm_instance_get_func is declared below.
 */
#ifndef ZWASM_H
#define ZWASM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "wasm.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ── Runtime version ─────────────────────────────────────────────────── */

/* Semantic version of the LINKED LIBRARY (e.g. "2.5.0"). Static storage,
 * never NULL; do not free.
 *
 * This is the semver ALONE, not the build identity. -Dwasm / -Dwasi /
 * -Dengine are compile-time and change what the library can do, yet two
 * builds of the same commit differing in all three return the same string:
 * "2.5.0" does NOT promise this library holds everything that version can
 * do. Per-axis identity accessors are deferred until a consumer needs one
 * (ADR-0221). */
WASM_API_EXTERN const char* zwasm_version(void);

/* ── Observability hooks ─────────────────────────────────────────────── */

/* Five engine events an embedder can listen to, registered one at a time on
 * the engine. Passing NULL for the callback clears that slot; `user_data` is
 * handed back unchanged and is never interpreted.
 *
 * Events, not durations: the core carries no clock and no allocator of its
 * own, so a hook reports that something happened, not how long it took. Time
 * it on your side if you need it.
 *
 * Instances are named by a uint64_t id, never by pointer: the id is monotonic
 * for the engine's life and never reused, whereas an address can be handed
 * out again after a delete. Id 0 means "no instance" — an event the engine
 * raised before one existed, or one belonging to a wasm_func_new function,
 * which is not part of any instance. Ids are not dense: an instantiation that
 * fails still consumes one.
 *
 * THREE RULES, and they are the whole contract:
 *
 *   1. Calling back into this engine, its stores, or its instances from
 *      inside a hook is UNDEFINED. The hook fires in the middle of the
 *      operation it reports. Record what you need and return.
 *   2. Register before you start using the engine, and do not change a slot
 *      while another thread could be running guest code. The engine reads a
 *      slot with a plain load and takes no lock (see "Threads" below: the
 *      engine is single-threaded anyway).
 *   3. A (pointer, length) string is borrowed for the duration of the call.
 *      Copy it if you keep it. It is NOT NUL-terminated.
 */

/* A module was offered to the engine (wasm_module_new / wasm_module_validate).
 *
 * `accepted` says whether the engine TOOK the bytes. False covers two things
 * the engine does not distinguish here: bytes that parse or validation
 * rejected, and a resource failure while validating them — retrying the same
 * bytes with memory available can accept them. Treat a false as "not taken",
 * not as proof the bytes are malformed.
 *
 * True is not a promise that a module exists either: an accepted
 * wasm_module_new can still return NULL if the allocation for the copy fails,
 * and wasm_module_validate never creates one.
 *
 * An empty byte vector (wasm_byte_vec_new_empty's { 0, NULL }) is an offer of
 * zero bytes and is reported, rejected. A NULL data pointer with a nonzero
 * size is a malformed call, not bytes: it is refused and raises nothing. */
typedef void (*zwasm_compile_hook_t)(void* user_data, size_t wasm_len, bool accepted);

/* An instantiation succeeded and was given `instance_id`. A failed one raises
 * nothing here; when it fails by trapping, the trap hook reports that. */
typedef void (*zwasm_instantiate_hook_t)(void* user_data, uint64_t instance_id);

/* The engine raised a trap. `trap_kind` is the same value zwasm_trap_kind
 * reports (the ZWASM_TRAP_* constants below) and `message` the same text
 * wasm_trap_message would carry. A trap the EMBEDDER mints with wasm_trap_new
 * is its own, not the engine's, and is not reported. */
typedef void (*zwasm_trap_hook_t)(void* user_data, uint64_t instance_id,
                                  int32_t trap_kind, const char* message,
                                  size_t message_len);

/* A fuel budget ran out. Raised IN ADDITION to a trap event of kind
 * ZWASM_TRAP_OUT_OF_FUEL for the same instance, so a host that meters fuel
 * need not switch on the kind. */
typedef void (*zwasm_fuel_exhausted_hook_t)(void* user_data, uint64_t instance_id);

/* A linear memory grew, on either engine, from a guest memory.grow or from
 * wasm_memory_grow. Page counts are in that memory's page-size units (64 KiB
 * by default). A REFUSED grow is the spec's recoverable -1, not an event. */
typedef void (*zwasm_memory_growth_hook_t)(void* user_data, uint64_t instance_id,
                                           uint32_t memory_index,
                                           uint64_t old_pages, uint64_t new_pages);

WASM_API_EXTERN void zwasm_engine_set_compile_hook(
    wasm_engine_t*, zwasm_compile_hook_t, void* user_data);
WASM_API_EXTERN void zwasm_engine_set_instantiate_hook(
    wasm_engine_t*, zwasm_instantiate_hook_t, void* user_data);
WASM_API_EXTERN void zwasm_engine_set_trap_hook(
    wasm_engine_t*, zwasm_trap_hook_t, void* user_data);
WASM_API_EXTERN void zwasm_engine_set_fuel_exhausted_hook(
    wasm_engine_t*, zwasm_fuel_exhausted_hook_t, void* user_data);
WASM_API_EXTERN void zwasm_engine_set_memory_growth_hook(
    wasm_engine_t*, zwasm_memory_growth_hook_t, void* user_data);

/* ── Fuel (deterministic budget) ─────────────────────────────────────── */

/* Fuel units are engine-specific: interpreter = instructions executed;
 * JIT = poll-site crossings (function entry + loop back-edges). A budget
 * armed on an instance whose engine you did not force therefore has no
 * portable unit — pin the engine with zwasm_instance_new_ex when the
 * exact count matters. */

/* Arm (or re-arm) the fuel budget. Exhaustion traps with kind
 * ZWASM_TRAP_OUT_OF_FUEL ("all fuel consumed"). */
WASM_API_EXTERN void zwasm_instance_set_fuel(wasm_instance_t*, uint64_t fuel);

/* Remove the budget (unmetered). */
WASM_API_EXTERN void zwasm_instance_disable_fuel(wasm_instance_t*);

/* Read the remaining fuel into *out; returns false when unmetered. */
WASM_API_EXTERN bool zwasm_instance_fuel_remaining(const wasm_instance_t*, uint64_t* out);

/* ── Memory cap (host ceiling below the declared/spec max) ───────────── */

/* memory.grow past `max_pages` (pages of memory 0's page size, 64 KiB by
 * default) returns the spec grow-failure (-1) — not a trap. */
WASM_API_EXTERN void zwasm_instance_set_memory_pages_limit(wasm_instance_t*, uint64_t max_pages);
WASM_API_EXTERN void zwasm_instance_clear_memory_pages_limit(wasm_instance_t*);

/* ── Threads ─────────────────────────────────────────────────────────── */

/* THE ENGINE IS SINGLE-THREADED. Not merely one thread per Store: one thread
 * per process. Stores share process-global state — among it the table the
 * exception unwinder consults to find which instance owns a frame — so a
 * second thread that deletes a Store can free memory a call on the first is
 * still reading, even though the two share no handle. Making separate Stores
 * usable on separate threads is a later design, not an undocumented
 * allowance. `zwasm_instance_interrupt` below is the one call safe from any
 * thread, and says so. */

/* ── Cooperative interruption (cancel / host-driven timeout) ─────────── */

/* Callable from any thread; the running guest traps with kind
 * ZWASM_TRAP_INTERRUPTED at its next poll (function entry / loop
 * back-edge). Idempotent; clear before re-invoking. */
WASM_API_EXTERN void zwasm_instance_interrupt(wasm_instance_t*);
WASM_API_EXTERN void zwasm_instance_clear_interrupt(wasm_instance_t*);

/* ── Trap kind introspection ─────────────────────────────────────────── */

/* Machine-readable trap kind beside wasm.h's message-only surface; -1 on
 * NULL. Values mirror the `TrapKind` enum (src/api/trap_surface.zig), which is
 * append-only stable; a C host can switch on these without string-matching. */

/* The embedder's binding is wrong: an argument or result count that is not the
 * signature's, or a host callback's own trap. A shape the engine cannot call
 * is ZWASM_TRAP_UNSUPPORTED.
 *
 * A binding the runtime REFUSES to make earns it too (#436, #446):
 * zwasm_instance_new[_ex] returns NULL with this trap, on every engine, when
 * an import's extern comes from a DIFFERENT store — an instance's export, or
 * any entity created by wasm_func_new / wasm_global_new / wasm_memory_new /
 * wasm_table_new on another store. Their backing belongs to the store that
 * made them and dies with it, and nothing ties two stores' lifetimes.
 *
 * The module is refused on the same ground (#447): instantiating a module
 * created on another store returns NULL with this trap, because a JIT-backed
 * instance borrows the module's bytes. Move the module with
 * wasm_module_share + wasm_module_obtain, which copies them into the
 * obtaining store. Other instantiation failures still return NULL with no
 * trap. */
#define ZWASM_TRAP_BINDING_ERROR 0
#define ZWASM_TRAP_UNREACHABLE 1
#define ZWASM_TRAP_DIV_BY_ZERO 2
#define ZWASM_TRAP_INT_OVERFLOW 3
#define ZWASM_TRAP_INVALID_CONVERSION 4
#define ZWASM_TRAP_OOB_MEMORY 5
#define ZWASM_TRAP_OOB_TABLE 6
#define ZWASM_TRAP_UNINITIALIZED_ELEM 7
#define ZWASM_TRAP_INDIRECT_CALL_MISMATCH 8
#define ZWASM_TRAP_STACK_OVERFLOW 9
#define ZWASM_TRAP_OUT_OF_MEMORY 10
#define ZWASM_TRAP_NULL_REFERENCE 11
#define ZWASM_TRAP_CAST_FAILURE 12
#define ZWASM_TRAP_UNCAUGHT_EXCEPTION 13
#define ZWASM_TRAP_UNALIGNED_ATOMIC 14
#define ZWASM_TRAP_EXPECTED_SHARED_MEMORY 15
#define ZWASM_TRAP_INTERRUPTED 16
#define ZWASM_TRAP_OUT_OF_FUEL 17
/* Host-originated, not a guest fault: the guest called WASI proc_exit. Read the
 * status itself with zwasm_store_wasi_exit_code(). */
#define ZWASM_TRAP_WASI_EXIT 18
/* The JIT judged the module invalid (a check the front-end validator does not
 * make yet): zwasm_instance_new_ex returns NULL with this trap on AUTO and JIT,
 * and AUTO does not retry on the interpreter. The message names the verdict. */
#define ZWASM_TRAP_INVALID_MODULE 19
/* The engine that owns this instance has no implementation for this call's
 * shape. Not a guest trap and not a binding error; AUTO does not retry on the
 * interpreter at call time. The message names the shape. */
#define ZWASM_TRAP_UNSUPPORTED 20
WASM_API_EXTERN int32_t zwasm_trap_kind(const wasm_trap_t*);

/* The message beside the kind: wasm.h's wasm_trap_message fills a
 * wasm_message_t that carries its terminating NUL, with size counting it, so
 * the vector reads as a C string and the text is size - 1 bytes. Symmetrically
 * wasm_trap_new takes a host message with or without the NUL inside size. */

/* ── Instance helpers ────────────────────────────────────────────────── */

/* Resolve an instance + defined-function index into a fresh, owned func
 * handle — a convenience over wasm_instance_exports + wasm_extern_vec_t
 * indexing. Returns NULL on a null instance or an out-of-range index. The
 * caller owns the result and must release it with wasm_func_delete. */
WASM_API_EXTERN wasm_func_t* zwasm_instance_get_func(wasm_instance_t*, uint32_t idx);

/* ── Engine selection ────────────────────────────────────────────────── */

/* Per-instance engine kind for zwasm_instance_new_ex. AUTO — what stock
 * wasm_instance_new passes — compiles the module with the JIT and instantiates
 * the interpreter only for a module the JIT DECLINES (an import it cannot
 * satisfy, or a body it cannot compile). One decline has no fallback: a module
 * importing a function from another instance THIS Store backs with the JIT
 * cannot run on the interpreter at all, so AUTO returns NULL with no trap for
 * it, as JIT does. A module the JIT judges INVALID is not retried: NULL, with
 * a ZWASM_TRAP_INVALID_MODULE trap through trap_out.
 * JIT forces the native JIT: a declined module fails instantiation, returning
 * NULL with no trap — no silent downgrade; an invalid one returns NULL with
 * the same trap AUTO gives. INTERP forces the interpreter, which unlike the
 * other two rejects a module importing wasi_snapshot_preview1 when no WASI
 * host is configured on the store. */
#define ZWASM_ENGINE_AUTO 0
#define ZWASM_ENGINE_JIT 1
#define ZWASM_ENGINE_INTERP 2

/* wasm_instance_new with a trailing per-instance engine selector (the stock
 * wasm_instance_new is AUTO). Same ownership/trap contract as wasm_instance_new:
 * NULL on null input / instantiation failure / OOM; a start-function trap, a
 * ZWASM_TRAP_INVALID_MODULE verdict or a ZWASM_TRAP_BINDING_ERROR cross-store
 * import is written through trap_out (when non-NULL) with a NULL return. The
 * cross-store refusal is decided before any engine-specific capability check,
 * so all three engine kinds give the same reason for it. */
WASM_API_EXTERN wasm_instance_t* zwasm_instance_new_ex(
    wasm_store_t*, const wasm_module_t*, const wasm_extern_vec_t*,
    wasm_trap_t**, uint8_t engine_kind);

/* The RESOLVED engine kind into *out: ZWASM_ENGINE_JIT or ZWASM_ENGINE_INTERP,
 * never AUTO — AUTO is what you asked for, this is what you got, and an
 * instance AUTO handed to the interpreter because the JIT declined its module
 * says INTERP here. Returns false (out untouched) on a null instance.
 * ADR-0200 D3. */
WASM_API_EXTERN bool zwasm_instance_engine(const wasm_instance_t*, int32_t* out);

/* ── Module introspection ────────────────────────────────────────────── */

/* wasm_module_imports with a verdict (the _ex suffix as in
 * zwasm_instance_new_ex: wasm.h fixes the stock signature, which returns void).
 * true — *out holds one wasm_importtype_t per import, in section order, with
 * no kind left out: a tag import's externtype has kind WASM_EXTERN_TAG and
 * wasm_externtype_as_tagtype gives its parameter signature. false — *out is
 * {0, NULL} and nothing has leaked; a NULL module or out reports false too.
 * There is no partial answer, because a short vector reads exactly like a
 * module with fewer imports. Release a true result with
 * wasm_importtype_vec_delete. */
WASM_API_EXTERN bool zwasm_module_imports_ex(
    const wasm_module_t*, wasm_importtype_vec_t* out);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* ZWASM_H */
