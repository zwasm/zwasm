# `wasi_p2_path_beneath_rust.wasm` — a WASI 0.2 path that leaves its preopen through a symlink is refused

Source `wasi_p2_path_beneath_rust.rs`. The guest creates the symlink
`up -> .` in its preopen (`symlink-at`, allowed: the target stays inside),
then reads `up/../outside.txt` (`open-at`). Resolved one component at a time,
`up` is the preopen root and `..` from it leaves the preopen, so `open-at` is
`err(not-permitted)` and the guest exits 20 with nothing on stdout.

Asserted in `src/api/component_tests.zig` ("0.2 open-at: a path whose symlink
leads above the preopen is refused"), with `outside.txt` in the preopen's
parent directory.

## Build

```sh
rustc --target wasm32-wasip2 -O wasi_p2_path_beneath_rust.rs -o /tmp/pb.wasm
wasm-tools strip /tmp/pb.wasm -o wasi_p2_path_beneath_rust.wasm
wasm-tools validate --features component-model wasi_p2_path_beneath_rust.wasm
```

Built with rustup's stable rustc 1.100.0 and wasm-tools 1.262.0.
