- **On the x86_64 JIT, a call's arguments, the frame reserved for them and the
  return buffer of a callee with three or more results follow one rule**.
  Before, a call passing a `v128` with more arguments than fit in registers could
  make it overlap a slot of the caller's frame (Linux) or another argument
  (Windows): bits the guest chose became an address or a reference, or a wrong
  value came back, on `--engine jit`, the default engine, the C API and a `.cwasm`.
