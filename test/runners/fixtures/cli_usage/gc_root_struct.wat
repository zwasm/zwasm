;; A struct kept in a local, an even integer equal to an interior offset of it
;; kept in an i64 local, then ~2.4 MB of garbage so a collection fires at the
;; 1 MiB watermark. The odd loop counter never looks like a root. Post-fix the
;; interior offset is not an object start, so field 0 comes back unchanged.
(module
  (type $s (struct (field (mut i64)) (field (mut i64))))
  (type $a (array (mut i64)))
  (func (export "run") (param $plant i64) (param $f0 i64) (result i64)
    (local $obj (ref null $s)) (local $p i64) (local $i i32)
    (local.set $obj (struct.new $s (local.get $f0) (i64.const 0)))  ;; first alloc -> ref 2
    (local.set $p (local.get $plant))                                ;; planted integer
    (local.set $i (i32.const 1))                                     ;; odd counter: never a root
    (loop $l
      (drop (array.new_default $a (i32.const 1000)))                 ;; 8012 B garbage each
      (local.set $i (i32.add (local.get $i) (i32.const 2)))
      (br_if $l (i32.lt_u (local.get $i) (i32.const 601))))          ;; ~2.4 MB > 1 MiB watermark
    (struct.get $s 0 (local.get $obj))))
