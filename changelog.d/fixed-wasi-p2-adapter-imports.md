- **A component built with the preview1 adapter (Go, TinyGo, C) links and
  runs** (#634). It failed with `UnknownImport`: the adapter's `env::memory`
  and three WASI 0.2 rows it imports (`filesystem-error-code`, the 0.2 clock
  `resolution`s) were not served.
