# Changelog

All notable changes to zwasm are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
will follow [SemVer](https://semver.org/) from the first tag.

zwasm v2 is a ground-up redesign of v1. **v1 ABI compatibility is out of
scope** — see [`docs/migration_v1_to_v2.md`](docs/migration_v1_to_v2.md).
SemVer compatibility guarantees start at the first stable `v2.0.0` tag.

## [Unreleased]

## [2.6.0] - 2026-08-31

### Added

- **A C host can read a WASI guest's exit status** (#234).
  `zwasm_store_wasi_exit_code` (`wasi.h`) returns the value the guest passed to
  `proc_exit`, and false when the Store has no WASI host or the guest never
  called it. The contract took four passes to settle and the final shape is
  what ships: the status is **per call** — each `wasm_func_call` into a Store
  clears it before running, so a `true` return describes the call just made and
  never an earlier guest's (#341) — and it follows **the runtime that actually
  ran `proc_exit`**, including when a call reaches another instance's export
  through an imported func or an imported table (#345, #352, ADR-0222 /
  ADR-0224) — measured on the interpreter, which is where a cross-instance
  call binds at all until #360.
  `zwasm_store_set_wasi` retires the host it replaces instead of
  freeing it, so an instance built under the old configuration keeps working
  (#314, ADR-0219). A `proc_exit` trap is also classified apart from a guest
  fault as `ZWASM_TRAP_WASI_EXIT`, identically on every engine (#331,
  ADR-0218) — but the kind never carries the number, so a host that needs the
  status reads it through the accessor either way.

- **WASI 0.1 is 72/72 on the official wasi-testsuite** for both engines on
  macOS and Linux, up from 58/72 on the interpreter and 54/72 on the JIT when
  the corpus was first measured on x86_64-linux (ADR-0208, D-583). The step is
  advisory and runs on the merge rather than on a PR, so nothing blocking holds
  that number yet — D-583's discharge is what moves it into `test-all`.
  A preopen now advertises the rights wasmtime does plus
  `PATH_FILESTAT_SET_SIZE` (ADR-0215 D2), and each call checks the right its
  witx doc comment names, answering `notcapable` when it is absent (#251,
  #260). wasmtime reports rights but only reads `FD_READ` / `FD_WRITE`; zwasm
  enforces them, as WasmEdge, WAMR and wasmer do. `poll_oneoff` answers
  `fd_read` / `fd_write`
  subscriptions rather than only clock ones (#263, ADR-0217). Path handling
  lost four host aborts and two wrong answers along the way: a trailing slash
  on `path_unlink_file` and a dotted final component on `path_rename` no longer
  panic the process (#310, #267), `path_open` honours `LOOKUP_SYMLINK_FOLLOW`
  on the final component (#276), four `fd_*` calls honour state the slot
  already carries (#274), and a `..` that stays inside the preopen is an
  ordinary path (#261).

- **`zwasm_version`** (`zwasm.h`) — the linked library reports its own semver
  (#237, ADR-0221). Only the accessor: macros, numeric fields and build
  identity are deferred with named triggers, because `libzwasm.a` and the
  headers are installed from one checkout by `zig build static-lib`, so the
  header/library mismatch a version macro detects cannot occur.

### Fixed

- **Four JIT liveness divergences that desynced vreg numbering into silent
  miscompiles** (#250, #252, #258, #272, D-596). Liveness simulates the operand
  stack and must agree with what emit actually pushes; where they disagreed the
  numbering slid and the JIT produced a wrong answer with no trap. The shapes:
  a block reached only by `br` losing its result vreg past `.end`,
  `ref.as_non_null` treated as 1→1 rather than transparent, the if-merge and
  terminator drains indexing from the wrong base, and the `else` arm's
  `param_arity` run one level deeper than emit. `ZWASM_DEBUG=liveverify` now
  checks the two against each other by vreg (#269), which is how the last of
  them was found.

- **`wasm_func_call` on a func created by `wasm_func_new` reported success
  without running the callback** (#315, ADR-0220). It returned NULL — the
  wasm-c-api's "no trap" — leaving the caller's result vector untouched;
  `wasm_func_param_arity` answers for host funcs, so an embedder that
  validated its argument shape first got a clean pass and then an unwritten
  answer. wasmtime permits the direct call, so ported code compiled, ran and
  was wrong. The callback now runs.

- **The EH frame sniffer dereferenced an unaligned frame pointer** (#323).
  ReleaseSafe-only, which is the configuration every release binary is built
  in — and which no lane ran the unit tests under, which is how it reached
  `main`. The Linux leg of every PR now runs them ReleaseSafe, and a `main`
  run is no longer cancelled by the next merge (#347, #312). Separately, `signal.ensureInstalled` marked the fault handler installed
  before installing it, so a second thread entering JIT code inside that window
  ran with no handler and died on the first guard fault — a race, in any build
  mode (#320).

- **A `try_table` with a catch clause lost its fall-through result on the
  JIT** (#280): emcc `-fwasm-exceptions` output trapped `oob_memory` on the
  default engine where the interpreter and wasmtime return the value. Behind
  it, the same family: register-homed locals were stale at a landing pad
  (they are reloaded there now, and spilled before a `throw` leaves the
  frame), an enclosing try_table could shadow a nested one covering the same
  code, and a `try_table` left dead by a tail call desynced the JIT's
  internal numbering for the rest of the function. The emcc fixture runs in
  the realworld lane's JIT result-check now.

- **`zwasm run` never handed a core module the process stdin** (#257) —
  `fd_read` on fd 0 was always EOF, whatever stdin held. The guest reads the
  process stdin on demand now: piped and redirected input arrive as the
  guest asks for them (no size cap, no read-ahead on a pipe that stays
  open, a terminal works), end of input is a zero-byte read, and
  `poll_oneoff` reports the descriptor readable rather than hung up. The C
  API still has no stdin source — that is #365 below.

- **Trap kinds on the C surface describe the call just made.** On x86_64 an
  out-of-bounds `return_call_indirect` or `call_indirect` and a null
  `return_call_ref` reported `unreachable` (#357); the JIT never cleared
  the kind between calls, so a kindless trap could report the previous
  call's — including `WASI_EXIT` (#336); and the interpreter mapped the GC
  heap cap to `binding_error` instead of `out_of_memory` (#361's
  interpreter half). On Windows, RDI/RSI are callee-saved under Win64 and
  were missing from the JIT's clobber list (#287), and `path.confine`
  treated `..\` as an opaque byte, so a backslash path escaped the preopen
  (#262).

- **Three JIT codegen faults on paths a real toolchain reaches.** The mixed
  multi-result thunks did not survive optimisation on Win64 (#288);
  `table.get`'s index was read after the descriptor loads rather than
  snapshotted before them (#212); and a null funcptr in a table was executed
  rather than trapped (D-586).

- **Validation accepted modules the specification rejects.** `call_ref` and
  `return_call_ref` checked their callee with a bare `isRef`, so a non-null
  externref was read as a function entity and both engines died; they now
  require a subtype of `(ref null typeidx)` and an immediate that names a func
  type (#249). A module with no code section was skipped by the validate path
  entirely (#278). Three GC subtype gaps closed alongside (#231, #240, #247).

### Changed

- **Building zwasm no longer fetches anything** (#235). `build.zig` imported
  the zlinter dev-dep at the top level, so every step — including
  `static-lib`, the one C and Rust consumers build — had to resolve the lint
  tool first, pulling zlinter, zls, diffz, known_folders and lsp_kit from
  GitHub. Packaged consumers (the `zwasm-sys` crate), `cargo vendor
  --offline`, sandboxed builders and offline CI all failed on it. The lint
  wiring moved to `tools/lint/build.zig` with its own manifest (ADR-0214);
  the root package now declares no dependencies at all. `zig build lint` is
  unchanged in rules, coverage and exit code — it is the only step that still
  needs the network on a cold package store.

### Documentation

- `include/zwasm.h` no longer claims the interpreter is the default engine — it
  has been `auto` (JIT-first, interpreter fallback) since ADR-0200, and the
  header is the only file a C embedder reads (#309). `include/wasi.h`'s
  trap-kind advice catches up with ADR-0218 (#348). The tutorial and README
  name `zig build static-lib` as the step that produces `libzwasm.a` and the
  public headers, which nothing in the reader's path said before (#325).
  `docs/development.md` records how a release is cut (#241). The Homebrew
  install points at `zwasm/homebrew-tap`, the last live `clojurewasm`
  reference in the tree.

### Known limitations

- **A cross-module func import cannot bind when the source instance is
  JIT-backed** (#360), which is the stock engine since ADR-0200. Two modules
  cannot be composed through `wasm_instance_new`. Forcing
  `ZWASM_ENGINE_INTERP` on the source through `zwasm_instance_new_ex` works,
  but that is a zwasm extension rather than the portable wasm-c-api path.
- **Instantiation failures return NULL without setting the trap
  out-parameter** (#353), so a failed link reports no reason.
- **The official preview1 corpus is host-dependent on Windows** — 65/72 on
  CI's `windows-2022`, 64/72 on a Windows 11 host, which also fails
  `path_symlink_trailing_slashes` (#290). Symlink, hardlink and readdir cases.
  Measurable there for the first time in this release; the runner previously
  died mid-corpus and the advisory step reported the leg green.
- **The JIT does not trap on the GC heap cap** (#364): an
  `array.new_default` past the 4 GiB cap returns a reference and the guest
  runs on, where the interpreter traps `out_of_memory` and wasmtime traps
  "allocation size too large".
- **The C API has no way to feed a guest's stdin** (#365):
  `zwasm_wasi_config_inherit_stdio` routes stdout and stderr but not fd 0,
  so an embedder's guest reads EOF where the CLI serves the process stdin.

## [2.5.0] - 2026-08-11

### Added

- **Full WASI 0.3 coverage** (ADR-0205, opt-in `-Dwasi=p3`). zwasm now serves
  all six WASI 0.3.0 proposals — `cli` / `clocks` / `random` / `filesystem` /
  `sockets` / `http` — over the Component-Model async substrate. Conformance is
  the official `wasm32-wasip3` corpus, **45/45 green on all three supported
  OSes** (macOS aarch64 / Linux x86_64 / Windows x86_64; `@unstable`-gated
  interfaces excluded, matching upstream release gating). Sockets and http run
  their real data planes: TCP/UDP connect / listen / send / receive / echo,
  `ip-name-lookup` real DNS, `wasi:http` fields / request / response /
  request-options resources, the exported `handler.handle` (service world),
  and `client.send` over `std.http.Client`. Platform substance behind the
  claim: on Linux, TCP listen composes a raw SO_REUSEADDR-only bind (the
  stdlib couples SO_REUSEPORT, whose `fastreuseport` bind-bucket cache breaks
  the address-in-use contract); on Windows, the runtime composes its own
  NT/AFD socket control plane (UNIQUE-share bind, dgram/bound connect,
  getsockname) and NT hardlinks (`FILE_LINK_INFORMATION`) where the pinned
  stdlib has gaps. A `doc-truth` CI guard
  (`check_wasi03_coverage_claims.sh`) keeps the coverage prose honest.

### Fixed

- **"the interpreter is the default engine" was still claimed in five places**
  (#163, reported by @jtakakura). The default has been `auto` (prefers the JIT,
  interpreter fallback) since the D-496 ch6 flip; v2.4.1 corrected `zwasm
  --help` but not `docs/benchmarks.md` (engine table + methodology),
  `.github/ISSUE_TEMPLATE/bug_report.yml` (the Execution-mode dropdown, which
  had no way to say "I did not pass `--engine`"), `.dev/ROADMAP.md` §10.2, or
  `docs/handoff_cw_v2_zig_api.md`. The same sweep retired two adjacent stale
  claims found alongside them: ROADMAP §10.2 still said the JIT was
  compute-only and rejected `--dir` (D-244 closed that), and the cljw handoff
  still listed JIT fuel / memory-cap / table-cap as a gap (they ship on both
  engines; only the D-314(a) epoch-counter upgrade remains). Published
  benchmark numbers are unaffected — `scripts/run_bench.sh --engines=` passes
  `--engine` explicitly for every row. `scripts/check_engine_default_claims.sh`
  now gates the claim: it anchors on the CLI usage text and sweeps tracked
  files for the stale phrasings, and it runs in `gate_commit.sh` **and** in a
  new always-on CI `doc-truth` job — doc-only PRs skip the 3-host matrix, which
  is how a prose claim rotted past three releases in the first place.

- **81 declared C-API symbols were missing from `libzwasm.a`** (#161). Zig only
  emits `export fn` symbols from files the analysis pass visits, and four
  `src/api/` files (`ref_base.zig`, `config.zig`, `host_info.zig`,
  `module_serialize.zig`) were absent from the `src/zwasm.zig` comptime
  force-analyse block — their lazy `pub const` re-exports through `api/wasm.zig`
  never trigger analysis. Every `wasm_X_copy` / `wasm_X_same` / `wasm_X_as_ref` /
  `wasm_ref_as_X` / `wasm_X_{get,set}_host_info` / `wasm_config_*` /
  `wasm_module_serialize`-family call declared in `include/wasm.h` failed at
  link time. `ref_base.zig` additionally did not compile (`wasm_extern_copy`
  nulled a field `Extern` does not have) — unnoticed precisely because the file
  was never analysed; its 6 tests (plus 5 more from the other three files) now
  run under `zig build test`. Three guards close the class: commit-time
  `scripts/check_api_export_analysis.sh` (every `pub export fn` file listed in
  the comptime block), plus two archive assertions in `scripts/test_extlink.sh`
  (every `src/api/` `pub export fn`, and every installed-header declaration,
  present in `libzwasm.a`). Verified end-to-end from C, Rust, and Go (cgo)
  consumers over the system linker.

## [2.4.1] - 2026-08-04

Consumer-driven patch release. Both fixes were found from ClojureWasm, and both
are things zwasm's own fixtures could not have surfaced: every component fixture
in this repo exported exactly one function, and no test captured guest output
from a guest that wanted to produce a lot of it.

### Added

- **`Limits.max_output_bytes` / `Host.max_capture_bytes`** — a cap on how many
  bytes a captured run may buffer. Nothing else bounded this: fuel bounds
  instructions, and bytes-per-instruction is the guest's choice. Measured from
  ClojureWasm, a guest looping on a 64-byte `fd_write` buffered 64,000,000 bytes
  for 1,000,000 fuel — ~64 GB under zwasm's own 1e9 default before the fuel trap
  fires. `null` stays the default, so every existing caller is unchanged; a
  capped buffer keeps the prefix that fits and returns `.nospc` (#158).

### Fixed

A component with two or more exports failed validation. Every component
fixture in this repo and in every known downstream exported exactly one
function, which is why it survived to a tagged release.

- **Component export index-space accounting.** A component-level
  `export` of a func ADDS an entry to the component func index space
  (`Binary.md`) — it does not merely name an existing one. Exports were
  never appended, so from the second export onward every `canon lift`'s
  sortidx read out of bounds and the component was rejected with
  `InvalidSort`. `wasm-tools validate --features all` accepts every case
  this rejected, i.e. zwasm was refusing spec-valid components rather
  than being strict. `.instance` exports had the same omission (#157).
- **An export could satisfy its own sortidx bound.** Once exports began
  extending their index spaces, the export bound check read the space
  size AFTER the export's own entry, so `(export "a" (instance 0))` with
  no instances validated — the export was the instance it named. The
  bound is now the space size at the export's definition point, which is
  what a sortidx referring only to earlier definitions actually means.
  Caught by the official corpus (`types_02`).

Found from the consumer side: ClojureWasm could not load a typed
16-export component fixture built to verify its WIT marshalling table.
Its headline feature — a Wasm component becoming a Clojure namespace —
could only ever load single-function components.

## [2.4.0] - 2026-08-03

External-consumer release: static-library linking from non-Zig
toolchains now works without a workaround, and sub-3.0 builds shed the
GC code that had been leaking into them.

### Added

- **`-Dcompiler-rt=true` for `zig build static-lib`** — bundles Zig's
  compiler-rt into `libzwasm.a` so an external non-Zig linker (rustc,
  gcc, clang) can resolve `__zig_probe_stack` (x86_64-macos) and the
  `__divti3`-class builtins. Same spelling as the v1 option. Default
  stays off, and the default archive is byte-identical to before.
  Thanks to [@jtakakura](https://github.com/jtakakura) for the report
  and the fix (#153, #154).

### Fixed

- **Docs corrected**: `docs/migration_v1_to_v2.md` claimed no
  `compiler-rt` flag was needed because "Zig bundles it into the
  archive". That is false — Zig's implicit default covers executables
  and dynamic libraries only, never a static library. The external
  link line now builds with `-Dcompiler-rt=true`, and
  `scripts/test_extlink.sh` asserts `compiler_rt.o` is in the archive
  and runs on the CI extended leg so the claim can no longer rot.

- **Sub-3.0 builds no longer carry the WasmGC code path.** The
  GC/subtyping JIT helpers are held as `JitRuntime` function-pointer
  fields whose default is the real helper (ADR-0203 D1), and a field
  default takes the address unconditionally — so the whole GC cohort
  stayed live even in a `-Dwasm=1.0` build. Each helper body is now
  comptime-guarded, letting DCE reclaim it: `-Dwasm=1.0 -Dwasi=p1`
  `.text` drops 2,957,749 → 2,614,800 bytes (−11.6%). Wasm 3.0 builds
  are unaffected (#150).

## [2.3.0] - 2026-07-17

Inventory sweep against the officially released **WASI 0.3.0**
(2026-06-11): the first slice of the official interface set, plus a
docs truth-sweep and Homebrew packaging.

### Added

- **Official WASI 0.3.0 clocks surface** — `wasi:clocks/system-clock`
  (0.3.0's renamed `wall-clock`; `instant{seconds: s64, nanoseconds:
  u32}`, pre-1970 instants representable with the floored split) and
  `get-resolution` on both clocks, served on the component host. The
  async `wait-until` / `wait-for` need scheduler-wired timer waitables
  and are tracked as debt (D-524).
- **Homebrew**: `brew install clojurewasm/tap/zwasm` (macOS arm64,
  Linux x86_64 / aarch64), packaging the release binaries.

### Changed

- **wasip3 fixture toolchain repinned** nightly-2026-06-14 →
  nightly-2026-06-24 (the newest nightly that can still `-Z build-std`
  wasm32-wasip3 — 2026-07-08/-16 hit an upstream std regression) and
  the conformance fixtures regenerated. Measured: the emitted imports
  are unchanged (wasi 0.2.6) because they come from the borrowed
  wasip2 wasi-libc, not the nightly's std bindings — the official-WIT
  fixture gap remains open as D-523.

### Fixed

- **`zwasm --help` engine wording**: the usage text claimed
  `interp (default)`; the real default (since 2.0.0) is `auto` — prefers
  the JIT with transparent interpreter fallback. The help now matches
  `docs/reference/cli.md` and the README, and also lists the `--cache` /
  `--cache-clear` flags shipped in 2.2.0.

### Documentation

- **WASI 0.3 documented**: README gains a WASI 0.3 row (Component-Model
  native-async core, opt-in `-Dwasi=p3`; official WASI 0.3.0 released
  2026-06-11 — `wasi:filesystem`/`wasi:sockets` data-plane and `wasi:http`
  pending), and the migration guide's "until it settles" framing is
  replaced accordingly.
- **GC build default corrected in the migration guide**: WasmGC is
  compiled in and executes by default (part of `-Dwasm=v3_0`); the guide
  previously described it as opt-in via `-Dgc`, which is inert (tracked
  as debt).
- **README gains an Install section** (Homebrew + prebuilt release
  binaries).

## [2.2.1] - 2026-07-16

Binary-size campaign (ADR-0204, PRs #144-#146), triggered by downstream
embedder measurement (cljw): the zwasm binary shrank ~21% (ReleaseSafe
arm64 CLI 5,282,584 → 4,173,736 B) with no API, behaviour, or JIT-output
change.

### Changed

- **JIT host-callback FP thunks share their bridge bodies** (D-522
  stage 1): the `f32`/`f64`-arg host-call thunks previously monomorphized
  the full marshalling body per (arg-kinds × result × slot) —
  ~300 B × 3,840 instantiations. The bodies now live in 60 shared
  `noinline` bridges; each per-slot thunk is a ~23 B tail-forwarder.
  `api.jit_host_bridge` code: 1,311 KB → 232 KB (−82%). Thunk C-ABI
  signatures, trap semantics, and the embedder-facing API are unchanged.

### Internal

- Binary-size baseline + per-stage rows recorded in
  `bench/results/size_history.yaml`; campaign record in ADR-0204
  (including the measured refutation of the "table-driven dispatch
  shrinks the emitter" hypothesis — D-521 discharged).

## [2.2.0] - 2026-07-09

AOT-full-fidelity campaign (ADR-0203, PRs #136-#142): `.cwasm` is now a
real deployment-grade artifact, and compilation is transparently cacheable.

### Added

- **Transparent compilation cache** (`zwasm run --cache[=DIR]`, D-508):
  modules are keyed by content hash and the `.cwasm` artifact of a previous
  run is reused — parse/validate/codegen skipped (measured 2.2x cold start
  on a 3 MB Go module). Deploy artifact stays `.wasm`; the cache lives in
  the platform user-cache dir under a versioned subdirectory. Any cache
  defect (corrupt entry, unserializable module, I/O failure) degrades to a
  miss or bypass — the cache can never make `run` fail. `--cache-clear`
  deletes this build's cache subdirectory.
- **`.cwasm` format v0.5**: embeds the original module bytes plus per-func
  frame/EH/oob metadata, so an artifact loads back into the FULL runtime.

### Changed

- **`zwasm run x.cwasm` now runs through the full runtime** — identical
  WASI, sandbox limits (`--fuel`/`--timeout`/`--max-memory`/
  `--max-table-elements`), `--invoke NAME=ARGS`, and start-function
  behaviour to running the source `.wasm` (cache-hit == cache-miss by
  construction). The former compute-only AOT mini-runtime is retired, and
  the `.cwasm` sandbox-flag refusal is gone.
- **Bounds-check-elided artifacts serialize** (guard-page hosts): `zwasm
  compile` output now carries the elision bit and re-registers trap
  entries at load; non-guarded hosts refuse the artifact loudly.
- `--engine interp` with a `.cwasm` input is now a loud exit-2 refusal
  (the artifact is precompiled JIT code); with `--cache` it bypasses the
  cache and runs the interpreter as asked.

### Fixed

- **JIT helper addresses are no longer baked into emitted code** (D-516):
  a `.cwasm` produced by one process crashed (or worse) in another under
  ASLR — all 36 helper call sites now route through position-independent
  runtime slots. A cross-process differential gate
  (`zig build test-aot-diff`, 63 fixtures) pins the fix.
- **`(start)` function now runs on the lenient JIT path** (Wasm §4.5.4) —
  a pre-existing `--engine jit` spec bug the campaign's differential
  harness caught.
- CI: the `ci-required` aggregator no longer reports green when its
  change-detection job fails.

## [2.1.0] - 2026-07-06

### Added

- **table64 compiles natively in the JIT** (D-475) — i64-indexed tables (the
  memory64 proposal's table extension) no longer fall back to the interpreter:
  the JIT table descriptors widened to u64 (`TableSlice.len`/`max`,
  `table_size`), and every table op (`table.get/set/size/grow/fill/copy/init`),
  `call_indirect`, and `return_call_indirect` now emits the index width
  declared by the table's type on both arm64 and x86_64, with wrap-safe
  64-bit bounds sums. i32 tables keep the byte-identical fast path.

### Fixed

- **table64 element segments under the JIT engine**: an active elem segment
  with an `i64.const` offset failed instantiation on the JIT path (masked by
  the interp fallback) — offsets now evaluate at u64 width, matching the
  interpreter.
- **Instantiate-time bounds hardening**: a guest-chosen 64-bit element offset
  can no longer wrap the table bounds check.
- **AOT**: a table64 whose minimum size exceeds the `.cwasm` u32 field is now
  rejected loudly instead of silently saturated.

## [2.0.0] - 2026-07-01

First **stable** release. Carries the complete feature set of `v2.0.0-rc.1`
(below), promoted to stable after the final hardening pass.

### Added

- **JIT `table.grow` for no-max tables** — a table declared without an upper
  bound now grows under the JIT up to a synthesized cap (`max(min*2, 1024)`,
  matching WAMR), where it previously returned the spec `-1` (D-501).

### Fixed

- **Docs / reference / examples** corrected to the code truth: the default
  engine is `.auto` (JIT-preferring, interp fallback); `include/zwasm.h` carries
  the sandboxing + engine-selection + `zwasm_instance_get_func` surface;
  `Linker.instantiate` takes `(module, opts)`; the build flag is `-Dwasm=v3_0`.
  The `docs/examples/zig_dep` external consumer builds and runs again.
- **Repo layout** decluttered: `CLAUDE.md` → `.claude/`, `THIRD_PARTY.md` →
  `legal/`, `examples/` → `docs/examples/`, community-health files → `.github/`.
- **Test harness**: guest std streams no longer leak to the real process fd 1/2
  in test builds (removed a phantom `failed command: … --listen=-` that appeared
  even when every test passed).

## [2.0.0-rc.1] - 2026-07-01

The first tagged **release candidate** for `v2.0.0`. The v2 redesign is
feature-complete and verified on the 3-host gate (Mac aarch64 + Linux x86_64 +
Windows x86_64). Earlier pre-releases were tagged `v2.0.0-alpha.*`.

### Added

- **WebAssembly 3.0** — all 9 proposals: GC, exception handling, tail
  calls, memory64, multi-memory, typed function references,
  extended-const, relaxed-SIMD, custom annotations. Plus full Wasm 1.0 + 2.0 (multi-value,
  SIMD-128, bulk-memory, reference-types, non-trapping FP→int conversion,
  sign-extension, mutable globals). Spec testsuite green, `skip-impl == 0`.
- **Execution backends** — interpreter (full WASI), JIT for ARM64
  (AAPCS64) + x86_64 SysV + x86_64 Win64 (MSVC ABI), and AOT (`.cwasm`
  compile + load + run). `interp == jit` differential testing.
- **Memory-safe GC-on-JIT** — a conservative native-stack-scan collector
  roots live references across collections; verified by an adversarial
  use-after-free test on aarch64 + x86_64.
- **WASI preview1** — args, environment, preopened directories, clock,
  random, fd I/O (under the interpreter).
- **C API** — `include/wasm.h` byte-identical to the upstream wasm-c-api
  standard (the interface wasmtime/wasmer follow), with full coverage of
  the standard surface, plus `wasi.h` + `zwasm.h` extensions.
- **Zig embedding API** — native `Engine` / `Module` /
  `Instance` / `Linker` / `Caller` / `Memory` / `Global` / `Table` /
  `TypedFunc` / `Trap` / `Value` facade, consumable as an external
  `build.zig.zon` dependency.
- **CLI** — `zwasm run` (WASI exec, `--invoke` / `--engine` / `--dir` /
  `--env`) and `zwasm compile` (`.cwasm` AOT), plus `--version` /
  `--help`.
- **Sandboxing** — cooperative interruption (cancel/timeout),
  deterministic fuel metering, and a host memory-growth cap, on BOTH
  engines (the JIT polls at function entry + every loop back-edge):
  Zig facade setters, C `zwasm_instance_*` setters + `zwasm_trap_kind`
  (`zwasm.h`), and CLI `--fuel` / `--timeout` / `--max-memory`.

### Changed (from v1)

- Breaking redesign of the C / Zig / CLI surfaces to the first-principles,
  industry-standard shape (not v1 parity). The CLI drops v1's
  `validate` / `inspect` / `features` / `wat` / `wasm` subcommands and
  capability-flag sprawl — validation is programmatic; conversion and
  introspection delegate to `wasm-tools` / `wabt`.

### Known limitations

- WASI 0.1 (preview1) `sock_*` calls have no host socket layer (they
  validate the fd and return `notsock`; preview1 has no socket-open).
  Real socket support — including TCP listeners — is available via
  WASI 0.2 (`wasi:sockets/tcp`), which is default-ON (Component Model
  functional, not deferred).
- Table funcref slots surface as opaque handles (not yet directly
  callable from the host).
