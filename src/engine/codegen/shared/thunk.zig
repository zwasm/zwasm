//! Cross-module import bridge thunk facade (ADR-0066).
//! Arch-agnostic API; routes to `arm64/thunk.zig`
//! or `x86_64/thunk.zig` per `builtin.target.cpu.arch` (same
//! pattern as `shared/compile.zig`'s emit-module switch).
//!
//! A bridge thunk is the per-import-resolved native-code snippet
//! planted into `JitRuntime.host_dispatch_base[i]` when import
//! `i` resolves against a registered exporter Wasm instance.
//! At call time the importer's emit path performs the standard
//! indirect-call sequence (caller-side emit unchanged); the
//! thunk swaps the JitRuntime pointer from caller's to
//! callee's and tail-jumps to the callee's JIT entry. The
//! callee's eventual RET returns directly to the importer's
//! call site; the importer's `captureCallResult` reads the
//! return register per the callee's signature.
//!
//! See ADR-0066 §Decision for the byte-layout rationale across
//! both architectures and §Consequences §"Implementation chunk
//! plan" for the (c)-2.2..(c)-2.4 sequence that consumes this
//! facade.
//!
//! Zone 2 (`src/engine/codegen/shared/`) — may import both
//! arch modules per the established `shared/` cross-arch
//! pattern (cf. `shared/compile.zig:42`).

const std = @import("std");
const builtin = @import("builtin");

const jit_mem = @import("../../../platform/jit_mem.zig");

const arch_thunk = switch (builtin.target.cpu.arch) {
    .aarch64 => @import("../arm64/thunk.zig"),
    .x86_64 => @import("../x86_64/thunk.zig"),
    else => @compileError("ADR-0066 bridge thunk encoder not implemented for this architecture"),
};

/// Bridge thunk byte count for the current target architecture.
/// Stable across all callee signatures — every thunk has the same
/// shape; only the embedded literals differ.
///
/// The per-arch modules own the layout and its byte count; this
/// facade deliberately does NOT restate either. Both numbers have
/// moved three times (D-144 grew arm64 56 → 96; D-238 / ADR-0185 a
/// grew x86_64 27 → 40; #381 grew x86_64 40 → 79) and the copy
/// here was stale for two of them.
///
/// What IS this facade's contract, and holds on both arches:
/// - **Call-and-return**, not a tail-jump (D-142 fix (A)): the
///   thunk CALLs the callee and returns to the importer, so it can
///   restore state around the call.
/// - The caller's runtime pointer (arm64 X19 / x86_64 R15) and the
///   rest of the reserved-invariant cohort survive the call.
/// - The callee's `trap_flag`/`trap_kind` are cleared on the way in
///   and relayed onto the caller's runtime on the way out (#381), so
///   a trap raised inside the callee reaches the importer's existing
///   post-call check.
/// - An RBP / X29 frame-link makes the thunk frame a chain link for
///   the cross-instance EH unwinder (D-238 / ADR-0185 a, ADR-0134 D1).
pub const thunk_bytes: usize = arch_thunk.thunk_bytes;

/// Emit one bridge thunk into `buf[0..thunk_bytes]`. `buf` MUST
/// be exactly `thunk_bytes` long for the current target. The
/// caller owns the buffer and is responsible for placing it in
/// an RX-mappable arena before the thunk is invoked (see
/// (c)-2.2 thunk-arena lifecycle chunk).
///
/// `callee_rt`    — the callee instance's `*JitRuntime` cast to
///                  `usize`, installed in the entry-arg0 register
///                  before the CALL so the callee's prologue
///                  snapshots it into its own runtime-ptr register.
///                  X0 on AArch64; on x86_64 whichever register the
///                  active convention names (`abi.current.entry_arg0_gpr`
///                  — RDI under SysV, RCX under Win64, #385).
/// `callee_entry` — the callee's JIT entry point address (the
///                  first instruction of the callee function's
///                  body in its module's JIT code block).
///
/// The emitted thunk is position-independent on both targets
/// (AArch64 uses PC-relative ADR; x86_64 embeds the literals
/// in MOV imm64), so it can be relocated to any RX page
/// without patching after emit.
pub fn emitThunk(buf: []u8, callee_rt: usize, callee_entry: usize) void {
    arch_thunk.emitThunk(buf, callee_rt, callee_entry);
}

// ============================================================
// Per-instance thunk arena lifecycle (ADR-0066 (c)-2.2)
// ============================================================
//
// The arena is a JIT-capable (RWX-on-alloc, mprotect-to-RX-on-
// finalize) memory region sized to hold one bridge thunk per
// import-function slot. It is allocated at instantiation time
// — AFTER imports have been resolved against `Store.instances`
// per ADR-0066 §"Resolver wire-up" — written by the resolver
// chunk ((c)-2.3), then finalized (set executable, mprotect RX
// + cache invalidation) before the importer's entry point is
// invoked. Lifetime is owned by the per-instance JitModule:
// `freeArena` runs alongside `JitModule.deinit`.
//
// An instance with **zero** Wasm-cross-module function imports
// — including the common case of host-C-fn-only imports
// (e.g. `(import "spectest" "print_i32" ...)`) — gets the
// empty-arena sentinel (`bytes.len == 0`). Slot lookups are
// rejected at compile time via `std.debug.assert` rather than
// silently returning a zero-length slice, mirroring the
// `linker.zig` empty-module sentinel pattern.

