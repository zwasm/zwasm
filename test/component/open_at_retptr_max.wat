;; `wasi:filesystem/types` `[method]descriptor.open-at` on a preopen with
;; retptr 0xFFFF_FFFE: the result payload's address, retptr + 4, does not fit
;; in u32, so the call traps as the store of that result would.
(component
  (import "wasi:filesystem/types@0.2.0" (instance $types
    (export "descriptor" (type $descriptor (sub resource)))
    (type $err-def (enum "access" "would-block"))
    (export "error-code" (type $error-code (eq $err-def)))
    (type $of-def (flags "create" "directory" "exclusive" "truncate"))
    (export "open-flags" (type $open-flags (eq $of-def)))
    (type $pf-def (flags "symlink-follow"))
    (export "path-flags" (type $path-flags (eq $pf-def)))
    (type $df-def (flags "read" "write"))
    (export "descriptor-flags" (type $descriptor-flags (eq $df-def)))
    (type $borrow-desc (borrow $descriptor))
    (type $own-desc (own $descriptor))
    (export "[method]descriptor.open-at"
      (func (param "self" $borrow-desc) (param "path-flags" $path-flags) (param "path" string)
            (param "open-flags" $open-flags) (param "flags" $descriptor-flags)
            (result (result $own-desc (error $error-code)))))))
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

  (core func $getdirs
    (canon lower (func $preopens "get-directories")
      (memory (core memory $libc "memory")) (realloc (core func $libc "cabi_realloc"))))
  (core func $openat
    (canon lower (func $types "[method]descriptor.open-at")
      (memory (core memory $libc "memory")) (realloc (core func $libc "cabi_realloc"))))

  (core module $M
    (import "fs" "get-directories" (func $getdirs (param i32)))
    (import "fs" "open-at" (func $openat (param i32 i32 i32 i32 i32 i32 i32)))
    (import "libc" "memory" (memory 1))
    (data (i32.const 16) "out.txt")
    (func (export "run") (result i32)
      (call $getdirs (i32.const 256))
      ;; open-at(dir, path-flags=0, path=16, len=7, open-flags=CREAT=1, flags=0, retptr)
      (call $openat (i32.load (i32.load (i32.const 256)))
        (i32.const 0) (i32.const 16) (i32.const 7) (i32.const 1) (i32.const 0) (i32.const 0xFFFFFFFE))
      (i32.const 0)))

  (core instance $deps (export "get-directories" (func $getdirs))
                       (export "open-at" (func $openat)))
  (core instance $m (instantiate $M
    (with "fs" (instance $deps))
    (with "libc" (instance $libc))))

  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $run-inst)))
