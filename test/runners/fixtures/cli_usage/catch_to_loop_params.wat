;; #369 — a catch clause delivers the loop's params at its header: the
;; tag's payload (an i32 or an f64), or with `catch_ref` the payload and the
;; exnref, which the last iteration rethrows to read the first payload back.
;; The interpreter traps on the first two (#244).
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (tag $ti (param i32))
  (tag $tf (param f64))
  (func (export "payload_to_loop") (result i32) (local i32)
    (i32.const 0)
    (loop $l (param i32) (result i32)
      (local.set 0 (i32.add (i32.const 1)))
      (if (i32.lt_s (local.get 0) (i32.const 3))
        (then (try_table (catch $ti $l) (throw $ti (local.get 0)))))
      (local.get 0)))
  (func (export "f64_payload_to_loop") (result f64) (local f64)
    (f64.const 0)
    (loop $l (param f64) (result f64)
      (local.set 0 (f64.add (f64.const 1.5)))
      (if (f64.lt (local.get 0) (f64.const 4))
        (then (try_table (catch $tf $l) (throw $tf (local.get 0)))))
      (local.get 0)))
  (func (export "catch_ref_to_loop") (result i32) (local i32 exnref exnref)
    (block $out (result i32)
      (try_table (catch $ti $out)
        (i32.const 0) (ref.null exn)
        (loop $l (param i32 exnref)
          (local.set 2)
          (drop)
          ;; Keep the first iteration's exnref, whose payload is 10.
          (local.set 1 (select (result exnref) (local.get 2) (local.get 1)
            (i32.eq (local.get 0) (i32.const 1))))
          (local.set 0 (i32.add (local.get 0) (i32.const 1)))
          (if (i32.lt_s (local.get 0) (i32.const 3))
            (then (try_table (catch_ref $ti $l)
              (throw $ti (i32.mul (local.get 0) (i32.const 10)))))
            (else (throw_ref (local.get 1))))))
      (unreachable)))
)
