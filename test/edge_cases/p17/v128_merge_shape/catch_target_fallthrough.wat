;; #605: A try_table catch mints the target block's merge vreg, which shape tags never counted. No throw happens here.
;; The else arm's v128 was merged as a scalar. Spec expectation: 36.
(module
  (tag $t (param v128))
  (func $thrower (param v128) (local.get 0) (throw $t))
  (func $f (param $x i32) (param $c i32) (result i32)
    (i32x4.extract_lane 3
      (block $b (result v128)
        (try_table (result v128) (catch $t $b)
          (if (local.get $c) (then (call $thrower (i32x4.splat (local.get $x)))))
          (i32x4.add (i32x4.splat (local.get $x)) (v128.const i32x4 1 2 3 6))))))
  (func (export "test") (result i32) (call $f (i32.const 30) (i32.const 0))))
