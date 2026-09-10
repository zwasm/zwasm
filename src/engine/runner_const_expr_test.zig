//! JIT const-expression tests: the shared validator judges a constant
//! expression's validity once (Wasm 3.0 §3.3.13.1) and the JIT only
//! evaluates (#397). Split from `runner_test.zig`, which sits at its
//! file-size cap; mirrors the `runner_trap_test.zig` split. Discovered by
//! the unit-test loader via `src/zwasm.zig`'s `test {}` block.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const skip = @import("../test_support/skip.zig");

const runner = @import("runner.zig");
const compileWasm = runner.compileWasm;
const JitInstance = runner.JitInstance;
// ── #397: a const expression reads any immutable global in scope ──
// Wasm 3.0 §3.3.13.1 (extended-const) lets a global init `global.get` an
// immutable global declared before it, imported or defined. The JIT's
// own const-expr check applied the 2.0 rule (imports only); its validity
// is now the shared validator's verdict and `runner_validate.zig` only
// evaluates.

// (module
//   (global $a i32 (i32.const 5))
//   (global $b i32 (global.get $a))
//   (func (export "test") (result i32) global.get $b))
const defined_global_read_bytes = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type ()->(i32)
    0x03, 0x02, 0x01, 0x00, // func 0: type 0
    // global sec: $a i32 immutable (i32.const 5); $b i32 immutable (global.get 0)
    0x06, 0x0b, 0x02, 0x7f,
    0x00, 0x41, 0x05, 0x0b,
    0x7f, 0x00, 0x23, 0x00,
    0x0b,
    0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, // export "test" func 0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x23, 0x01, 0x0b, // code: global.get 1; end
};

test "JitInstance: a global init reads a defined immutable global (#397)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var inst = try JitInstance.init(testing.allocator, &defined_global_read_bytes);
    defer inst.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 5), try inst.invoke(testing.allocator, "test", &.{}));
}

test "compileWasm: a global init that reads itself, a later global, or a mutable global is invalid (§3.3.13.1)" {
    // (module (global i32 (global.get 0)))
    const self_ref = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x06, 0x06, 0x01, 0x7f, 0x00, 0x23, 0x00, 0x0b };
    try testing.expectError(error.InvalidGlobalInitExpr, compileWasm(testing.allocator, &self_ref));
    // (module (global i32 (global.get 1)) (global i32 (i32.const 0)))
    const forward_ref = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x06, 0x0b, 0x02, 0x7f, 0x00, 0x23, 0x01, 0x0b, 0x7f, 0x00, 0x41, 0x00, 0x0b };
    try testing.expectError(error.InvalidGlobalInitExpr, compileWasm(testing.allocator, &forward_ref));
    // (module (global $m (mut i32) (i32.const 1)) (global i32 (global.get $m)))
    const mutable_read = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x06, 0x0b, 0x02, 0x7f, 0x01, 0x41, 0x01, 0x0b, 0x7f, 0x00, 0x23, 0x00, 0x0b };
    try testing.expectError(error.InvalidGlobalInitExpr, compileWasm(testing.allocator, &mutable_read));
}

test "applyDefinedGlobalsInit: a defined-global read evaluates in index order, and a reference read declines" {
    const gpa = testing.allocator;
    {
        var c = try compileWasm(gpa, &defined_global_read_bytes);
        defer c.deinit(gpa);
        const buf = try gpa.alloc(u8, c.globals_offsets.len * 16);
        defer gpa.free(buf);
        @memset(buf, 0);
        try runner.applyDefinedGlobalsInit(gpa, &defined_global_read_bytes, c.globals_offsets, c.globals_valtypes, buf, c.num_global_imports);
        try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, buf[c.globals_offsets[1]..][0..4], .little));
    }
    {
        // (module (func $f) (global $a funcref (ref.func $f)) (global $b funcref (global.get $a)))
        // $a's slot holds the `ref.func` funcidx placeholder until
        // `resolveFuncrefGlobals`, which rewrites only `ref.func` inits —
        // so copying it into $b would carry the placeholder past the
        // resolver. The evaluator declines instead of copying.
        const funcref_chain = [_]u8{
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
            0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type ()->()
            0x03, 0x02, 0x01, 0x00, // func 0: type 0
            0x06, 0x0b, 0x02, 0x70,
            0x00, 0xd2, 0x00, 0x0b,
            0x70, 0x00, 0x23, 0x00,
            0x0b,
            0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code: end
        };
        var c = try compileWasm(gpa, &funcref_chain);
        defer c.deinit(gpa);
        const buf = try gpa.alloc(u8, c.globals_offsets.len * 16);
        defer gpa.free(buf);
        @memset(buf, 0);
        try testing.expectError(error.UnsupportedEntrySignature, runner.applyDefinedGlobalsInit(gpa, &funcref_chain, c.globals_offsets, c.globals_valtypes, buf, c.num_global_imports));
    }
}

test "compileWasm: a table init that reads a defined global is invalid — a table sees the imports only (§3.3.13.1)" {
    // (module (global $g i32 (i32.const 0)) (table 1 funcref (global.get $g)))
    // PR #428 review: `compileWasm` judged global inits and segment offsets
    // but never a table's own init expr, and setup then resolved the read.
    const table_reads_defined = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x04, 0x09, 0x01, 0x40, 0x00, 0x70, 0x00, 0x01, 0x23, 0x00, 0x0b, // table: funcref min 1, init global.get 0
        0x06, 0x06, 0x01, 0x7f, 0x00, 0x41, 0x00, 0x0b, // global $g i32 (i32.const 0)
    };
    try testing.expectError(error.InvalidGlobalInitExpr, compileWasm(testing.allocator, &table_reads_defined));
}

test "JitInstance: an active data offset that reads a defined global is valid, and setup declines it cleanly" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module (memory 1) (global $o i32 (i32.const 8)) (data (global.get $o) "hi")
    //   (func (export "test") (result i32) i32.const 8 i32.load8_u))
    // The offset is a valid constant expression (§3.3.13.1: an offset sees
    // every global), so `compileWasm` accepts it; `setup.zig` evaluates
    // offsets without a globals context and declines — as one error, with
    // no instance and nothing half-initialised (PR #428 review). `.auto`
    // runs it on the interpreter; `--engine jit` fails with this name.
    const data_offset_reads_global = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> (i32)
        0x03, 0x02, 0x01, 0x00, // func 0
        0x05, 0x03, 0x01, 0x00, 0x01, // memory 1
        0x06, 0x06, 0x01, 0x7f, 0x00, 0x41, 0x08, 0x0b, // global $o i32 (i32.const 8)
        0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, // export "test"
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x41, 0x08, 0x2d, 0x00, 0x00, 0x0b, // code: i32.const 8; i32.load8_u
        0x0b, 0x08, 0x01, 0x00, 0x23, 0x00, 0x0b, 0x02, 0x68, 0x69, // data (global.get 0) "hi"
    };
    var c = try compileWasm(testing.allocator, &data_offset_reads_global);
    c.deinit(testing.allocator);
    try testing.expectError(error.UnsupportedEntrySignature, JitInstance.init(testing.allocator, &data_offset_reads_global));
}
