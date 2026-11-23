;; An ordinary program with nothing planted: build a linked list of $n nodes
;; holding i*mul, then sum them. The only even integer in a local is the
;; program's own loop counter. Once the heap passes 1 MiB a collection fires;
;; post-fix the counter is not an object start, so the sum is exact.
(module
  (type $node (struct (field $val (mut i64)) (field $next (mut (ref null $node)))))
  (func (export "run") (param $n i32) (param $mul i64) (result i64)
    (local $head (ref null $node)) (local $i i32) (local $sum i64)
    (local.set $i (i32.const 0))
    (loop $build
      (local.set $head
        (struct.new $node
          (i64.mul (i64.extend_i32_u (local.get $i)) (local.get $mul))
          (local.get $head)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $build (i32.lt_u (local.get $i) (local.get $n))))
    (block $done
      (loop $walk
        (br_if $done (ref.is_null (local.get $head)))
        (local.set $sum (i64.add (local.get $sum) (struct.get $node $val (local.get $head))))
        (local.set $head (struct.get $node $next (local.get $head)))
        (br $walk)))
    (local.get $sum)))
