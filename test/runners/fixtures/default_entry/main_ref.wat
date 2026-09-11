;; `main () -> funcref`: the interpreter prints `null`; the JIT has no call
;; helper for a lone ref result, so `--engine jit` / `.cwasm` say so and exit 1
;; instead of an instantiate-only exit 0 (#220 C4).
(module (func (export "main") (result funcref) ref.null func))
