//! End-to-end JIT trap-KIND tests (ADR-0164 workstream A / D-292). Split from
//! `runner_test.zig` (P1 spec-defined sub-language — Wasm trap kinds — + P3
//! independent change cadence: the trap-kind widening kept pushing
//! `runner_test.zig` toward the 2000-line hard cap, mirroring the
//! `runner_gc_test.zig` split). Each test compiles a `_start` that traps a
//! specific way, runs it through the JIT void-export path, and asserts the
//! precise `JitRuntime.trap_kind` code the codegen recorded maps to the
//! interp-parity `TrapKind`. Discovered via `src/zwasm.zig`'s `test {}` block.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const skip = @import("../test_support/skip.zig");

const runner = @import("runner.zig");
const entry = @import("codegen/shared/entry.zig");
const trap_surface = @import("../api/trap_surface.zig");
const trap_registry = @import("../platform/trap_registry.zig");

// `(module (func (export "_start") unreachable))` — the JIT lowers `unreachable`
// to an unconditional branch into a dedicated trap stub recording trap-kind 5.
const unreachable_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x05,
    0x01, 0x03, 0x00, 0x00, 0x0b,
};

test "runVoidExportWasi: a JIT `unreachable` surfaces the precise trap-kind code 5 (ADR-0164 A / D-292)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var trap_code: u32 = 99; // sentinel: must be overwritten by the trap path
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &unreachable_start_wasm, "_start", null, &trap_code));
    // D-292 widening: `unreachable` now records the PRECISE code 5 on BOTH arches
    // (was the arch-divergent generic bucket — arm64 1, x86_64 0). 5 maps to
    // TrapKind.unreachable_ via trap_surface.jitTrapCode, reaching interp-parity.
    try testing.expectEqual(@as(u32, 5), trap_code);
    try testing.expectEqual(trap_surface.TrapKind.unreachable_, trap_surface.jitTrapCode(trap_code).?);
}

// D-468 / ADR-0199 — a host-import call that sets `trap_flag` (here the default
// `hostDispatchTrap` planted for the unresolved `env.h`; proc_exit's mechanism
// is identical) MUST unwind to the function epilogue at the CALL SITE, not fall
// through to the next op. Module: `$inner = call $h ; unreachable` and
// `_start = call $inner ; unreachable`. Correct: the trap surfaces but NEITHER
// `unreachable` runs, so trap_kind != unreachable_(5). Before the fix the guest
// kept executing past the trap-flagging call → the first `unreachable` fired →
// trap_code == 5 (the D-468 go_* JIT-exit-hang root cause: proc_exit set
// trap_flag but execution continued into Go's scheduler). Exercises BOTH the
// post-import-call check ($inner) and the post-body-call check (_start).
const import_trap_then_unreachable_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60,
    0x00, 0x00, 0x02, 0x09, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x68, 0x00,
    0x00, 0x03, 0x03, 0x02, 0x00, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x02, 0x0a, 0x0d, 0x02, 0x05, 0x00, 0x10,
    0x00, 0x00, 0x0b, 0x05, 0x00, 0x10, 0x01, 0x00, 0x0b, 0x00, 0x12, 0x04,
    0x6e, 0x61, 0x6d, 0x65, 0x01, 0x0b, 0x02, 0x00, 0x01, 0x68, 0x01, 0x05,
    0x69, 0x6e, 0x6e, 0x65, 0x72,
};

test "JIT host-import trap_flag unwinds at the call site, not the next op (D-468/ADR-0199)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var trap_code: u32 = 99; // sentinel
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &import_trap_then_unreachable_wasm, "_start", null, &trap_code));
    // The `unreachable` ops must NOT have executed — the trap unwound at the
    // trap-flagging call site, so the kind is the import trap (NOT 5/unreachable_).
    try testing.expect(trap_code != 5);
}

// GC trap-kind precision (correctness sweep): `array.len` on a null array ref must
// surface trap_kind = null_reference (raw 10, jitTrapCode → .null_reference), the
// same kind the interp reports (`mvp.zig` Trap.NullReference). Before the fix the
// JIT routed the null check to the GENERIC `bounds_fixups` (kind 0), diverging from
// interp + spec. `(type $a (array i32)) (func (export "test") (result i32)
//   ref.null $a array.len)`.
const array_len_null_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x5e,
    0x7f, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07, 0x08,
    0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x0a, 0x08, 0x01, 0x06,
    0x00, 0xd0, 0x00, 0xfb, 0x0f, 0x0b, 0x00, 0x0b, 0x04, 0x6e, 0x61, 0x6d,
    0x65, 0x04, 0x04, 0x01, 0x00, 0x01, 0x61,
};

test "JIT array.len on null ref traps null_reference (GC trap-kind precision sweep)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var inst = try runner.JitInstance.init(testing.allocator, &array_len_null_wasm);
    defer inst.deinit(testing.allocator);
    try testing.expectError(entry.Error.Trap, inst.invoke(testing.allocator, "test", &.{}));
    try testing.expectEqual(@as(u32, 10), inst.owned.rt.trap_kind); // null_reference
    try testing.expectEqual(trap_surface.TrapKind.null_reference, trap_surface.jitTrapCode(inst.owned.rt.trap_kind).?);
}

// `array.new_data` whose segment access is out of bounds must surface oob_memory
// (raw 6), matching the interp (Trap.OutOfBoundsLoad, array_ops.zig). Was the
// generic bounds bucket. `(type $a (array i8)) (data $d "ab")
//   (func (export "test") (result i32) i32.const 0 i32.const 100
//     array.new_data $a $d drop i32.const 0)` — size 100 >> the 2-byte segment.
const array_new_data_oob_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x5e,
    0x78, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07, 0x08,
    0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x0c, 0x01, 0x01, 0x0a,
    0x10, 0x01, 0x0e, 0x00, 0x41, 0x00, 0x41, 0xe4, 0x00, 0xfb, 0x09, 0x00,
    0x00, 0x1a, 0x41, 0x00, 0x0b, 0x0b, 0x05, 0x01, 0x01, 0x02, 0x61, 0x62,
    0x00, 0x11, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x04, 0x04, 0x01, 0x00, 0x01,
    0x61, 0x09, 0x04, 0x01, 0x00, 0x01, 0x64,
};

test "JIT array.new_data segment-oob traps oob_memory (GC trap-kind precision sweep)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var inst = try runner.JitInstance.init(testing.allocator, &array_new_data_oob_wasm);
    defer inst.deinit(testing.allocator);
    try testing.expectError(entry.Error.Trap, inst.invoke(testing.allocator, "test", &.{}));
    try testing.expectEqual(@as(u32, 6), inst.owned.rt.trap_kind); // oob_memory
    try testing.expectEqual(trap_surface.TrapKind.oob_memory, trap_surface.jitTrapCode(inst.owned.rt.trap_kind).?);
}

