;; #558 boundary fixture — `local.get` of a v128 local into a spilled
;; vreg. Six live v128 temporaries hold the XMM pool, so the get's result
;; spills; the x86_64 get stored 8 of its 16 bytes there and the use read 16,
;; so lanes 2-3 were whatever the slot held. Siblings: _set_, _tee_.
;;
;; lane0 + 10*lane1 + 100*lane2 + 1000*lane3 of i32x4 1 2 3 4. Spec expectation: 4321.
(module
  (func (export "test") (result i32)
    (local $v v128)
    (local.set $v (v128.const i32x4 1 2 3 4))
    (v128.const i32x4 0 0 0 0) (v128.const i32x4 0 0 0 0) (v128.const i32x4 0 0 0 0)
    (v128.const i32x4 0 0 0 0) (v128.const i32x4 0 0 0 0) (v128.const i32x4 0 0 0 0)
    (local.get $v)
    (v128.or) (v128.or) (v128.or) (v128.or) (v128.or) (v128.or)
    (local.set $v)
    (i32.add
      (i32.add (i32x4.extract_lane 0 (local.get $v)) (i32.mul (i32.const 10) (i32x4.extract_lane 1 (local.get $v))))
      (i32.add (i32.mul (i32.const 100) (i32x4.extract_lane 2 (local.get $v))) (i32.mul (i32.const 1000) (i32x4.extract_lane 3 (local.get $v)))))))
