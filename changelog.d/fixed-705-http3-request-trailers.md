- **A WASI 0.3 request sends the trailers its future resolves to** (#705).
  The host dropped the request's trailers future at `client.send`, so the
  guest's write never completed and the instance deadlocked. Now
  `ok(some)` sends the body chunked with that trailer section, and `err`
  aborts the request: `client.send` returns the guest's error.
