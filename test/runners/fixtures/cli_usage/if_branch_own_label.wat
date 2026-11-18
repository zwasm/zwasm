;; An `if` with params and no else whose then arm branches to the `if`'s own
;; label. With no else the else arm is empty, so on cond=0 the params are the
;; results; on cond=1 the branch carries them. `ref_result`'s `if` passes a
;; function reference over an i32 below it.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (type $t (func (result i32)))
  (func $g (type $t) i32.const 42)
  (elem declare func $g)
  (func (export "i32_result") (param i32) (result i32)
    i32.const 100
    i32.const 50
    local.get 0
    if (param i32) (result i32)
      drop
      i32.const 7
      br 0
    end
    i32.add)
  (func (export "ref_result") (param i32) (result i32)
    i32.const 100
    ref.func $g
    local.get 0
    if (param (ref null $t)) (result (ref null $t))
      drop
      ref.null $t
      br 0
    end
    ref.is_null
    i32.add))
