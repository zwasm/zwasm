//! SysV/Win64 frame-chain read helper (ADR-0114 D6 / D5).
//!
//! Reads the caller's saved RBP + saved RIP out of an x86_64
//! frame prefix planted by the function prologue's
//! `PUSH RBP; MOV RBP, RSP`. Per System V AMD64 ABI §3.2.2 (and
//! the Win64 ABI's equivalent — both ABIs use RBP-chained
//! frames in this layout):
//!
//!   [RBP, #0] = caller's saved RBP
//!   [RBP, #8] = caller's saved RIP (the return address pushed
//!               by the CALL instruction)
//!
//! Mirror of `arm64/frame_chain.zig` (AAPCS64 `[X29, #0]` / `[X29, #8]`);
//! the trampoline composes both into a
//! `unwind.FrameChainLoader` per host via a PC-normalization callback.
//!
//! Unreadable frame pointer → null, which the unwinder reads as
//! "no more Wasm frames" (`.uncaught`). Two cases produce it:
//! `fp == 0`, the top-of-Wasm-stack sentinel the entry shim plants
//! so the unwinder terminates deterministically at the Wasm
//! boundary; and a non-zero `fp` that is not machine-word-aligned,
//! which cannot be a frame pointer at all (see `readableFrame`).
//!
//! INVARIANT (paired with ADR-0114 D5 + ADR-0112 D7): two
//! pointer-relative loads, no allocator calls, no host-call
//! invocations, no signal-check branches.
//!
//! Spec: System V AMD64 ABI §3.2.2.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");

/// One x86_64 frame prefix read. The trampoline converts
/// `caller_rip` (= the raw saved RIP, an absolute return address)
/// to a module-relative PC via the active function's code-map
/// lookup before calling `unwind.walk`.
pub const RawFrameLink = struct {
    caller_fp: usize,
    caller_rip: usize,
};

/// A frame prefix is only readable at a machine-word-aligned `fp`. `fp == 0` is
/// the entry shim's top-of-Wasm-stack sentinel; a non-zero misaligned `fp` is
/// not a frame pointer at all — the chain escaped into host frames and the
/// standard-layout default handed back whatever word sat in `slots[0]`.
/// Both mean "no caller frame this reader can trust": return null and let
/// `unwind.walk` report `.uncaught`. Dereferencing instead panics
/// ("incorrect alignment") in every safety-checked build.
inline fn readableFrame(fp: usize) bool {
    return fp != 0 and std.mem.isAligned(fp, @alignOf(usize));
}

/// Read the x86_64 frame prefix at `[fp, 0]` + `[fp, 8]`.
/// Returns null for the top-of-Wasm-stack sentinel (`fp == 0`).
pub fn loadFrame(fp: usize) ?RawFrameLink {
    if (!readableFrame(fp)) return null;
    const slots: [*]const usize = @ptrFromInt(fp);
    return .{
        .caller_fp = slots[0],
        .caller_rip = slots[1],
    };
}

/// D-184 — x86_64 prologue-aware sniffed frame read. The zwasm
/// JIT prologue is `PUSH RBP; PUSH R15; MOV RBP, RSP` when the
/// function uses_runtime_ptr (= EH ops, calls, memory ops, …
/// per `usage.usesRuntimePtr`). MOV RBP, RSP captures RBP AFTER
/// the R15 push, so `[RBP, 0] = saved R15`, `[RBP, 8] = saved
/// RBP`, `[RBP, 16] = saved RIP`. For non-uses_runtime_ptr
/// functions the prologue is just `PUSH RBP; MOV RBP, RSP`,
/// giving the standard SysV `[RBP, 0] = saved RBP`, `[RBP, 8] =
/// saved RIP` layout. The unwinder doesn't know per-frame which
/// layout applies, so it sniffs: if `[fp, 8]` resolves through
/// the CodeMap as a JIT body address (i.e., a saved RIP), the
/// function used standard SysV; if `[fp, 16]` resolves but
/// `[fp, 8]` does not, the function pushed R15 between RBP-save
/// and MOV. The check is unambiguous because saved-RBP / saved-
/// R15 are stack / heap addresses (never JIT-body); only the
/// saved-RIP at the correct slot resolves to `.inside`.
pub fn loadFrameSniffed(
    fp: usize,
    code_map: *const @import("../shared/code_map.zig").CodeMap,
) ?RawFrameLink {
    if (!readableFrame(fp)) return null;
    const slots: [*]const usize = @ptrFromInt(fp);
    // Sniff standard layout first (most caller frames in EH chain
    // do NOT push R15 between RBP-save and MOV; non-throwing
    // intermediate frames are uses_runtime_ptr=false often).
    switch (code_map.lookup(slots[1])) {
        .inside => return .{ .caller_fp = slots[0], .caller_rip = slots[1] },
        .outside => {},
    }
    switch (code_map.lookup(slots[2])) {
        .inside => return .{ .caller_fp = slots[1], .caller_rip = slots[2] },
        .outside => {},
    }
    // Neither slot is a JIT body address — frame chain has
    // escaped the JIT module (entry shim / host stack). Return
    // the slot0/slot1 default; the unwinder will see the
    // non-JIT caller_rip resolve to the `non_jit_pc_sentinel`
    // and either match a sentinel handler or step further into
    // host frames where `loadFrame` may return null (fp == 0)
    // or the heuristic may fail safely on the next iteration.
    return .{ .caller_fp = slots[0], .caller_rip = slots[1] };
}

