;; Four reference arguments and a v128 argument in one call: each must arrive
;; intact. `test` returns 1 only when every reference is non-null and both v128
;; lanes hold what the caller passed.
(module
  (func $leaf)
  (elem declare func $leaf)
  (func $callee (param funcref funcref funcref funcref v128) (result i32)
    (i32.and
      (i32.and
        (i32.and (i32.eqz (ref.is_null (local.get 0))) (i32.eqz (ref.is_null (local.get 1))))
        (i32.and (i32.eqz (ref.is_null (local.get 2))) (i32.eqz (ref.is_null (local.get 3)))))
      (i32.and
        (i64.eq (i64x2.extract_lane 0 (local.get 4)) (i64.const 0))
        (i64.eq (i64x2.extract_lane 1 (local.get 4)) (i64.const 0x0123456789abcdef)))))
  (func (export "test") (result i32)
    (call $callee
      (ref.func $leaf) (ref.func $leaf) (ref.func $leaf) (ref.func $leaf)
      (v128.const i64x2 0 0x0123456789abcdef))))
