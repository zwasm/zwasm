;; #601: A void call before an if (result i32) whose then arm ends in i32.reinterpret_f32: the i32 is merged with an XMM move.
;; The merge MOV took the class of a neighbouring vreg. f(9.5, 4.25, 87, 0) = 1087.
(module
  (func $v)
  (func $two (result i32 i32) i32.const 1 i32.const 2)
  (func $getf (param f32) (result f32) local.get 0 f32.const 0.5 f32.add)
  (table 4 funcref)
  (global $g (mut f32) (f32.const 3.5))
  (func $f (param $a f32) (param $b f32) (param $i i32) (param $c i32) (result i32)
    call $v
    local.get $c
    if (result i32)
      local.get $a
      i32.reinterpret_f32
    else
      local.get $i
      i32.const 1000
      i32.add
    end)
  (func (export "test") (result i32)
    (call $f (f32.const 9.5) (f32.const 4.25) (i32.const 87) (i32.const 0))))
