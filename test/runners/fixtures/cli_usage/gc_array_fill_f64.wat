;; array.fill of an f64 element array, on the JIT. f64-only, so a broken f64
;; branch shows here on its own. The emit reads the fill value from the
;; floating-point register and marshals its bits into the fill helper's
;; argument. A const value and a computed one: on x86_64 the register-resident
;; (computed) form could read a general register the value sat in by accident,
;; so the const value is the one that reads a wrong register pre-fix there; both
;; read a wrong register on aarch64.
;;
;; 2.0 is f64 0x4000000000000000 = 4611686018427387904.
(module
  (type $f64a (array (mut f64)))
  (func (export "fill_f64_c") (result i64) (local $r (ref null $f64a))
    (local.set $r (array.new_default $f64a (i32.const 1)))
    (array.fill $f64a (local.get $r) (i32.const 0) (f64.const 2) (i32.const 1))
    (i64.reinterpret_f64 (array.get $f64a (local.get $r) (i32.const 0))))
  (func (export "fill_f64_r") (result i64) (local $r (ref null $f64a))
    (local.set $r (array.new_default $f64a (i32.const 1)))
    (array.fill $f64a (local.get $r) (i32.const 0) (f64.add (f64.const 1.25) (f64.const 0.75)) (i32.const 1))
    (i64.reinterpret_f64 (array.get $f64a (local.get $r) (i32.const 0)))))
