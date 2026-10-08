;; #505 boundary fixture — sibling of vreg_crosses_try_table_catch_ref with
;; a plain catch clause: no reify call on the landing pad, only the throw
;; dispatcher between the pending 54 and its use.
;;
;; Spec expectation: 54 + 100 = 154.
(module
  (tag $e)
  (func (export "test") (result i32)
    (i32.add (i32.mul (i32.const 3) (i32.const 7)) (i32.mul (i32.const 3) (i32.const 11)))
    (block $h
      (try_table (catch $e $h) (throw $e))
      (unreachable))
    (i32.const 100)
    (i32.add)))
