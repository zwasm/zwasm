;; #504 — a core module's wasi_snapshot_preview1 imports are satisfied by a
;; `with` arg (the shape wit-component's preview1 adapter produces), so the
;; Linker must bind the poured entries rather than ask a WASI host it lacks.
(component
  (core module $adapter
    (func (export "random_get") (param i32 i32) (result i32) (i32.const 0)))
  (core instance $a (instantiate $adapter))
  (core module $main
    (import "wasi_snapshot_preview1" "random_get" (func (param i32 i32) (result i32)))
    (func (export "f") (result i32) (i32.const 7)))
  (core instance $m (instantiate $main (with "wasi_snapshot_preview1" (instance $a))))
)
