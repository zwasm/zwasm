- **The JIT runs `memory.init`, `table.init`, `data.drop` and `elem.drop` on
  any segment index** (#659). It declined data index 2048, elem index 1024
  and, on arm64, drop index 4096, caps that only the arm64 immediate encoding
  needed, so `--engine jit` and `zwasm compile` failed with `UnsupportedOp`.
