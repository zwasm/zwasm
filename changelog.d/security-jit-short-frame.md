- **On the JIT, a block whose body ends in `unreachable` before producing its
  result traps as the interpreter does** (#399). Before, in a function that
  computed nothing else, reading that result indexed an empty table and the
  process aborted, on `--engine jit` and on the default engine.
  [GHSA-pxpg-mx84-x9c9](https://github.com/zwasm/zwasm/security/advisories/GHSA-pxpg-mx84-x9c9).
