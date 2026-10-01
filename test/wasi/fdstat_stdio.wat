;; Guest for `zig build test-cli-stdin` and the `test/wasi` fixture walk (#494):
;; asks `fd_fdstat_get` what fds 0 and 1 are and prints the two filetype bytes
;; as ASCII digits on stdout ("00" = neither is a tty, "22" = both character
;; devices), or exits 100 + errno. Built with `wasm-tools parse` from this text.
(module
  (import "wasi_snapshot_preview1" "fd_fdstat_get" (func $fd_fdstat_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  ;; iov at 0: buf=8 len=2 ; digits at 8 ; nwritten at 16 ; fdstat of fd 0 at 32, of fd 1 at 64
  (func (export "_start") (local $err i32)
    (local.set $err (call $fd_fdstat_get (i32.const 0) (i32.const 32)))
    (if (local.get $err) (then (call $proc_exit (i32.add (i32.const 100) (local.get $err)))))
    (local.set $err (call $fd_fdstat_get (i32.const 1) (i32.const 64)))
    (if (local.get $err) (then (call $proc_exit (i32.add (i32.const 100) (local.get $err)))))
    (i32.store8 (i32.const 8) (i32.add (i32.const 48) (i32.load8_u (i32.const 32))))
    (i32.store8 (i32.const 9) (i32.add (i32.const 48) (i32.load8_u (i32.const 64))))
    (i32.store (i32.const 0) (i32.const 8))
    (i32.store (i32.const 4) (i32.const 2))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 16)))
    (call $proc_exit (i32.const 0))))
