;; #559 boundary fixture — a v128 spill slot right after an even run of
;; 8-byte scalar spill slots. The x86_64 slot address named the low edge of an
;; 8-byte cell, so a 16-byte store reached 8 bytes into the slot above: the
;; scalar 600 read back as -1, lane 2 of the v128.
;;
;; 1+2+3+4+5+6+7+8+90+600 + 7000. Spec expectation: 7726.
(module
  (func (export "test") (result i32)
    (i32.mul (i32.const 1) (i32.const 1))
    (i32.mul (i32.const 2) (i32.const 1))
    (i32.mul (i32.const 3) (i32.const 1))
    (i32.mul (i32.const 4) (i32.const 1))
    (i32.mul (i32.const 5) (i32.const 1))
    (i32.mul (i32.const 6) (i32.const 1))
    (i32.mul (i32.const 7) (i32.const 1))
    (i32.mul (i32.const 8) (i32.const 1))
    (i32.mul (i32.const 90) (i32.const 1))
    (i32.mul (i32.const 600) (i32.const 1))
    (v128.xor (v128.const i32x4 7000 -1 -1 -1) (v128.const i32x4 0 0 0 0))
    (i32x4.extract_lane 0)
    (i32.add) (i32.add) (i32.add) (i32.add) (i32.add) (i32.add) (i32.add) (i32.add) (i32.add) (i32.add)))
