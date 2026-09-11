;; As `main_ref`, body traps: the interpreter reports the trap; the JIT
;; refuses the shape before calling, so its reason is C4's, not the trap (#220 C4).
(module (func (export "main") (result funcref) unreachable))
