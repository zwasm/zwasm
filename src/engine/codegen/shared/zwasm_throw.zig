//! `zwasm_throw` trampoline Zig dispatcher (ADR-0114 D6).
//!
//! The JIT-emitted `throw` / `throw_ref` op marshals its
//! throw-site context (caller's FP, saved LR/RIP = absolute
//! throw-site address, tag_idx) and calls `dispatchThrow`.
//! This function:
//!
//!   (1) Normalises the absolute throw-site address through the
//!       per-Instance `CodeMap` → module-relative initial PC.
//!   (2) Builds the `frame_chain_adapter.Context` pinning the
//!       code map as the PC-normalizer for subsequent frames.
//!   (3) Invokes `unwind.walk(table, tag_idx, initial_pc,
//!       initial_fp, loader, max_depth)`.
//!   (4) Returns the `UnwindResult` to the caller (the assembly
//!       glue / op_exception_handling.zig layer) which then
//!       branches on `.handler` (restore SP to handler_fp +
//!       jump to landing_pad_pc) or `.uncaught` (trap_flag=1 +
//!       return 0 to the entry shim).
//!
//! INVARIANT (paired with ADR-0114 D5/D6 + ADR-0112 D7): the
//! dispatcher itself performs only the four steps above — no
//! allocator calls, no host-call invocations, no signal-check
//! branches between entry and `.handler` / `.uncaught` return.
//!
//! The arch-specific entry/exit glue handles the
//! assembly-level details: extracting
//! X29 / RBP, fetching the saved LR / RIP, building the
//! `ThrowSite` record, calling this function, and consuming
//! the result to either restore SP + JMP or to set trap_flag.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

const exception_table = @import("exception_table.zig");
const code_map_mod = @import("code_map.zig");
const frame_chain_adapter = @import("frame_chain_adapter.zig");
const unwind = @import("unwind.zig");

pub const ExceptionTable = exception_table.ExceptionTable;
pub const CodeMap = code_map_mod.CodeMap;
pub const UnwindResult = unwind.UnwindResult;
pub const HandlerLanding = unwind.HandlerLanding;

/// Throw-site state captured by the arch-specific entry/exit
/// glue. `initial_fp` is the caller's X29 (AAPCS64) / RBP
/// (SysV/Win64); `throw_site_addr` is the absolute address of
/// the throw instruction (the saved LR / RIP at the throw
/// site's CALL boundary).
pub const ThrowSite = struct {
    initial_fp: usize,
    throw_site_addr: usize,
    tag_idx: u32,
    /// The thrown tag's identity, when `tag_idx` cannot name it: a `throw_ref`
    /// of an exnref whose tag the rethrowing module does not declare has no
    /// local index (#426 review). `null` = derive it from `tag_idx`.
    tag_id: ?u64 = null,
};

/// Default max unwind depth — Phase 10 cap on the Wasm call
/// stack. The Runtime can override at instantiate time
/// (Phase 11+ wiring); the trampoline picks the live value
/// before calling here.
pub const default_max_unwind_depth: u32 = 4096;

/// Dispatch a `throw` / `throw_ref` through the full FP-walk
/// unwind pipeline.
///
/// `table` and `code_map` are per-Runtime — the assembly glue
/// loads them from the Runtime pointer (X19 / R15) before
/// calling here.
///
/// Returns the `UnwindResult` for the caller to act on. On
/// `.handler`, the caller restores SP to `handler_fp`'s
/// prologue boundary (per ADR-0114 D6) and jumps to
/// `landing_pad_pc`. On `.uncaught`, the caller writes
/// `trap_flag=1` to the Runtime (existing bounds_fixup trap
/// shape) and returns 0 to the entry shim.
pub fn dispatchThrow(
    table: ExceptionTable,
    code_map: *const CodeMap,
    site: ThrowSite,
    max_unwind_depth: u32,
    resolver: ?unwind.InstanceResolver,
    /// x86_64 cross-instance code-membership predicate (D-238 / ADR-0185 (c));
    /// `eh_registry.isCodeAddr` in production, `null` in unit tests (→ legacy
    /// single-CodeMap sniff). arm64 ignores it (no sniff).
    is_code_addr: ?*const fn (usize) bool,
) UnwindResult {
    // (1) Normalise the throw-site absolute address to a
    // module-relative PC (= absolute - block_addr) to match
    // `collectModuleTable`'s pc_start/pc_end shift convention.
    // See `code_map.toModuleRelativePc` for the rationale +
    // sentinel semantics (D-183/D-184).
    const initial_pc = code_map_mod.toModuleRelativePc(code_map, site.throw_site_addr);

    // (2) Build the adapter context. The code_map serves both
    // as the initial-PC normaliser (above) and the per-frame
    // PC normaliser (here).
    var ctx = code_map_mod.adapterContextFor(code_map);
    ctx.is_code_addr = is_code_addr;
    const loader = frame_chain_adapter.loaderFor(&ctx);

    // (3) Walk. `throw_site_addr` is the absolute address of the
    // throw instruction; the walker carries it (or each frame's
    // raw saved LR/RIP) through so the handler-match step can
    // return `handler_abs_pc` for the trampoline's CodeMap.Entry
    // lookup (start_addr + frame_bytes).
    return unwind.walk(
        table,
        site.tag_idx,
        initial_pc,
        site.throw_site_addr,
        site.initial_fp,
        loader,
        max_unwind_depth,
        resolver,
        site.tag_id,
    );
}

