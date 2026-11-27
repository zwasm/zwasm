;; f64 array.fill as the only declining op (array.new_default is not declined),
;; so the f64 decline predicate for array.fill is exercised on its own. Expect
;; f64 2.0 = 4611686018427387904.
(module
  (type $A64 (array (mut f64)))
  (func (export "ff64") (result i64) (local $r (ref null $A64))
    (local.set $r (array.new_default $A64 (i32.const 1)))
    (array.fill $A64 (local.get $r) (i32.const 0) (f64.add (f64.const 1.5) (f64.const 0.5)) (i32.const 1))
    (i64.reinterpret_f64 (array.get $A64 (local.get $r) (i32.const 0)))))
