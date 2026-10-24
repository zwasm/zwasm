;; #600: four i32 locals take the register homes, and six f32 values are live
;; at once past them. f(1.5): homes sum to 10, the six products to 31.5.
(module
  (func $f (param $x f32) (result f32)
    (local $a i32) (local $b i32) (local $c i32) (local $d i32)
    (local.set $a (i32.const 1)) (local.set $b (i32.const 2))
    (local.set $c (i32.const 3)) (local.set $d (i32.const 4))
    (f32.mul (local.get $x) (f32.const 1))
    (f32.mul (local.get $x) (f32.const 2))
    (f32.mul (local.get $x) (f32.const 3))
    (f32.mul (local.get $x) (f32.const 4))
    (f32.mul (local.get $x) (f32.const 5))
    (f32.mul (local.get $x) (f32.const 6))
    f32.add f32.add f32.add f32.add f32.add
    (f32.convert_i32_s (i32.add (i32.add (local.get $a) (local.get $b)) (i32.add (local.get $c) (local.get $d))))
    f32.add)
  (func (export "test") (result i32)
    (i32.reinterpret_f32 (call $f (f32.const 1.5)))))
