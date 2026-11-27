- **On the JIT, `array.new` and `array.fill` of an `f32` or `f64` element now
  decline to the interpreter.** Before, they filled each element from a general
  register an `f32` / `f64` value does not occupy, so the elements could hold
  other bits. The decline moves the whole module: one that also holds a SIMD
  instruction no longer instantiates, nor does one that imports, through the C
  API, from an instance running on the JIT. `zwasm compile` refuses a function
  that uses them.
