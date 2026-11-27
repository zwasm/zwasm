;; array.new of an f32 / f64 element array. The JIT emit marshals the init
;; through a general register (mirroring struct.new), so an f32 / f64 init —
;; which sits in a floating-point register — has no path: the JIT declines (the
;; default engine then runs it on the interpreter), as it already does for a
;; v128 element (D-495). The interpreter fills every element with the init.
;;
;; Entries take no parameter (the JIT `--invoke` rejects an f32-parameter
;; entry), compute the init so it lands in a floating-point register, and return
;; its bits: 2.0 is f32 0x40000000 = 1073741824 / f64 0x4000000000000000 =
;; 4611686018427387904.
(module
  (type $f32a (array (mut f32)))
  (type $f64a (array (mut f64)))
  (func (export "new_f32") (result i32) (local $a (ref null $f32a))
    (local.set $a (array.new $f32a (f32.add (f32.const 1.25) (f32.const 0.75)) (i32.const 4)))
    (i32.reinterpret_f32 (array.get $f32a (local.get $a) (i32.const 2))))
  (func (export "new_f64") (result i64) (local $a (ref null $f64a))
    (local.set $a (array.new $f64a (f64.add (f64.const 1.25) (f64.const 0.75)) (i32.const 4)))
    (i64.reinterpret_f64 (array.get $f64a (local.get $a) (i32.const 2)))))
