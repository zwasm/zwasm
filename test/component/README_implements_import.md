# Component Model fixture: implements_import (`implements` name attribute, #612)

A component that imports an interface under a plain name, `import cache: store;`.
`wasm-tools` encodes the name as `0x02 "cache" vec(attribute)` with one
`(implements "local:demo/store")` attribute, the form WASI 0.3.1 adopted.

## Reproduce

```sh
wasm-tools component embed --dummy implements_import.wit -o implements_import_embedded.wasm
wasm-tools component new implements_import_embedded.wasm -o implements_import_component.wasm
wasm-tools validate implements_import_component.wasm
```

`wasm-tools` 1.262.0; the `--dummy` core comes from `embed`, so there is no `.wat`.
`implements_import_embedded.wasm` is not committed.

## Files

- `implements_import.wit` — the world
- `implements_import_component.wasm` — the fixture
