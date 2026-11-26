- **On the JIT, `array.new` and `array.fill` of an `f32` or `f64` element now
  decline to the interpreter.** Before, the JIT filled each element from a
  general register, which an `f32` / `f64` value does not occupy, so the
  elements could hold other bits. The default engine and the C API now fill them
  on the interpreter; the explicit JIT reports the decline, and `zwasm compile`
  refuses such a module.
