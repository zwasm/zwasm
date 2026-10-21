;; #602 with catch_ref: the exnref is the top result and the f32 payload sits
;; below it. f(7.75, 1) throws 7.75: bits 1089994752.
(module
  (tag $t (param f32))
  (func $thrower (param f32) (local.get 0) (throw $t))
  (func $f (param $x f32) (param $c i32) (result f32)
    (block $b (result f32 exnref)
      (try_table (result f32) (catch_ref $t $b)
        (if (local.get $c) (then (call $thrower (local.get $x))))
        (f32.add (local.get $x) (f32.const 1)))
      (return))
    (drop))
  (func (export "test") (result i32)
    (i32.reinterpret_f32 (call $f (f32.const 7.75) (i32.const 1)))))
