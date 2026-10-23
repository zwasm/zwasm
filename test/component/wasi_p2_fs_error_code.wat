;; WASI 0.2 `wasi:filesystem/types` `filesystem-error-code(err: borrow<error>)`
;; -> option<error-code>, lowered to a core (i32 err, i32 retptr)->() (the
;; fs_filesystem_error_code trampoline). This host never mints an error
;; carrying a filesystem code, so the answer is `none`: discriminant 0 at
;; retptr. The return area is filled with 0xFF first; run() exits 0 iff the
;; byte at retptr is 0, else exit(1).
(component
  (import "wasi:io/error@0.2.0" (instance $io-error
    (export "error" (type (sub resource)))))
  (alias export $io-error "error" (type $error))
  (import "wasi:filesystem/types@0.2.0" (instance $types
    (alias outer 1 $error (type $error-in))
    (export "error" (type $error-ex (eq $error-in)))
    (type $err-def (enum "access" "would-block" "already"))
    (export "error-code" (type $error-code (eq $err-def)))
    (type $borrow-error (borrow $error-ex))
    (type $opt-code (option $error-code))
    (export "filesystem-error-code" (func (param "err" $borrow-error) (result $opt-code)))))
  (import "wasi:cli/exit@0.2.0" (instance $cli-exit
    (export "exit" (func (param "status" (result))))))

  (core module $libc (memory (export "memory") 1))
  (core instance $libc (instantiate $libc))
  (core func $fec (canon lower (func $types "filesystem-error-code") (memory (core memory $libc "memory"))))
  (core func $exit (canon lower (func $cli-exit "exit")))

  (core module $M
    (import "io" "fec" (func $fec (param i32 i32)))   ;; (err handle, retptr)
    (import "io" "exit" (func $exit (param i32)))
    (import "libc" "memory" (memory 1))
    (func (export "run") (result i32)
      (memory.fill (i32.const 16) (i32.const 0xFF) (i32.const 8))
      (call $fec (i32.const 1) (i32.const 16))
      (if (i32.eqz (i32.load8_u (i32.const 16)))      ;; option disc @ retptr
        (then (call $exit (i32.const 0)))
        (else (call $exit (i32.const 1))))
      (i32.const 0)))

  (core instance $deps-io (export "fec" (func $fec)) (export "exit" (func $exit)))
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
