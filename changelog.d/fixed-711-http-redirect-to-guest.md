- **A `wasi:http` request answered with a 3xx returns that response to the
  guest** (#711). The host followed up to three redirects itself; now the
  guest receives the 3xx with its `location` header and body, and the host
  sends no further request, as wasmtime does. Both 0.2 and 0.3.
