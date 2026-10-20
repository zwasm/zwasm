;; #601: The then arm ends in an f32 call result, so the merge vreg is an f32 the old classifier called GPR.
;; The merge MOV took the class of a neighbouring vreg. f(6.5, 2.75, 57, 0) = 9.25 (bits 1091829760).
(module
  (func $v)
  (func $two (result i32 i32) i32.const 1 i32.const 2)
  (func $getf (param f32) (result f32) local.get 0 f32.const 0.5 f32.add)
  (table 4 funcref)
  (global $g (mut f32) (f32.const 3.5))
  (func $f (param $a f32) (param $b f32) (param $i i32) (param $c i32) (result f32)
    local.get $c
    if (result f32)
      local.get $a
      call $getf
    else
      local.get $a
      local.get $b
      f32.add
    end)
  (func (export "test") (result i32)
    (i32.reinterpret_f32 (call $f (f32.const 6.5) (f32.const 2.75) (i32.const 57) (i32.const 0)))))
