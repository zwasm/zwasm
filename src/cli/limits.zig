//! The CLI's file-size cap (#530). `compile` reads a `.wasm` and writes a
//! `.cwasm`, `run` reads either, and the cache stores what `run` reads
//! back — one bound for all of them keeps every file one of them writes
//! readable by the others.
//!
//! Zone 3 (`src/cli/`).

/// Largest `.wasm` / `.cwasm` the CLI reads, writes, or caches, in bytes.
pub const max_file_bytes: usize = 256 << 20;
