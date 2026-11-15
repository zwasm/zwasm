;; #369 — a catch clause whose label is a `loop` branches to the loop's
;; header, as `br` to that label does; the JIT's pad landed after the loop.
;; `catch_to_block` is the same loop with the label on an enclosing block;
;; `catch_all_spin` loops through its catch N times, long enough for `--timeout`
;; or `--fuel` to stop it.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (tag $t)
  (func (export "catch_to_loop") (result i32) (local i32)
    (loop $l
      (local.set 0 (i32.add (local.get 0) (i32.const 1)))
      (if (i32.lt_s (local.get 0) (i32.const 3))
        (then (try_table (catch $t $l) (throw $t)))))
    (local.get 0))
  (func (export "catch_to_block") (result i32) (local i32)
    (block $b
      (loop $l
        (local.set 0 (i32.add (local.get 0) (i32.const 1)))
        (if (i32.lt_s (local.get 0) (i32.const 3))
          (then (try_table (catch $t $b) (throw $t))))))
    (local.get 0))
  (func (export "catch_all_to_loop") (result i32) (local i32)
    (loop $l
      (local.set 0 (i32.add (local.get 0) (i32.const 1)))
      (if (i32.lt_s (local.get 0) (i32.const 3))
        (then (try_table (catch_all $l) (throw $t)))))
    (local.get 0))
  (func (export "catch_to_outer_loop") (result i32) (local i32)
    (loop $l
      (local.set 0 (i32.add (local.get 0) (i32.const 1)))
      (block $inner
        (if (i32.lt_s (local.get 0) (i32.const 3))
          (then (try_table (catch $t $l) (throw $t))))))
    (local.get 0))
  (func (export "catch_all_spin") (param i32) (result i32) (local i32)
    (loop $l
      (local.set 1 (i32.add (local.get 1) (i32.const 1)))
      (if (i32.lt_u (local.get 1) (local.get 0))
        (then (try_table (catch_all $l) (throw $t)))))
    (local.get 1)))
