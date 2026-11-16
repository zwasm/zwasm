;; #745: `throw_ref` of a null exnref traps (Wasm 3.0, throw_ref execution),
;; so the `catch_all` around it does not catch it.
;; The JIT raised an exception the clause caught, and `test` returned 5.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (func (export "test") (result i32)
    (block $h (try_table (catch_all $h) (throw_ref (ref.null exn))))
    (i32.const 5)))
