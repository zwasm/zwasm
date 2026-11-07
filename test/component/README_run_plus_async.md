# Component fixture: run_plus_async (sync `wasi:cli/run` + async `tick`)

A component exporting a sync `wasi:cli/run@0.2.0` whose `run` returns `ok`,
next to an unrelated async export `tick` that traps. `zwasm run` runs `run`
and exits 0 with nothing on stderr; it ran `tick` before #677.

## Reproduce

```sh
wasm-tools parse run_plus_async.wat -o run_plus_async.wasm   # wasm-tools >= 1.262 (CM-async)
wasm-tools validate --features all run_plus_async.wasm
wasmtime run -W component-model-async=y run_plus_async.wasm  # exit 0
```

## Files

- `run_plus_async.wat`  — hand-written component
- `run_plus_async.wasm` — assembled component (275 B); THE fixture
