;; No function export at all: no default entry, exit 1 with the reason
;; (#220 C2). `zwasm compile` still accepts it, and its `.cwasm` fails to load
;; before the entry is judged (#432).
(module (memory (export "memory") 1))
