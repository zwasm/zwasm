;; array.new of an f32 element array, on the JIT. The emit reads the init from
;; the floating-point register (as array.set / struct.set do) and marshals its
;; bits into the fill helper's argument, so the JIT fills every element with the
;; value — no fall back to the interpreter. f32-only, one export, so a broken
;; f32 branch shows here and is not masked by the f64 one.
;;
;; The entry takes no parameter (the JIT `--invoke` rejects an f32-parameter
;; entry), computes the init so it lands in a floating-point register, and
;; returns its bits: 2.0 is f32 0x40000000 = 1073741824.
(module
  (type $f32a (array (mut f32)))
  (func (export "new_f32") (result i32) (local $a (ref null $f32a))
    (local.set $a (array.new $f32a (f32.add (f32.const 1.25) (f32.const 0.75)) (i32.const 4)))
    (i32.reinterpret_f32 (array.get $f32a (local.get $a) (i32.const 2)))))
