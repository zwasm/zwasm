;; #618 — one f32 param and three results: the Win64 thunk's 3-result branch
;; loaded the param as a GPR, so the body read an unwritten XMM register.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (func (export "f") (param $x f32) (result i32 i32 i32)
    (i32.const 7)
    (i32.trunc_f32_s (f32.mul (local.get $x) (f32.const 100)))
    (i32.trunc_f32_s (f32.mul (local.get $x) (f32.const 1000)))))
