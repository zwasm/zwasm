;; A sync `wasi:cli/run` whose `run` returns ok, next to an unrelated async
;; export `tick` that traps. Running the command must not call `tick` (#677).
(component
  (core module $m
    (func (export "run") (result i32) (i32.const 0))
    (func (export "tick") (result i32) unreachable)
    (func (export "tick-cb") (param i32 i32 i32) (result i32) (i32.const 0)))
  (core instance $i (instantiate $m))
  (func $run (result (result)) (canon lift (core func $i "run")))
  (instance $run-inst (export "run" (func $run)))
  (export "wasi:cli/run@0.2.0" (instance $run-inst))
  (func (export "tick") async
    (canon lift (core func $i "tick") async (callback (core func $i "tick-cb")))))
