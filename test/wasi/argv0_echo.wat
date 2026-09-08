;; Guest for `zig build test-cli-argv0` (#256): reads argv (args_sizes_get +
;; args_get) and writes argv[0] MINUS its trailing NUL to stdout. The CLI is
;; expected to hand a guest the wasm file's base name, whatever path it was
;; given, so stdout = "argv0_echo.wasm" — the in-process fixture runner passes
;; the base name itself, hence the same `.expected_stdout`. Built with
;; `wasm-tools parse`; the committed .wasm is this text.
(module
  (import "wasi_snapshot_preview1" "args_sizes_get"
    (func $args_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "args_get"
    (func $args_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  ;; argc@0, bufsize@4 ; ciovec@8 ; nwritten@16 ; argv ptrs@64 ; argv buf@128
  (func $main (local $len i32)
    (drop (call $args_sizes_get (i32.const 0) (i32.const 4)))
    (drop (call $args_get (i32.const 64) (i32.const 128)))
    (loop $scan                                                     ;; len = strlen(argv[0])
      (if (i32.load8_u (i32.add (i32.load (i32.const 64)) (local.get $len)))
        (then
          (local.set $len (i32.add (local.get $len) (i32.const 1)))
          (br $scan))))
    (i32.store (i32.const 8) (i32.load (i32.const 64)))             ;; ciovec.buf = argv[0]
    (i32.store (i32.const 12) (local.get $len))                     ;; ciovec.len
    (drop (call $fd_write (i32.const 1) (i32.const 8) (i32.const 1) (i32.const 16))))
  (export "_start" (func $main)))
