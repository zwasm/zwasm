;; #503 boundary fixture — five temporaries are live across array.init_elem, a
;; runtime callout. Sibling of vreg_crosses_array_init_data: the same count, for
;; the same reason (one past the callee-saved part of the x86_64 pool; all of
;; arm64's X9-X13).
;;
;; 2*3 + 2*5 + 2*7 + 2*11 + 2*13 = 78; element 0 is $f, not null = 1.
;; Spec expectation: 79.
(module
  (type $funcs (array (mut funcref)))
  (func $f)
  (elem $e func $f)
  (func (export "test") (result i32)
    (local $arr (ref null $funcs))
    (local.set $arr (array.new_default $funcs (i32.const 1)))
    (i32.mul (i32.const 2) (i32.const 3))
    (i32.mul (i32.const 2) (i32.const 5))
    (i32.mul (i32.const 2) (i32.const 7))
    (i32.mul (i32.const 2) (i32.const 11))
    (i32.mul (i32.const 2) (i32.const 13))
    (array.init_elem $funcs $e (local.get $arr) (i32.const 0) (i32.const 0) (i32.const 1))
    (i32.add)
    (i32.add)
    (i32.add)
    (i32.add)
    (i32.add (i32.eqz (ref.is_null (array.get $funcs (local.get $arr) (i32.const 0)))))))
