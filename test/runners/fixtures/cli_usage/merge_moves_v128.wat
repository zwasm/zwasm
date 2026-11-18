;; `merge_moves.wat`'s `loop_swap` with two v128s: a loop whose back edge,
;; taken once, carries its params back in each other's place, above a value
;; it leaves behind. Lane 0 of each result is folded as r0 + 100*r1. A module
;; of its own, since the interpreter runs no SIMD.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (type $v2 (func (param v128 v128) (result v128 v128)))
  (func (export "loop_swap") (param i32) (result i32)
    (local v128 v128)
    v128.const i32x4 22 0 0 0 v128.const i32x4 29 0 0 0
    loop (type $v2)
      local.set 2 local.set 1
      v128.const i32x4 7 0 0 0 local.get 2 local.get 1
      local.get 0
      i32.const 0
      local.set 0
      br_if 0
      local.set 2 local.set 1 drop local.get 1 local.get 2
    end
    i32x4.extract_lane 0
    local.set 0
    i32x4.extract_lane 0
    local.get 0 i32.const 100 i32.mul
    i32.add))
