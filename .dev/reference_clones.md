# Read-only reference clones

> **Doc-state**: ACTIVE — load-bearing reference (Phase 9+ scope).

Pointed to from `CLAUDE.md` and mirrored in the maintainer's
gitignored `.claude/settings.local.json` (`additionalDirectories`).
Never edit or commit from any of these paths — they are reference
material, not project state.

> **Author-local layout.** The absolute paths below reflect one
> maintainer's checkout layout and are **not required to build, test,
> or use zwasm** — an external clone needs none of them. They only
> position the read-only textbook clones for local development.

| Path                                             | What it is                                                             |
|--------------------------------------------------|------------------------------------------------------------------------|
| `~/Documents/MyProducts/zwasm/`                  | THIS repo (v2 on `main`; v1 frozen at tag `v1.11.1` in the same history — **read v1, never copy**) |
| `~/Documents/OSS/wasmtime/`                      | wasmtime + cranelift (winch / regalloc2 reference)                     |
| `~/Documents/OSS/zware/`                         | Zig idiomatic interpreter                                              |
| `~/Documents/OSS/wasm3/`                         | wasm3 (M3 IR + tail-call dispatch interpreter)                         |
| `~/Documents/OSS/wasmer/`                        | wasmer (singlepass / multi-backend)                                    |
| `~/Documents/OSS/wazero/`                        | wazero (Go, dual-engine)                                               |
| `~/Documents/OSS/wasm-c-api/`                    | wasm-c-api standard ABI                                                |
| `~/Documents/OSS/regalloc2/`                     | cranelift register allocator                                           |
| `~/Documents/OSS/wasm-tools/`                    | `wasm-tools smith` (fuzz corpus), `validate`, ...                      |
| `~/Documents/OSS/sightglass/`                    | Bytecode Alliance bench suite                                          |
| `~/Documents/OSS/wasm-micro-runtime/`            | WAMR (lightweight runtime reference)                                   |
| `~/Documents/OSS/cap-std/`                       | Capability-based std for Rust                                          |
| `~/Documents/OSS/wit-bindgen/`                   | Component Model bindgen (post-v0.1.0 reference)                        |
| `~/Documents/OSS/WasmEdge/`                      | WasmEdge (cloud-native runtime; AOT strategy reference)                |
| `~/Documents/OSS/wasi-rs/`                       | Rust WASI binding (host idiom + C ABI consumer reference)              |
| `~/Documents/OSS/dynasm-rs/`                     | DynASM (Rust port; copy-and-patch reference, post-v0.1.0)              |
| `~/Documents/OSS/poop/`                          | Andrew Kelley's perf-bench tool (Zig)                                  |
| `~/Documents/OSS/hyperfine/`                     | Hyperfine source (bench tool used in `bench/`)                         |
| `~/Documents/OSS/extism/`                        | Extism (multi-language Wasm host SDK reference)                        |
| `~/Documents/OSS/WebAssembly/spec/`              | reference interpreter (OCaml) + spec text — checked out at `wg-3.0`; see version pin note below |
| `~/Documents/OSS/WebAssembly/testsuite/`         | spec testsuite — see version pin note below                            |
| `~/Documents/OSS/WebAssembly/<proposal>/`        | per-proposal spec + tests (multi-value, simd, gc, eh, ...)             |
| `~/Documents/OSS/WASI/`                          | WASI spec monorepo — `specifications/wasi-0.3.0/` (released 2026-06-11) + live `proposals/*/wit/` WIT sources. NOTE: the per-interface `WebAssembly/wasi-*` repos below were ARCHIVED 2025-11-25; this monorepo is the living source |
| `~/Documents/OSS/WebAssembly/wasi-<iface>/`      | archived (2025-11-25) per-interface WASI repos (cli/clocks/filesystem/http/io/random/sockets) — historical WIT incl. `wit-0.3.0-draft/`; prefer `WASI/proposals/` for current WIT |
| `~/Documents/OSS/WebAssembly/component-model/`   | Component Model spec (canonical ABI, async, WIT) — WASI 0.2/0.3 substrate |
| `~/Documents/OSS/wasi-testsuite/`                | WASI testsuite (P1 + p3 guest tests)                                   |
| `~/Documents/OSS/wasmtime-py/`                   | wasmtime Python embedding (host-API shape reference)                   |
| `~/Documents/OSS/zig/`                           | Zig 0.16 stdlib source                                                 |

## Version pin policy (Wasm 3.0 scope; historical 2.0 policy = ADR-0061)

The authoritative pin is [`.dev/spec_pin.yaml`](spec_pin.yaml) —
`WebAssembly/spec` + `WebAssembly/testsuite` SHAs acknowledged as the
vendoring baseline for the committed `test/spec/` conformance corpora.
`scripts/check_spec_bump.sh` alerts when upstream advances beyond the
pin; drift is assessed at the quarterly `proposal_watch.md` review
(benign drift → pin bump, `test/core/` changes → re-vendor + re-distil).

- The local `WebAssembly/spec` clone sits on the `wg-3.0` branch
  (Wasm 3.0, W3C Rec 2025-09) — the scope zwasm v2 ships.
- Wasm 3.0 corpora (`test/spec/wasm-3.0-assert/{memory64,multi-memory,
  gc,function-references,tail-call,exception-handling}/`) are committed
  and wired into `test-all`; the historical Phase-9 rule "never add 3.0
  corpora until the runtime lands" (ADR-0061) is fulfilled and retired.
- `git pull` on these clones is fine (they are reference material);
  regen/re-distil of committed corpora happens only via the
  `scripts/regen_spec_*.sh` flow against the pinned SHAs.
