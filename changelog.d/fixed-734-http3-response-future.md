- **A `wasi:http` 0.3 handler that awaits the future `response.new` returns
  completes** (#734). Nothing resolved it, so the handler failed with
  `AsyncDeadlock` and `zwasm serve` answered 500. It now resolves `ok` once the
  host has the whole response or the response is dropped, and with what the
  guest writes to `res` when the guest passes its own response to `consume-body`.
