//! Frame-chain adapter — bridges per-arch `frame_chain.zig`
//! readers to the shared `unwind.FrameChainLoader` interface
//! (ADR-0114 D5/D6).
//!
//! The per-arch `frame_chain.zig` files return `RawFrameLink`
//! with the saved return-address as an **absolute** address
//! (`caller_lr` on AAPCS64 / `caller_rip` on SysV/Win64). The
//! shared unwinder consumes a **module-relative** PC for
//! `ExceptionTable.lookup`. This adapter holds the
//! PC-normalization callback that translates absolute return
//! address → module-relative PC via the active per-function
//! code-map.
//!
//! Dispatch by `builtin.target.cpu.arch` (mirrors
//! `shared/frame_teardown.zig` + `shared/thunk.zig` pattern):
//! one `loadFrameLink` fn covers both arches; the adapter
//! constructs a `unwind.FrameChainLoader` that the trampoline
//! passes to `unwind.walk`.
//!
//! Zone 2 (`src/engine/codegen/shared/`). The trampoline
//! consumes this adapter as one of its inputs.

const std = @import("std");
const builtin = @import("builtin");

const unwind = @import("unwind.zig");

const arch_frame_chain = switch (builtin.target.cpu.arch) {
    .aarch64 => @import("../arm64/frame_chain.zig"),
    .x86_64 => @import("../x86_64/frame_chain.zig"),
    else => @compileError("frame_chain_adapter not implemented for this architecture"),
};

/// Translate a raw absolute return-address (saved LR on AAPCS64
/// / saved RIP on SysV/Win64) into a module-relative PC for
/// `ExceptionTable.lookup`. The trampoline supplies the real
/// per-function code-map walker; the test driver supplies a
/// pure-function variant.
pub const NormalizePcFn = *const fn (ret_addr: usize, ctx: ?*anyopaque) u32;

/// Per-unwind context bundling the PC-normalizer + its closure.
/// Lives on the trampoline's stack frame; lifetime is bounded
/// by `unwind.walk`'s return.
pub const Context = struct {
    normalize: NormalizePcFn,
    normalize_ctx: ?*anyopaque = null,
    /// x86_64-only (D-238 / ADR-0185 (c)): a global "is this address valid
    /// JIT code anywhere" predicate (any instance's CodeMap OR any bridge-thunk
    /// arena, = `eh_registry.isCodeAddr`). When set, the x86_64 frame sniff uses
    /// it instead of the single throwing-instance `normalize_ctx` CodeMap — a
    /// cross-instance unwind walks frames in OTHER instances + the importer's
    /// bridge thunk, which the single CodeMap cannot resolve. Null → legacy
    /// single-CodeMap sniff (unit tests + arm64, which ignores it entirely).
    /// Separate field from `normalize_ctx` by design (two distinct axes:
    /// PC-normalization base vs. layout-disambiguation code-membership).
    is_code_addr: ?*const fn (usize) bool = null,
};

