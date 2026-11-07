# Component fixtures: run_void and run_with_param (top-level `run` shapes)

A top-level func export `run` stands in for `wasi:cli/run`'s `run`, so
`zwasm run` takes it as the entry only as `func()` or `func() -> result`
(#677, ADR-0230).

- `run_void` — `run: func()`; `zwasm run` exits 0.
- `run_with_param` — `run: func(x: u32) -> u32`; `zwasm run` refuses it with
  the exports listed, and `zwasm run --invoke run=7` prints `7`.

## Reproduce

```sh
wasm-tools parse run_void.wat -o run_void.wasm
wasm-tools parse run_with_param.wat -o run_with_param.wasm
wasm-tools validate --features all run_void.wasm
wasm-tools validate --features all run_with_param.wasm
```

## Files

- `run_void.wat` / `run_void.wasm` (130 B)
- `run_with_param.wat` / `run_with_param.wasm` (137 B)
