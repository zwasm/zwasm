;; `[method]output-stream.blocking-write-and-flush` with `contents` at
;; ptr 0x7fff0000, len 16, on a 1-page memory (#535): the guest's buffer lies
;; past the end of memory, so the call traps with the memory trap the access
;; is. Same shape as wasi_p2_hello.wat with the pointer moved out of bounds.
(component
  (import "wasi:io/error@0.2.0" (instance $io-error
    (export "error" (type (sub resource)))))
  (alias export $io-error "error" (type $error))

  (import "wasi:io/streams@0.2.0" (instance $io-streams
    (alias outer 1 $error (type $error-in))
    (export "error" (type $error-ex (eq $error-in)))
    (export "output-stream" (type $output-stream (sub resource)))
    (type $stream-error-def (variant (case "last-operation-failed" (own $error-ex)) (case "closed")))
    (export "stream-error" (type $stream-error (eq $stream-error-def)))
    (type $borrow-os (borrow $output-stream))
    (type $list-u8 (list u8))
    (export "[method]output-stream.blocking-write-and-flush"
      (func (param "self" $borrow-os) (param "contents" $list-u8) (result (result (error $stream-error)))))))
  (alias export $io-streams "output-stream" (type $output-stream))

  (import "wasi:cli/stdout@0.2.0" (instance $cli-stdout
    (alias outer 1 $output-stream (type $os-out))
    (export "output-stream" (type (eq $os-out)))
    (type $own-os (own $os-out))
    (export "get-stdout" (func (result $own-os)))))

  (core func $get-stdout
    (canon lower (func $cli-stdout "get-stdout")))
  (core module $libc (memory (export "memory") 1))
  (core instance $libc (instantiate $libc))
  (core func $write
    (canon lower (func $io-streams "[method]output-stream.blocking-write-and-flush")
      (memory $libc "memory")))

  (core module $M
    (import "io" "get-stdout" (func $get-stdout (result i32)))
    ;; blocking-write-and-flush(self:i32, ptr:i32, len:i32, retptr:i32)
    (import "io" "write" (func $write (param i32 i32 i32 i32)))
    (import "libc" "memory" (memory 1))
    (func (export "run") (result i32)
      (call $write (call $get-stdout) (i32.const 0x7fff0000) (i32.const 16) (i32.const 128))
      (i32.const 0)))

  (core instance $deps-io (export "get-stdout" (func $get-stdout))
                          (export "write" (func $write)))
  (core instance $m (instantiate $M
    (with "io" (instance $deps-io))
    (with "libc" (instance $libc))))

  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $run-inst))
)
