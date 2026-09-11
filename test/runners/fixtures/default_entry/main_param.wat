;; `main (param i32)`: as `start_param`, through the second link (#220 C2).
;; The report must not name `--invoke` (the flag was not passed) and must not
;; read as a trap (#220 (d)).
(module (func (export "main") (param i32) unreachable))
