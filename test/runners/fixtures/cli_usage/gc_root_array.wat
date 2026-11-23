;; Like gc_root_struct, but the first allocation is an array of length 1 and the
;; planted even integer equals an interior offset that overlaps the array's
;; length field. Pre-fix a false root set a bit in the length, so the sweep read
;; a corrupt size; post-fix the interior offset is not an object start and
;; array.len reads 1.
(module
  (type $s (struct (field (mut i64)) (field (mut i64))))
  (type $a (array (mut i64)))
  (func (export "len") (param $plant i64) (result i32)
    (local $arr (ref null $a)) (local $p i64) (local $i i32)
    (local.set $arr (array.new_default $a (i32.const 1)))           ;; first alloc -> ref 2
    (local.set $p (local.get $plant))
    (local.set $i (i32.const 1))
    (loop $l
      (drop (array.new_default $a (i32.const 1000)))
      (local.set $i (i32.add (local.get $i) (i32.const 2)))
      (br_if $l (i32.lt_u (local.get $i) (i32.const 601))))
    (array.len (local.get $arr))))
