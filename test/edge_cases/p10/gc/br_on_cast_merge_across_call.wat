;; #400: as br_on_null_merge_across_call, for br_on_cast, which keeps the ref on the stack.
;; The JIT returned 7. f(struct 30) casts, so it takes the branch with (7, ref): 7 + 30 = 37.
(module
  (type $s (struct (field i32)))
  (func $id (param i32) (result i32) local.get 0)
  (func $f (param $r anyref) (result i32)
    (block (result i32 (ref $s))
      i32.const 7
      local.get $r
      br_on_cast 0 anyref (ref $s)
      drop
      drop
      i32.const 8
      (struct.new $s (i32.const 0)))
    i32.const 1000
    call $id
    drop
    struct.get $s 0
    i32.add)
  (func (export "test") (result i32)
    (call $f (struct.new $s (i32.const 30)))))
