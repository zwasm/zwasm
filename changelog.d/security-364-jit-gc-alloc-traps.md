- **On the JIT, a GC allocation that fails now traps `out_of_memory`** (#364).
  `array.new`, `array.new_default`, `array.new_fixed`, `struct.new` and
  `struct.new_default` checked the result on the interpreter but not the JIT,
  where a failed allocation (the GC heap's 4 GiB cap) returned a null reference.
  The JIT now traps there, and declines a v128-element `array.new`.
  [GHSA-pjxf-4q9v-jpwq](https://github.com/zwasm/zwasm/security/advisories/GHSA-pjxf-4q9v-jpwq).
