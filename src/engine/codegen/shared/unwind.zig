//! FP-walk unwind algorithm (ADR-0114 D5).
//!
//! Cross-platform: Mac aarch64 / Linux x86_64 / Win64 use the
//! SAME frame-chain walker — FP register conventions are
//! ABI-pinned per platform (AAPCS64: X29; SysV / Win64: RBP)
//! but the walk shape is platform-agnostic. The arch-specific
//! glue (which FP register to read, how to materialise the
//! frame chain from registers + memory) lives in the
//! `zwasm_throw` trampoline; this
//! file owns the platform-agnostic algorithm.
//!
//! Algorithm (per ADR-0114 D5):
//!
//!   pc = current_throw_site
//!   fp = current_frame_pointer
//!   loop:
//!       handler = table.lookup(pc, throw_tag_idx)
//!       if handler != null:
//!           return .{ landing_pad_pc, kind, handler_fp = fp }
//!       (caller_fp, caller_pc) = load_frame_chain(fp)
//!       if caller_fp == 0:  // top of stack
//!           return .uncaught
//!       fp = caller_fp
//!       pc = caller_pc
//!
//! Cross-instance EH (ADR-0134 D2): an optional `InstanceResolver`
//! maps each frame's absolute PC to its OWNING instance's table +
//! module-relative PC, so a module-1 throw reaches a module-2 catch
//! (the throw's identity is resolved once from the throwing table per
//! ADR-0134 D3, then matched against each frame's table). With no
//! resolver the walk uses one table for every frame (single-instance).
//!
//! INVARIANT: the walker has NO allocator calls / NO host-call
//! invocations / NO signal-check branches between
//! initial entry and the .uncaught or .handler return —
//! aligning with the safepoint-free unwind invariant cited
//! by ADR-0114 D5 (the unwinder shares the
//! "no allocator between teardown and landing" property with
//! tail-call per ADR-0112 D7).
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

const exception_table = @import("exception_table.zig");

pub const ExceptionTable = exception_table.ExceptionTable;
pub const CatchKind = exception_table.CatchKind;

/// One frame-chain link as observed by the unwinder. Materialised
/// per-arch by the trampoline (AAPCS64 reads `[X29, #0]` for
/// caller's saved FP + `[X29, #8]` for caller's saved LR; SysV
/// reads `[RBP]` for caller's saved RBP + `[RBP + 8]` for the
/// return address).
///
/// `caller_fp == 0` signals top-of-stack (= no caller frame; the
/// throw escapes the Wasm execution boundary → uncaught exception
/// per ADR-0114 D5).
pub const FrameLink = struct {
    caller_fp: usize,
    caller_pc: u32,
    /// Absolute return address (= raw saved LR / RIP, pre-normalize).
    /// The walker carries this so a handler match in this frame can
    /// return the absolute PC, letting the trampoline look up the
    /// catching function's `code_map.Entry` for `start_addr` +
    /// `frame_bytes` (needed to compute the absolute landing-pad
    /// JMP target and the SP-restore amount).
    caller_abs_pc: usize,
};

/// Function pointer that materialises one frame-chain step.
/// Caller (the trampoline) constructs this once per unwind and
/// passes it to `walk`. The synthetic-test driver supplies an
/// in-memory implementation; the production trampoline supplies
/// the load-from-frame-prefix implementation.
pub const LoadFrameChainFn = *const fn (fp: usize, ctx: ?*anyopaque) ?FrameLink;

pub const FrameChainLoader = struct {
    load: LoadFrameChainFn,
    ctx: ?*anyopaque = null,
};

/// Successful catch outcome.
pub const HandlerLanding = struct {
    landing_pad_pc: u32,
    kind: CatchKind,
    /// FP at the catching frame — the trampoline restores SP to
    /// this frame's prologue boundary before jumping to
    /// `landing_pad_pc`.
    handler_fp: usize,
    /// Absolute PC inside the catching function at the moment the
    /// handler matched (= the throw-site call's saved-LR for the
    /// catching frame, OR `throw_site_addr` if the handler hit in
    /// the throwing function itself). The trampoline does
    /// `code_map.lookup(handler_abs_pc)` to recover the catching
    /// function's `start_addr` + `frame_bytes` for the SP-restore
    /// and absolute landing-pad JMP target.
    handler_abs_pc: usize,
};

/// Unwind walk result. `.uncaught` propagates to the
/// outermost Wasm boundary and triggers the host's uncaught-
/// exception trap (per ADR-0114 D5 + Wasm 3.0 §4.5.10).
pub const UnwindResult = union(enum) {
    handler: HandlerLanding,
    uncaught,
};