// `array.init_data` on a null destination array must surface null_reference (raw
// 10), matching interp. The trampoline conflates null + oob in one result==0
// check (D-470), so the JIT emits an INLINE null-ref check (→ null_ref_fixups)
// before the call; the residual result==0 (only the segment/array OOB for a
// validated module) routes to oob_memory. `(type $a (array (mut i8)))
// (data $d "ab") (func (export "test") (result i32) ref.null $a
//   i32.const 0 i32.const 0 i32.const 1 array.init_data $a $d i32.const 0)`.
const array_init_data_null_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x5e,
    0x78, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x07, 0x08,
    0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x0c, 0x01, 0x01, 0x0a,
    0x12, 0x01, 0x10, 0x00, 0xd0, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x01,
    0xfb, 0x12, 0x00, 0x00, 0x41, 0x00, 0x0b, 0x0b, 0x05, 0x01, 0x01, 0x02,
    0x61, 0x62, 0x00, 0x11, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x04, 0x04, 0x01,
    0x00, 0x01, 0x61, 0x09, 0x04, 0x01, 0x00, 0x01, 0x64,
};

test "JIT array.init_data on null array traps null_reference (GC trap-kind precision sweep)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var inst = try runner.JitInstance.init(testing.allocator, &array_init_data_null_wasm);
    defer inst.deinit(testing.allocator);
    try testing.expectError(entry.Error.Trap, inst.invoke(testing.allocator, "test", &.{}));
    try testing.expectEqual(@as(u32, 10), inst.owned.rt.trap_kind); // null_reference
    try testing.expectEqual(trap_surface.TrapKind.null_reference, trap_surface.jitTrapCode(inst.owned.rt.trap_kind).?);
}

// `(module (func (export "_start") i32.const 1 i32.const 0 i32.div_s drop))` —
// the div-by-zero check traps before the IDIV/SDIV (ADR-0164 A2 / D-292: code 7).
const divzero_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x0a,
    0x01, 0x08, 0x00, 0x41, 0x01, 0x41, 0x00, 0x6d,
    0x1a, 0x0b,
};

// `(module (func (export "_start") i32.const INT_MIN i32.const -1 i32.div_s drop))` —
// signed-overflow check traps on INT_MIN / -1 (ADR-0164 A2 / D-292: code 8).
const div_overflow_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x0e,
    0x01, 0x0c, 0x00, 0x41, 0x80, 0x80, 0x80, 0x80,
    0x78, 0x41, 0x7f, 0x6d, 0x1a, 0x0b,
};

test "runVoidExportWasi: JIT div-by-zero → precise code 7; div_s overflow → code 8 (ADR-0164 A2 / D-292)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var dz: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &divzero_start_wasm, "_start", null, &dz));
    try testing.expectEqual(@as(u32, 7), dz);
    try testing.expectEqual(trap_surface.TrapKind.div_by_zero, trap_surface.jitTrapCode(dz).?);
    var ov: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &div_overflow_start_wasm, "_start", null, &ov));
    try testing.expectEqual(@as(u32, 8), ov);
    try testing.expectEqual(trap_surface.TrapKind.int_overflow, trap_surface.jitTrapCode(ov).?);
}

// `(module (memory 1) (func (export "_start") i32.const 65536 i32.load drop))` —
// the load at ea=65536 (1-page memory = indices 0..65535) is out of bounds
// (ADR-0164 A3 / D-292: oob_memory code 6).
const oob_load_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07,
    0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72,
    0x74, 0x00, 0x00, 0x0a, 0x0c, 0x01, 0x0a, 0x00,
    0x41, 0x80, 0x80, 0x04, 0x28, 0x02, 0x00, 0x1a,
    0x0b,
};

test "runVoidExportWasi: JIT out-of-bounds load → precise oob_memory code 6 (ADR-0164 A3 / D-292)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var oob: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &oob_load_start_wasm, "_start", null, &oob));
    try testing.expectEqual(@as(u32, 6), oob);
    try testing.expectEqual(trap_surface.TrapKind.oob_memory, trap_surface.jitTrapCode(oob).?);
}

// `(module (table 1 funcref) (func (export "_start") i32.const 5 table.get 0 drop))` —
// table.get index 5 on a 1-element table is out of bounds (D-293: oob_table, code 2,
// now unified across arm64+x86_64 — x86_64 previously reported the generic bucket).
const table_get_oob_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00, 0x01,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61,
    0x72, 0x74, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07,
    0x00, 0x41, 0x05, 0x25, 0x00, 0x1a, 0x0b,
};

test "runVoidExportWasi: JIT table.get out-of-bounds → precise oob_table code 2 (D-293)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var oob: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &table_get_oob_wasm, "_start", null, &oob));
    try testing.expectEqual(@as(u32, 2), oob);
    try testing.expectEqual(trap_surface.TrapKind.oob_table, trap_surface.jitTrapCode(oob).?);
}

// `(module (table 3 3 funcref) (func (export "_start")
//    i32.const 1 i32.const 2 i32.const 3   ;; N padding values, kept live
//    i32.const 2 table.get 0 br 0))` — index 2 is IN BOUNDS on a 3-slot
// table, so neither arm may trap. `br 0` targets the function block, so the
// padding needs no consumer and the body stays `() -> ()`; the two modules
// differ ONLY in how many values are live across the `table.get`.
//
// D-590: x86_64 `emitTableGet` loaded the table descriptor into R10/R11
// BEFORE re-loading a spilled index, and R10 is `abi.spill_stage_gprs[0]` —
// so a spilled index overwrote the length it was about to be compared
// against, `CMP RDX, R10` became `CMP idx, idx`, and `JAE` fired whether or
// not the index was in bounds. The count IS the experiment: `abi.allocatable_gprs` is 4 wide on
// SysV x86_64, so at three padding values the index still gets a register
// (this arm passed even while the bug was live) and at four it spills. Win64
// runs a 6-wide pool, so its threshold sits two higher — the arms below would
// not exercise the spill there even without the phase-end skip. Re-derive
// with `debug_jit_auto` recipe 20 if regalloc moves the boundary: should BOTH
// arms stop spilling the index, this test keeps passing while covering
// nothing.
const table_get_live3_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x04, 0x05, 0x01, 0x70, 0x01, 0x03,
    0x03, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74,
    0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x10, 0x01,
    0x0e, 0x00, 0x41, 0x01, 0x41, 0x02, 0x41, 0x03,
    0x41, 0x02, 0x25, 0x00, 0x0c, 0x00, 0x0b,
};

// Same module plus a fourth padding value (`i32.const 4`), which pushes the
// index vreg past the 4-slot GPR pool and onto the spill path.
const table_get_live4_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x04, 0x05, 0x01, 0x70, 0x01, 0x03,
    0x03, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74,
    0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x12, 0x01,
    0x10, 0x00, 0x41, 0x01, 0x41, 0x02, 0x41, 0x03,
    0x41, 0x04, 0x41, 0x02, 0x25, 0x00, 0x0c, 0x00,
    0x0b,
};

