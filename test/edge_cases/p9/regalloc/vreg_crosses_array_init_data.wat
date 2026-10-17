;; #503 boundary fixture — five temporaries are live across array.init_data, a
;; runtime callout. Five is one more than the callee-saved registers in the
;; x86_64 pool (RBX, R12-R14), and every one of arm64's X9-X13 is caller-saved,
;; so unless the regalloc force-spills them at the op's pc, the callout's
;; argument marshal or its own temporaries overwrite one of them.
;; Sibling of vreg_crosses_table_grow (ADR-0060 call-site list).
;;
;; 2*3 + 2*5 + 2*7 + 2*11 + 2*13 = 78; element 0 = 'A' = 65. Spec expectation: 143.
(module
  (type $bytes (array (mut i8)))
  (data $d "ABCD")
  (func (export "test") (result i32)
    (local $arr (ref null $bytes))
    (local.set $arr (array.new_default $bytes (i32.const 4)))
    (i32.mul (i32.const 2) (i32.const 3))
    (i32.mul (i32.const 2) (i32.const 5))
    (i32.mul (i32.const 2) (i32.const 7))
    (i32.mul (i32.const 2) (i32.const 11))
    (i32.mul (i32.const 2) (i32.const 13))
    (array.init_data $bytes $d (local.get $arr) (i32.const 0) (i32.const 0) (i32.const 4))
    (i32.add)
    (i32.add)
    (i32.add)
    (i32.add)
    (i32.add (array.get_u $bytes (local.get $arr) (i32.const 0)))))
