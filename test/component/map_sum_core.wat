(module
  (memory (export "memory") 1)

  ;; Bump allocator backing cabi_realloc; the cursor starts at 1024.
  (global $next (mut i32) (i32.const 1024))

  ;; cabi_realloc(old_ptr, old_size, align, new_size) -> ptr
  ;; Ignores old_ptr/old_size; bump-allocates new_size aligned to `align`.
  (func (export "cabi_realloc")
    (param $old_ptr i32) (param $old_size i32) (param $align i32) (param $new_size i32)
    (result i32)
    (local $ptr i32)
    (local $mask i32)
    (local.set $mask (i32.sub (local.get $align) (i32.const 1)))
    (local.set $ptr
      (i32.and
        (i32.add (global.get $next) (local.get $mask))
        (i32.xor (local.get $mask) (i32.const -1))))
    (global.set $next (i32.add (local.get $ptr) (local.get $new_size)))
    (local.get $ptr))

  ;; f(x: map<string, u32>) -> u32, lowered as list<tuple<string, u32>>:
  ;; (ptr, len) of 12-byte elements [key_ptr, key_len, value]; returns the
  ;; sum of the values.
  (func (export "test:m/m#f") (param $ptr i32) (param $len i32) (result i32)
    (local $sum i32)
    (block $done
      (loop $next
        (br_if $done (i32.eqz (local.get $len)))
        (local.set $sum
          (i32.add (local.get $sum) (i32.load offset=8 (local.get $ptr))))
        (local.set $ptr (i32.add (local.get $ptr) (i32.const 12)))
        (local.set $len (i32.sub (local.get $len) (i32.const 1)))
        (br $next)))
    (local.get $sum)))
