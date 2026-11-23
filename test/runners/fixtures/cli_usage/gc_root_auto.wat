;; The same interior-offset plant as gc_root_struct, but with everything baked in
;; and a memory the JIT declines (over 256 MiB, #489), so the default engine
;; falls back to the interpreter: a module reaches the defect with its own bytes
;; alone, no flag and no argument. Post-fix the run completes with exit 0.
(module
  (type $s (struct (field (mut i64)) (field (mut i64))))
  (type $a (array (mut i64)))
  (memory 4097)  ;; JIT declines (>256 MiB, #489) -> auto falls back to interp
  (func (export "_start")
    (local $obj (ref null $s)) (local $p i64) (local $i i32)
    (local.set $obj (struct.new $s (i64.const 5) (i64.const 0)))  ;; first alloc -> ref 2
    (local.set $p (i64.const 10))                                 ;; planted integer
    (local.set $i (i32.const 1))                                  ;; odd counter: never a root
    (loop $l
      (drop (array.new_default $a (i32.const 1000)))
      (local.set $i (i32.add (local.get $i) (i32.const 2)))
      (br_if $l (i32.lt_u (local.get $i) (i32.const 601))))
    (drop (struct.get $s 0 (local.get $obj)))))
