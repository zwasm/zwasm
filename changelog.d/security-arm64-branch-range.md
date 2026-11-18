- **On arm64, the JIT declines a function when a branch or a literal load in
  it cannot reach its target, and the interpreter runs the module.** Both
  reach 1 MiB, so this is a function with more than about 1 MiB of machine
  code; `--engine jit` reports the distance and the reach. A module is also
  declined when an entry wrapper is more than a call's 128 MiB from its
  function (`DisplacementOverflow`).
  [GHSA-9v38-4fvh-wjp6](https://github.com/zwasm/zwasm/security/advisories/GHSA-9v38-4fvh-wjp6).
