;; `merge_moves_br_on.wat`'s loop form with `br_on_null` as the back edge:
;; taken once when n is set, it carries the loop's three values back rotated
;; by one. The calls put the params and the carried values in spill slots,
;; and the two values pushed and dropped reorder the slots those take, so
;; the edge's moves form a cycle. The fold is r0 + 100*r1 + 10000*r2.
;; A module of its own: the x86_64 JIT declines `br_on_null` to a loop.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (type $i3 (func (param i32 i32 i32) (result i32 i32 i32)))
  (type $f3 (func (param f64 f64 f64) (result f64 f64 f64)))

  (func $fold_i32 (param i32 i32 i32) (result i32)
    local.get 0
    local.get 1 i32.const 100 i32.mul i32.add
    local.get 2 i32.const 10000 i32.mul i32.add)
  (func $fold_f64 (param f64 f64 f64) (result i32)
    local.get 0
    local.get 1 f64.const 100 f64.mul f64.add
    local.get 2 f64.const 10000 f64.mul f64.add
    i32.trunc_f64_s)
  (func $nop)

  (func (export "null_loop") (param $n i32) (result i32)
    (local $a i32) (local $b i32) (local $c i32)
    i32.const 22 i32.const 29 i32.const 36
    loop (type $i3)
      call $nop
      local.set $c local.set $b local.set $a
      local.get $a local.get $a drop drop
      local.get $b local.get $c local.get $a
      ref.null i31 i32.const 5 ref.i31 local.get $n select (result i31ref)
      i32.const 0
      local.set $n
      call $nop
      br_on_null 0
      drop
      local.set $c local.set $b local.set $a
      local.get $a local.get $b local.get $c
    end
    call $fold_i32)

  (func (export "null_loop_f64") (param $n i32) (result i32)
    (local $a f64) (local $b f64) (local $c f64)
    f64.const 22 f64.const 29 f64.const 36
    loop (type $f3)
      call $nop
      local.set $c local.set $b local.set $a
      local.get $a local.get $a drop drop
      local.get $b local.get $c local.get $a
      ref.null i31 i32.const 5 ref.i31 local.get $n select (result i31ref)
      i32.const 0
      local.set $n
      call $nop
      br_on_null 0
      drop
      local.set $c local.set $b local.set $a
      local.get $a local.get $b local.get $c
    end
    call $fold_f64))
