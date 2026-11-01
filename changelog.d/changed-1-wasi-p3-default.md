- **zwasm runs WASI 0.3 async components by default** (#673). `zwasm run` on a
  `wasm32-wasip3` component no longer needs a `-Dwasi=p3` build (2.9 exited 1).
  `-Dwasi=p2` is the opt-out; `zig build test-wasi-p3` is now `test-wasi-p2`,
  its unit suite. The ReleaseSafe binary grows 0.68 MB stripped on x86_64
  Linux, mostly the HTTP/TLS client the 0.3 outgoing handler reaches.
