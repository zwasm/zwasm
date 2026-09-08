;; No `_start` / `main`: the lenient chain resolves `f`, whose parameter
;; nothing supplies. The `.wasm` default used to report that as
;; `trapped in ... --invoke: argument count does not match`, naming a flag
;; that was not passed and calling a marshalling failure a trap (#220 (d)).
(module (func (export "f") (param i32) unreachable))
