;; #400: a block's first exit is br_on_null, and a call runs between the block's end and the
;; use of its result. Liveness did not keep the branch's merge value live, so its register was
;; reused and the JIT returned 2000. f(null) takes the branch with 7: 7 + 1000 = 1007.
(module
  (func $id (param i32) (result i32) local.get 0)
  (func $f (param $r funcref) (result i32)
    (block (result i32)
      i32.const 7
      local.get $r
      br_on_null 0
      drop
      drop
      i32.const 8)
    i32.const 1000
    call $id
    i32.add)
  (func (export "test") (result i32)
    (call $f (ref.null func))))
