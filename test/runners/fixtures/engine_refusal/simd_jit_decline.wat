;; #597 — a SIMD module the JIT declines: `return_call` to a 3-result callee
;; is refused on every target with the same note, before the v128 op is
;; reached. The interpreter refuses the v128 op.
(module
  (func $tri (param i32) (result i32 i32 i32) local.get 0 i32.const 2 i32.const 3)
  (func $tail (result i32 i32 i32) i32.const 1 return_call $tri)
  (func (export "_start")
    (drop (drop (drop (call $tail))))
    (drop (i32x4.extract_lane 0 (v128.const i32x4 0 0 0 0)))))
