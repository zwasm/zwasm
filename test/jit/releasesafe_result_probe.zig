//! D-245 RESULT-path regression probe (§15.5 / chunk 1).
//!
//! Companion to `scripts/check_jit_releasesafe.sh`, which only drives the
//! no-arg VOID path (`runVoidExport`). This probe drives the i32 RESULT path
//! (`runner.runI32Export` → `entry.invokeAndCheck`), which has its own
//! host→JIT seam: the JIT prologue MOV-installs the pinned callee-saved
//! cohort (arm64 X19/X24-X28; x86_64 RBX/R12-R15) from `rt` WITHOUT
//! stack-saving the caller's values, so a plain `@call` clobbers the host's
//! live callee-saved registers. In ReleaseSafe the optimized host keeps live
//! values there → heap-corruption SEGV; Debug keeps nothing live → no crash.
//!
//! To make the clobber observable, the probe ALLOCATES a slice and HOLDS it
//! live across the `runI32Export` call (mirroring how `runVoidExport`'s caller
//! SEGV'd in `compiled.deinit` after the call corrupted the heap-pointer it
//! kept in a callee-saved register). We touch the slice both before and after
//! the call; if the call clobbered the register holding the slice base, the
//! post-call free / readback corrupts the heap → SEGV / abort.
//!
//! Built ONLY via `zig build jit-result-probe-releasesafe`, which pins both
//! this module AND a fresh `core` module to `-OReleaseSafe` regardless of the
//! ambient `-Doptimize` (an exe's optimize does NOT propagate to an imported
//! pre-built `core`, so a normal run-artifact can't isolate ReleaseSafe).

const std = @import("std");
const zwasm = @import("zwasm");
const runner = zwasm.engine.runner;

// `(module (memory 1) (func (export "f") (result i32)
//    (i32.store (i32.const 0) (i32.const 42)) (i32.load (i32.const 0))))`
//
// The memory access is load-bearing: it makes the JIT body `uses_runtime_ptr`,
// so the prologue MOV-installs the pinned callee-saved cohort from `rt`. A
// bare `(i32.const 42)` body does NOT touch the runtime pointer → the prologue
// installs nothing → no clobber → the bug would NOT reproduce. Storing/loading
// `42` keeps the asserted result while forcing the vulnerable prologue.
const wasm_f_42 = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
    0x02, 0x01, 0x00,
    0x05, 0x03, 0x01, 0x00, 0x01, //                    memory: min 1
    0x07, 0x05, 0x01, 0x01, 0x66,
    0x00, 0x00,
    0x0a, 0x10, 0x01, 0x0e, 0x00, //                    code
    0x41, 0x00, 0x41, 0x2a, 0x36, 0x02, 0x00, //        i32.store (0) 42
    0x41, 0x00, 0x28, 0x02, 0x00, //                    i32.load (0)
    0x0b,
};

/// Hold a cohort's-worth of independent live pointers across the JIT call so
/// ReleaseSafe is forced to keep some of them in the callee-saved registers
/// the JIT prologue clobbers (arm64 X19/X24-X28; x86_64 RBX/R12-R15). Each
/// pointer is dereferenced BOTH before and after the call, and the result
/// feeds back into the assertion, so the optimizer cannot sink/hoist them out
/// of the live range. `.never_inline` gives this frame its own register
/// allocation around the call (mirrors the real embedder seam where the host
/// caller's frame straddles the JIT call).
fn probeGprOnce(alloc: std.mem.Allocator) !void {
    // Eight independent allocations — more than the cohort width on either
    // arch, maximizing the chance the allocator pins live bases in clobbered
    // regs across the call (this is what SEGV'd `compiled.deinit` on the void
    // path: a live heap pointer survived in a callee-saved reg).
    var slots: [8][]u64 = undefined;
    inline for (&slots, 0..) |*s, k| {
        s.* = try alloc.alloc(u64, 16);
        for (s.*, 0..) |*v, i| v.* = (0xA5A5_0000_0000_0000 | (@as(u64, k) << 32)) | @as(u64, i);
    }
    defer inline for (slots) |s| alloc.free(s);

    // Pre-call read to anchor the live range BEFORE the call.
    var pre: u64 = 0;
    inline for (slots) |s| pre +%= s[0] +% s[15];
    std.mem.doNotOptimizeAway(pre);

    const result = try runner.runI32Export(alloc, &wasm_f_42, "f");

    // Post-call: re-read every slot. If the call clobbered a callee-saved reg
    // holding one of these slice bases, this read hits corrupted heap state →
    // SEGV / allocator abort under ReleaseSafe.
    inline for (&slots, 0..) |*s, k| {
        for (s.*, 0..) |v, i| {
            const want = (0xA5A5_0000_0000_0000 | (@as(u64, k) << 32)) | @as(u64, i);
            if (v != want) {
                std.debug.print("[probe] slot[{d}][{d}] corrupted: {x} != {x}\n", .{ k, i, v, want });
                return error.SentinelCorrupted;
            }
        }
    }
    std.mem.doNotOptimizeAway(pre);

    if (result != 42) {
        std.debug.print("[probe] FAIL: runI32Export returned {d}, expected 42\n", .{result});
        return error.WrongResult;
    }
}

