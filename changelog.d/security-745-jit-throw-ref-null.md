- **`throw_ref` of a null `exnref` traps `null_reference` on the JIT, as on the
  interpreter** (#745). It raised an exception instead, which a `try_table`
  clause could catch and the run went on.
  [GHSA-wwr2-84fx-2j37](https://github.com/zwasm/zwasm/security/advisories/GHSA-wwr2-84fx-2j37).
