- **On the JIT, the values an edge delivers to a merge are moved as one
  parallel assignment**, on x86_64 and arm64: at the end of a block or of an
  `if` arm, and on a branch to a block, an `if` or a loop. Each edge delivers
  its own values when they sit where another edge's values go.
  [GHSA-4wxj-2fwr-xxwq](https://github.com/zwasm/zwasm/security/advisories/GHSA-4wxj-2fwr-xxwq).
