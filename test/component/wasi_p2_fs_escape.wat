;; WASI Preview 2 filesystem error path for a path that leaves the preopen
;; (#462). Opens a preopen dir, then calls descriptor.stat-at on "../x": the
;; host's lexical confinement answers P1 `notcapable`, which the trampoline must
;; write as result.err(error-code::not-permitted). The guest asserts the result
;; discriminant is `err` and the error-code ordinal is 31 (not-permitted, not
;; io = 13); a mismatch traps (unreachable).
(component
  (import "wasi:filesystem/types@0.2.0" (instance $types
    (export "descriptor" (type $descriptor (sub resource)))
    ;; error-code declared in full so the fixture can name not-permitted (31).
    (type $err-def (enum "access" "would-block" "already" "bad-descriptor" "busy"
                         "deadlock" "quota" "exist" "file-too-large"
                         "illegal-byte-sequence" "in-progress" "interrupted"
                         "invalid" "io" "is-directory" "loop" "too-many-links"
                         "message-size" "name-too-long" "no-device" "no-entry"
                         "no-lock" "insufficient-memory" "insufficient-space"
                         "not-directory" "not-empty" "not-recoverable"
                         "unsupported" "no-tty" "no-such-device" "overflow"
                         "not-permitted" "pipe" "read-only" "invalid-seek"
                         "text-file-busy" "cross-device"))
    (export "error-code" (type $error-code (eq $err-def)))
    (type $pf-def (flags "symlink-follow"))
    (export "path-flags" (type $path-flags (eq $pf-def)))
    (type $dt-def (enum "unknown" "block-device" "character-device" "directory"
                        "fifo" "symbolic-link" "regular-file" "socket"))
    (export "descriptor-type" (type $descriptor-type (eq $dt-def)))
    (type $datetime-def (record (field "seconds" u64) (field "nanoseconds" u32)))
    (export "datetime" (type $datetime (eq $datetime-def)))
    (type $dstat-def (record (field "type" $descriptor-type) (field "link-count" u64)
                             (field "size" u64) (field "data-access-timestamp" (option $datetime))
                             (field "data-modification-timestamp" (option $datetime))
                             (field "status-change-timestamp" (option $datetime))))
    (export "descriptor-stat" (type $descriptor-stat (eq $dstat-def)))
    (type $borrow-desc (borrow $descriptor))
    (export "[method]descriptor.stat-at"
      (func (param "self" $borrow-desc) (param "path-flags" $path-flags) (param "path" string)
            (result (result $descriptor-stat (error $error-code)))))))
  (alias export $types "descriptor" (type $descriptor))

  (import "wasi:filesystem/preopens@0.2.0" (instance $preopens
    (alias outer 1 $descriptor (type $desc-in))
    (export "descriptor" (type $desc-ex (eq $desc-in)))
    (type $own-d (own $desc-ex))
    (type $tup (tuple $own-d string))
    (type $dirlist (list $tup))
    (export "get-directories" (func (result $dirlist)))))

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

  (core func $getdirs
    (canon lower (func $preopens "get-directories") (memory $libc "memory") (realloc $cabi_realloc)))
  (core func $statat
    (canon lower (func $types "[method]descriptor.stat-at") (memory $libc "memory") (realloc $cabi_realloc)))

  (core module $M
    (import "fs" "get-directories" (func $getdirs (param i32)))
    (import "fs" "stat-at" (func $statat (param i32 i32 i32 i32 i32)))
    (import "libc" "memory" (memory 1))
    (data (i32.const 16) "../x")
    (func $check (param $cond i32) (if (local.get $cond) (then (unreachable))))
    (func (export "run") (result i32)
      (local $dir i32)
      (call $getdirs (i32.const 256))
      (local.set $dir (i32.load (i32.load (i32.const 256))))
      ;; stat-at(dir, pf=0, path=16 "../x" len=4, ret=288); the result's
      ;; payload is align 8 (descriptor-stat holds u64s), so error-code is at +8.
      (call $statat (local.get $dir) (i32.const 0) (i32.const 16) (i32.const 4) (i32.const 288))
      (call $check (i32.ne (i32.load8_u (i32.const 288)) (i32.const 1)))   ;; result disc == err
      (call $check (i32.ne (i32.load8_u (i32.const 296)) (i32.const 31)))  ;; error-code == not-permitted
      (i32.const 0)))

  (core instance $deps (export "get-directories" (func $getdirs))
                       (export "stat-at" (func $statat)))
  (core instance $m (instantiate $M
    (with "fs" (instance $deps))
    (with "libc" (instance $libc))))

  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $run-inst))
)
