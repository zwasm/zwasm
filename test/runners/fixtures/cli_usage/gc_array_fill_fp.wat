;; array.fill of an f32 / f64 element array. The JIT emit marshals the fill
;; value through a general register, so an f32 / f64 value — which sits in a
;; floating-point register — has no path: the JIT declines (the default engine
;; then runs it on the interpreter), as array.new does for the same element
;; types. array.new_default (zero-init, no runtime value) is not declined, so
;; the declining op here is array.fill.
;;
;; Entries take no parameter, compute / const the value so it lands in a
;; floating-point register, and return its bits: 2.0 is f32 0x40000000 =
;; 1073741824 / f64 0x4000000000000000 = 4611686018427387904, 2.5 is f32
;; 0x40200000 = 1075838976.
(module
  (type $f32a (array (mut f32)))
  (type $f64a (array (mut f64)))
  (func (export "fill_f32_c") (result i32) (local $r (ref null $f32a))
    (local.set $r (array.new_default $f32a (i32.const 1)))
    (array.fill $f32a (local.get $r) (i32.const 0) (f32.const 2.5) (i32.const 1))
    (i32.reinterpret_f32 (array.get $f32a (local.get $r) (i32.const 0))))
  (func (export "fill_f32_r") (result i32) (local $r (ref null $f32a))
    (local.set $r (array.new_default $f32a (i32.const 1)))
    (array.fill $f32a (local.get $r) (i32.const 0) (f32.add (f32.const 1.25) (f32.const 0.75)) (i32.const 1))
    (i32.reinterpret_f32 (array.get $f32a (local.get $r) (i32.const 0))))
  (func (export "fill_f64_r") (result i64) (local $r (ref null $f64a))
    (local.set $r (array.new_default $f64a (i32.const 1)))
    (array.fill $f64a (local.get $r) (i32.const 0) (f64.add (f64.const 1.25) (f64.const 0.75)) (i32.const 1))
    (i64.reinterpret_f64 (array.get $f64a (local.get $r) (i32.const 0)))))
