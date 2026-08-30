;; (issue #257) Stdin-echo WASI fixture: fd_read up to 32 bytes from
;; fd 0, fd_write exactly those bytes to fd 1, then proc_exit(nread).
;; The exit code IS the byte count, so a host that never hands the
;; guest its stdin shows up as exit 0 + empty stdout.
;;
;; Compile via:  wasm-tools parse test/wasi/stdin_echo.wat -o test/wasi/stdin_echo.wasm
;;
;; Layout:
;;   linear memory[0..8]   = wasi_iovec { buf: u32 = 64, buf_len: u32 }
;;   linear memory[16..20] = nread_out (u32)
;;   linear memory[20..24] = nwritten_out (u32)
;;   linear memory[64..96] = read buffer
;;
;; Under `zig build test-wasi-p1` (in-process, no stdin source) the guest
;; sees EOF: `.expected_exit` = 0. `test-cli-stdin` pipes bytes through
;; the real CLI and checks the echo.
(module
  (import "wasi_snapshot_preview1" "fd_read" (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (func (export "_start")
    (i32.store (i32.const 0) (i32.const 64))
    (i32.store (i32.const 4) (i32.const 32))
    (drop (call $fd_read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 16)))
    (i32.store (i32.const 4) (i32.load (i32.const 16)))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 20)))
    (call $proc_exit (i32.load (i32.const 16)))))
