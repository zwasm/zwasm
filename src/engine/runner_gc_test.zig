// FILE-SIZE-EXEMPT: pure test suite already P1+P3-extracted from runner_test.zig (ADR-0128); slicing duplicates fixtures (N4) (investigated 2026-08-12, per ADR-0099)
//! GC-on-JIT end-to-end tests (ADR-0128 §1 / §2) extracted from
//! `runner_test.zig` (P1 spec-defined sub-language + P3 independent
//! change cadence — the gc/ref op family evolves on its own track and
//! kept pushing `runner_test.zig` toward the 2000-line hard cap).
//! Covers the i31 / struct / array / ref.eq / ref.test / ref.cast op
//! families + gc const-expr globals, all driven through the JIT entry
//! (`runI32Export` / `JitInstance`). Discovered by the unit-test loader
//! via `src/zwasm.zig`'s `test {}` block. wat2wasm 1.0.40 predates gc
//! textual support, so module bytes are hand-encoded.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const skip = @import("../test_support/skip.zig");

const runner = @import("runner.zig");
const runI32Export = runner.runI32Export;
const runF32Export = runner.runF32Export;
const JitInstance = runner.JitInstance;

const entry = @import("codegen/shared/entry.zig");
const heap_mod = @import("../feature/gc/heap.zig");

// ============================================================
// 10.G GC-on-JIT — i31 op family e2e (ref.i31 / i31.get_s /
// i31.get_u), both arches. The round-trip runs through compileWasm
// (JIT) → callI32NoArgs (JIT entry). wat2wasm 1.0.40 predates i31
// textual support, so bytes are hand-encoded (opcodes verified
// against test/spec/.../gc/i31/i31.0.wasm).

