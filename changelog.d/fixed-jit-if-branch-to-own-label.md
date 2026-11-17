- **On the JIT, an `if` with no else whose then arm branches to the `if`'s
  own label gives its params when the condition is zero.** An `if` with no
  else behaves as one whose else arm is empty, so its params are its results,
  and a branch to its label carries the results. The JIT compiles the shape
  to that rule and gives what the interpreter gives.
