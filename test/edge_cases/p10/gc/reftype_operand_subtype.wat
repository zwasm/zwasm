;; #322 acceptance half: operands that are proper subtypes of what each op
;; takes — `(ref i31)` for `i31.get_s` / `i31.get_u` (i31ref), for
;; `ref.test (ref i31)` (the any hierarchy) and for `br_on_cast eqref`
;; (rt1 = eqref), and `(ref $a)` for `array.len` (arrayref) — still validate
;; and run once each operand is checked against its spec type. 5 + 1 + 3 + 5.
;; wasm-tools accepts.
;;
;; Provenance: hand-written for the #322 fix. The reject half lives in
;; validator_reftype_operand_tests.zig — this runner has no reject
;; expectation form.
(module
  (type $a (array i32))
  (func (export "test") (result i32)
    (local $i (ref i31))
    (local.set $i (ref.i31 (i32.const 5)))
    (i32.add
      (i32.add
        (i31.get_s (local.get $i))
        (ref.test (ref i31) (local.get $i)))
      (i32.add
        (array.len (array.new_fixed $a 3 (i32.const 1) (i32.const 2) (i32.const 3)))
        (i31.get_u
          (block $l (result (ref i31))
            (br_on_cast $l eqref (ref i31) (local.get $i))
            (drop)
            (ref.i31 (i32.const 100)))))))
)
