- **The validator checks the reference operand of `throw_ref`, `ref.test`,
  `ref.cast`, `array.len`, `br_on_cast` and `i31.get` against its spec type**
  (#322): `exnref`, the cast target's hierarchy, `arrayref`, `rt1` and
  `i31ref`. A module whose operand is outside it is rejected.
  [GHSA-fv27-pjx7-p4m3](https://github.com/zwasm/zwasm/security/advisories/GHSA-fv27-pjx7-p4m3).