test "runI32Export: ref.i31 + i31.get_s positive round-trip → 1234 (10.G JIT)" {
    // (module (func (export "f") (result i32)
    //   i32.const 1234  ref.i31  i31.get_s))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type ()->(i32)
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        0x0a, 0x0b, 0x01, 0x09, 0x00, 0x41, 0xd2,
        0x09, 0xfb, 0x1c, 0xfb, 0x1d, 0x0b,
    };
    try testing.expectEqual(@as(u32, 1234), try runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.i31(-1) + i31.get_u → 0x7FFFFFFF (high bit zero; 10.G JIT)" {
    // (module (func (export "f") (result i32)
    //   i32.const -1  ref.i31  i31.get_u))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00, 0x0a, 0x0a, 0x01, 0x08, 0x00, 0x41,
        0x7f, 0xfb, 0x1c, 0xfb, 0x1e, 0x0b,
    };
    try testing.expectEqual(@as(u32, 0x7FFF_FFFF), try runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: i31.get_s on null i31ref traps (10.G JIT)" {
    // (module (func (export "f") (result i32)
    //   ref.null i31  i31.get_s))  ;; spec: traps on null input
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00,
        // code: body is 6 bytes (locals + ref.null i31 [d0 6c] +
        // i31.get_s [fb 1d] + end), so body_size=0x06, sect size=0x08.
        0x0a, 0x08, 0x01, 0x06, 0x00, 0xd0,
        0x6c, 0xfb, 0x1d, 0x0b,
    };
    try testing.expectError(entry.Error.Trap, runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: try_table (result i32) value survives to function return → 42 (10.E)" {
    // Regression for the try_table label-arity drop: the arm64/x86_64
    // try_table emit pushed its label with hardcoded result_arity=0,
    // param_arity=0 (ignoring the blocktype arity the lowerer threads in
    // ZirInstr.extra). The matching `end`'s stack truncation then computed
    // new_len = entry_depth − 0 + 0 = entry_depth and DISCARDED the
    // try_table's result vreg → a later consumer (here the function return)
    // marshalled an empty stack → stale register returned instead of 42.
    // (Caught-path landing worked by luck; this is the normal-completion path.)
    // (module (func (export "f") (result i32) (try_table (result i32) (i32.const 42))))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type ()->(i32)
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: body=8 (locals=0; try_table 0x1f blocktype=i32 0x7f catch-count=0;
        //   i32.const 42 [0x41 0x2a]; end [0x0b]; end [0x0b])
        0x0a, 0x0a, 0x01, 0x08, 0x00, 0x1f, 0x7f,
        0x00, 0x41, 0x2a, 0x0b, 0x0b,
    };
    try testing.expectEqual(@as(u32, 42), try runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: struct.new_default + ref.is_null → 0 (10.G struct-on-JIT A-2b-1)" {
    // Ungated for x86_64: the SysV struct.new_default emit landed (D-211
    // mirror); runs on both Mac aarch64 and Linux x86_64 (ubuntu gate).
    // (module
    //   (type (struct (field (mut i32))))    ;; type 0
    //   (func (export "f") (result i32)        ;; type 1
    //     struct.new_default 0  ref.is_null))  ;; fresh struct is non-null → 0
    // Exercises the full alloc path: JIT validate (GC type-kind threading)
    // → struct.new_default emit → jitGcAlloc trampoline → setupRuntime-wired
    // Heap. wat2wasm 1.0.40 lacks GC text; hand-encoded (struct.new_default
    // = fb 01 typeidx; ref.is_null = d1). arm64 first; x86_64 emit = D-211.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=struct{i32 mut} (5f 01 7f 01), [1]=func ()->(i32) (60 00 01 7f)
        0x01, 0x09, 0x02, 0x5f, 0x01, 0x7f, 0x01, 0x60,
        0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: body 6 bytes (locals + struct.new_default 0 [fb 01 00] +
        // ref.is_null [d1] + end), body_size=0x06, sect size=0x08.
        0x0a, 0x08, 0x01, 0x06, 0x00, 0xfb, 0x01,
        0x00, 0xd1, 0x0b,
    };
    try testing.expectEqual(@as(u32, 0), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: struct.new_default + struct.get 0 0 → 0 (10.G struct-on-JIT A-2b-2)" {
    // Ungated for x86_64: the SysV struct.get emit landed (D-211 mirror);
    // runs on both Mac aarch64 and Linux x86_64 (ubuntu gate).
    // (module
    //   (type (struct (field (mut i32))))    ;; type 0
    //   (func (export "f") (result i32)        ;; type 1
    //     struct.new_default 0  struct.get 0 0))  ;; zero-inited field → 0
    // Exercises the field-load path: JIT validate → struct.new_default
    // emit (alloc) → struct.get emit (null-trap + slab-base load of the
    // 8-byte field slot) → result on stack. Derived from the A-2b-1 module
    // by replacing ref.is_null (d1, 1 byte) with struct.get 0 0
    // (fb 02 00 00, 4 bytes); body_size + sect_size each +3.
    // arm64 first; x86_64 emit = D-211.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=struct{i32 mut} (5f 01 7f 01), [1]=func ()->(i32) (60 00 01 7f)
        0x01, 0x09, 0x02, 0x5f, 0x01, 0x7f, 0x01, 0x60,
        0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: body 9 bytes (locals + struct.new_default 0 [fb 01 00] +
        // struct.get 0 0 [fb 02 00 00] + end), body_size=0x09, sect size=0x0b.
        0x0a, 0x0b, 0x01, 0x09, 0x00, 0xfb, 0x01,
        0x00, 0xfb, 0x02, 0x00, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 0), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: i32.const 42 + struct.new 0 + struct.get 0 0 → 42 (10.G struct-on-JIT A-3)" {
    // Ungated for x86_64: the SysV struct.new emit landed (A-3 mirror);
    // runs on both Mac aarch64 and Linux x86_64 (ubuntu gate).
    // (module
    //   (type (struct (field (mut i32))))    ;; type 0
    //   (func (export "f") (result i32)        ;; type 1
    //     i32.const 42  struct.new 0  struct.get 0 0))  ;; field 0 = 42
    // Exercises the variadic struct.new emit: the i32.const 42 field
    // operand is force-spilled across the jitGcAlloc BLR (ADR-0060 amend),
    // then struct.new reloads the slab base AFTER the alloc and stores 42
    // at [slab+ref+8]; struct.get reads it back → 42. struct.new =
    // fb 00 typeidx; field count comes from the struct type (1), stamped
    // into ZirInstr.extra by the lowerer. wat2wasm 1.0.40 lacks GC text;
    // hand-encoded (i32.const 42 = 41 2a; struct.new 0 = fb 00 00).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=struct{i32 mut} (5f 01 7f 01), [1]=func ()->(i32) (60 00 01 7f)
        0x01, 0x09, 0x02, 0x5f, 0x01, 0x7f, 0x01, 0x60,
        0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: body 11 bytes (locals 00 + i32.const 42 [41 2a] +
        // struct.new 0 [fb 00 00] + struct.get 0 0 [fb 02 00 00] + end 0b),
        // body_size=0x0b, sect size=0x0d.
        0x0a, 0x0d, 0x01, 0x0b, 0x00, 0x41, 0x2a,
        0xfb, 0x00, 0x00, 0xfb, 0x02, 0x00, 0x00,
        0x0b,
    };
    try testing.expectEqual(@as(u32, 42), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: struct.set then struct.get round-trip → 55 (10.G struct-on-JIT A-3 set)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module
    //   (type (struct (field (mut i32))))             ;; type 0
    //   (func (export "f") (result i32) (local (ref null 0))  ;; type 1
    //     struct.new_default 0  local.tee 0  i32.const 55
    //     struct.set 0 0  local.get 0  struct.get 0 0))  ;; field 0 ← 55
    // Exercises struct.set: pop value(55) + ref (null-trap), reload slab
    // base, store 55 at [slab+ref+8]; struct.get reads it back → 55 (vs
    // the zero-inited 0 without the set). A `(ref null 0)` local (63 00)
    // holds the ref across the set/get via local.tee/local.get. struct.set
    // = fb 05 typeidx fieldidx; i32.const 55 = 41 37 (55 < 64 → single-byte
    // signed LEB128, bit 6 clear; do NOT use values ≥ 64 unencoded).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=struct{i32 mut} (5f 01 7f 01), [1]=func ()->(i32) (60 00 01 7f)
        0x01, 0x09, 0x02, 0x5f, 0x01, 0x7f, 0x01, 0x60,
        0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: body 22 bytes. locals = 1 group of 1×(ref null 0) [01 01 63 00];
        // struct.new_default 0 [fb 01 00] + local.tee 0 [22 00] +
        // i32.const 99 [41 63] + struct.set 0 0 [fb 05 00 00] +
        // local.get 0 [20 00] + struct.get 0 0 [fb 02 00 00] + end [0b].
        // body_size=0x16, sect size=0x18.
        0x0a, 0x18, 0x01, 0x16, 0x01, 0x01, 0x63,
        0x00, 0xfb, 0x01, 0x00, 0x22, 0x00, 0x41,
        0x37, 0xfb, 0x05, 0x00, 0x00, 0x20, 0x00,
        0xfb, 0x02, 0x00, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 55), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: array.new_default + array.len → 3 (10.G array-on-JIT A-2)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module
    //   (type (array (mut i32)))             ;; type 0
    //   (func (export "f") (result i32)        ;; type 1
    //     i32.const 3  array.new_default 0  array.len))  ;; length → 3
    // Exercises array.new_default (pop length=3 → arg2, CALL jitGcAllocArray
    // → ref) + array.len (null-trap ref, reload slab, LDR length [base+8]).
    // wat2wasm 1.0.40 lacks GC text; hand-encoded (array type = 5E 7F 01;
    // array.new_default 0 = fb 07 00; array.len = fb 0f; i32.const 3 = 41 03).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=array{i32 mut} (5e 7f 01), [1]=func ()->(i32) (60 00 01 7f)
        0x01, 0x08, 0x02, 0x5e, 0x7f, 0x01, 0x60, 0x00,
        0x01, 0x7f,
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: body 9 bytes (locals 00 + i32.const 3 [41 03] +
        // array.new_default 0 [fb 07 00] + array.len [fb 0f] + end 0b),
        // body_size=0x09, sect size=0x0b.
        0x0a, 0x0b, 0x01, 0x09, 0x00, 0x41, 0x03,
        0xfb, 0x07, 0x00, 0xfb, 0x0f, 0x0b,
    };
    try testing.expectEqual(@as(u32, 3), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: array.set then array.get round-trip → 55 (10.G array-on-JIT A-3)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module
    //   (type (array (mut i32)))                       ;; type 0
    //   (func (export "f") (result i32) (local (ref null 0))  ;; type 1
    //     i32.const 3  array.new_default 0  local.tee 0
    //     i32.const 1  i32.const 55  array.set 0        ;; elem[1] = 55
    //     local.get 0  i32.const 1  array.get 0))       ;; elem[1] → 55
    // Exercises array.set (pop value+index+ref, bounds-check, register-
    // offset store at [base+12+index*8]) + array.get (bounds-check +
    // register-offset load). A `(ref null 0)` local (63 00) holds the ref.
    // array.set = fb 0e typeidx; array.get = fb 0b typeidx; i32.const 55 =
    // 41 37 (< 64 → single-byte signed LEB128).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=array{i32 mut} (5e 7f 01), [1]=func ()->(i32) (60 00 01 7f)
        0x01, 0x08, 0x02, 0x5e, 0x7f, 0x01, 0x60, 0x00,
        0x01, 0x7f,
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: body 26 bytes. locals 1×(ref null 0) [01 01 63 00];
        // i32.const 3 [41 03] + array.new_default 0 [fb 07 00] +
        // local.tee 0 [22 00] + i32.const 1 [41 01] + i32.const 55 [41 37] +
        // array.set 0 [fb 0e 00] + local.get 0 [20 00] + i32.const 1 [41 01]
        // + array.get 0 [fb 0b 00] + end [0b]. body_size=0x1a, sect=0x1c.
        0x0a, 0x1c, 0x01, 0x1a, 0x01, 0x01, 0x63,
        0x00, 0x41, 0x03, 0xfb, 0x07, 0x00, 0x22,
        0x00, 0x41, 0x01, 0x41, 0x37, 0xfb, 0x0e,
        0x00, 0x20, 0x00, 0x41, 0x01, 0xfb, 0x0b,
        0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 55), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: array.new fill + array.get → 7 (10.G array-on-JIT A-4)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module
    //   (type (array (mut i32)))             ;; type 0
    //   (func (export "f") (result i32)        ;; type 1
    //     i32.const 7  i32.const 3  array.new 0  i32.const 1  array.get 0))
    // array.new pops [init=7, length=3] (length on top), allocs + fills all
    // 3 elements with 7 via the jitGcAllocArrayFill trampoline; array.get
    // reads elem[1] → 7 (vs 0 if the fill didn't run). No local needed (the
    // ref flows new → get directly). array.new = fb 06 typeidx.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=array{i32 mut} (5e 7f 01), [1]=func ()->(i32) (60 00 01 7f)
        0x01, 0x08, 0x02, 0x5e, 0x7f, 0x01, 0x60, 0x00,
        0x01, 0x7f,
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: body 14 bytes (locals 00 + i32.const 7 [41 07] + i32.const 3
        // [41 03] + array.new 0 [fb 06 00] + i32.const 1 [41 01] +
        // array.get 0 [fb 0b 00] + end 0b). body_size=0x0e, sect size=0x10.
        0x0a, 0x10, 0x01, 0x0e, 0x00, 0x41, 0x07,
        0x41, 0x03, 0xfb, 0x06, 0x00, 0x41, 0x01,
        0xfb, 0x0b, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 7), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: array.new_fixed 3 elems + array.get → 30 (10.G array-on-JIT A-5)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module
    //   (type (array (mut i32)))             ;; type 0
    //   (func (export "f") (result i32)        ;; type 1
    //     i32.const 10  i32.const 20  i32.const 30
    //     array.new_fixed 0 3                  ;; elem[0]=10 elem[1]=20 elem[2]=30
    //     i32.const 2  array.get 0))           ;; elem[2] → 30
    // array.new_fixed is variadic (N=3 compile-time): allocs a length-3
    // array via jitGcAllocArray, then stores the 3 popped values inline at
    // [base+12+i*8] in DECLARED order (reverse-pop). Reading elem[2] → 30
    // verifies both the reverse-pop ordering (top operand 30 lands in the
    // highest slot) AND the force-spill across the alloc CALL (a clobbered
    // field value would corrupt the result). array.new_fixed = fb 08 typeidx N.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=array{i32 mut} (5e 7f 01), [1]=func ()->(i32) (60 00 01 7f)
        0x01, 0x08, 0x02, 0x5e, 0x7f, 0x01, 0x60, 0x00,
        0x01, 0x7f,
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: body 17 bytes (locals 00 + i32.const 10 [41 0a] + i32.const 20
        // [41 14] + i32.const 30 [41 1e] + array.new_fixed 0 3 [fb 08 00 03] +
        // i32.const 2 [41 02] + array.get 0 [fb 0b 00] + end 0b).
        // body_size=0x11, sect size=0x13.
        0x0a, 0x13, 0x01, 0x11, 0x00, 0x41, 0x0a,
        0x41, 0x14, 0x41, 0x1e, 0xfb, 0x08, 0x00,
        0x03, 0x41, 0x02, 0xfb, 0x0b, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 30), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: array.get_s on i8 element 0xC8 → -56 (10.G array-on-JIT A-6a)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module
    //   (type (array (mut i8)))                ;; type 0 — PACKED i8 (5e 78 01)
    //   (func (export "f") (result i32)          ;; type 1
    //     i32.const 200  array.new_fixed 0 1     ;; 1-elem i8 array [0xC8]
    //     i32.const 0  array.get_s 0))           ;; sign-extend 0xC8 → -56
    // array.get_s loads the 8-byte slot (like array.get A-3) then sign-extends
    // the LOW byte (SXTB / MOVSX) since the element is packed i8. 0xC8 sign-
    // extends to -56 (u32 0xFFFFFFC8 = 4294967240); a raw load (no SXTB) would
    // give 200, so the result confirms the extend ran. The packed width (i8 vs
    // i16) is threaded from the type section into ZirInstr.extra at lower time
    // (mirror struct_field_counts). array.get_s = fb 0c typeidx.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=array{i8 mut} (5e 78 01), [1]=func ()->(i32) (60 00 01 7f)
        0x01, 0x08, 0x02, 0x5e, 0x78, 0x01, 0x60, 0x00,
        0x01, 0x7f,
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: body 14 bytes (locals 00 + i32.const 200 [41 c8 01] +
        // array.new_fixed 0 1 [fb 08 00 01] + i32.const 0 [41 00] +
        // array.get_s 0 [fb 0c 00] + end 0b). body_size=0x0e, sect size=0x10.
        0x0a, 0x10, 0x01, 0x0e, 0x00, 0x41, 0xc8,
        0x01, 0xfb, 0x08, 0x00, 0x01, 0x41, 0x00,
        0xfb, 0x0c, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 4294967240), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: array.get_u on i8 element 0xC8 → 200 (10.G array-on-JIT A-6b)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module
    //   (type (array (mut i8)))                ;; type 0 — PACKED i8 (5e 78 01)
    //   (func (export "f") (result i32)          ;; type 1
    //     i32.const -56  array.new_fixed 0 1     ;; 1-elem i8 array; slot = 0x..FFFFFFC8
    //     i32.const 0  array.get_u 0))           ;; zero-extend low byte 0xC8 → 200
    // array.get_u loads the 8-byte slot then ZERO-extends the low byte (UXTB /
    // MOVZX). Storing i32.const -56 leaves the slot = 0x00000000FFFFFFC8 (the
    // i32.const zero-extends into the 64-bit reg, then 8 bytes stored), so a raw
    // load (no UXTB) gives 4294967240; the masked get_u gives 200 — the result
    // confirms the zero-extend ran. array.get_u = fb 0d typeidx. i32.const -56 =
    // signed LEB128 41 c8 7f.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=array{i8 mut} (5e 78 01), [1]=func ()->(i32) (60 00 01 7f)
        0x01, 0x08, 0x02, 0x5e, 0x78, 0x01, 0x60, 0x00,
        0x01, 0x7f,
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: body 14 bytes (locals 00 + i32.const -56 [41 c8 7f] +
        // array.new_fixed 0 1 [fb 08 00 01] + i32.const 0 [41 00] +
        // array.get_u 0 [fb 0d 00] + end 0b). body_size=0x0e, sect size=0x10.
        0x0a, 0x10, 0x01, 0x0e, 0x00, 0x41, 0xc8,
        0x7f, 0xfb, 0x08, 0x00, 0x01, 0x41, 0x00,
        0xfb, 0x0d, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 200), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: array.fill then array.get → 42 (10.G array-on-JIT A-7)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module
    //   (type (array (mut i32)))               ;; type 0
    //   (func (export "f") (result i32) (local (ref null 0))
    //     i32.const 5  array.new_default 0  local.tee 0  ;; 5-elem zero array, ref→local0+stack
    //     i32.const 1  i32.const 42  i32.const 3  array.fill 0 ;; fill elem[1,2,3]=42
    //     local.get 0  i32.const 2  array.get 0))          ;; elem[2] → 42
    // array.fill pops [ref, idx, value, count]; the emit marshals all 6
    // trampoline args (rt+typeidx+ref/idx/value/count) → CALL jitGcArrayFill →
    // CMP result,#0; B.EQ→bounds_fixups (trap on null/OOB). 4→0 (no push). The
    // ref is kept across the consuming fill via a `(ref null 0)` local + tee.
    // array.fill = fb 10 typeidx. local type (ref null 0) = 63 00.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=array{i32 mut} (5e 7f 01), [1]=func ()->(i32) (60 00 01 7f)
        0x01, 0x08, 0x02, 0x5e, 0x7f, 0x01, 0x60, 0x00,
        0x01, 0x7f,
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: body 28 bytes. locals: 1 group [count 1, (ref null 0) = 63 00]
        // = 01 01 63 00. i32.const 5 [41 05] + array.new_default 0 [fb 07 00] +
        // local.tee 0 [22 00] + i32.const 1 [41 01] + i32.const 42 [41 2a] +
        // i32.const 3 [41 03] + array.fill 0 [fb 10 00] + local.get 0 [20 00] +
        // i32.const 2 [41 02] + array.get 0 [fb 0b 00] + end 0b.
        // body_size=0x1c, sect size=0x1e.
        0x0a, 0x1e, 0x01, 0x1c, 0x01, 0x01, 0x63,
        0x00, 0x41, 0x05, 0xfb, 0x07, 0x00, 0x22,
        0x00, 0x41, 0x01, 0x41, 0x2a, 0x41, 0x03,
        0xfb, 0x10, 0x00, 0x20, 0x00, 0x41, 0x02,
        0xfb, 0x0b, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 42), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.eq distinct arrays → 0 (10.G ref-on-JIT A-8)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module (type (array (mut i32)))
    //   (func (export "f") (result i32)
    //     i32.const 1  array.new_fixed 0 1   ;; ref A
    //     i32.const 1  array.new_fixed 0 1   ;; ref B (distinct slab offset)
    //     ref.eq))                            ;; A != B → 0
    // ref.eq pops two eqrefs, compares the (zero-extended) ref values, pushes
    // i32 (1=same / 0=distinct). Two array.new_fixed allocate distinct objects
    // → 0. Emit = CMP + CSET .eq (arm64) / CMP + SETE + MOVZX (x86_64); no
    // trampoline, no heap. ref.eq = single-byte 0xD3.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x02, 0x5e, 0x7f, 0x01, 0x60, 0x00,
        0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07, 0x05,
        0x01, 0x01, 0x66, 0x00, 0x00,
        // body 15 bytes: locals 00 + i32.const 1 [41 01] + array.new_fixed 0 1
        // [fb 08 00 01] + i32.const 1 [41 01] + array.new_fixed 0 1 [fb 08 00 01]
        // + ref.eq [d3] + end [0b]. body_size=0x0f, sect=0x11.
        0x0a, 0x11, 0x01,
        0x0f, 0x00, 0x41, 0x01, 0xfb, 0x08, 0x00, 0x01,
        0x41, 0x01, 0xfb, 0x08, 0x00, 0x01, 0xd3, 0x0b,
    };
    try testing.expectEqual(@as(u32, 0), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.eq same ref → 1 (10.G ref-on-JIT A-8)" {
    // (module (type (array (mut i32)))
    //   (func (export "f") (result i32) (local (ref null 0))
    //     i32.const 1  array.new_fixed 0 1  local.tee 0  local.get 0  ref.eq))
    // Same non-null ref compared to itself → 1 (exercises the equal path with a
    // real GcRef, kept via a (ref null 0) local + tee/get). local (ref null 0)
    // = 63 00.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x02, 0x5e, 0x7f, 0x01, 0x60, 0x00,
        0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07, 0x05,
        0x01, 0x01, 0x66, 0x00, 0x00,
        // body 16 bytes: locals 01 01 63 00 + i32.const 1 [41 01] +
        // array.new_fixed 0 1 [fb 08 00 01] + local.tee 0 [22 00] +
        // local.get 0 [20 00] + ref.eq [d3] + end [0b]. body_size=0x10, sect=0x12.
        0x0a, 0x12, 0x01,
        0x10, 0x01, 0x01, 0x63, 0x00, 0x41, 0x01, 0xfb,
        0x08, 0x00, 0x01, 0x22, 0x00, 0x20, 0x00, 0xd3,
        0x0b,
    };
    try testing.expectEqual(@as(u32, 1), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: array.copy src→dst then array.get → 20 (10.G array-on-JIT A-9)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module (type (array (mut i32)))
    //   (func (export "f") (result i32) (local (ref null 0)) (local (ref null 0))
    //     i32.const 3  array.new_default 0  local.set 0          ;; dst = [0,0,0]
    //     i32.const 10 i32.const 20 i32.const 30 array.new_fixed 0 3  local.set 1 ;; src=[10,20,30]
    //     local.get 0  i32.const 1  local.get 1  i32.const 0  i32.const 2  array.copy 0 0
    //       ;; copy src[0..2) → dst[1..3): dst[1]=10, dst[2]=20
    //     local.get 0  i32.const 2  array.get 0))                ;; dst[2] → 20
    // array.copy pops [dst_ref, dst_off, src_ref, src_off, len]; emit marshals 6
    // trampoline args (rt + those 5; typeidx args dropped — esz=8 uniform per
    // ADR-0116 §3a) → CALL jitGcArrayCopy (null+bounds-check + overlap-aware
    // copy in Zig) → CMP/TEST result,0; B.EQ/JE → bounds_fixups. 5→0. array.copy
    // = fb 11 dst_ty src_ty. 2 (ref null 0) locals = 01 02 63 00.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x02, 0x5e, 0x7f, 0x01, 0x60, 0x00,
        0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07, 0x05,
        0x01, 0x01, 0x66, 0x00, 0x00,
        // body 45 bytes (0x2d); sect size 0x2f. See test comment for the op stream.
        0x0a, 0x2f, 0x01,
        0x2d,
        0x01, 0x02, 0x63, 0x00, // locals: 2 × (ref null 0)
        0x41, 0x03, 0xfb, 0x07, 0x00, 0x21, 0x00, // i32.const 3; array.new_default 0; local.set 0
        0x41, 0x0a, 0x41, 0x14, 0x41, 0x1e, 0xfb, 0x08, 0x00, 0x03, 0x21, 0x01, // [10,20,30]; new_fixed; set 1
        0x20, 0x00, 0x41, 0x01, 0x20, 0x01, 0x41, 0x00, 0x41, 0x02, 0xfb, 0x11, 0x00, 0x00, // copy args + array.copy 0 0
        0x20, 0x00, 0x41, 0x02, 0xfb, 0x0b, 0x00, // local.get 0; i32.const 2; array.get 0
        0x0b,
    };
    try testing.expectEqual(@as(u32, 20), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: array.copy self-region (dst_off==src_off) is alias-safe → 20 (ADR-0192; wasmtime gc)" {
    // JIT counterpart of the interp array_ops.zig regression: jitGcArrayCopy
    // used per-element @memcpy, which panics "@memcpy arguments alias" when a
    // region is copied onto itself (same array, dst_off == src_off). Seeds a
    // 4-elem array [10,20,30,40], self-copies slots [1..3), reads a[1] → 20.
    // (Reduction of test/edge_cases/p10/gc/array_copy_self_overlap.wat.)
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x5e,
        0x7f, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07, 0x08,
        0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x0a, 0x47, 0x01, 0x45,
        0x01, 0x01, 0x64, 0x00, 0x41, 0x04, 0xfb, 0x07, 0x00, 0x21, 0x00, 0x20,
        0x00, 0x41, 0x00, 0x41, 0x0a, 0xfb, 0x0e, 0x00, 0x20, 0x00, 0x41, 0x01,
        0x41, 0x14, 0xfb, 0x0e, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, 0x1e, 0xfb,
        0x0e, 0x00, 0x20, 0x00, 0x41, 0x03, 0x41, 0x28, 0xfb, 0x0e, 0x00, 0x20,
        0x00, 0x41, 0x01, 0x20, 0x00, 0x41, 0x01, 0x41, 0x02, 0xfb, 0x11, 0x00,
        0x00, 0x20, 0x00, 0x41, 0x01, 0xfb, 0x0b, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 20), runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: array.new_data + array.get → 20 (10.G array-on-JIT A-10a)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module (type (array (mut i32))) (data $d "\0a\00\00\00\14\00\00\00\1e\00\00\00")
    //   (func (export "f") (result i32)
    //     i32.const 0  i32.const 3  array.new_data 0 0   ;; array [10,20,30] from segment 0
    //     i32.const 1  array.get 0))                      ;; elem[1] → 20
    // array.new_data allocs a size-3 array and copies its payload from passive
    // data segment 0, reading nat=4 bytes/elem (i32) little-endian into each
    // 8-byte slot. Emit marshals 5 trampoline args (rt + typeidx + segidx +
    // offset + size) → CALL jitGcArrayNewData (reuses memory.init's
    // data_segments_ptr plumbing) → CMP/TEST 0; B.EQ/JE → bounds_fixups; push
    // ref. 2→1. array.new_data = fb 09 typeidx segidx. Datacount section (0c)
    // declares 1 data segment so the validator accepts segidx 0.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x02, 0x5e, 0x7f, 0x01, 0x60, 0x00, 0x01, 0x7f, // type
        0x03, 0x02, 0x01, 0x01, // func
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f"
        0x0c, 0x01, 0x01, // datacount: 1 data segment
        // code: body 15 bytes (locals 00 + i32.const 0 [41 00] + i32.const 3
        // [41 03] + array.new_data 0 0 [fb 09 00 00] + i32.const 1 [41 01] +
        // array.get 0 [fb 0b 00] + end 0b). body_size=0x0f, sect=0x11.
        0x0a, 0x11, 0x01,
        0x0f, 0x00, 0x41,
        0x00, 0x41, 0x03,
        0xfb, 0x09, 0x00,
        0x00, 0x41, 0x01,
        0xfb, 0x0b, 0x00,
        0x0b,
        // data: 1 passive segment (01), 12 bytes = i32 LE [10,20,30].
        0x0b, 0x0f,
        0x01, 0x01, 0x0c,
        0x0a, 0x00, 0x00,
        0x00, 0x14, 0x00,
        0x00, 0x00, 0x1e,
        0x00, 0x00, 0x00,
    };
    try testing.expectEqual(@as(u32, 20), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: array.new_elem + array.get + call_ref → 42 (10.G array-on-JIT A-10b)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module
    //   (type $sig (func (result i32)))
    //   (type $arr (array (mut (ref null $sig))))
    //   (elem $e (ref null $sig) (ref.func $worker))    ;; passive
    //   (func $worker (type $sig) (i32.const 42))
    //   (func $f (export "f") (result i32)
    //     i32.const 0  i32.const 1  array.new_elem $arr $e  ;; array [funcref $worker]
    //     i32.const 0  array.get $arr                        ;; elem[0] → (ref null $sig)
    //     call_ref $sig))                                    ;; → $worker() = 42
    // array.new_elem allocs a size-1 array and copies the funcref from passive
    // element segment 0 (a *FuncEntity ptr — the SAME encoding ref.func / call_ref
    // use) DIRECT into the 8-byte slot (no LE-unpack, esz=8). Emit marshals 5
    // trampoline args (rt + typeidx + segidx + offset + size) → CALL
    // jitGcArrayNewElem (reuses table.init's elem_segments_ptr plumbing) →
    // CMP/TEST 0; B.EQ/JE → bounds_fixups; push ref. 2→1. array.new_elem = fb 0a
    // typeidx segidx. call_ref through the copied funcref proves the EXACT ref was
    // carried (a copy failure → null slot → call_ref null-trap, not 42).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: (func ()->i32) + (array (mut (ref null 0)))
        0x01, 0x09, 0x02, 0x60, 0x00, 0x01, 0x7f, 0x5e,
        0x63, 0x00, 0x01,
        0x03, 0x03, 0x02, 0x00, 0x00, // func: 2 funcs, both type 0
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x01, // export "f" → func 1
        // elem: 1 passive seg, reftype (ref null 0), [ref.func 0].
        0x09, 0x08, 0x01, 0x05, 0x63, 0x00, 0x01,
        0xd2, 0x00, 0x0b,
        // code: 2 funcs.
        0x0a, 0x18, 0x02,
        0x04, 0x00, 0x41, 0x2a, 0x0b, // worker: i32.const 42; end. body=04.
        // f: body=0x11. i32.const 0; i32.const 1; array.new_elem 1 0;
        // i32.const 0; array.get 1; call_ref 0; end.
        0x11, 0x00, 0x41, 0x00, 0x41,
        0x01, 0xfb, 0x0a, 0x01, 0x00,
        0x41, 0x00, 0xfb, 0x0b, 0x01,
        0x14, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 42), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: array.init_data into existing array then array.get → 20 (10.G array-on-JIT A-11a)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module (type (array (mut i32))) (data $d "\0a\00\00\00\14\00\00\00\1e\00\00\00")
    //   (func (export "f") (result i32) (local (ref null 0))
    //     i32.const 3  array.new_default 0  local.tee 0  ;; 3-elem zero array → local0 + stack
    //     i32.const 0  i32.const 0  i32.const 3  array.init_data 0 0 ;; arr[0..3]=[10,20,30]
    //     local.get 0  i32.const 1  array.get 0))         ;; elem[1] → 20
    // array.init_data pops [ref, dst_off, src_off, len]; emit marshals 6 trampoline
    // args (rt + segidx + those 4) → CALL jitGcArrayInitData → CMP/TEST result,0;
    // B.EQ/JE → bounds_fixups (trap on null/OOB). 4→0 (no push). typeidx is NOT
    // passed (6-arg SysV limit) — the trampoline reads it back from the array's
    // ObjectHeader to derive the element's natural width. array.init_data = fb 12
    // typeidx dataidx. The ref is kept across the consuming init via a (ref null 0)
    // local + tee. Datacount section (0c) declares 1 data segment.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x02, 0x5e, 0x7f, 0x01, 0x60, 0x00, 0x01, 0x7f, // type
        0x03, 0x02, 0x01, 0x01, // func
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f"
        0x0c, 0x01, 0x01, // datacount: 1 data segment
        // code: body 29 bytes (0x1d); sect 0x1f. locals 01 01 63 00 +
        // i32.const 3 [41 03] + array.new_default 0 [fb 07 00] + local.tee 0 [22 00]
        // + i32.const 0 [41 00] + i32.const 0 [41 00] + i32.const 3 [41 03] +
        // array.init_data 0 0 [fb 12 00 00] + local.get 0 [20 00] + i32.const 1
        // [41 01] + array.get 0 [fb 0b 00] + end 0b.
        0x0a, 0x1f, 0x01,
        0x1d, 0x01, 0x01,
        0x63, 0x00, 0x41,
        0x03, 0xfb, 0x07,
        0x00, 0x22, 0x00,
        0x41, 0x00, 0x41,
        0x00, 0x41, 0x03,
        0xfb, 0x12, 0x00,
        0x00, 0x20, 0x00,
        0x41, 0x01, 0xfb,
        0x0b, 0x00, 0x0b,
        // data: 1 passive segment (01), 12 bytes = i32 LE [10,20,30].
        0x0b, 0x0f, 0x01,
        0x01, 0x0c, 0x0a,
        0x00, 0x00, 0x00,
        0x14, 0x00, 0x00,
        0x00, 0x1e, 0x00,
        0x00, 0x00,
    };
    try testing.expectEqual(@as(u32, 20), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: array.init_elem into existing array + array.get + call_ref → 42 (10.G array-on-JIT A-11b)" {
    // Both arches (arm64 + x86_64 SysV emit landed together).
    // (module
    //   (type $sig (func (result i32)))
    //   (type $arr (array (mut (ref null $sig))))
    //   (elem $e (ref null $sig) (ref.func $worker))    ;; passive
    //   (func $worker (type $sig) (i32.const 42))
    //   (func $f (export "f") (result i32) (local (ref null $arr))
    //     i32.const 1  array.new_default $arr  local.tee 0  ;; size-1 null array → local0 + stack
    //     i32.const 0  i32.const 0  i32.const 1  array.init_elem $arr $e ;; arr[0]=funcref $worker
    //     local.get 0  i32.const 0  array.get $arr          ;; elem[0] → (ref null $sig)
    //     call_ref $sig))                                   ;; → $worker() = 42
    // array.init_elem pops [ref, dst_off, src_off, len]; emit marshals 6 trampoline
    // args (rt + segidx + those 4) → CALL jitGcArrayInitElem (direct ref copy, esz=8
    // uniform per ADR-0116 §3a; no typeidx needed) → CMP/TEST 0; B.EQ/JE →
    // bounds_fixups. 4→0. array.init_elem = fb 13 typeidx elemidx. call_ref through
    // the copied funcref proves the EXACT ref was carried (copy failure → null slot
    // → call_ref null-trap, not 42).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: (func ()->i32) + (array (mut (ref null 0)))
        0x01, 0x09, 0x02, 0x60, 0x00, 0x01, 0x7f, 0x5e,
        0x63, 0x00, 0x01,
        0x03, 0x03, 0x02, 0x00, 0x00, // func: 2 funcs, both type 0
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x01, // export "f" → func 1
        // elem: 1 passive seg, reftype (ref null 0), [ref.func 0].
        0x09, 0x08, 0x01, 0x05, 0x63, 0x00, 0x01,
        0xd2, 0x00, 0x0b,
        // code: 2 funcs. payload 0x26 = count(1) + worker(5) + f(1+31).
        0x0a, 0x26, 0x02,
        0x04, 0x00, 0x41, 0x2a, 0x0b, // worker: i32.const 42; end. body=04.
        // f: body 31 bytes (0x1f). locals 01 01 63 01 + i32.const 1 [41 01] +
        // array.new_default 1 [fb 07 01] + local.tee 0 [22 00] + i32.const 0 [41 00]
        // + i32.const 0 [41 00] + i32.const 1 [41 01] + array.init_elem 1 0
        // [fb 13 01 00] + local.get 0 [20 00] + i32.const 0 [41 00] + array.get 1
        // [fb 0b 01] + call_ref 0 [14 00] + end 0b.
        0x1f, 0x01, 0x01, 0x63, 0x01,
        0x41, 0x01, 0xfb, 0x07, 0x01,
        0x22, 0x00, 0x41, 0x00, 0x41,
        0x00, 0x41, 0x01, 0xfb, 0x13,
        0x01, 0x00, 0x20, 0x00, 0x41,
        0x00, 0xfb, 0x0b, 0x01, 0x14,
        0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 42), runI32Export(testing.allocator, &bytes, "f"));
}

