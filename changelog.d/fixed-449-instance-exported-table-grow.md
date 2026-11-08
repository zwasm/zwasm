- **A table exported by one instance and imported by another no longer grows
  on either side** (#449). Before, a grow reallocated the buffer both read and
  left the other instance reading freed memory; now `table.grow` returns `-1`
  and `wasm_table_grow` returns `false`, as for an imported `wasm_table_new`
  table. `Linker.defineTable` by value declines on the importer's side only.