test "runVoidExportWasi: an in-bounds JIT table.get does not trap when the index spills (D-590)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // Control arm — index in a register. Passed before the fix too; it is
    // here so a failure localizes to the spill path rather than to
    // `table.get` at large.
    _ = try runner.runVoidExportWasi(testing.allocator, &table_get_live3_wasm, "_start", null, null);
    // Regression arm — index spilled. Reported `oob_table` (code 2) for an
    // in-bounds index before the descriptor loads moved after the reload.
    _ = try runner.runVoidExportWasi(testing.allocator, &table_get_live4_wasm, "_start", null, null);
}

// `(module (type $t0 (func)) (type $t1 (func (param i32))) (table 1 funcref)
//  (func $f (type $t0)) (elem (i32.const 0) $f)
//  (func (export "_start") i32.const 0 i32.const 0 call_indirect (type $t1)))` —
// table[0] holds $f : ()->() but call_indirect expects $t1 : (i32)->(), a
// SIGNATURE mismatch (index 0 is IN bounds). D-293 slice-2: indirect_call_mismatch
// code 3, now UNIFIED across arm64+x86_64 (x86_64 previously reported the generic
// bucket — its inline sig `JNE` appended to `bounds_fixups`). Bytes generated via
// `wasm-tools parse` (name section stripped to the 66-byte module proper).
const cind_sig_mismatch_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x01,
    0x7f, 0x00, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04,
    0x04, 0x01, 0x70, 0x00, 0x01, 0x07, 0x0a, 0x01,
    0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00,
    0x01, 0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b,
    0x01, 0x00, 0x0a, 0x0e, 0x02, 0x02, 0x00, 0x0b,
    0x09, 0x00, 0x41, 0x00, 0x41, 0x00, 0x11, 0x01,
    0x00, 0x0b,
};

test "runVoidExportWasi: JIT call_indirect signature mismatch → precise indirect_call_mismatch code 3 (D-293 slice-2)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var sig: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &cind_sig_mismatch_wasm, "_start", null, &sig));
    try testing.expectEqual(@as(u32, 3), sig);
    try testing.expectEqual(trap_surface.TrapKind.indirect_call_mismatch, trap_surface.jitTrapCode(sig).?);
}

// `(module (type $t (func)) (table 1 funcref)
//  (func (export "_start") i32.const 0 call_indirect (type $t)))` —
// table[0] is NULL (no elem segment) and index 0 is IN bounds. The null slot's
// stored typeidx is the maxInt(u32) no-func sentinel, so the pre-sig
// `CMP/CMN typeidx, sentinel` fires FIRST → uninitialized_elem code 13, NOT the
// sig-mismatch code 3 it was mislabelled as before D-294. Bytes from `wat2wasm`.
const cind_null_elem_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60,
    0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00, 0x01,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00,
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x41, 0x00, 0x11, 0x00, 0x00, 0x0b,
};

test "runVoidExportWasi: JIT call_indirect on a null table element → precise uninitialized_elem code 13 (D-294)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var ue: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &cind_null_elem_wasm, "_start", null, &ue));
    // D-294: was 3 (indirect_call_mismatch) — the null check now PRECEDES the sig
    // CMP so the JIT matches the interp + all reference engines (uninitialized element).
    try testing.expectEqual(@as(u32, 13), ue);
    try testing.expectEqual(trap_surface.TrapKind.uninitialized_elem, trap_surface.jitTrapCode(ue).?);
}

// SUBTYPING variant of the above (D-294 RESIDUAL). The rec group `(type $base
// (sub (func))) (type $t (sub $base (func)))` makes the module USE subtyping, so
// call_indirect routes through the `jitCallIndirectResolve` trampoline (not the
// inline finality-blind CMP). table[0] is NULL → the trampoline returns the
// NULL_ELEM_SENTINEL → uninitialized_elem (code 13), where it previously
// collapsed to indirect_call_mismatch (code 3). Bytes from `wasm-tools parse`.
const cind_subtype_null_elem_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x11, 0x02, 0x4e,
    0x02, 0x50, 0x00, 0x60, 0x00, 0x00, 0x50, 0x01, 0x00, 0x60, 0x00, 0x00,
    0x60, 0x00, 0x00, 0x03, 0x02, 0x01, 0x02, 0x04, 0x04, 0x01, 0x70, 0x00,
    0x01, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00,
    0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x41, 0x00, 0x11, 0x01, 0x00, 0x0b,
};

test "runVoidExportWasi: JIT call_indirect on null elem under SUBTYPING → uninitialized_elem code 13 (D-294 residual)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var ue: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &cind_subtype_null_elem_wasm, "_start", null, &ue));
    // Was 3 (indirect_call_mismatch) — the subtyping resolve trampoline collapsed
    // null/OOB/sig into funcptr=0; now returns a distinct NULL sentinel → code 13.
    try testing.expectEqual(@as(u32, 13), ue);
    try testing.expectEqual(trap_surface.TrapKind.uninitialized_elem, trap_surface.jitTrapCode(ue).?);
}

// D-586 — an IMPORTED function reached through `call_indirect`. The table's
// funcptr mirror takes `func_entities[fidx].funcptr`, which for an import is
// the bridge thunk `dispatch[fidx]`, so the call lands in the host. `setup.zig`
// used to leave that mirror null on purpose — the JIT emits no host-dispatch
// trampoline of its own, and refusing the call beat running arbitrary host
// code — but the inline path EXECUTED the null and the PROCESS DIED (SIGSEGV,
// zwasm's own handler reporting "this is a bug in zwasm (not a wasm trap)").
// Distinct from the two D-294 cases above: there the slot is null and its
// typeidx is the maxInt(u32) sentinel; here the slot is fully initialised —
// typeidx valid, sig matching — so bounds, sentinel and sig all passed before
// the call, which is why no existing guard caught it.
// The fixture calls `proc_exit(42)` — 42 is outside `jitTrapCode`'s range, so
// reading it back distinguishes a real host call from any trap. Bytes from
// `wasm-tools parse`, one operand byte edited.
const cind_import_in_table_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60,
    0x01, 0x7f, 0x00, 0x60, 0x00, 0x00, 0x02, 0x24, 0x01, 0x16, 0x77, 0x61,
    0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f,
    0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6f,
    0x63, 0x5f, 0x65, 0x78, 0x69, 0x74, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01,
    0x04, 0x04, 0x01, 0x70, 0x00, 0x01, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x01, 0x09, 0x07, 0x01, 0x00, 0x41, 0x00,
    0x0b, 0x01, 0x00, 0x0a, 0x0b, 0x01, 0x09, 0x00, 0x41, 0x2a, 0x41, 0x00,
    0x11, 0x00, 0x00, 0x0b, 0x00, 0x14, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01,
    0x07, 0x01, 0x00, 0x04, 0x65, 0x78, 0x69, 0x74, 0x04, 0x04, 0x01, 0x00,
    0x01, 0x74,
};

