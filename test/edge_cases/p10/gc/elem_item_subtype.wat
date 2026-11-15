;; #285 item 4 acceptance half: an element item that is a proper subtype of
;; the segment's type — `ref.func $seven`, a `(ref $f)`, in a `(ref null $f)`
;; segment — still validates and runs once each item is typed against the
;; segment (Wasm 3.0 §3.4.9 `check_elem`). wasm-tools accepts.
;;
;; Provenance: hand-written for the #285 item 4 fix. The reject half lives in
;; runner_const_expr_test.zig — this runner has no reject expectation form.
(module
  (type $f (func (result i32)))
  (func $seven (type $f) (i32.const 7))
  (table $t 1 (ref null $f))
  (elem (table $t) (i32.const 0) (ref null $f) (item ref.func $seven))
  (func (export "test") (result i32)
    (call_ref $f (table.get $t (i32.const 0)))))
