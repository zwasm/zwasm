# 0221 — Expose the runtime version to C as semver alone, by function alone

- **Status**: Accepted
- **Date**: 2026-08-29
- **Author**: Junji Takakura
- **Tags**: c-abi, versioning, distribution

## Context

`include/zwasm.h` has no way to ask the linked library what it is, so a C
consumer cannot report the runtime version it is running against. The value
itself already exists and is already threaded: `build.zig:110` reads
`.version` out of `build.zig.zon` and injects it as `build_options.version`
(again at `:472` and `:522` for the component and p3 modules);
`src/zwasm.zig:39` re-exports it as `zwasm.version`, and `src/cli/cache.zig:51`
puts it in the cache directory name. Nothing carries it across the C boundary.

Issue #237 left two questions open, and both turn on facts about how zwasm is
actually distributed and consumed rather than on taste. Those facts were
checked rather than assumed:

**There is no distribution shape in which a header and a library can come from
different commits.** `build.zig:1241` declares the only library, and its
`.linkage` is `.static`; there is no shared-library step. `zig build static-lib`
(`build.zig:1270`–`1282`) installs `libzwasm.a` and `wasm.h` / `wasi.h` /
`zwasm.h` into one prefix out of one checkout. `.github/workflows/release.yml`
publishes the CLI executable only — no archive, no headers — so a release
carries no C surface at all. There is no distro packaging.

**The one downstream C consumer builds the library from the header's own
commit.** `zwasm-rust-sdk`'s `crates/zwasm-sys` vendors this repository as a git
submodule (`.gitmodules`: `crates/zwasm-sys/zwasm`), runs `zig build static-lib`
inside it (`build.rs:112`–`122`) and links `static=zwasm` (`build.rs:134`), with
bindgen generating the Rust bindings from that same `zwasm.h`
(`build.rs:6`, `:44`). `containerd-shim-zwasm` reaches zwasm only through that
SDK. So header and library are the same commit by construction, and the
mismatch a version macro would detect cannot occur.

**`include/zwasm.h` is hand-authored.** Nothing generates it —
`scripts/fetch_wasm_c_api.sh` fetches `wasm.h` from upstream and leaves
`zwasm.h` alone. This is the difference from wasmtime, whose header is
generated per release and therefore cannot drift from its manifest.

**No consumer maps a capability axis yet.** `zwasm-sys` passes only `-Dtarget`,
`-Dcompiler-rt` and `-Doptimize` to `zig build static-lib`; neither
`zwasm-sys/Cargo.toml` nor the workspace declares a `[features]` section. The
identity consumer named in the issue — the SDK mapping `-Dgc` / `-Dcomponent`
onto cargo features — is real but not yet present, and its arrival is
observable in exactly those two files.

## Decision

**One function, semver alone.**

`const char* zwasm_version(void)` in `include/zwasm.h`, implemented as
`zwasm_version` in `src/api/zwasm_ext.zig` beside the other zwasm-only
extensions. It returns `build_options.version` in static storage, never NULL,
and the caller never frees it.

`build_options.version` is a `[]const u8` with no terminator, so returning its
`.ptr` would hand C an unterminated pointer. The accessor re-materialises the
same comptime bytes as a sentinel-terminated array with
`std.fmt.comptimePrint`, which lives in the binary's constant data for the
process's life. This is the first `[*:0]const u8` export in `src/api/`; there
was no house form to copy.

**Macros (`ZWASM_VERSION`, `ZWASM_VERSION_MAJOR`, …) are deferred** until a
distribution exists in which a header and a library can arrive separately.
When they ship, the sync gate that keeps them equal to `build.zig.zon` ships in
the same PR.

**Numeric accessors (`zwasm_version_major()` and friends) are deferred** until
a consumer wants runtime gating.

**Build identity is deferred**, and when it ships it ships as one accessor per
axis rather than one composed string — the one-function-per-capability shape
discussion #209 settled. The trigger is concrete: the SDK growing a
`[features]` section that maps `-Dgc` / `-Dcomponent`.

Recorded beside that defer, because it is the cost of it: deferring identity
delays diagnosis, not prevention. A consumer linking a `-Dwasi=p1` build and
reading `"2.5.0"` can believe it holds everything that version implies. In
practice a link error or a runtime failure surfaces first, which is why this
does not overturn the defer — but the header says so in as many words, so the
belief is at least contradicted in the place the consumer reads.

## Alternatives considered

### Alternative A — ship macros alongside the function

- **Sketch**: `#define ZWASM_VERSION "2.5.0"` (and the numeric triple) next to
  the accessor, so a consumer can compare the header it compiled against with
  the library it linked.
- **Why rejected**: the mismatch it detects is unreachable today — every
  distribution path above ships header and library from one checkout. Against
  that, a hand-authored header with baked numbers is dual maintenance with
  `build.zig.zon`, which is the rot ADR-0216 argues against, and the only
  honest fix is a gate that re-reads the manifest and compares. That gate is a
  larger artifact than the accessor it guards. Macros are purely additive on a
  pre-1.0 surface, so deferring costs only the date on which mismatch
  detection becomes available.

### Alternative B — numeric accessors instead of (or beside) the string

- **Sketch**: `zwasm_version_major()` / `_minor()` / `_patch()`, the shape
  wasmedge uses. They read `build_options` exactly as the string accessor does,
  so they carry no drift risk.
- **Why rejected**: nothing is asking to gate on a version at runtime. The
  string answers the stated need — a C host reporting what it links, so a bug
  report can name it — and parsing `"2.5.0"` is not the obstacle that would
  make a consumer ask. Deferring keeps the surface at one symbol; the numeric
  form remains available without breaking anything, since it is additive.

