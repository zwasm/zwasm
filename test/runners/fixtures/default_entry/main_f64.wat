;; `main () -> f64`: a non-i32 result prints like an `--invoke` result (#220 C3).
(module (func (export "main") (result f64) f64.const 1.5))
