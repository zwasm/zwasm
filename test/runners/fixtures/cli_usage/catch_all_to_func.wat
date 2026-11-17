;; A `catch_all` whose label is the function's own label returns (with no
;; values) rather than falling through. The body throws, the clause catches and
;; returns, and the trailing `unreachable` is dead: every engine exits 0 with no
;; output.
(module
  (tag $e (param i32))
  (func (export "D1")
    try_table (catch_all 0) i32.const 99 throw $e end
    unreachable))
