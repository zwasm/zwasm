- **The validator types each operand of a GC constructor in a constant
  expression, and each element segment item, against the type its position
  requires** (#430, #285). A module whose operand or item does not fit, as
  the spec's constant-expression typing and `check_elem` require, is rejected.
  [GHSA-rg2g-8x8j-3pm9](https://github.com/zwasm/zwasm/security/advisories/GHSA-rg2g-8x8j-3pm9).
