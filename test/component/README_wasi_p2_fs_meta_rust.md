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
stubs as unsupported. It stats `a.txt` by path and by fd and asserts the two
routes report the same `st_ino` (one object, one identity: the path route
reads `metadata-hash-at`, the fd route `metadata-hash`), stats the directory,
asserts `NotFound` on a missing path, asserts that `fs::read` fails as
`ErrorKind::Unsupported` (the `read-via-stream` stub's `error-code`, as the
guest decodes it), lists the directory, and prints `META-OK a.txt,b.txt`.

## Build (gen host)

`MetadataExt::ino` is unstable on `wasm32-wasip2` (`std::os::wasi` is behind
the `wasip2` library feature, the trait behind `wasi_ext`,
rust-lang/rust#71213), so the source opts in with `#![feature(...)]` and the
stable compiler needs `RUSTC_BOOTSTRAP=1`:

```sh
nix develop .#gen --command bash -c '
  RUSTC_BOOTSTRAP=1 rustc --target wasm32-wasip2 -O wasi_p2_fs_meta_rust.rs -o /tmp/meta.wasm
  wasm-tools strip /tmp/meta.wasm -o wasi_p2_fs_meta_rust.wasm
  wasm-tools validate --features component-model wasi_p2_fs_meta_rust.wasm'
```

The committed binary was built OUTSIDE that pin, with rustup's stable rustc
1.97.1 and wasm-tools 1.240.0 (no nix on the machine that built it); the
imports are `@0.2.0` / `@0.2.9` (the guest's view), which the importname
decoder strips before classification.

Asserted in `src/api/component_tests.zig` ("0.2 metadata-hash +
metadata-hash-at") and dogfooded via
`zwasm run --dir /tmp/work:/work test/component/wasi_p2_fs_meta_rust.wasm`
(with `a.txt` and `b.txt` placed in `/tmp/work` first).