### Alternative C — build identity in this change

- **Sketch**: answer what `zwasm --version` answers —
  `wasm: <level>, wasi: <level>, engine: <default>` — either as the CLI's
  composed line or as per-axis accessors.
- **Why rejected**: this is the project's own bar, applied in #209 to both the
  invoke hook and wasi:otel — the C API grows when a consumer asks. No consumer
  asks yet, and the check above says so from the consumer's own source rather
  than from belief. Shipping the composed string would additionally be the
  wrong shape to be stuck with: it is a string a consumer must parse, where
  #209 settled on machine-readable per-capability functions. The cost of
  waiting is recorded above rather than dismissed.

### Alternative D — return the unterminated `.ptr` and document a length

- **Sketch**: hand C `build_options.version.ptr` and expose the length
  separately, avoiding the sentinel question altogether.
- **Why rejected**: it makes every caller's `printf("%s")` undefined behaviour
  — the shape a C consumer will reach for first. A NUL-terminated `const char*`
  is what the header's other string-shaped neighbours in `wasm.h` imply, and
  the terminator costs one comptime byte.

## Consequences

- **Positive**: a C host can print the runtime version of the library it
  linked, which is what a bug report needs. `zwasm-rust-sdk` picks the symbol
  up with no work — bindgen regenerates from the same header. The accessor
  reads the same `build_options.version` as the CLI and the cache directory,
  so there is exactly one place the version lives.
- **Negative**: the answer does not distinguish builds that are not
  interchangeable, and the failure mode of that is recorded above rather than
  solved. Consumers who want identity wait for a follow-up.
- **Neutral / follow-ups**:
  - `include/zwasm.h` grows one declaration. No existing symbol, value or
    signature changes; `scripts/test_extlink.sh` derives its symbol set from
    the headers, so the new export is required of the archive automatically.
  - `zwasm --version` is untouched: the CLI keeps printing identity, and the C
    API deliberately answers less. The two surfaces now disagree in scope, on
    purpose.
  - The change is tested from both sides, because neither side can cover the
    other. `test/c_api_conformance/version.c` is the shape a new public C
    function takes here — the precedent is #330's `wasi_exit_code.c` — and it
    holds three things nothing else does:
    1. `include/zwasm.h`'s declaration agrees with the export. Compiling this
       file against the header and linking it against `libzwasm.a` is what
       catches a wrong return type or linkage in the header.
    2. A C translation unit reaches the symbol at all.
    3. The storage is stable: the same pointer on every call, unchanged across
       unrelated runtime activity, nothing to free — the ownership the header
       claims.
    `scripts/test_extlink.sh` does not substitute for any of them: it proves
    an external toolchain can link the archive, not that the declaration
    matches the implementation. The Zig test in `src/api/zwasm_ext.zig` owns
    the other half — the string equals `build.zig.zon`'s `.version`.
  - Neither test proves the terminator, and both say so. The sentinel is a
    compile-time guarantee of the `[*:0]const u8` return type: `return
    build_options.version.ptr;` does not compile ("destination pointer
    requires '0' sentinel"), so only an explicit `@ptrCast` defeats it.
    Measured on x86_64-linux, Zig 0.16.0: a build carrying that cast still
    reads back `"2.5.0"` with `strlen` 5 from C, because the byte following
    the version in constant data happens to be 0. A runtime test cannot
    distinguish the two here, and claiming otherwise would be a hollow gate —
    so the claim is written down at its real strength instead.
  - That Zig test compares two different *readings* of the manifest, which is
    why it is not tautological: the accessor's value is `.version` as
    `build.zig`'s `@import("build.zig.zon")` parsed it at build time, and the
    expectation is the same field read off disk at test time. Comparing
    against `build_options.version` instead would compare the injection with
    itself; transcribing `"2.5.0"` would be the dual maintenance this decision
    rejects macros for. Its reach is correspondingly narrow and worth stating
    exactly: it catches a stale `build_options` that was not regenerated, and
    an accessor that later grows a hardcoded string. Both are small, and both
    are real.
  - The manifest cannot be reached at comptime:
    `@embedFile("../../build.zig.zon")` from `src/api/` is rejected with
    "embed of file outside package path", because the root module is
    `src/zwasm.zig` and the package root is therefore `src/` (measured on Zig
    0.16.0). The read is a runtime one, so the test requires CWD = the
    repository root. That requirement is stated in the test's own doc comment
    and a wrong CWD fails by a named error rather than silently — an
    environment-dependent check that goes quiet is the failure mode #327 and
    #268 are about.

## References

- Issue: zwasm/zwasm#237
- Related ADRs: ADR-0216 (a value duplicated between two files rots; the ledger
  case for the same argument), ADR-0212 D1 (a change to product semantics needs
  maintainer sign-off — this ADR is that record), ADR-0214 (the `static-lib`
  target C and Rust consumers build), ADR-0156 (the v2 C surface broke v1 on
  purpose; release stays user-only)
- Discussion: zwasm/zwasm#209 — "the C API grows when a consumer asks", and the
  one-function-per-capability shape
- Files: `include/zwasm.h`, `src/api/zwasm_ext.zig`,
  `test/c_api_conformance/version.c` (and its entry in `build.zig`'s
  `conformance_cases`); the value's origin at
  `build.zig:110` and `src/zwasm.zig:39`; the distribution evidence at
  `build.zig:1241`, `build.zig:1270`–`1282`,
  `.github/workflows/release.yml`
- External: `zwasm/zwasm-rust-sdk` — `.gitmodules`,
  `crates/zwasm-sys/build.rs:6`, `:44`, `:112`–`134`