/// Predicate-based variant of `loadFrameSniffed` (D-238 / ADR-0185 (c)).
/// Identical layout disambiguation, but instead of a SINGLE CodeMap it asks
/// `is_code(addr)` = "is this a valid JIT code address ANYWHERE" (any
/// instance's CodeMap OR any registered bridge-thunk arena). A cross-instance
/// EH unwind walks frames belonging to OTHER instances + the importer's bridge
/// thunk, whose saved-RIP addresses are not in the throwing instance's
/// CodeMap; a single-CodeMap sniff resolves them `.outside` and mis-walks (the
/// callee→thunk transition specifically). The production predicate is
/// `eh_registry.isCodeAddr`; the standard-layout slot (`[fp,8]`) is checked
/// first (most intermediate frames don't push R15), then the R15-pushed slot
/// (`[fp,16]`); neither → the standard default (correct for a standard frame,
/// e.g. the RBP-framed bridge thunk itself).
pub fn loadFrameSniffedPred(
    fp: usize,
    local_code_map: ?*const @import("../shared/code_map.zig").CodeMap,
    is_code: *const fn (usize) bool,
) ?RawFrameLink {
    if (!readableFrame(fp)) return null;
    const slots: [*]const usize = @ptrFromInt(fp);
    // Code membership = the THROWING instance's own CodeMap (always available
    // via the adapter's normalize_ctx, even for a single instance NOT
    // registered in eh_registry — e.g. the edge runner) UNION the global
    // predicate (other registered instances + bridge-thunk arenas). The
    // union is load-bearing: a bare global predicate returns false for an
    // unregistered single instance, so the sniff would mis-resolve the
    // layout and walk into a garbage caller_fp (D-238 regression, caught on
    // the x86_64 ubuntu gate — the single-CodeMap sniff this replaced always
    // saw the thrower's CodeMap).
    if (isCodeUnion(local_code_map, is_code, slots[1])) return .{ .caller_fp = slots[0], .caller_rip = slots[1] };
    if (isCodeUnion(local_code_map, is_code, slots[2])) return .{ .caller_fp = slots[1], .caller_rip = slots[2] };
    return .{ .caller_fp = slots[0], .caller_rip = slots[1] };
}

inline fn isCodeUnion(
    local_code_map: ?*const @import("../shared/code_map.zig").CodeMap,
    is_code: *const fn (usize) bool,
    addr: usize,
) bool {
    if (local_code_map) |cm| switch (cm.lookup(addr)) {
        .inside => return true,
        .outside => {},
    };
    return is_code(addr);
}

// ---------------------------------------------------------------------
// Unit tests — pure pointer read; synthetic frame planted in test
// memory. No JIT emit / no actual stack walk required.
// ---------------------------------------------------------------------

const testing = std.testing;

test "loadFrame x86_64: fp == 0 sentinel → null (top-of-stack)" {
    try testing.expectEqual(@as(?RawFrameLink, null), loadFrame(0));
}

test "loadFrame x86_64: reads [fp, 0] as caller_fp and [fp, 8] as caller_rip" {
    var frame: [2]usize = .{ 0xDEADBEEFCAFE, 0xFEEDFACE0001 };
    const fp: usize = @intFromPtr(&frame);

    const link = loadFrame(fp).?;
    try testing.expectEqual(@as(usize, 0xDEADBEEFCAFE), link.caller_fp);
    try testing.expectEqual(@as(usize, 0xFEEDFACE0001), link.caller_rip);
}

test "loadFrame x86_64: caller_fp == 0 propagates (next walk step would terminate)" {
    var frame: [2]usize = .{ 0, 0xAAAA1234 };
    const fp: usize = @intFromPtr(&frame);

    const link = loadFrame(fp).?;
    try testing.expectEqual(@as(usize, 0), link.caller_fp);
    try testing.expectEqual(@as(usize, 0xAAAA1234), link.caller_rip);
}

