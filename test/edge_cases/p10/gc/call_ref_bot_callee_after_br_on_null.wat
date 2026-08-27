;; `(call_ref $vv (br_on_null $l (unreachable)))` is spec-valid: the
;; callee operand is polymorphic (`.bot`), and br_on_null's fall-through
;; push must keep it that way. The 2026-08-22 prototype of the #249 fix
;; materialised the bot as `.funcref`, and exactly this shape regressed
;; (function-references/br_on_null): funcref is the SUPERtype of
;; `(ref null $vv)`, so the narrowed callee check refused it. wasm-tools
;; accepts; at runtime the block traps on `unreachable` before the call.
;;
;; Stress axes (test_discipline.md §1): validator boundary (call_ref
;; callee subtype) x polymorphic stack (unreachable region) x br_on_null
;; fall-through push.
;;
;; Provenance: hand-written from the minimal check recorded during the
;; 2026-08-22 probe sweep for #249.
(module
  (type $vv (func))
  (func (export "test") (result i32)
    (block $l
      unreachable
      br_on_null $l
      call_ref $vv)
    i32.const 42))
