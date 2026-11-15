- **A constant expression's value has all 16 bytes defined, so `zwasm compile`
  gives the same `.cwasm` bytes for the same module.** Above the value's own
  bytes the slot is zero, for globals, tables and element items on both engines.
  [GHSA-gj6g-62gx-5cwf](https://github.com/zwasm/zwasm/security/advisories/GHSA-gj6g-62gx-5cwf).