/// Byte size of the thunk arena for `num_func_imports` Wasm-
/// cross-module function imports. Returns 0 for the zero-import
/// case (the empty-arena sentinel path). Each populated slot is
/// `thunk_bytes` bytes wide; slots are laid out back-to-back
/// with no padding (every thunk is naturally `thunk_bytes`-
/// aligned and self-contained).
///
/// **Note**: only *Wasm-cross-module* func imports consume a
/// slot. Host-C-fn imports (the existing `hostDispatchTrap` /
/// `hostImportTrapStub` path) plant the C fn pointer directly
/// into `host_dispatch_base[i]`; no thunk is needed and no
/// slot is reserved.
pub fn arenaBytes(num_func_imports: usize) usize {
    return num_func_imports * thunk_bytes;
}

/// Allocate a per-instance thunk arena sized for
/// `num_func_imports` Wasm-cross-module func imports. The
/// returned `JitBlock` starts in the writable state on the
/// current thread (Mac aarch64 W^X per-thread; Linux/Windows
/// RWX). Caller emits one thunk per slot via `emitInto`, then
/// publishes via `finalizeArena`.
///
/// `num_func_imports == 0` returns the empty-arena sentinel
/// (`bytes.len == 0`), matching `jit_mem`'s zero-length-block
/// invariant + `freeArena`'s no-op guard.
///
/// Mac aarch64 W^X is per-thread global, not per-block; if the
/// caller has just finished a JIT compile (which leaves the
/// thread in RX via `linker.JitModule.linkBlock`'s closing
/// `setExecutable`), the freshly-mapped MAP_JIT pages are
/// unwritable until this call's `setWritable` flips the
/// thread back to RW mode. Mirrors `linker.zig`'s pairing.
pub fn allocArena(num_func_imports: usize) jit_mem.Error!jit_mem.JitBlock {
    if (num_func_imports == 0) {
        return .{ .bytes = &[_:0]u8{} };
    }
    const block = try jit_mem.alloc(arenaBytes(num_func_imports));
    errdefer jit_mem.free(block);
    try jit_mem.setWritable(block);
    return block;
}

/// Free a thunk arena. Mirrors `jit_mem.free`'s zero-length
/// short-circuit (D-077 discharge) so callers can blindly pair
/// `allocArena` with `freeArena` regardless of whether the
/// instance had any cross-module imports.
pub fn freeArena(arena: jit_mem.JitBlock) void {
    jit_mem.free(arena);
}

/// Return the byte slice for thunk slot `idx` inside `arena`.
/// `idx` MUST be in `[0, num_func_imports)`; out-of-range is a
/// program error (asserted via `std.debug.assert`, identical to
/// `JitModule.entry`'s out-of-range check pattern). The
/// returned slice is exactly `thunk_bytes` long and aligned to
/// `arena.bytes.ptr + idx * thunk_bytes`.
///
/// **Lifetime**: the slice aliases the arena's mapping; do NOT
/// retain it past the arena's `freeArena`. Resolver code emits
/// directly into the returned slice via `emitThunk`.
pub fn thunkSlot(arena: jit_mem.JitBlock, idx: usize) []u8 {
    const start = idx * thunk_bytes;
    const end = start + thunk_bytes;
    std.debug.assert(end <= arena.bytes.len);
    return arena.bytes[start..end];
}

/// Publish the arena as executable on the current thread (Mac
/// aarch64: pthread_jit_write_protect_np + I-cache invalidate;
/// Linux/Windows: no-op since the pages were mapped RWX).
/// Mirrors `jit_mem.setExecutable` semantics; safe to call on
/// an empty arena (zero-length JitBlock is silently allowed
/// since no protection flip is needed).
pub fn finalizeArena(arena: jit_mem.JitBlock) jit_mem.Error!void {
    if (arena.bytes.len == 0) return;
    try jit_mem.setExecutable(arena);
}

