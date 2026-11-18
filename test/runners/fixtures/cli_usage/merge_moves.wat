;; Frames with two edges into one merge, where the values one edge delivers
;; sit where the other edge's values go. Each function folds the frame's
;; results as r0 + 100*r1 (+ 10000*r2), so a result's position shows in the
;; value. One numeric type per frame.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (type $i3 (func (param i32 i32 i32) (result i32 i32 i32)))
  (type $i2 (func (param i32 i32) (result i32 i32)))
  (type $f2 (func (param f64 f64) (result f64 f64)))

  (func $fold3 (param i32 i32 i32) (result i32)
    local.get 0
    local.get 1 i32.const 100 i32.mul i32.add
    local.get 2 i32.const 10000 i32.mul i32.add)
  (func $fold2 (param i32 i32) (result i32)
    local.get 0
    local.get 1 i32.const 100 i32.mul i32.add)
  (func $foldf (param f64 f64) (result i32)
    local.get 0
    local.get 1 f64.const 100 f64.mul f64.add
    i32.trunc_f64_s)

  ;; The branch carries [29 36 57]; the fall-through leaves [22 29 36].
  (func (export "block") (param i32) (result i32)
    i32.const 22 i32.const 29 i32.const 36
    block (type $i3)
      i32.const 57
      local.get 0
      br_if 0
      drop
    end
    call $fold3)

  ;; The same with f64: the branch carries [29 57], the fall-through [22 29].
  (func (export "block_f64") (param i32) (result i32)
    f64.const 22 f64.const 29
    block (type $f2)
      f64.const 57
      local.get 0
      br_if 0
      drop
    end
    call $foldf)

  ;; Local 0 picks the arm, local 1 the branch. The then arm's `br_if`
  ;; carries [29 57]; not taken, the arm reaches `else` with [22 29].
  (func (export "if_then") (param i32 i32) (result i32)
    i32.const 22 i32.const 29
    local.get 0
    if (type $i2)
      i32.const 57
      local.get 1
      br_if 0
      drop
    else
      drop drop
      i32.const 3 i32.const 4
    end
    call $fold2)

  ;; The then arm's `br_if` carries the params [22 29]; the else arm reaches
  ;; `end` with [29 57], which a nested block's branch left one slot down.
  (func (export "if_else") (param i32 i32) (result i32)
    i32.const 22 i32.const 29
    local.get 0
    if (type $i2)
      local.get 1
      br_if 0
      drop drop
      i32.const 3 i32.const 4
    else
      block (type $i2)
        i32.const 57
        br 0
      end
    end
    call $fold2)

  ;; f64: the then arm branches with [29 57]; the else arm's `br_if` carries
  ;; the params [22 29].
  (func (export "if_f64") (param i32 i32) (result i32)
    f64.const 22 f64.const 29
    local.get 0
    if (type $f2)
      f64.const 57
      br 0
    else
      local.get 1
      br_if 0
      drop drop
      f64.const 3 f64.const 4
    end
    call $foldf)

  ;; A loop whose back edge, taken once, carries [29 57] into its params
  ;; [22 29].
  (func (export "loop") (param i32) (result i32)
    i32.const 22 i32.const 29
    loop (type $i2)
      i32.const 57
      local.get 0
      i32.const 0
      local.set 0
      br_if 0
      drop
    end
    call $fold2)

  ;; A loop whose back edge, taken once, carries its params back in each
  ;; other's place, above a value it leaves behind: [29 22] into [22 29].
  (func (export "loop_swap") (param i32) (result i32)
    (local i32 i32)
    i32.const 22 i32.const 29
    loop (type $i2)
      local.set 2 local.set 1
      i32.const 7 local.get 2 local.get 1
      local.get 0
      i32.const 0
      local.set 0
      br_if 0
      local.set 2 local.set 1 drop local.get 1 local.get 2
    end
    call $fold2))
