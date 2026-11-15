;; #369 — the loop has a result: a catch to its label lands at the header, and
;; the loop ends in the struct the body builds.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (type $s (struct (field i64)))
  (tag $t)
  (func (export "test") (result i64) (local i32)
    (struct.get $s 0
      (loop $l (result (ref $s))
        (local.set 0 (i32.add (local.get 0) (i32.const 1)))
        (if (i32.lt_s (local.get 0) (i32.const 3))
          (then (try_table (catch $t $l) (throw $t))))
        (struct.new $s (i64.const 42))))))
