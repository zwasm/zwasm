;; `_start () -> i32`: runs and the result prints on stdout; the exit code
;; stays 0 — a result is not an exit status (#220 (c), C3).
(module (func (export "_start") (result i32) i32.const 42))
