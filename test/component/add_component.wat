;; Core module for add_component.wasm: `add: func(a: u32, b: u32) -> u32`.
;; No memory: a lift of an all-scalar signature needs none.
(module
  (func (export "add") (param i32 i32) (result i32)
    (i32.add (local.get 0) (local.get 1))))
