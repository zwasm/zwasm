;; Plants "d" -> "." and then "d/e" -> "..", whose real directory is the
;; preopen root. The second symlink is notcapable: exit 140 + 76.
(module
  (import "wasi_snapshot_preview1" "path_symlink" (func $symlink (param i32 i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open" (func $open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_read" (func $read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 0) ".")
  (data (i32.const 4) "d")
  (data (i32.const 8) "..")
  (data (i32.const 12) "d/e")
  (data (i32.const 16) "d/e/outside.txt")
  (func (export "_start")
    (local $e i32)
    ;; d -> "." : d is the preopen root itself
    (local.set $e (call $symlink (i32.const 0) (i32.const 1) (i32.const 3) (i32.const 4) (i32.const 1)))
    (if (local.get $e) (then (call $exit (i32.add (i32.const 100) (local.get $e)))))
    ;; d/e -> ".." : lexically one level under d, really one level above the root
    (local.set $e (call $symlink (i32.const 8) (i32.const 2) (i32.const 3) (i32.const 12) (i32.const 3)))
    (if (local.get $e) (then (call $exit (i32.add (i32.const 140) (local.get $e)))))
    ;; open d/e/outside.txt : no ".." in the guest path
    (local.set $e (call $open (i32.const 3) (i32.const 1) (i32.const 16) (i32.const 15) (i32.const 0)
                     (i64.const 0x1FFFFFFF) (i64.const 0x1FFFFFFF) (i32.const 0) (i32.const 64)))
    (if (local.get $e) (then (call $exit (local.get $e))))
    (i32.store (i32.const 72) (i32.const 128))
    (i32.store (i32.const 76) (i32.const 64))
    (local.set $e (call $read (i32.load (i32.const 64)) (i32.const 72) (i32.const 1) (i32.const 80)))
    (if (local.get $e) (then (call $exit (i32.add (i32.const 180) (local.get $e)))))
    (i32.store (i32.const 88) (i32.const 128))
    (i32.store (i32.const 92) (i32.load (i32.const 80)))
    (drop (call $write (i32.const 1) (i32.const 88) (i32.const 1) (i32.const 96)))
    (call $exit (i32.const 0))))
