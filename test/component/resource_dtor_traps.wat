;; A guest resource whose destructor traps (#550). run() mints an OWN handle with
;; `canon resource.new` and drops it with `canon resource.drop`, which runs the
;; declared destructor over the rep; the destructor executes `unreachable`, so the
;; run fails with the guest's own trap, `Unreachable`, not the host's `HostTrap`.
(component
  (core module $Dtor
    (func (export "dtor") (param i32)
      unreachable))
  (core instance $d (instantiate $Dtor))
  (alias core export $d "dtor" (core func $dtor))

  (type $R (resource (rep i32) (dtor (core func $dtor))))
  (core func $new (canon resource.new $R))
  (core func $drop (canon resource.drop $R))

  (core module $M
    (import "r" "new" (func $new (param i32) (result i32)))
    (import "r" "drop" (func $drop (param i32)))
    (func (export "run") (result i32)
      (call $drop (call $new (i32.const 42)))
      (i32.const 0)))
  (core instance $deps (export "new" (func $new)) (export "drop" (func $drop)))
  (core instance $m (instantiate $M (with "r" (instance $deps))))

  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $run-inst))
)
