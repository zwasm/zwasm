;; #249 regression guard, acceptance half: `call_ref $ft` /
;; `return_call_ref $ft` with a genuinely typed callee — `ref.func $seven`
;; is `(ref $ft)`, a non-null subtype of the required `(ref null $ft)` —
;; must keep validating AND running after the callee check narrowed from
;; "any reftype" to a `(ref null typeidx)` subtype test (Wasm 3.0
;; §3.3.10.4-5). wasm-tools accepts.
;;
;; Stress axes (test_discipline.md §1): validator boundary (call_ref
;; callee subtype) x typed funcref source (ref.func -> concrete
;; (ref $ft)) x tail-call (return_call_ref shares the same callee arm).
;;
;; Provenance: hand-written for the #249 fix. The reject half lives in
;; validator_tests.zig — this runner has no reject expectation form.
(module
  (type $ft (func (result i32)))
  (func $seven (type $ft) i32.const 7)
  (elem declare func $seven)
  (func $tail (type $ft)
    (return_call_ref $ft (ref.func $seven)))
  (func (export "test") (result i32)
    (call_ref $ft (ref.func $seven))
    (call $tail)
    i32.add))
