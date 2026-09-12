;; `main () -> (i32 f32)`: the interpreter prints both; the JIT has no
;; thunk for a mixed multi-value shape, so `--engine jit` / `.cwasm` refuse it
;; (#220 C4). The default engine reaches the same shape at call time, where
;; there is no falling back, and traps `unsupported` naming it (#431).
(module (func (export "main") (result i32 f32) i32.const 1 f32.const 2))