test "JitInstance.invoke: externref-param setup fn runs + stores host ref → chk ref.is_null 0 (D-226)" {
    // (module (table $t 1 externref)
    //   (func (export "setup") (param externref) (table.set $t (i32.const 0) (local.get 0)))
    //   (func (export "chk") (result i32) (ref.is_null (table.get $t (i32.const 0)))))
    // Mirrors the corpus `(invoke "init" (ref.extern 0))` setup shape. Before
    // D-226 the externref-param invoke rejected (UnsupportedEntrySignature) →
    // tables stayed empty. Now a `.ref` param threads the full u64 host-ref
    // (0x7000…, untruncated via the i64 carrier) into the JIT entry → stored →
    // chk reads a non-null ref → ref.is_null 0.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x09, 0x02, 0x60, 0x01, 0x6f, 0x00, 0x60, 0x00, 0x01, 0x7f, // type: (externref)->() + ()->i32
        0x03, 0x03, 0x02, 0x00, 0x01, // func: f0:t0, f1:t1
        0x04, 0x04, 0x01, 0x6f, 0x00, 0x01, // table: 1 × externref, min 1
        0x07, 0x0f, 0x02, 0x05, 0x73, 0x65, 0x74, 0x75, 0x70, 0x00, 0x00, 0x03, 0x63, 0x68, 0x6b, 0x00, 0x01, // export setup,chk
        // code: f0 setup [i32.const 0; local.get 0; table.set 0; end]; f1 chk [i32.const 0; table.get 0; ref.is_null; end]
        0x0a, 0x12, 0x02, 0x08, 0x00, 0x41, 0x00, 0x20, 0x00, 0x26, 0x00, 0x0b, 0x07, 0x00, 0x41, 0x00, 0x25,
        0x00, 0xd1, 0x0b,
    };
    var inst = try JitInstance.init(testing.allocator, &bytes);
    defer inst.deinit(testing.allocator);
    _ = try inst.invoke(testing.allocator, "setup", &.{0x7000_0000_0000_0000}); // host externref
    try testing.expectEqual(@as(?u64, 0), try inst.invoke(testing.allocator, "chk", &.{}));
}