/// Implementation of `unwind.LoadFrameChainFn` parameterised on
/// the active arch's `frame_chain.loadFrame`. The `ctx` arg
/// MUST be a `*const Context` pointing at the live closure.
pub fn loadFrameLink(fp: usize, ctx: ?*anyopaque) ?unwind.FrameLink {
    const adapter_ctx: *const Context = @ptrCast(@alignCast(ctx.?));
    // D-184 — x86_64 uses a prologue-aware sniffed read because
    // the zwasm uses_runtime_ptr prologue (`PUSH RBP; PUSH R15;
    // MOV RBP, RSP`) lands RBP at saved-R15, not saved-RBP. arm64
    // uses the standard `STP X29, X30; MOV X29, SP` shape — no
    // sniff needed.
    const raw = switch (builtin.target.cpu.arch) {
        .aarch64 => arch_frame_chain.loadFrame(fp) orelse return null,
        .x86_64 => blk: {
            // D-238 / ADR-0185 (c): cross-instance unwind needs the GLOBAL
            // code-membership predicate (any instance's CodeMap OR any
            // bridge-thunk arena), not the single throwing-instance CodeMap —
            // else the callee→thunk transition (and any importer-instance
            // frame) mis-walks. Production sets `is_code_addr`; prefer it.
            if (adapter_ctx.is_code_addr) |pred| {
                // Union the throwing instance's local CodeMap (normalize_ctx,
                // always present in production even for a single unregistered
                // instance) with the global predicate — see loadFrameSniffedPred.
                const code_map_mod = @import("code_map.zig");
                const local_cm: ?*const code_map_mod.CodeMap = if (adapter_ctx.normalize_ctx) |p|
                    @ptrCast(@alignCast(p))
                else
                    null;
                break :blk arch_frame_chain.loadFrameSniffedPred(fp, local_cm, pred) orelse return null;
            }
            // Legacy single-CodeMap sniff (the production path's
            // `code_map.adapterContextFor` sets `normalize_ctx` to the CodeMap
            // pointer). Unit tests with a null `normalize_ctx` fall back to the
            // plain `loadFrame` shape (their synthetic frames don't model the
            // zwasm uses_runtime_ptr layout).
            if (adapter_ctx.normalize_ctx) |ctx_ptr| {
                const code_map_mod = @import("code_map.zig");
                const code_map: *const code_map_mod.CodeMap = @ptrCast(@alignCast(ctx_ptr));
                break :blk arch_frame_chain.loadFrameSniffed(fp, code_map) orelse return null;
            }
            break :blk arch_frame_chain.loadFrame(fp) orelse return null;
        },
        else => unreachable,
    };
    const ret_addr = switch (builtin.target.cpu.arch) {
        .aarch64 => raw.caller_lr,
        .x86_64 => raw.caller_rip,
        else => unreachable,
    };
    // D-183: subtract 1 from the saved return address before
    // normalising for `ExceptionTable.lookup`. The saved LR/RIP
    // points to the instruction AFTER the CALL/BL — when the
    // CALL is the last instruction in a try_table body, the
    // unadjusted ret_addr lands at `pc_end` (half-open) and
    // would reject the match. DWARF / libunwind / wasmtime /
    // WAMR convention is to subtract 1 so the lookup lands at
    // the prior instruction's byte. The lookup is just an
    // in-range check (no decode of the underlying bytes), so
    // subtracting 1 is safe — the result still lies within
    // the CALL/BL instruction's byte range.
    const lookup_addr = ret_addr -% 1;
    return .{
        .caller_fp = raw.caller_fp,
        .caller_pc = adapter_ctx.normalize(lookup_addr, adapter_ctx.normalize_ctx),
        .caller_abs_pc = lookup_addr,
    };
}

/// Convenience constructor — builds a `unwind.FrameChainLoader`
/// from a `*const Context`. The trampoline calls this once per
/// unwind and passes the result to `unwind.walk`.
pub fn loaderFor(ctx: *const Context) unwind.FrameChainLoader {
    return .{
        .load = loadFrameLink,
        .ctx = @ptrCast(@constCast(ctx)),
    };
}

// ---------------------------------------------------------------------
// Unit tests — end-to-end integration: synthetic frame chain +
// identity PC normalizer + unwind.walk → handler hit.
// ---------------------------------------------------------------------

const testing = std.testing;
const exception_table = @import("exception_table.zig");

/// Identity-truncation PC normalizer: treats the low 32 bits of
/// the absolute return address as the module-relative PC. Used
/// by the test driver only; the real trampoline uses a per-
/// function code-map walker.
fn identityTruncate(ret_addr: usize, ctx: ?*anyopaque) u32 {
    _ = ctx;
    return @truncate(ret_addr);
}

test "frame_chain_adapter: loadFrameLink reads raw frame + normalizes PC via callback" {
    // Synthetic 2-slot frame prefix: caller_fp = 0xDEAD, caller_ret = 0xBEEF1234.
    // D-183: the adapter subtracts 1 from the saved return
    // address before normalising (DWARF convention; lands the
    // lookup at the prior instruction's byte). caller_pc =
    // truncate(ret_addr - 1) = 0xBEEF1233.
    var frame: [2]usize = .{ 0xDEAD, 0xBEEF1234 };
    const fp: usize = @intFromPtr(&frame);

    const ctx: Context = .{ .normalize = identityTruncate };
    const link = loadFrameLink(fp, @ptrCast(@constCast(&ctx))).?;
    try testing.expectEqual(@as(usize, 0xDEAD), link.caller_fp);
    try testing.expectEqual(@as(u32, 0xBEEF1233), link.caller_pc);
}

