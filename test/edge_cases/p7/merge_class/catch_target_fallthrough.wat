;; #601: a try_table catch gives its target block fresh merge vregs; the body's
;; f32 fall-through was merged into them with a GPR move. No throw happens here.
;; f(10.5, 0) = 11.5 (bits 1094189056).
(module
  (tag $t (param f32))
  (func $thrower (param f32) (local.get 0) (throw $t))
  (func $f (param $x f32) (param $c i32) (result f32)
    (block $b (result f32)
      (try_table (result f32) (catch $t $b)
        (if (local.get $c) (then (call $thrower (local.get $x))))
        (f32.add (local.get $x) (f32.const 1)))))
  (func (export "test") (result i32)
    (i32.reinterpret_f32 (call $f (f32.const 10.5) (i32.const 0)))))
