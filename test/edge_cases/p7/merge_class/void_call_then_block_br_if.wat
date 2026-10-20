;; #601: A void call before a block whose br_if carries an f32; the fallthrough value is merged with a GPR move.
;; The merge MOV took the class of a neighbouring vreg. f(2.5, 0.75, 17, 0) = 3.25 (bits 1078984704).
(module
  (func $v)
  (func $two (result i32 i32) i32.const 1 i32.const 2)
  (func $getf (param f32) (result f32) local.get 0 f32.const 0.5 f32.add)
  (table 4 funcref)
  (global $g (mut f32) (f32.const 3.5))
  (func $f (param $a f32) (param $b f32) (param $i i32) (param $c i32) (result f32)
    call $v
    block (result f32)
      local.get $i
      f32.convert_i32_s
      local.get $c
      br_if 0
      drop
      local.get $a
      local.get $b
      f32.add
    end)
  (func (export "test") (result i32)
    (i32.reinterpret_f32 (call $f (f32.const 2.5) (f32.const 0.75) (i32.const 17) (i32.const 0)))))