test "runI32Export: any.convert_extern beside a sibling table.set preserves it → table-loaded ref.test i31 → 1" {
    // (module (table $t 4 anyref) (func (export "f") (result i32)
    //   i32.const 0  i32.const 5 ref.i31         table.set $t   ;; $t[0] = i31(5)
    //   i32.const 1  ref.null extern any.convert_extern table.set $t ;; $t[1] = convert
    //   i32.const 0  table.get $t  ref.test i31))                ;; read $t[0] → expect 1
    // The transparent 0→0 convert in the SAME function as a sibling table.set does
    // NOT desync regalloc — $t[0] survives intact (GREEN). Mirrors the corpus setup
    // fn shape (converts at $ta[6,7] beside direct stores). Proves convert's model
    // is sound; the corpus +59 was the setup INVOKE not running (externref arg the
    // JIT runner can't pack), not regalloc corruption.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> i32
        0x03, 0x02, 0x01, 0x00, // func
        0x04, 0x04, 0x01, 0x6e, 0x00, 0x04, // table: anyref, min 4
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f"
        // code: body 25 bytes (0x19); sect 0x1b.
        0x0a, 0x1b, 0x01, 0x19, 0x00, 0x41, 0x00,
        0x41, 0x05, 0xfb, 0x1c, 0x26, 0x00, 0x41,
        0x01, 0xd0, 0x6f, 0xfb, 0x1a, 0x26, 0x00,
        0x41, 0x00, 0x25, 0x00, 0xfb, 0x14, 0x6c,
        0x0b,
    };
    try testing.expectEqual(@as(u32, 1), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.test i31 on i31 ref → 1 (10.G ref.test-on-JIT R-1)" {
    // (module (func (export "f") (result i32)
    //   i32.const 5  ref.i31  ref.test i31))   ;; non-null i31 matches i31 → 1
    // ref.test (0xFB 0x14 <heaptype>) emits a 3-arg trampoline marshal
    // (rt + 64-bit ref + ht|nullbit) → CALL jitGcRefTest → push W0/EAX (i32).
    // The abstract i31 path: gcRefMatchesNonNullCore sees isI31Ref → match.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> i32
        0x03, 0x02, 0x01, 0x00, // func f0:type0
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f"
        // code: i32.const 5; ref.i31; ref.test i31 (fb 14 6c); end.
        0x0a, 0x0b, 0x01, 0x09, 0x00, 0x41, 0x05,
        0xfb, 0x1c, 0xfb, 0x14, 0x6c, 0x0b,
    };
    try testing.expectEqual(@as(u32, 1), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.test struct on an i31 ref → 0 (HA probe — cross/negative combo)" {
    // (module (func (export "f") (result i32)
    //   i32.const 5  ref.i31  ref.test struct))  ;; an i31 is NOT a struct → 0
    // CROSS/NEGATIVE combo the comprehensive gc/ref_test.wast exercises but the
    // existing positive tests don't. If JIT returns 1 here, gcAbstractMatch is
    // too-lax (HA: the convert-corpus +59 is ref.test RTT-logic, not convert).
    // ref.i31 = fb 1c; ref.test struct = fb 14 6b.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> i32
        0x03, 0x02, 0x01, 0x00, // func f0:type0
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f"
        // code: i32.const 5; ref.i31; ref.test struct (fb 14 6b); end.
        0x0a, 0x0b, 0x01, 0x09, 0x00, 0x41, 0x05,
        0xfb, 0x1c, 0xfb, 0x14, 0x6b, 0x0b,
    };
    try testing.expectEqual(@as(u32, 0), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.test i31 on a struct ref → 0 (HA probe — cross/negative combo)" {
    // (module (type (struct (field (mut i32))))
    //   (func (export "f") (result i32)
    //     struct.new_default 0  ref.test i31))  ;; a struct is NOT an i31 → 0
    // struct.new_default = fb 01 00; ref.test i31 = fb 14 6c.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x09, 0x02, 0x5f, 0x01, 0x7f, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: struct + func
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f"
        // code: struct.new_default 0 (fb 01 00); ref.test i31 (fb 14 6c); end.
        0x0a, 0x0a, 0x01, 0x08, 0x00, 0xfb, 0x01,
        0x00, 0xfb, 0x14, 0x6c, 0x0b,
    };
    try testing.expectEqual(@as(u32, 0), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.test i31 on a table-loaded i31 ref → 1 (table-path probe, positive)" {
    // (module (table $t 2 anyref) (func (export "f") (result i32)
    //   i32.const 0  i32.const 5 ref.i31  table.set $t   ;; $t[0] = i31(5)
    //   i32.const 0  table.get $t  ref.test i31))         ;; → 1
    // Probe whether a ref READ BACK from a table mis-classifies (the corpus
    // gc/ref_test reads $ta via table.get; the passing matrix tests use direct
    // refs). table.set=0x26, table.get=0x25, anyref elemtype=0x6e.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> i32
        0x03, 0x02, 0x01, 0x00, // func
        0x04, 0x04, 0x01, 0x6e, 0x00, 0x02, // table: 1 × anyref, min 2
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f"
        // code: body 17 bytes (0x11); sect 0x13.
        0x0a, 0x13, 0x01, 0x11, 0x00, 0x41, 0x00,
        0x41, 0x05, 0xfb, 0x1c, 0x26, 0x00, 0x41,
        0x00, 0x25, 0x00, 0xfb, 0x14, 0x6c, 0x0b,
    };
    try testing.expectEqual(@as(u32, 1), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.test struct on a table-loaded i31 ref → 0 (table-path probe, negative)" {
    // Same as above but ref.test struct (fb 14 6b) → an i31 read from the table
    // is NOT a struct → 0. If JIT returns 1, the table.get-reftype/ref.test path
    // is the convert-corpus +59 culprit (independent of any.convert_extern).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x04, 0x04, 0x01, 0x6e, 0x00,
        0x02, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
        0x0a, 0x13, 0x01, 0x11, 0x00, 0x41, 0x00, 0x41,
        0x05, 0xfb, 0x1c, 0x26, 0x00, 0x41, 0x00, 0x25,
        0x00, 0xfb, 0x14, 0x6b, 0x0b,
    };
    try testing.expectEqual(@as(u32, 0), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.test eq on an i31 ref → 1 (abstract matrix — i31 <: eq)" {
    // i32.const 5; ref.i31; ref.test eq (fb 14 6d) → an i31 IS an eqref → 1.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00, 0x0a, 0x0b, 0x01, 0x09, 0x00, 0x41,
        0x05, 0xfb, 0x1c, 0xfb, 0x14, 0x6d, 0x0b,
    };
    try testing.expectEqual(@as(u32, 1), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.test eq on a struct ref → 1 (abstract matrix — struct <: eq)" {
    // struct.new_default 0; ref.test eq (fb 14 6d) → a struct IS an eqref → 1.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x09, 0x02, 0x5f, 0x01, 0x7f, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07,
        0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a, 0x0a,
        0x01, 0x08, 0x00, 0xfb, 0x01, 0x00, 0xfb, 0x14,
        0x6d, 0x0b,
    };
    try testing.expectEqual(@as(u32, 1), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.test array on an i31 ref → 0 (abstract matrix — i31 ⊄ array)" {
    // i32.const 5; ref.i31; ref.test array (fb 14 6a) → i31 is NOT an array → 0.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00, 0x0a, 0x0b, 0x01, 0x09, 0x00, 0x41,
        0x05, 0xfb, 0x1c, 0xfb, 0x14, 0x6a, 0x0b,
    };
    try testing.expectEqual(@as(u32, 0), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.test array on a struct ref → 0 (abstract matrix — struct ⊄ array)" {
    // struct.new_default 0; ref.test array (fb 14 6a) → a struct is NOT an array → 0.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x09, 0x02, 0x5f, 0x01, 0x7f, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07,
        0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a, 0x0a,
        0x01, 0x08, 0x00, 0xfb, 0x01, 0x00, 0xfb, 0x14,
        0x6a, 0x0b,
    };
    try testing.expectEqual(@as(u32, 0), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.test i31 on null → 0 (10.G ref.test-on-JIT R-1)" {
    // (module (func (export "f") (result i32)
    //   ref.null i31  ref.test i31))   ;; null → ref.test returns 0
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00,
        // code: ref.null i31 (d0 6c); ref.test i31 (fb 14 6c); end.
        0x0a, 0x09, 0x01, 0x07, 0x00, 0xd0,
        0x6c, 0xfb, 0x14, 0x6c, 0x0b,
    };
    try testing.expectEqual(@as(u32, 0), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.test_null i31 on null → 1 (10.G ref.test-on-JIT R-1)" {
    // (module (func (export "f") (result i32)
    //   ref.null i31  ref.test_null i31))   ;; null matches the _null variant → 1
    // ref.test_null (0xFB 0x15) marshals ht|nullbit=0x100 → trampoline returns
    // the null-bit (1) on a null ref.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00,
        // code: ref.null i31 (d0 6c); ref.test_null i31 (fb 15 6c); end.
        0x0a, 0x09, 0x01, 0x07, 0x00, 0xd0,
        0x6c, 0xfb, 0x15, 0x6c, 0x0b,
    };
    try testing.expectEqual(@as(u32, 1), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.test struct on a struct ref → 1 (10.G ref.test-on-JIT R-1)" {
    // (module (type (struct (field (mut i32))))
    //   (func (export "f") (result i32)
    //     struct.new_default 0  ref.test struct))   ;; a struct matches `struct` → 1
    // Exercises the HEAP obj-kind read branch of gcRefMatchesNonNullCore
    // (readObjKindHeap → .struct_ → gcAbstractMatch struct → 1), distinct
    // from the i31/null paths above. struct.new_default = fb 01 0; ref.test
    // struct = fb 14 6b (0x6b = struct abstract heaptype).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x09, 0x02, 0x5f, 0x01, 0x7f, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: struct + func
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f"
        // code: struct.new_default 0 (fb 01 00); ref.test struct (fb 14 6b); end.
        0x0a, 0x0a, 0x01, 0x08, 0x00, 0xfb, 0x01,
        0x00, 0xfb, 0x14, 0x6b, 0x0b,
    };
    try testing.expectEqual(@as(u32, 1), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.cast i31 round-trips the ref → i31.get_s 5 (10.G ref.cast-on-JIT R-2)" {
    // (module (func (export "f") (result i32)
    //   i32.const 5  ref.i31  ref.cast i31  i31.get_s))   ;; cast returns the ref → 5
    // ref.cast (0xFB 0x16 <ht>) marshals (rt + 64-bit ref + ht) → CALL
    // jitGcRefCast → CMP/TEST 0; B.EQ/JE → bounds_fixups (trap on null /
    // mismatch); else capture the 64-bit ref. i31.get_s then extracts 5,
    // proving the cast returned the EXACT (matching) ref unchanged.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00,
        // code: i32.const 5; ref.i31; ref.cast i31 (fb 16 6c); i31.get_s (fb 1d); end.
        0x0a, 0x0d, 0x01, 0x0b, 0x00, 0x41,
        0x05, 0xfb, 0x1c, 0xfb, 0x16, 0x6c, 0xfb, 0x1d,
        0x0b,
    };
    try testing.expectEqual(@as(u32, 5), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.cast i31 on null traps (10.G ref.cast-on-JIT R-2)" {
    // (module (func (export "f") (result i32)  ref.null i31  ref.cast i31))
    // ref.cast (non-null target) of a null ref traps (Wasm 3.0 GC §4.4.5):
    // the trampoline returns 0 → bounds_fixups trap stub.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00,
        // code: ref.null i31; ref.cast i31; drop; i32.const 0; end. The
        // drop + const make the body type-check (result i32) even though
        // ref.cast traps at runtime before reaching them.
        0x0a, 0x0c, 0x01, 0x0a, 0x00, 0xd0,
        0x6c, 0xfb, 0x16, 0x6c, 0x1a, 0x41, 0x00, 0x0b,
    };
    try testing.expectError(entry.Error.Trap, runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.cast struct on an i31 ref traps (10.G ref.cast-on-JIT R-2)" {
    // (module (func (export "f") (result i32)  i32.const 5  ref.i31  ref.cast struct))
    // An i31 is not a struct → ref.cast struct traps (exercises the
    // non-null type-mismatch trap path, not just the null path).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00,
        // code: i32.const 5; ref.i31; ref.cast struct; drop; i32.const 0; end.
        0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x41,
        0x05, 0xfb, 0x1c, 0xfb, 0x16, 0x6b, 0x1a, 0x41,
        0x00, 0x0b,
    };
    try testing.expectError(entry.Error.Trap, runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.cast_null i31 on i31 ref → i31.get_s 5 (10.G ref.cast_null-on-JIT R-3)" {
    // (module (func (export "f") (result i32)
    //   i32.const 5  ref.i31  ref.cast_null i31  i31.get_s))   ;; match → ref → 5
    // ref.cast_null (0xFB 0x17 <ht>): null PASSES (no trap), non-null traps on
    // mismatch. Emit reuses jitGcRefTest with the _null bit (0x100): result is
    // the operand UNCHANGED (stored before the CALL); CALL jitGcRefTest →
    // CMP W0,#0; B.EQ/JE → trap iff NOT-ok (null OR match → 1 = ok). i31.get_s
    // extracts 5 (the cast returned the matching ref unchanged).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00,
        // code: i32.const 5; ref.i31; ref.cast_null i31 (fb 17 6c); i31.get_s (fb 1d); end.
        0x0a, 0x0d, 0x01, 0x0b, 0x00, 0x41,
        0x05, 0xfb, 0x1c, 0xfb, 0x17, 0x6c, 0xfb, 0x1d,
        0x0b,
    };
    try testing.expectEqual(@as(u32, 5), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.cast_null i31 on null passes → ref.is_null 1 (10.G ref.cast_null-on-JIT R-3)" {
    // (module (func (export "f") (result i32)
    //   ref.null i31  ref.cast_null i31  ref.is_null))   ;; null PASSES → 1
    // Proves ref.cast_null does NOT trap on null (unlike ref.cast): the result
    // is the (null) operand unchanged → ref.is_null → 1.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00,
        // code: ref.null i31 (d0 6c); ref.cast_null i31 (fb 17 6c); ref.is_null (d1); end.
        0x0a, 0x0a, 0x01, 0x08, 0x00, 0xd0,
        0x6c, 0xfb, 0x17, 0x6c, 0xd1, 0x0b,
    };
    try testing.expectEqual(@as(u32, 1), runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: ref.cast_null struct on an i31 ref traps (10.G ref.cast_null-on-JIT R-3)" {
    // (module (func (export "f") (result i32)
    //   i32.const 5  ref.i31  ref.cast_null struct  drop  i32.const 0))
    // A non-null i31 is not a struct → ref.cast_null traps (only NULL passes;
    // a non-null type-mismatch still traps). drop+const keep the body typed.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00,
        // code: i32.const 5; ref.i31; ref.cast_null struct (fb 17 6b); drop; i32.const 0; end.
        0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x41,
        0x05, 0xfb, 0x1c, 0xfb, 0x17, 0x6b, 0x1a, 0x41,
        0x00, 0x0b,
    };
    try testing.expectError(entry.Error.Trap, runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: 2nd ref.cast_null on a re-read NULLABLE local still traps (D-233 multi-cast desync)" {
    // (module (func (export "f") (result i32) (local anyref)   ;; nullable operand
    //   (local.set 0 (ref.i31 (i32.const 5)))
    //   (drop (ref.cast_null any    (local.get 0)))   ;; cast1: i31<:any → OK
    //   (drop (ref.cast_null struct (local.get 0)))   ;; cast2: i31≢struct → MUST trap
    //   (i32.const 0)))
    // Mirrors the spec ref_cast_null corpus: a NULLABLE operand (so the emit's
    // CBZ-null-skip is live) re-read for each cast. D-233 = the 2nd cast receives
    // operand 0 → CBZ skips → no trap. A non-null fresh-operand sequence does NOT
    // repro (separate passing test). Expect Trap; a return = the bug reproduced.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00,
        // code section: count=1, body size=0x18, locals: 1 group {count 1, anyref 0x6e}
        0x0a, 0x1a, 0x01, 0x18, 0x01, 0x01,
        0x6e,
        // i32.const 5; ref.i31; local.set 0
        0x41, 0x05, 0xfb, 0x1c, 0x21, 0x00,
        // local.get 0; ref.cast_null any (fb 17 6e); drop
        0x20,
        0x00, 0xfb, 0x17, 0x6e, 0x1a,
        // local.get 0; ref.cast_null struct (fb 17 6b); drop
        0x20, 0x00, 0xfb,
        0x17, 0x6b, 0x1a,
        // i32.const 0; end
        0x41, 0x00, 0x0b,
    };
    try testing.expectError(entry.Error.Trap, runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: mem64 OOB i32.load traps on JIT (D-234)" {
    // (module (memory i64 1) (func (export "f") (result i32)
    //   (i32.load (i64.const 0x10000))))   ;; addr 0x10000 = just past a 1-page
    //   (64KiB) mem64 → must trap "out of bounds memory access".
    // D-234: the JIT runs this and RETURNS instead of trapping (exposed once
    // jit-mode assert_trap routed through cur_jit, D-233). Expect Trap.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type ()->i32
        0x03, 0x02, 0x01, 0x00, // func: 1 func, type 0
        0x05, 0x03, 0x01, 0x04, 0x01, // memory: (memory i64 1) — flags 0x04 = i64, min 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        // code: i64.const 0x10000 (42 80 80 04); i32.load (28 02 00); end (0b)
        0x0a, 0x0b, 0x01, 0x09, 0x00, 0x42, 0x80,
        0x80, 0x04, 0x28, 0x02, 0x00, 0x0b,
    };
    try testing.expectError(entry.Error.Trap, runI32Export(testing.allocator, &bytes, "f"));
}

