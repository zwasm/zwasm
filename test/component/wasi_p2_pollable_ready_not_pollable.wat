;; `[method]pollable.ready` given the stdin input-stream handle (#519): the
;; handle exists but is not a pollable, so the call traps. The host's
;; TypeMismatch is not a trap name; before #519 it aborted the process.
(component
  (import "wasi:io/poll@0.2.0" (instance $poll
    (export "pollable" (type $pollable (sub resource)))
    (type $borrow-p (borrow $pollable))
    (export "[method]pollable.ready" (func (param "self" $borrow-p) (result bool)))))

  (import "wasi:io/streams@0.2.0" (instance $streams
    (export "input-stream" (type $istream (sub resource)))))
  (alias export $streams "input-stream" (type $istream))

  (import "wasi:cli/stdin@0.2.0" (instance $stdin
    (alias outer 1 $istream (type $is-in))
    (export "input-stream" (type $is-ex (eq $is-in)))
    (type $own-is (own $is-ex))
    (export "get-stdin" (func (result $own-is)))))

  (core func $getstdin (canon lower (func $stdin "get-stdin")))
  (core func $ready (canon lower (func $poll "[method]pollable.ready")))

  (core module $M
    (import "io" "get-stdin" (func $getstdin (result i32)))
    (import "io" "ready" (func $ready (param i32) (result i32)))
    (func (export "run") (result i32)
      (drop (call $ready (call $getstdin)))
      (i32.const 0)))

  (core instance $deps (export "get-stdin" (func $getstdin))
                       (export "ready" (func $ready)))
  (core instance $m (instantiate $M (with "io" (instance $deps))))

  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $run-inst))
)
