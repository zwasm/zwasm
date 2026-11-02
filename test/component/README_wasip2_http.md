# `wasip2_http/http-get.wasm` — a `wasi:http@0.2.12` client guest

A `wasm32-wasip2` component built with the `wasip2` 1.0.4 crate, the binding
current Rust toolchains use, so its imports are the `@0.2.12` generation the
issue reported (#564). `wasm-tools component wit` prints:

```
import wasi:cli/environment@0.2.12;
import wasi:cli/exit@0.2.12;
import wasi:io/error@0.2.12;
import wasi:io/poll@0.2.12;
import wasi:io/streams@0.2.12;
import wasi:cli/stdin@0.2.12;
import wasi:cli/stdout@0.2.12;
import wasi:cli/stderr@0.2.12;
import wasi:cli/terminal-input@0.2.12;
import wasi:cli/terminal-output@0.2.12;
import wasi:cli/terminal-stdin@0.2.12;
import wasi:cli/terminal-stdout@0.2.12;
import wasi:cli/terminal-stderr@0.2.12;
import wasi:clocks/monotonic-clock@0.2.12;
import wasi:http/types@0.2.12;
import wasi:http/outgoing-handler@0.2.12;
```

## Source

`wasip2_http/src/bin/http-get.rs`. `HTTP_ENDPOINT` is `host:port`; `argv[1]`
picks the check and the guest prints one line per observation:

| mode | what it does |
|---|---|
| `get` (default) | `GET /`, prints status, body and trailers |
| `post` | `POST /` with body `ping` through `outgoing-body.write` + `finish` |
| `get-body` / `delete-body` | the same body on `GET` / `DELETE` |
| `https` | `GET` with scheme `https`, which `handle` refuses |
| `twice` | `get`, then a second `future-incoming-response.get` |
| `unfinished` | takes the request body and sends without `finish` |
| `live-in` / `live-out` | `finish` on a body whose stream child is still live (WIT: traps) |
| `abandon` | uploads and a response dropped before they are used |
| `fields` | `fields` errors (`set` / `append` / `delete` / `from-list`) and an immutable child |

## Build

```sh
cd test/component/wasip2_http
cargo build --release --target wasm32-wasip2
wasm-tools strip target/wasm32-wasip2/release/http-get.wasm -o http-get.wasm
wasm-tools validate --features component-model http-get.wasm
```

The committed binary was built with rustup's stable rustc 1.99.1 and
wasm-tools 1.262.0, outside the `flake.nix` pin.

Asserted in `src/api/component_wasi_p2_http.zig` against the test echo
endpoint (`src/api/component_http_echo.zig`).
