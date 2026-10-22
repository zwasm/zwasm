;; `wasi:io/poll` `poll` with `in` = (ptr 0, len 0x4000_0000): the result
;; list's byte size, 4 per index, does not fit in u32, so the call traps as
;; the store of that list would, before the guest's allocator is asked.
(component
  (import "wasi:io/poll@0.2.12" (instance $poll
    (export "poll" (func (param "in" (list u32)) (result (list u32))))))
  (core module $libc
    (memory (export "memory") 1)
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) unreachable))
  (core instance $libc (instantiate $libc))
  (core func $poll (canon lower (func $poll "poll")
    (memory (core memory $libc "memory")) (realloc (core func $libc "cabi_realloc"))))
  (core module $M
    (import "poll" "poll" (func $poll (param i32 i32 i32)))
    (func (export "run") (result i32)
      (call $poll (i32.const 0) (i32.const 0x40000000) (i32.const 0))
      (i32.const 0)))
  (core instance $deps (export "poll" (func $poll)))
  (core instance $m (instantiate $M (with "poll" (instance $deps))))
  (func $run (result u32) (canon lift (core func $m "run")))
  (export "run" (func $run)))
