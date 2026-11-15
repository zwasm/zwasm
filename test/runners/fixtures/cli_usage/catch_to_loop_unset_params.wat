;; #369 — a catch to a loop whose param comes from a block that ends in
;; `unreachable`, in a function with no other value: the JIT declines it, and
;; the interpreter (and so the default engine) traps.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (tag $ti (param i32))
  (func $thrower)
  (func (export "_start")
    (block (result i32) (unreachable))
    (loop $l (param i32)
      (drop)
      (try_table (catch $ti $l)
        (call $thrower)))))
