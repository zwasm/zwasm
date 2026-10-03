;; WASI Preview 2 cli/environment + terminal + check-write component (E2 step 4).
;; A sandboxed always-writable host: get-environment/get-arguments are empty,
;; initial-cwd is none, get-terminal-stdout is none because the test hands the
;; host a capture buffer rather than a terminal (#507), output-stream.check-write
;; reports a permit. Each result is asserted; a mismatch traps (unreachable).
(component
  ;; ---- wasi:cli/environment ----
  (import "wasi:cli/environment@0.2.0" (instance $env
    (type $str-tup (tuple string string))
    (type $env-list (list $str-tup))
    (type $arg-list (list string))
    (type $opt-str (option string))
    (export "get-environment" (func (result $env-list)))
    (export "get-arguments" (func (result $arg-list)))
    (export "initial-cwd" (func (result $opt-str)))))

  ;; ---- wasi:io/streams (output-stream + check-write) ----
  (import "wasi:io/streams@0.2.0" (instance $streams
    (export "output-stream" (type $ostream (sub resource)))
    (type $se-def (variant (case "last-operation-failed") (case "closed")))
    (export "stream-error" (type $stream-error (eq $se-def)))
    (type $borrow-os (borrow $ostream))
    (export "[method]output-stream.check-write"
      (func (param "self" $borrow-os) (result (result u64 (error $stream-error)))))))
  (alias export $streams "output-stream" (type $ostream))

  ;; ---- wasi:cli/stdout ----
  (import "wasi:cli/stdout@0.2.0" (instance $stdout
    (alias outer 1 $ostream (type $os-in))
    (export "output-stream" (type $os-ex (eq $os-in)))
    (type $own-os (own $os-ex))
    (export "get-stdout" (func (result $own-os)))))

  ;; ---- wasi:cli/terminal-output + terminal-stdout ----
  (import "wasi:cli/terminal-output@0.2.0" (instance $tout
    (export "terminal-output" (type $terminal-output (sub resource)))))
  (alias export $tout "terminal-output" (type $terminal-output))
  (import "wasi:cli/terminal-stdout@0.2.0" (instance $tstdout
    (alias outer 1 $terminal-output (type $to-in))
    (export "terminal-output" (type $to-ex (eq $to-in)))
    (type $own-to (own $to-ex))
    (export "get-terminal-stdout" (func (result (option $own-to))))))

  ;; ---- libc: memory + bump cabi_realloc ----
  (core module $libc
    (memory (export "memory") 1)
    (global $bump (mut i32) (i32.const 1024))
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      (local $p i32)
      (local.set $p (global.get $bump))
      (global.set $bump (i32.add (global.get $bump) (local.get 3)))
      (local.get $p)))
  (core instance $libc (instantiate $libc))
  (alias core export $libc "cabi_realloc" (core func $cabi_realloc))

  ;; ---- lower imported component funcs ----
  (core func $getenv (canon lower (func $env "get-environment") (memory $libc "memory") (realloc $cabi_realloc)))
  (core func $getargs (canon lower (func $env "get-arguments") (memory $libc "memory") (realloc $cabi_realloc)))
  (core func $getcwd (canon lower (func $env "initial-cwd") (memory $libc "memory") (realloc $cabi_realloc)))
  (core func $getstdout (canon lower (func $stdout "get-stdout")))
  (core func $checkwrite (canon lower (func $streams "[method]output-stream.check-write") (memory $libc "memory")))
  (core func $getterm (canon lower (func $tstdout "get-terminal-stdout") (memory $libc "memory")))
  (core func $dropos (canon resource.drop $ostream))

  ;; ---- core driver ----
  (core module $M
    (import "io" "get-environment" (func $getenv (param i32)))
    (import "io" "get-arguments" (func $getargs (param i32)))
    (import "io" "initial-cwd" (func $getcwd (param i32)))
    (import "io" "get-stdout" (func $getstdout (result i32)))
    (import "io" "check-write" (func $checkwrite (param i32 i32)))
    (import "io" "get-terminal-stdout" (func $getterm (param i32)))
    (import "io" "drop-os" (func $dropos (param i32)))
    (import "libc" "memory" (memory 1))
    (func $check (param $cond i32) (if (local.get $cond) (then (unreachable))))
    (func (export "run") (result i32)
      (local $s i32)
      (call $getenv (i32.const 256))
      (call $check (i32.load (i32.const 260)))          ;; environment list len == 0
      (call $getargs (i32.const 264))
      (call $check (i32.load (i32.const 268)))           ;; arguments list len == 0
      (call $getcwd (i32.const 272))
      (call $check (i32.load8_u (i32.const 272)))         ;; initial-cwd option disc == 0 (none)
      (call $getterm (i32.const 280))
      (call $check (i32.load8_u (i32.const 280)))         ;; get-terminal-stdout == none
      (local.set $s (call $getstdout))
      (call $checkwrite (local.get $s) (i32.const 288))
      (call $check (i32.load8_u (i32.const 288)))         ;; check-write result ok
      (call $check (i64.eqz (i64.load (i32.const 296))))  ;; permit > 0
      (call $dropos (local.get $s))
      (i32.const 0)))

  (core instance $deps (export "get-environment" (func $getenv))
                       (export "get-arguments" (func $getargs))
                       (export "initial-cwd" (func $getcwd))
                       (export "get-stdout" (func $getstdout))
                       (export "check-write" (func $checkwrite))
                       (export "get-terminal-stdout" (func $getterm))
                       (export "drop-os" (func $dropos)))
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
