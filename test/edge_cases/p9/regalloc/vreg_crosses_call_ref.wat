;; #505 boundary fixture — a temporary (not a local) is live across a
;; call_ref. The callee is temporary-heavy and has no locals, so it reuses
;; every pool register without saving any (a JIT callee saves only FP and
;; the runtime ptr). Unless the regalloc force-spills the pending 54 at
;; the call_ref pc, the callee's own temporaries overwrite it.
;; Sibling of vreg_crosses_table_copy (ADR-0060 call-site list, not the
;; ADR-0077 scratch fence).
;;
;; 3*7 + 3*11 = 54; clob(1) = 2+3+5+7+11+13+17 = 58. Spec expectation: 112.
(module
  (type $t (func (param i32) (result i32)))
  (elem declare func $clob)
  (func $clob (type $t) (param i32) (result i32)
    (i32.add (i32.mul (local.get 0) (i32.const 2)) (i32.add (i32.mul (local.get 0) (i32.const 3)) (i32.add (i32.mul (local.get 0) (i32.const 5)) (i32.add (i32.mul (local.get 0) (i32.const 7)) (i32.add (i32.mul (local.get 0) (i32.const 11)) (i32.add (i32.mul (local.get 0) (i32.const 13)) (i32.mul (local.get 0) (i32.const 17)))))))))
  (func (export "test") (result i32)
    (i32.add (i32.add (i32.mul (i32.const 3) (i32.const 7)) (i32.mul (i32.const 3) (i32.const 11)))
             (call_ref $t (i32.const 1) (ref.func $clob)))))
