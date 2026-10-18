# Component Model fixture: preview1_with_arg (preview1 imports satisfied by `with`)

A core module imports `wasi_snapshot_preview1` `random_get`, and the
component satisfies it with a `with` arg naming an earlier core instance —
the shape wit-component's preview1 adapter produces. The WASI-P2 build
(`buildWasiP2Component`, the `zwasm run` path) pours that instance into the
importer's Linker with `defineInstance` and sets no WASI host, so the import
links only if the Linker binds its own entry before asking for a host (#504).

## Why hand-written component WAT

The fixture needs exactly one thing — a `wasi_snapshot_preview1` import
under a `with` arg — and nothing a real adapter brings along (memory,
`cabi_realloc`, `wasi:cli` imports). The component text format expresses it
directly and `wasm-tools parse` assembles it in one step.

## Reproduce

```sh
wasm-tools parse preview1_with_arg.wat -o preview1_with_arg.wasm
wasm-tools validate --features all preview1_with_arg.wasm
```

`wasm-tools` 1.251.0.

## Files

- `preview1_with_arg.wat`  — source (single-file component WAT)
- `preview1_with_arg.wasm` — the fixture (252 B)

## Behaviour

Both core instances build; the second's `f` returns `7`. The component has
no `wasi:cli/run` export, so `zwasm run` stops at `NoRunExport` after
linking — the test in `src/api/component_tests.zig` invokes the core `f`
directly.