/// Re-enter writable mode on the current thread so the resolver
/// (or a future re-link path) can patch thunk literals. Pair
/// strictly with `finalizeArena` — Mac aarch64's W^X toggle is
/// per-thread global state, not per-block. Safe no-op on an
/// empty arena.
pub fn unfinalizeArena(arena: jit_mem.JitBlock) jit_mem.Error!void {
    if (arena.bytes.len == 0) return;
    try jit_mem.setWritable(arena);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "thunk_bytes: matches arch-specific constant" {
    switch (builtin.target.cpu.arch) {
        .aarch64 => try testing.expectEqual(@as(usize, 120), thunk_bytes), // #381: 96→120 (trap relay)
        .x86_64 => try testing.expectEqual(@as(usize, 79), thunk_bytes), // D-238/ADR-0185 a: 27→40 (RBP frame-link); #381: 40→79 (entry clear + trap relay)
        else => unreachable,
    }
}

test "emitThunk: writes exactly thunk_bytes bytes (no over/under-fill)" {
    // Allocate one extra byte at each end pre-filled with a
    // sentinel; verify the emit doesn't touch either.
    const guard_byte: u8 = 0xAA;
    var buf: [thunk_bytes + 2]u8 = undefined;
    @memset(&buf, guard_byte);
    emitThunk(buf[1 .. 1 + thunk_bytes], 0x1234_5678_9ABC_DEF0, 0xFEDC_BA98_7654_3210);
    try testing.expectEqual(guard_byte, buf[0]);
    try testing.expectEqual(guard_byte, buf[buf.len - 1]);
}

test "emitThunk: distinct callee pairs produce distinct thunks" {
    var a: [thunk_bytes]u8 = undefined;
    var b: [thunk_bytes]u8 = undefined;
    emitThunk(&a, 0x1, 0x2);
    emitThunk(&b, 0x3, 0x4);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "arenaBytes: zero imports → 0; N imports → N * thunk_bytes" {
    try testing.expectEqual(@as(usize, 0), arenaBytes(0));
    try testing.expectEqual(thunk_bytes, arenaBytes(1));
    try testing.expectEqual(7 * thunk_bytes, arenaBytes(7));
}

test "allocArena / freeArena: zero imports → empty sentinel; free is no-op" {
    const arena = try allocArena(0);
    try testing.expectEqual(@as(usize, 0), arena.bytes.len);
    // Empty arena's free is no-op per jit_mem.free's
    // zero-length short-circuit (D-077 discharge).
    freeArena(arena);
}

test "allocArena / freeArena: 4 imports — arena page-rounded, ≥ 4*thunk_bytes" {
    const arena = try allocArena(4);
    defer freeArena(arena);
    try testing.expect(arena.bytes.len >= 4 * thunk_bytes);
}

test "thunkSlot: returns thunk_bytes-wide slice at correct offset" {
    const arena = try allocArena(3);
    defer freeArena(arena);
    const s0 = thunkSlot(arena, 0);
    const s1 = thunkSlot(arena, 1);
    const s2 = thunkSlot(arena, 2);
    try testing.expectEqual(thunk_bytes, s0.len);
    try testing.expectEqual(thunk_bytes, s1.len);
    try testing.expectEqual(thunk_bytes, s2.len);
    try testing.expectEqual(@intFromPtr(arena.bytes.ptr) + 0 * thunk_bytes, @intFromPtr(s0.ptr));
    try testing.expectEqual(@intFromPtr(arena.bytes.ptr) + 1 * thunk_bytes, @intFromPtr(s1.ptr));
    try testing.expectEqual(@intFromPtr(arena.bytes.ptr) + 2 * thunk_bytes, @intFromPtr(s2.ptr));
}

test "thunk arena lifecycle: emit → finalize → bytes readable; unfinalize → free" {
    // Allocate a 2-slot arena, emit two distinct thunks, publish
    // RX, then verify the bytes match what emitThunk would write
    // into a plain buffer. No execution — this test verifies the
    // arena lifecycle (alloc → write → finalize → free) without
    // depending on real instance/runtime pointers.
    const arena = try allocArena(2);
    defer freeArena(arena);

    // setWritable is required on Mac aarch64 W^X paths before
    // writing into a freshly-allocated MAP_JIT region; no-op on
    // Linux/Windows RWX paths.
    try unfinalizeArena(arena);

    const rt0: usize = 0xDEAD_BEEF_CAFE_BABE;
    const ep0: usize = 0x1234_5678_9ABC_DEF0;
    const rt1: usize = 0xAAAA_BBBB_CCCC_DDDD;
    const ep1: usize = 0xEEEE_FFFF_0000_1111;
    emitThunk(thunkSlot(arena, 0), rt0, ep0);
    emitThunk(thunkSlot(arena, 1), rt1, ep1);

    try finalizeArena(arena);

    // Compare against the same thunk bytes emitted into a plain
    // (non-RX) buffer — proves the arena's writable phase
    // captured the encoder's output without surprises (W^X
    // toggle / setExecutable cannot rewrite bytes; only flip
    // protection).
    var ref0: [thunk_bytes]u8 = undefined;
    var ref1: [thunk_bytes]u8 = undefined;
    emitThunk(&ref0, rt0, ep0);
    emitThunk(&ref1, rt1, ep1);

    // Toggle back to writable so we can readback compare. On Mac
    // aarch64 the page is RX after finalize; setWritable flips
    // back to RW. Linux/Windows are no-ops (page stays RWX).
    try unfinalizeArena(arena);
    try testing.expectEqualSlices(u8, &ref0, thunkSlot(arena, 0));
    try testing.expectEqualSlices(u8, &ref1, thunkSlot(arena, 1));
}
