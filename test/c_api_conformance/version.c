/* zwasm v2 — a C host asks the linked library what version it is.
 *
 * The accessor exists so a C consumer can name a version in a bug report, and
 * that is only true if the value crosses the ABI. The Zig test beside the
 * implementation pins what the string *is* — it equals `build.zig.zon`'s
 * `.version`. It cannot pin any of the three things this case exists for:
 *
 *   - `include/zwasm.h`'s declaration agrees with the exported symbol. That is
 *     what compiling this file against the header and linking it against
 *     libzwasm.a proves; a return type or linkage the header got wrong fails
 *     here and nowhere else.
 *   - a C translation unit reaches the symbol at all.
 *   - the value survives being read as a C string: `strlen` returns something
 *     plausible, the storage is stable across calls and across unrelated
 *     runtime activity, and there is nothing to free.
 *
 * What this case does NOT prove is that the NUL terminator is present. That
 * is a compile-time guarantee of the Zig side's `[*:0]const u8` return type —
 * returning the unterminated `build_options.version.ptr` is a compile error,
 * so only an explicit `@ptrCast` could defeat it. Measured: a build with that
 * cast still prints `"2.5.0"` with strlen 5 from here, because the byte after
 * the version in constant data happens to be 0. The semver-shape check below
 * would catch an overrun into less friendly bytes, but it is a net, not a
 * proof, and it is written down as one.
 *
 * Run by `test-c-api-conformance`.
 */

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* MAJOR.MINOR.PATCH: three non-empty all-digit components, nothing else.
 * Stricter than "contains a dot" so that a string which starts correctly and
 * runs on into unrelated bytes is rejected — see the caveat in the header
 * comment about what that does and does not establish. */
static bool is_semver(const char* s) {
    size_t digits = 0;
    size_t dots = 0;
    for (const char* p = s; *p; p++) {
        if (*p >= '0' && *p <= '9') {
            digits++;
        } else if (*p == '.') {
            if (digits == 0) return false; /* empty component */
            digits = 0;
            dots++;
        } else {
            return false;
        }
    }
    return dots == 2 && digits > 0;
}

int main(void) {
    /* Declared `const char*` in zwasm.h; a mismatch with the export is a
     * compile or link failure, not a runtime one. */
    const char* v = zwasm_version();

    if (v == NULL) {
        fputs("zwasm_version() returned NULL\n", stderr);
        return 1;
    }

    const size_t len = strlen(v);
    if (len == 0) {
        fputs("zwasm_version() returned an empty string\n", stderr);
        return 1;
    }
    if (!is_semver(v)) {
        fprintf(stderr, "zwasm_version() = \"%s\" (strlen %zu) is not MAJOR.MINOR.PATCH\n",
                v, len);
        return 1;
    }

    /* Static storage: the same pointer every call, so there is nothing to free
     * and no allocator involved. A different pointer would mean the header's
     * ownership claim is wrong. */
    if (zwasm_version() != v) {
        fputs("zwasm_version() returned a different pointer on the second call\n", stderr);
        return 1;
    }

    /* …and that storage is not a buffer some later runtime activity reuses.
     * Copy it, drive the runtime, read it back. */
    char snapshot[64];
    if (len >= sizeof(snapshot)) {
        fprintf(stderr, "version string implausibly long (%zu)\n", len);
        return 1;
    }
    memcpy(snapshot, v, len + 1);

    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    if (!engine || !store) {
        fputs("engine/store new failed\n", stderr);
        if (store) wasm_store_delete(store);
        if (engine) wasm_engine_delete(engine);
        return 1;
    }
    wasm_store_delete(store);
    wasm_engine_delete(engine);

    if (strcmp(zwasm_version(), snapshot) != 0) {
        fprintf(stderr, "version changed across runtime activity: \"%s\" then \"%s\"\n",
                snapshot, zwasm_version());
        return 1;
    }

    printf("zwasm c_api_conformance/version: zwasm_version() = \"%s\" (strlen %zu)\n", v, len);
    return 0;
}
