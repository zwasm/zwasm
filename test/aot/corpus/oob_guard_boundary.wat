;; AOT-diff corpus (ADR-0203 stage 4 / ADR-0202 D5): page-boundary-straddling
;; accesses in an ELIDED artifact. `zwasm compile` defaults to elided codegen
;; on qualifying memories, so the .cwasm lane must guard-fault through the
;; RE-REGISTERED trap entries in a fresh process and exit-code-match the
;; .wasm lane (default entry = `main` = the straddling load → trap).
(module
  (memory 1)
  ;; 4-byte load at 65533: bytes 65533..65537 cross the 65536 end → trap.
  (func $oob_load_straddle (export "main") (result i32)
    (i32.load (i32.const 65533)))
  ;; 4-byte store at 65534 → trap; must write NO byte.
  (func (export "oob_store_straddle") (result i32)
    (i32.store (i32.const 65534) (i32.const 42))
    (i32.const 0))
  ;; Last fully in-bounds 4-byte slot — must NOT trap on any lane.
  (func (export "load_last_slot") (result i32)
    (i32.load (i32.const 65532))))
