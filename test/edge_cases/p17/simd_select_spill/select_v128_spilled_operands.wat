;; #596 — fifteen live v128 values at a `select`: past the aarch64 FP pool too,
;; so val1, val2 and the result all spill there, as on x86_64. Sibling of
;; select_v128_spilled_val2, whose seven spill on x86_64 only.
;;
;; cond is true, so the select yields 8192: 1 | 2 | ... | 4096 | 8192. Spec expectation: 16383.
(module
  (func (export "test") (result i32)
    (v128.const i32x4 1 0 0 0) (v128.const i32x4 2 0 0 0)
    (v128.const i32x4 4 0 0 0) (v128.const i32x4 8 0 0 0)
    (v128.const i32x4 16 0 0 0) (v128.const i32x4 32 0 0 0)
    (v128.const i32x4 64 0 0 0) (v128.const i32x4 128 0 0 0)
    (v128.const i32x4 256 0 0 0) (v128.const i32x4 512 0 0 0)
    (v128.const i32x4 1024 0 0 0) (v128.const i32x4 2048 0 0 0)
    (v128.const i32x4 4096 0 0 0) (v128.const i32x4 8192 0 0 0)
    (v128.const i32x4 16384 0 0 0)
    (select (i32.mul (i32.const 1) (i32.const 1)))
    (v128.or) (v128.or) (v128.or) (v128.or) (v128.or) (v128.or)
    (v128.or) (v128.or) (v128.or) (v128.or) (v128.or) (v128.or)
    (v128.or)
    (i32x4.extract_lane 0)))
