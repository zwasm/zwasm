;; WASI 0.2 `wasi:clocks/wall-clock` `resolution()` -> datetime{seconds: u64,
;; nanoseconds: u32}, lowered to a core (i32 retptr)->() that writes the
;; 12-byte record at retptr (the clocks_wall_resolution trampoline). The
;; return area is filled with 0xAA first, so a write at the wrong offset
;; leaves a sentinel behind. run() exits 0 iff seconds@+0 < 2^32 and
;; nanoseconds@+8 < 1e9 (both below the 0xAA.. sentinel), else exit(1).
(component
  (import "wasi:clocks/wall-clock@0.2.0" (instance $wall
    (type $datetime-def (record (field "seconds" u64) (field "nanoseconds" u32)))
    (export "datetime" (type $datetime (eq $datetime-def)))
    (export "resolution" (func (result $datetime)))))
  (import "wasi:cli/exit@0.2.0" (instance $cli-exit
    (export "exit" (func (param "status" (result))))))

  (core module $libc (memory (export "memory") 1))
  (core instance $libc (instantiate $libc))
  (core func $res (canon lower (func $wall "resolution") (memory (core memory $libc "memory"))))
  (core func $exit (canon lower (func $cli-exit "exit")))

  (core module $M
    (import "io" "res" (func $res (param i32)))
    (import "io" "exit" (func $exit (param i32)))
    (import "libc" "memory" (memory 1))
    (func (export "run") (result i32)
      (memory.fill (i32.const 16) (i32.const 0xAA) (i32.const 16))
      (call $res (i32.const 16))
      (if (i32.and
            (i64.lt_u (i64.load (i32.const 16)) (i64.const 0x100000000))   ;; seconds @ +0
            (i32.lt_u (i32.load (i32.const 24)) (i32.const 1000000000)))   ;; nanoseconds @ +8
        (then (call $exit (i32.const 0)))
        (else (call $exit (i32.const 1))))
      (i32.const 0)))

  (core instance $deps-io (export "res" (func $res)) (export "exit" (func $exit)))
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
