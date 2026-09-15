// Real rust-std wasm32-wasip2 fixture for the path/fd metadata-hash pair.
// wasi-libc's stat()/fstat()/readdir() fill st_ino / d_ino from
// `[method]descriptor.metadata-hash-at` / `metadata-hash`, so every one of
// `fs::metadata`, `File::metadata` and `fs::read_dir` imports them.
// Expects a preopen at /work holding a.txt (5 bytes) and b.txt (1 byte),
// created by the host: the guest never writes, because rust-std writes files
// through `write-via-stream`, which the 0.2 host does not provide. Prints
// META-OK <sorted entries>.
use std::fs;

fn main() {
    let by_path = fs::metadata("/work/a.txt").expect("fs::metadata (stat-at + metadata-hash-at)");
    assert_eq!(by_path.len(), 5);
    assert!(by_path.is_file());

    let file = fs::File::open("/work/a.txt").expect("open a.txt");
    let by_fd = file.metadata().expect("File::metadata (stat + metadata-hash)");
    assert_eq!(by_fd.len(), 5);

    let dir = fs::metadata("/work").expect("fs::metadata on the preopen");
    assert!(dir.is_dir());

    let missing = fs::metadata("/work/nope").expect_err("missing path must be an error");
    assert_eq!(missing.kind(), std::io::ErrorKind::NotFound);

    let mut names: Vec<String> = fs::read_dir("/work")
        .expect("read_dir")
        .map(|e| e.expect("dir entry").file_name().into_string().expect("utf8 name"))
        .collect();
    names.sort();
    println!("META-OK {}", names.join(","));
}
