;; #597 — one SIMD op, which the interpreter binds no handler for.
(module
  (func (export "_start")
    (drop (i32x4.extract_lane 0 (v128.const i32x4 0 0 0 0)))))
