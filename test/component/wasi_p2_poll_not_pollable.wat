;; `poll([stdin])` with the stdin input-stream handle in the list (#519): the
;; handle exists but is not a pollable, so the call traps, as `ready` and
;; `block` do. Before #519 `poll` counted it ready and the guest exited 0.
(component
  (import "wasi:io/poll@0.2.0" (instance $poll
    (export "pollable" (type $pollable (sub resource)))
    (type $borrow-p (borrow $pollable))
    (type $list-borrow (list $borrow-p))
    (type $list-u32 (list u32))
    (export "poll" (func (param "in" $list-borrow) (result $list-u32)))))

  (import "wasi:io/streams@0.2.0" (instance $streams
    (export "input-stream" (type $istream (sub resource)))))
  (alias export $streams "input-stream" (type $istream))

  (import "wasi:cli/stdin@0.2.0" (instance $stdin
    (alias outer 1 $istream (type $is-in))
    (export "input-stream" (type $is-ex (eq $is-in)))
    (type $own-is (own $is-ex))
    (export "get-stdin" (func (result $own-is)))))

  (core module $libc
    (memory (export "memory") 1)
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      (i32.const 1024)))
  (core instance $libc (instantiate $libc))
  (alias core export $libc "cabi_realloc" (core func $cabi_realloc))

  (core func $getstdin (canon lower (func $stdin "get-stdin")))
  (core func $pollfn (canon lower (func $poll "poll") (memory $libc "memory") (realloc $cabi_realloc)))

  (core module $M
    (import "io" "get-stdin" (func $getstdin (result i32)))
    (import "io" "poll" (func $pollfn (param i32 i32 i32)))
    (import "libc" "memory" (memory 1))
    (func (export "run") (result i32)
      ;; list<borrow<pollable>> [stdin] at 64; list<u32> ret@256
      (i32.store (i32.const 64) (call $getstdin))
      (call $pollfn (i32.const 64) (i32.const 1) (i32.const 256))
      (i32.const 0)))

  (core instance $deps (export "get-stdin" (func $getstdin))
                       (export "poll" (func $pollfn)))
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
