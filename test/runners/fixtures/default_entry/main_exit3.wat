;; `proc_exit(3)` inside a value-returning `main`: the exit status is the
;; guest's, and the result it never returned is not printed (#220 (c), C3).
(module
  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
  (memory (export "memory") 1)
  (func (export "main") (result i32) i32.const 3 call $exit i32.const 42))
