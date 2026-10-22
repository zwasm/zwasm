;; WASI Preview 2 filesystem component pinning the offset range of
;; descriptor.read: after get-directories + open-at "a.txt" (5 bytes, seeded by
;; the host), a read at offset 0 returns the 5 bytes, and a 1-byte read at
;; offset i64::MAX and at u64::MAX each return err(invalid) (12). A mismatch
;; traps (unreachable).
(component
  ;; ---- import wasi:filesystem/types ----
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
    (type $bytes (list u8))
    (type $read-ok (tuple $bytes bool))
    (type $borrow-desc (borrow $descriptor))
    (type $own-desc (own $descriptor))
    (export "[method]descriptor.open-at"
      (func (param "self" $borrow-desc) (param "path-flags" $path-flags) (param "path" string)
            (param "open-flags" $open-flags) (param "flags" $descriptor-flags)
            (result (result $own-desc (error $error-code)))))
    (export "[method]descriptor.read"
      (func (param "self" $borrow-desc) (param "length" u64) (param "offset" u64)
            (result (result $read-ok (error $error-code)))))))
  (alias export $types "descriptor" (type $descriptor))

  ;; ---- import wasi:filesystem/preopens (get-directories) ----
  (import "wasi:filesystem/preopens@0.2.0" (instance $preopens
    (alias outer 1 $descriptor (type $desc-in))
    (export "descriptor" (type $desc-ex (eq $desc-in)))
    (type $own-d (own $desc-ex))
    (type $tup (tuple $own-d string))
    (type $dirlist (list $tup))
    (export "get-directories" (func (result $dirlist)))))

  ;; ---- libc: memory + a bump cabi_realloc ----
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

  ;; ---- lower the imported component funcs to core funcs ----
  (core func $getdirs
    (canon lower (func $preopens "get-directories") (memory (core memory $libc "memory")) (realloc $cabi_realloc)))
  (core func $openat
    (canon lower (func $types "[method]descriptor.open-at") (memory (core memory $libc "memory")) (realloc $cabi_realloc)))
  (core func $read
    (canon lower (func $types "[method]descriptor.read") (memory (core memory $libc "memory")) (realloc $cabi_realloc)))
  (core func $dropdesc
    (canon resource.drop $descriptor))

  ;; ---- core module that drives the reads ----
  (core module $M
    (import "fs" "get-directories" (func $getdirs (param i32)))
    (import "fs" "open-at" (func $openat (param i32 i32 i32 i32 i32 i32 i32)))
    (import "fs" "read" (func $read (param i32 i64 i64 i32)))
    (import "fs" "drop" (func $dropdesc (param i32)))
    (import "libc" "memory" (memory 1))
    (data (i32.const 16) "a.txt")
    (func $check (param $cond i32) (if (local.get $cond) (then (unreachable))))
    ;; read(file, 1, offset, ret) must be err(invalid): disc@ret = 1, error-code@ret+4 = 12
    (func $read_invalid (param $file i32) (param $offset i64) (param $ret i32)
      (call $read (local.get $file) (i64.const 1) (local.get $offset) (local.get $ret))
      (call $check (i32.ne (i32.load8_u (local.get $ret)) (i32.const 1)))
      (call $check (i32.ne (i32.load8_u offset=4 (local.get $ret)) (i32.const 12))))
    (func (export "run") (result i32)
      (local $dir i32) (local $file i32)
      (call $getdirs (i32.const 256))
      (local.set $dir (i32.load (i32.load (i32.const 256))))
      ;; open-at(dir, pf=0, path=16, len=5, oflags=0, dflags=READ=1, ret=288)
      (call $openat (local.get $dir) (i32.const 0) (i32.const 16) (i32.const 5) (i32.const 0) (i32.const 1) (i32.const 288))
      (call $check (i32.load8_u (i32.const 288)))            ;; open-at ok
      (local.set $file (i32.load (i32.const 292)))
      ;; read(file, 5, 0, ret=320): ok, list len@328 = 5
      (call $read (local.get $file) (i64.const 5) (i64.const 0) (i32.const 320))
      (call $check (i32.load8_u (i32.const 320)))
      (call $check (i32.ne (i32.load (i32.const 328)) (i32.const 5)))
      (call $read_invalid (local.get $file) (i64.const 0x7fffffffffffffff) (i32.const 352))
      (call $read_invalid (local.get $file) (i64.const -1) (i32.const 384))
      (call $dropdesc (local.get $file))
      (i32.const 0)))

  (core instance $deps (export "get-directories" (func $getdirs))
                       (export "open-at" (func $openat))
                       (export "read" (func $read))
                       (export "drop" (func $dropdesc)))
  (core instance $m (instantiate $M
    (with "fs" (instance $deps))
    (with "libc" (instance $libc))))

  ;; ---- lift run to wasi:cli/run ----
  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $run-inst))
)