test "loadFrame x86_64: chained read — outer frame reachable via inner's caller_fp" {
    var outer: [2]usize = .{ 0, 0x1111 };
    var inner: [2]usize = .{ @intFromPtr(&outer), 0x2222 };
    const inner_fp: usize = @intFromPtr(&inner);

    const inner_link = loadFrame(inner_fp).?;
    try testing.expectEqual(@intFromPtr(&outer), inner_link.caller_fp);
    try testing.expectEqual(@as(usize, 0x2222), inner_link.caller_rip);

    const outer_link = loadFrame(inner_link.caller_fp).?;
    try testing.expectEqual(@as(usize, 0), outer_link.caller_fp);
    try testing.expectEqual(@as(usize, 0x1111), outer_link.caller_rip);
}

/// Test predicate: "code" = the synthetic JIT/thunk range [0x50000, 0x50100).
/// Stack-slot values in the tests live far outside it (high addresses), so the
/// predicate cleanly separates a saved-RIP slot from saved-RBP/saved-R15.
fn testIsCode5xxxx(addr: usize) bool {
    return addr >= 0x50000 and addr < 0x50100;
}

test "loadFrameSniffedPred x86_64: standard layout — saved RIP at [fp,8]" {
    // `PUSH RBP; MOV RBP,RSP` frame: [fp,0]=saved RBP (stack), [fp,8]=saved RIP
    // (code). The bridge thunk itself is this shape (ADR-0185 a).
    var frame: [3]usize = .{ 0x7FFF_0000_0000, 0x50040, 0xDEAD };
    const fp: usize = @intFromPtr(&frame);
    const link = loadFrameSniffedPred(fp, null, testIsCode5xxxx).?;
    try testing.expectEqual(@as(usize, 0x7FFF_0000_0000), link.caller_fp);
    try testing.expectEqual(@as(usize, 0x50040), link.caller_rip);
}

test "loadFrameSniffedPred x86_64: R15-pushed callee — saved RIP at [fp,16] (the D-238 case)" {
    // uses_runtime_ptr `PUSH RBP; PUSH R15; MOV RBP,RSP` frame:
    // [fp,0]=saved R15 (stack), [fp,8]=saved RBP (stack), [fp,16]=saved RIP =
    // a bridge-thunk return address (code). The standard slot [fp,8] is a stack
    // address (NOT code), so the sniff must fall through to [fp,16]. A single
    // throwing-instance CodeMap would resolve the thunk RIP `.outside` and
    // mis-pick [fp,0]/[fp,8]; the global predicate fixes it.
    var frame: [3]usize = .{ 0x7FFF_1111_0000, 0x7FFF_2222_0000, 0x50080 };
    const fp: usize = @intFromPtr(&frame);
    const link = loadFrameSniffedPred(fp, null, testIsCode5xxxx).?;
    try testing.expectEqual(@as(usize, 0x7FFF_2222_0000), link.caller_fp); // [fp,8]
    try testing.expectEqual(@as(usize, 0x50080), link.caller_rip); // [fp,16]
}

test "loadFrameSniffedPred x86_64: no code slot — escaped to host, standard default" {
    // Neither candidate slot is code (frame chain escaped into host stack).
    // Falls back to the standard {slots[0], slots[1]} default.
    var frame: [3]usize = .{ 0xAAAA, 0xBBBB, 0xCCCC };
    const fp: usize = @intFromPtr(&frame);
    const link = loadFrameSniffedPred(fp, null, testIsCode5xxxx).?;
    try testing.expectEqual(@as(usize, 0xAAAA), link.caller_fp);
    try testing.expectEqual(@as(usize, 0xBBBB), link.caller_rip);
}

test "loadFrameSniffedPred x86_64: fp == 0 sentinel → null" {
    try testing.expectEqual(@as(?RawFrameLink, null), loadFrameSniffedPred(0, null, testIsCode5xxxx));
}

/// A predicate that NEVER claims an address — models the global eh_registry
/// being EMPTY (a single, unregistered throwing instance, e.g. the edge-runner).
fn testIsCodeNever(addr: usize) bool {
    _ = addr;
    return false;
}

