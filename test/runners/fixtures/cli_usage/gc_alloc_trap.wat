;; #364 — a GC allocation whose size passes the GC heap's 4 GiB cap must trap
;; out_of_memory at the allocating instruction, on the JIT as on the interp.
;; Each export asks for a ~8 GiB array (0x7fffffff elements x 4 bytes), so the
;; alloc fails; the trailing (i32.const 42) must never run. Only array.new* can
;; overshoot the cap in a SINGLE allocation (a runtime length), so those are the
;; cheap ones to exercise; struct.new* / array.new_fixed share the same
;; zero-check and it is equally load-bearing — a guest that fills the heap makes
;; their next alloc fail too — that path is just not cheap to drive in a fixture.
(module
  (type $a (array (mut i32)))
  ;; array.new_default -> jitGcAllocArray
  (func (export "array_new_default") (result i32)
    (drop (array.new_default $a (i32.const 0x7fffffff)))
    (i32.const 42))
  ;; array.new -> jitGcAllocArrayFill
  (func (export "array_new") (result i32)
    (drop (array.new $a (i32.const 0) (i32.const 0x7fffffff)))
    (i32.const 42)))
