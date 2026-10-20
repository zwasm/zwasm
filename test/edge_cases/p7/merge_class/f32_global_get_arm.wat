;; #601: The then arm ends in an f32 global.get.
;; The merge MOV took the class of a neighbouring vreg. f(7.5, 3.25, 67, 0) = 10.75 (bits 1093402624).
(module
  (func $v)
  (func $two (result i32 i32) i32.const 1 i32.const 2)
  (func $getf (param f32) (result f32) local.get 0 f32.const 0.5 f32.add)
  (table 4 funcref)
  (global $g (mut f32) (f32.const 3.5))
  (func $f (param $a f32) (param $b f32) (param $i i32) (param $c i32) (result f32)
    local.get $a
    global.set $g
    local.get $c
    if (result f32)
      global.get $g
    else
      local.get $a
      local.get $b
      f32.add
    end)
  (func (export "test") (result i32)
    (i32.reinterpret_f32 (call $f (f32.const 7.5) (f32.const 3.25) (i32.const 67) (i32.const 0)))))
