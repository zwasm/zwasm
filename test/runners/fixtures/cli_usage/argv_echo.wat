;; #232 — writes argv[1..] to stdout, one per line, so `test-cli-usage` sees
;; the tokens after the module path reach the guest. Built with `wasm-tools
;; parse`; the committed .wasm is this text.
(module
  (import "wasi_snapshot_preview1" "args_sizes_get"
    (func $args_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "args_get"
    (func $args_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  ;; argc@0, bufsize@4 ; ciovec[2]@8 ; nwritten@24 ; "\n"@32 ; argv ptrs@64 ; argv buf@1024
  (data (i32.const 32) "\n")
  (func $main (local $i i32) (local $arg i32) (local $len i32)
    (drop (call $args_sizes_get (i32.const 0) (i32.const 4)))
    (drop (call $args_get (i32.const 64) (i32.const 1024)))
    (i32.store (i32.const 16) (i32.const 32))                       ;; ciovec[1] = "\n"
    (i32.store (i32.const 20) (i32.const 1))
    (local.set $i (i32.const 1))
    (block $done
      (loop $each
        (br_if $done (i32.ge_u (local.get $i) (i32.load (i32.const 0))))
        (local.set $arg (i32.load (i32.add (i32.const 64) (i32.shl (local.get $i) (i32.const 2)))))
        (local.set $len (i32.const 0))
        (loop $scan                                                 ;; len = strlen(argv[i])
          (if (i32.load8_u (i32.add (local.get $arg) (local.get $len)))
            (then
              (local.set $len (i32.add (local.get $len) (i32.const 1)))
              (br $scan))))
        (i32.store (i32.const 8) (local.get $arg))                  ;; ciovec[0] = argv[i]
        (i32.store (i32.const 12) (local.get $len))
        (drop (call $fd_write (i32.const 1) (i32.const 8) (i32.const 2) (i32.const 24)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $each))))
  (export "_start" (func $main)))
