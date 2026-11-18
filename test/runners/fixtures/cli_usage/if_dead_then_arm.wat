;; #739 — an `if` whose then-arm ends in `unreachable`, so only the else arm
;; (`else_arm`, `ref_result`, `param_else`) or the implicit else
;; (`implicit_else`) reaches the `end`. The JIT took the merge value from
;; below the `if`: `f=0` gave 0 and 2 where the interpreter gives -2.
;; `ref_result`'s `if` yields a function reference over an i32, and
;; `call_ref` calls it. `param_else`'s `if` takes one param and returns two
;; results, with values below it; `param_else_only` is the same `if` with
;; only its param below it.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (type $t (func (result i32)))
  (func $g (type $t) i32.const 42)
  (elem declare func $g)
  (func (export "else_arm") (param i32) (result i32)
    i32.const 5
    local.get 0
    if (result i32)
      unreachable
    else
      i32.const 7
    end
    i32.sub)
  (func (export "implicit_else") (param i32) (result i32)
    i32.const 5
    i32.const 7
    local.get 0
    if (param i32) (result i32)
      drop
      unreachable
    end
    i32.sub)
  (func (export "ref_result") (param i32) (result i32)
    i32.const 5
    local.get 0
    if (result (ref null $t))
      unreachable
    else
      ref.func $g
    end
    call_ref $t
    i32.add)
  (func (export "param_else") (param i32) (result i32)
    i32.const 10
    i32.const 20
    i32.const 30
    local.get 0
    if (param i32) (result i32 i32)
      drop
      unreachable
    else
      drop
      i32.const 7
      i32.const 8
    end
    i32.add
    i32.add
    i32.add)
  (func (export "param_else_only") (param i32) (result i32)
    i32.const 30
    local.get 0
    if (param i32) (result i32 i32)
      drop
      unreachable
    else
      drop
      i32.const 7
      i32.const 8
    end
    i32.add))