/// One frame's resolved EH view (ADR-0134 D2): the owning instance's
/// exception table + the frame's absolute PC normalized to THAT
/// instance's module-relative PC. Returned by an `InstanceResolver`
/// keyed on the frame's absolute PC.
pub const ResolvedFrame = struct {
    table: ExceptionTable,
    module_pc: u32,
};

/// Maps a frame's absolute PC → its owning instance's `ResolvedFrame`
/// (ADR-0134 D2). `null` result = the PC is in no registered instance
/// (e.g. a cross-module bridge-thunk frame, or an unregistered
/// single-instance) → `walk` falls back to the THROWING instance's
/// table for that frame (harmless miss for a thunk; correct for an
/// unregistered single-instance). When the whole `resolver` is `null`
/// (synthetic-test paths), `walk` uses the passed-in `table` +
/// loader-normalized PC for every frame (the pre-D2 behaviour).
pub const InstanceResolver = struct {
    resolve: *const fn (abs_pc: usize, ctx: ?*anyopaque) ?ResolvedFrame,
    ctx: ?*anyopaque = null,
};

/// Walk the frame chain from `(initial_pc, initial_fp)` looking
/// for a handler matching the thrown tag. Stops at the first
/// matching handler (= innermost-try_table-wins per ADR-0114 D5
/// + Wasm 3.0 §4.5.10).
///
/// The thrown tag's identity is resolved ONCE from `table` (the
/// THROWING instance's table) — a globally-comparable id (ADR-0134
/// D3) — then matched against each frame's table. With a per-frame
/// `resolver` (D2) each frame uses its OWN instance's table + PC
/// normalization, so a module-1 throw reaches a module-2 catch.
///
/// `max_depth` bounds the walk to detect corrupted frame chains
/// (a cycle would otherwise loop forever). The trampoline sets
/// it to the Runtime's configured Wasm call-stack cap.
pub fn walk(
    table: ExceptionTable,
    throw_tag_idx: u32,
    initial_pc: u32,
    initial_abs_pc: usize,
    initial_fp: usize,
    loader: FrameChainLoader,
    max_depth: u32,
    resolver: ?InstanceResolver,
    /// The thrown tag's globally comparable identity, when the caller holds it
    /// rather than an index into `table` — a `throw_ref` of an exnref whose tag
    /// the RETHROWING module does not declare has no local index to name it
    /// (#426 review). `null` = derive it from `throw_tag_idx` as usual.
    throw_id_override: ?u64,
) UnwindResult {
    const throw_id = throw_id_override orelse table.identityOf(throw_tag_idx);
    var pc = initial_pc;
    var abs_pc = initial_abs_pc;
    var fp = initial_fp;
    var depth: u32 = 0;
    while (depth < max_depth) : (depth += 1) {
        var frame_table = table;
        var frame_pc = pc;
        if (resolver) |r| {
            if (r.resolve(abs_pc, r.ctx)) |rf| {
                frame_table = rf.table;
                frame_pc = rf.module_pc;
            }
            // else: PC owned by no registered instance — fall back to the
            // throwing instance's table + loader-normalized PC. This keeps
            // an UNREGISTERED single-instance throw working (it matches in
            // the throwing table as before) and is harmless for a genuine
            // bridge-thunk frame (the thunk has no try_table → the lookup
            // misses and the walk steps to the caller). So wiring the
            // resolver is regression-safe even with zero registrations.
        }
        if (frame_table.lookupByIdentity(frame_pc, throw_id)) |hit| {
            return .{ .handler = .{
                .landing_pad_pc = hit.landing_pad_pc,
                .kind = hit.kind,
                .handler_fp = fp,
                .handler_abs_pc = abs_pc,
            } };
        }
        const link = loader.load(fp, loader.ctx) orelse return .uncaught;
        if (link.caller_fp == 0) return .uncaught;
        fp = link.caller_fp;
        pc = link.caller_pc;
        abs_pc = link.caller_abs_pc;
    }
    // Depth exhausted — treat as uncaught. The trampoline
    // distinguishes this from a clean top-of-stack via the
    // depth counter (Phase 11+ if diagnostic granularity warrants).
    return .uncaught;
}

// ---------------------------------------------------------------------
// Unit tests — pure-algorithm; synthetic frame chains constructed
// inline. No JIT emit / no actual stack walk required.
// ---------------------------------------------------------------------

const testing = std.testing;
const Builder = exception_table.Builder;

/// Synthetic frame-chain backing for tests. Maps `fp → FrameLink`
/// via an array lookup keyed on FP-as-index.
const SyntheticFrames = struct {
    links: []const ?FrameLink,

    fn loadFn(fp: usize, ctx: ?*anyopaque) ?FrameLink {
        const self: *const SyntheticFrames = @ptrCast(@alignCast(ctx.?));
        if (fp >= self.links.len) return null;
        return self.links[fp];
    }

    fn loader(self: *const SyntheticFrames) FrameChainLoader {
        return .{ .load = SyntheticFrames.loadFn, .ctx = @constCast(self) };
    }
};

