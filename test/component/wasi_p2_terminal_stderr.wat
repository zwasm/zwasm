;; WASI Preview 2 terminal-stderr component (#507): get-terminal-stderr must be
;; some — the test points fd 2 at a pty before running it — and the handle must
;; drop cleanly; a `none` traps (unreachable). Hand-written; built with
;; `wasm-tools parse` + `wasm-tools validate --features component-model`.
(component
  (import "wasi:cli/terminal-output@0.2.0" (instance $tout
    (export "terminal-output" (type $terminal-output (sub resource)))))
  (alias export $tout "terminal-output" (type $terminal-output))
  (import "wasi:cli/terminal-stderr@0.2.0" (instance $tstderr
    (alias outer 1 $terminal-output (type $to-in))
    (export "terminal-output" (type $to-ex (eq $to-in)))
    (type $own-to (own $to-ex))
    (export "get-terminal-stderr" (func (result (option $own-to))))))

  (core module $libc
    (memory (export "memory") 1))
  (core instance $libc (instantiate $libc))

  (core func $getterm (canon lower (func $tstderr "get-terminal-stderr") (memory $libc "memory")))
  (core func $dropterm (canon resource.drop $terminal-output))

  (core module $M
    (import "io" "get-terminal-stderr" (func $getterm (param i32)))
    (import "io" "drop-terminal" (func $dropterm (param i32)))
    (import "libc" "memory" (memory 1))
    (func (export "run") (result i32)
      (call $getterm (i32.const 16))                                     ;; option<own<terminal-output>> at 16
      (if (i32.eqz (i32.load8_u (i32.const 16))) (then (unreachable)))   ;; none → trap
      (call $dropterm (i32.load (i32.const 20)))                          ;; drop the owned handle
      (i32.const 0)))

  (core instance $deps (export "get-terminal-stderr" (func $getterm))
                       (export "drop-terminal" (func $dropterm)))
  (core instance $m (instantiate $M
    (with "io" (instance $deps))
    (with "libc" (instance $libc))))

  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $run-inst))
)
