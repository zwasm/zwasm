(module
  (import "wasi_snapshot_preview1" "fd_write" (func $fw (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 17)
  (global $bump (mut i32) (i32.const 1024))
  (data (i32.const 64) "P1-OK\n")
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
    (local $p i32)
    (local.set $p (global.get $bump))
    (global.set $bump (i32.add (global.get $bump) (i32.add (local.get 3) (i32.const 8))))
    (local.get $p))
  ;; call(op, request) -> request; writes "P1-OK\n" to stdout through the
  ;; preview1 fd_write the adapter maps onto wasi:cli/stdout.
  (func (export "call") (param i32 i32 i32 i32) (result i32)
    (i32.store (i32.const 32) (i32.const 64))
    (i32.store (i32.const 36) (i32.const 6))
    (drop (call $fw (i32.const 1) (i32.const 32) (i32.const 1) (i32.const 40)))
    (i32.store (i32.const 16) (local.get 2))
    (i32.store (i32.const 20) (local.get 3))
    (i32.const 16)))
