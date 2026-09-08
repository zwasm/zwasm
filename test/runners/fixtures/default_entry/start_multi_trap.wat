;; `_start` with two results, body traps. The `.wasm` default runs it and
;; exits 1 with the trap on stderr; the `.cwasm` / `--engine jit` driver
;; used to leave it instantiate-only and exit 0 with nothing printed (#220).
(module (func (export "_start") (result i32 i32) unreachable))
