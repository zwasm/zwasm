# `wasi_p2_fs_meta_rust.wasm` — rust-std `fs::metadata` over WASI 0.2 metadata-hash

A real `rustc --target wasm32-wasip2` component whose only job is to exercise
the two `wasi:filesystem/types@0.2` imports rust-std cannot avoid:

| import | who calls it | what rust-std reads from it |
|---|---|---|
| `[method]descriptor.metadata-hash-at` | `stat()`, `readdir()` in wasi-libc | `st_ino` / `d_ino` |
| `[method]descriptor.metadata-hash` | `fstat()` | `st_ino` |

`fs::metadata`, `File::metadata` and `fs::read_dir` all reach one of them, so
any std-using wasip2 guest imports BOTH. A host that maps `metadata-hash` but
not `metadata-hash-at` fails at LINK time (`UnsupportedWasiImport`), before a
single guest instruction runs — which is how a "hello world" fixture can pass
while every real program fails to instantiate.

## Source

`wasi_p2_fs_meta_rust.rs`. Expects a preopen at `/work` already holding
`a.txt` (5 bytes) and `b.txt` (1 byte): the guest never writes, because
rust-std writes files through `write-via-stream`, which the 0.2 host still
stubs as unsupported. It stats `a.txt` by path and by fd, stats the
directory, asserts `NotFound` on a missing path, lists the directory, and
prints `META-OK a.txt,b.txt`.

## Build

```sh
rustc --target wasm32-wasip2 -O wasi_p2_fs_meta_rust.rs -o /tmp/meta.wasm
wasm-tools strip /tmp/meta.wasm -o wasi_p2_fs_meta_rust.wasm
wasm-tools validate --features component-model wasi_p2_fs_meta_rust.wasm
```

Built with rustc 1.97.1; the imports are `@0.2.0` / `@0.2.9` (the guest's
view), which the importname decoder strips before classification.

Asserted in `src/api/component_tests.zig` ("0.2 metadata-hash +
metadata-hash-at") and dogfooded via
`zwasm run --dir /tmp/work:/work test/component/wasi_p2_fs_meta_rust.wasm`
(with `a.txt` and `b.txt` placed in `/tmp/work` first).