test "frame_chain_adapter: loadFrameLink returns null for fp == 0 sentinel" {
    const ctx: Context = .{ .normalize = identityTruncate };
    try testing.expectEqual(@as(?unwind.FrameLink, null), loadFrameLink(0, @ptrCast(@constCast(&ctx))));
}

test "frame_chain_adapter: end-to-end walk — synthetic frame chain → handler hit" {
    // Build exception table: PC range [0, 100) catches tag=5 → landing 200.
    var b: exception_table.Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = 5,
        .landing_pad_pc = 200,
        .kind = .catch_,
    });
    const t = b.finalize();

    // Synthetic 2-frame chain:
    //   inner frame's prefix at &inner: caller_fp = &outer, caller_ret = 0x00000050 (= PC 50 after truncate).
    //   outer frame's prefix at &outer: caller_fp = 0 (top), caller_ret = 0.
    // Initial throw site at inner's PC = 9999 (out of any try_table range).
    // Walk: inner miss → step to outer at PC 50 → hit catch_ tag 5 → landing 200.
    var outer: [2]usize = .{ 0, 0 };
    var inner: [2]usize = .{ @intFromPtr(&outer), 0x00000050 };
    const inner_fp: usize = @intFromPtr(&inner);

    const ctx: Context = .{ .normalize = identityTruncate };
    const loader = loaderFor(&ctx);
    const result = unwind.walk(t, 5, 9999, 0xDEAD0000 | 9999, inner_fp, loader, 16, null, null);

    switch (result) {
        .handler => |h| {
            try testing.expectEqual(@as(u32, 200), h.landing_pad_pc);
            try testing.expectEqual(@intFromPtr(&outer), h.handler_fp);
            try testing.expectEqual(exception_table.CatchKind.catch_, h.kind);
        },
        .uncaught => try testing.expect(false),
    }
}

test "frame_chain_adapter: end-to-end walk — uncaught after exhausting frame chain" {
    // Empty exception table: every frame falls through.
    var b: exception_table.Builder = .empty;
    defer b.deinit(testing.allocator);
    const t = b.finalize();

    var outer: [2]usize = .{ 0, 0 }; // top-of-stack sentinel
    var inner: [2]usize = .{ @intFromPtr(&outer), 0x99 };
    const inner_fp: usize = @intFromPtr(&inner);

    const ctx: Context = .{ .normalize = identityTruncate };
    const loader = loaderFor(&ctx);
    const result = unwind.walk(t, 7, 50, 0x50, inner_fp, loader, 16, null, null);
    try testing.expectEqual(unwind.UnwindResult.uncaught, result);
}

test "frame_chain_adapter: normalize callback receives ret_addr - 1 (D-183 DWARF convention)" {
    // D-183: the adapter subtracts 1 from the saved return
    // address before invoking the normalizer so the lookup
    // lands at the prior instruction's byte (DWARF / libunwind
    // convention; covers try_table bodies ending in CALL where
    // the saved-LR lands exactly at the body's `pc_end`).
    const Probe = struct {
        var captured: usize = 0;
        fn capture(ret_addr: usize, ctx: ?*anyopaque) u32 {
            _ = ctx;
            captured = ret_addr;
            return @truncate(ret_addr);
        }
    };
    Probe.captured = 0;

    var frame: [2]usize = .{ 0xAA, 0xDEADC0DEABCD1234 };
    const fp: usize = @intFromPtr(&frame);

    const ctx: Context = .{ .normalize = Probe.capture };
    _ = loadFrameLink(fp, @ptrCast(@constCast(&ctx)));
    try testing.expectEqual(@as(usize, 0xDEADC0DEABCD1233), Probe.captured);
}
