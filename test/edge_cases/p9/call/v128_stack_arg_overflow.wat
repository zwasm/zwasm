;; A v128 stack argument must not be written over the caller's own frame.
;;
;; $callee's FP/SIMD arguments fill XMM0..7 (eight f64), so its two v128
;; arguments overflow to the caller's outgoing-args region, each a 16-byte,
;; 16-aligned pair of eightbytes; its integer arguments fill then spill the
;; integer registers. The caller $F holds live values across that call. If the
;; frame reserves the stack-argument region by an eightbyte-per-scalar count
;; that leaves a v128 out, the 16-byte write lands past the region, over one of
;; $F's own slots, and $F returns a value that differs from the spec's.
;;
;; `test` returns 1 only when $F matches the reference value (wasmtime 49.0.4),
;; so a frame that mis-sizes the region fails here.
(module
  (func $h7i (param i64 i64 i64 i64 i64 i64 i64) (result i64) local.get 0)
  (func $h7d (param i64 i64 i64 i64 i64 i64 i64) (result f64) local.get 0 f64.reinterpret_i64)
  (func $callee (param f64 f64 f64 f64 f64 f64 f64 f64 i64 i64 i64 i64 i64 i64 v128 i64 v128) (result i64) (local $acc i64)
    local.get 0 i64.reinterpret_f64 i64.const 3 i64.mul local.get $acc i64.add local.set $acc
    local.get 1 i64.reinterpret_f64 i64.const 5 i64.mul local.get $acc i64.add local.set $acc
    local.get 2 i64.reinterpret_f64 i64.const 7 i64.mul local.get $acc i64.add local.set $acc
    local.get 3 i64.reinterpret_f64 i64.const 9 i64.mul local.get $acc i64.add local.set $acc
    local.get 4 i64.reinterpret_f64 i64.const 11 i64.mul local.get $acc i64.add local.set $acc
    local.get 5 i64.reinterpret_f64 i64.const 13 i64.mul local.get $acc i64.add local.set $acc
    local.get 6 i64.reinterpret_f64 i64.const 15 i64.mul local.get $acc i64.add local.set $acc
    local.get 7 i64.reinterpret_f64 i64.const 17 i64.mul local.get $acc i64.add local.set $acc
    local.get 8 i64.const 19 i64.mul local.get $acc i64.add local.set $acc
    local.get 9 i64.const 21 i64.mul local.get $acc i64.add local.set $acc
    local.get 10 i64.const 23 i64.mul local.get $acc i64.add local.set $acc
    local.get 11 i64.const 25 i64.mul local.get $acc i64.add local.set $acc
    local.get 12 i64.const 27 i64.mul local.get $acc i64.add local.set $acc
    local.get 13 i64.const 29 i64.mul local.get $acc i64.add local.set $acc
    local.get 14 i64x2.extract_lane 0 local.get 14 i64x2.extract_lane 1 i64.const 7 i64.mul i64.add i64.const 31 i64.mul local.get $acc i64.add local.set $acc
    local.get 15 i64.const 33 i64.mul local.get $acc i64.add local.set $acc
    local.get 16 i64x2.extract_lane 0 local.get 16 i64x2.extract_lane 1 i64.const 7 i64.mul i64.add i64.const 35 i64.mul local.get $acc i64.add local.set $acc
    local.get $acc)
  (func $F (result i64)
    i64.const 1229764173248921601 i64.const 1229764173249970177 i64.const 1229764173251018753 i64.const 1229764173252067329 i64.const 1229764173253115905 i64.const 1229764173254164481 i64.const 1229764173255213057 call $h7d
    i64.const 1229764173248987138 i64.const 1229764173250035714 i64.const 1229764173251084290 i64.const 1229764173252132866 i64.const 1229764173253181442 i64.const 1229764173254230018 i64.const 1229764173255278594 call $h7d
    i64.const 1229764173249052675 i64.const 1229764173250101251 i64.const 1229764173251149827 i64.const 1229764173252198403 i64.const 1229764173253246979 i64.const 1229764173254295555 i64.const 1229764173255344131 call $h7d
    i64.const 1229764173249118212 i64.const 1229764173250166788 i64.const 1229764173251215364 i64.const 1229764173252263940 i64.const 1229764173253312516 i64.const 1229764173254361092 i64.const 1229764173255409668 call $h7d
    i64.const 1229764173249183749 i64.const 1229764173250232325 i64.const 1229764173251280901 i64.const 1229764173252329477 i64.const 1229764173253378053 i64.const 1229764173254426629 i64.const 1229764173255475205 call $h7d
    i64.const 1229764173249249286 i64.const 1229764173250297862 i64.const 1229764173251346438 i64.const 1229764173252395014 i64.const 1229764173253443590 i64.const 1229764173254492166 i64.const 1229764173255540742 call $h7d
    i64.const 1229764173249314823 i64.const 1229764173250363399 i64.const 1229764173251411975 i64.const 1229764173252460551 i64.const 1229764173253509127 i64.const 1229764173254557703 i64.const 1229764173255606279 call $h7d
    i64.const 1229764173249380360 i64.const 1229764173250428936 i64.const 1229764173251477512 i64.const 1229764173252526088 i64.const 1229764173253574664 i64.const 1229764173254623240 i64.const 1229764173255671816 call $h7d
    i64.const 1229764173249445897 i64.const 1229764173250494473 i64.const 1229764173251543049 i64.const 1229764173252591625 i64.const 1229764173253640201 i64.const 1229764173254688777 i64.const 1229764173255737353 call $h7i
    i64.const 1229764173249511434 i64.const 1229764173250560010 i64.const 1229764173251608586 i64.const 1229764173252657162 i64.const 1229764173253705738 i64.const 1229764173254754314 i64.const 1229764173255802890 call $h7i
    i64.const 1229764173249576971 i64.const 1229764173250625547 i64.const 1229764173251674123 i64.const 1229764173252722699 i64.const 1229764173253771275 i64.const 1229764173254819851 i64.const 1229764173255868427 call $h7i
    i64.const 1229764173249642508 i64.const 1229764173250691084 i64.const 1229764173251739660 i64.const 1229764173252788236 i64.const 1229764173253836812 i64.const 1229764173254885388 i64.const 1229764173255933964 call $h7i
    i64.const 1229764173249708045 i64.const 1229764173250756621 i64.const 1229764173251805197 i64.const 1229764173252853773 i64.const 1229764173253902349 i64.const 1229764173254950925 i64.const 1229764173255999501 call $h7i
    i64.const 4919056692996341774
    v128.const i64x2 6149008513365446415 7378791451327401743
    i64.const 4919056692996472848
    v128.const i64x2 6149008513365446929 7378791451327533329
    call $callee)
  (func (export "test") (result i32)
    (i64.eq (call $F) (i64.const 6190139749374905223))))
