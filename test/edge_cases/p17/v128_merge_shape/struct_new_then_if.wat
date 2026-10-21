;; #605: struct.new before the if; shape tags counted its GcRef as no push.
;; The else arm's v128 was merged as a scalar. Spec expectation: 25.
(module
  (type $s (struct (field i32)))
  (func $f (param $x i32) (param $c i32) (result i32)
    (drop (struct.new $s (local.get $x)))
    (i32x4.extract_lane 3
      (if (result v128) (local.get $c)
        (then (i32x4.splat (local.get $x)))
        (else (i32x4.add (i32x4.splat (local.get $x)) (v128.const i32x4 1 2 3 5))))))
  (func (export "test") (result i32) (call $f (i32.const 20) (i32.const 0))))
