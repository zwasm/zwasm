// Real rust-std wasm32-wasip2 fixture for the path/fd metadata-hash pair.
// wasi-libc's stat()/fstat()/readdir() fill st_ino / d_ino from
// `[method]descriptor.metadata-hash-at` / `metadata-hash`, so every one of
// `fs::metadata`, `File::metadata` and `fs::read_dir` imports them.
// Expects a preopen at /work holding a.txt (5 bytes) and b.txt (1 byte),
// created by the host: the guest never writes, because rust-std writes files
// through `write-via-stream`, which the 0.2 host does not provide. Its one
// read (`read-via-stream`, also a stub) must fail as `Unsupported`. Prints
// META-OK <sorted entries>.

// `MetadataExt::ino` is unstable twice over on this target: `std::os::wasi`
// sits behind `wasip2`, and the trait behind `wasi_ext` (rust-lang/rust#71213).
// Build with RUSTC_BOOTSTRAP=1 on the stable toolchain (see the README).
#![feature(wasip2, wasi_ext)]

use std::fs;
use std::os::wasi::fs::MetadataExt;

fn main() {
    let by_path = fs::metadata("/work/a.txt").expect("fs::metadata (stat-at + metadata-hash-at)");
    assert_eq!(by_path.len(), 5);
    assert!(by_path.is_file());

    let file = fs::File::open("/work/a.txt").expect("open a.txt");
    let by_fd = file.metadata().expect("File::metadata (stat + metadata-hash)");
    assert_eq!(by_fd.len(), 5);
    // One object, one identity: st_ino comes from metadata-hash-at on the
    // path route and from metadata-hash on the fd route.
    assert_eq!(by_path.ino(), by_fd.ino());

    let dir = fs::metadata("/work").expect("fs::metadata on the preopen");
    assert!(dir.is_dir());

    let missing = fs::metadata("/work/nope").expect_err("missing path must be an error");
    assert_eq!(missing.kind(), std::io::ErrorKind::NotFound);

    // Reading contents goes through `read-via-stream`, which the 0.2 host
    // stubs as err(unsupported); the guest must see exactly that kind.
    let unread = fs::read("/work/a.txt").expect_err("read-via-stream is a stub");
    assert_eq!(unread.kind(), std::io::ErrorKind::Unsupported);

    let mut names: Vec<String> = fs::read_dir("/work")
        .expect("read_dir")
        .map(|e| e.expect("dir entry").file_name().into_string().expect("utf8 name"))
        .collect();
    names.sort();
    println!("META-OK {}", names.join(","));
}
