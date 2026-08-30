;; Guest for `zig build test-cli-stdin` (#257): reads fd 0 until EOF, echoes
;; every chunk to stdout, and exits with the total byte count — or 100 + errno
;; if any read fails, so an EOF reported as an error is visible as the exit
;; status. Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (import "wasi_snapshot_preview1" "fd_read" (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  ;; iov at 0: buf=64 len=32 ; nread at 16 ; nwritten at 20 ; total in local 0
  (func (export "_start") (local $total i32) (local $err i32)
    (loop $again
      (i32.store (i32.const 0) (i32.const 64))
      (i32.store (i32.const 4) (i32.const 32))
      (local.set $err (call $fd_read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 16)))
      (if (local.get $err) (then (call $proc_exit (i32.add (i32.const 100) (local.get $err)))))
      (if (i32.load (i32.const 16))
        (then
          (i32.store (i32.const 4) (i32.load (i32.const 16)))
          (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 20)))
          (local.set $total (i32.add (local.get $total) (i32.load (i32.const 16))))
          (br $again))))
    (call $proc_exit (local.get $total))))
