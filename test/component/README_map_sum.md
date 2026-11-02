# Component Model fixture: map_sum (`map<string, u32>` param, #611)

A component whose exported interface takes a `map<K, V>`, the type WASI 0.3.1
adopted. The canonical ABI lowers it as `list<tuple<string, u32>>`; the core
walks that list and returns the sum of the values.

## Reproduce

```sh
wasm-tools parse map_sum_core.wat -o map_sum_core.wasm
wasm-tools component embed map_sum.wit map_sum_core.wasm -o map_sum_embedded.wasm
wasm-tools component new map_sum_embedded.wasm -o map_sum_component.wasm
wasm-tools validate map_sum_component.wasm
```

`wasm-tools` 1.262.0; `map_sum_embedded.wasm` is not committed.

## Files

- `map_sum.wit` — `interface m { f: func(x: map<string, u32>) -> u32; }`, exported
- `map_sum_core.wat` — hand-written core: a bump `cabi_realloc` and `test:m/m#f`,
  which reads 12-byte elements (key ptr, key len, value; align 4)
- `map_sum_core.wasm` — assembled core module
- `map_sum_component.wasm` — the fixture
