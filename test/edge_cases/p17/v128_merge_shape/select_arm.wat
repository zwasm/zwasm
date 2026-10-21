;; #605: The then arm ends in a v128 select, which shape tags tagged scalar.
;; The else arm's v128 was merged as a scalar. Spec expectation: 47.
(module
  (func $f (param $x i32) (param $c i32) (result i32)
    (i32x4.extract_lane 3
      (if (result v128) (local.get $c)
        (then (select (i32x4.splat (local.get $x)) (v128.const i32x4 0 0 0 0) (local.get $x)))
        (else (i32x4.add (i32x4.splat (local.get $x)) (v128.const i32x4 1 2 3 7))))))
  (func (export "test") (result i32) (call $f (i32.const 40) (i32.const 0))))
