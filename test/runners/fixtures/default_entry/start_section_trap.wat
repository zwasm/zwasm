;; A `(start)` that traps, with a fine `_start`: instantiation is where the
;; trap happens, on every path (#220 — instantiate, then the entry).
(module (func $s unreachable) (start $s) (func (export "_start")))
