;; #601: table.fill, which pushes nothing, before the if.
;; The merge MOV took the class of a neighbouring vreg. f(4.5, 1.75, 37, 0) = 6.25 (bits 1086849024).
(module
  (func $v)
  (func $two (result i32 i32) i32.const 1 i32.const 2)
  (func $getf (param f32) (result f32) local.get 0 f32.const 0.5 f32.add)
  (table 4 funcref)
  (global $g (mut f32) (f32.const 3.5))
  (func $f (param $a f32) (param $b f32) (param $i i32) (param $c i32) (result f32)
    i32.const 0
    ref.null func
    i32.const 1
    table.fill 0
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
    (i32.reinterpret_f32 (call $f (f32.const 4.5) (f32.const 1.75) (i32.const 37) (i32.const 0)))))
