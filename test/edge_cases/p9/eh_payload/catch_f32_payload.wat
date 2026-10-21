;; #602: a caught f32 payload was loaded into the GPR of its slot while the
;; catch target's consumer read the XMM/V register of the same slot.
;; f(10.25, 1) throws 10.25 and catches it into $b: bits 1092878336.
(module
  (tag $t (param f32))
  (func $thrower (param f32) (local.get 0) (throw $t))
  (func $f (param $x f32) (param $c i32) (result f32)
    (block $b (result f32)
      (try_table (result f32) (catch $t $b)
        (if (local.get $c) (then (call $thrower (local.get $x))))
        (f32.add (local.get $x) (f32.const 1)))))
  (func (export "test") (result i32)
    (i32.reinterpret_f32 (call $f (f32.const 10.25) (i32.const 1)))))
