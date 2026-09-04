# zwasm

A spec-compliant WebAssembly runtime written in Zig.

[![CI](https://github.com/zwasm/zwasm/actions/workflows/ci.yml/badge.svg)](https://github.com/zwasm/zwasm/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/zwasm/zwasm)](https://github.com/zwasm/zwasm/releases)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
[![WebAssembly 3.0](https://img.shields.io/badge/WebAssembly-3.0-654ff0?logo=webassembly&logoColor=white)](https://webassembly.org/)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

- **Full spec coverage** — WebAssembly 3.0 (all 9 proposals), spec testsuite
  green on macOS aarch64, Linux x86_64 and Windows x86_64. CI runs both
  engines; the JIT lane enumerates its known-wrong outcomes and gates on an
  exact match. WASI 0.1, 0.2 (Component Model, on by default) and 0.3
  (native async, opt-in).
- **Three execution backends** — interpreter, JIT (arm64 + x86_64) and AOT
  (`.cwasm`), differentially tested against each other on every change.
  wasmtime is the external oracle for the interpreter and JIT; the AOT lane
  against it runs on demand.
- **Embeddable, sandboxed by default** — C (standard `wasm-c-api`), Zig and
  CLI surfaces; the Zig API gives instances finite fuel, memory and table
  budgets by default, and every surface can set them explicitly.

> **Status**: feature-complete and green on the 3-OS CI matrix.
> **`v2.0.0` is the first stable release** (SemVer starts there); the current
> line is on [Releases](https://github.com/zwasm/zwasm/releases). v2 is a
> ground-up redesign — v1 is frozen at
> [`v1.11.1`](https://github.com/zwasm/zwasm/releases/tag/v1.11.1) (MIT), and
> the v2 line is Apache-2.0 with no v1 ABI compatibility.

## Install

**Homebrew** (macOS arm64 / Linux):

```sh
brew install zwasm/tap/zwasm
```

The `zwasm` binary is not code-signed. Homebrew installs it without a
Gatekeeper prompt on most setups; if macOS still blocks it as coming from an
unidentified developer, clear the quarantine flag once:

```sh
xattr -d com.apple.quarantine "$(which zwasm)"
```

Or grab a prebuilt binary straight from the
[Releases](https://github.com/zwasm/zwasm/releases) page (macOS arm64,
Linux x86_64/aarch64, Windows x86_64). Building from source is
[below](#building-from-source).

Then run a module:

```sh
zwasm run hello.wasm                     # WASI _start / main
zwasm run --invoke 'add=2,40' lib.wasm   # call a named export (prints 42)
zwasm compile app.wasm -o app.cwasm      # AOT-compile, then run the artifact
zwasm run app.cwasm
```

Full walkthrough (run, preopen dirs, embed from Zig and C):
[`docs/tutorial.md`](docs/tutorial.md).

## Supported platforms

zwasm is built and tested on these host targets:

| Platform | Arch    | Notes                                           |
|----------|---------|-------------------------------------------------|
| macOS    | aarch64 | primary development target                      |
| Linux    | x86_64  | native, spec + full test gate                   |
| Linux    | aarch64 | cross-built (not in the per-release test gate)  |
| Windows  | x86_64  | native, MSVC ABI                                |

Each release is verified on native macOS-aarch64, Linux-x86_64, and
Windows-x86_64 hosts. Linux-aarch64 is cross-built but not covered by that
per-release test gate. Windows ARM64 and other targets are out of scope for
now (demand-driven).

## Coverage

### Wasm versions

| Spec                                                                                                            | Status  | Notes                                                    |
|-----------------------------------------------------------------------------------------------------------------|---------|----------------------------------------------------------|
| Wasm 1.0                                                                                                        | ✅ 100% | spec testsuite green on the 3-OS CI matrix                |
| Wasm 2.0 (multi-value, SIMD-128, bulk-memory, reference-types, non-trapping FP→int, sign-ext, mutable globals) | ✅ 100% | `skip-impl == 0`; bit-identical across hosts             |
| Wasm 3.0 (GC, EH, tail-call, memory64, multi-memory, typed func refs, extended-const, relaxed-simd, custom annotations) | ✅ 100% | all 9 proposals; spec testsuite green on the 3-OS CI matrix (extended-const: unit-tested, its corpus lane is pending #217) |

### WASI

| Spec                                 | Status                    | Notes                                                                                                                                                                                                                                                                                                                                                         |
|--------------------------------------|---------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| WASI 0.1 (preview1)                  | ✅ functional, both engines | args / env / preopened dirs / clock / random / fd I/O with an enforced rights model, on the interpreter, the JIT and AOT. Measured against the official `WebAssembly/wasi-testsuite` preview1 corpus by a lane that blocks `ci-required`; `adapters/zwasm.py` is upstream, so a clean checkout of the suite re-derives the result against a stock binary |
| WASI 0.2 (preview2, Component Model) | ✅ functional, default-ON | wasmtime-equivalent campaign complete (2026-06-13): real `wasm32-wasip2` Rust/TinyGo components run e2e (fs, sockets incl. TCP listeners, guest-defined resources); typed embedder API (introspection + `invokeTyped`); validation rules 1-12, official corpus 158/0/0; gated by `-Dwasi>=p2` (default), `-Dwasi=p1` = lean opt-out |
| WASI 0.3 (preview3, native async)    | ✅ full coverage, opt-in (`-Dwasi=p3`) | All six WASI 0.3.0 proposals (released 2026-06-11) — `cli` / `clocks` / `random` / `filesystem` / `sockets` / `http` — served over the Component-Model async substrate (async-lifted exports via the stackless callback loop, `stream<T>`/`future<T>`, waitable-sets). Conformance = the official `wasm32-wasip3` corpus, **45/45 green on all three supported OSes** (macOS aarch64 / Linux x86_64 / Windows x86_64; `@unstable`-gated interfaces excluded, matching upstream's own release gating). Sockets/http run their real data planes (TCP/UDP + connect/echo, `client.send` over `std.http.Client`, exported `handler.handle`); on Windows the runtime composes its own NT/AFD socket control plane and NT hardlinks where the platform needs it |

All three execution paths do full WASI I/O — the interpreter, the JIT
(`--engine jit`), and AOT (`.cwasm`). The JIT additionally
executes SIMD-128 (the interpreter does not).

### Execution backends

| Backend                              | Status        |
|--------------------------------------|---------------|
| Interpreter (full WASI)              | ✅ functional |
| JIT — ARM64 (AAPCS64)               | ✅ functional |
| JIT — x86_64 SysV (Linux/macOS)     | ✅ functional |
| JIT — x86_64 Win64 (MSVC ABI)       | ✅ functional |
| AOT — `.cwasm` compile + load + run | ✅ functional |

The GC-on-JIT path is memory-safe: a conservative native-stack-scan
collector roots live references across collections, verified by an
adversarial use-after-free test on aarch64 + x86_64.

## CLI

```sh
zwasm                                  # print version + build options
zwasm run <file.wasm|.cwasm> [args...] # run a module (WASI _start / main)
    [--invoke <name>[=a,b,…]]          #   run a named export; =args prints typed results
    [--engine <interp|jit>]            #   default: auto (prefers JIT, interp fallback); interp|jit force one (both full WASI; jit adds SIMD)
    [--dir <host>[:<guest>]]           #   preopen a host directory for WASI
    [--env <KEY=VAL>]                  #   set a WASI env var (repeatable)
    [--fuel <N>]                       #   trap after a deterministic budget (error.OutOfFuel)
    [--timeout <ms>]                   #   interrupt after a wall-clock deadline
    [--max-memory <bytes>]             #   refuse memory.grow past this many bytes
    [--max-table-elements <N>]         #   refuse table growth past this many elements
    [--cache[=DIR]]                    #   transparent compilation cache (content-keyed .cwasm reuse; a cache defect degrades, never fails the run)
    [--cache-clear]                    #   delete this build's cache subdirectory (clear-only; combine with --cache to repopulate)
zwasm compile <file.wasm> -o <out.cwasm>  # compile to a .cwasm AOT artifact
zwasm --version | -V                   # version + build identity (wasm/wasi/engine)
zwasm --help | -h | help
```

The CLI is deliberately `run` + `compile` — the
wasmtime/wazero-aligned shape for a runtime. Validation is programmatic
(C-API `wasm_module_validate` / Zig `Engine.compile`); wat↔wasm
conversion and module introspection are `wasm-tools` / `wabt`'s job.
Full flag table + exit codes: [`docs/reference/cli.md`](docs/reference/cli.md).

Runtime env vars: `ZWASM_DEBUG=<categories>` (dbg category filter),
`ZWASM_DIAG=<channels>` (diagnostic trace ringbuffer drain).

## Embedding

zwasm is a library first, with two host surfaces.

**Zig** (native facade) — add zwasm as a `build.zig.zon`
dependency, pull its module (`b.dependency("zwasm", .{}).module("zwasm")`),
then:

```zig
const zwasm = @import("zwasm");

var eng = try zwasm.Engine.init(alloc, .{});
defer eng.deinit();
var mod = try eng.compile(&wasm_bytes);
defer mod.deinit();
var inst = try mod.instantiate(.{});
defer inst.deinit();

const add = inst.typedFunc(fn (i32, i32) i32, "add");
const r = try add.call(.{ 2, 40 }); // 42
```

Surface: `Engine` / `Module` / `Instance` / `Linker` (host imports via
`defineFunc` + `Caller`) / `Memory` / `Global` / `Table` / `TypedFunc` /
`Trap` / `Value`. Runnable: [`docs/examples/zig_dep/`](docs/examples/zig_dep/)
(external path-dep consumer) and [`docs/examples/zig_host/`](docs/examples/zig_host/).

**Sandboxing untrusted guests** (both engines): `mod.instantiate(.{})`
is **bounded by default** — `InstantiateOpts.fuel` and `.max_memory_pages` carry
finite defaults (a deterministic instruction budget → `error.OutOfFuel`, and a
linear-memory cap), so a forgotten budget still yields a metered instance; set an
axis to `.unmetered` (e.g. `.{ .fuel = .unmetered }`) for trusted code. `Instance.interrupt()` stops a runaway guest from
another thread (timeout or cancellation → `error.Interrupted`);
`setFuel`/`setMemoryPagesLimit`/`setTableElementsLimit` adjust the budgets on a
live instance. The **JIT engine carries the same triad**: polls at
function entry + every loop back-edge deliver interruption and fuel (units there
= entries + loop iterations), and `memory.grow` honours the host cap. From C,
use the `zwasm_instance_*` setters in [`include/zwasm.h`](include/zwasm.h);
from the CLI, `--fuel` / `--timeout` / `--max-memory` (both engines).

**C** (wasm-c-api) — [`include/wasm.h`](include/wasm.h) is byte-identical
to the upstream standard (the interface wasmtime/wasmer follow); WASI
host-setup is the hand-authored [`include/wasi.h`](include/wasi.h). See
[`docs/examples/c_host/`](docs/examples/c_host/) and
[`docs/reference/c_api.md`](docs/reference/c_api.md).

**Any FFI language** — [`docs/examples/rust_host/`](docs/examples/rust_host/)
(`zig build run-rust-host`) declares the same `wasm.h` ABI from Rust and
links `libzwasm`, demonstrating the C surface is consumable from any
FFI-capable language, not just C.

## Build flags

```
-Dwasm=v3_0|v2_0|v1_0       # default v3_0; lower levels omit later proposals
-Dwasi=none|p1|p2|p3        # default p2; ordered tier. p2 = Component Model / WASI-P2 host,
                            #   p3 = + Preview-3 async. -Dwasi=p1 = lean build (~-8%)
-Dengine=both|jit|interp    # default both
-Dstrip=true|false          # default false
```

## Ecosystem

| Repository | What it is |
| --- | --- |
| [zwasm-rust-sdk](https://github.com/zwasm/zwasm-rust-sdk) | Safe Rust bindings (`zwasm-sdk` / `zwasm-sys` on crates.io) |
| [containerd-shim-zwasm](https://github.com/zwasm/containerd-shim-zwasm) | containerd shim — run Wasm workloads on containerd |
| [homebrew-tap](https://github.com/zwasm/homebrew-tap) | Homebrew formulae |

The org profile at [github.com/zwasm](https://github.com/zwasm) tracks the
same list.

## Building from source

```sh
zig build              # compile the zwasm binary
zig build test         # unit tests
zig build test-all     # all enabled test layers

# Embedding from C or Rust: libzwasm.a + the three public headers into zig-out/
zig build static-lib -Doptimize=ReleaseSafe -Dcompiler-rt=true

# Cross-compile sanity check (catches, e.g., Win64 compile errors in ~3s)
zig build -Dtarget=x86_64-windows-gnu
```

The link line that goes with `static-lib`, and what each of its flags is for,
is in [`docs/tutorial.md`](docs/tutorial.md) §5.

**You need Zig 0.16.0 and [`wasm-tools`](https://github.com/bytecodealliance/wasm-tools)**
(pinned in [`.github/versions.lock`](.github/versions.lock); the build
generates `test/spec/spectest.wasm` with it). Multi-OS verification is handled
automatically by CI on every pull request. The full development story
(test layers, optional tools, git hooks, what's maintainer-only) is in
**[`docs/development.md`](docs/development.md)**; the contribution flow is in
[`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md).

Nix is optional: `nix develop` (or direnv) loads the pinned Zig 0.16.0
and tool surface (`flake.nix`: hyperfine, wasm-tools, wasmtime, yq-go,
lldb, nasm).

## Community & contributing

- **Questions, ideas, show & tell** →
  [GitHub Discussions](https://github.com/zwasm/zwasm/discussions)
- **Bugs / feature requests** →
  [issue templates](https://github.com/zwasm/zwasm/issues/new/choose)
- **First contribution?** Read
  [`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md) and pick a
  [`good first issue`](https://github.com/zwasm/zwasm/labels/good%20first%20issue)
  — CI verifies the 3-OS matrix on every PR.
- **Security** — report privately via
  [security advisories](https://github.com/zwasm/zwasm/security/advisories/new),
  never public issues ([`SECURITY.md`](.github/SECURITY.md)).

## Layout

```
src/         Zig sources (parse/ validate/ ir/ runtime/ instruction/ feature/
             engine/ interp/ wasi/ api/ cli/ diagnostic/ support/ platform/)
include/     Public C headers (wasm.h / wasi.h / zwasm.h)
build.zig    Build script
flake.nix    Nix dev shell pinned to Zig 0.16.0
docs/        Tutorial + API reference + benchmarks
.dev/        ROADMAP + handover + ADRs + lessons + setup notes
.claude/     Claude Code settings, skills, rules (auto-loaded)
scripts/     pre-commit gate + integrity checks + bench tooling
test/        per-layer suites; unified `zig build test-all`
bench/       benchmark history (append-only)
tools/lint/  the `zig build lint` sub-build (the only thing with a dep)
```

## Documentation

- [`docs/tutorial.md`](docs/tutorial.md) — getting started (build, run, embed)
- [`docs/reference/`](docs/reference/) — API reference:
  [Zig](docs/reference/zig_api.md) · [C](docs/reference/c_api.md) · [CLI](docs/reference/cli.md)
- [`docs/benchmarks.md`](docs/benchmarks.md) — performance vs other runtimes + across engines
- [`CHANGELOG.md`](CHANGELOG.md) — release notes

## References

- [`.dev/ROADMAP.md`](.dev/ROADMAP.md) — mission, principles, phase plan
- [`.dev/decisions/`](.dev/decisions/) — ADRs (deviations from ROADMAP)

## License

Copyright 2026 zwasm Contributors. Licensed under Apache-2.0 — see `LICENSE`.
