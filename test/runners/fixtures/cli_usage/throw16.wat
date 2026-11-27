;; A `throw` of a tag with 16 i32 payload values — the JIT's payload buffer
;; holds exactly 16 (`Exception.payload[16]`). The JIT compiles and runs it:
;; `catch_all` catches the throw and `go` returns 42 on `--engine jit`.
;; `throw17.wat` is the 17-value sibling the JIT declines.
(module
  (tag $e (param i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32))
  (func (export "go") (result i32)
    (block $caught
      try_table (catch_all $caught)
        i32.const 0 i32.const 0 i32.const 0 i32.const 0
        i32.const 0 i32.const 0 i32.const 0 i32.const 0
        i32.const 0 i32.const 0 i32.const 0 i32.const 0
        i32.const 0 i32.const 0 i32.const 0 i32.const 0
        throw $e
      end
      unreachable)
    i32.const 42))