test "unwind: matching handler in current frame → returns handler immediately" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = 5,
        .landing_pad_pc = 200,
        .kind = .catch_,
    });
    const t = b.finalize();

    // No frame chain needed — handler hits at the initial frame.
    const frames: SyntheticFrames = .{ .links = &.{} };
    const result = walk(t, 5, 50, 0, 1, frames.loader(), 16, null, null);

    switch (result) {
        .handler => |h| {
            try testing.expectEqual(@as(u32, 200), h.landing_pad_pc);
            try testing.expectEqual(CatchKind.catch_, h.kind);
            try testing.expectEqual(@as(usize, 1), h.handler_fp);
        },
        .uncaught => try testing.expect(false),
    }
}

test "unwind: no handler in any frame → uncaught (caller_fp == 0 terminates)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = 5,
        .landing_pad_pc = 200,
        .kind = .catch_,
    });
    const t = b.finalize();

    // 2-frame chain; throw tag is 99 (no match at any pc).
    // fp=2 → caller fp=1 ; fp=1 → caller fp=0 (top).
    const frames: SyntheticFrames = .{ .links = &.{
        null,
        .{ .caller_fp = 0, .caller_pc = 0, .caller_abs_pc = 0 },
        .{ .caller_fp = 1, .caller_pc = 50, .caller_abs_pc = 50 },
    } };
    const result = walk(t, 99, 50, 0, 2, frames.loader(), 16, null, null);
    try testing.expectEqual(UnwindResult.uncaught, result);
}

test "unwind: walks to caller frame and finds handler there" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    // Inner frame's PC range = [0, 100), tag=99 (won't match throw of tag=5).
    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = 99,
        .landing_pad_pc = 100,
        .kind = .catch_,
    });
    // Caller's PC range = [500, 600), tag=5 → matches throw.
    try b.add(testing.allocator, .{
        .pc_start = 500,
        .pc_end = 600,
        .tag_idx = 5,
        .landing_pad_pc = 555,
        .kind = .catch_,
    });
    const t = b.finalize();

    // Inner frame at fp=2 throws at pc=50 (no match);
    // caller frame at fp=1, call site pc=550.
    const frames: SyntheticFrames = .{ .links = &.{
        null,
        .{ .caller_fp = 0, .caller_pc = 0, .caller_abs_pc = 0 },
        .{ .caller_fp = 1, .caller_pc = 550, .caller_abs_pc = 0x10550 },
    } };
    const result = walk(t, 5, 50, 0x10050, 2, frames.loader(), 16, null, null);

    switch (result) {
        .handler => |h| {
            try testing.expectEqual(@as(u32, 555), h.landing_pad_pc);
            try testing.expectEqual(@as(usize, 1), h.handler_fp);
        },
        .uncaught => try testing.expect(false),
    }
}

test "unwind: catch_all in inner frame catches everything (no walk needed)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = null,
        .landing_pad_pc = 77,
        .kind = .catch_all,
    });
    const t = b.finalize();

    const frames: SyntheticFrames = .{ .links = &.{} };
    const result = walk(t, 12345, 50, 0, 0, frames.loader(), 16, null, null);
    switch (result) {
        .handler => |h| {
            try testing.expectEqual(@as(u32, 77), h.landing_pad_pc);
            try testing.expectEqual(CatchKind.catch_all, h.kind);
        },
        .uncaught => try testing.expect(false),
    }
}

test "unwind: max_depth bound prevents runaway on corrupted chain" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    // Table has no entries — every frame falls through.
    const t = b.finalize();

    // Pathological frame chain: every frame points back to itself
    // (a cycle). Without max_depth this would loop forever.
    const frames: SyntheticFrames = .{
        .links = &.{
            .{ .caller_fp = 0, .caller_pc = 0, .caller_abs_pc = 0 }, // fp=0 → fp=0 (self-cycle)
        },
    };
    const result = walk(t, 1, 0, 0, 0, frames.loader(), 4, null, null);
    try testing.expectEqual(UnwindResult.uncaught, result);
}

test "unwind: loader returning null (invalid fp) → uncaught" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    const t = b.finalize();

    // Empty frame chain — loader returns null at any fp.
    const frames: SyntheticFrames = .{ .links = &.{} };
    const result = walk(t, 5, 50, 0, 99, frames.loader(), 16, null, null);
    try testing.expectEqual(UnwindResult.uncaught, result);
}

