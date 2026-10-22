;; WASI Preview 2 poll component (D3-7). Mints two pollables — one from
;; monotonic-clock.subscribe-duration, one from input-stream.subscribe(stdin) —
;; then drives wasi:io/poll: poll([p1,p2]) must report BOTH ready (indices 0,1),
;; pollable.ready(p) must be true, pollable.block(p) returns at once. The clock
;; pollable's duration is 0 and the test host's stdin is a byte slice, so
;; both are ready and every check has a fixed expected value; a mismatch
;; traps (unreachable), so a clean run proves the poll trampolines are correct.
(component
  ;; ---- import wasi:io/poll (pollable resource + ready/block/poll) ----
  (import "wasi:io/poll@0.2.0" (instance $poll
    (export "pollable" (type $pollable (sub resource)))
    (type $borrow-p (borrow $pollable))
    (type $list-borrow (list $borrow-p))
    (type $list-u32 (list u32))
    (export "[method]pollable.ready" (func (param "self" $borrow-p) (result bool)))
    (export "[method]pollable.block" (func (param "self" $borrow-p)))
    (export "poll" (func (param "in" $list-borrow) (result $list-u32)))))
  (alias export $poll "pollable" (type $pollable))

  ;; ---- import wasi:clocks/monotonic-clock (subscribe-duration → pollable) ----
  (import "wasi:clocks/monotonic-clock@0.2.0" (instance $clock
    (alias outer 1 $pollable (type $p-in))
    (export "pollable" (type $p-ex (eq $p-in)))
    (type $own-p (own $p-ex))
    (export "subscribe-duration" (func (param "when" u64) (result $own-p)))))

  ;; ---- import wasi:io/streams (input-stream + subscribe → pollable) ----
  (import "wasi:io/streams@0.2.0" (instance $streams
    (alias outer 1 $pollable (type $p-in2))
    (export "pollable" (type $p-ex2 (eq $p-in2)))
    (export "input-stream" (type $istream (sub resource)))
    (type $borrow-is (borrow $istream))
    (type $own-p2 (own $p-ex2))
    (export "[method]input-stream.subscribe" (func (param "self" $borrow-is) (result $own-p2)))))
  (alias export $streams "input-stream" (type $istream))

  ;; ---- import wasi:cli/stdin (get-stdin) ----
  (import "wasi:cli/stdin@0.2.0" (instance $stdin
    (alias outer 1 $istream (type $is-in))
    (export "input-stream" (type $is-ex (eq $is-in)))
    (type $own-is (own $is-ex))
    (export "get-stdin" (func (result $own-is)))))

  ;; ---- libc: memory + bump cabi_realloc (poll's list<u32> return area) ----
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

  ;; ---- lower imported component funcs to core funcs ----
  (core func $subdur (canon lower (func $clock "subscribe-duration")))
  (core func $issub (canon lower (func $streams "[method]input-stream.subscribe")))
  (core func $getstdin (canon lower (func $stdin "get-stdin")))
  (core func $ready (canon lower (func $poll "[method]pollable.ready")))
  (core func $block (canon lower (func $poll "[method]pollable.block")))
  (core func $pollfn (canon lower (func $poll "poll") (memory $libc "memory") (realloc $cabi_realloc)))
  (core func $dropp (canon resource.drop $pollable))
  (core func $dropis (canon resource.drop $istream))

  ;; ---- core module driving poll ----
  (core module $M
    (import "io" "subscribe-duration" (func $subdur (param i64) (result i32)))
    (import "io" "input-stream.subscribe" (func $issub (param i32) (result i32)))
    (import "io" "get-stdin" (func $getstdin (result i32)))
    (import "io" "ready" (func $ready (param i32) (result i32)))
    (import "io" "block" (func $block (param i32)))
    (import "io" "poll" (func $pollfn (param i32 i32 i32)))
    (import "io" "drop-p" (func $dropp (param i32)))
    (import "io" "drop-is" (func $dropis (param i32)))
    (import "libc" "memory" (memory 1))
    (func $check (param $cond i32) (if (local.get $cond) (then (unreachable))))
    (func (export "run") (result i32)
      (local $p1 i32) (local $p2 i32) (local $s i32) (local $dptr i32)
      (local.set $p1 (call $subdur (i64.const 0)))         ;; clock pollable
      (local.set $s (call $getstdin))
      (local.set $p2 (call $issub (local.get $s)))         ;; stdin pollable
      ;; build list<borrow<pollable>> [p1, p2] at 64; poll → list<u32> ret@256
      (i32.store (i32.const 64) (local.get $p1))
      (i32.store (i32.const 68) (local.get $p2))
      (call $pollfn (i32.const 64) (i32.const 2) (i32.const 256))
      (call $check (i32.ne (i32.load (i32.const 260)) (i32.const 2)))  ;; ready count == 2
      (local.set $dptr (i32.load (i32.const 256)))
      (call $check (i32.ne (i32.load (local.get $dptr)) (i32.const 0)))             ;; index 0
      (call $check (i32.ne (i32.load (i32.add (local.get $dptr) (i32.const 4))) (i32.const 1))) ;; index 1
      (call $check (i32.eqz (call $ready (local.get $p1))))   ;; ready(p1) true
      (call $check (i32.eqz (call $ready (local.get $p2))))   ;; ready(p2) true
      (call $block (local.get $p1))                          ;; noop
      (call $dropp (local.get $p1))
      (call $dropp (local.get $p2))
      (call $dropis (local.get $s))
      (i32.const 0)))

  (core instance $deps (export "subscribe-duration" (func $subdur))
                       (export "input-stream.subscribe" (func $issub))
                       (export "get-stdin" (func $getstdin))
                       (export "ready" (func $ready))
                       (export "block" (func $block))
                       (export "poll" (func $pollfn))
                       (export "drop-p" (func $dropp))
                       (export "drop-is" (func $dropis)))
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
