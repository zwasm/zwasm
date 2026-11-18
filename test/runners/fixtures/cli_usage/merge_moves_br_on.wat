;; `br_on_null`, `br_on_non_null`, `br_on_cast` and `br_on_cast_fail` as the
;; edge that delivers values into a merge another edge named. One reference
;; type throughout, i31ref, and no type definitions beside the frames'.
;;
;; `*_block` (c, n): `br_if` on c carries [29 57 ..] first; then the `br_on`
;; edge, taken when n is set, carries [22 29 ..] into the same merge; else
;; the body leaves [3 4 ..].
;;
;; `*_loop` (n): the back edge is the `br_on`, taken once when n is set; it
;; carries the loop's three values back rotated by one. The call at the
;; loop's head puts the params in spill slots, as the cast's own call does
;; the carried values, and the two values pushed and dropped reorder the
;; slots those take, so the edge's moves form a cycle.
;;
;; The fold is r0 + 100*r1 + 10000*r2, plus 1000000 when the frame's
;; reference result is null.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (type $i2 (func (param i32 i32) (result i32 i32)))
  (type $f2 (func (param f64 f64) (result f64 f64)))
  (type $i2r (func (param i32 i32) (result i32 i32 i31ref)))
  (type $f2r (func (param f64 f64) (result f64 f64 i31ref)))
  (type $i3r (func (param i32 i32 i32 i31ref) (result i32 i32 i32 i31ref)))
  (type $f3r (func (param f64 f64 f64 i31ref) (result f64 f64 f64 i31ref)))

  (func $fold_i32 (param i32 i32 i32 i32) (result i32)
    local.get 0
    local.get 1 i32.const 100 i32.mul i32.add
    local.get 2 i32.const 10000 i32.mul i32.add
    local.get 3 i32.const 1000000 i32.mul i32.add)
  (func $fold_f64 (param f64 f64 f64 i32) (result i32)
    local.get 0
    local.get 1 f64.const 100 f64.mul f64.add
    local.get 2 f64.const 10000 f64.mul f64.add
    i32.trunc_f64_s
    local.get 3 i32.const 1000000 i32.mul i32.add)
  (func $nop)

  (func (export "null_block") (param $c i32) (param $n i32) (result i32)
    i32.const 22 i32.const 29
    block (type $i2)
      i32.const 57
      local.get $c
      br_if 0
      drop
      ref.null i31 i32.const 5 ref.i31 local.get $n select (result i31ref)
      br_on_null 0
      drop
      drop drop i32.const 3 i32.const 4
    end
    i32.const 0 i32.const 0
    call $fold_i32)

  (func (export "non_null_block") (param $c i32) (param $n i32) (result i32)
    (local $f i32)
    i32.const 22 i32.const 29
    block (type $i2r)
      i32.const 57
      ref.null i31
      local.get $c
      br_if 0
      drop drop
      i32.const 5 ref.i31 ref.null i31 local.get $n select (result i31ref)
      br_on_non_null 0
      drop drop i32.const 3 i32.const 4 ref.null i31
    end
    ref.is_null
    local.set $f
    i32.const 0 local.get $f
    call $fold_i32)

  (func (export "cast_block") (param $c i32) (param $n i32) (result i32)
    (local $f i32)
    i32.const 22 i32.const 29
    block (type $i2r)
      i32.const 57
      ref.null i31
      local.get $c
      br_if 0
      drop drop
      i32.const 5 ref.i31 ref.null i31 local.get $n select (result i31ref)
      br_on_cast 0 (ref null i31) (ref i31)
      drop
      drop drop i32.const 3 i32.const 4 ref.null i31
    end
    ref.is_null
    local.set $f
    i32.const 0 local.get $f
    call $fold_i32)

  (func (export "cast_fail_block") (param $c i32) (param $n i32) (result i32)
    (local $f i32)
    i32.const 22 i32.const 29
    block (type $i2r)
      i32.const 57
      ref.null i31
      local.get $c
      br_if 0
      drop drop
      ref.null i31 i32.const 5 ref.i31 local.get $n select (result i31ref)
      br_on_cast_fail 0 (ref null i31) (ref i31)
      drop
      drop drop i32.const 3 i32.const 4 i32.const 5 ref.i31
    end
    ref.is_null
    local.set $f
    i32.const 0 local.get $f
    call $fold_i32)

  (func (export "cast_loop") (param $n i32) (result i32)
    (local $a i32) (local $b i32) (local $c i32) (local $r i31ref)
    i32.const 22 i32.const 29 i32.const 36 ref.null i31
    loop (type $i3r)
      call $nop
      local.set $r local.set $c local.set $b local.set $a
      local.get $a local.get $a drop drop
      local.get $b local.get $c local.get $a
      i32.const 5 ref.i31 ref.null i31 local.get $n select (result i31ref)
      i32.const 0
      local.set $n
      br_on_cast 0 (ref null i31) (ref i31)
      local.set $r local.set $c local.set $b local.set $a
      local.get $a local.get $b local.get $c local.get $r
    end
    ref.is_null
    call $fold_i32)

  (func (export "cast_fail_loop") (param $n i32) (result i32)
    (local $a i32) (local $b i32) (local $c i32) (local $r i31ref)
    i32.const 22 i32.const 29 i32.const 36 ref.null i31
    loop (type $i3r)
      call $nop
      local.set $r local.set $c local.set $b local.set $a
      local.get $a local.get $a drop drop
      local.get $b local.get $c local.get $a
      ref.null i31 i32.const 5 ref.i31 local.get $n select (result i31ref)
      i32.const 0
      local.set $n
      br_on_cast_fail 0 (ref null i31) (ref i31)
      local.set $r local.set $c local.set $b local.set $a
      local.get $a local.get $b local.get $c local.get $r
    end
    ref.is_null
    call $fold_i32)

  (func (export "null_block_f64") (param $c i32) (param $n i32) (result i32)
    f64.const 22 f64.const 29
    block (type $f2)
      f64.const 57
      local.get $c
      br_if 0
      drop
      ref.null i31 i32.const 5 ref.i31 local.get $n select (result i31ref)
      br_on_null 0
      drop
      drop drop f64.const 3 f64.const 4
    end
    f64.const 0 i32.const 0
    call $fold_f64)

  (func (export "non_null_block_f64") (param $c i32) (param $n i32) (result i32)
    (local $f i32)
    f64.const 22 f64.const 29
    block (type $f2r)
      f64.const 57
      ref.null i31
      local.get $c
      br_if 0
      drop drop
      i32.const 5 ref.i31 ref.null i31 local.get $n select (result i31ref)
      br_on_non_null 0
      drop drop f64.const 3 f64.const 4 ref.null i31
    end
    ref.is_null
    local.set $f
    f64.const 0 local.get $f
    call $fold_f64)

  (func (export "cast_block_f64") (param $c i32) (param $n i32) (result i32)
    (local $f i32)
    f64.const 22 f64.const 29
    block (type $f2r)
      f64.const 57
      ref.null i31
      local.get $c
      br_if 0
      drop drop
      i32.const 5 ref.i31 ref.null i31 local.get $n select (result i31ref)
      br_on_cast 0 (ref null i31) (ref i31)
      drop
      drop drop f64.const 3 f64.const 4 ref.null i31
    end
    ref.is_null
    local.set $f
    f64.const 0 local.get $f
    call $fold_f64)

  (func (export "cast_fail_block_f64") (param $c i32) (param $n i32) (result i32)
    (local $f i32)
    f64.const 22 f64.const 29
    block (type $f2r)
      f64.const 57
      ref.null i31
      local.get $c
      br_if 0
      drop drop
      ref.null i31 i32.const 5 ref.i31 local.get $n select (result i31ref)
      br_on_cast_fail 0 (ref null i31) (ref i31)
      drop
      drop drop f64.const 3 f64.const 4 i32.const 5 ref.i31
    end
    ref.is_null
    local.set $f
    f64.const 0 local.get $f
    call $fold_f64)

  (func (export "cast_loop_f64") (param $n i32) (result i32)
    (local $a f64) (local $b f64) (local $c f64) (local $r i31ref)
    f64.const 22 f64.const 29 f64.const 36 ref.null i31
    loop (type $f3r)
      call $nop
      local.set $r local.set $c local.set $b local.set $a
      local.get $a local.get $a drop drop
      local.get $b local.get $c local.get $a
      i32.const 5 ref.i31 ref.null i31 local.get $n select (result i31ref)
      i32.const 0
      local.set $n
      br_on_cast 0 (ref null i31) (ref i31)
      local.set $r local.set $c local.set $b local.set $a
      local.get $a local.get $b local.get $c local.get $r
    end
    ref.is_null
    call $fold_f64)

  (func (export "cast_fail_loop_f64") (param $n i32) (result i32)
    (local $a f64) (local $b f64) (local $c f64) (local $r i31ref)
    f64.const 22 f64.const 29 f64.const 36 ref.null i31
    loop (type $f3r)
      call $nop
      local.set $r local.set $c local.set $b local.set $a
      local.get $a local.get $a drop drop
      local.get $b local.get $c local.get $a
      ref.null i31 i32.const 5 ref.i31 local.get $n select (result i31ref)
      i32.const 0
      local.set $n
      br_on_cast_fail 0 (ref null i31) (ref i31)
      local.set $r local.set $c local.set $b local.set $a
      local.get $a local.get $b local.get $c local.get $r
    end
    ref.is_null
    call $fold_f64))
