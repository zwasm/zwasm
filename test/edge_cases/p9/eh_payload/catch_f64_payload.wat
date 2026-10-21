;; #602, f64 sibling of catch_f32_payload. f(-3.3, 1) throws -3.3; the result
;; folds the payload's two 32-bit halves so a wrong low half shows too:
;; -1502871552.
(module
  (tag $t (param f64))
  (func $thrower (param f64) (local.get 0) (throw $t))
  (func $f (param $x f64) (param $c i32) (result f64)
    (block $b (result f64)
      (try_table (result f64) (catch $t $b)
        (if (local.get $c) (then (call $thrower (local.get $x))))
        (f64.add (local.get $x) (f64.const 1)))))
  (func (export "test") (result i32)
    (local $v i64)
    (local.set $v (i64.reinterpret_f64 (call $f (f64.const -3.3) (i32.const 1))))
    (i32.wrap_i64 (i64.xor (local.get $v) (i64.shr_u (local.get $v) (i64.const 32))))))
