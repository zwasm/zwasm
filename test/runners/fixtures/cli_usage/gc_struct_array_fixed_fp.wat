;; struct.new and array.new_fixed with an f32 / f64 field / element read the
;; value correctly on the JIT as on the interpreter — like array.new /
;; array.fill once the JIT reads their value from the floating-point register
;; too. These two read a value popped from the pre-homed value stack, so the GPR
;; loader already read the real spilled bytes. This pins that for a const value
;; and a computed (stack-resident) value, both widths, both instructions.
;;
;; Entries take no parameter and return the value's bits: 2.0 is f32 0x40000000
;; = 1073741824 / f64 0x4000000000000000 = 4611686018427387904.
;; (Exhaustive enumeration lives in
;; private/review_array-new-fill-fp-operand/gen_siblings.py.)
(module
  (type $S32 (struct (field (mut f32))))
  (type $S64 (struct (field (mut f64))))
  (type $A32 (array (mut f32)))
  (type $A64 (array (mut f64)))
  (func (export "sn32_const") (result i32)
    (i32.reinterpret_f32 (struct.get $S32 0 (struct.new $S32 (f32.const 2)))))
  (func (export "sn32_stack") (result i32)
    (i32.reinterpret_f32 (struct.get $S32 0 (struct.new $S32 (f32.add (f32.const 1.5) (f32.const 0.5))))))
  (func (export "sn64_const") (result i64)
    (i64.reinterpret_f64 (struct.get $S64 0 (struct.new $S64 (f64.const 2)))))
  (func (export "sn64_stack") (result i64)
    (i64.reinterpret_f64 (struct.get $S64 0 (struct.new $S64 (f64.add (f64.const 1.5) (f64.const 0.5))))))
  (func (export "anf32_const") (result i32)
    (i32.reinterpret_f32 (array.get $A32 (array.new_fixed $A32 1 (f32.const 2)) (i32.const 0))))
  (func (export "anf32_stack") (result i32)
    (i32.reinterpret_f32 (array.get $A32 (array.new_fixed $A32 1 (f32.add (f32.const 1.5) (f32.const 0.5))) (i32.const 0))))
  (func (export "anf64_const") (result i64)
    (i64.reinterpret_f64 (array.get $A64 (array.new_fixed $A64 1 (f64.const 2)) (i32.const 0))))
  (func (export "anf64_stack") (result i64)
    (i64.reinterpret_f64 (array.get $A64 (array.new_fixed $A64 1 (f64.add (f64.const 1.5) (f64.const 0.5))) (i32.const 0)))))
