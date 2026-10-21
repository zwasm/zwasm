;; #605: The then arm ends in a v128 global.get, which shape tags tagged scalar.
;; The else arm's v128 was merged as a scalar. Spec expectation: 58.
(module
  (global $g (mut v128) (v128.const i32x4 0 0 0 0))
  (func $f (param $x i32) (param $c i32) (result i32)
    (global.set $g (i32x4.splat (local.get $x)))
    (i32x4.extract_lane 3
      (if (result v128) (local.get $c)
        (then (global.get $g))
        (else (i32x4.add (i32x4.splat (local.get $x)) (v128.const i32x4 1 2 3 8))))))
  (func (export "test") (result i32) (call $f (i32.const 50) (i32.const 0))))
