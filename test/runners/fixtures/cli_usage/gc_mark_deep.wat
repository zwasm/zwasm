;; A single linked list of `(lim-1)/2` struct nodes, each holding the next, so
;; a collection's mark reaches the chain one link at a time. Building it past
;; the 1 MiB watermark fires a collection while the whole chain is live, which
;; once recursed one native frame per node and overflowed the native stack on a
;; long enough chain. `run` returns the count it walked back, which equals `lim`
;; for an odd `lim`, so the expected output is the argument itself. Post-fix the
;; mark uses an explicit work list, so the chain marks in a bounded native depth
;; and the walk completes on every engine.
(module
  (type $node (struct (field $val (mut i64)) (field $next (mut (ref null $node)))))
  (func (export "run") (param $lim i32) (result i32)
    (local $head (ref null $node)) (local $i i32) (local $cnt i32)
    (local.set $i (i32.const 1))
    (loop $build
      (local.set $head (struct.new $node (i64.const 1) (local.get $head)))
      (local.set $i (i32.add (local.get $i) (i32.const 2)))
      (br_if $build (i32.lt_u (local.get $i) (local.get $lim))))
    (local.set $cnt (i32.const 1))
    (block $done
      (loop $walk
        (br_if $done (ref.is_null (local.get $head)))
        (local.set $cnt (i32.add (local.get $cnt) (i32.const 2)))
        (local.set $head (struct.get $node $next (local.get $head)))
        (br $walk)))
    (local.get $cnt)))
