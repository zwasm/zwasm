;; array.new of an f64 element array, on the JIT. f64-only, one export, so a
;; broken f64 branch shows here on its own (in the combined #780 module the f64
;; predicate sat behind the f32 function's module-wide decline and never ran).
;; The emit reads the init from the floating-point register and marshals its
;; bits into the fill helper's argument.
;;
;; 2.0 is f64 0x4000000000000000 = 4611686018427387904.
(module
  (type $f64a (array (mut f64)))
  (func (export "new_f64") (result i64) (local $a (ref null $f64a))
    (local.set $a (array.new $f64a (f64.add (f64.const 1.25) (f64.const 0.75)) (i32.const 4)))
    (i64.reinterpret_f64 (array.get $f64a (local.get $a) (i32.const 2)))))
