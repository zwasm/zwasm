;; #430 acceptance half: a GC constructor in a constant expression whose
;; operand is a proper subtype of the field — `(ref $t)` where `$h`'s field
;; is `(ref $s)` and `$t <: $s` — still validates and runs once each operand
;; is typed against its field (Wasm 3.0 §3.3.13.1). wasm-tools accepts.
;;
;; Provenance: hand-written for the #430 fix. The reject half lives in
;; validator_helpers_tests.zig — this runner has no reject expectation form.
(module
  (type $s (sub (struct (field i32))))
  (type $t (sub $s (struct (field i32) (field i64))))
  (type $h (struct (field (ref $s))))
  (global $g (ref $h) (struct.new $h (struct.new $t (i32.const 41) (i64.const 2))))
  (func (export "test") (result i32)
    (i32.add (struct.get $s 0 (struct.get $h 0 (global.get $g))) (i32.const 1))))
