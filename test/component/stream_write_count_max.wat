;; WASI 0.3: a guest hands the readable end of a stream of 20-byte tuples to
;; wasi:cli/stdout write-via-stream, then stream.write's 0x0CCC_CCCD elements at
;; ptr 0. The count is within the spec's 2^28 - 1, but the byte span does not
;; fit in u32, so the write traps as the access to that span would.
(component
  (import "wasi:cli/stdout@0.3.0" (instance $stdout
    (type $ec (enum "io" "illegal-byte-sequence" "pipe"))
    (export "error-code" (type $ec-ex (eq $ec)))
    (export "write-via-stream"
      (func (param "data" (stream (tuple u32 u32 u32 u32 u32))) (result (future (result (error $ec-ex))))))))
  (type $st (stream (tuple u32 u32 u32 u32 u32)))
  (core module $libc (memory (export "mem") 1))
  (core instance $libc (instantiate $libc))
  (core func $wvs (canon lower (func $stdout "write-via-stream")))
  (core func $sn (canon stream.new $st))
  (core func $wr (canon stream.write $st (memory (core memory $libc "mem"))))
  (core module $m
    (import "async" "write-via-stream" (func $wvs (param i32) (result i32)))
    (import "async" "stream-new" (func $sn (result i64)))
    (import "async" "stream-write" (func $wr (param i32 i32 i32) (result i32)))
    (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "run") (result i32)
      (local $h i64)
      (local.set $h (call $sn))
      (drop (call $wvs (i32.wrap_i64 (local.get $h))))
      (drop (call $wr (i32.wrap_i64 (i64.shr_u (local.get $h) (i64.const 32)))
        (i32.const 0) (i32.const 0x0CCCCCCD)))
      i32.const 0))
  (core instance $deps
    (export "write-via-stream" (func $wvs))
    (export "stream-new" (func $sn))
    (export "stream-write" (func $wr)))
  (core instance $i (instantiate $m (with "async" (instance $deps))))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (core func $i "callback")))))
