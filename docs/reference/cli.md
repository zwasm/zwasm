# CLI reference

The `zwasm` binary is deliberately minimal — `run` + `compile`, the
wasmtime/wazero-aligned shape for a runtime. Validation is
programmatic (C-API `wasm_module_validate` / Zig `Engine.compile`);
wat↔wasm conversion and module introspection are `wasm-tools` / `wabt`'s
job, not a runtime's. Dispatch source:
[`src/cli/main.zig`](../../src/cli/main.zig).

## Commands

```
zwasm                                     # version + build-options banner
zwasm run <file.wasm|.cwasm> [args...]    # run a module
zwasm compile <file.wasm> -o <out.cwasm>  # compile to a .cwasm AOT artifact
zwasm --version | -V                      # version + build identity (wasm/wasi/engine)
zwasm --help | -h | help                  # usage
```

An unrecognised first token is an error (exit 2) — the surface is
explicit; there is no bare-file shortcut.

### `run`

Runs the module's default entry: the `_start` export, else `main`. It must
take no parameters — otherwise `run` refuses it, naming the export, with exit
1 — and its results, if any, print bare on stdout, one per line, like an
`--invoke` result. The exit code is the guest's `proc_exit` status (0 when it
never calls it), never the entry's result; a trap exits 1 with its kind on
stderr. A module with neither export is refused the same way (use `--invoke`).
The same contract holds on every engine and on a `.cwasm` (CWAS magic, which
loads + runs directly with no parse/compile); a shape the JIT cannot call is
refused with the reason rather than silently skipped (ADR-0230).

| Flag                       | Effect                                                                                                                                                                                                                                       |
|----------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--invoke <name>[=a,b,…]` | run the named export instead of `_start`/`main`. `=args` (comma-separated, parsed by param type i32/i64/f32/f64) supplies its parameters; typed results print bare, one per line, on stdout. Works on both the interpreter and the JIT (D-477) |
| `--engine <auto\|interp\|jit>` | default `auto` — prefers the JIT, falls back to the interpreter when the JIT declines the module (`--engine auto` is the explicit spelling of the same). `--engine interp` / `jit` force one. BOTH do full WASI; `jit` additionally executes SIMD-128                    |
| `--dir <host>[:<guest>]`   | preopen a host directory for WASI (colon separator; guest path mirrors host when omitted)                                                                                                                                                    |
| `--env KEY=VAL`            | set a WASI environment variable for the guest (repeatable; bare `KEY` sets empty)                                                                                                                                                            |
| `--fuel <N>`               | trap (`all fuel consumed`) after a deterministic budget. Units are engine-specific by design: interp counts instructions, jit counts function entries + loop iterations                                                                     |
| `--timeout <ms>`           | interrupt the guest (`interrupted` trap) after a wall-clock deadline — both engines                                                                                                                                                         |
| `--max-memory <bytes>`     | refuse `memory.grow` past this many bytes (64 KiB page granularity); the spec `-1` failure, not a trap                                                                                                                                       |
| `--max-table-elements <N>` | cap a module's **declared initial** table element count at load time (D-332); a module whose initial table exceeds `N` is refused. (Runtime `table.grow` past a table's own declared max already returns the spec `-1`.)                     |
| `--cache[=DIR]`            | transparent compilation cache (ADR-0203): the module is keyed by content hash and the `.cwasm` artifact of a previous run is reused (parse/validate/codegen skipped). Default root = the platform user-cache dir (`~/Library/Caches/zwasm` / `$XDG_CACHE_HOME\|~/.cache/zwasm` / `%LOCALAPPDATA%\zwasm`). ANY cache defect degrades (miss / bypass) — the cache never makes `run` fail. Bypassed under `--engine interp`. Cache-dir write access = native code execution as the user: point `--cache=DIR` only at trusted locations |
| `--cache-clear`            | delete this build's versioned cache subdirectory, then run normally (clear-only: does not itself enable caching — combine with `--cache` to clear-then-repopulate)                                                                            |

The sandboxing flags (`--fuel`/`--timeout`/`--max-memory`/`--max-table-elements`) apply to `.wasm`
**and `.cwasm`** runs (the artifact loads into the full runtime — ADR-0203);
a component run combined with them is refused loudly (exit 2) rather than
running unsandboxed.

### `compile`

Reads a `.wasm`, runs the JIT pipeline, and writes a `.cwasm` AOT artifact
to the `-o` / `--output` path (format-versioned; an artifact with an
incompatible artifact-format version or CPU arch is refused with a
specific error).
`zwasm run <file.cwasm>` executes it through the full runtime — identical
WASI / sandbox / `--invoke` behaviour to running the source `.wasm`
(ADR-0203: cache-hit == cache-miss by construction).

## Engine selection

- `.cwasm` input → AOT-loaded into the full runtime (full WASI).
  `--engine interp` with a `.cwasm` is a contradictory request (the
  artifact is precompiled JIT code) and is refused loudly (exit 2).
- `.wasm` input → **`auto` by default** (prefers the JIT, transparently falls
  back to the interpreter when the JIT *declines* the module; a module the JIT
  judges *invalid* fails with the reason, on every engine — #233);
  `--engine auto` spells the default explicitly.
  `--engine interp` forces the interpreter; `--engine jit` forces the JIT
  (full WASI, plus SIMD execution).
- `--cache` affects `.wasm` runs only (a `.cwasm` input IS the artifact;
  components have no artifact format) and is bypassed under
  `--engine interp`.

## Exit codes

| Code | Meaning                                                                                          |
|------|--------------------------------------------------------------------------------------------------|
| `0`  | Success — guest returned normally, or called `proc_exit(0)`                                     |
| `N`  | Guest called `proc_exit(N)` (the guest's own status surfaces verbatim)                           |
| `1`  | Guest trapped (OOB access, `unreachable`, integer divide-by-zero, fuel/timeout, …), OR a file read / load failure, OR a `compile` build/IO error                          |
| `2`  | Usage error — unknown subcommand, a `run` flag parse error, a requested limit refused (loud), or a `compile` usage error                                                  |
| `70` | Internal zwasm fault — a fatal signal/panic caught by the diagnostic fault handler              |

Source of truth: the `run` exit-code mapping (`src/cli/run.zig`) +
`main.zig`'s dispatch (`2`) and internal-fault handler (`70`).

## Environment

- `ZWASM_DEBUG=<categories>` — `dbg.zig` category filter.
- `ZWASM_DIAG=<channels>` — diagnostic trace ringbuffer drain.

## Not shipped

`validate` / `inspect` / `features` / `wat` / `wasm` are deliberately
absent. (`--env`, `--fuel`, `--timeout`, `--max-memory`,
`--max-table-elements` and `--invoke NAME=ARGS` arg-marshalling +
typed-result printing have all shipped — see the `run` table.)
