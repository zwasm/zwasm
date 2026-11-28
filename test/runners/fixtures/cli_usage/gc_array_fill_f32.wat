;; array.fill of an f32 element array, on the JIT. The emit reads the fill value
;; from the floating-point register and marshals its bits into the fill helper's
;; argument, so the JIT fills the slots with the value. f32-only. A const value
;; and a computed (register-resident) one; array.new_default (zero-init, no
;; value) stays on the JIT as before, so the op under test is array.fill.
;;
;; 2.5 is f32 0x40200000 = 1075838976; 2.0 is f32 0x40000000 = 1073741824.
(module
  (type $f32a (array (mut f32)))
  (func (export "fill_f32_c") (result i32) (local $r (ref null $f32a))
    (local.set $r (array.new_default $f32a (i32.const 1)))
    (array.fill $f32a (local.get $r) (i32.const 0) (f32.const 2.5) (i32.const 1))
    (i32.reinterpret_f32 (array.get $f32a (local.get $r) (i32.const 0))))
  (func (export "fill_f32_r") (result i32) (local $r (ref null $f32a))
    (local.set $r (array.new_default $f32a (i32.const 1)))
    (array.fill $f32a (local.get $r) (i32.const 0) (f32.add (f32.const 1.25) (f32.const 0.75)) (i32.const 1))
    (i32.reinterpret_f32 (array.get $f32a (local.get $r) (i32.const 0)))))
