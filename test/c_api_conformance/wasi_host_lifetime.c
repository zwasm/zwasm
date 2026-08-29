/* zwasm v2 — a WASI host outlives the instances that captured it.
 *
 * `zwasm_store_set_wasi` takes ownership of a config. Calling it a second
 * time therefore has to decide what happens to the first one, and an
 * instance created in between is the case that decides it: instantiation
 * bakes the host's address into the instance (the interpreter stores it as
 * each `wasi_snapshot_preview1` import's context; the JIT stores it on the
 * runtime the compiled body reads). Releasing the config out from under
 * that instance leaves the guest calling into released memory, and closes
 * the preopened directories the instance is still entitled to use.
 *
 * Nothing below reads released memory. Two independent checks:
 *
 *   fd (POSIX only) — a released host closes its preopen directory fd, and
 *     a closed descriptor is the lowest one the next `open` hands out. So
 *     an `open` before the swap and an `open` after it must return the same
 *     descriptor. Deterministic: no allocator behaviour involved. Windows
 *     dir handles are not CRT descriptors, so this check is POSIX-only.
 *
 *   probe — right after the swap, the case creates configs of its own, one
 *     of which lands on the block a released host vacated. Then it runs a
 *     guest whose only act is `proc_exit(42)`: a single store into
 *     `exit_code`. A config that we own, and that no guest ever ran
 *     against, must not report an exit status.
 *
 * The probe check depends on the allocator handing the released block back
 * to one of the next same-sized requests. It cannot report a false failure
 * — the probes are reachable only through the dangling pointer — but an
 * allocator that quarantines the block would leave it empty, so it prints
 * `probes recycled` for every case rather than passing quietly. Read that
 * number: where it is 0 on POSIX the fd check still holds, and where it is
 * 0 on Windows this case proved nothing. The first three-OS run recycled on
 * the first request on Linux and macOS and on the fourth on Windows, which
 * is what 64 leaves room for.
 *
 * Both engines are covered because they capture the host separately, and
 * both `set_wasi(store, cfg2)` and `set_wasi(store, NULL)` are covered
 * because both release the previous host.
 *
 * Run by `test-c-api-conformance`.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

#ifndef _WIN32
#include <fcntl.h>
#include <unistd.h>
#endif

#include <wasm.h>
#include <wasi.h>
#include <zwasm.h>

/* (module
 *   (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
 *   (func (export "_start") (call $exit (i32.const 42)))) */
static const uint8_t kExitWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00,
    0x02, 0x24, 0x01,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31,
    0x09, 0x70, 0x72, 0x6f, 0x63, 0x5f, 0x65, 0x78, 0x69, 0x74,
    0x00, 0x00,
    0x03, 0x02, 0x01, 0x01,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x01,
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x2a, 0x10, 0x00, 0x0b,
};

/* Windows recycled the released block on the fourth request where Linux and
 * macOS recycled it on the first, and left the interpreter's cases empty at
 * four. Wide enough that "0 recycled" means the allocator kept the block,
 * not that the case gave up early. */
#define kProbes 64

static const uint8_t kEngines[] = { ZWASM_ENGINE_INTERP, ZWASM_ENGINE_JIT };

static const char* engine_name(uint8_t kind) {
    return kind == ZWASM_ENGINE_JIT ? "jit" : "interp";
}

/* `set_wasi(A)` → instantiate → `set_wasi(B or NULL)` → run the guest.
 * Returns 0 when the first config was still whole afterwards. */