test "runScalar1Export: mem64 OOB i32.load via i64 PARAM traps on JIT (D-234)" {
    // (module (memory i64 1) (func (export "f") (param $a i64) (result i32)
    //   (i32.load (local.get $a))))  — invoked with $a = 0x10000 (OOB) → must trap.
    // Mirrors the corpus memory_trap64 i32.load (param i64). The const-address
    // sibling traps fine; this isolates whether the i64 PARAM path mishandles
    // the OOB address (D-234). Expect Trap.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7e, 0x01, 0x7f, // type (i64)->i32
        0x03, 0x02, 0x01, 0x00, // func
        0x05, 0x03, 0x01, 0x04, 0x01, // memory i64 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f"
        // code: local.get 0; i32.load (28 02 00); end
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00,
        0x28, 0x02, 0x00, 0x0b,
    };
    try testing.expectError(entry.Error.Trap, runner.runScalar1Export(testing.allocator, &bytes, "f", 0x10000));
}

// ── ADR-0128 §1 / D-220: gc ref.i31 global init-expr (JIT compile gate) ──

test "JitInstance: ref.i31 global init compiles + get returns the i31 value" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module (global $g i31ref (i32.const 1234) (ref.i31))
    //   (func (export "g") (result i32) global.get 0 i31.get_s))
    // The JIT compile gate's validateGlobalInitExpr was single-opcode and
    // rejected the `i32.const; ref.i31; end` sequence (InvalidGlobalInitExpr).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type ()->(i32)
        0x03, 0x02, 0x01, 0x00,
        // global sec: 1 global, type i31ref (0x6c), immutable, init i32.const 1234; ref.i31; end
        0x06, 0x09, 0x01,
        0x6c, 0x00, 0x41, 0xd2, 0x09, 0xfb, 0x1c,
        0x0b,
        0x07, 0x05, 0x01, 0x01, 0x67, 0x00, 0x00, // export "g"
        // code: global.get 0; i31.get_s (0xfb 0x1d); end
        0x0a, 0x08, 0x01, 0x06, 0x00, 0x23, 0x00,
        0xfb, 0x1d, 0x0b,
    };
    var inst = try JitInstance.init(testing.allocator, &bytes);
    defer inst.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 1234), try inst.invoke(testing.allocator, "g", &.{}));
}

