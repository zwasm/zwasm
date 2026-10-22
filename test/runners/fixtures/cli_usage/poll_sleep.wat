;; #598 — one poll_oneoff on a 5 s relative monotonic clock, then return, so
;; `--timeout` has to fire inside the host's sleep: no poll site follows it.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (import "wasi_snapshot_preview1" "poll_oneoff" (func $poll (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "_start")
    (i32.store8 (i32.const 8) (i32.const 0))           ;; clock
    (i32.store (i32.const 16) (i32.const 1))           ;; monotonic
    (i64.store (i32.const 24) (i64.const 5000000000))  ;; 5 s relative
    (drop (call $poll (i32.const 0) (i32.const 100) (i32.const 1) (i32.const 200)))))
