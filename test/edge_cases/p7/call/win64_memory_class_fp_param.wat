;; #607: a callee with three results is MEMORY-class, so on Win64 its params
;; start at position 2 for both register banks. The callee read its f32 from
;; XMM2 while the caller wrote XMM3. f(7, 2.5) = (7, 250, 2500): 702750.
(module
  (func $f (param $i i32) (param $x f32) (result i32 i32 i32)
    (local.get $i)
    (i32.trunc_f32_s (f32.mul (local.get $x) (f32.const 100)))
    (i32.trunc_f32_s (f32.mul (local.get $x) (f32.const 1000))))
  (func (export "test") (result i32)
    (local $a i32) (local $b i32) (local $c i32)
    (call $f (i32.const 7) (f32.const 2.5))
    (local.set $c) (local.set $b) (local.set $a)
    (i32.add (i32.add (i32.mul (local.get $a) (i32.const 100000)) (local.get $b)) (local.get $c))))