// ── ADR-0128 §1 / D-223: gc const-expr global (struct.new / array.new) ──

test "runI32Export: array.new_default const-expr global + array.len → 3 (D-223)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module
    //   (type $arr (array (mut i32)))                       ;; type 0
    //   (global $g (ref 0) (i32.const 3) (array.new_default 0)) ;; gc const-expr
    //   (func (export "len") (result i32) global.get 0 array.len))
    // The JIT compile gate (validateGlobalInitExpr) rejected the multi-op
    // const-expr (i32.const; array.new_default; end → InvalidGlobalInitExpr),
    // so the whole module was compile-skipped. Now the validator walks the
    // const-expr + setup allocates the array on the gc heap at global init.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type: [0]=array{i32 mut} (5e 7f 01), [1]=func ()->(i32) (60 00 01 7f)
        0x01, 0x08, 0x02, 0x5e, 0x7f, 0x01, 0x60, 0x00,
        0x01, 0x7f,
        0x03, 0x02, 0x01, 0x01, // func: type idx 1
        // global: 1 entry, type (ref 0) [64 00], immutable [00],
        // init i32.const 3 [41 03]; array.new_default 0 [fb 07 00]; end [0b]
        0x06, 0x0a, 0x01, 0x64,
        0x00, 0x00, 0x41, 0x03,
        0xfb, 0x07, 0x00, 0x0b,
        0x07, 0x07, 0x01, 0x03, 0x6c, 0x65, 0x6e, 0x00, 0x00, // export "len" func 0
        // code: body 6 bytes (locals 00 + global.get 0 [23 00] + array.len [fb 0f] + end 0b)
        0x0a, 0x08, 0x01, 0x06, 0x00, 0x23, 0x00, 0xfb, 0x0f,
        0x0b,
    };
    try testing.expectEqual(@as(u32, 3), runI32Export(testing.allocator, &bytes, "len"));
}

// ── ADR-0128 §1 / D-220: ref.as_non_null liveness stackEffect (JIT compile gate) ──

test "JitInstance: ref.as_non_null module JIT-compiles (liveness stackEffect)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module (func (export "f") (param funcref) (result i32)
    //   local.get 0 ref.as_non_null drop i32.const 7))
    // ref.as_non_null lowers (0xD4) + emits + is registered, but the
    // liveness pass lacked a stackEffect entry → module-compile-reject
    // (UnsupportedOp[stackEffect-missing]). Compile-only check (funcref
    // param isn't scalar-dispatchable, so we don't invoke).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x70, 0x01, 0x7f, // type (funcref)->(i32)
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f"
        0x0a, 0x0a, 0x01, 0x08, 0x00, 0x20, 0x00,
        0xd4, 0x1a, 0x41, 0x07, 0x0b,
    };
    var inst = try JitInstance.init(testing.allocator, &bytes); // compiles ⇒ green
    inst.deinit(testing.allocator);
}

test "runI32Export: ref.as_non_null result outliving an i32 local → 1040 (#245)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module (type $pt (struct (field i32) (field i32)))
    //   (func (export "f") (result i32) (local $p (ref $pt)) (local $k i32)
    //     (local.set $k (i32.const 1000))
    //     (local.set $p (ref.as_non_null (struct.new $pt (i32.const 40) (i32.const 2))))
    //     (i32.add (local.get $k) (struct.get $pt 0 (local.get $p)))))
    // The compile-only gate above proves ref.as_non_null EMITS; it cannot
    // prove it computes. Both emitters push the source vreg straight back
    // (identity, no result vreg), so a liveness model that pops-and-pushes
    // closes the operand's range and frees its register while the narrowed
    // ref is still live. Pre-fix the JIT returned 42: `local.get $k` handed
    // back the `i32.const 2` that fed struct.new. Keeping the result alive
    // across one more value is the whole trigger — a single consumer is
    // always correct, which is why the spec corpus misses it (#245).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0b, 0x02, 0x5f, 0x02, 0x7f, 0x00, 0x7f, // type: $pt struct(i32,i32)
        0x00, 0x60, 0x00, 0x01, 0x7f, // type: ()->(i32)
        0x03, 0x02, 0x01, 0x01, // func: type 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" func 0
        0x0a, 0x21, 0x01, 0x1f, 0x02, 0x01, 0x64,
        0x00, 0x01, 0x7f, 0x41, 0xe8, 0x07, 0x21,
        0x01, 0x41, 0x28, 0x41, 0x02, 0xfb, 0x00,
        0x00, 0xd4, 0x21, 0x00, 0x20, 0x01, 0x20,
        0x00, 0xfb, 0x02, 0x00, 0x00, 0x6a, 0x0b,
    };
    try testing.expectEqual(@as(u32, 1040), try runI32Export(testing.allocator, &bytes, "f"));
}

// ── D-212: cross-function ref-param struct.get result-class scaffolding ──
// A struct ref passed as a call ARGUMENT, then read in the callee via
// struct.get. The i32 control PASSES (ref-arg passing + GPR result are
// correct). The f32 case is the D-212 bug: struct.get's f32 result is
// GPR-class and never reaches the FP return register across the call/return
// boundary → reads stale V0/XMM0 (0.0 in a clean process). Un-skip the f32
// test when D-212 lands (struct.get/array.get f32/f64 result → FP-class).

test "runI32Export: cross-func ref-param struct.get i32 field → 42 (D-212 control)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (type $s (struct (field i32))) ; $inner (ref $s)->i32 = struct.get 0 0 ;
    // export "f" ()->i32 = i32.const 42; struct.new 0; call $inner
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0f, 0x03, 0x5f, 0x01, 0x7f, 0x00, 0x60,
        0x01, 0x64, 0x00, 0x01, 0x7f, 0x60, 0x00, 0x01,
        0x7f, 0x03, 0x03, 0x02, 0x01, 0x02, 0x07, 0x05,
        0x01, 0x01, 0x66, 0x00, 0x01, 0x0a, 0x14, 0x02,
        0x08, 0x00, 0x20, 0x00, 0xfb, 0x02, 0x00, 0x00,
        0x0b, 0x09, 0x00, 0x41, 0x2a, 0xfb, 0x00, 0x00,
        0x10, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 42), runI32Export(testing.allocator, &bytes, "f"));
}