// `(module (func (export "g") (result f64)` with eight simultaneously-live
// f64 locals summed pairwise — two more than the six-wide FP pool
// (`abi.allocatable_xmms`), so the body has to reach the spill stage rather
// than sit in a corner of the pool. Which XMMs it ends up using is the
// allocator's choice; the coverage of the range is asserted in `entry.zig`.
const wasm_g_f64 = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7c, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x67,
    0x00, 0x00, 0x0a, 0x75, 0x01, 0x73, 0x01, 0x08, 0x7c, 0x44, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xf8, 0x3f, 0x21, 0x00, 0x44, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x02, 0x40, 0x21, 0x01, 0x44, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x09, 0x40, 0x21, 0x02, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x40, 0x10, 0x40, 0x21, 0x03, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20,
    0x14, 0x40, 0x21, 0x04, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x18,
    0x40, 0x21, 0x05, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x1c, 0x40,
    0x21, 0x06, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x20, 0x40, 0x21,
    0x07, 0x20, 0x00, 0x20, 0x01, 0xa0, 0x20, 0x02, 0x20, 0x03, 0xa0, 0xa0,
    0x20, 0x04, 0x20, 0x05, 0xa0, 0x20, 0x06, 0x20, 0x07, 0xa0, 0xa0, 0xa0,
    0x0b,
};

/// A runtime seed the optimiser cannot see through, so the values below are
/// neither constants it can rematerialise after the call nor loads it can sink
/// past it. Written once per iteration by `main`.
var fp_seed: f64 = 0;

/// #286 — Win64 makes XMM6-XMM15 non-volatile and the JIT preserves none of
/// them. The GPR arm above cannot see it: it holds slice bases, which live in
/// general-purpose registers.
///
/// The precondition is the one that makes a non-volatile register useful in
/// the first place — a value live ACROSS a call goes there — so the probe
/// holds twelve independent f64s across `runF64Export` and reads each back.
/// Best-effort by nature: which of them the compiler actually leaves in an XMM
/// is its choice, and the pre-fix Windows run reporting `fp slot[0] corrupted`
/// is the evidence that at least one of them was. The guarantee that the
/// clobber lists cover the whole range lives in `entry.zig`'s coverage tests,
/// not here.
fn probeFpOnce() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const s = fp_seed;
    // Twelve independent scalars, more than Win64's ten non-volatile XMMs.
    // Separate locals rather than an array: an array is a memory object, and a
    // value the host spilled to its own stack is one the guest cannot reach.
    var a: f64 = s + 1.0625;
    var b: f64 = s + 2.125;
    var c: f64 = s + 3.1875;
    var d: f64 = s + 4.25;
    var e: f64 = s + 5.3125;
    var f: f64 = s + 6.375;
    var g: f64 = s + 7.4375;
    var h: f64 = s + 8.5;
    var i: f64 = s + 9.5625;
    var j: f64 = s + 10.625;
    var k: f64 = s + 11.6875;
    var l: f64 = s + 12.75;
    inline for (.{ &a, &b, &c, &d, &e, &f, &g, &h, &i, &j, &k, &l }) |ptr| {
        ptr.* += 0.0; // a mutation the value survives, so each stays a `var`
        // The value, not its address: `doNotOptimizeAway` takes a pointer
        // through an `"m"` operand with a memory clobber, which is the one
        // thing that would push these onto the host's own stack — where the
        // guest cannot reach them and the probe would measure nothing.
        std.mem.doNotOptimizeAway(ptr.*);
    }

    const result = try runner.runF64Export(alloc, &wasm_g_f64, "g");

    // Recomputed from the seed AFTER the call: the freshly computed side is
    // correct by construction, so a difference is the held register.
    const want = [_]f64{ s + 1.0625, s + 2.125, s + 3.1875, s + 4.25, s + 5.3125, s + 6.375, s + 7.4375, s + 8.5, s + 9.5625, s + 10.625, s + 11.6875, s + 12.75 };
    const got = [_]f64{ a, b, c, d, e, f, g, h, i, j, k, l };
    for (got, want, 0..) |gv, wv, idx| {
        if (gv != wv) {
            std.debug.print("[probe] fp slot[{d}] corrupted: {d} != {d}\n", .{ idx, gv, wv });
            return error.FpSentinelCorrupted;
        }
    }

    // 1.5+2.25+3.125+4.0625+5.03125+6.015625+7.0078125+8.00390625
    const expect: f64 = 36.99609375;
    if (result != expect) {
        std.debug.print("[probe] FAIL: runF64Export returned {d}, expected {d}\n", .{ result, expect });
        return error.WrongResult;
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Repeat to reshuffle the heap and re-roll register allocation; the
    // clobber is deterministic per-codegen, but extra iterations harden
    // against an incidentally-safe allocation layout on one run.
    var n: u32 = 0;
    while (n < 64) : (n += 1) {
        try @call(.never_inline, probeGprOnce, .{alloc});
    }
    std.debug.print("[probe] OK: runI32Export == 42, sentinels intact x64 (D-245 result path)\n", .{});

    var m: u32 = 0;
    while (m < 64) : (m += 1) {
        fp_seed = @as(f64, @floatFromInt(m)) * 0.5;
        try @call(.never_inline, probeFpOnce, .{});
    }
    std.debug.print("[probe] OK: runF64Export == 36.99609375, fp sentinels intact x64 (#286 XMM cohort)\n", .{});
}