static int run_case(uint8_t engine, bool detach) {
    const char* what = detach ? "set_wasi(NULL)" : "set_wasi(cfg2)";
    int rc = 1;
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_store_t* probe_stores[kProbes] = { NULL };
    uintptr_t first_addr = 0;
    int recycled = 0;
#ifndef _WIN32
    int fd_before = -1, fd_after = -1;
#endif
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    zwasm_wasi_config_t* first = zwasm_wasi_config_new();
    if (!first) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    first_addr = (uintptr_t) first;
    /* Gives the host something to close on release — see the fd check. */
    if (!zwasm_wasi_config_preopen_dir(first, ".", "/sandbox")) {
        fputs("preopen_dir failed\n", stderr);
        goto cleanup;
    }
    zwasm_store_set_wasi(store, first); /* takes ownership */

    wasm_byte_vec_t binary = { sizeof(kExitWasm), (wasm_byte_t*) kExitWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    /* Opens the preopen: the host now holds a directory descriptor. */
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, engine);
    if (itrap) wasm_trap_delete(itrap);
    if (!instance) { fputs("zwasm_instance_new_ex failed\n", stderr); goto cleanup; }

    /* Built before the swap so their allocations cannot compete for the
     * block the swap releases. */
    for (size_t i = 0; i < kProbes; i++) {
        probe_stores[i] = wasm_store_new(eng);
        if (!probe_stores[i]) { fputs("probe store new failed\n", stderr); goto cleanup; }
    }

#ifndef _WIN32
    /* The lowest descriptor free right now — above the host's preopen. */
    fd_before = open("/dev/null", O_RDONLY);
    if (fd_before < 0) { perror("open /dev/null"); goto cleanup; }
    close(fd_before);
#endif

    /* The swap. `first` is now unreachable from C, but the instance above
     * still holds its address. */
    if (detach) {
        zwasm_store_set_wasi(store, NULL);
    } else {
        zwasm_wasi_config_t* second = zwasm_wasi_config_new();
        if (!second) { fputs("wasi config new failed\n", stderr); goto cleanup; }
        zwasm_store_set_wasi(store, second);
    }

#ifndef _WIN32
    fd_after = open("/dev/null", O_RDONLY);
    if (fd_after < 0) { perror("open /dev/null"); goto cleanup; }
    close(fd_after);
#endif

    for (size_t i = 0; i < kProbes; i++) {
        zwasm_wasi_config_t* probe = zwasm_wasi_config_new();
        if (!probe) { fputs("probe config new failed\n", stderr); goto cleanup; }
        /* Comparing the address only — `first` is never dereferenced. */
        if ((uintptr_t) probe == first_addr) recycled++;
        zwasm_store_set_wasi(probe_stores[i], probe);
    }

    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0] || wasm_extern_kind(exports.data[0]) != WASM_EXTERN_FUNC) {
        fputs("missing _start export\n", stderr);
        goto cleanup;
    }
    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_vec_t no_res = { 0, NULL };
    wasm_trap_t* trap = wasm_func_call(wasm_extern_as_func(exports.data[0]), &no_args, &no_res);
    if (!trap) {
        fprintf(stderr, "[%s] %s: proc_exit did not trap, so the guest never called the host\n",
                engine_name(engine), what);
        goto cleanup;
    }
    wasm_trap_delete(trap);

    rc = 0;
#ifndef _WIN32
    if (fd_after != fd_before) {
        fprintf(stderr,
                "[%s] %s: descriptor %d came free across the swap (was %d before) — the "
                "host closed a preopen its instance is still entitled to use\n",
                engine_name(engine), what, fd_after, fd_before);
        rc = 1;
    }
#endif
    for (size_t i = 0; i < kProbes; i++) {
        uint32_t code = 0;
        if (zwasm_store_wasi_exit_code(probe_stores[i], &code)) {
            fprintf(stderr,
                    "[%s] %s: probe config %zu reports exit status %u — the guest wrote "
                    "into a host released out from under its instance\n",
                    engine_name(engine), what, i, code);
            rc = 1;
        }
    }
    fprintf(stderr, "[%s] %s: probes recycled %d/%d\n", engine_name(engine), what, recycled, kProbes);

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    for (size_t i = 0; i < kProbes; i++) {
        if (probe_stores[i]) wasm_store_delete(probe_stores[i]);
    }
    if (store) wasm_store_delete(store);
    if (eng) wasm_engine_delete(eng);
    return rc;
}

/* Nothing captured the host, so releasing it right away stays correct:
 * a swap before any instantiation must not retain the first config. */
static int run_uncaptured(void) {
    wasm_engine_t* eng = wasm_engine_new();
    wasm_store_t* store = eng ? wasm_store_new(eng) : NULL;
    if (!eng || !store) { fputs("engine/store new failed\n", stderr); return 1; }
    for (int i = 0; i < 3; i++) {
        zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
        if (!cfg) { fputs("wasi config new failed\n", stderr); return 1; }
        zwasm_store_set_wasi(store, cfg);
    }
    zwasm_store_set_wasi(store, NULL);
    wasm_store_delete(store);
    wasm_engine_delete(eng);
    return 0;
}

int main(void) {
    int rc = 0;
    /* Every case runs even after one fails: which engines and which checks
     * fire is the diagnosis, and on a platform where the probes come up
     * empty the fd check is the only one that speaks. */
    for (size_t i = 0; i < sizeof(kEngines) / sizeof(kEngines[0]); i++) {
        rc |= run_case(kEngines[i], false);
        rc |= run_case(kEngines[i], true);
    }
    rc |= run_uncaptured();
    if (rc) return 1;
    puts("zwasm c_api_conformance/wasi_host_lifetime: a captured WASI host outlives its instances");
    return 0;
}