test "runVoidExportWasi: JIT call_indirect calls an IMPORTED table element (D-586)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    const wasi_host_mod = @import("../wasi/host.zig");
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    // `proc_exit` surfaces its exit code through the binding's Trap path
    // (`wasi/jit_dispatch.zig`), so the error is expected and is not the signal.
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &cind_import_in_table_wasm, "_start", &h, null));

    // THE load-bearing assertion: the host actually ran `proc_exit` with the
    // operand the fixture pushed. A null `wasi_host` would trap with
    // `binding_error` well before this, which is what the mirror-less build did
    // — and before D-586 it was a dead process rather than either.
    try testing.expectEqual(@as(?u32, 42), h.exit_code);
}

// D-586, found in adversarial review: the SAME import-in-table shape reached
// through `return_call_indirect` instead of `call_indirect`. The tail-call emit
// path has its own four funcptr loads, none of which null-tested, so this
// variant still killed the process after the call_indirect sites were fixed —
// which is why it is pinned separately rather than assumed to follow.
// Byte-identical to `cind_import_in_table_wasm` except the opcode: 0x13
// (return_call_indirect) where the other has 0x11.
const tail_cind_import_in_table_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60,
    0x01, 0x7f, 0x00, 0x60, 0x00, 0x00, 0x02, 0x24, 0x01, 0x16, 0x77, 0x61,
    0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f,
    0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6f,
    0x63, 0x5f, 0x65, 0x78, 0x69, 0x74, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01,
    0x04, 0x04, 0x01, 0x70, 0x00, 0x01, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x01, 0x09, 0x07, 0x01, 0x00, 0x41, 0x00,
    0x0b, 0x01, 0x00, 0x0a, 0x0b, 0x01, 0x09, 0x00, 0x41, 0x2a, 0x41, 0x00,
    0x13, 0x00, 0x00, 0x0b, 0x00, 0x14, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01,
    0x07, 0x01, 0x00, 0x04, 0x65, 0x78, 0x69, 0x74, 0x04, 0x04, 0x01, 0x00,
    0x01, 0x74,
};

// D-586 — the cohort question the two fixtures above cannot ask: they tail-call
// from `_start`, so no same-module frame is left to return into. Here `_start`
// CALLs a middle function, which `return_call_indirect`s to the imported
// `clock_time_get` with its own frame torn down; the import returns past it,
// straight into `_start`'s still-live frame. `_start` then does a
// `call_indirect` to a LOCAL table entry, which reads the pinned typeidx_base /
// funcptr_base — the exact registers a thunk that failed to restore the cohort
// would have clobbered (an earlier 56-byte arm64 thunk saved only X19, leaving
// X24 stale; it surfaced as an `imports.1.wasm` sig mismatch, kind 3). A
// corrupted cohort therefore fails here as a trap rather than the expected 42.
// This is why `emitIndirectReturnCall` may BR to an import while
// `emitCrossModuleReturnCall` routes the direct form to call-and-return.
// From `wasm-tools parse` (index form, so no name section).
const grand_caller_tail_cind_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x13, 0x04, 0x60,
    0x03, 0x7f, 0x7e, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01,
    0x7f, 0x00, 0x60, 0x00, 0x00, 0x02, 0x4c, 0x02, 0x16, 0x77, 0x61, 0x73,
    0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70,
    0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x0e, 0x63, 0x6c, 0x6f, 0x63,
    0x6b, 0x5f, 0x74, 0x69, 0x6d, 0x65, 0x5f, 0x67, 0x65, 0x74, 0x00, 0x00,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68,
    0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x09,
    0x70, 0x72, 0x6f, 0x63, 0x5f, 0x65, 0x78, 0x69, 0x74, 0x00, 0x02, 0x03,
    0x04, 0x03, 0x00, 0x01, 0x03, 0x04, 0x04, 0x01, 0x70, 0x00, 0x02, 0x05,
    0x03, 0x01, 0x00, 0x01, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61,
    0x72, 0x74, 0x00, 0x04, 0x09, 0x08, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x02,
    0x00, 0x03, 0x0a, 0x27, 0x03, 0x0d, 0x00, 0x20, 0x00, 0x20, 0x01, 0x20,
    0x02, 0x41, 0x00, 0x13, 0x00, 0x00, 0x0b, 0x04, 0x00, 0x41, 0x2a, 0x0b,
    0x12, 0x00, 0x41, 0x00, 0x42, 0x00, 0x41, 0x00, 0x10, 0x02, 0x1a, 0x41,
    0x01, 0x11, 0x01, 0x00, 0x10, 0x01, 0x0b,
};

test "runVoidExportWasi: JIT return_call_indirect to an import keeps a grand-caller's cohort (D-586)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    const wasi_host_mod = @import("../wasi/host.zig");
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &grand_caller_tail_cind_wasm, "_start", &h, null));

    // 42 comes from the LOCAL table entry `_start` reached AFTER the tail-called
    // import returned through it. Reading it back proves the grand-caller's
    // pinned bases survived the frame-consuming jump into the bridge thunk.
    try testing.expectEqual(@as(?u32, 42), h.exit_code);
}

test "runVoidExportWasi: JIT return_call_indirect calls an IMPORTED table element (D-586)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    const wasi_host_mod = @import("../wasi/host.zig");
    var h = try wasi_host_mod.Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &tail_cind_import_in_table_wasm, "_start", &h, null));
    // Same reasoning as the call_indirect test above.
    try testing.expectEqual(@as(?u32, 42), h.exit_code);
}

// `(module (func (export "_start") f32.const nan i32.trunc_f32_s drop))` — the Wasm
// 1.0 trapping `i32.trunc_f32_s` traps on NaN (the FP self-compare sets PF/V). D-293
// slice-3: invalid_conversion code 9, UNIFIED across arm64+x86_64 (previously the
// generic bucket — x86_64 `JP`/arm64 `B.VS` appended to bounds_fixups). `0x7fc00000` = qNaN.
const trunc_nan_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x0b,
    0x01, 0x09, 0x00, 0x43, 0x00, 0x00, 0xc0, 0x7f,
    0xa8, 0x1a, 0x0b,
};

// `(module (func (export "_start") f32.const 1e30 i32.trunc_f32_s drop))` — 1e30 ≥ 2^31,
// so the trapping `i32.trunc_f32_s` range-check traps. D-293 slice-3: trunc out-of-range
// reuses int_overflow code 8 (the div_s overflow channel), UNIFIED across both arches.
const trunc_overflow_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x0b,
    0x01, 0x09, 0x00, 0x43, 0xca, 0xf2, 0x49, 0x71,
    0xa8, 0x1a, 0x0b,
};

test "runVoidExportWasi: JIT trapping-trunc NaN → precise invalid_conversion code 9; out-of-range → int_overflow code 8 (D-293 slice-3)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var nan_code: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &trunc_nan_wasm, "_start", null, &nan_code));
    try testing.expectEqual(@as(u32, 9), nan_code);
    try testing.expectEqual(trap_surface.TrapKind.invalid_conversion, trap_surface.jitTrapCode(nan_code).?);
    var ovf_code: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &trunc_overflow_wasm, "_start", null, &ovf_code));
    try testing.expectEqual(@as(u32, 8), ovf_code);
    try testing.expectEqual(trap_surface.TrapKind.int_overflow, trap_surface.jitTrapCode(ovf_code).?);
}

