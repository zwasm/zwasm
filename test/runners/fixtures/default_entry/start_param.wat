;; `_start (param i32)`: the chain resolves it, nothing supplies its
;; parameter — refused with the export's name, exit 1, on every driver (#220 C2).
(module (func (export "_start") (param i32) unreachable))
