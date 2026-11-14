- **A `wasi:http` response with a `content-encoding` std's HTTP client does not
  decode no longer stops the call** (#738). A zstd or compress response failed
  only after the peer closed the connection; it now reaches the guest undecoded.
  A br response fails at once with `HTTP-response-content-coding`, and any head
  the client cannot parse closes the connection rather than waiting on it.
