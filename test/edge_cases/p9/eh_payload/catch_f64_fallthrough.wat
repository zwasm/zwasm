;; #602 sibling of catch_f64_payload on the path that does not throw: the
;; try_table's f64 falls through into the catch target's merge, which the FP
;; landing pad shares. f(6.75, 0) = 7.75, halves folded as in catch_f64_payload.
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
    (local.set $v (i64.reinterpret_f64 (call $f (f64.const 6.75) (i32.const 0))))
    (i32.wrap_i64 (i64.xor (local.get $v) (i64.shr_u (local.get $v) (i64.const 32))))))
