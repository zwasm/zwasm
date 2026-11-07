;; A top-level `run` that takes a parameter is not a command entry: `zwasm run`
;; refuses it with the exports listed, and `--invoke run=N` calls it (#677).
(component
  (core module $m (func (export "run") (param i32) (result i32) (local.get 0)))
  (core instance $i (instantiate $m))
  (func (export "run") (param "x" u32) (result u32) (canon lift (core func $i "run"))))
