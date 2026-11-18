;; A catch clause whose label is the function's own label is a `br` to the
;; function body: the function returns the tag's payload. The clause targets
;; label 0 (the try_table sits at the top of the function body), the body always
;; throws, and the trailing `i32.const 5` is dead. Every engine returns 77.
(module
  (tag $e (param i32))
  (func (export "D1") (result i32)
    try_table (catch $e 0) i32.const 77 throw $e end
    i32.const 5))
