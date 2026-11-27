- **On the arm64 JIT, a function whose `i32` or `f32` parameter arrives on the
  stack more than 16 KiB above the frame is declined to the interpreter.**
  Before, the load of that parameter did not fit its encoding and the process
  aborted when the module was instantiated, on `--engine jit` and on the
  default engine. x86_64 was not affected.
