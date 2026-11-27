- **On the JIT, `array.new` and `array.fill` of an `f32` or `f64` element
  decline to the interpreter** (#780). Before, the elements could hold other
  bits than the value. The decline takes the whole module, so one that also has
  SIMD in a function body, or imports through the C API from an instance on the
  JIT, no longer instantiates. `zwasm compile` refuses a function using them.
