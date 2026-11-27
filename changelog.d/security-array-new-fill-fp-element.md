- **On the JIT, `array.new` and `array.fill` of an `f32` or `f64` element now
  write the value they are given.** Before, the JIT filled each element from a
  general register, which an `f32` / `f64` value — held in a floating-point
  register — never reaches, so the elements held other bits. This was reachable
  through `--engine jit`, the default engine, and the C API; the interpreter was
  unaffected.