// `(module (type $t (func)) (func (export "_start") ref.null $t call_ref $t))` —
// call_ref on a null funcref traps (Wasm 3.0 typed func-refs §4.4.8.13).
// D-293 slice-4b: null_reference code 10. NOTE this was a REGRESSION on arm64 —
// the call_ref null check appended to `cind_bounds_fixups`, mis-reporting
// oob_table (code 2); slice-4b re-routes both arches to the null_ref channel.
const callref_null_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x08,
    0x01, 0x06, 0x00, 0xd0, 0x00, 0x14, 0x00, 0x0b,
};

// `(module (func (export "_start") ref.null func ref.as_non_null drop))` —
// ref.as_non_null on null traps (Wasm 3.0 §3.3.8.5). D-293 slice-4b: code 10
// (was the generic bucket — TEST/CMP self + JE/B.EQ → bounds_fixups).
const asnonnull_null_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x08,
    0x01, 0x06, 0x00, 0xd0, 0x70, 0xd4, 0x1a, 0x0b,
};

test "runVoidExportWasi: JIT call_ref null + ref.as_non_null null → precise null_reference code 10 (D-293 slice-4b)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var cr: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &callref_null_wasm, "_start", null, &cr));
    try testing.expectEqual(@as(u32, 10), cr); // was 2 (oob_table) on arm64 pre-slice-4b
    try testing.expectEqual(trap_surface.TrapKind.null_reference, trap_surface.jitTrapCode(cr).?);
    var an: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &asnonnull_null_wasm, "_start", null, &an));
    try testing.expectEqual(@as(u32, 10), an);
    try testing.expectEqual(trap_surface.TrapKind.null_reference, trap_surface.jitTrapCode(an).?);
}

// `(module (type $s (struct (field i32))) (func (export "_start")
//  ref.null $s struct.get $s 0 drop))` — struct.get on a null structref is
// null_reference (Wasm 3.0 GC §4.4.5). D-293 slice-4c: code 10 (was generic).
const structget_null_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x5f, 0x01, 0x7f, 0x00, 0x60,
    0x00, 0x00, 0x03, 0x02, 0x01, 0x01, 0x07, 0x0a,
    0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74,
    0x00, 0x00, 0x0a, 0x0b, 0x01, 0x09, 0x00, 0xd0,
    0x00, 0xfb, 0x02, 0x00, 0x00, 0x1a, 0x0b,
};

// `(module (type $a (array i32)) (func (export "_start")
//  i32.const 0 array.new_default $a i32.const 0 array.get $a drop))` — array.get
// index 0 on a length-0 array is OOB. D-293 slice-4c: array index OOB raises the
// interp's OutOfBoundsLoad → reuses oob_memory code 6 (no new TrapKind).
const arrayget_oob_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x02, 0x5e, 0x7f, 0x00, 0x60, 0x00,
    0x00, 0x03, 0x02, 0x01, 0x01, 0x07, 0x0a, 0x01,
    0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00,
    0x00, 0x0a, 0x0f, 0x01, 0x0d, 0x00, 0x41, 0x00,
    0xfb, 0x07, 0x00, 0x41, 0x00, 0xfb, 0x0b, 0x00,
    0x1a, 0x0b,
};

test "runVoidExportWasi: JIT struct.get null → null_reference code 10; array.get OOB → oob_memory code 6 (D-293 slice-4c)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var sg: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &structget_null_wasm, "_start", null, &sg));
    try testing.expectEqual(@as(u32, 10), sg);
    try testing.expectEqual(trap_surface.TrapKind.null_reference, trap_surface.jitTrapCode(sg).?);
    var ag: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &arrayget_oob_wasm, "_start", null, &ag));
    try testing.expectEqual(@as(u32, 6), ag);
    try testing.expectEqual(trap_surface.TrapKind.oob_memory, trap_surface.jitTrapCode(ag).?);
}

// D-293 array_oob: the packed-array `array.get_s` SIBLING was still on the generic
// bounds_fixups while array.get/set were precise (slice-4c). Now rerouted to match:
// null → null_reference (code 10), index OOB → oob_memory (code 6). Bytes from
// `wasm-tools parse` of `(type $a (array i8))`. Mirrors the array.get test above.
const arraygets_null_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x02, 0x5e,
    0x78, 0x00, 0x60, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01, 0x07, 0x0a, 0x01,
    0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x0c, 0x01,
    0x0a, 0x00, 0xd0, 0x00, 0x41, 0x00, 0xfb, 0x0c, 0x00, 0x1a, 0x0b,
};
const arraygets_oob_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x02, 0x5e,
    0x78, 0x00, 0x60, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01, 0x07, 0x0a, 0x01,
    0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x0f, 0x01,
    0x0d, 0x00, 0x41, 0x00, 0xfb, 0x07, 0x00, 0x41, 0x00, 0xfb, 0x0c, 0x00,
    0x1a, 0x0b,
};

test "runVoidExportWasi: JIT array.get_s null → null_reference code 10; OOB → oob_memory code 6 (D-293 array_oob siblings)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var n: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &arraygets_null_wasm, "_start", null, &n));
    try testing.expectEqual(@as(u32, 10), n);
    try testing.expectEqual(trap_surface.TrapKind.null_reference, trap_surface.jitTrapCode(n).?);
    var o: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &arraygets_oob_wasm, "_start", null, &o));
    try testing.expectEqual(@as(u32, 6), o);
    try testing.expectEqual(trap_surface.TrapKind.oob_memory, trap_surface.jitTrapCode(o).?);
}

// D-293 array_oob (the LAST piece): array.fill/array.copy route through the
// jitGcArrayFill/Copy TRAMPOLINE which collapsed null+OOB into W0=0. Now the
// trampoline returns ARRAY_NULL_SENTINEL (2) for a null ref; both arch callers
// route 2→null_reference (10), 0→oob_memory (6). Bytes from `wasm-tools parse`
// of `(array (mut i8))` (fill/copy need a MUTABLE array). array.fill=0xfb 0x10,
// array.copy=0xfb 0x11.
const arrayfill_null_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x02, 0x5e,
    0x78, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01, 0x07, 0x0a, 0x01,
    0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x0f, 0x01,
    0x0d, 0x00, 0xd0, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x01, 0xfb, 0x10,
    0x00, 0x0b,
};
const arrayfill_oob_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x02, 0x5e,
    0x78, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01, 0x07, 0x0a, 0x01,
    0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x12, 0x01,
    0x10, 0x00, 0x41, 0x00, 0xfb, 0x07, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41,
    0x01, 0xfb, 0x10, 0x00, 0x0b,
};
const arraycopy_null_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x02, 0x5e,
    0x78, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01, 0x07, 0x0a, 0x01,
    0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x12, 0x01,
    0x10, 0x00, 0xd0, 0x00, 0x41, 0x00, 0xd0, 0x00, 0x41, 0x00, 0x41, 0x01,
    0xfb, 0x11, 0x00, 0x00, 0x0b,
};
const arraycopy_oob_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x02, 0x5e,
    0x78, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02, 0x01, 0x01, 0x07, 0x0a, 0x01,
    0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x18, 0x01,
    0x16, 0x00, 0x41, 0x00, 0xfb, 0x07, 0x00, 0x41, 0x00, 0x41, 0x00, 0xfb,
    0x07, 0x00, 0x41, 0x00, 0x41, 0x01, 0xfb, 0x11, 0x00, 0x00, 0x0b,
};

