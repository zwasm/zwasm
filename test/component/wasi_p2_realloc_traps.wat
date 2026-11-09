;; `wasi_p2_random.wat` with a `cabi_realloc` that traps (#550). The
;; get-random-bytes trampoline allocates its list result through the guest's
;; cabi_realloc (a nested invoke); that invoke executes `unreachable`, so the run
;; fails with the guest's own trap, `Unreachable`, not the host's `HostTrap`.
(component
  (import "wasi:random/random@0.2.0" (instance $random
    (export "get-random-bytes" (func (param "len" u64) (result (list u8))))))
  (import "wasi:cli/exit@0.2.0" (instance $cli-exit
    (export "exit" (func (param "status" (result))))))

  ;; libc: memory + a cabi_realloc that traps.
  (core module $libc
    (memory (export "memory") 1)
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      unreachable))
  (core instance $libc (instantiate $libc))
  (alias core export $libc "cabi_realloc" (core func $cabi_realloc))

  (core func $rand
    (canon lower (func $random "get-random-bytes") (memory (core memory $libc "memory")) (realloc $cabi_realloc)))
  (core func $exit (canon lower (func $cli-exit "exit")))

  (core module $M
    (import "io" "rand" (func $rand (param i64 i32)))   ;; (len, retptr)
    (import "io" "exit" (func $exit (param i32)))
    (import "libc" "memory" (memory 1))
    (func (export "run") (result i32)
      (local $ptr i32) (local $len i32) (local $i i32) (local $acc i32)
      (call $rand (i64.const 16) (i32.const 16))        ;; retptr=16: ptr@16, len@20
      (local.set $ptr (i32.load (i32.const 16)))
      (local.set $len (i32.load (i32.const 20)))
      (block $done
        (loop $loop
          (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
          (local.set $acc (i32.or (local.get $acc)
            (i32.load8_u (i32.add (local.get $ptr) (local.get $i)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $loop)))
      (if (i32.and (i32.ne (local.get $acc) (i32.const 0)) (i32.eq (local.get $len) (i32.const 16)))
        (then (call $exit (i32.const 0)))
        (else (call $exit (i32.const 1))))
      (i32.const 0)))

  (core instance $deps-io (export "rand" (func $rand)) (export "exit" (func $exit)))
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
