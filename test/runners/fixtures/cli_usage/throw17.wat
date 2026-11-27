;; A `throw` of a tag with 17 i32 payload values — one past the JIT's payload
;; buffer (`Exception.payload[16]`). Nothing validates a tag's arity, so the
;; module is well-formed; the JIT declines the `throw` emit (`UnsupportedOp`),
;; so `--engine jit` exits 1 with that reason.
;; The `auto`/`interp` outcome is #781's wrong trap and is left unpinned.
(module
  (tag $e (param i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32))
  (func (export "go") (result i32)
    (block $caught
      try_table (catch_all $caught)
        i32.const 0 i32.const 0 i32.const 0 i32.const 0
        i32.const 0 i32.const 0 i32.const 0 i32.const 0
        i32.const 0 i32.const 0 i32.const 0 i32.const 0
        i32.const 0 i32.const 0 i32.const 0 i32.const 0
        i32.const 0
        throw $e
      end
      unreachable)
    i32.const 42))
