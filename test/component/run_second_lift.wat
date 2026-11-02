;; Lifts `add` before `run`, and exports `run` only through `wasi:cli/run@0.2.0`:
;; the command entry is the export by name, not the first `canon lift` (#622).
(component
  (core module $M
    (func (export "add") (param i32 i32) (result i32)
      (i32.add (local.get 0) (local.get 1)))
    (func (export "run") (result i32) (i32.const 0)))
  (core instance $m (instantiate $M))
  (func $add (param "a" u32) (param "b" u32) (result u32) (canon lift (core func $m "add")))
  (func $run (result (result)) (canon lift (core func $m "run")))
  (instance $run-inst (export "run" (func $run)))
  (export "add" (func $add))
  (export "wasi:cli/run@0.2.0" (instance $run-inst)))