// ---------------------------------------------------------------------
// Unit tests — end-to-end dispatch through the full pipeline:
// CodeMap + ExceptionTable + synthetic frame chain.
// ---------------------------------------------------------------------

const testing = std.testing;
const Builder = exception_table.Builder;
const CodeBuilder = code_map_mod.Builder;

test "dispatchThrow: throw-site address inside a function → handler in same frame" {
    // Build a code map: one function at address 0x10000, length 0x100.
    var cb: CodeBuilder = .empty;
    defer cb.deinit(testing.allocator);
    try cb.add(testing.allocator, .{ .start_addr = 0x10000, .len = 0x100, .func_idx = 0 });
    const cmap = cb.finalize();

    // Build an exception table: PC range [0, 0x100) catches tag=5 → landing 0x80.
    var eb: Builder = .empty;
    defer eb.deinit(testing.allocator);
    try eb.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 0x100,
        .tag_idx = 5,
        .landing_pad_pc = 0x80,
        .kind = .catch_,
    });
    const table = eb.finalize();

    // Throw at absolute address 0x10042 (relative PC 0x42).
    // Initial FP is irrelevant — handler hits in the same frame.
    const site: ThrowSite = .{
        .initial_fp = 999, // unused since handler is found before walk
        .throw_site_addr = 0x10042,
        .tag_idx = 5,
    };
    const result = dispatchThrow(table, &cmap, site, 16, null, null);

    switch (result) {
        .handler => |h| {
            try testing.expectEqual(@as(u32, 0x80), h.landing_pad_pc);
            try testing.expectEqual(@as(usize, 999), h.handler_fp);
            try testing.expectEqual(exception_table.CatchKind.catch_, h.kind);
        },
        .uncaught => try testing.expect(false),
    }
}

test "dispatchThrow: no matching handler → uncaught" {
    var cb: CodeBuilder = .empty;
    defer cb.deinit(testing.allocator);
    try cb.add(testing.allocator, .{ .start_addr = 0x20000, .len = 0x100, .func_idx = 0 });
    const cmap = cb.finalize();

    // Empty table — no handlers anywhere.
    var eb: Builder = .empty;
    defer eb.deinit(testing.allocator);
    const table = eb.finalize();

    // 1-frame chain: caller at fp=1 is top-of-stack.
    var outer: [2]usize = .{ 0, 0 };
    const initial_fp: usize = @intFromPtr(&outer);
    const site: ThrowSite = .{
        .initial_fp = initial_fp,
        .throw_site_addr = 0x20050,
        .tag_idx = 99,
    };
    const result = dispatchThrow(table, &cmap, site, 16, null, null);
    try testing.expectEqual(UnwindResult.uncaught, result);
}

