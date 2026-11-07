;; A top-level `run: func()` and no `wasi:cli/run`: `zwasm run` runs it and
;; exits 0 (#677).
(component
  (core module $m (func (export "run")))
  (core instance $i (instantiate $m))
  (func (export "run") (canon lift (core func $i "run"))))
