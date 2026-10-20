;; #601: A two-result call before the if, counted as one push.
;; The merge MOV took the class of a neighbouring vreg. f(3.5, 1.25, 27, 0) = 27.0 (bits 1104674816).
(module
  (func $v)
  (func $two (result i32 i32) i32.const 1 i32.const 2)
  (func $getf (param f32) (result f32) local.get 0 f32.const 0.5 f32.add)
  (table 4 funcref)
  (global $g (mut f32) (f32.const 3.5))
  (func $f (param $a f32) (param $b f32) (param $i i32) (param $c i32) (result f32)
    call $two
    drop
    drop
    local.get $c
    if (result f32)
      local.get $a
      local.get $b
      f32.add
    else
      local.get $i
      f32.convert_i32_s
    end)
  (func (export "test") (result i32)
    (i32.reinterpret_f32 (call $f (f32.const 3.5) (f32.const 1.25) (i32.const 27) (i32.const 0)))))
