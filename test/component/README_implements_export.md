# Component Model fixture: implements_export (`implements` name attribute, #612)

A component that exports an interface under a plain name, `export cache: store;`.
`wasm-tools` encodes the name as `0x02 "cache" vec(attribute)` with one
`(implements "local:demo/store")` attribute, the form WASI 0.3.1 adopted.

## Reproduce

```sh
wasm-tools component embed --dummy implements_export.wit -o implements_export_embedded.wasm
wasm-tools component new implements_export_embedded.wasm -o implements_export_component.wasm
wasm-tools validate implements_export_component.wasm
```

`wasm-tools` 1.262.0; the `--dummy` core comes from `embed`, so there is no `.wat`.
`implements_export_embedded.wasm` is not committed.

## Files

- `implements_export.wit` — the world
- `implements_export_component.wasm` — the fixture
