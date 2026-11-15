# http_service_await_sent.wat — a 0.3 handler that awaits its response's future

A hand-written `wasi:http/handler@0.3.0` service (#734). `handle` drops the
request, builds a response whose body is `hello` through `response.new`,
delivers it with `task.return`, and then reads the future `response.new`
returned. It exits once that future resolves `ok`, and traps on `err`.

The body write parks until the host takes the body in; the handler then closes
the stream. So the handler can only exit if the host resolves the future inside
the drive, after it has the whole body. Before #734 nothing resolved it, and
`serviceHandle` failed with `AsyncDeadlock`.

Two tests serve it: "serviceHandle: a handler that awaits the future
response.new returned completes, …" in `src/api/component_wasi_p3.zig`, and
`zig build test-cli-serve` (`test/runners/serve_runner.zig`), which sends it
two requests over HTTP through `zwasm serve`.

## Build

The instance type of `wasi:http/types` is the part of the one
`wasi-testsuite`'s `http-service-echo.wasm` declares that this guest uses.

```sh
wasm-tools parse http_service_await_sent.wat -o http_service_await_sent.wasm
wasm-tools validate --features all http_service_await_sent.wasm
```

Built with `wasm-tools` 1.262.0.
