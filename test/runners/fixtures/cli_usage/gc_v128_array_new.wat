;; #364 / D-495 — array.new of a v128-element array. The JIT fill marshals the
;; init through a general register, so a 16-byte element has no path: the JIT
;; declines (the default engine then runs it on the interpreter) rather than
;; trapping out_of_memory, which is not the condition. The interpreter does not
;; execute v128.const, so this module runs on neither engine today — both
;; refuse, each for its own reason. array.new_default (no runtime init) is NOT
;; declined: it zero-inits a v128 array fine on the JIT.
(module
  (type $a (array (mut v128)))
  (func (export "new") (result i32)
    (array.len (array.new $a (v128.const i32x4 0 0 0 0) (i32.const 3)))))