test "runVoidExportWasi: JIT array.fill/copy null → null_reference 10; OOB → oob_memory 6 (D-293 array_oob trampoline)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    inline for (.{ arrayfill_null_wasm, arraycopy_null_wasm }) |w| {
        var c: u32 = 99;
        try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &w, "_start", null, &c));
        try testing.expectEqual(@as(u32, 10), c);
        try testing.expectEqual(trap_surface.TrapKind.null_reference, trap_surface.jitTrapCode(c).?);
    }
    inline for (.{ arrayfill_oob_wasm, arraycopy_oob_wasm }) |w| {
        var c: u32 = 99;
        try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &w, "_start", null, &c));
        try testing.expectEqual(@as(u32, 6), c);
        try testing.expectEqual(trap_surface.TrapKind.oob_memory, trap_surface.jitTrapCode(c).?);
    }
}

// `(module (type $a (struct (field i32))) (type $b (struct (field i64)))
//  (func (export "_start") struct.new_default $a ref.cast (ref $b) drop))` —
// casting a `(ref $a)` to the unrelated `(ref $b)` fails (Wasm 3.0 GC §4.4.5).
// D-293 slice-4d: cast_failure code 11. The `jitGcRefCast` trampoline returns 0
// on null-or-mismatch; for ref.cast a null operand is itself a cast failure, so
// the single 0-return trap maps cleanly to cast_failure.
const refcast_fail_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0c, 0x03, 0x5f, 0x01, 0x7f, 0x00, 0x5f,
    0x01, 0x7e, 0x00, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x02, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x0b,
    0x01, 0x09, 0x00, 0xfb, 0x01, 0x00, 0xfb, 0x16,
    0x01, 0x1a, 0x0b,
};

test "runVoidExportWasi: JIT ref.cast subtype mismatch → precise cast_failure code 11 (D-293 slice-4d)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var cf: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &refcast_fail_wasm, "_start", null, &cf));
    try testing.expectEqual(@as(u32, 11), cf);
    try testing.expectEqual(trap_surface.TrapKind.cast_failure, trap_surface.jitTrapCode(cf).?);
}

// D-293 slice-4e: the null-deref siblings slice-4c missed. `struct.get_s`
// (separate handler from `struct.get`), `i31.get_s`, `i31.get_u` each trap with
// a SINGLE failure mode = null reference (Wasm 3.0 GC §4.4.5 / §4.4.6) but still
// appended to the generic `bounds_fixups` channel (mislabel). The interp raises
// NullReference; these now route to `null_ref_fixups` → code 10, matching
// `struct.get`/`ref.as_non_null`. (The GC array.* trampolines stay generic —
// their single 0-return mixes ≥6 failure modes, so they need a kinded helper
// return, not mechanical routing; D-293 row.)

// `(module (type $s (struct (field i8))) (func (export "_start")
//  ref.null $s struct.get_s $s 0 drop))` — struct.get_s on a null structref.
const structgets_null_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x5f, 0x01, 0x78, 0x00, 0x60,
    0x00, 0x00, 0x03, 0x02, 0x01, 0x01, 0x07, 0x0a,
    0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74,
    0x00, 0x00, 0x0a, 0x0b, 0x01, 0x09, 0x00, 0xd0,
    0x00, 0xfb, 0x03, 0x00, 0x00, 0x1a, 0x0b,
};

// `(module (func (export "_start") ref.null i31 i31.get_s drop))`.
const i31gets_null_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x09,
    0x01, 0x07, 0x00, 0xd0, 0x6c, 0xfb, 0x1d, 0x1a,
    0x0b,
};

// `(module (func (export "_start") ref.null i31 i31.get_u drop))`.
const i31getu_null_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x09,
    0x01, 0x07, 0x00, 0xd0, 0x6c, 0xfb, 0x1e, 0x1a,
    0x0b,
};

test "runVoidExportWasi: JIT struct.get_s / i31.get_s / i31.get_u null → null_reference code 10 (D-293 slice-4e)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    for ([_][]const u8{ &structgets_null_wasm, &i31gets_null_wasm, &i31getu_null_wasm }) |wasm| {
        var tk: u32 = 99;
        try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, wasm, "_start", null, &tk));
        try testing.expectEqual(@as(u32, 10), tk);
        try testing.expectEqual(trap_surface.TrapKind.null_reference, trap_surface.jitTrapCode(tk).?);
    }
}

// `(module (tag $e) (func (export "_start") (throw $e)))` — `throw` with no
// enclosing `try_table` catch → the exception escapes the outermost function
// (Wasm 3.0 EH §4.5). D-292 C: uncaught_exception code 12. NOTE this fixed a
// latent x86_64 mis-report — the uncaught-throw JMP appended to `unreach_fixups`
// (code 5 = unreachable); both arches now route to the dedicated code-12 stub.
const throw_uncaught_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x0d, 0x03, 0x01, 0x00, 0x00, 0x07,
    0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72,
    0x74, 0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00,
    0x08, 0x00, 0x0b,
};

test "runVoidExportWasi: JIT uncaught throw → precise uncaught_exception code 12 (D-292 C)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var ue: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &throw_uncaught_wasm, "_start", null, &ue));
    try testing.expectEqual(@as(u32, 12), ue); // was 5 (unreachable) on x86_64 pre-D-292-C
    try testing.expectEqual(trap_surface.TrapKind.uncaught_exception, trap_surface.jitTrapCode(ue).?);
}

// D-295 / D-291 regression guard: `shootout/ed25519.wasm` (53 KB, copied into the src
// package so @embedFile can reach it) run under JIT. Pre-fix (arm64
// `homedCallerSavedSpillReload` SKIPPED callee-saved-bank homes X20..X22 across calls),
// func 11 homed its saved-SP local2 in a callee-saved reg, call-crossing → clobbered by
// `call 14`/`call 17` → __stack_pointer over-restore → func 7 data-region buffer → func
// 17 clobbered the funcptr global → call_indirect oob_table TRAP. The bug needs realworld
// register pressure (not minimally reproducible); ed25519 is the deterministic repro.
// `_start`'s SUCCESS path is pure arithmetic (only the error path calls proc_exit), so a
// null-host run returns cleanly WHEN FIXED and traps mid-computation when broken. Fast
// (<1s) under JIT. (`bench/runners/wasm/shootout/ed25519.wasm` is the source of truth.)
const d291_ed25519_wasm = @embedFile("testdata/d291_ed25519.wasm");

test "runVoidExportWasi: ed25519 JIT runs without trap (D-291 callee-saved-home regression)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    _ = try runner.runVoidExportWasi(testing.allocator, d291_ed25519_wasm, "_start", null, null);
}

