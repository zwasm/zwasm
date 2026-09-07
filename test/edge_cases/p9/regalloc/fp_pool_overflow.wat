;; #286 — eight simultaneously-live f64 locals against a six-wide FP pool
;; (`x86_64/abi.zig` allocatable_xmms), so the body has to reach the spill
;; stage. Self-checking: returns 1 when the sum is exact, so the fixture format
;; stays `i32:` and a spill that loses a lane shows up as 0 rather than as a
;; value nobody compares.
(module
  (func (export "test") (result i32)
    (local f64 f64 f64 f64 f64 f64 f64 f64)
    (local.set 0 (f64.const 1.5))      (local.set 1 (f64.const 2.25))
    (local.set 2 (f64.const 3.125))    (local.set 3 (f64.const 4.0625))
    (local.set 4 (f64.const 5.03125))  (local.set 5 (f64.const 6.015625))
    (local.set 6 (f64.const 7.0078125))(local.set 7 (f64.const 8.00390625))
    (f64.eq
      (f64.add
        (f64.add (f64.add (local.get 0) (local.get 1)) (f64.add (local.get 2) (local.get 3)))
        (f64.add (f64.add (local.get 4) (local.get 5)) (f64.add (local.get 6) (local.get 7))))
      (f64.const 36.99609375))))
