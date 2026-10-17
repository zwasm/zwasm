;; #503 boundary fixture — call arguments whose vregs sit in each other's
;; argument registers. Under SysV the pressure from b's and d's zero-valued
;; subtrees leaves d in R9 and e in R8, bound for R8 and R9: a cycle the
;; marshal breaks through RAX (`gpr.ParallelMove`). Moved in order, d would
;; reach both (44121). Win64 passes d and e on the stack, so there this
;; checks the arithmetic only.
;;
;; a + 10b + 100c + 1000d + 10000e of 1..5. Spec expectation: 54321.
(module
  (func $f (param i32 i32 i32 i32 i32) (result i32) (i32.add (i32.add (i32.add (i32.add (local.get 0) (i32.mul (local.get 1) (i32.const 10))) (i32.mul (local.get 2) (i32.const 100))) (i32.mul (local.get 3) (i32.const 1000))) (i32.mul (local.get 4) (i32.const 10000))))
  (func (export "test") (result i32)
    (call $f
      (i32.mul (i32.const 1) (i32.const 1))
      (i32.add (i32.mul (i32.const 2) (i32.const 1)) (i32.add (i32.mul (i32.const 7) (i32.const 0)) (i32.mul (i32.const 7) (i32.const 0))))
      (i32.mul (i32.const 3) (i32.const 1))
      (i32.add (i32.mul (i32.const 4) (i32.const 1)) (i32.add (i32.mul (i32.const 7) (i32.const 0)) (i32.mul (i32.const 7) (i32.const 0))))
      (i32.mul (i32.const 5) (i32.const 1)))))
