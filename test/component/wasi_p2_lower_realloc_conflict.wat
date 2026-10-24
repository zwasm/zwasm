;; Two `canon lower`s naming two DIFFERENT reallocs: the adapter's
;; `cabi_import_realloc` and libc's `cabi_realloc`. The host trampolines
;; allocate every lowered result through one realloc, so building this
;; component must fail with UnsupportedLowerRealloc rather than place one
;; lower's results through the other's realloc.
(component
  (import "wasi:random/random@0.2.0" (instance $random
    (export "get-random-bytes" (func (param "len" u64) (result (list u8))))))
  (import "wasi:cli/exit@0.2.0" (instance $cli-exit
    (export "exit" (func (param "status" (result))))))

  (core module $libc
    (memory (export "memory") 1)
    (global $bump (mut i32) (i32.const 1024))
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      (local $p i32)
      (local.set $p (global.get $bump))
      (global.set $bump (i32.add (global.get $bump) (local.get 3)))
      (local.get $p)))
  (core instance $libc (instantiate $libc))
  (alias core export $libc "cabi_realloc" (core func $cabi_realloc))

  (core module $adapter
    (import "env" "memory" (memory 1))
    (func (export "cabi_import_realloc") (param i32 i32 i32 i32) (result i32)
      (i32.const 4096)))
  (core instance $adapter (instantiate $adapter (with "env" (instance $libc))))
  (alias core export $adapter "cabi_import_realloc" (core func $cabi_import_realloc))

  (core func $rand
    (canon lower (func $random "get-random-bytes") (memory (core memory $libc "memory")) (realloc $cabi_import_realloc)))
  (core func $rand2
    (canon lower (func $random "get-random-bytes") (memory (core memory $libc "memory")) (realloc $cabi_realloc)))
  (core func $exit (canon lower (func $cli-exit "exit")))

  (core module $M
    (import "io" "rand" (func $rand (param i64 i32)))
    (import "io" "rand2" (func $rand2 (param i64 i32)))
    (import "io" "exit" (func $exit (param i32)))
    (import "libc" "memory" (memory 1))
    (func (export "run") (result i32)
      (call $rand (i64.const 16) (i32.const 16))
      (call $rand2 (i64.const 16) (i32.const 24))
      (call $exit (i32.const 0))
      (i32.const 0)))

  (core instance $deps-io
    (export "rand" (func $rand)) (export "rand2" (func $rand2)) (export "exit" (func $exit)))
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
