- **`wasm_module_imports` and `wasm_module_exports` list a memory64 memory
  whose minimum does not fit `u32`** (#670). The import list came back empty
  and `zwasm_module_imports_ex` returned `false`; the minimum now reports as
  `0xffffffff`, as a table64 bound already did, since `wasm_limits_t` is `u32`.
