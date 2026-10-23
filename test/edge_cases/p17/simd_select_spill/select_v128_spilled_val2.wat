;; #596 — a v128 `select` whose second operand spills: seven live v128 values
;; put val2 past the XMM pool. Both backends read val2 without a spill stage and
;; declined the module. Sibling of select_v128_spilled_result (#560).
;;
;; cond is true, so the select yields 32: 1 | 2 | 4 | 8 | 16 | 32. Spec expectation: 63.
(module
  (func (export "test") (result i32)
    (v128.const i32x4 1 0 0 0) (v128.const i32x4 2 0 0 0)
    (v128.const i32x4 4 0 0 0) (v128.const i32x4 8 0 0 0)
    (v128.const i32x4 16 0 0 0) (v128.const i32x4 32 0 0 0)
    (v128.const i32x4 64 0 0 0)
    (select (i32.mul (i32.const 1) (i32.const 1)))
    (v128.or) (v128.or) (v128.or) (v128.or) (v128.or)
    (i32x4.extract_lane 0)))
