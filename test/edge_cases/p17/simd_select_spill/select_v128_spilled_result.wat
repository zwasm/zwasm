;; #560 boundary fixture — a v128 `select` whose result spills: four
;; live v128 values plus the select's operands put it past the XMM pool. The
;; x86_64 handler staged the spilled result through XMM14, the register its
;; (val1 ^ val2) & mask scratch lives in, so the result was 0 and the or-chain 15.
;; Sibling of select_v128_spilled_cond (D-490: a spilled condition).
;;
;; 170 | 1 | 2 | 4 | 8. Spec expectation: 175.
(module
  (func (export "test") (result i32)
    (v128.const i32x4 1 0 0 0) (v128.const i32x4 2 0 0 0)
    (v128.const i32x4 4 0 0 0) (v128.const i32x4 8 0 0 0)
    (select (v128.const i32x4 170 0 0 0) (v128.const i32x4 187 0 0 0) (i32.mul (i32.const 1) (i32.const 1)))
    (v128.or) (v128.or) (v128.or) (v128.or)
    (i32x4.extract_lane 0)))
