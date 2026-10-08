;; #505 boundary fixture — a temporary pushed before a try_table and used
;; after it is live across the whole block, and reaches the landing pad
;; through the throw dispatcher and the exnref reify call. Neither is a
;; call the emit models, so the regalloc must spill the pending 54 at the
;; try_table pc. The throw is inline (a call inside the body would spill
;; it for the wrong reason and hide the gap).
;;
;; Spec expectation: 54 + 100 = 154.
(module
  (tag $e)
  (func (export "test") (result i32)
    (i32.add (i32.mul (i32.const 3) (i32.const 7)) (i32.mul (i32.const 3) (i32.const 11)))
    (block $h (result exnref)
      (try_table (catch_ref $e $h) (throw $e))
      (unreachable))
    (drop)
    (i32.const 100)
    (i32.add)))
