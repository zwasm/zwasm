;; #505 boundary fixture — a temporary is live across table.grow, a runtime
;; callout that preserves callee-saved registers only. On a pool that holds
;; caller-saved registers (arm64 X9-X13) the pending 54 must be in its slot
;; before the callout. table.grow on an empty table returns the old size, 0.
;;
;; Spec expectation: 54.
(module
  (table $tab 0 funcref)
  (func (export "test") (result i32)
    (i32.add (i32.add (i32.mul (i32.const 3) (i32.const 7)) (i32.mul (i32.const 3) (i32.const 11)))
             (table.grow $tab (ref.null func) (i32.const 1)))))
