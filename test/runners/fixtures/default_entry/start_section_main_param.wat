;; A `(start)` that traps AND a `main (param i32)`: instantiation comes first
;; on every path, so the trap is reported and the entry is never judged
;; (#220 C5, ADR-0229 — the validity verdict precedes the refusal; PR #433).
(module (func $s unreachable) (start $s) (func (export "main") (param i32)))