test "unwind: handler_fp reports the catching frame (NOT the throwing frame)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    // No handler at inner; handler at depth-2 frame.
    try b.add(testing.allocator, .{
        .pc_start = 1000,
        .pc_end = 2000,
        .tag_idx = null,
        .landing_pad_pc = 1500,
        .kind = .catch_all,
    });
    const t = b.finalize();

    // 3-frame chain: throw at fp=3 → walks to fp=2 → walks to fp=1
    // (pc=1500 hits the handler). handler_fp should be 1.
    const frames: SyntheticFrames = .{ .links = &.{
        null,
        .{ .caller_fp = 0, .caller_pc = 0, .caller_abs_pc = 0 },
        .{ .caller_fp = 1, .caller_pc = 1500, .caller_abs_pc = 0x21500 },
        .{ .caller_fp = 2, .caller_pc = 50, .caller_abs_pc = 0x20050 },
    } };
    const result = walk(t, 7, 10, 0x30010, 3, frames.loader(), 16, null, null);
    switch (result) {
        .handler => |h| try testing.expectEqual(@as(usize, 1), h.handler_fp),
        .uncaught => try testing.expect(false),
    }
}

/// Two synthetic instances keyed by absolute-PC range, for the
/// cross-instance resolver test (ADR-0134 D2). `a` = [0x1000,0x2000),
/// `b` = [0x2000,0x3000); a PC outside both = pass-through (null).
const TwoInstanceResolver = struct {
    a: ExceptionTable,
    b: ExceptionTable,

    fn resolveFn(abs_pc: usize, ctx: ?*anyopaque) ?ResolvedFrame {
        const self: *const TwoInstanceResolver = @ptrCast(@alignCast(ctx.?));
        if (abs_pc >= 0x1000 and abs_pc < 0x2000) return .{ .table = self.a, .module_pc = @intCast(abs_pc - 0x1000) };
        if (abs_pc >= 0x2000 and abs_pc < 0x3000) return .{ .table = self.b, .module_pc = @intCast(abs_pc - 0x2000) };
        return null;
    }

    fn resolver(self: *const TwoInstanceResolver) InstanceResolver {
        return .{ .resolve = TwoInstanceResolver.resolveFn, .ctx = @constCast(self) };
    }
};

test "unwind: per-frame resolver switches to the catching instance's table (ADR-0134 D2)" {
    // Instance A (throwing) has NO catch but maps local tag 0 → id 0xAA.
    // Instance B (catching) catches local tag 0, also id 0xAA (a shared
    // cross-module tag identity per D3). The throw's identity is resolved
    // from A (0xAA); the walk must step from A's frame to B's frame and
    // match in B's table — proving per-frame table dispatch.
    var ab: Builder = .empty;
    defer ab.deinit(testing.allocator);
    const a_ids = [_]u64{0xAA};
    const a_table: ExceptionTable = .{ .entries = ab.finalize().entries, .tag_ids = &a_ids };

    var bb: Builder = .empty;
    defer bb.deinit(testing.allocator);
    try bb.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 0x100,
        .tag_idx = 0,
        .landing_pad_pc = 200,
        .kind = .catch_,
    });
    const b_ids = [_]u64{0xAA};
    const b_table: ExceptionTable = .{ .entries = bb.finalize().entries, .tag_ids = &b_ids };

    const two: TwoInstanceResolver = .{ .a = a_table, .b = b_table };

    // Frame chain: fp=2 (A, throw at abs 0x1050) → fp=1 (B, abs 0x2050).
    const frames: SyntheticFrames = .{
        .links = &.{
            .{ .caller_fp = 0, .caller_pc = 0, .caller_abs_pc = 0 }, // fp=0 top (unused)
            .{ .caller_fp = 0, .caller_pc = 0, .caller_abs_pc = 0 }, // fp=1 → top
            .{ .caller_fp = 1, .caller_pc = 0, .caller_abs_pc = 0x2050 }, // fp=2 → fp=1 @ B
        },
    };
    // throw_tag_idx 0 resolved via A's table → 0xAA. initial abs 0x1050 (A).
    const result = walk(a_table, 0, 0, 0x1050, 2, frames.loader(), 16, two.resolver(), null);
    switch (result) {
        .handler => |h| {
            try testing.expectEqual(@as(u32, 200), h.landing_pad_pc);
            try testing.expectEqual(@as(usize, 1), h.handler_fp); // B's frame
        },
        .uncaught => try testing.expect(false),
    }

    // Control: a throw identity that no instance catches → uncaught.
    const a_ids2 = [_]u64{0xCC}; // A maps tag 0 → 0xCC (≠ B's 0xAA)
    const a_table2: ExceptionTable = .{ .entries = ab.finalize().entries, .tag_ids = &a_ids2 };
    const two2: TwoInstanceResolver = .{ .a = a_table2, .b = b_table };
    const r2 = walk(a_table2, 0, 0, 0x1050, 2, frames.loader(), 16, two2.resolver(), null);
    try testing.expectEqual(UnwindResult.uncaught, r2);
}
