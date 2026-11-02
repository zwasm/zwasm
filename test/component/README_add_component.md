# Component fixture: add_component (u32, u32 -> u32)

A component whose only export is a plain func, `add: func(a: u32, b: u32) -> u32`,
and no `wasi:cli/run`: `zwasm run` refuses it with its export list, and
`zwasm run --invoke add=2,3` prints `5` (#622).

## Reproduce

```sh
wasm-tools parse add_component.wat -o add_core.wasm
wasm-tools component embed add_component.wit add_core.wasm -o add_embedded.wasm
wasm-tools component new add_embedded.wasm -o add_component.wasm
wasm-tools validate --features component-model add_component.wasm
wasmtime run --invoke 'add(2, 3)' add_component.wasm   # prints: 5
```

(`add_core.wasm` and `add_embedded.wasm` are transient intermediates; not committed.)

## Files

- `add_component.wit`  — WIT world: `export add: func(a: u32, b: u32) -> u32;`
- `add_component.wat`  — hand-written core module
- `add_component.wasm` — final component (261 B); THE fixture
