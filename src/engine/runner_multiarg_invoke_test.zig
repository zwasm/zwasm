//! D-477 characterization tests — host→guest JIT multi-arg `--invoke`.
//!
//! Pins the CURRENT behaviour of the JIT host-invoke path before the
//! D-477 bundle generalises `wrapper_thunk.emit` to arbitrary N typed
//! args + multi/FP/ref results (findings: `.dev/d477_findings.md`):
//!
//!  - `JitInstance.invoke` handles 0-3 args / single scalar result via
//!    the shape-specific `entry.callXxx_yyy` family (runner.zig:934);
//!    4+ args → `UnsupportedEntrySignature`.
//!  - `runWasiLenient` (the CLI `--invoke` path) rejects EVERY param
//!    (runner.zig:657) — only 0-arg exports invoke under the JIT today.
//!
//! The "GAP" assertions below pin the rejects. As each Phase IV slice
//! lands, the matching reject-pin flips to a value-assertion IN THE SAME
//! COMMIT that removes the reject — so the change is always deliberate
//! and the interp oracle (the full spec suite, multi-arg pervasive) is
//! never silently diverged from. Discovered via `src/zwasm.zig`'s
//! `test {}` block. Module bytes are hand-encoded (wat2wasm-free at
//! test runtime), mirroring `runner_test.zig`.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const runner = @import("runner.zig");
const JitInstance = runner.JitInstance;

// (module (func (export "add") (param i32 i32) (result i32)
//   local.get 0 local.get 1 i32.add))
const add_i32i32 = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32 i32)->i32
    0x03, 0x02, 0x01, 0x00, // func: type 0
    0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // export "add" func 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // code
};

// (module (func (export "sum4") (param i32 i32 i32 i32) (result i32)
//   local.get 0 local.get 1 i32.add local.get 2 i32.add local.get 3 i32.add))
const sum4_i32 = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x09, 0x01, 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32 i32 i32 i32)->i32
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x08, 0x01, 0x04, 0x73, 0x75, 0x6d, 0x34, 0x00, 0x00, // export "sum4"
    0x0a, 0x0f, 0x01, 0x0d, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a,
    0x20, 0x02, 0x6a, 0x20, 0x03, 0x6a, 0x0b,
};

// (module (func (export "addf") (param f64 f64) (result f64)
//   local.get 0 local.get 1 f64.add))
const addf_f64 = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7c, 0x7c, 0x01, 0x7c, // type: (f64 f64)->f64
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x08, 0x01, 0x04, 0x61, 0x64, 0x64, 0x66, 0x00, 0x00, // export "addf"
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0xa0, 0x0b, // f64.add
};

test "D-477 baseline: JitInstance.invoke 2×i32 add(2,3) → 5 (current working shape, durable)" {
    var inst = try JitInstance.init(testing.allocator, &add_i32i32);
    defer inst.deinit(testing.allocator);
    const got = try inst.invoke(testing.allocator, "add", &.{ 2, 3 });
    try testing.expectEqual(@as(?u64, 5), got);
}

test "D-477: JitInstance.invoke 4×i32 sum4(2,3,4,5) → 14 via buffer thunk (arm64 + x86_64 SysV)" {
    // arm64 (emitAarch64, ≤7 params) and x86_64 SysV (emitX8664SysV, ≤5 params)
    // both emit the N-GPR-param thunk → invoke routes the 4-arg shape through
    // invokeViaBufferSingle → 2+3+4+5 = 14. Win64 caps register params at 3
    // (RDX/R8/R9 after RCX=rt) and stack-spill emit is a later D-477 slice, so a
    // 4-arg func has no thunk there and stays UnsupportedEntrySignature.
    // Arch/OS-split gate cited to D-477 per test_discipline §4.
    var inst = try JitInstance.init(testing.allocator, &sum4_i32);
    defer inst.deinit(testing.allocator);
    const supported = builtin.cpu.arch == .aarch64 or
        (builtin.cpu.arch == .x86_64 and builtin.os.tag != .windows);
    if (supported) {
        try testing.expectEqual(@as(?u64, 14), try inst.invoke(testing.allocator, "sum4", &.{ 2, 3, 4, 5 }));
    } else {
        try testing.expectError(
            runner.Error.UnsupportedEntrySignature,
            inst.invoke(testing.allocator, "sum4", &.{ 2, 3, 4, 5 }),
        );
    }
}

test "D-477 FP: runWasiLenientArgs addf(2.5,1.5) → f64 4.0 via the FP-bank thunk (all 3 arches)" {
    // FP params/result through the buffer-write thunk on every arch: arm64 V0/V1→D0,
    // x86_64 SysV XMM0/XMM1→MOVSD, Win64 positional XMM1/XMM2→MOVSD. Runs natively
    // on arm64 + x86_64-macos (Rosetta); Win64 runtime via the windows gate.
    var result: ?runner.ScalarResult = null;
    const a: u64 = @bitCast(@as(f64, 2.5));
    const b: u64 = @bitCast(@as(f64, 1.5));
    _ = try runner.runWasiLenientArgs(testing.allocator, &addf_f64, "addf", null, null, .{}, &result, &.{ a, b }, null);
    try testing.expectEqual(@as(f64, 4.0), result.?.f64);
}

test "D-477: runWasiLenient (no args) of a 2-arg export → EntryNotCallable" {
    // Zero args supplied for a 2-param entry → can't invoke. The back-compat
    // delegate threads an empty arg slice, so the arity guard rejects (this is
    // distinct from the WITH-args path below).
    try testing.expectError(
        runner.Error.EntryNotCallable,
        runner.runWasiLenient(testing.allocator, &add_i32i32, "add", null, null, .{}, null),
    );
}

test "D-477: runWasiLenientArgs add(2,3) → scalar i32 5 (all arches: arm64 ≤7 / x86_64 SysV ≤5 / Win64 ≤3)" {
    // The `--invoke add=2,3 --engine jit` exit-condition at the engine boundary:
    // typed args through the buffer-write thunk. 2-param GPR is now emitted on
    // ALL three arches (arm64 emitAarch64, x86_64 SysV emitX8664SysV, Win64
    // emitX8664Win64 generic ≤3-param). (sum4's 4 params stay Win64-deferred.)
    var result: ?runner.ScalarResult = null;
    _ = try runner.runWasiLenientArgs(testing.allocator, &add_i32i32, "add", null, null, .{}, &result, &.{ 2, 3 }, null);
    try testing.expectEqual(@as(i32, 5), result.?.i32);
}
