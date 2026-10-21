;; #602: a tag mixing i32, f32 and f64 params. Each payload slot is loaded by
;; its own type; the i32 must stay a GPR load. f(5, 2.5, -0.125, 1) throws all
;; three; the result combines them: 5000 + 250 + 1250 = 6500.
(module
  (tag $t (param i32 f32 f64))
  (func $thrower (param i32 f32 f64) (local.get 0) (local.get 1) (local.get 2) (throw $t))
  (func $f (param $i i32) (param $x f32) (param $y f64) (param $c i32) (result i32)
    (local $ri i32) (local $rx f32) (local $ry f64)
    (block $b (result i32 f32 f64)
      (try_table (result i32 f32 f64) (catch $t $b)
        (if (local.get $c) (then (call $thrower (local.get $i) (local.get $x) (local.get $y))))
        (i32.const 0) (f32.const 0) (f64.const 0)))
    (local.set $ry) (local.set $rx) (local.set $ri)
    (i32.add
      (i32.add (i32.mul (local.get $ri) (i32.const 1000))
               (i32.trunc_f32_s (f32.mul (local.get $rx) (f32.const 100))))
      (i32.trunc_f64_s (f64.mul (local.get $ry) (f64.const -10000)))))
  (func (export "test") (result i32)
    (call $f (i32.const 5) (f32.const 2.5) (f64.const -0.125) (i32.const 1))))
