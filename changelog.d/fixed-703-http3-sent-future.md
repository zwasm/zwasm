- **A WASI 0.3 request's `sent` future resolves, so a guest that awaits it
  no longer deadlocks** (#703). The host minted it and never wrote it; now
  it resolves with the send's outcome (`ok`, or the `error-code`
  `client.send` returned), and `ok` when the request is dropped unsent, as
  wasmtime does.
