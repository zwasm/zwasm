;; #601: A void call before the if. The else arm's f32 is merged with a GPR move.
;; The merge MOV took the class of a neighbouring vreg. f(1.5, 0.25, 7, 0) = 1.75 (bits 1071644672).
(module
  (func $v)
  (func $two (result i32 i32) i32.const 1 i32.const 2)
  (func $getf (param f32) (result f32) local.get 0 f32.const 0.5 f32.add)
  (table 4 funcref)
  (global $g (mut f32) (f32.const 3.5))
  (func $f (param $a f32) (param $b f32) (param $i i32) (param $c i32) (result f32)
    call $v
    local.get $c
    if (result f32)
      local.get $i
      f32.convert_i32_s
    else
      local.get $a
      local.get $b
      f32.add
    end)
  (func (export "test") (result i32)
    (i32.reinterpret_f32 (call $f (f32.const 1.5) (f32.const 0.25) (i32.const 7) (i32.const 0)))))
