;; `br_on_null` as the back edge of a loop that has no params. `passes`
;; returns how many times the loop body ran: the reference is null on the
;; first pass only, and only when n is set, so the edge is taken once for
;; n=1 (2 passes) and never for n=0 (1 pass). One reference type, i31ref.
;; Built with `wasm-tools parse`; the committed .wasm is this text.
(module
  (func (export "passes") (param $n i32) (result i32)
    (local $i i32)
    loop
      local.get $i i32.const 1 i32.add local.set $i
      ref.null i31 i32.const 5 ref.i31 local.get $n select (result i31ref)
      i32.const 0
      local.set $n
      br_on_null 0
      drop
    end
    local.get $i))
