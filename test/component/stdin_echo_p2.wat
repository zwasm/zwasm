;; Component twin of `test/wasi/stdin_echo.wat` for `zig build test-cli-stdin`
;; (#508): blocking-reads fd 0 through wasi:cli/stdin + wasi:io/streams until
;; the stream closes, writes every chunk to stdout, then returns ok (exit 0).
;; Hand-written; `wasm-tools parse` + `validate --features component-model`.
(component
  (import "wasi:io/error@0.2.0" (instance $io-error
    (export "error" (type (sub resource)))))
  (alias export $io-error "error" (type $error))

  (import "wasi:io/streams@0.2.0" (instance $io-streams
    (alias outer 1 $error (type $error-in))
    (export "error" (type $error-ex (eq $error-in)))
    (export "input-stream" (type $input-stream (sub resource)))
    (export "output-stream" (type $output-stream (sub resource)))
    (type $stream-error-def (variant (case "last-operation-failed" (own $error-ex)) (case "closed")))
    (export "stream-error" (type $stream-error (eq $stream-error-def)))
    (type $borrow-is (borrow $input-stream))
    (type $borrow-os (borrow $output-stream))
    (type $list-u8 (list u8))
    (export "[method]input-stream.blocking-read"
      (func (param "self" $borrow-is) (param "len" u64) (result (result $list-u8 (error $stream-error)))))
    (export "[method]output-stream.blocking-write-and-flush"
      (func (param "self" $borrow-os) (param "contents" $list-u8) (result (result (error $stream-error)))))))
  (alias export $io-streams "input-stream" (type $input-stream))
  (alias export $io-streams "output-stream" (type $output-stream))

  (import "wasi:cli/stdin@0.2.0" (instance $cli-stdin
    (alias outer 1 $input-stream (type $is-in))
    (export "input-stream" (type (eq $is-in)))
    (type $own-is (own $is-in))
    (export "get-stdin" (func (result $own-is)))))
  (import "wasi:cli/stdout@0.2.0" (instance $cli-stdout
    (alias outer 1 $output-stream (type $os-out))
    (export "output-stream" (type (eq $os-out)))
    (type $own-os (own $os-out))
    (export "get-stdout" (func (result $own-os)))))

  ;; memory + a cabi_realloc that hands out one fixed 32 KiB buffer for the
  ;; list<u8> each read returns (consumed by the write before the next read)
  (core module $libc
    (memory (export "memory") 1)
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      (i32.const 8192)))
  (core instance $libc (instantiate $libc))

  (core func $get-stdin (canon lower (func $cli-stdin "get-stdin")))
  (core func $get-stdout (canon lower (func $cli-stdout "get-stdout")))
  (core func $read (canon lower (func $io-streams "[method]input-stream.blocking-read")
    (memory $libc "memory") (realloc (func $libc "cabi_realloc"))))
  (core func $write (canon lower (func $io-streams "[method]output-stream.blocking-write-and-flush")
    (memory $libc "memory")))
  (core func $drop-is (canon resource.drop $input-stream))
  (core func $drop-os (canon resource.drop $output-stream))

  (core module $M
    (import "io" "get-stdin" (func $get-stdin (result i32)))
    (import "io" "get-stdout" (func $get-stdout (result i32)))
    ;; blocking-read(self, len:i64, retptr) → result<list<u8>, stream-error>: disc@0, ptr@4, len@8
    (import "io" "read" (func $read (param i32 i64 i32)))
    ;; blocking-write-and-flush(self, ptr, len, retptr)
    (import "io" "write" (func $write (param i32 i32 i32 i32)))
    (import "io" "drop-is" (func $drop-is (param i32)))
    (import "io" "drop-os" (func $drop-os (param i32)))
    (import "libc" "memory" (memory 1))
    (func (export "run") (result i32)
      (local $in i32) (local $out i32)
      (local.set $in (call $get-stdin))
      (local.set $out (call $get-stdout))
      (loop $again
        (call $read (local.get $in) (i64.const 32768) (i32.const 128))
        (if (i32.eqz (i32.load8_u (i32.const 128)))              ;; ok(list) — err is the closed stream
          (then
            (call $write (local.get $out) (i32.load (i32.const 132)) (i32.load (i32.const 136)) (i32.const 144))
            (br $again))))
      (call $drop-is (local.get $in))
      (call $drop-os (local.get $out))
      (i32.const 0)))

  (core instance $deps (export "get-stdin" (func $get-stdin))
                       (export "get-stdout" (func $get-stdout))
                       (export "read" (func $read))
                       (export "write" (func $write))
                       (export "drop-is" (func $drop-is))
                       (export "drop-os" (func $drop-os)))
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
