;; #400: as br_on_cast_merge_across_call, for br_on_cast_fail. The JIT returned 7.
;; f(struct 30) is not an i31, so it takes the branch with (7, ref): 7 + 30 = 37.
(module
  (type $s (struct (field i32)))
  (func $id (param i32) (result i32) local.get 0)
  (func $f (param $r anyref) (result i32)
    (block (result i32 anyref)
      i32.const 7
      local.get $r
      br_on_cast_fail 0 anyref (ref i31)
      drop
      drop
      i32.const 8
      (struct.new $s (i32.const 0)))
    i32.const 1000
    call $id
    drop
    ref.cast (ref $s)
    struct.get $s 0
    i32.add)
  (func (export "test") (result i32)
    (call $f (struct.new $s (i32.const 30)))))