test "dispatchThrow: handler in caller frame after one unwind step" {
    // Two functions in the code map. The CodeMap's first entry
    // defines `block_addr` (the JitBlock base) — both functions
    // are addressed relative to it for the unwinder's
    // module-relative PC convention (D-183 fix; see
    // `code_map.normalizeForUnwind` + `dispatchThrow`'s
    // initial_pc computation).
    //   f0: [0x10000, 0x10100)  — throw site here; block_addr =
    //                              0x10000 since f0 is first.
    //   f1: [0x20000, 0x20100)  — handler frame here (caller);
    //                              module-relative range is
    //                              [0x10000, 0x10100) =
    //                              0x20000 - 0x10000.
    var cb: CodeBuilder = .empty;
    defer cb.deinit(testing.allocator);
    try cb.add(testing.allocator, .{ .start_addr = 0x10000, .len = 0x100, .func_idx = 0 });
    try cb.add(testing.allocator, .{ .start_addr = 0x20000, .len = 0x100, .func_idx = 1 });
    const cmap = cb.finalize();

    // HandlerEntries are MODULE-relative (post-collectModuleTable
    // shift). f1's entry sits at module-relative offset
    // 0x20000 - 0x10000 = 0x10000 onwards. The inner range
    // matches f0's body (tag 7 — throw of tag 5 misses); the
    // outer range covers f1's [0x10050, 0x10100) which the
    // walker hits after one frame step (saved LR 0x20070 → mod
    // 0x10070 ∈ [0x10050, 0x10100)).
    var eb3: Builder = .empty;
    defer eb3.deinit(testing.allocator);
    try eb3.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 0x50,
        .tag_idx = 7,
        .landing_pad_pc = 0x10,
        .kind = .catch_,
    });
    try eb3.add(testing.allocator, .{
        .pc_start = 0x10050,
        .pc_end = 0x10100,
        .tag_idx = null,
        .landing_pad_pc = 0x90,
        .kind = .catch_all,
    });
    const table3 = eb3.finalize();

    // Build the frame chain. AAPCS64 `[X29, #8]` = caller's saved LR
    // = the return address into the *caller* (per arm64/frame_chain.zig
    // §6.4). So inner.saved_lr holds outer's resumption PC, NOT inner's
    // own PC. Outer is top-of-stack: outer.saved_fp=0 terminates the walk.
    //
    //   outer frame (f1, top of stack): saved_fp=0, saved_lr unused.
    //   inner frame (f0, throw site):   saved_fp=&outer,
    //                                   saved_lr=0x20070 (= rel PC 0x70
    //                                   in f1's [0x50, 0x100) catch_all).
    var outer: [2]usize = .{ 0, 0 };
    var inner: [2]usize = .{ @intFromPtr(&outer), 0x20070 };
    const inner_fp: usize = @intFromPtr(&inner);

    const site: ThrowSite = .{
        .initial_fp = inner_fp,
        .throw_site_addr = 0x10042, // rel pc 0x42, in inner's [0, 0x50) catch tag=7
        .tag_idx = 5, // not 7 → miss
    };
    const result = dispatchThrow(table3, &cmap, site, 16, null, null);
    switch (result) {
        .handler => |h| {
            try testing.expectEqual(@as(u32, 0x90), h.landing_pad_pc);
            try testing.expectEqual(@intFromPtr(&outer), h.handler_fp);
            try testing.expectEqual(exception_table.CatchKind.catch_all, h.kind);
        },
        .uncaught => try testing.expect(false),
    }
}

test "dispatchThrow: throw-site outside any JIT function → walks via sentinel" {
    var cb: CodeBuilder = .empty;
    defer cb.deinit(testing.allocator);
    try cb.add(testing.allocator, .{ .start_addr = 0x30000, .len = 0x100, .func_idx = 0 });
    const cmap = cb.finalize();

    var eb: Builder = .empty;
    defer eb.deinit(testing.allocator);
    // Catch in the same JIT function. relative PC for caller frame.
    try eb.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 0x100,
        .tag_idx = null,
        .landing_pad_pc = 0x42,
        .kind = .catch_all,
    });
    const table = eb.finalize();

    // 2-frame chain. Inner frame's throw is from a non-JIT address (host code).
    // Outer is top-of-stack. Per AAPCS64 §6.4, inner.saved_lr is the
    // return address into the *caller* (= outer's JIT PC 0x30050, rel 0x50).
    var outer: [2]usize = .{ 0, 0 };
    var inner: [2]usize = .{ @intFromPtr(&outer), 0x30050 };
    const inner_fp: usize = @intFromPtr(&inner);

    const site: ThrowSite = .{
        .initial_fp = inner_fp,
        .throw_site_addr = 0xFFFFFFFF, // not in any JIT function
        .tag_idx = 1,
    };
    // The initial lookup falls through (PC = sentinel maxInt32, no entry covers it),
    // walker advances to outer frame at rel pc 0x50, catch_all hits.
    const result = dispatchThrow(table, &cmap, site, 16, null, null);
    switch (result) {
        .handler => |h| {
            try testing.expectEqual(@as(u32, 0x42), h.landing_pad_pc);
            try testing.expectEqual(@intFromPtr(&outer), h.handler_fp);
        },
        .uncaught => try testing.expect(false),
    }
}
