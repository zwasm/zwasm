;; A `canon lower` whose `(realloc ...)` names a DIFFERENT core func than the
;; component's `cabi_realloc`: the shape the wasi_snapshot_preview1 adapter
;; produces (its lowers name `cabi_import_realloc`, which hands back the
;; buffer the preview1 caller supplied; the main module exports
;; `cabi_realloc`). The host must allocate a lowered list result through the
;; lower's own realloc. run() calls get-random-bytes(16) and exit(0) iff the
;; returned list pointer is 4096 (what `cabi_import_realloc` returns), else
;; exit(1) (1024 is where `cabi_realloc` would have put it).
(component
  (import "wasi:random/random@0.2.0" (instance $random
    (export "get-random-bytes" (func (param "len" u64) (result (list u8))))))
  (import "wasi:cli/exit@0.2.0" (instance $cli-exit
    (export "exit" (func (param "status" (result))))))

  ;; libc: memory + a bump cabi_realloc starting at 1024.
  (core module $libc
    (memory (export "memory") 1)
    (global $bump (mut i32) (i32.const 1024))
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      (local $p i32)
      (local.set $p (global.get $bump))
      (global.set $bump (i32.add (global.get $bump) (local.get 3)))
      (local.get $p)))
  (core instance $libc (instantiate $libc))

  ;; adapter: shares libc's memory, its import realloc always answers 4096.
  (core module $adapter
    (import "env" "memory" (memory 1))
    (func (export "cabi_import_realloc") (param i32 i32 i32 i32) (result i32)
      (i32.const 4096)))
  (core instance $adapter (instantiate $adapter (with "env" (instance $libc))))
  (alias core export $adapter "cabi_import_realloc" (core func $cabi_import_realloc))

  (core func $rand
    (canon lower (func $random "get-random-bytes") (memory (core memory $libc "memory")) (realloc $cabi_import_realloc)))
  (core func $exit (canon lower (func $cli-exit "exit")))

  (core module $M
    (import "io" "rand" (func $rand (param i64 i32)))   ;; (len, retptr)
    (import "io" "exit" (func $exit (param i32)))
    (import "libc" "memory" (memory 1))
    (func (export "run") (result i32)
      (call $rand (i64.const 16) (i32.const 16))        ;; retptr=16: ptr@16, len@20
      (if (i32.and (i32.eq (i32.load (i32.const 16)) (i32.const 4096))
                   (i32.eq (i32.load (i32.const 20)) (i32.const 16)))
        (then (call $exit (i32.const 0)))
        (else (call $exit (i32.const 1))))
      (i32.const 0)))

  (core instance $deps-io (export "rand" (func $rand)) (export "exit" (func $exit)))
  (core instance $m (instantiate $M
    (with "io" (instance $deps-io))
    (with "libc" (instance $libc))))

  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $run-inst))
)
