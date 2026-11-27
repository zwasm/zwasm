;; f64 array.new as the only declining op, so the f64 (0x7C) decline predicate
;; is exercised on its own — gc_array_new_fp.wat declines at its f32 function
;; first, which would mask a missing f64 branch. Expect f64 2.0 =
;; 0x4000000000000000 = 4611686018427387904.
(module
  (type $A64 (array (mut f64)))
  (func (export "nf64") (result i64) (local $a (ref null $A64))
    (local.set $a (array.new $A64 (f64.add (f64.const 1.5) (f64.const 0.5)) (i32.const 1)))
    (i64.reinterpret_f64 (array.get $A64 (local.get $a) (i32.const 0)))))
