- **A WASI 0.3 response's trailer section reaches the guest** (#704). The
  trailers future `consume-body` hands out always resolved `ok(none)`; it
  now resolves `ok(some(fields))` with the trailers a chunked response
  carried.