test "runF32Export: cross-func ref-param struct.get f32 field → 2.5 (D-212 RED — un-skip on fix)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // D-212 (fixed): f32 struct.get result is now FP-class → reaches V0/XMM0.
    // (type $s (struct (field f32))) ; $inner (ref $s)->f32 = struct.get 0 0 ;
    // export "f" ()->f32 = f32.const 2.5; struct.new 0; call $inner
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0f, 0x03, 0x5f, 0x01, 0x7d, 0x00, 0x60,
        0x01, 0x64, 0x00, 0x01, 0x7d, 0x60, 0x00, 0x01,
        0x7d, 0x03, 0x03, 0x02, 0x01, 0x02, 0x07, 0x05,
        0x01, 0x01, 0x66, 0x00, 0x01, 0x0a, 0x17, 0x02,
        0x08, 0x00, 0x20, 0x00, 0xfb, 0x02, 0x00, 0x00,
        0x0b, 0x0c, 0x00, 0x43, 0x00, 0x00, 0x20, 0x40,
        0xfb, 0x00, 0x00, 0x10, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(f32, 2.5), try runF32Export(testing.allocator, &bytes, "f"));
}

// ── D-218: table-of-i31ref active elem segment compiles + reads (3 guards) ──

test "JitInstance: table-of-i31ref active elem + table.get + i31.get_u → 999/888/777 (D-218)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module (table $t 3 i31ref)
    //   (elem (table $t) (i32.const 0) i31ref (item (ref.i31 (i32.const 999)))
    //                                          (item (ref.i31 (i32.const 888)))
    //                                          (item (ref.i31 (i32.const 777))))
    //   (func (export "get") (param i32) (result i32)
    //     (i31.get_u (table.get $t (local.get 0)))))
    // The active i31ref elem items are i31-ENCODED const-exprs; three sites
    // (compile.zig funcidx range-check, setup active-elem-init, setup
    // elem_refs_arena) used to treat them as funcidxs → InvalidFuncIndex /
    // UnsupportedEntrySignature. D-218 guards all three for i31/eq/any.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type (i32)->(i32)
        0x03, 0x02, 0x01, 0x00, // func 0 : type 0
        0x04, 0x04, 0x01, 0x6c, 0x00, 0x03, // table: 1 table, i31ref, min 3
        0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, // export "get" func 0
        // elem: flag 6 (active+tableidx+reftype+exprs), table 0, offset (i32.const 0),
        // reftype i31ref (6c), 3 items each (ref.i31 (i32.const N)).
        0x09, 0x1a, 0x01, 0x06, 0x00, 0x41, 0x00, 0x0b, 0x6c,
        0x03,
        0x41, 0xe7, 0x07, 0xfb, 0x1c, 0x0b, // 999
        0x41, 0xf8, 0x06, 0xfb, 0x1c, 0x0b, // 888
        0x41, 0x89, 0x06, 0xfb, 0x1c, 0x0b, // 777
        // code: local.get 0; table.get 0; i31.get_u; end
        0x0a, 0x0a, 0x01, 0x08, 0x00, 0x20,
        0x00, 0x25, 0x00, 0xfb, 0x1e, 0x0b,
    };
    var inst = try JitInstance.init(testing.allocator, &bytes);
    defer inst.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 999), try inst.invoke(testing.allocator, "get", &.{0}));
    try testing.expectEqual(@as(?u64, 888), try inst.invoke(testing.allocator, "get", &.{1}));
    try testing.expectEqual(@as(?u64, 777), try inst.invoke(testing.allocator, "get", &.{2}));
}

// ── D-224: JIT table.grow on a (non-funcref) i31ref table ──

test "JitInstance: table.grow i31 table — grow→old size, get grown slot (D-224)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module (table $t 1 5 i31ref)
    //   (func (export "grow") (param i32 i32) (result i32)  ;; p0=delta p1=val
    //     local.get 1  ref.i31  local.get 0  table.grow $t)
    //   (func (export "size") (result i32) table.size $t)
    //   (func (export "get") (param i32) (result i32) local.get 0 table.get $t i31.get_u))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x10, 0x03, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f,
        0x01, 0x7f, 0x03, 0x04, 0x03, 0x00, 0x01, 0x02,
        0x04, 0x05, 0x01, 0x6c, 0x01, 0x01, 0x05, // table i31ref min1 max5
        0x07, 0x15, 0x03, 0x04, 0x67, 0x72, 0x6f,
        0x77, 0x00, 0x00, 0x04, 0x73, 0x69, 0x7a,
        0x65, 0x00, 0x01, 0x03, 0x67, 0x65, 0x74,
        0x00, 0x02, 0x0a, 0x1c, 0x03,
        0x0b, 0x00, 0x20, 0x01, 0xfb, 0x1c, 0x20, 0x00, 0xfc, 0x0f, 0x00, 0x0b, // grow
        0x05, 0x00, 0xfc, 0x10, 0x00, 0x0b, // size
        0x08, 0x00, 0x20, 0x00, 0x25, 0x00, 0xfb, 0x1e, 0x0b, // get
    };
    var inst = try JitInstance.init(testing.allocator, &bytes);
    defer inst.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 1), try inst.invoke(testing.allocator, "grow", &.{ 2, 99 })); // old size
    try testing.expectEqual(@as(?u64, 3), try inst.invoke(testing.allocator, "size", &.{})); // 1+2
    try testing.expectEqual(@as(?u64, 99), try inst.invoke(testing.allocator, "get", &.{1})); // grown slot
}

// ── D-225 (partial): ref.func in a funcref global init resolves non-null ──

test "runI32Export: global funcref ref.func f + ref.is_null is 0 (D-225)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module (func $f) (global funcref (ref.func $f))
    //   (func (export "f") (result i32) global.get 0 ref.is_null))
    // The ref.func global init was left null (setup passed empty func_entities
    // to evalGlobalInitGc); now func_entities is built before the global loop.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01, 0x7f, // type[0]=()->() type[1]=()->i32
        0x03, 0x03, 0x02, 0x00, 0x01, // func0=type0 ($f), func1=type1 (export)
        // global: 1, funcref (0x70), immutable (00), init ref.func 0 (d2 00) end (0b)
        0x06, 0x06, 0x01, 0x70, 0x00,
        0xd2, 0x00, 0x0b,
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x01, // export "f" -> func1
        0x0a, 0x0a, 0x02, 0x02, 0x00, 0x0b, 0x05, 0x00, 0x23, 0x00, 0xd1, 0x0b, // func0 empty; func1 global.get 0 ref.is_null
    };
    try testing.expectEqual(@as(u32, 0), runI32Export(testing.allocator, &bytes, "f"));
}

// ── D-225 (partial): table-with-explicit-init-expr filled at setup ──

test "JitInstance: table (ref i31) explicit init-expr ref.i31 7 + table.get → 7 (D-225)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module (table $t 2 (ref i31) (ref.i31 (i32.const 7)))
    //   (func (export "get") (param i32) (result i32) local.get 0 table.get $t i31.get_u))
    // setup previously ignored the table init-expr → slots null → i31.get traps.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type (i32)->(i32)
        0x03, 0x02, 0x01, 0x00, // func 0
        // table: explicit-init form 0x40 0x00, reftype (ref i31)=64 6c, limits min2 (00 02),
        // init-expr i32.const 7; ref.i31; end (41 07 fb 1c 0b)
        0x04, 0x0c, 0x01, 0x40,
        0x00, 0x64, 0x6c, 0x00,
        0x02, 0x41, 0x07, 0xfb,
        0x1c, 0x0b,
        0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, // export "get" func0
        0x0a, 0x0a, 0x01, 0x08, 0x00, 0x20, 0x00, 0x25, 0x00, 0xfb, 0x1e, 0x0b, // local.get0 table.get0 i31.get_u
    };
    var inst = JitInstance.init(testing.allocator, &bytes) catch |e| {
        std.debug.print("\n[d225t] init ERR={s}\n", .{@errorName(e)});
        return error.TestUnexpectedResult;
    };
    defer inst.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 7), try inst.invoke(testing.allocator, "get", &.{0}));
    try testing.expectEqual(@as(?u64, 7), try inst.invoke(testing.allocator, "get", &.{1}));
}

// ── D-225: imported-global resolution into setup-time const-expr evals ──

test "JitInstance.initLinked: table init-expr ref.i31(global.get imported) → 42 (D-225)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module (global $g (import "env" "g") i32)
    //   (table $t 2 (ref i31) (ref.i31 (global.get $g)))
    //   (func (export "get") (param i32) (result i32) local.get 0 table.get $t i31.get_u))
    // initLinked passes the imported global value (42) → the table init-expr's
    // global.get resolves it (D-225 imported-global piece; runner wiring = next).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type (i32)->(i32)
        0x02, 0x0a, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x67, 0x03, 0x7f, 0x00, // import env.g : global i32
        0x03, 0x02, 0x01, 0x00, // func 0
        // table (ref i31) min2 init-expr: global.get 0; ref.i31; end
        0x04, 0x0c, 0x01, 0x40,
        0x00, 0x64, 0x6c, 0x00,
        0x02, 0x23, 0x00, 0xfb,
        0x1c, 0x0b,
        0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, // export "get" func0
        0x0a, 0x0a, 0x01, 0x08, 0x00, 0x20, 0x00, 0x25, 0x00,
        0xfb, 0x1e, 0x0b,
    };
    var inst = JitInstance.initLinked(testing.allocator, &bytes, &.{42}, &.{}, &.{}, &.{}) catch |e| {
        std.debug.print("\n[d225g] init ERR={s}\n", .{@errorName(e)});
        return error.TestUnexpectedResult;
    };
    defer inst.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 42), try inst.invoke(testing.allocator, "get", &.{0}));
    try testing.expectEqual(@as(?u64, 42), try inst.invoke(testing.allocator, "get", &.{1}));
}

// struct.get_s / struct.get_u — Wasm 3.0 GC §3.3.13.7 packed (i8/i16)
// field sign/zero-extension (D-225 skip-reduction; mirrors the proven
// array.get_s/u emit). Single-result variants (the gc/struct.10 corpus
// asserts return 2 values = multi-value-eligibility-skipped, so verify
// the runtime extension here). Struct {mut i8}; store i32 -2 (low byte
// 0xFE); get_s → sign-extend → -2; get_u → zero-extend → 254.
test "JitInstance: struct.get_s / struct.get_u packed i8 sign/zero-extend (D-225)" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type0 = struct {mut i8}; type1 = ()->i32
        0x01, 0x09, 0x02, 0x5f, 0x01, 0x78, 0x01, 0x60,
        0x00, 0x01, 0x7f,
        0x03, 0x03, 0x02, 0x01, 0x01, // 2 funcs, both type1
        // export "gs" func0, "gu" func1
        0x07, 0x0b, 0x02, 0x02, 0x67,
        0x73, 0x00, 0x00, 0x02, 0x67,
        0x75, 0x00, 0x01,
        // code: gs = i32.const -2; struct.new 0; struct.get_s 0 0
        //       gu = i32.const -2; struct.new 0; struct.get_u 0 0
        0x0a, 0x19,
        0x02, 0x0b, 0x00, 0x41, 0x7e,
        0xfb, 0x00, 0x00, 0xfb, 0x03,
        0x00, 0x00, 0x0b, 0x0b, 0x00,
        0x41, 0x7e, 0xfb, 0x00, 0x00,
        0xfb, 0x04, 0x00, 0x00, 0x0b,
    };
    var inst = JitInstance.init(testing.allocator, &bytes) catch |e| {
        std.debug.print("\n[d225-structget] init ERR={s}\n", .{@errorName(e)});
        return error.TestUnexpectedResult;
    };
    defer inst.deinit(testing.allocator);
    const gs = (try inst.invoke(testing.allocator, "gs", &.{})).?;
    const gu = (try inst.invoke(testing.allocator, "gu", &.{})).?;
    try testing.expectEqual(@as(i32, -2), @as(i32, @bitCast(@as(u32, @truncate(gs)))));
    try testing.expectEqual(@as(i32, 254), @as(i32, @bitCast(@as(u32, @truncate(gu)))));
}