test "JIT interrupt poll: prologue traps interrupted (trap_kind 16) on a host-set flag (D-314 #3a)" {
    // BOTH arches now (arm64 + x86_64 prologue polls landed). The exported `f`
    // CALLS `$g`, so it `uses_runtime_ptr` → the x86_64 prologue actually sets
    // up R15 + emits the poll (a no-call fn has no R15, hence no poll, on x86_64;
    // arm64 always pins X19). Win64 verified via windowsmini.
    // (module (func $g (result i32) i32.const 42)
    //         (func (export "f") (result i32) call $g))
    const fcall = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x00, 0x07, 0x05, 0x01, 0x01,
        0x66, 0x00, 0x01, 0x0a, 0x0b, 0x02, 0x04, 0x00, 0x41, 0x2a, 0x0b, 0x04,
        0x00, 0x10, 0x00, 0x0b,
    };
    var inst = try runner.JitInstance.init(testing.allocator, &fcall);
    defer inst.deinit(testing.allocator);
    var flag = std.atomic.Value(u32).init(0);
    inst.setInterruptFlag(&flag);
    // Flag clear → the poll falls through; f calls g, returns 42.
    try testing.expectEqual(@as(?u64, 42), try inst.invoke(testing.allocator, "f", &.{}));
    // Flag set → f's prologue poll traps before the call; trap_kind = 16.
    flag.store(1, .monotonic);
    try testing.expectError(entry.Error.Trap, inst.invoke(testing.allocator, "f", &.{}));
    try testing.expectEqual(@as(u32, 16), inst.owned.rt.trap_kind);
    try testing.expectEqual(trap_surface.TrapKind.interrupted, trap_surface.jitTrapCode(inst.owned.rt.trap_kind).?);
    // Cleared → re-checked each call (not latched); f runs again.
    flag.store(0, .monotonic);
    inst.owned.rt.trap_flag = 0;
    try testing.expectEqual(@as(?u64, 42), try inst.invoke(testing.allocator, "f", &.{}));
}

// (func (export "f") (result i32) (local $i i32)
//   (local.set $i (i32.const 1000000))
//   (loop $L (local.set $i (i32.sub (local.get $i) (i32.const 1)))
//            (br_if $L (local.get $i)))    ;; backward br_if = a back-edge
//   (i32.const 42))
// Shared by the interrupt R15-forcing test and the fuel tests: ~1e6 br_if
// back-edge poll crossings + 1 prologue crossing.
const countdown_loop_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
    0x00, 0x00, 0x0a, 0x1c, 0x01, 0x1a, 0x01, 0x01, 0x7f, 0x41, 0xc0, 0x84,
    0x3d, 0x21, 0x00, 0x03, 0x40, 0x20, 0x00, 0x41, 0x01, 0x6b, 0x21, 0x00,
    0x20, 0x00, 0x0d, 0x00, 0x0b, 0x41, 0x2a, 0x0b,
};

test "JIT loop fn with flag raised BEFORE invoke traps interrupted (D-314 #3a R15-forcing)" {
    // The flag is set BEFORE invoke, so on both arches the PROLOGUE poll traps
    // at entry (never reaching a back-edge poll). What this pins on x86_64 is
    // the R15-FORCING: a no-call loop fn only has a prologue poll because
    // usage.usesRuntimePtr lists `.loop` — drop that and there is NO poll at
    // all and the countdown completes with 42 (the observed TDD red). The
    // RUNNING-loop back-edge case is the thread-raiser tests below.
    var inst = try runner.JitInstance.init(testing.allocator, &countdown_loop_wasm);
    defer inst.deinit(testing.allocator);
    var flag = std.atomic.Value(u32).init(0);
    inst.setInterruptFlag(&flag);
    // Flag clear → the loop counts down ~1e6 iterations to 0 and returns 42.
    try testing.expectEqual(@as(?u64, 42), try inst.invoke(testing.allocator, "f", &.{}));
    // Flag set → the FIRST back-edge poll traps long before the loop finishes.
    flag.store(1, .monotonic);
    try testing.expectError(entry.Error.Trap, inst.invoke(testing.allocator, "f", &.{}));
    try testing.expectEqual(@as(u32, 16), inst.owned.rt.trap_kind);
    try testing.expectEqual(trap_surface.TrapKind.interrupted, trap_surface.jitTrapCode(inst.owned.rt.trap_kind).?);
    // Cleared → runs to completion again.
    flag.store(0, .monotonic);
    inst.owned.rt.trap_flag = 0;
    try testing.expectEqual(@as(?u64, 42), try inst.invoke(testing.allocator, "f", &.{}));
}

/// Raises the interrupt flag from a sibling thread after a spin-wait long
/// enough that the main thread is already INSIDE the guest loop (past the
/// prologue poll, which sees flag=0 at entry) — so only a BACK-EDGE poll can
/// deliver the trap. No clock dependency: ~50M spin hints ≈ tens of ms; the
/// guest loop is infinite, so "too late" cannot happen. If the back-edge poll
/// regressed, the invoke spins forever (test hang = failure, mirroring the
/// interp back-edge test's hang-as-failure contract; gate timeouts bound it).
const FlagRaiser = struct {
    fn run(flag_ptr: *std.atomic.Value(u32)) void {
        var i: u64 = 0;
        while (i < 50_000_000) : (i += 1) std.atomic.spinLoopHint();
        flag_ptr.store(1, .monotonic);
    }
};

test "JIT fuel: metered budget meters poll crossings and traps out_of_fuel (kind 17, D-314 #3b)" {
    // Countdown guest = 1 prologue crossing + 1e6 br_if back-edge crossings
    // (the no-params br_if polls on every pass incl. the exit pass).
    var inst = try runner.JitInstance.init(testing.allocator, &countdown_loop_wasm);
    defer inst.deinit(testing.allocator);
    // Unmetered (default) → completes; fuelRemaining reads null.
    try testing.expectEqual(@as(?u64, 42), try inst.invoke(testing.allocator, "f", &.{}));
    try testing.expectEqual(@as(?u64, null), inst.fuelRemaining());
    // Metered with headroom → completes; exactly 1_000_001 units consumed
    // (pins the crossing-unit semantics: prologue + one per loop pass).
    inst.setFuel(2_000_000);
    try testing.expectEqual(@as(?u64, 42), try inst.invoke(testing.allocator, "f", &.{}));
    try testing.expectEqual(@as(?u64, 2_000_000 - 1_000_001), inst.fuelRemaining());
    // Tight budget → the 101st crossing SUBs the cell to -1 and traps 17,
    // long before the 1e6-pass countdown could finish.
    inst.setFuel(100);
    try testing.expectError(entry.Error.Trap, inst.invoke(testing.allocator, "f", &.{}));
    try testing.expectEqual(@as(u32, 17), inst.owned.rt.trap_kind);
    try testing.expectEqual(trap_surface.TrapKind.out_of_fuel, trap_surface.jitTrapCode(inst.owned.rt.trap_kind).?);
    try testing.expectEqual(@as(?u64, 0), inst.fuelRemaining());
    // Disarm + clear → runs to completion again.
    inst.setFuel(null);
    inst.owned.rt.trap_flag = 0;
    try testing.expectEqual(@as(?u64, 42), try inst.invoke(testing.allocator, "f", &.{}));
}

