- **`zwasm run` on a component with a sync `wasi:cli/run` next to an async
  export runs `run`** (#677). It ran the first async-lifted export instead. The
  entry is `wasi:cli/run#run` by name, the highest generation first, else a
  top-level `run` typed `func()` or `func() -> result`, each driven sync or
  async as it is lifted.
