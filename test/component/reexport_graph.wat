(component
  ;; ---- child component B: exports adder: func(u32,u32)->u32 ----
  (component $B
    (core module $MB
      (func (export "adder") (param i32 i32) (result i32)
        local.get 0 local.get 1 i32.add))
    (core instance $ib (instantiate $MB))
    (func (export "adder") (param "a" u32) (param "b" u32) (result u32)
      (canon lift (core func $ib "adder")))
  )

  ;; ---- child component A: imports adder, exports add-five: func(u32)->u32 ----
  (component $A
    (import "adder" (func $adder (param "a" u32) (param "b" u32) (result u32)))
    (core func $adder_core (canon lower (func $adder)))
    (core module $MA
      (import "deps" "adder" (func $adder (param i32 i32) (result i32)))
      (func (export "add-five") (param i32) (result i32)
        local.get 0 i32.const 5 call $adder))
    (core instance $deps (export "adder" (func $adder_core)))
    (core instance $ia (instantiate $MA (with "deps" (instance $deps))))
    (func (export "add-five") (param "x" u32) (result u32)
      (canon lift (core func $ia "add-five")))
  )

  ;; ---- outer: every child instance is exported, and every reference to a
  ;; child goes through its export's index, not the instantiate's ----
  (instance $b (instantiate $B))                                  ;; instance 0: definition 0
  (export $bx "b" (instance $b))                                  ;; instance 1: re-exports 0
  (instance $a (instantiate $A (with "adder" (func $bx "adder"))));; instance 2: definition 1
  (export $ax "a" (instance $a))                                  ;; instance 3: re-exports 2
  (export "add-five" (func $ax "add-five"))
)
