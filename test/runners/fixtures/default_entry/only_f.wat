;; Neither `_start` nor `main`: there is no default entry, whatever else the
;; module exports — D-284's third link (the first func export) is gone (#220 C1).
;; `--invoke f` runs it.
(module (func (export "f") (result i32) i32.const 42))
