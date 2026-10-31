- **The JIT declines `memory.init` on a data segment index of 2048 or more,
  and `table.init` on an element segment index of 1024 or more** (#659).
  `--engine jit` and `zwasm compile` fail with `UnsupportedOp`; the
  interpreter runs the module, so `--engine interp` is the workaround.
