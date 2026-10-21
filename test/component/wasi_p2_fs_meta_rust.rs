// Real rust-std wasm32-wasip2 fixture for the path/fd metadata-hash pair and
// the descriptor via-stream trio. wasi-libc's stat()/fstat()/readdir() fill
// st_ino / d_ino from `[method]descriptor.metadata-hash-at` /
// `metadata-hash`, so every one of `fs::metadata`, `File::metadata` and
// `fs::read_dir` imports them; file contents move through
// `read-via-stream`, `write-via-stream` and (an O_APPEND fd)
// `append-via-stream`.
// Expects a preopen at /work holding a.txt (5 bytes) and b.txt (1 byte),
// created by the host. Writes c.txt itself. Prints META-OK <sorted entries>.
// That the two hash routes agree on one object is pinned by
// wasi_p2_fs_meta.wat, which compares the hashes directly.

use std::fs;
use std::io::Write;

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

    assert_eq!(fs::read("/work/a.txt").expect("fs::read (read-via-stream)"), b"hello");

    fs::write("/work/c.txt", b"written").expect("fs::write (write-via-stream)");
    assert_eq!(fs::read("/work/c.txt").expect("read c.txt back"), b"written");

    let mut log = fs::OpenOptions::new().append(true).open("/work/c.txt").expect("open c.txt to append");
    log.write_all(b"+more").expect("append (append-via-stream)");
    drop(log);
    assert_eq!(fs::read("/work/c.txt").expect("re-read c.txt"), b"written+more");

    let mut names: Vec<String> = fs::read_dir("/work")
        .expect("read_dir")
        .map(|e| e.expect("dir entry").file_name().into_string().expect("utf8 name"))
        .collect();
    names.sort();
    println!("META-OK {}", names.join(","));
}
