;; A module with a v128 (SIMD) export AND an f32 `array.new` export. The JIT now
;; marshals the f32 init from the floating-point register, so `array.new` no
;; longer declines; the whole module compiles on the JIT, and the SIMD export
;; runs there. Before (when the f32 element declined, D-495-style), the decline
;; dropped the whole instance to the interpreter, which cannot execute
;; `v128.const`, so the module failed to instantiate on the default engine.
;;
;; `simd` extracts lane 0 of a v128 (= 7); `mk` fills an f32 array with 2.0 and
;; returns its bits (0x40000000 = 1073741824).
(module
  (type $f32a (array (mut f32)))
  (func (export "simd") (result i32)
    (i32x4.extract_lane 0 (v128.const i32x4 7 0 0 0)))
  (func (export "mk") (result i32) (local $a (ref null $f32a))
    (local.set $a (array.new $f32a (f32.add (f32.const 1.25) (f32.const 0.75)) (i32.const 4)))
    (i32.reinterpret_f32 (array.get $f32a (local.get $a) (i32.const 2)))))
