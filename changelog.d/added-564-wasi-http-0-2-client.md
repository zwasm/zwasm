- **A `wasm32-wasip2` guest that makes HTTP requests runs** (#564). The
  `wasi:http/types@0.2.x` client resources and `outgoing-handler.handle` are
  served behind `--allow-network` (2.9 refused the component with
  `UnsupportedWasiImport`). Only the `http` scheme is sent; the server half
  (`incoming-handler`) is not served.
