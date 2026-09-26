;; Core module behind test/component/two_iface.wasm: one scalar func per
;; exported interface. The two bodies differ (v+1 vs v*2) so a resolver that
;; maps the second interface onto the first one's instance is caught by the
;; value, not just by a name lookup.
;;
;; The funcs never touch memory; it is exported because every toolchain-built
;; guest exports one and the single-module typed invoke path requires it.
(module
  (memory (export "memory") 1)
  (func (export "local:twoiface/first@0.1.0#inc") (param $v i32) (result i32)
    (i32.add (local.get $v) (i32.const 1)))
  (func (export "local:twoiface/second@0.1.0#double") (param $v i32) (result i32)
    (i32.mul (local.get $v) (i32.const 2))))
