;; `main () -> (i32 i32)`: both results print, one per line (#220 C3).
(module (func (export "main") (result i32 i32) i32.const 1 i32.const 2))
