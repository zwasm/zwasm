;; #399 — a block whose body is `unreachable` closes short of its f64
;; result before any vreg exists, and `local.set` of an f64 local loads it.
;; The JIT read that result from an empty slot table and panicked; every
;; engine now traps on the `unreachable`.
;; `else_short`: an `if (result i32 i32)` whose then-arm leaves one value
;; and ends in `unreachable`, and whose else arm is `unreachable`. Both
;; arms' frames close short, and the emit and liveness must mint the same
;; vregs there, or every later vreg takes another's range. `f=1` branches
;; past the `if`; the result is 17.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (func (export "f") (local f64)
    (block (result f64) unreachable)
    local.set 0)
  (func (export "else_short") (param i32) (result i32)
    block
      local.get 0
      br_if 0
      local.get 0
      if (result i32 i32)
        i32.const 1
        unreachable
      else
        unreachable
      end
      drop
      drop
    end
    i32.const 1000
    drop
    i32.const 7
    i32.const 1
    i32.const 2
    i32.add
    i32.const 3
    i32.add
    i32.const 4
    i32.add
    i32.add)
  (func (export "else_unreachable") (param i32) (result i32)
    i32.const 100
    i32.const 50
    local.get 0
    if (param i32) (result i32 i32)
      drop
      i32.const 7
      i32.const 8
    else
      unreachable
    end
    i32.add
    i32.add))
