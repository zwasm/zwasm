- **On the JIT, an `if` whose then-arm ends in a terminator such as
  `unreachable` returns the else arm's value** (#739). Before, when the
  then-arm left fewer values than the `if` returns, the JIT took the result
  from below the `if`, so the else arm or the implicit else returned a wrong
  value with no trap. The interpreter was not affected.
  [GHSA-grpg-98rp-93g7](https://github.com/zwasm/zwasm/security/advisories/GHSA-grpg-98rp-93g7).