test "runI32Export: any.convert_extern + extern.convert_any null round-trip → ref.is_null 1 (10.G JIT)" {
    // Both arches. (module (func (export "f") (result i32)
    //   ref.null extern  any.convert_extern  extern.convert_any  ref.is_null))
    // The converts are pure identity (externref/anyref share the Value.ref
    // slot; the any↔extern distinction is validator-only) → emit is a no-op,
    // liveness is operand-stack-transparent (0→0, like local.tee). This test
    // proves the value flows THROUGH both converts unchanged (null preserved →
    // is_null 1). Before the emit/liveness wiring the module rejected with
    // `liveness: UnsupportedOp[stackEffect-missing] op=any.convert_extern`.
    // ref.null extern = d0 6f; any.convert_extern = fb 1a; extern.convert_any =
    // fb 1b; ref.is_null = d1.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type ()->i32
        0x03, 0x02, 0x01, 0x00, // func type 0
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f"
        // code: body 9 bytes (0x09); sect 0x0b. locals 00 + ref.null extern
        // [d0 6f] + any.convert_extern [fb 1a] + extern.convert_any [fb 1b] +
        // ref.is_null [d1] + end [0b].
        0x0a, 0x0b, 0x01, 0x09, 0x00, 0xd0, 0x6f,
        0xfb, 0x1a, 0xfb, 0x1b, 0xd1, 0x0b,
    };
    try testing.expectEqual(@as(u32, 1), runI32Export(testing.allocator, &bytes, "f"));
}

// ============================================================
// D-235 — JIT call_indirect subtype acceptance (Wasm §3.3.5.5). The inline
// D-111 structural sig CMP is finality/subtype-blind; subtyping modules route
// through the jitCallIndirectResolve trampoline. Two directions: (A) a
// finality-distinct callee must TRAP (over-accept regression), (B) an
// exact/subtype callee must be ACCEPTED + run (over-reject + gti-materialise
// regression). Both exercise the func-only-subtyping path (no GC heap).
// wat2wasm predates gc text; bytes hand-encoded (sub=0x50, sub final=0x4F per
// parse/sections.zig:434).

test "runI32Export: call_indirect $t1 on a $t2(final) funcref TRAPS — D-235 over-accept" {
    // (module
    //   (type $t1 (sub (func)))        ;; idx0 ()->()  open
    //   (type $t2 (sub final (func)))  ;; idx1 ()->()  final — $t2 !<: $t1
    //   (type $t3 (func (result i32))) ;; idx2
    //   (func $f2 (type $t2)) (table funcref (elem $f2))
    //   (func (export "f") (result i32)
    //     (call_indirect (type $t1) (i32.const 0))  ;; $f2:$t2 via $t1 → TRAP
    //     (i32.const 42)))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0f, 0x03, 0x50, 0x00, 0x60, 0x00, 0x00,
        0x4f, 0x00, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01,
        0x7f,
        0x03, 0x03, 0x02, 0x01, 0x02, // func: f2:type1, f:type2
        0x04, 0x04, 0x01, 0x70, 0x00, 0x01, // table funcref min 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x01, // export "f" = func 1
        0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00, // elem active tbl0 off0 [func0]
        // code: f2 empty (02 00 0b); f body9 = locals0 + i32.const 0 (idx) +
        // call_indirect type0 tbl0 + i32.const 42 + end.
        0x0a, 0x0e, 0x02, 0x02, 0x00, 0x0b, 0x09, 0x00, 0x41,
        0x00, 0x11, 0x00, 0x00, 0x41, 0x2a, 0x0b,
    };
    try testing.expectError(entry.Error.Trap, runI32Export(testing.allocator, &bytes, "f"));
}

test "runI32Export: call_indirect $t1 on a $t1 funcref returns 7 — D-235 exact-match accept" {
    // (module
    //   (type $t1 (sub (func (result i32))))  ;; idx0 — subtyping module
    //   (func $f (type $t1) (i32.const 7)) (table funcref (elem $f))
    //   (func (export "f") (result i32)
    //     (call_indirect (type $t1) (i32.const 0))))  ;; exact → accept → 7
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x50, 0x00, 0x60, 0x00, 0x01, 0x7f, // type0 = sub ()->(i32)
        0x03, 0x03, 0x02, 0x00, 0x00, // func: 2 funcs both type0
        0x04, 0x04, 0x01, 0x70, 0x00, 0x01, // table funcref min 1
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x01, // export "f" = func 1
        0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00, // elem active tbl0 off0 [func0]
        // code: f body4 = locals0 + i32.const 7 + end; f-export body7 =
        // locals0 + i32.const 0 (idx) + call_indirect type0 tbl0 + end.
        0x0a, 0x0e, 0x02, 0x04, 0x00, 0x41, 0x07, 0x0b, 0x07,
        0x00, 0x41, 0x00, 0x11, 0x00, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 7), runI32Export(testing.allocator, &bytes, "f"));
}

// ============================================================
// §16.6 GC-on-JIT memory safety (D-258 + D-261; ADR-0160).
// ============================================================

// Shared fixture: (module (type (struct (field (mut i32))))
//   (func (export "f") (result i32) struct.new_default 0  ref.is_null))
// One JIT struct allocation; `f` returns 0 (fresh struct is non-null).
const gc_struct_new_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x09, 0x02, 0x5f, 0x01, 0x7f, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07,
    0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a, 0x08,
    0x01, 0x06, 0x00, 0xfb, 0x01, 0x00, 0xd1, 0x0b,
};

test "D-258: JIT struct.new triggers a GC collection under heap pressure (ADR-0160)" {
    var inst = try JitInstance.init(testing.allocator, &gc_struct_new_wasm);
    defer inst.deinit(testing.allocator);

    // The struct type section materialises the per-instance GC heap.
    const heap: *heap_mod.Heap = @ptrCast(@alignCast(inst.owned.rt.gc_heap.?));
    // Arm collection to fire on the very next allocation: the JIT alloc
    // trampoline must check pressure + collect BEFORE bumping the cursor.
    heap.pressure_bytes = 16;
    heap.next_gc_at = heap.cursor;

    _ = try inst.invoke(testing.allocator, "f", &.{});

    // Before D-258 the JIT trampoline called object_alloc directly →
    // gc_cycles stays 0 (RED). After wiring maybeCollectJit → >0 (GREEN).
    try testing.expect(heap.gc_cycles > 0);
}

// D-261 adversarial fixture (the conservative-rooting correctness proof):
// (module (type (struct (field (mut i32))))
//   (func (export "f") (result i32) (local (ref null 0))
//     i32.const 42  struct.new 0   local.set 0   ;; A.field=42, held in local 0
//     i32.const 0    struct.new 0   drop          ;; B alloc → forces the collect
//     local.get 0    struct.get 0 0))              ;; read A.field across the collect
// A is held ONLY in local 0 across B's collection-triggering alloc. If the
// conservative native-stack scan roots it (ADR-0160), A survives → 42. If A is
// wrongly swept, B reuses A's exact-size slot (field 0) → 0 — a use-after-free
// the value discriminator catches deterministically.
const gc_hold_across_collect_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x09, 0x02, 0x5f, 0x01, 0x7f, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07,
    0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a, 0x1a,
    0x01, 0x18, 0x01, 0x01, 0x63, 0x00, 0x41, 0x2a,
    0xfb, 0x00, 0x00, 0x21, 0x00, 0x41, 0x00, 0xfb,
    0x00, 0x00, 0x1a, 0x20, 0x00, 0xfb, 0x02, 0x00,
    0x00, 0x0b,
};

test "D-261: JIT GcRef held across a collect-forcing alloc survives (ADR-0160)" {
    var inst = try JitInstance.init(testing.allocator, &gc_hold_across_collect_wasm);
    defer inst.deinit(testing.allocator);

    const heap: *heap_mod.Heap = @ptrCast(@alignCast(inst.owned.rt.gc_heap.?));
    // Arm so A's alloc does NOT collect (cursor < next_gc_at) but B's DOES
    // (cursor has grown past next_gc_at after A). A is live in local 0 across
    // B's collection — the spill-at-call model (ADR-0128 §2) must place it on
    // the native stack so scanNativeStackRoots marks it.
    heap.pressure_bytes = 16;
    heap.next_gc_at = heap.cursor + 1;

    const r = try inst.invoke(testing.allocator, "f", &.{});

    try testing.expect(heap.gc_cycles > 0); // the collect actually fired
    // 42 ⇒ A survived (conservative scan rooted the held ref). 0 ⇒ swept +
    // slot-reused = use-after-free (would fail this assertion, voiding ADR-0160).
    try testing.expectEqual(@as(?u64, 42), r);
}

test "JitInstance: struct.new_default through table → ref.test (subtype/canonical) → 1 (D-317)" {
    // D-317 — a GcRef stored to a table then ref.tested returned the wrong
    // answer: struct.new* spilled the u32 ref via a 32-bit store (arm64 STR W),
    // and x86_64 table.set reused r10/r11 for both the descriptor and the spill
    // stages, so a force-spilled table index/value clobbered refs/len. Both
    // corrupt the table-loaded ref. This exercises the exact/subtype/canonical
    // ref.test paths on a table-sourced struct.new_default object.
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x1a, 0x05, 0x50, 0x00, 0x5f, 0x00, 0x50, 0x01, 0x00, 0x5f, 0x01, 0x7f, 0x00, 0x50, 0x01, 0x00, 0x5f, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x03, 0x04, 0x04, 0x04, 0x01, 0x6b, 0x00, 0x03, 0x07, 0x07, 0x01, 0x03, 0x63, 0x68, 0x6b, 0x00, 0x01, 0x0a, 0x35, 0x02, 0x17, 0x00, 0x41, 0x00, 0xfb, 0x01, 0x00, 0x26, 0x00, 0x41, 0x01, 0xfb, 0x01, 0x01, 0x26, 0x00, 0x41, 0x02, 0xfb, 0x01, 0x02, 0x26, 0x00, 0x0b, 0x1b, 0x00, 0x10, 0x00, 0x41, 0x01, 0x25, 0x00, 0xfb, 0x14, 0x00, 0x41, 0x01, 0x25, 0x00, 0xfb, 0x14, 0x01, 0x71, 0x41, 0x01, 0x25, 0x00, 0xfb, 0x14, 0x02, 0x71, 0x0b, 0x00, 0x21, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01, 0x08, 0x01, 0x00, 0x05, 0x73, 0x65, 0x74, 0x75, 0x70, 0x04, 0x0a, 0x03, 0x00, 0x01, 0x61, 0x01, 0x01, 0x62, 0x02, 0x01, 0x63, 0x05, 0x04, 0x01, 0x00, 0x01, 0x74 };
    var inst = try JitInstance.initLinked(testing.allocator, &bytes, &.{}, &.{}, &.{}, &.{});
    defer inst.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 1), try inst.invoke(testing.allocator, "chk", &.{}));
}
