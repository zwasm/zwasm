- **A component using the Component Model features WASI 0.3.1 adopted decodes
  and runs** (#611, #612). A `map<K, V>` type is accepted, its key and value
  validated as the spec says, and crosses the canonical ABI as
  `list<tuple<K, V>>`; the `implements` / `version-suffix` / `external-id`
  attributes on an import or export name are read and ignored, as type checking
  ignores them.