test "runWasiLenient: RunLimits fuel + interrupt_flag bound an infinite-loop guest (D-314 #3a-4)" {
    // (module (func (export "_start") (loop (br 0)))) — only a limit ends it.
    const inf_start = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60,
        0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
        0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x03,
        0x40, 0x0c, 0x00, 0x0b, 0x0b,
    };
    var trap_code: u32 = 0;
    try testing.expectError(entry.Error.Trap, runner.runWasiLenient(testing.allocator, &inf_start, "_start", null, &trap_code, .{ .fuel = 100 }, null));
    try testing.expectEqual(@as(u32, 17), trap_code); // out_of_fuel
    var flag = std.atomic.Value(u32).init(1);
    trap_code = 0;
    try testing.expectError(entry.Error.Trap, runner.runWasiLenient(testing.allocator, &inf_start, "_start", null, &trap_code, .{ .interrupt_flag = &flag }, null));
    try testing.expectEqual(@as(u32, 16), trap_code); // interrupted (prologue poll)
}

test "JIT back-edge poll interrupts a RUNNING infinite loop (br back edge, D-314 #3a)" {
    // (func (export "f") (result i32) (loop (br 0)) (i32.const 42)) — the
    // backward `br 0` is the only exit-capable site (emitBr loop path on both
    // arches). Flag is 0 at entry; the raiser thread sets it mid-spin.
    const inf_loop_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00, 0x0a, 0x0b, 0x01, 0x09, 0x00, 0x03, 0x40, 0x0c, 0x00, 0x0b,
        0x41, 0x2a, 0x0b,
    };
    var inst = try runner.JitInstance.init(testing.allocator, &inf_loop_wasm);
    defer inst.deinit(testing.allocator);
    var flag = std.atomic.Value(u32).init(0);
    inst.setInterruptFlag(&flag);
    var th = try std.Thread.spawn(.{}, FlagRaiser.run, .{&flag});
    try testing.expectError(entry.Error.Trap, inst.invoke(testing.allocator, "f", &.{}));
    th.join();
    try testing.expectEqual(@as(u32, 16), inst.owned.rt.trap_kind);
    try testing.expectEqual(trap_surface.TrapKind.interrupted, trap_surface.jitTrapCode(inst.owned.rt.trap_kind).?);
}

test "JIT back-edge poll interrupts a RUNNING infinite br_table loop (D-314 #3a)" {
    // (func (export "f") (result i32) (loop $L (br_table $L (i32.const 0)))
    //   (i32.const 42)) — br_table with an empty case vector + default $L: the
    // default tail IS the back edge (arm64: emitBranchToDepth loop path;
    // x86_64: emitBrTableJmp loop path). Same raiser contract as above.
    const brtable_wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00, 0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x03, 0x40, 0x41, 0x00, 0x0e,
        0x00, 0x00, 0x0b, 0x41, 0x2a, 0x0b,
    };
    var inst = try runner.JitInstance.init(testing.allocator, &brtable_wasm);
    defer inst.deinit(testing.allocator);
    var flag = std.atomic.Value(u32).init(0);
    inst.setInterruptFlag(&flag);
    var th = try std.Thread.spawn(.{}, FlagRaiser.run, .{&flag});
    try testing.expectError(entry.Error.Trap, inst.invoke(testing.allocator, "f", &.{}));
    th.join();
    try testing.expectEqual(@as(u32, 16), inst.owned.rt.trap_kind);
    try testing.expectEqual(trap_surface.TrapKind.interrupted, trap_surface.jitTrapCode(inst.owned.rt.trap_kind).?);
}

// ADR-0202 D3 — the emit→linker plumbing carries the oob-stub offset into the
// trap registry: a compiled function WITH a bounds-checked memory access
// registers a real (non-`no_stub`) redirect entry, and one WITHOUT stays
// `no_stub`. This is the phase-2 (pre-elision) proof that the PC-redirect
// target the fault handler needs is actually published.
test "JitModule publishes an oob-stub trap entry for a memory-access function (ADR-0202 D3)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (func (export "f") (result i32) i32.store(0,42); i32.load(0)) — memory
    // access → an emitted kind=6 oob stub.
    const with_mem = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01,
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a,
        0x10, 0x01, 0x0e, 0x00, 0x41, 0x00, 0x41, 0x2a,
        0x36, 0x02, 0x00, 0x41, 0x00, 0x28, 0x02, 0x00,
        0x0b,
    };
    var compiled = try runner.compileWasm(testing.allocator, &with_mem);
    defer compiled.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), compiled.module.trap_func_entries.len);
    const e = compiled.module.trap_func_entries[0];
    try testing.expect(e.oob_stub_off != trap_registry.FuncEntry.no_stub);
    // The stub is at or after the function's code start (region-relative).
    try testing.expect(e.oob_stub_off >= e.code_off);

    // (func (export "f") (result i32) i32.const 42) — no memory access → no stub.
    const no_mem = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41,
        0x2a, 0x0b,
    };
    var compiled2 = try runner.compileWasm(testing.allocator, &no_mem);
    defer compiled2.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), compiled2.module.trap_func_entries.len);
    try testing.expectEqual(
        trap_registry.FuncEntry.no_stub,
        compiled2.module.trap_func_entries[0].oob_stub_off,
    );
}

// ADR-0202 D3 — a wrapper-thunk module (any exported ≥1-param / ≥2-result
// function) publishes a NEW combined block via `linkWithThunks`, which frees
// the body block. That path must RE-register the combined block, or a guard
// fault in the dominant real-module shape would go unclassified. Regression
// pin for the linkWithThunks registration fix.
test "JitModule re-registers the combined block for a wrapper-thunk module (ADR-0202 D3)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (func (export "f") (param i32) (result i32) local.get 0; i32.load) —
    // the i32 param forces a buffer-write wrapper thunk; the i32.load emits a
    // kind=6 oob stub. Bytes verified against `wasm-tools parse`.
    const param_mem = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00,
        0x01, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x28,
        0x02, 0x00, 0x0b,
    };
    var compiled = try runner.compileWasm(testing.allocator, &param_mem);
    defer compiled.deinit(testing.allocator);
    // FAIL-1 pin: the bug returned trap_region_start=0 + empty entries for this
    // (thunk) path. The combined block must be registered (non-zero region
    // start) and carry the function's real oob stub.
    try testing.expect(compiled.module.trap_region_start != 0);
    try testing.expectEqual(
        @intFromPtr(compiled.module.block.bytes.ptr),
        compiled.module.trap_region_start, // registered under the COMBINED block, not the freed body block
    );
    try testing.expectEqual(@as(usize, 1), compiled.module.trap_func_entries.len);
    try testing.expect(
        compiled.module.trap_func_entries[0].oob_stub_off != trap_registry.FuncEntry.no_stub,
    );
}