test "loadFrameSniffedPred x86_64: local CodeMap resolves a single UNREGISTERED instance (regression for 808090f2 SEGV)" {
    // The exact shape that SEGV'd: slice 2b's predicate REPLACED the local
    // CodeMap, so a single throwing instance not in eh_registry (empty global
    // predicate) could not disambiguate the R15-pushed layout → it mis-picked
    // the standard slot, returned a garbage caller_fp, and the next walk step
    // SEGV'd reading slots[1]. The fix UNIONs the local CodeMap (always present
    // via normalize_ctx) with the global predicate. Here the global predicate
    // is NEVER true, yet the saved RIP at [fp,16] lives in the local map, so the
    // R15-pushed layout must still resolve. A revert to pure-predicate fails here
    // BEFORE the x86_64 ubuntu integration run would.
    const code_map_mod = @import("../shared/code_map.zig");
    var entries = [_]code_map_mod.Entry{.{ .start_addr = 0x50000, .len = 0x100, .func_idx = 0 }};
    const cm = code_map_mod.CodeMap{ .entries = &entries };
    // R15-pushed frame: [fp,16]=saved RIP=0x50080 ∈ the LOCAL map (∉ the global).
    var frame: [3]usize = .{ 0x7FFF_1111_0000, 0x7FFF_2222_0000, 0x50080 };
    const fp: usize = @intFromPtr(&frame);
    const link = loadFrameSniffedPred(fp, &cm, testIsCodeNever).?;
    try testing.expectEqual(@as(usize, 0x7FFF_2222_0000), link.caller_fp); // [fp,8]
    try testing.expectEqual(@as(usize, 0x50080), link.caller_rip); // [fp,16]
}

test "loadFrameSniffedPred x86_64: union prefers EITHER source — global-only still resolves" {
    // Symmetric half: a frame whose saved RIP is in the GLOBAL predicate but NOT
    // the local CodeMap (the cross-instance case — another instance's frame or a
    // bridge thunk). The union must resolve it via the global predicate even with
    // a non-null local map that does not contain the address.
    const code_map_mod = @import("../shared/code_map.zig");
    var entries = [_]code_map_mod.Entry{.{ .start_addr = 0x10000, .len = 0x100, .func_idx = 0 }};
    const cm = code_map_mod.CodeMap{ .entries = &entries }; // does NOT cover 0x50xxx
    var frame: [3]usize = .{ 0x7FFF_1111_0000, 0x7FFF_2222_0000, 0x50080 };
    const fp: usize = @intFromPtr(&frame);
    const link = loadFrameSniffedPred(fp, &cm, testIsCode5xxxx).?; // 0x50080 ∈ global
    try testing.expectEqual(@as(usize, 0x7FFF_2222_0000), link.caller_fp);
    try testing.expectEqual(@as(usize, 0x50080), link.caller_rip);
}

// ---------------------------------------------------------------------
// #323 — an unaligned `fp` is not a frame pointer. It is reached when the
// chain escapes into optimized host frames: the sniff finds code at neither
// candidate slot and hands back the standard-layout default, whose `slots[0]`
// is then whatever word that host frame happened to hold. Dereferencing it
// panics ("incorrect alignment") in every safety-checked build. Each reader
// must decline it exactly as it declines the `fp == 0` sentinel — null, which
// `unwind.walk` turns into `.uncaught`.
//
// The loops cover every misalignment 1..7, not just +1: a guard written
// against a narrower alignment (`fp & 1`, `fp & 3`) would let +2 / +4 through
// and re-open the panic.
// ---------------------------------------------------------------------

test "loadFrame x86_64: unaligned fp → null (never dereferenced)" {
    var frame: [3]usize = .{ 0xAAAA, 0xBBBB, 0xCCCC };
    const aligned_fp: usize = @intFromPtr(&frame);
    for (1..@alignOf(usize)) |off| {
        try testing.expectEqual(@as(?RawFrameLink, null), loadFrame(aligned_fp + off));
    }
}

test "loadFrameSniffed x86_64: unaligned fp → null (never dereferenced)" {
    const code_map_mod = @import("../shared/code_map.zig");
    var entries = [_]code_map_mod.Entry{.{ .start_addr = 0x50000, .len = 0x100, .func_idx = 0 }};
    const cm = code_map_mod.CodeMap{ .entries = &entries };
    var frame: [3]usize = .{ 0x7FFF_1111_0000, 0x7FFF_2222_0000, 0x50080 };
    const aligned_fp: usize = @intFromPtr(&frame);
    for (1..@alignOf(usize)) |off| {
        try testing.expectEqual(@as(?RawFrameLink, null), loadFrameSniffed(aligned_fp + off, &cm));
    }
}

test "loadFrameSniffedPred x86_64: unaligned fp → null (the #323 panic site)" {
    // The stack trace in #323 names this function: engine.runner_test's two JIT
    // EH end-to-end cases walk out of the JIT into the ReleaseSafe-optimized
    // unit-test harness frames, and the next `caller_fp` comes back unaligned.
    var frame: [3]usize = .{ 0x7FFF_1111_0000, 0x7FFF_2222_0000, 0x50080 };
    const aligned_fp: usize = @intFromPtr(&frame);
    for (1..@alignOf(usize)) |off| {
        try testing.expectEqual(
            @as(?RawFrameLink, null),
            loadFrameSniffedPred(aligned_fp + off, null, testIsCode5xxxx),
        );
    }
}
