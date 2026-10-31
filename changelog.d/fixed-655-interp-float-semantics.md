- **On the interpreter, `nearest` rounds ties to even and quiets a signalling
  NaN, and `min` / `max` return `-0` / `+0` for a pair of zeros** (#655). They
  rounded ties away from zero, could return the signalling NaN, and took the
  zero's sign from operand order. The Wasm 2.0 value-assert corpus now also
  runs on the interpreter in `test-all`.
