- **On the JIT, every path that reaches the end of an `if` delivers its own
  values to it**, when an arm ends in a terminator, when a `br_if` targets the
  `if`, and when the `if` has no else (#739). Before, a then-arm short of its
  results took its value from below the `if`, with no trap.
  [GHSA-grpg-98rp-93g7](https://github.com/zwasm/zwasm/security/advisories/GHSA-grpg-98rp-93g7).
