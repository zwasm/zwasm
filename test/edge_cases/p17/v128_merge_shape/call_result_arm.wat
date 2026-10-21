;; #605: The then arm ends in a call returning v128, which shape tags tagged scalar.
;; The else arm's v128 was merged as a scalar. Spec expectation: 69.
(module
  (func $v (param i32) (result v128) (i32x4.splat (local.get 0)))
  (func $f (param $x i32) (param $c i32) (result i32)
    (i32x4.extract_lane 3
      (if (result v128) (local.get $c)
        (then (call $v (local.get $x)))
        (else (i32x4.add (i32x4.splat (local.get $x)) (v128.const i32x4 1 2 3 9))))))
  (func (export "test") (result i32) (call $f (i32.const 60) (i32.const 0))))
