- **On the JIT, a function that throws a tag with more than 16 parameters is
  declined to the interpreter**, which traps `unreachable` on such a throw
  rather than catching it (#781). Before, compiling the `throw` aborted the
  process, on x86_64 and arm64, on `--engine jit`, the default engine and the
  C API.
