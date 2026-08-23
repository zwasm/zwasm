;; Wasm 3.0 function-references `ref.as_non_null` is an IDENTITY on the
;; operand stack: both emitters pop the source vreg, null-check it, and push
;; the SAME vreg back (no result vreg, no MOV). Liveness must model that as
;; transparent, or it closes the operand's live range and fabricates a result
;; vreg nothing ever writes — and the register allocator hands the operand's
;; register to the next value while the narrowed ref is still live. The JIT
;; then returns a silently wrong i32: no trap, no diagnostic, exit 0.
;;
;; Every case here keeps the `ref.as_non_null` result alive ACROSS at least
;; one further allocation. A single consumer of the result is always correct
;; (the operand is dead by then), which is why the spec corpus misses this:
;; `function-references/ref_as_non_null.wast` consumes every result in the
;; very next instruction (`call_ref $t (ref.as_non_null ...)`).
;;
;; Stress axes (test_discipline.md §1): the value that outlives the narrowed
;; ref (unrelated i32 local / a second field read of the ref itself) x the
;; source of the nullable ref (direct `struct.new` / mutable nullable global
;; / `array.get` of a nullable-element array).
;;
;; $a is the sharpest: it corrupts an i32 LOCAL, which shows the defect is in
;; register assignment and not in `struct.get`. Pre-fix the JIT returned 42
;; for it — `local.get $k` yielded the `i32.const 2` that fed `struct.new`.
;;
;; Provenance: hand-written reduction of issue #245 (the MoonBit wasm-gc
;; recursive-struct walk it came from returned 0 instead of 140);
;; wasm-tools parse. Interp and wasmtime 47.0.3 both give 1131.
(module
  (type $pt (struct (field $x i32) (field $y i32)))
  (type $arr (array (mut (ref null $pt))))

  (global $g (mut (ref null $pt)) (ref.null $pt))

  ;; A. the narrowed ref outlives an UNRELATED i32 local.
  (func $a (result i32) (local $p (ref $pt)) (local $k i32)
    (local.set $k (i32.const 1000))
    (local.set $p (ref.as_non_null (struct.new $pt (i32.const 40) (i32.const 2))))
    (i32.add (local.get $k) (struct.get $pt $x (local.get $p))))    ;; 1040

  ;; B. two field reads of the same narrowed ref — the ref outlives the
  ;;    first `struct.get`'s result.
  (func $b (result i32) (local $p (ref $pt))
    (local.set $p (ref.as_non_null (struct.new $pt (i32.const 40) (i32.const 2))))
    (i32.add (struct.get $pt $x (local.get $p))
             (struct.get $pt $y (local.get $p))))                   ;; 42

  ;; C. same shape, nullable ref sourced from a mutable global.
  (func $c (result i32) (local $p (ref $pt))
    (global.set $g (struct.new $pt (i32.const 40) (i32.const 2)))
    (local.set $p (ref.as_non_null (global.get $g)))
    (i32.add (struct.get $pt $x (local.get $p))
             (struct.get $pt $y (local.get $p))))                   ;; 42

  ;; D. same shape, nullable ref sourced from an array element.
  (func $d (result i32) (local $v (ref $arr)) (local $p (ref $pt))
    (local.set $v (array.new_fixed $arr 2
      (struct.new $pt (i32.const 3) (i32.const 4))
      (struct.new $pt (i32.const 5) (i32.const 6))))
    (local.set $p (ref.as_non_null (array.get $arr (local.get $v) (i32.const 0))))
    (i32.add (struct.get $pt $x (local.get $p))
             (struct.get $pt $y (local.get $p))))                   ;; 7

  (func (export "test") (result i32)
    (i32.add (i32.add (call $a) (call $b))
             (i32.add (call $c) (call $d)))))                       ;; 1131
