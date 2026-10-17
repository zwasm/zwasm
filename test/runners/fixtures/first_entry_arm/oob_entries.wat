;; #302 boundary: every entry point that bypasses `invokeAndCheck`, in one
;; module. Each export loads at 65533 (eff_addr 65537 > the 65536-byte memory),
;; which guard-page bounds elision (ADR-0202 D4) turns into a hardware fault —
;; so whichever entry a process reaches FIRST must have armed the handler and
;; published `stack_limit`, or the guest's oob access kills the process.
(module
  (memory 1)
  ;; Production multi-result path (ADR-0106 wrapper thunk → invokeBufferWrite).
  (func (export "multi3") (result i32 i32 i32)
    i32.const 65533
    i32.load
    i32.const 2
    i32.const 3)
  ;; The three inline-asm mixed multi-result thunks.
  (func (export "i32f64") (result i32 f64)
    i32.const 65533
    i32.load
    drop
    i32.const 7
    f64.const 1.5)
  (func (export "f64i32") (result f64 i32)
    i32.const 65533
    i32.load
    drop
    f64.const 1.5
    i32.const 7)
  (func (export "f64f32") (result f64 f32)
    i32.const 65533
    i32.load
    drop
    f64.const 1.5
    f32.const 2.5)
  ;; The stack-limit half of the preamble: no bounds check and no guard page —
  ;; only the prologue probe (fed by `stack_limit`) stops this recursion.
  (func $rec (export "rec_i32f64") (result i32 f64)
    call $rec))
