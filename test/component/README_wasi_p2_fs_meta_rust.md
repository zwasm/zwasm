# `wasi_p2_fs_meta_rust.wasm` — rust-std `fs::metadata` / `fs::read` / `fs::write` over WASI 0.2

A real `rustc --target wasm32-wasip2` component that exercises the
`wasi:filesystem/types@0.2` imports rust-std cannot avoid. Two carry identity:

| import | who calls it | what rust-std reads from it |
|---|---|---|
| `[method]descriptor.metadata-hash-at` | `stat()`, `readdir()` in wasi-libc | `st_ino` / `d_ino` |
| `[method]descriptor.metadata-hash` | `fstat()` | `st_ino` |

`fs::metadata`, `File::metadata` and `fs::read_dir` all reach one of them, so
any std-using wasip2 guest imports BOTH. A host that maps `metadata-hash` but
not `metadata-hash-at` fails at LINK time (`UnsupportedWasiImport`), before a
single guest instruction runs — which is how a "hello world" fixture can pass
while every real program fails to instantiate.

File contents move through the via-stream trio: `fs::read` through
`[method]descriptor.read-via-stream`, `fs::write` through `write-via-stream`,
and a write on an `OpenOptions::append` file through `append-via-stream`.

## Source

`wasi_p2_fs_meta_rust.rs`. Expects a preopen at `/work` already holding
`a.txt` (`hello`) and `b.txt` (1 byte). It stats `a.txt` by path and by fd,
stats the directory, asserts `NotFound` on a missing path, reads `a.txt`,
writes `c.txt` and reads it back, appends to it and reads `written+more` back,
lists the directory, and prints `META-OK a.txt,b.txt,c.txt`.

That the two routes give one object one identity is pinned by the hand-written
`wasi_p2_fs_meta.wat`, which calls `metadata-hash` on an fd and
`metadata-hash-at` on the same file by path and compares the two 16-byte
values (and asserts a second file hashes differently, and a missing path is
`err(no-entry)`). It needs only `wasm-tools parse`.

## Build (gen host)

Plain stable rustc, no feature gates:

```sh
nix develop .#gen --command bash -c '
  rustc --target wasm32-wasip2 -O wasi_p2_fs_meta_rust.rs -o /tmp/meta.wasm
  wasm-tools strip /tmp/meta.wasm -o wasi_p2_fs_meta_rust.wasm
  wasm-tools validate --features component-model wasi_p2_fs_meta_rust.wasm
  wasm-tools parse wasi_p2_fs_meta.wat -o wasi_p2_fs_meta.wasm
  wasm-tools validate --features component-model wasi_p2_fs_meta.wasm'
```

The committed binaries were built OUTSIDE that pin, with rustup's stable
rustc 1.98.1 (the Rust guest stripped with wasm-tools 1.237.0, the `.wat`
parsed with 1.259.0); the Rust guest's imports are `@0.2.0` /
`@0.2.9` (the guest's view), which the importname decoder strips before
classification.

Asserted in `src/api/component_tests.zig` ("0.2 metadata-hash +
via-stream") and dogfooded via
`zwasm run --dir /tmp/work:/work test/component/wasi_p2_fs_meta_rust.wasm`
(with `a.txt` and `b.txt` placed in `/tmp/work` first; the run leaves
`c.txt` there).
