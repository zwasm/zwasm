- **A `try_table` catch clause whose label is the function's own label returns
  the delivered values — the tag's payload, and the exnref for a `_ref` clause —
  as the function's results, on the interpreter and on both JIT architectures.**
  Earlier neither engine reached the function's return path for it.
