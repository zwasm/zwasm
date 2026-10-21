;; #605: A value-returning call before the if; shape tags counted its result as no push.
;; The else arm's v128 was merged as a scalar. Spec expectation: 14.
(module
  (func $one (result i32) (i32.const 1))
  (func $f (param $x i32) (param $c i32) (result i32)
    (drop (call $one))
    (i32x4.extract_lane 3
      (if (result v128) (local.get $c)
        (then (i32x4.splat (local.get $x)))
        (else (i32x4.add (i32x4.splat (local.get $x)) (v128.const i32x4 1 2 3 4))))))
  (func (export "test") (result i32) (call $f (i32.const 10) (i32.const 0))))
